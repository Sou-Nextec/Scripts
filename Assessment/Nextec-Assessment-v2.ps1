#Requires -Version 5.1
<#
.SYNOPSIS
    Levantamento completo e somente leitura do ambiente de TI para o assessment da Nextec.

.DESCRIPTION
    Executar no servidor principal do cliente (de preferência o controlador de domínio), em PowerShell
    aberto como administrador, com usuário administrador do domínio.

    O script NÃO altera nenhuma configuração. Ele coleta:
      - Servidor local: hardware, service tag, discos, RAID, volumes, rede, papéis, serviços, softwares,
        atualizações, tarefas agendadas, compartilhamentos e permissões, portas em escuta, firewall,
        antivírus, segurança (SMB1, RDP, BitLocker, Secure Boot), SQL Server e bancos, backup, certificados,
        impressoras, Hyper-V, licenciamento, eventos críticos e sincronização de horário.
      - Active Directory: domínio, DCs, FSMO, usuários, inativos, grupos privilegiados, computadores,
        política de senha, GPOs e vínculos, DNS, DHCP, DFS, dcdiag.
      - Rede: varredura das sub-redes (ping + ARP), portas abertas, identificação por título web e tipo
        provável de cada dispositivo.
      - Estações do domínio: fabricante, modelo, número de série, SO e situação de suporte, CPU, memória,
        disco, antivírus e usuário logado (via WinRM ou DCOM).

    Modo sem intervenção (-Automatico, usado pelo Executar-Assessment.cmd): não faz nenhuma pergunta.
    Exige PowerShell aberto como administrador (não se eleva sozinho), assume o nome do cliente pelo domínio, valida o ambiente
    antes de coletar e, só se a conta atual for negada nas estações, abre UMA janela de login e senha do domínio.
    Essa credencial vale apenas para esta execução, não é gravada e é descartada ao terminar.

    Saída: em C:\Temp (mude com -Saida), um .zip com CSVs (separador ';', UTF-8), textos, resumo.json e Resumo-Assessment.html. A pasta de trabalho é removida depois que o .zip é gerado.
    A varredura de rede abre conexões TCP nas portas listadas; se houver IPS/antivírus de rede, avise o cliente.

    Por padrão o script não abre net.exe nem vssadmin e não acessa API web, para não acionar bloqueio por comportamento:
      -ComandosExternos  liga net view (compartilhamentos dos equipamentos da rede), net accounts e vssadmin.
      -ConsultasWeb      liga ipinfo.io (cidade do IP público), api.macvendors.com e o download da base IEEE.

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -Automatico

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -SoValidar

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -Cliente "Cartorio Maria Jose Rabelo Costa"

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -Cliente "CMJRC" -Subredes 192.168.0.0/24,192.168.10.0/24

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -Cliente "CMJRC" -SemVarreduraRede -SemInventarioRemoto
#>
[CmdletBinding()]
param(
    [string]$Cliente = 'Cliente',
    [string[]]$Subredes,
    [string]$Saida = 'C:\Temp',
    [int[]]$Portas = @(21, 22, 23, 25, 53, 80, 88, 110, 111, 135, 139, 143, 389, 443, 445, 465, 515, 554, 587,
                       631, 636, 993, 995, 1433, 1521, 1723, 2049, 3050, 3268, 3269, 3306, 3389, 4899, 5000,
                       5001, 5060, 5357, 5432, 5900, 5938, 5985, 5986, 6000, 7070, 8000, 8006, 8080, 8081,
                       8089, 8181, 8291, 8443, 8888, 9000, 9090, 9100, 9200, 10000, 27017, 32400, 34567,
                       37777, 49152, 623, 902, 5989),
    [ValidateRange(100, 5000)][int]$TimeoutPingMs = 800,
    [ValidateRange(100, 5000)][int]$TimeoutPortaMs = 700,
    [ValidateRange(1, 3650)][int]$DiasInatividade = 90,
    [ValidateRange(1, 90)][int]$DiasEventos = 7,
    [switch]$SemVarreduraRede,
    [switch]$SemInventarioRemoto,
    [switch]$SemAD,
    [switch]$SemConsultaInternet,
    [switch]$ComandosExternos,
    [switch]$ConsultasWeb,
    [switch]$PortasCompletas,
    [switch]$IncluirRedesVirtuais,
    [switch]$SoftwareEstacoes,
    [string]$PastaEstacoes,
    [ValidateRange(1, 90)][int]$DiasValidadeColetaLocal = 7,
    [string]$DominioEmail,
    [switch]$Agressivo,
    [ValidateRange(1, 32)][int]$Paralelismo = 8,
    [pscredential]$Credencial,
    [switch]$PedirCredencial,
    [switch]$Automatico,
    [switch]$SoValidar,
    [switch]$SemValidacao
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Executado por duplo clique (.cmd) ou "Executar com o PowerShell", a janela fecha sozinha em erro fatal
# e o técnico não vê o motivo. Com teclado, segura a janela; em automação, só encerra.
trap {
    Write-Host ''
    Write-Host "ERRO FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Linha $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim())" -ForegroundColor DarkRed
    try { if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { Read-Host 'Pressione Enter para fechar' | Out-Null } } catch { }
    break
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# ============================================================================
# Estado e utilitários
# ============================================================================

$script:Inicio      = Get-Date
$script:Resumo      = [ordered]@{}
$script:Alertas     = New-Object System.Collections.Generic.List[object]
$script:Erros       = New-Object System.Collections.Generic.List[object]
$script:Arquivos    = New-Object System.Collections.Generic.List[object]
$script:Hosts       = @()
$script:Estacoes    = @()
$script:ComputadoresAD = @()
$script:SoftwareLocal  = @()
$script:ServicosLocal  = @()
$script:CompartilhamentosRede = @()
$script:IpsLocais = @()
$script:IpsLocaisVirtuais = @()
$script:PapelMaquina = 'Não identificado'
$script:EhServidor = $false
$script:ServidorDhcp = ''
$script:Tls = @()
$script:Certificados = @()
$script:DominioEmailAD = ''
$script:UpnSuffixesForest = @()
$script:SoftwaresEstacoes = New-Object System.Collections.Generic.List[object]
$script:DetalhesEstacoes = @{}
$script:CredencialRemota = $null
$script:DiscosSemSmart = @()

# Ritmo da varredura. O padrão é suave de propósito: rajada grande de conexões TCP esgota a tabela
# de estado de roteador SOHO e derruba o DNS do cliente no meio do expediente. -Agressivo só em
# ambiente onde o equipamento de borda aguenta e você pode assumir o risco.
$script:LotePing    = if ($Agressivo) { 128 } else { 48 }
$script:LotePortas  = if ($Agressivo) { 256 } else { 48 }
$script:PausaLoteMs = if ($Agressivo) { 0 } else { 300 }

# ============================================================================
# Execução sem parâmetros: pergunta o que não dá para descobrir sozinho.
# Se não houver console (agendador, chamada automatizada), segue com os padrões.
# ============================================================================

function Test-TemTeclado {
    # UserInteractive sozinho não basta: em agendador e automação a entrada vem redirecionada
    # e o Read-Host trava esperando algo que nunca chega.
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    $true
}

function Read-Preenchimento {
    param([string]$Pergunta, [string]$Padrao = '')
    if (-not (Test-TemTeclado)) { return $Padrao }
    $sufixo = if ($Padrao) { " [$Padrao]" } else { '' }
    try { $resposta = Read-Host "$Pergunta$sufixo" } catch { return $Padrao }
    if ([string]::IsNullOrWhiteSpace($resposta)) { $Padrao } else { $resposta.Trim() }
}

if (-not $PSBoundParameters.ContainsKey('Cliente') -and ((Test-TemTeclado) -or $Automatico)) {
    $sugestao = try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain -and $cs.Domain) { ($cs.Domain -split '\.')[0] } else { $env:COMPUTERNAME }
    } catch { $env:COMPUTERNAME }
    if ($Automatico) {
        $Cliente = $sugestao
    } else {
        Write-Host ''
        Write-Host '  Assessment Nextec' -ForegroundColor Cyan
        Write-Host '  Enter aceita o valor entre colchetes.' -ForegroundColor DarkGray
        Write-Host ''
        $Cliente = Read-Preenchimento 'Nome do cliente' $sugestao
    }
}

if (-not $PSBoundParameters.ContainsKey('DominioEmail')) {
    # Descobre sozinho o domínio público, sem perguntar nada. Ordem: domínio da máquina,
    # sufixo DNS primário, sufixos de busca. Descarta nomes internos (.local, .lan e afins).
    $ehPublico = { param($d) $d -and $d -match '^[a-z0-9.-]+\.[a-z]{2,}$' -and $d -notmatch '(?i)\.(local|lan|internal|corp|home|intranet|test|localdomain)$' }
    $candidatos = New-Object System.Collections.Generic.List[string]
    try { $candidatos.Add((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Domain) } catch { }
    try { $candidatos.Add((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'Domain' -ErrorAction Stop).Domain) } catch { }
    try { foreach ($s in (Get-DnsClientGlobalSetting -ErrorAction Stop).SuffixSearchList) { $candidatos.Add($s) } } catch { }
    try { foreach ($s in (Get-DnsClient -ErrorAction Stop | Where-Object { $_.ConnectionSpecificSuffix }).ConnectionSpecificSuffix) { $candidatos.Add($s) } } catch { }
    $DominioEmail = @($candidatos | Where-Object { & $ehPublico $_ } | Select-Object -Unique -First 1)
}

$nomeClienteArquivo = ($Cliente -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
if (-not $nomeClienteArquivo) { $nomeClienteArquivo = 'Cliente' }
$script:PastaSaida  = Join-Path $Saida ('{0}_{1}_{2}' -f $nomeClienteArquivo, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
New-Item -Path $script:PastaSaida -ItemType Directory -Force | Out-Null
$script:ArquivoLog  = Join-Path $script:PastaSaida 'coleta.log'

$RotuloPortas = @{
    21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 25 = 'SMTP'; 53 = 'DNS'; 80 = 'HTTP'; 88 = 'Kerberos'; 110 = 'POP3';
    111 = 'RPCbind/NFS'; 135 = 'RPC'; 139 = 'NetBIOS'; 143 = 'IMAP'; 389 = 'LDAP'; 443 = 'HTTPS'; 445 = 'SMB';
    465 = 'SMTPS'; 515 = 'LPD'; 554 = 'RTSP'; 587 = 'SMTP-envio'; 631 = 'IPP'; 636 = 'LDAPS'; 993 = 'IMAPS';
    995 = 'POP3S'; 1433 = 'SQL Server'; 1521 = 'Oracle'; 1723 = 'VPN PPTP'; 2049 = 'NFS'; 3050 = 'Firebird';
    3268 = 'AD Catálogo Global'; 3269 = 'AD Catálogo Global SSL'; 3306 = 'MySQL'; 3389 = 'RDP'; 4899 = 'Radmin';
    5000 = 'HTTP-5000'; 5001 = 'HTTPS-5001'; 5060 = 'SIP/VoIP'; 5357 = 'WSD'; 5432 = 'PostgreSQL'; 5900 = 'VNC';
    5938 = 'TeamViewer'; 5985 = 'WinRM'; 5986 = 'WinRM-HTTPS'; 6000 = 'X11'; 7070 = 'AnyDesk'; 8000 = 'HTTP-8000/DVR';
    8006 = 'Proxmox'; 8080 = 'HTTP-alt'; 8081 = 'HTTP-8081'; 8089 = 'HTTP-8089'; 8181 = 'HTTP-8181';
    8291 = 'MikroTik Winbox'; 8443 = 'HTTPS-alt'; 8888 = 'HTTP-8888'; 9000 = 'HTTP-9000'; 9090 = 'HTTP-9090/Cockpit';
    9100 = 'Impressão RAW'; 9200 = 'Elasticsearch'; 10000 = 'Webmin'; 27017 = 'MongoDB'; 32400 = 'Plex';
    34567 = 'DVR XMEye'; 37777 = 'DVR Dahua/Intelbras'; 49152 = 'RPC dinâmico'
    623 = 'IPMI/BMC'; 902 = 'VMware ESXi'; 5989 = 'CIM/WBEM'
}

# Portas onde faz sentido negociar TLS para conferir versão do protocolo e validade do certificado.
$script:PortasTls = @(443, 465, 636, 993, 995, 5001, 8006, 8443, 9090, 5989)

# Agrupamento das portas por finalidade, para o relatório ficar legível em vez de uma lista solta de números.
$script:GrupoPortas = [ordered]@{
    'Web / Administração' = @(80, 443, 5000, 5001, 8000, 8006, 8080, 8081, 8089, 8181, 8443, 8888, 9000, 9090, 10000, 32400)
    'Acesso remoto'       = @(22, 23, 3389, 4899, 5900, 5938, 5985, 5986, 7070)
    'Arquivos / Impressão'= @(21, 139, 445, 515, 631, 2049, 9100)
    'Banco de dados'      = @(1433, 1521, 3050, 3306, 5432, 9200, 27017)
    'E-mail'              = @(25, 110, 143, 465, 587, 993, 995)
    'Rede / Diretório'    = @(53, 88, 111, 135, 389, 636, 3268, 3269, 5357, 49152)
    'Câmeras / Mídia'     = @(554, 34567, 37777)
    'Telefonia'           = @(5060)
}
$script:CorGrupoPorta = @{
    'Web / Administração' = '#0277bd'; 'Acesso remoto' = '#ef8c00'; 'Arquivos / Impressão' = '#00897b'
    'Banco de dados' = '#6a1b9a'; 'E-mail' = '#8d6e63'; 'Rede / Diretório' = '#5C50FF'
    'Câmeras / Mídia' = '#c62828'; 'Telefonia' = '#00838f'; 'Outros' = '#607d8b'
}

function Get-GrupoPorta {
    param([int]$Porta)
    foreach ($g in $script:GrupoPortas.Keys) { if ($script:GrupoPortas[$g] -contains $Porta) { return $g } }
    'Outros'
}

function Get-UrlPorta {
    # Link clicável para abrir o serviço que responde naquela porta. Só monta o endereço; não acessa nada.
    param([string]$Ip, [int]$Porta)
    switch ($Porta) {
        { $_ -in 443, 5001, 8006, 8443, 9090 } { return "https://${Ip}:$Porta/" }
        { $_ -in 80, 5000, 8000, 8080, 8081, 8089, 8181, 8888, 9000, 10000, 32400 } { return "http://${Ip}:$Porta/" }
        21    { return "ftp://$Ip/" }
        22    { return "ssh://$Ip" }
        23    { return "telnet://$Ip" }
        445   { return "file://$Ip/" }
        139   { return "file://$Ip/" }
        5900  { return "vnc://$Ip" }
        3389  { return "rdp://$Ip" }
        default { return '' }
    }
}

# ---------- Apresentação no console ----------
# O arquivo coleta.log guarda tudo com hora e nível; a tela mostra só o necessário, organizado por seção e etapa.
$script:VersaoAssessment = '2.11'

# Toda consulta WMI/CIM tem prazo: com o WMI corrompido ou um provedor travado, a etapa falha e a coleta segue.
# Vale para as consultas locais e para as feitas pelas sessões CIM das estações. Quem precisa de mais tempo informa o próprio.
$script:TimeoutWmiSeg = 60
$PSDefaultParameterValues['Get-CimInstance:OperationTimeoutSec'] = $script:TimeoutWmiSeg
$script:LarguraTela = 64
$script:EtapaAberta = $null
$script:NumeroSecao = 0
$script:TotalSecoes = 7

function Close-LinhaEtapa {
    # Fecha a linha da etapa em andamento antes de escrever qualquer outra coisa na tela.
    if ($script:EtapaAberta) { Write-Host ''; $script:EtapaAberta = $null }
}

function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel = 'INFO', [switch]$SoArquivo)
    $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Nivel, $Mensagem
    if ($script:ArquivoLog) { Add-Content -Path $script:ArquivoLog -Value $linha -Encoding UTF8 }
    if ($SoArquivo) { return }
    Close-LinhaEtapa
    $texto = $Mensagem.TrimStart()
    $recuo = ' ' * (6 + ($Mensagem.Length - $texto.Length))
    switch ($Nivel) {
        'AVISO' { Write-Host "$recuo! $texto" -ForegroundColor Yellow }
        'ERRO'  { Write-Host "${recuo}x $texto" -ForegroundColor Red }
        default { Write-Host "$recuo$texto" -ForegroundColor DarkGray }
    }
}

function Format-Duracao {
    param([TimeSpan]$Tempo)
    if ($Tempo.TotalMinutes -ge 1) { return '{0} min {1:00} s' -f [math]::Floor($Tempo.TotalMinutes), $Tempo.Seconds }
    '{0:N1} s' -f $Tempo.TotalSeconds
}

function Write-Cabecalho {
    $l = $script:LarguraTela
    $titulo = '  NEXTEC  |  Assessment de TI'
    $versao = "v$script:VersaoAssessment  "
    Write-Host ''
    Write-Host ('  ┌' + ('─' * $l) + '┐') -ForegroundColor Cyan
    Write-Host '  │' -NoNewline -ForegroundColor Cyan
    Write-Host $titulo -NoNewline -ForegroundColor White
    Write-Host (' ' * ($l - $titulo.Length - $versao.Length)) -NoNewline
    Write-Host $versao -NoNewline -ForegroundColor DarkGray
    Write-Host '│' -ForegroundColor Cyan
    Write-Host ('  └' + ('─' * $l) + '┘') -ForegroundColor Cyan
    foreach ($campo in @(
            @('Cliente', $Cliente),
            @('Máquina', $env:COMPUTERNAME),
            @('Conta', "$env:USERDOMAIN\$env:USERNAME"),
            @('Saída', $Saida),
            @('Início', (Get-Date -Format 'dd/MM/yyyy HH:mm')))) {
        Write-Host ('   {0,-10}' -f $campo[0]) -NoNewline -ForegroundColor DarkGray
        Write-Host $campo[1] -ForegroundColor Gray
    }
}

function Write-Secao {
    param([string]$Titulo)
    Close-LinhaEtapa
    $script:NumeroSecao++
    Write-Log "== $Titulo" -SoArquivo
    $rotulo = ' {0}/{1}  {2} ' -f $script:NumeroSecao, $script:TotalSecoes, $Titulo
    Write-Host ''
    Write-Host ('  ──' + $rotulo + ('─' * [math]::Max(4, $script:LarguraTela - $rotulo.Length - 2))) -ForegroundColor Cyan
}

function Write-ItemValidacao {
    param([string]$Item, [string]$Status, [string]$Detalhe)
    Close-LinhaEtapa
    $cor = switch ($Status) { 'OK' { 'Green' } 'FALHA' { 'Red' } default { 'Yellow' } }
    Write-Host ('   {0,-7}' -f $Status) -NoNewline -ForegroundColor $cor
    Write-Host ('{0,-24}' -f $Item) -NoNewline -ForegroundColor Gray
    Write-Host $Detalhe -ForegroundColor $(if ($Status -eq 'OK') { 'DarkGray' } else { $cor })
}

function Add-Alerta {
    param(
        [ValidateSet('Alta', 'Média', 'Baixa', 'Info')][string]$Severidade,
        [string]$Area, [string]$Item, [string]$Detalhe
    )
    $script:Alertas.Add([pscustomobject]@{ Severidade = $Severidade; Area = $Area; Item = $Item; Detalhe = $Detalhe })
}

function Invoke-Etapa {
    # Uma linha por etapa: "Nome ........ ok  1,2 s". Se a etapa escrever detalhes, eles aparecem logo abaixo.
    param([string]$Nome, [scriptblock]$Acao)
    Write-Log "Coletando: $Nome" -SoArquivo
    Close-LinhaEtapa
    Write-Host "   $Nome" -NoNewline -ForegroundColor Gray
    $script:EtapaAberta = $Nome
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    $falhou = $false
    try { & $Acao }
    catch {
        $falhou = $true
        $mensagem = $_.Exception.Message
        $script:Erros.Add([pscustomobject]@{ Etapa = $Nome; Erro = $mensagem })
        Write-Log "Falha em ${Nome}: $mensagem" 'AVISO'
    }
    $tempo = Format-Duracao $relogio.Elapsed
    if ($script:EtapaAberta) {
        Write-Host (' ' + ('.' * [math]::Max(2, 44 - $Nome.Length)) + ' ') -NoNewline -ForegroundColor DarkGray
        Write-Host 'ok' -NoNewline -ForegroundColor Green
        Write-Host "  $tempo" -ForegroundColor DarkGray
        $script:EtapaAberta = $null
    } elseif (-not $falhou) {
        Write-Host "      concluído em $tempo" -ForegroundColor Green
    }
}

function Test-CelulaPerigosa {
    # Excel executa célula que começa com = + - @, inclusive depois de espaço, tabulação ou quebra de linha. Número negativo e traço sozinho não são fórmula.
    param($Valor)
    if ($null -eq $Valor -or $Valor -is [ValueType]) { return $false }
    $texto = "$Valor"
    ($texto -match '^\s*[=+\-@＝＋－＠]') -and ($texto -notmatch '^\s*[-+]?\d+([.,]\d+)*\s*$') -and ($texto -notmatch '^\s*-+\s*$')
}

function ConvertTo-LinhaCsvSegura {
    # O apóstrofo faz a planilha tratar como texto. Nome de coluna também conta: as colunas da estação vêm do JSON dela.
    param($Linha)
    $propriedades = @($Linha.PSObject.Properties)
    $valores = @{}
    $perigosa = $false
    foreach ($p in $propriedades) {
        try { $valores[$p.Name] = $p.Value } catch { $valores[$p.Name] = $null }
        if ((Test-CelulaPerigosa $p.Name) -or (Test-CelulaPerigosa $valores[$p.Name])) { $perigosa = $true }
    }
    if (-not $perigosa) { return $Linha }
    $nova = [ordered]@{}
    foreach ($p in $propriedades) {
        $valor = $valores[$p.Name]
        $nome = if (Test-CelulaPerigosa $p.Name) { "'$($p.Name)" } else { $p.Name }
        $nova[$nome] = if (Test-CelulaPerigosa $valor) { "'$valor" } else { $valor }
    }
    [pscustomobject]$nova
}

function Save-Dados {
    param([string]$Nome, $Dados, [string]$Descricao)
    $lista = @($Dados | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-LinhaCsvSegura $_ })
    if ($lista.Count -gt 0) {
        $lista | Export-Csv -Path (Join-Path $script:PastaSaida "$Nome.csv") -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    $script:Arquivos.Add([pscustomobject]@{ Arquivo = "$Nome.csv"; Registros = $lista.Count; Descricao = $Descricao })
}

function Save-Texto {
    param([string]$Nome, [scriptblock]$Comando, [string]$Descricao)
    $ErrorActionPreference = 'Continue'
    try { $conteudo = (& $Comando 2>&1 | Out-String -Width 250) }
    catch { $conteudo = "Falha ao executar: $($_.Exception.Message)" }
    $conteudo | Out-File -FilePath (Join-Path $script:PastaSaida "$Nome.txt") -Encoding UTF8
    $script:Arquivos.Add([pscustomobject]@{ Arquivo = "$Nome.txt"; Registros = $null; Descricao = $Descricao })
}

function Protect-Texto {
    # Mascara senhas que aparecem em argumentos de tarefas e comandos.
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return $Texto }
    $t = $Texto -replace '(?i)(/p(ass(word)?)?[:=]\s*)("[^"]*"|\S+)', '$1****'
    $t = $t -replace '(?i)(\s-(pass|password|pwd|senha|p)\s+)("[^"]*"|\S+)', '$1****'
    $t -replace '(?i)((password|pwd|senha|passwd)\s*[=:]\s*)("[^"]*"|[^;\s]+)', '$1****'
}

function Test-ComandoExiste { param([string]$Nome) [bool](Get-Command -Name $Nome -ErrorAction SilentlyContinue) }

function ConvertFrom-CharArrayWmi {
    # O WMI devolve textos de monitor como array de códigos de caractere terminado em zero.
    param($Codigos)
    if (-not $Codigos) { return '' }
    (($Codigos | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) -join '').Trim()
}

function Get-ValorRegistro {
    param([string]$Caminho, [string]$Nome)
    try { (Get-ItemProperty -Path $Caminho -Name $Nome -ErrorAction Stop).$Nome } catch { $null }
}

function Format-Data {
    param($Data)
    if ($null -eq $Data -or $Data -eq [datetime]::MinValue) { return '' }
    ([datetime]$Data).ToString('dd/MM/yyyy HH:mm')
}

function Get-SituacaoSuporte {
    # Datas de fim de suporte por edição (LTSC, Enterprise/Education, Home/Pro; estendido para servidores). Conferir em caso de dúvida.
    param([string]$Caption, [int]$Build)
    if (-not $Build) { return 'Verificar' }
    if ($Caption -match 'Server') {
        $mapa = @{ 6002 = '2020-01-14'; 7601 = '2020-01-14'; 9200 = '2023-10-10'; 9600 = '2023-10-10'
                   14393 = '2027-01-12'; 17763 = '2029-01-09'; 20348 = '2031-10-14'; 26100 = '2034-10-10' }
    } elseif ($Caption -match 'LTSC|LTSB') {
        $iot = $Caption -match 'IoT'
        $mapa = @{ 10240 = '2025-10-14'; 14393 = '2026-10-13'; 17763 = '2029-01-09'
                   19044 = $(if ($iot) { '2032-01-13' } else { '2027-01-12' })
                   26100 = $(if ($iot) { '2034-10-10' } else { '2029-10-09' }) }
    } elseif ($Caption -match 'Enterprise|Education|Educa') {
        $mapa = @{ 17763 = '2021-05-11'; 18363 = '2022-05-10'; 19041 = '2021-12-14'; 19042 = '2023-05-09'
                   19043 = '2022-12-13'; 19044 = '2024-06-11'; 19045 = '2025-10-14'; 22000 = '2024-10-08'
                   22621 = '2025-10-14'; 22631 = '2026-11-10'; 26100 = '2027-10-12'; 26200 = '2028-10-10'
                   26300 = '2029-10-09'; 28000 = '2029-03-13' }
    } else {
        $mapa = @{ 7601 = '2020-01-14'; 9600 = '2023-01-10'; 10240 = '2017-05-09'; 17763 = '2020-11-10'
                   18363 = '2022-05-10'; 19041 = '2021-12-14'; 19042 = '2022-05-10'; 19043 = '2022-12-13'
                   19044 = '2023-06-13'; 19045 = '2025-10-14'; 22000 = '2023-10-10'; 22621 = '2024-10-08'
                   22631 = '2025-11-11'; 26100 = '2026-10-13'; 26200 = '2027-10-12'
                   26300 = '2028-10-10'; 28000 = '2028-03-14' }
    }
    if (-not $mapa.ContainsKey($Build)) { return 'Verificar (build não mapeado)' }
    $fim = [datetime]::ParseExact($mapa[$Build], 'yyyy-MM-dd', $null)
    $dias = ($fim - (Get-Date)).Days
    if ($dias -lt 0) { return "Fora de suporte desde $($fim.ToString('dd/MM/yyyy'))" }
    if ($dias -le 180) { return "Suporte até $($fim.ToString('dd/MM/yyyy')) (encerra em $dias dias)" }
    "Suportado até $($fim.ToString('dd/MM/yyyy'))"
}

function Test-ServicoBackupReal {
    # O filtro por "Backup" também casa serviços que vêm com o Windows, e aí o alerta de "nenhum backup" nunca disparava.
    param($Servico)
    $Servico.Name -notmatch '^(SDRSVC|wbengine|fhsvc|VSS|swprv|CloudBackupRestoreSvc(_[0-9a-f]+)?)$'
}

function Format-SituacaoTpm {
    param($Tpm)
    if (-not $Tpm) { return 'Não identificado' }
    "Presente: $($Tpm.TpmPresent) | Pronto: $($Tpm.TpmReady)"
}

function Get-MembrosAdministradores {
    # Get-LocalGroupMember aborta inteiro quando o grupo tem SID órfão (conta de domínio apagada); nesse caso lê por CIM.
    try {
        @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource)
    } catch {
        $grupo = Get-CimInstance Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction Stop
        @(Get-CimAssociatedInstance -InputObject $grupo -Association Win32_GroupUser -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = "$($_.Domain)\$($_.Name)"; ObjectClass = $_.CimClass.CimClassName -replace '^Win32_', ''; PrincipalSource = 'N/D' }
        })
    }
}

function Get-ResumoOfficeClickToRun {
    # Microsoft 365 e Office por conta não aparecem em SoftwareLicensingProduct: sem isto o Office ficava invisível.
    param($Config)
    if (-not $Config -or -not $Config.ProductReleaseIds) { return $null }
    "$($Config.ProductReleaseIds) $($Config.VersionToReport) (Click-to-Run; ativação pela conta ou assinatura, confirmar no portal)"
}

function ConvertTo-NumeroOuNulo {
    # O arquivo da estação vem de uma pasta que qualquer máquina grava: coluna numérica só aceita número.
    param($Valor)
    if ($null -eq $Valor -or $Valor -is [bool]) { return $null }
    $numero = 0.0
    if ([double]::TryParse("$Valor", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numero)) { return $numero }
    $null
}

function ConvertFrom-TxtCymru {
    # Resposta TXT do Team Cymru: campos separados por '|'.
    param([string]$Texto)
    @($Texto.Trim('"', ' ') -split '\s*\|\s*')
}

function Get-IpPublicoDns {
    # IP público e operadora por consulta DNS, sem processo externo nem API web. Não traz a cidade.
    $servidor = @(Resolve-DnsName 'ns1.google.com' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) | Select-Object -First 1
    $ip = @(Resolve-DnsName 'o-o.myaddr.l.google.com' -Server $servidor -Type TXT -DnsOnly -ErrorAction Stop | ForEach-Object { $_.Strings }) |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
    if (-not $ip) { throw 'O DNS não devolveu o IP público' }
    $octetos = $ip -split '\.'
    [array]::Reverse($octetos)
    $origem = ConvertFrom-TxtCymru (@(Resolve-DnsName "$($octetos -join '.').origin.asn.cymru.com" -Type TXT -DnsOnly -ErrorAction Stop | ForEach-Object { $_.Strings }) | Select-Object -First 1)
    $asn = "$($origem[0])".Split(' ')[0]
    $dados = ConvertFrom-TxtCymru (@(Resolve-DnsName "AS$asn.asn.cymru.com" -Type TXT -DnsOnly -ErrorAction Stop | ForEach-Object { $_.Strings }) | Select-Object -First 1)
    [pscustomobject]@{ IP = $ip; Asn = $asn; Operadora = "$($dados[4])" -replace ',\s*[A-Z]{2}$', '' }
}

function Stop-TrabalhosVencidos {
    # Estação que trava depois de conectar segurava a coleta inteira: passado o prazo, abandona e segue.
    param($Trabalhos, $Resultados, [datetime]$Inicio, [int]$PrazoSeg)
    if (((Get-Date) - $Inicio).TotalSeconds -lt $PrazoSeg) { return 0 }
    $abandonados = 0
    foreach ($t in @($Trabalhos | Where-Object { -not $_.Lido })) {
        [void]$t.PS.BeginStop($null, $null)
        $Resultados[$t.Nome] = [pscustomobject]@{ Computador = $t.Nome; Status = "Sem resposta em $PrazoSeg s (consulta abandonada)" }
        $t.Lido = $true
        $abandonados++
    }
    $abandonados
}

# Lista branca: o nome da lista vira nome de arquivo, e o JSON da estação não é confiável.
$script:ListasEstacao = [ordered]@{
    Certificados      = 'estacoes_certificados', 'Certificados ICP-Brasil nas estações'
    ContasLocais      = 'estacoes_contas_locais', 'Contas locais das estações'
    Compartilhamentos = 'estacoes_compartilhamentos', 'Pastas compartilhadas nas estações'
    Tarefas           = 'estacoes_tarefas', 'Tarefas agendadas fora do padrão do Windows'
    Servicos          = 'estacoes_servicos', 'Serviços fora do padrão do Windows'
    Inicializacao     = 'estacoes_inicializacao', 'Programas de inicialização'
    LogonsFalha       = 'estacoes_logons_falha', 'Logons com falha nos últimos 7 dias'
    Rede              = 'estacoes_rede', 'Placas de rede: IP, DNS, MAC e Wi-Fi'
    Impressoras       = 'estacoes_impressoras', 'Impressoras instaladas'
    Scanners          = 'estacoes_scanners', 'Scanners instalados'
    Unidades          = 'estacoes_unidades', 'Unidades mapeadas'
    Discos            = 'estacoes_discos', 'Discos físicos e saúde'
    Eventos           = 'estacoes_eventos', 'Eventos críticos e erros de sistema mais frequentes (30 dias)'
    PastasUsuario     = 'estacoes_dados_locais', 'Volume em Área de Trabalho, Documentos e Downloads'
}

function Add-DetalhesEstacao {
    param($Detalhes, [string]$Computador)
    if (-not $Detalhes) { return }
    foreach ($lista in $script:ListasEstacao.Keys) {
        foreach ($item in @($Detalhes.$lista)) {
            if ($null -eq $item) { continue }
            $linha = [ordered]@{ Computador = $Computador }
            foreach ($prop in $item.PSObject.Properties) { if ($prop.Name -ne 'Computador') { $linha[$prop.Name] = $prop.Value } }
            if (-not $script:DetalhesEstacoes.ContainsKey($lista)) { $script:DetalhesEstacoes[$lista] = New-Object System.Collections.Generic.List[object] }
            $script:DetalhesEstacoes[$lista].Add([pscustomobject]$linha)
        }
    }
}

function Get-ListaEstacao {
    param([string]$Lista)
    if ($script:DetalhesEstacoes.ContainsKey($Lista)) { $script:DetalhesEstacoes[$Lista].ToArray() }
}

function Save-DetalhesEstacoes {
    foreach ($lista in $script:ListasEstacao.Keys) {
        $linhas = @(Get-ListaEstacao $lista)
        if ($linhas.Count -eq 0) { continue }
        $colunas = @($linhas | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        Save-Dados $script:ListasEstacao[$lista][0] @($linhas | Select-Object -Property $colunas) $script:ListasEstacao[$lista][1]
    }
}

function Add-AlertaPorMaquinas {
    # Um alerta por tipo, com os nomes juntos: em parque grande, um por máquina afogaria o relatório.
    param($Maquinas, [string]$Severidade, [string]$Area, [string]$Titulo, [string]$Explicacao)
    $nomes = @($Maquinas | ForEach-Object { $_.Computador } | Select-Object -Unique)
    if ($nomes.Count -eq 0) { return }
    $texto = ($nomes | Select-Object -First 15) -join ', '
    if ($nomes.Count -gt 15) { $texto += " e mais $($nomes.Count - 15)" }
    Add-Alerta $Severidade $Area "$Titulo ($($nomes.Count))" "$Explicacao | $texto"
}

function Add-AlertasColetaLocal {
    param($Estacoes)
    # Só as máquinas com o coletor 2.0 trazem estes campos.
    $doColetor = @($Estacoes | Where-Object { $_.AcessoEntrada })
    if ($doColetor.Count -eq 0) { return }
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.Firewall -match 'DESLIGADO' }) 'Média' 'Segurança' 'Estações com firewall do Windows desligado' 'Religar o perfil e liberar só o necessário.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.SMBv1 -eq 'Ligado' }) 'Alta' 'Segurança' 'Estações com SMBv1 ligado' 'Protocolo obsoleto, explorado por ransomware. Desligar.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.AcessoEntrada -match 'WinRM[^|]*bloqueada' -and $_.AcessoEntrada -match 'WMI[^|]*bloqueada' }) 'Info' 'Estações' 'Estações com WinRM e WMI bloqueados no firewall' 'Explica por que a consulta remota não alcança estas máquinas.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.AdministradorLocal -like 'Habilitada*' -and $_.LAPS -eq 'Não configurado' }) 'Média' 'Segurança' 'Administrador local habilitado sem LAPS' 'A mesma senha pode valer em várias máquinas. Desabilitar a conta ou adotar LAPS.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.LAPS -eq 'Não configurado' }) 'Baixa' 'Segurança' 'Estações sem LAPS' 'Senha do administrador local sem rotação automática.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.ContasSemSenhaObrigatoria }) 'Baixa' 'Segurança' 'Estações com conta local ativa sem senha obrigatória' 'A conta aceita senha em branco, o que não prova que esteja em branco; comum em conta criada na instalação do Windows. Ver estacoes_contas_locais.csv.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.USB -eq 'Liberado' }) 'Baixa' 'Segurança' 'Estações com armazenamento USB liberado' 'Avaliar bloqueio por política.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.BloqueioTela -eq 'Não configurado' }) 'Média' 'Segurança' 'Estações sem bloqueio de tela por inatividade' 'Definir por GPO.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.WindowsAtivacao -and $_.WindowsAtivacao -notin 'Licenciado', 'N/D' }) 'Média' 'Licenciamento' 'Estações com Windows não licenciado' 'Conferir a ativação e o comprovante.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.WindowsCanal -eq 'Volume (KMS)' }) 'Info' 'Licenciamento' 'Estações com Windows ativado por KMS' 'Confirmar se o KMS é legítimo do cliente e não ativador irregular.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.OfficeAtivacao -match 'Não licenciado|Notificação|carência' }) 'Média' 'Licenciamento' 'Estações com Office sem ativação confirmada' 'Conferir a ativação e o comprovante de licença.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.SaudeDiscos -match 'ATENÇÃO' }) 'Alta' 'Estações' 'Estações com disco em risco' 'Fazer backup e programar a troca. Ver estacoes_discos.csv.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.TelasAzuis30d -gt 0 }) 'Média' 'Estações' 'Estações com tela azul nos últimos 30 dias' 'Ver estacoes_eventos.csv.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.DesligamentosInesperados30d -ge 3 }) 'Baixa' 'Estações' 'Estações com desligamentos inesperados recorrentes' 'Três ou mais em 30 dias: verificar energia e hardware.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.LogonsFalha7d -ge 50 }) 'Média' 'Segurança' 'Estações com muitos logons com falha' 'Cinquenta ou mais em 7 dias. Ver estacoes_logons_falha.csv.'
    $certificados = @(Get-ListaEstacao 'Certificados')
    Add-AlertaPorMaquinas @($certificados | Where-Object { $dias = ConvertTo-NumeroOuNulo $_.DiasRestantes; $null -ne $dias -and $dias -lt 0 }) 'Média' 'Certificados' 'Estações com certificado ICP-Brasil vencido' 'Remover ou renovar. Ver estacoes_certificados.csv.'
    Add-AlertaPorMaquinas @($certificados | Where-Object { $dias = ConvertTo-NumeroOuNulo $_.DiasRestantes; $null -ne $dias -and $dias -ge 0 -and $dias -le 30 }) 'Média' 'Certificados' 'Estações com certificado ICP-Brasil vencendo em até 30 dias' 'Programar a renovação. Ver estacoes_certificados.csv.'
    Add-AlertaPorMaquinas @(Get-ListaEstacao 'PastasUsuario' | Where-Object { (ConvertTo-NumeroOuNulo $_.TotalGB) -ge 5 }) 'Média' 'Backup' 'Estações com muitos dados locais' 'Cinco GB ou mais em Área de Trabalho, Documentos e Downloads, possivelmente fora do backup. Ver estacoes_dados_locais.csv.'
    $compartilhamentos = @(Get-ListaEstacao 'Compartilhamentos')
    Add-AlertaPorMaquinas @($compartilhamentos | Where-Object { $_.AcessoTodos -match 'Full' }) 'Média' 'Arquivos' 'Estações com pasta compartilhada com controle total para Todos' 'Restringir o acesso. Ver estacoes_compartilhamentos.csv.'
    Add-AlertaPorMaquinas @($compartilhamentos | Where-Object { $_.AcessoTodos -notmatch 'Full' }) 'Baixa' 'Arquivos' 'Estações com pasta compartilhada' 'Dado em estação costuma ficar fora do backup. Ver estacoes_compartilhamentos.csv.'
    Add-AlertaPorMaquinas @($doColetor | Where-Object { $_.QtdTarefasForaPadrao -gt 0 -or $_.QtdServicosForaPadrao -gt 0 }) 'Info' 'Estações' 'Estações com tarefas ou serviços fora do padrão do Windows' 'Levantamento para conferência, não indica problema por si só. Ver estacoes_tarefas.csv e estacoes_servicos.csv.'
}

function New-EstacoesHtml {
    param($Estacoes)
    $doColetor = @($Estacoes | Where-Object { $_.AcessoEntrada })
    if ($doColetor.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<p class="legenda">Dados da coleta local (coletor 2.0). Máquinas só com a consulta remota não aparecem aqui.</p>')
    $tabelas = @(
        @{ Titulo = 'Licenças'; Colunas = 'Computador', 'WindowsAtivacao', 'WindowsCanal', 'WindowsChaveFinal', 'OfficeEdicao', 'OfficeLicenca', 'OfficeAtivacao', 'OfficeConta', 'BiosVersao' }
        @{ Titulo = 'Segurança'; Colunas = 'Computador', 'Firewall', 'AcessoEntrada', 'WinRM', 'SMBv1', 'AdministradorLocal', 'LAPS', 'USB', 'BloqueioTela' }
        @{ Titulo = 'Rede e saúde'; Colunas = 'Computador', 'IpTipo', 'IpLocal', 'UsaWiFi', 'SaudeDiscos', 'TelasAzuis30d', 'LogonsFalha7d', 'DadosLocaisGB' }
    )
    foreach ($t in $tabelas) { [void]$sb.Append("<h3>$(ConvertTo-HtmlSeguro $t.Titulo)</h3>$(New-TabelaHtml $doColetor $t.Colunas)") }
    $listas = @(
        @{ Titulo = 'Certificados nas estações'; Lista = 'Certificados'; Colunas = 'Computador', 'Titular', 'Tipo', 'ValidoAte', 'DiasRestantes', 'Usuario' }
        @{ Titulo = 'Pastas compartilhadas nas estações'; Lista = 'Compartilhamentos'; Colunas = 'Computador', 'Compartilhamento', 'Caminho', 'AcessoTodos' }
        @{ Titulo = 'Dados locais por usuário'; Lista = 'PastasUsuario'; Colunas = 'Computador', 'Usuario', 'AreaTrabalhoGB', 'DocumentosGB', 'DownloadsGB', 'TotalGB', 'OneDriveNoPerfil', 'Observacao' }
        @{ Titulo = 'Discos'; Lista = 'Discos'; Colunas = @($null) }
        @{ Titulo = 'Eventos mais frequentes (30 dias)'; Lista = 'Eventos'; Colunas = 'Computador', 'Origem', 'Id', 'Nivel', 'Quantidade', 'Ultimo', 'Mensagem' }
    )
    foreach ($l in $listas) {
        $linhas = @(Get-ListaEstacao $l.Lista)
        if ($linhas.Count -eq 0) { continue }
        $colunas = if ($null -ne $l.Colunas[0]) { $l.Colunas } else { @($linhas | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique) }
        [void]$sb.Append("<h3>$(ConvertTo-HtmlSeguro $l.Titulo)</h3>$(New-TabelaHtml $linhas $colunas)")
    }
    $sb.ToString()
}

function Get-SuporteSql {
    # Fim do suporte estendido por versão principal do SQL Server (REQ-014 veda tecnologia sem suporte).
    param([string]$Versao)
    if ($Versao -notmatch '^(\d+)\.(\d+)') { return 'Verificar' }
    $maior = [int]$Matches[1]; $menor = [int]$Matches[2]
    $mapa = @{ 16 = @('SQL Server 2022', '2033-01-11'); 15 = @('SQL Server 2019', '2030-01-08'); 14 = @('SQL Server 2017', '2027-10-12')
               13 = @('SQL Server 2016', '2026-07-14'); 12 = @('SQL Server 2014', '2024-07-09'); 11 = @('SQL Server 2012', '2022-07-12')
               9 = @('SQL Server 2005', '2016-04-12') }
    $item = if ($maior -eq 10) { if ($menor -ge 50) { @('SQL Server 2008 R2', '2019-07-09') } else { @('SQL Server 2008', '2019-07-09') } } else { $mapa[$maior] }
    if (-not $item) { return "Verificar (versão $Versao)" }
    $fim = [datetime]::ParseExact($item[1], 'yyyy-MM-dd', $null)
    $dias = ($fim - (Get-Date)).Days
    if ($dias -lt 0) { return "$($item[0]): fora de suporte desde $($fim.ToString('dd/MM/yyyy'))" }
    if ($dias -le 180) { return "$($item[0]): suporte até $($fim.ToString('dd/MM/yyyy')) (encerra em $dias dias)" }
    "$($item[0]): suportado até $($fim.ToString('dd/MM/yyyy'))"
}

function Test-PortaRapida {
    param([string]$Alvo, [int]$Porta, [int]$Timeout = 1000)
    $cliente = New-Object System.Net.Sockets.TcpClient
    try { $tarefa = $cliente.ConnectAsync($Alvo, $Porta); return ($tarefa.Wait($Timeout) -and $cliente.Connected) }
    catch { return $false }
    finally { $cliente.Close() }
}

# ============================================================================
# Funções de rede
# ============================================================================

function ConvertTo-NumeroIp {
    param([string]$Ip)
    $bytes = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($bytes)
    [int64][BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-NumeroIp {
    param([int64]$Numero)
    $bytes = [BitConverter]::GetBytes([uint32]$Numero)
    [Array]::Reverse($bytes)
    (New-Object System.Net.IPAddress -ArgumentList (, $bytes)).ToString()
}

function Get-IpsDaSubrede {
    param([string]$Cidr)
    if (-not ($Cidr -match '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$')) { throw "Sub-rede inválida: $Cidr (use o formato 192.168.1.0/24)" }
    $prefixo = [int]$Matches[3]
    if ($prefixo -lt 20 -or $prefixo -gt 30) { throw "Prefixo /$prefixo fora do intervalo aceito (/20 a /30): $Cidr" }
    $tamanho = [int64][math]::Pow(2, 32 - $prefixo)
    $rede = [int64]([math]::Floor((ConvertTo-NumeroIp $Matches[1]) / $tamanho) * $tamanho)
    for ($n = $rede + 1; $n -lt $rede + $tamanho - 1; $n++) { ConvertFrom-NumeroIp $n }
}

function Get-TipoAdaptador {
    param([string]$Texto)
    if ($Texto -match '(?i)loopback|npcap|KM-TEST') { return 'Loopback/captura' }
    if ($Texto -match '(?i)hyper-v|vEthernet|virtual|vmware|virtualbox|TAP-|WAN Miniport|Bluetooth|WSL|Docker') { return 'Virtual' }
    'Física'
}

function Get-SubredesLocais {
    # Rede de produção = adaptador com IP válido e ROTA PADRÃO, ou placa física com IP.
    # "Física ou virtual" não serve: em host Hyper-V o IP real mora num vEthernet ligado ao vSwitch
    # externo. Já WSL, Docker, Default Switch e VirtualBox host-only nunca têm gateway.
    $tipoPorIndice = @{}
    foreach ($a in Get-NetAdapter -ErrorAction SilentlyContinue) {
        $tipoPorIndice[[int]$a.ifIndex] = Get-TipoAdaptador "$($a.InterfaceDescription) $($a.Name)"
    }
    $comGateway = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } | ForEach-Object { [int]$_.InterfaceIndex } | Select-Object -Unique)
    $enderecos = @(Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' })
    if (-not $IncluirRedesVirtuais) {
        $ehProducao = { param($e) ([int]$e.InterfaceIndex -in $comGateway) -or ($tipoPorIndice[[int]$e.InterfaceIndex] -eq 'Física') }
        $ignoradas = @($enderecos | Where-Object { -not (& $ehProducao $_) })
        if ($ignoradas.Count -gt 0) {
            Write-Log ("Redes sem rota de saída ignoradas na varredura (WSL/Docker/host-only): {0}. Use -IncluirRedesVirtuais para incluí-las." -f (($ignoradas.IPAddress) -join ', '))
        }
        $enderecos = @($enderecos | Where-Object { & $ehProducao $_ })
    }
    if ($enderecos.Count -eq 0) { Write-Log 'Nenhuma rede de produção detectada (sem IP com gateway). Informe -Subredes 192.168.1.0/24.' 'AVISO' }
    $lista = foreach ($e in $enderecos) {
        $prefixo = [int]$e.PrefixLength
        if ($prefixo -lt 20) {
            Write-Log "Sub-rede /$prefixo em $($e.IPAddress) tem mais de 4096 endereços; varrendo apenas a /22 ao redor do servidor. Use -Subredes para definir o alcance exato." 'AVISO'
            $prefixo = 22
        }
        $tamanho = [int64][math]::Pow(2, 32 - $prefixo)
        $rede = [int64]([math]::Floor((ConvertTo-NumeroIp $e.IPAddress) / $tamanho) * $tamanho)
        '{0}/{1}' -f (ConvertFrom-NumeroIp $rede), $prefixo
    }
    @($lista | Select-Object -Unique)
}

function Invoke-VarreduraPing {
    param([string[]]$Ips, [int]$Timeout, [int]$Lote = 0)
    if ($Lote -le 0) { $Lote = $script:LotePing }
    $vivos = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Ips.Count; $i += $Lote) {
        if ($i -gt 0 -and $script:PausaLoteMs -gt 0) { Start-Sleep -Milliseconds $script:PausaLoteMs }
        $fatia = @($Ips[$i..([math]::Min($i + $Lote, $Ips.Count) - 1)])
        $pendentes = @(foreach ($ip in $fatia) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            [pscustomobject]@{ Ip = $ip; Ping = $ping; Tarefa = $ping.SendPingAsync($ip, $Timeout) }
        })
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pendentes.Tarefa), $Timeout + 3000) } catch { }
        foreach ($item in $pendentes) {
            if ($item.Tarefa.Status -eq 'RanToCompletion' -and $item.Tarefa.Result.Status -eq 'Success') {
                $ttl = if ($item.Tarefa.Result.Options) { $item.Tarefa.Result.Options.Ttl } else { $null }
                $vivos.Add([pscustomobject]@{ Ip = $item.Ip; LatenciaMs = $item.Tarefa.Result.RoundtripTime; Ttl = $ttl })
            }
            $item.Ping.Dispose()
        }
    }
    $vivos
}

function Invoke-VarreduraPortas {
    param([string[]]$Ips, [int[]]$Portas, [int]$Timeout, [int]$Lote = 0)
    if ($Lote -le 0) { $Lote = $script:LotePortas }
    $alvos = @(foreach ($ip in $Ips) { foreach ($porta in $Portas) { [pscustomobject]@{ Ip = $ip; Porta = $porta } } })
    $abertas = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $alvos.Count; $i += $Lote) {
        # Pausa entre as rajadas: roteador SOHO tem tabela de conexões pequena e trava o DNS se for inundado.
        if ($i -gt 0 -and $script:PausaLoteMs -gt 0) { Start-Sleep -Milliseconds $script:PausaLoteMs }
        $fatia = @($alvos[$i..([math]::Min($i + $Lote, $alvos.Count) - 1)])
        $pendentes = @(foreach ($alvo in $fatia) {
            $cliente = New-Object System.Net.Sockets.TcpClient
            [pscustomobject]@{ Alvo = $alvo; Cliente = $cliente; Tarefa = $cliente.ConnectAsync($alvo.Ip, $alvo.Porta) }
        })
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pendentes.Tarefa), $Timeout) } catch { }
        foreach ($item in $pendentes) {
            if ($item.Tarefa.Status -eq 'RanToCompletion' -and $item.Cliente.Connected) { $abertas.Add($item.Alvo) }
            $item.Cliente.Close()
        }
    }
    $abertas
}

function Get-TituloWeb {
    param([string]$Ip, [int]$Porta)
    $esquema = if ($Porta -in 443, 5001, 8006, 8443, 9090) { 'https' } else { 'http' }
    $resposta = $null
    try {
        $requisicao = [System.Net.HttpWebRequest]::Create("${esquema}://${Ip}:${Porta}/")
        $requisicao.Timeout = 3000
        $requisicao.ReadWriteTimeout = 3000
        $requisicao.UserAgent = 'Nextec-Assessment'
        $resposta = $requisicao.GetResponse()
    }
    catch [System.Net.WebException] { $resposta = $_.Exception.Response }
    catch { return $null }
    if (-not $resposta) { return $null }
    try {
        $leitor = New-Object System.IO.StreamReader($resposta.GetResponseStream())
        $buffer = New-Object char[] 16384
        $lidos = $leitor.Read($buffer, 0, $buffer.Length)
        $html = [string]::new($buffer, 0, [math]::Max($lidos, 0))
        $titulo = if ($html -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') { [System.Net.WebUtility]::HtmlDecode(($Matches[1] -replace '\s+', ' ')).Trim() } else { '' }
        $realm = [string]$resposta.Headers['WWW-Authenticate']
        if (-not $titulo -and $realm) { $titulo = $realm }
        if ($titulo.Length -gt 120) { $titulo = $titulo.Substring(0, 120) }
        [pscustomobject]@{ Titulo = $titulo; Servidor = [string]$resposta.Headers['Server'] }
    }
    catch { $null }
    finally { $resposta.Close() }
}

function Invoke-ComandoComTimeout {
    # Executa um utilitário do Windows e devolve a saída (stdout + stderr).
    # Se passar do tempo, mata o processo e devolve $null, para quem chamou saber que não houve resposta.
    param([string]$Arquivo, [string]$Argumentos, [int]$TimeoutMs = 8000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Arquivo; $psi.Arguments = $Argumentos
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # Mesma decodificação da chamada nativa do PowerShell (página OEM do console), para manter os acentos.
    $codificacao = try { [Console]::OutputEncoding } catch { $null }
    if (-not $codificacao) { $codificacao = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    $psi.StandardOutputEncoding = $codificacao; $psi.StandardErrorEncoding = $codificacao
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $saida = $proc.StandardOutput.ReadToEndAsync()
        $erro = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) { try { $proc.Kill() } catch { }; return $null }
        $proc.WaitForExit()
        ($saida.Result + $erro.Result)
    } catch { '' }
    finally { if ($proc) { $proc.Dispose() } }
}

function Invoke-Externo {
    # Roda uma linha de comando ("netsh wlan show interfaces") com limite de tempo e registra no log quando trava.
    param([string]$Linha, [int]$TimeoutSeg = 20)
    $partes = $Linha.Trim() -split '\s+', 2
    $argumentos = if ($partes.Count -gt 1) { $partes[1] } else { '' }
    $saida = Invoke-ComandoComTimeout -Arquivo $partes[0] -Argumentos $argumentos -TimeoutMs ($TimeoutSeg * 1000)
    if ($null -eq $saida) { Write-Log "  '$Linha' sem resposta em $TimeoutSeg s: interrompido, a coleta seguiu sem esse dado." 'AVISO' }
    $saida
}

function Save-TextoExterno {
    # Igual ao Save-Texto, mas para utilitários do Windows: cada comando tem limite de tempo e não trava a coleta.
    param([string]$Nome, [string[]]$Comandos, [string]$Descricao, [int]$TimeoutSeg = 20)
    $partes = foreach ($c in $Comandos) {
        $saida = Invoke-Externo -Linha $c -TimeoutSeg $TimeoutSeg
        if ($null -eq $saida) { "[$c] sem resposta em $TimeoutSeg s (comando interrompido)" } else { $saida }
    }
    ($partes -join [Environment]::NewLine) | Out-File -FilePath (Join-Path $script:PastaSaida "$Nome.txt") -Encoding UTF8
    $script:Arquivos.Add([pscustomobject]@{ Arquivo = "$Nome.txt"; Registros = $null; Descricao = $Descricao })
}

function Invoke-ComLimiteTempo {
    # Roda cmdlets que podem travar (WMI, Storage, Defender, Windows Server Backup) num runspace à parte.
    # Se não responder no prazo, a coleta segue e a chamada travada é abandonada (morre junto com o script).
    # O bloco não enxerga variáveis nem funções do script: passar valores por -Argumentos (param no bloco).
    param([scriptblock]$Bloco, [string]$Descricao = 'Consulta', [int]$TimeoutSeg = 30, [object[]]$Argumentos = @())
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Bloco.ToString())
    foreach ($a in $Argumentos) { [void]$ps.AddArgument($a) }
    $assinc = $ps.BeginInvoke()
    if ($assinc.AsyncWaitHandle.WaitOne($TimeoutSeg * 1000)) {
        try { $ps.EndInvoke($assinc) }
        finally { $ps.Dispose() }
    } else {
        [void]$ps.BeginStop($null, $null)
        Write-Log "  $Descricao sem resposta em $TimeoutSeg s: a coleta seguiu sem esse dado." 'AVISO'
        throw [System.TimeoutException]::new("$Descricao sem resposta em $TimeoutSeg s")
    }
}

function Get-NomeNetBios {
    # Consulta de status NetBIOS (NBSTAT, UDP 137) feita direto pelo script, sem abrir o nbtstat.exe.
    # Mesmo resultado do nbtstat -A: devolve o nome único <00> do equipamento.
    param([string]$Ip, [int]$TimeoutMs = 1500)
    # A própria máquina de coleta nem sempre responde à consulta feita para o próprio IP.
    if (-not $script:IpsLocais) {
        $script:IpsLocais = @(try { [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | ForEach-Object { $_.IPAddressToString } } catch { })
    }
    if ($script:IpsLocais -contains $Ip) { return $env:COMPUTERNAME.ToUpper() }
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $id = Get-Random -Minimum 1 -Maximum 65535
        $pacote = New-Object System.Collections.Generic.List[byte]
        # Cabeçalho: id, flags 0, 1 pergunta, sem respostas
        $pacote.AddRange([byte[]]@([byte]($id -shr 8), [byte]($id -band 0xFF), 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        # Nome '*' completado com nulos até 16 bytes, na codificação NetBIOS (cada meio byte + 'A')
        $pacote.Add(0x20)
        $pacote.AddRange([byte[]]@(0x43, 0x4B))
        for ($i = 0; $i -lt 15; $i++) { $pacote.AddRange([byte[]]@(0x41, 0x41)) }
        # Fim do nome, tipo NBSTAT (0x21), classe IN (0x01)
        $pacote.AddRange([byte[]]@(0x00, 0x00, 0x21, 0x00, 0x01))
        $dados = $pacote.ToArray()
        [void]$udp.Send($dados, $dados.Length, $Ip, 137)
        $origem = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resposta = $udp.Receive([ref]$origem)
        # Depois do cabeçalho (12) vem o nome da resposta: completo (tamanho + nome + 0) ou ponteiro de 2 bytes.
        # Em seguida tipo e classe (4), TTL (4) e tamanho (2); o próximo byte é a quantidade de nomes.
        if ($resposta.Length -lt 14) { return '' }
        $p = if (($resposta[12] -band 0xC0) -eq 0xC0) { 14 } else { 12 + 1 + [int]$resposta[12] + 1 }
        $p += 10
        if ($resposta.Length -le $p) { return '' }
        $quantidade = [int]$resposta[$p]
        for ($n = 0; $n -lt $quantidade; $n++) {
            $pos = $p + 1 + ($n * 18)
            if ($pos + 18 -gt $resposta.Length) { break }
            $sufixo = $resposta[$pos + 15]
            $grupo = ($resposta[$pos + 16] -band 0x80) -ne 0
            if ($sufixo -eq 0x00 -and -not $grupo) {
                return ([System.Text.Encoding]::ASCII.GetString($resposta, $pos, 15)).Trim([char]0, ' ')
            }
        }
        ''
    } catch { '' }
    finally { $udp.Close() }
}

function Get-AntivirusComportamental {
    # Antivírus com bloqueio por comportamento que costumam interromper a varredura de rede quando a pasta do script não está liberada.
    $conhecidos = [ordered]@{
        'Bitdefender'                     = '^(EPSecurityService|EPProtectedService|EPIntegrationService|bdredline)$'
        'Sophos'                          = '^Sophos'
        'CrowdStrike Falcon'              = '^CSFalconService$'
        'SentinelOne'                     = '^SentinelAgent$'
        'Microsoft Defender for Endpoint' = '^Sense$'
        'Kaspersky'                       = '^(AVP|kavfs|klnagent)'
        'ESET'                            = '^ekrn$'
        'Trend Micro'                     = '^(ds_agent|TMBMServer|ntrtscan)$'
    }
    $servicos = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    foreach ($produto in $conhecidos.Keys) {
        if (@($servicos -match $conhecidos[$produto]).Count) { $produto }
    }
}

function Get-CompartilhamentosRemotos {
    # Lista pastas e impressoras compartilhadas visíveis (net view), sem os compartilhamentos administrativos.
    param([string]$Ip)
    $linhas = (Invoke-ComandoComTimeout 'net.exe' "view \\$Ip" 5000) -split "`r?`n"
    $inicio = [array]::FindIndex([string[]]$linhas, [Predicate[string]] { param($l) $l -match '^-{10,}' })
    if ($inicio -lt 0 -or $inicio -ge $linhas.Count - 1) { return }
    foreach ($l in $linhas[($inicio + 1)..($linhas.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($l) -or $l -match '(?i)comando|command') { break }
        $partes = @($l.Trim() -split '\s{2,}')
        if ($partes[0] -match '^(IPC\$|ADMIN\$|[A-Z]\$|print\$)$') { continue }
        [pscustomobject]@{ Nome = $partes[0]; Tipo = $(if ($partes.Count -gt 1) { $partes[1] } else { '' }); Comentario = ($partes | Select-Object -Skip 2) -join ' ' }
    }
}

function Get-BannerTcp {
    # Lê a primeira linha que o serviço envia ao conectar (SSH, FTP, SMTP). Não envia comandos nem credenciais.
    param([string]$Ip, [int]$Porta, [int]$Timeout = 2500)
    $cliente = New-Object System.Net.Sockets.TcpClient
    try {
        if (-not $cliente.ConnectAsync($Ip, $Porta).Wait($Timeout)) { return '' }
        $fluxo = $cliente.GetStream()
        $fluxo.ReadTimeout = $Timeout
        $buffer = New-Object byte[] 512
        $lidos = $fluxo.Read($buffer, 0, $buffer.Length)
        $texto = ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $lidos) -split "`r?`n")[0]
        ($texto -replace '[^\x20-\x7E]', '').Trim()
    } catch { '' }
    finally { $cliente.Close() }
}

function Get-InfoTls {
    # Negocia TLS em cada versão para descobrir quais o serviço aceita e lê o certificado apresentado.
    # Só abre a conexão e desliga; não envia requisição nem credencial.
    param([string]$Ip, [int]$Porta, [string]$NomeHost, [int]$Timeout = 4000)
    # O nome DNS, quando existe, é o alvo correto do handshake (SNI) e traz o certificado certo.
    $alvoSni = if ($NomeHost) { $NomeHost } else { $Ip }
    # Ordem pensada para desistir cedo: se 1.2, 1.3 e 1.0 falharem, a porta não fala TLS e não
    # adianta gastar timeout com 1.1 e SSL 3.0.
    $versoes = [ordered]@{ 'TLS 1.2' = 3072; 'TLS 1.3' = 12288; 'TLS 1.0' = 192; 'TLS 1.1' = 768; 'SSL 3.0' = 48 }
    $aceitos = New-Object System.Collections.Generic.List[string]
    $cert = $null
    $tentativas = 0
    $validacao = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }
    foreach ($nome in $versoes.Keys) {
        $tentativas++
        if ($tentativas -gt 3 -and $aceitos.Count -eq 0) { break }
        $cliente = $null; $ssl = $null
        try {
            $cliente = New-Object System.Net.Sockets.TcpClient
            if (-not $cliente.ConnectAsync($Ip, $Porta).Wait($Timeout)) { break }
            # Sem isto o handshake fica pendurado indefinidamente numa porta que aceita conexão
            # mas não fala TLS (RPC, SMB, DVR). O Wait() acima limita só o connect.
            $fluxo = $cliente.GetStream()
            $fluxo.ReadTimeout = $Timeout
            $fluxo.WriteTimeout = $Timeout
            $ssl = New-Object System.Net.Security.SslStream($fluxo, $false, $validacao)
            $ssl.AuthenticateAsClient($alvoSni, $null, [System.Security.Authentication.SslProtocols]$versoes[$nome], $false)
            $aceitos.Add($nome)
            if (-not $cert -and $ssl.RemoteCertificate) {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
            }
        } catch { }
        finally {
            if ($ssl) { try { $ssl.Dispose() } catch { } }
            if ($cliente) { try { $cliente.Close() } catch { } }
        }
    }
    if ($aceitos.Count -eq 0 -and -not $cert) { return $null }
    $obsoletos = @($aceitos | Where-Object { $_ -in 'TLS 1.0', 'TLS 1.1', 'SSL 3.0' })
    [pscustomobject]@{
        IP = $Ip; Porta = $Porta
        ProtocolosAceitos = ($aceitos -join ', ')
        ProtocoloObsoleto = ($obsoletos -join ', ')
        CertificadoAssunto = if ($cert) { $cert.Subject } else { '' }
        CertificadoEmissor = if ($cert) { $cert.Issuer } else { '' }
        CertificadoValidoAte = if ($cert) { Format-Data $cert.NotAfter } else { '' }
        DiasParaVencer = if ($cert) { [int]($cert.NotAfter - (Get-Date)).TotalDays } else { $null }
        AutoAssinado = if ($cert) { $cert.Subject -eq $cert.Issuer } else { $null }
    }
}

function Get-SoPorBanner {
    param([string]$Banner)
    switch -Regex ($Banner) {
        '(?i)OpenSSH_for_Windows'   { return 'Windows (OpenSSH)' }
        '(?i)Ubuntu'                { return 'Linux Ubuntu' }
        '(?i)Raspbian'              { return 'Linux Raspberry Pi OS' }
        '(?i)Debian'                { return 'Linux Debian' }
        '(?i)el\d|CentOS|Red ?Hat'  { return 'Linux RHEL/CentOS' }
        '(?i)FreeBSD'               { return 'FreeBSD (pfSense/OPNsense/TrueNAS)' }
        '(?i)ROSSSH|MikroTik'       { return 'MikroTik RouterOS' }
        '(?i)Cisco'                 { return 'Cisco IOS' }
        '(?i)dropbear'              { return 'Linux embarcado (dropbear)' }
        '(?i)Microsoft ESMTP|Microsoft FTP' { return 'Windows Server' }
        default                     { return '' }
    }
}

function Get-TipoProvavel {
    param([int[]]$PortasAbertas, $Ttl, [string]$TextoWeb, [string]$Fabricante)
    $t = "$TextoWeb"
    $f = "$Fabricante"
    $windows = $PortasAbertas -contains 445 -or $PortasAbertas -contains 3389 -or $PortasAbertas -contains 135
    # RPC (135) e RDP (3389) só existem em Windows. PC com 515 é o serviço LPD do Windows, não impressora.
    $windowsForte = $PortasAbertas -contains 135 -or $PortasAbertas -contains 3389
    if ($PortasAbertas -contains 88 -and $PortasAbertas -contains 389) { return 'Servidor Windows (controlador de domínio)' }
    if ($PortasAbertas -contains 1433 -or $PortasAbertas -contains 3050 -or $PortasAbertas -contains 1521) { return 'Servidor de banco de dados' }
    if ($f -match '(?i)VMware|Hyper-V|QEMU|VirtualBox') {
        if ($windows) { return 'Servidor Windows (máquina virtual)' }
        return 'Servidor (máquina virtual)'
    }
    # Controladora fora de banda (iDRAC, iLO, IPMI): dá poder total sobre o servidor e costuma ficar esquecida.
    if ($PortasAbertas -contains 623 -or
        $t -match '(?i)idrac|integrated dell remote|\biLO\b|integrated lights-out|supermicro|\bIPMI\b|\bBMC\b|megarac|remote management') {
        return 'Gerência fora de banda (iDRAC/iLO/IPMI)'
    }
    if ($PortasAbertas -contains 902 -or $PortasAbertas -contains 5989 -or $t -match '(?i)esxi|vsphere|vmware') { return 'Servidor de virtualização (VMware ESXi)' }
    if ($PortasAbertas -contains 8006 -or $t -match '(?i)proxmox') { return 'Servidor de virtualização (Proxmox)' }
    if ($t -match '(?i)xcp-ng|xenserver') { return 'Servidor de virtualização (XCP-ng/Xen)' }
    if (-not $windowsForte -and (
        $PortasAbertas -contains 9100 -or $PortasAbertas -contains 515 -or $PortasAbertas -contains 631 -or
        $f -match '(?i)^(Epson|Brother|Kyocera|Ricoh|Zebra|Lexmark|Xerox|Canon)' -or
        $t -match '(?i)printer|impressora|brother|epson|laserjet|officejet|ricoh|kyocera|lexmark|xerox|canon|samsung|zebra')) { return 'Impressora/multifuncional' }
    if ($PortasAbertas -contains 37777 -or $PortasAbertas -contains 34567 -or $PortasAbertas -contains 554 -or
        $f -match '(?i)Hikvision|Dahua' -or
        $t -match '(?i)dvr|nvr|hikvision|intelbras|dahua|camera|câmera|xmeye') { return 'Câmera/DVR/NVR' }
    if ($f -match '(?i)Synology|QNAP' -or $t -match '(?i)synology|qnap|diskstation|truenas|\bnas\b') { return 'Storage/NAS' }
    if ($PortasAbertas -contains 8291 -or $f -match '(?i)MikroTik|TP-Link|Ubiquiti|Cisco|Aruba|Fortinet|Juniper' -or
        $t -match '(?i)mikrotik|routeros|router|roteador|tp-link|tplink|mercusys|mercury|ubiquiti|unifi|omada|huawei|zte|fiberhome|pfsense|opnsense|fortigate|sonicwall|sophos|switch|intelbras') { return 'Rede (roteador/switch/firewall/AP)' }
    if ($windows) { return 'Computador Windows' }
    if ($t -match '(?i)control ?id|biometr|ponto') { return 'Relógio de ponto/biometria' }
    if ($PortasAbertas -contains 5060) { return 'Telefonia IP (VoIP)' }
    if ($Ttl -ge 100 -and $Ttl -le 128) { return 'Provável Windows (portas fechadas por firewall)' }
    if ($PortasAbertas -contains 22) { return 'Linux ou equipamento de rede (SSH)' }
    if ($f -like 'MAC aleatório*') { return 'Celular/notebook (MAC aleatório)' }
    if ($f -match '(?i)Apple') { return 'Dispositivo Apple' }
    # Fabricante entrega o que a porta não entrega: assistente, lâmpada, tomada e TV enchem o "Outros".
    if ($f -match '(?i)Tuya|Espressif|Sonoff|Shelly|Broadlink|Xiaomi|Tapo|Govee|Positivo Casa Inteligente') { return 'IoT / automação' }
    if ($f -match '(?i)Amazon Technologies|Google|Nest Labs|Sonos|Roku') { return 'Assistente / mídia' }
    if ($f -match '(?i)Samsung|LG Electronics|TCL|Roku|Philips') { return 'TV / eletrônico' }
    if ($PortasAbertas -contains 80 -or $PortasAbertas -contains 443) { return 'Dispositivo com painel web' }
    'Não identificado'
}

# Prefixos OUI (3 primeiros octetos do MAC) dos fabricantes mais comuns em clientes. O que não estiver aqui é
# consultado online (só o prefixo, nunca o MAC completo), exceto com -SemConsultaInternet.
# Só o que a base IEEE não diz direito: prefixos de virtualização (a IEEE registra "Microsoft" ou
# "PCS Systemtechnik", e o classificador precisa saber que é máquina virtual). O resto vem da base
# embutida, que é oficial. Mapa feito à mão já errou (B4-2E-99 é Gigabyte, não Brother).
$script:OuiLocal = @{
    '00-05-69' = 'VMware'; '00-0C-29' = 'VMware'; '00-1C-14' = 'VMware'; '00-50-56' = 'VMware'
    '00-15-5D' = 'Microsoft Hyper-V'; '52-54-00' = 'QEMU/KVM'; '08-00-27' = 'VirtualBox'
}
$script:CacheOui = @{}
# Definida aqui, antes da varredura de rede: o carregamento da base acontece na primeira consulta de fabricante.
# Recorte da base IEEE de fabricantes (11 mil prefixos dos fabricantes comuns em cliente).
# Em texto puro de propósito: blob em base64 com gzip é padrão que antivírus trata como carga escondida.
# Garante nome de fabricante offline em qualquer maquina, sem depender de oui.csv ao lado nem de internet.
$script:OuiEmbutido = @'
000000|XEROX CORPORATION
000001|XEROX CORPORATION
000002|XEROX CORPORATION
000003|XEROX CORPORATION
000004|XEROX CORPORATION
000005|XEROX CORPORATION
000006|XEROX CORPORATION
000007|XEROX CORPORATION
000008|XEROX CORPORATION
000009|XEROX CORPORATION
00000C|Cisco Systems, Inc
00000E|FUJITSU LIMITED
000039|TOSHIBA CORPORATION
000048|Seiko Epson Corporation
000054|Schneider Electric
00006C|Schneider Electric
000074|RICOH COMPANY LTD.
000085|CANON INC.
000095|SONY TEKTRONIX CORP.
000097|Dell EMC
0000AA|XEROX CORPORATION
0000DD|TCL INCORPORATED
0000E2|ACER TECHNOLOGIES CORP.
0000F0|Samsung Electronics Co.,Ltd
000121|WatchGuard Technologies, Inc.
000123|Schneider Electric Japan Holdings Ltd.
000124|Acer Incorporated
000130|Extreme Networks, Inc.
000142|Cisco Systems, Inc
000143|Cisco Systems, Inc
000144|Dell EMC
00014A|Sony Corporation
000163|Cisco Systems, Inc
000164|Cisco Systems, Inc
00016C|FOXCONN
000196|Cisco Systems, Inc
000197|Cisco Systems, Inc
0001C7|Cisco Systems, Inc
0001C9|Cisco Systems, Inc
0001D3|PAXCOMM, Inc.
0001E6|Hewlett Packard
0001E7|Hewlett Packard
000209|Shenzhen SED Information Technology Co., Ltd.
000216|Cisco Systems, Inc
000217|Cisco Systems, Inc
000220|CANON FINETECH INC.
00023D|Cisco Systems, Inc
00023F|Compal Electronics INC.
00024A|Cisco Systems, Inc
00024B|Cisco Systems, Inc
00026C|Philips CFT
000278|SAMSUNG ELECTRO MECHANICS CO., LTD.
00027D|Cisco Systems, Inc
00027E|Cisco Systems, Inc
000285|Riverstone Networks
000287|Adapcom
0002A5|Hewlett Packard
0002B9|Cisco Systems, Inc
0002BA|Cisco Systems, Inc
0002EE|Nokia Danmark A/S
0002FC|Cisco Systems, Inc
0002FD|Cisco Systems, Inc
000331|Cisco Systems, Inc
000332|Cisco Systems, Inc
00036B|Cisco Systems, Inc
00036C|Cisco Systems, Inc
000374|Schneider Electric
00037F|Atheros Communications, Inc.
000381|Ingenico International
000393|Apple, Inc.
00039F|Cisco Systems, Inc
0003A0|Cisco Systems, Inc
0003E3|Cisco Systems, Inc
0003E4|Cisco Systems, Inc
0003FD|Cisco Systems, Inc
0003FE|Cisco Systems, Inc
0003FF|Microsoft Corporation
000400|LEXMARK INTERNATIONAL, INC.
00040D|Avaya Inc
00040F|Asus Network Technologies, Inc.
000417|Schneider Electric
00041F|Sony Interactive Entertainment Inc.
000427|Cisco Systems, Inc
000428|Cisco Systems, Inc
00043C|SONOS Co., Ltd.
00044B|NVIDIA
00044D|Cisco Systems, Inc
00044E|Cisco Systems, Inc
000456|Cambium Networks Limited
00045A|The Linksys Group, Inc.
00046D|Cisco Systems, Inc
00046E|Cisco Systems, Inc
00047D|Motorola Solutions Inc.
000496|Extreme Networks, Inc.
00049A|Cisco Systems, Inc
00049B|Cisco Systems, Inc
0004C0|Cisco Systems, Inc
0004C1|Cisco Systems, Inc
0004DD|Cisco Systems, Inc
0004DE|Cisco Systems, Inc
0004EA|Hewlett Packard
0004EB|Paxonet Communications, Inc.
0004F2|Polycom
000500|Cisco Systems, Inc
000501|Cisco Systems, Inc
000502|Apple, Inc.
000512|Zebra Technologies Inc
000521|Schneider Electric
000531|Cisco Systems, Inc
000532|Cisco Systems, Inc
00054B|Eaton Automation AG
00054E|Philips
00055D|D-LINK SYSTEMS, INC.
00055E|Cisco Systems, Inc
00055F|Cisco Systems, Inc
000569|VMware, Inc.
000573|Cisco Systems, Inc
000574|Cisco Systems, Inc
000585|Juniper Networks
00059A|Cisco Systems, Inc
00059B|Cisco Systems, Inc
0005B5|Broadcom Technologies
0005DC|Cisco Systems, Inc
0005DD|Cisco Systems, Inc
0005FC|Schenck Pegasus Corp.
000600|Toshiba Teli Corporation
00061B|Notebook Development Lab. Lenovo Japan Ltd.
000625|The Linksys Group, Inc.
000628|Cisco Systems, Inc
00062A|Cisco Systems, Inc
000633|Crossmatch Technologies/HID Global
000637|Toptrend-Meta Information (ShenZhen) Inc.
000646|ShenZhen XunBao Network Technology Co Ltd
00064A|Honeywell Co., Ltd. (KOREA)
000652|Cisco Systems, Inc
000653|Cisco Systems, Inc
00065B|Dell Inc.
00067C|Cisco Systems, Inc
0006B1|Sonicwall
0006C1|Cisco Systems, Inc
0006D6|Cisco Systems, Inc
0006D7|Cisco Systems, Inc
0006F6|Cisco Systems, Inc
00070D|Cisco Systems, Inc
00070E|Cisco Systems, Inc
000725|Bematech International Corp.
000726|SHENZHEN GONGJIN ELECTRONICS CO.,LT
00073E|China Great-Wall Computer Shenzhen Co., Ltd.
00074D|Zebra Technologies Corp.
00074F|Cisco Systems, Inc
000750|Cisco Systems, Inc
00077D|Cisco Systems, Inc
000784|Cisco Systems, Inc
000785|Cisco Systems, Inc
0007AB|Samsung Electronics Co.,Ltd
0007B3|Cisco Systems, Inc
0007B4|Cisco Systems, Inc
0007BE|DataLogic SpA
0007EB|Cisco Systems, Inc
0007EC|Cisco Systems, Inc
000802|Hewlett Packard
00080D|Toshiba
000820|Cisco Systems, Inc
000821|Cisco Systems, Inc
00082F|Cisco Systems, Inc
000830|Cisco Systems, Inc
000831|Cisco Systems, Inc
000832|Cisco Systems, Inc
000859|ShenZhen Unitone Electronics Co., Ltd.
000874|Dell Inc.
00087C|Cisco Systems, Inc
00087D|Cisco Systems, Inc
000883|Hewlett Packard
00088C|Quanta Network Systems Inc.
0008A3|Cisco Systems, Inc
0008A4|Cisco Systems, Inc
0008B2|SHENZHEN COMPASS TECHNOLOGY DEVELOPMENT CO.,LTD
0008C2|Cisco Systems, Inc
0008C6|Philips Consumer Communications
0008C7|Hewlett Packard
0008E2|Cisco Systems, Inc
0008E3|Cisco Systems, Inc
0008FB|SonoSite, Inc.
000901|Shenzhen Shixuntong Information & Technoligy Co
00090F|Fortinet, Inc.
000911|Cisco Systems, Inc
000912|Cisco Systems, Inc
000918|SAMSUNG TECHWIN CO.,LTD
000937|Inventec Appliance Corp
000943|Cisco Systems, Inc
000944|Cisco Systems, Inc
000947|Aztek, Inc.
00095B|NETGEAR
00095C|Philips Medical Systems - Cardiac and Monitoring Systems (CM
00097B|Cisco Systems, Inc
00097C|Cisco Systems, Inc
0009B6|Cisco Systems, Inc
0009B7|Cisco Systems, Inc
0009CA|iMaxNetworks(Shenzhen)Limited.
0009DC|Galaxis Technology AG
0009E8|Cisco Systems, Inc
0009E9|Cisco Systems, Inc
0009F6|Shenzhen Eastern Digital Tech Ltd.
0009FB|Philips Patient Monitoring
000A00|MediaTek Inc
000A13|Honeywell Video Systems
000A27|Apple, Inc.
000A28|Motorola
000A41|Cisco Systems, Inc
000A42|Cisco Systems, Inc
000A57|Hewlett Packard
000A5D|FingerTec Worldwide Sdn Bhd
000A8A|Cisco Systems, Inc
000A8B|Cisco Systems, Inc
000A95|Apple, Inc.
000AB7|Cisco Systems, Inc
000AB8|Cisco Systems, Inc
000AC2|Wuhan FiberHome Digital Technology Co.,Ltd.
000AD9|Sony Corporation
000AE0|Fujitsu Softek
000AE4|Wistron Corporation
000AEB|TP-LINK TECHNOLOGIES CO.,LTD.
000AF3|Cisco Systems, Inc
000AF4|Cisco Systems, Inc
000AF7|Broadcom
000B45|Cisco Systems, Inc
000B46|Cisco Systems, Inc
000B4F|Verifone, Inc.
000B5D|FUJITSU LIMITED
000B5F|Cisco Systems, Inc
000B60|Cisco Systems, Inc
000B66|Teralink Communications
000B7D|SOLOMON EXTREME INTERNATIONAL LTD.
000B82|Grandstream Networks, Inc.
000B85|Cisco Systems, Inc
000B86|Hewlett Packard Enterprise
000BBE|Cisco Systems, Inc
000BBF|Cisco Systems, Inc
000BCD|Hewlett Packard
000BD6|Paxton Access Ltd
000BDB|Dell Inc.
000BDD|TOHOKU RICOH Co., LTD.
000BDF|Shenzhen RouterD Networks Limited
000BE1|Nokia NET Product Operations
000BF9|Gemstone Communications, Inc.
000BFC|Cisco Systems, Inc
000BFD|Cisco Systems, Inc
000C29|VMware, Inc.
000C2E|Openet information technology(shenzhen) Co., Ltd.
000C30|Cisco Systems, Inc
000C31|Cisco Systems, Inc
000C41|Cisco-Linksys, LLC
000C42|Routerboard.com
000C43|MediaTek Inc
000C6E|ASUSTek COMPUTER INC.
000C76|MICRO-STAR INTERNATIONAL CO., LTD.
000C81|Schneider Electric (Australia)
000C85|Cisco Systems, Inc
000C86|Cisco Systems, Inc
000C87|AMD
000CBF|Holy Stone Ent. Co., Ltd.
000CC1|Eaton Corporation
000CCE|Cisco Systems, Inc
000CCF|Cisco Systems, Inc
000CE6|Fortinet, Inc.
000CE7|MediaTek Inc
000D28|Cisco Systems, Inc
000D29|Cisco Systems, Inc
000D3A|Microsoft Corp.
000D4B|Roku, Inc.
000D56|Dell Inc.
000D57|Fujitsu I-Network Systems Limited.
000D61|Giga-Byte Technology Co., Ltd.
000D65|Cisco Systems, Inc
000D66|Cisco Systems, Inc
000D88|D-Link Corporation
000D93|Apple, Inc.
000D9D|Hewlett Packard
000DAE|SAMSUNG HEAVY INDUSTRIES CO., LTD.
000DB6|Broadcom
000DBC|Cisco Systems, Inc
000DBD|Cisco Systems, Inc
000DE5|Samsung Thales
000DEC|Cisco Systems, Inc
000DED|Cisco Systems, Inc
000E07|Sony Corporation
000E08|Cisco-Linksys, LLC
000E09|Shenzhen Coship Software Co.,LTD.
000E1F|TCL Networks Equipment Co., Ltd.
000E38|Cisco Systems, Inc
000E39|Cisco Systems, Inc
000E58|Sonos, Inc.
000E59|Sagemcom Broadband SAS
000E7B|Toshiba
000E7F|Hewlett Packard
000E83|Cisco Systems, Inc
000E84|Cisco Systems, Inc
000EA6|ASUSTek COMPUTER INC.
000EB3|Hewlett Packard
000EC7|Motorola Korea
000ED6|Cisco Systems, Inc
000ED7|Cisco Systems, Inc
000EE1|ExtremeSpeed Inc.
000EE8|Zioncom Electronics (Shenzhen) Ltd.
000EED|Nokia Danmark A/S
000F12|Panasonic Europe Ltd.
000F1F|Dell Inc.
000F20|Hewlett Packard
000F23|Cisco Systems, Inc
000F24|Cisco Systems, Inc
000F34|Cisco Systems, Inc
000F35|Cisco Systems, Inc
000F3A|HISHARP
000F3D|D-Link Corporation
000F61|Hewlett Packard
000F66|Cisco-Linksys, LLC
000F76|Digital Keystone, Inc.
000F8F|Cisco Systems, Inc
000F90|Cisco Systems, Inc
000FA0|Canon Korea Inc.
000FB0|Compal Electronics INC.
000FB5|NETGEAR
000FBB|Nokia Siemens Networks GmbH & Co. KG.
000FDE|Sony Corporation
000FEA|GIGA-BYTE TECHNOLOGY CO.,LTD.
000FF7|Cisco Systems, Inc
000FF8|Cisco Systems, Inc
001007|Cisco Systems, Inc
00100B|Cisco Systems, Inc
00100D|Cisco Systems, Inc
001011|Cisco Systems, Inc
001014|Cisco Systems, Inc
001018|Broadcom
00101F|Cisco Systems, Inc
001029|Cisco Systems, Inc
00102F|Cisco Systems, Inc
001054|Cisco Systems, Inc
001055|FUJITSU MICROELECTRONICS, INC.
001079|Cisco Systems, Inc
00107B|Cisco Systems, Inc
001083|Hewlett Packard
00108C|Fujitsu Services Ltd
0010A6|Cisco Systems, Inc
0010B3|NOKIA MULTIMEDIA TERMINALS
0010DB|Juniper Networks
0010DC|MICRO-STAR INTERNATIONAL CO., LTD.
0010E3|Hewlett Packard
0010F6|Cisco Systems, Inc
0010FA|Apple, Inc.
0010FF|Cisco Systems, Inc
001100|Schneider Electric
001109|Micro-Star International
00110A|Hewlett Packard
001112|Honeywell CMSS
001120|Cisco Systems, Inc
001121|Cisco Systems, Inc
001124|Apple, Inc.
00112F|ASUSTek COMPUTER INC.
001132|Synology Incorporated
001143|Dell Inc.
00115C|Cisco Systems, Inc
00115D|Cisco Systems, Inc
001183|Datalogic ADC, Inc.
001185|Hewlett Packard
001192|Cisco Systems, Inc
001193|Cisco Systems, Inc
001195|D-Link Corporation
00119F|Nokia Danmark A/S
0011B5|Shenzhen Powercom Co.,Ltd
0011BB|Cisco Systems, Inc
0011BC|Cisco Systems, Inc
0011D8|ASUSTek COMPUTER INC.
0011F7|Shenzhen Forward Industry Co., Ltd
001200|Cisco Systems, Inc
001201|Cisco Systems, Inc
001217|Cisco-Linksys, LLC
00121E|Juniper Networks
00123F|Dell Inc.
001243|Cisco Systems, Inc
001244|Cisco Systems, Inc
001247|Samsung Electronics Co.,Ltd
001248|Dell EMC
001257|LeapComm Communication Technologies Inc.
00125A|Microsoft Corporation
001262|Nokia Danmark A/S
001267|Panasonic Corporation
001279|Hewlett Packard
00127F|Cisco Systems, Inc
001280|Cisco Systems, Inc
001298|MICO ELECTRIC(SHENZHEN) LIMITED
0012D9|Cisco Systems, Inc
0012DA|Cisco Systems, Inc
0012EE|Sony Corporation
0012F0|Intel Corporate
0012FB|Samsung Electronics Co.,Ltd
0012FE|Lenovo Mobile Communication Technology Ltd.
001302|Intel Corporate
001310|Cisco-Linksys, LLC
001315|Sony Interactive Entertainment Inc.
001319|Cisco Systems, Inc
00131A|Cisco Systems, Inc
001320|Intel Corporate
001321|Hewlett Packard
001324|Schneider Electric Ultra Terminal
001345|Eaton Corporation
001346|D-Link Corporation
001349|Zyxel Communications Corporation
001352|Naztec, Inc.
00135F|Cisco Systems, Inc
001360|Cisco Systems, Inc
001370|Nokia Danmark A/S
001372|Dell Inc.
001374|Atheros Communications, Inc.
001377|Samsung Electronics Co.,Ltd
00137F|Cisco Systems, Inc
001380|Cisco Systems, Inc
001389|Redes de Telefonía Móvil S.A.
001392|Ruckus Wireless
0013A9|Sony Corporation
0013C3|Cisco Systems, Inc
0013C4|Cisco Systems, Inc
0013CE|Intel Corporate
0013D3|MICRO-STAR INTERNATIONAL CO., LTD.
0013D4|ASUSTek COMPUTER INC.
0013E8|Intel Corporate
0013F3|Giga-byte Communications Inc.
0013FD|Nokia Danmark A/S
00141B|Cisco Systems, Inc
00141C|Cisco Systems, Inc
001422|Dell Inc.
001438|Hewlett Packard Enterprise
001448|Inventec Multimedia & Telecom Corporation
001451|Apple, Inc.
001460|Kyocera Wireless Corp.
001469|Cisco Systems, Inc
00146A|Cisco Systems, Inc
00146C|NETGEAR
001478|TP-LINK TECHNOLOGIES CO.,LTD.
001485|Giga-Byte
001492|Liteon, Mobile Media Solution SBU
0014A4|Hon Hai Precision Ind. Co.,Ltd.
0014A7|Nokia Danmark A/S
0014A8|Cisco Systems, Inc
0014A9|Cisco Systems, Inc
0014BF|Cisco-Linksys, LLC
0014C2|Hewlett Packard
0014F1|Cisco Systems, Inc
0014F2|Cisco Systems, Inc
0014F6|Juniper Networks
001500|Intel Corporate
001517|Intel Corporate
001518|Shenzhen 10MOONS Technology Development CO.,Ltd
00152A|Nokia Corporation
00152B|Cisco Systems, Inc
00152C|Cisco Systems, Inc
001530|Dell EMC
00153A|Shenzhen Syscan Technology Co.,Ltd.
001556|Sagemcom Broadband SAS
001558|FOXCONN
00155D|Microsoft Corporation
001560|Hewlett Packard
001562|Cisco Systems, Inc
001563|Cisco Systems, Inc
001565|XIAMEN YEALINK NETWORK TECHNOLOGY CO.,LTD
00156D|Ubiquiti Inc
001570|Zebra Technologies Inc
001599|Samsung Electronics Co.,Ltd
0015A0|Nokia Danmark A/S
0015AF|AzureWave Technology Inc.
0015B7|Toshiba
0015B9|Samsung Electronics Co.,Ltd
0015C1|Sony Interactive Entertainment Inc.
0015C5|Dell Inc.
0015C6|Cisco Systems, Inc
0015C7|Cisco Systems, Inc
0015DE|Nokia Danmark A/S
0015E9|D-Link Corporation
0015EB|zte corporation
0015F2|ASUSTek COMPUTER INC.
0015F9|Cisco Systems, Inc
0015FA|Cisco Systems, Inc
001620|Sony Corporation
001632|Samsung Electronics Co.,Ltd
001635|Hewlett Packard
001636|Quanta Computer Inc.
001645|Eaton Corporation
001646|Cisco Systems, Inc
001647|Cisco Systems, Inc
00164E|Nokia Danmark A/S
00166B|Samsung Electronics Co.,Ltd
00166C|Samsung Electronics Co.,Ltd
00166D|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
00166F|Intel Corporate
001676|Intel Corporate
001678|SHENZHEN BAOAN GAOKE ELECTRONICS CO., LTD
00169C|Cisco Systems, Inc
00169D|Cisco Systems, Inc
0016AF|Shenzhen Union Networks Equipment Co.,Ltd.
0016B6|Cisco-Linksys, LLC
0016B8|Sony Corporation
0016BC|Nokia Danmark A/S
0016C5|Shenzhen Xing Feng Industry Co.,Ltd
0016C7|Cisco Systems, Inc
0016C8|Cisco Systems, Inc
0016CB|Apple, Inc.
0016CE|Hon Hai Precision Ind. Co.,Ltd.
0016CF|Hon Hai Precision Ind. Co.,Ltd.
0016D3|Wistron Corporation
0016D4|Compal Communications, Inc.
0016DB|Samsung Electronics Co.,Ltd
0016E6|GIGA-BYTE TECHNOLOGY CO.,LTD.
0016EA|Intel Corporate
0016EB|Intel Corporate
0016F0|Dell
0016FB|SHENZHEN MTC CO LTD
001708|Hewlett Packard
00170E|Cisco Systems, Inc
00170F|Cisco Systems, Inc
001731|ASUSTek COMPUTER INC.
00173B|Cisco Systems, Inc
00173C|Extreme Engineering Solutions
001742|FUJITSU LIMITED
00174B|Nokia Danmark A/S
001759|Cisco Systems, Inc
00175A|Cisco Systems, Inc
00175C|SHARP CORPORATION
00176F|PAX Computer Technology(Shenzhen) Ltd.
001781|Greystone Data System, Inc.
001787|Brother, Brother & Sons ApS
001788|Philips Lighting BV
001794|Cisco Systems, Inc
001795|Cisco Systems, Inc
00179A|D-Link Corporation
0017A4|Hewlett Packard
0017A5|MediaTek Inc
0017B0|Nokia Danmark A/S
0017B6|Aquantia Corporation
0017C4|Quanta Microsystems, INC.
0017C5|SonicWALL
0017C8|KYOCERA Display Corporation
0017C9|Samsung Electronics Co.,Ltd
0017CB|Juniper Networks
0017D5|Samsung Electronics Co.,Ltd
0017DF|Cisco Systems, Inc
0017E0|Cisco Systems, Inc
0017F2|Apple, Inc.
0017FA|Microsoft Corporation
00180A|Cisco Meraki
00180F|Nokia Danmark A/S
001813|Sony Corporation
001818|Cisco Systems, Inc
001819|Cisco Systems, Inc
001821|SINDORICOH
001839|Cisco-Linksys, LLC
001842|Nokia Danmark A/S
00184D|NETGEAR
001864|Eaton Corporation
001867|Datalogic ADC
001868|Cisco SPVTG
001871|Hewlett Packard
001873|Cisco Systems, Inc
001874|Cisco Systems, Inc
001882|HUAWEI TECHNOLOGIES CO.,LTD
001885|Motorola Solutions Inc.
00188B|Dell Inc.
00188D|Nokia Danmark A/S
001893|SHENZHEN PHOTON BROADBAND TECHNOLOGY CO.,LTD
001899|ShenZhen jieshun Science&Technology Industry CO,LTD.
0018AF|Samsung Electronics Co.,Ltd
0018B9|Cisco Systems, Inc
0018BA|Cisco Systems, Inc
0018BD|SHENZHEN DVBWORLD TECHNOLOGY CO., LTD.
0018C5|Nokia Danmark A/S
0018DE|Intel Corporate
0018F3|ASUSTek COMPUTER INC.
0018F5|Shenzhen Streaming Video Technology Company Limited
0018F8|Cisco-Linksys, LLC
0018FE|Hewlett Packard
001906|Cisco Systems, Inc
001907|Cisco Systems, Inc
00192D|Nokia Corporation
00192F|Cisco Systems, Inc
001930|Cisco Systems, Inc
00193F|RDI technology(Shenzhen) Co.,LTD
001947|Cisco SPVTG
00194B|Sagemcom Broadband SAS
00194F|Nokia Danmark A/S
001955|Cisco Systems, Inc
001956|Cisco Systems, Inc
00195B|D-Link Corporation
00195D|ShenZhen XinHuaTong Opto Electronics Co.,Ltd
001963|Sony Corporation
001977|Extreme Networks, Inc.
001979|Nokia Danmark A/S
00197D|Hon Hai Precision Ind. Co.,Ltd.
00197E|Hon Hai Precision Ind. Co.,Ltd.
001987|Panasonic Mobile Communications Co.,Ltd.
00198F|Nokia Bell N.V.
001999|Fujitsu Technology Solutions GmbH
0019A9|Cisco Systems, Inc
0019AA|Cisco Systems, Inc
0019B7|Nokia Danmark A/S
0019B9|Dell Inc.
0019BB|Hewlett Packard
0019C5|Sony Interactive Entertainment Inc.
0019C6|zte corporation
0019CB|Zyxel Communications Corporation
0019D1|Intel Corporate
0019D2|Intel Corporate
0019DB|MICRO-STAR INTERNATIONAL CO., LTD.
0019E0|TP-LINK TECHNOLOGIES CO.,LTD.
0019E2|Juniper Networks
0019E3|Apple, Inc.
0019E7|Cisco Systems, Inc
0019E8|Cisco Systems, Inc
0019EF|SHENZHEN LINNKING ELECTRONICS CO.,LTD
0019FE|SHENZHEN SEECOMM TECHNOLOGY CO.,LTD.
001A11|Google, Inc.
001A16|Nokia Danmark A/S
001A1E|Hewlett Packard Enterprise
001A2F|Cisco Systems, Inc
001A30|Cisco Systems, Inc
001A3F|Intelbras
001A4B|Hewlett Packard
001A4D|GIGA-BYTE TECHNOLOGY CO.,LTD.
001A6C|Cisco Systems, Inc
001A6D|Cisco Systems, Inc
001A70|Cisco-Linksys, LLC
001A75|Sony Corporation
001A80|Sony Corporation
001A83|Pegasus Technologies Inc.
001A89|Nokia Danmark A/S
001A8A|Samsung Electronics Co.,Ltd
001A8C|Sophos Ltd
001A92|ASUSTek COMPUTER INC.
001A9A|Skyworth Digital Technology(Shenzhen) Co.,Ltd
001AA0|Dell Inc.
001AA1|Cisco Systems, Inc
001AA2|Cisco Systems, Inc
001ADC|Nokia Danmark A/S
001AE2|Cisco Systems, Inc
001AE3|Cisco Systems, Inc
001AE7|Aztek Networks, Inc.
001AEE|Shenztech Ltd
001B0C|Cisco Systems, Inc
001B0D|Cisco Systems, Inc
001B10|ShenZhen Kang Hui Technology Co.,ltd
001B11|D-Link Corporation
001B17|Palo Alto Networks
001B21|Intel Corporate
001B24|Quanta Computer Inc.
001B2A|Cisco Systems, Inc
001B2B|Cisco Systems, Inc
001B2F|NETGEAR
001B33|Nokia Danmark A/S
001B38|COMPAL INFORMATION (KUNSHAN) CO., LTD.
001B48|Shenzhen Lantech Electronics Co., Ltd.
001B4F|Avaya Inc
001B53|Cisco Systems, Inc
001B54|Cisco Systems, Inc
001B59|Sony Corporation
001B63|Apple, Inc.
001B67|Cisco Systems Inc
001B74|MiraLink Corporation
001B77|Intel Corporate
001B78|Hewlett Packard
001B8F|Cisco Systems, Inc
001B90|Cisco Systems, Inc
001B98|Samsung Electronics Co.,Ltd
001BA9|Brother industries, LTD.
001BAF|Nokia Danmark A/S
001BBF|Sagemcom Broadband SAS
001BC0|Juniper Networks
001BD3|Panasonic Corporation AVC Networks Company
001BD4|Cisco Systems, Inc
001BD5|Cisco Systems, Inc
001BD7|Cisco SPVTG
001BE9|Broadcom
001BEE|Nokia Danmark A/S
001BFC|ASUSTek COMPUTER INC.
001C0A|Shenzhen AEE Technology Co.,Ltd.
001C0E|Cisco Systems, Inc
001C0F|Cisco Systems, Inc
001C10|Cisco-Linksys, LLC
001C14|VMware, Inc.
001C1B|Hyperstone GmbH
001C23|Dell Inc.
001C25|Hon Hai Precision Ind. Co.,Ltd.
001C26|Hon Hai Precision Ind. Co.,Ltd.
001C35|Nokia Danmark A/S
001C43|Samsung Electronics Co.,Ltd
001C50|TCL Technoly Electronics (Huizhou) Co., Ltd.
001C54|Hillstone Networks Inc
001C55|Shenzhen Kaifa Technology Co.
001C57|Cisco Systems, Inc
001C58|Cisco Systems, Inc
001C62|LG Electronics (Mobile Communications)
001C7E|Toshiba
001C9A|Nokia Danmark A/S
001CA4|Sony Corporation
001CB0|Cisco Systems, Inc
001CB1|Cisco Systems, Inc
001CB3|Apple, Inc.
001CBF|Intel Corporate
001CC0|Intel Corporate
001CC4|Hewlett Packard
001CD4|Nokia Danmark A/S
001CD6|Nokia Danmark A/S
001CEE|SHARP Corporation
001CF0|D-Link Corporation
001CF6|Cisco Systems, Inc
001CF9|Cisco Systems, Inc
001D07|Shenzhen Sang Fei Consumer Communications Co.,Ltd
001D09|Dell Inc.
001D0D|Sony Interactive Entertainment Inc.
001D0F|TP-LINK TECHNOLOGIES CO.,LTD.
001D15|Shenzhen Dolphin Electronic Co., Ltd
001D25|Samsung Electronics Co.,Ltd
001D28|Sony Corporation
001D2A|SHENZHEN BUL-TECH CO.,LTD.
001D2E|Ruckus Wireless
001D3B|Nokia Danmark A/S
001D43|Shenzhen G-link Digital Technology Co., Ltd.
001D45|Cisco Systems, Inc
001D46|Cisco Systems, Inc
001D4F|Apple, Inc.
001D60|ASUSTek COMPUTER INC.
001D6E|Nokia Danmark A/S
001D70|Cisco Systems, Inc
001D71|Cisco Systems, Inc
001D72|Wistron Corporation
001D7D|GIGA-BYTE TECHNOLOGY CO.,LTD.
001D7E|Cisco-Linksys, LLC
001D92|MICRO-STAR INT'L CO.,LTD.
001D96|WatchGuard Video
001D98|Nokia Danmark A/S
001DA1|Cisco Systems, Inc
001DA2|Cisco Systems, Inc
001DB5|Juniper Networks
001DBA|Sony Corporation
001DD8|Microsoft Corporation
001DD9|Hon Hai Precision Ind. Co.,Ltd.
001DE0|Intel Corporate
001DE1|Intel Corporate
001DE5|Cisco Systems, Inc
001DE6|Cisco Systems, Inc
001DE9|Nokia Danmark A/S
001DF6|Samsung Electronics Co.,Ltd
001DFB|NETCLEUS Systems Corporation
001DFD|Nokia Danmark A/S
001E0B|Hewlett Packard
001E10|HUAWEI TECHNOLOGIES CO.,LTD
001E13|Cisco Systems, Inc
001E14|Cisco Systems, Inc
001E1E|Honeywell Life Safety
001E2A|NETGEAR
001E33|INVENTEC CORPORATION
001E3A|Nokia Danmark A/S
001E3B|Nokia Danmark A/S
001E45|Sony Corporation
001E49|Cisco Systems, Inc
001E4A|Cisco Systems, Inc
001E4C|Hon Hai Precision Ind. Co.,Ltd.
001E4F|Dell Inc.
001E52|Apple, Inc.
001E58|D-Link Corporation
001E64|Intel Corporate
001E65|Intel Corporate
001E67|Intel Corporate
001E68|Quanta Computer Inc.
001E6B|Cisco SPVTG
001E6E|Shenzhen First Mile Communications Ltd
001E73|zte corporation
001E74|Sagemcom Broadband SAS
001E75|LG Electronics (Mobile Communications)
001E79|Cisco Systems, Inc
001E7A|Cisco Systems, Inc
001E7D|Samsung Electronics Co.,Ltd
001E8C|ASUSTek COMPUTER INC.
001E8F|CANON INC.
001EA3|Nokia Danmark A/S
001EA4|Nokia Danmark A/S
001EBD|Cisco Systems, Inc
001EBE|Cisco Systems, Inc
001EC2|Apple, Inc.
001EC9|Dell Inc.
001ECF|PHILIPS ELECTRONICS UK LTD
001EDC|Sony Corporation
001EE1|Samsung Electronics Co.,Ltd
001EE2|Samsung Electronics Co.,Ltd
001EE3|T&W Electronics (ShenZhen) Co.,Ltd
001EE5|Cisco-Linksys, LLC
001EE6|Shenzhen Advanced Video Info-Tech Co., Ltd.
001EE9|Stoneridge Electronics AB
001EEC|COMPAL INFORMATION (KUNSHAN) CO., LTD.
001EF6|Cisco Systems, Inc
001EF7|Cisco Systems, Inc
001F00|Nokia Danmark A/S
001F01|Nokia Danmark A/S
001F07|AZTEQ Mobile
001F12|Juniper Networks
001F16|Wistron Corporation
001F26|Cisco Systems, Inc
001F27|Cisco Systems, Inc
001F29|Hewlett Packard
001F33|NETGEAR
001F3A|Hon Hai Precision Ind. Co.,Ltd.
001F3B|Intel Corporate
001F3C|Intel Corporate
001F41|Ruckus Wireless
001F55|Honeywell Security (China) Co., Ltd.
001F59|Kronback Tracers
001F5B|Apple, Inc.
001F5C|Nokia Danmark A/S
001F5D|Nokia Danmark A/S
001F6B|LG Electronics (Mobile Communications)
001F6C|Cisco Systems, Inc
001F6D|Cisco Systems, Inc
001F92|Motorola Solutions Inc.
001F95|Sagemcom Broadband SAS
001F9D|Cisco Systems, Inc
001F9E|Cisco Systems, Inc
001FA3|T&W Electronics(Shenzhen)Co.,Ltd.
001FA4|SHENZHEN GONGJIN ELECTRONICS CO.,LT
001FA7|Sony Interactive Entertainment Inc.
001FBD|Kyocera Wireless Corp.
001FBE|Shenzhen Mopnet Industrial Co.,Ltd
001FC6|ASUSTek COMPUTER INC.
001FC9|Cisco Systems, Inc
001FCA|Cisco Systems, Inc
001FCC|Samsung Electronics Co.,Ltd
001FCD|Samsung Electronics Co.,Ltd
001FD0|GIGA-BYTE TECHNOLOGY CO.,LTD.
001FD6|Shenzhen Allywll
001FDE|Nokia Danmark A/S
001FDF|Nokia Danmark A/S
001FE1|Hon Hai Precision Ind. Co.,Ltd.
001FE2|Hon Hai Precision Ind. Co.,Ltd.
001FE3|LG Electronics (Mobile Communications)
001FE4|Sony Corporation
001FF3|Apple, Inc.
002000|LEXMARK INTERNATIONAL, INC.
002004|YAMATAKE-HONEYWELL CO., LTD.
00203D|Honeywell Environmental & Combustion Controls
00206B|KONICA MINOLTA HOLDINGS, INC.
002075|MOTOROLA COMMUNICATION ISRAEL
002085|Eaton Corporation
0020D9|PANASONIC TECHNOLOGIES, INC./MIECO-US
0020ED|GIGA-BYTE TECHNOLOGY CO., LTD.
0020F9|PARALINK NETWORKS, INC.
002108|Nokia Danmark A/S
002109|Nokia Danmark A/S
002119|SAMSUNG ELECTRO MECHANICS CO., LTD.
00211B|Cisco Systems, Inc
00211C|Cisco Systems, Inc
002126|Shenzhen Torch Equipment Co., Ltd.
002127|TP-LINK TECHNOLOGIES CO.,LTD.
002129|Cisco-Linksys, LLC
00214B|Shenzhen HAMP Science & Technology Co.,Ltd
00214C|Samsung Electronics Co.,Ltd
002155|Cisco Systems, Inc
002156|Cisco Systems, Inc
002159|Juniper Networks
00215A|Hewlett Packard
00215C|Intel Corporate
00215D|Intel Corporate
00216A|Intel Corporate
00216B|Intel Corporate
002170|Dell Inc.
002185|MICRO-STAR INT'L CO.,LTD.
002191|D-Link Corporation
00219B|Dell Inc.
00219E|Sony Corporation
0021A0|Cisco Systems, Inc
0021A1|Cisco Systems, Inc
0021AA|Nokia Danmark A/S
0021AB|Nokia Danmark A/S
0021B7|LEXMARK INTERNATIONAL, INC.
0021BE|Cisco SPVTG
0021CB|SMS TECNOLOGIA ELETRONICA LTDA
0021D1|Samsung Electronics Co.,Ltd
0021D2|Samsung Electronics Co.,Ltd
0021D7|Cisco Systems, Inc
0021D8|Cisco Systems, Inc
0021DB|Santachi Video Technology (Shenzhen) Co., Ltd.
0021E9|Apple, Inc.
0021FB|LG Electronics (Mobile Communications)
0021FC|Nokia Danmark A/S
0021FE|Nokia Danmark A/S
00220C|Cisco Systems, Inc
00220D|Cisco Systems, Inc
002215|ASUSTek COMPUTER INC.
002219|Dell Inc.
00223A|Cisco SPVTG
00223F|NETGEAR
002241|Apple, Inc.
002243|AzureWave Technology Inc.
002248|Microsoft Corporation
002255|Cisco Systems, Inc
002256|Cisco Systems, Inc
00225F|Liteon Technology Corporation
002264|Hewlett Packard
002265|Nokia Danmark A/S
002266|Nokia Danmark A/S
002268|Hon Hai Precision Ind. Co.,Ltd.
002269|Hon Hai Precision Ind. Co.,Ltd.
00226A|Honeywell
00226B|Cisco-Linksys, LLC
00226D|Shenzhen GIEC Electronics Co., Ltd.
002278|Shenzhen Tongfang Multimedia Technology Co.,Ltd.
00227F|Ruckus Wireless
002283|Juniper Networks
002289|Vanderlande APC inc.
002290|Cisco Systems, Inc
002291|Cisco Systems, Inc
002293|zte corporation
002294|KYOCERA CORPORATION
002298|Sony Corporation
0022A1|Huawei Symantec Technologies Co.,Ltd.
0022A6|Sony Computer Entertainment America
0022A9|LG Electronics (Mobile Communications)
0022AB|Shenzhen Turbosight Technology Ltd
0022B0|D-Link Corporation
0022BD|Cisco Systems, Inc
0022BE|Cisco Systems, Inc
0022C0|Shenzhen Forcelink Electronic Co, Ltd
0022CE|Cisco SPVTG
0022D5|Eaton Corp. Electrical Group Data Center Solutions - Pulizzi
0022D8|Shenzhen GST Security and Safety Technology Limited
0022F3|SHARP Corporation
0022FA|Intel Corporate
0022FB|Intel Corporate
0022FC|Nokia Danmark A/S
0022FD|Nokia Danmark A/S
002304|Cisco Systems, Inc
002305|Cisco Systems, Inc
002312|Apple, Inc.
002314|Intel Corporate
002315|Intel Corporate
002318|Toshiba
002326|FUJITSU LIMITED
002332|Apple, Inc.
002333|Cisco Systems, Inc
002334|Cisco Systems, Inc
002339|Samsung Electronics Co.,Ltd
00233A|Samsung Electronics Co.,Ltd
002345|Sony Corporation
002348|Sagemcom Broadband SAS
00234D|Hon Hai Precision Ind. Co.,Ltd.
00234E|Hon Hai Precision Ind. Co.,Ltd.
002354|ASUSTek COMPUTER INC.
00235A|COMPAL INFORMATION (KUNSHAN) CO., LTD.
00235D|Cisco Systems, Inc
00235E|Cisco Systems, Inc
002363|Zhuhai Raysharp Technology Co.,Ltd
002368|Zebra Technologies Inc
002369|Cisco-Linksys, LLC
00236C|Apple, Inc.
00237D|Hewlett Packard
00238B|Quanta Computer Inc.
002399|Samsung Electronics Co.,Ltd
00239C|Juniper Networks
0023AB|Cisco Systems, Inc
0023AC|Cisco Systems, Inc
0023AE|Dell Inc.
0023B4|Nokia Danmark A/S
0023B6|SECURITE COMMUNICATIONS / HONEYWELL
0023BE|Cisco SPVTG
0023C2|SAMSUNG Electronics. Co. LTD
0023CB|Shenzhen Full-join Technology Co.,Ltd
0023CD|TP-LINK TECHNOLOGIES CO.,LTD.
0023D6|Samsung Electronics Co.,Ltd
0023D7|Samsung Electronics Co.,Ltd
0023DD|ELGIN S.A.
0023DF|Apple, Inc.
0023E5|IPaXiom Networks
0023EA|Cisco Systems, Inc
0023EB|Cisco Systems, Inc
0023F1|Sony Corporation
0023F8|Zyxel Communications Corporation
002401|D-Link Corporation
002403|Nokia Danmark A/S
002404|Nokia Danmark A/S
00240E|Inventec Besta Co., Ltd.
002413|Cisco Systems, Inc
002414|Cisco Systems, Inc
00241D|GIGA-BYTE TECHNOLOGY CO.,LTD.
002421|MICRO-STAR INT'L CO., LTD.
002423|AzureWave Technologies (Shanghai) Inc.
002424|Ace Axis Limited
002425|Shenzhenshi chuangzhicheng Technology Co.,Ltd
00242B|Hon Hai Precision Ind. Co.,Ltd.
00242C|Hon Hai Precision Ind. Co.,Ltd.
002436|Apple, Inc.
002437|Motorola - BSG
002447|Kaztek Systems
002450|Cisco Systems, Inc
002451|Cisco Systems, Inc
002454|Samsung Electronics Co.,Ltd
00246C|Hewlett Packard Enterprise
00247C|Nokia Danmark A/S
00247D|Nokia Danmark A/S
002481|Hewlett Packard
002482|Ruckus Wireless
002483|LG Electronics (Mobile Communications)
00248C|ASUSTek COMPUTER INC.
00248D|Sony Interactive Entertainment Inc.
002490|Samsung Electronics Co.,Ltd
002491|Samsung Electronics Co.,Ltd
002492|Motorola, Broadband Solutions Group
002494|Shenzhen Baoxin Tech CO., Ltd.
002497|Cisco Systems, Inc
002498|Cisco Systems, Inc
0024B2|NETGEAR
0024BE|Sony Corporation
0024C3|Cisco Systems, Inc
0024C4|Cisco Systems, Inc
0024D0|Shenzhen SOGOOD Industry CO.,LTD.
0024D6|Intel Corporate
0024D7|Intel Corporate
0024DC|Juniper Networks
0024E8|Dell Inc.
0024E9|Samsung Electronics Co.,Ltd
0024EF|Sony Corporation
0024F1|Shenzhen Fanhai Sanjiang Electronics Co., Ltd.
0024F7|Cisco Systems, Inc
0024F9|Cisco Systems, Inc
002500|Apple, Inc.
002512|zte corporation
00251B|Philips CareServant
00252E|Cisco SPVTG
002538|Samsung Electronics Co., Ltd., Memory Division
002545|Cisco Systems, Inc
002546|Cisco Systems, Inc
002547|Nokia Danmark A/S
002548|Nokia Danmark A/S
00254B|Apple, Inc.
002556|Hon Hai Precision Ind. Co.,Ltd.
002564|Dell Inc.
002566|Samsung Electronics Co.,Ltd
002567|Samsung Electronics Co.,Ltd
002568|HUAWEI TECHNOLOGIES CO.,LTD
002569|Sagemcom Broadband SAS
002583|Cisco Systems, Inc
002584|Cisco Systems, Inc
002586|TP-LINK TECHNOLOGIES CO.,LTD.
00259C|Cisco-Linksys, LLC
00259E|HUAWEI TECHNOLOGIES CO.,LTD
0025AE|Microsoft Corporation
0025B3|Hewlett Packard
0025B4|Cisco Systems, Inc
0025B5|Cisco Systems, Inc
0025BC|Apple, Inc.
0025BD|Italdata Ingegneria dell'Idea S.p.A.
0025C4|Ruckus Wireless
0025C9|SHENZHEN HUAPU DIGITAL CO., LTD
0025CF|Nokia Danmark A/S
0025D0|Nokia Danmark A/S
0025D3|AzureWave Technology Inc.
0025DB|ATI Electronics(Shenzhen) Co., LTD
0025E5|LG Electronics (Mobile Communications)
0025E7|Sony Corporation
002603|Shenzhen Wistar Technology Co., Ltd
002608|Apple, Inc.
00260A|Cisco Systems, Inc
00260B|Cisco Systems, Inc
002618|ASUSTek COMPUTER INC.
002622|COMPAL INFORMATION (KUNSHAN) CO., LTD.
00262D|Wistron Corporation
002637|SAMSUNG ELECTRO MECHANICS CO., LTD.
00264A|Apple, Inc.
002651|Cisco Systems, Inc
002652|Cisco Systems, Inc
002655|Hewlett Packard
00265A|D-Link Corporation
00265C|Hon Hai Precision Ind. Co.,Ltd.
00265D|Samsung Electronics Co.,Ltd
00265E|Hon Hai Precision Ind. Co.,Ltd.
00265F|Samsung Electronics Co.,Ltd
002663|Shenzhen Huitaiwei Tech. Ltd, co.
002668|Nokia Danmark A/S
002669|Nokia Danmark A/S
00266C|INVENTEC CORPORATION
002673|RICOH COMPANY,LTD.
002675|Aztech Electronics Pte Ltd
002688|Juniper Networks
002691|Sagemcom Broadband SAS
002698|Cisco Systems, Inc
002699|Cisco Systems, Inc
00269E|Quanta Computer Inc.
0026AB|Seiko Epson Corporation
0026B0|Apple, Inc.
0026B9|Dell Inc.
0026BB|Apple, Inc.
0026BF|ShenZhen Temobi Science&Tech Development Co.,Ltd
0026C6|Intel Corporate
0026C7|Intel Corporate
0026CA|Cisco Systems, Inc
0026CB|Cisco Systems, Inc
0026CC|Nokia Danmark A/S
0026E2|LG Electronics (Mobile Communications)
0026ED|zte corporation
0026F2|NETGEAR
002700|Shenzhen Siglent Technology Co., Ltd.
00270C|Cisco Systems, Inc
00270D|Cisco Systems, Inc
00270E|Intel Corporate
002710|Intel Corporate
002719|TP-LINK TECHNOLOGIES CO.,LTD.
002721|Shenzhen Baoan Fenda Industrial Co., Ltd
002722|Ubiquiti Inc
002790|Cisco Systems, Inc
0027E3|Cisco Systems, Inc
0028F8|Intel Corporate
0029C2|Cisco Systems, Inc
002A10|Cisco Systems, Inc
002A6A|Cisco Systems, Inc
002B67|LCFC(Hefei) Electronics Technology co., ltd
002B70|Samsung Electronics Co.,Ltd
002B90|Zelus(Shenzhen) Technology Ltd.
002CC8|Cisco Systems, Inc
002EC7|HUAWEI TECHNOLOGIES CO.,LTD
002F5C|Cisco Systems, Inc
002FD9|Fiberhome Telecommunication Technologies Co.,LTD
003005|Fujitsu Siemens Computers
00300A|Aztech Electronics Pte Ltd
003019|Cisco Systems, Inc
003024|Cisco Systems, Inc
003040|Cisco Systems, Inc
003065|Apple, Inc.
00306E|Hewlett Packard
003071|Cisco Systems, Inc
003078|Cisco Systems, Inc
00307B|Cisco Systems, Inc
003080|Cisco Systems, Inc
003085|Cisco Systems, Inc
00308E|Crossmatch Technologies/HID Global
003094|Cisco Systems, Inc
003096|Cisco Systems, Inc
0030A3|Cisco Systems, Inc
0030AF|Honeywell GmbH
0030B6|Cisco Systems, Inc
0030C1|Hewlett Packard
0030C4|Canon Imaging Systems Inc.
0030F2|Cisco Systems, Inc
003126|Nokia
003146|Juniper Networks
003192|TP-Link Systems Inc
003217|Cisco Systems, Inc
003358|Ruckus Wireless
00337A|Tuya Smart Inc.
0034DA|LG Electronics (Mobile Communications)
0034FE|HUAWEI TECHNOLOGIES CO.,LTD
00351A|Cisco Systems, Inc
0037B7|Sagemcom Broadband SAS
0038DF|Cisco Systems, Inc
003A7D|Cisco Systems, Inc
003A98|Cisco Systems, Inc
003A99|Cisco Systems, Inc
003A9A|Cisco Systems, Inc
003A9B|Cisco Systems, Inc
003A9C|Cisco Systems, Inc
003C10|Cisco Systems, Inc
003CB7|AzureWave Technology Inc.
003DE1|Huawei Device Co., Ltd.
003DE8|LG Electronics (Mobile Communications)
003EC4|Huawei Device Co., Ltd.
003EE1|Apple, Inc.
003F10|Shenzhen GainStrong Technology Co., Ltd.
00400B|Cisco Systems, Inc
004043|Nokia Siemens Networks GmbH & Co. KG.
004084|Honeywell
00408C|Axis Communications AB
004093|PAXDATA NETWORKS LTD.
004096|Cisco Systems, Inc
0041D2|Cisco Systems, Inc
004238|Intel Corporate
00425A|Cisco Systems, Inc
004268|Cisco Systems, Inc
00451D|Cisco Systems, Inc
00464B|HUAWEI TECHNOLOGIES CO.,LTD
004A77|zte corporation
004B0D|Huawei Device Co., Ltd.
004B12|Espressif Inc.
004BF3|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
004E01|Dell Inc.
004E35|Hewlett Packard Enterprise
004F1A|HUAWEI TECHNOLOGIES CO.,LTD
005009|PHILIPS BROADBAND NETWORKS
00500B|Cisco Systems, Inc
00500F|Cisco Systems, Inc
005014|Cisco Systems, Inc
00502A|Cisco Systems, Inc
00503E|Cisco Systems, Inc
005040|Panasonic Electric Works Co., Ltd.
005043|MARVELL SEMICONDUCTOR, INC.
005050|Cisco Systems, Inc
005053|Cisco Systems, Inc
005054|Cisco Systems, Inc
005056|VMware, Inc.
005073|Cisco Systems, Inc
005080|Cisco Systems, Inc
00508B|Hewlett Packard
0050A2|Cisco Systems, Inc
0050A7|Cisco Systems, Inc
0050AA|KONICA MINOLTA HOLDINGS, INC.
0050BA|D-Link Corporation
0050BD|Cisco Systems, Inc
0050D1|Cisco Systems, Inc
0050E2|Cisco Systems, Inc
0050E4|Apple, Inc.
0050F0|Cisco Systems, Inc
0050F2|MICROSOFT CORP.
00549F|Avaya Inc
00562B|Cisco Systems, Inc
00566D|Huawei Device Co., Ltd.
0056CD|Apple, Inc.
0056F1|zte corporation
0057C1|LG Electronics (Mobile Communications)
0057D2|Cisco Systems, Inc
005907|LenovoEMC Products USA, LLC
00596C|Cisco Systems, Inc
0059DC|Cisco Systems, Inc
005A13|HUAWEI TECHNOLOGIES CO.,LTD
005A39|SHENZHEN FAST TECHNOLOGIES CO.,LTD
005B94|Apple, Inc.
005C86|SHENZHEN FAST TECHNOLOGIES CO.,LTD
005CC2|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
005D73|Cisco Systems, Inc
005F67|TP-Link Systems Inc
005F86|Cisco Systems, Inc
005FBF|Toshiba Corp.
006009|Cisco Systems, Inc
00602F|Cisco Systems, Inc
00603E|Cisco Systems, Inc
006047|Cisco Systems, Inc
006048|Dell EMC
00604C|Sagemcom Broadband SAS
00605C|Cisco Systems, Inc
006067|ACER NETXUS INC.
006070|Cisco Systems, Inc
006083|Cisco Systems, Inc
0060B0|Hewlett Packard
0060DE|Kayser-Threde GmbH
006151|HUAWEI TECHNOLOGIES CO.,LTD
006168|Nokia
006171|Apple, Inc.
006201|Motorola Mobility LLC, a Lenovo Company
00620B|Broadcom Limited
0062EC|Cisco Systems, Inc
006440|Cisco Systems, Inc
006619|Huawei Device Co., Ltd.
00664B|HUAWEI TECHNOLOGIES CO.,LTD
0066DC|Apple, Inc.
006762|Fiberhome Telecommunication Technologies Co.,LTD
00682B|Huawei Device Co., Ltd.
0068EB|HP Inc.
006B6F|HUAWEI TECHNOLOGIES CO.,LTD
006BA0|SHENZHEN UNIVERSAL INTELLISYS PTE LTD
006BF1|Cisco Systems, Inc
006CBC|Cisco Systems, Inc
006D52|Apple, Inc.
006F64|Samsung Electronics Co.,Ltd
007007|Espressif Inc.
007147|Amazon Technologies Inc.
0071C2|PEGATRON CORPORATION
0071CC|Hon Hai Precision Ind. Co.,Ltd.
007204|Samsung Electronics Co., Ltd. ARTIK
007278|Cisco Systems, Inc
0072EE|Intel Corporate
00738D|Shenzhen TINNO Mobile Technology Corp.
0073E0|Samsung Electronics Co.,Ltd
007686|Cisco Systems, Inc
00778D|Cisco Systems, Inc
0077E4|Nokia Solutions and Networks GmbH & Co. KG
007839|Nokia
007888|Cisco Systems, Inc
00789E|Sagemcom Broadband SAS
007C2D|Samsung Electronics Co.,Ltd
007D3B|Samsung Electronics Co.,Ltd
007D60|Apple, Inc.
007E95|Cisco Systems, Inc
00805F|Hewlett Packard
008077|Brother industries, LTD.
008083|AMDAHL
00808E|RADSTONE TECHNOLOGY
008099|Eaton Industries GmbH
0080A0|Hewlett Packard
0080A7|Honeywell International Inc
0080C8|D-LINK SYSTEMS, INC.
0080F0|Panasonic Communications Co., Ltd.
00812A|Apple, Inc.
0081C4|Cisco Systems, Inc
008320|Huawei Device Co., Ltd.
00841E|Cisco Meraki
008497|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
0084ED|LEXMARK INTERNATIONAL, INC.
008621|Amazon Technologies Inc.
00869C|Palo Alto Networks
008701|Samsung Electronics Co.,Ltd
008731|Cisco Systems, Inc
008764|Cisco Systems, Inc
008865|Apple, Inc.
0089C9|Extreme Networks, Inc.
008A55|Huawei Device Co., Ltd.
008A76|Apple, Inc.
008A96|Cisco Systems, Inc
008CFA|INVENTEC CORPORATION
008E73|Cisco Systems, Inc
008EF2|NETGEAR
00900C|Cisco Systems, Inc
009020|PHILIPS ANALYTICAL X-RAY B.V.
009021|Cisco Systems, Inc
00902B|Cisco Systems, Inc
009030|HONEYWELL-DATING
00903E|N.V. PHILIPS INDUSTRIAL ACTIVITIES
00905F|Cisco Systems, Inc
009069|Juniper Networks
00906A|TURNSTONE SYSTEMS, INC.
00906D|Cisco Systems, Inc
00906F|Cisco Systems, Inc
00907A|Spectralink, Inc
00907F|WatchGuard Technologies, Inc.
009086|Cisco Systems, Inc
009092|Cisco Systems, Inc
0090A6|Cisco Systems, Inc
0090AB|Cisco Systems, Inc
0090B1|Cisco Systems, Inc
0090BF|Cisco Systems, Inc
0090D9|Cisco Systems, Inc
0090F2|Cisco Systems, Inc
00919E|Intel Corporate
009235|Apple, Inc.
0092FA|SHENZHEN WISKY TECHNOLOGY CO.,LTD
009337|Intel Corporate
0094EC|Huawei Device Co., Ltd.
0097F1|Apple, Inc.
00991D|HUAWEI TECHNOLOGIES CO.,LTD
009ACD|HUAWEI TECHNOLOGIES CO.,LTD
009AD2|Cisco Systems, Inc
009C02|Hewlett Packard
009E1E|Cisco Systems, Inc
009EC8|Xiaomi Communications Co Ltd
009EEE|Positivo Tecnologia S.A.
00A040|Apple, Inc.
00A060|ACER PERIPHERALS, INC.
00A077|FUJITSU NEXION, INC.
00A0BF|WIRELESS DATA GROUP MOTOROLA
00A0C5|Zyxel Communications Corporation
00A0C6|Qualcomm Inc.
00A0CA|FUJITSU DENSO LTD.
00A0D1|INVENTEC CORPORATION
00A0F8|Zebra Technologies Inc
00A159|LG Electronics
00A1DE|ShenZhen ShiHua Technology CO.,LTD
00A289|Cisco Systems, Inc
00A2EE|Cisco Systems, Inc
00A38E|Cisco Systems, Inc
00A3D1|Cisco Systems, Inc
00A45F|Huawei Device Co., Ltd.
00A554|Intel Corporate
00A5BF|Cisco Systems, Inc
00A6CA|Cisco Systems, Inc
00A742|Cisco Systems, Inc
00A91D|HUAWEI TECHNOLOGIES CO.,LTD
00AA6E|Cisco Systems, Inc
00AA70|LG Electronics (Mobile Communications)
00AD24|D-Link International
00ADD5|Huawei Device Co., Ltd.
00AF1F|Cisco Systems, Inc
00B04A|Cisco Systems, Inc
00B052|Atheros Communications
00B064|Cisco Systems, Inc
00B08E|Cisco Systems, Inc
00B0C2|Cisco Systems, Inc
00B0D0|Dell Inc.
00B0E1|Cisco Systems, Inc
00B1E3|Cisco Systems, Inc
00B362|Apple, Inc.
00B5D0|Samsung Electronics Co.,Ltd
00B670|Cisco Systems, Inc
00B771|Cisco Systems, Inc
00B81D|Extreme Networks, Inc.
00B8B3|Cisco Systems, Inc
00B8B6|Motorola Mobility LLC, a Lenovo Company
00B9F6|Shenzhen Super Rich Electronics Co.,Ltd
00BB1C|Huawei Device Co., Ltd.
00BB3A|Amazon Technologies Inc.
00BB60|Intel Corporate
00BBC1|CANON INC.
00BC60|Cisco Systems, Inc
00BC99|Hangzhou Hikvision Digital Technology Co.,Ltd.
00BD3A|Nokia Corporation
00BD82|Shenzhen YOUHUA Technology Co., Ltd
00BE3B|HUAWEI TECHNOLOGIES CO.,LTD
00BE43|Dell Inc.
00BE75|Cisco Systems, Inc
00BE9E|Fiberhome Telecommunication Technologies Co.,LTD
00BF61|Samsung Electronics Co.,Ltd
00BF77|Cisco Systems, Inc
00C04F|Dell Inc.
00C08F|Panasonic Electric Works Co., Ltd.
00C09F|Quanta Computer Inc.
00C0EE|KYOCERA Display Corporation
00C164|Cisco Systems, Inc
00C1B1|Cisco Systems, Inc
00C2C6|Intel Corporate
00C30A|Xiaomi Communications Co Ltd
00C3F4|Samsung Electronics Co.,Ltd
00C52C|Juniper Networks
00C585|Apple, Inc.
00C610|Apple, Inc.
00C84E|Hewlett Packard Enterprise
00C88B|Cisco Systems, Inc
00CAE5|Cisco Systems, Inc
00CB51|Sagemcom Broadband SAS
00CBB4|SHENZHEN ATEKO PHOTOELECTRICITY CO.,LTD
00CC05|HUAWEI TECHNOLOGIES CO.,LTD
00CC34|Juniper Networks
00CCFC|Cisco Systems, Inc
00CDFE|Apple, Inc.
00D006|Cisco Systems, Inc
00D058|Cisco Systems, Inc
00D060|Panasonic Europe Ltd.
00D063|Cisco Systems, Inc
00D079|Cisco Systems, Inc
00D090|Cisco Systems, Inc
00D097|Cisco Systems, Inc
00D0BA|Cisco Systems, Inc
00D0BB|Cisco Systems, Inc
00D0BC|Cisco Systems, Inc
00D0C0|Cisco Systems, Inc
00D0D3|Cisco Systems, Inc
00D0DE|PHILIPS MULTIMEDIA NETWORK
00D0E4|Cisco Systems, Inc
00D0F6|Nokia
00D0FF|Cisco Systems, Inc
00D49E|Intel Corporate
00D6FE|Cisco Systems, Inc
00D76D|Intel Corporate
00D78F|Cisco Systems, Inc
00D861|Micro-Star INTL CO., LTD.
00D8A2|Huawei Device Co., Ltd.
00D9D1|Sony Interactive Entertainment Inc.
00DA27|Palo Alto Networks
00DA55|Cisco Systems, Inc
00DB70|Apple, Inc.
00DBDF|Intel Corporate
00DCB2|Extreme Networks, Inc.
00DD25|Shenzhen hechengdong Technology Co., Ltd
00DEFB|Cisco Systems, Inc
00DF1D|Cisco Systems, Inc
00E000|FUJITSU LIMITED
00E003|NOKIA WIRELESS BUSINESS COMMUN
00E007|Avaya ECS Ltd
00E00C|MOTOROLA
00E014|Cisco Systems, Inc
00E018|ASUSTek COMPUTER INC.
00E01E|Cisco Systems, Inc
00E02B|Extreme Networks, Inc.
00E034|Cisco Systems, Inc
00E04C|REALTEK SEMICONDUCTOR CORP.
00E04F|Cisco Systems, Inc
00E064|SAMSUNG ELECTRONICS
00E088|LTX-Credence CORPORATION
00E08F|Cisco Systems, Inc
00E091|LG Electronics
00E0A3|Cisco Systems, Inc
00E0B0|Cisco Systems, Inc
00E0F7|Cisco Systems, Inc
00E0F9|Cisco Systems, Inc
00E0FC|HUAWEI TECHNOLOGIES CO.,LTD
00E0FE|Cisco Systems, Inc
00E12F|HUAWEI TECHNOLOGIES CO.,LTD
00E16D|Cisco Systems, Inc
00E18C|Intel Corporate
00E3B2|Samsung Electronics Co.,Ltd
00E406|HUAWEI TECHNOLOGIES CO.,LTD
00E421|Sony Interactive Entertainment Inc.
00E60E|Extreme Networks, Inc.
00E63A|Ruckus Wireless
00E7E3|zte corporation
00E93A|AzureWave Technology Inc.
00EABD|Cisco Systems, Inc
00EB2D|Sony Corporation
00EBD5|Cisco Systems, Inc
00EBD8|MERCUSYS TECHNOLOGIES CO., LTD.
00EC0A|Xiaomi Communications Co Ltd
00EDB8|KYOCERA Corporation
00EE01|Enablers Solucoes e Consultoria em Dispositivos
00EEAB|Cisco Systems, Inc
00F28B|Cisco Systems, Inc
00F361|Amazon Technologies Inc.
00F39F|Apple, Inc.
00F46F|Samsung Electronics Co.,Ltd
00F48D|Liteon Technology Corporation
00F4B9|Apple, Inc.
00F5FD|HUAWEI TECHNOLOGIES CO.,LTD
00F620|Google, Inc.
00F663|Cisco Systems, Inc
00F76F|Apple, Inc.
00F7AD|HUAWEI TECHNOLOGIES CO.,LTD
00F81C|HUAWEI TECHNOLOGIES CO.,LTD
00F82C|Cisco Systems, Inc
00F8CC|Sagemcom Broadband SAS
00F952|HUAWEI TECHNOLOGIES CO.,LTD
00FA21|Samsung Electronics Co.,Ltd
00FADE|Motorola Mobility LLC, a Lenovo Company
00FB4A|Espressif Inc.
00FC8B|Amazon Technologies Inc.
00FCBA|Cisco Systems, Inc
00FD22|Cisco Systems, Inc
00FD45|Hewlett Packard Enterprise
00FEC8|Cisco Systems, Inc
04006E|Google, Inc.
0401A1|Fortinet, Inc.
04021F|HUAWEI TECHNOLOGIES CO.,LTD
0402CA|Shenzhen Vtsonic Co.,ltd
040312|Hangzhou Hikvision Digital Technology Co.,Ltd.
0404B8|China Hualu Panasonic AVC Networks Co., LTD.
0405DD|Shenzhen Cultraview Digital Technology Co., Ltd
040973|Hewlett Packard Enterprise
040CCE|Apple, Inc.
040E3C|HP Inc.
040F66|TP-Link Systems Inc.
04106B|Xiaomi Communications Co Ltd
04137A|Apple, Inc.
041471|HUAWEI TECHNOLOGIES CO.,LTD
041552|Apple, Inc.
04180F|Samsung Electronics Co.,Ltd
041892|HUAWEI TECHNOLOGIES CO.,LTD
0418D6|Ubiquiti Inc
041B6D|LG Electronics (Mobile Communications)
041BBA|Samsung Electronics Co.,Ltd
041C6C|Intel Corporate
041DC7|zte corporation
041E64|Apple, Inc.
042084|zte corporation
04209A|Panasonic Corporation AVC Networks Company
0422E7|Fiberhome Telecommunication Technologies Co.,LTD
042336|Zyxel Communications Corporation
0425C5|HUAWEI TECHNOLOGIES CO.,LTD
0425F0|Nokia
042665|Apple, Inc.
042728|Microsoft Corporation
042758|HUAWEI TECHNOLOGIES CO.,LTD
04292E|Samsung Electronics Co.,Ltd
042AE2|Cisco Systems, Inc
042B58|Shenzhen Hanzsung Technology Co.,Ltd
042EC1|Apple, Inc.
042F56|ATOCS (Shenzhen) LTD
0430FA|Cisco Systems, Inc
043201|Broadcom Limited
04331F|Huawei Device Co., Ltd.
043389|HUAWEI TECHNOLOGIES CO.,LTD
0433C2|Intel Corporate
0434CF|Apple, Inc.
0434F6|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
043CE8|Shenzhen SuperElectron Technology Co.,Ltd.
043D6E|Nokia
0441A5|Apple, Inc.
04421A|ASUSTek COMPUTER INC.
04472A|Palo Alto Networks
04489A|Apple, Inc.
04495D|Huawei Device Co., Ltd.
044A50|Ramaxel Technology (Shenzhen) limited company
044A69|Shenzhen Phaten Tech. LTD
044A6C|HUAWEI TECHNOLOGIES CO.,LTD
044BA5|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
044BB1|Huawei Device Co., Ltd.
044BED|Apple, Inc.
044F4C|HUAWEI TECHNOLOGIES CO.,LTD
044FAA|Ruckus Wireless
0450DA|Qiku Internet Network Scientific (Shenzhen) Co., Ltd
0452F3|Apple, Inc.
045453|Apple, Inc.
0455B8|HUAWEI TECHNOLOGIES CO.,LTD
045665|Nokia Shanghai Bell Co., Ltd.
0456E5|Intel Corporate
045791|Shenzhenshi Xinzhongxin Technology Co.Ltd
045A95|Nokia Corporation
045C6C|Juniper Networks
045D4B|Sony Corporation
045E0A|SHENZHEN TRANSCHAN TECHNOLOGY LIMITED
045FA6|Shenzhen SDMC Technology CP,.LTD
045FA7|Shenzhen Yichen Technology Development Co.,LTD
045FB9|Cisco Systems, Inc
046273|Cisco Systems, Inc
0463D0|Huawei Device Co., Ltd.
0464FA|Dell Inc.
046761|Beijing Xiaomi Mobile Software Co., Ltd
046865|Apple, Inc.
04698F|Juniper Networks
0469F8|Apple, Inc.
046C59|Intel Corporate
046C9D|Cisco Systems, Inc
046ECB|zte corporation
046F00|LG Electronics
047179|Hewlett Packard Enterprise
047295|Apple, Inc.
0472EF|Apple, Inc.
04749E|HUAWEI TECHNOLOGIES CO.,LTD
047503|HUAWEI TECHNOLOGIES CO.,LTD
0476B0|Cisco Systems, Inc
047970|HUAWEI TECHNOLOGIES CO.,LTD
047A0B|Beijing Xiaomi Electronics Co., Ltd.
047AAE|Huawei Device Co., Ltd.
047C16|Micro-Star INTL CO., LTD.
047D50|Shenzhen Kang Ying Technology Co.Ltd.
047D7B|Quanta Computer Inc.
04801A|Huawei Device Co., Ltd.
0480A7|ShenZhen TianGang Micro Technology CO.LTD
048308|Espressif Inc.
04885F|HUAWEI TECHNOLOGIES CO.,LTD
048A15|Avaya Inc
048C03|ThinPAD Technology (Shenzhen)CO.,LTD
048C16|HUAWEI TECHNOLOGIES CO.,LTD
048C9A|Huawei Device Co., Ltd.
049226|ASUSTek COMPUTER INC.
049573|zte corporation
0495E6|Tenda Technology Co.,Ltd.Dongguan branch
0499B9|Apple, Inc.
0499BB|Apple, Inc.
0499E6|Shenzhen Yoostar Technology Co., Ltd
049D05|Apple, Inc.
049FCA|HUAWEI TECHNOLOGIES CO.,LTD
04A151|NETGEAR
04A2F3|Fiberhome Telecommunication Technologies Co.,LTD
04A526|Nokia
04A6C8|Intel Corporate
04A741|Cisco Systems, Inc
04A81C|HUAWEI TECHNOLOGIES CO.,LTD
04A82A|Nokia Corporation
04AB08|Shenzhen Skyworth Digital Technology CO., Ltd
04AE47|Beijing Xiaomi Mobile Software Co., Ltd
04B0E7|HUAWEI TECHNOLOGIES CO.,LTD
04B167|Xiaomi Communications Co Ltd
04B1A1|Samsung Electronics Co.,Ltd
04B247|Espressif Inc.
04B429|Samsung Electronics Co.,Ltd
04B5B2|Apple, Inc.
04B9E3|Samsung Electronics Co.,Ltd
04BA1C|Huawei Device Co., Ltd.
04BA8D|Samsung Electronics Co.,Ltd
04BAD6|D-Link Corporation
04BC6D|Apple, Inc.
04BC87|Shenzhen JustLink Technology Co., LTD
04BD70|HUAWEI TECHNOLOGIES CO.,LTD
04BD88|Hewlett Packard Enterprise
04BD97|Cisco Systems, Inc
04BDBF|Samsung Electronics Co.,Ltd
04BE58|HUAWEI TECHNOLOGIES CO.,LTD
04BF1B|Dell Inc.
04BF6D|Zyxel Communications Corporation
04BFD5|Apple, Inc.
04C06F|HUAWEI TECHNOLOGIES CO.,LTD
04C1B9|Fiberhome Telecommunication Technologies Co.,LTD
04C1D8|Huawei Device Co., Ltd.
04C241|Nokia
04C5A4|Cisco Systems, Inc
04C807|Xiaomi Communications Co Ltd
04C845|TP-Link Systems Inc.
04C8B0|Google, Inc.
04CAED|HUAWEI TECHNOLOGIES CO.,LTD
04CB01|Samsung Electronics Co.,Ltd
04CB88|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
04CCBC|HUAWEI TECHNOLOGIES CO.,LTD
04CE09|Shenzhen Skyworth Digital Technology CO., Ltd
04CF4B|Intel Corporate
04CF8C|XIAOMI Electronics,CO.,LTD
04D13A|Xiaomi Communications Co Ltd
04D395|Motorola Mobility LLC, a Lenovo Company
04D3B0|Intel Corporate
04D3B5|Huawei Device Co., Ltd.
04D3CF|Apple, Inc.
04D4C4|ASUSTek COMPUTER INC.
04D590|Fortinet, Inc.
04D6AA|SAMSUNG ELECTRO-MECHANICS(THAILAND)
04D9C8|Hon Hai Precision Industry Co., Ltd.
04D9F5|ASUSTek COMPUTER INC.
04DAD2|Cisco Systems, Inc
04DB56|Apple, Inc.
04DEF2|Shenzhen ECOM Technology Co. Ltd
04E0B0|Shenzhen YOUHUA Technology Co., Ltd
04E31A|Sagemcom Broadband SAS
04E387|Cisco Systems, Inc
04E4B6|Samsung Electronics Co.,Ltd
04E536|Apple, Inc.
04E598|Xiaomi Communications Co Ltd
04E795|HUAWEI TECHNOLOGIES CO.,LTD
04E8B9|Intel Corporate
04EA56|Intel Corporate
04EB40|Cisco Systems, Inc
04ECBB|Fiberhome Telecommunication Technologies Co.,LTD
04ECD8|Intel Corporate
04ED33|Intel Corporate
04EECD|Hangzhou Hikvision Digital Technology Co.,Ltd.
04EF61|Dell Inc.
04F03E|Huawei Device Co., Ltd.
04F0E4|ShenZhen Hosecom Electronic Technology Co.,LTD
04F0EE|Intel Corporate
04F13E|Apple, Inc.
04F169|Huawei Device Co., Ltd.
04F352|HUAWEI TECHNOLOGIES CO.,LTD
04F41C|Routerboard.com
04F778|Sony Interactive Entertainment Inc.
04F7E4|Apple, Inc.
04F938|HUAWEI TECHNOLOGIES CO.,LTD
04F9F8|TP-LINK TECHNOLOGIES CO.,LTD.
04FE31|Samsung Electronics Co.,Ltd
04FE7F|Cisco Systems, Inc
04FE8D|HUAWEI TECHNOLOGIES CO.,LTD
04FF08|Huawei Device Co., Ltd.
080007|Apple, Inc.
080009|Hewlett Packard
08001B|Dell EMC
08001F|SHARP CORPORATION
080023|Panasonic Communications Co., Ltd.
080046|Sony Corporation
08006F|PHILIPS APELDOORN B.V.
080072|XEROX CORP UNIV GRANT PROGRAM
080086|KONICA MINOLTA HOLDINGS, INC.
080205|HUAWEI TECHNOLOGIES CO.,LTD
08023C|Samsung Electronics Co.,Ltd
08028E|NETGEAR
080342|Palo Alto Networks
080581|Roku, Inc.
0805E2|Juniper Networks
0808C2|Samsung Electronics Co.,Ltd
080FE5|Cisco Systems, Inc
081093|Samsung Electronics Co.,Ltd
081196|Intel Corporate
0812A5|Amazon Technologies Inc.
08152F|Samsung Electronics Co., Ltd. ARTIK
081651|SHENZHEN SEA STAR TECHNOLOGY CO.,LTD
0816E3|HUAWEI TECHNOLOGIES CO.,LTD
081735|Cisco Systems, Inc
081814|Hewlett Packard Enterprise
08181A|zte corporation
0819A6|HUAWEI TECHNOLOGIES CO.,LTD
081A1E|Shenzhen iComm Semiconductor CO.,LTD
081AFD|Huawei Device Co., Ltd.
081C6E|Xiaomi Communications Co Ltd
081F71|TP-LINK TECHNOLOGIES CO.,LTD.
081FF3|Cisco Systems, Inc
0821EF|Samsung Electronics Co.,Ltd
0823C6|HUAWEI TECHNOLOGIES CO.,LTD
08240B|Apple, Inc.
082525|Xiaomi Communications Co Ltd
082573|Apple, Inc.
082697|Zyxel Communications Corporation
08276B|Huawei Device Co., Ltd.
082802|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
082CB6|Apple, Inc.
082E36|Huawei Device Co., Ltd.
082E5F|Hewlett Packard
082FE9|HUAWEI TECHNOLOGIES CO.,LTD
08306B|Palo Alto Networks
0830CE|Fiberhome Telecommunication Technologies Co.,LTD
08318B|HUAWEI TECHNOLOGIES CO.,LTD
0831A4|Huawei Device Co., Ltd.
08351B|Shenzhen Jialihua Electronic Technology Co., Ltd
08357D|Microsoft Corporation
0836C9|NETGEAR
08373D|Samsung Electronics Co.,Ltd
0838E6|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
083A8D|Espressif Inc.
083AF2|Espressif Inc.
083BC1|Hangzhou Hikvision Digital Technology Co.,Ltd.
083D88|Samsung Electronics Co.,Ltd
083E5D|Sagemcom Broadband SAS
083E8E|Hon Hai Precision Ind. Co.,Ltd.
083F21|Motorola Mobility LLC, a Lenovo Company
083FBC|zte corporation
0840F3|Tenda Technology Co.,Ltd.Dongguan branch
084473|zte corporation
0845D1|Cisco Systems, Inc
0846C7|Fiberhome Telecommunication Technologies Co.,LTD
08474C|Nokia
0847D0|Nokia Shanghai Bell Co., Ltd.
084F0A|HUAWEI TECHNOLOGIES CO.,LTD
084F66|Shenzhen Skyworth Digital Technology CO., Ltd
084FA9|Cisco Systems, Inc
084FF9|Cisco Systems, Inc
085104|Huawei Device Co., Ltd.
0851F2|Sagemcom Broadband SAS
08524E|Shenzhen Fangcheng Baiyi Technology Co., Ltd.
085411|Hangzhou Hikvision Digital Technology Co.,Ltd.
0854BB|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
085531|Routerboard.com
085700|TP-LINK TECHNOLOGIES CO.,LTD.
0857FB|Amazon Technologies Inc.
085A11|D-Link International
085B0E|Fortinet, Inc.
085BD6|Intel Corporate
085C1B|HUAWEI TECHNOLOGIES CO.,LTD
085D53|Apple, Inc.
08606E|ASUSTek COMPUTER INC.
086083|zte corporation
086202|Apple, Inc.
086266|ASUSTek COMPUTER INC.
086361|HUAWEI TECHNOLOGIES CO.,LTD
08638A|Cisco Systems, Inc
086518|Apple, Inc.
08661F|Palo Alto Networks
086698|Apple, Inc.
086A0B|Cisco Meraki
086AC5|Intel Corporate
086AE5|Amazon Technologies Inc.
086BD1|Shenzhen SuperElectron Technology Co.,Ltd.
086D41|Apple, Inc.
086DF2|Shenzhen MIMOWAVE Technology Co.,Ltd
086E9C|Huawei Device Co., Ltd.
086F48|Shenzhen iComm Semiconductor CO.,LTD
087045|Apple, Inc.
087073|HUAWEI TECHNOLOGIES CO.,LTD
08711C|Cisco Meraki
087190|Intel Corporate
087402|Apple, Inc.
087458|Fiberhome Telecommunication Technologies Co.,LTD
087671|Juniper Networks
087808|Samsung Electronics Co.,Ltd
08798C|HUAWEI TECHNOLOGIES CO.,LTD
087A4C|HUAWEI TECHNOLOGIES CO.,LTD
087B0F|Amazon Technologies Inc.
087B12|Sagemcom Broadband SAS
087B87|Cisco Systems, Inc
087C39|Amazon Technologies Inc.
087C43|Huawei Device Co., Ltd.
088039|Cisco SPVTG
0881F4|Juniper Networks
08849D|Amazon Technologies Inc.
0887C7|Apple, Inc.
088AF1|MERCUSYS TECHNOLOGIES CO., LTD.
088BC8|Google, Inc.
088C2C|Samsung Electronics Co.,Ltd
088E90|Intel Corporate
088EDC|Apple, Inc.
088FC3|COMPAL INFORMATION (KUNSHAN) CO., LTD.
089115|Amazon Technologies Inc.
0891A3|Amazon Technologies Inc.
089204|Dell Inc.
089272|Espressif Inc.
089356|HUAWEI TECHNOLOGIES CO.,LTD
0894EC|Huawei Device Co., Ltd.
0894EF|Wistron Infocomm (Zhongshan) Corporation
089542|Apple, Inc.
0896AD|Cisco Systems, Inc
089707|Cisco Systems, Inc
089734|Hewlett Packard Enterprise
089758|Shenzhen Strong Rising Electronics Co.,Ltd DongGuan Subsidiary
089798|COMPAL INFORMATION (KUNSHAN) CO., LTD.
0898EF|Shenzhen Taichi Technology Limited
089AC7|zte corporation
089BB9|Nokia Solutions and Networks GmbH & Co. KG
089C86|Nokia Shanghai Bell Co., Ltd.
089DF4|Intel Corporate
089E01|Quanta Computer Inc.
089E08|Google, Inc.
089E84|HUAWEI TECHNOLOGIES CO.,LTD
08A12B|ShenZhen EZL Technology Co., Ltd
08A189|Hangzhou Hikvision Digital Technology Co.,Ltd.
08A5DF|Samsung Electronics Co.,Ltd
08A6BC|Amazon Technologies Inc.
08A6F7|Espressif Inc.
08A842|Huawei Device Co., Ltd.
08A95A|AzureWave Technology Inc.
08AA55|Motorola Mobility LLC, a Lenovo Company
08AA89|zte corporation
08AD0A|Espressif Inc.
08AED6|Samsung Electronics Co.,Ltd
08B258|Juniper Networks
08B339|Xiaomi Communications Co Ltd
08B3D6|Huawei Device Co., Ltd.
08B4B1|Google, Inc.
08B4D2|Intel Corporate
08B61F|Espressif Inc.
08B8D0|Chipsea Technologies (Shenzhen) Corp.
08BD43|NETGEAR
08BFA0|Samsung Electronics Co.,Ltd
08BFB8|ASUSTek COMPUTER INC.
08C021|HUAWEI TECHNOLOGIES CO.,LTD
08C06C|Huawei Device Co., Ltd.
08C224|Amazon Technologies Inc.
08C3B3|TCL King Electrical Appliances(Huizhou)Co.,Ltd
08C5E1|SAMSUNG ELECTRO-MECHANICS(THAILAND)
08C729|Apple, Inc.
08C7B5|Apple, Inc.
08CC27|Motorola Mobility LLC, a Lenovo Company
08CC68|Cisco Systems, Inc
08CC81|Hangzhou Hikvision Digital Technology Co.,Ltd.
08CCA7|Cisco Systems, Inc
08D01E|Juniper Networks
08D09F|Cisco Systems, Inc
08D1F9|Espressif Inc.
08D23E|Intel Corporate
08D40C|Intel Corporate
08D42B|Samsung Electronics Co.,Ltd
08D46A|LG Electronics (Mobile Communications)
08D59D|Sagemcom Broadband SAS
08D833|Shenzhen RF Technology Co., Ltd
08D945|HUAWEI TECHNOLOGIES CO.,LTD
08DD82|HUAWEI TECHNOLOGIES CO.,LTD
08E4DF|Shenzhen Sande Dacom Electronics Co., Ltd
08E5DA|NANJING FUJITSU COMPUTER PRODUCTS CO.,LTD.
08E63B|zte corporation
08E64B|Apple, Inc.
08E689|Apple, Inc.
08E7E5|Huawei Device Co., Ltd.
08E84F|HUAWEI TECHNOLOGIES CO.,LTD
08EA40|SHENZHEN BILIAN ELECTRONIC CO.，LTD
08EA44|Extreme Networks, Inc.
08EB21|Intel Corporate
08EBF6|HUAWEI TECHNOLOGIES CO.,LTD
08ECA9|Samsung Electronics Co.,Ltd
08ECF5|Cisco Systems, Inc
08EDB9|Hon Hai Precision Ind. Co.,Ltd.
08EDED|Zhejiang Dahua Technology Co., Ltd.
08EE8B|Samsung Electronics Co.,Ltd
08F1B3|Cisco Meraki
08F1EA|Hewlett Packard Enterprise
08F3FB|Cisco Systems, Inc
08F458|Huawei Device Co., Ltd.
08F4AB|Apple, Inc.
08F4F0|Cisco Systems, Inc
08F606|zte corporation
08F69C|Apple, Inc.
08F8BC|Apple, Inc.
08F9E0|Espressif Inc.
08FA28|HUAWEI TECHNOLOGIES CO.,LTD
08FC88|Samsung Electronics Co.,Ltd
08FD0E|Samsung Electronics Co.,Ltd
08FD58|HUAWEI TECHNOLOGIES CO.,LTD
08FF24|Shenzhen Skyworth Digital Technology CO., Ltd
08FF44|Apple, Inc.
0C014B|zte corporation
0C01A5|zte corporation
0C02BD|Samsung Electronics Co.,Ltd
0C0535|Juniper Systems
0C07DF|Xiaomi Communications Co Ltd
0C07F3|HUAWEI TECHNOLOGIES CO.,LTD
0C0E76|D-Link International
0C0ECB|Huawei Device Co., Ltd.
0C1167|Cisco Systems, Inc
0C1262|zte corporation
0C12AD|Hewlett Packard Enterprise
0C1420|Samsung Electronics Co.,Ltd
0C1539|Apple, Inc.
0C1563|Apple, Inc.
0C1773|Huawei Device Co., Ltd.
0C184E|HUAWEI TECHNOLOGIES CO.,LTD
0C19F8|Apple, Inc.
0C1B7B|Microsoft Corporation
0C1C19|LONGCONN ELECTRONICS(SHENZHEN) CO.,LTD
0C1C31|MERCUSYS TECHNOLOGIES CO., LTD.
0C1DAF|Xiaomi Communications Co Ltd
0C2369|Honeywell SPS
0C238D|HUAWEI TECHNOLOGIES CO.,LTD
0C2643|Cisco Systems, Inc
0C2724|Cisco Systems, Inc
0C29EF|Dell Inc.
0C2A86|Fiberhome Telecommunication Technologies Co.,LTD
0C2C54|HUAWEI TECHNOLOGIES CO.,LTD
0C2C7C|Shenzhen Skyworth Digital Technology CO., Ltd
0C2D71|Apple, Inc.
0C2E57|HUAWEI TECHNOLOGIES CO.,LTD
0C2FB0|Samsung Electronics Co.,Ltd
0C3021|Apple, Inc.
0C31DC|HUAWEI TECHNOLOGIES CO.,LTD
0C323A|Samsung Electronics Co.,Ltd
0C3526|Microsoft Corporation
0C354F|Nokia
0C35FE|Fiberhome Telecommunication Technologies Co.,LTD
0C3623|Nokia Shanghai Bell Co., Ltd.
0C3747|zte corporation
0C37DC|HUAWEI TECHNOLOGIES CO.,LTD
0C3B50|Apple, Inc.
0C3E9F|Apple, Inc.
0C413E|Microsoft Corporation
0C41E9|HUAWEI TECHNOLOGIES CO.,LTD
0C43F9|Amazon Technologies Inc.
0C44C0|zte corporation
0C45BA|HUAWEI TECHNOLOGIES CO.,LTD
0C47C9|Amazon Technologies Inc.
0C4885|LG Electronics (Mobile Communications)
0C4B48|Nokia
0C4B54|TP-LINK TECHNOLOGIES CO.,LTD.
0C4DE9|Apple, Inc.
0C4EA0|Espressif Inc.
0C4F9B|HUAWEI TECHNOLOGIES CO.,LTD
0C5101|Apple, Inc.
0C517E|Apple, Inc.
0C53B7|Apple, Inc.
0C5415|Intel Corporate
0C54A5|PEGATRON CORPORATION
0C54B9|Nokia
0C599C|Juniper Networks
0C6076|Hon Hai Precision Ind. Co.,Ltd.
0C659A|Panasonic Automotive Systems Company of America
0C6743|HUAWEI TECHNOLOGIES CO.,LTD
0C6803|Cisco Systems, Inc
0C6ABC|Fiberhome Telecommunication Technologies Co.,LTD
0C6AC4|Apple, Inc.
0C6F8B|Apple, Inc.
0C7043|Sony Interactive Entertainment Inc.
0C704A|HUAWEI TECHNOLOGIES CO.,LTD
0C715D|Samsung Electronics Co.,Ltd
0C7165|Motorola Mobility LLC, a Lenovo Company
0C722C|TP-LINK TECHNOLOGIES CO.,LTD.
0C72D9|zte corporation
0C7474|Fiberhome Telecommunication Technologies Co.,LTD
0C74C2|Apple, Inc.
0C7512|Shenzhen Kunlun TongTai Technology Co.,Ltd.
0C75BD|Cisco Systems, Inc
0C75D2|Hangzhou Hikvision Digital Technology Co.,Ltd.
0C771A|Apple, Inc.
0C7A15|Intel Corporate
0C7BC8|Cisco Meraki
0C7C28|Nokia Solutions and Networks GmbH & Co. KG
0C7DB0|Motorola Mobility LLC, a Lenovo Company
0C8063|TP-LINK TECHNOLOGIES CO.,LTD.
0C8126|Juniper Networks
0C8230|SHENZHEN MAGNUS TECHNOLOGIES CO.,LTD
0C8268|TP-LINK TECHNOLOGIES CO.,LTD.
0C8306|Huawei Device Co., Ltd.
0C839A|Huawei Device Co., Ltd.
0C8408|HUAWEI TECHNOLOGIES CO.,LTD
0C8447|Fiberhome Telecommunication Technologies Co.,LTD
0C84DC|Hon Hai Precision Ind. Co.,Ltd.
0C8509|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
0C8525|Cisco Systems, Inc
0C85E1|Apple, Inc.
0C8610|Juniper Networks
0C8832|Nokia Solutions and Networks India Private Limited
0C8910|Samsung Electronics Co.,Ltd
0C8B95|Espressif Inc.
0C8BA2|HUAWEI TECHNOLOGIES CO.,LTD
0C8BFD|Intel Corporate
0C8C24|SHENZHEN BILIAN ELECTRONIC CO.，LTD
0C8C69|Shenzhen elink smart Co., ltd
0C8DCA|Samsung Electronics Co.,Ltd
0C8DDB|Cisco Meraki
0C8FFF|HUAWEI TECHNOLOGIES CO.,LTD
0C9192|Intel Corporate
0C9541|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
0C96BF|HUAWEI TECHNOLOGIES CO.,LTD
0C975F|Hewlett Packard Enterprise
0C9838|Xiaomi Communications Co Ltd
0C9A3C|Intel Corporate
0C9A42|FN-LINK TECHNOLOGY LIMITED
0C9B78|Extreme Networks, Inc.
0C9D92|ASUSTek COMPUTER INC.
0CA280|FN-LINK TECHNOLOGY Ltd.
0CA3B2|Apple, Inc.
0CA8A7|Samsung Electronics Co.,Ltd
0CA94A|Shenzhen Skyworth Digital Technology CO., Ltd
0CAC8A|Sagemcom Broadband SAS
0CAE39|Intel Corporate
0CAF31|Cisco Systems, Inc
0CB319|Samsung Electronics Co.,Ltd
0CB34F|Shenzhen Xiaoqi Intelligent Technology Co., Ltd.
0CB527|HUAWEI TECHNOLOGIES CO.,LTD
0CB5B3|Huawei Device Co., Ltd.
0CB6D2|D-Link International
0CB787|HUAWEI TECHNOLOGIES CO.,LTD
0CB78E|Huawei Device Co., Ltd.
0CB7EC|HUAWEI TECHNOLOGIES CO.,LTD
0CB815|Espressif Inc.
0CBC9F|Apple, Inc.
0CBEF1|Huawei Device Co., Ltd.
0CBF3F|Shenzhen Lencotion Technology Co.,Ltd
0CC119|Shenzhen Phaten Tech. LTD
0CC3B8|Shenzhen Jiahua Zhongli Technology Co., LTD
0CC413|Google, Inc.
0CC56C|Apple, Inc.
0CC66A|Nokia Corporation
0CC6CC|HUAWEI TECHNOLOGIES CO.,LTD
0CC6FD|Xiaomi Communications Co Ltd
0CC98A|Intel Corporate
0CCB85|Motorola Mobility LLC, a Lenovo Company
0CCC5D|Apple, Inc.
0CCF89|SHENZHEN BILIAN ELECTRONIC CO.，LTD
0CD0F8|Cisco Systems, Inc
0CD292|Intel Corporate
0CD5D3|Cisco Systems, Inc
0CD6BD|HUAWEI TECHNOLOGIES CO.,LTD
0CD746|Apple, Inc.
0CD86C|SHENZHEN FAST TECHNOLOGIES CO.,LTD
0CD996|Cisco Systems, Inc
0CDBEA|Apple, Inc.
0CDC7E|Espressif Inc.
0CDC91|Amazon Technologies Inc.
0CDD24|Intel Corporate
0CDDEF|Nokia Corporation
0CDFA4|Samsung Electronics Co.,Ltd
0CE0DC|Samsung Electronics Co.,Ltd
0CE159|Shenzhen iStartek Technology Co., Ltd.
0CE441|Apple, Inc.
0CE4A0|Huawei Device Co., Ltd.
0CE5A1|Apple, Inc.
0CE5B5|HUAWEI TECHNOLOGIES CO.,LTD
0CE623|Huawei Device Co., Ltd.
0CE725|Microsoft Corporation
0CEA14|Ubiquiti Inc
0CEC84|Shenzhen TINNO Mobile Technology Corp.
0CEC8D|Motorola Mobility LLC, a Lenovo Company
0CED71|Extreme Networks, Inc.
0CEDC8|Xiaomi Communications Co Ltd
0CEE99|Amazon Technologies Inc.
0CEEE6|Hon Hai Precision Ind. Co.,Ltd.
0CEF15|TP-Link Systems Inc.
0CF07B|Shenzhen Skyworth Digital Technology CO., Ltd
0CF346|Xiaomi Communications Co Ltd
0CF4D5|Ruckus Wireless
0CF5A4|Cisco Systems, Inc
0CFC18|HUAWEI TECHNOLOGIES CO.,LTD
0CFE45|Sony Interactive Entertainment Inc.
100020|Apple, Inc.
10003B|Espressif Inc.
100177|HUAWEI TECHNOLOGIES CO.,LTD
1002B5|Intel Corporate
100501|PEGATRON CORPORATION
1005CA|Cisco Systems, Inc
1005E1|Nokia
10061C|Espressif Inc.
100645|Sagemcom Broadband SAS
1006ED|Cisco Systems, Inc
10071D|Fiberhome Telecommunication Technologies Co.,LTD
1007B6|Samsung Electronics Co.,Ltd
1008B1|Hon Hai Precision Ind. Co.,Ltd.
1009F9|Amazon Technologies Inc.
100BA9|Intel Corporate
100C29|Shenzhen NORCO lntelligent Technology Co.,Ltd
100C6B|NETGEAR
100D7F|NETGEAR
100D8C|Huawei Device Co., Ltd.
100E7E|Juniper Networks
101081|zte corporation
1012D0|zte corporation
1012FB|Hangzhou Hikvision Digital Technology Co.,Ltd.
101B54|HUAWEI TECHNOLOGIES CO.,LTD
101C0C|Apple, Inc.
101D6E|Hewlett Packard Enterprise
101DC0|Samsung Electronics Co.,Ltd
101EDA|INGENICO TERMINALS SAS
101F74|Hewlett Packard
1020BA|Espressif Inc.
102407|HUAWEI TECHNOLOGIES CO.,LTD
1027F5|TP-Link Systems Inc
102874|Shenzhen Jingxun Technology Co., Ltd.
102959|Apple, Inc.
1029AB|Samsung Electronics Co.,Ltd
102AB3|Xiaomi Communications Co Ltd
102B1C|Motorola Mobility LLC, a Lenovo Company
102B41|Samsung Electronics Co.,Ltd
102BAA|Sagemcom Broadband SAS
102D31|Shenzhen Americas Trading Company LLC
102E00|Intel Corporate
102F6B|Microsoft Corporation
102F6E|Shenzhen Sundray Technologies company Limited
102FA3|Shenzhen Uvision-tech Technology Co.Ltd
102FCA|Apple, Inc.
103025|Apple, Inc.
103047|Samsung Electronics Co.,Ltd
10321D|HUAWEI TECHNOLOGIES CO.,LTD
10327E|Huawei Device Co., Ltd.
103917|Samsung Electronics Co.,Ltd
1039E9|Juniper Networks
103B54|HUAWEI TECHNOLOGIES CO.,LTD
103B59|Samsung Electronics Co.,Ltd
103C59|zte corporation
103D1C|Intel Corporate
103F44|Xiaomi Communications Co Ltd
1040F3|Apple, Inc.
10417F|Apple, Inc.
104210|Apple, Inc.
104400|HUAWEI TECHNOLOGIES CO.,LTD
104738|Nokia Shanghai Bell Co., Ltd.
104780|HUAWEI TECHNOLOGIES CO.,LTD
1047E7|Shenzhen YOUHUA Technology Co., Ltd
10490E|HUAWEI TECHNOLOGIES CO.,LTD
104A7D|Intel Corporate
104C43|Fiberhome Telecommunication Technologies Co.,LTD
104F58|Hewlett Packard Enterprise
104FA8|Sony Corporation
105107|Intel Corporate
105172|HUAWEI TECHNOLOGIES CO.,LTD
1051DB|Espressif Inc.
10521C|Espressif Inc.
1052BD|HUAWEI TECHNOLOGIES CO.,LTD
1055E4|Shenzhen Skyworth Digital Technology CO., Ltd
105725|Cisco Systems, Inc
105887|Fiberhome Telecommunication Technologies Co.,LTD
105932|Roku, Inc
105A17|Tuya Smart Inc.
105A95|TP-Link Systems Inc.
105DDC|Huawei Device Co., Ltd.
105F49|Cisco SPVTG
105FAD|Intel Corporate
10604B|Hewlett Packard
1062E5|Hewlett Packard
1062EB|D-Link International
10634B|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
1063C8|Liteon Technology Corporation
106519|Shenzhen iComm Semiconductor CO.,LTD
106530|Dell Inc.
1067A3|HUAWEI TECHNOLOGIES CO.,LTD
106838|AzureWave Technology Inc.
10683F|LG Electronics (Mobile Communications)
107100|Huawei Device Co., Ltd.
1071B3|Zyxel Communications Corporation
10746F|MOTOROLA SOLUTIONS MALAYSIA SDN. BHD.
107717|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
1077B0|Fiberhome Telecommunication Technologies Co.,LTD
1077B1|Samsung Electronics Co.,Ltd
107873|Shenzhen Jinkeyi Communication Co., Ltd.
107A2A|Microsoft Corporation
107B44|ASUSTek COMPUTER INC.
107BCE|Nokia
107BEF|Zyxel Communications Corporation
107C61|ASUSTek COMPUTER INC.
107D1A|Dell Inc.
107DC8|Apple, Inc.
1086F4|Huawei Device Co., Ltd.
1088CE|Fiberhome Telecommunication Technologies Co.,LTD
1088D3|HUAWEI TECHNOLOGIES CO.,LTD
1089FB|Samsung Electronics Co.,Ltd
108A7B|Nokia
108CCF|Cisco Systems, Inc
108EE0|Samsung Electronics Co.,Ltd
108FFE|HUAWEI TECHNOLOGIES CO.,LTD
1090FC|Shenzhen DOOGEE Hengtong Technology CO.,LTD
109166|Shenzhen Yinwang Intelligent Technologies Co.,Ltd.
1091A8|Espressif Inc.
1091D1|Intel Corporate
109266|Samsung Electronics Co.,Ltd
109327|GIGA-BYTE TECHNOLOGY CO. , Ltd.
1093E9|Apple, Inc.
1094BB|Apple, Inc.
1094EF|HUAWEI TECHNOLOGIES CO.,LTD
10961A|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
109693|Amazon Technologies Inc.
1096C6|Cisco Systems, Inc
1097BD|Espressif Inc.
109819|Dell Inc.
109826|Nokia
109836|Dell Inc.
109ABA|Intel Corporate
109ADD|Apple, Inc.
109D7A|Huawei Device Co., Ltd.
109E6B|Apple, Inc.
109F41|Apple, Inc.
109F47|Shenzhen Skyworth Digital Technology CO., Ltd
10A1DA|Apple, Inc.
10A2D3|Apple, Inc.
10A30F|HUAWEI TECHNOLOGIES CO.,LTD
10A4BE|SHENZHEN BILIAN ELECTRONIC CO.，LTD
10A4C9|Apple, Inc.
10A4DA|HUAWEI TECHNOLOGIES CO.,LTD
10A51D|Intel Corporate
10A829|Cisco Systems, Inc
10A85B|Espressif Systems (Singapore) Pte. Ltd
10A879|Intel Corporate
10ABC9|Samsung Electronics Co.,Ltd
10AE60|Amazon Technologies Inc.
10AF78|Shenzhen ATUE Technology Co., Ltd
10B06E|Shenzhen Phaten Tech. LTD
10B1F8|HUAWEI TECHNOLOGIES CO.,LTD
10B3C6|Cisco Systems, Inc
10B3D5|Cisco Systems, Inc
10B3D6|Cisco Systems, Inc
10B41D|Espressif Inc.
10B588|Apple, Inc.
10B676|HP Inc.
10B9C4|Apple, Inc.
10BA1A|SHENZHEN IK WORLD Technology Co., Ltd
10BBF3|HUNAN FN-LINK TECHNOLOGY LIMITED
10BC36|Huawei Device Co., Ltd.
10BD18|Cisco Systems, Inc
10BD3A|Apple, Inc.
10BDA3|Espressif Inc.
10BEF5|D-Link International
10BF48|ASUSTek COMPUTER INC.
10BF67|Amazon Technologies Inc.
10C172|HUAWEI TECHNOLOGIES CO.,LTD
10C197|Xiaomi Communications Co Ltd
10C34D|SHENZHEN WATER WORLD CO.,LTD.
10C37B|ASUSTek COMPUTER INC.
10C3AB|HUAWEI TECHNOLOGIES CO.,LTD
10C595|Lenovo
10C5FA|Zyxel Communications Corporation
10C61F|HUAWEI TECHNOLOGIES CO.,LTD
10C67E|SHENZHEN JUCHIN TECHNOLOGY CO., LTD
10C735|Microsoft Corporation
10CD54|HUAWEI TECHNOLOGIES CO.,LTD
10CDAE|Avaya Inc
10CE02|Amazon Technologies Inc.
10CEE9|Apple, Inc.
10CF0F|Apple, Inc.
10D0AB|zte corporation
10D38A|Samsung Electronics Co.,Ltd
10D542|Samsung Electronics Co.,Ltd
10D561|Tuya Smart Inc.
10D7B0|Sagemcom Broadband SAS
10D9A2|Google, Inc.
10DA43|NETGEAR
10DA49|Huawei Device Co., Ltd.
10DA63|Apple, Inc.
10DC4A|Fiberhome Telecommunication Technologies Co.,LTD
10DDB1|Apple, Inc.
10DF8B|Shenzhen CareDear Communication Technology Co.,Ltd
10E2C9|Apple, Inc.
10E376|Cisco Systems, Inc
10E4C2|Samsung Electronics Co.,Ltd
10E676|Cisco Systems, Inc
10E7C6|Hewlett Packard
10E878|Nokia
10E953|Huawei Device Co., Ltd.
10EA59|Cisco SPVTG
10EC81|Samsung Electronics Co.,Ltd
10F005|Intel Corporate
10F068|Ruckus Wireless
10F1F2|LG Electronics (Mobile Communications)
10F311|Cisco Systems, Inc
10F60A|Intel Corporate
10F920|Cisco Systems, Inc
10F96F|LG Electronics (Mobile Communications)
10F9EE|Nokia Corporation
10FC33|Huawei Device Co., Ltd.
10FEED|TP-LINK TECHNOLOGIES CO.,LTD.
10FFE0|GIGA-BYTE TECHNOLOGY CO.,LTD.
14007D|zte corporation
140152|Samsung Electronics Co.,Ltd
1402EC|Hewlett Packard Enterprise
140338|HUAWEI TECHNOLOGIES CO.,LTD
140498|Apple, Inc.
140589|Motorola Mobility LLC, a Lenovo Company
140808|Espressif Inc.
1409B4|zte corporation
1409DC|HUAWEI TECHNOLOGIES CO.,LTD
140A02|SHENZHEN BILIAN ELECTRONIC CO.，LTD
140AC5|Amazon Technologies Inc.
140B9E|Samsung Electronics Co.,Ltd
140F42|Nokia
14109F|Apple, Inc.
14115D|Skyworth Digital Technology(Shenzhen) Co.,Ltd
141333|AzureWave Technology Inc.
141346|Skyworth Digital Technology(Shenzhen) Co.,Ltd
1413FB|HUAWEI TECHNOLOGIES CO.,LTD
14147D|Apple, Inc.
14169D|Cisco Systems, Inc
14172A|Fiberhome Telecommunication Technologies Co.,LTD
141826|Nokia
141877|Dell Inc.
1418C3|Intel Corporate
141923|Cisco Systems, Inc
141A97|Apple, Inc.
141AA3|Motorola Mobility LLC, a Lenovo Company
141B30|Shenzhen Yipingfang Network Technology Co., Ltd.
141BA0|Apple, Inc.
141F78|Samsung Electronics Co.,Ltd
142004|zte corporation
14205E|Apple, Inc.
142233|Fiberhome Telecommunication Technologies Co.,LTD
14223B|Google, Inc.
14230A|HUAWEI TECHNOLOGIES CO.,LTD
1423F2|Broadcom Limited
1423F3|Broadcom Limited
142876|Apple, Inc.
142A14|ShenZhen Selenview Digital Technology Co.,Ltd
142B2F|Espressif Inc.
142D27|Hon Hai Precision Ind. Co.,Ltd.
142D4D|Apple, Inc.
142D79|Fiberhome Telecommunication Technologies Co.,LTD
143004|HUAWEI TECHNOLOGIES CO.,LTD
1430C6|Motorola Mobility LLC, a Lenovo Company
1432D1|Samsung Electronics Co.,Ltd
14335C|Espressif Inc.
143375|Zyxel Communications Corporation
1435B7|Apple, Inc.
143605|Nokia Corporation
14360E|Zyxel Communications Corporation
1436C6|Lenovo Mobile Communication Technology Ltd.
1438FA|Motorola Mobility LLC, a Lenovo Company
143A9A|Hon Hai Precision Industry Co.,LTD
143B42|Realfit(Shenzhen) Intelligent Technology Co., Ltd
143B51|Huawei Device Co., Ltd.
143CC3|HUAWEI TECHNOLOGIES CO.,LTD
143E60|Nokia
143EBF|zte corporation
143EC2|Intel Corporate
143FA6|Sony Home Entertainment&Sound Products Inc
144146|Honeywell (China) Co., LTD
144658|HUAWEI TECHNOLOGIES CO.,LTD
14488B|Shenzhen Doov Technology Co.,Ltd
144920|HUAWEI TECHNOLOGIES CO.,LTD
1449C5|Huawei Device Co., Ltd.
1449D4|Xiaomi Communications Co Ltd
1449E0|SAMSUNG ELECTRO-MECHANICS(THAILAND)
144CFF|Grandstream Networks, Inc.
144D67|Zioncom Electronics (Shenzhen) Ltd.
144F8A|Intel Corporate
145051|SHARP Corporation
145120|Huawei Device Co., Ltd.
145594|Huawei Device Co., Ltd.
1455B9|Nokia Solutions and Networks GmbH & Co. KG
14563A|Huawei Device Co., Ltd.
14568E|Samsung Electronics Co.,Ltd
14579F|HUAWEI TECHNOLOGIES CO.,LTD
1458D0|Hewlett Packard
1459C0|NETGEAR
145A05|Apple, Inc.
145AFC|Liteon Technology Corporation
145D34|SHENZHEN BILIAN ELECTRONIC CO.，LTD
145EBC|HUAWEI TECHNOLOGIES CO.,LTD
145F94|HUAWEI TECHNOLOGIES CO.,LTD
146080|zte corporation
1460CB|Apple, Inc.
14612F|Avaya Inc
146393|Espressif Inc.
14656A|HUAWEI TECHNOLOGIES CO.,LTD
146B72|Shenzhen Fortune Ship Technology Co., Ltd.
146B9A|zte corporation
146B9C|SHENZHEN BILIAN ELECTRONIC CO.，LTD
14755B|Intel Corporate
147590|TP-LINK TECHNOLOGIES CO.,LTD.
147649|Hewlett Packard Enterprise
147740|Huawei Device Co., Ltd.
147830|NVIDIA Corporation
147AE4|Apple, Inc.
147BAC|Nokia
147DDA|Apple, Inc.
147E19|Hewlett Packard Enterprise
147FCE|Apple, Inc.
148473|Cisco Systems, Inc
148509|Apple, Inc.
14857F|Intel Corporate
148692|TP-LINK TECHNOLOGIES CO.,LTD.
14876A|Apple, Inc.
1488E6|Apple, Inc.
1489CB|HUAWEI TECHNOLOGIES CO.,LTD
1489FD|Samsung Electronics Co.,Ltd
148C4A|HUAWEI TECHNOLOGIES CO.,LTD
148F79|Apple, Inc.
148FC6|Apple, Inc.
14907A|Beijing Xiaomi Mobile Software Co., Ltd
149138|Amazon Technologies Inc.
14946C|Apple, Inc.
149569|Shenzhen iComm Semiconductor CO.,LTD
1495CE|Apple, Inc.
1496E5|Samsung Electronics Co.,Ltd
149877|Apple, Inc.
14993E|Xiaomi Communications Co Ltd
1499E2|Apple, Inc.
149A10|Microsoft Corporation
149AA3|HUAWEI TECHNOLOGIES CO.,LTD
149D09|HUAWEI TECHNOLOGIES CO.,LTD
149D99|Apple, Inc.
149ECF|Dell Inc.
149F3C|Samsung Electronics Co.,Ltd
149F43|Cisco Meraki
149FE8|Lenovo Mobile Communication Technology Ltd.
14A0F8|HUAWEI TECHNOLOGIES CO.,LTD
14A2A0|Cisco Systems, Inc
14A32F|Huawei Device Co., Ltd.
14A364|Samsung Electronics Co.,Ltd
14A3B4|Huawei Device Co., Ltd.
14A417|Shenzhen Belon Technology CO.,LTD
14A51A|HUAWEI TECHNOLOGIES CO.,LTD
14A6B9|Samsung Electronics Co.,Ltd
14A78B|Zhejiang Dahua Technology Co., Ltd.
14A86B|ShenZhen Telacom Science&Technology Co., Ltd
14AB02|HUAWEI TECHNOLOGIES CO.,LTD
14ABC5|Intel Corporate
14ABEC|Hewlett Packard Enterprise
14B2E5|Shenzhen iComm Semiconductor CO.,LTD
14B31F|Dell Inc.
14B370|Gigaset Digital Technology (Shenzhen) Co., Ltd.
14B3A1|Juniper Networks
14B484|Samsung Electronics Co.,Ltd
14B5CD|Liteon Technology Corporation
14B653|Apple, Inc.
14B837|Shenzhen YOUHUA Technology Co., Ltd
14B903|HUAWEI TECHNOLOGIES CO.,LTD
14B968|HUAWEI TECHNOLOGIES CO.,LTD
14BAA2|Extreme Networks, Inc.
14BB6E|Samsung Electronics Co.,Ltd
14BC68|Cisco Systems, Inc
14BD61|Apple, Inc.
14C126|Nokia Corporation
14C14E|Google, Inc.
14C19F|Espressif Inc.
14C1FF|ShenZhen QianHai Comlan communication Co.,LTD
14C213|Apple, Inc.
14C7C4|Zyxel Communications Corporation
14C88B|Apple, Inc.
14C913|LG Electronics
14CA56|zte corporation
14CB19|HP Inc.
14CB65|Microsoft Corporation
14CC20|TP-LINK TECHNOLOGIES CO.,LTD.
14CF92|TP-LINK TECHNOLOGIES CO.,LTD.
14D00D|Apple, Inc.
14D11F|HUAWEI TECHNOLOGIES CO.,LTD
14D169|HUAWEI TECHNOLOGIES CO.,LTD
14D19E|Apple, Inc.
14D1D4|Huawei Device Co., Ltd.
14D424|AzureWave Technology Inc.
14D55C|Apple, Inc.
14D64D|D-Link International
14D864|TP-LINK TECHNOLOGIES CO.,LTD.
14D881|Beijing Xiaomi Mobile Software Co., Ltd
14DAB9|Huawei Device Co., Ltd.
14DAE9|ASUSTek COMPUTER INC.
14DDA9|ASUSTek COMPUTER INC.
14DE39|Huawei Device Co., Ltd.
14E01D|Samsung Electronics Co.,Ltd
14E22A|Cisco Systems, Inc
14E602|Shenzhen EMTEK Storage Technology Co.,Ltd
14E6E4|TP-LINK TECHNOLOGIES CO.,LTD.
14E9B2|Fiberhome Telecommunication Technologies Co.,LTD
14EB03|SHENZHEN IP-COM NETWORKS CO.,LTD.
14EB08|HUAWEI TECHNOLOGIES CO.,LTD
14EBB6|TP-Link Systems Inc
14EFCF|SCHREDER
14F287|Apple, Inc.
14F42A|Samsung Electronics Co.,Ltd
14F592|Shenzhen SDG DONZHI Technology Co., Ltd
14F5F9|HUNAN FN-LINK TECHNOLOGY LIMITED
14F65A|Xiaomi Communications Co Ltd
14F6D8|Intel Corporate
14F893|Wuhan FiberHome Digital Technology Co.,Ltd.
14FB70|Huawei Device Co., Ltd.
14FEB5|Dell Inc.
18002D|Sony Corporation
1801F1|Xiaomi Communications Co Ltd
18022D|HUAWEI TECHNOLOGIES CO.,LTD
180373|Dell Inc.
1806FF|Acer Computer(Shanghai) Limited.
180712|Shenzhen Dazoo Technologies CO.,Ltd
180B1B|Amazon Technologies Inc.
180BD0|HUAWEI TECHNOLOGIES CO.,LTD
180C7A|Sagemcom Broadband SAS
180CAC|CANON INC.
180D2C|Intelbras
180EAC|SHENZHEN FAST TECHNOLOGIES CO.,LTD
180F76|D-Link International
18120C|Zhouhai Intelligence(Shenzhen).,Ltd
18132D|zte corporation
181456|Nokia Corporation
1814AE|Nokia
1816C9|Samsung Electronics Co.,Ltd
1819D6|Samsung Electronics Co.,Ltd
181DEA|Intel Corporate
181E78|Sagemcom Broadband SAS
181EB0|Samsung Electronics Co.,Ltd
182012|Aztech Associates Inc.
182032|Apple, Inc.
182195|Samsung Electronics Co.,Ltd
18227E|Samsung Electronics Co.,Ltd
182649|Intel Corporate
182654|Samsung Electronics Co.,Ltd
182666|Samsung Electronics Co.,Ltd
182A57|HUAWEI TECHNOLOGIES CO.,LTD
182AD3|Juniper Networks
1831BF|ASUSTek COMPUTER INC.
1832DE|Apple, Inc.
183386|HUAWEI TECHNOLOGIES CO.,LTD
18339D|Cisco Systems, Inc
183451|Apple, Inc.
183A2D|Samsung Electronics Co.,Ltd
183C98|Shenzhen Hengyi Technology Co., LTD
183CB7|Huawei Device Co., Ltd.
183D2D|LCFC(Hefei) Electronics Technology co., ltd
183D5E|HUAWEI TECHNOLOGIES CO.,LTD
183DA2|Intel Corporate
183EEF|Apple, Inc.
183F47|Samsung Electronics Co.,Ltd
183F70|Apple, Inc.
1840A4|Shenzhen Trylong Smart Science and Technology Co., Ltd.
1844E6|zte corporation
184617|Samsung Electronics Co.,Ltd
1848BE|Amazon Technologies Inc.
1849F8|Extreme Networks, Inc.
184A53|Apple, Inc.
184B0D|Ruckus Wireless
184E16|Samsung Electronics Co.,Ltd
184ECB|Samsung Electronics Co.,Ltd
184F32|Hon Hai Precision Ind. Co.,Ltd.
185282|Fiberhome Telecommunication Technologies Co.,LTD
185345|Nokia
1854CF|Samsung Electronics Co.,Ltd
18550F|Cisco SPVTG
1855E3|Apple, Inc.
185644|HUAWEI TECHNOLOGIES CO.,LTD
185680|Intel Corporate
1856C3|Apple, Inc.
185933|Cisco SPVTG
185936|Xiaomi Communications Co Ltd
1859F5|Cisco Systems, Inc
185A58|Dell Inc.
185B00|Nokia
185BB3|Samsung Electronics Co.,Ltd
185E0B|zte corporation
185E0F|Intel Corporate
185F27|Motorola Mobility LLC, a Lenovo Company
186024|Hewlett Packard
18622C|Sagemcom Broadband SAS
186472|Hewlett Packard Enterprise
186590|Apple, Inc.
1866C7|Shenzhen Libre Technology Co., Ltd
1866DA|Dell Inc.
1867B0|Samsung Electronics Co.,Ltd
18686A|zte corporation
1868CB|Hangzhou Hikvision Digital Technology Co.,Ltd.
186945|TP-Link Systems Inc.
1869D4|Samsung Electronics Co.,Ltd
1869D8|Tuya Smart Inc.
186A81|Sagemcom Broadband SAS
186F2D|Shenzhen Sundray Technologies company Limited
186FA7|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
18703B|Huawei Device Co., Ltd.
18742E|Amazon Technologies Inc.
1879FD|zte corporation
187A3B|Hewlett Packard Enterprise
187C0B|Ruckus Wireless
187EB9|Apple, Inc.
187ED5|shenzhen kaism technology Co. Ltd
188025|Hangzhou Hikvision Digital Technology Co.,Ltd.
188090|Cisco Systems, Inc
18810E|Apple, Inc.
188331|Samsung Electronics Co.,Ltd
1886AC|Nokia Danmark A/S
1886C3|Nokia
188740|Xiaomi Communications Co Ltd
18895B|Samsung Electronics Co.,Ltd
188B0E|Espressif Inc.
188B15|ShenZhen ZhongRuiJing Technology co.,LTD
188B45|Cisco Systems, Inc
188B9D|Cisco Systems, Inc
189067|Shenzhen Jingxun Technology Co., Ltd.
1890D8|Sagemcom Broadband SAS
189341|Intel Corporate
1894A3|Wistron Service(Kunshan) Co., Ltd.
1894C6|ShenZhen Chenyee Technology Co., Ltd.
189C5D|Cisco Systems, Inc
189E2C|Huawei Device Co., Ltd.
189EAD|Shenzhen Chengqian Information Technology Co., Ltd
189EFC|Apple, Inc.
18A084|Apple, Inc.
18A3E8|Fiberhome Telecommunication Technologies Co.,LTD
18A6F7|TP-LINK TECHNOLOGIES CO.,LTD.
18A788|Shenzhen MEK Intellisys Pte Ltd
18A905|Hewlett Packard
18A99B|Dell Inc.
18AA0F|Huawei Device Co., Ltd.
18AA1E|Shenzhen Skyworth Digital Technology CO., Ltd
18AB1D|Samsung Electronics Co.,Ltd
18ACC2|TCL King Electrical Appliances(Huizhou)Co.,Ltd
18AF61|Apple, Inc.
18AF8F|Apple, Inc.
18AFA1|Shenzhen Yifang Network Technology Co., Ltd.
18B0A4|zte corporation
18B169|Sonicwall
18B657|HUAWEI TECHNOLOGIES CO.,LTD
18B83D|Samsung Electronics Co.,Ltd
18B842|Apple, Inc.
18BB1C|Huawei Device Co., Ltd.
18BB26|FN-LINK TECHNOLOGY LIMITED
18BB41|Huawei Device Co., Ltd.
18BFB3|Samsung Electronics Co., Ltd., Memory Division
18C007|Huawei Device Co., Ltd.
18C04D|GIGA-BYTE TECHNOLOGY CO.,LTD.
18C086|Broadcom
18C241|SonicWall
18C300|Nokia
18C501|SHENZHEN GONGJIN ELECTRONICS CO.,LT
18C58A|HUAWEI TECHNOLOGIES CO.,LTD
18C8E7|Shenzhen Hualistone Technology Co.,Ltd
18CAA7|zte corporation
18CC18|Intel Corporate
18CE94|Samsung Electronics Co.,Ltd
18CF24|HUAWEI TECHNOLOGIES CO.,LTD
18CF5E|Liteon Technology Corporation
18D225|Fiberhome Telecommunication Technologies Co.,LTD
18D276|HUAWEI TECHNOLOGIES CO.,LTD
18D3CF|Hewlett Packard Enterprise
18D61C|Shenzhen TINNO Mobile Technology Corp.
18D6C7|TP-LINK TECHNOLOGIES CO.,LTD.
18D6DD|HUAWEI TECHNOLOGIES CO.,LTD
18D98F|Huawei Device Co., Ltd.
18DBF2|Dell Inc.
18DC56|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
18DE50|Tuya Smart Inc.
18DED7|HUAWEI TECHNOLOGIES CO.,LTD
18E215|Nokia
18E2C2|Samsung Electronics Co.,Ltd
18E671|Apple, Inc.
18E728|Cisco Systems, Inc
18E7B0|Apple, Inc.
18E7F4|Apple, Inc.
18E829|Ubiquiti Inc
18E91D|HUAWEI TECHNOLOGIES CO.,LTD
18EBD4|Shenzhen Skyworth Digital Technology CO., Ltd
18EE69|Apple, Inc.
18EF63|Cisco Systems, Inc
18F0E4|Xiaomi Communications Co Ltd
18F1D8|Apple, Inc.
18F22C|TP-LINK TECHNOLOGIES CO.,LTD.
18F46A|Hon Hai Precision Ind. Co.,Ltd.
18F643|Apple, Inc.
18F935|Cisco Systems, Inc
18FAB7|Apple, Inc.
18FB7B|Dell Inc.
18FD74|Routerboard.com
18FE34|Espressif Inc.
18FF0F|Intel Corporate
18FF2E|Shenzhen Rui Ying Da Technology Co., Ltd
1C0B8B|Ubiquiti Inc
1C0D7D|Apple, Inc.
1C0EAF|Huawei Device Co., Ltd.
1C0EC2|Apple, Inc.
1C12B0|Amazon Technologies Inc.
1C1386|Huawei Device Co., Ltd.
1C13FA|Huawei Device Co., Ltd.
1C151F|HUAWEI TECHNOLOGIES CO.,LTD
1C17D3|Cisco Systems, Inc
1C184A|ShenZhen RicherLink Technologies Co.,LTD
1C1AC0|Apple, Inc.
1C1ADF|Microsoft Corporation
1C1B0D|GIGA-BYTE TECHNOLOGY CO.,LTD.
1C1BB5|Intel Corporate
1C1D67|HUAWEI TECHNOLOGIES CO.,LTD
1C1D86|Cisco Systems, Inc
1C1DD3|Apple, Inc.
1C1FF1|Huawei Device Co., Ltd.
1C20DB|HUAWEI TECHNOLOGIES CO.,LTD
1C2226|Cisco Systems, Inc
1C232C|Samsung Electronics Co.,Ltd
1C2575|Xiaomi Communications Co Ltd
1C2704|zte corporation
1C28AF|Hewlett Packard Enterprise
1C2904|Espressif Inc.
1C2A8B|Nokia
1C2AA3|Shenzhen HongRui Optical Technology Co., Ltd.
1C2AB0|Beijing Xiaomi Electronics Co.,Ltd
1C2D60|Extreme Networks, Inc.
1C3003|Hewlett Packard Enterprise
1C3283|COMTTI Intelligent Technology(Shenzhen) Co., Ltd.
1C32AC|HUAWEI TECHNOLOGIES CO.,LTD
1C3576|Samsung Electronics Co.,Ltd
1C36BB|Apple, Inc.
1C3947|COMPAL INFORMATION (KUNSHAN) CO., LTD.
1C398A|Fiberhome Telecommunication Technologies Co.,LTD
1C3A60|Ruckus Wireless
1C3ADE|Samsung Electronics Co.,Ltd
1C3BF3|TP-LINK TECHNOLOGIES CO.,LTD.
1C3C78|Apple, Inc.
1C3CD4|HUAWEI TECHNOLOGIES CO.,LTD
1C3D2F|HUAWEI TECHNOLOGIES CO.,LTD
1C3E84|Hon Hai Precision Ind. Co.,Ltd.
1C4024|Dell Inc.
1C40E8|SHENZHEN PROGRESS&WIN TECHNOLOGY CO.,LTD
1C42C2|Huawei Device Co., Ltd.
1C4363|HUAWEI TECHNOLOGIES CO.,LTD
1C4419|TP-LINK TECHNOLOGIES CO.,LTD.
1C472F|Huawei Device Co., Ltd.
1C47F6|Zhidao Network Technology(Shenzhen) Co.,Ltd
1C4BD6|AzureWave Technology Inc.
1C4D66|Amazon Technologies Inc.
1C4D70|Intel Corporate
1C4EA2|Shenzhen V-Link Technology CO., LTD.
1C53F9|Google, Inc.
1C54E6|Shenzhen Yisheng Technology Co.,Ltd
1C568E|Zioncom Electronics (Shenzhen) Ltd.
1C56FE|Motorola Mobility LLC, a Lenovo Company
1C57DC|Apple, Inc.
1C599B|HUAWEI TECHNOLOGIES CO.,LTD
1C5A3E|Samsung Electronics Co.,Ltd
1C5A6B|Philips Electronics Nederland BV
1C5C60|Shenzhen Belzon Technology Co.,LTD.
1C5CF2|Apple, Inc.
1C5EE6|SHENZHEN TWOWING TECHNOLOGIES CO.,LTD.
1C5F2B|D-Link International
1C5FFF|Beijing Ereneben Information Technology Co.,Ltd Shenzhen Branch
1C60D2|Fiberhome Telecommunication Technologies Co.,LTD
1C61B4|TP-Link Systems Inc
1C61BF|Apple, Inc.
1C627E|HUAWEI TECHNOLOGIES CO.,LTD
1C62B8|Samsung Electronics Co.,Ltd
1C63BF|SHENZHEN BROADTEL TELECOM CO.,LTD
1C64F0|Motorola Mobility LLC, a Lenovo Company
1C659D|Liteon Technology Corporation
1C666D|Hon Hai Precision Ind. Co.,Ltd.
1C66AA|Samsung Electronics Co.,Ltd
1C674A|zte corporation
1C6758|HUAWEI TECHNOLOGIES CO.,LTD
1C687E|Shenzhen Qihu Intelligent Technology Company Limited
1C6920|Espressif Inc.
1C6A1B|Ubiquiti Inc
1C6A76|Apple, Inc.
1C6A7A|Cisco Systems, Inc
1C6F65|GIGA-BYTE TECHNOLOGY CO.,LTD.
1C7055|HUAWEI TECHNOLOGIES CO.,LTD
1C7125|Apple, Inc.
1C721D|Dell Inc.
1C73E2|HUAWEI TECHNOLOGIES CO.,LTD
1C740D|Zyxel Communications Corporation
1C7508|COMPAL INFORMATION (KUNSHAN) CO., LTD.
1C76F2|Samsung Electronics Co.,Ltd
1C7754|Apple, Inc.
1C7839|Shenzhen Tencent Computer System Co., Ltd.
1C7B21|Sony Corporation
1C7EE5|D-Link International
1C7F2C|HUAWEI TECHNOLOGIES CO.,LTD
1C84A6|Cisco Systems, Inc
1C8682|Apple, Inc.
1C869A|Samsung Electronics Co.,Ltd
1C872C|ASUSTek COMPUTER INC.
1C880C|Shenzhen Skyworth Digital Technology CO., Ltd
1C8B84|Espressif Systems (Singapore) Pte. Ltd
1C8BEF|Beijing Xiaomi Electronics Co.,Ltd
1C8E2A|Apple, Inc.
1C8E5C|HUAWEI TECHNOLOGIES CO.,LTD
1C8F57|Espressif Inc.
1C90FF|Tuya Smart Inc.
1C9148|Apple, Inc.
1C9180|Apple, Inc.
1C93C4|Amazon Technologies Inc.
1C984B|Extreme Networks, Inc.
1C98EC|Hewlett Packard Enterprise
1C9957|Intel Corporate
1C99DB|HUAWEI TECHNOLOGIES CO.,LTD
1C9C8C|Juniper Networks
1C9DC2|Espressif Inc.
1C9E46|Apple, Inc.
1CA0B8|Hon Hai Precision Industry Co., Ltd.
1CA532|SHENZHEN GONGJIN ELECTRONICS CO.,LT
1CA681|HUAWEI TECHNOLOGIES CO.,LTD
1CA770|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
1CAA07|Cisco Systems, Inc
1CABA7|Apple, Inc.
1CAECB|HUAWEI TECHNOLOGIES CO.,LTD
1CAF05|Samsung Electronics Co.,Ltd
1CAF4A|Samsung Electronics Co.,Ltd
1CAFF7|D-Link International
1CB3C9|Apple, Inc.
1CB3E9|Shenzhen Zhongke United Communication Technology
1CB46C|HUAWEI TECHNOLOGIES CO.,LTD
1CB72C|ASUSTek COMPUTER INC.
1CB796|HUAWEI TECHNOLOGIES CO.,LTD
1CB9C4|Ruckus Wireless
1CBDB9|D-Link International
1CBFCE|Shenzhen Century Xinyang Technology Co., Ltd
1CC10C|Intel Corporate
1CC1DE|Hewlett Packard
1CC212|Fortinet, Inc.
1CC3AB|Espressif Inc.
1CC72D|Shenzhen Huapu Digital CO.,Ltd
1CCCD6|Xiaomi Communications Co Ltd
1CCE51|AzureWave Technology Inc.
1CCF82|Palo Alto Networks
1CD11A|Fortinet, Inc.
1CD1BA|Fiberhome Telecommunication Technologies Co.,LTD
1CD1E0|Cisco Systems, Inc
1CD21E|Juniper Networks
1CD5E2|Shenzhen YOUHUA Technology Co., Ltd
1CDBD4|Espressif Inc.
1CDE57|Fiberhome Telecommunication Technologies Co.,LTD
1CDEA7|Cisco Systems, Inc
1CDF0F|Cisco Systems, Inc
1CE209|Apple, Inc.
1CE4CB|Espressif Systems (Singapore) Pte. Ltd
1CE4DD|Technicolor (China) Technology Co., Ltd.
1CE504|HUAWEI TECHNOLOGIES CO.,LTD
1CE57F|Samsung Electronics Co.,Ltd
1CE587|Cisco Meraki
1CE61D|Samsung Electronics Co.,Ltd
1CE62B|Apple, Inc.
1CE639|HUAWEI TECHNOLOGIES CO.,LTD
1CE6AD|Huawei Device Co., Ltd.
1CE6C7|Cisco Systems, Inc
1CE85D|Cisco Systems, Inc
1CEA1B|Nokia
1CEAAC|Beijing Xiaomi Mobile Software Co., Ltd
1CF29A|Google, Inc.
1CF42B|Huawei Device Co., Ltd.
1CF64C|Apple, Inc.
1CF8D0|Samsung Electronics Co.,Ltd
1CF9D5|Apple, Inc.
1CFA68|TP-LINK TECHNOLOGIES CO.,LTD.
1CFC17|Cisco Systems, Inc
1CFC2A|HUAWEI TECHNOLOGIES CO.,LTD
1CFE2B|Amazon Technologies Inc.
1CFFAD|HUAWEI TECHNOLOGIES CO.,LTD
20040F|Dell Inc.
200484|Apple, Inc.
200889|zte corporation
2008ED|HUAWEI TECHNOLOGIES CO.,LTD
200B74|AzureWave Technology Inc.
200BC5|Cisco Systems, Inc
200BC7|HUAWEI TECHNOLOGIES CO.,LTD
200CC8|NETGEAR
200DB0|Shenzhen Four Seas Global Link Network Technology Co., Ltd.
200E0F|Panasonic Marketing Middle East & Africa FZE
200E2B|Apple, Inc.
20108A|zte corporation
2010B1|Amazon Technologies Inc.
2013E0|Samsung Electronics Co.,Ltd
2014C4|HUAWEI TECHNOLOGIES CO.,LTD
201582|Apple, Inc.
2015DE|Samsung Electronics Co.,Ltd
201642|Microsoft Corporation
2016B9|Intel Corporate
2016D8|Liteon Technology Corporation
201742|LG Electronics
20180E|Shenzhen Sunchip Technology Co., Ltd
20185B|Shenzhen Jingxun Technology Co., Ltd.
201A06|COMPAL INFORMATION (KUNSHAN) CO., LTD.
201A94|Apple, Inc.
201BC9|Juniper Networks
201E1D|HUAWEI TECHNOLOGIES CO.,LTD
201E88|Intel Corporate
201F3B|Google, Inc.
202027|Shenzhen Sundray Technologies company Limited
202051|zte corporation
2021A5|LG Electronics (Mobile Communications)
202351|TP-Link Systems Inc
202564|PEGATRON CORPORATION
202565|Espressif Inc.
2025CC|Xiaomi Communications Co Ltd
2025D2|Fiberhome Telecommunication Technologies Co.,LTD
202680|Samsung Electronics Co.,Ltd
20283E|HUAWEI TECHNOLOGIES CO.,LTD
202BC1|HUAWEI TECHNOLOGIES CO.,LTD
202C05|ZHEJIANG DAHUA ZHILIAN CO.,LTD
202D07|Samsung Electronics Co.,Ltd
202DF6|Apple, Inc.
203233|SHENZHEN BILIAN ELECTRONIC CO.，LTD
20326C|Samsung Electronics Co.,Ltd
2032C6|Apple, Inc.
203389|Google, Inc.
203462|Xiaomi Communications Co Ltd
2034FB|Xiaomi Communications Co Ltd
203543|Sagemcom Broadband SAS
203626|TP-Link Systems Inc
2036D0|Motorola Mobility LLC, a Lenovo Company
203706|Cisco Systems, Inc
2037A5|Apple, Inc.
203A07|Cisco Systems, Inc
203A43|Intel Corporate
203AEB|zte corporation
203B34|Xiaomi Communications Co Ltd
203B67|Samsung Electronics Co.,Ltd
203CAE|Apple, Inc.
203DB2|HUAWEI TECHNOLOGIES CO.,LTD
2043A8|Espressif Inc.
20443A|Schneider Electric Asia Pacific Ltd
20463A|Apple, Inc.
204747|Dell Inc.
2047B5|Sagemcom Broadband SAS
2047DA|Xiaomi Communications Co Ltd
204C03|Hewlett Packard Enterprise
204C9E|Cisco Systems, Inc
204E71|Juniper Networks
204E7F|NETGEAR
204EF6|AzureWave Technology Inc.
20500D|Espressif Inc.
20521D|Apple, Inc.
205383|HUAWEI TECHNOLOGIES CO.,LTD
20538D|Hon Hai Precision Industry Co., Ltd.
205476|Sony Corporation
2054FA|HUAWEI TECHNOLOGIES CO.,LTD
205531|Samsung Electronics Co.,Ltd
20579E|HUNAN FN-LINK TECHNOLOGY LIMITED
2057AF|Shenzhen FH-NET OPTOELECTRONICS CO.,LTD
205869|Ruckus Wireless
205A1D|zte corporation
205A8F|Shenzhen Hikeen Technology Co.,LTD
205B5E|Shenzhen Wonhe Technology Co., Ltd
205D0D|Fiberhome Telecommunication Technologies Co.,LTD
205E64|Huawei Device Co., Ltd.
205E97|Nokia
205EF7|Samsung Electronics Co.,Ltd
206274|Microsoft Corporation
206296|Shenzhen Malio Technology Co.,Ltd
206432|SAMSUNG ELECTRO MECHANICS CO., LTD.
20658E|HUAWEI TECHNOLOGIES CO.,LTD
20677C|Hewlett Packard Enterprise
2067E0|Shenzhen iComm Semiconductor CO.,LTD
20689D|Liteon Technology Corporation
206980|Apple, Inc.
206A8A|Wistron Infocomm (Zhongshan) Corporation
206BE7|TP-LINK TECHNOLOGIES CO.,LTD.
206BF4|Huawei Device Co., Ltd.
206C8A|Extreme Networks, Inc.
206E9C|Samsung Electronics Co.,Ltd
206EF1|Espressif Inc.
2072A9|Beijing Xiaomi Electronics Co.,Ltd
2074CF|Shenzhen Voxtech Co.,Ltd
20768F|Apple, Inc.
207693|Lenovo (Beijing) Limited.
207759|OPTICAL NETWORK VIDEO TECHNOLOGIES (SHENZHEN) CO., LTD.
207852|Nokia Solutions and Networks GmbH & Co. KG
2078CD|Apple, Inc.
2078F0|Apple, Inc.
207918|Intel Corporate
207C8F|Quanta Microsystems,Inc.
207D74|Apple, Inc.
208097|Shenzhen OXO Technology limited
2082C0|Xiaomi Communications Co Ltd
20845F|Apple, Inc.
2084F5|Yufei Innovation Software(Shenzhen) Co., Ltd.
2087EC|HUAWEI TECHNOLOGIES CO.,LTD
208810|Dell Inc.
20896F|Fiberhome Telecommunication Technologies Co.,LTD
208984|COMPAL INFORMATION (KUNSHAN) CO., LTD.
208986|zte corporation
20898A|Shenzhen Skyworth Digital Technology CO., Ltd
208B37|Skyworth Digital Technology(Shenzhen) Co.,Ltd
208C0A|Apple, Inc.
208C86|HUAWEI TECHNOLOGIES CO.,LTD
20906F|Shenzhen Tencent Computer System Co., Ltd.
2091DF|Apple, Inc.
209339|Juniper Networks
20988E|Shenzhen Feasycom Co., Ltd
2098D8|Shenzhen Yingdakang Technology CO., LTD
209952|Xiaomi Communications Co Ltd
209A7D|Sagemcom Broadband SAS
209BA9|Espressif Inc.
209BCD|Apple, Inc.
209BDD|HUAWEI TECHNOLOGIES CO.,LTD
209CB4|Hewlett Packard Enterprise
209EF7|Extreme Networks, Inc.
20A171|Amazon Technologies Inc.
20A200|HUAWEI TECHNOLOGIES CO.,LTD
20A2E4|Apple, Inc.
20A5CB|Apple, Inc.
20A60C|Xiaomi Communications Co Ltd
20A680|HUAWEI TECHNOLOGIES CO.,LTD
20A6CD|Hewlett Packard Enterprise
20A766|HUAWEI TECHNOLOGIES CO.,LTD
20A7F9|SHENZHEN OLANBOA TECHNOLOGY CO., LTD
20A8BF|HUAWEI TECHNOLOGIES CO.,LTD
20A99B|Microsoft Corporation
20AA4B|Cisco-Linksys, LLC
20AB37|Apple, Inc.
20AB48|HUAWEI TECHNOLOGIES CO.,LTD
20AB53|Motorola Mobility LLC, a Lenovo Company
20AEB6|Huawei Device Co., Ltd.
20B780|Toshiba Visual Solutions Corporation Co.,Ltd
20B82B|Sagemcom Broadband SAS
20B868|Motorola Mobility LLC, a Lenovo Company
20BBC0|Cisco Systems, Inc
20BD1D|Intel Corporate
20BEB8|Amazon Technologies Inc.
20C06D|SHENZHEN SPACETEK TECHNOLOGY CO.,LTD
20C19B|Intel Corporate
20C2B0|HUAWEI TECHNOLOGIES CO.,LTD
20C6EB|Panasonic Corporation AVC Networks Company
20C8B3|SHENZHEN BUL-TECH CO.,LTD.
20C9D0|Apple, Inc.
20CC27|Cisco Systems, Inc
20CC73|Samsung Electronics Co.,Ltd
20CF30|ASUSTek COMPUTER INC.
20CFAE|Cisco Systems, Inc
20D390|Samsung Electronics Co.,Ltd
20D476|Amazon Technologies Inc.
20D5BF|Samsung Electronics Co.,Ltd
20D5C2|Espressif Systems (Singapore) Pte. Ltd
20D607|Nokia Corporation
20D80B|Juniper Networks
20DA22|HUAWEI TECHNOLOGIES CO.,LTD
20DBAB|Samsung Electronics Co., Ltd.
20DBEA|Cisco Systems, Inc
20DCE6|TP-LINK TECHNOLOGIES CO.,LTD.
20DCFD|Huawei Device Co., Ltd.
20DE1E|Nokia
20DF73|HUAWEI TECHNOLOGIES CO.,LTD
20DFB9|Google, Inc.
20E09C|Nokia
20E15D|TP-Link Systems Inc.
20E2A8|Apple, Inc.
20E525|Huawei Device Co., Ltd.
20E52A|NETGEAR
20E59B|Panasonic Automotive Systems
20E7C8|Espressif Inc.
20E874|Apple, Inc.
20E882|zte corporation
20EAC7|SHENZHEN RIOPINE ELECTRONICS CO., LTD
20ED47|Juniper Networks
20EE28|Apple, Inc.
20EFBD|Roku, Inc
20F094|Google, Inc.
20F120|Cisco Systems, Inc
20F17C|HUAWEI TECHNOLOGIES CO.,LTD
20F1B2|Tuya Smart Inc.
20F307|zte corporation
20F3A3|HUAWEI TECHNOLOGIES CO.,LTD
20F41B|SHENZHEN BILIAN ELECTRONIC CO.，LTD
20F44F|Nokia
20F478|Xiaomi Communications Co Ltd
20F4D4|Apple, Inc.
20FA85|Apple, Inc.
20FE00|Amazon Technologies Inc.
20FF0C|HUAWEI TECHNOLOGIES CO.,LTD
2400BA|HUAWEI TECHNOLOGIES CO.,LTD
24016F|Huawei Device Co., Ltd.
2401C7|Cisco Systems, Inc
240588|Google, Inc.
240935|Samsung Electronics Co.,Ltd
240995|HUAWEI TECHNOLOGIES CO.,LTD
240A3F|Samsung Electronics Co.,Ltd
240A64|AzureWave Technology Inc.
240AC4|Espressif Inc.
240B0A|Palo Alto Networks
240D65|Shenzhen Vsun Communication Technology Co., Ltd.
240F5E|Shenzhen z-router Technology Co., Ltd
240F9B|Hangzhou Hikvision Digital Technology Co.,Ltd.
241064|Shenzhen Ecsino Tecnical Co. Ltd
241145|Xiaomi Communications Co Ltd
241153|Samsung Electronics Co.,Ltd
241551|Huawei Device Co., Ltd.
24161B|Cisco Systems, Inc
241651|Chipsea Technologies (Shenzhen) Corp.
24166D|HUAWEI TECHNOLOGIES CO.,LTD
24169D|Cisco Systems, Inc
24181D|SAMSUNG ELECTRO-MECHANICS(THAILAND)
2418C6|HUNAN FN-LINK TECHNOLOGY LIMITED
241AE6|Huawei Device Co., Ltd.
241B7A|Apple, Inc.
241C04|SHENZHEN JEHE TECHNOLOGY DEVELOPMENT CO., LTD.
241EEB|Apple, Inc.
241FA0|HUAWEI TECHNOLOGIES CO.,LTD
241FBD|Extreme Networks, Inc.
2420C7|Sagemcom Broadband SAS
242124|Nokia
2421AB|Sony Corporation
24240E|Apple, Inc.
2424B7|Samsung Electronics Co.,Ltd
242642|SHARP Corporation.
2426BA|Shenzhen Toptel Technology Co., Ltd.
2426D6|HUAWEI TECHNOLOGIES CO.,LTD
2427E5|Huawei Device Co., Ltd.
2428FD|Hangzhou Hikvision Digital Technology Co.,Ltd.
242934|Google, Inc.
2429B0|HUAWEI TECHNOLOGIES CO.,LTD
2429FE|KYOCERA Corporation
242A04|Cisco Systems, Inc
242AEA|Apple, Inc.
242E02|HUAWEI TECHNOLOGIES CO.,LTD
242FD0|TP-Link Systems Inc
242FFA|Toshiba Global Commerce Solutions
2430F8|Huawei Device Co., Ltd.
243154|HUAWEI TECHNOLOGIES CO.,LTD
243184|SHARP Corporation
2432AE|Hangzhou Hikvision Digital Technology Co.,Ltd.
2436DA|Cisco Systems, Inc
24374C|Cisco SPVTG
243FAA|Huawei Device Co., Ltd.
24418C|Intel Corporate
2442E3|Shenzhen Ai-Thinker Technology Co.,Ltd
244427|HUAWEI TECHNOLOGIES CO.,LTD
24456B|Huawei Device Co., Ltd.
2446C8|Motorola Mobility LLC, a Lenovo Company
2446E4|HUAWEI TECHNOLOGIES CO.,LTD
244750|Sagemcom Broadband SAS
244845|Hangzhou Hikvision Digital Technology Co.,Ltd.
244885|Huawei Device Co., Ltd.
244B03|Samsung Electronics Co.,Ltd
244B81|Samsung Electronics Co.,Ltd
244BF1|HUAWEI TECHNOLOGIES CO.,LTD
244BFE|ASUSTek COMPUTER INC.
244C07|HUAWEI TECHNOLOGIES CO.,LTD
244CAB|Espressif Inc.
244CE3|Amazon Technologies Inc.
244ECD|Sagemcom Broadband SAS
24526A|Zhejiang Dahua Technology Co., Ltd.
2453ED|Dell Inc.
24559A|Apple, Inc.
24586E|zte corporation
24587C|Espressif Inc.
245A4C|Ubiquiti Inc
245A5F|TP-LINK TECHNOLOGIES CO.,LTD.
245AB5|Samsung Electronics Co.,Ltd
245BA7|Apple, Inc.
245BF0|Liteon, Inc.
245CC5|Huawei Device Co., Ltd.
245D92|Juniper Networks
245E48|Apple, Inc.
245EBE|QNAP Systems, Inc.
245F9F|Huawei Device Co., Ltd.
245FDF|KYOCERA CORPORATION
246078|HUAWEI TECHNOLOGIES CO.,LTD
2460B3|Samsung Electronics Co.,Ltd
2462AB|Espressif Inc.
2462C6|Huawei Device Co., Ltd.
2462CE|Hewlett Packard Enterprise
246477|Beijing Xiaomi Mobile Software Co., Ltd
24649F|Huawei Device Co., Ltd.
246800|Samsung Electronics Co.,Ltd
246830|Shenzhen Shokzhear Co., Ltd
2468B0|Samsung Electronics Co.,Ltd
246968|TP-LINK TECHNOLOGIES CO.,LTD.
24698E|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
2469A5|HUAWEI TECHNOLOGIES CO.,LTD
246A0E|HP Inc.
246C60|Huawei Device Co., Ltd.
246C84|Cisco Systems, Inc
246D10|Apple, Inc.
246E96|Dell Inc.
246F28|Espressif Inc.
246F8C|Huawei Device Co., Ltd.
247121|Cisco Systems, Inc
247152|Dell Inc.
2475FC|zte corporation
247645|Huawei Device Co., Ltd.
24767D|Cisco SPVTG
247703|Intel Corporate
247755|Huawei Device Co., Ltd.
247823|Panasonic Entertainment & Communication Co., Ltd.
2478EF|Nokia
24792A|Ruckus Wireless
247E12|Cisco Systems, Inc
247E51|zte corporation
247F20|Sagemcom Broadband SAS
247F3C|HUAWEI TECHNOLOGIES CO.,LTD
24813B|Cisco Systems, Inc
24814E|AMD
248185|Extreme Networks, Inc.
2481C7|Huawei Device Co., Ltd.
248894|shenzhen lensun Communication Technology LTD
2491BB|HUAWEI TECHNOLOGIES CO.,LTD
24920E|Samsung Electronics Co.,Ltd
24952F|Google, Inc.
249745|HUAWEI TECHNOLOGIES CO.,LTD
249AC8|Shenzhen Skyworth Digital Technology CO., Ltd
249AD8|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
249EAB|HUAWEI TECHNOLOGIES CO.,LTD
24A02D|shenzhen worldelite electronics co., LTD
24A074|Apple, Inc.
24A160|Espressif Inc.
24A2E1|Apple, Inc.
24A43C|Ubiquiti Inc
24A452|Samsung Electronics Co.,Ltd
24A487|Huawei Device Co., Ltd.
24A52C|HUAWEI TECHNOLOGIES CO.,LTD
24A65E|zte corporation
24A799|Huawei Device Co., Ltd.
24A87D|Panasonic Automotive Systems Asia Pacific(Thailand)Co.,Ltd.
24AB81|Apple, Inc.
24B105|Prama Hikvision India Private Limited
24B209|Avaya Inc
24B2B9|Liteon Technology Corporation
24B2DE|Espressif Inc.
24B339|Apple, Inc.
24B5B9|Motorola Mobility LLC, a Lenovo Company
24B657|Cisco Systems, Inc
24B6FD|Dell Inc.
24B7DA|Fiberhome Telecommunication Technologies Co.,LTD
24BA23|Cisco Systems, Inc
24BBC9|Shenzhen SuperElectron Technology Co.,Ltd.
24BCF8|HUAWEI TECHNOLOGIES CO.,LTD
24BE05|Hewlett Packard
24C013|zte corporation
24C42F|Philips Lifeline
24C44A|zte corporation
24C613|Samsung Electronics Co.,Ltd
24C696|Samsung Electronics Co.,Ltd
24C9A1|Ruckus Wireless
24CACB|Fiberhome Telecommunication Technologies Co.,LTD
24CE33|Amazon Technologies Inc.
24CF21|Shenzhen State Micro Technology Co., Ltd
24CF24|Beijing Xiaomi Mobile Software Co., Ltd
24D0DF|Apple, Inc.
24D1A1|Shenzhen Cultraview Digital Technology Co., Ltd
24D337|Xiaomi Communications Co Ltd
24D3F2|zte corporation
24D53B|Motorola Mobility LLC, a Lenovo Company
24D5E4|Cisco Systems, Inc
24D79C|Cisco Systems, Inc
24D7EB|Espressif Inc.
24D921|Avaya Inc
24DA33|HUAWEI TECHNOLOGIES CO.,LTD
24DA9B|Motorola Mobility LLC, a Lenovo Company
24DB94|Juniper Networks
24DBAC|HUAWEI TECHNOLOGIES CO.,LTD
24DBED|Samsung Electronics Co.,Ltd
24DCC3|Espressif Inc.
24DE8A|Nokia Solutions and Networks GmbH & Co. KG
24DEC6|Hewlett Packard Enterprise
24DEEB|HUAWEI TECHNOLOGIES CO.,LTD
24DF17|Shenzhen Sande Dacom Electronics Co., Ltd
24DF6A|HUAWEI TECHNOLOGIES CO.,LTD
24E29D|Huawei Device Co., Ltd.
24E314|Apple, Inc.
24E3A4|Fiberhome Telecommunication Technologies Co.,LTD
24E4C8|Fiberhome Telecommunication Technologies Co.,LTD
24E50F|Google, Inc.
24E5AA|Philips Oral Healthcare, Inc.
24E8E5|Shenzhen Skyworth Digital Technology CO., Ltd
24E9B3|Cisco Systems, Inc
24E9CA|Huawei Device Co., Ltd.
24EA9B|HUAWEI TECHNOLOGIES CO.,LTD
24EB16|Intel Corporate
24EBED|HUAWEI TECHNOLOGIES CO.,LTD
24EC4A|Espressif Inc.
24EE9A|Intel Corporate
24F094|Apple, Inc.
24F0D3|Samsung Electronics Co.,Ltd
24F27F|Hewlett Packard Enterprise
24F40A|Samsung Electronics Co.,Ltd
24F5AA|Samsung Electronics Co.,Ltd
24F603|HUAWEI TECHNOLOGIES CO.,LTD
24F677|Apple, Inc.
24F68D|Nokia
24FAD4|ShenZhen More Star Technology Co.,LTD
24FAD6|EMSTONE
24FB65|HUAWEI TECHNOLOGIES CO.,LTD
24FBE3|HP Inc.
24FC4E|Juniper Networks
24FCE5|Samsung Electronics Co.,Ltd
24FD0D|Intelbras
24FD52|Liteon Technology Corporation
2800AF|Dell Inc.
28011C|zte corporation
28022E|Apple, Inc.
280244|Apple, Inc.
2802D8|Samsung Electronics Co.,Ltd
2803E6|Nokia
2805A5|Espressif Inc.
280708|Samsung Electronics Co.,Ltd
280B5C|Apple, Inc.
280C50|Intel Corporate
280DFC|Sony Interactive Entertainment Inc.
28107B|D-Link International
2811A8|Intel Corporate
2811EC|HUAWEI TECHNOLOGIES CO.,LTD
2812D0|Motorola Mobility LLC, a Lenovo Company
2815A4|SHENZHEN PINSU ZHILIAN INFORMATION TECHNOLOGY CO.,LTD.
28167F|Xiaomi Communications Co Ltd
2816A8|Microsoft Corporation
2816AD|Intel Corporate
281709|HUAWEI TECHNOLOGIES CO.,LTD
28172E|Fiberhome Telecommunication Technologies Co.,LTD
281878|Microsoft Corporation
281DFB|HUAWEI TECHNOLOGIES CO.,LTD
28221E|HUAWEI TECHNOLOGIES CO.,LTD
2824C9|Amazon Technologies Inc.
282536|SHENZHEN HOLATEK CO.,LTD
2827BF|Samsung Electronics Co.,Ltd
28285D|Zyxel Communications Corporation
282947|Chipsea Technologies (Shenzhen) Corp.
282986|APC by Schneider Electric
282B96|Huawei Device Co., Ltd.
282BB9|Shenzhen Xiongxin Technology Co.,Ltd
282CB2|TP-LINK TECHNOLOGIES CO.,LTD.
282CC4|HUAWEI TECHNOLOGIES CO.,LTD
282D7F|Apple, Inc.
283152|HUAWEI TECHNOLOGIES CO.,LTD
2831F8|HUAWEI TECHNOLOGIES CO.,LTD
283334|Huawei Device Co., Ltd.
2834A2|Cisco Systems, Inc
2834FF|Apple, Inc.
28353A|HUAWEI TECHNOLOGIES CO.,LTD
283545|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
2836F0|Huawei Device Co., Ltd.
283713|Shenzhen 3Nod Digital Technology Co., Ltd.
28372F|Espressif Inc.
283737|Apple, Inc.
28395E|Samsung Electronics Co.,Ltd
283B82|D-Link International
283CE4|HUAWEI TECHNOLOGIES CO.,LTD
283DC2|Samsung Electronics Co.,Ltd
283F69|Sony Corporation
2840DD|Sony Interactive Entertainment Inc.
2841C6|HUAWEI TECHNOLOGIES CO.,LTD
2841EC|HUAWEI TECHNOLOGIES CO.,LTD
2845AC|Huawei Device Co., Ltd.
2847AA|Nokia Corporation
2848E7|Huawei Device Co., Ltd.
2849E9|Apple, Inc.
284B54|Apple, Inc.
284D7D|zte corporation
284E44|HUAWEI TECHNOLOGIES CO.,LTD
285132|Shenzhen Prayfly Technology Co.,Ltd
285261|Cisco Systems, Inc
2852F9|Zhongxin Intelligent Times (Shenzhen) Co., Ltd.
28534E|HUAWEI TECHNOLOGIES CO.,LTD
285471|Huawei Device Co., Ltd.
28562F|Espressif Inc.
28563A|Fiberhome Telecommunication Technologies Co.,LTD
28565A|Hon Hai Precision Ind. Co.,Ltd.
28575D|Apple, Inc.
2857BE|Hangzhou Hikvision Digital Technology Co.,Ltd.
285923|Xiaomi Communications Co Ltd
285AEB|Apple, Inc.
285FDB|HUAWEI TECHNOLOGIES CO.,LTD
2864B0|Huawei Device Co., Ltd.
2864EF|Shenzhen Fsan Intelligent Technology Co.,Ltd
28656B|Keystone Microtech Corporation
2866E3|AzureWave Technology Inc.
2868D2|HUAWEI TECHNOLOGIES CO.,LTD
286AB8|Apple, Inc.
286ABA|Apple, Inc.
286B35|Intel Corporate
286B5C|Cisco Systems, Inc
286C07|XIAOMI Electronics,CO.,LTD
286DDA|Fiberhome Telecommunication Technologies Co.,LTD
286ED4|HUAWEI TECHNOLOGIES CO.,LTD
286F7F|Cisco Systems, Inc
286FB9|Nokia Shanghai Bell Co., Ltd.
28704E|Ubiquiti Inc
2872C6|Samsung Electronics Co.,Ltd
2873F6|Amazon Technologies Inc.
2874F5|Nokia Solutions and Networks GmbH & Co. KG
287777|zte corporation
2877F1|Apple, Inc.
287994|Realplay Digital Technology(Shenzhen) Co.,Ltd
287AB4|HUAWEI TECHNOLOGIES CO.,LTD
287B09|zte corporation
287FCF|Intel Corporate
288023|Hewlett Packard
288088|NETGEAR
28808A|HUAWEI TECHNOLOGIES CO.,LTD
288335|Samsung Electronics Co.,Ltd
2883C9|Apple, Inc.
288485|Espressif Inc.
2884FA|SHARP Corporation
2887BA|TP-Link Systems Inc
288A1C|Juniper Networks
288CB8|zte corporation
288EEC|Apple, Inc.
288FF6|Apple, Inc.
289104|TP-Link Systems Inc.
289200|Intel Corporate
28924A|Hewlett Packard
2893FE|Cisco Systems, Inc
289401|NETGEAR
28940F|Cisco Systems, Inc
289529|Intel Corporate
2896B0|HUAWEI TECHNOLOGIES CO.,LTD
28987B|Samsung Electronics Co.,Ltd
289E97|HUAWEI TECHNOLOGIES CO.,LTD
289EFC|Sagemcom Broadband SAS
289F04|Samsung Electronics Co.,Ltd
28A02B|Apple, Inc.
28A06B|Intel Corporate
28A1EB|ETEK TECHNOLOGY (SHENZHEN) CO.,LTD
28A24B|Juniper Networks
28A44A|Intel Corporate
28A5EE|Shenzhen SDGI CATV Co., Ltd
28A6DB|HUAWEI TECHNOLOGIES CO.,LTD
28A9AE|HUAWEI TECHNOLOGIES CO.,LTD
28AC9E|Cisco Systems, Inc
28AD3E|Shenzhen TONG BO WEI Technology CO.,LTD
28AF21|zte corporation
28AF42|Samsung Electronics Co.,Ltd
28AFE5|Shenzhen C-Data Technology Co., Ltd.
28AFFD|Cisco Systems, Inc
28B133|SHINEMAN(SHENZHEN) Tech. Cor., Ltd.
28B2BD|Intel Corporate
28B371|Ruckus Wireless
28B446|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
28B448|HUAWEI TECHNOLOGIES CO.,LTD
28B591|Cisco Systems, Inc
28B829|Juniper Networks
28BAB5|Samsung Electronics Co.,Ltd
28BD89|Google, Inc.
28BF89|Fiberhome Telecommunication Technologies Co.,LTD
28C01B|Shenzhen Skyworth Digital Technology CO., Ltd
28C039|HUAWEI TECHNOLOGIES CO.,LTD
28C0DA|Juniper Networks
28C13C|Hon Hai Precision Industry Co., Ltd.
28C1A0|Apple, Inc.
28C21F|SAMSUNG ELECTRO-MECHANICS(THAILAND)
28C2DD|AzureWave Technology Inc.
28C538|Apple, Inc.
28C5C8|HP Inc.
28C5D2|Intel Corporate
28C63F|Intel Corporate
28C68E|NETGEAR
28C709|Apple, Inc.
28C7CE|Cisco Systems, Inc
28C825|DellKing Industrial Co., Ltd
28C87C|zte corporation
28CB5C|Shenzhen CPETEK Technology Co.,Ltd.
28CC01|Samsung Electronics Co.,Ltd
28CD9C|Shenzhen Dynamax Software Development Co.,Ltd.
28CDC1|Raspberry Pi Trading Ltd
28CE15|Shenzhen Xinwei Intelligent Co., Ltd
28CFDA|Apple, Inc.
28CFE9|Apple, Inc.
28D043|AzureWave Technology Inc.
28D044|Shenzhen Xinyin technology company
28D0EA|Intel Corporate
28D127|Beijing Xiaomi Mobile Software Co., Ltd
28D1AF|Nokia Corporation
28D1B7|Shenzhen YOUHUA Technology Co., Ltd
28D244|LCFC(Hefei) Electronics Technology co., ltd
28D3EA|Huawei Device Co., Ltd.
28D5B1|Apple, Inc.
28D6EC|HUAWEI TECHNOLOGIES CO.,LTD
28DB02|zte corporation
28DCC3|HUAWEI TECHNOLOGIES CO.,LTD
28DE1C|Samsung Electronics Co.,Ltd
28DE65|Hewlett Packard Enterprise
28DEA8|zte corporation
28DEE5|HUAWEI TECHNOLOGIES CO.,LTD
28DFEB|Intel Corporate
28E02C|Apple, Inc.
28E14C|Apple, Inc.
28E31F|Xiaomi Communications Co Ltd
28E347|Liteon Technology Corporation
28E34E|HUAWEI TECHNOLOGIES CO.,LTD
28E5B0|HUAWEI TECHNOLOGIES CO.,LTD
28E6A9|Samsung Electronics Co.,Ltd
28E7CF|Apple, Inc.
28EA0B|Microsoft Corporation
28EA2D|Apple, Inc.
28EC95|Apple, Inc.
28ED6A|Apple, Inc.
28EE52|TP-LINK TECHNOLOGIES CO.,LTD.
28EED3|Shenzhen Super D Technology Co., Ltd
28EF01|Amazon Technologies Inc.
28F033|Apple, Inc.
28F076|Apple, Inc.
28F10E|Dell Inc.
28F366|SHENZHEN BILIAN ELECTRONIC CO.，LTD
28F52B|FN-LINK TECHNOLOGY Ltd.
28F7D6|Fiberhome Telecommunication Technologies Co.,LTD
28FA19|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
28FBAE|HUAWEI TECHNOLOGIES CO.,LTD
28FCF6|Shenzhen Xin KingBrand enterprises Co.,Ltd
28FF3C|Apple, Inc.
28FF3E|zte corporation
28FFB2|Toshiba Corp.
2C002A|Shenzhen TINNO Mobile Technology Corp.
2C01B5|Cisco Systems, Inc
2C0547|Shenzhen Phaten Tech. LTD
2C0786|Huawei Device Co., Ltd.
2C08B4|Huawei Device Co., Ltd.
2C0B97|Xiaomi Communications Co Ltd
2C0BAB|HUAWEI TECHNOLOGIES CO.,LTD
2C0BE9|Cisco Systems, Inc
2C0D27|Huawei Device Co., Ltd.
2C0DA7|Intel Corporate
2C0DCF|Xiaomi Communications Co Ltd
2C0E3D|SAMSUNG ELECTRO-MECHANICS(THAILAND)
2C15BF|Samsung Electronics Co.,Ltd
2C15D9|HUAWEI TECHNOLOGIES CO.,LTD
2C1809|Apple, Inc.
2C1875|Skyworth Digital Technology(Shenzhen) Co.,Ltd
2C195C|Beijing Xiaomi Mobile Software Co., Ltd
2C1A01|HUAWEI TECHNOLOGIES CO.,LTD
2C1A05|Cisco Systems, Inc
2C1CF7|Apple, Inc.
2C1F23|Apple, Inc.
2C200B|Apple, Inc.
2C2080|Huawei Device Co., Ltd.
2C2131|Juniper Networks
2C2172|Juniper Networks
2C233A|Hewlett Packard
2C26C5|zte corporation
2C2768|HUAWEI TECHNOLOGIES CO.,LTD
2C27D7|Hewlett Packard
2C2997|Microsoft Corporation
2C2B86|Sagemcom Broadband SAS
2C301A|Technicolor CH USA Inc for Telus
2C3033|NETGEAR
2C3124|Cisco Systems, Inc
2C326A|Apple, Inc.
2C3311|Cisco Systems, Inc
2C3358|Intel Corporate
2C3361|Apple, Inc.
2C337A|Hon Hai Precision Ind. Co.,Ltd.
2C347B|SHENZHEN JUNGE TECHNOLOGY CO.,LTD
2C36F2|HUAWEI TECHNOLOGIES CO.,LTD
2C36F8|Cisco Systems, Inc
2C3731|SHENZHEN YIFANG DIGITAL TECHNOLOGY CO.,LTD.
2C3996|Sagemcom Broadband SAS
2C3A91|Huawei Device Co., Ltd.
2C3AB1|Huawei Device Co., Ltd.
2C3AE8|Espressif Inc.
2C3B70|AzureWave Technology Inc.
2C3ECF|Cisco Systems, Inc
2C3F0B|Cisco Meraki
2C3F38|Cisco Systems, Inc
2C4053|Samsung Electronics Co.,Ltd
2C4138|Hewlett Packard
2C431A|Shenzhen YOUHUA Technology Co., Ltd
2C4401|Samsung Electronics Co.,Ltd
2C44FD|Hewlett Packard
2C4C15|Juniper Networks
2C4D54|ASUSTek COMPUTER INC.
2C4F52|Cisco Systems, Inc
2C5089|Shenzhen Kaixuan Visual Technology Co.,Limited
2C52AF|HUAWEI TECHNOLOGIES CO.,LTD
2C534A|Shenzhen Winyao Electronic Limited
2C542D|Cisco Systems, Inc
2C5491|Microsoft Corporation
2C54CF|LG Electronics (Mobile Communications)
2C557C|Shenzhen YOUHUA Technology Co., Ltd
2C55D3|HUAWEI TECHNOLOGIES CO.,LTD
2C56DC|ASUSTek COMPUTER INC.
2C5741|Cisco Systems, Inc
2C57CE|Apple, Inc.
2C58B9|HP Inc.
2C58E8|HUAWEI TECHNOLOGIES CO.,LTD
2C598A|LG Electronics (Mobile Communications)
2C59E5|Hewlett Packard
2C5A05|Nokia Corporation
2C5A0F|Cisco Systems, Inc
2C5D93|Ruckus Wireless
2C600C|Quanta Computer Inc.
2C6104|SHENZHEN FENGLIAN TECHNOLOGY CO., LTD.
2C61F6|Apple, Inc.
2C63A1|Huawei Device Co., Ltd.
2C658D|Cisco Systems, Inc
2C66F5|SHENZHEN ELECTRICAL APPLIANCES CO.
2C67FB|ShenZhen Zhengjili Electronics Co., LTD
2C693E|HUAWEI TECHNOLOGIES CO.,LTD
2C6BF5|Juniper Networks
2C6DC1|Intel Corporate
2C6E85|Intel Corporate
2C6F37|Nokia
2C6FC9|Hon Hai Precision Ind. Co.,Ltd.
2C704F|zte corporation
2C71FF|Amazon Technologies Inc.
2C73A0|Cisco Systems, Inc
2C7600|Apple, Inc.
2C768A|Hewlett Packard
2C780E|Huawei Device Co., Ltd.
2C79BE|TP-LINK TECHNOLOGIES CO.,LTD.
2C79D7|Sagemcom Broadband SAS
2C7BA0|Intel Corporate
2C7CF2|Apple, Inc.
2C8158|Hon Hai Precision Ind. Co.,Ltd.
2C81BF|Apple, Inc.
2C8217|Apple, Inc.
2C86D2|Cisco Systems, Inc
2C8DB1|Intel Corporate
2C9452|HUAWEI TECHNOLOGIES CO.,LTD
2C9520|Apple, Inc.
2C957F|zte corporation
2C97B1|HUAWEI TECHNOLOGIES CO.,LTD
2C97ED|Sony Imaging Products & Solutions Inc.
2C9975|Samsung Electronics Co.,Ltd
2C9D1E|HUAWEI TECHNOLOGIES CO.,LTD
2C9E00|Sony Interactive Entertainment Inc.
2C9EFC|CANON INC.
2CA042|Huawei Device Co., Ltd.
2CA2E5|Cisco Systems, Inc
2CA59C|Hangzhou Hikvision Digital Technology Co.,Ltd.
2CA797|HUAWEI TECHNOLOGIES CO.,LTD
2CA79E|HUAWEI TECHNOLOGIES CO.,LTD
2CA7EF|OnePlus Technology (Shenzhen) Co., Ltd
2CAB00|HUAWEI TECHNOLOGIES CO.,LTD
2CAB25|SHENZHEN GONGJIN ELECTRONICS CO.,LT
2CAB46|Ruckus Wireless
2CABA4|Cisco SPVTG
2CABEB|Cisco Systems, Inc
2CAD13|SHENZHEN ZHILU TECHNOLOGY CO.,LTD
2CAE2B|Samsung Electronics Co.,Ltd
2CB05D|NETGEAR
2CB0FD|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
2CB43A|Apple, Inc.
2CB471|Tuya Smart Inc.
2CB68F|HUAWEI TECHNOLOGIES CO.,LTD
2CB6C2|zte corporation
2CB7A1|Huawei Device Co., Ltd.
2CB8ED|SonicWall
2CBABA|Samsung Electronics Co.,Ltd
2CBC87|Apple, Inc.
2CBCBB|Espressif Inc.
2CBE08|Apple, Inc.
2CC1F4|Nokia Solutions and Networks India Private Limited
2CC253|Apple, Inc.
2CC3E6|SHENZHEN BILIAN ELECTRONIC CO.，LTD
2CC546|Huawei Device Co., Ltd.
2CC5D3|Ruckus Wireless
2CC81B|Routerboard.com
2CC8F5|Huawei Device Co., Ltd.
2CCA16|Apple, Inc.
2CCC15|Nokia Corporation
2CCC44|Sony Interactive Entertainment Inc.
2CCCE6|Skyworth Digital Technology(Shenzhen) Co.,Ltd
2CCF58|HUAWEI TECHNOLOGIES CO.,LTD
2CCF67|Raspberry Pi (Trading) Ltd
2CD02D|Cisco Systems, Inc
2CD05A|Liteon Technology Corporation
2CD066|Xiaomi Communications Co Ltd
2CD26B|FN-LINK TECHNOLOGY LIMITED
2CD2E7|Nokia Corporation
2CD444|FUJITSU LIMITED
2CD8AE|Shenzhen SEI Robotics Co.,Ltd
2CDA46|Samsung Electronics Co.,Ltd
2CDB07|Intel Corporate
2CDCD7|AzureWave Technology Inc.
2CDD5F|Shenzhen iComm Semiconductor CO.,LTD
2CDF68|Apple, Inc.
2CE032|TCL King Electrical Appliances(Huizhou)Co.,Ltd
2CE2D9|Huawei Device Co., Ltd.
2CE38E|Cisco Systems, Inc
2CE412|Sagemcom Broadband SAS
2CE5BD|Ubiquiti Inc
2CE6CC|Ruckus Wireless
2CEA7F|Dell Inc.
2CEAFC|Intel Corporate
2CECA6|HUAWEI TECHNOLOGIES CO.,LTD
2CECF7|Shenzhen SDMC Technology CO.,Ltd.
2CED89|HUAWEI TECHNOLOGIES CO.,LTD
2CEDB0|HUAWEI TECHNOLOGIES CO.,LTD
2CF05D|Micro-Star INTL CO., LTD.
2CF0A2|Apple, Inc.
2CF0EE|Apple, Inc.
2CF1BB|zte corporation
2CF295|Huawei Device Co., Ltd.
2CF2A5|Sagemcom Broadband SAS
2CF432|Espressif Inc.
2CF4C5|Avaya Inc
2CF814|Cisco Systems, Inc
2CF89B|Cisco Systems, Inc
2CFB0F|Sagemcom Broadband SAS
2CFDA1|ASUSTek COMPUTER INC.
2CFDAB|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
2CFDB4|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
2CFE4F|Xiaomi Communications Co Ltd
3000FC|Nokia
3001AF|Cisco Systems, Inc
30045C|Shenzhen SuperElectron Technology Co.,Ltd.
300505|Intel Corporate
30055C|Brother industries, LTD.
30074D|SAMSUNG ELECTRO-MECHANICS(THAILAND)
3007A3|Shenzhen Skyworth Digital Technology CO., Ltd
300916|Apple, Inc.
3009C0|Motorola Mobility LLC, a Lenovo Company
300C23|zte corporation
300D43|Microsoft Mobile Oy
300E43|Apple, Inc.
300EB8|LG Electronics
300ED5|Hon Hai Precision Ind. Co.,Ltd.
300EE3|Aquantia Corporation
3010B3|Liteon Technology Corporation
3010E4|Apple, Inc.
30138B|HP Inc.
301577|Zyxel Communications Corporation
30169D|MERCUSYS TECHNOLOGIES CO., LTD.
3017C8|Sony Corporation
301966|Samsung Electronics Co.,Ltd
301984|HUAWEI TECHNOLOGIES CO.,LTD
301C22|Hewlett Packard Enterprise
301F48|zte corporation
30215B|Shenzhen Ostar Display Electronic Co.,Ltd
302364|Nokia Shanghai Bell Co., Ltd.
302432|Intel Corporate
302478|Sagemcom Broadband SAS
3024A9|HP Inc.
30294B|HUAWEI TECHNOLOGIES CO.,LTD
302952|Hillstone Networks Inc
3030F9|Espressif Inc.
303180|Shenzhen Skyworth Digital Technology CO., Ltd
3035AD|Apple, Inc.
3035C5|Huawei Device Co., Ltd.
3037A6|Cisco Systems, Inc
3037B3|HUAWEI TECHNOLOGIES CO.,LTD
303855|Nokia Corporation
303926|Sony Corporation
303955|Shenzhen Jinhengjia Electronic Co., Ltd.
303A64|Intel Corporate
303B49|Cisco Meraki
303B7C|Apple, Inc.
303EA7|Intel Corporate
303F7B|Shenzhen YOUHUA Technology Co., Ltd
303FBB|Hewlett Packard Enterprise
304074|zte corporation
304240|zte corporation
304596|HUAWEI TECHNOLOGIES CO.,LTD
30469A|NETGEAR
30487D|Tuya Smart Inc.
30499E|HUAWEI TECHNOLOGIES CO.,LTD
304A26|Shenzhen Trolink Technology CO, LTD
304B07|Motorola Mobility LLC, a Lenovo Company
304C7E|Panasonic Electric Works Automation Controls Techno Co.,Ltd.
304D1F|Amazon Technologies Inc.
304E1B|Huawei Device Co., Ltd.
3050CE|Xiaomi Communications Co Ltd
3050FD|Skyworth Digital Technology(Shenzhen) Co.,Ltd
3052CB|Liteon Technology Corporation
30535B|Shenzhen Comnect Technology Co.,LTD
30560F|GIGA-BYTE TECHNOLOGY CO. , Ltd.
305684|SHENZHEN YUNJI INTELLIGENT TECHNOLOGY CO.,LTD
305714|Apple, Inc.
3058EB|zte corporation
3059B7|Microsoft
305A3A|ASUSTek COMPUTER INC.
3061A2|HUAWEI TECHNOLOGIES CO.,LTD
306222|Samsung Electronics Co.,Ltd
30636B|Apple, Inc.
306371|Shenzhenshi Xinzhongxin Technology Co.Ltd
3063EA|Juniper Networks
3065EC|Wistron (ChongQing)
3066D0|Huawei Device Co., Ltd.
3067A1|Sagemcom Broadband SAS
306893|TP-Link Systems Inc.
306A4F|Roku, Inc
306A85|Samsung Electronics Co.,Ltd
307467|Samsung Electronics Co.,Ltd
307496|HUAWEI TECHNOLOGIES CO.,LTD
307512|Sony Corporation
30766F|LG Electronics (Mobile Communications)
3076F5|Espressif Inc.
3077CB|Maike Industry(Shenzhen)CO.,LTD
307A05|HUAWEI TECHNOLOGIES CO.,LTD
307AD2|Apple, Inc.
307BC9|SHENZHEN BILIAN ELECTRONIC CO.，LTD
307C4A|Huawei Device Co., Ltd.
307C5E|Juniper Networks
308216|Apple, Inc.
308398|Espressif Inc.
3083D2|Motorola Mobility LLC, a Lenovo Company
3085A9|ASUSTek COMPUTER INC.
3085EB|Fiberhome Telecommunication Technologies Co.,LTD
3086F1|Fiberhome Telecommunication Technologies Co.,LTD
308730|HUAWEI TECHNOLOGIES CO.,LTD
3087D9|Ruckus Wireless
30894A|Intel Corporate
3089A6|HUAWEI TECHNOLOGIES CO.,LTD
308AF7|Huawei Device Co., Ltd.
308BB2|Cisco Systems, Inc
308D99|Hewlett Packard
308DD4|HUAWEI TECHNOLOGIES CO.,LTD
308E7A|Shenzhen iComm Semiconductor CO.,LTD
308ECF|HUAWEI TECHNOLOGIES CO.,LTD
309048|Apple, Inc.
3090AB|Apple, Inc.
309176|Skyworth Digital Technology(Shenzhen) Co.,Ltd
3093BC|Sagemcom Broadband SAS
309587|HUNAN FN-LINK TECHNOLOGY LIMITED
309610|Huawei Device Co., Ltd.
30963B|Huawei Device Co., Ltd.
3096FB|Samsung Electronics Co.,Ltd
309935|zte corporation
309C23|Micro-Star INTL CO., LTD.
309E62|HUAWEI TECHNOLOGIES CO.,LTD
30A033|Apple, Inc.
30A176|Fiberhome Telecommunication Technologies Co.,LTD
30A1FA|HUAWEI TECHNOLOGIES CO.,LTD
30A243|Shenzhen Prifox Innovation Technology Co., Ltd.
30A2C2|Huawei Device Co., Ltd.
30A30F|HUAWEI TECHNOLOGIES CO.,LTD
30A612|ShenZhen Hugsun Technology Co.,Ltd.
30A7F5|Apple, Inc.
30A8DB|Sony Corporation
30A998|Huawei Device Co., Ltd.
30AAE4|Huawei Device Co., Ltd.
30AB6A|SAMSUNG ELECTRO-MECHANICS(THAILAND)
30AEA4|Espressif Inc.
30B0EA|Shenzhen Chuangxin Internet Communication Technology Co., Ltd
30B3A2|Shenzhen Heguang Measurement & Control Technology Co.,Ltd
30B49E|TP-LINK TECHNOLOGIES CO.,LTD.
30B4B8|LG Electronics
30B5C2|TP-LINK TECHNOLOGIES CO.,LTD.
30B64F|Juniper Networks
30B930|zte corporation
30BB7D|OnePlus Technology (Shenzhen) Co., Ltd
30BD13|Zyxel Communications Corporation
30C01B|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
30C0AE|Apple, Inc.
30C50F|HUAWEI TECHNOLOGIES CO.,LTD
30C599|ASUSTek COMPUTER INC.
30C6AB|zte corporation
30C6F7|Espressif Inc.
30C7AE|Samsung Electronics Co.,Ltd
30C8A2|SHENZHEN TRANSCHAN TECHNOLOGY LIMITED
30C922|Espressif Inc.
30C9CC|Samsung Electronics Co.,Ltd
30CBC7|Cambium Networks Limited
30CBF8|Samsung Electronics Co.,Ltd
30CC21|zte corporation
30CDA7|Samsung Electronics Co.,Ltd
30D042|Dell Inc.
30D16B|Liteon Technology Corporation
30D17E|HUAWEI TECHNOLOGIES CO.,LTD
30D386|zte corporation
30D4E2|HUAWEI TECHNOLOGIES CO.,LTD
30D53E|Apple, Inc.
30D587|Samsung Electronics Co.,Ltd
30D6C9|Samsung Electronics Co.,Ltd
30D7A1|Apple, Inc.
30D875|Apple, Inc.
30D9D9|Apple, Inc.
30DCE7|zte corporation
30DDAA|ZHEJIANG DAHUA TECHNOLOGYCO.,LTD
30DE4B|TP-Link Systems Inc
30DE52|Samsung Electronics Co.,Ltd
30DF8D|SHENZHEN GONGJIN ELECTRONICS CO.,LT
30E044|Google, Inc.
30E04F|Apple, Inc.
30E171|Hewlett Packard
30E1F1|Intelbras
30E226|Apple, Inc.
30E37A|Intel Corporate
30E396|Huawei Device Co., Ltd.
30E3A4|Intel Corporate
30E4D8|Huawei Device Co., Ltd.
30E4DB|Cisco Systems, Inc
30E98E|HUAWEI TECHNOLOGIES CO.,LTD
30EB15|Huawei Device Co., Ltd.
30EC7C|Shenzhen Along Electronics Co., Ltd
30EDA0|Espressif Inc.
30EFD1|Alstom Strongwish (Shenzhen) Co., Ltd.
30F31D|zte corporation
30F335|HUAWEI TECHNOLOGIES CO.,LTD
30F600|Sagemcom Broadband SAS
30F65D|Hewlett Packard Enterprise
30F6EF|Intel Corporate
30F70D|Cisco Systems, Inc
30F772|Hon Hai Precision Ind. Co.,Ltd.
30F7C5|Apple, Inc.
30F856|Extreme Networks, Inc.
30F947|Shenzhen Skyworth Digital Technology CO., Ltd
30F9ED|Sony Corporation
30FBB8|HUAWEI TECHNOLOGIES CO.,LTD
30FC68|TP-LINK TECHNOLOGIES CO.,LTD.
30FCEB|LG Electronics (Mobile Communications)
30FD38|Google, Inc.
30FD65|HUAWEI TECHNOLOGIES CO.,LTD
30FE31|Nokia
30FE6C|Apple, Inc.
30FEFA|Cisco Systems, Inc
30FFFD|HUAWEI TECHNOLOGIES CO.,LTD
3400A3|HUAWEI TECHNOLOGIES CO.,LTD
340286|Intel Corporate
34029C|D-Link Corporation
34033D|HP Inc.
340804|D-Link Corporation
3408BC|Apple, Inc.
340962|Hangzhou Hikvision Digital Technology Co.,Ltd.
340A33|D-Link International
340A98|HUAWEI TECHNOLOGIES CO.,LTD
340E22|Apple, Inc.
3410BE|Apple, Inc.
3410D0|HUAWEI TECHNOLOGIES CO.,LTD
341298|Apple, Inc.
3412F9|HUAWEI TECHNOLOGIES CO.,LTD
3413E8|Intel Corporate
34145F|Samsung Electronics Co.,Ltd
341593|Ruckus Wireless
34159E|Apple, Inc.
341736|Shenzhen iComm Semiconductor CO.,LTD
3417EB|Dell Inc.
341A35|Fiberhome Telecommunication Technologies Co.,LTD
341A4C|SHENZHEN WEIBU ELECTRONICS CO.,LTD.
341B2D|Cisco Systems, Inc
341CF0|Xiaomi Communications Co Ltd
341E6B|HUAWEI TECHNOLOGIES CO.,LTD
341FC4|Shenzhen V-Link Technology CO., LTD.
342003|Shenzhen Feitengyun Technology Co.,LTD
3420D3|SHENZHEN IP-COM NETWORKS CO.,LTD.
3420E3|Ruckus Wireless
342387|Hon Hai Precision Ind. Co.,Ltd.
3423BA|SAMSUNG ELECTRO-MECHANICS(THAILAND)
34243E|zte corporation
34255D|Shenzhen Loadcom Technology Co.,Ltd
3425BE|Amazon Technologies Inc.
342601|HUAWEI TECHNOLOGIES CO.,LTD
342840|Apple, Inc.
342865|Juniper Networks
342912|HUAWEI TECHNOLOGIES CO.,LTD
342B6E|Apple, Inc.
342CC4|Compal Broadband Networks, Inc.
342D0D|Samsung Electronics Co.,Ltd
342D0F|zte corporation
342DA3|Fiberhome Telecommunication Technologies Co.,LTD
342EB6|HUAWEI TECHNOLOGIES CO.,LTD
342EB7|Intel Corporate
343111|Samsung Electronics Co.,Ltd
34317F|Panasonic Appliances Company
34318F|Apple, Inc.
3432E6|Panasonic Industrial Devices Europe GmbH
343638|HUAWEI TECHNOLOGIES CO.,LTD
34363B|Apple, Inc.
343654|zte corporation
343759|zte corporation
343916|Google, Inc.
343A20|Hewlett Packard Enterprise
343DA9|HUAWEI TECHNOLOGIES CO.,LTD
34415D|Intel Corporate
344262|Apple, Inc.
3446EC|Huawei Device Co., Ltd.
3448ED|Dell Inc.
34495B|Sagemcom Broadband SAS
344A1B|zte corporation
344B3D|Fiberhome Telecommunication Technologies Co.,LTD
344B50|zte corporation
344DEA|zte corporation
344DF7|LG Electronics (Mobile Communications)
344EE2|Huawei Device Co., Ltd.
34516F|Skychers Creations ShenZhen Limited
345180|TCL King Electrical Appliances (Huizhou) Co., Ltd
345184|Huawei Device Co., Ltd.
3451C9|Apple, Inc.
3453D2|Sagemcom Broadband SAS
3454EF|Cisco Systems, Inc
3456FE|Cisco Meraki
345840|HUAWEI TECHNOLOGIES CO.,LTD
34588A|Cisco Systems, Inc
345A06|SHARP Corporation
345A60|Micro-Star INTL CO., LTD.
345ABA|tcloud intelligence
345CF3|Chipsea Technologies (Shenzhen) Corp.
345D9E|Sagemcom Broadband SAS
345DA8|Cisco Systems, Inc
345E08|Roku, Inc
345F45|Espressif Inc.
3460F9|TP-Link Systems Inc
346288|Cisco Systems, Inc
3464A9|Hewlett Packard
346679|HUAWEI TECHNOLOGIES CO.,LTD
346691|Apple, Inc.
346895|Hon Hai Precision Ind. Co.,Ltd.
346987|zte corporation
346AC2|HUAWEI TECHNOLOGIES CO.,LTD
346B46|Sagemcom Broadband SAS
346BD3|HUAWEI TECHNOLOGIES CO.,LTD
346E68|HUAWEI TECHNOLOGIES CO.,LTD
346F24|AzureWave Technology Inc.
346F3F|Hon Hai Precision Industry Co.,LTD
346F90|Cisco Systems, Inc
347069|Cisco Systems, Inc
347146|Huawei Device Co., Ltd.
34732D|Cisco Systems, Inc
34735A|Dell Inc.
347563|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
3475C7|Avaya Inc
347839|zte corporation
347877|O-Net Communications (Shenzhen) Limited
347916|HUAWEI TECHNOLOGIES CO.,LTD
347C25|Apple, Inc.
347DE4|SHENZHEN BILIAN ELECTRONIC CO.，LTD
347DF6|Intel Corporate
347E00|Huawei Device Co., Ltd.
347E39|Nokia Danmark A/S
347E5C|Sonos, Inc.
34800D|Marvell Semiconductors
3480B3|Xiaomi Communications Co Ltd
348296|Apple, Inc.
3482C5|Samsung Electronics Co.,Ltd
3483D5|HUAWEI TECHNOLOGIES CO.,LTD
348511|Shenzhen Skyworth Digital Technology CO., Ltd
348518|Espressif Inc.
348584|Extreme Networks, Inc.
34865D|Espressif Inc.
348818|Cisco Systems, Inc
348A12|Hewlett Packard Enterprise
348A3B|Huawei Device Co., Ltd.
348A7B|Samsung Electronics Co.,Ltd
348AAE|Sagemcom Broadband SAS
348C5E|Apple, Inc.
348F27|Ruckus Wireless
34936F|Juniper Networks
349454|Espressif Inc.
349671|HUAWEI TECHNOLOGIES CO.,LTD
349672|TP-LINK TECHNOLOGIES CO.,LTD.
349677|zte corporation
3497D7|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
3497F6|ASUSTek COMPUTER INC.
34987A|Espressif Inc.
3498B5|NETGEAR
349971|Quanta Storage Inc.
349F7B|CANON INC.
34A137|HUAWEI TECHNOLOGIES CO.,LTD
34A2A2|HUAWEI TECHNOLOGIES CO.,LTD
34A395|Apple, Inc.
34A6EF|Shenzhen Phaten Tech. LTD
34A843|KYOCERA Display Corporation
34A84E|Cisco Systems, Inc
34A8A0|HUAWEI TECHNOLOGIES CO.,LTD
34A8EB|Apple, Inc.
34AA31|Shenzhen Skyworth Digital Technology CO., Ltd
34AA8B|Samsung Electronics Co.,Ltd
34AA99|Nokia
34AB37|Apple, Inc.
34AB95|Espressif Inc.
34AC2F|zte corporation
34AFB3|Amazon Technologies Inc.
34B1EB|Apple, Inc.
34B20A|Huawei Device Co., Ltd.
34B354|HUAWEI TECHNOLOGIES CO.,LTD
34B472|Espressif Inc.
34B4F0|Hasselblad (Shenzhen) Trading CompanyLimited
34B7DA|Espressif Inc.
34B883|Cisco Systems, Inc
34B98D|Xiaomi Communications Co Ltd
34BB26|Motorola Mobility LLC, a Lenovo Company
34BDC8|Cisco Systems, Inc
34BDFA|Cisco SPVTG
34BE00|Samsung Electronics Co.,Ltd
34BF90|Fiberhome Telecommunication Technologies Co.,LTD
34C059|Apple, Inc.
34C232|Samsung Electronics Co.,Ltd
34C386|Apple, Inc.
34C3AC|Samsung Electronics Co.,Ltd
34C3D2|FN-LINK TECHNOLOGY LIMITED
34C3FD|Cisco Systems, Inc
34C515|Hewlett Packard Enterprise
34C7E9|Google, Inc.
34C803|Nokia Corporation
34C93D|Intel Corporate
34CDB0|Espressif Inc.
34CDBE|HUAWEI TECHNOLOGIES CO.,LTD
34CE00|XIAOMI Electronics,CO.,LTD
34CE69|Nokia Solutions and Networks GmbH & Co. KG
34CFF6|Intel Corporate
34D270|Amazon Technologies Inc.
34D693|Huawei Device Co., Ltd.
34D72F|Shenzhen SuperElectron Technology Co.,Ltd.
34D856|Shenzhen Skyworth Digital Technology CO., Ltd
34D868|Broadcom Limited
34DAA1|Apple, Inc.
34DAB7|zte corporation
34DB9C|Sagemcom Broadband SAS
34DBFD|Cisco Systems, Inc
34DDCC|Google, Inc.
34DE1A|Intel Corporate
34DE34|zte corporation
34DF20|Shenzhen Comstar .Technology Co.,Ltd
34E0CF|zte corporation
34E12D|Intel Corporate
34E2FD|Apple, Inc.
34E3FB|Samsung Electronics Co.,Ltd
34E5EC|Palo Alto Networks
34E6AD|Intel Corporate
34E6D7|Dell Inc.
34E71C|Shenzhen YOUHUA Technology Co., Ltd
34E894|TP-LINK TECHNOLOGIES CO.,LTD.
34ED1B|Cisco Systems, Inc
34EE16|Apple, Inc.
34EFD7|HUAWEI TECHNOLOGIES CO.,LTD
34F015|Beijing Xiaomi Mobile Software Co., Ltd
34F043|Samsung Electronics Co.,Ltd
34F084|Samsung Electronics Co.,Ltd
34F0CA|Shenzhen Linghangyuan Digital Technology Co.,Ltd.
34F39A|Intel Corporate
34F5D7|Huawei Device Co., Ltd.
34F62D|SHARP Corporation
34F64B|Intel Corporate
34F68D|Apple, Inc.
34F6D2|Panasonic Taiwan Co.,Ltd.
34F716|TP-LINK TECHNOLOGIES CO.,LTD.
34F8DD|Apple, Inc.
34F8E7|Cisco Systems, Inc
34FA1C|Beijing Xiaomi Mobile Software Co., Ltd
34FA9F|Ruckus Wireless
34FCB9|Hewlett Packard Enterprise
34FCEF|LG Electronics (Mobile Communications)
34FD6A|Apple, Inc.
34FD70|Intel Corporate
34FE77|Apple, Inc.
34FE9E|Fujitsu Limited
34FEC5|Shenzhen Sunwoda intelligent hardware Co.,Ltd
34FFF3|HUAWEI TECHNOLOGIES CO.,LTD
380025|Intel Corporate
380146|SHENZHEN BILIAN ELECTRONIC CO.，LTD
380195|Samsung Electronics Co.,Ltd
38019F|SHENZHEN FAST TECHNOLOGIES CO.,LTD
3802E3|YICHEN (SHENZHEN) TECHNOLOGY CO.,LTD
380484|Apple, Inc.
3809FB|Apple, Inc.
380A94|Samsung Electronics Co.,Ltd
380B40|Samsung Electronics Co.,Ltd
380E4D|Cisco Systems, Inc
380F4A|Apple, Inc.
380FAD|HUAWEI TECHNOLOGIES CO.,LTD
3810F0|Hewlett Packard Enterprise
381428|Dell Inc.
38144E|Fiberhome Telecommunication Technologies Co.,LTD
38165A|zte corporation
381672|Shenzhen SuperElectron Technology Co.,Ltd.
3816B3|HP Inc.
3816D1|Samsung Electronics Co.,Ltd
3817B1|Sagemcom Broadband SAS
3817C3|Hewlett Packard Enterprise
38182B|Espressif Inc.
38184C|Sony Home Entertainment&Sound Products Inc
381868|Intel Corporate
38192F|Nokia Corporation
381A52|Seiko Epson Corporation
381C1A|Cisco Systems, Inc
381DD9|FN-LINK TECHNOLOGY LIMITED
381EC7|Chipsea Technologies(Shenzhen) Corp.
381F8D|Tuya Smart Inc.
382028|HUAWEI TECHNOLOGIES CO.,LTD
382056|Cisco Systems, Inc
3821C7|Hewlett Packard Enterprise
3822E2|HP Inc.
3822F4|Huawei Device Co., Ltd.
38256B|Microsoft Mobile Oy
382656|TCL King Electrical Appliances(Huizhou)Co.,Ltd
382835|zte corporation
382C4A|ASUSTek COMPUTER INC.
382CE5|Tuya Smart Inc.
382DD1|Samsung Electronics Co.,Ltd
382DE8|Samsung Electronics Co.,Ltd
3830F9|LG Electronics (Mobile Communications)
38327A|Routerboard.com
3833C5|Microsoft Corporation
3835FB|Sagemcom Broadband SAS
38378B|HUAWEI TECHNOLOGIES CO.,LTD
38396C|Huawei Device Co., Ltd.
3839DD|Nokia
383D5B|Fiberhome Telecommunication Technologies Co.,LTD
383E51|Espressif Inc.
383FE8|HUAWEI TECHNOLOGIES CO.,LTD
38420B|Sonos, Inc.
38437D|Compal Broadband Networks, Inc.
3844BE|Espressif Inc.
38453B|Ruckus Wireless
384608|zte corporation
3847BC|HUAWEI TECHNOLOGIES CO.,LTD
38484C|Apple, Inc.
384A80|Samsung Electronics Co.,Ltd
384C4F|HUAWEI TECHNOLOGIES CO.,LTD
384DD2|Huawei Device Co., Ltd.
384F49|Juniper Networks
384FF0|AzureWave Technology Inc.
38521A|Nokia
385247|Huawei Device Co., Ltd.
38539C|Apple, Inc.
38549B|zte corporation
38563D|Microsoft Corporation
3859F9|Hon Hai Precision Ind. Co.,Ltd.
385F66|Cisco SPVTG
386077|PEGATRON CORPORATION
386233|Apple, Inc.
38637F|Fiberhome Telecommunication Technologies Co.,LTD
3863BB|Hewlett Packard
3863F6|3NOD MULTIMEDIA(SHENZHEN)CO.,LTD
3865B2|Apple, Inc.
3866F0|Apple, Inc.
386893|Intel Corporate
3868A4|Samsung Electronics Co.,Ltd
3868DD|INVENTEC CORPORATION
386A77|Samsung Electronics Co.,Ltd
386B1C|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
386DED|Juniper Networks
386E88|zte corporation
386EB2|HUAWEI TECHNOLOGIES CO.,LTD
386FF4|Amazon Technologies Inc.
3870F2|HUAWEI TECHNOLOGIES CO.,LTD
3871DE|Apple, Inc.
38736E|Huawei Device Co., Ltd.
3876CA|Shenzhen Smart Intelligent Technology Co.Ltd
387862|Sony Corporation
387A0E|Intel Corporate
387A3C|Fiberhome Telecommunication Technologies Co.,LTD
387ACC|SHENZHEN BILIAN ELECTRONIC CO.，LTD
387B01|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
387F8B|Apple, Inc.
3880DF|Motorola Mobility LLC, a Lenovo Company
388345|TP-LINK TECHNOLOGIES CO.,LTD.
38839A|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
388479|Cisco Meraki
3886F7|Google, Inc.
3887D5|Intel Corporate
38881E|HUAWEI TECHNOLOGIES CO.,LTD
3888A4|Apple, Inc.
38892C|Apple, Inc.
388A06|Samsung Electronics Co.,Ltd
388B59|Google, Inc.
388C50|LG Electronics
388CEF|Samsung Electronics Co.,Ltd
388F30|Samsung Electronics Co.,Ltd
389052|HUAWEI TECHNOLOGIES CO.,LTD
3890A5|Cisco Systems, Inc
3890AF|zte corporation
389148|zte corporation
3891B7|Cisco Systems, Inc
389496|Samsung Electronics Co.,Ltd
3894ED|NETGEAR
3898E9|Huawei Device Co., Ltd.
389AF6|Samsung Electronics Co.,Ltd
389CB2|Apple, Inc.
389D92|Seiko Epson Corporation
389E4C|Hewlett Packard Enterprise
389E80|zte corporation
38A067|Nokia Solutions and Networks GmbH & Co. KG
38A28C|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
38A44B|Huawei Device Co., Ltd.
38A4ED|Xiaomi Communications Co Ltd
38A5B6|SHENZHEN MEGMEET ELECTRICAL CO.,LTD
38A5C9|Tuya Smart Inc.
38A659|Sagemcom Broadband SAS
38A746|COMPAL INFORMATION (KUNSHAN) CO., LTD.
38A89B|Fiberhome Telecommunication Technologies Co.,LTD
38AA09|Cisco Systems, Inc
38AA20|zte corporation
38AA3C|SAMSUNG ELECTRO MECHANICS CO., LTD.
38AF29|Zhejiang Dahua Technology Co., Ltd.
38AFD7|FUJITSU LIMITED
38B1DB|Hon Hai Precision Ind. Co.,Ltd.
38B3F7|Huawei Device Co., Ltd.
38B54D|Apple, Inc.
38B725|Wistron Infocomm (Zhongshan) Corporation
38BAB0|Broadcom
38BAF8|Intel Corporate
38BB3C|Avaya Inc
38BC01|HUAWEI TECHNOLOGIES CO.,LTD
38BD7A|Hewlett Packard Enterprise
38C0EA|Fortinet, Inc.
38C1ED|Xiaomi Communications Co Ltd
38C43A|Apple, Inc.
38C6BD|Xiaomi Communications Co Ltd
38C85C|Cisco SPVTG
38C986|Apple, Inc.
38C9B1|zte corporation
38CA73|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
38CA84|HP Inc.
38CADA|Apple, Inc.
38D09C|HUAWEI TECHNOLOGIES CO.,LTD
38D40B|Samsung Electronics Co.,Ltd
38D547|ASUSTek COMPUTER INC.
38D82F|zte corporation
38DEAD|Intel Corporate
38E13D|Apple, Inc.
38E1AA|zte corporation
38E1F4|Sagemcom Broadband SAS
38E26E|ShenZhen Sweet Rain Electronics Co.,Ltd.
38E2DD|zte corporation
38E39F|Motorola Mobility LLC, a Lenovo Company
38E595|SHENZHEN GONGJIN ELECTRONICS CO.,LT
38E60A|Xiaomi Communications Co Ltd
38EAA7|Hewlett Packard
38EADD|Juniper Networks
38EB47|HUAWEI TECHNOLOGIES CO.,LTD
38EC07|Motorola Mobility LLC, a Lenovo Company
38EC0D|Apple, Inc.
38ECE4|Samsung Electronics Co.,Ltd
38ED18|Cisco Systems, Inc
38EFE3|INGENICO TERMINALS SAS
38F098|Vapor Stone Rail Systems
38F18F|Technicolor (China) Technology Co., Ltd.
38F195|HUAWEI TECHNOLOGIES CO.,LTD
38F20D|Juniper Networks
38F23E|Microsoft Mobile Oy
38F3AB|LCFC(Hefei) Electronics Technology co., ltd
38F6CF|zte corporation
38F73D|Amazon Technologies Inc.
38F7F1|Huawei Device Co., Ltd.
38F889|HUAWEI TECHNOLOGIES CO.,LTD
38F9D3|Apple, Inc.
38FACA|Skyworth Digital Technology(Shenzhen) Co.,Ltd
38FB14|HUAWEI TECHNOLOGIES CO.,LTD
38FBA0|Shenzhen Baseus Technology CoLtd
38FC34|Huawei Device Co., Ltd.
38FC98|Intel Corporate
38FDF8|Cisco Systems, Inc
38FF36|Ruckus Wireless
38FF59|Dell Inc.
3C01EF|Sony Corporation
3C0518|Samsung Electronics Co.,Ltd
3C058E|HUAWEI TECHNOLOGIES CO.,LTD
3C0630|Apple, Inc.
3C06A7|TP-LINK TECHNOLOGIES CO.,LTD.
3C0754|Apple, Inc.
3C0771|Sony Corporation
3C07D7|Apple, Inc.
3C08CD|Juniper Networks
3C08F6|Cisco Systems, Inc
3C0A7A|Samsung Electronics Co.,Ltd
3C0B59|Tuya Smart Inc.
3C0D0D|Espressif Systems (Singapore) Pte. Ltd
3C0E23|Cisco Systems, Inc
3C0F02|Espressif Inc.
3C1060|Fiberhome Telecommunication Technologies Co.,LTD
3C135A|Xiaomi Communications Co Ltd
3C13BB|HUAWEI TECHNOLOGIES CO.,LTD
3C13CC|Cisco Systems, Inc
3C1512|Shenzhen Huanhu Technology Co.,Ltd
3C155A|Nokia
3C15C2|Apple, Inc.
3C15FB|HUAWEI TECHNOLOGIES CO.,LTD
3C1710|Sagemcom Broadband SAS
3C189F|Nokia Corporation
3C195E|Samsung Electronics Co.,Ltd
3C1A65|Nokia
3C1BF8|Hangzhou Hikvision Digital Technology Co.,Ltd.
3C1E04|D-Link International
3C1EB5|Apple, Inc.
3C20F6|Samsung Electronics Co.,Ltd
3C219C|Intel Corporate
3C22FB|Apple, Inc.
3C240A|Huawei Device Co., Ltd.
3C25D7|Nokia Corporation
3C25F8|Dell Inc.
3C26E4|Cisco Systems, Inc
3C286D|Google, Inc.
3C2983|Samsung Electronics Co.,Ltd
3C2AF4|Brother Industries, LTD.
3C2C30|Dell Inc.
3C2CA6|Beijing Xiaomi Electronics Co.,Ltd
3C2CCD|Apple, Inc.
3C2EF9|Apple, Inc.
3C2EFF|Apple, Inc.
3C306F|HUAWEI TECHNOLOGIES CO.,LTD
3C3174|Google, Inc.
3C318A|Samsung Electronics Co.,Ltd
3C3300|SHENZHEN BILIAN ELECTRONIC CO.，LTD
3C3332|D-Link Corporation
3C3464|Apple, Inc.
3C363D|Nokia Corporation
3C366A|HUAWEI TECHNOLOGIES CO.,LTD
3C3786|NETGEAR
3C381F|Huawei Device Co., Ltd.
3C3824|Xiaomi Communications Co Ltd
3C38F4|Sony Corporation
3C39A8|Shenzhen Taichi Technology Limited
3C39C8|Apple, Inc.
3C3A73|Avaya Inc
3C3B77|Apple, Inc.
3C410E|Cisco Systems, Inc
3C46A1|Ruckus Wireless
3C46D8|TP-LINK TECHNOLOGIES CO.,LTD.
3C4711|HUAWEI TECHNOLOGIES CO.,LTD
3C4A92|Hewlett Packard
3C4AC9|Huawei Device Co., Ltd.
3C4DBE|Apple, Inc.
3C4E56|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
3C5002|Apple, Inc.
3C510E|Cisco Systems, Inc
3C5282|Hewlett Packard
3C52A1|TP-Link Systems Inc
3C5447|HUAWEI TECHNOLOGIES CO.,LTD
3C55DB|Shenzhen Skyworth Digital Technology CO., Ltd
3C5731|Cisco Systems, Inc
3C576C|Samsung Electronics Co.,Ltd
3C5836|Sagemcom Broadband SAS
3C585D|Sagemcom Broadband SAS
3C58C2|Intel Corporate
3C591E|TCL King Electrical Appliances (Huizhou) Co., Ltd
3C59C0|HUAWEI TECHNOLOGIES CO.,LTD
3C5A37|Samsung Electronics Co.,Ltd
3C5AB4|Google, Inc.
3C5CC3|Shenzhen First Blue Chip Technology Ltd
3C5CC4|Amazon Technologies Inc.
3C5EC3|Cisco Systems, Inc
3C6104|Juniper Networks
3C6105|Espressif Inc.
3C6200|Samsung Electronics Co.,Ltd
3C6278|SHENZHEN JETNET TECHNOLOGY CO.,LTD.
3C64CF|TP-Link Systems Inc
3C65D1|HUAWEI TECHNOLOGIES CO.,LTD
3C678C|HUAWEI TECHNOLOGIES CO.,LTD
3C6A48|TP-LINK TECHNOLOGIES CO.,LTD.
3C6AA7|Intel Corporate
3C6AD2|TP-Link Systems Inc.
3C6D66|NVIDIA Corporation
3C6D89|Apple, Inc.
3C6F9B|zte corporation
3C6FEA|Panasonic India Pvt. Ltd.
3C71BF|Espressif Inc.
3C7625|zte corporation
3C7787|Huawei Device Co., Ltd.
3C77E6|Hon Hai Precision Ind. Co.,Ltd.
3C7843|HUAWEI TECHNOLOGIES CO.,LTD
3C7895|TP-Link Systems Inc.
3C7C3F|ASUSTek COMPUTER INC.
3C7D0A|Apple, Inc.
3C7F6E|Xiaomi Communications Co Ltd
3C81D8|Sagemcom Broadband SAS
3C8375|Microsoft Corporation
3C8427|Espressif Inc.
3C846A|TP-LINK TECHNOLOGIES CO.,LTD.
3C869A|HUAWEI TECHNOLOGIES CO.,LTD
3C87CF|Quanta Computer Inc.
3C8A1F|Espressif Inc.
3C8AB0|Juniper Networks
3C8B7F|Cisco Systems, Inc
3C8BFE|Samsung Electronics Co.,Ltd
3C8C93|Juniper Networks
3C8D20|Google, Inc.
3C8F06|Shenzhen Libtor Technology Co.,Ltd
3C90E0|HUAWEI TECHNOLOGIES CO.,LTD
3C9157|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
3C9180|Liteon Technology Corporation
3C93F4|HUAWEI TECHNOLOGIES CO.,LTD
3C94D5|Juniper Networks
3C9509|Liteon Technology Corporation
3C970E|Wistron InfoComm(Kunshan)Co.,Ltd.
3C9722|shenzhen worldelite electronics co., LTD
3C9BC6|Huawei Device Co., Ltd.
3C9C0F|Intel Corporate
3C9D56|HUAWEI TECHNOLOGIES CO.,LTD
3C9F81|Shenzhen CATIC Bit Communications Technology Co.,Ltd
3C9FCD|Shenzhen Neoway Technology Co.,Ltd.
3CA00E|Shenzhen Skyworth Digital Technology CO., Ltd
3CA067|Liteon Technology Corporation
3CA070|Blink by Amazon
3CA10D|Samsung Electronics Co.,Ltd
3CA161|HUAWEI TECHNOLOGIES CO.,LTD
3CA37E|HUAWEI TECHNOLOGIES CO.,LTD
3CA6F6|Apple, Inc.
3CA7AE|zte corporation
3CA82A|Hewlett Packard
3CA916|Huawei Device Co., Ltd.
3CA9F4|Intel Corporate
3CAB8E|Apple, Inc.
3CAFB7|Xiaomi Communications Co Ltd
3CB15B|Avaya Inc
3CB233|Huawei Device Co., Ltd.
3CB922|HUAWEI TECHNOLOGIES CO.,LTD
3CBB73|Shenzhen Xinguodu Technology Co., Ltd.
3CBBFD|Samsung Electronics Co.,Ltd
3CBCD0|zte corporation
3CBD3E|Beijing Xiaomi Electronics Co., Ltd.
3CBD69|Nokia Shanghai Bell Co., Ltd.
3CBDD8|LG ELECTRONICS INC
3CBF60|Apple, Inc.
3CBFD7|Apple, Inc.
3CC03E|HUAWEI TECHNOLOGIES CO.,LTD
3CC079|Shenzhen One-Nine Intelligent Electronic Science and Technology Co., Ltd
3CC243|Nokia Corporation
3CC5C7|HUAWEI TECHNOLOGIES CO.,LTD
3CC801|Shenzhen Sundray Technologies company Limited
3CCD36|Apple, Inc.
3CCD40|Apple, Inc.
3CCD57|Beijing Xiaomi Mobile Software Co., Ltd
3CCD5D|HUAWEI TECHNOLOGIES CO.,LTD
3CCD93|LG ELECTRONICS INC
3CCE0D|Shenzhen juduoping Technology Co.,Ltd
3CCE73|Cisco Systems, Inc
3CD0F8|Apple, Inc.
3CD7DA|SK Mtek microelectronics(shenzhen)limited
3CD92B|Hewlett Packard
3CDA2A|zte corporation
3CDC75|Espressif Inc.
3CDCBC|Samsung Electronics Co.,Ltd
3CDD57|Apple, Inc.
3CDF1E|Cisco Systems, Inc
3CDFBD|HUAWEI TECHNOLOGIES CO.,LTD
3CE072|Apple, Inc.
3CE36B|Zhejiang Dahua Technology Co., Ltd.
3CE441|Amazon Technologies Inc.
3CE824|HUAWEI TECHNOLOGIES CO.,LTD
3CE86E|Hewlett Packard Enterprise
3CE90E|Espressif Inc.
3CE9F7|Intel Corporate
3CEF8C|Zhejiang Dahua Technology Co., Ltd.
3CF011|Intel Corporate
3CF652|zte corporation
3CF692|Huawei Device Co., Ltd.
3CF72A|Nokia Corporation
3CF748|Shenzhen Linsn Technology Development Co.,Ltd
3CF75D|Zyxel Communications Corporation
3CF7A4|Samsung Electronics Co.,Ltd
3CF808|HUAWEI TECHNOLOGIES CO.,LTD
3CF862|Intel Corporate
3CF9F0|zte corporation
3CFA06|Microsoft Corporation
3CFA30|Palo Alto Networks
3CFA43|HUAWEI TECHNOLOGIES CO.,LTD
3CFA80|HUAWEI TECHNOLOGIES CO.,LTD
3CFB02|Apple, Inc.
3CFB5C|Fiberhome Telecommunication Technologies Co.,LTD
3CFDFE|Intel Corporate
3CFEAC|Cisco Systems, Inc
3CFFD8|HUAWEI TECHNOLOGIES CO.,LTD
40017A|Cisco Systems, Inc
400634|Huawei Device Co., Ltd.
4006D5|Cisco Systems, Inc
400877|Xiaomi Communications Co Ltd
400E85|SAMSUNG ELECTRO-MECHANICS(THAILAND)
400EB9|HUAWEI TECHNOLOGIES CO.,LTD
400EF3|zte corporation
4011C3|Samsung Electronics Co.,Ltd
401277|Microsoft Corporation
401482|Cisco Systems, Inc
4014AD|Huawei Device Co., Ltd.
40163B|Samsung Electronics Co.,Ltd
40167E|ASUSTek COMPUTER INC.
40169F|TP-LINK TECHNOLOGIES CO.,LTD.
4018B1|Extreme Networks, Inc.
401C83|Intel Corporate
401CD4|Huawei Device Co., Ltd.
402230|Shenzhen SuperElectron Technology Co.,Ltd.
4022D8|Espressif Inc.
4024D2|Huawei Device Co., Ltd.
4025C2|Intel Corporate
402619|Apple, Inc.
402641|HUAWEI TECHNOLOGIES CO.,LTD
40268E|Shenzhen Photon Leap Technology Co., Ltd.
4027A8|Cisco Meraki
402BA1|Sony Corporation
402BD6|Espressif Inc.
403004|Apple, Inc.
40313C|XIAOMI Electronics,CO.,LTD
40331A|Apple, Inc.
4035E6|Samsung Electronics Co.,Ltd
4036B7|Juniper Networks
403B7B|Huawei Device Co., Ltd.
403CFC|Apple, Inc.
403F43|Extreme Networks, Inc.
403F8C|TP-LINK TECHNOLOGIES CO.,LTD.
4040A7|Sony Corporation
40410D|HUAWEI TECHNOLOGIES CO.,LTD
404244|Cisco Systems, Inc
4044CE|HUAWEI TECHNOLOGIES CO.,LTD
4045C4|HUAWEI TECHNOLOGIES CO.,LTD
40486E|Nokia Solutions and Networks GmbH & Co. KG
40490F|Hon Hai Precision Ind. Co.,Ltd.
404A03|Zyxel Communications Corporation
404CCA|Espressif Inc.
404D7F|Apple, Inc.
404D8E|HUAWEI TECHNOLOGIES CO.,LTD
404F42|HUAWEI TECHNOLOGIES CO.,LTD
4050B5|Shenzhen New Species Technology Co., Ltd.
40538C|LG Electronics
405493|zte corporation
405539|Cisco Systems, Inc
405582|Nokia
405B7F|Broadcom Limited
405CFD|Dell Inc.
405D82|NETGEAR
405EE1|Shenzhen H&T Intelligent Control Co.,Ltd.
405EF6|Samsung Electronics Co.,Ltd
406186|MICRO-STAR INT'L CO.,LTD
4065A3|Sagemcom Broadband SAS
406768|Huawei Device Co., Ltd.
406792|Cisco Systems, Inc
40679B|Shenzhen Skyworth Digital Technology CO., Ltd
4068F9|Shenzhen SuperElectron Technology Co.,Ltd.
406C8F|Apple, Inc.
406F27|HUAWEI TECHNOLOGIES CO.,LTD
4070F5|Apple, Inc.
407183|Juniper Networks
4074E0|Intel Corporate
4076A9|Huawei Device Co., Ltd.
40786A|Motorola Mobility LLC, a Lenovo Company
407911|Apple, Inc.
407A80|Nokia Corporation
407AA4|ZHEJIANG DAHUA TECHNOLOGYCO.,LTD
407C7D|Nokia
407D0F|HUAWEI TECHNOLOGIES CO.,LTD
407F5F|Juniper Networks
407FE0|Glory Star Technics (ShenZhen) Limited
4080E1|FN-LINK TECHNOLOGY Ltd.
40831D|Apple, Inc.
4083DE|Zebra Technologies Inc
4086CB|D-Link Corporation
408805|Motorola Mobility LLC, a Lenovo Company
40882F|Extreme Networks, Inc.
4088E0|Beijing Ereneben Information Technology Limited Shenzhen Branch
4089C2|Apple, Inc.
4089C6|Amazon Technologies Inc.
408BF6|Shenzhen TCL New Technology Co., Ltd
408C4C|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
408D5C|GIGA-BYTE TECHNOLOGY CO.,LTD.
408E2C|Microsoft Corporation
408EDF|Huawei Device Co., Ltd.
408F9D|Juniper Networks
409151|Espressif Inc.
40921A|Apple, Inc.
409595|TP-Link Systems Inc.
4098AD|Apple, Inc.
409922|AzureWave Technology Inc.
409B0D|Shenzhen Yourf Kwan Industrial Co., Ltd
409B21|Nokia
409BCD|D-Link International
409C28|Apple, Inc.
409EA4|Juniper Networks
409F38|AzureWave Technology Inc.
40A108|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
40A2DB|Amazon Technologies Inc.
40A3CC|Intel Corporate
40A44A|Google, Inc.
40A53B|Nokia
40A5EF|Shenzhen Four Seas Global Link Network Technology Co., Ltd.
40A654|HUAWEI TECHNOLOGIES CO.,LTD
40A677|Juniper Networks
40A6B7|Intel Corporate
40A6D9|Apple, Inc.
40A6E8|Cisco Systems, Inc
40A746|Broadcom Limited
40A8F0|Hewlett Packard
40A9CF|Amazon Technologies Inc.
40ACBF|Hangzhou Hikvision Digital Technology Co.,Ltd.
40AE30|TP-Link Systems Inc
40B034|Hewlett Packard
40B076|ASUSTek COMPUTER INC.
40B0FA|LG Electronics (Mobile Communications)
40B15C|HUAWEI TECHNOLOGIES CO.,LTD
40B215|Extreme Networks, Inc.
40B395|Apple, Inc.
40B3FA|Apple, Inc.
40B4CD|Amazon Technologies Inc.
40B4F0|Juniper Networks
40B570|Hangzhou Hikvision Digital Technology Co.,Ltd.
40B5C1|Cisco Systems, Inc
40B6E7|Huawei Device Co., Ltd.
40B70E|Huawei Device Co., Ltd.
40B82D|Ruckus Wireless
40B837|Sony Corporation
40B89A|Hon Hai Precision Ind. Co.,Ltd.
40B93C|Hewlett Packard Enterprise
40BA09|Dell Inc.
40BC60|Apple, Inc.
40BEEE|Shenzhen Yunding Information Technology Co.,Ltd
40C1F6|Shenzhen Jingxun Technology Co., Ltd.
40C245|Shenzhen Hexicom Technology Co., Ltd.
40C2BA|COMPAL INFORMATION (KUNSHAN) CO., LTD.
40C3BC|Huawei Device Co., Ltd.
40C711|Apple, Inc.
40C729|Sagemcom Broadband SAS
40C73C|Intel Corporate
40C81F|Shenzhen Xinguodu Technology Co., Ltd.
40CBA8|HUAWEI TECHNOLOGIES CO.,LTD
40CBC0|Apple, Inc.
40CE24|Cisco Systems, Inc
40D133|Intel Corporate
40D160|Apple, Inc.
40D32D|Apple, Inc.
40D3AE|Samsung Electronics Co.,Ltd
40DA5C|Apple, Inc.
40DCA5|Huawei Device Co., Ltd.
40DE17|Shenzhen Lanfeng Times Industrial Co.,Ltd.
40DE24|Samsung Electronics Co.,Ltd
40DEAD|Juniper Networks
40E11C|shenzhen Cloud High Communication Technology Co.,Ltd
40E1E4|Nokia Solutions and Networks GmbH & Co. KG
40E230|AzureWave Technology Inc.
40E317|Extreme Networks, Inc.
40E3D6|Hewlett Packard Enterprise
40E4C6|Nokia
40E64B|Apple, Inc.
40E767|Extreme Networks, Inc.
40E793|Shenzhen Siviton Technology Co.,Ltd
40E99B|SAMSUNG ELECTRO-MECHANICS(THAILAND)
40EB21|HUAWEI TECHNOLOGIES CO.,LTD
40EC99|Intel Corporate
40ECBD|Intel Corporate
40ED00|TP-Link Systems Inc
40EDCF|Apple, Inc.
40EE15|Zioncom Electronics (Shenzhen) Ltd.
40EE6D|HUAWEI TECHNOLOGIES CO.,LTD
40EEDD|HUAWEI TECHNOLOGIES CO.,LTD
40F02F|Liteon Technology Corporation
40F078|Cisco Systems, Inc
40F201|Sagemcom Broadband SAS
40F49F|Cisco Systems, Inc
40F4C9|FN-LINK TECHNOLOGY Ltd.
40F4EC|Cisco Systems, Inc
40F520|Espressif Inc.
40F6BC|Amazon Technologies Inc.
40F8DF|CANON INC.
40F946|Apple, Inc.
40FAFE|Motorola Mobility LLC, a Lenovo Company
440010|Apple, Inc.
440049|Amazon Technologies Inc.
44004D|HUAWEI TECHNOLOGIES CO.,LTD
4401BB|SHENZHEN BILIAN ELECTRONIC CO.，LTD
44032C|Intel Corporate
4403A7|Cisco Systems, Inc
44053F|Sagemcom Broadband SAS
4405B8|Huawei Device Co., Ltd.
44070B|Google, Inc.
4409B8|Salcomp (Shenzhen) CO., LTD.
4409C6|HUAWEI TECHNOLOGIES CO.,LTD
4409DA|Apple, Inc.
440BAB|Positivo Tecnologia S.A.
440C4B|HUAWEI TECHNOLOGIES CO.,LTD
441030|Google, Inc.
441244|Hewlett Packard Enterprise
4413D0|zte corporation
441524|Sagemcom Broadband SAS
441622|Microsoft Corporation
4416FA|Samsung Electronics Co.,Ltd
441793|Espressif Inc.
4418FD|Apple, Inc.
4419B6|Hangzhou Hikvision Digital Technology Co.,Ltd.
441A5C|Cisco Systems, Inc
441B88|Apple, Inc.
441BF6|Espressif Inc.
441C7F|Motorola Mobility LLC, a Lenovo Company
441CA8|Hon Hai Precision Ind. Co.,Ltd.
441D64|Espressif Inc.
441E98|Ruckus Wireless
441EA1|Hewlett Packard
44227C|HUAWEI TECHNOLOGIES CO.,LTD
44237C|Beijing Xiaomi Mobile Software Co., Ltd
4425F4|Apple, Inc.
44272E|Huawei Device Co., Ltd.
442A60|Apple, Inc.
442B03|Cisco Systems, Inc
442D49|Extreme Networks, Inc.
44303F|HUAWEI TECHNOLOGIES CO.,LTD
443192|Hewlett Packard
44321D|HUAWEI TECHNOLOGIES CO.,LTD
44322A|Avaya Inc
443262|zte corporation
44334C|SHENZHEN BILIAN ELECTRONIC CO.，LTD
443583|Apple, Inc.
44365D|Shenzhen HippStor Technology Co., Ltd
4437E6|Hon Hai Precision Ind. Co.,Ltd.
4438E8|Intel Corporate
443B32|Intelbras
443D54|Amazon Technologies Inc.
4441F0|zte corporation
444201|Amazon Technologies Inc.
44456F|SHENZHEN ONEGA TECHNOLOGY CO.,LTD
444648|Hon Hai Precision Industry Co.,LTD
4447CC|Hangzhou Hikvision Digital Technology Co.,Ltd.
4448C1|Hewlett Packard Enterprise
444988|Intel Corporate
4449C0|NVIDIA Corporation
444A37|Xiaomi Communications Co Ltd
444AD6|Shenzhen Rinocloud Technology Co.,Ltd.
444ADB|Apple, Inc.
444B7E|Fiberhome Telecommunication Technologies Co.,LTD
444C0C|Apple, Inc.
444E1A|Samsung Electronics Co.,Ltd
44552B|Samsung Electronics Co.,Ltd
4455B1|HUAWEI TECHNOLOGIES CO.,LTD
4455C4|Huawei Device Co., Ltd.
44579F|Beijing Xiaomi Mobile Software Co., Ltd
445829|Cisco SPVTG
445943|zte corporation
4459E3|HUAWEI TECHNOLOGIES CO.,LTD
445BED|Hewlett Packard Enterprise
445CE9|Samsung Electronics Co.,Ltd
445D5E|SHENZHEN Coolkit Technology CO.,LTD
445E82|Zyxel Communications Corporation
446370|LCFC(Hefei) Electronics Technology co., ltd
4463B6|Apple, Inc.
4463C2|Zyxel Communications Corporation
44643C|Cisco Systems, Inc
44650D|Amazon Technologies Inc.
4465E0|Merlion Consulting Services (Shenzhen) Co., Ltd
446690|TP-LINK TECHNOLOGIES CO.,LTD.
446747|HUAWEI TECHNOLOGIES CO.,LTD
446752|Wistron INFOCOMM (Zhongshan) CORPORATION
446A2E|HUAWEI TECHNOLOGIES CO.,LTD
446D57|Liteon Technology Corporation
446D6C|Samsung Electronics Co.,Ltd
446D7F|Amazon Technologies Inc.
446EE5|HUAWEI TECHNOLOGIES CO.,LTD
447147|Beijing Xiaomi Electronics Co.,Ltd
44746C|Sony Corporation
447654|HUAWEI TECHNOLOGIES CO.,LTD
447831|HUAWEI TECHNOLOGIES CO.,LTD
44783E|Samsung Electronics Co.,Ltd
447B30|Espressif Inc.
447B45|Amazon Technologies Inc.
447BBB|Shenzhen YOUHUA Technology Co., Ltd
4480EB|Motorola Mobility LLC, a Lenovo Company
4482E5|HUAWEI TECHNOLOGIES CO.,LTD
448500|Intel Corporate
448502|Shenzhen SuperElectron Technology Co.,Ltd.
4485DA|Shenzhen Skyworth Digital Technology CO., Ltd
448763|FN-LINK TECHNOLOGY Ltd.
448816|Cisco Systems, Inc
448A5B|Micro-Star INT'L CO., LTD.
448DD5|Cisco Systems, Inc
448F17|Samsung Electronics Co., Ltd. ARTIK
4490BB|Apple, Inc.
4494FC|NETGEAR
44975A|SHENZHEN FAST TECHNOLOGIES CO.,LTD
449A52|zte corporation
449BC1|HUAWEI TECHNOLOGIES CO.,LTD
449E8B|Apple, Inc.
449F46|Huawei Device Co., Ltd.
44A038|Huawei Device Co., Ltd.
44A10E|Apple, Inc.
44A191|HUAWEI TECHNOLOGIES CO.,LTD
44A3BB|Intel Corporate
44A3C7|zte corporation
44A56E|NETGEAR
44A642|Hangzhou Hikvision Digital Technology Co.,Ltd.
44A7F4|Apple, Inc.
44A842|Dell Inc.
44A8FC|Apple, Inc.
44AA50|Juniper Networks
44ADB1|Sagemcom Broadband SAS
44ADD9|Cisco Systems, Inc
44AE25|Cisco Systems, Inc
44AE44|Huawei Device Co., Ltd.
44AF28|Intel Corporate
44B176|Espressif Inc.
44B32D|TP-LINK TECHNOLOGIES CO.,LTD.
44B3C5|Huawei Device Co., Ltd.
44B4B2|Amazon Technologies Inc.
44B6BE|Cisco Systems, Inc
44BB3B|Google, Inc.
44BD8D|Espressif Inc.
44BDC8|Xiaomi Communications Co Ltd
44BE0B|HUAWEI TECHNOLOGIES CO.,LTD
44BE23|PEGATRON CORPORATION
44BFE3|Shenzhen Longtech Electronics Co.,Ltd
44C20C|Cisco Systems, Inc
44C277|Shenzhen Kingspec Electronics Technology Co., Ltd.
44C346|HUAWEI TECHNOLOGIES CO.,LTD
44C3B6|HUAWEI TECHNOLOGIES CO.,LTD
44C532|HUAWEI TECHNOLOGIES CO.,LTD
44C63C|Samsung Electronics Co.,Ltd
44C65D|Apple, Inc.
44C7FC|Huawei Device Co., Ltd.
44CBAD|Xiaomi Communications Co Ltd
44CE1D|Nokia
44D1FA|Shenzhen Yunlink Technology Co., Ltd
44D244|Seiko Epson Corporation
44D3AD|Shenzhen TINNO Mobile Technology Corp.
44D3CA|Cisco Systems, Inc
44D453|Sagemcom Broadband SAS
44D454|Sagemcom Broadband SAS
44D47F|INGENICO TERMINALS SAS
44D4E0|Sony Corporation
44D5CC|Amazon Technologies Inc.
44D791|HUAWEI TECHNOLOGIES CO.,LTD
44D832|AzureWave Technology Inc.
44D884|Apple, Inc.
44D9E7|Ubiquiti Inc
44DA30|Apple, Inc.
44DBBE|HUAWEI TECHNOLOGIES CO.,LTD
44DBD2|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
44DF65|Beijing Xiaomi Mobile Software Co., Ltd
44E08E|Cisco SPVTG
44E213|Beijing Xiaomi Mobile Software Co., Ltd
44E4D9|Cisco Systems, Inc
44E4E6|Extreme Networks, Inc.
44E517|Intel Corporate
44E59B|HUAWEI TECHNOLOGIES CO.,LTD
44E64A|Shenzhen iComm Semiconductor CO.,LTD
44E66E|Apple, Inc.
44E853|Apple, Inc.
44E968|HUAWEI TECHNOLOGIES CO.,LTD
44E9DD|Sagemcom Broadband SAS
44EA30|Samsung Electronics Co.,Ltd
44ECCE|Juniper Networks
44F09E|Apple, Inc.
44F21B|Apple, Inc.
44F436|zte corporation
44F459|Samsung Electronics Co.,Ltd
44F477|Juniper Networks
44F770|Beijing Xiaomi Mobile Software Co., Ltd
44F971|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
44FB42|Apple, Inc.
44FB5A|zte corporation
44FFBA|zte corporation
480020|Hewlett Packard Enterprise
480031|HUAWEI TECHNOLOGIES CO.,LTD
4800B3|Cisco Systems, Inc
4801C5|OnePlus Technology (Shenzhen) Co., Ltd
480234|HUAWEI TECHNOLOGIES CO.,LTD
4805E2|Huawei Device Co., Ltd.
480A28|Apple, Inc.
480EEC|TP-LINK TECHNOLOGIES CO.,LTD.
480FCF|Hewlett Packard
481258|HUAWEI TECHNOLOGIES CO.,LTD
48128F|HUAWEI TECHNOLOGIES CO.,LTD
48137E|Samsung Electronics Co.,Ltd
481BA4|Cisco Systems, Inc
481D70|Cisco SPVTG
481F2D|Shenzhen Jie Shi Lian Industrial Co.,LTD
48210B|PEGATRON CORPORATION
482218|Shenzhen Yipingfang Network Technology Co., Ltd.
482254|TP-Link Systems Inc
4825F3|Huawei Device Co., Ltd.
48262C|Apple, Inc.
4827C5|HUAWEI TECHNOLOGIES CO.,LTD
4827E2|Espressif Inc.
4827EA|Samsung Electronics Co.,Ltd
48282F|zte corporation
482952|Sagemcom Broadband SAS
482AE3|Wistron InfoComm(Kunshan)Co.,Ltd.
482CA0|Xiaomi Communications Co Ltd
482CD0|HUAWEI TECHNOLOGIES CO.,LTD
482CEA|Motorola Inc Business Light Radios
482E72|Cisco Systems, Inc
482F6B|Hewlett Packard Enterprise
482FD7|HUAWEI TECHNOLOGIES CO.,LTD
483106|NVIDIA Corporation
4831B7|Espressif Inc.
4831DB|Huawei Device Co., Ltd.
48352B|Apple, Inc.
48352E|Shenzhen Wolck Network Product Co.,LTD
483584|Huawei Device Co., Ltd.
4835AB|Apple, Inc.
483871|Huawei Device Co., Ltd.
483A02|Fortinet, Inc.
483B38|Apple, Inc.
483C0C|HUAWEI TECHNOLOGIES CO.,LTD
483F72|Samsung Electronics Co.,Ltd
483FDA|Espressif Inc.
483FE9|HUAWEI TECHNOLOGIES CO.,LTD
4840D5|Intel Corporate
48417B|Nokia Solutions and Networks GmbH & Co. KG
48435A|HUAWEI TECHNOLOGIES CO.,LTD
48437C|Apple, Inc.
4843DD|Amazon Technologies Inc.
484487|Cisco SPVTG
4844F7|Samsung Electronics Co.,Ltd
484520|Intel Corporate
4846C1|FN-LINK TECHNOLOGY LIMITED
4846FB|HUAWEI TECHNOLOGIES CO.,LTD
48474B|Huawei Device Co., Ltd.
484982|Huawei Device Co., Ltd.
484996|Huawei Device Co., Ltd.
4849C7|Samsung Electronics Co.,Ltd
484AE9|Hewlett Packard Enterprise
484BAA|Apple, Inc.
484C29|HUAWEI TECHNOLOGIES CO.,LTD
484C86|Huawei Device Co., Ltd.
484D7E|Dell Inc.
485073|Microsoft Corporation
485169|Samsung Electronics Co.,Ltd
4851B7|Intel Corporate
4851C5|Intel Corporate
4851CF|Intelbras
485519|Espressif Inc.
48555E|Shenzhen Skyworth Digital Technology CO., Ltd
48555F|Fiberhome Telecommunication Technologies Co.,LTD
485702|HUAWEI TECHNOLOGIES CO.,LTD
4857D2|Broadcom Limited
485929|LG Electronics (Mobile Communications)
4859A4|zte corporation
485A0D|Juniper Networks
485AB6|Hon Hai Precision Ind. Co.,Ltd.
485AEA|Fiberhome Telecommunication Technologies Co.,LTD
485B39|ASUSTek COMPUTER INC.
485D60|AzureWave Technology Inc.
485F08|TP-LINK TECHNOLOGIES CO.,LTD.
485F2D|Amazon Technologies Inc.
485FDF|zte corporation
48605F|LG Electronics (Mobile Communications)
4860BC|Apple, Inc.
4861EE|Samsung Electronics Co.,Ltd
486276|HUAWEI TECHNOLOGIES CO.,LTD
486345|Huawei Device Co., Ltd.
48684A|Intel Corporate
48706F|HUAWEI TECHNOLOGIES CO.,LTD
4870D4|Cisco Meraki
487310|Juniper Networks
487410|Cisco Systems, Inc
487412|OnePlus Technology (Shenzhen) Co., Ltd
48746E|Apple, Inc.
48785B|Hangzhou Hikvision Digital Technology Co.,Ltd.
48785E|Amazon Technologies Inc.
48794D|Samsung Electronics Co.,Ltd
487B2F|Microsoft Corporation
487B6B|HUAWEI TECHNOLOGIES CO.,LTD
487D2E|TP-LINK TECHNOLOGIES CO.,LTD.
488002|Cisco Systems, Inc
4882DF|Huawei Device Co., Ltd.
4883C7|Sagemcom Broadband SAS
4886E8|Microsoft Corporation
488759|Xiaomi Communications Co Ltd
4887B8|TCL King Electrical Appliances(Huizhou)Co.,Ltd
488899|Shenzhen SuperElectron Technology Co.,Ltd.
4888CA|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
4889E7|Intel Corporate
488B0A|Cisco Systems, Inc
488C63|Huawei Device Co., Ltd.
488EB7|Zebra Technologies Inc.
488EEF|HUAWEI TECHNOLOGIES CO.,LTD
488F4C|shenzhen trolink Technology Co.,Ltd
488F5A|Routerboard.com
48902F|LG Electronics (Mobile Communications)
4890F0|Dell Inc.
4891D5|Cisco Systems, Inc
4891F6|Shenzhen Reach software technology CO.,LTD
4896D9|zte corporation
4898AB|Wistron InfoComm(Chongqing)Co.,Ltd.
489A58|Samsung Electronics Co.,Ltd
489A5B|Shenzhen iComm Semiconductor CO.,LTD
489BD5|Extreme Networks, Inc.
489D31|Espressif Inc.
489DD1|Samsung Electronics Co.,Ltd
489EBD|HP Inc.
489ECB|Hewlett Packard Enterprise
48A0F8|Fiberhome Telecommunication Technologies Co.,LTD
48A170|Cisco Systems, Inc
48A195|Apple, Inc.
48A22D|Shenzhen Huaxuchang Telecom Technology Co.,Ltd
48A472|Intel Corporate
48A516|Huawei Device Co., Ltd.
48A6B8|Sonos, Inc.
48A74E|zte corporation
48A91C|Apple, Inc.
48A98A|Routerboard.com
48AABB|Sagemcom Broadband SAS
48AD08|HUAWEI TECHNOLOGIES CO.,LTD
48AD9A|Intel Corporate
48AFF3|Espressif Inc.
48B02D|NVIDIA Corporation
48B25D|HUAWEI TECHNOLOGIES CO.,LTD
48B423|Amazon Technologies Inc.
48B4C3|Hewlett Packard Enterprise
48B8A3|Apple, Inc.
48BA4E|Hewlett Packard
48BCE1|Samsung Electronics Co.,Ltd
48BD0E|Quanta Storage Inc.
48BD4A|HUAWEI TECHNOLOGIES CO.,LTD
48BF6B|Apple, Inc.
48C35A|LENOVO(BEIJING)CO., LTD.
48C381|TP-Link Systems Inc.
48C796|Samsung Electronics Co.,Ltd
48CA43|Espressif Inc.
48CA68|Apple, Inc.
48CDD3|HUAWEI TECHNOLOGIES CO.,LTD
48CFA9|HUAWEI TECHNOLOGIES CO.,LTD
48D224|Liteon Technology Corporation
48D24F|Sagemcom Broadband SAS
48D539|HUAWEI TECHNOLOGIES CO.,LTD
48D682|zte corporation
48D6D5|Google, Inc.
48D705|Apple, Inc.
48D845|Shenzhen Mainuoke Electronics Co., Ltd
48D890|FN-LINK TECHNOLOGY LIMITED
48DB50|HUAWEI TECHNOLOGIES CO.,LTD
48DC2D|HUAWEI TECHNOLOGIES CO.,LTD
48DCFB|Nokia Corporation
48DF37|Hewlett Packard Enterprise
48E150|Intel Corporate
48E15C|Apple, Inc.
48E1CA|Apple, Inc.
48E244|Hon Hai Precision Ind. Co.,Ltd.
48E27E|Sagemcom Broadband SAS
48E729|Espressif Inc.
48E7DA|AzureWave Technology Inc.
48E9F1|Apple, Inc.
48EA62|HP Inc.
48EAA9|ShenZhen C&D Electronics CO.Ltd.
48EC5B|Nokia Solutions and Networks GmbH & Co. KG
48EDE6|Zyxel Communications Corporation
48EE0C|D-Link International
48EF1C|Samsung Electronics Co.,Ltd
48EF61|Huawei Device Co., Ltd.
48F17F|Intel Corporate
48F6EE|Espressif Inc.
48F7BC|HUAWEI TECHNOLOGIES CO.,LTD
48F7F1|Nokia
48F8B3|Cisco-Linksys, LLC
48F8DB|HUAWEI TECHNOLOGIES CO.,LTD
48F8E1|Nokia
48F97C|Fiberhome Telecommunication Technologies Co.,LTD
48FC07|Huawei Device Co., Ltd.
48FC7C|Shenzhen Huidu Technology Co., Ltd.
48FD8E|HUAWEI TECHNOLOGIES CO.,LTD
48FDA3|Xiaomi Communications Co Ltd
4C0082|Cisco Systems, Inc
4C01F7|Cisco Systems, Inc
4C0220|Xiaomi Communications Co Ltd
4C034F|Intel Corporate
4C09B4|zte corporation
4C0A4E|Extreme Networks, Inc.
4C0BBE|Microsoft
4C0F3E|Intel Corporate
4C0F6E|Hon Hai Precision Ind. Co.,Ltd.
4C10D5|TP-LINK TECHNOLOGIES CO.,LTD.
4C11AE|Espressif Inc.
4C11BF|Zhejiang Dahua Technology Co., Ltd.
4C14A3|TCL Technoly Electronics (Huizhou) Co., Ltd.
4C1694|shenzhen sibituo Technology Co., Ltd
4C16F1|zte corporation
4C16FC|Juniper Networks
4C1744|Amazon Technologies Inc.
4C17EB|Sagemcom Broadband SAS
4C195D|Sagemcom Broadband SAS
4C1D96|Intel Corporate
4C1F86|Hangzhou Hikvision Digital Technology Co.,Ltd.
4C1FCC|HUAWEI TECHNOLOGIES CO.,LTD
4C20B8|Apple, Inc.
4C2113|Nokia Shanghai Bell Co., Ltd.
4C218C|Panasonic India Private limited
4C21D0|Sony Corporation
4C22C9|zte corporation
4C231A|Extreme Networks, Inc.
4C2578|Nokia Corporation
4C2B3B|Huawei Device Co., Ltd.
4C2E5E|Samsung Electronics Co.,Ltd
4C2EB4|Apple, Inc.
4C2EFE|Shenzhen Comnect Technology Co.,LTD
4C2FD7|Huawei Device Co., Ltd.
4C3275|Apple, Inc.
4C3488|Intel Corporate
4C364E|Panasonic Connect Co., Ltd.
4C3946|Samsung Electronics Co.,Ltd
4C3BDF|Microsoft Corporation
4C3C16|Samsung Electronics Co.,Ltd
4C3C8F|Shenzhen Jingxun Technology Co., Ltd.
4C3CE2|Huawei Device Co., Ltd.
4C421E|Cisco Systems, Inc
4C445B|Intel Corporate
4C4929|TCL King Electrical Appliances(Huizhou)Co.,Ltd
4C494F|zte corporation
4C496C|Intel Corporate
4C49E3|Xiaomi Communications Co Ltd
4C4AB4|Juniper Networks
4C4CD8|zte corporation
4C4E35|Cisco Systems, Inc
4C4FEE|OnePlus Technology (Shenzhen) Co., Ltd
4C5077|Huawei Device Co., Ltd.
4C5262|Fujitsu Technology Solutions GmbH
4C53FD|Amazon Technologies Inc.
4C5499|HUAWEI TECHNOLOGIES CO.,LTD
4C55B2|Xiaomi Communications Co Ltd
4C569D|Apple, Inc.
4C5739|Samsung Electronics Co.,Ltd
4C57CA|Apple, Inc.
4C5D3C|Cisco Systems, Inc
4C5D6A|Apple, Inc.
4C5E0C|Routerboard.com
4C5F70|Intel Corporate
4C60AD|Amazon Technologies Inc.
4C60DE|NETGEAR
4C617E|Huawei Device Co., Ltd.
4C62CD|Nokia
4C62DF|Hangzhou Hikvision Digital Technology Co.,Ltd.
4C631B|HUAWEI TECHNOLOGIES CO.,LTD
4C6371|Xiaomi Communications Co Ltd
4C63AD|Huawei Device Co., Ltd.
4C6641|SAMSUNG ELECTRO-MECHANICS(THAILAND)
4C66A6|Samsung Electronics Co.,Ltd
4C6BE8|Apple, Inc.
4C6CA1|Chipsea Technologies (Shenzhen) Crop.
4C6D58|Juniper Networks
4C710C|Cisco Systems, Inc
4C710D|Cisco Systems, Inc
4C7274|Shenzhenshi Xinzhongxin Technology Co.Ltd
4C72B9|PEGATRON CORPORATION
4C734F|Juniper Networks
4C74BF|Apple, Inc.
4C7525|Espressif Inc.
4C7625|Dell Inc.
4C7766|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
4C776D|Cisco Systems, Inc
4C77CB|Intel Corporate
4C796E|Intel Corporate
4C7975|Apple, Inc.
4C79BA|Intel Corporate
4C7A88|Cisco Systems, Inc
4C7C5F|Apple, Inc.
4C7CD9|Apple, Inc.
4C7F62|Nokia Corporation
4C8093|Intel Corporate
4C80FB|Google, Inc.
4C820C|Apple, Inc.
4C83DE|Cisco SPVTG
4C83FE|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
4C8421|Espressif Inc.
4C889E|Huawei Device Co., Ltd.
4C8BEF|HUAWEI TECHNOLOGIES CO.,LTD
4C8D53|HUAWEI TECHNOLOGIES CO.,LTD
4C8D79|Apple, Inc.
4C8E19|Xiaomi Communications Co Ltd
4C9614|Juniper Networks
4C97CC|Apple, Inc.
4C99E8|ZHEJIANG DAHUA TECHNOLOGYCO.,LTD
4C9EFF|Zyxel Communications Corporation
4C9FF1|Apple, Inc.
4CA38F|shenzhen trolink Technology Co.,Ltd
4CA56D|Samsung Electronics Co.,Ltd
4CA64D|Cisco Systems, Inc
4CA919|Tuya Smart Inc.
4CA954|Intel Corporate
4CAA16|AzureWave Technologies (Shanghai) Inc.
4CAB4F|Apple, Inc.
4CABFC|zte corporation
4CAC0A|zte corporation
4CAD35|Apple, Inc.
4CAE13|HUAWEI TECHNOLOGIES CO.,LTD
4CAE31|ShengHai Electronics (Shenzhen) Ltd
4CAEA3|Hewlett Packard Enterprise
4CB008|Shenzhen Gwelltimes Technology Co.,Ltd
4CB04A|Intel Corporate
4CB087|HUAWEI TECHNOLOGIES CO.,LTD
4CB16C|HUAWEI TECHNOLOGIES CO.,LTD
4CB199|Apple, Inc.
4CB1CD|Ruckus Wireless
4CB7E0|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
4CB8B5|Shenzhen YOUHUA Technology Co., Ltd
4CB910|Apple, Inc.
4CBB47|NVIDIA Corporation
4CBC42|Shenzhen Hangsheng Electronics Co.,Ltd.
4CBC48|Cisco Systems, Inc
4CBCA5|Samsung Electronics Co.,Ltd
4CBD8F|Hangzhou Hikvision Digital Technology Co.,Ltd.
4CC096|Shenzhen SuperElectron Technology Co.,Ltd.
4CC382|Espressif Inc.
4CC53E|Zyxel Communications Corporation
4CC5D9|Dell Inc.
4CC64C|Beijing Xiaomi Mobile Software Co., Ltd
4CC681|Shenzhen Aisat Electronic Co., Ltd.
4CC8A1|Cisco Meraki
4CC94F|Nokia
4CC95E|Samsung Electronics Co.,Ltd
4CCA95|Huawei Device Co., Ltd.
4CCBEA|Huawei Device Co., Ltd.
4CCBF5|zte corporation
4CCC34|Motorola Solutions Inc.
4CCC6A|Micro-Star INTL CO., LTD.
4CCDB6|Apple, Inc.
4CCF7C|HP Inc.
4CD012|Apple, Inc.
4CD0CB|HUAWEI TECHNOLOGIES CO.,LTD
4CD0DD|HUAWEI TECHNOLOGIES CO.,LTD
4CD0F9|Cisco Systems, Inc
4CD1A1|HUAWEI TECHNOLOGIES CO.,LTD
4CD546|Hewlett Packard Enterprise
4CD587|Hewlett Packard Enterprise
4CD629|HUAWEI TECHNOLOGIES CO.,LTD
4CD717|Dell Inc.
4CD73A|ShenZhen XinZhongXin Technology Co.， Ltd
4CD98F|Dell Inc.
4CDD31|Samsung Electronics Co.,Ltd
4CDE48|Huawei Device Co., Ltd.
4CE0DB|Xiaomi Communications Co Ltd
4CE175|Cisco Systems, Inc
4CE176|Cisco Systems, Inc
4CE20F|Xiaomi Communications Co Ltd
4CE4B6|Motorola Mobility LLC, a Lenovo Company
4CE650|Apple, Inc.
4CE65E|HUAWEI TECHNOLOGIES CO.,LTD
4CE6C0|Apple, Inc.
4CEA27|Shenzhen Skyworth Digital Technology CO., Ltd
4CEB42|Intel Corporate
4CEBB0|Samsung Electronics Co.,Ltd
4CEBD6|Espressif Inc.
4CEC0F|Cisco Systems, Inc
4CECEE|Samsung Electronics Co.,Ltd
4CEDFB|ASUSTek COMPUTER INC.
4CEF56|Shenzhen Sundray Technologies company Limited
4CEFC0|Amazon Technologies Inc.
4CF202|Xiaomi Communications Co Ltd
4CF475|Huawei Device Co., Ltd.
4CF55B|HUAWEI TECHNOLOGIES CO.,LTD
4CF5DC|Hangzhou Hikvision Digital Technology Co.,Ltd.
4CF95D|HUAWEI TECHNOLOGIES CO.,LTD
4CFA9A|Shenzhen Quanxing Technology Co., Ltd
4CFB45|HUAWEI TECHNOLOGIES CO.,LTD
5000E0|Cisco Systems, Inc
50016B|HUAWEI TECHNOLOGIES CO.,LTD
5001BB|Samsung Electronics Co.,Ltd
5001D9|HUAWEI TECHNOLOGIES CO.,LTD
500238|Nokia Shanghai Bell Co., Ltd.
500291|Espressif Inc.
5003CF|CANON INC.
5004B8|HUAWEI TECHNOLOGIES CO.,LTD
500604|Cisco Systems, Inc
5006AB|Cisco Systems, Inc
5006F5|Roku, Inc
5007C3|Amazon Technologies Inc.
500A9C|Extreme Networks, Inc.
500B23|HUAWEI TECHNOLOGIES CO.,LTD
500B26|HUAWEI TECHNOLOGIES CO.,LTD
500B32|Foxda Technology Industrial(ShenZhen)Co.,LTD
500F80|Cisco Systems, Inc
500FF5|Tenda Technology Co.,Ltd.Dongguan branch
50125C|Sony Corporation
50131D|Motorola Mobility LLC, a Lenovo Company
5014C1|HUAWEI TECHNOLOGIES CO.,LTD
5016F4|Motorola Mobility LLC, a Lenovo Company
5017FF|Cisco Systems, Inc
501AC5|Microsoft
501CB0|Cisco Systems, Inc
501CBF|Cisco Systems, Inc
501D93|HUAWEI TECHNOLOGIES CO.,LTD
501FC6|Apple, Inc.
5021EC|Huawei Device Co., Ltd.
5023A2|Apple, Inc.
502690|FUJITSU LIMITED
5027E4|Marvell Semiconductors
50284A|Intel Corporate
502873|Huawei Device Co., Ltd.
502B73|Tenda Technology Co.,Ltd.Dongguan branch
502D1D|Nokia Corporation
502DA2|Intel Corporate
502E91|AzureWave Technology Inc.
502F9B|Intel Corporate
502FA8|Cisco Systems, Inc
502FBB|Motorola Mobility LLC, a Lenovo Company
503123|FN-LINK TECHNOLOGY Ltd.
503237|Apple, Inc.
503275|Samsung Electronics Co.,Ltd
5033F0|YICHEN (SHENZHEN) TECHNOLOGY CO.LTD
503955|Cisco SPVTG
503AA0|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
503B70|Apple, Inc.
503CC4|Lenovo Mobile Communication Technology Ltd.
503D7F|Nokia Shanghai Bell Co., Ltd.
503DA1|Samsung Electronics Co.,Ltd
503DC6|Xiaomi Communications Co Ltd
503DD1|TP-Link Systems Inc.
503DE5|Cisco Systems, Inc
503EAA|TP-LINK TECHNOLOGIES CO.,LTD.
503F50|Huawei Device Co., Ltd.
504061|Nokia
504172|HUAWEI TECHNOLOGIES CO.,LTD
504289|zte corporation
504472|Motorola Mobility LLC, a Lenovo Company
50464A|HUAWEI TECHNOLOGIES CO.,LTD
50465D|ASUSTek COMPUTER INC.
504921|Cisco Systems, Inc
5049B0|Samsung Electronics Co.,Ltd
504A6E|NETGEAR
504B9E|Huawei Device Co., Ltd.
504F3B|Beijing Xiaomi Mobile Software Co., Ltd
5050A4|Samsung Electronics Co.,Ltd
50523B|Nokia
505527|LG Electronics (Mobile Communications)
5056BF|Samsung Electronics Co.,Ltd
50578A|Apple, Inc.
50579C|Seiko Epson Corporation
5057A8|Cisco Systems, Inc
50586F|Huawei Device Co., Ltd.
505A65|AzureWave Technology Inc.
505B1D|Shenzhen C-Data Technology Co., Ltd.
505BC2|Liteon Technology Corporation
505C88|Cisco Systems, Inc
505D7A|zte corporation
505DAC|HUAWEI TECHNOLOGIES CO.,LTD
505E24|zte corporation
50613C|ShenZhen XinZhongXin Technology Co.， Ltd
50617E|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
506184|Avaya Inc
5061BF|Cisco Systems, Inc
506313|Hon Hai Precision Ind. Co.,Ltd.
506382|HUAWEI TECHNOLOGIES CO.,LTD
506391|HUAWEI TECHNOLOGIES CO.,LTD
50642B|XIAOMI Electronics,CO.,LTD
5065F3|Hewlett Packard
5066E5|Huawei Device Co., Ltd.
5067AE|Cisco Systems, Inc
5067F0|Zyxel Communications Corporation
50680A|HUAWEI TECHNOLOGIES CO.,LTD
5068AC|Huawei Device Co., Ltd.
50695A|AiFamous（shenzhen）Technology Co.,Ltd
506A03|NETGEAR
506F0C|Sagemcom Broadband SAS
506F77|HUAWEI TECHNOLOGIES CO.,LTD
507164|Cisco Systems, Inc
5076AF|Intel Corporate
507705|Samsung Electronics Co.,Ltd
50787D|Espressif Inc.
5078B0|Huawei Device Co., Ltd.
5078B3|zte corporation
507A55|Apple, Inc.
507AC5|Apple, Inc.
507B9D|LCFC(Hefei) Electronics Technology co., ltd
507C6F|Intel Corporate
507C90|Huami (Shenzhen) Information Technology Co., Ltd
508114|Apple, Inc.
508140|HP Inc.
5082D5|Apple, Inc.
508492|Intel Corporate
508569|Samsung Electronics Co.,Ltd
508789|Cisco Systems, Inc
508811|Beijing Xiaomi Mobile Software Co., Ltd
508965|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
5089D1|Huawei Device Co., Ltd.
508A06|Tuya Smart Inc.
508A0F|SHENZHEN FISE TECHNOLOGY HOLDING CO.,LTD.
508A7F|HUAWEI TECHNOLOGIES CO.,LTD
508ACB|SHENZHEN MAXMADE TECHNOLOGY CO., LTD.
508BB9|Tuya Smart Inc.
508CC9|zte corporation
508D62|HUAWEI TECHNOLOGIES CO.,LTD
508D9E|HUAWEI TECHNOLOGIES CO.,LTD
508E49|Xiaomi Communications Co Ltd
508F4C|Xiaomi Communications Co Ltd
5091E3|TP-Link Systems Inc
50926A|Beijing Xiaomi Mobile Software Co., Ltd
5092B9|Samsung Electronics Co.,Ltd
5093CE|HUAWEI TECHNOLOGIES CO.,LTD
509546|HUAWEI TECHNOLOGIES CO.,LTD
509839|Xiaomi Communications Co Ltd
50995A|Amazon Technologies Inc.
509A4C|Dell Inc.
509A88|HUAWEI TECHNOLOGIES CO.,LTD
509B94|Shenzhen iComm Semiconductor CO.,LTD
509EA7|Samsung Electronics Co.,Ltd
509F27|HUAWEI TECHNOLOGIES CO.,LTD
509FB9|Shenzhen Skyworth Digital Technology CO., Ltd
50A009|Xiaomi Communications Co Ltd
50A015|Shenzhen Yipingfang Network Technology Co., Ltd.
50A0A4|Nokia
50A132|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
50A1F3|Huawei Device Co., Ltd.
50A4C8|Samsung Electronics Co.,Ltd
50A67F|Apple, Inc.
50A6D8|Apple, Inc.
50A72B|HUAWEI TECHNOLOGIES CO.,LTD
50A733|Ruckus Wireless
50ACB9|HUAWEI TECHNOLOGIES CO.,LTD
50AF4D|zte corporation
50AF73|Shenzhen Bitland Information Technology Co., Ltd.
50B03B|Sony Interactive Entertainment Inc.
50B127|Apple, Inc.
50B363|Digitron da Amazonia S/A
50B3B4|Shenzhen Furuilian Electronic Co.,Ltd.
50B7C3|Samsung Electronics Co.,Ltd
50BA84|Cisco Systems, Inc
50BBB5|AzureWave Technology Inc.
50BC96|Apple, Inc.
50BD5F|TP-LINK TECHNOLOGIES CO.,LTD.
50C58D|Juniper Networks
50C6AD|Fiberhome Telecommunication Technologies Co.,LTD
50C709|Juniper Networks
50C7BF|TP-LINK TECHNOLOGIES CO.,LTD.
50C8E5|Samsung Electronics Co.,Ltd
50CCF8|SAMSUNG ELECTRO MECHANICS CO., LTD.
50CD22|Avaya Inc
50D2F5|Beijing Xiaomi Mobile Software Co., Ltd
50D45C|Amazon Technologies Inc.
50D4F7|TP-LINK TECHNOLOGIES CO.,LTD.
50DA9E|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
50DAD6|Xiaomi Communications Co Ltd
50DB3F|SHENZHEN GONGJIN ELECTRONICS CO.,LT
50DCE7|Amazon Technologies Inc.
50DDAB|Samsung Electronics Co.,Ltd
50DE06|Apple, Inc.
50DE92|shenzhen worldelite electronics co., LTD
50E039|Zyxel Communications Corporation
50E085|Intel Corporate
50E0EF|Nokia
50E24E|zte corporation
50E452|Chipsea Technologies (Shenzhen) Corp.
50E4E0|Hewlett Packard Enterprise
50E538|Hangzhou Hikvision Digital Technology Co.,Ltd.
50E549|GIGA-BYTE TECHNOLOGY CO.,LTD.
50E666|Shenzhen Techtion Electronics Co., Ltd.
50EAD6|Apple, Inc.
50EB71|Intel Corporate
50EBF6|ASUSTek COMPUTER INC.
50EC50|Beijing Xiaomi Mobile Software Co., Ltd
50ED3C|Apple, Inc.
50EE32|Hon Hai Precision Industry Co.,LTD
50F0D3|Samsung Electronics Co.,Ltd
50F265|Apple, Inc.
50F351|Apple, Inc.
50F4EB|Apple, Inc.
50F520|Samsung Electronics Co.,Ltd
50F5DA|Amazon Technologies Inc.
50F722|Cisco Systems, Inc
50F7ED|Huawei Device Co., Ltd.
50F958|Huawei Device Co., Ltd.
50FA84|TP-LINK TECHNOLOGIES CO.,LTD.
50FB19|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
50FC9F|Samsung Electronics Co.,Ltd
50FE0C|AzureWave Technology Inc.
50FE39|Beijing Xiaomi Mobile Software Co., Ltd
540295|HUAWEI TECHNOLOGIES CO.,LTD
5404A6|ASUSTek COMPUTER INC.
5405DB|LCFC(Hefei) Electronics Technology co., ltd
540764|Huawei Device Co., Ltd.
54077D|NETGEAR
5408F1|SHENZHENLINGDECHUANGTECHNOLOGY CO.,LTD
540910|Apple, Inc.
540955|zte corporation
540A77|Fiberhome Telecommunication Technologies Co.,LTD
540A8A|Jlztlink Industry(ShenZhen)Co.,Ltd.
540DF9|Huawei Device Co., Ltd.
54102E|HUAWEI TECHNOLOGIES CO.,LTD
54104F|Samsung Electronics Co.,Ltd
5412CB|HUAWEI TECHNOLOGIES CO.,LTD
541310|HUAWEI TECHNOLOGIES CO.,LTD
541379|Hon Hai Precision Ind. Co.,Ltd.
5414F3|Intel Corporate
5416A5|Espressif Systems (Singapore) Pte. Ltd
541E56|Juniper Networks
541F8D|zte corporation
54211D|Huawei Device Co., Ltd.
54219D|Samsung Electronics Co.,Ltd
542259|HUAWEI TECHNOLOGIES CO.,LTD
5422F8|zte corporation
542369|HUAWEI TECHNOLOGIES CO.,LTD
5425EA|HUAWEI TECHNOLOGIES CO.,LTD
542618|HUAWEI TECHNOLOGIES CO.,LTD
54263D|Sony Corporation
542696|Apple, Inc.
54271E|AzureWave Technology Inc.
542758|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
542906|Apple, Inc.
542A1B|Sonos, Inc.
542A43|Apple, Inc.
542B1C|Amazon Technologies Inc.
542B76|zte corporation
542B8D|Apple, Inc.
542F2B|HUAWEI TECHNOLOGIES CO.,LTD
543204|Espressif Inc.
5432C7|Apple, Inc.
5433CB|Apple, Inc.
5434EF|HUAWEI TECHNOLOGIES CO.,LTD
543530|Hon Hai Precision Ind. Co.,Ltd.
543631|Intel Corporate
5439DF|HUAWEI TECHNOLOGIES CO.,LTD
543AD6|Samsung Electronics Co.,Ltd
543CED|Sagemcom Broadband SAS
543D37|Ruckus Wireless
543E64|Fiberhome Telecommunication Technologies Co.,LTD
5440AD|Samsung Electronics Co.,Ltd
544249|Sony Corporation
5443B2|Espressif Inc.
544408|Nokia Corporation
54443B|HUAWEI TECHNOLOGIES CO.,LTD
5444A3|Samsung Electronics Co.,Ltd
544617|zte corporation
54466B|Shenzhen CZTIC Electronic Technology Co., Ltd
5447CC|Sagemcom Broadband SAS
544810|Dell Inc.
5448E6|Beijing Xiaomi Mobile Software Co., Ltd
544A00|Cisco Systems, Inc
544B8C|Juniper Networks
544C8A|Microsoft Corporation
544E90|Apple, Inc.
544EF0|Roku, Inc
54511B|HUAWEI TECHNOLOGIES CO.,LTD
5451DE|Cisco Systems, Inc
545284|Huawei Device Co., Ltd.
5453ED|Sony Corporation
5455D5|Huawei Device Co., Ltd.
545618|Huawei Device Co., Ltd.
545925|HUAWEI TECHNOLOGIES CO.,LTD
545AA6|Espressif Inc.
545B86|Panasonic Automotive Systems Co.,Ltd
546009|Google, Inc.
54606D|HUAWEI TECHNOLOGIES CO.,LTD
5462E2|Apple, Inc.
5464D9|Sagemcom Broadband SAS
54666C|Shenzhen YOUHUA Technology Co., Ltd
546749|Google, Inc.
546751|Compal Broadband Networks, Inc.
5467E6|SHENZHEN MTC CO LTD
546990|HUAWEI TECHNOLOGIES CO.,LTD
546CAC|Intelbras
546CEB|Intel Corporate
5471DD|Huawei Device Co., Ltd.
54724F|Apple, Inc.
54735A|Huawei Device Co., Ltd.
547595|TP-LINK TECHNOLOGIES CO.,LTD.
5475D0|Cisco Systems, Inc
54778A|Hewlett Packard Enterprise
54781A|Cisco Systems, Inc
547885|SHENZHEN GIEC DIGITAL CO.,LTD
5478F0|zte corporation
547975|Nokia Corporation
547C69|Cisco Systems, Inc
547F54|INGENICO
547FEE|Cisco Systems, Inc
548028|Hewlett Packard Enterprise
54812D|PAX Computer Technology(Shenzhen) Ltd.
54833A|Zyxel Communications Corporation
5484DC|zte corporation
5486BC|Cisco Systems, Inc
54880E|SAMSUNG ELECTRO-MECHANICS(THAILAND)
5488D5|zte corporation
5488DE|Cisco Systems, Inc
548998|HUAWEI TECHNOLOGIES CO.,LTD
548ABA|Cisco Systems, Inc
548C81|Hangzhou Hikvision Digital Technology Co.,Ltd.
548CA0|Liteon Technology Corporation
548D5A|Intel Corporate
549209|HUAWEI TECHNOLOGIES CO.,LTD
5492BE|Samsung Electronics Co.,Ltd
549359|SHENZHEN TWOWING TECHNOLOGIES CO.,LTD.
549963|Apple, Inc.
549B12|Samsung Electronics Co.,Ltd
549C6A|Shenzhen Bilian Electronic Co.,Ltd
549DEA|Espressif Inc.
549F06|Nokia Shanghai Bell Co., Ltd.
549F13|Apple, Inc.
549F35|Dell Inc.
549FC6|Cisco Systems, Inc
54A050|ASUSTek COMPUTER INC.
54A274|Cisco Systems, Inc
54A31B|Shenzhen Linkworld Technology Co,.LTD
54A51B|HUAWEI TECHNOLOGIES CO.,LTD
54A552|Shenzhen WeSing Interactive Entertainment Technology Co., Ltd
54A637|HUAWEI TECHNOLOGIES CO.,LTD
54A6DB|Huawei Device Co., Ltd.
54A703|TP-LINK TECHNOLOGIES CO.,LTD.
54AB3A|Quanta Computer Inc.
54AE27|Apple, Inc.
54AF97|TP-Link Systems Inc
54B121|HUAWEI TECHNOLOGIES CO.,LTD
54B203|PEGATRON CORPORATION
54B27E|Sagemcom Broadband SAS
54B29D|Shenzhen YOUHUA Technology Co., Ltd
54B802|Samsung Electronics Co.,Ltd
54B80A|D-Link International
54B8DB|Apple, Inc.
54BAD6|HUAWEI TECHNOLOGIES CO.,LTD
54BAD9|Intelbras
54BD79|Samsung Electronics Co.,Ltd
54BE53|zte corporation
54BEF7|PEGATRON CORPORATION
54BF55|Juniper Networks
54BF64|Dell Inc.
54C415|Hangzhou Hikvision Digital Technology Co.,Ltd.
54C480|HUAWEI TECHNOLOGIES CO.,LTD
54C80F|TP-LINK TECHNOLOGIES CO.,LTD.
54C8CC|Shenzhen SDG Telecom Equipment Co.,Ltd.
54C9DF|FN-LINK TECHNOLOGY LIMITED
54CD10|Panasonic Mobile Communications Co.,Ltd.
54CDEE|ShenZhen Apexis Electronic Co.,Ltd
54CE82|zte corporation
54CF8D|HUAWEI TECHNOLOGIES CO.,LTD
54D17D|Samsung Electronics Co.,Ltd
54D299|TP-Link Systems Inc.
54D46F|Cisco SPVTG
54D7E3|Hewlett Packard Enterprise
54D9C6|Huawei Device Co., Ltd.
54DC1D|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
54DD21|Huawei Device Co., Ltd.
54DD4F|Samsung Electronics Co.,Ltd
54DED3|zte corporation
54DF24|Fiberhome Telecommunication Technologies Co.,LTD
54E005|Fiberhome Telecommunication Technologies Co.,LTD
54E032|Juniper Networks
54E140|INGENICO
54E15B|Huawei Device Co., Ltd.
54E1AD|LCFC(Hefei) Electronics Technology co., ltd
54E43A|Apple, Inc.
54E4BD|FN-LINK TECHNOLOGY LIMITED
54E4ED|Intel Corporate
54E61B|Apple, Inc.
54E63F|ShenZhen LingKeWeiEr Technology Co., Ltd.
54E6FC|TP-LINK TECHNOLOGIES CO.,LTD.
54E6FD|Sony Interactive Entertainment Inc.
54EAA8|Apple, Inc.
54EBE9|Apple, Inc.
54EC2F|Ruckus Wireless
54EE75|Wistron InfoComm(Kunshan)Co.,Ltd.
54EF33|SHENZHEN BILIAN ELECTRONIC CO.，LTD
54EF43|HUAWEI TECHNOLOGIES CO.,LTD
54EF92|Shenzhen Elink Technology Co., LTD
54F0B1|Hewlett Packard Enterprise
54F201|Samsung Electronics Co.,Ltd
54F294|Huawei Device Co., Ltd.
54F29F|HUNAN FN-LINK TECHNOLOGY LIMITED
54F607|Huawei Device Co., Ltd.
54F6E2|HUAWEI TECHNOLOGIES CO.,LTD
54FA3E|Samsung Electronics Co.,Ltd
54FA96|Nokia Solutions and Networks GmbH & Co. KG
54FCF0|Samsung Electronics Co.,Ltd
5800BB|Juniper Networks
5800E3|Liteon Technology Corporation
580205|AzureWave Technology Inc.
5803FB|Hangzhou Hikvision Digital Technology Co.,Ltd.
58044F|TP-Link Systems Inc.
5805D9|Seiko Epson Corporation
5807F8|Nokia Solutions and Networks GmbH & Co. KG
580987|Amazon Technologies Inc.
580A20|Cisco Systems, Inc
580AD4|Apple, Inc.
580E85|Sagemcom Broadband SAS
580FA5|Apple, Inc.
581031|Hon Hai Precision IND.CO.,LTD
58108C|Intelbras
581122|ASUSTek COMPUTER INC.
581626|Avaya Inc
58170C|Sony Corporation
581862|Sony Corporation
581CF8|Intel Corporate
581DD8|Sagemcom Broadband SAS
581F28|HUAWEI TECHNOLOGIES CO.,LTD
581FAA|Apple, Inc.
582059|Xiaomi Communications Co Ltd
582071|Samsung Electronics Co.,Ltd
5820B1|Hewlett Packard
58239B|Fiberhome Telecommunication Technologies Co.,LTD
582429|Google, Inc.
582575|HUAWEI TECHNOLOGIES CO.,LTD
582A93|Apple, Inc.
582ABD|Espressif Inc.
582AF7|HUAWEI TECHNOLOGIES CO.,LTD
582BD3|Espressif Inc.
582BDB|Pax AB
582FF7|Sagemcom Broadband SAS
58306E|Nokia
58355D|Huawei Device Co., Ltd.
5835D9|Cisco Systems, Inc
583653|Apple, Inc.
583879|RICOH COMPANY, LTD.
583BD9|Fiberhome Telecommunication Technologies Co.,LTD
583F54|LG Electronics (Mobile Communications)
58404E|Apple, Inc.
584120|TP-LINK TECHNOLOGIES CO.,LTD.
584498|Xiaomi Communications Co Ltd
584704|Shenzhen Webridge Technology Co.,Ltd
584822|Sony Corporation
58493B|Palo Alto Networks
584BBC|zte corporation
5850ED|Hangzhou Hikvision Digital Technology Co.,Ltd.
5851A3|Apple, Inc.
585595|Apple, Inc.
5855CA|Apple, Inc.
58569F|Cisco Systems, Inc
5856AA|Apple, Inc.
5856C2|HUAWEI TECHNOLOGIES CO.,LTD
5858CD|Extreme Networks, Inc.
5859C2|Extreme Networks, Inc.
585FF6|zte corporation
586010|shenzhen zovoton electronic co.,ltd
58605F|HUAWEI TECHNOLOGIES CO.,LTD
586356|FN-LINK TECHNOLOGY LIMITED
5864C4|Apple, Inc.
58666D|Apple, Inc.
58687A|Sagemcom Broadband SAS
586B14|Apple, Inc.
586C25|Intel Corporate
586D0C|Hewlett Packard Enterprise
586D67|Intel Corporate
586D8F|Cisco-Linksys, LLC
5872C9|zte corporation
5873D1|HUAWEI TECHNOLOGIES CO.,LTD
5873D8|Apple, Inc.
58769C|Palo Alto Networks
587961|Microsoft Corporation
5879E0|Samsung Electronics Co.,Ltd
587A4D|Stonesoft Corporation
587F57|Apple, Inc.
587F66|HUAWEI TECHNOLOGIES CO.,LTD
5882A8|Microsoft
588336|HUAWEI TECHNOLOGIES CO.,LTD
588670|Juniper Networks
58879F|Huawei Device Co., Ltd.
5887E2|Shenzhen Coship Electronics Co., Ltd.
588A5A|Dell Inc.
588B1C|Cisco Systems, Inc
588BF3|Zyxel Communications Corporation
588C81|Espressif Inc.
588D09|Cisco Systems, Inc
589043|Sagemcom Broadband SAS
5891CF|Intel Corporate
589204|zte corporation
589351|Huawei Device Co., Ltd.
589396|Ruckus Wireless
5893E8|Apple, Inc.
58946B|Intel Corporate
5894AE|Huawei Device Co., Ltd.
58957E|Huawei Device Co., Ltd.
58960A|LG Electronics
58961D|Intel Corporate
58971E|Cisco Systems, Inc
5897BD|Cisco Systems, Inc
589A3E|Amazon Technologies Inc.
58A023|Intel Corporate
58A2B5|LG Electronics (Mobile Communications)
58A639|Samsung Electronics Co.,Ltd
58A839|Intel Corporate
58A8E8|Amazon Technologies Inc.
58ABFB|Huawei Device Co., Ltd.
58AC78|Cisco Systems, Inc
58AD12|Apple, Inc.
58AE2B|Huawei Device Co., Ltd.
58AEA8|HUAWEI TECHNOLOGIES CO.,LTD
58AEF1|Fiberhome Telecommunication Technologies Co.,LTD
58B035|Apple, Inc.
58B10F|Samsung Electronics Co.,Ltd
58B18F|Huawei Device Co., Ltd.
58B3FC|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
58B623|Beijing Xiaomi Mobile Software Co., Ltd
58B633|Ruckus Wireless
58B965|Apple, Inc.
58BAD4|HUAWEI TECHNOLOGIES CO.,LTD
58BC27|Cisco Systems, Inc
58BE72|HUAWEI TECHNOLOGIES CO.,LTD
58BF25|Espressif Inc.
58BFEA|Cisco Systems, Inc
58C17A|Cambium Networks Limited
58C38B|Samsung Electronics Co.,Ltd
58C57E|Fiberhome Telecommunication Technologies Co.,LTD
58C5CB|Samsung Electronics Co.,Ltd
58CB52|Google, Inc.
58CE2A|Intel Corporate
58CF79|Espressif Inc.
58D061|HUAWEI TECHNOLOGIES CO.,LTD
58D312|zte corporation
58D349|Apple, Inc.
58D56E|D-Link International
58D61F|Ubiquiti Inc
58D759|HUAWEI TECHNOLOGIES CO.,LTD
58D812|TP-Link Systems Inc.
58D9C3|Motorola Mobility LLC, a Lenovo Company
58D9D5|Tenda Technology Co.,Ltd.Dongguan branch
58DF59|Cisco Systems, Inc
58E28F|Apple, Inc.
58E434|Juniper Networks
58E488|Amazon Technologies Inc.
58E4EB|FN-LINK TECHNOLOGY Ltd.
58E6BA|Apple, Inc.
58E6C5|Espressif Inc.
58EA1F|Beijing Xiaomi Mobile Software Co., Ltd
58ED99|zte corporation
58F2FC|Huawei Device Co., Ltd.
58F39C|Cisco Systems, Inc
58F8D7|HUAWEI TECHNOLOGIES CO.,LTD
58F987|HUAWEI TECHNOLOGIES CO.,LTD
58FB3E|Huawei Device Co., Ltd.
58FB84|Intel Corporate
58FB96|Ruckus Wireless
58FCC8|Honeywell
58FDB1|LG Electronics
58FDBE|Shenzhen Taikaida Technology Co., Ltd
58FE7E|zte corporation
58FFA1|zte corporation
5C013B|Espressif Inc.
5C0214|Beijing Xiaomi Mobile Software Co., Ltd
5C0339|HUAWEI TECHNOLOGIES CO.,LTD
5C0610|Cisco Meraki
5C07A6|HUAWEI TECHNOLOGIES CO.,LTD
5C0947|Apple, Inc.
5C0979|HUAWEI TECHNOLOGIES CO.,LTD
5C0A5B|SAMSUNG ELECTRO MECHANICS CO., LTD.
5C0B3B|HUAWEI TECHNOLOGIES CO.,LTD
5C0E8B|Extreme Networks, Inc.
5C101E|zte corporation
5C10C5|Samsung Electronics Co.,Ltd
5C13AC|Apple, Inc.
5C13CC|Apple, Inc.
5C15C5|Shenzhen SSC Technology Co. Ltd
5C167D|HUAWEI TECHNOLOGIES CO.,LTD
5C1720|Huawei Device Co., Ltd.
5C17CF|OnePlus Technology (Shenzhen) Co., Ltd
5C1BF4|Apple, Inc.
5C1DD9|Apple, Inc.
5C23C2|Apple, Inc.
5C260A|Dell Inc.
5C27D4|Shenzhen Qihu Intelligent Technology Company Limited
5C2886|Inventec(Chongqing) Corporation
5C2E59|Samsung Electronics Co.,Ltd
5C3192|Cisco Systems, Inc
5C337B|Google, Inc.
5C345B|Hangzhou Hikvision Digital Technology Co.,Ltd.
5C353B|Compal Broadband Networks, Inc.
5C36B8|TCL King Electrical Appliances (Huizhou) Co., Ltd
5C3977|Juniper Networks
5C3A3D|zte corporation
5C3C27|Samsung Electronics Co.,Ltd
5C3E06|Cisco Systems, Inc
5C3E1B|Apple, Inc.
5C4071|Xiaomi Communications Co Ltd
5C415A|Amazon.com, LLC
5C4527|Juniper Networks
5C4546|Shenzhen Water World Information Co.,Ltd.
5C4879|HUAWEI TECHNOLOGIES CO.,LTD
5C497D|Samsung Electronics Co.,Ltd
5C49FA|Shenzhen Guowei Shidai Communication Equipement Co., Ltd
5C4CA9|HUAWEI TECHNOLOGIES CO.,LTD
5C4DBF|zte corporation
5C5015|Cisco Systems, Inc
5C50D9|Apple, Inc.
5C5136|Samsung Electronics Co.,Ltd
5C514F|Intel Corporate
5C5181|Samsung Electronics Co.,Ltd
5C5188|Motorola Mobility LLC, a Lenovo Company
5C5230|Apple, Inc.
5C5284|Apple, Inc.
5C546D|HUAWEI TECHNOLOGIES CO.,LTD
5C57C8|Nokia Corporation
5C58E6|Palo Alto Networks
5C5948|Apple, Inc.
5C5AC7|Cisco Systems, Inc
5C5E0A|Samsung Electronics Co.,Ltd
5C5EAB|Juniper Networks
5C5EBB|HUAWEI TECHNOLOGIES CO.,LTD
5C5F67|Intel Corporate
5C60BA|HP Inc.
5C6117|HUAWEI TECHNOLOGIES CO.,LTD
5C625A|CANON INC.
5C628B|TP-Link Systems Inc
5C63B0|Fortinet, Inc.
5C63BF|TP-LINK TECHNOLOGIES CO.,LTD.
5C647A|HUAWEI TECHNOLOGIES CO.,LTD
5C648E|Zyxel Communications Corporation
5C64F1|Cisco Systems, Inc
5C6783|Intel Corporate
5C6A80|Zyxel Communications Corporation
5C6D20|Hon Hai Precision Ind. Co.,Ltd.
5C6F69|Broadcom Limited
5C7017|Apple, Inc.
5C7075|HUAWEI TECHNOLOGIES CO.,LTD
5C70A3|LG Electronics (Mobile Communications)
5C710D|Cisco Systems, Inc
5C76D5|Nokia
5C78F8|Huawei Device Co., Ltd.
5C7B5C|Shenzhen SDMC Technology CO.,Ltd.
5C7D5E|HUAWEI TECHNOLOGIES CO.,LTD
5C7DAE|zte corporation
5C7DF3|Fiberhome Telecommunication Technologies Co.,LTD
5C80B6|Intel Corporate
5C836C|Ruckus Wireless
5C8382|Nokia
5C838F|Cisco Systems, Inc
5C843C|Sony Interactive Entertainment Inc.
5C8505|Huawei Device Co., Ltd.
5C85F8|SHENZHEN KAIFA TECHNOLOGY CO.,LTD.
5C865C|Samsung Electronics Co.,Ltd
5C8730|Apple, Inc.
5C879C|Intel Corporate
5C899A|TP-LINK TECHNOLOGIES CO.,LTD.
5C89BC|Apple, Inc.
5C8A38|Hewlett Packard
5C8B6B|Amazon Technologies Inc.
5C8D4E|Apple, Inc.
5C8E8B|Shenzhen Linghai Electronics Co.,Ltd
5C9157|HUAWEI TECHNOLOGIES CO.,LTD
5C9175|Apple, Inc.
5C925E|Zioncom Electronics (Shenzhen) Ltd.
5C93A2|Liteon Technology Corporation
5C9462|Shenzhen Jiuzhou Electric Co.,LTD
5C95AE|Apple, Inc.
5C9656|AzureWave Technology Inc.
5C9666|Sony Interactive Entertainment Inc.
5C969D|Apple, Inc.
5C97F3|Apple, Inc.
5C9960|Samsung Electronics Co.,Ltd
5C9977|Apple, Inc.
5C9AA1|Huawei Device Co., Ltd.
5C9AD8|FUJITSU LIMITED
5C9BA6|Apple, Inc.
5CA39D|SAMSUNG ELECTRO MECHANICS CO., LTD.
5CA436|Shenzhen G-world Technology Incorporated Company
5CA47D|Hewlett Packard Enterprise
5CA48A|Cisco Systems, Inc
5CA4A4|Fiberhome Telecommunication Technologies Co.,LTD
5CA4F4|zte corporation
5CA62D|Cisco Systems, Inc
5CA64F|TP-Link Systems Inc.
5CA6E6|TP-Link Systems Inc
5CA86A|HUAWEI TECHNOLOGIES CO.,LTD
5CAAFD|Sonos, Inc.
5CAC3D|Samsung Electronics Co.,Ltd
5CAC4C|Hon Hai Precision Ind. Co.,Ltd.
5CAD76|Shenzhen TCL New Technology Co., Ltd
5CADBA|Apple, Inc.
5CADCF|Apple, Inc.
5CAF06|LG Electronics (Mobile Communications)
5CB00A|HUAWEI TECHNOLOGIES CO.,LTD
5CB12E|Cisco Systems, Inc
5CB13E|Sagemcom Broadband SAS
5CB26D|Intel Corporate
5CB2DF|Shenzhen Powerleader Storage Technology Co., Ltd.
5CB395|HUAWEI TECHNOLOGIES CO.,LTD
5CB43E|HUAWEI TECHNOLOGIES CO.,LTD
5CB47E|Intel Corporate
5CB524|Sony Corporation
5CB8B7|Apple, Inc.
5CB901|Hewlett Packard
5CBA2C|Hewlett Packard Enterprise
5CBA37|Microsoft Corporation
5CBBEE|zte corporation
5CBD9A|Huawei Device Co., Ltd.
5CC0A0|HUAWEI TECHNOLOGIES CO.,LTD
5CC1D7|Samsung Electronics Co.,Ltd
5CC1F2|HUAWEI TECHNOLOGIES CO.,LTD
5CC307|HUAWEI TECHNOLOGIES CO.,LTD
5CC41D|Stone Devices Sdn. Bhd.
5CC563|HUNAN FN-LINK TECHNOLOGY LIMITED
5CC5D4|Intel Corporate
5CC6D0|Skyworth Digital Technology(Shenzhen) Co.,Ltd
5CC786|ShenZhen Tengxin Electronics Manufacturing Co.,Ltd.
5CC787|Huawei Device Co., Ltd.
5CC9D3|PALLADIUM ENERGY ELETRONICA DA AMAZONIA LTDA
5CCA1A|Microsoft Mobile Oy
5CCAD3|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
5CCB99|Samsung Electronics Co.,Ltd
5CCD5B|Intel Corporate
5CCF7F|Espressif Inc.
5CD06E|Xiaomi Communications Co Ltd
5CD2E4|Intel Corporate
5CD33D|Samsung Electronics Co.,Ltd
5CD5B5|Shenzhen WiSiYiLink Technology Co.,Ltd
5CD89E|Huawei Device Co., Ltd.
5CD998|D-Link Corporation
5CDC49|Samsung Electronics Co.,Ltd
5CDE34|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
5CDF89|Ruckus Wireless
5CDFB8|Shenzhen Unionmemory Information System Limited
5CE0C5|Intel Corporate
5CE176|Cisco Systems, Inc
5CE28C|Zyxel Communications Corporation
5CE3B6|Fiberhome Telecommunication Technologies Co.,LTD
5CE42A|Intel Corporate
5CE50C|Beijing Xiaomi Mobile Software Co., Ltd
5CE747|HUAWEI TECHNOLOGIES CO.,LTD
5CE753|Shenzhen Intellirocks Tech. Co. Ltd.
5CE7A0|Nokia
5CE883|HUAWEI TECHNOLOGIES CO.,LTD
5CE8EB|Samsung Electronics Co.,Ltd
5CE91E|Apple, Inc.
5CE931|TP-Link Systems Inc
5CEA1D|Hon Hai Precision Ind. Co.,Ltd.
5CEB52|zte corporation
5CED8C|Hewlett Packard Enterprise
5CEDF4|Samsung Electronics Co.,Ltd
5CF4AB|Zyxel Communications Corporation
5CF51A|Zhejiang Dahua Technology Co., Ltd.
5CF5DA|Apple, Inc.
5CF6DC|Samsung Electronics Co.,Ltd
5CF7E6|Apple, Inc.
5CF938|Apple, Inc.
5CF96A|HUAWEI TECHNOLOGIES CO.,LTD
5CF9DD|Dell Inc.
5CFA25|Sagemcom Broadband SAS
5CFB7C|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
5CFC66|Cisco Systems, Inc
5CFF35|Wistron Corporation
5CFFA9|zte corporation
5CFFFF|Shenzhen Kezhonglong Optoelectronic Technology Co., Ltd
600194|Espressif Inc.
6001B1|HUAWEI TECHNOLOGIES CO.,LTD
600292|PEGATRON CORPORATION
600308|Apple, Inc.
60030C|Shenzhen YOUHUA Technology Co., Ltd
6006E3|Apple, Inc.
600810|HUAWEI TECHNOLOGIES CO.,LTD
600A8C|Shenzhen Sundray Technologies company Limited
600F6B|Apple, Inc.
60109E|HUAWEI TECHNOLOGIES CO.,LTD
60123C|HUAWEI TECHNOLOGIES CO.,LTD
60128B|CANON INC.
601466|zte corporation
60152B|Palo Alto Networks
60156F|TP-Link Systems Inc.
60182E|ShenZhen Protruly Electronic Ltd co.
60183A|Huawei Device Co., Ltd.
601888|zte corporation
601895|Dell Inc.
601929|VOLTRONIC POWER TECHNOLOGY(SHENZHEN) CORP.
601D56|Extreme Networks, Inc.
601D91|Motorola Mobility LLC, a Lenovo Company
601F56|HUAWEI TECHNOLOGIES CO.,LTD
602232|Ubiquiti Inc
6025ED|Hewlett Packard Enterprise
6026AA|Cisco Systems, Inc
6026EF|Hewlett Packard Enterprise
60292B|TP-LINK TECHNOLOGIES CO.,LTD.
602AD0|Cisco SPVTG
602D74|Extreme Networks, Inc.
602E20|HUAWEI TECHNOLOGIES CO.,LTD
602ED5|Apple, Inc.
6030B3|HUAWEI TECHNOLOGIES CO.,LTD
6030D4|Apple, Inc.
603197|Zyxel Communications Corporation
6032B1|TP-LINK TECHNOLOGIES CO.,LTD.
60334B|Apple, Inc.
6036DD|Intel Corporate
603A7C|TP-LINK TECHNOLOGIES CO.,LTD.
603AAF|Samsung Electronics Co.,Ltd
603CEE|LG Electronics (Mobile Communications)
603D29|HUAWEI TECHNOLOGIES CO.,LTD
603E5F|Apple, Inc.
60427F|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
60452E|Intel Corporate
6045BD|Microsoft
6045CB|ASUSTek COMPUTER INC.
6045CD|Sagemcom Broadband SAS
60470A|Shenzhen Zenith Intelligent Technology Co., Ltd.
604966|Shenzhen Dingsheng Technology Co., Ltd.
6049C1|Avaya Inc
604DE1|HUAWEI TECHNOLOGIES CO.,LTD
604F5B|Huawei Device Co., Ltd.
605317|Sandstone Technologies
605355|HUAWEI TECHNOLOGIES CO.,LTD
605375|HUAWEI TECHNOLOGIES CO.,LTD
6055F9|Espressif Inc.
6056B1|HUAWEI TECHNOLOGIES CO.,LTD
605718|Intel Corporate
6057C8|Apple, Inc.
605B30|Dell Inc.
605BB4|AzureWave Technology Inc.
605E4F|Huawei Device Co., Ltd.
605FAA|Huawei Device Co., Ltd.
60629A|Juniper Networks
60634C|D-Link International
606525|Apple, Inc.
6065F4|Chipsea Technologies (Shenzhen) Crop.
606682|SHENZHEN ATEKO PHOTOELECTRICITY CO.,LTD
606720|Intel Corporate
60684E|Samsung Electronics Co.,Ltd
606944|Apple, Inc.
606BB3|zte corporation
606BBD|Samsung Electronics Co.,Ltd
606C66|Intel Corporate
606DC7|Hon Hai Precision Ind. Co.,Ltd.
606EE8|Xiaomi Communications Co Ltd
60706C|Google, Inc.
607072|SHENZHEN HONGDE SMART LINK TECHNOLOGY CO., LTD
6070C0|Apple, Inc.
60735C|Cisco Systems, Inc
6073BC|zte corporation
60756C|LG Electronics
607623|Shenzhen E-Superlink Technology Co., Ltd
6077E2|Samsung Electronics Co.,Ltd
6079C9|HUAWEI TECHNOLOGIES CO.,LTD
607DDD|Shenzhen Shichuangyi Electronics Co.,Ltd
607EC9|Apple, Inc.
607ECD|HUAWEI TECHNOLOGIES CO.,LTD
607EDD|Microsoft Mobile Oy
607FCB|Samsung Electronics Co.,Ltd
608110|Apple, Inc.
608246|Apple, Inc.
608306|Huawei Device Co., Ltd.
608334|HUAWEI TECHNOLOGIES CO.,LTD
608373|Apple, Inc.
6083E7|TP-Link Systems Inc
608625|FN-LINK TECHNOLOGY Ltd.
608B0E|Apple, Inc.
608C4A|Apple, Inc.
608E08|Samsung Electronics Co.,Ltd
608F5C|Samsung Electronics Co.,Ltd
608FA4|Nokia Solutions and Networks GmbH & Co. KG
609217|Apple, Inc.
6092C8|Roku, Inc
609316|Apple, Inc.
609532|Zebra Technologies Inc.
609578|Samsung Electronics Co.,Ltd
6095BD|Apple, Inc.
6096A4|HUAWEI TECHNOLOGIES CO.,LTD
609849|Nokia Solutions and Networks India Private Limited
6099D1|Vuzix / Lenovo
609AC1|Apple, Inc.
609BB4|HUAWEI TECHNOLOGIES CO.,LTD
60A10A|Samsung Electronics Co.,Ltd
60A2C6|HUAWEI TECHNOLOGIES CO.,LTD
60A37D|Apple, Inc.
60A3E3|TP-LINK TECHNOLOGIES CO.,LTD.
60A44C|ASUSTek COMPUTER INC.
60A4B7|TP-Link Systems Inc
60A4D0|Samsung Electronics Co.,Ltd
60A5E2|Intel Corporate
60A6C5|HUAWEI TECHNOLOGIES CO.,LTD
60A730|Shenzhen Yipinfang Internet Technology Co.,Ltd
60A751|Huawei Device Co., Ltd.
60A8FE|Nokia Solutions and Networks GmbH & Co. KG
60A954|Cisco Systems, Inc
60AAEF|Huawei Device Co., Ltd.
60AB67|Xiaomi Communications Co Ltd
60AF6D|Samsung Electronics Co.,Ltd
60B0E8|Huawei Device Co., Ltd.
60B4A2|Samsung Electronics Co.,Ltd
60B617|Fiberhome Telecommunication Technologies Co.,LTD
60B705|Shenzhen Skyworth Digital Technology CO., Ltd
60B76E|Google, Inc.
60B9C0|Cisco Systems, Inc
60BBEB|HUAWEI TECHNOLOGIES CO.,LTD
60BD83|HUAWEI TECHNOLOGIES CO.,LTD
60BEB5|Motorola Mobility LLC, a Lenovo Company
60BEC4|Apple, Inc.
60C547|Apple, Inc.
60C5AD|Samsung Electronics Co.,Ltd
60C727|Digiboard Eletronica da Amazonia Ltda
60C78D|Juniper Networks
60C798|Verifone, Inc.
60C9AA|Nokia
60CA3A|Apple, Inc.
60CE41|HUAWEI TECHNOLOGIES CO.,LTD
60CF84|ASUSTek COMPUTER INC.
60D02C|Ruckus Wireless
60D039|Apple, Inc.
60D0A9|Samsung Electronics Co.,Ltd
60D15F|Futurepath Technology(Shenzhen)Co.,Ltd.
60D178|Cisco Systems, Inc
60D2DD|Shenzhen Baitong Putian Technology Co.,Ltd.
60D51B|Fujitsu Limited
60D561|Shenzhen Glazero Technology Co., Ltd.
60D755|HUAWEI TECHNOLOGIES CO.,LTD
60D819|Hon Hai Precision Ind. Co.,Ltd.
60D9A0|Lenovo Mobile Communication Technology Ltd.
60D9C7|Apple, Inc.
60DD10|Shenzhen Angxun Technology Co.,Ltd
60DD70|Apple, Inc.
60DD8E|Intel Corporate
60DE18|Apple, Inc.
60DE44|HUAWEI TECHNOLOGIES CO.,LTD
60DE94|HUAWEI TECHNOLOGIES CO.,LTD
60DEF3|HUAWEI TECHNOLOGIES CO.,LTD
60DEF4|Shenzhen iComm Semiconductor CO.,LTD
60E327|TP-LINK TECHNOLOGIES CO.,LTD.
60E32B|Intel Corporate
60E3AC|LG Electronics (Mobile Communications)
60E5D8|zte corporation
60E701|HUAWEI TECHNOLOGIES CO.,LTD
60EB69|Quanta Computer Inc.
60EE5C|SHENZHEN FAST TECHNOLOGIES CO.,LTD
60EFC6|Shenzhen Chima Technologies Co Limited
60F18A|HUAWEI TECHNOLOGIES CO.,LTD
60F262|Intel Corporate
60F445|Apple, Inc.
60F494|Hon Hai Precision Ind. Co.,Ltd.
60F549|Apple, Inc.
60F620|Sonos Inc.
60F677|Intel Corporate
60F723|Beijing Xiaomi Mobile Software Co., Ltd
60F81D|Apple, Inc.
60FA9D|HUAWEI TECHNOLOGIES CO.,LTD
60FAA7|SHENZHEN MTC CO LTD
60FACD|Apple, Inc.
60FB00|SHENZHEN BILIAN ELECTRONIC CO.，LTD
60FB42|Apple, Inc.
60FDA6|Apple, Inc.
60FEC5|Apple, Inc.
60FF12|Samsung Electronics Co.,Ltd
60FF9E|AzureWave Technology Inc.
64006A|Dell Inc.
6400F1|Cisco Systems, Inc
64037F|Samsung Electronics Co.,Ltd
6405E9|Shenzhen WayOS Technology Crop., Ltd.
64078C|HUAWEI TECHNOLOGIES CO.,LTD
6407F6|Samsung Electronics Co.,Ltd
640864|Cisco Systems, Inc
640980|Xiaomi Communications Co Ltd
640BD7|Apple, Inc.
640C91|Apple, Inc.
640D22|LG Electronics (Mobile Communications)
640DCE|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
6411A4|Motorola Mobility LLC, a Lenovo Company
641225|Cisco Systems, Inc
64136C|zte corporation
6413AB|HUAWEI TECHNOLOGIES CO.,LTD
64167F|Polycom
64168D|Cisco Systems, Inc
6416F0|HUAWEI TECHNOLOGIES CO.,LTD
6417CD|Samsung Electronics Co.,Ltd
6418DF|Sagemcom Broadband SAS
641B2F|Samsung Electronics Co.,Ltd
641CAE|Samsung Electronics Co.,Ltd
641CB0|Samsung Electronics Co.,Ltd
64200C|Apple, Inc.
642315|Huawei Device Co., Ltd.
642656|Shenzhen Fanweitai Technology Service Co.,Ltd
642737|Hon Hai Precision Ind. Co.,Ltd.
642753|Huawei Device Co., Ltd.
642943|D-Link Corporation
6429FF|HUAWEI TECHNOLOGIES CO.,LTD
642CAC|HUAWEI TECHNOLOGIES CO.,LTD
642E41|HUAWEI TECHNOLOGIES CO.,LTD
642F1C|HUAWEI TECHNOLOGIES CO.,LTD
643135|Apple, Inc.
643150|Hewlett Packard
6432A8|Intel Corporate
643AEA|Cisco Systems, Inc
643E0A|HUAWEI TECHNOLOGIES CO.,LTD
643E8C|HUAWEI TECHNOLOGIES CO.,LTD
6441E6|Apple, Inc.
6441FF|Shenzhen Wolf Technology Co., Ltd.
644212|Shenzhen Water World Information Co.,Ltd.
644842|Apple, Inc.
64497D|Intel Corporate
644A7D|Intel Corporate
644C36|Intel Corporate
644ED7|HP Inc.
644F56|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
645106|Hewlett Packard
6451F4|Huawei Device Co., Ltd.
6453E0|HUAWEI TECHNOLOGIES CO.,LTD
645601|TP-LINK TECHNOLOGIES CO.,LTD.
6456B5|Samsung Electronics Co.,Ltd
6457BA|Intel Corporate
645A36|Apple, Inc.
645AED|Apple, Inc.
645D86|Intel Corporate
645DD7|Shenzhen Lifesense Medical Electronics Co., Ltd.
645DF4|Samsung Electronics Co.,Ltd
645E10|HUAWEI TECHNOLOGIES CO.,LTD
646140|Huawei Device Co., Ltd.
646306|Xiaomi Communications Co Ltd
64644A|Beijing Xiaomi Mobile Software Co., Ltd
64649B|Juniper Networks
646624|Sagemcom Broadband SAS
6466B3|TP-LINK TECHNOLOGIES CO.,LTD.
6466D8|Samsung Electronics Co.,Ltd
6467CD|HUAWEI TECHNOLOGIES CO.,LTD
646A52|Avaya Inc
646CB2|Samsung Electronics Co.,Ltd
646D2F|Apple, Inc.
646D4E|HUAWEI TECHNOLOGIES CO.,LTD
646D6C|HUAWEI TECHNOLOGIES CO.,LTD
646E60|zte corporation
646E69|Liteon Technology Corporation
646E97|TP-LINK TECHNOLOGIES CO.,LTD.
646EE0|Intel Corporate
647002|TP-LINK TECHNOLOGIES CO.,LTD.
647033|Apple, Inc.
647366|Shenzhen Siera Technology Ltd
647520|zte corporation
6476BA|Apple, Inc.
647791|Samsung Electronics Co.,Ltd
647924|Huawei Device Co., Ltd.
647999|Sagemcom Broadband SAS
6479F0|Intel Corporate
647B1E|Sagemcom Broadband SAS
647BCE|Samsung Electronics Co.,Ltd
647CE8|Palo Alto Networks
648099|Intel Corporate
648214|FN-LINK TECHNOLOGY Ltd.
648505|zte corporation
64876C|HUAWEI TECHNOLOGIES CO.,LTD
648788|Juniper Networks
648914|Espressif Inc.
64899A|LG Electronics (Mobile Communications)
6489F1|Samsung Electronics Co.,Ltd
648F3E|Cisco Systems, Inc
6490C1|Beijing Xiaomi Mobile Software Co., Ltd
64956C|LG Electronics
649746|AzureWave Technology Inc.
649A08|Shenzhen SuperElectron Technology Co.,Ltd.
649ABE|Apple, Inc.
649C81|Qualcomm Inc.
649CF3|Fiberhome Telecommunication Technologies Co.,LTD
649D38|Google, Inc.
649E31|Beijing Xiaomi Mobile Software Co., Ltd
649EF3|Cisco Systems, Inc
64A0E7|Cisco Systems, Inc
64A198|Huawei Device Co., Ltd.
64A200|Xiaomi Communications Co Ltd
64A28A|Huawei Device Co., Ltd.
64A2F9|OnePlus Technology (Shenzhen) Co., Ltd
64A3CB|Apple, Inc.
64A5C3|Apple, Inc.
64A651|HUAWEI TECHNOLOGIES CO.,LTD
64A7DD|Avaya Inc
64A963|Huawei Device Co., Ltd.
64AC2B|Juniper Networks
64ACE0|Samsung Electronics Co.,Ltd
64AE0C|Cisco Systems, Inc
64B0A6|Apple, Inc.
64B0E8|Huawei Device Co., Ltd.
64B2B4|Fiberhome Telecommunication Technologies Co.,LTD
64B2E4|Shenzhen Skyworth Digital Technology CO., Ltd
64B310|Samsung Electronics Co.,Ltd
64B473|Xiaomi Communications Co Ltd
64B4E8|Shenzhen D-Robotics Co., Ltd.
64B5F2|Samsung Electronics Co.,Ltd
64B708|Espressif Inc.
64B853|Samsung Electronics Co.,Ltd
64B94E|Dell Technologies
64B9E8|Apple, Inc.
64BAA4|zte corporation
64BC0C|LG Electronics (Mobile Communications)
64BC43|HUAWEI TECHNOLOGIES CO.,LTD
64BC58|Intel Corporate
64BD6D|Apple, Inc.
64BF6B|HUAWEI TECHNOLOGIES CO.,LTD
64C045|Apple, Inc.
64C2DE|LG Electronics (Mobile Communications)
64C354|Avaya Inc
64C394|HUAWEI TECHNOLOGIES CO.,LTD
64C3D6|Juniper Networks
64C5F9|SHENZHEN TECNO TECHNOLOGY
64C6D2|Seiko Epson Corporation
64C753|Apple, Inc.
64C901|INVENTEC Corporation
64C905|Apple, Inc.
64C9F1|Amazon Technologies Inc.
64CC2E|Xiaomi Communications Co Ltd
64CDC2|Amazon Technologies Inc.
64D0D6|Samsung Electronics Co.,Ltd
64D154|Routerboard.com
64D2C4|Apple, Inc.
64D4DA|Intel Corporate
64D562|Huawei Device Co., Ltd.
64D608|Shenzhen Ailyworld Technology Co.,Ltd.
64D69A|Intel Corporate
64D7C0|Huawei Device Co., Ltd.
64D814|Cisco Systems, Inc
64D989|Cisco Systems, Inc
64DB38|zte corporation
64DB43|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
64DB8B|Hangzhou Hikvision Digital Technology Co.,Ltd.
64DBF7|Nokia Shanghai Bell Co., Ltd.
64DD68|Zyxel Communications Corporation
64DDE9|Xiaomi Communications Co Ltd
64DE6D|Intel Corporate
64E172|Shenzhen Qihoo Intelligent Technology Co.,Ltd
64E4A5|LG Electronics
64E682|Apple, Inc.
64E7D8|Samsung Electronics Co.,Ltd
64E833|Espressif Inc.
64E881|Hewlett Packard Enterprise
64E950|Cisco Systems, Inc
64EB8C|Seiko Epson Corporation
64EB94|zte corporation
64F69D|Cisco Systems, Inc
64F705|Huawei Device Co., Ltd.
64F81C|Huawei Technologies Co., Ltd.
64FA2B|Sagemcom Broadband SAS
64FD29|Zhejiang Dahua Technology Co., Ltd.
64FD96|Sagemcom Broadband SAS
680125|Amazon Technologies Inc.
6802B8|Compal Broadband Networks, Inc.
680489|Cisco Systems, Inc
680571|Samsung Electronics Co.,Ltd
6805CA|Intel Corporate
680715|Intel Corporate
68080D|Shenzhen Yingsheng Technology Co., LTD
680927|Apple, Inc.
680947|Espressif Inc.
681324|Huawei Device Co., Ltd.
6813F3|Amazon Technologies Inc.
681401|Hon Hai Precision Ind. Co.,Ltd.
681590|Sagemcom Broadband SAS
681729|Intel Corporate
681A47|Apple, Inc.
681AA4|Shenzhen Skyworth Digital Technology CO., Ltd
681AB2|zte corporation
681BEF|HUAWEI TECHNOLOGIES CO.,LTD
681C52|Cisco Systems, Inc
681DEF|Shenzhen CYX Technology Co., Ltd.
68228E|Juniper Networks
6822E5|Huawei Device Co., Ltd.
6823F4|Shenzhen Jinlangxin Technology Co., Ltd
6825DD|Espressif Inc.
682737|Samsung Electronics Co.,Ltd
68275F|zte corporation
68286C|Sony Interactive Entertainment Inc.
6828CF|Hewlett Packard Enterprise
682ADD|zte corporation
682C7B|Cisco Systems, Inc
682D83|SHENZHEN DINGHE COMMUNICATION COMPANY
682E3C|Ubiquiti Inc
682F67|Apple, Inc.
683036|Apple, Inc.
683045|HUAWEI TECHNOLOGIES CO.,LTD
683421|Intel Corporate
683563|SHENZHEN LIOWN ELECTRONICS CO.,LTD.
6837E9|Amazon Technologies Inc.
683A1E|Cisco Meraki
683B09|Apple, Inc.
683B78|Cisco Systems, Inc
683E26|Intel Corporate
683EC0|Apple, Inc.
68403C|Fiberhome Telecommunication Technologies Co.,LTD
684465|Apple, Inc.
684571|Huawei Device Co., Ltd.
6845CC|Apple, Inc.
6845F1|TOSHIBA CLIENT SOLUTIONS CO., LTD.
6847C5|Intel Corporate
684898|Samsung Electronics Co.,Ltd
684983|HUAWEI TECHNOLOGIES CO.,LTD
684992|Cisco Meraki
684A5F|Apple, Inc.
684AAE|HUAWEI TECHNOLOGIES CO.,LTD
684AE9|Samsung Electronics Co.,Ltd
684C25|Huawei Device Co., Ltd.
684CA8|Shenzhen Herotel Tech. Co., Ltd.
684DB6|Xiaomi Communications Co Ltd
684E05|HUNAN FN-LINK TECHNOLOGY LIMITED
684F64|Dell Inc.
685134|Hewlett Packard Enterprise
68545A|Intel Corporate
6854FD|Amazon Technologies Inc.
6855D4|Seiko Epson Corporation
68572D|Tuya Smart Inc.
685811|Fiberhome Telecommunication Technologies Co.,LTD
685ACF|Samsung Electronics Co.,Ltd
685B35|Apple, Inc.
685D43|Intel Corporate
685EDD|Apple, Inc.
686372|Huawei Device Co., Ltd.
68644B|Apple, Inc.
686725|Espressif Inc.
6867C7|Sagemcom Broadband SAS
686CE6|Microsoft Corporation
686DBC|Hangzhou Hikvision Digital Technology Co.,Ltd.
687161|Cisco Systems, Inc
687251|Ubiquiti Inc
6872C3|Samsung Electronics Co.,Ltd
68764F|Sony Corporation
687724|TP-LINK TECHNOLOGIES CO.,LTD.
6877DA|zte corporation
6878A8|Fiberhome Telecommunication Technologies Co.,LTD
687909|Cisco Systems, Inc
6879ED|SHARP Corporation
687A64|Intel Corporate
687BDC|Juniper Networks
687D00|Shenzhen YOUHUA Technology Co., Ltd
687D6B|Samsung Electronics Co.,Ltd
687DAC|Samsung Electronics Co.,Ltd
687DB4|Cisco Systems, Inc
687F74|Cisco-Linksys, LLC
687FF0|TP-Link Systems Inc
6881E0|HUAWEI TECHNOLOGIES CO.,LTD
6883CB|Apple, Inc.
68847E|FUJITSU LIMITED
6886A7|Cisco Systems, Inc
68871C|Motorola Mobility LLC, a Lenovo Company
6887BD|zte corporation
6887C6|Cisco Systems, Inc
6889C1|HUAWEI TECHNOLOGIES CO.,LTD
688AF0|zte corporation
688F84|HUAWEI TECHNOLOGIES CO.,LTD
688FC9|Zhuolian (Shenzhen) Communication Co., Ltd
689234|Ruckus Wireless
689268|Motorola Mobility LLC, a Lenovo Company
689423|Hon Hai Precision Ind. Co.,Ltd.
68944A|zte corporation
68951B|Huawei Device Co., Ltd.
68962E|HUAWEI TECHNOLOGIES CO.,LTD
68967B|Apple, Inc.
68974B|Shenzhen Costar Electronics Co. Ltd.
6899CD|Cisco Systems, Inc
689A21|Fiberhome Telecommunication Technologies Co.,LTD
689A87|Amazon Technologies Inc.
689B43|Huawei Device Co., Ltd.
689C70|Apple, Inc.
689CE2|Cisco Systems, Inc
689DD2|Espressif Inc.
689E0B|Cisco Systems, Inc
689E29|zte corporation
689E67|SHENZHEN FOCUSCOM TECHNOLOGIES CO., LTD
689E6A|Huawei Device Co., Ltd.
689FD4|Amazon Technologies Inc.
689FF0|zte corporation
68A03E|HUAWEI TECHNOLOGIES CO.,LTD
68A0F6|HUAWEI TECHNOLOGIES CO.,LTD
68A34F|Nokia
68A3C4|Liteon Technology Corporation
68A46A|HUAWEI TECHNOLOGIES CO.,LTD
68A593|Apple, Inc.
68A682|Shenzhen YOUHUA Technology Co., Ltd
68A729|Apple, Inc.
68A828|HUAWEI TECHNOLOGIES CO.,LTD
68A86D|Apple, Inc.
68AB09|Nokia
68AB1E|Apple, Inc.
68ABA9|Sagemcom Broadband SAS
68ABBC|Beijing Xiaomi Mobile Software Co., Ltd
68AE04|Shenzhen SuperElectron Technology Co.,Ltd.
68AE20|Apple, Inc.
68B35E|Shenzhen Neostra Technology Co.Ltd
68B599|Hewlett Packard
68B5E3|HUAWEI TECHNOLOGIES CO.,LTD
68B691|Amazon Technologies Inc.
68B6B3|Espressif Inc.
68B76B|Fiberhome Telecommunication Technologies Co.,LTD
68B8BB|Beijing Xiaomi Electronics Co.,Ltd
68B9D3|Shenzhen Trolink Technology CO, LTD
68BC0C|Cisco Systems, Inc
68BDAB|Cisco Systems, Inc
68BFC4|Samsung Electronics Co.,Ltd
68C44C|Xiaomi Communications Co Ltd
68C44D|Motorola Mobility LLC, a Lenovo Company
68C63A|Espressif Inc.
68C6AC|Intel Corporate
68CAC4|Apple, Inc.
68CAE4|Cisco Systems, Inc
68CC6E|HUAWEI TECHNOLOGIES CO.,LTD
68CCAE|Fortinet, Inc.
68D1BA|Shenzhen YOUHUA Technology Co., Ltd
68D1FD|Shenzhen Trimax Technology Co.,Ltd
68D482|SHENZHEN GONGJIN ELECTRONICS CO.,LT
68D79A|Ubiquiti Inc
68D927|HUAWEI TECHNOLOGIES CO.,LTD
68D93C|Apple, Inc.
68D972|Cisco Systems, Inc
68DBCA|Apple, Inc.
68DBF5|Amazon Technologies Inc.
68DDB7|TP-LINK TECHNOLOGIES CO.,LTD.
68DECE|Fiberhome Telecommunication Technologies Co.,LTD
68DFDD|Xiaomi Communications Co Ltd
68DFE4|Samsung Electronics Co.,Ltd
68E209|HUAWEI TECHNOLOGIES CO.,LTD
68E580|Apple, Inc.
68E59E|Cisco Systems, Inc
68E5D9|Fiberhome Telecommunication Technologies Co.,LTD
68E7C2|Samsung Electronics Co.,Ltd
68E905|Fiberhome Telecommunication Technologies Co.,LTD
68EBAE|Samsung Electronics Co.,Ltd
68ECC5|Intel Corporate
68ED57|Juniper Networks
68EDA4|Shenzhen Seavo Technology Co.,Ltd
68EE88|Shenzhen TINNO Mobile Technology Corp.
68EE8F|Espressif Inc.
68EE96|Cisco SPVTG
68EF43|Apple, Inc.
68EFBD|Cisco Systems, Inc
68EFDC|Apple, Inc.
68F0BC|Shenzhen LiWiFi Technology Co., Ltd
68F38E|Juniper Networks
68F543|HUAWEI TECHNOLOGIES CO.,LTD
68F63B|Amazon Technologies Inc.
68F728|LCFC(Hefei) Electronics Technology co., ltd
68F7D8|Microsoft Corporation
68F90F|Intel Corporate
68FB7E|Apple, Inc.
68FCCA|Samsung Electronics Co.,Ltd
68FDE8|Ruckus Wireless
68FE71|Espressif Inc.
68FEDA|Fiberhome Telecommunication Technologies Co.,LTD
68FEF7|Apple, Inc.
68FF7B|TP-LINK TECHNOLOGIES CO.,LTD.
6C006B|Samsung Electronics Co.,Ltd
6C0273|Shenzhen Jin Yun Video Equipment Co., Ltd.
6C028C|HUAWEI TECHNOLOGIES CO.,LTD
6C02E0|HP Inc.
6C0309|Cisco Systems, Inc
6C0370|Extreme Networks, Inc.
6C03B5|Cisco Systems, Inc
6C047A|HUAWEI TECHNOLOGIES CO.,LTD
6C0699|Beijing Xiaomi Mobile Software Co., Ltd
6C06D6|Huawei Device Co., Ltd.
6C09BF|Fiberhome Telecommunication Technologies Co.,LTD
6C0B5E|HP Inc.
6C0C9A|Amazon Technologies Inc.
6C0D34|Nokia
6C0DC4|Beijing Xiaomi Electronics Co., Ltd.
6C0E0D|Sony Corporation
6C1041|Shenzhen Skyworth Digital Technology CO., Ltd
6C11BA|zte corporation
6C1270|Apple, Inc.
6C13D5|Cisco Systems, Inc
6C146E|HUAWEI TECHNOLOGIES CO.,LTD
6C1544|Microsoft Corporation
6C1632|HUAWEI TECHNOLOGIES CO.,LTD
6C198F|D-Link International
6C19C0|Apple, Inc.
6C1A75|Huawei Device Co., Ltd.
6C1C71|Zhejiang Dahua Technology Co., Ltd.
6C1D2C|HUAWEI TECHNOLOGIES CO.,LTD
6C1F8A|Apple, Inc.
6C2056|Cisco Systems, Inc
6C22F7|Nokia Shanghai Bell Co., Ltd.
6C23B9|Sony Corporation
6C2408|LCFC(Hefei) Electronics Technology co., ltd
6C2483|Microsoft Mobile Oy
6C2636|HUAWEI TECHNOLOGIES CO.,LTD
6C2779|Microsoft Mobile Oy
6C2995|Intel Corporate
6C29D2|Cisco Systems, Inc
6C2ACB|Paxton Access Ltd
6C2B59|Dell Inc.
6C2CDC|Skyworth Digital Technology(Shenzhen) Co.,Ltd
6C2E85|Sagemcom Broadband SAS
6C2F2C|Samsung Electronics Co.,Ltd
6C2F80|Intel Corporate
6C2F8A|Samsung Electronics Co.,Ltd
6C310E|Cisco Systems, Inc
6C3491|HUAWEI TECHNOLOGIES CO.,LTD
6C3845|Fiberhome Telecommunication Technologies Co.,LTD
6C3A84|Shenzhen Aero-Startech. Co.Ltd
6C3AFF|Apple, Inc.
6C3B6B|Routerboard.com
6C3BE5|Hewlett Packard
6C3C7C|CANON INC.
6C3C8C|Dell Inc.
6C3DD8|Espressif Systems (Singapore) Pte. Ltd
6C3E6D|Apple, Inc.
6C4008|Apple, Inc.
6C410E|Cisco Systems, Inc
6C416A|Cisco Systems, Inc
6C41DE|HUAWEI TECHNOLOGIES CO.,LTD
6C442A|HUAWEI TECHNOLOGIES CO.,LTD
6C483F|Xiaomi Communications Co Ltd
6C48A6|Fiberhome Telecommunication Technologies Co.,LTD
6C4A85|Apple, Inc.
6C4B90|LiteON
6C4CBC|TP-Link Systems Inc.
6C4CE2|Intel Corporate
6C4D51|Shenzhen Ceres Technology Co., Ltd.
6C4D73|Apple, Inc.
6C4EF6|Cisco Systems, Inc
6C4F89|Zyxel Communications Corporation
6C4FA1|Cisco Systems, Inc
6C504D|Cisco Systems, Inc
6C51BF|Huawei Device Co., Ltd.
6C51E4|Huawei Device Co., Ltd.
6C5563|Samsung Electronics Co.,Ltd
6C558D|HUAWEI TECHNOLOGIES CO.,LTD
6C55B1|Amazon Technologies Inc.
6C5697|Amazon Technologies Inc.
6C5A34|Shenzhen Haitianxiong Electronic Co., Ltd.
6C5AB0|TP-Link Systems Inc
6C5AB5|TCL Technoly Electronics (Huizhou) Co., Ltd.
6C5D3A|Microsoft Corporation
6C5D63|ShenZhen Rapoo Technology Co., Ltd.
6C5E3B|Cisco Systems, Inc
6C5F1C|Lenovo Mobile Communication Technology Ltd.
6C6016|OnePlus Technology (Shenzhen) Co., Ltd
6C60D0|Huawei Device Co., Ltd.
6C626D|Micro-Star INT'L CO., LTD
6C6286|Nokia
6C62FE|Juniper Networks
6C63F8|Ubiquiti Inc
6C67EF|HUAWEI TECHNOLOGIES CO.,LTD
6C688A|Amazon Technologies Inc.
6C6A77|Intel Corporate
6C6C0F|HUAWEI TECHNOLOGIES CO.,LTD
6C6CD3|Cisco Systems, Inc
6C6F18|Stereotaxis, Inc.
6C709F|Apple, Inc.
6C70CB|Samsung Electronics Co.,Ltd
6C710D|Cisco Systems, Inc
6C71D2|HUAWEI TECHNOLOGIES CO.,LTD
6C71D9|AzureWave Technology Inc.
6C7220|D-Link International
6C72B8|LCFC(Hefei) Electronics Technology co., ltd
6C72E7|Apple, Inc.
6C7637|Huawei Device Co., Ltd.
6C7660|KYOCERA CORPORATION
6C7742|zte corporation
6C77F0|Huawei Device Co., Ltd.
6C78C1|Juniper Networks
6C7DB7|Cisco Meraki
6C7E67|Apple, Inc.
6C7F0C|Cisco Meraki
6C7F49|Huawei Device Co., Ltd.
6C8243|Huawei Device Co., Ltd.
6C8336|Samsung Electronics Co.,Ltd
6C8375|Broadcom Limited
6C8814|Intel Corporate
6C8B2F|zte corporation
6C8BD3|Cisco Systems, Inc
6C8D77|Cisco Systems, Inc
6C8DC1|Apple, Inc.
6C8FB5|Microsoft Mobile Oy
6C9188|Nokia
6C92CF|Broadcom Limited
6C9354|Yaojin Technology (Shenzhen) Co., LTD.
6C9466|Intel Corporate
6C94F8|Apple, Inc.
6C96CF|Apple, Inc.
6C976D|Motorola Mobility LLC, a Lenovo Company
6C9961|Sagemcom Broadband SAS
6C9989|Cisco Systems, Inc
6C999D|Amazon Technologies Inc.
6C9B02|Nokia Corporation
6C9CED|Cisco Systems, Inc
6C9E7C|Fiberhome Telecommunication Technologies Co.,LTD
6CA100|Intel Corporate
6CA4D1|Fiberhome Telecommunication Technologies Co.,LTD
6CA75F|zte corporation
6CA780|Nokia Corporation
6CA849|Avaya Inc
6CA858|Fiberhome Telecommunication Technologies Co.,LTD
6CAAB3|Ruckus Wireless
6CAB05|Cisco Systems, Inc
6CAB31|Apple, Inc.
6CACC2|Samsung Electronics Co.,Ltd
6CADF8|AzureWave Technology Inc.
6CAEE3|Nokia
6CB0CE|NETGEAR
6CB0FD|Shenzhen Xinghai Iot Technology Co.,Ltd
6CB133|Apple, Inc.
6CB158|TP-LINK TECHNOLOGIES CO.,LTD.
6CB227|Sony Video & Sound Products Inc.
6CB2AE|Cisco Systems, Inc
6CB311|Shenzhen Lianrui Electronics Co.,Ltd
6CB456|Espressif Inc.
6CB4FD|Huawei Device Co., Ltd.
6CB749|HUAWEI TECHNOLOGIES CO.,LTD
6CB7E2|HUAWEI TECHNOLOGIES CO.,LTD
6CB7F4|Samsung Electronics Co.,Ltd
6CB881|zte corporation
6CBAB8|Sagemcom Broadband SAS
6CC217|Hewlett Packard
6CC242|Shenzhen Skyworth Digital Technology CO., Ltd
6CC26B|Apple, Inc.
6CC3B2|Cisco Meraki
6CC49F|Hewlett Packard Enterprise
6CC7EC|SAMSUNG ELECTRO-MECHANICS(THAILAND)
6CC840|Espressif Inc.
6CCDD6|NETGEAR
6CD008|zte corporation
6CD032|LG Electronics
6CD1E5|HUAWEI TECHNOLOGIES CO.,LTD
6CD2BA|zte corporation
6CD552|SHENZHEN BILIAN ELECTRONIC CO.，LTD
6CD63F|HUAWEI TECHNOLOGIES CO.,LTD
6CD68A|LG Electronics (Mobile Communications)
6CD6E3|Cisco Systems, Inc
6CD704|HUAWEI TECHNOLOGIES CO.,LTD
6CD719|Fiberhome Telecommunication Technologies Co.,LTD
6CDD30|Cisco Systems, Inc
6CDDBC|Samsung Electronics Co.,Ltd
6CDEA9|Cisco Meraki
6CE210|Espressif Systems (Singapore) Pte. Ltd
6CE5C9|Apple, Inc.
6CE85C|Apple, Inc.
6CE873|TP-LINK TECHNOLOGIES CO.,LTD.
6CE874|HUAWEI TECHNOLOGIES CO.,LTD
6CE907|Nokia Corporation
6CEBB6|HUAWEI TECHNOLOGIES CO.,LTD
6CEC5A|Hon Hai Precision Ind. CO.,Ltd.
6CECA1|SHENZHEN CLOU ELECTRONICS CO. LTD.
6CEEF7|shenzhen scodeno technology co., Ltd.
6CEFBD|Cisco Meraki
6CEFC6|SHENZHEN TWOWING TECHNOLOGIES CO.,LTD.
6CF049|GIGA-BYTE TECHNOLOGY CO.,LTD.
6CF2D8|CANON INC.
6CF373|Samsung Electronics Co.,Ltd
6CF37F|Hewlett Packard Enterprise
6CF6DA|Intel Corporate
6CF712|Nokia Solutions and Networks GmbH & Co. KG
6CF784|Xiaomi Communications Co Ltd
6CFA58|Avaya Inc
6CFA89|Cisco Systems, Inc
6CFE54|Intel Corporate
6CFFCE|Sagemcom Broadband SAS
7001B5|Cisco Systems, Inc
70039F|Espressif Inc.
70041D|Espressif Inc.
700514|LG Electronics (Mobile Communications)
700810|Intel Corporate
700894|Liteon Technology Corporation
700971|Samsung Electronics Co.,Ltd
700B01|Sagemcom Broadband SAS
700B4F|Cisco Systems, Inc
700F6A|Cisco Systems, Inc
700FC7|SHENZHEN IKINLOOP TECHNOLOGY CO.,LTD.
70105C|Cisco Systems, Inc
70106F|Hewlett Packard Enterprise
70110E|zte corporation
701124|Apple, Inc.
701384|Apple, Inc.
7014A6|Apple, Inc.
7015FB|Intel Corporate
70188B|Hon Hai Precision Ind. Co.,Ltd.
7018A7|Cisco Systems, Inc
70192F|HUAWEI TECHNOLOGIES CO.,LTD
701A04|Liteon Technology Corporation
701AB8|Intel Corporate
701CE7|Intel Corporate
701D08|99IOT Shenzhen co.,ltd
701F3C|Samsung Electronics Co.,Ltd
701F53|Cisco Systems, Inc
702084|Hon Hai Precision Industry Co., Ltd.
70217F|Xiaomi Communications Co Ltd
7022FE|Apple, Inc.
702526|Nokia
702605|SONY Visual Products Inc.
70287D|Google, Inc.
70288B|Samsung Electronics Co.,Ltd
702900|Shenzhen ChipTrip Technology Co,Ltd
702AD5|Samsung Electronics Co.,Ltd
702E22|zte corporation
702F35|HUAWEI TECHNOLOGIES CO.,LTD
703018|Avaya Inc
70317F|Apple, Inc.
70320C|Ruckus Wireless
703217|Intel Corporate
703509|Cisco Systems, Inc
7038EE|Avaya Inc
703A0E|Hewlett Packard Enterprise
703A2D|Shenzhen V-Link Technology CO., LTD.
703A51|Xiaomi Communications Co Ltd
703A73|Shenzhen Sundray Technologies company Limited
703A8C|Shenzhen Skyworth Digital Technology CO., Ltd
703ACB|Google, Inc.
703AD8|Shenzhen Afoundry Electronic Co., Ltd
703C69|Apple, Inc.
703EAC|Apple, Inc.
7040FF|Huawei Device Co., Ltd.
70441C|SHENZHEN KAIFA TECHNOLOGY CO.,LTD.
704698|HUAWEI TECHNOLOGIES CO.,LTD
704777|Ruckus Wireless
70480F|Apple, Inc.
7049A2|Zyxel Communications Corporation
704BCA|Espressif Inc.
704CA2|Apple, Inc.
704CA5|Fortinet, Inc.
704CB6|Shenzhen SuperElectron Technology Co.,Ltd.
704D7B|ASUSTek COMPUTER INC.
704E66|SHENZHEN FAST TECHNOLOGIES CO.,LTD
704E6B|HUAWEI TECHNOLOGIES CO.,LTD
704EE0|Samsung Electronics Co.,Ltd
704F08|Shenzhen Huisheng Information Technology Co., Ltd.
704F57|TP-LINK TECHNOLOGIES CO.,LTD.
7052C5|Avaya Inc
7054D2|PEGATRON CORPORATION
7054F5|HUAWEI TECHNOLOGIES CO.,LTD
705681|Apple, Inc.
705812|Panasonic Corporation AVC Networks Company
705A0F|Hewlett Packard
705AAC|Samsung Electronics Co.,Ltd
705AB6|COMPAL INFORMATION (KUNSHAN) CO., LTD.
705FA3|Xiaomi Communications Co Ltd
70617B|Cisco Systems, Inc
7062B8|D-Link International
7062CB|Apple, Inc.
70662A|Sony Interactive Entertainment Inc.
706655|AzureWave Technology Inc.
7066B9|Huawei Device Co., Ltd.
706871|FN-LINK TECHNOLOGY Ltd.
70695A|Cisco Systems, Inc
706AC9|zte corporation
706BB9|Cisco Systems, Inc
706D15|Cisco Systems, Inc
706E10|HUAWEI TECHNOLOGIES CO.,LTD
706E6D|Cisco Systems, Inc
70700D|Apple, Inc.
707013|HUAWEI TECHNOLOGIES CO.,LTD
70708B|Cisco Systems, Inc
7070AA|Amazon Technologies Inc.
7070D5|HUAWEI TECHNOLOGIES CO.,LTD
7071BC|PEGATRON CORPORATION
70720D|Lenovo Mobile Communication Technology Ltd.
70723C|HUAWEI TECHNOLOGIES CO.,LTD
7072FE|Apple, Inc.
707362|HUAWEI TECHNOLOGIES CO.,LTD
7073CB|Apple, Inc.
707781|Hon Hai Precision Ind. Co.,Ltd.
707990|HUAWEI TECHNOLOGIES CO.,LTD
7079B3|Cisco Systems, Inc
707BE8|HUAWEI TECHNOLOGIES CO.,LTD
707C69|Avaya Inc
707CE3|HUAWEI TECHNOLOGIES CO.,LTD
707D95|Shenzhen City LinwlanTechnology Co. Ltd.
707DA1|Sagemcom Broadband SAS
707DB9|Cisco Systems, Inc
708105|Cisco Systems, Inc
7081EB|Apple, Inc.
708540|Skyworth Digital Technology(Shenzhen) Co.,Ltd
708976|Tuya Smart Inc.
708A09|HUAWEI TECHNOLOGIES CO.,LTD
708BCD|ASUSTek COMPUTER INC.
708CB6|HUAWEI TECHNOLOGIES CO.,LTD
708CF2|Apple, Inc.
708D09|Nokia Corporation
7090B7|Huawei Device Co., Ltd.
709684|Apple, Inc.
709751|Beijing Xiaomi Mobile Software Co., Ltd
709883|SHENZHEN KAYAN ELECTRONICS., LTD.
70991C|Shenzhen Honesty Electronics Co.,Ltd
709AC4|Huawei Device Co., Ltd.
709BA5|Shenzhen Y&D Electronics Co.,LTD.
709C45|HUAWEI TECHNOLOGIES CO.,LTD
709CD1|Intel Corporate
709E29|Sony Interactive Entertainment Inc.
709F2D|zte corporation
70A04B|Intel Corporate
70A2B3|Apple, Inc.
70A56A|Shenzhen C-Data Technology Co., Ltd.
70A6CC|Intel Corporate
70A741|Ubiquiti Inc
70A8A5|Microsoft Corporation
70A8D3|Intel Corporate
70A8E3|HUAWEI TECHNOLOGIES CO.,LTD
70A983|Cisco Systems, Inc
70ACD7|Shenzhen YOUHUA Technology Co., Ltd
70AD43|Blink by Amazon
70AE2A|Apple, Inc.
70AED5|Apple, Inc.
70AF09|Espressif Inc.
70AF6A|SHENZHEN FENGLIAN TECHNOLOGY CO., LTD.
70B035|Shenzhen Zowee Technology Co., Ltd
70B13D|Samsung Electronics Co.,Ltd
70B258|Ruckus Wireless
70B306|Apple, Inc.
70B317|Cisco Systems, Inc
70B51A|Huawei Device Co., Ltd.
70B5E8|Dell Inc.
70B7E4|Broadcom Limited
70B8F6|Espressif Inc.
70B921|Fiberhome Telecommunication Technologies Co.,LTD
70B9BB|Shenzhen Hankvision Technology CO.,LTD
70BB5B|Apple, Inc.
70BBE9|Xiaomi Communications Co Ltd
70BC10|Microsoft Corporation
70BC48|Cisco Systems, Inc
70BD96|Cisco Systems, Inc
70C288|Intel Corporate
70C7F2|HUAWEI TECHNOLOGIES CO.,LTD
70C94E|Liteon Technology Corporation
70C9C6|Cisco Systems, Inc
70CA4D|Shenzhen lnovance Technology Co.,Ltd.
70CA97|Ruckus Wireless
70CA9B|Cisco Systems, Inc
70CD0D|Intel Corporate
70CD60|Apple, Inc.
70CE8C|Samsung Electronics Co.,Ltd
70CF49|Intel Corporate
70D313|HUAWEI TECHNOLOGIES CO.,LTD
70D379|Cisco Systems, Inc
70D51E|Fiberhome Telecommunication Technologies Co.,LTD
70D823|Intel Corporate
70D8C2|Intel Corporate
70DA48|Cisco Systems, Inc
70DB98|Cisco Systems, Inc
70DDEF|Huawei Device Co., Ltd.
70DEE2|Apple, Inc.
70DF2F|Cisco Systems, Inc
70E284|Wistron Infocomm (Zhongshan) Corporation
70E422|Cisco Systems, Inc
70E72C|Apple, Inc.
70E997|HUAWEI TECHNOLOGIES CO.,LTD
70EA1A|Cisco Systems, Inc
70EA5A|Apple, Inc.
70EBA5|Huawei Device Co., Ltd.
70ECE4|Apple, Inc.
70EF00|Apple, Inc.
70F087|Apple, Inc.
70F096|Cisco Systems, Inc
70F11C|Shenzhen Ogemray Technology Co.,Ltd
70F1A1|Liteon Technology Corporation
70F35A|Cisco Systems, Inc
70F8AE|Microsoft Corporation
70F927|Samsung Electronics Co.,Ltd
70F94A|Apple, Inc.
70FD45|HUAWEI TECHNOLOGIES CO.,LTD
70FD46|Samsung Electronics Co.,Ltd
7400E8|HUAWEI TECHNOLOGIES CO.,LTD
74042B|Lenovo Mobile Communication (Wuhan) Company Limited
7404F1|Intel Corporate
7405A5|TP-LINK TECHNOLOGIES CO.,LTD.
740AE1|Huawei Device Co., Ltd.
740C2E|Cisco Systems, Inc
740CEE|Huawei Device Co., Ltd.
740EA4|Apple, Inc.
7410E0|Broadcom Limited
7411A0|Nokia
7411B2|Cisco Systems, Inc
741213|Linksys USA, Inc
7412BB|Fiberhome Telecommunication Technologies Co.,LTD
741348|Blink by Amazon
74136A|Motorola Mobility LLC, a Lenovo Company
7413EA|Intel Corporate
7414D0|Apple, Inc.
741575|Xiaomi Communications Co Ltd
7415F5|Apple, Inc.
74190A|Samsung Electronics Co.,Ltd
741BB2|Apple, Inc.
741E93|Fiberhome Telecommunication Technologies Co.,LTD
741EB1|Samsung Electronics Co.,Ltd
74205F|Shenzhen Zhongruixin Intelligent Technology Co., Ltd.
7422BB|Huawei Device Co., Ltd.
742344|Xiaomi Communications Co Ltd
74238D|zte corporation
742435|Huawei Device Co., Ltd.
742554|NVIDIA Corporation
7426AC|Cisco Systems, Inc
7426FF|zte corporation
742869|Huawei Device Co., Ltd.
742917|Apple, Inc.
742959|Apple, Inc.
742972|Juniper Networks
7429AF|Hon Hai Precision Ind. Co.,Ltd.
742A8A|shenzhen worldelite electronics co., LTD
742B62|FUJITSU LIMITED
742F68|AzureWave Technology Inc.
7430AF|Fiberhome Telecommunication Technologies Co.,LTD
743174|Apple, Inc.
74317E|Ruckus Wireless
7433A6|Shenzhen SuperElectron Technology Co.,Ltd.
7433E9|zte corporation
74342B|HUAWEI TECHNOLOGIES CO.,LTD
743491|Shenzhen Kings IoT Co., Ltd
743675|Juniper Networks
74372F|Tongfang Shenzhen Cloudcomputing Technology Co.,Ltd
743822|Xiaomi Communications Co Ltd
7438B7|CANON INC.
743989|TP-LINK TECHNOLOGIES CO.,LTD.
743AF4|Intel Corporate
743C24|HUAWEI TECHNOLOGIES CO.,LTD
743CDE|Hewlett Packard Enterprise
743E2B|Ruckus Wireless
743F8E|Apple, Inc.
743FC2|Hangzhou Hikvision Digital Technology Co.,Ltd.
7440BB|Hon Hai Precision Ind. Co.,Ltd.
744218|Apple, Inc.
74428B|Apple, Inc.
744401|NETGEAR
74452D|Huawei Device Co., Ltd.
74458A|Samsung Electronics Co.,Ltd
7446A0|Hewlett Packard
744AA4|zte corporation
744CA1|Liteon Technology Corporation
744D28|Routerboard.com
744D6D|HUAWEI TECHNOLOGIES CO.,LTD
744DBD|Espressif Inc.
744F80|shenzhen Amos Electronics Co.,Ltd
7450CD|HUAWEI TECHNOLOGIES CO.,LTD
7451BA|Xiaomi Communications Co Ltd
745427|SHENZHEN FAST TECHNOLOGIES CO.,LTD
74547D|Cisco SPVTG
74563C|GIGA-BYTE TECHNOLOGY CO.,LTD.
745889|Multilaser Industrial S.A.
7458F3|Amazon Technologies Inc.
745909|HUAWEI TECHNOLOGIES CO.,LTD
745AAA|HUAWEI TECHNOLOGIES CO.,LTD
745CFA|Shenzhen Shunrui Gaojie Technology Co., Ltd.
745D22|LCFC(Hefei) Electronics Technology co., ltd
745D68|Fiberhome Telecommunication Technologies Co.,LTD
745EA5|shenzhen trolink Technology Co.,Ltd
745F00|Samsung Semiconductor Inc.
7460FA|HUAWEI TECHNOLOGIES CO.,LTD
7463C2|Huawei Device Co., Ltd.
74650C|Apple, Inc.
74675F|COMPAL INFORMATION(KUNSHAN)CO.,LTD.
7467F7|Extreme Networks, Inc.
746DFA|Samsung Electronics Co.,Ltd
746F19|ICARVISIONS (SHENZHEN) TECHNOLOGY CO., LTD.
746F88|zte corporation
747069|Huawei Device Co., Ltd.
7470FD|Intel Corporate
74718B|Apple, Inc.
7473B4|Apple, Inc.
7473E2|Hillstone Networks Corp.
747446|Google, Inc.
747548|Amazon Technologies Inc.
74761F|Microsoft Corporation
74767D|shenzhen kexint technology co.,ltd
747786|Apple, Inc.
747827|Dell Inc.
7478A6|Fortinet, Inc.
748114|Apple, Inc.
7483A0|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
7483C2|Ubiquiti Inc
74852A|PEGATRON CORPORATION
74860B|Cisco Systems, Inc
74866F|zte corporation
74867A|Dell Inc.
7486E2|Dell Inc.
74872E|HUAWEI TECHNOLOGIES CO.,LTD
74882A|HUAWEI TECHNOLOGIES CO.,LTD
7488BB|Cisco Systems, Inc
748927|Espressif Inc.
748B23|Samsung Electronics Co.,Ltd
748D08|Apple, Inc.
748DAA|HUAWEI TECHNOLOGIES CO.,LTD
748F3C|Apple, Inc.
748FC2|Cisco Systems, Inc
74911A|Ruckus Wireless
7493A4|Zebra Technologies Corp.
749781|zte corporation
749B89|HUAWEI TECHNOLOGIES CO.,LTD
749D8F|HUAWEI TECHNOLOGIES CO.,LTD
749E75|Hewlett Packard Enterprise
749EAF|Apple, Inc.
749EF5|Samsung Electronics Co.,Ltd
74A02F|Cisco Systems, Inc
74A063|HUAWEI TECHNOLOGIES CO.,LTD
74A2E6|Cisco Systems, Inc
74A528|HUAWEI TECHNOLOGIES CO.,LTD
74A57E|Panasonic Ecology Systems
74A5C2|KYOCERA Corporation
74A6CD|Apple, Inc.
74A722|LG Electronics (Mobile Communications)
74A78E|zte corporation
74A7EA|Amazon Technologies Inc.
74A981|HUAWEI TECHNOLOGIES CO.,LTD
74AB93|Blink by Amazon
74AC5F|Qiku Internet Network Scientific (Shenzhen) Co., Ltd.
74ACB9|Ubiquiti Inc
74AD98|Cisco Systems, Inc
74B059|Motorola Mobility LLC, a Lenovo Company
74B57E|zte corporation
74B587|Apple, Inc.
74B725|Huawei Device Co., Ltd.
74B7B3|Shenzhen YOUHUA Technology Co., Ltd
74B8A8|HUAWEI TECHNOLOGIES CO.,LTD
74BADB|Longconn Electornics(shenzhen)Co.,Ltd
74BBD3|Shenzhen xeme Communication Co., Ltd.
74BC6B|Intel Corporate
74BEF3|Motorola Mobility LLC, a Lenovo Company
74BFC0|CANON INC.
74C14F|HUAWEI TECHNOLOGIES CO.,LTD
74C17E|LG Electronics
74C246|Amazon Technologies Inc.
74C330|SHENZHEN FAST TECHNOLOGIES CO.,LTD
74C412|Microsoft Corporation
74C63B|AzureWave Technology Inc.
74C929|Zhejiang Dahua Technology Co., Ltd.
74C9A3|Fiberhome Telecommunication Technologies Co.,LTD
74CA60|Sonos, Inc.
74CC39|Fiberhome Telecommunication Technologies Co.,LTD
74CC40|Apple, Inc.
74CF00|Shenzhen SuperElectron Technology Co.,Ltd.
74D02B|ASUSTek COMPUTER INC.
74D21D|HUAWEI TECHNOLOGIES CO.,LTD
74D423|Amazon Technologies Inc.
74D435|GIGA-BYTE TECHNOLOGY CO.,LTD.
74D4DD|Quanta Computer Inc.
74D5E8|Apple, Inc.
74D637|Amazon Technologies Inc.
74D6E5|Huawei Device Co., Ltd.
74D7CA|Panasonic Automotive Systems Co.,Ltd
74D809|Microsoft Corporation
74D83E|Intel Corporate
74DA78|HP Inc.
74DA88|TP-LINK TECHNOLOGIES CO.,LTD.
74DADA|D-Link International
74DDF0|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
74DE2B|Liteon Technology Corporation
74DFBF|Liteon Technology Corporation
74E19A|Fiberhome Telecommunication Technologies Co.,LTD
74E1B6|Apple, Inc.
74E20C|Amazon Technologies Inc.
74E28C|Microsoft Corporation
74E2E7|Cisco Systems, Inc
74E2F5|Apple, Inc.
74E50B|Intel Corporate
74E543|Liteon Technology Corporation
74E5F9|Intel Corporate
74E6B8|LG Electronics
74E6E2|Dell Inc.
74E798|Juniper Networks
74E987|Apple, Inc.
74E9BF|HUAWEI TECHNOLOGIES CO.,LTD
74EA3A|TP-LINK TECHNOLOGIES CO.,LTD.
74EB80|Samsung Electronics Co.,Ltd
74EC42|Fiberhome Telecommunication Technologies Co.,LTD
74ECB2|Amazon Technologies Inc.
74EE2A|SHENZHEN BILIAN ELECTRONIC CO.，LTD
74F06D|AzureWave Technology Inc.
74F2FA|Xiaomi Communications Co Ltd
74F441|Samsung Electronics Co.,Ltd
74F661|Schneider Electric Fire & Security Oy
74F67A|Samsung Electronics Co.,Ltd
74F90F|HUAWEI TECHNOLOGIES CO.,LTD
74F92C|Ubiquiti Inc
74FA29|Ubiquiti Inc
74FC77|HUAWEI TECHNOLOGIES CO.,LTD
74FECE|TP-Link Systems Inc
74FF4C|Skyworth Digital Technology(Shenzhen) Co.,Ltd
78009E|Samsung Electronics Co.,Ltd
78028B|Apple, Inc.
7802B1|Cisco Systems, Inc
7802B7|ShenZhen Ultra Easy Technology CO.,LTD
7802F8|Xiaomi Communications Co Ltd
78034F|Nokia
7804E3|Huawei Device Co., Ltd.
78055F|Shenzhen WYC Technology Co., Ltd.
7806C9|Huawei Device Co., Ltd.
78078F|HUAWEI TECHNOLOGIES CO.,LTD
78084D|HUAWEI TECHNOLOGIES CO.,LTD
780CB8|Intel Corporate
780CF0|Cisco Systems, Inc
780E3E|HUAWEI TECHNOLOGIES CO.,LTD
780F81|Cisco Meraki
78119D|Cisco Systems, Inc
7811DC|XIAOMI Electronics,CO.,LTD
781699|HUAWEI TECHNOLOGIES CO.,LTD
781735|Nokia Shanghai Bell Co., Ltd.
7817BE|HUAWEI TECHNOLOGIES CO.,LTD
781881|AzureWave Technology Inc.
7818A8|Huawei Device Co., Ltd.
7818EC|Fortinet, Inc.
7819F7|Juniper Networks
781A32|Huawei Device Co., Ltd.
781C3C|Espressif Inc.
781C5A|SHARP Corporation
781D4A|zte corporation
781DBA|HUAWEI TECHNOLOGIES CO.,LTD
781EB8|Shenzhen iComm Semiconductor CO.,LTD
781F7C|Nokia
781FDB|Samsung Electronics Co.,Ltd
78202E|Skychers Creations ShenZhen Limited
782051|TP-Link Systems Inc.
782184|Espressif Inc.
782288|SHENZHEN BILIAN ELECTRONIC CO.，LTD
782327|Samsung Electronics Co.,Ltd
7824AF|ASUSTek COMPUTER INC.
7824BE|Cisco Systems, Inc
782599|Huawei Device Co., Ltd.
7825AD|Samsung Electronics Co.,Ltd
7826A6|zte corporation
7828CA|Sonos, Inc.
782B46|Intel Corporate
782B60|Huawei Device Co., Ltd.
782BCB|Dell Inc.
782DAD|HUAWEI TECHNOLOGIES CO.,LTD
782EEF|Nokia Corporation
78305D|zte corporation
78312B|zte corporation
7831C1|Apple, Inc.
78321B|D-Link International
7833C6|Samsung Electronics Co.,Ltd
783409|HUAWEI TECHNOLOGIES CO.,LTD
783486|Nokia
7834B4|HUAWEI TECHNOLOGIES CO.,LTD
783690|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
783716|Samsung Electronics Co.,Ltd
783A84|Apple, Inc.
783D5B|TELNET Redes Inteligentes S.A.
783EA1|Nokia Shanghai Bell Co., Ltd.
783F4D|Apple, Inc.
7840E4|Samsung Electronics Co.,Ltd
78421C|Espressif Inc.
78444A|Shenzhen Aiwinn information Technology Co., Ltd.
784476|Zioncom Electronics (Shenzhen) Ltd.
7844FD|TP-LINK TECHNOLOGIES CO.,LTD.
784558|Ubiquiti Inc
7845B3|Huawei Device Co., Ltd.
7845C4|Dell Inc.
7845DC|HUAWEI TECHNOLOGIES CO.,LTD
78465F|Fiberhome Telecommunication Technologies Co.,LTD
7846D4|Samsung Electronics Co.,Ltd
78471D|Samsung Electronics Co.,Ltd
784859|Hewlett Packard
7849D7|Samsung Electronics Co.,Ltd
784F43|Apple, Inc.
784F9B|Juniper Networks
78507C|Juniper Networks
78521A|Samsung Electronics Co.,Ltd
785237|zte corporation
785262|Shenzhen Hojy Software Co., Ltd.
78530D|Shenzhen Skyworth Digital Technology CO., Ltd
785333|Beijing Xiaomi Electronics Co.,Ltd
78542E|D-Link International
785536|shenzhen AZW Technology(Group) Co.,Ltd
785773|HUAWEI TECHNOLOGIES CO.,LTD
7857B0|GERTEC BRASIL LTDA
785860|HUAWEI TECHNOLOGIES CO.,LTD
78595E|Samsung Electronics Co.,Ltd
785968|Hon Hai Precision Ind. Co.,Ltd.
785B64|Huawei Device Co., Ltd.
785C5E|HUAWEI TECHNOLOGIES CO.,LTD
785DC8|LG Electronics
785ECC|Apple, Inc.
785F36|Shenzhen Skyworth Digital Technology CO., Ltd
78605B|TP-LINK TECHNOLOGIES CO.,LTD.
786089|Samsung Electronics Co.,Ltd
786256|HUAWEI TECHNOLOGIES CO.,LTD
7864A0|Cisco Systems, Inc
7864C0|Apple, Inc.
786559|Sagemcom Broadband SAS
7866A5|Chipsea Technologies (Shenzhen) Crop.
7866AE|ZTEC Instruments, Inc.
7866F3|shenzhen worldelite electronics co., LTD
7867D7|Apple, Inc.
786A89|HUAWEI TECHNOLOGIES CO.,LTD
786C1C|Apple, Inc.
786C84|Amazon Technologies Inc.
786D94|Palo Alto Networks
78725D|Cisco Systems, Inc
787462|Intel Corporate
78753E|Apple, Inc.
787826|HUAWEI TECHNOLOGIES CO.,LTD
787984|Apple, Inc.
787B8A|Apple, Inc.
787D53|Extreme Networks, Inc.
787E42|zte corporation
787E61|Apple, Inc.
788371|HUAWEI TECHNOLOGIES CO.,LTD
78843C|Sony Corporation
788517|Cisco Systems, Inc
7885F4|Huawei Device Co., Ltd.
78862E|Microsoft Corporation
7886B6|Shenzhen YOUHUA Technology Co., Ltd
78886D|Apple, Inc.
788A20|Ubiquiti Inc
788C77|LEXMARK INTERNATIONAL, INC.
788CB5|TP-Link Systems Inc
788DAF|Sagemcom Broadband SAS
7890A2|zte corporation
78923E|Nokia Corporation
78929C|Intel Corporate
78960D|Apple, Inc.
78966E|Huawei Device Co., Ltd.
789682|zte corporation
7896A3|Extreme Networks, Inc.
7898E8|D-Link International
789987|Xiaomi Communications Co Ltd
789A18|Routerboard.com
789CE7|Shenzhen Aikede Technology Co., Ltd
789ED0|Samsung Electronics Co.,Ltd
789F38|Shenzhen Feasycom Co., Ltd
789F6A|Ruckus Wireless
789F70|Apple, Inc.
789FAA|Huawei Device Co., Ltd.
78A03F|Amazon Technologies Inc.
78A106|TP-LINK TECHNOLOGIES CO.,LTD.
78A1D8|ShenzhenEnjoyTechnologyCo.,Ltd
78A351|SHENZHEN ZHIBOTONG ELECTRONICS CO.,LTD
78A3E4|Apple, Inc.
78A5DD|Shenzhen Smarteye Digital Electronics Co., Ltd
78A7C7|Apple, Inc.
78A873|Samsung Electronics Co.,Ltd
78ABBB|Samsung Electronics Co.,Ltd
78AC44|Dell Inc.
78ACC0|Hewlett Packard
78AF08|Intel Corporate
78AFB8|Shenzhen SDMC Technology CP,.LTD
78B46A|HUAWEI TECHNOLOGIES CO.,LTD
78B554|Huawei Device Co., Ltd.
78B5F2|HUAWEI TECHNOLOGIES CO.,LTD
78B6FE|Samsung Electronics Co.,Ltd
78B8D6|Zebra Technologies Inc.
78BAF9|Cisco Systems, Inc
78BB5C|Nokia Solutions and Networks India Private Limited
78BC1A|Cisco Systems, Inc
78BDBC|Samsung Electronics Co.,Ltd
78BE81|FN-LINK TECHNOLOGY Ltd.
78C05A|TP-Link Systems Inc.
78C11D|Samsung Electronics Co.,Ltd
78C1A7|zte corporation
78C213|Sagemcom Broadband SAS
78C3E9|Samsung Electronics Co.,Ltd
78C4AB|Shenzhen Runsil Technology Co.,Ltd
78C57D|Zyxel Communications Corporation
78C5F8|Huawei Device Co., Ltd.
78C881|Sony Interactive Entertainment Inc.
78C884|Huawei Device Co., Ltd.
78CA04|Nokia Corporation
78CA39|Apple, Inc.
78CF2F|HUAWEI TECHNOLOGIES CO.,LTD
78CFF9|Huawei Device Co., Ltd.
78D162|Apple, Inc.
78D294|NETGEAR
78D6B2|Toshiba
78D6DC|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
78D6F0|SAMSUNG ELECTRO MECHANICS CO., LTD.
78D752|HUAWEI TECHNOLOGIES CO.,LTD
78D75F|Apple, Inc.
78D840|Xiaomi Communications Co Ltd
78DA6E|Cisco Systems, Inc
78DAAF|HUAWEI TECHNOLOGIES CO.,LTD
78DC87|HUAWEI TECHNOLOGIES CO.,LTD
78DD08|Hon Hai Precision Ind. Co.,Ltd.
78DD33|HUAWEI TECHNOLOGIES CO.,LTD
78E0C5|Samsung Electronics Co.,Ltd
78E103|Amazon Technologies Inc.
78E22C|Huawei Device Co., Ltd.
78E36D|Espressif Inc.
78E3B5|Hewlett Packard
78E3DE|Apple, Inc.
78E400|Hon Hai Precision Ind. Co.,Ltd.
78E7D1|Hewlett Packard
78E8B6|zte corporation
78EB14|SHENZHEN FAST TECHNOLOGIES CO.,LTD
78EB46|HUAWEI TECHNOLOGIES CO.,LTD
78EDBC|OnePlus Technology (Shenzhen) Co., Ltd
78EE4C|Espressif Inc.
78F09B|Huawei Device Co., Ltd.
78F1C6|Cisco Systems, Inc
78F238|Samsung Electronics Co.,Ltd
78F29E|PEGATRON CORPORATION
78F557|HUAWEI TECHNOLOGIES CO.,LTD
78F5FD|HUAWEI TECHNOLOGIES CO.,LTD
78F7BE|Samsung Electronics Co.,Ltd
78F882|LG Electronics (Mobile Communications)
78F9B4|Nokia Solutions and Networks GmbH & Co. KG
78FBD8|Apple, Inc.
78FD94|Apple, Inc.
78FDF1|Shenzhen Huadian Communication Co., Ltd
78FE3D|Juniper Networks
78FF57|Intel Corporate
7C004D|HUAWEI TECHNOLOGIES CO.,LTD
7C0191|Apple, Inc.
7C034C|Sagemcom Broadband SAS
7C035E|Xiaomi Communications Co Ltd
7C03AB|Xiaomi Communications Co Ltd
7C03C9|Shenzhen YOUHUA Technology Co., Ltd
7C03D8|Sagemcom Broadband SAS
7C04D0|Apple, Inc.
7C0507|PEGATRON CORPORATION
7C0A3F|Samsung Electronics Co.,Ltd
7C0BC6|Samsung Electronics Co.,Ltd
7C0C5F|Espressif Inc.
7C0CF1|Beijing Xiaomi Mobile Software Co., Ltd
7C0CFA|HUAWEI TECHNOLOGIES CO.,LTD
7C0ECE|Cisco Systems, Inc
7C10C9|ASUSTek COMPUTER INC.
7C11BE|Apple, Inc.
7C11CB|HUAWEI TECHNOLOGIES CO.,LTD
7C162A|Huawei Device Co., Ltd.
7C1689|Sagemcom Broadband SAS
7C1960|HUAWEI TECHNOLOGIES CO.,LTD
7C19E3|Google, Inc.
7C1AC0|HUAWEI TECHNOLOGIES CO.,LTD
7C1B93|Huawei Device Co., Ltd.
7C1C68|Samsung Electronics Co.,Ltd
7C1CF1|HUAWEI TECHNOLOGIES CO.,LTD
7C1DD9|Xiaomi Communications Co Ltd
7C1E52|Microsoft
7C210D|Cisco Systems, Inc
7C210E|Cisco Systems, Inc
7C214A|Intel Corporate
7C21D8|Shenzhen Think Will Communication Technology co., LTD.
7C2302|Samsung Electronics Co.,Ltd
7C2499|Apple, Inc.
7C2586|Juniper Networks
7C25A3|Fortinet, Inc.
7C25DA|FN-LINK TECHNOLOGY LIMITED
7C2664|Sagemcom Broadband SAS
7C273C|Shenzhen Yunlink Technology Co., Ltd
7C296F|Apple, Inc.
7C2A31|Intel Corporate
7C2ACA|Apple, Inc.
7C2ADB|Xiaomi Communications Co Ltd
7C2BE1|Shenzhen Ferex Electrical Co.,Ltd
7C2C67|Espressif Inc.
7C2EBD|Google, Inc.
7C2EDD|Samsung Electronics Co.,Ltd
7C310E|Cisco Systems, Inc
7C33F9|HUAWEI TECHNOLOGIES CO.,LTD
7C3626|HUAWEI TECHNOLOGIES CO.,LTD
7C38AD|Samsung Electronics Co.,Ltd
7C3953|zte corporation
7C3985|HUAWEI TECHNOLOGIES CO.,LTD
7C3B2D|Apple, Inc.
7C3CB6|Shenzhen Homecare Technology Co.,Ltd.
7C3D2B|Huawei Device Co., Ltd.
7C3E74|Huawei Device Co., Ltd.
7C41A2|Nokia
7C45D0|Shenzhen Wewins Wireless Co., ltd
7C4685|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
7C49EB|XIAOMI Electronics,CO.,LTD
7C4B26|Apple, Inc.
7C4D8F|HP Inc.
7C4E09|Shenzhen Skyworth Wireless Technology Co.,Ltd
7C4FAD|Espressif Inc.
7C4FCD|Apple, Inc.
7C5049|Apple, Inc.
7C5079|Intel Corporate
7C573C|Hewlett Packard Enterprise
7C5758|HP Inc.
7C59B1|Apple, Inc.
7C5A1C|Sophos Ltd
7C5CF8|Intel Corporate
7C6097|HUAWEI TECHNOLOGIES CO.,LTD
7C60DB|zte corporation
7C6130|Apple, Inc.
7C6166|Amazon Technologies Inc.
7C62E7|Cisco Systems, Inc
7C6305|Amazon Technologies Inc.
7C6456|Samsung Electronics Co.,Ltd
7C646C|LG Electronics
7C669A|HUAWEI TECHNOLOGIES CO.,LTD
7C66EF|Hon Hai Precision IND.CO.,LTD
7C67A2|Intel Corporate
7C67AB|Roku, Inc
7C68B9|Huawei Device Co., Ltd.
7C692B|HUAWEI TECHNOLOGIES CO.,LTD
7C69F6|Cisco Systems, Inc
7C6CE1|Shenzhen Honesty Electronics Co.,Ltd.
7C6CF0|Shenzhen TINNO Mobile Technology Corp.
7C6D12|Microsoft Corporation
7C6D62|Apple, Inc.
7C6DF8|Apple, Inc.
7C6FF8|ShenZhen ACTO Digital Video Technology Co.,Ltd.
7C70DB|Intel Corporate
7C7398|Espressif Inc.
7C73EB|Huawei Device Co., Ltd.
7C752D|Samsung Electronics Co.,Ltd
7C7630|Shenzhen YOUHUA Technology Co., Ltd
7C7635|Intel Corporate
7C7668|HUAWEI TECHNOLOGIES CO.,LTD
7C7716|Zyxel Communications Corporation
7C787E|Samsung Electronics Co.,Ltd
7C7A91|Intel Corporate
7C7B1C|Motorola Mobility LLC, a Lenovo Company
7C7BBF|Samsung Electronics Co.,Ltd
7C7D21|zte corporation
7C7D3D|HUAWEI TECHNOLOGIES CO.,LTD
7C8274|Shenzhen Hikeen Technology CO.,LTD
7C852F|Huawei Device Co., Ltd.
7C8530|Nokia
7C8767|Cisco Systems, Inc
7C87CE|Espressif Inc.
7C8899|FN-LINK TECHNOLOGY Ltd.
7C8931|Huawei Device Co., Ltd.
7C8956|Samsung Electronics Co.,Ltd
7C89C1|Palo Alto Networks
7C8AE1|COMPAL INFORMATION (KUNSHAN) CO., LTD.
7C8BB5|Samsung Electronics Co.,Ltd
7C8BCA|TP-LINK TECHNOLOGIES CO.,LTD.
7C9122|Samsung Electronics Co.,Ltd
7C942A|HUAWEI TECHNOLOGIES CO.,LTD
7C949F|Shenzhen iComm Semiconductor CO.,LTD
7C94B2|Philips Healthcare PCCI
7C95B1|Extreme Networks, Inc.
7C95F3|Cisco Systems, Inc
7C97E1|Huawei Device Co., Ltd.
7C9824|Sagemcom Broadband SAS
7C9A1D|Apple, Inc.
7C9EBD|Espressif Inc.
7CA05E|Motorola Mobility LLC, a Lenovo Company
7CA177|HUAWEI TECHNOLOGIES CO.,LTD
7CA1AE|Apple, Inc.
7CA23E|HUAWEI TECHNOLOGIES CO.,LTD
7CA449|Xiaomi Communications Co Ltd
7CA4F7|Extreme Networks, Inc.
7CA53E|Motorola Mobility LLC, a Lenovo Company
7CA58F|shenzhen Qikai Electronic Co., Ltd.
7CA62A|Hewlett Packard Enterprise
7CA7B0|SHENZHEN BILIAN ELECTRONIC CO.，LTD
7CA8EC|Hewlett Packard Enterprise
7CAB60|Apple, Inc.
7CAD4F|Cisco Systems, Inc
7CAD74|Cisco Systems, Inc
7CAF77|Nokia
7CB0C2|Intel Corporate
7CB15D|HUAWEI TECHNOLOGIES CO.,LTD
7CB21B|Cisco SPVTG
7CB27D|Intel Corporate
7CB30A|zte corporation
7CB353|Cisco Systems, Inc
7CB566|Intel Corporate
7CB59B|TP-LINK TECHNOLOGIES CO.,LTD.
7CB59F|HUAWEI TECHNOLOGIES CO.,LTD
7CC025|Palo Alto Networks
7CC06F|Apple, Inc.
7CC0AA|Microsoft Corporation
7CC180|Apple, Inc.
7CC225|Samsung Electronics Co.,Ltd
7CC294|Beijing Xiaomi Mobile Software Co., Ltd
7CC2C6|TP-Link Systems Inc
7CC385|HUAWEI TECHNOLOGIES CO.,LTD
7CC3A1|Apple, Inc.
7CC537|Apple, Inc.
7CC709|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
7CC74A|Fiberhome Telecommunication Technologies Co.,LTD
7CC77E|Fiberhome Telecommunication Technologies Co.,LTD
7CC790|Palo Alto Networks
7CC882|HUAWEI TECHNOLOGIES CO.,LTD
7CC8DF|Apple, Inc.
7CC95A|Dell EMC
7CCCB8|Intel Corporate
7CCF0F|LCFC(Hefei) Electronics Technology co., ltd
7CD1AD|Apple, Inc.
7CD1C3|Apple, Inc.
7CD2DA|Apple, Inc.
7CD30A|INVENTEC CORPORATION
7CD3E5|HUAWEI TECHNOLOGIES CO.,LTD
7CD4A8|Sagemcom Broadband SAS
7CD544|Espressif Inc.
7CD566|Amazon Technologies Inc.
7CD62C|Apple, Inc.
7CD661|Xiaomi Communications Co Ltd
7CD95C|Google, Inc.
7CD9A0|HUAWEI TECHNOLOGIES CO.,LTD
7CDC73|HUAWEI TECHNOLOGIES CO.,LTD
7CDD90|Shenzhen Ogemray Technology Co., Ltd.
7CDFA1|Espressif Inc.
7CE2CA|Juniper Networks
7CE53F|HUAWEI TECHNOLOGIES CO.,LTD
7CE87F|Sagemcom Broadband SAS
7CE8B1|Espressif Inc.
7CE9D3|Hon Hai Precision Ind. Co.,Ltd.
7CECB1|Apple, Inc.
7CED8D|Microsoft
7CEDC6|Amazon Technologies Inc.
7CF05F|Apple, Inc.
7CF0E5|OnePlus Technology (Shenzhen) Co., Ltd
7CF17E|TP-Link Systems Inc
7CF31B|LG Electronics (Mobile Communications)
7CF34D|Apple, Inc.
7CF666|Tuya Smart Inc.
7CF854|Samsung Electronics Co.,Ltd
7CF880|Cisco Systems, Inc
7CF90E|Samsung Electronics Co.,Ltd
7CF9A0|Fiberhome Telecommunication Technologies Co.,LTD
7CFADF|Apple, Inc.
7CFC16|Apple, Inc.
7CFCFD|Fiberhome Telecommunication Technologies Co.,LTD
7CFD6B|Xiaomi Communications Co Ltd
7CFE4E|Shenzhen Safe vision Technology Co.,LTD
7CFE62|ShenZhen XinZhongXin Technology Co.， Ltd
80000B|Intel Corporate
80006E|Apple, Inc.
80030D|CANON INC.
800384|Ruckus Wireless
80045F|Apple, Inc.
800518|HUAWEI TECHNOLOGIES CO.,LTD
8006D9|zte corporation
800794|Samsung Electronics Co.,Ltd
800C67|Apple, Inc.
800CF9|Amazon Technologies Inc.
800D3F|Samsung Electronics Co.,Ltd
800EA9|TCL Yuxin Zhixing Technology (Huizhou) Co.,Ltd
801242|Apple, Inc.
8012DF|Shenzhen SuperElectron Technology Co.,Ltd.
801316|Intel Corporate
801382|HUAWEI TECHNOLOGIES CO.,LTD
8013BE|Juniper Networks
801844|Dell Inc.
8018A7|Samsung Electronics Co.,Ltd
801934|Intel Corporate
801970|Samsung Electronics Co.,Ltd
801D39|Apple, Inc.
801DAA|Avaya Inc
8020DA|Sagemcom Broadband SAS
8020FD|Samsung Electronics Co.,Ltd
80248F|Cisco Systems, Inc
802689|D-Link International
80276C|Cisco Systems, Inc
802AA8|Ubiquiti Inc
802BF9|Hon Hai Precision Ind. Co.,Ltd.
802D1A|zte corporation
802DBF|Cisco Systems, Inc
802EC3|HUAWEI TECHNOLOGIES CO.,LTD
802EDE|Huawei Device Co., Ltd.
803049|Liteon Technology Corporation
8030E0|Hewlett Packard Enterprise
8031F0|Samsung Electronics Co.,Ltd
803253|Intel Corporate
8035C1|Xiaomi Communications Co Ltd
803773|NETGEAR
803896|SHARP Corporation
8038BC|HUAWEI TECHNOLOGIES CO.,LTD
8038FB|Intel Corporate
80398C|Samsung Electronics Co.,Ltd
803AF4|Fiberhome Telecommunication Technologies Co.,LTD
803C04|TP-Link Systems Inc.
803C20|HUAWEI TECHNOLOGIES CO.,LTD
803E48|SHENZHEN GONGJIN ELECTRONICS CO.,LT
803FD4|Apple, Inc.
804126|HUAWEI TECHNOLOGIES CO.,LTD
80433F|Juniper Networks
80456B|Espressif Inc.
8045DD|Intel Corporate
804715|Apple, Inc.
804786|Samsung Electronics Co.,Ltd
80489F|Hangzhou Hikvision Digital Technology Co.,Ltd.
804971|Apple, Inc.
804A14|Apple, Inc.
804AF2|Sonos, Inc.
804DCB|Huawei Device Co., Ltd.
804E70|Samsung Electronics Co.,Ltd
804E81|Samsung Electronics Co.,Ltd
80501B|Nokia Corporation
8053E0|Espressif Inc.
80542D|Samsung Electronics Co.,Ltd
80546A|SHENZHEN GONGJIN ELECTRONICS CO.,LT
80549C|Samsung Electronics Co.,Ltd
8054D9|HUAWEI TECHNOLOGIES CO.,LTD
8054E3|Apple, Inc.
8056F2|Hon Hai Precision Ind. Co.,Ltd.
805719|Samsung Electronics Co.,Ltd
8058F8|Motorola Mobility LLC, a Lenovo Company
805A04|LG Electronics (Mobile Communications)
805A70|Fortinet, Inc.
805E0C|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
805E4F|FN-LINK TECHNOLOGY LIMITED
805EC0|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
805FC5|Apple, Inc.
806036|HUAWEI TECHNOLOGIES CO.,LTD
806132|Cisco Systems, Inc
80618F|Shenzhen sangfei consumer communications co.,ltd
80646F|Espressif Inc.
80647C|Tuya Smart Inc.
80656D|Samsung Electronics Co.,Ltd
80657C|Apple, Inc.
806599|Espressif Inc.
806933|HUAWEI TECHNOLOGIES CO.,LTD
806A00|Cisco Systems, Inc
806AB0|Shenzhen TINNO Mobile Technology Corp.
806C1B|Motorola Mobility LLC, a Lenovo Company
806D71|Amazon Technologies Inc.
806F1C|Huawei Device Co., Ltd.
80711F|Juniper Networks
80717A|HUAWEI TECHNOLOGIES CO.,LTD
807264|Huawei Device Co., Ltd.
80739F|KYOCERA CORPORATION
8075BF|Samsung Electronics Co.,Ltd
807B3E|Samsung Electronics Co.,Ltd
807C0A|zte corporation
807C62|Hangzhou Hikvision Digital Technology Co.,Ltd.
807D14|HUAWEI TECHNOLOGIES CO.,LTD
807D3A|Espressif Inc.
807EB4|Shenzhen SuperElectron Technology Co.,Ltd.
807FF8|Juniper Networks
80802C|Fortinet, Inc.
8081A5|TONGQING COMMUNICATION EQUIPMENT (SHENZHEN) Co.,Ltd
808223|Apple, Inc.
8083F6|Apple, Inc.
808489|Intel Corporate
808544|Intelbras
8086D9|Samsung Electronics Co.,Ltd
8086F2|Intel Corporate
808800|zte corporation
808917|TP-LINK TECHNOLOGIES CO.,LTD.
808943|Samsung Electronics Co.,Ltd
808ABD|Samsung Electronics Co.,Ltd
808B5C|Shenzhen Runhuicheng Technology Co., Ltd
808DB7|Hewlett Packard Enterprise
808F1D|TP-LINK TECHNOLOGIES CO.,LTD.
808F97|Xiaomi Communications Co Ltd
808FE8|Intelbras
809133|AzureWave Technology Inc.
80929F|Apple, Inc.
8092A5|Valeo Interior Controls (Shenzhen) Co.,Ltd
80953A|Apple, Inc.
809562|Extreme Networks, Inc.
809621|Lenovo
809698|Apple, Inc.
8096CA|Hon Hai Precision Ind. Co.,Ltd.
809733|Shenzhen Elebao Technology Co., Ltd
8099E7|Sony Corporation
809B20|Intel Corporate
809D65|FN-LINK TECHNOLOGY Ltd.
809FAB|Fiberhome Telecommunication Technologies Co.,LTD
809FE4|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
809FF5|Samsung Electronics Co.,Ltd
80A2FC|AzureWave Technology Inc.
80A589|AzureWave Technology Inc.
80A63C|Amazon Technologies Inc.
80A796|Neuralink Corp.
80A997|Apple, Inc.
80AB4D|Nokia Solutions and Networks GmbH & Co. KG
80ACAC|Juniper Networks
80AD16|Xiaomi Communications Co Ltd
80AE54|TP-LINK TECHNOLOGIES CO.,LTD.
80AF19|Apple, Inc.
80AFCA|Shenzhen Cudy Technology Co., Ltd.
80B03D|Apple, Inc.
80B07B|zte corporation
80B54E|Espressif Inc.
80B575|HUAWEI TECHNOLOGIES CO.,LTD
80B655|Intel Corporate
80B686|HUAWEI TECHNOLOGIES CO.,LTD
80B946|Nokia
80B989|Apple, Inc.
80BC37|Ruckus Wireless
80BE05|Apple, Inc.
80BEAF|Hangzhou Hikvision Digital Technology Co.,Ltd.
80C01E|Intel Corporate
80C16E|Hewlett Packard
80C548|Shenzhen Zowee Technology Co.,Ltd
80C5E6|Microsoft Corporation
80C5F2|AzureWave Technology Inc.
80C755|Panasonic Appliances Company
80C7C5|Fiberhome Telecommunication Technologies Co.,LTD
80CA4B|SHENZHEN GONGJIN ELECTRONICS CO.,LTD
80CA52|Wistron InfoComm(Chongqing)Co.,Ltd.
80CC12|Huawei Device Co., Ltd.
80CC9C|NETGEAR
80CE62|Hewlett Packard
80CEB9|Samsung Electronics Co.,Ltd
80CF41|Lenovo Mobile Communication Technology Ltd.
80CFA2|Huawei Device Co., Ltd.
80D09B|HUAWEI TECHNOLOGIES CO.,LTD
80D1CE|Apple, Inc.
80D21D|AzureWave Technology Inc.
80D4A5|HUAWEI TECHNOLOGIES CO.,LTD
80D605|Apple, Inc.
80DACE|Huawei Device Co., Ltd.
80DB17|Juniper Networks
80E01D|Cisco Systems, Inc
80E1BF|HUAWEI TECHNOLOGIES CO.,LTD
80E4BA|Intel Corporate
80E63C|Xiaomi Communications Co Ltd
80E650|Apple, Inc.
80E82C|Hewlett Packard
80E86F|Cisco Systems, Inc
80E8A4|zte corporation
80EA07|TP-LINK TECHNOLOGIES CO.,LTD.
80EA0B|Zyxel Communications Corporation
80EA96|Apple, Inc.
80EB77|Wistron Corporation
80ED2C|Apple, Inc.
80EE25|Shenzhen Skyworth Digital Technology CO., Ltd
80F0CF|Ruckus Wireless
80F1A4|HUAWEI TECHNOLOGIES CO.,LTD
80F1B2|Espressif Inc.
80F3DA|Espressif Inc.
80F416|Chipsea Technologies (Shenzhen) Corp.
80F5AE|Hangzhou Hikvision Digital Technology Co.,Ltd.
80F7A6|Shenzhen C-Data Technology Co., Ltd.
80FB06|HUAWEI TECHNOLOGIES CO.,LTD
84002D|PEGATRON CORPORATION
8400D2|Sony Corporation
840328|Juniper Networks
840511|Apple, Inc.
8406FA|Fiberhome Telecommunication Technologies Co.,LTD
84083A|Intel Corporate
840B2D|SAMSUNG ELECTRO MECHANICS CO., LTD.
840C6D|Cisco Systems, Inc
840D8E|Espressif Inc.
840F4C|Apple, Inc.
84100D|Motorola Mobility LLC, a Lenovo Company
84119E|Samsung Electronics Co.,Ltd
84139F|zte corporation
84144D|Intel Corporate
8415D3|HUAWEI TECHNOLOGIES CO.,LTD
84160C|Broadcom Limited
841623|zte corporation
8416F9|TP-LINK TECHNOLOGIES CO.,LTD.
84183A|Ruckus Wireless
841888|Juniper Networks
841985|Samsung Electronics Co.,Ltd
841B38|Shenzhen Excelsecu Data Technology Co.,Ltd
841B5E|NETGEAR
841B77|Intel Corporate
841C70|zte corporation
841EA3|Sagemcom Broadband SAS
841FE8|Espressif Inc.
842096|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
842141|Shenzhen Ginwave Technologies Ltd.
8421F1|HUAWEI TECHNOLOGIES CO.,LTD
84225E|SHENZHEN TECHNEWCHIP TECHNOLOGY CO.,LTD.
842289|Samsung Electronics Co.,Ltd
842388|Ruckus Wireless
84248D|Zebra Technologies Inc
842519|Samsung Electronics
8425DB|Samsung Electronics Co.,Ltd
84262B|Nokia
842789|Apple, Inc.
842859|Amazon Technologies Inc.
842999|Apple, Inc.
842AFD|HP Inc.
842B2B|Dell Inc.
842BBC|Modelleisenbahn GmbH
842E27|Samsung Electronics Co.,Ltd
842F57|Apple, Inc.
843095|Hon Hai Precision IND.CO.,LTD
8430CE|Shenzhen Jaguar Microsystems Co., Ltd
8432EA|ANHUI WANZTEN P&T CO., LTD
8433F2|Shenzhen Stellamore Technology Co.,Ltd
843497|Hewlett Packard
8437D5|Samsung Electronics Co.,Ltd
843835|Apple, Inc.
843838|SAMSUNG ELECTRO-MECHANICS(THAILAND)
84398F|Fortinet, Inc.
8439FC|Nokia
843A4B|Intel Corporate
843A5B|Inventec(Chongqing) Corporation
843C99|zte corporation
843CFC|HUAWEI TECHNOLOGIES CO.,LTD
843DC6|Cisco Systems, Inc
843E03|Sagemcom Broadband SAS
843E79|Shenzhen Belon Technology CO.,LTD
843E92|HUAWEI TECHNOLOGIES CO.,LTD
844167|Apple, Inc.
844693|Beijing Xiaomi Mobile Software Co., Ltd
8446FE|HUAWEI TECHNOLOGIES CO.,LTD
844709|Shenzhen IP3 Century Intelligent Technology CO.,Ltd
844765|HUAWEI TECHNOLOGIES CO.,LTD
844880|Amazon Technologies Inc.
844BF5|Hon Hai Precision Ind. Co.,Ltd.
844DBE|Fiberhome Telecommunication Technologies Co.,LTD
845075|Huawei Device Co., Ltd.
845181|Samsung Electronics Co.,Ltd
845234|Juniper Networks
8454DF|Huawei Device Co., Ltd.
8455A5|Samsung Electronics Co.,Ltd
845733|Microsoft Corporation
8457EB|Motorola Mobility LLC, a Lenovo Company
845A3E|Cisco Systems, Inc
845B12|HUAWEI TECHNOLOGIES CO.,LTD
845C31|Dell Inc.
845CF3|Intel Corporate
845DD7|Shenzhen Netcom Electronics Co.,Ltd
845F04|Samsung Electronics Co.,Ltd
846223|Shenzhen Coship Electronics Co., Ltd.
8463D6|Microsoft Corporation
8464DD|HUAWEI TECHNOLOGIES CO.,LTD
84683E|Intel Corporate
846878|Apple, Inc.
846991|Nokia
846993|HP Inc.
846B48|ShenZhen EepuLink Co., Ltd.
846EBC|Nokia Solutions and Networks India Private Limited
84716A|Huawei Device Co., Ltd.
84742A|zte corporation
847460|zte corporation
847637|HUAWEI TECHNOLOGIES CO.,LTD
847848|Ubiquiti Inc
84788B|Apple, Inc.
8478AC|Cisco Systems, Inc
847B57|Intel Corporate
847BEB|Dell Inc.
847CEE|Cisco Systems, Inc
847D7E|Cisco Systems, Inc
84802D|Cisco Systems, Inc
848102|Fiberhome Telecommunication Technologies Co.,LTD
848371|Avaya Inc
848506|Apple, Inc.
84850A|Hella Sonnen- und Wetterschutztechnik GmbH
8487FF|Shenzhen Skyworth Digital Technology CO., Ltd
8488E1|Apple, Inc.
8489AD|Apple, Inc.
848A8D|Cisco Systems, Inc
848C8D|Apple, Inc.
848DC7|Cisco SPVTG
848E0C|Apple, Inc.
848EDF|Sony Corporation
848F69|Dell Inc.
849265|Intel Corporate
8492E5|HUAWEI TECHNOLOGIES CO.,LTD
8493A0|Huawei Device Co., Ltd.
8493B2|zte corporation
849437|Apple, Inc.
849459|Hangzhou Hikvision Digital Technology Co.,Ltd.
849866|Samsung Electronics Co.,Ltd
849A40|Hangzhou Hikvision Digital Technology Co.,Ltd.
849D4B|Shenzhen Boomtech Industrial Corporation
849FB5|HUAWEI TECHNOLOGIES CO.,LTD
84A06E|Sagemcom Broadband SAS
84A134|Apple, Inc.
84A1D1|Sagemcom Broadband SAS
84A423|Sagemcom Broadband SAS
84A466|Samsung Electronics Co.,Ltd
84A6C8|Intel Corporate
84A824|Google, Inc.
84A8E4|HUAWEI TECHNOLOGIES CO.,LTD
84A938|LCFC(Hefei) Electronics Technology co., ltd
84A93E|Hewlett Packard
84A9C4|HUAWEI TECHNOLOGIES CO.,LTD
84AB1A|Apple, Inc.
84AC16|Apple, Inc.
84AD58|HUAWEI TECHNOLOGIES CO.,LTD
84AD8D|Apple, Inc.
84AEDE|Xiaomi Communications Co Ltd
84B153|Apple, Inc.
84B1E2|Microsoft Corporation
84B1E4|Apple, Inc.
84B261|Cisco Systems, Inc
84B4D2|Shenzhen iComm Semiconductor CO.,LTD
84B517|Cisco Systems, Inc
84B541|Samsung Electronics Co.,Ltd
84B59C|Juniper Networks
84B802|Cisco Systems, Inc
84B890|TP-LINK TECHNOLOGIES CO.,LTD.
84B8B8|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
84BA3B|CANON INC.
84BA59|Wistron InfoComm(Chongqing)Co.,Ltd.
84BE52|HUAWEI TECHNOLOGIES CO.,LTD
84C0EF|Samsung Electronics Co.,Ltd
84C1C1|Juniper Networks
84C5A6|Intel Corporate
84C7BB|Espressif Inc.
84C7EA|Sony Corporation
84C9B2|D-Link International
84C9C6|SHENZHEN GONGJIN ELECTRONICS CO.,LT
84CC63|Huawei Device Co., Ltd.
84CCA8|Espressif Inc.
84CD62|ShenZhen IDWELL Technology CO.,Ltd
84D1C1|Intel Corporate
84D303|Chipsea Technologies (Shenzhen) Crop.
84D328|Apple, Inc.
84D3D5|Huawei Device Co., Ltd.
84D412|Palo Alto Networks
84D47E|Hewlett Packard Enterprise
84D6D0|Amazon Technologies Inc.
84D7DE|HUAWEI TECHNOLOGIES CO.,LTD
84D81B|TP-LINK TECHNOLOGIES CO.,LTD.
84DBA4|Huawei Device Co., Ltd.
84DBAC|HUAWEI TECHNOLOGIES CO.,LTD
84DBFC|Nokia
84DD84|Cisco Systems, Inc
84E342|Tuya Smart Inc.
84E4D9|Shenzhen NEED technology Ltd.
84E59E|Shenzhen YOUHUA Technology Co., Ltd
84E657|Sony Interactive Entertainment Inc.
84E986|Huawei Device Co., Ltd.
84EA97|Shenzhen iComm Semiconductor CO.,LTD
84EAED|Roku, Inc
84EBEF|Cisco Systems, Inc
84EE7F|HUAWEI TECHNOLOGIES CO.,LTD
84EEE4|Samsung Electronics Co.,Ltd
84EF18|Intel Corporate
84F147|Cisco Systems, Inc
84F2C1|zte corporation
84F3EB|Espressif Inc.
84F5EB|zte corporation
84F703|Espressif Inc.
84FC14|SHENZHEN BILIAN ELECTRONIC CO.，LTD
84FCAC|Apple, Inc.
84FCE6|Espressif Inc.
84FCFE|Apple, Inc.
84FDD1|Intel Corporate
84FE40|HUAWEI TECHNOLOGIES CO.,LTD
84FFC2|Cisco Systems, Inc
88074B|LG Electronics (Mobile Communications)
880AA3|Juniper Networks
880E85|Shenzhen Boomtech Industrial Corporation
880FA2|Sagemcom Broadband SAS
881032|Apple, Inc.
881036|Panodic(ShenZhen) Electronics Limted
88108F|HUAWEI TECHNOLOGIES CO.,LTD
881196|HUAWEI TECHNOLOGIES CO.,LTD
88124E|Qualcomm Inc.
88127D|Shenzhen Melon Electronics Co.,Ltd
8812AC|HUNAN FN-LINK TECHNOLOGY LIMITED
8813BF|Espressif Inc.
881544|Cisco Meraki
881566|Huawei Device Co., Ltd.
8815C5|Huawei Device Co., Ltd.
8817A8|Apple, Inc.
8818F1|Nokia
881908|Apple, Inc.
881B99|SHENZHEN XIN FEI JIA ELECTRONIC CO. LTD.
881DFC|Cisco Systems, Inc
881E5A|Apple, Inc.
881FA1|Apple, Inc.
88200D|Apple, Inc.
882067|Fiberhome Telecommunication Technologies Co.,LTD
88225B|Hewlett Packard Enterprise
8822B2|Chipsea Technologies (Shenzhen) Corp.
88238C|Fiberhome Telecommunication Technologies Co.,LTD
882510|Hewlett Packard Enterprise
882593|TP-LINK TECHNOLOGIES CO.,LTD.
8828B3|HUAWEI TECHNOLOGIES CO.,LTD
8828FB|Juniper Networks
88299C|Samsung Electronics Co.,Ltd
8829BF|Amazon Technologies Inc.
882C31|Apple, Inc.
882F92|Xiaomi Communications Co Ltd
883037|Juniper Networks
88329B|SAMSUNG ELECTRO-MECHANICS(THAILAND)
88365F|LG Electronics (Mobile Communications)
8836CF|Huawei Device Co., Ltd.
883A30|Hewlett Packard Enterprise
883D24|Google, Inc.
883F27|Huawei Device Co., Ltd.
883FD3|HUAWEI TECHNOLOGIES CO.,LTD
884033|HUAWEI TECHNOLOGIES CO.,LTD
88403B|HUAWEI TECHNOLOGIES CO.,LTD
884157|Shenzhen Atsmart Technology Co.,Ltd.
8841C1|ORBISAT DA AMAZONIA IND E AEROL SA
8843E1|Cisco Systems, Inc
884477|HUAWEI TECHNOLOGIES CO.,LTD
8844F6|Nokia Corporation
884604|Xiaomi Communications Co Ltd
88492D|SHENZHEN BILIAN ELECTRONIC CO.，LTD
884D7C|Apple, Inc.
884F59|Cisco Systems, Inc
8850F6|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
8851F2|Apple, Inc.
8851FB|Hewlett Packard
8852EB|Xiaomi Communications Co Ltd
88532E|Intel Corporate
885395|Apple, Inc.
8853D4|HUAWEI TECHNOLOGIES CO.,LTD
88541F|Google, Inc.
8856A6|Espressif Inc.
885721|Espressif Inc.
885A92|Cisco Systems, Inc
885BDD|Extreme Networks, Inc.
885DFB|zte corporation
885E54|Samsung Electronics Co.,Ltd
8863C5|HUAWEI TECHNOLOGIES CO.,LTD
8863DF|Apple, Inc.
886440|Apple, Inc.
88659F|Fiberhome Telecommunication Technologies Co.,LTD
886639|HUAWEI TECHNOLOGIES CO.,LTD
88665A|Apple, Inc.
8866A5|Apple, Inc.
8867DC|HUAWEI TECHNOLOGIES CO.,LTD
88685C|Shenzhen ChuangDao & Perpetual Eternal Technology Co.,Ltd
88693D|HUAWEI TECHNOLOGIES CO.,LTD
886B6E|Apple, Inc.
886BDB|Apple, Inc.
886C60|Xiaomi Communications Co Ltd
886D2D|Huawei Device Co., Ltd.
886EEB|HUAWEI TECHNOLOGIES CO.,LTD
886FD4|Dell Inc.
887015|Apple, Inc.
88708C|Lenovo Mobile Communication Technology Ltd.
8871E5|Amazon Technologies Inc.
887384|Toshiba
887477|HUAWEI TECHNOLOGIES CO.,LTD
887556|Cisco Systems, Inc
887598|Samsung Electronics Co.,Ltd
8876B9|D-Link Corporation
887873|Intel Corporate
88797E|Motorola Mobility LLC, a Lenovo Company
887ABC|Cisco Systems, Inc
887B2C|zte corporation
887E25|Extreme Networks, Inc.
887E9B|Apple, Inc.
887FD5|zte corporation
8881B9|Huawei Device Co., Ltd.
888279|Shenzhen RB-LINK Intelligent Technology Co.Ltd
888322|Samsung Electronics Co.,Ltd
88835D|FN-LINK TECHNOLOGY LIMITED
888603|HUAWEI TECHNOLOGIES CO.,LTD
888717|CANON INC.
88892F|HUAWEI TECHNOLOGIES CO.,LTD
888E68|Huawei Device Co., Ltd.
888F10|Shenzhen Max Infinite Technology Co.,Ltd.
888FA4|Huawei Device Co., Ltd.
889009|Juniper Networks
88908D|Cisco Systems, Inc
88947E|Fiberhome Telecommunication Technologies Co.,LTD
889986|TP-LINK TECHNOLOGIES CO.,LTD.
889B39|Samsung Electronics Co.,Ltd
889CAD|Cisco Systems, Inc
889E96|zte corporation
889F6F|Samsung Electronics Co.,Ltd
889FFA|Hon Hai Precision Ind. Co.,Ltd.
88A0BE|HUAWEI TECHNOLOGIES CO.,LTD
88A25E|Juniper Networks
88A29E|Raspberry Pi (Trading) Ltd
88A2D7|HUAWEI TECHNOLOGIES CO.,LTD
88A303|Samsung Electronics Co.,Ltd
88A479|Apple, Inc.
88A4C2|LCFC(Hefei) Electronics Technology co., ltd
88A6C6|Sagemcom Broadband SAS
88A9B7|Apple, Inc.
88AC9E|Shenzhen YOUHUA Technology Co., Ltd
88ACC0|Zyxel Communications Corporation
88AD43|PEGATRON CORPORATION
88ADD2|Samsung Electronics Co.,Ltd
88AE07|Apple, Inc.
88AE1D|COMPAL INFORMATION (KUNSHAN) CO., LTD.
88B111|Intel Corporate
88B291|Apple, Inc.
88B2AB|Fiberhome Telecommunication Technologies Co.,LTD
88B362|Nokia Shanghai Bell Co., Ltd.
88B4A6|Motorola Mobility LLC, a Lenovo Company
88B4BE|HUAWEI TECHNOLOGIES CO.,LTD
88B5FF|Shenzhen iComm Semiconductor CO.,LTD
88B7EB|Apple, Inc.
88B945|Apple, Inc.
88B951|Xiaomi Communications Co Ltd
88BCAC|Zebra Technologies Inc.
88BCC1|HUAWEI TECHNOLOGIES CO.,LTD
88BD45|Samsung Electronics Co.,Ltd
88BF35|Verifone, Inc.
88BFE4|HUAWEI TECHNOLOGIES CO.,LTD
88C08B|Apple, Inc.
88C174|zte corporation
88C227|HUAWEI TECHNOLOGIES CO.,LTD
88C344|Google, Inc.
88C397|Beijing Xiaomi Mobile Software Co., Ltd
88C663|Apple, Inc.
88C6E8|HUAWEI TECHNOLOGIES CO.,LTD
88C78F|zte corporation
88C9D0|LG Electronics (Mobile Communications)
88C9E8|Sony Corporation
88CB87|Apple, Inc.
88CC45|Skyworth Digital Technology(Shenzhen) Co.,Ltd
88CE3F|HUAWEI TECHNOLOGIES CO.,LTD
88CEFA|HUAWEI TECHNOLOGIES CO.,LTD
88CF98|HUAWEI TECHNOLOGIES CO.,LTD
88D274|zte corporation
88D546|Apple, Inc.
88D7F6|ASUSTek COMPUTER INC.
88D82E|Intel Corporate
88D98F|Juniper Networks
88DA04|HUAWEI TECHNOLOGIES CO.,LTD
88DDB8|Huawei Device Co., Ltd.
88DE39|Hangzhou Hikvision Digital Technology Co.,Ltd.
88DEA9|Roku, Inc.
88E056|HUAWEI TECHNOLOGIES CO.,LTD
88E0A0|Shenzhen VisionSTOR Technologies Co., Ltd
88E0F3|Juniper Networks
88E3AB|HUAWEI TECHNOLOGIES CO.,LTD
88E628|Shenzhen Kezhonglong Optoelectronic Technology Co.,Ltd
88E64B|Juniper Networks
88E87F|Apple, Inc.
88E9A4|Hewlett Packard Enterprise
88E9FE|Apple, Inc.
88F031|Cisco Systems, Inc
88F077|Cisco Systems, Inc
88F155|Espressif Inc.
88F2CE|Apple, Inc.
88F3D5|Zyxel Communications Corporation
88F488|cellon communications technology(shenzhen)Co.,Ltd.
88F4DA|Intel Corporate
88F56E|HUAWEI TECHNOLOGIES CO.,LTD
88F6DC|Huawei Device Co., Ltd.
88F872|HUAWEI TECHNOLOGIES CO.,LTD
88FC5D|Cisco Systems, Inc
8C006D|Apple, Inc.
8C04BA|Dell Inc.
8C0528|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
8C0572|Huawei Device Co., Ltd.
8C08AA|Apple, Inc.
8C0C87|Nokia
8C0C90|Ruckus Wireless
8C0D76|HUAWEI TECHNOLOGIES CO.,LTD
8C0F6F|PEGATRON CORPORATION
8C0F7E|TCL King Electrical Appliances(Huizhou)Co.,Ltd
8C0FC9|Huawei Device Co., Ltd.
8C10D4|Sagemcom Broadband SAS
8C142A|Cisco Systems, Inc
8C14B4|zte corporation
8C15C7|HUAWEI TECHNOLOGIES CO.,LTD
8C1645|LCFC(Hefei) Electronics Technology co., ltd
8C1759|Intel Corporate
8C17B6|Huawei Device Co., Ltd.
8C1801|zte corporation
8C18D9|Shenzhen RF Technology Co., Ltd
8C1952|Amazon Technologies Inc.
8C1ABF|Samsung Electronics Co.,Ltd
8C1AF3|Shenzhen Gooxi Information Security CO.,Ltd.
8C1D96|Intel Corporate
8C1E80|Cisco Systems, Inc
8C210A|TP-LINK TECHNOLOGIES CO.,LTD.
8C2114|Huawei Device Co., Ltd.
8C22D2|Hangzhou Hikvision Digital Technology Co.,Ltd.
8C2505|HUAWEI TECHNOLOGIES CO.,LTD
8C26AA|Apple, Inc.
8C2937|Apple, Inc.
8C2A85|Amazon Technologies Inc.
8C2DAA|Apple, Inc.
8C2E72|Samsung Electronics Co.,Ltd
8C3066|Ubiquiti Inc
8C3396|Apple, Inc.
8C3446|Huawei Device Co., Ltd.
8C34FD|HUAWEI TECHNOLOGIES CO.,LTD
8C367A|Palo Alto Networks
8C3AE3|LG Electronics (Mobile Communications)
8C3BAD|NETGEAR
8C3D16|Shenzhen Four Seas Global Link Network Technology Co.,Ltd
8C426D|HUAWEI TECHNOLOGIES CO.,LTD
8C44A5|Cisco Systems, Inc
8C44BB|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
8C4598|Espressif Inc.
8C47BE|Dell Inc.
8C4962|Roku, Inc
8C497A|Extreme Networks, Inc.
8C4B14|Espressif Inc.
8C4E46|Motorola Mobility LLC, a Lenovo Company
8C4EBB|Amazon Technologies Inc.
8C4F00|Espressif Inc.
8C5105|Shenzhen ireadygo Information Technology CO.,LTD.
8C5219|SHARP Corporation
8C53C3|Beijing Xiaomi Mobile Software Co., Ltd
8C554A|Intel Corporate
8C5646|LG Electronics
8C5877|Apple, Inc.
8C5973|Zyxel Communications Corporation
8C5AC1|Huawei Device Co., Ltd.
8C5AF8|Beijing Xiaomi Electronics Co., Ltd.
8C5EBD|Huawei Device Co., Ltd.
8C5FAD|Fiberhome Telecommunication Technologies Co.,LTD
8C604F|Cisco Systems, Inc
8C6422|Sony Corporation
8C64A2|OnePlus Technology (Shenzhen) Co., Ltd
8C683A|HUAWEI TECHNOLOGIES CO.,LTD
8C68C8|zte corporation
8C6A3B|Samsung Electronics Co.,Ltd
8C6BDB|Huawei Device Co., Ltd.
8C6D50|SHENZHEN MTC CO LTD
8C6D77|HUAWEI TECHNOLOGIES CO.,LTD
8C705A|Intel Corporate
8C71F8|Samsung Electronics Co.,Ltd
8C736E|FUJITSU LIMITED
8C73A0|Fiberhome Telecommunication Technologies Co.,LTD
8C7712|Samsung Electronics Co.,Ltd
8C78D7|SHENZHEN FAST TECHNOLOGIES CO.,LTD
8C7909|Hewlett Packard Enterprise
8C7967|zte corporation
8C79F5|Samsung Electronics Co.,Ltd
8C7A00|Nokia
8C7A15|Ruckus Wireless
8C7A3D|Xiaomi Communications Co Ltd
8C7AAA|Apple, Inc.
8C7B9D|Apple, Inc.
8C7C92|Apple, Inc.
8C7CB5|Hon Hai Precision Ind. Co.,Ltd.
8C8283|Apple, Inc.
8C839D|SHENZHEN XINYUPENG ELECTRONIC TECHNOLOGY CO., LTD
8C83DF|Nokia
8C83E1|Samsung Electronics Co.,Ltd
8C83E8|HUAWEI TECHNOLOGIES CO.,LTD
8C8442|Cisco Systems, Inc
8C8474|Broadcom Limited
8C8590|Apple, Inc.
8C85C1|Hewlett Packard Enterprise
8C861E|Apple, Inc.
8C862A|HUAWEI TECHNOLOGIES CO.,LTD
8C86DD|TP-Link Systems Inc.
8C87D0|Shenzhen Uascent Technology Co.,Ltd
8C8881|Cisco Meraki
8C89A5|Micro-Star INT'L CO., LTD
8C8ACD|HUAWEI TECHNOLOGIES CO.,LTD
8C8C29|Espressif Inc.
8C8CAA|LCFC(Hefei) Electronics Technology co., ltd
8C8D28|Intel Corporate
8C8E0D|zte corporation
8C8EF2|Apple, Inc.
8C8FE9|Apple, Inc.
8C902D|TP-Link Systems Inc.
8C90D3|Nokia
8C91A4|Apple, Inc.
8C941F|Cisco Systems, Inc
8C9461|Cisco Systems, Inc
8C94DF|Espressif Inc.
8C9806|SHENZHEN SEI ROBOTICS CO.,LTD
8C986B|Apple, Inc.
8C9885|Samsung Electronics Co.,Ltd
8C9A8F|Sagemcom Broadband SAS
8CA2F5|Huawei Device Co., Ltd.
8CA3EC|Samsung Electronics Co.,Ltd
8CA401|Shenzhen New Chip Intelligence Co.,LTD
8CA5CF|HUAWEI TECHNOLOGIES CO.,LTD
8CA6DF|TP-LINK TECHNOLOGIES CO.,LTD.
8CA96D|HUAWEI TECHNOLOGIES CO.,LTD
8CA982|Intel Corporate
8CAAB5|Espressif Inc.
8CAACE|Xiaomi Communications Co Ltd
8CB0E9|Samsung Electronics.,LTD
8CB50E|Cisco Systems, Inc
8CB64F|Cisco Systems, Inc
8CB7F7|Shenzhen UniStrong Science & Technology Co., Ltd
8CB84A|SAMSUNG ELECTRO-MECHANICS(THAILAND)
8CB87E|Intel Corporate
8CBD37|Shenzhen Phaten Tech. LTD
8CBEBE|Xiaomi Communications Co Ltd
8CBFA6|Samsung Electronics Co.,Ltd
8CBFEA|Espressif Inc.
8CC121|Panasonic Corporation AVC Networks Company
8CC246|Apple, Inc.
8CC58C|ShenZhen Elsky Technology Co.,LTD
8CC5B4|Sagemcom Broadband SAS
8CC5D0|Samsung Electronics Co.,Ltd
8CC5E1|ShenZhen Konka Telecommunication Technology Co.,Ltd
8CC681|Intel Corporate
8CC8CD|Samsung Electronics Co.,Ltd
8CC9E9|Huawei Device Co., Ltd.
8CCBDF|FOXCONN INTERCONNECT TECHNOLOGY
8CCE4E|Espressif Inc.
8CCEFD|Shenzhen zhouhai technology co.,LTD
8CCF09|Dell EMC
8CD0B2|Beijing Xiaomi Mobile Software Co., Ltd
8CD9D6|Xiaomi Communications Co Ltd
8CDC02|zte corporation
8CDCD4|Hewlett Packard
8CDEE6|Samsung Electronics Co.,Ltd
8CDEF9|Beijing Xiaomi Mobile Software Co., Ltd
8CE081|zte corporation
8CE117|zte corporation
8CE4DB|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
8CE5C0|Samsung Electronics Co.,Ltd
8CE5EF|HUAWEI TECHNOLOGIES CO.,LTD
8CE748|Hangzhou Hikvision Digital Technology Co.,Ltd.
8CE9B4|Zhejiang Dahua Technology Co., Ltd.
8CE9EE|Intel Corporate
8CE9FF|Dell Inc.
8CEA12|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
8CEA48|Samsung Electronics Co.,Ltd
8CEBC6|HUAWEI TECHNOLOGIES CO.,LTD
8CEC4B|Dell Inc.
8CEC7B|Apple, Inc.
8CEDE1|Ubiquiti Inc
8CEEFD|zte corporation
8CF112|Motorola Mobility LLC, a Lenovo Company
8CF5A3|SAMSUNG ELECTRO-MECHANICS(THAILAND)
8CF67D|NETGEAR
8CF773|Nokia
8CF8C5|Intel Corporate
8CF957|RuiXingHengFang Network (Shenzhen) Co.,Ltd
8CFABA|Apple, Inc.
8CFADD|HUAWEI TECHNOLOGIES CO.,LTD
8CFCA0|Shenzhen Smart Device Technology Co., LTD.
8CFD18|HUAWEI TECHNOLOGIES CO.,LTD
8CFD49|Espressif Inc.
8CFDDE|Sagemcom Broadband SAS
8CFDF0|Qualcomm Inc.
8CFE57|Apple, Inc.
8CFE74|Ruckus Wireless
90004E|Hon Hai Precision Ind. Co.,Ltd.
9000DB|Samsung Electronics Co.,Ltd
900117|HUAWEI TECHNOLOGIES CO.,LTD
90013B|Sagemcom Broadband SAS
90027A|Shenzhen Sworix Techonlogy Co., Ltd
90028A|Shenzhen Shidean Legrand Electronic Products Co.,Ltd
9002A9|Zhejiang Dahua Technology Co., Ltd.
900325|HUAWEI TECHNOLOGIES CO.,LTD
900628|Samsung Electronics Co.,Ltd
9006DB|HUAWEI TECHNOLOGIES CO.,LTD
9009D0|Synology Incorporated
9009DF|Intel Corporate
900A48|Samsung Electronics Co.,Ltd
900CC8|Google, Inc.
900E9E|Shenzhen SuperElectron Technology Co.,Ltd.
900EB3|Shenzhen Amediatech Technology Co., Ltd.
901057|Intel Corporate
901195|Amazon Technologies Inc.
901234|Shenzhen YOUHUA Technology Co., Ltd
9014AF|Cambium Networks Limited
901506|Espressif Inc.
9016BA|HUAWEI TECHNOLOGIES CO.,LTD
90173F|HUAWEI TECHNOLOGIES CO.,LTD
9017AC|HUAWEI TECHNOLOGIES CO.,LTD
9017C8|HUAWEI TECHNOLOGIES CO.,LTD
90187C|SAMSUNG ELECTRO MECHANICS CO., LTD.
901B0E|Fujitsu Technology Solutions GmbH
901D27|zte corporation
901F94|TP-Link Systems Inc.
9020C2|Hewlett Packard Enterprise
9020D7|Microsoft Corporation
90235B|Amazon Technologies Inc.
9025F2|HUAWEI TECHNOLOGIES CO.,LTD
9027E4|Apple, Inc.
902AEE|Xiaomi Communications Co Ltd
902B34|GIGA-BYTE TECHNOLOGY CO.,LTD.
902BD2|HUAWEI TECHNOLOGIES CO.,LTD
902C09|Apple, Inc.
902E16|LCFC(Hefei) Electronics Technology co., ltd
902E1C|Intel Corporate
903196|SHENZHEN IP-COM NETWORKS CO.,LTD.
90324B|Hon Hai Precision Ind. Co.,Ltd.
9034FC|Hon Hai Precision Ind. Co.,Ltd.
9035A2|Apple, Inc.
90380C|Espressif Inc.
90395F|Amazon Technologies Inc.
903A72|Ruckus Wireless
903AA0|Nokia
903C92|Apple, Inc.
903CDA|Fiberhome Telecommunication Technologies Co.,LTD
903D5A|Shenzhen Wision Technology Holding Limited
903E7F|Fiberhome Telecommunication Technologies Co.,LTD
903FC3|Huawei Device Co., Ltd.
903FEA|HUAWEI TECHNOLOGIES CO.,LTD
9041B2|Ubiquiti Inc
904748|Sony Interactive Entertainment Inc.
9047C2|Intel Corporate
90489A|Hon Hai Precision Ind. Co.,Ltd.
9049FA|Intel Corporate
904C81|Hewlett Packard Enterprise
904CC5|Apple, Inc.
904CE5|Hon Hai Precision Ind. Co.,Ltd.
904D4A|Sagemcom Broadband SAS
904DE2|Apple, Inc.
904E2B|HUAWEI TECHNOLOGIES CO.,LTD
9051F8|Hewlett Packard Enterprise
9055DE|Fiberhome Telecommunication Technologies Co.,LTD
905671|Cisco Systems, Inc
905C44|Compal Broadband Networks, Inc.
905E44|HUAWEI TECHNOLOGIES CO.,LTD
905F7A|Apple, Inc.
9060F1|Apple, Inc.
9061AE|Intel Corporate
90623F|Apple, Inc.
90633B|Samsung Electronics Co.,Ltd
90649B|Espressif Inc.
9064AD|HUAWEI TECHNOLOGIES CO.,LTD
906584|Intel Corporate
90671C|HUAWEI TECHNOLOGIES CO.,LTD
9068C3|Motorola Mobility LLC, a Lenovo Company
906989|Samsung Electronics Co.,Ltd
906AEB|Microsoft Corporation
906CAC|Fortinet, Inc.
906D62|Cambium Networks Limited
906EBB|Hon Hai Precision Ind. Co.,Ltd.
907069|Espressif Inc.
9070D3|Fiberhome Telecommunication Technologies Co.,LTD
907240|Apple, Inc.
907282|Sagemcom Broadband SAS
90735A|Motorola Mobility LLC, a Lenovo Company
9074AE|AzureWave Technology Inc.
9074F2|HUAWEI TECHNOLOGIES CO.,LTD
9075BC|Nokia Shanghai Bell Co., Ltd.
9075DE|Zebra Technologies Inc.
90769F|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
9077EE|Cisco Systems, Inc
907841|Intel Corporate
9078B2|Xiaomi Communications Co Ltd
9079CF|zte corporation
907E43|zte corporation
907EBA|UTEK TECHNOLOGY (SHENZHEN) CO.,LTD
90808F|Huawei Device Co., Ltd.
90812A|Apple, Inc.
908158|Apple, Inc.
908175|Samsung Electronics Co.,Ltd
9082C3|Quanta Computer Inc.
90837E|Fiberhome Telecommunication Technologies Co.,LTD
90840D|Apple, Inc.
90869B|zte corporation
908855|Cisco Systems, Inc
908A80|Cisco Systems, Inc
908C43|Apple, Inc.
908D6C|Apple, Inc.
908D6E|Dell Inc.
908D78|D-Link International
909497|HUAWEI TECHNOLOGIES CO.,LTD
9094E4|D-Link International
909507|HUAWEI TECHNOLOGIES CO.,LTD
9097D5|Espressif Inc.
9097F3|Samsung Electronics Co.,Ltd
909838|Huawei Device Co., Ltd.
909A4A|TP-LINK TECHNOLOGIES CO.,LTD.
909B6F|Apple, Inc.
909C4A|Apple, Inc.
909F22|Zyxel Communications Corporation
90A25B|Apple, Inc.
90A57D|Huawei Device Co., Ltd.
90A5AF|HUAWEI TECHNOLOGIES CO.,LTD
90A822|Amazon Technologies Inc.
90AC6D|Apple, Inc.
90AE1B|TP-LINK TECHNOLOGIES CO.,LTD.
90B021|Intel Corporate
90B0ED|Apple, Inc.
90B11C|Dell Inc.
90B141|Motorola Mobility LLC, a Lenovo Company
90B144|Samsung Electronics Co.,Ltd
90B176|Intel Corporate
90B21F|Apple, Inc.
90B339|Espressif Inc.
90B57F|Shenzhen iComm Semiconductor CO.,LTD
90B622|Samsung Electronics Co.,Ltd
90B67A|Shenzhen Skyworth Digital Technology CO., Ltd
90B790|Apple, Inc.
90B832|Extreme Networks, Inc.
90B8E0|SHENZHEN YANRAY TECHNOLOGY CO.,LTD
90B931|Apple, Inc.
90B942|zte corporation
90B9F9|Motorola Mobility LLC, a Lenovo Company
90BA09|HUAWEI TECHNOLOGIES CO.,LTD
90C115|Sony Corporation
90C119|Nokia
90C1C6|Apple, Inc.
90C710|zte corporation
90C7D8|zte corporation
90C97E|HUAWEI TECHNOLOGIES CO.,LTD
90CAFA|Google, Inc.
90CC7A|Huawei Device Co., Ltd.
90CCDF|Intel Corporate
90CDB6|Hon Hai Precision Ind. Co.,Ltd.
90CDE8|Apple, Inc.
90CF15|Nokia Corporation
90D20B|Nokia Shanghai Bell Co., Ltd.
90D432|zte corporation
90D733|HUAWEI TECHNOLOGIES CO.,LTD
90D8F3|zte corporation
90DA72|Espressif Inc.
90DD5D|Apple, Inc.
90DE80|Shenzhen Century Xinyang Technology Co., Ltd
90E17B|Apple, Inc.
90E2BA|Intel Corporate
90E4B0|SHARP Corporation
90E5B1|Espressif Inc.
90E6BA|ASUSTek COMPUTER INC.
90E868|AzureWave Technology Inc.
90E95E|Cisco Systems, Inc
90EB50|Cisco Systems, Inc
90ECE3|Nokia
90ECEA|Apple, Inc.
90EEC7|Samsung Electronics Co.,Ltd
90EF68|Zyxel Communications Corporation
90F04C|Nokia Solutions (Shanghai) Co.,Ltd.
90F1AA|Samsung Electronics Co.,Ltd
90F260|Shenzhen Honesty Electronics Co.,Ltd.
90F644|Huawei Device Co., Ltd.
90F652|TP-LINK TECHNOLOGIES CO.,LTD.
90F80C|Samsung Electronics Co.,Ltd
90F82E|Amazon Technologies Inc.
90F970|HUAWEI TECHNOLOGIES CO.,LTD
90F9B7|HUAWEI TECHNOLOGIES CO.,LTD
90FB5B|Avaya Inc
90FB5D|Beijing Xiaomi Mobile Software Co., Ltd
90FBA6|Hon Hai Precision Ind. Co.,Ltd.
90FD61|Apple, Inc.
90FD73|zte corporation
940070|Nokia Corporation
9400B0|HUAWEI TECHNOLOGIES CO.,LTD
94017D|SHENZHEN SHLINK.CO.,LIMITED
9401C2|Samsung Electronics Co.,Ltd
94049C|HUAWEI TECHNOLOGIES CO.,LTD
940853|Liteon Technology Corporation
9408C7|Huawei Device Co., Ltd.
9409D3|shenzhen maxtopic technology co.,ltd
940B19|HUAWEI TECHNOLOGIES CO.,LTD
940B2D|NetView Technologies(Shenzhen) Co., Ltd
940B83|zte corporation
940BCD|Apple, Inc.
940C6D|TP-LINK TECHNOLOGIES CO.,LTD.
940C98|Apple, Inc.
940D4B|Cisco Systems, Inc
940E5F|Apple, Inc.
940E6B|HUAWEI TECHNOLOGIES CO.,LTD
940EE7|HUAWEI TECHNOLOGIES CO.,LTD
94105A|Dell Inc.
941457|Shenzhen Sundray Technologies company Limited
9415B2|Huawei Device Co., Ltd.
941625|Apple, Inc.
941700|Xiaomi Communications Co Ltd
941787|Nokia
941865|NETGEAR
941882|Hewlett Packard Enterprise
941DD4|Google, Inc.
942053|Nokia Corporation
942157|Apple, Inc.
94236E|Shenzhen Junlan Electronic Ltd
942453|HUAWEI TECHNOLOGIES CO.,LTD
942533|HUAWEI TECHNOLOGIES CO.,LTD
94261D|HUAWEI TECHNOLOGIES CO.,LTD
94270E|Intel Corporate
94286F|zte corporation
942A6F|Ubiquiti Inc
942B68|Apple, Inc.
942D3A|PRIZOR VIZTECH LIMITED
942DDC|Samsung Electronics Co.,Ltd
942E17|Schneider Electric Canada Inc
9433D8|Cisco Systems, Inc
94350A|Samsung Electronics Co.,Ltd
943589|HUAWEI TECHNOLOGIES CO.,LTD
9437F7|Huawei Device Co., Ltd.
94390E|Intel Corporate
9439E5|Hon Hai Precision Ind. Co.,Ltd.
943A91|Amazon Technologies Inc.
943AF0|Nokia Corporation
943B22|NETGEAR
943C96|Sagemcom Broadband SAS
943CC6|Espressif Inc.
943FC2|Hewlett Packard Enterprise
943FD6|Apple, Inc.
9440C9|Hewlett Packard Enterprise
9440F3|HUAWEI TECHNOLOGIES CO.,LTD
944560|Google, Inc.
944667|Cisco Systems, Inc
944788|HUAWEI TECHNOLOGIES CO.,LTD
9447EE|Fiberhome Telecommunication Technologies Co.,LTD
9449F6|Huawei Device Co., Ltd.
944FDB|Nokia
945103|Samsung Electronics Co.,Ltd
9451DC|Espressif Inc.
945244|Samsung Electronics Co.,Ltd
945330|Hon Hai Precision Ind. Co.,Ltd.
9453FF|Intel Corporate
9454C5|Espressif Inc.
945641|Palo Alto Networks
9457A5|Hewlett Packard
945915|Amazon Technologies Inc.
945AEA|HUAWEI TECHNOLOGIES CO.,LTD
945AFC|Amazon Technologies Inc.
945C9A|Apple, Inc.
945DBF|Nokia Solutions and Networks India Private Limited
946010|Huawei Device Co., Ltd.
9460D5|Hewlett Packard Enterprise
94626D|Beijing Xiaomi Electronics Co.,Ltd
9463D1|Samsung Electronics Co.,Ltd
946424|Hewlett Packard Enterprise
94652D|OnePlus Technology (Shenzhen) Co., Ltd
94659C|Intel Corporate
946A7C|OnePlus Technology (Shenzhen) Co., Ltd
94742E|MERCUSYS TECHNOLOGIES CO., LTD.
9476B7|Samsung Electronics Co.,Ltd
94772B|HUAWEI TECHNOLOGIES CO.,LTD
947AF4|HUAWEI TECHNOLOGIES CO.,LTD
947BAE|Xiaomi Communications Co Ltd
947BE7|Samsung Electronics Co.,Ltd
947D77|HUAWEI TECHNOLOGIES CO.,LTD
947F1D|Shenzhen Fastrain Technology Co., Ltd.
947FD8|Shenzhen Skyworth Digital Technology CO., Ltd
9487E0|Xiaomi Communications Co Ltd
948978|Apple, Inc.
948B93|Xiaomi Communications Co Ltd
948BC1|Samsung Electronics Co.,Ltd
949010|HUAWEI TECHNOLOGIES CO.,LTD
949034|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
949386|Shenzhen SiACRRIER Industry Machines Co.,LTD
949426|Apple, Inc.
9495A0|Google, Inc.
949722|AzureWave Technology Inc.
94974F|Liteon Technology Corporation
949869|zte corporation
94988F|Sagemcom Broadband SAS
949901|Shenzhen YITOA Digital Appliance CO.,LTD
949AA9|Microsoft Corporation
949B2C|Extreme Networks, Inc.
949CBE|HUAWEI TECHNOLOGIES CO.,LTD
949D57|Panasonic do Brasil Limitada
949F3E|Sonos, Inc.
949F8B|zte corporation
94A07D|Huawei Device Co., Ltd.
94A25D|HUAWEI TECHNOLOGIES CO.,LTD
94A408|Shenzhen Trolink Technology CO, LTD
94A4F9|HUAWEI TECHNOLOGIES CO.,LTD
94A67E|NETGEAR
94A7B7|zte corporation
94A990|Espressif Inc.
94AA07|Nokia
94AA0A|Fiberhome Telecommunication Technologies Co.,LTD
94ABFE|Nokia
94AD05|Huawei Device Co., Ltd.
94AD23|Apple, Inc.
94AEF0|Cisco Systems, Inc
94B01F|Apple, Inc.
94B10A|Samsung Electronics Co.,Ltd
94B271|HUAWEI TECHNOLOGIES CO.,LTD
94B34F|Ruckus Wireless
94B40F|Hewlett Packard Enterprise
94B43A|Samsung Electronics Co.,Ltd
94B555|Espressif Inc.
94B609|Intel Corporate
94B819|Nokia
94B86D|Intel Corporate
94B97E|Espressif Inc.
94BA06|SHENZHEN BILIAN ELECTRONIC CO.，LTD
94BA56|Shenzhen Coship Electronics Co., Ltd.
94BB43|AzureWave Technology Inc.
94BE46|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
94BF2D|Apple, Inc.
94BF80|zte corporation
94BF94|Juniper Networks
94BF95|Shenzhen Coship Electronics Co., Ltd
94BFC4|Ruckus Wireless
94CA0F|Honeywell Analytics
94CBCD|zte corporation
94CE0F|Huawei Device Co., Ltd.
94CE2C|Sony Corporation
94CFB0|Huawei Device Co., Ltd.
94D00D|HUAWEI TECHNOLOGIES CO.,LTD
94D2BC|HUAWEI TECHNOLOGIES CO.,LTD
94D331|Xiaomi Communications Co Ltd
94D469|Cisco Systems, Inc
94D505|Fiberhome Telecommunication Technologies Co.,LTD
94D54D|HUAWEI TECHNOLOGIES CO.,LTD
94D60E|shenzhen yunmao information technologies co., ltd
94D771|Samsung Electronics Co.,Ltd
94D9B3|TP-LINK TECHNOLOGIES CO.,LTD.
94DB56|Sony Home Entertainment&Sound Products Inc
94DBC9|AzureWave Technology Inc.
94DBDA|HUAWEI TECHNOLOGIES CO.,LTD
94DDF8|Brother Industries, LTD.
94DE80|GIGA-BYTE TECHNOLOGY CO.,LTD.
94DF34|HUAWEI TECHNOLOGIES CO.,LTD
94DF4E|Wistron InfoComm(Kunshan)Co.,Ltd.
94E129|Samsung Electronics Co.,Ltd
94E1AC|Hangzhou Hikvision Digital Technology Co.,Ltd.
94E23C|Intel Corporate
94E300|HUAWEI TECHNOLOGIES CO.,LTD
94E3EE|zte corporation
94E4BA|Huawei Device Co., Ltd.
94E686|Espressif Inc.
94E6BA|Samsung Electronics Co.,Ltd
94E6F7|Intel Corporate
94E70B|Intel Corporate
94E7EA|HUAWEI TECHNOLOGIES CO.,LTD
94E7F3|HUAWEI TECHNOLOGIES CO.,LTD
94E96A|Apple, Inc.
94E979|Liteon Technology Corporation
94E98C|Nokia
94E9EE|Huawei Device Co., Ltd.
94EA32|Apple, Inc.
94EB2C|Google, Inc.
94EF50|TP-Link Systems Inc.
94F128|Hewlett Packard Enterprise
94F392|Fortinet, Inc.
94F665|Ruckus Wireless
94F6A3|Apple, Inc.
94F6D6|Apple, Inc.
94F7AD|Juniper Networks
94FAE8|Shenzhen Eycom Technology Co., Ltd
94FB29|Zebra Technologies Inc.
94FBB2|SHENZHEN GONGJIN ELECTRONICS CO.,LT
94FE22|HUAWEI TECHNOLOGIES CO.,LTD
94FE9D|SHENZHEN GONGJIN ELECTRONICS CO.,LT
94FEF4|Sagemcom Broadband SAS
94FF06|Hewlett Packard Enterprise
94FF3C|Fortinet, Inc.
98006A|zte corporation
9800C6|Apple, Inc.
9801A7|Apple, Inc.
98038E|TP-Link Systems Inc.
9803CF|SHENZHEN BILIAN ELECTRONIC CO.，LTD
9803D8|Apple, Inc.
98045F|Huawei Device Co., Ltd.
98063C|Samsung Electronics Co.,Ltd
980709|Huawei Device Co., Ltd.
98076A|Apple, Inc.
9809CF|OnePlus Technology (Shenzhen) Co., Ltd
980A4B|Nokia Solutions and Networks GmbH & Co. KG
980C82|SAMSUNG ELECTRO MECHANICS CO., LTD.
980CA5|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
980D51|Huawei Device Co., Ltd.
980D67|Zyxel Communications Corporation
980D6F|Samsung Electronics Co.,Ltd
980DAF|Apple, Inc.
981094|Shenzhen Vsun communication technology Co.,ltd
9810E8|Apple, Inc.
9812E0|Xiaomi Communications Co Ltd
981333|zte corporation
98171A|Beijing Xiaomi Mobile Software Co., Ltd
9817F1|zte corporation
981888|Cisco Meraki
981A35|HUAWEI TECHNOLOGIES CO.,LTD
981CA2|Apple, Inc.
981DFA|Samsung Electronics Co.,Ltd
981E19|Sagemcom Broadband SAS
981FB1|Shenzhen Lemon Network Technology Co.,Ltd
98226E|Amazon Technologies Inc.
9822EF|Liteon Technology Corporation
98247B|HUAWEI TECHNOLOGIES CO.,LTD
98254A|TP-Link Systems Inc
9828A6|COMPAL INFORMATION (KUNSHAN) CO., LTD.
9829A6|COMPAL INFORMATION (KUNSHAN) CO., LTD.
982A0A|Intelbras
982AFD|HUAWEI TECHNOLOGIES CO.,LTD
982BA6|Motorola Mobility LLC, a Lenovo Company
982CBC|Intel Corporate
982D68|Samsung Electronics Co., Ltd
982FF8|Huawei Device Co., Ltd.
9835ED|HUAWEI TECHNOLOGIES CO.,LTD
98398E|Samsung Electronics Co.,Ltd
983A1F|Google, Inc.
983B8F|Intel Corporate
983C8C|Apple, Inc.
983DAE|Espressif Inc.
983F60|HUAWEI TECHNOLOGIES CO.,LTD
983FA4|zte corporation
983FE8|Samsung Electronics Co.,Ltd
9840BB|Dell Inc.
984265|Sagemcom Broadband SAS
9842F5|Apple, Inc.
9843FA|Intel Corporate
9844CE|HUAWEI TECHNOLOGIES CO.,LTD
98460A|Apple, Inc.
984744|Shenzhen Boomtech Industrial Corporation
984827|TP-LINK TECHNOLOGIES CO.,LTD.
984874|HUAWEI TECHNOLOGIES CO.,LTD
984925|Juniper Networks
984B06|HUAWEI TECHNOLOGIES CO.,LTD
984BE1|Hewlett Packard
984E8A|Samsung Electronics Co.,Ltd
984FEE|Intel Corporate
98502E|Apple, Inc.
9851FC|Huawei Device Co., Ltd.
985207|HUAWEI TECHNOLOGIES CO.,LTD
9852B1|Samsung Electronics Co.,Ltd
98535F|HUAWEI TECHNOLOGIES CO.,LTD
98541B|Intel Corporate
9857D3|HON HAI-CCPBG PRECISION IND.CO.,LTD.
98597A|Intel Corporate
985A98|HUAWEI TECHNOLOGIES CO.,LTD
985AEB|Apple, Inc.
985F41|Intel Corporate
985FD3|Microsoft Corporation
9860CA|Apple, Inc.
986110|HUAWEI TECHNOLOGIES CO.,LTD
986297|Shenzhen Techwinsemi Technology Co., Ltd.
986610|zte corporation
98698A|Apple, Inc.
986CF5|zte corporation
986DC8|TOSHIBA MITSUBISHI-ELECTRIC INDUSTRIAL SYSTEMS CORPORATION
98743D|Shenzhen Jun Kai Hengye Technology Co. Ltd
98751A|Huawei Device Co., Ltd.
987552|Xiaomi Communications Co Ltd
987A14|Microsoft Corporation
987A9B|TCL MOKA International Limited
987EB5|Huawei Device Co., Ltd.
9880EE|Samsung Electronics Co.,Ltd
98818A|Huawei Device Co., Ltd.
988389|Samsung Electronics Co.,Ltd
98865D|Nokia Shanghai Bell Co., Ltd.
98868B|Juniper Networks
98876C|Huawei Device Co., Ltd.
98886C|Huawei Device Co., Ltd.
9888E0|Espressif Inc.
988B0A|Hangzhou Hikvision Digital Technology Co.,Ltd.
988B5D|Sagemcom Broadband SAS
988B69|Shenzhen hylitech Co.,LTD
988D46|Intel Corporate
988F00|Hewlett Packard Enterprise
989096|Dell Inc.
9893CC|LG ELECTRONICS INC
9897CC|TP-LINK TECHNOLOGIES CO.,LTD.
9898FB|Google, Inc.
989AB9|zte corporation
989C57|HUAWEI TECHNOLOGIES CO.,LTD
989DE5|Hangzhou Hikvision Digital Technology Co.,Ltd.
989E63|Apple, Inc.
989F1E|HUAWEI TECHNOLOGIES CO.,LTD
98A2C0|Cisco Systems, Inc
98A316|Espressif Inc.
98A33C|Shenzhen Cultraview Digital Technology Co., Ltd
98A375|Huawei Device Co., Ltd.
98A5F9|Apple, Inc.
98AD1D|Huawei Device Co., Ltd.
98AF65|Intel Corporate
98B039|Nokia
98B08B|Samsung Electronics Co.,Ltd
98B379|Apple, Inc.
98B3EF|Huawei Device Co., Ltd.
98B785|Shenzhen 10Gtek Transceivers Co., Limited
98B8BA|LG Electronics (Mobile Communications)
98B8BC|Samsung Electronics Co.,Ltd
98B8E3|Apple, Inc.
98BA5F|TP-Link Systems Inc.
98BD80|Intel Corporate
98C08A|HUAWEI TECHNOLOGIES CO.,LTD
98C377|Espressif Inc.
98C7A4|Shenzhen HS Fiber Communication Equipment CO., LTD
98C97C|Shenzhen iComm Semiconductor CO.,LTD
98C9BE|Shenzhen SDMC Technology CO., LTD
98CA33|Apple, Inc.
98CAB5|Apple, Inc.
98CC4D|Shenzhen mantunsci co., LTD
98CCD9|Shenzhen SuperElectron Technology Co.,Ltd.
98CCE4|Shenzhen Mindray Animal Medical Technology Co.,LTD
98CCF3|Amazon Technologies Inc.
98CDAC|Espressif Inc.
98CF7D|Apple, Inc.
98D293|Google, Inc.
98D331|Shenzhen Bolutek Technology Co.,Ltd.
98D3D7|HUAWEI TECHNOLOGIES CO.,LTD
98D6BB|Apple, Inc.
98D6F7|LG Electronics (Mobile Communications)
98D742|Samsung Electronics Co.,Ltd
98D7E1|Cisco Systems, Inc
98DAC4|TP-LINK TECHNOLOGIES CO.,LTD.
98DD60|Apple, Inc.
98DED0|TP-LINK TECHNOLOGIES CO.,LTD.
98DF82|Hangzhou Hikvision Digital Technology Co.,Ltd.
98E081|Beijing Xiaomi Mobile Software Co., Ltd
98E0D9|Apple, Inc.
98E301|Shenzhen Sundray Technologies company Limited
98E55B|Intelbras
98E743|Dell Inc.
98E79A|Foxconn(NanJing) Communication Co.,Ltd.
98E7F4|Hewlett Packard
98E7F5|HUAWEI TECHNOLOGIES CO.,LTD
98E859|Apple, Inc.
98EDCA|Fiberhome Telecommunication Technologies Co.,LTD
98EE8C|zte corporation
98EE94|Xiaomi Communications Co Ltd
98EECB|Wistron Infocomm (Zhongshan) Corporation
98F04C|Cisco Systems, Inc
98F083|HUAWEI TECHNOLOGIES CO.,LTD
98F0AB|Apple, Inc.
98F112|Hangzhou Hikvision Digital Technology Co.,Ltd.
98F2B3|Hewlett Packard Enterprise
98F3F6|HUAWEI TECHNOLOGIES CO.,LTD
98F428|zte corporation
98F4AB|Espressif Inc.
98F537|zte corporation
98F621|Xiaomi Communications Co Ltd
98F67A|Chipsea Technologies (Shenzhen) Crop.
98F9CC|Zhejiang Dahua Technology Co., Ltd.
98FA2E|Sony Interactive Entertainment Inc.
98FA9B|LCFC(Hefei) Electronics Technology co., ltd
98FAE3|Xiaomi Communications Co Ltd
98FB27|Samsung Electronics Co.,Ltd
98FC11|Cisco-Linksys, LLC
98FE3E|Intel Corporate
98FE54|Raspberry Pi (Trading) Ltd
98FE94|Apple, Inc.
98FEE1|Apple, Inc.
98FFD0|Lenovo Mobile Communication Technology Ltd.
9C00D3|SHENZHEN IK WORLD Technology Co., Ltd
9C0111|Shenzhen Newabel Electronic Co., Ltd.
9C0298|Samsung Electronics Co.,Ltd
9C0351|HUAWEI TECHNOLOGIES CO.,LTD
9C04EB|Apple, Inc.
9C05D6|Ubiquiti Inc
9C098B|Cisco Systems, Inc
9C09CA|Huawei Device Co., Ltd.
9C0C35|Shenzhenshi Xinzhongxin Technology Co.Ltd
9C0E4A|Shenzhen Vastking Electronic Co.,Ltd.
9C0E51|Schneider Electric
9C139E|Espressif Inc.
9C1463|Zhejiang Dahua Technology Co., Ltd.
9C1874|Nokia Danmark A/S
9C1A25|Apple, Inc.
9C1C12|Hewlett Packard Enterprise
9C1D36|HUAWEI TECHNOLOGIES CO.,LTD
9C1FE6|Shenzhen Skyworth Display Technologies Co.,Ltd
9C207B|Apple, Inc.
9C216A|TP-LINK TECHNOLOGIES CO.,LTD.
9C2183|Broadcom Limited
9C2472|Sagemcom Broadband SAS
9C2595|Samsung Electronics Co.,Ltd
9C28B3|Apple, Inc.
9C28EF|HUAWEI TECHNOLOGIES CO.,LTD
9C28F7|Xiaomi Communications Co Ltd
9C293F|Apple, Inc.
9C2976|Intel Corporate
9C2A70|Hon Hai Precision Ind. Co.,Ltd.
9C2A83|Samsung Electronics Co.,Ltd
9C2DCD|LCFC(Hefei) Electronics Technology co., ltd
9C2E7A|Samsung Electronics Co.,Ltd
9C2EA1|Xiaomi Communications Co Ltd
9C2F4E|zte corporation
9C2F9D|Liteon Technology Corporation
9C305B|Hon Hai Precision Ind. Co.,Ltd.
9C32CE|CANON INC.
9C35EB|Apple, Inc.
9C3708|Hewlett Packard Enterprise
9C37CB|Sony Interactive Entertainment Inc.
9C37F4|HUAWEI TECHNOLOGIES CO.,LTD
9C3818|Cisco Systems, Inc
9C3928|Samsung Electronics Co.,Ltd
9C3A9A|Shenzhen Sundray Technologies company Limited
9C3AAF|Samsung Electronics Co.,Ltd
9C3DCF|NETGEAR
9C3E53|Apple, Inc.
9C4782|TP-LINK TECHNOLOGIES CO.,LTD.
9C47F4|Nokia
9C4929|HUAWEI TECHNOLOGIES CO.,LTD
9C4A7B|Nokia Corporation
9C4DC2|Cisco Systems, Inc
9C4E20|Cisco Systems, Inc
9C4E36|Intel Corporate
9C4F5F|Google, Inc.
9C4FAC|zte corporation
9C4FDA|Apple, Inc.
9C52F8|HUAWEI TECHNOLOGIES CO.,LTD
9C5322|TP-Link Systems Inc
9C5416|Cisco Systems, Inc
9C541C|Shenzhen My-power Technology Co.,Ltd
9C5467|Nokia
9C5636|Huawei Device Co., Ltd.
9C5766|HUAWEI TECHNOLOGIES CO.,LTD
9C57AD|Cisco Systems, Inc
9C583C|Apple, Inc.
9C5884|Apple, Inc.
9C5A44|COMPAL INFORMATION (KUNSHAN) CO., LTD.
9C5A80|Juniper Networks
9C5A81|Xiaomi Communications Co Ltd
9C5C8E|ASUSTek COMPUTER INC.
9C5CF9|Sony Corporation
9C5D12|Extreme Networks, Inc.
9C5FB0|Samsung Electronics Co.,Ltd
9C6076|Apple, Inc.
9C611D|Panasonic Corporation of North America
9C61D7|HUAWEI TECHNOLOGIES CO.,LTD
9C635B|zte corporation
9C63ED|zte corporation
9C648B|Apple, Inc.
9C65B0|Samsung Electronics Co.,Ltd
9C65EB|Intel Corporate
9C6697|Cisco Systems, Inc
9C67D6|Intel Corporate
9C6865|Fiberhome Telecommunication Technologies Co.,LTD
9C69D1|HUAWEI TECHNOLOGIES CO.,LTD
9C6BF0|Shenzhen Yipingfang Network Technology Co., Ltd.
9C6C15|Microsoft Corporation
9C6F52|zte corporation
9C713A|HUAWEI TECHNOLOGIES CO.,LTD
9C7370|HUAWEI TECHNOLOGIES CO.,LTD
9C73B1|Samsung Electronics Co.,Ltd
9C741A|HUAWEI TECHNOLOGIES CO.,LTD
9C746F|HUAWEI TECHNOLOGIES CO.,LTD
9C760E|Apple, Inc.
9C79E3|Apple, Inc.
9C7BEF|Hewlett Packard
9C7DA3|HUAWEI TECHNOLOGIES CO.,LTD
9C7F81|SHENZHEN FAST TECHNOLOGIES CO.,LTD
9C823F|Huawei Device Co., Ltd.
9C8306|Samsung Electronics Co.,Ltd
9C84B6|Shenzhen iComm Semiconductor CO.,LTD
9C84BF|Apple, Inc.
9C862B|MOTOROLA SOLUTIONS MALAYSIA SDN. BHD.
9C88AD|Fiberhome Telecommunication Technologies Co.,LTD
9C8ACB|Juniper Networks
9C8BA0|Apple, Inc.
9C8C6E|Samsung Electronics Co.,Ltd
9C8CD8|Hewlett Packard Enterprise
9C8E99|Hewlett Packard
9C8E9C|Huawei Device Co., Ltd.
9C924F|Apple, Inc.
9C934E|Xerox Corporation
9C9567|Huawei Device Co., Ltd.
9C9613|Lenovo Future Communication Technology (Chongqing) Company Limited
9C96D5|Espressif Systems (Singapore) Pte. Ltd
9C971B|Intel Corporate
9C9774|HUAWEI TECHNOLOGIES CO.,LTD
9C9793|HUAWEI TECHNOLOGIES CO.,LTD
9C99A0|Xiaomi Communications Co Ltd
9C9C1F|Espressif Inc.
9C9D07|FN-LINK TECHNOLOGY Ltd.
9C9D7E|Beijing Xiaomi Mobile Software Co., Ltd
9C9E6E|Espressif Inc.
9C9E71|Huawei Device Co., Ltd.
9C9ED5|Xiaomi Communications Co Ltd
9CA118|Huawei Device Co., Ltd.
9CA2F4|TP-Link Systems Inc
9CA389|Nokia
9CA513|Samsung Electronics Co.,Ltd
9CA615|TP-LINK TECHNOLOGIES CO.,LTD.
9CA6D8|Fiberhome Telecommunication Technologies Co.,LTD
9CA9B8|Cisco Systems, Inc
9CA9C5|Apple, Inc.
9CA9E4|zte corporation
9CAA1B|Microsoft Corporation
9CAD97|Hon Hai Precision Ind. Co.,Ltd.
9CAED3|Seiko Epson Corporation
9CAFCA|Cisco Systems, Inc
9CB150|Intel Corporate
9CB2B2|HUAWEI TECHNOLOGIES CO.,LTD
9CB2E8|HUAWEI TECHNOLOGIES CO.,LTD
9CB400|zte corporation
9CB654|Hewlett Packard
9CB6D0|Rivet Networks
9CB70D|Liteon Technology Corporation
9CBCA6|Hewlett Packard Enterprise
9CBCF0|Xiaomi Communications Co Ltd
9CBFCD|HUAWEI TECHNOLOGIES CO.,LTD
9CC172|HUAWEI TECHNOLOGIES CO.,LTD
9CC394|Apple, Inc.
9CC7D1|SHARP Corporation
9CC7D3|AzureWave Technology Inc.
9CC893|Juniper Networks
9CC8E9|Amazon Technologies Inc.
9CC9EB|NETGEAR
9CCAD9|Nokia Corporation
9CCC01|Espressif Inc.
9CCC83|Juniper Networks
9CD21E|Hon Hai Precision Ind. Co.,Ltd.
9CD24B|zte corporation
9CD35B|Samsung Electronics Co.,Ltd
9CD36D|NETGEAR
9CD57D|Cisco Systems, Inc
9CD643|D-Link International
9CD917|Motorola Mobility LLC, a Lenovo Company
9CDA3E|Intel Corporate
9CDAA8|Apple, Inc.
9CDAB7|Hewlett Packard Enterprise
9CDBAF|HUAWEI TECHNOLOGIES CO.,LTD
9CDC71|Hewlett Packard Enterprise
9CDC99|Extreme Networks, Inc.
9CDF8A|HUAWEI TECHNOLOGIES CO.,LTD
9CDFB1|Shenzhen Crave Communication Co., LTD
9CE041|Nokia
9CE063|Samsung Electronics Co.,Ltd
9CE176|Cisco Systems, Inc
9CE330|Cisco Meraki
9CE33F|Apple, Inc.
9CE374|HUAWEI TECHNOLOGIES CO.,LTD
9CE65E|Apple, Inc.
9CE6E7|Samsung Electronics Co.,Ltd
9CE91C|zte corporation
9CE951|Shenzhen Sang Fei Consumer Communications Ltd., Co.
9CEC61|Huawei Device Co., Ltd.
9CF155|Nokia
9CF1D4|Roku, Inc
9CF27E|Samsung Electronics Co.,Ltd
9CF387|Apple, Inc.
9CF3AC|Apple, Inc.
9CF48E|Apple, Inc.
9CF8B8|Shenzhen Skyworth Digital Technology CO., Ltd
9CF8DB|shenzhen eyunmei technology co,.ltd
9CF9A1|Juniper Networks
9CFA76|Apple, Inc.
9CFC01|Apple, Inc.
9CFC28|Apple, Inc.
9CFCE8|Intel Corporate
9CFEA1|Fiberhome Telecommunication Technologies Co.,LTD
A002A5|Intel Corporate
A002DC|Amazon Technologies Inc.
A00460|NETGEAR
A00798|Samsung Electronics Co.,Ltd
A0086F|HUAWEI TECHNOLOGIES CO.,LTD
A0092E|zte corporation
A009ED|Avaya Inc
A00A9A|Huawei Device Co., Ltd.
A00BBA|SAMSUNG ELECTRO MECHANICS CO., LTD.
A00CE2|Shenzhen Shokz Co., Ltd.
A00E98|HUAWEI TECHNOLOGIES CO.,LTD
A00F37|Cisco Systems, Inc
A01077|zte corporation
A01081|Samsung Electronics Co.,Ltd
A01290|Avaya Inc
A013CB|Fiberhome Telecommunication Technologies Co.,LTD
A01828|Apple, Inc.
A01859|Shenzhen Yidashi Electronics Co Ltd
A01B29|Sagemcom Broadband SAS
A01B9E|Samsung Electronics Co.,Ltd
A01C8D|HUAWEI TECHNOLOGIES CO.,LTD
A01D48|Hewlett Packard
A020A6|Espressif Inc.
A02195|Samsung Electronics Co.,Ltd
A021B7|NETGEAR
A0239F|Cisco Systems, Inc
A02442|Shenzhenshi Xinzhongxin Technology Co.Ltd
A025D7|Hewlett Packard Enterprise
A027B6|Samsung Electronics Co.,Ltd
A02919|Dell Inc.
A02942|Intel Corporate
A02BB8|Hewlett Packard
A02C36|FN-LINK TECHNOLOGY LIMITED
A02DDB|Sagemcom Broadband SAS
A031DB|HUAWEI TECHNOLOGIES CO.,LTD
A03299|Lenovo (Beijing) Co., Ltd.
A0334F|Cisco Systems, Inc
A03679|HUAWEI TECHNOLOGIES CO.,LTD
A0369F|Intel Corporate
A036BC|ASUSTek COMPUTER INC.
A03768|Shenzhen E-Life Intelligence Technology Co.,Ltd.
A039EE|Sagemcom Broadband SAS
A039F7|LG Electronics (Mobile Communications)
A039F9|Sagemcom Broadband SAS
A03BE3|Apple, Inc.
A03C20|Sagemcom Broadband SAS
A03C31|Shenzhen Belon Technology CO.,LTD
A03D6E|Cisco Systems, Inc
A03D6F|Cisco Systems, Inc
A0406F|HUAWEI TECHNOLOGIES CO.,LTD
A040A0|NETGEAR
A04147|Huawei Device Co., Ltd.
A042D1|Huawei Device Co., Ltd.
A0445C|HUAWEI TECHNOLOGIES CO.,LTD
A044B7|PAX Computer Technology(Shenzhen) Ltd.
A0465A|Motorola Mobility LLC, a Lenovo Company
A0481C|Hewlett Packard
A04839|HUAWEI TECHNOLOGIES CO.,LTD
A04A5E|Microsoft Corporation
A04C0C|Shenzhen Skyworth Digital Technology CO., Ltd
A04C5B|Shenzhen TINNO Mobile Technology Corp.
A04E04|Nokia Corporation
A04E8D|Cisco Meraki
A04EA7|Apple, Inc.
A04ECF|Apple, Inc.
A04F52|Intel Corporate
A04F85|LG Electronics (Mobile Communications)
A04FE4|PAX Computer Technology(Shenzhen) Ltd.
A0510B|Intel Corporate
A051C6|Avaya Inc
A05272|Apple, Inc.
A05394|Shenzhen zediel co., Ltd.
A0551F|Sagemcom Broadband SAS
A0552E|zte corporation
A0554F|Cisco Systems, Inc
A0562C|Samsung Electronics Co.,Ltd
A056F3|Apple, Inc.
A057E3|HUAWEI TECHNOLOGIES CO.,LTD
A05911|Cisco Meraki
A05950|Intel Corporate
A06090|Samsung Electronics Co.,Ltd
A06391|NETGEAR
A06610|FUJITSU LIMITED
A067D6|Nokia
A070B7|HUAWEI TECHNOLOGIES CO.,LTD
A071A9|Nokia Corporation
A07591|Samsung Electronics Co.,Ltd
A0764E|Espressif Inc.
A0779E|Chipsea Technologies (Shenzhen) Corp.
A07817|Apple, Inc.
A0782D|Apple, Inc.
A07D42|COMPAL INFORMATION (KUNSHAN) CO., LTD.
A07D9C|Samsung Electronics Co.,Ltd
A07F8A|Sagemcom Broadband SAS
A08069|Intel Corporate
A0821F|Samsung Electronics Co.,Ltd
A08527|Intel Corporate
A085E3|Espressif Inc.
A085FC|Microsoft Corporation
A086C6|Xiaomi Communications Co Ltd
A087BE|Apple, Inc.
A08869|Intel Corporate
A0889D|Huawei Device Co., Ltd.
A088B4|Intel Corporate
A089E4|Skyworth Digital Technology(Shenzhen) Co.,Ltd
A08CF8|HUAWEI TECHNOLOGIES CO.,LTD
A08CFD|Hewlett Packard
A08D16|HUAWEI TECHNOLOGIES CO.,LTD
A08E78|Sagemcom Broadband SAS
A09169|LG Electronics (Mobile Communications)
A091A2|OnePlus Electronics (Shenzhen) Co., Ltd.
A091C8|zte corporation
A091CA|Nokia Solutions and Networks GmbH & Co. KG
A09208|Tuya Smart Inc.
A09351|Cisco Systems, Inc
A0946A|Shenzhen XGTEC Technology Co,.Ltd.
A09857|Shenzhen ELINK Technology Co., Ltd.
A0999B|Apple, Inc.
A09A52|Shenzhen MoreSense Technology Co., Ltd.
A09A8E|Apple, Inc.
A09D22|Apple, Inc.
A09F10|SHENZHEN BILIAN ELECTRONIC CO.，LTD
A09F7A|D-Link Middle East FZCO
A0A001|Hewlett Packard Enterprise
A0A0DC|Huawei Device Co., Ltd.
A0A309|Apple, Inc.
A0A33B|HUAWEI TECHNOLOGIES CO.,LTD
A0A3B3|Espressif Inc.
A0A3F0|D-Link International
A0A47F|Cisco Systems, Inc
A0A4C5|Intel Corporate
A0A8CD|Intel Corporate
A0AB1B|D-Link International
A0AC69|Samsung Electronics Co.,Ltd
A0AC78|Shenzhen iComm Semiconductor CO.,LTD
A0AD62|HUAWEI TECHNOLOGIES CO.,LTD
A0AD9F|ASUSTek COMPUTER INC.
A0AF12|HUAWEI TECHNOLOGIES CO.,LTD
A0AFBD|Intel Corporate
A0B0BD|Samsung Electronics Co.,Ltd
A0B100|ShenZhen Cando Electronics Co.,Ltd
A0B15C|Google, Inc.
A0B339|Intel Corporate
A0B3CC|Hewlett Packard
A0B40F|Apple, Inc.
A0B439|Cisco Systems, Inc
A0B4A5|Samsung Electronics Co.,Ltd
A0B765|Espressif Inc.
A0BC6F|Cisco Systems, Inc
A0BD1D|Zhejiang Dahua Technology Co., Ltd.
A0BD71|QUALCOMM Incorporated
A0C1C5|Apple, Inc.
A0C20D|Huawei Device Co., Ltd.
A0C589|Intel Corporate
A0C6EC|ShenZhen ANYK Technology Co.,LTD
A0C773|Chipsea Technologies (Shenzhen) Corp.
A0C7D2|Cisco Systems, Inc
A0C926|Huawei Device Co., Ltd.
A0C98B|Nokia Solutions and Networks GmbH & Co. KG
A0CBFD|Samsung Electronics Co.,Ltd
A0CF5B|Cisco Systems, Inc
A0CFF5|zte corporation
A0D05B|Samsung Electronics Co.,Ltd
A0D0DC|Amazon Technologies Inc.
A0D1B3|Apple, Inc.
A0D2B1|Amazon Technologies Inc.
A0D365|Intel Corporate
A0D37A|Intel Corporate
A0D3C1|Hewlett Packard
A0D722|Samsung Electronics Co.,Ltd
A0D795|Apple, Inc.
A0D7A0|Huawei Device Co., Ltd.
A0D7F3|Samsung Electronics Co.,Ltd
A0D807|Huawei Device Co., Ltd.
A0D83D|Fiberhome Telecommunication Technologies Co.,LTD
A0DD6C|Espressif Inc.
A0DDE5|SHARP Corporation
A0DE0F|Huawei Device Co., Ltd.
A0DF15|HUAWEI TECHNOLOGIES CO.,LTD
A0E06D|Fiberhome Telecommunication Technologies Co.,LTD
A0E0AF|Cisco Systems, Inc
A0E390|Apple, Inc.
A0E453|Sony Corporation
A0E4CB|Zyxel Communications Corporation
A0E70B|Intel Corporate
A0EC80|zte corporation
A0ECF9|Cisco Systems, Inc
A0EDCD|Apple, Inc.
A0EE1A|Apple, Inc.
A0F261|Palo Alto Networks
A0F262|Espressif Inc.
A0F3C1|TP-LINK TECHNOLOGIES CO.,LTD.
A0F419|Nokia Corporation
A0F459|FN-LINK TECHNOLOGY LIMITED
A0F479|HUAWEI TECHNOLOGIES CO.,LTD
A0F849|Cisco Systems, Inc
A0F895|Shenzhen TINNO Mobile Technology Corp.
A0FAC8|HUAWEI TECHNOLOGIES CO.,LTD
A0FBC5|Apple, Inc.
A0FF0C|Hangzhou Hikvision Digital Technology Co.,Ltd.
A0FF22|SHENZHEN APICAL TECHNOLOGY CO., LTD
A4004E|Cisco Systems, Inc
A400E2|HUAWEI TECHNOLOGIES CO.,LTD
A402B7|Amazon Technologies Inc.
A402B9|Intel Corporate
A407B6|Samsung Electronics Co.,Ltd
A40801|Amazon Technologies Inc.
A40853|Nokia Solutions and Networks India Private Limited
A408F5|Sagemcom Broadband SAS
A40987|Apple, Inc.
A409B3|HUAWEI TECHNOLOGIES CO.,LTD
A40C66|Shenzhen Colorful Yugong Technology and Development Co., Ltd.
A40CC3|Cisco Systems, Inc
A40E75|Hewlett Packard Enterprise
A410B6|Cisco Systems, Inc
A41194|Lenovo
A411BB|Cisco Systems, Inc
A41437|Hangzhou Hikvision Digital Technology Co.,Ltd.
A416C0|Apple, Inc.
A416E7|HUAWEI TECHNOLOGIES CO.,LTD
A41731|Hon Hai Precision Ind. Co.,Ltd.
A4178B|HUAWEI TECHNOLOGIES CO.,LTD
A41791|Shenzhen Decnta Technology Co.,LTD.
A41875|Cisco Systems, Inc
A41908|Fiberhome Telecommunication Technologies Co.,LTD
A41A3A|TP-LINK TECHNOLOGIES CO.,LTD.
A41A6E|zte corporation
A41F72|Dell Inc.
A42249|Sagemcom Broadband SAS
A422B6|Motorola Mobility LLC, a Lenovo Company
A4251B|Avaya Inc
A426CA|Intel Corporate
A427A5|Palo Alto Networks
A42902|Hangzhou Hikvision Digital Technology Co.,Ltd.
A42940|Shenzhen YOUHUA Technology Co., Ltd
A42A95|D-Link International
A42B8C|NETGEAR
A42BB0|TP-LINK TECHNOLOGIES CO.,LTD.
A42DF1|Motorola Mobility LLC, a Lenovo Company
A4307A|Samsung Electronics Co.,Ltd
A43135|Apple, Inc.
A434D9|Intel Corporate
A4373E|Huawei Device Co., Ltd.
A43828|HUAWEI TECHNOLOGIES CO.,LTD
A439B3|Beijing Xiaomi Mobile Software Co., Ltd
A439B6|SHENZHEN PEIZHE MICROELECTRONICS CO .LTD
A43B0E|Huawei Device Co., Ltd.
A43F51|Shenzhen Benew Technology Co.,Ltd.
A43FA7|Hewlett Packard Enterprise
A44027|zte corporation
A4403D|Shenzhen Baseus Technology Co., Ltd.
A4423B|Intel Corporate
A44280|Apple, Inc.
A44343|Huawei Device Co., Ltd.
A44380|Huawei Device Co., Ltd.
A44519|Xiaomi Communications Co Ltd
A446B4|Huawei Device Co., Ltd.
A44BD5|Xiaomi Communications Co Ltd
A44BD9|Hangzhou Hikvision Digital Technology Co.,Ltd.
A44C11|Cisco Systems, Inc
A44CC8|Dell Inc.
A44E31|Intel Corporate
A45006|SHENZHEN HUACHUANG SHIDAI TECHNOLOGYCO.,LTD
A45046|Xiaomi Communications Co Ltd
A4515E|Juniper Networks
A4516F|Microsoft Mobile Oy
A4530E|Cisco Systems, Inc
A45590|Xiaomi Communications Co Ltd
A45630|Cisco Systems, Inc
A45D36|Hewlett Packard
A45E60|Apple, Inc.
A46011|Verifone, Inc.
A46706|Apple, Inc.
A46BB6|Intel Corporate
A46C24|HUAWEI TECHNOLOGIES CO.,LTD
A46C2A|Cisco Systems, Inc
A46CF1|Samsung Electronics Co.,Ltd
A46DA4|HUAWEI TECHNOLOGIES CO.,LTD
A470D6|Motorola Mobility LLC, a Lenovo Company
A47174|HUAWEI TECHNOLOGIES CO.,LTD
A473AB|Extreme Networks, Inc.
A475B9|Samsung Electronics Co.,Ltd
A47733|Google, Inc.
A47760|Nokia Corporation
A477F3|Apple, Inc.
A47806|Cisco Systems, Inc
A47886|Avaya Inc
A47952|Huawei Device Co., Ltd.
A47B1A|Huawei Device Co., Ltd.
A47B2C|Nokia
A47B9D|Espressif Inc.
A47CC9|HUAWEI TECHNOLOGIES CO.,LTD
A47D9F|Shenzhen iComm Semiconductor CO.,LTD
A47E39|zte corporation
A47F1B|Juniper Networks
A481EE|Nokia Corporation
A483E7|Apple, Inc.
A48431|Samsung Electronics Co.,Ltd
A48873|Cisco Systems, Inc
A48CDB|Lenovo
A49005|CHINA GREATWALL COMPUTER SHENZHEN CO.,LTD
A492CB|Nokia
A4933F|HUAWEI TECHNOLOGIES CO.,LTD
A4934C|Cisco Systems, Inc
A493AD|Huawei Device Co., Ltd.
A493FE|HUAWEI TECHNOLOGIES CO.,LTD
A49700|Cisco Systems, Inc
A49791|Extreme Networks, Inc.
A49947|HUAWEI TECHNOLOGIES CO.,LTD
A49A58|Samsung Electronics Co.,Ltd
A49B4F|HUAWEI TECHNOLOGIES CO.,LTD
A49BCD|Cisco Systems, Inc
A49DB8|SHENZHEN TECNO TECHNOLOGY
A49DDD|Samsung Electronics Co.,Ltd
A49FE7|Samsung Electronics Co.,Ltd
A4A24A|Cisco SPVTG
A4A459|Hangzhou Hikvision Digital Technology Co.,Ltd.
A4A46B|HUAWEI TECHNOLOGIES CO.,LTD
A4A490|Samsung Electronics Co.,Ltd
A4A584|Cisco Systems, Inc
A4A80F|Shenzhen Coship Electronics Co., Ltd.
A4A930|Beijing Xiaomi Mobile Software Co., Ltd
A4AAFE|Huawei Device Co., Ltd.
A4AB39|Shenzhen Taichi Technology Limited
A4AC0F|Huawei Device Co., Ltd.
A4AE11|Hon Hai Precision Industry Co., Ltd.
A4AE12|Hon Hai Precision Industry Co., Ltd.
A4B039|Shenzhen iComm Semiconductor CO.,LTD
A4B197|Apple, Inc.
A4B1C1|Intel Corporate
A4B239|Cisco Systems, Inc
A4B256|Shenzhen Incar Technology Co., Ltd.
A4B439|Cisco Systems, Inc
A4B61E|Huawei Device Co., Ltd.
A4B805|Apple, Inc.
A4BA70|Beijing Xiaomi Mobile Software Co., Ltd
A4BA76|HUAWEI TECHNOLOGIES CO.,LTD
A4BADB|Dell Inc.
A4BB6D|Dell Inc.
A4BDC4|HUAWEI TECHNOLOGIES CO.,LTD
A4BE2B|HUAWEI TECHNOLOGIES CO.,LTD
A4BF01|Intel Corporate
A4C0C7|ShenZhen Hitom Communication Technology Co..LTD
A4C337|Apple, Inc.
A4C361|Apple, Inc.
A4C3BE|Xiaomi Communications Co Ltd
A4C3F0|Intel Corporate
A4C494|Intel Corporate
A4C54E|Huawei Device Co., Ltd.
A4C64F|HUAWEI TECHNOLOGIES CO.,LTD
A4C69A|Samsung Electronics Co.,Ltd
A4C6F0|Apple, Inc.
A4C74B|Huawei Device Co., Ltd.
A4C788|Xiaomi Communications Co Ltd
A4C7F6|Extreme Networks, Inc.
A4CAA0|HUAWEI TECHNOLOGIES CO.,LTD
A4CB8F|Espressif Inc.
A4CCB3|Xiaomi Communications Co Ltd
A4CD23|Shenzhenshi Xinzhongxin Co., Ltd
A4CF12|Espressif Inc.
A4CF99|Apple, Inc.
A4D18C|Apple, Inc.
A4D18F|Shenzhen Skyee Optical Fiber Communication Technology Ltd.
A4D1D2|Apple, Inc.
A4D23E|Apple, Inc.
A4D4B2|Shenzhen MeiG Smart Technology Co.,Ltd
A4D530|Avaya LLC
A4D5C2|Hangzhou Hikvision Digital Technology Co.,Ltd.
A4D73C|Seiko Epson Corporation
A4D7D6|Shenzhen Linkoh Network Technology Co;Ltd
A4D931|Apple, Inc.
A4D990|Samsung Electronics Co.,Ltd
A4DB30|Liteon Technology Corporation
A4DCBE|HUAWEI TECHNOLOGIES CO.,LTD
A4DCD5|Cisco Systems, Inc
A4DD58|HUAWEI TECHNOLOGIES CO.,LTD
A4E11A|Juniper Networks
A4E287|Xiaomi Communications Co Ltd
A4E31B|Nokia
A4E57C|Espressif Inc.
A4E615|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
A4E731|Nokia Corporation
A4E88D|FN-LINK TECHNOLOGY Ltd.
A4E975|Apple, Inc.
A4EA8E|Extreme Networks, Inc.
A4EBD3|Samsung Electronics Co.,Ltd
A4EE57|Seiko Epson Corporation
A4F00F|Espressif Inc.
A4F01F|CANON INC.
A4F1E8|Apple, Inc.
A4F33B|zte corporation
A4F6E6|Apple, Inc.
A4F6E8|Apple, Inc.
A4F841|Apple, Inc.
A4F8FF|Ubiquiti Inc
A4F921|Apple, Inc.
A4F933|Intel Corporate
A4FC14|Apple, Inc.
A4FCA1|Nokia Solutions and Networks GmbH & Co. KG
A4FF95|Nokia
A4FF9F|Xiaomi Communications Co Ltd
A802DB|zte corporation
A8032A|Espressif Inc.
A80600|Samsung Electronics Co.,Ltd
A809B1|Huawei Device Co., Ltd.
A80B6B|Chipsea Technologies (Shenzhen) Corp.
A80BFB|Ruckus Wireless
A80C0D|Cisco Systems, Inc
A80C63|HUAWEI TECHNOLOGIES CO.,LTD
A80CCA|Shenzhen Sundray Technologies company Limited
A80DE1|HUAWEI TECHNOLOGIES CO.,LTD
A81374|Panasonic Corporation AVC Networks Company
A81378|Nokia
A8154D|TP-LINK TECHNOLOGIES CO.,LTD.
A815D6|Shenzhen Meione Technology CO., LTD
A816B2|LG Electronics (Mobile Communications)
A816D0|Samsung Electronics Co.,Ltd
A81AF1|Apple, Inc.
A81D16|AzureWave Technology Inc.
A81E84|Quanta Computer Inc.
A82066|Apple, Inc.
A8213A|Shenzhen Talent Technology Comapny Limited 深圳市泰霖科技有限公司
A821C8|shenzhen phoenix telecom technology Co.,Ltd.
A82316|Nokia
A823FE|LG Electronics
A824B8|Nokia
A82948|TP-Link Systems Inc.
A829DC|TP-Link Systems Inc.
A82BB9|Samsung Electronics Co.,Ltd
A82BCD|HUAWEI TECHNOLOGIES CO.,LTD
A82BD5|Xiaomi Communications Co Ltd
A82BDD|LCFC(Hefei) Electronics Technology co., ltd
A82C3E|Shenzhen Cultraview Digital Technology Co., Ltd
A82C89|Apple, Inc.
A830BC|Samsung Electronics Co.,Ltd
A8346A|Samsung Electronics Co.,Ltd
A83512|Huawei Device Co., Ltd.
A83759|Huawei Device Co., Ltd.
A83B5C|HUAWEI TECHNOLOGIES CO.,LTD
A83CA5|Dell Inc.
A83ED3|HUAWEI TECHNOLOGIES CO.,LTD
A84021|zte corporation
A841F4|AzureWave Technology Inc.
A842A1|TP-Link Systems Inc
A842E3|Espressif Inc.
A84481|Nokia Corporation
A844AA|Fiberhome Telecommunication Technologies Co.,LTD
A84616|HUAWEI TECHNOLOGIES CO.,LTD
A84674|Espressif Inc.
A8469D|Cisco Meraki
A8474A|Hon Hai Precision Ind. Co.,Ltd.
A848FA|Espressif Inc.
A8494D|HUAWEI TECHNOLOGIES CO.,LTD
A84A28|Apple, Inc.
A84B4D|Samsung Electronics Co.,Ltd
A84FB1|Cisco Systems, Inc
A85081|HUAWEI TECHNOLOGIES CO.,LTD
A8515B|Samsung Electronics Co.,Ltd
A851AB|Apple, Inc.
A852D4|Hewlett Packard Enterprise
A8574E|TP-LINK TECHNOLOGIES CO.,LTD.
A857BA|Shenzhen YOUHUA Technology Co., Ltd
A8595F|Intel Corporate
A85AE0|Huawei Device Co., Ltd.
A85B78|Apple, Inc.
A85BB0|Shenzhen Dehoo Technology Co.,Ltd
A85BB7|Apple, Inc.
A85BD1|INVENTEC CORPORATION
A85BF7|Hewlett Packard Enterprise
A85C2C|Apple, Inc.
A85E45|ASUSTek COMPUTER INC.
A85F61|Apple, Inc.
A860B6|Apple, Inc.
A8637D|D-Link International
A864F1|Intel Corporate
A8667F|Apple, Inc.
A86A86|Xiaomi Communications Co Ltd
A86ABB|Sagemcom Broadband SAS
A86B7C|SHENZHEN FENGLIAN TECHNOLOGY CO., LTD.
A86BAD|Hon Hai Precision Ind. Co.,Ltd.
A86DAA|Intel Corporate
A86E4E|Huawei Device Co., Ltd.
A86E84|TP-Link Systems Inc
A8724D|Intel Corporate
A87484|zte corporation
A87650|Samsung Electronics Co.,Ltd
A877E5|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
A87971|HUAWEI TECHNOLOGIES CO.,LTD
A8798D|Samsung Electronics Co.,Ltd
A87B39|Nokia Corporation
A87C01|Samsung Electronics Co.,Ltd
A87C45|HUAWEI TECHNOLOGIES CO.,LTD
A87CF8|Apple, Inc.
A87D12|HUAWEI TECHNOLOGIES CO.,LTD
A87E33|Nokia Danmark A/S
A87EEA|Intel Corporate
A88038|ShenZhen MovingComm Technology Co., Limited
A88055|Tuya Smart Inc.
A8817E|Apple, Inc.
A88195|Samsung Electronics Co.,Ltd
A886DD|Apple, Inc.
A887B3|Samsung Electronics Co.,Ltd
A88808|Apple, Inc.
A88940|Huawei Device Co., Ltd.
A88B28|SHENZHEN DIYANG SMART TECHNOLOGY CO.,LTD.
A88C3E|Microsoft Corporation
A88E24|Apple, Inc.
A88FD9|Apple, Inc.
A8913D|Apple, Inc.
A89162|Sophos Ltd
A8922C|LG Electronics (Mobile Communications)
A89609|FN-LINK TECHNOLOGY Ltd.
A89675|Motorola Mobility LLC, a Lenovo Company
A8968A|Apple, Inc.
A89969|Dell Inc.
A89A8C|zte corporation
A89A93|Sagemcom Broadband SAS
A89AD7|Nokia
A89C6C|Ubiquiti Inc
A89C78|Apple, Inc.
A89CED|Xiaomi Communications Co Ltd
A89D21|Cisco Systems, Inc
A89FBA|Samsung Electronics Co.,Ltd
A8A668|zte corporation
A8A795|Hon Hai Precision Ind. Co.,Ltd.
A8AA7C|Huawei Device Co., Ltd.
A8ABB5|Apple, Inc.
A8B0D1|EFUN Display Technology (Shenzhen) Co., Ltd.
A8B13B|HP Inc.
A8B1D4|Cisco Systems, Inc
A8B271|HUAWEI TECHNOLOGIES CO.,LTD
A8B2DA|FUJITSU LIMITED
A8B456|Cisco Systems, Inc
A8B483|Shenzhen SuperElectron Technology Co.,Ltd.
A8B57C|Roku, Inc
A8B58E|SHENZHEN BILIAN ELECTRONIC CO.，LTD
A8B86E|LG Electronics (Mobile Communications)
A8BA25|Hewlett Packard Enterprise
A8BA69|Samsung Electronics Co.,Ltd
A8BB56|Apple, Inc.
A8BBCF|Apple, Inc.
A8BD27|Hewlett Packard Enterprise
A8BE27|Apple, Inc.
A8C092|Huawei Device Co., Ltd.
A8C252|Huawei Device Co., Ltd.
A8C407|HUAWEI TECHNOLOGIES CO.,LTD
A8C647|Extreme Networks, Inc.
A8C83A|HUAWEI TECHNOLOGIES CO.,LTD
A8CA77|Amazon Technologies Inc.
A8CA7B|HUAWEI TECHNOLOGIES CO.,LTD
A8CA87|ZHEJIANG DAHUA ZHILIAN CO.,LTD
A8CAB9|SAMSUNG ELECTRO MECHANICS CO., LTD.
A8CEE7|Fiberhome Telecommunication Technologies Co.,LTD
A8D081|Huawei Device Co., Ltd.
A8D0E5|Juniper Networks
A8D162|Samsung Electronics Co.,Ltd
A8D4E0|HUAWEI TECHNOLOGIES CO.,LTD
A8DA01|Shenzhen NUOLIJIA Digital Technology Co.,Ltd
A8DB03|SAMSUNG ELECTRO-MECHANICS(THAILAND)
A8DDBC|Tuya Smart Inc.
A8E018|Nokia Corporation
A8E291|AzureWave Technology Inc.
A8E2C3|Shenzhen YOUHUA Technology Co., Ltd
A8E3EE|Sony Interactive Entertainment Inc.
A8E544|HUAWEI TECHNOLOGIES CO.,LTD
A8E5EC|Nokia
A8E621|Amazon Technologies Inc.
A8E705|Fiberhome Telecommunication Technologies Co.,LTD
A8E978|Huawei Device Co., Ltd.
A8EA71|Fiberhome Telecommunication Technologies Co.,LTD
A8EE67|Samsung Electronics Co.,Ltd
A8F059|HUAWEI TECHNOLOGIES CO.,LTD
A8F07C|Huawei Device Co., Ltd.
A8F266|Huawei Device Co., Ltd.
A8F274|Samsung Electronics Co.,Ltd
A8F5AC|HUAWEI TECHNOLOGIES CO.,LTD
A8F5E1|Shenzhen Shokz Co., Ltd.
A8FAD8|Apple, Inc.
A8FB40|Nokia Solutions and Networks GmbH & Co. KG
A8FB45|Google, Inc.
A8FD07|Espressif Inc.
A8FE9D|Apple, Inc.
A8FECE|Fiberhome Telecommunication Technologies Co.,LTD
A8FFBA|HUAWEI TECHNOLOGIES CO.,LTD
AC007A|Apple, Inc.
AC00D0|zte corporation
AC0416|zte corporation
AC05C7|Intel Corporate
AC075F|HUAWEI TECHNOLOGIES CO.,LTD
AC0775|Apple, Inc.
AC0BFB|Espressif Inc.
AC0D1B|LG Electronics (Mobile Communications)
AC1203|Intel Corporate
AC1518|Espressif Inc.
AC15A2|TP-Link Systems Inc
AC15F4|Apple, Inc.
AC1615|Apple, Inc.
AC162D|Hewlett Packard
AC16DE|Intel Corporate
AC1794|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
AC17C8|Cisco Meraki
AC1826|Seiko Epson Corporation
AC198E|Intel Corporate
AC1A3D|Dell Inc.
AC1D06|Apple, Inc.
AC1E92|Samsung Electronics Co.,Ltd
AC1E9E|Xiaomi Communications Co Ltd
AC1EA9|Intelbras
AC1F09|shenzhen RAKwireless technology Co.,Ltd
AC1F74|Apple, Inc.
AC2205|Compal Broadband Networks, Inc.
AC220B|ASUSTek COMPUTER INC.
AC2241|HUAWEI TECHNOLOGIES CO.,LTD
AC233F|Shenzhen Minew Technologies Co., Ltd.
AC2477|Shenzhen Tinno Mobile Technology Corp
AC276E|Espressif Inc.
AC293A|Apple, Inc.
AC2AA1|Cisco Systems, Inc
AC2B6E|Intel Corporate
AC3019|Shenzhen Hailingwei Electronics Co., Ltd.
AC3184|Huawei Device Co., Ltd.
AC319D|Shenzhen TG-NET Botone Technology Co.,Ltd.
AC3328|Huawei Device Co., Ltd.
AC35EE|FN-LINK TECHNOLOGY LIMITED
AC3613|Samsung Electronics Co.,Ltd
AC361B|Hon Hai Precision Industry Co.,LTD
AC3870|Lenovo Mobile Communication Technology Ltd.
AC3A67|Cisco Systems, Inc
AC3A7A|Roku, Inc.
AC3AE2|NVIDIA Corporation
AC3B77|Sagemcom Broadband SAS
AC3C0B|Apple, Inc.
AC3DCB|Intel Corporate
AC3EB1|Google, Inc.
AC416A|Amazon Technologies Inc.
AC4500|Apple, Inc.
AC45B0|Shenzhen Jidao Technology Co Ltd
AC45EF|Intel Corporate
AC471B|Huawei Device Co., Ltd.
AC49DB|Apple, Inc.
AC4A56|Cisco Systems, Inc
AC4A67|Cisco Systems, Inc
AC4BC8|Juniper Networks
AC4DD9|Extreme Networks, Inc.
AC4E2E|Shenzhen JingHanDa Electronics Co.Ltd
AC4E65|Fiberhome Telecommunication Technologies Co.,LTD
AC4E74|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
AC4E91|HUAWEI TECHNOLOGIES CO.,LTD
AC51AB|HUAWEI TECHNOLOGIES CO.,LTD
AC5322|Samsung Electronics Co.,Ltd
AC5A14|Samsung Electronics Co.,Ltd
AC5AF0|LG Electronics
AC5AFC|Intel Corporate
AC5C2C|Apple, Inc.
AC5D5C|FN-LINK TECHNOLOGY LIMITED
AC5E14|HUAWEI TECHNOLOGIES CO.,LTD
AC5F3E|SAMSUNG ELECTRO-MECHANICS(THAILAND)
AC5FEA|OnePlus Technology (Shenzhen) Co., Ltd
AC606F|Nokia Shanghai Bell Co., Ltd.
AC6089|HUAWEI TECHNOLOGIES CO.,LTD
AC6175|HUAWEI TECHNOLOGIES CO.,LTD
AC61EA|Apple, Inc.
AC63BE|Amazon Technologies Inc.
AC6462|zte corporation
AC6490|HUAWEI TECHNOLOGIES CO.,LTD
AC64CF|FN-LINK TECHNOLOGY LIMITED
AC6706|Ruckus Wireless
AC675D|Intel Corporate
AC6784|Google, Inc.
AC67B2|Espressif Inc.
AC69CF|Cisco Meraki
AC6AA3|Shenzhen Kertong Technology Co.,Ltd
AC6C90|Samsung Electronics Co.,Ltd
AC6E1A|SHENZHEN GONGJIN ELECTRONICS CO.,LT
AC712E|Fortinet, Inc.
AC7289|Intel Corporate
AC74B1|Intel Corporate
AC751D|HUAWEI TECHNOLOGIES CO.,LTD
AC7713|Honeywell Safety Products (Shanghai) Co.,Ltd
AC78D1|Juniper Networks
AC7A56|Cisco Systems, Inc
AC7BA1|Intel Corporate
AC7E01|Huawei Device Co., Ltd.
AC7E8A|Cisco Systems, Inc
AC7F3E|Apple, Inc.
AC7F8D|Extreme Networks, Inc.
AC800A|Sony Corporation
AC80AE|Fiberhome Telecommunication Technologies Co.,LTD
AC80FB|Samsung Electronics Co.,Ltd
AC81F3|Nokia Corporation
AC8247|Intel Corporate
AC82F0|Apple, Inc.
AC8317|Shenzhen Furtunetel Communication Co., Ltd
AC84C6|TP-LINK TECHNOLOGIES CO.,LTD.
AC84C9|Sagemcom Broadband SAS
AC853D|HUAWEI TECHNOLOGIES CO.,LTD
AC86A3|Apple, Inc.
AC87A3|Apple, Inc.
AC8866|Shenzhen Skyworth Digital Technology CO., Ltd
AC88FD|Apple, Inc.
AC8995|AzureWave Technology Inc.
AC8AC7|HUAWEI TECHNOLOGIES CO.,LTD
AC8BA9|Ubiquiti Inc
AC8C46|Beijing Xiaomi Mobile Software Co., Ltd
AC8D34|HUAWEI TECHNOLOGIES CO.,LTD
AC8EBD|Microsoft Corporation
AC8FA9|Nokia Solutions and Networks GmbH & Co. KG
AC8FF8|Nokia
AC9073|HUAWEI TECHNOLOGIES CO.,LTD
AC9085|Apple, Inc.
AC91A1|Dell Inc.
AC9232|HUAWEI TECHNOLOGIES CO.,LTD
AC932F|Nokia Corporation
AC936A|Huawei Device Co., Ltd.
AC9738|Apple, Inc.
AC9929|HUAWEI TECHNOLOGIES CO.,LTD
AC9B0A|Sony Corporation
AC9E17|ASUSTek COMPUTER INC.
ACA016|Cisco Systems, Inc
ACA09D|Juniper Networks
ACA213|SHENZHEN BILIAN ELECTRONIC CO.，LTD
ACA26A|Espressif Systems (Singapore) Pte. Ltd
ACA31E|Hewlett Packard Enterprise
ACA46E|SHENZHEN GONGJIN ELECTRONICS CO.,LT
ACA704|Espressif Inc.
ACA7F1|TP-Link Systems Inc.
ACA88E|SHARP Corporation
ACAD4B|zte corporation
ACAE19|Roku, Inc
ACAFB9|Samsung Electronics Co.,Ltd
ACB1EE|SHENZHEN FENDA TECHNOLOGY CO., LTD
ACB3B5|HUAWEI TECHNOLOGIES CO.,LTD
ACB480|Dell Inc.
ACB57D|Liteon Technology Corporation
ACB92F|Hangzhou Hikvision Digital Technology Co.,Ltd.
ACBC32|Apple, Inc.
ACBCB5|Apple, Inc.
ACBCD9|Cisco Systems, Inc
ACBD70|Huawei Device Co., Ltd.
ACBDF7|Cisco Meraki
ACC048|OnePlus Technology (Shenzhen) Co., Ltd
ACC1EE|Xiaomi Communications Co Ltd
ACC25D|Fiberhome Telecommunication Technologies Co.,LTD
ACC33A|Samsung Electronics Co.,Ltd
ACC3E5|Cisco Meraki
ACC4A9|Fiberhome Telecommunication Technologies Co.,LTD
ACC5B4|HUAWEI TECHNOLOGIES CO.,LTD
ACC906|Apple, Inc.
ACCB36|Fiberhome Telecommunication Technologies Co.,LTD
ACCB51|Hangzhou Hikvision Digital Technology Co.,Ltd.
ACCC8E|Axis Communications AB
ACCCFC|Amazon Technologies Inc.
ACCF5C|Apple, Inc.
ACCF85|HUAWEI TECHNOLOGIES CO.,LTD
ACD074|Espressif Inc.
ACD1B8|Hon Hai Precision Ind. Co.,Ltd.
ACD31D|Cisco Meraki
ACD400|Cisco Systems, Inc
ACD618|OnePlus Technology (Shenzhen) Co., Ltd
ACD75B|Sagemcom Broadband SAS
ACDBDA|Shenzhen Geniatech Inc, Ltd
ACDCCA|HUAWEI TECHNOLOGIES CO.,LTD
ACDE01|Ruckus Wireless
ACDFA1|Apple, Inc.
ACE010|Liteon Technology Corporation
ACE011|HUAWEI TECHNOLOGIES CO.,LTD
ACE215|HUAWEI TECHNOLOGIES CO.,LTD
ACE2D3|Hewlett Packard
ACE342|HUAWEI TECHNOLOGIES CO.,LTD
ACE403|Shenzhen Visteng Technology CO.,LTD
ACE4B5|Apple, Inc.
ACE4D8|Xiaomi Communications Co Ltd
ACE64B|Shenzhen Baojia Battery Technology Co., Ltd.
ACE6BB|Google, Inc.
ACE6FB|Apple, Inc.
ACE87B|HUAWEI TECHNOLOGIES CO.,LTD
ACEAEA|HUAWEI TECHNOLOGIES CO.,LTD
ACEBE6|Espressif Inc.
ACED32|Extreme Networks, Inc.
ACED5C|Intel Corporate
ACEE64|Shenzhen SuperElectron Technology Co.,Ltd.
ACEE9E|Samsung Electronics Co.,Ltd
ACF1DF|D-Link International
ACF2C5|Cisco Systems, Inc
ACF466|HP Inc.
ACF5E6|Cisco Systems, Inc
ACF6F7|LG Electronics (Mobile Communications)
ACF7F3|Xiaomi Communications Co Ltd
ACF878|Tuya Smart Inc.
ACF970|HUAWEI TECHNOLOGIES CO.,LTD
ACFBC2|Shenzhen Skyworth Digital Technology CO., Ltd
ACFC82|Shenzhen Sundray Technologies company Limited
ACFDCE|Intel Corporate
ACFDEC|Apple, Inc.
ACFF6B|HUAWEI TECHNOLOGIES CO.,LTD
B000B4|Cisco Systems, Inc
B00594|Liteon Technology Corporation
B00875|HUAWEI TECHNOLOGIES CO.,LTD
B00AD5|zte corporation
B00B22|Huawei Device Co., Ltd.
B00CD1|Hewlett Packard
B01041|Hon Hai Precision Ind. Co.,Ltd.
B0104B|Fiberhome Telecommunication Technologies Co.,LTD
B01656|HUAWEI TECHNOLOGIES CO.,LTD
B01831|Apple, Inc.
B01921|TP-Link Systems Inc
B019C6|Apple, Inc.
B01BFC|Cisco Systems, Inc
B01C0C|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
B01F8C|Hewlett Packard Enterprise
B01FF4|Sagemcom Broadband SAS
B0216F|HUAWEI TECHNOLOGIES CO.,LTD
B0227A|HP Inc.
B02347|Shenzhen Giant Microelectronics Company Limited
B02491|Huawei Device Co., Ltd.
B025AA|AIstone Global Limited
B02628|Broadcom Limited
B02680|Cisco Systems, Inc
B027CF|Extreme Networks, Inc.
B02A43|Google, Inc.
B02B64|Cisco Systems, Inc
B02EE0|Huawei Device Co., Ltd.
B033A6|Juniper Networks
B03495|Apple, Inc.
B034FB|ShenZhen Microtest Automation Co.,Ltd
B0358D|Nokia Corporation
B0359F|Intel Corporate
B035B5|Apple, Inc.
B03795|LG Electronics
B03956|NETGEAR
B03ACE|Huawei Device Co., Ltd.
B03CDC|Intel Corporate
B03DBF|shenzhen ceita communications technology co.,ltd
B03DC2|Wasp artificial intelligence(Shenzhen) Co.,ltd
B03F64|Apple, Inc.
B03FD3|Espressif Inc.
B0416F|Shenzhen Maxtang Computer Co.,Ltd
B042B7|HUAWEI TECHNOLOGIES CO.,LTD
B04502|Huawei Device Co., Ltd.
B047BF|Samsung Electronics Co.,Ltd
B047E9|Intel Corporate
B0481A|Apple, Inc.
B0487A|TP-LINK TECHNOLOGIES CO.,LTD.
B04A6A|Samsung Electronics Co.,Ltd
B04AB4|Motorola Mobility LLC, a Lenovo Company
B04E26|TP-LINK TECHNOLOGIES CO.,LTD.
B04F13|Dell Inc.
B04FC3|Shenzhen NVC Cloud Technology Co., Ltd.
B050BC|SHENZHEN BASICOM ELECTRONIC CO.,LTD.
B05216|Hon Hai Precision Ind. Co.,Ltd.
B05476|Samsung Electronics Co.,Ltd
B05508|HUAWEI TECHNOLOGIES CO.,LTD
B05947|Shenzhen Qihu Intelligent Technology Company Limited
B05A7B|Huawei Device Co., Ltd.
B05ADA|Hewlett Packard
B05B67|HUAWEI TECHNOLOGIES CO.,LTD
B05B99|Sagemcom Broadband SAS
B05C16|Fiberhome Telecommunication Technologies Co.,LTD
B05CDA|HP Inc.
B05CE5|Nokia Corporation
B06088|Intel Corporate
B061A9|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
B064E0|Samsung Electronics Co.,Ltd
B065BD|Apple, Inc.
B067B5|Apple, Inc.
B06A41|Google, Inc.
B06EBF|ASUSTek COMPUTER INC.
B06FE0|Samsung Electronics Co.,Ltd
B0700D|Nokia
B0702D|Apple, Inc.
B07219|Apple, Inc.
B0735D|Huawei Device Co., Ltd.
B0739C|Amazon Technologies Inc.
B0754D|Nokia
B075D5|zte corporation
B0761B|HUAWEI TECHNOLOGIES CO.,LTD
B07994|Motorola Mobility LLC, a Lenovo Company
B07ADF|HUAWEI TECHNOLOGIES CO.,LTD
B07B25|Dell Inc.
B07C51|Ruckus Wireless
B07C8E|Brother Industries, LTD.
B07D47|Cisco Systems, Inc
B07D64|Intel Corporate
B07FB9|NETGEAR
B08184|Espressif Inc.
B082E2|ASUSTek COMPUTER INC.
B083FE|Dell Inc.
B08900|HUAWEI TECHNOLOGIES CO.,LTD
B08B92|zte corporation
B08BA8|Amazon Technologies Inc.
B08BCF|Cisco Systems, Inc
B08BD0|Cisco Systems, Inc
B08C75|Apple, Inc.
B08CB3|FN-LINK TECHNOLOGY Ltd.
B08D57|Cisco Systems, Inc
B0907E|Cisco Systems, Inc
B090D4|Shenzhen Hoin Internet Technology Co., Ltd
B09200|Apple, Inc.
B0924A|Sagemcom Broadband SAS
B09575|TP-LINK TECHNOLOGIES CO.,LTD.
B0958E|TP-LINK TECHNOLOGIES CO.,LTD.
B09738|Shenzhen Skyworth Digital Technology CO., Ltd
B0982B|Sagemcom Broadband SAS
B098BC|Huawei Device Co., Ltd.
B09928|FUJITSU LIMITED
B0995A|HUAWEI TECHNOLOGIES CO.,LTD
B099D7|Samsung Electronics Co.,Ltd
B09C18|Shenzhen Taichi Technology Limited
B09C63|Xiaomi Communications Co Ltd
B09CB2|Google, Inc.
B09FBA|Apple, Inc.
B0A2E7|Shenzhen TINNO Mobile Technology Corp.
B0A460|Intel Corporate
B0A4F0|HUAWEI TECHNOLOGIES CO.,LTD
B0A5B3|Hewlett Packard Enterprise
B0A604|Espressif Inc.
B0A651|Cisco Systems, Inc
B0A732|Espressif Inc.
B0A737|Roku, Inc.
B0A7B9|TP-Link Systems Inc
B0A7D2|Fiberhome Telecommunication Technologies Co.,LTD
B0A86E|Juniper Networks
B0AA77|Cisco Systems, Inc
B0ACD2|zte corporation
B0ACFA|FUJITSU LIMITED
B0ADAA|Avaya Inc
B0AFF7|Shenzhen Yipingfang Network Technology Co., Ltd.
B0B0A1|Hon Hai Precision Industry Co.,LTD
B0B194|zte corporation
B0B21C|Espressif Inc.
B0B28F|Sagemcom Broadband SAS
B0B2DC|Zyxel Communications Corporation
B0B369|Shenzhen SDMC Technology CO.,Ltd.
B0B867|Hewlett Packard Enterprise
B0B98A|NETGEAR
B0BBA9|Apple, Inc.
B0BBE5|Sagemcom Broadband SAS
B0BE76|TP-LINK TECHNOLOGIES CO.,LTD.
B0BE83|Apple, Inc.
B0C19E|zte corporation
B0C2C7|Motorola Mobility LLC, a Lenovo Company
B0C38E|Huawei Device Co., Ltd.
B0C4E7|Samsung Electronics Co.,Ltd
B0C53C|Cisco Systems, Inc
B0C554|D-Link International
B0C559|Samsung Electronics Co.,Ltd
B0C61C|HUAWEI TECHNOLOGIES CO.,LTD
B0C69A|Juniper Networks
B0C787|HUAWEI TECHNOLOGIES CO.,LTD
B0CA68|Apple, Inc.
B0CAE7|Huawei Device Co., Ltd.
B0CBD8|Espressif Inc.
B0CCFE|Huawei Device Co., Ltd.
B0CFCB|Amazon Technologies Inc.
B0D09C|Samsung Electronics Co.,Ltd
B0D1D6|Nokia Shanghai Bell Co., Ltd.
B0D568|Shenzhen Cultraview Digital Technology Co., Ltd
B0D576|Apple, Inc.
B0D59D|Shenzhen Zowee Technology Co., Ltd
B0D5FB|Google, Inc.
B0D77E|HUAWEI TECHNOLOGIES CO.,LTD
B0D888|Panasonic Automotive Systems Co.,Ltd
B0DCEF|Intel Corporate
B0DE28|Apple, Inc.
B0DE31|Samsung Electronics Co.,Ltd
B0DF3A|Samsung Electronics Co.,Ltd
B0DFC1|Tenda Technology Co.,Ltd.Dongguan branch
B0E17E|HUAWEI TECHNOLOGIES CO.,LTD
B0E235|Xiaomi Communications Co Ltd
B0E2E5|Fiberhome Telecommunication Technologies Co.,LTD
B0E45C|Samsung Electronics Co.,Ltd
B0E4D5|Google, Inc.
B0E5ED|HUAWEI TECHNOLOGIES CO.,LTD
B0E5EF|Apple, Inc.
B0E5F9|Apple, Inc.
B0E892|Seiko Epson Corporation
B0E9FE|Woan Technology (Shenzhen) Co., Ltd.
B0EA19|TPV Audio and Visual Technology (Shenzhen) Co.,Ltd.
B0EB57|HUAWEI TECHNOLOGIES CO.,LTD
B0EB7F|Juniper Networks
B0EC69|Apple, Inc.
B0EC71|Samsung Electronics Co.,Ltd
B0ECDD|HUAWEI TECHNOLOGIES CO.,LTD
B0EE45|AzureWave Technology Inc.
B0EE7B|Roku, Inc
B0F1D8|Apple, Inc.
B0F2F6|Samsung Electronics Co.,Ltd
B0F7C4|Amazon Technologies Inc.
B0FA8B|Huawei Device Co., Ltd.
B0FAEB|Cisco Systems, Inc
B0FBDD|Shenzhen SuperElectron Technology Co.,Ltd.
B0FC0D|Amazon Technologies Inc.
B0FC4B|Shenzhen Phaten Tech. LTD
B0FC88|Sagemcom Broadband SAS
B0FEE5|Huawei Device Co., Ltd.
B0FF0D|Hangzhou Hikvision Digital Technology Co.,Ltd.
B40016|INGENICO TERMINALS SAS
B40216|Cisco Systems, Inc
B40421|zte corporation
B405A1|Xiaomi Communications Co Ltd
B407F9|SAMSUNG ELECTRO MECHANICS CO., LTD.
B40931|HUAWEI TECHNOLOGIES CO.,LTD
B40AD8|Sony Interactive Entertainment Inc.
B40B1D|Samsung Electronics Co.,Ltd
B40C25|Palo Alto Networks
B40EDE|Intel Corporate
B40F3B|Tenda Technology Co.,Ltd.Dongguan branch
B4107A|Amazon Technologies Inc.
B41324|Google, Inc.
B41489|Cisco Systems, Inc
B414E6|HUAWEI TECHNOLOGIES CO.,LTD
B41513|HUAWEI TECHNOLOGIES CO.,LTD
B41584|Samsung Electronics Co.,Ltd
B41678|Juniper Networks
B418D1|Apple, Inc.
B41974|Apple, Inc.
B41A1D|Samsung Electronics Co.,Ltd
B41BB0|Apple, Inc.
B41C30|zte corporation
B41D2B|Shenzhen YOUHUA Technology Co., Ltd
B41D62|Nokia Shanghai Bell Co., Ltd.
B41DC4|HUAWEI TECHNOLOGIES CO.,LTD
B41F4D|Sony Interactive Entertainment Inc.
B42200|Brother Industries, LTD.
B423A2|Google, Inc.
B42802|Intel Corporate
B4293D|Shenzhen Urovo Technology Co.,Ltd.
B42BB9|HUAWEI TECHNOLOGIES CO.,LTD
B42D56|Extreme Networks, Inc.
B42E99|GIGA-BYTE TECHNOLOGY CO.,LTD.
B43052|HUAWEI TECHNOLOGIES CO.,LTD
B437D8|D-Link (Shanghai) Limited Corp.
B43836|HUAWEI TECHNOLOGIES CO.,LTD
B43939|Shenzhen TINNO Mobile Technology Corp.
B4394C|HUAWEI TECHNOLOGIES CO.,LTD
B43A28|Samsung Electronics Co.,Ltd
B43A45|Espressif Inc.
B43AE2|HUAWEI TECHNOLOGIES CO.,LTD
B43B52|Sagemcom Broadband SAS
B440A4|Apple, Inc.
B440DC|Samsung Electronics Co.,Ltd
B4417A|SHENZHEN GONGJIN ELECTRONICS CO.,LT
B44326|HUAWEI TECHNOLOGIES CO.,LTD
B44389|HUAWEI TECHNOLOGIES CO.,LTD
B44506|Dell Inc.
B4475E|Avaya Inc
B44BD2|Apple, Inc.
B44C3B|Zhejiang Dahua Technology Co., Ltd.
B44C90|Cisco Systems, Inc
B4527D|Sony Corporation
B4527E|Sony Corporation
B454F2|Huawei Device Co., Ltd.
B45575|Apple, Inc.
B4565D|Chipsea Technologies (Shenzhen) Corp.
B456E3|Apple, Inc.
B45976|Apple, Inc.
B45BD1|TP-Link Systems Inc.
B45D50|Hewlett Packard Enterprise
B45F84|zte corporation
B4608C|Fiberhome Telecommunication Technologies Co.,LTD
B460ED|Beijing Xiaomi Mobile Software Co., Ltd
B46142|HUAWEI TECHNOLOGIES CO.,LTD
B46293|Samsung Electronics Co.,Ltd
B4636F|Nokia Solutions and Networks GmbH & Co. KG
B4673F|Shenzhen Shokz Co., Ltd.
B46921|Intel Corporate
B46BFC|Intel Corporate
B46C47|Panasonic Appliances Company
B46D83|Intel Corporate
B46DC2|SHENZHEN BILIAN ELECTRONIC CO.，LTD
B46E08|HUAWEI TECHNOLOGIES CO.,LTD
B47064|Samsung Electronics Co.,Ltd
B472D4|zte corporation
B47443|Samsung Electronics Co.,Ltd
B476A4|Huawei Device Co., Ltd.
B47748|Shenzhen Neoway Technology Co.,Ltd.
B479A7|SAMSUNG ELECTRO-MECHANICS(THAILAND)
B479C8|Ruckus Wireless
B47AF1|Hewlett Packard Enterprise
B47B1A|HUAWEI TECHNOLOGIES CO.,LTD
B47C29|Shenzhen Guzidi Technology Co.,Ltd
B47C9C|Amazon Technologies Inc.
B47CA6|zte corporation
B47E9F|Xiaomi Communications Co Ltd
B48107|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
B48351|Intel Corporate
B485E1|Apple, Inc.
B48655|HUAWEI TECHNOLOGIES CO.,LTD
B48901|HUAWEI TECHNOLOGIES CO.,LTD
B48A0A|Espressif Inc.
B48A5F|Juniper Networks
B48B19|Apple, Inc.
B48C9D|AzureWave Technology Inc.
B49107|HUAWEI TECHNOLOGIES CO.,LTD
B49691|Intel Corporate
B496A5|Apple, Inc.
B49842|zte corporation
B499BA|Hewlett Packard
B49A95|Shenzhen Boomtech Industrial Corporation
B49CDF|Apple, Inc.
B49D02|Samsung Electronics Co.,Ltd
B49DFD|Shenzhen SDMC Technology CO.,Ltd.
B49EE6|SHENZHEN TECHNOLOGY CO LTD
B49F4D|Fiberhome Telecommunication Technologies Co.,LTD
B4A10A|Huawei Device Co., Ltd.
B4A25C|Cambium Networks Limited
B4A382|Hangzhou Hikvision Digital Technology Co.,Ltd.
B4A3BD|Extreme Networks, Inc.
B4A4E3|Cisco Systems, Inc
B4A64A|Espressif Inc.
B4A828|Shenzhen Concox Information Technology Co., Ltd
B4A898|Huawei Device Co., Ltd.
B4A8B9|Cisco Systems, Inc
B4A95A|Avaya Inc
B4A9FC|Quanta Computer Inc.
B4A9FE|GHIA Technology (Shenzhen) LTD
B4AE2B|Microsoft
B4AEC1|Apple, Inc.
B4B017|Avaya Inc
B4B024|TP-Link Systems Inc
B4B055|HUAWEI TECHNOLOGIES CO.,LTD
B4B291|LG Electronics
B4B2E9|Fortinet, Inc.
B4B362|zte corporation
B4B384|ShenZhen Figigantic Electronic Co.,Ltd
B4B52F|Hewlett Packard
B4B676|Intel Corporate
B4B686|Hewlett Packard
B4B742|Amazon Technologies Inc.
B4BFE9|Espressif Inc.
B4BFF6|Samsung Electronics Co.,Ltd
B4C0C3|TP-Link Systems Inc.
B4C0F5|Shenzhen TINNO Mobile Technology Corp.
B4C2F7|Huawei Device Co., Ltd.
B4C3D9|HUAWEI TECHNOLOGIES CO.,LTD
B4C4FC|Xiaomi Communications Co Ltd
B4C799|Extreme Networks, Inc.
B4CADD|Cisco Systems, Inc
B4CD27|HUAWEI TECHNOLOGIES CO.,LTD
B4CE40|Samsung Electronics Co.,Ltd
B4CFDB|Shenzhen Jiuzhou Electric Co.,LTD
B4D1F6|HUAWEI TECHNOLOGIES CO.,LTD
B4D5BD|Intel Corporate
B4D5E5|Samsung Electronics Co.,Ltd
B4DE31|Cisco Systems, Inc
B4DEDF|zte corporation
B4DF91|Cisco Meraki
B4E10F|Dell Inc.
B4E1C4|Microsoft Mobile Oy
B4E25B|HP Inc.
B4E265|Shenzhen SDMC Technology CO.,Ltd.
B4E3D0|LG Electronics
B4E454|Amazon Technologies Inc.
B4E53E|Ruckus Wireless
B4E5C5|Huawei Device Co., Ltd.
B4E62D|Espressif Inc.
B4E9B0|Cisco Systems, Inc
B4E9B8|Dell Inc.
B4EE25|Shenzhen Belon Technology CO.,LTD
B4EF39|Samsung Electronics Co.,Ltd
B4F0AB|Apple, Inc.
B4F18C|Huawei Device Co., Ltd.
B4F1DA|LG Electronics (Mobile Communications)
B4F267|Compal Broadband Networks, Inc.
B4F49B|Huawei Device Co., Ltd.
B4F58E|HUAWEI TECHNOLOGIES CO.,LTD
B4F61C|Apple, Inc.
B4F7A1|LG Electronics (Mobile Communications)
B4F95D|Juniper Networks
B4FA48|Apple, Inc.
B4FBE4|Ubiquiti Inc
B4FBF9|HUAWEI TECHNOLOGIES CO.,LTD
B4FF98|HUAWEI TECHNOLOGIES CO.,LTD
B8005B|Huawei Device Co., Ltd.
B8011F|Apple, Inc.
B80305|Intel Corporate
B80533|Apple, Inc.
B805AB|zte corporation
B8060D|Tuya Smart Inc.
B80756|Cisco Meraki
B808CF|Intel Corporate
B808D7|HUAWEI TECHNOLOGIES CO.,LTD
B8098A|Apple, Inc.
B80B9A|HUAWEI TECHNOLOGIES CO.,LTD
B80E1D|PAX Computer Technology(Shenzhen) Ltd.
B8114B|Cisco Systems, Inc
B8144D|Apple, Inc.
B8145C|Huawei Device Co., Ltd.
B81743|shenzhen worldelite electronics co., LTD
B817C2|Apple, Inc.
B81904|Nokia Shanghai Bell Co., Ltd.
B81D1F|HUAWEI TECHNOLOGIES CO.,LTD
B81DAA|LG Electronics (Mobile Communications)
B81E0B|Extreme Networks, Inc.
B81E9E|HUAWEI TECHNOLOGIES CO.,LTD
B81EA4|Liteon Technology Corporation
B81F3F|Espressif Inc.
B8208E|Panasonic Connect Co., Ltd.
B8211C|Apple, Inc.
B8220C|Apple, Inc.
B827C5|Huawei Device Co., Ltd.
B827EB|Raspberry Pi Foundation
B82A72|Dell Inc.
B82AA9|Apple, Inc.
B82B68|Huawei Device Co., Ltd.
B831B5|Microsoft Corporation
B83446|Motorola Mobility LLC, a Lenovo Company
B8374A|Apple, Inc.
B8374B|Hewlett Packard Enterprise
B837B2|Hewlett Packard Enterprise
B83861|Cisco Systems, Inc
B83865|Hewlett Packard Enterprise
B83A08|Tenda Technology Co.,Ltd.Dongguan branch
B83A5A|Hewlett Packard Enterprise
B83BCC|Xiaomi Communications Co Ltd
B83C20|Huawei Device Co., Ltd.
B83C28|Apple, Inc.
B83D4E|Shenzhen Cultraview Digital Technology Co.,Ltd Shanghai Branch
B83E59|Roku, Inc.
B841A4|Apple, Inc.
B844D9|Apple, Inc.
B845EB|Apple, Inc.
B8496D|Apple, Inc.
B84D43|HUNAN FN-LINK TECHNOLOGY LIMITED
B84FA7|Apple, Inc.
B84FD5|Microsoft Corporation
B85001|Extreme Networks, Inc.
B850D8|Beijing Xiaomi Mobile Software Co., Ltd
B851A9|Nokia
B85213|zte corporation
B852E0|Beijing Xiaomi Electronics Co.,Ltd
B85384|Xiaomi Communications Co Ltd
B853AC|Apple, Inc.
B85510|Zioncom Electronics (Shenzhen) Ltd.
B85600|HUAWEI TECHNOLOGIES CO.,LTD
B857D6|Cisco Systems, Inc
B857D8|Samsung Electronics Co.,Ltd
B85A73|Samsung Electronics Co.,Ltd
B85C5C|Microsoft Corporation
B85D0A|Apple, Inc.
B85DC3|HUAWEI TECHNOLOGIES CO.,LTD
B85E7B|Samsung Electronics Co.,Ltd
B85F98|Amazon Technologies Inc.
B85FB0|HUAWEI TECHNOLOGIES CO.,LTD
B861FC|Juniper Networks
B8621F|Cisco Systems, Inc
B8634D|Apple, Inc.
B86685|Sagemcom Broadband SAS
B869F4|Routerboard.com
B86AF1|Sagemcom Broadband SAS
B86B23|Toshiba
B86CE0|Hewlett Packard Enterprise
B86CE8|Samsung Electronics Co.,Ltd
B87029|Shenzhen Ruiyuanchuangxin Technology Co.,Ltd.
B870F4|COMPAL INFORMATION (KUNSHAN) CO., LTD.
B8752E|Huawei Device Co., Ltd.
B8763F|Hon Hai Precision Ind. Co.,Ltd.
B8782E|Apple, Inc.
B87B4D|Espressif Inc.
B87BC5|Apple, Inc.
B87BD4|Google, Inc.
B87CD0|Huawei Device Co., Ltd.
B87CF2|Extreme Networks, Inc.
B87E39|Motorola Mobility LLC, a Lenovo Company
B87E40|Huawei Device Co., Ltd.
B87EE5|Intelbras
B88035|Shenzhen Qihu Intelligent Technology Company Limited
B88198|Intel Corporate
B881FA|Apple, Inc.
B88268|SHENZHEN HOPESTAR TECHNOLOGY CO.,LTD.
B88303|Hewlett Packard Enterprise
B88411|Shenzhen Shokz Co., Ltd.
B8857B|HUAWEI TECHNOLOGIES CO.,LTD
B88584|Dell Inc.
B88687|Liteon Technology Corporation
B88788|HP Inc.
B888E3|COMPAL INFORMATION (KUNSHAN) CO., LTD.
B88A60|Intel Corporate
B88C2B|Sagemcom Broadband SAS
B88D12|Apple, Inc.
B88E82|Huawei Device Co., Ltd.
B88EB0|Shenzhen Skyworth Digital Technology CO., Ltd
B89047|Apple, Inc.
B89436|HUAWEI TECHNOLOGIES CO.,LTD
B894E7|Xiaomi Communications Co Ltd
B8977A|Nokia Solutions and Networks GmbH & Co. KG
B898AD|Motorola Mobility LLC, a Lenovo Company
B898F7|Gionee Communication Equipment Co,Ltd.ShenZhen
B899AE|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
B89A2A|Intel Corporate
B89FCC|HUAWEI TECHNOLOGIES CO.,LTD
B8A0B8|Samsung Electronics Co.,Ltd
B8A175|Roku, Inc.
B8A25D|Motorola Mobility LLC, a Lenovo Company
B8A377|Cisco Systems, Inc
B8A386|D-Link International
B8A44F|Axis Communications AB
B8A825|Samsung Electronics Co.,Ltd
B8AB61|Cisco Meraki
B8AC6F|Dell Inc.
B8AF67|Hewlett Packard
B8B2F8|Apple, Inc.
B8B409|Samsung Electronics Co.,Ltd
B8B42E|Gionee Communication Equipment Co,Ltd.ShenZhen
B8B4C9|Cisco Meraki
B8B81E|Intel Corporate
B8B94E|Shenzhen iBaby Labs, Inc.
B8BA66|Microsoft Corporation
B8BB11|Espressif Systems (Singapore) Pte. Ltd
B8BBAF|Samsung Electronics Co.,Ltd
B8BC1B|HUAWEI TECHNOLOGIES CO.,LTD
B8BC5B|Samsung Electronics Co.,Ltd
B8BEBF|Cisco Systems, Inc
B8BF83|Intel Corporate
B8C111|Apple, Inc.
B8C253|Juniper Networks
B8C385|HUAWEI TECHNOLOGIES CO.,LTD
B8C68E|Samsung Electronics Co.,Ltd
B8C716|Fiberhome Telecommunication Technologies Co.,LTD
B8C75D|Apple, Inc.
B8C924|Cisco Systems, Inc
B8CA3A|Dell Inc.
B8CB29|Dell Inc.
B8CC38|Shenzhen Yinwang Intelligent Technologies Co., Ltd.
B8CC5F|Shenzhen iComm Semiconductor CO.,LTD
B8CD58|Shenzhen SuperElectron Technology Co.,Ltd.
B8CEED|Broadcom
B8D4BC|zte corporation
B8D4C3|HUAWEI TECHNOLOGIES CO.,LTD
B8D4E7|Hewlett Packard Enterprise
B8D526|Zyxel Communications Corporation
B8D5AD|Nokia
B8D61A|Espressif Inc.
B8D6F6|HUAWEI TECHNOLOGIES CO.,LTD
B8D94D|Sagemcom Broadband SAS
B8D9CE|Samsung Electronics Co.,Ltd
B8DAE8|Huawei Device Co., Ltd.
B8DB38|Google, Inc.
B8DC28|Extreme Networks, Inc.
B8DD71|zte corporation
B8DFD4|Fiberhome Telecommunication Technologies Co.,LTD
B8E28C|MOTOROLA SOLUTIONS MALAYSIA SDN. BHD.
B8E3B1|HUAWEI TECHNOLOGIES CO.,LTD
B8E60C|Apple, Inc.
B8E856|Apple, Inc.
B8E937|Sonos, Inc.
B8EA98|Xiaomi Communications Co Ltd
B8ECA3|Zyxel Communications Corporation
B8EE0E|Sagemcom Broadband SAS
B8EE65|Liteon Technology Corporation
B8EF8B|SHENZHEN CANNICE TECHNOLOGY CO.,LTD
B8F009|Espressif Inc.
B8F015|Juniper Networks
B8F0B9|zte corporation
B8F12A|Apple, Inc.
B8F4A4|Google, Inc.
B8F653|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
B8F6B1|Apple, Inc.
B8F774|Fiberhome Telecommunication Technologies Co.,LTD
B8F775|Intel Corporate
B8F862|Espressif Inc.
B8F883|TP-LINK TECHNOLOGIES CO.,LTD.
B8F934|Sony Corporation
B8FBB3|TP-Link Systems Inc.
B8FE90|Cisco Systems, Inc
B8FE96|Amazon Technologies Inc.
B8FF61|Apple, Inc.
BC0004|Fiberhome Telecommunication Technologies Co.,LTD
BC0358|Intel Corporate
BC071D|TP-Link Systems Inc.
BC091B|Intel Corporate
BC0963|Apple, Inc.
BC0EAB|Samsung Electronics Co.,Ltd
BC0F64|Intel Corporate
BC0F9A|D-Link International
BC0FF3|HP Inc.
BC0FFE|Juniper Networks
BC107B|Samsung Electronics Co.,Ltd
BC122F|LCFC(Hefei) Electronics Technology co., ltd
BC13A8|Shenzhen YOUHUA Technology Co., Ltd
BC1485|Samsung Electronics Co.,Ltd
BC1541|Nokia
BC1665|Cisco Systems, Inc
BC1695|zte corporation
BC16F5|Cisco Systems, Inc
BC17B8|Intel Corporate
BC1827|Apple, Inc.
BC1896|HUAWEI TECHNOLOGIES CO.,LTD
BC1926|Espressif Inc.
BC1AE4|Huawei Device Co., Ltd.
BC1D89|Motorola Mobility LLC, a Lenovo Company
BC1E85|HUAWEI TECHNOLOGIES CO.,LTD
BC20A4|Samsung Electronics Co.,Ltd
BC2228|D-Link International
BC25E0|HUAWEI TECHNOLOGIES CO.,LTD
BC26C7|Cisco Systems, Inc
BC277A|Samsung Electronics Co.,Ltd
BC2978|Prama Hikvision India Private Limited
BC2CE6|Cisco Systems, Inc
BC2EC3|Shenzhen Tianruixiang Communication Equipment Co.,Ltd
BC2EF6|Huawei Device Co., Ltd.
BC305B|Dell Inc.
BC325F|Zhejiang Dahua Technology Co., Ltd.
BC32B2|Samsung Electronics Co.,Ltd
BC3329|Sony Interactive Entertainment Inc.
BC3340|Cisco Meraki
BC33DB|Sagemcom Broadband SAS
BC34D6|Extreme Networks, Inc.
BC351E|Tuya Smart Inc.
BC36F7|HUAWEI TECHNOLOGIES CO.,LTD
BC37D3|Apple, Inc.
BC3898|Intel Corporate
BC3BAF|Apple, Inc.
BC3D85|HUAWEI TECHNOLOGIES CO.,LTD
BC3E0B|Panasonic Connect Co., Ltd.
BC3F8F|HUAWEI TECHNOLOGIES CO.,LTD
BC4101|Shenzhen TINNO Mobile Technology Corp.
BC41A0|zte corporation
BC4434|Shenzhen TINNO Mobile Technology Corp.
BC4486|Samsung Electronics Co.,Ltd
BC4529|zte corporation
BC455B|Samsung Electronics Co.,Ltd
BC458C|Shenzhen Topwise Communication Co.,Ltd
BC4632|Fiberhome Telecommunication Technologies Co.,LTD
BC4699|TP-LINK TECHNOLOGIES CO.,LTD.
BC4760|Samsung Electronics Co.,Ltd
BC49B2|SHENZHEN ALONG COMMUNICATION TECH CO., LTD
BC4A56|Cisco Systems, Inc
BC4C78|HUAWEI TECHNOLOGIES CO.,LTD
BC4CA0|HUAWEI TECHNOLOGIES CO.,LTD
BC4CC4|Apple, Inc.
BC4F2D|Apple, Inc.
BC515F|Nokia Solutions and Networks India Private Limited
BC5274|Samsung Electronics Co.,Ltd
BC52B4|Nokia
BC52B7|Apple, Inc.
BC542F|Intel Corporate
BC5436|Apple, Inc.
BC5451|Samsung Electronics Co.,Ltd
BC54FC|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
BC5729|Shenzhen KKM Co., Ltd
BC5A56|Cisco Systems, Inc
BC5E33|Hangzhou Hikvision Digital Technology Co.,Ltd.
BC60A7|Sony Interactive Entertainment Inc.
BC6193|Xiaomi Communications Co Ltd
BC620E|HUAWEI TECHNOLOGIES CO.,LTD
BC629C|zte corporation
BC671C|Cisco Systems, Inc
BC6778|Apple, Inc.
BC68C3|HUAWEI TECHNOLOGIES CO.,LTD
BC69CB|Panasonic Electric Works Networks Co., Ltd.
BC6AD1|Xiaomi Communications Co Ltd
BC6B4D|Nokia
BC6C21|Apple, Inc.
BC6C96|SHEN ZHEN TENDA TECHNOLOGY CO.,LTD
BC6E64|Sony Corporation
BC6EE2|Intel Corporate
BC72B1|Samsung Electronics Co.,Ltd
BC74EA|Apple, Inc.
BC7574|HUAWEI TECHNOLOGIES CO.,LTD
BC765E|Samsung Electronics Co.,Ltd
BC7670|HUAWEI TECHNOLOGIES CO.,LTD
BC76C5|HUAWEI TECHNOLOGIES CO.,LTD
BC7737|Intel Corporate
BC79AD|Samsung Electronics Co.,Ltd
BC7ABF|Samsung Electronics Co.,Ltd
BC7B72|Huawei Device Co., Ltd.
BC7E8B|Samsung Electronics Co.,Ltd
BC7EC3|Zyxel Communications Corporation
BC7F7B|Huawei Device Co., Ltd.
BC7FA4|Xiaomi Communications Co Ltd
BC804E|Apple, Inc.
BC8385|Microsoft Corporation
BC83A7|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
BC851F|Samsung Electronics Co.,Ltd
BC8556|Hon Hai Precision Ind. Co.,Ltd.
BC89A7|Apple, Inc.
BC89C1|Apple, Inc.
BC8CCD|SAMSUNG ELECTRO-MECHANICS(THAILAND)
BC8D0E|Nokia
BC8D1F|Cisco Systems, Inc
BC8D2D|Fiberhome Telecommunication Technologies Co.,LTD
BC926B|Apple, Inc.
BC9307|Samsung Electronics Co.,Ltd
BC9388|Nokia Solutions (Shanghai) Co.,Ltd.
BC9680|SHENZHEN GONGJIN ELECTRONICS CO.,LT
BC9789|Huawei Device Co., Ltd.
BC97E1|Broadcom Limited
BC9889|Fiberhome Telecommunication Technologies Co.,LTD
BC98DF|Motorola Mobility LLC, a Lenovo Company
BC9911|Zyxel Communications Corporation
BC9930|HUAWEI TECHNOLOGIES CO.,LTD
BC9A53|Huawei Device Co., Ltd.
BC9B5E|Hangzhou Hikvision Digital Technology Co.,Ltd.
BC9C31|HUAWEI TECHNOLOGIES CO.,LTD
BC9C8D|Ruckus Wireless
BC9D42|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
BC9D4E|Shenzhen Skyworth Digital Technology CO., Ltd
BC9F58|Apple, Inc.
BC9FE4|Hewlett Packard Enterprise
BC9FEF|Apple, Inc.
BCA080|Samsung Electronics Co.,Ltd
BCA0B9|HUAWEI TECHNOLOGIES CO.,LTD
BCA231|HUAWEI TECHNOLOGIES CO.,LTD
BCA511|NETGEAR
BCA58B|Samsung Electronics Co.,Ltd
BCA5A9|Apple, Inc.
BCA8A6|Intel Corporate
BCA920|Apple, Inc.
BCA993|Cambium Networks Limited
BCAA82|Fiberhome Telecommunication Technologies Co.,LTD
BCABF5|Cisco Systems, Inc
BCAD28|Hangzhou Hikvision Digital Technology Co.,Ltd.
BCADAB|Avaya Inc
BCAEC5|ASUSTek COMPUTER INC.
BCB0E7|HUAWEI TECHNOLOGIES CO.,LTD
BCB181|SHARP CORPORATION
BCB1D3|Cisco Meraki
BCB1F3|Samsung Electronics Co.,Ltd
BCB2CC|Samsung Electronics Co.,Ltd
BCB30E|Cisco Systems, Inc
BCB863|Apple, Inc.
BCBAC2|Hangzhou Hikvision Digital Technology Co.,Ltd.
BCBB58|Apple, Inc.
BCBCCA|Huawei Device Co., Ltd.
BCBD84|zte corporation
BCBF2E|ASUSTek COMPUTER INC.
BCC00F|Fiberhome Telecommunication Technologies Co.,LTD
BCC342|Panasonic Communications Co., Ltd.
BCC427|HUAWEI TECHNOLOGIES CO.,LTD
BCC436|Nokia
BCC493|Cisco Systems, Inc
BCC6DB|Nokia Corporation
BCC746|Hon Hai Precision IND.CO.,LTD
BCC810|Cisco SPVTG
BCC8CC|Seiko Epson Corporation
BCCD7F|Huawei Device Co., Ltd.
BCCD99|Intel Corporate
BCCF4F|Zyxel Communications Corporation
BCD074|Apple, Inc.
BCD11F|Samsung Electronics Co.,Ltd
BCD165|Cisco SPVTG
BCD177|TP-LINK TECHNOLOGIES CO.,LTD.
BCD1D3|Shenzhen TINNO Mobile Technology Corp.
BCD206|HUAWEI TECHNOLOGIES CO.,LTD
BCD22C|Intel Corporate
BCD295|Cisco Systems, Inc
BCD5ED|Sagemcom Broadband SAS
BCD7A5|Hewlett Packard Enterprise
BCD7D4|Roku, Inc
BCDB09|Cisco Meraki
BCDDC2|Espressif Inc.
BCDF58|Google, Inc.
BCE143|Apple, Inc.
BCE265|HUAWEI TECHNOLOGIES CO.,LTD
BCE63F|Samsung Electronics Co.,Ltd
BCE67C|Cambium Networks Limited
BCE712|Cisco Systems, Inc
BCE92F|HP Inc.
BCEAFA|Hewlett Packard
BCEBE8|Samsung Electronics Co.,Ltd
BCEC23|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
BCEC5D|Apple, Inc.
BCECA0|COMPAL INFORMATION (KUNSHAN) CO., LTD.
BCEE7B|ASUSTek COMPUTER INC.
BCF105|Intel Corporate
BCF171|Intel Corporate
BCF1F2|Cisco Systems, Inc
BCF310|Extreme Networks, Inc.
BCF45F|zte corporation
BCF5AC|LG Electronics (Mobile Communications)
BCF685|D-Link International
BCF730|Samsung Electronics Co.,Ltd
BCF88B|zte corporation
BCFAEB|Cisco Systems, Inc
BCFCE7|ASUSTek COMPUTER INC.
BCFD0C|Shenzhen Phaten Tech. LTD
BCFED9|Apple, Inc.
BCFF21|Smart Code(shenzhen)Technology Co.,Ltd
BCFF4D|Espressif Inc.
BCFF54|zte corporation
BCFFEB|Motorola Mobility LLC, a Lenovo Company
C00195|Amazon Technologies Inc.
C00380|Juniper Networks
C0060C|HUAWEI TECHNOLOGIES CO.,LTD
C006C3|TP-Link Systems Inc
C00925|FN-LINK TECHNOLOGY Ltd.
C01173|Samsung Electronics Co.,Ltd
C0143D|Hon Hai Precision Ind. Co.,Ltd.
C014B8|Nokia
C014FE|Cisco Systems, Inc
C0151B|Sony Interactive Entertainment Inc.
C01693|Xiaomi Communications Co Ltd
C0174D|Samsung Electronics Co.,Ltd
C01754|Apple, Inc.
C01803|HP Inc.
C01850|Quanta Computer Inc.
C01885|Hon Hai Precision Ind. Co.,Ltd.
C01944|Juniper Networks
C01ADA|Apple, Inc.
C01C30|Shenzhen WIFI-3L Technology Co.,Ltd
C01C6A|Google, Inc.
C0210D|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
C0238D|Samsung Electronics Co.,Ltd
C0252F|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
C0255C|Cisco Systems, Inc
C025A5|Dell Inc.
C025E9|TP-LINK TECHNOLOGIES CO.,LTD.
C02C17|Cisco Systems, Inc
C02C5C|Apple, Inc.
C02C7A|Shenzhen Horn Audio Co.,Ltd.
C02E1D|Nokia Solutions and Networks GmbH & Co. KG
C02E5F|Zyxel Communications Corporation
C0335E|Microsoft
C03379|HUAWEI TECHNOLOGIES CO.,LTD
C033DA|Shenzhen JRUN Technologies CO., LTD
C034B4|Gigastone Corporation
C03532|Liteon Technology Corporation
C03656|Fiberhome Telecommunication Technologies Co.,LTD
C03896|Hon Hai Precision Ind. Co.,Ltd.
C038F9|Nokia Danmark A/S
C0395A|Zhejiang Dahua Technology Co., Ltd.
C03A55|TP-Link Systems Inc.
C03C04|Sagemcom Broadband SAS
C03C59|Intel Corporate
C03D03|Samsung Electronics Co.,Ltd
C03E50|HUAWEI TECHNOLOGIES CO.,LTD
C03E75|HUAWEI TECHNOLOGIES CO.,LTD
C03EBA|Dell Inc.
C03F0E|NETGEAR
C03FDD|HUAWEI TECHNOLOGIES CO.,LTD
C04121|Nokia Solutions and Networks GmbH & Co. KG
C041F6|LG ELECTRONICS INC
C042D0|Juniper Networks
C04442|Apple, Inc.
C044E3|Shenzhen Sinkna Electronics Co., LTD
C0470E|Dell Inc.
C048E6|Samsung Electronics Co.,Ltd
C048FB|Shenzhen JingHanDa Electronics Co.Ltd
C04943|zte corporation
C049EF|Espressif Inc.
C04A00|TP-LINK TECHNOLOGIES CO.,LTD.
C04E30|Espressif Inc.
C04E8A|HUAWEI TECHNOLOGIES CO.,LTD
C0515C|zte corporation
C0517E|Hangzhou Hikvision Digital Technology Co.,Ltd.
C05234|HUAWEI TECHNOLOGIES CO.,LTD
C0544D|Nokia Shanghai Bell Co., Ltd.
C056E3|Hangzhou Hikvision Digital Technology Co.,Ltd.
C057BC|Avaya Inc
C0582E|Cisco Systems, Inc
C05B44|Beijing Xiaomi Mobile Software Co., Ltd
C05BBD|HUAWEI TECHNOLOGIES CO.,LTD
C05D89|Espressif Inc.
C05E79|SHENZHEN HUAXUN ARK TECHNOLOGIES CO.,LTD
C06118|TP-LINK TECHNOLOGIES CO.,LTD.
C06194|Huawei Device Co., Ltd.
C0626B|Cisco Systems, Inc
C06394|Apple, Inc.
C064C6|Nokia Corporation
C064E4|Cisco Systems, Inc
C06599|Samsung Electronics Co.,Ltd
C067AF|Cisco Systems, Inc
C068CC|Shenzhen Skyworth Digital Technology CO., Ltd
C06B55|Motorola Mobility LLC, a Lenovo Company
C06C0C|Apple, Inc.
C06DED|Hangzhou Hikvision Digital Technology Co.,Ltd.
C06E3D|SHENZHEN TECNO TECHNOLOGY
C07009|HUAWEI TECHNOLOGIES CO.,LTD
C071AA|ShenZhen OnMicro Electronics Co.,Ltd.
C0742B|SHENZHEN XUNLONG SOFTWARE CO.,LIMITED
C074AD|Grandstream Networks, Inc.
C07831|Huawei Device Co., Ltd.
C07982|TCL King Electrical Appliances(Huizhou)Co.,Ltd
C07AD6|Samsung Electronics Co.,Ltd
C07BBC|Cisco Systems, Inc
C07C90|Shenzhen YOUHUA Technology Co., Ltd
C07CD1|PEGATRON CORPORATION
C07E40|SHENZHEN XDK COMMUNICATION EQUIPMENT CO.,LTD
C083C9|Huawei Device Co., Ltd.
C0847A|Apple, Inc.
C084E0|HUAWEI TECHNOLOGIES CO.,LTD
C086B3|Shenzhen Voxtech Co., Ltd.
C08706|Shenzhen Qianfenyi Intelligent Technology Co.,LTD
C087EB|Samsung Electronics Co.,Ltd
C08997|Samsung Electronics Co.,Ltd
C08ADE|Ruckus Wireless
C08B05|HUAWEI TECHNOLOGIES CO.,LTD
C08B27|FN-LINK TECHNOLOGY Ltd.
C08B2A|Cisco Systems, Inc
C08C60|Cisco Systems, Inc
C08C71|Motorola Mobility LLC, a Lenovo Company
C08D51|Amazon Technologies Inc.
C08F20|Shenzhen Skyworth Digital Technology CO., Ltd
C091B9|Amazon Technologies Inc.
C09296|zte corporation
C094AD|zte corporation
C0956D|Apple, Inc.
C095CF|Amazon Technologies Inc.
C096A4|Fiberhome Telecommunication Technologies Co.,LTD
C09727|SAMSUNG ELECTRO-MECHANICS(THAILAND)
C09879|Acer Inc.
C09AD0|Apple, Inc.
C09B63|HUAWEI TECHNOLOGIES CO.,LTD
C09F42|Apple, Inc.
C09FE1|zte corporation
C0A0BB|D-Link International
C0A36D|HUAWEI TECHNOLOGIES CO.,LTD
C0A53E|Apple, Inc.
C0A5DD|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
C0A5E8|Intel Corporate
C0A600|Apple, Inc.
C0A810|Intel Corporate
C0A938|HUAWEI TECHNOLOGIES CO.,LTD
C0AB2B|Huawei Device Co., Ltd.
C0AC54|Sagemcom Broadband SAS
C0AEFD|Shenzhen HC-WLAN Technology Co.,Ltd
C0B101|zte corporation
C0B22F|Apple, Inc.
C0B47D|Huawei Device Co., Ltd.
C0B550|Broadcom Limited
C0B5CD|Huawei Device Co., Ltd.
C0B658|Apple, Inc.
C0B6F9|Intel Corporate
C0B883|Intel Corporate
C0BC9A|HUAWEI TECHNOLOGIES CO.,LTD
C0BDC8|Samsung Electronics Co.,Ltd
C0BDD1|SAMSUNG ELECTRO-MECHANICS(THAILAND)
C0BFA7|Juniper Networks
C0BFAC|Huawei Device Co., Ltd.
C0BFBE|AzureWave Technology Inc.
C0BFC0|HUAWEI TECHNOLOGIES CO.,LTD
C0C170|Shenzhen SuperElectron Technology Co.,Ltd.
C0C1C0|Cisco-Linksys, LLC
C0C520|Ruckus Wireless
C0C687|Cisco SPVTG
C0C70A|Ruckus Wireless
C0C7DB|Apple, Inc.
C0C976|Shenzhen TINNO Mobile Technology Corp.
C0C9E3|TP-LINK TECHNOLOGIES CO.,LTD.
C0CB38|Hon Hai Precision Ind. Co.,Ltd.
C0CCF8|Apple, Inc.
C0CDD6|Espressif Inc.
C0CECD|Apple, Inc.
C0D012|Apple, Inc.
C0D026|Huawei Device Co., Ltd.
C0D044|Sagemcom Broadband SAS
C0D193|Huawei Device Co., Ltd.
C0D2DD|Samsung Electronics Co.,Ltd
C0D3C0|Samsung Electronics Co.,Ltd
C0D46B|Huawei Device Co., Ltd.
C0D5E2|Samsung Electronics Co.,Ltd
C0D6D5|Microsoft Corporation
C0D941|Shenzhen VMAX Software Co., Ltd.
C0DA5E|Huawei Device Co., Ltd.
C0DCD7|Huawei Device Co., Ltd.
C0DCDA|Samsung Electronics Co.,Ltd
C0DFED|Juniper Networks
C0E018|HUAWEI TECHNOLOGIES CO.,LTD
C0E1BE|HUAWEI TECHNOLOGIES CO.,LTD
C0E3FB|HUAWEI TECHNOLOGIES CO.,LTD
C0E42D|TP-LINK TECHNOLOGIES CO.,LTD.
C0E434|AzureWave Technology Inc.
C0E579|Huawei Device Co., Ltd.
C0E862|Apple, Inc.
C0E8EA|Fiberhome Telecommunication Technologies Co.,LTD
C0EAE4|Sonicwall
C0EEFB|OnePlus Tech (Shenzhen) Ltd
C0F2FB|Apple, Inc.
C0F4E6|HUAWEI TECHNOLOGIES CO.,LTD
C0F6C2|HUAWEI TECHNOLOGIES CO.,LTD
C0F6EC|HUAWEI TECHNOLOGIES CO.,LTD
C0F853|Tuya Smart Inc.
C0F87F|Cisco Systems, Inc
C0F8DA|Hon Hai Precision Ind. Co.,Ltd.
C0F945|Toshiba Toko Meter Systems Co., LTD.
C0F9B0|HUAWEI TECHNOLOGIES CO.,LTD
C0FD6F|Sagemcom Broadband SAS
C0FD84|zte corporation
C0FFA8|HUAWEI TECHNOLOGIES CO.,LTD
C0FFD4|NETGEAR
C4017C|Ruckus Wireless
C403A8|Intel Corporate
C40415|NETGEAR
C4047B|Shenzhen YOUHUA Technology Co., Ltd
C40528|HUAWEI TECHNOLOGIES CO.,LTD
C40683|HUAWEI TECHNOLOGIES CO.,LTD
C4072F|HUAWEI TECHNOLOGIES CO.,LTD
C4084A|Nokia
C40880|Shenzhen UTEPO Tech Co., Ltd.
C409B7|Juniper Networks
C40ACB|Cisco Systems, Inc
C40B31|Apple, Inc.
C40BCB|Xiaomi Communications Co Ltd
C40D96|HUAWEI TECHNOLOGIES CO.,LTD
C40F08|Intel Corporate
C4108A|Ruckus Wireless
C41234|Apple, Inc.
C412EC|HUAWEI TECHNOLOGIES CO.,LTD
C412F5|D-Link International
C413E2|Extreme Networks, Inc.
C41411|Apple, Inc.
C4143C|Cisco Systems, Inc
C414A2|Cisco Meraki
C41688|Huawei Device Co., Ltd.
C4168F|Apple, Inc.
C416C8|HUAWEI TECHNOLOGIES CO.,LTD
C4170E|Huawei Device Co., Ltd.
C417FE|Hon Hai Precision Ind. Co.,Ltd.
C418E9|Samsung Electronics Co.,Ltd
C418FC|Cisco Systems, Inc
C41C07|Samsung Electronics Co.,Ltd
C42155|Huawei Device Co., Ltd.
C421B9|zte corporation
C421C8|KYOCERA CORPORATION
C42360|Intel Corporate
C42456|Palo Alto Networks
C42728|zte corporation
C4278C|Huawei Device Co., Ltd.
C42AD0|Apple, Inc.
C42B44|Huawei Device Co., Ltd.
C42C03|Apple, Inc.
C42F90|Hangzhou Hikvision Digital Technology Co.,Ltd.
C4345B|HUAWEI TECHNOLOGIES CO.,LTD
C4346B|Hewlett Packard
C435D9|Apple, Inc.
C43655|Shenzhen Fenglian Technology Co., Ltd.
C43875|Sonos, Inc.
C43A35|FN-LINK TECHNOLOGY LIMITED
C43AA5|AzureWave Technology Inc.
C43ABE|Sony Corporation
C43CB0|SHENZHEN BILIAN ELECTRONIC CO.，LTD
C43D1A|Intel Corporate
C43DC7|NETGEAR
C43EAB|Huawei Device Co., Ltd.
C44202|Samsung Electronics Co.,Ltd
C4438F|LG Electronics (Mobile Communications)
C4447D|HUAWEI TECHNOLOGIES CO.,LTD
C444A0|Cisco Systems, Inc
C44606|Cisco Systems, Inc
C44619|Hon Hai Precision Ind. Co.,Ltd.
C4473F|HUAWEI TECHNOLOGIES CO.,LTD
C4474E|Intel Corporate
C4491B|Apple, Inc.
C4493E|Motorola Mobility LLC, a Lenovo Company
C44B31|Cisco Systems, Inc
C44D84|Cisco Systems, Inc
C44EAC|Shenzhen Shiningworth Technology Co., Ltd.
C44F33|Espressif Inc.
C44F5F|Huawei Device Co., Ltd.
C45006|Samsung Electronics Co.,Ltd
C4518D|Shenzhen YOUHUA Technology Co., Ltd
C4524F|Apple, Inc.
C45444|Quanta Computer Inc.
C4550D|HUAWEI TECHNOLOGIES CO.,LTD
C4576E|Samsung Electronics Co.,Ltd
C457CD|HUAWEI TECHNOLOGIES CO.,LTD
C458C2|Shenzhen TATFOOK Technology Co., Ltd.
C45A86|Huawei Device Co., Ltd.
C45AB1|Dell Inc.
C45BAC|Apple, Inc.
C45BBE|Espressif Inc.
C45D83|Samsung Electronics Co.,Ltd
C45E5C|HUAWEI TECHNOLOGIES CO.,LTD
C4618B|Apple, Inc.
C461C7|Microsoft Corporation
C462EA|Samsung Electronics Co.,Ltd
C463C4|HUAWEI TECHNOLOGIES CO.,LTD
C46413|Cisco Systems, Inc
C464B7|Fiberhome Telecommunication Technologies Co.,LTD
C46516|Hewlett Packard
C467D1|HUAWEI TECHNOLOGIES CO.,LTD
C46940|Xiaomi Communications Co Ltd
C469F0|HUAWEI TECHNOLOGIES CO.,LTD
C46AB7|Xiaomi Communications Co Ltd
C46DD1|HUAWEI TECHNOLOGIES CO.,LTD
C46E1F|TP-LINK TECHNOLOGIES CO.,LTD.
C46E7B|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
C4710F|Xiaomi Communications Co Ltd
C47154|TP-LINK TECHNOLOGIES CO.,LTD.
C471FE|Cisco Systems, Inc
C47295|Cisco Systems, Inc
C4731E|Samsung Electronics Co.,Ltd
C4741E|zte corporation
C475AB|Intel Corporate
C475EA|HUAWEI TECHNOLOGIES CO.,LTD
C47764|Samsung Electronics Co.,Ltd
C478A2|Huawei Device Co., Ltd.
C47BE3|HUAWEI TECHNOLOGIES CO.,LTD
C47D46|FUJITSU LIMITED
C47D4F|Cisco Systems, Inc
C47D9F|Samsung Electronics Co.,Ltd
C47DCC|Zebra Technologies Inc
C47EE0|Cisco Systems, Inc
C48025|Huawei Device Co., Ltd.
C482E1|Tuya Smart Inc.
C48466|Apple, Inc.
C484C0|Motorola Mobility LLC, a Lenovo Company
C484FC|Apple, Inc.
C48508|Intel Corporate
C486E9|HUAWEI TECHNOLOGIES CO.,LTD
C488E5|Samsung Electronics Co.,Ltd
C48BA3|Cisco Meraki
C48E8F|Hon Hai Precision Ind. Co.,Ltd.
C48F07|Shenzhen Yihao Hulian Science and Technology Co., Ltd.
C4910C|Apple, Inc.
C4913A|Shenzhen Sanland Electronic Co., ltd.
C492D9|zte corporation
C493BB|Beijing Xiaomi Mobile Software Co., Ltd
C493D9|Samsung Electronics Co.,Ltd
C49500|Amazon Technologies Inc.
C495A2|SHENZHEN WEIJIU INDUSTRY AND TRADE DEVELOPMENT CO., LTD
C4969F|Amazon Technologies Inc.
C49880|Apple, Inc.
C49A02|LG Electronics (Mobile Communications)
C49A31|Zyxel Communications Corporation
C49D08|Huawei Device Co., Ltd.
C49DED|Microsoft Corporation
C49E7E|Espressif Inc.
C49F4C|HUAWEI TECHNOLOGIES CO.,LTD
C4A052|Motorola Mobility LLC, a Lenovo Company
C4A1AE|Huawei Device Co., Ltd.
C4A366|zte corporation
C4A402|HUAWEI TECHNOLOGIES CO.,LTD
C4A72B|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
C4A81D|D-Link International
C4AA43|Cisco Systems, Inc
C4AA99|HUAWEI TECHNOLOGIES CO.,LTD
C4AAC4|Zhejiang Dahua Technology Co., Ltd.
C4AB4D|Cisco Systems, Inc
C4ACAA|Apple, Inc.
C4AD34|Routerboard.com
C4AE12|Samsung Electronics Co.,Ltd
C4B1D9|HUAWEI TECHNOLOGIES CO.,LTD
C4B239|Cisco Systems, Inc
C4B301|Apple, Inc.
C4B349|Apple, Inc.
C4B36A|Cisco Systems, Inc
C4B8B4|HUAWEI TECHNOLOGIES CO.,LTD
C4B9CD|Cisco Systems, Inc
C4BB03|HUAWEI TECHNOLOGIES CO.,LTD
C4BB4C|Zebra Information Tech Co. Ltd
C4BD8D|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
C4BDE5|Intel Corporate
C4BED4|Avaya Inc
C4C00A|Microsoft Corporation
C4C17D|Apple, Inc.
C4C36B|Apple, Inc.
C4C603|Cisco Systems, Inc
C4C6E6|LCFC(Hefei) Electronics Technology co., ltd
C4CB76|Microsoft Corporation
C4CBE1|Dell Inc.
C4CCF9|zte corporation
C4CD50|Shenzhen C-Data Technology Co., Ltd.
C4D0E3|Intel Corporate
C4D438|HUAWEI TECHNOLOGIES CO.,LTD
C4D496|Shenzhen Excelsecu Data Technology Co.,Ltd
C4D4D0|SHENZHEN TECNO TECHNOLOGY
C4D666|Cisco Meraki
C4D6D3|Dell Inc.
C4D738|Huawei Device Co., Ltd.
C4D8D4|HUAWEI TECHNOLOGIES CO.,LTD
C4D8D5|Espressif Inc.
C4D987|Intel Corporate
C4DB04|HUAWEI TECHNOLOGIES CO.,LTD
C4DD57|Espressif Inc.
C4DE7B|Huawei Device Co., Ltd.
C4DEE2|Espressif Inc.
C4E287|HUAWEI TECHNOLOGIES CO.,LTD
C4E90A|D-Link International
C4E984|TP-LINK TECHNOLOGIES CO.,LTD.
C4EB39|Sagemcom Broadband SAS
C4EB41|Sagemcom Broadband SAS
C4EB42|Sagemcom Broadband SAS
C4EB43|Sagemcom Broadband SAS
C4EB81|Apple, Inc.
C4EBFF|zte corporation
C4EF3D|Samsung Electronics Co.,Ltd
C4EFBB|LCFC(Hefei) Electronics Technology co., ltd
C4EFDA|Honeywell
C4F081|HUAWEI TECHNOLOGIES CO.,LTD
C4F0EC|Fiberhome Telecommunication Technologies Co.,LTD
C4F445|Apple, Inc.
C4F7C1|Apple, Inc.
C4F7D5|Cisco Systems, Inc
C4FBAA|HUAWEI TECHNOLOGIES CO.,LTD
C4FBC8|Shenzhen Candour Co., Ltd.
C4FC22|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
C4FF1F|HUAWEI TECHNOLOGIES CO.,LTD
C4FF22|Huawei Device Co., Ltd.
C4FF99|Intel Corporate
C80084|Cisco Systems, Inc
C803F5|Ruckus Wireless
C805A4|Motorola(Wuhan) Mobility Technologies Communication Co.,Ltd
C80873|Ruckus Wireless
C808E9|LG Electronics
C809A8|Intel Corporate
C80AA9|Quanta Computer Inc.
C80CC8|HUAWEI TECHNOLOGIES CO.,LTD
C8102F|NETGEAR
C8120B|Samsung Electronics Co.,Ltd
C81337|Juniper Networks
C8138B|Shenzhen Skyworth Digital Technology CO., Ltd
C81451|HUAWEI TECHNOLOGIES CO.,LTD
C81479|Samsung Electronics Co.,Ltd
C8154E|Intel Corporate
C819D8|Blink by Amazon
C819F7|Samsung Electronics Co.,Ltd
C81CFE|Zebra Technologies Inc.
C81EE7|Apple, Inc.
C81F66|Dell Inc.
C81FBE|HUAWEI TECHNOLOGIES CO.,LTD
C81FE8|Apple, Inc.
C81FEA|Avaya Inc
C82158|Intel Corporate
C821DA|Shenzhen YOUHUA Technology Co., Ltd
C82832|Beijing Xiaomi Electronics Co., Ltd.
C828E5|Cisco Systems, Inc
C829C8|Palo Alto Networks
C82A14|Apple, Inc.
C82ADD|Google, Inc.
C82B6B|shenzhen worldelite electronics co., LTD
C82B96|Espressif Inc.
C82E18|Espressif Inc.
C83049|Huawei Device Co., Ltd.
C8334B|Apple, Inc.
C83374|Zyxel Communications Corporation
C833E5|HUAWEI TECHNOLOGIES CO.,LTD
C8348E|Intel Corporate
C834E5|Cisco Systems, Inc
C836A3|GERTEC BRASIL LTDA
C83870|Samsung Electronics Co.,Ltd
C839AC|Huawei Device Co., Ltd.
C83A1B|Toshiba TEC Corporation Inc
C83A35|Tenda Technology Co., Ltd.
C83A6B|Roku, Inc
C83C85|Apple, Inc.
C83D97|Nokia Corporation
C83DDC|Xiaomi Communications Co Ltd
C83E9E|Huawei Device Co., Ltd.
C83F26|Microsoft Corporation
C84029|Fiberhome Telecommunication Technologies Co.,LTD
C84052|PAX Computer Technology(Shenzhen) Ltd.
C8418A|Samsung Electronics.,LTD
C84709|Cisco Systems, Inc
C84AA0|Sony Interactive Entertainment Inc.
C84BD6|Dell Inc.
C84C75|Cisco Systems, Inc
C84C78|zte corporation
C84D44|Shenzhen Jiapeng Huaxiang Technology Co.,Ltd
C84F86|Sophos Ltd
C850CE|HUAWEI TECHNOLOGIES CO.,LTD
C85142|Samsung Electronics Co.,Ltd
C85195|HUAWEI TECHNOLOGIES CO.,LTD
C851FB|Extreme Networks, Inc.
C85309|LCFC(Hefei) Electronics Technology co., ltd
C8544B|Zyxel Communications Corporation
C85895|Motorola Mobility LLC, a Lenovo Company
C858B3|Intel Corporate
C858C0|Intel Corporate
C85A9F|zte corporation
C85ACF|HP Inc.
C85B76|LCFC(Hefei) Electronics Technology co., ltd
C85BA0|Shenzhen Qihu Intelligent Technology Company Limited
C85CCC|Beijing Xiaomi Mobile Software Co., Ltd
C85EA9|Intel Corporate
C86000|ASUSTek COMPUTER INC.
C8608F|Cisco Systems, Inc
C86340|Cisco Meraki
C863F1|Sony Interactive Entertainment Inc.
C864C7|zte corporation
C8665D|Extreme Networks, Inc.
C8675E|Extreme Networks, Inc.
C868DE|Huawei Device Co., Ltd.
C869CD|Apple, Inc.
C86C3D|Amazon Technologies Inc.
C86C87|Zyxel Communications Corporation
C86E08|Intel Corporate
C86F1D|Apple, Inc.
C8727E|Nokia
C8741B|Fiberhome Telecommunication Technologies Co.,LTD
C875DD|LG Electronics NV
C8787D|D-Link Corporation
C878F7|Cisco Systems, Inc
C87B5B|zte corporation
C87D77|Shenzhen Kingtech Communication Equipment Co.,Ltd
C87E75|Samsung Electronics Co.,Ltd
C87EA1|TCL MOKA International Limited
C87F54|ASUSTek COMPUTER INC.
C8806D|Apple, Inc.
C88234|Cisco Systems, Inc
C8848C|Ruckus Wireless
C884A1|Cisco Systems, Inc
C884CF|HUAWEI TECHNOLOGIES CO.,LTD
C88541|Espressif Inc.
C88550|Apple, Inc.
C88629|Shenzhen Duubee Intelligent Technologies Co.,LTD.
C889F3|Apple, Inc.
C88A7B|Espressif Inc.
C88A9A|Intel Corporate
C88D83|HUAWEI TECHNOLOGIES CO.,LTD
C88F26|Skyworth Digital Technology(Shenzhen) Co.,Ltd
C8908A|Samsung Electronics Co.,Ltd
C890F7|HUAWEI TECHNOLOGIES CO.,LTD
C891F9|Sagemcom Broadband SAS
C894BB|HUAWEI TECHNOLOGIES CO.,LTD
C895CE|Intel Corporate
C89665|Microsoft Corporation
C8979F|Nokia Corporation
C89828|zte corporation
C89C1D|Cisco Systems, Inc
C89D18|Huawei Device Co., Ltd.
C89E43|NETGEAR
C89F0C|Motorola Mobility LLC, a Lenovo Company
C89F1A|HUAWEI TECHNOLOGIES CO.,LTD
C89F1D|SHENZHEN COMMUNICATION TECHNOLOGIES CO.,LTD
C8A1B6|Shenzhen Longway Technologies Co., Ltd
C8A1DC|Motorola Mobility LLC, a Lenovo Company
C8A23B|Shenzhen Sundray Technologies company Limited
C8A608|Ruckus Wireless
C8A6EF|Samsung Electronics Co.,Ltd
C8A702|Hangzhou Hikvision Digital Technology Co.,Ltd.
C8A776|HUAWEI TECHNOLOGIES CO.,LTD
C8A823|Samsung Electronics Co.,Ltd
C8AAB2|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
C8ADE7|Shenzhen Shengxi Industrial Co.,Ltd
C8B0B2|zte corporation
C8B1CD|Apple, Inc.
C8B21E|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
C8B29B|Intel Corporate
C8B373|Cisco-Linksys, LLC
C8B5AD|Hewlett Packard Enterprise
C8B5B7|Apple, Inc.
C8B6D3|HUAWEI TECHNOLOGIES CO.,LTD
C8B78A|HUAWEI TECHNOLOGIES CO.,LTD
C8BA94|SAMSUNG ELECTRO-MECHANICS(THAILAND)
C8BB81|Huawei Device Co., Ltd.
C8BC9C|Huawei Device Co., Ltd.
C8BCC8|Apple, Inc.
C8BD4D|Samsung Electronics Co.,Ltd
C8BD69|Samsung Electronics Co.,Ltd
C8BE19|D-Link International
C8BE35|Extreme Networks, Inc.
C8BF4C|Beijing Xiaomi Mobile Software Co., Ltd
C8BFFE|Huawei Device Co., Ltd.
C8C2FA|HUAWEI TECHNOLOGIES CO.,LTD
C8C465|HUAWEI TECHNOLOGIES CO.,LTD
C8C50E|Shenzhen Primestone Network Technologies.Co., Ltd.
C8C750|Motorola Mobility LLC, a Lenovo Company
C8C919|Broadcom Limited
C8C9A3|Espressif Inc.
C8C9B2|Amazon Technologies Inc.
C8CA63|Huawei Device Co., Ltd.
C8CB9E|Intel Corporate
C8CBB8|Hewlett Packard
C8CD72|Sagemcom Broadband SAS
C8D083|Apple, Inc.
C8D10B|Nokia Corporation
C8D15E|HUAWEI TECHNOLOGIES CO.,LTD
C8D1A9|HUAWEI TECHNOLOGIES CO.,LTD
C8D2C1|Jetlun (Shenzhen) Corporation
C8D3A3|D-Link International
C8D3FF|Hewlett Packard
C8D5FE|Shenzhen Zowee Technology Co., Ltd
C8D719|Cisco-Linksys, LLC
C8D7B0|Samsung Electronics Co.,Ltd
C8D959|Motorola Mobility LLC, a Lenovo Company
C8D995|Juniper Networks
C8D9D2|Hewlett Packard
C8DA29|Espressif Systems (Singapore) Pte. Ltd
C8DDC9|Lenovo Mobile Communication Technology Ltd.
C8DF7C|Nokia Corporation
C8E07A|Fiberhome Telecommunication Technologies Co.,LTD
C8E0EB|Apple, Inc.
C8E265|Intel Corporate
C8E31D|HUAWEI TECHNOLOGIES CO.,LTD
C8E5E0|HUAWEI TECHNOLOGIES CO.,LTD
C8E600|HUAWEI TECHNOLOGIES CO.,LTD
C8E7F0|Juniper Networks
C8EA71|Espressif Inc.
C8EAF8|zte corporation
C8EBEC|Shenzhen YOUHUA Technology Co., Ltd
C8ED8B|Espressif Inc.
C8EDFC|Shenzhen Ideaform Industrial Product Design Co., Ltd
C8EEA6|Shenzhen SHX Technology Co., Ltd
C8F09E|Espressif Inc.
C8F319|LG Electronics (Mobile Communications)
C8F386|Shenzhen Xiaoniao Technology Co.,Ltd
C8F406|Avaya Inc
C8F650|Apple, Inc.
C8F6C8|Fiberhome Telecommunication Technologies Co.,LTD
C8F733|Intel Corporate
C8F750|Dell Inc.
C8F9C8|NewSharp Technology(SuZhou)Co,Ltd
C8F9F9|Cisco Systems, Inc
C8FB26|Cisco SPVTG
C8FE0F|SHENZHEN BILIAN ELECTRONIC CO.，LTD
C8FE6A|Juniper Networks
C8FF28|Liteon Technology Corporation
CC00F1|Sagemcom Broadband SAS
CC033D|Beijing Xiaomi Mobile Software Co., Ltd
CC03D9|Cisco Meraki
CC051B|Samsung Electronics Co.,Ltd
CC0577|HUAWEI TECHNOLOGIES CO.,LTD
CC0677|Fiberhome Telecommunication Technologies Co.,LTD
CC07AB|Samsung Electronics Co.,Ltd
CC07E4|Lenovo Mobile Communication Technology Ltd.
CC087B|HUAWEI TECHNOLOGIES CO.,LTD
CC088D|Apple, Inc.
CC08E0|Apple, Inc.
CC08FA|Apple, Inc.
CC08FB|TP-LINK TECHNOLOGIES CO.,LTD.
CC0DCB|Microsoft Corporation
CC0DEC|Cisco SPVTG
CC0DF2|Motorola Mobility LLC, a Lenovo Company
CC115A|Apple, Inc.
CC13F3|Hangzhou Hikvision Digital Technology Co.,Ltd.
CC1531|Intel Corporate
CC167E|Cisco Systems, Inc
CC1AFA|zte corporation
CC1B5A|Ruckus Wireless
CC1E56|HUAWEI TECHNOLOGIES CO.,LTD
CC1E97|HUAWEI TECHNOLOGIES CO.,LTD
CC208C|HUAWEI TECHNOLOGIES CO.,LTD
CC20AC|Samsung Electronics Co.,Ltd
CC20E8|Apple, Inc.
CC2119|Samsung Electronics Co.,Ltd
CC219D|Shenzhen Wangliantong Intelligent Technology Co.,Lte
CC2293|Amazon Technologies Inc.
CC22FE|Apple, Inc.
CC242E|Shenzhen SuperElectron Technology Co.,Ltd.
CC25EF|Apple, Inc.
CC2746|Apple, Inc.
CC28AA|ASUSTek COMPUTER INC.
CC29BD|zte corporation
CC29F5|Apple, Inc.
CC2D21|Tenda Technology Co.,Ltd.Dongguan branch
CC2D8C|LG ELECTRONICS INC
CC2DB7|Apple, Inc.
CC2DD2|Ruckus Wireless
CC2DE0|Routerboard.com
CC2F71|Intel Corporate
CC312A|HUIZHOU TCL COMMUNICATION ELECTRON CO.,LTD
CC3296|Huawei Device Co., Ltd.
CC32E5|TP-LINK TECHNOLOGIES CO.,LTD.
CC33BB|Sagemcom Broadband SAS
CC3429|TP-LINK TECHNOLOGIES CO.,LTD.
CC35D9|Ubiquiti Inc
CC36CF|Cisco Systems, Inc
CC38D0|Palo Alto Networks
CC38E1|HUAWEI TECHNOLOGIES CO.,LTD
CC3A61|SAMSUNG ELECTRO MECHANICS CO., LTD.
CC3D82|Intel Corporate
CC3DD1|HUAWEI TECHNOLOGIES CO.,LTD
CC3E5F|Hewlett Packard
CC3F36|Apple, Inc.
CC40D0|NETGEAR
CC4210|Xiaomi Communications Co Ltd
CC4460|Huawei Device Co., Ltd.
CC4463|Apple, Inc.
CC464E|Samsung Electronics Co.,Ltd
CC46D6|Cisco Systems, Inc
CC4740|AzureWave Technology Inc.
CC483A|Dell Inc.
CC4B04|Apple, Inc.
CC4D75|Beijing Xiaomi Mobile Software Co., Ltd
CC500A|Fiberhome Telecommunication Technologies Co.,LTD
CC50E3|Espressif Inc.
CC5289|SHENZHEN OPTFOCUS TECHNOLOGY.,LTD
CC53B5|HUAWEI TECHNOLOGIES CO.,LTD
CC5763|Panasonic Automotive Systems Co.,Ltd
CC5830|Sagemcom Broadband SAS
CC58C7|Nokia
CC5A53|Cisco Systems, Inc
CC5C61|Huawei Device Co., Ltd.
CC5D4E|Zyxel Communications Corporation
CC5EA5|Palo Alto Networks
CC6023|Apple, Inc.
CC60C8|Microsoft Corporation
CC61E5|Motorola Mobility LLC, a Lenovo Company
CC641A|SHENZHEN BILIAN ELECTRONIC CO.，LTD
CC64A6|HUAWEI TECHNOLOGIES CO.,LTD
CC660A|Apple, Inc.
CC66B2|Nokia
CC68B6|TP-Link Systems Inc
CC68C7|Espressif Inc.
CC68E0|Apple, Inc.
CC69FA|Apple, Inc.
CC6A33|Cisco Systems, Inc
CC6DA0|Roku, Inc.
CC6E2A|Cisco Meraki
CC6EA4|Samsung Electronics Co.,Ltd
CC70ED|Cisco Systems, Inc
CC722A|Apple, Inc.
CC763A|zte corporation
CC7645|Microsoft Corporation
CC77C9|Fiberhome Telecommunication Technologies Co.,LTD
CC785F|Apple, Inc.
CC79CF|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
CC79D7|Cisco Systems, Inc
CC7A8B|SHENZHEN TECNO TECHNOLOGY
CC7B35|zte corporation
CC7B5C|Espressif Inc.
CC7E1F|Espressif Inc.
CC7EE7|Panasonic Corporation AVC Networks Company
CC7F75|Cisco Systems, Inc
CC7F76|Cisco Systems, Inc
CC808F|Apple, Inc.
CC8130|Intelbras
CC817D|Apple, Inc.
CC82EB|KYOCERA CORPORATION
CC856C|SHENZHEN MDK DIGITAL TECHNOLOGY CO.,LTD
CC874A|Nokia
CC88C7|Hewlett Packard Enterprise
CC895E|HUAWEI TECHNOLOGIES CO.,LTD
CC89FD|Nokia Corporation
CC8A84|Huawei Device Co., Ltd.
CC8CBF|Tuya Smart Inc.
CC8CDA|Shenzhen Wei Da Intelligent Technology Go.,Ltd
CC8DA2|Espressif Inc.
CC8DB5|Shenzhen SuperElectron Technology Co.,Ltd.
CC8E71|Cisco Systems, Inc
CC9070|Cisco Systems, Inc
CC9096|Huawei Device Co., Ltd.
CC90E8|Shenzhen YOUHUA Technology Co., Ltd
CC915B|Huawei Device Co., Ltd.
CC96A0|HUAWEI TECHNOLOGIES CO.,LTD
CC96E5|Dell Inc.
CC988B|SONY Visual Products Inc.
CC9891|Cisco Systems, Inc
CC9C3E|Cisco Meraki
CC9EA2|Amazon Technologies Inc.
CCA08F|zte corporation
CCA12B|TCL King Electrical Appliances (Huizhou) Co., Ltd
CCA219|SHENZHEN ALONG INVESTMENT CO.,LTD
CCA223|HUAWEI TECHNOLOGIES CO.,LTD
CCA4AF|Shenzhen Sowell Technology Co., LTD
CCA7C1|Google, Inc.
CCAA00|Microsoft Corporation
CCAF78|Hon Hai Precision Ind. Co.,Ltd.
CCAFE3|Amazon Technologies Inc.
CCB071|Fiberhome Telecommunication Technologies Co.,LTD
CCB0A8|Huawei Device Co., Ltd.
CCB0B3|Microsoft Corporation
CCB0DA|Liteon Technology Corporation
CCB11A|Samsung Electronics Co.,Ltd
CCB182|HUAWEI TECHNOLOGIES CO.,LTD
CCB255|D-Link International
CCB3AB|shenzhen Biocare Bio-Medical Equipment Co.,Ltd.
CCB3F8|FUJITSU ISOTEC LIMITED
CCB5D1|Beijing Xiaomi Mobile Software Co., Ltd
CCB6C8|Cisco Systems, Inc
CCB775|Huawei Device Co., Ltd.
CCB777|zte corporation
CCB7C4|HUAWEI TECHNOLOGIES CO.,LTD
CCB85E|Shenzhen Phaten Tech. LTD
CCBA6F|HUAWEI TECHNOLOGIES CO.,LTD
CCBA97|Espressif Inc.
CCBABD|TP-Link Systems Inc.
CCBBFE|HUAWEI TECHNOLOGIES CO.,LTD
CCBC2B|Huawei Device Co., Ltd.
CCBCE3|HUAWEI TECHNOLOGIES CO.,LTD
CCBE61|Apple, Inc.
CCBF0C|SHENZHEN FENDA TECHNOLOGY CO., LTD
CCC253|zte corporation
CCC3EA|Motorola Mobility LLC, a Lenovo Company
CCC4B2|Shenzhen Trolink Technology Co.,LTD
CCC50A|SHENZHEN DAJIAHAO TECHNOLOGY CO.,LTD
CCC530|AzureWave Technology Inc.
CCC5E5|Dell Inc.
CCC760|Apple, Inc.
CCC95D|Apple, Inc.
CCCC81|HUAWEI TECHNOLOGIES CO.,LTD
CCD083|Hewlett Packard Enterprise
CCD281|Apple, Inc.
CCD29B|Shenzhen Bopengfa Elec&Technology CO.,Ltd
CCD342|Cisco Systems, Inc
CCD539|Cisco Systems, Inc
CCD73C|HUAWEI TECHNOLOGIES CO.,LTD
CCD843|Beijing Xiaomi Mobile Software Co., Ltd
CCD8C1|Cisco Systems, Inc
CCD9AC|Intel Corporate
CCDA20|Beijing Xiaomi Mobile Software Co., Ltd
CCDB93|Cisco Systems, Inc
CCDBA7|Espressif Inc.
CCDEDE|Nokia
CCE17F|Juniper Networks
CCE194|Juniper Networks
CCE686|Samsung Electronics Co.,Ltd
CCE9FA|Samsung Electronics Co.,Ltd
CCEB5E|Xiaomi Communications Co Ltd
CCECB7|ShenZhen Linked-Z Intelligent Display Co., Ltd
CCED21|Nokia Shanghai Bell Co., Ltd.
CCED4D|Cisco Systems, Inc
CCEF48|Cisco Systems, Inc
CCF305|SHENZHEN TIAN XING CHUANG ZHAN ELECTRONIC CO.,LTD
CCF411|Google, Inc.
CCF735|Amazon Technologies Inc.
CCF826|Samsung Electronics Co.,Ltd
CCF954|Avaya Inc
CCF9E4|Intel Corporate
CCF9E8|Samsung Electronics Co.,Ltd
CCF9F0|Samsung Electronics Co.,Ltd
CCFA00|LG Electronics (Mobile Communications)
CCFA66|Huawei Device Co., Ltd.
CCFAF1|Sagemcom Broadband SAS
CCFE3C|Samsung Electronics Co.,Ltd
CCFF90|Huawei Device Co., Ltd.
D0034B|Apple, Inc.
D003DF|Samsung Electronics Co.,Ltd
D00401|Motorola Mobility LLC, a Lenovo Company
D00477|HUAWEI TECHNOLOGIES CO.,LTD
D00492|Fiberhome Telecommunication Technologies Co.,LTD
D004B0|Samsung Electronics Co.,Ltd
D005E4|Huawei Device Co., Ltd.
D007CA|Juniper Networks
D009C8|Cisco Systems, Inc
D00DF7|Huawei Device Co., Ltd.
D011E5|Apple, Inc.
D013C1|Shenzhen Skyworth Digital Technology CO., Ltd
D013FD|LG Electronics (Mobile Communications)
D0154A|zte corporation
D015A6|Hewlett Packard Enterprise
D016B4|HUAWEI TECHNOLOGIES CO.,LTD
D0176A|Samsung Electronics Co.,Ltd
D017C2|ASUSTek COMPUTER INC.
D01B49|Samsung Electronics Co.,Ltd
D01BF4|Sagemcom Broadband SAS
D021F9|Ubiquiti Inc
D022BE|SAMSUNG ELECTRO-MECHANICS(THAILAND)
D023DB|Apple, Inc.
D02544|SAMSUNG ELECTRO-MECHANICS(THAILAND)
D02598|Apple, Inc.
D02788|Hon Hai Precision Ind. Co.,Ltd.
D02B20|Apple, Inc.
D02C39|Cisco Systems, Inc
D02DB3|HUAWEI TECHNOLOGIES CO.,LTD
D03169|Samsung Electronics Co.,Ltd
D032C3|D-Link Corporation
D032E7|Tuya Smart Inc.
D03311|Apple, Inc.
D03742|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
D03745|TP-LINK TECHNOLOGIES CO.,LTD.
D03957|Liteon Technology Corporation
D039FA|Samsung Electronics Co.,Ltd
D03BF4|Shenzhen Kean Digital Co.,Ltd
D03C1F|Intel Corporate
D03E07|Apple, Inc.
D03E5C|HUAWEI TECHNOLOGIES CO.,LTD
D03E7D|CHIPSEA TECHNOLOGIES (SHENZHEN) CORP.
D03FAA|Apple, Inc.
D041C9|Fiberhome Telecommunication Technologies Co.,LTD
D0431E|Dell Inc.
D0458D|Shenzhen Skyworth Digital Technology CO., Ltd
D0460C|Dell Inc.
D0484F|Nokia Solutions and Networks GmbH & Co. KG
D048A1|Juniper Networks
D0497C|OnePlus Technology (Shenzhen) Co., Ltd
D04D2C|Roku, Inc.
D04D86|Apple, Inc.
D04DC6|Hewlett Packard Enterprise
D04E99|HUAWEI TECHNOLOGIES CO.,LTD
D04F58|Ruckus Wireless
D04F7E|Apple, Inc.
D04FAB|Yoqu Technology (Shenzhen) Co., Ltd.
D05162|Sony Corporation
D05349|Liteon Technology Corporation
D05533|Palo Alto Networks
D056FB|Samsung Electronics Co.,Ltd
D0574C|Cisco Systems, Inc
D0577B|Intel Corporate
D0577E|Intel Corporate
D05794|Sagemcom Broadband SAS
D058A5|Apple, Inc.
D058A8|zte corporation
D05919|zte corporation
D05995|Fiberhome Telecommunication Technologies Co.,LTD
D059E4|Samsung Electronics Co.,Ltd
D05AF1|Shenzhen Pulier Tech CO.,Ltd
D05BA8|zte corporation
D05FAF|Shenzhen C-Data Technology Co., Ltd.
D0608C|zte corporation
D06158|HUAWEI TECHNOLOGIES CO.,LTD
D06544|Apple, Inc.
D06578|Intel Corporate
D065B3|TCL King Electrical Appliances(Huizhou)Co.,Ltd
D065CA|HUAWEI TECHNOLOGIES CO.,LTD
D0666D|Shenzhen Bus-Lan Technology Co., Ltd.
D0667B|Samsung Electronics Co.,Ltd
D06726|Hewlett Packard Enterprise
D067E5|Dell Inc.
D069C1|HUAWEI TECHNOLOGIES CO.,LTD
D069FF|Fiberhome Telecommunication Technologies Co.,LTD
D06B78|Apple, Inc.
D06DC8|HUAWEI TECHNOLOGIES CO.,LTD
D06DC9|Sagemcom Broadband SAS
D06EDE|Sagemcom Broadband SAS
D06F82|HUAWEI TECHNOLOGIES CO.,LTD
D071C4|zte corporation
D072DC|Cisco Systems, Inc
D07380|Huawei Device Co., Ltd.
D076E7|TP-LINK TECHNOLOGIES CO.,LTD.
D07714|Motorola Mobility LLC, a Lenovo Company
D07880|Fiberhome Telecommunication Technologies Co.,LTD
D07AB5|HUAWEI TECHNOLOGIES CO.,LTD
D07D33|Huawei Device Co., Ltd.
D07E01|Huawei Device Co., Ltd.
D07E28|Hewlett Packard
D07E35|Intel Corporate
D07FA0|Samsung Electronics Co.,Ltd
D07FC4|Ou Wei Technology Co.，Ltd. of Shenzhen City
D0817A|Apple, Inc.
D081C5|Juniper Networks
D082E8|Tuya Smart Inc.
D082EB|Tuya Smart Inc.
D084B0|Sagemcom Broadband SAS
D08543|Cisco Systems, Inc
D087E2|Samsung Electronics Co.,Ltd
D0880C|Apple, Inc.
D08999|APCON, Inc.
D08E79|Dell Inc.
D09168|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
D09282|Apple, Inc.
D0929E|Microsoft Corporation
D092FA|Fiberhome Telecommunication Technologies Co.,LTD
D093F8|Stonestreet One LLC
D09466|Dell Inc.
D094CF|HUAWEI TECHNOLOGIES CO.,LTD
D09AAF|Espressif Systems (Singapore) Pte. Ltd
D09C7A|Xiaomi Communications Co Ltd
D0A0BB|Shenzhen iComm Semiconductor CO.,LTD
D0A5A6|Cisco Systems, Inc
D0A637|Apple, Inc.
D0ABD5|Intel Corporate
D0AD08|HP Inc.
D0AE05|Xiaomi Communications Co Ltd
D0B128|Samsung Electronics Co.,Ltd
D0B1CA|Shenzhen Skyworth Digital Technology CO., Ltd
D0B324|Apple, Inc.
D0B33F|Shenzhen TINNO Mobile Technology Corp.
D0B45D|Huawei Device Co., Ltd.
D0BB61|zte corporation
D0BF9C|Hewlett Packard
D0C050|Apple, Inc.
D0C1B1|Samsung Electronics Co.,Ltd
D0C1B5|Dell Inc.
D0C1BF|Xiaomi Communications Co Ltd
D0C24E|Samsung Electronics Co.,Ltd
D0C282|Cisco Systems, Inc
D0C5D3|AzureWave Technology Inc.
D0C5F3|Apple, Inc.
D0C637|Intel Corporate
D0C65B|HUAWEI TECHNOLOGIES CO.,LTD
D0C67F|HUAWEI TECHNOLOGIES CO.,LTD
D0C730|zte corporation
D0C789|Cisco Systems, Inc
D0C7C0|TP-LINK TECHNOLOGIES CO.,LTD.
D0CDBF|LG Electronics
D0CEC0|Xiaomi Communications Co Ltd
D0CF0E|Sagemcom Broadband SAS
D0CF13|Espressif Inc.
D0D003|Samsung Electronics Co.,Ltd
D0D04B|HUAWEI TECHNOLOGIES CO.,LTD
D0D0FD|Cisco Systems, Inc
D0D23C|Apple, Inc.
D0D2B0|Apple, Inc.
D0D3E0|Hewlett Packard Enterprise
D0D49F|Apple, Inc.
D0D783|HUAWEI TECHNOLOGIES CO.,LTD
D0D7BE|HUAWEI TECHNOLOGIES CO.,LTD
D0DAD7|Apple, Inc.
D0DB32|Nokia Corporation
D0DC2C|Cisco Systems, Inc
D0DD49|Juniper Networks
D0DD7C|zte corporation
D0DF9A|Liteon Technology Corporation
D0DFC7|Samsung Electronics Co.,Ltd
D0E042|Cisco Systems, Inc
D0E140|Apple, Inc.
D0E581|Apple, Inc.
D0E782|AzureWave Technology Inc.
D0EA11|Routerboard.com
D0EC35|Cisco Systems, Inc
D0EF76|Espressif Inc.
D0EFC1|HUAWEI TECHNOLOGIES CO.,LTD
D0F3F5|Huawei Device Co., Ltd.
D0F405|Hon Hai Precision Industry Co., Ltd.
D0F4F7|Huawei Device Co., Ltd.
D0F520|KYOCERA Corporation
D0F76E|Shenzhen YOUHUA Technology Co., Ltd
D0F815|HUAWEI TECHNOLOGIES CO.,LTD
D0F88C|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
D0F8E7|Shenzhen Shutong Space Technology Co., Ltd
D0F928|zte corporation
D0F99B|zte corporation
D0FCCC|Samsung Electronics Co.,Ltd
D0FF98|HUAWEI TECHNOLOGIES CO.,LTD
D40068|Fiberhome Telecommunication Technologies Co.,LTD
D40129|Broadcom
D4016D|TP-LINK TECHNOLOGIES CO.,LTD.
D401C3|Routerboard.com
D404E6|Broadcom Limited
D404FF|Juniper Networks
D40592|Espressif Inc.
D40DAB|Shenzhen Cudy Technology Co., Ltd.
D40F9E|Apple, Inc.
D411A3|Samsung Electronics Co.,Ltd
D4126E|Apple, Inc.
D41368|Shenzhen Intellirocks Tech. Co. Ltd.
D41761|Xiaomi Communications Co Ltd
D41972|Hewlett Packard Enterprise
D41AD1|Zyxel Communications Corporation
D41D71|Palo Alto Networks
D4223F|Lenovo Mobile Communication Technology Ltd.
D4258B|Intel Corporate
D427FF|Sagemcom Broadband SAS
D42B6F|Cisco Systems, Inc
D42C44|Cisco Systems, Inc
D42CA6|Samsung Electronics Co.,Ltd
D42DCC|Apple, Inc.
D42F4B|Hon Hai Precision Industry Co.,LTD
D42FCA|Apple, Inc.
D43538|Beijing Xiaomi Mobile Software Co., Ltd
D437D7|zte corporation
D4389C|Sony Corporation
D43A2C|Google, Inc.
D43A2E|SHENZHEN MTC CO LTD
D43A2F|SHENZHEN MTC CO LTD
D43B04|Intel Corporate
D43B8A|Shenzhen Zhide technology Co., LTD
D43D7E|Micro-Star Int'l Co, Ltd
D43DF3|Zyxel Communications Corporation
D440F0|HUAWEI TECHNOLOGIES CO.,LTD
D4430E|Zhejiang Dahua Technology Co., Ltd.
D4438A|Beijing Xiaomi Mobile Software Co., Ltd
D44649|HUAWEI TECHNOLOGIES CO.,LTD
D446E1|Apple, Inc.
D4482D|Shenzhen Deejoy Lighting Technology Co.,Ltd.
D44C9C|Shenzhen YOOBAO Technology Co.Ltd
D44D77|Nokia
D44D9F|Shenzhen Skyworth Digital Technology CO., Ltd
D44F67|HUAWEI TECHNOLOGIES CO.,LTD
D45039|Sagemcom Broadband SAS
D4532A|Beijing Xiaomi Mobile Software Co., Ltd
D4548B|Intel Corporate
D455BE|SHENZHEN FAST TECHNOLOGIES CO.,LTD
D45763|Apple, Inc.
D45800|Fiberhome Telecommunication Technologies Co.,LTD
D45A3F|Juniper Networks
D45B51|Motorola Mobility LLC, a Lenovo Company
D45D42|Nokia Corporation
D45D64|ASUSTek COMPUTER INC.
D45DDF|PEGATRON CORPORATION
D45E89|Motorola Mobility LLC, a Lenovo Company
D45EEC|Beijing Xiaomi Electronics Co., Ltd.
D45F25|Shenzhen YOUHUA Technology Co., Ltd
D45F2C|zte corporation
D45F7A|HUAWEI TECHNOLOGIES CO.,LTD
D4612E|HUAWEI TECHNOLOGIES CO.,LTD
D46195|zte corporation
D4619D|Apple, Inc.
D461DA|Apple, Inc.
D462EA|HUAWEI TECHNOLOGIES CO.,LTD
D463C0|Apple, Inc.
D463C6|Motorola Mobility LLC, a Lenovo Company
D46624|Cisco Systems, Inc
D46663|Shenzhen Detran Technology Co.,Ltd.
D467E7|Fiberhome Telecommunication Technologies Co.,LTD
D4684D|Ruckus Wireless
D468AA|Apple, Inc.
D468BA|Shenzhen Sundray Technologies company Limited
D46A35|Cisco Systems, Inc
D46A6A|Hon Hai Precision Ind. Co.,Ltd.
D46AA8|HUAWEI TECHNOLOGIES CO.,LTD
D46BA6|HUAWEI TECHNOLOGIES CO.,LTD
D46D50|Cisco Systems, Inc
D46D6D|Intel Corporate
D46E0E|TP-LINK TECHNOLOGIES CO.,LTD.
D46E5C|HUAWEI TECHNOLOGIES CO.,LTD
D47226|zte corporation
D47327|HUAWEI TECHNOLOGIES CO.,LTD
D47415|Huawei Device Co., Ltd.
D476A0|Fortinet, Inc.
D476EA|zte corporation
D47798|Cisco Systems, Inc
D47856|Avaya Inc
D4789B|Cisco Systems, Inc
D47954|Huawei Device Co., Ltd.
D47AE2|Samsung Electronics Co.,Ltd
D47F35|Cisco Systems, Inc
D4808B|Seiko Epson Corporation
D481D7|Dell Inc.
D48304|SHENZHEN FAST TECHNOLOGIES CO.,LTD
D48409|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
D48564|Hewlett Packard
D487D8|Samsung Electronics Co.,Ltd
D48866|HUAWEI TECHNOLOGIES CO.,LTD
D48890|Samsung Electronics Co.,Ltd
D489C1|Ubiquiti Inc
D48A39|Samsung Electronics Co.,Ltd
D48A3B|HUNAN FN-LINK TECHNOLOGY LIMITED
D48AFC|Espressif Inc.
D48C49|Espressif Inc.
D48CB5|Cisco Systems, Inc
D48F33|Microsoft Corporation
D48FA2|Huawei Device Co., Ltd.
D4909C|Apple, Inc.
D4910F|Amazon Technologies Inc.
D49398|Nokia Corporation
D49400|HUAWEI TECHNOLOGIES CO.,LTD
D494A9|Intel Corporate
D494E8|HUAWEI TECHNOLOGIES CO.,LTD
D4955D|zte corporation
D4970B|Xiaomi Communications Co Ltd
D4996C|Juniper Networks
D49A20|Apple, Inc.
D49AF6|AzureWave Technology Inc.
D49CF4|Palo Alto Networks
D49D9D|Shenzhen Goodocom lnformation Technology Co.,Ltd.
D49DC0|Samsung Electronics Co.,Ltd
D49E05|zte corporation
D49F29|Fiberhome Telecommunication Technologies Co.,LTD
D49FDD|Huawei Device Co., Ltd.
D4A02A|Cisco Systems, Inc
D4A148|HUAWEI TECHNOLOGIES CO.,LTD
D4A254|HUAWEI TECHNOLOGIES CO.,LTD
D4A2CD|Dell Inc.
D4A33D|Apple, Inc.
D4A365|Xiaomi Communications Co Ltd
D4A3EB|Shenzhen iComm Semiconductor CO.,LTD
D4A651|Tuya Smart Inc.
D4A923|HUAWEI TECHNOLOGIES CO.,LTD
D4AB61|Intel Corporate
D4AD2D|Fiberhome Telecommunication Technologies Co.,LTD
D4AD71|Cisco Systems, Inc
D4ADBD|Cisco Systems, Inc
D4ADFC|Shenzhen Intellirocks Tech. Co. Ltd.
D4AE05|Samsung Electronics Co.,Ltd
D4AE52|Dell Inc.
D4B110|HUAWEI TECHNOLOGIES CO.,LTD
D4B4C0|Fortinet, Inc.
D4B5CD|Sagemcom Broadband SAS
D4B6C9|Nokia
D4B709|zte corporation
D4BBE6|Huawei Device Co., Ltd.
D4BD4F|Ruckus Wireless
D4BED7|Dell Inc.
D4BED9|Dell Inc.
D4BEDC|Roku, Inc
D4C19E|Ruckus Wireless
D4C1C8|zte corporation
D4C1FC|Nokia Corporation
D4C93C|Cisco Systems, Inc
D4C94B|Motorola Mobility LLC, a Lenovo Company
D4C9EF|Hewlett Packard
D4CA6D|Routerboard.com
D4CBAF|Nokia Corporation
D4CE40|Apple, Inc.
D4CFF9|Shenzhen SEI Robotics Co.,Ltd
D4D252|Intel Corporate
D4D2D6|FN-LINK TECHNOLOGY LIMITED
D4D4DA|Espressif Inc.
D4D51B|HUAWEI TECHNOLOGIES CO.,LTD
D4D6DF|TP-Link Systems Inc.
D4D748|Cisco Systems, Inc
D4D853|Intel Corporate
D4D892|HUAWEI TECHNOLOGIES CO.,LTD
D4DA21|Beijing Xiaomi Mobile Software Co., Ltd
D4DCCD|Apple, Inc.
D4E053|Hewlett Packard Enterprise
D4E22F|Roku, Inc
D4E33F|Nokia
D4E3C5|zte corporation
D4E6B7|Samsung Electronics Co.,Ltd
D4E853|Hangzhou Hikvision Digital Technology Co.,Ltd.
D4E880|Cisco Systems, Inc
D4E8B2|Samsung Electronics Co.,Ltd
D4E98A|Intel Corporate
D4E9F4|Espressif Inc.
D4EA0E|Avaya Inc
D4EB68|Cisco Systems, Inc
D4F0B4|Napco Security Technologies
D4F0C9|KYOCERA Document Solutions Inc.
D4F0EA|Beijing Xiaomi Mobile Software Co., Ltd
D4F242|Huawei Device Co., Ltd.
D4F32D|Intel Corporate
D4F46F|Apple, Inc.
D4F4BE|Palo Alto Networks
D4F547|Google, Inc.
D4F5EF|Hewlett Packard Enterprise
D4F756|zte corporation
D4F786|Fiberhome Telecommunication Technologies Co.,LTD
D4F7D5|Sony Interactive Entertainment Inc.
D4F829|Sagemcom Broadband SAS
D4F98D|Espressif Inc.
D4F9A1|HUAWEI TECHNOLOGIES CO.,LTD
D4FB8E|Apple, Inc.
D4FC13|Fiberhome Telecommunication Technologies Co.,LTD
D4FF1A|Apple, Inc.
D8004D|Apple, Inc.
D801D0|HUAWEI TECHNOLOGIES CO.,LTD
D8028A|Shenzhen YOUHUA Technology Co., Ltd
D802C0|Extreme Networks, Inc.
D806D1|Honeywell Fire System (Shanghai) Co,. Ltd.
D807B6|TP-LINK TECHNOLOGIES CO.,LTD.
D80831|Samsung Electronics Co.,Ltd
D8097F|zte corporation
D80A60|HUAWEI TECHNOLOGIES CO.,LTD
D80AE6|zte corporation
D80B9A|Samsung Electronics Co.,Ltd
D80D17|TP-LINK TECHNOLOGIES CO.,LTD.
D80F99|Hon Hai Precision Ind. Co.,Ltd.
D80FB5|SHENZHEN ULTRAEASY TECHNOLOGY CO LTD
D8109F|HUAWEI TECHNOLOGIES CO.,LTD
D8132A|Espressif Inc.
D814DF|TCL King Electrical Appliances (Huizhou) Co., Ltd
D8150D|TP-LINK TECHNOLOGIES CO.,LTD.
D818D3|Juniper Networks
D81BB5|HUAWEI TECHNOLOGIES CO.,LTD
D81C79|Apple, Inc.
D81D72|Apple, Inc.
D81F12|Tuya Smart Inc.
D820A2|HUAWEI TECHNOLOGIES CO.,LTD
D824BD|Cisco Systems, Inc
D82918|HUAWEI TECHNOLOGIES CO.,LTD
D829F8|HUAWEI TECHNOLOGIES CO.,LTD
D82A7E|Nokia Corporation
D82D9B|Shenzhen G.Credit Communication Technology Co., Ltd
D83062|Apple, Inc.
D8312C|zte corporation
D83134|Roku, Inc
D83139|zte corporation
D831CF|Samsung Electronics Co.,Ltd
D83214|Tenda Technology Co.,Ltd.Dongguan branch
D8325A|Shenzhen YOUHUA Technology Co., Ltd
D832E3|Xiaomi Communications Co Ltd
D833B7|Sagemcom Broadband SAS
D834D1|Shenzhen Orange Digital Technology Co.,Ltd
D8365F|Intelbras
D8373B|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
D837BE|SHENZHEN GONGJIN ELECTRONICS CO.,LT
D8380D|SHENZHEN IP-COM Network Co.,Ltd
D838FC|Ruckus Wireless
D83ADD|Raspberry Pi Trading Ltd
D83BBF|Intel Corporate
D83BDA|Espressif Inc.
D83C69|Shenzhen TINNO Mobile Technology Corp.
D83DCC|shenzhen UDD Technologies,co.,Ltd
D84008|HUAWEI TECHNOLOGIES CO.,LTD
D843AE|Micro-Star INTL CO., LTD.
D84489|TP-Link Systems Inc
D846CE|Apple, Inc.
D84732|TP-LINK TECHNOLOGIES CO.,LTD.
D847BB|Huawei Device Co., Ltd.
D8490B|HUAWEI TECHNOLOGIES CO.,LTD
D8492F|CANON INC.
D84A2B|zte corporation
D84C90|Apple, Inc.
D84FB8|LG ELECTRONICS
D850E6|ASUSTek COMPUTER INC.
D8539A|Juniper Networks
D853AD|Cisco Meraki
D853BC|Lenovo Information Products (Shenzhen)Co.,Ltd
D85437|HUAWEI TECHNOLOGIES CO.,LTD
D854A2|Extreme Networks, Inc.
D854F2|Huawei Device Co., Ltd.
D85575|Samsung Electronics Co.,Ltd
D855A3|zte corporation
D857EF|Samsung Electronics Co.,Ltd
D85982|HUAWEI TECHNOLOGIES CO.,LTD
D85B22|Shenzhen Hohunet Technology Co., Ltd
D85B2A|Samsung Electronics Co.,Ltd
D85D4C|TP-LINK TECHNOLOGIES CO.,LTD.
D85DE2|Hon Hai Precision Ind. Co.,Ltd.
D85ED3|GIGA-BYTE TECHNOLOGY CO.,LTD.
D862CA|Cisco Systems, Inc
D8630D|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
D86375|Xiaomi Communications Co Ltd
D8638C|Shenzhen Dttek Technology Co., Ltd.
D866C6|Shenzhen Daystar Technology Co.,ltd
D867D3|Huawei Device Co., Ltd.
D867D9|Cisco Systems, Inc
D86852|HUAWEI TECHNOLOGIES CO.,LTD
D868A0|Samsung Electronics Co.,Ltd
D868C3|Samsung Electronics Co.,Ltd
D86BFC|zte corporation
D86C63|Google, Inc.
D86CE9|Sagemcom Broadband SAS
D86D17|HUAWEI TECHNOLOGIES CO.,LTD
D87154|Samsung Electronics Co.,Ltd
D87157|Lenovo Mobile Communication Technology Ltd.
D87475|Apple, Inc.
D87495|zte corporation
D874DF|HUAWEI TECHNOLOGIES CO.,LTD
D87533|Nokia Corporation
D876AE|HUAWEI TECHNOLOGIES CO.,LTD
D8778B|Intelbras
D87988|Hon Hai Precision Ind. Co.,Ltd.
D87D7F|Sagemcom Broadband SAS
D880DC|Huawei Device Co., Ltd.
D88466|Extreme Networks, Inc.
D8855E|zte corporation
D885AC|Espressif Inc.
D88863|HUAWEI TECHNOLOGIES CO.,LTD
D88ADC|Huawei Device Co., Ltd.
D88C73|zte corporation
D88C79|Google, Inc.
D88F76|Apple, Inc.
D890E8|Samsung Electronics Co.,Ltd
D8912A|Zyxel Communications Corporation
D89333|HUAWEI TECHNOLOGIES CO.,LTD
D893D4|Xiaomi Communications Co Ltd
D89403|Hewlett Packard Enterprise
D89695|Apple, Inc.
D897BA|PEGATRON CORPORATION
D89A0D|zte corporation
D89AC1|Nokia
D89B3B|HUAWEI TECHNOLOGIES CO.,LTD
D89C67|Hon Hai Precision Ind. Co.,Ltd.
D89D13|Samsung Electronics Co.,Ltd
D89D67|Hewlett Packard
D89E3F|Apple, Inc.
D89E61|Huawei Device Co., Ltd.
D89ED4|Fiberhome Telecommunication Technologies Co.,LTD
D89EF3|Dell Inc.
D8A01D|Espressif Inc.
D8A0E8|zte corporation
D8A25E|Apple, Inc.
D8A35C|Samsung Electronics Co.,Ltd
D8A491|Huawei Device Co., Ltd.
D8A756|Sagemcom Broadband SAS
D8A8C8|zte corporation
D8AFF1|Panasonic Appliances Company
D8B053|Xiaomi Communications Co Ltd
D8B061|SHENZHEN WENXUN TECHNOLOGY CO.,LTD
D8B122|Juniper Networks
D8B12A|Panasonic Mobile Communications Co.,Ltd.
D8B190|Cisco Systems, Inc
D8B1DE|Hewlett Packard Enterprise
D8B249|Huawei Device Co., Ltd.
D8B2AA|zte corporation
D8B370|Ubiquiti Inc
D8BB2C|Apple, Inc.
D8BBC1|Micro-Star INTL CO., LTD.
D8BC38|Espressif Inc.
D8BC59|Shenzhen DAPU Microelectronics Co., Ltd
D8BE1F|Apple, Inc.
D8BE65|Amazon Technologies Inc.
D8BF42|Intel Corporate
D8BFC0|Espressif Inc.
D8C0A6|AzureWave Technology Inc.
D8C262|Ubiquiti Inc
D8C497|Quanta Computer Inc.
D8C4E9|Samsung Electronics Co.,Ltd
D8C771|HUAWEI TECHNOLOGIES CO.,LTD
D8C7C8|Hewlett Packard Enterprise
D8C80C|Tuya Smart Inc.
D8C960|Huawei Device Co., Ltd.
D8CB8A|Micro-Star INTL CO., LTD.
D8CC98|Huawei Device Co., Ltd.
D8CE3A|Xiaomi Communications Co Ltd
D8CF61|Sagemcom Broadband SAS
D8CF9C|Apple, Inc.
D8CFBF|Motorola Mobility LLC, a Lenovo Company
D8D090|Dell Inc.
D8D1CB|Apple, Inc.
D8D385|Hewlett Packard
D8D43C|Sony Corporation
D8D668|Tuya Smart Inc.
D8D775|Sagemcom Broadband SAS
D8D866|SHENZHEN TOZED TECHNOLOGIES CO.,LTD.
D8DAF1|HUAWEI TECHNOLOGIES CO.,LTD
D8DC40|Apple, Inc.
D8DE3A|Apple, Inc.
D8E016|Extreme Networks, Inc.
D8E0E1|Samsung Electronics Co.,Ltd
D8E2DF|Microsoft Corporation
D8E374|Xiaomi Communications Co Ltd
D8E593|Apple, Inc.
D8E72F|Chipsea Technologies (Shenzhen) Corp.
D8E844|zte corporation
D8EB46|Google, Inc.
D8ECE5|Zyxel Communications Corporation
D8EDA8|Xiaomi Communications Co Ltd
D8EF42|Huawei Device Co., Ltd.
D8EFCD|Nokia Solutions and Networks GmbH & Co. KG
D8F12E|TP-Link Systems Inc.
D8F15B|Espressif Inc.
D8F2CA|Intel Corporate
D8F3BC|Liteon Technology Corporation
D8F507|Fiberhome Telecommunication Technologies Co.,LTD
D8F883|Intel Corporate
D8FBD6|Amazon Technologies Inc.
D8FC92|Tuya Smart Inc.
D8FC93|Intel Corporate
D8FEE3|D-Link International
D8FFC3|Shenzhen 3SNIC information technology company Limited
DC0077|TP-LINK TECHNOLOGIES CO.,LTD.
DC028E|zte corporation
DC0539|Cisco Systems, Inc
DC0675|Espressif Inc.
DC07F8|Hangzhou Hikvision Digital Technology Co.,Ltd.
DC080F|Apple, Inc.
DC094C|HUAWEI TECHNOLOGIES CO.,LTD
DC0A69|Espressif Inc.
DC0B09|Cisco Systems, Inc
DC0B34|LG Electronics (Mobile Communications)
DC0C5C|Apple, Inc.
DC0D30|Shenzhen Feasycom Technology Co., Ltd.
DC0E96|Palo Alto Networks
DC0EA1|COMPAL INFORMATION (KUNSHAN) CO., LTD.
DC1057|Apple, Inc.
DC121D|HUAWEI TECHNOLOGIES CO.,LTD
DC16B2|HUAWEI TECHNOLOGIES CO.,LTD
DC1A01|Ecoliv Technology ( Shenzhen ) Ltd.
DC1BA1|Intel Corporate
DC1ED5|Espressif Inc.
DC2148|Intel Corporate
DC215C|Intel Corporate
DC21E2|HUAWEI TECHNOLOGIES CO.,LTD
DC233B|Extreme Networks, Inc.
DC2727|Huawei Device Co., Ltd.
DC293A|Shenzhen Nuoshi Technology Co., LTD.
DC2B2A|Apple, Inc.
DC2B61|Apple, Inc.
DC2C6E|Routerboard.com
DC2D3C|Huawei Device Co., Ltd.
DC3052|zte corporation
DC333D|Huawei Device Co., Ltd.
DC35F1|Positivo Tecnologia S.A.
DC3642|zte corporation
DC3714|Apple, Inc.
DC38E1|Juniper Networks
DC3979|Cisco Systems, Inc
DC3A5E|Roku, Inc.
DC3EF8|Nokia Corporation
DC415F|Apple, Inc.
DC41A9|Intel Corporate
DC41E5|Shenzhen Zhixin Data Service Co., Ltd.
DC42C8|Huawei Device Co., Ltd.
DC44B6|Samsung Electronics Co.,Ltd
DC4546|Intel Corporate
DC45B8|Apple, Inc.
DC4628|Intel Corporate
DC4A3E|Hewlett Packard
DC4BDD|Shenzhen SuperElectron Technology Co.,Ltd.
DC4BFE|Shenzhen Belon Technology CO.,LTD
DC4EF4|Shenzhen MTN Electronics CO., Ltd
DC4F22|Espressif Inc.
DC5193|zte corporation
DC5285|Apple, Inc.
DC5360|Intel Corporate
DC537C|Compal Broadband Networks, Inc.
DC5392|Apple, Inc.
DC5475|Espressif Inc.
DC54D7|Amazon Technologies Inc.
DC55B1|Espressif Inc.
DC56E6|Shenzhen Bococom Technology Co.,LTD
DC56E7|Apple, Inc.
DC5D89|Cisco Systems, Inc
DC6180|HUAWEI TECHNOLOGIES CO.,LTD
DC621F|HUAWEI TECHNOLOGIES CO.,LTD
DC6279|TP-Link Systems Inc
DC64B8|Shenzhen JingHanDa Electronics Co.Ltd
DC663A|Apacer Technology Inc.
DC6672|Samsung Electronics Co.,Ltd
DC680C|Hewlett Packard Enterprise
DC6880|zte corporation
DC69E2|Samsung Electronics Co.,Ltd
DC6AE7|Xiaomi Communications Co Ltd
DC6B1B|Huawei Device Co., Ltd.
DC6DBC|Apple, Inc.
DC7137|zte corporation
DC7144|SAMSUNG ELECTRO MECHANICS CO., LTD.
DC7196|Intel Corporate
DC71D0|Apple, Inc.
DC729B|HUAWEI TECHNOLOGIES CO.,LTD
DC7385|Huawei Device Co., Ltd.
DC74A8|Samsung Electronics Co.,Ltd
DC774C|Cisco Systems, Inc
DC7794|Huawei Device Co., Ltd.
DC7B94|Cisco Systems, Inc
DC7E1D|HUAWEI TECHNOLOGIES CO.,LTD
DC7EF5|HUAWEI TECHNOLOGIES CO.,LTD
DC8084|Apple, Inc.
DC83BF|Seiko Epson Corporation
DC8403|shenzhen trolink Technology Co.,Ltd
DC84E9|Shenzhen Qihoo Intelligent Technology Co.,Ltd
DC85DE|AzureWave Technology Inc.
DC868D|HUAWEI TECHNOLOGIES CO.,LTD
DC86D8|Apple, Inc.
DC87F8|Samsung Electronics Co.,Ltd
DC8983|Samsung Electronics Co.,Ltd
DC8B28|Intel Corporate
DC8C37|Cisco Systems, Inc
DC8D8A|Nokia Solutions and Networks GmbH & Co. KG
DC8E6D|Huawei Device Co., Ltd.
DC9009|Intel Corporate
DC9088|HUAWEI TECHNOLOGIES CO.,LTD
DC9166|Huawei Device Co., Ltd.
DC91BF|Amazon Technologies Inc.
DC9272|Sagemcom Broadband SAS
DC9396|Apple, Inc.
DC9566|Apple, Inc.
DC97BA|Intel Corporate
DC97E6|Sagemcom Broadband SAS
DC9840|Microsoft Corporation
DC9914|HUAWEI TECHNOLOGIES CO.,LTD
DC9B9C|Apple, Inc.
DC9C99|HUAWEI TECHNOLOGIES CO.,LTD
DC9C9F|Shenzhen YOUHUA Technology Co., Ltd
DC9DED|Samsung Electronics Co.,Ltd
DC9E8F|Apple, Inc.
DC9FA4|Nokia Corporation
DC9FDB|Ubiquiti Inc
DCA0D0|Amazon Technologies Inc.
DCA120|Nokia
DCA266|Hon Hai Precision Ind. Co.,Ltd.
DCA313|Shenzhen Changjin Communication Technology Co.,Ltd
DCA333|Shenzhen YOUHUA Technology Co., Ltd
DCA4CA|Apple, Inc.
DCA5F4|Cisco Systems, Inc
DCA632|Raspberry Pi Trading Ltd
DCA782|HUAWEI TECHNOLOGIES CO.,LTD
DCA904|Apple, Inc.
DCA971|Intel Corporate
DCAA43|Shenzhen Terca Information Technology Co., Ltd.
DCAEEB|Ruckus Wireless
DCB082|Nokia
DCB131|SHENZHEN HUARUIAN TECHNOLOGY CO.,LTD
DCB347|SHENZHEN FAST TECHNOLOGIES CO.,LTD
DCB3B4|Honeywell Environmental & Combustion Controls (Tianjin) Co., Ltd.
DCB4C4|Microsoft XCG
DCB4D9|Espressif Inc.
DCB54F|Apple, Inc.
DCB72E|Xiaomi Communications Co Ltd
DCB7AC|Hewlett Packard Enterprise
DCB808|Extreme Networks, Inc.
DCB87D|Hewlett Packard Enterprise
DCBB3D|Extreme Networks, Inc.
DCBBFA|Cisco Meraki
DCBFE9|Motorola Mobility LLC, a Lenovo Company
DCC0DB|Shenzhen Kaiboer Technology Co., Ltd.
DCC2C9|CANON INC.
DCC49C|Samsung Electronics Co.,Ltd
DCC64B|HUAWEI TECHNOLOGIES CO.,LTD
DCC793|Nokia Corporation
DCCCE6|Samsung Electronics Co.,Ltd
DCCD2F|Seiko Epson Corporation
DCCEBC|Shenzhen JSR Technology Co.,Ltd.
DCCEC1|Cisco Systems, Inc
DCCF96|Samsung Electronics Co.,Ltd
DCD26A|Hangzhou Hikvision Digital Technology Co.,Ltd.
DCD2FC|HUAWEI TECHNOLOGIES CO.,LTD
DCD2FD|HUAWEI TECHNOLOGIES CO.,LTD
DCD3A2|Apple, Inc.
DCD444|Huawei Device Co., Ltd.
DCD7A0|Huawei Device Co., Ltd.
DCD83B|Cisco Systems, Inc
DCD87F|Shenzhen JoinCyber Telecom Equipment Ltd
DCD916|HUAWEI TECHNOLOGIES CO.,LTD
DCD9AE|Nokia Shanghai Bell Co., Ltd.
DCDA0C|Espressif Inc.
DCDB27|Huawei Device Co., Ltd.
DCDCC3|Extreme Networks, Inc.
DCDCE2|Samsung Electronics Co.,Ltd
DCDE4B|SHENZHEN TRANSCHAN TECHNOLOGY LIMITED
DCDFD6|zte corporation
DCE1AD|Shenzhen Wintop Photoelectric Technology Co., Ltd
DCE541|Apple, Inc.
DCE55B|Google, Inc.
DCE5D8|zte corporation
DCE650|Extreme Networks, Inc.
DCE838|CK Telecom (Shenzhen) Limited
DCEAE7|D-Link Corporation
DCEB4D|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
DCEB94|Cisco Systems, Inc
DCED83|Beijing Xiaomi Mobile Software Co., Ltd
DCEE06|HUAWEI TECHNOLOGIES CO.,LTD
DCEF09|NETGEAR
DCEF80|HUAWEI TECHNOLOGIES CO.,LTD
DCF110|Nokia Corporation
DCF401|Dell Inc.
DCF4CA|Apple, Inc.
DCF505|AzureWave Technology Inc.
DCF719|Cisco Systems, Inc
DCF756|Samsung Electronics Co.,Ltd
DCF8B9|zte corporation
DCFB48|Intel Corporate
DCFE07|PEGATRON CORPORATION
DCFE18|TP-LINK TECHNOLOGIES CO.,LTD.
E00084|HUAWEI TECHNOLOGIES CO.,LTD
E0036B|Samsung Electronics Co.,Ltd
E00370|ShenZhen Continental Wireless Technology Co., Ltd.
E005C5|TP-LINK TECHNOLOGIES CO.,LTD.
E00630|HUAWEI TECHNOLOGIES CO.,LTD
E006E6|Hon Hai Precision Ind. Co.,Ltd.
E0071B|Hewlett Packard Enterprise
E009BF|SHENZHEN TONG BO WEI TECHNOLOGY Co.,LTD
E00AF6|Liteon Technology Corporation
E00CE5|HUAWEI TECHNOLOGIES CO.,LTD
E00DEE|Huawei Device Co., Ltd.
E00ECE|Fiberhome Telecommunication Technologies Co.,LTD
E00EDA|Cisco Systems, Inc
E0107F|Ruckus Wireless
E01283|Shenzhen Fanzhuo Communication Technology Co., Lt
E0150B|HUAWEI TECHNOLOGIES CO.,LTD
E01877|FUJITSU LIMITED
E0191D|HUAWEI TECHNOLOGIES CO.,LTD
E01954|zte corporation
E01ADF|Google, Inc.
E01C41|Extreme Networks, Inc.
E01CFC|D-Link International
E01F2B|Nokia Solutions and Networks GmbH & Co. KG
E01F6A|Huawei Device Co., Ltd.
E01F88|Xiaomi Communications Co Ltd
E01FED|Nokia Shanghai Bell Co., Ltd.
E01FFC|Motorola (Wuhan) Mobility Technologies Communication Co., Ltd.
E023FF|Fortinet, Inc.
E0247F|HUAWEI TECHNOLOGIES CO.,LTD
E02481|HUAWEI TECHNOLOGIES CO.,LTD
E02611|Apple, Inc.
E0280A|TP-Link Systems Inc.
E02861|HUAWEI TECHNOLOGIES CO.,LTD
E028B1|Shenzhen Skyworth Digital Technology CO., Ltd
E02A25|Shenzhen Intellirocks Tech. Co. Ltd.
E02A66|Cisco Systems, Inc
E02AE6|Fiberhome Telecommunication Technologies Co.,LTD
E02B96|Apple, Inc.
E02BE9|Intel Corporate
E02CB2|Lenovo Mobile Communication (Wuhan) Company Limited
E02E0B|Intel Corporate
E02E3F|Huawei Device Co., Ltd.
E02EFE|Zhejiang Dahua Technology Co., Ltd.
E02F6D|Cisco Systems, Inc
E030F9|Juniper Networks
E0338E|Apple, Inc.
E03676|HUAWEI TECHNOLOGIES CO.,LTD
E0383F|zte corporation
E03AAA|Intel Corporate
E03C5B|SHENZHEN JIAXINJIE ELECTRON CO.,LTD
E03E44|Broadcom
E03F49|ASUSTek COMPUTER INC.
E04007|Huawei Device Co., Ltd.
E04027|Huawei Device Co., Ltd.
E04102|zte corporation
E043DB|Shenzhen ViewAt Technology Co.,Ltd.
E0469A|NETGEAR
E046EE|NETGEAR
E04BA6|HUAWEI TECHNOLOGIES CO.,LTD
E04E5D|HUAWEI TECHNOLOGIES CO.,LTD
E04F95|Sagemcom Broadband SAS
E0508B|Zhejiang Dahua Technology Co., Ltd.
E0553D|Cisco Meraki
E05A1B|Espressif Inc.
E05F45|Apple, Inc.
E05FB9|Cisco Systems, Inc
E0604A|Fiberhome Telecommunication Technologies Co.,LTD
E06267|Xiaomi Communications Co Ltd
E063DA|Ubiquiti Inc
E063E5|Sony Corporation
E06678|Apple, Inc.
E067B3|Shenzhen C-Data Technology Co., Ltd.
E06995|PEGATRON CORPORATION
E069BA|Cisco Systems, Inc
E06A05|Shenzhen YOUHUA Technology Co., Ltd
E06A1B|Shenzhen Zidoo Technology Co., Ltd.
E06C4E|Shenzhen TINNO Mobile Technology Corp.
E06CC5|Huawei Device Co., Ltd.
E06D17|Apple, Inc.
E070EA|HP Inc.
E0720A|Shenzhen SuperElectron Technology Co.,Ltd.
E07256|Intel Corporate
E072A1|Espressif Inc.
E073E7|HP Inc.
E0757D|Motorola Mobility LLC, a Lenovo Company
E07726|Huawei Device Co., Ltd.
E07C13|zte corporation
E0806B|Xiaomi Communications Co Ltd
E0859A|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
E0897E|Apple, Inc.
E0899D|Cisco Systems, Inc
E08C3C|Cisco Systems, Inc
E08CFE|Espressif Inc.
E08E3C|Aztech Electronics Pte Ltd
E08F4C|Intel Corporate
E091F5|NETGEAR
E0925C|Apple, Inc.
E09467|Intel Corporate
E096E8|Fiberhome Telecommunication Technologies Co.,LTD
E09796|HUAWEI TECHNOLOGIES CO.,LTD
E09806|Espressif Inc.
E09861|Motorola Mobility LLC, a Lenovo Company
E09971|Samsung Electronics Co.,Ltd
E09D13|Samsung Electronics Co.,Ltd
E09D1E|zte corporation
E09D31|Intel Corporate
E09E2D|Nokia
E0A129|Extreme Networks, Inc.
E0A1CE|zte corporation
E0A366|Motorola Mobility LLC, a Lenovo Company
E0A3AC|HUAWEI TECHNOLOGIES CO.,LTD
E0A447|zte corporation
E0A498|SHENZHEN ORFA TECH CO.,LTD
E0A670|Nokia Corporation
E0AA96|Samsung Electronics Co.,Ltd
E0ACCB|Apple, Inc.
E0ACF1|Cisco Systems, Inc
E0AD9B|HUAWEI TECHNOLOGIES CO.,LTD
E0AEA2|HUAWEI TECHNOLOGIES CO.,LTD
E0B2F1|FN-LINK TECHNOLOGY LIMITED
E0B52D|Apple, Inc.
E0B55F|Apple, Inc.
E0B655|Beijing Xiaomi Electronics Co., Ltd.
E0B668|zte corporation
E0B72E|ShenZhen Qualmesh Technology Co.,Ltd.
E0B94D|SHENZHEN BILIAN ELECTRONIC CO.，LTD
E0B98A|Shenzhen Taike industrial automation company,Ltd
E0B9A5|AzureWave Technology Inc.
E0B9BA|Apple, Inc.
E0BA78|Apple, Inc.
E0BAAD|Hangzhou Hikvision Digital Technology Co.,Ltd.
E0BB9E|Seiko Epson Corporation
E0BDA0|Apple, Inc.
E0BFB2|Apple, Inc.
E0C0D1|CK Telecom (Shenzhen) Limited
E0C250|NETGEAR
E0C264|Intel Corporate
E0C29E|zte corporation
E0C377|Samsung Electronics Co.,Ltd
E0C3EA|Apple, Inc.
E0C3F3|zte corporation
E0C767|Apple, Inc.
E0C86A|SHENZHEN TW-SCIE Co., Ltd
E0C932|Intel Corporate
E0C97A|Apple, Inc.
E0CA3C|Hangzhou Hikvision Digital Technology Co.,Ltd.
E0CA4D|Shenzhen Unistar Communication Co.,LTD
E0CB19|Nokia
E0CB1D|Amazon Technologies Inc.
E0CB4E|ASUSTek COMPUTER INC.
E0CB56|Shenzhen iComm Semiconductor CO.,LTD
E0CBBC|Cisco Meraki
E0CBEE|Samsung Electronics Co.,Ltd
E0CC7A|HUAWEI TECHNOLOGIES CO.,LTD
E0CCF8|Xiaomi Communications Co Ltd
E0CDB8|Huawei Device Co., Ltd.
E0D045|Intel Corporate
E0D083|Samsung Electronics Co.,Ltd
E0D173|Cisco Systems, Inc
E0D362|TP-Link Systems Inc.
E0D38E|Chipsea Technologies (Shenzhen) Crop.
E0D3B4|Cisco Meraki
E0D462|Huawei Device Co., Ltd.
E0D464|Intel Corporate
E0D491|Cisco Systems, Inc
E0D4E8|Intel Corporate
E0D55D|Intel Corporate
E0D55E|GIGA-BYTE TECHNOLOGY CO.,LTD.
E0D848|Dell Inc.
E0DA90|HUAWEI TECHNOLOGIES CO.,LTD
E0DAD7|zte corporation
E0DB10|Samsung Electronics Co.,Ltd
E0DB55|Dell Inc.
E0DCFF|Xiaomi Communications Co Ltd
E0DF13|Hangzhou Hikvision Digital Technology Co.,Ltd.
E0E0FC|Huawei Device Co., Ltd.
E0E1A9|Shenzhen Four Seas Global Link Network Technology Co., Ltd.
E0E258|Intel Corporate
E0E2E6|Espressif Inc.
E0E37C|Huawei Device Co., Ltd.
E0E8E6|Shenzhen C-Data Technology Co., Ltd.
E0EB40|Apple, Inc.
E0EDC7|Shenzhen Friendcom Technology Development Co., Ltd
E0EE1B|Panasonic Automotive Systems Company of America
E0F330|HUAWEI TECHNOLOGIES CO.,LTD
E0F442|Huawei Device Co., Ltd.
E0F5C6|Apple, Inc.
E0F62D|Juniper Networks
E0F678|Fiberhome Telecommunication Technologies Co.,LTD
E0F728|Amazon Technologies Inc.
E0F847|Apple, Inc.
E4013B|Apple, Inc.
E4029B|Intel Corporate
E406E0|HUAWEI TECHNOLOGIES CO.,LTD
E4072B|Huawei Device Co., Ltd.
E407B4|HUAWEI TECHNOLOGIES CO.,LTD
E40A16|HUAWEI TECHNOLOGIES CO.,LTD
E40D36|Intel Corporate
E40EEE|HUAWEI TECHNOLOGIES CO.,LTD
E41088|Samsung Electronics Co.,Ltd
E4115B|Hewlett Packard
E41218|ShenZhen Rapoo Technology Co., Ltd.
E4121D|Samsung Electronics Co.,Ltd
E4135C|Cisco Systems, Inc
E41613|Extreme Networks, Inc.
E4186B|Zyxel Communications Corporation
E419C1|HUAWEI TECHNOLOGIES CO.,LTD
E41B43|Beijing Xiaomi Mobile Software Co., Ltd
E41F7B|Cisco Systems, Inc
E41FD5|Intel Corporate
E4233C|Juniper Networks
E42354|SHENZHEN FUZHI SOFTWARE TECHNOLOGY CO.,LTD
E4246C|Zhejiang Dahua Technology Co., Ltd.
E425E7|Apple, Inc.
E4268B|Huawei Device Co., Ltd.
E426D5|Motorola Mobility LLC, a Lenovo Company
E4293D|Shenzhen Sy-Fiber Optical Communication Technology.Co.,Ltd
E42AAC|Microsoft Corporation
E42B34|Apple, Inc.
E42B79|Nokia
E42F26|Fiberhome Telecommunication Technologies Co.,LTD
E42F37|Apple, Inc.
E432CB|Samsung Electronics Co.,Ltd
E43493|HUAWEI TECHNOLOGIES CO.,LTD
E435C8|HUAWEI TECHNOLOGIES CO.,LTD
E4379F|Cisco Systems, Inc
E43819|Shenzhen Hi-Link Electronic CO.,Ltd.
E4387E|Cisco Systems, Inc
E43883|Ubiquiti Inc
E43A6E|Shenzhen Zeroone Technology CO.,LTD
E43A85|Cisco Systems, Inc
E43D1A|Broadcom Limited
E43EC6|HUAWEI TECHNOLOGIES CO.,LTD
E440E2|Samsung Electronics Co.,Ltd
E44122|OnePlus Technology (Shenzhen) Co., Ltd
E44164|Nokia
E442A6|Intel Corporate
E4434B|Dell Inc.
E44389|Apple, Inc.
E443CF|TP-Link Systems Inc.
E444E5|Extreme Networks, Inc.
E44519|Beijing Xiaomi Electronics Co.,Ltd
E446B0|Fujitsu Client Computing Limited
E446DA|Xiaomi Communications Co Ltd
E447B3|zte corporation
E448C7|Cisco SPVTG
E44AE0|Intel Corporate
E44C6C|Shenzhen Guo Wei Electronic Co,. Ltd.
E44E12|zte corporation
E44E2D|Cisco Systems, Inc
E44E76|CHAMPIONTECH ENTERPRISE (SHENZHEN) INC
E450EB|Apple, Inc.
E45341|Apple, Inc.
E454E5|Huawei Device Co., Ltd.
E454E8|Dell Inc.
E455A8|Cisco Meraki
E458B8|Samsung Electronics Co.,Ltd
E458E7|Samsung Electronics Co.,Ltd
E45BB3|zte corporation
E45D37|Juniper Networks
E45D52|Avaya Inc
E45D75|Samsung Electronics Co.,Ltd
E45E1B|Google, Inc.
E45E37|Intel Corporate
E45ECC|Juniper Networks
E45F01|Raspberry Pi Trading Ltd
E46017|Intel Corporate
E4604D|zte corporation
E461F4|shenzhen worldelite electronics co., LTD
E462C4|Cisco Systems, Inc
E46564|SHENZHEN KTC TECHNOLOGY CO.,LTD
E465B8|Espressif Inc.
E466AB|zte corporation
E468A3|HUAWEI TECHNOLOGIES CO.,LTD
E46F13|D-Link International
E47010|Apple, Inc.
E470B8|Intel Corporate
E4729D|Nokia Shanghai Bell Co., Ltd.
E472E2|HUAWEI TECHNOLOGIES CO.,LTD
E47305|Shenzhen INVT Electric CO.,Ltd
E47319|Huawei Device Co., Ltd.
E47450|Shenzhen Grandsun Electronic Co.,Ltd.
E47684|Apple, Inc.
E47723|zte corporation
E47727|HUAWEI TECHNOLOGIES CO.,LTD
E4793F|Juniper Networks
E47CF9|Samsung Electronics Co.,Ltd
E47DBD|Samsung Electronics Co.,Ltd
E47E66|HUAWEI TECHNOLOGIES CO.,LTD
E47E9A|zte corporation
E47F3C|zte corporation
E47FB2|FUJITSU LIMITED
E48184|Nokia
E481B3|Shenzhen ACT Industrial Co.,Ltd.
E48210|HUAWEI TECHNOLOGIES CO.,LTD
E48326|HUAWEI TECHNOLOGIES CO.,LTD
E484D3|Xiaomi Communications Co Ltd
E489CA|Cisco Systems, Inc
E48B7F|Apple, Inc.
E48D8C|Routerboard.com
E48EC5|HUAWEI TECHNOLOGIES CO.,LTD
E48F1D|Huawei Device Co., Ltd.
E4902A|HUAWEI TECHNOLOGIES CO.,LTD
E4907E|Motorola Mobility LLC, a Lenovo Company
E490FD|Apple, Inc.
E49282|Samsung Electronics Co.,Ltd
E492FB|Samsung Electronics Co.,Ltd
E498D1|Microsoft Mobile Oy
E498D6|Apple, Inc.
E4995F|HUAWEI TECHNOLOGIES CO.,LTD
E49A79|Apple, Inc.
E49ADC|Apple, Inc.
E49C67|Apple, Inc.
E49F7D|Samsung Electronics Co.,Ltd
E4A41C|Cisco Systems, Inc
E4A430|Samsung Electronics Co.,Ltd
E4A471|Intel Corporate
E4A749|Palo Alto Networks
E4A7A0|Intel Corporate
E4A7C5|HUAWEI TECHNOLOGIES CO.,LTD
E4A7D0|HUAWEI TECHNOLOGIES CO.,LTD
E4A8B6|HUAWEI TECHNOLOGIES CO.,LTD
E4A8DF|COMPAL INFORMATION (KUNSHAN) CO., LTD.
E4AA5D|Cisco Systems, Inc
E4AAE4|Xiaomi Communications Co Ltd
E4AAEA|Liteon Technology Corporation
E4AEE4|Tuya Smart Inc.
E4B021|Samsung Electronics Co.,Ltd
E4B063|Espressif Inc.
E4B107|Huawei Device Co., Ltd.
E4B16C|Apple, Inc.
E4B224|HUAWEI TECHNOLOGIES CO.,LTD
E4B2FB|Apple, Inc.
E4B318|Intel Corporate
E4B323|Espressif Inc.
E4B555|Huawei Device Co., Ltd.
E4B97A|Dell Inc.
E4BCAA|Xiaomi Communications Co Ltd
E4BD4B|zte corporation
E4BEFB|HUAWEI TECHNOLOGIES CO.,LTD
E4C0E2|Sagemcom Broadband SAS
E4C0FE|Apple, Inc.
E4C1F1|SHENZHEN SPOTMAU INFORMATION TECHNOLIGY CO., Ltd
E4C2D1|HUAWEI TECHNOLOGIES CO.,LTD
E4C32A|TP-LINK TECHNOLOGIES CO.,LTD.
E4C63D|Apple, Inc.
E4C722|Cisco Systems, Inc
E4C767|Intel Corporate
E4CA12|zte corporation
E4CDA7|zte corporation
E4CE8F|Apple, Inc.
E4D332|TP-LINK TECHNOLOGIES CO.,LTD.
E4D373|HUAWEI TECHNOLOGIES CO.,LTD
E4D398|Xiaomi Communications Co Ltd
E4D3F1|Cisco Systems, Inc
E4D436|Nokia Solutions and Networks India Private Limited
E4D53D|Hon Hai Precision Ind. Co.,Ltd.
E4D58B|Hangzhou Hikvision Digital Technology Co.,Ltd.
E4DB6D|Beijing Xiaomi Electronics Co., Ltd.
E4DBAE|Extreme Networks, Inc.
E4DC43|Huawei Device Co., Ltd.
E4DCCC|HUAWEI TECHNOLOGIES CO.,LTD
E4DE40|Hewlett Packard Enterprise
E4E0A6|Apple, Inc.
E4E0C5|Samsung Electronics Co.,Ltd
E4E4AB|Apple, Inc.
E4E749|Hewlett Packard
E4EA83|SHENZHEN GONGJIN ELECTRONICS CO.,LT
E4EC10|Nokia Corporation
E4ECE8|Samsung Electronics Co.,Ltd
E4F004|Dell Inc.
E4F042|Google, Inc.
E4F27C|Juniper Networks
E4F3C4|Samsung Electronics Co.,Ltd
E4F3E8|Shenzhen SuperElectron Technology Co.,Ltd.
E4F3F5|SHENZHEN MERCURY COMMUNICATION TECHNOLOGIES CO.,LTD.
E4F4C6|NETGEAR
E4F58E|Schneider Electric USA
E4F89C|Intel Corporate
E4F8EF|Samsung Electronics Co.,Ltd
E4FAC4|TP-Link Systems Inc
E4FADE|Microsoft Corporation
E4FAE4|Shenzhen SDMC Technology CP,.LTD
E4FAED|Samsung Electronics Co.,Ltd
E4FAFD|Intel Corporate
E4FB1E|Microsoft Corporation
E4FB5D|HUAWEI TECHNOLOGIES CO.,LTD
E4FC82|Juniper Networks
E4FD45|Intel Corporate
E4FD8C|Extreme Networks, Inc.
E4FDA1|HUAWEI TECHNOLOGIES CO.,LTD
E4FE43|Beijing Xiaomi Mobile Software Co., Ltd
E4FED4|Microsoft Corporation
E8018D|Fiberhome Telecommunication Technologies Co.,LTD
E8039A|Samsung Electronics Co.,Ltd
E8040B|Apple, Inc.
E80462|Cisco Systems, Inc
E805DC|Verifone, Inc.
E80688|Apple, Inc.
E80690|Espressif Inc.
E807BF|SHENZHEN BOOMTECH INDUSTRY CO.,LTD
E8088B|HUAWEI TECHNOLOGIES CO.,LTD
E808AF|zte corporation
E80AB9|Cisco Systems, Inc
E81098|Hewlett Packard Enterprise
E81132|Samsung Electronics Co.,Ltd
E8136E|HUAWEI TECHNOLOGIES CO.,LTD
E81499|Yoqu Technology(Shenzhen)Co.,Ltd.
E8150E|Nokia Corporation
E81711|Shenzhen Vipstech Co., Ltd
E817FC|Fujitsu Limited
E81CA5|Hewlett Packard Enterprise
E81CBA|Fortinet, Inc.
E81CD8|Apple, Inc.
E81DA8|Ruckus Wireless
E81E92|Huawei Device Co., Ltd.
E822B8|Shenzhen Skyworth Digital Technology CO., Ltd
E824A6|Juniper Networks
E82587|Shenzhen Chilink IoT Technology Co., Ltd.
E82689|Hewlett Packard Enterprise
E8268D|Shenzhen SuperElectron Technology Co.,Ltd.
E826CF|Shenzhen Jingxun Technology Co., Ltd.
E82725|Axis Communications AB
E8288D|Huawei Device Co., Ltd.
E82A44|Liteon Technology Corporation
E82AEA|Intel Corporate
E82BC5|Huawei Device Co., Ltd.
E831CD|Espressif Inc.
E83617|Apple, Inc.
E8377A|Zyxel Communications Corporation
E83935|Hewlett Packard
E83A12|Samsung Electronics Co.,Ltd
E83A97|Toshiba Corporation
E83DC1|Espressif Inc.
E83F67|Huawei Device Co., Ltd.
E84040|Cisco Systems, Inc
E840F2|PEGATRON CORPORATION
E84368|zte corporation
E843B6|QNAP Systems, Inc.
E8473A|Hon Hai Precision Industry Co.,LTD
E848B8|TP-Link Systems Inc
E84A54|Beijing Xiaomi Mobile Software Co., Ltd
E84A78|Apple, Inc.
E84C4A|Amazon Technologies Inc.
E84D74|HUAWEI TECHNOLOGIES CO.,LTD
E84DD0|HUAWEI TECHNOLOGIES CO.,LTD
E84DEC|Xerox Corporation
E84E84|Samsung Electronics Co.,Ltd
E84EBA|Google, Inc.
E84F4B|Shenzhen Delos Electronic Co., Ltd
E84FA7|Huawei Device Co., Ltd.
E8508B|SAMSUNG ELECTRO-MECHANICS(THAILAND)
E85497|Samsung Electronics Co.,Ltd
E8567A|zte corporation
E85A8B|Xiaomi Communications Co Ltd
E85AD1|Fiberhome Telecommunication Technologies Co.,LTD
E85B5B|LG ELECTRONICS INC
E85C0A|Cisco Systems, Inc
E85C5F|FN-LINK TECHNOLOGY Ltd.
E85F02|Apple, Inc.
E85FB4|Xiaomi Communications Co Ltd
E8617E|Liteon Technology Corporation
E862BE|Intel Corporate
E86549|Cisco Systems, Inc
E8655F|Dell Inc.
E865D4|Tenda Technology Co.,Ltd.Dongguan branch
E86819|HUAWEI TECHNOLOGIES CO.,LTD
E868E7|Espressif Inc.
E86A64|LCFC(Hefei) Electronics Technology co., ltd
E86BEA|Espressif Inc.
E86DCB|Samsung Electronics Co.,Ltd
E86DE9|HUAWEI TECHNOLOGIES CO.,LTD
E86E3A|Sony Interactive Entertainment Inc.
E86E44|zte corporation
E8757F|FIRS Technologies(Shenzhen) Co., Ltd
E87865|Apple, Inc.
E879A3|Cisco Systems, Inc
E87E1C|HUAWEI TECHNOLOGIES CO.,LTD
E87EEF|Xiaomi Communications Co Ltd
E87F6B|Samsung Electronics Co.,Ltd
E87F95|Apple, Inc.
E8802E|Apple, Inc.
E88088|LCFC(Hefei) Electronics Technology co., ltd
E880E7|Huawei Device Co., Ltd.
E88152|Apple, Inc.
E88175|zte corporation
E884A5|Intel Corporate
E884C6|HUAWEI TECHNOLOGIES CO.,LTD
E8854B|Apple, Inc.
E886CF|Nokia
E88843|Xiaomi Communications Co Ltd
E8886C|Shenzhen SC Technologies Co.,LTD
E88D28|Apple, Inc.
E8910F|Fiberhome Telecommunication Technologies Co.,LTD
E89120|Motorola Mobility LLC, a Lenovo Company
E892A4|LG Electronics (Mobile Communications)
E89309|Samsung Electronics Co.,Ltd
E89363|Nokia
E894F6|TP-LINK TECHNOLOGIES CO.,LTD.
E89505|Shenzhen MiaoMing Intelligent Technology Co.,Ltd
E89606|testo Instruments (Shenzhen) Co., Ltd.
E89744|LCFC(Hefei) Electronics Technology co., ltd
E89847|Xiaomi Communications Co Ltd
E8986D|Palo Alto Networks
E898EE|Apple, Inc.
E89A8F|Quanta Computer Inc.
E89C25|ASUSTek COMPUTER INC.
E89D87|Toshiba
E89EB4|Hon Hai Precision Ind. Co.,Ltd.
E89F39|Nokia
E89F6D|Espressif Inc.
E8A0ED|Hangzhou Hikvision Digital Technology Co.,Ltd.
E8A1F8|zte corporation
E8A245|Juniper Networks
E8A34E|HUAWEI TECHNOLOGIES CO.,LTD
E8A55A|Juniper Networks
E8A660|HUAWEI TECHNOLOGIES CO.,LTD
E8A6CA|Huawei Device Co., Ltd.
E8A72F|Microsoft Corporation
E8A730|Apple, Inc.
E8AACB|Samsung Electronics Co.,Ltd
E8ABF3|HUAWEI TECHNOLOGIES CO.,LTD
E8ABFA|Shenzhen Reecam Tech.Ltd.
E8AC23|HUAWEI TECHNOLOGIES CO.,LTD
E8ACAD|zte corporation
E8ADA6|Sagemcom Broadband SAS
E8B0C5|Intel Corporate
E8B1FC|Intel Corporate
E8B265|Dell Inc.
E8B2AC|Apple, Inc.
E8B3EF|Fiberhome Telecommunication Technologies Co.,LTD
E8B4AE|Shenzhen C&D Electronics Co.,Ltd
E8B4C8|Samsung Electronics Co.,Ltd
E8B541|zte corporation
E8B5D0|Dell Inc.
E8B6C2|Juniper Networks
E8B723|Shenzhen Vatilon Electronics Co.,Ltd
E8B748|Cisco Systems, Inc
E8BA17|Beijing Xiaomi Mobile Software Co., Ltd
E8BA70|Cisco Systems, Inc
E8BCE4|Cisco Systems, Inc
E8BDD1|HUAWEI TECHNOLOGIES CO.,LTD
E8BE81|Sagemcom Broadband SAS
E8BFB8|Intel Corporate
E8BFE1|Intel Corporate
E8C1D7|Philips
E8C1E8|Shenzhen Xiao Bi En Culture Education Technology Co.,Ltd.
E8C386|Apple, Inc.
E8C3C5|Huawei Device Co., Ltd.
E8C417|Fiberhome Telecommunication Technologies Co.,LTD
E8C74F|Liteon Technology Corporation
E8C829|Intel Corporate
E8C913|Samsung Electronics Co.,Ltd
E8CBA1|Nokia Corporation
E8CBED|Chipsea Technologies(Shenzhen) Corp.
E8CC18|D-Link International
E8CD2D|HUAWEI TECHNOLOGIES CO.,LTD
E8CF83|Dell Inc.
E8D03C|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
E8D099|Fiberhome Telecommunication Technologies Co.,LTD
E8D0FC|Liteon Technology Corporation
E8D2FF|Sagemcom Broadband SAS
E8D322|Cisco Systems, Inc
E8D52B|Google, Inc.
E8D765|HUAWEI TECHNOLOGIES CO.,LTD
E8D775|HUAWEI TECHNOLOGIES CO.,LTD
E8D819|AzureWave Technology Inc.
E8D87E|Amazon Technologies Inc.
E8D8D1|HP Inc.
E8DA3E|Huawei Device Co., Ltd.
E8DB84|Espressif Inc.
E8DC6C|Cisco Systems, Inc
E8DE27|TP-LINK TECHNOLOGIES CO.,LTD.
E8E0B7|Toshiba
E8E5D6|Samsung Electronics Co.,Ltd
E8E776|Shenzhen Kootion Technology Co., Ltd
E8E7C3|zte corporation
E8EA34|HUAWEI TECHNOLOGIES CO.,LTD
E8EA4D|HUAWEI TECHNOLOGIES CO.,LTD
E8EA7C|Shenzhen Amazwear Holdings Co., Ltd
E8EB34|Cisco Systems, Inc
E8EDD6|Fortinet, Inc.
E8EDF3|Cisco Systems, Inc
E8F085|HUAWEI TECHNOLOGIES CO.,LTD
E8F1B0|Sagemcom Broadband SAS
E8F375|Nokia
E8F408|Intel Corporate
E8F60A|Espressif Inc.
E8F654|HUAWEI TECHNOLOGIES CO.,LTD
E8F673|Microsoft Corporation
E8F724|Hewlett Packard Enterprise
E8F72F|HUAWEI TECHNOLOGIES CO.,LTD
E8F791|Xiaomi Communications Co Ltd
E8F8D0|Nokia Shanghai Bell Co., Ltd.
E8F9D4|HUAWEI TECHNOLOGIES CO.,LTD
E8FA23|Huawei Device Co., Ltd.
E8FB1C|AzureWave Technology Inc.
E8FBE9|Apple, Inc.
E8FC5F|Ruckus Wireless
E8FCAF|NETGEAR
E8FD35|Huawei Device Co., Ltd.
E8FEBE|Apple, Inc.
E8FF98|Huawei Device Co., Ltd.
E8FFF4|Apple, Inc.
EC01D5|Cisco Systems, Inc
EC01E2|FOXCONN INTERCONNECT TECHNOLOGY
EC0273|Hewlett Packard Enterprise
EC0441|ShenZhen TIGO Semiconductor Co., Ltd.
EC086B|TP-LINK TECHNOLOGIES CO.,LTD.
EC08E5|Motorola Mobility LLC, a Lenovo Company
EC0C96|Nokia
EC0D51|Apple, Inc.
EC0DE4|Amazon Technologies Inc.
EC0EC4|Hon Hai Precision Ind. Co.,Ltd.
EC1055|Beijing Xiaomi Electronics Co.,Ltd
EC107B|Samsung Electronics Co.,Ltd
EC13DB|Juniper Networks
EC172F|TP-LINK TECHNOLOGIES CO.,LTD.
EC192E|Cisco Systems, Inc
EC1A02|HUAWEI TECHNOLOGIES CO.,LTD
EC1B5F|Hewlett Packard Enterprise
EC1D53|HUAWEI TECHNOLOGIES CO.,LTD
EC1D7F|zte corporation
EC1D8B|Cisco Systems, Inc
EC1DA9|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
EC1F72|SAMSUNG ELECTRO-MECHANICS(THAILAND)
EC2125|Toshiba Corp.
EC21E5|Toshiba
EC2280|D-Link International
EC233D|HUAWEI TECHNOLOGIES CO.,LTD
EC237B|zte corporation
EC2651|Apple, Inc.
EC26CA|TP-LINK TECHNOLOGIES CO.,LTD.
EC28D3|Apple, Inc.
EC2A72|Dell Inc.
EC2BEB|Amazon Technologies Inc.
EC2C0D|Apple, Inc.
EC2C73|Apple, Inc.
EC2CE2|Apple, Inc.
EC2E98|AzureWave Technology Inc.
EC3091|Cisco Systems, Inc
EC30B3|Xiaomi Communications Co Ltd
EC315F|Amazon Technologies Inc.
EC33CC|Hewlett Packard Enterprise
EC3586|Apple, Inc.
EC3873|Juniper Networks
EC388F|HUAWEI TECHNOLOGIES CO.,LTD
EC3A52|Huawei Device Co., Ltd.
EC3A56|AzureWave Technology Inc.
EC3CBB|Huawei Device Co., Ltd.
EC3DFD|SHENZHEN BILIAN ELECTRONIC CO.，LTD
EC3EB3|Zyxel Communications Corporation
EC3EF7|Juniper Networks
EC4118|XIAOMI Electronics,CO.,LTD
EC41CA|Shenzhen TecAnswer Technology co.,ltd
EC41F9|Shenzhen iComm Semiconductor CO.,LTD
EC42CC|Apple, Inc.
EC43F6|Zyxel Communications Corporation
EC4476|Cisco Systems, Inc
EC4654|Apple, Inc.
EC4684|Microsoft Corporation
EC4C8C|Intel Corporate
EC4D3E|Beijing Xiaomi Mobile Software Co., Ltd
EC4D47|HUAWEI TECHNOLOGIES CO.,LTD
EC50A6|Sagemcom Broadband SAS
EC50AA|Hewlett Packard Enterprise
EC536F|HUAWEI TECHNOLOGIES CO.,LTD
EC551C|HUAWEI TECHNOLOGIES CO.,LTD
EC55F9|Hon Hai Precision Ind. Co.,Ltd.
EC5623|HUAWEI TECHNOLOGIES CO.,LTD
EC5865|Shenzhen Xinguodu Technology Co., Ltd
EC58EA|Ruckus Wireless
EC59E7|Microsoft Corporation
EC5A86|Yulong Computer Telecommunication Scientific (Shenzhen) Co.,Ltd
EC5AA3|Huawei Device Co., Ltd.
EC5B71|Inventec(Chongqing) Corporation
EC6073|TP-LINK TECHNOLOGIES CO.,LTD.
EC6260|Espressif Inc.
EC63D7|Intel Corporate
EC64C9|Espressif Inc.
EC65CC|Panasonic Automotive Systems Company of America
EC6794|Hewlett Packard Enterprise
EC6881|Palo Alto Networks
EC6CB5|zte corporation
EC725B|zte corporation
EC7359|Shenzhen Cloudsky Technologies Co., Ltd.
EC7379|Apple, Inc.
EC748C|Sony Interactive Entertainment Inc.
EC74D7|Grandstream Networks Inc
EC750C|TP-Link Systems Inc.
EC753E|HUAWEI TECHNOLOGIES CO.,LTD
EC7949|FUJITSU LIMITED
EC79C0|zte corporation
EC7C2C|HUAWEI TECHNOLOGIES CO.,LTD
EC7C5C|Juniper Networks
EC7C74|Justone Technologies Co., Ltd.
EC7CB6|Samsung Electronics Co.,Ltd
EC7CBA|Hewlett Packard Enterprise
EC8150|Apple, Inc.
EC8152|HUAWEI TECHNOLOGIES CO.,LTD
EC819C|HUAWEI TECHNOLOGIES CO.,LTD
EC8263|zte corporation
EC8350|Microsoft Corporation
EC852F|Apple, Inc.
EC888F|TP-LINK TECHNOLOGIES CO.,LTD.
EC8892|Motorola Mobility LLC, a Lenovo Company
EC8914|HUAWEI TECHNOLOGIES CO.,LTD
EC89F5|Lenovo Mobile Communication Technology Ltd.
EC8A4C|zte corporation
EC8AC4|Amazon Technologies Inc.
EC8AC7|Fiberhome Telecommunication Technologies Co.,LTD
EC8C9A|HUAWEI TECHNOLOGIES CO.,LTD
EC8CA2|Ruckus Wireless
EC8E12|Nokia
EC8E77|Intel Corporate
EC8EB5|Hewlett Packard
EC90C1|Samsung Electronics Co.,Ltd
EC94CB|Espressif Inc.
EC94D5|Juniper Networks
EC97A2|Apple, Inc.
EC9A74|Hewlett Packard
EC9B5B|Nokia Corporation
EC9B75|Roku, Inc
EC9B8B|Hewlett Packard Enterprise
EC9BF3|SAMSUNG ELECTRO-MECHANICS(THAILAND)
ECA138|Amazon Technologies Inc.
ECA1CC|Cisco Systems, Inc
ECA1D1|HUAWEI TECHNOLOGIES CO.,LTD
ECA62F|HUAWEI TECHNOLOGIES CO.,LTD
ECA78D|Cisco Systems, Inc
ECA907|Apple, Inc.
ECA971|Hangzhou Hikvision Digital Technology Co.,Ltd.
ECAA25|Samsung Electronics Co.,Ltd
ECAA8F|HUAWEI TECHNOLOGIES CO.,LTD
ECAAA0|PEGATRON CORPORATION
ECADB8|Apple, Inc.
ECADE0|D-Link International
ECB157|Sagemcom Broadband SAS
ECB1D7|Hewlett Packard
ECB293|Hewlett Packard Enterprise
ECB313|SHENZHEN GONGJIN ELECTRONICS CO.,LT
ECB4E8|Wistron Mexico SA de CV
ECB550|Samsung Electronics Co.,Ltd
ECB5FA|Philips Lighting BV
ECB878|Huawei Device Co., Ltd.
ECB931|TP-Link Systems Inc.
ECB9A5|Huawei Device Co., Ltd.
ECBB78|Cisco Systems, Inc
ECBD1D|Cisco Systems, Inc
ECBEDD|Sagemcom Broadband SAS
ECC018|Cisco Systems, Inc
ECC01B|HUAWEI TECHNOLOGIES CO.,LTD
ECC342|zte corporation
ECC3B0|zte corporation
ECC5D2|Huawei Device Co., Ltd.
ECC882|Cisco Systems, Inc
ECC89C|Hangzhou Hikvision Digital Technology Co.,Ltd.
ECC9FF|Espressif Inc.
ECCB30|HUAWEI TECHNOLOGIES CO.,LTD
ECCE13|Cisco Systems, Inc
ECCED7|Apple, Inc.
ECD09F|Xiaomi Communications Co Ltd
ECD508|Apple, Inc.
ECD61B|Espressif Inc.
ECD68A|Shenzhen JMicron Intelligent Technology Developmen
ECD9D1|Shenzhen TG-NET Botone Technology Co.,Ltd.
ECDA3B|Espressif Inc.
ECDCAA|Apple, Inc.
ECDD24|Cisco Systems, Inc
ECE09B|Samsung Electronics Co.,Ltd
ECE1A9|Cisco Systems, Inc
ECE334|Espressif Inc.
ECE61D|Huawei Device Co., Ltd.
ECE6A2|Fiberhome Telecommunication Technologies Co.,LTD
ECE7A7|Intel Corporate
ECE9D2|Apple, Inc.
ECE9F5|HUAWEI TECHNOLOGIES CO.,LTD
ECEBB8|Hewlett Packard Enterprise
ECED04|Intel Corporate
ECED73|Motorola Mobility LLC, a Lenovo Company
ECF0FE|zte corporation
ECF33C|Intel Corporate
ECF35B|Nokia Corporation
ECF40C|Cisco Systems, Inc
ECF4BB|Dell Inc.
ECF8D0|HUAWEI TECHNOLOGIES CO.,LTD
ECFA5C|Beijing Xiaomi Electronics Co., Ltd.
ECFABC|Espressif Inc.
ECFC2F|Sagemcom Broadband SAS
ECFCC6|Hewlett Packard Enterprise
ECFF3A|Apple, Inc.
F0038C|AzureWave Technology Inc.
F003BC|Cisco Systems, Inc
F004E1|Apple, Inc.
F0051B|Samsung Electronics Co.,Ltd
F008D1|Espressif Inc.
F008F1|Samsung Electronics Co.,Ltd
F0090D|TP-Link Systems Inc
F00C51|zte corporation
F00FEC|HUAWEI TECHNOLOGIES CO.,LTD
F013C3|SHENZHEN FENDA TECHNOLOGY CO., LTD
F0161D|Espressif Inc.
F01628|Technicolor (China) Technology Co., Ltd.
F01653|YEALINK(XIAMEN) NETWORK TECHNOLOGY CO.,LTD.
F01898|Apple, Inc.
F01AA0|Hewlett Packard Enterprise
F01B24|zte corporation
F01C13|LG Electronics (Mobile Communications)
F01C2D|Juniper Networks
F01D2D|Cisco Systems, Inc
F01DBC|Microsoft Corporation
F01FAF|Dell Inc.
F01FC7|Apple, Inc.
F020FF|Intel Corporate
F02475|Apple, Inc.
F024F9|Espressif Inc.
F02572|Cisco Systems, Inc
F0258E|HUAWEI TECHNOLOGIES CO.,LTD
F025B7|SAMSUNG ELECTRO-MECHANICS(THAILAND)
F0272D|Amazon Technologies Inc.
F027A0|Apple, Inc.
F02929|Cisco Systems, Inc
F02B7C|Extreme Networks, Inc.
F02C59|Chipsea Technologies (Shenzhen) Crop.
F02F4B|Apple, Inc.
F02F50|Shenzhen SEI Robotics Co.,Ltd
F02F74|ASUSTek COMPUTER INC.
F02F9E|Amazon Technologies Inc.
F02FA7|HUAWEI TECHNOLOGIES CO.,LTD
F02FBA|Apple, Inc.
F033E5|HUAWEI TECHNOLOGIES CO.,LTD
F037A1|Huike Electronics (SHENZHEN) CO., LTD.
F037CF|Huawei Device Co., Ltd.
F03965|Samsung Electronics Co.,Ltd
F03E90|Ruckus Wireless
F03F95|HUAWEI TECHNOLOGIES CO.,LTD
F0407B|Fiberhome Telecommunication Technologies Co.,LTD
F040D9|Apple, Inc.
F0421C|Intel Corporate
F042F5|Huawei Device Co., Ltd.
F04347|HUAWEI TECHNOLOGIES CO.,LTD
F04A02|Cisco Systems, Inc
F04B3A|Juniper Networks
F04DA2|Dell Inc.
F04DD4|Sagemcom Broadband SAS
F04EA4|HP Inc.
F04F7C|Amazon Technologies Inc.
F05494|Honeywell Connected Building
F05501|Huawei Device Co., Ltd.
F057A6|Intel Corporate
F05A09|Samsung Electronics Co.,Ltd
F05B7B|Samsung Electronics Co.,Ltd
F05C0E|Huawei Device Co., Ltd.
F05C19|Hewlett Packard Enterprise
F05C77|Google, Inc.
F05CD5|Apple, Inc.
F05D88|HUAWEI TECHNOLOGIES CO.,LTD
F061C0|Hewlett Packard Enterprise
F0620D|Shenzhen Egreat Tech Corp.,Ltd
F063F9|HUAWEI TECHNOLOGIES CO.,LTD
F06426|Extreme Networks, Inc.
F065AE|Samsung Electronics Co.,Ltd
F067B1|Samsung Electronics Co.,Ltd
F068E3|AzureWave Technology Inc.
F06BCA|Samsung Electronics Co.,Ltd
F06C5D|Xiaomi Communications Co Ltd
F06C73|Nokia
F06E0B|Microsoft Corporation
F06FCE|Ruckus Wireless
F0704F|Samsung Electronics Co.,Ltd
F0728C|Samsung Electronics Co.,Ltd
F072EA|Google, Inc.
F074C1|Blink by Amazon
F0761C|COMPAL INFORMATION (KUNSHAN) CO., LTD.
F0766F|Apple, Inc.
F077C3|Intel Corporate
F07807|Apple, Inc.
F07816|Cisco Systems, Inc
F07959|ASUSTek COMPUTER INC.
F07960|Apple, Inc.
F07A55|zte corporation
F07B65|Sagemcom Broadband SAS
F07BCB|Hon Hai Precision Ind. Co.,Ltd.
F07CC7|Juniper Networks
F07D68|D-Link Corporation
F07F06|Cisco Systems, Inc
F08173|Amazon Technologies Inc.
F08175|Sagemcom Broadband SAS
F08261|Sagemcom Broadband SAS
F084C9|zte corporation
F085C1|SHENZHEN RF-LINK TECHNOLOGY CO.,LTD.
F08756|Zyxel Communications Corporation
F0877F|Magnetar Technology Shenzhen Co., LTD.
F08A76|Samsung Electronics Co.,Ltd
F08CFB|Fiberhome Telecommunication Technologies Co.,LTD
F09008|Shenzhen Skyworth Digital Technology CO., Ltd
F0921C|Hewlett Packard
F09838|HUAWEI TECHNOLOGIES CO.,LTD
F0989D|Apple, Inc.
F099B6|Apple, Inc.
F099BF|Apple, Inc.
F09BB8|HUAWEI TECHNOLOGIES CO.,LTD
F09CE9|Extreme Networks, Inc.
F09E4A|Intel Corporate
F09E63|Cisco Systems, Inc
F09E9E|Espressif Inc.
F09FC2|Ubiquiti Inc
F09FFC|SHARP Corporation
F0A0B1|HUAWEI TECHNOLOGIES CO.,LTD
F0A225|Amazon Technologies Inc.
F0A35A|Apple, Inc.
F0A4EA|Huawei Device Co., Ltd.
F0A731|TP-Link Systems Inc
F0A882|shenzhen trolink Technology Co.,Ltd
F0A951|HUAWEI TECHNOLOGIES CO.,LTD
F0AB1F|zte corporation
F0ABF3|Fiberhome Telecommunication Technologies Co.,LTD
F0ABFA|Shenzhen Rayin Technology Co.,Ltd
F0B040|HUNAN FN-LINK TECHNOLOGY LIMITED
F0B052|Ruckus Wireless
F0B0E7|Apple, Inc.
F0B11D|Nokia
F0B13F|Huawei Device Co., Ltd.
F0B2B9|Intel Corporate
F0B2E5|Cisco Systems, Inc
F0B3EC|Apple, Inc.
F0B429|Xiaomi Communications Co Ltd
F0B479|Apple, Inc.
F0B4D2|D-Link International
F0B61E|Intel Corporate
F0BDEE|Huawei Device Co., Ltd.
F0BF97|Sony Corporation
F0C1F1|Apple, Inc.
F0C371|Apple, Inc.
F0C42F|Huawei Device Co., Ltd.
F0C478|HUAWEI TECHNOLOGIES CO.,LTD
F0C725|Apple, Inc.
F0C814|SHENZHEN BILIAN ELECTRONIC CO.，LTD
F0C850|HUAWEI TECHNOLOGIES CO.,LTD
F0C8B5|HUAWEI TECHNOLOGIES CO.,LTD
F0CBA1|Apple, Inc.
F0CCE0|Shenzhen All-Smartlink Technology Co.,Ltd.
F0CD31|Samsung Electronics Co.,Ltd
F0D018|Hewlett Packard Enterprise
F0D1A9|Apple, Inc.
F0D2F1|Amazon Technologies Inc.
F0D31F|Apple, Inc.
F0D32B|Juniper Networks
F0D415|Intel Corporate
F0D4E2|Dell Inc.
F0D5BF|Intel Corporate
F0D635|Apple, Inc.
F0D793|Apple, Inc.
F0D7AA|Motorola Mobility LLC, a Lenovo Company
F0D7EE|Huawei Device Co., Ltd.
F0D805|Cisco Systems, Inc
F0DBE2|Apple, Inc.
F0DBF8|Apple, Inc.
F0DCE2|Apple, Inc.
F0DEF1|Wistron Infocomm (Zhongshan) Corporation
F0E426|Samsung Electronics Co.,Ltd
F0E4A2|HUAWEI TECHNOLOGIES CO.,LTD
F0E752|Shenzhen Huajuxin Semiconductor Co.,ltd
F0E77E|Samsung Electronics Co.,Ltd
F0EC80|Zero Boundary Singularity Technology(Shenzhen)
F0ED19|zte corporation
F0EE10|Samsung Electronics Co.,Ltd
F0EE7A|Apple, Inc.
F0EF86|Google, Inc.
F0F002|Hon Hai Precision Ind. Co.,Ltd.
F0F0A4|Amazon Technologies Inc.
F0F336|TP-LINK TECHNOLOGIES CO.,LTD.
F0F564|Samsung Electronics Co.,Ltd
F0F5BD|Espressif Inc.
F0F61C|Apple, Inc.
F0F6C1|Sonos, Inc.
F0F755|Cisco Systems, Inc
F0F7E7|HUAWEI TECHNOLOGIES CO.,LTD
F0F7FC|HUAWEI TECHNOLOGIES CO.,LTD
F0F832|Google, Inc.
F0FABA|NVIDIA Corporation
F0FAC7|Huawei Device Co., Ltd.
F0FEE7|Huawei Device Co., Ltd.
F400A2|Samsung Electronics Co.,Ltd
F40223|PAX Computer Technology(Shenzhen) Ltd.
F40228|SAMSUNG ELECTRO-MECHANICS(THAILAND)
F40270|Dell Inc.
F40304|Google, Inc.
F4032A|Amazon Technologies Inc.
F40343|Hewlett Packard Enterprise
F40595|Sagemcom Broadband SAS
F40616|Apple, Inc.
F40669|Intel Corporate
F406A3|Huawei Device Co., Ltd.
F409D8|SAMSUNG ELECTRO-MECHANICS(THAILAND)
F40A2E|Shenzhen Skyworth Digital Technology CO., Ltd
F40E01|Apple, Inc.
F40E22|Samsung Electronics Co.,Ltd
F40F1B|Cisco Systems, Inc
F40F24|Apple, Inc.
F412DA|zte corporation
F412FA|Espressif Inc.
F41A9C|Xiaomi Communications Co Ltd
F41AB0|Shenzhen Xingguodu Technology Co., Ltd.
F41AF7|zte corporation
F41BA1|Apple, Inc.
F41C71|SHENZHEN SANMU COMMUNICATION TECHNOLOGY CO., LTD
F41D6B|HUAWEI TECHNOLOGIES CO.,LTD
F41E57|Routerboard.com
F41F88|zte corporation
F41FC2|Cisco Systems, Inc
F421CA|Apple, Inc.
F4248B|HUAWEI TECHNOLOGIES CO.,LTD
F425FE|HUAWEI TECHNOLOGIES CO.,LTD
F42679|Intel Corporate
F42853|Zioncom Electronics (Shenzhen) Ltd.
F42A7D|TP-LINK TECHNOLOGIES CO.,LTD.
F42B8C|Samsung Electronics Co.,Ltd
F42D06|zte corporation
F42DC9|Espressif Inc.
F42E48|zte corporation
F42E7F|Hewlett Packard Enterprise
F4308B|Xiaomi Communications Co Ltd
F430B9|Hewlett Packard
F431C3|Apple, Inc.
F43392|Cisco Systems, Inc
F433B7|Apple, Inc.
F434F0|Apple, Inc.
F437B7|Apple, Inc.
F438C1|Huawei Device Co., Ltd.
F43909|Hewlett Packard
F439A6|Apple, Inc.
F43A7B|zte corporation
F43BD8|Intel Corporate
F43C3B|HUNAN FN-LINK TECHNOLOGY LIMITED
F43E61|SHENZHEN GONGJIN ELECTRONICS CO.,LT
F4419E|Huawei Device Co., Ltd.
F4428F|Samsung Electronics Co.,Ltd
F4442C|Shenzhen SuperElectron Technology Co.,Ltd.
F44588|HUAWEI TECHNOLOGIES CO.,LTD
F44637|Intel Corporate
F449EF|EMSTONE
F44B2A|Cisco SPVTG
F44C70|Skyworth Digital Technology(Shenzhen) Co.,Ltd
F44C7F|HUAWEI TECHNOLOGIES CO.,LTD
F44D5C|Zyxel Communications Corporation
F44E05|Cisco Systems, Inc
F44EE3|Intel Corporate
F44FD3|shenzhen hemuwei technology co.,ltd
F45293|Apple, Inc.
F453E4|HUAWEI TECHNOLOGIES CO.,LTD
F45424|Extreme Networks, Inc.
F4559C|HUAWEI TECHNOLOGIES CO.,LTD
F4573E|Fiberhome Telecommunication Technologies Co.,LTD
F45B29|HUAWEI TECHNOLOGIES CO.,LTD
F45BB4|Cisco Systems, Inc
F45C42|Huawei Device Co., Ltd.
F45C89|Apple, Inc.
F45FD4|Cisco SPVTG
F460E2|Xiaomi Communications Co Ltd
F462DC|Huawei Device Co., Ltd.
F4631F|HUAWEI TECHNOLOGIES CO.,LTD
F46412|Sony Interactive Entertainment Inc.
F4645D|Toshiba
F4650B|Espressif Inc.
F465A6|Apple, Inc.
F4672D|ShenZhen Topstar Technology Company
F46802|HUAWEI TECHNOLOGIES CO.,LTD
F46A92|SHENZHEN FAST TECHNOLOGIES CO.,LTD
F46AD7|Microsoft Corporation
F46ADD|Liteon Technology Corporation
F46B8C|Hon Hai Precision Industry Co., Ltd.
F46BEF|Sagemcom Broadband SAS
F46D04|ASUSTek COMPUTER INC.
F46D2F|TP-LINK TECHNOLOGIES CO.,LTD.
F46D3F|Intel Corporate
F46DE2|zte corporation
F46E95|Extreme Networks, Inc.
F46FED|Fiberhome Telecommunication Technologies Co.,LTD
F47190|Samsung Electronics Co.,Ltd
F47470|Cisco Systems, Inc
F478AC|Apple, Inc.
F47946|HUAWEI TECHNOLOGIES CO.,LTD
F47960|HUAWEI TECHNOLOGIES CO.,LTD
F47B09|Intel Corporate
F47B5E|Samsung Electronics Co.,Ltd
F47D8F|Google, Inc.
F47DEF|Samsung Electronics Co.,Ltd
F47F35|Cisco Systems, Inc
F48139|CANON INC.
F481C4|Apple, Inc.
F483CD|TP-LINK TECHNOLOGIES CO.,LTD.
F4848D|TP-LINK TECHNOLOGIES CO.,LTD.
F487C5|Huawei Device Co., Ltd.
F48918|HUAWEI TECHNOLOGIES CO.,LTD
F48974|Cisco Systems, Inc
F48B32|Xiaomi Communications Co Ltd
F48C50|Intel Corporate
F48CEB|D-Link International
F48E09|Nokia Corporation
F48E38|Dell Inc.
F48E92|HUAWEI TECHNOLOGIES CO.,LTD
F492BF|Ubiquiti Inc
F4939F|Hon Hai Precision Industry Co., Ltd.
F49634|Intel Corporate
F49AB1|Hewlett Packard Enterprise
F49F54|Samsung Electronics Co.,Ltd
F49FF3|HUAWEI TECHNOLOGIES CO.,LTD
F4A157|Huawei Device Co., Ltd.
F4A1A6|Apple, Inc.
F4A310|Apple, Inc.
F4A3C2|Shenzhen iComm Semiconductor CO.,LTD
F4A475|Intel Corporate
F4A4D6|HUAWEI TECHNOLOGIES CO.,LTD
F4A59D|Huawei Device Co., Ltd.
F4A739|Juniper Networks
F4A80D|Wistron InfoComm(Kunshan)Co.,Ltd.
F4A997|CANON INC.
F4ACC1|Cisco Systems, Inc
F4AFE7|Apple, Inc.
F4B1C2|Zhejiang Dahua Technology Co., Ltd.
F4B24E|Huawei Device Co., Ltd.
F4B301|Intel Corporate
F4B52F|Juniper Networks
F4B599|Apple, Inc.
F4B5AA|zte corporation
F4B78D|HUAWEI TECHNOLOGIES CO.,LTD
F4B7E2|Hon Hai Precision Ind. Co.,Ltd.
F4B821|Cisco Systems, Inc
F4B8A7|zte corporation
F4BC97|Shenzhen Crave Communication Co., LTD
F4BCDA|Shenzhen Jingxun Software Telecommunication Technology Co.,Ltd
F4BD9E|Cisco Systems, Inc
F4BDAE|Shenzhen V-Link Technology CO., LTD.
F4BEEC|Apple, Inc.
F4BF80|HUAWEI TECHNOLOGIES CO.,LTD
F4BFA8|Juniper Networks
F4C248|Samsung Electronics Co.,Ltd
F4C4D6|Shenzhen Xinfa Electronic Co.,ltd
F4C714|HUAWEI TECHNOLOGIES CO.,LTD
F4C7AA|Marvell Semiconductors
F4C88A|Intel Corporate
F4CB52|HUAWEI TECHNOLOGIES CO.,LTD
F4CBE7|Apple, Inc.
F4CC55|Juniper Networks
F4CE23|Intel Corporate
F4CE46|Hewlett Packard
F4CE48|Extreme Networks, Inc.
F4CFA2|Espressif Inc.
F4CFE2|Cisco Systems, Inc
F4D108|Intel Corporate
F4D454|Shenzhen Skyworth Digital Technology CO., Ltd
F4D488|Apple, Inc.
F4D58A|Palo Alto Networks
F4D9FB|Samsung Electronics Co.,Ltd
F4DBE3|Apple, Inc.
F4DBE6|Cisco Systems, Inc
F4DCF9|HUAWEI TECHNOLOGIES CO.,LTD
F4DD06|Samsung Electronics Co.,Ltd
F4DEAF|HUAWEI TECHNOLOGIES CO.,LTD
F4E1FC|Hewlett Packard Enterprise
F4E2C6|Ubiquiti Inc
F4E3FB|HUAWEI TECHNOLOGIES CO.,LTD
F4E451|HUAWEI TECHNOLOGIES CO.,LTD
F4E4AD|zte corporation
F4E5F2|HUAWEI TECHNOLOGIES CO.,LTD
F4E84F|zte corporation
F4E8C7|Apple, Inc.
F4EA67|Cisco Systems, Inc
F4EAB5|Extreme Networks, Inc.
F4EB38|Sagemcom Broadband SAS
F4EC38|TP-LINK TECHNOLOGIES CO.,LTD.
F4ED5F|SHENZHEN KTC TECHNOLOGY GROUP
F4EE08|Dell Inc.
F4EE31|Cisco Systems, Inc
F4F15A|Apple, Inc.
F4F19E|Wistron InforComm (Zhongshan) Corporation
F4F1E1|Motorola Mobility LLC, a Lenovo Company
F4F26D|TP-LINK TECHNOLOGIES CO.,LTD.
F4F28A|HUAWEI TECHNOLOGIES CO.,LTD
F4F309|Samsung Electronics Co.,Ltd
F4F50B|TP-Link Systems Inc.
F4F524|Motorola Mobility LLC, a Lenovo Company
F4F5A5|Nokia Corporation
F4F5D8|Google, Inc.
F4F5DB|Xiaomi Communications Co Ltd
F4F5E8|Google, Inc.
F4F647|zte corporation
F4F951|Apple, Inc.
F4FBB8|HUAWEI TECHNOLOGIES CO.,LTD
F4FC49|zte corporation
F4FE3E|Apple, Inc.
F4FEFB|Samsung Electronics Co.,Ltd
F800A1|HUAWEI TECHNOLOGIES CO.,LTD
F80113|HUAWEI TECHNOLOGIES CO.,LTD
F801B4|LG Electronics
F80377|Apple, Inc.
F8042E|SAMSUNG ELECTRO-MECHANICS(THAILAND)
F8075D|Huawei Device Co., Ltd.
F8084F|Sagemcom Broadband SAS
F80BCB|Cisco Systems, Inc
F80CF3|LG Electronics (Mobile Communications)
F80D43|Hon Hai Precision Ind. Co.,Ltd.
F80D60|CANON INC.
F80DA9|Zyxel Communications Corporation
F80DAC|HP Inc.
F80DF0|zte corporation
F80F41|Wistron Infocomm (Zhongshan) Corporation
F80F6F|Cisco Systems, Inc
F80FF9|Google, Inc.
F81093|Apple, Inc.
F81308|Nokia
F814DD|Cisco Systems, Inc
F81547|Avaya Inc
F8160C|Shenzhen iComm Semiconductor CO.,LTD
F81654|Intel Corporate
F8172D|Tuya Smart Inc.
F81A2B|Google, Inc.
F81A67|TP-LINK TECHNOLOGIES CO.,LTD.
F81E49|Apple, Inc.
F81EDF|Apple, Inc.
F81F32|Motorola Mobility LLC, a Lenovo Company
F820A9|Huawei Device Co., Ltd.
F82229|Nokia Shanghai Bell Co., Ltd.
F82387|Shenzhen Horn Audio Co.,Ltd.
F823B2|HUAWEI TECHNOLOGIES CO.,LTD
F82551|Seiko Epson Corporation
F82793|Apple, Inc.
F82819|Liteon Technology Corporation
F828C9|HUAWEI TECHNOLOGIES CO.,LTD
F8293A|HUAWEI TECHNOLOGIES CO.,LTD
F82AE2|Apple, Inc.
F82B7F|Huawei Device Co., Ltd.
F82D7C|Apple, Inc.
F82E3F|HUAWEI TECHNOLOGIES CO.,LTD
F82F65|Huawei Device Co., Ltd.
F82FA8|Hon Hai Precision Ind. Co.,Ltd.
F832E4|ASUSTek COMPUTER INC.
F83441|Intel Corporate
F83869|LG Electronics
F83880|Apple, Inc.
F83918|Cisco Systems, Inc
F83B7E|Huawei Device Co., Ltd.
F83C44|SHENZHEN TRANSCHAN TECHNOLOGY LIMITED
F83DC6|AzureWave Technology Inc.
F83DFF|HUAWEI TECHNOLOGIES CO.,LTD
F83E95|HUAWEI TECHNOLOGIES CO.,LTD
F83F51|Samsung Electronics Co.,Ltd
F84288|Apple, Inc.
F843EE|Espressif Inc.
F843EF|Xiaomi Communications Co Ltd
F845C4|Shenzhen Netforward Micro-Electronic Co., Ltd.
F8461C|Sony Interactive Entertainment Inc.
F847E3|Shenzhen Skyworth Digital Technology CO., Ltd
F84ABF|HUAWEI TECHNOLOGIES CO.,LTD
F84CDA|HUAWEI TECHNOLOGIES CO.,LTD
F84D33|Fiberhome Telecommunication Technologies Co.,LTD
F84D89|Apple, Inc.
F84DFC|Hangzhou Hikvision Digital Technology Co.,Ltd.
F84E17|Sony Corporation
F84E58|Samsung Electronics Co.,Ltd
F84E73|Apple, Inc.
F84F57|Cisco Systems, Inc
F85329|HUAWEI TECHNOLOGIES CO.,LTD
F854B8|Amazon Technologies Inc.
F854F6|AzureWave Technology Inc.
F856C3|zte corporation
F85971|Intel Corporate
F85B1B|Espressif Inc.
F85B6E|Samsung Electronics Co.,Ltd
F85C24|Sonos Inc.
F85C4D|Nokia
F85C7D|Shenzhen Honesty Electronics Co.,Ltd.
F85C7E|Shenzhen Honesty Electronics Co.,Ltd.
F85E3C|SHENZHEN ZHIBOTONG ELECTRONICS CO.,LTD
F85EA0|Intel Corporate
F85F2A|Nokia Corporation
F860F0|Hewlett Packard Enterprise
F86214|Apple, Inc.
F8633F|Intel Corporate
F864B8|zte corporation
F8665A|Apple, Inc.
F866D1|Hon Hai Precision Ind. Co.,Ltd.
F866F2|Cisco Systems, Inc
F868FF|Cisco Systems, Inc
F86BD9|Cisco Systems, Inc
F86C03|Shenzhen Teleone Technology Co., Ltd
F86EEE|HUAWEI TECHNOLOGIES CO.,LTD
F86FB0|TP-LINK TECHNOLOGIES CO.,LTD.
F86FC1|Apple, Inc.
F86FDE|Shenzhen Goodix Technology Co.,Ltd.
F8710C|Xiaomi Communications Co Ltd
F871A6|Apple, Inc.
F872EA|Cisco Systems, Inc
F8731A|zte corporation
F87394|NETGEAR
F873A2|Avaya Inc
F873DF|Apple, Inc.
F87588|HUAWEI TECHNOLOGIES CO.,LTD
F875A4|LCFC(Hefei) Electronics Technology co., ltd
F877B8|Samsung Electronics Co.,Ltd
F87907|Huawei Device Co., Ltd.
F87928|zte corporation
F87A41|Cisco Systems, Inc
F87B20|Cisco Systems, Inc
F87D3F|Huawei Device Co., Ltd.
F87D76|Apple, Inc.
F88306|Beijing Xiaomi Mobile Software Co., Ltd
F88479|Yaojin Technology(Shenzhen)Co.,Ltd
F884F2|Samsung Electronics Co.,Ltd
F887F1|Apple, Inc.
F8893C|Inventec Appliances Corp.
F88C21|TP-LINK TECHNOLOGIES CO.,LTD.
F88F07|Samsung Electronics Co.,Ltd
F88FC8|Chipsea Technologies (Shenzhen) Corp.
F88FCA|Google, Inc.
F894C2|Intel Corporate
F89522|HUAWEI TECHNOLOGIES CO.,LTD
F895C7|LG Electronics (Mobile Communications)
F895EA|Apple, Inc.
F89753|Huawei Device Co., Ltd.
F898B9|HUAWEI TECHNOLOGIES CO.,LTD
F898EF|HUAWEI TECHNOLOGIES CO.,LTD
F89A25|HUAWEI TECHNOLOGIES CO.,LTD
F89A78|HUAWEI TECHNOLOGIES CO.,LTD
F89B6E|Nokia Solutions and Networks GmbH & Co. KG
F89D9D|Shenzhen MinewSemi Co.,LTD.
F89E28|Cisco Meraki
F89E94|Intel Corporate
F8A26D|CANON INC.
F8A2D6|Liteon Technology Corporation
F8A34F|zte corporation
F8A45F|Xiaomi Communications Co Ltd
F8A5C5|Cisco Systems, Inc
F8A73A|Cisco Systems, Inc
F8A963|COMPAL INFORMATION (KUNSHAN) CO., LTD.
F8A986|Microsoft Corporation
F8A9D0|LG Electronics (Mobile Communications)
F8AA8A|Axview Technology (Shenzhen) Co.,Ltd
F8AB05|Sagemcom Broadband SAS
F8AB82|Xiaomi Communications Co Ltd
F8ABE5|shenzhen worldelite electronics co., LTD
F8AC65|Intel Corporate
F8AF05|Huawei Device Co., Ltd.
F8AFDB|Fiberhome Telecommunication Technologies Co.,LTD
F8B132|HUAWEI TECHNOLOGIES CO.,LTD
F8B156|Dell Inc.
F8B1DD|Apple, Inc.
F8B22C|Roku, Inc
F8B3B7|Espressif Inc.
F8B46A|Hewlett Packard
F8B54D|Intel Corporate
F8B7E2|Cisco Systems, Inc
F8B8B4|Shenzhen Skyworth Digital Technology CO., Ltd
F8BAE6|Nokia
F8BC12|Dell Inc.
F8BF09|HUAWEI TECHNOLOGIES CO.,LTD
F8C001|Juniper Networks
F8C116|Juniper Networks
F8C288|Cisco Systems, Inc
F8C39E|HUAWEI TECHNOLOGIES CO.,LTD
F8C3CC|Apple, Inc.
F8C650|Cisco Systems, Inc
F8C903|TP-LINK TECHNOLOGIES CO.,LTD.
F8C96C|Fiberhome Telecommunication Technologies Co.,LTD
F8CAB8|Dell Inc.
F8CB15|Apple, Inc.
F8CE07|ZHEJIANG DAHUA TECHNOLOGYCO.,LTD
F8CE21|TP-LINK TECHNOLOGIES CO.,LTD.
F8CE72|Wistron Corporation
F8CF52|Intel Corporate
F8CFC5|Motorola Mobility LLC, a Lenovo Company
F8D027|Seiko Epson Corporation
F8D0AC|Sony Interactive Entertainment Inc.
F8D0BD|Samsung Electronics Co.,Ltd
F8D111|TP-LINK TECHNOLOGIES CO.,LTD.
F8D3F0|Apple, Inc.
F8DA0C|Hon Hai Precision Ind. Co.,Ltd.
F8DB88|Dell Inc.
F8DE73|HUAWEI TECHNOLOGIES CO.,LTD
F8DFA8|zte corporation
F8E079|Motorola Mobility LLC, a Lenovo Company
F8E252|Apple, Inc.
F8E4A4|Fiberhome Telecommunication Technologies Co.,LTD
F8E4E3|Intel Corporate
F8E57E|Cisco Systems, Inc
F8E5CE|Apple, Inc.
F8E61A|Samsung Electronics Co.,Ltd
F8E71E|Ruckus Wireless
F8E811|HUAWEI TECHNOLOGIES CO.,LTD
F8E903|D-Link International
F8E94E|Apple, Inc.
F8E94F|Cisco Systems, Inc
F8EDFC|HP Inc.
F8EF5D|Motorola Mobility LLC, a Lenovo Company
F8F1B6|Motorola Mobility LLC, a Lenovo Company
F8F1E6|Samsung Electronics Co.,Ltd
F8F21E|Intel Corporate
F8F2F0|Chipsea Technologies (Shenzhen) Crop.
F8F3D3|Shenzhen Gotron electronic CO.,LTD
F8F58C|Apple, Inc.
F8F6B7|SHENZHEN BILIAN ELECTRONIC CO.，LTD
F8F7B9|HUAWEI TECHNOLOGIES CO.,LTD
F8FCE1|Amazon Technologies Inc.
F8FE5E|Intel Corporate
F8FF5F|Shenzhen Communication Technology Co.,Ltd
F8FFC2|Apple, Inc.
FC0012|Toshiba Samsung Storage Technolgoy Korea Corporation
FC012C|Espressif Inc.
FC017C|Hon Hai Precision Ind. Co.,Ltd.
FC0296|Xiaomi Communications Co Ltd
FC039F|Samsung Electronics Co.,Ltd
FC068C|SHENZHEN MICIPC TECHNOLOGY CO.,LTD
FC0736|Huawei Device Co., Ltd.
FC084A|FUJITSU LIMITED
FC0A81|Extreme Networks, Inc.
FC0C45|Shenzhen SuperElectron Technology Co.,Ltd.
FC0F76|Amazon Technologies Inc.
FC0FE6|Sony Interactive Entertainment Inc.
FC101A|Palo Alto Networks
FC1165|Cambium Networks Limited
FC1193|HUAWEI TECHNOLOGIES CO.,LTD
FC122C|HUAWEI TECHNOLOGIES CO.,LTD
FC15B4|Hewlett Packard
FC1803|HUAWEI TECHNOLOGIES CO.,LTD
FC183C|Apple, Inc.
FC1910|Samsung Electronics Co.,Ltd
FC1999|Xiaomi Communications Co Ltd
FC1A46|Samsung Electronics Co.,Ltd
FC1BD1|HUAWEI TECHNOLOGIES CO.,LTD
FC1CA1|Nokia
FC1D3A|HUAWEI TECHNOLOGIES CO.,LTD
FC1D43|Apple, Inc.
FC1F19|SAMSUNG ELECTRO MECHANICS CO., LTD.
FC2120|Cisco Systems, Inc
FC221C|Shenzhen Xunman Technology Co., Ltd
FC22F4|Zyxel Communications Corporation
FC2325|EosTek (Shenzhen) Co., Ltd.
FC23CD|SHENZHEN BILIAN ELECTRONIC CO.，LTD
FC253F|Apple, Inc.
FC2640|Huawei Device Co., Ltd.
FC2A9C|Apple, Inc.
FC2D5E|zte corporation
FC2FAA|Nokia
FC315D|Apple, Inc.
FC3342|Juniper Networks
FC3497|ASUSTek COMPUTER INC.
FC34E2|Shenzhen YOUHUA Technology Co., Ltd
FC376D|SHENZHEN BILIAN ELECTRONIC CO.，LTD
FC386A|Shenzhen Skyworth Digital Technology CO., Ltd
FC395A|SonicWall
FC3CD7|Tuya Smart Inc.
FC3F7C|HUAWEI TECHNOLOGIES CO.,LTD
FC3FDB|Hewlett Packard
FC4009|zte corporation
FC4116|Google, Inc.
FC4203|Samsung Electronics Co.,Ltd
FC4345|Xiaomi Communications Co Ltd
FC4482|Intel Corporate
FC449F|zte corporation
FC4596|COMPAL INFORMATION (KUNSHAN) CO., LTD.
FC478D|SHENZHEN TOPWELL TECHNOLOGY CO., LTD.
FC47D8|Apple, Inc.
FC48EF|HUAWEI TECHNOLOGIES CO.,LTD
FC492D|Amazon Technologies Inc.
FC4A47|Nokia
FC4CEA|Dell Inc.
FC4CEF|Huawei Device Co., Ltd.
FC4D8C|SHENZHEN PANTE ELECTRONICS TECHNOLOGY CO., LTD
FC4DA6|HUAWEI TECHNOLOGIES CO.,LTD
FC4E6D|HUAWEI TECHNOLOGIES CO.,LTD
FC4EA4|Apple, Inc.
FC50D6|Huawei Device Co., Ltd.
FC51B5|HUAWEI TECHNOLOGIES CO.,LTD
FC52CE|Control iD
FC5557|Apple, Inc.
FC5708|Broadcom Limited
FC589A|Cisco Systems, Inc
FC597A|Zebra Technologies Inc.
FC5B39|Cisco Systems, Inc
FC5B8C|Xiaomi Communications Co Ltd
FC5C45|Ruckus Wireless
FC5CEE|LCFC(Hefei) Electronics Technology co., ltd
FC5F49|Zhejiang Dahua Technology Co., Ltd.
FC61E9|Fiberhome Telecommunication Technologies Co.,LTD
FC643A|Samsung Electronics Co.,Ltd
FC64BA|Xiaomi Communications Co Ltd
FC65B3|Huawei Device Co., Ltd.
FC65DE|Amazon Technologies Inc.
FC6637|Sagemcom Broadband SAS
FC66CF|Apple, Inc.
FC671F|Tuya Smart Inc.
FC6D77|Intel Corporate
FC6E83|Samsung Electronics Co.,Ltd
FC7288|Cisco Systems, Inc
FC73FB|HUAWEI TECHNOLOGIES CO.,LTD
FC7516|D-Link International
FC7774|Intel Corporate
FC79DD|Huawei Device Co., Ltd.
FC7A58|Shenzhen Skyworth Digital Technology CO., Ltd
FC7FF1|Hewlett Packard Enterprise
FC8399|Avaya Inc
FC862A|Huawei Device Co., Ltd.
FC8743|HUAWEI TECHNOLOGIES CO.,LTD
FC8827|Apple, Inc.
FC8A3D|zte corporation
FC8AF7|zte corporation
FC8B97|SHENZHEN GONGJIN ELECTRONICS CO.,LT
FC8C11|Microsoft Corporation
FC8F7D|SHENZHEN GONGJIN ELECTRONICS CO.,LT
FC8F90|Samsung Electronics Co.,Ltd
FC915D|Google, Inc.
FC923B|Nokia Corporation
FC931D|HUAWEI TECHNOLOGIES CO.,LTD
FC934E|REALTEK SEMICONDUCTOR CORP.
FC936B|Samsung Electronics Co.,Ltd
FC942E|Cisco Meraki
FC9435|HUAWEI TECHNOLOGIES CO.,LTD
FC94CE|zte corporation
FC9643|Juniper Networks
FC9947|Cisco Systems, Inc
FC9CA7|Apple, Inc.
FC9D05|Micro-Star INTL CO., LTD.
FC9DD2|Apple, Inc.
FC9E53|Intel Corporate
FC9F2A|Zyxel Communications Corporation
FC9FFD|Hangzhou Hikvision Digital Technology Co.,Ltd.
FCA0F3|HUAWEI TECHNOLOGIES CO.,LTD
FCA13E|Samsung Electronics Co.,Ltd
FCA183|Amazon Technologies Inc.
FCA27E|HUAWEI TECHNOLOGIES CO.,LTD
FCA386|SHENZHEN CHUANGWEI-RGB ELECTRONICS CO.,LTD
FCA5C8|Apple, Inc.
FCA621|Samsung Electronics Co.,Ltd
FCA667|Amazon Technologies Inc.
FCA6CD|Fiberhome Telecommunication Technologies Co.,LTD
FCA841|Avaya Inc
FCA9F5|Xiaomi Communications Co Ltd
FCAA14|GIGA-BYTE TECHNOLOGY CO.,LTD.
FCAA81|Apple, Inc.
FCAAB6|Samsung Electronics Co.,Ltd
FCAB90|HUAWEI TECHNOLOGIES CO.,LTD
FCABF5|zte corporation
FCB10D|Shenzhen Tian Kun Technology Co.,LTD.
FCB214|Apple, Inc.
FCB3AA|Intel Corporate
FCB3BC|Intel Corporate
FCB467|Espressif Inc.
FCB585|Shenzhen Water World Information Co.,Ltd.
FCB69D|Zhejiang Dahua Technology Co., Ltd.
FCB6D8|Apple, Inc.
FCB9DF|Motorola Mobility LLC, a Lenovo Company
FCBBA1|Shenzhen Minicreate Technology Co.,Ltd
FCBCD1|HUAWEI TECHNOLOGIES CO.,LTD
FCC17D|Xiaomi Communications Co Ltd
FCC233|ASUSTek COMPUTER INC.
FCC734|Samsung Electronics Co.,Ltd
FCC766|Huawei Device Co., Ltd.
FCC897|zte corporation
FCCA10|MERCUSYS TECHNOLOGIES CO., LTD.
FCCA40|Sony Interactive Entertainment Inc.
FCD436|Motorola Mobility LLC, a Lenovo Company
FCD586|Shenzhen SuperElectron Technology Co.,Ltd.
FCD5D9|Shenzhen SDMC Technology CO.,Ltd.
FCD733|TP-LINK TECHNOLOGIES CO.,LTD.
FCD749|Amazon Technologies Inc.
FCD848|Apple, Inc.
FCD908|Xiaomi Communications Co Ltd
FCDD55|Shenzhen WeWins wireless Co.,Ltd
FCDE90|Samsung Electronics Co.,Ltd
FCE1A6|HUAWEI TECHNOLOGIES CO.,LTD
FCE26C|Apple, Inc.
FCE33C|HUAWEI TECHNOLOGIES CO.,LTD
FCE557|Nokia Corporation
FCE5F0|Samsung Electronics Co.,Ltd
FCE8C0|Espressif Inc.
FCE998|Apple, Inc.
FCE9D8|Amazon Technologies Inc.
FCEB7B|HUAWEI TECHNOLOGIES CO.,LTD
FCECDA|Ubiquiti Inc
FCEFD7|HUAWEI TECHNOLOGIES CO.,LTD
FCF136|Samsung Electronics Co.,Ltd
FCF152|Sony Corporation
FCF528|Zyxel Communications Corporation
FCF5C4|Espressif Inc.
FCF647|Fiberhome Telecommunication Technologies Co.,LTD
FCF738|HUAWEI TECHNOLOGIES CO.,LTD
FCF77B|Huawei Device Co., Ltd.
FCF8AE|Intel Corporate
FCFA21|zte corporation
FCFBFB|Cisco Systems, Inc
FCFC48|Apple, Inc.
'@
# Cache de fabricantes em disco: assessments futuros reaproveitam o que já foi resolvido (rápido e funciona offline).
$script:ArquivoCacheOui = Join-Path $env:LOCALAPPDATA 'Nextec-Assessment\oui-cache.csv'
if (Test-Path $script:ArquivoCacheOui) {
    try { Import-Csv $script:ArquivoCacheOui | ForEach-Object { if ($_.Prefixo -and $_.Fabricante) { $script:CacheOui[$_.Prefixo] = $_.Fabricante } } } catch { }
}

# Base oficial de fabricantes da IEEE (baixada uma vez, ~4 MB). Depois disso a identificação é offline e confiável.
$script:OuiIeee = $null
$script:ArquivoOuiIeee = Join-Path $env:LOCALAPPDATA 'Nextec-Assessment\oui-ieee.csv'

function Format-Fabricante {
    # A IEEE registra razão social ("Micro-Star INT'L CO., LTD."). No relatório vale o nome que o técnico usa.
    param([string]$Nome)
    if (-not $Nome) { return '' }
    $curtos = [ordered]@{
        'Routerboard\.com|MikroTik' = 'MikroTik'; 'Hewlett Packard Enterprise' = 'HPE'; 'Hewlett Packard|HP Inc' = 'HP'
        'Seiko Epson' = 'Epson'; 'Hangzhou Hikvision' = 'Hikvision'; 'Zhejiang Dahua' = 'Dahua'; 'GIGA-BYTE' = 'Gigabyte'
        'Micro-Star' = 'MSI'; 'ASUSTek' = 'ASUS'; 'Intel Corporate' = 'Intel'; 'REALTEK' = 'Realtek'; 'Brother industries' = 'Brother'
        'KYOCERA' = 'Kyocera'; 'Samsung Electronics' = 'Samsung'; 'LG Electronics' = 'LG'; 'Dell Inc' = 'Dell'; 'Lenovo' = 'Lenovo'
        'Cisco Systems' = 'Cisco'; 'TP-LINK|TP-Link' = 'TP-Link'; 'Ubiquiti' = 'Ubiquiti'; 'Zyxel' = 'Zyxel'; 'Tuya Smart' = 'Tuya (IoT)'
        'Amazon Technologies' = 'Amazon'; 'Intelbras' = 'Intelbras'; 'Xiaomi' = 'Xiaomi'; 'Huawei' = 'Huawei'; 'Espressif' = 'Espressif (IoT)'
        'VMware' = 'VMware'; 'Synology' = 'Synology'; 'QNAP' = 'QNAP'; 'Positivo' = 'Positivo'; 'Multilaser' = 'Multilaser'
        'Grandstream' = 'Grandstream'; 'Yealink' = 'Yealink'; 'Fortinet' = 'Fortinet'; 'SonicWall' = 'SonicWall'; 'Ricoh' = 'Ricoh'
    }
    foreach ($k in $curtos.Keys) { if ($Nome -match "(?i)$k") { return $curtos[$k] } }
    $n = $Nome -replace '(?i)\b(co\.?,?\s*ltd\.?|ltda\.?|limited|inc\.?|incorporated|corp\.?|corporation|gmbh|llc|technolog(y|ies)|electronics?)\b', ''
    $n = ($n -replace '[,.]+\s*$', '' -replace '\s{2,}', ' ').Trim(' ,.')
    if ($n.Length -gt 28) { $n = $n.Substring(0, 27) + '…' }
    $n
}

function Initialize-OuiIeee {
    if ($null -ne $script:OuiIeee) { return }
    $script:OuiIeee = @{}
    # 1) Base embutida no próprio script: funciona offline em qualquer máquina, sem arquivo do lado.
    try {
        if ($script:OuiEmbutido) {
            $sr = New-Object IO.StringReader ($script:OuiEmbutido)
            while ($null -ne ($linha = $sr.ReadLine())) {
                $i = $linha.IndexOf('|')
                if ($i -gt 0) { $script:OuiIeee[$linha.Substring(0, $i)] = $linha.Substring($i + 1) }
            }
            $sr.Dispose()
        }
    } catch { Write-Log "Base embutida de fabricantes não carregou: $($_.Exception.Message)" 'AVISO' }
    $embutidos = $script:OuiIeee.Count
    # 2) Se houver a base completa (oui.csv ao lado ou cache), ela complementa. Download só como bônus.
    try {
        # 1) Prioriza um oui.csv ao lado do script (levado junto = offline, sem depender de rede).
        $ouiLocalArquivo = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'oui.csv' } else { $null }
        $fonte = $null
        if ($ouiLocalArquivo -and (Test-Path $ouiLocalArquivo)) {
            $fonte = $ouiLocalArquivo
        } else {
            # 2) Senão, usa o cache já baixado; baixa só se não existir ou estiver com mais de 120 dias.
            $dir = Split-Path $script:ArquivoOuiIeee
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $precisaBaixar = -not (Test-Path $script:ArquivoOuiIeee)
            if (-not $precisaBaixar -and ((Get-Date) - (Get-Item $script:ArquivoOuiIeee).LastWriteTime).TotalDays -gt 120) { $precisaBaixar = $true }
            if ($precisaBaixar -and $ConsultasWeb -and -not $SemConsultaInternet) {
                Write-Log 'Baixando a base de fabricantes da IEEE (uma vez; ~4 MB)...'
                try {
                    Invoke-WebRequest -Uri 'https://standards-oui.ieee.org/oui/oui.csv' -OutFile $script:ArquivoOuiIeee -TimeoutSec 60 -UseBasicParsing
                } catch {
                    Write-Log "Download da base IEEE falhou ($($_.Exception.Message)). Coloque um oui.csv ao lado do script para identificar fabricantes offline." 'AVISO'
                }
            }
            if (Test-Path $script:ArquivoOuiIeee) { $fonte = $script:ArquivoOuiIeee }
        }
        if ($fonte) {
            Import-Csv $fonte | ForEach-Object {
                $a = "$($_.Assignment)".ToUpper()
                if ($a -and -not $script:OuiIeee.ContainsKey($a)) { $script:OuiIeee[$a] = $_.'Organization Name' }
            }
            Write-Log "Base de fabricantes: $embutidos embutidos + $(Split-Path $fonte -Leaf) = $($script:OuiIeee.Count) prefixos."
        } else {
            Write-Log "Base de fabricantes: $embutidos prefixos embutidos (base completa não disponível; o que faltar tenta online)."
        }
    } catch { Write-Log "Base completa de fabricantes não carregou ($($_.Exception.Message)); seguindo com os $embutidos embutidos." 'AVISO' }
}

function Get-FabricanteMac {
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return '' }
    $prefixo = ($Mac.ToUpper() -replace '[:.]', '-')
    if ($prefixo.Length -lt 8) { return '' }
    $prefixo = $prefixo.Substring(0, 8)
    # Bit "localmente administrado" ligado = MAC aleatório (celulares e notebooks com privacidade de Wi-Fi).
    if ([Convert]::ToInt32($prefixo.Substring(0, 2), 16) -band 2) { return 'MAC aleatório (privacidade)' }
    if ($script:OuiLocal.ContainsKey($prefixo)) { return $script:OuiLocal[$prefixo] }
    if ($script:CacheOui.ContainsKey($prefixo)) { return $script:CacheOui[$prefixo] }
    Initialize-OuiIeee
    $hex = $prefixo -replace '-', ''
    if ($script:OuiIeee.ContainsKey($hex)) { $nomeCurto = Format-Fabricante $script:OuiIeee[$hex]; $script:CacheOui[$prefixo] = $nomeCurto; return $nomeCurto }
    $fabricante = ''
    if ($ConsultasWeb -and -not $SemConsultaInternet) {
        foreach ($tentativa in 1, 2) {
            Start-Sleep -Milliseconds 1500   # a API gratuita aceita ~1 consulta por segundo
            try {
                $fabricante = Format-Fabricante ([string](Invoke-RestMethod -Uri "https://api.macvendors.com/$prefixo" -TimeoutSec 6 -UseBasicParsing))
                break
            } catch {
                $fabricante = ''
                if ("$($_.Exception.Message)" -notmatch '429|Too Many|limit') { break }  # só repete se for limite de taxa
            }
        }
    }
    $script:CacheOui[$prefixo] = $fabricante   # guarda no cache da execução (inclusive vazio, para não repetir a consulta)
    $fabricante
}

function Get-CategoriaDispositivo {
    param([string]$Tipo)
    switch -Regex ($Tipo) {
        'fora de banda'         { return 'Gerência (iDRAC/iLO)' }
        'Servidor'              { return 'Servidores' }
        'Windows'               { return 'Estações' }
        'Impressora'            { return 'Impressoras' }
        'Câmera|DVR|NVR'        { return 'Câmeras/DVR' }
        '^Rede '                { return 'Rede' }
        'Storage|NAS'           { return 'NAS' }
        'ponto|biometria'       { return 'Ponto/Acesso' }
        'VoIP'                  { return 'Telefonia' }
        'Linux'                 { return 'Linux/SSH' }
        'MAC aleatório|Apple'   { return 'Móveis/Wi-Fi' }
        'IoT|Assistente|TV /'   { return 'IoT / TV / assistente' }
        'painel web'            { return 'Painel web não identificado' }
        default                 { return 'Não identificado' }
    }
}

$script:CorCategoria = [ordered]@{
    'Rede' = '#ef8c00'; 'Servidores' = '#0D0035'; 'Gerência (iDRAC/iLO)' = '#b71c1c'; 'Estações' = '#5C50FF'; 'Impressoras' = '#00897b'
    'Câmeras/DVR' = '#c62828'; 'NAS' = '#6a1b9a'; 'Ponto/Acesso' = '#00838f'; 'Telefonia' = '#8d6e63'
    'Linux/SSH' = '#2e7d32'; 'Móveis/Wi-Fi' = '#0277bd'; 'IoT / TV / assistente' = '#7cb342'
    'Painel web não identificado' = '#9575cd'; 'Não identificado' = '#607d8b'; 'Máquina de coleta' = '#455a64'
}

# ============================================================================
# Execução sem intervenção, credencial única e pré-validação
# ============================================================================

function Test-CredencialDominio {
    # $true = aceita, $false = recusada, $null = não deu para validar (DC inalcançável).
    param([pscredential]$Cred, [string]$Dominio)
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $tipo = [System.DirectoryServices.AccountManagement.ContextType]::Domain
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext($tipo, $Dominio)
        try {
            return [bool]$ctx.ValidateCredentials($Cred.UserName, $Cred.GetNetworkCredential().Password,
                [System.DirectoryServices.AccountManagement.ContextOptions]::Negotiate)
        } finally { $ctx.Dispose() }
    } catch { return $null }
}

function Request-CredencialDominio {
    # Uma janela de login e senha. Duas tentativas no máximo, para não bloquear a conta do técnico.
    param([string]$Dominio, [string]$Motivo)
    if (-not (Test-TemTeclado)) { return $null }
    $netbios = if ($Dominio) { ($Dominio -split '\.')[0].ToUpper() } else { $env:USERDOMAIN }
    for ($tentativa = 1; $tentativa -le 2; $tentativa++) {
        $c = try { Get-Credential -UserName "$netbios\" -Message $Motivo } catch { $null }
        if (-not $c) { return $null }
        if ($c.UserName -notmatch '[\\@]') { $c = New-Object System.Management.Automation.PSCredential("$netbios\$($c.UserName)", $c.Password) }
        $ok = Test-CredencialDominio $c $Dominio
        if ($ok -ne $false) { return $c }
        Write-Log "Login ou senha recusados pelo domínio (tentativa $tentativa de 2)." 'AVISO'
    }
    $null
}

function Test-AcessoRemoto {
    # Abre uma sessão CIM (WinRM, depois DCOM) e lê o SO. Distingue desligado/firewall de acesso negado.
    param([string]$Alvo, [pscredential]$Cred)
    $r = [ordered]@{ Computador = $Alvo; Resultado = ''; Protocolo = ''; Detalhe = '' }
    $p5985 = Test-PortaRapida $Alvo 5985 1000
    $p135  = Test-PortaRapida $Alvo 135 1000
    if (-not ($p5985 -or $p135)) {
        $r.Resultado = 'Inacessível'; $r.Detalhe = 'Portas 5985 e 135 fechadas (desligado ou firewall)'
        return [pscustomobject]$r
    }
    $negou = $false
    foreach ($proto in 'Wsman', 'Dcom') {
        if (($proto -eq 'Wsman' -and -not $p5985) -or ($proto -eq 'Dcom' -and -not $p135)) { continue }
        $sessao = $null
        try {
            $param = @{ ComputerName = $Alvo; SessionOption = (New-CimSessionOption -Protocol $proto); OperationTimeoutSec = 12; ErrorAction = 'Stop' }
            if ($Cred) { $param.Credential = $Cred }
            $sessao = New-CimSession @param
            $so = Get-CimInstance -CimSession $sessao -ClassName Win32_OperatingSystem -ErrorAction Stop
            $r.Resultado = 'OK'; $r.Protocolo = $proto; $r.Detalhe = "$($so.Caption)".Trim()
            return [pscustomobject]$r
        } catch {
            $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
            if ($msg -match '(?i)access is denied|acesso negado|0x80070005|unauthorized|logon failure|0x8007052e|user name or password|nome de usu.rio ou senha|senha incorret|bad password') { $negou = $true }
            $r.Protocolo = $proto
            $r.Detalhe = if ($msg.Length -gt 140) { $msg.Substring(0, 140) } else { $msg }
        } finally { if ($sessao) { Remove-CimSession -CimSession $sessao -ErrorAction SilentlyContinue } }
    }
    $r.Resultado = if ($negou) { 'Acesso negado' } else { 'Falha' }
    [pscustomobject]$r
}

function Invoke-PreValidacao {
    # Confere, antes de coletar, se o ambiente permite a coleta completa. Nada aqui altera o sistema.
    # Devolve os itens, a credencial a usar nas estações (ou $null) e se há impedimento real.
    $itens = New-Object System.Collections.Generic.List[object]
    $registrar = {
        param($Item, $Status, $Detalhe)
        $itens.Add([pscustomobject]@{ Item = $Item; Status = $Status; Detalhe = $Detalhe })
        $nivel = switch ($Status) { 'OK' { 'INFO' } 'FALHA' { 'ERRO' } default { 'AVISO' } }
        Write-Log "[$Status] ${Item}: $Detalhe" $nivel -SoArquivo
        Write-ItemValidacao $Item $Status $Detalhe
    }
    $bloqueio = $false
    $credencialAtiva = $Credencial
    Write-Secao 'Pré-validação'
    $avs = @(Get-AntivirusComportamental)
    if ($avs.Count) { & $registrar 'Antivírus' 'AVISO' "$($avs -join ', ') com bloqueio por comportamento. Se parar, libere C:\ProgramData\Nextec\" }
    else { & $registrar 'Antivírus' 'OK' 'Sem bloqueio por comportamento conhecido' }

    # Máquina de coleta
    & $registrar 'PowerShell' 'OK' "$($PSVersionTable.PSVersion)"
    $modo = "$($ExecutionContext.SessionState.LanguageMode)"
    if ($modo -eq 'FullLanguage') { & $registrar 'Modo de linguagem' 'OK' $modo }
    else { & $registrar 'Modo de linguagem' 'FALHA' "$modo (AppLocker/WDAC restringindo o PowerShell; a coleta não funciona assim)"; $bloqueio = $true }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        & $registrar 'Processo' 'AVISO' 'PowerShell de 32 bits em Windows de 64 bits; parte do registro e dos módulos fica invisível'
    }
    if ($ehAdmin) { & $registrar 'Privilégio local' 'OK' 'Administrador (elevado)' }
    else { & $registrar 'Privilégio local' 'AVISO' 'Sem elevação: BitLocker, segurança e Hyper-V ficam de fora' }
    try {
        $raiz = [IO.Path]::GetPathRoot($script:PastaSaida)
        $livreGB = [math]::Round(([IO.DriveInfo]$raiz).AvailableFreeSpace / 1GB, 1)
        if ($livreGB -lt 0.5) { & $registrar 'Espaço para a saída' 'FALHA' "$livreGB GB livres em $raiz"; $bloqueio = $true }
        elseif ($livreGB -lt 2) { & $registrar 'Espaço para a saída' 'AVISO' "$livreGB GB livres em $raiz" }
        else { & $registrar 'Espaço para a saída' 'OK' "$livreGB GB livres em $raiz" }
    } catch { & $registrar 'Espaço para a saída' 'AVISO' 'Não foi possível medir (destino de rede?)' }

    # Domínio e Active Directory
    $dominio = ''
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; if ($cs.PartOfDomain) { $dominio = $cs.Domain } } catch { }
    $temModuloAd = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    $amostra = @()
    if ($SemAD) {
        & $registrar 'Active Directory' 'AVISO' 'Ignorado por -SemAD'
    } elseif (-not $dominio) {
        & $registrar 'Domínio' 'AVISO' 'Máquina fora de domínio: coleta do AD e inventário das estações serão ignorados'
    } else {
        & $registrar 'Domínio' 'OK' $dominio
        if ($temModuloAd) { & $registrar 'Módulo ActiveDirectory' 'OK' 'Disponível' }
        else { & $registrar 'Módulo ActiveDirectory' 'AVISO' 'Ausente: rodar no controlador de domínio ou instalar RSAT-AD-PowerShell' }
        try {
            $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController().Name
            & $registrar 'Controlador de domínio' 'OK' $dc
        } catch { & $registrar 'Controlador de domínio' 'AVISO' "Sem resposta do DC: $($_.Exception.Message)" }
        try {
            $sids = @([Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value })
            if ($sids | Where-Object { $_ -match '^S-1-5-21-.*-512$' }) { & $registrar 'Conta atual' 'OK' "$env:USERDOMAIN\$env:USERNAME é Admins. do domínio" }
            else { & $registrar 'Conta atual' 'AVISO' "$env:USERDOMAIN\$env:USERNAME não aparece como Admins. do domínio; o teste nas estações abaixo decide se isso importa" }
        } catch { }

        # Amostra de estações para testar o acesso remoto de verdade
        if ($temModuloAd -and -not $SemInventarioRemoto) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $limite = (Get-Date).AddDays(-30)
                $paramAd = @{ Filter = 'Enabled -eq $true'; Properties = 'OperatingSystem', 'LastLogonDate', 'DNSHostName'; ErrorAction = 'Stop' }
                if ($credencialAtiva) { $paramAd.Credential = $credencialAtiva }
                $todos = @(Get-ADComputer @paramAd | Where-Object {
                    $_.OperatingSystem -like 'Windows*' -and $_.Name -ne $env:COMPUTERNAME -and $_.LastLogonDate -ge $limite })
                $amostra = if ($todos.Count -gt 0) { @($todos | Get-Random -Count ([math]::Min(6, $todos.Count)) | ForEach-Object { if ($_.DNSHostName) { $_.DNSHostName } else { $_.Name } }) } else { @() }
                & $registrar 'Computadores no AD' 'OK' "$($todos.Count) ativos nos últimos 30 dias; testando $($amostra.Count)"
            } catch { & $registrar 'Computadores no AD' 'AVISO' "Não foi possível listar: $($_.Exception.Message)" }
        }
    }

    # Acesso remoto às estações, com a conta atual e, se preciso, com um login único
    if ($amostra.Count -gt 0) {
        $testar = { param($cred) @($amostra | ForEach-Object { Test-AcessoRemoto $_ $cred }) }
        $contar = { param($r, $tipo) @($r | Where-Object Resultado -eq $tipo).Count }

        if (-not $credencialAtiva -and $PedirCredencial) {
            $credencialAtiva = Request-CredencialDominio $dominio 'Conta administradora do domínio, usada só nesta coleta. Não é gravada.'
        }
        $resultado = & $testar $credencialAtiva
        $ok = & $contar $resultado 'OK'; $neg = & $contar $resultado 'Acesso negado'

        if (-not $credencialAtiva -and $neg -gt 0 -and $neg -ge $ok) {
            Write-Log '  A conta atual foi negada nas estações. Pedindo um login de administrador do domínio.' 'AVISO'
            $nova = Request-CredencialDominio $dominio 'A conta atual não administra as estações. Informe uma conta administradora do domínio, usada só nesta coleta. Não é gravada.'
            if ($nova) {
                $resultado2 = & $testar $nova
                $ok2 = & $contar $resultado2 'OK'
                if ($ok2 -gt $ok) { $credencialAtiva = $nova; $resultado = $resultado2; $ok = $ok2; $neg = & $contar $resultado 'Acesso negado' }
                else { & $registrar 'Login informado' 'AVISO' 'Não melhorou o acesso; mantida a conta atual' }
            }
        }
        $quem = if ($credencialAtiva) { $credencialAtiva.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }
        $inacessiveis = & $contar $resultado 'Inacessível'; $falhas = & $contar $resultado 'Falha'
        $detalheTeste = "$ok OK | $neg acesso negado | $inacessiveis sem resposta | $falhas outras falhas (de $($amostra.Count), conta $quem)"
        if ($ok -eq $amostra.Count) { & $registrar 'Acesso remoto às estações' 'OK' $detalheTeste }
        elseif ($ok -gt 0) { & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. Parte das estações vai ficar sem inventário remoto (a coleta local por GPO cobre essas)" }
        elseif ($neg -gt 0) { & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. A conta não é administradora nas estações: sem inventário delas" }
        elseif ($inacessiveis -eq $amostra.Count) {
            $agora = Get-Date
            $foraExpediente = $agora.Hour -lt 7 -or $agora.Hour -ge 19 -or $agora.DayOfWeek -in 'Saturday', 'Sunday'
            $dicaHorario = if ($foraExpediente) { " Coleta às $($agora.ToString('HH:mm')) fora do expediente: as estações costumam estar desligadas, repetir em horário comercial." } else { '' }
            & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. Estações desligadas ou com firewall bloqueando WinRM/DCOM (liberar por GPO).$dicaHorario"
        }
        else { & $registrar 'Acesso remoto às estações' 'AVISO' $detalheTeste }
        foreach ($t in $resultado | Where-Object Resultado -ne 'OK') {
            Write-Log "    $($t.Computador): $($t.Resultado) $($t.Protocolo) $($t.Detalhe)" 'AVISO'
        }
    }

    # O que será varrido
    if (-not $SemVarreduraRede) {
        try {
            $cidrs = if ($Subredes) { @($Subredes) } else { @(Get-SubredesLocais) }
            if ($cidrs.Count -gt 0) { & $registrar 'Sub-redes a varrer' 'OK' ($cidrs -join ', ') }
            else { & $registrar 'Sub-redes a varrer' 'AVISO' 'Nenhuma detectada; informe -Subredes' }
        } catch { & $registrar 'Sub-redes a varrer' 'AVISO' $_.Exception.Message }
    }

    [pscustomobject]@{ Itens = $itens.ToArray(); Credencial = $credencialAtiva; Bloqueio = $bloqueio }
}

# ============================================================================
# Início
# ============================================================================

$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "Assessment Nextec v$script:VersaoAssessment | Cliente: $Cliente | Máquina: $env:COMPUTERNAME | Saída: $script:PastaSaida" -SoArquivo
if ($SemValidacao) { $script:TotalSecoes-- }
Write-Cabecalho

if (-not $ehAdmin) {
    # O script não se eleva sozinho: o PowerShell precisa ser aberto como administrador antes de executar.
    Write-Host ''
    Write-Host 'Este assessment precisa ser executado como administrador.' -ForegroundColor Yellow
    Write-Host 'Feche esta janela, abra o PowerShell com "Executar como administrador" e rode o comando de novo.' -ForegroundColor Yellow
    Write-Host ''
    Remove-Item -LiteralPath $script:PastaSaida -Recurse -Force -ErrorAction SilentlyContinue
    if ($Automatico) { exit 1 }
    return
}

# Sem pré-validação, o aviso de antivírus com bloqueio por comportamento sai aqui mesmo.
if ($SemValidacao) {
    $antivirusComportamental = @(Get-AntivirusComportamental)
    if ($antivirusComportamental.Count) {
        Write-Host ''
        Write-Log "$($antivirusComportamental -join ', ') com bloqueio por comportamento. Se a coleta parar, confira a exclusão de C:\ProgramData\Nextec\" 'AVISO'
    }
}

# Pré-validação: confere o ambiente e, se a conta atual não alcançar as estações, pede o login único.
if (-not $SemValidacao) {
    $validacao = Invoke-PreValidacao
    Save-Dados 'validacao' $validacao.Itens 'Pré-validação do ambiente antes da coleta'
    if ($validacao.Credencial) {
        $script:CredencialRemota = $validacao.Credencial
        # Cmdlets do AD passam a usar a mesma conta; as chamadas locais continuam com a sessão atual.
        $PSDefaultParameterValues['Get-AD*:Credential'] = $script:CredencialRemota
    }
    if ($validacao.Bloqueio) { throw 'Pré-validação reprovada: veja os itens FALHA acima e em validacao.csv.' }
    if ($SoValidar) {
        Write-Host ''
        Write-Host "   Validação concluída. Detalhes em $script:PastaSaida" -ForegroundColor Green
        Write-Host ''
        if ($Automatico) { try { Start-Process explorer.exe -ArgumentList "`"$script:PastaSaida`"" } catch { } }
        exit 0
    }
} elseif ($Credencial) {
    $script:CredencialRemota = $Credencial
    $PSDefaultParameterValues['Get-AD*:Credential'] = $script:CredencialRemota
}

$script:Resumo['Cliente'] = $Cliente
$script:Resumo['Data da coleta'] = Format-Data $script:Inicio
$script:Resumo['Executado por'] = "$env:USERDOMAIN\$env:USERNAME"
$script:Resumo['Executado em'] = $env:COMPUTERNAME
$script:Resumo['Conta usada nas estações'] = if ($script:CredencialRemota) { $script:CredencialRemota.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }
$script:Resumo['Ritmo da varredura'] = if ($Agressivo) { "Agressivo (lotes de $($script:LotePortas), sem pausa)" } else { "Suave (lotes de $($script:LotePortas), pausa de $($script:PausaLoteMs) ms)" }
if ($Agressivo) { Write-Log 'Modo agressivo: rajadas maiores de conexões TCP. Pode saturar roteador SOHO e derrubar o DNS do cliente.' 'AVISO' }

# ============================================================================
# 1. Servidor local
# ============================================================================

Write-Secao 'Servidor'

Invoke-Etapa 'Hardware e sistema operacional' {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $so   = Get-CimInstance Win32_OperatingSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    $exibicao = Get-ValorRegistro 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
    $suporte = Get-SituacaoSuporte -Caption $so.Caption -Build ([int]$so.BuildNumber)
    $uptime = (Get-Date) - $so.LastBootUpTime

    # A coleta pode ser feita de qualquer máquina, então o papel é detectado, não presumido.
    $script:EhServidor = ([int]$cs.DomainRole -ge 2) -or ($so.Caption -match 'Server')
    $script:PapelMaquina = if ([int]$cs.DomainRole -ge 4) { 'Controlador de domínio' }
        elseif ($script:EhServidor) { 'Servidor' }
        elseif ([int]$cs.DomainRole -eq 1) { 'Estação no domínio' }
        else { 'Estação fora do domínio' }

    $script:Resumo['Computador analisado'] = $env:COMPUTERNAME
    $script:Resumo['Papel da máquina'] = $script:PapelMaquina
    $script:Resumo['Usuário logado no console'] = "$($cs.UserName)"
    $script:Resumo['Fabricante / modelo'] = "$($cs.Manufacturer) $($cs.Model)"
    $script:Resumo['Service tag / nº de série'] = $bios.SerialNumber
    $script:Resumo['BIOS'] = "$($bios.SMBIOSBIOSVersion) ($(Format-Data $bios.ReleaseDate))"
    $script:Resumo['Sistema operacional'] = "$($so.Caption) $exibicao (build $($so.BuildNumber))"
    $script:Resumo['Situação de suporte do SO'] = $suporte
    $script:Resumo['Processador'] = ($cpus | ForEach-Object { "$($_.Name.Trim()) ($($_.NumberOfCores) núcleos)" }) -join ' + '
    $memTotal = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $memLivre = if ($so.FreePhysicalMemory) { [math]::Round($so.FreePhysicalMemory / 1MB, 1) } else { $null }
    $script:Resumo['Memória'] = if ($memLivre) { "$memTotal GB ($memLivre GB livres, $([math]::Round((($memTotal - $memLivre) / $memTotal) * 100, 0))% em uso)" } else { "$memTotal GB" }
    if ($memLivre -and (($memTotal - $memLivre) / $memTotal) -gt 0.9) {
        Add-Alerta 'Média' 'Servidor' 'Memória quase esgotada' "$memLivre GB livres de $memTotal GB"
    }
    $script:Resumo['Instalado em'] = Format-Data $so.InstallDate
    $script:Resumo['Último boot'] = '{0} ({1} dias ligado)' -f (Format-Data $so.LastBootUpTime), [int]$uptime.TotalDays
    $script:Resumo['Domínio / grupo de trabalho'] = $cs.Domain
    $script:Resumo['Máquina virtual'] = if ($cs.Model -match 'Virtual|VMware|KVM|HVM|QEMU') { 'Sim' } else { 'Não' }

    if ($suporte -like 'Fora de suporte*') { Add-Alerta 'Alta' 'Servidor' 'SO fora de suporte' "$($so.Caption): $suporte (Provimento 213, art. 4º, § 3º)" }
    elseif ($suporte -like '*encerra em*') { Add-Alerta 'Média' 'Servidor' 'SO perto do fim do suporte' "$($so.Caption): $suporte" }
    if ($uptime.TotalDays -gt 60) { Add-Alerta 'Baixa' 'Servidor' 'Muito tempo sem reiniciar' "$([int]$uptime.TotalDays) dias ligado; atualizações podem estar pendentes" }

    # Equipamento que faz papel de servidor mas é estação comum (Windows de desktop ou sem linha de servidor).
    $soDesktop = $so.Caption -notmatch 'Server'
    $papelServidor = $script:EhServidor -or ($script:ComputadoresAD.Count -eq 0 -and $cs.DomainRole -ge 2)
    if ($soDesktop -and ($script:PapelMaquina -eq 'Servidor' -or $cs.Model -match 'System Product Name|To be filled')) {
        Add-Alerta 'Média' 'Servidor' 'Equipamento de estação no papel de servidor' "$($cs.Manufacturer) $($cs.Model) com $($so.Caption): sem hardware de servidor (RAID, fonte redundante, ECC) nem SO de servidor"
    }

    # Link de garantia pronto, a partir do fabricante e do número de série.
    $serie = "$($bios.SerialNumber)".Trim()
    $serieValida = $serie -and $serie -notmatch '(?i)^(System Serial Number|To be filled|Default string|None|0+)$'
    if ($serieValida) {
        $linkGarantia = switch -Wildcard ("$($cs.Manufacturer)".ToLower()) {
            'dell*'               { "https://www.dell.com/support/home/pt-br/product-support/servicetag/$serie" }
            '*lenovo*'            { "https://pcsupport.lenovo.com/br/pt/warrantylookup?serialnumber=$serie" }
            { $_ -match 'hp|hewlett' } { 'https://support.hp.com/br-pt/checkwarranty' }
            default               { '' }
        }
        if ($linkGarantia) { $script:Resumo['Consulta de garantia'] = $linkGarantia }
    }

    # Memória: pentes instalados, slots livres e máximo suportado, para planejar upgrade.
    try {
        $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $array  = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
        $slots  = if ($array.MemoryDevices) { [int]$array.MemoryDevices } else { $pentes.Count }
        $maxGB  = if ($array.MaxCapacityEx) { [math]::Round($array.MaxCapacityEx / 1MB, 0) } elseif ($array.MaxCapacity) { [math]::Round($array.MaxCapacity / 1MB, 0) } else { $null }
        $tipoPente = { param($t) switch ([int]$t) { 20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { '' } } }
        $memModulos = @($pentes | ForEach-Object {
            [pscustomobject]@{ Slot = $_.DeviceLocator; CapacidadeGB = [math]::Round($_.Capacity / 1GB, 0)
                Tipo = (& $tipoPente $_.SMBIOSMemoryType); VelocidadeMHz = $_.Speed; Fabricante = "$($_.Manufacturer)".Trim(); NumeroSerie = "$($_.SerialNumber)".Trim() }
        })
        Save-Dados 'memoria_modulos' $memModulos 'Pentes de memória instalados, por slot'
        $livres = $slots - $pentes.Count
        $script:Resumo['Memória (slots)'] = "$($pentes.Count) de $slots ocupados$(if ($livres -gt 0) { ", $livres livre(s)" })$(if ($maxGB) { "; máximo $maxGB GB" })"
        if ($livres -le 0 -and $maxGB -and ([math]::Round($cs.TotalPhysicalMemory / 1GB, 0) -ge $maxGB)) {
            Add-Alerta 'Baixa' 'Servidor' 'Memória no limite da placa' "Todos os $slots slots ocupados e no máximo suportado ($maxGB GB); upgrade exige troca de pentes"
        }
    } catch { }

    Save-Dados 'maquina_hardware' ([pscustomobject]@{
        Computador = $env:COMPUTERNAME; Papel = $script:PapelMaquina; Fabricante = $cs.Manufacturer; Modelo = $cs.Model
        NumeroSerie = $bios.SerialNumber; BIOS = $bios.SMBIOSBIOSVersion; DataBIOS = Format-Data $bios.ReleaseDate
        SO = $so.Caption; Versao = $exibicao; Build = $so.BuildNumber; Suporte = $suporte
        Processador = $script:Resumo['Processador']; MemoriaGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        InstaladoEm = Format-Data $so.InstallDate; UltimoBoot = Format-Data $so.LastBootUpTime
        Dominio = $cs.Domain; UsuarioConsole = $cs.UserName
    }) 'Hardware, BIOS e SO da máquina que executou a coleta'
}

Invoke-Etapa 'Discos, RAID e volumes' {
    $discosWmi = @(Get-CimInstance Win32_DiskDrive | Select-Object Index, Model, SerialNumber, InterfaceType, Status,
        @{ n = 'TamanhoGB'; e = { [math]::Round($_.Size / 1GB, 1) } }, Partitions)
    Save-Dados 'discos_wmi' $discosWmi 'Discos vistos pelo Windows (inclui discos virtuais da controladora RAID)'

    if (Test-ComandoExiste 'Get-PhysicalDisk') {
        # O serviço de armazenamento (Storage Spaces/SMAPI) trava com controladora ou disco USB com defeito: consulta com limite.
        $discosPd = @(try {
            # Os campos viram texto e número dentro do runspace, onde o módulo Storage traduz os enums (0 vira "Healthy").
            Invoke-ComLimiteTempo {
                foreach ($pd in Get-PhysicalDisk) {
                    $c = try { $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
                    [pscustomobject]@{
                        Disco = [pscustomobject]@{
                            FriendlyName = "$($pd.FriendlyName)"; SerialNumber = "$($pd.SerialNumber)".Trim()
                            MediaType = "$($pd.MediaType)"; BusType = "$($pd.BusType)"
                            HealthStatus = "$($pd.HealthStatus)"; OperationalStatus = "$($pd.OperationalStatus)"; Size = [double]$pd.Size
                        }
                        Contador = if ($c) {
                            [pscustomobject]@{ Wear = $c.Wear; Temperature = $c.Temperature; PowerOnHours = $c.PowerOnHours
                                ReadErrorsTotal = $c.ReadErrorsTotal; WriteErrorsTotal = $c.WriteErrorsTotal }
                        } else { $null }
                    }
                }
            } 'Discos físicos e SMART' 60
        } catch { })
        $fisicos = @($discosPd.Disco | Select-Object FriendlyName, SerialNumber, MediaType, BusType, HealthStatus, OperationalStatus,
            @{ n = 'TamanhoGB'; e = { [math]::Round($_.Size / 1GB, 1) } })
        Save-Dados 'discos_fisicos' $fisicos 'Discos físicos (Storage Spaces)'
        foreach ($d in $fisicos | Where-Object { $_.HealthStatus -ne 'Healthy' }) {
            Add-Alerta 'Alta' 'Armazenamento' "Disco com saúde $($d.HealthStatus)" "$($d.FriendlyName) ($($d.SerialNumber))"
        }

        # Saúde real de cada disco: desgaste do SSD, horas ligado, temperatura e erros de leitura.
        $saude = @(foreach ($item in $discosPd) {
            $pd = $item.Disco
            $c = $item.Contador
            $semLeitura = (-not $c) -or (($null -eq $c.Wear -or $c.Wear -eq 0) -and (-not $c.Temperature) -and (-not $c.PowerOnHours) -and ($pd.BusType -eq 'RAID' -or "$($pd.MediaType)" -eq 'Unspecified'))
            if ($semLeitura -and $c) { $script:DiscosSemSmart += "$($pd.FriendlyName)" }
            if ($c -and -not $semLeitura) {
                [pscustomobject]@{ Disco = $pd.FriendlyName; MediaType = $pd.MediaType
                    DesgastePct = $c.Wear; TemperaturaC = $c.Temperature; HorasLigado = $c.PowerOnHours
                    ErrosLeitura = $c.ReadErrorsTotal; ErrosEscrita = $c.WriteErrorsTotal }
            }
        })
        if ($script:DiscosSemSmart.Count) {
            $script:Resumo['Saúde dos discos'] = "Não lida: $(($script:DiscosSemSmart | Select-Object -Unique) -join ', ') esconde os discos físicos do Windows (SMART só pelo utilitário da controladora ou pelo iDRAC)"
            Add-Alerta 'Info' 'Armazenamento' 'Saúde dos discos físicos não lida' "Controladora RAID ($(($script:DiscosSemSmart | Select-Object -Unique) -join ', ')) não expõe SMART ao Windows: conferir no iDRAC/OMSA ou instalar perccli/storcli"
        }
        if ($saude.Count) {
            Save-Dados 'discos_saude' $saude 'Saúde SMART dos discos: desgaste, temperatura, horas ligado e erros'
            foreach ($s in $saude) {
                if ($null -ne $s.DesgastePct -and $s.DesgastePct -ge 90) { Add-Alerta 'Alta' 'Armazenamento' 'SSD perto do fim da vida útil' "$($s.Disco): $($s.DesgastePct)% de desgaste" }
                elseif ($null -ne $s.DesgastePct -and $s.DesgastePct -ge 70) { Add-Alerta 'Média' 'Armazenamento' 'SSD com desgaste alto' "$($s.Disco): $($s.DesgastePct)% de desgaste" }
                if ($s.ErrosLeitura -gt 0 -or $s.ErrosEscrita -gt 0) { Add-Alerta 'Média' 'Armazenamento' 'Disco com erros de E/S' "$($s.Disco): $($s.ErrosLeitura) leitura, $($s.ErrosEscrita) escrita" }
                if ($s.TemperaturaC -ge 60) { Add-Alerta 'Média' 'Armazenamento' 'Disco em temperatura alta' "$($s.Disco): $($s.TemperaturaC) °C" }
            }
            $script:Resumo['Saúde dos discos'] = ($saude | ForEach-Object { "$($_.Disco): $(if ($null -ne $_.DesgastePct) { "$($_.DesgastePct)% desgaste, " })$($_.HorasLigado)h, $($_.TemperaturaC)°C" }) -join ' | '
        }
    }

    try {
        $falhas = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure })
        foreach ($f in $falhas) { Add-Alerta 'Alta' 'Armazenamento' 'SMART prevê falha de disco' $f.InstanceName }
    } catch { }

    $raid = @($discosWmi | Where-Object { $_.Model -match 'PERC|RAID|LOGICAL|Virtual|MegaRAID|Smart Array' })
    $script:Resumo['Discos (Windows)'] = ($discosWmi | ForEach-Object { "$($_.Model) $($_.TamanhoGB) GB" }) -join ' | '
    # Sem redundância: servidor com um disco só, ou com vários discos avulsos sem RAID/espelhamento.
    if ($script:EhServidor -and $raid.Count -eq 0) {
        if ($discosWmi.Count -eq 1) {
            Add-Alerta 'Alta' 'Armazenamento' 'Servidor com disco único sem RAID aparente' "$($discosWmi[0].Model); confirmar redundância na controladora"
        } elseif ($discosWmi.Count -gt 1) {
            Add-Alerta 'Alta' 'Armazenamento' 'Servidor com discos avulsos sem RAID aparente' "$($discosWmi.Count) discos sem espelhamento: perda de um disco derruba o que estiver nele; confirmar redundância"
        }
    }

    # RAID por utilitário do fabricante, quando a controladora não aparece como disco lógico no Windows.
    $raidUtils = @(
        @{ Nome = 'storcli'; Cmd = { storcli /c0 show }; Desc = 'Broadcom/LSI MegaRAID (storcli)' },
        @{ Nome = 'perccli'; Cmd = { perccli /c0 show }; Desc = 'Dell PERC (perccli)' },
        @{ Nome = 'ssacli';  Cmd = { ssacli ctrl all show config }; Desc = 'HPE Smart Array (ssacli)' },
        @{ Nome = 'arcconf'; Cmd = { arcconf getconfig 1 }; Desc = 'Microchip/Adaptec (arcconf)' }
    )
    foreach ($u in $raidUtils) {
        if (Test-ComandoExiste $u.Nome) { Save-Texto "raid_$($u.Nome)" $u.Cmd $u.Desc }
    }

    $volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $livrePct = if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100, 1) } else { 0 }
        [pscustomobject]@{ Unidade = $_.DeviceID; Rotulo = $_.VolumeName; Sistema = $_.FileSystem
            TamanhoGB = [math]::Round($_.Size / 1GB, 1); LivreGB = [math]::Round($_.FreeSpace / 1GB, 1); LivrePct = $livrePct }
    })
    Save-Dados 'volumes' $volumes 'Volumes locais e espaço livre'
    foreach ($v in $volumes) {
        if ($v.LivrePct -lt 10) { Add-Alerta 'Alta' 'Armazenamento' "Volume $($v.Unidade) com pouco espaço" "$($v.LivrePct)% livre ($($v.LivreGB) GB)" }
        elseif ($v.LivrePct -lt 15) { Add-Alerta 'Média' 'Armazenamento' "Volume $($v.Unidade) com pouco espaço" "$($v.LivrePct)% livre ($($v.LivreGB) GB)" }
    }
    $script:Resumo['Volumes'] = ($volumes | ForEach-Object { "$($_.Unidade) $($_.TamanhoGB) GB ($($_.LivrePct)% livre)" }) -join ' | '

    if (Test-ComandoExiste 'omreport') {
        Save-TextoExterno 'dell_omsa_storage' @('omreport storage vdisk', 'omreport storage pdisk controller=0') 'Dell OpenManage: discos virtuais e físicos' 60
        Save-TextoExterno 'dell_omsa_chassis' @('omreport chassis', 'omreport system summary') 'Dell OpenManage: chassi e resumo' 60
    }
}

Invoke-Etapa 'Rede da máquina de coleta' {
    # Os cmdlets Net* enxergam os adaptadores virtuais (vEthernet do WSL/Hyper-V), que o WMI antigo deixa passar.
    $ipsv4  = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $rotas  = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $adaptadores = @(Get-NetAdapter | ForEach-Object {
        $a = $_
        $meus = @($ipsv4 | Where-Object { $_.InterfaceIndex -eq $a.ifIndex -and $_.IPAddress -notlike '127.*' })
        # Separa placa real de adaptador virtual (WSL, Docker, Hyper-V, VPN) e de loopback de captura (Npcap).
        $tipo = Get-TipoAdaptador "$($a.InterfaceDescription) $($a.Name)"
        [pscustomobject]@{
            Nome = $a.Name; Tipo = $tipo; Descricao = $a.InterfaceDescription; MAC = $a.MacAddress; Status = $a.Status; Velocidade = $a.LinkSpeed
            Duplex = $a.FullDuplex
            IPv4 = ($meus.IPAddress) -join ', '
            Mascara = (($meus | ForEach-Object { "/$($_.PrefixLength)" }) | Select-Object -Unique) -join ', '
            Gateway = ((@($rotas | Where-Object { $_.InterfaceIndex -eq $a.ifIndex }).NextHop | Where-Object { $_ -and $_ -ne '0.0.0.0' }) | Select-Object -Unique) -join ', '
            DNS = ((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ }) -join ', '
            DHCP = [bool](@($meus | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).Count)
        }
    })
    Save-Dados 'rede_adaptadores' $adaptadores 'Placas de rede da máquina de coleta, com tipo (física/virtual), velocidade, duplex, IP, gateway e DNS'
    # Placa física ativa negociando abaixo de 1 Gbps ou em half duplex: cabo, porta do switch ou placa com problema.
    foreach ($a in $adaptadores | Where-Object { $_.Tipo -eq 'Física' -and $_.Status -eq 'Up' -and $_.IPv4 }) {
        $mbps = if ("$($a.Velocidade)" -match '([\d.]+)\s*Gbps') { [double]$Matches[1] * 1000 } elseif ("$($a.Velocidade)" -match '([\d.]+)\s*Mbps') { [double]$Matches[1] } else { $null }
        if ($mbps -and $mbps -lt 1000) { Add-Alerta 'Média' 'Rede' 'Placa de rede abaixo de 1 Gbps' "$($a.Nome): negociou $($a.Velocidade); conferir cabo e porta do switch" }
        if ($a.Duplex -eq $false) { Add-Alerta 'Média' 'Rede' 'Placa de rede em half duplex' "$($a.Nome): half duplex causa colisões e lentidão; conferir negociação com o switch" }
    }
    $ativos   = @($adaptadores | Where-Object { $_.IPv4 })
    # Produção = tem rota padrão (gateway) ou é placa física. Cobre o vEthernet do vSwitch externo do Hyper-V.
    $producao = @($ativos | Where-Object { $_.Gateway -or $_.Tipo -eq 'Física' })
    $virtuais = @($ativos | Where-Object { -not $_.Gateway -and $_.Tipo -ne 'Física' })
    $fisicos  = $producao

    # Guarda os IPs locais para que a varredura saiba reconhecer a própria máquina.
    $script:IpsLocais = @($ativos | ForEach-Object { $_.IPv4 -split ',\s*' } | Where-Object { $_ })
    $script:IpsLocaisVirtuais = @($virtuais | ForEach-Object { $_.IPv4 -split ',\s*' } | Where-Object { $_ })

    # 169.254.x é APIPA: placa sem IP válido. Não entra no resumo para não poluir, mas continua no CSV.
    $formatar = {
        param($Lista)
        ($Lista | ForEach-Object {
            $ips = @(($_.IPv4 -split ',\s*') | Where-Object { $_ -and $_ -notlike '169.254.*' })
            if ($ips.Count -gt 0) { "$($ips -join ', ') ($($_.Nome))" }
        }) -join ' | '
    }
    $script:Resumo['Endereços de rede (produção)'] = & $formatar $producao
    $textoVirtuais = & $formatar $virtuais
    if ($textoVirtuais) { $script:Resumo['Adaptadores virtuais (WSL/Docker/Hyper-V/VPN)'] = $textoVirtuais }
    $script:Resumo['Gateway'] = ((@($producao.Gateway) + @($ativos.Gateway) | Where-Object { $_ }) | Select-Object -Unique -First 1)
    $script:Resumo['DNS configurado'] = (($producao.DNS | Where-Object { $_ }) | Select-Object -Unique) -join ', '

    # DC com DNS de cliente apontando para fora é erro clássico: quebra localização de serviços, logon e GPO.
    if ($script:PapelMaquina -eq 'Controlador de domínio') {
        $dnsCliente = @(($script:Resumo['DNS configurado'] -split ',\s*') | Where-Object { $_ })
        $apontaParaSi = @($dnsCliente | Where-Object { $_ -eq '127.0.0.1' -or $_ -in $script:IpsLocais }).Count -gt 0
        if ($dnsCliente.Count -gt 0 -and -not $apontaParaSi) {
            Add-Alerta 'Alta' 'Active Directory' 'Controlador de domínio com DNS apontando para servidor externo' "DNS do cliente: $($dnsCliente -join ', '). O DC deve apontar para si mesmo (ou outro DC) e usar encaminhadores para a internet"
        }
    }

    # Quem distribui IP na rede. Serve para marcar esse equipamento na topologia.
    $dhcpSrv = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        Where-Object { $_.DHCPEnabled -and $_.DHCPServer -and $_.DHCPServer -notin '255.255.255.255', '0.0.0.0' } |
        ForEach-Object { $_.DHCPServer })
    $script:ServidorDhcp = @($dhcpSrv | Select-Object -Unique) -join ', '
    if ($script:ServidorDhcp) { $script:Resumo['Servidor DHCP da rede'] = $script:ServidorDhcp }
    if ($script:EhServidor -and ($fisicos | Where-Object { $_.DHCP -eq $true })) {
        Add-Alerta 'Média' 'Rede' 'Servidor com IP por DHCP' 'Servidores devem ter IP fixo'
    }
    if (Test-ComandoExiste 'Get-NetLbfoTeam') {
        $times = @(Get-NetLbfoTeam -ErrorAction SilentlyContinue | Select-Object Name, TeamingMode, LoadBalancingAlgorithm, Status, @{ n = 'Membros'; e = { $_.Members -join ', ' } })
        Save-Dados 'rede_teaming' $times 'Agrupamento de placas de rede (NIC teaming)'
    }
}

function Get-ClasseIp {
    param([string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.') { return '' }
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    if ($a -eq 10 -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)) { return 'Privado' }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return 'CGNAT' }
    'Público'
}

$script:Operadora = ''
$script:IpPublico = ''
Invoke-Etapa 'Internet, operadora e rota de saída' {
    if (-not $SemConsultaInternet -and -not $ConsultasWeb) {
        try {
            $publico = Get-IpPublicoDns
            $script:IpPublico = $publico.IP
            $script:Operadora = $publico.Operadora
            $script:Resumo['IP público / operadora'] = "$($publico.IP) | AS$($publico.Asn) $($publico.Operadora)"
        } catch { Write-Log "Consulta do IP público por DNS falhou: $($_.Exception.Message)" 'AVISO' }
    } elseif (-not $SemConsultaInternet) {
        try {
            # O PS 5.1 lê a resposta como Latin-1 e quebra os acentos (Goiânia -> GoiÃ¢nia); força UTF-8.
            $resposta = Invoke-WebRequest -Uri 'https://ipinfo.io/json' -TimeoutSec 8 -UseBasicParsing
            $bytes = if ($resposta.RawContentStream) { $resposta.RawContentStream.ToArray() } else { [System.Text.Encoding]::UTF8.GetBytes([string]$resposta.Content) }
            $info = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            $script:IpPublico = $info.ip
            $script:Operadora = "$($info.org)" -replace '^AS\d+\s+', ''
            $script:Resumo['IP público / operadora'] = "$($info.ip) | $($info.org) | $($info.city)/$($info.region)"
        } catch { Write-Log "Consulta do IP público falhou: $($_.Exception.Message)" 'AVISO' }
    }
    if (-not (Test-ComandoExiste 'Test-NetConnection')) { return }
    $destinoRota = '8.8.8.8'   # DNS público do Google, só como alvo do traceroute
    $rota = Test-NetConnection -ComputerName $destinoRota -TraceRoute -Hops 8 -WarningAction SilentlyContinue
    $n = 0
    $saltos = @(foreach ($ip in @($rota.TraceRoute)) {
        $n++
        $sem = $ip -eq '0.0.0.0'
        [pscustomobject]@{ Salto = $n; IP = $(if ($sem) { '* (sem resposta)' } else { $ip }); Classe = $(if ($sem) { '' } else { Get-ClasseIp $ip }) }
    })
    Save-Dados 'rota_internet' $saltos 'Saltos até a internet (traceroute para 8.8.8.8)'
    $script:Resumo['Rota de saída'] = ($saltos.IP) -join ' → '
    $privados = @($saltos | Where-Object { $_.Classe -eq 'Privado' })
    if ($privados.Count -ge 2) {
        Add-Alerta 'Baixa' 'Rede' 'Possível NAT duplo' "$($privados.Count) saltos privados antes da internet ($(($privados.IP) -join ' → ')): roteador atrás do modem da operadora; pode afetar VPN e acesso remoto"
    }
    $primeiroExterno = $saltos | Where-Object { $_.Classe -in 'CGNAT', 'Público' } | Select-Object -First 1
    if ($primeiroExterno -and $primeiroExterno.Classe -eq 'CGNAT') {
        Add-Alerta 'Info' 'Rede' 'Possível CGNAT da operadora' "Primeiro salto externo $($primeiroExterno.IP) é endereço CGNAT (100.64.0.0/10): sem IP público próprio, VPN/acesso entrante exige IP fixo"
    }
}

Invoke-Etapa 'Qualidade do link e DNS' {
    # Latência e perda de pacotes até o gateway, o DNS e a internet, para separar problema interno de problema da operadora.
    $alvos = [ordered]@{}
    if ($script:Resumo['Gateway']) { $alvos['Gateway'] = ($script:Resumo['Gateway'] -split ',\s*')[0] }
    $alvos['Internet (1.1.1.1)'] = '1.1.1.1'
    $medicoes = @(foreach ($rotulo in $alvos.Keys) {
        $ip = $alvos[$rotulo]
        $r = @(Test-Connection -ComputerName $ip -Count 10 -ErrorAction SilentlyContinue)
        $ok = $r.Count
        $lat = if ($ok) { [math]::Round((($r | Measure-Object -Property ResponseTime -Average).Average), 0) } else { $null }
        $perda = [math]::Round((10 - $ok) / 10 * 100, 0)
        [pscustomobject]@{ Alvo = $rotulo; IP = $ip; LatenciaMediaMs = $lat; PerdaPct = $perda; Respostas = "$ok/10" }
    })
    Save-Dados 'rede_qualidade_link' $medicoes 'Latência e perda de pacotes até o gateway e a internet (10 pings cada)'
    $script:Resumo['Qualidade do link'] = ($medicoes | ForEach-Object { "$($_.Alvo): $(if ($null -ne $_.LatenciaMediaMs) { "$($_.LatenciaMediaMs) ms" } else { 'sem resposta' }), $($_.PerdaPct)% perda" }) -join ' | '
    foreach ($m in $medicoes) {
        if ($m.PerdaPct -ge 20) { Add-Alerta 'Alta' 'Rede' "Perda de pacotes alta até $($m.Alvo)" "$($m.PerdaPct)% de perda ($($m.Respostas)): link instável" }
        elseif ($m.PerdaPct -ge 5) { Add-Alerta 'Média' 'Rede' "Perda de pacotes até $($m.Alvo)" "$($m.PerdaPct)% de perda ($($m.Respostas))" }
        if ($m.Alvo -like 'Internet*' -and $null -ne $m.LatenciaMediaMs -and $m.LatenciaMediaMs -gt 120) { Add-Alerta 'Média' 'Rede' 'Latência alta até a internet' "$($m.LatenciaMediaMs) ms médios" }
    }

    # DNS em uso: quais servidores a rede usa e o tempo de resposta de cada um.
    $dnsSrv = @(($script:Resumo['DNS configurado'] -split ',\s*') | Where-Object { $_ -and $_ -notlike '127.*' } | Select-Object -Unique)
    if ($dnsSrv.Count -and (Test-ComandoExiste 'Resolve-DnsName')) {
        $testeDns = @(foreach ($srv in $dnsSrv) {
            $t = [System.Diagnostics.Stopwatch]::StartNew()
            $resolveu = try { [bool](Resolve-DnsName -Name 'www.google.com' -Server $srv -Type A -QuickTimeout -ErrorAction Stop) } catch { $false }
            $t.Stop()
            $classe = if ($srv -in '8.8.8.8','8.8.4.4','1.1.1.1','1.0.0.1','9.9.9.9') { 'Público' } elseif ($srv -in $script:IpsLocais) { 'Esta máquina' } elseif ($srv -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { 'Interno/local' } else { 'Externo' }
            [pscustomobject]@{ Servidor = $srv; Classe = $classe; Resolveu = $resolveu; TempoMs = if ($resolveu) { [math]::Round($t.Elapsed.TotalMilliseconds, 0) } else { $null } }
        })
        Save-Dados 'rede_dns_em_uso' $testeDns 'Servidores DNS configurados, classe e tempo de resposta'
        $script:Resumo['DNS em uso'] = ($testeDns | ForEach-Object { "$($_.Servidor) ($($_.Classe))$(if ($_.Resolveu) { ": $($_.TempoMs) ms" } else { ': sem resposta' })" }) -join ' | '
        foreach ($d in $testeDns | Where-Object { -not $_.Resolveu }) { Add-Alerta 'Média' 'Rede' 'Servidor DNS não respondeu' "$($d.Servidor) ($($d.Classe)): configurado mas sem resposta" }
    }
}

Invoke-Etapa 'Papéis e recursos do Windows' {
    if (Test-ComandoExiste 'Get-WindowsFeature') {
        $recursos = @(Get-WindowsFeature | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' } | Select-Object Name, DisplayName)
        Save-Dados 'papeis_instalados' $recursos 'Papéis de servidor instalados'
        $script:Resumo['Papéis instalados'] = ($recursos.DisplayName) -join ', '
        # DC que também é host de virtualização, RDS e servidor de arquivos concentra risco num ponto só.
        $pesados = @('Hyper-V', 'Remote-Desktop-Services', 'FileAndStorage-Services', 'Web-Server', 'Print-Services') | Where-Object { $_ -in @($recursos.Name) }
        if ('AD-Domain-Services' -in @($recursos.Name) -and $pesados.Count -ge 2) {
            Add-Alerta 'Média' 'Servidor' 'Controlador de domínio acumulando papéis' "Além do AD: $(($recursos.DisplayName | Where-Object { $_ -notmatch 'Domínio Active|Domain Services' }) -join ', '). Um problema em qualquer papel derruba a autenticação de todos (REQ-037)"
        }
        $smb1 = Get-WindowsFeature -Name FS-SMB1 -ErrorAction SilentlyContinue
        if ($smb1 -and $smb1.Installed) { Add-Alerta 'Alta' 'Segurança' 'SMB1 instalado' 'Protocolo inseguro (vetor de ransomware); remover o recurso FS-SMB1' }
    }
}

Invoke-Etapa 'Serviços' {
    $script:ServicosLocal = @(Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, StartName)
    Save-Dados 'servicos' $script:ServicosLocal 'Todos os serviços, estado e conta de execução'
    $ignorar = 'gupdate|edgeupdate|MapsBroker|sppsvc|RemoteRegistry|tiledatamodelsvc|WbioSrvc|CDPSvc|clr_optimization|TrustedInstaller|wuauserv|BITS|ShellHWDetection|GoogleUpdater|OneSyncSvc|DoSvc|UsoSvc|WaaSMedicSvc'
    $parados = @($script:ServicosLocal | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.Name -notmatch $ignorar })
    Save-Dados 'servicos_automaticos_parados' $parados 'Serviços automáticos que não estão em execução'
    if ($parados.Count -gt 0) { Add-Alerta 'Baixa' 'Servidor' "$($parados.Count) serviço(s) automático(s) parado(s)" (($parados.DisplayName | Select-Object -First 8) -join ', ') }
    $contasDominio = @($script:ServicosLocal | Where-Object { $_.StartName -and $_.StartName -notmatch '^(LocalSystem|NT AUTHORITY|NT Service|AUTORIDADE NT)' })
    Save-Dados 'servicos_conta_usuario' $contasDominio 'Serviços executados com conta de usuário (verificar senha e privilégios)'
}

Invoke-Etapa 'Softwares instalados' {
    $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $script:SoftwareLocal = @(Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Select-Object @{ n = 'Nome'; e = { $_.DisplayName.Trim() } }, @{ n = 'Versao'; e = { $_.DisplayVersion } },
                      @{ n = 'Fabricante'; e = { $_.Publisher } }, @{ n = 'InstaladoEm'; e = { $_.InstallDate } } |
        Sort-Object Nome, Versao -Unique)
    Save-Dados 'softwares_instalados' $script:SoftwareLocal 'Softwares instalados no servidor'

    $acessoRemoto = @($script:SoftwareLocal | Where-Object { $_.Nome -match '(?i)AnyDesk|TeamViewer|RustDesk|Splashtop|ScreenConnect|ConnectWise|Supremo|LogMeIn|VNC|Radmin|Ammyy|NinjaOne|Action1|Atera|Zoho Assist|Chrome Remote|GoTo' })
    if ($acessoRemoto.Count -gt 0) {
        $severidade = if ($acessoRemoto.Count -gt 1) { 'Média' } else { 'Info' }
        Add-Alerta $severidade 'Segurança' 'Ferramentas de acesso remoto instaladas' (($acessoRemoto.Nome | Select-Object -Unique) -join ', ')
    }
    $script:Resumo['Acesso remoto instalado'] = ($acessoRemoto.Nome | Select-Object -Unique) -join ', '
}

Invoke-Etapa 'Atualizações do Windows' {
    # Get-HotFix não aceita prazo: roda à parte e já volta com a data convertida.
    # Se estourar, o resto da etapa (reinício pendente e política do Windows Update) continua.
    $hotfixes = @(try {
            Invoke-ComLimiteTempo {
                Get-HotFix | Select-Object HotFixID, Description, InstalledBy, @{ n = 'InstaladoEm'; e = { $_.InstalledOn } }
            } 'Lista de atualizações (Get-HotFix)' $script:TimeoutWmiSeg
        } catch { })
    $hotfixes = @($hotfixes | Sort-Object InstaladoEm -Descending)
    Save-Dados 'atualizacoes_instaladas' $hotfixes 'Atualizações instaladas (Get-HotFix)'
    $ultima = ($hotfixes | Where-Object { $_.InstaladoEm } | Select-Object -First 1).InstaladoEm
    $script:Resumo['Última atualização instalada'] = Format-Data $ultima
    if ($ultima -and ((Get-Date) - $ultima).TotalDays -gt 45) { Add-Alerta 'Média' 'Servidor' 'Atualizações atrasadas' "Última atualização em $(Format-Data $ultima)" }

    $pendente = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $script:Resumo['Reinicialização pendente'] = if ($pendente) { 'Sim' } else { 'Não' }
    if ($pendente) { Add-Alerta 'Média' 'Servidor' 'Reinicialização pendente' 'Há atualizações aguardando reinício' }

    $wsus = Get-ValorRegistro 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer'
    $auOpcao = Get-ValorRegistro 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'
    $auHora = Get-ValorRegistro 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'ScheduledInstallTime'
    $script:Resumo['Política do Windows Update'] = 'WSUS: {0} | AUOptions: {1} | Hora agendada: {2}' -f ($(if ($wsus) { $wsus } else { 'não' })), ($(if ($auOpcao) { $auOpcao } else { 'padrão' })), ($(if ($null -ne $auHora) { "${auHora}h" } else { 'padrão' }))
}

Invoke-Etapa 'Tarefas agendadas' {
    $tarefas = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
        $info = try { $_ | Get-ScheduledTaskInfo -ErrorAction Stop } catch { $null }
        [pscustomobject]@{
            Tarefa = $_.TaskName; Caminho = $_.TaskPath; Estado = $_.State; Conta = $_.Principal.UserId; Autor = $_.Author
            Acao = Protect-Texto ((@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' | ')
            UltimaExecucao = if ($info) { Format-Data $info.LastRunTime } else { '' }
            UltimoResultado = if ($info) { '0x{0:X}' -f $info.LastTaskResult } else { '' }
            ProximaExecucao = if ($info) { Format-Data $info.NextRunTime } else { '' }
        }
    })
    Save-Dados 'tarefas_agendadas' $tarefas 'Tarefas agendadas fora da pasta Microsoft (senhas mascaradas)'
    foreach ($t in $tarefas | Where-Object { $_.UltimoResultado -notin '0x0', '0x41301', '0x41303', '0x41325', '' -and $_.Estado -ne 'Disabled' }) {
        Add-Alerta 'Baixa' 'Servidor' "Tarefa com erro: $($t.Tarefa)" "Último resultado $($t.UltimoResultado) em $($t.UltimaExecucao)"
    }
}

Invoke-Etapa 'Administradores locais' {
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
        Write-Log 'Servidor é controlador de domínio: administradores listados na etapa do AD.'
        return
    }
    $membros = @(Get-MembrosAdministradores)
    Save-Dados 'administradores_locais' $membros 'Membros do grupo Administradores local'
    $locais = @(Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet, PasswordExpires, Description)
    Save-Dados 'usuarios_locais' $locais 'Contas locais do servidor'
}

Invoke-Etapa 'Compartilhamentos e permissões' {
    $shares = @(Get-SmbShare | Where-Object { $_.Name -notmatch '^(ADMIN\$|IPC\$|[A-Z]\$|print\$)$' })
    Save-Dados 'compartilhamentos' ($shares | Select-Object Name, Path, Description, FolderEnumerationMode, CachingMode, EncryptData) 'Pastas compartilhadas'
    $acessoShare = foreach ($s in $shares) {
        Get-SmbShareAccess -Name $s.Name | Select-Object @{ n = 'Compartilhamento'; e = { $s.Name } }, AccountName, AccessControlType, AccessRight
    }
    Save-Dados 'compartilhamentos_permissoes' $acessoShare 'Permissões de compartilhamento'
    $ntfs = foreach ($s in $shares | Where-Object { $_.Path -and (Test-Path $_.Path) }) {
        (Get-Acl -Path $s.Path).Access | Select-Object @{ n = 'Compartilhamento'; e = { $s.Name } }, @{ n = 'Caminho'; e = { $s.Path } },
            IdentityReference, FileSystemRights, AccessControlType, IsInherited, InheritanceFlags
    }
    Save-Dados 'compartilhamentos_ntfs_raiz' $ntfs 'Permissões NTFS na raiz de cada compartilhamento'
    foreach ($a in @($acessoShare) | Where-Object { $_.AccountName -match '^(Everyone|Todos)$' -and $_.AccessRight -eq 'Full' }) {
        Add-Alerta 'Média' 'Arquivos' "Compartilhamento $($a.Compartilhamento) com Controle Total para Todos" 'Restringir por grupo do AD'
    }
    $script:Resumo['Compartilhamentos'] = ($shares.Name) -join ', '
    if (Test-ComandoExiste 'Get-SmbServerConfiguration') {
        $smb = Get-SmbServerConfiguration
        $script:Resumo['SMB1 habilitado'] = $smb.EnableSMB1Protocol
        $script:Resumo['Assinatura SMB obrigatória'] = $smb.RequireSecuritySignature
        if ($smb.EnableSMB1Protocol) { Add-Alerta 'Alta' 'Segurança' 'SMB1 habilitado no servidor' 'Desabilitar o protocolo SMB1' }
    }
}

Invoke-Etapa 'Portas em escuta' {
    $processos = @{}
    Get-Process | ForEach-Object { $processos[$_.Id] = $_.ProcessName }
    $tcp = @(Get-NetTCPConnection -State Listen | Sort-Object LocalPort -Unique | Select-Object LocalAddress, LocalPort,
        @{ n = 'Processo'; e = { $processos[[int]$_.OwningProcess] } }, OwningProcess)
    Save-Dados 'portas_tcp_escuta' $tcp 'Portas TCP em escuta no servidor e processo responsável'
    # Acima de 49152 é porta efêmera (num DNS são milhares): só ruído. Fica o que é serviço de verdade.
    $udp = @(Get-NetUDPEndpoint | Where-Object { $_.LocalPort -lt 49152 } | Sort-Object LocalPort -Unique | Select-Object LocalAddress, LocalPort,
        @{ n = 'Processo'; e = { $processos[[int]$_.OwningProcess] } }, OwningProcess)
    Save-Dados 'portas_udp' $udp 'Portas UDP de serviço abertas no servidor (abaixo de 49152)'
    $script:Resumo['Portas TCP em escuta'] = (($tcp | Where-Object { $_.LocalPort -lt 49152 }).LocalPort | Select-Object -Unique) -join ', '
}

Invoke-Etapa 'Firewall do Windows' {
    $perfis = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogAllowed, LogBlocked, LogFileName)
    Save-Dados 'firewall_perfis' $perfis 'Perfis do firewall do Windows'
    foreach ($p in $perfis | Where-Object { -not $_.Enabled }) { Add-Alerta 'Média' 'Segurança' "Firewall do Windows desligado (perfil $($p.Name))" 'Religar o perfil e liberar só o necessário' }
    $script:Resumo['Firewall do Windows'] = ($perfis | ForEach-Object { "$($_.Name): $(if ($_.Enabled) { 'ligado' } else { 'DESLIGADO' })" }) -join ' | '
    $personalizadas = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Where-Object { -not $_.DisplayGroup } | ForEach-Object {
        $filtro = $_ | Get-NetFirewallPortFilter
        $enderecos = $_ | Get-NetFirewallAddressFilter
        [pscustomobject]@{ Regra = $_.DisplayName; Perfil = $_.Profile; Protocolo = $filtro.Protocol; Porta = ($filtro.LocalPort -join ','); Origem = ($enderecos.RemoteAddress -join ',') }
    })
    Save-Dados 'firewall_regras_personalizadas' $personalizadas 'Regras de entrada permitidas criadas manualmente ou por aplicativos'
}

Invoke-Etapa 'Antivírus e proteção' {
    $avServicos = @($script:ServicosLocal | Where-Object { $_.State -eq 'Running' -and $_.DisplayName -match '(?i)Acronis (Active Protection|Cyber Protection)|Kaspersky|\bESET\b|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|\bAVG\b|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|Defender for Endpoint|\bSense\b' })
    $script:Resumo['Antivírus/EDR (serviços ativos)'] = (($avServicos.DisplayName) | Select-Object -Unique) -join ', '
    $defenderAtivo = $false
    if (Test-ComandoExiste 'Get-MpComputerStatus') {
        try {
            # Com outro antivírus no lugar, o Defender às vezes não responde e o cmdlet fica parado.
            $mp = Invoke-ComLimiteTempo { Get-MpComputerStatus } 'Status do Microsoft Defender' 30 | Select-Object -First 1
            if (-not $mp) { throw 'Defender sem status' }
            $defenderAtivo = [bool]$mp.RealTimeProtectionEnabled
            $script:Resumo['Microsoft Defender'] = 'Antivírus: {0} | Tempo real: {1} | Assinaturas: {2}' -f $mp.AntivirusEnabled, $mp.RealTimeProtectionEnabled, (Format-Data $mp.AntivirusSignatureLastUpdated)
            if ($defenderAtivo -and ((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays -gt 7) { Add-Alerta 'Média' 'Segurança' 'Assinaturas do Defender desatualizadas' "Última atualização em $(Format-Data $mp.AntivirusSignatureLastUpdated)" }
        } catch { $script:Resumo['Microsoft Defender'] = 'Não disponível ou desativado' }
    }
    if ($avServicos.Count -eq 0 -and -not $defenderAtivo) { Add-Alerta 'Alta' 'Segurança' 'Servidor sem antivírus ativo identificado' 'Defender sem tempo real e nenhum outro antivírus em execução; confirmar manualmente' }
}

Invoke-Etapa 'Configurações de segurança' {
    $rdpNegado = Get-ValorRegistro 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    $nla = Get-ValorRegistro 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
    $portaRdp = Get-ValorRegistro 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'PortNumber'
    $script:Resumo['RDP'] = 'Habilitado: {0} | NLA: {1} | Porta: {2}' -f ($rdpNegado -eq 0), ($nla -eq 1), $portaRdp
    if ($rdpNegado -eq 0 -and $nla -ne 1) { Add-Alerta 'Média' 'Segurança' 'RDP sem autenticação em nível de rede (NLA)' 'Habilitar NLA' }
    if ($rdpNegado -eq 0 -and $portaRdp -and [int]$portaRdp -ne 3389) {
        Add-Alerta 'Média' 'Segurança' "RDP em porta não padrão ($portaRdp)" 'Porta trocada quase sempre indica RDP publicado na internet pelo roteador. Confirmar; se exposto, o acesso deve ser por VPN com MFA (CRIT-024-02)'
    }

    $wdigest = Get-ValorRegistro 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential'
    if ($wdigest -eq 1) { Add-Alerta 'Alta' 'Segurança' 'WDigest guardando senhas em texto na memória' 'UseLogonCredential = 1' }
    $lsaPpl = Get-ValorRegistro 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
    $uac = Get-ValorRegistro 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    $llmnr = Get-ValorRegistro 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
    $secureBoot = try { Confirm-SecureBootUEFI } catch { 'Não suportado/BIOS legado' }
    $tpm = try { Format-SituacaoTpm (Invoke-ComLimiteTempo { Get-Tpm } 'TPM' 20 | Select-Object -First 1) } catch { 'Não identificado' }
    $script:Resumo['Secure Boot'] = $secureBoot
    $script:Resumo['TPM'] = $tpm
    $script:Resumo['Proteção LSA (RunAsPPL)'] = if ($lsaPpl -ge 1) { 'Sim' } else { 'Não' }
    $script:Resumo['UAC'] = if ($uac -eq 0) { 'Desligado' } else { 'Ligado' }
    $script:Resumo['LLMNR desabilitado por política'] = if ($llmnr -eq 0) { 'Sim' } else { 'Não' }
    if ($uac -eq 0) { Add-Alerta 'Média' 'Segurança' 'UAC desligado' 'EnableLUA = 0' }

    if (Test-ComandoExiste 'Get-BitLockerVolume') {
        $bl = @(try {
            Invoke-ComLimiteTempo {
                Get-BitLockerVolume | ForEach-Object { [pscustomobject]@{ MountPoint = "$($_.MountPoint)"; VolumeStatus = "$($_.VolumeStatus)"
                    ProtectionStatus = "$($_.ProtectionStatus)"; EncryptionMethod = "$($_.EncryptionMethod)"; EncryptionPercentage = $_.EncryptionPercentage } }
            } 'BitLocker' $script:TimeoutWmiSeg
        } catch { })
        Save-Dados 'bitlocker' $bl 'Criptografia BitLocker por volume'
        $script:Resumo['BitLocker'] = ($bl | ForEach-Object { "$($_.MountPoint) $($_.ProtectionStatus)" }) -join ' | '
    }
    Save-TextoExterno 'politica_auditoria' @('auditpol /get /category:*') 'Política de auditoria do Windows' 20
    if ($ComandosExternos) { Save-TextoExterno 'politica_senha_local' @('net accounts') 'Política de senha efetiva (local/domínio)' 30 }
}

Invoke-Etapa 'SQL Server e bancos de dados' {
    $instancias = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    $lista = @()
    if ($instancias) {
        $lista = @($instancias.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
            $setup = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($_.Value)\Setup"
            $versao = Get-ValorRegistro $setup 'Version'
            [pscustomobject]@{ Instancia = $_.Name; Id = $_.Value; Edicao = Get-ValorRegistro $setup 'Edition'; Versao = $versao; Suporte = Get-SuporteSql $versao }
        })
    }
    Save-Dados 'sql_instancias' $lista 'Instâncias do SQL Server, com versão e situação de suporte'
    $script:Resumo['SQL Server'] = ($lista | ForEach-Object { "$($_.Instancia) ($($_.Edicao) $($_.Versao)) | $($_.Suporte)" }) -join ' | '
    foreach ($i in $lista | Where-Object { $_.Suporte -like '*fora de suporte*' }) { Add-Alerta 'Alta' 'Banco de dados' "SQL Server sem suporte: $($i.Instancia)" "$($i.Suporte) (REQ-014)" }
    foreach ($i in $lista | Where-Object { $_.Suporte -like '*encerra em*' }) { Add-Alerta 'Média' 'Banco de dados' "SQL Server perto do fim do suporte: $($i.Instancia)" $i.Suporte }

    $outrosBancos = @($script:ServicosLocal | Where-Object { $_.Name -match '(?i)firebird|mysql|mariadb|postgres|oracle|mongo' } | Select-Object Name, DisplayName, State, StartMode)
    Save-Dados 'bancos_outros' $outrosBancos 'Outros gerenciadores de banco (Firebird, MySQL, PostgreSQL etc.)'
    if ($outrosBancos) { $script:Resumo['Outros bancos'] = ($outrosBancos.DisplayName) -join ', ' }

    if ($lista.Count -eq 0) { return }
    # Consulta direta pelo SqlClient do .NET (sempre presente no PowerShell 5.1). O sqlcmd dependia de
    # estar instalado e, quando falhava, não dizia por quê.
    $consulta = "SET NOCOUNT ON; SELECT d.name, d.state_desc, d.recovery_model_desc, " +
        "CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END) * 8 / 1024.0 AS DECIMAL(12,1)), " +
        "CAST(SUM(mf.size) * 8 / 1024.0 AS DECIMAL(12,1)), " +
        "CONVERT(VARCHAR(16), (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'D'), 120) " +
        "FROM sys.databases d JOIN sys.master_files mf ON mf.database_id = d.database_id " +
        "GROUP BY d.name, d.state_desc, d.recovery_model_desc ORDER BY 5 DESC;"
    $bancos = foreach ($inst in $lista) {
        $servidorSql = if ($inst.Instancia -eq 'MSSQLSERVER') { '.' } else { ".\$($inst.Instancia)" }
        $conexao = New-Object System.Data.SqlClient.SqlConnection("Server=$servidorSql;Integrated Security=SSPI;Connect Timeout=8;Encrypt=False")
        try {
            $conexao.Open()
            $comando = $conexao.CreateCommand()
            $comando.CommandText = $consulta
            $comando.CommandTimeout = 20
            $leitor = $comando.ExecuteReader()
            while ($leitor.Read()) {
                [pscustomobject]@{
                    Instancia = $inst.Instancia; Edicao = $inst.Edicao
                    Banco = "$($leitor.GetValue(0))"; Estado = "$($leitor.GetValue(1))"; Recuperacao = "$($leitor.GetValue(2))"
                    DadosMB = [double]$leitor.GetValue(3); TotalMB = [double]$leitor.GetValue(4)
                    UltimoBackupFullSql = if ($leitor.IsDBNull(5)) { '' } else { "$($leitor.GetValue(5))" }
                }
            }
            $leitor.Close()
        } catch {
            Write-Log "Sem acesso ao SQL $($inst.Instancia) com a conta atual: $($_.Exception.Message)" 'AVISO'
            Add-Alerta 'Info' 'Banco de dados' "Bancos do SQL $($inst.Instancia) não listados" 'A conta que rodou a coleta não tem permissão na instância; rodar com um login sysadmin ou colher no SSMS'
        } finally { $conexao.Dispose() }
    }
    foreach ($b in @($bancos) | Where-Object { $_.Banco -notin 'master', 'model', 'msdb', 'tempdb' -and -not $_.UltimoBackupFullSql }) {
        Add-Alerta 'Média' 'Backup' "Banco $($b.Banco) sem backup nativo do SQL registrado" 'Nenhum backup FULL no msdb; confirmar se a ferramenta de backup usa VSS/agente de SQL'
    }
    Save-Dados 'sql_bancos' $bancos 'Bancos SQL: tamanho de dados, total e último backup nativo'
    foreach ($b in @($bancos) | Where-Object { $_.Edicao -match 'Express' -and $_.Banco -notin 'master', 'model', 'msdb', 'tempdb' }) {
        if ($b.DadosMB -gt 9500) { Add-Alerta 'Alta' 'Banco de dados' "Banco $($b.Banco) perto do limite do SQL Express" "$($b.DadosMB) MB de dados (limite 10 GB por banco)" }
        elseif ($b.DadosMB -gt 8000) { Add-Alerta 'Média' 'Banco de dados' "Banco $($b.Banco) acima de 8 GB no SQL Express" "$($b.DadosMB) MB de dados (limite 10 GB por banco)" }
    }
}

Invoke-Etapa 'Backup' {
    $padrao = '(?i)Acronis|Veeam|Ahsay|Cobian|Arcserve|Nakivo|Iperius|Duplicati|Macrium|Backup Exec|Altaro|Datto|Bacula|UrBackup|Areca|SyncBack|Backup'
    $softwares = @($script:SoftwareLocal | Where-Object { $_.Nome -match $padrao })
    $servicos = @($script:ServicosLocal | Where-Object { $_.DisplayName -match $padrao -and (Test-ServicoBackupReal $_) })
    Save-Dados 'backup_softwares' ($softwares) 'Softwares de backup instalados'
    Save-Dados 'backup_servicos' ($servicos) 'Serviços de backup'
    $script:Resumo['Backup identificado'] = (@($softwares.Nome) + @($servicos.DisplayName) | Select-Object -Unique) -join ', '
    $wsbComSucesso = $false
    if (Test-ComandoExiste 'Get-WBSummary') {
        try {
            $wb = Invoke-ComLimiteTempo { Get-WBSummary } 'Windows Server Backup' 45 | Select-Object -First 1
            if (-not $wb) { throw 'Windows Server Backup sem resposta' }
            $semSucesso = (-not $wb.LastSuccessfulBackupTime -or $wb.LastSuccessfulBackupTime -eq [datetime]::MinValue)
            $wsbComSucesso = -not $semSucesso
            $script:Resumo['Windows Server Backup'] = if ($semSucesso) { 'Nenhum backup concluído (rotina de backup nativa não configurada)' } else { 'Último sucesso: {0} | Último resultado: {1}' -f (Format-Data $wb.LastSuccessfulBackupTime), $wb.LastBackupResultHR }
            if ($semSucesso) {
                Add-Alerta 'Info' 'Backup' 'Windows Server Backup instalado sem backup concluído' 'Recurso presente, nenhum sucesso registrado; confirmar se a rotina real é outra ferramenta'
            } elseif (((Get-Date) - $wb.LastSuccessfulBackupTime).TotalDays -gt 2) {
                Add-Alerta 'Média' 'Backup' 'Windows Server Backup atrasado' "Último sucesso em $(Format-Data $wb.LastSuccessfulBackupTime)"
            }
        } catch { }
    }
    if ($softwares.Count -eq 0 -and $servicos.Count -eq 0 -and -not $wsbComSucesso) { Add-Alerta 'Alta' 'Backup' 'Nenhuma ferramenta de backup identificada no servidor' 'Confirmar rotina de backup local e em nuvem' }
    # Por CIM, sem processo externo; a consulta trava quando o serviço VSS está travado, por isso o limite de tempo.
    try {
        $sombras = @(Invoke-ComLimiteTempo {
            Get-CimInstance Win32_ShadowStorage -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Volume    = $_.Volume.DeviceID
                    UsadoGB   = [math]::Round($_.UsedSpace / 1GB, 2)
                    AlocadoGB = [math]::Round($_.AllocatedSpace / 1GB, 2)
                    MaximoGB  = [math]::Round($_.MaxSpace / 1GB, 2)
                }
            }
        } 'Armazenamento VSS' 30)
        Save-Dados 'vss_armazenamento' $sombras 'Armazenamento de cópias de sombra (VSS)'
    } catch { Write-Log "Armazenamento VSS não lido: $($_.Exception.Message)" 'AVISO' }
    if ($ComandosExternos) {
        Save-TextoExterno 'vss_writers' @('vssadmin list writers') 'Estado dos gravadores VSS' 60
    }
}

Invoke-Etapa 'Certificados digitais (máquina, usuário e A3)' {
    # O assessment cobra inventário de certificados com tipo, finalidade, validade e onde está (CT.4 e REQ-027).
    # Ruído: certificado que o próprio aplicativo cria para uso interno. Não é patrimônio do cliente
    # e polui o relatório. O que interessa é e-CNPJ, e-CPF e certificado emitido por AC pública.
    $ruidoApp = '(?i)Adobe|localhost|127\.0\.0\.1|DO_NOT_TRUST|MS-Organization|Windows Azure|TeamViewer|AnyDesk|' +
                'Citrix|VMware|Zoom|Docker|WinRM|Remote Desktop|WMSvc|Plex|Acronis|Sophos|Kaspersky|ESET|' +
                'Intel\(R\)|NVIDIA|Realtek|Logitech|Token Signing|Hardware Compatibility|Root Agency|SolarWinds'

    $certs = @(
        foreach ($loja in 'LocalMachine', 'CurrentUser') {
            Get-ChildItem "Cert:\$loja\My" -ErrorAction SilentlyContinue | ForEach-Object {
                $icp = [bool]($_.Issuer -match '(?i)ICP-Brasil|Certisign|Serasa|Valid Certificadora|Soluti|Safeweb|Syngular|AC \w')
                $temDocumento = [bool]($_.Subject -match ':\d{11}\b|:\d{14}\b')
                $autoAssinado = $_.Subject -eq $_.Issuer
                $ehRuido = [bool]("$($_.Subject) $($_.Issuer)" -match $ruidoApp)
                [pscustomobject]@{
                    Repositorio = $loja
                    Titular = $_.Subject
                    Emissor = $_.Issuer
                    IcpBrasil = $icp
                    Relevante = [bool]($icp -or $temDocumento -or (-not $autoAssinado -and -not $ehRuido -and $_.HasPrivateKey))
                    ValidoDe = Format-Data $_.NotBefore
                    ValidoAte = Format-Data $_.NotAfter
                    DiasRestantes = [int]($_.NotAfter - (Get-Date)).TotalDays
                    TemChavePrivada = $_.HasPrivateKey
                    Impressao = $_.Thumbprint
                }
            }
        })
    Save-Dados 'certificados_digitais' $certs 'Todos os certificados dos repositórios, com marcação do que é relevante (o CSV guarda tudo)'
    # O relatório mostra só os relevantes; os do aplicativo continuam no CSV para quem quiser conferir.
    $script:Certificados = @($certs | Where-Object { $_.Relevante })
    $descartados = @($certs).Count - @($script:Certificados).Count
    if ($descartados -gt 0) { Write-Log "  $descartados certificado(s) de aplicativo ocultados do relatório (continuam no CSV)." }

    # Leitora de token ou cartão indica certificado A3 em uso.
    $leitoras = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPClass -eq 'SmartCardReader' -or $_.Name -match '(?i)token|smart ?card|safenet|watchdata|gemalto|etoken' } |
        Select-Object Name, Manufacturer, Status, PNPClass)
    Save-Dados 'leitoras_certificado_a3' $leitoras 'Leitoras de cartão e tokens (indício de certificado A3)'

    $icp = @($certs | Where-Object { $_.IcpBrasil })
    $script:Resumo['Certificados ICP-Brasil (A1 instalados)'] = if ($icp.Count -gt 0) { ($icp | ForEach-Object { "$($_.Titular) vence $($_.ValidoAte)" }) -join ' | ' } else { 'Nenhum encontrado nos repositórios' }
    $script:Resumo['Leitora de token (A3)'] = if ($leitoras.Count -gt 0) { ($leitoras.Name | Select-Object -Unique) -join ', ' } else { 'Nenhuma detectada' }

    foreach ($c in $certs | Where-Object { $_.Relevante -and $_.DiasRestantes -ge 0 -and $_.DiasRestantes -le 30 }) {
        $sev = if ($c.IcpBrasil) { 'Alta' } else { 'Média' }
        Add-Alerta $sev 'Certificados' 'Certificado vencendo' "$($c.Titular) vence em $($c.DiasRestantes) dias ($($c.ValidoAte))"
    }
    foreach ($c in $certs | Where-Object { $_.IcpBrasil -and $_.DiasRestantes -lt 0 }) {
        Add-Alerta 'Média' 'Certificados' 'Certificado ICP-Brasil vencido' "$($c.Titular) venceu em $($c.ValidoAte)"
    }
}

Invoke-Etapa 'Retenção dos logs de evento' {
    # REQ-038 exige retenção mínima de 5 anos das trilhas.
    $logs = @(foreach ($n in 'Application', 'System', 'Security') {
        try {
            $l = Get-WinEvent -ListLog $n -ErrorAction Stop
            $maisAntigo = try { (Get-WinEvent -LogName $n -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { $null }
            [pscustomobject]@{
                Log = $n
                TamanhoMaximoMB = [math]::Round($l.MaximumSizeInBytes / 1MB, 0)
                Modo = $l.LogMode
                Registros = $l.RecordCount
                RegistroMaisAntigo = Format-Data $maisAntigo
                CoberturaDias = if ($maisAntigo) { [int]((Get-Date) - $maisAntigo).TotalDays } else { $null }
            }
        } catch { }
    })
    Save-Dados 'logs_retencao' $logs 'Tamanho, modo e cobertura real dos logs de evento (REQ-038 pede 5 anos)'
    $script:Resumo['Cobertura dos logs de evento'] = ($logs | ForEach-Object { "$($_.Log): $($_.CoberturaDias) dias ($($_.TamanhoMaximoMB) MB)" }) -join ' | '
    foreach ($l in $logs | Where-Object { $null -ne $_.CoberturaDias -and $_.CoberturaDias -lt 365 }) {
        Add-Alerta 'Média' 'Auditoria' "Log $($l.Log) cobre só $($l.CoberturaDias) dias" 'O Provimento 213 exige trilhas por 5 anos; aumentar o tamanho do log ou exportar para retenção'
    }
}

Invoke-Etapa 'Ferramentas de monitoramento e RMM' {
    $padrao = '(?i)NinjaOne|NinjaRMM|Action1|Atera|Datto|ConnectWise Automate|Kaseya|N-able|Pulseway|Syncro|ManageEngine|PRTG|Zabbix|Nagios|Centreon|LibreNMS|Site24x7|Auvik'
    $soft = @($script:SoftwareLocal | Where-Object { $_.Nome -match $padrao } | Select-Object Nome, Versao, Fabricante)
    $serv = @($script:ServicosLocal | Where-Object { $_.DisplayName -match $padrao -or $_.Name -match $padrao } | Select-Object Name, DisplayName, State, StartMode)
    Save-Dados 'monitoramento_rmm' (@($soft) + @($serv | ForEach-Object { [pscustomobject]@{ Nome = $_.DisplayName; Versao = ''; Fabricante = "serviço: $($_.State)" } })) 'Ferramentas de monitoramento e gestão remota instaladas'
    $nomes = @((@($soft.Nome) + @($serv.DisplayName)) | Where-Object { $_ } | Select-Object -Unique)
    $script:Resumo['Monitoramento / RMM'] = if ($nomes.Count -gt 0) { $nomes -join ', ' } else { 'Nenhum identificado' }
    if ($nomes.Count -eq 0) { Add-Alerta 'Baixa' 'Gestão' 'Sem ferramenta de monitoramento identificada' 'GS.12 e GS.25 do checklist: sem monitoramento ativo, falha passa despercebida' }
}

Invoke-Etapa 'Periféricos (scanners, biometria e digitalização)' {
    $perif = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPClass -in 'Image', 'Biometric' -or $_.Name -match '(?i)scanner|digitaliza|biometr|fingerprint|leitor' } |
        Select-Object Name, Manufacturer, PNPClass, Status | Sort-Object Name -Unique)
    Save-Dados 'perifericos' $perif 'Scanners, digitalizadores e leitores biométricos (HD.8 e HD.9 do checklist)'
    $script:Resumo['Scanners e biometria'] = if ($perif.Count -gt 0) { ($perif.Name | Select-Object -First 6) -join ', ' } else { 'Nenhum detectado' }
}

Invoke-Etapa 'Impressoras' {
    if (Test-ComandoExiste 'Get-Printer') {
        # Spooler travado (driver de impressora com problema) deixa o Get-Printer parado indefinidamente.
        $impressoras = @(Invoke-ComLimiteTempo {
                Get-Printer | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DriverName = $_.DriverName; PortName = $_.PortName
                    Shared = $_.Shared; ShareName = $_.ShareName; Published = $_.Published } }
            } 'Impressoras (spooler)' 30)
        Save-Dados 'impressoras' $impressoras 'Impressoras instaladas na máquina'
        $portas = @(Invoke-ComLimiteTempo {
                Get-PrinterPort | Where-Object { $_.PrinterHostAddress } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; PrinterHostAddress = $_.PrinterHostAddress; PortNumber = $_.PortNumber } }
            } 'Portas de impressão (spooler)' 30)
        Save-Dados 'impressoras_portas' $portas 'Portas TCP/IP de impressão'
    }
}

Invoke-Etapa 'Monitores' {
    # Número de série do monitor é patrimônio: entra no inventário do cliente.
    $mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Fabricante    = ConvertFrom-CharArrayWmi $_.ManufacturerName
            Modelo        = ConvertFrom-CharArrayWmi $_.UserFriendlyName
            NumeroSerie   = ConvertFrom-CharArrayWmi $_.SerialNumberID
            AnoFabricacao = $_.YearOfManufacture
            SemanaFabricacao = $_.WeekOfManufacture
        }
    })
    Save-Dados 'monitores' $mons 'Monitores conectados: fabricante, modelo, número de série e ano de fabricação'
    $script:Resumo['Monitores'] = ($mons | ForEach-Object { "$($_.Fabricante) $($_.Modelo) ($($_.AnoFabricacao))" }) -join ' | '
}

Invoke-Etapa 'Wi-Fi' {
    # Sem placa Wi-Fi ou sem o serviço WLAN rodando, o netsh wlan pode ficar parado esperando o serviço: nem chama.
    $placasWifi = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -in 1, 9 -or $_.PhysicalMediaType -match '802\.11|Wireless' })
    $servicoWlan = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
    if ($placasWifi.Count -eq 0 -or -not $servicoWlan -or $servicoWlan.Status -ne 'Running') {
        Write-Log "Wi-Fi ignorado: $(if ($placasWifi.Count -eq 0) { 'nenhuma placa Wi-Fi' } else { 'serviço WLAN parado' })." -SoArquivo
        return
    }
    # Cada consulta do netsh tem limite de tempo e roda uma vez só; a mesma saída vai para o arquivo e para a análise.
    $saida = Invoke-Externo 'netsh wlan show interfaces' 10
    if (-not $saida -or $saida -match '(?i)não está em execução|is not running|nenhuma interface|no wireless') { return }
    $saida | Out-File -FilePath (Join-Path $script:PastaSaida 'wifi_interface.txt') -Encoding UTF8
    $script:Arquivos.Add([pscustomobject]@{ Arquivo = 'wifi_interface.txt'; Registros = $null; Descricao = 'Conexão Wi-Fi atual (SSID, sinal, canal, taxa)' })
    Save-TextoExterno 'wifi_perfis' @('netsh wlan show profiles') 'Redes Wi-Fi salvas nesta máquina' 10
    $pegar = { param($Rotulo) if ($saida -match "(?im)^\s*$Rotulo\s*:\s*(.+)$") { $Matches[1].Trim() } else { '' } }
    $ssid  = & $pegar 'SSID'
    $sinal = & $pegar '(?:Sinal|Signal)'
    $radio = & $pegar '(?:Tipo de r.dio|Radio type)'
    $banda = & $pegar '(?:Banda|Band)'
    $canal = & $pegar '(?:Canal|Channel)'
    if ($ssid) {
        $script:Resumo['Wi-Fi conectado'] = (@("$ssid", "sinal $sinal", $banda, "canal $canal", $radio) | Where-Object { $_ -and $_ -notmatch '^(sinal|canal)\s*$' }) -join ' | '
        if ($script:EhServidor) { Add-Alerta 'Média' 'Rede' 'Servidor conectado por Wi-Fi' 'Servidor deve usar cabo; Wi-Fi compromete estabilidade e backup' }
    }

    # Wi-Fi do ambiente: redes visíveis, canal e sinal, para achar interferência e AP mal posicionado.
    $saidaRedes = Invoke-Externo 'netsh wlan show networks mode=bssid' 15
    $(if ($null -eq $saidaRedes) { 'Sem resposta do netsh em 15 s (comando interrompido)' } else { $saidaRedes }) |
        Out-File -FilePath (Join-Path $script:PastaSaida 'wifi_redes_visiveis.txt') -Encoding UTF8
    $script:Arquivos.Add([pscustomobject]@{ Arquivo = 'wifi_redes_visiveis.txt'; Registros = $null; Descricao = 'Redes Wi-Fi visíveis no ambiente, com canal e sinal' })
    $redes = New-Object System.Collections.Generic.List[object]
    $ssidAtual = ''
    foreach ($l in ($saidaRedes -split "`r?`n")) {
        if ($l -match '(?im)^\s*SSID\s+\d+\s*:\s*(.*)$') { $ssidAtual = $Matches[1].Trim() }
        elseif ($l -match '(?im)^\s*(?:Sinal|Signal)\s*:\s*(.+)$') { $sinalRede = $Matches[1].Trim() }
        elseif ($l -match '(?im)^\s*(?:Canal|Channel)\s*:\s*(.+)$') {
            $redes.Add([pscustomobject]@{ SSID = $(if ($ssidAtual) { $ssidAtual } else { '(oculto)' }); Canal = $Matches[1].Trim(); Sinal = $sinalRede })
        }
    }
    if ($redes.Count) {
        Save-Dados 'wifi_ambiente' $redes 'Redes Wi-Fi do ambiente (SSID, canal e sinal)'
        $script:Resumo['Wi-Fi no ambiente'] = "$($redes.Count) rede(s) visível(eis)"
        $porCanal = $redes | Group-Object Canal | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 1
        if ($porCanal) { Add-Alerta 'Baixa' 'Rede' 'Canal Wi-Fi congestionado' "Canal $($porCanal.Name) com $($porCanal.Count) redes: avaliar mudança de canal do AP" }
    }
}

Invoke-Etapa 'Proxy, VLAN e rotas de saída' {
    $proxyUsuario = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer'
    $proxyAtivo   = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyEnable'
    $proxyAuto    = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoConfigURL'
    $script:Resumo['Proxy configurado'] = if ($proxyAtivo -eq 1 -and $proxyUsuario) { $proxyUsuario }
        elseif ($proxyAuto) { "Automático: $proxyAuto" } else { 'Não' }
    Save-TextoExterno 'proxy_winhttp' @('netsh winhttp show proxy') 'Proxy do WinHTTP (usado por serviços e atualizações)' 10

    # Só interessa a propriedade que carrega o número da VLAN. "Prioridade & VLAN ativado" é outra coisa.
    $vlans = @(Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)VLAN\s*ID' -and "$($_.DisplayValue)" -match '^\d+$' -and [int]$_.DisplayValue -gt 0 } |
        Select-Object Name, DisplayName, DisplayValue)
    Save-Dados 'rede_vlan' $vlans 'Marcação de VLAN (802.1Q) configurada nas placas de rede'
    $script:Resumo['VLAN na placa de rede'] = if ($vlans.Count -gt 0) { ($vlans | ForEach-Object { "$($_.Name)=$($_.DisplayValue)" }) -join ', ' } else { 'Nenhuma' }

    $padrao = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object @{ n = 'Interface'; e = { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name } }, NextHop, RouteMetric, InterfaceMetric)
    Save-Dados 'rede_rotas_padrao' $padrao 'Rotas padrão (mais de uma indica múltiplos links ou VPN ativa)'
    if ($padrao.Count -gt 1) {
        $script:Resumo['Links de saída'] = "$($padrao.Count) rotas padrão: " + (($padrao | ForEach-Object { "$($_.NextHop) via $($_.Interface)" }) -join ', ')
    }
}

# Definida como função para rodar DEPOIS do AD: em domínio .local o único jeito de descobrir o
# domínio público de e-mail sozinho é pelo sufixo UPN dos usuários.
function Invoke-EtapaEmail {
Invoke-Etapa 'E-mail: MX, SPF, DKIM e DMARC' {
    # Precisa do domínio público de e-mail. O domínio do AD costuma ser interno (.local) e não serve.
    $dominio = $DominioEmail
    if (-not $dominio) {
        $candidato = (Get-CimInstance Win32_ComputerSystem).Domain
        if ($candidato -and $candidato -match '\.' -and $candidato -notmatch '(?i)\.(local|lan|internal|corp|home|intranet)$') { $dominio = $candidato }
    }
    if (-not $dominio) {
        Write-Log 'Domínio público de e-mail não informado; use -DominioEmail cartorio.com.br para conferir MX, SPF, DKIM e DMARC.' 'AVISO'
        return
    }
    $script:Resumo['Domínio de e-mail verificado'] = $dominio

    # -QuickTimeout é essencial: sem ele, cada seletor DKIM inexistente custa ~11 s e a etapa leva minutos.
    $consulta = {
        param($Nome, $Tipo)
        try { @(Resolve-DnsName -Name $Nome -Type $Tipo -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq $Tipo }) } catch { @() }
    }
    $registros = New-Object System.Collections.Generic.List[object]

    $mx = @(& $consulta $dominio 'MX' | Sort-Object Preference)
    $mxTexto = ($mx | ForEach-Object { "$($_.NameExchange) ($($_.Preference))" }) -join ', '
    foreach ($m in $mx) { $registros.Add([pscustomobject]@{ Dominio = $dominio; Tipo = 'MX'; Nome = $dominio; Valor = "$($m.NameExchange) prioridade $($m.Preference)" }) }
    $plataforma = if ($mxTexto -match '(?i)outlook\.com|protection\.outlook') { 'Microsoft 365' }
        elseif ($mxTexto -match '(?i)google|googlemail') { 'Google Workspace' }
        elseif ($mxTexto -match '(?i)locaweb|umbler|hostgator|kinghost') { 'Hospedagem nacional' }
        elseif ($mxTexto) { 'Outro/próprio' } else { 'Sem MX publicado' }
    $script:Resumo['Plataforma de e-mail (pelo MX)'] = "$plataforma | $mxTexto"
    if (-not $mx) { Add-Alerta 'Info' 'E-mail' 'Domínio sem registro MX' "$dominio não publica MX; confirmar se o e-mail usa outro domínio" }

    $txt = @(& $consulta $dominio 'TXT')
    $spf = ($txt | ForEach-Object { ($_.Strings -join '') } | Where-Object { $_ -match '^v=spf1' } | Select-Object -First 1)
    if ($spf) {
        $registros.Add([pscustomobject]@{ Dominio = $dominio; Tipo = 'SPF'; Nome = $dominio; Valor = $spf })
        $script:Resumo['SPF'] = $spf
        if ($spf -match '\+all') { Add-Alerta 'Alta' 'E-mail' 'SPF permite qualquer remetente (+all)' "$dominio : $spf" }
        elseif ($spf -notmatch '[-~]all') { Add-Alerta 'Média' 'E-mail' 'SPF sem regra final (-all ou ~all)' "$dominio : $spf" }
    } else {
        $script:Resumo['SPF'] = 'Não publicado'
        Add-Alerta 'Média' 'E-mail' 'Domínio sem SPF' "$dominio permite falsificação de remetente"
    }

    $dmarcTxt = @(& $consulta "_dmarc.$dominio" 'TXT')
    $dmarc = ($dmarcTxt | ForEach-Object { ($_.Strings -join '') } | Where-Object { $_ -match '^v=DMARC1' } | Select-Object -First 1)
    if ($dmarc) {
        $registros.Add([pscustomobject]@{ Dominio = $dominio; Tipo = 'DMARC'; Nome = "_dmarc.$dominio"; Valor = $dmarc })
        $script:Resumo['DMARC'] = $dmarc
        if ($dmarc -match 'p=none') { Add-Alerta 'Baixa' 'E-mail' 'DMARC apenas em modo monitoramento (p=none)' "$dominio : $dmarc" }
    } else {
        $script:Resumo['DMARC'] = 'Não publicado'
        Add-Alerta 'Média' 'E-mail' 'Domínio sem DMARC' "$dominio sem política contra falsificação"
    }

    # DKIM depende do seletor, que varia por provedor; testa os mais comuns.
    $seletores = 'selector1', 'selector2', 'google', 'default', 'dkim', 'locaweb'
    $achados = @(foreach ($s in $seletores) {
        $n = "$s._domainkey.$dominio"
        $r = @(& $consulta $n 'CNAME') + @(& $consulta $n 'TXT')
        if ($r.Count -gt 0) {
            $registros.Add([pscustomobject]@{ Dominio = $dominio; Tipo = 'DKIM'; Nome = $n; Valor = 'seletor publicado' })
            $s
        }
    })
    $script:Resumo['DKIM'] = if ($achados.Count -gt 0) { "Seletores encontrados: $($achados -join ', ')" } else { 'Nenhum seletor comum encontrado (pode usar seletor próprio)' }
    if ($achados.Count -eq 0) { Add-Alerta 'Baixa' 'E-mail' 'DKIM não confirmado' "$dominio : nenhum seletor comum respondeu; confirmar no painel do provedor" }

    Save-Dados 'email_dns' $registros 'Registros DNS de e-mail do domínio: MX, SPF, DKIM e DMARC'
}
}

Invoke-Etapa 'Programas na inicialização' {
    $ini = @(Get-CimInstance Win32_StartupCommand | ForEach-Object {
        [pscustomobject]@{ Nome = $_.Name; Comando = Protect-Texto $_.Command; Local = $_.Location; Usuario = $_.User }
    })
    Save-Dados 'inicializacao' $ini 'Programas que sobem junto com o Windows (senhas mascaradas)'
}

Invoke-Etapa 'Hyper-V' {
    if (Test-ComandoExiste 'Get-VM') {
        $vms = @(Get-VM | Select-Object Name, State, Generation, ProcessorCount, @{ n = 'MemoriaGB'; e = { [math]::Round($_.MemoryAssigned / 1GB, 1) } }, Uptime, Version)
        Save-Dados 'hyperv_vms' $vms 'Máquinas virtuais do Hyper-V'
        $script:Resumo['Máquinas virtuais'] = if ($vms.Count -gt 0) { ($vms | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', ' } else { 'Nenhuma (papel instalado)' }
        if ($vms.Count -eq 0) { Add-Alerta 'Info' 'Virtualização' 'Papel Hyper-V instalado sem máquinas virtuais' 'O vSwitch ocupa a placa de produção. Se não há VMs, avaliar remover o papel e devolver o IP à placa física' }

        # Checkpoint esquecido cresce sem parar e derruba o host por falta de disco (GS.19 do checklist).
        $snaps = @(Get-VMSnapshot -VMName * -ErrorAction SilentlyContinue |
            Select-Object VMName, Name, SnapshotType, CreationTime, @{ n = 'DiasDeIdade'; e = { [int]((Get-Date) - $_.CreationTime).TotalDays } })
        Save-Dados 'hyperv_snapshots' $snaps 'Checkpoints das máquinas virtuais e há quanto tempo existem'
        foreach ($s in $snaps | Where-Object { $_.DiasDeIdade -gt 7 }) {
            $sev = if ($s.DiasDeIdade -gt 30) { 'Média' } else { 'Baixa' }
            Add-Alerta $sev 'Virtualização' "Checkpoint antigo em $($s.VMName)" "'$($s.Name)' criado há $($s.DiasDeIdade) dias; consome disco e degrada desempenho"
        }
    }
}

Invoke-Etapa 'Licenciamento do Windows' {
    $mapaStatus = @{ 0 = 'Não licenciado'; 1 = 'Licenciado'; 2 = 'Carência OOB'; 3 = 'Carência OOT'; 4 = 'Carência não genuína'; 5 = 'Notificação'; 6 = 'Carência estendida' }
    # SoftwareLicensingProduct é lento por natureza (consulta o serviço de licenciamento): prazo maior que o padrão.
    $licencas = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -OperationTimeoutSec 120 |
        Select-Object Name, Description, @{ n = 'Status'; e = { $mapaStatus[[int]$_.LicenseStatus] } })
    Save-Dados 'licenciamento_windows' $licencas 'Ativação do Windows (sem chave)'
    $script:Resumo['Ativação do Windows'] = ($licencas.Status | Select-Object -Unique) -join ', '
    if ($licencas | Where-Object { $_.Status -ne 'Licenciado' }) { Add-Alerta 'Média' 'Licenciamento' 'Windows não ativado' (($licencas.Status) -join ', ') }

    # Office: o assessment cobra comprovante de licença, e ativação por método alternativo é achado comum (REQ-011).
    $office = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -OperationTimeoutSec 120 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)office|project|visio' } |
        Select-Object Name, Description, @{ n = 'Status'; e = { $mapaStatus[[int]$_.LicenseStatus] } },
                      @{ n = 'Canal'; e = { if ($_.Description -match 'KMS') { 'KMS' } elseif ($_.Description -match 'MAK') { 'MAK' } elseif ($_.Description -match 'Retail') { 'Varejo' } elseif ($_.Description -match 'OEM') { 'OEM' } else { '' } } },
                      @{ n = 'ServidorKms'; e = { $_.KeyManagementServiceMachine } })
    Save-Dados 'licenciamento_office' $office 'Ativação do Office, Project e Visio, com canal de licenciamento'
    if ($office.Count -gt 0) {
        $script:Resumo['Ativação do Office'] = ($office | ForEach-Object { "$($_.Name): $($_.Status)$(if ($_.Canal) { " ($($_.Canal))" })" }) -join ' | '
        foreach ($o in $office | Where-Object { $_.Status -ne 'Licenciado' }) {
            Add-Alerta 'Alta' 'Licenciamento' "Office não licenciado: $($o.Name)" "Situação: $($o.Status). REQ-011 exige comprovante de licença"
        }
        foreach ($o in $office | Where-Object { $_.Canal -eq 'KMS' -and $_.ServidorKms }) {
            Add-Alerta 'Média' 'Licenciamento' "Office ativado por KMS: $($o.Name)" "Servidor KMS $($o.ServidorKms). Confirmar se é KMS legítimo do cliente e não ativador irregular"
        }
    } else {
        $resumoC2r = Get-ResumoOfficeClickToRun (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue)
        if ($resumoC2r) { $script:Resumo['Ativação do Office'] = $resumoC2r }
    }
}

Invoke-Etapa 'Energia (nobreak USB)' {
    $baterias = @(Get-CimInstance Win32_Battery | Select-Object Name, DeviceID, EstimatedChargeRemaining, EstimatedRunTime, BatteryStatus)
    Save-Dados 'nobreak_usb' $baterias 'Nobreak conectado por USB (quando reconhecido pelo Windows)'
    $script:Resumo['Nobreak com comunicação USB'] = if ($baterias.Count -gt 0) { 'Sim' } else { 'Não identificado' }
}

Invoke-Etapa 'Eventos críticos' {
    $desde = (Get-Date).AddDays(-$DiasEventos)
    $eventos = foreach ($log in 'System', 'Application') {
        try { Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $desde } -MaxEvents 5000 -ErrorAction Stop } catch { }
    }
    $agrupados = @($eventos | Group-Object LogName, ProviderName, Id | Sort-Object Count -Descending | ForEach-Object {
        $amostra = $_.Group | Select-Object -First 1
        $mensagem = "$($amostra.Message)" -replace '\s+', ' '
        [pscustomobject]@{ Log = $amostra.LogName; Origem = $amostra.ProviderName; Id = $amostra.Id; Ocorrencias = $_.Count
            Ultima = Format-Data (($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated)
            Mensagem = if ($mensagem.Length -gt 250) { $mensagem.Substring(0, 250) } else { $mensagem } }
    })
    Save-Dados 'eventos_erros' $agrupados "Erros e eventos críticos dos últimos $DiasEventos dias, agrupados"
    $disco = @($agrupados | Where-Object { $_.Origem -match '(?i)^(disk|storahci|stornvme|storport|iaStor\w*|percsas\w*|megasas\w*|Ntfs)$' })
    if ($disco.Count -gt 0) { Add-Alerta 'Alta' 'Armazenamento' 'Erros de disco ou controladora no log' (($disco | ForEach-Object { "$($_.Origem) $($_.Id) ($($_.Ocorrencias)x)" }) -join '; ') }
    $desligamentos = @($agrupados | Where-Object { $_.Id -in 41, 6008 })
    if ($desligamentos.Count -gt 0) { Add-Alerta 'Média' 'Servidor' 'Desligamentos inesperados' (($desligamentos | ForEach-Object { "Evento $($_.Id) ($($_.Ocorrencias)x)" }) -join '; ') }
}

Invoke-Etapa 'Sincronização de horário' {
    Save-TextoExterno 'horario_w32tm' @('w32tm /query /status', 'w32tm /query /source', 'w32tm /query /configuration') 'Sincronização de horário (w32tm)' 15
    $script:Resumo['Fonte de horário'] = "$(Invoke-Externo 'w32tm /query /source' 15)".Trim()
    $script:Resumo['Fuso horário'] = (Get-TimeZone).DisplayName
}

# ============================================================================
# 2. Active Directory
# ============================================================================

Write-Secao 'Active Directory'
if ($SemAD) { Write-Log 'Ignorado (-SemAD).' }

$temAD = $false
if (-not $SemAD) {
    try { Import-Module ActiveDirectory -ErrorAction Stop; $temAD = $true }
    catch { Write-Log 'Módulo ActiveDirectory indisponível: coleta do AD ignorada (rodar no DC ou instalar RSAT).' 'AVISO' }
}

if ($temAD) {
    Invoke-Etapa 'AD: domínio, floresta e DCs' {
        $script:DominioAD = Get-ADDomain
        $floresta = Get-ADForest
        $script:UpnSuffixesForest = @($floresta.UPNSuffixes)
        $d = $script:DominioAD
        $script:Resumo['Domínio AD'] = "$($d.DNSRoot) (NetBIOS $($d.NetBIOSName))"
        $script:Resumo['Nível funcional'] = "Domínio $($d.DomainMode) | Floresta $($floresta.ForestMode)"
        $script:Resumo['FSMO'] = 'PDC {0} | RID {1} | Infra {2} | Schema {3} | Naming {4}' -f $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster, $floresta.SchemaMaster, $floresta.DomainNamingMaster
        $dcs = @(Get-ADDomainController -Filter * | Select-Object Name, IPv4Address, OperatingSystem, OperatingSystemVersion, Site, IsGlobalCatalog, IsReadOnly)
        Save-Dados 'ad_controladores' $dcs 'Controladores de domínio'
        $script:Resumo['Controladores de domínio'] = ($dcs | ForEach-Object { "$($_.Name) ($($_.IPv4Address))" }) -join ', '
        if ($dcs.Count -eq 1) { Add-Alerta 'Média' 'Active Directory' 'Apenas um controlador de domínio' 'Sem redundância do AD; backup do estado do sistema é essencial' }
        $lixeira = Get-ADOptionalFeature -Filter "Name -like 'Recycle Bin Feature'"
        $script:Resumo['Lixeira do AD'] = if ($lixeira.EnabledScopes.Count -gt 0) { 'Habilitada' } else { 'Desabilitada' }
        if ($lixeira.EnabledScopes.Count -eq 0) { Add-Alerta 'Baixa' 'Active Directory' 'Lixeira do AD desabilitada' 'Habilitar para permitir restaurar objetos excluídos' }
        Save-Dados 'ad_ous' (Get-ADOrganizationalUnit -Filter * -Properties ProtectedFromAccidentalDeletion | Select-Object Name, DistinguishedName, ProtectedFromAccidentalDeletion) 'Unidades organizacionais'
    }

    Invoke-Etapa 'AD: usuários' {
        $limite = (Get-Date).AddDays(-$DiasInatividade)
        $usuarios = @(Get-ADUser -Filter * -Properties LastLogonDate, PasswordLastSet, PasswordNeverExpires, PasswordNotRequired, whenCreated, Description, Title, Department, LockedOut, AdminCount, EmailAddress, UserPrincipalName, SID |
            Select-Object SamAccountName, Name, Enabled, LastLogonDate,
                @{ n = 'DiasSemLogon'; e = { if ($_.LastLogonDate) { [int]((Get-Date) - $_.LastLogonDate).TotalDays } else { $null } } },
                PasswordLastSet, PasswordNeverExpires, PasswordNotRequired, LockedOut, AdminCount, whenCreated, Title, Department, EmailAddress, UserPrincipalName, Description,
                @{ n = 'SID'; e = { $_.SID.Value } }, DistinguishedName)
        Save-Dados 'ad_usuarios' $usuarios 'Usuários do AD com último logon e situação da senha'

        # Domínio público de e-mail deduzido do AD: sufixo UPN ou e-mail dos usuários, ou sufixos da floresta.
        $ehPublico = { param($d) $d -and $d -match '^[a-z0-9.-]+\.[a-z]{2,}$' -and $d -notmatch '(?i)\.(local|lan|internal|corp|home|intranet|test|localdomain)$' }
        $sufixos = @($usuarios | Where-Object { $_.Enabled } | ForEach-Object { @($_.UserPrincipalName, $_.EmailAddress) } |
            Where-Object { $_ -match '@' } | ForEach-Object { ($_ -split '@')[1].ToLower() } | Where-Object { & $ehPublico $_ } |
            Group-Object | Sort-Object Count -Descending | ForEach-Object { $_.Name })
        $sufixos += @($script:UpnSuffixesForest | ForEach-Object { "$_".ToLower() } | Where-Object { & $ehPublico $_ })
        $script:DominioEmailAD = @($sufixos | Select-Object -Unique -First 1)
        $ativos = @($usuarios | Where-Object { $_.Enabled })
        $inativos = @($ativos | Where-Object { -not $_.LastLogonDate -or $_.LastLogonDate -lt $limite })
        $nuncaExpira = @($ativos | Where-Object { $_.PasswordNeverExpires })
        $semSenha = @($ativos | Where-Object { $_.PasswordNotRequired })
        Save-Dados 'ad_usuarios_inativos' $inativos "Usuários habilitados sem logon há mais de $DiasInatividade dias"
        $script:Resumo['Usuários do AD'] = "$($usuarios.Count) no total | $($ativos.Count) habilitados | $($inativos.Count) inativos há +$DiasInatividade dias | $($nuncaExpira.Count) com senha que nunca expira"
        if ($inativos.Count -gt 0) { Add-Alerta 'Média' 'Active Directory' "$($inativos.Count) usuário(s) habilitado(s) inativo(s)" (($inativos.SamAccountName | Select-Object -First 10) -join ', ') }
        if ($nuncaExpira.Count -gt 0) { Add-Alerta 'Média' 'Active Directory' "$($nuncaExpira.Count) usuário(s) com senha que nunca expira" (($nuncaExpira.SamAccountName | Select-Object -First 10) -join ', ') }
        if ($semSenha.Count -gt 0) { Add-Alerta 'Alta' 'Active Directory' 'Usuários que não exigem senha' (($semSenha.SamAccountName) -join ', ') }
        $adminPadrao = $usuarios | Where-Object { $_.SID -like '*-500' }
        if ($adminPadrao -and $adminPadrao.Enabled) { Add-Alerta 'Baixa' 'Active Directory' 'Conta Administrator padrão habilitada' "Conta $($adminPadrao.SamAccountName); preferir contas nominais" }
        $convidado = $usuarios | Where-Object { $_.SID -like '*-501' }
        if ($convidado -and $convidado.Enabled) { Add-Alerta 'Alta' 'Active Directory' 'Conta Convidado habilitada' $convidado.SamAccountName }
        $krbtgt = Get-ADUser krbtgt -Properties PasswordLastSet
        $diasKrb = [int]((Get-Date) - $krbtgt.PasswordLastSet).TotalDays
        $script:Resumo['Senha do krbtgt'] = "Trocada há $diasKrb dias"
        if ($diasKrb -gt 365) { Add-Alerta 'Baixa' 'Active Directory' 'Senha do krbtgt antiga' "$diasKrb dias sem troca" }
    }

    Invoke-Etapa 'AD: grupos privilegiados' {
        $sidDominio = $script:DominioAD.DomainSID.Value
        $grupos = [ordered]@{
            'Admins. do domínio (Domain Admins)'   = "$sidDominio-512"
            'Admins. corporativos (Enterprise)'    = "$sidDominio-519"
            'Admins. de esquema (Schema)'          = "$sidDominio-518"
            'Administradores (Builtin)'            = 'S-1-5-32-544'
            'Opers. de contas (Account Operators)' = 'S-1-5-32-548'
            'Opers. de backup (Backup Operators)'  = 'S-1-5-32-551'
            'Opers. de servidor (Server Operators)' = 'S-1-5-32-549'
        }
        $membros = foreach ($nome in $grupos.Keys) {
            try {
                Get-ADGroupMember -Identity $grupos[$nome] -Recursive -ErrorAction Stop |
                    Select-Object @{ n = 'Grupo'; e = { $nome } }, SamAccountName, Name, objectClass
            } catch { }
        }
        Save-Dados 'ad_grupos_privilegiados' $membros 'Membros (recursivos) dos grupos privilegiados'
        $admins = @($membros | Where-Object { $_.Grupo -like 'Admins. do domínio*' })
        $script:Resumo['Admins. do domínio'] = "$($admins.Count): " + (($admins.SamAccountName) -join ', ')
        if ($admins.Count -gt 3) { Add-Alerta 'Média' 'Active Directory' "$($admins.Count) contas em Admins. do domínio" 'Reduzir ao mínimo necessário' }

        $todos = @(Get-ADGroup -Filter * -Properties member, Description | Select-Object Name, GroupScope, GroupCategory, @{ n = 'Membros'; e = { @($_.member).Count } }, Description, DistinguishedName)
        Save-Dados 'ad_grupos' $todos 'Grupos do AD e quantidade de membros'
        $relacao = foreach ($g in $todos | Where-Object { $_.Membros -gt 0 -and $_.DistinguishedName -notmatch 'CN=Builtin' }) {
            try { Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction Stop | Select-Object @{ n = 'Grupo'; e = { $g.Name } }, SamAccountName, Name, objectClass } catch { }
        }
        Save-Dados 'ad_grupos_membros' $relacao 'Membros diretos de cada grupo'
    }

    Invoke-Etapa 'AD: computadores' {
        $limite = (Get-Date).AddDays(-$DiasInatividade)
        $script:ComputadoresAD = @(Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, LastLogonDate, IPv4Address, whenCreated, Description |
            ForEach-Object {
                $build = if ($_.OperatingSystemVersion -match '\((\d+)\)') { [int]$Matches[1] } else { 0 }
                [pscustomobject]@{ Nome = $_.Name; DNS = $_.DNSHostName; Habilitado = $_.Enabled; SO = $_.OperatingSystem; VersaoSO = $_.OperatingSystemVersion
                    Suporte = if ($_.OperatingSystem) { Get-SituacaoSuporte -Caption $_.OperatingSystem -Build $build } else { '' }
                    UltimoLogon = $_.LastLogonDate; IPv4 = $_.IPv4Address; CriadoEm = $_.whenCreated; Descricao = $_.Description; DN = $_.DistinguishedName }
            })
        Save-Dados 'ad_computadores' $script:ComputadoresAD 'Computadores do AD, SO e situação de suporte'
        $inativos = @($script:ComputadoresAD | Where-Object { $_.Habilitado -and (-not $_.UltimoLogon -or $_.UltimoLogon -lt $limite) })
        $foraSuporte = @($script:ComputadoresAD | Where-Object { $_.Habilitado -and $_.Suporte -like 'Fora de suporte*' -and $_ -notin $inativos })
        $script:Resumo['Computadores do AD'] = "$($script:ComputadoresAD.Count) no total | $($inativos.Count) inativos | $($foraSuporte.Count) ativos com SO fora de suporte"
        if ($foraSuporte.Count -gt 0) { Add-Alerta 'Alta' 'Estações' "$($foraSuporte.Count) computador(es) com SO fora de suporte" ((($foraSuporte | ForEach-Object { "$($_.Nome) ($($_.SO))" }) -join ', ') + ' | Provimento 213, art. 4º, § 3º') }
        if ($inativos.Count -gt 0) { Add-Alerta 'Baixa' 'Active Directory' "$($inativos.Count) computador(es) inativo(s) no AD" (($inativos.Nome | Select-Object -First 10) -join ', ') }
    }

    Invoke-Etapa 'AD: política de senha' {
        $p = Get-ADDefaultDomainPasswordPolicy
        $script:Resumo['Política de senha do domínio'] = 'Mínimo {0} | Complexidade {1} | Validade {2} dias | Histórico {3} | Bloqueio após {4} tentativas' -f $p.MinPasswordLength, $p.ComplexityEnabled, [int]$p.MaxPasswordAge.TotalDays, $p.PasswordHistoryCount, $p.LockoutThreshold
        if ($p.MinPasswordLength -lt 12) { Add-Alerta 'Média' 'Active Directory' 'Senha mínima curta' "$($p.MinPasswordLength) caracteres (padrão Nextec: 12)" }
        if (-not $p.ComplexityEnabled) { Add-Alerta 'Média' 'Active Directory' 'Complexidade de senha desligada' 'Habilitar na política padrão do domínio' }
        if ($p.LockoutThreshold -eq 0) { Add-Alerta 'Média' 'Active Directory' 'Sem bloqueio de conta por tentativas' 'Configurar bloqueio (ex.: 5 tentativas)' }
        Save-Dados 'ad_politicas_senha_refinadas' (Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, Precedence, MinPasswordLength, ComplexityEnabled, MaxPasswordAge, LockoutThreshold, AppliesTo) 'Políticas de senha refinadas'
    }

    Invoke-Etapa 'AD: GPOs' {
        Import-Module GroupPolicy -ErrorAction Stop
        $gpos = @(Get-GPO -All | Select-Object DisplayName, GpoStatus, CreationTime, ModificationTime, Owner, Id)
        Save-Dados 'ad_gpos' $gpos 'Objetos de política de grupo'
        $alvos = @($script:DominioAD.DistinguishedName) + @((Get-ADOrganizationalUnit -Filter *).DistinguishedName)
        $vinculos = foreach ($alvo in $alvos) {
            try { (Get-GPInheritance -Target $alvo).GpoLinks | Select-Object @{ n = 'Destino'; e = { $alvo } }, DisplayName, Enabled, Enforced, Order } catch { }
        }
        Save-Dados 'ad_gpos_vinculos' $vinculos 'Onde cada GPO está vinculada'
        $vinculadas = @($vinculos.DisplayName | Select-Object -Unique)
        $orfas = @($gpos | Where-Object { $_.DisplayName -notin $vinculadas })
        if ($orfas.Count -gt 0) { Add-Alerta 'Info' 'Active Directory' "$($orfas.Count) GPO(s) sem vínculo" (($orfas.DisplayName) -join ', ') }
        $script:Resumo['GPOs'] = "$($gpos.Count) GPOs ($($orfas.Count) sem vínculo)"
        Get-GPOReport -All -ReportType Html -Path (Join-Path $script:PastaSaida 'ad_gpos_relatorio.html')
        $script:Arquivos.Add([pscustomobject]@{ Arquivo = 'ad_gpos_relatorio.html'; Registros = $gpos.Count; Descricao = 'Relatório completo das GPOs (configurações)' })
    }

    Invoke-Etapa 'AD: saúde (dcdiag e replicação)' {
        # dcdiag é lento por natureza (testa DNS, replicação e serviços); o limite só corta quando um DC parceiro não responde.
        if (Test-ComandoExiste 'dcdiag') { Save-TextoExterno 'ad_dcdiag' @('dcdiag /q') 'Testes do dcdiag (só falhas)' 300 }
        if (Test-ComandoExiste 'repadmin') { Save-TextoExterno 'ad_replicacao' @('repadmin /replsummary') 'Resumo da replicação do AD' 120 }
    }
}

Write-Secao 'Serviços de rede'
Invoke-Etapa 'DNS do servidor' {
    if (-not (Test-ComandoExiste 'Get-DnsServerZone')) { return }
    $zonas = @(Get-DnsServerZone -ErrorAction Stop | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate, IsAutoCreated)
    Save-Dados 'dns_zonas' $zonas 'Zonas DNS'

    # Sem zona reversa nenhum IP vira nome: inventário, log e diagnóstico ficam só com número.
    $reversas = @($zonas | Where-Object { $_.IsReverseLookupZone -and -not $_.IsAutoCreated } | ForEach-Object { $_.ZoneName })
    $semReversa = @(@(foreach ($ip in @($script:IpsLocais | Where-Object { $_ -and $_ -notlike '169.254.*' })) {
        $o = $ip -split '\.'
        if ($o.Count -ne 4) { continue }
        $z24 = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"; $z16 = "$($o[1]).$($o[0]).in-addr.arpa"; $z8 = "$($o[0]).in-addr.arpa"
        if ($z24 -notin $reversas -and $z16 -notin $reversas -and $z8 -notin $reversas) { "$($o[0]).$($o[1]).$($o[2]).0/24" }
    }) | Select-Object -Unique)
    if ($semReversa.Count -gt 0) {
        Add-Alerta 'Baixa' 'Active Directory' 'DNS sem zona de pesquisa inversa' "Faltam zonas reversas para $($semReversa -join ', '). Sem elas o IP não resolve para nome, e o inventário de rede sai sem nomes"
    }
    $encaminhadores = (Get-DnsServerForwarder).IPAddress.IPAddressToString -join ', '
    $script:Resumo['Encaminhadores DNS'] = $encaminhadores
    $limpeza = Get-DnsServerScavenging
    $script:Resumo['Limpeza de DNS (scavenging)'] = if ($limpeza.ScavengingState) { 'Ligada' } else { 'Desligada' }
}

Invoke-Etapa 'DHCP do servidor' {
    if (-not (Test-ComandoExiste 'Get-DhcpServerv4Scope')) { return }
    $escopos = @(Get-DhcpServerv4Scope -ErrorAction Stop)
    Save-Dados 'dhcp_escopos' ($escopos | Select-Object ScopeId, Name, SubnetMask, StartRange, EndRange, State, LeaseDuration) 'Escopos DHCP'
    $concessoes = foreach ($e in $escopos) { Get-DhcpServerv4Lease -ScopeId $e.ScopeId | Select-Object IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime }
    Save-Dados 'dhcp_concessoes' $concessoes 'Concessões DHCP ativas'
    $reservas = foreach ($e in $escopos) { Get-DhcpServerv4Reservation -ScopeId $e.ScopeId | Select-Object IPAddress, ClientId, Name, Description }
    Save-Dados 'dhcp_reservas' $reservas 'Reservas DHCP'
    $opcoes = foreach ($e in $escopos) { Get-DhcpServerv4OptionValue -ScopeId $e.ScopeId | Select-Object @{ n = 'Escopo'; e = { $e.ScopeId } }, OptionId, Name, @{ n = 'Valor'; e = { $_.Value -join ', ' } } }
    Save-Dados 'dhcp_opcoes' $opcoes 'Opções DHCP por escopo (gateway, DNS)'
    $script:Resumo['DHCP'] = "No servidor: $($escopos.Count) escopo(s)"
}

Invoke-Etapa 'DFS' {
    if (-not $temAD -or -not (Test-ComandoExiste 'Get-DfsnRoot')) { return }
    $raizes = @(Get-DfsnRoot -Domain $script:DominioAD.DNSRoot -ErrorAction Stop)
    $pastas = foreach ($r in $raizes) {
        foreach ($p in Get-DfsnFolder -Path "$($r.Path)\*" -ErrorAction SilentlyContinue) {
            Get-DfsnFolderTarget -Path $p.Path | Select-Object Path, TargetPath, State
        }
    }
    Save-Dados 'dfs_pastas' $pastas 'Namespaces DFS e destinos'
    $script:Resumo['DFS'] = ($raizes.Path) -join ', '
}

# E-mail só agora: se veio sem -DominioEmail e o AD apontou um sufixo público, usa ele.
if (-not $DominioEmail -and $script:DominioEmailAD) {
    $DominioEmail = "$($script:DominioEmailAD)"
    Write-Log "Domínio público de e-mail deduzido do AD: $DominioEmail"
}
Invoke-EtapaEmail

# ============================================================================
# 3. Varredura da rede
# ============================================================================

Write-Secao 'Varredura da rede'
if ($SemVarreduraRede) { Write-Log 'Ignorada (-SemVarreduraRede).' }
if (-not $SemVarreduraRede) {
    Invoke-Etapa 'Varredura da rede' {
        $cidrs = if ($Subredes) { $Subredes } else { Get-SubredesLocais }
        $script:Resumo['Sub-redes varridas'] = $cidrs -join ', '
        $ips = @(foreach ($c in $cidrs) { Get-IpsDaSubrede $c })
        Write-Log "Etapa 1 de 3: ping em $($ips.Count) endereços..."
        $vivos = @(Invoke-VarreduraPing -Ips $ips -Timeout $TimeoutPingMs)
        Write-Log "  $($vivos.Count) responderam ping."

        # Muita coisa não responde ping: Windows com firewall ligado, celular, impressora, câmera.
        # Uma sondagem TCP curta em portas comuns acha quem está no ar mesmo ignorando ICMP.
        $ipsTcp = @()
        # Só sonda quem não respondeu ping: quem já respondeu está confirmado e não precisa de mais tráfego.
        $faltantes = @($ips | Where-Object { $_ -notin @($vivos.Ip) })
        if ($faltantes.Count -le 4096) {
            $portasDescoberta = @(445, 135, 22, 80, 443, 3389)
            Write-Log "Etapa 2 de 3: sondagem TCP em $($faltantes.Count) endereços que não responderam ping ($($portasDescoberta.Count) portas)..."
            $ipsTcp = @(Invoke-VarreduraPortas -Ips $faltantes -Portas $portasDescoberta -Timeout $TimeoutPortaMs |
                ForEach-Object { $_.Ip } | Select-Object -Unique)
            Write-Log "  $($ipsTcp.Count) responderam em alguma porta."
        } else {
            Write-Log "Etapa 2 de 3 pulada: sub-rede grande demais ($($faltantes.Count) endereços) para a sondagem TCP." 'AVISO'
        }

        # O ARP responde no mesmo segmento mesmo quando ICMP e TCP são bloqueados: é a rede mais fiel.
        $vizinhos = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -notin 'Unreachable', 'Incomplete' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-){5}00$|^(FF-){5}FF$' -and $_.IPAddress -in $ips })
        $macs = @{}
        foreach ($v in $vizinhos) { $macs[$v.IPAddress] = $v.LinkLayerAddress }
        foreach ($local in Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -in $ips }) {
            $adaptador = Get-NetAdapter -InterfaceIndex $local.InterfaceIndex -ErrorAction SilentlyContinue
            if ($adaptador) { $macs[$local.IPAddress] = $adaptador.MacAddress }
        }
        Write-Log "  $($macs.Keys.Count) apareceram na tabela ARP."

        $alvos = @(@($vivos.Ip) + $ipsTcp + @($macs.Keys) | Where-Object { $_ } | Select-Object -Unique | Sort-Object { ConvertTo-NumeroIp $_ })
        $script:Resumo['Descoberta'] = "$($vivos.Count) por ping | $($ipsTcp.Count) por TCP | $($macs.Keys.Count) por ARP | $($alvos.Count) no total"
        $inicioPortas = Get-Date
        if ($PortasCompletas) {
            Write-Log "$($alvos.Count) dispositivos ativos. Varredura COMPLETA (portas 1 a 65535) em cada um: pode levar bastante tempo." 'AVISO'
            $listaAbertas = New-Object System.Collections.Generic.List[object]
            $i = 0
            foreach ($ip in $alvos) {
                $i++
                Write-Log "  [$i/$($alvos.Count)] Portas 1-65535 em $ip"
                foreach ($a in @(Invoke-VarreduraPortas -Ips @($ip) -Portas (1..65535) -Timeout $TimeoutPortaMs -Lote $(if ($Agressivo) { 1000 } else { 200 }))) { $listaAbertas.Add($a) }
            }
            $abertas = $listaAbertas.ToArray()
            $script:Resumo['Portas verificadas'] = 'Todas (1 a 65535)'
        } else {
            Write-Log "Etapa 3 de 3: $($alvos.Count) dispositivos no ar. Verificando $($Portas.Count) portas em cada..."
            $abertas = @(Invoke-VarreduraPortas -Ips $alvos -Portas $Portas -Timeout $TimeoutPortaMs)
            $script:Resumo['Portas verificadas'] = "$($Portas.Count) portas conhecidas (use -PortasCompletas para 1 a 65535)"
        }
        Write-Log ("Varredura de portas concluída em {0:N1} min: {1} porta(s) aberta(s)." -f ((Get-Date) - $inicioPortas).TotalMinutes, $abertas.Count)

        # Segunda leitura do ARP: impressora ou PC que acordou durante a varredura de portas entra na lista.
        $acordaram = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -notin 'Unreachable', 'Incomplete' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-){5}00$|^(FF-){5}FF$' -and $_.IPAddress -in $ips -and $_.IPAddress -notin $alvos })
        foreach ($v in $acordaram) { $macs[$v.IPAddress] = $v.LinkLayerAddress }
        if ($acordaram.Count -gt 0) {
            $alvos = @(@($alvos) + @($acordaram.IPAddress) | Select-Object -Unique | Sort-Object { ConvertTo-NumeroIp $_ })
            Write-Log "  +$($acordaram.Count) apareceram no ARP durante a varredura de portas."
        }

        # Nome pelo AD: o cadastro de computadores traz o IP de cada um, e resolve mesmo sem zona reversa no DNS.
        $adPorIp = @{}
        foreach ($c in @($script:ComputadoresAD)) { if ($c.IPv4) { $adPorIp["$($c.IPv4)"] = $c } }

        $gateways = @(($script:Resumo['Gateway'] -split ',\s*') | Where-Object { $_ })
        $compartilhamentosRede = New-Object System.Collections.Generic.List[object]
        $listaTls = New-Object System.Collections.Generic.List[object]
        $validacaoOriginal = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        try {
            # Somente leitura do título da página de administração dos equipamentos da rede local.
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $nomesAD = @($script:ComputadoresAD.Nome | ForEach-Object { "$_".ToUpper() })
            $contador = 0
            $script:Hosts = @(foreach ($ip in $alvos) {
                $contador++
                Write-Log "  [$contador/$($alvos.Count)] identificando $ip"
                $portasHost = @($abertas | Where-Object { $_.Ip -eq $ip } | ForEach-Object { $_.Porta } | Sort-Object)
                $ping = $vivos | Where-Object { $_.Ip -eq $ip } | Select-Object -First 1
                $ttl = if ($ping) { $ping.Ttl } else { 0 }
                $nome = try { (Resolve-DnsName -Name $ip -Type PTR -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'PTR' } | Select-Object -First 1).NameHost } catch { '' }
                $netbios = if ($portasHost -contains 139 -or $portasHost -contains 445) { Get-NomeNetBios $ip } else { '' }
                # Sem PTR (zona reversa ausente é comum), cai para o AD e depois para o registro A do nome NetBIOS.
                if (-not $nome -and $adPorIp.ContainsKey($ip)) { $nome = if ($adPorIp[$ip].DNS) { "$($adPorIp[$ip].DNS)" } else { "$($adPorIp[$ip].Nome)" } }
                if (-not $nome -and $netbios) {
                    $nome = try { (Resolve-DnsName -Name $netbios -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress -eq $ip } | Select-Object -First 1).Name } catch { '' }
                    if (-not $nome) { $nome = $netbios }
                }
                $fabricante = Get-FabricanteMac $macs[$ip]

                $web = $null
                foreach ($p in @(80, 443, 8080, 8000, 8443, 5000, 5001, 8081, 8888, 9000, 9090, 10000, 8006) | Where-Object { $_ -in $portasHost }) {
                    $web = Get-TituloWeb -Ip $ip -Porta $p
                    if ($web -and ($web.Titulo -or $web.Servidor)) { break }
                }
                $banners = @(foreach ($p in @(22, 21, 25) | Where-Object { $_ -in $portasHost }) {
                    $b = Get-BannerTcp -Ip $ip -Porta $p
                    if ($b) { "${p}: $b" }
                })

                # TLS: versões aceitas e certificado, no máximo uma porta por equipamento para não alongar demais.
                $tlsHost = @(foreach ($p in @($script:PortasTls | Where-Object { $_ -in $portasHost } | Select-Object -First 1)) {
                    $t = Get-InfoTls -Ip $ip -Porta $p -NomeHost $nome -Timeout 2000
                    if ($t) { $listaTls.Add($t); $t }
                })
                $soBanner = ($banners | ForEach-Object { Get-SoPorBanner $_ } | Where-Object { $_ } | Select-Object -First 1)

                $compartilhados = @()
                if ($ComandosExternos -and $portasHost -contains 445) {
                    $compartilhados = @(Get-CompartilhamentosRemotos -Ip $ip)
                    foreach ($c in $compartilhados) {
                        $compartilhamentosRede.Add([pscustomobject]@{ IP = $ip; Nome = $(if ($nome) { $nome } else { $netbios }); Compartilhamento = $c.Nome; Tipo = $c.Tipo; Comentario = $c.Comentario })
                    }
                }

                $nomeCurto = if ($nome) { $nome.Split('.')[0].ToUpper() } elseif ($netbios) { $netbios.ToUpper() } else { '' }
                $soAD = if ($nomeCurto) { ($script:ComputadoresAD | Where-Object { "$($_.Nome)".ToUpper() -eq $nomeCurto } | Select-Object -First 1).SO } else { $null }
                $soProvavel = if ($soAD) { $soAD }
                    elseif ($soBanner) { $soBanner }
                    elseif ($portasHost -contains 445 -or $portasHost -contains 3389 -or $portasHost -contains 135) { 'Windows (pelas portas)' }
                    elseif ($ttl -gt 128) { 'Equipamento de rede/Unix (pelo TTL)' }
                    elseif ($ttl -gt 64) { 'Windows (pelo TTL)' }
                    elseif ($ttl -gt 0) { 'Linux/Unix/embarcado (pelo TTL)' }
                    else { '' }

                $textoTipo = "$(if ($web) { "$($web.Titulo) $($web.Servidor)" }) $($banners -join ' ') $soBanner"
                $tipo = Get-TipoProvavel -PortasAbertas $portasHost -Ttl $ttl -TextoWeb $textoTipo -Fabricante $fabricante
                $categoria = Get-CategoriaDispositivo $tipo

                # A coleta pode rodar de qualquer máquina. Os IPs dela (inclusive WSL/Docker/Hyper-V) aparecem na
                # varredura como se fossem outros equipamentos; aqui eles são identificados para não poluir o inventário.
                $ehLocal = $ip -in $script:IpsLocais
                $ehLocalVirtual = $ip -in $script:IpsLocaisVirtuais
                if ($ehLocalVirtual) {
                    $tipo = 'Adaptador virtual desta máquina (WSL/Docker/Hyper-V)'
                    $categoria = 'Máquina de coleta'
                } elseif ($ehLocal) {
                    $tipo = "Máquina que executou a coleta ($env:COMPUTERNAME)"
                    $categoria = 'Máquina de coleta'
                }

                $acessos = @($portasHost | ForEach-Object { Get-UrlPorta -Ip $ip -Porta $_ } | Where-Object { $_ })
                [pscustomobject]@{
                    IP = $ip; NomeDNS = $nome; NetBIOS = $netbios; MAC = $macs[$ip]; Fabricante = $fabricante
                    Origem = if ($ehLocal) { 'Esta máquina' } else { 'Rede' }
                    Gateway = [bool]($ip -in $gateways)
                    ServidorDhcp = [bool]($ip -in @($script:ServidorDhcp -split ',\s*' | Where-Object { $_ }))
                    TipoProvavel = $tipo; Categoria = $categoria; SOProvavel = $soProvavel
                    RespondePing = [bool]$ping; LatenciaMs = if ($ping) { $ping.LatenciaMs } else { $null }; TTL = if ($ping) { $ping.Ttl } else { $null }
                    QtdPortas = $portasHost.Count
                    Portas = $portasHost
                    PortasAbertas = ($portasHost | ForEach-Object { "$_ $($RotuloPortas[$_])".Trim() }) -join ', '
                    Acessos = $acessos -join ' '
                    Banners = $banners -join ' | '
                    TLS = ($tlsHost | ForEach-Object { "$($_.Porta): $($_.ProtocolosAceitos)" }) -join ' | '
                    Compartilhamentos = ($compartilhados | ForEach-Object { $_.Nome }) -join ', '
                    TituloWeb = if ($web) { $web.Titulo } else { '' }; ServidorWeb = if ($web) { $web.Servidor } else { '' }
                    NoAD = if ($adPorIp.ContainsKey($ip)) { $true } elseif ($nomeCurto -and $nomesAD.Count -gt 0) { $nomeCurto -in $nomesAD } else { $null }
                }
            })
        }
        finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $validacaoOriginal
        }
        Save-Dados 'rede_dispositivos' ($script:Hosts | Select-Object * -ExcludeProperty Portas) 'Dispositivos encontrados: nome, MAC, fabricante, SO provável, portas, links de acesso, compartilhamentos e tipo'
        Save-Dados 'rede_portas_abertas' ($abertas | Select-Object Ip, Porta, @{ n = 'Servico'; e = { $RotuloPortas[$_.Porta] } }) 'Uma linha por porta aberta encontrada'
        Save-Dados 'rede_compartilhamentos' $compartilhamentosRede 'Pastas e impressoras compartilhadas em todos os dispositivos da rede'
        $script:CompartilhamentosRede = $compartilhamentosRede.ToArray()
        Save-Dados 'rede_tls' $listaTls 'TLS por serviço: versões aceitas, certificado, emissor e validade (REQ-024)'
        $script:Tls = $listaTls.ToArray()

        foreach ($t in $script:Tls | Where-Object { $_.ProtocoloObsoleto }) {
            Add-Alerta 'Média' 'Criptografia' "Protocolo TLS obsoleto em $($t.IP):$($t.Porta)" "Aceita $($t.ProtocoloObsoleto); o Provimento 213 exige TLS 1.2 ou superior (REQ-024)"
        }
        foreach ($t in $script:Tls | Where-Object { $null -ne $_.DiasParaVencer -and $_.DiasParaVencer -lt 0 }) {
            Add-Alerta 'Média' 'Criptografia' "Certificado vencido em $($t.IP):$($t.Porta)" "Venceu em $($t.CertificadoValidoAte)"
        }
        foreach ($t in $script:Tls | Where-Object { $null -ne $_.DiasParaVencer -and $_.DiasParaVencer -ge 0 -and $_.DiasParaVencer -le 30 }) {
            Add-Alerta 'Média' 'Criptografia' "Certificado vencendo em $($t.IP):$($t.Porta)" "Vence em $($t.DiasParaVencer) dias ($($t.CertificadoValidoAte))"
        }
        $autoassinados = @($script:Tls | Where-Object { $_.AutoAssinado })
        if ($autoassinados.Count -gt 0) {
            Add-Alerta 'Info' 'Criptografia' "$($autoassinados.Count) serviço(s) com certificado autoassinado" ((($autoassinados | ForEach-Object { "$($_.IP):$($_.Porta)" }) -join ', ') + ' | comum em painel de equipamento, registrar como aceito ou substituir')
        }

        # Segmentação: equipamento de uso público na mesma sub-rede dos servidores é rede plana (REQ-034).
        $porSubrede = @($script:Hosts | Group-Object { ($_.IP -replace '\.\d+$', '') })
        $sensiveis = 'Servidores', 'NAS', 'Gerência (iDRAC/iLO)'
        $publicos  = 'Câmeras/DVR', 'Móveis/Wi-Fi', 'Ponto/Acesso', 'Telefonia', 'IoT / TV / assistente'
        $planas = @(foreach ($g in $porSubrede) {
            $cats = @($g.Group.Categoria | Select-Object -Unique)
            if ((@($cats | Where-Object { $_ -in $sensiveis }).Count -gt 0) -and (@($cats | Where-Object { $_ -in $publicos }).Count -gt 0)) {
                "$($g.Name).0/24 ($(($cats | Where-Object { $_ -in ($sensiveis + $publicos) }) -join ' + '))"
            }
        })
        $script:Resumo['Sub-redes com dispositivos'] = "$($porSubrede.Count): " + (($porSubrede | ForEach-Object { "$($_.Name).0/24 ($($_.Count))" }) -join ', ')
        if ($planas.Count -gt 0) {
            $script:Resumo['Segmentação de rede'] = 'Rede plana: ' + ($planas -join '; ')
            Add-Alerta 'Média' 'Rede' 'Rede plana (sem segmentação)' (($planas -join '; ') + ' | câmera, celular ou telefonia na mesma rede dos servidores; exigida VLAN ou equivalente (REQ-034)')
        } elseif ($porSubrede.Count -gt 1) {
            $script:Resumo['Segmentação de rede'] = "Há $($porSubrede.Count) sub-redes; confirmar no switch se é VLAN de verdade"
        } else {
            $script:Resumo['Segmentação de rede'] = 'Sub-rede única; sem equipamento de uso público detectado junto dos servidores'
        }

        $resumoTipos = ($script:Hosts | Group-Object Categoria | Sort-Object Count -Descending | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ' | '
        foreach ($h in $script:Hosts | Where-Object { $_.PortasAbertas -match '(^|, )(27017|9200) ' }) { Add-Alerta 'Média' 'Rede' "Banco MongoDB/Elasticsearch acessível em $($h.IP)" 'Costumam vir sem autenticação; restringir acesso' }
        $remotos = @($script:Hosts | Where-Object { $_.PortasAbertas -match '(^|, )(5938|7070|4899) ' })
        if ($remotos.Count -gt 0) { Add-Alerta 'Info' 'Rede' "$($remotos.Count) dispositivo(s) com acesso remoto em escuta (TeamViewer/AnyDesk/Radmin)" (($remotos | ForEach-Object { "$($_.IP) $($_.NomeDNS)" }) -join ', ') }
        $estacoesComShare = @($script:Hosts | Where-Object { $_.Compartilhamentos -and $_.Categoria -eq 'Estações' })
        if ($estacoesComShare.Count -gt 0) { Add-Alerta 'Baixa' 'Arquivos' "$($estacoesComShare.Count) estação(ões) com pastas compartilhadas" ((($estacoesComShare | ForEach-Object { "$($_.IP) [$($_.Compartilhamentos)]" }) -join '; ') + ' | Dados fora do servidor ficam sem backup e controle de acesso') }
        $bmc = @($script:Hosts | Where-Object { $_.Categoria -eq 'Gerência (iDRAC/iLO)' })
        if ($bmc.Count -gt 0) {
            Add-Alerta 'Média' 'Rede' "$($bmc.Count) controladora(s) de gerência fora de banda na rede de produção" ((($bmc | ForEach-Object { "$($_.IP) $($_.Fabricante)" }) -join ', ') + ' | iDRAC/iLO/IPMI dá controle total do servidor; deve ficar em rede isolada e com senha trocada')
        }
        $aleatorios = @($script:Hosts | Where-Object { $_.Fabricante -like 'MAC aleatório*' })
        if ($aleatorios.Count -gt 0) { Add-Alerta 'Info' 'Rede' "$($aleatorios.Count) dispositivo(s) com MAC aleatório" 'Celulares/notebooks pessoais na mesma rede dos computadores; avaliar rede de visitantes separada' }
        $script:Resumo['Dispositivos na rede'] = "$($script:Hosts.Count) ativos | $resumoTipos"
        foreach ($h in $script:Hosts | Where-Object { $_.PortasAbertas -match '(^|, )(21|23) ' }) { Add-Alerta 'Média' 'Rede' "Telnet/FTP aberto em $($h.IP)" "$($h.NomeDNS) $($h.TituloWeb) | $($h.PortasAbertas)" }
        foreach ($h in $script:Hosts | Where-Object { $_.PortasAbertas -match '(^|, )5900 ' }) { Add-Alerta 'Média' 'Rede' "VNC aberto em $($h.IP)" "$($h.NomeDNS) $($h.TituloWeb)" }
        $foraAD = @($script:Hosts | Where-Object { $_.TipoProvavel -eq 'Computador Windows' -and $_.NoAD -eq $false })
        if ($foraAD.Count -gt 0) { Add-Alerta 'Baixa' 'Rede' "$($foraAD.Count) Windows possivelmente fora do domínio" (($foraAD | ForEach-Object { "$($_.IP) $($_.NomeDNS)" }) -join ', ') }
        $naoIdentificados = @($script:Hosts | Where-Object { $_.TipoProvavel -eq 'Não identificado' })
        if ($naoIdentificados.Count -gt 0) { Add-Alerta 'Info' 'Rede' "$($naoIdentificados.Count) dispositivo(s) não identificado(s)" 'Identificar pelo MAC (fabricante) e no local' }
    }
}

# ============================================================================
# 4. Inventário remoto das estações
# ============================================================================

function Get-InventarioRemoto {
    param([string]$Computador, [switch]$Local)
    $sessao = $null
    # Credencial única da pré-validação. Na própria máquina não se usa: o Windows recusa credencial explícita em conexão local.
    $usarCredencial = $CredencialRemota -and -not $Local
    $negou = $false
    # Mensagens de credencial recusada (inglês e português). Distingue "a conta não entra" de "máquina desligada".
    $regexRecusa = '(?i)access is denied|acesso negado|0x80070005|unauthorized|logon failure|0x8007052e|user name or password|nome de usu.rio ou senha|senha incorret|bad password'
    foreach ($protocolo in 'Wsman', 'Dcom') {
        try {
            $parametrosSessao = @{ ComputerName = $Computador; SessionOption = (New-CimSessionOption -Protocol $protocolo); OperationTimeoutSec = 20; ErrorAction = 'Stop' }
            if ($usarCredencial) { $parametrosSessao.Credential = $CredencialRemota }
            $sessao = New-CimSession @parametrosSessao
            Get-CimInstance -CimSession $sessao -ClassName Win32_OperatingSystem -Property Caption -ErrorAction Stop | Out-Null
            break
        } catch {
            if ("$($_.Exception.Message)" -match $regexRecusa) { $negou = $true }
            if ($sessao) { Remove-CimSession -CimSession $sessao -ErrorAction SilentlyContinue }
            $sessao = $null
        }
    }
    if (-not $sessao) {
        if ($negou) { return [pscustomobject]@{ Computador = $Computador; Status = 'Credencial recusada (acesso negado)' } }
        return [pscustomobject]@{ Computador = $Computador; Status = 'Sem acesso (WinRM e DCOM)' }
    }
    try {
        $cs    = Get-CimInstance -CimSession $sessao -ClassName Win32_ComputerSystem
        $bios  = Get-CimInstance -CimSession $sessao -ClassName Win32_BIOS
        $so    = Get-CimInstance -CimSession $sessao -ClassName Win32_OperatingSystem
        $cpu   = Get-CimInstance -CimSession $sessao -ClassName Win32_Processor | Select-Object -First 1
        $disco = Get-CimInstance -CimSession $sessao -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
        $av = try { (Get-CimInstance -CimSession $sessao -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop).displayName -join '; ' } catch { '' }
        if (-not $av) {
            # Windows Server não tem Security Center: identifica o antivírus pelos serviços em execução,
            # senão todo servidor cai como "sem antivírus" mesmo com Acronis, Kaspersky ou ESET rodando.
            $regexAv = '(?i)Acronis (Active Protection|Cyber Protection)|Kaspersky|\bESET\b|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|\bAVG\b|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|^WinDefend$'
            $av = try {
                (Get-CimInstance -CimSession $sessao -ClassName Win32_Service -Filter "State='Running'" -ErrorAction Stop |
                    Where-Object { $_.DisplayName -match $regexAv -or $_.Name -match $regexAv } |
                    ForEach-Object { $_.DisplayName } | Select-Object -Unique -First 3) -join '; '
            } catch { '' }
            if (-not $av) { $av = 'N/D' }
        }
        $midia = try {
            (Get-CimInstance -CimSession $sessao -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
                ForEach-Object { switch ([int]$_.MediaType) { 3 { 'HDD' } 4 { 'SSD' } default { 'Não informado' } } }) -join '; '
        } catch { '' }

        # Criptografia em repouso por volume (REQ-025).
        $bitlocker = try {
            (Get-CimInstance -CimSession $sessao -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
                ForEach-Object {
                    $st = switch ([int]$_.ProtectionStatus) { 0 { 'desprotegido' } 1 { 'protegido' } default { 'desconhecido' } }
                    "$($_.DriveLetter) $st"
                }) -join '; '
        } catch { 'N/D' }

        # Estado do Defender: tempo real ligado e idade das assinaturas (REQ-021 e AV.9 do checklist).
        $tempoReal = $null; $assinatura = $null
        try {
            $mp = Get-CimInstance -CimSession $sessao -Namespace 'root\Microsoft\Windows\Defender' -ClassName MSFT_MpComputerStatus -ErrorAction Stop
            $tempoReal = $mp.RealTimeProtectionEnabled
            $assinatura = $mp.AntivirusSignatureLastUpdated
        } catch { }

        # Data do último patch aplicado (REQ-042).
        $ultimoPatch = try {
            (Get-CimInstance -CimSession $sessao -ClassName Win32_QuickFixEngineering -ErrorAction Stop |
                Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn
        } catch { $null }

        # Quem é administrador local (CRIT-005-02). O nome do grupo é traduzido, então busca pelo SID.
        $admins = try {
            $grupo = Get-CimInstance -CimSession $sessao -ClassName Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction Stop | Select-Object -First 1
            if ($grupo) {
                $consulta = "ASSOCIATORS OF {Win32_Group.Domain='$($grupo.Domain)',Name='$($grupo.Name)'} WHERE AssocClass=Win32_GroupUser Role=GroupComponent"
                (Get-CimInstance -CimSession $sessao -Query $consulta -ErrorAction Stop | ForEach-Object { "$($_.Domain)\$($_.Name)" }) -join '; '
            } else { '' }
        } catch { 'N/D' }

        # Software instalado por estação (HD.5). Uma chamada só via WinRM, porque ler o registro remoto
        # item a item pelo CIM levaria centenas de idas e vindas por máquina.
        $qtdSoftware = $null
        if ($SoftwareEstacoes) {
            try {
                # Limite para abrir a sessão e para a consulta: estação com WinRM meio quebrado não segura a coleta.
                $paramIc = @{ ComputerName = $Computador; ErrorAction = 'Stop'; SessionOption = (New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 60000) }
                if ($usarCredencial) { $paramIc.Credential = $CredencialRemota }
                $lista = @(Invoke-Command @paramIc -ScriptBlock {
                    $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
                        Select-Object @{ n = 'Nome'; e = { $_.DisplayName.Trim() } },
                                      @{ n = 'Versao'; e = { $_.DisplayVersion } },
                                      @{ n = 'Fabricante'; e = { $_.Publisher } } |
                        Sort-Object Nome, Versao -Unique
                })
                foreach ($s in $lista) {
                    $script:SoftwaresEstacoes.Add([pscustomobject]@{
                        Computador = $Computador; Nome = $s.Nome; Versao = $s.Versao; Fabricante = $s.Fabricante
                    })
                }
                $qtdSoftware = $lista.Count
            } catch {
                Write-Log "  Software de $Computador não coletado (WinRM indisponível): $($_.Exception.Message)" 'AVISO'
            }
        }

        [pscustomobject]@{
            Computador = $Computador; Status = 'OK'; Fabricante = $cs.Manufacturer; Modelo = $cs.Model; NumeroSerie = $bios.SerialNumber
            QtdSoftwares = $qtdSoftware
            SO = $so.Caption; Build = $so.BuildNumber; Suporte = Get-SituacaoSuporte -Caption $so.Caption -Build ([int]$so.BuildNumber)
            Processador = "$($cpu.Name)".Trim(); MemoriaGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            MemoriaLivreGB = if ($so.FreePhysicalMemory) { [math]::Round($so.FreePhysicalMemory / 1MB, 1) } else { $null }
            DiscoCGB = [math]::Round($disco.Size / 1GB, 0); LivreCPct = if ($disco.Size) { [math]::Round($disco.FreeSpace / $disco.Size * 100, 0) } else { $null }
            TipoDisco = $midia; Antivirus = $av
            DefenderTempoReal = $tempoReal
            AssinaturaAV = Format-Data $assinatura
            DiasAssinaturaAV = if ($assinatura) { [int]((Get-Date) - $assinatura).TotalDays } else { $null }
            BitLocker = $bitlocker
            UltimoPatch = Format-Data $ultimoPatch
            DiasSemPatch = if ($ultimoPatch) { [int]((Get-Date) - $ultimoPatch).TotalDays } else { $null }
            AdministradoresLocais = $admins
            UsuarioLogado = $cs.UserName
            UltimoBoot = Format-Data $so.LastBootUpTime; InstaladoEm = Format-Data $so.InstallDate
        }
    }
    catch {
        $status = if ("$($_.Exception.Message)" -match $regexRecusa) { 'Credencial recusada (acesso negado)' } else { "Erro: $($_.Exception.Message)" }
        [pscustomobject]@{ Computador = $Computador; Status = $status }
    }
    finally { Remove-CimSession -CimSession $sessao -ErrorAction SilentlyContinue }
}

Write-Secao 'Estações do domínio'
if ($SemInventarioRemoto) { Write-Log 'Ignorado (-SemInventarioRemoto).' }
elseif (-not $temAD) { Write-Log 'Ignorado: sem acesso ao Active Directory.' }
elseif ($script:ComputadoresAD.Count -eq 0) { Write-Log 'Nenhum computador encontrado no Active Directory.' }
if (-not $SemInventarioRemoto -and $temAD -and $script:ComputadoresAD.Count -gt 0) {
    Invoke-Etapa 'Inventário das estações e servidores do domínio' {
        $limite = (Get-Date).AddDays(-60)
        $candidatos = @($script:ComputadoresAD | Where-Object { $_.Habilitado -and ($_.UltimoLogon -ge $limite -or -not $_.UltimoLogon) })

        # Coleta local por GPO (Nextec-Assessment-Estacao.ps1): cada estação grava um .json no compartilhamento.
        # Quem tem arquivo recente dispensa a consulta remota, então firewall e máquina desligada deixam de importar.
        $resultados = @{}
        if (-not $PastaEstacoes) {
            try { $compartilhamento = Get-SmbShare -Name 'Assessment$' -ErrorAction Stop; $PastaEstacoes = Join-Path $compartilhamento.Path 'Estacoes' } catch { }
        }
        if ($PastaEstacoes -and (Test-Path -LiteralPath $PastaEstacoes)) {
            $validade = (Get-Date).AddDays(-$DiasValidadeColetaLocal)
            $arquivosLocais = @(Get-ChildItem -LiteralPath $PastaEstacoes -Filter '*.json' -File -ErrorAction SilentlyContinue)
            $antigos = 0; $invalidos = 0
            foreach ($arq in $arquivosLocais) {
                $nomeMaq = [IO.Path]::GetFileNameWithoutExtension($arq.Name).ToUpper()
                if ($nomeMaq -eq $env:COMPUTERNAME.ToUpper()) { continue }
                $colunasNumericas = 'MemoriaGB', 'MemoriaLivreGB', 'DiscoCGB', 'LivreCPct', 'DiasSemPatch', 'DiasAssinaturaAV', 'TelasAzuis30d', 'DesligamentosInesperados30d', 'ErrosCriticos30d', 'ErrosSistema30d', 'LogonsFalha7d', 'DadosLocaisGB', 'Minidumps'
                $cand = $candidatos | Where-Object { $_.Nome.ToUpper() -eq $nomeMaq } | Select-Object -First 1
                if (-not $cand) { continue }
                if ($arq.LastWriteTime -lt $validade) { $antigos++; continue }
                if ($arq.Length -gt 10MB) { $invalidos++; Write-Log "  Coleta local de $nomeMaq recusada: arquivo acima de 10 MB" 'AVISO'; continue }
                try {
                    $j = Get-Content -LiteralPath $arq.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    $h = [ordered]@{}
                    foreach ($prop in $j.PSObject.Properties) {
                        if ($prop.Name -in 'Softwares', 'Detalhes') { continue }
                        $h[$prop.Name] = if ($prop.Name -in $colunasNumericas -or $prop.Name -like 'Qtd*') { ConvertTo-NumeroOuNulo $prop.Value } else { $prop.Value }
                    }
                    $h['Computador'] = $cand.Nome
                    $h['Suporte'] = Get-SituacaoSuporte -Caption "$($j.SO)" -Build ([int]$j.Build)
                    $resultados[$cand.Nome] = [pscustomobject]$h
                    Add-DetalhesEstacao $j.Detalhes $cand.Nome
                    foreach ($sw in @($j.Softwares)) {
                        if ($sw.Nome) { $script:SoftwaresEstacoes.Add([pscustomobject]@{ Computador = $cand.Nome; Nome = $sw.Nome; Versao = $sw.Versao; Fabricante = $sw.Fabricante }) }
                    }
                } catch { $invalidos++; Write-Log "  Coleta local de $nomeMaq ilegível: $($_.Exception.Message)" 'AVISO' }
            }
            Write-Log "  Coleta local por GPO: $($resultados.Count) de $($candidatos.Count) estações com arquivo recente em $PastaEstacoes$(if ($antigos) { "; $antigos antigo(s) ignorado(s) (mais de $DiasValidadeColetaLocal dias)" })$(if ($invalidos) { "; $invalidos ilegível(is)" })"
            $script:Resumo['Coleta local por GPO'] = "$($resultados.Count) de $($candidatos.Count) computadores (arquivos de até $DiasValidadeColetaLocal dias)"
        } else {
            $script:Resumo['Coleta local por GPO'] = 'Não configurada (sem pasta de estações); inventário só por consulta remota'
        }
        $remotos = @($candidatos | Where-Object { -not $resultados.ContainsKey($_.Nome) })
        # Inventário em paralelo (runspaces). Sequencial, cada máquina sem acesso custava ~40 s de timeout
        # de DCOM; com 20 estações eram 14 minutos. Em paralelo cai para o tempo das mais lentas.
        Write-Log "  $($candidatos.Count) computador(es) candidatos; $($remotos.Count) por consulta remota, até $Paralelismo em paralelo."
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($nomeFn in 'Get-SituacaoSuporte', 'Format-Data', 'Test-PortaRapida', 'Get-InventarioRemoto') {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($nomeFn, (Get-Command $nomeFn).Definition)))
        }
        # Dentro do runspace o Write-Log só acumula; o log de verdade é escrito aqui fora, em ordem.
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry('Write-Log', 'param($Mensagem, $Nivel = "INFO") [void]$global:Mensagens.Add([pscustomobject]@{ Nivel = $Nivel; Texto = "$Mensagem".Trim() })')))
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('SoftwareEstacoes', [bool]$SoftwareEstacoes, '')))
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('CredencialRemota', $script:CredencialRemota, '')))
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Paralelismo, $iss, $Host)
        $pool.Open()
        $bloco = {
            param($Nome, $Alvo, $EhLocal)
            # Listas zeradas a cada máquina, porque o pool reaproveita runspaces.
            $global:Mensagens = New-Object System.Collections.Generic.List[object]
            $script:SoftwaresEstacoes = New-Object System.Collections.Generic.List[object]
            $global:SoftwaresEstacoes = $script:SoftwaresEstacoes
            $inicio = Get-Date
            $alcancavel = $EhLocal -or (Test-PortaRapida $Alvo 5985 800) -or (Test-PortaRapida $Alvo 135 800)
            $inv = if (-not $alcancavel) { [pscustomobject]@{ Computador = $Nome; Status = 'Desligado ou inacessível' } }
                   else { Get-InventarioRemoto -Computador $Alvo -Local:$EhLocal }
            [pscustomobject]@{
                Nome = $Nome; Inventario = $inv
                Softwares = $script:SoftwaresEstacoes.ToArray(); Mensagens = $global:Mensagens.ToArray()
                Segundos = [int]((Get-Date) - $inicio).TotalSeconds
            }
        }
        $trabalhos = New-Object System.Collections.Generic.List[object]
        foreach ($c in $remotos) {
            $alvo = if ($c.DNS) { $c.DNS } else { $c.Nome }
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($bloco).AddArgument($c.Nome).AddArgument($alvo).AddArgument(($c.Nome -eq $env:COMPUTERNAME))
            $trabalhos.Add([pscustomobject]@{ Nome = $c.Nome; PS = $ps; Handle = $ps.BeginInvoke(); Lido = $false })
        }
        $ultimoAviso = Get-Date
        $inicioParalelo = Get-Date
        $prazoParalelo = [int][math]::Max(600, [math]::Ceiling($remotos.Count / $Paralelismo) * 120)
        $abandonados = 0
        while (@($trabalhos | Where-Object { -not $_.Lido }).Count -gt 0) {
            foreach ($t in @($trabalhos | Where-Object { -not $_.Lido -and $_.Handle.IsCompleted })) {
                try {
                    $r = $t.PS.EndInvoke($t.Handle) | Select-Object -First 1
                    if ($r) {
                        $resultados[$t.Nome] = $r.Inventario
                        foreach ($s in @($r.Softwares)) { $script:SoftwaresEstacoes.Add($s) }
                        foreach ($m in @($r.Mensagens)) {
                            $nivel = if ($m.Nivel -in 'INFO', 'AVISO', 'ERRO') { $m.Nivel } else { 'INFO' }
                            Write-Log "  [$($t.Nome)] $($m.Texto)" $nivel
                        }
                        Write-Log "  $($t.Nome): $($r.Inventario.Status) ($($r.Segundos) s)"
                    } else {
                        $resultados[$t.Nome] = [pscustomobject]@{ Computador = $t.Nome; Status = 'Erro: sem retorno do runspace' }
                    }
                } catch {
                    $resultados[$t.Nome] = [pscustomobject]@{ Computador = $t.Nome; Status = "Erro: $($_.Exception.Message)" }
                    Write-Log "  $($t.Nome): erro no inventário paralelo: $($_.Exception.Message)" 'AVISO'
                } finally { $t.PS.Dispose(); $t.Lido = $true }
            }
            if (((Get-Date) - $ultimoAviso).TotalSeconds -ge 15) {
                Write-Log "  ... $($resultados.Count) de $($candidatos.Count) concluídos"
                $ultimoAviso = Get-Date
            }
            $abandonados += Stop-TrabalhosVencidos $trabalhos $resultados $inicioParalelo $prazoParalelo
            Start-Sleep -Milliseconds 400
        }
        # Com consulta abandonada, Close() ficaria esperando justamente o que travou.
        if ($abandonados) {
            Write-Log "  $abandonados computador(es) abandonado(s) depois de $prazoParalelo s sem resposta" 'AVISO'
            [void]$pool.BeginClose($null, $null)
        } else { $pool.Close(); $pool.Dispose() }
        $script:Estacoes = @(foreach ($c in $candidatos) { if ($resultados.ContainsKey($c.Nome)) { $resultados[$c.Nome] } })
        $colunasInventario = @($script:Estacoes | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        if ($colunasInventario.Count -gt 0) { $script:Estacoes = @($script:Estacoes | Select-Object -Property $colunasInventario) }
        Save-Dados 'inventario_computadores' $script:Estacoes 'Inventário das estações: hardware, SO, criptografia, antivírus, patch e administradores locais'
        Save-DetalhesEstacoes
        $ok = @($script:Estacoes | Where-Object { $_.Status -eq 'OK' })
        $recusadas = @($script:Estacoes | Where-Object { $_.Status -like 'Credencial recusada*' })
        $script:Resumo['Inventário remoto'] = "$($ok.Count) de $($candidatos.Count) computadores inventariados" + $(if ($recusadas.Count -gt 0) { " | $($recusadas.Count) recusaram a credencial" } else { '' })
        if ($recusadas.Count -gt 0) {
            Add-Alerta 'Alta' 'Estações' "$($recusadas.Count) computador(es) recusaram a credencial" ((($recusadas.Computador | ForEach-Object { "$_".Split('.')[0] }) -join ', ') + " | Conta usada: $($script:Resumo['Conta usada nas estações']). Conferir se ela é administradora local nessas máquinas (domínio fora do grupo Admins. locais, UAC remoto, GPO), ou refazer a coleta com outra conta (-PedirCredencial)")
        }
        foreach ($e in $ok | Where-Object { $_.LivreCPct -ne $null -and $_.LivreCPct -lt 10 }) { Add-Alerta 'Média' 'Estações' "Pouco espaço em $($e.Computador)" "$($e.LivreCPct)% livre no C:" }
        foreach ($e in $ok | Where-Object { $null -ne $_.MemoriaGB -and $_.MemoriaGB -lt 7.5 -and $_.SO -notmatch 'Server' }) { Add-Alerta 'Baixa' 'Estações' "Pouca memória em $($e.Computador)" "$($e.MemoriaGB) GB" }
        foreach ($e in $ok | Where-Object { $_.TipoDisco -match 'HDD' -and $_.SO -notmatch 'Server' }) { Add-Alerta 'Baixa' 'Estações' "Disco mecânico (HDD) em $($e.Computador)" 'Candidato a troca por SSD' }

        Add-AlertasColetaLocal $script:Estacoes

        # Cobertura de antivírus (AV.5, AV.6 e AV.7 do checklist; REQ-021 exige 100%).
        $semAv = @($ok | Where-Object { (-not $_.Antivirus -or $_.Antivirus -in 'N/D', '') -and $_.DefenderTempoReal -ne $true })
        $cobertura = if ($ok.Count -gt 0) { [math]::Round((($ok.Count - $semAv.Count) / $ok.Count) * 100, 0) } else { 0 }
        $script:Resumo['Cobertura de antivírus'] = "$cobertura% dos inventariados ($($ok.Count - $semAv.Count) de $($ok.Count)); $($candidatos.Count - $ok.Count) de $($candidatos.Count) computadores sem inventário, cobertura real desconhecida"
        if ($semAv.Count -gt 0) {
            Add-Alerta 'Alta' 'Estações' "$($semAv.Count) computador(es) sem antivírus ativo" ((($semAv.Computador) -join ', ') + ' | REQ-021 exige proteção em 100% das estações e servidores')
        }
        # Maioria "Sem acesso" = a conta não é administradora nas estações. Sem isso o inventário não sai.
        $semAcesso = @($script:Estacoes | Where-Object { $_.Status -like 'Sem acesso*' })
        if ($semAcesso.Count -ge 3 -and $semAcesso.Count -ge ($candidatos.Count / 2)) {
            Add-Alerta 'Alta' 'Estações' "$($semAcesso.Count) de $($candidatos.Count) estações não responderam à consulta remota" "WinRM e DCOM sem resposta com a conta $($script:Resumo['Conta usada nas estações']) (tempo esgotado, não é acesso negado): firewall do Windows das estações bloqueando RPC/WMI. Liberar por GPO ou usar a coleta local por GPO (Nextec-Assessment-Estacao.ps1) para obter SO, antivírus, BitLocker, patch e administradores de cada estação"
        }
        $naoInventariados = @($script:Estacoes | Where-Object { $_.Status -ne 'OK' })
        if ($naoInventariados.Count -gt 0) {
            $hora = (Get-Date).Hour
            $dica = if ($hora -lt 8 -or $hora -ge 18 -or (Get-Date).DayOfWeek -in 'Saturday', 'Sunday') { " | Coleta às $(Get-Date -Format 'HH:mm'): fora do expediente as estações ficam desligadas. Repetir em horário comercial para inventariá-las" } else { ' | sem esses dados a cobertura não fecha 100%' }
            Add-Alerta 'Info' 'Estações' "$($naoInventariados.Count) computador(es) não inventariado(s)" ((($naoInventariados | ForEach-Object { "$($_.Computador) ($($_.Status))" }) -join ', ') + $dica)
        }

        # Assinaturas velhas: o critério do assessment é 7 dias.
        foreach ($e in $ok | Where-Object { $null -ne $_.DiasAssinaturaAV -and $_.DiasAssinaturaAV -gt 7 }) {
            Add-Alerta 'Média' 'Estações' "Assinaturas de antivírus desatualizadas em $($e.Computador)" "Última atualização há $($e.DiasAssinaturaAV) dias"
        }
        # Defender sem tempo real só é problema se não houver outro antivírus assumindo a proteção.
        foreach ($e in $ok | Where-Object { $_.DefenderTempoReal -eq $false }) {
            $outros = @(($e.Antivirus -split ';\s*') | Where-Object { $_ -and $_ -notmatch '(?i)windows defender|microsoft defender' })
            if ($outros.Count -eq 0) {
                Add-Alerta 'Alta' 'Estações' "Proteção em tempo real desligada em $($e.Computador)" 'Defender presente mas sem proteção ativa, e nenhum outro antivírus registrado'
            }
        }

        # Criptografia em repouso (REQ-025).
        $semCripto = @($ok | Where-Object { $_.BitLocker -match 'desprotegido' })
        if ($semCripto.Count -gt 0) {
            Add-Alerta 'Média' 'Criptografia' "$($semCripto.Count) computador(es) sem criptografia de disco" ((($semCripto.Computador) -join ', ') + ' | REQ-025 exige AES-256 em repouso nos equipamentos com dados críticos')
        }
        $criptoNaoLida = @($ok | Where-Object { $_.BitLocker -eq 'N/D' })
        if ($criptoNaoLida.Count -gt 0) {
            Add-Alerta 'Info' 'Criptografia' "$($criptoNaoLida.Count) computador(es) sem leitura do BitLocker" 'Consulta sem retorno: falta privilégio de administrador no equipamento ou o recurso BitLocker não está instalado (comum em Windows Server). Confirmar no próprio equipamento'
        }

        # Atualizações atrasadas (REQ-042).
        foreach ($e in $ok | Where-Object { $null -ne $_.DiasSemPatch -and $_.DiasSemPatch -gt 60 }) {
            Add-Alerta 'Média' 'Estações' "Atualizações atrasadas em $($e.Computador)" "Último patch há $($e.DiasSemPatch) dias ($($e.UltimoPatch))"
        }

        # Administrador local a mais é privilégio excessivo (CRIT-005-02).
        $adminsPorMaquina = @(foreach ($e in $ok | Where-Object { $_.AdministradoresLocais -and $_.AdministradoresLocais -ne 'N/D' }) {
            foreach ($a in ($e.AdministradoresLocais -split ';\s*')) {
                if ($a) { [pscustomobject]@{ Computador = $e.Computador; Administrador = $a } }
            }
        })
        Save-Dados 'estacoes_administradores' $adminsPorMaquina 'Quem é administrador local em cada computador do domínio'
        $excesso = @($ok | Where-Object { $_.AdministradoresLocais -and $_.AdministradoresLocais -ne 'N/D' -and (@($_.AdministradoresLocais -split ';\s*').Count -gt 3) })
        if ($excesso.Count -gt 0) {
            Add-Alerta 'Baixa' 'Estações' "$($excesso.Count) computador(es) com muitos administradores locais" ((($excesso | ForEach-Object { "$($_.Computador) ($(@($_.AdministradoresLocais -split ';\s*').Count))" }) -join ', ') + ' | aplicar privilégio mínimo')
        }

        # Software por estação (HD.5, REQ-011 e REQ-014).
        if ($script:SoftwaresEstacoes.Count -gt 0) {
            $softEstacoes = $script:SoftwaresEstacoes.ToArray()
            Save-Dados 'estacoes_softwares' $softEstacoes 'Softwares instalados em cada estação do domínio'

            $resumoSoft = @($softEstacoes | Group-Object Nome | Sort-Object Count -Descending |
                ForEach-Object { [pscustomobject]@{ Software = $_.Name; Maquinas = $_.Count; Versoes = (($_.Group.Versao | Select-Object -Unique) -join ', ') } })
            Save-Dados 'estacoes_softwares_resumo' $resumoSoft 'Cada software e em quantas máquinas está instalado, com as versões encontradas'
            $script:Resumo['Softwares distintos nas estações'] = "$($resumoSoft.Count) em $(@($softEstacoes.Computador | Select-Object -Unique).Count) computadores"

            # Versões diferentes do mesmo software indicam atualização incompleta no parque.
            $divergentes = @($resumoSoft | Where-Object { $_.Maquinas -gt 1 -and @($_.Versoes -split ',\s*').Count -gt 1 })
            if ($divergentes.Count -gt 0) {
                Add-Alerta 'Baixa' 'Estações' "$($divergentes.Count) software(s) com versões diferentes entre máquinas" ((($divergentes | Select-Object -First 8 | ForEach-Object { $_.Software }) -join ', ') + ' | padronizar versão')
            }
            $eol = @($softEstacoes | Where-Object { $_.Nome -match '(?i)Office (2007|2010|2013|2016)|Windows 7|Java 6|Java 7|Adobe Reader (X|9|8)|Firebird 2|SQL Server (2008|2012|2014)' })
            if ($eol.Count -gt 0) {
                Add-Alerta 'Alta' 'Estações' "$($eol.Count) instalação(ões) de software sem suporte nas estações" ((($eol | ForEach-Object { "$($_.Computador): $($_.Nome)" } | Select-Object -First 10) -join '; ') + ' | REQ-014 veda tecnologia sem suporte do fabricante')
            }
        }
    }
}

# ============================================================================
# 5. Relatório
# ============================================================================

Write-Secao 'Relatório'

$ordemSeveridade = @{ 'Alta' = 0; 'Média' = 1; 'Baixa' = 2; 'Info' = 3 }
$alertasOrdenados = @($script:Alertas | Sort-Object { $ordemSeveridade[$_.Severidade] }, Area)
Save-Dados 'alertas' $alertasOrdenados 'Pontos de atenção encontrados'
Save-Dados 'erros_coleta' $script:Erros 'Etapas que falharam na coleta'

$script:Resumo['Tempo de coleta'] = '{0:N0} minutos' -f ((Get-Date) - $script:Inicio).TotalMinutes
[pscustomobject]@{ Resumo = $script:Resumo; Alertas = $alertasOrdenados; Dispositivos = $script:Hosts; Computadores = $script:Estacoes; Erros = $script:Erros } |
    ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $script:PastaSaida 'resumo.json') -Encoding UTF8

# Marca da Nextec embutida em base64: o relatorio sai com identidade visual em qualquer maquina,
# sem depender de arquivo externo. Logo clara (cabecalho escuro) e emblema (favicon).
$script:LogoBase64    = 'iVBORw0KGgoAAAANSUhEUgAAAaQAAABQCAYAAABWOAGOAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAB5tSURBVHhe7Z0JuCRVdcfvfaioqBCXCEQRtwiKCoKicRmVYV5V9QMBgxHUoKKgwX2JaEAQExciKkZQAQW3ABIDBjHGGFEUxQi4EAQFxQUFAWFYZl5XL//K9+869abeeVXdVd3Vb9445/d994PprrtUv+576px7FucMwzAMw1gZrHLX3XNfh+3nXPJA/Z5hGIZhTJ3Vbv0O0UzvqMj3rox8d13k+7cEPv5o4LClvtYwDMMwGidw7ceGrn9i5Ht/fJ5PkjmfJJFPkpZPkv35/y4+VPcxDMMwjMYIHfaIfPdT1IYoiCiAQt9Z1Ph64OL36L6GYRiGMTFr3HwQ+v6XIt/r71siiNLWTfZJNaSD9BiGYRiGMRar3IV3a7negZHvfZMmOQqiyKNACG1oNNuFvjPfcskj9HiGYRiGUYtV7rZtWjPJYZHvXU5tZ6Dx+N4S4VPUeG3oO5cf45IZPa5hGIZhVCJw6x4Sut7Roe/+mtpQKlyqCaKsDc6PfOdUPbZhGIZhjCRyd20b+f77I9+7kYKI5jmeBWlhM7otnB+9WM9hGIZhGEOJXHvnlu9du99QR4VqjedLke+017j2TnoewzAMwyhllUvuFvj4YprZtHAZp6WaVXzV7i65u57LMAzDMEpZ4+Inpl5z/SXCZZxGc1/gOqfreQzDMAxjKIGLD6UQGe+8SLdu6hbueofreYzNGwAPSpJkBwAPLWt8P0mSbXVfwzA2E0LfOT0VSFq41G+pptXtRy7eVc9jbN4A+CKA25MkWVvW+D6AS5LEzL2GsdnBOKHAd36SnvssFTB1m4xzzSqX3FPPZWzeAPifpAIAfmYCyTA2Q2Zd+zGB78SSWWHiJprWOXoewwDwVS18igDwfyaQDGMzJHDxi9PA1ybOj1KBNOs6r9PzGIYJJMMwhhL67keaOz/qD2KYZt36p+l5DMMEkmFsAqxxa+8/5/DkyCXL7ggQ+vjKps6PBu7ePv7ZnEvurecxDBNIhrGCYUBq6DpHt3z/t61BdgN6qPUumnPdffS10yCa6RzZhLmO605rIvXuarnuaj2PYRATSIaxYjmG3m2fZlXVtMpqf9AoINJ/9y6IXPc5ulcTzDpsF/n+B2heq5q9u6ixvwiiTuT756x26/bQcxlGBoCvaOFTBIArdF/DMKZI6Oafm9YVWpodgUIifa+LyPfPDFy8m+4/DsxXF3l8IPK9m8rmrtIoiGR9d7Z897Q5Fz9JzzUJAO6XJMkjADx8WJNrttT9kyTxAJ4M4NUATgJwFp/OAZwD4BQAbwLwnCRZHtMigEcCeD6AdwA4DcCZAP5V/vsRAK8DsIaBo7rvMJIk2SJJkgcCuG+VNs79AriXHqescS1ck/TbSr8P4Ota+BQB4KcA7l/QP5vnbnqdVaHmBWA3AIcAeA+Az+T+Hp8DcDyAVwB4SpIsb+hCkiT3kLX9LYB3J0lyRm5tbB+V78reAB6g+xvG2AQ+Pm5U7jiawmTj70S+c+oah0fpcaoQuc6eke+eEfru+rJy46Nbd6C5pevp3Ri67genlTwVwOEA7gJw54jGa/bM+nEDAfBKAP8LoK83Og2AawAcB2D7xSuYHI4J4PUAvs116rmLAHATgH8D8DdVhIfc738AuBXAHyq0XydJsrsepwwATwTwq4JxihrX8BU+IMimf0nBNbG+5yIAdOWz0P2zNqvXOookSXYF8H4AV3J8PacGKfx+nAzgmXq8JuH4AP4FwFVV1kYA3ChCKuIDmB7TMGoR+s4FVb3bGCPEa1u+f3vk+idEbv3D9HhFtFyyuuV750W+O6Lc+PC2QSPqXRPN9N6yj7vzwXquJuFToP4BlgHgr6TPngB+oN+vgvy4D9XrGAdJj/M+ADfreeogWsLINVHAAOjp/mVIFoSRGoY8rX9X9y+DDwAABiZbClMRftNiP73eMkTjoJZRaaMvA8DXADxLjz8JAAIA/63nqguAbyVJYme3xnjs63DfwLevrysgsjObyPf+EM30jtrL3V6otoeuHUZ0jqhYbnxYS50tevOB67whcLifnmsaAHiN/tGVAeAvAexVVQsZBp+g9VrqAOAAAL/Q406CmBofrefKA+AI3W8YNB3qMTQA3qr7DYMPEVlfEUjX6GuaAsC+i1dbDICjAKzX/ScBwIk0Y+q56gDgLwB8Xo89KbK2JSZswxjKGtfZnRVYxxUUOcH0y5brvZ7eetnYsy5+ac60tqRvncb+ke/1wi3az198B9OlqkAS087bANym3xuXKpt1EWLznwoAbuC5gZ4zD013ul8Z3KQB7KLHyADwWJpEdb8yaKrL99/YAknOnyp/HnURM+xD9bxVoJbV9ENLHqZnsvMloxahi1+Zmusmc7em4GFBvcB3PsVx6T0X+u6dTcUVpS7h8QV6/dOmhkCimaiyuaoKcnZQy7uRjgl6nKYRIVJ6dgLgITQ96n5D+GaSJDN6HHEIuVBfXIac6SzanDemQBJh9B3dp2noml737BHAXNMaWxG8f34Oen7DKCT0ndOqnh+NamL2Wxs4bDnr2gc0IeiyRi0scO236PVPm6oCaVoA+BHPUPS6ikiS5Fjdf1pQExyh2Ryg+wyDThcFY9Q1//21HmNjCSSaqwB8Q18/LQBcVNV8J2bleT3GtBBNycx3xigSH/jOD5vSYiiQAh9ff6BLtgh9fHxTgi5NAwQW2lul72DabGyBRAC8QK9LA2Af3W8ZuHSYsATwCd2hDBFwj8z6iht9ZfMngFMXz54iAulafX1TDBFIJ+prpw2AD+p1aKQG1O9132kD4J/1WgxjEXMu2SH08Z11HRrKmpjVvsqxQx9/r2FBd8OB7tat9T1MmxUikAafaRlJkvzZlD3JSgFQqrUmSXIfujbrPmUA+M+sL4Dz9ftlsEQEY4IWz54iMUh1zIe1YEyXnjNJkmfr65YDmowZ86bXk6fO59o0AJ6r12MYC4SuG6ZCZDKHg6wNYplc5x2sPxQ0KOioaQU+XtislpNJBJKctVwmh9rfBPA7fU0VANxBbyi9tgwA/6j7DEPGOytJksN4sJ0kyTMArJJAxy/XcUsGcAuAP9dryqArfJ2zNZrd6pj7xJmkNDaHbuUAXiL39hppR9CVXY9VBLUJieHK+mbttTLmwwvm+74eZxh0LJCg5BfybyF/D7phvxPA9/T1wwBwXn49eQDsr6+vihQrZCwUQwB+U+dvSqQg4oIGbBhLmPXxsU2Z1SjUBmmGXOdZLdd5ZqodNSPoBgJppn2MXv9yMI5AAtChkADwqPxhfZIkWzPQlEGHus8oADxv8cpSKAwA/FFfXwaAz3Jdepw8Ei/zX7pvGQDeoMfIQ5dn3acM3gsDW/XrQzhWz1eFqpoCgB/rvsOgCU+PUQbPcQD8Pb8Xepw8FCRVzY7iXLMkmwq/hwzS1tePgt8D+c5uz+BniQnbSoJ7KTB/q/vk4fvM9qDXYxhLCHx8flMCScxq86vdrVuHrnvsqMwP1RsFHc+Punvp9S8HdQWSbDL763Hy0BVWAggrA6BQINdZHwWD7l8GNzCmi9FjFCFBwEu85DJkM7xI95sUABePm/h0WslVAXxJj1GEaKmB7l8GvQcpHPU4RQB4b0H/Vfq6Ycj6DtHjaCRd1Cm6P5GHn1ref8Zmyu7ud/cOfPyrps55aPoLfPsyjh36+MLUFLj0urotNfvFN+3t7iw1C02TOhs+AfBmPUYRAB5WJ4MCgE/rMUhVt2g6GOi+oxDz08iME2I221n3z8Og4SRJ1uq+4yImpMfoeaoyDYEkQaaVYqZontP9RwHgcRQUeiwNgB/qBwTmntPXlQFgHT3x8v1HkffwBPDLJEkO1NcYRilMkhr6DsYNiNVNznk+Rs+90Mc3NnV+RIEZ+Pgqvf7loo5AAnBdHfdWPsnqMcoAsCQGS3LUVdmgbqDjg+5fBSZa1eMVUeVpGsDLdb8JOEyPX4cpCSTm/RsJgHN136rQW02Pp6FAoZdi1odJZuU+KgHgVYtnrYZkZ/g8gKmm89pUARDms4hsLMTkusO4eQcBPEkevjjOyDyXlWgqIDZt3VRDcvHLOXbgO5eylEUTYzNDQ8v34pabLw3EnCY1BdKJuv8w6uR+Y0S+7k+Tj76uCAAf0H2rIlrSz/WYGgAn6L5FiDPFRDDpqx63LlMSSMfr/ho541mj+1aFOfoqJuuNcn2Y0qpS3BGAy8fdqFYizCqSJMlL9evLjVhEzqdFgyEa+v3lRByH+JuuLUzEdHyeZH//Mk22+pqxCFx8fHPnPN1UQ3LtI2XsJ7R87xK+1oRJkDFILd9bG830jlzl/nAffS/TpKZAerHuPwxxSR56KJxRIpBeq68rgl8+en7R/FazMVM5E6CONLXx7ESvrwg5cxjbRZ2eik08gU9JII1MESQC6XL5bPXnPaqxD/tWEUivza2r0oMLyfdbqcjmzkwTAw9HOaOkA9E2dLnPsu6zdIwIAXoHUiizXMiO4lzEM7WBWZPlPSRT+aK9JUmSbVVsHOfZJfs+SL9Qb8qyvijvPCTlSg4WB5HCgHIAjwfQ0uNliDBoSSaUB+msJHK/s/lzO8l4v5om2CyRsayB1hxeP/hc5PV7JUmyUxZbyN+ZzPfEbDzJnvI0KUvC/3JNg0wcRXNVJnLtAyiQmhAYbK1B8Gr3psB1F57MItc5vOX7106S3XvD+As58a5uud5I81BT1BRIpe7HZXCj0eMUUSKQRppvlgtm49brK0N+xGPBH4gebxymJJAu0/03FsxnmFtXJVOpxDE1Wk+saQC8iA80zIIh7vKHyiZJoXMFz8/kTPOtkgfxZjkTe7cIMZYw+a5ogiyZQjPj1XQyknIgCx6KsrkzHVW24TJhMefmRv5pyczPMh18SBrkd5RQCpY/YTonhkS8PnMQkhAQrvt7FAT5++IZnNwPNSj+d5EWLTXM6IHKcdmfAuW03PvbyesM2+DDCwUFTfqck+PxvlmGhems9pF10+zGcQbB3aJ9c+28huZFll3hZ8L7PFlMv+8Vr95LmR1eruHaKCD5sJSf6yH5exhJ4OZfHfne9ePXJVoqNNLW+0Lk4l05xyp33T1bvv+u0PdvTZOwTnJmtaEOUui73w5dd2iSzyaoKZCeqvuPYkKB9El93cYCwE/qPBUB+Cc9xihoEtPjjEvTAkk2xUqu2csBnRhyaztSv1+EbDy1CjMuJ7LpMrnvIARCUiDx3zsDuF4KGjJlE2uYsd4VN9ATst9O5pIvcWTUWF4obukDjRvAh8QbdGCyFI2IcVcDrVGECV3dqR0wNGFQlFNCPJieiq7wrIv2EnGPp6ZwIB8IxES2jYxDYXZ+7r4Yq0fBOXAMYhgFg72z7x37iaBgiADHfQyFHYVcbozd5M/IoOxHiLC9QNz2aYmhEL1YinJS0PK+tEBiIVF+Bxj2wc/lHzif3NerpBhjW2LlWGfs+fJ57itnhyyLks3FHIZfzNZXmcDd8aBopvfOyPdubkIwMc2PaDJx5PufbLn5weHqrLtru8h3P8HKs5POQVfw1ByIJHL9c2Zde2xvq1HUFEhP0/1HsRkLpEP0GKOoUpOpKlMSSCPP2pYLfjeytTFrvH6/CHn6L8x4sRKQ4oEMq2AhSG5+3HCpnfBpnk/yA61CNCMKDGYKYSXeC/m6CAcGp2eVhPm0z8BnjsdaUAxep4fiQjosCYCmRkXTFjdrxv2xcOXHc9dQo+A6WHTx59nrufdZGfqXYj7kuikYLsq9z82e2s95onWwUdMYeBYDeLq8v1ByR1zqz87+La+9TDSoj8s6KVQWLAoigCmIXiDX0fTHdQ3O5wE8QR6qXir3syg3omhxl+dfk/FYDZvHAvm5aBb8TfZZ14aF9gIffzjyvTtSTWa8kuJZYyE/KUtxR+T7J6xydwzsoi3XXR357m008ek+dRvXyAzjoe9c33LrSjMZTMIKF0in6+s2FnUEkjzR1gl+HSCu3k/Q443DlATS1JK41iWvIQF4u36/CNmEVmy5CJ7JSHwUNRDm5ON5Dp/eufnSTJQ96dMLjBoEBRI1pMHmLxsxN+CBJ6xspBQyj5fxniRnKAtOHaKdUNjRDHaW9KNGxLIdg7LyogHxs6PGRvPgoFCnaFBPpWYjAmZnmYemsYWzKTm/4jktM3Q8VO6J95YJTmqG9JwcuNKLBnJtPhREhAt/V9RQmKuQwoMCe+HBJEmSL4jQowC/Ws5zue6B5584O/A3xjXTFDfIoSmpyZjJhaY5VscenF2JRsUHBJoyWSttUOkhN9c35P/Hd5KJXHvn0PdPj3wfTQiN7Oyn5Xs3B647CBgNffvkpgJy6YVHD781rj2n76UJVrhAqhxbMm2kouvILx6fuqrecxFip66U1XoYUxJIlfP2TRsAx+XWdph+vwiauUbFk21spNAhN+OPicbB87EtuKFneQVlo2T6K26kPGPivVFLpIbEc53B90c2b5a6Z00ppm6iZrIkFyCT1spH9Az5NwPb6WBCrYBmPArJgfYuZkP+m5oQN3XWJqNg5NkQs56fJFlQdsrGF9MgzXg872H5ePZdFDQtZ2IUdnyP66Ug+GzufVapptmPmhP/y/MyaorUAKnhcb3UmOj8sZ/EQPI7e5yUueG41Hayz41psRhSQsHC86Z/l98utUPeFwXQ4MxUBFl+LjpQ0XFpJ8Y/UkvN38tY0C285Xu9SQvrZS2NU+r8igX8Qh9/qCkPP2pJg+J9bt3As6ZpVrJAqno2sBzwR6bXV0QTQpQHrHrcujQtkEgTJcCbghtYbl2VM8FT+1h8VysP1gijgBGzED27uKEz9992fF+0mjlJdcSwBZqy+BnQa242b0bK5Tp8u+R1XPJQJd5m7J/XnHhGcwiTC2tHECaRFQES5l7jZk7heWTmBagRTYP3xTUuyXwiWgrPkahJ8ZxnkfAUzYtFQhdqqIlGxjMpCpiB951oU5xjcD/yOfIaevnxnCgT2Px/eoW+PzNjihA7iAkARODQW3HH3FzM+5ifi96GT8/WMza7u0vvHvj418154aWlKZ7nkm1CH3+3yUwOXOe03MFXskDKDhVHIeaCzwE4Z0qNT0+v1OvT8AlVr21c6G2lx6/DlARSpXIb8oR7ZsHn2FRjItOF76JsNB29jiL4pLz4rozNGTof8fetX1926IQQ+viWyR0Q0iYC6AKe9QS+s66pccX0VykGZhxWuECitw29iYZCU5Luu9wAePQ450ZDoIlmbGeWGgKJZ2OVDmbp3aX7F9GEhlcH8QSr7AE4rBrwMETTOEK/bmyaSC0xOnUwNmqJ5risrHHzezeZsTut+Np5G5OkpsJp8iwObBRIs66zYJ5ompUskMRUQa+gKoyVFbsJxFWVZ0yNInEXlVM15akhkOiVVSmiXQ6VR5bukLOa2jFrk0ANWa+jDNGoayVFlQDKgRYmWtqj9TWGMTbhTPsdTTkebEgt1N1r1rWPam5cphWabiXZlSyQCIB36WuLEFvwwbp/Hcps36OYZgAvgA/r+apQs7zGQbp/EWJfZwbykUhNocfpMaoiWQkWDsZHUbcWkgSYVlqfnNEwPiXfn27Kh+trDWMsAt85tynBIcGw87Mu2bHpTOABE7m6tWMlDq3CJiCQGB8x0mxHRCgdk7mrVkVcYeltQ2olh6RHj17HMCQf3Pv068Moqto6Cj7F63HKyFxgtTYmKWIWZaHnWZruX4a43BaWQB+GHBTTI4pl3yt95+QQvm6cFM2iRxfVzxIzIN2cmdesFPFiK0yVYxiVeKr7zb1C37muKYcGGecyBsmGPv4jtRp9zThNBFsl765xWekCiQD4jL5+GPL0y6qpdAFdCALMIzEKdB09XWcUB/B3+voimGuMm3m+7zCyWCaJsK9qiswExqLKraOg27AeZxQiBOjuyk2Wrq236azj4krMGJXKSGwIi/AV5uijUwU9mSRDwNdUX7oxV0r3wwDMfN+qSPYBptaha/InxfWXcSyVEDfoN+UDOw2jMnu7eJfAd3qTpfnZ0FKX7/YpkZt/Tiqcmjs/Cl33XXr9TbKJCCRu/LfrPqOQWIafSKT6WdLoocVI8qG1mkZ5ucn51jd0vzLkXGWPrL8EN1bKUE0k5UulwFxC91g9xjgAeEXB2Afr66og6WF4Lsa/Qfb3YKzNjyUwshDJsDAyfki0mh/p/stFU3kIjc2MwMUvatLxYBBzNBO/LHTtuTT+aPJxGXs0EG5ufqr57DYFgUTGffodF0lgWVpkjtHsus8wGM9RMMab9HXDYLyEHqMMiTmZmLJ0RnSV1ddOE8lJVkUoMW9aJRfwJpGS8ZXc5w1jEbOufUpT50cUGpHvtJmaKI1B6l7FdD9MLaSvrdPk/OjWwE03GeSmIpBI1ZLjTVJ0PiBuopWhGUyPkSE1VypT9Sl8HNNaEWUCSUyeV+nrp4lksC40weahuVb3nSaSUmlbvQ7DGEno1u3R8v3bJ00bRHNfmqy1F8+6+YUCWavduu1brntSy/faaRLW8eZJzYDxtxavvnk2MYHEg2s+iS4XFICLXKIl7xZdpSsh6f0X1XXJI1HlN+p+ZUj259Lx8jRhtisTSETixFjOe1nISjHodRTBlDG6/zSQM8RB5n/DqEXk0Ip853eTODNQcxGzXK/l+2evcZ2n6HlI5JJdW773Rc41jnkw1eDi9+pxm2ZTEkhEhNLUk66yjoxObyJuz1/R1w6jiofcGJ56PPhfknpFIyUIJso/N0wgEXpBsnaM7tckANaPOtMrQtLFVKpYPA6S8LTw928YZfjAtfePfP/rFCbjCqNMELV8767Q988IXGdJksIiItcNWr73HQql6nOncU2ha++nx2uaTU0gZUhOqdqODhWgK/Cr9XyEiS/1xcOgp5seo4y6OfDorqzHKEJS7lfW6DQVUyYxt9qpum8TiFPK2LnCWLJhUqFchDi0DHKcGcZIjnHJTOh6B7d87+Ks6N045rNMEEW+u7bluyfNuerBehkHui9sEczEh7R8/+oqNZnS9+O7AlezIuEYVC0TTsYUSJWqjNLzTfcdhSQ/ZPbfkSWvRyExTByrMF0PE0rqPsOQjXQrPU4ZcuZTy0OsagocEUrf1/2rUCcZqcQPfUuPMQ7i6s6YsolzOEo5g2NGeVZWQQrlvbFquiVjM2dvd8NW0cygtPgPqGWwjZPRm31SIda7kfWOAje/UN9jXFa5ZJtopvPOyPdvTscuFkxyfnSJ7j8NpARxJcZ5UqVLrx6nCJYE1n2rIlmAmV7/Oj3uKMR7i30XXLI1EiNT55yHJqZKGnQeyXB8lx6vDNm0lwR1FiEu0W8EcIUepwhJr0ONsLZAkHo0dOlmKehaUCizkmfVc7I6MFuzZJBneWrouYchJQqONucFoxLUiCLXeV3ke1dyQx/n3GZDS0uJR75z6qxLU743yayb3zHy/ZMj3+1u0Ny41rT20WDuLdqDMsbThofqSZKslqj00sZrkiTZWvcfBTfmUePL2LvrvnXh+ljiWDY0lhxm7RJurIxjYWN9F77G91i+mOWQR96TpJ1nLrMla9dN7nU3PUZVeEA+6vPKNa7pYXqMYUjePdbTYRVPFndjYDDP5M6QEtcsN8AyABMHeUoJaZYcYKXRc6UeDs9dsr8HC8Oxhs6pkuSSZaqnrnnIWSC1Rs7Jejas5XN1bl1sLFh3tmRy4OcxcY0qYzMhcLfcjxkN6G7dRGBq6lDQXajnPi3o8Rf53rlZkb9UGOEXjJPS1xrjIVkA7iGtcmCpMR1yfwu2qQufqkgGjYW16fcNozKBi0/YvwFBxJYWxOt2WFlWzzMtAtd5Ruh6r5pz2IfCVb9vGIZhbAIEDluGPm40L13gOz9l5Vc9l2EYhmGU0nLxLqHvdJvMSxf6zpl6HsMwDMMYyqyLD5rMgWGpQApc5416HsMwDMMYSui7H2oqLx3Pj5hSaJoF8QzDMIw/SRI/6+NvN1wQ75a93O0P0DMZhmEYRinMhB349m2jMh9UbYMy5MuQ0NQwDMP4E2PWdZ/N6qzjpAQqakzrE/j4RD2PYRiGYQwldJ03N3V+lCVenXXrn6nnMQzDMIyhhL5zzqQCidoVx2j5PgLXXlLV0zAMwzCGwoDYwMc/HzcglnFLaR45mvx6F5hnnWEYhjEWTO0T+m5c9/woyxsX+W4c+v7ZoevUzmBtGIZhGAuELj64TkBsrtLr+tB3Tw9cPHZGZsMwDMNYIPTdE6ucH+U0ottavv+RNa5du8CeYRiGYZQSDg2ITesZpRpR7+aW775vbzf/cD2GYRiGYUxM4DuFAbEbypX3ro9c55g1bn3jlScNwzAMY4HAd24UwTNw3c4Jol+0XO/Ncy55oO5jGIZhGI0z6+IXzPn+79NS4yyq17sidJ0j1ri199fXGoZhGMZUea6788Et110dOex5oLOyw4ZhGIZhGIZhbKb8PxtfYgTxLs4OAAAAAElFTkSuQmCC'
$script:EmblemaBase64 = 'iVBORw0KGgoAAAANSUhEUgAAADoAAABACAYAAABLAmSPAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAdpSURBVGhD3VtpqBxFEK5ab1FRiYiiIOKBByreohjU+LaPTaLRJxKIgSCC8Qh4I2LQX6L4Q0QUBPFA1CBeoAHv24BHosEYxYjGCzUaMb73Zrp7ZqS2Z7L76l1zLczzg48Q0lNbNV1VXVU9AfgfQoCdr9A9r9F9qjF6ug3JIXzNrIWAb3ZR4JZodGvmY5IswCTpYJJchEkiMXyZr591WAjJ3roVX63RbSDjyEiJNpFouqS/CwzX8OdmDebByIGqZW5X6DYvTHev38CM9G8Cw3v5842HhvhwDdG9Ct2WnoHjjevR+h2G4AIup7HQYE5SGD2i0I2SgXpaAz0VxvTnmID4IC6vcTgfRk7TGFMG7bqhymFgRh+fwVous3EQEKgOWusNjCYYMhPT+HyQy20UhiHZQeLYRsqk3IB8tN0jRoJbzGU3ChLiIyTauMxOEtP4dPMgOJzLbhTaEC4pv5smzcbhRvIMLrtREBg+RDHGDchLH5/mMS63cRBo1vkqZ6IRedg1FMwVXG6jMASjB0s0QRpnhUlxTRQQHsdlF8Kg/V6BXejjc2JJl4dpffvDMCQ7c9k5kKCE4DqN0ScK3SaF9hEBwdF8VQ1Ahfbtcm7rukdKpWOFAvvCtDugjOYPcTeqMbqPXI2vLwMFyQka3eqiu0lumnUuGqO322DbXHYuSDAnkxB+plE55utO96cGe8cQ/L0vfzYPFMRna4xWKXSuyJHS+32KSfdSB+wQl10IbQiumy7VU4Htd9j+pFtuxekQ78ZlTAYN8QKN0as9D8mXfOiFpx4VaLRPKDCncdmlINE8ledNZwprdBs1uKUU11wWQYK7TGP0cTYJUOgmyJqKGuPuDkoMH1AQHMVll8ZKSFpUYUzf941nZoDGaE1/LzgXkj0kmtUXTDIJyEN6IRqdE+CGx2tZAzSMHSrRmLxu1aNvesko1TK3kSwJ9o5FJQzMSC9PYPgi17EWtCFYVDQL9jM9Jr4iWQLDrrvyNXmZVjvLuY61QIK9a7pENBPTXXh2Afyxp0AzUtwzPCkBUWzSpIHrWAskmjfzJKKpmO7ClZQZy8RlRsrsAs3PF+fM6IWwAOI9BYZ/5JnPTE4fp20ITxQtc3NVz5AYvsR1rAUCzCmUzouk/36m851tc2Hr3gLDV6vGp4TgJq5jLaDAr7IL3rDwAw3JPgLDv8p6hj9W4qQN5gyuYy0QaB6vYqh/1t4tIN6PzuEiE7x+kqEdjJMhMKdyHWtAggLNhiKFAqdPRMENJE2geZLO1LLyyFCF7qM2hMdwTStDYPiOP+DLxahXzq4XMNIdICtwlyh03/gysbjBaWNBHdM982Hb/lzf0hiCscOobaIfKHs00A5qdL9rcNsTiWq5G6nj8YV5sSlf1kBojH6RYFYcXa65nhwKrFboPsx6Pv7jM7HX3bjvJLjLSSYdXRrtAxR/quQLTA3+XMPYPK5zJVDXrtCtL9pxcOUUus/bECwkmaplri3rLcRuHkAz0oZ/D+D6VgJduEpwt2p0UdnYzYp9AeFwB5I5JKeoC2ekkrI7DKuzZeuHQPt+GTfOSIZKDO9TYM+psqPpoPrbkoOwmVHVUHI5msYLMCurnNW+NAye4vrVAioABIbbyhwRnr7SoRJTYPhG1RcmYewqrmMtIHfzLlMuRn0nEv6iITxWoNlKRvM1eegz9gBbt6qdSLqDL0qw51aNT4HhT0sh2ZXrWAskhs9V7VFly9yqwNxS5YWlrdtgRit0HSEw/K5szUq752tgex7dRtNQfOKafPQJzQymdaO4UmijcudeaiTaX8ndqO3qoPvLFxHF4tR3NN3pxVlcx8roQLK7QvN68SzpJw2+ZHNf0OQ/k9mGsUM02oc12ti7Yr4Elya0LQLivcZrWQHd7wn6yj/+o1PTG+hLxmidALdsqiJcgzm1g9HLvQaCyxrPVI/XuJxSEBDvosEtU+jWFSvo/a0WraceUoO7dBhW5bpqpCtDjdFntPvT5QEf5+Gd/PlCmAu/7aFabjl9X0cCixwB5FKpgW8piLuFe1GcBMlOEgx93/ejd3dusP/maAjsOfzZnKA7ULOC2qneG81noDeye6v1j4LwEi65DDrwzxyN9i6N0b+ZPkTK1ALNCyUvpBNso3mChEznMlMz++5u9DIuuSraEB+p0D6qMdqs0X2pwKykXefrckGCOTNNGpMYMTPTAfOWgQyYU3jZk9/Q5YZoVatSaDcFBu9yuY2DRFO9rAN7D5fbKFDTWrWs614mDeLesk7QGEKWLuu2f3dnaWrIZTcKEsLFVdw2bZc2zYW3duSyGwWBwf1VElF6rj3M5TYOAsMP85d3PWaHt0S3tg1xvePGukHfBgkMt04ss6ai7R8ef6/A3UIlI5fbOCgYPTvf/Gdcq/W1AndNrS3SoCFbwfXTx2d/q2XXa3BXDLL6GRgkmlWTZ1y33UCN7hP671Cl68smQKDZNL5Q6O8lo/cU2EX0xSV/btZBoFlLd6BZgqE/FbrXFMSar53VGIL4eI3ulQ669RqjZzpgz+Nr/g/4D+Ez/UpApXzsAAAAAElFTkSuQmCC'

function ConvertTo-HtmlSeguro { param($Valor) [System.Net.WebUtility]::HtmlEncode("$Valor") }

function New-TabelaHtml {
    param($Linhas, [string[]]$Colunas)
    $lista = @($Linhas | ForEach-Object { $_ })
    if ($lista.Count -eq 0) { return '<p class="vazio">Nenhum registro.</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tabela"><table><thead><tr>')
    foreach ($c in $Colunas) { [void]$sb.Append("<th>$(ConvertTo-HtmlSeguro $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($l in $lista) {
        $classe = if ($l.PSObject.Properties['Severidade']) { " class=""sev-$($ordemSeveridade[$l.Severidade])""" } else { '' }
        [void]$sb.Append("<tr$classe>")
        foreach ($c in $Colunas) {
            $v = "$($l.$c)"
            # IP, MAC, data, número e valor curto não quebram linha; texto longo quebra só entre palavras.
            $curto = ($v -match '^[\d.,:/%-]+$') -or ($v -match '^\d{2}/\d{2}/\d{4}') -or ($v -in 'True', 'False') -or ($v.Length -le 12 -and $v -notmatch '\s')
            [void]$sb.Append("<td$(if ($curto) { ' class=""nw""' })>$(ConvertTo-HtmlSeguro $v)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    $sb.ToString()
}

function New-AlertasHtml {
    # Tabela de quatro colunas com texto longo não se lê. Cartão por alerta, agrupado por severidade.
    param($Alertas)
    $lista = @($Alertas | ForEach-Object { $_ })
    if ($lista.Count -eq 0) { return '<p class="vazio">Nenhum ponto de atenção.</p>' }
    $cores = @{ 'Alta' = '#c62828'; 'Média' = '#ef8c00'; 'Baixa' = '#5C50FF'; 'Info' = '#78909c' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($sev in 'Alta', 'Média', 'Baixa', 'Info') {
        $doNivel = @($lista | Where-Object { $_.Severidade -eq $sev })
        if ($doNivel.Count -eq 0) { continue }
        $cor = $cores[$sev]
        [void]$sb.Append("<h3 class='sev-titulo' style='color:$cor'>$(ConvertTo-HtmlSeguro $sev) <span class='sev-qtd' style='background:$cor'>$($doNivel.Count)</span></h3><div class='alertas'>")
        foreach ($a in $doNivel) {
            [void]$sb.Append("<div class='alerta' style='border-left-color:$cor'><div class='alerta-cab'><span class='area'>$(ConvertTo-HtmlSeguro $a.Area)</span><b>$(ConvertTo-HtmlSeguro $a.Item)</b></div>")
            if ($a.Detalhe) { [void]$sb.Append("<div class='alerta-det'>$(ConvertTo-HtmlSeguro $a.Detalhe)</div>") }
            [void]$sb.Append('</div>')
        }
        [void]$sb.Append('</div>')
    }
    $sb.ToString()
}

function New-ComputadoresHtml {
    # Dezesseis colunas não cabem em tela. Um cartão por máquina, com o que importa em destaque.
    param($Estacoes)
    $lista = @($Estacoes | ForEach-Object { $_ })
    if ($lista.Count -eq 0) { return '<p class="vazio">Sem inventário remoto (sem AD ou desativado).</p>' }
    $ok = @($lista | Where-Object { $_.Status -eq 'OK' } | Sort-Object Computador)
    $fora = @($lista | Where-Object { $_.Status -ne 'OK' } | Sort-Object Computador)
    $badge = { param($Texto, $Classe) "<span class='badge $Classe'>$(ConvertTo-HtmlSeguro $Texto)</span>" }
    $sb = New-Object System.Text.StringBuilder
    if ($ok.Count -gt 0) {
        [void]$sb.Append('<div class="pcs">')
        foreach ($e in $ok) {
            $nome = "$($e.Computador)".Split('.')[0]
            $sup = "$($e.Suporte)"
            $supClasse = if ($sup -like 'Fora de suporte*') { 'ruim' } elseif ($sup -like '*encerra em*') { 'aviso' } elseif ($sup) { 'ok' } else { 'neutro' }
            $supTexto = if ($sup -like 'Fora de suporte*') { 'SO sem suporte' } elseif ($sup -like '*encerra em*') { 'Suporte encerrando' } elseif ($sup) { 'SO suportado' } else { 'Suporte a verificar' }
            $temAv = $e.Antivirus -and $e.Antivirus -notin 'N/D', ''
            $avClasse = if ($temAv -or $e.DefenderTempoReal -eq $true) { 'ok' } else { 'ruim' }
            $avTexto = if ($temAv) { "$($e.Antivirus)" } elseif ($e.DefenderTempoReal -eq $true) { 'Defender' } else { 'Sem antivírus' }
            if ($avTexto.Length -gt 34) { $avTexto = $avTexto.Substring(0, 33) + '…' }
            $blClasse = if ("$($e.BitLocker)" -match 'desprotegido') { 'ruim' } elseif ("$($e.BitLocker)" -match 'protegido') { 'ok' } else { 'neutro' }
            $blTexto = if ("$($e.BitLocker)" -match 'desprotegido') { 'Sem BitLocker' } elseif ("$($e.BitLocker)" -match 'protegido') { 'BitLocker ativo' } else { 'BitLocker n/d' }
            $patchClasse = if ($null -ne $e.DiasSemPatch -and ($e.DiasSemPatch -as [int]) -gt 60) { 'aviso' } elseif ($null -ne $e.DiasSemPatch) { 'ok' } else { 'neutro' }
            $patchTexto = if ($null -ne $e.DiasSemPatch) { "Patch há $($e.DiasSemPatch) d" } else { 'Patch n/d' }
            $admins = @("$($e.AdministradoresLocais)" -split ';\s*' | Where-Object { $_ -and $_ -ne 'N/D' })
            [void]$sb.Append("<div class='pc'><h4>$(ConvertTo-HtmlSeguro $nome) $(& $badge 'online' 'ok')</h4>")
            [void]$sb.Append("<div class='l'><b>$(ConvertTo-HtmlSeguro $e.SO)</b> $(& $badge $supTexto $supClasse)</div>")
            [void]$sb.Append("<div class='l'>$(ConvertTo-HtmlSeguro "$($e.Fabricante) $($e.Modelo)".Trim()) &middot; série $(ConvertTo-HtmlSeguro $e.NumeroSerie)</div>")
            [void]$sb.Append("<div class='l'>RAM <b>$(ConvertTo-HtmlSeguro $e.MemoriaGB) GB</b> &middot; disco <b>$(ConvertTo-HtmlSeguro $e.TipoDisco)</b> &middot; C: <b>$(ConvertTo-HtmlSeguro $e.LivreCPct)%</b> livre</div>")
            [void]$sb.Append("<div class='l'>$(& $badge $avTexto $avClasse) $(& $badge $blTexto $blClasse) $(& $badge $patchTexto $patchClasse)</div>")
            [void]$sb.Append("<div class='l'>Admins locais: <b>$($admins.Count)</b>$(if ($admins.Count -gt 0) { " <span class='mudo'>(" + (ConvertTo-HtmlSeguro ($admins -join ', ')) + ')</span>' })</div>")
            if ($e.UsuarioLogado) { [void]$sb.Append("<div class='l'>Logado: $(ConvertTo-HtmlSeguro $e.UsuarioLogado)</div>") }
            [void]$sb.Append('</div>')
        }
        [void]$sb.Append('</div>')
    }
    $recusadasHtml = @($fora | Where-Object { $_.Status -like 'Credencial recusada*' })
    $foraHtml = @($fora | Where-Object { $_.Status -notlike 'Credencial recusada*' })
    if ($recusadasHtml.Count -gt 0) {
        [void]$sb.Append("<div class='offline' style='border-left:4px solid #c62828'><b>$($recusadasHtml.Count) recusaram a credencial</b> (conta usada: $(ConvertTo-HtmlSeguro $script:Resumo['Conta usada nas estações'])): ")
        [void]$sb.Append((($recusadasHtml | ForEach-Object { ConvertTo-HtmlSeguro "$($_.Computador)".Split('.')[0] }) -join ', '))
        [void]$sb.Append('</div>')
    }
    if ($foraHtml.Count -gt 0) {
        [void]$sb.Append("<div class='offline'><b>$($foraHtml.Count) não inventariado(s)</b> (desligado ou sem WinRM/DCOM no momento da coleta): ")
        [void]$sb.Append((($foraHtml | ForEach-Object { ConvertTo-HtmlSeguro "$($_.Computador)".Split('.')[0] }) -join ', '))
        [void]$sb.Append('</div>')
    }
    $sb.ToString()
}

function New-ChipsPortas {
    # Mostra as portas agrupadas por finalidade; as que têm serviço acessível viram link clicável.
    param($Dispositivo)
    $portas = @($Dispositivo.Portas | ForEach-Object { $_ })
    if ($portas.Count -eq 0) { return '<span class="semporta">nenhuma porta conhecida aberta</span>' }
    # Tudo numa linha corrida: a cor já diz a finalidade (legenda acima da tabela), então não repete o título do grupo.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="portas">')
    $ordem = @($script:GrupoPortas.Keys) + 'Outros'
    foreach ($g in $ordem) {
        foreach ($p in @($portas | Where-Object { (Get-GrupoPorta $_) -eq $g } | Sort-Object)) {
            $cor = if ($script:CorGrupoPorta[$g]) { $script:CorGrupoPorta[$g] } else { '#607d8b' }
            $svc = "$($RotuloPortas[$p])"
            $rot = if ($svc) { "$p&nbsp;$(ConvertTo-HtmlSeguro $svc)" } else { "$p" }
            $dica = ConvertTo-HtmlSeguro "$g - porta $p"
            $url = Get-UrlPorta -Ip $Dispositivo.IP -Porta $p
            if ($url) {
                [void]$sb.Append("<a class='chip' style='border-color:$cor;color:$cor' href='$(ConvertTo-HtmlSeguro $url)' target='_blank' rel='noopener' title='$dica | abrir $(ConvertTo-HtmlSeguro $url)'>$rot</a>")
            } else {
                [void]$sb.Append("<span class='chip chip-off' style='border-color:$cor' title='$dica'>$rot</span>")
            }
        }
    }
    [void]$sb.Append('</div>')
    $sb.ToString()
}

function New-TabelaDispositivos {
    param($Hosts)
    $lista = @($Hosts | ForEach-Object { $_ })
    if ($lista.Count -eq 0) { return '<p class="vazio">Nenhum dispositivo encontrado.</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table class="disp"><thead><tr><th>IP</th><th>Nome / MAC</th><th>Fabricante</th><th>Categoria</th><th>Sistema provável</th><th>Tipo provável</th><th>Portas abertas e serviços</th></tr></thead><tbody>')
    foreach ($d in ($lista | Sort-Object { ConvertTo-NumeroIp $_.IP })) {
        $ehLocal = $d.Origem -eq 'Esta máquina'
        $classe = if ($ehLocal) { ' class="linha-local"' } else { '' }
        $nome = if ($d.NomeDNS) { $d.NomeDNS } elseif ($d.NetBIOS) { $d.NetBIOS } else { '' }
        $tags = ''
        if ($d.Gateway) { $tags += ' <span class="tag tag-gw">gateway</span>' }
        if ($ehLocal) { $tags += ' <span class="tag tag-local">esta máquina</span>' }
        [void]$sb.Append("<tr$classe>")
        [void]$sb.Append("<td class='ip'>$(ConvertTo-HtmlSeguro $d.IP)$tags</td>")
        [void]$sb.Append("<td>$(ConvertTo-HtmlSeguro $nome)<div class='mac'>$(ConvertTo-HtmlSeguro $d.MAC)</div></td>")
        [void]$sb.Append("<td>$(ConvertTo-HtmlSeguro $d.Fabricante)</td>")
        [void]$sb.Append("<td>$(ConvertTo-HtmlSeguro $d.Categoria)</td>")
        [void]$sb.Append("<td>$(ConvertTo-HtmlSeguro $d.SOProvavel)</td>")
        [void]$sb.Append("<td>$(ConvertTo-HtmlSeguro $d.TipoProvavel)</td>")
        [void]$sb.Append("<td>$(New-ChipsPortas $d)</td>")
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $sb.ToString()
}

function ConvertTo-ValorVisao {
    # Valor com " | " é lista: cada item vira uma linha. Valor curto e estruturado não quebra.
    param($Valor)
    $v = "$Valor"
    if (-not $v) { return '<span class="mudo">n/d</span>' }
    $partes = @($v -split '\s\|\s' | Where-Object { $_ -ne '' })
    if ($partes.Count -gt 1) { return (($partes | ForEach-Object { "<span class='ln'>$(ConvertTo-HtmlSeguro $_)</span>" }) -join '') }
    ConvertTo-HtmlSeguro $v
}

function New-VisaoGeral {
    # Uma tabela de 40 linhas soltas não se lê. Agrupa por assunto em cartões.
    param($Resumo)
    $blocos = [ordered]@{
        'Identificação'      = 'Cliente|Data da coleta|Executado|Computador analisado|Papel da máquina|Usuário logado|Ritmo da varredura|Tempo de coleta'
        'Hardware'           = 'Fabricante / modelo|Service tag|BIOS|Processador|Memória|Discos|Volumes|Monitores|Scanners|Nobreak|Máquina virtual|Máquinas virtuais'
        'Sistema e licenças' = 'Sistema operacional|Situação de suporte|Instalado em|Último boot|Ativação|Última atualização|Reinicialização|Política do Windows Update|Papéis instalados|Fuso|Fonte de horário'
        'Rede'               = 'Endereços de rede|Adaptadores virtuais|Gateway|DNS configurado|Servidor DHCP|Wi-Fi|IP público|Rota de saída|Proxy|VLAN|Links de saída|Sub-redes|Segmentação|Descoberta|Dispositivos na rede|Portas verificadas|Portas TCP'
        'E-mail'             = 'Domínio de e-mail|Plataforma de e-mail|SPF|DKIM|DMARC'
        'Segurança'          = 'Firewall|Antivírus|Microsoft Defender|RDP|Secure Boot|TPM|Proteção LSA|UAC|LLMNR|BitLocker|SMB1|Assinatura SMB|Certificados ICP|Leitora de token|Cobertura dos logs|Acesso remoto instalado|Cobertura de antivírus'
        'Dados e serviços'   = 'SQL Server|Outros bancos|Compartilhamentos|Backup|Windows Server Backup|DFS|DHCP|Encaminhadores DNS|Limpeza de DNS|Monitoramento'
        'Active Directory'   = 'Domínio AD|Nível funcional|FSMO|Controladores|Lixeira do AD|Usuários do AD|Computadores do AD|Admins|Política de senha|GPOs|krbtgt|Inventário remoto|Softwares distintos'
    }
    $usadas = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="visao">')
    foreach ($titulo in $blocos.Keys) {
        $padrao = $blocos[$titulo]
        $itens = @($Resumo.Keys | Where-Object { $_ -match $padrao -and $_ -notin $usadas })
        if ($itens.Count -eq 0) { continue }
        foreach ($i in $itens) { $usadas.Add($i) }
        [void]$sb.Append("<section class='bloco'><h3>$(ConvertTo-HtmlSeguro $titulo)</h3><dl>")
        foreach ($i in $itens) {
            [void]$sb.Append("<dt>$(ConvertTo-HtmlSeguro $i)</dt><dd>$(ConvertTo-ValorVisao $Resumo[$i])</dd>")
        }
        [void]$sb.Append('</dl></section>')
    }
    $sobra = @($Resumo.Keys | Where-Object { $_ -notin $usadas })
    if ($sobra.Count -gt 0) {
        [void]$sb.Append("<section class='bloco'><h3>Outros dados</h3><dl>")
        foreach ($i in $sobra) { [void]$sb.Append("<dt>$(ConvertTo-HtmlSeguro $i)</dt><dd>$(ConvertTo-HtmlSeguro $Resumo[$i])</dd>") }
        [void]$sb.Append('</dl></section>')
    }
    [void]$sb.Append('</div>')
    $sb.ToString()
}

function New-BarrasCategoria {
    param($Hosts)
    $lista = @($Hosts | ForEach-Object { $_ })
    if ($lista.Count -eq 0) { return '<p class="vazio">Sem dispositivos na rede.</p>' }
    $grupos = $lista | Group-Object Categoria | Sort-Object Count -Descending
    $max = ($grupos | Measure-Object Count -Maximum).Maximum
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="barras">')
    foreach ($g in $grupos) {
        $cor = if ($script:CorCategoria[$g.Name]) { $script:CorCategoria[$g.Name] } else { '#607d8b' }
        $pct = if ($max) { [math]::Round($g.Count / $max * 100, 0) } else { 0 }
        [void]$sb.Append("<div class='barra'><span class='barra-rot'>$(ConvertTo-HtmlSeguro $g.Name)</span><span class='barra-trilho'><span class='barra-fill' style='width:$pct%;background:$cor'></span></span><span class='barra-num'>$($g.Count)</span></div>")
    }
    [void]$sb.Append('</div>')
    $sb.ToString()
}

function Get-PapeisMaquinaLocal {
    # Resumo curto do que a máquina da coleta faz, para o nó dela na topologia.
    $papeis = New-Object System.Collections.Generic.List[string]
    if ($script:PapelMaquina -eq 'Controlador de domínio') { $papeis.Add('AD (DC)') }
    $p = "$($script:Resumo['Papéis instalados'])"
    if ($p -match 'Hyper-V') { $papeis.Add('Hyper-V') }
    if ($p -match '(?i)Trabalho Remota|Remote Desktop') { $papeis.Add('RDS') }
    if ($p -match '(?i)Arquivo|File') { $papeis.Add('Arquivos') }
    if ($p -match 'DHCP') { $papeis.Add('DHCP') }
    if ($p -match 'DNS') { $papeis.Add('DNS') }
    if ($p -match '(?i)Web|IIS') { $papeis.Add('IIS') }
    if ($p -match '(?i)Impress|Print') { $papeis.Add('Impressão') }
    if ("$($script:Resumo['SQL Server'])") { $papeis.Add('SQL Server') }
    $ob = "$($script:Resumo['Outros bancos'])"
    if ($ob -match '(?i)Firebird') { $papeis.Add('Firebird') }
    if ($ob -match '(?i)postgres') { $papeis.Add('PostgreSQL') }
    if ($ob -match '(?i)mysql|mariadb') { $papeis.Add('MySQL') }
    if ($papeis.Count -eq 0 -and $script:PapelMaquina) { $papeis.Add($script:PapelMaquina) }
    ($papeis -join ' · ')
}

function New-TopologiaSvg {
    # Diagrama de rede: Internet, gateway, um barramento por sub-rede e os grupos pendurados nele.
    # A máquina da coleta vira um nó próprio com os papéis dela. Desenha mesmo sem dispositivo descoberto.
    param($Hosts, [string]$Gateway, [string]$Operadora)
    $todos = @($Hosts | ForEach-Object { $_ })
    $equipGateway = @($todos | Where-Object { $_.Gateway }) | Select-Object -First 1
    $local = @($todos | Where-Object { $_.Origem -eq 'Esta máquina' -and $_.IP -notlike '169.254.*' }) | Select-Object -First 1
    $ipLocal = if ($local) { $local.IP } else { @($script:IpsLocais | Where-Object { $_ -and $_ -notlike '169.254.*' }) | Select-Object -First 1 }
    $lista = @($todos | Where-Object { -not $_.Gateway -and $_.Origem -ne 'Esta máquina' })

    $esc = { param($t) ConvertTo-HtmlSeguro "$t" }
    $cardW = 200; $gap = 16; $margem = 28; $limite = 12; $localW = 250
    $nomeLocal = $env:COMPUTERNAME
    $papeis = Get-PapeisMaquinaLocal

    # Sub-redes (por /24) com seus grupos. A que contém a máquina local vem primeiro.
    $porSub = @($lista | Group-Object { ($_.IP -replace '\.\d+$', '') } | Sort-Object Count -Descending)
    $subLocal = if ($ipLocal) { $ipLocal -replace '\.\d+$', '' } else { '' }
    $ordemSub = @()
    if ($subLocal) { $ordemSub += $subLocal }
    $ordemSub += @($porSub | ForEach-Object { $_.Name } | Where-Object { $_ -ne $subLocal })
    if ($ordemSub.Count -eq 0) { $ordemSub = @($(if ($Gateway) { $Gateway -replace '\.\d+$', '' } else { 'LAN' })) }

    # Largura: a faixa mais larga manda.
    $maxCards = 0
    foreach ($s in $ordemSub) {
        $g = @($porSub | Where-Object { $_.Name -eq $s })
        $cats = if ($g) { @($g[0].Group.Categoria | Select-Object -Unique).Count } else { 0 }
        $largura = $cats * ($cardW + $gap) + $(if ($s -eq $subLocal -or $ordemSub.Count -eq 1) { $localW + $gap } else { 0 })
        if ($largura -gt $maxCards) { $maxCards = $largura }
    }
    $svgW = [math]::Max(900, $margem * 2 + $maxCards)
    $cx = [int]($svgW / 2)

    $sb = New-Object System.Text.StringBuilder
    $corpo = New-Object System.Text.StringBuilder
    $y = 14
    # Internet
    $opTexto = if ($Operadora) { $Operadora } else { 'Operadora não identificada' }
    if ($opTexto.Length -gt 50) { $opTexto = $opTexto.Substring(0, 49) + '…' }
    $wNet = [math]::Max(300, $opTexto.Length * 7 + 48)
    [void]$corpo.Append("<rect x='$($cx - [int]($wNet/2))' y='$y' width='$wNet' height='50' rx='25' fill='#e8f0fe' stroke='#0277bd' stroke-width='2'/>")
    [void]$corpo.Append("<text x='$cx' y='$($y+22)' text-anchor='middle' font-size='15' font-weight='700' fill='#0277bd'>Internet</text>")
    [void]$corpo.Append("<text x='$cx' y='$($y+40)' text-anchor='middle' font-size='11' fill='#333'>$(& $esc $opTexto)</text>")
    $y += 50
    [void]$corpo.Append("<line x1='$cx' y1='$y' x2='$cx' y2='$($y+34)' stroke='#999' stroke-width='2'/>")
    $y += 34
    # Gateway
    $gwTexto = if ($Gateway) { "Gateway / Firewall   $Gateway" } else { 'Gateway / Firewall não identificado' }
    $gwDetalhe = if ($equipGateway) {
        $p = @($equipGateway.Fabricante, $(if ($equipGateway.NomeDNS) { $equipGateway.NomeDNS.Split('.')[0] } elseif ($equipGateway.NetBIOS) { $equipGateway.NetBIOS } else { '' })) | Where-Object { $_ }
        if ($equipGateway.ServidorDhcp) { $p += 'servidor DHCP' }
        ($p -join ' · ')
    } else { '' }
    if ($gwDetalhe.Length -gt 56) { $gwDetalhe = $gwDetalhe.Substring(0, 55) + '…' }
    $wGw = [math]::Max(320, [math]::Max($gwTexto.Length, $gwDetalhe.Length) * 8 + 48)
    $hGw = if ($gwDetalhe) { 52 } else { 44 }
    [void]$corpo.Append("<rect x='$($cx - [int]($wGw/2))' y='$y' width='$wGw' height='$hGw' rx='8' fill='#0D0035'/>")
    if ($gwDetalhe) {
        [void]$corpo.Append("<text x='$cx' y='$($y+21)' text-anchor='middle' font-size='13' font-weight='700' fill='#fff'>$(& $esc $gwTexto)</text>")
        [void]$corpo.Append("<text x='$cx' y='$($y+39)' text-anchor='middle' font-size='10.5' fill='#c9c5ff'>$(& $esc $gwDetalhe)</text>")
    } else {
        [void]$corpo.Append("<text x='$cx' y='$($y+27)' text-anchor='middle' font-size='13' font-weight='700' fill='#fff'>$(& $esc $gwTexto)</text>")
    }
    $gwBottom = $y + $hGw
    $y = $gwBottom + 44

    $k = 0
    foreach ($s in $ordemSub) {
        $g = @($porSub | Where-Object { $_.Name -eq $s })
        $itensSub = if ($g) { @($g[0].Group) } else { @() }
        $grupos = @($itensSub | Group-Object Categoria)
        $presentes = @($script:CorCategoria.Keys | Where-Object { $ch = $_; $grupos | Where-Object { $_.Name -eq $ch } })
        $temLocal = ($s -eq $subLocal) -or ($ordemSub.Count -eq 1 -and -not $subLocal)
        $qtdSub = $itensSub.Count + $(if ($temLocal) { 1 } else { 0 })

        # Ligação do gateway até o barramento: reta na primeira faixa, tracejada (roteado) nas demais.
        $busY = $y
        if ($k -eq 0) {
            [void]$corpo.Append("<line x1='$cx' y1='$gwBottom' x2='$cx' y2='$busY' stroke='#999' stroke-width='2'/>")
        } else {
            # Sai do gateway, dobra para a margem e desce tracejado até a faixa: é tráfego roteado.
            $xr = $margem - 8
            [void]$corpo.Append("<path d='M $cx $gwBottom V $($gwBottom+16) H $xr V $busY' stroke='#999' stroke-width='1.5' stroke-dasharray='6,4' fill='none'/>")
            [void]$corpo.Append("<text x='$($xr+8)' y='$($busY-8)' font-size='10' fill='#666'>roteado pelo gateway</text>")
        }
        # Barramento da LAN
        [void]$corpo.Append("<line x1='$margem' y1='$busY' x2='$($svgW-$margem)' y2='$busY' stroke='#5C50FF' stroke-width='5' stroke-linecap='round'/>")
        $rotuloSub = "LAN $s.0/24 · $qtdSub dispositivo$(if ($qtdSub -ne 1) { 's' })"
        [void]$corpo.Append("<rect x='$cx' y='$($busY-11)' width='1' height='1' fill='none'/>")
        [void]$corpo.Append("<text x='$($svgW-$margem)' y='$($busY-8)' text-anchor='end' font-size='11.5' font-weight='700' fill='#5C50FF'>$(& $esc $rotuloSub)</text>")

        # Cards da faixa: nó da máquina local primeiro, depois um por categoria.
        $x = $margem
        $yCard = $busY + 26
        $alturaFaixa = 0
        if ($temLocal) {
            # Papéis quebram em linhas de até 34 caracteres, sem truncar: são o motivo de o nó existir.
            $linhasPapeis = @()
            $atual = ''
            foreach ($tok in @($papeis -split '\s·\s' | Where-Object { $_ })) {
                if ($atual -and ($atual.Length + $tok.Length + 3) -gt 34) { $linhasPapeis += $atual; $atual = $tok } else { $atual = if ($atual) { "$atual · $tok" } else { $tok } }
            }
            if ($atual) { $linhasPapeis += $atual }
            $linhas = @($nomeLocal, $(if ($ipLocal) { $ipLocal } else { '' })) + $linhasPapeis | Where-Object { $_ }
            $hLocal = 30 + $linhas.Count * 16 + 8
            $lcx = [int]($x + $localW / 2)
            [void]$corpo.Append("<line x1='$lcx' y1='$busY' x2='$lcx' y2='$yCard' stroke='#455a64' stroke-width='2'/>")
            [void]$corpo.Append("<rect x='$x' y='$yCard' width='$localW' height='$hLocal' rx='8' fill='#0D0035' stroke='#455a64' stroke-width='2'/>")
            [void]$corpo.Append("<rect x='$($x+$localW-52)' y='$($yCard+8)' width='44' height='14' rx='7' fill='#455a64'/>")
            [void]$corpo.Append("<text x='$($x+$localW-30)' y='$($yCard+18)' text-anchor='middle' font-size='9' font-weight='700' fill='#fff'>VOCÊ</text>")
            [void]$corpo.Append("<text x='$($x+12)' y='$($yCard+19)' font-size='13' font-weight='700' fill='#fff'>$(& $esc $nomeLocal)</text>")
            $ty = $yCard + 38
            foreach ($l in @($linhas | Select-Object -Skip 1)) {
                [void]$corpo.Append("<text x='$($x+12)' y='$ty' font-size='11' fill='#c9c5ff'>$(& $esc "$l")</text>")
                $ty += 16
            }
            $alturaFaixa = [math]::Max($alturaFaixa, $hLocal)
            $x += $localW + $gap
        }
        foreach ($cat in $presentes) {
            $grupo = $grupos | Where-Object { $_.Name -eq $cat }
            $qtd = $grupo.Count
            $mostra = [math]::Min($qtd, $limite)
            $h = 42 + $mostra * 16 + $(if ($qtd -gt $limite) { 18 } else { 0 }) + 8
            $cor = if ($script:CorCategoria[$cat]) { $script:CorCategoria[$cat] } else { '#607d8b' }
            $ccx = [int]($x + $cardW / 2)
            [void]$corpo.Append("<line x1='$ccx' y1='$busY' x2='$ccx' y2='$yCard' stroke='$cor' stroke-width='2'/>")
            [void]$corpo.Append("<rect x='$x' y='$yCard' width='$cardW' height='$h' rx='8' fill='#fff' stroke='$cor' stroke-width='2'/>")
            [void]$corpo.Append("<path d='M $x $($yCard+8) q 0 -8 8 -8 h $($cardW-16) q 8 0 8 8 v 22 h -$cardW z' fill='$cor'/>")
            [void]$corpo.Append("<text x='$($x+10)' y='$($yCard+20)' font-size='12.5' font-weight='700' fill='#fff'>$(& $esc $cat)</text>")
            [void]$corpo.Append("<text x='$($x+$cardW-10)' y='$($yCard+20)' text-anchor='end' font-size='12.5' font-weight='700' fill='#fff'>$qtd</text>")
            $ty = $yCard + 46
            foreach ($d in @($grupo.Group | Sort-Object { ConvertTo-NumeroIp $_.IP } | Select-Object -First $limite)) {
                $nm = if ($d.NomeDNS) { $d.NomeDNS.Split('.')[0] } elseif ($d.NetBIOS) { $d.NetBIOS } else { '' }
                $rot = if ($nm) { "$($d.IP)  $nm" } else { "$($d.IP)" }
                if ($rot.Length -gt 26) { $rot = $rot.Substring(0, 25) + '…' }
                $peso = if ($d.ServidorDhcp) { '700' } else { '400' }
                [void]$corpo.Append("<text x='$($x+10)' y='$ty' font-size='11' font-weight='$peso' fill='#222'>$(& $esc $rot)</text>")
                if ($d.ServidorDhcp) {
                    [void]$corpo.Append("<rect x='$($x+$cardW-44)' y='$($ty-10)' width='36' height='13' rx='6' fill='#0277bd'/>")
                    [void]$corpo.Append("<text x='$($x+$cardW-26)' y='$($ty-1)' text-anchor='middle' font-size='8.5' font-weight='700' fill='#fff'>DHCP</text>")
                }
                $ty += 16
            }
            if ($qtd -gt $limite) { [void]$corpo.Append("<text x='$($x+10)' y='$ty' font-size='11' font-style='italic' fill='#666'>+$($qtd-$limite) na tabela abaixo</text>") }
            $alturaFaixa = [math]::Max($alturaFaixa, $h)
            $x += $cardW + $gap
        }
        if ($itensSub.Count -eq 0 -and -not $temLocal) {
            [void]$corpo.Append("<text x='$margem' y='$($yCard+18)' font-size='11.5' font-style='italic' fill='#666'>nenhum dispositivo descoberto nesta faixa</text>")
            $alturaFaixa = 24
        } elseif ($itensSub.Count -eq 0) {
            [void]$corpo.Append("<text x='$x' y='$($yCard+18)' font-size='11.5' font-style='italic' fill='#666'>nenhum outro dispositivo descoberto (varredura vazia ou desativada)</text>")
        }
        $y = $yCard + $alturaFaixa + 40
        $k++
    }
    $svgH = $y
    [void]$sb.Append("<svg viewBox='0 0 $svgW $svgH' width='100%' style='max-width:${svgW}px;height:auto' xmlns='http://www.w3.org/2000/svg' font-family='Open Sans,Segoe UI,Arial,sans-serif'>")
    [void]$sb.Append($corpo.ToString())
    [void]$sb.Append('</svg>')
    $sb.ToString()
}

$linhasResumo = foreach ($chave in $script:Resumo.Keys) { [pscustomobject]@{ Item = $chave; Valor = $script:Resumo[$chave] } }
$contagem = ($alertasOrdenados | Group-Object Severidade | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ' | '
$manual = @(
    'Contratos: sistema cartorário, link de internet, backup em nuvem, locação de impressoras, suporte',
    'Fornecedores e contatos: sistema cartorário, operadora, CFTV, telefonia, energia/nobreak',
    'Firewall/roteador: modelo, firmware, regras, VPN, acesso remoto liberado',
    'Switch e cabeamento: modelo, portas, VLANs, rack e organização',
    'Nobreaks: modelo, potência, autonomia, idade das baterias',
    'Backup: painel do backup em nuvem, retenção, último teste de restauração, cópia externa',
    'Certificados digitais A1/A3: titular, validade e custódia',
    'Credenciais: registrar somente no Bitwarden, nunca em documento',
    'Provimento 213: documentos e evidências já existentes (dossiê)',
    'Fotos do ambiente técnico, rack e servidores'
)

# Indicadores do topo
$totDisp  = @($script:Hosts).Count
$totPortas = [int](@($script:Hosts | Measure-Object QtdPortas -Sum).Sum)
$altas    = @($alertasOrdenados | Where-Object { $_.Severidade -eq 'Alta' }).Count
$medias   = @($alertasOrdenados | Where-Object { $_.Severidade -eq 'Média' }).Count
$foraSup  = (@($script:ComputadoresAD | Where-Object { $_.Suporte -like 'Fora de suporte*' }).Count) + (@($script:Estacoes | Where-Object { $_.Suporte -like 'Fora de suporte*' }).Count)
$totComp  = @($script:Estacoes | Where-Object { $_.Status -eq 'OK' }).Count

$kpis = @(
    @{ N = $altas;    R = 'Alertas de alta';        C = $(if ($altas -gt 0) { '#c62828' } else { '#2e7d32' }) }
    @{ N = $medias;   R = 'Alertas médios';         C = $(if ($medias -gt 0) { '#ef8c00' } else { '#2e7d32' }) }
    @{ N = $totDisp;  R = 'Dispositivos na rede';   C = '#5C50FF' }
    @{ N = $totPortas; R = 'Portas abertas';        C = '#0277bd' }
    @{ N = $foraSup;  R = 'SO fora de suporte';     C = $(if ($foraSup -gt 0) { '#c62828' } else { '#2e7d32' }) }
    @{ N = $totComp;  R = 'PCs inventariados';      C = '#00897b' }
)
$kpiHtml = ($kpis | ForEach-Object { "<div class='kpi' style='border-top-color:$($_.C)'><div class='kpi-n' style='color:$($_.C)'>$($_.N)</div><div class='kpi-r'>$(ConvertTo-HtmlSeguro $_.R)</div></div>" }) -join ''

$html = @"
<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Assessment de TI | $(ConvertTo-HtmlSeguro $Cliente)</title>
<link rel="icon" type="image/png" href="data:image/png;base64,$($script:EmblemaBase64)">
<style>
 *{box-sizing:border-box}
 body{font-family:'Open Sans',Segoe UI,Arial,sans-serif;margin:0;background:#F4F4F4;color:#1a1a2e}
 header{background:linear-gradient(120deg,#0D0035,#2a1a6e);color:#fff;padding:24px 32px}
 header h1{margin:0 0 4px;font-size:22px} header p{margin:0;color:#c9c5ff;font-size:13px}
 main{padding:24px 32px;max-width:1500px;margin:0 auto}
 h2{color:#0D0035;border-bottom:3px solid #5C50FF;padding-bottom:4px;margin-top:36px}
 .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin-top:20px}
 .kpi{background:#fff;border-radius:10px;border-top:4px solid #5C50FF;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.08);text-align:center}
 .kpi-n{font-size:34px;font-weight:800;line-height:1}
 .kpi-r{font-size:12px;color:#555;margin-top:6px}
 .card{background:#fff;border-radius:10px;padding:18px 20px;margin-top:8px;box-shadow:0 1px 4px rgba(0,0,0,.06);overflow-x:auto}
 table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;margin-top:8px}
 th{background:#0D0035;color:#fff;text-align:left;padding:8px;position:sticky;top:0}
 td{padding:6px 8px;border-bottom:1px solid #e3e3e3;vertical-align:top;word-break:normal;overflow-wrap:break-word;max-width:480px}
 td.nw,th{white-space:nowrap}
 .tabela{overflow-x:auto;background:#fff;border-radius:10px;box-shadow:0 1px 4px rgba(0,0,0,.06);margin-top:8px}
 .tabela table{margin-top:0}
 .mudo{color:#888;font-weight:400}
 h3.sev-titulo{margin:18px 0 6px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;display:flex;align-items:center;gap:8px}
 .sev-qtd{color:#fff;font-size:11px;padding:1px 8px;border-radius:10px}
 .alertas{display:flex;flex-direction:column;gap:8px}
 .alerta{background:#fff;border-radius:8px;padding:10px 14px;border-left:6px solid #9e9e9e;box-shadow:0 1px 3px rgba(0,0,0,.06)}
 .alerta-cab{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
 .alerta-cab b{font-size:13.5px;color:#1a1a2e}
 .area{font-size:10.5px;color:#666;text-transform:uppercase;letter-spacing:.5px;white-space:nowrap}
 .alerta-det{font-size:12.5px;color:#444;margin-top:4px;line-height:1.45}
 .pcs{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:12px;margin-top:8px}
 .pc{background:#fff;border-radius:10px;padding:12px 14px;box-shadow:0 1px 4px rgba(0,0,0,.06);border-top:3px solid #5C50FF}
 .pc h4{margin:0 0 6px;font-size:14px;display:flex;justify-content:space-between;align-items:center;gap:8px}
 .pc .l{font-size:12px;color:#444;line-height:1.55;margin-top:2px}
 .pc .l b{color:#1a1a2e}
 .badge{display:inline-block;font-size:10.5px;font-weight:700;padding:1px 7px;border-radius:10px;white-space:nowrap;margin-right:2px}
 .ok{background:#e8f5e9;color:#2e7d32} .ruim{background:#ffebee;color:#c62828} .aviso{background:#fff3e0;color:#ef6c00} .neutro{background:#eceff1;color:#455a64}
 .offline{background:#fff;border-radius:10px;padding:10px 14px;margin-top:10px;font-size:12.5px;color:#666;line-height:1.6}
 tr:nth-child(even) td{background:#faf9ff}
 tr.sev-0 td:first-child{border-left:6px solid #c62828;font-weight:600}
 tr.sev-1 td:first-child{border-left:6px solid #ef8c00;font-weight:600}
 tr.sev-2 td:first-child{border-left:6px solid #5C50FF}
 tr.sev-3 td:first-child{border-left:6px solid #9e9e9e}
 .vazio{color:#666;font-style:italic} ul{background:#fff;border-radius:10px;padding:16px 32px;margin-top:8px}
 .contagem{background:#fff;border-left:6px solid #5C50FF;padding:12px 16px;margin-top:8px;border-radius:6px;font-weight:600}
 .barras{margin-top:4px}
 .barra{display:flex;align-items:center;gap:10px;margin:5px 0}
 .barra-rot{width:130px;font-size:12px;text-align:right;color:#333}
 .barra-trilho{flex:1;background:#ececf4;border-radius:6px;height:18px;overflow:hidden}
 .barra-fill{display:block;height:100%;border-radius:6px}
 .barra-num{width:34px;font-size:12px;font-weight:700}
 .legenda{color:#666;font-size:12px;margin:4px 0 0}
 .visao{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;margin-top:10px}
 .bloco{background:#fff;border-radius:10px;padding:14px 18px;box-shadow:0 1px 4px rgba(0,0,0,.06);border-top:3px solid #5C50FF}
 .bloco h3{margin:0 0 10px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:#5C50FF}
 .bloco dl{margin:0;display:grid;grid-template-columns:150px 1fr;gap:6px 12px}
 .bloco dt{font-size:12px;color:#666;line-height:1.4;padding-top:1px}
 .bloco dd{margin:0;font-size:12.5px;font-weight:600;color:#1a1a2e;line-height:1.4;word-break:normal;overflow-wrap:anywhere}
 .bloco dd .ln{display:block;padding:1px 0;border-bottom:1px dotted #e6e6ef} .bloco dd .ln:last-child{border-bottom:0}
 .marca{display:flex;align-items:center;gap:14px}
 .marca img{height:40px;width:auto;display:block}
 .marca-txt{display:flex;flex-direction:column}
 table.disp td{font-size:12.5px}
 table.disp td.ip{white-space:nowrap;font-weight:600}
 .mac{color:#888;font-size:11px;font-family:Consolas,monospace;margin-top:2px}
 .tag{display:inline-block;font-size:10px;font-weight:700;padding:1px 6px;border-radius:10px;vertical-align:middle;margin-left:4px}
 .tag-gw{background:#ef8c00;color:#fff} .tag-local{background:#455a64;color:#fff}
 tr.linha-local td{background:#f0f2f5;color:#666}
 .portas{display:flex;flex-wrap:wrap;gap:3px;max-width:420px}
 .chip{display:inline-block;font-size:10.5px;line-height:1.5;border:1px solid #bbb;border-radius:10px;padding:0 6px;text-decoration:none;white-space:nowrap}
 a.chip{font-weight:600} a.chip:hover{background:#eef0ff;text-decoration:underline}
 .chip-off{color:#777;background:#fafafa;opacity:.85}
 .semporta{color:#999;font-style:italic;font-size:12px}
 .selo{display:inline-block;color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:6px;vertical-align:middle}
 .legenda-portas{display:flex;flex-wrap:wrap;gap:10px;margin:6px 0 0;font-size:11px;color:#555}
 .legenda-portas span b{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px}
 @media print{body{background:#fff}.card,.kpi{box-shadow:none;border:1px solid #ddd}h2{page-break-after:avoid}}
</style></head><body>
<header><div class="marca">
<img src="data:image/png;base64,$($script:LogoBase64)" alt="Nextec">
<div class="marca-txt">
<h1>Assessment de TI | $(ConvertTo-HtmlSeguro $Cliente)</h1>
<p>Coleta em $(ConvertTo-HtmlSeguro $script:Resumo['Data da coleta']) a partir de $(ConvertTo-HtmlSeguro $env:COMPUTERNAME) ($(ConvertTo-HtmlSeguro $script:PapelMaquina)), por $(ConvertTo-HtmlSeguro "$env:USERDOMAIN\$env:USERNAME") &bull; Documento interno</p>
</div></div></header>
<main>
<div class="kpis">$kpiHtml</div>

<h2>Topologia da rede (lógica)</h2>
<div class="card">$(New-TopologiaSvg -Hosts $script:Hosts -Gateway $script:Resumo['Gateway'] -Operadora $script:Operadora)
<p class="legenda">Internet, gateway de saída e um barramento por sub-rede com os grupos pendurados nele. O nó escuro com <span class="selo" style="background:#455a64">VOCÊ</span> é a máquina que rodou a coleta, com os papéis que ela acumula; <span class="selo" style="background:#0277bd">DHCP</span> marca quem distribui os IPs. Agrupamento por tipo provável; não representa a ligação física de cada porta do switch.</p></div>

<h2>Distribuição por tipo</h2>
<div class="card">$(New-BarrasCategoria $script:Hosts)</div>

<h2>Pontos de atenção</h2>
<div class="contagem">$(ConvertTo-HtmlSeguro $contagem)</div>
$(New-AlertasHtml $alertasOrdenados)

<h2>Visão geral</h2>
$(New-VisaoGeral $script:Resumo)

<h2>Dispositivos na rede</h2>
<p class="legenda">As portas com serviço acessível viram link: clique para abrir o painel web, o compartilhamento ou o console do equipamento. Linhas em cinza são a própria máquina que rodou a coleta.</p>
<div class="legenda-portas">$(($script:CorGrupoPorta.Keys | ForEach-Object { "<span><b style='background:$($script:CorGrupoPorta[$_])'></b>$(ConvertTo-HtmlSeguro $_)</span>" }) -join '')</div>
$(New-TabelaDispositivos $script:Hosts)

<h2>TLS e certificados dos serviços</h2>
<p class="legenda">Versões aceitas por cada serviço e validade do certificado. O Provimento 213 (REQ-024) exige TLS 1.2 ou superior.</p>
$(New-TabelaHtml $script:Tls @('IP', 'Porta', 'ProtocolosAceitos', 'ProtocoloObsoleto', 'CertificadoEmissor', 'CertificadoValidoAte', 'DiasParaVencer', 'AutoAssinado'))

<h2>Compartilhamentos encontrados na rede</h2>
$(New-TabelaHtml $script:CompartilhamentosRede @('IP', 'Nome', 'Compartilhamento', 'Tipo', 'Comentario'))

<h2>Computadores do domínio</h2>
<p class="legenda">Um cartão por máquina inventariada. Os dados completos estão em <b>inventario_computadores.csv</b> e nos arquivos <b>estacoes_*.csv</b>.</p>
$(New-ComputadoresHtml $script:Estacoes)
$(New-EstacoesHtml $script:Estacoes)

<h2>Certificados digitais</h2>
$(New-TabelaHtml $script:Certificados @('Repositorio', 'Titular', 'Emissor', 'IcpBrasil', 'ValidoAte', 'DiasRestantes', 'TemChavePrivada'))

<h2>Arquivos gerados</h2>
$(New-TabelaHtml $script:Arquivos @('Arquivo', 'Registros', 'Descricao'))

<h2>Falhas na coleta</h2>
$(New-TabelaHtml $script:Erros @('Etapa', 'Erro'))
</main></body></html>
"@
$caminhoHtml = Join-Path $script:PastaSaida 'Resumo-Assessment.html'
$html | Out-File -FilePath $caminhoHtml -Encoding UTF8

# Persiste os fabricantes resolvidos (só os acertos) para as próximas execuções.
try {
    $dirCache = Split-Path $script:ArquivoCacheOui
    if (-not (Test-Path $dirCache)) { New-Item -ItemType Directory -Path $dirCache -Force | Out-Null }
    $script:CacheOui.GetEnumerator() | Where-Object { $_.Value -and $_.Value -notlike 'MAC aleatório*' } |
        ForEach-Object { [pscustomobject]@{ Prefixo = $_.Key; Fabricante = $_.Value } } |
        Export-Csv -Path $script:ArquivoCacheOui -NoTypeInformation -Encoding UTF8
} catch { }

$zip = "$script:PastaSaida.zip"
$zipGerado = $false
try {
    Compress-Archive -Path (Join-Path $script:PastaSaida '*') -DestinationPath $zip -Force
    $zipGerado = (Test-Path -LiteralPath $zip) -and ((Get-Item -LiteralPath $zip).Length -gt 0)
    Write-Log "Pacote compactado: $zip"
} catch { Write-Log "Não foi possível compactar: $($_.Exception.Message)" 'AVISO' }

# Com o .zip íntegro, a pasta é redundante e some do servidor do cliente. Se o zip falhar, a pasta fica.
# Nenhum Write-Log depois daqui: o log vive dentro da pasta removida.
$pastaRemovida = $false
if ($zipGerado) {
    try {
        Remove-Item -LiteralPath $script:PastaSaida -Recurse -Force -ErrorAction Stop
        $pastaRemovida = $true
    } catch { Write-Host "Não foi possível remover a pasta $script:PastaSaida: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Resumo final
Close-LinhaEtapa
$duracaoTotal = Format-Duracao ((Get-Date) - $script:Inicio)
Write-Host ''
Write-Host ('  ' + ('═' * ($script:LarguraTela + 2))) -ForegroundColor Cyan
Write-Host '   Assessment concluído' -NoNewline -ForegroundColor Green
Write-Host "  em $duracaoTotal" -ForegroundColor DarkGray
Write-Host ''
Write-Host ('   {0,-10}' -f 'Alertas') -NoNewline -ForegroundColor DarkGray
$coresSeveridade = [ordered]@{ 'Alta' = 'Red'; 'Média' = 'Yellow'; 'Baixa' = 'Cyan'; 'Info' = 'Gray' }
foreach ($sev in $coresSeveridade.Keys) {
    $qtd = @($alertasOrdenados | Where-Object { $_.Severidade -eq $sev }).Count
    Write-Host ("{0} {1}    " -f $sev, $qtd) -NoNewline -ForegroundColor $(if ($qtd) { $coresSeveridade[$sev] } else { 'DarkGray' })
}
Write-Host ''
if ($script:Erros.Count) {
    Write-Host ('   {0,-10}' -f 'Falhas') -NoNewline -ForegroundColor DarkGray
    Write-Host "$($script:Erros.Count) etapa(s) com falha, detalhes no relatório" -ForegroundColor Yellow
}
if ($zipGerado) {
    Write-Host ('   {0,-10}' -f 'Pacote') -NoNewline -ForegroundColor DarkGray
    Write-Host $zip -ForegroundColor White
}
if (-not $pastaRemovida) {
    Write-Host ('   {0,-10}' -f 'Relatório') -NoNewline -ForegroundColor DarkGray
    Write-Host $caminhoHtml -ForegroundColor White
}
Write-Host ''
Write-Host '   Envie o pacote para análise e não deixe cópias no servidor do cliente.' -ForegroundColor Gray
Write-Host ('  ' + ('═' * ($script:LarguraTela + 2))) -ForegroundColor Cyan

# Segura a janela no fim quando há alguém olhando (duplo clique); em agendador e automação, não trava.
if ($Automatico) {
    # Sem perguntas: abre a pasta com o relatório e deixa a janela por alguns segundos para o técnico ler o caminho.
    $alvoExplorer = if ($pastaRemovida) { $zip } else { $caminhoHtml }
    try { Start-Process explorer.exe -ArgumentList "/select,`"$alvoExplorer`"" } catch { }
    Write-Host ''
    Write-Host 'Esta janela fecha sozinha em 20 segundos.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
} elseif (Test-TemTeclado) {
    Write-Host ''
    if (-not $pastaRemovida -and (Read-Preenchimento 'Abrir o relatório agora? (S/N)' 'S') -match '^(s|y)') { try { Start-Process $caminhoHtml } catch { } }
    Read-Host 'Pressione Enter para fechar' | Out-Null
}
