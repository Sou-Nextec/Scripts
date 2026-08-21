#requires -version 5.1
<#
.SYNOPSIS
    Nextec NOC Monitoring Installer para Windows.

.DESCRIPTION
    Instala ou atualiza o Grafana Alloy em Windows Server, Windows 10 e Windows 11.

    O instalador:
      1. valida execução como Administrador;
      2. permite alteração dinâmica do destino NOC;
      3. detecta instalação existente e oferece menu de manutenção;
      4. detecta Windows Server ou estação Windows 10/11;
      5. detecta funções e serviços compatíveis;
      6. coleta identificação e credenciais do NOC;
      7. exibe resumo e valida conectividade;
      8. instala ou atualiza o Grafana Alloy;
      9. grava credenciais fora do config.alloy;
     10. gera config.alloy documentado;
     11. executa alloy fmt e alloy validate;
     12. reinicia o serviço somente se a configuração for válida;
     13. executa rollback se houver falha depois de alterar a configuração.

.NOTES
    Arquivo padrão Nextec:
      install-nextec-monitoring-windows-v2.ps1

    Requisitos:
      PowerShell 5.1+
      Windows 10+ ou Windows Server 2016+
      Arquitetura AMD64/x64
      Execução como Administrador

    Codificação: UTF-8 com BOM.

    -------------------------------------------------------------------------
    HISTÓRICO
    -------------------------------------------------------------------------
    2.10.0 Falha em capacidade opcional (Blackbox, SNMP, Speedtest) deixa de
           reverter a instalação inteira: a capacidade é desligada, a
           instalação continua e o resumo final lista as pendências. As
           verificações pós-instalação também deixaram de causar rollback.
           Código de saída 2 significa instalado com pendências.

    2.9.0  Intervalo de sondagem do Blackbox passa a ser configurável (padrão
           60s, mínimo 5s), com o timeout derivado do intervalo. Piso do
           Speedtest reduzido para 5 minutos, com confirmação e estimativa de
           consumo abaixo de 15 minutos.

    2.8.0  Apresentação no console: títulos de etapa com régua, campos em
           colunas alinhadas e valores destacados por cor. A etapa de Internet
           passa a explicar que o Speedtest mede velocidade e não
           disponibilidade, avisa o custo de intervalos curtos e oferece criar
           os alvos ICMP de disponibilidade (gateway, 1.1.1.1, 8.8.8.8).

    2.7.0  Menu de reconfiguração: "Internet (Speedtest)" e "Exporters
           adicionais" passam a aparecer sempre. Internet só era oferecida a
           host que já fosse coletor, e era justamente por ela que se ativava
           o primeiro; exporters não tinham editor nenhum.

    2.6.0  Auto elevação: o instalador reabre a si mesmo com privilégio de
           Administrador em vez de recusar a execução, repassando os
           parâmetros por EncodedCommand e propagando o código de saída.
           Correções: atributo do coletor textfile do exporter Windows
           (rejeitava a configuração inteira quando o Speedtest estava
           ligado), BOM no .prom do Speedtest, reconfiguração de host com
           SNMP pelo menu, preservação das credenciais SNMP existentes,
           acúmulo de fabricantes SNMP no mesmo host, backup e rollback dos
           arquivos auxiliares e identificação em cabeçalho estruturado.

    2.5.0  SNMP sem digitação: o módulo é lido do próprio snmp.yml e escolhido
           pela versão SNMP, e a credencial passa a ser montada pelo
           instalador em snmp-auth.yml. Os defaults antigos ("system,if_mib"
           e "public_v2") não existiam em nenhum arquivo do repositório e
           geravam alvo que nunca coletava.

    2.4.0  SNMP: opção de baixar o snmp.yml homologado direto do repositório
           Sou-Nextec/Scripts (por fabricante), sem depender de o operador
           já ter uma cópia local do arquivo.

    2.3.0  Correção da causa raiz do "configuração não vai para o disco":
           Invoke-AlloyCommand não citava caminhos com espaço ao chamar o
           CLI do Alloy, e Update-AlloyBinaryOnly não preservava o
           config.alloy da Nextec através da reinstalação do binário.
           Também corrigidos: rollback de registro que indexava
           [pscustomobject] por colchete, leitura de Environment/Arguments
           do registro sob StrictMode, colisão entre $script:Cliente e o
           parâmetro -Cliente, AllowEmptyCollection faltando em
           Get-NextecConfiguration, parser de configuração atual que
           perdia alvos de Blackbox/SNMP depois de "alloy fmt", e bloco
           "network" do exporter Windows trocado por "net" (nome real do
           bloco no Alloy; o anterior nunca teve efeito algum no filtro).

    2.2.0  Correção da geração do config.alloy, aderência aos documentos 02, 03
           e 04, redução do custo de coleta e ACL nas credenciais do registro.
           Detalhes de cada decisão estão comentados no ponto do código.

    2.1.3  Versão anterior.
#>

[CmdletBinding()]
param(
    # Nome do cliente para identificação no NOC (será normalizado para 'slug').
    [string]$Cliente,

    # Ambiente de monitoramento.
    [ValidateSet("producao","homologacao","desenvolvimento","backup","teste")]
    [string]$Ambiente = "producao",

    # Local físico ou lógico do ativo (ex: matriz, filial_sp, datacenter_aws).
    [string]$Local = "matriz",

    # Nível de criticidade do ativo monitorado.
    [ValidateSet("critico","alto","medio","baixo")]
    [string]$Criticidade = "alto",

    # Define o modo de operação do Alloy. 'auto' decide entre 'servidor' e 'estacao'.
    [ValidateSet("auto","servidor","estacao","collector","servidor_collector","estacao_collector")]
    [string]$Modo = "auto",

    # [Modo Silencioso] Habilita a coleta de logs do sistema (Application, System), apenas Critical e Error.
    [switch]$EnableLogs,
    # [Modo Silencioso] Inclui tambem os eventos de nivel Warning nos canais Application e System.
    # ATENCAO: Warning e o maior gerador de ruido do Windows (Perflib, DCOM, WMI, GPO, spooler).
    # Em servidor com aplicacao legada isso pode multiplicar por 10 o volume enviado ao Loki.
    [switch]$EnableLogWarnings,
    # [Modo Silencioso] Habilita a coleta de logs de segurança (autenticação).
    [switch]$EnableSecurityLogs,
    # [Modo Silencioso] Habilita a função de collector SNMP.
    [switch]$EnableSnmp,
    # [Modo Silencioso] Habilita a função de collector Blackbox (conectividade).
    [switch]$EnableBlackbox,
    # [Modo Silencioso] Habilita a coleta de exporters customizados.
    [switch]$EnableExporters,
    # [Modo Silencioso] Habilita o monitoramento de Internet (Speedtest Ookla):
    # disponibilidade, latência, download e upload. Instala e configura tudo
    # sozinho, sem passo manual. Exige -Modo collector, servidor_collector ou
    # estacao_collector.
    [switch]$EnableInternet,
    # [Modo Silencioso] Intervalo em minutos entre execuções do teste de
    # velocidade. Padrão 30min: um link residencial não deve ser saturado por
    # um teste de banda a cada poucos minutos.
    [ValidateRange(5, 1440)]
    [int]$InternetIntervalMinutes = 30,

    # [Modo Silencioso] Define um ou mais alvos para o Blackbox Exporter. Formato: "nome|endereco|modulo|tipo".
    [string[]]$BlackboxTarget = @(),
    # [Modo Silencioso] Caminho para o arquivo de configuração 'snmp.yml'.
    [string]$SnmpConfig = "",
    # [Modo Silencioso] Define um ou mais alvos para o SNMP Exporter. Formato: "nome|endereco|modulo|auth|tipo|os".
    [string[]]$SnmpTarget = @(),
    # [Modo Silencioso] Define um ou mais exporters customizados. Formato: "nome|host:porta|servico".
    [string[]]$CustomExporter = @(),

    # FQDN ou IP do servidor do NOC de destino. Pode ser alterado no modo interativo.
    [string]$NocTarget = "noc.nex.tec.br",

    # Executa o script sem interação, usando os parâmetros fornecidos e variáveis de ambiente para credenciais.
    [switch]$Silent
)

# Guardado aqui, na raiz do script, porque $PSBoundParameters só reflete os
# parâmetros recebidos por ESTE invocation quando lido neste escopo. É usado
# mais abaixo para reabrir automaticamente em PowerShell 64 bits, repassando
# exatamente os mesmos parâmetros que o operador informou.
$script:OriginalBoundParameters = $PSBoundParameters

# Texto do próprio script, capturado aqui porque dentro de uma função
# $MyInvocation passa a ser o da função. Serve para reabrir o instalador
# quando ele foi executado sem arquivo em disco, pelo one-liner.
$script:OriginalScriptText = ""
try {
    $script:OriginalScriptText = [string]$MyInvocation.MyCommand.ScriptBlock
}
catch {
    $script:OriginalScriptText = ""
}

$script:RelaunchTempScript = ""
$script:Relaunched = $false
$script:ExitCode = 0

# Etapas opcionais que falharam. A instalação segue sem elas e o resumo final
# lista o que ficou pendente, para o técnico resolver depois sem precisar
# reinstalar o host inteiro.
$script:EtapasComFalha = @()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Definido aqui (bem cedo) e não só dentro de Install-OrUpdateAlloy, porque
# Test-NocConnectivity faz uma chamada HTTPS ANTES disso. Em Windows Server
# mais antigo sem certas atualizações, o .NET Framework pode não negociar
# TLS 1.2 por padrão, fazendo a pré-validação de conectividade falhar por
# handshake TLS mesmo com o NOC de destino totalmente acessível.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ==============================================================================
# CONSTANTES E VARIÁVEIS GLOBAIS
# ==============================================================================

$InstallerVersion = "2.10.0"

# Caminhos padrão de uma instalação nova. Resolve-AlloyInstallation ajusta
# estes valores quando encontra uma instalação existente em outro lugar.
#
# O instalador do Alloy para Windows entrega dois executáveis na mesma pasta:
#   alloy-windows-amd64.exe          binário CLI, é o que aceita run/fmt/validate
#   alloy-service-windows-amd64.exe  wrapper registrado no Service Control Manager
# Não existe "alloy.exe". Todo comando do instalador precisa do CLI; o wrapper
# só sabe se comportar como serviço.
$AlloyDir = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"
$AlloyExe = Join-Path $AlloyDir "alloy-windows-amd64.exe"
$ConfigFile = Join-Path $AlloyDir "config.alloy"
$BlackboxFile = Join-Path $AlloyDir "blackbox.yml"
$SnmpFile = Join-Path $AlloyDir "snmp.yml"

# Credencial SNMP em arquivo separado do módulo do fabricante. O snmp.yml do
# repositório traz só a seção "modules"; a seção "auths" é específica do
# cliente e nunca entra no repositório. O Alloy junta os dois em memória.
$SnmpAuthFile = Join-Path $AlloyDir "snmp-auth.yml"

# Repositório Nextec com os snmp.yml homologados por fabricante. Usado para
# baixar o arquivo certo sem depender de o operador já ter uma cópia local.
$NextecSnmpRepoBaseUrl = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/snmp"
$NextecSnmpVendors = [ordered]@{
    "1" = @{ Label = "pfSense"; File = "pfsense.yml" }
    "2" = @{ Label = "Fortigate"; File = "fortigate.yml" }
    "3" = @{ Label = "Mikrotik"; File = "mikrotik.yml" }
}

# Nome do serviço Windows. Resolve-AlloyInstallation substitui pelo nome real
# quando o serviço existe com outro nome.
$script:AlloyServiceName = "Alloy"

$ProgramDataDir = Join-Path $env:ProgramData "GrafanaLabs\Alloy"
$StorageDir = Join-Path $ProgramDataDir "data"
$BackupDir = Join-Path $ProgramDataDir "nextec-backup"
$LogDir = Join-Path $ProgramDataDir "nextec-installer"

# Internet (Speedtest Ookla). O binário e o wrapper ficam fora do diretório
# do Alloy para sobreviver a uma atualização/reinstalação "binário só"; a
# pasta "textfile" é o diretório que o coletor "textfile" do windows_exporter
# varre, então só pode conter o .prom do speedtest, nada mais.
$SpeedtestDir = Join-Path $ProgramDataDir "nextec-speedtest"
$SpeedtestExe = Join-Path $SpeedtestDir "speedtest.exe"
$SpeedtestMetricsDir = Join-Path $SpeedtestDir "textfile"
$SpeedtestMetricsFile = Join-Path $SpeedtestMetricsDir "nextec_speedtest.prom"
$SpeedtestRunnerScript = Join-Path $SpeedtestDir "Invoke-NextecSpeedtest.ps1"
$SpeedtestTaskName = "NextecSpeedtest"
# Versão pinada do Ookla Speedtest CLI. Checar a versão mais recente em
# https://www.speedtest.net/apps/cli antes de trocar; um ZIP inexistente
# nessa URL derruba a instalação do zero, não fica em modo degradado.
$SpeedtestCliVersion = "1.2.0"
$SpeedtestCliUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-{0}-win64.zip" -f $SpeedtestCliVersion

$RegistryPath = "HKLM:\SOFTWARE\GrafanaLabs\Alloy"
$LatestInstallerUrl = "https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe"

$script:ConfigBackup = $null
$script:AuxiliaryBackups = @()
$script:RegistryBackup = $null
$script:ConfigChanged = $false
$script:TranscriptStarted = $false
$script:NocHost = $NocTarget
$script:RemoteWriteUrl = ""
$script:LokiUrl = ""
$script:InstallerLog = ""

# Valores padrão de todas as demais variáveis de estado usadas ao longo do
# instalador. Com Set-StrictMode -Version 3.0, ler uma variável de script
# antes de ela ser atribuída lança erro. Isso importa especialmente para os
# fluxos de manutenção (que não passam pela identificação/credenciais
# completas) e para o modo -Silent, que pulam etapas do fluxo interativo.
# $Cliente já vem do parâmetro -Cliente do script (linha ~49). Atribuir ""
# aqui apagaria qualquer valor recebido na linha de comando; o padrão certo
# é copiar o parâmetro para a variável de estado, como já é feito abaixo
# para Ambiente, Local e Criticidade.
$script:Cliente = $Cliente
$script:HostLabel = ""
$script:Ambiente = $Ambiente
$script:Local = $Local
$script:Criticidade = $Criticidade
$script:MonitorHost = $false
$script:Collector = $false
$script:ResolvedMode = ""
$script:TipoLabel = ""
$script:DetectedHostFeatures = @()
$script:SelectedHostFeatureKeys = [string[]]@()
$script:EnableLogsResolved = $false
$script:EnableLogWarningsResolved = $false
$script:EnableSecurityLogsResolved = $false
$script:EnableSnmpResolved = $false
$script:EnableBlackboxResolved = $false
$script:EnableExportersResolved = $false
$script:SelectedExporterKeys = [string[]]@()
$script:EnableInternetResolved = $false
$script:InternetIntervalMinutesResolved = 30

# Intervalo de sondagem dos alvos Blackbox. 60s é o padrão histórico e serve
# para "o site está no ar". Para medir disponibilidade de link, latência e
# jitter com alguma resolução, o intervalo precisa cair para 10s ou 15s.
$script:BlackboxIntervalSecondsResolved = 60
$script:BlackboxTargets = @()
$script:SnmpTargets = @()
$script:SnmpSourceFile = $null
$script:SnmpAuthBlocks = @()
$script:CustomExporters = @()
$script:RwUsername = ""
$script:RwPassword = ""
$script:LokiUsername = ""
$script:LokiPassword = ""

# ==============================================================================
# SAÍDA
# ==============================================================================

$script:LarguraConsole = 64

function Write-Step {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ""
    Write-Host ("  {0}" -f $Message.ToUpperInvariant()) -ForegroundColor Cyan
    Write-Host ("  {0}" -f ("-" * [Math]::Min($script:LarguraConsole, $Message.Length + 4))) -ForegroundColor DarkCyan
}

function Write-Section {
    # Subtítulo dentro de uma etapa, para separar blocos de informação.
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ""
    Write-Host ("  {0}" -f $Message) -ForegroundColor White
}

function Write-Field {
    <#
        Par rótulo/valor com colunas alinhadas. Mantém o alinhamento mesmo
        quando o rótulo tem acento, porque o padding é aplicado depois da
        formatação e conta caracteres, não bytes.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray,
        [int]$Width = 16
    )

    $rotulo = ("{0}:" -f $Label).PadRight($Width)
    Write-Host ("    {0}" -f $rotulo) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-Ok {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ("[OK] {0}" -f $Message) -ForegroundColor Green
}

function Write-Info {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ("[INFO] {0}" -f $Message) -ForegroundColor Gray
}

function Write-Warn {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ("[AVISO] {0}" -f $Message) -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host ("[ERRO] {0}" -f $Message) -ForegroundColor Red
}

function Wait-NextecOperator {
    <#
        Espera o operador antes de devolver o controle.

        Serve para o caso em que o console foi criado só para este script (duplo
        clique, atalho, ou a janela de 64 bits que o próprio instalador abre):
        nessas situações a janela fecha no instante em que o script retorna.
        Não faz nada quando não há console interativo, para não travar execução
        via RMM.
    #>
    if ($Silent) {
        return
    }

    if (-not (Test-NextecInteractiveConsole)) {
        return
    }

    Write-Host ""
    Write-Host "Pressione ENTER para fechar." -ForegroundColor DarkGray

    try {
        [void](Read-Host)
    }
    catch {
        # Sem console utilizável para ler entrada. Não há o que fazer além de
        # seguir: forçar uma pausa aqui travaria execução automatizada.
        Write-Verbose ("Não foi possível aguardar o operador: {0}" -f $_.Exception.Message)
    }
}

function Show-Banner {
    if ($Silent) {
        return
    }

    # Alguns hosts de RMM não implementam RawUI, e ali Clear-Host lança. Com
    # $ErrorActionPreference = "Stop" isso derrubaria o script na primeira
    # linha útil, com uma mensagem que não tem relação com o problema real.
    try {
        Clear-Host
    }
    catch {
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "       NEXTEC NOC MONITORING INSTALLER, WINDOWS" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ("Versão:  {0}" -f $InstallerVersion)
    if (-not [string]::IsNullOrEmpty($script:NocHost)) {
        Write-Host ("Destino: {0}" -f $script:NocHost)
    }
    Write-Host ""
}

# ==============================================================================
# LOG
# ==============================================================================

function Initialize-Logging {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $logPath = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    try {
        Start-Transcript -Path $logPath -Append | Out-Null
        $script:TranscriptStarted = $true
        $script:InstallerLog = $logPath
    }
    catch {
        $script:InstallerLog = $logPath
        Write-Warn ("Não foi possível iniciar transcript: {0}" -f $_.Exception.Message)
    }
}

function Stop-Logging {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # O transcript pode já ter sido encerrado por outro ponto do fluxo.
            # Falhar aqui não deve impedir o script de terminar normalmente.
            Write-Verbose ("Stop-Transcript falhou: {0}" -f $_.Exception.Message)
        }

        $script:TranscriptStarted = $false
    }
}

# ==============================================================================
# UTILITÁRIOS
# ==============================================================================

function Invoke-NextecOptionalStep {
    <#
        Executa uma etapa que não é essencial para o host ser monitorado.

        Falha ao baixar o Speedtest CLI ou ao obter um snmp.yml não justifica
        desfazer a instalação inteira: o host continua entregando CPU,
        memória, disco, serviços e logs. O que a falha exige é desligar a
        capacidade correspondente, senão o config.alloy sai referenciando um
        arquivo que não existe e a validação derruba tudo mais adiante.

        -AoFalhar recebe o scriptblock que desliga a capacidade.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Nome,
        [Parameter(Mandatory=$true)][scriptblock]$Acao,
        [scriptblock]$AoFalhar
    )

    try {
        & $Acao
        return $true
    }
    catch {
        $mensagem = $_.Exception.Message

        $script:EtapasComFalha += [pscustomobject]@{
            Nome = $Nome
            Erro = $mensagem
        }

        Write-Host ""
        Write-Warn ("{0} não pôde ser configurado: {1}" -f $Nome, $mensagem)

        if ($null -ne $AoFalhar) {
            & $AoFalhar
        }

        Write-Info "A instalação continua sem esse item; o resumo final lista o que ficou pendente."
        Write-Host ""

        return $false
    }
}

function Invoke-NextecVerification {
    <#
        Executa uma verificação pós-instalação. Falha aqui é diagnóstico, não
        motivo para rollback: a configuração já está no disco e válida, e o
        serviço já subiu. Reverter por causa de um teste de ingestão que não
        respondeu a tempo destruiria uma instalação que está correta.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Nome,
        [Parameter(Mandatory=$true)][scriptblock]$Acao
    )

    try {
        & $Acao
    }
    catch {
        $script:EtapasComFalha += [pscustomobject]@{
            Nome = $Nome
            Erro = $_.Exception.Message
        }

        Write-Warn ("{0}: {1}" -f $Nome, $_.Exception.Message)
    }
}

function Test-NextecIsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    # Rede de segurança dentro do processo que vai instalar de fato. A decisão
    # de elevar acontece antes, no despacho do script.
    if (-not (Test-NextecIsAdministrator)) {
        throw "Execute este script em uma sessão do PowerShell aberta como Administrador."
    }
}

function Test-NextecProcessNeedsBitnessRelaunch {
    # "Windows PowerShell (x86)" é um processo de 32 bits. Em Windows Server
    # de 64 bits, Get-WindowsFeature (usado para detectar DNS, File Server,
    # IIS etc.) não existe nesse processo, então a detecção de funções do
    # servidor fica incompleta em silêncio.
    return ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
}

function ConvertTo-NextecPowerShellLiteral {
    <#
        Converte um valor para a sua representação literal em PowerShell,
        preservando tipo. Usado para reconstruir os parâmetros na sessão nova.

        Passar parâmetros pela linha de comando com -File não funciona para
        array: "-Nome a b" é recusado pelo binder, "-Nome a -Nome b" é
        recusado como parâmetro repetido e "-Nome a,b" chega como uma única
        string literal. Reconstruir um hashtable e aplicá-lo por splatting
        resolve os três casos e ainda dispensa escape de aspas e de barra
        invertida final.
    #>
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [switch]) {
        if ($Value.IsPresent) { return '$true' }
        return '$false'
    }

    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $Value))
    }

    if ($Value -is [System.Array]) {
        $items = @(@($Value) | ForEach-Object { ConvertTo-NextecPowerShellLiteral -Value $_ })

        if ($items.Count -eq 0) {
            return '@()'
        }

        return ('@({0})' -f ($items -join ","))
    }

    # Aspas simples não interpolam nada; o único escape necessário é a própria
    # aspa simples, duplicada.
    return ("'{0}'" -f ([string]$Value).Replace("'", "''"))
}

function Get-NextecRelaunchScriptPath {
    <#
        Devolve um caminho em disco de onde a sessão nova pode carregar este
        script.

        Executado pelo one-liner (irm mais scriptblock) não existe arquivo:
        $PSCommandPath fica vazio. Nesse caso o próprio texto do script é
        gravado em ProgramData, que o processo elevado enxerga, ao contrário
        do %TEMP% do usuário. O mesmo vale quando o script está numa unidade
        mapeada ou em UNC, que o token elevado normalmente não enxerga.
    #>
    $origem = [string]$PSCommandPath
    $precisaMaterializar = [string]::IsNullOrWhiteSpace($origem)

    if (-not $precisaMaterializar) {
        $raiz = [IO.Path]::GetPathRoot($origem)

        if ($origem.StartsWith("\\") -or [string]::IsNullOrWhiteSpace($raiz)) {
            $precisaMaterializar = $true
        }
        elseif ([IO.DriveInfo]::new($raiz).DriveType -ne [IO.DriveType]::Fixed) {
            $precisaMaterializar = $true
        }
    }

    if (-not $precisaMaterializar) {
        return $origem
    }

    if ([string]::IsNullOrWhiteSpace($script:OriginalScriptText)) {
        throw "Não foi possível recuperar o texto deste script para reabrir a sessão. Salve o arquivo .ps1 em disco local e execute-o novamente."
    }

    $destinoDir = Join-Path $env:ProgramData "Nextec\installer"
    New-Item -ItemType Directory -Path $destinoDir -Force | Out-Null

    $destino = Join-Path $destinoDir "install-nextec-monitoring-windows.ps1"

    # UTF-8 com BOM: o Windows PowerShell 5.1 lê arquivo sem BOM como ANSI e
    # os acentos das mensagens do instalador chegariam corrompidos.
    [IO.File]::WriteAllText($destino, $script:OriginalScriptText, (New-Object Text.UTF8Encoding($true)))

    $script:RelaunchTempScript = $destino
    return $destino
}

