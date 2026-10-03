#requires -version 5.1
<#
.SYNOPSIS
    Atualizador Nextec (Windows).
.DESCRIPTION
    Mantém o monitoramento Nextec desta máquina na versão publicada pela
    Nextec, sem ninguém precisar entrar nela. Roda pela tarefa agendada
    NextecAtualizador (SYSTEM), de madrugada.

    A cada execução:
      1. Baixa o manifesto publicado e a assinatura dele, por HTTPS.
      2. Confere a assinatura RSA com as chaves públicas gravadas NESTE
         arquivo. Manifesto sem assinatura válida é descartado.
      3. Recusa manifesto vencido e manifesto com sequência menor que a
         última aceita (impede reenviar versão antiga).
      4. Respeita a pausa geral e a onda desta máquina (0, 1 ou 2).
      5. Baixa cada arquivo e confere o SHA-256 do manifesto.
      6. Guarda cópia do que está instalado, roda o instalador em
         -Atualizar (sem perguntas) e confere a saúde do Alloy. Se não ficar
         saudável, volta tudo como estava.
      7. Grava métricas para o NOC e um evento por atualização.

    Não aceita comando avulso: só aplica o que veio num manifesto assinado.
.PARAMETER Acao
    executar (padrão, usado pela tarefa), verificar (só mostra), versao.
.NOTES
    Codificação: UTF-8 com BOM.
