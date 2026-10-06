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

    Execução direta do GitHub (sem baixar o arquivo):
      $u = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/install-nextec-monitoring-windows-v2.ps1"
      & ([scriptblock]::Create((irm $u).TrimStart([char]0xFEFF)))

    Parâmetros vão no fim da linha, por exemplo -Simular ou -Console.
    O TrimStart é obrigatório: o irm entrega o BOM como primeiro caractere,
    o parser do PowerShell não o trata como espaço e o param() deixa de ser
    a primeira instrução ("Unexpected attribute 'CmdletBinding'"). O BOM
    continua no arquivo porque o Windows PowerShell 5.1 lê .ps1 sem BOM
    como ANSI e corromperia os acentos quando o script roda de um arquivo.

    -------------------------------------------------------------------------
    HISTÓRICO
    -------------------------------------------------------------------------
    2.22.0 Virtualização: Hyper-V do próprio servidor (VMs, checkpoints,
           replicação, armazenamento) e hipervisores pela rede (VMware ESXi ou
           vCenter, Proxmox VE e XCP-ng), com senha ou token protegido.
    2.21.0 Coletor time no perfil básico (relógio e sincronia NTP, inclusive
           em controlador de domínio). Speedtest passa a ser módulo da Coleta
           Complementar: a tarefa NextecSpeedtest e o serviço antigo são
           removidos depois que o Alloy sobe validado.
    2.20.0 Bancos: Firebird, Oracle e SQL Anywhere detectados e medidos pela
           Coleta Complementar (no ar, conexões, memória, tamanho das bases),
           e bases SQLite informadas na tela.
    2.19.1 Fabricantes SNMP em ordem alfabética.
    2.19.0 Instalação existente com área de trabalho: estado e opções numa
           janela; "Ver e alterar" abre as abas preenchidas com a
           configuração atual, inclusive equipamentos SNMP e credenciais.
    2.18.0 SNMP: Ubiquiti, Cisco, HP / Aruba, TP-Link e Intelbras no
           catálogo de fabricantes.
    2.17.2 Corrige a tela que não abria na 2.17.1 (ícone da janela lido
           antes de existir, erro no modo estrito).
    2.17.1 Emblema da Nextec como ícone das janelas (barra de título e
           barra de tarefas), no lugar do ícone padrão do PowerShell.
    2.17.0 Tela mais clara: campos obrigatórios com asterisco vermelho;
           perfil básico recolhido; Speedtest com a recomendação ao lado;
           links em Mbps e Função com inicial maiúscula; testes de
           conectividade numerados do mais simples (1) ao mais completo
           (6); equipamento SNMP cadastrado numa janela só, com a
           credencial junto e aviso para fabricante fora da lista;
           exporters pelo nome do serviço, com passo a passo para outro
           serviço. Janela de andamento: o console fica escondido, o log
           aparece na própria tela e ela só fecha quando o técnico quiser
           (vale para a simulação e para a instalação). Escala correta
           em telas de 125% e 150% no PowerShell 7.

    2.16.2 Logo da Nextec no cabeçalho da tela de instalação, embutida no
           próprio script.

    2.16.1 Tela Recursos: o perfil básico (CPU, memória, discos, rede,
           uptime e serviços do Windows) aparece na árvore marcado e
           travado, em cinza, em vez de só citado no texto.
           One-liner documentado com TrimStart([char]0xFEFF). Desde a
           2.15.4 o arquivo tem BOM, e o [scriptblock]::Create(irm ...)
           falhava com "Unexpected attribute 'CmdletBinding'".

    2.16.0 Tela de instalação (WinForms dentro do próprio script): abre
           sozinha quando há área de trabalho, com abas para identificação,
           recursos (exporters em árvore), links, conectividade, SNMP,
           exporters, credenciais e resumo, validando cada campo na hora.
           A instalação em si é a mesma do console. -Console força o
           console; RMM, sessão sem tela e Server Core seguem no console.
           -Simular abre as telas e mostra o resumo sem instalar nada.
           SNMP: SonicWall no catálogo; módulo atualizado do repositório
           substitui o antigo no snmp.yml; com mais de um fabricante no
           arquivo, o técnico escolhe qual vale para o equipamento.
           Menu de instalação existente igual ao Linux: mostra o pacote
           Nextec aplicado e as coletas ligadas, e ao ligar logs ou a Coleta
           pede só a credencial do Loki.
    2.15.4 Teste de velocidade: o nome do servidor da Ookla chegava com
           acento quebrado ("Claro M├│vel"). A saída do speedtest.exe
           passa a ser lida como UTF-8, e o script da tarefa é gravado com
           BOM para o PowerShell 5.1 não quebrar os textos das métricas.
    2.15.3 Destino aparece uma vez só (no topo); a pergunta vira "Destino do
           monitoramento [ENTER mantém, D altera]". Arquivo pequeno aparece
           em KB, não "0.0 MB".
    2.15.2 Links: "Quantos links de internet este local tem?" (padrão 1) no
           lugar do item "Links de internet" do checklist e da pergunta "tem
           mais de um link?". Por link: operadora, tipo e velocidade
           contratada (padronizada em Mbps a partir de "500", "1 Giga",
           "600/300"); função só com mais de um link. Destinos de teste
           prontos (três por link, sem repetir entre links), trocados só se
           o técnico quiser. Telefone de suporte saiu.
    2.15.1 Console com fundo preto durante a instalação (o azul do
           PowerShell apagava as cores). Cadastro de links refeito: pergunta
           quantos links o local tem e, por link, só operadora, tipo, função
           e telefone; o nome sai da operadora e do tipo, o IP público é
           detectado e o resto fica em "opções avançadas".
    2.15.0 Saída com a mesma hierarquia visual do instalador Linux (títulos
           de etapa, símbolos, perguntas, resumo e quadro final). Download do
           Alloy, do Speedtest, da Coleta e do atualizador com porcentagem.
           Variáveis NEXTEC_*_URL passam para a sessão reaberta como
           Administrador (antes a elevação perdia a URL da branch de teste).
           "Ver e alterar" instala o atualizador e repara componentes que
           ficaram pendentes, mesmo sem outra alteração.
    2.14.1 O menu de instalação existente mostra a versão deste instalador,
           a versão que gerou o config.alloy atual e as versões da Coleta
           Complementar e do atualizador instalados.
    2.14.0 Atualizador automático Nextec: o instalador passa a instalar a
           tarefa NextecAtualizador (SYSTEM, de madrugada), que aplica
           versões publicadas e assinadas pela Nextec, em ondas e com volta
           automática. Novo modo -Atualizar, sem perguntas, que reaplica a
           configuração atual com arquivos já conferidos pela assinatura
           (-ColetaArquivo, -AtualizadorArquivo, -AlloyInstaladorArquivo).
           Pastas executadas como SYSTEM (Nextec, Coleta, Speedtest) passam a
           ter ACL restrita: usuário comum só lê.
    2.13.0 Todas as respostas digitadas são validadas e a pergunta é repetida
           quando o valor é inválido, em vez de encerrar: cliente (hífen e
           acento convertidos para o padrão de labels), host, local, IPs,
           host:porta, URLs, listas de destinos e interface WAN dos links.
    2.12.0 Coleta Complementar Nextec: monitoramento de internet (status,
           DNS, IP público, diagnóstico) e de cada link do local (failover,
           gateway da operadora, causa das quedas). Arquivo único baixado do
           repositório Scripts, roda por tarefa agendada e grava arquivos que
           o próprio Alloy envia. Oferecida em qualquer modo, não só collector.
           O .prom do Speedtest passa a terminar com quebra de linha, exigida
           pelo coletor textfile.

    2.11.0 Corrige o registro da tarefa do Speedtest. O gatilho usava
           [TimeSpan]::MaxValue como duracao da repeticao, o que gera
           "P99999999DT23H59M59S" e faz o agendador recusar a tarefa com
           HRESULT 0x80041318. Pelo schema do Task Scheduler, repeticao sem
           duracao ja significa indefinida.

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
    # [Modo Silencioso] Liga a Coleta Complementar (internet, DNS, IP público
    # e diagnóstico). Links ficam no arquivo coleta-complementar.ini; se ele já
    # existir, é preservado.
    [switch]$EnableColeta,
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
    [switch]$Silent,
    # Usa as perguntas no console mesmo quando há área de trabalho (sem a tela).
    [switch]$Console,
    # Abre as telas e mostra o resumo, sem instalar nem alterar nada. Não
    # precisa de Administrador. Grava as respostas (sem senha) em
    # %TEMP%\nextec-simulacao.json.
    [switch]$Simular,
    # Modo do atualizador automático: reaplica a configuração atual sem
    # perguntas e sem pedir credencial. Os arquivos chegam já conferidos pela
    # assinatura do manifesto da Nextec.
    [switch]$Atualizar,
    [string]$ColetaArquivo = "",
    [string]$AtualizadorArquivo = "",
    [string]$AlloyInstaladorArquivo = "",
    [string]$AlloyVersao = "",
    [string]$PacoteVersao = ""
)

# A atualização nunca pergunta nada: roda pela tarefa agendada, sem console.
if ($Atualizar) { $Silent = [switch]$true }

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

$InstallerVersion = "2.22.0"

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
# Em ordem alfabética, como aparece para o técnico.
$NextecSnmpVendors = [ordered]@{
    "1" = @{ Label = "Cisco"; File = "cisco.yml" }
    "2" = @{ Label = "FortiGate"; File = "fortigate.yml" }
    "3" = @{ Label = "HP / Aruba"; File = "hp.yml" }
    "4" = @{ Label = "Intelbras"; File = "intelbras.yml" }
    "5" = @{ Label = "MikroTik"; File = "mikrotik.yml" }
    "6" = @{ Label = "pfSense"; File = "pfsense.yml" }
    "7" = @{ Label = "SonicWall"; File = "sonicwall.yml" }
    "8" = @{ Label = "TP-Link"; File = "tplink.yml" }
    "9" = @{ Label = "Ubiquiti"; File = "ubiquiti.yml" }
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
# Nomes do Speedtest antigo (tarefa até a 2.20; serviço de instalações à mão).
$SpeedtestLegadoNomes = @($SpeedtestTaskName, "nextec-speedtest")

# Coleta Complementar Nextec (internet e links). Arquivo único baixado do
# repositório Scripts; roda por tarefa agendada como SYSTEM e só grava
# arquivos locais (métricas .prom e eventos em JSON). Quem envia é o Alloy.
# NEXTEC_COLETA_URL permite testar uma branch sem alterar o instalador.
$ColetaUrl = if ($env:NEXTEC_COLETA_URL) { $env:NEXTEC_COLETA_URL } else { "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/coleta-complementar/coleta-complementar.ps1" }
$ColetaDir = Join-Path $ProgramDataDir "coleta-complementar"
$ColetaScript = Join-Path $ColetaDir "coleta-complementar.ps1"
$ColetaConfig = Join-Path $ColetaDir "coleta-complementar.ini"
# Senhas e tokens dos hipervisores consultados pela rede (só SYSTEM e Administradores).
$ColetaSegredos = Join-Path $ColetaDir "segredos.ini"
$ColetaTextfileDir = Join-Path $ColetaDir "textfile"
$ColetaEventos = Join-Path $ColetaDir "eventos.jsonl"
$ColetaTaskName = "NextecColetaComplementar"
# Versão pinada do Ookla Speedtest CLI. Checar a versão mais recente em
# https://www.speedtest.net/apps/cli antes de trocar; um ZIP inexistente
# nessa URL derruba a instalação do zero, não fica em modo degradado.
$SpeedtestCliVersion = "1.2.0"
$SpeedtestCliUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-{0}-win64.zip" -f $SpeedtestCliVersion

# Atualizador automático Nextec. Pasta própria, com ACL restrita, porque o
# script roda como SYSTEM. NEXTEC_ATUALIZADOR_URL permite testar uma branch.
$NextecDataDir = Join-Path $env:ProgramData "Nextec"
$AtualizadorDir = Join-Path $NextecDataDir "atualizador"
$AtualizadorScript = Join-Path $AtualizadorDir "nextec-atualizador.ps1"
$AtualizadorConfig = Join-Path $NextecDataDir "atualizador.conf"
$AtualizadorTaskName = "NextecAtualizador"
$AtualizadorUrl = if ($env:NEXTEC_ATUALIZADOR_URL) { $env:NEXTEC_ATUALIZADOR_URL } else { "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/atualizador/nextec-atualizador.ps1" }

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
$script:GuiIconeJanela = $null
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
$script:EnableColetaResolved = $false
# Bases SQLite (caminhos com curinga, separados por vírgula) medidas pela
# Coleta Complementar. SQLite não tem serviço para detectar.
$script:BancosSqlite = ""
# Hipervisores consultados pela rede pela Coleta Complementar: nome, tipo
# (vmware, proxmox, xcpng), endereco, usuario, verificar e segredo. Segredo
# nulo mantém o que já está gravado em $ColetaSegredos.
$script:Hipervisores = @()
$script:TiposHipervisor = [ordered]@{ vmware = "VMware ESXi/vCenter"; proxmox = "Proxmox VE"; xcpng = "XCP-ng" }
$script:EnableLinksResolved = $false
$script:ColetaLinks = @()

# Intervalo de sondagem dos alvos Blackbox. 60s é o padrão histórico e serve
# para "o site está no ar". Para medir disponibilidade de link, latência e
# jitter com alguma resolução, o intervalo precisa cair para 10s ou 15s.
$script:BlackboxIntervalSecondsResolved = 60
$script:BlackboxTargets = @()
$script:SnmpTargets = @()
$script:SnmpSourceFile = $null
$script:SnmpAuthBlocks = @()
$script:CustomExporters = @()
$script:UsarTela = $false
$script:RwUsername = ""
$script:RwPassword = ""
$script:LokiUsername = ""
$script:LokiPassword = ""

# ==============================================================================
# SAÍDA
# ==============================================================================

$script:LarguraConsole = 60
$script:TemaOriginal = $null

# Símbolos do conjunto WGL4, presentes nas fontes do console clássico
# (Consolas, Lucida Console) do Windows Server 2016+; caractere fora dele
# vira um quadrado no conhost.
$script:SimboloOk = [string][char]0x221A      # √
$script:SimboloBarra = [string][char]0x258C   # ▌
$script:SimboloLinha = [string][char]0x2500   # ─
$script:SimboloCursor = [string][char]0x203A  # ›

function Write-Step {
    # Título de etapa: barra e linha, como no instalador Linux.
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog "" ; Add-NextecGuiLog ("{0} {1}" -f $script:SimboloBarra, $Message) "etapa" }
    Write-Host ""
    Write-Host ("{0} {1}" -f $script:SimboloBarra, $Message) -ForegroundColor Cyan
    Write-Host ($script:SimboloLinha * $script:LarguraConsole) -ForegroundColor DarkCyan
}

function Write-Section {
    # Subtítulo dentro de uma etapa, para separar blocos de informação.
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ""; Add-NextecGuiLog ("  {0}" -f $Message) "secao" }
    Write-Host ""
    Write-Host ("  {0}" -f $Message) -ForegroundColor Cyan
}

function Get-NextecCorDoValor {
    # sim em verde, não/0 apagado, demais em branco (igual ao resumo Linux).
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '^sim\b') { return [ConsoleColor]::Green }
    if ($Value -eq "não" -or $Value -eq "0") { return [ConsoleColor]::DarkGray }
    return [ConsoleColor]::White
}

function Write-Field {
    <#
        Par rótulo/valor com colunas alinhadas. Mantém o alinhamento mesmo
        quando o rótulo tem acento, porque o padding é aplicado depois da
        formatação e conta caracteres, não bytes. Sem -ValueColor, a cor
        segue o valor (sim, não, demais).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value,
        [Nullable[ConsoleColor]]$ValueColor = $null,
        [int]$Width = 24
    )

    $cor = if ($null -ne $ValueColor) { [ConsoleColor]$ValueColor } else { Get-NextecCorDoValor -Value $Value }
    $rotulo = $Label.PadRight($Width)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("    {0}{1}" -f $rotulo, $Value) }
    Write-Host ("    {0}" -f $rotulo) -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $cor
}

function Write-Ok {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("{0}  {1}" -f $script:SimboloOk, $Message) "ok" }
    Write-Host ("{0}  " -f $script:SimboloOk) -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Info {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("i  {0}" -f $Message) "info" }
    Write-Host "i  " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("!  {0}" -f $Message) "aviso" }
    Write-Host "!  " -ForegroundColor Yellow -NoNewline
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("x  {0}" -f $Message) "falha" }
    Write-Host "x  " -ForegroundColor Red -NoNewline
    Write-Host $Message -ForegroundColor Red
}

function Write-Hint {
    # Texto de ajuda, sem símbolo: explica a próxima pergunta.
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -ne $script:GuiProgresso) { Add-NextecGuiLog ("  {0}" -f $Message) "dica" }
    Write-Host ("  {0}" -f $Message) -ForegroundColor DarkGray
}

# ==============================================================================
# JANELA DE ANDAMENTO (TELA)
# ==============================================================================
# Com a tela, o console fica escondido e o andamento aparece numa janela com o
# mesmo cabeçalho. Write-Step, Write-Ok e demais escrevem nos dois lugares.
$script:GuiProgresso = $null
$script:UsouTela = $false
$script:UsouProgresso = $false
$script:ConsoleEscondido = $false
# Título do resultado na janela de andamento quando a operação não é uma
# instalação (ex.: "Configuração atualizada"). Vazio usa o texto padrão.
$script:GuiTituloSucesso = ""
$script:GuiTituloFalha = ""
# Fechar a tela de manutenção sem escolher nada encerra sem pedir ENTER.
$script:DispensarEspera = $false
$script:GuiManutencaoEscolha = 5

function Set-NextecConsoleVisivel {
    param([bool]$Visivel)
    try {
        if (-not ("Nextec.ConsoleJanela" -as [type])) {
            Add-Type -Namespace "Nextec" -Name "ConsoleJanela" -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
'@
        }
        $janela = [Nextec.ConsoleJanela]::GetConsoleWindow()
        if ($janela -eq [IntPtr]::Zero) { return }
        if ($Visivel) {
            if ($script:ConsoleEscondido) { [void][Nextec.ConsoleJanela]::ShowWindow($janela, 5) }
            $script:ConsoleEscondido = $false
        }
        else {
            [void][Nextec.ConsoleJanela]::ShowWindow($janela, 0)
            $script:ConsoleEscondido = $true
        }
    }
    catch {
        Write-Verbose ("Não foi possível alterar a janela do console: {0}" -f $_.Exception.Message)
    }
}

function Invoke-NextecGuiEventos {
    if ($null -ne $script:GuiProgresso) { [Windows.Forms.Application]::DoEvents() }
}

function Wait-NextecSegundos {
    # Pausa que mantém a janela de andamento respondendo.
    param([double]$Segundos)
    if ($null -eq $script:GuiProgresso) { Start-Sleep -Milliseconds ([int]($Segundos * 1000)); return }
    $fim = (Get-Date).AddSeconds($Segundos)
    while ((Get-Date) -lt $fim) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
}

function Wait-NextecProcesso {
    # Espera um processo terminar sem congelar a janela de andamento.
    param([Parameter(Mandatory=$true)][Diagnostics.Process]$Processo)
    while (-not $Processo.HasExited) {
        Invoke-NextecGuiEventos
        Start-Sleep -Milliseconds 100
    }
    $Processo.WaitForExit()
}

function Add-NextecGuiLog {
    param([AllowEmptyString()][string]$Texto, [string]$Tipo = "texto")
    $gp = $script:GuiProgresso
    if ($null -eq $gp -or $gp.Form.IsDisposed) { return }
    $cor = switch ($Tipo) {
        "etapa" { $script:GuiCores.Marinho }
        "secao" { $script:GuiCores.Roxo }
        "ok" { [Drawing.Color]::FromArgb(22, 128, 60) }
        "aviso" { [Drawing.Color]::FromArgb(176, 96, 0) }
        "falha" { $script:GuiCores.Erro }
        "dica" { $script:GuiCores.Cinza }
        default { $script:GuiCores.Texto }
    }
    $log = $gp.Log
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = $cor
    $log.SelectionFont = $(if ($Tipo -eq "etapa") { $gp.FonteEtapa } else { $gp.FonteLog })
    $log.AppendText($Texto + [Environment]::NewLine)
    $log.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}

function Set-NextecGuiStatus {
    param([string]$Texto)
    if ($null -eq $script:GuiProgresso) { return }
    $script:GuiProgresso.Status.Text = $Texto
    [Windows.Forms.Application]::DoEvents()
}

function Open-NextecGuiProgresso {
    <#
        Janela de andamento: abre depois da tela de respostas, com o mesmo
        cabeçalho, e mostra tudo o que a instalação (ou a simulação) escreve.
        Só deixa fechar quando o trabalho termina.
    #>
    param([Parameter(Mandatory=$true)][object]$Inventory, [Parameter(Mandatory=$true)][string]$Titulo)

    $gp = @{ Concluido = $false }
    $form = New-Object Windows.Forms.Form
    $form.Text = "Nextec · Instalação do monitoramento"
    Set-GuiIconeJanela -Form $form
    $form.Size = New-Object Drawing.Size(900, 680)
    $form.MinimumSize = New-Object Drawing.Size(700, 480)
    $form.StartPosition = "CenterScreen"
    $form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
    $form.BackColor = [Drawing.Color]::White
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $gp.Form = $form

    $rodape = New-Object Windows.Forms.Panel
    $rodape.Dock = "Bottom"; $rodape.Height = 56; $rodape.BackColor = [Drawing.Color]::White
    # Largura final já na criação: as âncoras dos filhos são medidas a partir dela.
    $rodape.Width = 884
    $gp.Status = New-GuiLabel "" 16 18 640
    $gp.Status.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $gp.Fechar = New-GuiBotao "Fechar" 670 12 200 -Principal
    $gp.Fechar.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    $gp.Fechar.Enabled = $false
    $gp.Fechar.Add_Click({ $script:GuiProgresso.Form.Close() })
    $rodape.Controls.Add($gp.Status); $rodape.Controls.Add($gp.Fechar)

    $corpo = New-Object Windows.Forms.Panel
    $corpo.Dock = "Fill"; $corpo.BackColor = [Drawing.Color]::White
    $corpo.Padding = New-Object Windows.Forms.Padding(24, 52, 24, 8)
    $gp.Titulo = New-GuiLabel $Titulo 24 14 800 -Titulo
    $corpo.Controls.Add($gp.Titulo)
    $gp.Log = New-Object Windows.Forms.RichTextBox
    $gp.Log.Dock = "Fill"; $gp.Log.ReadOnly = $true
    $gp.Log.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $gp.Log.BackColor = [Drawing.Color]::FromArgb(250, 250, 252)
    $gp.FonteLog = New-Object Drawing.Font("Consolas", 9.5)
    $gp.FonteEtapa = New-Object Drawing.Font("Consolas", 10, [Drawing.FontStyle]::Bold)
    $gp.Log.Font = $gp.FonteLog
    $corpo.Controls.Add($gp.Log)

    $form.Controls.Add($corpo)
    $form.Controls.Add($rodape)
    $form.Controls.Add((New-GuiCabecalho -Inventory $Inventory))
    # Fechar no X durante o trabalho deixaria a instalação pela metade.
    $form.Add_FormClosing({ param($s, $e) if (-not $script:GuiProgresso.Concluido) { $e.Cancel = $true } })

    Set-GuiEscala -Controle $form
    $script:GuiProgresso = $gp
    $script:UsouProgresso = $true
    $form.Show()
    $form.Activate()
    Set-NextecGuiStatus "Em andamento..."
}

function Complete-NextecGuiProgresso {
    # Mostra o resultado, libera o botão Fechar e espera o técnico fechar.
    param([bool]$Sucesso, [string]$Titulo, [string]$Mensagem)
    $gp = $script:GuiProgresso
    if ($null -eq $gp) { return }
    if (-not $gp.Form.IsDisposed) {
        $gp.Concluido = $true
        $gp.Titulo.Text = $Titulo
        $gp.Titulo.ForeColor = $(if ($Sucesso) { [Drawing.Color]::FromArgb(22, 128, 60) } else { $script:GuiCores.Erro })
        $gp.Status.Text = $Mensagem
        $gp.Status.ForeColor = $gp.Titulo.ForeColor
        $gp.Fechar.Enabled = $true
        [void]$gp.Fechar.Focus()
        while ($gp.Form.Visible) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $gp.Form.Dispose()
    }
    $script:GuiProgresso = $null
}

function Set-NextecConsoleTheme {
    <#
        Fundo preto enquanto o instalador roda: no azul padrão do Windows
        PowerShell, ciano, cinza e verde perdem contraste e a tela fica
        "chapada". Volta às cores originais no fim (Restore-NextecConsoleTheme).
    #>
    if ($Silent -or $null -ne $script:TemaOriginal) { return }
    try {
        $ui = $Host.UI.RawUI
        $script:TemaOriginal = @{ Fundo = $ui.BackgroundColor; Texto = $ui.ForegroundColor }
        $ui.BackgroundColor = [ConsoleColor]::Black
        $ui.ForegroundColor = [ConsoleColor]::Gray
    }
    catch {
        $script:TemaOriginal = $null
    }
}

function Restore-NextecConsoleTheme {
    if ($null -eq $script:TemaOriginal) { return }
    try {
        $Host.UI.RawUI.BackgroundColor = $script:TemaOriginal.Fundo
        $Host.UI.RawUI.ForegroundColor = $script:TemaOriginal.Texto
    }
    catch {
    }
    $script:TemaOriginal = $null
}

function Get-NextecTextoTamanho {
    param([double]$Bytes)
    if ($Bytes -lt 1MB) { return ("{0:N0} KB" -f [Math]::Max(1, $Bytes / 1KB)) }
    return ("{0:N1} MB" -f ($Bytes / 1MB))
}