function Invoke-NextecRelaunch {
    <#
        Reabre o instalador numa sessão adequada e devolve o código de saída
        dela.

        Dois motivos levam a relançar: processo de 32 bits num Windows de 64
        bits, e falta de elevação. O tratamento é o mesmo, então vale uma
        função só.
    #>
    param(
        [Parameter(Mandatory=$true)][System.Collections.IDictionary]$BoundParameters,
        [switch]$NeedsBitness,
        [switch]$NeedsElevation
    )

    if ($NeedsElevation -and $Silent) {
        # Elevar em automação abriria um prompt de UAC que ninguém responde, e
        # o processo ficaria pendurado até alguém notar. 740 é o
        # ERROR_ELEVATION_REQUIRED do Windows, que o RMM sabe interpretar.
        Write-Fail "Este script precisa de privilégio administrativo e o modo silencioso não pode responder ao prompt do UAC."
        Write-Info "Execute o agente como SYSTEM ou como administrador local."
        return 740
    }

    # O caminho canônico é System32 mesmo quando o processo atual é de 32
    # bits: quem cria o processo elevado é o serviço AppInfo, de 64 bits, para
    # o qual o alias Sysnative não existe. Sysnative serve apenas para este
    # processo conferir que o binário está lá.
    $sysnative = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $system32 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"

    if ($NeedsBitness) {
        if (-not (Test-Path -LiteralPath $sysnative)) {
            throw ("PowerShell de 32 bits detectado num Windows de 64 bits, e o PowerShell de 64 bits não foi encontrado em {0}. Feche esta janela e abra 'Windows PowerShell' (sem '(x86)') como Administrador." -f $sysnative)
        }

        Write-Warn "PowerShell de 32 bits detectado num Windows de 64 bits."
    }

    if ($NeedsElevation) {
        Write-Warn "Esta sessão não está elevada."
    }

    $scriptPath = Get-NextecRelaunchScriptPath
    $literais = New-Object System.Collections.Generic.List[string]

    foreach ($key in $BoundParameters.Keys) {
        $literais.Add(("  {0} = {1}" -f $key, (ConvertTo-NextecPowerShellLiteral -Value $BoundParameters[$key])))
    }

    $hashtable = "@{}"
    if ($literais.Count -gt 0) {
        $hashtable = "@{" + [Environment]::NewLine + ($literais -join [Environment]::NewLine) + [Environment]::NewLine + "}"
    }

    # -EncodedCommand em vez de -File: comando não é arquivo de script, então
    # escapa da Execution Policy vinda de GPO, que sobrepõe o -ExecutionPolicy
    # Bypass da linha de comando e faria a sessão nova morrer ao carregar.
    # A sessão elevada nasce em System32, não no diretório do operador, e aí
    # qualquer caminho relativo que ele tenha passado deixa de resolver.
    $diretorio = $env:SystemRoot
    try {
        if ($PWD.Provider.Name -eq "FileSystem") {
            $diretorio = $PWD.ProviderPath
        }
    }
    catch {
        $diretorio = $env:SystemRoot
    }

    $comando = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$($diretorio.Replace("'", "''"))'
`$parametros = $hashtable
`$global:LASTEXITCODE = 0
& '$($scriptPath.Replace("'", "''"))' @parametros
exit `$global:LASTEXITCODE
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($comando))

    $argumentos = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded)
    $executavel = if ($NeedsBitness) { $system32 } else { (Get-Process -Id $PID).Path }

    if ([string]::IsNullOrWhiteSpace($executavel)) {
        $executavel = $system32
    }

    Write-Info "Reabrindo o instalador em uma sessão com privilégio de Administrador..."

    try {
        $parametrosStart = @{
            FilePath = $executavel
            ArgumentList = $argumentos
            PassThru = $true
            Wait = $true
        }

        if ($NeedsElevation) {
            $parametrosStart["Verb"] = "RunAs"
        }
        else {
            $parametrosStart["NoNewWindow"] = $true
        }

        $processo = Start-Process @parametrosStart
    }
    catch {
        # ShellExecute devolve 1223 (ERROR_CANCELLED) quando o operador nega o
        # UAC. Vale distinguir de falha real para não mandar o técnico caçar
        # problema que não existe.
        if ($_.Exception.Message -match "cancel|1223") {
            throw "Elevação cancelada no prompt do UAC. Aceite o prompt ou abra o PowerShell como Administrador e rode de novo."
        }

        throw ("Falha ao reabrir o instalador com privilégio administrativo: {0}" -f $_.Exception.Message)
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:RelaunchTempScript)) {
            Remove-Item -LiteralPath $script:RelaunchTempScript -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -eq $processo) {
        throw "Não foi possível iniciar a sessão elevada do instalador."
    }

    return [int]$processo.ExitCode
}

function ConvertTo-Slug {
    param([Parameter(Mandatory=$true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = $Value.Trim().ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $result = $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
    $result = $result -replace "[^a-z0-9_-]+", "_"
    $result = $result -replace "_+", "_"
    $result = $result.Trim("_")

    return $result
}

function ConvertTo-AlloyEscapedString {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    return $escaped
}

function Read-Required {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = ""
    )

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Default)) {
            $value = Read-Host $Prompt
        }
        else {
            $value = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $Default
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Host ""
            return $value.Trim()
        }

        Write-Warn "Campo obrigatório."
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { "[S/n]" } else { "[s/N]" }

    while ($true) {
        $answer = Read-Host ("{0} {1}" -f $Prompt, $suffix)

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host ""
            return $Default
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            "s"   { Write-Host ""; return $true }
            "sim" { Write-Host ""; return $true }
            "y"   { Write-Host ""; return $true }
            "yes" { Write-Host ""; return $true }
            "n"   { Write-Host ""; return $false }
            "nao" { Write-Host ""; return $false }
            "não" { Write-Host ""; return $false }
            "no"  { Write-Host ""; return $false }
            default { Write-Warn "Responda S ou N." }
        }
    }
}

function Read-Choice {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string[]]$Options,
        [int]$Default = 1
    )

    Write-Host $Prompt -ForegroundColor White

    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
    }

    while ($true) {
        $choiceText = Read-Host ("Escolha [{0}]" -f $Default)

        if ([string]::IsNullOrWhiteSpace($choiceText)) {
            Write-Host ""
            return $Default
        }

        $number = 0
        if ([int]::TryParse($choiceText, [ref]$number)) {
            if ($number -ge 1 -and $number -le $Options.Count) {
                Write-Host ""
                return $number
            }
        }

        Write-Warn "Opção inválida."
    }
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory=$true)][Security.SecureString]$SecureValue)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Read-RequiredSecret {
    param([Parameter(Mandatory=$true)][string]$Prompt)

    # No PowerShell ISE (e outros hosts sem console real), Read-Host
    # -AsSecureString abre uma CAIXA DE DIÁLOGO gráfica separada em vez de
    # mascarar a digitação dentro do próprio console — comportamento do
    # host, não algo que o script controla. Isso faz a senha "sumir" da
    # tela do shell. Só usamos -AsSecureString (mascarado, inline) quando
    # há console real; nos demais casos caímos para Read-Host normal
    # (visível, mas ainda dentro do shell, sem popup).
    $useMaskedInput = Test-NextecInteractiveConsole

    while ($true) {
        if ($useMaskedInput) {
            $secureValue = Read-Host $Prompt -AsSecureString
            $plainValue = Convert-SecureStringToPlainText -SecureValue $secureValue
        }
        else {
            Write-Warn "Console sem suporte a entrada mascarada (ex.: ISE); a senha ficará visível ao digitar."
            $plainValue = Read-Host $Prompt
        }

        if ([string]::IsNullOrWhiteSpace($plainValue)) {
            Write-Warn "Campo obrigatório."
            continue
        }

        if ($plainValue -match "[`r`n]") {
            Write-Warn "A credencial não pode conter quebra de linha."
            continue
        }

        Write-Host ""
        return $plainValue
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutMs = 5000
    )

    $client = New-Object Net.Sockets.TcpClient

    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }

        $client.EndConnect($asyncResult)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Test-ListeningPort {
    param([Parameter(Mandatory=$true)][int]$Port)

    try {
        $command = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue

        if ($null -ne $command) {
            $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
            return ($connections.Count -gt 0)
        }

        $netstat = @(netstat -ano -p tcp 2>$null)
        $pattern = ":{0}\s+.*LISTENING" -f $Port
        return ($null -ne ($netstat | Select-String -Pattern $pattern | Select-Object -First 1))
    }
    catch {
        return $false
    }
}

# ==============================================================================
# DESTINO E MANUTENÇÃO
# ==============================================================================

function Set-NocDestination {
    $script:NocHost = $NocTarget

    if (-not $Silent) {
        Write-Host ""
        Write-Host "Destino: " -NoNewline -ForegroundColor White
        Write-Host $script:NocHost -ForegroundColor Cyan

        $action = Read-Host "?  ENTER para continuar ou D para alterar"

        if ($action.Trim().ToLowerInvariant() -eq "d") {
            while ($true) {
                $inputHost = Read-Host "?  Novo destino"
                $inputHost = $inputHost -replace "^https?://", ""
                $inputHost = $inputHost -replace "/.*$", ""
                $inputHost = $inputHost.Trim()

                if ($inputHost -match "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$") {
                    $script:NocHost = $inputHost.ToLowerInvariant()
                    Write-Ok ("Destino alterado para {0}." -f $script:NocHost)
                    break
                }
                Write-Warn "Destino inválido. Informe um hostname/FQDN, ex.: noc.cliente.com.br."
            }
        }
    }

    $script:RemoteWriteUrl = "https://$($script:NocHost)/api/v1/write"
    $script:LokiUrl = "https://$($script:NocHost)/loki/api/v1/push"
}

function Get-AlloyInstalledVersion {
    if (-not (Test-Path -LiteralPath $AlloyExe)) {
        return $null
    }

    try {
        $result = Invoke-AlloyCommand -Arguments @("--version")

        if ($result.ExitCode -ne 0) {
            return $null
        }

        return [string](($result.Output -split "`r?`n") | Select-Object -First 1)
    }
    catch {
        return $null
    }
}

function Show-MaintenanceStatus {
    $service = Get-AlloyService
    $version = Get-AlloyInstalledVersion
    $configExists = Test-Path -LiteralPath $ConfigFile

    $versionLabel = if ([string]::IsNullOrWhiteSpace($version)) { "instalado, versão não identificada" } else { $version }
    $serviceLabel = if ($null -ne $service) { $service.Status } else { "não encontrado" }
    $configLabel = if ($configExists) { $ConfigFile } else { "não encontrada" }

    Write-Info ("Binário Alloy: {0}" -f $versionLabel)
    Write-Info ("Caminho:       {0}" -f $AlloyExe)
    Write-Info ("Serviço:       {0} ({1})" -f $script:AlloyServiceName, $serviceLabel)
    Write-Info ("Configuração:  {0}" -f $configLabel)
}

function Update-AlloyBinaryOnly {
    <#
        Atualiza apenas o binário do Alloy, preservando a configuração.

        O instalador oficial reescreve HKLM:\SOFTWARE\GrafanaLabs\Alloy
        (Arguments e Environment), então as credenciais precisam ser lidas
        antes e regravadas depois. Sem isso o serviço volta sem
        NEXTEC_RW_USERNAME e NEXTEC_RW_PASSWORD.
    #>
    $preserved = Get-PreservedServiceEnvironment

    # O instalador oficial do Alloy sobrescreve C:\...\Alloy\config.alloy com
    # o exemplo padrão dele (não mantém o que já estava no disco). Sem copiar
    # o config.alloy da Nextec para fora do caminho de instalação antes, e
    # devolvê-lo depois, o binário atualiza mas a configuração inteira é
    # perdida e o serviço sobe com o exemplo do fabricante.
    $configSnapshot = $null

    if (Test-Path -LiteralPath $ConfigFile) {
        $configSnapshot = Join-Path $env:TEMP ("nextec-config-{0}.alloy" -f [Guid]::NewGuid().ToString("N"))
        Copy-Item -LiteralPath $ConfigFile -Destination $configSnapshot -Force
    }

    try {
        Install-OrUpdateAlloy
        Restore-ServiceEnvironment -Preserved $preserved

        if ($null -ne $configSnapshot) {
            Copy-Item -LiteralPath $configSnapshot -Destination $ConfigFile -Force
            Write-Ok "Configuração da Nextec restaurada após a reinstalação do binário."
        }
        else {
            Write-Warn "Não havia config.alloy anterior para preservar; a instalação seguiu com o exemplo padrão do Alloy."
        }

        Format-AndValidateAlloyConfiguration
        Restart-AlloyService
        Test-AlloyReadiness -Mandatory $false
    }
    finally {
        if ($null -ne $configSnapshot) {
            Remove-Item -LiteralPath $configSnapshot -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PreservedServiceEnvironment {
    # Lê do registro as variáveis que o instalador oficial sobrescreve, para
    # regravá-las após a reinstalação do binário.
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $null
    }

    $key = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue

    if ($null -eq $key) {
        return $null
    }

    # Get-ItemProperty só cria propriedades para os valores de registro que
    # existem de fato. Sob Set-StrictMode -Version 3.0, ler $key.Environment
    # quando o valor "Environment" nunca foi gravado lança "a propriedade
    # não foi encontrada", em vez de devolver $null. Get-Member confirma
    # presença sem disparar esse erro.
    $hasEnvironment = $null -ne ($key.PSObject.Properties.Match("Environment") | Select-Object -First 1)
    $hasArguments   = $null -ne ($key.PSObject.Properties.Match("Arguments") | Select-Object -First 1)

    return [pscustomobject]@{
        Environment = if ($hasEnvironment) { $key.Environment } else { $null }
        Arguments   = if ($hasArguments) { $key.Arguments } else { $null }
    }
}

function Restore-ServiceEnvironment {
    param($Preserved)

    if ($null -eq $Preserved) {
        Write-Warn "Não havia variáveis de ambiente do serviço para preservar."
        return
    }

    foreach ($name in @("Environment", "Arguments")) {
        $value = $Preserved.$name

        if ($null -ne $value) {
            New-ItemProperty -Path $RegistryPath -Name $name -PropertyType MultiString `
                -Value ([string[]]$value) -Force | Out-Null
        }
    }

    Protect-AlloyRegistryKey
    Write-Ok "Credenciais e argumentos do serviço preservados após a reinstalação."
}

function Get-AlloyConfigSection {
    <#
        Devolve o texto de um bloco de nível superior do config.alloy.

        O parser é posicional: acha o cabeçalho do bloco e conta chaves até
        fechar. Funciona porque o arquivo é gerado por este próprio instalador
        e depois normalizado por "alloy fmt", então a indentação é previsível.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory=$true)][string]$Header
    )

    $start = $Content.IndexOf($Header)

    if ($start -lt 0) {
        return ""
    }

    $depth = 0
    $i = $Content.IndexOf("{", $start)

    if ($i -lt 0) {
        return ""
    }

    for ($j = $i; $j -lt $Content.Length; $j++) {
        $ch = $Content[$j]

        if ($ch -eq "{") { $depth++ }
        elseif ($ch -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $Content.Substring($start, $j - $start + 1)
            }
        }
    }

    return ""
}

function Get-AlloyRelabelValues {
    <#
        Extrai os pares target_label/replacement de um bloco discovery.relabel
        e devolve como hashtable.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Section)

    $values = @{}

    # O nome da variável evita $matches de propósito: $matches é variável
    # automática do PowerShell, preenchida pelo operador -match, e sobrescrevê-la
    # afeta qualquer código que leia $matches depois nesta mesma sessão.
    $pairs = [Regex]::Matches(
        $Section,
        'target_label\s*=\s*"([^"]+)"\s*[\r\n]+\s*replacement\s*=\s*"([^"]*)"'
    )

    foreach ($pair in $pairs) {
        $values[$pair.Groups[1].Value] = $pair.Groups[2].Value
    }

    return $values
}

function Get-AlloyLabelValue {
    # Lê uma label de dentro de um bloco "labels = { ... }" ou "values = { ... }".
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Section,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $match = [Regex]::Match($Section, ('{0}\s*=\s*"([^"]*)"' -f [Regex]::Escape($Name)))

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ""
}

function Read-CurrentAlloyConfiguration {
    <#
        Lê o config.alloy instalado e devolve um objeto com o que está
        configurado hoje. Devolve $null quando não há configuração no disco.

        Só entende arquivos gerados por este instalador. Um config.alloy
        editado à mão pode ser lido parcialmente, e por isso quem chama precisa
        conferir o resumo com o operador antes de regravar.
    #>
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        return $null
    }

    $content = [IO.File]::ReadAllText($ConfigFile)

    $remoteWrite = Get-AlloyConfigSection -Content $content -Header 'prometheus.remote_write "nextec"'
    $lokiWrite   = Get-AlloyConfigSection -Content $content -Header 'loki.write "nextec"'
    $exporter    = Get-AlloyConfigSection -Content $content -Header 'prometheus.exporter.windows "system"'
    $labels      = Get-AlloyRelabelValues -Section (Get-AlloyConfigSection -Content $content -Header 'discovery.relabel "system_labels"')

    # O cabeçalho estruturado é a fonte preferida da identificação: existe em
    # todos os modos, inclusive coletor puro, onde o bloco system_labels nem
    # chega a ser gerado. O relabel continua valendo como leitura de
    # configurações geradas por versões anteriores.
    foreach ($cabecalho in [Regex]::Matches($content, '(?m)^\s*//\s*nextec:(?<chave>[a-z_]+)\s*=\s*(?<valor>.*?)\s*$')) {
        $chave = $cabecalho.Groups["chave"].Value
        $valor = $cabecalho.Groups["valor"].Value

        if ($chave -eq "versao" -or [string]::IsNullOrWhiteSpace($valor)) {
            continue
        }

        $labels[$chave] = $valor
    }

    $collectors = @()
    $collectorMatch = [Regex]::Match($exporter, 'enabled_collectors\s*=\s*\[([^\]]*)\]')
    if ($collectorMatch.Success) {
        $collectors = @([Regex]::Matches($collectorMatch.Groups[1].Value, '"([^"]+)"') |
                        ForEach-Object { $_.Groups[1].Value })
    }

    $urlMatch = [Regex]::Match($remoteWrite, 'url\s*=\s*"([^"]*)"')
    $remoteWriteUrl = if ($urlMatch.Success) { $urlMatch.Groups[1].Value } else { "" }

    $lokiMatch = [Regex]::Match($lokiWrite, 'url\s*=\s*"([^"]*)"')
    $lokiUrl = if ($lokiMatch.Success) { $lokiMatch.Groups[1].Value } else { "" }

    # Os componentes de log são nomeados por canal e severidade, então a
    # presença de cada um já diz o que está sendo coletado.
    $logComponents = @([Regex]::Matches($content, 'loki\.source\.windowsevent\s+"([^"]+)"') |
                       ForEach-Object { $_.Groups[1].Value })

    $blackboxTargets = @()
    $blackboxSection = Get-AlloyConfigSection -Content $content -Header 'prometheus.exporter.blackbox "network"'

    # Intervalo de sondagem vive no bloco de scrape, não no de exporter.
    $blackboxIntervalSeconds = 60
    $scrapeBlackbox = Get-AlloyConfigSection -Content $content -Header 'prometheus.scrape "blackbox"'
    $intervalMatch = [Regex]::Match($scrapeBlackbox, 'scrape_interval\s*=\s*"(\d+)s"')
    if ($intervalMatch.Success) {
        $blackboxIntervalSeconds = [int]$intervalMatch.Groups[1].Value
    }

    # O fechamento do bloco pode vir com dois espaços (como este instalador
    # gera) ou com TAB (como "alloy fmt" reformata depois da primeira
    # validação). "[ \t]*" aceita os dois; antes disso, qualquer configuração
    # que já tivesse passado por "alloy fmt" perdia os alvos na leitura.
    foreach ($match in [Regex]::Matches($blackboxSection, '(?s)target\s*\{(.*?)\n[ \t]*\}')) {
        $body = $match.Groups[1].Value
        $blackboxTargets += [pscustomobject]@{
            Name    = Get-AlloyLabelValue -Section $body -Name "name"
            Address = Get-AlloyLabelValue -Section $body -Name "address"
            Module  = Get-AlloyLabelValue -Section $body -Name "module"
            Type    = Get-AlloyLabelValue -Section $body -Name "tipo"
        }
    }

    $snmpTargets = @()
    $snmpSection = Get-AlloyConfigSection -Content $content -Header 'prometheus.exporter.snmp "network"'

    # Mesmo ajuste de indentação do bloco Blackbox acima.
    foreach ($match in [Regex]::Matches($snmpSection, '(?s)target\s+"([^"]+)"\s*\{(.*?)\n[ \t]*\}')) {
        $body = $match.Groups[2].Value
        $snmpTargets += [pscustomobject]@{
            Name    = $match.Groups[1].Value
            Address = Get-AlloyLabelValue -Section $body -Name "address"
            Module  = Get-AlloyLabelValue -Section $body -Name "module"
            Auth    = Get-AlloyLabelValue -Section $body -Name "auth"
            Type    = Get-AlloyLabelValue -Section $body -Name "tipo"
            Os      = Get-AlloyLabelValue -Section $body -Name "os"
        }
    }

    $customExporters = @()
    foreach ($match in [Regex]::Matches($content, 'discovery\.relabel\s+"(custom_\d+)"')) {
        $section = Get-AlloyConfigSection -Content $content -Header ('discovery.relabel "{0}"' -f $match.Groups[1].Value)
        $addressMatch = [Regex]::Match($section, '__address__"\s*=\s*"([^"]*)"')
        $relabels = Get-AlloyRelabelValues -Section $section

        $customExporters += [pscustomobject]@{
            Name    = $match.Groups[1].Value
            Target  = if ($addressMatch.Success) { $addressMatch.Groups[1].Value } else { "" }
            Service = if ($relabels.ContainsKey("servico")) { $relabels["servico"] } else { "" }
        }
    }

    # O textfile collector só é adicionado por este instalador para o
    # Speedtest, então a presença dele no config.alloy atual já identifica o
    # recurso como habilitado. O intervalo real fica na tarefa agendada, não
    # no config.alloy, então é lido de lá quando disponível.
    $enableInternet = ($collectors -contains "textfile")
    $internetIntervalMinutes = 30

    if ($enableInternet) {
        try {
            $existingTask = Get-ScheduledTask -TaskName $SpeedtestTaskName -ErrorAction SilentlyContinue

            if ($null -ne $existingTask) {
                $repetition = $existingTask.Triggers[0].Repetition.Interval

                if (-not [string]::IsNullOrWhiteSpace($repetition)) {
                    $parsedInterval = [Xml.XmlConvert]::ToTimeSpan($repetition)
                    $internetIntervalMinutes = [int]$parsedInterval.TotalMinutes
                }
            }
        }
        catch {
            # Mantém o padrão de 30 minutos se a tarefa não existir ou o
            # formato do gatilho não puder ser lido; não é motivo para falhar
            # a leitura de toda a configuração atual.
        }
    }

    return [pscustomobject]@{
        Cliente                  = if ($labels.ContainsKey("cliente")) { $labels["cliente"] } else { "" }
        HostLabel                = if ($labels.ContainsKey("host")) { $labels["host"] } else { "" }
        Ambiente                 = if ($labels.ContainsKey("ambiente")) { $labels["ambiente"] } else { "" }
        Local                    = if ($labels.ContainsKey("local")) { $labels["local"] } else { "" }
        Criticidade              = if ($labels.ContainsKey("criticidade")) { $labels["criticidade"] } else { "" }
        TipoLabel                = if ($labels.ContainsKey("tipo")) { $labels["tipo"] } else { "" }
        RemoteWriteUrl           = $remoteWriteUrl
        LokiUrl                  = $lokiUrl
        MonitorHost              = (-not [string]::IsNullOrWhiteSpace($exporter))
        Collectors               = $collectors
        LogComponents            = $logComponents
        EnableLogs               = @($logComponents | Where-Object { $_ -match "_(error|warning)$" }).Count -gt 0
        EnableWarnings           = @($logComponents | Where-Object { $_ -match "_warning$" }).Count -gt 0
        EnableSecurity           = ($logComponents -contains "security")
        BlackboxTargets          = $blackboxTargets
        SnmpTargets              = $snmpTargets
        CustomExporters          = $customExporters
        EnableInternet           = $enableInternet
        InternetIntervalMinutes  = $internetIntervalMinutes
        BlackboxIntervalSeconds  = $blackboxIntervalSeconds
        Modificado               = (Get-Item -LiteralPath $ConfigFile).LastWriteTime
        Arquivo                  = $ConfigFile
    }
}

function Read-ServiceCredentials {
    <#
        Lê as credenciais gravadas no registro do serviço.

        Permite regerar a configuração sem pedir a senha de novo ao operador.
        Devolve $null quando a chave não existe.
    #>
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $null
    }

    $key = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue

    # Mesmo motivo de Get-PreservedServiceEnvironment: sob StrictMode, ler
    # $key.Environment antes de confirmar que a propriedade existe lança erro
    # em vez de devolver $null, quando o registro ainda não tem esse valor.
    $hasEnvironment = ($null -ne $key) -and
        ($null -ne ($key.PSObject.Properties.Match("Environment") | Select-Object -First 1))

    if (-not $hasEnvironment -or $null -eq $key.Environment) {
        return $null
    }

    $values = @{}

    foreach ($entry in @($key.Environment)) {
        $separator = $entry.IndexOf("=")

        if ($separator -gt 0) {
            $values[$entry.Substring(0, $separator)] = $entry.Substring($separator + 1)
        }
    }

    return [pscustomobject]@{
        RwUsername   = if ($values.ContainsKey("NEXTEC_RW_USERNAME")) { $values["NEXTEC_RW_USERNAME"] } else { "" }
        RwPassword   = if ($values.ContainsKey("NEXTEC_RW_PASSWORD")) { $values["NEXTEC_RW_PASSWORD"] } else { "" }
        LokiUsername = if ($values.ContainsKey("NEXTEC_LOKI_USERNAME")) { $values["NEXTEC_LOKI_USERNAME"] } else { "" }
        LokiPassword = if ($values.ContainsKey("NEXTEC_LOKI_PASSWORD")) { $values["NEXTEC_LOKI_PASSWORD"] } else { "" }
    }
}

function Show-CurrentConfiguration {
    <#
        Mostra ao operador o que está configurado no host, sem precisar abrir o
        config.alloy.
    #>
    param([Parameter(Mandatory=$true)][object]$Configuration)

    $c = $Configuration

    Write-Step "Configuração atual"

    Write-Section "Identificação"
    Write-Field -Label "Cliente" -Value $c.Cliente -ValueColor White
    Write-Field -Label "Host" -Value $c.HostLabel -ValueColor White
    Write-Field -Label "Tipo" -Value $c.TipoLabel
    Write-Field -Label "Ambiente" -Value $c.Ambiente
    Write-Field -Label "Local" -Value $c.Local
    Write-Field -Label "Criticidade" -Value $c.Criticidade -ValueColor $(
        if ($c.Criticidade -eq "critico") { [ConsoleColor]::Red }
        elseif ($c.Criticidade -eq "alto") { [ConsoleColor]::Yellow }
        else { [ConsoleColor]::Gray }
    )

    Write-Section "Destino"
    Write-Field -Label "Métricas" -Value $c.RemoteWriteUrl

    if ([string]::IsNullOrWhiteSpace($c.LokiUrl)) {
        Write-Field -Label "Logs" -Value "não configurado" -ValueColor DarkGray
    }
    else {
        Write-Field -Label "Logs" -Value $c.LokiUrl
    }

    Write-Section "Coleta do host"

    if ($c.MonitorHost) {
        Write-Field -Label "Coletores" -Value ($c.Collectors -join ", ")
    }
    else {
        Write-Field -Label "Coletores" -Value "host não monitorado (somente collector de rede)" -ValueColor DarkGray
    }

    $logResumo = New-Object System.Collections.Generic.List[string]
    if ($c.EnableLogs)     { $logResumo.Add("Critical/Error") }
    if ($c.EnableWarnings) { $logResumo.Add("Warning") }
    if ($c.EnableSecurity) { $logResumo.Add("segurança") }

    if ($logResumo.Count -gt 0) {
        Write-Field -Label "Logs" -Value ($logResumo -join ", ")
    }
    else {
        Write-Field -Label "Logs" -Value "desabilitados" -ValueColor DarkGray
    }

    if ($c.EnableInternet) {
        Write-Field -Label "Internet" -Value ("Speedtest a cada {0} min" -f $c.InternetIntervalMinutes)
    }
    else {
        Write-Field -Label "Internet" -Value "não monitorada" -ValueColor DarkGray
    }

    if ($c.BlackboxTargets.Count -gt 0) {
        Write-Section ("Conectividade, Blackbox ({0} alvo(s))" -f $c.BlackboxTargets.Count)
        Write-Host ("    {0,-18} {1,-28} {2,-16} {3}" -f "NOME", "ENDEREÇO", "MÓDULO", "TIPO") -ForegroundColor DarkGray
        foreach ($t in $c.BlackboxTargets) {
            Write-Host ("    {0,-18} {1,-28} {2,-16} {3}" -f $t.Name, $t.Address, $t.Module, $t.Type)
        }
    }

    if ($c.SnmpTargets.Count -gt 0) {
        Write-Host ""
        Write-Host "SNMP" -ForegroundColor White
        foreach ($t in $c.SnmpTargets) {
            Write-Host ("  {0,-20} {1,-20} {2,-16} {3,-14} {4}" -f $t.Name, $t.Address, $t.Module, $t.Auth, $t.Type)
        }
    }

    if ($c.EnableInternet) {
        Write-Host ""
        Write-Host "Internet (Speedtest)" -ForegroundColor White
        Write-Host ("  Habilitado, a cada {0} min." -f $c.InternetIntervalMinutes)
    }

    if ($c.CustomExporters.Count -gt 0) {
        Write-Host ""
        Write-Host "Exporters adicionais" -ForegroundColor White
        foreach ($t in $c.CustomExporters) {
            Write-Host ("  {0,-20} {1}" -f $t.Service, $t.Target)
        }
    }

    Write-Host ""
    Write-Host ("Arquivo: {0}" -f $c.Arquivo) -ForegroundColor DarkGray
    Write-Host ("Última alteração: {0:dd/MM/yyyy HH:mm:ss}" -f $c.Modificado) -ForegroundColor DarkGray
}

