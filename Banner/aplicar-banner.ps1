# Nextec | Aplica o aviso de acesso (antes da senha) e o quadro informativo (área de trabalho) no Windows Server
#
# Uso (PowerShell como administrador, dentro do servidor):
#   $nome     = ''                   # Vazio = usa o nome real da máquina
#   $funcao   = 'Servidor Escriba'
#   $ambiente = 'Produção'           # Produção | Homologação | Testes
#   $papel    = 'Manter'             # Manter = quadro sobre o papel de parede atual | Azul = azul Nextec liso | Preto = preto liso
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#   $s = Join-Path $env:TEMP 'aplicar-banner.ps1'
#   Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner/aplicar-banner.ps1' -OutFile $s
#   & $s -Nome $nome -Funcao $funcao -Ambiente $ambiente -PapelDeParede $papel
#
# Pode ser executado de novo a qualquer momento: baixa o quadro do repositório, faz backup do que mudar e regrava tudo.
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [string]$Nome = '',
    [string]$Funcao = '',
    [string]$Ambiente = '',
    [ValidateSet('Manter', 'Azul', 'Preto', 'Remover')]
    [string]$PapelDeParede = 'Manter'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BaseUrl    = if ($env:BANNER_BASE_URL) { $env:BANNER_BASE_URL } else { 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner' }
$Pasta      = Join-Path $env:ProgramData 'Nextec\Banner'
$Quadro     = Join-Path $Pasta 'quadro-windows.ps1'
$TarefaNome = 'Nextec - Banner da area de trabalho'
$Stamp      = Get-Date -Format 'yyyyMMddHHmmss'

function Falha([string]$mensagem) { throw "Erro: $mensagem" }

# Remove caracteres de controle e espaços nas pontas
function Limpar([string]$texto) { ($texto -replace '[\x00-\x1F\x7F]', '').Trim() }

function Baixar([string]$url, [string]$destino) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing -TimeoutSec 60
    } catch {
        Falha "não foi possível baixar $url ($($_.Exception.Message))."
    }
    if (-not (Test-Path -LiteralPath $destino) -or (Get-Item -LiteralPath $destino).Length -eq 0) {
        Falha "$url veio vazio."
    }
}

# ---------- Validação ----------
$identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalAtual = New-Object Security.Principal.WindowsPrincipal($identidade)
if (-not $principalAtual.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Falha 'execute o PowerShell como administrador.'
}

$Nome     = Limpar $Nome
$Funcao   = Limpar $Funcao
$Ambiente = Limpar $Ambiente
if ([string]::IsNullOrWhiteSpace($Funcao))   { Falha 'informe a função.' }
if ([string]::IsNullOrWhiteSpace($Ambiente)) { Falha 'informe o ambiente.' }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------- 1. Baixa o quadro do repositório ----------
$tmp = Join-Path $env:TEMP "nextec-banner-$Stamp"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $novoQuadro = Join-Path $tmp 'quadro-windows.ps1'
    Baixar "$BaseUrl/quadro-windows.ps1" $novoQuadro
    $erros = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($novoQuadro, [ref]$tokens, [ref]$erros)
    if ($erros) { Falha "quadro-windows.ps1 tem erro de sintaxe ($($erros[0].Message))." }
    Write-Host "Quadro baixado de $BaseUrl"

    # ---------- 2. Instala o quadro ----------
    New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
    if ((Test-Path -LiteralPath $Quadro) -and ((Get-FileHash $Quadro).Hash -ne (Get-FileHash $novoQuadro).Hash)) {
        Copy-Item -LiteralPath $Quadro -Destination "$Quadro.bak.$Stamp" -Force
        Write-Host "Backup do quadro anterior: $Quadro.bak.$Stamp"
    }
    Copy-Item -LiteralPath $novoQuadro -Destination $Quadro -Force
    Write-Host "Quadro instalado em $Quadro"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Restos da versão que usava BGInfo
foreach ($antigo in 'Bginfo64.exe', 'servidor.bgi') {
    $caminho = Join-Path $Pasta $antigo
    if (Test-Path -LiteralPath $caminho) {
        Remove-Item -LiteralPath $caminho -Force
        Write-Host "Arquivo antigo removido: $antigo"
    }
}

