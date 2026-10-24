# Nextec | Mantém o painel da área de trabalho (quadro-windows.ps1) igual à versão publicada no repositório
#
# Roda pela tarefa agendada "Nextec - Atualizar banner da area de trabalho" (SYSTEM, todo dia e na inicialização),
# criada pelo aplicar-banner.ps1. Fluxo:
#   1. Pergunta ao GitHub qual é o último commit que alterou o quadro-windows.ps1 (sem baixar o arquivo).
#   2. Mesmo commit da versão instalada: não faz nada.
#   3. Commit diferente: busca o arquivo daquele commit. Igual ao instalado: só registra o commit.
#   4. Servidores da Nextec (NEXTEC_BANNER_TIPO=nextec) instalam na hora; clientes só quando o commit tem 2 dias ou mais.
#   5. Confere a sintaxe, guarda a versão anterior, instala e reabre os painéis. Se nenhum painel voltar em
#      1 minuto, devolve a versão anterior e não tenta aquele commit de novo.
#
# Uso manual (PowerShell como administrador):
#   & 'C:\ProgramData\Nextec\Banner\atualizar-banner.ps1'            # mesma regra da tarefa
#   & 'C:\ProgramData\Nextec\Banner\atualizar-banner.ps1' -Agora     # ignora a espera de 2 dias
# Registro em C:\ProgramData\Nextec\Banner\atualizacao.log.
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [switch]$Agora
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repositorio   = 'Sou-Nextec/Scripts'
$Ramo          = 'main'
$CaminhoRemoto = 'Banner/quadro-windows.ps1'
$Pasta         = Join-Path $env:ProgramData 'Nextec\Banner'
$Quadro        = Join-Path $Pasta 'quadro-windows.ps1'
$ArquivoEstado = Join-Path $Pasta 'versao.json'
$ArquivoLog    = Join-Path $Pasta 'atualizacao.log'
$TarefaPainel  = 'Nextec - Banner da area de trabalho'
$DiasEspera    = 2
$EsperaPainelSegundos = 60

function Registrar([string]$mensagem) {
    $linha = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $mensagem
    Write-Host $linha
    try {
        New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
        Add-Content -LiteralPath $ArquivoLog -Value $linha -Encoding UTF8
        $linhas = @(Get-Content -LiteralPath $ArquivoLog -Encoding UTF8)
        if ($linhas.Count -gt 500) { Set-Content -LiteralPath $ArquivoLog -Value ($linhas | Select-Object -Last 300) -Encoding UTF8 }
    } catch { }
}

