<#
.SYNOPSIS
    IT-AdminUtil - Console Portatil de Administracao de TI (Estilo WinUtil)
.DESCRIPTION
    Utilitario completo em PowerShell + WPF com Dashboard Avancado (Telemetria,
    Sensores Termicos CPU/NVMe, Perfis Rapidos de IP/VLAN, Controle de Servicos,
    Ping Gateway/WAN, Copiar Ficha Tecnica), Setup Expresso de Maquinas,
    Limpeza de Standby RAM, Ping Sweep, Rastreador IP/MAC/Switch e Instalador Winget.
#>

# ==============================================================================
# 1. VERIFICACAO DE PRIVILEGIOS DE ADMINISTRADOR
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warning "Este utilitario requer privilegios de Administrador."
    Write-Host "Abra o PowerShell como Administrador e execute o comando novamente." -ForegroundColor Yellow
    Pause
    exit
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ProfilesFile = Join-Path $ScriptDir "ip_profiles.json"
$SwitchesFile = Join-Path $ScriptDir "switches.json"

# ==============================================================================
# 2. GERENCIAMENTO DE PERFIS DE IP / VLAN E INVENTARIO DE SWITCHES (JSON)
# ==============================================================================
function global:Get-IpProfiles {
    if (Test-Path $ProfilesFile) {
        try {
            $data = Get-Content -Path $ProfilesFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data) { return @($data) }
        } catch {}
    }

    $defaults = @(
        [PSCustomObject]@{ Name = "Bancada / Roteador Padrao (.1.50)"; IP = "192.168.1.50"; Mask = "255.255.255.0"; Gateway = "192.168.1.1"; DNS = "8.8.8.8" },
        [PSCustomObject]@{ Name = "Rede Equipamentos (.0.50)"; IP = "192.168.0.50"; Mask = "255.255.255.0"; Gateway = "192.168.0.1"; DNS = "8.8.8.8" },
        [PSCustomObject]@{ Name = "Gerencia Switches / OLT (10.101.1.250)"; IP = "10.101.1.250"; Mask = "255.255.255.0"; Gateway = "10.101.1.1"; DNS = "1.1.1.1" },
        [PSCustomObject]@{ Name = "UniFi / Controladora (.20.50)"; IP = "192.168.20.50"; Mask = "255.255.255.0"; Gateway = "192.168.20.254"; DNS = "192.168.20.254" }
    )
    Save-IpProfiles -Profiles $defaults
    return $defaults
}

function global:Save-IpProfiles {
    param([array]$Profiles)
    try {
        $Profiles | ConvertTo-Json -Depth 3 | Out-File -FilePath $ProfilesFile -Encoding UTF8
    } catch {
        Write-AppLog "Nao foi possivel salvar ip_profiles.json (modo somente leitura)." "WARN"
    }
}

function global:Get-SwitchInventory {
    if (Test-Path $SwitchesFile) {
        try {
            $data = Get-Content -Path $SwitchesFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data) { return @($data) }
        } catch {}
    }

    $defaults = @(
        [PSCustomObject]@{ Name = "Switch CPD";         IP = "10.101.1.231"; Community = "public" },
        [PSCustomObject]@{ Name = "Switch Piscina";     IP = "10.101.1.232"; Community = "public" },
        [PSCustomObject]@{ Name = "Switch Estoque";     IP = "10.101.1.233"; Community = "public" },
        [PSCustomObject]@{ Name = "Switch Pedra Velha"; IP = "10.101.1.234"; Community = "public" }
    )
    Save-SwitchInventory -Switches $defaults
    return $defaults
}

function global:Save-SwitchInventory {
    param([array]$Switches)
    try {
        $Switches | ConvertTo-Json -Depth 3 | Out-File -FilePath $SwitchesFile -Encoding UTF8
    } catch {
        Write-AppLog "Nao foi possivel salvar switches.json." "WARN"
    }
}

# ==============================================================================
# 3. ESTADO SINCRONIZADO ENTRE UI E RUNSPACES (THREAD-SAFE)
# ==============================================================================
$SyncHash = [hashtable]::Synchronized(@{
    LogQueue        = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    ResultTabs      = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    ShowResults     = $false
    IsBusy          = $false
    StatusText      = "Pronto"
    DashboardData   = $null
    DashboardReady  = $false
    RefreshDashNext = $false
    WingetStatusMap = $null
    WingetReady     = $false
    ErrorCount      = 0
})

function global:Write-AppLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    if ($Level -eq "ERR") { $SyncHash.ErrorCount++ }
    $prefix = switch ($Level) {
        "ERR"   { "[ERRO]" }
        "WARN"  { "[AVISO]" }
        "OK"    { "[OK]" }
        "CMD"   { "[CMD]" }
        default { "[INFO]" }
    }
    $SyncHash.LogQueue.Enqueue("[$timestamp] $prefix $Message")
}

# ==============================================================================
# 4. MOTOR DE EXECUCAO ASSINCRONA
# ==============================================================================
function global:Invoke-AsyncTask {
    param(
        [string]$TaskName,
        [scriptblock]$ScriptBlock,
        [hashtable]$Parameters = @{},
        [bool]$AutoRefreshDashboard = $false
    )

    if ($SyncHash.IsBusy) {
        Write-AppLog "Aguarde a conclusao da tarefa atual antes de iniciar outra." "WARN"
        return
    }

    $SyncHash.IsBusy = $true
    $SyncHash.StatusText = "Executando: $TaskName..."
    $SyncHash.ResultTabs.Clear()
    $SyncHash.ShowResults = $false

    Write-AppLog ">>> Iniciando: $TaskName"

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("SyncHash", $SyncHash)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $scriptText = $ScriptBlock.ToString()

    $wrapperCode = {
        param($ScriptCodeString, $UserParams, $Sync, $TName, $DoRefreshDash)

        Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
        Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
        Import-Module CimCmdlets -ErrorAction SilentlyContinue
        Import-Module NetTCPIP -ErrorAction SilentlyContinue
        Import-Module DnsClient -ErrorAction SilentlyContinue
        Import-Module Storage -ErrorAction SilentlyContinue

        function global:Write-TaskLog {
            param([string]$Msg, [string]$Lvl = "INFO")
            if ($Lvl -eq "ERR") { $Sync.ErrorCount++ }
            $ts = (Get-Date).ToString("HH:mm:ss")
            $Sync.LogQueue.Enqueue("[$ts] [$Lvl] $Msg")
        }

        function global:Add-TaskResult {
            param([string]$TabTitle, [string]$Content)
            if (-not [string]::IsNullOrWhiteSpace($Content)) {
                [void]$Sync.ResultTabs.Add([PSCustomObject]@{
                    Title   = $TabTitle
                    Content = $Content.Trim()
                })
            }
        }

        function global:Invoke-NativeCmd {
            param(
                [string]$CmdLine,
                [string]$ResultTabTitle = ""
            )
            $ts = (Get-Date).ToString("HH:mm:ss")
            $Sync.LogQueue.Enqueue("[$ts] [CMD] Acionando: $CmdLine")

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "cmd.exe"
            $psi.Arguments = "/c $CmdLine"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(850)
            $psi.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(850)
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()

            if ($proc.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($err)) {
                $Sync.ErrorCount++
                $Sync.LogQueue.Enqueue("[$ts] [ERRO] $($err.Trim())")
            }

            if ($ResultTabTitle -ne "") {
                $combined = ""
                if (-not [string]::IsNullOrWhiteSpace($out)) { $combined += $out.Trim() }
                if (-not [string]::IsNullOrWhiteSpace($err)) { $combined += "`r`n`r`n[AVISOS/ERROS]:`r`n" + $err.Trim() }
                if ([string]::IsNullOrWhiteSpace($combined)) { $combined = "(Comando executado sem retorno textual)" }
                Add-TaskResult -TabTitle $ResultTabTitle -Content $combined
            }
        }

        function global:Enable-AdapterDhcpClean {
            param([string]$Alias)
            Write-TaskLog "Removendo IP estatico e habilitando DHCP em '$Alias'..." "CMD"

            Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -eq 'Manual' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            Get-NetRoute -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.Protocol -eq 'NetMgmt' } |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

            Set-NetIPInterface -InterfaceAlias $Alias -Dhcp Enabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceAlias $Alias -ResetServerAddresses -ErrorAction SilentlyContinue

            Invoke-NativeCmd "netsh interface ipv4 set address name=`"$Alias`" source=dhcp"
            Invoke-NativeCmd "netsh interface ipv4 set dnsservers name=`"$Alias`" source=dhcp"

            $nicState = (Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue).Status
            if ($nicState -eq "Up") {
                Invoke-NativeCmd "ipconfig /renew `"$Alias`""
            }
        }

        function global:Set-AdapterStaticClean {
            param(
                [string]$Alias,
                [string]$IP,
                [string]$Mask = "255.255.255.0",
                [string]$Gateway = "",
                [string]$DNS = ""
            )
            Write-TaskLog "Aplicando IP fixo $IP ($Mask) em '$Alias'..." "CMD"
            if ($Gateway) {
                Invoke-NativeCmd "netsh interface ipv4 set address name=`"$Alias`" static $IP $Mask $Gateway 1"
            } else {
                Invoke-NativeCmd "netsh interface ipv4 set address name=`"$Alias`" static $IP $Mask"
            }
            if ($DNS) {
                Invoke-NativeCmd "netsh interface ipv4 set dnsservers name=`"$Alias`" static $DNS primary"
            } else {
                Invoke-NativeCmd "netsh interface ipv4 set dnsservers name=`"$Alias`" source=dhcp"
            }
        }

        function global:Invoke-RamStandbyPurge {
            param([bool]$PurgeStandby = $true)
            $code = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class RamCleaner {
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int InfoClass, ref int Info, int Length);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct TOKEN_PRIVILEGES {
        public int PrivilegeCount;
        public long Luid;
        public int Attributes;
    }

    public static void TrimWorkingSets() {
        foreach (Process p in Process.GetProcesses()) {
            try { EmptyWorkingSet(p.Handle); } catch {}
        }
    }

    public static void PurgeStandbyList() {
        IntPtr token;
        if (OpenProcessToken(Process.GetCurrentProcess().Handle, 0x0028, out token)) {
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Attributes = 2;
            if (LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out tp.Luid)) {
                AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            }
        }
        int cmd = 4;
        NtSetSystemInformation(80, ref cmd, sizeof(int));
    }
}
"@
            if (-not ([System.Management.Automation.PSTypeName]'RamCleaner').Type) {
                Add-Type -TypeDefinition $code -Language CSharp
            }
            [RamCleaner]::TrimWorkingSets()
            if ($PurgeStandby) {
                [RamCleaner]::PurgeStandbyList()
            }
        }

        function global:Invoke-SnmpMacLookup {
            param([string]$SwitchIp, [string]$Community, [string]$MacHexClean)
            $snmpCode = @"
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;

public class SnmpMacFinder {
    public static int FindMacPort(string switchIp, string community, byte[] targetMac) {
        List<int> oid = new List<int> { 1, 3, 6, 1, 2, 1, 17, 4, 3, 1, 2 };
        foreach (byte b in targetMac) oid.Add(b);

        byte[] packet = BuildSnmpGetPacket(community, oid.ToArray());
        using (UdpClient udp = new UdpClient()) {
            udp.Client.ReceiveTimeout = 1200;
            IPEndPoint ep = new IPEndPoint(IPAddress.Parse(switchIp), 161);
            udp.Send(packet, packet.Length, ep);
            try {
                byte[] resp = udp.Receive(ref ep);
                if (resp.Length > 20) {
                    for (int i = resp.Length - 6; i >= 15; i--) {
                        if (resp[i] == 0x02 && resp[i + 1] == 0x01 && resp[i + 2] == 0x00) {
                            int valLen = resp[resp.Length - 2];
                            if (valLen == 1) return resp[resp.Length - 1];
                            if (valLen == 2) return (resp[resp.Length - 2] << 8) | resp[resp.Length - 1];
                        }
                    }
                }
            } catch {}
        }
        return -1;
    }

    private static byte[] EncodeOid(int[] oid) {
        List<byte> bytes = new List<byte>();
        bytes.Add((byte)(oid[0] * 40 + oid[1]));
        for (int i = 2; i < oid.Length; i++) {
            int v = oid[i];
            if (v < 128) bytes.Add((byte)v);
            else {
                Stack<byte> s = new Stack<byte>();
                s.Push((byte)(v & 0x7F));
                v >>= 7;
                while (v > 0) { s.Push((byte)((v & 0x7F) | 0x80)); v >>= 7; }
                while (s.Count > 0) bytes.Add(s.Pop());
            }
        }
        return bytes.ToArray();
    }

    private static byte[] BuildSnmpGetPacket(string comm, int[] oid) {
        byte[] oidBytes = EncodeOid(oid);
        List<byte> varBind = new List<byte> { 0x06, (byte)oidBytes.Length };
        varBind.AddRange(oidBytes);
        varBind.AddRange(new byte[] { 0x05, 0x00 });

        List<byte> varBindSeq = new List<byte> { 0x30, (byte)varBind.Count };
        varBindSeq.AddRange(varBind);

        List<byte> varBindList = new List<byte> { 0x30, (byte)varBindSeq.Count };
        varBindList.AddRange(varBindSeq);

        List<byte> pdu = new List<byte> { 0xA0 };
        List<byte> pduBody = new List<byte> { 0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00 };
        pduBody.AddRange(varBindList);
        pdu.Add((byte)pduBody.Count);
        pdu.AddRange(pduBody);

        byte[] commBytes = System.Text.Encoding.ASCII.GetBytes(comm);
        List<byte> msgBody = new List<byte> { 0x02, 0x01, 0x01, 0x04, (byte)commBytes.Length };
        msgBody.AddRange(commBytes);
        msgBody.AddRange(pdu);

        List<byte> full = new List<byte> { 0x30, (byte)msgBody.Count };
        full.AddRange(msgBody);
        return full.ToArray();
    }
}
"@
            if (-not ([System.Management.Automation.PSTypeName]'SnmpMacFinder').Type) {
                Add-Type -TypeDefinition $snmpCode -Language CSharp
            }
            $bytes = [byte[]]::new(6)
            for ($i = 0; $i -lt 6; $i++) {
                $bytes[$i] = [Convert]::ToByte($MacHexClean.Substring($i * 2, 2), 16)
            }
            return [SnmpMacFinder]::FindMacPort($SwitchIp, $Community, $bytes)
        }

        try {
            $localBlock = [scriptblock]::Create($ScriptCodeString)
            & $localBlock @UserParams
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Concluido: $TName")
            if ($Sync.ResultTabs.Count -gt 0) {
                $Sync.ShowResults = $true
            }
            if ($DoRefreshDash) {
                Start-Sleep -Milliseconds 650
                $Sync.RefreshDashNext = $true
            }
        } catch {
            $Sync.ErrorCount++
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [ERRO] Falha em '$TName': $($_.Exception.Message)")
        } finally {
            $Sync.IsBusy = $false
            $Sync.StatusText = "Pronto"
        }
    }

    [void]$ps.AddScript($wrapperCode).AddArgument($scriptText).AddArgument($Parameters).AddArgument($SyncHash).AddArgument($TaskName).AddArgument($AutoRefreshDashboard)
    $null = $ps.BeginInvoke()
}

# ==============================================================================
# 5. COLETA ASSINCRONA DO DASHBOARD & DETECCAO DE SOFTWARES WINGET
# ==============================================================================
function global:Update-DashboardAsync {
    $SyncHash.StatusText = "Atualizando telemetria e interfaces..."
    Write-AppLog "Atualizando telemetria, latencia e interfaces de rede..." "CMD"

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = "STA"
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("SyncHash", $SyncHash)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    $dashScript = {
        param($Sync)
        Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
        Import-Module CimCmdlets -ErrorAction SilentlyContinue
        Import-Module Storage -ErrorAction SilentlyContinue
        Import-Module NetTCPIP -ErrorAction SilentlyContinue
        Import-Module DnsClient -ErrorAction SilentlyContinue

        $deg = [char]176

        try {
            $cs    = Get-CimInstance Win32_ComputerSystem
            $os    = Get-CimInstance Win32_OperatingSystem
            $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
            $bios  = Get-CimInstance Win32_BIOS
            $board = Get-CimInstance Win32_BaseBoard
            $gpus  = (Get-CimInstance Win32_VideoController).Name -join " | "

            $cpuTempC = $null
            try {
                $tz = Get-CimInstance -Namespace "root\wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
                      Sort-Object CurrentTemperature -Descending | Select-Object -First 1
                if ($tz -and $tz.CurrentTemperature -gt 0) {
                    $cpuTempC = [math]::Round(($tz.CurrentTemperature / 10) - 273.15, 1)
                }
            } catch {
                try {
                    $tz2 = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop |
                           Sort-Object HighPrecisionTemperature -Descending | Select-Object -First 1
                    if ($tz2 -and $tz2.HighPrecisionTemperature -gt 0) {
                        $cpuTempC = [math]::Round(($tz2.HighPrecisionTemperature / 10) - 273.15, 1)
                    }
                } catch {}
            }
            $cpuTempStr = if ($cpuTempC) { "$cpuTempC ${deg}C" } else { "N/D" }

            $totalRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            $freeRamGB  = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
            $usedRamGB  = [math]::Round($totalRamGB - $freeRamGB, 1)
            $ramPct     = if ($totalRamGB -gt 0) { [math]::Round(($usedRamGB / $totalRamGB) * 100, 0) } else { 0 }

            $ramSlotsInfo = "N/D"
            try {
                $sticks = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
                $slotCount = ($sticks | Measure-Object).Count
                $speedMhz = ($sticks | Select-Object -First 1).ConfiguredClockSpeed
                if (-not $speedMhz) { $speedMhz = ($sticks | Select-Object -First 1).Speed }
                $ramSlotsInfo = "$slotCount pente(s) @ ${speedMhz} MHz"
            } catch {}

            $sysDrive  = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
            $diskTotal = if ($sysDrive) { [math]::Round($sysDrive.Size / 1GB, 0) } else { 0 }
            $diskFree  = if ($sysDrive) { [math]::Round($sysDrive.FreeSpace / 1GB, 0) } else { 0 }
            $diskUsed  = $diskTotal - $diskFree
            $diskPct   = if ($diskTotal -gt 0) { [math]::Round(($diskUsed / $diskTotal) * 100, 0) } else { 0 }

            $smartLines = @()
            try {
                $physDisks = Get-PhysicalDisk -ErrorAction Stop
                foreach ($pd in $physDisks) {
                    $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                    $gb = [math]::Round($pd.Size / 1GB, 0)
                    $tempTxt = if ($rel.Temperature -and $rel.Temperature -gt 0) { "$($rel.Temperature)${deg}C" } else { "--${deg}C" }
                    $wearTxt = if ($null -ne $rel.Wear) { "Saude: $(100 - $rel.Wear)%" } else { $pd.HealthStatus }
                    $hrsTxt  = if ($rel.PowerOnHours) { " | $($rel.PowerOnHours)h" } else { "" }
                    $smartLines += "$($pd.FriendlyName) [${gb}GB] -> $tempTxt | $wearTxt$hrsTxt"
                }
            } catch {
                Get-CimInstance Win32_DiskDrive | ForEach-Object {
                    $smartLines += "$($_.Model) [$([math]::Round($_.Size/1GB,0))GB - $($_.Status)]"
                }
            }
            $smartSummary = $smartLines -join "`n"

            $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
            $batStr = "N/A (Desktop / Sem Bateria)"
            if ($bat) {
                $charge = $bat.EstimatedChargeRemaining
                try {
                    $full = (Get-CimInstance -Namespace "root\wmi" -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
                    $des  = (Get-CimInstance -Namespace "root\wmi" -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
                    if ($full -gt 0 -and $des -gt 0) {
                        $healthPct = [math]::Round(($full / $des) * 100, 1)
                        $batStr = "Carga: ${charge}% | Saude Real: ${healthPct}% (${full}/${des} mWh)"
                    } else {
                        $batStr = "Carga: ${charge}% ($($bat.Status))"
                    }
                } catch {
                    $batStr = "Carga: ${charge}% ($($bat.Status))"
                }
            }

            $nicList = @()
            $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                        Where-Object { $_.InterfaceDescription -notmatch "Bluetooth|Virtual|Hyper-V|TAP|VPN|Tailscale|ZeroTier" }
            if (-not $adapters) {
                $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -and $_.InterfaceDescription -notmatch "Bluetooth|Loopback|Virtual|Hyper-V|TAP|VPN|Tailscale|ZeroTier" }
            }

            foreach ($ad in $adapters) {
                $alias = $ad.Name
                $ipInterface = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $isDhcp = ($ipInterface.Dhcp -eq 'Enabled')
                $isConnected = ($ad.Status -eq 'Up')

                $ipObjs = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                          Where-Object { $_.IPAddress -notlike "169.254.*" }
                $ipv4 = if ($ipObjs) { ($ipObjs.IPAddress) -join ", " } else { "Sem IP (DHCP Aguardando)" }

                $routeObj = Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
                $gw = if ($routeObj) { $routeObj.NextHop } else { "" }

                $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $dns = if ($dnsObj -and $dnsObj.ServerAddresses) { ($dnsObj.ServerAddresses | Select-Object -First 1) } else { "" }

                $nicList += [PSCustomObject]@{
                    Alias       = $alias
                    Description = $ad.InterfaceDescription
                    MacAddress  = $ad.MacAddress
                    Connected   = $isConnected
                    StatusText  = if ($isConnected) { "Conectada" } else { "Desconectada" }
                    IPv4        = $ipv4
                    Mask        = "255.255.255.0"
                    Gateway     = $gw
                    Dns         = $dns
                    DhcpEnabled = $isDhcp
                    ModeText    = if ($isDhcp) { "DHCP (Auto)" } else { "IP Estatico" }
                }
            }

            $activeNic = $nicList | Where-Object { $_.Connected } | Select-Object -First 1
            $ipAddr  = if ($activeNic) { $activeNic.IPv4 } else { "Sem rede" }
            $gwAddr  = if ($activeNic -and $activeNic.Gateway) { $activeNic.Gateway } else { "" }
            $dnsAddr = if ($activeNic -and $activeNic.Dns) { $activeNic.Dns } else { "N/D" }

            $pinger = New-Object System.Net.NetworkInformation.Ping
            $gwLatency = "--"
            if ($gwAddr) {
                try {
                    $rGw = $pinger.Send($gwAddr, 800)
                    if ($rGw.Status -eq "Success") {
                        $ms = if ($rGw.RoundtripTime -eq 0) { "<1" } else { "$($rGw.RoundtripTime)" }
                        $gwLatency = "${ms} ms"
                    } else { $gwLatency = "Falha" }
                } catch { $gwLatency = "Falha" }
            }

            $netOnline = $false
            $wanLatency = "--"
            try {
                $rWan = $pinger.Send("1.1.1.1", 1200)
                if ($rWan.Status -eq "Success") {
                    $netOnline = $true
                    $wanLatency = "$($rWan.RoundtripTime) ms"
                }
            } catch {}
            $pinger.Dispose()

            $up = (Get-Date) - $os.LastBootUpTime
            $uptimeStr = "$($up.Days)d $($up.Hours)h $($up.Minutes)m"

            $crashSummary = "0 falhas criticas (30d)"
            try {
                $since = (Get-Date).AddDays(-30)
                $evts = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,1001; StartTime=$since} -ErrorAction SilentlyContinue
                $c41 = ($evts | Where-Object { $_.Id -eq 41 } | Measure-Object).Count
                $c1001 = ($evts | Where-Object { $_.Id -eq 1001 } | Measure-Object).Count
                if ($c41 -gt 0 -or $c1001 -gt 0) {
                    $crashSummary = "$c1001 BSOD / $c41 Deslig. Forcados (30d)"
                }
            } catch {}

            $spooler  = (Get-Service Spooler -ErrorAction SilentlyContinue).Status -eq "Running"
            $wuauserv = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq "Running"
            $defender = (Get-Service WinDefend -ErrorAction SilentlyContinue).Status -eq "Running"
            $rdpVal   = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -ErrorAction SilentlyContinue).fDenyTSConnections
            $rdpEnabled = ($rdpVal -eq 0)

            $bitlockerStatus = "Desativado"
            try {
                $bl = Get-CimInstance -Namespace "Root\CIMV2\Security\MicrosoftVolumeEncryption" -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop
                if ($bl.ProtectionStatus -eq 1) { $bitlockerStatus = "Ativo (Protegido)" }
            } catch {}

            $topProcs = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 | ForEach-Object {
                "$($_.ProcessName) ($([math]::Round($_.WorkingSet64/1MB,0)) MB)"
            }) -join "  |  "

            $Sync.DashboardData = @{
                CpuLoad      = [int]$cpu.LoadPercentage
                CpuTemp      = $cpuTempC
                CpuTempStr   = $cpuTempStr
                CpuName      = $cpu.Name.Trim()
                CpuCores     = "$($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T"
                RamUsed      = $usedRamGB
                RamTotal     = $totalRamGB
                RamPct       = $ramPct
                RamSlots     = $ramSlotsInfo
                DiskUsed     = $diskUsed
                DiskTotal    = $diskTotal
                DiskFree     = $diskFree
                DiskPct      = $diskPct
                SmartSummary = $smartSummary
                NicList      = $nicList
                Hostname     = $env:COMPUTERNAME
                User         = $env:USERNAME
                Domain       = "$($cs.Domain) ($(if($cs.PartOfDomain){'Dominio AD'}else{'Workgroup'}))"
                Model        = "$($cs.Manufacturer) $($cs.Model)"
                Motherboard  = "$($board.Manufacturer) $($board.Product)"
                BiosSerial   = $bios.SerialNumber
                Gpu          = $gpus
                OsCaption    = "$($os.Caption) (Build $($os.BuildNumber))"
                Uptime       = $uptimeStr
                Battery      = $batStr
                CrashSummary = $crashSummary
                BitLocker    = $bitlockerStatus
                TopProcs     = $topProcs
                IpAddress    = $ipAddr
                Gateway      = if ($gwAddr) { $gwAddr } else { "N/D" }
                Dns          = $dnsAddr
                InternetOk   = $netOnline
                GwLatency    = $gwLatency
                WanLatency   = $wanLatency
                SvcSpooler   = $spooler
                SvcWU        = $wuauserv
                SvcDefender  = $defender
                SvcRdp       = $rdpEnabled
            }
            $Sync.DashboardReady = $true
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Dashboard atualizado (GW: $gwLatency | Internet: $wanLatency).")
        } catch {
            $Sync.ErrorCount++
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [ERRO] Falha ao carregar Dashboard: $($_.Exception.Message)")
        } finally {
            $Sync.StatusText = "Pronto"
        }
    }

    [void]$ps.AddScript($dashScript).AddArgument($SyncHash)
    $null = $ps.BeginInvoke()
}

