# Nextec | Aplica o aviso de acesso (antes da senha) e o quadro informativo (área de trabalho) no Windows Server
#
# Uso (PowerShell como administrador, dentro do servidor), em uma linha só: edite os quatro valores do início e cole:
#   $nome=''; $funcao='Servidor Escriba'; $ambiente='Produção'; $papel='Manter'; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner/aplicar-banner.ps1').Content.TrimStart([char]0xFEFF))) -Nome $nome -Funcao $funcao -Ambiente $ambiente -PapelDeParede $papel
#
#   $nome     Vazio = usa o nome real da máquina
#   -Tipo     cliente (padrão) recebe versões novas do painel 2 dias depois de publicadas; nextec recebe na hora
#   $ambiente Produção | Homologação | Testes
#   $papel    Manter = painel sobre o papel de parede atual, sem alterá-lo (vale também com GPO) | '' (vazio) = fundo preto
#
# O painel é uma janela ancorada na área de trabalho, atualizada a cada 10 segundos, uma por sessão (console ou RDP).
# Pode ser executado de novo a qualquer momento: baixa o quadro do repositório, faz backup do que mudar e regrava tudo.
# Para tirar do servidor, rode com -Remover: devolve o aviso anterior e o papel de parede guardado, apaga tarefa e variáveis.
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [string]$Nome = '',
    [string]$Funcao = '',
    [string]$Ambiente = '',
    [string]$PapelDeParede = 'Manter',  # Manter ou vazio (fundo preto); Preto e Remover são nomes antigos do vazio
    [ValidateSet('cliente', 'nextec')]
    [string]$Tipo = 'cliente',          # nextec: servidores da Nextec recebem versões novas do painel na hora
    [switch]$Remover                    # Tira o painel e o aviso do servidor
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BaseUrl    = if ($env:BANNER_BASE_URL) { $env:BANNER_BASE_URL } else { 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner' }
$Pasta      = Join-Path $env:ProgramData 'Nextec\Banner'
$Quadro     = Join-Path $Pasta 'quadro-windows.ps1'
$TarefaNome = 'Nextec - Banner da area de trabalho'
$Atualizador = Join-Path $Pasta 'atualizar-banner.ps1'
$TarefaAtualizacao = 'Nextec - Atualizar banner da area de trabalho'
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

# ---------- Remoção ----------
if ($Remover) {
    # Encerra os painéis de todas as sessões e apaga a tarefa
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*quadro-windows.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $TarefaNome -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TarefaAtualizacao -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Painéis encerrados e tarefas agendadas removidas.'

    # Papel de parede guardado pelo fundo preto: volta para este usuário; os demais são listados
    $estadoFundo = Join-Path $env:LOCALAPPDATA 'Nextec\fundo-original.json'
    if (Test-Path -LiteralPath $estadoFundo) {
        $estado = Get-Content -LiteralPath $estadoFundo -Raw -Encoding UTF8 | ConvertFrom-Json
        $chaveDesktop = 'HKCU:\Control Panel\Desktop'
        $original = ''
        if ($estado.Caminho -and (Test-Path -LiteralPath $estado.Caminho)) {
            $original = $estado.Caminho
            if ($estado.Estilo) { Set-ItemProperty -Path $chaveDesktop -Name 'WallpaperStyle' -Value "$($estado.Estilo)" }
            if ($estado.Tile)   { Set-ItemProperty -Path $chaveDesktop -Name 'TileWallpaper' -Value "$($estado.Tile)" }
        }
        if (-not ('NextecRemocao' -as [type])) {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class NextecRemocao { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int SystemParametersInfo(int a, int b, string c, int d); }'
        }
        [void][NextecRemocao]::SystemParametersInfo(20, 0, $original, 3)   # 20 = SPI_SETDESKWALLPAPER
        Remove-Item -LiteralPath $estadoFundo -Force
        Write-Host "Papel de parede deste usuário devolvido: '$original'"
    }
    $outros = @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users\*\AppData\Local\Nextec\fundo-original.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $estadoFundo })
    foreach ($o in $outros) {
        Write-Host "Atenção: o usuário da pasta $($o.FullName.Split('\')[2]) ficou com fundo preto. Ele pode voltar o papel de parede pelas Configurações do Windows (o original está em $($o.FullName))."
    }

    # Aviso antes da senha: volta o que existia antes da primeira instalação, se havia; senão, apaga
    $politica = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $backup = Get-ChildItem -Path $Pasta -Filter 'aviso-anterior.*.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($backup) {
        $linhas = @(Get-Content -LiteralPath $backup.FullName -Encoding UTF8)
        Set-ItemProperty -Path $politica -Name 'legalnoticecaption' -Value "$($linhas[0])"
        Set-ItemProperty -Path $politica -Name 'legalnoticetext' -Value (($linhas | Select-Object -Skip 1) -join "`r`n")
        Write-Host "Aviso anterior devolvido (de $($backup.Name))."
    } else {
        Remove-ItemProperty -Path $politica -Name 'legalnoticecaption', 'legalnoticetext' -ErrorAction SilentlyContinue
        Write-Host 'Aviso antes da senha removido (não havia aviso anterior).'
    }

    foreach ($chave in 'NEXTEC_NOME_SERVIDOR', 'NEXTEC_FUNCAO', 'NEXTEC_AMBIENTE', 'NEXTEC_PAPEL_DE_PAREDE', 'NEXTEC_OPACIDADE', 'NEXTEC_BANNER_TIPO') {
        [Environment]::SetEnvironmentVariable($chave, $null, 'Machine')
    }
    Remove-Item -LiteralPath $Pasta -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Variáveis NEXTEC_* e a pasta $Pasta removidas. Concluído."
    return
}

