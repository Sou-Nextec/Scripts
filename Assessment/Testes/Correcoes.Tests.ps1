# Testes de regressão das correções do Nextec-Assessment-v2.ps1 e dos instaladores (Pester 3.4+, Windows PowerShell 5.1).
# Carrega só as funções pelo AST, sem executar a coleta (o script inteiro exige administrador).
$script:Raiz = Split-Path -Parent $PSScriptRoot
$arquivo = Join-Path $script:Raiz 'Nextec-Assessment-v2.ps1'
$arquivoInstalador = Join-Path $script:Raiz 'Instalar-Assessment-Estacao.ps1'
$arquivoCompartilhamento = Join-Path $script:Raiz 'Preparar-Compartilhamento-Assessment.ps1'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros)
$script:TextoV2 = [System.IO.File]::ReadAllText($arquivo, [System.Text.Encoding]::UTF8)

$nomes = 'Get-SituacaoSuporte', 'Get-NomeNetBios', 'Stop-TrabalhosVencidos', 'Get-MembrosAdministradores',
    'Format-SituacaoTpm', 'Test-ServicoBackupReal', 'ConvertTo-NumeroOuNulo', 'New-ComputadoresHtml',
    'ConvertTo-HtmlSeguro', 'ConvertFrom-TxtCymru', 'Get-ResumoOfficeClickToRun', 'Add-DetalhesEstacao',
    'Get-ListaEstacao', 'Save-DetalhesEstacoes', 'Save-Dados', 'ConvertTo-LinhaCsvSegura', 'Test-CelulaPerigosa', 'Add-AlertasColetaLocal', 'Add-Alerta', 'Add-AlertaPorMaquinas'
$funcoesCarregadas = New-Object System.Collections.Generic.List[string]
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $nomes }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
    $funcoesCarregadas.Add($f.Name)
}

# Tabela das listas de estação (lista branca), extraída do v2 pelo AST.
$atribuicaoListas = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ListasEstacao' }, $true) | Select-Object -First 1
if ($atribuicaoListas) { . ([scriptblock]::Create($atribuicaoListas.Extent.Text)) }

function Test-AtrasDeSwitch {
    # Verdadeiro quando o nó está dentro de um if/elseif cuja condição cita a variável (o switch do script).
    param($No, [string]$Variavel)
    $pai = $No.Parent
    while ($pai) {
        if ($pai -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clausula in $pai.Clauses) {
                if ($clausula.Item1.Extent.Text -match [regex]::Escape($Variavel)) { return $true }
            }
        }
        $pai = $pai.Parent
    }
    $false
}

function Find-TextoNoAst {
    param([string]$Padrao)
    @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text.Length -lt 5000 -and $n.Extent.Text -match $Padrao }, $true))
}

function New-EstacaoTeste {
    param([string]$Nome, [hashtable]$Extra = @{})
    $o = [ordered]@{ Computador = $Nome; AcessoEntrada = 'WinRM 5985: liberada | WMI/RPC 135: liberada | SMB 445: N/D | RDP 3389: N/D' }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    [pscustomobject]$o
}

function Get-AlertasTeste {
    param($Estacoes, [hashtable]$Listas = @{})
    $script:Alertas = New-Object System.Collections.Generic.List[object]
    $script:DetalhesEstacoes = @{}
    foreach ($k in $Listas.Keys) {
        $script:DetalhesEstacoes[$k] = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Listas[$k]) { $script:DetalhesEstacoes[$k].Add($item) }
    }
    Add-AlertasColetaLocal $Estacoes
    $script:Alertas.ToArray()
}

Describe 'Nextec-Assessment-v2.ps1: carga dos testes' {
    It 'não tem erro de sintaxe' {
        @($erros).Count | Should Be 0
    }
    It 'tem todas as funções testadas aqui' {
        foreach ($n in $nomes) { ($n -in $funcoesCarregadas.ToArray()) | Should Be $true }
    }
    It 'tem a tabela de listas das estações' {
        $script:ListasEstacao.Keys.Count | Should BeGreaterThan 5
    }
}