function global:Scan-WingetInstalledAsync {
    param([hashtable]$PackageMap)
    Write-AppLog "Verificando softwares instalados via Winget..." "CMD"

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = "STA"
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("SyncHash", $SyncHash)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    $scanScript = {
        param($PkgMap, $Sync)
        $statusResult = @{}
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "winget.exe"
            $psi.Arguments = "list --accept-source-agreements"
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $rawOut = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit()

            foreach ($tag in $PkgMap.Keys) {
                $id = $PkgMap[$tag]
                $statusResult[$tag] = ($rawOut -match [regex]::Escape($id))
            }
        } catch {
            foreach ($tag in $PkgMap.Keys) { $statusResult[$tag] = $false }
        }
        $Sync.WingetStatusMap = $statusResult
        $Sync.WingetReady = $true
        $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Verificacao de status Winget concluida.")
    }

    [void]$ps.AddScript($scanScript).AddArgument($PackageMap).AddArgument($SyncHash)
    $null = $ps.BeginInvoke()
}

# ==============================================================================
# 6. POPUPS E DIALOGOS AUXILIARES
# ==============================================================================
function Show-ResultsPopup {
    param([System.Collections.ArrayList]$TabsData)

    if (-not $TabsData -or $TabsData.Count -eq 0) { return }

    [xml]$resXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Resultados da Execu&#231;&#227;o | IT-AdminUtil"
        Height="580" Width="900" MinHeight="420" MinWidth="640"
        WindowStartupLocation="CenterOwner" Background="#1E222A" Foreground="#E5E7EB"
        FontFamily="Segoe UI">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="Relat&#243;rio Detalhado por Comando Executado" FontSize="16" FontWeight="Bold" Foreground="#3B82F6" VerticalAlignment="Center"/>
            <TextBlock x:Name="LblTabCount" Text="" Foreground="#9CA3AF" FontSize="12" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </DockPanel>

        <TabControl x:Name="ResultTabControl" Grid.Row="1" Background="#161920" BorderBrush="#3E4451" BorderThickness="1" Padding="6">
            <TabControl.Resources>
                <Style TargetType="TabItem">
                    <Setter Property="Background" Value="#282C34"/>
                    <Setter Property="Foreground" Value="#ABB2BF"/>
                    <Setter Property="Padding" Value="12,6"/>
                    <Setter Property="Margin" Value="0,0,4,0"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="TabItem">
                                <Border x:Name="Border" Background="#282C34" BorderBrush="#3E4451" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="12,6" Margin="0,0,3,0">
                                    <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsSelected" Value="True">
                                        <Setter TargetName="Border" Property="Background" Value="#2B579A"/>
                                        <Setter TargetName="Border" Property="BorderBrush" Value="#3B82F6"/>
                                        <Setter Property="Foreground" Value="#FFFFFF"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </TabControl.Resources>
        </TabControl>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnCopyTab" Content="Copiar Aba Atual" Background="#282C34" Foreground="#E5E7EB" BorderBrush="#3E4451" Padding="14,7" Margin="0,0,8,0" Cursor="Hand"/>
            <Button x:Name="BtnSaveTab" Content="Salvar Aba (.txt)" Background="#282C34" Foreground="#E5E7EB" BorderBrush="#3E4451" Padding="14,7" Margin="0,0,8,0" Cursor="Hand"/>
            <Button x:Name="BtnSaveAll" Content="Salvar Tudo (.txt)" Background="#282C34" Foreground="#E5E7EB" BorderBrush="#3E4451" Padding="14,7" Margin="0,0,8,0" Cursor="Hand"/>
            <Button x:Name="BtnCloseRes" Content="Fechar" Background="#2B579A" Foreground="#FFFFFF" BorderBrush="#3B82F6" FontWeight="Bold" Padding="18,7" Cursor="Hand"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $rReader = (New-Object System.Xml.XmlNodeReader $resXaml)
    $resWin = [Windows.Markup.XamlReader]::Load($rReader)
    $resWin.Owner = $Window

    $tabCtrl  = $resWin.FindName("ResultTabControl")
    $lblCount = $resWin.FindName("LblTabCount")
    $btnCopy  = $resWin.FindName("BtnCopyTab")
    $btnSave  = $resWin.FindName("BtnSaveTab")
    $btnAll   = $resWin.FindName("BtnSaveAll")
    $btnClose = $resWin.FindName("BtnCloseRes")

    $lblCount.Text = "$($TabsData.Count) resultado(s) gerado(s)"

    foreach ($item in $TabsData) {
        $tabItem = New-Object System.Windows.Controls.TabItem
        $tabItem.Header = $item.Title

        $txtBox = New-Object System.Windows.Controls.TextBox
        $txtBox.Text = $item.Content
        $txtBox.Background = "#12141A"
        $txtBox.Foreground = "#E5E7EB"
        $txtBox.FontFamily = "Consolas"
        $txtBox.FontSize = 12.5
        $txtBox.IsReadOnly = $true
        $txtBox.VerticalScrollBarVisibility = "Auto"
        $txtBox.HorizontalScrollBarVisibility = "Auto"
        $txtBox.TextWrapping = "NoWrap"
        $txtBox.BorderThickness = "0"
        $txtBox.Padding = "10"

        $tabItem.Content = $txtBox
        [void]$tabCtrl.Items.Add($tabItem)
    }

    $btnCopy.Add_Click({
        if ($tabCtrl.SelectedItem -and $tabCtrl.SelectedItem.Content) {
            [System.Windows.Clipboard]::SetText($tabCtrl.SelectedItem.Content.Text)
            Write-AppLog "Conteudo da aba '$($tabCtrl.SelectedItem.Header)' copiado." "OK"
        }
    })

    $btnSave.Add_Click({
        if ($tabCtrl.SelectedItem -and $tabCtrl.SelectedItem.Content) {
            $safeTitle = ($tabCtrl.SelectedItem.Header -replace '[\\/:*?"<>|]', '_')
            $sfd = New-Object Microsoft.Win32.SaveFileDialog
            $sfd.Filter = "Arquivo de Texto (*.txt)|*.txt"
            $sfd.FileName = "$($safeTitle)_$($env:COMPUTERNAME).txt"
            if ($sfd.ShowDialog() -eq $true) {
                $tabCtrl.SelectedItem.Content.Text | Out-File -FilePath $sfd.FileName -Encoding UTF8
                Write-AppLog "Aba '$($tabCtrl.SelectedItem.Header)' salva em: $($sfd.FileName)" "OK"
            }
        }
    })

    $btnAll.Add_Click({
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.Filter = "Arquivo de Texto (*.txt)|*.txt"
        $sfd.FileName = "Relatorio_Completo_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
        if ($sfd.ShowDialog() -eq $true) {
            $full = New-Object System.Text.StringBuilder
            [void]$full.AppendLine("============================================================")
            [void]$full.AppendLine("RELATORIO CONSOLIDADO - IT-ADMINUTIL ($($env:COMPUTERNAME))")
            [void]$full.AppendLine("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
            [void]$full.AppendLine("============================================================`r`n")
            foreach ($t in $TabsData) {
                [void]$full.AppendLine("### $($t.Title) ###")
                [void]$full.AppendLine($t.Content)
                [void]$full.AppendLine("`r`n------------------------------------------------------------`r`n")
            }
            $full.ToString() | Out-File -FilePath $sfd.FileName -Encoding UTF8
            Write-AppLog "Relatorio consolidado salvo em: $($sfd.FileName)" "OK"
        }
    })

    $btnClose.Add_Click({ $resWin.Close() })
    [void]$resWin.ShowDialog()
}

function global:Open-ManageIpProfilesDialog {
    $dlg = New-Object System.Windows.Window
    $dlg.Title = "Gerenciar Perfis Rapidos de IP / VLAN"
    $dlg.Width = 540
    $dlg.Height = 440
    $dlg.WindowStartupLocation = "CenterOwner"
    $dlg.Owner = $Window
    $dlg.Background = "#1E222A"
    $dlg.Foreground = "#E5E7EB"
    $dlg.ResizeMode = "NoResize"

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = "16"
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = "Auto"
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = "*"
    $r3 = New-Object System.Windows.Controls.RowDefinition; $r3.Height = "Auto"
    [void]$grid.RowDefinitions.Add($r1)
    [void]$grid.RowDefinitions.Add($r2)
    [void]$grid.RowDefinitions.Add($r3)

    $lblTop = New-Object System.Windows.Controls.TextBlock
    $lblTop.Text = "Seus Perfis Salvos (arquivo: ip_profiles.json)"
    $lblTop.FontWeight = "Bold"
    $lblTop.Foreground = "#3B82F6"
    $lblTop.FontSize = 14
    $lblTop.Margin = "0,0,0,10"
    [System.Windows.Controls.Grid]::SetRow($lblTop, 0)
    [void]$grid.Children.Add($lblTop)

    $listBox = New-Object System.Windows.Controls.ListBox
    $listBox.Background = "#161920"
    $listBox.Foreground = "#E5E7EB"
    $listBox.BorderBrush = "#3E4451"
    $listBox.FontFamily = "Consolas"
    $listBox.FontSize = 12
    [System.Windows.Controls.Grid]::SetRow($listBox, 1)
    [void]$grid.Children.Add($listBox)

    $script:CurrentProfiles = [System.Collections.ArrayList]@(Get-IpProfiles)

    $refreshList = {
        $listBox.Items.Clear()
        foreach ($p in $script:CurrentProfiles) {
            [void]$listBox.Items.Add("$($p.Name)  -->  $($p.IP) / $($p.Mask) (GW: $($p.Gateway))")
        }
    }
    & $refreshList

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = "0,12,0,0"
    [System.Windows.Controls.Grid]::SetRow($btnRow, 2)

    $btnAdd = New-Object System.Windows.Controls.Button
    $btnAdd.Content = "+ Novo Perfil"
    $btnAdd.Padding = "12,6"
    $btnAdd.Margin = "0,0,8,0"
    $btnAdd.Background = "#2B579A"
    $btnAdd.Foreground = "#FFFFFF"
    $btnAdd.FontWeight = "Bold"
    $btnAdd.Add_Click({
        $newP = Show-InputDialog -Title "Adicionar Novo Perfil de IP" -Fields @(
            @{Name="Name"; Label="Nome do Perfil (ex: VLAN Cameras 10.20):"; Type="Text"},
            @{Name="IP"; Label="Endereco IPv4:"; Type="Text"},
            @{Name="Mask"; Label="Mascara de Sub-rede:"; Type="Text"; Default="255.255.255.0"},
            @{Name="Gateway"; Label="Gateway Padrao (Opcional):"; Type="Text"},
            @{Name="DNS"; Label="DNS Primaria (Opcional):"; Type="Text"; Default="8.8.8.8"}
        )
        if ($newP -and $newP.Name -and $newP.IP) {
            [void]$script:CurrentProfiles.Add([PSCustomObject]@{
                Name    = $newP.Name
                IP      = $newP.IP
                Mask    = if ($newP.Mask) { $newP.Mask } else { "255.255.255.0" }
                Gateway = $newP.Gateway
                DNS     = $newP.DNS
            })
            Save-IpProfiles -Profiles @($script:CurrentProfiles)
            & $refreshList
            Write-AppLog "Perfil '$($newP.Name)' salvo." "OK"
        }
    })

    $btnDel = New-Object System.Windows.Controls.Button
    $btnDel.Content = "Remover Selecionado"
    $btnDel.Padding = "12,6"
    $btnDel.Margin = "0,0,8,0"
    $btnDel.Background = "#282C34"
    $btnDel.Foreground = "#FCA5A5"
    $btnDel.Add_Click({
        if ($listBox.SelectedIndex -ge 0) {
            $script:CurrentProfiles.RemoveAt($listBox.SelectedIndex)
            Save-IpProfiles -Profiles @($script:CurrentProfiles)
            & $refreshList
        }
    })

    $btnClose = New-Object System.Windows.Controls.Button
    $btnClose.Content = "Concluir"
    $btnClose.Padding = "14,6"
    $btnClose.Background = "#282C34"
    $btnClose.Foreground = "#FFFFFF"
    $btnClose.Add_Click({ $dlg.Close() })

    [void]$btnRow.Children.Add($btnAdd)
    [void]$btnRow.Children.Add($btnDel)
    [void]$btnRow.Children.Add($btnClose)
    [void]$grid.Children.Add($btnRow)

    $dlg.Content = $grid
    [void]$dlg.ShowDialog()
}

function global:Open-ManageSwitchesDialog {
    $dlg = New-Object System.Windows.Window
    $dlg.Title = "Gerenciar Switches SNMP (Rastreador de MAC)"
    $dlg.Width = 540
    $dlg.Height = 440
    $dlg.WindowStartupLocation = "CenterOwner"
    $dlg.Owner = $Window
    $dlg.Background = "#1E222A"
    $dlg.Foreground = "#E5E7EB"
    $dlg.ResizeMode = "NoResize"

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = "16"
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = "Auto"
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = "*"
    $r3 = New-Object System.Windows.Controls.RowDefinition; $r3.Height = "Auto"
    [void]$grid.RowDefinitions.Add($r1)
    [void]$grid.RowDefinitions.Add($r2)
    [void]$grid.RowDefinitions.Add($r3)

    $lblTop = New-Object System.Windows.Controls.TextBlock
    $lblTop.Text = "Switches Cadastrados para Busca SNMP (arquivo: switches.json)"
    $lblTop.FontWeight = "Bold"
    $lblTop.Foreground = "#3B82F6"
    $lblTop.FontSize = 14
    $lblTop.Margin = "0,0,0,10"
    [System.Windows.Controls.Grid]::SetRow($lblTop, 0)
    [void]$grid.Children.Add($lblTop)

    $listBox = New-Object System.Windows.Controls.ListBox
    $listBox.Background = "#161920"
    $listBox.Foreground = "#E5E7EB"
    $listBox.BorderBrush = "#3E4451"
    $listBox.FontFamily = "Consolas"
    $listBox.FontSize = 12
    [System.Windows.Controls.Grid]::SetRow($listBox, 1)
    [void]$grid.Children.Add($listBox)

    $script:CurrentSwitches = [System.Collections.ArrayList]@(Get-SwitchInventory)

    $refreshList = {
        $listBox.Items.Clear()
        foreach ($sw in $script:CurrentSwitches) {
            [void]$listBox.Items.Add("$($sw.Name)  -->  $($sw.IP) (Community: $($sw.Community))")
        }
    }
    & $refreshList

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.HorizontalAlignment = "Right"
    $btnRow.Margin = "0,12,0,0"
    [System.Windows.Controls.Grid]::SetRow($btnRow, 2)

    $btnAdd = New-Object System.Windows.Controls.Button
    $btnAdd.Content = "+ Adicionar Switch"
    $btnAdd.Padding = "12,6"
    $btnAdd.Margin = "0,0,8,0"
    $btnAdd.Background = "#2B579A"
    $btnAdd.Foreground = "#FFFFFF"
    $btnAdd.FontWeight = "Bold"
    $btnAdd.Add_Click({
        $newSw = Show-InputDialog -Title "Adicionar Switch Gerenciavel" -Fields @(
            @{Name="Name"; Label="Nome / Localizacao do Switch (ex: Switch Restaurante):"; Type="Text"},
            @{Name="IP"; Label="IP de Gerencia do Switch:"; Type="Text"},
            @{Name="Community"; Label="Comunidade SNMP v1/v2c (Padrao: public):"; Type="Text"; Default="public"}
        )
        if ($newSw -and $newSw.Name -and $newSw.IP) {
            [void]$script:CurrentSwitches.Add([PSCustomObject]@{
                Name      = $newSw.Name
                IP        = $newSw.IP
                Community = if ($newSw.Community) { $newSw.Community } else { "public" }
            })
            Save-SwitchInventory -Switches @($script:CurrentSwitches)
            & $refreshList
            Write-AppLog "Switch '$($newSw.Name)' adicionado." "OK"
        }
    })

    $btnDel = New-Object System.Windows.Controls.Button
    $btnDel.Content = "Remover Selecionado"
    $btnDel.Padding = "12,6"
    $btnDel.Margin = "0,0,8,0"
    $btnDel.Background = "#282C34"
    $btnDel.Foreground = "#FCA5A5"
    $btnDel.Add_Click({
        if ($listBox.SelectedIndex -ge 0) {
            $script:CurrentSwitches.RemoveAt($listBox.SelectedIndex)
            Save-SwitchInventory -Switches @($script:CurrentSwitches)
            & $refreshList
        }
    })

    $btnClose = New-Object System.Windows.Controls.Button
    $btnClose.Content = "Concluir"
    $btnClose.Padding = "14,6"
    $btnClose.Background = "#282C34"
    $btnClose.Foreground = "#FFFFFF"
    $btnClose.Add_Click({ $dlg.Close() })

    [void]$btnRow.Children.Add($btnAdd)
    [void]$btnRow.Children.Add($btnDel)
    [void]$btnRow.Children.Add($btnClose)
    [void]$grid.Children.Add($btnRow)

    $dlg.Content = $grid
    [void]$dlg.ShowDialog()
}

function global:Open-NicIpConfigDialog {
    param(
        [string]$NicAlias = "",
        [string]$CurrentIp = "",
        [string]$CurrentMask = "255.255.255.0",
        [string]$CurrentGw = "",
        [string]$CurrentDns = "8.8.8.8"
    )

    if (-not $NicAlias) {
        $NicAlias = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object -First 1).Name
    }
    $cleanIp = if ($CurrentIp -and $CurrentIp -notlike "Sem IP*") { ($CurrentIp -split ",")[0].Trim() } else { "" }

    $res = Show-InputDialog -Title "Configurar IP / DHCP - $NicAlias" -Fields @(
        @{Name="Nic"; Label="Nome da Interface de Rede:"; Type="Text"; Default=$NicAlias},
        @{Name="UseDhcp"; Label="Modo Automatico:"; Type="Check"; CheckText="Ativar DHCP (Remove IP Fixo e volta para automatico)"},
        @{Name="IP"; Label="Endereco IPv4 (ex: 192.168.1.50):"; Type="Text"; Default=$cleanIp},
        @{Name="Mask"; Label="Mascara de Sub-rede (ex: 255.255.255.0):"; Type="Text"; Default=$CurrentMask},
        @{Name="Gateway"; Label="Gateway Padrao (Opcional):"; Type="Text"; Default=$CurrentGw},
        @{Name="DNS"; Label="DNS Primaria (Opcional):"; Type="Text"; Default=$CurrentDns}
    )

    if ($res -and $res.Nic) {
        Invoke-AsyncTask -TaskName "Configurar Rede ($($res.Nic))" -AutoRefreshDashboard $true -Parameters @{Cfg=$res} -ScriptBlock {
            param($Cfg)
            if ($Cfg.UseDhcp) {
                Enable-AdapterDhcpClean -Alias $Cfg.Nic
            } else {
                Set-AdapterStaticClean -Alias $Cfg.Nic -IP $Cfg.IP -Mask $Cfg.Mask -Gateway $Cfg.Gateway -DNS $Cfg.DNS
            }
        }
    }
}

