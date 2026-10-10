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
    Reabre elevado sozinho (o UAC é o único aviso), assume o nome do cliente pelo domínio, valida o ambiente
    antes de coletar e, só se a conta atual for negada nas estações, abre UMA janela de login e senha do domínio.
    Essa credencial vale apenas para esta execução, não é gravada e é descartada ao terminar.

    Saída: pasta com CSVs (separador ';', UTF-8), textos, resumo.json, Resumo-Assessment.html e um .zip.
    A varredura de rede abre conexões TCP nas portas listadas; se houver IPS/antivírus de rede, avise o cliente.

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -Automatico

.EXAMPLE
    .\Nextec-Assessment-v2.ps1 -SoValidar

.EXAMPLE
    .\Nextec-Assessment.ps1 -Cliente "Cartorio Maria Jose Rabelo Costa"

.EXAMPLE
    .\Nextec-Assessment.ps1 -Cliente "CMJRC" -Subredes 192.168.0.0/24,192.168.10.0/24

.EXAMPLE
    .\Nextec-Assessment.ps1 -Cliente "CMJRC" -SemVarreduraRede -SemInventarioRemoto
#>
[CmdletBinding()]
param(
    [string]$Cliente = 'Cliente',
    [string[]]$Subredes,
    [string]$Saida = 'C:\Assessment',
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
    [switch]$PortasCompletas,
    [switch]$IncluirRedesVirtuais,
    [switch]$SoftwareEstacoes,
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
$script:CredencialRemota = $null

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

function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel = 'INFO')
    $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Nivel, $Mensagem
    $cor = switch ($Nivel) { 'AVISO' { 'Yellow' } 'ERRO' { 'Red' } default { 'Gray' } }
    Write-Host $linha -ForegroundColor $cor
    Add-Content -Path $script:ArquivoLog -Value $linha -Encoding UTF8
}

function Add-Alerta {
    param(
        [ValidateSet('Alta', 'Média', 'Baixa', 'Info')][string]$Severidade,
        [string]$Area, [string]$Item, [string]$Detalhe
    )
    $script:Alertas.Add([pscustomobject]@{ Severidade = $Severidade; Area = $Area; Item = $Item; Detalhe = $Detalhe })
}

function Invoke-Etapa {
    param([string]$Nome, [scriptblock]$Acao)
    Write-Log "Coletando: $Nome"
    try { & $Acao }
    catch {
        $mensagem = $_.Exception.Message
        $script:Erros.Add([pscustomobject]@{ Etapa = $Nome; Erro = $mensagem })
        Write-Log "Falha em ${Nome}: $mensagem" 'AVISO'
    }
}

function Save-Dados {
    param([string]$Nome, $Dados, [string]$Descricao)
    $lista = @($Dados | Where-Object { $null -ne $_ })
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
    # Datas de fim de suporte (edições Home/Pro para clientes, estendido para servidores). Conferir em caso de dúvida.
    param([string]$Caption, [int]$Build)
    if (-not $Build) { return 'Verificar' }
    if ($Caption -match 'Server') {
        $mapa = @{ 6002 = '2020-01-14'; 7601 = '2020-01-14'; 9200 = '2023-10-10'; 9600 = '2023-10-10'
                   14393 = '2027-01-12'; 17763 = '2029-01-09'; 20348 = '2031-10-14'; 26100 = '2034-10-10' }
    } else {
        $mapa = @{ 7601 = '2020-01-14'; 9600 = '2023-01-10'; 10240 = '2017-05-09'; 17763 = '2020-11-10'
                   18363 = '2022-05-10'; 19041 = '2021-12-14'; 19042 = '2022-05-10'; 19043 = '2022-12-13'
                   19044 = '2023-06-13'; 19045 = '2025-10-14'; 22000 = '2023-10-10'; 22621 = '2024-10-08'
                   22631 = '2025-11-11'; 26100 = '2026-10-13'; 26200 = '2027-10-12' }
    }
    if (-not $mapa.ContainsKey($Build)) { return 'Verificar (build não mapeado)' }
    $fim = [datetime]::ParseExact($mapa[$Build], 'yyyy-MM-dd', $null)
    $dias = ($fim - (Get-Date)).Days
    if ($dias -lt 0) { return "Fora de suporte desde $($fim.ToString('dd/MM/yyyy'))" }
    if ($dias -le 180) { return "Suporte até $($fim.ToString('dd/MM/yyyy')) (encerra em $dias dias)" }
    "Suportado até $($fim.ToString('dd/MM/yyyy'))"
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
        $titulo = if ($html -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') { ($Matches[1] -replace '\s+', ' ') } else { '' }
        $realm = [string]$resposta.Headers['WWW-Authenticate']
        if (-not $titulo -and $realm) { $titulo = $realm }
        if ($titulo.Length -gt 120) { $titulo = $titulo.Substring(0, 120) }
        [pscustomobject]@{ Titulo = $titulo; Servidor = [string]$resposta.Headers['Server'] }
    }
    catch { $null }
    finally { $resposta.Close() }
}

