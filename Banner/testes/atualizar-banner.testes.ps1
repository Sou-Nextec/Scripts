<#
    Testes do Banner/atualizar-banner.ps1 (atualização diária do painel nos servidores Windows).

    O atualizador troca um script em todos os servidores sem ninguém olhar, então as regras de quando trocar,
    quando esperar e quando recusar ficam travadas aqui.

    Parte 1: regra de decisão (Decidir) em todos os casos.
    Parte 2: identificador do conteúdo (ShaGit) igual ao do git, que é o que o GitHub devolve.
    Parte 3: regras de código (commit fixado, sintaxe conferida antes de instalar, volta da versão anterior).

    Uso: .\Banner\testes\atualizar-banner.testes.ps1      (código de saída 1 se algum teste falhar)
#>
$ErrorActionPreference = 'Stop'
$script:falhas = 0
$arquivo = (Resolve-Path (Join-Path $PSScriptRoot '..\atualizar-banner.ps1')).Path

function Conferir([string]$nome, [bool]$passou, [string]$detalhe = '') {
    if ($passou) {
        Write-Host "  ok    $nome"
    } else {
        $script:falhas++
        Write-Host "::error file=Banner/atualizar-banner.ps1::$nome $detalhe"
        Write-Host "  FALHA $nome $detalhe"
    }
}

$tokens = $null
$errosSintaxe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$errosSintaxe)
if ($errosSintaxe) { throw "atualizar-banner.ps1 tem erro de sintaxe: $($errosSintaxe[0].Message)" }

$funcoes = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcoes[$f.Name] = $f
}
foreach ($nome in 'Decidir', 'ShaGit', 'ParaUtc', 'PainelAbriu') {
    if (-not $funcoes.ContainsKey($nome)) { throw "Função $nome não encontrada no atualizar-banner.ps1" }
    . ([scriptblock]::Create($funcoes[$nome].Extent.Text))
}

# ---------- Parte 1: regra de decisão ----------
Write-Host 'Parte 1: regra de decisão'
$hoje = [datetime]'2026-10-24T10:00:00'
$base = @{
    CommitInstalado = 'aaa'; CommitRecusado = ''; CommitRemoto = 'bbb'; DataRemota = $hoje.AddDays(-3)
    ShaLocal = 'local'; ShaRemoto = 'remoto'; Tipo = 'cliente'; Momento = $hoje; DiasEspera = 2; SemEspera = $false
}
function Caso([hashtable]$mudancas) {
    $p = $base.Clone()
    foreach ($k in $mudancas.Keys) { $p[$k] = $mudancas[$k] }
    return Decidir @p
}

Conferir 'Mesmo commit instalado: não faz nada' ((Caso @{ CommitRemoto = 'aaa' }) -eq 'nada')
Conferir 'Commit que já falhou neste servidor: não tenta de novo' ((Caso @{ CommitRecusado = 'bbb' }) -eq 'nada')
Conferir 'Arquivo igual ao instalado: só registra o commit, sem reabrir painel' ((Caso @{ ShaRemoto = 'local' }) -eq 'registrar')
Conferir 'Primeira verificação com arquivo igual: registra mesmo se o commit é recente' `
    ((Caso @{ CommitInstalado = ''; ShaRemoto = 'local'; DataRemota = $hoje.AddHours(-1) }) -eq 'registrar')
Conferir 'Cliente, versão de 1 dia: aguarda' ((Caso @{ DataRemota = $hoje.AddDays(-1) }) -eq 'aguardar')
Conferir 'Cliente, versão de 1 dia e 23 horas: ainda aguarda' ((Caso @{ DataRemota = $hoje.AddHours(-47) }) -eq 'aguardar')
Conferir 'Cliente, versão de 2 dias: atualiza' ((Caso @{ DataRemota = $hoje.AddDays(-2) }) -eq 'atualizar')
Conferir 'Cliente, versão de 3 dias: atualiza' ((Caso @{}) -eq 'atualizar')
Conferir 'Nextec, versão de 1 hora: atualiza na hora' ((Caso @{ Tipo = 'nextec'; DataRemota = $hoje.AddHours(-1) }) -eq 'atualizar')
Conferir 'Cliente com -Agora, versão de 1 hora: atualiza' ((Caso @{ SemEspera = $true; DataRemota = $hoje.AddHours(-1) }) -eq 'atualizar')
Conferir 'Commit recusado vale também para a Nextec' ((Caso @{ Tipo = 'nextec'; CommitRecusado = 'bbb' }) -eq 'nada')
Conferir 'Commit novo depois de um recusado: volta a atualizar' ((Caso @{ CommitRecusado = 'ccc' }) -eq 'atualizar')

Conferir 'Data do GitHub em texto vira UTC certo' ((ParaUtc '2026-10-24T13:35:06Z') -eq [datetime]::SpecifyKind([datetime]'2026-10-24 13:35:06', 'Utc'))
$local = [datetime]::SpecifyKind([datetime]'2026-10-24 10:35:06', 'Local')
Conferir 'Data já convertida pelo PowerShell 7 vira UTC certo' ((ParaUtc $local) -eq $local.ToUniversalTime())
Conferir 'Decisão usa UTC dos dois lados' ($funcoes['Atualizar'].Extent.Text -match '-Momento \(\[DateTime\]::UtcNow\)')

# ---------- Sinal de que o painel abriu ----------
Write-Host 'Sinal de que o painel abriu'
$reabertura = [datetime]'2026-10-24 10:00:00'
$antigo = '2026-10-24 09:59:58 Painel ancorado: WorkerW'
Conferir 'Painel ancorado depois da reabertura: abriu' (PainelAbriu @($antigo, '2026-10-24 10:00:05 Painel ancorado: WorkerW') $reabertura)
Conferir 'Painel visível na tela depois da reabertura: abriu' (PainelAbriu @('2026-10-24 10:00:07 Painel visível na tela: Progman (24H2)') $reabertura)
Conferir 'Só registro anterior à reabertura: não abriu' (-not (PainelAbriu @($antigo) $reabertura))
Conferir 'Processo vivo com erro repetido: não abriu' `
    (-not (PainelAbriu @('2026-10-24 10:00:03 Início: Windows', '2026-10-24 10:00:04 Painel: Exception calling Aplicar', '2026-10-24 10:00:09 Painel: Exception calling Aplicar') $reabertura))
