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
      acessos   logins RDP e de console (evento 4624) com IP de origem;
                marca acesso privilegiado, origem nova e fora do horário
                para os alertas de acesso privilegiado
      bancos    bancos sem exportador próprio (Firebird, Oracle, SQL
                Anywhere e arquivos SQLite): no ar, conexões, memória,
                tempo ligado e tamanho das bases, no padrão nextec_banco_*.
                O SQL Server segue com o coletor mssql do Alloy.
      virtualizacao  hipervisores (Hyper-V no próprio servidor; VMware,
                Proxmox e XCP-ng pela rede): hosts, VMs, armazenamento,
                snapshots e replicação, no padrão nextec_hipervisor_* e
                nextec_vm_* (mesmos nomes do Linux)
      velocidade  teste de velocidade com o Speedtest CLI da Ookla, nas
                métricas nextec_speedtest_* (mesmos nomes do Linux). O
                teste roda em segundo plano para não atrasar os links.

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

$Versao = "1.5.0"
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
    # -Bruto: só linha inteira vira comentário (senha pode ter ; e #).
    param([string]$Caminho, [switch]$Bruto)
    if (-not (Test-Path -LiteralPath $Caminho)) {
        throw "Configuração não encontrada: $Caminho"
    }
    $secoes = [ordered]@{}
    $atual = $null
    foreach ($linhaBruta in [IO.File]::ReadAllLines($Caminho, $script:Utf8SemBom)) {
        $linha = $(if ($Bruto) { $linhaBruta.Trim() } else { ($linhaBruta -replace '\s[;#].*$', '').Trim() })
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
    param([string]$Categoria, [string]$Evento, [string]$Nivel = "info", [hashtable]$Campos = @{}, [string]$Tipo = "links_evento")
    $registro = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        tipo      = $Tipo
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

function ConvertTo-Mbps {
    param([string]$Texto)
    $numero = 0
    if ($Texto -and [int]::TryParse($Texto.Trim(), [ref]$numero) -and $numero -gt 0 -and $numero -le 100000) { return $numero }
    return $null
}

function Get-IpAprendido {
    # Último IP público visto quando só este link estava no ar.
    param([string]$Nome)
    $melhor = ""; $quando = 0
    $aprendidos = Get-Secao "ip_links"
    foreach ($ip in @($aprendidos.Keys)) {
        $info = $aprendidos[$ip]
        if ($info -is [hashtable] -and $info.link -eq $Nome -and [double]$info.visto -gt $quando) {
            $melhor = $ip; $quando = [double]$info.visto
        }
    }
    return $melhor
}

function Set-IpAprendido {
    # Com um só link no ar, o IP público de saída é dele: guarda o par. Assim
    # ninguém precisa informar o IP de cada link na instalação.
    param([string]$Nome)
    $aprendidos = Get-Secao "ip_links"
    $aprendidos[$script:IpAtual] = @{ link = $Nome; visto = [math]::Round((Get-Agora)) }
    if ($aprendidos.Count -gt 20) {
        $maisAntigo = @($aprendidos.Keys | Sort-Object { if ($aprendidos[$_] -is [hashtable]) { [double]$aprendidos[$_].visto } else { 0 } })[0]
        $aprendidos.Remove($maisAntigo)
    }
}

function Get-LinkAtivo {
    param($Estados)
    if ($script:Links.Count -eq 0) { return $null }
    $noAr = @($script:Links | Where-Object { $Estados[$_.nome].status -ne $script:Fora })
    if ($script:IpAtual) {
        foreach ($link in $script:Links) {
            if ($link.ip_publico -and $link.ip_publico -eq $script:IpAtual) { return $link.nome }
        }
        if ($noAr.Count -eq 1) { Set-IpAprendido $noAr[0].nome }
        $info = (Get-Secao "ip_links")[$script:IpAtual]
        if ($info -is [hashtable] -and @($noAr | Where-Object { $_.nome -eq $info.link }).Count -gt 0) { return $info.link }
    }
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
    Add-Metrica $metricas "nextec_internet_estado_desde_segundos" ([math]::Round([double]$contagem.memoria.desde))
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
            suporte = $link.suporte; ip_publico = $(if ($link.ip_publico) { $link.ip_publico } else { Get-IpAprendido $link.nome }); gateway = $link.gateway
            alvos = ($link.alvos -join ", "); firewall = $link.firewall
            interface_firewall = $link.interface_firewall; teste_velocidade = $link.teste_velocidade
            velocidade_mbps = [string]$link.velocidade_mbps; velocidade_upload_mbps = [string]$link.velocidade_upload_mbps
        })
        foreach ($par in @(@("download", $link.velocidade_mbps), @("upload", $link.velocidade_upload_mbps))) {
            if ($par[1]) {
                Add-Metrica $metricas "nextec_link_velocidade_contratada_mbps" $par[1] ([ordered]@{ link = $link.nome; sentido = $par[0] })
            }
        }
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

# -----------------------------------------------------------------------------
# Acessos (logins com origem)
# -----------------------------------------------------------------------------
# Lê o evento 4624 do log Security (logon RDP tipo 10, console 2 e console com
# credencial em cache 11) e grava um evento por acesso, com a classificação
# usada pelos alertas de acesso privilegiado:
#   alerta=critico  Administrator embutido (RID 500), ou usuário privilegiado
#                   entrando de IP público que ele não usou nesta máquina nos
#                   últimos 30 dias
#   alerta=resumo   usuário privilegiado fora do horário comercial
#   alerta=nenhum   só registro
# Logon de rede (tipo 3, compartilhamento de arquivo) fica de fora: num
# controlador de domínio são milhares por hora.

$TiposLogon = @{ "2" = "console"; "10" = "rdp"; "11" = "console_cache" }
$DiasSemana = @{ "seg" = 0; "ter" = 1; "qua" = 2; "qui" = 3; "sex" = 4; "sab" = 5; "dom" = 6 }
$RedesInternas = @("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "fc00::/7", "fe80::/10")

function Read-Horario {
    param([string]$Texto)
    $grade = @{}
    foreach ($parte in ([string]$Texto).Split(";")) {
        if ($parte.Trim().ToLowerInvariant() -match '^([a-z]{3})(?:-([a-z]{3}))?\s+(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') {
            $fimNome = if ($Matches[2]) { $Matches[2] } else { $Matches[1] }
            if (-not $script:DiasSemana.ContainsKey($Matches[1]) -or -not $script:DiasSemana.ContainsKey($fimNome)) { continue }
            $primeiro = $script:DiasSemana[$Matches[1]]
            $ultimo = $script:DiasSemana[$fimNome]
            $faixa = @(([int]$Matches[3] * 60 + [int]$Matches[4]), ([int]$Matches[5] * 60 + [int]$Matches[6]))
            $dia = $primeiro
            while ($true) {
                if (-not $grade.ContainsKey($dia)) { $grade[$dia] = @() }
                $grade[$dia] += ,$faixa
                if ($dia -eq $ultimo) { break }
                $dia = ($dia + 1) % 7
            }
        }
    }
    return $grade
}

function Test-ForaHorario {
    param([DateTime]$Utc)
    # Brasília, UTC-3 o ano todo (sem horário de verão desde 2019).
    $local = $Utc.AddHours(-3)
    $dia = ([int]$local.DayOfWeek + 6) % 7
    $minuto = $local.Hour * 60 + $local.Minute
    if (-not $script:GradeHorario.ContainsKey($dia)) { return $true }
    foreach ($faixa in $script:GradeHorario[$dia]) {
        if ($minuto -ge $faixa[0] -and $minuto -lt $faixa[1]) { return $false }
    }
    return $true
}

function Test-CidrContem {
    param([string]$Ip, [string]$Cidr)
    $partes = $Cidr.Split("/")
    $endereco = $null; $rede = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$endereco) -or -not [Net.IPAddress]::TryParse($partes[0], [ref]$rede)) { return $false }
    if ($endereco.AddressFamily -ne $rede.AddressFamily) { return $false }
    $a = $endereco.GetAddressBytes(); $b = $rede.GetAddressBytes()
    $bits = if ($partes.Count -gt 1) { [int]$partes[1] } else { $a.Length * 8 }
    for ($i = 0; $i -lt $a.Length -and $bits -gt 0; $i++) {
        $mascara = if ($bits -ge 8) { 255 } else { (0xFF -shl (8 - $bits)) -band 0xFF }
        if (($a[$i] -band $mascara) -ne ($b[$i] -band $mascara)) { return $false }
        $bits -= 8
    }
    return $true
}

function Get-TipoOrigem {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return "local" }
    $endereco = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$endereco)) { return "publica" }
    if ([Net.IPAddress]::IsLoopback($endereco)) { return "local" }
    foreach ($cidr in $script:OrigensConhecidas) { if (Test-CidrContem $Ip $cidr) { return "conhecida" } }
    $ipLocal = if ($script:IpAtual) { $script:IpAtual } else { [string](Get-Secao "ip_publico")["ip"] }
    if ($ipLocal -and $Ip -eq $ipLocal) { return "rede_local" }
    foreach ($cidr in $script:RedesInternas) { if (Test-CidrContem $Ip $cidr) { return "rede_interna" } }
    return "publica"
}

function Get-PrefixoOrigem {
    param([string]$Ip)
    $endereco = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$endereco)) { return $Ip }
    $bytes = $endereco.GetAddressBytes()
    if ($bytes.Length -eq 4) { return ("{0}.{1}.{2}.0/24" -f $bytes[0], $bytes[1], $bytes[2]) }
    return ((0..3 | ForEach-Object { "{0:x2}{1:x2}" -f $bytes[$_ * 2], $bytes[$_ * 2 + 1] }) -join ":") + "::/64"
}

function Test-OrigemNova {
    param([string]$Usuario, [string]$Ip, [double]$Instante)
    $historico = Get-Secao "acessos_origens"
    if (-not $historico.ContainsKey($Usuario)) { $historico[$Usuario] = @{} }
    $prefixo = Get-PrefixoOrigem $Ip
    $anterior = if ($historico[$Usuario].ContainsKey($prefixo)) { [double]$historico[$Usuario][$prefixo] } else { 0 }
    $historico[$Usuario][$prefixo] = [long]$Instante
    return (($Instante - $anterior) -gt ($script:DiasOrigemConhecida * 86400))
}

function Get-NivelAlerta {
    param([bool]$Privilegiado, [bool]$Emergencia, [string]$TipoOrigem, [bool]$Nova, [bool]$Fora)
    if ($Emergencia) { return "critico" }
    if ($Privilegiado -and $TipoOrigem -eq "publica" -and $Nova) { return "critico" }
    if ($Privilegiado -and $Fora) { return "resumo" }
    return "nenhum"
}