function Import-CurrentConfiguration {
    <#
        Carrega a configuração instalada para as variáveis de estado do
        instalador, para que New-AlloyConfiguration possa regerar o arquivo
        preservando tudo que não foi alterado.
    #>
    param([Parameter(Mandatory=$true)][object]$Configuration)

    $c = $Configuration

    $script:Cliente     = $c.Cliente
    $script:HostLabel   = $c.HostLabel
    $script:Ambiente    = $c.Ambiente
    $script:Local       = $c.Local
    $script:Criticidade = $c.Criticidade
    $script:TipoLabel   = $c.TipoLabel

    $script:RemoteWriteUrl = $c.RemoteWriteUrl
    $script:LokiUrl        = $c.LokiUrl

    $script:MonitorHost = $c.MonitorHost
    $script:Collector   = (($c.BlackboxTargets.Count -gt 0) -or ($c.SnmpTargets.Count -gt 0) -or $c.EnableInternet)

    $script:EnableLogsResolved         = $c.EnableLogs
    $script:EnableLogWarningsResolved  = $c.EnableWarnings
    $script:EnableSecurityLogsResolved = $c.EnableSecurity
    $script:EnableBlackboxResolved     = ($c.BlackboxTargets.Count -gt 0)
    $script:EnableSnmpResolved         = ($c.SnmpTargets.Count -gt 0)
    $script:EnableInternetResolved     = $c.EnableInternet

    if ($script:EnableInternetResolved) {
        $script:InternetIntervalMinutesResolved = $c.InternetIntervalMinutes
    }

    $script:BlackboxTargets = @($c.BlackboxTargets)
    $script:BlackboxIntervalSecondsResolved = $c.BlackboxIntervalSeconds
    $script:SnmpTargets     = @($c.SnmpTargets)
    $script:CustomExporters = @($c.CustomExporters)

    # O LokiUrl fica vazio quando o host nunca coletou log. Deriva do destino
    # de métricas para que habilitar logs depois não exija digitar a URL.
    if ([string]::IsNullOrWhiteSpace($script:LokiUrl) -and -not [string]::IsNullOrWhiteSpace($script:RemoteWriteUrl)) {
        $script:LokiUrl = $script:RemoteWriteUrl -replace "/api/v1/write$", "/loki/api/v1/push"
    }

    $credentials = Read-ServiceCredentials

    if ($null -ne $credentials) {
        $script:RwUsername   = $credentials.RwUsername
        $script:RwPassword   = $credentials.RwPassword
        $script:LokiUsername = $credentials.LokiUsername
        $script:LokiPassword = $credentials.LokiPassword
    }

    # Reconstitui as features selecionadas a partir dos coletores presentes no
    # arquivo, para que Get-WindowsCollectors produza a mesma lista ao regerar.
    $inventory = Get-WindowsInventory
    $roles = @(Get-WindowsServerRoles -Inventory $inventory)
    $detected = @(Get-DetectedHostFeatures -Inventory $inventory -ServerRoles $roles `
                    -Sql (Get-SqlServerDetection) -Firebird (Get-FirebirdDetection))

    $script:DetectedHostFeatures = $detected

    $selected = New-Object System.Collections.Generic.List[string]

    foreach ($feature in $detected) {
        foreach ($collector in $feature.Collectors) {
            if ($c.Collectors -contains $collector) {
                if (-not $selected.Contains($feature.Key)) {
                    $selected.Add($feature.Key)
                }
            }
        }
    }

    $script:SelectedHostFeatureKeys = [string[]]@($selected)

    return $inventory
}

function Save-ReconfiguredAlloy {
    <#
        Regrava a configuração a partir do estado atual das variáveis, valida e
        reinicia o serviço. É o passo final de qualquer alteração feita pelo
        menu de configuração.
    #>
    param([Parameter(Mandatory=$true)][object]$Inventory)

    Backup-ExistingConfiguration
    Set-AlloyServiceEnvironment
    New-BlackboxConfiguration
    Install-SnmpConfiguration
    Install-InternetMonitoring
    New-AlloyConfiguration -Inventory $Inventory
    Format-AndValidateAlloyConfiguration
    Restart-AlloyService
    Test-AlloyReadiness
    Write-Ok "Configuração atualizada."
}

function Edit-IdentificationSettings {
    Write-Step "Identificação"

    Write-Info ("Cliente atual: {0}" -f $script:Cliente)
    $cliente = Read-Host "Novo cliente (ENTER mantém)"
    if (-not [string]::IsNullOrWhiteSpace($cliente)) {
        $slug = ConvertTo-Slug $cliente
        if ($slug -notmatch "^[a-z0-9][a-z0-9_-]*$") {
            throw ("Cliente inválido após normalização: {0}" -f $slug)
        }
        $script:Cliente = $slug
    }

    Write-Info ("Local atual: {0}" -f $script:Local)
    $local = Read-Host "Novo local (ENTER mantém)"
    if (-not [string]::IsNullOrWhiteSpace($local)) {
        # Mesma validação da primeira instalação. Sem ela, uma entrada como
        # "###" vira string vazia na normalização e o host chega ao NOC sem a
        # label obrigatória, sem nada acusar.
        $slugLocal = ConvertTo-Slug $local
        if ([string]::IsNullOrWhiteSpace($slugLocal)) {
            throw ("Local inválido após normalização: {0}" -f $local)
        }
        $script:Local = $slugLocal
    }

    $ambientes = @("producao","homologacao","desenvolvimento","backup","teste")
    $indiceAmbiente = [Array]::IndexOf($ambientes, $script:Ambiente)
    if ($indiceAmbiente -lt 0) { $indiceAmbiente = 0 }
    $script:Ambiente = $ambientes[(Read-Choice -Prompt "Ambiente" -Options $ambientes -Default ($indiceAmbiente + 1)) - 1]

    $criticidades = @("critico","alto","medio","baixo")
    $indiceCriticidade = [Array]::IndexOf($criticidades, $script:Criticidade)
    if ($indiceCriticidade -lt 0) { $indiceCriticidade = 1 }
    $script:Criticidade = $criticidades[(Read-Choice -Prompt "Criticidade" -Options $criticidades -Default ($indiceCriticidade + 1)) - 1]

    Write-Info ("Host atual: {0}" -f $script:HostLabel)
    $hostLabel = Read-Host "Novo nome do host (ENTER mantém)"
    if (-not [string]::IsNullOrWhiteSpace($hostLabel)) {
        $slugHost = ConvertTo-Slug $hostLabel
        if ([string]::IsNullOrWhiteSpace($slugHost)) {
            throw ("Nome de host inválido após normalização: {0}" -f $hostLabel)
        }
        $script:HostLabel = $slugHost
    }
}

function Edit-LogSettings {
    Write-Step "Coleta de logs"

    $script:EnableLogsResolved = Read-YesNo -Prompt "Coletar logs do sistema (Critical e Error)?" -Default $script:EnableLogsResolved

    if ($script:EnableLogsResolved) {
        $script:EnableLogWarningsResolved = Read-YesNo -Prompt "Incluir também os avisos (Warning)? Aumenta muito o volume" -Default $script:EnableLogWarningsResolved
    }
    else {
        $script:EnableLogWarningsResolved = $false
    }

    $script:EnableSecurityLogsResolved = Read-YesNo -Prompt "Coletar logs de autenticação e segurança?" -Default $script:EnableSecurityLogsResolved

    # A credencial do Loki só é necessária quando algum log é coletado, e pode
    # não existir se o host nunca enviou log até agora.
    if (($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved) -and
        [string]::IsNullOrWhiteSpace($script:LokiUsername)) {
        Write-Info "Este host ainda não tem credencial de Loki gravada."
        Read-NocCredentials
    }
}

function Read-BlackboxInterval {
    <#
        Define de quanto em quanto tempo cada alvo é sondado.

        O intervalo é o que determina a resolução de tudo que se calcula em
        cima: com 60s, uma queda de 40 segundos pode passar entre duas sondas.
        Com 10s, a janela cega cai para 10 segundos e sobram amostras
        suficientes para jitter e taxa de perda terem significado.
    #>
    Write-Section "Intervalo de sondagem"
    Write-Host "    Quanto menor, mais fina a medição de disponibilidade, latência e jitter." -ForegroundColor DarkGray
    Write-Host "    Cada alvo gera cerca de 9 séries por sondagem." -ForegroundColor DarkGray
    Write-Host ""

    $opcoes = @(
        "10 segundos - disponibilidade e latência de link, jitter confiável",
        "15 segundos - equilíbrio entre resolução e volume",
        "30 segundos - suficiente para serviços e sites",
        "60 segundos - padrão, indicado para site externo e alvo remoto",
        "Informar outro valor"
    )
    $valores = @(10, 15, 30, 60)

    $atual = [Array]::IndexOf($valores, [int]$script:BlackboxIntervalSecondsResolved)
    $padrao = if ($atual -ge 0) { $atual + 1 } else { 4 }

    $escolha = Read-Choice -Prompt "Sondar os alvos a cada" -Options $opcoes -Default $padrao

    if ($escolha -le $valores.Count) {
        $script:BlackboxIntervalSecondsResolved = $valores[$escolha - 1]
    }
    else {
        while ($true) {
            $texto = Read-Host ("    Intervalo em segundos [{0}]" -f $script:BlackboxIntervalSecondsResolved)

            if ([string]::IsNullOrWhiteSpace($texto)) {
                break
            }

            $valor = 0
            if (-not [int]::TryParse($texto, [ref]$valor)) {
                Write-Warn "Informe um número inteiro."
                continue
            }

            # O piso de 5s existe porque o timeout da sonda precisa caber
            # dentro do intervalo, e abaixo disso a sonda não termina a tempo.
            if ($valor -lt 5 -or $valor -gt 300) {
                Write-Warn "Informe um valor entre 5 e 300 segundos."
                continue
            }

            $script:BlackboxIntervalSecondsResolved = $valor
            break
        }
    }

    $porDia = [Math]::Floor(86400 / $script:BlackboxIntervalSecondsResolved)
    Write-Host ""
    Write-Ok ("Sondagem a cada {0}s, {1} medições por alvo por dia." -f $script:BlackboxIntervalSecondsResolved, $porDia)
}

function Edit-BlackboxTargets {
    Write-Step "Alvos de conectividade (Blackbox)"

    if ($script:BlackboxTargets.Count -eq 0) {
        Write-Info "Nenhum alvo configurado."
    }
    else {
        for ($i = 0; $i -lt $script:BlackboxTargets.Count; $i++) {
            $t = $script:BlackboxTargets[$i]
            Write-Host ("  [{0}] {1,-20} {2,-30} {3}" -f ($i + 1), $t.Name, $t.Address, $t.Module)
        }
    }

    Write-Field -Label "Sondagem" -Value ("a cada {0}s" -f $script:BlackboxIntervalSecondsResolved)

    $opcoes = @("Adicionar alvos", "Remover um alvo", "Alterar o intervalo de sondagem", "Refazer a lista do zero", "Voltar")
    $escolha = Read-Choice -Prompt "O que deseja fazer?" -Options $opcoes -Default 5

    switch ($escolha) {
        1 {
            # Read-BlackboxTargets recria a lista, então preservamos o que já
            # existe e concatenamos o que o operador informar agora.
            $existentes = @($script:BlackboxTargets)
            $script:EnableBlackboxResolved = $true
            Read-BlackboxTargets
            $script:BlackboxTargets = @($existentes) + @($script:BlackboxTargets)
        }
        2 {
            if ($script:BlackboxTargets.Count -eq 0) {
                Write-Warn "Não há alvos para remover."
                return
            }

            $nomes = @($script:BlackboxTargets | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Address })
            $indice = Read-Choice -Prompt "Qual alvo remover?" -Options $nomes -Default 1
            $script:BlackboxTargets = @($script:BlackboxTargets | Where-Object { $_ -ne $script:BlackboxTargets[$indice - 1] })
        }
        3 { Read-BlackboxInterval }
        4 {
            $script:BlackboxTargets = @()
            $script:EnableBlackboxResolved = $true
            Read-BlackboxTargets
        }
    }

    $script:EnableBlackboxResolved = ($script:BlackboxTargets.Count -gt 0)
    $script:Collector = ($script:EnableBlackboxResolved -or $script:EnableSnmpResolved -or $script:EnableInternetResolved)
}

function Edit-SnmpTargets {
    Write-Step "Alvos SNMP"

    if ($script:SnmpTargets.Count -eq 0) {
        Write-Info "Nenhum alvo configurado."
    }
    else {
        for ($i = 0; $i -lt $script:SnmpTargets.Count; $i++) {
            $t = $script:SnmpTargets[$i]
            Write-Host ("  [{0}] {1,-20} {2,-20} {3,-16} {4}" -f ($i + 1), $t.Name, $t.Address, $t.Module, $t.Auth)
        }
    }

    $opcoes = @("Adicionar alvos", "Remover um alvo", "Refazer a lista do zero", "Voltar")
    $escolha = Read-Choice -Prompt "O que deseja fazer?" -Options $opcoes -Default 4

    switch ($escolha) {
        1 {
            $existentes = @($script:SnmpTargets)
            $script:EnableSnmpResolved = $true
            Read-SnmpTargets -Append
            $script:SnmpTargets = @($existentes) + @($script:SnmpTargets)
        }
        2 {
            if ($script:SnmpTargets.Count -eq 0) {
                Write-Warn "Não há alvos para remover."
                return
            }

            $nomes = @($script:SnmpTargets | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Address })
            $indice = Read-Choice -Prompt "Qual alvo remover?" -Options $nomes -Default 1
            $script:SnmpTargets = @($script:SnmpTargets | Where-Object { $_ -ne $script:SnmpTargets[$indice - 1] })
        }
        3 {
            $script:SnmpTargets = @()
            $script:SnmpAuthBlocks = @()
            $script:EnableSnmpResolved = $true
            Read-SnmpTargets
        }
    }

    $script:EnableSnmpResolved = ($script:SnmpTargets.Count -gt 0)
    $script:Collector = ($script:EnableBlackboxResolved -or $script:EnableSnmpResolved -or $script:EnableInternetResolved)
}

function Add-CustomExporterEntries {
    <#
        Acrescenta endpoints Prometheus um a um, oferecendo o catálogo como
        atalho de porta e nome de serviço. Não reaproveita a árvore de seleção
        da instalação porque ali os exporters vêm junto com logs e recursos
        detectados, e num host já instalado só os exporters estão em jogo.
    #>
    $catalogo = Get-NextecExporterCatalog
    $rotulos = @($catalogo | ForEach-Object { $_.Label })

    do {
        $indice = Read-Choice -Prompt "Qual exporter?" -Options $rotulos -Default $rotulos.Count
        $definicao = $catalogo[$indice - 1]

        $nome = ""
        while ([string]::IsNullOrWhiteSpace($nome)) {
            $sugestao = if ([string]::IsNullOrWhiteSpace($definicao.DefaultService)) { "" } else { $definicao.Key }
            $nome = ConvertTo-Slug (Read-Required -Prompt "Nome do exporter" -Default $sugestao)

            if ([string]::IsNullOrWhiteSpace($nome)) {
                Write-Warn "Nome inválido após normalização."
                continue
            }

            if (@($script:CustomExporters | ForEach-Object { $_.Name }) -contains $nome) {
                Write-Warn ("Já existe um exporter chamado '{0}'. Use outro nome." -f $nome)
                $nome = ""
            }
        }

        $alvo = Read-Required -Prompt "Endereço (host:porta)" -Default $definicao.DefaultTarget
        $servico = ConvertTo-Slug (Read-Required -Prompt "Serviço (label)" -Default $definicao.DefaultService)

        $script:CustomExporters += [pscustomobject]@{
            Name = $nome
            Target = $alvo
            Service = $servico
        }

        $mais = Read-YesNo -Prompt "Adicionar outro exporter?" -Default $false
    }
    while ($mais)
}

function Edit-CustomExporters {
    <#
        Edita os endpoints Prometheus adicionais de um host já instalado.

        Espelha Edit-BlackboxTargets e Edit-SnmpTargets: sem este editor, um
        exporter só podia ser acrescentado reinstalando o host do zero.
    #>
    Write-Step "Exporters adicionais"

    if ($script:CustomExporters.Count -eq 0) {
        Write-Info "Nenhum exporter configurado."
    }
    else {
        for ($i = 0; $i -lt $script:CustomExporters.Count; $i++) {
            $exporter = $script:CustomExporters[$i]
            Write-Host ("  [{0}] {1,-20} {2,-24} {3}" -f ($i + 1), $exporter.Name, $exporter.Target, $exporter.Service)
        }
    }

    $opcoes = @("Adicionar exporters", "Remover um exporter", "Refazer a lista do zero", "Voltar")
    $escolha = Read-Choice -Prompt "O que deseja fazer?" -Options $opcoes -Default 4

    switch ($escolha) {
        1 { Add-CustomExporterEntries }
        2 {
            if ($script:CustomExporters.Count -eq 0) {
                Write-Warn "Não há exporters para remover."
                return
            }

            $nomes = @($script:CustomExporters | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Target })
            $indice = Read-Choice -Prompt "Qual exporter remover?" -Options $nomes -Default 1
            $script:CustomExporters = @($script:CustomExporters | Where-Object { $_ -ne $script:CustomExporters[$indice - 1] })
        }
        3 {
            $script:CustomExporters = @()
            Add-CustomExporterEntries
        }
    }

    $script:EnableExportersResolved = ($script:CustomExporters.Count -gt 0)
    $script:Collector = ($script:EnableBlackboxResolved -or $script:EnableSnmpResolved -or $script:EnableInternetResolved -or $script:EnableExportersResolved)
}

function Edit-InternetSettings {
    Write-Step "Internet (Speedtest)"

    if ($script:EnableInternetResolved) {
        Write-Info ("Habilitado, a cada {0} min." -f $script:InternetIntervalMinutesResolved)
    }
    else {
        Write-Info "Desabilitado."
    }

    Write-Host ""
    Write-Host "    O Speedtest satura o link durante o teste e consome banda de verdade." -ForegroundColor DarkGray
    Write-Host "    Ele mede velocidade, não disponibilidade: para saber se o link caiu," -ForegroundColor DarkGray
    Write-Host "    use os alvos de conectividade (Blackbox), que testam a cada minuto." -ForegroundColor DarkGray
    Write-Host ""

    $habilitar = Read-YesNo -Prompt "Habilitar medição de velocidade (Speedtest Ookla)?" -Default $script:EnableInternetResolved

    if (-not $habilitar) {
        $script:EnableInternetResolved = $false
        return
    }

    while ($true) {
        $intervaloTexto = Read-Host ("    Intervalo em minutos entre execuções [{0}]" -f $script:InternetIntervalMinutesResolved)

        if ([string]::IsNullOrWhiteSpace($intervaloTexto)) {
            Write-Host ""
            break
        }

        $intervalo = 0
        if (-not [int]::TryParse($intervaloTexto, [ref]$intervalo)) {
            Write-Warn "Informe um número inteiro."
            continue
        }

        if ($intervalo -lt 5) {
            Write-Warn "Intervalo mínimo é 5 minutos."
            continue
        }

        if ($intervalo -gt 1440) {
            Write-Warn "Intervalo máximo é 1440 minutos (24 horas)."
            continue
        }

        # Cada execução ocupa o link inteiro por cerca de 15 segundos em cada
        # sentido, então o consumo cresce com a velocidade contratada: num link
        # de 300 Mbps cada teste transfere perto de meio giga. Abaixo de 15
        # minutos o operador vê a conta antes de confirmar.
        if ($intervalo -lt 15) {
            $porDia = [Math]::Floor(1440 / $intervalo)
            Write-Host ""
            Write-Warn ("A cada {0} min são {1} testes por dia." -f $intervalo, $porDia)
            Write-Host ("    Em um link de 100 Mbps isso passa de {0} GB por dia." -f [Math]::Round($porDia * 0.37, 0)) -ForegroundColor Yellow
            Write-Host ("    Em um link de 300 Mbps, mais de {0} GB por dia." -f [Math]::Round($porDia * 1.1, 0)) -ForegroundColor Yellow
            Write-Host "    Durante cada teste o link fica saturado e o cliente sente lentidão." -ForegroundColor Yellow
            Write-Host "    Para disponibilidade e latência contínuas, use os alvos ICMP." -ForegroundColor DarkGray
            Write-Host ""

            if (-not (Read-YesNo -Prompt ("Confirma medir velocidade a cada {0} minutos?" -f $intervalo) -Default $false)) {
                continue
            }
        }

        $script:InternetIntervalMinutesResolved = $intervalo
        Write-Host ""
        break
    }

    $script:EnableInternetResolved = $true

    # Velocidade sem disponibilidade conta metade da história: um teste a cada
    # 30 minutos não enxerga uma queda de cinco. Os alvos ICMP fecham essa
    # lacuna e separam "a internet caiu" de "o roteador do cliente caiu".
    if ($script:BlackboxTargets.Count -eq 0) {
        Write-Host ""
        Write-Info "Nenhum alvo de conectividade configurado neste host."

        if (Read-YesNo -Prompt "Criar os alvos padrão de disponibilidade (gateway, 1.1.1.1, 8.8.8.8)?" -Default $true) {
            Add-DefaultConnectivityTargets
        }
    }
}

function Add-DefaultConnectivityTargets {
    <#
        Cria os três alvos ICMP que respondem à pergunta que aparece primeiro
        em toda queda: o problema é o link, o roteador ou a internet inteira.

        O gateway sai da tabela de rotas do próprio host; se não der para
        descobrir, apenas os dois destinos externos são criados.
    #>
    $novos = New-Object System.Collections.Generic.List[object]

    $gateway = ""
    try {
        $rota = Get-CimInstance -ClassName Win32_IP4RouteTable -Filter "Destination='0.0.0.0'" -ErrorAction Stop |
                Sort-Object Metric1 |
                Select-Object -First 1

        if ($null -ne $rota) {
            $gateway = [string]$rota.NextHop
        }
    }
    catch {
        $gateway = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($gateway) -and $gateway -ne "0.0.0.0") {
        $novos.Add([pscustomobject]@{
            Name = "gateway"
            Address = $gateway
            Module = "icmp_ipv4"
            Type = "rede"
            Service = "conectividade"
        })
    }
    else {
        Write-Warn "Não foi possível descobrir o gateway padrão; criando apenas os destinos externos."
    }

    $novos.Add([pscustomobject]@{
        Name = "dns_cloudflare"
        Address = "1.1.1.1"
        Module = "icmp_ipv4"
        Type = "rede"
        Service = "conectividade"
    })

    $novos.Add([pscustomobject]@{
        Name = "dns_google"
        Address = "8.8.8.8"
        Module = "icmp_ipv4"
        Type = "rede"
        Service = "conectividade"
    })

    $existentes = @($script:BlackboxTargets | ForEach-Object { $_.Name })
    $adicionados = @($novos | Where-Object { $existentes -notcontains $_.Name })

    $script:BlackboxTargets = @($script:BlackboxTargets) + $adicionados
    $script:EnableBlackboxResolved = ($script:BlackboxTargets.Count -gt 0)
    $script:Collector = $true

    foreach ($alvo in $adicionados) {
        Write-Ok ("Alvo criado: {0} ({1})" -f $alvo.Name, $alvo.Address)
    }

    # Alvo de disponibilidade de link só cumpre o papel com sondagem curta:
    # a 60s uma queda de quarenta segundos passa despercebida entre duas
    # medições.
    if ($script:BlackboxIntervalSecondsResolved -gt 15) {
        Write-Host ""
        Write-Info ("A sondagem está em {0}s, o que é grosseiro para medir queda de link." -f $script:BlackboxIntervalSecondsResolved)

        if (Read-YesNo -Prompt "Reduzir para 10 segundos?" -Default $true) {
            $script:BlackboxIntervalSecondsResolved = 10
            Write-Ok "Sondagem ajustada para 10s."
        }
    }
}

function Edit-NocDestination {
    Write-Step "Destino do NOC"

    Write-Info ("Métricas: {0}" -f $script:RemoteWriteUrl)
    Write-Info ("Logs:     {0}" -f $script:LokiUrl)

    Set-NocDestination

    if (-not (Test-NocConnectivity)) {
        Write-Warn "Conectividade não confirmada com o novo destino."
    }
}

function Invoke-ConfigurationMenu {
    <#
        Menu de visualização e alteração da configuração instalada.

        Toda alteração passa por New-AlloyConfiguration, ou seja, o arquivo é
        sempre regerado inteiro a partir do estado carregado, nunca editado por
        substituição de texto. Isso evita que uma alteração pontual deixe o
        arquivo inconsistente com o padrão da Nextec.
    #>
    $configuration = Read-CurrentAlloyConfiguration

    if ($null -eq $configuration) {
        Write-Warn ("Nenhuma configuração encontrada em {0}." -f $ConfigFile)
        return
    }

    Show-CurrentConfiguration -Configuration $configuration

    if (-not (Read-YesNo -Prompt "Deseja alterar alguma coisa?" -Default $false)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($configuration.Cliente)) {
        Write-Warn "Não foi possível ler a identificação do config.alloy atual. Use a opção de reconfiguração completa."
        return
    }

    $inventory = Import-CurrentConfiguration -Configuration $configuration

    $alterou = $false

    while ($true) {
        # Lista montada dinamicamente porque "Internet (Speedtest)" só faz
        # sentido em host captador. O despacho abaixo é por rótulo, não por
        # número fixo, para não quebrar quando um item entra ou sai da lista.
        $opcoes = New-Object System.Collections.Generic.List[string]
        [void]$opcoes.Add("Identificação (cliente, host, local, ambiente, criticidade)")
        [void]$opcoes.Add("Coleta de logs (sistema, avisos, segurança)")
        [void]$opcoes.Add("Alvos de conectividade (Blackbox)")
        [void]$opcoes.Add("Alvos SNMP")

        # Internet e exporters aparecem sempre. Condicionar a "já ser coletor"
        # criava um beco: o item só existia se o host já tivesse algum alvo, e
        # era justamente por esse item que se ativava o primeiro.
        [void]$opcoes.Add("Internet (Speedtest)")
        [void]$opcoes.Add("Exporters adicionais")

        [void]$opcoes.Add("Credenciais do NOC")
        [void]$opcoes.Add("Destino do NOC")
        [void]$opcoes.Add("Abrir o config.alloy no Bloco de Notas")
        [void]$opcoes.Add("Gravar e aplicar as alterações")
        [void]$opcoes.Add("Sair sem gravar")

        $defaultIndex = $opcoes.IndexOf("Gravar e aplicar as alterações") + 1
        $escolha = Read-Choice -Prompt "O que deseja alterar?" -Options $opcoes.ToArray() -Default $defaultIndex
        $rotulo = $opcoes[$escolha - 1]

        switch ($rotulo) {
            "Identificação (cliente, host, local, ambiente, criticidade)" { Edit-IdentificationSettings; $alterou = $true }
            "Coleta de logs (sistema, avisos, segurança)" { Edit-LogSettings; $alterou = $true }
            "Alvos de conectividade (Blackbox)" { Edit-BlackboxTargets; $alterou = $true }
            "Alvos SNMP" { Edit-SnmpTargets; $alterou = $true }
            "Internet (Speedtest)" { Edit-InternetSettings; $alterou = $true }
            "Exporters adicionais" { Edit-CustomExporters; $alterou = $true }
            "Credenciais do NOC" {
                # Limpa o que veio do registro para que Read-NocCredentials
                # pergunte de novo em vez de reaproveitar em silêncio.
                $script:RwUsername = ""
                $script:RwPassword = ""
                $script:LokiUsername = ""
                $script:LokiPassword = ""
                Read-NocCredentials
                $alterou = $true
            }
            "Destino do NOC" { Edit-NocDestination; $alterou = $true }
            "Abrir o config.alloy no Bloco de Notas" {
                Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $ConfigFile) | Out-Null
                Write-Info "O Bloco de Notas foi aberto. Alterações feitas por lá não passam pela validação deste instalador."
            }
            "Gravar e aplicar as alterações" {
                if (-not $alterou) {
                    Write-Info "Nada foi alterado."
                    return
                }

                Save-ReconfiguredAlloy -Inventory $inventory
                return
            }
            "Sair sem gravar" {
                if ($alterou) {
                    Write-Warn "Alterações descartadas; o arquivo no disco não foi tocado."
                }
                return
            }
        }
    }
}

function Invoke-MaintenanceMenu {
    if (-not (Test-AlloyInstalled)) {
        return $true
    }

    if ($Silent) {
        return $true
    }

    Write-Step "Instalação existente detectada"
    Show-MaintenanceStatus

    $options = @(
        "Ver e alterar a configuração atual",
        "Reconfigurar tudo, fluxo completo (identificação, recursos, credenciais)",
        "Atualizar/reinstalar o binário do Grafana Alloy, mantém configuração atual",
        "Validar configuração atual e reiniciar o serviço",
        "Cancelar"
    )

    # O default é "Cancelar": as outras opções alteram ou reiniciam o serviço
    # em um servidor de produção, e ENTER não deve disparar isso.
    $choice = Read-Choice -Prompt "O que deseja fazer?" -Options $options -Default 5

    switch ($choice) {
        1 {
            Invoke-ConfigurationMenu
            return $false
        }
        2 {
            return $true
        }
        3 {
            # ConfigChanged fica falso: esta opção não gera configuração nova,
            # e marcá-la faria o rollback remover a config existente.
            Backup-ExistingConfiguration
            Update-AlloyBinaryOnly
            Write-Ok "Binário do Alloy atualizado/reinstalado, configuração mantida."
            return $false
        }
        4 {
            Backup-ExistingConfiguration
            Format-AndValidateAlloyConfiguration
            Restart-AlloyService
            Test-AlloyReadiness -Mandatory $false
            Write-Ok "Manutenção concluída."
            return $false
        }
        5 {
            throw "Operação cancelada pelo operador."
        }
    }

    return $true
}


# ==============================================================================
# DETECÇÃO DO WINDOWS
# ==============================================================================

function Get-WindowsInventory {
    Write-Step "Detectando sistema operacional"

    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem

    $productType = [int]$os.ProductType

    switch ($productType) {
        1 { $role = "workstation" }
        2 { $role = "domain_controller" }
        3 { $role = "server" }
        default { $role = "unknown" }
    }

    if ($productType -eq 1) {
        $build = [int]$os.BuildNumber

        if ($build -ge 22000) {
            $generation = "windows_11"
        }
        elseif ($build -ge 10240) {
            $generation = "windows_10"
        }
        else {
            $generation = "windows_legacy"
        }
    }
    else {
        $generation = "windows_server"
    }
    if ($productType -eq 1 -and [int]$os.BuildNumber -lt 10240) {
        throw ("Windows não suportado pelo Grafana Alloy: {0}, build {1}. Mínimo: Windows 10." -f $os.Caption, $os.BuildNumber)
    }

    if ($productType -ne 1 -and [int]$os.BuildNumber -lt 14393) {
        throw ("Windows Server não suportado pelo Grafana Alloy: {0}, build {1}. Mínimo: Windows Server 2016." -f $os.Caption, $os.BuildNumber)
    }

    if ($os.OSArchitecture -notmatch "64") {
        throw ("Arquitetura não suportada: {0}. O Grafana Alloy para Windows requer AMD64/x64." -f $os.OSArchitecture)
    }

    # A checagem de processo 32 bits em Windows 64 bits acontece bem antes
    # disso, no despacho final do script (Test-NextecProcessNeedsBitnessRelaunch
    # e Invoke-NextecRelaunch), que reabre em 64 bits antes de chegar aqui.

    [pscustomobject]@{
        Caption      = [string]$os.Caption
        Version      = [string]$os.Version
        Build        = [string]$os.BuildNumber
        Architecture = [string]$os.OSArchitecture
        ProductType  = $productType
        Role         = $role
        Generation   = $generation
        Hostname     = [string]$env:COMPUTERNAME
        PartOfDomain = [bool]$computer.PartOfDomain
        Domain       = [string]$computer.Domain
        Manufacturer = [string]$computer.Manufacturer
        Model        = [string]$computer.Model
    }
}

function Get-WindowsServerRoles {
    param([Parameter(Mandatory=$true)][object]$Inventory)

    $roles = New-Object System.Collections.Generic.List[string]

    if ($Inventory.ProductType -eq 1) {
        return @()
    }

    $getWindowsFeature = Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue

    if ($null -ne $getWindowsFeature) {
        try {
            # -Name com lista fechada. Sem filtro, Get-WindowsFeature
            # materializa o catálogo inteiro (~250 features) via Component
            # Based Servicing: de 5 a 60 segundos com pico de CPU e I/O do
            # TrustedInstaller, em servidor de produção.
            # Para detectar uma role nova, acrescente o nome aqui e o case
            # correspondente no switch abaixo.
            $featureNames = @(
                "AD-Domain-Services", "ADCS-Cert-Authority", "ADFS-Federation",
                "DNS", "DHCP", "Web-Server", "Hyper-V", "FS-FileServer",
                "FS-DFS-Replication", "RDS-RD-Server", "Failover-Clustering"
            )

            $installed = @(Get-WindowsFeature -Name $featureNames -ErrorAction SilentlyContinue |
                           Where-Object { $_.Installed })

            foreach ($feature in $installed) {
                switch ($feature.Name) {
                    "AD-Domain-Services"   { if (-not $roles.Contains("active_directory")) { $roles.Add("active_directory") } }
                    "ADCS-Cert-Authority"  { if (-not $roles.Contains("adcs"))             { $roles.Add("adcs") } }
                    "ADFS-Federation"      { if (-not $roles.Contains("adfs"))             { $roles.Add("adfs") } }
                    "DNS"                  { if (-not $roles.Contains("dns"))              { $roles.Add("dns") } }
                    "DHCP"                 { if (-not $roles.Contains("dhcp"))             { $roles.Add("dhcp") } }
                    "Web-Server"           { if (-not $roles.Contains("iis"))              { $roles.Add("iis") } }
                    "Hyper-V"              { if (-not $roles.Contains("hyper_v"))          { $roles.Add("hyper_v") } }
                    "FS-FileServer"         { if (-not $roles.Contains("file_server"))      { $roles.Add("file_server") } }
                    "FS-DFS-Replication"    { if (-not $roles.Contains("dfsr"))             { $roles.Add("dfsr") } }
                    "RDS-RD-Server"         { if (-not $roles.Contains("terminal_services")){ $roles.Add("terminal_services") } }
                    "Failover-Clustering"   { if (-not $roles.Contains("failover_cluster")) { $roles.Add("failover_cluster") } }
                }
            }
        }
        catch {
            Write-Warn ("Não foi possível consultar todas as funções do Windows Server: {0}" -f $_.Exception.Message)
        }
    }

    if ($Inventory.Role -eq "domain_controller" -and -not $roles.Contains("active_directory")) {
        $roles.Add("active_directory")
    }

    if ($roles.Count -eq 0) {
        return @()
    }

    return @($roles | Sort-Object -Unique)
}

# ==============================================================================
# DETECÇÃO DE SOFTWARE
# ==============================================================================

function Get-InstalledPrograms {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $programs = New-Object System.Collections.Generic.List[object]

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $keys = @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)

        foreach ($key in $keys) {
            try {
                $displayName = [string]$key.GetValue("DisplayName", $null)

                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    continue
                }

                $programs.Add([pscustomobject]@{
                    DisplayName     = $displayName
                    DisplayVersion  = [string]$key.GetValue("DisplayVersion", $null)
                    Publisher       = [string]$key.GetValue("Publisher", $null)
                    InstallLocation = [string]$key.GetValue("InstallLocation", $null)
                })
            }
            catch {
                Write-Info ("Entrada de programa ignorada: {0}" -f $key.Name)
            }
        }
    }

    if ($programs.Count -eq 0) {
        return @()
    }

    return @($programs | Sort-Object DisplayName, DisplayVersion -Unique)
}

function Get-SqlServerDetection {
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "^(MSSQLSERVER|MSSQL\$|SQLAgent|SQLBrowser)" -or
        $_.DisplayName -match "SQL Server"
    })

    $processes = @(Get-Process -Name "sqlservr" -ErrorAction SilentlyContinue)
    $instances = New-Object System.Collections.Generic.List[string]

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue

            if ($null -eq $item) {
                continue
            }

            foreach ($property in $item.PSObject.Properties) {
                if ($property.Name -notmatch "^PS") {
                    if (-not $instances.Contains($property.Name)) {
                        $instances.Add($property.Name)
                    }
                }
            }
        }
    }

    # Exige instância registrada ou o processo sqlservr em execução. Serviço
    # com "SQL Server" no DisplayName não serve como critério: o "SQL Server
    # VSS Writer" existe em qualquer máquina com SSMS ou agente de backup, sem
    # instância de banco. O coletor mssql habilitado sem instância tenta ler
    # contadores inexistentes a cada scrape.
    [pscustomobject]@{
        Detected  = ($instances.Count -gt 0 -or $processes.Count -gt 0)
        Services  = @($services | ForEach-Object { "{0} [{1}]" -f $_.Name, $_.Status })
        Instances = if ($instances.Count -gt 0) { @($instances | Sort-Object -Unique) } else { @() }
        Processes = $processes.Count
    }
}

function Get-FirebirdDetection {
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "firebird|fbserver|fbguard" -or
        $_.DisplayName -match "Firebird"
    })

    $processNames = @(
        "firebird",
        "firebird_server",
        "fbserver",
        "fb_inet_server",
        "fbguard"
    )

    # Get-Process aceita array em -Name: uma chamada em vez de uma varredura
    # da tabela de processos por nome procurado.
    $processes = New-Object System.Collections.Generic.List[object]

    foreach ($process in @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)) {
        $processes.Add($process)
    }

    $programs = @(Get-InstalledPrograms | Where-Object {
        $_.DisplayName -match "Firebird"
    })

    $knownPaths = New-Object System.Collections.Generic.List[string]

    $pathCandidates = @(
        (Join-Path $env:ProgramFiles "Firebird")
    )

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $pathCandidates += (Join-Path $programFilesX86 "Firebird")
    }

    foreach ($path in $pathCandidates) {
        if (Test-Path $path) {
            $knownPaths.Add($path)
        }
    }

    $port3050 = Test-ListeningPort -Port 3050

    [pscustomobject]@{
        Detected   = ($services.Count -gt 0 -or $processes.Count -gt 0 -or $programs.Count -gt 0 -or $knownPaths.Count -gt 0 -or $port3050)
        Services   = @($services | ForEach-Object { "{0} [{1}]" -f $_.Name, $_.Status })
        Programs   = @($programs | ForEach-Object { "{0} {1}" -f $_.DisplayName, $_.DisplayVersion })
        Processes  = $processes.Count
        Port3050   = $port3050
        KnownPaths = @($knownPaths)
    }
}


function Get-DetectedHostFeatures {
    # [AllowEmptyCollection()] é necessário: parâmetro Mandatory recusa array
    # vazio, e coleção vazia é entrada válida aqui (estação Windows não tem
    # roles de servidor).
    param(
        [Parameter(Mandatory=$true)][object]$Inventory,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$ServerRoles,
        [Parameter(Mandatory=$true)][object]$Sql,
        [Parameter(Mandatory=$true)][object]$Firebird
    )

    $features = New-Object System.Collections.Generic.List[object]

    foreach ($role in $ServerRoles) {
        switch ($role) {
            "active_directory" {
                if ($Inventory.Role -eq "domain_controller") {
                    $features.Add([pscustomobject]@{ Key="active_directory"; Label="Active Directory"; Collectors=@("ad"); Selected=$true })
                }
            }
            "adcs" {
                if ($null -ne (Get-Service -Name "CertSvc" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="adcs"; Label="Active Directory Certificate Services"; Collectors=@("adcs"); Selected=$true })
                }
            }
            "adfs" {
                if ($null -ne (Get-Service -Name "adfssrv" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="adfs"; Label="AD FS"; Collectors=@("adfs"); Selected=$true })
                }
            }
            "dns" {
                if ($null -ne (Get-Service -Name "DNS" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="dns"; Label="DNS Server"; Collectors=@("dns"); Selected=$true })
                }
            }
            "dhcp" {
                if ($null -ne (Get-Service -Name "DHCPServer" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="dhcp"; Label="DHCP Server"; Collectors=@("dhcp"); Selected=$true })
                }
            }
            "iis" {
                if ($null -ne (Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="iis"; Label="IIS"; Collectors=@("iis"); Selected=$true })
                }
            }
            "hyper_v" {
                if ($null -ne (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="hyper_v"; Label="Hyper-V"; Collectors=@("hyperv"); Selected=$true })
                }
            }
            "file_server" {
                $features.Add([pscustomobject]@{ Key="file_server"; Label="File Server / SMB"; Collectors=@("smb"); Selected=$true })
            }
            "dfsr" {
                if ($null -ne (Get-Service -Name "DFSR" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="dfsr"; Label="DFSR"; Collectors=@("dfsr"); Selected=$true })
                }
            }
            "terminal_services" {
                $features.Add([pscustomobject]@{ Key="terminal_services"; Label="Remote Desktop Services"; Collectors=@("terminal_services"); Selected=$true })
            }
            "failover_cluster" {
                if ($null -ne (Get-Service -Name "ClusSvc" -ErrorAction SilentlyContinue)) {
                    $features.Add([pscustomobject]@{ Key="failover_cluster"; Label="Failover Cluster"; Collectors=@("mscluster"); Selected=$true })
                }
            }
        }
    }

    # SQL Server vem desmarcado: o documento 03 exige homologação do método
    # para a versão e a topologia do ambiente antes de habilitar a coleta, e o
    # instalador Linux também não configura sozinho.
    #
    # O rótulo do Firebird descreve o que é entregue de fato, o coletor
    # "process": CPU, memória e handles. Não há conexões ativas, transações,
    # deadlocks nem tamanho de base.
    if ($Sql.Detected) {
        $features.Add([pscustomobject]@{ Key="sql_server"; Label="SQL Server (coleta requer homologação, ver documento 03)"; Collectors=@("mssql"); Selected=$false })
    }

    if ($Firebird.Detected) {
        $features.Add([pscustomobject]@{ Key="firebird"; Label="Firebird (apenas processos do servidor)"; Collectors=@("process"); Selected=$true })
    }

    return @($features | Sort-Object Label -Unique)
}

function Show-DetectionSummary {
    # Coleção vazia é entrada válida; ver Get-DetectedHostFeatures.
    param(
        [Parameter(Mandatory=$true)][object]$Inventory,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$DetectedFeatures
    )

    Write-Step "Resultado da detecção"
    Write-Info ("Sistema: {0}" -f $Inventory.Caption)
    Write-Info ("Versão/build: {0} / {1}" -f $Inventory.Version, $Inventory.Build)
    Write-Info ("Tipo detectado: {0}" -f $Inventory.Generation)
    Write-Info ("Arquitetura: {0}" -f $Inventory.Architecture)
    Write-Info ("Hostname: {0}" -f $Inventory.Hostname)

    if ($Inventory.PartOfDomain) {
        Write-Info ("Domínio: {0}" -f $Inventory.Domain)
    }
    else {
        Write-Info "Equipamento em workgroup."
    }

    if ($DetectedFeatures.Count -gt 0) {
        Write-Ok ("Recursos detectados: {0}" -f (($DetectedFeatures | ForEach-Object { $_.Label }) -join ", "))
    }
}

# ==============================================================================
# CONFIGURAÇÃO INTERATIVA
# ==============================================================================

function Resolve-Mode {
    param([Parameter(Mandatory=$true)][object]$Inventory)

    if ($Modo -ne "auto") {
        return $Modo
    }

    if ($Inventory.ProductType -eq 1) {
        return "estacao"
    }

    return "servidor"
}

function Get-NextecVisibleItemIndexes {
    param([Parameter(Mandatory=$true)][object[]]$Items)

    $visible = New-Object System.Collections.Generic.List[int]

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]

        if ([string]::IsNullOrEmpty([string]$item.ParentKey)) {
            $visible.Add($i)
            continue
        }

        $parent = $Items | Where-Object { $_.Key -eq $item.ParentKey } | Select-Object -First 1

        if ($null -ne $parent -and [bool]$parent.Expanded) {
            $visible.Add($i)
        }
    }

    return @($visible)
}

function Get-NextecMultiSelectionConsole {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][object[]]$Items
    )

    $cursor = 0
    $keyOptions = [System.Management.Automation.Host.ReadKeyOptions]"NoEcho,IncludeKeyDown"

    try {
        while ($true) {
            $visibleIndexes = @(Get-NextecVisibleItemIndexes -Items $Items)

            if ($cursor -ge $visibleIndexes.Count) {
                $cursor = $visibleIndexes.Count - 1
            }
            if ($cursor -lt 0) {
                $cursor = 0
            }

            Clear-Host
            Show-Banner
            Write-Host ("==> {0}" -f $Title) -ForegroundColor Cyan
            Write-Host "Use as setas para navegar. ESPAÇO expande/retrai categorias e marca/desmarca itens. ENTER confirma." -ForegroundColor DarkGray
            Write-Host ""

            for ($vi = 0; $vi -lt $visibleIndexes.Count; $vi++) {
                $item = $Items[$visibleIndexes[$vi]]
                $indent = "  " * [int]$item.Depth
                $prefix = if ($vi -eq $cursor) { ">" } else { " " }

                if ([bool]$item.HasChildren) {
                    $arrow = if ([bool]$item.Expanded) { "v" } else { ">" }
                    $line = ("{0} {1}{2} {3}" -f $prefix, $indent, $arrow, $item.Label)
                }
                else {
                    $mark = if ($item.Selected) { "x" } else { " " }
                    $line = ("{0} {1}[{2}] {3}" -f $prefix, $indent, $mark, $item.Label)
                }

                if ($vi -eq $cursor) {
                    Write-Host $line -ForegroundColor Cyan
                }
                else {
                    Write-Host $line
                }
            }

            $key = $Host.UI.RawUI.ReadKey($keyOptions)

            switch ($key.VirtualKeyCode) {
                38 { $cursor = ($cursor - 1 + $visibleIndexes.Count) % $visibleIndexes.Count }
                40 { $cursor = ($cursor + 1) % $visibleIndexes.Count }
                32 {
                    $target = $Items[$visibleIndexes[$cursor]]

                    if ([bool]$target.HasChildren) {
                        $target.Expanded = -not [bool]$target.Expanded
                    }
                    else {
                        $target.Selected = -not $target.Selected
                    }
                }
                13 {
                    return [pscustomobject]@{
                        Succeeded = $true
                        Keys = [string[]]@($Items | Where-Object { -not [bool]$_.HasChildren -and $_.Selected } | ForEach-Object { $_.Key })
                    }
                }
            }
        }
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Keys = [string[]]@() }
    }
}

function Get-NextecMultiSelectionFallback {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][object[]]$Items
    )

    while ($true) {
        Write-Step $Title
        Write-Host "Números marcam/desmarcam itens ou expandem/retraem categorias (> / v)." -ForegroundColor DarkGray

        $visibleIndexes = @(Get-NextecVisibleItemIndexes -Items $Items)

        for ($vi = 0; $vi -lt $visibleIndexes.Count; $vi++) {
            $item = $Items[$visibleIndexes[$vi]]
            $indent = "  " * [int]$item.Depth

            if ([bool]$item.HasChildren) {
                $arrow = if ([bool]$item.Expanded) { "v" } else { ">" }
                Write-Host ("  {0}{1} {2}. {3}" -f $indent, $arrow, ($vi + 1), $item.Label)
            }
            else {
                $mark = if ($item.Selected) { "x" } else { " " }
                Write-Host ("  {0}[{1}] {2}. {3}" -f $indent, $mark, ($vi + 1), $item.Label)
            }
        }

        $inputValue = Read-Host "Números para marcar/desmarcar/expandir, separados por espaço. ENTER confirma"

        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            Write-Host ""
            return [string[]]@($Items | Where-Object { -not [bool]$_.HasChildren -and $_.Selected } | ForEach-Object { $_.Key })
        }

        $tokens = @($inputValue -split "[,\s]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        foreach ($token in $tokens) {
            $number = 0
            if ([int]::TryParse($token, [ref]$number) -and $number -ge 1 -and $number -le $visibleIndexes.Count) {
                $target = $Items[$visibleIndexes[$number - 1]]

                if ([bool]$target.HasChildren) {
                    $target.Expanded = -not [bool]$target.Expanded
                }
                else {
                    $target.Selected = -not $target.Selected
                }
            }
            else {
                Write-Warn ("Opção inválida: {0}" -f $token)
            }
        }
    }
}

function Test-NextecInteractiveConsole {
    # Equivalente ao teste `[[ ! -t 0 || ! -t 1 ]]` do script Linux: só tenta o
    # menu por teclado quando existe um console real (host = ConsoleHost e
    # entrada/saída não redirecionadas). PowerShell ISE, execução remota ou
    # saída redirecionada caem direto no fallback textual, sem GUI.
    try {
        if ($Host.Name -ne "ConsoleHost") {
            return $false
        }
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-NextecMultiSelection {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][object[]]$Items
    )

    if ($Items.Count -eq 0) {
        return [string[]]@()
    }

    if (Test-NextecInteractiveConsole) {
        $consoleResult = Get-NextecMultiSelectionConsole -Title $Title -Items $Items
        if ($consoleResult.Succeeded) {
            Show-Banner
            return [string[]]$consoleResult.Keys
        }
    }

    # Sem console interativo real ou com falha no menu por teclado: segue o
    # mesmo padrão do instalador Linux e usa seleção numérica via shell,
    # nunca uma interface gráfica.
    return Get-NextecMultiSelectionFallback -Title $Title -Items $Items
}

function Get-NextecExporterCatalog {
    # Catálogo único de exporters pré-definidos, usado tanto para montar a
    # árvore de seleção quanto para preencher os valores padrão em
    # Read-CustomExporters. "custom" representa "Outro endpoint Prometheus",
    # que aceita múltiplas entradas livres.
    return @(
        [pscustomobject]@{ Key = "redis_exporter";         Label = "Redis Exporter, padrão :9121";              DefaultTarget = "127.0.0.1:9121";  DefaultService = "redis" }
        [pscustomobject]@{ Key = "nginx_exporter";         Label = "Nginx Prometheus Exporter, padrão :9113";   DefaultTarget = "127.0.0.1:9113";  DefaultService = "nginx" }
        [pscustomobject]@{ Key = "apache_exporter";        Label = "Apache Exporter, padrão :9117";             DefaultTarget = "127.0.0.1:9117";  DefaultService = "apache" }
        [pscustomobject]@{ Key = "rabbitmq_prometheus";    Label = "RabbitMQ Prometheus, padrão :15692";        DefaultTarget = "127.0.0.1:15692"; DefaultService = "rabbitmq" }
        [pscustomobject]@{ Key = "elasticsearch_exporter"; Label = "Elasticsearch Exporter, padrão :9114";      DefaultTarget = "127.0.0.1:9114";  DefaultService = "elasticsearch" }
        [pscustomobject]@{ Key = "mongodb_exporter";       Label = "MongoDB Exporter, padrão :9216";            DefaultTarget = "127.0.0.1:9216";  DefaultService = "mongodb" }
        [pscustomobject]@{ Key = "nvidia_dcgm_exporter";   Label = "NVIDIA DCGM Exporter, padrão :9400";        DefaultTarget = "127.0.0.1:9400";  DefaultService = "gpu" }
        [pscustomobject]@{ Key = "custom";                 Label = "Outro endpoint Prometheus";                 DefaultTarget = "";                 DefaultService = "" }
    )
}

function New-NextecChecklistItem {
    # Monta um item da árvore de seleção sem depender do operador "+" de
    # hashtables. Em PowerShell, $h1 + $h2 lança "O item já foi adicionado"
    # quando as duas hashtables têm a mesma chave (ele chama .Add() por
    # baixo, não sobrescreve). Construir o objeto inteiro aqui, com todas as
    # propriedades sempre explícitas, evita essa classe de erro por completo.
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Label,
        [bool]$Selected = $false,
        [int]$Depth = 0,
        [string]$ParentKey = $null,
        [bool]$HasChildren = $false,
        [bool]$Expanded = $false
    )

    return [pscustomobject]@{
        Key         = $Key
        Label       = $Label
        Selected    = $Selected
        Depth       = $Depth
        ParentKey   = $ParentKey
        HasChildren = $HasChildren
        Expanded    = $Expanded
        Visible     = $true
        Enabled     = $true
    }
}

function Read-ResourceChecklist {
    param(
        [Parameter(Mandatory=$true)][bool]$MonitorHost,
        [Parameter(Mandatory=$true)][bool]$Collector,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$DetectedFeatures
    )

    $script:EnableLogsResolved = $EnableLogs.IsPresent
    $script:EnableLogWarningsResolved = $EnableLogWarnings.IsPresent
    $script:EnableSecurityLogsResolved = $EnableSecurityLogs.IsPresent
    $script:EnableSnmpResolved = $EnableSnmp.IsPresent
    $script:EnableBlackboxResolved = $EnableBlackbox.IsPresent
    $script:EnableExportersResolved = $EnableExporters.IsPresent
    $script:EnableInternetResolved = $EnableInternet.IsPresent
    $script:InternetIntervalMinutesResolved = $InternetIntervalMinutes
    $script:SelectedHostFeatureKeys = [string[]]@()
    $script:SelectedExporterKeys = [string[]]@()

    $items = New-Object System.Collections.Generic.List[object]

    if ($MonitorHost) {
        # Critical/Error e Warning são itens separados porque o custo é muito
        # diferente: Warning costuma responder pela maior parte do volume de
        # log de um servidor Windows e raramente é consultado.
        $items.Add((New-NextecChecklistItem -Key "logs" -Label "Logs do sistema, Critical e Error" -Selected $script:EnableLogsResolved))
        $items.Add((New-NextecChecklistItem -Key "logs_warning" -Label "Incluir também os avisos (Warning), aumenta muito o volume" -Selected $script:EnableLogWarningsResolved))
        $items.Add((New-NextecChecklistItem -Key "security" -Label "Logs de autenticação e segurança" -Selected $script:EnableSecurityLogsResolved))

        foreach ($feature in $DetectedFeatures) {
            $items.Add((New-NextecChecklistItem `
                -Key ("feature:{0}" -f $feature.Key) `
                -Label ("{0} (detectado)" -f $feature.Label) `
                -Selected ([bool]$feature.Selected)))
        }
    }

    if ($Collector) {
        $items.Add((New-NextecChecklistItem -Key "snmp" -Label "SNMP, firewalls/switches/UPS/APs" -Selected $script:EnableSnmpResolved))
        $items.Add((New-NextecChecklistItem -Key "blackbox" -Label "Conectividade e disponibilidade, ping/HTTP/TCP" -Selected $script:EnableBlackboxResolved))
        # Instala e configura sozinho: baixa o Speedtest CLI, grava o wrapper
        # e registra a tarefa agendada. Não pede nada além de marcar aqui.
        $items.Add((New-NextecChecklistItem -Key "internet" -Label "Internet (Speedtest), disponibilidade, latência, download e upload" -Selected $script:EnableInternetResolved))
    }

    # "Exporters adicionais" agora é uma categoria em árvore: ESPAÇO/ENTER
    # expande e mostra o catálogo de exporters como filhos selecionáveis,
    # em vez de abrir um fluxo de perguntas separado depois.
    $items.Add((New-NextecChecklistItem `
        -Key "exporter" `
        -Label "Exporters adicionais" `
        -Selected $script:EnableExportersResolved `
        -HasChildren $true `
        -Expanded $script:EnableExportersResolved))

    foreach ($definition in (Get-NextecExporterCatalog)) {
        $items.Add((New-NextecChecklistItem `
            -Key ("exporter:{0}" -f $definition.Key) `
            -Label $definition.Label `
            -Selected $false `
            -Depth 1 `
            -ParentKey "exporter"))
    }

    if ($Silent) {
        # Switch incompatível com o -Modo precisa falhar aqui. A resolução
        # abaixo é feita por -contains sobre a lista de itens, e itens que não
        # se aplicam ao modo nem entram na lista: o flag voltaria a $false sem
        # nenhuma mensagem, e um rollout via RMM instalaria hosts sem log e sem
        # probe reportando sucesso.
        if (($EnableLogs.IsPresent -or $EnableSecurityLogs.IsPresent -or $EnableLogWarnings.IsPresent) -and -not $MonitorHost) {
            throw "-EnableLogs, -EnableLogWarnings e -EnableSecurityLogs exigem um modo que monitore o host (servidor, estacao, servidor_collector ou estacao_collector)."
        }

        if ($EnableSnmp.IsPresent -and -not $Collector) {
            throw "-EnableSnmp exige -Modo collector, servidor_collector ou estacao_collector."
        }

        if ($EnableBlackbox.IsPresent -and -not $Collector) {
            throw "-EnableBlackbox exige -Modo collector, servidor_collector ou estacao_collector."
        }

        if ($EnableInternet.IsPresent -and -not $Collector) {
            throw "-EnableInternet exige -Modo collector, servidor_collector ou estacao_collector."
        }

        $selectedKeys = [string[]]@($items | Where-Object { $_.Selected } | ForEach-Object { $_.Key })
    }
    else {
        $selectedKeys = Get-NextecMultiSelection -Title "Recursos adicionais" -Items $items.ToArray()
    }

    $script:EnableLogsResolved = ($selectedKeys -contains "logs")
    $script:EnableLogWarningsResolved = ($selectedKeys -contains "logs_warning")
    $script:EnableSecurityLogsResolved = ($selectedKeys -contains "security")

    # Warning depende de Critical/Error: sozinho geraria um pipeline de log
    # sem o canal principal.
    if ($script:EnableLogWarningsResolved -and -not $script:EnableLogsResolved) {
        Write-Warn "Avisos (Warning) exigem a coleta de Critical/Error; ambos foram habilitados."
        $script:EnableLogsResolved = $true
    }
    $script:EnableSnmpResolved = ($selectedKeys -contains "snmp")
    $script:EnableBlackboxResolved = ($selectedKeys -contains "blackbox")
    $script:EnableInternetResolved = ($selectedKeys -contains "internet")
    if ($script:EnableInternetResolved) {
        $script:InternetIntervalMinutesResolved = $InternetIntervalMinutes
    }

    $featureKeys = New-Object System.Collections.Generic.List[string]
    $exporterKeys = New-Object System.Collections.Generic.List[string]

    foreach ($key in $selectedKeys) {
        if ($key -like "feature:*") {
            $featureKeys.Add($key.Substring(8))
        }
        elseif ($key -like "exporter:*") {
            $exporterKeys.Add($key.Substring(9))
        }
    }

    $script:SelectedHostFeatureKeys = [string[]]@($featureKeys)
    $script:SelectedExporterKeys = [string[]]@($exporterKeys)

    # No modo -Silent, "exporter" pode vir marcado diretamente (via -EnableExporters,
    # sem filhos na árvore). No modo interativo, o pai nunca é retornado como
    # selecionado (só os filhos); nesse caso, exporters habilitados = algum filho marcado.
    $script:EnableExportersResolved = (($selectedKeys -contains "exporter") -or ($exporterKeys.Count -gt 0))
}

