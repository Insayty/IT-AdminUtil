<#
.SYNOPSIS
    IT-AdminUtil - Console Portatil de Administracao de TI (Estilo WinUtil)
.DESCRIPTION
    Utilitario completo em PowerShell + WPF com Dashboard de Telemetria em tempo real,
    gestao de Usuarios/AD, Redes, Manutencao de Maquinas, Impressoras/Spooler e Winget.
    Console inferior dedicado a auditoria de comandos/erros e janela popup com abas
    para exibicao de relatorios detalhados.
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

# ==============================================================================
# 2. ESTADO SINCRONIZADO ENTRE UI E RUNSPACES (THREAD-SAFE)
# ==============================================================================
$SyncHash = [hashtable]::Synchronized(@{
    LogQueue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    ResultTabs    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    ShowResults   = $false
    IsBusy        = $false
    StatusText    = "Pronto"
    DashboardData = $null
    DashboardReady = $false
})

function global:Write-AppLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
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
# 3. MOTOR DE EXECUCAO ASSINCRONA (RUNSPACES COM ESCOPO E MODULOS INJETADOS)
# ==============================================================================
function global:Invoke-AsyncTask {
    param(
        [string]$TaskName,
        [scriptblock]$ScriptBlock,
        [hashtable]$Parameters = @{}
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
        param($ScriptCodeString, $UserParams, $Sync, $TName)

        Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
        Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
        Import-Module CimCmdlets -ErrorAction SilentlyContinue

        function global:Write-TaskLog {
            param([string]$Msg, [string]$Lvl = "INFO")
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

        try {
            $localBlock = [scriptblock]::Create($ScriptCodeString)
            & $localBlock @UserParams
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Concluido: $TName")
            if ($Sync.ResultTabs.Count -gt 0) {
                $Sync.ShowResults = $true
            }
        } catch {
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [ERRO] Falha em '$TName': $($_.Exception.Message)")
        } finally {
            $Sync.IsBusy = $false
            $Sync.StatusText = "Pronto"
        }
    }

    [void]$ps.AddScript($wrapperCode).AddArgument($scriptText).AddArgument($Parameters).AddArgument($SyncHash).AddArgument($TaskName)
    $null = $ps.BeginInvoke()
}

# ==============================================================================
# 4. COLETA ASSINCRONA DEDICADA DO DASHBOARD INICIAL
# ==============================================================================
function global:Update-DashboardAsync {
    $SyncHash.StatusText = "Coletando telemetria do Dashboard..."
    Write-AppLog "Atualizando telemetria geral da maquina no Dashboard..." "CMD"

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

        try {
            $cs    = Get-CimInstance Win32_ComputerSystem
            $os    = Get-CimInstance Win32_OperatingSystem
            $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
            $bios  = Get-CimInstance Win32_BIOS
            $board = Get-CimInstance Win32_BaseBoard
            $gpus  = (Get-CimInstance Win32_VideoController).Name -join " | "
            $bat   = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue

            # RAM
            $totalRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            $freeRamGB  = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
            $usedRamGB  = [math]::Round($totalRamGB - $freeRamGB, 1)
            $ramPct     = if ($totalRamGB -gt 0) { [math]::Round(($usedRamGB / $totalRamGB) * 100, 0) } else { 0 }

            # Disco C:
            $sysDrive   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
            $diskTotal  = if ($sysDrive) { [math]::Round($sysDrive.Size / 1GB, 0) } else { 0 }
            $diskFree   = if ($sysDrive) { [math]::Round($sysDrive.FreeSpace / 1GB, 0) } else { 0 }
            $diskUsed   = $diskTotal - $diskFree
            $diskPct    = if ($diskTotal -gt 0) { [math]::Round(($diskUsed / $diskTotal) * 100, 0) } else { 0 }

            # Discos SMART
            $smartList = (Get-CimInstance Win32_DiskDrive | ForEach-Object {
                "$($_.Model) [$([math]::Round($_.Size/1GB,0))GB - $($_.Status)]"
            }) -join "`n"

            # Rede
            $nicCfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | Select-Object -First 1
            $ipAddr = if ($nicCfg.IPAddress) { ($nicCfg.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ", " } else { "Sem IP" }
            $gwAddr = if ($nicCfg.DefaultIPGateway) { $nicCfg.DefaultIPGateway -join ", " } else { "N/D" }
            $dnsAddr = if ($nicCfg.DNSServerSearchOrder) { $nicCfg.DNSServerSearchOrder -join ", " } else { "N/D" }
            $netOnline = Test-Connection 8.8.8.8 -Count 1 -Quiet

            # Uptime
            $up = (Get-Date) - $os.LastBootUpTime
            $uptimeStr = "$($up.Days)d $($up.Hours)h $($up.Minutes)m"

            # Servicos Criticos
            $spooler = (Get-Service Spooler -ErrorAction SilentlyContinue).Status -eq "Running"
            $wuauserv = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq "Running"
            $defender = (Get-Service WinDefend -ErrorAction SilentlyContinue).Status -eq "Running"
            $rdpVal = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -ErrorAction SilentlyContinue).fDenyTSConnections
            $rdpEnabled = ($rdpVal -eq 0)

            # Bateria
            $batStr = if ($bat) { "$($bat.EstimatedChargeRemaining)% ($($bat.Status))" } else { "N/A (Desktop / Sem Bateria)" }

            $Sync.DashboardData = @{
                CpuLoad      = [int]$cpu.LoadPercentage
                CpuName      = $cpu.Name.Trim()
                CpuCores     = "$($cpu.NumberOfCores) Cores / $($cpu.NumberOfLogicalProcessors) Threads"
                RamUsed      = $usedRamGB
                RamTotal     = $totalRamGB
                RamPct       = $ramPct
                DiskUsed     = $diskUsed
                DiskTotal    = $diskTotal
                DiskFree     = $diskFree
                DiskPct      = $diskPct
                SmartSummary = $smartList
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
                IpAddress    = $ipAddr
                Gateway      = $gwAddr
                Dns          = $dnsAddr
                InternetOk   = $netOnline
                SvcSpooler   = $spooler
                SvcWU        = $wuauserv
                SvcDefender  = $defender
                SvcRdp       = $rdpEnabled
            }
            $Sync.DashboardReady = $true
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Telemetria do Dashboard atualizada.")
        } catch {
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [ERRO] Falha ao carregar Dashboard: $($_.Exception.Message)")
        } finally {
            $Sync.StatusText = "Pronto"
        }
    }

    [void]$ps.AddScript($dashScript).AddArgument($SyncHash)
    $null = $ps.BeginInvoke()
}

