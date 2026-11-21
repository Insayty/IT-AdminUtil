<#
.SYNOPSIS
    IT-AdminUtil - Ferramenta Portátil de Administração de TI (Estilo WinUtil)
.DESCRIPTION
    Utilitário completo em PowerShell + WPF para gestão de Usuários/AD, Redes,
    Manutenção de Máquinas, Impressoras/Spooler e Deploy via Winget.
    Compatível com execução direta em memória: irm <URL> | iex
#>

# ==============================================================================
# 1. AUTO-ELEVAÇÃO UAC (COMPATÍVEL COM ARQUIVO LOCAL E EXECUÇÃO EM MEMÓRIA IEX)
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } else {
        # Se executado via irm | iex, materializa temporariamente para elevar
        $tempScript = "$env:TEMP\ITAdminUtil_Elevated.ps1"
        $MyInvocation.MyCommand.ScriptContents | Out-File -FilePath $tempScript -Encoding UTF8 -Force
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$tempScript'; Remove-Item '$tempScript' -Force`"" -Verb RunAs
    }
    exit
}

# Configuração de Encoding para evitar quebra de acentos em saídas de CMD/PowerShell
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
    LogQueue   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    IsBusy     = $false
    StatusText = "Pronto"
})

function Write-AppLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = switch ($Level) {
        "ERR"  { "[ERRO]" }
        "WARN" { "[AVISO]" }
        "OK"   { "[OK]" }
        default { "[INFO]" }
    }
    $SyncHash.LogQueue.Enqueue("[$timestamp] $prefix $Message")
}

# ==============================================================================
# 3. MOTOR DE EXECUÇÃO ASSÍNCRONA (RUNSPACES)
# ==============================================================================
function Invoke-AsyncTask {
    param(
        [string]$TaskName,
        [scriptblock]$ScriptBlock,
        [hashtable]$Parameters = @{}
    )

    if ($SyncHash.IsBusy) {
        Write-AppLog "Aguarde a conclusão da tarefa atual antes de iniciar outra." "WARN"
        return
    }

    $SyncHash.IsBusy = $true
    $SyncHash.StatusText = "Executando: $TaskName..."
    Write-AppLog ">>> Iniciando: $TaskName"

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("SyncHash", $SyncHash)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    # Wrapper que garante encoding CP850 -> UTF8 para comandos nativos do Windows
    $wrapperCode = {
        param($UserScript, $UserParams, $Sync)
        function Write-TaskLog {
            param([string]$Msg, [string]$Lvl = "INFO")
            $ts = (Get-Date).ToString("HH:mm:ss")
            $Sync.LogQueue.Enqueue("[$ts] [$Lvl] $Msg")
        }
        function Invoke-NativeCmd {
            param([string]$CmdLine)
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
            if ($out) { $Sync.LogQueue.Enqueue($out.Trim()) }
            if ($err) { $Sync.LogQueue.Enqueue("[STDERR] " + $err.Trim()) }
        }

        try {
            & $UserScript @UserParams
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [OK] Concluído: $TaskName")
        } catch {
            $Sync.LogQueue.Enqueue("[" + (Get-Date).ToString("HH:mm:ss") + "] [ERRO] Falha em '$TaskName': $($_.Exception.Message)")
        } finally {
            $Sync.IsBusy = $false
            $Sync.StatusText = "Pronto"
        }
    }

    [void]$ps.AddScript($wrapperCode).AddArgument($ScriptBlock).AddArgument($Parameters).AddArgument($SyncHash)
    $null = $ps.BeginInvoke()
}

