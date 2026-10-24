<#
    Testes do Banner/quadro-windows.ps1 (painel da área de trabalho dos servidores Windows).

    O painel fica aberto por dias e coleta métricas a cada 10 segundos, então qualquer recurso não liberado na coleta
    vira vazamento. Já aconteceu: em outubro de 2026 o painel chegou a 8 GB e 43 mil handles numa estação com 8 GB.

    Parte 1 (qualquer sistema): regras de código que evitam a volta do vazamento.
    Parte 2 (só Windows): executa a coleta real centenas de vezes e confere se memória e handles ficam estáveis.

    Uso: .\Banner\testes\quadro-windows.testes.ps1      (código de saída 1 se algum teste falhar)
#>
$ErrorActionPreference = 'Stop'
$script:falhas = 0
$arquivo = (Resolve-Path (Join-Path $PSScriptRoot '..\quadro-windows.ps1')).Path

function Conferir([string]$nome, [bool]$passou, [string]$detalhe = '') {
    if ($passou) {
        Write-Host "  ok    $nome"
    } else {
        $script:falhas++
        Write-Host "::error file=Banner/quadro-windows.ps1::$nome $detalhe"
        Write-Host "  FALHA $nome $detalhe"
    }
}

$tokens = $null
$errosSintaxe = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$errosSintaxe)
if ($errosSintaxe) { throw "quadro-windows.ps1 tem erro de sintaxe: $($errosSintaxe[0].Message)" }

$funcoes = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcoes[$f.Name] = $f
}

function ComandosEm($no, [string]$nome) {
    @($no.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $nome
    }, $true))
}

function DentroDe($no, [string]$funcao) {
    $pai = $no.Parent
    while ($pai) {
        if ($pai -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $pai.Name -eq $funcao) { return $true }
        $pai = $pai.Parent
    }
    return $false
}

# ---------- Parte 1: regras de código ----------
Write-Host 'Parte 1: regras de código'

Conferir 'Get-NetIPConfiguration não é usado (abre várias consultas CIM por chamada)' `
    ((ComandosEm $ast 'Get-NetIPConfiguration').Count -eq 0)

$cimFora = @(ComandosEm $ast 'Get-CimInstance' | Where-Object { -not (DentroDe $_ 'ConsultarCim') })
Conferir 'Get-CimInstance só dentro do ConsultarCim (sessão reaproveitada e instâncias descartadas)' `
    ($cimFora.Count -eq 0) ("(linhas: $(($cimFora | ForEach-Object { $_.Extent.StartLineNumber }) -join ', '))")

Conferir 'ConsultarCim descarta as instâncias (Dispose em finally)' `
    ($funcoes.ContainsKey('ConsultarCim') -and $funcoes['ConsultarCim'].Extent.Text -match 'finally[\s\S]*\.Dispose\(\)')

Conferir 'Sessão CIM local por DCOM (não depende do WinRM)' `
    ($funcoes.ContainsKey('SessaoCim') -and $funcoes['SessaoCim'].Extent.Text -match '-Protocol\s+Dcom')

$coletaFuncoes = 'Coletar', 'ColetarLentos', 'Tique', 'Preencher'
$getProcess = @(foreach ($n in $coletaFuncoes) { if ($funcoes.ContainsKey($n)) { ComandosEm $funcoes[$n] 'Get-Process' } })
Conferir 'Get-Process fora do ciclo de coleta (objetos Process sem Dispose)' ($getProcess.Count -eq 0)

Conferir 'ContarProcessos descarta os objetos Process' `
    ($funcoes.ContainsKey('ContarProcessos') -and $funcoes['ContarProcessos'].Extent.Text -match 'finally[\s\S]*\.Dispose\(\)')

Conferir 'Proteção de memória chamada no Tique' `
    ($funcoes.ContainsKey('ConferirMemoria') -and $funcoes.ContainsKey('Tique') -and (ComandosEm $funcoes['Tique'] 'ConferirMemoria').Count -gt 0)