function Invoke-ComandoComTimeout {
    # Executa um utilitário do Windows e devolve a saída; mata o processo se passar do tempo.
    param([string]$Arquivo, [string]$Argumentos, [int]$TimeoutMs = 8000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Arquivo; $psi.Arguments = $Argumentos
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $saida = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) { try { $proc.Kill() } catch { }; return '' }
        $saida.Result
    } catch { '' }
}

function Get-NomeNetBios {
    param([string]$Ip)
    $saida = Invoke-ComandoComTimeout 'nbtstat.exe' "-A $Ip" 3000
    $linha = ($saida -split "`r?`n") | Where-Object { $_ -match '^\s*(\S+)\s+<00>\s+' -and $_ -notmatch '(?i)GRUPO|GROUP' } | Select-Object -First 1
    if ($linha -match '^\s*(\S+)\s+<00>') { return $Matches[1] }
    ''
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
        if ($script:OuiEmbutidoGz) {
            $ms = New-Object IO.MemoryStream (, [Convert]::FromBase64String($script:OuiEmbutidoGz))
            $gz = New-Object IO.Compression.GZipStream ($ms, [IO.Compression.CompressionMode]::Decompress)
            $sr = New-Object IO.StreamReader ($gz, [Text.Encoding]::UTF8)
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
            if ($precisaBaixar -and -not $SemConsultaInternet) {
                Write-Log 'Baixando a base de fabricantes da IEEE (uma vez; ~4 MB)...'
                try {
                    Invoke-WebRequest -Uri 'https://standards-oui.ieee.org/oui/oui.csv' -OutFile $script:ArquivoOuiIeee -TimeoutSec 60 -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
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
    if (-not $SemConsultaInternet) {
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

function New-ComandoRelancamento {
    # Monta o comando para reabrir o script elevado com os mesmos parâmetros. Vai codificado
    # (-EncodedCommand) porque o -File não entende lista separada por vírgula nem aspas dentro de valores.
    param([System.Collections.IDictionary]$Informados)
    $aspas = { param($t) "'" + ("$t" -replace "'", "''") + "'" }
    $partes = New-Object System.Collections.Generic.List[string]
    $partes.Add("& $(& $aspas $PSCommandPath)")
    foreach ($nome in $Informados.Keys) {
        if ($nome -eq 'Credencial') { continue }   # credencial não atravessa a elevação; o processo elevado pede de novo se precisar
        $valor = $Informados[$nome]
        if ($valor -is [System.Management.Automation.SwitchParameter]) {
            if ($valor.IsPresent) { $partes.Add("-$nome") }
        } elseif ($valor -is [array]) {
            $itens = foreach ($v in $valor) { if ($v -is [string]) { & $aspas $v } else { "$v" } }
            $partes.Add("-$nome " + ($itens -join ','))
        } elseif ($valor -is [string]) {
            $partes.Add("-$nome " + (& $aspas $valor))
        } else {
            $partes.Add("-$nome $valor")
        }
    }
    $partes -join ' '
}

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
        Write-Log "  [$Status] ${Item}: $Detalhe" $nivel
    }
    $bloqueio = $false
    $credencialAtiva = $Credencial
    Write-Log 'Pré-validação do ambiente'

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
        if ($ok -gt 0 -and $neg -eq 0) { & $registrar 'Acesso remoto às estações' 'OK' $detalheTeste }
        elseif ($ok -gt 0) { & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. Parte das estações vai ficar sem inventário" }
        elseif ($neg -gt 0) { & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. A conta não é administradora nas estações: sem inventário delas" }
        elseif ($inacessiveis -eq $amostra.Count) { & $registrar 'Acesso remoto às estações' 'AVISO' "$detalheTeste. Estações desligadas ou com firewall bloqueando WinRM/DCOM (liberar por GPO)" }
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
Write-Log "Assessment Nextec | Cliente: $Cliente | Máquina: $env:COMPUTERNAME | Saída: $script:PastaSaida"

if (-not $ehAdmin) {
    Write-Log 'Sem privilégio de administrador: BitLocker, configurações de segurança e Hyper-V não serão coletados.' 'AVISO'
    $reabrir = $false
    if ($PSCommandPath) {
        if ($Automatico) { $reabrir = $true }
        elseif (Test-TemTeclado) { $reabrir = ((Read-Preenchimento 'Reabrir como administrador? (S/N)' 'S') -match '^(s|y)') }
    }
    if ($reabrir) {
        try {
            $informados = [ordered]@{}
            foreach ($k in $PSBoundParameters.Keys) { $informados[$k] = $PSBoundParameters[$k] }
            if (-not $informados.Contains('Cliente')) { $informados['Cliente'] = $Cliente }
            if ($DominioEmail -and -not $informados.Contains('DominioEmail')) { $informados['DominioEmail'] = $DominioEmail }
            $comando = New-ComandoRelancamento $informados
            $codificado = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($comando))
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $codificado)
            Write-Log 'Reaberto em janela com privilégio de administrador. Esta janela vai encerrar.'
            # A pasta desta execução só tem o log; a janela elevada cria a sua.
            Remove-Item -LiteralPath $script:PastaSaida -Recurse -Force -ErrorAction SilentlyContinue
            exit 0
        } catch {
            Write-Log "Não foi possível elevar ($($_.Exception.Message)); seguindo sem privilégio." 'AVISO'
        }
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
        Write-Host "Validação concluída. Detalhes em $script:PastaSaida" -ForegroundColor Green
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
        $fisicos = @(Get-PhysicalDisk | Select-Object FriendlyName, SerialNumber, MediaType, BusType, HealthStatus, OperationalStatus,
            @{ n = 'TamanhoGB'; e = { [math]::Round($_.Size / 1GB, 1) } })
        Save-Dados 'discos_fisicos' $fisicos 'Discos físicos (Storage Spaces)'
        foreach ($d in $fisicos | Where-Object { $_.HealthStatus -ne 'Healthy' }) {
            Add-Alerta 'Alta' 'Armazenamento' "Disco com saúde $($d.HealthStatus)" "$($d.FriendlyName) ($($d.SerialNumber))"
        }
    }

    try {
        $falhas = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure })
        foreach ($f in $falhas) { Add-Alerta 'Alta' 'Armazenamento' 'SMART prevê falha de disco' $f.InstanceName }
    } catch { }

    $raid = @($discosWmi | Where-Object { $_.Model -match 'PERC|RAID|LOGICAL|Virtual|MegaRAID|Smart Array' })
    $script:Resumo['Discos (Windows)'] = ($discosWmi | ForEach-Object { "$($_.Model) $($_.TamanhoGB) GB" }) -join ' | '
    if ($discosWmi.Count -eq 1 -and $raid.Count -eq 0) {
        Add-Alerta 'Alta' 'Armazenamento' 'Servidor com disco único sem RAID aparente' "$($discosWmi[0].Model); confirmar redundância na controladora"
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
        Save-Texto 'dell_omsa_storage' { omreport storage vdisk; omreport storage pdisk controller=0 } 'Dell OpenManage: discos virtuais e físicos'
        Save-Texto 'dell_omsa_chassis' { omreport chassis; omreport system summary } 'Dell OpenManage: chassi e resumo'
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
            IPv4 = ($meus.IPAddress) -join ', '
            Mascara = (($meus | ForEach-Object { "/$($_.PrefixLength)" }) | Select-Object -Unique) -join ', '
            Gateway = ((@($rotas | Where-Object { $_.InterfaceIndex -eq $a.ifIndex }).NextHop | Where-Object { $_ -and $_ -ne '0.0.0.0' }) | Select-Object -Unique) -join ', '
            DNS = ((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ }) -join ', '
            DHCP = [bool](@($meus | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).Count)
        }
    })
    Save-Dados 'rede_adaptadores' $adaptadores 'Placas de rede da máquina de coleta, com tipo (física/virtual), IP, gateway e DNS'
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
    if (-not $SemConsultaInternet) {
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
    $rota = Test-NetConnection -ComputerName 8.8.8.8 -TraceRoute -Hops 8 -WarningAction SilentlyContinue
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
    $hotfixes = @(Get-HotFix | Select-Object HotFixID, Description, InstalledBy, @{ n = 'InstaladoEm'; e = { $_.InstalledOn } } | Sort-Object InstaladoEm -Descending)
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
    $membros = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Select-Object Name, ObjectClass, PrincipalSource)
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
    $perfis = @(Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogAllowed, LogBlocked, LogFileName)
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
    $avServicos = @($script:ServicosLocal | Where-Object { $_.State -eq 'Running' -and $_.DisplayName -match '(?i)Acronis|Kaspersky|ESET|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|AVG|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|Defender for Endpoint|Sense' })
    $script:Resumo['Antivírus/EDR (serviços ativos)'] = (($avServicos.DisplayName) | Select-Object -Unique) -join ', '
    $defenderAtivo = $false
    if (Test-ComandoExiste 'Get-MpComputerStatus') {
        try {
            $mp = Get-MpComputerStatus
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
    $tpm = try { $t = Get-Tpm; "Presente: $($t.TpmPresent) | Pronto: $($t.TpmReady)" } catch { 'Não identificado' }
    $script:Resumo['Secure Boot'] = $secureBoot
    $script:Resumo['TPM'] = $tpm
    $script:Resumo['Proteção LSA (RunAsPPL)'] = if ($lsaPpl -ge 1) { 'Sim' } else { 'Não' }
    $script:Resumo['UAC'] = if ($uac -eq 0) { 'Desligado' } else { 'Ligado' }
    $script:Resumo['LLMNR desabilitado por política'] = if ($llmnr -eq 0) { 'Sim' } else { 'Não' }
    if ($uac -eq 0) { Add-Alerta 'Média' 'Segurança' 'UAC desligado' 'EnableLUA = 0' }

    if (Test-ComandoExiste 'Get-BitLockerVolume') {
        $bl = @(Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod, EncryptionPercentage)
        Save-Dados 'bitlocker' $bl 'Criptografia BitLocker por volume'
        $script:Resumo['BitLocker'] = ($bl | ForEach-Object { "$($_.MountPoint) $($_.ProtectionStatus)" }) -join ' | '
    }
    Save-Texto 'politica_auditoria' { auditpol /get /category:* } 'Política de auditoria do Windows'
    Save-Texto 'politica_senha_local' { net accounts } 'Política de senha efetiva (local/domínio)'
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
    $servicos = @($script:ServicosLocal | Where-Object { $_.DisplayName -match $padrao })
    Save-Dados 'backup_softwares' ($softwares) 'Softwares de backup instalados'
    Save-Dados 'backup_servicos' ($servicos) 'Serviços de backup'
    $script:Resumo['Backup identificado'] = (@($softwares.Nome) + @($servicos.DisplayName) | Select-Object -Unique) -join ', '
    if ($softwares.Count -eq 0 -and $servicos.Count -eq 0) { Add-Alerta 'Alta' 'Backup' 'Nenhuma ferramenta de backup identificada no servidor' 'Confirmar rotina de backup local e em nuvem' }
    if (Test-ComandoExiste 'Get-WBSummary') {
        try {
            $wb = Get-WBSummary
            $script:Resumo['Windows Server Backup'] = 'Último sucesso: {0} | Último resultado: {1}' -f (Format-Data $wb.LastSuccessfulBackupTime), $wb.LastBackupResultHR
            if (-not $wb.LastSuccessfulBackupTime -or $wb.LastSuccessfulBackupTime -eq [datetime]::MinValue) {
                Add-Alerta 'Info' 'Backup' 'Windows Server Backup instalado sem backup concluído' 'Recurso presente, nenhum sucesso registrado; confirmar se a rotina real é outra ferramenta'
            } elseif (((Get-Date) - $wb.LastSuccessfulBackupTime).TotalDays -gt 2) {
                Add-Alerta 'Média' 'Backup' 'Windows Server Backup atrasado' "Último sucesso em $(Format-Data $wb.LastSuccessfulBackupTime)"
            }
        } catch { }
    }
    Save-Texto 'vss_armazenamento' { vssadmin list shadowstorage } 'Armazenamento de cópias de sombra (VSS)'
    Save-Texto 'vss_writers' { vssadmin list writers } 'Estado dos gravadores VSS'
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
        Save-Dados 'impressoras' (Get-Printer | Select-Object Name, DriverName, PortName, Shared, ShareName, Published) 'Impressoras instaladas na máquina'
        Save-Dados 'impressoras_portas' (Get-PrinterPort | Where-Object { $_.PrinterHostAddress } | Select-Object Name, PrinterHostAddress, PortNumber) 'Portas TCP/IP de impressão'
    }
}

Invoke-Etapa 'Monitores' {
    # Número de série do monitor é patrimônio: entra no inventário do cliente.
    $mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
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
    # Chamada nativa: decodifica os acentos da saída do netsh corretamente.
    $saida = (netsh wlan show interfaces 2>&1 | Out-String)
    if (-not $saida -or $saida -match '(?i)não está em execução|is not running|nenhuma interface|no wireless') { return }
    Save-Texto 'wifi_interface' { netsh wlan show interfaces } 'Conexão Wi-Fi atual (SSID, sinal, canal, taxa)'
    Save-Texto 'wifi_perfis' { netsh wlan show profiles } 'Redes Wi-Fi salvas nesta máquina'
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
}

Invoke-Etapa 'Proxy, VLAN e rotas de saída' {
    $proxyUsuario = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer'
    $proxyAtivo   = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyEnable'
    $proxyAuto    = Get-ValorRegistro 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoConfigURL'
    $script:Resumo['Proxy configurado'] = if ($proxyAtivo -eq 1 -and $proxyUsuario) { $proxyUsuario }
        elseif ($proxyAuto) { "Automático: $proxyAuto" } else { 'Não' }
    Save-Texto 'proxy_winhttp' { netsh winhttp show proxy } 'Proxy do WinHTTP (usado por serviços e atualizações)'

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
    $licencas = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
        Select-Object Name, Description, @{ n = 'Status'; e = { $mapaStatus[[int]$_.LicenseStatus] } })
    Save-Dados 'licenciamento_windows' $licencas 'Ativação do Windows (sem chave)'
    $script:Resumo['Ativação do Windows'] = ($licencas.Status | Select-Object -Unique) -join ', '
    if ($licencas | Where-Object { $_.Status -ne 'Licenciado' }) { Add-Alerta 'Média' 'Licenciamento' 'Windows não ativado' (($licencas.Status) -join ', ') }

    # Office: o assessment cobra comprovante de licença, e ativação por método alternativo é achado comum (REQ-011).
    $office = @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
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
    Save-Texto 'horario_w32tm' { w32tm /query /status; w32tm /query /source; w32tm /query /configuration } 'Sincronização de horário (w32tm)'
    $script:Resumo['Fonte de horário'] = ((w32tm /query /source) | Out-String).Trim()
    $script:Resumo['Fuso horário'] = (Get-TimeZone).DisplayName
}

