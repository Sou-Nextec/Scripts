<#
    Testes do instalador Windows: bloqueios de entrada do Firewall do Windows (2.30.0).

    Parte 1: opção desligada não gera o bloco; ligada gera o bloco com os rótulos padrão.
    Parte 2: filtros (ALLOW, SEND, loopback, broadcast, multicast, linhas sem data) aplicados às linhas
             do bloco gerado, na mesma ordem em que o Alloy os executa.
    Parte 3: a resposta sobrevive ao Reconfigurar, ao Ver e alterar e ao -Atualizar.
    Parte 4: regras de código (cabeçalho, condição do loki.write, leitura e importação).

    Uso: .\Alloy\testes\instalador-windows-firewall.testes.ps1      (código de saída 1 se algum teste falhar)
#>
$ErrorActionPreference = 'Stop'
$script:falhas = 0
$arquivo = (Resolve-Path (Join-Path $PSScriptRoot '..\install-nextec-monitoring-windows-v2.ps1')).Path

function Conferir([string]$nome, [bool]$passou, [string]$detalhe = '') {
    if ($passou) {
        Write-Host "  ok    $nome"
    } else {
        $script:falhas++
        Write-Host "::error file=Alloy/install-nextec-monitoring-windows-v2.ps1::$nome $detalhe"
        Write-Host "  FALHA $nome $detalhe"
    }
}

$tokens = $null
$errosSintaxe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$errosSintaxe)
if ($errosSintaxe) { throw "install-nextec-monitoring-windows-v2.ps1 tem erro de sintaxe: $($errosSintaxe[0].Message)" }

function Corpo-Funcao([string]$nome) {
    $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nome }, $true)
    if (-not $f) { throw "Função $nome não encontrada no instalador" }
    return $f.Extent.Text
}

. ([scriptblock]::Create((Corpo-Funcao 'ConvertTo-AlloyEscapedString')))
. ([scriptblock]::Create((Corpo-Funcao 'Get-FirewallWindowsAlloyLines')))
. ([scriptblock]::Create((Corpo-Funcao 'Get-FirewallLogsDoConfig')))
. ([scriptblock]::Create((Corpo-Funcao 'Get-NextecBroadcastIPv4')))
. ([scriptblock]::Create((Corpo-Funcao 'Get-NextecFirewallLogCaminho')))

$dados = @{
    Cliente = 'cartorio_adriana_celiac'; HostLabel = 'servidor_online'; Tipo = 'servidor'
    Ambiente = 'producao'; Criticidade = 'alto'; Local = 'matriz'
}

Write-Host 'Parte 1: bloco desligado e ligado'
$desligado = @(Get-FirewallWindowsAlloyLines -Ativo $false @dados)
Conferir 'desligada: nenhuma linha' ($desligado.Count -eq 0) "linhas: $($desligado.Count)"

$linhas = @(Get-FirewallWindowsAlloyLines -Ativo $true @dados -BroadcastsLocais @('10.0.1.255'))
$bloco = $linhas -join "`n"
Conferir 'ligada: gera local.file_match, loki.source.file e loki.process' (
    $bloco.Contains('local.file_match "firewall_windows"') -and
    $bloco.Contains('loki.source.file "firewall_windows"') -and
    $bloco.Contains('loki.process "firewall_windows"'))