Describe 'Get-SituacaoSuporte (fim de suporte por edição e build)' {
    It 'Windows 11 Enterprise 22631 termina em 10/11/2026' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 11 Enterprise' -Build 22631 | Should Match '10/11/2026'
    }
    It 'Windows 11 Pro 22631 termina em 11/11/2025' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 11 Pro' -Build 22631 | Should Match '11/11/2025'
    }
    It 'Windows 10 Enterprise LTSC 2021 19044 termina em 12/01/2027' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 10 Enterprise LTSC 2021' -Build 19044 | Should Match '12/01/2027'
    }
    It 'Windows 10 IoT Enterprise LTSC 2021 19044 termina em 13/01/2032' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 10 IoT Enterprise LTSC 2021' -Build 19044 | Should Match '13/01/2032'
    }
    It 'builds 26300 e 28000 em Pro não caem em build não mapeado' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 11 Pro' -Build 26300 | Should Not Match 'não mapeado'
        Get-SituacaoSuporte -Caption 'Microsoft Windows 11 Pro' -Build 28000 | Should Not Match 'não mapeado'
    }
    It 'build desconhecido continua pedindo verificação' {
        Get-SituacaoSuporte -Caption 'Microsoft Windows 11 Pro' -Build 12345 | Should Match 'não mapeado'
    }
}

Describe 'Get-NomeNetBios (preenchimento dos IPs locais)' {
    It 'testa lista vazia com -not e não com $null -eq' {
        $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-NomeNetBios' }, $true) | Select-Object -First 1
        $f.Extent.Text.Contains('-not $script:IpsLocais') | Should Be $true
        $f.Extent.Text.Contains('$null -eq $script:IpsLocais') | Should Be $false
    }
    It 'com IpsLocais vazio, o IP da própria máquina devolve o nome da máquina' {
        $anterior = $script:IpsLocais
        try {
            $script:IpsLocais = @()
            $ip = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object { $_.IPAddressToString }) | Select-Object -First 1
            "$ip" | Should Not Be ''
            Get-NomeNetBios -Ip $ip -TimeoutMs 200 | Should Be $env:COMPUTERNAME.ToUpper()
            @($script:IpsLocais).Count | Should BeGreaterThan 0
        } finally { $script:IpsLocais = $anterior }
    }
}

Describe 'Expressões de antivírus' {
    $linhas = $script:TextoV2 -split "`r?`n"
    $linhaServicos = $linhas | Where-Object { $_.Contains('$avServicos = @(') } | Select-Object -First 1
    $linhaRegex = $linhas | Where-Object { $_.Contains('$regexAv = ') } | Select-Object -First 1
    $fontes = @{}
    if ($linhaServicos -and $linhaServicos -match "-match\s+'([^']+)'") { $fontes['avServicos'] = $Matches[1] }
    if ($linhaRegex -and $linhaRegex -match "\`$regexAv = '([^']+)'") { $fontes['regexAv'] = $Matches[1] }

    It 'encontra as duas expressões no v2' {
        $fontes.ContainsKey('avServicos') | Should Be $true
        $fontes.ContainsKey('regexAv') | Should Be $true
    }
    foreach ($fonte in 'avServicos', 'regexAv') {
        It "$fonte não casa Reset nem Acronis Managed Machine Service" {
            [regex]::IsMatch('Reset', $fontes[$fonte]) | Should Be $false
            [regex]::IsMatch('Acronis Managed Machine Service', $fontes[$fonte]) | Should Be $false
        }
        It "$fonte casa ESET Service e Acronis Active Protection Service" {
            [regex]::IsMatch('ESET Service', $fontes[$fonte]) | Should Be $true
            [regex]::IsMatch('Acronis Active Protection Service', $fontes[$fonte]) | Should Be $true
        }
    }
}

Describe 'Firewall: Get-NetFirewallProfile' {
    It 'só aparece com -PolicyStore ActiveStore' {
        $chamadas = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-NetFirewallProfile' }, $true))
        $chamadas.Count | Should BeGreaterThan 0
        foreach ($c in $chamadas) { $c.Extent.Text | Should Match '-PolicyStore\s+ActiveStore' }
    }
}