function Read-BlackboxTargets {
    # Precisa espelhar os módulos de New-BlackboxConfiguration. Nome fora
    # desta lista passa pelo alloy validate e falha só em runtime, sem log.
    $validModules = @("icmp_ipv4", "http_2xx", "http_2xx_ssl", "tcp_connect", "dns_udp", "http_2xx_content")

    $script:BlackboxTargets = @()

    if (-not $script:EnableBlackboxResolved) {
        return
    }

    if ($Silent) {
        if ($BlackboxTarget.Count -eq 0) {
            throw "No modo silencioso com -EnableBlackbox, informe pelo menos um -BlackboxTarget no formato nome|endereco|modulo|tipo."
        }

        # Valida conteúdo, não só a quantidade de campos. Endereço vazio ou
        # módulo inexistente passam pelo alloy validate e só falham em runtime,
        # deixando o alvo sem dado no NOC sem nenhum erro visível.
        foreach ($entry in $BlackboxTarget) {
            $parts = @($entry -split "\|", 4)
            if ($parts.Count -ne 4) {
                throw ("BlackboxTarget inválido, use nome|endereco|modulo|tipo: {0}" -f $entry)
            }

            $targetName = ConvertTo-Slug $parts[0]

            if ([string]::IsNullOrWhiteSpace($targetName)) {
                throw ("BlackboxTarget com nome inválido após normalização: {0}" -f $entry)
            }

            if ([string]::IsNullOrWhiteSpace($parts[1])) {
                throw ("BlackboxTarget sem endereço: {0}" -f $entry)
            }

            if ($validModules -notcontains $parts[2]) {
                throw ("Módulo blackbox inválido '{0}'. Módulos disponíveis: {1}." -f $parts[2], ($validModules -join ", "))
            }

            $script:BlackboxTargets += [pscustomobject]@{
                Name = $targetName
                Address = $parts[1]
                Module = $parts[2]
                Type = ConvertTo-Slug $parts[3]
            }
        }

        return
    }

    Write-Step "Conectividade e disponibilidade (Blackbox)"

    # Cada opção carrega uma explicação curta do que ela realmente confere,
    # porque "HTTP 2xx" sozinho não deixa claro que só valida o código de
    # status: uma página que carrega com erro (ex.: WordPress quebrado) mas
    # ainda responde 200 passa despercebida. ICMP só confere se o host
    # responde a ping, nada além disso.
    $probeOptions = @(
        "ICMP/Ping - só confere se o host responde a ping. Não diz nada sobre um site ou serviço estar funcionando.",
        "HTTP 2xx - abre a URL e confere se a resposta veio com status 200-299. Não confere o conteúdo da página: um site com erro visível mas que responde 200 passa como OK.",
        "HTTPS 2xx com validação de certificado - igual ao HTTP 2xx, mas exige HTTPS válido e também avisa quando o certificado está perto de vencer.",
        "TCP connect - só confere se a porta aceita conexão. Não valida o que roda por cima dela.",
        "DNS (UDP) - confere se o servidor DNS responde a uma consulta.",
        "HTTP 2xx com verificação de conteúdo - além do status 200-299, falha se a página trouxer um erro conhecido no corpo (ex.: 'Há um erro crítico' do WordPress, erro de conexão com banco, 500/502/503). Pega o caso de página que carrega mas está quebrada."
    )
    $moduleByOption = @{ 1 = "icmp_ipv4"; 2 = "http_2xx"; 3 = "http_2xx_ssl"; 4 = "tcp_connect"; 5 = "dns_udp"; 6 = "http_2xx_content" }
    $suffixByOption = @{ 1 = "ping"; 2 = "http"; 3 = "https"; 4 = "tcp"; 5 = "dns"; 6 = "content" }

    do {
        $name = ConvertTo-Slug (Read-Required "Nome do alvo (ex.: fw_matriz)")
        $address = Read-Required "IP, FQDN ou URL"

        Write-Host "Tipo de teste (pode escolher mais de um, separados por vírgula, ex.: 1,2)" -ForegroundColor White
        for ($i = 0; $i -lt $probeOptions.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $probeOptions[$i])
        }

        $selectedOptions = $null
        while ($null -eq $selectedOptions) {
            $raw = Read-Host "Escolha [1]"
            if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "1" }

            $numbers = New-Object System.Collections.Generic.List[int]
            $valido = $true
            foreach ($part in ($raw -split ",")) {
                $trimmed = $part.Trim()
                if ($trimmed -eq "") { continue }
                $n = 0
                if (-not [int]::TryParse($trimmed, [ref]$n) -or $n -lt 1 -or $n -gt $probeOptions.Count) {
                    $valido = $false
                    break
                }
                if (-not $numbers.Contains($n)) { $numbers.Add($n) }
            }

            if (-not $valido -or $numbers.Count -eq 0) {
                Write-Warn "Opção inválida."
                continue
            }

            $selectedOptions = $numbers
        }
        Write-Host ""

        # "site" existe à parte de "aplicacao" porque monitoramento de site
        # público (com ou sem loja/aplicação por trás) é um cenário próprio,
        # cada vez mais comum em clientes sem firewall dedicado.
        $typeOptions = @("firewall","switch","link","aplicacao","site","storage")
        $typeChoice = Read-Choice -Prompt "Tipo do ativo" -Options $typeOptions -Default 1
        $assetType = $typeOptions[$typeChoice - 1]

        # Mais de um teste no mesmo alvo (ex.: ping + HTTP) vira mais de uma
        # entrada de blackbox, uma por módulo, com o nome sufixado para não
        # colidir; com um teste só o nome digitado fica como está.
        $multiplo = $selectedOptions.Count -gt 1
        foreach ($opcao in $selectedOptions) {
            $targetName = if ($multiplo) { "{0}_{1}" -f $name, $suffixByOption[$opcao] } else { $name }

            $script:BlackboxTargets += [pscustomobject]@{
                Name = $targetName
                Address = $address
                Module = $moduleByOption[$opcao]
                Type = $assetType
            }
        }

        $again = Read-YesNo -Prompt "Adicionar outro alvo de conectividade/disponibilidade?" -Default $false
    }
    while ($again)

    Read-BlackboxInterval
}