# Sistema suportado: Windows 8 / Server 2012 ou mais novo, Windows PowerShell 5.1 e .NET Framework 4.5 ou mais novo
$so = Get-CimInstance -ClassName Win32_OperatingSystem
if ([Version]$so.Version -lt [Version]'6.2') { Falha "$($so.Caption) não é suportado. O painel precisa do Windows 8 / Server 2012 ou mais novo." }
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { Falha "PowerShell $($PSVersionTable.PSVersion) encontrado. Instale o Windows Management Framework 5.1." }
# Server Core não tem área de trabalho: só o aviso antes da senha é aplicado
$temDesktop = Test-Path -LiteralPath (Join-Path $env:windir 'explorer.exe')
$releaseNet = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
if ($temDesktop -and (-not $releaseNet -or $releaseNet -lt 378389)) { Falha 'o painel precisa do .NET Framework 4.5 ou mais novo.' }
Write-Host "Sistema: $($so.Caption) (build $($so.BuildNumber)), PowerShell $($PSVersionTable.PSVersion)"
if (-not $temDesktop) { Write-Host 'Atenção: Windows sem área de trabalho (Server Core). Só o aviso antes da senha será aplicado.' }

$Nome     = Limpar $Nome
$Funcao   = Limpar $Funcao
$Ambiente = Limpar $Ambiente
if ([string]::IsNullOrWhiteSpace($Funcao))   { Falha 'informe a função.' }
if ([string]::IsNullOrWhiteSpace($Ambiente)) { Falha 'informe o ambiente.' }

# Manter preserva o papel de parede; vazio (e os nomes antigos) pede fundo preto, gravado como Preto
$escolha = (Limpar $PapelDeParede).ToLower()
if ($escolha -eq 'manter') { $PapelDeParede = 'Manter' }
elseif ($escolha -in '', 'preto', 'remover') { $PapelDeParede = 'Preto' }
else { Falha "papel de parede '$PapelDeParede' inválido. Use Manter ou deixe vazio para fundo preto." }

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

    $novoAtualizador = Join-Path $tmp 'atualizar-banner.ps1'
    Baixar "$BaseUrl/atualizar-banner.ps1" $novoAtualizador
    $erros = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($novoAtualizador, [ref]$tokens, [ref]$erros)
    if ($erros) { Falha "atualizar-banner.ps1 tem erro de sintaxe ($($erros[0].Message))." }

    # ---------- 2. Instala o quadro ----------
    New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
    if ((Test-Path -LiteralPath $Quadro) -and ((Get-FileHash $Quadro).Hash -ne (Get-FileHash $novoQuadro).Hash)) {
        Copy-Item -LiteralPath $Quadro -Destination "$Quadro.bak.$Stamp" -Force
        Write-Host "Backup do quadro anterior: $Quadro.bak.$Stamp"
    }
    Copy-Item -LiteralPath $novoQuadro -Destination $Quadro -Force
    Write-Host "Quadro instalado em $Quadro"
    Copy-Item -LiteralPath $novoAtualizador -Destination $Atualizador -Force
    Write-Host "Atualizador instalado em $Atualizador"
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
    NEXTEC_BANNER_TIPO   = $Tipo
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