# ==============================================================================
# 5. JANELA POPUP COM ABAS PARA EXIBICAO DOS RESULTADOS
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

# ==============================================================================
# 6. INTERFACE GRAFICA WPF PRINCIPAL (COM ABA 0: DASHBOARD GERAL)
# ==============================================================================
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT-AdminUtil | Console Port&#225;til de Infraestrutura Windows"
        Height="780" Width="1240" MinHeight="660" MinWidth="1020"
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

        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#2B579A"/>
            <Setter Property="BorderBrush" Value="#3B82F6"/>
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
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="165"/>
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
                    <RadioButton x:Name="TabUsers" Content="1. Usu&#225;rios &amp; AD" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabNetwork" Content="2. Redes &amp; Conectividade" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabMachines" Content="3. Gest&#227;o de M&#225;quinas" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabPrinters" Content="4. Impressoras &amp; Spooler" Style="{StaticResource TabPillButton}"/>
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
        <Grid Grid.Row="1" Margin="0,0,0,10">
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
                            <!-- LINHA 1: 4 CARDS DE TELEMETRIA KPI -->
                            <UniformGrid Columns="4">
                                <!-- KPI CPU -->
                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="PROCESSADOR (CPU)" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashCpuPct" Text="-- %" FontSize="22" FontWeight="Bold" Foreground="#3B82F6" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashCpuBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#3B82F6" BorderThickness="0"/>
                                        <TextBlock x:Name="DashCpuSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </Border>

                                <!-- KPI RAM -->
                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="MEM&#211;RIA RAM" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashRamPct" Text="-- / -- GB" FontSize="22" FontWeight="Bold" Foreground="#10B981" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashRamBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#10B981" BorderThickness="0"/>
                                        <TextBlock x:Name="DashRamSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>

                                <!-- KPI DISCO C: -->
                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="DISCO SISTEMA (C:)" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashDiskPct" Text="-- / -- GB" FontSize="22" FontWeight="Bold" Foreground="#F59E0B" Margin="0,4,0,4"/>
                                        <ProgressBar x:Name="DashDiskBar" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1E222A" Foreground="#F59E0B" BorderThickness="0"/>
                                        <TextBlock x:Name="DashDiskSub" Text="Carregando..." FontSize="11" Foreground="#9CA3AF" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>

                                <!-- KPI UPTIME & REDE -->
                                <Border Style="{StaticResource KpiCard}">
                                    <StackPanel>
                                        <TextBlock Text="UPTIME &amp; CONECTIVIDADE" FontSize="11" FontWeight="Bold" Foreground="#9CA3AF"/>
                                        <TextBlock x:Name="DashUptime" Text="--d --h --m" FontSize="22" FontWeight="Bold" Foreground="#E5E7EB" Margin="0,4,0,4"/>
                                        <TextBlock x:Name="DashNetStatus" Text="Verificando rede..." FontSize="11.5" FontWeight="SemiBold" Foreground="#10B981" Margin="0,2,0,0"/>
                                        <TextBlock x:Name="DashIpMain" Text="IP: --" FontSize="11" Foreground="#9CA3AF" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </Border>
                            </UniformGrid>

                            <!-- LINHA 2: FICHA TECNICA COMPLETA & STATUS DE SERVICOS/REDE -->
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="1.35*"/>
                                    <ColumnDefinition Width="1*"/>
                                </Grid.ColumnDefinitions>

                                <!-- CARD ESQUERDO: IDENTIDADE & HARDWARE -->
                                <Border Grid.Column="0" Style="{StaticResource CategoryCard}">
                                    <StackPanel>
                                        <TextBlock Text="Ficha T&#233;cnica &amp; Identidade do Equipamento" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>

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
                                            <TextBlock Text="Bateria:" Foreground="#9CA3AF" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashBattery" Grid.Column="1" Text="Carregando..." Foreground="#E5E7EB"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- CARD DIREITO: SERVICOS CRITICOS, REDE & DISCOS -->
                                <StackPanel Grid.Column="1">
                                    <Border Style="{StaticResource CategoryCard}">
                                        <StackPanel>
                                            <TextBlock Text="Servi&#231;os Cr&#237;ticos &amp; Seguran&#231;a" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,8"/>

                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Spooler de Impress&#227;o:" Foreground="#D1D5DB"/>
                                                <TextBlock x:Name="DashSvcSpooler" Text="--" FontWeight="Bold" HorizontalAlignment="Right"/>
                                            </DockPanel>
                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Windows Update (wuauserv):" Foreground="#D1D5DB"/>
                                                <TextBlock x:Name="DashSvcWU" Text="--" FontWeight="Bold" HorizontalAlignment="Right"/>
                                            </DockPanel>
                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Windows Defender Antiv&#237;rus:" Foreground="#D1D5DB"/>
                                                <TextBlock x:Name="DashSvcDefender" Text="--" FontWeight="Bold" HorizontalAlignment="Right"/>
                                            </DockPanel>
                                            <DockPanel Margin="0,3">
                                                <TextBlock Text="Acesso Remoto (RDP):" Foreground="#D1D5DB"/>
                                                <TextBlock x:Name="DashSvcRdp" Text="--" FontWeight="Bold" HorizontalAlignment="Right"/>
                                            </DockPanel>
                                        </StackPanel>
                                    </Border>

                                    <Border Style="{StaticResource CategoryCard}">
                                        <StackPanel>
                                            <TextBlock Text="Resumo de Rede &amp; Discos F&#237;sicos" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,8"/>
                                            <TextBlock x:Name="DashNetDetails" Text="Gateway / DNS: --" Foreground="#D1D5DB" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                            <TextBlock Text="Unidades F&#237;sicas (SMART):" Foreground="#9CA3AF" FontSize="11.5" FontWeight="SemiBold"/>
                                            <TextBlock x:Name="DashSmartList" Text="Carregando..." Foreground="#10B981" FontSize="11.5" FontFamily="Consolas" TextWrapping="Wrap" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </Grid>
                        </StackPanel>

                        <!-- ==================== ABA 1: USUARIOS & AD ==================== -->
                        <UniformGrid x:Name="PanelUsers" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Auditoria de Contas &amp; Grupos" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Usr_ListLocal" Content="Listar Usu&#225;rios Locais e Status (Ativo/Bloqueado)"/>
                                    <CheckBox Tag="Usr_ListAdmins" Content="Listar Membros do Grupo Administradores"/>
                                    <CheckBox Tag="Usr_ADStatus" Content="Verificar Status de Dom&#237;nio / Confian&#231;a AD"/>
                                    <Button x:Name="BtnNetplwiz" Content="Abrir Gerenciador Cl&#225;ssico (netplwiz)" Style="{StaticResource ModernButton}" Margin="0,12,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Gest&#227;o e Manuten&#231;&#227;o de Usu&#225;rios" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnCreateUser" Content="+ Criar Novo Usu&#225;rio Local" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnResetPass" Content="Resetar Senha / Desbloquear Conta Local" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                                        <Button x:Name="BtnEnableBuiltInAdmin" Content="Ativar Admin Embutido" Style="{StaticResource ModernButton}" Margin="0,0,6,0" Width="175"/>
                                        <Button x:Name="BtnDisableBuiltInAdmin" Content="Desativar Admin Embutido" Style="{StaticResource ModernButton}" Width="185"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Pol&#237;ticas de Grupo (GPO)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Usr_Gpupdate" Content="For&#231;ar Atualiza&#231;&#227;o de Pol&#237;ticas (gpupdate /force)"/>
                                    <CheckBox Tag="Usr_Gpresult" Content="Exibir Relat&#243;rio de GPOs Aplicadas (gpresult /r)"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 2: REDES & CONECTIVIDADE ==================== -->
                        <UniformGrid x:Name="PanelNetwork" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Diagn&#243;stico e Tabelas de Rede" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_Ipconfig" Content="Configura&#231;&#227;o Completa (ipconfig /all)"/>
                                    <CheckBox Tag="Net_Arp" Content="Exibir Tabela ARP (arp -a)"/>
                                    <CheckBox Tag="Net_Route" Content="Exibir Tabela de Rotas (route print)"/>
                                    <CheckBox Tag="Net_Netstat" Content="Listar Portas Ativas e Processos (netstat -abno)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Reparo e Configura&#231;&#227;o de IP" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_FlushDns" Content="Limpar Cache DNS (ipconfig /flushdns)"/>
                                    <CheckBox Tag="Net_Renew" Content="Renovar Concess&#227;o DHCP (release + renew)"/>
                                    <CheckBox Tag="Net_Winsock" Content="Reset Completo Pilha TCP/IP e Winsock"/>
                                    <Button x:Name="BtnConfigIP" Content="Configurar IP Est&#225;tico / DHCP" Style="{StaticResource PrimaryButton}" Margin="0,10,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Testes de Conectividade e Portas" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnTestPort" Content="Testar Porta TCP/IP (3389, 445, 9100, 80...)" Style="{StaticResource ModernButton}" Margin="0,0,0,8"/>
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

                        <!-- ==================== ABA 3: GESTAO DE MAQUINAS ==================== -->
                        <UniformGrid x:Name="PanelMachines" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Invent&#225;rio e Sa&#250;de de Hardware" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_Inventory" Content="Invent&#225;rio Completo (CPU, RAM, BIOS Serial, OS, Uptime)"/>
                                    <CheckBox Tag="Mch_Smart" Content="Verificar Sa&#250;de SMART e Desgaste dos Discos"/>
                                    <CheckBox Tag="Mch_Battery" Content="Verificar Sa&#250;de da Bateria (Notebooks)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Limpeza Profunda &amp; Integridade" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_CleanTemp" Content="Limpar Temp Windows, Temp Usu&#225;rio, Prefetch e Lixeira"/>
                                    <CheckBox Tag="Mch_CleanWU" Content="Limpar Cache do Windows Update (SoftwareDistribution)"/>
                                    <CheckBox Tag="Mch_Sfc" Content="Verificar Arquivos do Sistema (sfc /scannow)"/>
                                    <CheckBox Tag="Mch_Dism" Content="Reparar Imagem do Windows (DISM RestoreHealth)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Acesso Remoto (RDP)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnEnableRDP" Content="Ativar RDP + Liberar Porta 3389 no Firewall" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnDisableRDP" Content="Desativar &#193;rea de Trabalho Remota (RDP)" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Energia &amp; Shell" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnRestartExplorer" Content="Reiniciar Windows Explorer (explorer.exe)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnRebootBios" Content="Reiniciar Direto na BIOS / UEFI" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnForceShutdown" Content="Desligamento For&#231;ado Imediato" Style="{StaticResource ModernButton}" Foreground="#F87171"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 4: IMPRESSORAS & SPOOLER ==================== -->
                        <UniformGrid x:Name="PanelPrinters" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Invent&#225;rio e Diagn&#243;stico de Impress&#227;o" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Prt_ListAll" Content="Listar Impressoras, Portas (IPs) e Drivers Instalados"/>
                                    <CheckBox Tag="Prt_ClearQueue" Content="Destravar Fila (Parar Spooler, Limpar PRINTERS, Iniciar)"/>
                                    <CheckBox Tag="Prt_RemoveOffline" Content="Remover Impressoras Fantasmas / Offline"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="Impressoras de Rede (TCP/IP)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnAddIpPrinter" Content="+ Adicionar Impressora de Rede via IP (Porta 9100)" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnTestPrinterNet" Content="Testar Comunica&#231;&#227;o Impressora (Ping + 9100/515/631/161)" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}" Grid.ColumnSpan="2">
                                <StackPanel>
                                    <TextBlock Text="Instala&#231;&#227;o R&#225;pida de Programas Padr&#227;o (Winget)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,8"/>
                                    <UniformGrid Columns="3">
                                        <CheckBox Tag="Wgt_Chrome" Content="Google Chrome"/>
                                        <CheckBox Tag="Wgt_7Zip" Content="7-Zip"/>
                                        <CheckBox Tag="Wgt_AdobeReader" Content="Adobe Acrobat Reader DC"/>
                                        <CheckBox Tag="Wgt_AnyDesk" Content="AnyDesk"/>
                                        <CheckBox Tag="Wgt_RustDesk" Content="RustDesk"/>
                                        <CheckBox Tag="Wgt_VCRedist" Content="Visual C++ Redistributable AIO"/>
                                        <CheckBox Tag="Wgt_NotepadPP" Content="Notepad++"/>
                                        <CheckBox Tag="Wgt_LibreOffice" Content="LibreOffice"/>
                                        <CheckBox Tag="Wgt_VLC" Content="VLC Media Player"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                    </Grid>
                </ScrollViewer>
            </Border>
        </Grid>

        <!-- CONSOLE INTEGRADO (APENAS AUDITORIA DE COMANDOS E ERROS) -->
        <Border Grid.Row="2" Background="#161920" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <DockPanel Grid.Row="0" Margin="0,0,0,6">
                    <TextBlock Text="CONSOLE DE AUDITORIA (COMANDOS ACIONADOS &amp; ERROS)" FontWeight="Bold" Foreground="#9CA3AF" FontSize="11.5" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="BtnLastResults" Content="Ver &#218;ltimos Resultados" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5" Margin="0,0,6,0"/>
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
        <DockPanel Grid.Row="3" Margin="2,6,2,0">
            <TextBlock x:Name="LblStatus" Text="Status: Pronto (Modo Administrador)" Foreground="#9CA3AF" FontSize="11.5"/>
            <TextBlock Text="Windows Admin Toolkit | PowerShell WPF" Foreground="#6B7280" FontSize="11.5" HorizontalAlignment="Right"/>
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