function Get-NextecSnmpConfigFromRepo {
    <#
        Baixa o snmp.yml homologado direto do repositório Sou-Nextec/Scripts,
        pelo tipo de fabricante escolhido pelo operador. Evita depender de o
        arquivo já estar copiado manualmente na máquina.
    #>
    Write-Host ""
    Write-Host "Fabricantes disponíveis no repositório Nextec:"
    foreach ($key in $NextecSnmpVendors.Keys) {
        Write-Host ("  [{0}] {1}" -f $key, $NextecSnmpVendors[$key].Label)
    }

    $vendorChoice = Read-Required -Prompt ("Escolha o fabricante [1-{0}]" -f $NextecSnmpVendors.Count)

    if (-not $NextecSnmpVendors.Contains($vendorChoice)) {
        Write-Warn "Opção inválida."
        return $null
    }

    $vendor = $NextecSnmpVendors[$vendorChoice]
    $url = "{0}/{1}" -f $NextecSnmpRepoBaseUrl, $vendor.File
    $destino = Join-Path $env:TEMP ("nextec-snmp-{0}" -f $vendor.File)

    try {
        Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing
    }
    catch {
        Write-Warn ("Falha ao baixar {0}: {1}" -f $url, $_.Exception.Message)
        return $null
    }

    Write-Info ("Baixado de {0}" -f $url)
    return $destino
}

function Get-SnmpConfigSectionKeys {
    <#
        Devolve as chaves de primeiro nível de uma seção do snmp.yml
        ("modules" ou "auths").

        Parser de texto, não de YAML: o PowerShell 5.1 não traz leitor de YAML
        e o pfsense.yml passa de 270 KB, grande demais para converter inteiro
        só para descobrir dois nomes. As chaves ficam sempre com dois espaços
        de indentação sob a seção, formato gerado pelo snmp_exporter.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Section
    )

    $keys = @()
    $inSection = $false
    $sectionPattern = "^{0}\s*:" -f [regex]::Escape($Section)

    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match "^\s*#") {
            continue
        }

        if ($line -match $sectionPattern) {
            $inSection = $true
            continue
        }

        if (-not $inSection) {
            continue
        }

        # Linha começando na coluna zero encerra a seção.
        if ($line -match "^\S") {
            break
        }

        if ($line -match "^\s{2}(?<key>[A-Za-z0-9_.\-]+)\s*:\s*$") {
            $keys += $Matches["key"]
        }
    }

    return $keys
}

function Get-SnmpAuthBlocksFromFile {
    <#
        Recupera os blocos da seção "auths" de um snmp-auth.yml já instalado,
        cada um como um texto pronto para ser regravado.

        Serve para preservar a credencial dos equipamentos que já existem
        quando o operador acrescenta um alvo novo pelo menu: sem isso o
        arquivo é regravado só com a auth nova e os alvos antigos passam a
        apontar para uma chave inexistente, o que o Alloy aceita em silêncio.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    $blocks = @()

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $blocks
    }

    $current = $null
    $inSection = $false

    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match "^auths\s*:") {
            $inSection = $true
            continue
        }

        if (-not $inSection) {
            continue
        }

        if ($line -match "^\S") {
            break
        }

        if ($line -match "^\s{2}[A-Za-z0-9_.\-]+\s*:\s*$") {
            if ($null -ne $current) {
                $blocks += ($current -join [Environment]::NewLine)
            }

            $current = @($line.TrimEnd())
            continue
        }

        if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($line)) {
            $current += $line.TrimEnd()
        }
    }

    if ($null -ne $current) {
        $blocks += ($current -join [Environment]::NewLine)
    }

    return $blocks
}

function Get-SnmpModuleBlocksFromFile {
    <#
        Devolve os blocos da seção "modules" indexados pelo nome do módulo,
        cada um como a lista de linhas originais.

        Usado para acumular fabricantes diferentes num único snmp.yml, já que
        o Alloy aceita um arquivo por exporter e um host pode ter firewall,
        switch e nobreak de marcas distintas.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    $blocks = [ordered]@{}

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $blocks
    }

    $currentName = $null
    $currentLines = $null
    $inSection = $false

    foreach ($line in [IO.File]::ReadLines($Path)) {
        if (-not $inSection) {
            if ($line -match "^modules\s*:") {
                $inSection = $true
            }

            continue
        }

        if ($line -match "^\S") {
            break
        }

        if ($line -match "^\s{2}(?<key>[A-Za-z0-9_.\-]+)\s*:\s*$") {
            if ($null -ne $currentName) {
                $blocks[$currentName] = $currentLines
            }

            $currentName = $Matches["key"]
            $currentLines = @($line.TrimEnd())
            continue
        }

        if ($null -ne $currentName) {
            $currentLines += $line.TrimEnd()
        }
    }

    if ($null -ne $currentName) {
        $blocks[$currentName] = $currentLines
    }

    return $blocks
}

function Merge-SnmpModuleFile {
    <#
        Acumula no snmp.yml instalado os módulos de um arquivo novo, sem
        remover os que já estavam lá.

        Copiar por cima mataria o equipamento anterior: o config.alloy
        continuaria pedindo, por exemplo, "pfsense_v2c" num arquivo que agora
        só tem os módulos do Mikrotik. O Alloy não acusa isso, o alvo só para
        de coletar.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$NewFile,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    $newBlocks = Get-SnmpModuleBlocksFromFile -Path $NewFile

    if ($newBlocks.Count -eq 0) {
        throw ("Nenhum módulo encontrado na seção 'modules' de {0}." -f $NewFile)
    }

    $merged = Get-SnmpModuleBlocksFromFile -Path $Destination
    $added = @()

    foreach ($name in @($newBlocks.Keys)) {
        if ($merged.Contains($name)) {
            continue
        }

        $merged[$name] = $newBlocks[$name]
        $added += $name
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Gerado pelo instalador Nextec. Acumula os módulos SNMP dos fabricantes")
    [void]$lines.Add("# usados por este host. As credenciais ficam em snmp-auth.yml.")
    [void]$lines.Add("modules:")

    foreach ($name in @($merged.Keys)) {
        foreach ($line in $merged[$name]) {
            [void]$lines.Add($line)
        }
    }

    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Destination, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)

    if ($added.Count -gt 0) {
        Write-Info ("Módulos acrescentados ao snmp.yml: {0}" -f ($added -join ", "))
    }

    $preserved = @($merged.Keys | Where-Object { $added -notcontains $_ })
    if ($preserved.Count -gt 0) {
        Write-Info ("Módulos preservados: {0}" -f ($preserved -join ", "))
    }
}

function Get-SnmpAuthBlockName {
    param([Parameter(Mandatory=$true)][string]$Block)

    $firstLine = @($Block -split "`r?`n")[0]
    return $firstLine.Trim().TrimEnd(":").Trim()
}

function Select-SnmpModules {
    <#
        Escolhe quais módulos do arquivo entram no alvo.

        O sufixo de versão (_v1, _v2c, _v3) marca variantes do MESMO módulo,
        que diferem apenas na versão SNMP: só uma pode entrar, senão o mesmo
        walk é feito duas vezes e uma das cópias falha na autenticação.
        Módulos sem esse sufixo são complementares e entram todos.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Modules,
        [Parameter(Mandatory=$true)][string]$SnmpVersion
    )

    if ($Modules.Count -eq 0) {
        return ""
    }

    $selected = @()
    $families = [ordered]@{}

    foreach ($module in $Modules) {
        if ($module -match "^(?<base>.+)_(?<version>v1|v2c|v2|v3)$") {
            $base = $Matches["base"]
            $version = $Matches["version"]

            if (-not $families.Contains($base)) {
                $families[$base] = [ordered]@{}
            }

            $families[$base][$version] = $module
        }
        else {
            $selected += $module
        }
    }

    foreach ($base in @($families.Keys)) {
        $variants = $families[$base]

        if ($variants.Contains($SnmpVersion)) {
            $selected += $variants[$SnmpVersion]
            continue
        }

        $fallback = @($variants.Values)[0]
        Write-Warn ("O arquivo não tem variante {0} de '{1}'; usando '{2}'. Confira se a credencial bate com a versão do módulo." -f $SnmpVersion, $base, $fallback)
        $selected += $fallback
    }

    return ($selected -join ",")
}

function ConvertTo-YamlSingleQuoted {
    <#
        Escapa um valor para YAML entre aspas simples, onde a única sequência
        especial é a própria aspa simples, duplicada. Senhas SNMP costumam ter
        $, ! e # e não sobrevivem a aspas duplas sem tratamento.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    return ("'{0}'" -f ($Value -replace "'", "''"))
}

function Read-SnmpAuthDefinition {
    <#
        Monta a credencial SNMP do equipamento e devolve o nome da auth mais o
        bloco YAML correspondente.

        O snmp.yml do repositório traz só "modules". A seção "auths" é do
        cliente e é escrita aqui, em arquivo separado, para nunca ir para o
        repositório junto com o módulo do fabricante.
    #>
    param([Parameter(Mandatory=$true)][string]$EquipmentName)

    $versionChoice = Read-Choice -Prompt "Versão SNMP" -Options @("v2c (community)","v3 (usuário e senha)") -Default 1
    $lines = @()

    if ($versionChoice -eq 1) {
        $authName = ConvertTo-Slug ("{0}_v2c" -f $EquipmentName)
        $community = Read-Required -Prompt "Community SNMP" -Default "public"

        $lines += ("  {0}:" -f $authName)
        $lines += "    version: 2"
        $lines += ("    community: {0}" -f (ConvertTo-YamlSingleQuoted $community))

        return [pscustomobject]@{
            Name = $authName
            Version = "v2c"
            Yaml = ($lines -join [Environment]::NewLine)
        }
    }

    $authName = ConvertTo-Slug ("{0}_v3" -f $EquipmentName)
    $username = Read-Required -Prompt "Usuário SNMPv3" -Default "nextec_monitoramento"

    $levelChoice = Read-Choice -Prompt "Nível de segurança" -Options @("authPriv (autenticação e criptografia)","authNoPriv (só autenticação)") -Default 1
    $authProtocol = Read-Required -Prompt "Protocolo de autenticação" -Default "SHA"
    $authPassword = Read-RequiredSecret -Prompt "Senha de autenticação"

    $lines += ("  {0}:" -f $authName)
    $lines += "    version: 3"
    $lines += ("    username: {0}" -f (ConvertTo-YamlSingleQuoted $username))
    $lines += ("    auth_protocol: {0}" -f $authProtocol)
    $lines += ("    password: {0}" -f (ConvertTo-YamlSingleQuoted $authPassword))

    if ($levelChoice -eq 1) {
        $privProtocol = Read-Required -Prompt "Protocolo de criptografia" -Default "AES"
        $privPassword = Read-RequiredSecret -Prompt "Senha de criptografia"

        $lines += "    security_level: authPriv"
        $lines += ("    priv_protocol: {0}" -f $privProtocol)
        $lines += ("    priv_password: {0}" -f (ConvertTo-YamlSingleQuoted $privPassword))
    }
    else {
        $lines += "    security_level: authNoPriv"
    }

    return [pscustomobject]@{
        Name = $authName
        Version = "v3"
        Yaml = ($lines -join [Environment]::NewLine)
    }
}

function Read-SnmpTargets {
    <#
        -Append acrescenta equipamentos a uma configuração existente: mantém
        os alvos já lidos, recupera do disco as credenciais dos equipamentos
        atuais e reaproveita o snmp.yml instalado, em vez de recomeçar do zero.
    #>
    param([switch]$Append)

    if (-not $Append) {
        $script:SnmpTargets = @()
        $script:SnmpSourceFile = $null
        $script:SnmpAuthBlocks = @()
    }
    else {
        $script:SnmpAuthBlocks = @(Get-SnmpAuthBlocksFromFile -Path $SnmpAuthFile)
    }

    if (-not $script:EnableSnmpResolved) {
        return
    }

    if ($Silent) {
        if ([string]::IsNullOrWhiteSpace($SnmpConfig) -or -not (Test-Path -LiteralPath $SnmpConfig -PathType Leaf)) {
            throw "No modo silencioso com -EnableSnmp, informe -SnmpConfig apontando para um snmp.yml válido."
        }

        if ($SnmpTarget.Count -eq 0) {
            throw "No modo silencioso com -EnableSnmp, informe pelo menos um -SnmpTarget no formato nome|endereco|modulo|auth|tipo|os."
        }

        $script:SnmpSourceFile = (Resolve-Path -LiteralPath $SnmpConfig).Path

        # No modo silencioso o arquivo precisa trazer as duas seções, porque
        # não há operador para informar credencial. Módulo ou auth inexistente
        # passa por fmt e validate e sobe "healthy": o alvo nunca produz série
        # e a automação registra sucesso.
        $modulosValidos = @(Get-SnmpConfigSectionKeys -Path $script:SnmpSourceFile -Section "modules")
        $authsValidas = @(Get-SnmpConfigSectionKeys -Path $script:SnmpSourceFile -Section "auths")

        if ($modulosValidos.Count -eq 0) {
            throw ("O arquivo {0} não tem seção 'modules'." -f $script:SnmpSourceFile)
        }

        if ($authsValidas.Count -eq 0) {
            throw ("O arquivo {0} não tem seção 'auths'. No modo silencioso o -SnmpConfig precisa conter módulos e credenciais." -f $script:SnmpSourceFile)
        }

        $nomesUsados = @()

        foreach ($entry in $SnmpTarget) {
            $parts = @($entry -split "\|", 6)
            if ($parts.Count -ne 6) {
                throw ("SnmpTarget inválido: {0}" -f $entry)
            }

            $nome = ConvertTo-Slug $parts[0]

            if ([string]::IsNullOrWhiteSpace($nome)) {
                throw ("SnmpTarget com nome inválido após normalização: {0}" -f $entry)
            }

            if ($nomesUsados -contains $nome) {
                throw ("SnmpTarget duplicado: {0}. Nomes repetidos derrubam o exporter SNMP inteiro." -f $nome)
            }

            if ([string]::IsNullOrWhiteSpace($parts[1])) {
                throw ("SnmpTarget sem endereço: {0}" -f $entry)
            }

            foreach ($modulo in @($parts[2] -split ",")) {
                if ($modulosValidos -notcontains $modulo.Trim()) {
                    throw ("Módulo SNMP '{0}' não existe em {1}. Disponíveis: {2}" -f $modulo.Trim(), $script:SnmpSourceFile, ($modulosValidos -join ", "))
                }
            }

            if ($authsValidas -notcontains $parts[3]) {
                throw ("Auth SNMP '{0}' não existe em {1}. Disponíveis: {2}" -f $parts[3], $script:SnmpSourceFile, ($authsValidas -join ", "))
            }

            $nomesUsados += $nome

            $script:SnmpTargets += [pscustomobject]@{
                Name = $nome
                Address = $parts[1]
                Module = $parts[2]
                Auth = $parts[3]
                Type = ConvertTo-Slug $parts[4]
                Os = ConvertTo-Slug $parts[5]
            }
        }

        return
    }

    Write-Step "SNMP"

    $temArquivoInstalado = Test-Path -LiteralPath $SnmpFile -PathType Leaf
    $opcoesOrigem = @("Baixar do repositório Nextec (GitHub)","Informar caminho local")

    if ($temArquivoInstalado) {
        $opcoesOrigem += "Usar o snmp.yml já instalado neste host"
    }

    while ($true) {
        $origem = Read-Choice -Prompt "Origem do snmp.yml" -Options $opcoesOrigem -Default $(if ($temArquivoInstalado) { 3 } else { 1 })

        if ($origem -eq 3) {
            $script:SnmpSourceFile = (Resolve-Path -LiteralPath $SnmpFile).Path
            break
        }

        if ($origem -eq 1) {
            $candidate = Get-NextecSnmpConfigFromRepo

            if ($null -eq $candidate) {
                continue
            }
        }
        else {
            $candidate = Read-Required "Caminho do snmp.yml homologado pela Nextec"
        }

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $script:SnmpSourceFile = (Resolve-Path -LiteralPath $candidate).Path
            break
        }

        Write-Warn ("Arquivo não encontrado: {0}" -f $candidate)
    }

    # Fabricantes diferentes convivem no mesmo host: os módulos do arquivo
    # escolhido são somados aos que já estão instalados, então a lista
    # oferecida ao operador precisa considerar as duas origens.
    $availableModules = @(Get-SnmpConfigSectionKeys -Path $script:SnmpSourceFile -Section "modules")

    if ($temArquivoInstalado) {
        foreach ($instalado in @(Get-SnmpConfigSectionKeys -Path $SnmpFile -Section "modules")) {
            if ($availableModules -notcontains $instalado) {
                $availableModules += $instalado
            }
        }
    }

    if ($availableModules.Count -eq 0) {
        throw ("Nenhum módulo encontrado na seção 'modules' de {0}." -f $script:SnmpSourceFile)
    }

    Write-Info ("Módulos disponíveis: {0}" -f ($availableModules -join ", "))

    do {
        # Nome repetido gera chave duplicada em auths e derruba o exporter
        # SNMP inteiro em tempo de execução, não só o alvo repetido. O laço
        # fica aqui, e não no do/while externo, porque "continue" ali pularia
        # para a condição de repetição antes de ela ser definida.
        $name = ""

        while ([string]::IsNullOrWhiteSpace($name)) {
            $name = ConvertTo-Slug (Read-Required "Nome do equipamento")

            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Warn "Nome inválido após normalização. Use letras, números, hífen ou sublinhado."
                continue
            }

            if (@($script:SnmpTargets | ForEach-Object { $_.Name }) -contains $name) {
                Write-Warn ("Já existe um equipamento chamado '{0}' nesta configuração. Use outro nome." -f $name)
                $name = ""
            }
        }

        $address = Read-Required "IP/FQDN SNMP"

        $authDefinition = Read-SnmpAuthDefinition -EquipmentName $name
        $auth = $authDefinition.Name
        $script:SnmpAuthBlocks += $authDefinition.Yaml

        $module = Select-SnmpModules -Modules $availableModules -SnmpVersion $authDefinition.Version

        if ([string]::IsNullOrWhiteSpace($module)) {
            throw "Não foi possível determinar o módulo SNMP a partir do arquivo informado."
        }

        Write-Info ("Módulo aplicado: {0}" -f $module)

        $typeOptions = @("firewall","switch","storage","ap","ups")
        $typeChoice = Read-Choice -Prompt "Tipo do equipamento" -Options $typeOptions -Default 1
        $assetType = $typeOptions[$typeChoice - 1]

        $system = ConvertTo-Slug (Read-Required -Prompt "Sistema/fabricante" -Default "network")

        $script:SnmpTargets += [pscustomobject]@{
            Name = $name
            Address = $address
            Module = $module
            Auth = $auth
            Type = $assetType
            Os = $system
        }

        $again = Read-YesNo -Prompt "Adicionar outro equipamento SNMP?" -Default $false
    }
    while ($again)
}

function Read-CustomExporters {
    $script:CustomExporters = @()

    if (-not $script:EnableExportersResolved) {
        return
    }

    if ($Silent) {
        if ($CustomExporter.Count -eq 0) {
            throw "No modo silencioso com -EnableExporters, informe pelo menos um -CustomExporter no formato nome|host:porta|servico."
        }

        foreach ($entry in $CustomExporter) {
            $parts = @($entry -split "\|", 3)
            if ($parts.Count -ne 3) {
                throw ("CustomExporter inválido: {0}" -f $entry)
            }

            $script:CustomExporters += [pscustomobject]@{
                Name = ConvertTo-Slug $parts[0]
                Target = $parts[1]
                Service = ConvertTo-Slug $parts[2]
            }
        }

        return
    }

    Write-Step "Exporters adicionais"

    $catalog = Get-NextecExporterCatalog
    $selectedKeys = @($script:SelectedExporterKeys)

    foreach ($exporterKey in $selectedKeys) {
        if ($exporterKey -eq "custom") {
            continue
        }

        $definition = $catalog | Where-Object { $_.Key -eq $exporterKey } | Select-Object -First 1

        if ($null -eq $definition) {
            continue
        }

        Write-Info $definition.Label
        $target = Read-Required -Prompt "Target host:porta" -Default $definition.DefaultTarget
        $service = ConvertTo-Slug (Read-Required -Prompt "Label servico" -Default $definition.DefaultService)

        $script:CustomExporters += [pscustomobject]@{
            Name = $definition.Key
            Target = $target
            Service = $service
        }
    }

    if ($selectedKeys -contains "custom") {
        do {
            $name = ConvertTo-Slug (Read-Required "Nome do exporter")
            $target = Read-Required -Prompt "Target host:porta" -Default ""
            $service = ConvertTo-Slug (Read-Required -Prompt "Label servico" -Default $name)

            $script:CustomExporters += [pscustomobject]@{
                Name = $name
                Target = $target
                Service = $service
            }

            $again = Read-YesNo -Prompt "Adicionar outro endpoint Prometheus customizado?" -Default $false
        }
        while ($again)
    }

    if ($script:CustomExporters.Count -eq 0) {
        Write-Warn "Nenhum exporter configurado apesar da categoria marcada; nada será adicionado ao config.alloy."
    }
}

function Get-NextecConfiguration {
    param(
        [Parameter(Mandatory=$true)][object]$Inventory,
        # [AllowEmptyCollection()] é necessário pelo mesmo motivo das outras
        # ocorrências deste parâmetro: estação Windows 10/11 ou servidor sem
        # nenhuma função compatível detectada chega aqui com array vazio, e
        # um parâmetro Mandatory recusa array vazio por padrão.
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$DetectedFeatures
    )

    Write-Step "Identificação"

    if ([string]::IsNullOrWhiteSpace($Cliente)) {
        if ($Silent) {
            throw "No modo silencioso, informe -Cliente."
        }

        $rawCliente = Read-Required "Cliente (ex.: cliente_exemplo)"
        $script:Cliente = ConvertTo-Slug $rawCliente
    }
    else {
        $script:Cliente = ConvertTo-Slug $Cliente
    }

    # Aceita hífen porque ConvertTo-Slug preserva hífen. As duas regras
    # precisam concordar, senão nomes como "Cartorio-Bruno" são normalizados e
    # rejeitados em seguida.
    if ($script:Cliente -notmatch "^[a-z0-9][a-z0-9_-]*$") {
        throw ("Cliente inválido após normalização: {0}" -f $script:Cliente)
    }

    if ($Silent) {
        if ([string]::IsNullOrWhiteSpace($Inventory.Hostname)) {
            throw "Não foi possível detectar o hostname automaticamente. Modo silencioso exige hostname detectável (env:COMPUTERNAME)."
        }
        $script:HostLabel = ConvertTo-Slug $Inventory.Hostname
    } else {
        $detectedHost = ConvertTo-Slug $Inventory.Hostname
        $script:HostLabel = ConvertTo-Slug (Read-Required -Prompt "Hostname para monitoramento" -Default $detectedHost)
    }

    $script:Ambiente = $Ambiente
    $script:Local = ConvertTo-Slug $Local
    $script:Criticidade = $Criticidade
    $script:MonitorHost = $false
    $script:Collector = $false
    $script:BlackboxTargets = @()
    $script:SnmpTargets = @()
    $script:CustomExporters = @()
    $script:SnmpSourceFile = $null
    $script:SnmpAuthBlocks = @()
    $script:DetectedHostFeatures = @($DetectedFeatures)
    $script:SelectedHostFeatureKeys = [string[]]@()

    if (-not $Silent) {
        $ambienteOptions = @("producao","homologacao","desenvolvimento","backup","teste")
        $ambienteChoice = Read-Choice -Prompt "Ambiente" -Options $ambienteOptions -Default 1
        $script:Ambiente = $ambienteOptions[$ambienteChoice - 1]

        $script:Local = ConvertTo-Slug (Read-Required -Prompt "Local" -Default $Local)

        $criticidadeOptions = @("critico","alto","medio","baixo")
        $defaultCrit = [Array]::IndexOf($criticidadeOptions, $Criticidade) + 1
        if ($defaultCrit -lt 1) {
            $defaultCrit = 2
        }

        $critChoice = Read-Choice -Prompt "Criticidade" -Options $criticidadeOptions -Default $defaultCrit
        $script:Criticidade = $criticidadeOptions[$critChoice - 1]
    }

    if ([string]::IsNullOrWhiteSpace($script:Local)) {
        throw "Local inválido após normalização."
    }

    Write-Step "Função deste Alloy"

    if (-not $Silent -and $Modo -eq "auto") {
        if ($Inventory.ProductType -eq 1) {
            $modeOptions = @("Estação monitorada", "Collector de rede", "Estação + Collector de rede")
        }
        else {
            $modeOptions = @("Servidor monitorado", "Collector de rede", "Servidor + Collector de rede")
        }

        $modeChoice = Read-Choice -Prompt "Selecione o modo" -Options $modeOptions -Default 1

        switch ($modeChoice) {
            1 { $script:MonitorHost = $true;  $script:Collector = $false }
            2 { $script:MonitorHost = $false; $script:Collector = $true }
            3 { $script:MonitorHost = $true;  $script:Collector = $true }
        }

        if ($Inventory.ProductType -eq 1) {
            $script:ResolvedMode = if ($script:Collector) { "estacao_collector" } else { "estacao" }
        }
        else {
            $script:ResolvedMode = if ($script:Collector) { "servidor_collector" } else { "servidor" }
        }
    }
    else {
        $resolved = Resolve-Mode -Inventory $Inventory

        switch ($resolved) {
            "servidor"           { $script:MonitorHost=$true;  $script:Collector=$false; $script:ResolvedMode="servidor" }
            "estacao"            { $script:MonitorHost=$true;  $script:Collector=$false; $script:ResolvedMode="estacao" }
            "collector"          { $script:MonitorHost=$false; $script:Collector=$true;  $script:ResolvedMode="collector" }
            "servidor_collector" { $script:MonitorHost=$true;  $script:Collector=$true;  $script:ResolvedMode="servidor_collector" }
            "estacao_collector"  { $script:MonitorHost=$true;  $script:Collector=$true;  $script:ResolvedMode="estacao_collector" }
            default               { throw ("Modo inválido: {0}" -f $resolved) }
        }
    }

    # "estacao" ainda não consta do catálogo de "tipo" do documento 02, então
    # um host com esse valor fica fora dos painéis e regras que filtram por
    # tipo. É aviso e não erro porque monitorar uma estação crítica é caso de
    # uso legítimo.
    $script:TipoLabel = if ($Inventory.ProductType -eq 1) { "estacao" } else { "servidor" }

    if ($script:TipoLabel -eq "estacao") {
        Write-Warn "Este host será rotulado como tipo=estacao, valor ainda não homologado no catálogo do documento 02. Confirme com o NOC antes de usar em produção."
    }

    if ($script:MonitorHost) {
        Write-Host "Perfil mínimo recomendado, habilitado automaticamente:" -ForegroundColor White
        Write-Host "  [x] CPU"
        Write-Host "  [x] Memória"
        Write-Host "  [x] Filesystem e discos"
        Write-Host "  [x] Rede e interfaces"
        Write-Host "  [x] Uptime e informações do sistema"
        Write-Host "  [x] Serviços Windows"
        Write-Host ""
    }

    Read-ResourceChecklist -MonitorHost $script:MonitorHost -Collector $script:Collector -DetectedFeatures @($script:DetectedHostFeatures)
    Read-BlackboxTargets
    Read-SnmpTargets
    Read-CustomExporters
}