Describe 'Stop-TrabalhosVencidos (abandona consulta de estação que travou)' {
    It 'antes do prazo não mexe; depois do prazo abandona, marca Lido e registra o status' {
        $pool = [runspacefactory]::CreateRunspacePool(1, 2)
        $pool.Open()
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript('Start-Sleep -Seconds 60')
        $handle = $ps.BeginInvoke()
        try {
            $trabalhos = @([pscustomobject]@{ Nome = 'PC01'; PS = $ps; Handle = $handle; Lido = $false })
            $resultados = @{}
            $relogio = [System.Diagnostics.Stopwatch]::StartNew()
            $antes = Stop-TrabalhosVencidos $trabalhos $resultados (Get-Date) 30
            $antes | Should Be 0
            $trabalhos[0].Lido | Should Be $false
            $resultados.Count | Should Be 0
            $depois = Stop-TrabalhosVencidos $trabalhos $resultados ((Get-Date).AddSeconds(-40)) 30
            $relogio.Stop()
            $depois | Should Be 1
            $trabalhos[0].Lido | Should Be $true
            $resultados['PC01'].Status | Should Match 'Sem resposta em'
            ($relogio.Elapsed.TotalSeconds -lt 5) | Should Be $true
        } finally {
            [void]$pool.BeginClose($null, $null)
        }
    }
    It 'ignora trabalho já lido' {
        $trabalhos = @([pscustomobject]@{ Nome = 'PC02'; PS = $null; Handle = $null; Lido = $true })
        $resultados = @{}
        Stop-TrabalhosVencidos $trabalhos $resultados ((Get-Date).AddSeconds(-40)) 30 | Should Be 0
        $resultados.Count | Should Be 0
    }
}

Describe 'Get-MembrosAdministradores (SID órfão no grupo)' {
    It 'não lança e lê por CIM quando Get-LocalGroupMember falha' {
        Mock Get-LocalGroupMember { throw 'SID órfão' }
        Mock Get-CimInstance { New-CimInstance -ClassName Win32_Group -ClientOnly -Property @{ Name = 'Administrators'; SID = 'S-1-5-32-544' } }
        Mock Get-CimAssociatedInstance { [pscustomobject]@{ Domain = 'DOM'; Name = 'fulano'; CimClass = [pscustomobject]@{ CimClassName = 'Win32_UserAccount' } } }
        $r = @(Get-MembrosAdministradores)
        $r.Count | Should Be 1
        $r[0].Name | Should Be 'DOM\fulano'
        $r[0].ObjectClass | Should Be 'UserAccount'
    }
    It 'sem erro, devolve o que Get-LocalGroupMember trouxe' {
        Mock Get-LocalGroupMember { [pscustomobject]@{ Name = 'PC\Administrador'; ObjectClass = 'Usuário'; PrincipalSource = 'Local'; Extra = 'x' } }
        $r = @(Get-MembrosAdministradores)
        $r.Count | Should Be 1
        $r[0].Name | Should Be 'PC\Administrador'
        $r[0].PrincipalSource | Should Be 'Local'
    }
}

Describe 'Format-SituacaoTpm' {
    It 'nulo vira Não identificado' {
        Format-SituacaoTpm $null | Should Be 'Não identificado'
    }
    It 'objeto com TpmPresent e TpmReady vira texto' {
        Format-SituacaoTpm ([pscustomobject]@{ TpmPresent = $true; TpmReady = $false }) | Should Be 'Presente: True | Pronto: False'
    }
}

Describe 'Test-ServicoBackupReal' {
    foreach ($nome in 'SDRSVC', 'wbengine', 'fhsvc', 'VSS', 'swprv', 'CloudBackupRestoreSvc_ab12') {
        It "serviço do Windows $nome não conta como backup" {
            Test-ServicoBackupReal ([pscustomobject]@{ Name = $nome }) | Should Be $false
        }
    }
    It 'VeeamBackupSvc conta como backup' {
        Test-ServicoBackupReal ([pscustomobject]@{ Name = 'VeeamBackupSvc' }) | Should Be $true
    }
}