Conferir 'Reinício pela proteção libera o mutex antes de abrir o painel novo' `
    ($ast.Extent.Text -match '\$mutex\.ReleaseMutex\(\)[\s\S]*AbrirNovaInstancia')

# ---------- Parte 2: coleta real em laço (só Windows) ----------
$ehWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $ehWindows) {
    Write-Host 'Parte 2: ignorada (só roda no Windows)'
} else {
    Write-Host 'Parte 2: coleta real em laço'
    Add-Type -AssemblyName System.Drawing
    if (-not ('NextecLinha' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
public class NextecLinha
{
    public string Rotulo = "";
    public string Valor = "";
    public bool Negrito;
    public bool TemCor;
    public System.Drawing.Color Cor;
    public bool Espaco;
}
'@
    }

    # Mesmo ambiente que o painel monta antes de coletar
    $PastaUsuario = Join-Path ([System.IO.Path]::GetTempPath()) 'nextec-quadro-teste'
    $CiclosEntreLentos = 6
    $script:sessaoCim = $null
    $script:lentos = $null
    $script:ciclosLentos = 0
    $script:avisouSessaoCim = $false
    $corAlerta  = [System.Drawing.Color]::FromArgb(255, 213, 79)
    $corCritica = [System.Drawing.Color]::FromArgb(239, 83, 80)

    $necessarias = 'Registrar', 'Ler', 'Seguro', 'NovaLinha', 'CorDoUso', 'SessaoCim', 'FecharSessaoCim',
                   'ConsultarCim', 'IpPrincipal', 'ContarProcessos', 'ColetarLentos', 'Coletar'
    foreach ($nome in $necessarias) {
        if (-not $funcoes.ContainsKey($nome)) { throw "Função $nome não encontrada no quadro-windows.ps1" }
        . ([scriptblock]::Create($funcoes[$nome].Extent.Text))
    }

    function Medir {
        [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
        $eu = [System.Diagnostics.Process]::GetCurrentProcess()
        try { [pscustomobject]@{ PrivadaMB = $eu.PrivateMemorySize64 / 1MB; Handles = $eu.HandleCount } }
        finally { $eu.Dispose() }
    }

    $dados = Coletar
    Conferir 'Coleta devolve as 8 linhas do painel' ($dados.Linhas.Count -eq 8)
    Conferir 'Coleta lê a memória do sistema' (($dados.Linhas | Where-Object Rotulo -eq 'Memória').Valor -match '^\d+% de ')

    # Aquecimento: carrega módulos, tipos e a sessão CIM antes de medir
    for ($i = 0; $i -lt 30; $i++) { [void](Coletar) }
    $antes = Medir

    # 360 ciclos = 1 hora de painel aberto (um ciclo a cada 10 s)
    $ciclos = 360
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $ciclos; $i++) { [void](Coletar) }
    $relogio.Stop()
    $depois = Medir
    FecharSessaoCim

    $crescMB = [math]::Round($depois.PrivadaMB - $antes.PrivadaMB, 1)
    $crescHandles = $depois.Handles - $antes.Handles
    Write-Host ("        {0} ciclos em {1:N1} s; memória privada {2:N1} -> {3:N1} MB; handles {4} -> {5}" -f
        $ciclos, $relogio.Elapsed.TotalSeconds, $antes.PrivadaMB, $depois.PrivadaMB, $antes.Handles, $depois.Handles)

    # Limites folgados para o ruído do runner; o vazamento original passava de 100 handles e 30 MB por hora
    Conferir 'Handles estáveis em 1 hora de coleta (até 60 a mais)' ($crescHandles -le 60) "(cresceu $crescHandles)"
    Conferir 'Memória estável em 1 hora de coleta (até 20 MB a mais)' ($crescMB -le 20) "(cresceu $crescMB MB)"
}

if ($script:falhas -gt 0) {
    Write-Host "$($script:falhas) teste(s) falharam."
    exit 1
}
Write-Host 'Testes do quadro-windows OK.'
exit 0