# ==============================================================================
# 7. INTERFACE GRAFICA WPF PRINCIPAL
# ==============================================================================
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT-AdminUtil | Console Port&#225;til de Infraestrutura Windows"
        Height="800" Width="1300" MinHeight="660" MinWidth="1080"
        WindowStartupLocation="CenterScreen" Background="#1E222A" Foreground="#ABB2BF"
        FontFamily="Segoe UI">

    <Window.Resources>
        <Style x:Key="TabPillButton" TargetType="RadioButton">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="Foreground" Value="#ABB2BF"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="16" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#323842"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2B579A"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#3B82F6"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="Foreground" Value="#E5E7EB"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#353B45"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#3B82F6"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2B579A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="MiniActionButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Padding" Value="8,2"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#2B579A"/>
            <Setter Property="BorderBrush" Value="#3B82F6"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>

        <Style x:Key="SuccessButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#065F46"/>
            <Setter Property="BorderBrush" Value="#10B981"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>

        <Style x:Key="CategoryCard" TargetType="Border">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="14"/>
            <Setter Property="Margin" Value="5"/>
        </Style>

        <Style x:Key="KpiCard" TargetType="Border">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="12"/>
            <Setter Property="Margin" Value="5"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#D1D5DB"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Margin" Value="0,5"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition x:Name="ConsoleRowDef" Height="0"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- BARRA SUPERIOR -->
        <Border Grid.Row="0" Background="#282C34" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="240"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="IT-AdminUtil" FontSize="17" FontWeight="Bold" Foreground="#3B82F6" VerticalAlignment="Center" Margin="4,0,14,0"/>
                    <RadioButton x:Name="TabDashboard" Content="0. Dashboard" Style="{StaticResource TabPillButton}" IsChecked="True"/>
                    <RadioButton x:Name="TabUsers" Content="1. Usu&#225;rios &amp; Setup" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabNetwork" Content="2. Redes &amp; Conectividade" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabMachines" Content="3. Limpeza &amp; Reparo" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabPrinters" Content="4. Impressoras &amp; Softwares" Style="{StaticResource TabPillButton}"/>
                </StackPanel>

                <Grid Grid.Column="1" VerticalAlignment="Center">
                    <TextBox x:Name="TxtSearch" Background="#1E222A" Foreground="#FFFFFF" BorderBrush="#3E4451"
                             BorderThickness="1" Padding="10,6" FontSize="12" VerticalContentAlignment="Center"/>
                    <TextBlock x:Name="TxtSearchPlaceholder" Text="Filtrar ferramentas..." Foreground="#6B7280"
                               IsHitTestVisible="False" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="12"/>
                </Grid>
            </Grid>
        </Border>

        <!-- CORPO PRINCIPAL -->
        <Grid Grid.Row="1" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- PAINEL LATERAL ESQUERDO -->
            <Border Grid.Column="0" Background="#282C34" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,10,0">
                <DockPanel LastChildFill="False">
                    <TextBlock DockPanel.Dock="Top" Text="&#9889; A&#199;&#213;ES R&#193;PIDAS" FontWeight="Bold" Foreground="#3B82F6" FontSize="12" Margin="0,0,0,10"/>

                    <Button DockPanel.Dock="Top" x:Name="BtnRefreshDash" Content="Atualizar Dashboard" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,6"/>
                    <Separator DockPanel.Dock="Top" Background="#3E4451" Margin="0,4,0,8"/>

                    <Button DockPanel.Dock="Top" x:Name="BtnLusrmgr" Content="Usu&#225;rios Locais (lusrmgr)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnNetplwiz" Content="Contas Cl&#225;ssicas (netplwiz)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnNcpa" Content="Conex&#245;es de Rede (ncpa.cpl)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnDevmgmt" Content="Gerenc. Dispositivos" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnServices" Content="Servi&#231;os (services.msc)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnPrintMgmt" Content="Gerenc. Impress&#227;o" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnGpedit" Content="Pol&#237;ticas Grupo (gpedit)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,10"/>

                    <Button DockPanel.Dock="Bottom" x:Name="BtnRunSelected" Content="&#9654; EXECUTAR SELECIONADOS" Style="{StaticResource PrimaryButton}" Padding="8,10" FontSize="12"/>
                    <Button DockPanel.Dock="Bottom" x:Name="BtnClearSelection" Content="Desmarcar Todos" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                </DockPanel>
            </Border>

            <!-- AREA CENTRAL -->
            <Border Grid.Column="1" Background="#1E222A" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="6">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <Grid x:Name="MainContentContainer">

                        <!-- ==================== ABA 0: DASHBOARD GERAL ==================== -->
                        <StackPanel x:Name="PanelDashboard" Visibility="Visible">
                            <UniformGrid Columns="4">
                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <DockPanel>
                                            <TextBlock Text="CPU &amp; TEMP" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                            <TextBlock x:Name="DashCpuTemp" Text="--" FontSize="12" FontWeight="Bold" Foreground="#10B981" HorizontalAlignment="Right"/>
                                        </DockPanel>
                                        <TextBlock x:Name="DashCpuPct" Text="-- %" FontSize="22" FontWeight="Bold" Foreground="#3B82F6" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashCpuBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#3B82F6" BorderThickness="0"/>
                                        <TextBlock x:Name="DashCpuSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="MEM&#211;RIA RAM" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashRamPct" Text="-- / -- GB" FontSize="22" FontWeight="Bold" Foreground="#10B981" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashRamBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#10B981" BorderThickness="0"/>
                                        <TextBlock x:Name="DashRamSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="DISCO SISTEMA (C:)" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashDiskPct" Text="-- / -- GB" FontSize="22" FontWeight="Bold" Foreground="#F59E0B" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashDiskBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#F59E0B" BorderThickness="0"/>
                                        <TextBlock x:Name="DashDiskSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <DockPanel>
                                            <TextBlock Text="UPTIME &amp; LAT&#202;NCIA" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                            <TextBlock x:Name="DashLatencyBadge" Text="GW: -- | Net: --" FontSize="11" FontWeight="SemiBold" Foreground="#60A5FA" HorizontalAlignment="Right"/>
                                        </DockPanel>
                                        <TextBlock x:Name="DashUptime" Text="--d --h --m" FontSize="22" FontWeight="Bold" Foreground="#E5E7EB" Margin="0,4,0,4"/>
                                        <TextBlock x:Name="DashNetStatus" Text="Verificando rede..." FontSize="11.5" FontWeight="SemiBold" Foreground="#10B981" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="DashIpMain" Text="IP: --" FontSize="11" Foreground="#9CA3AF" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </Border>
                            </UniformGrid>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <DockPanel Margin="0,0,0,8">
                                        <TextBlock Text="Interfaces de Rede, Perfis IP/VLAN &amp; DHCP" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" VerticalAlignment="Center"/>
                                        <Button x:Name="BtnManageProfiles" Content="+ Gerenciar Perfis IP" Style="{StaticResource MiniActionButton}" HorizontalAlignment="Right"/>
                                    </DockPanel>
                                    <StackPanel x:Name="DashNicContainer">
                                        <TextBlock Text="Carregando adaptadores de rede..." Foreground="#9CA3AF" FontSize="12"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="1.25*"/>
                                    <ColumnDefinition Width="1*"/>
                                </Grid.ColumnDefinitions>

                                <Border Grid.Column="0" Style="{StaticResource CategoryCard}">
                                    <StackPanel>
                                        <DockPanel Margin="0,0,0,10">
                                            <TextBlock Text="Ficha T&#233;cnica &amp; Identidade do Equipamento" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" VerticalAlignment="Center"/>
                                            <Button x:Name="BtnCopySpecs" Content="Copiar Ficha" Style="{StaticResource MiniActionButton}" HorizontalAlignment="Right"/>
                                        </DockPanel>

                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Hostname / Usu&#225;rio:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashHostUser" Grid.Column="1" Text="Carregando..." Foreground="#FFFFFF"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Dom&#237;nio / Rede:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashDomain" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Fabricante / Modelo:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashModel" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Placa-M&#227;e:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashBoard" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Serial BIOS:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashSerial" Grid.Column="1" Text="Carregando..." Foreground="#FBBF24" FontFamily="Consolas"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Processador:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashCpuFull" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB" TextWrapping="Wrap"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Placa(s) de V&#237;deo:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashGpu" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB" TextWrapping="Wrap"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Sistema Operacional:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashOs" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Bateria / Sa&#250;de:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashBattery" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                        <Grid Margin="0,3">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Estabilidade (30d):" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashCrash" Grid.Column="1" Text="Carregando..." Foreground="#10B981"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <StackPanel Grid.Column="1">
                                    <Border Style="{StaticResource CategoryCard}">
                                        <StackPanel>
                                            <TextBlock Text="Servi&#231;os Cr&#237;ticos &amp; A&#231;&#245;es R&#225;pidas" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,8"/>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Spooler Impress&#227;o:" Foreground="#D1D5DB" VerticalAlignment="Center"/>
                                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                                    <TextBlock x:Name="DashSvcSpooler" Text="--" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                    <Button x:Name="BtnDashFixSpooler" Content="Limpar Fila" Style="{StaticResource MiniActionButton}"/>
                                                </StackPanel>
                                            </DockPanel>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Windows Update:" Foreground="#D1D5DB" VerticalAlignment="Center"/>
                                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                                    <TextBlock x:Name="DashSvcWU" Text="--" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                    <Button x:Name="BtnDashToggleWU" Content="Alternar" Style="{StaticResource MiniActionButton}"/>
                                                </StackPanel>
                                            </DockPanel>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Acesso Remoto (RDP):" Foreground="#D1D5DB" VerticalAlignment="Center"/>
                                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                                    <TextBlock x:Name="DashSvcRdp" Text="--" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                                    <Button x:Name="BtnDashToggleRdp" Content="Alternar" Style="{StaticResource MiniActionButton}"/>
                                                </StackPanel>
                                            </DockPanel>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Windows Defender:" Foreground="#D1D5DB" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="DashSvcDefender" Text="--" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                            </DockPanel>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="BitLocker (C:):" Foreground="#D1D5DB" VerticalAlignment="Center"/>
                                                <TextBlock x:Name="DashBitLocker" Text="--" FontWeight="Bold" Foreground="#9CA3AF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                            </DockPanel>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CategoryCard}">
                                        <StackPanel>
                                            <TextBlock Text="Sensores SMART / Temperatura NVMe" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,6"/>
                                            <TextBlock x:Name="DashSmartList" Text="Carregando sensores..." Foreground="#10B981" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" Margin="0,0,0,8"/>

                                            <TextBlock Text="Top Processos (Mem&#243;ria):" Foreground="#9CA3AF" FontSize="11.5" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashTopProcs" Text="--" Foreground="#D1D5DB" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,6"/>

                                            <TextBlock x:Name="DashNetDetails" Text="Gateway / DNS: --" Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </Grid>
                        </StackPanel>

                        <!-- ==================== ABA 1: USUARIOS & SETUP DE MAQUINAS ==================== -->
                        <Grid x:Name="PanelUsers" Visibility="Collapsed">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Card Superior Esquerdo -->
                            <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Setup de M&#225;quinas &amp; Contas Padr&#227;o" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnExpressSetup" Content="&#9889; SETUP R&#193;PIDO EXPRESSO (Renomear + TI + Padr&#227;o)" Style="{StaticResource SuccessButton}" Margin="0,0,0,8"/>
                                    <Button x:Name="BtnRenamePC" Content="1. Renomear Computador (Atual: --)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnCreateUserTI" Content="2. Criar Usu&#225;rio TI (Privil&#233;gios de Administrador)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnCreateUserStd" Content="3. Criar Usu&#225;rio Padr&#227;o (Restrito, sem senha)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnDeleteUser" Content="4. Excluir Usu&#225;rio Local (Remove conta e arquivos)" Style="{StaticResource ModernButton}" Foreground="#FCA5A5"/>
                                </StackPanel>
                            </Border>

                            <!-- Card Superior Direito -->
                            <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Higieniza&#231;&#227;o de Contas &amp; Senhas" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Usr_CleanAccounts" Content="Limpar E-mails, Credenciais Salvas e Contas Vinculadas"/>
                                    <Button x:Name="BtnCreateUser" Content="+ Criar Usu&#225;rio Personalizado" Style="{StaticResource ModernButton}" Margin="0,10,0,6"/>
                                    <Button x:Name="BtnResetPass" Content="Resetar Senha / Desbloquear Conta Local" Style="{StaticResource ModernButton}" Margin="0,0,0,8"/>
                                    <UniformGrid Columns="2">
                                        <Button x:Name="BtnEnableBuiltInAdmin" Content="Ativar Admin Embutido" Style="{StaticResource ModernButton}" Margin="0,0,4,0"/>
                                        <Button x:Name="BtnDisableBuiltInAdmin" Content="Desativar Admin Embutido" Style="{StaticResource ModernButton}" Margin="4,0,0,0"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>

                            <!-- Card Inferior (100% da Largura) -->
                            <Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Auditoria de Contas, Grupos &amp; Pol&#237;ticas (GPO)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <UniformGrid Columns="2">
                                        <CheckBox Tag="Usr_ListLocal" Content="Listar Usu&#225;rios Locais e Status (Ativo / Bloqueado)"/>
                                        <CheckBox Tag="Usr_ListAdmins" Content="Listar Membros do Grupo Administradores"/>
                                        <CheckBox Tag="Usr_ADStatus" Content="Verificar Status de Dom&#237;nio / Confian&#231;a AD (dsregcmd)"/>
                                        <CheckBox Tag="Usr_Gpupdate" Content="For&#231;ar Atualiza&#231;&#227;o de Pol&#237;ticas de Grupo (gpupdate /force)"/>
                                        <CheckBox Tag="Usr_Gpresult" Content="Exibir Relat&#243;rio Completo de GPOs Aplicadas (gpresult /r)"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- ==================== ABA 2: REDES & CONECTIVIDADE ==================== -->
                        <UniformGrid x:Name="PanelNetwork" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Diagn&#243;stico, Status MAC &amp; Tabelas" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_CleanStatusMac" Content="Exibir Status Limpo da Rede com Endere&#231;o MAC"/>
                                    <CheckBox Tag="Net_Ipconfig" Content="Configura&#231;&#227;o Completa (ipconfig /all)"/>
                                    <CheckBox Tag="Net_Arp" Content="Exibir Tabela ARP (arp -a)"/>
                                    <CheckBox Tag="Net_Route" Content="Exibir Tabela de Rotas (route print)"/>
                                    <CheckBox Tag="Net_Netstat" Content="Listar Portas Ativas e Processos (netstat -abno)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Configura&#231;&#227;o de IP, DNS &amp; Reparo" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnConfigIP" Content="Configurar IP Est&#225;tico / DHCP" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnRestartNic" Content="Reiniciar Adaptador de Rede Espec&#237;fico" Style="{StaticResource ModernButton}" Margin="0,0,0,8"/>
                                    <CheckBox Tag="Net_FlushDns" Content="Limpar Cache DNS (ipconfig /flushdns)"/>
                                    <CheckBox Tag="Net_Renew" Content="Renovar Concess&#227;o DHCP (release + renew)"/>
                                    <CheckBox Tag="Net_Winsock" Content="Reset Completo Pilha TCP/IP e Winsock"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <DockPanel Margin="0,0,0,8">
                                        <TextBlock Text="Rastreador F&#237;sico &amp; Varredura" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" VerticalAlignment="Center"/>
                                        <Button x:Name="BtnManageSwitches" Content="Switches SNMP" Style="{StaticResource MiniActionButton}" HorizontalAlignment="Right"/>
                                    </DockPanel>
                                    <Button x:Name="BtnTraceDevice" Content="&#128269; Rastrear Dispositivo (IP / MAC / Porta Switch)" Style="{StaticResource SuccessButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnPingSweep" Content="Varredura de Rede (Ping Sweep Interativo)" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnTestPort" Content="Testar Porta TCP (3389, 445, 9100, 80...)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <CheckBox Tag="Net_TestInternet" Content="Testar Conectividade Externa (DNS Google/Cloudflare)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Unidades de Rede (SMB)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_ListShares" Content="Listar Unidades Mapeadas (net use)"/>
                                    <Button x:Name="BtnMapDrive" Content="+ Mapear Unidade de Rede" Style="{StaticResource ModernButton}" Margin="0,8,0,6"/>
                                    <Button x:Name="BtnUnmapDrive" Content="Desconectar Unidade de Rede" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 3: LIMPEZA, OTIMIZACAO & REPARO ==================== -->
                        <UniformGrid x:Name="PanelMachines" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="M&#243;dulo de Limpeza &amp; Otimiza&#231;&#227;o de RAM" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_CleanTemp" Content="1. Limpar Arquivos Tempor&#225;rios do Sistema (Temp)"/>
                                    <CheckBox Tag="Mch_CleanPrefetch" Content="2. Limpar Cache Prefetch (Arquivos Mortos)"/>
                                    <CheckBox Tag="Mch_CleanWU" Content="3. Limpar Cache de Downloads do Windows Update"/>
                                    <CheckBox Tag="Mch_EmptyRecycle" Content="4. Esvaziar Lixeira"/>
                                    <CheckBox Tag="Mch_OptRamActive" Content="5. Otimizar Mem&#243;ria RAM (Processos Ativos)"/>
                                    <CheckBox Tag="Mch_PurgeStandby" Content="6. Limpar Cache Standby da RAM (For&#231;ar Esvaziamento)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="M&#243;dulo de Reparo &amp; Integridade do Windows" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_Sfc" Content="1. SFC (System File Checker) - Corrige arquivos do sistema"/>
                                    <CheckBox Tag="Mch_Dism" Content="2. DISM - Repara a imagem base do Windows"/>
                                    <CheckBox Tag="Mch_DismSfcCombo" Content="3. DISM + SFC - Combo de Reparo Profundo (Recomendado)"/>
                                    <CheckBox Tag="Mch_Chkdsk" Content="4. CHKDSK - Verifica erros no Disco Local (C:)"/>
                                    <CheckBox Tag="Mch_TrimDefrag" Content="5. TRIM / Defrag - Otimiza SSDs e desfragmenta HDDs"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Invent&#225;rio, Hardware &amp; RDP" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_Inventory" Content="Invent&#225;rio Completo (CPU, RAM, BIOS Serial, OS, Uptime)"/>
                                    <CheckBox Tag="Mch_Smart" Content="Verificar Sa&#250;de SMART e Desgaste dos Discos"/>
                                    <CheckBox Tag="Mch_Battery" Content="Verificar Sa&#250;de da Bateria (Notebooks)"/>
                                    <UniformGrid Columns="2" Margin="0,8,0,0">
                                        <Button x:Name="BtnEnableRDP" Content="Ativar RDP + Firewall" Style="{StaticResource PrimaryButton}" Margin="0,0,4,0"/>
                                        <Button x:Name="BtnDisableRDP" Content="Desativar RDP" Style="{StaticResource ModernButton}" Margin="4,0,0,0"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Energia &amp; Shell Windows" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnRestartExplorer" Content="Reiniciar Windows Explorer (explorer.exe)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnRebootBios" Content="Reiniciar Direto na BIOS / UEFI" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnForceShutdown" Content="Desligamento For&#231;ado Imediato" Style="{StaticResource ModernButton}" Foreground="#F87171"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 4: IMPRESSORAS & SOFTWARES (WINGET) ==================== -->
                        <StackPanel x:Name="PanelPrinters" Visibility="Collapsed">
                            <UniformGrid Columns="2">
                                <Border Style="{StaticResource CategoryCard}">
                                    <StackPanel>
                                        <TextBlock Text="M&#243;dulo de Reparo de Impressoras (Spooler)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                        <CheckBox Tag="Prt_ListAll" Content="1. Listar Impressoras Instaladas, Portas e Status"/>
                                        <CheckBox Tag="Prt_SoftReset" Content="2. Reiniciar Servi&#231;o de Impress&#227;o (Soft Reset)"/>
                                        <CheckBox Tag="Prt_ClearQueue" Content="3. Limpar Fila Travada e Reiniciar (Hard Reset - RECOMENDADO)"/>
                                        <CheckBox Tag="Prt_RemoveOffline" Content="4. Remover Impressoras Fantasmas / Offline"/>
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource CategoryCard}">
                                    <StackPanel>
                                        <TextBlock Text="Impressoras de Rede (TCP/IP)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                        <Button x:Name="BtnAddIpPrinter" Content="+ Adicionar Impressora de Rede via IP (Porta 9100)" Style="{StaticResource PrimaryButton}" Margin="0,0,0,8"/>
                                        <Button x:Name="BtnTestPrinterNet" Content="Testar Comunica&#231;&#227;o Impressora (Ping + 9100/515/631/161)" Style="{StaticResource ModernButton}"/>
                                    </StackPanel>
                                </Border>
                            </UniformGrid>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <DockPanel Margin="0,0,0,8">
                                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                            <TextBlock Text="Instalador de Softwares Padr&#227;o (Winget)   " FontWeight="Bold" Foreground="#3B82F6" FontSize="14"/>
                                            <TextBlock Text="[VERDE] = J&#225; Instalado" Foreground="#10B981" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                            <TextBlock Text="[VERMELHO] = N&#227;o Instalado" Foreground="#F87171" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Button x:Name="BtnScanWinget" Content="Verificar Instalados" Style="{StaticResource MiniActionButton}" HorizontalAlignment="Right"/>
                                    </DockPanel>

                                    <UniformGrid Columns="3">
                                        <CheckBox x:Name="Chk_Wgt_Chrome" Tag="Wgt_Chrome" Content="1. Google Chrome"/>
                                        <CheckBox x:Name="Chk_Wgt_Firefox" Tag="Wgt_Firefox" Content="2. Mozilla Firefox"/>
                                        <CheckBox x:Name="Chk_Wgt_Brave" Tag="Wgt_Brave" Content="3. Brave Browser"/>
                                        <CheckBox x:Name="Chk_Wgt_WinRAR" Tag="Wgt_WinRAR" Content="4. WinRAR"/>
                                        <CheckBox x:Name="Chk_Wgt_VLC" Tag="Wgt_VLC" Content="5. VLC Media Player"/>
                                        <CheckBox x:Name="Chk_Wgt_Foxit" Tag="Wgt_Foxit" Content="6. Foxit PDF Reader"/>
                                        <CheckBox x:Name="Chk_Wgt_AnyDesk" Tag="Wgt_AnyDesk" Content="7. AnyDesk"/>
                                        <CheckBox x:Name="Chk_Wgt_Discord" Tag="Wgt_Discord" Content="8. Discord"/>
                                        <CheckBox x:Name="Chk_Wgt_Tailscale" Tag="Wgt_Tailscale" Content="9. Tailscale VPN"/>
                                        <CheckBox x:Name="Chk_Wgt_CrystalDisk" Tag="Wgt_CrystalDisk" Content="10. CrystalDiskInfo"/>
                                        <CheckBox x:Name="Chk_Wgt_Telegram" Tag="Wgt_Telegram" Content="11. Telegram"/>
                                        <CheckBox x:Name="Chk_Wgt_Bitwarden" Tag="Wgt_Bitwarden" Content="12. Bitwarden"/>
                                        <CheckBox x:Name="Chk_Wgt_Wireshark" Tag="Wgt_Wireshark" Content="13. Wireshark"/>
                                        <CheckBox x:Name="Chk_Wgt_WinSCP" Tag="Wgt_WinSCP" Content="14. WinSCP"/>
                                        <CheckBox x:Name="Chk_Wgt_MobaXterm" Tag="Wgt_MobaXterm" Content="15. MobaXterm"/>
                                        <CheckBox x:Name="Chk_Wgt_Steam" Tag="Wgt_Steam" Content="16. Steam"/>
                                        <CheckBox x:Name="Chk_Wgt_NotepadPP" Tag="Wgt_NotepadPP" Content="17. Notepad++"/>
                                        <CheckBox x:Name="Chk_Wgt_Revo" Tag="Wgt_Revo" Content="18. Revo Uninstaller"/>
                                        <CheckBox x:Name="Chk_Wgt_PuTTY" Tag="Wgt_PuTTY" Content="19. PuTTY"/>
                                        <CheckBox x:Name="Chk_Wgt_Everything" Tag="Wgt_Everything" Content="20. Everything"/>
                                        <CheckBox x:Name="Chk_Wgt_AdvIpScan" Tag="Wgt_AdvIpScan" Content="21. Advanced IP Scanner"/>
                                        <CheckBox x:Name="Chk_Wgt_HWMonitor" Tag="Wgt_HWMonitor" Content="22. HWMonitor"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                    </Grid>
                </ScrollViewer>
            </Border>
        </Grid>

        <!-- CONSOLE INTEGRADO -->
        <Border x:Name="ConsolePanel" Grid.Row="2" Background="#161920" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,0,0,8" Visibility="Collapsed">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <DockPanel Grid.Row="0" Margin="0,0,0,6">
                    <TextBlock Text="CONSOLE DE AUDITORIA (COMANDOS ACIONADOS &amp; ERROS)" FontWeight="Bold" Foreground="#9CA3AF" FontSize="11.5" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="BtnClearLog" Content="Limpar Log" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5" Margin="0,0,6,0"/>
                        <Button x:Name="BtnExportLog" Content="Exportar Log (.txt)" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5"/>
                    </StackPanel>
                </DockPanel>

                <TextBox x:Name="TxtConsole" Grid.Row="1" Background="#12141A" Foreground="#10B981"
                         FontFamily="Consolas" FontSize="12" IsReadOnly="True"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap" BorderThickness="0" Padding="6"/>
            </Grid>
        </Border>

        <!-- BARRA DE STATUS -->
        <DockPanel Grid.Row="3" Margin="2,2,2,0">
            <TextBlock x:Name="LblStatus" Text="Status: Pronto (Modo Administrador)" Foreground="#9CA3AF" FontSize="11.5" VerticalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnLastResults" Content="Ver &#218;ltimos Resultados" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5" Margin="0,0,8,0"/>
                <ToggleButton x:Name="BtnToggleConsole" Content="Mostrar Console" Background="#282C34" Foreground="#E5E7EB" BorderBrush="#3E4451" BorderThickness="1" Padding="12,4" FontSize="11.5" Cursor="Hand"/>
            </StackPanel>
        </DockPanel>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

