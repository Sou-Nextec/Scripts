#Requires -Version 5.1
<#
.SYNOPSIS
    Coleta local e silenciosa de uma estação (ou servidor) para o Assessment Nextec.

.DESCRIPTION
    Roda na própria máquina, como SYSTEM, por tarefa agendada criada por GPO (veja Instalar-Assessment-Estacao.ps1).
    É somente leitura: não altera nada na máquina. Grava um arquivo <NOME-DA-MAQUINA>.json na pasta
    compartilhada do servidor e uma cópia local em C:\ProgramData\Nextec\Assessment\Estacao.
    O Nextec-Assessment-v2.ps1 lê esses arquivos no lugar de consultar as estações pela rede,
    então firewall e permissão remota deixam de ser problema.

    Sem janela, sem pergunta, sem saída no console. Código de saída: 0 = gravou no compartilhamento,
    1 = coletou mas não alcançou o compartilhamento (a cópia local fica e a próxima execução tenta de novo).

.PARAMETER Destino
    Pasta compartilhada de destino, por exemplo \\SERVIDOR01\Assessment$\Estacoes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destino,
    [string]$PastaLocal
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$versaoColetor = '1.0'

$pastaLocal = if ($PastaLocal) { $PastaLocal } else { Join-Path $env:ProgramData 'Nextec\Assessment\Estacao' }
try { New-Item -ItemType Directory -Path $pastaLocal -Force | Out-Null }
catch {
    # Sem permissão na pasta padrão (execução fora do SYSTEM): usa a pasta temporária do usuário.
    $pastaLocal = Join-Path $env:TEMP 'Nextec-Assessment-Estacao'
    New-Item -ItemType Directory -Path $pastaLocal -Force | Out-Null
}
$logLocal = Join-Path $pastaLocal 'coleta-estacao.log'