Describe 'ConvertTo-NumeroOuNulo' {
    It "'16.5' vira 16.5" { ConvertTo-NumeroOuNulo '16.5' | Should Be 16.5 }
    It '16 vira 16' { ConvertTo-NumeroOuNulo 16 | Should Be 16 }
    It "texto com marcação vira nulo" { ($null -eq (ConvertTo-NumeroOuNulo '<script>')) | Should Be $true }
    It '$null vira nulo' { ($null -eq (ConvertTo-NumeroOuNulo $null)) | Should Be $true }
    It '$true vira nulo' { ($null -eq (ConvertTo-NumeroOuNulo $true)) | Should Be $true }
}

Describe 'New-ComputadoresHtml (dados da estação não são confiáveis)' {
    It 'não lança e escapa campos numéricos com marcação' {
        $estacao = [pscustomobject]@{
            Computador = 'PC01.dom.local'; Status = 'OK'; SO = 'Windows 11 Pro'; Suporte = 'Suportado até 11/11/2028'
            Fabricante = 'Dell'; Modelo = 'Optiplex'; NumeroSerie = 'ABC123'; MemoriaGB = '<b>x</b>'; TipoDisco = 'SSD'
            LivreCPct = '<i>y</i>'; Antivirus = 'N/D'; DefenderTempoReal = $true; BitLocker = 'C: protegido'
            DiasSemPatch = 'abc'; AdministradoresLocais = 'DOM\fulano; N/D'; UsuarioLogado = 'DOM\ciclano'
        }
        $html = $null
        { $script:html = New-ComputadoresHtml @($estacao) } | Should Not Throw
        $script:html | Should Not Match '<b>x</b>'
        $script:html | Should Not Match '<i>y</i>'
        $script:html | Should Match 'PC01'
    }
}

Describe 'Base de fabricantes embutida' {
    It 'o v2 não usa base64, GZipStream nem OuiEmbutidoGz' {
        $script:TextoV2.Contains('FromBase64String') | Should Be $false
        $script:TextoV2.Contains('GZipStream') | Should Be $false
        $script:TextoV2.Contains('OuiEmbutidoGz') | Should Be $false
    }
    It 'OuiEmbutido é um here-string em texto com pelo menos 10000 linhas com |' {
        $a = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:OuiEmbutido' }, $true) | Select-Object -First 1
        $a | Should Not BeNullOrEmpty
        $texto = $a.Right.Expression.Value
        $texto | Should Not BeNullOrEmpty
        $quantidade = @($texto -split "`r?`n" | Where-Object { $_.Contains('|') }).Count
        $quantidade | Should BeGreaterThan 9999
    }
}

Describe 'Comandos externos e consultas web atrás de switch' {
    It 'o param tem os switches ComandosExternos e ConsultasWeb' {
        $parametros = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($parametros -contains 'ComandosExternos') | Should Be $true
        ($parametros -contains 'ConsultasWeb') | Should Be $true
        foreach ($p in $ast.ParamBlock.Parameters) {
            if ($p.Name.VariablePath.UserPath -in 'ComandosExternos', 'ConsultasWeb') { $p.StaticType.Name | Should Be 'SwitchParameter' }
        }
    }
    It 'Get-CompartilhamentosRemotos só é chamada com ComandosExternos' {
        $chamadas = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CompartilhamentosRemotos' }, $true))
        $chamadas.Count | Should BeGreaterThan 0
        foreach ($c in $chamadas) { (Test-AtrasDeSwitch $c '$ComandosExternos') | Should Be $true }
    }
    It 'net accounts só roda com ComandosExternos' {
        $achados = Find-TextoNoAst 'net accounts'
        $achados.Count | Should BeGreaterThan 0
        foreach ($c in $achados) { (Test-AtrasDeSwitch $c '$ComandosExternos') | Should Be $true }
    }
    It 'vssadmin só roda com ComandosExternos' {
        $achados = Find-TextoNoAst 'vssadmin'
        $achados.Count | Should BeGreaterThan 0
        foreach ($c in $achados) { (Test-AtrasDeSwitch $c '$ComandosExternos') | Should Be $true }
    }
    foreach ($url in 'api.macvendors.com', 'ipinfo.io', 'standards-oui.ieee.org') {
        It "$url só é consultado com ConsultasWeb" {
            $achados = Find-TextoNoAst ([regex]::Escape($url))
            $achados.Count | Should BeGreaterThan 0
            foreach ($c in $achados) { (Test-AtrasDeSwitch $c '$ConsultasWeb') | Should Be $true }
        }
    }
    It 'o v2 não usa user agent Mozilla/5.0' {
        $script:TextoV2.Contains('Mozilla/5.0') | Should Be $false
    }
}