$Controls = @{}
$XAML.SelectNodes("//*[@*[contains(translate(name(.),'n','N'),'Name')]]") | ForEach-Object {
    $name = $_.Name
    $Controls[$name] = $Window.FindName($name)
}

$script:LatestDashSnapshot = $null

$script:WingetCatalog = @{
    "Wgt_Chrome"      = "Google.Chrome"
    "Wgt_Firefox"     = "Mozilla.Firefox"
    "Wgt_Brave"       = "Brave.Brave"
    "Wgt_WinRAR"      = "RARLab.WinRAR"
    "Wgt_VLC"         = "VideoLAN.VLC"
    "Wgt_Foxit"       = "Foxit.FoxitReader"
    "Wgt_AnyDesk"     = "AnyDesk.AnyDesk"
    "Wgt_Discord"     = "Discord.Discord"
    "Wgt_Tailscale"   = "Tailscale.Tailscale"
    "Wgt_CrystalDisk" = "CrystalDewWorld.CrystalDiskInfo"
    "Wgt_Telegram"    = "Telegram.TelegramDesktop"
    "Wgt_Bitwarden"   = "Bitwarden.Bitwarden"
    "Wgt_Wireshark"   = "WiresharkFoundation.Wireshark"
    "Wgt_WinSCP"      = "WinSCP.WinSCP"
    "Wgt_MobaXterm"   = "Mobatek.MobaXterm"
    "Wgt_Steam"       = "Valve.Steam"
    "Wgt_NotepadPP"   = "Notepad++.Notepad++"
    "Wgt_Revo"        = "RevoUninstaller.RevoUninstaller"
    "Wgt_PuTTY"       = "PuTTY.PuTTY"
    "Wgt_Everything"  = "voidtools.Everything"
    "Wgt_AdvIpScan"   = "Famatech.AdvancedIPScanner"
    "Wgt_HWMonitor"   = "CPUID.HWMonitor"
}