Conferir 'ligada: envia para o loki.write do instalador' ($bloco.Contains('forward_to = [loki.write.nextec.receiver]'))
Conferir 'ligada: lê o pfirewall.log' ($bloco -match '"__path__" = "[^"]*/System32/LogFiles/Firewall/pfirewall\.log"')
Conferir 'ligada: lê só o que chega depois da instalação' ($bloco.Contains('tail_from_end = true'))
$rotulos = [ordered]@{
    cliente = 'cartorio_adriana_celiac'; host = 'servidor_online'; servico = 'firewall_windows'; tipo = 'servidor'
    ambiente = 'producao'; os = 'windows'; origem = 'alloy'; criticidade = 'alto'; local = 'matriz'; canal = 'firewall'
}
foreach ($chave in $rotulos.Keys) {
    $esperado = ('{0}\s*=\s*"{1}",' -f $chave, [regex]::Escape($rotulos[$chave]))
    Conferir "rótulo $chave" ($bloco -match "(?m)^\s*$esperado") "esperado $chave=$($rotulos[$chave])"
}
Conferir 'sem rótulo filename (vem do loki.source.file)' ($bloco.Contains('stage.label_drop') -and $bloco.Contains('"filename"'))
Conferir 'limite contra varredura de porta' ($bloco -match '(?s)stage\.limit \{\s*rate\s*=\s*20\s*burst\s*=\s*100\s*drop\s*=\s*true')
Conferir 'mensagem no formato ícone EQUIPAMENTO · o que aconteceu · detalhes' (
    $bloco.Contains('template = "🔐 SERVIDOR_ONLINE · Bloqueio no firewall do Windows · {{ .proto }} {{ .ip_origem }} → porta {{ .porta_destino }}"'))
Conferir 'valores com aspas e barras são escapados' (
    ((@(Get-FirewallWindowsAlloyLines -Ativo $true -Cliente 'a"b' -HostLabel 'h\1' -Tipo 'servidor' -Ambiente 'producao' -Criticidade 'alto' -Local 'matriz') -join "`n").Contains('cliente     = "a\"b"')))
Conferir 'caminho do log usa barras normais' ((Get-NextecFirewallLogCaminho) -notmatch '\\' -and (Get-NextecFirewallLogCaminho) -match 'System32/LogFiles/Firewall/pfirewall\.log$')

$semBroadcast = (@(Get-FirewallWindowsAlloyLines -Ativo $true @dados) -join "`n")
Conferir 'sem redes locais: filtro de destino não descarta .255' ($semBroadcast.Contains('expression = "^(22[4-9]\\.|23[0-9]\\.|255\\.|ff0)"') -and -not $semBroadcast.Contains('\\.255'))
Conferir 'broadcast local entra no filtro com os pontos escapados' ($bloco.Contains('expression = "^(22[4-9]\\.|23[0-9]\\.|255\\.|ff0)|^(10\\.0\\.1\\.255)$"'))
$doisBroadcasts = (@(Get-FirewallWindowsAlloyLines -Ativo $true @dados -BroadcastsLocais @('10.0.1.255', '192.168.1.255', '192.168.1.255', 'texto', '300.1')) -join "`n")
Conferir 'vários broadcasts: sem repetição e sem valor inválido' ($doisBroadcasts.Contains('|^(10\\.0\\.1\\.255|192\\.168\\.1\\.255)$"'))

Write-Host 'Broadcast direto da rede (cálculo)'
$calculos = [ordered]@{
    '10.0.1.20/23'     = @('10.0.1.20', 23, '10.0.1.255')
    '10.0.0.20/23'     = @('10.0.0.20', 23, '10.0.1.255')
    '192.168.1.111/24' = @('192.168.1.111', 24, '192.168.1.255')
    '172.16.5.9/16'    = @('172.16.5.9', 16, '172.16.255.255')
    '10.0.0.5/30'      = @('10.0.0.5', 30, '10.0.0.7')
    '10.0.0.1/31'      = @('10.0.0.1', 31, '')
    '10.0.0.1/32'      = @('10.0.0.1', 32, '')
    'IPv6'             = @('fe80::1', 64, '')
    'texto inválido'   = @('x', 24, '')
}
foreach ($nome in $calculos.Keys) {
    $ip, $prefixo, $esperado = $calculos[$nome]
    $obtido = Get-NextecBroadcastIPv4 -Ip $ip -Prefixo $prefixo
    Conferir "broadcast de $nome" ($obtido -eq $esperado) "esperado '$esperado', obtido '$obtido'"
}