Describe 'ConvertFrom-TxtCymru' {
    It 'resposta de origem: primeiro campo é o ASN' {
        $r = @(ConvertFrom-TxtCymru '"28573 | 200.0.0.0/24 | BR | lacnic | 2010-01-01"')
        $r[0] | Should Be '28573'
        $r.Count | Should Be 5
    }
    It 'resposta do ASN: quinto campo é o nome da operadora' {
        $r = @(ConvertFrom-TxtCymru '"28573 | BR | lacnic | 2005-01-01 | CLARO S.A., BR"')
        $r[4] | Should Be 'CLARO S.A., BR'
    }
}

Describe 'Instaladores' {
    $instalador = Get-Content -LiteralPath $arquivoInstalador -Raw -Encoding UTF8
    $compartilhamento = Get-Content -LiteralPath $arquivoCompartilhamento -Raw -Encoding UTF8
    It 'Instalar-Assessment-Estacao.ps1 não esconde janela nem usa Bypass' {
        $instalador | Should Not Match '-WindowStyle\s+Hidden'
        $instalador | Should Not Match '-Hidden'
        $instalador | Should Not Match 'Bypass'
    }
    It 'Instalar-Assessment-Estacao.ps1 desbloqueia o coletor e usa RemoteSigned' {
        $instalador | Should Match 'Unblock-File'
        $instalador | Should Match 'RemoteSigned'
    }
    It 'Preparar-Compartilhamento-Assessment.ps1 desbloqueia os arquivos copiados' {
        $compartilhamento | Should Match 'Unblock-File'
    }
}

Describe 'WmiMonitorID' {
    It 'não usa -ErrorAction Stop' {
        $linhasWmi = @(Select-String -Path $arquivo -Pattern 'WmiMonitorID' -Encoding UTF8)
        $linhasWmi.Count | Should BeGreaterThan 0
        foreach ($l in $linhasWmi) { $l.Line | Should Not Match 'ErrorAction\s+Stop' }
    }
}

Describe 'Get-ResumoOfficeClickToRun' {
    It 'nulo devolve nulo' {
        ($null -eq (Get-ResumoOfficeClickToRun $null)) | Should Be $true
    }
    It 'sem ProductReleaseIds devolve nulo' {
        ($null -eq (Get-ResumoOfficeClickToRun ([pscustomobject]@{ VersionToReport = '16.0.1' }))) | Should Be $true
    }
    It 'com ProductReleaseIds devolve o produto e a versão' {
        $r = Get-ResumoOfficeClickToRun ([pscustomobject]@{ ProductReleaseIds = 'O365ProPlusRetail'; VersionToReport = '16.0.1' })
        $r | Should Match 'O365ProPlusRetail'
        $r | Should Match '16\.0\.1'
    }
}

Describe 'Add-DetalhesEstacao e Get-ListaEstacao (JSON da estação não é confiável)' {
    It 'lista conhecida entra com o Computador autoritativo, mesmo que o JSON traga outro' {
        $script:DetalhesEstacoes = @{}
        $json = '{"Certificados":[{"Computador":"OUTRO","Titular":"Fulano","DiasRestantes":40}]}' | ConvertFrom-Json
        Add-DetalhesEstacao $json 'PC01'
        $linhas = @(Get-ListaEstacao 'Certificados')
        $linhas.Count | Should Be 1
        $linhas[0].Computador | Should Be 'PC01'
        $linhas[0].Titular | Should Be 'Fulano'
    }
    It 'lista fora da lista branca é ignorada' {
        $script:DetalhesEstacoes = @{}
        $json = '{"..\\..\\evil":[{"Computador":"X","A":1}],"Certificados":[{"Titular":"Fulano"}]}' | ConvertFrom-Json
        Add-DetalhesEstacao $json 'PC01'
        $script:DetalhesEstacoes.ContainsKey('..\..\evil') | Should Be $false
        $script:DetalhesEstacoes.Keys.Count | Should Be 1
        @(Get-ListaEstacao '..\..\evil').Count | Should Be 0
    }
    It 'Detalhes nulo não faz nada' {
        $script:DetalhesEstacoes = @{}
        { Add-DetalhesEstacao $null 'PC01' } | Should Not Throw
        $script:DetalhesEstacoes.Keys.Count | Should Be 0
    }
}