# ==============================================================================
# 8. CONSTRUTOR DINAMICO DAS LINHAS DE PLACAS DE REDE NO DASHBOARD
# ==============================================================================
function Render-DashboardNics {
    param([array]$NicList)

    $Controls.DashNicContainer.Children.Clear()

    if (-not $NicList -or $NicList.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = "Nenhum adaptador de rede fisico detectado."
        $empty.Foreground = "#9CA3AF"
        [void]$Controls.DashNicContainer.Children.Add($empty)
        return
    }

    $profiles = Get-IpProfiles

    foreach ($nic in $NicList) {
        $rowBorder = New-Object System.Windows.Controls.Border
        $rowBorder.Background = "#1E222A"
        $rowBorder.BorderBrush = "#3E4451"
        $rowBorder.BorderThickness = "1"
        $rowBorder.CornerRadius = "6"
        $rowBorder.Padding = "10,7"
        $rowBorder.Margin = "0,0,0,6"

        $grid = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = "1.35*"
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "1.15*"
        $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = "Auto"
        [void]$grid.ColumnDefinitions.Add($c1)
        [void]$grid.ColumnDefinitions.Add($c2)
        [void]$grid.ColumnDefinitions.Add($c3)

        $spInfo = New-Object System.Windows.Controls.StackPanel
        $spInfo.VerticalAlignment = "Center"
        $spTitle = New-Object System.Windows.Controls.StackPanel
        $spTitle.Orientation = "Horizontal"

        $tbAlias = New-Object System.Windows.Controls.TextBlock
        $tbAlias.Text = $nic.Alias
        $tbAlias.FontWeight = "Bold"
        $tbAlias.FontSize = 13
        $tbAlias.Foreground = "#FFFFFF"

        $tbState = New-Object System.Windows.Controls.TextBlock
        $tbState.Text = "  [$($nic.StatusText)]"
        $tbState.FontSize = 11.5
        $tbState.FontWeight = "SemiBold"
        $tbState.Foreground = if ($nic.Connected) { "#10B981" } else { "#6B7280" }
        $tbState.VerticalAlignment = "Center"

        [void]$spTitle.Children.Add($tbAlias)
        [void]$spTitle.Children.Add($tbState)

        $tbDesc = New-Object System.Windows.Controls.TextBlock
        $tbDesc.Text = "$($nic.Description) | MAC: $($nic.MacAddress)"
        $tbDesc.FontSize = 11
        $tbDesc.Foreground = "#9CA3AF"
        $tbDesc.TextTrimming = "CharacterEllipsis"

        [void]$spInfo.Children.Add($spTitle)
        [void]$spInfo.Children.Add($tbDesc)
        [System.Windows.Controls.Grid]::SetColumn($spInfo, 0)
        [void]$grid.Children.Add($spInfo)

        $spIp = New-Object System.Windows.Controls.StackPanel
        $spIp.VerticalAlignment = "Center"

        $tbIp = New-Object System.Windows.Controls.TextBlock
        $tbIp.Text = "IP: $($nic.IPv4)"
        $tbIp.FontFamily = "Consolas"
        $tbIp.FontSize = 12.5
        $tbIp.FontWeight = "Bold"
        $tbIp.Foreground = "#E5E7EB"

        $tbMode = New-Object System.Windows.Controls.TextBlock
        $gwTxt = if ($nic.Gateway) { " | GW: $($nic.Gateway)" } else { "" }
        $tbMode.Text = "Modo: $($nic.ModeText)$gwTxt"
        $tbMode.FontSize = 11
        $tbMode.Foreground = if ($nic.DhcpEnabled) { "#3B82F6" } else { "#F59E0B" }

        [void]$spIp.Children.Add($tbIp)
        [void]$spIp.Children.Add($tbMode)
        [System.Windows.Controls.Grid]::SetColumn($spIp, 1)
        [void]$grid.Children.Add($spIp)

        $spBtns = New-Object System.Windows.Controls.StackPanel
        $spBtns.Orientation = "Horizontal"
        $spBtns.VerticalAlignment = "Center"

        $btnDhcp = New-Object System.Windows.Controls.Button
        $btnDhcp.Content = if ($nic.DhcpEnabled) { "DHCP Ativo" } else { "Ativar DHCP" }
        $btnDhcp.Padding = "10,5"
        $btnDhcp.Margin = "0,0,6,0"
        $btnDhcp.FontSize = 11.5
        $btnDhcp.Cursor = "Hand"
        $btnDhcp.Background = if ($nic.DhcpEnabled) { "#1E3A5F" } else { "#282C34" }
        $btnDhcp.Foreground = if ($nic.DhcpEnabled) { "#93C5FD" } else { "#E5E7EB" }
        $btnDhcp.BorderBrush = if ($nic.DhcpEnabled) { "#3B82F6" } else { "#3E4451" }
        $btnDhcp.Tag = $nic.Alias

        $btnDhcp.Add_Click({
            param($sender, $e)
            $targetNic = $sender.Tag.ToString()
            Invoke-AsyncTask -TaskName "Ativar DHCP ($targetNic)" -AutoRefreshDashboard $true -Parameters @{NicName=$targetNic} -ScriptBlock {
                param($NicName)
                Enable-AdapterDhcpClean -Alias $NicName
            }
        })

        $btnPresets = New-Object System.Windows.Controls.Button
        $btnPresets.Content = "Perfis IP " + [char]9662
        $btnPresets.Padding = "10,5"
        $btnPresets.Margin = "0,0,6,0"
        $btnPresets.FontSize = 11.5
        $btnPresets.Cursor = "Hand"
        $btnPresets.Background = "#282C34"
        $btnPresets.Foreground = "#E5E7EB"
        $btnPresets.BorderBrush = "#3E4451"

        $ctxMenu = New-Object System.Windows.Controls.ContextMenu
        foreach ($prof in $profiles) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = "$($prof.Name) [$($prof.IP)]"
            $mi.Tag = @{ Nic = $nic.Alias; Prof = $prof }
            $mi.Add_Click({
                param($s, $ev)
                $data = $s.Tag
                $p = $data.Prof
                Invoke-AsyncTask -TaskName "Aplicar Perfil '$($p.Name)' ($($data.Nic))" -AutoRefreshDashboard $true -Parameters @{Alias=$data.Nic; Prof=$p} -ScriptBlock {
                    param($Alias, $Prof)
                    Set-AdapterStaticClean -Alias $Alias -IP $Prof.IP -Mask $Prof.Mask -Gateway $Prof.Gateway -DNS $Prof.DNS
                }
            })
            [void]$ctxMenu.Items.Add($mi)
        }
        $btnPresets.ContextMenu = $ctxMenu
        $btnPresets.Add_Click({
            param($sender, $e)
            $sender.ContextMenu.PlacementTarget = $sender
            $sender.ContextMenu.IsOpen = $true
        })

        $btnStatic = New-Object System.Windows.Controls.Button
        $btnStatic.Content = "Definir IP Fixo"
        $btnStatic.Padding = "10,5"
        $btnStatic.FontSize = 11.5
        $btnStatic.Cursor = "Hand"
        $btnStatic.Background = if (-not $nic.DhcpEnabled) { "#2B579A" } else { "#282C34" }
        $btnStatic.Foreground = "#FFFFFF"
        $btnStatic.BorderBrush = "#3B82F6"
        $btnStatic.Tag = $nic

        $btnStatic.Add_Click({
            param($sender, $e)
            $n = $sender.Tag
            Open-NicIpConfigDialog -NicAlias $n.Alias -CurrentIp $n.IPv4 -CurrentMask $n.Mask -CurrentGw $n.Gateway -CurrentDns $(if($n.Dns){$n.Dns}else{"8.8.8.8"})
        })

        [void]$spBtns.Children.Add($btnDhcp)
        [void]$spBtns.Children.Add($btnPresets)
        [void]$spBtns.Children.Add($btnStatic)
        [System.Windows.Controls.Grid]::SetColumn($spBtns, 2)
        [void]$grid.Children.Add($spBtns)

        $rowBorder.Child = $grid
        [void]$Controls.DashNicContainer.Children.Add($rowBorder)
    }
}

# ==============================================================================
# 9. TIMER DE ATUALIZACAO DA UI
# ==============================================================================
$UiTimer = New-Object System.Windows.Threading.DispatcherTimer
$UiTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$UiTimer.Add_Tick({
    $msg = $null
    $sb = New-Object System.Text.StringBuilder
    while ($SyncHash.LogQueue.TryDequeue([ref]$msg)) {
        [void]$sb.AppendLine($msg)
    }
    if ($sb.Length -gt 0) {
        $Controls.TxtConsole.AppendText($sb.ToString())
        $Controls.TxtConsole.ScrollToEnd()
    }
    $Controls.LblStatus.Text = "Status: $($SyncHash.StatusText) | Administrador: SIM"

    $isConsoleOpen = ($Controls.BtnToggleConsole.IsChecked -eq $true)
    $errTxt = if ($SyncHash.ErrorCount -gt 0) { " ($($SyncHash.ErrorCount) erro(s))" } else { "" }
    $Controls.BtnToggleConsole.Content = if ($isConsoleOpen) { "Ocultar Console$errTxt" } else { "Mostrar Console$errTxt" }
    if ($SyncHash.ErrorCount -gt 0 -and -not $isConsoleOpen) {
        $Controls.BtnToggleConsole.BorderBrush = "#EF4444"
        $Controls.BtnToggleConsole.Foreground = "#FCA5A5"
    }

    if ($SyncHash.RefreshDashNext) {
        $SyncHash.RefreshDashNext = $false
        Update-DashboardAsync
    }

    if ($SyncHash.WingetReady -and $SyncHash.WingetStatusMap) {
        $SyncHash.WingetReady = $false
        $map = $SyncHash.WingetStatusMap
        foreach ($tag in $map.Keys) {
            $chk = $Controls["Chk_$tag"]
            if ($chk) {
                $baseName = ($chk.Content.ToString() -replace ' \[.*\]$', '')
                if ($map[$tag]) {
                    $chk.Content = "$baseName [Instalado]"
                    $chk.Foreground = "#10B981"
                } else {
                    $chk.Content = "$baseName [Nao Instalado]"
                    $chk.Foreground = "#F87171"
                }
            }
        }
    }

    if ($SyncHash.DashboardReady -and $SyncHash.DashboardData) {
        $SyncHash.DashboardReady = $false
        $d = $SyncHash.DashboardData
        $script:LatestDashSnapshot = $d

        $Controls.BtnRenamePC.Content = "1. Renomear Computador (Atual: $($d.Hostname))"

        $Controls.DashCpuPct.Text = "$($d.CpuLoad)%"
        $Controls.DashCpuBar.Value = $d.CpuLoad
        $Controls.DashCpuSub.Text = "$($d.CpuCores) | $($d.CpuName)"
        $Controls.DashCpuTemp.Text = $d.CpuTempStr
        if ($d.CpuTemp) {
            $Controls.DashCpuTemp.Foreground = if ($d.CpuTemp -ge 82) { "#EF4444" } elseif ($d.CpuTemp -ge 65) { "#F59E0B" } else { "#10B981" }
        } else {
            $Controls.DashCpuTemp.Foreground = "#9CA3AF"
        }

        $Controls.DashRamPct.Text = "$($d.RamUsed) / $($d.RamTotal) GB"
        $Controls.DashRamBar.Value = $d.RamPct
        $Controls.DashRamSub.Text = "$($d.RamPct)% em uso ($($d.RamSlots))"

        $Controls.DashDiskPct.Text = "$($d.DiskUsed) / $($d.DiskTotal) GB"
        $Controls.DashDiskBar.Value = $d.DiskPct
        $Controls.DashDiskSub.Text = "$($d.DiskFree) GB livres ($($d.DiskPct)% usado)"

        $Controls.DashUptime.Text = $d.Uptime
        $Controls.DashLatencyBadge.Text = "GW: $($d.GwLatency) | Net: $($d.WanLatency)"
        $Controls.DashNetStatus.Text = if ($d.InternetOk) { "ONLINE (Internet OK)" } else { "OFFLINE / SEM INTERNET" }
        $Controls.DashNetStatus.Foreground = if ($d.InternetOk) { "#10B981" } else { "#F87171" }
        $Controls.DashIpMain.Text = "IP: $($d.IpAddress)"

        Render-DashboardNics -NicList $d.NicList

        $Controls.DashHostUser.Text = "$($d.Hostname)  |  $($d.User)"
        $Controls.DashDomain.Text   = $d.Domain
        $Controls.DashModel.Text    = $d.Model
        $Controls.DashBoard.Text    = $d.Motherboard
        $Controls.DashSerial.Text   = $d.BiosSerial
        $Controls.DashCpuFull.Text  = $d.CpuName
        $Controls.DashGpu.Text      = $d.Gpu
        $Controls.DashOs.Text       = $d.OsCaption
        $Controls.DashBattery.Text  = $d.Battery
        $Controls.DashCrash.Text    = $d.CrashSummary
        $Controls.DashCrash.Foreground = if ($d.CrashSummary.StartsWith("0 ")) { "#10B981" } else { "#F59E0B" }

        $Controls.DashSvcSpooler.Text       = if ($d.SvcSpooler) { "ATIVO" } else { "PARADO" }
        $Controls.DashSvcSpooler.Foreground = if ($d.SvcSpooler) { "#10B981" } else { "#F87171" }

        $Controls.DashSvcWU.Text       = if ($d.SvcWU) { "ATIVO" } else { "PARADO" }
        $Controls.DashSvcWU.Foreground = if ($d.SvcWU) { "#10B981" } else { "#F59E0B" }
        $Controls.BtnDashToggleWU.Content = if ($d.SvcWU) { "Parar" } else { "Iniciar" }

        $Controls.DashSvcDefender.Text       = if ($d.SvcDefender) { "ATIVO" } else { "DESATIVADO" }
        $Controls.DashSvcDefender.Foreground = if ($d.SvcDefender) { "#10B981" } else { "#F87171" }

        $Controls.DashSvcRdp.Text       = if ($d.SvcRdp) { "ATIVADO" } else { "DESATIVADO" }
        $Controls.DashSvcRdp.Foreground = if ($d.SvcRdp) { "#3B82F6" } else { "#9CA3AF" }
        $Controls.BtnDashToggleRdp.Content = if ($d.SvcRdp) { "Desativar" } else { "Ativar" }

        $Controls.DashBitLocker.Text       = $d.BitLocker
        $Controls.DashBitLocker.Foreground = if ($d.BitLocker -like "Ativo*") { "#10B981" } else { "#9CA3AF" }

        $Controls.DashSmartList.Text  = $d.SmartSummary
        $Controls.DashTopProcs.Text   = $d.TopProcs
        $Controls.DashNetDetails.Text = "Gateway: $($d.Gateway)  |  DNS: $($d.Dns)"
    }

    if ($SyncHash.ShowResults) {
        $SyncHash.ShowResults = $false
        Show-ResultsPopup -TabsData $SyncHash.ResultTabs
    }
})
$UiTimer.Start()

