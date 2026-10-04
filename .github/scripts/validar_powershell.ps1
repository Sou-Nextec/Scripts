<#
    Confere a sintaxe de todos os .ps1 do repositório com o parser do
    PowerShell que estiver rodando (pwsh 7 no Linux, Windows PowerShell 5.1
    no runner Windows) e, quando o PSScriptAnalyzer está disponível, os
    achados de severidade Error.
#>
$ErrorActionPreference = 'Stop'
$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$arquivos = @(& git -C $raiz ls-files '*.ps1' | ForEach-Object { Join-Path $raiz $_ })
$falhas = 0

Write-Host ("PowerShell {0}: {1} arquivo(s)" -f $PSVersionTable.PSVersion, $arquivos.Count)
foreach ($arquivo in $arquivos) {
    $tokens = $null
    $erros = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros)
    foreach ($erro in $erros) {
        $falhas++
        Write-Host ("::error file={0},line={1}::{2}" -f $arquivo.Substring($raiz.Length + 1), $erro.Extent.StartLineNumber, $erro.Message)
    }
}

$temAnalisador = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
if (-not $temAnalisador -and $env:EXIGIR_PSSA -eq '1') {
    $falhas++
    Write-Host "::error::PSScriptAnalyzer não está instalado."
}
if ($temAnalisador) {
    Write-Host "PSScriptAnalyzer: severidade Error"
    foreach ($arquivo in $arquivos) {
        foreach ($achado in @(Invoke-ScriptAnalyzer -Path $arquivo -Severity Error)) {
            $falhas++
            Write-Host ("::error file={0},line={1}::{2}: {3}" -f $arquivo.Substring($raiz.Length + 1), $achado.Line, $achado.RuleName, $achado.Message)
        }
    }
}

if ($falhas -gt 0) {
    Write-Host ("{0} problema(s) encontrado(s)." -f $falhas)
    exit 1
}
Write-Host "PowerShell OK."