Describe 'Add-AlertasColetaLocal' {
    It 'estação sem AcessoEntrada (sem coletor 2.0) não gera alerta' {
        $e = [pscustomobject]@{ Computador = 'PC01'; Firewall = 'Domain: DESLIGADO'; SMBv1 = 'Ligado' }
        @(Get-AlertasTeste @($e)).Count | Should Be 0
    }
    It 'firewall desligado gera alerta de severidade Média' {
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01' @{ Firewall = 'Domain: DESLIGADO' }))
        $a.Count | Should Be 1
        $a[0].Severidade | Should Be 'Média'
        $a[0].Item | Should Match 'firewall'
    }
    It 'SMBv1 ligado gera alerta de severidade Alta' {
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01' @{ SMBv1 = 'Ligado' }))
        $a.Count | Should Be 1
        $a[0].Severidade | Should Be 'Alta'
        $a[0].Item | Should Match 'SMBv1'
    }
    It 'WinRM e WMI bloqueados geram alerta Info' {
        $acesso = 'WinRM 5985: bloqueada | WMI/RPC 135: bloqueada | SMB 445: N/D | RDP 3389: N/D'
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01' @{ AcessoEntrada = $acesso }))
        $a.Count | Should Be 1
        $a[0].Severidade | Should Be 'Info'
    }
    It 'disco com ATENÇÃO gera alerta Alta' {
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01' @{ SaudeDiscos = 'ATENÇÃO: x' }))
        $a.Count | Should Be 1
        $a[0].Severidade | Should Be 'Alta'
    }
    It 'Office em carência gera alerta Média' {
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01' @{ OfficeAtivacao = 'Em carência (Varejo)' }))
        $a.Count | Should Be 1
        $a[0].Severidade | Should Be 'Média'
        $a[0].Item | Should Match 'Office'
    }
    It 'com 20 máquinas iguais há um único alerta e o detalhe diz e mais 5' {
        $estacoes = @(1..20 | ForEach-Object { New-EstacaoTeste ('PC{0:00}' -f $_) @{ SMBv1 = 'Ligado' } })
        $a = @(Get-AlertasTeste $estacoes)
        $a.Count | Should Be 1
        $a[0].Item | Should Match '\(20\)'
        $a[0].Detalhe | Should Match 'e mais 5'
    }
    It 'DiasRestantes nulo não gera alerta de certificado vencido' {
        $cert = [pscustomobject]@{ Computador = 'PC01'; DiasRestantes = $null }
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01') @{ Certificados = @($cert) })
        @($a | Where-Object { $_.Item -match 'certificado' }).Count | Should Be 0
    }
    It 'DiasRestantes não numérico não gera alerta de certificado vencido' {
        $cert = [pscustomobject]@{ Computador = 'PC01'; DiasRestantes = 'abc' }
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01') @{ Certificados = @($cert) })
        @($a | Where-Object { $_.Item -match 'vencido' }).Count | Should Be 0
    }
    It 'DiasRestantes negativo gera alerta de certificado vencido' {
        $cert = [pscustomobject]@{ Computador = 'PC01'; DiasRestantes = -5 }
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01') @{ Certificados = @($cert) })
        $v = @($a | Where-Object { $_.Item -match 'vencido' })
        $v.Count | Should Be 1
        $v[0].Severidade | Should Be 'Média'
    }
    It 'DiasRestantes até 30 gera alerta de vencimento próximo e acima de 30 não gera' {
        $c1 = [pscustomobject]@{ Computador = 'PC01'; DiasRestantes = 10 }
        $c2 = [pscustomobject]@{ Computador = 'PC02'; DiasRestantes = 40 }
        $a = @(Get-AlertasTeste @(New-EstacaoTeste 'PC01') @{ Certificados = @($c1, $c2) })
        $v = @($a | Where-Object { $_.Item -match '30 dias' })
        $v.Count | Should Be 1
        $v[0].Detalhe | Should Match 'PC01'
        $v[0].Detalhe | Should Not Match 'PC02'
    }
}