# ==============================================================================
# 4. INTERFACE GRÁFICA WPF (XAML EMBUTIDO - TEMA WINUTIL DARK)
# ==============================================================================
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT-AdminUtil | Console Portátil de Infraestrutura Windows"
        Height="780" Width="1180" MinHeight="650" MinWidth="960"
        WindowStartupLocation="CenterScreen" Background="#1E222A" Foreground="#ABB2BF"
        FontFamily="Segoe UI">

    <Window.Resources>
        <!-- Estilo Botão Aba Superior (Pílula) -->
        <Style x:Key="TabPillButton" TargetType="RadioButton">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="Foreground" Value="#ABB2BF"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FontSize" Value="13"/>
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

        <!-- Estilo Botão Padrão / Ação -->
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

        <!-- Estilo Botão Primário Destaque -->
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#2B579A"/>
            <Setter Property="BorderBrush" Value="#3B82F6"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="Bold"/>
        </Style>

        <!-- Estilo Cartão de Categoria -->
        <Style x:Key="CategoryCard" TargetType="Border">
            <Setter Property="Background" Value="#282C34"/>
            <Setter Property="BorderBrush" Value="#3E4451"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="14"/>
            <Setter Property="Margin" Value="6"/>
        </Style>

        <!-- Estilo CheckBox Ferramenta -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#D1D5DB"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Barra Superior -->
            <RowDefinition Height="*"/>    <!-- Corpo Principal -->
            <RowDefinition Height="210"/>  <!-- Console Integrado -->
            <RowDefinition Height="Auto"/> <!-- Barra de Status -->
        </Grid.RowDefinitions>

        <!-- ================= BARRA SUPERIOR ================= -->
        <Border Grid.Row="0" Background="#282C34" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="270"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="IT-AdminUtil" FontSize="17" FontWeight="Bold" Foreground="#3B82F6" VerticalAlignment="Center" Margin="0,0,18,0"/>
                    <RadioButton x:Name="TabUsers" Content="1. Usuários &amp; AD" Style="{StaticResource TabPillButton}" IsChecked="True"/>
                    <RadioButton x:Name="TabNetwork" Content="2. Redes &amp; Conectividade" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabMachines" Content="3. Gestão de Máquinas" Style="{StaticResource TabPillButton}"/>
                    <RadioButton x:Name="TabPrinters" Content="4. Impressoras &amp; Spooler" Style="{StaticResource TabPillButton}"/>
                </StackPanel>

                <!-- Barra de Pesquisa Rápida -->
                <Grid Grid.Column="1" VerticalAlignment="Center">
                    <TextBox x:Name="TxtSearch" Background="#1E222A" Foreground="#FFFFFF" BorderBrush="#3E4451"
                             BorderThickness="1" Padding="10,6" FontSize="12.5" VerticalContentAlignment="Center"/>
                    <TextBlock x:Name="TxtSearchPlaceholder" Text="🔍 Filtrar ferramentas na tela..." Foreground="#6B7280"
                               IsHitTestVisible="False" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="12"/>
                </Grid>
            </Grid>
        </Border>

        <!-- ================= CORPO PRINCIPAL ================= -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230"/> <!-- Painel Lateral Esquerdo -->
                <ColumnDefinition Width="*"/>   <!-- Área Central Dinâmica -->
            </Grid.ColumnDefinitions>

            <!-- PAINEL LATERAL ESQUERDO (AÇÕES RÁPIDAS) -->
            <Border Grid.Column="0" Background="#282C34" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,10,0">
                <DockPanel LastChildFill="False">
                    <TextBlock DockPanel.Dock="Top" Text="⚡ AÇÕES RÁPIDAS" FontWeight="Bold" Foreground="#3B82F6" FontSize="12" Margin="0,0,0,10"/>

                    <Button DockPanel.Dock="Top" x:Name="BtnSysInfo" Content="🖥 Info Sistema (IP/Host/AD)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,6"/>
                    <Separator DockPanel.Dock="Top" Background="#3E4451" Margin="0,4,0,8"/>

                    <Button DockPanel.Dock="Top" x:Name="BtnLusrmgr" Content="👤 Usuários Locais (lusrmgr)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnNcpa" Content="🌐 Conexões de Rede (ncpa.cpl)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnDevmgmt" Content="🔧 Gerenc. Dispositivos" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnServices" Content="⚙ Serviços (services.msc)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnPrintMgmt" Content="🖨 Gerenc. Impressão" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,5"/>
                    <Button DockPanel.Dock="Top" x:Name="BtnGpedit" Content="🛡 Políticas Grupo (gpedit)" Style="{StaticResource ModernButton}" HorizontalContentAlignment="Left" Margin="0,0,0,12"/>

                    <Button DockPanel.Dock="Bottom" x:Name="BtnRunSelected" Content="▶ EXECUTAR SELECIONADOS" Style="{StaticResource PrimaryButton}" Padding="10,11" FontSize="12.5"/>
                    <Button DockPanel.Dock="Bottom" x:Name="BtnClearSelection" Content="Desmarcar Todos" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                </DockPanel>
            </Border>

            <!-- ÁREA CENTRAL (SCROLLVIEWER COM AS 4 ABAS) -->
            <Border Grid.Column="1" Background="#1E222A" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="6">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <Grid x:Name="MainContentContainer">

                        <!-- ==================== ABA 1: USUÁRIOS & AD ==================== -->
                        <UniformGrid x:Name="PanelUsers" Columns="2" Visibility="Visible">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="👥 Auditoria de Contas &amp; Grupos" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Usr_ListLocal" Content="Listar Usuários Locais e Status (Ativo/Bloqueado)"/>
                                    <CheckBox Tag="Usr_ListAdmins" Content="Listar Membros do Grupo Administradores"/>
                                    <CheckBox Tag="Usr_ADStatus" Content="Verificar Status de Domínio / Confiança AD"/>
                                    <Button x:Name="BtnNetplwiz" Content="Abrir Gerenciador Clássico (netplwiz)" Style="{StaticResource ModernButton}" Margin="0,12,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🔑 Gestão e Manutenção de Usuários" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnCreateUser" Content="+ Criar Novo Usuário Local" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnResetPass" Content="Resetar Senha / Desbloquear Conta Local" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                                        <Button x:Name="BtnEnableBuiltInAdmin" Content="Ativar Admin Embutido" Style="{StaticResource ModernButton}" Margin="0,0,6,0" Width="175"/>
                                        <Button x:Name="BtnDisableBuiltInAdmin" Content="Desativar Admin Embutido" Style="{StaticResource ModernButton}" Width="185"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="📜 Políticas de Grupo (GPO)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Usr_Gpupdate" Content="Forçar Atualização de Políticas (gpupdate /force)"/>
                                    <CheckBox Tag="Usr_Gpresult" Content="Exibir Relatório de GPOs Aplicadas (gpresult /r)"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 2: REDES & CONECTIVIDADE ==================== -->
                        <UniformGrid x:Name="PanelNetwork" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="📡 Diagnóstico e Tabelas de Rede" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_Ipconfig" Content="Configuração Completa (ipconfig /all)"/>
                                    <CheckBox Tag="Net_Arp" Content="Exibir Tabela ARP (arp -a)"/>
                                    <CheckBox Tag="Net_Route" Content="Exibir Tabela de Rotas (route print)"/>
                                    <CheckBox Tag="Net_Netstat" Content="Listar Portas Ativas e Processos (netstat -abno)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🔄 Reparo e Configuração de IP" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_FlushDns" Content="Limpar Cache DNS (ipconfig /flushdns)"/>
                                    <CheckBox Tag="Net_Renew" Content="Renovar Concessão DHCP (release + renew)"/>
                                    <CheckBox Tag="Net_Winsock" Content="Reset Completo Pilha TCP/IP e Winsock"/>
                                    <Button x:Name="BtnConfigIP" Content="⚙ Configurar IP Estático / DHCP" Style="{StaticResource PrimaryButton}" Margin="0,10,0,0"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🔌 Testes de Conectividade e Portas" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnTestPort" Content="Testar Porta TCP/IP (3389, 445, 9100, 80...)" Style="{StaticResource ModernButton}" Margin="0,0,0,8"/>
                                    <CheckBox Tag="Net_TestInternet" Content="Testar Conectividade Externa (DNS Google/Cloudflare)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="📂 Unidades de Rede (SMB)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Net_ListShares" Content="Listar Unidades Mapeadas (net use)"/>
                                    <Button x:Name="BtnMapDrive" Content="+ Mapear Unidade de Rede" Style="{StaticResource ModernButton}" Margin="0,8,0,6"/>
                                    <Button x:Name="BtnUnmapDrive" Content="Desconectar Unidade de Rede" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 3: GESTÃO DE MÁQUINAS ==================== -->
                        <UniformGrid x:Name="PanelMachines" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🖥 Inventário e Saúde de Hardware" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_Inventory" Content="Inventário Completo (CPU, RAM, BIOS Serial, OS, Uptime)"/>
                                    <CheckBox Tag="Mch_Smart" Content="Verificar Saúde SMART e Desgaste dos Discos"/>
                                    <CheckBox Tag="Mch_Battery" Content="Verificar Saúde da Bateria (Notebooks)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🧹 Limpeza Profunda &amp; Integridade" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Mch_CleanTemp" Content="Limpar Temp Windows, Temp Usuário, Prefetch e Lixeira"/>
                                    <CheckBox Tag="Mch_CleanWU" Content="Limpar Cache do Windows Update (SoftwareDistribution)"/>
                                    <CheckBox Tag="Mch_Sfc" Content="Verificar Arquivos do Sistema (sfc /scannow)"/>
                                    <CheckBox Tag="Mch_Dism" Content="Reparar Imagem do Windows (DISM RestoreHealth)"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🖧 Acesso Remoto (RDP)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnEnableRDP" Content="Ativar RDP + Liberar Porta 3389 no Firewall" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnDisableRDP" Content="Desativar Área de Trabalho Remota (RDP)" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="⚡ Energia &amp; Shell" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnRestartExplorer" Content="Reiniciar Windows Explorer (explorer.exe)" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnRebootBios" Content="Reiniciar Direto na BIOS / UEFI" Style="{StaticResource ModernButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnForceShutdown" Content="Desligamento Forçado Imediato" Style="{StaticResource ModernButton}" Foreground="#F87171"/>
                                </StackPanel>
                            </Border>
                        </UniformGrid>

                        <!-- ==================== ABA 4: IMPRESSORAS & SPOOLER ==================== -->
                        <UniformGrid x:Name="PanelPrinters" Columns="2" Visibility="Collapsed">
                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🖨 Inventário e Diagnóstico de Impressão" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <CheckBox Tag="Prt_ListAll" Content="Listar Impressoras, Portas (IPs) e Drivers Instalados"/>
                                    <CheckBox Tag="Prt_ClearQueue" Content="Destravar Fila (Parar Spooler, Limpar PRINTERS, Iniciar)"/>
                                    <CheckBox Tag="Prt_RemoveOffline" Content="Remover Impressoras Fantasmas / Offline"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}">
                                <StackPanel>
                                    <TextBlock Text="🌐 Impressoras de Rede (TCP/IP)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,10"/>
                                    <Button x:Name="BtnAddIpPrinter" Content="+ Adicionar Impressora de Rede via IP (Porta 9100)" Style="{StaticResource PrimaryButton}" Margin="0,0,0,6"/>
                                    <Button x:Name="BtnTestPrinterNet" Content="Testar Comunicação Impressora (Ping + 9100/515/631/161)" Style="{StaticResource ModernButton}"/>
                                </StackPanel>
                            </Border>

                            <Border Style="{StaticResource CategoryCard}" Grid.ColumnSpan="2">
                                <StackPanel>
                                    <TextBlock Text="📦 Instalação Rápida de Programas Padrão (Winget)" FontWeight="Bold" Foreground="#3B82F6" FontSize="14" Margin="0,0,0,8"/>
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

        <!-- ================= CONSOLE INTEGRADO (INFERIOR) ================= -->
        <Border Grid.Row="2" Background="#161920" BorderBrush="#3E4451" BorderThickness="1" CornerRadius="8" Padding="10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <DockPanel Grid.Row="0" Margin="0,0,0,6">
                    <TextBlock Text="📟 CONSOLE DE SAÍDA &amp; LOG EM TEMPO REAL" FontWeight="Bold" Foreground="#9CA3AF" FontSize="11.5" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="BtnClearLog" Content="Limpar Log" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5" Margin="0,0,6,0"/>
                        <Button x:Name="BtnExportLog" Content="💾 Exportar Relatório (.txt)" Style="{StaticResource ModernButton}" Padding="10,4" FontSize="11.5"/>
                    </StackPanel>
                </DockPanel>

                <TextBox x:Name="TxtConsole" Grid.Row="1" Background="#12141A" Foreground="#10B981"
                         FontFamily="Consolas" FontSize="12" IsReadOnly="True"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap" BorderThickness="0" Padding="6"/>
            </Grid>
        </Border>

        <!-- ================= BARRA DE STATUS ================= -->
        <DockPanel Grid.Row="3" Margin="2,6,2,0">
            <TextBlock x:Name="LblStatus" Text="Status: Pronto (Modo Administrador)" Foreground="#9CA3AF" FontSize="11.5"/>
            <TextBlock Text="Windows Admin Toolkit | PowerShell WPF" Foreground="#6B7280" FontSize="11.5" HorizontalAlignment="Right"/>
        </DockPanel>
    </Grid>
