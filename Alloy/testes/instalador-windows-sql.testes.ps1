<#
    Testes do instalador Windows: coleta de eventos e do ERRORLOG do SQL Server (2.29.0).

    Parte 1: Get-SqlErrorLogPaths lê o caminho do ERRORLOG de cada instância no registro
             (num ramo temporário do HKCU, sem tocar no HKLM).
    Parte 2: filtro dos eventos 7036 e 7040: só os dos serviços SQL seguem.
    Parte 3: regra de código: o filtro vem depois do static_labels, que é quem cria o rótulo canal.

    Uso: .\Alloy\testes\instalador-windows-sql.testes.ps1      (código de saída 1 se algum teste falhar)
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

$funcao = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SqlErrorLogPaths' }, $true)
if (-not $funcao) { throw 'Função Get-SqlErrorLogPaths não encontrada no instalador' }
. ([scriptblock]::Create($funcao.Extent.Text))

Write-Host 'Parte 1: caminho do ERRORLOG no registro'
$raiz = "HKCU:\Software\NextecTesteSql\$([guid]::NewGuid().ToString('N'))"
$pasta = Join-Path ([System.IO.Path]::GetTempPath()) ("nextec-sql-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $pasta | Out-Null
    $errorLog = Join-Path $pasta 'ERRORLOG'
    Set-Content -LiteralPath $errorLog -Value 'teste'

    New-Item -Path "$raiz\Instance Names\SQL" -Force | Out-Null
    New-ItemProperty -Path "$raiz\Instance Names\SQL" -Name 'MSSQLSERVER' -Value 'MSSQL16.MSSQLSERVER' | Out-Null
    # Instância com nome iniciado por PS não pode ser confundida com as propriedades do PowerShell.
    New-ItemProperty -Path "$raiz\Instance Names\SQL" -Name 'PSERVER' -Value 'MSSQL16.PSERVER' | Out-Null
    New-ItemProperty -Path "$raiz\Instance Names\SQL" -Name 'SEMARQUIVO' -Value 'MSSQL16.SEMARQUIVO' | Out-Null

    foreach ($instancia in 'MSSQL16.MSSQLSERVER', 'MSSQL16.PSERVER') {
        $parametros = "$raiz\$instancia\MSSQLServer\Parameters"
        New-Item -Path $parametros -Force | Out-Null
        New-ItemProperty -Path $parametros -Name 'SQLArg0' -Value '-dC:\dados\master.mdf' | Out-Null
        New-ItemProperty -Path $parametros -Name 'SQLArg1' -Value ("-e" + $errorLog) | Out-Null
    }
    $parametros = "$raiz\MSSQL16.SEMARQUIVO\MSSQLServer\Parameters"
    New-Item -Path $parametros -Force | Out-Null
    New-ItemProperty -Path $parametros -Name 'SQLArg1' -Value ("-e" + (Join-Path $pasta 'NAO-EXISTE')) | Out-Null

    $achados = @(Get-SqlErrorLogPaths -RaizRegistro $raiz)
    $nomes = @($achados | ForEach-Object { $_.Instancia }) -join ','
    Conferir 'acha as instâncias com ERRORLOG existente' ($nomes -eq 'MSSQLSERVER,PSERVER') "obtido: $nomes"
    Conferir 'caminho vem do argumento -e' (@($achados | Where-Object { $_.Caminho -ne $errorLog }).Count -eq 0)
    Conferir 'instância sem arquivo fica de fora' (-not ($achados.Instancia -contains 'SEMARQUIVO'))
    Conferir 'sem SQL instalado devolve vazio' (@(Get-SqlErrorLogPaths -RaizRegistro "$raiz\nada").Count -eq 0)
} finally {
    Remove-Item -LiteralPath (Split-Path $raiz) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pasta -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Parte 2: filtro dos eventos de serviço'
$texto = [System.IO.File]::ReadAllText($arquivo)
$casamento = [regex]::Match($texto, "DropSelector\s*=\s*'([^']+)'")
Conferir 'DropSelector do sql_sistema existe' $casamento.Success
# Como o Alloy lê: \" vira ", e a seleção é: rótulo, |~ (casa) e !~ (não casa).
$seletor = $casamento.Groups[1].Value -replace '\\"', '"'
$partes = [regex]::Match($seletor, '^\{canal="sql_sistema"\} \|~ "([^"]+)" !~ "([^"]+)"$')
Conferir 'seletor no formato rótulo + |~ + !~' $partes.Success "seletor: $seletor"
$casa = $partes.Groups[1].Value
$naoCasa = $partes.Groups[2].Value
function Descarta([string]$linha) { ($linha -match $casa) -and ($linha -notmatch $naoCasa) }
$eventos = @{
    'SQL Server parado (7036)'            = @('{"source":"Service Control Manager","channel":"System","event_id":7036,"message":"O serviço SQL Server (MSSQLSERVER) entrou no estado parado."}', $false)
    'SQL Server Agent desabilitado (7040)' = @('{"source":"Service Control Manager","channel":"System","event_id":7040,"message":"The start type of the SQL Server Agent (MSSQLSERVER) service was changed from auto start to disabled."}', $false)
    'Windows Update parado (7036)'        = @('{"source":"Service Control Manager","channel":"System","event_id":7036,"message":"O serviço Windows Update entrou no estado parado."}', $true)
    'outro serviço (7040)'                = @('{"source":"Service Control Manager","channel":"System","event_id":7040,"message":"The start type of the Print Spooler service was changed."}', $true)
    'desligamento inesperado (6008)'      = @('{"source":"EventLog","channel":"System","event_id":6008,"message":"O desligamento anterior do sistema foi inesperado."}', $false)
    'desligamento pedido (1074)'          = @('{"source":"User32","channel":"System","event_id":1074,"message":"O processo C:\\Windows\\system32\\shutdown.exe iniciou o reinício."}', $false)
}
foreach ($nome in $eventos.Keys) {
    $linha, $esperado = $eventos[$nome]
    Conferir ("{0}: {1}" -f $nome, $(if ($esperado) { 'descartado' } else { 'segue' })) ((Descarta $linha) -eq $esperado)
}

Write-Host 'Parte 3: ordem dos estágios no loki.process'
$laco = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -eq '$logStreams' }, $true)
Conferir 'laço dos fluxos de log encontrado' ($null -ne $laco)
$corpo = $laco.Body.Extent.Text
$posRotulos = $corpo.IndexOf('stage.static_labels {')
$posFiltro = $corpo.IndexOf('stage.match {')
Conferir 'stage.match depois do stage.static_labels (o rótulo canal já existe)' ($posRotulos -ge 0 -and $posFiltro -gt $posRotulos) "static_labels em $posRotulos, match em $posFiltro"

if ($script:falhas -gt 0) {
    Write-Host "$script:falhas teste(s) falharam."
    exit 1
}
Write-Host 'Todos os testes passaram.'
exit 0
