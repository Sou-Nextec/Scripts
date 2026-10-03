#Requires -Version 5.1
<#
.SYNOPSIS
    Coleta Complementar Nextec (Windows).

.DESCRIPTION
    Completa o que o Grafana Alloy não coleta sozinho. Não envia nada para a
    central: grava métricas em arquivos .prom (lidos pelo coletor textfile do
    Alloy) e eventos em JSON por linha (lidos pelo loki.source.file do Alloy).

    Módulos no Windows:
      internet  sempre ligado: saída padrão, DNS, IP público e diagnóstico
      links     cada link de internet do local: status, qualidade, link em
                uso (failover), gateway da operadora e causa das quedas

    O teste de velocidade no Windows continua com o instalador (tarefa
    NextecSpeedtest), que grava as mesmas métricas nextec_speedtest_*.

.PARAMETER Acao
    executar   roda em laço (usado pela tarefa agendada)
    uma-vez    uma rodada, mostrando o que foi gravado
    verificar  confere configuração e dependências
    versao     mostra a versão

.PARAMETER Config
    Caminho do arquivo de configuração. Padrão:
    C:\ProgramData\GrafanaLabs\Alloy\coleta-complementar\coleta-complementar.ini
#>
[CmdletBinding()]
param(
    [ValidateSet("executar", "uma-vez", "verificar", "versao")]
    [string]$Acao = "executar",
    [string]$Config = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Versao = "1.0.0"
$PastaBase = Join-Path $env:ProgramData "GrafanaLabs\Alloy\coleta-complementar"
if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Join-Path $PastaBase "coleta-complementar.ini"
}

$UrlsIpPublico = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
$CausaFirewall = "rede local: firewall sem resposta"
$CausaGateway = "operadora: gateway sem resposta"
$CausaSemSaida = "operadora: gateway responde, sem saída para a internet"
$CausaGeral = "todos os links sem saída com gateways respondendo: instabilidade geral ou firewall"
$CausaSemGateway = "sem saída para a internet (gateway da operadora não configurado)"
$Fora = 0; $Ok = 1; $Degradado = 2
$TamanhoMaxEventos = 10MB
$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)
$Cultura = [System.Globalization.CultureInfo]::InvariantCulture

# -----------------------------------------------------------------------------
# Utilidades
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Nivel, [string]$Mensagem)
    $linha = "{0} nivel={1} msg=""{2}""" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Nivel, $Mensagem
    Write-Host $linha
    try {
        $arquivo = Join-Path $script:PastaDados "coleta-complementar.log"
        if ((Test-Path -LiteralPath $arquivo) -and (Get-Item -LiteralPath $arquivo).Length -gt 5MB) {
            Move-Item -LiteralPath $arquivo -Destination "$arquivo.1" -Force
        }
        [IO.File]::AppendAllText($arquivo, $linha + "`n", $script:Utf8SemBom)
    }
    catch {
        Write-Host "nivel=erro msg=""falha ao gravar o log: $($_.Exception.Message)"""
    }
}