# ============================================================================
# 2. Active Directory
# ============================================================================

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
        if (Test-ComandoExiste 'dcdiag') { Save-Texto 'ad_dcdiag' { dcdiag /q } 'Testes do dcdiag (só falhas)' }
        if (Test-ComandoExiste 'repadmin') { Save-Texto 'ad_replicacao' { repadmin /replsummary } 'Resumo da replicação do AD' }
    }
}

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

                # TLS: versões aceitas e certificado, no máximo duas portas por equipamento para não alongar demais.
                $tlsHost = @(foreach ($p in @($script:PortasTls | Where-Object { $_ -in $portasHost } | Select-Object -First 1)) {
                    $t = Get-InfoTls -Ip $ip -Porta $p -NomeHost $nome -Timeout 2000
                    if ($t) { $listaTls.Add($t); $t }
                })
                $soBanner = ($banners | ForEach-Object { Get-SoPorBanner $_ } | Where-Object { $_ } | Select-Object -First 1)

                $compartilhados = @()
                if ($portasHost -contains 445) {
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
            $regexAv = '(?i)Acronis (Active Protection|Cyber Protection)|Kaspersky|ESET|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|AVG|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|^WinDefend$'
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
                $paramIc = @{ ComputerName = $Computador; ErrorAction = 'Stop' }
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

if (-not $SemInventarioRemoto -and $temAD -and $script:ComputadoresAD.Count -gt 0) {
    Invoke-Etapa 'Inventário das estações e servidores do domínio' {
        $limite = (Get-Date).AddDays(-60)
        $candidatos = @($script:ComputadoresAD | Where-Object { $_.Habilitado -and ($_.UltimoLogon -ge $limite -or -not $_.UltimoLogon) })
        # Inventário em paralelo (runspaces). Sequencial, cada máquina sem acesso custava ~40 s de timeout
        # de DCOM; com 20 estações eram 14 minutos. Em paralelo cai para o tempo das mais lentas.
        Write-Log "  $($candidatos.Count) computador(es) candidatos; até $Paralelismo em paralelo."
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
        foreach ($c in $candidatos) {
            $alvo = if ($c.DNS) { $c.DNS } else { $c.Nome }
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($bloco).AddArgument($c.Nome).AddArgument($alvo).AddArgument(($c.Nome -eq $env:COMPUTERNAME))
            $trabalhos.Add([pscustomobject]@{ Nome = $c.Nome; PS = $ps; Handle = $ps.BeginInvoke(); Lido = $false })
        }
        $resultados = @{}
        $ultimoAviso = Get-Date
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
            Start-Sleep -Milliseconds 400
        }
        $pool.Close(); $pool.Dispose()
        $script:Estacoes = @(foreach ($c in $candidatos) { if ($resultados.ContainsKey($c.Nome)) { $resultados[$c.Nome] } })
        $colunasInventario = @($script:Estacoes | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        if ($colunasInventario.Count -gt 0) { $script:Estacoes = @($script:Estacoes | Select-Object -Property $colunasInventario) }
        Save-Dados 'inventario_computadores' $script:Estacoes 'Inventário das estações: hardware, SO, criptografia, antivírus, patch e administradores locais'
        $ok = @($script:Estacoes | Where-Object { $_.Status -eq 'OK' })
        $recusadas = @($script:Estacoes | Where-Object { $_.Status -like 'Credencial recusada*' })
        $script:Resumo['Inventário remoto'] = "$($ok.Count) de $($candidatos.Count) computadores inventariados" + $(if ($recusadas.Count -gt 0) { " | $($recusadas.Count) recusaram a credencial" } else { '' })
        if ($recusadas.Count -gt 0) {
            Add-Alerta 'Alta' 'Estações' "$($recusadas.Count) computador(es) recusaram a credencial" ((($recusadas.Computador | ForEach-Object { "$_".Split('.')[0] }) -join ', ') + " | Conta usada: $($script:Resumo['Conta usada nas estações']). Conferir se ela é administradora local nessas máquinas (domínio fora do grupo Admins. locais, UAC remoto, GPO), ou refazer a coleta com outra conta (-PedirCredencial)")
        }
        foreach ($e in $ok | Where-Object { $_.LivreCPct -ne $null -and $_.LivreCPct -lt 10 }) { Add-Alerta 'Média' 'Estações' "Pouco espaço em $($e.Computador)" "$($e.LivreCPct)% livre no C:" }
        foreach ($e in $ok | Where-Object { $_.MemoriaGB -lt 7.5 -and $_.SO -notmatch 'Server' }) { Add-Alerta 'Baixa' 'Estações' "Pouca memória em $($e.Computador)" "$($e.MemoriaGB) GB" }
        foreach ($e in $ok | Where-Object { $_.TipoDisco -match 'HDD' -and $_.SO -notmatch 'Server' }) { Add-Alerta 'Baixa' 'Estações' "Disco mecânico (HDD) em $($e.Computador)" 'Candidato a troca por SSD' }

        # Cobertura de antivírus (AV.5, AV.6 e AV.7 do checklist; REQ-021 exige 100%).
        $semAv = @($ok | Where-Object { (-not $_.Antivirus -or $_.Antivirus -in 'N/D', '') -and $_.DefenderTempoReal -ne $true })
        $cobertura = if ($ok.Count -gt 0) { [math]::Round((($ok.Count - $semAv.Count) / $ok.Count) * 100, 0) } else { 0 }
        $script:Resumo['Cobertura de antivírus'] = "$cobertura% ($($ok.Count - $semAv.Count) de $($ok.Count) inventariados)"
        if ($semAv.Count -gt 0) {
            Add-Alerta 'Alta' 'Estações' "$($semAv.Count) computador(es) sem antivírus ativo" ((($semAv.Computador) -join ', ') + ' | REQ-021 exige proteção em 100% das estações e servidores')
        }
        # Maioria "Sem acesso" = a conta não é administradora nas estações. Sem isso o inventário não sai.
        $semAcesso = @($script:Estacoes | Where-Object { $_.Status -like 'Sem acesso*' })
        if ($semAcesso.Count -ge 3 -and $semAcesso.Count -ge ($candidatos.Count / 2)) {
            Add-Alerta 'Alta' 'Estações' "$($semAcesso.Count) de $($candidatos.Count) estações negaram acesso remoto" "A conta $($script:Resumo['Conta usada nas estações']) não é administradora nessas máquinas (WinRM e DCOM negados). Rodar a coleta como Admins. do domínio para obter SO, antivírus, BitLocker, patch e administradores de cada estação"
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
            Add-Alerta 'Info' 'Criptografia' "$($criptoNaoLida.Count) computador(es) sem leitura do BitLocker" 'Consulta exige privilégio de administrador no equipamento; rodar a coleta como administrador do domínio'
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
        if ($SoftwareEstacoes -and $script:SoftwaresEstacoes.Count -gt 0) {
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

$ordemSeveridade = @{ 'Alta' = 0; 'Média' = 1; 'Baixa' = 2; 'Info' = 3 }
$alertasOrdenados = @($script:Alertas | Sort-Object { $ordemSeveridade[$_.Severidade] }, Area)
Save-Dados 'alertas' $alertasOrdenados 'Pontos de atenção encontrados'
Save-Dados 'erros_coleta' $script:Erros 'Etapas que falharam na coleta'

$script:Resumo['Tempo de coleta'] = '{0:N0} minutos' -f ((Get-Date) - $script:Inicio).TotalMinutes
[pscustomobject]@{ Resumo = $script:Resumo; Alertas = $alertasOrdenados; Dispositivos = $script:Hosts; Computadores = $script:Estacoes; Erros = $script:Erros } |
    ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $script:PastaSaida 'resumo.json') -Encoding UTF8

# Marca da Nextec embutida em base64: o relatorio sai com identidade visual em qualquer maquina,
# sem depender de arquivo externo. Logo clara (cabecalho escuro) e emblema (favicon).
$script:LogoBase64    = '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'
$script:EmblemaBase64 = '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'
# Recorte da base IEEE de fabricantes (11 mil prefixos dos fabricantes comuns em cliente), gzip em base64.
# Garante nome de fabricante offline em qualquer maquina, sem depender de oui.csv ao lado nem de internet.
$script:OuiEmbutidoGz = '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'

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
            $patchClasse = if ($null -ne $e.DiasSemPatch -and [int]$e.DiasSemPatch -gt 60) { 'aviso' } elseif ($null -ne $e.DiasSemPatch) { 'ok' } else { 'neutro' }
            $patchTexto = if ($null -ne $e.DiasSemPatch) { "Patch há $($e.DiasSemPatch) d" } else { 'Patch n/d' }
            $admins = @("$($e.AdministradoresLocais)" -split ';\s*' | Where-Object { $_ -and $_ -ne 'N/D' })
            [void]$sb.Append("<div class='pc'><h4>$(ConvertTo-HtmlSeguro $nome) $(& $badge 'online' 'ok')</h4>")
            [void]$sb.Append("<div class='l'><b>$(ConvertTo-HtmlSeguro $e.SO)</b> $(& $badge $supTexto $supClasse)</div>")
            [void]$sb.Append("<div class='l'>$(ConvertTo-HtmlSeguro "$($e.Fabricante) $($e.Modelo)".Trim()) &middot; série $(ConvertTo-HtmlSeguro $e.NumeroSerie)</div>")
            [void]$sb.Append("<div class='l'>RAM <b>$($e.MemoriaGB) GB</b> &middot; disco <b>$(ConvertTo-HtmlSeguro $e.TipoDisco)</b> &middot; C: <b>$($e.LivreCPct)%</b> livre</div>")
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
<p class="legenda">Um cartão por máquina inventariada. Os dados completos (16 colunas) estão em <b>inventario_computadores.csv</b>.</p>
$(New-ComputadoresHtml $script:Estacoes)

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
try {
    Compress-Archive -Path (Join-Path $script:PastaSaida '*') -DestinationPath $zip -Force
    Write-Log "Pacote compactado: $zip"
} catch { Write-Log "Não foi possível compactar: $($_.Exception.Message)" 'AVISO' }

Write-Host ''
Write-Host "Concluído. Alertas: $contagem" -ForegroundColor Green
Write-Host "Resumo: $caminhoHtml" -ForegroundColor Green
Write-Host "Envie o arquivo $zip para análise." -ForegroundColor Green

# Segura a janela no fim quando há alguém olhando (duplo clique); em agendador e automação, não trava.
if ($Automatico) {
    # Sem perguntas: abre a pasta com o relatório e deixa a janela por alguns segundos para o técnico ler o caminho.
    try { Start-Process explorer.exe -ArgumentList "/select,`"$caminhoHtml`"" } catch { }
    Write-Host ''
    Write-Host 'Esta janela fecha sozinha em 20 segundos.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
} elseif (Test-TemTeclado) {
    Write-Host ''
    if ((Read-Preenchimento 'Abrir o relatório agora? (S/N)' 'S') -match '^(s|y)') { try { Start-Process $caminhoHtml } catch { } }
    Read-Host 'Pressione Enter para fechar' | Out-Null
}