function Test-LogonComPrivilegio {
    <#
        ElevatedToken (Windows 10 / Server 2016 em diante) diz se o logon
        recebeu token de administrador. Sem o campo, procura o 4672
        (privilégios especiais) do mesmo LogonId.
    #>
    param($Dados)
    if ($Dados.ContainsKey("ElevatedToken") -and $Dados["ElevatedToken"]) {
        return ($Dados["ElevatedToken"] -eq "%%1842")
    }
    $logonId = [string]$Dados["TargetLogonId"]
    if (-not $logonId) { return $false }
    $xpath = "*[System[(EventID=4672)] and EventData[Data[@Name='SubjectLogonId']='$logonId']]"
    return [bool](Get-WinEvent -LogName Security -FilterXPath $xpath -MaxEvents 1 -ErrorAction SilentlyContinue)
}

function Invoke-RodadaAcessos {
    $memoria = Get-Secao "acessos"
    $ultimo = if ($memoria.ContainsKey("ultimo_record")) { [long]$memoria["ultimo_record"] } else { 0 }
    if ($ultimo -eq 0) {
        # Primeira execução: começa do evento mais recente, sem reprocessar o histórico.
        $maisRecente = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction SilentlyContinue
        $memoria["ultimo_record"] = if ($maisRecente) { [long]$maisRecente.RecordId } else { 1 }
        Save-Estado
        return
    }

    $xpath = "*[System[(EventID=4624) and (EventRecordID > $ultimo)]]"
    $eventos = @(Get-WinEvent -LogName Security -FilterXPath $xpath -MaxEvents 2000 -ErrorAction SilentlyContinue | Sort-Object RecordId)
    if ($eventos.Count -eq 0) { return }

    $logons = New-Object System.Collections.Generic.List[object]
    foreach ($evento in $eventos) {
        $memoria["ultimo_record"] = [long]$evento.RecordId
        $dados = @{}
        foreach ($campo in ([xml]$evento.ToXml()).Event.EventData.Data) { $dados[[string]$campo.Name] = [string]$campo.'#text' }
        $tipoLogon = [string]$dados["LogonType"]
        if (-not $script:TiposLogon.ContainsKey($tipoLogon)) { continue }
        $usuario = [string]$dados["TargetUserName"]
        $sid = [string]$dados["TargetUserSid"]
        if ($usuario.EndsWith('$') -or $usuario -match '^(DWM|UMFD)-' -or $sid -in @("S-1-5-18", "S-1-5-19", "S-1-5-20")) { continue }
        $ip = [string]$dados["IpAddress"]
        if ($ip -eq "-" -or $ip -eq "::1" -or $ip -eq "127.0.0.1") { $ip = "" }
        $logons.Add([pscustomobject]@{
            Instante     = $evento.TimeCreated.ToUniversalTime()
            Usuario      = $usuario
            Dominio      = [string]$dados["TargetDomainName"]
            Sid          = $sid
            Canal        = $script:TiposLogon[$tipoLogon]
            Metodo       = [string]$dados["AuthenticationPackageName"]
            Ip           = $ip
            Privilegiado = (Test-LogonComPrivilegio $dados)
        })
    }

    # Com UAC, um logon de administrador gera dois 4624 (token completo e
    # filtrado). Junta os repetidos em até 10 segundos num acesso só.
    $unicos = New-Object System.Collections.Generic.List[object]
    foreach ($logon in $logons) {
        $anterior = if ($unicos.Count -gt 0) { $unicos[$unicos.Count - 1] } else { $null }
        if ($null -ne $anterior -and $anterior.Usuario -eq $logon.Usuario -and $anterior.Ip -eq $logon.Ip -and
            $anterior.Canal -eq $logon.Canal -and ($logon.Instante - $anterior.Instante).TotalSeconds -le 10) {
            $anterior.Privilegiado = $anterior.Privilegiado -or $logon.Privilegiado
            continue
        }
        $unicos.Add($logon)
    }

    foreach ($logon in $unicos) {
        $emergencia = $logon.Sid -match '-500$'
        $privilegiado = $emergencia -or $logon.Privilegiado
        $tipo = Get-TipoOrigem $logon.Ip
        $instante = ($logon.Instante - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
        $nova = if ($tipo -eq "publica") { Test-OrigemNova $logon.Usuario $logon.Ip $instante } else { $false }
        $fora = Test-ForaHorario $logon.Instante
        $alerta = Get-NivelAlerta $privilegiado $emergencia $tipo $nova $fora
        $nivel = switch ($alerta) { "critico" { "erro" } "resumo" { "aviso" } default { "info" } }
        $onde = if ($logon.Ip) { "de $($logon.Ip)" } else { "no console" }
        Write-Evento -Tipo "acesso_evento" -Categoria "login" -Evento "login" -Nivel $nivel -Campos @{
            usuario          = $logon.Usuario
            dominio          = $logon.Dominio
            canal            = $logon.Canal
            metodo           = $logon.Metodo
            origem_ip        = $logon.Ip
            origem_tipo      = $tipo
            origem_nova      = $(if ($nova) { "sim" } else { "nao" })
            privilegiado     = $(if ($privilegiado) { "sim" } else { "nao" })
            conta_emergencia = $(if ($emergencia) { "sim" } else { "nao" })
            fora_horario     = $(if ($fora) { "sim" } else { "nao" })
            alerta           = $alerta
            detalhe          = ("{0} entrou por {1} {2}" -f $logon.Usuario, $logon.Canal, $onde)
        }
    }

    # Origens antigas saem do histórico depois do prazo.
    $historico = Get-Secao "acessos_origens"
    $limite = (Get-Agora) - ($script:DiasOrigemConhecida * 86400)
    foreach ($usuario in @($historico.Keys)) {
        foreach ($prefixo in @($historico[$usuario].Keys)) {
            if ([double]$historico[$usuario][$prefixo] -lt $limite) { $historico[$usuario].Remove($prefixo) }
        }
        if ($historico[$usuario].Count -eq 0) { $historico.Remove($usuario) }
    }
    Save-Estado
}

# -----------------------------------------------------------------------------
# Módulo bancos
# -----------------------------------------------------------------------------
# Bancos sem exportador Prometheus de uso simples. Não usa driver nem senha:
# olha os processos do banco, as portas em que escutam, as conexões
# estabelecidas nessas portas e o tamanho dos arquivos das bases. Sai no
# padrão nextec_banco_* que o painel "Nextec | Banco de dados" converte junto
# com SQL Server, MySQL/MariaDB e PostgreSQL.

$MotoresBanco = [ordered]@{ firebird = "Firebird"; oracle = "Oracle"; sqlanywhere = "SQL Anywhere"; sqlite = "SQLite" }

function Get-BasesFirebird {
    # Bases declaradas no databases.conf (Firebird 3+) ou aliases.conf (2.x),
    # na pasta do executável do servidor.
    param([string[]]$Pastas)
    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($pasta in $Pastas) {
        foreach ($nome in @("databases.conf", "aliases.conf")) {
            $arquivo = Join-Path $pasta $nome
            if (-not (Test-Path -LiteralPath $arquivo)) { continue }
            foreach ($linha in [IO.File]::ReadAllLines($arquivo)) {
                $limpa = ($linha -replace '#.*$', '').Trim()
                if ($limpa -match '^[^{}=]+=\s*"?([A-Za-z]:\\[^"]+|\\\\[^"]+)"?\s*$' -and -not $bases.Contains($Matches[1].Trim())) {
                    $bases.Add($Matches[1].Trim())
                }
            }
        }
    }
    return ,$bases.ToArray()
}

function Get-InstanciasBanco {
    <#
        Agrupa os processos de cada banco por instância. Devolve uma lista de
        objetos com Motor, Instancia, Pids e Bases.
    #>
    $instancias = [ordered]@{}
    $anotar = {
        param([string]$Motor, [string]$Instancia, [int]$ProcessoId, [string[]]$Bases)
        $chave = "$Motor|$Instancia"
        if (-not $instancias.Contains($chave)) {
            $instancias[$chave] = [pscustomobject]@{ Motor = $Motor; Instancia = $Instancia; Pids = (New-Object System.Collections.Generic.List[int]); Bases = (New-Object System.Collections.Generic.List[string]) }
        }
        $instancias[$chave].Pids.Add($ProcessoId)
        foreach ($b in @($Bases)) { if ($b -and -not $instancias[$chave].Bases.Contains($b)) { $instancias[$chave].Bases.Add($b) } }
    }
    $servicoPorPid = @{}
    foreach ($servico in @(Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue)) {
        if ($servico.ProcessId) { $servicoPorPid[[int]$servico.ProcessId] = [string]$servico.Name }
    }
    $processos = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $temOracle = $false
    foreach ($p in $processos) {
        $nome = ([string]$p.Name).ToLowerInvariant()
        $idProc = [int]$p.ProcessId
        if ($nome -match '^(firebird|fbserver|fb_inet_server)\.exe$') {
            $pastas = @()
            if ($p.ExecutablePath) { $pasta = Split-Path -Parent $p.ExecutablePath; $pastas = @($pasta, (Split-Path -Parent $pasta)) }
            $inst = if ($servicoPorPid.ContainsKey($idProc)) { $servicoPorPid[$idProc] } else { "padrao" }
            & $anotar "firebird" $inst $idProc (Get-BasesFirebird -Pastas $pastas)
        }
        elseif ($nome -match '^(dbsrv|dbeng)\d+\.exe$') {
            $linha = [string]$p.CommandLine
            $inst = if ($linha -match '(?i)\s-n\s+"?([^"\s]+)') { $Matches[1] } elseif ($servicoPorPid.ContainsKey($idProc)) { $servicoPorPid[$idProc] } else { $nome -replace '\.exe$', '' }
            $bases = @([regex]::Matches($linha, '(?i)"([^"]+\.db)"|(\S+\.db)\b') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
            & $anotar "sqlanywhere" $inst $idProc $bases
        }
        elseif ($nome -eq "oracle.exe") {
            $temOracle = $true
            $inst = "padrao"
            if ($servicoPorPid.ContainsKey($idProc) -and $servicoPorPid[$idProc] -match '(?i)^OracleService(.+)$') { $inst = $Matches[1] }
            & $anotar "oracle" $inst $idProc @()
        }
    }
    # O listener (TNSLSNR) recebe as conexões e entrega ao oracle.exe; as
    # portas dele contam para todas as instâncias.
    if ($temOracle) {
        foreach ($p in $processos | Where-Object { ([string]$_.Name) -ieq "tnslsnr.exe" }) {
            foreach ($chave in @($instancias.Keys | Where-Object { $_ -like "oracle|*" })) { $instancias[$chave].Pids.Add([int]$p.ProcessId) }
        }
    }
    return @($instancias.Values)
}

function Invoke-RodadaBancos {
    $metricas = New-Metricas
    $agora = Get-Agora
    $instancias = @(Get-InstanciasBanco)
    $escutas = @(); $estabelecidas = @()
    if ($instancias.Count -gt 0) {
        $escutas = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
        $estabelecidas = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
    }
    $processos = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $processos[[int]$p.Id] = $p }

    $motoresVistos = @($instancias | ForEach-Object { $_.Motor } | Select-Object -Unique)
    foreach ($motor in $script:BancosEsperados) {
        if ($motor -ne "sqlite" -and $motoresVistos -notcontains $motor) {
            Add-Metrica $metricas "nextec_banco_up" 0 ([ordered]@{ motor = $script:MotoresBanco[$motor]; instancia = "padrao" })
        }
    }
    foreach ($inst in $instancias) {
        $rotulos = [ordered]@{ motor = $script:MotoresBanco[$inst.Motor]; instancia = $inst.Instancia }
        $portas = @($escutas | Where-Object { $inst.Pids.Contains([int]$_.OwningProcess) } | ForEach-Object { [int]$_.LocalPort } | Select-Object -Unique)
        $conexoes = @($estabelecidas | Where-Object { $portas -contains [int]$_.LocalPort }).Count
        Add-Metrica $metricas "nextec_banco_up" 1 $rotulos
        Add-Metrica $metricas "nextec_banco_conexoes_total" $conexoes $rotulos
        foreach ($porta in $portas) { Add-Metrica $metricas "nextec_banco_porta_info" 1 ([ordered]@{ motor = $rotulos.motor; instancia = $rotulos.instancia; porta = [string]$porta }) }
        $memoria = 0; $inicio = $null
        foreach ($processoId in $inst.Pids) {
            if (-not $processos.ContainsKey($processoId)) { continue }
            $proc = $processos[$processoId]
            if (([string]$proc.ProcessName) -ieq "tnslsnr") { continue }
            $memoria += [double]$proc.WorkingSet64
            try { if ($null -eq $inicio -or $proc.StartTime -lt $inicio) { $inicio = $proc.StartTime } } catch { }
        }
        Add-Metrica $metricas "nextec_banco_memoria_bytes" $memoria $rotulos
        if ($null -ne $inicio) {
            Add-Metrica $metricas "nextec_banco_ligado_segundos" ([math]::Round(((Get-Date) - $inicio).TotalSeconds)) $rotulos
        }
    }

    $bases = New-Object System.Collections.Generic.List[object]
    foreach ($inst in $instancias) { foreach ($b in $inst.Bases) { $bases.Add(@($inst.Motor, $inst.Instancia, $b)) } }
    foreach ($item in $script:BancosArquivos) {
        $encontrados = @()
        $pasta = Split-Path -Parent $item.Caminho
        $filtro = Split-Path -Leaf $item.Caminho
        if ($pasta -and (Test-Path -LiteralPath $pasta)) { $encontrados = @(Get-ChildItem -LiteralPath $pasta -Filter $filtro -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        # SQLite não tem processo: a pasta das bases é a instância, e ela fica
        # "no ar" enquanto o arquivo existir.
        $instancia = if ($item.Motor -eq "sqlite") { $pasta } else { "padrao" }
        if ($item.Motor -eq "sqlite") {
            Add-Metrica $metricas "nextec_banco_up" ([int]($encontrados.Count -gt 0)) ([ordered]@{ motor = "SQLite"; instancia = $instancia })
        }
        foreach ($b in $encontrados) { $bases.Add(@($item.Motor, $instancia, $b)) }
    }
    $vistos = @{}
    foreach ($b in $bases) {
        $chave = "{0}|{1}" -f $b[0], ([string]$b[2]).ToLowerInvariant()
        if ($vistos.ContainsKey($chave)) { continue }
        $vistos[$chave] = $true
        $arquivo = Get-Item -LiteralPath $b[2] -ErrorAction SilentlyContinue
        if ($null -eq $arquivo) { continue }
        Add-Metrica $metricas "nextec_banco_tamanho_bytes" $arquivo.Length ([ordered]@{ motor = $script:MotoresBanco[$b[0]]; instancia = $b[1]; banco = [IO.Path]::GetFileNameWithoutExtension($arquivo.Name) })
    }
    Add-Metrica $metricas "nextec_bancos_coletor_ultima_execucao_segundos" ([math]::Floor($agora))
    Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar_bancos.prom")
}

# -----------------------------------------------------------------------------
# Módulo velocidade
# -----------------------------------------------------------------------------
# O teste leva de 20 a 60 segundos. Ele roda como processo à parte e o laço
# principal só confere se terminou, para que os links continuem medidos a
# cada rodada. O cmd.exe grava a saída em arquivo sem conversão de página de
# código, o que preserva os acentos do nome do servidor Ookla.

function Start-TesteVelocidade {
    $saida = Join-Path $script:PastaDados "velocidade-saida.json"
    Remove-Item -LiteralPath $saida -Force -ErrorAction SilentlyContinue
    $comando = '/d /c ""{0}" --accept-license --accept-gdpr --format=json --progress=no > "{1}" 2>nul"' -f $script:SpeedtestExe, $saida
    $processo = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\cmd.exe") -ArgumentList $comando -WindowStyle Hidden -PassThru
    $script:TesteVelocidade = [pscustomobject]@{ Processo = $processo; Saida = $saida; Inicio = (Get-Agora) }
}

function Save-ResultadoVelocidade {
    param([double]$Inicio, $Dados, [string]$Erro)
    $metricas = New-Metricas
    $quando = [math]::Floor($Inicio)
    if ($Erro) {
        Add-Metrica $metricas "nextec_speedtest_up" 0
        Add-Metrica $metricas "nextec_speedtest_last_run_timestamp_seconds" $quando
        Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar_velocidade.prom")
        Write-Log "erro" "teste de velocidade falhou: $Erro"
        Write-Evento "velocidade" "teste_velocidade" "aviso" @{ detalhe = "teste falhou: $Erro" }
        return
    }
    $download = [double]$Dados.download.bandwidth * 8
    $upload = [double]$Dados.upload.bandwidth * 8
    $latencia = [double]$Dados.ping.latency
    $jitter = if ($null -ne $Dados.ping.jitter) { [double]$Dados.ping.jitter } else { $null }
    $perda = if ($Dados.PSObject.Properties.Name -contains "packetLoss" -and $null -ne $Dados.packetLoss) { [double]$Dados.packetLoss } else { 0 }
    $servidor = $Dados.server
    Add-Metrica $metricas "nextec_speedtest_up" 1
    Add-Metrica $metricas "nextec_speedtest_download_bits_per_second" $download
    Add-Metrica $metricas "nextec_speedtest_upload_bits_per_second" $upload
    Add-Metrica $metricas "nextec_speedtest_ping_latency_milliseconds" $latencia
    Add-Metrica $metricas "nextec_speedtest_ping_jitter_milliseconds" $jitter
    Add-Metrica $metricas "nextec_speedtest_packet_loss_percent" $perda
    Add-Metrica $metricas "nextec_speedtest_last_run_timestamp_seconds" $quando
    Add-Metrica $metricas "nextec_speedtest_server_info" 1 ([ordered]@{
        server_id = [string]$servidor.id; server_name = [string]$servidor.name; server_location = [string]$servidor.location })
    Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar_velocidade.prom")
    Write-Evento "velocidade" "teste_velocidade" "info" @{
        download_mbps = [math]::Round($download / 1e6, 1); upload_mbps = [math]::Round($upload / 1e6, 1)
        latencia_ms = [math]::Round($latencia, 1); detalhe = [string]$servidor.name }
}

function Invoke-RodadaVelocidade {
    $teste = $script:TesteVelocidade
    if ($null -ne $teste) {
        $decorrido = (Get-Agora) - $teste.Inicio
        if (-not $teste.Processo.HasExited) {
            if ($decorrido -lt 180) { return }
            # taskkill /T encerra também o speedtest.exe filho do cmd.exe.
            & (Join-Path $env:SystemRoot "System32\taskkill.exe") /PID $teste.Processo.Id /T /F 2>&1 | Out-Null
            $script:TesteVelocidade = $null
            Save-ResultadoVelocidade $teste.Inicio $null "sem resposta em 180 s"
            return
        }
        $script:TesteVelocidade = $null
        try {
            $texto = if (Test-Path -LiteralPath $teste.Saida) { [IO.File]::ReadAllText($teste.Saida, $script:Utf8SemBom) } else { "" }
            $linha = @($texto -split "`r?`n" | Where-Object { $_ -match '"type"\s*:\s*"result"' } | Select-Object -Last 1)
            if ($linha.Count -eq 0) { throw "saída do Speedtest CLI sem resultado" }
            $dados = $linha[0] | ConvertFrom-Json
            Save-ResultadoVelocidade $teste.Inicio $dados $null
        }
        catch { Save-ResultadoVelocidade $teste.Inicio $null $_.Exception.Message }
        finally { Remove-Item -LiteralPath $teste.Saida -Force -ErrorAction SilentlyContinue }
        return
    }
    if (((Get-Agora) - $script:UltimoTesteVelocidade) -lt $script:IntervaloVelocidade) { return }
    $script:UltimoTesteVelocidade = Get-Agora
    if (-not (Test-Path -LiteralPath $script:SpeedtestExe)) {
        Save-ResultadoVelocidade (Get-Agora) $null "Speedtest CLI não encontrado em $($script:SpeedtestExe)"
        return
    }
    Start-TesteVelocidade
}

# -----------------------------------------------------------------------------
# Módulo virtualização
# -----------------------------------------------------------------------------
# Hipervisores no padrão nextec_hipervisor_* (host, armazenamento, cluster) e
# nextec_vm_* (cada VM), os mesmos nomes do Linux. Fontes:
#   local      Hyper-V do próprio servidor (Get-VM), sem senha
#   [hipervisor:<nome>]  consulta pela rede: VMware ESXi ou vCenter (SOAP),
#              Proxmox VE (API com token) e XCP-ng (XAPI). Senha e token ficam
#              no arquivo de segredos, com acesso só de SYSTEM e Administradores.
# Snapshots e discos mudam pouco e custam uma chamada por VM: são lidos a cada
# 30 minutos e repetidos nas rodadas do meio.

$PlataformasVirt = [ordered]@{ hyperv = "Hyper-V"; proxmox = "Proxmox VE"; vmware = "VMware"; xcpng = "XCP-ng" }
$IntervaloDetalhesVirt = 1800

function Get-Campo {
    # Lê campo de hashtable ou de objeto do ConvertFrom-Json sem quebrar no
    # modo estrito quando o campo não existe.
    param($Objeto, [string]$Nome)
    if ($null -eq $Objeto) { return $null }
    if ($Objeto -is [System.Collections.IDictionary]) { return $Objeto[$Nome] }
    $propriedade = $Objeto.PSObject.Properties[$Nome]
    if ($null -eq $propriedade) { return $null }
    return $propriedade.Value
}

function ConvertTo-Epoch {
    # Data ISO 8601, formato básico da XAPI (20261001T10:00:00Z) ou DateTime.
    param($Valor)
    if ($null -eq $Valor -or [string]$Valor -eq "") { return $null }
    if ($Valor -is [datetime]) { return [double]([DateTimeOffset]$Valor.ToUniversalTime()).ToUnixTimeSeconds() }
    $texto = [string]$Valor
    $formato = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $data = [datetime]::MinValue
    foreach ($padrao in @("yyyyMMdd'T'HH:mm:ss'Z'", "yyyyMMdd'T'HH:mm:ss")) {
        if ([datetime]::TryParseExact($texto, $padrao, $script:Cultura, $formato, [ref]$data)) {
            return [double]([DateTimeOffset]::new($data, [TimeSpan]::Zero)).ToUnixTimeSeconds()
        }
    }
    $offset = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($texto, $script:Cultura, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$offset)) {
        return [double]$offset.ToUnixTimeSeconds()
    }
    return $null
}

function New-InventarioVirt {
    return @{ Hosts = New-Object System.Collections.ArrayList; Vms = New-Object System.Collections.ArrayList
              Armazenamentos = New-Object System.Collections.ArrayList; Clusters = New-Object System.Collections.ArrayList }
}

function Get-ResumoSnapshots {
    param($Datas)
    $validas = @($Datas | Where-Object { $null -ne $_ })
    if ($validas.Count -eq 0) { return @(0, $null) }
    return @($validas.Count, ($validas | Measure-Object -Minimum).Minimum)
}

function Initialize-TlsNextec {
    # Hipervisor com certificado próprio (padrão do ESXi, Proxmox e XCP-ng):
    # a conexão segue cifrada, só sem conferir quem assinou. A validação é
    # desligada por requisição, nunca no processo inteiro.
    if (-not ("NextecTls" -as [type])) {
        Add-Type -TypeDefinition @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class NextecTls {
    public static bool Aceitar(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
    public static RemoteCertificateValidationCallback SemVerificar = new RemoteCertificateValidationCallback(Aceitar);
}
"@
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Invoke-NextecHttp {
    param([string]$Url, [string]$Metodo = "GET", [string]$Corpo = "", [hashtable]$Cabecalhos = @{}, [bool]$Verificar = $false,
          [string]$TipoConteudo = "application/json")
    Initialize-TlsNextec
    $pedido = [Net.HttpWebRequest]::Create($Url)
    $pedido.Method = $Metodo
    $pedido.Timeout = 60000
    $pedido.ReadWriteTimeout = 60000
    if (-not $Verificar) { $pedido.ServerCertificateValidationCallback = [NextecTls]::SemVerificar }
    foreach ($chave in $Cabecalhos.Keys) { $pedido.Headers[$chave] = [string]$Cabecalhos[$chave] }
    if ($Corpo) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Corpo)
        $pedido.ContentType = $TipoConteudo
        $pedido.ContentLength = $bytes.Length
        $fluxo = $pedido.GetRequestStream(); $fluxo.Write($bytes, 0, $bytes.Length); $fluxo.Close()
    }
    try { $resposta = $pedido.GetResponse() }
    catch [Net.WebException] {
        if ($null -eq $_.Exception.Response) { throw }
        $resposta = $_.Exception.Response
    }
    try {
        $leitor = New-Object IO.StreamReader($resposta.GetResponseStream(), [Text.Encoding]::UTF8)
        return [pscustomobject]@{ Status = [int]$resposta.StatusCode; Corpo = $leitor.ReadToEnd(); Cookie = $resposta.Headers["Set-Cookie"] }
    }
    finally { $resposta.Close() }
}

function Get-HyperVInventario {
    param($Fonte)
    $inv = New-InventarioVirt
    $no = $env:COMPUTERNAME.ToLowerInvariant()
    $so = Get-CimInstance Win32_OperatingSystem
    $cpu = $null
    try {
        $hv = Get-CimInstance -ClassName Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor -Filter "Name = '_Total'" -ErrorAction Stop
        $cpu = [double]$hv.PercentTotalRunTime
    }
    catch { $cpu = [double](@(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average) }
    $vmHost = Get-VMHost
    [void]$inv.Hosts.Add(@{
        no = $no; versao = ("Hyper-V em {0}" -f $so.Caption); cluster = ""; up = 1; cpu_percentual = $cpu
        cpus = [int]$vmHost.LogicalProcessorCount
        memoria_usada = ([double]$so.TotalVisibleMemorySize - [double]$so.FreePhysicalMemory) * 1024
        memoria_total = [double]$so.TotalVisibleMemorySize * 1024
        ligado_segundos = [math]::Round(((Get-Date) - $so.LastBootUpTime).TotalSeconds) })

    $vms = @(Get-VM)
    if (((Get-Agora) - $Fonte.UltimoDetalhe) -ge $script:IntervaloDetalhesVirt) {
        $detalhes = @{}
        $pastas = New-Object System.Collections.Generic.List[string]
        if ($vmHost.VirtualHardDiskPath) { $pastas.Add([string]$vmHost.VirtualHardDiskPath) }
        foreach ($vm in $vms) {
            $datas = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { ConvertTo-Epoch $_.CreationTime })
            $usado = 0.0; $total = 0.0
            foreach ($disco in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | Where-Object { $_.Path })) {
                $pastas.Add([string]$disco.Path)
                try { $vhd = Get-VHD -Path $disco.Path -ErrorAction Stop; $usado += [double]$vhd.FileSize; $total += [double]$vhd.Size } catch { }
            }
            $detalhes[[string]$vm.Id] = @{ Snapshots = (Get-ResumoSnapshots $datas); Usado = $usado; Total = $total }
        }
        $volumes = New-Object System.Collections.ArrayList
        foreach ($letra in @($pastas | Where-Object { $_ -match '^[A-Za-z]:' } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() } | Select-Object -Unique)) {
            $volume = Get-Volume -DriveLetter $letra -ErrorAction SilentlyContinue
            if ($null -eq $volume) { continue }
            [void]$volumes.Add(@{ no = $no; nome = "${letra}:"; tipo = [string]$volume.FileSystem
                                  usado = [double]$volume.Size - [double]$volume.SizeRemaining; total = [double]$volume.Size
                                  saude = [int]([string]$volume.HealthStatus -eq "Healthy") })
        }
        $Fonte.Detalhes = @{ Vms = $detalhes; Volumes = $volumes }
        $Fonte.UltimoDetalhe = Get-Agora
    }
    foreach ($volume in @($Fonte.Detalhes.Volumes)) { if ($volume) { [void]$inv.Armazenamentos.Add($volume) } }

    foreach ($vm in $vms) {
        $estadoTexto = [string]$vm.State
        $estado = if (@("Running", "Starting") -contains $estadoTexto) { 1 } elseif (@("Paused", "Saved", "Pausing", "Saving") -contains $estadoTexto) { 2 } else { 0 }
        $ligada = $estado -eq 1
        $detalhe = $Fonte.Detalhes.Vms[[string]$vm.Id]
        $memoriaTotal = if ($vm.DynamicMemoryEnabled) { [double]$vm.MemoryMaximum } else { [double]$vm.MemoryStartup }
        $replicacao = switch ([string]$vm.ReplicationHealth) { "Normal" { 1 } "Warning" { 2 } "Critical" { 0 } default { $null } }
        [void]$inv.Vms.Add(@{
            no = $no; vm = [string]$vm.Name; id = [string]$vm.Id; tipo = "VM"; so = ""; estado = $estado
            cpus = [int]$vm.ProcessorCount; cpu_percentual = $(if ($ligada) { [double]$vm.CPUUsage } else { $null })
            memoria_usada = $(if ($ligada) { [double]$vm.MemoryAssigned } else { $null }); memoria_total = $memoriaTotal
            disco_usado = $(if ($detalhe -and $detalhe.Usado) { $detalhe.Usado } else { $null })
            disco_total = $(if ($detalhe -and $detalhe.Total) { $detalhe.Total } else { $null })
            ligado_segundos = $(if ($ligada) { [math]::Round($vm.Uptime.TotalSeconds) } else { $null })
            snapshots = $(if ($detalhe) { $detalhe.Snapshots[0] } else { $null })
            snapshot_mais_antigo = $(if ($detalhe) { $detalhe.Snapshots[1] } else { $null })
            replicacao = $replicacao })
    }
    return $inv
}

function Get-ProxmoxInventario {
    param($Fonte)
    $endereco = if ($Fonte.Endereco -match ':\d+$') { $Fonte.Endereco } else { "$($Fonte.Endereco):8006" }
    $obter = {
        param([string]$Caminho)
        $r = Invoke-NextecHttp -Url ("https://{0}/api2/json{1}" -f $endereco, $Caminho) -Verificar $Fonte.Verificar `
            -Cabecalhos @{ Authorization = ("PVEAPIToken={0}={1}" -f $Fonte.Usuario, $Fonte.Segredo) }
        if ($r.Status -ne 200) { throw ("Proxmox {0}: HTTP {1}" -f $Caminho, $r.Status) }
        return (Get-Campo ($r.Corpo | ConvertFrom-Json) "data")
    }
    $inv = New-InventarioVirt
    $versao = [string](Get-Campo (& $obter "/version") "version")
    $status = @(& $obter "/cluster/status")
    $cluster = @($status | Where-Object { (Get-Campo $_ "type") -eq "cluster" }) | Select-Object -First 1
    $nomeCluster = if ($cluster) { [string](Get-Campo $cluster "name") } else { "" }
    if ($cluster) {
        $nos = @($status | Where-Object { (Get-Campo $_ "type") -eq "node" })
        [void]$inv.Clusters.Add(@{ cluster = $nomeCluster; quorum = [int][bool](Get-Campo $cluster "quorate")
                                   nos_online = @($nos | Where-Object { Get-Campo $_ "online" }).Count; nos = $nos.Count })
    }
    foreach ($r in @(& $obter "/cluster/resources")) {
        $tipo = [string](Get-Campo $r "type")
        if ($tipo -eq "node") {
            $online = (Get-Campo $r "status") -eq "online"
            [void]$inv.Hosts.Add(@{ no = [string](Get-Campo $r "node"); versao = $versao; cluster = $nomeCluster; up = [int]$online
                cpu_percentual = $(if ($online) { [math]::Round([double](Get-Campo $r "cpu") * 100, 2) } else { $null })
                cpus = Get-Campo $r "maxcpu"; memoria_usada = Get-Campo $r "mem"; memoria_total = Get-Campo $r "maxmem"
                ligado_segundos = $(if ($online) { Get-Campo $r "uptime" } else { $null }) })
        }
        elseif ($tipo -eq "storage") {
            [void]$inv.Armazenamentos.Add(@{ no = [string](Get-Campo $r "node"); nome = [string](Get-Campo $r "storage")
                tipo = [string](Get-Campo $r "plugintype"); usado = Get-Campo $r "disk"; total = Get-Campo $r "maxdisk"
                saude = [int]((Get-Campo $r "status") -eq "available") })
        }
        elseif (@("qemu", "lxc") -contains $tipo -and -not (Get-Campo $r "template")) {
            $ligada = (Get-Campo $r "status") -eq "running"
            [void]$inv.Vms.Add(@{ no = [string](Get-Campo $r "node"); vm = [string](Get-Campo $r "name"); id = [string](Get-Campo $r "vmid")
                tipo = $(if ($tipo -eq "qemu") { "VM" } else { "Contêiner" }); so = ""; estado = [int]$ligada; cpus = Get-Campo $r "maxcpu"
                cpu_percentual = $(if ($ligada) { [math]::Round([double](Get-Campo $r "cpu") * 100, 2) } else { $null })
                memoria_usada = $(if ($ligada) { Get-Campo $r "mem" } else { $null }); memoria_total = Get-Campo $r "maxmem"
                disco_usado = $(if (Get-Campo $r "disk") { Get-Campo $r "disk" } else { $null }); disco_total = Get-Campo $r "maxdisk"
                ligado_segundos = $(if ($ligada) { Get-Campo $r "uptime" } else { $null }); _tipo = $tipo })
        }
    }
    if (((Get-Agora) - $Fonte.UltimoDetalhe) -ge $script:IntervaloDetalhesVirt) {
        $detalhes = @{ zfs = New-Object System.Collections.ArrayList }
        $online = @($inv.Hosts | Where-Object { $_.up } | ForEach-Object { $_.no })
        foreach ($vm in $inv.Vms) {
            if ($online -notcontains $vm.no) { continue }
            try {
                $datas = @(& $obter ("/nodes/{0}/{1}/{2}/snapshot" -f $vm.no, $vm._tipo, $vm.id) |
                    Where-Object { (Get-Campo $_ "name") -ne "current" } | ForEach-Object { Get-Campo $_ "snaptime" })
                $detalhes["vm:" + $vm.id] = Get-ResumoSnapshots $datas
            }
            catch { Write-Log "aviso" ("snapshots não lidos de {0}: {1}" -f $vm.vm, $_.Exception.Message) }
        }
        foreach ($h in @($inv.Hosts | Where-Object { $_.up })) {
            try {
                foreach ($pool in @(& $obter ("/nodes/{0}/disks/zfs" -f $h.no))) {
                    [void]$detalhes.zfs.Add(@{ no = $h.no; nome = "zfs:" + (Get-Campo $pool "name"); tipo = "zfs"
                        usado = Get-Campo $pool "alloc"; total = Get-Campo $pool "size"; saude = [int]((Get-Campo $pool "health") -eq "ONLINE") })
                }
            }
            catch { }
        }
        $Fonte.Detalhes = $detalhes
        $Fonte.UltimoDetalhe = Get-Agora
    }
    foreach ($vm in $inv.Vms) {
        $resumo = $Fonte.Detalhes["vm:" + $vm.id]
        if ($resumo) { $vm.snapshots = $resumo[0]; $vm.snapshot_mais_antigo = $resumo[1] }
    }
    foreach ($z in @($Fonte.Detalhes.zfs)) { if ($z) { [void]$inv.Armazenamentos.Add($z) } }
    return $inv
}

function Invoke-VMwareSoap {
    param($Fonte, [string]$Corpo)
    $envelope = '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:urn="urn:vim25"><soapenv:Body>' + $Corpo + '</soapenv:Body></soapenv:Envelope>'
    $cabecalhos = @{ SOAPAction = $(if ($Fonte.VersaoApi) { "urn:vim25/" + $Fonte.VersaoApi } else { "urn:vim25" }) }
    if ($Fonte.Cookie) { $cabecalhos["Cookie"] = $Fonte.Cookie }
    $r = Invoke-NextecHttp -Url ("https://{0}/sdk" -f $Fonte.Endereco) -Metodo POST -Corpo $envelope -Cabecalhos $cabecalhos `
        -Verificar $Fonte.Verificar -TipoConteudo "text/xml; charset=utf-8"
    if ($r.Cookie) { $Fonte.Cookie = ($r.Cookie -split ";")[0] }
    $xml = [xml]$r.Corpo
    if ($r.Status -ne 200) {
        $falha = $xml.SelectSingleNode("//*[local-name()='faultstring']")
        throw ("VMware: {0}" -f $(if ($falha) { $falha.InnerText.Trim() } else { "HTTP $($r.Status)" }))
    }
    return $xml
}

function Get-VMwareInventario {
    param($Fonte)
    $Fonte.Cookie = $null; $Fonte.VersaoApi = ""
    $nos = { param($x, [string]$nome) @($x.SelectNodes(".//*[local-name()='$nome']")) }
    $texto = { param($x, [string]$nome) $n = $x.SelectSingleNode(".//*[local-name()='$nome']"); if ($n) { $n.InnerText.Trim() } else { "" } }
    $conteudo = (Invoke-VMwareSoap $Fonte '<urn:RetrieveServiceContent><urn:_this type="ServiceInstance">ServiceInstance</urn:_this></urn:RetrieveServiceContent>').SelectSingleNode("//*[local-name()='returnval']")
    $Fonte.VersaoApi = & $texto $conteudo "apiVersion"
    $produto = & $texto $conteudo "fullName"
    $sessao = & $texto $conteudo "sessionManager"
    $esc = { param([string]$t) [Security.SecurityElement]::Escape($t) }
    [void](Invoke-VMwareSoap $Fonte ('<urn:Login><urn:_this type="SessionManager">{0}</urn:_this><urn:userName>{1}</urn:userName><urn:password>{2}</urn:password></urn:Login>' -f $sessao, (& $esc $Fonte.Usuario), (& $esc $Fonte.Segredo)))
    try {
        $tipos = [ordered]@{
            HostSystem = @("name", "runtime.connectionState", "summary.quickStats.overallCpuUsage", "summary.quickStats.overallMemoryUsage",
                           "summary.quickStats.uptime", "summary.hardware.cpuMhz", "summary.hardware.numCpuCores", "summary.hardware.numCpuThreads",
                           "summary.hardware.memorySize", "summary.config.product.fullName", "parent")
            VirtualMachine = @("name", "config.template", "runtime.powerState", "runtime.host", "summary.config.numCpu", "summary.config.memorySizeMB",
                               "summary.config.guestFullName", "summary.quickStats.overallCpuUsage", "summary.runtime.maxCpuUsage",
                               "summary.quickStats.guestMemoryUsage", "summary.quickStats.uptimeSeconds", "summary.storage.committed",
                               "summary.storage.uncommitted", "snapshot")
            Datastore = @("summary.name", "summary.type", "summary.capacity", "summary.freeSpace", "summary.accessible")
            ClusterComputeResource = @("name")
        }
        $vista = & $texto (Invoke-VMwareSoap $Fonte ('<urn:CreateContainerView><urn:_this type="ViewManager">{0}</urn:_this><urn:container type="Folder">{1}</urn:container>{2}<urn:recursive>true</urn:recursive></urn:CreateContainerView>' -f (& $texto $conteudo "viewManager"), (& $texto $conteudo "rootFolder"), (($tipos.Keys | ForEach-Object { "<urn:type>$_</urn:type>" }) -join ""))) "returnval"
        $conjuntos = ($tipos.Keys | ForEach-Object { "<urn:propSet><urn:type>$_</urn:type>" + (($tipos[$_] | ForEach-Object { "<urn:pathSet>$_</urn:pathSet>" }) -join "") + "</urn:propSet>" }) -join ""
        $coletor = & $texto $conteudo "propertyCollector"
        $corpo = ('<urn:RetrievePropertiesEx><urn:_this type="PropertyCollector">{0}</urn:_this><urn:specSet>{1}<urn:objectSet><urn:obj type="ContainerView">{2}</urn:obj>' +
                  '<urn:skip>true</urn:skip><urn:selectSet xsi:type="urn:TraversalSpec"><urn:name>vista</urn:name><urn:type>ContainerView</urn:type><urn:path>view</urn:path>' +
                  '<urn:skip>false</urn:skip></urn:selectSet></urn:objectSet></urn:specSet><urn:options><urn:maxObjects>500</urn:maxObjects></urn:options></urn:RetrievePropertiesEx>') -f $coletor, $conjuntos, $vista
        $objetos = New-Object System.Collections.ArrayList
        $resposta = Invoke-VMwareSoap $Fonte $corpo
        while ($true) {
            $retorno = $resposta.SelectSingleNode("//*[local-name()='returnval']")
            if ($null -eq $retorno) { break }
            foreach ($o in @($retorno.SelectNodes("./*[local-name()='objects']"))) {
                $ref = $o.SelectSingleNode("./*[local-name()='obj']")
                $item = @{ _tipo = $ref.GetAttribute("type"); _id = $ref.InnerText.Trim() }
                foreach ($p in @($o.SelectNodes("./*[local-name()='propSet']"))) {
                    $item[$p.SelectSingleNode("./*[local-name()='name']").InnerText] = $p.SelectSingleNode("./*[local-name()='val']")
                }
                [void]$objetos.Add($item)
            }
            $ficha = $retorno.SelectSingleNode("./*[local-name()='token']")
            if ($null -eq $ficha) { break }
            $resposta = Invoke-VMwareSoap $Fonte ('<urn:ContinueRetrievePropertiesEx><urn:_this type="PropertyCollector">{0}</urn:_this><urn:token>{1}</urn:token></urn:ContinueRetrievePropertiesEx>' -f $coletor, $ficha.InnerText)
        }
    }
    finally {
        try { [void](Invoke-VMwareSoap $Fonte ('<urn:Logout><urn:_this type="SessionManager">{0}</urn:_this></urn:Logout>' -f $sessao)) } catch { }
    }

    $v = { param($item, [string]$chave) $n = $item[$chave]; if ($null -eq $n) { $null } else { $n.InnerText.Trim() } }
    $num = { param($item, [string]$chave) $t = & $v $item $chave; if ($t -match '^-?\d+(\.\d+)?$') { [double]$t } else { $null } }
    $inv = New-InventarioVirt
    $hosts = @($objetos | Where-Object { $_._tipo -eq "HostSystem" })
    $clusters = @{}; foreach ($c in @($objetos | Where-Object { $_._tipo -eq "ClusterComputeResource" })) { $clusters[$c._id] = & $v $c "name" }
    $nomes = @{}; foreach ($h in $hosts) { $nomes[$h._id] = $(if (& $v $h "name") { & $v $h "name" } else { $h._id }) }
    foreach ($h in $hosts) {
        $conectado = (& $v $h "runtime.connectionState") -eq "connected"
        $mhz = & $num $h "summary.hardware.cpuMhz"; $nucleos = & $num $h "summary.hardware.numCpuCores"; $uso = & $num $h "summary.quickStats.overallCpuUsage"
        $memoria = & $num $h "summary.quickStats.overallMemoryUsage"
        $pai = & $v $h "parent"
        [void]$inv.Hosts.Add(@{ no = $nomes[$h._id]; versao = $(if (& $v $h "summary.config.product.fullName") { & $v $h "summary.config.product.fullName" } else { $produto })
            cluster = $(if ($pai -and $clusters.ContainsKey($pai)) { $clusters[$pai] } else { "" }); up = [int]$conectado
            cpu_percentual = $(if ($conectado -and $null -ne $uso -and $mhz -and $nucleos) { [math]::Round(100 * $uso / ($mhz * $nucleos), 2) } else { $null })
            cpus = & $num $h "summary.hardware.numCpuThreads"
            memoria_usada = $(if ($conectado -and $null -ne $memoria) { $memoria * 1MB } else { $null }); memoria_total = & $num $h "summary.hardware.memorySize"
            ligado_segundos = $(if ($conectado) { & $num $h "summary.quickStats.uptime" } else { $null }) })
    }
    $unico = if ($nomes.Count -eq 1) { @($nomes.Values)[0] } else { "" }
    foreach ($o in $objetos) {
        if ($o._tipo -eq "Datastore") {
            $total = & $num $o "summary.capacity"; $livre = & $num $o "summary.freeSpace"
            [void]$inv.Armazenamentos.Add(@{ no = $unico; nome = $(if (& $v $o "summary.name") { & $v $o "summary.name" } else { $o._id }); tipo = [string](& $v $o "summary.type")
                usado = $(if ($null -ne $total -and $null -ne $livre) { $total - $livre } else { $null }); total = $total
                saude = [int]((& $v $o "summary.accessible") -eq "true") })
        }
        elseif ($o._tipo -eq "VirtualMachine" -and (& $v $o "config.template") -ne "true") {
            $estado = switch (& $v $o "runtime.powerState") { "poweredOn" { 1 } "suspended" { 2 } default { 0 } }
            $ligada = $estado -eq 1
            $uso = & $num $o "summary.quickStats.overallCpuUsage"; $maximo = & $num $o "summary.runtime.maxCpuUsage"
            $memoria = & $num $o "summary.config.memorySizeMB"; $convidado = & $num $o "summary.quickStats.guestMemoryUsage"
            $usado = & $num $o "summary.storage.committed"; $livre = & $num $o "summary.storage.uncommitted"
            $datas = @()
            if ($o["snapshot"]) { $datas = @(& $nos $o["snapshot"] "createTime" | ForEach-Object { ConvertTo-Epoch $_.InnerText.Trim() }) }
            $resumo = Get-ResumoSnapshots $datas
            $hostVm = & $v $o "runtime.host"
            [void]$inv.Vms.Add(@{ no = $(if ($hostVm -and $nomes.ContainsKey($hostVm)) { $nomes[$hostVm] } else { "" }); vm = [string](& $v $o "name"); id = $o._id
                tipo = "VM"; so = [string](& $v $o "summary.config.guestFullName"); estado = $estado; cpus = & $num $o "summary.config.numCpu"
                cpu_percentual = $(if ($ligada -and $null -ne $uso -and $maximo) { [math]::Round(100 * $uso / $maximo, 2) } else { $null })
                memoria_usada = $(if ($ligada -and $null -ne $convidado) { $convidado * 1MB } else { $null })
                memoria_total = $(if ($null -ne $memoria) { $memoria * 1MB } else { $null })
                disco_usado = $usado; disco_total = $(if ($null -ne $usado -or $null -ne $livre) { [double]$usado + [double]$livre } else { $null })
                ligado_segundos = $(if ($ligada) { & $num $o "summary.quickStats.uptimeSeconds" } else { $null })
                snapshots = $resumo[0]; snapshot_mais_antigo = $resumo[1] })
        }
    }
    return $inv
}

function ConvertFrom-XmlRpcValor {
    param([System.Xml.XmlNode]$No)
    $filho = @($No.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }) | Select-Object -First 1
    if ($null -eq $filho) { return $No.InnerText }
    switch ($filho.LocalName) {
        "struct" {
            $tabela = @{}
            foreach ($membro in @($filho.SelectNodes("./member"))) {
                $tabela[$membro.SelectSingleNode("./name").InnerText] = ConvertFrom-XmlRpcValor $membro.SelectSingleNode("./value")
            }
            return $tabela
        }
        "array" { return , @($filho.SelectNodes("./data/value") | ForEach-Object { ConvertFrom-XmlRpcValor $_ }) }
        "boolean" { return $filho.InnerText -eq "1" }
        { @("int", "i4", "i8") -contains $_ } { return [int64]$filho.InnerText }
        "double" { return [double]::Parse($filho.InnerText, $script:Cultura) }
        default { return $filho.InnerText }
    }
}

function Invoke-XmlRpc {
    param($Fonte, [string]$Metodo, [string[]]$Parametros)
    $params = ($Parametros | ForEach-Object { "<param><value><string>{0}</string></value></param>" -f [Security.SecurityElement]::Escape($_) }) -join ""
    $corpo = "<?xml version=`"1.0`"?><methodCall><methodName>$Metodo</methodName><params>$params</params></methodCall>"
    $r = Invoke-NextecHttp -Url ("https://{0}/" -f $Fonte.Endereco) -Metodo POST -Corpo $corpo -Verificar $Fonte.Verificar -TipoConteudo "text/xml"
    if ($r.Status -ne 200) { throw ("XAPI {0}: HTTP {1}" -f $Metodo, $r.Status) }
    $resposta = ConvertFrom-XmlRpcValor ([xml]$r.Corpo).SelectSingleNode("//params/param/value")
    if ($resposta["Status"] -ne "Success") { throw ("XAPI {0}: {1}" -f $Metodo, (@($resposta["ErrorDescription"]) -join " ")) }
    return $resposta["Value"]
}

function Get-XcpInventario {
    param($Fonte)
    $sessao = Invoke-XmlRpc $Fonte "session.login_with_password" @($Fonte.Usuario, $Fonte.Segredo, "1.0", "nextec-coleta")
    try {
        $todos = @{}
        foreach ($classe in @("pool", "host", "host_metrics", "host_cpu", "VM", "VM_metrics", "VM_guest_metrics", "VBD", "VDI", "SR")) {
            $todos[$classe] = Invoke-XmlRpc $Fonte "$classe.get_all_records" @($sessao)
        }
    }
    finally { try { [void](Invoke-XmlRpc $Fonte "session.logout" @($sessao)) } catch { } }
    $inv = New-InventarioVirt
    $nomePool = ""; foreach ($p in $todos.pool.Values) { $nomePool = [string]$p["name_label"]; break }
    $nomes = @{}; foreach ($ref in $todos.host.Keys) { $nomes[$ref] = [string]$todos.host[$ref]["name_label"] }
    foreach ($ref in $todos.host.Keys) {
        $h = $todos.host[$ref]; $m = $todos.host_metrics[[string]$h["metrics"]]
        $vivo = if ($m -and $m.ContainsKey("live")) { [bool]$m["live"] } else { $true }
        $uso = @($todos.host_cpu.Values | Where-Object { $_["host"] -eq $ref } | ForEach-Object { [double]$_["utilisation"] })
        $total = if ($m) { [double]$m["memory_total"] } else { 0 }
        $versaoXcp = if ($h["software_version"]) { [string]$h["software_version"]["product_version"] } else { "" }
        [void]$inv.Hosts.Add(@{ no = $nomes[$ref]; versao = "XCP-ng $versaoXcp"; cluster = $nomePool; up = [int]$vivo
            cpu_percentual = $(if ($uso.Count -and $vivo) { [math]::Round(100 * ($uso | Measure-Object -Sum).Sum / $uso.Count, 2) } else { $null })
            cpus = $(if ($uso.Count) { $uso.Count } else { $null }); memoria_usada = $(if ($total) { $total - [double]$m["memory_free"] } else { $null })
            memoria_total = $(if ($total) { $total } else { $null }); ligado_segundos = $null })
    }
    $snapshots = @{}
    foreach ($vm in $todos.VM.Values) {
        if ($vm["is_a_snapshot"]) {
            $origem = [string]$vm["snapshot_of"]
            if (-not $snapshots.ContainsKey($origem)) { $snapshots[$origem] = New-Object System.Collections.ArrayList }
            [void]$snapshots[$origem].Add((ConvertTo-Epoch $vm["snapshot_time"]))
        }
    }
    foreach ($ref in $todos.VM.Keys) {
        $vm = $todos.VM[$ref]
        if ($vm["is_a_template"] -or $vm["is_control_domain"] -or $vm["is_a_snapshot"]) { continue }
        $estado = switch ([string]$vm["power_state"]) { "Running" { 1 } "Paused" { 2 } "Suspended" { 2 } default { 0 } }
        $ligada = $estado -eq 1
        $m = $todos.VM_metrics[[string]$vm["metrics"]]
        $g = $todos.VM_guest_metrics[[string]$vm["guest_metrics"]]
        $discos = @(@($vm["VBDs"]) | Where-Object { $_ -and $todos.VBD.ContainsKey($_) -and $todos.VBD[$_]["type"] -eq "Disk" } |
                    ForEach-Object { $todos.VDI[[string]$todos.VBD[$_]["VDI"]] } | Where-Object { $_ })
        $inicio = if ($ligada -and $m) { ConvertTo-Epoch $m["start_time"] } else { $null }
        $resumo = Get-ResumoSnapshots $(if ($snapshots.ContainsKey($ref)) { $snapshots[$ref] } else { @() })
        $usado = ($discos | ForEach-Object { [double]$_["physical_utilisation"] } | Measure-Object -Sum).Sum
        $total = ($discos | ForEach-Object { [double]$_["virtual_size"] } | Measure-Object -Sum).Sum
        [void]$inv.Vms.Add(@{ no = $(if ($ligada -and $nomes.ContainsKey([string]$vm["resident_on"])) { $nomes[[string]$vm["resident_on"]] } else { "" })
            vm = [string]$vm["name_label"]; id = [string]$vm["uuid"]; tipo = "VM"
            so = $(if ($g -and $g["os_version"]) { ([string]$g["os_version"]["name"] -split '\|')[0] } else { "" })
            estado = $estado; cpus = $(if ($vm["VCPUs_at_startup"]) { [double]$vm["VCPUs_at_startup"] } else { $null }); cpu_percentual = $null
            memoria_usada = $(if ($ligada -and $m -and $m["memory_actual"]) { [double]$m["memory_actual"] } else { $null })
            memoria_total = $(if ($vm["memory_static_max"]) { [double]$vm["memory_static_max"] } else { $null })
            disco_usado = $(if ($usado) { $usado } else { $null }); disco_total = $(if ($total) { $total } else { $null })
            ligado_segundos = $(if ($inicio -and $inicio -gt 0) { [math]::Round((Get-Agora) - $inicio) } else { $null })
            snapshots = $resumo[0]; snapshot_mais_antigo = $resumo[1] })
    }
    foreach ($sr in $todos.SR.Values) {
        if (@("iso", "udev") -contains [string]$sr["type"] -or -not [double]$sr["physical_size"]) { continue }
        [void]$inv.Armazenamentos.Add(@{ no = ""; nome = [string]$sr["name_label"]; tipo = [string]$sr["type"]
            usado = [double]$sr["physical_utilisation"]; total = [double]$sr["physical_size"]; saude = $null })
    }
    return $inv
}

function Add-InventarioVirt {
    param($Metricas, $Fonte, $Inv)
    $base = [ordered]@{ plataforma = $script:PlataformasVirt[$Fonte.Plataforma]; hipervisor = $Fonte.Nome }
    $com = { param([System.Collections.IDictionary]$extra) $r = [ordered]@{}; foreach ($k in $base.Keys) { $r[$k] = $base[$k] }; foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] }; $r }
    foreach ($c in $Inv.Clusters) {
        $r = & $com ([ordered]@{ cluster = $c.cluster })
        Add-Metrica $Metricas "nextec_hipervisor_cluster_quorum" $c.quorum $r
        Add-Metrica $Metricas "nextec_hipervisor_cluster_nos_online" $c.nos_online $r
        Add-Metrica $Metricas "nextec_hipervisor_cluster_nos" $c.nos $r
    }
    foreach ($h in $Inv.Hosts) {
        $r = & $com ([ordered]@{ no = $h.no })
        Add-Metrica $Metricas "nextec_hipervisor_info" 1 (& $com ([ordered]@{ no = $h.no; versao = $h.versao; cluster = $h.cluster }))
        Add-Metrica $Metricas "nextec_hipervisor_host_up" $h.up $r
        foreach ($par in @(@("cpu_percentual", "nextec_hipervisor_cpu_percentual"), @("cpus", "nextec_hipervisor_cpus"),
                           @("memoria_usada", "nextec_hipervisor_memoria_usada_bytes"), @("memoria_total", "nextec_hipervisor_memoria_total_bytes"),
                           @("ligado_segundos", "nextec_hipervisor_ligado_segundos"))) {
            Add-Metrica $Metricas $par[1] $h[$par[0]] $r
        }
    }
    foreach ($a in $Inv.Armazenamentos) {
        $r = & $com ([ordered]@{ no = $a.no; armazenamento = $a.nome; tipo = $a.tipo })
        Add-Metrica $Metricas "nextec_hipervisor_armazenamento_usado_bytes" $a.usado $r
        Add-Metrica $Metricas "nextec_hipervisor_armazenamento_total_bytes" $a.total $r
        Add-Metrica $Metricas "nextec_hipervisor_armazenamento_saude" $a.saude $r
    }
    foreach ($vm in $Inv.Vms) {
        $r = & $com ([ordered]@{ no = $vm.no; vm = $vm.vm; vmid = $vm.id })
        Add-Metrica $Metricas "nextec_vm_info" 1 (& $com ([ordered]@{ no = $vm.no; vm = $vm.vm; vmid = $vm.id; tipo = $vm.tipo; so = $vm.so }))
        Add-Metrica $Metricas "nextec_vm_estado" $vm.estado $r
        foreach ($par in @(@("cpus", "nextec_vm_cpus"), @("cpu_percentual", "nextec_vm_cpu_percentual"), @("memoria_usada", "nextec_vm_memoria_usada_bytes"),
                           @("memoria_total", "nextec_vm_memoria_total_bytes"), @("disco_usado", "nextec_vm_disco_usado_bytes"),
                           @("disco_total", "nextec_vm_disco_total_bytes"), @("ligado_segundos", "nextec_vm_ligado_segundos"),
                           @("snapshots", "nextec_vm_snapshots"), @("replicacao", "nextec_vm_replicacao_saude"))) {
            Add-Metrica $Metricas $par[1] $vm[$par[0]] $r
        }
        if ($vm["snapshot_mais_antigo"]) { Add-Metrica $Metricas "nextec_vm_snapshot_mais_antigo_segundos" ([math]::Round($vm["snapshot_mais_antigo"])) $r }
    }
}

function Get-FontesVirtualizacao {
    param($Ini)
    $secao = if ($Ini.Contains("virtualizacao")) { $Ini["virtualizacao"] } else { @{} }
    $fontes = New-Object System.Collections.ArrayList
    $local = (Get-Valor $secao "local" "auto").ToLowerInvariant()
    if ($local -eq "auto") { $local = $(if (Get-Command Get-VM -ErrorAction SilentlyContinue) { "hyperv" } else { "" }) }
    if ($local -eq "hyperv") {
        [void]$fontes.Add([pscustomobject]@{ Nome = $env:COMPUTERNAME.ToLowerInvariant(); Plataforma = "hyperv"; Detalhes = @{ Vms = @{}; Volumes = @() }; UltimoDetalhe = 0.0 })
    }
    $segredos = @{}
    if (Test-Path -LiteralPath $script:ArquivoSegredos) { $segredos = Read-Ini $script:ArquivoSegredos -Bruto }
    foreach ($nomeSecao in $Ini.Keys) {
        if ($nomeSecao -notmatch '^hipervisor:(.+)$') { continue }
        $nome = $Matches[1].Trim()
        $dados = $Ini[$nomeSecao]
        $segredo = if ($segredos.Contains($nomeSecao)) { $segredos[$nomeSecao] } else { @{} }
        $tipo = (Get-Valor $dados "tipo").ToLowerInvariant() -replace '^(xcp-ng|xenserver)$', 'xcpng'
        if (-not $script:PlataformasVirt.Contains($tipo) -or $tipo -eq "hyperv") {
            Write-Log "aviso" "hipervisor [$nomeSecao] com tipo desconhecido: $tipo"
            continue
        }
        [void]$fontes.Add([pscustomobject]@{
            Nome = $nome; Plataforma = $tipo; Endereco = Get-Valor $dados "endereco"; Usuario = Get-Valor $dados "usuario"
            Segredo = $(if ($tipo -eq "proxmox") { Get-Valor $segredo "token" } else { Get-Valor $segredo "senha" })
            Verificar = @("sim", "s", "1", "true") -contains (Get-Valor $dados "verificar_certificado" "nao").ToLowerInvariant()
            Detalhes = @{}; UltimoDetalhe = 0.0; Cookie = $null; VersaoApi = "" })
    }
    return $fontes
}

function Get-InventarioFonte {
    param($Fonte)
    switch ($Fonte.Plataforma) {
        "hyperv" { return Get-HyperVInventario $Fonte }
        "proxmox" { return Get-ProxmoxInventario $Fonte }
        "vmware" { return Get-VMwareInventario $Fonte }
        "xcpng" { return Get-XcpInventario $Fonte }
    }
}

function Invoke-RodadaVirtualizacao {
    $metricas = New-Metricas
    $falhas = 0
    foreach ($fonte in $script:FontesVirt) {
        $rotulos = [ordered]@{ plataforma = $script:PlataformasVirt[$fonte.Plataforma]; hipervisor = $fonte.Nome }
        $inicio = Get-Agora
        try {
            $inv = Get-InventarioFonte $fonte
            Add-InventarioVirt $metricas $fonte $inv
            Add-Metrica $metricas "nextec_hipervisor_up" 1 $rotulos
        }
        catch {
            $falhas++
            Add-Metrica $metricas "nextec_hipervisor_up" 0 $rotulos
            Write-Log "erro" ("consulta ao hipervisor {0} falhou: {1}" -f $fonte.Nome, $_.Exception.Message)
        }
        Add-Metrica $metricas "nextec_hipervisor_coleta_duracao_segundos" ([math]::Round((Get-Agora) - $inicio, 2)) $rotulos
    }
    Add-Metrica $metricas "nextec_hipervisor_coletor_ultima_execucao_segundos" ([math]::Floor((Get-Agora)))
    Save-Metricas $metricas (Join-Path $script:PastaTextfile "coleta_complementar_virtualizacao.prom")
    if ($script:FontesVirt.Count -gt 0 -and $falhas -eq $script:FontesVirt.Count) { throw "nenhum hipervisor respondeu" }
}

function Save-Saude {
    param([bool]$Ok, [bool]$AcessosOk = $true, [bool]$BancosOk = $true, [bool]$VelocidadeOk = $true, [bool]$VirtOk = $true)
    $metricas = New-Metricas
    $lista = @()
    if ($script:InternetAtivo) { $lista += "internet" }
    if ($script:AcessosAtivo) { $lista += "acessos" }
    if ($script:BancosAtivo) { $lista += "bancos" }
    if ($script:VelocidadeAtivo) { $lista += "velocidade" }
    if ($script:VirtAtivo) { $lista += "virtualizacao" }
    Add-Metrica $metricas "nextec_coleta_complementar_info" 1 ([ordered]@{ versao = $script:Versao; modulos = ($lista -join ",") })
    if ($script:InternetAtivo) {
        Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$Ok) @{ modulo = "internet" }
    }
    if ($script:AcessosAtivo) {
        Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$AcessosOk) @{ modulo = "acessos" }
    }
    if ($script:BancosAtivo) {
        Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$BancosOk) @{ modulo = "bancos" }
    }
    if ($script:VelocidadeAtivo) {
        Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$VelocidadeOk) @{ modulo = "velocidade" }
    }
    if ($script:VirtAtivo) {
        Add-Metrica $metricas "nextec_coleta_complementar_modulo_ok" ([int]$VirtOk) @{ modulo = "virtualizacao" }
    }
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
    $script:ArquivoSegredos = Get-Valor $geral "arquivo_segredos" (Join-Path $script:PastaBase "segredos.ini")
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

    $acessos = if ($ini.Contains("acessos")) { $ini["acessos"] } else { @{} }
    $script:AcessosAtivo = @("sim", "s", "1", "true", "ligado") -contains (Get-Valor $acessos "ativo" "nao").ToLowerInvariant()
    $script:GradeHorario = Read-Horario (Get-Valor $acessos "horario" "seg-sex 07:00-19:00; sab 07:00-14:00")
    if ($script:GradeHorario.Count -eq 0) { $script:GradeHorario = Read-Horario "seg-sex 07:00-19:00; sab 07:00-14:00" }
    $script:OrigensConhecidas = @(Split-Lista (Get-Valor $acessos "origens_conhecidas" ""))
    $script:DiasOrigemConhecida = [math]::Max(1, [int](Get-Valor $acessos "dias_origem_conhecida" "30"))

    $bancos = if ($ini.Contains("bancos")) { $ini["bancos"] } else { @{} }
    $script:BancosAtivo = @("sim", "s", "1", "true", "ligado") -contains (Get-Valor $bancos "ativo" "nao").ToLowerInvariant()
    $script:IntervaloBancos = [math]::Max(30, [int](Get-Valor $bancos "intervalo_segundos" "60"))
    $script:UltimaRodadaBancos = 0.0
    $script:BancosEsperados = @(Split-Lista (Get-Valor $bancos "motores" "") | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $script:MotoresBanco.Contains($_) })
    $script:BancosArquivos = @()
    foreach ($item in @(Split-Lista (Get-Valor $bancos "arquivos" ""))) {
        $posicao = $item.IndexOf(":")
        if ($posicao -lt 1) { continue }
        $motor = $item.Substring(0, $posicao).Trim().ToLowerInvariant()
        $caminho = $item.Substring($posicao + 1).Trim()
        if ($script:MotoresBanco.Contains($motor) -and $caminho) { $script:BancosArquivos += [pscustomobject]@{ Motor = $motor; Caminho = $caminho } }
    }

    $velocidade = if ($ini.Contains("velocidade")) { $ini["velocidade"] } else { @{} }
    $script:VelocidadeAtivo = @("sim", "s", "1", "true", "ligado") -contains (Get-Valor $velocidade "ativo" "nao").ToLowerInvariant()
    # Mínimo de 5 minutos, o mesmo que o instalador aceita com confirmação.
    $script:IntervaloVelocidade = [math]::Max(5, [int](Get-Valor $velocidade "intervalo_minutos" "30")) * 60
    $script:SpeedtestExe = Get-Valor $velocidade "speedtest" (Join-Path $env:ProgramData "GrafanaLabs\Alloy\nextec-speedtest\speedtest.exe")
    $script:UltimoTesteVelocidade = 0.0
    $script:TesteVelocidade = $null

    $virt = if ($ini.Contains("virtualizacao")) { $ini["virtualizacao"] } else { @{} }
    $script:VirtAtivo = @("sim", "s", "1", "true", "ligado") -contains (Get-Valor $virt "ativo" "nao").ToLowerInvariant()
    $script:IntervaloVirt = [math]::Max(60, [int](Get-Valor $virt "intervalo_segundos" "120"))
    $script:UltimaRodadaVirt = 0.0
    $script:FontesVirt = @()
    if ($script:VirtAtivo) { $script:FontesVirt = @(Get-FontesVirtualizacao $ini) }

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
                # Velocidade contratada em Mbps, padronizada pelo instalador.
                velocidade_mbps        = ConvertTo-Mbps (Get-Valor $secao "velocidade_mbps")
                velocidade_upload_mbps = ConvertTo-Mbps (Get-Valor $secao "velocidade_upload_mbps")
            }
        }
    }
    # Mesma regra do Linux: "ativo = nao" em [internet] desliga o módulo,
    # a menos que haja links cadastrados.
    $script:InternetAtivo = (@("sim", "s", "1", "true", "ligado") -contains (Get-Valor $internet "ativo" "sim").ToLowerInvariant()) -or ($script:Links.Count -gt 0)
    $script:Estado = Read-Estado
}

function Invoke-Executar {
    Initialize-Configuracao
    $script:BancosOk = $true
    $script:VirtOk = $true
    Write-Log "info" "Coleta Complementar $script:Versao iniciada; links configurados: $($script:Links.Count)"
    $ligados = @(); if ($script:InternetAtivo) { $ligados += "internet" }; if ($script:AcessosAtivo) { $ligados += "acessos" }; if ($script:BancosAtivo) { $ligados += "bancos" }; if ($script:VelocidadeAtivo) { $ligados += "velocidade" }; if ($script:VirtAtivo) { $ligados += "virtualizacao" }
    Write-Evento "sistema" "coletor_iniciado" "info" @{ detalhe = "Coleta Complementar $script:Versao (Windows): $($ligados -join ', ')" }
    while ($true) {
        $inicio = Get-Agora
        # Um módulo com erro não derruba o outro.
        $acessosOk = $true
        if ($script:AcessosAtivo) {
            try { Invoke-RodadaAcessos }
            catch {
                $acessosOk = $false
                Write-Log "erro" ("rodada de acessos falhou: {0}" -f $_.Exception.Message)
            }
        }
        if ($script:BancosAtivo -and ($inicio - $script:UltimaRodadaBancos) -ge $script:IntervaloBancos) {
            $script:UltimaRodadaBancos = $inicio
            try { Invoke-RodadaBancos; $script:BancosOk = $true }
            catch {
                $script:BancosOk = $false
                Write-Log "erro" ("rodada de bancos falhou: {0}" -f $_.Exception.Message)
            }
        }
        if ($script:VirtAtivo -and ($inicio - $script:UltimaRodadaVirt) -ge $script:IntervaloVirt) {
            $script:UltimaRodadaVirt = $inicio
            try { Invoke-RodadaVirtualizacao; $script:VirtOk = $true }
            catch {
                $script:VirtOk = $false
                Write-Log "erro" ("rodada de virtualização falhou: {0}" -f $_.Exception.Message)
            }
        }
        $velocidadeOk = $true
        if ($script:VelocidadeAtivo) {
            try { Invoke-RodadaVelocidade }
            catch {
                $velocidadeOk = $false
                Write-Log "erro" ("rodada de velocidade falhou: {0}" -f $_.Exception.Message)
            }
        }
        try {
            if ($script:InternetAtivo) { Invoke-RodadaLinks }
            Save-Saude $true $acessosOk $script:BancosOk $velocidadeOk $script:VirtOk
        }
        catch {
            Write-Log "erro" ("rodada falhou: {0} | {1}" -f $_.Exception.Message, ($_.ScriptStackTrace -replace "`r?`n", " <- "))
            try { Save-Saude $false $acessosOk $script:BancosOk $velocidadeOk $script:VirtOk } catch { }
        }
        $espera = $script:Intervalo - ((Get-Agora) - $inicio)
        if ($espera -gt 0) { Start-Sleep -Milliseconds ([int]($espera * 1000)) }
    }
}

function Invoke-UmaVez {
    Initialize-Configuracao
    if ($script:InternetAtivo) { Invoke-RodadaLinks }
    if ($script:BancosAtivo) { Invoke-RodadaBancos }
    if ($script:VirtAtivo) { Invoke-RodadaVirtualizacao }
    if ($script:VelocidadeAtivo) {
        # Uma rodada mostra o teste completo: espera o resultado.
        Invoke-RodadaVelocidade
        if ($null -ne $script:TesteVelocidade) {
            [void]$script:TesteVelocidade.Processo.WaitForExit(185000)
            Invoke-RodadaVelocidade
        }
    }
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
    Write-Host ("Acessos (logins com origem): {0}" -f $(if ($script:AcessosAtivo) { "ligado" } else { "desligado" }))
    Write-Host ("Bancos: {0}" -f $(if ($script:BancosAtivo) { "ligado ({0})" -f (@($script:BancosEsperados) -join ", ") } else { "desligado" }))
    Write-Host ("Velocidade: {0}" -f $(if ($script:VelocidadeAtivo) { "ligado (a cada {0} min)" -f ($script:IntervaloVelocidade / 60) } else { "desligado" }))
    if ($script:VelocidadeAtivo -and -not (Test-Path -LiteralPath $script:SpeedtestExe)) {
        $problemas += "Speedtest CLI não encontrado em $($script:SpeedtestExe)"
    }
    foreach ($fonte in $script:FontesVirt) {
        try {
            $inv = Get-InventarioFonte $fonte
            Write-Host ("Hipervisor {0} ({1}): {2} host(s), {3} VM(s), {4} armazenamento(s)" -f $fonte.Nome, $script:PlataformasVirt[$fonte.Plataforma], $inv.Hosts.Count, $inv.Vms.Count, $inv.Armazenamentos.Count)
        }
        catch { $problemas += ("hipervisor {0} ({1}) sem resposta: {2}" -f $fonte.Nome, $script:PlataformasVirt[$fonte.Plataforma], $_.Exception.Message) }
    }
    if ($script:AcessosAtivo) {
        try { [void](Get-WinEvent -LogName Security -MaxEvents 1) }
        catch { $problemas += "log Security ilegível: o módulo acessos não registra logins ($($_.Exception.Message))" }
    }
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