Write-Host 'Parte 2: filtros do bloco'
# Interpreta os estágios stage.drop e stage.regex do bloco gerado, na ordem, como o Alloy faz.
function ConvertFrom-AlloyString([string]$s) { return ($s -replace '\\(["\\])', '$1') }
$estagios = New-Object System.Collections.Generic.List[object]
$atual = $null
foreach ($l in $linhas) {
    if ($l -match '^\s*stage\.(drop|regex) \{\s*$') { $atual = @{ tipo = $Matches[1]; attrs = @{} }; continue }
    if ($null -ne $atual) {
        if ($l -match '^\s*\}\s*$') { $estagios.Add($atual); $atual = $null; continue }
        if ($l -match '^\s*(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"\s*$') { $atual.attrs[$Matches[1]] = ConvertFrom-AlloyString $Matches[2] }
    }
}
Conferir 'estágios drop e regex encontrados' (@($estagios | Where-Object { $_.tipo -eq 'drop' }).Count -eq 5 -and @($estagios | Where-Object { $_.tipo -eq 'regex' }).Count -eq 1) "estágios: $($estagios.Count)"

function Processar-Linha([string]$linha) {
    # Devolve $null quando o Alloy descartaria a linha; senão, o texto da mensagem.
    $extraido = @{}
    foreach ($e in $estagios) {
        $a = $e.attrs
        if ($e.tipo -eq 'regex') {
            $m = [regex]::Match($linha, ($a['expression'] -replace '\(\?P<', '(?<'))
            if ($m.Success) { foreach ($g in $m.Groups) { if ($g.Name -notmatch '^\d+$') { $extraido[$g.Name] = $g.Value } } }
            continue
        }
        $alvo = $linha
        if ($a.ContainsKey('source')) {
            if (-not $extraido.ContainsKey($a['source'])) { continue }
            $alvo = $extraido[$a['source']]
        }
        if ($a.ContainsKey('value') -and $alvo -eq $a['value']) { return $null }
        if ($a.ContainsKey('expression') -and [regex]::IsMatch($alvo, $a['expression'])) { return $null }
    }
    return ('🔐 SERVIDOR_ONLINE · Bloqueio no firewall do Windows · {0} {1} → porta {2}' -f $extraido['proto'], $extraido['ip_origem'], $extraido['porta_destino'])
}

$cab = '2026-11-17 10:00:00'
$casos = [ordered]@{
    'DROP RECEIVE passa'                 = @("$cab DROP TCP 203.0.113.5 10.0.0.10 51234 3389 52 S 1 0 8192 0 0 - RECEIVE", '🔐 SERVIDOR_ONLINE · Bloqueio no firewall do Windows · TCP 203.0.113.5 → porta 3389')
    'DROP UDP IPv6 passa'                = @("$cab DROP UDP 2001:db8::1 2001:db8::2 5353 5355 60 - - - - - - - RECEIVE", '🔐 SERVIDOR_ONLINE · Bloqueio no firewall do Windows · UDP 2001:db8::1 → porta 5355')
    'ALLOW é descartado'                 = @("$cab ALLOW TCP 203.0.113.5 10.0.0.10 51234 443 52 S 1 0 8192 0 0 - RECEIVE", $null)
    'SEND é descartado'                  = @("$cab DROP TCP 10.0.0.10 203.0.113.5 51234 443 52 S 1 0 8192 0 0 - SEND", $null)
    'broadcast direto da rede local é descartado' = @("$cab DROP UDP 10.0.1.20 10.0.1.255 137 137 78 - - - - - - - RECEIVE", $null)
    'host .255 de rede maior (/23) passa' = @("$cab DROP TCP 203.0.113.5 10.0.0.255 51234 445 52 S 1 0 8192 0 0 - RECEIVE", '🔐 SERVIDOR_ONLINE · Bloqueio no firewall do Windows · TCP 203.0.113.5 → porta 445')
    'broadcast 255.255.255.255'          = @("$cab DROP UDP 10.0.0.20 255.255.255.255 68 67 328 - - - - - - - RECEIVE", $null)
    'multicast 224.0.0.251'              = @("$cab DROP UDP 10.0.0.20 224.0.0.251 5353 5353 72 - - - - - - - RECEIVE", $null)
    'multicast 239.255.255.250'          = @("$cab DROP UDP 10.0.0.20 239.255.255.250 50000 1900 200 - - - - - - - RECEIVE", $null)
    'multicast IPv6 ff02::1'             = @("$cab DROP UDP 2001:db8::1 ff02::1 546 547 100 - - - - - - - RECEIVE", $null)
    'loopback 127.0.0.1 na origem'       = @("$cab DROP TCP 127.0.0.1 10.0.0.10 50000 445 52 S 1 0 8192 0 0 - RECEIVE", $null)
    'loopback ::1 na origem'             = @("$cab DROP TCP ::1 ::1 50000 445 52 S 1 0 8192 0 0 - RECEIVE", $null)
    'link-local fe80: na origem'         = @("$cab DROP UDP fe80::2 2001:db8::2 5353 5355 60 - - - - - - - RECEIVE", $null)
    'cabeçalho #Version'                 = @('#Version: 1.5', $null)
    'cabeçalho #Fields'                  = @('#Fields: date time action protocol src-ip dst-ip src-port dst-port size tcpflags tcpsyn tcpack tcpwin icmptype icmpcode info path', $null)
    'linha vazia'                        = @('', $null)
    'linha só com espaços'               = @('   ', $null)
    'linha sem data'                     = @('texto qualquer sem data', $null)
}
foreach ($nome in $casos.Keys) {
    $linha, $esperado = $casos[$nome]
    $obtido = Processar-Linha $linha
    Conferir $nome ($obtido -eq $esperado) "esperado '$esperado', obtido '$obtido'"
}