Conferir 'Log vazio: não abriu' (-not (PainelAbriu @() $reabertura))

# ---------- Parte 2: identificador do conteúdo ----------
Write-Host 'Parte 2: identificador do conteúdo'
$amostras = @(
    [byte[]]@(),
    [System.Text.Encoding]::UTF8.GetBytes("Write-Host 'olá'`r`n"),
    [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\quadro-windows.ps1'))
)
$git = Get-Command git -ErrorAction SilentlyContinue
foreach ($bytes in $amostras) {
    $calculado = ShaGit $bytes
    if ($git) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            $esperado = (& git hash-object --no-filters $tmp).Trim()
        } finally { Remove-Item -LiteralPath $tmp -Force }
        Conferir "ShaGit igual ao git hash-object ($($bytes.Length) bytes)" ($calculado -eq $esperado) "($calculado x $esperado)"
    }
}
Conferir 'ShaGit de arquivo vazio igual ao valor conhecido do git' ((ShaGit ([byte[]]@())) -eq 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')

# ---------- Parte 3: regras de código ----------
Write-Host 'Parte 3: regras de código'
$texto = $ast.Extent.Text
$corpoAtualizar = $funcoes['Atualizar'].Extent.Text

Conferir 'Busca o arquivo pelo commit (ref=commit), não pelo ramo' ($corpoAtualizar -match 'contents/.*\?ref=\$commitRemoto')
Conferir 'Confere o conteúdo baixado contra o identificador do GitHub' ($corpoAtualizar -match 'ShaGit \$bytesRemotos' -and $corpoAtualizar -match '\$conteudo\.sha')
Conferir 'Confere a sintaxe antes de instalar' ($corpoAtualizar.IndexOf('SintaxeValida') -ge 0 -and $corpoAtualizar.IndexOf('SintaxeValida') -lt $corpoAtualizar.IndexOf('Move-Item'))
Conferir 'Guarda a versão anterior antes de trocar' ($corpoAtualizar.IndexOf('$anterior -Force') -lt $corpoAtualizar.IndexOf('Move-Item'))
Conferir 'Devolve a versão anterior quando o painel não abre' ($corpoAtualizar -match 'Copy-Item -LiteralPath \$anterior -Destination \$Quadro')
Conferir 'Erro depois da troca também devolve a versão anterior (catch com volta)' `
    ($corpoAtualizar -match 'catch \{\s*if \(-not \$instalada\) \{ throw \}' -and $corpoAtualizar.IndexOf('catch {') -lt $corpoAtualizar.IndexOf('Copy-Item -LiteralPath $anterior -Destination $Quadro'))
Conferir 'Confere o painel pelo log (AguardarPainel), não só pelo processo' ($corpoAtualizar -match 'AguardarPainel \$inicio')
Conferir 'Painel ancorado é o sinal registrado pelo quadro-windows.ps1' `
    ((Get-Content (Join-Path $PSScriptRoot '..\quadro-windows.ps1') -Raw -Encoding UTF8) -match 'Registrar "Painel ancorado: ')
Conferir 'Espera padrão de 2 dias para clientes' ($texto -match '\$DiasEspera\s*=\s*2\b')
Conferir 'Só o tipo nextec atualiza sem espera' ($funcoes['Decidir'].Extent.Text -match "\`$Tipo -eq 'nextec'")
Conferir 'Erros vão para o log e encerram com código 1' ($texto -match 'catch \{\s*Registrar[^\}]*\}?\s*[\s\S]*exit 1')

if ($script:falhas -gt 0) {
    Write-Host "$($script:falhas) teste(s) falharam."
    exit 1
}
Write-Host 'Testes do atualizar-banner OK.'
exit 0