Describe 'CSV gerado a partir do JSON da estação (fórmulas neutralizadas)' {
    function Invoke-ExportacaoTeste {
        # Caminho real: JSON, Add-DetalhesEstacao, Save-DetalhesEstacoes, arquivo.
        param([string]$Json, [string]$Lista)
        $script:DetalhesEstacoes = @{}
        $script:Arquivos = New-Object System.Collections.Generic.List[object]
        $script:PastaSaida = Join-Path $env:TEMP ('NxtCsv_' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:PastaSaida)
        try {
            Add-DetalhesEstacao ($Json | ConvertFrom-Json) 'PC01'
            Save-DetalhesEstacoes
            @(Import-Csv -LiteralPath (Join-Path $script:PastaSaida "$($script:ListasEstacao[$Lista][0]).csv") -Delimiter ';')
        } finally { Remove-Item -LiteralPath $script:PastaSaida -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'valor iniciado por = sai como texto' {
        $l = Invoke-ExportacaoTeste '{"Certificados":[{"Titular":"=1+1"}]}' 'Certificados'
        $l[0].Titular | Should Be "'=1+1"
        $l[0].Computador | Should Be 'PC01'
    }
    It 'cobre + - @, tabulação e espaço antes do sinal' {
        $l = Invoke-ExportacaoTeste '{"Impressoras":[{"A":"+1+1","B":"-2+3","C":"@SUM(A1)","D":"\t=1+1","E":"  =1+1"}]}' 'Impressoras'
        $l[0].A | Should Be "'+1+1"
        $l[0].B | Should Be "'-2+3"
        $l[0].C | Should Be "'@SUM(A1)"
        $l[0].D | Should Be "'`t=1+1"
        $l[0].E | Should Be "'  =1+1"
    }
    It 'nome de coluna vindo do JSON também é neutralizado' {
        $l = Invoke-ExportacaoTeste '{"Impressoras":[{"=HYPERLINK(1)":"x"}]}' 'Impressoras'
        $l[0].PSObject.Properties.Name -contains "'=HYPERLINK(1)" | Should Be $true
        $l[0].PSObject.Properties.Name -contains '=HYPERLINK(1)' | Should Be $false
    }
    It 'objeto aninhado, que o CSV escreveria como @{...}, sai como texto' {
        $l = Invoke-ExportacaoTeste '{"Impressoras":[{"Nome":{"a":"b"}}]}' 'Impressoras'
        $l[0].Nome | Should Be "'@{a=b}"
    }
    It 'valor comum, número negativo e traço ficam como estão' {
        $l = Invoke-ExportacaoTeste '{"Impressoras":[{"Nome":"HP 1020","Saldo":-5,"Texto":"-5,5","Vazio":"-","Mail":"a@b.com"}]}' 'Impressoras'
        $l[0].Nome | Should Be 'HP 1020'
        $l[0].Saldo | Should Be '-5'
        $l[0].Texto | Should Be '-5,5'
        $l[0].Vazio | Should Be '-'
        $l[0].Mail | Should Be 'a@b.com'
    }
    It 'Save-Dados protege também os demais CSVs, como o inventário' {
        $script:Arquivos = New-Object System.Collections.Generic.List[object]
        $script:PastaSaida = Join-Path $env:TEMP ('NxtCsv_' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:PastaSaida)
        try {
            Save-Dados 'inventario_computadores' @([pscustomobject]@{ Computador = 'PC01'; OfficeConta = '=1+1' }) 'teste'
            $l = @(Import-Csv -LiteralPath (Join-Path $script:PastaSaida 'inventario_computadores.csv') -Delimiter ';')
            $l[0].OfficeConta | Should Be "'=1+1"
            $script:Arquivos[0].Registros | Should Be 1
        } finally { Remove-Item -LiteralPath $script:PastaSaida -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'linha sem nada perigoso passa intacta' {
        $o = [pscustomobject]@{ A = 'x'; B = 1 }
        [object]::ReferenceEquals((ConvertTo-LinhaCsvSegura $o), $o) | Should Be $true
    }
}