function Read-NocCredentials {
    Write-Step "Credenciais do NOC"

    $rwUser = [Environment]::GetEnvironmentVariable("NEXTEC_RW_USERNAME", "Process")
    $rwPassword = [Environment]::GetEnvironmentVariable("NEXTEC_RW_PASSWORD", "Process")

    if ([string]::IsNullOrWhiteSpace($rwUser)) {
        if ($Silent) {
            throw "No modo silencioso, defina NEXTEC_RW_USERNAME no ambiente do processo."
        }

        $rwUser = Read-Required "Usuário do remote_write"
    }

    if ([string]::IsNullOrWhiteSpace($rwPassword)) {
        if ($Silent) {
            throw "No modo silencioso, defina NEXTEC_RW_PASSWORD no ambiente do processo."
        }

        $rwPassword = Read-RequiredSecret "Senha do remote_write"
    }

    $script:RwUsername = $rwUser
    $script:RwPassword = $rwPassword

    if (-not ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved)) {
        return
    }

    $lokiUser = [Environment]::GetEnvironmentVariable("NEXTEC_LOKI_USERNAME", "Process")
    $lokiPassword = [Environment]::GetEnvironmentVariable("NEXTEC_LOKI_PASSWORD", "Process")

    if ([string]::IsNullOrWhiteSpace($lokiUser) -or [string]::IsNullOrWhiteSpace($lokiPassword)) {
        if ($Silent) {
            $lokiUser = $rwUser
            $lokiPassword = $rwPassword
        }
        else {
            $sameCredential = Read-YesNo -Prompt "Usar a mesma credencial no Loki?" -Default $true

            if ($sameCredential) {
                $lokiUser = $rwUser
                $lokiPassword = $rwPassword
            }
            else {
                $lokiUser = Read-Required "Usuário do Loki"
                $lokiPassword = Read-RequiredSecret "Senha do Loki"
            }
        }
    }

    $script:LokiUsername = $lokiUser
    $script:LokiPassword = $lokiPassword
}

function Show-Plan {
    param([Parameter(Mandatory=$true)][object]$Inventory)

    Write-Step "Resumo antes da instalação"

    $rows = [ordered]@{
        "Cliente"       = $script:Cliente
        "Host"          = $script:HostLabel
        "Sistema"       = $Inventory.Caption
        "Build"         = $Inventory.Build
        "Tipo detectado"= $Inventory.Generation
        "Modo Alloy"    = $script:ResolvedMode
        "Ambiente"      = $script:Ambiente
        "Local"         = $script:Local
        "Criticidade"   = $script:Criticidade
        "Destino"       = $script:NocHost
    }

    foreach ($entry in $rows.GetEnumerator()) {
        Write-Host ("  {0,-27} {1}" -f ($entry.Key + ":"), $entry.Value)
    }

    if ($script:MonitorHost) {
        Write-Host ("  {0,-27} {1}" -f "Perfil base:", "CPU, memória, discos, rede, uptime, serviços")

        $selectedFeatures = @($script:DetectedHostFeatures | Where-Object { $script:SelectedHostFeatureKeys -contains $_.Key })
        $featureText = if ($selectedFeatures.Count -gt 0) { ($selectedFeatures | ForEach-Object { $_.Label }) -join ", " } else { "nenhum adicional" }
        Write-Host ("  {0,-27} {1}" -f "Recursos detectados:", $featureText)
        Write-Host ("  {0,-27} {1}" -f "Logs do sistema:", $(if ($script:EnableLogsResolved) { "sim" } else { "não" }))
        Write-Host ("  {0,-27} {1}" -f "Logs de autenticação:", $(if ($script:EnableSecurityLogsResolved) { "sim" } else { "não" }))
    }

    if ($script:Collector) {
        Write-Host ("  {0,-27} {1}" -f "SNMP:", $(if ($script:EnableSnmpResolved) { "sim ($($script:SnmpTargets.Count))" } else { "não" }))
        Write-Host ("  {0,-27} {1}" -f "Conectividade:", $(if ($script:EnableBlackboxResolved) { "sim ($($script:BlackboxTargets.Count))" } else { "não" }))
        Write-Host ("  {0,-27} {1}" -f "Internet (Speedtest):", $(if ($script:EnableInternetResolved) { "sim (a cada $($script:InternetIntervalMinutesResolved) min)" } else { "não" }))
    }

    Write-Host ("  {0,-27} {1}" -f "Exporters adicionais:", $script:CustomExporters.Count)

    if (-not $Silent) {
        if (-not (Read-YesNo -Prompt "Confirmar instalação/configuração?" -Default $true)) {
            throw "Instalação cancelada pelo operador."
        }
    }
}

# ==============================================================================
# CONECTIVIDADE
# ==============================================================================

function Test-NocConnectivityOnce {
    $addresses = $null

    try {
        $addresses = [Net.Dns]::GetHostAddresses($script:NocHost)
    }
    catch {
        throw ("DNS não resolve {0}: {1}" -f $script:NocHost, $_.Exception.Message)
    }

    if ($null -eq $addresses -or $addresses.Count -eq 0) {
        throw ("DNS não resolve {0}: nenhum endereço retornado." -f $script:NocHost)
    }

    $ipStrings = @($addresses | ForEach-Object { $_.IPAddressToString })
    Write-Ok ("DNS resolve {0}: {1}" -f $script:NocHost, ($ipStrings -join ", "))

    if (-not (Test-TcpPort -ComputerName $script:NocHost -Port 443 -TimeoutMs 5000)) {
        throw ("TCP 443 para {0} não está acessível." -f $script:NocHost)
    }

    Write-Ok "TCP 443 acessível."

    try {
        $request = [Net.HttpWebRequest]::Create("https://$($script:NocHost)/")
        $request.Method = "HEAD"
        $request.Timeout = 8000
        $request.AllowAutoRedirect = $true

        try {
            $response = $request.GetResponse()
            $response.Close()
            Write-Ok "TLS/HTTPS respondeu."
        }
        catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $_.Exception.Response.Close()
                Write-Ok "TLS/HTTPS respondeu com status HTTP não 2xx."
            }
            else {
                throw
            }
        }
    }
    catch {
        throw ("Falha na validação TLS/HTTPS: {0}" -f $_.Exception.Message)
    }
}

function Test-NocConnectivity {
    Write-Step "Pré-validação de conectividade"

    # Logo após o boot de uma VM ou troca de rede, a primeira consulta DNS
    # pode falhar de forma passageira (resolvedor ainda "aquecendo", como
    # aconteceu ao testar: falhou uma vez e um "ping" manual em seguida
    # resolveu na hora). Em vez de abortar a instalação nesse cenário
    # transitório, tentamos de novo algumas vezes antes de desistir.
    $maxAttempts = 5
    $delaySeconds = 3

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Test-NocConnectivityOnce
            return
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                throw ("Falha na pré-validação de conectividade com {0} após {1} tentativa(s): {2}" -f $script:NocHost, $maxAttempts, $_.Exception.Message)
            }

            Write-Warn ("Falha temporária na conectividade com {0} (tentativa {1}/{2}): {3}" -f $script:NocHost, $attempt, $maxAttempts, $_.Exception.Message)
            Write-Info ("Tentando de novo em {0}s..." -f $delaySeconds)
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

# ==============================================================================
# ALLOY
# ==============================================================================

function Get-AlloyService {
    <#
        Retorna o objeto de serviço do Alloy, ou $null.

        O instalador oficial registra o serviço como "Alloy", mas versões
        antigas e instalações feitas à mão usam outros nomes. A busca por
        DisplayName cobre esses casos.
    #>
    foreach ($name in @("Alloy", "GrafanaAlloy", "grafana-alloy")) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue

        if ($null -ne $service) {
            return $service
        }
    }

    return (Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "(?i)^(grafana )?alloy" } |
            Select-Object -First 1)
}

function Find-AlloyCliExecutable {
    <#
        Localiza o executável CLI do Alloy dentro de um diretório.

        O ImagePath do serviço aponta para alloy-service-windows-amd64.exe, que
        é o wrapper do Service Control Manager e não aceita fmt, validate nem
        --version. O que o instalador precisa é o binário CLI, que fica na mesma
        pasta com outro nome.
    #>
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $null
    }

    foreach ($name in @("alloy-windows-amd64.exe", "alloy.exe", "alloy-windows-386.exe")) {
        $candidate = Join-Path $Directory $name

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    # Fallback para nomes futuros: qualquer alloy*.exe que não seja o wrapper.
    $found = @(Get-ChildItem -LiteralPath $Directory -Filter "alloy*.exe" -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch "(?i)service" } |
               Select-Object -First 1)

    if ($found.Count -gt 0) {
        return $found[0].FullName
    }

    return $null
}

function Get-AlloyExecutableFromService {
    <#
        Descobre o diretório de instalação a partir do ImagePath do serviço e
        devolve o executável CLI que estiver lá.

        O ImagePath é a fonte confiável do diretório: o Alloy pode ter sido
        instalado em outro disco, e um PowerShell de 32 bits enxerga
        $env:ProgramFiles como "Program Files (x86)", que não é onde o
        instalador de 64 bits coloca o binário. O executável apontado pelo
        ImagePath, porém, é o wrapper de serviço, então quem escolhe o binário
        correto dentro da pasta é Find-AlloyCliExecutable.
    #>
    param($Service)

    if ($null -eq $Service) {
        return $null
    }

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $Service.Name

    if (-not (Test-Path -LiteralPath $key)) {
        return $null
    }

    $imagePath = [string](Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).ImagePath

    if ([string]::IsNullOrWhiteSpace($imagePath)) {
        return $null
    }

    # ImagePath vem com os argumentos do serviço junto e, quando o caminho tem
    # espaço, entre aspas. Ex.: "C:\Program Files\GrafanaLabs\Alloy\alloy.exe" run ...
    if ($imagePath -match '^\s*"([^"]+)"') {
        $exe = $Matches[1]
    }
    else {
        $exe = ($imagePath -split "\s+")[0]
    }

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        return $null
    }

    return (Find-AlloyCliExecutable -Directory (Split-Path -Parent $exe))
}