Write-Host 'Parte 3: a resposta sobrevive ao Reconfigurar, ao Ver e alterar e ao -Atualizar'
$cabecalhoSim = "// nextec:cliente     = x`n// nextec:firewall_bloqueios = sim`n"
$cabecalhoNao = "// nextec:cliente     = x`n// nextec:firewall_bloqueios = nao`n"
Conferir 'cabeçalho sim: ligada' (Get-FirewallLogsDoConfig -Content $cabecalhoSim)
Conferir 'cabeçalho nao: desligada' (-not (Get-FirewallLogsDoConfig -Content $cabecalhoNao))
Conferir 'cabeçalho + bloco gerado: ligada' (Get-FirewallLogsDoConfig -Content ($cabecalhoSim + $bloco))
Conferir 'config sem nada: desligada' (-not (Get-FirewallLogsDoConfig -Content "// nextec:cliente = x`nloki.write ""nextec"" {}`n"))
Conferir 'bloco colado à mão, sem cabeçalho: ligada (não se perde na regeração)' (Get-FirewallLogsDoConfig -Content "prometheus.remote_write ""nextec"" {}`n$bloco")
Conferir 'conteúdo vazio: desligada' (-not (Get-FirewallLogsDoConfig -Content ''))
# O que Reconfigurar e -Atualizar fazem: ler -> importar -> regerar. Aqui o ciclo inteiro, sem o Alloy.
$lido = Get-FirewallLogsDoConfig -Content ($cabecalhoSim + $bloco)
$regerado = @(Get-FirewallWindowsAlloyLines -Ativo $lido @dados -BroadcastsLocais @('10.0.1.255')) -join "`n"
Conferir 'ciclo ler e regerar mantém o bloco' ($regerado -eq $bloco)

