#Requires -Version 5.1
<#
.SYNOPSIS
    Script de inicialização da GPO: instala (ou atualiza) a tarefa agendada que coleta o inventário da estação.

.DESCRIPTION
    Roda como SYSTEM na inicialização do computador, pela GPO. Em cada execução:
      1. copia o coletor (Nextec-Assessment-Estacao.ps1) para C:\ProgramData\Nextec\Assessment\Estacao;
      2. registra a tarefa "Nextec - Assessment da estacao" (SYSTEM, oculta, sem janela);
      3. dispara uma coleta se ainda não existir resultado ou se o último tiver mais de 6 dias.
    É idempotente: rodar de novo apenas atualiza o coletor e a tarefa. Somente leitura no restante da máquina.

.PARAMETER Destino
    Pasta compartilhada que recebe os resultados, por exemplo \\SERVIDOR01.dominio.local\Assessment$\Estacoes

.PARAMETER Remover
    Remove a tarefa e os arquivos locais (para desfazer o que a GPO instalou).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destino,
    [switch]$Remover
)

$ErrorActionPreference = 'Stop'

$nomeTarefa = 'Nextec - Assessment da estacao'
$pastaLocal = Join-Path $env:ProgramData 'Nextec\Assessment\Estacao'
$coletorLocal = Join-Path $pastaLocal 'Nextec-Assessment-Estacao.ps1'
$logLocal = Join-Path $pastaLocal 'instalacao.log'

function Write-LogInstalacao {
    param([string]$Mensagem)
    try { Add-Content -Path $logLocal -Value ("{0} {1}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Mensagem) -Encoding UTF8 } catch { }
}

try {
    if ($Remover) {
        Unregister-ScheduledTask -TaskName $nomeTarefa -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $pastaLocal -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }

    New-Item -ItemType Directory -Path $pastaLocal -Force | Out-Null

    # O coletor vem da mesma pasta deste script (NETLOGON). Se a rede não responder agora, mantém o que já existe.
    $origem = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Nextec-Assessment-Estacao.ps1'
    if (Test-Path -LiteralPath $origem) {
        $novo = (Get-FileHash -LiteralPath $origem -Algorithm SHA256).Hash
        $atual = if (Test-Path $coletorLocal) { (Get-FileHash -LiteralPath $coletorLocal -Algorithm SHA256).Hash } else { '' }
        if ($novo -ne $atual) { Copy-Item -LiteralPath $origem -Destination $coletorLocal -Force; Write-LogInstalacao 'Coletor atualizado.' }
    } elseif (-not (Test-Path $coletorLocal)) {
        Write-LogInstalacao "Coletor não encontrado em $origem e não existe cópia local."
        exit 1
    }

    $argumentos = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$coletorLocal`" -Destino `"$Destino`""
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentos
    # Na inicialização, com atraso para não competir com o login; e uma vez por dia no meio do expediente.
    $gatilhoBoot = New-ScheduledTaskTrigger -AtStartup
    $gatilhoBoot.Delay = 'PT10M'
    $gatilhoDia = New-ScheduledTaskTrigger -Daily -At '12:15' -RandomDelay (New-TimeSpan -Minutes 30)
    $gatilhos = @($gatilhoBoot, $gatilhoDia)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew -RunOnlyIfNetworkAvailable -Hidden
    Register-ScheduledTask -TaskName $nomeTarefa -Action $acao -Trigger $gatilhos -Principal $principal -Settings $config `
        -Description 'Inventario local da estacao para o Assessment Nextec. Somente leitura.' -Force | Out-Null

    # Primeira coleta sem esperar o gatilho: se não há resultado ou ele está velho.
    $ultimo = Join-Path $pastaLocal "$($env:COMPUTERNAME.ToUpper()).json"
    if (-not (Test-Path $ultimo) -or ((Get-Date) - (Get-Item $ultimo).LastWriteTime).TotalDays -gt 6) {
        Start-ScheduledTask -TaskName $nomeTarefa
        Write-LogInstalacao 'Tarefa registrada e primeira coleta disparada.'
    } else {
        Write-LogInstalacao 'Tarefa registrada.'
    }
    exit 0
} catch {
    Write-LogInstalacao "ERRO: $($_.Exception.Message)"
    exit 2
}