function Resolve-AlloyInstallation {
    <#
        Descobre onde o Alloy está instalado e aponta as variáveis de caminho
        do instalador para lá.

        Ordem de busca:
          1. ImagePath do serviço registrado
          2. Program Files e Program Files (x86)
          3. mantém o padrão, para o caso de instalação nova
    #>
    $service = Get-AlloyService

    if ($null -ne $service) {
        $script:AlloyServiceName = $service.Name
    }

    $exe = Get-AlloyExecutableFromService -Service $service

    if ($null -eq $exe) {
        $directories = @(
            (Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"),
            (Join-Path ${env:ProgramFiles(x86)} "GrafanaLabs\Alloy"),
            "C:\Program Files\GrafanaLabs\Alloy"
        )

        foreach ($directory in $directories) {
            $exe = Find-AlloyCliExecutable -Directory $directory

            if ($null -ne $exe) {
                break
            }
        }
    }

    if ($null -eq $exe) {
        return
    }

    $script:AlloyExe = $exe
    $script:AlloyDir = Split-Path -Parent $exe
    $script:ConfigFile = Join-Path $script:AlloyDir "config.alloy"
    $script:BlackboxFile = Join-Path $script:AlloyDir "blackbox.yml"
    $script:SnmpFile = Join-Path $script:AlloyDir "snmp.yml"
    $script:SnmpAuthFile = Join-Path $script:AlloyDir "snmp-auth.yml"
}

function Test-AlloyInstalled {
    <#
        Instalação existente = binário no disco E serviço registrado.

        Os dois precisam existir. Só o binário significa instalação
        interrompida; só o serviço significa binário removido. Nos dois casos o
        caminho correto é reinstalar, não oferecer o menu de manutenção.
    #>
    Resolve-AlloyInstallation

    $service = Get-AlloyService
    $exeExists = (-not [string]::IsNullOrWhiteSpace($AlloyExe)) -and (Test-Path -LiteralPath $AlloyExe -PathType Leaf)

    if ($exeExists -and ($null -ne $service)) {
        return $true
    }

    # Estado parcial é anômalo e precisa aparecer para o técnico, senão o
    # instalador segue como se fosse máquina limpa e o motivo nunca é
    # investigado.
    if ($exeExists -and ($null -eq $service)) {
        Write-Warn ("Binário do Alloy encontrado em {0}, mas nenhum serviço Windows correspondente. Será reinstalado." -f $AlloyExe)
    }
    elseif ((-not $exeExists) -and ($null -ne $service)) {
        Write-Warn ("Serviço '{0}' existe, mas o executável CLI do Alloy não foi localizado em {1}. Será reinstalado." -f $service.Name, $AlloyDir)
    }

    return $false
}

function Install-OrUpdateAlloy {
    Write-Step "Instalando ou atualizando Grafana Alloy"

    if (Test-AlloyInstalled) {
        try {
            $versionOutput = & $AlloyExe --version 2>$null | Select-Object -First 1
            Write-Info ("Alloy já instalado: {0}" -f $versionOutput)
        }
        catch {
            Write-Info "Alloy já está instalado."
        }
    }

    $tempDir = Join-Path $env:TEMP ("nextec-alloy-{0}" -f [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $installer = Join-Path $tempDir "alloy-installer-windows-amd64.exe"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Write-Info "Baixando instalador oficial do Grafana Alloy."

        # $ProgressPreference é forçado para "SilentlyContinue" no topo do
        # script (evita que outros comandos poluam a tela). Isso também
        # suprime a barra de progresso nativa do Invoke-WebRequest, fazendo
        # o download parecer travado sem nenhum feedback visual. Habilitamos
        # a barra só durante este download e restauramos o valor original
        # logo em seguida, mesmo se der erro.
        # São ~130 MB pelo link do cliente. -TimeoutSec é obrigatório porque o
        # default do PowerShell 5.1 é espera infinita: um proxy que aceita a
        # conexão e não responde trava o instalador sem mensagem. As tentativas
        # cobrem queda momentânea de link, que de outra forma descartaria todo
        # o fluxo interativo já preenchido.
        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = "Continue"
        try {
            $maxTries = 3

            for ($try = 1; $try -le $maxTries; $try++) {
                try {
                    Invoke-WebRequest -Uri $LatestInstallerUrl -OutFile $installer -UseBasicParsing -TimeoutSec 600
                    break
                }
                catch {
                    if ($try -eq $maxTries) {
                        throw
                    }

                    Write-Warn ("Falha no download (tentativa {0} de {1}): {2}" -f $try, $maxTries, $_.Exception.Message)
                    Start-Sleep -Seconds (5 * $try)
                }
            }
        }
        finally {
            $ProgressPreference = $previousProgressPreference
        }

        if (-not (Test-Path $installer)) {
            throw "Instalador do Alloy não foi baixado."
        }

        $installerSize = (Get-Item $installer).Length

        if ($installerSize -lt 1MB) {
            throw ("Arquivo de instalação parece inválido: {0} bytes." -f $installerSize)
        }

        Write-Ok ("Download concluído: {0:N1} MB." -f ($installerSize / 1MB))

        $arguments = @(
            "/S",
            "/DISABLEREPORTING=yes"
        )

        Write-Info "Executando instalador silencioso do Alloy (/S). Isso pode levar até um minuto sem nenhuma saída na tela; é esperado."

        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            throw ("Instalador do Alloy retornou código {0}." -f $process.ExitCode)
        }

        if (-not (Test-Path $AlloyExe)) {
            throw ("alloy.exe não encontrado em {0}." -f $AlloyExe)
        }

        Resolve-AlloyInstallation
        $service = Get-AlloyService

        if ($null -eq $service) {
            throw "Serviço Windows Alloy não foi criado pelo instalador."
        }

        Write-Ok "Grafana Alloy instalado/atualizado."
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Backup-ExistingConfiguration {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

    $carimbo = Get-Date -Format "yyyyMMdd-HHmmss"

    if (Test-Path $ConfigFile) {
        $backupPath = Join-Path $BackupDir ("config.alloy.{0}.bak" -f $carimbo)

        Copy-Item -Path $ConfigFile -Destination $backupPath -Force

        $script:ConfigBackup = $backupPath
        Write-Ok ("Backup da configuração: {0}" -f $backupPath)
    }

    # Os arquivos auxiliares são reescritos antes da validação do config.alloy.
    # Sem eles no backup, um rollback devolve o config antigo apontando para
    # módulos e credenciais que já foram substituídos no disco, e o alvo
    # simplesmente para de coletar sem erro nenhum.
    $script:AuxiliaryBackups = @()

    foreach ($alvo in @($SnmpFile, $SnmpAuthFile, $BlackboxFile)) {
        if (-not (Test-Path -LiteralPath $alvo -PathType Leaf)) {
            continue
        }

        $nome = Split-Path -Leaf $alvo
        $destino = Join-Path $BackupDir ("{0}.{1}.bak" -f $nome, $carimbo)

        Copy-Item -LiteralPath $alvo -Destination $destino -Force

        $script:AuxiliaryBackups += [pscustomobject]@{
            Original = $alvo
            Backup = $destino
        }
    }

    if ($script:AuxiliaryBackups.Count -gt 0) {
        Write-Ok ("Backup dos arquivos auxiliares: {0} arquivo(s)." -f $script:AuxiliaryBackups.Count)
    }
}

function Protect-AlloyRegistryKey {
    <#
        Restringe a chave de registro do serviço Alloy a SYSTEM e
        Administradores.

        A chave guarda NEXTEC_RW_PASSWORD e NEXTEC_LOKI_PASSWORD em texto claro,
        porque o Alloy as lê como variáveis de ambiente do serviço.
        HKLM:\SOFTWARE herda leitura para "Users", o que tornaria a senha de
        remote_write do cliente legível por qualquer usuário autenticado no
        servidor. Equivale ao chmod 0600 do instalador Linux.
    #>
    try {
        $acl = Get-Acl -Path $RegistryPath

        # Corta a herança e descarta as ACEs herdadas, de onde vem o acesso de
        # leitura para "Users".
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($rule in @($acl.Access)) {
            [void]$acl.RemoveAccessRule($rule)
        }

        foreach ($identity in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $identity,
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }

        Set-Acl -Path $RegistryPath -AclObject $acl
        Write-Ok "Permissões da chave de registro restritas a SYSTEM e Administradores."
    }
    catch {
        # Não aborta: em host com política de segurança própria a alteração de
        # ACL pode ser negada. O aviso precisa aparecer para o técnico.
        Write-Warn ("Não foi possível restringir a ACL de {0}: {1}. As credenciais podem estar legíveis por usuários locais." -f $RegistryPath, $_.Exception.Message)
    }
}

function Set-AlloyServiceEnvironment {
    # New-Item -Force em chave existente recria a chave e descarta os valores
    # atuais, por isso só criamos quando ela não existe.
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    # Estado anterior guardado para Restore-Configuration.
    if ($null -eq $script:RegistryBackup) {
        $script:RegistryBackup = Get-PreservedServiceEnvironment
    }

    $environment = New-Object System.Collections.Generic.List[string]
    $environment.Add(("NEXTEC_RW_USERNAME={0}" -f $script:RwUsername))
    $environment.Add(("NEXTEC_RW_PASSWORD={0}" -f $script:RwPassword))

    if ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved) {
        $environment.Add(("NEXTEC_LOKI_USERNAME={0}" -f $script:LokiUsername))
        $environment.Add(("NEXTEC_LOKI_PASSWORD={0}" -f $script:LokiPassword))
    }

    New-ItemProperty `
        -Path $RegistryPath `
        -Name "Environment" `
        -PropertyType MultiString `
        -Value ([string[]]$environment.ToArray()) `
        -Force | Out-Null

    $arguments = @(
        "run",
        $ConfigFile,
        ("--storage.path={0}" -f $StorageDir),
        "--server.http.listen-addr=127.0.0.1:12345",
        "--disable-reporting"
    )

    New-ItemProperty `
        -Path $RegistryPath `
        -Name "Arguments" `
        -PropertyType MultiString `
        -Value $arguments `
        -Force | Out-Null

    Protect-AlloyRegistryKey

    Write-Ok "Credenciais e argumentos gravados no registro do serviço Alloy."
}

# ==============================================================================
# ARQUIVOS AUXILIARES DE COLETA
# ==============================================================================

function New-BlackboxConfiguration {
    if (-not $script:EnableBlackboxResolved) {
        return
    }

    # Os nomes dos módulos precisam ser idênticos aos do blackbox.yml do Alloy
    # central: um alvo migrado entre os dois falha em silêncio se o módulo não
    # existir do outro lado, porque a validação passa e a sonda simplesmente
    # nunca produz resultado.
    #
    # http_2xx_ssl é o único que produz probe_ssl_earliest_cert_expiry, métrica
    # usada pelo alerta de certificado a vencer.
    $content = @"
modules:
  icmp_ipv4:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  http_2xx:
    prober: http
    timeout: 8s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true

  # HTTPS com validação de certificado. Produz probe_ssl_earliest_cert_expiry.
  http_2xx_ssl:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      fail_if_not_ssl: true
      tls_config:
        insecure_skip_verify: false

  # HTTP com verificação de conteúdo. Além do status 2xx, falha se o corpo
  # bater com uma assinatura de erro conhecida: pega o caso de página que
  # carrega (responde 200) mas está com erro visível, ex.: tela de erro
  # crítico do WordPress ou falha de conexão com o banco.
  http_2xx_content:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      fail_if_body_matches_regexp:
        - "(?i)há um erro crítico"
        - "(?i)there has been a critical error"
        - "(?i)error establishing a database connection"
        - "(?i)erro de conex(a|ã)o com o banco de dados"
        - "(?i)\\b(500 internal server error|502 bad gateway|503 service unavailable|504 gateway timeout)\\b"
      tls_config:
        insecure_skip_verify: false

  tcp_connect:
    prober: tcp
    timeout: 5s

  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      transport_protocol: udp
      preferred_ip_protocol: ip4
      query_name: nex.tec.br
      query_type: A
"@

    [IO.File]::WriteAllText(
        $BlackboxFile,
        $content,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Install-SnmpConfiguration {
    if (-not $script:EnableSnmpResolved) {
        return
    }

    # Reconfiguração pelo menu: o parser recupera os alvos do config.alloy mas
    # não o caminho de origem do snmp.yml, então aqui a origem vem vazia. O
    # arquivo já instalado é a origem correta nesse caso, e barrar a gravação
    # impediria qualquer alteração num host que já tem SNMP.
    if ([string]::IsNullOrWhiteSpace([string]$script:SnmpSourceFile)) {
        if (Test-Path -LiteralPath $SnmpFile -PathType Leaf) {
            Write-Info "Reaproveitando o snmp.yml já instalado neste host."
            Install-SnmpAuthFile
            return
        }

        throw "Arquivo snmp.yml não informado e nenhum arquivo instalado neste host."
    }

    if (-not (Test-Path -LiteralPath $script:SnmpSourceFile -PathType Leaf)) {
        throw ("Arquivo snmp.yml não encontrado: {0}" -f $script:SnmpSourceFile)
    }

    $sourceFull = (Resolve-Path -LiteralPath $script:SnmpSourceFile).Path

    if ($sourceFull -ieq $SnmpFile) {
        Write-Info "O snmp.yml informado já é o arquivo instalado; nada a copiar."
    }
    else {
        Merge-SnmpModuleFile -NewFile $sourceFull -Destination $SnmpFile
    }

    Install-SnmpAuthFile
}

function Install-SnmpAuthFile {
    <#
        Grava a seção "auths" em arquivo próprio, com ACL restrita a SYSTEM e
        Administradores. Fica separado do snmp.yml porque o módulo do
        fabricante é público e versionado no repositório, e a credencial do
        cliente não pode acompanhar esse arquivo.
    #>
    if ($script:SnmpAuthBlocks.Count -eq 0) {
        return
    }

    # Duas credenciais com o mesmo nome viram chave YAML repetida, e aí o
    # Alloy derruba o exporter SNMP inteiro em tempo de execução com
    # "key already set in map". O fmt e o validate não pegam isso.
    # A última definição vence, que é a informada agora pelo operador.
    $unique = [ordered]@{}

    foreach ($block in $script:SnmpAuthBlocks) {
        $name = Get-SnmpAuthBlockName -Block $block

        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $unique[$name] = $block
    }

    $content = @("auths:") + @($unique.Values)
    $text = ($content -join [Environment]::NewLine) + [Environment]::NewLine

    # UTF-8 sem BOM: o parser YAML do Alloy trata o BOM como caractere do
    # conteúdo e rejeita o arquivo.
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($SnmpAuthFile, $text, $encoding)

    Protect-NextecSecretFile -Path $SnmpAuthFile
    Write-Ok ("Credenciais SNMP gravadas em {0}" -f $SnmpAuthFile)
}

function Protect-NextecSecretFile {
    <#
        Remove herança e deixa apenas SYSTEM e Administradores com acesso.
        Mesmo tratamento aplicado às credenciais do NOC no registro.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $acl = Get-Acl -Path $Path
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($rule in @($acl.Access)) {
            [void]$acl.RemoveAccessRule($rule)
        }

        foreach ($identity in @("NT AUTHORITY\SYSTEM","BUILTIN\Administrators")) {
            $account = New-Object Security.Principal.NTAccount($identity)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $account,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }

        Set-Acl -Path $Path -AclObject $acl
    }
    catch {
        Write-Warn ("Não foi possível restringir a ACL de {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

# ==============================================================================
# INTERNET (SPEEDTEST OOKLA)
# ==============================================================================
#
# Desenho: em vez de subir um exporter Prometheus separado com porta própria,
# o teste de velocidade roda por tarefa agendada e grava um arquivo .prom no
# diretório que o coletor "textfile" do windows_exporter (já embutido no
# Alloy) varre sozinho. Vantagens: nenhuma porta nova exposta, e o alvo
# continua sendo o mesmo prometheus.exporter.windows "system", então as
# labels de cliente/host/ambiente/criticidade já aplicadas em
# discovery.relabel "system_labels" valem também para essas métricas, sem
# precisar duplicar labelling em outro scrape job.

function Install-SpeedtestCli {
    <#
        Baixa e extrai o Speedtest CLI da Ookla. Se o .exe já existe, não
        baixa de novo (reinstalação/atualização não deve repetir download a
        cada execução do instalador).
    #>
    if (Test-Path -LiteralPath $SpeedtestExe -PathType Leaf) {
        Write-Info "Speedtest CLI já instalado, não baixando de novo."
        return
    }

    Write-Step "Instalando Speedtest CLI (Ookla)"

    New-Item -ItemType Directory -Path $SpeedtestDir -Force | Out-Null

    $zipPath = Join-Path $SpeedtestDir "speedtest-cli.zip"

    try {
        Invoke-WebRequest -Uri $SpeedtestCliUrl -OutFile $zipPath -UseBasicParsing
    }
    catch {
        throw ("Falha ao baixar o Speedtest CLI em {0}: {1}. Confira se a versão pinada no instalador ({2}) ainda existe em https://www.speedtest.net/apps/cli." -f $SpeedtestCliUrl, $_.Exception.Message, $SpeedtestCliVersion)
    }

    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $SpeedtestDir -Force
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $SpeedtestExe -PathType Leaf)) {
        throw ("O ZIP do Speedtest CLI foi baixado, mas {0} não apareceu depois de extrair. O layout do pacote da Ookla pode ter mudado." -f $SpeedtestExe)
    }

    # Aceita a licença e o GDPR sem interação uma vez aqui, para que a
    # primeira execução real (via tarefa agendada, sem console) não fique
    # esperando confirmação que nunca chega.
    & $SpeedtestExe --accept-license --accept-gdpr --format=json 2>&1 | Out-Null
}

function New-SpeedtestRunnerScript {
    <#
        Grava o script que a tarefa agendada executa a cada intervalo. Fica
        em arquivo próprio, não inline na definição da tarefa, para o log de
        cada execução poder ser lido e para o comando não ficar refém do
        limite de tamanho de linha do Task Scheduler.
    #>
    New-Item -ItemType Directory -Path $SpeedtestMetricsDir -Force | Out-Null

    # Token de texto simples em vez de -f: o corpo do script tem vários "{ }"
    # de controle de fluxo do PowerShell (if/else, blocos de script), e -f
    # exigiria escapar cada um como "{{ }}" só para não colidir com os dois
    # placeholders reais. Um Replace() de token único não tem esse risco.
    $runnerContent = @'
$ErrorActionPreference = "Continue"

$speedtestExe = "__NEXTEC_SPEEDTEST_EXE__"
$metricsFile  = "__NEXTEC_SPEEDTEST_METRICS_FILE__"
$tempFile     = "__NEXTEC_SPEEDTEST_METRICS_FILE__.tmp"

$timestamp = [int][double]::Parse((Get-Date -UFormat %s))

try {
    $raw = & $speedtestExe --accept-license --accept-gdpr --format=json --progress=no 2>$null
    $result = $raw | ConvertFrom-Json -ErrorAction Stop

    if ($null -eq $result -or $result.type -ne "result") {
        throw "Saída do Speedtest CLI sem resultado válido."
    }

    $downloadBps = [int64]$result.download.bandwidth * 8
    $uploadBps   = [int64]$result.upload.bandwidth * 8
    $latencyMs   = [double]$result.ping.latency
    $jitterMs    = [double]$result.ping.jitter
    $packetLoss  = if ($null -ne $result.packetLoss) { [double]$result.packetLoss } else { 0 }
    $serverId    = [string]$result.server.id
    $serverName  = ($result.server.name -replace '["\\]', '')

    $lines = @(
        "# HELP nextec_speedtest_up 1 se a última execução do speedtest terminou com sucesso, 0 caso contrário.",
        "# TYPE nextec_speedtest_up gauge",
        "nextec_speedtest_up 1",
        "# HELP nextec_speedtest_download_bits_per_second Velocidade de download medida, em bits por segundo.",
        "# TYPE nextec_speedtest_download_bits_per_second gauge",
        "nextec_speedtest_download_bits_per_second $downloadBps",
        "# HELP nextec_speedtest_upload_bits_per_second Velocidade de upload medida, em bits por segundo.",
        "# TYPE nextec_speedtest_upload_bits_per_second gauge",
        "nextec_speedtest_upload_bits_per_second $uploadBps",
        "# HELP nextec_speedtest_ping_latency_milliseconds Latência do ping até o servidor de teste, em milissegundos.",
        "# TYPE nextec_speedtest_ping_latency_milliseconds gauge",
        "nextec_speedtest_ping_latency_milliseconds $latencyMs",
        "# HELP nextec_speedtest_ping_jitter_milliseconds Variação da latência (jitter), em milissegundos.",
        "# TYPE nextec_speedtest_ping_jitter_milliseconds gauge",
        "nextec_speedtest_ping_jitter_milliseconds $jitterMs",
        "# HELP nextec_speedtest_packet_loss_percent Perda de pacotes durante o teste, em percentual.",
        "# TYPE nextec_speedtest_packet_loss_percent gauge",
        "nextec_speedtest_packet_loss_percent $packetLoss",
        "# HELP nextec_speedtest_last_run_timestamp_seconds Timestamp Unix da última execução do speedtest.",
        "# TYPE nextec_speedtest_last_run_timestamp_seconds gauge",
        "nextec_speedtest_last_run_timestamp_seconds $timestamp",
        "# HELP nextec_speedtest_server_info Servidor Ookla usado no teste, sempre valor 1.",
        "# TYPE nextec_speedtest_server_info gauge",
        "nextec_speedtest_server_info{server_id=`"$serverId`",server_name=`"$serverName`"} 1"
    )
}
catch {
    # Falha registrada como métrica, não como arquivo ausente: nextec_speedtest_up
    # em 0 aparece no Grafana; um arquivo .prom que some (ex.: erro apagando o
    # antigo) só gera "sem dado", que é fácil de confundir com "sem problema".
    $lines = @(
        "# HELP nextec_speedtest_up 1 se a última execução do speedtest terminou com sucesso, 0 caso contrário.",
        "# TYPE nextec_speedtest_up gauge",
        "nextec_speedtest_up 0",
        "# HELP nextec_speedtest_last_run_timestamp_seconds Timestamp Unix da última execução do speedtest.",
        "# TYPE nextec_speedtest_last_run_timestamp_seconds gauge",
        "nextec_speedtest_last_run_timestamp_seconds $timestamp"
    )
}

# Escrita atômica: o coletor textfile do windows_exporter varre o diretório
# em intervalos próprios e pode ler o arquivo no meio de uma escrita direta,
# resultando em métrica truncada e scrape com erro de parsing. Grava em
# arquivo temporário e troca com Move-Item, que no NTFS é atômico dentro do
# mesmo volume.
# UTF-8 sem BOM: "Set-Content -Encoding utf8" no Windows PowerShell 5.1 grava
# COM BOM, e o parser do formato texto do Prometheus lê o BOM como parte do
# primeiro nome de métrica, descartando o arquivo inteiro com
# "invalid metric name".
[IO.File]::WriteAllText($tempFile, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tempFile -Destination $metricsFile -Force
'@

    # Valor puro, sem ConvertTo-AlloyEscapedString: aquela função escapa para
    # a sintaxe do .alloy (barra invertida dobrada), não para string do
    # PowerShell. Os caminhos vêm de $env:ProgramData, sem aspas, então não
    # há nada para escapar aqui.
    $runnerContent = $runnerContent.Replace("__NEXTEC_SPEEDTEST_EXE__", $SpeedtestExe)
    $runnerContent = $runnerContent.Replace("__NEXTEC_SPEEDTEST_METRICS_FILE__", $SpeedtestMetricsFile)

    [IO.File]::WriteAllText(
        $SpeedtestRunnerScript,
        $runnerContent,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Register-SpeedtestScheduledTask {
    <#
        Tarefa como SYSTEM: não depende de nenhuma conta de usuário logada
        nem de senha armazenada, sobrevive a logoff/reboot, e roda mesmo sem
        ninguém interativo na máquina, igual ao próprio serviço do Alloy.
    #>
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $SpeedtestRunnerScript)

    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $script:InternetIntervalMinutesResolved) `
        -RepetitionDuration ([TimeSpan]::MaxValue)

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask -TaskName $SpeedtestTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Install-InternetMonitoring {
    if (-not $script:EnableInternetResolved) {
        # Reconfiguração pode estar desligando o que já estava ligado: some
        # a tarefa agendada, mas deixa o binário e o histórico de métricas
        # (o próximo scrape simplesmente para de receber dado novo).
        if (Get-ScheduledTask -TaskName $SpeedtestTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $SpeedtestTaskName -Confirm:$false
        }
        return
    }

    Write-Step "Internet (Speedtest)"

    Install-SpeedtestCli
    New-SpeedtestRunnerScript
    Register-SpeedtestScheduledTask

    # Roda uma vez agora, na hora da instalação: sem isso o técnico só veria
    # o primeiro dado depois de até $InternetIntervalMinutesResolved minutos,
    # e o checklist de validação (ver documento 03, item 19) ficaria bloqueado
    # esperando sem necessidade.
    Write-Info ("Executando o primeiro teste de velocidade agora (pode levar até 30s)...")
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SpeedtestRunnerScript
        Write-Info "Primeiro teste de velocidade concluído."
    }
    catch {
        Write-Warn ("Primeiro teste de velocidade falhou, mas a tarefa agendada ({0} em {1} min) segue tentando: {2}" -f $SpeedtestTaskName, $script:InternetIntervalMinutesResolved, $_.Exception.Message)
    }
}

# ==============================================================================
# CONFIG.ALLOY
# ==============================================================================

function Get-MonitoredServiceRegex {
    <#
        Devolve o regex de serviços Windows que o coletor "service" enumera.

        Cada serviço incluído custa de 7 a 13 séries por host. Prefira
        acrescentar na tabela condicional, que só vale quando a role
        correspondente foi detectada, em vez de na lista base.
    #>
    $names = New-Object System.Collections.Generic.List[string]

    # Base: o agente e serviços presentes em qualquer servidor gerenciado.
    foreach ($name in @("Alloy", "LanmanServer", "Netlogon", "Spooler", "W32Time", "WinDefend")) {
        $names.Add([Regex]::Escape($name))
    }

    # Condicionais por role detectada e selecionada.
    $conditional = @{
        "active_directory"  = @("NTDS", "Netlogon", "DFSR")
        "adcs"              = @("CertSvc")
        "adfs"              = @("adfssrv")
        "dns"               = @("DNS")
        "dhcp"              = @("DHCPServer")
        "iis"               = @("W3SVC", "WAS")
        "hyper_v"           = @("vmms")
        "file_server"       = @("LanmanServer")
        "dfsr"              = @("DFSR")
        "terminal_services" = @("TermService", "UmRdpService")
        "failover_cluster"  = @("ClusSvc")
        "sql_server"        = @("MSSQLSERVER", "SQLSERVERAGENT", "SQLBrowser")
        "firebird"          = @("FirebirdServerDefaultInstance", "FirebirdGuardianDefaultInstance")
    }

    foreach ($key in $conditional.Keys) {
        if ($script:SelectedHostFeatureKeys -contains $key) {
            foreach ($name in $conditional[$key]) {
                $escaped = [Regex]::Escape($name)
                if (-not $names.Contains($escaped)) {
                    $names.Add($escaped)
                }
            }
        }
    }

    # Serviços de backup entram por padrão de nome.
    # Instância nomeada de SQL Server chama-se "MSSQL$INSTANCIA". O cifrão vai
    # como classe de caractere [$] porque uma barra invertida chegaria ao
    # arquivo .alloy como "\$", que o parser do Alloy recusa por escape
    # inválido.
    if ($script:SelectedHostFeatureKeys -contains "sql_server") {
        $names.Add('MSSQL[$].*')
    }

    $names.Add("Veeam.*")

    return ("(?i)^({0})$" -f (($names | Sort-Object -Unique) -join "|"))
}

function Get-WindowsCollectors {
    <#
        Monta a lista de coletores do windows_exporter.

        A lista base é o perfil mínimo do documento 03.

        "service" depende do bloco service { include } montado em
        New-AlloyConfiguration. Sem filtro ele gera de 7 a 13 séries por
        serviço Windows instalado, ou seja, mais de 1.800 séries em um servidor
        com 200 serviços, contra cerca de 130 com filtro.

        Coletores a avaliar antes de incluir, por custo:
          process           uma série por processo
          textfile          depende de arquivo externo, falha em silêncio
          netframework*     volumoso e raramente consultado
          terminal_services séries por sessão de usuário, com rotatividade
                            diária
    #>
    $collectors = New-Object System.Collections.Generic.List[string]

    foreach ($collector in @("cpu","logical_disk","memory","net","os","service","system")) {
        if (-not $collectors.Contains($collector)) {
            $collectors.Add($collector)
        }
    }

    foreach ($feature in $script:DetectedHostFeatures) {
        if ($script:SelectedHostFeatureKeys -contains $feature.Key) {
            foreach ($collector in $feature.Collectors) {
                if (-not $collectors.Contains($collector)) {
                    $collectors.Add($collector)
                }
            }
        }
    }

    return @($collectors | Sort-Object -Unique)
}

function Add-AlloyRelabelRule {
    param(
        [Parameter(Mandatory=$true)][Text.StringBuilder]$Builder,
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$Replacement
    )

    [void]$Builder.AppendLine("  rule {")
    [void]$Builder.AppendLine(('    target_label = "{0}"' -f $Target))
    [void]$Builder.AppendLine(('    replacement  = "{0}"' -f (ConvertTo-AlloyEscapedString $Replacement)))
    [void]$Builder.AppendLine("  }")
}

function New-AlloyConfiguration {
    param([Parameter(Mandatory=$true)][object]$Inventory)

    Write-Step "Gerando configuração do Alloy"

    New-Item -ItemType Directory -Path $AlloyDir -Force | Out-Null
    New-Item -ItemType Directory -Path $StorageDir -Force | Out-Null

    $builder = New-Object Text.StringBuilder

    [void]$builder.AppendLine("// =============================================================================")
    [void]$builder.AppendLine("// Nextec NOC Monitoring, Windows")
    [void]$builder.AppendLine("// Gerado por install-nextec-monitoring-windows-v2.ps1")
    [void]$builder.AppendLine("// Credenciais não ficam neste arquivo.")
    [void]$builder.AppendLine("//")
    # Identificação em cabeçalho estruturado. O menu de reconfiguração lia
    # esses valores do bloco discovery.relabel "system_labels", que só existe
    # quando o host é monitorado; num coletor puro (só Blackbox, SNMP ou
    # exporters) o bloco não é gerado e o host ficava impossível de
    # reconfigurar pelo menu. O cabeçalho existe em todos os modos.
    [void]$builder.AppendLine(("// nextec:versao      = {0}" -f $InstallerVersion))
    [void]$builder.AppendLine(("// nextec:cliente     = {0}" -f $script:Cliente))
    [void]$builder.AppendLine(("// nextec:host        = {0}" -f $script:HostLabel))
    [void]$builder.AppendLine(("// nextec:ambiente    = {0}" -f $script:Ambiente))
    [void]$builder.AppendLine(("// nextec:local       = {0}" -f $script:Local))
    [void]$builder.AppendLine(("// nextec:criticidade = {0}" -f $script:Criticidade))
    [void]$builder.AppendLine(("// nextec:tipo        = {0}" -f $script:TipoLabel))
    [void]$builder.AppendLine("// =============================================================================")
    [void]$builder.AppendLine("")

    [void]$builder.AppendLine('prometheus.remote_write "nextec" {')
    [void]$builder.AppendLine("  endpoint {")
    [void]$builder.AppendLine(('    url = "{0}"' -f (ConvertTo-AlloyEscapedString $script:RemoteWriteUrl)))
    [void]$builder.AppendLine("    basic_auth {")
    [void]$builder.AppendLine('      username = sys.env("NEXTEC_RW_USERNAME")')
    [void]$builder.AppendLine('      password = sys.env("NEXTEC_RW_PASSWORD")')
    [void]$builder.AppendLine("    }")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("    // max_shards limita a paralelizacao do envio. O padrao do Alloy e 50,")
    [void]$builder.AppendLine("    // o que satura o upload do cliente ao drenar o WAL depois de uma queda.")
    [void]$builder.AppendLine("    queue_config {")
    [void]$builder.AppendLine("      capacity             = 5000")
    [void]$builder.AppendLine("      min_shards           = 1")
    [void]$builder.AppendLine("      max_shards           = 10")
    [void]$builder.AppendLine("      max_samples_per_send = 1000")
    [void]$builder.AppendLine('      batch_send_deadline  = "10s"')
    [void]$builder.AppendLine('      min_backoff          = "100ms"')
    [void]$builder.AppendLine('      max_backoff          = "10s"')
    [void]$builder.AppendLine("      retry_on_http_429    = true")
    [void]$builder.AppendLine("    }")
    [void]$builder.AppendLine("  }")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("  // Buffer local: cobre ate 12h de indisponibilidade sem perder metrica.")
    [void]$builder.AppendLine("  wal {")
    [void]$builder.AppendLine('    truncate_frequency = "2h"')
    [void]$builder.AppendLine('    min_keepalive_time = "10m"')
    [void]$builder.AppendLine('    max_keepalive_time = "12h"')
    [void]$builder.AppendLine("  }")
    [void]$builder.AppendLine("}")
    [void]$builder.AppendLine("")

    # Filtro entre a coleta e o envio. Todo prometheus.scrape deve apontar
    # para prometheus.relabel.filtro_nextec.receiver, nunca direto para o
    # remote_write, senão tudo que o exporter produz atravessa o link do
    # cliente e é indexado no NOC.
    [void]$builder.AppendLine('prometheus.relabel "filtro_nextec" {')
    [void]$builder.AppendLine("  forward_to = [prometheus.remote_write.nextec.receiver]")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("  // windows_service_state gera 7 series por servico, uma por estado.")
    [void]$builder.AppendLine('  // Mantemos apenas "running"; os demais sao deduzidos por ausencia.')
    [void]$builder.AppendLine("  rule {")
    [void]$builder.AppendLine('    source_labels = ["__name__", "state"]')
    [void]$builder.AppendLine('    separator     = ";"')
    [void]$builder.AppendLine('    regex         = "windows_service_state;(?:stopped|paused|continue pending|pause pending|start pending|stop pending)"')
    [void]$builder.AppendLine('    action        = "drop"')
    [void]$builder.AppendLine("  }")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("  // Metricas de custo alto e valor operacional baixo.")
    [void]$builder.AppendLine("  rule {")
    [void]$builder.AppendLine('    source_labels = ["__name__"]')
    [void]$builder.AppendLine('    regex         = "windows_service_(info|start_mode)|windows_cpu_cstate_seconds_total|windows_cpu_core_frequency_mhz"')
    [void]$builder.AppendLine('    action        = "drop"')
    [void]$builder.AppendLine("  }")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("  // process_id muda a cada restart e cria serie nova a cada vez.")
    [void]$builder.AppendLine("  rule {")
    [void]$builder.AppendLine('    regex  = "process_id|creating_process_id"')
    [void]$builder.AppendLine('    action = "labeldrop"')
    [void]$builder.AppendLine("  }")
    [void]$builder.AppendLine("}")
    [void]$builder.AppendLine("")

    # O bloco existe sempre que há algo para o windows_exporter coletar: seja
    # o perfil completo de host monitorado, seja só o coletor "textfile" do
    # Speedtest num host que é apenas captador (sem monitorar o próprio SO).
    # Sem isso, "captador puro" com Internet habilitada nunca teria onde o
    # coletor textfile rodar, e a métrica de speedtest não sairia do host.
    if ($script:MonitorHost -or $script:EnableInternetResolved) {
        $collectors = if ($script:MonitorHost) { New-Object System.Collections.Generic.List[string] (,[string[]](Get-WindowsCollectors)) } else { New-Object System.Collections.Generic.List[string] }

        if ($script:EnableInternetResolved -and -not $collectors.Contains("textfile")) {
            $collectors.Add("textfile")
        }

        $collectorLiteral = ($collectors | Sort-Object -Unique | ForEach-Object { '"{0}"' -f (ConvertTo-AlloyEscapedString $_) }) -join ", "

        [void]$builder.AppendLine("// Métricas básicas do Windows")
        [void]$builder.AppendLine('prometheus.exporter.windows "system" {')
        [void]$builder.AppendLine(("  enabled_collectors = [{0}]" -f $collectorLiteral))
        [void]$builder.AppendLine("")

        if ($script:MonitorHost) {
            # O coletor "service" precisa do include. Sem ele são de 7 a 13 séries
            # por serviço Windows instalado, mais de 1.800 em um servidor típico.
            # A lista é montada em Get-MonitoredServiceRegex.
            [void]$builder.AppendLine("  // Apenas servicos que o NOC realmente acompanha. Ver nota no instalador.")
            [void]$builder.AppendLine("  service {")
            [void]$builder.AppendLine(('    include = "{0}"' -f (ConvertTo-AlloyEscapedString (Get-MonitoredServiceRegex))))
            [void]$builder.AppendLine("  }")
            [void]$builder.AppendLine("")

            # O coletor "net" enumera loopback, Teredo, isatap, WAN Miniport,
            # vEthernet e TAP de VPN. Em host com Hyper-V são cerca de 25
            # adaptadores a 17 métricas cada, e os virtuais aparecem e somem.
            #
            # O bloco do Alloy se chama "net", não "network". Confirmado no
            # código-fonte do Alloy (config_windows.go): o exporter do Windows
            # sempre aplica NetConfig.Convert() por último, sobrescrevendo
            # qualquer NetworkConfig; um bloco "network { }" é aceito sem erro
            # mas nunca tem efeito nenhum sobre o filtro real.
            [void]$builder.AppendLine("  // Ignora adaptadores virtuais, de tunel e de loopback.")
            [void]$builder.AppendLine("  net {")
            [void]$builder.AppendLine('    exclude = "(?i).*(loopback|teredo|isatap|virtual|vethernet|pseudo|tunnel|miniport|bluetooth|tap-|npcap|wan ).*"')
            [void]$builder.AppendLine("  }")
            [void]$builder.AppendLine("")

            # Sem include entram volumes reservados do sistema, unidades ópticas,
            # ISOs montadas e volumes temporários de software de backup, que são
            # montados e desmontados a cada job.
            [void]$builder.AppendLine("  // Apenas volumes com letra de unidade.")
            [void]$builder.AppendLine("  logical_disk {")
            [void]$builder.AppendLine('    include = "^[A-Za-z]:$"')
            [void]$builder.AppendLine("  }")

            if ($script:SelectedHostFeatureKeys -contains "firebird") {
                [void]$builder.AppendLine("")
                [void]$builder.AppendLine("  // Coletor process restrito ao Firebird. Sem include ele gera uma")
                [void]$builder.AppendLine("  // serie por processo do host.")
                [void]$builder.AppendLine('  process {')
                [void]$builder.AppendLine('    include = "^(firebird|firebird_server|fbserver|fb_inet_server|fbguard).*"')
                [void]$builder.AppendLine('  }')
            }

            if ($script:SelectedHostFeatureKeys -contains "sql_server") {
                [void]$builder.AppendLine("")
                [void]$builder.AppendLine("  // Sem a classe 'databases', que gera ~25 metricas por banco.")
                [void]$builder.AppendLine("  mssql {")
                [void]$builder.AppendLine('    enabled_classes = ["accessmethods", "bufman", "genstats", "sqlstats", "memmgr", "transactions", "locks"]')
                [void]$builder.AppendLine("  }")
            }
        }

        if ($script:EnableInternetResolved) {
            # Diretório exclusivo do .prom do Speedtest. O coletor textfile
            # varre TODO arquivo .prom da pasta, então ela não pode ser
            # compartilhada com outra coisa que também escreva ali.
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine("  // Internet (Speedtest): le o .prom gravado pela tarefa agendada.")
            [void]$builder.AppendLine("  textfile {")
            # O atributo do exporter windows chama-se text_file_directory.
            # "directory" é o nome equivalente no exporter unix e o Alloy
            # recusa a configuração inteira com "unrecognized attribute name".
            [void]$builder.AppendLine(('    text_file_directory = "{0}"' -f (ConvertTo-AlloyEscapedString $SpeedtestMetricsDir)))
            [void]$builder.AppendLine("  }")
        }

        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")

        [void]$builder.AppendLine('discovery.relabel "system_labels" {')
        [void]$builder.AppendLine("  targets = prometheus.exporter.windows.system.targets")
        [void]$builder.AppendLine("")

        Add-AlloyRelabelRule -Builder $builder -Target "instance" -Replacement $script:HostLabel
        Add-AlloyRelabelRule -Builder $builder -Target "host" -Replacement $script:HostLabel
        Add-AlloyRelabelRule -Builder $builder -Target "cliente" -Replacement $script:Cliente
        Add-AlloyRelabelRule -Builder $builder -Target "servico" -Replacement "system"
        Add-AlloyRelabelRule -Builder $builder -Target "tipo" -Replacement $script:TipoLabel
        Add-AlloyRelabelRule -Builder $builder -Target "ambiente" -Replacement $script:Ambiente
        Add-AlloyRelabelRule -Builder $builder -Target "os" -Replacement "windows"
        Add-AlloyRelabelRule -Builder $builder -Target "origem" -Replacement "alloy"
        Add-AlloyRelabelRule -Builder $builder -Target "criticidade" -Replacement $script:Criticidade
        Add-AlloyRelabelRule -Builder $builder -Target "local" -Replacement $script:Local

        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")

        # job_name é obrigatório: sem ele o Alloy usa o nome do componente como
        # valor da label "job", e o host chega ao NOC como
        # job="prometheus.scrape.system". Painéis e alertas que filtram
        # job=~"integrations/.*" passam a ignorar o host.
        #
        # scrape_interval de 60s segue o documento 03 e o nextec.alloy central.
        # scrape_timeout de 30s dá folga ao coletor service em servidor
        # carregado: um scrape que estoura descarta todas as métricas do ciclo,
        # inclusive CPU e memória.
        [void]$builder.AppendLine('prometheus.scrape "system" {')
        [void]$builder.AppendLine("  targets         = discovery.relabel.system_labels.output")
        [void]$builder.AppendLine("  forward_to      = [prometheus.relabel.filtro_nextec.receiver]")
        [void]$builder.AppendLine('  job_name        = "integrations/windows"')
        [void]$builder.AppendLine('  scrape_interval = "60s"')
        [void]$builder.AppendLine('  scrape_timeout  = "30s"')
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
    }

    if ($script:MonitorHost -and ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved)) {
        [void]$builder.AppendLine("// Logs Windows")
        [void]$builder.AppendLine('loki.write "nextec" {')
        [void]$builder.AppendLine("  endpoint {")
        [void]$builder.AppendLine(('    url = "{0}"' -f (ConvertTo-AlloyEscapedString $script:LokiUrl)))
        [void]$builder.AppendLine("    basic_auth {")
        [void]$builder.AppendLine('      username = sys.env("NEXTEC_LOKI_USERNAME")')
        [void]$builder.AppendLine('      password = sys.env("NEXTEC_LOKI_PASSWORD")')
        [void]$builder.AppendLine("    }")
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")

        # Um componente por severidade, não por canal. É isso que permite a
        # label "nivel" ser estática e o NOC filtrar por severidade sem fazer
        # parsing do corpo do evento, do mesmo modo que o instalador Linux faz
        # com journal_error e journal_warning.
        #
        # "servico" é sempre "windows_event", conforme o catálogo do documento
        # 02; o canal fica em label própria.
        $logStreams = New-Object System.Collections.Generic.List[object]

        if ($script:EnableLogsResolved) {
            foreach ($logName in @("Application","System")) {
                $logStreams.Add([pscustomobject]@{
                    Component = ("{0}_error" -f $logName.ToLowerInvariant())
                    EventLog  = $logName
                    Canal     = $logName.ToLowerInvariant()
                    Nivel     = "error"
                    XPath     = "*[System[(Level=1 or Level=2)]]"
                    Rate      = 20
                })

                if ($script:EnableLogWarningsResolved) {
                    $logStreams.Add([pscustomobject]@{
                        Component = ("{0}_warning" -f $logName.ToLowerInvariant())
                        EventLog  = $logName
                        Canal     = $logName.ToLowerInvariant()
                        Nivel     = "warning"
                        XPath     = "*[System[(Level=3)]]"
                        Rate      = 20
                    })
                }
            }
        }

        if ($script:EnableSecurityLogsResolved) {
            # Event IDs acionáveis do canal Security:
            #   4625 falha de logon             4740 conta bloqueada
            #   4771 falha de pré-auth Kerberos 4720 conta criada
            #   4726 conta excluída             4728/4732/4756 conta em grupo privilegiado
            #   4648 logon com credencial explícita
            #   1102 log de auditoria limpo
            #
            # 4624, 4634 e 4672 estão fora porque são emitidos a cada
            # autenticação de rede, incluindo conta de máquina e acesso SMB:
            # em um controlador de domínio são milhões de eventos por dia.
            # Se logon bem-sucedido for requisito, filtre LogonType 10 no XPath
            # em vez de incluir 4624 aberto.
            $logStreams.Add([pscustomobject]@{
                Component = "security"
                EventLog  = "Security"
                Canal     = "security"
                Nivel     = "alerta"
                XPath     = "*[System[(EventID=4625 or EventID=4648 or EventID=4720 or EventID=4726 or EventID=4728 or EventID=4732 or EventID=4740 or EventID=4756 or EventID=4771 or EventID=1102)]]"
                Rate      = 50
            })
        }

        foreach ($stream in $logStreams) {
            $processorName = ("windows_{0}_labels" -f $stream.Component)

            # A chave de abertura sai como "{{" porque -f é String.Format:
            # "{" sozinho é lido como início de placeholder e lança
            # FormatException.
            [void]$builder.AppendLine(('loki.process "{0}" {{' -f $processorName))
            [void]$builder.AppendLine("  forward_to = [loki.write.nextec.receiver]")
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine("  // Freio contra tempestade de log. Uma aplicacao em loop de erro pode")
            [void]$builder.AppendLine("  // despejar milhares de eventos por segundo e saturar o link do cliente.")
            [void]$builder.AppendLine("  stage.limit {")
            [void]$builder.AppendLine(("    rate  = {0}" -f $stream.Rate))
            [void]$builder.AppendLine(("    burst = {0}" -f ($stream.Rate * 5)))
            [void]$builder.AppendLine("    drop  = true")
            [void]$builder.AppendLine("  }")
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine("  stage.static_labels {")
            [void]$builder.AppendLine("    values = {")
            [void]$builder.AppendLine(('      cliente     = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Cliente)))
            [void]$builder.AppendLine(('      host        = "{0}",' -f (ConvertTo-AlloyEscapedString $script:HostLabel)))
            [void]$builder.AppendLine('      servico     = "windows_event",')
            [void]$builder.AppendLine(('      canal       = "{0}",' -f (ConvertTo-AlloyEscapedString $stream.Canal)))
            [void]$builder.AppendLine(('      nivel       = "{0}",' -f (ConvertTo-AlloyEscapedString $stream.Nivel)))
            [void]$builder.AppendLine(('      tipo        = "{0}",' -f (ConvertTo-AlloyEscapedString $script:TipoLabel)))
            [void]$builder.AppendLine(('      ambiente    = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Ambiente)))
            [void]$builder.AppendLine('      os          = "windows",')
            [void]$builder.AppendLine('      origem      = "alloy",')
            # criticidade e local são obrigatórias pelo documento 02 e
            # sustentam a correlação métrica/log por local e o roteamento de
            # alerta por criticidade.
            [void]$builder.AppendLine(('      criticidade = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Criticidade)))
            [void]$builder.AppendLine(('      local       = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Local)))
            [void]$builder.AppendLine("    }")
            [void]$builder.AppendLine("  }")
            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")

            [void]$builder.AppendLine(('loki.source.windowsevent "{0}" {{' -f $stream.Component))
            [void]$builder.AppendLine(('  eventlog_name = "{0}"' -f $stream.EventLog))
            [void]$builder.AppendLine(('  xpath_query   = "{0}"' -f $stream.XPath))
            [void]$builder.AppendLine("  use_incoming_timestamp = true")
            # bookmark_path explícito: sem ele uma reinstalação pode fazer o
            # Alloy reler o Event Log desde o início, e com
            # use_incoming_timestamp = true esses eventos são recusados pelo
            # Loki por idade, consumindo banda sem ingerir nada.
            [void]$builder.AppendLine(('  bookmark_path = "{0}"' -f (ConvertTo-AlloyEscapedString (Join-Path $StorageDir ("bookmark-{0}.xml" -f $stream.Component)))))
            [void]$builder.AppendLine(('  forward_to = [loki.process.{0}.receiver]' -f $processorName))
            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")
        }
    }

    if ($script:EnableBlackboxResolved) {
        [void]$builder.AppendLine("// Conectividade e disponibilidade")
        [void]$builder.AppendLine('prometheus.exporter.blackbox "network" {')
        [void]$builder.AppendLine(('  config_file = "{0}"' -f (ConvertTo-AlloyEscapedString $BlackboxFile)))

        foreach ($target in $script:BlackboxTargets) {
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine("  target {")
            [void]$builder.AppendLine(('    name    = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Name)))
            [void]$builder.AppendLine(('    address = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Address)))
            [void]$builder.AppendLine(('    module  = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Module)))
            [void]$builder.AppendLine("    labels = {")
            [void]$builder.AppendLine(('      cliente     = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Cliente)))
            [void]$builder.AppendLine(('      host        = "{0}",' -f (ConvertTo-AlloyEscapedString $target.Name)))
            [void]$builder.AppendLine('      servico     = "blackbox",')
            [void]$builder.AppendLine(('      tipo        = "{0}",' -f (ConvertTo-AlloyEscapedString $target.Type)))
            [void]$builder.AppendLine(('      ambiente    = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Ambiente)))
            [void]$builder.AppendLine('      os          = "network",')
            [void]$builder.AppendLine('      origem      = "blackbox",')
            [void]$builder.AppendLine(('      criticidade = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Criticidade)))
            [void]$builder.AppendLine(('      local       = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Local)))
            [void]$builder.AppendLine("    }")
            [void]$builder.AppendLine("  }")
        }

        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
        # O timeout precisa caber dentro do intervalo, senão o Alloy recusa a
        # configuração em tempo de execução (o validate não pega isso). Fica
        # dois segundos abaixo do intervalo, limitado a 20s.
        $intervaloBlackbox = [Math]::Max(5, [int]$script:BlackboxIntervalSecondsResolved)
        $timeoutBlackbox = [Math]::Max(3, [Math]::Min($intervaloBlackbox - 2, 20))

        [void]$builder.AppendLine('prometheus.scrape "blackbox" {')
        [void]$builder.AppendLine("  targets         = prometheus.exporter.blackbox.network.targets")
        [void]$builder.AppendLine("  forward_to      = [prometheus.relabel.filtro_nextec.receiver]")
        [void]$builder.AppendLine('  job_name        = "integrations/blackbox"')
        [void]$builder.AppendLine(('  scrape_interval = "{0}s"' -f $intervaloBlackbox))
        [void]$builder.AppendLine(('  scrape_timeout  = "{0}s"' -f $timeoutBlackbox))
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
    }

    if ($script:EnableSnmpResolved) {
        [void]$builder.AppendLine("// SNMP")

        # O módulo do fabricante e a credencial do cliente vivem em arquivos
        # separados e são unidos em memória pelo Alloy. Só o arquivo de módulo
        # é público; snmp-auth.yml tem ACL restrita e nunca vai ao repositório.
        $useSplitSnmpConfig = $script:SnmpAuthBlocks.Count -gt 0

        if ($useSplitSnmpConfig) {
            [void]$builder.AppendLine('local.file "snmp_modules" {')
            [void]$builder.AppendLine(('  filename = "{0}"' -f (ConvertTo-AlloyEscapedString $SnmpFile)))
            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine('local.file "snmp_auth" {')
            [void]$builder.AppendLine(('  filename  = "{0}"' -f (ConvertTo-AlloyEscapedString $SnmpAuthFile)))
            [void]$builder.AppendLine("  is_secret = true")
            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")
        }

        [void]$builder.AppendLine('prometheus.exporter.snmp "network" {')

        if ($useSplitSnmpConfig) {
            [void]$builder.AppendLine('  config = local.file.snmp_auth.content + "\n" + local.file.snmp_modules.content')
        }
        else {
            [void]$builder.AppendLine(('  config_file = "{0}"' -f (ConvertTo-AlloyEscapedString $SnmpFile)))
        }

        foreach ($target in $script:SnmpTargets) {
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine(('  target "{0}" {{' -f (ConvertTo-AlloyEscapedString $target.Name)))
            [void]$builder.AppendLine(('    address = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Address)))
            [void]$builder.AppendLine(('    module  = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Module)))
            [void]$builder.AppendLine(('    auth    = "{0}"' -f (ConvertTo-AlloyEscapedString $target.Auth)))
            [void]$builder.AppendLine("    labels = {")
            [void]$builder.AppendLine(('      cliente     = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Cliente)))
            [void]$builder.AppendLine(('      host        = "{0}",' -f (ConvertTo-AlloyEscapedString $target.Name)))
            [void]$builder.AppendLine('      servico     = "snmp",')
            [void]$builder.AppendLine(('      tipo        = "{0}",' -f (ConvertTo-AlloyEscapedString $target.Type)))
            [void]$builder.AppendLine(('      ambiente    = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Ambiente)))
            [void]$builder.AppendLine(('      os          = "{0}",' -f (ConvertTo-AlloyEscapedString $target.Os)))
            [void]$builder.AppendLine('      origem      = "snmp",')
            [void]$builder.AppendLine(('      criticidade = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Criticidade)))
            [void]$builder.AppendLine(('      local       = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Local)))
            [void]$builder.AppendLine("    }")
            [void]$builder.AppendLine("  }")
        }

        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
        # SNMP usa 120s de intervalo e 60s de timeout. Walk SNMP em
        # equipamento de entrada leva de 15 a 45 segundos, e dado de rede não
        # precisa de resolução de um minuto. Timeout curto aqui é a causa
        # conhecida de up=0 intermitente em firewall.
        [void]$builder.AppendLine('prometheus.scrape "snmp" {')
        [void]$builder.AppendLine("  targets         = prometheus.exporter.snmp.network.targets")
        [void]$builder.AppendLine("  forward_to      = [prometheus.relabel.filtro_nextec.receiver]")
        [void]$builder.AppendLine('  job_name        = "integrations/snmp"')
        [void]$builder.AppendLine('  scrape_interval = "120s"')
        [void]$builder.AppendLine('  scrape_timeout  = "60s"')
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
    }

    if ($script:CustomExporters.Count -gt 0) {
        for ($i = 0; $i -lt $script:CustomExporters.Count; $i++) {
            $target = $script:CustomExporters[$i]
            $idx = $i + 1

            [void]$builder.AppendLine(('discovery.relabel "custom_{0}" {{' -f $idx))
            [void]$builder.AppendLine(('  targets = [{{ "__address__" = "{0}" }}]' -f (ConvertTo-AlloyEscapedString $target.Target)))
            [void]$builder.AppendLine("")

            Add-AlloyRelabelRule -Builder $builder -Target "instance" -Replacement $script:HostLabel
            Add-AlloyRelabelRule -Builder $builder -Target "host" -Replacement $script:HostLabel
            Add-AlloyRelabelRule -Builder $builder -Target "cliente" -Replacement $script:Cliente
            Add-AlloyRelabelRule -Builder $builder -Target "servico" -Replacement $target.Service
            Add-AlloyRelabelRule -Builder $builder -Target "tipo" -Replacement $script:TipoLabel
            Add-AlloyRelabelRule -Builder $builder -Target "ambiente" -Replacement $script:Ambiente
            Add-AlloyRelabelRule -Builder $builder -Target "os" -Replacement "windows"
            Add-AlloyRelabelRule -Builder $builder -Target "origem" -Replacement "exporter_especializado"
            Add-AlloyRelabelRule -Builder $builder -Target "criticidade" -Replacement $script:Criticidade
            Add-AlloyRelabelRule -Builder $builder -Target "local" -Replacement $script:Local

            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")
            [void]$builder.AppendLine(('prometheus.scrape "custom_{0}" {{' -f $idx))
            [void]$builder.AppendLine(('  targets         = discovery.relabel.custom_{0}.output' -f $idx))
            [void]$builder.AppendLine("  forward_to      = [prometheus.relabel.filtro_nextec.receiver]")
            [void]$builder.AppendLine(('  job_name        = "integrations/{0}"' -f (ConvertTo-AlloyEscapedString $target.Service)))
            [void]$builder.AppendLine('  scrape_interval = "60s"')
            [void]$builder.AppendLine('  scrape_timeout  = "20s"')
            [void]$builder.AppendLine("}")
            [void]$builder.AppendLine("")
        }
    }

    $content = $builder.ToString()

    # Uma configuração só com remote_write é sintaticamente válida e o serviço
    # sobe normalmente, mas nada é coletado. Sem esta checagem o host entra no
    # inventário sem produzir nenhuma série.
    if (($content -notmatch "prometheus\.scrape") -and ($content -notmatch "loki\.source")) {
        throw "A configuração gerada não possui nenhuma coleta (nenhum prometheus.scrape nem loki.source). Revise os recursos selecionados."
    }

    # Marcado antes da escrita: se WriteAllText falhar no meio, o arquivo já
    # está alterado e o rollback precisa rodar.
    $script:ConfigChanged = $true

    [IO.File]::WriteAllText(
        $ConfigFile,
        $content,
        (New-Object Text.UTF8Encoding($false))
    )
    Write-Ok ("Configuração criada: {0}" -f $ConfigFile)
}

function Invoke-AlloyCommand {
    <#
        Executa o CLI do Alloy e devolve código de saída e saída combinada.

        Usa Start-Process com redirecionamento para arquivo em vez do operador
        de chamada. Motivo: com $ErrorActionPreference em "Stop", o "2>&1" de um
        comando nativo faz o PowerShell 5.1 tratar cada linha de stderr como
        erro terminante, e o fluxo morre antes de qualquer checagem de código de
        saída, mesmo quando o alloy só emitiu um aviso. Start-Process também
        entrega o ExitCode direto no objeto do processo, sem depender de
        $LASTEXITCODE, que é variável automática e não deve ser atribuída.
    #>
    param([Parameter(Mandatory=$true)][string[]]$Arguments)

    $stdout = [IO.Path]::GetTempFileName()
    $stderr = [IO.Path]::GetTempFileName()

    # Start-Process -ArgumentList NÃO cita elementos de array que contêm
    # espaço: um array como @("fmt", "C:\Program Files\...\config.alloy")
    # vira dois argumentos separados na linha de comando real, e o Alloy
    # recebe um caminho quebrado. Cada elemento precisa ser citado à mão e
    # passado como uma única string de linha de comando.
    $commandLine = ($Arguments | ForEach-Object {
        '"{0}"' -f ($_ -replace '"', '\"')
    }) -join " "

    try {
        $process = Start-Process `
            -FilePath $AlloyExe `
            -ArgumentList $commandLine `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        $output = New-Object System.Collections.Generic.List[string]

        foreach ($file in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $file) {
                $text = [IO.File]::ReadAllText($file).Trim()

                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $output.Add($text)
                }
            }
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = ($output -join "`r`n")
        }
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Format-AndValidateAlloyConfiguration {
    Write-Step "Validando configuração do Alloy"

    if (-not (Test-Path -LiteralPath $AlloyExe)) {
        throw ("Executável do Alloy não encontrado: {0}" -f $AlloyExe)
    }

    # fmt e validate são subcomandos do CLI. O wrapper de serviço aceita ser
    # invocado, não reclama, e não faz nada do que se espera aqui.
    if ((Split-Path -Leaf $AlloyExe) -match "(?i)service") {
        throw ("O caminho resolvido aponta para o wrapper de serviço ({0}), não para o CLI do Alloy. Verifique o conteúdo de {1}." -f (Split-Path -Leaf $AlloyExe), $AlloyDir)
    }

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw ("config.alloy não encontrado: {0}" -f $ConfigFile)
    }

    $oldRwUser = [Environment]::GetEnvironmentVariable("NEXTEC_RW_USERNAME", "Process")
    $oldRwPassword = [Environment]::GetEnvironmentVariable("NEXTEC_RW_PASSWORD", "Process")
    $oldLokiUser = [Environment]::GetEnvironmentVariable("NEXTEC_LOKI_USERNAME", "Process")
    $oldLokiPassword = [Environment]::GetEnvironmentVariable("NEXTEC_LOKI_PASSWORD", "Process")

    try {
        if (-not [string]::IsNullOrEmpty($script:RwUsername)) {
            [Environment]::SetEnvironmentVariable("NEXTEC_RW_USERNAME", $script:RwUsername, "Process")
            [Environment]::SetEnvironmentVariable("NEXTEC_RW_PASSWORD", $script:RwPassword, "Process")
        }

        if ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved) {
            if (-not [string]::IsNullOrEmpty($script:LokiUsername)) {
                [Environment]::SetEnvironmentVariable("NEXTEC_LOKI_USERNAME", $script:LokiUsername, "Process")
                [Environment]::SetEnvironmentVariable("NEXTEC_LOKI_PASSWORD", $script:LokiPassword, "Process")
            }
        }

        $format = Invoke-AlloyCommand -Arguments @("fmt", "--write", $ConfigFile)

        if ($format.ExitCode -ne 0) {
            throw ("alloy fmt falhou:`r`n{0}" -f $format.Output)
        }

        $validation = Invoke-AlloyCommand -Arguments @("validate", $ConfigFile)

        if ($validation.ExitCode -ne 0) {
            throw ("alloy validate falhou:`r`n{0}" -f $validation.Output)
        }

        Write-Ok "Configuração Alloy validada."
    }
    finally {
        [Environment]::SetEnvironmentVariable("NEXTEC_RW_USERNAME", $oldRwUser, "Process")
        [Environment]::SetEnvironmentVariable("NEXTEC_RW_PASSWORD", $oldRwPassword, "Process")
        [Environment]::SetEnvironmentVariable("NEXTEC_LOKI_USERNAME", $oldLokiUser, "Process")
        [Environment]::SetEnvironmentVariable("NEXTEC_LOKI_PASSWORD", $oldLokiPassword, "Process")
    }
}

function Restart-AlloyService {
    Write-Step "Reiniciando serviço Alloy"

    $service = Get-AlloyService

    if ($null -eq $service) {
        throw "Serviço Alloy não encontrado."
    }

    if ($service.Status -eq "Running") {
        Restart-Service -Name $service.Name -Force
    }
    else {
        Start-Service -Name $service.Name
    }

    $deadline = (Get-Date).AddSeconds(30)

    do {
        Start-Sleep -Seconds 1
        $service = Get-Service -Name $script:AlloyServiceName

        if ($service.Status -eq "Running") {
            break
        }
    }
    while ((Get-Date) -lt $deadline)

    if ($service.Status -ne "Running") {
        throw "Serviço Alloy não ficou em execução."
    }

    Write-Ok "Serviço Alloy está ativo."
}

function Test-AlloyReadiness {
    <#
        Confirma que o Alloy subiu e respondeu no endpoint local de readiness.

        Falha aqui é erro, não aviso: um agente que não sobe precisa impedir
        que o instalador declare sucesso.

        -Mandatory $false é usado apenas no menu de manutenção, onde o objetivo
        é diagnosticar sem interromper o fluxo.
    #>
    param([bool]$Mandatory = $true)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri "http://127.0.0.1:12345/-/ready" `
                -UseBasicParsing `
                -TimeoutSec 5

            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                Write-Ok "Readiness local do Alloy respondeu."
                return
            }
        }
        catch {
            # Erro nas primeiras tentativas é esperado: o serviço ainda está
            # subindo. A falha definitiva é tratada depois do laço.
            Write-Verbose ("Tentativa {0} de readiness falhou: {1}" -f $attempt, $_.Exception.Message)
        }

        Start-Sleep -Seconds 2
    }

    $message = "Alloy não respondeu em http://127.0.0.1:12345/-/ready após 10 tentativas. Verifique 'Get-Service Alloy' e o log de eventos (Application, provedor Alloy)."

    if ($Mandatory) {
        throw $message
    }

    Write-Warn $message
}