</Window>
"@

# Carrega a Janela Principal
$reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Mapeamento dos Controles
$Controls = @{}
$XAML.SelectNodes("//*[@*[contains(translate(name(.),'n','N'),'Name')]]") | ForEach-Object {
    $name = $_.Name
    $Controls[$name] = $Window.FindName($name)
}

# ==============================================================================
# 5. TIMER DE ATUALIZAÇÃO DA UI (CONSOME LOGQUEUE E STATUS DO RUNSPACE)
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
})
$UiTimer.Start()

# ==============================================================================
# 6. HELPER DE DIÁLOGOS MODAIS ESTILIZADOS (POPUPS DINÂMICOS)
# ==============================================================================
function Show-InputDialog {
    param(
        [string]$Title,
        [array]$Fields # Ex: @(@{Name="User"; Label="Usuário:"; Type="Text"}, @{Name="Pass"; Label="Senha:"; Type="Password"})
    )

    $dlg = New-Object System.Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 420
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
# 7. NAVEGAÇÃO ENTRE ABAS E FILTRO DE PESQUISA EM TEMPO REAL
# ==============================================================================
$Controls.TabUsers.Add_Checked({
    $Controls.PanelUsers.Visibility = "Visible"
    $Controls.PanelNetwork.Visibility = "Collapsed"
    $Controls.PanelMachines.Visibility = "Collapsed"
    $Controls.PanelPrinters.Visibility = "Collapsed"
})
$Controls.TabNetwork.Add_Checked({
    $Controls.PanelUsers.Visibility = "Collapsed"
    $Controls.PanelNetwork.Visibility = "Visible"
    $Controls.PanelMachines.Visibility = "Collapsed"
    $Controls.PanelPrinters.Visibility = "Collapsed"
})
$Controls.TabMachines.Add_Checked({
    $Controls.PanelUsers.Visibility = "Collapsed"
    $Controls.PanelNetwork.Visibility = "Collapsed"
    $Controls.PanelMachines.Visibility = "Visible"
    $Controls.PanelPrinters.Visibility = "Collapsed"
})
$Controls.TabPrinters.Add_Checked({
    $Controls.PanelUsers.Visibility = "Collapsed"
    $Controls.PanelNetwork.Visibility = "Collapsed"
    $Controls.PanelMachines.Visibility = "Collapsed"
    $Controls.PanelPrinters.Visibility = "Visible"
})

# Pesquisa Instantânea nas Checkboxes e Botões das Abas
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
# 8. EVENTOS DO PAINEL LATERAL E CONSOLE
# ==============================================================================
$Controls.BtnClearLog.Add_Click({ $Controls.TxtConsole.Clear() })

$Controls.BtnExportLog.Add_Click({
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = "Arquivo de Texto (*.txt)|*.txt"
    $sfd.FileName = "Relatorio_TI_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
    if ($sfd.ShowDialog() -eq $true) {
        $Controls.TxtConsole.Text | Out-File -FilePath $sfd.FileName -Encoding UTF8
        Write-AppLog "Relatório exportado para: $($sfd.FileName)" "OK"
    }
})

$Controls.BtnLusrmgr.Add_Click({ Start-Process "lusrmgr.msc" })
$Controls.BtnNcpa.Add_Click({ Start-Process "ncpa.cpl" })
$Controls.BtnDevmgmt.Add_Click({ Start-Process "devmgmt.msc" })
$Controls.BtnServices.Add_Click({ Start-Process "services.msc" })
$Controls.BtnPrintMgmt.Add_Click({ Start-Process "printmanagement.msc" })
$Controls.BtnGpedit.Add_Click({ Start-Process "gpedit.msc" })
$Controls.BtnNetplwiz.Add_Click({ Start-Process "netplwiz.exe" })

$Controls.BtnSysInfo.Add_Click({
    Invoke-AsyncTask -TaskName "Informações Rápidas do Sistema" -ScriptBlock {
        $cs = Get-CimInstance Win32_ComputerSystem
        $ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress -join ", "
        Write-TaskLog "Hostname: $($env:COMPUTERNAME) | Usuário Atual: $($env:USERNAME)"
        Write-TaskLog "Domínio/Workgroup: $($cs.Domain) (Ingressado no Domínio: $($cs.PartOfDomain))"
        Write-TaskLog "Endereços IPv4 Ativos: $ips"
    }
})

$Controls.BtnClearSelection.Add_Click({
    Find-VisualChildren -Parent $Controls.MainContentContainer | Where-Object { $_ -is [System.Windows.Controls.CheckBox] } | ForEach-Object {
        $_.IsChecked = $false
    }
})

# ==============================================================================
# 9. EVENTOS DE BOTÕES DIRETOS (POPUPS E AÇÕES IMEDIATAS)
# ==============================================================================

# --- ABA 1: USUÁRIOS ---
$Controls.BtnCreateUser.Add_Click({
    $res = Show-InputDialog -Title "Criar Novo Usuário Local" -Fields @(
        @{Name="User"; Label="Nome de Usuário:"; Type="Text"},
        @{Name="Pass"; Label="Senha:"; Type="Password"},
        @{Name="IsAdmin"; Label="Privilégios:"; Type="Check"; CheckText="Adicionar ao grupo Administradores"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Criar Usuário $($res.User)" -Parameters @{U=$res.User; P=$res.Pass; A=$res.IsAdmin} -ScriptBlock {
            param($U, $P, $A)
            $secPass = ConvertTo-SecureString $P -AsPlainText -Force
            New-LocalUser -Name $U -Password $secPass -FullName $U -Description "Criado via IT-AdminUtil" -PasswordNeverExpires
            Write-TaskLog "Usuário '$U' criado com sucesso." "OK"
            if ($A) {
                Add-LocalGroupMember -Group "Administradores" -Member $U -ErrorAction SilentlyContinue
                Add-LocalGroupMember -Group "Administrators" -Member $U -ErrorAction SilentlyContinue
                Write-TaskLog "Usuário '$U' adicionado aos Administradores." "OK"
            }
        }
    }
})

$Controls.BtnResetPass.Add_Click({
    $res = Show-InputDialog -Title "Resetar Senha / Desbloquear Conta" -Fields @(
        @{Name="User"; Label="Nome do Usuário Local:"; Type="Text"},
        @{Name="Pass"; Label="Nova Senha (deixe vazio apenas para desbloquear):"; Type="Password"}
    )
    if ($res -and $res.User) {
        Invoke-AsyncTask -TaskName "Manutenção Conta $($res.User)" -Parameters @{U=$res.User; P=$res.Pass} -ScriptBlock {
            param($U, $P)
            Enable-LocalUser -Name $U
            Write-TaskLog "Conta '$U' ativada/desbloqueada." "OK"
            if ($P) {
                $secPass = ConvertTo-SecureString $P -AsPlainText -Force
                Set-LocalUser -Name $U -Password $secPass
                Write-TaskLog "Senha do usuário '$U' redefinida com sucesso." "OK"
            }
        }
    }
})

$Controls.BtnEnableBuiltInAdmin.Add_Click({
    Invoke-AsyncTask -TaskName "Ativar Conta Administrador Embutida" -ScriptBlock {
        $admin = Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-21-*-500" }
        Enable-LocalUser -Name $admin.Name
        Write-TaskLog "Conta embutida '$($admin.Name)' ATIVADA." "OK"
    }
})

$Controls.BtnDisableBuiltInAdmin.Add_Click({
    Invoke-AsyncTask -TaskName "Desativar Conta Administrador Embutida" -ScriptBlock {
        $admin = Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-21-*-500" }
        Disable-LocalUser -Name $admin.Name
        Write-TaskLog "Conta embutida '$($admin.Name)' DESATIVADA." "OK"
    }
})

# --- ABA 2: REDES ---
$Controls.BtnConfigIP.Add_Click({
    $defaultNic = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).Name
    $res = Show-InputDialog -Title "Configurar IP Estático ou DHCP" -Fields @(
        @{Name="Nic"; Label="Nome da Interface de Rede:"; Type="Text"; Default=$defaultNic},
        @{Name="UseDhcp"; Label="Modo Automático:"; Type="Check"; CheckText="Ativar DHCP (Ignora campos abaixo)"},
        @{Name="IP"; Label="Endereço IP (ex: 192.168.1.50):"; Type="Text"},
        @{Name="Prefix"; Label="Prefixo de Máscara (ex: 24 para 255.255.255.0):"; Type="Text"; Default="24"},
        @{Name="Gateway"; Label="Gateway Padrão (ex: 192.168.1.1):"; Type="Text"},
        @{Name="DNS"; Label="DNS Primário (ex: 8.8.8.8):"; Type="Text"; Default="8.8.8.8"}
    )
    if ($res -and $res.Nic) {
        Invoke-AsyncTask -TaskName "Configurar Rede ($($res.Nic))" -Parameters @{Cfg=$res} -ScriptBlock {
            param($Cfg)
            if ($Cfg.UseDhcp) {
                Set-NetIPInterface -InterfaceAlias $Cfg.Nic -Dhcp Enabled
                Set-DnsClientServerAddress -InterfaceAlias $Cfg.Nic -ResetServerAddresses
                Write-TaskLog "Interface '$($Cfg.Nic)' configurada para DHCP." "OK"
            } else {
                Remove-NetIPAddress -InterfaceAlias $Cfg.Nic -Confirm:$false -ErrorAction SilentlyContinue
                Remove-NetRoute -InterfaceAlias $Cfg.Nic -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceAlias $Cfg.Nic -IPAddress $Cfg.IP -PrefixLength ([int]$Cfg.Prefix) -DefaultGateway $Cfg.Gateway
                if ($Cfg.DNS) { Set-DnsClientServerAddress -InterfaceAlias $Cfg.Nic -ServerAddresses $Cfg.DNS }
                Write-TaskLog "IP Estático $($Cfg.IP)/$($Cfg.Prefix) aplicado em '$($Cfg.Nic)'." "OK"
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
            $test = Test-NetConnection -ComputerName $T -Port $P -WarningAction SilentlyContinue
            $status = if ($test.TcpTestSucceeded) { "ABERTA (Sucesso)" } else { "FECHADA / BLOQUEADA" }
            Write-TaskLog "Destino: $T | Porta: $P | Ping: $($test.PingSucceeded) | Porta TCP: $status"
        }
    }
})

$Controls.BtnMapDrive.Add_Click({
    $res = Show-InputDialog -Title "Mapear Unidade de Rede" -Fields @(
        @{Name="Letter"; Label="Letra da Unidade (ex: Z:):"; Type="Text"; Default="Z:"},
        @{Name="Path"; Label="Caminho UNC (ex: \\Servidor\Pasta):"; Type="Text"},
        @{Name="User"; Label="Usuário (Opcional - ex: DOMINIO\usuario):"; Type="Text"},
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

# --- ABA 3: GESTÃO DE MÁQUINAS ---
$Controls.BtnEnableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Ativar RDP e Firewall" -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
        Enable-NetFirewallRule -DisplayGroup "Área de Trabalho Remota" -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-TaskLog "Área de Trabalho Remota (RDP) ativada e liberada no Firewall." "OK"
    }
})

$Controls.BtnDisableRDP.Add_Click({
    Invoke-AsyncTask -TaskName "Desativar RDP" -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 1
        Disable-NetFirewallRule -DisplayGroup "Área de Trabalho Remota" -ErrorAction SilentlyContinue
        Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-TaskLog "Área de Trabalho Remota (RDP) desativada." "OK"
    }
})