# ==============================================================================
# 7. TIMER DE ATUALIZACAO DA UI (LOG, DASHBOARD E POPUP DE RESULTADOS)
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

    # Atualiza Cards do Dashboard quando os dados chegam do Runspace
    if ($SyncHash.DashboardReady -and $SyncHash.DashboardData) {
        $SyncHash.DashboardReady = $false
        $d = $SyncHash.DashboardData

        $Controls.DashCpuPct.Text = "$($d.CpuLoad)%"
        $Controls.DashCpuBar.Value = $d.CpuLoad
        $Controls.DashCpuSub.Text = $d.CpuCores

        $Controls.DashRamPct.Text = "$($d.RamUsed) / $($d.RamTotal) GB"
        $Controls.DashRamBar.Value = $d.RamPct
        $Controls.DashRamSub.Text = "$($d.RamPct)% em uso"

        $Controls.DashDiskPct.Text = "$($d.DiskUsed) / $($d.DiskTotal) GB"
        $Controls.DashDiskBar.Value = $d.DiskPct
        $Controls.DashDiskSub.Text = "$($d.DiskFree) GB livres ($($d.DiskPct)% usado)"

        $Controls.DashUptime.Text = $d.Uptime
        $Controls.DashNetStatus.Text = if ($d.InternetOk) { "ONLINE (Internet OK)" } else { "OFFLINE / SEM INTERNET" }
        $Controls.DashNetStatus.Foreground = if ($d.InternetOk) { "#10B981" } else { "#F87171" }
        $Controls.DashIpMain.Text = "IP: $($d.IpAddress)"

        $Controls.DashHostUser.Text = "$($d.Hostname)  |  $($d.User)"
        $Controls.DashDomain.Text   = $d.Domain
        $Controls.DashModel.Text    = $d.Model
        $Controls.DashBoard.Text    = $d.Motherboard
        $Controls.DashSerial.Text   = $d.BiosSerial
        $Controls.DashCpuFull.Text  = $d.CpuName
        $Controls.DashGpu.Text      = $d.Gpu
        $Controls.DashOs.Text       = $d.OsCaption
        $Controls.DashBattery.Text  = $d.Battery

        $Controls.DashSvcSpooler.Text       = if ($d.SvcSpooler) { "ATIVO" } else { "PARADO" }
        $Controls.DashSvcSpooler.Foreground = if ($d.SvcSpooler) { "#10B981" } else { "#F87171" }

        $Controls.DashSvcWU.Text       = if ($d.SvcWU) { "ATIVO" } else { "PARADO" }
        $Controls.DashSvcWU.Foreground = if ($d.SvcWU) { "#10B981" } else { "#F59E0B" }

        $Controls.DashSvcDefender.Text       = if ($d.SvcDefender) { "ATIVO" } else { "DESATIVADO" }
        $Controls.DashSvcDefender.Foreground = if ($d.SvcDefender) { "#10B981" } else { "#F87171" }

        $Controls.DashSvcRdp.Text       = if ($d.SvcRdp) { "ATIVADO" } else { "DESATIVADO" }
        $Controls.DashSvcRdp.Foreground = if ($d.SvcRdp) { "#3B82F6" } else { "#9CA3AF" }

        $Controls.DashNetDetails.Text = "Gateway: $($d.Gateway)  |  DNS: $($d.Dns)"
        $Controls.DashSmartList.Text  = $d.SmartSummary
    }

    if ($SyncHash.ShowResults) {
        $SyncHash.ShowResults = $false
        Show-ResultsPopup -TabsData $SyncHash.ResultTabs
    }
})
$UiTimer.Start()