function Test-AlloyIngestion {
    <#
        Confirma que o Alloy está enviando amostras ao NOC.

        Test-AlloyReadiness só garante que o processo subiu: o endpoint
        responde 200 mesmo com credencial errada, sem targets ou com os
        componentes em erro. Aqui lemos o /metrics do próprio Alloy e
        comparamos prometheus_remote_storage_samples_total em dois momentos.

        Não lança erro porque em link lento o primeiro envio pode demorar mais
        que a janela observada. O resultado é informativo.
    #>
    Write-Step "Verificando envio de métricas para o NOC"

    function Get-AlloySampleCounters {
        try {
            $metrics = (Invoke-WebRequest -Uri "http://127.0.0.1:12345/metrics" -UseBasicParsing -TimeoutSec 10).Content
        }
        catch {
            return $null
        }

        $sent = 0.0
        $failed = 0.0

        foreach ($line in ($metrics -split "`n")) {
            if ($line.StartsWith("#")) { continue }

            if ($line -match '^prometheus_remote_storage_samples_total\{[^}]*\}\s+([0-9.e+-]+)$') {
                $sent += [double]$Matches[1]
            }
            elseif ($line -match '^prometheus_remote_storage_samples_failed_total\{[^}]*\}\s+([0-9.e+-]+)$') {
                $failed += [double]$Matches[1]
            }
        }

        return [pscustomobject]@{ Sent = $sent; Failed = $failed }
    }

    $first = Get-AlloySampleCounters

    if ($null -eq $first) {
        Write-Warn "Não foi possível ler as métricas internas do Alloy; pule esta verificação e confira no Grafana."
        return
    }

    Start-Sleep -Seconds 45
    $second = Get-AlloySampleCounters

    if ($null -eq $second) {
        Write-Warn "Não foi possível reler as métricas internas do Alloy."
        return
    }

    $delta = $second.Sent - $first.Sent
    $failedDelta = $second.Failed - $first.Failed

    if ($delta -gt 0 -and $failedDelta -le 0) {
        Write-Ok ("Envio confirmado: {0:N0} amostras entregues ao NOC nos últimos 45s." -f $delta)
        return
    }

    if ($failedDelta -gt 0) {
        Write-Fail ("O Alloy tentou enviar e o NOC recusou {0:N0} amostras. Causa mais comum: usuário/senha de remote_write incorretos." -f $failedDelta)
        return
    }

    Write-Warn "Nenhuma amostra foi enviada ao NOC na janela observada. Confirme no Grafana em alguns minutos; se não aparecer, revise credenciais e conectividade."
}

function Restore-Configuration {
    if (-not $script:ConfigChanged) {
        return
    }

    Write-Warn "Executando rollback da configuração."

    try {
        $restored = $false

        if ($null -ne $script:ConfigBackup -and (Test-Path -LiteralPath $script:ConfigBackup)) {
            Copy-Item -LiteralPath $script:ConfigBackup -Destination $ConfigFile -Force
            $restored = $true
            Write-Warn "Configuração anterior restaurada."
        }
        else {
            Remove-Item -LiteralPath $ConfigFile -Force -ErrorAction SilentlyContinue
            Write-Warn "Configuração nova removida, pois não existia configuração anterior."
        }

        foreach ($auxiliar in @($script:AuxiliaryBackups)) {
            if (Test-Path -LiteralPath $auxiliar.Backup -PathType Leaf) {
                Copy-Item -LiteralPath $auxiliar.Backup -Destination $auxiliar.Original -Force
                Write-Warn ("Restaurado: {0}" -f (Split-Path -Leaf $auxiliar.Original))
            }
        }

        # A tarefa agendada é criada antes da validação do config.alloy. Se a
        # instalação foi revertida, deixá-la ativa produz um teste de
        # velocidade a cada 30 minutos num host que não coleta o resultado.
        if ($script:EnableInternetResolved -and -not $restored) {
            try {
                Unregister-ScheduledTask -TaskName $SpeedtestTaskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Warn ("Tarefa agendada {0} removida no rollback." -f $SpeedtestTaskName)
            }
            catch {
                Write-Warn ("Não foi possível remover a tarefa {0}: {1}" -f $SpeedtestTaskName, $_.Exception.Message)
            }
        }

        # O registro guarda as credenciais e os argumentos do serviço, e é
        # reescrito antes da configuração. Sem restaurá-lo, o Alloy continua no
        # ar com a config antiga mas com credenciais novas e erradas, e passa a
        # receber 401 no remote_write no próximo restart.
        if ($null -ne $script:RegistryBackup) {
            try {
                # [pscustomobject] não aceita indexação por colchetes ($obj["chave"]
                # sempre lança "Não é possível indexar..."); o acesso correto é por
                # ponto, igual ao que Restore-ServiceEnvironment já fazia.
                foreach ($name in @("Environment", "Arguments")) {
                    $value = $script:RegistryBackup.$name

                    if ($null -ne $value) {
                        New-ItemProperty -Path $RegistryPath -Name $name -PropertyType MultiString `
                            -Value ([string[]]$value) -Force | Out-Null
                    }
                }
                Write-Warn "Registro do serviço Alloy restaurado."
            }
            catch {
                Write-Fail ("Não foi possível restaurar o registro do serviço: {0}" -f $_.Exception.Message)
            }
        }

        # Reinicia apenas quando há configuração restaurada para carregar. Se
        # a config foi removida, o processo em execução ainda tem a versão
        # anterior em memória e reiniciar o derruba.
        $service = Get-AlloyService

        if ($null -ne $service -and $restored) {
            Restart-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        }
        elseif (-not $restored) {
            Write-Warn "Serviço Alloy NÃO foi reiniciado: não há configuração válida para carregar."
        }
    }
    catch {
        Write-Fail ("Rollback encontrou erro: {0}" -f $_.Exception.Message)
    }
}

# ==============================================================================
# RESUMO
# ==============================================================================

function Show-FinalSummary {
    param([Parameter(Mandatory=$true)][object]$Inventory)

    # O título muda quando algo ficou pendente: encerrar um atendimento lendo
    # "INSTALAÇÃO CONCLUÍDA" numa instalação que perdeu o SNMP é o tipo de
    # coisa que só aparece semanas depois, quando alguém sente falta do dado.
    $comPendencia = ($script:EtapasComFalha.Count -gt 0)
    $cor = if ($comPendencia) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
    $titulo = if ($comPendencia) { "        INSTALAÇÃO CONCLUÍDA COM PENDÊNCIAS" } else { "                 INSTALAÇÃO CONCLUÍDA" }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor $cor
    Write-Host $titulo -ForegroundColor $cor
    Write-Host "============================================================" -ForegroundColor $cor
    Write-Host ("Cliente:        {0}" -f $script:Cliente)
    Write-Host ("Host:           {0}" -f $script:HostLabel)
    Write-Host ("Sistema:        {0}" -f $Inventory.Caption)
    Write-Host ("Tipo:           {0}" -f $Inventory.Generation)
    Write-Host ("Modo:           {0}" -f $script:ResolvedMode)
    # Estado real do serviço. O resumo é o que o técnico usa para encerrar o
    # atendimento, então não pode afirmar nada que não tenha sido verificado.
    $alloyService = Get-AlloyService
    $alloyStatus = if ($null -ne $alloyService) { [string]$alloyService.Status } else { "não encontrado" }
    Write-Host ("Alloy:          {0}" -f $alloyStatus)
    Write-Host ("Configuração:   {0}" -f $ConfigFile)
    Write-Host ("Métricas:       {0}" -f $script:RemoteWriteUrl)

    if ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved) {
        Write-Host ("Logs:           {0}" -f $script:LokiUrl)
    }

    if ($script:MonitorHost) {
        $selectedFeatures = @($script:DetectedHostFeatures | Where-Object { $script:SelectedHostFeatureKeys -contains $_.Key })
        if ($selectedFeatures.Count -gt 0) {
            Write-Host ("Recursos:       {0}" -f (($selectedFeatures | ForEach-Object { $_.Label }) -join ", "))
        }
    }

    if ($script:EnableBlackboxResolved) {
        Write-Host ("Conectividade:   {0} alvo(s)" -f $script:BlackboxTargets.Count)
    }

    if ($script:EnableSnmpResolved) {
        Write-Host ("SNMP:           {0} alvo(s)" -f $script:SnmpTargets.Count)
    }

    if ($script:EnableInternetResolved) {
        Write-Host ("Internet:       Speedtest a cada {0} min ({1})" -f $script:InternetIntervalMinutesResolved, $SpeedtestMetricsFile)
    }

    if ($script:CustomExporters.Count -gt 0) {
        Write-Host ("Exporters:      {0}" -f $script:CustomExporters.Count)
    }

    Write-Host ("Log instalador: {0}" -f $script:InstallerLog)

    if ($comPendencia) {
        Write-Host ""
        Write-Host "PENDÊNCIAS" -ForegroundColor Yellow
        Write-Host "O host está sendo monitorado, mas estes itens não puderam ser" -ForegroundColor Yellow
        Write-Host "configurados. Rode o instalador de novo e use a opção" -ForegroundColor Yellow
        Write-Host "'Ver e alterar a configuração atual' para tentar só o que faltou." -ForegroundColor Yellow
        Write-Host ""

        foreach ($etapa in $script:EtapasComFalha) {
            Write-Host ("  - {0}" -f $etapa.Nome) -ForegroundColor Yellow
            Write-Host ("      {0}" -f $etapa.Erro) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "Diagnóstico:"
    Write-Host '  Get-Service Alloy'
    Write-Host ('  & "{0}" validate "{1}"' -f $AlloyExe, $ConfigFile)
    Write-Host '  Invoke-WebRequest http://127.0.0.1:12345/-/ready -UseBasicParsing'
    Write-Host '  Get-WinEvent -LogName Application | Where-Object ProviderName -Match "Alloy|Grafana" | Select-Object -First 20'
}

# ==============================================================================
# MAIN
# ==============================================================================

function Invoke-NextecInstaller {
    Show-Banner
    Initialize-Logging
    Assert-Administrator

    try {
        Set-NocDestination

        if (-not (Invoke-MaintenanceMenu)) {
            return
        }

        $inventory = Get-WindowsInventory
        $serverRoles = @(Get-WindowsServerRoles -Inventory $inventory)
        $sql = Get-SqlServerDetection
        $firebird = Get-FirebirdDetection
        $detectedFeatures = @(Get-DetectedHostFeatures -Inventory $inventory -ServerRoles $serverRoles -Sql $sql -Firebird $firebird)

        Show-DetectionSummary -Inventory $inventory -DetectedFeatures @($detectedFeatures)
        Get-NextecConfiguration -Inventory $inventory -DetectedFeatures $detectedFeatures
        Read-NocCredentials
        Show-Plan -Inventory $inventory

        Test-NocConnectivity

        # O backup precisa vir antes de Install-OrUpdateAlloy: o instalador
        # oficial escreve no diretório de configuração, e um backup posterior
        # guardaria o arquivo já sobrescrito.
        Backup-ExistingConfiguration

        # Daqui até a validação, só o essencial derruba a instalação: binário,
        # credenciais, geração e validação da configuração, e o serviço. As
        # capacidades opcionais que falharem são desligadas e reportadas no
        # fim, para que uma falha em SNMP não custe ao cliente o
        # monitoramento de CPU, disco, serviços e logs.
        Install-OrUpdateAlloy
        Set-AlloyServiceEnvironment

        if ($script:EnableBlackboxResolved) {
            Invoke-NextecOptionalStep -Nome "Alvos de conectividade (Blackbox)" -Acao {
                New-BlackboxConfiguration
            } -AoFalhar {
                $script:EnableBlackboxResolved = $false
                $script:BlackboxTargets = @()
            } | Out-Null
        }

        if ($script:EnableSnmpResolved) {
            Invoke-NextecOptionalStep -Nome "SNMP" -Acao {
                Install-SnmpConfiguration
            } -AoFalhar {
                $script:EnableSnmpResolved = $false
                $script:SnmpTargets = @()
                $script:SnmpAuthBlocks = @()
            } | Out-Null
        }

        if ($script:EnableInternetResolved) {
            Invoke-NextecOptionalStep -Nome "Internet (Speedtest)" -Acao {
                Install-InternetMonitoring
            } -AoFalhar {
                $script:EnableInternetResolved = $false
            } | Out-Null
        }

        $script:Collector = ($script:EnableBlackboxResolved -or $script:EnableSnmpResolved -or
                             $script:EnableInternetResolved -or ($script:CustomExporters.Count -gt 0))

        New-AlloyConfiguration -Inventory $inventory
        Format-AndValidateAlloyConfiguration
        Restart-AlloyService

        # Verificação não reverte nada: a configuração já está válida no disco
        # e o serviço já subiu. Falha aqui é informação para o técnico.
        Invoke-NextecVerification -Nome "Prontidão do Alloy" -Acao { Test-AlloyReadiness }
        Invoke-NextecVerification -Nome "Teste de ingestão no NOC" -Acao { Test-AlloyIngestion }

        Show-FinalSummary -Inventory $inventory
    }
    catch {
        # A mensagem de erro é impressa uma única vez, no despacho final do
        # script (fora desta função), que também cobre falhas ocorridas
        # antes deste bloco try (ex.: Assert-Administrator). Aqui só cuidamos
        # do rollback antes de repassar a exceção adiante.
        Restore-Configuration
        throw
    }
}

try {
    # A decisão de relançar vem antes de tudo, inclusive do banner: Show-Banner
    # limpa a tela, e limpar a tela para em seguida abrir outra janela apaga o
    # contexto do operador sem necessidade.
    $precisaBitness = Test-NextecProcessNeedsBitnessRelaunch
    $precisaElevar = -not (Test-NextecIsAdministrator)

    if ($precisaBitness -or $precisaElevar) {
        $script:Relaunched = $true
        $script:ExitCode = Invoke-NextecRelaunch -BoundParameters $script:OriginalBoundParameters -NeedsBitness:$precisaBitness -NeedsElevation:$precisaElevar
    }
    else {
        Invoke-NextecInstaller

        # 2 distingue, para a automação, "instalou e está monitorando, mas
        # algo opcional ficou de fora" de sucesso pleno (0) e de falha (1).
        if ($script:EtapasComFalha.Count -gt 0) {
            $script:ExitCode = 2
        }
    }
}
catch {
    # Ponto único onde o erro é mostrado ao operador, cobrindo tanto falhas
    # de dentro do try de Invoke-NextecInstaller (rollback já feito lá)
    # quanto falhas antes disso. Sem este try/catch aqui fora, o PowerShell
    # também despejaria o stack trace nativo por cima da nossa mensagem.
    Write-Fail $_.Exception.Message

    if (-not [string]::IsNullOrWhiteSpace([string]$script:InstallerLog)) {
        Write-Info ("Log desta execução: {0}" -f $script:InstallerLog)
    }

    if ($script:ExitCode -eq 0) {
        $script:ExitCode = 1
    }
}
finally {
    # Stop-Logging fica aqui, depois do Write-Fail, para que a causa da falha
    # entre no transcript. No finally interno, o log era encerrado antes de a
    # mensagem existir e o suporte recebia um log que parava no rollback.
    Stop-Logging

    # Segura a janela antes de devolver o controle, porque o console aberto por
    # duplo clique ou atalho fecha assim que o script retorna. Quando o
    # trabalho foi delegado a outra sessão, quem espera o operador é ela.
    if (-not $Silent -and -not $script:Relaunched) {
        Wait-NextecOperator
    }
}

# Dot-source (". .\script.ps1") roda no processo do operador, e ali "exit"
# encerraria a sessão inteira dele. Fora esse caso, o código de saída é o que
# permite a automação distinguir sucesso de falha, inclusive quando o trabalho
# foi feito pela sessão elevada.
if ($MyInvocation.InvocationName -ne ".") {
    exit $script:ExitCode
}