# ---------- 3. Variáveis do servidor ----------
$variaveis = [ordered]@{
    NEXTEC_NOME_SERVIDOR = $(if ($Nome) { $Nome } else { $null })
    NEXTEC_FUNCAO        = $Funcao
    NEXTEC_AMBIENTE      = $Ambiente
    NEXTEC_PAPEL_DE_PAREDE = $PapelDeParede
    NEXTEC_SERVIDOR      = $null   # usada só pela versão antiga; removida
}
foreach ($chave in $variaveis.Keys) {
    [Environment]::SetEnvironmentVariable($chave, $variaveis[$chave], 'Machine')
    # Também na sessão atual, para o quadro aplicado no passo 6 já enxergar os valores
    [Environment]::SetEnvironmentVariable($chave, $variaveis[$chave], 'Process')
}
Write-Host 'Variáveis NEXTEC_* gravadas na máquina.'

# ---------- 4. Aviso antes da senha ----------
$politica = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$titulo = 'Aviso: acesso restrito'
$texto = "Este sistema é de uso exclusivo de pessoas autorizadas.`r`n`r`nTodas as atividades são monitoradas e registradas. Ao prosseguir, você declara estar ciente e de acordo com esse monitoramento.`r`n`r`nO acesso ou uso não autorizado está sujeito às medidas administrativas, civis e criminais cabíveis."

$tituloAtual = (Get-ItemProperty -Path $politica -Name 'legalnoticecaption' -ErrorAction SilentlyContinue).legalnoticecaption
$textoAtual  = (Get-ItemProperty -Path $politica -Name 'legalnoticetext' -ErrorAction SilentlyContinue).legalnoticetext
if (($tituloAtual -and $tituloAtual -ne $titulo) -or ($textoAtual -and $textoAtual -ne $texto)) {
    $backupAviso = Join-Path $Pasta "aviso-anterior.$Stamp.txt"
    Set-Content -LiteralPath $backupAviso -Value @($tituloAtual, $textoAtual) -Encoding UTF8
    Write-Host "Aviso anterior salvo em $backupAviso"
}
Set-ItemProperty -Path $politica -Name 'legalnoticecaption' -Value $titulo
Set-ItemProperty -Path $politica -Name 'legalnoticetext' -Value $texto
Write-Host 'Aviso gravado no registro (vale a partir do próximo login).'

if ((Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain) {
    Write-Host 'Atenção: servidor em domínio. Se existir GPO com o aviso de logon interativo, ela prevalece sobre o registro local.'
}

# ---------- 5. Tarefa agendada (redesenha o quadro a cada login) ----------
# O grupo Users é resolvido pelo SID, porque o nome muda conforme o idioma do Windows (Users, Usuários...)
$grupoUsuarios = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount]).Value
$argumentos = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Quadro`""
$acao      = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentos
$gatilho   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId $grupoUsuarios -RunLevel Limited
$config    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $TarefaNome -Action $acao -Trigger $gatilho -Principal $principal -Settings $config -Force | Out-Null
Write-Host "Tarefa agendada registrada: $TarefaNome"

# ---------- 6. Aplica agora ----------
& $Quadro
Write-Host 'Quadro aplicado na área de trabalho desta sessão.'

# ---------- 7. Conferência ----------
Write-Host ''
Write-Host 'Variáveis gravadas:'
foreach ($chave in 'NEXTEC_NOME_SERVIDOR', 'NEXTEC_FUNCAO', 'NEXTEC_AMBIENTE', 'NEXTEC_PAPEL_DE_PAREDE') {
    $valor = [Environment]::GetEnvironmentVariable($chave, 'Machine')
    if ($valor) { Write-Host ("  {0,-24} {1}" -f $chave, $valor) }
}
$estado = (Get-ScheduledTask -TaskName $TarefaNome).State
Write-Host "Tarefa agendada: $estado"
Write-Host ''
Write-Host 'Concluído. Confira em uma nova sessão (sair e entrar de novo) antes de fechar esta.'
