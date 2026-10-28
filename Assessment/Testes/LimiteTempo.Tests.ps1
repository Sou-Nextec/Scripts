# Testes dos limites de tempo do Nextec-Assessment-v2.ps1 (Pester 3.4+).
# Carrega só as funções auxiliares pelo AST, sem executar a coleta.
$script:Raiz = Split-Path -Parent $PSScriptRoot
$arquivo = Join-Path $script:Raiz 'Nextec-Assessment-v2.ps1'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros)

Describe 'Nextec-Assessment-v2.ps1' {
    It 'não tem erro de sintaxe' {
        @($erros).Count | Should Be 0
    }
    It 'não chama netsh, vssadmin, auditpol, w32tm, dcdiag ou repadmin sem limite de tempo' {
        $semLimite = Select-String -Path $arquivo -Pattern "Save-Texto '|[({;]\s*(netsh|vssadmin|auditpol|w32tm|dcdiag|repadmin|omreport)\s+(/|wlan|winhttp|list|storage|chassis|system)" -Encoding UTF8
        @($semLimite).Count | Should Be 0
    }
}

$nomes = 'Write-Log', 'Close-LinhaEtapa', 'Invoke-ComandoComTimeout', 'Invoke-Externo', 'Save-TextoExterno', 'Invoke-ComLimiteTempo'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $nomes }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}

Describe 'Invoke-ComandoComTimeout' {
    It 'devolve a saída do comando' {
        Invoke-ComandoComTimeout 'cmd.exe' '/c echo nextec' 5000 | Should Match 'nextec'
    }
    It 'devolve $null e mata o processo quando passa do tempo' {
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ComandoComTimeout 'ping.exe' '-n 30 127.0.0.1' 1500
        $relogio.Stop()
        ($null -eq $r) | Should Be $true
        ($relogio.Elapsed.TotalSeconds -lt 5) | Should Be $true
    }
    It 'devolve vazio (não $null) quando o executável não existe' {
        $r = Invoke-ComandoComTimeout 'nao-existe-nextec.exe' '' 2000
        ($null -ne $r) | Should Be $true
    }
}

Describe 'Save-TextoExterno' {
    It 'grava o arquivo com aviso quando o comando trava, sem segurar a coleta' {
        $script:PastaSaida = Join-Path $env:TEMP "assessment-teste-$PID"
        New-Item -ItemType Directory -Path $script:PastaSaida -Force | Out-Null
        $script:Arquivos = New-Object System.Collections.Generic.List[object]
        $script:ArquivoLog = Join-Path $script:PastaSaida 'coleta.log'
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        Save-TextoExterno 'teste' @('ping -n 30 127.0.0.1', 'cmd /c echo segue') 'Teste' 1 6>$null
        $relogio.Stop()
        $conteudo = Get-Content (Join-Path $script:PastaSaida 'teste.txt') -Raw -Encoding UTF8
        $conteudo | Should Match 'sem resposta em 1 s'
        $conteudo | Should Match 'segue'
        ($relogio.Elapsed.TotalSeconds -lt 6) | Should Be $true
        $script:Arquivos.Count | Should Be 1
    }
}

Describe 'Invoke-ComLimiteTempo' {
    It 'devolve o resultado do bloco' {
        Invoke-ComLimiteTempo { 1 + 1 } 'Soma' 10 | Should Be 2
    }
    It 'desiste no prazo quando o bloco trava' {
        $script:ArquivoLog = Join-Path $env:TEMP "assessment-teste-$PID.log"
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        $estourou = $false
        try { Invoke-ComLimiteTempo { Start-Sleep -Seconds 60 } 'Bloco lento' 2 6>$null } catch [System.TimeoutException] { $estourou = $true }
        $relogio.Stop()
        $estourou | Should Be $true
        ($relogio.Elapsed.TotalSeconds -lt 6) | Should Be $true
    }
}

Describe 'Discos físicos pelo runspace' {
    It 'devolve a saúde do disco como texto (Healthy), não como número' {
        $chamada = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-ComLimiteTempo' -and $n.Extent.Text -match 'Discos físicos e SMART' }, $true) | Select-Object -First 1
        $bloco = ($chamada.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1).ScriptBlock.GetScriptBlock()
        $discos = @(Invoke-ComLimiteTempo ([scriptblock]::Create($bloco.ToString())) 'Discos' 60)
        $discos.Count | Should BeGreaterThan 0
        $discos[0].Disco.HealthStatus | Should Not Match '^\d+$'
    }
}