$Controls.BtnRestartExplorer.Add_Click({
    Invoke-AsyncTask -TaskName "Reiniciar Explorer" -ScriptBlock {
        Stop-Process -Name explorer -Force
        Write-TaskLog "Windows Explorer reiniciado." "OK"
    }
})

$Controls.BtnRebootBios.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show("Deseja reiniciar o computador diretamente no setup UEFI/BIOS agora?", "Confirmar Reinicialização", "YesNo", "Warning")
    if ($confirm -eq "Yes") { shutdown.exe /r /fw /t 0 }
})

$Controls.BtnForceShutdown.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show("Deseja forçar o desligamento imediato desta máquina?", "Confirmar Desligamento", "YesNo", "Warning")
    if ($confirm -eq "Yes") { shutdown.exe /s /f /t 0 }
})

# --- ABA 4: IMPRESSORAS ---
$Controls.BtnAddIpPrinter.Add_Click({
    $res = Show-InputDialog -Title "Adicionar Impressora de Rede via IP" -Fields @(
        @{Name="Name"; Label="Nome da Impressora:"; Type="Text"},
        @{Name="IP"; Label="Endereço IP da Impressora:"; Type="Text"},
        @{Name="Driver"; Label="Nome do Driver Instalado (Padrão: Generic / Text Only):"; Type="Text"; Default="Generic / Text Only"}
    )
    if ($res -and $res.Name -and $res.IP) {
        Invoke-AsyncTask -TaskName "Instalar Impressora $($res.Name)" -Parameters @{P=$res} -ScriptBlock {
            param($P)
            $portName = "IP_$($P.IP)"
            if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
                Add-PrinterPort -Name $portName -PrinterHostAddress $P.IP
                Write-TaskLog "Porta TCP/IP '$portName' (9100) criada." "OK"
            }
            Add-Printer -Name $P.Name -DriverName $P.Driver -PortName $portName
            Write-TaskLog "Impressora '$($P.Name)' instalada com sucesso no IP $($P.IP)." "OK"
        }
    }
})