# ==============================================================================
# 10. TOGGLE DO CONSOLE INFERIOR (ABRIR / FECHAR)
# ==============================================================================
$Controls.BtnToggleConsole.Add_Checked({
    $Controls.ConsoleRowDef.Height = New-Object System.Windows.GridLength(175)
    $Controls.ConsolePanel.Visibility = "Visible"
    $Controls.BtnToggleConsole.BorderBrush = "#3B82F6"
    $Controls.BtnToggleConsole.Foreground = "#FFFFFF"
})

$Controls.BtnToggleConsole.Add_Unchecked({
    $Controls.ConsoleRowDef.Height = New-Object System.Windows.GridLength(0)
    $Controls.ConsolePanel.Visibility = "Collapsed"
})

# ==============================================================================
# 11. HELPER DE DIALOGOS MODAIS DE ENTRADA
# ==============================================================================
function Show-InputDialog {
    param([string]$Title, [array]$Fields)

    $dlg = New-Object System.Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 440
    $dlg.SizeToContent = "Height"
    $dlg.WindowStartupLocation = "CenterOwner"
    $dlg.Owner = $Window
    $dlg.Background = "#1E222A"
    $dlg.Foreground = "#E5E7EB"
    $dlg.ResizeMode = "NoResize"

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = "18"
    $inputs = @{}

    foreach ($f in $Fields) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $f.Label
        $lbl.Margin = "0,6,0,3"
        $lbl.FontSize = 12.5
        [void]$stack.Children.Add($lbl)

        if ($f.Type -eq "Check") {
            $chk = New-Object System.Windows.Controls.CheckBox
            $chk.Content = $f.CheckText
            $chk.Foreground = "#E5E7EB"
            $chk.Margin = "0,4,0,6"
            [void]$stack.Children.Add($chk)
            $inputs[$f.Name] = $chk
        } elseif ($f.Type -eq "Password") {
            $pb = New-Object System.Windows.Controls.PasswordBox
            $pb.Background = "#282C34"
            $pb.Foreground = "#FFFFFF"
            $pb.BorderBrush = "#3E4451"
            $pb.Padding = "6"
            [void]$stack.Children.Add($pb)
            $inputs[$f.Name] = $pb
        } else {
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Background = "#282C34"
            $tb.Foreground = "#FFFFFF"
            $tb.BorderBrush = "#3E4451"
            $tb.Padding = "6"
            if ($f.Default) { $tb.Text = $f.Default }
            [void]$stack.Children.Add($tb)
            $inputs[$f.Name] = $tb
        }
    }

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = "Horizontal"
    $btnPanel.HorizontalAlignment = "Right"
    $btnPanel.Margin = "0,16,0,0"

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "Cancelar"
    $btnCancel.Padding = "14,6"
    $btnCancel.Margin = "0,0,8,0"
    $btnCancel.Background = "#282C34"
    $btnCancel.Foreground = "#E5E7EB"
    $btnCancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "Confirmar"
    $btnOk.Padding = "16,6"
    $btnOk.Background = "#2B579A"
    $btnOk.Foreground = "#FFFFFF"
    $btnOk.FontWeight = "Bold"
    $btnOk.Add_Click({ $dlg.DialogResult = $true; $dlg.Close() })

    [void]$btnPanel.Children.Add($btnCancel)
    [void]$btnPanel.Children.Add($btnOk)
    [void]$stack.Children.Add($btnPanel)
    $dlg.Content = $stack

    if ($dlg.ShowDialog() -eq $true) {
        $result = @{}
        foreach ($key in $inputs.Keys) {
            $ctrl = $inputs[$key]
            if ($ctrl -is [System.Windows.Controls.CheckBox]) { $result[$key] = $ctrl.IsChecked }
            elseif ($ctrl -is [System.Windows.Controls.PasswordBox]) { $result[$key] = $ctrl.Password }
            else { $result[$key] = $ctrl.Text.Trim() }
        }
        return $result
    }
    return $null
}

# ==============================================================================
# 12. NAVEGACAO ENTRE ABAS E FILTRO DE PESQUISA
# ==============================================================================
function Set-ActiveTab {
    param([string]$ActivePanel)
    $Controls.PanelDashboard.Visibility = if ($ActivePanel -eq "Dashboard") { "Visible" } else { "Collapsed" }
    $Controls.PanelUsers.Visibility     = if ($ActivePanel -eq "Users")     { "Visible" } else { "Collapsed" }
    $Controls.PanelNetwork.Visibility   = if ($ActivePanel -eq "Network")   { "Visible" } else { "Collapsed" }
    $Controls.PanelMachines.Visibility  = if ($ActivePanel -eq "Machines")  { "Visible" } else { "Collapsed" }
    $Controls.PanelPrinters.Visibility  = if ($ActivePanel -eq "Printers")  { "Visible" } else { "Collapsed" }

    if ($ActivePanel -eq "Printers" -and -not $script:WingetScannedOnce) {
        $script:WingetScannedOnce = $true
        Scan-WingetInstalledAsync -PackageMap $script:WingetCatalog
    }
}

$Controls.TabDashboard.Add_Checked({ Set-ActiveTab "Dashboard" })
$Controls.TabUsers.Add_Checked({ Set-ActiveTab "Users" })
$Controls.TabNetwork.Add_Checked({ Set-ActiveTab "Network" })
$Controls.TabMachines.Add_Checked({ Set-ActiveTab "Machines" })
$Controls.TabPrinters.Add_Checked({ Set-ActiveTab "Printers" })

function Find-VisualChildren {
    param([System.Windows.DependencyObject]$Parent)
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        $child
        Find-VisualChildren -Parent $child
    }
}

$Controls.TxtSearch.Add_TextChanged({
    $query = $Controls.TxtSearch.Text.Trim().ToLower()
    $Controls.TxtSearchPlaceholder.Visibility = if ($query.Length -gt 0) { "Collapsed" } else { "Visible" }

    $allElements = Find-VisualChildren -Parent $Controls.MainContentContainer
    foreach ($el in $allElements) {
        if ($el -is [System.Windows.Controls.CheckBox] -or $el -is [System.Windows.Controls.Button]) {
            $text = $el.Content.ToString().ToLower()
            if ([string]::IsNullOrEmpty($query) -or $text.Contains($query)) {
                $el.Visibility = "Visible"
            } else {
                $el.Visibility = "Collapsed"
            }
        }
    }
})

# ==============================================================================
# 13. EVENTOS DO DASHBOARD, PAINEL LATERAL E CONSOLE
# ==============================================================================
$Controls.BtnRefreshDash.Add_Click({ Update-DashboardAsync })
$Controls.BtnClearLog.Add_Click({ $Controls.TxtConsole.Clear(); $SyncHash.ErrorCount = 0 })
$Controls.BtnScanWinget.Add_Click({ Scan-WingetInstalledAsync -PackageMap $script:WingetCatalog })

$Controls.BtnManageProfiles.Add_Click({
    Open-ManageIpProfilesDialog
    if ($script:LatestDashSnapshot -and $script:LatestDashSnapshot.NicList) {
        Render-DashboardNics -NicList $script:LatestDashSnapshot.NicList
    }
})

$Controls.BtnManageSwitches.Add_Click({
    Open-ManageSwitchesDialog
})

$Controls.BtnCopySpecs.Add_Click({
    $d = $script:LatestDashSnapshot
    if (-not $d) { return }
    $nicsTxt = ($d.NicList | ForEach-Object { "- $($_.Alias) ($($_.StatusText)): $($_.IPv4) [$($_.ModeText)] [MAC: $($_.MacAddress)]" }) -join "`r`n"
    $summary = @"
=== FICHA TECNICA - $($d.Hostname) ===
Usuario: $($d.User) | Rede: $($d.Domain)
Modelo: $($d.Model)
Placa-Mae: $($d.Motherboard)
Serial BIOS: $($d.BiosSerial)
Processador: $($d.CpuName) ($($d.CpuCores))
Memoria RAM: $($d.RamTotal) GB ($($d.RamSlots))
Disco C:: $($d.DiskUsed) / $($d.DiskTotal) GB ($($d.DiskFree) GB livres)
Sistema: $($d.OsCaption)
Uptime: $($d.Uptime)
Interfaces de Rede:
$nicsTxt
"@
    [System.Windows.Clipboard]::SetText($summary)
    Write-AppLog "Ficha tecnica e Serial BIOS ($($d.BiosSerial)) copiados." "OK"
})

$Controls.BtnDashFixSpooler.Add_Click({
    Invoke-AsyncTask -TaskName "Limpar Fila e Reiniciar Spooler" -AutoRefreshDashboard $true -ScriptBlock {
        Write-TaskLog "Parando Spooler, limpando PRINTERS e reiniciando servico..." "CMD"
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:WINDIR\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler
    }
})

$Controls.BtnDashToggleWU.Add_Click({
    $isRunning = ($script:LatestDashSnapshot -and $script:LatestDashSnapshot.SvcWU)
    if ($isRunning) {
        Invoke-AsyncTask -TaskName "Parar Windows Update" -AutoRefreshDashboard $true -ScriptBlock {
            Stop-Service -Name wuauserv -Force
        }
    } else {
        Invoke-AsyncTask -TaskName "Iniciar Windows Update" -AutoRefreshDashboard $true -ScriptBlock {
            Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv
        }
    }
})

$Controls.BtnDashToggleRdp.Add_Click({
    $isRdpOn = ($script:LatestDashSnapshot -and $script:LatestDashSnapshot.SvcRdp)
    if ($isRdpOn) {
        Invoke-AsyncTask -TaskName "Desativar RDP" -AutoRefreshDashboard $true -ScriptBlock {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 1
            Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"remote desktop`" new enable=No"
        }
    } else {
        Invoke-AsyncTask -TaskName "Ativar RDP e Firewall" -AutoRefreshDashboard $true -ScriptBlock {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
            Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"remote desktop`" new enable=Yes"
            Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"Área de Trabalho Remota`" new enable=Yes"
        }
    }
})

$Controls.BtnLastResults.Add_Click({
    if ($SyncHash.ResultTabs.Count -gt 0) {
        Show-ResultsPopup -TabsData $SyncHash.ResultTabs
    } else {
        Write-AppLog "Nenhum relatorio em cache. Execute uma consulta primeiro." "WARN"
    }
})

$Controls.BtnExportLog.Add_Click({
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = "Arquivo de Texto (*.txt)|*.txt"
    $sfd.FileName = "Log_Auditoria_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
    if ($sfd.ShowDialog() -eq $true) {
        $Controls.TxtConsole.Text | Out-File -FilePath $sfd.FileName -Encoding UTF8
        Write-AppLog "Log exportado para: $($sfd.FileName)" "OK"
    }
})

$Controls.BtnLusrmgr.Add_Click({ Write-AppLog "Abrindo lusrmgr.msc" "CMD"; Start-Process "lusrmgr.msc" })
$Controls.BtnNetplwiz.Add_Click({ Write-AppLog "Abrindo netplwiz.exe" "CMD"; Start-Process "netplwiz.exe" })
$Controls.BtnNcpa.Add_Click({ Write-AppLog "Abrindo ncpa.cpl" "CMD"; Start-Process "ncpa.cpl" })
$Controls.BtnDevmgmt.Add_Click({ Write-AppLog "Abrindo devmgmt.msc" "CMD"; Start-Process "devmgmt.msc" })
$Controls.BtnServices.Add_Click({ Write-AppLog "Abrindo services.msc" "CMD"; Start-Process "services.msc" })
$Controls.BtnPrintMgmt.Add_Click({ Write-AppLog "Abrindo printmanagement.msc" "CMD"; Start-Process "printmanagement.msc" })
$Controls.BtnGpedit.Add_Click({ Write-AppLog "Abrindo gpedit.msc" "CMD"; Start-Process "gpedit.msc" })

$Controls.BtnClearSelection.Add_Click({
    Find-VisualChildren -Parent $Controls.MainContentContainer | Where-Object { $_ -is [System.Windows.Controls.CheckBox] } | ForEach-Object {
        $_.IsChecked = $false
    }
})

# ==============================================================================
# 14. EVENTOS DE BOTOES DIRETOS DAS ABAS
# ==============================================================================

# --- ABA 1: SETUP DE MAQUINAS E USUARIOS ---
$Controls.BtnExpressSetup.Add_Click({
    $res = Show-InputDialog -Title "Setup Rapido Expresso (Renomear + TI + Padrao)" -Fields @(
        @{Name="Hostname"; Label="1. Novo Nome do Computador (deixe vazio para manter '$env:COMPUTERNAME'):"; Type="Text"; Default=$env:COMPUTERNAME},
        @{Name="TiUser"; Label="2. Nome do Usuario Administrador TI:"; Type="Text"; Default="TI"},
        @{Name="TiPass"; Label="Senha do Usuario TI:"; Type="Password"},
        @{Name="StdUser"; Label="3. Nome do Usuario Padrao (Sem senha):"; Type="Text"; Default="Usuario"}
    )
    if ($res) {
        Invoke-AsyncTask -TaskName "Setup Rapido Expresso" -AutoRefreshDashboard $true -Parameters @{Cfg=$res} -ScriptBlock {
            param($Cfg)
            $report = New-Object System.Text.StringBuilder
            [void]$report.AppendLine("=== RESUMO DO SETUP EXPRESSO ===")

            if ($Cfg.Hostname -and $Cfg.Hostname -ne $env:COMPUTERNAME) {
                Write-TaskLog "Renomeando computador para $($Cfg.Hostname)..." "CMD"
                Rename-Computer -NewName $Cfg.Hostname -Force -ErrorAction Stop
                [void]$report.AppendLine("[1] Hostname alterado para: $($Cfg.Hostname) (Requer reinicializacao)")
            } else {
                [void]$report.AppendLine("[1] Hostname mantido: $env:COMPUTERNAME")
            }

            if ($Cfg.TiUser) {
                Write-TaskLog "Criando usuario Administrador '$($Cfg.TiUser)'..." "CMD"
                Invoke-NativeCmd "net user `"$($Cfg.TiUser)`" `"$($Cfg.TiPass)`" /add /expires:never"
                Invoke-NativeCmd "net localgroup Administradores `"$($Cfg.TiUser)`" /add"
                Invoke-NativeCmd "net localgroup Administrators `"$($Cfg.TiUser)`" /add"
                [void]$report.AppendLine("[2] Conta Administrador '$($Cfg.TiUser)' criada com sucesso.")
            }

            if ($Cfg.StdUser) {
                Write-TaskLog "Criando usuario Padrao sem senha '$($Cfg.StdUser)'..." "CMD"
                Invoke-NativeCmd "net user `"$($Cfg.StdUser)`" `"`" /add /expires:never"
                [void]$report.AppendLine("[3] Conta Padrao '$($Cfg.StdUser)' criada (sem senha).")
            }

            Add-TaskResult -TabTitle "Setup Expresso" -Content $report.ToString()
        }
    }
})