function Write-LogEstacao {
    param([string]$Mensagem)
    try {
        if ((Test-Path $logLocal) -and (Get-Item $logLocal).Length -gt 512KB) { Move-Item $logLocal "$logLocal.antigo" -Force }
        Add-Content -Path $logLocal -Value ("{0} {1}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Mensagem) -Encoding UTF8
    } catch { }
}

function Format-DataEstacao {
    param($Data)
    if ($null -eq $Data -or $Data -eq [datetime]::MinValue) { return '' }
    ([datetime]$Data).ToString('dd/MM/yyyy HH:mm')
}

function Invoke-Seguro {
    # Cada item é independente: se um falha, os demais continuam e o campo sai com o valor padrão.
    param([scriptblock]$Bloco, $Padrao = $null)
    try { & $Bloco } catch { Write-LogEstacao "Item ignorado: $($_.Exception.Message)"; $Padrao }
}

try {
    Write-LogEstacao "Início da coleta (coletor $versaoColetor) para $env:COMPUTERNAME"

    $cs    = Get-CimInstance Win32_ComputerSystem
    $bios  = Get-CimInstance Win32_BIOS
    $so    = Get-CimInstance Win32_OperatingSystem
    $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
    $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

    # Antivírus: Security Center nas estações; em servidor, pelos serviços em execução.
    $av = Invoke-Seguro { (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop).displayName -join '; ' } ''
    if (-not $av) {
        $regexAv = '(?i)Acronis (Active Protection|Cyber Protection)|Kaspersky|ESET|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|AVG|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|^WinDefend$'
        $av = Invoke-Seguro {
            (Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction Stop |
                Where-Object { $_.DisplayName -match $regexAv -or $_.Name -match $regexAv } |
                ForEach-Object { $_.DisplayName } | Select-Object -Unique -First 3) -join '; '
        } ''
        if (-not $av) { $av = 'N/D' }
    }

    $midia = Invoke-Seguro {
        (Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
            ForEach-Object { switch ([int]$_.MediaType) { 3 { 'HDD' } 4 { 'SSD' } default { 'Não informado' } } }) -join '; '
    } ''

    $bitlocker = Invoke-Seguro {
        (Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
            ForEach-Object {
                $st = switch ([int]$_.ProtectionStatus) { 0 { 'desprotegido' } 1 { 'protegido' } default { 'desconhecido' } }
                "$($_.DriveLetter) $st"
            }) -join '; '
    } 'N/D'

    $tempoReal = $null; $assinatura = $null
    try {
        $mp = Get-CimInstance -Namespace 'root\Microsoft\Windows\Defender' -ClassName MSFT_MpComputerStatus -ErrorAction Stop
        $tempoReal = $mp.RealTimeProtectionEnabled
        $assinatura = $mp.AntivirusSignatureLastUpdated
    } catch { }

    $ultimoPatch = Invoke-Seguro {
        (Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop |
            Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn
    }

    # Administradores locais pelo SID do grupo (o nome muda conforme o idioma).
    $admins = Invoke-Seguro {
        $grupo = Get-CimInstance Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction Stop | Select-Object -First 1
        if ($grupo) {
            $consulta = "ASSOCIATORS OF {Win32_Group.Domain='$($grupo.Domain)',Name='$($grupo.Name)'} WHERE AssocClass=Win32_GroupUser Role=GroupComponent"
            (Get-CimInstance -Query $consulta -ErrorAction Stop | ForEach-Object { "$($_.Domain)\$($_.Name)" }) -join '; '
        } else { '' }
    } 'N/D'

    # Softwares instalados (registro 64 e 32 bits).
    $softwares = @(Invoke-Seguro {
        $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
            Select-Object @{ n = 'Nome'; e = { $_.DisplayName.Trim() } },
                          @{ n = 'Versao'; e = { $_.DisplayVersion } },
                          @{ n = 'Fabricante'; e = { $_.Publisher } } |
            Sort-Object Nome, Versao -Unique
    } @())

    $tpm = Invoke-Seguro {
        $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($t -and $t.IsEnabled_InitialValue) { 'Presente e ativo' } elseif ($t) { 'Presente, desativado' } else { 'Ausente' }
    } 'N/D'
    $secureBoot = Invoke-Seguro { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'Ligado' } else { 'Desligado' } } 'N/D'
    $rdp = Invoke-Seguro {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        if ($v -eq 0) { 'Habilitado' } else { 'Desabilitado' }
    } 'N/D'
    $acessoRemoto = ($softwares | Where-Object { $_.Nome -match '(?i)AnyDesk|TeamViewer|RustDesk|Radmin|UltraVNC|TightVNC|Splashtop|LogMeIn|ScreenConnect|Chrome Remote' } |
        ForEach-Object { $_.Nome } | Select-Object -Unique) -join '; '
    $reinicioPendente = Invoke-Seguro {
        [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    } $null
    $firewall = Invoke-Seguro {
        (Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object { "$($_.Name): $(if ($_.Enabled) { 'ligado' } else { 'DESLIGADO' })" }) -join ' | '
    } 'N/D'

    $inventario = [ordered]@{
        Computador            = "$env:COMPUTERNAME"
        Status                = 'OK'
        Origem                = 'Coleta local (GPO)'
        ColetadoEm            = (Get-Date).ToString('s')
        VersaoColetor         = $versaoColetor
        Fabricante            = $cs.Manufacturer
        Modelo                = $cs.Model
        NumeroSerie           = $bios.SerialNumber
        SO                    = $so.Caption
        Build                 = $so.BuildNumber
        Processador           = "$($cpu.Name)".Trim()
        MemoriaGB             = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        MemoriaLivreGB        = if ($so.FreePhysicalMemory) { [math]::Round($so.FreePhysicalMemory / 1MB, 1) } else { $null }
        DiscoCGB              = if ($disco) { [math]::Round($disco.Size / 1GB, 0) } else { $null }
        LivreCPct             = if ($disco -and $disco.Size) { [math]::Round($disco.FreeSpace / $disco.Size * 100, 0) } else { $null }
        TipoDisco             = $midia
        Antivirus             = $av
        DefenderTempoReal     = $tempoReal
        AssinaturaAV          = Format-DataEstacao $assinatura
        DiasAssinaturaAV      = if ($assinatura) { [int]((Get-Date) - $assinatura).TotalDays } else { $null }
        BitLocker             = $bitlocker
        UltimoPatch           = Format-DataEstacao $ultimoPatch
        DiasSemPatch          = if ($ultimoPatch) { [int]((Get-Date) - $ultimoPatch).TotalDays } else { $null }
        AdministradoresLocais = $admins
        UsuarioLogado         = $cs.UserName
        UltimoBoot            = Format-DataEstacao $so.LastBootUpTime
        InstaladoEm           = Format-DataEstacao $so.InstallDate
        TPM                   = $tpm
        SecureBoot            = $secureBoot
        RDP                   = $rdp
        AcessoRemotoInstalado = $acessoRemoto
        ReinicioPendente      = $reinicioPendente
        Firewall              = $firewall
        QtdSoftwares          = $softwares.Count
        Softwares             = $softwares
    }

    $json = $inventario | ConvertTo-Json -Depth 4
    $nomeArquivo = "$($env:COMPUTERNAME.ToUpper()).json"

    # Cópia local primeiro: se o compartilhamento estiver fora do ar, a próxima execução entrega.
    $arquivoLocal = Join-Path $pastaLocal $nomeArquivo
    [IO.File]::WriteAllText($arquivoLocal, $json, (New-Object System.Text.UTF8Encoding($true)))

    # Entrega atômica: grava com extensão temporária e renomeia, para o assessment nunca ler arquivo pela metade.
    $temporario = Join-Path $Destino "$nomeArquivo.tmp"
    $final = Join-Path $Destino $nomeArquivo
    try {
        [IO.File]::WriteAllText($temporario, $json, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temporario -Destination $final -Force
        Write-LogEstacao "Gravado em $final ($($softwares.Count) softwares)"
        exit 0
    } catch {
        Write-LogEstacao "Compartilhamento inalcançável ($Destino): $($_.Exception.Message). Cópia local mantida."
        exit 1
    }
} catch {
    Write-LogEstacao "ERRO: $($_.Exception.Message)"
    exit 2
}