#>
[CmdletBinding()]
param(
    [ValidateSet("executar","verificar","versao")]
    [string]$Acao = "executar"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Versao = "1.0.0"

# ---------------------------------------------------------------------------
# Chaves públicas confiáveis (RSA, módulo em hexadecimal).
# Preenchidas pelo publicar-versao.py ("gerar-chave").
# ---------------------------------------------------------------------------
$script:ChavesConfiaveis = @(
)

$script:ManifestoUrlPadrao = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/atualizador/manifesto.json"

$script:NextecDir = Join-Path $env:ProgramData "Nextec"
$script:Config = Join-Path $script:NextecDir "atualizador.conf"
$script:Dados = Join-Path $script:NextecDir "atualizador"
$script:Estado = Join-Path $script:Dados "estado.json"
$script:Staging = Join-Path $script:Dados "staging"
$script:Backups = Join-Path $script:Dados "backup"
$script:LogInstalador = Join-Path $script:Dados "instalador.log"

$script:AlloyDir = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"
$script:AlloyExe = Join-Path $script:AlloyDir "alloy-windows-amd64.exe"
$script:AlloyConfig = Join-Path $script:AlloyDir "config.alloy"
$script:AlloyDados = Join-Path $env:ProgramData "GrafanaLabs\Alloy"
$script:ColetaDir = Join-Path $script:AlloyDados "coleta-complementar"
$script:Textfile = Join-Path $script:ColetaDir "textfile\atualizador.prom"
$script:Eventos = Join-Path $script:ColetaDir "eventos.jsonl"
$script:Registro = "HKLM\SOFTWARE\GrafanaLabs\Alloy"
$script:AlloyReady = "http://127.0.0.1:12345/-/ready"

$script:FormatoManifesto = 1
$script:TamanhoMinimoChave = 3072
$script:LimiteManifesto = 1MB
$script:LimiteArquivo = 50MB
$script:LimiteAlloy = 400MB
$script:TempoInstaladorMs = 45 * 60 * 1000
$script:TempoSaudeSeg = 180
$script:ArquivosWindows = @("instalador", "coleta", "atualizador")

# Arquivos que a volta automática restaura (configuração, nunca binários).
$script:ArquivosBackup = @(
    (Join-Path $script:AlloyDir "config.alloy"),
    (Join-Path $script:AlloyDir "blackbox.yml"),
    (Join-Path $script:AlloyDir "snmp.yml"),
    (Join-Path $script:AlloyDir "snmp-auth.yml"),
    (Join-Path $script:ColetaDir "coleta-complementar.ps1"),
    (Join-Path $script:ColetaDir "coleta-complementar.ini"),
    (Join-Path $script:AlloyDados "nextec-speedtest\Invoke-NextecSpeedtest.ps1"),
    (Join-Path $script:NextecDir "atualizador\nextec-atualizador.ps1"),
    (Join-Path $script:NextecDir "atualizador.conf")
)

$script:Utf8SemBom = New-Object Text.UTF8Encoding($false)
# Identificação do conteúdo do pacote do manifesto atual (preenchida ao aceitá-lo).
$script:PacoteAtual = ""

class Recusa : System.Exception {
    [string]$Resultado
    [string]$Nivel
    Recusa([string]$resultado, [string]$detalhe, [string]$nivel) : base($detalhe) {
        $this.Resultado = $resultado
        $this.Nivel = $nivel
    }
}

function New-Recusa([string]$Resultado, [string]$Detalhe, [string]$Nivel = "aviso") {
    return [Recusa]::new($Resultado, $Detalhe, $Nivel)
}

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

function Write-Log([string]$Nivel, [string]$Mensagem) {
    # Write-Host e não Write-Output: saída no pipeline viraria parte do valor
    # devolvido pelas funções que registram log.
    Write-Host ("{0} nivel={1} msg=""{2}""" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Nivel, $Mensagem.Replace('"', "'"))
}

function Get-Agora { return [DateTime]::UtcNow }

# Calculado à mão: ToUnixTimeSeconds só existe a partir do .NET 4.6.
$script:Epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
function Get-Epoch([DateTime]$Data = [DateTime]::UtcNow) {
    return [long][Math]::Floor(($Data.ToUniversalTime() - $script:Epoch).TotalSeconds)
}

function Test-DotNetSuportado {
    # RSA.VerifyData com HashAlgorithmName exige .NET Framework 4.6 ou mais novo.
    return ($null -ne ("System.Security.Cryptography.HashAlgorithmName" -as [type]))
}

function ConvertTo-DataUtc($Valor, [string]$Campo) {
    # PowerShell 7 converte datas ISO do JSON em DateTime; o 5.1 entrega texto.
    if ($Valor -is [DateTime]) { return $Valor.ToUniversalTime() }
    $texto = [string]$Valor
    $saida = [DateTime]::MinValue
    $estilo = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParseExact($texto, "yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture, $estilo, [ref]$saida)) {
        return $saida
    }
    throw (New-Recusa "manifesto_invalido" ("data inválida em {0}: {1}" -f $Campo, $texto) "erro")
}

function Write-ArquivoAtomico([string]$Caminho, [byte[]]$Bytes) {
    $pasta = Split-Path -Parent $Caminho
    if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    $tmp = Join-Path $pasta (".tmp-{0}" -f [guid]::NewGuid().ToString("N"))
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    Move-Item -LiteralPath $tmp -Destination $Caminho -Force
}

function Get-Download([string]$Url, [long]$Limite) {
    if (-not $Url.StartsWith("https://")) {
        throw (New-Recusa "manifesto_invalido" ("endereço sem HTTPS recusado: {0}" -f $Url) "erro")
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # HttpWebRequest em vez de Invoke-WebRequest: lê no máximo o limite (um
    # arquivo gigante não enche o disco) e permite recusar redirecionamento
    # para fora do HTTPS.
    $pedido = [Net.HttpWebRequest]::Create($Url)
    $pedido.UserAgent = "nextec-atualizador/" + $script:Versao
    $pedido.Headers["Cache-Control"] = "no-cache"
    $pedido.Timeout = 600000
    $pedido.ReadWriteTimeout = 600000
    $resposta = $pedido.GetResponse()
    try {
        if ($resposta.ResponseUri.Scheme -ne "https") {
            throw (New-Recusa "manifesto_invalido" ("redirecionamento para fora do HTTPS recusado: {0}" -f $resposta.ResponseUri) "erro")
        }
        $fluxo = $resposta.GetResponseStream()
        $memoria = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 65536
        while (($lidos = $fluxo.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memoria.Write($buffer, 0, $lidos)
            if ($memoria.Length -gt $Limite) {
                throw (New-Recusa "falha_download" ("arquivo maior que o limite: {0}" -f $Url) "erro")
            }
        }
        return ,$memoria.ToArray()
    }
    finally {
        $resposta.Close()
    }
}

function Get-CodigoHttp($ErroRegistro) {
    # A WebException costuma vir embrulhada (MethodInvocationException).
    $erro = $ErroRegistro.Exception
    while ($null -ne $erro) {
        if ($erro -is [Net.WebException] -and $null -ne $erro.Response) {
            try { return [int]$erro.Response.StatusCode } catch { return 0 }
        }
        $erro = $erro.InnerException
    }
    return 0
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") })) }
    finally { $sha.Dispose() }
}

function ConvertFrom-Hex([string]$Hex) {
    if ($Hex.Length % 2 -ne 0 -or $Hex -notmatch '^[0-9a-fA-F]+$') { return $null }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$bytes
}

# ---------------------------------------------------------------------------
# Assinatura RSA (PKCS#1 v1.5, SHA-256)
# ---------------------------------------------------------------------------

function Get-ChavesValidas {
    $validas = @()
    foreach ($chave in $script:ChavesConfiaveis) {
        $modulo = ConvertFrom-Hex ([string]$chave.N)
        if ($null -eq $modulo) { continue }
        # Remove zero à esquerda, se houver, para medir o tamanho real.
        $inicio = 0
        while ($inicio -lt $modulo.Length -and $modulo[$inicio] -eq 0) { $inicio++ }
        $modulo = [byte[]]$modulo[$inicio..($modulo.Length - 1)]
        if ($modulo.Length * 8 -lt $script:TamanhoMinimoChave) { continue }
        $e = [long]$chave.E
        if ($e -lt 3 -or $e % 2 -eq 0) { continue }
        $expoente = [BitConverter]::GetBytes($e)
        [Array]::Reverse($expoente)
        $i = 0
        while ($i -lt $expoente.Length - 1 -and $expoente[$i] -eq 0) { $i++ }
        $validas += [pscustomobject]@{ Id = [string]$chave.Id; Modulo = $modulo; Expoente = [byte[]]$expoente[$i..($expoente.Length - 1)] }
    }
    return ,$validas
}

function Test-Assinatura([byte[]]$Dados, [byte[]]$Assinatura, $Chaves) {
    foreach ($chave in $Chaves) {
        if ($Assinatura.Length -ne $chave.Modulo.Length) { continue }
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $parametros = New-Object Security.Cryptography.RSAParameters
            $parametros.Modulus = $chave.Modulo
            $parametros.Exponent = $chave.Expoente
            $rsa.ImportParameters($parametros)
            if ($rsa.VerifyData($Dados, $Assinatura, [Security.Cryptography.HashAlgorithmName]::SHA256,
                                [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
                if ([string]::IsNullOrEmpty($chave.Id)) { return "sem_id" }
                return $chave.Id
            }
        }
        catch {
            continue
        }
        finally {
            $rsa.Dispose()
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Configuração, estado e identificação
# ---------------------------------------------------------------------------

function Read-Config {
    $cfg = @{ Habilitado = $true; Onda = "auto"; ManifestoUrl = $script:ManifestoUrlPadrao }
    if (Test-Path -LiteralPath $script:Config) {
        foreach ($linha in [IO.File]::ReadAllLines($script:Config)) {
            if ($linha -match '^\s*([a-z_]+)\s*=\s*(.*?)\s*$') {
                switch ($Matches[1]) {
                    "habilitado"    { $cfg.Habilitado = @("sim","s","1","true") -contains $Matches[2].ToLowerInvariant() }
                    "onda"          { $cfg.Onda = $Matches[2].ToLowerInvariant() }
                    "manifesto_url" { if ($Matches[2]) { $cfg.ManifestoUrl = $Matches[2] } }
                }
            }
        }
    }
    if (@("auto","0","1","2") -notcontains $cfg.Onda) { $cfg.Onda = "auto" }
    return $cfg
}

function Read-Estado {
    if (Test-Path -LiteralPath $script:Estado) {
        try {
            $obj = [IO.File]::ReadAllText($script:Estado) | ConvertFrom-Json
            $estado = @{}
            foreach ($p in $obj.PSObject.Properties) { $estado[$p.Name] = $p.Value }
            if ($estado.ContainsKey("falhas")) { $estado["falhas"] = @($estado["falhas"]) }
            return $estado
        }
        catch {
            Write-Log "aviso" "estado ilegível; começando do zero"
        }
    }
    return @{}
}

function Save-Estado([hashtable]$Estado) {
    $json = $Estado | ConvertTo-Json -Depth 5
    Write-ArquivoAtomico $script:Estado ($script:Utf8SemBom.GetBytes($json))
}

function Read-Identificacao {
    # O instalador grava a identificação no cabeçalho do config.alloy.
    $id = @{}
    if (Test-Path -LiteralPath $script:AlloyConfig) {
        foreach ($m in [Regex]::Matches([IO.File]::ReadAllText($script:AlloyConfig), '(?m)^\s*//\s*nextec:(?<chave>[a-z_]+)\s*=\s*(?<valor>.*?)\s*$')) {
            $id[$m.Groups["chave"].Value] = $m.Groups["valor"].Value
        }
    }
    return $id
}

function Get-OndaDaMaquina($Cfg, $Id) {
    if ($Cfg.Onda -ne "auto") { return [int]$Cfg.Onda }
    $cliente = if ($Id.ContainsKey("cliente")) { $Id["cliente"] } else { "" }
    $hostLabel = if ($Id.ContainsKey("host")) { $Id["host"] } else { "" }
    if ($cliente -eq "nextec") { return 0 }
    $hex = Get-Sha256Hex ($script:Utf8SemBom.GetBytes(("{0}/{1}" -f $cliente, $hostLabel)))
    $sorteio = [Convert]::ToUInt32($hex.Substring(0, 8), 16)
    if ($sorteio % 10 -eq 0) { return 1 }
    return 2
}

# ---------------------------------------------------------------------------
# Manifesto
# ---------------------------------------------------------------------------

function Get-Manifesto($Cfg, [hashtable]$Estado) {
    $chaves = Get-ChavesValidas
    if (-not (Test-DotNetSuportado)) {
        throw (New-Recusa "dotnet_antigo" "o .NET Framework desta máquina é anterior ao 4.6; atualize o .NET para receber atualizações" "erro")
    }
    if ($chaves.Count -eq 0) {
        throw (New-Recusa "sem_chave" "nenhuma chave pública configurada neste atualizador" "erro")
    }
    $url = $Cfg.ManifestoUrl
    try {
        $bruto = Get-Download $url $script:LimiteManifesto
        $assinaturaTexto = [Text.Encoding]::ASCII.GetString((Get-Download ($url + ".sig") 16KB)).Trim()
    }
    catch [Recusa] { throw }
    catch {
        throw (New-Recusa "erro_rede" ("não foi possível baixar o manifesto: {0}" -f $_.Exception.Message))
    }
    try { $assinatura = [Convert]::FromBase64String($assinaturaTexto) }
    catch { throw (New-Recusa "assinatura_invalida" "arquivo de assinatura ilegível" "erro") }

    $chaveId = Test-Assinatura $bruto $assinatura $chaves
    if (-not $chaveId) {
        throw (New-Recusa "assinatura_invalida" "assinatura do manifesto não confere com nenhuma chave confiável" "erro")
    }
    try { $m = $script:Utf8SemBom.GetString($bruto) | ConvertFrom-Json }
    catch { throw (New-Recusa "manifesto_invalido" "manifesto assinado mas ilegível" "erro") }

    Test-Manifesto $m
    if ((Get-Agora) -gt (ConvertTo-DataUtc $m.valido_ate "valido_ate")) {
        throw (New-Recusa "manifesto_vencido" ("manifesto vencido em {0}" -f $m.valido_ate) "erro")
    }
    $ultima = if ($Estado.ContainsKey("sequencia")) { [long]$Estado["sequencia"] } else { 0 }
    $resumo = Get-Sha256Hex $bruto
    if ([long]$m.sequencia -lt $ultima) {
        throw (New-Recusa "versao_antiga" ("manifesto com sequência {0} menor que a já aceita {1}" -f $m.sequencia, $ultima) "erro")
    }
    if ([long]$m.sequencia -eq $ultima -and $Estado.ContainsKey("manifesto_sha256") -and $Estado["manifesto_sha256"] -ne $resumo) {
        throw (New-Recusa "manifesto_divergente" ("manifesto com a mesma sequência {0} e conteúdo diferente do já aceito" -f $ultima) "erro")
    }
    # Aceito: a sequência fica registrada antes de pausa e onda (anti-rollback).
    $Estado["sequencia"] = [long]$m.sequencia
    $Estado["manifesto_sha256"] = $resumo
    $script:PacoteAtual = (Get-Sha256Hex ($script:Utf8SemBom.GetBytes(($m.windows | ConvertTo-Json -Depth 6 -Compress)))).Substring(0, 16)
    return $m
}

function Test-Propriedade($Objeto, [string]$Nome) {
    return ($null -ne $Objeto) -and ($null -ne ($Objeto.PSObject.Properties.Match($Nome) | Select-Object -First 1))
}

function Test-Manifesto($m) {
    if (-not (Test-Propriedade $m "formato") -or $m.formato -ne $script:FormatoManifesto) {
        throw (New-Recusa "manifesto_invalido" "formato de manifesto não suportado" "erro")
    }
    if (-not (Test-Propriedade $m "sequencia") -or -not ($m.sequencia -is [int] -or $m.sequencia -is [long]) -or $m.sequencia -lt 1) {
        throw (New-Recusa "manifesto_invalido" "sequência inválida" "erro")
    }
    if (-not (Test-Propriedade $m "versao") -or [string]$m.versao -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,40}\z') {
        throw (New-Recusa "manifesto_invalido" "versão inválida" "erro")
    }
    if (-not (Test-Propriedade $m "ondas") -or -not (Test-Propriedade $m "valido_ate")) {
        throw (New-Recusa "manifesto_invalido" "ondas ou validade ausentes" "erro")
    }
    foreach ($onda in @("0","1","2")) {
        if ((Test-Propriedade $m.ondas $onda) -and $null -ne $m.ondas.$onda) { [void](ConvertTo-DataUtc $m.ondas.$onda ("ondas." + $onda)) }
    }
    if (-not (Test-Propriedade $m "windows") -or -not (Test-Propriedade $m.windows "arquivos")) {
        throw (New-Recusa "manifesto_invalido" "seção windows ausente" "erro")
    }
    foreach ($nome in $script:ArquivosWindows) {
        if (-not (Test-Propriedade $m.windows.arquivos $nome)) {
            throw (New-Recusa "manifesto_invalido" ("arquivo {0} ausente" -f $nome) "erro")
        }
        Test-ItemDownload $m.windows.arquivos.$nome $nome
    }
    foreach ($nome in @("alloy","alloy_anterior")) {
        if ((Test-Propriedade $m.windows $nome) -and $null -ne $m.windows.$nome) {
            if ([string]$m.windows.$nome.versao -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\z') {
                throw (New-Recusa "manifesto_invalido" ("versão do Alloy inválida em {0}" -f $nome) "erro")
            }
            Test-ItemDownload $m.windows.$nome $nome
        }
    }
}

function Test-ItemDownload($Item, [string]$Nome) {
    if (-not ([string]$Item.url).StartsWith("https://")) {
        throw (New-Recusa "manifesto_invalido" ("{0} sem HTTPS" -f $Nome) "erro")
    }
    if ([string]$Item.sha256 -notmatch '^[0-9a-f]{64}\z') {
        throw (New-Recusa "manifesto_invalido" ("{0} sem SHA-256" -f $Nome) "erro")
    }
}

function Get-PausaAtiva($Cfg) {
    # A pausa não é assinada de propósito: ela só consegue impedir, nunca instalar.
    $url = $Cfg.ManifestoUrl.Substring(0, $Cfg.ManifestoUrl.LastIndexOf("/")) + "/pausa.json"
    try {
        $bytes = Get-Download $url 16KB
    }
    catch [Recusa] { throw }
    catch {
        if ((Get-CodigoHttp $_) -eq 404) { return $null }
        throw (New-Recusa "erro_rede" ("não foi possível ler a pausa: {0}" -f $_.Exception.Message))
    }
    $texto = $script:Utf8SemBom.GetString($bytes)
    if ([string]::IsNullOrWhiteSpace($texto)) { return "arquivo de pausa vazio" }
    try { $dados = $texto | ConvertFrom-Json }
    catch { return "arquivo de pausa ilegível" }
    if ($null -eq $dados) { return "arquivo de pausa ilegível" }
    if ((Test-Propriedade $dados "pausado") -and $dados.pausado -eq $true) {
        $motivo = if (Test-Propriedade $dados "motivo") { [string]$dados.motivo } else { "sem motivo informado" }
        if ($motivo.Length -gt 200) { $motivo = $motivo.Substring(0, 200) }
        return $motivo
    }
    return $null
}

# ---------------------------------------------------------------------------
# Aplicação
# ---------------------------------------------------------------------------

function Get-ItemVerificado($Item, [string]$Nome, [string]$Destino, [long]$Limite) {
    try { $bytes = Get-Download ([string]$Item.url) $Limite }
    catch [Recusa] { throw }
    catch { throw (New-Recusa "falha_download" ("falha ao baixar {0}: {1}" -f $Nome, $_.Exception.Message)) }
    if ((Get-Sha256Hex $bytes) -ne [string]$Item.sha256) {
        throw (New-Recusa "hash_invalido" ("SHA-256 de {0} não confere com o manifesto" -f $Nome) "erro")
    }
    Write-ArquivoAtomico $Destino $bytes
    return $Destino
}

function Get-VersaoAlloy {
    if (-not (Test-Path -LiteralPath $script:AlloyExe)) { return "" }
    try {
        $saida = (& $script:AlloyExe --version 2>$null | Select-Object -First 1) -join ""
        if ($saida -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    }
    catch { }
    return ""
}

function Test-AlloySaudavel {
    $servico = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    if ($null -eq $servico -or $servico.Status -ne "Running") { return $false }
    try {
        $r = Invoke-WebRequest -Uri $script:AlloyReady -UseBasicParsing -TimeoutSec 5
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
    }
    catch { return $false }
}

function Wait-Saude {
    $limite = (Get-Date).AddSeconds($script:TempoSaudeSeg)
    while ((Get-Date) -lt $limite) {
        if (Test-AlloySaudavel) {
            # Confere de novo depois de um intervalo: serviço que cai logo
            # depois de subir também é falha.
            Start-Sleep -Seconds 20
            if (Test-AlloySaudavel) { return $true }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function New-Backup {
    $pasta = Join-Path $script:Backups ("antes-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    $indice = @()
    $n = 0
    foreach ($arquivo in $script:ArquivosBackup) {
        $n++
        if (Test-Path -LiteralPath $arquivo -PathType Leaf) {
            Copy-Item -LiteralPath $arquivo -Destination (Join-Path $pasta ("{0}.arq" -f $n)) -Force
            $indice += [pscustomobject]@{ Caminho = $arquivo; Copia = ("{0}.arq" -f $n) }
        }
        else {
            $indice += [pscustomobject]@{ Caminho = $arquivo; Copia = "" }
        }
    }
    $indice | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pasta "indice.json") -Encoding UTF8
    $reg = Join-Path $pasta "alloy.reg"
    # Processo separado: o reg.exe escreve no stderr até em sucesso, o que o
    # PowerShell 5.1 com ErrorAction Stop trataria como erro.
    $p = Start-Process -FilePath "reg.exe" -ArgumentList @("export", ('"{0}"' -f $script:Registro), ('"{0}"' -f $reg), "/y") `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ("reg export terminou com código {0}" -f $p.ExitCode) }
    return $pasta
}

function Restore-Backup([string]$Pasta) {
    $indice = Get-Content -LiteralPath (Join-Path $Pasta "indice.json") -Raw | ConvertFrom-Json
    foreach ($item in @($indice)) {
        if ([string]::IsNullOrEmpty($item.Copia)) {
            Remove-Item -LiteralPath $item.Caminho -Force -ErrorAction SilentlyContinue
        }
        else {
            Copy-Item -LiteralPath (Join-Path $Pasta $item.Copia) -Destination $item.Caminho -Force
        }
    }
    $reg = Join-Path $Pasta "alloy.reg"
    if (Test-Path -LiteralPath $reg) {
        $p = Start-Process -FilePath "reg.exe" -ArgumentList @("import", ('"{0}"' -f $reg)) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw ("reg import terminou com código {0}" -f $p.ExitCode) }
    }
    # Credenciais voltam só para SYSTEM e Administradores, como o instalador deixa.
    Protect-ChaveRegistro
    $auth = Join-Path $script:AlloyDir "snmp-auth.yml"
    if (Test-Path -LiteralPath $auth) { Protect-ArquivoRestrito $auth }
}

function Protect-ArquivoRestrito([string]$Caminho) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
        $id = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, "FullControl", "Allow")))
    }
    Set-Acl -LiteralPath $Caminho -AclObject $acl
}

function Protect-PastaRestrita([string]$Caminho) {
    <#
        Pasta só de SYSTEM e Administradores (estado, cópias com credenciais,
        arquivos baixados). Dono Administradores e herança para o conteúdo.
    #>
    if (-not (Test-Path -LiteralPath $Caminho)) { New-Item -ItemType Directory -Path $Caminho -Force | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
        $id = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    }
    Set-Acl -LiteralPath $Caminho -AclObject $acl
}

function Protect-ChaveRegistro {
    $chave = "HKLM:\SOFTWARE\GrafanaLabs\Alloy"
    if (-not (Test-Path -LiteralPath $chave)) { return }
    try {
        $acl = New-Object Security.AccessControl.RegistrySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
            $id = New-Object Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($id, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
        }
        Set-Acl -LiteralPath $chave -AclObject $acl
    }
    catch {
        Write-Log "aviso" ("não foi possível restringir a chave de registro do Alloy: {0}" -f $_.Exception.Message)
    }
}

function Invoke-InstaladorAlloy([string]$Arquivo) {
    $p = Start-Process -FilePath $Arquivo -ArgumentList @("/S", "/DISABLEREPORTING=yes") -Wait -PassThru
    return ($p.ExitCode -eq 0)
}

function Invoke-Instalador($Arquivos, $Manifesto) {
    $argumentos = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $Arquivos.instalador),
        "-Atualizar",
        "-ColetaArquivo", ('"{0}"' -f $Arquivos.coleta),
        "-AtualizadorArquivo", ('"{0}"' -f $Arquivos.atualizador),
        "-PacoteVersao", $Manifesto.versao
    )
    if ($Arquivos.ContainsKey("alloy")) {
        $argumentos += @("-AlloyInstaladorArquivo", ('"{0}"' -f $Arquivos.alloy), "-AlloyVersao", [string]$Manifesto.windows.alloy.versao)
    }
    $saida = Join-Path $script:Dados "instalador-saida.log"
    $erros = Join-Path $script:Dados "instalador-erros.log"
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentos -PassThru -NoNewWindow `
        -RedirectStandardOutput $saida -RedirectStandardError $erros
    # Sem guardar o handle, o PowerShell 5.1 perde o ExitCode desse processo.
    $null = $p.Handle
    if (-not $p.WaitForExit($script:TempoInstaladorMs)) {
        # Mata a árvore inteira (instalador do Alloy, msiexec), não só o PowerShell.
        Start-Process -FilePath "taskkill.exe" -ArgumentList @("/T", "/F", "/PID", $p.Id) -Wait -NoNewWindow | Out-Null
        $codigo = 124
    }
    else {
        $codigo = $p.ExitCode
    }
    $registro = "`r`n===== {0} versão {1} (código {2}) =====`r`n" -f (Get-Date -Format "s"), $Manifesto.versao, $codigo
    foreach ($f in @($saida, $erros)) {
        if (Test-Path -LiteralPath $f) { $registro += [IO.File]::ReadAllText($f); Remove-Item -LiteralPath $f -Force }
    }
    [IO.File]::AppendAllText($script:LogInstalador, $registro, $script:Utf8SemBom)
    # 2 = instalado com pendência opcional (ex.: um teste de velocidade que falhou).
    return $codigo
}

function Invoke-Aplicacao($Manifesto) {
    $pasta = Join-Path $script:Staging ([string]$Manifesto.versao)
    if (Test-Path -LiteralPath $pasta) { Remove-Item -LiteralPath $pasta -Recurse -Force }
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null

    $arquivos = @{}
    foreach ($nome in $script:ArquivosWindows) {
        $ext = if ($nome -eq "atualizador" -or $nome -eq "instalador" -or $nome -eq "coleta") { ".ps1" } else { "" }
        $arquivos[$nome] = Get-ItemVerificado $Manifesto.windows.arquivos.$nome $nome (Join-Path $pasta ($nome + $ext)) $script:LimiteArquivo
    }

    $alloyAntes = Get-VersaoAlloy
    $alloyNova = if ((Test-Propriedade $Manifesto.windows "alloy") -and $null -ne $Manifesto.windows.alloy) { [string]$Manifesto.windows.alloy.versao } else { "" }
    if ($alloyNova -and $alloyNova -ne $alloyAntes) {
        $arquivos["alloy"] = Get-ItemVerificado $Manifesto.windows.alloy "alloy" (Join-Path $pasta "alloy-installer-windows-amd64.exe") $script:LimiteAlloy
    }

    $backup = New-Backup
    Write-Log "info" ("aplicando versão {0}; backup em {1}" -f $Manifesto.versao, $backup)

    $codigo = Invoke-Instalador $arquivos $Manifesto
    if (($codigo -eq 0 -or $codigo -eq 2) -and (Wait-Saude)) {
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pasta -Recurse -Force -ErrorAction SilentlyContinue
        return @("ok", ("versão {0} aplicada" -f $Manifesto.versao))
    }

    $motivo = if ($codigo -ne 0 -and $codigo -ne 2) { "instalador terminou com código {0}" -f $codigo } else { "serviço não ficou saudável" }
    Write-Log "erro" ("atualização falhou; voltando a versão anterior: {0}" -f $motivo)

    if ($alloyAntes -and (Get-VersaoAlloy) -ne $alloyAntes -and (Test-Propriedade $Manifesto.windows "alloy_anterior") -and
        $null -ne $Manifesto.windows.alloy_anterior -and [string]$Manifesto.windows.alloy_anterior.versao -eq $alloyAntes) {
        try {
            $anterior = Get-ItemVerificado $Manifesto.windows.alloy_anterior "alloy_anterior" (Join-Path $pasta "alloy-anterior.exe") $script:LimiteAlloy
            [void](Invoke-InstaladorAlloy $anterior)
        }
        catch {
            Write-Log "erro" ("não foi possível reinstalar o Alloy {0}: {1}" -f $alloyAntes, $_.Exception.Message)
        }
    }
    # O instalador do Alloy reescreve config e registro: a restauração vem depois.
    try {
        Restore-Backup $backup
    }
    catch {
        Restart-Service -Name "Alloy" -Force -ErrorAction SilentlyContinue
        return @("falha_rollback", ("{0}; a volta automática falhou: {1} (backup em {2})" -f $motivo, $_.Exception.Message, $backup))
    }
    Restart-Service -Name "Alloy" -Force -ErrorAction SilentlyContinue
    if (Wait-Saude) {
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        return @("falha_instalacao", ("{0}; versão anterior restaurada" -f $motivo))
    }
    return @("falha_rollback", ("{0}; a volta automática não deixou o Alloy saudável (backup em {1})" -f $motivo, $backup))
}

# ---------------------------------------------------------------------------
# Saídas para o NOC
# ---------------------------------------------------------------------------

function ConvertTo-Rotulo([string]$Valor) {
    return $Valor.Replace("\", "\\").Replace("`n", " ").Replace('"', '\"')
}

function Write-Metricas([hashtable]$Estado, [string]$Resultado, [int]$Onda, $Manifesto) {
    $pasta = Split-Path -Parent $script:Textfile
    if (-not (Test-Path -LiteralPath $pasta)) { return }
    $disponivel = ""
    $validade = 0
    if ($null -ne $Manifesto) {
        $disponivel = [string]$Manifesto.versao
        try { $validade = Get-Epoch (ConvertTo-DataUtc $Manifesto.valido_ate "valido_ate") } catch { $validade = 0 }
    }
    $instalada = if ($Estado.ContainsKey("versao_instalada")) { [string]$Estado["versao_instalada"] } else { "" }
    $aplicada = if ($Estado.ContainsKey("aplicada_em")) { [long]$Estado["aplicada_em"] } else { 0 }
    $sequencia = if ($Estado.ContainsKey("sequencia")) { [long]$Estado["sequencia"] } else { 0 }
    $agora = Get-Epoch
    $linhas = @(
        "# HELP nextec_atualizador_info Versões do atualizador e do pacote Nextec nesta máquina.",
        "# TYPE nextec_atualizador_info gauge",
        ('nextec_atualizador_info{{versao_agente="{0}",versao_instalada="{1}",versao_disponivel="{2}",onda="{3}"}} 1' -f $script:Versao, (ConvertTo-Rotulo $instalada), (ConvertTo-Rotulo $disponivel), $Onda),
        "# HELP nextec_atualizador_resultado Resultado da última execução (1 no resultado atual).",
        "# TYPE nextec_atualizador_resultado gauge",
        ('nextec_atualizador_resultado{{resultado="{0}"}} 1' -f (ConvertTo-Rotulo $Resultado)),
        "# HELP nextec_atualizador_ultima_execucao_segundos Fim da última execução (epoch).",
        "# TYPE nextec_atualizador_ultima_execucao_segundos gauge",
        ("nextec_atualizador_ultima_execucao_segundos {0}" -f $agora),
        "# HELP nextec_atualizador_ultima_atualizacao_segundos Última versão aplicada com sucesso (epoch).",
        "# TYPE nextec_atualizador_ultima_atualizacao_segundos gauge",
        ("nextec_atualizador_ultima_atualizacao_segundos {0}" -f $aplicada),
        "# HELP nextec_atualizador_sequencia Sequência do último manifesto aceito.",
        "# TYPE nextec_atualizador_sequencia gauge",
        ("nextec_atualizador_sequencia {0}" -f $sequencia),
        "# HELP nextec_atualizador_manifesto_valido_ate_segundos Vencimento do manifesto atual (epoch).",
        "# TYPE nextec_atualizador_manifesto_valido_ate_segundos gauge",
        ("nextec_atualizador_manifesto_valido_ate_segundos {0}" -f $validade)
    )
    # Sem BOM e com quebra de linha no fim: exigências do coletor textfile.
    try { Write-ArquivoAtomico $script:Textfile ($script:Utf8SemBom.GetBytes(($linhas -join "`n") + "`n")) }
    catch { Write-Log "aviso" ("não foi possível gravar as métricas: {0}" -f $_.Exception.Message) }
}

function Write-Evento([string]$Evento, [string]$Nivel, [string]$Detalhe, [string]$Versao = "") {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $script:Eventos))) { return }
    if ($Detalhe.Length -gt 500) { $Detalhe = $Detalhe.Substring(0, 500) }
    $linha = [ordered]@{
        ts        = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fff+00:00")
        tipo      = "atualizador_evento"
        categoria = "atualizacao"
        evento    = $Evento
        nivel     = $Nivel
        detalhe   = $Detalhe
    }
    if ($Versao) { $linha["versao"] = $Versao }
    try { [IO.File]::AppendAllText($script:Eventos, (($linha | ConvertTo-Json -Compress) + "`n"), $script:Utf8SemBom) }
    catch { Write-Log "aviso" ("não foi possível registrar o evento: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

function Invoke-Ciclo {
    $estado = Read-Estado
    $onda = -1
    $manifesto = $null
    $resultado = "erro"
    $aplicando = $false
    try {
        $cfg = Read-Config
        $id = Read-Identificacao
        $onda = Get-OndaDaMaquina $cfg $id
        if (-not $cfg.Habilitado) { throw (New-Recusa "desligado" ("atualizador desligado em " + $script:Config) "info") }
        if (-not $id.ContainsKey("cliente")) {
            throw (New-Recusa "sem_estado" "config.alloy sem identificação Nextec; rode o instalador uma vez" "erro")
        }
        $manifesto = Get-Manifesto $cfg $estado
        $pausa = Get-PausaAtiva $cfg
        if ($pausa) { throw (New-Recusa "pausado" ("atualizações pausadas: " + $pausa) "info") }

        $liberada = if (Test-Propriedade $manifesto.ondas ([string]$onda)) { $manifesto.ondas.([string]$onda) } else { $null }
        if ($null -eq $liberada -or (Get-Agora) -lt (ConvertTo-DataUtc $liberada "ondas")) {
            throw (New-Recusa "aguardando_onda" ("versão {0} ainda não liberada para a onda {1}" -f $manifesto.versao, $onda) "info")
        }
        # O pacote é identificado pelo conteúdo (arquivos e Alloy), não só pelo nome da versão.
        $pacote = $script:PacoteAtual
        if ($estado.ContainsKey("pacote_instalado") -and $estado["pacote_instalado"] -eq $pacote) {
            $estado["versao_instalada"] = [string]$manifesto.versao
            throw (New-Recusa "atualizado" ("já na versão {0}" -f $manifesto.versao) "info")
        }
        $falhas = if ($estado.ContainsKey("falhas")) { @($estado["falhas"]) } else { @() }
        if ($falhas -contains $pacote) {
            throw (New-Recusa "falhou_antes" ("versão {0} já falhou nesta máquina; aguardando nova versão" -f $manifesto.versao))
        }

        $aplicando = $true
        $r = Invoke-Aplicacao $manifesto
        $aplicando = $false
        $resultado = $r[0]
        if ($resultado -eq "ok") {
            $estado["versao_instalada"] = [string]$manifesto.versao
            $estado["pacote_instalado"] = $pacote
            $estado["aplicada_em"] = Get-Epoch
            Write-Evento "atualizacao_concluida" "info" $r[1] ([string]$manifesto.versao)
            Write-Log "info" $r[1]
        }
        else {
            Add-Falha $estado $pacote
            Write-Evento "atualizacao_falhou" "erro" $r[1] ([string]$manifesto.versao)
            Write-Log "erro" $r[1]
        }
    }
    catch [Recusa] {
        $recusa = $_.Exception
        $resultado = $recusa.Resultado
        Write-Log $recusa.Nivel ("{0} ({1})" -f $recusa.Message, $resultado)
        if ($recusa.Nivel -eq "erro") {
            $v = if ($null -ne $manifesto) { [string]$manifesto.versao } else { "" }
            Write-Evento $resultado "erro" $recusa.Message $v
        }
    }
    catch {
        $resultado = "erro"
        # Falha no meio da aplicação: não tenta a mesma versão toda noite.
        if ($aplicando -and $script:PacoteAtual) { Add-Falha $estado $script:PacoteAtual }
        Write-Log "erro" ("falha inesperada no atualizador: {0}" -f $_.Exception.Message)
        Write-Evento "erro" "erro" ("falha inesperada: {0}" -f $_.Exception.Message)
    }
    finally {
        $estado["ultimo_resultado"] = $resultado
        $estado["ultima_execucao"] = Get-Epoch
        try { Save-Estado $estado } catch { Write-Log "erro" ("não foi possível salvar o estado: {0}" -f $_.Exception.Message) }
        try { Write-Metricas $estado $resultado $onda $manifesto } catch { Write-Log "erro" ("não foi possível gravar as métricas: {0}" -f $_.Exception.Message) }
    }
    if (@("erro","falha_rollback") -contains $resultado) { return 1 }
    return 0
}

function Add-Falha([hashtable]$Estado, [string]$Pacote) {
    $lista = if ($Estado.ContainsKey("falhas")) { @($Estado["falhas"]) } else { @() }
    $lista += $Pacote
    $Estado["falhas"] = @($lista | Select-Object -Last 10)
}

function Invoke-Executar {
    # Pastas só de SYSTEM e Administradores: guardam estado, arquivos baixados
    # e, durante a atualização, a cópia das credenciais.
    Protect-PastaRestrita $script:Dados
    foreach ($p in @($script:Staging, $script:Backups)) {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    # Trava em arquivo dentro da pasta protegida: um mutex global poderia ser
    # segurado por qualquer usuário e congelar as atualizações.
    $trava = $null
    try {
        $trava = [IO.File]::Open((Join-Path $script:Dados "trava"), "OpenOrCreate", "ReadWrite", "None")
    }
    catch {
        Write-Log "aviso" "outra execução do atualizador está em andamento"
        return 0
    }
    try { return (Invoke-Ciclo) }
    finally { $trava.Dispose() }
}

function Invoke-Verificar {
    $cfg = Read-Config
    $estado = Read-Estado
    $id = Read-Identificacao
    $onda = Get-OndaDaMaquina $cfg $id
    Write-Output ("Atualizador Nextec {0}" -f $script:Versao)
    Write-Output ("Habilitado:        {0}" -f $(if ($cfg.Habilitado) { "sim" } else { "não" }))
    Write-Output ("Manifesto:         {0}" -f $cfg.ManifestoUrl)
    Write-Output ("Chaves confiáveis: {0}" -f (Get-ChavesValidas).Count)
    Write-Output ("Cliente/host:      {0}/{1}" -f $(if ($id.ContainsKey("cliente")) { $id["cliente"] } else { "?" }), $(if ($id.ContainsKey("host")) { $id["host"] } else { "?" }))
    Write-Output ("Onda:              {0}{1}" -f $onda, $(if ($cfg.Onda -eq "auto") { " (automática)" } else { "" }))
    Write-Output ("Versão instalada:  {0}" -f $(if ($estado.ContainsKey("versao_instalada")) { $estado["versao_instalada"] } else { "nenhuma registrada" }))
    Write-Output ("Último resultado:  {0}" -f $(if ($estado.ContainsKey("ultimo_resultado")) { $estado["ultimo_resultado"] } else { "nunca executou" }))
    try {
        $m = Get-Manifesto $cfg $estado
        $liberada = if (Test-Propriedade $m.ondas ([string]$onda)) { $m.ondas.([string]$onda) } else { $null }
        Write-Output ("Versão publicada:  {0} (sequência {1}, válida até {2})" -f $m.versao, $m.sequencia, $m.valido_ate)
        Write-Output ("Liberada p/ onda:  {0}" -f $(if ($liberada) { $liberada } else { "ainda não" }))
        $pausa = Get-PausaAtiva $cfg
        Write-Output ("Pausa:             {0}" -f $(if ($pausa) { $pausa } else { "não" }))
    }
    catch [Recusa] {
        Write-Output ("Manifesto:         {0} ({1})" -f $_.Exception.Resultado, $_.Exception.Message)
        return 1
    }
    return 0
}

# Ponto de entrada. Dot-source (testes) só carrega as funções.
if ($MyInvocation.InvocationName -ne ".") {
    switch ($Acao) {
        "versao"    { Write-Output $script:Versao; exit 0 }
        "verificar" { exit (Invoke-Verificar) }
        default     { exit (Invoke-Executar) }
    }
}