function Read-Ini {
    param([string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho)) {
        throw "Configuração não encontrada: $Caminho"
    }
    $secoes = [ordered]@{}
    $atual = $null
    foreach ($linhaBruta in [IO.File]::ReadAllLines($Caminho, $script:Utf8SemBom)) {
        $linha = ($linhaBruta -replace '\s[;#].*$', '').Trim()
        if ($linha -eq "" -or $linha.StartsWith(";") -or $linha.StartsWith("#")) { continue }
        if ($linha -match '^\[(.+)\]$') {
            $atual = $Matches[1].Trim()
            $secoes[$atual] = @{}
            continue
        }
        if ($null -ne $atual -and $linha -match '^([^=]+)=(.*)$') {
            $secoes[$atual][$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $secoes
}

function Get-Valor {
    param($Secao, [string]$Chave, [string]$Padrao = "")
    if ($null -ne $Secao -and $Secao.ContainsKey($Chave) -and $Secao[$Chave] -ne "") { return $Secao[$Chave] }
    return $Padrao
}

function Split-Lista {
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }
    return @($Texto.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Format-Numero {
    param($Valor)
    return ([double]$Valor).ToString("0.######", $script:Cultura)
}

function Format-Rotulos {
    param([System.Collections.IDictionary]$Rotulos)
    if ($null -eq $Rotulos -or $Rotulos.Count -eq 0) { return "" }
    $pares = foreach ($chave in $Rotulos.Keys) {
        $valor = ([string]$Rotulos[$chave]).Replace("\", "\\").Replace('"', '\"').Replace("`n", " ")
        '{0}="{1}"' -f $chave, $valor
    }
    return "{" + ($pares -join ",") + "}"
}

function New-Metricas { return [ordered]@{} }

function Add-Metrica {
    param($Metricas, [string]$Nome, $Valor, [System.Collections.IDictionary]$Rotulos = $null, [string]$Tipo = "gauge")
    if ($null -eq $Valor) { return }
    if (-not $Metricas.Contains($Nome)) {
        $Metricas[$Nome] = New-Object System.Collections.Generic.List[string]
        $Metricas[$Nome].Add("# TYPE $Nome $Tipo")
    }
    $linha = "{0}{1} {2}" -f $Nome, (Format-Rotulos $Rotulos), (Format-Numero $Valor)
    $Metricas[$Nome].Add($linha)
}

function Save-Atomico {
    <#
        Grava em arquivo temporário e troca com Move-Item. UTF-8 sem BOM e
        terminando em quebra de linha: o coletor textfile do Windows ignora
        arquivo com BOM ou sem a linha final.
    #>
    param([string]$Caminho, [string]$Conteudo)
    $pasta = Split-Path -Parent $Caminho
    if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    $temporario = "$Caminho.tmp"
    [IO.File]::WriteAllText($temporario, $Conteudo, $script:Utf8SemBom)
    Move-Item -LiteralPath $temporario -Destination $Caminho -Force
}

function Save-Metricas {
    param($Metricas, [string]$Caminho)
    $linhas = foreach ($nome in $Metricas.Keys) { $Metricas[$nome] }
    Save-Atomico -Caminho $Caminho -Conteudo ((($linhas) -join "`n") + "`n")
}

function Write-Evento {
    param([string]$Categoria, [string]$Evento, [string]$Nivel = "info", [hashtable]$Campos = @{})
    $registro = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        tipo      = "links_evento"
        categoria = $Categoria
        evento    = $Evento
        nivel     = $Nivel
    }
    foreach ($chave in $Campos.Keys) {
        if ($null -ne $Campos[$chave] -and [string]$Campos[$chave] -ne "") { $registro[$chave] = $Campos[$chave] }
    }
    $linha = $registro | ConvertTo-Json -Compress
    try {
        if ((Test-Path -LiteralPath $script:ArquivoEventos) -and
            (Get-Item -LiteralPath $script:ArquivoEventos).Length -gt $script:TamanhoMaxEventos) {
            Move-Item -LiteralPath $script:ArquivoEventos -Destination "$($script:ArquivoEventos).1" -Force
        }
        [IO.File]::AppendAllText($script:ArquivoEventos, $linha + "`n", $script:Utf8SemBom)
    }
    catch {
        Write-Log "erro" "falha ao gravar evento: $($_.Exception.Message)"
    }
}

function Read-Estado {
    $caminho = Join-Path $script:PastaDados "estado.json"
    if (Test-Path -LiteralPath $caminho) {
        try {
            $objeto = [IO.File]::ReadAllText($caminho, $script:Utf8SemBom) | ConvertFrom-Json
            return (ConvertTo-Hashtable $objeto)
        }
        catch {
            Write-Log "aviso" "estado ilegível, recomeçando do zero"
        }
    }
    return @{}
}

function ConvertTo-Hashtable {
    param($Objeto)
    if ($null -eq $Objeto) { return $null }
    if ($Objeto -is [System.Management.Automation.PSCustomObject]) {
        $tabela = @{}
        foreach ($propriedade in $Objeto.PSObject.Properties) { $tabela[$propriedade.Name] = ConvertTo-Hashtable $propriedade.Value }
        return $tabela
    }
    return $Objeto
}

function Save-Estado {
    Save-Atomico -Caminho (Join-Path $script:PastaDados "estado.json") -Conteudo ($script:Estado | ConvertTo-Json -Depth 6 -Compress)
}

function Get-Secao {
    param([string]$Nome)
    if (-not $script:Estado.ContainsKey($Nome)) { $script:Estado[$Nome] = @{} }
    return $script:Estado[$Nome]
}

function Get-Agora { return [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000 }

# -----------------------------------------------------------------------------
# Rede: ping, rota, DNS e IP público
# -----------------------------------------------------------------------------

function New-ResultadoPing {
    param([string]$Alvo)
    return [pscustomobject]@{ Alvo = $Alvo; Perda = 100.0; Latencia = $null; Jitter = $null; Respondeu = $false }
}

function Complete-ResultadoPing {
    param($Resultado, [int]$Enviados, [double[]]$Tempos)
    if ($Tempos.Count -gt 0) {
        $media = ($Tempos | Measure-Object -Average).Average
        $variancia = ($Tempos | ForEach-Object { [math]::Pow($_ - $media, 2) } | Measure-Object -Average).Average
        $Resultado.Latencia = [math]::Round($media, 3)
        $Resultado.Jitter = [math]::Round([math]::Sqrt($variancia), 3)
        $Resultado.Perda = [math]::Round(100.0 * ($Enviados - $Tempos.Count) / $Enviados, 1)
        $Resultado.Respondeu = $true
    }
    return $Resultado
}

function Invoke-Pings {
    <#
        Pinga vários destinos ao mesmo tempo. Sem IP de origem usa a classe
        Ping do .NET (rápida e independente de idioma). Com IP de origem usa
        o ping.exe -S, porque a classe Ping não escolhe a interface de saída.
    #>
    param([string[]]$Alvos, [string]$Origem = "", [int]$Quantidade = 5, [int]$TimeoutMs = 1000)
    $resultados = [ordered]@{}
    if ($Alvos.Count -eq 0) { return @() }

    if ([string]::IsNullOrWhiteSpace($Origem)) {
        $tarefas = @{}
        foreach ($alvo in $Alvos) { $tarefas[$alvo] = New-Object System.Collections.Generic.List[object] }
        for ($i = 0; $i -lt $Quantidade; $i++) {
            foreach ($alvo in $Alvos) {
                $ping = New-Object System.Net.NetworkInformation.Ping
                try { $tarefas[$alvo].Add($ping.SendPingAsync($alvo, $TimeoutMs)) }
                catch { Write-Log "aviso" "ping não enviado para ${alvo}: $($_.Exception.Message)" }
            }
            Start-Sleep -Milliseconds 200
        }
        foreach ($alvo in $Alvos) {
            $tempos = New-Object System.Collections.Generic.List[double]
            foreach ($tarefa in $tarefas[$alvo]) {
                try {
                    [void]$tarefa.Wait($TimeoutMs + 2000)
                    if ($tarefa.Status -eq "RanToCompletion" -and $tarefa.Result.Status -eq "Success") {
                        $tempos.Add([double]$tarefa.Result.RoundtripTime)
                    }
                }
                catch { }
            }
            $resultados[$alvo] = Complete-ResultadoPing (New-ResultadoPing $alvo) $Quantidade $tempos.ToArray()
        }
        return @($resultados.Values)
    }

    $processos = @{}
    foreach ($alvo in $Alvos) {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = "ping.exe"
        $info.Arguments = "-n $Quantidade -w $TimeoutMs -S $Origem $alvo"
        $info.RedirectStandardOutput = $true
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $processos[$alvo] = [System.Diagnostics.Process]::Start($info)
    }
    foreach ($alvo in $Alvos) {
        $saida = $processos[$alvo].StandardOutput.ReadToEnd()
        $processos[$alvo].WaitForExit()
        $tempos = @()
        foreach ($linha in ($saida -split "`r?`n")) {
            # A linha de resposta tem TTL= em qualquer idioma; o tempo vem como =12ms ou <1ms.
            if ($linha -match 'TTL=' -and $linha -match '[=<](\d+)\s?ms') { $tempos += [double]$Matches[1] }
        }
        $resultados[$alvo] = Complete-ResultadoPing (New-ResultadoPing $alvo) $Quantidade $tempos
    }
    return @($resultados.Values)
}

function Get-Rota {
    param([string]$Alvo)
    try {
        $saida = & tracert.exe -d -h 10 -w 500 $Alvo 2>$null
    }
    catch {
        return @{ ultimo = $null; rota = "rota não registrada: $($_.Exception.Message)" }
    }
    $saltos = New-Object System.Collections.Generic.List[string]
    foreach ($linha in $saida) {
        if ($linha -match '^\s*\d+\s.*?(\d{1,3}(\.\d{1,3}){3})\s*$') {
            if (-not $saltos.Contains($Matches[1])) { $saltos.Add($Matches[1]) }
        }
    }
    if ($saltos.Count -eq 0) { return @{ ultimo = $null; rota = "nenhum salto respondeu" } }
    return @{ ultimo = $saltos[$saltos.Count - 1]; rota = ($saltos -join " > ") }
}

function Get-GatewayPadrao {
    try {
        $rota = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
                Sort-Object -Property RouteMetric | Select-Object -First 1
        if ($null -ne $rota -and $rota.NextHop -ne "0.0.0.0") { return [string]$rota.NextHop }
    }
    catch { }
    return ""
}

function Test-Dns {
    param([string]$Servidor, [string]$Nome)
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Servidor -eq "sistema") {
            [void][System.Net.Dns]::GetHostAddresses($Nome)
        }
        else {
            [void](Resolve-DnsName -Name $Nome -Server $Servidor -Type A -DnsOnly -QuickTimeout -NoHostsFile -ErrorAction Stop)
        }
        return @{ sucesso = $true; tempo = $relogio.Elapsed.TotalMilliseconds }
    }
    catch {
        return @{ sucesso = $false; tempo = $null }
    }
}

function Get-IpPublico {
    param([string[]]$Urls)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in $Urls) {
        try {
            $texto = ([string](Invoke-RestMethod -Uri $url -TimeoutSec 5 -UseBasicParsing)).Trim()
            if ($texto -match '^[0-9a-fA-F:.]{3,45}$') { return $texto }
        }
        catch { continue }
    }
    return $null
}

# -----------------------------------------------------------------------------
# Internet e links
# -----------------------------------------------------------------------------

function Get-Classificacao {
    param($Resultados)
    $respondendo = @($Resultados | Where-Object { $_.Respondeu })
    if ($respondendo.Count -eq 0) { return @{ status = $script:Fora; perda = 100.0; latencia = $null; jitter = $null } }
    # Perda do link é a do melhor destino: um destino externo instável não
    # torna o link ruim (vira evento de instabilidade externa).
    $perda = ($Resultados | Measure-Object -Property Perda -Minimum).Minimum
    $latencia = ($respondendo | Measure-Object -Property Latencia -Average).Average
    $jitter = ($respondendo | Measure-Object -Property Jitter -Average).Average
    $status = $script:Ok
    if ($perda -gt $script:LimitePerda -or $latencia -gt $script:LimiteLatencia) { $status = $script:Degradado }
    return @{ status = $status; perda = $perda; latencia = $latencia; jitter = $jitter }
}

function Get-MotivoDegradado {
    param($Classificacao)
    $motivos = @()
    if ($null -ne $Classificacao.perda -and $Classificacao.perda -gt $script:LimitePerda) { $motivos += "perda alta" }
    if ($null -ne $Classificacao.latencia -and $Classificacao.latencia -gt $script:LimiteLatencia) { $motivos += "latência alta" }
    if ($motivos.Count -eq 0) { return "degradado" }
    return "degradado: " + ($motivos -join " e ")
}

function Update-Contadores {
    param([string]$Chave, [int]$Status)
    $links = Get-Secao "links"
    if (-not $links.ContainsKey($Chave)) {
        $links[$Chave] = @{ rodadas = 0; fora = 0; degradado = 0; segundos_fora = 0.0; status = $null;
                            desde = (Get-Agora); queda_id = $null; inicio_queda = $null }
    }
    $memoria = $links[$Chave]
    $memoria.rodadas = [int]$memoria.rodadas + 1
    if ($Status -eq $script:Fora) {
        $memoria.fora = [int]$memoria.fora + 1
        $memoria.segundos_fora = [double]$memoria.segundos_fora + $script:Intervalo
    }
    elseif ($Status -eq $script:Degradado) {
        $memoria.degradado = [int]$memoria.degradado + 1
    }
    $anterior = $memoria.status
    if ($null -eq $anterior -or [int]$anterior -ne $Status) { $memoria.desde = (Get-Agora) }
    $memoria.status = $Status
    return @{ memoria = $memoria; anterior = $anterior }
}

function Invoke-Transicao {
    param($Memoria, $Anterior, [int]$Status, [string]$Link, [string]$Causa, [string]$AlvoRota)
    if ($null -eq $Anterior) { return }
    $anterior = [int]$Anterior
    $prefixo = if ($Link) { "link" } else { "internet" }
    if ($Status -eq $script:Fora -and $anterior -ne $script:Fora) {
        $nomeQueda = if ($Link) { $Link } else { "internet" }
        $Memoria.queda_id = "{0}-{1}" -f $nomeQueda, [int](Get-Agora)
        $Memoria.inicio_queda = (Get-Agora)
        Write-Evento "queda" "${prefixo}_caiu" "critico" @{ link = $Link; causa = $Causa; queda_id = $Memoria.queda_id }
        if ($AlvoRota) {
            $rota = Get-Rota $AlvoRota
            Write-Evento "queda" "rota_na_queda" "aviso" @{ link = $Link; queda_id = $Memoria.queda_id;
                ultimo_salto = $rota.ultimo; rota = $rota.rota; alvo = $AlvoRota }
        }
    }
    elseif ($anterior -eq $script:Fora -and $Status -ne $script:Fora) {
        $inicio = if ($Memoria.inicio_queda) { [double]$Memoria.inicio_queda } else { Get-Agora }
        Write-Evento "queda" "${prefixo}_voltou" "info" @{ link = $Link; queda_id = $Memoria.queda_id;
            duracao_s = [int][math]::Round((Get-Agora) - $inicio) }
        $Memoria.queda_id = $null
        $Memoria.inicio_queda = $null
    }
    if ($Status -eq $script:Degradado -and $anterior -eq $script:Ok) {
        Write-Evento "qualidade" "${prefixo}_degradado" "aviso" @{ link = $Link }
    }
    elseif ($Status -eq $script:Ok -and $anterior -eq $script:Degradado) {
        Write-Evento "qualidade" "${prefixo}_normalizado" "info" @{ link = $Link }
    }
}

function Update-Destinos {
    param([string]$Grupo, $Resultados, [string]$Link)
    $destinos = Get-Secao "destinos"
    if (-not $destinos.ContainsKey($Grupo)) { $destinos[$Grupo] = @{} }
    $memoria = $destinos[$Grupo]
    $algumOk = @($Resultados | Where-Object { $_.Respondeu }).Count -gt 0
    foreach ($resultado in $Resultados) {
        $caiu = $algumOk -and -not $resultado.Respondeu
        $antes = $memoria.ContainsKey($resultado.Alvo) -and [bool]$memoria[$resultado.Alvo]
        if ($caiu -and -not $antes) {
            Write-Evento "instabilidade_externa" "destino_sem_resposta" "aviso" @{ link = $Link; alvo = $resultado.Alvo }
        }
        elseif ($antes -and $resultado.Respondeu) {
            Write-Evento "instabilidade_externa" "destino_voltou" "info" @{ link = $Link; alvo = $resultado.Alvo }
        }
        $memoria[$resultado.Alvo] = $caiu
    }
}

function Get-LinkAtivo {
    param($Estados)
    if ($script:Links.Count -eq 0) { return $null }
    if ($script:IpAtual) {
        foreach ($link in $script:Links) {
            if ($link.ip_publico -and $link.ip_publico -eq $script:IpAtual) { return $link.nome }
        }
    }
    $noAr = @($script:Links | Where-Object { $Estados[$_.nome].status -ne $script:Fora })
    if ($noAr.Count -eq 1) { return $noAr[0].nome }
    $primarios = @($noAr | Where-Object { $_.papel -eq "primario" })
    if ($primarios.Count -gt 0) { return $primarios[0].nome }
    if ($noAr.Count -gt 0) { return $noAr[0].nome }
    return $null
}

function Invoke-RodadaLinks {
    $metricas = New-Metricas
    $momento = Get-Agora

    $firewallOk = $null
    if ($script:FirewallLocal) {
        $firewallOk = (Invoke-Pings -Alvos @($script:FirewallLocal) -Quantidade 2)[0].Respondeu
    }

    # Internet pela saída padrão
    $resultadosInternet = @(Invoke-Pings -Alvos $script:AlvosInternet)
    $internet = Get-Classificacao $resultadosInternet
    $causaInternet = $null
    if ($internet.status -eq $script:Fora) {
        $causaInternet = if ($firewallOk -eq $false) { $script:CausaFirewall } else { "sem saída para a internet" }
        $diagnosticoInternet = "fora: $causaInternet"
    }
    elseif ($internet.status -eq $script:Degradado) { $diagnosticoInternet = Get-MotivoDegradado $internet }
    else { $diagnosticoInternet = "normal" }

    $contagem = Update-Contadores "__internet__" $internet.status
    $alvoRota = if ($script:AlvosInternet.Count -gt 0) { $script:AlvosInternet[0] } else { $null }
    Invoke-Transicao $contagem.memoria $contagem.anterior $internet.status $null $causaInternet $alvoRota
    Update-Destinos "__internet__" $resultadosInternet $null

    Add-Metrica $metricas "nextec_internet_status" $internet.status
    Add-Metrica $metricas "nextec_internet_latencia_ms" $internet.latencia
    Add-Metrica $metricas "nextec_internet_perda_percentual" $internet.perda
    Add-Metrica $metricas "nextec_internet_jitter_ms" $internet.jitter
    Add-Metrica $metricas "nextec_internet_diagnostico" 1 @{ diagnostico = $diagnosticoInternet }
    Add-Metrica $metricas "nextec_internet_rodadas_total" $contagem.memoria.rodadas -Tipo counter
    Add-Metrica $metricas "nextec_internet_rodadas_fora_total" $contagem.memoria.fora -Tipo counter
    Add-Metrica $metricas "nextec_internet_rodadas_degradado_total" $contagem.memoria.degradado -Tipo counter
    Add-Metrica $metricas "nextec_internet_segundos_fora_total" $contagem.memoria.segundos_fora -Tipo counter
    foreach ($resultado in $resultadosInternet) {
        Add-Metrica $metricas "nextec_internet_alvo_latencia_ms" $resultado.Latencia @{ alvo = $resultado.Alvo }
        Add-Metrica $metricas "nextec_internet_alvo_perda_percentual" $resultado.Perda @{ alvo = $resultado.Alvo }
    }
    if ($null -ne $firewallOk) {
        Add-Metrica $metricas "nextec_internet_firewall_status" ([int]$firewallOk) @{ firewall = $script:FirewallLocal }
    }

    # Cada link: mede todos antes de decidir a causa
    $medicoes = @()
    foreach ($link in $script:Links) {
        $resultados = @()
        if ($link.alvos.Count -gt 0) { $resultados = @(Invoke-Pings -Alvos $link.alvos -Origem $link.origem) }
        $classificacao = if ($resultados.Count -gt 0) { Get-Classificacao $resultados } else { @{ status = $script:Fora; perda = 100.0; latencia = $null; jitter = $null } }
        $gateway = $null
        if ($link.gateway) { $gateway = (Invoke-Pings -Alvos @($link.gateway) -Origem $link.origem -Quantidade 3)[0] }
        $medicoes += [pscustomobject]@{ link = $link; resultados = $resultados; c = $classificacao; gateway = $gateway }
    }
    $todosForaComGateway = $medicoes.Count -gt 1 -and @($medicoes | Where-Object {
        -not ($_.c.status -eq $script:Fora -and $null -ne $_.gateway -and $_.gateway.Respondeu) }).Count -eq 0

    $estados = @{}
    $mudouAlgum = $false
    foreach ($medicao in $medicoes) {
        $link = $medicao.link
        $c = $medicao.c
        $gateway = $medicao.gateway
        $estados[$link.nome] = @{ status = $c.status }
        $causa = $null
        if ($c.status -eq $script:Fora) {
            if ($firewallOk -eq $false) { $causa = $script:CausaFirewall }
            elseif ($todosForaComGateway) { $causa = $script:CausaGeral }
            elseif ($null -eq $gateway) { $causa = $script:CausaSemGateway }
            elseif (-not $gateway.Respondeu) { $causa = $script:CausaGateway }
            else { $causa = $script:CausaSemSaida }
            $diagnostico = "fora: $causa"
        }
        elseif ($c.status -eq $script:Degradado) { $diagnostico = Get-MotivoDegradado $c }
        else { $diagnostico = "normal" }

        $contagem = Update-Contadores $link.nome $c.status
        if ($null -ne $contagem.anterior -and (([int]$contagem.anterior -eq $script:Fora) -ne ($c.status -eq $script:Fora))) { $mudouAlgum = $true }
        $alvoRota = if ($link.alvos.Count -gt 0) { $link.alvos[0] } else { $null }
        Invoke-Transicao $contagem.memoria $contagem.anterior $c.status $link.nome $causa $alvoRota
        Update-Destinos $link.nome $medicao.resultados $link.nome

        $rotulo = [ordered]@{ link = $link.nome }
        Add-Metrica $metricas "nextec_link_status" $c.status $rotulo
        Add-Metrica $metricas "nextec_link_diagnostico" 1 ([ordered]@{ link = $link.nome; diagnostico = $diagnostico })
        Add-Metrica $metricas "nextec_link_latencia_ms" $c.latencia $rotulo
        Add-Metrica $metricas "nextec_link_perda_percentual" $c.perda $rotulo
        Add-Metrica $metricas "nextec_link_jitter_ms" $c.jitter $rotulo
        Add-Metrica $metricas "nextec_link_estado_desde_segundos" ([math]::Round([double]$contagem.memoria.desde)) $rotulo
        Add-Metrica $metricas "nextec_link_rodadas_total" $contagem.memoria.rodadas $rotulo -Tipo counter
        Add-Metrica $metricas "nextec_link_rodadas_fora_total" $contagem.memoria.fora $rotulo -Tipo counter
        Add-Metrica $metricas "nextec_link_rodadas_degradado_total" $contagem.memoria.degradado $rotulo -Tipo counter
        Add-Metrica $metricas "nextec_link_segundos_fora_total" $contagem.memoria.segundos_fora $rotulo -Tipo counter
        if ($null -ne $gateway) {
            Add-Metrica $metricas "nextec_link_gateway_status" ([int]$gateway.Respondeu) $rotulo
            Add-Metrica $metricas "nextec_link_gateway_latencia_ms" $gateway.Latencia $rotulo
        }
        foreach ($resultado in $medicao.resultados) {
            Add-Metrica $metricas "nextec_link_alvo_latencia_ms" $resultado.Latencia ([ordered]@{ link = $link.nome; alvo = $resultado.Alvo })
            Add-Metrica $metricas "nextec_link_alvo_perda_percentual" $resultado.Perda ([ordered]@{ link = $link.nome; alvo = $resultado.Alvo })
        }
        Add-Metrica $metricas "nextec_link_info" 1 ([ordered]@{
            link = $link.nome; papel = $link.papel; operadora = $link.operadora; tipo = $link.tipo
            suporte = $link.suporte; ip_publico = $link.ip_publico; gateway = $link.gateway
            alvos = ($link.alvos -join ", "); firewall = $link.firewall
            interface_firewall = $link.interface_firewall; teste_velocidade = $link.teste_velocidade
        })
    }

    # IP público e link em uso
    if ($mudouAlgum -or ($momento - $script:UltimoIp) -ge $script:IntervaloIp) {
        $script:UltimoIp = $momento
        $novoIp = Get-IpPublico $script:UrlsIp
        $memoriaIp = Get-Secao "ip_publico"
        if ($novoIp -and $memoriaIp.ContainsKey("ip") -and $memoriaIp.ip -and $novoIp -ne $memoriaIp.ip) {
            Write-Evento "failover" "ip_publico_mudou" "aviso" @{ de = $memoriaIp.ip; para = $novoIp }
        }
        if ($novoIp) { $memoriaIp.ip = $novoIp }
        $script:IpAtual = $novoIp
    }
    Add-Metrica $metricas "nextec_internet_ip_publico_sucesso" ([int][bool]$script:IpAtual)
    if ($script:IpAtual) { Add-Metrica $metricas "nextec_internet_ip_publico_info" 1 @{ ip = $script:IpAtual } }

    if ($script:Links.Count -gt 0) {
        $linkAtivo = Get-LinkAtivo $estados
        foreach ($link in $script:Links) {
            Add-Metrica $metricas "nextec_link_ativo" ([int]($link.nome -eq $linkAtivo)) ([ordered]@{ link = $link.nome })
        }
        if ($linkAtivo) {
            Add-Metrica $metricas "nextec_internet_link_ativo_info" 1 @{ link = $linkAtivo }
            $memoriaAtivo = Get-Secao "link_ativo"
            if ($memoriaAtivo.ContainsKey("link") -and $memoriaAtivo.link -and $memoriaAtivo.link -ne $linkAtivo) {
                Write-Evento "failover" "link_ativo_mudou" "aviso" @{ de = $memoriaAtivo.link; para = $linkAtivo }
            }
            $memoriaAtivo.link = $linkAtivo
        }
    }

    # DNS
    $dns = Get-Secao "dns"
    foreach ($servidor in $script:DnsServidores) {
        $teste = Test-Dns $servidor $script:DnsNome
        if (-not $dns.ContainsKey($servidor)) { $dns[$servidor] = @{ consultas = 0; falhas = 0 } }
        $dns[$servidor].consultas = [int]$dns[$servidor].consultas + 1
        if (-not $teste.sucesso) { $dns[$servidor].falhas = [int]$dns[$servidor].falhas + 1 }
        $rotulo = @{ servidor = $servidor }
        Add-Metrica $metricas "nextec_dns_sucesso" ([int]$teste.sucesso) $rotulo
        Add-Metrica $metricas "nextec_dns_resposta_ms" $teste.tempo $rotulo
        Add-Metrica $metricas "nextec_dns_consultas_total" $dns[$servidor].consultas $rotulo -Tipo counter
        Add-Metrica $metricas "nextec_dns_falhas_total" $dns[$servidor].falhas $rotulo -Tipo counter
    }

    Add-Metrica $metricas "nextec_links_intervalo_segundos" $script:Intervalo
    Add-Metrica $metricas "nextec_links_limite_latencia_ms" $script:LimiteLatencia
    Add-Metrica $metricas "nextec_links_limite_perda_percentual" $script:LimitePerda
    Add-Metrica $metricas "nextec_links_coletor_ultima_execucao_segundos" ([math]::Round((Get-Agora)))

    Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar_links.prom")
    Save-Estado
}

function Save-Saude {
    param([bool]$Ok)
    $metricas = New-Metricas
    Add-Metrica $metricas "nextec_coleta_complementar_info" 1 ([ordered]@{ versao = $script:Versao; modulos = "internet" })
    Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$Ok) @{ modulo = "internet" }
    Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar.prom")
}

# -----------------------------------------------------------------------------
# Configuração e execução
# -----------------------------------------------------------------------------

function Initialize-Configuracao {
    $ini = Read-Ini $script:Config
    $geral = if ($ini.Contains("geral")) { $ini["geral"] } else { @{} }
    $internet = if ($ini.Contains("internet")) { $ini["internet"] } else { @{} }

    $script:PastaDados = Get-Valor $geral "pasta_dados" $script:PastaBase
    $script:PastaTextfile = Get-Valor $geral "pasta_textfile" (Join-Path $script:PastaDados "textfile")
    $script:ArquivoEventos = Get-Valor $geral "arquivo_eventos" (Join-Path $script:PastaDados "eventos.jsonl")
    foreach ($pasta in @($script:PastaDados, $script:PastaTextfile)) {
        if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    }

    $script:Intervalo = [math]::Max(10, [int](Get-Valor $geral "intervalo_links_segundos" "15"))
    $script:LimiteLatencia = [double]::Parse((Get-Valor $geral "limite_latencia_ms" "150"), $script:Cultura)
    $script:LimitePerda = [double]::Parse((Get-Valor $geral "limite_perda_percentual" "5"), $script:Cultura)
    $script:AlvosInternet = @(Split-Lista (Get-Valor $internet "alvos" "1.1.1.1, 8.8.8.8"))
    $script:FirewallLocal = Get-Valor $internet "firewall" (Get-GatewayPadrao)
    $script:DnsServidores = @(Split-Lista (Get-Valor $internet "dns_servidores" "sistema, 1.1.1.1, 8.8.8.8"))
    $script:DnsNome = Get-Valor $internet "dns_nome" "google.com"
    $urls = @(Split-Lista (Get-Valor $internet "ip_publico_urls" ""))
    $script:UrlsIp = if ($urls.Count -gt 0) { $urls } else { $script:UrlsIpPublico }
    $script:IntervaloIp = [math]::Max(60, [int](Get-Valor $internet "ip_publico_intervalo_segundos" "300"))
    $script:UltimoIp = 0.0
    $script:IpAtual = $null

    $script:Links = @()
    foreach ($nomeSecao in $ini.Keys) {
        if ($nomeSecao -match '^link:(.+)$') {
            $secao = $ini[$nomeSecao]
            $script:Links += [pscustomobject]@{
                nome               = $Matches[1].Trim()
                papel              = Get-Valor $secao "papel" "primario"
                operadora          = Get-Valor $secao "operadora"
                tipo               = Get-Valor $secao "tipo"
                suporte            = Get-Valor $secao "suporte"
                ip_publico         = Get-Valor $secao "ip_publico"
                gateway            = Get-Valor $secao "gateway"
                alvos              = @(Split-Lista (Get-Valor $secao "alvos"))
                origem             = Get-Valor $secao "origem"
                firewall           = Get-Valor $secao "firewall"
                interface_firewall = Get-Valor $secao "interface_firewall"
                teste_velocidade   = Get-Valor $secao "teste_velocidade" "nao"
            }
        }
    }
    $script:Estado = Read-Estado
}

function Invoke-Executar {
    Initialize-Configuracao
    Write-Log "info" "Coleta Complementar $script:Versao iniciada; links configurados: $($script:Links.Count)"
    Write-Evento "sistema" "coletor_iniciado" "info" @{ detalhe = "Coleta Complementar $script:Versao (Windows): internet" }
    while ($true) {
        $inicio = Get-Agora
        try {
            Invoke-RodadaLinks
            Save-Saude $true
        }
        catch {
            Write-Log "erro" ("rodada falhou: {0} | {1}" -f $_.Exception.Message, ($_.ScriptStackTrace -replace "`r?`n", " <- "))
            try { Save-Saude $false } catch { }
        }
        $espera = $script:Intervalo - ((Get-Agora) - $inicio)
        if ($espera -gt 0) { Start-Sleep -Milliseconds ([int]($espera * 1000)) }
    }
}

function Invoke-UmaVez {
    Initialize-Configuracao
    Invoke-RodadaLinks
    Save-Saude $true
    Get-ChildItem -LiteralPath $script:PastaTextfile -Filter "coleta_complementar*.prom" | ForEach-Object {
        Write-Host "--- $($_.Name)"
        Write-Host ([IO.File]::ReadAllText($_.FullName, $script:Utf8SemBom))
    }
}

function Invoke-Verificar {
    $problemas = @()
    Initialize-Configuracao
    Write-Host "Configuração: $script:Config"
    Write-Host "Links configurados: $($script:Links.Count)"
    Write-Host "Firewall local: $script:FirewallLocal"
    foreach ($link in $script:Links) {
        if ($link.alvos.Count -eq 0) { $problemas += "[link:$($link.nome)] sem alvos: o link nunca terá status" }
        if ($link.origem -and -not (Get-NetIPAddress -IPAddress $link.origem -ErrorAction SilentlyContinue)) {
            $problemas += "[link:$($link.nome)] IP de origem $($link.origem) não existe neste servidor"
        }
    }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        $problemas += "Resolve-DnsName indisponível: a consulta por servidor DNS vai falhar"
    }
    foreach ($problema in $problemas) { Write-Host "PROBLEMA: $problema" }
    if ($problemas.Count -eq 0) { Write-Host "Tudo certo." }
    return $problemas.Count
}

$script:PastaDados = $PastaBase
try {
    switch ($Acao) {
        "executar" { Invoke-Executar }
        "uma-vez" { Invoke-UmaVez }
        "verificar" { exit (Invoke-Verificar) }
        "versao" { Write-Host $Versao }
    }
}
catch {
    Write-Log "erro" ("{0} | {1}" -f $_.Exception.Message, ($_.ScriptStackTrace -replace "`r?`n", " <- "))
    exit 1
}