# Padrão da resposta: parâmetro vence; sem parâmetro vale o config.alloy; sem config, desligada.
. ([scriptblock]::Create((Corpo-Funcao 'Get-NextecFirewallPadrao')))
function Write-Warn([string]$Mensagem) { }
$script:OriginalBoundParameters = @{}
$ColetarBloqueiosFirewall = [switch]$false
function Read-CurrentAlloyConfiguration { return [pscustomobject]@{ EnableFirewall = $true } }
Conferir 'sem parâmetro e config ligada: mantém ligada (Reconfigurar, -Silent sem o parâmetro)' (Get-NextecFirewallPadrao)
function Read-CurrentAlloyConfiguration { return [pscustomobject]@{ EnableFirewall = $false } }
Conferir 'sem parâmetro e config desligada: desligada' (-not (Get-NextecFirewallPadrao))
function Read-CurrentAlloyConfiguration { return $null }
Conferir 'sem parâmetro e sem config: desligada' (-not (Get-NextecFirewallPadrao))
$script:OriginalBoundParameters = @{ ColetarBloqueiosFirewall = $true }
$ColetarBloqueiosFirewall = [switch]$true
Conferir 'parâmetro informado: ligada' (Get-NextecFirewallPadrao)
function Read-CurrentAlloyConfiguration { return [pscustomobject]@{ EnableFirewall = $true } }
$script:OriginalBoundParameters = @{ ColetarBloqueiosFirewall = $true }
$ColetarBloqueiosFirewall = [switch]$false
Conferir '-ColetarBloqueiosFirewall:$false vence a config e desliga' (-not (Get-NextecFirewallPadrao))
function Read-CurrentAlloyConfiguration { throw 'falha de leitura' }
$script:OriginalBoundParameters = @{}
Conferir 'falha ao ler a config: avisa e parte de desligada' (-not (Get-NextecFirewallPadrao))

Write-Host 'Parte 4: regras de código'
$escreve = Corpo-Funcao 'New-AlloyConfiguration'
Conferir 'New-AlloyConfiguration grava o cabeçalho nextec:firewall_bloqueios' ($escreve.Contains('// nextec:firewall_bloqueios = '))
Conferir 'New-AlloyConfiguration chama o bloco com o estado resolvido e só em host monitorado' (
    $escreve -match 'Get-FirewallWindowsAlloyLines[\s\S]{0,80}-Ativo \(\[bool\]\(\$script:MonitorHost -and \$script:EnableFirewallLogsResolved\)\)')
Conferir 'o loki.write sai também quando só o firewall está ligado' (
    $escreve -match '\$script:MonitorHost -and \(\$script:EnableLogsResolved -or \$script:EnableSecurityLogsResolved -or \$script:EnableFirewallLogsResolved\)')
$posLokiWrite = $escreve.IndexOf('loki.write "nextec" {')
$posFirewall = $escreve.IndexOf('Get-FirewallWindowsAlloyLines')
$posColeta = $escreve.IndexOf('loki.source.file "coleta_complementar"')
Conferir 'o bloco é gerado depois do loki.write e dentro do mesmo if' ($posLokiWrite -ge 0 -and $posFirewall -gt $posLokiWrite -and $posFirewall -lt $posColeta)
Conferir 'Test-NextecNeedsLoki considera o firewall' ((Corpo-Funcao 'Test-NextecNeedsLoki').Contains('$script:EnableFirewallLogsResolved'))
Conferir 'Read-CurrentAlloyConfiguration devolve EnableFirewall' ((Corpo-Funcao 'Read-CurrentAlloyConfiguration') -match 'EnableFirewall\s*=\s*\$enableFirewall')
Conferir 'Import-CurrentConfiguration (Reconfigurar, Atualizar, Ver e alterar) importa EnableFirewall' ((Corpo-Funcao 'Import-CurrentConfiguration') -match 'EnableFirewallLogsResolved\s*=\s*\[bool\]\$c\.EnableFirewall')
Conferir 'menu Ver e alterar pergunta pelo firewall' ((Corpo-Funcao 'Edit-LogSettings').Contains('EnableFirewallLogsResolved = Read-YesNo'))
Conferir 'checklist do modo interativo e do -Silent tem o item firewall' ((Corpo-Funcao 'Read-ResourceChecklist') -match 'Key "firewall"')
Conferir 'o resumo avisa quando o log não existe' ((Corpo-Funcao 'Show-Plan').Contains('Write-NextecFirewallAviso'))
Conferir 'o instalador não liga o firewall nem muda perfis' (-not ((Corpo-Funcao 'Write-NextecFirewallAviso') -match 'Set-NetFirewall|netsh|Enable-NetFirewall|auditpol'))

if ($script:falhas -gt 0) {
    Write-Host "$script:falhas teste(s) falharam."
    exit 1
}
Write-Host 'Todos os testes passaram.'
exit 0