$Controls.BtnTestPrinterNet.Add_Click({
    $res = Show-InputDialog -Title "Diagnosticar Impressora de Rede" -Fields @(
        @{Name="IP"; Label="Endereço IP da Impressora:"; Type="Text"}
    )
    if ($res -and $res.IP) {
        Invoke-AsyncTask -TaskName "Testar Impressora $($res.IP)" -Parameters @{IP=$res.IP} -ScriptBlock {
            param($IP)
            $ping = Test-Connection -ComputerName $IP -Count 2 -Quiet
            Write-TaskLog "Ping para $IP : $(if($ping){'RESPONDEU'}else{'SEM RESPOSTA'})"
            $ports = @{9100="RAW/JetDirect"; 515="LPR/LPD"; 631="IPP"; 161="SNMP (Status)"}
            foreach ($port in $ports.Keys) {
                $t = Test-NetConnection -ComputerName $IP -Port $port -WarningAction SilentlyContinue
                $st = if ($t.TcpTestSucceeded) { "ABERTA" } else { "Fechada" }
                Write-TaskLog "  -> Porta $port ($($ports[$port])): $st"
            }
        }
    }
})

# ==============================================================================
# 10. EXECUÇÃO EM LOTE DAS CHECKBOXES SELECIONADAS
# ==============================================================================
$Controls.BtnRunSelected.Add_Click({
    $selectedTags = Find-VisualChildren -Parent $Controls.MainContentContainer |
        Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked -eq $true } |
        ForEach-Object { $_.Tag.ToString() }

    if (-not $selectedTags -or $selectedTags.Count -eq 0) {
        Write-AppLog "Nenhuma ferramenta marcada nas caixas de seleção." "WARN"
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
            Write-TaskLog "--- Executando módulo: $tag ---"

            # WINGET PACKAGES
            if ($wingetMap.ContainsKey($tag)) {
                $pkgId = $wingetMap[$tag]
                Write-TaskLog "Instalando pacote via Winget: $pkgId..."
                Invoke-NativeCmd "winget install --id $pkgId -e --silent --accept-package-agreements --accept-source-agreements"
                continue
            }

            switch ($tag) {
                # ABA 1: USUÁRIOS & AD
                "Usr_ListLocal" {
                    Get-LocalUser | Format-Table Name, Enabled, PasswordLastSet, LastLogon -AutoSize | Out-String | ForEach-Object { Write-TaskLog $_.Trim() }
                }
                "Usr_ListAdmins" {
                    Invoke-NativeCmd "net localgroup Administradores"
                    Invoke-NativeCmd "net localgroup Administrators"
                }
                "Usr_ADStatus" {
                    Invoke-NativeCmd "dsregcmd /status | findstr /C:`"DomainJoined`" /C:`"AzureAdJoined`" /C:`"DomainName`""
                }
                "Usr_Gpupdate" { Invoke-NativeCmd "gpupdate /force" }
                "Usr_Gpresult" { Invoke-NativeCmd "gpresult /r" }

                # ABA 2: REDES
                "Net_Ipconfig"     { Invoke-NativeCmd "ipconfig /all" }
                "Net_Arp"          { Invoke-NativeCmd "arp -a" }
                "Net_Route"        { Invoke-NativeCmd "route print" }
                "Net_Netstat"      { Invoke-NativeCmd "netstat -abno" }
                "Net_FlushDns"     { Invoke-NativeCmd "ipconfig /flushdns" }
                "Net_Renew"        { Invoke-NativeCmd "ipconfig /release && ipconfig /renew" }
                "Net_Winsock"      { Invoke-NativeCmd "netsh int ip reset && netsh winsock reset" }
                "Net_ListShares"   { Invoke-NativeCmd "net use" }
                "Net_TestInternet" {
                    $g = Test-Connection 8.8.8.8 -Count 2 -Quiet
                    $c = Test-Connection 1.1.1.1 -Count 2 -Quiet
                    Write-TaskLog "Ping 8.8.8.8 (Google): $g | Ping 1.1.1.1 (Cloudflare): $c"
                }

                # ABA 3: GESTÃO DE MÁQUINAS
                "Mch_Inventory" {
                    $cpu = (Get-CimInstance Win32_Processor).Name
                    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
                    $bios = (Get-CimInstance Win32_BIOS).SerialNumber
                    $os = Get-CimInstance Win32_OperatingSystem
                    $uptime = (Get-Date) - $os.LastBootUpTime
                    Write-TaskLog "CPU: $cpu | RAM: $ram GB | Serial BIOS: $bios"
                    Write-TaskLog "OS: $($os.Caption) (Build $($os.BuildNumber)) | Uptime: $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
                }
                "Mch_Smart" {
                    Get-PhysicalDisk | ForEach-Object {
                        $rel = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                        Write-TaskLog "Disco: $($_.FriendlyName) ($($_.MediaType)) | Saúde: $($_.HealthStatus) | Desgaste: $($rel.Wear)% | Horas: $($rel.PowerOnHours)h"
                    }
                }
                "Mch_Battery" {
                    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
                    if ($bat) {
                        Write-TaskLog "Bateria: $($bat.Name) | Carga Atual: $($bat.EstimatedChargeRemaining)% | Status: $($bat.Status)"
                    } else {
                        Write-TaskLog "Nenhuma bateria detectada (Desktop)."
                    }
                }
                "Mch_CleanTemp" {
                    $paths = @("$env:TEMP\*", "$env:WINDIR\Temp\*", "$env:WINDIR\Prefetch\*")
                    foreach ($p in $paths) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
                    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                    Write-TaskLog "Arquivos temporários, Prefetch e Lixeira limpos." "OK"
                }
                "Mch_CleanWU" {
                    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                    Remove-Item "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
                    Start-Service wuauserv -ErrorAction SilentlyContinue
                    Write-TaskLog "Cache do Windows Update limpo com sucesso." "OK"
                }
                "Mch_Sfc"  { Invoke-NativeCmd "sfc /scannow" }
                "Mch_Dism" { Invoke-NativeCmd "DISM /Online /Cleanup-Image /RestoreHealth" }

                # ABA 4: IMPRESSORAS & SPOOLER
                "Prt_ListAll" {
                    Get-Printer | Select-Object Name, DriverName, PortName, PrinterStatus | Format-Table -AutoSize | Out-String | ForEach-Object { Write-TaskLog $_.Trim() }
                    Get-PrinterPort | Select-Object Name, PrinterHostAddress, PortNumber | Format-Table -AutoSize | Out-String | ForEach-Object { Write-TaskLog $_.Trim() }
                }
                "Prt_ClearQueue" {
                    Write-TaskLog "Parando serviço Spooler de Impressão..."
                    Stop-Service -Name Spooler -Force
                    Remove-Item -Path "$env:WINDIR\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
                    Start-Service -Name Spooler
                    Write-TaskLog "Fila de impressão limpa e Spooler reiniciado!" "OK"
                }
                "Prt_RemoveOffline" {
                    $offline = Get-Printer | Where-Object { $_.PrinterStatus -eq "Offline" -or $_.WorkOffline -eq $true }
                    if ($offline) {
                        foreach ($p in $offline) {
                            Remove-Printer -Name $p.Name
                            Write-TaskLog "Impressora offline removida: $($p.Name)" "OK"
                        }
                    } else {
                        Write-TaskLog "Nenhuma impressora offline encontrada."
                    }
                }
            }
        }
    }
})

# Mensagem de Boas-Vindas no Console
Write-AppLog "IT-AdminUtil inicializado com privilégios de Administrador." "OK"
Write-AppLog "Selecione os itens desejados nas abas superiores e clique em 'EXECUTAR SELECIONADOS'."

# Exibe a Janela WPF
[void]$Window.ShowDialog()
$UiTimer.Stop()