function Invoke-NextecDownload {
    <#
        Baixa um arquivo mostrando a porcentagem na mesma linha:
          ↓ Grafana Alloy  [████████░░░░░░░░░░░░]  41%  9,3 de 22,7 MB
        Só HTTPS: redirecionamento para fora do HTTPS é recusado. Sem console
        interativo (RMM, atualizador) não desenha a barra, só o resultado.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destino,
        [Parameter(Mandatory=$true)][string]$Descricao,
        [int]$TimeoutSec = 600
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $mostrar = (-not $Silent) -and (Test-NextecInteractiveConsole) -and ($null -eq $script:GuiProgresso)
    $seta = [string][char]0x2193
    $cheio = [string][char]0x2588
    $vazio = [string][char]0x2591

    $pedido = [Net.HttpWebRequest]::Create($Url)
    $pedido.Timeout = $TimeoutSec * 1000
    $pedido.ReadWriteTimeout = 120000
    $pedido.UserAgent = "nextec-instalador/" + $InstallerVersion
    $pedido.AllowAutoRedirect = $true

    $resposta = $null
    $entrada = $null
    $saida = $null
    try {
        $resposta = $pedido.GetResponse()
        if ($Url.StartsWith("https://") -and $resposta.ResponseUri.Scheme -ne "https") {
            throw ("Download redirecionado para fora do HTTPS: {0}" -f $resposta.ResponseUri)
        }

        $total = [double]$resposta.ContentLength
        $entrada = $resposta.GetResponseStream()
        $saida = [IO.File]::Create($Destino)
        $buffer = New-Object byte[] 65536
        $lido = [double]0
        $relogio = [Diagnostics.Stopwatch]::StartNew()

        while ($true) {
            $n = $entrada.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            $saida.Write($buffer, 0, $n)
            $lido += $n

            if ($null -ne $script:GuiProgresso -and $relogio.ElapsedMilliseconds -ge 250) {
                $relogio.Reset(); $relogio.Start()
                if ($total -gt 0) { Set-NextecGuiStatus ("Baixando {0}: {1}% ({2} de {3})" -f $Descricao, [int][Math]::Floor(100 * $lido / $total), (Get-NextecTextoTamanho $lido), (Get-NextecTextoTamanho $total)) }
                else { Set-NextecGuiStatus ("Baixando {0}: {1}" -f $Descricao, (Get-NextecTextoTamanho $lido)) }
            }

            if ($mostrar -and $relogio.ElapsedMilliseconds -ge 250) {
                $relogio.Reset(); $relogio.Start()
                if ($total -gt 0) {
                    $pct = [int][Math]::Floor(100 * $lido / $total)
                    $blocos = [int][Math]::Floor($pct / 5)
                    $texto = ("`r{0} {1}  [{2}{3}] {4,3}%  {5} de {6}   " -f $seta, $Descricao, ($cheio * $blocos), ($vazio * (20 - $blocos)), $pct, (Get-NextecTextoTamanho $lido), (Get-NextecTextoTamanho $total))
                }
                else {
                    $texto = ("`r{0} {1}  {2}   " -f $seta, $Descricao, (Get-NextecTextoTamanho $lido))
                }
                Write-Host $texto -ForegroundColor Cyan -NoNewline
            }
        }
    }
    finally {
        if ($null -ne $saida) { $saida.Dispose() }
        if ($null -ne $entrada) { $entrada.Dispose() }
        if ($null -ne $resposta) { $resposta.Close() }
        if ($mostrar) {
            # Limpa a linha da barra antes da próxima mensagem.
            Write-Host ("`r{0}`r" -f (" " * 78)) -NoNewline
        }
    }

    Write-Ok ("{0}: {1} baixados." -f $Descricao, (Get-NextecTextoTamanho (Get-Item -LiteralPath $Destino).Length))
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
    Set-NextecConsoleTheme

    try {
        Clear-Host
    }
    catch {
    }

    $logo = @(
        " _   _ _______  _______ _____ ____",
        "| \ | | ____\ \/ /_   _| ____/ ___|",
        "|  \| |  _|  \  /  | | |  _|| |",
        "| |\  | |___ /  \  | | | |__| |___",
        "|_| \_|_____/_/\_\ |_| |_____\____|"
    )
    foreach ($linhaLogo in $logo) {
        Write-Host $linhaLogo -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "NOC Monitoring Installer, Windows" -ForegroundColor White -NoNewline
    Write-Host ("  v{0}" -f $InstallerVersion) -ForegroundColor Gray
    if (-not [string]::IsNullOrEmpty($script:NocHost)) {
        Write-Host "Destino: " -NoNewline
        Write-Host $script:NocHost -ForegroundColor Cyan
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

    # A sessão elevada nasce do serviço AppInfo, sem as variáveis deste
    # processo: as URLs de teste (branch) precisam ir no próprio comando.
    $ambiente = ""
    foreach ($nome in @("NEXTEC_COLETA_URL", "NEXTEC_ATUALIZADOR_URL")) {
        $valor = [Environment]::GetEnvironmentVariable($nome, "Process")
        if (-not [string]::IsNullOrWhiteSpace($valor)) {
            if ($valor -notmatch '^https://[^\s''"`]+$') {
                throw ("{0} precisa ser uma URL https sem espaços nem aspas." -f $nome)
            }
            $ambiente += ("`$env:{0} = '{1}'" -f $nome, $valor) + [Environment]::NewLine
        }
    }

    $comando = @"
`$ErrorActionPreference = 'Continue'
$ambiente
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

function ConvertTo-ClienteSlug {
    # O rótulo cliente só aceita minúsculas, números e _ (padrão de labels):
    # hífen vira _ para "grupo-alves-de-faria" virar "grupo_alves_de_faria".
    param([Parameter(Mandatory=$true)][string]$Value)

    $slug = (ConvertTo-Slug $Value) -replace "-", "_"
    $slug = $slug -replace "_+", "_"
    return $slug.Trim("_")
}

# -----------------------------------------------------------------------------
# VALIDAÇÃO DE ENTRADAS
# Toda resposta digitada passa por aqui: valor inválido gera aviso e a pergunta
# é repetida. O instalador nunca encerra por erro de digitação.
# -----------------------------------------------------------------------------
function Test-NextecIPv4 {
    param([string]$Value)
    if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) {
        if ([int]$Matches[$i] -gt 255) { return $false }
    }
    return $true
}

function Test-NextecHost {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if (Test-NextecIPv4 $Value) { return $true }
    # Só números e pontos precisa ser um IP válido ("1.2.3" não é host).
    if ($Value -notmatch '[A-Za-z]') { return $false }
    return ($Value.Length -le 253 -and $Value -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$')
}

function Test-NextecPort {
    param([string]$Value)
    $port = 0
    return ($Value -match '^\d{1,5}$' -and [int]::TryParse($Value, [ref]$port) -and $port -ge 1 -and $port -le 65535)
}

function Test-NextecHostPort {
    param([string]$Value)
    $i = $Value.LastIndexOf(":")
    if ($i -lt 1) { return $false }
    return ((Test-NextecHost $Value.Substring(0, $i)) -and (Test-NextecPort $Value.Substring($i + 1)))
}

function Test-NextecDestino {
    # Destino de sonda: URL http(s), host/IP ou host:porta.
    param([string]$Value)
    if ($Value -match '^https?://([^/:?#]+)(:(\d+))?([/?#].*)?$') {
        $urlHost = $Matches[1]
        $urlPorta = $Matches[3]
        if (-not (Test-NextecHost $urlHost)) { return $false }
        return ([string]::IsNullOrEmpty($urlPorta) -or (Test-NextecPort $urlPorta))
    }
    return ((Test-NextecHost $Value) -or (Test-NextecHostPort $Value))
}

function Test-NextecAddress {
    param([string]$Value, [string]$Kind)
    switch ($Kind) {
        "ip"       { return (Test-NextecIPv4 $Value) }
        "host"     { return (Test-NextecHost $Value) }
        "hostport" { return (Test-NextecHostPort $Value) }
        "destino"  { return (Test-NextecDestino $Value) }
    }
    return $false
}

function Get-NextecAddressExample {
    param([string]$Kind)
    switch ($Kind) {
        "ip"       { return "ex.: 192.168.0.1" }
        "host"     { return "ex.: 192.168.0.1 ou fw.cliente.com.br" }
        "hostport" { return "ex.: 127.0.0.1:9182" }
        "destino"  { return "ex.: 192.168.0.1, cliente.com.br, https://cliente.com.br ou 10.0.0.5:3389" }
    }
    return ""
}

function Read-NextecAddress {
    # Kind: ip, host, hostport ou destino. -List aceita vários separados por vírgula.
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = "",
        [Parameter(Mandatory=$true)][ValidateSet("ip","host","hostport","destino")][string]$Kind,
        [switch]$Optional,
        [switch]$List
    )

    while ($true) {
        if ($Optional) {
            $value = Read-NextecInput -Prompt $Prompt -Hint "ENTER para pular"
            if ([string]::IsNullOrWhiteSpace($value)) { return "" }
            $value = $value.Trim()
        }
        else {
            $value = Read-Required -Prompt $Prompt -Default $Default
        }

        if ($List) {
            $itens = @($value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
            $invalidos = @($itens | Where-Object { -not (Test-NextecAddress -Value $_ -Kind $Kind) })
            if ($itens.Count -gt 0 -and $invalidos.Count -eq 0) {
                return ($itens -join ", ")
            }
            Write-Warn ("Endereço inválido: {0}. Use {1}, separados por vírgula." -f ($(if ($invalidos.Count) { $invalidos -join ", " } else { "vazio" })), (Get-NextecAddressExample $Kind))
        }
        else {
            if (Test-NextecAddress -Value $value -Kind $Kind) {
                return $value
            }
            Write-Warn ("Endereço inválido: {0}. Use {1}." -f $value, (Get-NextecAddressExample $Kind))
        }
    }
}

function Read-NextecSlug {
    # Kind cliente/label: minúsculas, números e _ (hífen e espaço viram _).
    # Kind host: igual, mas mantém hífen (hostnames reais usam hífen).
    # -AllowKeep: ENTER devolve "" para o chamador manter o valor atual.
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = "",
        [ValidateSet("cliente","label","host")][string]$Kind = "label",
        [switch]$AllowKeep
    )

    while ($true) {
        if ($AllowKeep) {
            $raw = Read-NextecInput -Prompt $Prompt -Hint "ENTER mantém"
            if ([string]::IsNullOrWhiteSpace($raw)) { return "" }
            $raw = $raw.Trim()
        }
        else {
            $raw = Read-Required -Prompt $Prompt -Default $Default
        }

        $slug = if ($Kind -eq "host") { ConvertTo-Slug $raw } else { ConvertTo-ClienteSlug $raw }

        if (-not [string]::IsNullOrWhiteSpace($slug) -and $slug -match '^[a-z0-9][a-z0-9_-]*$') {
            if ($slug -cne $raw) {
                Write-Info ("Será registrado como: {0}" -f $slug)
            }
            return $slug
        }

        Write-Warn ("Valor inválido: {0}. Use letras e números (acentos, espaços e símbolos são convertidos)." -f $raw)
    }
}

function Read-NextecPattern {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = "",
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][string]$Hint,
        [switch]$Optional
    )

    while ($true) {
        if ($Optional) {
            $value = Read-NextecInput -Prompt $Prompt -Hint "ENTER para pular"
            if ([string]::IsNullOrWhiteSpace($value)) { return "" }
            $value = $value.Trim()
        }
        else {
            $value = Read-Required -Prompt $Prompt -Default $Default
        }
        if ($value -match $Pattern) { return $value }
        Write-Warn ("Valor inválido: {0}. Use {1}." -f $value, $Hint)
    }
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

function Show-NextecConsoleParaPergunta {
    # Pergunta no console com a janela de andamento aberta: o console volta a
    # aparecer, senão a instalação ficaria parada esperando uma resposta que
    # ninguém vê.
    if ($null -eq $script:GuiProgresso -or -not $script:ConsoleEscondido) { return }
    Add-NextecGuiLog "!  Há uma pergunta na janela do console. Responda lá para continuar." "aviso"
    Set-NextecConsoleVisivel $true
}

function Read-NextecInput {
    <#
        Pergunta com hierarquia visual: "?" em ciano, texto em branco, dica e
        valor padrão em cinza. Read-Host sem -Prompt não imprime nada, então
        o texto colorido montado aqui é o único que aparece.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = "",
        [string]$Hint = "",
        [switch]$AsSecureString
    )

    Write-Host "? " -ForegroundColor Cyan -NoNewline
    Write-Host $Prompt -ForegroundColor White -NoNewline
    if ($Hint) { Write-Host (" ({0})" -f $Hint) -ForegroundColor DarkGray -NoNewline }
    if ($Default) { Write-Host (" [{0}]" -f $Default) -ForegroundColor DarkGray -NoNewline }
    Write-Host ": " -NoNewline

    Show-NextecConsoleParaPergunta
    if ($AsSecureString) { return (Read-Host -AsSecureString) }
    return (Read-Host)
}

function Read-Required {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = ""
    )

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Default)) {
            $value = Read-NextecInput -Prompt $Prompt
        }
        else {
            $value = Read-NextecInput -Prompt $Prompt -Default $Default
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $Default
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
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
        $answer = Read-NextecInput -Prompt $Prompt -Hint ($suffix.Trim("[]"))

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            "s"   { return $true }
            "sim" { return $true }
            "y"   { return $true }
            "yes" { return $true }
            "n"   { return $false }
            "nao" { return $false }
            "não" { return $false }
            "no"  { return $false }
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

    # Igual ao instalador Linux: número em ciano, "›" marca o padrão e
    # ENTER escolhe o padrão.
    Write-Host "? " -ForegroundColor Cyan -NoNewline
    Write-Host $Prompt -ForegroundColor White -NoNewline
    Write-Host (" [ENTER = {0}]" -f $Default) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marca = if (($i + 1) -eq $Default) { $script:SimboloCursor } else { " " }
        Write-Host ("  {0}{1,2}  " -f $marca, ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host $Options[$i]
    }

    while ($true) {
        Write-Host ("{0} " -f $script:SimboloCursor) -ForegroundColor Cyan -NoNewline
        Show-NextecConsoleParaPergunta
        $choiceText = Read-Host

        if ([string]::IsNullOrWhiteSpace($choiceText)) {
            return $Default
        }

        $number = 0
        if ([int]::TryParse($choiceText.Trim(), [ref]$number)) {
            if ($number -ge 1 -and $number -le $Options.Count) {
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
            $secureValue = Read-NextecInput -Prompt $Prompt -AsSecureString
            $plainValue = Convert-SecureStringToPlainText -SecureValue $secureValue
        }
        else {
            Write-Warn "Console sem suporte a entrada mascarada (ex.: ISE); a senha ficará visível ao digitar."
            $plainValue = Read-NextecInput -Prompt $Prompt
        }

        if ([string]::IsNullOrWhiteSpace($plainValue)) {
            Write-Warn "Campo obrigatório."
            continue
        }

        if ($plainValue -match "[`r`n]") {
            Write-Warn "A credencial não pode conter quebra de linha."
            continue
        }

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

    if (-not $Silent -and -not $script:UsarTela) {
        # O banner já mostra o destino: aqui só a confirmação.
        $action = Read-NextecInput -Prompt "Destino do monitoramento" -Hint "ENTER mantém, D altera" -Default $script:NocHost

        if ($action.Trim().ToLowerInvariant() -eq "d") {
            while ($true) {
                $inputHost = Read-NextecInput -Prompt "Novo destino"
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

        $linha = [string](($result.Output -split "`r?`n") | Select-Object -First 1)
        $m = [Regex]::Match($linha, '\d+\.\d+\.\d+')
        if ($m.Success) { return $m.Value }
        return $linha
    }
    catch {
        return $null
    }
}

function Get-NextecEstadoServico {
    param([AllowNull()][object]$Servico)
    if ($null -eq $Servico) { return "não encontrado" }
    switch ([string]$Servico.Status) {
        "Running" { return "ativo" }
        "StartPending" { return "iniciando" }
        "Stopped" { return "parado" }
        default { return [string]$Servico.Status }
    }
}

function Show-MaintenanceStatus {
    foreach ($linha in @(Get-MaintenanceStatusRows)) {
        Write-Field -Label $linha.Rotulo -Value $linha.Valor -ValueColor $linha.Cor
    }
    Write-Host ""
}

function Get-MaintenanceStatusRows {
    # Mesmo quadro do instalador Linux: versões e estado de cada parte. Cada
    # linha traz rótulo, valor e cor; o console e a tela mostram a mesma lista.
    $service = Get-AlloyService
    $version = Get-AlloyInstalledVersion
    $configExists = Test-Path -LiteralPath $ConfigFile

    # Versões lidas do texto dos arquivos (nada é executado).
    $conteudoConfig = ""
    if ($configExists) {
        try { $conteudoConfig = [IO.File]::ReadAllText($ConfigFile) } catch { $conteudoConfig = "" }
    }
    $cabecalho = { param($chave)
        $m = [Regex]::Match($conteudoConfig, ('(?m)^\s*//\s*nextec:{0}\s*=\s*(\S+)' -f $chave))
        if ($m.Success) { $m.Groups[1].Value } else { "" }
    }
    $versaoConfig = & $cabecalho "versao"
    $cliente = & $cabecalho "cliente"
    $hostLabel = & $cabecalho "host"
    $versaoColeta = Get-VersaoNoArquivo -Caminho $ColetaScript -Padrao '(?m)^\$Versao\s*=\s*"([^"]+)"'
    $versaoAtualizador = Get-VersaoNoArquivo -Caminho $AtualizadorScript -Padrao '(?m)^\$script:Versao\s*=\s*"([^"]+)"'

    $instaladoCom = if ($versaoConfig) { "v$versaoConfig" } elseif ($configExists) { "versão anterior à 2.12 (não identificada)" } else { "sem configuração" }
    $alloy = if ([string]::IsNullOrWhiteSpace($version)) { "versão não identificada" } else { $version }

    $coleta = "não instalada"
    if ($versaoColeta) {
        $tarefaColeta = Get-ScheduledTask -TaskName $ColetaTaskName -ErrorAction SilentlyContinue
        $coleta = if ($null -ne $tarefaColeta) { "$versaoColeta (ligada)" } else { "$versaoColeta (tarefa ausente)" }
    }
    $atualizador = "não instalado"
    if ($versaoAtualizador) {
        $tarefa = Get-ScheduledTask -TaskName $AtualizadorTaskName -ErrorAction SilentlyContinue
        $atualizador = if ($null -ne $tarefa) { "$versaoAtualizador (ligado)" } else { "$versaoAtualizador (tarefa ausente)" }
    }

    $linhas = New-Object System.Collections.Generic.List[object]
    $add = { param([string]$Rotulo, [string]$Valor, [ConsoleColor]$Cor) [void]$linhas.Add([pscustomobject]@{ Rotulo = $Rotulo; Valor = $Valor; Cor = $Cor }) }
    & $add "Este instalador" ("v{0}" -f $InstallerVersion) White
    & $add "Instalado com" $instaladoCom White
    if ($cliente) { & $add "Cliente" $cliente White }
    if ($hostLabel) { & $add "Host" $hostLabel White }
    & $add "Grafana Alloy" ("{0} ({1})" -f $alloy, (Get-NextecEstadoServico -Servico $service)) White
    & $add "Coleta Complementar" $coleta $(if ($versaoColeta) { [ConsoleColor]::White } else { [ConsoleColor]::DarkGray })
    & $add "Atualizador" $atualizador $(if ($versaoAtualizador) { [ConsoleColor]::White } else { [ConsoleColor]::Yellow })
    & $add "Pacote Nextec aplicado" (Get-NextecPacoteAplicado) White
    if ($configExists) {
        $atual = $null
        try { $atual = Read-CurrentAlloyConfiguration } catch { $atual = $null }
        if ($null -ne $atual) {
            $ligadas = @()
            if ($atual.MonitorHost) { $ligadas += $(if ($atual.TipoLabel -eq "estacao") { "estação" } else { "servidor" }) }
            if ($atual.EnableLogs) { $ligadas += "logs" }
            if ($atual.EnableSecurity) { $ligadas += "segurança" }
            if (@($atual.BlackboxTargets).Count -gt 0) { $ligadas += "conectividade" }
            if (@($atual.SnmpTargets).Count -gt 0) { $ligadas += "snmp" }
            if (@($atual.CustomExporters).Count -gt 0) { $ligadas += "exporters" }
            if ($atual.EnableInternet) { $ligadas += "velocidade" }
            if ($atual.EnableColeta) { $ligadas += "internet e links" }
            if ($atual.BancosColeta) { $ligadas += ("bancos ({0})" -f $atual.BancosColeta) }
            if (@($atual.Hipervisores).Count -gt 0) { $ligadas += ("hipervisores pela rede ({0})" -f (@($atual.Hipervisores | ForEach-Object { $_.nome }) -join ", ")) }
            & $add "Coletas ligadas" $(if ($ligadas.Count -gt 0) { $ligadas -join ", " } else { "nenhuma" }) White
        }
    }
    & $add "Configuração" $(if ($configExists) { $ConfigFile } else { "não encontrada" }) Gray
    return $linhas.ToArray()
}

function Get-NextecPacoteAplicado {
    # Versão publicada pela Nextec que o atualizador aplicou neste host.
    $estado = Join-Path $AtualizadorDir "estado.json"
    if (-not (Test-Path -LiteralPath $estado -PathType Leaf)) { return "nenhum" }
    try {
        $obj = [IO.File]::ReadAllText($estado) | ConvertFrom-Json
        if ($obj.PSObject.Properties.Name -contains "versao_instalada" -and $obj.versao_instalada) { return [string]$obj.versao_instalada }
        return "nenhum"
    }
    catch {
        return "não identificada"
    }
}

function Read-LokiCredentials {
    <#
        Pede só a credencial do Loki, como o instalador Linux, quando logs ou a
        Coleta são ligados num host que ainda não envia para o Loki. A do
        remote_write continua a gravada.
    #>
    Write-Info "Este host ainda não envia logs e eventos e não tem credencial do Loki."
    if (-not [string]::IsNullOrWhiteSpace($script:RwUsername) -and
        (Read-YesNo -Prompt "Usar a mesma credencial do remote_write no Loki?" -Default $true)) {
        $script:LokiUsername = $script:RwUsername
        $script:LokiPassword = $script:RwPassword
        return
    }
    $script:LokiUsername = Read-Required "Usuário do Loki"
    $script:LokiPassword = Read-RequiredSecret "Senha do Loki"
}

function Get-VersaoNoArquivo {
    param(
        [string]$Caminho,
        [string]$Padrao
    )

    if ([string]::IsNullOrEmpty($Caminho) -or -not (Test-Path -LiteralPath $Caminho -PathType Leaf)) {
        return ""
    }

    try {
        $m = [Regex]::Match([IO.File]::ReadAllText($Caminho), $Padrao)
        if ($m.Success) {
            return $m.Groups[1].Value
        }
    }
    catch {
    }

    return ""
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

    # Speedtest ligado: seção [velocidade] da Coleta ou, em instalação
    # anterior à 2.21, o coletor textfile no exporter "system", a tarefa
    # NextecSpeedtest ou o serviço antigo. O intervalo vem do .ini ou do
    # gatilho da tarefa.
    $enableInternet = ($collectors -contains "textfile") -or (Test-NextecSpeedtestLegado)
    $internetIntervalMinutes = 30

    # A Coleta pode rodar só pelos bancos: a internet conta como ligada quando
    # o .ini não diz "ativo = nao" ou quando há link cadastrado.
    $enableColeta = ($content -match 'prometheus\.exporter\.windows\s+"coleta_complementar"')
    $bancosSqlite = ""
    $iniColeta = Read-ColetaIniFile -Caminho $ColetaConfig
    if ($enableColeta -and $iniColeta.Contains("internet") -and $iniColeta["internet"].Contains("ativo") -and
        [string]$iniColeta["internet"]["ativo"] -match '^(nao|não|n|0|false)$' -and
        @($iniColeta.Keys | Where-Object { $_ -like "link:*" }).Count -eq 0) {
        $enableColeta = $false
    }
    $bancosColeta = ""
    if ($iniColeta.Contains("bancos") -and $iniColeta["bancos"].Contains("motores") -and
        -not ([string]$iniColeta["bancos"]["ativo"] -match '^(nao|não|n|0|false)$')) {
        $bancosColeta = (@(([string]$iniColeta["bancos"]["motores"]) -split "," | ForEach-Object { $_.Trim() } |
            Where-Object { $_ }) -join ", ")
    }
    $hipervisores = @()
    foreach ($nomeSecao in @($iniColeta.Keys)) {
        if ([string]$nomeSecao -notmatch '^hipervisor:(.+)$') { continue }
        $nomeHv = $Matches[1].Trim()
        $secaoHv = $iniColeta[$nomeSecao]
        $tipoHv = if ($secaoHv.Contains("tipo")) { ([string]$secaoHv["tipo"]).Trim().ToLowerInvariant() -replace '^(xcp-ng|xenserver)$', 'xcpng' } else { "" }
        if (-not $script:TiposHipervisor.Contains($tipoHv)) { continue }
        $hipervisores += [pscustomobject]@{
            nome = $nomeHv; tipo = $tipoHv
            endereco = $(if ($secaoHv.Contains("endereco")) { [string]$secaoHv["endereco"] } else { "" })
            usuario = $(if ($secaoHv.Contains("usuario")) { [string]$secaoHv["usuario"] } else { "" })
            verificar = ($secaoHv.Contains("verificar_certificado") -and [string]$secaoHv["verificar_certificado"] -match '^(sim|s|1|true)$')
            segredo = $null
        }
    }
    if ($iniColeta.Contains("bancos") -and $iniColeta["bancos"].Contains("arquivos")) {
        $bancosSqlite = (@(([string]$iniColeta["bancos"]["arquivos"]) -split "," | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -like "sqlite:*" } | ForEach-Object { $_.Substring(7) }) -join ", ")
    }

    if ($iniColeta.Contains("velocidade") -and [string]$iniColeta["velocidade"]["ativo"] -match '^(sim|s|1|true|ligado)$') {
        $enableInternet = $true
        $minutos = 0
        if ([int]::TryParse([string]$iniColeta["velocidade"]["intervalo_minutos"], [ref]$minutos) -and $minutos -gt 0) {
            $internetIntervalMinutes = $minutos
        }
    }
    elseif ($enableInternet) {
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
        MonitorHost              = (-not [string]::IsNullOrWhiteSpace($exporter)) -and @($collectors | Where-Object { $_ -ne "textfile" }).Count -gt 0
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
        EnableColeta             = $enableColeta
        BancosSqlite             = $bancosSqlite
        BancosColeta             = $bancosColeta
        Hipervisores             = $hipervisores
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

    if ($c.EnableColeta) {
        $linksAtuais = @(Get-ColetaLinksFromIni)
        $textoLinks = if ($linksAtuais.Count -gt 0) { ($linksAtuais | ForEach-Object { $_.nome }) -join ", " } else { "nenhum link cadastrado" }
        Write-Field -Label "Coleta Complementar" -Value ("internet; links: {0}" -f $textoLinks)
    }
    else {
        Write-Field -Label "Coleta Complementar" -Value "desligada" -ValueColor DarkGray
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
    $script:EnableColetaResolved       = [bool]$c.EnableColeta
    $script:BancosSqlite               = [string]$c.BancosSqlite
    $script:Hipervisores               = @($c.Hipervisores)
    if ($script:EnableColetaResolved) { Import-ColetaLinks }
    $script:EnableLinksResolved        = ($script:ColetaLinks.Count -gt 0)

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

function Get-NextecComponentesPendentes {
    # Componentes que a configuração atual pede e que não estão instalados.
    $faltando = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $AtualizadorScript) -or -not (Get-ScheduledTask -TaskName $AtualizadorTaskName -ErrorAction SilentlyContinue)) {
        $faltando.Add("atualizador automático")
    }
    if ((Test-NextecColetaNecessaria) -and (-not (Test-Path -LiteralPath $ColetaScript) -or -not (Get-ScheduledTask -TaskName $ColetaTaskName -ErrorAction SilentlyContinue))) {
        $faltando.Add("Coleta Complementar")
    }
    return $faltando.ToArray()
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
    Install-ColetaComplementar
    New-AlloyConfiguration -Inventory $Inventory
    Format-AndValidateAlloyConfiguration
    Restart-AlloyService
    Test-AlloyReadiness
    Remove-NextecSpeedtestLegado
    Write-Ok "Configuração atualizada."
}

function Edit-IdentificationSettings {
    Write-Step "Identificação"

    Write-Info ("Cliente atual: {0}" -f $script:Cliente)
    $slug = Read-NextecSlug -Prompt "Novo cliente" -Kind cliente -AllowKeep
    if ($slug) { $script:Cliente = $slug }

    Write-Info ("Local atual: {0}" -f $script:Local)
    # Read-NextecSlug repete a pergunta quando a entrada vira vazio na
    # normalização (ex.: "###"), para o host nunca chegar ao NOC sem local.
    $slugLocal = Read-NextecSlug -Prompt "Novo local" -Kind label -AllowKeep
    if ($slugLocal) { $script:Local = $slugLocal }

    $ambientes = @("producao","homologacao","desenvolvimento","backup","teste")
    $indiceAmbiente = [Array]::IndexOf($ambientes, $script:Ambiente)
    if ($indiceAmbiente -lt 0) { $indiceAmbiente = 0 }
    $script:Ambiente = $ambientes[(Read-Choice -Prompt "Ambiente" -Options $ambientes -Default ($indiceAmbiente + 1)) - 1]

    $criticidades = @("critico","alto","medio","baixo")
    $indiceCriticidade = [Array]::IndexOf($criticidades, $script:Criticidade)
    if ($indiceCriticidade -lt 0) { $indiceCriticidade = 1 }
    $script:Criticidade = $criticidades[(Read-Choice -Prompt "Criticidade" -Options $criticidades -Default ($indiceCriticidade + 1)) - 1]

    Write-Info ("Host atual: {0}" -f $script:HostLabel)
    $slugHost = Read-NextecSlug -Prompt "Novo nome do host" -Kind host -AllowKeep
    if ($slugHost) { $script:HostLabel = $slugHost }
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
    if ((Test-NextecNeedsLoki) -and
        [string]::IsNullOrWhiteSpace($script:LokiUsername)) {
        Read-LokiCredentials
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
            $texto = Read-NextecInput -Prompt "Intervalo em segundos" -Default $script:BlackboxIntervalSecondsResolved

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
        $intervaloTexto = Read-NextecInput -Prompt "Intervalo em minutos entre execuções" -Default $script:InternetIntervalMinutesResolved

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
        [void]$opcoes.Add("Internet e links (Coleta Complementar)")
        [void]$opcoes.Add("Hipervisores (virtualização)")
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
            "Internet e links (Coleta Complementar)" { Edit-ColetaSettings; $alterou = $true }
            "Hipervisores (virtualização)" { Edit-HipervisoresSettings; $alterou = $true }
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
                # Mesmo sem alteração, grava quando falta componente (ex.: o
                # atualizador ou a Coleta não baixaram na instalação).
                $pendentes = @(Get-NextecComponentesPendentes)
                if (-not $alterou -and $pendentes.Count -eq 0) {
                    Write-Info "Nada foi alterado."
                    return
                }
                if (-not $alterou) {
                    Write-Info ("Nada foi alterado, mas falta instalar: {0}. Aplicando a configuração atual." -f ($pendentes -join ", "))
                }

                Save-ReconfiguredAlloy -Inventory $inventory
                Invoke-NextecOptionalStep -Nome "Atualizador automático" -Acao {
                    Install-Atualizador
                } | Out-Null
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

    # Com área de trabalho, o estado e as opções aparecem numa janela, com a
    # mesma numeração do menu do console.
    $inventarioTela = $null
    if ($script:UsarTela) {
        $inventarioTela = Get-WindowsInventory
        $choice = Show-NextecGuiManutencao -Inventory $inventarioTela
    }
    else {
        Show-MaintenanceStatus

        $options = @(
            "Ver e alterar a configuração atual",
            "Reconfigurar tudo, fluxo completo (identificação, recursos, credenciais)",
            "Atualizar o Grafana Alloy, mantendo a configuração",
            "Validar a configuração e reiniciar os serviços",
            "Cancelar"
        )

        # O default é "Cancelar": as outras opções alteram ou reiniciam o
        # serviço em um servidor de produção, e ENTER não deve disparar isso.
        $choice = Read-Choice -Prompt "O que deseja fazer?" -Options $options -Default 5
    }

    switch ($choice) {
        1 {
            if ($script:UsarTela) { Invoke-NextecConfiguracaoGui }
            else { Invoke-ConfigurationMenu }
            return $false
        }
        2 {
            return $true
        }
        3 {
            if ($script:UsarTela) {
                Open-NextecGuiProgresso -Inventory $inventarioTela -Titulo "Atualizando o Grafana Alloy"
                $script:GuiTituloSucesso = "Grafana Alloy atualizado"
                $script:GuiTituloFalha = "A atualização do Alloy falhou"
            }
            # ConfigChanged fica falso: esta opção não gera configuração nova,
            # e marcá-la faria o rollback remover a config existente.
            Backup-ExistingConfiguration
            Update-AlloyBinaryOnly
            Write-Ok "Binário do Alloy atualizado/reinstalado, configuração mantida."
            return $false
        }
        4 {
            if ($script:UsarTela) {
                Open-NextecGuiProgresso -Inventory $inventarioTela -Titulo "Validando e reiniciando"
                $script:GuiTituloSucesso = "Configuração validada e serviço reiniciado"
                $script:GuiTituloFalha = "A validação falhou"
            }
            Backup-ExistingConfiguration
            Format-AndValidateAlloyConfiguration
            Restart-AlloyService
            Test-AlloyReadiness -Mandatory $false
            Write-Ok "Manutenção concluída."
            return $false
        }
        5 {
            if ($script:UsarTela) {
                Write-Info "Janela fechada sem alterar nada."
                $script:DispensarEspera = $true
                return $false
            }
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


function Get-OracleDetection {
    # Instância Oracle: serviço OracleService<SID> ou processo oracle.exe.
    $services = @(Get-Service -Name "OracleService*" -ErrorAction SilentlyContinue)
    $processes = @(Get-Process -Name "oracle" -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Detected  = ($services.Count -gt 0 -or $processes.Count -gt 0)
        Instances = @($services | ForEach-Object { $_.Name -replace '^OracleService', '' })
    }
}

function Get-SqlAnywhereDetection {
    # SAP SQL Anywhere (antigo Sybase), usado por sistemas como o Domínio:
    # servidor dbsrvNN.exe ou dbengNN.exe, como serviço ou processo.
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(dbsrv|dbeng)\d+$' })
    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match '(?i)\\(dbsrv|dbeng)\d+\.exe' })
    [pscustomobject]@{
        Detected = ($services.Count -gt 0 -or $processes.Count -gt 0)
        Services = @($services | ForEach-Object { $_.Name })
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
                    $features.Add([pscustomobject]@{ Key="hyper_v"; Label="Hyper-V (VMs, checkpoints, replicação e armazenamento)"; Collectors=@("hyperv"); Selected=$true })
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

    # Firebird, Oracle e SQL Anywhere: no ar, conexões, memória e tamanho
    # das bases pela Coleta Complementar (módulo bancos), sem credencial; o
    # coletor "process" do Alloy acrescenta CPU e handles dos processos.
    if ($Firebird.Detected) {
        $features.Add([pscustomobject]@{ Key="firebird"; Label="Firebird (no ar, conexões e tamanho das bases)"; Collectors=@("process"); Selected=$true })
    }
    if ((Get-OracleDetection).Detected) {
        $features.Add([pscustomobject]@{ Key="oracle"; Label="Oracle (no ar, conexões e memória)"; Collectors=@("process"); Selected=$true })
    }
    if ((Get-SqlAnywhereDetection).Detected) {
        $features.Add([pscustomobject]@{ Key="sqlanywhere"; Label="SQL Anywhere (no ar, conexões e tamanho das bases)"; Collectors=@("process"); Selected=$true })
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
            Write-Host $Title -ForegroundColor White
            Write-Host "Setas navegam, ESPAÇO abre/fecha categorias e marca/desmarca, ENTER confirma." -ForegroundColor Gray
            Write-Host ""

            for ($vi = 0; $vi -lt $visibleIndexes.Count; $vi++) {
                $item = $Items[$visibleIndexes[$vi]]
                $indent = "  " * [int]$item.Depth
                $prefix = if ($vi -eq $cursor) { [string][char]0x00BB } else { " " }

                if ([bool]$item.HasChildren) {
                    $arrow = if ([bool]$item.Expanded) { [string][char]0x25BC } else { [string][char]0x25BA }
                    $line = ("{0} {1}{2} {3}" -f $prefix, $indent, $arrow, $item.Label)
                }
                else {
                    $mark = if ($item.Selected) { $script:SimboloOk } else { " " }
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
                $cor = if ($item.Selected) { [ConsoleColor]::Green } else { [ConsoleColor]::Gray }
                Write-Host ("  {0}[{1}] {2}. {3}" -f $indent, $mark, ($vi + 1), $item.Label) -ForegroundColor $cor
            }
        }

        $inputValue = Read-NextecInput -Prompt "Números para marcar/desmarcar/expandir, separados por espaço" -Hint "ENTER confirma"

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
        [pscustomobject]@{ Key = "redis_exporter";         Label = "Redis";                                    DefaultTarget = "127.0.0.1:9121";  DefaultService = "redis" }
        [pscustomobject]@{ Key = "nginx_exporter";         Label = "Nginx";                                    DefaultTarget = "127.0.0.1:9113";  DefaultService = "nginx" }
        [pscustomobject]@{ Key = "apache_exporter";        Label = "Apache";                                   DefaultTarget = "127.0.0.1:9117";  DefaultService = "apache" }
        [pscustomobject]@{ Key = "rabbitmq_prometheus";    Label = "RabbitMQ";                                 DefaultTarget = "127.0.0.1:15692"; DefaultService = "rabbitmq" }
        [pscustomobject]@{ Key = "elasticsearch_exporter"; Label = "Elasticsearch";                            DefaultTarget = "127.0.0.1:9114";  DefaultService = "elasticsearch" }
        [pscustomobject]@{ Key = "mongodb_exporter";       Label = "MongoDB";                                  DefaultTarget = "127.0.0.1:9216";  DefaultService = "mongodb" }
        [pscustomobject]@{ Key = "nvidia_dcgm_exporter";   Label = "GPU NVIDIA (DCGM)";                        DefaultTarget = "127.0.0.1:9400";  DefaultService = "gpu" }
        [pscustomobject]@{ Key = "custom";                 Label = "Outro serviço com métricas Prometheus";    DefaultTarget = "";                 DefaultService = "" }
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
    $script:EnableColetaResolved = $EnableColeta.IsPresent
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

    # Coleta Complementar: vale para qualquer modo. Internet vem marcada por
    # padrão na instalação interativa; links só quando o local tem mais de um.
    $padraoColeta = $script:EnableColetaResolved -or (-not $Silent)
    $items.Add((New-NextecChecklistItem -Key "coleta" -Label "Internet e links: status, DNS, IP público e causa das quedas" -Selected $padraoColeta))

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
    $script:EnableColetaResolved = ($selectedKeys -contains "coleta")

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

    # SQLite não tem serviço para detectar: o técnico informa as bases.
    if ($script:MonitorHost -and -not $Silent) {
        while ($true) {
            $resposta = Read-NextecInput -Prompt "Bases SQLite para medir" -Hint "opcional, ex.: C:\Sistema\dados\*.db" -Default $script:BancosSqlite
            if ([string]::IsNullOrWhiteSpace($resposta)) { $resposta = $script:BancosSqlite }
            if (Test-NextecCaminhosSqlite $resposta) { $script:BancosSqlite = ([string]$resposta).Trim(); break }
            Write-Warn "Use caminhos completos separados por vírgula (C:\... ou \\servidor\...)."
        }
    }

    # Hipervisores pela rede: ESXi não aceita agente, e Proxmox ou XCP-ng de
    # outro servidor podem ser lidos daqui com um usuário só leitura.
    if (-not $Silent) {
        $padraoHv = (@($script:Hipervisores).Count -gt 0)
        if (Read-YesNo -Prompt "Consultar hipervisores pela rede (VMware ESXi/vCenter, Proxmox, XCP-ng)?" -Default $padraoHv) {
            if (@($script:Hipervisores).Count -gt 0) { Edit-HipervisoresSettings }
            else {
                do {
                    $novo = Read-NextecHipervisor
                    $script:Hipervisores = @(@($script:Hipervisores | Where-Object { $_.nome -ne $novo.nome }) + $novo)
                } while (Read-YesNo -Prompt "Cadastrar outro hipervisor?" -Default $false)
            }
        }
        else { $script:Hipervisores = @() }
    }

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
    # Ordem do mais simples ao mais completo, igual à tela e ao Linux.
    $probeOptions = @(
        "Ping - só confere se o host responde a ping. Não diz nada sobre um site ou serviço estar funcionando.",
        "TCP - só confere se a porta aceita conexão. Não valida o que roda por cima dela.",
        "DNS - confere se o servidor DNS responde a uma consulta.",
        "HTTP - abre a URL e confere se a resposta veio com status 200-299. Não confere o conteúdo: um site com erro visível que responde 200 passa como OK.",
        "HTTPS com certificado - igual ao HTTP, mas exige HTTPS válido e avisa quando o certificado está perto de vencer.",
        "Conteúdo - além do status 200-299, falha se a página trouxer um erro conhecido (ex.: 'Há um erro crítico' do WordPress, erro de conexão com banco, 500/502/503). Pega a página que carrega mas está quebrada."
    )
    $moduleByOption = @{ 1 = "icmp_ipv4"; 2 = "tcp_connect"; 3 = "dns_udp"; 4 = "http_2xx"; 5 = "http_2xx_ssl"; 6 = "http_2xx_content" }
    $suffixByOption = @{ 1 = "ping"; 2 = "tcp"; 3 = "dns"; 4 = "http"; 5 = "https"; 6 = "content" }

    do {
        $name = Read-NextecSlug -Prompt "Nome do alvo (ex.: fw_matriz)" -Kind host
        $address = Read-NextecAddress -Prompt "IP, FQDN ou URL" -Kind destino

        Write-Host "Tipo de teste, do 1 (mais simples) ao 6 (mais completo). Pode escolher mais de um, separados por vírgula, ex.: 1,4" -ForegroundColor White
        for ($i = 0; $i -lt $probeOptions.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $probeOptions[$i])
        }

        $selectedOptions = $null
        while ($null -eq $selectedOptions) {
            $raw = Read-NextecInput -Prompt "Escolha" -Default "1"
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
        Invoke-NextecDownload -Url $url -Destino $destino -Descricao ("snmp.yml {0}" -f $vendor.File) -TimeoutSec 120
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
    $updated = @()

    # Módulo que já existe é substituído: baixar o fabricante de novo traz a
    # versão homologada mais nova (ex.: correção de OID no repositório).
    foreach ($name in @($newBlocks.Keys)) {
        if ($merged.Contains($name)) {
            $merged[$name] = $newBlocks[$name]
            $updated += $name
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

    if ($updated.Count -gt 0) {
        Write-Info ("Módulos atualizados no snmp.yml: {0}" -f ($updated -join ", "))
    }

    $preserved = @($merged.Keys | Where-Object { $added -notcontains $_ -and $updated -notcontains $_ })
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

    # snmp.yml com mais de um fabricante (ex.: FortiGate e MikroTik no mesmo
    # host): o equipamento usa só a família escolhida. Sem isso o alvo
    # recebia os módulos de todos os fabricantes do arquivo.
    $bases = @()
    foreach ($module in $Modules) {
        $base = $module -replace "_(v1|v2c|v2|v3)$", ""
        if ($bases -notcontains $base) { $bases += $base }
    }
    if ($bases.Count -gt 1 -and -not $Silent) {
        $escolhida = $bases[(Read-Choice -Prompt "Módulo deste equipamento" -Options $bases -Default 1) - 1]
        $Modules = @($Modules | Where-Object { ($_ -replace "_(v1|v2c|v2|v3)$", "") -eq $escolhida })
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
    # Só os módulos do arquivo escolhido: os do snmp.yml instalado continuam
    # lá para os equipamentos que já usam, mas não entram no novo.
    $availableModules = @(Get-SnmpConfigSectionKeys -Path $script:SnmpSourceFile -Section "modules")

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
            $name = Read-NextecSlug -Prompt "Nome do equipamento" -Kind host

            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-Warn "Nome inválido após normalização. Use letras, números, hífen ou sublinhado."
                continue
            }

            if (@($script:SnmpTargets | ForEach-Object { $_.Name }) -contains $name) {
                Write-Warn ("Já existe um equipamento chamado '{0}' nesta configuração. Use outro nome." -f $name)
                $name = ""
            }
        }

        $address = Read-NextecAddress -Prompt "IP/FQDN SNMP" -Kind host

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

        $system = Read-NextecSlug -Prompt "Sistema/fabricante" -Default "network" -Kind label

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
        $target = Read-NextecAddress -Prompt "Target host:porta" -Default $definition.DefaultTarget -Kind hostport
        $service = Read-NextecSlug -Prompt "Label servico" -Default $definition.DefaultService -Kind label

        $script:CustomExporters += [pscustomobject]@{
            Name = $definition.Key
            Target = $target
            Service = $service
        }
    }

    if ($selectedKeys -contains "custom") {
        do {
            $name = Read-NextecSlug -Prompt "Nome do exporter" -Kind label
            $target = Read-NextecAddress -Prompt "Target host:porta" -Kind hostport
            $service = Read-NextecSlug -Prompt "Label servico" -Default $name -Kind label

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

        $script:Cliente = Read-NextecSlug -Prompt "Cliente, identificador da empresa e não do servidor (ex.: advocacia_martins)" -Kind cliente
    }
    else {
        $script:Cliente = ConvertTo-ClienteSlug $Cliente
    }

    # ConvertTo-ClienteSlug troca hífen por _, então "Cartorio-Bruno" vira
    # "cartorio_bruno" e passa nesta regra (a mesma do padrão de labels).
    if ($script:Cliente -notmatch "^[a-z0-9][a-z0-9_]*$") {
        throw ("Cliente inválido após normalização: {0}" -f $script:Cliente)
    }

    if ($Silent) {
        if ([string]::IsNullOrWhiteSpace($Inventory.Hostname)) {
            throw "Não foi possível detectar o hostname automaticamente. Modo silencioso exige hostname detectável (env:COMPUTERNAME)."
        }
        $script:HostLabel = ConvertTo-Slug $Inventory.Hostname
    } else {
        $detectedHost = ConvertTo-Slug $Inventory.Hostname
        $script:HostLabel = Read-NextecSlug -Prompt "Hostname para monitoramento" -Default $detectedHost -Kind host
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

        $script:Local = Read-NextecSlug -Prompt "Local" -Default $Local -Kind label

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
    if ($script:EnableColetaResolved) { Import-ColetaLinks }
    if ($script:EnableColetaResolved -and -not $Silent) { Invoke-ColetaLinksPrompt }
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

    if (-not (Test-NextecNeedsLoki)) {
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

    $simNao = { param($v) if ($v) { "sim" } else { "não" } }

    Write-Field -Label "Cliente" -Value $script:Cliente -ValueColor White -Width 26
    Write-Field -Label "Host" -Value $script:HostLabel -ValueColor White -Width 26
    Write-Field -Label "Sistema" -Value ("{0} (build {1})" -f $Inventory.Caption, $Inventory.Build) -Width 26
    Write-Field -Label "Tipo detectado" -Value $Inventory.Generation -Width 26
    Write-Field -Label "Modo Alloy" -Value $script:ResolvedMode -Width 26
    Write-Field -Label "Ambiente" -Value $script:Ambiente -Width 26
    Write-Field -Label "Local" -Value $script:Local -Width 26
    Write-Field -Label "Criticidade" -Value $script:Criticidade -Width 26
    Write-Field -Label "Destino" -Value $script:NocHost -Width 26

    if ($script:MonitorHost) {
        Write-Field -Label "Perfil base" -Value "sim (CPU, memória, discos, rede, uptime, serviços)" -Width 26

        $selectedFeatures = @($script:DetectedHostFeatures | Where-Object { $script:SelectedHostFeatureKeys -contains $_.Key })
        $featureText = if ($selectedFeatures.Count -gt 0) { "sim (" + (($selectedFeatures | ForEach-Object { $_.Label }) -join ", ") + ")" } else { "não" }
        Write-Field -Label "Recursos detectados" -Value $featureText -Width 26
        Write-Field -Label "Logs do sistema" -Value (& $simNao $script:EnableLogsResolved) -Width 26
        Write-Field -Label "Logs de autenticação" -Value (& $simNao $script:EnableSecurityLogsResolved) -Width 26
    }

    if ($script:Collector) {
        Write-Field -Label "SNMP" -Value $(if ($script:EnableSnmpResolved) { "sim ($($script:SnmpTargets.Count))" } else { "não" }) -Width 26
        Write-Field -Label "Conectividade" -Value $(if ($script:EnableBlackboxResolved) { "sim ($($script:BlackboxTargets.Count))" } else { "não" }) -Width 26
        Write-Field -Label "Internet (Speedtest)" -Value $(if ($script:EnableInternetResolved) { "sim (a cada $($script:InternetIntervalMinutesResolved) min)" } else { "não" }) -Width 26
    }

    $motoresPlano = @(Get-NextecBancosMotores)
    Write-Field -Label "Bancos (Coleta)" -Value $(if ($motoresPlano.Count -gt 0) { $motoresPlano -join ", " } else { "não" }) -Width 26
    $virtPlano = @()
    if ((Get-NextecVirtLocal) -ne "nao") { $virtPlano += "Hyper-V local" }
    foreach ($hv in @($script:Hipervisores)) { $virtPlano += ("{0} ({1})" -f $hv.nome, $script:TiposHipervisor[$hv.tipo]) }
    Write-Field -Label "Virtualização" -Value $(if ($virtPlano.Count -gt 0) { $virtPlano -join ", " } else { "não" }) -Width 26
    Write-Field -Label "Internet (Coleta)" -Value (& $simNao $script:EnableColetaResolved) -Width 26
    Write-Field -Label "Links de internet" -Value $(if ($script:ColetaLinks.Count -gt 0) { "sim ($($script:ColetaLinks.Count))" } else { "não" }) -Width 26
    Write-Field -Label "Exporters adicionais" -Value ([string]$script:CustomExporters.Count) -Width 26
    Write-Host ""

    if (-not $Silent -and -not $script:ConfirmadoNaTela -and -not $Simular) {
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
            Wait-NextecSegundos $delaySeconds
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

        if (-not [string]::IsNullOrWhiteSpace($AlloyInstaladorArquivo)) {
            # Entregue pelo atualizador, com o SHA-256 conferido pelo manifesto
            # assinado. Roda direto da pasta protegida do atualizador, sem
            # passar por pasta temporária.
            $installer = $AlloyInstaladorArquivo
            Write-Info ("Instalador do Alloy {0} entregue pelo atualizador." -f $AlloyVersao)
        }
        else {
        # Download com porcentagem na mesma linha (Invoke-NextecDownload). O
        # tempo limite é obrigatório: o padrão do .NET é esperar para sempre,
        # e um proxy que aceita a conexão e não responde travaria o
        # instalador sem mensagem. As tentativas cobrem queda momentânea de
        # link, que de outra forma descartaria o fluxo já preenchido.
        try {
            $maxTries = 3

            for ($try = 1; $try -le $maxTries; $try++) {
                try {
                    Invoke-NextecDownload -Url $LatestInstallerUrl -Destino $installer -Descricao "Grafana Alloy" -TimeoutSec 600
                    break
                }
                catch {
                    if ($try -eq $maxTries) {
                        throw
                    }

                    Write-Warn ("Falha no download (tentativa {0} de {1}): {2}" -f $try, $maxTries, $_.Exception.Message)
                    Wait-NextecSegundos (5 * $try)
                }
            }
        }
        finally {
        }
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

        $process = Start-Process -FilePath $installer -ArgumentList $arguments -PassThru
        Wait-NextecProcesso -Processo $process

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

    if (Test-NextecNeedsLoki) {
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
# O teste de velocidade é o módulo "velocidade" da Coleta Complementar, que
# roda o Speedtest CLI e grava nextec_speedtest_* na pasta textfile da Coleta.
# O instalador só baixa o CLI (pasta nextec-speedtest) e liga [velocidade] no
# .ini. Até a 2.20 o teste rodava pela tarefa NextecSpeedtest, com .prom
# próprio; Remove-NextecSpeedtestLegado apaga esse formato depois que a
# configuração nova sobe validada, para que um rollback ainda o encontre.

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
        Invoke-NextecDownload -Url $SpeedtestCliUrl -Destino $zipPath -Descricao "Speedtest CLI" -TimeoutSec 300
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

function New-SpeedtestTrigger {
    <#
        Monta o gatilho de repetição da tarefa do Speedtest.

        A duração é deliberadamente omitida: pelo schema do Task Scheduler,
        Repetition sem Duration repete indefinidamente. Passar
        [TimeSpan]::MaxValue gera "P99999999DT23H59M59S", que está fora do
        intervalo aceito, e o registro falha com HRESULT 0x80041318
        ("The task XML contains a value which is incorrectly formatted or out
        of range").
    #>
    param(
        [Parameter(Mandatory=$true)][datetime]$Inicio,
        [Parameter(Mandatory=$true)][TimeSpan]$Intervalo
    )

    $trigger = New-ScheduledTaskTrigger -Once -At $Inicio -RepetitionInterval $Intervalo

    # Mesmo sem o parâmetro, parte dos builds do PowerShell preenche a duração
    # com o valor máximo. Limpar aqui evita cair no mesmo erro por outro
    # caminho; a propriedade nem sempre existe, então a checagem é defensiva.
    try {
        if ($null -ne $trigger.PSObject.Properties["Repetition"] -and $null -ne $trigger.Repetition) {
            $duracao = [string]$trigger.Repetition.Duration

            if ($duracao -match "^P9{6,}" -or $duracao -match "P10675199") {
                $trigger.Repetition.Duration = $null
            }
        }
    }
    catch {
        # Objeto sem a propriedade ou somente leitura: segue com o gatilho como
        # veio e deixa o fallback do chamador resolver, se precisar.
    }

    return $trigger
}

function Test-NextecSpeedtestLegado {
    # Formato anterior à 2.21: tarefa agendada ou serviço do Speedtest.
    foreach ($nome in $SpeedtestLegadoNomes) {
        if (Get-ScheduledTask -TaskName $nome -ErrorAction SilentlyContinue) { return $true }
        if (Get-Service -Name $nome -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Remove-NextecSpeedtestLegado {
    <#
        Remove a tarefa e o serviço do Speedtest antigo, o script que a tarefa
        rodava e o .prom dele. Mantém o speedtest.exe, que a Coleta usa. Só
        roda com o Speedtest já na Coleta, ou desligado, e depois do Alloy
        validado.
    #>
    $removidos = New-Object System.Collections.Generic.List[string]
    foreach ($nome in $SpeedtestLegadoNomes) {
        if (Get-ScheduledTask -TaskName $nome -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $nome -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $nome -Confirm:$false
            $removidos.Add("tarefa $nome")
        }
        $servico = Get-Service -Name $nome -ErrorAction SilentlyContinue
        if ($null -ne $servico) {
            Stop-Service -Name $nome -Force -ErrorAction SilentlyContinue
            $saida = & (Join-Path $env:SystemRoot "System32\sc.exe") delete $nome 2>&1
            if ($LASTEXITCODE -ne 0) { throw ("Não foi possível remover o serviço {0}: {1}" -f $nome, ($saida -join " ")) }
            $removidos.Add("serviço $nome")
        }
    }
    foreach ($arquivo in @($SpeedtestRunnerScript, $SpeedtestMetricsFile, "$SpeedtestMetricsFile.tmp")) {
        if (Test-Path -LiteralPath $arquivo -PathType Leaf) {
            Remove-Item -LiteralPath $arquivo -Force
            $removidos.Add((Split-Path -Leaf $arquivo))
        }
    }
    if ((Test-Path -LiteralPath $SpeedtestMetricsDir) -and @(Get-ChildItem -LiteralPath $SpeedtestMetricsDir -Force).Count -eq 0) {
        Remove-Item -LiteralPath $SpeedtestMetricsDir -Force
    }
    if ($removidos.Count -gt 0) {
        Write-Ok ("Speedtest antigo removido ({0}); o teste segue pela Coleta Complementar." -f ($removidos -join ", "))
    }
}

function Install-InternetMonitoring {
    # Só o binário: quem roda o teste é a Coleta Complementar ([velocidade]).
    if (-not $script:EnableInternetResolved) { return }

    Write-Step "Internet (Speedtest)"
    Install-SpeedtestCli
}

# ==============================================================================
# COLETA COMPLEMENTAR NEXTEC (INTERNET E LINKS)
# ==============================================================================
#
# O Alloy coleta o servidor, os logs e as sondas. O que ele não faz sozinho
# (status consolidado da internet, IP público, link em uso, causa das quedas)
# fica com a Coleta Complementar: um arquivo único baixado do repositório
# Scripts, executado por tarefa agendada como SYSTEM. Ela só grava arquivos:
# métricas em $ColetaTextfileDir e eventos em $ColetaEventos. Quem envia ao
# NOC é o próprio Alloy, com a mesma credencial e os mesmos rótulos.
#
# O coleta-complementar.ini é a fonte da verdade dos links: a reconfiguração
# lê dali, e ajustes feitos à mão em [geral] e [internet] são preservados.

function Test-NextecNeedsLoki {
    return ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved -or $script:EnableColetaResolved)
}

function Read-ColetaIniFile {
    param([Parameter(Mandatory=$true)][string]$Caminho)

    $secoes = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Caminho -PathType Leaf)) { return $secoes }

    $atual = $null
    foreach ($linhaBruta in [IO.File]::ReadAllLines($Caminho, (New-Object Text.UTF8Encoding($false)))) {
        $linha = ($linhaBruta -replace '\s[;#].*$', '').Trim()
        if ($linha -eq "" -or $linha.StartsWith(";") -or $linha.StartsWith("#")) { continue }
        if ($linha -match '^\[(.+)\]$') {
            $atual = $Matches[1].Trim()
            $secoes[$atual] = [ordered]@{}
            continue
        }
        if ($null -ne $atual -and $linha -match '^([^=]+)=(.*)$') {
            $secoes[$atual][$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $secoes
}

function Get-ColetaLinksFromIni {
    $ini = Read-ColetaIniFile -Caminho $ColetaConfig
    $links = New-Object System.Collections.Generic.List[object]
    foreach ($nomeSecao in $ini.Keys) {
        if ($nomeSecao -notmatch '^link:(.+)$') { continue }
        $secao = $ini[$nomeSecao]
        $valor = { param($chave, $padrao) if ($secao.Contains($chave)) { [string]$secao[$chave] } else { $padrao } }
        $links.Add([pscustomobject]@{
            nome               = $Matches[1].Trim()
            papel              = & $valor "papel" "primario"
            operadora          = & $valor "operadora" ""
            tipo               = & $valor "tipo" ""
            suporte            = & $valor "suporte" ""
            ip_publico         = & $valor "ip_publico" ""
            gateway            = & $valor "gateway" ""
            alvos              = & $valor "alvos" ""
            origem             = & $valor "origem" ""
            firewall           = & $valor "firewall" ""
            interface_firewall = & $valor "interface_firewall" ""
            velocidade_mbps    = & $valor "velocidade_mbps" ""
            velocidade_upload_mbps = & $valor "velocidade_upload_mbps" ""
        })
    }
    return $links.ToArray()
}

function Import-ColetaLinks {
    $script:ColetaLinks = @(Get-ColetaLinksFromIni)
}

function ConvertTo-ColetaIniValue {
    param([string]$Valor)
    # Colchetes e quebras de linha quebrariam o arquivo INI.
    if ($null -eq $Valor) { return "" }
    return ($Valor -replace "[\r\n]+", " " -replace "\[", "(" -replace "\]", ")").Trim()
}

$script:PapeisLink = [ordered]@{ primario = "Principal"; failover = "Reserva"; sdwan = "SD-WAN" }
$script:TiposLink = [ordered]@{ fibra = "Fibra"; radio = "Rádio"; "4g" = "4G/5G"; satelite = "Satélite"; dedicado = "Dedicado" }
$script:TiposLinkNome = @{ fibra = "Fibra"; radio = "Rádio"; "4g" = "4G"; satelite = "Satélite"; dedicado = "Dedicado" }
# Três destinos por link, de provedores diferentes (uma queda de provedor não
# derruba a medição). Com mais de um link, cada conjunto precisa de uma rota
# própria no firewall, por isso os conjuntos não se repetem.
$script:DestinosLink = @(
    "8.8.8.8, 1.1.1.1, 9.9.9.9",
    "8.8.4.4, 1.0.0.1, 149.112.112.112",
    "208.67.222.222, 208.67.220.220, 94.140.14.14",
    "94.140.15.15, 76.76.2.0, 76.76.10.0"
)

function ConvertTo-NextecMbps {
    # "500", "500m", "1g", "1.5giga" em Mbps (inteiro); $null se inválido.
    param([string]$Texto)
    $m = [Regex]::Match($Texto, '^(\d+(?:\.\d+)?)(g|gb|gbps|giga|gigas|m|mb|mbps|mega|megas)?$')
    if (-not $m.Success) { return $null }
    $valor = [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($m.Groups[2].Value.StartsWith("g")) { $valor = $valor * 1000 }
    $inteiro = [int][Math]::Round($valor)
    if ($inteiro -lt 1 -or $inteiro -gt 100000) { return $null }
    return $inteiro
}

function ConvertTo-NextecVelocidade {
    <#
        Padroniza a velocidade contratada digitada pelo técnico: "500",
        "500 Mega", "1 Giga", "1,5G", "600/300" viram download e upload em
        Mbps. Devolve $null quando não entende.
    #>
    param([string]$Texto)
    $v = ($Texto.ToLowerInvariant() -replace '\s', '') -replace ',', '.'
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    $partes = $v.Split('/')
    if ($partes.Count -gt 2) { return $null }
    $down = ConvertTo-NextecMbps $partes[0]
    if ($null -eq $down) { return $null }
    $up = ""
    if ($partes.Count -eq 2 -and $partes[1] -ne "") {
        $upNum = ConvertTo-NextecMbps $partes[1]
        if ($null -eq $upNum) { return $null }
        $up = [string]$upNum
    }
    return [pscustomobject]@{ Download = [string]$down; Upload = $up }
}

function Get-NextecVelocidadeTexto {
    param([string]$Download, [string]$Upload)
    if ([string]::IsNullOrWhiteSpace($Download)) { return "não informada" }
    if ($Upload) { return ("{0}/{1} Mbps" -f $Download, $Upload) }
    return ("{0} Mbps" -f $Download)
}

function Get-NextecIpPublico {
    # IP público de saída agora (o do link em uso). Vazio se não conseguir.
    foreach ($url in @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")) {
        try {
            $pedido = [Net.HttpWebRequest]::Create($url)
            $pedido.Timeout = 5000
            $pedido.UserAgent = "nextec-instalador/" + $InstallerVersion
            $resposta = $pedido.GetResponse()
            try {
                $leitor = New-Object IO.StreamReader($resposta.GetResponseStream())
                $ip = $leitor.ReadToEnd().Trim()
            }
            finally {
                $resposta.Close()
            }
            $endereco = $null
            if ([Net.IPAddress]::TryParse($ip, [ref]$endereco)) { return $ip }
        }
        catch {
        }
    }
    return ""
}

function Get-NomeLinkUnico {
    param([string]$Base)
    $nome = $Base
    $n = 2
    while (@($script:ColetaLinks | Where-Object { $_.nome -eq $nome }).Count -gt 0) {
        $nome = "{0} {1}" -f $Base, $n
        $n++
    }
    return $nome
}

function Read-ColetaLinkDefinition {
    <#
        Um link por vez: operadora, tipo e velocidade contratada; função só
        com mais de um link. O nome sai da operadora e do tipo. Destinos de
        teste vêm prontos (três por link) e só são digitados se o técnico
        quiser trocar. Com mais de um link, confirma o IP público detectado
        para o principal (os demais a Coleta aprende quando ficam sozinhos no
        ar). Gateway, IP de origem e firewall ficam em opções avançadas.
    #>
    param(
        [int]$Numero = 1,
        [int]$Total = 1
    )

    $variosLinks = ($Total -gt 1) -or ($script:ColetaLinks.Count -gt 0)
    if ($Total -gt 1) {
        Write-Section ("Link {0} de {1}" -f $Numero, $Total)
    }
    else {
        Write-Section "Link de internet"
    }

    $operadora = ConvertTo-ColetaIniValue (Read-Required -Prompt "Operadora")
    $tipos = @($script:TiposLink.Keys)
    $tipo = $tipos[(Read-Choice -Prompt "Tipo de conexão" -Options @($script:TiposLink.Values) -Default 1) - 1]

    $velocidade = [pscustomobject]@{ Download = ""; Upload = "" }
    while ($true) {
        $texto = Read-NextecInput -Prompt "Velocidade contratada" -Hint "ex.: 500, 1 Giga, 600/300; ENTER se não souber"
        if ([string]::IsNullOrWhiteSpace($texto)) { break }
        $lida = ConvertTo-NextecVelocidade $texto
        if ($null -ne $lida) {
            $velocidade = $lida
            Write-Info ("Registrada como {0}." -f (Get-NextecVelocidadeTexto $velocidade.Download $velocidade.Upload))
            break
        }
        Write-Warn ("Velocidade inválida: {0}. Use Mega ou Giga, ex.: 500, 500 Mega, 1 Giga ou 600/300." -f $texto)
    }

    $temPrincipal = @($script:ColetaLinks | Where-Object { $_.papel -eq "primario" }).Count -gt 0
    if (-not $variosLinks) {
        $papel = "primario"
    }
    else {
        $papeis = @($script:PapeisLink.Keys)
        $padraoPapel = if ($temPrincipal) { 2 } else { 1 }
        $papel = $papeis[(Read-Choice -Prompt "Função deste link" -Options @("principal", "reserva (entra quando o principal cai)", "SD-WAN (os dois em uso ao mesmo tempo)") -Default $padraoPapel) - 1]
    }

    $padraoDestino = ""
    if ($script:ColetaLinks.Count -lt $script:DestinosLink.Count) {
        $padraoDestino = $script:DestinosLink[$script:ColetaLinks.Count]
    }
    if ($variosLinks) {
        Write-Hint "Com mais de um link, o firewall precisa mandar os destinos de teste deste"
        Write-Hint "link só por ele (uma rota por link)."
    }
    if ($padraoDestino -and (Read-YesNo -Prompt ("Destinos de teste: {0}. Usar estes?" -f $padraoDestino) -Default $true)) {
        $alvos = $padraoDestino
    }
    else {
        $alvos = Read-NextecAddress -Prompt "Destinos de teste deste link, separados por vírgula" -Kind host -List
    }

    $ipPublico = ""
    if ($variosLinks -and $papel -eq "primario") {
        $detectado = Get-NextecIpPublico
        if ($detectado -and (Read-YesNo -Prompt ("O IP público atual ({0}) é deste link?" -f $detectado) -Default $true)) {
            $ipPublico = $detectado
        }
    }

    $gateway = ""; $origem = ""; $firewall = ""; $interface = ""
    if (Read-YesNo -Prompt "Opções avançadas (gateway da operadora, IP de origem, firewall)?" -Default $false) {
        Write-Hint "Gateway: separa queda da operadora de problema no firewall."
        $gateway = Read-NextecAddress -Prompt "IP do gateway da operadora" -Kind host -Optional
        while ($true) {
            $origem = Read-NextecAddress -Prompt "IP deste servidor que sai só por este link" -Kind ip -Optional
            if (-not $origem -or (Get-NetIPAddress -IPAddress $origem -ErrorAction SilentlyContinue)) { break }
            Write-Warn ("O IP {0} não existe neste servidor. Informe um IP local ou deixe vazio." -f $origem)
        }
        $firewallRaw = Read-NextecInput -Prompt "Nome do firewall no NOC, para cruzar com o tráfego SNMP" -Hint "opcional"
        if (-not [string]::IsNullOrWhiteSpace($firewallRaw)) { $firewall = ConvertTo-Slug $firewallRaw }
        if ($firewall) {
            $interface = Read-NextecPattern -Prompt "Interface WAN do link no firewall" -Pattern '^[A-Za-z0-9._:/-]+$' -Hint "o nome como aparece no firewall, ex.: igb1, ether1, wan1"
        }
    }

    $nome = Get-NomeLinkUnico -Base (ConvertTo-ColetaIniValue ("{0} {1}" -f $operadora, $script:TiposLinkNome[$tipo]))
    return [pscustomobject]@{
        nome = $nome; papel = $papel; operadora = $operadora; tipo = $tipo; suporte = ""
        ip_publico = $ipPublico; gateway = $gateway; alvos = $alvos; origem = $origem
        firewall = $firewall; interface_firewall = $interface
        velocidade_mbps = $velocidade.Download; velocidade_upload_mbps = $velocidade.Upload
    }
}

function Show-ColetaLinks {
    if ($script:ColetaLinks.Count -eq 0) {
        Write-Hint "Nenhum link cadastrado."
        return
    }
    Write-Host ("    {0,-20} {1,-10} {2,-14} {3,-16} {4}" -f "LINK", "FUNÇÃO", "VELOCIDADE", "IP PÚBLICO", "DESTINOS DE TESTE") -ForegroundColor Gray
    foreach ($link in $script:ColetaLinks) {
        $funcao = if ($script:PapeisLink.Contains([string]$link.papel)) { $script:PapeisLink[[string]$link.papel] } else { $link.papel }
        $ip = if ($link.ip_publico) { $link.ip_publico } else { "automático" }
        $vel = if ($link.velocidade_mbps) { Get-NextecVelocidadeTexto $link.velocidade_mbps $link.velocidade_upload_mbps } else { "-" }
        Write-Host ("    {0,-20} " -f $link.nome) -ForegroundColor White -NoNewline
        Write-Host ("{0,-10} {1,-14} {2,-16} {3}" -f $funcao, $vel, $ip, $link.alvos)
    }
}

function Invoke-ColetaLinksPrompt {
    # Sem links cadastrados: "Quantos links?" (padrão 1). Com links: mostra e
    # pergunta se quer alterar.
    if ($script:ColetaLinks.Count -eq 0) {
        Edit-ColetaLinks
    }
    else {
        Write-Host ""
        Show-ColetaLinks
        if (Read-YesNo -Prompt ("Alterar os {0} link(s) de internet cadastrado(s)?" -f $script:ColetaLinks.Count) -Default $false) {
            Edit-ColetaLinks
        }
    }
    $script:EnableLinksResolved = ($script:ColetaLinks.Count -gt 0)
}

function Edit-ColetaLinks {
    Write-Step "Links de internet"

    if ($script:ColetaLinks.Count -eq 0) {
        $total = 0
        while ($total -lt 1 -or $total -gt 6) {
            $texto = Read-Required -Prompt "Quantos links de internet este local tem?" -Default "1"
            if (-not [int]::TryParse($texto, [ref]$total) -or $total -lt 1 -or $total -gt 6) {
                Write-Warn "Informe um número de 1 a 6."
                $total = 0
            }
        }
        for ($n = 1; $n -le $total; $n++) {
            $novo = Read-ColetaLinkDefinition -Numero $n -Total $total
            $script:ColetaLinks = @($script:ColetaLinks) + $novo
            Write-Ok ("Link {0} cadastrado ({1}, {2})." -f $novo.nome, $script:PapeisLink[$novo.papel], (Get-NextecVelocidadeTexto $novo.velocidade_mbps $novo.velocidade_upload_mbps))
        }
    }

    while ($true) {
        Write-Host ""
        Show-ColetaLinks
        Write-Host ""
        $escolha = Read-Choice -Prompt "Links" -Options @("Adicionar link", "Remover link", "Concluir") -Default 3

        switch ($escolha) {
            1 {
                $novo = Read-ColetaLinkDefinition
                $script:ColetaLinks = @($script:ColetaLinks) + $novo
                Write-Ok ("Link {0} cadastrado ({1}, {2})." -f $novo.nome, $script:PapeisLink[$novo.papel], (Get-NextecVelocidadeTexto $novo.velocidade_mbps $novo.velocidade_upload_mbps))
            }
            2 {
                if ($script:ColetaLinks.Count -eq 0) { continue }
                $indice = Read-Choice -Prompt "Qual link remover?" -Options @($script:ColetaLinks | ForEach-Object { $_.nome }) -Default 1
                $removido = $script:ColetaLinks[$indice - 1].nome
                $script:ColetaLinks = @($script:ColetaLinks | Where-Object { $_.nome -ne $removido })
                Write-Ok ("Link {0} removido." -f $removido)
            }
            3 {
                $script:EnableLinksResolved = ($script:ColetaLinks.Count -gt 0)
                return
            }
        }
    }
}

function Write-ColetaConfig {
    <#
        Regrava o coleta-complementar.ini. [geral] e [internet] mantêm o que já
        estava no arquivo (inclusive ajustes feitos à mão); os links vêm de
        $script:ColetaLinks.
    #>
    $existente = Read-ColetaIniFile -Caminho $ColetaConfig
    $geral = [ordered]@{ intervalo_links_segundos = "15"; limite_latencia_ms = "150"; limite_perda_percentual = "5" }
    $internet = [ordered]@{ alvos = "1.1.1.1, 8.8.8.8"; firewall = ""; dns_servidores = "sistema, 1.1.1.1, 8.8.8.8"; dns_nome = "google.com" }
    # Acessos (logins RDP e console com origem): ligado por padrão, inclusive
    # em instalação antiga que receber esta versão pelo atualizador.
    $acessos = [ordered]@{ ativo = "sim"; horario = "seg-sex 07:00-19:00; sab 07:00-14:00"; origens_conhecidas = "" }
    foreach ($par in @(@("geral", $geral), @("internet", $internet), @("acessos", $acessos))) {
        if ($existente.Contains($par[0])) {
            foreach ($chave in $existente[$par[0]].Keys) { $par[1][$chave] = $existente[$par[0]][$chave] }
        }
    }
    # A internet fica desligada quando a Coleta roda só pelos bancos.
    $internet["ativo"] = $(if ($script:EnableColetaResolved) { "sim" } else { "nao" })
    $motores = @(Get-NextecBancosMotores)
    $arquivosSqlite = @(([string]$script:BancosSqlite) -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "sqlite:$_" })

    $linhas = New-Object System.Collections.Generic.List[string]
    $linhas.Add("; Coleta Complementar Nextec")
    $linhas.Add(("; Gerado pelo instalador {0} em {1}." -f $InstallerVersion, (Get-Date -Format "dd/MM/yyyy HH:mm")))
    $linhas.Add("; Depois de alterar: Restart-ScheduledTask -TaskName $ColetaTaskName (ou reiniciar o servidor).")
    $linhas.Add("; Manual completo: Confluence NXTDOC, ""Coleta Complementar Nextec"".")
    $linhas.Add("")
    $linhas.Add("[geral]")
    foreach ($chave in $geral.Keys) { $linhas.Add(("{0} = {1}" -f $chave, $geral[$chave])) }
    $linhas.Add("")
    $linhas.Add("[internet]")
    foreach ($chave in $internet.Keys) { $linhas.Add(("{0} = {1}" -f $chave, $internet[$chave])) }
    $linhas.Add("")
    $linhas.Add("; Logins RDP e de console com IP de origem, para os alertas de acesso")
    $linhas.Add("; privilegiado. horario: comercial, em Brasília. origens_conhecidas: redes")
    $linhas.Add("; da Nextec ou VPN que não contam como origem nova (ex.: 203.0.113.0/24).")
    $linhas.Add("[acessos]")
    foreach ($chave in $acessos.Keys) { $linhas.Add(("{0} = {1}" -f $chave, $acessos[$chave])) }
    $linhas.Add("")
    $linhas.Add("; Bancos sem exportador próprio: no ar, conexões, memória, tempo ligado e")
    $linhas.Add("; tamanho das bases. motores: firebird, oracle, sqlanywhere. arquivos: bases")
    $linhas.Add("; para medir, como motor:caminho (curinga aceito). O SQL Server segue com o")
    $linhas.Add("; coletor mssql do Alloy.")
    $linhas.Add("[bancos]")
    $linhas.Add(("ativo = {0}" -f $(if ($motores.Count -gt 0) { "sim" } else { "nao" })))
    $linhas.Add(("motores = {0}" -f ($motores -join ", ")))
    $linhas.Add(("arquivos = {0}" -f ($arquivosSqlite -join ", ")))
    $linhas.Add("")
    $linhas.Add("; VMs, armazenamento, snapshots e replicação. local: hyperv neste servidor")
    $linhas.Add("; (sem senha) ou nao. Hipervisores da rede em [hipervisor:<nome>], com a")
    $linhas.Add(("; senha ou o token em {0}." -f $ColetaSegredos))
    $linhas.Add("[virtualizacao]")
    $linhas.Add(("ativo = {0}" -f $(if (Test-NextecVirtualizacao) { "sim" } else { "nao" })))
    $linhas.Add(("local = {0}" -f (Get-NextecVirtLocal)))
    foreach ($hv in @($script:Hipervisores)) {
        $linhas.Add("")
        $linhas.Add(("[hipervisor:{0}]" -f $hv.nome))
        $linhas.Add(("tipo = {0}" -f $hv.tipo))
        $linhas.Add(("endereco = {0}" -f $hv.endereco))
        $linhas.Add(("usuario = {0}" -f $hv.usuario))
        $linhas.Add(("verificar_certificado = {0}" -f $(if ($hv.verificar) { "sim" } else { "nao" })))
    }
    $linhas.Add("")
    $linhas.Add("; Teste de velocidade (Speedtest CLI da Ookla). Satura o link durante o")
    $linhas.Add("; teste: um servidor por local, a cada 30 min (recomendado).")
    $linhas.Add("[velocidade]")
    $linhas.Add(("ativo = {0}" -f $(if ($script:EnableInternetResolved) { "sim" } else { "nao" })))
    $linhas.Add(("intervalo_minutos = {0}" -f $script:InternetIntervalMinutesResolved))
    $linhas.Add(("speedtest = {0}" -f $SpeedtestExe))

    foreach ($link in $script:ColetaLinks) {
        $linhas.Add("")
        $linhas.Add(("[link:{0}]" -f $link.nome))
        foreach ($chave in @("papel", "operadora", "tipo", "suporte", "ip_publico", "gateway", "alvos", "origem", "firewall", "interface_firewall", "velocidade_mbps", "velocidade_upload_mbps")) {
            $valorLink = if ($link.PSObject.Properties[$chave]) { $link.$chave } else { "" }
            $linhas.Add(("{0} = {1}" -f $chave, $valorLink))
        }
        $linhas.Add("teste_velocidade = nao")
    }

    if (Test-Path -LiteralPath $ColetaConfig) {
        Copy-Item -LiteralPath $ColetaConfig -Destination ("{0}.{1}.bak" -f $ColetaConfig, (Get-Date -Format "yyyyMMdd-HHmmss")) -Force
    }
    Write-ColetaSegredos
    [IO.File]::WriteAllText($ColetaConfig, (($linhas -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

function Register-ColetaScheduledTask {
    <#
        A Coleta roda em laço contínuo. A tarefa sobe na inicialização e tem um
        segundo gatilho a cada 5 minutos com "ignorar nova instância": se o
        processo cair por qualquer motivo, volta em no máximo 5 minutos, sem
        nunca rodar duas cópias ao mesmo tempo.
    #>
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Acao executar' -f $ColetaScript)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

    $gatilhos = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-SpeedtestTrigger -Inicio ((Get-Date).AddMinutes(1)) -Intervalo (New-TimeSpan -Minutes 5))
    )

    Register-ScheduledTask -TaskName $ColetaTaskName -Action $action -Trigger $gatilhos `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Stop-ColetaComplementar {
    if (Get-ScheduledTask -TaskName $ColetaTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $ColetaTaskName -ErrorAction SilentlyContinue
    }
    # Stop-ScheduledTask nem sempre encerra o powershell.exe filho.
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*{0}*' -f $ColetaScript) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-NextecBancosMotores {
    # Bancos medidos pela Coleta Complementar (módulo bancos).
    $motores = @()
    foreach ($chave in @("firebird", "oracle", "sqlanywhere")) {
        if ($script:MonitorHost -and @($script:SelectedHostFeatureKeys) -contains $chave) { $motores += $chave }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:BancosSqlite)) { $motores += "sqlite" }
    return $motores
}

function Get-NextecVirtLocal {
    # Hyper-V deste servidor, medido pela Coleta sem senha.
    if ($script:MonitorHost -and @($script:SelectedHostFeatureKeys) -contains "hyper_v") { return "hyperv" }
    return "nao"
}

function Test-NextecVirtualizacao {
    return ((Get-NextecVirtLocal) -ne "nao" -or @($script:Hipervisores).Count -gt 0)
}

function Test-NextecColetaNecessaria {
    # A Coleta Complementar roda quando a internet está ligada, quando há
    # banco ou hipervisor para ela medir ou com o teste de velocidade.
    return ($script:EnableColetaResolved -or $script:EnableInternetResolved -or @(Get-NextecBancosMotores).Count -gt 0 -or (Test-NextecVirtualizacao))
}

function Read-ColetaSegredosArquivo {
    # Segredo pode ter ; e #: aqui nada vira comentário no meio da linha.
    $secoes = @{}
    if (-not (Test-Path -LiteralPath $ColetaSegredos -PathType Leaf)) { return $secoes }
    $atual = $null
    foreach ($linha in [IO.File]::ReadAllLines($ColetaSegredos, (New-Object Text.UTF8Encoding($false)))) {
        $limpa = $linha.Trim()
        if ($limpa -eq "" -or $limpa.StartsWith(";") -or $limpa.StartsWith("#")) { continue }
        if ($limpa -match '^\[(.+)\]$') { $atual = $Matches[1].Trim(); $secoes[$atual] = @{}; continue }
        if ($null -ne $atual -and $limpa -match '^([^=]+)=(.*)$') { $secoes[$atual][$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $secoes
}

function Write-ColetaSegredos {
    <#
        Grava o segredo de cada hipervisor. Segredo não redigitado continua o
        que já estava no arquivo; hipervisor que saiu da lista sai do arquivo.
        O arquivo é protegido antes de receber o conteúdo.
    #>
    $existente = Read-ColetaSegredosArquivo
    $linhas = New-Object System.Collections.Generic.List[string]
    $linhas.Add("; Senhas e tokens dos hipervisores da Coleta Complementar. Só SYSTEM e Administradores leem.")
    $total = 0
    foreach ($hv in @($script:Hipervisores)) {
        $secao = "hipervisor:" + $hv.nome
        $chave = if ($hv.tipo -eq "proxmox") { "token" } else { "senha" }
        $valor = if ($hv.segredo) { [string]$hv.segredo } elseif ($existente.ContainsKey($secao)) { [string]$existente[$secao][$chave] } else { "" }
        if (-not $valor) {
            Write-Warn ("Hipervisor {0} sem senha ou token: ele aparece como sem resposta até a credencial ser informada." -f $hv.nome)
            continue
        }
        $linhas.Add(""); $linhas.Add("[$secao]"); $linhas.Add("$chave = $valor")
        $total++
    }
    if ($total -eq 0) {
        Remove-Item -LiteralPath $ColetaSegredos -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path -LiteralPath $ColetaSegredos)) { [IO.File]::WriteAllText($ColetaSegredos, "", (New-Object Text.UTF8Encoding($false))) }
    Protect-NextecSecretFile -Path $ColetaSegredos
    [IO.File]::WriteAllText($ColetaSegredos, (($linhas -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

function Test-NextecEnderecoHipervisor {
    param([string]$Valor)
    return ([string]$Valor -match '^[A-Za-z0-9.-]+(:\d{1,5})?$')
}

function Read-NextecHipervisor {
    # Cadastro de um hipervisor no console. Devolve o objeto ou $null.
    $tipos = @($script:TiposHipervisor.Keys)
    $tipo = $tipos[(Read-Choice -Prompt "Tipo do hipervisor" -Options @($script:TiposHipervisor.Values) -Default 1) - 1]
    $nome = ""
    while (-not $nome) {
        $nome = Get-GuiSlug (Read-Required -Prompt "Nome no NOC (ex.: esxi01)")
        if (-not $nome) { Write-Warn "Use letras, números, ponto ou hífen." }
    }
    $dica = switch ($tipo) { "vmware" { "IP ou nome; o vCenter cobre todos os hosts dele" } "proxmox" { "IP ou nome de um nó; a porta 8006 é a padrão" } default { "IP ou nome do mestre do pool" } }
    while ($true) {
        $endereco = Read-NextecInput -Prompt "Endereço" -Hint $dica
        if (Test-NextecEnderecoHipervisor $endereco) { break }
        Write-Warn "Use só IP ou nome, com porta opcional (ex.: 192.168.0.10 ou esxi.local:443)."
    }
    switch ($tipo) {
        "proxmox" {
            Write-Info "Token de API com o papel PVEAuditor, no formato usuario@realm!token (ex.: monitor@pve!nextec)."
            while ($true) {
                $usuario = Read-Required -Prompt "ID do token"
                if ($usuario -match '^[^@!]+@[^@!]+![^@!]+$') { break }
                Write-Warn "Formato esperado: usuario@realm!token."
            }
            $segredo = Read-RequiredSecret -Prompt "Segredo do token"
        }
        "vmware" {
            Write-Info "Usuário só leitura no ESXi ou vCenter (papel Somente leitura), ex.: monitor@vsphere.local."
            $usuario = Read-Required -Prompt "Usuário"
            $segredo = Read-RequiredSecret -Prompt "Senha"
        }
        default {
            Write-Info "Usuário com papel read-only no pool (ou root)."
            $usuario = Read-Required -Prompt "Usuário"
            $segredo = Read-RequiredSecret -Prompt "Senha"
        }
    }
    Write-Info "Certificado próprio é o padrão desses hipervisores: responda n. A conexão continua cifrada."
    $verificar = Read-YesNo -Prompt "Conferir o certificado HTTPS?" -Default $false
    return [pscustomobject]@{ nome = $nome; tipo = $tipo; endereco = $endereco.Trim(); usuario = $usuario; verificar = [bool]$verificar; segredo = $segredo }
}

function Edit-HipervisoresSettings {
    Write-Step "Hipervisores (virtualização)"
    if ((Get-NextecVirtLocal) -ne "nao") { Write-Info "Hyper-V deste servidor: sempre coletado, sem senha." }
    Write-Info ("Senhas e tokens não são exibidos; ficam em {0}." -f $ColetaSegredos)
    while ($true) {
        if (@($script:Hipervisores).Count -eq 0) { Write-Info "Nenhum hipervisor pela rede cadastrado." }
        $i = 0
        foreach ($hv in @($script:Hipervisores)) { $i++; Write-Host ("  {0}  {1} ({2}) {3}" -f $i, $hv.nome, $script:TiposHipervisor[$hv.tipo], $hv.endereco) }
        $acao = Read-Choice -Prompt "O que deseja fazer?" -Options @("Voltar", "Adicionar", "Remover um") -Default 1
        if ($acao -eq 1) { break }
        if ($acao -eq 2) {
            $novo = Read-NextecHipervisor
            $script:Hipervisores = @(@($script:Hipervisores | Where-Object { $_.nome -ne $novo.nome }) + $novo)
        }
        elseif ($acao -eq 3 -and @($script:Hipervisores).Count -gt 0) {
            $indice = Read-Choice -Prompt "Qual remover?" -Options @($script:Hipervisores | ForEach-Object { "{0} ({1})" -f $_.nome, $_.endereco }) -Default 1
            $script:Hipervisores = @($script:Hipervisores | Where-Object { $_ -ne $script:Hipervisores[$indice - 1] })
        }
    }
}

function Test-NextecCaminhosSqlite {
    # Caminhos absolutos (C:\... ou \\servidor\...), separados por vírgula.
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $true }
    foreach ($item in ($Texto -split ",")) {
        if ($item.Trim() -notmatch '^([A-Za-z]:\\|\\\\)[^|;]+$') { return $false }
    }
    return $true
}

function Install-ColetaComplementar {
    if (-not (Test-NextecColetaNecessaria)) {
        # Desligando numa reconfiguração: para e remove a tarefa, mas mantém o
        # .ini (links cadastrados) para uma eventual religação.
        if (Get-ScheduledTask -TaskName $ColetaTaskName -ErrorAction SilentlyContinue) {
            Stop-ColetaComplementar
            Unregister-ScheduledTask -TaskName $ColetaTaskName -Confirm:$false
            Get-ChildItem -LiteralPath $ColetaTextfileDir -Filter "*.prom" -ErrorAction SilentlyContinue | Remove-Item -Force
            Write-Info "Coleta Complementar desligada."
        }
        return
    }

    $partes = @()
    if ($script:EnableColetaResolved) { $partes += "internet e links" }
    if ($script:EnableInternetResolved) { $partes += "velocidade" }
    if (@(Get-NextecBancosMotores).Count -gt 0) { $partes += "bancos de dados" }
    if (Test-NextecVirtualizacao) { $partes += "virtualização" }
    Write-Step ("Coleta Complementar ({0})" -f ($partes -join ", "))

    # Roda como SYSTEM: pasta protegida antes de gravar o script.
    Protect-NextecDirectory -Path $ColetaDir -LeituraUsuarios
    if (-not (Test-Path -LiteralPath $ColetaTextfileDir)) { New-Item -ItemType Directory -Path $ColetaTextfileDir -Force | Out-Null }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $temporario = Join-Path $env:TEMP ("coleta-complementar-{0}.ps1" -f [guid]::NewGuid().ToString("N"))
    try {
        if (-not [string]::IsNullOrWhiteSpace($ColetaArquivo)) {
            # Entregue pelo atualizador, já conferido pela assinatura do manifesto.
            Copy-Item -LiteralPath $ColetaArquivo -Destination $temporario -Force
        }
        else {
            Invoke-NextecDownload -Url $ColetaUrl -Destino $temporario -Descricao "Coleta Complementar" -TimeoutSec 120
        }
        $erros = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($temporario, [ref]$null, [ref]$erros)
        if ($erros -and $erros.Count -gt 0) {
            throw ("Arquivo baixado da Coleta Complementar tem erro de sintaxe: {0}" -f $erros[0].Message)
        }
        Stop-ColetaComplementar
        Copy-Item -LiteralPath $temporario -Destination $ColetaScript -Force
    }
    finally {
        Remove-Item -LiteralPath $temporario -Force -ErrorAction SilentlyContinue
    }

    Write-ColetaConfig
    Register-ColetaScheduledTask
    Start-ScheduledTask -TaskName $ColetaTaskName

    $versao = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ColetaScript -Acao versao
    Write-Ok ("Coleta Complementar {0} instalada; {1} link(s) cadastrado(s)." -f ($versao | Select-Object -Last 1), $script:ColetaLinks.Count)

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ColetaScript -Acao verificar | ForEach-Object { Write-Info $_ }
}

function Edit-ColetaSettings {
    Write-Step "Internet e links (Coleta Complementar)"

    if ($script:EnableColetaResolved) {
        Write-Info ("Ligada. Configuração em {0}." -f $ColetaConfig)
    }
    else {
        Write-Info "Desligada."
    }

    $script:EnableColetaResolved = Read-YesNo -Prompt "Monitorar a internet deste local (status, DNS, IP público, diagnóstico)?" -Default $true
    if (-not $script:EnableColetaResolved) {
        $script:EnableLinksResolved = $false
        return
    }

    if ($script:ColetaLinks.Count -eq 0) { Import-ColetaLinks }
    Invoke-ColetaLinksPrompt

    if ((Test-NextecNeedsLoki) -and [string]::IsNullOrWhiteSpace($script:LokiUsername)) {
        Read-LokiCredentials
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

        A lista base é o perfil mínimo do documento 03. "time" traz o
        relógio e o desvio em relação à fonte NTP (w32time), usado pelo
        alerta de relógio fora de sincronia.

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

    foreach ($collector in @("cpu","logical_disk","memory","net","os","service","system","time")) {
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

    # O exporter "system" existe só com o host monitorado. O Speedtest chega
    # pela pasta textfile da Coleta Complementar, que tem exporter próprio.
    if ($script:MonitorHost) {
        $collectors = New-Object System.Collections.Generic.List[string] (,[string[]](Get-WindowsCollectors))

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

            $processosBanco = @()
            if ($script:SelectedHostFeatureKeys -contains "firebird") { $processosBanco += "firebird|firebird_server|fbserver|fb_inet_server|fbguard" }
            if ($script:SelectedHostFeatureKeys -contains "oracle") { $processosBanco += "oracle|tnslsnr" }
            if ($script:SelectedHostFeatureKeys -contains "sqlanywhere") { $processosBanco += "dbsrv[0-9]+|dbeng[0-9]+" }
            if ($processosBanco.Count -gt 0) {
                [void]$builder.AppendLine("")
                [void]$builder.AppendLine("  // Coletor process restrito aos bancos. Sem include ele gera uma")
                [void]$builder.AppendLine("  // serie por processo do host.")
                [void]$builder.AppendLine('  process {')
                [void]$builder.AppendLine(('    include = "^({0}).*"' -f ($processosBanco -join "|")))
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

    # Sempre presente: além da Coleta Complementar, o atualizador automático
    # grava as métricas dele (versão, onda, resultado) na mesma pasta. Com a
    # Coleta desligada o bloco leva outro nome, porque a leitura da
    # configuração atual usa "coleta_complementar" para saber se ela está ligada.
    $nomeTextfile = if (Test-NextecColetaNecessaria) { "coleta_complementar" } else { "atualizador" }
    if ($true) {
        # Exporter próprio só com o textfile da Coleta Complementar. Separado
        # do "system" para valer em qualquer modo e para poder usar
        # honor_labels: as métricas trazem rótulos próprios (tipo do link,
        # tipo de espaço) que não podem ser sobrescritos pelos rótulos do host.
        [void]$builder.AppendLine("// Coleta Complementar Nextec: internet e links")
        [void]$builder.AppendLine(('prometheus.exporter.windows "{0}" {{' -f $nomeTextfile))
        [void]$builder.AppendLine('  enabled_collectors = ["textfile"]')
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine("  textfile {")
        [void]$builder.AppendLine(('    text_file_directory = "{0}"' -f (ConvertTo-AlloyEscapedString $ColetaTextfileDir)))
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine(('discovery.relabel "{0}_labels" {{' -f $nomeTextfile))
        [void]$builder.AppendLine(("  targets = prometheus.exporter.windows.{0}.targets" -f $nomeTextfile))
        [void]$builder.AppendLine("")
        Add-AlloyRelabelRule -Builder $builder -Target "instance" -Replacement $script:HostLabel
        Add-AlloyRelabelRule -Builder $builder -Target "host" -Replacement $script:HostLabel
        Add-AlloyRelabelRule -Builder $builder -Target "cliente" -Replacement $script:Cliente
        # O alvo do exporter já traz job=integrations/windows, que prevalece
        # sobre job_name do scrape: o job da Coleta é fixado aqui.
        Add-AlloyRelabelRule -Builder $builder -Target "job" -Replacement "integrations/coleta_complementar"
        Add-AlloyRelabelRule -Builder $builder -Target "servico" -Replacement "coleta_complementar"
        Add-AlloyRelabelRule -Builder $builder -Target "tipo" -Replacement $script:TipoLabel
        Add-AlloyRelabelRule -Builder $builder -Target "ambiente" -Replacement $script:Ambiente
        Add-AlloyRelabelRule -Builder $builder -Target "os" -Replacement "windows"
        Add-AlloyRelabelRule -Builder $builder -Target "origem" -Replacement "alloy"
        Add-AlloyRelabelRule -Builder $builder -Target "criticidade" -Replacement $script:Criticidade
        Add-AlloyRelabelRule -Builder $builder -Target "local" -Replacement $script:Local
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine(('prometheus.scrape "{0}" {{' -f $nomeTextfile))
        [void]$builder.AppendLine(("  targets         = discovery.relabel.{0}_labels.output" -f $nomeTextfile))
        [void]$builder.AppendLine("  forward_to      = [prometheus.relabel.filtro_nextec.receiver]")
        [void]$builder.AppendLine('  job_name        = "integrations/coleta_complementar"')
        [void]$builder.AppendLine("  honor_labels    = true")
        [void]$builder.AppendLine('  scrape_interval = "15s"')
        [void]$builder.AppendLine('  scrape_timeout  = "10s"')
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
    }

    if (($script:MonitorHost -and ($script:EnableLogsResolved -or $script:EnableSecurityLogsResolved)) -or $script:EnableColetaResolved) {
        [void]$builder.AppendLine("// Logs Windows e eventos da Coleta Complementar")
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

    if ($script:EnableColetaResolved) {
        # Um JSON por linha. tipo, categoria e link viram rótulos porque os
        # painéis filtram por eles; o restante fica no corpo (| json).
        [void]$builder.AppendLine('loki.source.file "coleta_complementar" {')
        [void]$builder.AppendLine("  targets = [{")
        [void]$builder.AppendLine(('    "__path__"  = "{0}",' -f (ConvertTo-AlloyEscapedString $ColetaEventos)))
        [void]$builder.AppendLine(('    cliente     = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Cliente)))
        [void]$builder.AppendLine(('    host        = "{0}",' -f (ConvertTo-AlloyEscapedString $script:HostLabel)))
        [void]$builder.AppendLine('    servico     = "coleta_complementar",')
        [void]$builder.AppendLine(('    ambiente    = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Ambiente)))
        [void]$builder.AppendLine('    os          = "windows",')
        [void]$builder.AppendLine('    origem      = "alloy",')
        [void]$builder.AppendLine(('    criticidade = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Criticidade)))
        [void]$builder.AppendLine(('    local       = "{0}",' -f (ConvertTo-AlloyEscapedString $script:Local)))
        [void]$builder.AppendLine("  }]")
        [void]$builder.AppendLine("  forward_to    = [loki.process.coleta_complementar.receiver]")
        [void]$builder.AppendLine("  tail_from_end = true")
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine('loki.process "coleta_complementar" {')
        [void]$builder.AppendLine("  forward_to = [loki.write.nextec.receiver]")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine("  stage.json {")
        [void]$builder.AppendLine('    expressions = { tipo = "", categoria = "", link = "", ts = "" }')
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine("  stage.labels {")
        [void]$builder.AppendLine('    values = { tipo = "", categoria = "", link = "" }')
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("")
        [void]$builder.AppendLine("  stage.timestamp {")
        [void]$builder.AppendLine('    source = "ts"')
        [void]$builder.AppendLine('    format = "RFC3339"')
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("}")
        [void]$builder.AppendLine("")
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

        if (Test-NextecNeedsLoki) {
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
        Wait-NextecSegundos 1
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

        Wait-NextecSegundos 2
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

    Wait-NextecSegundos 45
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
        if ($script:EnableColetaResolved -and -not $restored) {
            Unregister-ScheduledTask -TaskName $ColetaTaskName -Confirm:$false -ErrorAction SilentlyContinue
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

    $simbolo = if ($comPendencia) { "!" } else { $script:SimboloOk }
    $titulo = if ($comPendencia) { "INSTALAÇÃO CONCLUÍDA COM PENDÊNCIAS" } else { "INSTALAÇÃO CONCLUÍDA" }
    $titulo = "{0}  {1}" -f $simbolo, $titulo
    $largura = 54
    $esquerda = [int][Math]::Floor(($largura - $titulo.Length) / 2)
    $direita = $largura - $titulo.Length - $esquerda
    $h = [string][char]0x2550

    Write-Host ""
    Write-Host ("  {0}{1}{2}" -f [char]0x2554, ($h * $largura), [char]0x2557) -ForegroundColor $cor
    Write-Host ("  {0}{1}{2}{3}{4}" -f [char]0x2551, (" " * $esquerda), $titulo, (" " * $direita), [char]0x2551) -ForegroundColor $cor
    Write-Host ("  {0}{1}{2}" -f [char]0x255A, ($h * $largura), [char]0x255D) -ForegroundColor $cor

    # Estado real do serviço. O resumo é o que o técnico usa para encerrar o
    # atendimento, então não pode afirmar nada que não tenha sido verificado.
    $alloyService = Get-AlloyService
    $alloyStatus = Get-NextecEstadoServico -Servico $alloyService
    $corAlloy = if ($alloyStatus -eq "ativo") { [ConsoleColor]::Green } else { [ConsoleColor]::Red }

    Write-Section "Identificação"
    Write-Field -Label "Cliente" -Value $script:Cliente -ValueColor White -Width 20
    Write-Field -Label "Host" -Value $script:HostLabel -ValueColor White -Width 20
    Write-Field -Label "Sistema" -Value $Inventory.Caption -Width 20
    Write-Field -Label "Modo" -Value $script:ResolvedMode -Width 20
    Write-Field -Label "Alloy" -Value $alloyStatus -ValueColor $corAlloy -Width 20

    Write-Section "Envio para o NOC"
    Write-Field -Label "Métricas" -Value $script:RemoteWriteUrl -Width 20
    if (Test-NextecNeedsLoki) {
        Write-Field -Label "Logs e eventos" -Value $script:LokiUrl -Width 20
    }

    Write-Section "Coletas ligadas"
    if ($script:MonitorHost) {
        Write-Field -Label "Servidor" -Value "CPU, memória, discos, rede, serviços" -ValueColor Green -Width 20
        $selectedFeatures = @($script:DetectedHostFeatures | Where-Object { $script:SelectedHostFeatureKeys -contains $_.Key })
        if ($selectedFeatures.Count -gt 0) {
            Write-Field -Label "Recursos" -Value (($selectedFeatures | ForEach-Object { $_.Label }) -join ", ") -ValueColor Green -Width 20
        }
    }
    if ($script:EnableBlackboxResolved) {
        Write-Field -Label "Conectividade" -Value ("{0} alvo(s)" -f $script:BlackboxTargets.Count) -ValueColor Green -Width 20
    }
    if ($script:EnableSnmpResolved) {
        Write-Field -Label "SNMP" -Value ("{0} equipamento(s)" -f $script:SnmpTargets.Count) -ValueColor Green -Width 20
    }
    if ($script:EnableInternetResolved) {
        Write-Field -Label "Velocidade" -Value ("Speedtest a cada {0} min" -f $script:InternetIntervalMinutesResolved) -ValueColor Green -Width 20
    }
    if ($script:EnableColetaResolved) {
        Write-Field -Label "Internet e links" -Value ("Coleta Complementar, {0} link(s)" -f $script:ColetaLinks.Count) -ValueColor Green -Width 20
    }
    if ($script:CustomExporters.Count -gt 0) {
        Write-Field -Label "Exporters" -Value ([string]$script:CustomExporters.Count) -ValueColor Green -Width 20
    }

    Write-Section "Arquivos"
    Write-Field -Label "Configuração" -Value $ConfigFile -Width 20
    if ($script:EnableInternetResolved) {
        Write-Field -Label "Speedtest" -Value $SpeedtestMetricsFile -Width 20
    }
    if ($script:EnableColetaResolved) {
        Write-Field -Label "Coleta" -Value $ColetaConfig -Width 20
    }
    Write-Field -Label "Log do instalador" -Value $script:InstallerLog -Width 20

    Write-Section "Atualização automática"
    if (Get-ScheduledTask -TaskName $AtualizadorTaskName -ErrorAction SilentlyContinue) {
        Write-Field -Label "Atualizador" -Value "ligado, todo dia entre 01h e 05h" -ValueColor Green -Width 20
    }
    else {
        Write-Field -Label "Atualizador" -Value "não instalado" -ValueColor Yellow -Width 20
    }

    if ($comPendencia) {
        Write-Section "Pendências"
        Write-Host "    O host está sendo monitorado, mas estes itens ficaram de fora." -ForegroundColor Yellow
        Write-Host "    Rode o instalador de novo e escolha 'Ver e alterar': ligue de" -ForegroundColor Yellow
        Write-Host "    novo o que faltou e escolha 'Gravar'. O atualizador é refeito sozinho." -ForegroundColor Yellow
        foreach ($etapa in $script:EtapasComFalha) {
            Write-Host "    ! " -ForegroundColor Yellow -NoNewline
            Write-Host $etapa.Nome -ForegroundColor White
            Write-Host ("      {0}" -f $etapa.Erro) -ForegroundColor Gray
        }
    }

    Write-Section "Diagnóstico"
    $comandos = @(
        'Get-Service Alloy',
        ('& "{0}" validate "{1}"' -f $AlloyExe, $ConfigFile),
        'Invoke-WebRequest http://127.0.0.1:12345/-/ready -UseBasicParsing',
        'Get-WinEvent -LogName Application | Where-Object ProviderName -Match "Alloy|Grafana" | Select-Object -First 20'
    )
    if ($script:EnableColetaResolved) {
        $comandos += ('powershell -ExecutionPolicy Bypass -File "{0}" -Acao verificar' -f (Join-Path $ColetaDir "coleta-complementar.ps1"))
    }
    $comandos += ('powershell -ExecutionPolicy Bypass -File "{0}" -Acao verificar' -f $AtualizadorScript)
    foreach ($comando in $comandos) {
        Write-Host "    > " -ForegroundColor Cyan -NoNewline
        Write-Host $comando
    }

    Write-Host ""
    Write-Host "  Próximo passo: " -ForegroundColor Yellow -NoNewline
    Write-Host ("confira no NOC (Explore) os dados de cliente=""{0}"" e host=""{1}""." -f $script:Cliente, $script:HostLabel)
}

# ==============================================================================
# MAIN
# ==============================================================================

# ==============================================================================
# ATUALIZADOR AUTOMÁTICO NEXTEC
# ==============================================================================
#
# A tarefa NextecAtualizador roda como SYSTEM de madrugada, lê o manifesto
# publicado pela Nextec, confere a assinatura RSA e, quando há versão nova
# liberada para a onda desta máquina, chama este instalador em -Atualizar.
# Ver Alloy/atualizador/README.md no repositório Scripts.

function Protect-NextecDirectory {
    <#
        Deixa a pasta gravável só por SYSTEM e Administradores. Obrigatório
        para pasta com script executado como SYSTEM: com a ACL padrão do
        ProgramData, um usuário comum pode criar a pasta antes, deixar ACE
        própria nela ou trocá-la por um link e assim ganhar privilégio.

        - Link (junction ou symlink) no lugar da pasta: o link é removido.
        - Dono fora de SYSTEM/Administradores: o dono passa a ser
          Administradores e as ACEs explícitas do conteúdo são descartadas.
        - A DACL é montada do zero (sem herança), antes de qualquer gravação.
        Usa SID porque o nome dos grupos muda com o idioma do Windows.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$LeituraUsuarios
    )

    $confiaveis = @("S-1-5-18", "S-1-5-32-544")
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warn ("{0} era um link; removido e recriado como pasta." -f $Path)
            [IO.Directory]::Delete($Path, $false)
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $dono = ""
    try { $dono = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $dono = "" }
    $donoEstranho = ($confiaveis -notcontains $dono)

    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")))
    $acl.SetAccessRuleProtection($true, $false)
    $heranca = [Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    foreach ($sid in $confiaveis) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), "FullControl", $heranca, "None", "Allow")))
    }
    if ($LeituraUsuarios) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-545")), "ReadAndExecute", $heranca, "None", "Allow")))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    # Links dentro da pasta saem (só o link, nunca o destino dele).
    foreach ($link in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        Write-Warn ("Link removido de pasta protegida: {0}" -f $link.FullName)
        if ($link.PSIsContainer) { [IO.Directory]::Delete($link.FullName, $false) } else { [IO.File]::Delete($link.FullName) }
    }
    # Conteúdo com dono e ACE próprios volta a só herdar da pasta.
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        if ($donoEstranho) {
            & icacls.exe (Join-Path $Path "*") /setowner "*S-1-5-32-544" /T /C /Q | Out-Null
        }
        & icacls.exe (Join-Path $Path "*") /reset /T /C /Q | Out-Null
    }
}

function Test-DotNetParaAtualizador {
    # O atualizador confere a assinatura com APIs do .NET Framework 4.6+ (release 393295).
    try {
        $release = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction Stop).Release
        return ([int]$release -ge 393295)
    }
    catch { return $false }
}

function Install-Atualizador {
    Write-Step "Atualizador automático Nextec"

    if (-not (Test-DotNetParaAtualizador)) {
        Write-Warn "Esta máquina tem .NET Framework anterior ao 4.6: o atualizador fica instalado, mas só aplica versões depois que o .NET for atualizado."
    }

    # Proteção antes de gravar qualquer arquivo. Nextec: só SYSTEM e
    # Administradores (estado, cópias de credencial). Coleta e Speedtest
    # também rodam como SYSTEM: usuário comum só lê.
    Protect-NextecDirectory -Path $NextecDataDir
    if (-not (Test-Path -LiteralPath $AtualizadorDir)) { New-Item -ItemType Directory -Path $AtualizadorDir -Force | Out-Null }
    Protect-NextecDirectory -Path $ColetaDir -LeituraUsuarios
    if (-not (Test-Path -LiteralPath $ColetaTextfileDir)) {
        New-Item -ItemType Directory -Path $ColetaTextfileDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $SpeedtestDir) { Protect-NextecDirectory -Path $SpeedtestDir -LeituraUsuarios }

    $temporario = Join-Path $env:TEMP ("nextec-atualizador-{0}.ps1" -f [guid]::NewGuid().ToString("N"))
    try {
        if (-not [string]::IsNullOrWhiteSpace($AtualizadorArquivo)) {
            Copy-Item -LiteralPath $AtualizadorArquivo -Destination $temporario -Force
        }
        else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-NextecDownload -Url $AtualizadorUrl -Destino $temporario -Descricao "Atualizador" -TimeoutSec 120
        }
        $erros = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($temporario, [ref]$null, [ref]$erros)
        if ($erros -and $erros.Count -gt 0) {
            throw ("Arquivo do atualizador tem erro de sintaxe: {0}" -f $erros[0].Message)
        }
        Copy-Item -LiteralPath $temporario -Destination $AtualizadorScript -Force
    }
    finally {
        Remove-Item -LiteralPath $temporario -Force -ErrorAction SilentlyContinue
    }

    # A configuração do operador (onda fixa, desligar) não é sobrescrita.
    if (-not (Test-Path -LiteralPath $AtualizadorConfig)) {
        $conteudo = @(
            "; Atualizador automático Nextec.",
            "; onda: auto (máquinas da Nextec na 0, ~10% dos clientes na 1, demais na 2) ou 0, 1, 2.",
            "; habilitado: sim ou não. Desligar aqui só vale para esta máquina.",
            "[atualizador]",
            "habilitado = sim",
            "onda = auto"
        ) -join "`r`n"
        [IO.File]::WriteAllText($AtualizadorConfig, $conteudo + "`r`n", (New-Object Text.UTF8Encoding($false)))
    }

    # Madrugada, com atraso aleatório de até 4h por máquina (01h às 05h).
    # StartWhenAvailable recupera a execução perdida com a máquina desligada.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Acao executar' -f $AtualizadorScript)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    $gatilho = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.AddHours(1)) -RandomDelay (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $AtualizadorTaskName -Action $action -Trigger $gatilho `
        -Principal $principal -Settings $settings -Force | Out-Null

    $versao = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AtualizadorScript -Acao versao
    Write-Ok ("Atualizador {0} instalado; roda todo dia de madrugada." -f ($versao | Select-Object -Last 1))
}

function Invoke-NextecAtualizacao {
    <#
        Modo -Atualizar: reaplica a configuração atual com o instalador novo.
        Nada é perguntado. Credenciais, alvos e links vêm da instalação atual.
    #>
    Write-Step ("Atualização automática {0}" -f $PacoteVersao)

    $configuracao = Read-CurrentAlloyConfiguration
    if ($null -eq $configuracao) {
        throw "Sem config.alloy da Nextec nesta máquina; rode o instalador interativo uma vez."
    }
    $inventory = Import-CurrentConfiguration -Configuration $configuracao
    if ([string]::IsNullOrWhiteSpace($script:RwUsername) -or [string]::IsNullOrWhiteSpace($script:RwPassword)) {
        throw "Credenciais do NOC não encontradas no registro do serviço; rode o instalador interativo."
    }

    $versaoAtual = ""
    try {
        $saida = (& $AlloyExe --version 2>$null | Select-Object -First 1) -join ""
        if ($saida -match 'v?(\d+\.\d+\.\d+)') { $versaoAtual = $Matches[1] }
    }
    catch { $versaoAtual = "" }

    if (-not [string]::IsNullOrWhiteSpace($AlloyInstaladorArquivo) -and $AlloyVersao -ne $versaoAtual) {
        Write-Info ("Alloy {0} -> {1}" -f $versaoAtual, $AlloyVersao)
        Backup-ExistingConfiguration
        Update-AlloyBinaryOnly
    }

    $script:ConfigChanged = $true
    Save-ReconfiguredAlloy -Inventory $inventory
    Install-Atualizador
    Write-Ok "Atualização concluída."
}

# ==============================================================================
# INTERFACE GRÁFICA (WINFORMS)
# ==============================================================================
# A tela só coleta as respostas. Validação, geração do config.alloy, SNMP,
# Coleta, serviço e atualizador são as mesmas funções do console: uma lógica,
# duas telas. A tela abre quando há área de trabalho; RMM, sessão sem tela,
# Server Core e -Console continuam no console.

function Test-NextecUseGui {
    if ($Silent -or $Atualizar -or $Console) { return $false }
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ((Get-Process -Id $PID).SessionId -eq 0) { return $false }
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { return $false }
        $tipoInstalacao = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name InstallationType -ErrorAction SilentlyContinue).InstallationType
        if ($tipoInstalacao -eq "Server Core") { return $false }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Cores da marca. Preenchidas por Initialize-GuiCores, depois de carregar o
# System.Drawing (no Windows PowerShell 5.1 ele não vem carregado no console).
$script:GuiCores = @{}
$script:GuiEscala = 1.0
$script:GuiFabricantesSnmp = @()
$script:ConfirmadoNaTela = $false

function Get-GuiControlesRecursivo {
    param([Windows.Forms.Control]$Controle)
    foreach ($c in @($Controle.Controls)) {
        $c
        if ($c.Controls.Count -gt 0) { Get-GuiControlesRecursivo -Controle $c }
    }
}

function Set-GuiEscala {
    <#
        Os layouts da tela são escritos em pixels de 100% (96 DPI). O
        PowerShell 7 roda com DPI do sistema: numa tela de 150% a fonte já sai
        maior, mas posição e tamanho não acompanham e os rótulos ficam
        cortados. Aqui tudo é multiplicado pelo fator da tela antes de a
        janela abrir. No Windows PowerShell 5.1 o fator é 1 (o Windows amplia a
        janela inteira) e nada muda.

        As âncoras saem durante a escala e voltam no fim: com elas, o controle
        ancorado à direita andaria duas vezes (pela âncora e pela escala).
    #>
    param([Parameter(Mandatory=$true)][Windows.Forms.Control]$Controle)
    $f = $script:GuiEscala
    if ($f -le 1.01) { return }
    $todos = @(Get-GuiControlesRecursivo -Controle $Controle)
    $ancoras = @{}
    foreach ($c in $todos) {
        $ancoras[$c] = $c.Anchor
        if ($c.Dock -eq [Windows.Forms.DockStyle]::None) { $c.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left }
    }
    $Controle.Size = New-Object Drawing.Size([int]($Controle.Width * $f), [int]($Controle.Height * $f))
    if ($Controle -is [Windows.Forms.Form] -and -not $Controle.MinimumSize.IsEmpty) {
        $Controle.MinimumSize = New-Object Drawing.Size([int]($Controle.MinimumSize.Width * $f), [int]($Controle.MinimumSize.Height * $f))
    }
    foreach ($c in $todos) {
        if ($c -is [Windows.Forms.TabPage]) { continue }
        switch ($c.Dock) {
            ([Windows.Forms.DockStyle]::Fill) { }
            ([Windows.Forms.DockStyle]::Top) { $c.Height = [int]($c.Height * $f) }
            ([Windows.Forms.DockStyle]::Bottom) { $c.Height = [int]($c.Height * $f) }
            default { $c.Bounds = New-Object Drawing.Rectangle([int]($c.Left * $f), [int]($c.Top * $f), [int]($c.Width * $f), [int]($c.Height * $f)) }
        }
        if ($c -is [Windows.Forms.TabControl]) {
            $c.Padding = New-Object Drawing.Point([int]($c.Padding.X * $f), [int]($c.Padding.Y * $f))
        }
        elseif ($c -is [Windows.Forms.Panel]) {
            $pad = $c.Padding
            $c.Padding = New-Object Windows.Forms.Padding([int]($pad.Left * $f), [int]($pad.Top * $f), [int]($pad.Right * $f), [int]($pad.Bottom * $f))
        }
    }
    foreach ($c in $todos) { $c.Anchor = $ancoras[$c] }
}

function Initialize-GuiCores {
    # Escala da tela (1 = 100%, 1.5 = 150%). Os layouts são escritos para 96
    # DPI e PerformAutoScale ajusta tamanhos e posições; o que é medido em
    # pixel na hora (largura de texto, altura de item) usa este fator.
    $script:GuiEscala = 1.0
    try {
        $tela = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $script:GuiEscala = [double]$tela.DpiX / 96.0
        $tela.Dispose()
    }
    catch {
        $script:GuiEscala = 1.0
    }
    $script:GuiCores = @{
        Marinho = [Drawing.Color]::FromArgb(13, 0, 53)
        Roxo    = [Drawing.Color]::FromArgb(92, 80, 255)
        Fundo   = [Drawing.Color]::FromArgb(244, 244, 244)
        Texto   = [Drawing.Color]::FromArgb(33, 33, 33)
        Cinza   = [Drawing.Color]::FromArgb(110, 110, 110)
        Erro    = [Drawing.Color]::FromArgb(200, 40, 40)
    }
}

# Do teste mais simples ao mais completo: cada nível confere mais coisas que o
# anterior. O número na frente deixa a ordem visível na lista.
$script:GuiModulosBlackbox = [ordered]@{
    icmp_ipv4        = "1. Ping: o host responde"
    tcp_connect      = "2. TCP: a porta aceita conexão"
    dns_udp          = "3. DNS: o servidor resolve nomes"
    http_2xx         = "4. HTTP: a página responde (2xx)"
    http_2xx_ssl     = "5. HTTPS: responde e o certificado é válido"
    http_2xx_content = "6. Conteúdo: a página abre sem erro"
}
$script:GuiSufixoBlackbox = @{ icmp_ipv4 = "ping"; http_2xx = "http"; http_2xx_ssl = "https"; tcp_connect = "tcp"; dns_udp = "dns"; http_2xx_content = "content" }

function Get-GuiSlug {
    # ConvertTo-Slug exige valor; campo vazio da tela vira "" sem erro.
    param([AllowNull()][AllowEmptyString()][string]$Valor)
    if ([string]::IsNullOrWhiteSpace($Valor)) { return "" }
    return (ConvertTo-Slug $Valor)
}

function Get-GuiClienteSlug {
    param([AllowNull()][AllowEmptyString()][string]$Valor)
    if ([string]::IsNullOrWhiteSpace($Valor)) { return "" }
    return (ConvertTo-ClienteSlug $Valor)
}

function New-GuiLabel {
    param([string]$Texto, [int]$X, [int]$Y, [int]$Largura = 640, [switch]$Dica, [switch]$Titulo)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Texto
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.AutoSize = $false
    $l.Width = $Largura
    $l.Height = 22
    if ($Dica) { $l.ForeColor = $script:GuiCores.Cinza; $l.Font = New-Object Drawing.Font("Segoe UI", 8.5) }
    if ($Titulo) { $l.Font = New-Object Drawing.Font("Segoe UI Semibold", 11); $l.ForeColor = $script:GuiCores.Marinho; $l.Height = 28 }
    return $l
}

function Add-GuiRotulo {
    <#
        Rótulo de campo. Com -Obrigatorio, ganha um asterisco vermelho logo
        depois do texto.
    #>
    param($Pagina, [string]$Texto, [int]$X, [int]$Y, [int]$Largura = 200, [switch]$Obrigatorio)
    $l = New-GuiLabel $Texto $X $Y $Largura
    $Pagina.Controls.Add($l)
    if ($Obrigatorio) {
        $fonte = New-Object Drawing.Font("Segoe UI", 9.5)
        $largura = [int]([Windows.Forms.TextRenderer]::MeasureText($Texto, $fonte).Width / $script:GuiEscala)
        $a = New-GuiLabel "*" ($X + $largura - 2) $Y 14
        $a.ForeColor = $script:GuiCores.Erro
        $a.Font = New-Object Drawing.Font("Segoe UI Semibold", 10)
        $Pagina.Controls.Add($a)
        $a.BringToFront()
        # O asterisco acompanha o rótulo quando o campo some (Set-GuiVisivel).
        $l.Tag = $a
    }
    return $l
}

function Set-GuiVisivel {
    param([Parameter(Mandatory=$true)][object[]]$Controles, [bool]$Visivel)
    foreach ($c in $Controles) {
        $c.Visible = $Visivel
        if ($c.Tag -is [Windows.Forms.Control]) { $c.Tag.Visible = $Visivel }
    }
}

function Add-GuiLegendaObrigatorio {
    # "* obrigatório" no canto direito do título de cada aba.
    param($Pagina, [int]$X = 690, [int]$Y = 20)
    $l = New-GuiLabel "* campo obrigatório" $X $Y 160
    $l.ForeColor = $script:GuiCores.Erro
    $l.Font = New-Object Drawing.Font("Segoe UI", 8.5)
    $l.TextAlign = [Drawing.ContentAlignment]::MiddleRight
    $Pagina.Controls.Add($l)
}

function New-GuiTextBox {
    param([int]$X, [int]$Y, [int]$Largura = 300, [string]$Texto = "", [switch]$Senha)
    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point($X, $Y)
    $t.Width = $Largura
    $t.Text = $Texto
    if ($Senha) { $t.UseSystemPasswordChar = $true }
    return $t
}

function New-GuiCombo {
    param([int]$X, [int]$Y, [int]$Largura = 300, [string[]]$Itens, [int]$Indice = 0)
    $c = New-Object Windows.Forms.ComboBox
    $c.Location = New-Object Drawing.Point($X, $Y)
    $c.Width = $Largura
    $c.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($i in $Itens) { [void]$c.Items.Add($i) }
    if ($c.Items.Count -gt $Indice) { $c.SelectedIndex = $Indice }
    return $c
}

function New-GuiGrid {
    param([int]$X, [int]$Y, [int]$Largura, [int]$Altura)
    $g = New-Object Windows.Forms.DataGridView
    $g.Location = New-Object Drawing.Point($X, $Y)
    $g.Size = New-Object Drawing.Size($Largura, $Altura)
    $g.AllowUserToAddRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.BackgroundColor = [Drawing.Color]::White
    $g.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::CellSelect
    $g.AutoSizeColumnsMode = [Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $g.EditMode = [Windows.Forms.DataGridViewEditMode]::EditOnEnter
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $g.ColumnHeadersDefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::False
    # Valor fora da lista de uma coluna de escolha não abre caixa de erro.
    $g.Add_DataError({ param($s, $e) $e.ThrowException = $false })
    # Coluna obrigatória: o título termina em " *" e o asterisco sai vermelho.
    $g.Add_CellPainting({
        param($s, $e)
        if ($e.RowIndex -ne -1 -or $e.ColumnIndex -lt 0) { return }
        $texto = [string]$e.Value
        if (-not $texto.EndsWith(" *")) { return }
        $e.PaintBackground($e.CellBounds, $true)
        $base = $texto.Substring(0, $texto.Length - 2)
        $fonte = $e.CellStyle.Font
        $flags = [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::NoPadding
        $area = New-Object Drawing.Rectangle(($e.CellBounds.X + 6), $e.CellBounds.Y, ($e.CellBounds.Width - 6), $e.CellBounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $base, $fonte, $area, $e.CellStyle.ForeColor, $flags)
        $largura = [Windows.Forms.TextRenderer]::MeasureText($e.Graphics, $base, $fonte, $area.Size, $flags).Width
        $areaAst = New-Object Drawing.Rectangle(($area.X + $largura + 2), $e.CellBounds.Y, 16, $e.CellBounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, "*", $fonte, $areaAst, $script:GuiCores.Erro, $flags)
        $e.Handled = $true
    })
    return $g
}

function Add-GuiColunaTexto {
    param($Grid, [string]$Nome, [string]$Titulo, [int]$Peso = 100, [switch]$SomenteLeitura)
    $c = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $Nome; $c.HeaderText = $Titulo; $c.FillWeight = $Peso; $c.ReadOnly = [bool]$SomenteLeitura
    [void]$Grid.Columns.Add($c)
}

function Add-GuiColunaLista {
    param($Grid, [string]$Nome, [string]$Titulo, [string[]]$Itens, [int]$Peso = 100)
    $c = New-Object Windows.Forms.DataGridViewComboBoxColumn
    $c.Name = $Nome; $c.HeaderText = $Titulo; $c.FillWeight = $Peso
    $c.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    foreach ($i in $Itens) { [void]$c.Items.Add($i) }
    [void]$Grid.Columns.Add($c)
}

function New-GuiBotao {
    param([string]$Texto, [int]$X, [int]$Y, [int]$Largura = 140, [switch]$Principal)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Texto
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($Largura, 32)
    $b.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    if ($Principal) {
        $b.BackColor = $script:GuiCores.Roxo
        $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
    }
    return $b
}

function Get-GuiCelula {
    param($Linha, [string]$Coluna)
    $v = $Linha.Cells[$Coluna].Value
    if ($null -eq $v) { return "" }
    return ([string]$v).Trim()
}

function Show-GuiEquipamentoSnmp {
    <#
        Janela de um equipamento SNMP: identificação, fabricante e credencial
        juntos. Devolve um objeto com os campos, ou $null se o técnico
        cancelar. Senha nunca aparece na grade: a linha guarda a credencial
        na propriedade Tag.
    #>
    param([object]$Atual)

    $f = New-Object Windows.Forms.Form
    $f.Text = $(if ($null -ne $Atual) { "Editar equipamento SNMP" } else { "Novo equipamento SNMP" })
    Set-GuiIconeJanela -Form $f
    $f.Size = New-Object Drawing.Size(520, 660)
    $f.StartPosition = "CenterParent"
    $f.FormBorderStyle = "FixedDialog"
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object Drawing.Font("Segoe UI", 9.5)
    $f.BackColor = [Drawing.Color]::White
    $f.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None

    $f.Controls.Add((New-GuiLabel "Equipamento" 20 12 300 -Titulo))
    Add-GuiLegendaObrigatorio $f 320 16

    [void](Add-GuiRotulo $f "Nome" 20 52 160 -Obrigatorio)
    $nome = New-GuiTextBox 200 49 280 ""
    $f.Controls.Add($nome)
    $f.Controls.Add((New-GuiLabel "Curto e sem espaço. Ex.: fw_matriz, sw_core" 200 74 290 -Dica))

    [void](Add-GuiRotulo $f "IP ou FQDN" 20 104 160 -Obrigatorio)
    $endereco = New-GuiTextBox 200 101 280 ""
    $f.Controls.Add($endereco)

    [void](Add-GuiRotulo $f "Fabricante" 20 142 160 -Obrigatorio)
    $fabricante = New-GuiCombo 200 139 180 @($NextecSnmpVendors.Values | ForEach-Object { $_.Label })
    $f.Controls.Add($fabricante)
    $f.Controls.Add((New-GuiLabel "Fabricante fora da lista? Solicite ao NOC a inclusão antes de cadastrar." 200 164 300 -Dica))
    $f.Controls[$f.Controls.Count - 1].Height = 34

    [void](Add-GuiRotulo $f "Tipo" 20 204 160)
    $tipos = @("firewall", "switch", "storage", "ap", "ups")
    $tipo = New-GuiCombo 200 201 180 $tipos
    $f.Controls.Add($tipo)

    $f.Controls.Add((New-GuiLabel "Credencial SNMP" 20 244 300 -Titulo))
    [void](Add-GuiRotulo $f "Versão" 20 284 160)
    $versao = New-GuiCombo 200 281 280 @("v2c (community)", "v3 (usuário e senha, mais seguro)")
    $f.Controls.Add($versao)

    $rCommunity = Add-GuiRotulo $f "Community" 20 322 160 -Obrigatorio
    $community = New-GuiTextBox 200 319 280 "public" -Senha
    $f.Controls.Add($community)

    $rUsuario = Add-GuiRotulo $f "Usuário" 20 322 160 -Obrigatorio
    $usuario = New-GuiTextBox 200 319 280 "nextec_monitoramento"
    $f.Controls.Add($usuario)
    $rNivel = Add-GuiRotulo $f "Segurança" 20 357 160
    $nivel = New-GuiCombo 200 354 280 @("Autenticação e criptografia (authPriv)", "Só autenticação (authNoPriv)")
    $f.Controls.Add($nivel)
    $rProtAuth = Add-GuiRotulo $f "Autenticação" 20 392 160
    $protAuth = New-GuiCombo 200 389 120 @("SHA", "SHA256", "SHA512", "MD5")
    $f.Controls.Add($protAuth)
    $rSenhaAuth = Add-GuiRotulo $f "Senha de autenticação" 20 427 170 -Obrigatorio
    $senhaAuth = New-GuiTextBox 200 424 280 "" -Senha
    $f.Controls.Add($senhaAuth)
    $rProtPriv = Add-GuiRotulo $f "Criptografia" 20 462 160
    $protPriv = New-GuiCombo 200 459 120 @("AES", "AES256", "DES")
    $f.Controls.Add($protPriv)
    $rSenhaPriv = Add-GuiRotulo $f "Senha de criptografia" 20 497 170 -Obrigatorio
    $senhaPriv = New-GuiTextBox 200 494 280 "" -Senha
    $f.Controls.Add($senhaPriv)
    $f.Controls.Add((New-GuiLabel "A credencial fica só neste servidor (snmp-auth.yml); na tela aparece mascarada." 20 530 470 -Dica))

    $erro = New-GuiLabel "" 20 554 470
    $erro.ForeColor = $script:GuiCores.Erro
    $f.Controls.Add($erro)

    if ($null -ne $Atual) {
        $nome.Text = $Atual.Nome
        $endereco.Text = $Atual.Endereco
        if ($Atual.Fabricante) { $fabricante.SelectedItem = $Atual.Fabricante }
        if ($Atual.Tipo) { $tipo.SelectedItem = $Atual.Tipo }
        $cred = $Atual.Credencial
        if ($null -ne $cred) {
            if ($cred.Versao -eq "v3") {
                $versao.SelectedIndex = 1
                $usuario.Text = $cred.Usuario
                $nivel.SelectedIndex = $(if ($cred.Nivel -eq "authNoPriv") { 1 } else { 0 })
                $protAuth.SelectedItem = $cred.ProtocoloAuth
                $senhaAuth.Text = $cred.SenhaAuth
                if ($cred.ProtocoloPriv) { $protPriv.SelectedItem = $cred.ProtocoloPriv }
                $senhaPriv.Text = $cred.SenhaPriv
            }
            else {
                $community.Text = $cred.Community
            }
        }
    }

    # Mostra só os campos da versão escolhida.
    $v2 = @($rCommunity, $community)
    $v3 = @($rUsuario, $usuario, $rNivel, $nivel, $rProtAuth, $protAuth, $rSenhaAuth, $senhaAuth)
    $priv = @($rProtPriv, $protPriv, $rSenhaPriv, $senhaPriv)
    $atualizar = {
        $ehV3 = ($versao.SelectedIndex -eq 1)
        Set-GuiVisivel $v2 (-not $ehV3)
        Set-GuiVisivel $v3 $ehV3
        Set-GuiVisivel $priv ($ehV3 -and ($nivel.SelectedIndex -eq 0))
    }
    $versao.Add_SelectedIndexChanged($atualizar)
    $nivel.Add_SelectedIndexChanged($atualizar)

    $ok = New-GuiBotao "Salvar" 260 578 110 -Principal
    $cancelar = New-GuiBotao "Cancelar" 380 578 100
    $cancelar.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $f.CancelButton = $cancelar
    $f.AcceptButton = $ok
    $f.Controls.Add($ok); $f.Controls.Add($cancelar)
    $f.Add_Shown({ & $atualizar; [void]$nome.Focus() })
    Set-GuiEscala -Controle $f


    $script:GuiEquipamentoResultado = $null
    $ok.Add_Click({
        $n = (Get-GuiSlug $nome.Text) -replace "[-.]", "_"
        if (-not $n) { $erro.Text = "Informe o nome do equipamento."; [void]$nome.Focus(); return }
        if (-not (Test-NextecHost $endereco.Text.Trim())) { $erro.Text = "IP ou FQDN inválido. Ex.: 10.0.0.1 ou fw.cliente.local"; [void]$endereco.Focus(); return }
        if ($versao.SelectedIndex -eq 0) {
            if ([string]::IsNullOrWhiteSpace($community.Text)) { $erro.Text = "Informe a community."; [void]$community.Focus(); return }
            $cred = [pscustomobject]@{ Versao = "v2c"; Community = $community.Text }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($usuario.Text)) { $erro.Text = "Informe o usuário SNMPv3."; [void]$usuario.Focus(); return }
            if ([string]::IsNullOrEmpty($senhaAuth.Text)) { $erro.Text = "Informe a senha de autenticação."; [void]$senhaAuth.Focus(); return }
            $nivelTexto = $(if ($nivel.SelectedIndex -eq 0) { "authPriv" } else { "authNoPriv" })
            if ($nivelTexto -eq "authPriv" -and [string]::IsNullOrEmpty($senhaPriv.Text)) { $erro.Text = "Informe a senha de criptografia."; [void]$senhaPriv.Focus(); return }
            $cred = [pscustomobject]@{
                Versao = "v3"; Usuario = $usuario.Text.Trim(); Nivel = $nivelTexto
                ProtocoloAuth = [string]$protAuth.SelectedItem; SenhaAuth = $senhaAuth.Text
                ProtocoloPriv = $(if ($nivelTexto -eq "authPriv") { [string]$protPriv.SelectedItem } else { "" })
                SenhaPriv = $(if ($nivelTexto -eq "authPriv") { $senhaPriv.Text } else { "" })
            }
        }
        $script:GuiEquipamentoResultado = [pscustomobject]@{
            Nome = $n; Endereco = $endereco.Text.Trim(); Fabricante = [string]$fabricante.SelectedItem
            Tipo = [string]$tipo.SelectedItem; Credencial = $cred
        }
        $f.DialogResult = [Windows.Forms.DialogResult]::OK
        $f.Close()
    })

    [void]$f.ShowDialog($script:Gui.Form)
    $f.Dispose()
    return $script:GuiEquipamentoResultado
}

function ConvertTo-SnmpAuthYaml {
    # Mesmo formato de Read-SnmpAuthDefinition.
    param([string]$Nome, [object]$Credencial)
    $linhas = @(("  {0}:" -f $Nome))
    if ($Credencial.Versao -eq "v2c") {
        $linhas += "    version: 2"
        $linhas += ("    community: {0}" -f (ConvertTo-YamlSingleQuoted $Credencial.Community))
    }
    else {
        $linhas += "    version: 3"
        $linhas += ("    username: {0}" -f (ConvertTo-YamlSingleQuoted $Credencial.Usuario))
        $linhas += ("    auth_protocol: {0}" -f $Credencial.ProtocoloAuth)
        $linhas += ("    password: {0}" -f (ConvertTo-YamlSingleQuoted $Credencial.SenhaAuth))
        if ($Credencial.Nivel -eq "authPriv") {
            $linhas += "    security_level: authPriv"
            $linhas += ("    priv_protocol: {0}" -f $Credencial.ProtocoloPriv)
            $linhas += ("    priv_password: {0}" -f (ConvertTo-YamlSingleQuoted $Credencial.SenhaPriv))
        }
        else {
            $linhas += "    security_level: authNoPriv"
        }
    }
    return ($linhas -join [Environment]::NewLine)
}

function Get-NextecIconeJanela {
    <#
        Emblema da Nextec em .ico (16 a 64 px) para a barra de título e a
        barra de tarefas. Embutido em Base64 pelo mesmo motivo da logo. Se
        não puder ser montado, a janela fica com o ícone padrão.
    #>
    # Com Set-StrictMode, ler a variável antes da primeira atribuição é erro;
    # Get-Variable devolve nada nesse caso.
    $atual = Get-Variable -Name GuiIconeJanela -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $atual) { return $atual }
    $base64 = (
        "AAABAAUAEBAAAAAAIACFAgAAVgAAABgYAAAAACAAUwQAANsCAAAgIAAAAAAgAEMGAAAuBwAAMDAAAAAAIACZCQAAcQ0AAEBAAAAA" +
        "ACAAag0AAAoXAACJUE5HDQoaCgAAAA1JSERSAAAAEAAAABAIBgAAAB/z/2EAAAJMSURBVHiclZLPa9VHFMU/585830sMEelCEBQq" +
        "ii1CqUiLtiC6sXmJqCBk043/gIKU0pXw8sB1SxFEadduuiiIyFNbcF2KIroSFwqKYCzYHySZ7/c7c7sI3yQKLjwwMJx7557DnSPe" +
        "EzMsfxhkZ4W+dvdZe7Pstnre4ARDm+G/bXNqLgbFPyO9bwreM9Kzt5pVQGUeD6sPYQA9WHAUvpsknimUzQ5Nwe9dZ/OruK4i/4ql" +
        "HSKFX9CTjh+jBGDUhxM0RqwqoHVugWvNwTweTHaj0vTDWaULR3mxFeRzLA/mVI+FPi3kCsrdZa9PO/0fATTEbYTKUZZ3RoVHIsYK" +
        "kagfoeZq5VMLDjjFC+1T96cfj9mTOmG7AwYg/ItIZYW6biCD9+XxpICWeilgyuTxmD1pgPfXBnSXgD4IYCL0RDZhS07zWyE/F5rI" +
        "5BKpPhvw+vMx1N2S1S1rHuwf0rGgcAnYBjLQ40y6bsTTYFsCQU72xtPBW0z9MY+HNQcvQTeZuFbIzwLRCnklYLuFjjhlErxk2lwo" +
        "ybFFgL2djQ4DXu+SNj0U1o8E1aQlJ/9gVN9Gqr4DLSv3xz65r/t6g6GdYHF6wMo509RtYX3hdUv7U/bmwE2fOu9e9mfaq2FV53eA" +
        "wxDWlbVy+ZTcZ5XKcXkzUPq1qw03RHuW9MmXLE6vhw8iDE3oUIIaqHoQa/c7q3EmjFDdDRmhBxti7wCa4e+PTBMPKnpVQ/Mc/Gf3" +
        "3vdj+HdjY+dmBL6Ri6K3PWB/NV5faakv3Wb6Je/ACJW3uf8B0qr/e4DTMqsAAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAA" +
        "GAAAABgIBgAAAOB3PfgAAAQaSURBVHicpZVdiFVVFMd/a+99zp0P7UOmCUmiejBMk8goMmRgcpxRQyq6JEFkJAUFBdFLCJpPPRUU" +
        "VlRQUE/NRE9BUwY2RAqFgqZjPhiRgeVDMSP345yz9149nHvvHCcVyfV0OHuv9f+vtf5rbbhKG0Fd93s9J5eO03rhIfG/TkhzEsBd" +
        "2vXKbAbxY5wfTkieQuxOwa10QIEcvUoAlTonknm5dbel9pzDDgUgkOeWNBGN+wHMxVzrqK2j9lKhyzPROW4Z7WdgF8hQQe4jeRRI" +
        "AgFP8eMlMlCZQgLAHtQA7EVi9cZ5cKARaW6IECI+CJKCesFJoPinj8bsRQBUQHQTc+stiexFfugynoIICKDTSFam394YO5kqGiyp" +
        "qwENdPpLbmrWUSvVtKeQMM7c/Ylcc1BRFP950Pz1r1lypEpjgtaDRuzLgt0S8CoYcTgCxS9ofK/B3EczDDehIrFzJTvE2E1GIafI" +
        "U9LHEHl4C+1Po4bdEJc56dsHboMAnlwFwUAWtP3Sb5z+eJY1eZVMD2AYtKySvUdRBDE5eQDMILWnG9IcVGyS4jY0yQs6AklIbEHr" +
        "0DQD70M5FzMQQBR6KiobW+d4CrI2lqU2gliBmJUOTYO9PQMvYDtnKmUDDtTR9A6OpzOI7wbvAezplGeOFXdaajdHct9pKICNRBvE" +
        "nwRWGXA9bwQFAn52CslXszqwyCpzoKK4AOHvhNQJPQGoAXUxGYqaPR8JJx2pUVRBbaDQRPrfmKDx7Dm+6ySlPfFIFQBERzizYlCG" +
        "XwGzU9GBbmscqUTCoUIbHzrp225xYwVeBYyQkgAZren7tH/rXtBumSoACyAAE9L6JKXvyYLcgzhFfR+pa9P+WYknagxsz8mDIBbU" +
        "W1IJZMe+0tq6Dvdqk3sJ6Qjq1qEJyG1KSaXLxEOuxLOCuStAkApBAzai35QxsJX/C+zXoUmpgsMJyNpARMCAerDOQQp6CmS5LYNE" +
        "RWOvHhoPQkXyFwKIHkaKUf68cVjWvOlIlkZ8BCNl0+N8m/bb5/XMLtHiUY8/lJA6S2oES0GRF7QOA0zxWg+g03Gj4/y13Mi1Lwry" +
        "jCW5wZNHEBEkU41vFTTe/ZZlv1cLOk5rhxX3ag23skV2YFr7RkvRXbAcVeocTyekdewRUd0iQSck85slK7aJ6ri03+ne7KxwqTNp" +
        "u1Ic4+zgVtrbRpgfWhBKpS4AG5lfVZMlsxHvOwyMEouEmiu09fhS+r+4HswHSFF17i5ILmMGwOHutoiCdheSd9SSCAL5kSkkLIf/" +
        "BCqDq5SZqSw+7wEg3AuoQnSkJiF1EX8q18aOaa47DSqLH51KEbQEWtg/VXOwx4A8IGAsaRrxPwUt9il/fLaflVl1+P6XjXDAjUvr" +
        "+62Sz24mewIme0NyuXf5Su1fzujW8dzjhFkAAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAAIAAAACAIBgAAAHN6evQAAAYK" +
        "SURBVHictZdNbFxXFcd/59773tiJa6eJoEWqEkBFiixAFEpJEHRCSY2LU7UCDUIFBAI2oAJiURZZYKIKJFhFhQ1qVxWrGIQUBE0c" +
        "0jABkgpVIIpqKCiKIhSo8tnYHcfz7sdhcZ/tmbHjAk3PZjT33XvO//9/5+M+eMNMpYm63pVJOg9OSrc9JeH8/czfC+DWP/z6rIXa" +
        "GSS2IYxzqNzOvk+I2K8a3IfB4ICA2/EGAVCZQeJezowV3P45keIrjmJcgUClYLRCY6L7OwBzM0NPowZEJ1n4bEN2/KWQTT80FOMV" +
        "VfR0k4JanFHimQ+y5RwIcvPCq4DoFOdujXLb+YLGcKDyClaQmqiGgtJ1WXz6qG7+fBN1GykgTdQ1OeGy842tVatZsfUuSzkc8AGk" +
        "WA1eQwAV1ZPL/zfKAW0jYTVATqwbbV4AB5oMnV0WIaHQJ7Am8roo3ecA9kBaRwEVUGlxyE6w+MgDLD4CrTq4Sgu1/czVTqPmCNIF" +
        "URE3lVC0jq5oUlIUCjNE4SLd00tsfQlUDiBpjbTLTCek8/3NbPpWACLdPyWN3zvC5p9CTrYDoCC6fG6S+aZI4zFDMRXxKogoqpZS" +
        "LBDw/0wankpUP5pl7Go+Jeu/2xaH7ILs+7tleEekio6yFCBQnVT13z3CyGy9VR6g85CI+5pQ3mcAT9UTvBAlnFGNBxdZ+kmbW18Z" +
        "jNUHIDOTdD//fpuTbX8F04CkiiooBQ2jQKT6ZVevfqmU0f1DDH89q1SpQhLEKposThLh/KKevavNzksATdS1IfYq15cDcyuARt/j" +
        "KBpKjIAIYgRjPFUM+FhSTlka+8B8ykOKVAFEBLE1q2QxkgjH2uy8NIk2QCUn9WpwGKiCCzUAgV2Sf/s2CxjBSZfuZQMi2DclvICs" +
        "X02qp0Dl+gDrXutTYA8kABF5n8JKJq/4A7V56SUV944CJ4r6wahgXEUVA+HZ1mt0256HuSz2cmVMMLsjKa2jQDKAEl9USXMWjKMs" +
        "FR3oD6oGowWyMw8lCblNbwhAFFSGuO4hnXAYYymdknpBWE9QS7nPJje/qAsPJ8IfSkqbmWf9atzWyPDhj8vSk02uvvUAktbrqIML" +
        "Qn16gvlPOhnabyjeG6k0OwZQDAUGIeJ/4bVz0NL4kJXGdCIOkIKCgki4FvT6F49yy89bYHo76qAsNQuVWUZ/9iv9zD2BpacdhazK" +
        "LCS8errJUTzoZPjXie4LkdAVrFlVIpunWipwY1C8H0QvDJC+QYKI5tKZiYl0TvLY7HEsIhjxpKjIZTC7LcVwIqRVpVYYlQElEY4B" +
        "vHkgr26YoR8ADyoGs2f9ilC1GAPpHyJmm0USA85zMhbGU80nrv0ZYKautA0BtFA7B7KL00Mg4xFF+itGBbwDUdJZcO80+XnsfQUK" +
        "KZetvnCcOy5TX1h6Y/U1kGnUzIEsJ8nHWHjYUW4L+JTnumpusw1roREIF0X9QUXe4sU9UVLuCCQSPgrGSj1alXAKoAmmPaBAD4Dc" +
        "BwAmuLjTyS2PgvlyIiZZ6ZBWCqz1+PNRwpPX08KP29z2MkBTz57cJLd/U3DfKGmMeTxZEVzS9HtY+/6zzzo4iN7HpfGGjDwmmE87" +
        "iiFPoD5TF7B0VP3jkUtPzbL9Sn3WtHpU+ygvv72ULfvBfKFBYZfo/str993HGa33978CWZ7te7l4ZyFb/lhSjFQEIAXA1o0l3+W0" +
        "8+2jjDye5RycbCpNsMu3qL107h6m2P0qrx4+wdZzyyQHFXC/AQMSLJ2JHLzbBSn7B4yYiKLE4/mOuIfe69oyszYEmDYtviMzyPPA" +
        "870KDwaHnswWMfdorjbbX8uqgiFSvQLX/tbmIyEzv5EdSDNInEZN/jJam/l9ALIzFUXvTnnnCihFo0IosUbRF2fZfmX6NRyuwEBS" +
        "Pf/TRvsMiE5w5Q7B3plIZK00gmpBaR1lUVH9NunSo//N9fx/NQeQaLyrQVl6Ki+YosTZBESqWVV/8BlGnllltraUXjcAK3KvBRJl" +
        "oXgfqA577T5xjNH6A0LrC9LGcv7fAFR0Lmq4EAmnVKsfHGXsNKzpjDeV+bL9BxRb4nWe+0dUAAAAAElFTkSuQmCCiVBORw0KGgoA" +
        "AAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAJYElEQVR4nM2Za4xdVRXHf2vvfc6908fUBtvSVimNDba1omSgiCJTHm2HAMZIJpQQ" +
        "FY2CEfCLCWiiDPWDCQgSiBpSJE0QQ2Bi1A8aCtT2IiCVV7SlPJOWGmnpg5l2Oo97ztl7+eHcMzOdzn10MI7r471n7fP/7732evyP" +
        "8H9oPajZDdKLeIAvsnfhLFlwo2A3QBiq6sCNW5n3Yg9q3HSDHW/dqF0JuhEJAOt4f5mh/dsi5muO+HSPp0SEF38zyte3w/8HgW7U" +
        "9kIodvwyDp3rZMZNgrsmIm7zQEo1COIzrEX9m4XvNBNQAaMF8LUMXGLF3WKwX3JEJsOTkmSAFYwBCKgJpBWA+aDTSEAFRAHp4tjV" +
        "IvHNhlKnATJSEqpeEANSw6hqiExG9fBRjuwE6IVgpg88rOat9i4Z3BLL7F5LqdOTaEriAQRjQWTUA4JBgPDq3znrWA9qQHRaCHSC" +
        "BdE5LLi+jRlrE5IkI/GCiCB2Mh8pWGt4HmA7GJimOzAfFEDEXpJBEDDUAV6YggmA4p8bv8Y0EFDpRXwn28qC6QhgFJDGPmqITMrI" +
        "sSoHXoU8/qF2DK1YD2o6UdeJujz+pmY9OVZxfGqFxS0OpJpf1gbwIVhEhfCPCssP61gCaPUEekytuASACqO5W6kVnVZtB29HIFVL" +
        "+VxHJHmalAY4VAVSA2XVsANgDVgga5GACki4hP2ryzL3WwFIdeDBXuRFxoiEYkfqWTdqAXqRKoCR6KsBRcenmgnAAQ/GxbhyQtKf" +
        "MrAZVCq1jYQmodfN47aX7rCegQuttG11uAggIw2K/02qfXc+zaLXATpRVwE/kchEguvoX22ldLulfIUnCZwUPjlwIXIOISUdEsJj" +
        "g3rkrgqL3xhXP5oTyEFJtl6OP1pm5oaEZARwIC4iIiUdhuzBVPvueZrF+3Kfba7CxdnY8vm7uji+TiT6nmCusDhSkjAx9jW/rJID" +
        "Tw4r6cOZ+geeZs7b+RM9BjaeELKNLz8qcIesl9t2RrStyEhGL5wSvGBtlIPpV81+MUz/fRUWHx4HXLoYuEbE3WIpf17y00NRPzHf" +
        "K0EtsQTSI0H8PSPh/c0Vlh4Yd4qT3rcGBNSAhE72nNkmC980uFjxE0K2OG7nHIaM9L1Mh39+hLfvn0e7UVnUW2bmVR7ISEK+I5Pl" +
        "e1XBAr5vWA9ctI0lrzUDXljd9NVdI1fmtM9ElOKA9yffNxEQp2SaZxO7aJa0330ay7oz5l44g5lXVUmLKmvqVVnAO6x4kj9uY8lr" +
        "XWipqBfNslxdAgdrBILo54S8lNdfJicSyBIPXtHYMKMzQBC0EfBRU0A1/BXUDE+SDE6ZwJrRSudWa/6CJvcFBIky1HqO/lPEXFSr" +
        "si0UPeMyMh9IXwAJa8alySkSUNmIhE52zRLMqoAiTatvnkE8yX5IRgzmHE9AmhBXNBgcgeTdPva+A7Cxxd2vS6C79nvEguWGaH4g" +
        "UzBNgBBsDuglYc4ZjnhWIJvk3pxoMuoXnruSDt+BRjQM1xYIFPFvKZ9vsR7UN1torN3NtiumHOeMRZv4ajHVIG0bkfAyknairlhu" +
        "SgRGQYk9KwKrEBRtGpf5tsnSvzDvD4MM/UwQYuKG/oLYjEQtpasvl8GH1rJ/aQXJQLSbx5te/jos1QB6GYeWxTJ7s6X8BQXydIhp" +
        "EBYqiAbSh47qez9yuJmz5PSfWkobADxJ/dYH1YhYMtKjSvW+IX3n3grn9E9sHVokUMNSc+xiYIOR6IeO0tkeCCQNXSMiMpLhQLj7" +
        "3/rSvaezcmUkszcJZoXH122fleANkXUYPMm7qY7c/CTtf+oB2VinHrTQSgCIruTx+OOm65tGSz0GsyAQ9ORGbDwQZyMsnrSvqsPX" +
        "Vflg72w5c3doeAoAqgppiTiuMvTGEzpzRaNTaJIaRfNYVNtNd7YltD+Qav/1gmuY5wRjFa9VksQSzbUS32kpzWstuYgANkBQ5A0Y" +
        "y4pTIJBbL+K3g+lGrSWuKtq8qtWAKEED2cuOtvNd7tVqRjNB02dgLCtOmUBheW8SXWhrXUZrQIyohletxB2tVnTAegJK+jcYG+An" +
        "s5YJjCkJnMcpAMkIwPC/wJ7nAWn6zqCGWDzJwZQDu2BsgJ/MWiUgvRjfyZ6yYj9bi4FmCUAFpxnJAYhKBnemJ2lamRWpqW36SoVV" +
        "xwsB60MRuAF1EMQRnWFwH2umJCgaFNIYYyC8BskuQUxEbBX1jYpiUdGDZM/CmIA1JQLdqFVUNiEpiDqZ8wOHM/UA5MDVO2ITE8cJ" +
        "ye5UB299ioW7RvSDizOqz0TE1hIb0Kw2EJ2EKQCE6vPQOP5rhCcH3ovxY/Ns/zqR8q2W0qWTV1NVBXXERgDPyE6v/v4RDj1SYelI" +
        "D1rIMqyn/1ojbbdHxMszFCXNyKVGqYWdeJK+QT34iWdZ0tesEk9yAsUkpKyj78uXy8h2J3O2OEqX5mPhSeARInHExlPdUdWj172v" +
        "D3dsYdavx4PP+xqVLXzk0YO6paOqg7dCdjAidnnfpxmQWIwK4fVnWdLXLP4nOYGc7Tr6r3FS/r6hdJ4Aad15VlUwgB7KdOS7T9L+" +
        "u+KfenpR/nvx6ejgwpky4zZD/B1HVMq3A0b0+LVPMeuxbjDFs00JFAuv59iPyzL7J/kgXg0gdQbxPOYdkanqB195io/+fky8aiZ0" +
        "qXSCzbtOWMv+VVbm3mQws6s68MhWTnuiWehMIJA/fCUvzUhl5T5H29yQh0sTyS8ST7VvQPcuWczyoVOXGlUm3+XWwEPtDtQEV4Y5" +
        "45OWaG4glcbgRwVXgN3Ps2Jg5RR0UhDtRXwhHOc9l9pWwUNNG92eEwmOcofDmeaC62i+VvAvjl/j1AjkNl44PlU7MQuJXNCqY9HX" +
        "BM12TOXF/y0zALkoiwi2I/8K0kiBUAVNLbHLSEgYfqG2xpR28MOayQVT0UvYtwjMWYGATNqvqIJmQiQRcQTZgNfqjRUW7q3l6+kh" +
        "0MkaA2CZebaj1BbITihWeXsQvCGWiNgp2eGEobuG9NCnn6R907iPH9Ni7jizBUAorTbkOg1Q9Dtqia0FUpL3vKablKFNW5i/H04s" +
        "StNl7ko6/MuAEblAa3ECGhyxMTnwPV7TX6Xs27yVlUeg+G5wR5hu8ECh/Kl0yeBbMTOW1YYOAtWdXv0vR9jz2wqrjkP9rzDTakX5" +
        "X8fRb1whyZ7LZfiVLvpvWMafS8Uzp6KU/a/tP4//iVUxFHgpAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYA" +
        "AACqaXHeAAANMUlEQVR4nN2ba4xd1XXHf2vvfc6987DB9tSAbRwHbCBQaMFgGwJcg42LEYVE6hDR8qGlJmrTZ2hLqVRlmFal8KEJ" +
        "ESJqqlRVG1VFTBMpVBS/xyPzNIaAAk4wYAoETE0Cfs3jnsde/bDPnZfnce8dB4b+v8zVmTvrrLX26/9fa4/w/woqFbB9mAwUgPV8" +
        "sC6Stt8zuHOU7MCg/vTPe1lxABAQ/8n6e9KgUkHdqAdmPR/ctFEGNt8gif91Ub1BVL8gqtdL/2aALtQAmE/E35OGLhMCF+1DspV8" +
        "u3UDH/3ORhnc0yIdP3C0/JqCpFS9kmQZeEVOA+gupoib+gWzE12o2QfSg+R9dPt17FtgWfzbTuIvW8rnKJCSeEAFsYIxoN6AgfQJ" +
        "gLBUyD5VCahN2+5i7VY4uKxM+yYr8e2O+IwcSElyQAQZM7sVRAE02x2e7AJAPi7nZ4ou1NQCv5b3L4pl7lcM7lZHNDcHcqo5yAmB" +
        "1yAYPHnSrwfP282yN0ENiP+UzIAu0434Cu9d2irz/lKwNzuiKMOTkmSAFYyd7K8V9RZrcqr7d/Mvb4EOnwCzfhPsRC10+2s5tLFN" +
        "FjwZUf4NhSihmiuZgjiQKWeygDeAavYsdPsKDCdr1iegB3yFXhdJ6wOWOE5IEoAw4lMHXoOiEn76J8b/blYnIGx6osqyFYZoeUaq" +
        "gsSNWVEVrElJ8pzBPQB9MEyAZnUCdhX+lTh1tSM2ijbM3BTU4sSTvZnz6v7wNBwIMMsTsLAgK0bclQJIjd82gNr6B93TxzVZ2FP4" +
        "dCSgBzx0GZDVHtAZ+KuaPAFwaNzR36TBsdw7fNaTzCnUgLCO25cJ7pycHGmOt9iMTHMGngFYO2r9Q1MJUKlx79qT8Fk0TK+Tk4jO" +
        "QNPV0HZJRClWsrzeXX8EPrXEkpO+GzGwD1S6xy2jBolQCL5Cb3sLq+4SsTcJmFyzR/o58FAP8lFwXm0PkjdmO6CTRyx00oMkgLHS" +
        "8qeK1/oHX1XBCxhHKVIU1eTuLZxTncivBjIaRrbCK20lWba1lbbL08KAAVKG3vGa/MMRtvzTM9wyCEInvu5EdKL2fNARuvvORSX5" +
        "pfsdpetTEj8ZxR0buHrBWofD4/FUdyR69L4dnL69Rn3H/1XdCaigrg/JruNnv9smC75TJakqRIURb4idDYn4ideh+7cw77tADiqd" +
        "YCZOxIm/u44Pr3ZS/kOwX3TEbvrgVYFccM5hyEgyT/6DTA8/uJ1FfTBWR8w4ARvk6HfLzPnNIDdl1BLyquAdJSshEXsz7f/77XR8" +
        "v+YEjCi52nKq+bGBj262UvoDQ3m9RUjJUHwuyKQcPwRvJMKRkhxXkv/I9ci3trHkRQgM8JZJkx9Q9x7QBzl0GcH+qgejjM+eEQGb" +
        "FTrcUb7USfl7GxnoTfTovd3I9sJpQ6FOK3S5MnfeZqT0R5bSJQJkJJoXa3i64AUrSpYm9D+Q6pF/3MFnDkCtXtAjEgKfcgnWOQO6" +
        "DHT79byxNJJF+4WopOQ61a6seA9CRGw8imfo0aoe+budnLFHUVnFj+fPl898r0xrJQ+BDxcwpvdHFYwKPh3SQ1/cyZmPw4n7SD2o" +
        "6xjs5B4BEOb+iqNc8uTTHkmCMYKYlCT3pOpoualFOp7ewOEvCaLzZPF9LbRWqiRJVqzz+oIHII9wJmXoP3dy5uOdaAxqepC8keCh" +
        "zgTU2JOReHWjlDQEJZJRrTqcEXFfCs+jjSneA276HX4sameiaL61CzWHwDdb4a3rxWsL9qTY1TrKgcYgVkFVspeuYt8ZFrfI40Ua" +
        "JmOqgrEJSe4Zeq4b8WvHsbtGUMfLVUI15uV2wVzogcadHk6aZD7Z2cLCKyIiUXLfaC4LdYeSH9jOt1+DkQpvM5g2kE56DEDE/PMs" +
        "8UJPOuXmN/mLrE1J04T3XxYprQuniMxA3WV7oLtQd43bGfFrGhyiM6x/Spc4rIA2THEV9QaLkr3+BBd9BLYyU3WXazqhumsU9Tsg" +
        "0eXNvkTABxGuT1/OiwsNbrkP6q6JBBibknph8BlQs3YG6x/qcCAQIESwF89k1BRQzfrKlObFRLEnz7Vh53X4Z5X+KojfBzOS4tMJ" +
        "DAOiG/jpEoM9LyPzzWjyWlMiY/BgLw+/Nkj/jhKxtcQGNCv4fB0QlFwtkWmTMx+8ip98NqjGmhRvHNONpobs+n7F98c4A+TN1uZi" +
        "mfsna7igtFXb1w/q4ds91bdjYidEovi69hbBmCwQq3Xt8tkfbpRj3Veye17g+zKsOerFtKNZU1JreffzrbLgG5bSZWE0qzlgBFNv" +
        "aVodsWQM7UeTezdzyr8Ccr05+jWjpTsd8dyU9ESJMak97w2RcRhSkv/xOnjfFu74DvTk44TWlKhzOg8bNBv48DYrLXdHlD8XlEYy" +
        "jWIb7bR6S2xC/aD6Ilr92mZO+a8Kezta5Px7DdEmxVP/MRukcE2KZwztzXXwzi3M3z2VBB6NutdzMGg8KBV6yyUu3WQl+gtHaWlG" +
        "Ujc3KJaPOmIb1N/Q7kE9+le7OO3J6/jwr8sy72/TBpIabHoVJI+IXcLQkVzfPWcbZ39QhDjlTGh4QxtdVqrww1PLsvz+iPYvZ3VV" +
        "bcY47cFoRGQVqOqHV3qOHyzL0jd8AwkdC8nBa6IfXLCDJfvrmQUNH2kheJWV7I36uPjwFp3z+xlD71qihhoXQS1iM5KqA4T4Mmi9" +
        "sCjaN7HJqrc468le38FTbwQKb6a10yQTE32elRmorGJ/uzZ5BAEouNDXP/aClZZrZ9oAUfLn4JY8NECnN9M0Fe0EA6JzmXu+o3x6" +
        "Hvp2DSs7g7MZydAAb70tmKtzZkaRvaa7G/l+0y+qcXAhXmkRZJrS00QIys6g5K+UmBsZ7AXNNUCUGkX2DDwLJzZAJkPTCaj17UTc" +
        "6mZt1KatJ3vSMW95RBxpHdWm8VDwBiee9J23+dGrAN118oCmExD6do9Ywa6cobLTXKt7LG1XC16bXf9hE/LPvc4N1fEN0KnQbG/Q" +
        "AHyelYvBnO3xTfbthBzEc2yvlehzBatsqqMEzUnkpnqD10MEoi3MWRNTLvkG+3aK5qBZicglHH+hl7Ne9TrwUEpyJCIuAaoN1R3E" +
        "ZuQoQ08BLKSn7lnUQAJUKvQ6EN2MVCu8tCSSOX/jybXe0S8C14jYOmJXZWDHoL7/BVDZSse2o/rmxVU9/s+CEhFbRf303EK9IRJP" +
        "cvAw770C0EPnySyLq9TKTn1ck1V4uf16jn6lTc572lI+Nw/lgilbV4XS04jYGiJJGdw2qB/c+Li2rd/NincgUO3dnPfmFuZsGtIP" +
        "12QMPuaITXEzJA8N0gmsD3da9PnnuXSg0RLZVI4PB96D5OvYt2ADR/6sVVa8FMuch4R4SUF/p2iOqAeROLTLJKP/0UR/vm6ztm7Y" +
        "zsLHgsgKQitQ1i7TidqdnLHncW29cUh/dnPO0AsxsbWUZKLaQWHA55o+DY2XyCb58oicvIIfL2o3Z9xhtXxHRGlx7VJiKGdNLoUV" +
        "r46S5CQ5+Ecy7f/mNjqeLRIzZc9ubB+xy23gq3cEBRovzfAoWUZoz6lgvMNFA/q/V+zg9Kcbbc1PEEAIfiV7T+ng3LuNxJsi4o4c" +
        "8CSZhp7dlEtHUe+ITE71tar237aTjj21wPbRIz3cUnfLvBbMGp6af6pc+FVD6Y9rt0OF0Nwc4OjDW/Xrv9XFPTTaGRqXgFBbW8Mr" +
        "806Rs7a30HJxMpxxtVON+CgbClYFn/Tr+5f1sfTllWh0IzTctqr5WKHX9nFNBrCOt86KZMFdQrQB5COvgw9vYdPX4ZHCdmMl8jEB" +
        "jdwB+PldbTL//irVKkjc6BEXEdsq/U9s1farajYbcWoSy1Jh13AiKvS62ueZYMxUXlvwZyvlq3PwNHAbs4ZiU0Lwe0/uxalwCoGa" +
        "TrRIhBCO5uZ7A6MSUGuB9ZYVLgp3ABorMMJIBdjr0LPh465mfZsE4ms1CVCKWXBSOkMCEHH2CoNb7Mm02cZlaIknLwCsZe0v6P9y" +
        "mm+HjcZwgJXis9C6MiI24PNmGpcGB2RvZrx2AOpXZZ8UThhhIVrTrLFC3nqP/miia6mzEcMJKFpgiLhLg7xtbP0r3mtxVnqt/jfM" +
        "vHH5caAIsnYB8uXTBXtukLd1l7nzQHxKpkQcDdL/8Hsc/Lcu1Jyc4+8XCwO1+h5YOi50lNqVzE93/BVy1RfKzuQMPjOgR27dou23" +
        "7uOXk5lcWvg44WBkqjrKqwwQOMBEJ4CikAuYiNh6IGNwl9ehb2xh/qPFdwodMbs3vxocjK7v2dUQzvKxw1+7hmpsTGQzcjKSx3I9" +
        "9s2tdGwL32nsauxsgYys/95yWVa9GtG6dKTLE3pvYF2EJSXNlez7Xo89sJXTnoLpld1sh+uC4gr5mcsN7syM1AthjRsi6xCXkVZT" +
        "Bh/O9diDW1n0PIz892Y9tzFnM1w39wDg0SNKnka0xLUNICM5nFD990SPf2sni/bBRHd+P90olnq4Sr6eQ7eU5NS7PL6cM7Sjqkcf" +
        "7GPp69DcNdRPA/4PRVFD7RXRv+IAAAAASUVORK5CYII="
    )
    try {
        $stream = New-Object IO.MemoryStream(, [Convert]::FromBase64String($base64))
        $script:GuiIconeJanela = New-Object Drawing.Icon($stream)
    }
    catch {
        Write-Verbose ("Ícone da janela indisponível: {0}" -f $_.Exception.Message)
        $script:GuiIconeJanela = $null
    }
    return $script:GuiIconeJanela
}

function Set-GuiIconeJanela {
    param([Parameter(Mandatory=$true)][Windows.Forms.Form]$Form)
    $icone = Get-NextecIconeJanela
    if ($null -ne $icone) { $Form.Icon = $icone }
}

function Get-NextecLogoImage {
    <#
        Logo da Nextec (versão clara, para fundo escuro) embutida em Base64
        para o script continuar sendo um arquivo só, inclusive no one-liner.
        Se a imagem não puder ser montada, a tela abre sem logo.
    #>
    $base64 = (
        "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"
    )
    try {
        # O stream não pode ser descartado enquanto a imagem estiver em uso:
        # o GDI+ lê os bytes dele sob demanda.
        $stream = New-Object IO.MemoryStream(,[Convert]::FromBase64String($base64))
        return [Drawing.Image]::FromStream($stream)
    }
    catch {
        return $null
    }
}

function New-GuiCabecalho {
    # Faixa do topo com título, versão, host e logo. Usada na tela de
    # respostas e na janela de andamento.
    param([Parameter(Mandatory=$true)][object]$Inventory)
    $topo = New-Object Windows.Forms.Panel
    $topo.Dock = "Top"; $topo.Height = 64; $topo.BackColor = $script:GuiCores.Marinho
    $titulo = New-Object Windows.Forms.Label
    $titulo.Text = "Monitoramento Nextec"
    $titulo.ForeColor = [Drawing.Color]::White
    $titulo.Font = New-Object Drawing.Font("Segoe UI Semibold", 15)
    $titulo.Location = New-Object Drawing.Point(20, 8); $titulo.AutoSize = $true
    $sub = New-Object Windows.Forms.Label
    $sub.Text = ("Instalador Windows v{0} · {1} · {2}" -f $InstallerVersion, $Inventory.Hostname, $Inventory.Caption)
    $sub.ForeColor = [Drawing.Color]::FromArgb(217, 214, 255)
    $sub.Location = New-Object Drawing.Point(22, 38); $sub.AutoSize = $true
    $topo.Controls.Add($titulo); $topo.Controls.Add($sub)
    $imagemLogo = Get-NextecLogoImage
    if ($null -ne $imagemLogo) {
        $logo = New-Object Windows.Forms.PictureBox
        $logo.Image = $imagemLogo
        $logo.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
        $logo.Size = New-Object Drawing.Size(118, 32)
        $logo.Location = New-Object Drawing.Point(($topo.ClientSize.Width - 118 - 20), 16)
        $logo.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
        $logo.BackColor = [Drawing.Color]::Transparent
        $topo.Controls.Add($logo)
    }

    return $topo
}

function Get-NextecExporterDoCatalogo {
    # Chave do catálogo de um exporter já configurado: pelo nome (redis_exporter)
    # ou pelo serviço de costume (redis) com o endereço padrão.
    param([object]$Exporter)
    foreach ($d in (Get-NextecExporterCatalog)) {
        if ($d.Key -eq "custom") { continue }
        if ([string]$Exporter.Name -eq $d.Key) { return $d.Key }
        if ([string]$Exporter.Service -eq $d.DefaultService) { return $d.Key }
    }
    return $null
}

function Show-NextecGuiManutencao {
    <#
        Janela inicial quando o monitoramento já está instalado: mostra o
        estado de cada parte e devolve a opção escolhida, com a numeração do
        menu do console (1 alterar, 2 reconfigurar, 3 atualizar o Alloy,
        4 validar e reiniciar, 5 fechar).
    #>
    param([Parameter(Mandatory=$true)][object]$Inventory)

    Initialize-GuiCores
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:UsouTela = $true
    Set-NextecConsoleVisivel $false
    $script:GuiManutencaoEscolha = 5

    $form = New-Object Windows.Forms.Form
    $form.Text = "Nextec · Monitoramento já instalado"
    Set-GuiIconeJanela -Form $form
    $form.Size = New-Object Drawing.Size(900, 580)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
    $form.BackColor = [Drawing.Color]::White
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None

    $corpo = New-Object Windows.Forms.Panel
    $corpo.Dock = "Fill"; $corpo.BackColor = [Drawing.Color]::White
    $form.Controls.Add($corpo)
    $form.Controls.Add((New-GuiCabecalho -Inventory $Inventory))

    $corpo.Controls.Add((New-GuiLabel "Este computador já tem o monitoramento instalado" 24 16 560 -Titulo))
    $y = 58
    foreach ($linha in @(Get-MaintenanceStatusRows)) {
        $corpo.Controls.Add((New-GuiLabel $linha.Rotulo 24 ($y + 2) 190 -Dica))
        $valor = New-GuiLabel $linha.Valor 220 $y 370
        $corpo.Controls.Add($valor)
        if ($linha.Cor -eq [ConsoleColor]::Yellow) { $valor.ForeColor = [Drawing.Color]::FromArgb(176, 96, 0) }
        elseif ($linha.Cor -eq [ConsoleColor]::Gray -or $linha.Cor -eq [ConsoleColor]::DarkGray) { $valor.ForeColor = $script:GuiCores.Cinza }
        # Valor longo (coletas ligadas, caminho) quebra em mais linhas.
        $medida = [Windows.Forms.TextRenderer]::MeasureText($linha.Valor, $valor.Font, (New-Object Drawing.Size(370, 0)), [Windows.Forms.TextFormatFlags]::WordBreak)
        $valor.Height = [Math]::Max(22, $medida.Height + 2)
        $y += [Math]::Max(28, $valor.Height + 6)
    }

    $acoes = @(
        @(1, "Ver e alterar a configuração", "Abre as abas já preenchidas com a configuração atual.", $true),
        @(2, "Reconfigurar do zero", "Abre as abas como numa instalação nova.", $false),
        @(3, "Atualizar o Grafana Alloy", "Troca só a versão do Alloy; a configuração fica.", $false),
        @(4, "Validar e reiniciar", "Confere a configuração e reinicia o serviço do Alloy.", $false)
    )
    $yBotao = 58
    foreach ($acao in $acoes) {
        $botao = New-GuiBotao $acao[1] 610 $yBotao 250 -Principal:($acao[3])
        $botao.Tag = $acao[0]
        $botao.Add_Click({
            param($s, $e)
            $script:GuiManutencaoEscolha = [int]$s.Tag
            $s.FindForm().Close()
        })
        $corpo.Controls.Add($botao)
        $dica = New-GuiLabel $acao[2] 610 ($yBotao + 36) 260 -Dica
        $dica.Height = 34
        $corpo.Controls.Add($dica)
        $yBotao += 84
    }
    $fechar = New-GuiBotao "Fechar sem alterar" 610 $yBotao 250
    $fechar.Add_Click({ param($s, $e) $script:GuiManutencaoEscolha = 5; $s.FindForm().Close() })
    $corpo.Controls.Add($fechar)
    $form.CancelButton = $fechar

    Set-GuiEscala -Controle $form
    $form.Add_Shown({ param($s, $e) $s.Activate() })
    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:GuiManutencaoEscolha
}

function ConvertFrom-SnmpAuthYaml {
    <#
        Lê um bloco da seção "auths" (como Get-SnmpAuthBlocksFromFile devolve)
        e monta a credencial no formato da janela do equipamento. Devolve
        $null quando o bloco usa algo que a janela não representa; nesse caso
        o bloco é mantido como está.
    #>
    param([Parameter(Mandatory=$true)][string]$Bloco)

    $campos = @{}
    foreach ($linha in @($Bloco -split "`r?`n" | Select-Object -Skip 1)) {
        $m = [Regex]::Match($linha, '^\s+([A-Za-z_]+)\s*:\s*(.*?)\s*$')
        if (-not $m.Success) { continue }
        $valor = $m.Groups[2].Value
        if ($valor.Length -ge 2 -and $valor.StartsWith("'") -and $valor.EndsWith("'")) {
            $valor = $valor.Substring(1, $valor.Length - 2).Replace("''", "'")
        }
        elseif ($valor.Length -ge 2 -and $valor.StartsWith('"') -and $valor.EndsWith('"')) {
            $valor = $valor.Substring(1, $valor.Length - 2)
        }
        $campos[$m.Groups[1].Value.ToLowerInvariant()] = $valor
    }

    $versao = [string]$campos["version"]
    if (@("2", "2c", "v2c") -contains $versao) {
        if ([string]::IsNullOrEmpty([string]$campos["community"])) { return $null }
        return [pscustomobject]@{ Versao = "v2c"; Community = [string]$campos["community"] }
    }
    if (@("3", "v3") -notcontains $versao) { return $null }

    $usuario = [string]$campos["username"]
    $senhaAuth = [string]$campos["password"]
    $protAuth = $(if ($campos["auth_protocol"]) { [string]$campos["auth_protocol"] } else { "SHA" })
    $nivel = $(if ([string]$campos["security_level"] -eq "authNoPriv") { "authNoPriv" } else { "authPriv" })
    $protPriv = $(if ($campos["priv_protocol"]) { [string]$campos["priv_protocol"] } else { "AES" })
    $senhaPriv = [string]$campos["priv_password"]
    if (-not $usuario -or -not $senhaAuth) { return $null }
    if (@("SHA", "SHA256", "SHA512", "MD5") -notcontains $protAuth) { return $null }
    if ($nivel -eq "authPriv" -and (-not $senhaPriv -or @("AES", "AES256", "DES") -notcontains $protPriv)) { return $null }

    return [pscustomobject]@{
        Versao = "v3"; Usuario = $usuario; Nivel = $nivel
        ProtocoloAuth = $protAuth; SenhaAuth = $senhaAuth
        ProtocoloPriv = $(if ($nivel -eq "authPriv") { $protPriv } else { "" })
        SenhaPriv = $(if ($nivel -eq "authPriv") { $senhaPriv } else { "" })
    }
}

function Invoke-NextecConfiguracaoGui {
    <#
        "Ver e alterar" com área de trabalho: abre as abas preenchidas com a
        configuração instalada e, ao confirmar, regrava tudo pelo mesmo
        caminho do menu do console (Save-ReconfiguredAlloy).
    #>
    $configuracao = Read-CurrentAlloyConfiguration
    if ($null -eq $configuracao -or [string]::IsNullOrWhiteSpace([string]$configuracao.Cliente)) {
        throw ("Não foi possível ler a configuração atual em {0}. Rode de novo e use Reconfigurar do zero." -f $ConfigFile)
    }

    $inventario = Import-CurrentConfiguration -Configuration $configuracao
    $destino = [Regex]::Match([string]$script:RemoteWriteUrl, '^https?://([^/]+)')
    if ($destino.Success) { $script:NocHost = $destino.Groups[1].Value }
    $script:SnmpSourceFile = $null

    if (-not (Show-NextecInstallerGui -Inventory $inventario -DetectedFeatures @($script:DetectedHostFeatures) -Edicao)) {
        Write-Info "Tela fechada sem alterar nada."
        $script:DispensarEspera = $true
        return
    }

    Open-NextecGuiProgresso -Inventory $inventario -Titulo "Aplicando as alterações"
    $script:GuiTituloSucesso = "Configuração atualizada"
    $script:GuiTituloFalha = "A alteração falhou; a configuração anterior foi mantida"

    if ($script:EnableSnmpResolved -and @($script:GuiFabricantesSnmp).Count -gt 0) {
        $script:SnmpSourceFile = Get-NextecSnmpVendorFiles -Arquivos $script:GuiFabricantesSnmp
    }
    Save-ReconfiguredAlloy -Inventory $inventario
    Invoke-NextecOptionalStep -Nome "Atualizador automático" -Acao {
        Install-Atualizador
    } | Out-Null
}

function Show-NextecInstallerGui {
    <#
        Abre a tela de instalação e preenche as mesmas variáveis que o fluxo
        do console preenche. Devolve $true se o técnico confirmou e $false
        se fechou a janela.
    #>
    param(
        [Parameter(Mandatory=$true)][object]$Inventory,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$DetectedFeatures,
        # Abre preenchida com a configuração instalada (Import-CurrentConfiguration).
        [switch]$Edicao
    )

    Initialize-GuiCores
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:UsouTela = $true
    Set-NextecConsoleVisivel $false
    $g = @{}
    $script:Gui = $g
    $g.Inventory = $Inventory
    $g.Features = @($DetectedFeatures)
    $g.Confirmado = $false
    # Com Set-StrictMode, ler chave que não existe no hashtable dá erro: toda
    # chave lida por um evento precisa nascer aqui.
    $g.Ocupado = $false
    $g.Edicao = [bool]$Edicao
    # Marcação inicial da árvore na edição, por chave do item. Nula na
    # instalação nova, que usa os padrões de cada item.
    $g.Inicial = $null
    if ($Edicao) {
        $inicial = @{
            logs = [bool]$script:EnableLogsResolved
            logs_warning = [bool]$script:EnableLogWarningsResolved
            security = [bool]$script:EnableSecurityLogsResolved
            snmp = [bool]$script:EnableSnmpResolved
            blackbox = [bool]$script:EnableBlackboxResolved
            internet = [bool]$script:EnableInternetResolved
            coleta = [bool]$script:EnableColetaResolved
            exporter = (@($script:CustomExporters).Count -gt 0)
            virtualizacao = (@($script:Hipervisores).Count -gt 0)
        }
        foreach ($ft in @($DetectedFeatures)) { $inicial[("feature:{0}" -f $ft.Key)] = (@($script:SelectedHostFeatureKeys) -contains $ft.Key) }
        foreach ($ce in @($script:CustomExporters)) {
            $doCatalogo = Get-NextecExporterDoCatalogo -Exporter $ce
            if ($doCatalogo) { $inicial[("exporter:{0}" -f $doCatalogo)] = $true }
            else { $inicial["exporter:custom"] = $true }
        }
        $g.Inicial = $inicial
    }
    $estacao = ($Inventory.ProductType -eq 1)

    $form = New-Object Windows.Forms.Form
    $form.Text = $(if ($Edicao) { "Nextec · Alterar a configuração do monitoramento" } else { "Nextec · Instalação do monitoramento" })
    Set-GuiIconeJanela -Form $form
    $form.Size = New-Object Drawing.Size(900, 680)
    $form.MinimumSize = New-Object Drawing.Size(900, 680)
    $form.StartPosition = "CenterScreen"
    $form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
    $form.BackColor = $script:GuiCores.Fundo
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $g.Form = $form

    $topo = New-GuiCabecalho -Inventory $Inventory

    $rodape = New-Object Windows.Forms.Panel
    $rodape.Dock = "Bottom"; $rodape.Height = 56; $rodape.BackColor = [Drawing.Color]::White
    $g.Erro = New-GuiLabel "" 16 18 520
    $g.Erro.ForeColor = $script:GuiCores.Erro
    $g.Voltar = New-GuiBotao "Voltar" 560 12 100
    $g.Avancar = New-GuiBotao "Avançar" 670 12 200 -Principal
    $rodape.Controls.Add($g.Erro); $rodape.Controls.Add($g.Voltar); $rodape.Controls.Add($g.Avancar)

    $abas = New-Object Windows.Forms.TabControl
    $abas.Dock = "Fill"
    $abas.Padding = New-Object Drawing.Point(14, 6)
    $g.Abas = $abas

    $form.Controls.Add($abas)
    $form.Controls.Add($rodape)
    $form.Controls.Add($topo)

    # ---------------- Identificação ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Identificação"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaIdentificacao = $p
    $p.Controls.Add((New-GuiLabel "Quem é este servidor no NOC" 24 16 600 -Titulo))
    Add-GuiLegendaObrigatorio $p
    [void](Add-GuiRotulo $p "Cliente" 24 62 200 -Obrigatorio)
    $g.Cliente = New-GuiTextBox 230 59 360 $(if ($script:Cliente) { [string]$script:Cliente } else { "" })
    $p.Controls.Add($g.Cliente)
    $g.ClienteSlug = New-GuiLabel "Identificador da empresa, não do servidor. Ex.: advocacia_martins" 230 84 600 -Dica
    $p.Controls.Add($g.ClienteSlug)
    $g.Cliente.Add_TextChanged({
        $s = Get-GuiClienteSlug $script:Gui.Cliente.Text
        if ($s) { $script:Gui.ClienteSlug.Text = "No NOC vai ficar: $s" } else { $script:Gui.ClienteSlug.Text = "Identificador da empresa, não do servidor. Ex.: advocacia_martins" }
    })

    [void](Add-GuiRotulo $p "Nome do host" 24 117 200 -Obrigatorio)
    $hostPadrao = $(if ($script:HostLabel) { [string]$script:HostLabel } else { Get-GuiSlug $Inventory.Hostname })
    $g.Host = New-GuiTextBox 230 114 360 $hostPadrao
    $p.Controls.Add($g.Host)

    $ambientes = @("producao", "homologacao", "desenvolvimento", "backup", "teste")
    $p.Controls.Add((New-GuiLabel "Ambiente" 24 157 200))
    $g.Ambiente = New-GuiCombo 230 154 200 $ambientes ([Math]::Max(0, [Array]::IndexOf($ambientes, [string]$script:Ambiente)))
    $p.Controls.Add($g.Ambiente)

    [void](Add-GuiRotulo $p "Local" 24 197 200 -Obrigatorio)
    $g.Local = New-GuiTextBox 230 194 200 $(if ($script:Local) { [string]$script:Local } else { "matriz" })
    $p.Controls.Add($g.Local)
    $p.Controls.Add((New-GuiLabel "Ex.: matriz, filial_sp" 440 197 300 -Dica))

    $criticidades = @("critico", "alto", "medio", "baixo")
    $p.Controls.Add((New-GuiLabel "Criticidade" 24 237 200))
    $indiceCrit = [Array]::IndexOf($criticidades, [string]$script:Criticidade)
    if ($indiceCrit -lt 0) { $indiceCrit = 1 }
    $g.Criticidade = New-GuiCombo 230 234 200 $criticidades $indiceCrit
    $p.Controls.Add($g.Criticidade)

    if ($estacao) { $modos = @("Estação monitorada", "Collector de rede (SNMP, conectividade, Speedtest)", "Estação + Collector de rede") }
    else { $modos = @("Servidor monitorado", "Collector de rede (SNMP, conectividade, Speedtest)", "Servidor + Collector de rede") }
    $indiceModo = 0
    switch ($Modo) {
        "collector" { $indiceModo = 1 }
        "servidor_collector" { $indiceModo = 2 }
        "estacao_collector" { $indiceModo = 2 }
    }
    if ($Edicao) { $indiceModo = $(if (-not $script:MonitorHost) { 1 } elseif ($script:Collector) { 2 } else { 0 }) }
    $p.Controls.Add((New-GuiLabel "Função deste Alloy" 24 277 200))
    $g.Modo = New-GuiCombo 230 274 420 $modos $indiceModo
    $p.Controls.Add($g.Modo)
    $p.Controls.Add((New-GuiLabel "Collector é o servidor que alcança firewall, switch, nobreak e os destinos de teste." 230 300 600 -Dica))

    [void](Add-GuiRotulo $p "Destino do NOC" 24 340 200 -Obrigatorio)
    $g.Destino = New-GuiTextBox 230 337 360 $script:NocHost
    $p.Controls.Add($g.Destino)

    # ---------------- Recursos ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Recursos"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaRecursos = $p
    $p.Controls.Add((New-GuiLabel "O que coletar além do perfil básico" 24 16 600 -Titulo))
    $g.Basico = New-GuiLabel "Os itens em cinza são o perfil básico: vêm sempre ligados e não podem ser desmarcados." 24 46 760 -Dica
    $p.Controls.Add($g.Basico)
    $arvore = New-Object Windows.Forms.TreeView
    $arvore.CheckBoxes = $true
    $arvore.Location = New-Object Drawing.Point(24, 74)
    $arvore.Size = New-Object Drawing.Size(560, 384)
    $arvore.Font = New-Object Drawing.Font("Segoe UI", 10)
    $arvore.ItemHeight = [int](24 * $script:GuiEscala)
    $arvore.ShowLines = $false
    $arvore.FullRowSelect = $true
    $g.Arvore = $arvore
    $p.Controls.Add($arvore)
    $p.Controls.Add((New-GuiLabel "Speedtest a cada (min)" 604 80 200))
    $g.Intervalo = New-Object Windows.Forms.NumericUpDown
    $g.Intervalo.Location = New-Object Drawing.Point(604, 104)
    $g.Intervalo.Minimum = 5; $g.Intervalo.Maximum = 1440
    $g.Intervalo.Value = [Math]::Max(5, [int]$InternetIntervalMinutes)
    if ($Edicao -and [int]$script:InternetIntervalMinutesResolved -ge 5) { $g.Intervalo.Value = [Math]::Min(1440, [int]$script:InternetIntervalMinutesResolved) }
    $p.Controls.Add($g.Intervalo)
    $g.IntervaloDica = New-GuiLabel "Recomendado: 30 min." 604 134 250 -Dica
    $p.Controls.Add($g.IntervaloDica)
    $g.IntervaloAviso = New-GuiLabel "Cada teste satura o link por alguns segundos. Abaixo de 15 min o cliente sente lentidão e o consumo de franquia cresce muito." 604 156 250 -Dica
    $g.IntervaloAviso.Height = 70
    $p.Controls.Add($g.IntervaloAviso)
    $p.Controls.Add((New-GuiLabel "Bases SQLite (opcional)" 604 248 250))
    $g.Sqlite = New-GuiTextBox 604 272 250 ([string]$script:BancosSqlite)
    $p.Controls.Add($g.Sqlite)
    $g.SqliteDica = New-GuiLabel "Caminho completo, curinga aceito, separados por vírgula. Ex.: C:\Sistema\dados\*.db" 604 300 250 -Dica
    $g.SqliteDica.Height = 52
    $p.Controls.Add($g.SqliteDica)
    $g.Intervalo.Add_ValueChanged({
        $gg = $script:Gui
        $gg.IntervaloAviso.ForeColor = $(if ($gg.Intervalo.Value -lt 15) { $script:GuiCores.Erro } else { $script:GuiCores.Cinza })
    })
    $p.Controls.Add((New-GuiLabel "Clique no texto para marcar. Exporters: marque o grupo e escolha os filhos." 24 464 760 -Dica))

    # Itens do perfil básico são fixos: qualquer tentativa de desmarcar
    # (clique, barra de espaço) é cancelada antes de acontecer.
    $arvore.Add_BeforeCheck({
        param($s, $e)
        if ([string]$e.Node.Tag -eq "fixo") { $e.Cancel = $true }
    })

    # Marcar o pai marca os filhos e vice-versa; os avisos dependem dos logs.
    $arvore.Add_AfterCheck({
        param($s, $e)
        # Marcações feitas aqui disparam o evento de novo: a trava evita o laço.
        if ($script:Gui.Ocupado) { return }
        $script:Gui.Ocupado = $true
        try {
        $n = $e.Node
        if ($n.Nodes.Count -gt 0 -and $n.Name -eq "exporter") {
            if (-not $n.Checked) { foreach ($f in $n.Nodes) { $f.Checked = $false } }
            $n.Expand()
        }
        if ($null -ne $n.Parent -and $n.Parent.Name -eq "exporter") {
            $algum = $false
            foreach ($f in $n.Parent.Nodes) { if ($f.Checked) { $algum = $true } }
            $n.Parent.Checked = $algum
        }
        if ($n.Name -eq "logs_warning" -and $n.Checked) {
            $logs = $script:Gui.Arvore.Nodes.Find("logs", $true)
            if ($logs.Count -gt 0) { $logs[0].Checked = $true }
        }
        if ($n.Name -eq "logs" -and -not $n.Checked) {
            $warn = $script:Gui.Arvore.Nodes.Find("logs_warning", $true)
            if ($warn.Count -gt 0) { $warn[0].Checked = $false }
        }
        }
        finally { $script:Gui.Ocupado = $false }
        & $script:Gui.MontarAbas
    })
    $arvore.Add_NodeMouseClick({
        param($s, $e)
        if ($e.X -gt $e.Node.Bounds.Left) { $e.Node.Checked = -not $e.Node.Checked }
    })

    # ---------------- Links ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Links de internet"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaLinks = $p
    $p.Controls.Add((New-GuiLabel "Links de internet deste local" 24 16 600 -Titulo))
    Add-GuiLegendaObrigatorio $p
    $p.Controls.Add((New-GuiLabel "Velocidade contratada em Mbps: 500, 1000 ou 600/300 (download/upload); vazio se não souber. Destinos de teste já vêm prontos." 24 46 820 -Dica))
    $g.Links = New-GuiGrid 24 72 820 300
    Add-GuiColunaTexto $g.Links "operadora" "Operadora *" 110
    Add-GuiColunaLista $g.Links "tipo" "Tipo" @($script:TiposLink.Values) 70
    Add-GuiColunaLista $g.Links "papel" "Função" @($script:PapeisLink.Values) 70
    Add-GuiColunaTexto $g.Links "velocidade" "Velocidade (Mbps)" 105
    Add-GuiColunaTexto $g.Links "alvos" "Destinos de teste *" 170
    Add-GuiColunaTexto $g.Links "ip_publico" "IP público" 80
    Add-GuiColunaTexto $g.Links "gateway" "Gateway" 70
    Add-GuiColunaTexto $g.Links "origem" "IP de origem" 70
    Add-GuiColunaTexto $g.Links "firewall" "Firewall no NOC" 70
    Add-GuiColunaTexto $g.Links "interface_firewall" "Interface WAN" 60
    $p.Controls.Add($g.Links)
    $g.Avancado = New-Object Windows.Forms.CheckBox
    $g.Avancado.Text = "Mostrar opções avançadas (gateway, IP de origem, firewall)"
    $g.Avancado.Location = New-Object Drawing.Point(24, 380); $g.Avancado.AutoSize = $true
    $p.Controls.Add($g.Avancado)
    $atualizarColunasLinks = {
        foreach ($c in @("gateway", "origem", "firewall", "interface_firewall")) { $script:Gui.Links.Columns[$c].Visible = $script:Gui.Avancado.Checked }
    }
    $g.Avancado.Add_CheckedChanged($atualizarColunasLinks)
    & $atualizarColunasLinks
    $bAdd = New-GuiBotao "Adicionar link" 24 410 140
    $bDel = New-GuiBotao "Remover selecionado" 174 410 170
    $p.Controls.Add($bAdd); $p.Controls.Add($bDel)
    $g.AdicionarLink = {
        param([object]$Link)
        $gr = $script:Gui.Links
        $i = $gr.Rows.Add()
        $r = $gr.Rows[$i]
        if ($null -ne $Link) {
            $r.Cells["operadora"].Value = $Link.operadora
            $tipoTexto = $(if ($script:TiposLink.Contains([string]$Link.tipo)) { $script:TiposLink[[string]$Link.tipo] } else { @($script:TiposLink.Values)[0] })
            $r.Cells["tipo"].Value = $tipoTexto
            $r.Cells["papel"].Value = $(if ($script:PapeisLink.Contains([string]$Link.papel)) { $script:PapeisLink[[string]$Link.papel] } else { $script:PapeisLink["primario"] })
            $r.Cells["velocidade"].Value = $(if ($Link.velocidade_upload_mbps) { "{0}/{1}" -f $Link.velocidade_mbps, $Link.velocidade_upload_mbps } else { [string]$Link.velocidade_mbps })
            foreach ($c in @("alvos", "ip_publico", "gateway", "origem", "firewall", "interface_firewall")) { $r.Cells[$c].Value = [string]$Link.$c }
        }
        else {
            $r.Cells["tipo"].Value = @($script:TiposLink.Values)[0]
            $r.Cells["papel"].Value = $(if ($i -eq 0) { $script:PapeisLink["primario"] } else { $script:PapeisLink["failover"] })
            $r.Cells["alvos"].Value = $(if ($i -lt $script:DestinosLink.Count) { $script:DestinosLink[$i] } else { "" })
        }
    }
    $bAdd.Add_Click({ & $script:Gui.AdicionarLink $null })
    $bDel.Add_Click({ if ($null -ne $script:Gui.Links.CurrentRow) { $script:Gui.Links.Rows.Remove($script:Gui.Links.CurrentRow) } })
    if ($script:ColetaLinks.Count -gt 0) { foreach ($l in $script:ColetaLinks) { & $g.AdicionarLink $l } } else { & $g.AdicionarLink $null }

    # ---------------- Conectividade ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Conectividade"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaBlackbox = $p
    $p.Controls.Add((New-GuiLabel "Sistemas, sites e portas que este servidor vai testar" 24 16 640 -Titulo))
    Add-GuiLegendaObrigatorio $p
    $p.Controls.Add((New-GuiLabel "Testes do 1 (mais simples) ao 6 (mais completo). Para dois testes no mesmo alvo, cadastre duas linhas com o mesmo nome." 24 46 820 -Dica))
    $g.Blackbox = New-GuiGrid 24 72 820 300
    Add-GuiColunaTexto $g.Blackbox "nome" "Nome (ex.: fw_matriz) *" 80
    Add-GuiColunaTexto $g.Blackbox "endereco" "IP, FQDN ou URL *" 110
    Add-GuiColunaLista $g.Blackbox "modulo" "Teste" @($script:GuiModulosBlackbox.Values) 150
    $g.Blackbox.Columns["modulo"].DropDownWidth = 330
    Add-GuiColunaLista $g.Blackbox "tipo" "Tipo do ativo" @("firewall", "switch", "link", "aplicacao", "site", "storage") 60
    $p.Controls.Add($g.Blackbox)
    $p.Controls.Add((New-GuiLabel "Testar a cada" 24 386 120))
    $g.IntervaloBlackbox = New-GuiCombo 150 383 300 @("10 segundos (link: disponibilidade e jitter)", "15 segundos", "30 segundos (serviços e sites)", "60 segundos (site externo, padrão)") 3
    $p.Controls.Add($g.IntervaloBlackbox)
    $b1 = New-GuiBotao "Adicionar alvo" 24 420 140
    $b2 = New-GuiBotao "Remover selecionado" 174 420 170
    $b1.Add_Click({ $i = $script:Gui.Blackbox.Rows.Add(); $script:Gui.Blackbox.Rows[$i].Cells["modulo"].Value = @($script:GuiModulosBlackbox.Values)[0]; $script:Gui.Blackbox.Rows[$i].Cells["tipo"].Value = "firewall" })
    $b2.Add_Click({ if ($null -ne $script:Gui.Blackbox.CurrentRow) { $script:Gui.Blackbox.Rows.Remove($script:Gui.Blackbox.CurrentRow) } })
    $p.Controls.Add($b1); $p.Controls.Add($b2)
    if ($Edicao) {
        $iIntervalo = [Array]::IndexOf(@(10, 15, 30, 60), [int]$script:BlackboxIntervalSecondsResolved)
        if ($iIntervalo -ge 0) { $g.IntervaloBlackbox.SelectedIndex = $iIntervalo }
        foreach ($alvo in @($script:BlackboxTargets)) {
            $r = $g.Blackbox.Rows[$g.Blackbox.Rows.Add()]
            $r.Cells["nome"].Value = [string]$alvo.Name
            $r.Cells["endereco"].Value = [string]$alvo.Address
            # Teste ou tipo fora da lista da tela entram na lista, para não
            # trocar em silêncio o que já está configurado.
            $teste = $(if ($script:GuiModulosBlackbox.Contains([string]$alvo.Module)) { $script:GuiModulosBlackbox[[string]$alvo.Module] } elseif ($alvo.Module) { [string]$alvo.Module } else { @($script:GuiModulosBlackbox.Values)[0] })
            if (-not $g.Blackbox.Columns["modulo"].Items.Contains($teste)) { [void]$g.Blackbox.Columns["modulo"].Items.Add($teste) }
            $r.Cells["modulo"].Value = $teste
            $tipoAlvo = $(if ($alvo.Type) { [string]$alvo.Type } else { "firewall" })
            if (-not $g.Blackbox.Columns["tipo"].Items.Contains($tipoAlvo)) { [void]$g.Blackbox.Columns["tipo"].Items.Add($tipoAlvo) }
            $r.Cells["tipo"].Value = $tipoAlvo
        }
    }

    # ---------------- SNMP ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "SNMP"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaSnmp = $p
    $p.Controls.Add((New-GuiLabel "Equipamentos de rede (firewall, switch, nobreak, AP)" 24 16 640 -Titulo))
    Add-GuiLegendaObrigatorio $p
    $p.Controls.Add((New-GuiLabel "Use Adicionar equipamento: nome, endereço, fabricante e credencial ficam na mesma janela. Duplo clique numa linha edita." 24 46 820 -Dica))
    $g.Snmp = New-GuiGrid 24 72 820 290
    $g.Snmp.ReadOnly = $true
    $g.Snmp.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $g.Snmp.MultiSelect = $false
    Add-GuiColunaTexto $g.Snmp "nome" "Nome" 90
    Add-GuiColunaTexto $g.Snmp "endereco" "IP ou FQDN" 90
    Add-GuiColunaTexto $g.Snmp "fabricante" "Fabricante" 70
    Add-GuiColunaTexto $g.Snmp "tipo" "Tipo" 60
    Add-GuiColunaTexto $g.Snmp "credencial" "Credencial" 90
    # Módulo já configurado: vale quando o fabricante não está no catálogo.
    Add-GuiColunaTexto $g.Snmp "modulo_atual" "" 10
    $g.Snmp.Columns["modulo_atual"].Visible = $false
    $p.Controls.Add($g.Snmp)
    $p.Controls.Add((New-GuiLabel "Fabricante fora da lista? Solicite ao NOC a inclusão do fabricante antes de cadastrar o equipamento." 24 368 820 -Dica))

    # Linha da grade a partir do objeto devolvido pela janela do equipamento.
    $g.GravarEquipamento = {
        param($Linha, $Equipamento)
        $Linha.Cells["nome"].Value = $Equipamento.Nome
        $Linha.Cells["endereco"].Value = $Equipamento.Endereco
        $Linha.Cells["fabricante"].Value = $Equipamento.Fabricante
        $Linha.Cells["tipo"].Value = $Equipamento.Tipo
        $cred = $Equipamento.Credencial
        $Linha.Cells["credencial"].Value = $(if ($cred.Versao -eq "v2c") { "v2c (community)" } else { "v3, {0}" -f $cred.Nivel })
        $Linha.Tag = $cred
    }
    $g.EditarEquipamento = {
        $gg = $script:Gui
        $linha = $gg.Snmp.CurrentRow
        if ($null -eq $linha) { $gg.Erro.Text = "Selecione um equipamento na lista."; return }
        # Credencial mantida como texto (Bruto) não abre na janela: editar
        # pede a credencial de novo.
        $credAtual = $linha.Tag
        if ($null -ne $credAtual -and $null -ne $credAtual.PSObject.Properties["Bruto"]) { $credAtual = $null }
        $atual = [pscustomobject]@{
            Nome = Get-GuiCelula $linha "nome"; Endereco = Get-GuiCelula $linha "endereco"
            Fabricante = Get-GuiCelula $linha "fabricante"; Tipo = Get-GuiCelula $linha "tipo"; Credencial = $credAtual
        }
        $eq = Show-GuiEquipamentoSnmp -Atual $atual
        if ($null -ne $eq) { & $gg.GravarEquipamento $linha $eq; $gg.Erro.Text = "" }
    }
    $g.Snmp.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $script:Gui.EditarEquipamento } })
    $b1 = New-GuiBotao "Adicionar equipamento" 24 400 190 -Principal
    $b3 = New-GuiBotao "Editar selecionado" 224 400 160
    $b2 = New-GuiBotao "Remover selecionado" 394 400 170
    $b1.Add_Click({
        $eq = Show-GuiEquipamentoSnmp -Atual $null
        if ($null -ne $eq) {
            $gg = $script:Gui
            $i = $gg.Snmp.Rows.Add()
            & $gg.GravarEquipamento $gg.Snmp.Rows[$i] $eq
            $gg.Erro.Text = ""
        }
    })
    $b3.Add_Click({ & $script:Gui.EditarEquipamento })
    $b2.Add_Click({ if ($null -ne $script:Gui.Snmp.CurrentRow) { $script:Gui.Snmp.Rows.Remove($script:Gui.Snmp.CurrentRow) } })
    $p.Controls.Add($b1); $p.Controls.Add($b3); $p.Controls.Add($b2)
    if ($Edicao) {
        $authsAtuais = @{}
        foreach ($bloco in @(Get-SnmpAuthBlocksFromFile -Path $SnmpAuthFile)) { $authsAtuais[(Get-SnmpAuthBlockName -Block $bloco)] = $bloco }
        foreach ($alvo in @($script:SnmpTargets)) {
            $rotuloFabricante = [string]$alvo.Os
            foreach ($k in $NextecSnmpVendors.Keys) {
                if ([IO.Path]::GetFileNameWithoutExtension($NextecSnmpVendors[$k].File) -eq [string]$alvo.Os) { $rotuloFabricante = $NextecSnmpVendors[$k].Label }
            }
            $r = $g.Snmp.Rows[$g.Snmp.Rows.Add()]
            $r.Cells["nome"].Value = [string]$alvo.Name
            $r.Cells["endereco"].Value = [string]$alvo.Address
            $r.Cells["fabricante"].Value = $rotuloFabricante
            $r.Cells["tipo"].Value = [string]$alvo.Type
            $r.Cells["modulo_atual"].Value = [string]$alvo.Module
            $cred = $null
            if ($authsAtuais.ContainsKey([string]$alvo.Auth)) {
                $cred = ConvertFrom-SnmpAuthYaml -Bloco $authsAtuais[[string]$alvo.Auth]
                if ($null -eq $cred) { $cred = [pscustomobject]@{ Versao = ""; Bruto = $authsAtuais[[string]$alvo.Auth] } }
            }
            if ($null -eq $cred) { $r.Cells["credencial"].Value = "falta (editar)" }
            elseif ($null -ne $cred.PSObject.Properties["Bruto"]) { $r.Cells["credencial"].Value = "atual (mantida)" }
            else { $r.Cells["credencial"].Value = $(if ($cred.Versao -eq "v2c") { "v2c (community)" } else { "v3, {0}" -f $cred.Nivel }) }
            $r.Tag = $cred
        }
    }

    # ---------------- Exporters ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Exporters"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaExporters = $p
    $p.Controls.Add((New-GuiLabel "Serviços que já publicam métricas Prometheus" 24 16 640 -Titulo))
    Add-GuiLegendaObrigatorio $p
    $p.Controls.Add((New-GuiLabel "Os marcados em Recursos já vêm com o endereço de costume. Troque só se o serviço usa outra porta ou outro servidor." 24 46 820 -Dica))
    $g.Exporters = New-GuiGrid 24 72 820 190
    Add-GuiColunaTexto $g.Exporters "nome" "Serviço *" 90
    Add-GuiColunaTexto $g.Exporters "alvo" "Endereço (host:porta) *" 110
    Add-GuiColunaTexto $g.Exporters "servico" "Nome no NOC (opcional)" 90
    $p.Controls.Add($g.Exporters)
    $b1 = New-GuiBotao "Adicionar outro serviço" 24 270 190
    $b2 = New-GuiBotao "Remover selecionado" 224 270 170
    $b1.Add_Click({ $i = $script:Gui.Exporters.Rows.Add(); $script:Gui.Exporters.Rows[$i].Tag = "custom"; $script:Gui.Exporters.CurrentCell = $script:Gui.Exporters.Rows[$i].Cells["nome"]; $script:Gui.Exporters.BeginEdit($true) | Out-Null })
    $b2.Add_Click({ if ($null -ne $script:Gui.Exporters.CurrentRow) { $script:Gui.Exporters.Rows.Remove($script:Gui.Exporters.CurrentRow) } })
    $p.Controls.Add($b1); $p.Controls.Add($b2)
    $guia = New-Object Windows.Forms.GroupBox
    $guia.Text = "Como adicionar um serviço que não está na lista"
    $guia.Location = New-Object Drawing.Point(24, 314); $guia.Size = New-Object Drawing.Size(820, 160)
    $passos = @(
        "1. Abra http://host:porta/metrics no navegador. Se aparecer texto como ""nome_da_metrica 123"", o serviço publica métricas.",
        "2. Clique em Adicionar outro serviço e preencha: Serviço (nome curto, ex.: minio), Endereço (ex.: 127.0.0.1:9000).",
        "3. Nome no NOC é opcional: agrupa o serviço nos painéis. Em branco, usa o nome do serviço.",
        "4. Se /metrics não abrir, o serviço precisa de um exporter próprio. Solicite ao NOC antes de cadastrar."
    )
    $y = 24
    foreach ($passo in $passos) {
        $l = New-GuiLabel $passo 12 $y 796
        $l.Height = 30
        $guia.Controls.Add($l)
        $y += 32
    }
    $p.Controls.Add($guia)

    # ---------------- Virtualização ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Virtualização"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaVirt = $p
    $p.Controls.Add((New-GuiLabel "Hipervisores consultados pela rede" 24 16 640 -Titulo))
    Add-GuiLegendaObrigatorio $p
    $p.Controls.Add((New-GuiLabel "Este servidor lê VMs, armazenamento e snapshots pela API, com um usuário só leitura. O Hyper-V deste servidor entra pela aba Recursos, sem senha." 24 46 820 -Dica))
    $g.Hipervisores = New-GuiGrid 24 72 820 180
    Add-GuiColunaTexto $g.Hipervisores "nome" "Nome no NOC *" 80
    Add-GuiColunaLista $g.Hipervisores "tipo" "Tipo" @($script:TiposHipervisor.Values) 90
    Add-GuiColunaTexto $g.Hipervisores "endereco" "Endereço *" 100
    Add-GuiColunaTexto $g.Hipervisores "usuario" "Usuário ou ID do token *" 120
    Add-GuiColunaTexto $g.Hipervisores "segredo" "Senha ou segredo do token *" 110
    $cVerificar = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $cVerificar.Name = "verificar"; $cVerificar.HeaderText = "Conferir certificado"; $cVerificar.FillWeight = 85
    [void]$g.Hipervisores.Columns.Add($cVerificar)
    # Senha nunca aparece: a célula mostra pontos, a edição usa caractere de
    # senha e a já gravada aparece como "atual (mantida)".
    $g.Hipervisores.Add_CellFormatting({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $s.Columns[$e.ColumnIndex].Name -ne "segredo") { return }
        $linha = $s.Rows[$e.RowIndex]
        if ($e.Value) { $e.Value = "●●●●●●●●"; $e.FormattingApplied = $true }
        elseif ($linha.Tag -eq "mantida") { $e.Value = "atual (mantida)"; $e.FormattingApplied = $true }
    })
    $g.Hipervisores.Add_EditingControlShowing({
        param($s, $e)
        if ($e.Control -is [Windows.Forms.TextBox]) { $e.Control.UseSystemPasswordChar = ($s.CurrentCell.OwningColumn.Name -eq "segredo") }
    })
    $p.Controls.Add($g.Hipervisores)
    $bHvAdd = New-GuiBotao "Adicionar hipervisor" 24 260 170
    $bHvDel = New-GuiBotao "Remover selecionado" 204 260 170
    $bHvAdd.Add_Click({ $gr = $script:Gui.Hipervisores; $i = $gr.Rows.Add(); $gr.Rows[$i].Cells["tipo"].Value = @($script:TiposHipervisor.Values)[0]; $gr.Rows[$i].Cells["verificar"].Value = $false })
    $bHvDel.Add_Click({ if ($null -ne $script:Gui.Hipervisores.CurrentRow) { $script:Gui.Hipervisores.Rows.Remove($script:Gui.Hipervisores.CurrentRow) } })
    $p.Controls.Add($bHvAdd); $p.Controls.Add($bHvDel)
    $guiaHv = New-Object Windows.Forms.GroupBox
    $guiaHv.Text = "Usuário só leitura em cada hipervisor"
    $guiaHv.Location = New-Object Drawing.Point(24, 300); $guiaHv.Size = New-Object Drawing.Size(820, 172)
    $y = 22
    foreach ($passo in @(
        "VMware: no ESXi ou vCenter, crie um usuário e dê a ele o papel Somente leitura na raiz. Endereço: o host ou o vCenter (cobre todos os hosts).",
        "Proxmox: Datacenter > Permissões > Tokens de API, papel PVEAuditor no caminho /. Usuário: o ID do token (ex.: monitor@pve!nextec); senha: o segredo.",
        "XCP-ng: usuário com papel read-only no pool, ou root. Endereço: o mestre do pool.",
        "Conferir certificado: deixe desmarcado se o hipervisor usa o certificado que veio de fábrica. A conexão continua cifrada."
    )) {
        $l = New-GuiLabel $passo 12 $y 796
        $l.Height = 36
        $guiaHv.Controls.Add($l)
        $y += 36
    }
    $p.Controls.Add($guiaHv)
    foreach ($hv in @($script:Hipervisores)) {
        $i = $g.Hipervisores.Rows.Add()
        $r = $g.Hipervisores.Rows[$i]
        $r.Cells["nome"].Value = $hv.nome
        $r.Cells["tipo"].Value = $script:TiposHipervisor[$hv.tipo]
        $r.Cells["endereco"].Value = $hv.endereco
        $r.Cells["usuario"].Value = $hv.usuario
        $r.Cells["verificar"].Value = [bool]$hv.verificar
        if ($hv.segredo) { $r.Cells["segredo"].Value = $hv.segredo } else { $r.Tag = "mantida" }
    }

    # ---------------- Credenciais ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Credenciais"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaCredenciais = $p
    $p.Controls.Add((New-GuiLabel "Credencial do NOC (Bitwarden)" 24 16 600 -Titulo))
    Add-GuiLegendaObrigatorio $p
    [void](Add-GuiRotulo $p "Usuário (métricas)" 24 62 200 -Obrigatorio)
    $g.RwUser = New-GuiTextBox 230 59 300 ([string]$script:RwUsername)
    $p.Controls.Add($g.RwUser)
    [void](Add-GuiRotulo $p "Senha (métricas)" 24 102 200 -Obrigatorio)
    $g.RwSenha = New-GuiTextBox 230 99 300 ([string]$script:RwPassword) -Senha
    $p.Controls.Add($g.RwSenha)
    $g.MesmaLoki = New-Object Windows.Forms.CheckBox
    $g.MesmaLoki.Text = "Usar a mesma credencial para logs e eventos (Loki)"
    $g.MesmaLoki.Location = New-Object Drawing.Point(230, 140); $g.MesmaLoki.AutoSize = $true; $g.MesmaLoki.Checked = $true
    $p.Controls.Add($g.MesmaLoki)
    $g.RotuloLokiUser = Add-GuiRotulo $p "Usuário (Loki)" 24 182 200 -Obrigatorio
    $g.LokiUser = New-GuiTextBox 230 179 300
    $p.Controls.Add($g.LokiUser)
    $g.RotuloLokiSenha = Add-GuiRotulo $p "Senha (Loki)" 24 222 200 -Obrigatorio
    $g.LokiSenha = New-GuiTextBox 230 219 300 "" -Senha
    $p.Controls.Add($g.LokiSenha)
    $p.Controls.Add((New-GuiLabel "As credenciais ficam no registro do serviço do Alloy, com acesso só de SYSTEM e Administradores." 24 262 820 -Dica))
    # Com a mesma credencial, os campos do Loki somem em vez de ficar cinza.
    $g.AtualizarLoki = {
        $gg = $script:Gui
        Set-GuiVisivel @($gg.RotuloLokiUser, $gg.LokiUser, $gg.RotuloLokiSenha, $gg.LokiSenha) (-not $gg.MesmaLoki.Checked)
    }
    $g.MesmaLoki.Add_CheckedChanged({ & $script:Gui.AtualizarLoki })
    if ($Edicao -and $script:LokiUsername -and ($script:LokiUsername -ne $script:RwUsername -or $script:LokiPassword -ne $script:RwPassword)) {
        $g.MesmaLoki.Checked = $false
        $g.LokiUser.Text = [string]$script:LokiUsername
        $g.LokiSenha.Text = [string]$script:LokiPassword
    }
    & $g.AtualizarLoki

    # ---------------- Resumo ----------------
    $p = New-Object Windows.Forms.TabPage; $p.Text = "Resumo"; $p.BackColor = [Drawing.Color]::White
    $g.PaginaResumo = $p
    $p.Controls.Add((New-GuiLabel "Confira antes de instalar" 24 16 600 -Titulo))
    $g.Resumo = New-Object Windows.Forms.TextBox
    $g.Resumo.Multiline = $true; $g.Resumo.ReadOnly = $true; $g.Resumo.ScrollBars = "Vertical"
    $g.Resumo.Font = New-Object Drawing.Font("Consolas", 10)
    $g.Resumo.BackColor = [Drawing.Color]::White
    $g.Resumo.Location = New-Object Drawing.Point(24, 52); $g.Resumo.Size = New-Object Drawing.Size(820, 420)
    $p.Controls.Add($g.Resumo)

    # ---------------- Montagem da árvore e das abas ----------------
    $g.MontarArvore = {
        $gg = $script:Gui
        $marcados = @{}
        foreach ($n in $gg.Arvore.Nodes) {
            $marcados[$n.Name] = $n.Checked
            foreach ($f in $n.Nodes) { $marcados[$f.Name] = $f.Checked }
        }
        $primeira = ($gg.Arvore.Nodes.Count -eq 0)
        $monitora = ($gg.Modo.SelectedIndex -ne 1)
        $coleta = ($gg.Modo.SelectedIndex -ne 0)
        $gg.Basico.Visible = $monitora
        $gg.Arvore.BeginUpdate()
        $gg.Arvore.Nodes.Clear()
        $novo = {
            param($Pai, [string]$Chave, [string]$Texto, [bool]$Padrao)
            if ($null -ne $gg.Inicial -and $gg.Inicial.ContainsKey($Chave)) { $Padrao = [bool]$gg.Inicial[$Chave] }
            $n = New-Object Windows.Forms.TreeNode($Texto)
            $n.Name = $Chave
            $n.Checked = $(if ($primeira -or -not $marcados.ContainsKey($Chave)) { $Padrao } else { [bool]$marcados[$Chave] })
            if ($null -eq $Pai) { [void]$gg.Arvore.Nodes.Add($n) } else { [void]$Pai.Nodes.Add($n) }
            return $n
        }
        if ($monitora) {
            # Perfil básico: sempre coletado, aparece marcado e travado.
            $fixo = {
                param($Pai, [string]$Chave, [string]$Texto)
                $n = & $novo $Pai $Chave $Texto $true
                $n.Tag = "fixo"
                $n.ForeColor = [Drawing.SystemColors]::GrayText
                return $n
            }
            $basico = & $fixo $null "basico" "Perfil básico (sempre ligado)"
            foreach ($item in @(
                @("basico:cpu", "CPU"),
                @("basico:memoria", "Memória"),
                @("basico:discos", "Discos"),
                @("basico:rede", "Rede"),
                @("basico:uptime", "Uptime"),
                @("basico:servicos", "Serviços do Windows")
            )) {
                [void](& $fixo $basico $item[0] $item[1])
            }
            $logs = & $novo $null "logs" "Logs do sistema (Critical e Error)" ([bool]$EnableLogs.IsPresent -or $script:EnableLogsResolved)
            [void](& $novo $logs "logs_warning" "Incluir os avisos (Warning), aumenta muito o volume" ([bool]$EnableLogWarnings.IsPresent))
            $logs.Expand()
            [void](& $novo $null "security" "Logs de autenticação e segurança" ([bool]$EnableSecurityLogs.IsPresent -or $script:EnableSecurityLogsResolved))
            foreach ($feature in $gg.Features) {
                [void](& $novo $null ("feature:{0}" -f $feature.Key) ("{0} (detectado)" -f $feature.Label) ([bool]$feature.Selected))
            }
        }
        if ($coleta) {
            [void](& $novo $null "snmp" "SNMP: firewall, switch, nobreak, AP" ([bool]$EnableSnmp.IsPresent))
            [void](& $novo $null "blackbox" "Conectividade: ping, HTTP, TCP, DNS" ([bool]$EnableBlackbox.IsPresent))
            [void](& $novo $null "internet" "Teste de velocidade (Speedtest)" ([bool]$EnableInternet.IsPresent))
        }
        [void](& $novo $null "coleta" "Internet e links: status, DNS, IP público e causa das quedas" $true)
        [void](& $novo $null "virtualizacao" "Hipervisores pela rede: VMware, Proxmox, XCP-ng" (@($script:Hipervisores).Count -gt 0))
        $exp = & $novo $null "exporter" "Exporters adicionais" ([bool]$EnableExporters.IsPresent)
        foreach ($d in (Get-NextecExporterCatalog)) {
            [void](& $novo $exp ("exporter:{0}" -f $d.Key) $d.Label $false)
        }
        if ($exp.Checked) { $exp.Expand() }
        $gg.Arvore.EndUpdate()
        $gg.Intervalo.Enabled = $coleta
    }

    $g.Marcado = {
        param([string]$Chave)
        $achados = $script:Gui.Arvore.Nodes.Find($Chave, $true)
        return ($achados.Count -gt 0 -and $achados[0].Checked)
    }

    # Exporters marcados viram linhas com o endereço padrão; desmarcados saem.
    $g.SincronizarExporters = {
        $gg = $script:Gui
        $catalogo = Get-NextecExporterCatalog
        foreach ($d in $catalogo) {
            if ($d.Key -eq "custom") { continue }
            $linha = $null
            foreach ($r in $gg.Exporters.Rows) { if ($r.Tag -eq $d.Key) { $linha = $r } }
            $marcado = & $gg.Marcado ("exporter:{0}" -f $d.Key)
            if ($marcado -and $null -eq $linha) {
                $i = $gg.Exporters.Rows.Add($d.Key, $d.DefaultTarget, $d.DefaultService)
                $gg.Exporters.Rows[$i].Tag = $d.Key
                $gg.Exporters.Rows[$i].Cells["nome"].ReadOnly = $true
            }
            elseif (-not $marcado -and $null -ne $linha) {
                $gg.Exporters.Rows.Remove($linha)
            }
        }
        $temCustom = $false
        foreach ($r in $gg.Exporters.Rows) { if ($r.Tag -eq "custom") { $temCustom = $true } }
        if ((& $gg.Marcado "exporter:custom") -and -not $temCustom) {
            $i = $gg.Exporters.Rows.Add()
            $gg.Exporters.Rows[$i].Tag = "custom"
        }
        if (-not (& $gg.Marcado "exporter:custom")) {
            foreach ($r in @($gg.Exporters.Rows)) { if ($r.Tag -eq "custom") { $gg.Exporters.Rows.Remove($r) } }
        }
    }

    $g.MontarAbas = {
        $gg = $script:Gui
        $atual = $gg.Abas.SelectedTab
        $lista = New-Object System.Collections.Generic.List[object]
        [void]$lista.Add($gg.PaginaIdentificacao)
        [void]$lista.Add($gg.PaginaRecursos)
        if (& $gg.Marcado "coleta") { [void]$lista.Add($gg.PaginaLinks) }
        if (& $gg.Marcado "blackbox") { [void]$lista.Add($gg.PaginaBlackbox) }
        if (& $gg.Marcado "snmp") { [void]$lista.Add($gg.PaginaSnmp) }
        if (& $gg.Marcado "exporter") { [void]$lista.Add($gg.PaginaExporters) }
        if (& $gg.Marcado "virtualizacao") { [void]$lista.Add($gg.PaginaVirt) }
        [void]$lista.Add($gg.PaginaCredenciais)
        [void]$lista.Add($gg.PaginaResumo)
        $gg.Abas.SuspendLayout()
        foreach ($pg in @($gg.Abas.TabPages)) { if (-not $lista.Contains($pg)) { $gg.Abas.TabPages.Remove($pg) } }
        # TabPages.Insert não faz nada antes de a janela existir (limitação do
        # WinForms): na montagem inicial as abas entram em ordem com Add.
        for ($i = 0; $i -lt $lista.Count; $i++) {
            if ($gg.Abas.TabPages.Contains($lista[$i])) { continue }
            if ($gg.Abas.IsHandleCreated -and $i -lt $gg.Abas.TabPages.Count) { $gg.Abas.TabPages.Insert($i, $lista[$i]) }
            else { $gg.Abas.TabPages.Add($lista[$i]) }
        }
        $gg.Abas.ResumeLayout()
        if ($null -ne $atual -and $gg.Abas.TabPages.Contains($atual)) { $gg.Abas.SelectedTab = $atual }
        & $gg.SincronizarExporters
    }

    $g.Modo.Add_SelectedIndexChanged({ & $script:Gui.MontarArvore; & $script:Gui.MontarAbas })

    # Validação da aba ao avançar: devolve a mensagem de erro ou "".
    $g.Validar = {
        param($Pagina)
        $gg = $script:Gui
        if ($Pagina -eq $gg.PaginaIdentificacao) {
            if (-not (Get-GuiClienteSlug $gg.Cliente.Text)) { [void]$gg.Cliente.Focus(); return "Informe o cliente." }
            if (-not (Get-GuiSlug $gg.Host.Text)) { [void]$gg.Host.Focus(); return "Informe o nome do host." }
            if (-not (Get-GuiSlug $gg.Local.Text)) { [void]$gg.Local.Focus(); return "Informe o local." }
            $destino = ($gg.Destino.Text.Trim() -replace "^https?://", "") -replace "/.*$", ""
            if ($destino -notmatch "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$") { [void]$gg.Destino.Focus(); return "Destino do NOC inválido." }
        }
        if ($Pagina -eq $gg.PaginaRecursos -and -not (Test-NextecCaminhosSqlite $gg.Sqlite.Text)) {
            [void]$gg.Sqlite.Focus(); return "Bases SQLite: use caminhos completos separados por vírgula (C:\... ou \\servidor\...)."
        }
        if ($Pagina -eq $gg.PaginaLinks) {
            if ($gg.Links.Rows.Count -eq 0) { return "Cadastre pelo menos um link ou desmarque Internet e links." }
            $principais = 0
            foreach ($r in $gg.Links.Rows) {
                $n = $r.Index + 1
                if (-not (Get-GuiCelula $r "operadora")) { return "Link ${n}: informe a operadora." }
                $vel = Get-GuiCelula $r "velocidade"
                if ($vel -and $null -eq (ConvertTo-NextecVelocidade $vel)) { return "Link ${n}: velocidade inválida ($vel). Use Mbps: 500, 1000 ou 600/300." }
                foreach ($a in ((Get-GuiCelula $r "alvos") -split ",")) {
                    if ($a.Trim() -and -not (Test-NextecHost $a.Trim())) { return "Link ${n}: destino inválido ($($a.Trim()))." }
                }
                if (-not (Get-GuiCelula $r "alvos")) { return "Link ${n}: informe os destinos de teste." }
                foreach ($c in @("ip_publico", "gateway", "origem")) {
                    $v = Get-GuiCelula $r $c
                    if ($v -and -not (Test-NextecHost $v)) { return "Link ${n}: $c inválido ($v)." }
                }
                if ((Get-GuiCelula $r "papel") -eq $script:PapeisLink["primario"]) { $principais++ }
            }
            if ($principais -ne 1) { return "Marque exatamente um link como Principal." }
        }
        if ($Pagina -eq $gg.PaginaBlackbox) {
            if ($gg.Blackbox.Rows.Count -eq 0) { return "Cadastre pelo menos um alvo ou desmarque Conectividade." }
            foreach ($r in $gg.Blackbox.Rows) {
                $n = $r.Index + 1
                if (-not (Get-GuiSlug (Get-GuiCelula $r "nome"))) { return "Alvo ${n}: informe o nome." }
                $endereco = Get-GuiCelula $r "endereco"
                if (-not (Test-NextecDestino $endereco)) { return "Alvo ${n}: endereço inválido. $(Get-NextecAddressExample destino)" }
                $teste = Get-GuiCelula $r "modulo"
                if (($teste -eq $script:GuiModulosBlackbox["icmp_ipv4"] -or $teste -eq $script:GuiModulosBlackbox["dns_udp"]) -and -not (Test-NextecHost $endereco)) { return "Alvo ${n}: ping e DNS usam só IP ou nome, sem http:// e sem porta." }
                if ($teste -eq $script:GuiModulosBlackbox["tcp_connect"] -and -not (Test-NextecHostPort $endereco)) { return "Alvo ${n}: o teste TCP precisa de host:porta, ex.: 10.0.0.5:3389." }
            }
        }
        if ($Pagina -eq $gg.PaginaSnmp) {
            if ($gg.Snmp.Rows.Count -eq 0) { return "Cadastre pelo menos um equipamento ou desmarque SNMP." }
            $nomes = @()
            foreach ($r in $gg.Snmp.Rows) {
                $n = $r.Index + 1
                $nome = (Get-GuiSlug (Get-GuiCelula $r "nome")) -replace "[-.]", "_"
                if (-not $nome) { return "Equipamento ${n}: informe o nome." }
                if ($nomes -contains $nome) { return "Equipamento ${n}: nome repetido ($nome)." }
                $nomes += $nome
                if (-not (Test-NextecHost (Get-GuiCelula $r "endereco"))) { return "Equipamento ${n}: IP ou FQDN inválido." }
                $fabricanteOk = $false
                foreach ($k in $NextecSnmpVendors.Keys) { if ($NextecSnmpVendors[$k].Label -eq (Get-GuiCelula $r "fabricante")) { $fabricanteOk = $true } }
                if (-not $fabricanteOk -and -not (Get-GuiCelula $r "modulo_atual")) { return "Equipamento ${n}: escolha o fabricante. Selecione a linha e clique em Editar selecionado." }
                if ($null -eq $r.Tag) { return "Equipamento ${n}: falta a credencial. Selecione a linha e clique em Editar selecionado." }
            }
        }
        if ($Pagina -eq $gg.PaginaVirt) {
            if ($gg.Hipervisores.Rows.Count -eq 0) { return "Cadastre pelo menos um hipervisor ou desmarque Hipervisores pela rede." }
            $nomesHv = @()
            foreach ($r in $gg.Hipervisores.Rows) {
                $n = $r.Index + 1
                $nome = Get-GuiSlug (Get-GuiCelula $r "nome")
                if (-not $nome) { return "Hipervisor ${n}: informe o nome." }
                if ($nomesHv -contains $nome) { return "Hipervisor ${n}: nome repetido ($nome)." }
                $nomesHv += $nome
                if (-not (Test-NextecEnderecoHipervisor (Get-GuiCelula $r "endereco"))) { return "Hipervisor ${n}: endereço inválido. Use IP ou nome, com porta opcional (ex.: 192.168.0.10)." }
                $usuario = Get-GuiCelula $r "usuario"
                if (-not $usuario) { return "Hipervisor ${n}: informe o usuário." }
                if ((Get-GuiCelula $r "tipo") -eq $script:TiposHipervisor["proxmox"] -and $usuario -notmatch '^[^@!]+@[^@!]+![^@!]+$') { return "Hipervisor ${n}: no Proxmox o usuário é o ID do token, ex.: monitor@pve!nextec." }
                if (-not (Get-GuiCelula $r "segredo") -and $r.Tag -ne "mantida") { return "Hipervisor ${n}: informe a senha ou o segredo do token." }
            }
        }
        if ($Pagina -eq $gg.PaginaExporters) {
            if ($gg.Exporters.Rows.Count -eq 0) { return "Marque um serviço em Recursos ou use Adicionar outro serviço." }
            foreach ($r in $gg.Exporters.Rows) {
                $n = $r.Index + 1
                if (-not (Get-GuiSlug (Get-GuiCelula $r "nome"))) { return "Serviço ${n}: informe o nome." }
                if (-not (Test-NextecHostPort (Get-GuiCelula $r "alvo"))) { return "Serviço ${n}: o endereço precisa ser host:porta, ex.: 127.0.0.1:9121." }
            }
        }
        if ($Pagina -eq $gg.PaginaCredenciais) {
            if (-not $gg.RwUser.Text.Trim()) { [void]$gg.RwUser.Focus(); return "Informe o usuário do NOC." }
            if (-not $gg.RwSenha.Text) { [void]$gg.RwSenha.Focus(); return "Informe a senha do NOC." }
            if (-not $gg.MesmaLoki.Checked -and (-not $gg.LokiUser.Text.Trim() -or -not $gg.LokiSenha.Text)) { return "Informe usuário e senha do Loki." }
        }
        return ""
    }

    $g.AtualizarRodape = {
        $gg = $script:Gui
        $i = $gg.Abas.SelectedIndex
        $gg.Voltar.Enabled = ($i -gt 0)
        if ($gg.Abas.SelectedTab -eq $gg.PaginaResumo) {
            $gg.Avancar.Text = $(if ($Simular) { "Concluir simulação" } elseif ($gg.Edicao) { "Aplicar alterações" } else { "Instalar" })
            $gg.Resumo.Text = (Get-GuiResumo)
        }
        else {
            $gg.Avancar.Text = "Avançar"
        }
    }
    $g.Abas.Add_SelectedIndexChanged({ $script:Gui.Erro.Text = ""; & $script:Gui.AtualizarRodape })

    $g.Voltar.Add_Click({ $gg = $script:Gui; if ($gg.Abas.SelectedIndex -gt 0) { $gg.Abas.SelectedIndex-- } })
    $g.Avancar.Add_Click({
        $gg = $script:Gui
        # Erro inesperado aparece no rodapé, sem a caixa de exceção do .NET.
        try {
        # No resumo, todas as abas visíveis precisam estar válidas.
        if ($gg.Abas.SelectedTab -eq $gg.PaginaResumo) {
            foreach ($pg in @($gg.Abas.TabPages)) {
                $msg = & $gg.Validar $pg
                if ($msg) { $gg.Abas.SelectedTab = $pg; $gg.Erro.Text = $msg; return }
            }
            $gg.Confirmado = $true
            $gg.Form.Close()
            return
        }
        $msg = & $gg.Validar $gg.Abas.SelectedTab
        if ($msg) { $gg.Erro.Text = $msg; return }
        $gg.Erro.Text = ""
        $gg.Abas.SelectedIndex++
        }
        catch {
            $gg.Erro.Text = ("Erro: {0}" -f $_.Exception.Message)
        }
    })

    # Todas as abas entram antes da escala: aba que ficasse de fora apareceria
    # depois com o layout de 96 DPI numa tela de 150%.
    foreach ($pg in @($g.PaginaIdentificacao, $g.PaginaRecursos, $g.PaginaLinks, $g.PaginaBlackbox, $g.PaginaSnmp, $g.PaginaExporters, $g.PaginaVirt, $g.PaginaCredenciais, $g.PaginaResumo)) {
        if (-not $abas.TabPages.Contains($pg)) { $abas.TabPages.Add($pg) }
    }
    Set-GuiEscala -Controle $form
    & $g.MontarArvore
    & $g.MontarAbas
    if ($Edicao) {
        # Serviço do catálogo volta na linha dele; os demais em linhas livres.
        foreach ($ce in @($script:CustomExporters)) {
            $linha = $null
            $doCatalogo = Get-NextecExporterDoCatalogo -Exporter $ce
            if ($doCatalogo) { foreach ($r in $g.Exporters.Rows) { if ([string]$r.Tag -eq $doCatalogo) { $linha = $r } } }
            if ($null -eq $linha) {
                foreach ($r in $g.Exporters.Rows) { if ($null -eq $linha -and [string]$r.Tag -eq "custom" -and -not (Get-GuiCelula $r "nome")) { $linha = $r } }
            }
            if ($null -eq $linha) {
                $linha = $g.Exporters.Rows[$g.Exporters.Rows.Add()]
                $linha.Tag = "custom"
            }
            # No config.alloy o bloco se chama custom_N; o nome que o técnico
            # reconhece é o serviço.
            if ([string]$linha.Tag -eq "custom") { $linha.Cells["nome"].Value = $(if ([string]$ce.Name -match '^custom_\d+$' -and $ce.Service) { [string]$ce.Service } else { [string]$ce.Name }) }
            $linha.Cells["alvo"].Value = [string]$ce.Target
            $linha.Cells["servico"].Value = [string]$ce.Service
        }
    }
    & $g.AtualizarRodape
    $form.Add_Shown({ $script:Gui.Form.Activate(); [void]$script:Gui.Cliente.Focus() })
    [void]$form.ShowDialog()
    $confirmado = $g.Confirmado
    if ($confirmado) { Set-NextecConfigurationFromGui }
    $form.Dispose()
    return $confirmado
}

function Get-GuiResumo {
    $gg = $script:Gui
    $linhas = New-Object System.Collections.Generic.List[string]
    $simNao = { param($v) if ($v) { "sim" } else { "não" } }
    [void]$linhas.Add(("Cliente ............ {0}" -f (Get-GuiClienteSlug $gg.Cliente.Text)))
    [void]$linhas.Add(("Host ............... {0}" -f (Get-GuiSlug $gg.Host.Text)))
    [void]$linhas.Add(("Ambiente ........... {0}" -f $gg.Ambiente.SelectedItem))
    [void]$linhas.Add(("Local .............. {0}" -f (Get-GuiSlug $gg.Local.Text)))
    [void]$linhas.Add(("Criticidade ........ {0}" -f $gg.Criticidade.SelectedItem))
    [void]$linhas.Add(("Função ............. {0}" -f $gg.Modo.SelectedItem))
    [void]$linhas.Add(("Destino ............ {0}" -f $gg.Destino.Text.Trim()))
    [void]$linhas.Add("")
    if ($gg.Modo.SelectedIndex -ne 1) {
        [void]$linhas.Add("Perfil básico ...... CPU, memória, discos, rede, uptime, serviços")
        [void]$linhas.Add(("Logs do sistema .... {0}{1}" -f (& $simNao (& $gg.Marcado "logs")), $(if (& $gg.Marcado "logs_warning") { " (com avisos)" } else { "" })))
        [void]$linhas.Add(("Logs de segurança .. {0}" -f (& $simNao (& $gg.Marcado "security"))))
        $feats = @($gg.Features | Where-Object { & $gg.Marcado ("feature:{0}" -f $_.Key) } | ForEach-Object { $_.Label })
        if ($feats.Count -gt 0) { [void]$linhas.Add(("Detectados ......... {0}" -f ($feats -join ", "))) }
        if ($gg.Sqlite.Text.Trim()) { [void]$linhas.Add(("Bases SQLite ....... {0}" -f $gg.Sqlite.Text.Trim())) }
    }
    if (& $gg.Marcado "coleta") {
        [void]$linhas.Add(("Links de internet .. {0}" -f $gg.Links.Rows.Count))
        foreach ($r in $gg.Links.Rows) {
            $vel = Get-GuiCelula $r "velocidade"
            [void]$linhas.Add(("    {0} {1} ({2}) {3}" -f (Get-GuiCelula $r "operadora"), (Get-GuiCelula $r "tipo"), (Get-GuiCelula $r "papel"), $(if ($vel) { "$vel Mbps" } else { "velocidade não informada" })))
        }
    }
    else { [void]$linhas.Add("Internet e links ... não") }
    if (& $gg.Marcado "internet") { [void]$linhas.Add(("Speedtest .......... a cada {0} min" -f $gg.Intervalo.Value)) }
    if (& $gg.Marcado "blackbox") {
        [void]$linhas.Add(("Conectividade ...... {0} alvo(s), a cada {1}" -f $gg.Blackbox.Rows.Count, ($gg.IntervaloBlackbox.SelectedItem -replace " \(.*$", "")))
        foreach ($r in $gg.Blackbox.Rows) { [void]$linhas.Add(("    {0}  {1}  {2}" -f (Get-GuiSlug (Get-GuiCelula $r "nome")), (Get-GuiCelula $r "endereco"), (Get-GuiCelula $r "modulo"))) }
    }
    if (& $gg.Marcado "snmp") {
        [void]$linhas.Add(("SNMP ............... {0} equipamento(s)" -f $gg.Snmp.Rows.Count))
        foreach ($r in $gg.Snmp.Rows) { [void]$linhas.Add(("    {0}  {1}  {2}  {3}" -f ((Get-GuiSlug (Get-GuiCelula $r "nome")) -replace "[-.]", "_"), (Get-GuiCelula $r "endereco"), (Get-GuiCelula $r "fabricante"), (Get-GuiCelula $r "credencial"))) }
    }
    if (& $gg.Marcado "exporter") {
        [void]$linhas.Add(("Exporters .......... {0}" -f $gg.Exporters.Rows.Count))
        foreach ($r in $gg.Exporters.Rows) { [void]$linhas.Add(("    {0}  {1}" -f (Get-GuiCelula $r "nome"), (Get-GuiCelula $r "alvo"))) }
    }
    if (& $gg.Marcado "virtualizacao") {
        [void]$linhas.Add(("Hipervisores ....... {0}" -f $gg.Hipervisores.Rows.Count))
        foreach ($r in $gg.Hipervisores.Rows) { [void]$linhas.Add(("    {0}  {1}  {2}" -f (Get-GuiSlug (Get-GuiCelula $r "nome")), (Get-GuiCelula $r "tipo"), (Get-GuiCelula $r "endereco"))) }
    }
    [void]$linhas.Add("")
    [void]$linhas.Add(("Credencial do NOC .. {0}" -f $(if ($gg.RwUser.Text.Trim()) { $gg.RwUser.Text.Trim() } else { "não informada" })))
    if ($Simular) {
        [void]$linhas.Add("")
        [void]$linhas.Add("SIMULAÇÃO: nada será instalado nem alterado neste computador.")
    }
    return ($linhas -join [Environment]::NewLine)
}

function Set-NextecConfigurationFromGui {
    # Copia as respostas da tela para as mesmas variáveis do fluxo do console.
    $gg = $script:Gui
    $inv = $gg.Inventory
    $script:Cliente = Get-GuiClienteSlug $gg.Cliente.Text
    $script:HostLabel = Get-GuiSlug $gg.Host.Text
    $script:Ambiente = [string]$gg.Ambiente.SelectedItem
    $script:Local = Get-GuiSlug $gg.Local.Text
    $script:Criticidade = [string]$gg.Criticidade.SelectedItem
    $script:NocHost = (($gg.Destino.Text.Trim() -replace "^https?://", "") -replace "/.*$", "").ToLowerInvariant()
    $script:RemoteWriteUrl = "https://$($script:NocHost)/api/v1/write"
    $script:LokiUrl = "https://$($script:NocHost)/loki/api/v1/push"

    $script:MonitorHost = ($gg.Modo.SelectedIndex -ne 1)
    $script:Collector = ($gg.Modo.SelectedIndex -ne 0)
    $estacao = ($inv.ProductType -eq 1)
    if (-not $script:MonitorHost) { $script:ResolvedMode = "collector" }
    elseif ($estacao) { $script:ResolvedMode = $(if ($script:Collector) { "estacao_collector" } else { "estacao" }) }
    else { $script:ResolvedMode = $(if ($script:Collector) { "servidor_collector" } else { "servidor" }) }
    $script:TipoLabel = $(if ($estacao) { "estacao" } else { "servidor" })

    $script:DetectedHostFeatures = @($gg.Features)
    $script:SelectedHostFeatureKeys = [string[]]@($gg.Features | Where-Object { & $gg.Marcado ("feature:{0}" -f $_.Key) } | ForEach-Object { $_.Key })
    $script:EnableLogsResolved = [bool](& $gg.Marcado "logs")
    $script:EnableLogWarningsResolved = [bool](& $gg.Marcado "logs_warning")
    $script:EnableSecurityLogsResolved = [bool](& $gg.Marcado "security")
    $script:EnableSnmpResolved = [bool](& $gg.Marcado "snmp")
    $script:EnableBlackboxResolved = [bool](& $gg.Marcado "blackbox")
    $script:EnableInternetResolved = [bool](& $gg.Marcado "internet")
    $script:InternetIntervalMinutesResolved = [int]$gg.Intervalo.Value
    $script:EnableColetaResolved = [bool](& $gg.Marcado "coleta")
    $script:SelectedExporterKeys = [string[]]@((Get-NextecExporterCatalog) | Where-Object { & $gg.Marcado ("exporter:{0}" -f $_.Key) } | ForEach-Object { $_.Key })
    $script:BancosSqlite = $(if ($script:MonitorHost) { $gg.Sqlite.Text.Trim() } else { "" })

    # Hipervisores pela rede
    $hvs = @()
    if (& $gg.Marcado "virtualizacao") {
        $tipoHvPorTexto = @{}
        foreach ($k in $script:TiposHipervisor.Keys) { $tipoHvPorTexto[$script:TiposHipervisor[$k]] = $k }
        foreach ($r in $gg.Hipervisores.Rows) {
            $segredoHv = Get-GuiCelula $r "segredo"
            $hvs += [pscustomobject]@{
                nome = Get-GuiSlug (Get-GuiCelula $r "nome"); tipo = $tipoHvPorTexto[(Get-GuiCelula $r "tipo")]
                endereco = Get-GuiCelula $r "endereco"; usuario = Get-GuiCelula $r "usuario"
                verificar = [bool]$r.Cells["verificar"].Value; segredo = $(if ($segredoHv) { $segredoHv } else { $null })
            }
        }
    }
    $script:Hipervisores = $hvs

    # Links
    $script:ColetaLinks = @()
    if ($script:EnableColetaResolved) {
        $papelPorTexto = @{}
        foreach ($k in $script:PapeisLink.Keys) { $papelPorTexto[$script:PapeisLink[$k]] = $k }
        $tipoPorTexto = @{}
        foreach ($k in $script:TiposLink.Keys) { $tipoPorTexto[$script:TiposLink[$k]] = $k }
        foreach ($r in $gg.Links.Rows) {
            $tipo = $tipoPorTexto[(Get-GuiCelula $r "tipo")]
            $operadora = ConvertTo-ColetaIniValue (Get-GuiCelula $r "operadora")
            $vel = [pscustomobject]@{ Download = ""; Upload = "" }
            if (Get-GuiCelula $r "velocidade") { $vel = ConvertTo-NextecVelocidade (Get-GuiCelula $r "velocidade") }
            $firewall = Get-GuiSlug (Get-GuiCelula $r "firewall")
            $nome = Get-NomeLinkUnico -Base (ConvertTo-ColetaIniValue ("{0} {1}" -f $operadora, $script:TiposLinkNome[$tipo]))
            $script:ColetaLinks = @($script:ColetaLinks) + [pscustomobject]@{
                nome = $nome; papel = $papelPorTexto[(Get-GuiCelula $r "papel")]; operadora = $operadora; tipo = $tipo; suporte = ""
                ip_publico = Get-GuiCelula $r "ip_publico"; gateway = Get-GuiCelula $r "gateway"
                alvos = ((Get-GuiCelula $r "alvos") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ", "
                origem = Get-GuiCelula $r "origem"; firewall = $firewall
                interface_firewall = $(if ($firewall) { Get-GuiCelula $r "interface_firewall" } else { "" })
                velocidade_mbps = $vel.Download; velocidade_upload_mbps = $vel.Upload
            }
        }
    }
    $script:EnableLinksResolved = ($script:ColetaLinks.Count -gt 0)

    # Conectividade: nome repetido ganha o sufixo do teste, como no console.
    $script:BlackboxTargets = @()
    if ($script:EnableBlackboxResolved) {
        $moduloPorTexto = @{}
        foreach ($k in $script:GuiModulosBlackbox.Keys) { $moduloPorTexto[$script:GuiModulosBlackbox[$k]] = $k }
        $contagem = @{}
        foreach ($r in $gg.Blackbox.Rows) { $n = Get-GuiSlug (Get-GuiCelula $r "nome"); $contagem[$n] = 1 + [int]$contagem[$n] }
        foreach ($r in $gg.Blackbox.Rows) {
            $n = Get-GuiSlug (Get-GuiCelula $r "nome")
            $textoTeste = Get-GuiCelula $r "modulo"
            $modulo = $moduloPorTexto[$textoTeste]
            if (-not $modulo) { $modulo = $(if ($textoTeste) { $textoTeste } else { "icmp_ipv4" }) }
            $nomeFinal = $(if ($contagem[$n] -gt 1) { "{0}_{1}" -f $n, $script:GuiSufixoBlackbox[$modulo] } else { $n })
            $script:BlackboxTargets += [pscustomobject]@{ Name = $nomeFinal; Address = Get-GuiCelula $r "endereco"; Module = $modulo; Type = Get-GuiCelula $r "tipo" }
        }
        $script:BlackboxIntervalSecondsResolved = @(10, 15, 30, 60)[$gg.IntervaloBlackbox.SelectedIndex]
    }

    # SNMP: o arquivo de cada fabricante é baixado na instalação (Install-SnmpConfiguration).
    $script:SnmpTargets = @()
    $script:SnmpAuthBlocks = @()
    $script:GuiFabricantesSnmp = @()
    if ($script:EnableSnmpResolved) {
        $chavePorRotulo = @{}
        foreach ($k in $NextecSnmpVendors.Keys) { $chavePorRotulo[$NextecSnmpVendors[$k].Label] = $k }
        foreach ($r in $gg.Snmp.Rows) {
            $nome = (Get-GuiSlug (Get-GuiCelula $r "nome")) -replace "[-.]", "_"
            $rotulo = Get-GuiCelula $r "fabricante"
            $vendor = $null
            if ($chavePorRotulo.ContainsKey($rotulo)) { $vendor = $NextecSnmpVendors[$chavePorRotulo[$rotulo]] }
            $cred = $r.Tag
            $mantida = ($null -ne $cred.PSObject.Properties["Bruto"])
            if ($mantida) {
                # Credencial que a janela não representa: o bloco segue igual.
                $auth = Get-SnmpAuthBlockName -Block $cred.Bruto
                $script:SnmpAuthBlocks += $cred.Bruto
            }
            else {
                $auth = "{0}_{1}" -f $nome, $cred.Versao
                $script:SnmpAuthBlocks += (ConvertTo-SnmpAuthYaml -Nome $auth -Credencial $cred)
            }
            if ($null -ne $vendor -and -not $mantida) {
                $base = [IO.Path]::GetFileNameWithoutExtension($vendor.File)
                $modulo = "{0}_{1}" -f $base, $cred.Versao
                if ($script:GuiFabricantesSnmp -notcontains $vendor.File) { $script:GuiFabricantesSnmp += $vendor.File }
            }
            else {
                # Fabricante fora do catálogo ou credencial mantida: continua
                # com o módulo que já estava configurado.
                $base = $(if ($null -ne $vendor) { [IO.Path]::GetFileNameWithoutExtension($vendor.File) } else { $rotulo })
                $modulo = Get-GuiCelula $r "modulo_atual"
            }
            $script:SnmpTargets += [pscustomobject]@{
                Name = $nome; Address = Get-GuiCelula $r "endereco"; Module = $modulo
                Auth = $auth; Type = Get-GuiCelula $r "tipo"; Os = $base
            }
        }
    }

    $script:CustomExporters = @()
    foreach ($r in $gg.Exporters.Rows) {
        if (-not (& $gg.Marcado "exporter")) { break }
        $script:CustomExporters += [pscustomobject]@{
            Name = Get-GuiSlug (Get-GuiCelula $r "nome"); Target = Get-GuiCelula $r "alvo"
            Service = $(if (Get-GuiCelula $r "servico") { Get-GuiSlug (Get-GuiCelula $r "servico") } else { Get-GuiSlug (Get-GuiCelula $r "nome") })
        }
    }
    $script:EnableExportersResolved = ($script:CustomExporters.Count -gt 0)

    $script:RwUsername = $gg.RwUser.Text.Trim()
    $script:RwPassword = $gg.RwSenha.Text
    if ($gg.MesmaLoki.Checked) {
        $script:LokiUsername = $script:RwUsername
        $script:LokiPassword = $script:RwPassword
    }
    else {
        $script:LokiUsername = $gg.LokiUser.Text.Trim()
        $script:LokiPassword = $gg.LokiSenha.Text
    }
    if (-not (Test-NextecNeedsLoki)) {
        $script:LokiUsername = ""
        $script:LokiPassword = ""
    }
    $script:ConfirmadoNaTela = $true
}

function Get-NextecSnmpVendorFiles {
    <#
        Baixa os snmp.yml dos fabricantes escolhidos na tela e junta os
        módulos num arquivo temporário, que Install-SnmpConfiguration soma ao
        snmp.yml do host.
    #>
    param([string[]]$Arquivos)
    $junto = Join-Path $env:TEMP ("nextec-snmp-tela-{0}.yml" -f $PID)
    if (Test-Path -LiteralPath $junto) { Remove-Item -LiteralPath $junto -Force }
    foreach ($arquivo in $Arquivos) {
        $destino = Join-Path $env:TEMP ("nextec-snmp-{0}" -f $arquivo)
        Invoke-NextecDownload -Url ("{0}/{1}" -f $NextecSnmpRepoBaseUrl, $arquivo) -Destino $destino -Descricao ("snmp.yml {0}" -f $arquivo) -TimeoutSec 120
        Merge-SnmpModuleFile -NewFile $destino -Destination $junto
    }
    return $junto
}

function Save-NextecSimulacao {
    # -Simular: grava o que seria instalado, sem senha, para conferência.
    $saida = Join-Path $env:TEMP "nextec-simulacao.json"
    $dados = [ordered]@{
        instalador = $InstallerVersion
        cliente = $script:Cliente; host = $script:HostLabel; ambiente = $script:Ambiente; local = $script:Local
        criticidade = $script:Criticidade; modo = $script:ResolvedMode; destino = $script:NocHost
        recursos_detectados = @($script:SelectedHostFeatureKeys)
        logs = $script:EnableLogsResolved; avisos = $script:EnableLogWarningsResolved; seguranca = $script:EnableSecurityLogsResolved
        coleta = $script:EnableColetaResolved; links = @($script:ColetaLinks)
        speedtest = $script:EnableInternetResolved; speedtest_min = $script:InternetIntervalMinutesResolved
        blackbox = @($script:BlackboxTargets); blackbox_intervalo = $script:BlackboxIntervalSecondsResolved
        snmp = @($script:SnmpTargets); snmp_fabricantes = @($script:GuiFabricantesSnmp)
        snmp_credenciais = @($script:SnmpAuthBlocks | ForEach-Object { Get-SnmpAuthBlockName -Block $_ })
        exporters = @($script:CustomExporters)
        bancos_coleta = @(Get-NextecBancosMotores); bancos_sqlite = $script:BancosSqlite
        virtualizacao_local = (Get-NextecVirtLocal)
        hipervisores = @($script:Hipervisores | ForEach-Object { [ordered]@{ nome = $_.nome; tipo = $_.tipo; endereco = $_.endereco; usuario = $_.usuario; verificar = $_.verificar; segredo_informado = [bool]$_.segredo } })
        usuario_noc = $script:RwUsername
        loki_mesma_credencial = ($script:LokiUsername -eq $script:RwUsername -and $script:LokiPassword -eq $script:RwPassword)
    }
    [IO.File]::WriteAllText($saida, ($dados | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Write-Ok ("Simulação concluída. Nada foi instalado. Respostas em {0}" -f $saida)
}

function Invoke-NextecSimulacao {
    # Mesmo caminho da instalação até o resumo, sem tocar no computador.
    Write-Step "Simulação: nada será instalado"
    $script:NocHost = $NocTarget
    $script:RemoteWriteUrl = "https://$($script:NocHost)/api/v1/write"
    $script:LokiUrl = "https://$($script:NocHost)/loki/api/v1/push"
    $inventory = Get-WindowsInventory
    $serverRoles = @(Get-WindowsServerRoles -Inventory $inventory)
    $sql = Get-SqlServerDetection
    $firebird = Get-FirebirdDetection
    $detectedFeatures = @(Get-DetectedHostFeatures -Inventory $inventory -ServerRoles $serverRoles -Sql $sql -Firebird $firebird)
    Show-DetectionSummary -Inventory $inventory -DetectedFeatures @($detectedFeatures)
    if ($script:UsarTela) {
        if (-not (Show-NextecInstallerGui -Inventory $inventory -DetectedFeatures $detectedFeatures)) {
            Write-Info "Tela fechada sem concluir."
            return
        }
        Open-NextecGuiProgresso -Inventory $inventory -Titulo "Simulação em andamento"
    }
    else {
        Get-NextecConfiguration -Inventory $inventory -DetectedFeatures $detectedFeatures
        Read-NocCredentials
    }
    Show-Plan -Inventory $inventory
    Save-NextecSimulacao
}

function Invoke-NextecInstaller {
    Show-Banner
    $script:UsarTela = Test-NextecUseGui

    if ($Simular) {
        Invoke-NextecSimulacao
        return
    }

    Initialize-Logging
    Assert-Administrator

    try {
        if ($Atualizar) {
            Invoke-NextecAtualizacao
            return
        }

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
        if ($script:UsarTela) {
            Write-Info "Preencha a tela de instalação. O andamento aparece na própria tela."
            if (-not (Show-NextecInstallerGui -Inventory $inventory -DetectedFeatures $detectedFeatures)) {
                throw "Instalação cancelada pelo operador."
            }
            Open-NextecGuiProgresso -Inventory $inventory -Titulo "Instalação em andamento"
        }
        else {
            Get-NextecConfiguration -Inventory $inventory -DetectedFeatures $detectedFeatures
            Read-NocCredentials
        }
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
                if (@($script:GuiFabricantesSnmp).Count -gt 0) {
                    $script:SnmpSourceFile = Get-NextecSnmpVendorFiles -Arquivos $script:GuiFabricantesSnmp
                }
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

        if (Test-NextecColetaNecessaria) {
            Invoke-NextecOptionalStep -Nome "Coleta Complementar" -Acao {
                Install-ColetaComplementar
            } -AoFalhar {
                $script:EnableColetaResolved = $false
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
        Invoke-NextecOptionalStep -Nome "Remoção do Speedtest antigo" -Acao { Remove-NextecSpeedtestLegado } -AoFalhar { } | Out-Null
        Invoke-NextecVerification -Nome "Teste de ingestão no NOC" -Acao { Test-AlloyIngestion }

        # Depois do Alloy validado: falha aqui não desfaz o monitoramento.
        Invoke-NextecOptionalStep -Nome "Atualizador automático" -Acao {
            Install-Atualizador
        } | Out-Null

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
    $precisaElevar = (-not $Simular) -and (-not (Test-NextecIsAdministrator))

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

    # Com a tela, o resultado fica na janela de andamento até o técnico
    # fechar; o console volta a aparecer só depois.
    if ($null -ne $script:GuiProgresso) {
        $logTexto = $(if ([string]::IsNullOrWhiteSpace([string]$script:InstallerLog)) { "" } else { " Log: {0}" -f $script:InstallerLog })
        if ($Simular) {
            if ($script:ExitCode -eq 0) { Complete-NextecGuiProgresso -Sucesso $true -Titulo "Simulação concluída" -Mensagem "Nada foi instalado neste computador. Pode fechar." }
            else { Complete-NextecGuiProgresso -Sucesso $false -Titulo "A simulação parou com erro" -Mensagem "Veja a mensagem em vermelho acima." }
        }
        elseif ($script:ExitCode -eq 0) { Complete-NextecGuiProgresso -Sucesso $true -Titulo $(if ($script:GuiTituloSucesso) { $script:GuiTituloSucesso } else { "Instalação concluída" }) -Mensagem ("Confira o resumo acima.{0}" -f $logTexto) }
        elseif ($script:ExitCode -eq 2) { Complete-NextecGuiProgresso -Sucesso $true -Titulo "Instalação concluída com pendências" -Mensagem ("O monitoramento básico está ativo; veja os avisos acima.{0}" -f $logTexto) }
        else { Complete-NextecGuiProgresso -Sucesso $false -Titulo $(if ($script:GuiTituloFalha) { $script:GuiTituloFalha } else { "A instalação falhou" }) -Mensagem ("Veja a mensagem em vermelho acima.{0}" -f $logTexto) }
    }
    Set-NextecConsoleVisivel $true

    # Segura a janela antes de devolver o controle, porque o console aberto por
    # duplo clique ou atalho fecha assim que o script retorna. Quando o
    # trabalho foi delegado a outra sessão, quem espera o operador é ela; com a
    # tela, quem esperou foi a janela de andamento.
    if (-not $Silent -and -not $script:Relaunched -and -not $script:UsouProgresso -and -not $script:DispensarEspera) {
        Wait-NextecOperator
    }
    Restore-NextecConsoleTheme
}

# Dot-source (". .\script.ps1") roda no processo do operador, e ali "exit"
# encerraria a sessão inteira dele. Fora esse caso, o código de saída é o que
# permite a automação distinguir sucesso de falha, inclusive quando o trabalho
# foi feito pela sessão elevada.
if ($MyInvocation.InvocationName -ne ".") {
    exit $script:ExitCode
}