# ==============================================================================
# 8. HELPER DE DIALOGOS MODAIS DE ENTRADA
# ==============================================================================
function Show-InputDialog {
    param([string]$Title, [array]$Fields)

    $dlg = New-Object System.Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 430
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
# 9. NAVEGACAO ENTRE ABAS E FILTRO DE PESQUISA
# ==============================================================================
function Set-ActiveTab {
    param([string]$ActivePanel)
    $Controls.PanelDashboard.Visibility = if ($ActivePanel -eq "Dashboard") { "Visible" } else { "Collapsed" }
    $Controls.PanelUsers.Visibility     = if ($ActivePanel -eq "Users")     { "Visible" } else { "Collapsed" }
    $Controls.PanelNetwork.Visibility   = if ($ActivePanel -eq "Network")   { "Visible" } else { "Collapsed" }
    $Controls.PanelMachines.Visibility  = if ($ActivePanel -eq "Machines")  { "Visible" } else { "Collapsed" }
    $Controls.PanelPrinters.Visibility  = if ($ActivePanel -eq "Printers")  { "Visible" } else { "Collapsed" }
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
# 10. EVENTOS DO PAINEL LATERAL E CONSOLE
# ==============================================================================
$Controls.BtnRefreshDash.Add_Click({ Update-DashboardAsync })
$Controls.BtnClearLog.Add_Click({ $Controls.TxtConsole.Clear() })

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
$Controls.BtnNcpa.Add_Click({ Write-AppLog "Abrindo ncpa.cpl" "CMD"; Start-Process "ncpa.cpl" })
$Controls.BtnDevmgmt.Add_Click({ Write-AppLog "Abrindo devmgmt.msc" "CMD"; Start-Process "devmgmt.msc" })
$Controls.BtnServices.Add_Click({ Write-AppLog "Abrindo services.msc" "CMD"; Start-Process "services.msc" })
$Controls.BtnPrintMgmt.Add_Click({ Write-AppLog "Abrindo printmanagement.msc" "CMD"; Start-Process "printmanagement.msc" })
$Controls.BtnGpedit.Add_Click({ Write-AppLog "Abrindo gpedit.msc" "CMD"; Start-Process "gpedit.msc" })
$Controls.BtnNetplwiz.Add_Click({ Write-AppLog "Abrindo netplwiz.exe" "CMD"; Start-Process "netplwiz.exe" })

$Controls.BtnClearSelection.Add_Click({
    Find-VisualChildren -Parent $Controls.MainContentContainer | Where-Object { $_ -is [System.Windows.Controls.CheckBox] } | ForEach-Object {
        $_.IsChecked = $false
    }
})

# ==============================================================================
# 11. EVENTOS DE BOTOES DIRETOS
# ==============================================================================

# --- ABA 1: USUARIOS ---
$Controls.BtnCreateUser.Add_Click({
    $res = Show-InputDialog -Title "Criar Novo Usuario Local" -Fields @(
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

# --- ABA 2: REDES ---
$Controls.BtnConfigIP.Add_Click({
    $defaultNic = (Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionStatus=2" -ErrorAction SilentlyContinue | Select-Object -First 1).NetConnectionID
    $res = Show-InputDialog -Title "Configurar IP Estatico ou DHCP" -Fields @(
        @{Name="Nic"; Label="Nome da Interface de Rede:"; Type="Text"; Default=$defaultNic},
        @{Name="UseDhcp"; Label="Modo Automatico:"; Type="Check"; CheckText="Ativar DHCP (Ignora campos abaixo)"},
        @{Name="IP"; Label="Endereco IP (ex: 192.168.1.50):"; Type="Text"},
        @{Name="Mask"; Label="Mascara de Sub-rede (ex: 255.255.255.0):"; Type="Text"; Default="255.255.255.0"},
        @{Name="Gateway"; Label="Gateway Padrao (ex: 192.168.1.1):"; Type="Text"},
        @{Name="DNS"; Label="DNS Primaria (ex: 8.8.8.8):"; Type="Text"; Default="8.8.8.8"}
    )
    if ($res -and $res.Nic) {
        Invoke-AsyncTask -TaskName "Configurar Rede ($($res.Nic))" -Parameters @{Cfg=$res} -ScriptBlock {
            param($Cfg)
            if ($Cfg.UseDhcp) {
                Invoke-NativeCmd "netsh interface ip set address name=`"$($Cfg.Nic)`" source=dhcp"
                Invoke-NativeCmd "netsh interface ip set dns name=`"$($Cfg.Nic)`" source=dhcp"
            } else {
                if ($Cfg.Gateway) {
                    Invoke-NativeCmd "netsh interface ip set address name=`"$($Cfg.Nic)`" static $($Cfg.IP) $($Cfg.Mask) $($Cfg.Gateway) 1"
                } else {
                    Invoke-NativeCmd "netsh interface ip set address name=`"$($Cfg.Nic)`" static $($Cfg.IP) $($Cfg.Mask)"
                }
                if ($Cfg.DNS) {
                    Invoke-NativeCmd "netsh interface ip set dns name=`"$($Cfg.Nic)`" static $($Cfg.DNS) primary"
                }
            }
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

# --- ABA 3: GESTAO DE MAQUINAS ---
$Controls.BtnEnableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Ativar RDP e Firewall" -ScriptBlock {
        Write-TaskLog "Alterando registro fDenyTSConnections = 0" "CMD"
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
        Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"remote desktop`" new enable=Yes"
        Invoke-NativeCmd "netsh advfirewall firewall set rule group=`"Área de Trabalho Remota`" new enable=Yes"
    }
})

$Controls.BtnDisableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Desativar RDP" -ScriptBlock {
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
# 12. EXECUCAO EM LOTE DAS CHECKBOXES SELECIONADAS
# ==============================================================================
$Controls.BtnRunSelected.Add_Click({
    $selectedTags = Find-VisualChildren -Parent $Controls.MainContentContainer |
        Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -eq $true } |
        ForEach-Object { $_.Tag.ToString() }

    if (-not $selectedTags -or $selectedTags.Count -eq 0) {
        Write-AppLog "Nenhuma ferramenta marcada nas caixas de selecao." "WARN"
        return
    }

    Invoke-AsyncTask -TaskName "Lote de Tarefas ($($selectedTags.Count) itens)" -Parameters @{Tags=$selectedTags} -ScriptBlock {
        param($Tags)

        $wingetMap = @{
            "Wgt_Chrome"      = "Google.Chrome"
            "Wgt_7Zip"        = "7zip.7zip"
            "Wgt_AdobeReader" = "Adobe.Acrobat.Reader.64-bit"
            "Wgt_AnyDesk"     = "AnyDesk.AnyDesk"
            "Wgt_RustDesk"    = "RustDesk.RustDesk"
            "Wgt_VCRedist"    = "Microsoft.VCRedist.2015+.x64"
            "Wgt_NotepadPP"   = "Notepad++.Notepad++"
            "Wgt_LibreOffice" = "TheDocumentFoundation.LibreOffice"
            "Wgt_VLC"         = "VideoLAN.VLC"
        }

        foreach ($tag in $Tags) {
            if ($wingetMap.ContainsKey($tag)) {
                $pkgId = $wingetMap[$tag]
                Invoke-NativeCmd "winget install --id $pkgId -e --silent --accept-package-agreements --accept-source-agreements"
                continue
            }

            switch ($tag) {
                # ABA 1
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
                "Usr_ADStatus" {
                    Invoke-NativeCmd -CmdLine "dsregcmd /status" -ResultTabTitle "Status Dominio / AD"
                }
                "Usr_Gpupdate" {
                    Invoke-NativeCmd -CmdLine "gpupdate /force" -ResultTabTitle "GPUpdate"
                }
                "Usr_Gpresult" {
                    Invoke-NativeCmd -CmdLine "gpresult /r" -ResultTabTitle "GPResult (GPOs)"
                }

                # ABA 2
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

                # ABA 3
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
                    Write-TaskLog "Consultando status SMART em Win32_DiskDrive..." "CMD"
                    $disks = Get-CimInstance Win32_DiskDrive | ForEach-Object {
                        $gb = [math]::Round($_.Size / 1GB, 1)
                        "Modelo: $($_.Model)`r`nCapacidade: $gb GB | Interface: $($_.InterfaceType) | Status SMART: $($_.Status)`r`n----------------------------------------"
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
                "Mch_CleanTemp" {
                    Write-TaskLog "Limpando pastas TEMP, Prefetch e Lixeira..." "CMD"
                    $paths = @("$env:TEMP\*", "$env:WINDIR\Temp\*", "$env:WINDIR\Prefetch\*")
                    foreach ($p in $paths) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
                    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                }
                "Mch_CleanWU" {
                    Write-TaskLog "Parando wuauserv e limpando SoftwareDistribution\Download..." "CMD"
                    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                    Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Start-Service wuauserv -ErrorAction SilentlyContinue
                }
                "Mch_Sfc"  { Invoke-NativeCmd -CmdLine "sfc /scannow" -ResultTabTitle "SFC Scannow" }
                "Mch_Dism" { Invoke-NativeCmd -CmdLine "DISM /Online /Cleanup-Image /RestoreHealth" -ResultTabTitle "DISM RestoreHealth" }

                # ABA 4
                "Prt_ListAll" {
                    Write-TaskLog "Consultando Win32_Printer e Win32_TCPIPPrinterPort..." "CMD"
                    $prts = Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, WorkOffline | Format-Table -AutoSize | Out-String
                    $ports = Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue | Select-Object Name, HostAddress, PortNumber | Format-Table -AutoSize | Out-String
                    Add-TaskResult -TabTitle "Impressoras e Portas" -Content "=== IMPRESSORAS INSTALADAS ===`r`n$prts`r`n=== PORTAS TCP/IP ===`r`n$ports"
                }
                "Prt_ClearQueue" {
                    Write-TaskLog "Reiniciando servico Spooler e limpando fila PRINTERS..." "CMD"
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
# 13. INICIALIZACAO
# ==============================================================================
Write-AppLog "IT-AdminUtil inicializado com privilegios de Administrador." "OK"
$Window.Add_Loaded({ Update-DashboardAsync })

[void]$Window.ShowDialog()
$UiTimer.Stop()