# Identificador do conteúdo no git (o mesmo do "git hash-object"): compara sem depender de data nem de nome
function ShaGit([byte[]]$bytes) {
    $cabecalho = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $tudo = New-Object byte[] ($cabecalho.Length + $bytes.Length)
        [Array]::Copy($cabecalho, 0, $tudo, 0, $cabecalho.Length)
        [Array]::Copy($bytes, 0, $tudo, $cabecalho.Length, $bytes.Length)
        return (($sha1.ComputeHash($tudo) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha1.Dispose() }
}

# Decide o que fazer, sem rede nem disco (é o que os testes conferem)
#   nada       commit já instalado, ou commit que já falhou neste servidor
#   registrar  arquivo do commit é igual ao instalado: só grava o commit
#   aguardar   cliente e o commit ainda não tem 2 dias
#   atualizar  instala a versão nova
function Decidir {
    param(
        [string]$CommitInstalado, [string]$CommitRecusado,
        [string]$CommitRemoto, [datetime]$DataRemota,
        [string]$ShaLocal, [string]$ShaRemoto,
        [string]$Tipo, [datetime]$Momento, [int]$DiasEspera, [bool]$SemEspera
    )
    if ($CommitRemoto -eq $CommitInstalado) { return 'nada' }
    if ($CommitRemoto -eq $CommitRecusado) { return 'nada' }
    if ($ShaRemoto -and ($ShaRemoto -eq $ShaLocal)) { return 'registrar' }
    $imediato = $SemEspera -or ($Tipo -eq 'nextec')
    if (-not $imediato -and (($Momento - $DataRemota).TotalDays -lt $DiasEspera)) { return 'aguardar' }
    return 'atualizar'
}

# Data do GitHub em UTC: o Windows PowerShell 5.1 entrega texto ISO e o PowerShell 7 já converte para data
function ParaUtc($valor) {
    if ($valor -is [datetime]) { return $valor.ToUniversalTime() }
    return [DateTimeOffset]::Parse("$valor", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function LerEstado {
    if (-not (Test-Path -LiteralPath $ArquivoEstado)) { return [pscustomobject]@{ Commit = ''; Recusado = '' } }
    $estado = Get-Content -LiteralPath $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ Commit = "$($estado.Commit)"; Recusado = "$($estado.Recusado)" }
}

function GravarEstado([string]$commit, [string]$recusado) {
    [pscustomobject]@{ Commit = $commit; Recusado = $recusado; Atualizado = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -LiteralPath $ArquivoEstado -Encoding UTF8
}

function ApiGitHub([string]$caminho) {
    $cabecalhos = @{ 'User-Agent' = 'Nextec-Banner'; 'Accept' = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repositorio/$caminho" -Headers $cabecalhos -TimeoutSec 60
}

function PaineisAbertos {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*quadro-windows.ps1*' })
}

# Encerra os painéis e pede à tarefa do painel que abra de novo em cada sessão
function ReabrirPaineis {
    foreach ($p in PaineisAbertos) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $TarefaPainel
}

function SintaxeValida([string]$arquivo) {
    $tokens = $null; $erros = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros)
    return (-not $erros)
}

function Atualizar {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path -LiteralPath $Quadro)) { Registrar 'Painel não instalado neste servidor; nada a atualizar.'; return }

    $estado = LerEstado
    $tipo = "$([Environment]::GetEnvironmentVariable('NEXTEC_BANNER_TIPO', 'Machine'))".Trim().ToLower()
    if ($tipo -ne 'nextec') { $tipo = 'cliente' }

    # 1. Último commit que alterou o arquivo (só metadados)
    # O Windows PowerShell 5.1 devolve a lista JSON sem desenrolar; o pipeline pega o primeiro item de verdade
    $ultimo = ApiGitHub "commits?path=$CaminhoRemoto&sha=$Ramo&per_page=1" | ForEach-Object { $_ } | Select-Object -First 1
    if (-not $ultimo) { throw "nenhum commit encontrado para $CaminhoRemoto" }
    $commitRemoto = "$($ultimo.sha)"
    $dataRemota = ParaUtc $ultimo.commit.committer.date
    $curto = $commitRemoto.Substring(0, 7)

    if ($commitRemoto -eq $estado.Commit) { return }   # caso comum: nada mudou, nada a registrar
    if ($commitRemoto -eq $estado.Recusado) { Registrar "Commit $curto já falhou neste servidor; aguardando uma versão nova."; return }

    # 2. Arquivo daquele commit (fixado no commit, para não pegar outra versão no meio do caminho)
    $conteudo = ApiGitHub "contents/$($CaminhoRemoto)?ref=$commitRemoto"
    $bytesRemotos = [Convert]::FromBase64String(($conteudo.content -replace '\s', ''))
    $shaRemoto = ShaGit $bytesRemotos
    if ($shaRemoto -ne "$($conteudo.sha)") { throw "conteúdo baixado não confere com o commit $curto" }
    $shaLocal = ShaGit ([System.IO.File]::ReadAllBytes($Quadro))

    $acao = Decidir -CommitInstalado $estado.Commit -CommitRecusado $estado.Recusado -CommitRemoto $commitRemoto `
        -DataRemota $dataRemota -ShaLocal $shaLocal -ShaRemoto $shaRemoto -Tipo $tipo -Momento ([DateTime]::UtcNow) `
        -DiasEspera $DiasEspera -SemEspera $Agora.IsPresent

    switch ($acao) {
        'registrar' { GravarEstado $commitRemoto $estado.Recusado; Registrar "Painel já está na versão $curto."; return }
        'aguardar'  { Registrar ("Versão {0} de {1:dd/MM/yyyy HH:mm}: servidor de cliente instala após {2} dias." -f $curto, $dataRemota.ToLocalTime(), $DiasEspera); return }
        'nada'      { return }
    }

    # 3. Confere, guarda a anterior e instala
    $temporario = Join-Path $Pasta 'quadro-windows.ps1.novo'
    $anterior = Join-Path $Pasta 'quadro-windows.ps1.anterior'
    [System.IO.File]::WriteAllBytes($temporario, $bytesRemotos)
    if (-not (SintaxeValida $temporario)) {
        Remove-Item -LiteralPath $temporario -Force
        GravarEstado $estado.Commit $commitRemoto
        Registrar "Versão $curto recusada: erro de sintaxe. O painel continua na versão atual."
        return
    }
    $tinhaPainel = (PaineisAbertos).Count -gt 0
    Copy-Item -LiteralPath $Quadro -Destination $anterior -Force
    Move-Item -LiteralPath $temporario -Destination $Quadro -Force
    GravarEstado $commitRemoto ''
    Registrar "Versão $curto instalada (tipo $tipo)."

    if (-not $tinhaPainel) { Registrar 'Nenhuma sessão com painel aberto; a versão nova vale a partir do próximo login.'; return }

    # 4. Reabre os painéis e confere; sem painel em 1 minuto, devolve a anterior
    ReabrirPaineis
    $limite = (Get-Date).AddSeconds($EsperaPainelSegundos)
    while ((Get-Date) -lt $limite -and (PaineisAbertos).Count -eq 0) { Start-Sleep -Seconds 5 }
    Start-Sleep -Seconds 15   # um painel que cai logo depois de abrir também conta como falha
    if ((PaineisAbertos).Count -gt 0) { Registrar "Painéis reabertos na versão $curto."; return }

    Copy-Item -LiteralPath $anterior -Destination $Quadro -Force
    GravarEstado $estado.Commit $commitRemoto
    ReabrirPaineis
    Registrar "Versão $curto não abriu o painel; versão anterior devolvida e $curto não será tentada de novo."
}

try {
    Atualizar
} catch {
    Registrar "Falha na atualização: $($_.Exception.Message)"
    exit 1
}