$Controls.BtnRenamePC.Add_Click({
    $res = Show-InputDialog -Title "Renomear Computador" -Fields @(
        @{Name="NewName"; Label="Novo Hostname (Atual: $env:COMPUTERNAME):"; Type="Text"; Default=$env:COMPUTERNAME}
    )
    if ($res -and $res.NewName -and $res.NewName -ne $env:COMPUTERNAME) {
        Invoke-AsyncTask -TaskName "Renomear Computador para $($res.NewName)" -AutoRefreshDashboard $true -Parameters @{N=$res.NewName} -ScriptBlock {
            param($N)
            Write-TaskLog "Executando Rename-Computer -NewName $N -Force..." "CMD"
            Rename-Computer -NewName $N -Force
            Add-TaskResult -TabTitle "Renomear PC" -Content "Computador renomeado de '$env:COMPUTERNAME' para '$N'.`r`nReinicie a maquina para aplicar o novo nome na rede."
        }
    }
})

$Controls.BtnCreateUserTI.Add_Click({
    $res = Show-InputDialog -Title "Criar Usuario TI (Administrador)" -Fields @(
        @{Name="User"; Label="Nome da Conta TI:"; Type="Text"; Default="TI"},
        @{Name="Pass"; Label="Senha da Conta TI:"; Type="Password"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Criar Usuario TI ($($res.User))" -Parameters @{U=$res.User; P=$res.Pass} -ScriptBlock {
            param($U, $P)
            Invoke-NativeCmd "net user `"$U`" `"$P`" /add /expires:never"
            Invoke-NativeCmd "net localgroup Administradores `"$U`" /add"
            Invoke-NativeCmd "net localgroup Administrators `"$U`" /add"
        }
    }
})

$Controls.BtnCreateUserStd.Add_Click({
    $res = Show-InputDialog -Title "Criar Usuario Padrao (Sem Senha)" -Fields @(
        @{Name="User"; Label="Nome do Usuario Padrao:"; Type="Text"; Default="Usuario"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Criar Usuario Padrao ($($res.User))" -Parameters @{U=$res.User} -ScriptBlock {
            param($U)
            Invoke-NativeCmd "net user `"$U`" `"`" /add /expires:never"
        }
    }
})

$Controls.BtnDeleteUser.Add_Click({
    $res = Show-InputDialog -Title "Excluir Usuario Local e Arquivos" -Fields @(
        @{Name="User"; Label="Nome exato do Usuario Local a remover:"; Type="Text"}
    )
    if ($res -and $res.User) {
        $confirm = [System.Windows.MessageBox]::Show("ATENCAO: Isso excluira a conta '$($res.User)' e sua pasta de perfil em C:\Users\$($res.User). Deseja continuar?", "Confirmar Exclusao", "YesNo", "Warning")
        if ($confirm -eq "Yes") {
            Invoke-AsyncTask -TaskName "Excluir Usuario ($($res.User))" -Parameters @{U=$res.User} -ScriptBlock {
                param($U)
                $prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -like "*\$U" }
                if ($prof) {
                    Write-TaskLog "Removendo perfil e pasta local de '$U'..." "CMD"
                    $prof | Remove-CimInstance -ErrorAction SilentlyContinue
                }
                Invoke-NativeCmd "net user `"$U`" /delete"
            }
        }
    }
})

$Controls.BtnCreateUser.Add_Click({
    $res = Show-InputDialog -Title "Criar Usuario Personalizado" -Fields @(
        @{Name="User"; Label="Nome de Usuario:"; Type="Text"},
        @{Name="Pass"; Label="Senha:"; Type="Password"},
        @{Name="IsAdmin"; Label="Privilegios:"; Type="Check"; CheckText="Adicionar ao grupo Administradores"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Criar Usuario $($res.User)" -Parameters @{U=$res.User; P=$res.Pass; A=$res.IsAdmin} -ScriptBlock {
            param($U, $P, $A)
            Invoke-NativeCmd "net user `"$U`" `"$P`" /add /expires:never"
            if ($A) {
                Invoke-NativeCmd "net localgroup Administradores `"$U`" /add"
                Invoke-NativeCmd "net localgroup Administrators `"$U`" /add"
            }
        }
    }
})

$Controls.BtnResetPass.Add_Click({
    $res = Show-InputDialog -Title "Resetar Senha / Desbloquear Conta" -Fields @(
        @{Name="User"; Label="Nome do Usuario Local:"; Type="Text"},
        @{Name="Pass"; Label="Nova Senha (deixe vazio apenas para ativar/desbloquear):"; Type="Password"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Manutencao Conta $($res.User)" -Parameters @{U=$res.User; P=$res.Pass} -ScriptBlock {
            param($U, $P)
            Invoke-NativeCmd "net user `"$U`" /active:yes"
            if ($P) {
                Invoke-NativeCmd "net user `"$U`" `"$P`""
            }
        }
    }
})

$Controls.BtnEnableBuiltInAdmin.Add_Click({
    Invoke-AsyncTask -TaskName "Ativar Conta Administrador Embutida" -ScriptBlock {
        $admin = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%-500'").Name
        if (-not $admin) { $admin = "Administrador" }
        Invoke-NativeCmd "net user `"$admin`" /active:yes"
    }
})

$Controls.BtnDisableBuiltInAdmin.Add_Click({
    Invoke-AsyncTask -TaskName "Desativar Conta Administrador Embutida" -ScriptBlock {
        $admin = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%-500'").Name
        if (-not $admin) { $admin = "Administrador" }
        Invoke-NativeCmd "net user `"$admin`" /active:no"
    }
})

# --- ABA 2: REDES & RASTREADOR ---
$Controls.BtnConfigIP.Add_Click({ Open-NicIpConfigDialog })

$Controls.BtnRestartNic.Add_Click({
    $defaultNic = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object -First 1).Name
    $res = Show-InputDialog -Title "Reiniciar Adaptador de Rede" -Fields @(
        @{Name="Nic"; Label="Nome do Adaptador (ex: Ethernet, Wi-Fi):"; Type="Text"; Default=$defaultNic}
    )
    if ($res -and $res.Nic) {
        Invoke-AsyncTask -TaskName "Reiniciar Adaptador ($($res.Nic))" -AutoRefreshDashboard $true -Parameters @{Nic=$res.Nic} -ScriptBlock {
            param($Nic)
            Write-TaskLog "Reiniciando interface '$Nic' via Restart-NetAdapter..." "CMD"
            Restart-NetAdapter -Name $Nic -Confirm:$false
            Start-Sleep -Seconds 2
        }
    }
})

$Controls.BtnTraceDevice.Add_Click({
    $switchesList = @(Get-SwitchInventory)
    $res = Show-InputDialog -Title "Rastrear Dispositivo na Rede (IP / MAC / Porta Switch)" -Fields @(
        @{Name="Target"; Label="Informe o IP (ex: 192.168.50.142) ou MAC (ex: AA:BB:CC:DD:EE:FF):"; Type="Text"}
    )
    if ($res -and $res.Target) {
        Invoke-AsyncTask -TaskName "Rastrear Dispositivo ($($res.Target))" -Parameters @{Query=$res.Target; Switches=$switchesList} -ScriptBlock {
            param($Query, $Switches)
            $q = $Query.Trim()
            $targetIp = ""
            $targetMac = ""

            if ($q -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $targetIp = $q
                Write-TaskLog "Resolvendo MAC via Ping + ARP para IP $targetIp..." "CMD"
                $null = Test-Connection -ComputerName $targetIp -Count 1 -Quiet -ErrorAction SilentlyContinue
                $arpEntry = Get-NetNeighbor -IPAddress $targetIp -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($arpEntry -and $arpEntry.LinkLayerAddress -and $arpEntry.LinkLayerAddress -ne "00-00-00-00-00-00") {
                    $targetMac = ($arpEntry.LinkLayerAddress -replace '-', ':').ToUpper()
                }
            } else {
                $clean = ($q -replace '[^0-9a-fA-F]', '').ToUpper()
                if ($clean.Length -eq 12) {
                    $targetMac = ($clean -replace '(.{2})(?!$)', '$1:')
                    $arpEntry = Get-NetNeighbor -ErrorAction SilentlyContinue | Where-Object { ($_.LinkLayerAddress -replace '[^0-9a-fA-F]', '') -eq $clean } | Select-Object -First 1
                    if ($arpEntry) { $targetIp = $arpEntry.IPAddress }
                }
            }

            $out = New-Object System.Text.StringBuilder
            [void]$out.AppendLine("============================================================")
            [void]$out.AppendLine("RASTREAMENTO DE DISPOSITIVO NA REDE")
            [void]$out.AppendLine("============================================================")
            [void]$out.AppendLine("Entrada Pesquisada : $q")
            [void]$out.AppendLine("Endereco IPv4      : $(if($targetIp){$targetIp}else{'Nao localizado na tabela ARP local (outra VLAN)'})")
            [void]$out.AppendLine("Endereco MAC       : $(if($targetMac){$targetMac}else{'Nao resolvido (informe o MAC direto do pfSense)'})")

            if ($targetIp) {
                $dnsName = "N/D"
                try { $dnsName = ([System.Net.Dns]::GetHostEntry($targetIp)).HostName } catch {}
                [void]$out.AppendLine("Hostname DNS       : $dnsName")

                $openPorts = @()
                $probe = @{80="HTTP/Web"; 443="HTTPS/Web"; 22="SSH"; 23="Telnet"; 8291="MikroTik Winbox"; 3389="Windows RDP"; 445="Windows SMB"; 9100="Impressora"}
                foreach ($p in $probe.Keys) {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $iar = $tcp.BeginConnect($targetIp, $p, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(400, $false) -and $tcp.Connected) {
                        $tcp.EndConnect($iar)
                        $openPorts += "$p ($($probe[$p]))"
                    }
                    $tcp.Close()
                }
                [void]$out.AppendLine("Portas Abertas     : $(if($openPorts.Count -gt 0){$openPorts -join ', '}else{'Nenhuma porta padrao aberta (Celular / Cliente)'})")
            }

            if ($targetMac) {
                $oui = ($targetMac -replace ':', '').Substring(0, 6)
                $vendor = "Desconhecido / MAC Aleatorio (Privacidade Wi-Fi)"
                try {
                    $resp = Invoke-RestMethod -Uri "https://api.macvendors.com/$targetMac" -TimeoutSec 3 -ErrorAction Stop
                    if ($resp) { $vendor = $resp }
                } catch {}
                [void]$out.AppendLine("Fabricante (OUI)   : $vendor (Prefixo: $oui)")

                [void]$out.AppendLine("")
                [void]$out.AppendLine("=== BUSCA FISICA NOS SWITCHES (SNMP Bridge-MIB) ===")
                $macClean = $targetMac -replace ':', ''
                foreach ($sw in $Switches) {
                    Write-TaskLog "Consultando tabela MAC no switch $($sw.Name) ($($sw.IP))..." "CMD"
                    $portNum = Invoke-SnmpMacLookup -SwitchIp $sw.IP -Community $sw.Community -MacHexClean $macClean
                    if ($portNum -gt 0) {
                        [void]$out.AppendLine("[ENCONTRADO] $($sw.Name) ($($sw.IP))  -->  Porta Bridge / Interface ID: $portNum")
                    } else {
                        [void]$out.AppendLine("[   --     ] $($sw.Name) ($($sw.IP))  -->  MAC nao consta ou SNMP indisponivel")
                    }
                }
            }

            Add-TaskResult -TabTitle "Rastreamento ($q)" -Content $out.ToString()
        }
    }
})

$Controls.BtnPingSweep.Add_Click({
    $defaultPrefix = "192.168.1"
    if ($script:LatestDashSnapshot -and $script:LatestDashSnapshot.IpAddress -match '^(\d+\.\d+\.\d+)\.\d+') {
        $defaultPrefix = $Matches[1]
    }
    $res = Show-InputDialog -Title "Varredura de Rede (Ping Sweep)" -Fields @(
        @{Name="Subnet"; Label="Prefixo da Sub-rede (3 primeiros octetos, ex: 192.168.20):"; Type="Text"; Default=$defaultPrefix},
        @{Name="Start"; Label="Host Inicial (1 a 254):"; Type="Text"; Default="1"},
        @{Name="End"; Label="Host Final (1 a 254):"; Type="Text"; Default="254"}
    )
    if ($res -and $res.Subnet) {
        Invoke-AsyncTask -TaskName "Ping Sweep ($($res.Subnet).$($res.Start)-$($res.End))" -Parameters @{Cfg=$res} -ScriptBlock {
            param($Cfg)
            $sub = $Cfg.Subnet.TrimEnd('.')
            $s = [int]$Cfg.Start
            $e = [int]$Cfg.End
            Write-TaskLog "Varrendo faixa ${sub}.${s} ate ${sub}.${e} em paralelo..." "CMD"

            $tasks = @()
            for ($i = $s; $i -le $e; $i++) {
                $ip = "$sub.$i"
                $p = New-Object System.Net.NetworkInformation.Ping
                $tasks += [PSCustomObject]@{ IP = $ip; Task = $p.SendPingAsync($ip, 450); Pinger = $p }
            }

            $onlineHosts = @()
            foreach ($t in $tasks) {
                try {
                    $reply = $t.Task.GetAwaiter().GetResult()
                    if ($reply.Status -eq "Success") {
                        $hostName = ""
                        try { $hostName = ([System.Net.Dns]::GetHostEntry($t.IP)).HostName } catch {}
                        $ms = if ($reply.RoundtripTime -eq 0) { "<1 ms" } else { "$($reply.RoundtripTime) ms" }
                        $onlineHosts += "{0,-16} | {1,-8} | {2}" -f $t.IP, $ms, $hostName
                    }
                } catch {}
                $t.Pinger.Dispose()
            }

            $header = "=== VARREDURA DE REDE: ${sub}.${s} - ${sub}.${e} ===`r`nTotal de Hosts Ativos: $($onlineHosts.Count)`r`n`r`nIP               | Latencia | Hostname`r`n------------------------------------------------------------"
            $body = if ($onlineHosts.Count -gt 0) { $onlineHosts -join "`r`n" } else { "Nenhum host respondeu ao ICMP nesta faixa." }
            Add-TaskResult -TabTitle "Ping Sweep ($sub.0/24)" -Content "$header`r`n$body"
        }
    }
})

$Controls.BtnTestPort.Add_Click({
    $res = Show-InputDialog -Title "Testador de Porta TCP/IP" -Fields @(
        @{Name="Target"; Label="IP ou Hostname de Destino:"; Type="Text"},
        @{Name="Port"; Label="Porta TCP (ex: 3389, 445, 9100, 80, 443):"; Type="Text"; Default="3389"}
    )
    if ($res -and $res.Target -and $res.Port) {
        Invoke-AsyncTask -TaskName "Testar Porta $($res.Target):$($res.Port)" -Parameters @{T=$res.Target; P=[int]$res.Port} -ScriptBlock {
            param($T, $P)
            Write-TaskLog "Testando socket TCP em ${T}:${P}..." "CMD"
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($T, $P, $null, $null)
            $wait = $iar.AsyncWaitHandle.WaitOne(2500, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.EndConnect($iar)
                $status = "ABERTA (Conexao estabelecida com sucesso)"
            } else {
                $status = "FECHADA / BLOQUEADA / SEM RESPOSTA"
            }
            $tcp.Close()
            Add-TaskResult -TabTitle "Teste TCP ${T}:${P}" -Content "Destino: $T`r`nPorta TCP: $P`r`nResultado: $status"
        }
    }
})

$Controls.BtnMapDrive.Add_Click({
    $res = Show-InputDialog -Title "Mapear Unidade de Rede" -Fields @(
        @{Name="Letter"; Label="Letra da Unidade (ex: Z:):"; Type="Text"; Default="Z:"},
        @{Name="Path"; Label="Caminho UNC (ex: \\Servidor\Pasta):"; Type="Text"},
        @{Name="User"; Label="Usuario (Opcional - ex: DOMINIO\usuario):"; Type="Text"},
        @{Name="Pass"; Label="Senha (Opcional):"; Type="Password"}
    )
    if ($res -and $res.Letter -and $res.Path) {
        Invoke-AsyncTask -TaskName "Mapear $($res.Letter)" -Parameters @{M=$res} -ScriptBlock {
            param($M)
            if ($M.User -and $M.Pass) {
                Invoke-NativeCmd "net use $($M.Letter) `"$($M.Path)`" /user:$($M.User) $($M.Pass) /persistent:yes"
            } else {
                Invoke-NativeCmd "net use $($M.Letter) `"$($M.Path)`" /persistent:yes"
            }
        }
    }
})