if ($temDesktop) {
    # ---------- 5. Tarefa agendada (abre o painel em cada sessão e o mantém rodando) ----------
    # O grupo Users é resolvido pelo SID, porque o nome muda conforme o idioma do Windows (Users, Usuários...)
    $grupoUsuarios = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount]).Value
    $argumentos = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Quadro`""
    $acao      = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentos
    $gatilhos  = @(New-ScheduledTaskTrigger -AtLogOn)
    # Reforço: ao conectar ou desbloquear a sessão a tarefa roda de novo; o painel já aberto na sessão ignora a repetição
    try {
        $classe = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
        foreach ($mudanca in 1, 3, 8) {   # 1 = conexão no console, 3 = conexão remota (RDP), 8 = desbloqueio
            $gatilhos += New-CimInstance -CimClass $classe -ClientOnly -Property @{ StateChange = $mudanca; Enabled = $true }
        }
    } catch {
        Write-Host "Aviso: gatilhos de reconexão não criados ($($_.Exception.Message)). Segue só com o gatilho de logon."
        $gatilhos = @($gatilhos[0])
    }
    $principal = New-ScheduledTaskPrincipal -GroupId $grupoUsuarios -RunLevel Limited
    # Sem limite de tempo (o painel roda a sessão inteira), uma instância por sessão (o próprio painel impede duplicar)
    $config    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TarefaNome -Action $acao -Trigger $gatilhos -Principal $principal -Settings $config -Force | Out-Null
    Write-Host "Tarefa agendada registrada: $TarefaNome"

    # ---------- 6. Aplica agora ----------
    # Encerra painéis da versão anterior (em qualquer sessão) para entrar o novo
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*quadro-windows.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    $inicioPainel = (Get-Date).AddSeconds(-1).ToString('yyyy-MM-dd HH:mm:ss')
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentos -WindowStyle Hidden
    try { Start-ScheduledTask -TaskName $TarefaNome } catch { }   # demais sessões ativas; quem já tem painel ignora
    Write-Host 'Painel aberto na sessão atual (outras sessões recebem no próximo login ou reconexão).'

    # ---------- 5b. Atualização do painel (SYSTEM, todo dia e na inicialização) ----------
    # Compara o commit instalado com o do repositório; cliente instala versões com 2 dias ou mais, nextec na hora
    $argsAtualizacao = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Atualizador`""
    $acaoAtualizacao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argsAtualizacao
    $diario = New-ScheduledTaskTrigger -Daily -At '07:00' -RandomDelay (New-TimeSpan -Hours 2)
    $inicializacao = New-ScheduledTaskTrigger -AtStartup
    $inicializacao.Delay = 'PT10M'
    $principalSistema = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $configAtualizacao = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TarefaAtualizacao -Action $acaoAtualizacao -Trigger @($diario, $inicializacao) -Principal $principalSistema -Settings $configAtualizacao -Force | Out-Null
    Write-Host "Tarefa agendada registrada: $TarefaAtualizacao (tipo $Tipo)"

    # Registra o commit da versão instalada, para a primeira verificação já saber de onde parte
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Atualizador | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "Aviso: verificação de versão falhou; veja $Pasta\atualizacao.log. O painel funciona normalmente." }
} else {
    Unregister-ScheduledTask -TaskName $TarefaNome -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TarefaAtualizacao -Confirm:$false -ErrorAction SilentlyContinue
}

# ---------- 7. Conferência ----------
Write-Host ''
Write-Host 'Variáveis gravadas:'
foreach ($chave in 'NEXTEC_NOME_SERVIDOR', 'NEXTEC_FUNCAO', 'NEXTEC_AMBIENTE', 'NEXTEC_PAPEL_DE_PAREDE', 'NEXTEC_BANNER_TIPO') {
    $valor = [Environment]::GetEnvironmentVariable($chave, 'Machine')
    if ($valor) { Write-Host ("  {0,-24} {1}" -f $chave, $valor) }
}
if ($temDesktop) {
    $estado = (Get-ScheduledTask -TaskName $TarefaNome -ErrorAction SilentlyContinue).State
    if (-not $estado) { Falha 'a tarefa agendada não foi encontrada depois do registro.' }
    Write-Host "Tarefa agendada: $estado"
}

# Conferência do painel nesta sessão: o próprio painel confere na tela se apareceu e registra no quadro.log
if ($temDesktop) {
    Write-Host ''
    Write-Host 'Conferindo o painel na tela (até 1 minuto). Deixe o canto superior direito da tela livre...'
    $log = Join-Path $env:LOCALAPPDATA 'Nextec\quadro.log'
    $resultado = ''
    $novas = @()
    for ($i = 0; $i -lt 30 -and -not $resultado; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $log) {
            $novas = @(Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $inicioPainel })
            if ($novas -match 'Painel visível na tela') { $resultado = 'ok' }
            elseif ($novas -match 'nenhum modo de ancoragem') { $resultado = 'falhou' }
        }
        $rodando = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*quadro-windows.ps1*' -and $_.SessionId -eq (Get-Process -Id $PID).SessionId })
        if (-not $rodando -and -not $resultado) { $resultado = 'encerrou' }
    }
    switch ($resultado) {
        'ok'       { Write-Host "Validação: $(($novas -match 'Painel visível na tela' | Select-Object -Last 1).Substring(20))" }
        'falhou'   { Write-Host 'Validação: FALHOU, o painel não apareceu na tela.' }
        'encerrou' { Write-Host 'Validação: FALHOU, o painel encerrou logo depois de abrir.' }
        default    { Write-Host 'Validação: não foi possível conferir na tela (área coberta por janela ou tela bloqueada). Confira o canto superior direito.' }
    }
    if ($resultado -ne 'ok' -and $novas) {
        Write-Host "Últimas linhas de $($log):"
        $novas | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
    }
}
Write-Host ''
Write-Host 'Concluído. Outras sessões já abertas recebem o painel ao reconectar ou no próximo login. Erros do painel ficam em %LOCALAPPDATA%\Nextec\quadro.log.'