$Controls.BtnUnmapDrive.Add_Click({
    $res = Show-InputDialog -Title "Desconectar Unidade de Rede" -Fields @(
        @{Name="Letter"; Label="Letra da Unidade (ex: Z: ou * para todas):"; Type="Text"; Default="Z:"}
    )
    if ($res -and $res.Letter) {
        Invoke-AsyncTask -TaskName "Desconectar $($res.Letter)" -Parameters @{L=$res.Letter} -ScriptBlock {
            param($L)
            Invoke-NativeCmd "net use $L /delete /y"
        }
    }
})

# --- ABA 3: RDP & ENERGIA ---
$Controls.BtnEnableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Ativar RDP e Firewall" -AutoRefreshDashboard $true -ScriptBlock {
        Write-TaskLog "Alterando registro fDenyTSConnections = 0" "CMD"
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
        Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"remote desktop`" new enable=Yes"
        Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"Área de Trabalho Remota`" new enable=Yes"
    }
})

$Controls.BtnDisableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Desativar RDP" -AutoRefreshDashboard $true -ScriptBlock {
        Write-TaskLog "Alterando registro fDenyTSConnections = 1" "CMD"
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 1
        Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"remote desktop`" new enable=No"
    }
})

$Controls.BtnRestartExplorer.Add_Click({
    Invoke-AsyncTask -TaskName "Reiniciar Explorer" -ScriptBlock {
        Write-TaskLog "Executando Stop-Process -Name explorer -Force" "CMD"
        Stop-Process -Name explorer -Force
    }
})

$Controls.BtnRebootBios.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show("Deseja reiniciar o computador diretamente no setup UEFI/BIOS agora?", "Confirmar Reinicializacao", "YesNo", "Warning")
    if ($confirm -eq "Yes") { shutdown.exe /r /fw /t 0 }
})

$Controls.BtnForceShutdown.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show("Deseja forcar o desligamento imediato desta maquina?", "Confirmar Desligamento", "YesNo", "Warning")
    if ($confirm -eq "Yes") { shutdown.exe /s /f /t 0 }
})

# --- ABA 4: IMPRESSORAS ---
$Controls.BtnAddIpPrinter.Add_Click({
    $res = Show-InputDialog -Title "Adicionar Impressora de Rede via IP" -Fields @(
        @{Name="Name"; Label="Nome da Impressora:"; Type="Text"},
        @{Name="IP"; Label="Endereco IP da Impressora:"; Type="Text"},
        @{Name="Driver"; Label="Nome do Driver Instalado (Padrao: Generic / Text Only):"; Type="Text"; Default="Generic / Text Only"}
    )
    if ($res -and $res.Name -and $res.IP) {
        Invoke-AsyncTask -TaskName "Instalar Impressora $($res.Name)" -Parameters @{P=$res} -ScriptBlock {
            param($P)
            $portName = "IP_$($P.IP)"
            Invoke-NativeCmd "cscript //nologo C:\Windows\System32\Printing_Admin_Scripts\pt-BR\prnport.vbs -a -r $portName -h $($P.IP) -o raw -n 9100"
            Invoke-NativeCmd "cscript //nologo C:\Windows\System32\Printing_Admin_Scripts\en-US\prnport.vbs -a -r $portName -h $($P.IP) -o raw -n 9100"
            Invoke-NativeCmd "rundll32 printui.dll,PrintUIEntry /if /b `"$($P.Name)`" /r `"$portName`" /m `"$($P.Driver)`""
        }
    }
})

$Controls.BtnTestPrinterNet.Add_Click({
    $res = Show-InputDialog -Title "Diagnosticar Impressora de Rede" -Fields @(
        @{Name="IP"; Label="Endereco IP da Impressora:"; Type="Text"}
    )
    if ($res -and $res.IP) {
        Invoke-AsyncTask -TaskName "Testar Impressora $($res.IP)" -Parameters @{IP=$res.IP} -ScriptBlock {
            param($IP)
            Write-TaskLog "Testando Ping e portas de impressao (9100, 515, 631, 161) em $IP..." "CMD"
            $ping = Test-Connection -ComputerName $IP -Count 2 -Quiet
            $lines = @("Diagnostico de Rede para Impressora: $IP", "Ping ICMP: $(if($ping){'RESPONDEU'}else{'SEM RESPOSTA'})", "")
            $ports = @{9100="RAW/JetDirect"; 515="LPR/LPD"; 631="IPP"; 161="SNMP"}
            foreach ($port in $ports.Keys) {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $iar = $tcp.BeginConnect($IP, $port, $null, $null)
                $wait = $iar.AsyncWaitHandle.WaitOne(1500, $false)
                $st = if ($wait -and $tcp.Connected) { $tcp.EndConnect($iar); "ABERTA" } else { "Fechada" }
                $tcp.Close()
                $lines += "Porta $port ($($ports[$port])): $st"
            }
            Add-TaskResult -TabTitle "Impressora $IP" -Content ($lines -join "`r`n")
        }
    }
})

# ==============================================================================
# 15. EXECUCAO EM LOTE DAS CHECKBOXES SELECIONADAS
# ==============================================================================
$Controls.BtnRunSelected.Add_Click({
    $selectedTags = Find-VisualChildren -Parent $Controls.MainContentContainer |
        Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -eq $true } |
        ForEach-Object { $_.Tag.ToString() }

    if (-not $selectedTags -or $selectedTags.Count -eq 0) {
        Write-AppLog "Nenhuma ferramenta marcada nas caixas de selecao." "WARN"
        return
    }

    $hasWinget = ($selectedTags | Where-Object { $_ -like "Wgt_*" }).Count -gt 0

    Invoke-AsyncTask -TaskName "Lote de Tarefas ($($selectedTags.Count) itens)" -AutoRefreshDashboard $true -Parameters @{Tags=$selectedTags; PkgMap=$script:WingetCatalog; HasWgt=$hasWinget} -ScriptBlock {
        param($Tags, $PkgMap, $HasWgt)

        $deg = [char]176

        foreach ($tag in $Tags) {
            if ($PkgMap.ContainsKey($tag)) {
                $pkgId = $PkgMap[$tag]
                Invoke-NativeCmd "winget install --id $pkgId -e --silent --accept-package-agreements --accept-source-agreements"
                continue
            }

            switch ($tag) {
                "Usr_CleanAccounts" {
                    Write-TaskLog "Limpando Credenciais Salvas (cmdkey) e contas vinculadas..." "CMD"
                    $creds = cmdkey /list | Select-String "Target:|Destino:"
                    foreach ($line in $creds) {
                        $target = ($line.ToString() -split ":", 2)[1].Trim()
                        if ($target) {
                            Invoke-NativeCmd "cmdkey /delete:`"$target`""
                        }
                    }
                    Get-ChildItem "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    Get-ChildItem "HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    Add-TaskResult -TabTitle "Limpeza Contas" -Content "Credenciais do Cofre do Windows (Credential Manager) e vinculos de contas Microsoft/Office do usuario atual foram limpos."
                }
                "Usr_ListLocal" {
                    Write-TaskLog "Consultando Win32_UserAccount (LocalAccount=True)..." "CMD"
                    $out = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
                        Select-Object Name, Disabled, Lockout, PasswordRequired, Description |
                        Format-Table -AutoSize | Out-String
                    Add-TaskResult -TabTitle "Usuarios Locais" -Content $out
                }
                "Usr_ListAdmins" {
                    $grp = (Get-CimInstance Win32_Group -Filter "LocalAccount=True AND SID='S-1-5-32-544'").Name
                    if (-not $grp) { $grp = "Administradores" }
                    Invoke-NativeCmd -CmdLine "net localgroup `"$grp`"" -ResultTabTitle "Grupo Administradores"
                }
                "Usr_ADStatus" { Invoke-NativeCmd -CmdLine "dsregcmd /status" -ResultTabTitle "Status Dominio / AD" }
                "Usr_Gpupdate" { Invoke-NativeCmd -CmdLine "gpupdate /force" -ResultTabTitle "GPUpdate" }
                "Usr_Gpresult" { Invoke-NativeCmd -CmdLine "gpresult /r" -ResultTabTitle "GPResult (GPOs)" }

                "Net_CleanStatusMac" {
                    Write-TaskLog "Coletando status limpo das interfaces com MAC..." "CMD"
                    $lines = Get-NetAdapter | Where-Object { $_.InterfaceDescription -notmatch "Loopback" } | ForEach-Object {
                        $ips = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -join ", "
                        $gw  = (Get-NetRoute -InterfaceIndex $_.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop -join ", "
                        $dns = (Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ", "
                        "Interface : $($_.Name) [$($_.Status)]`r`nDescricao : $($_.InterfaceDescription)`r`nMAC       : $($_.MacAddress)`r`nIPv4      : $(if($ips){$ips}else{'Sem IP'})`r`nGateway   : $(if($gw){$gw}else{'N/D'})`r`nDNS       : $(if($dns){$dns}else{'N/D'})`r`n------------------------------------------------------------"
                    }
                    Add-TaskResult -TabTitle "Status Rede & MAC" -Content ($lines -join "`r`n")
                }
                "Net_Ipconfig"     { Invoke-NativeCmd -CmdLine "ipconfig /all" -ResultTabTitle "IPConfig /all" }
                "Net_Arp"          { Invoke-NativeCmd -CmdLine "arp -a" -ResultTabTitle "Tabela ARP" }
                "Net_Route"        { Invoke-NativeCmd -CmdLine "route print" -ResultTabTitle "Tabela de Rotas" }
                "Net_Netstat"      { Invoke-NativeCmd -CmdLine "netstat -abno" -ResultTabTitle "Netstat Portas" }
                "Net_FlushDns"     { Invoke-NativeCmd -CmdLine "ipconfig /flushdns" }
                "Net_Renew"        { Invoke-NativeCmd -CmdLine "ipconfig /release && ipconfig /renew" }
                "Net_Winsock"      { Invoke-NativeCmd -CmdLine "netsh int ip reset && netsh winsock reset" }
                "Net_ListShares"   { Invoke-NativeCmd -CmdLine "net use" -ResultTabTitle "Unidades de Rede" }
                "Net_TestInternet" {
                    Write-TaskLog "Testando conectividade ICMP para 8.8.8.8 e 1.1.1.1..." "CMD"
                    $g = Test-Connection 8.8.8.8 -Count 2 -Quiet
                    $c = Test-Connection 1.1.1.1 -Count 2 -Quiet
                    Add-TaskResult -TabTitle "Teste Internet" -Content "Ping 8.8.8.8 (Google DNS): $g`r`nPing 1.1.1.1 (Cloudflare DNS): $c"
                }

                "Mch_CleanTemp" {
                    Write-TaskLog "Limpando pastas TEMP do Usuario e Windows..." "CMD"
                    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
                }
                "Mch_CleanPrefetch" {
                    Write-TaskLog "Limpando cache Prefetch (Arquivos Mortos)..." "CMD"
                    Remove-Item -Path "$env:WINDIR\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
                }
                "Mch_CleanWU" {
                    Write-TaskLog "Parando wuauserv e limpando SoftwareDistribution\Download..." "CMD"
                    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                    Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Start-Service wuauserv -ErrorAction SilentlyContinue
                }
                "Mch_EmptyRecycle" {
                    Write-TaskLog "Esvaziando Lixeira..." "CMD"
                    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                }
                "Mch_OptRamActive" {
                    Write-TaskLog "Otimizando WorkingSet dos processos ativos na RAM..." "CMD"
                    Invoke-RamStandbyPurge -PurgeStandby $false
                }
                "Mch_PurgeStandby" {
                    Write-TaskLog "Forcando esvaziamento do Cache Standby da RAM..." "CMD"
                    Invoke-RamStandbyPurge -PurgeStandby $true
                }
                "Mch_Sfc"  { Invoke-NativeCmd -CmdLine "sfc /scannow" -ResultTabTitle "SFC Scannow" }
                "Mch_Dism" { Invoke-NativeCmd -CmdLine "DISM /Online /Cleanup-Image /RestoreHealth" -ResultTabTitle "DISM RestoreHealth" }
                "Mch_DismSfcCombo" {
                    Invoke-NativeCmd -CmdLine "DISM /Online /Cleanup-Image /RestoreHealth" -ResultTabTitle "1. DISM RestoreHealth"
                    Invoke-NativeCmd -CmdLine "sfc /scannow" -ResultTabTitle "2. SFC Scannow"
                }
                "Mch_Chkdsk" {
                    Invoke-NativeCmd -CmdLine "chkdsk C: /scan" -ResultTabTitle "CHKDSK C: (Scan)"
                }
                "Mch_TrimDefrag" {
                    Write-TaskLog "Executando Optimize-Volume (TRIM / Defrag) em C:..." "CMD"
                    $outOpt = Optimize-Volume -DriveLetter C -Verbose 4>&1 | Out-String
                    Add-TaskResult -TabTitle "TRIM / Defrag C:" -Content $(if($outOpt){$outOpt}else{"Otimizacao TRIM/Defrag concluida na unidade C:."})
                }
                "Mch_Inventory" {
                    Write-TaskLog "Coletando inventario de hardware via CIM..." "CMD"
                    $cpu = (Get-CimInstance Win32_Processor).Name
                    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
                    $bios = (Get-CimInstance Win32_BIOS).SerialNumber
                    $board = Get-CimInstance Win32_BaseBoard
                    $os = Get-CimInstance Win32_OperatingSystem
                    $uptime = (Get-Date) - $os.LastBootUpTime
                    $inv = @"
Placa-Mae: $($board.Manufacturer) $($board.Product)
Processador: $cpu
Memoria RAM Total: $ram GB
Serial BIOS: $bios
Sistema Operacional: $($os.Caption) (Build $($os.BuildNumber))
Tempo Ligado (Uptime): $($uptime.Days) dias, $($uptime.Hours) horas, $($uptime.Minutes) minutos
"@
                    Add-TaskResult -TabTitle "Inventario Hardware" -Content $inv
                }
                "Mch_Smart" {
                    Write-TaskLog "Consultando status SMART e temperatura em Get-PhysicalDisk..." "CMD"
                    $disks = Get-PhysicalDisk | ForEach-Object {
                        $rel = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                        $gb = [math]::Round($_.Size / 1GB, 1)
                        "Disco: $($_.FriendlyName) ($gb GB | $($_.MediaType))`r`nSaude: $($_.HealthStatus) | Desgaste: $($rel.Wear)% | Temp: $($rel.Temperature)${deg}C | Horas Ligado: $($rel.PowerOnHours)h`r`n----------------------------------------"
                    }
                    Add-TaskResult -TabTitle "Saude Discos (SMART)" -Content ($disks -join "`r`n")
                }
                "Mch_Battery" {
                    Write-TaskLog "Consultando Win32_Battery..." "CMD"
                    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
                    $txtBat = if ($bat) {
                        "Bateria: $($bat.Name)`r`nCarga Atual: $($bat.EstimatedChargeRemaining)%`r`nStatus: $($bat.Status)"
                    } else {
                        "Nenhuma bateria detectada neste equipamento (Desktop)."
                    }
                    Add-TaskResult -TabTitle "Saude Bateria" -Content $txtBat
                }

                "Prt_ListAll" {
                    Write-TaskLog "Consultando Win32_Printer e Win32_TCPIPPrinterPort..." "CMD"
                    $prts = Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, PrinterStatus, WorkOffline | Format-Table -AutoSize | Out-String
                    $ports = Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue | Select-Object Name, HostAddress, PortNumber | Format-Table -AutoSize | Out-String
                    Add-TaskResult -TabTitle "Impressoras e Portas" -Content "=== IMPRESSORAS INSTALADAS ===`r`n$prts`r`n=== PORTAS TCP/IP ===`r`n$ports"
                }
                "Prt_SoftReset" {
                    Write-TaskLog "Reiniciando servico Spooler (Soft Reset)..." "CMD"
                    Restart-Service -Name Spooler -Force
                }
                "Prt_ClearQueue" {
                    Write-TaskLog "Parando Spooler, limpando PRINTERS e reiniciando (Hard Reset)..." "CMD"
                    Stop-Service -Name Spooler -Force
                    Remove-Item -Path "$env:WINDIR\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
                    Start-Service -Name Spooler
                }
                "Prt_RemoveOffline" {
                    Write-TaskLog "Buscando impressoras offline em Win32_Printer..." "CMD"
                    $offline = Get-CimInstance Win32_Printer | Where-Object { $_.WorkOffline -eq $true }
                    if ($offline) {
                        foreach ($p in $offline) {
                            Invoke-NativeCmd "rundll32 printui.dll,PrintUIEntry /dl /n `"$($p.Name)`" /q"
                        }
                    } else {
                        Write-TaskLog "Nenhuma impressora offline encontrada."
                    }
                }
            }
        }
    }
})

# ==============================================================================
# 16. INICIALIZACAO
# ==============================================================================
Write-AppLog "IT-AdminUtil inicializado com privilegios de Administrador." "OK"
$Window.Add_Loaded({ Update-DashboardAsync })

[void]$Window.ShowDialog()
$UiTimer.Stop()