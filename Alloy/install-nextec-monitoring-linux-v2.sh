#!/usr/bin/env bash
# ==============================================================================
# Nextec NOC Monitoring Installer for Linux
# Versão: 2.7.0 (Testes de conectividade do mais simples ao mais completo; obrigatórios marcados; velocidade em Mbps)
#
# USO
# ---
#   sudo bash install-nextec-monitoring-linux-v2.sh                   instalação completa;
#     em servidor já instalado, abre o menu de manutenção (ver e alterar a
#     configuração, reconfigurar tudo, atualizar o Alloy, validar e reiniciar)
#   sudo bash install-nextec-monitoring-linux-v2.sh --somente-coleta  só a Coleta
#     Complementar, para servidor cujo Alloy roda fora deste instalador
#     (ex.: o servidor da central, coletado pelo Alloy da stack)
#   sudo bash install-nextec-monitoring-linux-v2.sh --atualizar       reaplica sem
#     perguntas, com as respostas gravadas em /etc/nextec/instalacao.conf. É o
#     modo usado pelo atualizador automático (nextec-atualizador), que entrega
#     os arquivos já conferidos por assinatura em COLETA_ARQUIVO e
#     ATUALIZADOR_ARQUIVO e a versão do Alloy em ALLOY_VERSAO.
#
# OBJETIVO
# -------
# Instalar e configurar Grafana Alloy em servidores Linux para enviar métricas
# e, opcionalmente, logs e métricas adicionais ao NOC da Nextec.
#
# PRINCÍPIOS DE MANUTENÇÃO
# -----------------------
# 1. O perfil mínimo monitora apenas métricas do servidor. Serviços são opcionais.
# 2. Docker é detectado automaticamente e oferecido como opção pré-selecionada.
# 3. Bancos de dados são detectados automaticamente, mas a coleta só é ativada
#    após confirmação, pois normalmente exige credencial de leitura/monitoramento.
# 4. Credenciais não são gravadas no config.alloy. Ficam no arquivo de ambiente
#    do serviço com permissão 0600.
# 5. "Conectividade e disponibilidade (Blackbox)" é o nome humano. Internamente,
#    o componente continua se chamando blackbox, seguindo a nomenclatura Grafana.
# 6. Antes de reiniciar o Alloy, o instalador executa `alloy fmt` e `alloy validate`.
# 7. Em caso de falha após alterar uma instalação existente, há rollback do config.
# 8. O que o Alloy não coleta sozinho (internet, links, estado e eventos do
#    Docker, teste de velocidade) fica com a Coleta Complementar Nextec, baixada
#    do repositório Scripts. Ela só grava arquivos locais; quem envia é o Alloy.
# 9. As respostas ficam em /etc/nextec/instalacao.conf (sem senha) e o
#    atualizador automático reaplica esta instalação a cada versão publicada e
#    assinada pela Nextec. Ver Alloy/atualizador/README.md.
#
# DISTRIBUIÇÕES
# ------------
# O instalador tenta usar o gerenciador de pacotes nativo quando possível:
#   Debian/Ubuntu: apt
#   RHEL/Rocky/Alma/Fedora: dnf ou yum
#   SUSE/openSUSE: zypper
# Em outros Linux modernos com systemd, usa o binário oficial do Alloy como fallback.
#
# Não é suportado automaticamente: Linux sem systemd, arquiteturas diferentes de
# amd64/arm64, appliances proprietários e distribuições extremamente minimalistas.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_VERSION="2.7.0"
DEFAULT_NOC_HOST="noc.nex.tec.br"
NOC_HOST="${DEFAULT_NOC_HOST}"
RW_URL=""
LOKI_URL=""

CONFIG_DIR="/etc/alloy"
CONFIG_FILE="${CONFIG_DIR}/config.alloy"
BACKUP_DIR="${CONFIG_DIR}/backup"
BLACKBOX_FILE="${CONFIG_DIR}/blackbox.yml"
SNMP_FILE="${CONFIG_DIR}/snmp.yml"
# Credenciais SNMP do cliente, separadas do módulo do fabricante (público).
SNMP_AUTH_FILE="${CONFIG_DIR}/snmp-auth.yml"
# snmp.yml homologados por fabricante. Pode ser sobrescrita para testar uma branch.
SNMP_REPO_URL="${SNMP_REPO_URL:-https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/snmp}"

# Coleta Complementar Nextec: completa o que o Alloy não coleta sozinho.
# COLETA_URL pode ser sobrescrita por variável de ambiente para testar uma branch.
COLETA_URL="${COLETA_URL:-https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/coleta-complementar/coleta-complementar.py}"
COLETA_BIN="/usr/local/lib/nextec/coleta-complementar.py"
COLETA_CONFIG_DIR="/etc/coleta-complementar"
COLETA_CONFIG="${COLETA_CONFIG_DIR}/coleta-complementar.ini"
COLETA_DADOS="/var/lib/coleta-complementar"
COLETA_TEXTFILE="${COLETA_DADOS}/textfile"
COLETA_EVENTOS="/var/log/coleta-complementar/eventos.jsonl"
COLETA_SERVICE="/etc/systemd/system/coleta-complementar.service"
SPEEDTEST_CLI_VERSION="1.2.0"
SPEEDTEST_BIN="/usr/local/bin/speedtest"

# Atualizador automático e respostas da instalação.
NEXTEC_DIR="/etc/nextec"
ESTADO_INSTALACAO="${NEXTEC_DIR}/instalacao.conf"
ATUALIZADOR_URL="${ATUALIZADOR_URL:-https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/atualizador/nextec-atualizador.py}"
ATUALIZADOR_BIN="/usr/local/lib/nextec/nextec-atualizador.py"
ATUALIZADOR_CONFIG="${NEXTEC_DIR}/atualizador.conf"
ATUALIZADOR_SERVICE="/etc/systemd/system/nextec-atualizador.service"
ATUALIZADOR_TIMER="/etc/systemd/system/nextec-atualizador.timer"
# 1 quando roda em --atualizar: nenhuma pergunta, nada de credencial nova.
MODO_ATUALIZACAO=0
# Menu de manutenção (instalação existente). EDICAO=1 aplica uma alteração
# pontual: credenciais que não foram alteradas ficam como estão.
EDICAO=0
NOVAS_CREDENCIAIS=0
DB_REDEFINIDO=0
CHECKLIST_DO_ESTADO=0
ESTADO_CARREGADO=0
ESTADO_INSTALADOR_VERSAO=""
SEGUIR_INSTALACAO=1
# Listas preenchidas pelas perguntas ou pelas respostas gravadas.
LINKS=(); BLACKBOX_TARGETS=(); SNMP_TARGETS=(); CUSTOM_EXPORTERS=(); DATABASE_TARGETS=(); DETECTED_DATABASES=()

# O pacote oficial usa /etc/default/alloy em Debian. No fallback binário também
# adotamos o mesmo local para manter um único padrão de manutenção.
ENV_FILE="/etc/default/alloy"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/alloy.service.d"
SYSTEMD_OVERRIDE="${SYSTEMD_OVERRIDE_DIR}/10-nextec.conf"

# Cores ANSI. Se o terminal não suportar cores, o conteúdo continua legível.
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[0;37m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
# No modo --atualizar a saída vai para o log do atualizador: sem códigos de cor.
if [[ "${1:-}" == "--atualizar" ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; WHITE=''; BOLD=''; DIM=''; NC=''
fi

# Locale UTF-8 para ${#texto} contar caracteres (e não bytes) no alinhamento
# do resumo, mesmo quando o terminal chega com LANG vazio (locale C).
LOCALE_UTF8="$(locale -a 2>/dev/null | grep -m1 -iE '^(c|en_us)\.utf-?8$' || true)"

ok()   { echo -e "${GREEN}✔${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
# warn e err vão para stderr: assim não contaminam o valor de perguntas
# chamadas dentro de $(...).
warn() { echo -e "${YELLOW}⚠${NC}  $*" >&2; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }
step() {
  # Título de etapa: barra colorida e linha, para separar bem cada fase.
  local titulo="$*"
  echo
  echo -e "${BLUE}${BOLD}▌ ${titulo}${NC}"
  echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"
}

# pergunta "texto" "padrão" "dica": monta o texto colorido de uma pergunta.
# ? em ciano, pergunta em negrito, padrão e dica apagados.
pergunta() {
  local texto="$1" padrao="${2:-}" dica="${3:-}" obrigatorio="${4:-0}" saida
  saida="${CYAN}?${NC} ${BOLD}${texto}${NC}"
  [[ "$obrigatorio" == "1" ]] && saida+="${RED}${BOLD} *${NC}"
  [[ -n "$dica" ]] && saida+=" ${DIM}(${dica})${NC}"
  [[ -n "$padrao" ]] && saida+=" ${DIM}[${padrao}]${NC}"
  echo -e "${saida}: "
}

# ------------------------------------------------------------------------------
# TRATAMENTO DE ERRO E ROLLBACK
# ------------------------------------------------------------------------------
cleanup_on_error() {
  local ec=$?
  err "Falha em ${FUNCNAME[1]:-main}, linha ${BASH_LINENO[0]}. Código: ${ec}."

  if [[ -f "${CONFIG_FILE}.nextec-preinstall" ]]; then
    warn "Restaurando configuração anterior do Alloy."
    cp -f "${CONFIG_FILE}.nextec-preinstall" "$CONFIG_FILE" || true
    systemctl restart alloy >/dev/null 2>&1 || true
  fi
  exit "$ec"
}
trap cleanup_on_error ERR

banner() {
  [[ "$MODO_ATUALIZACAO" == "1" ]] || clear 2>/dev/null || true
  echo -e "${BLUE}${BOLD}"
  cat <<'TXT'
 _   _ _______  _______ _____ ____
| \ | | ____\ \/ /_   _| ____/ ___|
|  \| |  _|  \  /  | | |  _|| |
| |\  | |___ /  \  | | | |__| |___
|_| \_|_____/_/\_\ |_| |_____\____|
TXT
  echo
  echo -e "${NC}${BOLD}NOC Monitoring Installer, Linux${NC}  ${DIM}v${INSTALLER_VERSION}${NC}"
  echo -e "Destino: ${CYAN}${NOC_HOST}${NC}\n"
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Execute como root: sudo bash $0"
    exit 1
  fi
}

need_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "Esta versão requer systemd/systemctl."
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# FUNÇÕES DE ENTRADA
# ------------------------------------------------------------------------------
normalize_slug() {
  local input="$1"
  # python3 remove acentos de forma confiável em qualquer locale; o iconv com
  # //TRANSLIT troca "ó" por "?" no locale C ("cartório" viraria "cart_rio").
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import re,sys,unicodedata
v=unicodedata.normalize("NFKD",sys.argv[1]).encode("ascii","ignore").decode().lower()
v=re.sub(r"[^a-z0-9_-]+","_",v)
print(re.sub(r"_+","_",v).strip("_"),end="")' "$input"
  elif command -v iconv >/dev/null 2>&1; then
    printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+|_+$//g; s/_+/_/g'
  else
    printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+|_+$//g; s/_+/_/g'
  fi
}

entrada_encerrada() {
  # Sem terminal (entrada fechada), repetir a pergunta viraria laço infinito.
  echo >&2
  err "Entrada encerrada antes de responder. Rode o instalador em um terminal interativo."
  exit 1
}

ask_required() {
  local prompt="$1" default="${2:-}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$(pergunta "$prompt" "$default" "" 1)" value || entrada_encerrada
      value="${value:-$default}"
    else
      read -r -p "$(pergunta "$prompt" "" "" 1)" value || entrada_encerrada
    fi
    value="$(trim "$value")"
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "Campo obrigatório."
  done
}

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# ------------------------------------------------------------------------------
# VALIDAÇÃO DE ENTRADAS
# Toda resposta digitada passa por aqui: valor inválido gera aviso e a pergunta
# é repetida. O instalador nunca encerra por erro de digitação.
# ------------------------------------------------------------------------------
RE_HOSTNAME='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$'
RE_IPV4='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
RE_URL='^https?://([^/:?#]+)(:([0-9]+))?([/?#].*)?$'
RE_INTERFACE='^[A-Za-z0-9._:/-]+$'

is_ipv4() {
  [[ "$1" =~ $RE_IPV4 ]] || return 1
  local octeto octetos=("${BASH_REMATCH[@]:1:4}")
  for octeto in "${octetos[@]}"; do
    (( 10#$octeto <= 255 )) || return 1
  done
}

is_host() {
  is_ipv4 "$1" && return 0
  [[ "$1" =~ [A-Za-z] ]] || return 1   # só números e pontos tem que ser IP válido
  [[ ${#1} -le 253 && "$1" =~ $RE_HOSTNAME ]]
}

is_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_hostport() {
  [[ "$1" == *:* ]] || return 1
  is_host "${1%:*}" && is_port "${1##*:}"
}

is_destino() {
  # Destino de sonda: URL http(s), host/IP ou host:porta.
  if [[ "$1" =~ $RE_URL ]]; then
    # Guarda as capturas antes: is_host usa =~ e sobrescreve BASH_REMATCH.
    local url_host="${BASH_REMATCH[1]}" url_porta="${BASH_REMATCH[3]}"
    is_host "$url_host" || return 1
    [[ -z "$url_porta" ]] || is_port "$url_porta"
    return
  fi
  is_host "$1" || is_hostport "$1"
}

address_example() {
  case "$1" in
    ip)       echo "ex.: 192.168.0.1";;
    host)     echo "ex.: 192.168.0.1 ou fw.cliente.com.br";;
    hostport) echo "ex.: 127.0.0.1:9121";;
    destino)  echo "ex.: 192.168.0.1, cliente.com.br, https://cliente.com.br ou 10.0.0.5:3389";;
  esac
}

address_valid() {
  case "$1" in
    ip)       is_ipv4 "$2";;
    host)     is_host "$2";;
    hostport) is_hostport "$2";;
    destino)  is_destino "$2";;
    *)        return 1;;
  esac
}

# ask_address "Pergunta" "padrão" tipo [opcional 0/1] [lista 0/1]
# tipo: ip, host, hostport ou destino. Lista aceita vários separados por vírgula.
ask_address() {
  local prompt="$1" default="${2:-}" kind="$3" optional="${4:-0}" list="${5:-0}"
  local value item ok_all itens=() invalidos=()
  while true; do
    if [[ "$optional" == "1" ]]; then
      read -r -p "$(pergunta "$prompt" "" "ENTER para pular")" value || entrada_encerrada
      value="$(trim "$value")"
      [[ -z "$value" ]] && { printf ''; return 0; }
    else
      value="$(ask_required "$prompt" "$default")"
    fi

    if [[ "$list" == "1" ]]; then
      itens=()
      invalidos=()
      IFS=',' read -r -a partes <<<"$value"
      for item in "${partes[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        if address_valid "$kind" "$item"; then itens+=("$item"); else invalidos+=("$item"); fi
      done
      if (( ${#invalidos[@]} == 0 && ${#itens[@]} > 0 )); then
        local IFS=','
        printf '%s' "${itens[*]}" | sed 's/,/, /g'
        return 0
      fi
      warn "Endereço inválido: ${invalidos[*]:-vazio}. Use $(address_example "$kind"), separados por vírgula."
    else
      if address_valid "$kind" "$value"; then
        printf '%s' "$value"
        return 0
      fi
      warn "Endereço inválido: ${value}. Use $(address_example "$kind")."
    fi
  done
}

# ask_slug "Pergunta" "padrão" tipo
# tipo cliente/label: minúsculas, números e _ (hífen e espaço viram _).
# tipo host: igual, mas mantém hífen (hostnames reais usam hífen).
ask_slug() {
  local prompt="$1" default="${2:-}" kind="${3:-label}" raw slug
  while true; do
    raw="$(ask_required "$prompt" "$default")"
    slug="$(normalize_slug "$raw")"
    if [[ "$kind" != "host" ]]; then
      slug="$(printf '%s' "$slug" | tr '-' '_' | sed -E 's/_+/_/g; s/^_+|_+$//g')"
    fi
    if [[ -n "$slug" && "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
      [[ "$slug" != "$raw" ]] && info "Será registrado como: ${slug}" >&2
      printf '%s' "$slug"
      return 0
    fi
    warn "Valor inválido: ${raw}. Use letras e números (acentos, espaços e símbolos são convertidos)." >&2
  done
}

# nome_existe "nome" "${LISTA[@]}": verdadeiro se algum item "nome|..." já usa o nome.
nome_existe() {
  local nome="$1" item
  shift
  for item in "$@"; do
    [[ "${item%%|*}" == "$nome" ]] && return 0
  done
  return 1
}

# ask_pattern "Pergunta" "padrão" 'regex' "dica"
ask_pattern() {
  local prompt="$1" default="${2:-}" regex="$3" dica="$4" value
  while true; do
    value="$(ask_required "$prompt" "$default")"
    [[ "$value" =~ $regex ]] && { printf '%s' "$value"; return 0; }
    warn "Valor inválido: ${value}. Use ${dica}."
  done
}

ask_secret() {
  local prompt="$1" value
  while true; do
    read -r -s -p "$(pergunta "$prompt")" value || entrada_encerrada
    # A quebra de linha vai para stderr: no stdout ela entraria na senha
    # capturada por $(...) e o envio ao NOC daria 401.
    echo >&2
    if [[ "$value" =~ [[:cntrl:]] ]]; then
      warn "A credencial não pode ter caracteres de controle. Digite de novo."
      continue
    fi
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "Campo obrigatório."
  done
}

ask_yes_no() {
  local prompt="$1" default="${2:-s}" answer suffix
  [[ "$default" == "s" ]] && suffix="[S/n]" || suffix="[s/N]"
  while true; do
    read -r -p "$(pergunta "$prompt" "" "${suffix//[\[\]]/}")" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      s|sim|y|yes) return 0 ;;
      n|nao|não|no) return 1 ;;
      *) warn "Responda s ou n." ;;
    esac
  done
}

CHOOSE_RESULT=""

choose() {
  local prompt="$1"; shift
  local options=("$@") choice i

  echo -e "${CYAN}?${NC} ${BOLD}${prompt}${NC}"
  for i in "${!options[@]}"; do
    printf '  %b%d%b  %s\n' "$CYAN" "$((i+1))" "$NC" "${options[$i]}"
  done

  while true; do
    read -r -p "$(echo -e "${CYAN}›${NC} ")" choice || entrada_encerrada
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      CHOOSE_RESULT="$choice"
      return 0
    fi
    warn "Opção inválida."
  done
}


# choose_padrao "Pergunta" N opções...: igual a choose, mas ENTER escolhe a opção N.
choose_padrao() {
  local prompt="$1" padrao="$2"; shift 2
  local options=("$@") choice i marca

  echo -e "${CYAN}?${NC} ${BOLD}${prompt}${NC} ${DIM}[ENTER = ${padrao}]${NC}"
  for i in "${!options[@]}"; do
    marca=" "
    (( i + 1 == padrao )) && marca="›"
    printf '  %b%s%d%b  %s\n' "$CYAN" "$marca" "$((i+1))" "$NC" "${options[$i]}"
  done

  while true; do
    read -r -p "$(echo -e "${CYAN}›${NC} ")" choice || entrada_encerrada
    choice="$(trim "$choice")"
    [[ -z "$choice" ]] && choice="$padrao"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      CHOOSE_RESULT="$choice"
      return 0
    fi
    warn "Opção inválida."
  done
}

# indice_de "valor" opções...: posição (a partir de 1) do valor na lista; 1 se não achar.
indice_de() {
  local valor="$1" i=1 item
  shift
  for item in "$@"; do
    [[ "$item" == "$valor" ]] && { echo "$i"; return 0; }
    i=$((i+1))
  done
  echo 1
}

# ------------------------------------------------------------------------------
# DESTINO DO MONITORAMENTO E FORMATAÇÃO DO RESUMO
# ------------------------------------------------------------------------------

configure_noc_destination() {
  local action input

  # O NOC da Nextec é o destino padrão e não exige confirmação. Na alteração
  # de uma instalação existente, o destino atual é mantido como padrão.
  NOC_HOST="${NOC_HOST:-$DEFAULT_NOC_HOST}"
  RW_URL="https://${NOC_HOST}/api/v1/write"
  LOKI_URL="https://${NOC_HOST}/loki/api/v1/push"

  # O banner já mostra o destino: aqui só a confirmação.
  read -r -p "$(pergunta "Destino do monitoramento" "${NOC_HOST}" "ENTER mantém, D altera")" action

  # Qualquer coisa diferente de D mantém o destino padrão.
  [[ "${action,,}" != "d" ]] && return 0

  while true; do
    read -r -p "$(pergunta "Novo destino")" input || entrada_encerrada

    input="${input#http://}"
    input="${input#https://}"
    input="${input%%/*}"
    input="$(trim "$input")"

    if [[ "$input" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
      NOC_HOST="${input,,}"
      RW_URL="https://${NOC_HOST}/api/v1/write"
      LOKI_URL="https://${NOC_HOST}/loki/api/v1/push"
      ok "Destino alterado para ${NOC_HOST}."
      return 0
    fi

    warn "Destino inválido. Informe um hostname/FQDN, ex.: noc.cliente.com.br."
  done
}

summary_row() {
  [[ -n "$LOCALE_UTF8" ]] && local LC_ALL="$LOCALE_UTF8"
  local label="$1"
  local value="$2"
  local width=30
  local len pad

  # ${#label} considera caracteres UTF-8 no locale normal do sistema,
  # evitando o desalinhamento causado por printf com textos acentuados.
  len=${#label}
  pad=$(( width - len ))
  (( pad < 1 )) && pad=1

  local cor="$BOLD"
  case "$value" in
    sim|sim\ *) cor="$GREEN";;
    não|0) cor="$DIM";;
  esac
  printf '  %b%s%b' "$DIM" "$label" "$NC"
  printf '%*s' "$pad" ''
  printf '%b%s%b\n' "$cor" "$value" "$NC"
}

alloy_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1" | tr -d '\n'
}

# ------------------------------------------------------------------------------
# DETECÇÃO DE SISTEMA, DOCKER E BANCOS
# ------------------------------------------------------------------------------
detect_os() {
  OS_FAMILY="linux"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    PRETTY_OS="${PRETTY_NAME:-$DISTRO_ID}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE=""
    PRETTY_OS="$(uname -srm)"
  fi

  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Arquitetura não suportada automaticamente: ${machine}. Suportadas: amd64 e arm64."; exit 1 ;;
  esac

  if command -v apt-get >/dev/null 2>&1; then
    PKG_FAMILY="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_FAMILY="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_FAMILY="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_FAMILY="zypper"
  else
    PKG_FAMILY="binary"
  fi
}

detect_docker() {
  # Esta função é apenas de descoberta. Falhas do Docker NÃO podem abortar o
  # instalador. É comum existir a CLI sem o daemon iniciado, socket inacessível
  # ou instalação parcialmente concluída.
  DOCKER_DETECTED=0
  DOCKER_DAEMON_AVAILABLE=0
  DOCKER_CONTAINER_COUNT=0
  DOCKER_CONTAINER_SUMMARY=""

  if command -v docker >/dev/null 2>&1 || [[ -S /var/run/docker.sock ]]; then
    DOCKER_DETECTED=1
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      DOCKER_DAEMON_AVAILABLE=1

      # Desliga temporariamente o efeito de pipefail dentro da coleta para que
      # uma falha pontual do Docker não seja tratada como erro fatal do script.
      local docker_ids=""
      docker_ids="$(docker ps -a -q 2>/dev/null || true)"
      if [[ -n "$docker_ids" ]]; then
        DOCKER_CONTAINER_COUNT="$(printf '%s\n' "$docker_ids" | grep -c . || true)"
      else
        DOCKER_CONTAINER_COUNT=0
      fi

      DOCKER_CONTAINER_SUMMARY="$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)"
    fi
  fi

  return 0
}

detect_databases() {
  # DETECTED_DATABASES contém valores únicos: postgres, mysql, sqlserver.
  DETECTED_DATABASES=()
  local found_pg=0 found_mysql=0 found_mssql=0 psout dockerout
  psout="$(ps -eo comm,args 2>/dev/null || true)"

  grep -Eqi '(^|[ /])(postgres|postmaster)([[:space:]]|$)' <<<"$psout" && found_pg=1 || true
  grep -Eqi '(^|[ /])(mysqld|mariadbd)([[:space:]]|$)' <<<"$psout" && found_mysql=1 || true
  grep -Eqi 'sqlservr' <<<"$psout" && found_mssql=1 || true

  command -v systemctl >/dev/null 2>&1 && {
    systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -Eqi 'postgresql|postgresql@' && found_pg=1 || true
    systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -Eqi 'mysql|mariadb' && found_mysql=1 || true
    systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -Eqi 'mssql-server' && found_mssql=1 || true
  }

  if [[ "$DOCKER_DETECTED" == "1" ]] && command -v docker >/dev/null 2>&1; then
    dockerout="$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null || true)"
    grep -Eqi 'postgres|timescale' <<<"$dockerout" && found_pg=1 || true
    grep -Eqi 'mysql|mariadb|percona' <<<"$dockerout" && found_mysql=1 || true
    grep -Eqi 'mssql|sqlserver|azure-sql-edge' <<<"$dockerout" && found_mssql=1 || true
  fi

  # IMPORTANTE PARA MANUTENÇÃO:
  # Expressões aritméticas como (( found_pg == 1 )) retornam status 1 quando
  # falsas. Com `set -e`, deixar uma delas como último comando da função faria
  # uma ausência NORMAL de banco ser interpretada como erro fatal. Por isso as
  # inclusões são feitas com `if` e a função termina explicitamente com status 0.
  if (( found_pg == 1 )); then
    DETECTED_DATABASES+=("postgres")
  fi
  if (( found_mysql == 1 )); then
    DETECTED_DATABASES+=("mysql")
  fi
  if (( found_mssql == 1 )); then
    DETECTED_DATABASES+=("sqlserver")
  fi

  return 0
}

show_detection() {
  step "Detecção automática"
  info "Sistema: ${PRETTY_OS}"
  info "Arquitetura: ${ARCH}"
  info "Método de instalação: ${PKG_FAMILY}"

  if [[ "$DOCKER_DETECTED" == "1" ]]; then
    if [[ "${DOCKER_DAEMON_AVAILABLE:-0}" == "1" ]]; then
      ok "Docker detectado e daemon acessível. Containers encontrados: ${DOCKER_CONTAINER_COUNT}."
      if [[ -n "$DOCKER_CONTAINER_SUMMARY" ]]; then
        echo -e "${DIM}${DOCKER_CONTAINER_SUMMARY}${NC}" | sed 's/^/  /'
      fi
    else
      warn "Docker detectado, mas o daemon não respondeu. O instalador continuará normalmente."
      info "Para diagnosticar: systemctl status docker && docker info"
    fi
  else
    info "Docker não detectado."
  fi

  if (( ${#DETECTED_DATABASES[@]} > 0 )); then
    ok "Banco(s) de dados detectado(s): ${DETECTED_DATABASES[*]}."
  else
    info "Nenhum PostgreSQL, MySQL/MariaDB ou SQL Server detectado."
  fi
}

# ------------------------------------------------------------------------------
# CONECTIVIDADE COM O NOC
# ------------------------------------------------------------------------------
check_connectivity() {
  step "Pré-validação de conectividade"

  if getent ahosts "$NOC_HOST" >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1 && nslookup "$NOC_HOST" >/dev/null 2>&1; then
    ok "DNS resolve ${NOC_HOST}."
  else
    err "DNS não resolve ${NOC_HOST}."
    return 1
  fi

  if command -v timeout >/dev/null 2>&1 && timeout 5 bash -c "</dev/tcp/${NOC_HOST}/443" 2>/dev/null; then
    ok "TCP 443 acessível."
  elif command -v curl >/dev/null 2>&1 && curl -fsSI --max-time 8 "https://${NOC_HOST}/" >/dev/null 2>&1; then
    ok "HTTPS 443 acessível."
  else
    err "Não foi possível confirmar acesso a ${NOC_HOST}:443."
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSI --max-time 8 "https://${NOC_HOST}/" >/dev/null 2>&1; then
      ok "TLS/HTTPS respondeu com certificado válido."
    else
      warn "A raiz HTTPS não respondeu 2xx. Isso pode ser normal se o NOC exigir autenticação."
    fi
  fi
}

# ------------------------------------------------------------------------------
# INSTALAÇÃO DO ALLOY
# ------------------------------------------------------------------------------
install_prerequisites() {
  case "$PKG_FAMILY" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates curl wget gpg coreutils procps
      ;;
    dnf)
      dnf install -y ca-certificates curl wget gnupg2 coreutils procps-ng shadow-utils
      ;;
    yum)
      yum install -y ca-certificates curl wget gnupg2 coreutils procps-ng shadow-utils
      ;;
    zypper)
      zypper --non-interactive install ca-certificates curl wget gpg2 coreutils procps shadow
      ;;
    binary)
      command -v curl >/dev/null 2>&1 || { err "Fallback binário requer curl."; exit 1; }
      ;;
  esac
}

install_alloy_apt() {
  install -d -m 0755 /etc/apt/keyrings
  wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
  chmod 0644 /etc/apt/keyrings/grafana.asc
  echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
  apt-get update -y
  # Conclui instalação interrompida por uma falha anterior, se houver.
  # --force-confold mantém o /etc/default/alloy atual sem perguntar: o
  # instalador grava nele as credenciais logo depois.
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold || true
  local pacote="alloy" candidato
  if [[ -n "${ALLOY_VERSAO:-}" ]]; then
    candidato="$(apt-cache madison alloy 2>/dev/null | awk -F'|' -v v="$ALLOY_VERSAO" '{gsub(/ /,"",$2); if ($2==v || index($2, v"-")==1) {print $2; exit}}')"
    [[ -n "$candidato" ]] || { err "Versão ${ALLOY_VERSAO} do Alloy não encontrada no repositório da Grafana."; exit 1; }
    pacote="alloy=${candidato}"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades -o Dpkg::Options::=--force-confold "$pacote"
}

install_alloy_rpm() {
  # Repositório RPM oficial da Grafana, compatível com dnf/yum.
  cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
  local pacote="alloy"
  [[ -n "${ALLOY_VERSAO:-}" ]] && pacote="alloy-${ALLOY_VERSAO}"
  if ! "$PKG_FAMILY" install -y "$pacote"; then
    [[ -n "${ALLOY_VERSAO:-}" ]] && "$PKG_FAMILY" downgrade -y "$pacote"
  fi
}

install_alloy_zypper() {
  rpm --import https://rpm.grafana.com/gpg.key
  zypper --non-interactive removerepo grafana >/dev/null 2>&1 || true
  zypper --non-interactive addrepo https://rpm.grafana.com grafana
  zypper --non-interactive --gpg-auto-import-keys refresh
  if [[ -n "${ALLOY_VERSAO:-}" ]]; then
    zypper --non-interactive install --oldpackage "alloy=${ALLOY_VERSAO}"
  else
    zypper --non-interactive install alloy
  fi
}

install_alloy_binary() {
  local tmpdir asset_url archive bin
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/alloy.zip"
  asset_url="https://github.com/grafana/alloy/releases/latest/download/alloy-linux-${ARCH}.zip"
  [[ -n "${ALLOY_VERSAO:-}" ]] && asset_url="https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSAO}/alloy-linux-${ARCH}.zip"

  info "Usando binário oficial do Alloy como fallback."
  curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$archive"
  if [[ -n "${ALLOY_BINARIO_SHA256:-}" ]]; then
    # Hash vindo do manifesto assinado pela Nextec.
    echo "${ALLOY_BINARIO_SHA256}  ${archive}" | sha256sum -c --quiet - || { err "SHA-256 do binário do Alloy não confere."; exit 1; }
  elif [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    err "Atualização sem SHA-256 do binário do Alloy para ${ARCH}: recusada."
    exit 1
  fi

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" -d "$tmpdir"
  else
    # Python é apenas fallback para extrair ZIP quando unzip não existe.
    command -v python3 >/dev/null 2>&1 || { err "É necessário unzip ou python3 para o fallback binário."; exit 1; }
    python3 - "$archive" "$tmpdir" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  fi

  bin="$(find "$tmpdir" -maxdepth 2 -type f -name 'alloy*' -perm -u+x | head -n1 || true)"
  [[ -n "$bin" ]] || bin="$(find "$tmpdir" -maxdepth 2 -type f -name 'alloy*' | head -n1 || true)"
  [[ -n "$bin" ]] || { err "Binário Alloy não encontrado no pacote baixado."; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/alloy
  id alloy >/dev/null 2>&1 || useradd --system --home /var/lib/alloy --create-home --shell /usr/sbin/nologin alloy
  install -d -o alloy -g alloy -m 0750 /var/lib/alloy
  install -d -o root -g alloy -m 0750 /etc/alloy

  cat > /etc/systemd/system/alloy.service <<'EOF'
[Unit]
Description=Grafana Alloy
Documentation=https://grafana.com/docs/alloy/
Wants=network-online.target
After=network-online.target

[Service]
User=alloy
Group=alloy
EnvironmentFile=-/etc/default/alloy
ExecStart=/usr/local/bin/alloy run $CUSTOM_ARGS --storage.path=/var/lib/alloy/data /etc/alloy/config.alloy
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  rm -rf "$tmpdir"
}

# O pacote do Alloy (Debian/RPM) carrega /etc/default/alloy como script de shell
# nos próprios scripts de instalação. Uma linha fora do formato CHAVE=valor (ex.:
# senha quebrada em duas linhas por versões antigas deste instalador) vira
# comando e derruba a atualização do pacote. Aqui o arquivo é conferido sem ser
# executado e, se tiver linha inválida, é refeito; as credenciais são gravadas
# de novo mais adiante pelo próprio instalador.
env_file_valido() {
  [[ -f "$ENV_FILE" ]] || return 0
  local linha
  local re_linha='^[A-Za-z_][A-Za-z0-9_]*=("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"'`$]*)$'
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    linha="${linha%$'\r'}"
    [[ -z "${linha//[[:space:]]/}" || "$linha" =~ ^[[:space:]]*# ]] && continue
    [[ "$linha" =~ $re_linha ]] || return 1
  done < "$ENV_FILE"
  return 0
}

sanitize_env_file() {
  env_file_valido && return 0

  local copia="${ENV_FILE}.invalido-$(date +%Y%m%d-%H%M%S)"
  cp -a "$ENV_FILE" "$copia"
  chmod 0600 "$copia"
  cat > "$ENV_FILE" <<'EOF'
# Grafana Alloy. Refeito pelo instalador Nextec porque o arquivo anterior tinha
# linha inválida; credenciais e argumentos são gravados abaixo pelo instalador.
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS=""
RESTART_ON_UPGRADE=true
EOF
  chmod 0600 "$ENV_FILE"
  warn "${ENV_FILE} tinha linha inválida e foi refeito (cópia protegida em ${copia}; apague depois de concluir)."
}

# Versão instalada do Alloy, só os números (ex.: 1.20.1); vazio se não houver.
alloy_versao_instalada() {
  command -v alloy >/dev/null 2>&1 || return 0
  alloy --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

install_alloy() {
  step "Instalando Grafana Alloy"
  if [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    # Sem credenciais em mãos, refazer o arquivo apagaria a senha de envio.
    env_file_valido || { err "${ENV_FILE} tem linha inválida; rode o instalador interativo neste servidor."; exit 1; }
  else
    sanitize_env_file
  fi

  if [[ -n "${ALLOY_VERSAO:-}" ]]; then
    [[ "$ALLOY_VERSAO" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "ALLOY_VERSAO inválida: ${ALLOY_VERSAO}"; exit 1; }
    if [[ "$(alloy_versao_instalada)" == "$ALLOY_VERSAO" ]] && systemctl cat alloy.service >/dev/null 2>&1; then
      ok "Grafana Alloy já está na versão ${ALLOY_VERSAO}."
      return 0
    fi
    info "Versão do Alloy definida pela Nextec: ${ALLOY_VERSAO}."
  fi
  install_prerequisites

  case "$PKG_FAMILY" in
    apt) install_alloy_apt ;;
    dnf|yum) install_alloy_rpm ;;
    zypper) install_alloy_zypper ;;
    binary) install_alloy_binary ;;
  esac

  systemctl daemon-reload
  systemctl enable alloy.service >/dev/null 2>&1 || true
  ok "Grafana Alloy instalado: $(alloy --version 2>/dev/null | head -n1 || echo instalado)"
}

# ------------------------------------------------------------------------------
# ARQUIVO DE AMBIENTE E SEGREDOS
# ------------------------------------------------------------------------------
append_env_var() {
  local key="$1" value="$2" tmp escaped
  # Quebra de linha dentro do valor quebra o arquivo: o pacote do Alloy executa
  # a linha seguinte como comando. Remove nas pontas e recusa no meio.
  value="${value#$'\n'}"; value="${value%$'\n'}"; value="${value//$'\r'/}"
  if [[ "$value" == *$'\n'* ]]; then
    err "O valor de ${key} contém quebra de linha. Rode o instalador de novo e digite a credencial em uma linha."
    exit 1
  fi
  tmp="$(mktemp)"
  [[ -f "$ENV_FILE" ]] && grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  # Aspas duplas com \, ", $ e ` escapados: valor literal tanto para o shell
  # (scripts do pacote) quanto para o systemd (EnvironmentFile).
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//\$/\\\$}"
  escaped="${escaped//\`/\\\`}"
  printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

# ------------------------------------------------------------------------------
# COLETA COMPLEMENTAR NEXTEC
# ------------------------------------------------------------------------------
# O Alloy coleta recursos, logs e sondas. O que ele não faz sozinho fica com a
# Coleta Complementar: internet e links (status, failover, causa das quedas),
# estado e eventos do Docker e teste de velocidade. Ela grava métricas em
# ${COLETA_TEXTFILE} e eventos em ${COLETA_EVENTOS}; o Alloy lê e envia.
coleta_enabled() {
  [[ "${ENABLE_INTERNET:-0}" == "1" || "${ENABLE_LINKS:-0}" == "1" || \
     "${ENABLE_VELOCIDADE:-0}" == "1" || "${ENABLE_DOCKER:-0}" == "1" || \
     "${ENABLE_ACESSOS:-0}" == "1" ]]
}

needs_loki() {
  [[ "${ENABLE_LOGS:-0}" == "1" ]] || coleta_enabled
}

ini_value() {
  # Remove quebras de linha e colchetes, que quebrariam o arquivo INI.
  local value="${1//$'\n'/ }"
  value="${value//[/(}"
  value="${value//]/)}"
  value="${value//|//}"
  printf '%s' "$(trim "$value")"
}

# Destino de teste padrão que ainda não está em uso por outro link.
proximo_destino_link() {
  local destino item alvos usado
  for destino in 8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222; do
    usado=0
    for item in "${LINKS[@]}"; do
      IFS='|' read -r _ _ _ _ _ _ _ alvos _ <<<"$item"
      [[ ", ${alvos}, " == *", ${destino}, "* ]] && usado=1
    done
    [[ "$usado" == "0" ]] && { echo "$destino"; return 0; }
  done
  echo ""
}

# Só o essencial por link: operadora, tipo, papel e destino de teste. O nome é
# montado (operadora + tipo) e o IP público é aprendido pela Coleta (com um só
# link no ar, o IP de saída é dele). O resto fica em "opções avançadas".
dica() { echo -e "  ${DIM}$*${NC}"; }

# IP público de saída agora (o do link em uso). Vazio se não conseguir.
ip_publico_atual() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip" || [[ "$ip" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 0
}

LINK_TIPOS=(fibra radio 4g satelite dedicado)
LINK_TIPOS_ROTULO=("Fibra" "Rádio" "4G/5G" "Satélite" "Dedicado")
LINK_TIPOS_NOME=("Fibra" "Rádio" "4G" "Satélite" "Dedicado")
# Três destinos por link, de provedores diferentes (uma queda de provedor não
# derruba a medição). Com mais de um link, cada conjunto precisa de uma rota
# própria no firewall, por isso os conjuntos não se repetem.
LINK_DESTINOS_PADRAO=(
  "8.8.8.8, 1.1.1.1, 9.9.9.9"
  "8.8.4.4, 1.0.0.1, 149.112.112.112"
  "208.67.222.222, 208.67.220.220, 94.140.14.14"
  "94.140.15.15, 76.76.2.0, 76.76.10.0"
)

papel_rotulo() {
  case "$1" in primario) echo "Principal";; failover) echo "Reserva";; sdwan) echo "SD-WAN";; *) echo "$1";; esac
}

# velocidade_mbps "500m" / "1g" / "1.5giga": valor em Mbps, inteiro.
velocidade_mbps() {
  local p="$1" mult=1
  [[ "$p" =~ ^([0-9]+(\.[0-9]+)?)(g|gb|gbps|giga|gigas|m|mb|mbps|mega|megas)?$ ]] || return 1
  [[ "${BASH_REMATCH[3]}" == g* ]] && mult=1000
  awk -v n="${BASH_REMATCH[1]}" -v m="$mult" 'BEGIN { v = int(n * m + 0.5); if (v < 1 || v > 100000) exit 1; print v }'
}

# normalizar_velocidade "600 Mega/300": "600|300". Aceita "500", "500 Mega",
# "1 Giga", "1,5G", "600/300". Sem upload: "500|".
normalizar_velocidade() {
  local v="${1,,}" d u
  v="${v// /}"; v="${v//,/.}"
  [[ -n "$v" ]] || return 1
  IFS='/' read -r d u <<<"$v"
  d="$(velocidade_mbps "$d")" || return 1
  if [[ -n "$u" ]]; then
    u="$(velocidade_mbps "$u")" || return 1
  fi
  printf '%s|%s' "$d" "$u"
}

velocidade_texto() {
  [[ -n "$1" ]] || { echo "não informada"; return 0; }
  if [[ -n "$2" ]]; then echo "$1/$2 Mbps"; else echo "$1 Mbps"; fi
}

# Um link por vez: operadora, tipo e velocidade contratada; função só com
# mais de um link. O nome sai da operadora e do tipo. Destinos de teste vêm
# prontos (três por link) e só são digitados se o técnico quiser trocar. Com
# mais de um link, confirma o IP público detectado para o principal (os demais
# a Coleta aprende quando ficam sozinhos no ar). Gateway, IP de origem e
# firewall ficam em opções avançadas.
collect_one_link() {
  local numero="$1" total="$2" varios=0 item tem_principal=0
  local operadora tipo tipo_rotulo papel alvos ip_publico detectado padrao_destino
  local velocidade="" vel_down="" vel_up="" resposta
  local gateway="" origem="" firewall="" interface="" nome base n
  (( total > 1 || ${#LINKS[@]} > 0 )) && varios=1
  echo
  if (( total > 1 )); then
    echo -e "  ${CYAN}${BOLD}Link ${numero} de ${total}${NC}"
  else
    echo -e "  ${CYAN}${BOLD}Link de internet${NC}"
  fi

  operadora="$(ini_value "$(ask_required "Operadora")")"
  choose_padrao "Tipo de conexão" 1 "${LINK_TIPOS_ROTULO[@]}"
  tipo="${LINK_TIPOS[$((CHOOSE_RESULT-1))]}"
  tipo_rotulo="${LINK_TIPOS_NOME[$((CHOOSE_RESULT-1))]}"

  while true; do
    read -r -p "$(pergunta "Velocidade contratada em Mbps" "" "ex.: 500, 1000 ou 600/300; ENTER se não souber")" resposta || entrada_encerrada
    resposta="$(trim "$resposta")"
    [[ -z "$resposta" ]] && break
    if velocidade="$(normalizar_velocidade "$resposta")"; then
      IFS='|' read -r vel_down vel_up <<<"$velocidade"
      info "Registrada como $(velocidade_texto "$vel_down" "$vel_up")."
      break
    fi
    warn "Velocidade inválida: ${resposta}. Use Mbps, ex.: 500, 1000 ou 600/300 (download/upload)."
  done

  if [[ "$varios" == "0" ]]; then
    papel=primario
  else
    for item in "${LINKS[@]}"; do
      IFS='|' read -r _ n _ <<<"$item"
      [[ "$n" == "primario" ]] && tem_principal=1
    done
    choose_padrao "Função deste link" "$([[ "$tem_principal" == 1 ]] && echo 2 || echo 1)" \
      "Principal" "Reserva (entra quando o principal cai)" "SD-WAN (os dois em uso ao mesmo tempo)"
    case "$CHOOSE_RESULT" in 1) papel=primario;; 2) papel=failover;; 3) papel=sdwan;; esac
  fi

  n=${#LINKS[@]}
  padrao_destino="${LINK_DESTINOS_PADRAO[$n]:-}"
  if [[ "$varios" == "1" ]]; then
    dica "Com mais de um link, o firewall precisa mandar os destinos de teste deste"
    dica "link só por ele (uma rota por link)."
  fi
  if [[ -n "$padrao_destino" ]] && ask_yes_no "Destinos de teste: ${padrao_destino}. Usar estes?" s; then
    alvos="$padrao_destino"
  else
    alvos="$(ask_address "Destinos de teste deste link, separados por vírgula" "" host 0 1)"
  fi

  ip_publico=""
  if [[ "$varios" == "1" && "$papel" == "primario" ]]; then
    detectado="$(ip_publico_atual)"
    if [[ -n "$detectado" ]] && ask_yes_no "O IP público atual (${detectado}) é deste link?" s; then
      ip_publico="$detectado"
    fi
  fi

  if ask_yes_no "Opções avançadas (gateway da operadora, IP de origem, firewall)?" n; then
    dica "Gateway: separa queda da operadora de problema no firewall."
    gateway="$(ask_address "IP do gateway da operadora" "" host 1)"
    while true; do
      origem="$(ask_address "IP deste servidor que sai só por este link" "" ip 1)"
      [[ -z "$origem" ]] && break
      ip -o addr show 2>/dev/null | grep -qw "inet ${origem}" && break
      warn "O IP ${origem} não existe neste servidor. Informe um IP local ou deixe vazio."
    done
    read -r -p "$(pergunta "Nome do firewall no NOC, para cruzar com o tráfego SNMP" "" "opcional")" firewall || entrada_encerrada
    firewall="$(trim "$firewall")"
    [[ -n "$firewall" ]] && firewall="$(normalize_slug "$firewall")"
    while [[ -n "$firewall" ]]; do
      read -r -p "$(pergunta "Interface WAN do link no firewall" "" "ex.: igb1")" interface || entrada_encerrada
      interface="$(trim "$interface")"
      [[ "$interface" =~ $RE_INTERFACE ]] && break
      warn "Interface inválida. Use o nome como aparece no firewall, ex.: igb1, ether1, wan1."
    done
  fi

  base="$(ini_value "${operadora} ${tipo_rotulo}")"
  nome="$base"
  n=2
  while nome_existe "$nome" "${LINKS[@]}"; do
    nome="${base} ${n}"
    n=$((n+1))
  done
  # Campos: nome|papel|operadora|tipo|suporte|ip_publico|gateway|alvos|origem|
  # firewall|interface|velocidade_mbps|velocidade_upload_mbps (suporte ficou
  # vazio a partir da 2.5.2; continua no formato para ler respostas antigas).
  LINKS+=("${nome}|${papel}|$(ini_value "$operadora")|${tipo}||$(ini_value "$ip_publico")|$(ini_value "$gateway")|$(ini_value "$alvos")|$(ini_value "$origem")|$(ini_value "$firewall")|$(ini_value "$interface")|${vel_down}|${vel_up}")
  ok "Link ${nome} cadastrado ($(papel_rotulo "$papel"), $(velocidade_texto "$vel_down" "$vel_up"))."
}

collect_links_inputs() {
  step "Links de internet"
  local total=1 n
  # Primeiro cadastro: pergunta quantos links o local tem e passa por cada um.
  if (( ${#LINKS[@]} == 0 )); then
    total="$(ask_pattern "Quantos links de internet este local tem?" "1" '^[1-6]$' "um número de 1 a 6")"
  fi
  for (( n = 1; n <= total; n++ )); do
    collect_one_link "$n" "$total"
  done
  return 0
}

# Com a internet ligada: sem links cadastrados, pergunta quantos (padrão 1);
# com links, mostra e pergunta se quer alterar.
perguntar_links() {
  if [[ "${ENABLE_INTERNET:-0}" != "1" ]]; then
    LINKS=()
    ENABLE_LINKS=0
    return 0
  fi
  if (( ${#LINKS[@]} == 0 )); then
    collect_links_inputs
  elif ask_yes_no "Alterar os ${#LINKS[@]} link(s) de internet cadastrado(s)?" n; then
    editar_lista LINKS "Links de internet" collect_links_inputs ENABLE_LINKS
  fi
  ENABLE_LINKS=0
  (( ${#LINKS[@]} > 0 )) && ENABLE_LINKS=1
  return 0
}

write_coleta_config() {
  mkdir -p "$COLETA_CONFIG_DIR"
  if [[ -f "$COLETA_CONFIG" ]] && (( ${#LINKS[@]} == 0 )); then
    # Reconfiguração sem links novos: preserva os links e limites já ajustados
    # e só atualiza quais módulos estão ligados.
    cp -a "$COLETA_CONFIG" "${COLETA_CONFIG}.$(date +%Y%m%d-%H%M%S).bak"
    python3 - "$COLETA_CONFIG" "$ENABLE_INTERNET" "$ENABLE_DOCKER" "$ENABLE_VELOCIDADE" "${ENABLE_ACESSOS:-0}" <<'PY'
import configparser, sys
caminho, internet, docker, velocidade, acessos = sys.argv[1:6]
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
config.read(caminho, encoding="utf-8")
if not config.has_section("acessos"):
    config.add_section("acessos")
    config["acessos"]["horario"] = "seg-sex 07:00-19:00; sab 07:00-14:00"
    config["acessos"]["origens_conhecidas"] = ""
for secao, ligado in (("internet", internet), ("docker", docker), ("velocidade", velocidade), ("acessos", acessos)):
    if not config.has_section(secao):
        config.add_section(secao)
    config[secao]["ativo"] = "sim" if ligado == "1" else "nao"
with open(caminho, "w", encoding="utf-8") as arquivo:
    config.write(arquivo)
PY
    ok "Configuração da Coleta Complementar preservada (${COLETA_CONFIG})."
    return 0
  fi

  [[ -f "$COLETA_CONFIG" ]] && cp -a "$COLETA_CONFIG" "${COLETA_CONFIG}.$(date +%Y%m%d-%H%M%S).bak"
  {
    cat <<EOF
; Coleta Complementar Nextec
; Gerado pelo instalador ${INSTALLER_VERSION} em $(date '+%d/%m/%Y %H:%M').
; Depois de alterar: systemctl restart coleta-complementar
; Manual completo: Confluence NXTDOC, "Coleta Complementar Nextec".

[geral]
; Intervalo entre medições de internet e links, em segundos (mínimo 10).
intervalo_links_segundos = 15
; Acima destes limites o link fica "degradado".
limite_latencia_ms = 150
limite_perda_percentual = 5

[internet]
; Links configurados abaixo mantêm este módulo ligado mesmo com "nao".
ativo = $([[ "$ENABLE_INTERNET" == 1 ]] && echo sim || echo nao)
; Destinos testados pela saída padrão do servidor.
alvos = 1.1.1.1, 8.8.8.8
; Firewall/gateway da rede local. Vazio: usa o gateway padrão do servidor.
firewall =
; Servidores DNS testados ("sistema" usa o DNS configurado no servidor).
dns_servidores = sistema, 1.1.1.1, 8.8.8.8
dns_nome = google.com

[docker]
ativo = $([[ "$ENABLE_DOCKER" == 1 ]] && echo sim || echo nao)

[velocidade]
ativo = $([[ "$ENABLE_VELOCIDADE" == 1 ]] && echo sim || echo nao)
intervalo_minutos = 30

[acessos]
; Logins (SSH e console), sudo e su, com IP de origem. Alimenta os alertas
; de acesso privilegiado: root direto, origem pública nova e fora do horário.
ativo = $([[ "${ENABLE_ACESSOS:-0}" == 1 ]] && echo sim || echo nao)
; Horário comercial (Brasília). Fora dele, acesso privilegiado entra no resumo.
horario = seg-sex 07:00-19:00; sab 07:00-14:00
; Redes de origem conhecidas, além da rede interna e do IP público do local
; (ex.: VPN ou escritório da Nextec): 203.0.113.0/24, 198.51.100.7
origens_conhecidas =
EOF
    local item nome papel operadora tipo suporte ip_publico gateway alvos origem firewall interface vel_down vel_up
    for item in "${LINKS[@]}"; do
      IFS='|' read -r nome papel operadora tipo suporte ip_publico gateway alvos origem firewall interface vel_down vel_up <<<"$item"
      cat <<EOF

[link:${nome}]
papel = ${papel}
operadora = ${operadora}
tipo = ${tipo}
suporte = ${suporte}
ip_publico = ${ip_publico}
gateway = ${gateway}
alvos = ${alvos}
origem = ${origem}
firewall = ${firewall}
interface_firewall = ${interface}
velocidade_mbps = ${vel_down}
velocidade_upload_mbps = ${vel_up}
teste_velocidade = nao
EOF
    done
  } > "$COLETA_CONFIG"
  chmod 0644 "$COLETA_CONFIG"
  ok "Configuração da Coleta Complementar criada em ${COLETA_CONFIG}."
}

install_speedtest_cli() {
  [[ "$ENABLE_VELOCIDADE" == "1" ]] || return 0
  if [[ -x "$SPEEDTEST_BIN" ]]; then
    info "Speedtest CLI já instalado."
    return 0
  fi
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64";;
    aarch64|arm64) arch="aarch64";;
    *) warn "Arquitetura sem Speedtest CLI; teste de velocidade desligado."; ENABLE_VELOCIDADE=0; return 0;;
  esac
  tmp="$(mktemp -d)"
  if curl -fsSL "https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_CLI_VERSION}-linux-${arch}.tgz" -o "${tmp}/speedtest.tgz" \
     && tar -xzf "${tmp}/speedtest.tgz" -C "$tmp" speedtest; then
    install -m 0755 "${tmp}/speedtest" "$SPEEDTEST_BIN"
    ok "Speedtest CLI instalado em ${SPEEDTEST_BIN}."
  elif [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    # Na atualização uma falha passageira não pode desligar o teste de vez
    # (a resposta ficaria gravada): a próxima atualização tenta de novo.
    warn "Não foi possível baixar o Speedtest CLI agora; nova tentativa na próxima atualização."
  else
    warn "Não foi possível baixar o Speedtest CLI; teste de velocidade desligado."
    ENABLE_VELOCIDADE=0
  fi
  rm -rf "$tmp"
}

install_coleta_complementar() {
  coleta_enabled || return 0
  step "Instalando a Coleta Complementar Nextec"

  if ! command -v python3 >/dev/null 2>&1; then
    info "Instalando python3..."
    case "$PKG_FAMILY" in
      apt) apt-get install -y -q python3 >/dev/null;;
      dnf|yum) "$PKG_FAMILY" install -y -q python3 >/dev/null;;
      zypper) zypper -q -n install python3 >/dev/null;;
      *) err "python3 não encontrado e não há gerenciador de pacotes conhecido."; exit 1;;
    esac
  fi
  if ! command -v ping >/dev/null 2>&1 || ! command -v traceroute >/dev/null 2>&1; then
    case "$PKG_FAMILY" in
      apt) apt-get install -y -q iputils-ping traceroute >/dev/null || true;;
      dnf|yum) "$PKG_FAMILY" install -y -q iputils traceroute >/dev/null || true;;
      zypper) zypper -q -n install iputils traceroute >/dev/null || true;;
    esac
  fi

  install_speedtest_cli

  local tmp
  tmp="$(mktemp)"
  if [[ -n "${COLETA_ARQUIVO:-}" ]]; then
    # Entregue pelo atualizador, já conferido pela assinatura do manifesto.
    cp "$COLETA_ARQUIVO" "$tmp" || { err "Arquivo da Coleta Complementar não encontrado: ${COLETA_ARQUIVO}"; exit 1; }
  else
    curl -fsSL "$COLETA_URL" -o "$tmp" || { err "Falha ao baixar a Coleta Complementar de ${COLETA_URL}"; exit 1; }
  fi
  python3 -m py_compile "$tmp" || { err "Arquivo baixado da Coleta Complementar é inválido."; exit 1; }
  install -D -m 0755 "$tmp" "$COLETA_BIN"
  rm -f "$tmp"
  ok "Coleta Complementar $(python3 "$COLETA_BIN" versao) instalada em ${COLETA_BIN}."

  write_coleta_config
  install -d -m 0755 "$COLETA_DADOS" "$COLETA_TEXTFILE" "$(dirname "$COLETA_EVENTOS")"

  cat > "$COLETA_SERVICE" <<EOF
[Unit]
Description=Coleta Complementar Nextec (internet, links, Docker e velocidade)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${COLETA_BIN} executar
Restart=always
RestartSec=10
# Roda como root: precisa de ping com IP de origem e do socket do Docker.
# Só grava em ${COLETA_DADOS} e $(dirname "$COLETA_EVENTOS").
# O Speedtest CLI grava o aceite da licença em \$HOME/.config; com ProtectHome
# o /root fica inacessível, então o HOME do serviço fica na pasta de dados.
Environment=HOME=${COLETA_DADOS}
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now coleta-complementar >/dev/null 2>&1
  systemctl restart coleta-complementar
  python3 "$COLETA_BIN" verificar || warn "A verificação da Coleta Complementar apontou problemas (ver acima)."
}

configure_service_env() {
  step "Configurando credenciais e segurança local"

  # Na atualização as credenciais já estão em ${ENV_FILE} e ficam como estão.
  if [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    configure_service_groups
    ok "Credenciais mantidas em ${ENV_FILE}."
    return 0
  fi
  # Alteração pelo menu de manutenção: só grava o que foi alterado.
  if [[ "$EDICAO" == "1" ]]; then
    gravar_credenciais_edicao
    configure_service_groups
    ok "Credenciais em ${ENV_FILE} preservadas; só o que foi alterado foi gravado."
    return 0
  fi

  append_env_var "NEXTEC_RW_USERNAME" "$RW_USERNAME"
  append_env_var "NEXTEC_RW_PASSWORD" "$RW_PASSWORD"

  if needs_loki; then
    append_env_var "NEXTEC_LOKI_USERNAME" "$LOKI_USERNAME"
    append_env_var "NEXTEC_LOKI_PASSWORD" "$LOKI_PASSWORD"
  fi

  local idx=0 item db_type db_dsn
  for item in "${DATABASE_TARGETS[@]}"; do
    IFS='|' read -r db_type db_dsn <<<"$item"
    idx=$((idx+1))
    append_env_var "NEXTEC_DB_DSN_${idx}" "$db_dsn"
  done

  # A UI local do Alloy não deve ficar exposta na rede.
  append_env_var "CUSTOM_ARGS" "--server.http.listen-addr=127.0.0.1:12345"

  configure_service_groups
  ok "Segredos armazenados em ${ENV_FILE} com permissão 0600."
}

configure_service_groups() {
  if [[ "$ENABLE_LOGS" == "1" ]]; then
    getent group adm >/dev/null 2>&1 && usermod -aG adm alloy || true
    getent group systemd-journal >/dev/null 2>&1 && usermod -aG systemd-journal alloy || true
  fi

  if [[ "$ENABLE_DOCKER" == "1" ]]; then
    if getent group docker >/dev/null 2>&1; then
      usermod -aG docker alloy
      warn "Alloy foi adicionado ao grupo docker. Esse grupo concede privilégios elevados no host."
    else
      warn "Grupo docker não encontrado. O Alloy poderá não acessar /var/run/docker.sock."
    fi
  fi
}

# ------------------------------------------------------------------------------
# GERADORES DE LABELS E CONFIGURAÇÃO ALLOY
# ------------------------------------------------------------------------------
write_common_relabels() {
  local src="$1" name="$2" service="$3" type="$4" os="$5" origin="${6:-alloy}" job="${7:-}"

  # IMPORTANTE PARA MANUTENÇÃO:
  # No Alloy/River, mantenha um atributo por linha dentro de cada bloco rule.
  cat <<EOF

discovery.relabel "${name}" {
  targets = ${src}

  rule {
    target_label = "instance"
    replacement  = "$(alloy_escape "$HOST_LABEL")"
  }
EOF
  # O alvo do exporter já traz job (ex.: integrations/unix), que prevalece
  # sobre job_name do scrape; quando informado, o job é fixado aqui.
  [[ -n "$job" ]] && cat <<EOF
  rule {
    target_label = "job"
    replacement  = "${job}"
  }
EOF
  cat <<EOF
  rule {
    target_label = "host"
    replacement  = "$(alloy_escape "$HOST_LABEL")"
  }
  rule {
    target_label = "cliente"
    replacement  = "$(alloy_escape "$CLIENTE")"
  }
  rule {
    target_label = "servico"
    replacement  = "$(alloy_escape "$service")"
  }
  rule {
    target_label = "tipo"
    replacement  = "$(alloy_escape "$type")"
  }
  rule {
    target_label = "ambiente"
    replacement  = "$(alloy_escape "$AMBIENTE")"
  }
  rule {
    target_label = "os"
    replacement  = "$(alloy_escape "$os")"
  }
  rule {
    target_label = "origem"
    replacement  = "$(alloy_escape "$origin")"
  }
  rule {
    target_label = "criticidade"
    replacement  = "$(alloy_escape "$CRITICIDADE")"
  }
  rule {
    target_label = "local"
    replacement  = "$(alloy_escape "$LOCAL")"
  }
}
EOF
}

generate_database_config() {
  local idx=0 item db_type db_dsn
  for item in "${DATABASE_TARGETS[@]}"; do
    IFS='|' read -r db_type db_dsn <<<"$item"
    idx=$((idx+1))

    case "$db_type" in
      postgres)
        cat <<EOF

// PostgreSQL detectado e confirmado pelo operador.
// A DSN fica em NEXTEC_DB_DSN_${idx}, fora deste arquivo.
prometheus.exporter.postgres "db_${idx}" {
  data_source_names = [sys.env("NEXTEC_DB_DSN_${idx}")]
}
EOF
        write_common_relabels "prometheus.exporter.postgres.db_${idx}.targets" "db_${idx}_labels" "postgresql" "servidor" "linux" "alloy"
        cat <<EOF
prometheus.scrape "db_${idx}" {
  targets         = discovery.relabel.db_${idx}_labels.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "10s"
}
EOF
        ;;
      mysql)
        cat <<EOF

// MySQL/MariaDB detectado e confirmado pelo operador.
// A DSN fica em NEXTEC_DB_DSN_${idx}, fora deste arquivo.
prometheus.exporter.mysql "db_${idx}" {
  data_source_name = sys.env("NEXTEC_DB_DSN_${idx}")
}
EOF
        write_common_relabels "prometheus.exporter.mysql.db_${idx}.targets" "db_${idx}_labels" "mysql" "servidor" "linux" "alloy"
        cat <<EOF
prometheus.scrape "db_${idx}" {
  targets         = discovery.relabel.db_${idx}_labels.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "10s"
}
EOF
        ;;
      sqlserver)
        # SQL Server é detectado, mas não é configurado automaticamente nesta versão.
        # database_observability.sql_server possui requisitos diferentes de um exporter
        # Prometheus tradicional. Mantemos a detecção para não perder o ativo crítico.
        cat <<EOF

// SQL Server foi detectado durante a instalação.
// O monitoramento automático não foi habilitado nesta versão do instalador.
// Registrar e configurar integração SQL Server homologada pela Nextec separadamente.
EOF
        ;;
    esac
  done
}

generate_config() {
  step "Gerando configuração do Alloy"
  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

  if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.nextec-preinstall"
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.alloy.$(date +%Y%m%d-%H%M%S)"
  fi

  {
    cat <<EOF
// =============================================================================
// Nextec NOC Monitoring
// Gerado automaticamente pelo Nextec NOC Monitoring Installer
//
// MANUTENÇÃO HUMANA
// -----------------
// Este arquivo pode ser lido e alterado por um técnico, mas o recomendado é
// alterar o instalador/template e reaplicar para manter padronização.
//
// Fluxo principal:
//   exporter/coletor -> discovery.relabel -> prometheus.scrape -> remote_write
//
// Credenciais ficam em ${ENV_FILE}, nunca neste arquivo.
// =============================================================================

prometheus.remote_write "nextec" {
  external_labels = {
    cliente     = "$(alloy_escape "$CLIENTE")",
    host        = "$(alloy_escape "$HOST_LABEL")",
    ambiente    = "$(alloy_escape "$AMBIENTE")",
    os          = "linux",
    local       = "$(alloy_escape "$LOCAL")",
    criticidade = "$(alloy_escape "$CRITICIDADE")",
    origem      = "alloy",
  }

  endpoint {
    url = "${RW_URL}"
    basic_auth {
      username = sys.env("NEXTEC_RW_USERNAME")
      password = sys.env("NEXTEC_RW_PASSWORD")
    }
  }
}
EOF

    if [[ "$MONITOR_SERVER" == "1" ]]; then
      cat <<'EOF'

// -----------------------------------------------------------------------------
// MÉTRICAS BÁSICAS DO SERVIDOR, PERFIL MÍNIMO NEXTEC
// CPU, memória, filesystem, disco/I/O, rede, load, uptime e informações do SO.
// Monitoramento de serviços não faz parte do perfil mínimo.
// -----------------------------------------------------------------------------
prometheus.exporter.unix "system" {
}
EOF
      write_common_relabels 'prometheus.exporter.unix.system.targets' 'system_labels' 'system' 'servidor' 'linux' 'alloy'
      cat <<'EOF'

prometheus.scrape "system" {
  targets         = discovery.relabel.system_labels.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "10s"
}
EOF
    fi

    if needs_loki; then
      cat <<EOF

// -----------------------------------------------------------------------------
// ENVIO DE LOGS E EVENTOS PARA O LOKI DO NOC
// -----------------------------------------------------------------------------
loki.write "nextec" {
  endpoint {
    url = "${LOKI_URL}"
    basic_auth {
      username = sys.env("NEXTEC_LOKI_USERNAME")
      password = sys.env("NEXTEC_LOKI_PASSWORD")
    }
  }
}
EOF
    fi

    if [[ "$ENABLE_DOCKER" == "1" ]]; then
      cat <<EOF

// -----------------------------------------------------------------------------
// DOCKER / CONTAINERS
// Estado, consumo (CPU, memória, rede, disco), health, configuração e eventos
// vêm da Coleta Complementar, lendo a API do Docker. O cAdvisor embutido no
// Alloy não é usado: no Docker com armazenamento de imagens do containerd
// (instalações recentes do Docker) ele não enxerga nenhum container.
// Aqui fica só a coleta dos logs dos containers, com os rótulos container e
// stack (projeto do compose; avulso quando não há).
// O usuário alloy precisa conseguir acessar o socket Docker.
// -----------------------------------------------------------------------------
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers_logs" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    regex         = "^\$"
    target_label  = "stack"
    replacement   = "avulso"
  }
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    regex         = "(.+)"
    target_label  = "stack"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers_logs.output
  forward_to = [loki.write.nextec.receiver]
  labels = {
    cliente="$(alloy_escape "$CLIENTE")", host="$(alloy_escape "$HOST_LABEL")", servico="docker",
    tipo="container", ambiente="$(alloy_escape "$AMBIENTE")", os="linux", origem="alloy",
    criticidade="$(alloy_escape "$CRITICIDADE")", local="$(alloy_escape "$LOCAL")",
  }
}
EOF
    fi

    # Sempre presente: além da Coleta Complementar, o atualizador automático
    # grava aqui as métricas dele (versão, onda, resultado).
    cat <<EOF

// -----------------------------------------------------------------------------
// COLETA COMPLEMENTAR NEXTEC E ATUALIZADOR
// Métricas: arquivos .prom em ${COLETA_TEXTFILE}.
// Eventos: ${COLETA_EVENTOS}, um JSON por linha.
// honor_labels mantém rótulos próprios das métricas (ex.: tipo do link).
// -----------------------------------------------------------------------------
prometheus.exporter.unix "coleta_complementar" {
  set_collectors = ["textfile"]

  textfile {
    directory = "${COLETA_TEXTFILE}"
  }
}
EOF
      write_common_relabels 'prometheus.exporter.unix.coleta_complementar.targets' 'coleta_complementar_labels' 'coleta_complementar' 'servidor' 'linux' 'alloy' 'integrations/coleta_complementar'
      cat <<EOF

prometheus.scrape "coleta_complementar" {
  targets         = discovery.relabel.coleta_complementar_labels.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  job_name        = "integrations/coleta_complementar"
  honor_labels    = true
  scrape_interval = "15s"
  scrape_timeout  = "10s"
}
EOF

    if needs_loki; then
      cat <<EOF

loki.source.file "coleta_complementar" {
  targets = [{
    "__path__"  = "${COLETA_EVENTOS}",
    cliente     = "$(alloy_escape "$CLIENTE")",
    host        = "$(alloy_escape "$HOST_LABEL")",
    servico     = "coleta_complementar",
    ambiente    = "$(alloy_escape "$AMBIENTE")",
    os          = "linux",
    origem      = "alloy",
    criticidade = "$(alloy_escape "$CRITICIDADE")",
    local       = "$(alloy_escape "$LOCAL")",
  }]
  forward_to    = [loki.process.coleta_complementar.receiver]
  tail_from_end = true
}

loki.process "coleta_complementar" {
  forward_to = [loki.write.nextec.receiver]

  stage.json {
    expressions = {
      tipo      = "",
      categoria = "",
      link      = "",
      ts        = "",
    }
  }

  stage.labels {
    values = {
      tipo      = "",
      categoria = "",
      link      = "",
    }
  }

  stage.timestamp {
    source = "ts"
    format = "RFC3339"
  }
}
EOF
    fi

    generate_database_config

    if [[ "$ENABLE_LOGS" == "1" ]]; then
      cat <<EOF

// -----------------------------------------------------------------------------
// LOGS DO SISTEMA, OPCIONAL
// Não fazem parte do perfil mínimo de métricas do servidor.
// O loki.write "nextec" é gerado no bloco de envio, mais acima.
// -----------------------------------------------------------------------------
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "nivel"
  }
}
EOF
      local p lbl
      for p in 0 1 2 3 4; do
        case "$p" in 0) lbl="emerg";; 1) lbl="alert";; 2) lbl="crit";; 3) lbl="error";; 4) lbl="warning";; esac
        cat <<EOF

loki.source.journal "journal_${lbl}" {
  forward_to    = [loki.write.nextec.receiver]
  relabel_rules = loki.relabel.journal.rules
  matches       = "PRIORITY=${p}"
  max_age       = "6h"
  labels = {
    cliente="$(alloy_escape "$CLIENTE")", host="$(alloy_escape "$HOST_LABEL")", servico="system",
    tipo="servidor", ambiente="$(alloy_escape "$AMBIENTE")", os="linux", origem="alloy",
    criticidade="$(alloy_escape "$CRITICIDADE")", local="$(alloy_escape "$LOCAL")",
  }
}
EOF
      done
    fi

    if [[ "$ENABLE_BLACKBOX" == "1" ]]; then
      cat <<EOF

// -----------------------------------------------------------------------------
// CONECTIVIDADE E DISPONIBILIDADE (BLACKBOX)
// Executa probes ICMP, HTTP/HTTPS ou TCP a partir deste servidor.
// -----------------------------------------------------------------------------
prometheus.exporter.blackbox "network" {
  config_file = "${BLACKBOX_FILE}"
EOF
      local item bb_name bb_addr bb_module bb_type
      for item in "${BLACKBOX_TARGETS[@]}"; do
        IFS='|' read -r bb_name bb_addr bb_module bb_type <<<"$item"
        cat <<EOF
  target {
    name    = "$(alloy_escape "$bb_name")"
    address = "$(alloy_escape "$bb_addr")"
    module  = "$(alloy_escape "$bb_module")"
    labels = {
      cliente="$(alloy_escape "$CLIENTE")", host="$(alloy_escape "$bb_name")", servico="blackbox",
      tipo="$(alloy_escape "$bb_type")", ambiente="$(alloy_escape "$AMBIENTE")", os="network",
      origem="blackbox", criticidade="$(alloy_escape "$CRITICIDADE")", local="$(alloy_escape "$LOCAL")",
    }
  }
EOF
      done
      cat <<'EOF'
}

prometheus.scrape "blackbox" {
  targets         = prometheus.exporter.blackbox.network.targets
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "10s"
}
EOF
    fi

    if [[ "$ENABLE_SNMP" == "1" ]]; then
      cat <<EOF

// -----------------------------------------------------------------------------
// SNMP DE REDE, OPCIONAL
// Módulos do fabricante em snmp.yml (homologados no repositório Nextec).
// -----------------------------------------------------------------------------
EOF
      # Módulo do fabricante e credencial do cliente vivem em arquivos
      # separados e são unidos em memória pelo Alloy, como no Windows. Sem
      # snmp-auth.yml (instalação antiga, ainda não regravada), o snmp.yml
      # traz as duas seções e é lido direto.
      if [[ -f "$SNMP_AUTH_FILE" ]]; then
        cat <<EOF
local.file "snmp_modules" {
  filename = "${SNMP_FILE}"
}

local.file "snmp_auth" {
  filename  = "${SNMP_AUTH_FILE}"
  is_secret = true
}

prometheus.exporter.snmp "network" {
  config = local.file.snmp_auth.content + "\n" + local.file.snmp_modules.content
EOF
      else
        cat <<EOF
prometheus.exporter.snmp "network" {
  config_file = "${SNMP_FILE}"
EOF
      fi
      local item sn_name sn_addr sn_module sn_auth sn_type sn_os
      for item in "${SNMP_TARGETS[@]}"; do
        IFS='|' read -r sn_name sn_addr sn_module sn_auth sn_type sn_os <<<"$item"
        cat <<EOF
  target "${sn_name//[^A-Za-z0-9_]/_}" {
    address = "$(alloy_escape "$sn_addr")"
    module  = "$(alloy_escape "$sn_module")"
    auth    = "$(alloy_escape "$sn_auth")"
    labels = {
      cliente="$(alloy_escape "$CLIENTE")", host="$(alloy_escape "$sn_name")", servico="snmp",
      tipo="$(alloy_escape "$sn_type")", ambiente="$(alloy_escape "$AMBIENTE")", os="$(alloy_escape "$sn_os")",
      origem="snmp", criticidade="$(alloy_escape "$CRITICIDADE")", local="$(alloy_escape "$LOCAL")",
    }
  }
EOF
      done
      cat <<'EOF'
}

// Walk SNMP em equipamento de entrada leva de 15 a 45 segundos. Timeout curto
// é a causa conhecida de up=0 intermitente em firewall.
prometheus.scrape "snmp" {
  targets         = prometheus.exporter.snmp.network.targets
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "120s"
  scrape_timeout  = "60s"
}
EOF
    fi

    if (( ${#CUSTOM_EXPORTERS[@]} > 0 )); then
      local cidx=0 item ce_name ce_target ce_service
      for item in "${CUSTOM_EXPORTERS[@]}"; do
        IFS='|' read -r ce_name ce_target ce_service <<<"$item"
        cidx=$((cidx+1))
        cat <<EOF

// Exporter Prometheus especializado já existente.
discovery.relabel "custom_${cidx}" {
  targets = [{ "__address__" = "$(alloy_escape "$ce_target")" }]

  rule {
    target_label = "instance"
    replacement  = "$(alloy_escape "$HOST_LABEL")"
  }
  rule {
    target_label = "host"
    replacement  = "$(alloy_escape "$HOST_LABEL")"
  }
  rule {
    target_label = "cliente"
    replacement  = "$(alloy_escape "$CLIENTE")"
  }
  rule {
    target_label = "servico"
    replacement  = "$(alloy_escape "$ce_service")"
  }
  rule {
    target_label = "tipo"
    replacement  = "servidor"
  }
  rule {
    target_label = "ambiente"
    replacement  = "$(alloy_escape "$AMBIENTE")"
  }
  rule {
    target_label = "os"
    replacement  = "linux"
  }
  rule {
    target_label = "origem"
    replacement  = "exporter_especializado"
  }
  rule {
    target_label = "criticidade"
    replacement  = "$(alloy_escape "$CRITICIDADE")"
  }
  rule {
    target_label = "local"
    replacement  = "$(alloy_escape "$LOCAL")"
  }
}

prometheus.scrape "custom_${cidx}" {
  targets         = discovery.relabel.custom_${cidx}.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
}
EOF
      done
    fi
  } > "$CONFIG_FILE"

  chmod 0640 "$CONFIG_FILE"
  chown root:alloy "$CONFIG_FILE" 2>/dev/null || true
  ok "Configuração criada em ${CONFIG_FILE}."
}

# ------------------------------------------------------------------------------
# CONECTIVIDADE E DISPONIBILIDADE (BLACKBOX)
# ------------------------------------------------------------------------------
write_blackbox_config() {
  [[ "$ENABLE_BLACKBOX" == "1" ]] || return 0

  cat > "$BLACKBOX_FILE" <<'EOF'
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

  # HTTP com verificação de conteúdo: além do 2xx, falha se o corpo trouxer
  # uma assinatura de erro conhecida (WordPress quebrado, banco fora, 5xx).
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
EOF
  chmod 0640 "$BLACKBOX_FILE"
  chown root:alloy "$BLACKBOX_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# SNMP: CATÁLOGO POR FABRICANTE E CREDENCIAL SEPARADA
# ------------------------------------------------------------------------------
# O módulo de cada fabricante (o que coletar) vem do repositório Nextec e é
# público. A credencial (community ou usuário SNMPv3) é do cliente e fica só
# neste servidor, em snmp-auth.yml. O Alloy junta os dois em memória. É o mesmo
# desenho do instalador Windows.
SNMP_FABRICANTES=(fortigate sonicwall pfsense mikrotik)
SNMP_FABRICANTES_ROTULOS=("FortiGate" "SonicWall" "pfSense" "MikroTik")
SNMP_AUTH_BLOCKS=()
SNMP_FONTES=()
SNMP_TMPDIR=""

snmp_tmpdir() {
  if [[ -z "$SNMP_TMPDIR" || ! -d "$SNMP_TMPDIR" ]]; then
    SNMP_TMPDIR="$(mktemp -d)"
  fi
  echo "$SNMP_TMPDIR"
}

# Nomes dos módulos (chaves de "modules:") de um snmp.yml.
snmp_modulos_do_arquivo() {
  awk '
    /^modules[ \t]*:/ { dentro = 1; next }
    dentro && /^[^ \t#]/ { dentro = 0 }
    dentro && /^  [A-Za-z0-9_.-]+[ \t]*:[ \t]*$/ { n = $1; sub(/:.*/, "", n); print n }
  ' "$1"
}

# Junta a seção "modules" de vários arquivos num só. O último arquivo vence
# quando o mesmo módulo aparece de novo: baixar o fabricante outra vez traz
# a versão homologada mais nova.
snmp_juntar_modulos() {
  awk '
    FNR == 1 { dentro = 0; atual = "" }
    /^modules[ \t]*:/ { dentro = 1; atual = ""; next }
    dentro && /^[^ \t#]/ { dentro = 0; atual = "" }
    dentro {
      if ($0 ~ /^  [A-Za-z0-9_.-]+[ \t]*:[ \t]*$/) {
        atual = $1; sub(/:.*/, "", atual)
        if (!(atual in visto)) { visto[atual] = 1; ordem[++n] = atual }
        corpo[atual] = ""
      }
      if (atual != "") corpo[atual] = corpo[atual] $0 "\n"
    }
    END {
      print "# Gerado pelo instalador Nextec. Junta os módulos SNMP dos fabricantes"
      print "# usados por este servidor. As credenciais ficam em snmp-auth.yml."
      print "modules:"
      for (i = 1; i <= n; i++) printf "%s", corpo[ordem[i]]
    }
  ' "$@"
}

snmp_nome_auth() {
  local linha="${1%%$'\n'*}"
  linha="${linha#"${linha%%[![:space:]]*}"}"
  printf '%s' "${linha%%:*}"
}

# Guarda um bloco de credencial. Mesmo nome substitui o anterior, a não ser
# que o segundo argumento seja "manter" (credencial já informada vence a lida
# do disco).
snmp_guardar_auth() {
  local novo="$1" modo="${2:-substituir}" nome i
  nome="$(snmp_nome_auth "$novo")"
  [[ -n "$nome" ]] || return 0
  for i in "${!SNMP_AUTH_BLOCKS[@]}"; do
    if [[ "$(snmp_nome_auth "${SNMP_AUTH_BLOCKS[$i]}")" == "$nome" ]]; then
      [[ "$modo" == "manter" ]] || SNMP_AUTH_BLOCKS[$i]="$novo"
      return 0
    fi
  done
  SNMP_AUTH_BLOCKS+=("$novo")
}

# Lê a seção "auths" de um arquivo (snmp-auth.yml ou o snmp.yml antigo, que
# trazia módulo e credencial juntos).
snmp_ler_auths() {
  local arquivo="$1" modo="${2:-manter}" linha dentro=0 bloco=""
  [[ -f "$arquivo" ]] || return 0
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    linha="${linha%$'\r'}"
    if (( dentro == 0 )); then
      [[ "$linha" =~ ^auths[[:space:]]*: ]] && dentro=1
      continue
    fi
    [[ "$linha" =~ ^[^[:space:]#] ]] && break
    if [[ "$linha" =~ ^\ \ [A-Za-z0-9_.-]+[[:space:]]*:[[:space:]]*$ ]]; then
      [[ -n "$bloco" ]] && snmp_guardar_auth "$bloco" "$modo"
      bloco="$linha"
      continue
    fi
    if [[ -n "$bloco" && -n "${linha//[[:space:]]/}" && ! "$linha" =~ ^[[:space:]]*# ]]; then
      bloco+=$'\n'"$linha"
    fi
  done < "$arquivo"
  [[ -n "$bloco" ]] && snmp_guardar_auth "$bloco" "$modo"
  return 0
}

# Valor entre aspas simples no YAML: só a própria aspa precisa ser dobrada.
# Senha SNMP costuma ter $, ! e #, que quebram aspas duplas.
yaml_aspas() {
  local v="$1"
  printf "'%s'" "${v//\'/\'\'}"
}

# Segredo com valor padrão (ENTER aceita), sem eco no terminal.
ask_secret_padrao() {
  local prompt="$1" padrao="$2" value
  read -r -s -p "$(pergunta "$prompt" "" "ENTER usa o padrão")" value || entrada_encerrada
  echo >&2
  printf '%s' "${value:-$padrao}"
}

# Monta a credencial do equipamento. Define SNMP_AUTH_NOME e SNMP_VERSAO.
snmp_ler_credencial() {
  local equipamento="$1" bloco usuario nivel protocolo senha cripto senha_cripto community
  choose_padrao "Versão SNMP" 1 "v2c (community)" "v3 (usuário e senha)"
  if [[ "$CHOOSE_RESULT" == "1" ]]; then
    SNMP_VERSAO="v2c"
    SNMP_AUTH_NOME="${equipamento}_v2c"
    community="$(ask_secret_padrao "Community SNMP" "public")"
    bloco="  ${SNMP_AUTH_NOME}:"$'\n'"    version: 2"$'\n'"    community: $(yaml_aspas "$community")"
  else
    SNMP_VERSAO="v3"
    SNMP_AUTH_NOME="${equipamento}_v3"
    usuario="$(ask_required "Usuário SNMPv3" "nextec_monitoramento")"
    choose_padrao "Nível de segurança" 1 "authPriv (autenticação e criptografia)" "authNoPriv (só autenticação)"
    nivel="$CHOOSE_RESULT"
    choose_padrao "Protocolo de autenticação" 1 "SHA" "SHA256" "SHA512" "MD5"
    case "$CHOOSE_RESULT" in 1) protocolo=SHA;; 2) protocolo=SHA256;; 3) protocolo=SHA512;; 4) protocolo=MD5;; esac
    senha="$(ask_secret "Senha de autenticação")"
    bloco="  ${SNMP_AUTH_NOME}:"$'\n'"    version: 3"$'\n'"    username: $(yaml_aspas "$usuario")"
    bloco+=$'\n'"    auth_protocol: ${protocolo}"$'\n'"    password: $(yaml_aspas "$senha")"
    if [[ "$nivel" == "1" ]]; then
      choose_padrao "Protocolo de criptografia" 1 "AES" "AES256" "DES"
      case "$CHOOSE_RESULT" in 1) cripto=AES;; 2) cripto=AES256;; 3) cripto=DES;; esac
      senha_cripto="$(ask_secret "Senha de criptografia")"
      bloco+=$'\n'"    security_level: authPriv"$'\n'"    priv_protocol: ${cripto}"$'\n'"    priv_password: $(yaml_aspas "$senha_cripto")"
    else
      bloco+=$'\n'"    security_level: authNoPriv"
    fi
  fi
  snmp_guardar_auth "$bloco"
}

# Baixa o snmp.yml homologado do fabricante. Sem acesso ao GitHub, aceita um
# caminho local. Define SNMP_FONTE (vazio se o operador desistir).
snmp_obter_fabricante() {
  local fab="$1" destino caminho
  SNMP_FONTE=""
  destino="$(snmp_tmpdir)/${fab}.yml"
  [[ -s "$destino" ]] && { SNMP_FONTE="$destino"; return 0; }
  info "Baixando o módulo ${fab} do repositório Nextec..."
  if curl -fsSL --max-time 120 "${SNMP_REPO_URL}/${fab}.yml" -o "$destino" && [[ -n "$(snmp_modulos_do_arquivo "$destino")" ]]; then
    ok "Módulo ${fab} baixado."
    SNMP_FONTE="$destino"
    return 0
  fi
  rm -f "$destino"
  warn "Não foi possível baixar ${SNMP_REPO_URL}/${fab}.yml."
  while true; do
    read -r -p "$(pergunta "Caminho local do ${fab}.yml" "" "ENTER desiste")" caminho || entrada_encerrada
    caminho="$(trim "$caminho")"
    [[ -z "$caminho" ]] && return 0
    if [[ -f "$caminho" && -n "$(snmp_modulos_do_arquivo "$caminho")" ]]; then
      cp "$caminho" "$destino"
      SNMP_FONTE="$destino"
      return 0
    fi
    warn "Arquivo não encontrado ou sem seção 'modules': ${caminho}"
  done
}

collect_snmp_targets() {
  local choice
  step "Equipamentos SNMP"
  info "O módulo do fabricante vem do repositório Nextec. A credencial fica só neste servidor (${SNMP_AUTH_FILE})."

  # Credenciais dos equipamentos já cadastrados continuam valendo.
  snmp_ler_auths "$SNMP_AUTH_FILE" manter
  snmp_ler_auths "$SNMP_FILE" manter

  while true; do
    local sn sa fab sm st sos rotulo_fab caminho
    local -a modulos=()
    while true; do
      sn="$(ask_slug "Nome do equipamento" "" host)"
      # O nome vira rótulo de bloco no config.alloy, que só aceita letra,
      # número e sublinhado ("fw-matriz" quebra o validate).
      sn="${sn//[-.]/_}"
      nome_existe "$sn" "${SNMP_TARGETS[@]}" || break
      warn "Já existe um equipamento chamado '${sn}'. Use outro nome."
    done
    sa="$(ask_address "IP/FQDN SNMP" "" host)"

    dica "Fabricante fora da lista? Solicite ao NOC a inclusão do fabricante; \"Outro\" só com snmp.yml já homologado."
    choose_padrao "Fabricante" 1 "${SNMP_FABRICANTES_ROTULOS[@]}" "Outro (snmp.yml próprio)"
    choice="$CHOOSE_RESULT"
    if (( choice <= ${#SNMP_FABRICANTES[@]} )); then
      fab="${SNMP_FABRICANTES[$((choice-1))]}"
      rotulo_fab="${SNMP_FABRICANTES_ROTULOS[$((choice-1))]}"
      snmp_obter_fabricante "$fab"
      if [[ -z "$SNMP_FONTE" ]]; then
        warn "Equipamento não cadastrado."
        ask_yes_no "Cadastrar outro equipamento SNMP?" n || break
        continue
      fi
    else
      fab=""
      rotulo_fab="Outro"
      while true; do
        caminho="$(ask_required "Caminho do snmp.yml (precisa ter a seção 'modules')")"
        [[ -f "$caminho" && -n "$(snmp_modulos_do_arquivo "$caminho")" ]] && break
        warn "Arquivo não encontrado ou sem seção 'modules': ${caminho}"
      done
      SNMP_FONTE="$(snmp_tmpdir)/proprio-${sn}.yml"
      cp "$caminho" "$SNMP_FONTE"
    fi

    snmp_ler_credencial "$sn"

    mapfile -t modulos < <(snmp_modulos_do_arquivo "$SNMP_FONTE")
    if [[ -n "$fab" ]]; then
      sm="${fab}_${SNMP_VERSAO}"
      if ! printf '%s\n' "${modulos[@]}" | grep -qx "$sm"; then
        err "O arquivo do ${rotulo_fab} não tem o módulo ${sm}."
        exit 1
      fi
    elif (( ${#modulos[@]} == 1 )); then
      sm="${modulos[0]}"
    else
      choose_padrao "Módulo SNMP" 1 "${modulos[@]}"
      sm="${modulos[$((CHOOSE_RESULT-1))]}"
    fi
    info "Módulo aplicado: ${sm}"

    choose_padrao "Tipo do equipamento" 1 "firewall" "switch" "storage" "ap" "ups"
    choice="$CHOOSE_RESULT"
    case "$choice" in 1) st=firewall;; 2) st=switch;; 3) st=storage;; 4) st=ap;; 5) st=ups;; esac

    if [[ -n "$fab" ]]; then
      sos="$fab"
    else
      sos="$(ask_slug "Sistema/fabricante" "network" label)"
    fi

    printf '%s\n' "${SNMP_FONTES[@]}" | grep -qxF "$SNMP_FONTE" || SNMP_FONTES+=("$SNMP_FONTE")
    SNMP_TARGETS+=("${sn}|${sa}|${sm}|${SNMP_AUTH_NOME}|${st}|${sos}")
    ok "Equipamento adicionado: ${sn} (${rotulo_fab}, ${sm})"
    ask_yes_no "Adicionar outro equipamento SNMP?" n || break
  done
  return 0
}

# Grava snmp.yml (módulos) e snmp-auth.yml (credenciais). Credenciais de um
# snmp.yml antigo, que trazia as duas coisas juntas, passam para o arquivo
# separado. Só ficam as credenciais usadas por algum equipamento.
prepare_snmp_config() {
  [[ "$ENABLE_SNMP" == "1" ]] || return 0
  if [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    [[ -f "$SNMP_FILE" ]] || { err "SNMP ligado, mas ${SNMP_FILE} não existe."; exit 1; }
    ok "snmp.yml mantido em ${SNMP_FILE}."
    return 0
  fi

  step "Preparando configuração SNMP"
  snmp_ler_auths "$SNMP_AUTH_FILE" manter
  snmp_ler_auths "$SNMP_FILE" manter

  local tmp item sn _a sm sau _t _o bloco achou faltando=0
  local -a usadas=() modulos=()

  if (( ${#SNMP_FONTES[@]} > 0 )); then
    tmp="$(mktemp)"
    if [[ -f "$SNMP_FILE" ]]; then
      snmp_juntar_modulos "$SNMP_FILE" "${SNMP_FONTES[@]}" > "$tmp"
    else
      snmp_juntar_modulos "${SNMP_FONTES[@]}" > "$tmp"
    fi
    install -m 0640 -o root -g alloy "$tmp" "$SNMP_FILE"
    rm -f "$tmp"
    ok "Módulos SNMP gravados em ${SNMP_FILE}: $(snmp_modulos_do_arquivo "$SNMP_FILE" | paste -sd, -)"
  elif [[ -f "$SNMP_FILE" ]]; then
    # snmp.yml antigo com credencial junto: regrava só com os módulos.
    if grep -qE '^auths[[:space:]]*:' "$SNMP_FILE"; then
      tmp="$(mktemp)"
      snmp_juntar_modulos "$SNMP_FILE" > "$tmp"
      install -m 0640 -o root -g alloy "$tmp" "$SNMP_FILE"
      rm -f "$tmp"
      ok "Credenciais do snmp.yml movidas para ${SNMP_AUTH_FILE}."
    else
      ok "snmp.yml mantido em ${SNMP_FILE}."
    fi
  else
    err "SNMP ligado, mas não há snmp.yml. Cadastre os equipamentos de novo pelo menu."
    exit 1
  fi

  mapfile -t modulos < <(snmp_modulos_do_arquivo "$SNMP_FILE")
  for item in "${SNMP_TARGETS[@]}"; do
    IFS='|' read -r sn _a sm sau _t _o <<<"$item"
    if ! printf '%s\n' "${modulos[@]}" | grep -qxF "$sm"; then
      err "O equipamento ${sn} usa o módulo ${sm}, que não está em ${SNMP_FILE}."
      faltando=1
    fi
    achou=0
    for bloco in "${usadas[@]}"; do
      [[ "$(snmp_nome_auth "$bloco")" == "$sau" ]] && { achou=1; break; }
    done
    if [[ "$achou" == "0" ]]; then
      for bloco in "${SNMP_AUTH_BLOCKS[@]}"; do
        if [[ "$(snmp_nome_auth "$bloco")" == "$sau" ]]; then
          achou=1
          usadas+=("$bloco")
          break
        fi
      done
    fi
    if [[ "$achou" == "0" ]]; then
      err "O equipamento ${sn} usa a credencial ${sau}, que não foi encontrada. Cadastre o equipamento de novo."
      faltando=1
    fi
  done
  # Módulo ou credencial inexistente passa pelo validate e o Alloy sobe
  # "saudável", mas o equipamento nunca envia dado. Melhor parar aqui.
  (( faltando == 0 )) || exit 1

  tmp="$(mktemp)"
  {
    echo "# Gerado pelo instalador Nextec. Credenciais SNMP deste cliente: não copie para o repositório."
    echo "auths:"
    for bloco in "${usadas[@]}"; do printf '%s\n' "$bloco"; done
  } > "$tmp"
  install -m 0640 -o root -g alloy "$tmp" "$SNMP_AUTH_FILE"
  rm -f "$tmp"
  ok "Credenciais SNMP gravadas em ${SNMP_AUTH_FILE} (${#usadas[@]})."
  [[ -n "$SNMP_TMPDIR" ]] && rm -rf "$SNMP_TMPDIR"
  SNMP_TMPDIR=""
  return 0
}

validate_and_start() {
  step "Validando e iniciando Alloy"

  local formatted
  formatted="$(mktemp)"
  alloy fmt "$CONFIG_FILE" > "$formatted"
  cat "$formatted" > "$CONFIG_FILE"
  rm -f "$formatted"

  alloy validate "$CONFIG_FILE"
  ok "Sintaxe do Alloy válida."

  systemctl daemon-reload
  systemctl restart alloy
  sleep 4

  if systemctl is-active --quiet alloy; then
    ok "Serviço Alloy está ativo."
  else
    journalctl -u alloy -n 80 --no-pager || true
    err "Alloy não iniciou corretamente."
    exit 1
  fi

  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; then
    ok "Readiness local respondeu."
  else
    warn "Não foi possível confirmar o endpoint local de readiness."
  fi
}

# ------------------------------------------------------------------------------
# COLETA INTERATIVA
# ------------------------------------------------------------------------------
collect_database_inputs() {
  DATABASE_TARGETS=()
  local db choice dsn

  if (( ${#DETECTED_DATABASES[@]} == 0 )); then
    return 0
  fi

  step "Bancos de dados detectados"
  info "Bancos são ativos críticos. O instalador oferece monitoramento por padrão, mas não cria usuários dentro do banco."
  info "Use uma credencial própria de monitoramento, com o menor privilégio necessário."

  for db in "${DETECTED_DATABASES[@]}"; do
    case "$db" in
      postgres)
        if ask_yes_no "PostgreSQL detectado. Configurar métricas do banco?" s; then
          echo -e "${DIM}Exemplo de DSN: postgresql://monitoramento:SENHA@127.0.0.1:5432/postgres?sslmode=disable${NC}"
          dsn="$(ask_secret "DSN PostgreSQL de monitoramento")"
          DATABASE_TARGETS+=("postgres|${dsn}")
        fi
        ;;
      mysql)
        if ask_yes_no "MySQL/MariaDB detectado. Configurar métricas do banco?" s; then
          echo -e "${DIM}Exemplo de DSN: monitoramento:SENHA@(127.0.0.1:3306)/${NC}"
          dsn="$(ask_secret "DSN MySQL/MariaDB de monitoramento")"
          DATABASE_TARGETS+=("mysql|${dsn}")
        fi
        ;;
      sqlserver)
        warn "SQL Server detectado. A versão 2.0 registra a detecção, mas não configura automaticamente a integração."
        info "Motivo: a integração SQL Server do Alloy usa um fluxo diferente e será homologada separadamente para evitar configuração insegura."
        DATABASE_TARGETS+=("sqlserver|")
        ;;
    esac
  done
}



# ------------------------------------------------------------------------------
# CHECKLIST DE RECURSOS ADICIONAIS
# ------------------------------------------------------------------------------
# Interface feita somente em Bash, sem dependências externas de interface.
#
# Uso:
#   - Digite um número para marcar/desmarcar.
#   - Pode informar vários números separados por espaço, ex.: 2 4 5
#   - Pressione ENTER sem digitar nada para continuar.
#
# Padrões:
#   - Docker: pré-marcado quando detectado e com daemon acessível.
#   - Banco: pré-marcado quando PostgreSQL/MySQL/MariaDB/SQL Server é detectado.
#   - Logs: desmarcado.
#   - SNMP: desmarcado.
#   - Conectividade e disponibilidade (Blackbox): desmarcado.
#   - Exporters adicionais: desmarcado e sempre aparece por último.
resource_checklist() {
  local db_available=0
  (( ${#DETECTED_DATABASES[@]} > 0 )) && db_available=1

  # Estado inicial recomendado.
  local -a selected=(0 0 0 0 0 0 1 1 1)
  local -a disabled=(0 0 0 0 0 0 0 0 0)
  local -a labels=(
    "Docker / containers"
    "Logs do sistema, warning/error/critical"
    "Banco de dados"
    "SNMP, firewalls/switches/UPS/APs"
    "Conectividade e disponibilidade (Blackbox), ping/TCP/DNS/HTTP"
    "Exporters adicionais"
    "Internet e links (status, DNS, IP público, cadastro dos links)"
    "Teste de velocidade (Speedtest, a cada 30 min)"
    "Acessos ao servidor (logins com origem, alerta de acesso privilegiado)"
  )
  local -a details=("" "" "" "" "" "" "recomendado" "recomendado" "recomendado")

  # "Exporters adicionais" é uma categoria em árvore, igual ao Windows: abre
  # e mostra o catálogo como itens filhos. O item pai não é marcado direto;
  # ele fica marcado quando algum filho está.
  local pai_exporters=5 expandido=0
  local -a filho_sel=()
  local j
  for j in "${!EXPORTER_CATALOGO_CHAVES[@]}"; do filho_sel[$j]=0; done

  # Na alteração de uma instalação existente, o checklist abre com o que já está ligado.
  local do_estado="${CHECKLIST_DO_ESTADO:-0}"
  if [[ "$do_estado" == "1" ]]; then
    selected=("${ENABLE_DOCKER:-0}" "${ENABLE_LOGS:-0}" "${ENABLE_DATABASES:-0}" "${ENABLE_SNMP:-0}"
              "${ENABLE_BLACKBOX:-0}" "${ENABLE_EXPORTERS:-0}" "${ENABLE_INTERNET:-0}"
              "${ENABLE_VELOCIDADE:-0}" "${ENABLE_ACESSOS:-0}")
    details[6]=""; details[7]=""; details[8]=""
    local item_exp chave_exp
    for item_exp in "${CUSTOM_EXPORTERS[@]}"; do
      chave_exp="$(exporter_chave_catalogo "${item_exp%%|*}")"
      filho_sel[$(exporter_indice "$chave_exp")]=1
    done
  fi

  if [[ "$DOCKER_DETECTED" == "1" && "${DOCKER_DAEMON_AVAILABLE:-0}" == "1" ]]; then
    [[ "$do_estado" == "1" ]] || selected[0]=1
    details[0]="detectado"
  elif [[ "$DOCKER_DETECTED" == "1" ]]; then
    disabled[0]=1
    selected[0]=0
    details[0]="detectado, daemon indisponível"
  else
    disabled[0]=1
    selected[0]=0
    details[0]="não detectado"
  fi

  if [[ "$db_available" == "1" ]]; then
    [[ "$do_estado" == "1" ]] || selected[2]=1
    details[2]="${#DETECTED_DATABASES[@]} detectado(s): ${DETECTED_DATABASES[*]}"
  else
    disabled[2]=1
    selected[2]=0
    details[2]="nenhum PostgreSQL, MySQL/MariaDB ou SQL Server detectado"
  fi

  # Marca do pai: segue os filhos.
  _sincronizar_pai() {
    local k
    selected[$pai_exporters]=0
    for k in "${!filho_sel[@]}"; do
      [[ "${filho_sel[$k]}" == "1" ]] && selected[$pai_exporters]=1
    done
    return 0
  }
  _sincronizar_pai
  [[ "${selected[$pai_exporters]}" == "1" ]] && expandido=1

  # Linhas visíveis: "t<i>" para item principal, "f<j>" para filho do catálogo.
  local -a linhas=()
  _montar_linhas() {
    local k
    linhas=()
    for k in "${!labels[@]}"; do
      linhas+=("t${k}")
      if (( k == pai_exporters )) && [[ "$expandido" == "1" ]]; then
        local f
        for f in "${!EXPORTER_CATALOGO_CHAVES[@]}"; do linhas+=("f${f}"); done
      fi
    done
    return 0
  }

  # Texto de uma linha: marca, seta do pai, recuo do filho e detalhe.
  _texto_linha() {
    local id="$1" k mark suffix seta
    if [[ "$id" == f* ]]; then
      k="${id#f}"
      mark=" "; [[ "${filho_sel[$k]}" == "1" ]] && mark="✓"
      printf '    [%s] %s' "$mark" "${EXPORTER_CATALOGO_ROTULOS[$k]}"
      return 0
    fi
    k="${id#t}"
    mark=" "; [[ "${selected[$k]}" == "1" ]] && mark="✓"
    suffix=""; [[ -n "${details[$k]}" ]] && suffix=" (${details[$k]})"
    seta=""
    if (( k == pai_exporters )); then
      [[ "$expandido" == "1" ]] && seta="▼ " || seta="▶ "
      [[ "$expandido" == "1" ]] || suffix=" (abra para escolher)"
    fi
    printf '[%s] %s%s%s' "$mark" "$seta" "${labels[$k]}" "$suffix"
  }

  # Marca ou desmarca a linha; no pai, abre e fecha a lista de filhos.
  _alternar_linha() {
    local id="$1" k
    if [[ "$id" == f* ]]; then
      k="${id#f}"
      [[ "${filho_sel[$k]}" == "1" ]] && filho_sel[$k]=0 || filho_sel[$k]=1
      _sincronizar_pai
      return 0
    fi
    k="${id#t}"
    if (( k == pai_exporters )); then
      [[ "$expandido" == "1" ]] && expandido=0 || expandido=1
      return 0
    fi
    if [[ "${disabled[$k]}" == "1" ]]; then
      MENSAGEM_CHECKLIST="${labels[$k]} não está disponível neste host."
      return 0
    fi
    [[ "${selected[$k]}" == "1" ]] && selected[$k]=0 || selected[$k]=1
    return 0
  }

  _linha_bloqueada() {
    local id="$1"
    [[ "$id" == t* && "${disabled[${id#t}]}" == "1" ]]
  }

  # --------------------------------------------------------------------------
  # FALLBACK SEM TTY
  # --------------------------------------------------------------------------
  # Quando stdin/stdout não são terminais reais, setas e leitura por tecla não
  # são confiáveis. Nesse cenário, usa seleção numérica tradicional.
  if [[ ! -t 0 || ! -t 1 ]]; then
    local input token n
    while true; do
      _montar_linhas
      echo
      echo -e "${BOLD}Recursos adicionais${NC}"
      echo -e "${DIM}Digite números separados por espaço para marcar/desmarcar. O número de \"Exporters adicionais\" abre a lista. ENTER confirma.${NC}"
      echo
      if [[ "${MONITOR_SERVER:-0}" == "1" ]]; then
        echo -e "  ${GREEN}[✓]${NC} Servidor: CPU, memória, discos, rede, load e uptime ${DIM}(sempre ativo, não precisa marcar)${NC}"
        echo
      fi

      for n in "${!linhas[@]}"; do
        printf '  %2d. %s\n' "$((n+1))" "$(_texto_linha "${linhas[$n]}")"
      done

      echo
      read -r -p "$(echo -e "${CYAN}›${NC} ")" input || entrada_encerrada
      [[ -z "${input//[[:space:]]/}" ]] && break

      # O script globalmente remove espaço do IFS. Aqui definimos IFS localmente
      # para que "2 6" seja interpretado como duas escolhas diferentes. Os
      # números valem para a lista mostrada; ela é remontada depois de cada
      # entrada, então abrir o pai e marcar um filho pede duas entradas.
      local -a tokens=()
      local -a vistas=("${linhas[@]}")
      IFS=' ,' read -r -a tokens <<< "$input"

      for token in "${tokens[@]}"; do
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#vistas[@]} )); then
          MENSAGEM_CHECKLIST=""
          _alternar_linha "${vistas[$((token-1))]}"
          [[ -n "$MENSAGEM_CHECKLIST" ]] && warn "$MENSAGEM_CHECKLIST"
        else
          warn "Opção inválida: ${token}. Use números de 1 a ${#vistas[@]}."
        fi
      done
    done
  else
    # ------------------------------------------------------------------------
    # TUI INTERATIVO
    # ------------------------------------------------------------------------
    # Teclas:
    #   ↑ / ↓  navega
    #   Espaço marca/desmarca (no pai, abre e fecha a lista)
    #   → / ←  abre e fecha "Exporters adicionais"
    #   Enter  confirma
    #
    # Não depende de whiptail/dialog. Usa somente sequências ANSI e read Bash.
    local cursor=0
    local key rest message="" count n attempts

    _montar_linhas
    count="${#linhas[@]}"
    # Garante que o primeiro cursor fique em item utilizável quando possível.
    while [[ "$cursor" -lt "$count" ]] && _linha_bloqueada "${linhas[$cursor]}"; do
      cursor=$((cursor+1))
    done
    [[ "$cursor" -ge "$count" ]] && cursor=0

    # Restaura o cursor mesmo se a função sair de forma antecipada.
    printf '\033[?25l'

    while true; do
      _montar_linhas
      count="${#linhas[@]}"
      (( cursor >= count )) && cursor=$((count-1))

      clear 2>/dev/null || printf '\033[2J\033[H'
      banner

      echo -e "${BOLD}Recursos adicionais${NC}"
      echo -e "${DIM}Use ↑/↓ para navegar, ESPAÇO para marcar/desmarcar e ENTER para continuar. ESPAÇO em \"Exporters adicionais\" abre a lista.${NC}"
      echo
      if [[ "${MONITOR_SERVER:-0}" == "1" ]]; then
        echo -e "  ${GREEN}[✓]${NC} Servidor: CPU, memória, discos, rede, load e uptime ${DIM}(sempre ativo, não precisa marcar)${NC}"
        echo
      fi

      local prefix texto
      for n in "${!linhas[@]}"; do
        prefix="  "
        [[ "$n" -eq "$cursor" ]] && prefix="❯ "
        texto="$(_texto_linha "${linhas[$n]}")"
        if _linha_bloqueada "${linhas[$n]}"; then
          if [[ "$n" -eq "$cursor" ]]; then
            printf '%b%s%s%b\n' "$CYAN" "$prefix" "$texto" "$NC"
          else
            printf '%b%s%s%b\n' "$DIM" "$prefix" "$texto" "$NC"
          fi
        elif [[ "$n" -eq "$cursor" ]]; then
          printf '%b%b%s%s%b\n' "$CYAN" "$BOLD" "$prefix" "$texto" "$NC"
        else
          printf '%s%s\n' "$prefix" "$texto"
        fi
      done

      echo
      [[ -n "$message" ]] && echo -e "${YELLOW}${message}${NC}"
      echo -e "${DIM}Itens detectados podem iniciar pré-marcados.${NC}"

      IFS= read -rsn1 key || true

      case "$key" in
        $'\x1b')
          # Sequência típica das setas: ESC [ A/B/C/D
          rest=""
          IFS= read -rsn2 -t 0.15 rest || true
          case "$rest" in
            "[A")
              # Sobe, pulando itens bloqueados quando houver opção disponível.
              attempts=0
              while (( attempts < count )); do
                cursor=$(( (cursor - 1 + count) % count ))
                _linha_bloqueada "${linhas[$cursor]}" || break
                attempts=$((attempts+1))
              done
              ;;
            "[B")
              # Desce, pulando itens bloqueados quando houver opção disponível.
              attempts=0
              while (( attempts < count )); do
                cursor=$(( (cursor + 1) % count ))
                _linha_bloqueada "${linhas[$cursor]}" || break
                attempts=$((attempts+1))
              done
              ;;
            "[C")
              [[ "${linhas[$cursor]}" == "t${pai_exporters}" ]] && expandido=1
              ;;
            "[D")
              # Fechar a lista com o cursor num filho leva o cursor para o pai.
              if [[ "${linhas[$cursor]}" == f* || "${linhas[$cursor]}" == "t${pai_exporters}" ]]; then
                expandido=0
                _montar_linhas
                cursor="$(indice_de "t${pai_exporters}" "${linhas[@]}")"
                cursor=$((cursor-1))
              fi
              ;;
          esac
          message=""
          ;;
        " ")
          MENSAGEM_CHECKLIST=""
          _alternar_linha "${linhas[$cursor]}"
          message="$MENSAGEM_CHECKLIST"
          ;;
        "")
          break
          ;;
        *)
          message="Use ↑/↓, ESPAÇO e ENTER."
          ;;
      esac
    done

    printf '\033[?25h'
    clear 2>/dev/null || printf '\033[2J\033[H'
    banner
  fi

  # Transfere o estado visual do checklist para as variáveis usadas pelo restante
  # do instalador.
  ENABLE_DOCKER="${selected[0]}"
  ENABLE_LOGS="${selected[1]}"
  ENABLE_DATABASES="${selected[2]}"
  ENABLE_SNMP="${selected[3]}"
  ENABLE_BLACKBOX="${selected[4]}"
  ENABLE_EXPORTERS="${selected[5]}"
  ENABLE_INTERNET="${selected[6]}"
  ENABLE_VELOCIDADE="${selected[7]}"
  ENABLE_ACESSOS="${selected[8]}"

  EXPORTERS_MARCADOS=()
  for j in "${!filho_sel[@]}"; do
    [[ "${filho_sel[$j]}" == "1" ]] && EXPORTERS_MARCADOS+=("${EXPORTER_CATALOGO_CHAVES[$j]}")
  done

  if [[ "$ENABLE_SNMP" == "1" || "$ENABLE_BLACKBOX" == "1" ]]; then
    COLLECTOR=1
  fi

  echo -e "${BOLD}Recursos selecionados:${NC}"
  local i
  for i in "${!labels[@]}"; do
    if [[ "${selected[$i]}" == "1" ]]; then
      echo "  ✓ ${labels[$i]}"
      if (( i == pai_exporters )); then
        for j in "${!filho_sel[@]}"; do
          [[ "${filho_sel[$j]}" == "1" ]] && echo "      · ${EXPORTER_CATALOGO_ROTULOS[$j]}"
        done
      fi
    fi
  done
  echo

  unset -f _sincronizar_pai _montar_linhas _texto_linha _alternar_linha _linha_bloqueada
  return 0
}

# ------------------------------------------------------------------------------
# CATÁLOGO DE EXPORTERS PROMETHEUS EXTERNOS
# ------------------------------------------------------------------------------
# PostgreSQL e MySQL/MariaDB possuem fluxo próprio no instalador e são tratados
# na etapa de detecção de bancos. Este catálogo serve para endpoints Prometheus
# adicionais que JÁ ESTEJAM ativos. É o mesmo do instalador Windows e alimenta
# tanto a árvore do checklist quanto a lista do menu de alteração.
EXPORTER_CATALOGO_CHAVES=(redis_exporter nginx_exporter apache_exporter rabbitmq_prometheus elasticsearch_exporter mongodb_exporter nvidia_dcgm_exporter outro)
EXPORTER_CATALOGO_ROTULOS=(
  "Redis"
  "Nginx"
  "Apache"
  "RabbitMQ"
  "Elasticsearch"
  "MongoDB"
  "GPU NVIDIA (DCGM)"
  "Outro serviço com métricas Prometheus"
)
EXPORTER_CATALOGO_ALVOS=(127.0.0.1:9121 127.0.0.1:9113 127.0.0.1:9117 127.0.0.1:15692 127.0.0.1:9114 127.0.0.1:9216 127.0.0.1:9400 "")
EXPORTER_CATALOGO_SERVICOS=(redis nginx apache rabbitmq elasticsearch mongodb gpu "")
EXPORTERS_MARCADOS=()

# Posição da chave no catálogo; chave desconhecida cai em "outro" (último).
exporter_indice() {
  local i
  for i in "${!EXPORTER_CATALOGO_CHAVES[@]}"; do
    [[ "${EXPORTER_CATALOGO_CHAVES[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo $(( ${#EXPORTER_CATALOGO_CHAVES[@]} - 1 ))
}

# Nome gravado no exporter -> chave do catálogo ("outro" para nome livre).
exporter_chave_catalogo() {
  local i
  for i in "${!EXPORTER_CATALOGO_CHAVES[@]}"; do
    [[ "${EXPORTER_CATALOGO_CHAVES[$i]}" == "outro" ]] && continue
    [[ "${EXPORTER_CATALOGO_CHAVES[$i]}" == "$1" ]] && { echo "$1"; return 0; }
  done
  echo outro
}

select_specialized_exporter() {
  local choice voltar
  voltar=$(( ${#EXPORTER_CATALOGO_ROTULOS[@]} + 1 ))

  echo
  echo -e "${BOLD}Exporters/integrações Prometheus que o instalador sabe cadastrar:${NC}"
  echo -e "${DIM}PostgreSQL e MySQL/MariaDB são tratados automaticamente na etapa de bancos.${NC}"
  echo

  # ENTER escolhe "Voltar": quem entrou por engano sai sem cadastrar nada.
  choose_padrao "Selecione o exporter/integração" "$voltar" \
    "${EXPORTER_CATALOGO_ROTULOS[@]}" \
    "Voltar, sem adicionar exporter"

  choice="$CHOOSE_RESULT"
  EXPORTER_NAME="__voltar__"
  (( choice == voltar )) && return 0
  # "outro" vira nome vazio: cadastrar_exporter pergunta o nome.
  EXPORTER_NAME="${EXPORTER_CATALOGO_CHAVES[$((choice-1))]}"
  [[ "$EXPORTER_NAME" == "outro" ]] && EXPORTER_NAME=""
  return 0
}

# Passo a passo para cadastrar um serviço que não está no catálogo.
guia_outro_exporter() {
  echo
  echo -e "  ${BOLD}Como adicionar um serviço que não está na lista${NC}"
  dica "1. Rode: curl -s http://host:porta/metrics | head"
  dica "   Se aparecer texto como \"nome_da_metrica 123\", o serviço publica métricas."
  dica "2. Informe um nome curto (ex.: minio) e o endereço host:porta (ex.: 127.0.0.1:9000)."
  dica "3. Nome no NOC agrupa o serviço nos painéis; ENTER usa o mesmo nome."
  dica "4. Se /metrics não responder, o serviço precisa de um exporter próprio: solicite ao NOC."
  echo
}

# Pergunta endereço e serviço de um exporter do catálogo (chave) ou de um
# endpoint livre (chave "outro") e acrescenta em CUSTOM_EXPORTERS.
cadastrar_exporter() {
  local chave="$1" idx cn ct cs
  idx="$(exporter_indice "$chave")"
  if [[ "$chave" != "outro" ]]; then
    echo
    info "${EXPORTER_CATALOGO_ROTULOS[$idx]}"
    dica "ENTER aceita o endereço de costume; troque só se o serviço usa outra porta ou outro servidor."
    cn="$chave"
    ct="$(ask_address "Endereço (host:porta)" "${EXPORTER_CATALOGO_ALVOS[$idx]}" hostport)"
    cs="$(ask_slug "Nome no NOC" "${EXPORTER_CATALOGO_SERVICOS[$idx]}" label)"
  else
    guia_outro_exporter
    while true; do
      cn="$(ask_slug "Serviço (nome curto, ex.: minio)" "" label)"
      nome_existe "$cn" "${CUSTOM_EXPORTERS[@]}" || break
      warn "Já existe um serviço chamado '${cn}'. Use outro nome."
    done
    ct="$(ask_address "Endereço (host:porta)" "" hostport)"
    cs="$(ask_slug "Nome no NOC" "$cn" label)"
  fi
  CUSTOM_EXPORTERS+=("${cn}|${ct}|${cs}")
  ok "Integração adicionada: ${cn} -> ${ct} (servico=${cs})"
}

# Lista do menu "Exporters adicionais" (Adicionar): escolhe um item por vez.
collect_custom_exporters() {
  echo
  echo -e "${BOLD}Exporters adicionais${NC}"
  echo -e "${DIM}Use somente para exporter/endpoint Prometheus que já esteja ativo.${NC}"

  while true; do
    select_specialized_exporter
    [[ "$EXPORTER_NAME" == "__voltar__" ]] && break

    if [[ -n "$EXPORTER_NAME" ]] && nome_existe "$EXPORTER_NAME" "${CUSTOM_EXPORTERS[@]}"; then
      warn "${EXPORTER_NAME} já está cadastrado. Para trocar o endereço, remova e cadastre de novo."
    else
      cadastrar_exporter "${EXPORTER_NAME:-outro}"
    fi

    ask_yes_no "Adicionar outro exporter?" n || break
  done

  # Sem nenhum exporter cadastrado, o item fica desligado no resumo e no estado.
  if (( ${#CUSTOM_EXPORTERS[@]} == 0 )); then
    ENABLE_EXPORTERS=0
    info "Nenhum exporter adicionado."
  fi
  return 0
}

# Depois do checklist: mantém os exporters que continuam marcados, tira os
# desmarcados e pergunta só o endereço dos que foram marcados agora.
collect_exporters_marcados() {
  local -a mantidos=()
  local item chave marcado tem_outro=0

  for item in "${CUSTOM_EXPORTERS[@]}"; do
    chave="$(exporter_chave_catalogo "${item%%|*}")"
    for marcado in "${EXPORTERS_MARCADOS[@]}"; do
      if [[ "$marcado" == "$chave" ]]; then
        mantidos+=("$item")
        [[ "$chave" == "outro" ]] && tem_outro=1
        break
      fi
    done
  done
  CUSTOM_EXPORTERS=("${mantidos[@]}")

  if (( ${#EXPORTERS_MARCADOS[@]} > 0 )); then
    step "Exporters adicionais"
    echo -e "${DIM}Use somente para exporter/endpoint Prometheus que já esteja ativo. ENTER aceita o endereço padrão.${NC}"
  fi

  for chave in "${EXPORTERS_MARCADOS[@]}"; do
    if [[ "$chave" == "outro" ]]; then
      (( tem_outro == 1 )) && continue
      while true; do
        echo
        info "Outro serviço com métricas Prometheus"
        cadastrar_exporter outro
        ask_yes_no "Adicionar mais um serviço?" n || break
      done
      continue
    fi
    nome_existe "$chave" "${CUSTOM_EXPORTERS[@]}" && continue
    cadastrar_exporter "$chave"
  done

  if (( ${#CUSTOM_EXPORTERS[@]} > 0 )); then
    ENABLE_EXPORTERS=1
  else
    ENABLE_EXPORTERS=0
  fi
  return 0
}

collect_blackbox_targets() {
  local choice
  step "Conectividade e disponibilidade (Blackbox)"
  while true; do
    local bn ba bm bt
    while true; do
      bn="$(ask_slug "Nome do alvo (ex.: fw_matriz)" "" host)"
      nome_existe "$bn" "${BLACKBOX_TARGETS[@]}" || break
      warn "Já existe um alvo chamado '${bn}'. Use outro nome."
    done
    # Do teste mais simples ao mais completo: cada nível confere mais coisas
    # que o anterior. Mesmos módulos e mesma ordem do Windows.
    choose "Tipo de teste (1 = mais simples, 6 = mais completo)" \
      "Ping: o host responde" \
      "TCP: a porta aceita conexão" \
      "DNS: o servidor resolve nomes" \
      "HTTP: a página responde (2xx)" \
      "HTTPS: responde e o certificado é válido" \
      "Conteúdo: a página abre sem erro (pega página quebrada que responde 200)"
    choice="$CHOOSE_RESULT"
    case "$choice" in
      1) bm=icmp_ipv4; ba="$(ask_address "IP ou FQDN" "" host)";;
      2) bm=tcp_connect; ba="$(ask_address "host:porta" "" hostport)";;
      3) bm=dns_udp; ba="$(ask_address "IP do servidor DNS" "" host)";;
      4) bm=http_2xx; ba="$(ask_address "URL ou endereço" "" destino)";;
      5) bm=http_2xx_ssl; ba="$(ask_address "URL ou endereço" "" destino)";;
      6) bm=http_2xx_content; ba="$(ask_address "URL ou endereço" "" destino)";;
    esac

    choose "Tipo do ativo" "firewall" "switch" "link" "aplicacao" "storage"
    choice="$CHOOSE_RESULT"
    case "$choice" in 1) bt=firewall;; 2) bt=switch;; 3) bt=link;; 4) bt=aplicacao;; 5) bt=storage;; esac

    BLACKBOX_TARGETS+=("${bn}|${ba}|${bm}|${bt}")
    ask_yes_no "Adicionar outro alvo de conectividade/disponibilidade?" n || break
  done
}

# Identificação. Com uma instalação existente carregada, as respostas atuais
# viram o padrão de cada pergunta (ENTER mantém).
collect_identification() {
  step "Identificação"
  local raw detected
  echo -e "  ${DIM}Perguntas com ${NC}${RED}${BOLD}*${NC}${DIM} são obrigatórias; ENTER aceita o valor entre colchetes.${NC}"

  while true; do
    raw="$(ask_required "Cliente, identificador da empresa e não do servidor (ex.: advocacia_martins)" "${CLIENTE:-}")"
    # O rótulo cliente só aceita minúsculas, números e _: hífen e espaço viram _.
    CLIENTE="$(normalize_slug "$raw" | tr '-' '_' | sed -E 's/_+/_/g; s/^_+|_+$//g')"
    [[ "$CLIENTE" =~ ^[a-z0-9_]+$ ]] && break
    warn "Cliente inválido: ${raw}. Use letras, números e _. Tente de novo."
  done
  [[ "$CLIENTE" != "$raw" ]] && info "Cliente será registrado como: ${CLIENTE}"

  detected="${HOST_LABEL:-$(normalize_slug "$(hostname -s 2>/dev/null || hostname)")}"
  HOST_LABEL="$(ask_slug "Hostname para monitoramento" "$detected" host)"

  local ambientes=(producao homologacao desenvolvimento backup teste)
  choose_padrao "Ambiente" "$(indice_de "${AMBIENTE:-producao}" "${ambientes[@]}")" "${ambientes[@]}"
  AMBIENTE="${ambientes[$((CHOOSE_RESULT-1))]}"

  LOCAL="$(ask_slug "Local" "${LOCAL:-matriz}" label)"

  local criticidades=(critico alto medio baixo)
  choose_padrao "Criticidade" "$(indice_de "${CRITICIDADE:-alto}" "${criticidades[@]}")" "${criticidades[@]}"
  CRITICIDADE="${criticidades[$((CHOOSE_RESULT-1))]}"
  return 0
}

collect_inputs() {
  configure_noc_destination
  collect_identification
  local choice

  step "Função deste Alloy"
  choose_padrao "Selecione o modo" 1 "Servidor monitorado" "Collector de rede" "Servidor + Collector de rede"
  choice="$CHOOSE_RESULT"
  MONITOR_SERVER=0
  COLLECTOR=0
  case "$choice" in
    1) MONITOR_SERVER=1;;
    2) COLLECTOR=1;;
    3) MONITOR_SERVER=1; COLLECTOR=1;;
  esac

  ENABLE_LOGS=0
  ENABLE_DOCKER=0
  ENABLE_DATABASES=0
  ENABLE_BLACKBOX=0
  ENABLE_SNMP=0
  ENABLE_EXPORTERS=0
  ENABLE_INTERNET=0
  ENABLE_LINKS=0
  ENABLE_VELOCIDADE=0
  ENABLE_ACESSOS=0
  LINKS=()
  BLACKBOX_TARGETS=()
  SNMP_TARGETS=()
  CUSTOM_EXPORTERS=()
  DATABASE_TARGETS=()

  if [[ "$MONITOR_SERVER" == "1" ]]; then
    echo
    echo -e "${BOLD}Perfil mínimo recomendado, habilitado automaticamente:${NC}"
    echo "  ✓ CPU"
    echo "  ✓ Memória"
    echo "  ✓ Filesystem"
    echo "  ✓ Disco e I/O"
    echo "  ✓ Rede e interfaces"
    echo "  ✓ Load average"
    echo "  ✓ Uptime"
    echo "  ✓ Informações de sistema/kernel"
    echo -e "  ${DIM}Serviços não fazem parte do perfil mínimo.${NC}"
  fi

  resource_checklist

  if [[ "$ENABLE_DATABASES" == "1" ]]; then
    collect_database_inputs
  fi

  [[ "$ENABLE_BLACKBOX" == "1" ]] && collect_blackbox_targets
  [[ "$ENABLE_SNMP" == "1" ]] && collect_snmp_targets
  collect_exporters_marcados

  perguntar_links

  step "Credenciais do NOC"
  info "Use a credencial cadastrada no NOC para autorizar o envio deste cliente."
  RW_USERNAME="$(ask_required "Usuário do remote_write")"
  RW_PASSWORD="$(ask_secret "Senha do remote_write")"

  if needs_loki; then
    echo
    info "Credencial do Loki (logs e eventos):"
    if ask_yes_no "Usar a mesma credencial do remote_write no Loki?" s; then
      LOKI_USERNAME="$RW_USERNAME"
      LOKI_PASSWORD="$RW_PASSWORD"
    else
      LOKI_USERNAME="$(ask_required "Usuário do Loki")"
      LOKI_PASSWORD="$(ask_secret "Senha do Loki")"
    fi
  fi
}

# show_plan ["pergunta de confirmação" | --resumo]
show_plan() {
  local confirmacao="${1:-Confirmar instalação e configuração?}"
  if [[ "$confirmacao" == "--resumo" ]]; then
    step "Configuração atual (ainda não gravada)"
  elif [[ "$EDICAO" == "1" ]]; then
    step "Resumo antes de aplicar as alterações"
  else
    step "Resumo antes da instalação"
  fi

  summary_row "Cliente:" "$CLIENTE"
  summary_row "SO:" "$OS_FAMILY"
  summary_row "Host:" "$HOST_LABEL"
  summary_row "Ambiente:" "$AMBIENTE"
  summary_row "Local:" "$LOCAL"
  summary_row "Criticidade:" "$CRITICIDADE"
  summary_row "Destino:" "$NOC_HOST"
  summary_row "Servidor monitorado:" "$([[ "$MONITOR_SERVER" == 1 ]] && echo sim || echo não)"
  summary_row "Métricas básicas do host:" "$([[ "$MONITOR_SERVER" == 1 ]] && echo sim || echo não)"
  summary_row "Docker:" "$([[ "$ENABLE_DOCKER" == 1 ]] && echo sim || echo não)"
  summary_row "Banco de dados:" "$([[ "${ENABLE_DATABASES:-0}" == 1 ]] && echo "sim (${#DATABASE_TARGETS[@]})" || echo não)"
  summary_row "Logs:" "$([[ "$ENABLE_LOGS" == 1 ]] && echo sim || echo não)"
  summary_row "Conectividade (Blackbox):" "$([[ "$ENABLE_BLACKBOX" == 1 ]] && echo "sim (${#BLACKBOX_TARGETS[@]})" || echo não)"
  summary_row "SNMP:" "$([[ "$ENABLE_SNMP" == 1 ]] && echo "sim (${#SNMP_TARGETS[@]})" || echo não)"
  summary_row "Exporters adicionais:" "${#CUSTOM_EXPORTERS[@]}"
  summary_row "Internet e DNS:" "$([[ "$ENABLE_INTERNET" == 1 ]] && echo sim || echo não)"
  summary_row "Links de internet:" "$([[ "$ENABLE_LINKS" == 1 ]] && echo "sim (${#LINKS[@]})" || echo não)"
  summary_row "Teste de velocidade:" "$([[ "$ENABLE_VELOCIDADE" == 1 ]] && echo sim || echo não)"
  summary_row "Acessos (logins):" "$([[ "${ENABLE_ACESSOS:-0}" == 1 ]] && echo sim || echo não)"

  echo
  [[ "$confirmacao" == "--resumo" ]] && return 0
  ask_yes_no "$confirmacao" s || { warn "Cancelado. Nada foi gravado."; exit 0; }
}

final_summary() {
  [[ -n "$LOCALE_UTF8" ]] && local LC_ALL="$LOCALE_UTF8"
  local titulo="✔  ${1:-INSTALAÇÃO CONCLUÍDA}"
  local alloy_estado="ativo" cor_alloy="$GREEN"
  systemctl is-active --quiet alloy || { alloy_estado="parado"; cor_alloy="$RED"; }

  # Preenchimento por ${#}, que conta caracteres (printf %-Ns conta bytes e
  # desalinha rótulos acentuados).
  campo() {
    local pad=$(( 23 - ${#1} )); (( pad < 1 )) && pad=1
    printf '    %b%s%b%*s%b%s%b\n' "$DIM" "$1" "$NC" "$pad" '' "${3:-$NC}" "$2" "$NC"
  }
  secao() { echo; echo -e "  ${BLUE}${BOLD}$1${NC}"; }
  comando() { echo -e "    ${CYAN}\$${NC} $1"; }

  echo
  echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
  local esq=$(( (54 - ${#titulo}) / 2 )) dir
  dir=$(( 54 - ${#titulo} - esq ))
  echo -e "${GREEN}${BOLD}  ║$(printf '%*s' "$esq" '')${titulo}$(printf '%*s' "$dir" '')║${NC}"
  echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"

  secao "Identificação"
  campo "Cliente" "$CLIENTE" "$BOLD"
  campo "Host" "$HOST_LABEL" "$BOLD"
  campo "Alloy" "$alloy_estado" "$cor_alloy"

  secao "Envio para o NOC"
  campo "Métricas" "$RW_URL"
  needs_loki && campo "Logs e eventos" "$LOKI_URL"

  secao "Coletas ligadas"
  campo "Servidor" "CPU, memória, discos, rede" "$GREEN"
  [[ "$ENABLE_LOGS" == 1 ]] && campo "Logs do sistema" "sim" "$GREEN"
  [[ "$ENABLE_DOCKER" == 1 ]] && campo "Docker" "logs pelo Alloy; estado e eventos pela Coleta" "$GREEN"
  [[ "$ENABLE_INTERNET" == 1 ]] && campo "Internet e DNS" "sim" "$GREEN"
  [[ "$ENABLE_LINKS" == 1 ]] && campo "Links de internet" "${#LINKS[@]}" "$GREEN"
  [[ "$ENABLE_VELOCIDADE" == 1 ]] && campo "Teste de velocidade" "a cada 30 min" "$GREEN"
  [[ "${ENABLE_ACESSOS:-0}" == 1 ]] && campo "Acessos" "logins com origem e alerta de privilegiado" "$GREEN"
  [[ "$ENABLE_BLACKBOX" == 1 ]] && campo "Conectividade" "${#BLACKBOX_TARGETS[@]} alvo(s)" "$GREEN"
  [[ "$ENABLE_SNMP" == 1 ]] && campo "SNMP" "${#SNMP_TARGETS[@]} equipamento(s)" "$GREEN"
  (( ${#DATABASE_TARGETS[@]} > 0 )) && campo "Banco(s) de dados" "${#DATABASE_TARGETS[@]}" "$GREEN"

  secao "Arquivos"
  campo "Configuração do Alloy" "$CONFIG_FILE"
  campo "Credenciais" "${ENV_FILE} (600)"
  coleta_enabled && campo "Coleta Complementar" "$COLETA_CONFIG"
  campo "Respostas gravadas" "$ESTADO_INSTALACAO"
  campo "UI local" "http://127.0.0.1:12345"

  secao "Atualização automática"
  if systemctl is-enabled --quiet nextec-atualizador.timer 2>/dev/null; then
    campo "Atualizador" "ligado, todo dia entre 01h e 05h (Brasília)" "$GREEN"
  else
    campo "Atualizador" "não instalado" "$YELLOW"
  fi

  secao "Diagnóstico"
  comando "systemctl status alloy"
  comando "journalctl -u alloy -f"
  comando "alloy validate ${CONFIG_FILE}"
  coleta_enabled && comando "systemctl status coleta-complementar"
  coleta_enabled && comando "python3 ${COLETA_BIN} verificar"
  comando "python3 ${ATUALIZADOR_BIN} verificar"

  echo
  echo -e "  ${YELLOW}${BOLD}Próximo passo:${NC} confira no NOC (Explore) os dados de cliente=\"${CLIENTE}\" e host=\"${HOST_LABEL}\"."
  echo
  return 0
}

# ------------------------------------------------------------------------------
# RESPOSTAS DA INSTALAÇÃO E ATUALIZADOR AUTOMÁTICO
# ------------------------------------------------------------------------------
# As respostas ficam em ${ESTADO_INSTALACAO}, sem senha, para o modo
# --atualizar reaplicar a mesma instalação com um instalador mais novo.
# O arquivo é lido linha a linha com lista fechada de chaves; nunca é executado.
salvar_estado_instalacao() {
  local modo="${1:-completo}" tmp item
  install -d -m 0755 "$NEXTEC_DIR"
  tmp="$(mktemp)"
  {
    echo "# Respostas da instalação Nextec ($(date -u +%Y-%m-%dT%H:%M:%SZ))."
    echo "# Lido pelo instalador em --atualizar. Sem senha: credenciais ficam em ${ENV_FILE}."
    echo "FORMATO=1"
    echo "INSTALADOR_VERSAO=${INSTALLER_VERSION}"
    echo "MODO=${modo}"
    echo "NOC_HOST=${NOC_HOST}"
    echo "CLIENTE=${CLIENTE:-}"
    echo "HOST_LABEL=${HOST_LABEL:-}"
    echo "AMBIENTE=${AMBIENTE:-}"
    echo "LOCAL=${LOCAL:-}"
    echo "CRITICIDADE=${CRITICIDADE:-}"
    echo "MONITOR_SERVER=${MONITOR_SERVER:-0}"
    echo "COLLECTOR=${COLLECTOR:-0}"
    echo "ENABLE_LOGS=${ENABLE_LOGS:-0}"
    echo "ENABLE_DOCKER=${ENABLE_DOCKER:-0}"
    echo "ENABLE_DATABASES=${ENABLE_DATABASES:-0}"
    echo "ENABLE_BLACKBOX=${ENABLE_BLACKBOX:-0}"
    echo "ENABLE_SNMP=${ENABLE_SNMP:-0}"
    echo "ENABLE_EXPORTERS=${ENABLE_EXPORTERS:-0}"
    echo "ENABLE_INTERNET=${ENABLE_INTERNET:-0}"
    echo "ENABLE_LINKS=${ENABLE_LINKS:-0}"
    echo "ENABLE_VELOCIDADE=${ENABLE_VELOCIDADE:-0}"
    echo "ENABLE_ACESSOS=${ENABLE_ACESSOS:-0}"
    for item in "${LINKS[@]}"; do echo "LINK=${item}"; done
    for item in "${BLACKBOX_TARGETS[@]}"; do echo "BLACKBOX=${item}"; done
    for item in "${SNMP_TARGETS[@]}"; do echo "SNMP=${item}"; done
    for item in "${CUSTOM_EXPORTERS[@]}"; do echo "EXPORTER=${item}"; done
    # Só o tipo do banco: a DSN fica em NEXTEC_DB_DSN_n, na mesma ordem.
    for item in "${DATABASE_TARGETS[@]}"; do echo "BANCO=${item%%|*}"; done
  } > "$tmp"
  install -m 0600 "$tmp" "$ESTADO_INSTALACAO"
  rm -f "$tmp"
}

carregar_estado_instalacao() {
  [[ -f "$ESTADO_INSTALACAO" ]] || { err "Sem respostas gravadas em ${ESTADO_INSTALACAO}: rode o instalador interativo uma vez neste servidor."; return 1; }
  local linha chave valor
  LINKS=(); BLACKBOX_TARGETS=(); SNMP_TARGETS=(); CUSTOM_EXPORTERS=(); DATABASE_TARGETS=()
  MODO_INSTALACAO="completo"
  # Recurso novo vem ligado em instalação antiga, que não tem a resposta gravada.
  ENABLE_ACESSOS=1
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    [[ -z "$linha" || "$linha" == \#* ]] && continue
    [[ "$linha" == *=* ]] || continue
    chave="${linha%%=*}"
    valor="${linha#*=}"
    case "$chave" in
      CLIENTE|LOCAL)
        [[ "$valor" =~ ^[a-z0-9_]*$ ]] || { err "Valor inválido de ${chave} em ${ESTADO_INSTALACAO}."; return 1; }
        printf -v "$chave" '%s' "$valor" ;;
      HOST_LABEL)
        [[ "$valor" =~ ^[a-z0-9_.-]*$ ]] || { err "Valor inválido de ${chave} em ${ESTADO_INSTALACAO}."; return 1; }
        HOST_LABEL="$valor" ;;
      AMBIENTE)
        [[ "$valor" =~ ^(producao|homologacao|desenvolvimento|backup|teste)?$ ]] || { err "AMBIENTE inválido."; return 1; }
        AMBIENTE="$valor" ;;
      CRITICIDADE)
        [[ "$valor" =~ ^(critico|alto|medio|baixo)?$ ]] || { err "CRITICIDADE inválida."; return 1; }
        CRITICIDADE="$valor" ;;
      NOC_HOST)
        [[ "$valor" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { err "NOC_HOST inválido."; return 1; }
        NOC_HOST="$valor" ;;
      MODO)
        [[ "$valor" =~ ^(completo|somente_coleta)$ ]] || { err "MODO inválido."; return 1; }
        MODO_INSTALACAO="$valor" ;;
      INSTALADOR_VERSAO)
        [[ "$valor" =~ ^[0-9]+(\.[0-9]+)*$ ]] && ESTADO_INSTALADOR_VERSAO="$valor" ;;
      MONITOR_SERVER|COLLECTOR|ENABLE_LOGS|ENABLE_DOCKER|ENABLE_DATABASES|ENABLE_BLACKBOX|ENABLE_SNMP|ENABLE_EXPORTERS|ENABLE_INTERNET|ENABLE_LINKS|ENABLE_VELOCIDADE|ENABLE_ACESSOS)
        [[ "$valor" =~ ^[01]$ ]] || { err "Valor inválido de ${chave}."; return 1; }
        printf -v "$chave" '%s' "$valor" ;;
      LINK) LINKS+=("$valor") ;;
      BLACKBOX) BLACKBOX_TARGETS+=("$valor") ;;
      SNMP) SNMP_TARGETS+=("$valor") ;;
      EXPORTER) CUSTOM_EXPORTERS+=("$valor") ;;
      BANCO)
        [[ "$valor" =~ ^(postgres|mysql|sqlserver)$ ]] || { err "BANCO inválido."; return 1; }
        DATABASE_TARGETS+=("${valor}|") ;;
      *) ;;
    esac
  done < "$ESTADO_INSTALACAO"
  RW_URL="https://${NOC_HOST}/api/v1/write"
  LOKI_URL="https://${NOC_HOST}/loki/api/v1/push"
  return 0
}

install_atualizador() {
  step "Instalando o atualizador automático Nextec"
  command -v python3 >/dev/null 2>&1 || {
    case "$PKG_FAMILY" in
      apt) apt-get install -y -q python3 >/dev/null;;
      dnf|yum) "$PKG_FAMILY" install -y -q python3 >/dev/null;;
      zypper) zypper -q -n install python3 >/dev/null;;
    esac
  }
  command -v python3 >/dev/null 2>&1 || { warn "python3 indisponível: atualizador automático não instalado."; return 0; }

  local tmp
  tmp="$(mktemp)"
  if [[ -n "${ATUALIZADOR_ARQUIVO:-}" ]]; then
    cp "$ATUALIZADOR_ARQUIVO" "$tmp" || { err "Arquivo do atualizador não encontrado: ${ATUALIZADOR_ARQUIVO}"; exit 1; }
  elif ! curl -fsSL "$ATUALIZADOR_URL" -o "$tmp"; then
    rm -f "$tmp"
    warn "Não foi possível baixar o atualizador de ${ATUALIZADOR_URL}; esta máquina não receberá atualizações automáticas."
    return 0
  fi
  python3 -m py_compile "$tmp" || { rm -f "$tmp"; err "Arquivo do atualizador é inválido."; exit 1; }
  install -D -m 0755 -o root -g root "$tmp" "$ATUALIZADOR_BIN"
  rm -f "$tmp"

  install -d -m 0755 "$NEXTEC_DIR" "$COLETA_DADOS" "$COLETA_TEXTFILE" "$(dirname "$COLETA_EVENTOS")"
  # A configuração do operador (onda fixa, desligar) não é sobrescrita.
  if [[ ! -f "$ATUALIZADOR_CONFIG" ]]; then
    cat > "$ATUALIZADOR_CONFIG" <<'EOF'
; Atualizador automático Nextec.
; onda: auto (servidores da Nextec na 0, ~10% dos clientes na 1, demais na 2) ou 0, 1, 2.
; habilitado: sim ou não. Desligar aqui só vale para este servidor.
[atualizador]
habilitado = sim
onda = auto
EOF
    chmod 0644 "$ATUALIZADOR_CONFIG"
  fi

  cat > "$ATUALIZADOR_SERVICE" <<EOF
[Unit]
Description=Atualizador automático do monitoramento Nextec
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 ${ATUALIZADOR_BIN} executar
# Roda como root: reaplica o instalador (pacotes, serviços e configuração).
# Só aplica o que vier num manifesto assinado pela chave da Nextec.
PrivateTmp=true
# Maior que a soma dos limites internos (instalador, saúde, volta automática).
TimeoutStartSec=2h
EOF
  # Madrugada no horário de Brasília, com atraso aleatório de até 4h por
  # servidor (01h às 05h), para a frota não atualizar toda no mesmo minuto.
  # O fuso vai no próprio OnCalendar (systemd 235+): servidor em nuvem fora do
  # Brasil (ex.: Contabo, CEST) também atualiza de madrugada aqui. Persistent
  # recupera execução perdida com a máquina desligada.
  local quando="*-*-* 01:00:00" sd_versao
  sd_versao="$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ "$sd_versao" =~ ^[0-9]+$ ]] && (( sd_versao >= 235 )) && [[ -f /usr/share/zoneinfo/America/Sao_Paulo ]]; then
    quando+=" America/Sao_Paulo"
  else
    warn "systemd ${sd_versao:-?} sem fuso no timer: o atualizador usa o fuso deste servidor ($(date +%Z))."
  fi
  cat > "$ATUALIZADOR_TIMER" <<EOF
[Unit]
Description=Atualizador automático do monitoramento Nextec (diário, de madrugada)

[Timer]
OnCalendar=${quando}
RandomizedDelaySec=4h
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now nextec-atualizador.timer >/dev/null 2>&1 || warn "Não foi possível ligar o timer do atualizador."
  ok "Atualizador $(python3 "$ATUALIZADOR_BIN" versao 2>/dev/null || echo instalado) com timer diário de madrugada."
}

# ------------------------------------------------------------------------------
# INSTALAÇÃO EXISTENTE: MENU DE MANUTENÇÃO
# ------------------------------------------------------------------------------
# Rodar o instalador num servidor que já tem o Alloy não refaz tudo do zero:
# mostra o que está instalado (com as versões) e oferece alterar só o que for
# preciso, a partir das respostas gravadas em ${ESTADO_INSTALACAO}. Credenciais
# que não foram alteradas ficam como estão em ${ENV_FILE}.
instalacao_existente() {
  [[ -f "$CONFIG_FILE" ]] && command -v alloy >/dev/null 2>&1 && systemctl cat alloy.service >/dev/null 2>&1
}

env_tem_chave() {
  [[ -f "$ENV_FILE" ]] && grep -qE "^${1}=" "$ENV_FILE"
}

# remover_env_var 'REGEX_DA_CHAVE': apaga do ${ENV_FILE} as linhas dessa chave.
remover_env_var() {
  [[ -f "$ENV_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -vE "^(${1})=" "$ENV_FILE" > "$tmp" || true
  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

# Copia a credencial do remote_write para o Loki sem ler a senha: só troca o
# nome da chave na linha já gravada (o valor continua com o mesmo escape).
copiar_credencial_rw_para_loki() {
  local tmp
  tmp="$(mktemp)"
  grep -vE '^NEXTEC_LOKI_(USERNAME|PASSWORD)=' "$ENV_FILE" > "$tmp" || true
  sed -n -e 's/^NEXTEC_RW_USERNAME=/NEXTEC_LOKI_USERNAME=/p' \
         -e 's/^NEXTEC_RW_PASSWORD=/NEXTEC_LOKI_PASSWORD=/p' "$ENV_FILE" >> "$tmp"
  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

desligar_coleta_complementar() {
  systemctl cat coleta-complementar.service >/dev/null 2>&1 || return 0
  systemctl disable --now coleta-complementar >/dev/null 2>&1 || true
  info "Coleta Complementar desligada: nenhum módulo dela está ativo."
}

estado_servico() {
  case "$(systemctl is-active "$1" 2>/dev/null || true)" in
    active) echo "ativo" ;;
    activating|reloading) echo "iniciando" ;;
    failed) echo "com falha" ;;
    *) echo "parado" ;;
  esac
}

versao_pacote_nextec() {
  local estado="/var/lib/nextec-atualizador/estado.json"
  [[ -f "$estado" ]] || { echo "nenhum"; return 0; }
  python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("versao_instalada") or "nenhum")
except Exception:
    print("não identificada")' "$estado" 2>/dev/null || echo "não identificada"
}

mostrar_status_instalacao() {
  step "Instalação existente detectada"
  local quando=""
  summary_row "Este instalador:" "v${INSTALLER_VERSION}"
  if [[ "$ESTADO_CARREGADO" == "1" ]]; then
    quando="$(sed -n 's/^# Respostas da instalação Nextec (\(.*\))\.$/\1/p' "$ESTADO_INSTALACAO" | head -n1)"
    [[ -n "$quando" ]] && quando="$(date -d "$quando" '+%d/%m/%Y %H:%M' 2>/dev/null || echo "$quando")"
    summary_row "Instalado com:" "v${ESTADO_INSTALADOR_VERSAO:-?}${quando:+ em ${quando}}"
    summary_row "Cliente:" "${CLIENTE:-?}"
    summary_row "Host:" "${HOST_LABEL:-?}"
  else
    summary_row "Instalado com:" "versão anterior à 2.4.0 (sem respostas gravadas)"
  fi

  local alloy_v coleta="não instalada" atualizador="não instalado"
  alloy_v="$(alloy_versao_instalada)"
  summary_row "Grafana Alloy:" "${alloy_v:-versão não identificada} ($(estado_servico alloy))"
  if [[ -f "$COLETA_BIN" ]]; then
    coleta="$(python3 "$COLETA_BIN" versao 2>/dev/null || echo '?') ($(estado_servico coleta-complementar))"
  fi
  summary_row "Coleta Complementar:" "$coleta"
  if [[ -f "$ATUALIZADOR_BIN" ]]; then
    atualizador="$(python3 "$ATUALIZADOR_BIN" versao 2>/dev/null || echo '?')"
    systemctl is-enabled --quiet nextec-atualizador.timer 2>/dev/null && atualizador+=" (ligado)" || atualizador+=" (timer desligado)"
  fi
  summary_row "Atualizador:" "$atualizador"
  summary_row "Pacote Nextec aplicado:" "$(versao_pacote_nextec)"

  if [[ "$ESTADO_CARREGADO" == "1" ]]; then
    local ligados=()
    [[ "${MONITOR_SERVER:-0}" == 1 ]] && ligados+=("servidor")
    [[ "${ENABLE_LOGS:-0}" == 1 ]] && ligados+=("logs")
    [[ "${ENABLE_DOCKER:-0}" == 1 ]] && ligados+=("docker")
    [[ "${ENABLE_DATABASES:-0}" == 1 ]] && ligados+=("bancos")
    [[ "${ENABLE_BLACKBOX:-0}" == 1 ]] && ligados+=("conectividade")
    [[ "${ENABLE_SNMP:-0}" == 1 ]] && ligados+=("snmp")
    [[ "${ENABLE_EXPORTERS:-0}" == 1 ]] && ligados+=("exporters")
    [[ "${ENABLE_INTERNET:-0}" == 1 ]] && ligados+=("internet")
    [[ "${ENABLE_LINKS:-0}" == 1 ]] && ligados+=("links")
    [[ "${ENABLE_VELOCIDADE:-0}" == 1 ]] && ligados+=("velocidade")
    [[ "${ENABLE_ACESSOS:-0}" == 1 ]] && ligados+=("acessos")
    local IFS=','
    summary_row "Coletas ligadas:" "$(printf '%s' "${ligados[*]:-nenhuma}" | sed 's/,/, /g')"
  fi
  echo
}

# descrever_item "a|b|...": "a (b)", para listar alvos, links e exporters.
descrever_item() {
  local a b
  IFS='|' read -r a b _ <<<"$1"
  case "$b" in primario|failover|sdwan) b="$(papel_rotulo "$b")";; esac
  printf '%s (%s)' "$a" "$b"
}

# editar_lista NOME_DO_ARRAY "Título" função_que_cadastra VARIAVEL_ENABLE
# Lista os itens e permite adicionar, remover um ou refazer a lista. Lista
# vazia desliga o recurso; lista com item liga.
editar_lista() {
  local -n _lista="$1"
  local titulo="$2" coletor="$3" flag="$4" i escolha
  while true; do
    step "$titulo"
    if (( ${#_lista[@]} == 0 )); then
      info "Nenhum item cadastrado."
    else
      for i in "${!_lista[@]}"; do
        printf '  %b%d%b  %s\n' "$CYAN" "$((i+1))" "$NC" "$(descrever_item "${_lista[$i]}")"
      done
    fi
    echo
    choose_padrao "O que deseja fazer?" 1 "Voltar" "Adicionar" "Remover um item" "Apagar todos e cadastrar de novo"
    case "$CHOOSE_RESULT" in
      1) break ;;
      2) "$coletor" ;;
      3)
        if (( ${#_lista[@]} == 0 )); then
          warn "Não há item para remover."
          continue
        fi
        while true; do
          read -r -p "$(pergunta "Número do item a remover" "" "ENTER cancela")" escolha || entrada_encerrada
          escolha="$(trim "$escolha")"
          [[ -z "$escolha" ]] && break
          if [[ "$escolha" =~ ^[0-9]+$ ]] && (( escolha >= 1 && escolha <= ${#_lista[@]} )); then
            ok "Removido: $(descrever_item "${_lista[$((escolha-1))]}")"
            _lista=("${_lista[@]:0:$((escolha-1))}" "${_lista[@]:$escolha}")
            break
          fi
          warn "Número inválido."
        done
        ;;
      4) _lista=(); "$coletor" ;;
    esac
  done
  if (( ${#_lista[@]} > 0 )); then
    printf -v "$flag" '%s' 1
  else
    printf -v "$flag" '%s' 0
    info "Lista vazia: recurso desligado."
  fi
  return 0
}

editar_recursos() {
  local db_antes="${ENABLE_DATABASES:-0}"
  CHECKLIST_DO_ESTADO=1
  resource_checklist
  CHECKLIST_DO_ESTADO=0

  if [[ "$ENABLE_DATABASES" == "1" && "$db_antes" != "1" ]]; then
    collect_database_inputs
    DB_REDEFINIDO=1
    (( ${#DATABASE_TARGETS[@]} > 0 )) || ENABLE_DATABASES=0
  fi
  [[ "$ENABLE_DATABASES" == "1" ]] || DATABASE_TARGETS=()

  if [[ "$ENABLE_BLACKBOX" == "1" ]]; then
    (( ${#BLACKBOX_TARGETS[@]} > 0 )) || collect_blackbox_targets
  else
    BLACKBOX_TARGETS=()
  fi
  if [[ "$ENABLE_SNMP" == "1" ]]; then
    (( ${#SNMP_TARGETS[@]} > 0 )) || collect_snmp_targets
  else
    SNMP_TARGETS=()
  fi
  collect_exporters_marcados
  if [[ "$ENABLE_INTERNET" == "1" ]]; then
    (( ${#LINKS[@]} > 0 )) || collect_links_inputs
  else
    LINKS=()
  fi
  ENABLE_LINKS=0
  (( ${#LINKS[@]} > 0 )) && ENABLE_LINKS=1
  return 0
}

editar_bancos() {
  if [[ "${ENABLE_DATABASES:-0}" != "1" ]]; then
    warn "Banco de dados está desligado. Ligue em \"Recursos\" primeiro."
    return 0
  fi
  step "Bancos de dados"
  local item
  for item in "${DATABASE_TARGETS[@]}"; do echo "  • ${item%%|*}"; done
  info "As credenciais (DSN) não são exibidas; ficam em ${ENV_FILE}."
  ask_yes_no "Cadastrar as credenciais dos bancos de novo?" n || return 0
  collect_database_inputs
  DB_REDEFINIDO=1
  if (( ${#DATABASE_TARGETS[@]} == 0 )); then
    ENABLE_DATABASES=0
    info "Nenhum banco confirmado: coleta de banco desligada."
  fi
  return 0
}

editar_credenciais() {
  step "Credenciais do NOC"
  info "Use a credencial cadastrada no NOC para autorizar o envio deste cliente."
  RW_USERNAME="$(ask_required "Usuário do remote_write")"
  RW_PASSWORD="$(ask_secret "Senha do remote_write")"
  if ask_yes_no "Usar a mesma credencial do remote_write no Loki (logs e eventos)?" s; then
    LOKI_USERNAME="$RW_USERNAME"
    LOKI_PASSWORD="$RW_PASSWORD"
  else
    LOKI_USERNAME="$(ask_required "Usuário do Loki")"
    LOKI_PASSWORD="$(ask_secret "Senha do Loki")"
  fi
  NOVAS_CREDENCIAIS=1
}

# Logs ou eventos ligados agora num servidor que nunca enviou ao Loki: falta a
# credencial dele. Pergunta antes de aplicar, para não gerar config sem senha.
preparar_credenciais_edicao() {
  LOKI_COPIAR_RW=0
  LOKI_NOVA=0
  [[ "$NOVAS_CREDENCIAIS" == "1" ]] && return 0
  needs_loki || return 0
  env_tem_chave NEXTEC_LOKI_USERNAME && return 0
  step "Credencial do Loki"
  info "Este servidor ainda não envia logs/eventos e não tem credencial do Loki."
  if ask_yes_no "Usar a mesma credencial do remote_write no Loki?" s; then
    LOKI_COPIAR_RW=1
  else
    LOKI_USERNAME="$(ask_required "Usuário do Loki")"
    LOKI_PASSWORD="$(ask_secret "Senha do Loki")"
    LOKI_NOVA=1
  fi
}

gravar_credenciais_edicao() {
  if [[ "$NOVAS_CREDENCIAIS" == "1" ]]; then
    append_env_var "NEXTEC_RW_USERNAME" "$RW_USERNAME"
    append_env_var "NEXTEC_RW_PASSWORD" "$RW_PASSWORD"
    append_env_var "NEXTEC_LOKI_USERNAME" "$LOKI_USERNAME"
    append_env_var "NEXTEC_LOKI_PASSWORD" "$LOKI_PASSWORD"
  elif [[ "${LOKI_COPIAR_RW:-0}" == "1" ]]; then
    copiar_credencial_rw_para_loki
  elif [[ "${LOKI_NOVA:-0}" == "1" ]]; then
    append_env_var "NEXTEC_LOKI_USERNAME" "$LOKI_USERNAME"
    append_env_var "NEXTEC_LOKI_PASSWORD" "$LOKI_PASSWORD"
  fi

  if [[ "${ENABLE_DATABASES:-0}" != "1" ]]; then
    remover_env_var 'NEXTEC_DB_DSN_[0-9]+'
  elif [[ "$DB_REDEFINIDO" == "1" ]]; then
    remover_env_var 'NEXTEC_DB_DSN_[0-9]+'
    local idx=0 item db_type db_dsn
    for item in "${DATABASE_TARGETS[@]}"; do
      IFS='|' read -r db_type db_dsn <<<"$item"
      idx=$((idx+1))
      append_env_var "NEXTEC_DB_DSN_${idx}" "$db_dsn"
    done
  fi
  append_env_var "CUSTOM_ARGS" "--server.http.listen-addr=127.0.0.1:12345"
}

aplicar_edicao() {
  EDICAO=1
  preparar_credenciais_edicao
  show_plan "Aplicar estas alterações neste servidor?"

  check_connectivity || warn "Conectividade com o NOC falhou; as alterações serão aplicadas mesmo assim."
  install_coleta_complementar
  coleta_enabled || desligar_coleta_complementar
  prepare_snmp_config
  write_blackbox_config
  configure_service_env
  generate_config
  validate_and_start
  rm -f "${CONFIG_FILE}.nextec-preinstall"
  salvar_estado_instalacao completo
  install_atualizador
  final_summary "ALTERAÇÕES APLICADAS"
}

menu_alterar() {
  detect_docker
  detect_databases
  local alterou=0 rotulo
  local opcoes=(
    "Identificação (cliente, host, ambiente, local, criticidade)"
    "Recursos (ligar e desligar coletas)"
    "Bancos de dados (credenciais)"
    "Alvos de conectividade (Blackbox)"
    "Equipamentos SNMP"
    "Exporters adicionais"
    "Links de internet"
    "Credenciais do NOC"
    "Destino do NOC"
    "Ver o resumo atual"
    "Gravar e aplicar as alterações"
    "Sair sem gravar"
  )
  while true; do
    step "Alterar a configuração"
    choose_padrao "O que deseja alterar?" 11 "${opcoes[@]}"
    rotulo="${opcoes[$((CHOOSE_RESULT-1))]}"
    case "$rotulo" in
      Identificação*) collect_identification; alterou=1 ;;
      Recursos*) editar_recursos; alterou=1 ;;
      Bancos*) editar_bancos; alterou=1 ;;
      Alvos*)
        editar_lista BLACKBOX_TARGETS "Alvos de conectividade (Blackbox)" collect_blackbox_targets ENABLE_BLACKBOX
        [[ "$ENABLE_BLACKBOX" == "1" ]] && COLLECTOR=1
        alterou=1 ;;
      Equipamentos*)
        editar_lista SNMP_TARGETS "Equipamentos SNMP" collect_snmp_targets ENABLE_SNMP
        [[ "$ENABLE_SNMP" == "1" ]] && COLLECTOR=1
        alterou=1 ;;
      Exporters*) editar_lista CUSTOM_EXPORTERS "Exporters adicionais" collect_custom_exporters ENABLE_EXPORTERS; alterou=1 ;;
      Links*)
        editar_lista LINKS "Links de internet" collect_links_inputs ENABLE_LINKS
        [[ "$ENABLE_LINKS" == "1" ]] && ENABLE_INTERNET=1
        alterou=1 ;;
      Credenciais*) editar_credenciais; alterou=1 ;;
      Destino*) configure_noc_destination; alterou=1 ;;
      Ver*) show_plan --resumo ;;
      Gravar*)
        if [[ "$alterou" != "1" ]]; then
          info "Nada foi alterado."
          return 0
        fi
        aplicar_edicao
        return 0 ;;
      Sair*)
        [[ "$alterou" == "1" ]] && warn "Alterações descartadas; nada foi gravado no servidor."
        return 0 ;;
    esac
  done
}

atualizar_somente_alloy() {
  local antes depois
  antes="$(alloy_versao_instalada)"
  mkdir -p "$BACKUP_DIR"
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.nextec-preinstall"
  cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.alloy.$(date +%Y%m%d-%H%M%S)"
  install_alloy
  # O pacote não deve trocar o config.alloy, mas se trocar a configuração da
  # Nextec volta antes de validar.
  if ! cmp -s "$CONFIG_FILE" "${CONFIG_FILE}.nextec-preinstall"; then
    cp -a "${CONFIG_FILE}.nextec-preinstall" "$CONFIG_FILE"
    warn "O pacote alterou o config.alloy; a configuração da Nextec foi restaurada."
  fi
  validate_and_start
  rm -f "${CONFIG_FILE}.nextec-preinstall"
  depois="$(alloy_versao_instalada)"
  ok "Grafana Alloy: ${antes:-?} → ${depois:-?}. Configuração mantida."
  if [[ -f "$ATUALIZADOR_BIN" ]]; then
    info "O atualizador automático mantém a versão do Alloy definida pela Nextec: na próxima versão publicada ele pode trocar esta."
  fi
}

validar_e_reiniciar() {
  cp -a "$CONFIG_FILE" "${CONFIG_FILE}.nextec-preinstall"
  validate_and_start
  rm -f "${CONFIG_FILE}.nextec-preinstall"
  if systemctl is-enabled --quiet coleta-complementar 2>/dev/null; then
    systemctl restart coleta-complementar
    ok "Coleta Complementar reiniciada."
    python3 "$COLETA_BIN" verificar || warn "A verificação da Coleta Complementar apontou problemas (ver acima)."
  fi
  ok "Manutenção concluída."
}

# Servidor no modo somente coleta (Alloy fora deste instalador): não instala o
# Alloy por cima sem o operador pedir.
menu_somente_coleta_existente() {
  step "Servidor no modo somente Coleta Complementar"
  info "O Alloy deste servidor roda fora deste instalador (ex.: Alloy da stack)."
  choose_padrao "O que deseja fazer?" 3 \
    "Alterar a Coleta Complementar (mantém o modo somente coleta)" \
    "Instalar o Grafana Alloy completo neste servidor" \
    "Cancelar"
  case "$CHOOSE_RESULT" in
    1) main_somente_coleta; SEGUIR_INSTALACAO=0 ;;
    2) SEGUIR_INSTALACAO=1 ;;
    3) info "Nada foi alterado."; SEGUIR_INSTALACAO=0 ;;
  esac
}

# Define SEGUIR_INSTALACAO: 1 segue para o fluxo completo, 0 encerra.
menu_manutencao() {
  SEGUIR_INSTALACAO=1
  ESTADO_CARREGADO=0
  if ! instalacao_existente; then
    if [[ -f "$ESTADO_INSTALACAO" ]] && grep -qx 'MODO=somente_coleta' "$ESTADO_INSTALACAO"; then
      menu_somente_coleta_existente
    fi
    return 0
  fi

  detect_os
  if [[ -f "$ESTADO_INSTALACAO" ]] && carregar_estado_instalacao; then
    ESTADO_CARREGADO=1
  fi
  mostrar_status_instalacao

  local opcoes=() rotulo
  if [[ "$ESTADO_CARREGADO" == "1" ]]; then
    opcoes+=("Ver e alterar a configuração atual")
  else
    info "Sem respostas gravadas: rode \"Reconfigurar tudo\" uma vez; depois a alteração pontual fica disponível."
  fi
  opcoes+=(
    "Reconfigurar tudo, fluxo completo (identificação, recursos, credenciais)"
    "Atualizar o Grafana Alloy, mantendo a configuração"
    "Validar a configuração e reiniciar os serviços"
    "Cancelar"
  )
  # O padrão é Cancelar: as outras opções mexem num servidor em produção, e
  # ENTER não deve disparar isso.
  choose_padrao "O que deseja fazer?" "${#opcoes[@]}" "${opcoes[@]}"
  rotulo="${opcoes[$((CHOOSE_RESULT-1))]}"
  SEGUIR_INSTALACAO=0
  case "$rotulo" in
    Ver*) menu_alterar ;;
    Reconfigurar*) SEGUIR_INSTALACAO=1 ;;
    Atualizar*) atualizar_somente_alloy ;;
    Validar*) validar_e_reiniciar ;;
    Cancelar) info "Nada foi alterado." ;;
  esac
  return 0
}

main_atualizar() {
  MODO_ATUALIZACAO=1
  need_root
  need_systemd
  banner
  step "Atualização automática ${NEXTEC_PACOTE_VERSAO:-sem versão de pacote}"
  carregar_estado_instalacao || exit 3
  detect_os

  if [[ "$MODO_INSTALACAO" == "somente_coleta" ]]; then
    install_coleta_complementar
    install_atualizador
    salvar_estado_instalacao somente_coleta
    ok "Coleta Complementar atualizada (modo somente coleta)."
    return 0
  fi

  install_alloy
  install_coleta_complementar
  install_atualizador
  prepare_snmp_config
  write_blackbox_config
  configure_service_env
  generate_config
  validate_and_start
  rm -f "${CONFIG_FILE}.nextec-preinstall"
  salvar_estado_instalacao completo
  ok "Atualização concluída."
}

main_somente_coleta() {
  # Para servidores cujo Alloy não foi instalado por este instalador
  # (ex.: o servidor da central, coletado pelo Alloy da stack). Instala só a
  # Coleta Complementar; o Alloy existente precisa ler os arquivos dela.
  banner
  need_root
  need_systemd
  detect_os
  detect_docker

  step "Somente Coleta Complementar"
  info "Este modo não instala nem altera o Alloy deste servidor."
  # Já instalado neste modo: as respostas atuais viram o padrão (ENTER mantém).
  local tem_estado=0
  if [[ -f "$ESTADO_INSTALACAO" ]] && grep -qx 'MODO=somente_coleta' "$ESTADO_INSTALACAO" && carregar_estado_instalacao; then
    tem_estado=1
    info "Respostas atuais carregadas: ENTER mantém cada uma."
  fi
  sn() { [[ "$tem_estado" == "1" ]] && { [[ "${1:-0}" == "1" ]] && echo s || echo n; } || echo "$2"; }
  local p_internet p_velocidade p_docker p_acessos
  p_internet="$(sn "${ENABLE_INTERNET:-0}" s)"
  p_velocidade="$(sn "${ENABLE_VELOCIDADE:-0}" s)"
  p_docker="$(sn "${ENABLE_DOCKER:-0}" s)"
  p_acessos="$(sn "${ENABLE_ACESSOS:-0}" s)"

  local raw detected
  while true; do
    raw="$(ask_required "Cliente, identificador da empresa (ex.: nextec)" "${CLIENTE:-}")"
    CLIENTE="$(normalize_slug "$raw" | tr '-' '_' | sed -E 's/_+/_/g; s/^_+|_+$//g')"
    [[ "$CLIENTE" =~ ^[a-z0-9_]+$ ]] && break
    warn "Cliente inválido: ${raw}. Use letras, números e _. Tente de novo."
  done
  detected="${HOST_LABEL:-$(normalize_slug "$(hostname -s 2>/dev/null || hostname)")}"
  HOST_LABEL="$(ask_slug "Hostname para monitoramento" "$detected" host)"
  ENABLE_INTERNET=0
  ENABLE_LINKS=0
  ENABLE_VELOCIDADE=0
  ENABLE_DOCKER=0
  ENABLE_ACESSOS=0

  ask_yes_no "Medir a internet e os links (status, DNS e IP público)?" "$p_internet" && ENABLE_INTERNET=1
  dica "Recomendado: a cada 30 min. Cada teste satura o link por alguns segundos."
  ask_yes_no "Teste de velocidade a cada 30 minutos?" "$p_velocidade" && ENABLE_VELOCIDADE=1
  if [[ "$DOCKER_DETECTED" == "1" ]]; then
    ask_yes_no "Coletar Docker (estado, consumo, health e eventos)?" "$p_docker" && ENABLE_DOCKER=1
  fi
  ask_yes_no "Registrar acessos ao servidor (logins com origem)?" "$p_acessos" && ENABLE_ACESSOS=1

  if ! coleta_enabled; then
    warn "Nenhum módulo escolhido. Nada a fazer."
    desligar_coleta_complementar
    exit 0
  fi
  perguntar_links

  install_coleta_complementar
  install_atualizador
  salvar_estado_instalacao somente_coleta

  step "Próximo passo: o Alloy deste servidor precisa ler a Coleta Complementar"
  echo "  Métricas: ${COLETA_TEXTFILE}/*.prom  (prometheus.exporter.unix com o coletor textfile)"
  echo "  Eventos:  ${COLETA_EVENTOS}  (loki.source.file + loki.process)"
  echo "  Modelo pronto: Alloy/coleta-complementar/alloy-central.alloy.example no repositório Scripts."
  echo "  Alloy em container: use os caminhos como o container os enxerga (ex.: /rootfs${COLETA_TEXTFILE})."
}

main() {
  banner
  need_root
  need_systemd
  menu_manutencao
  [[ "$SEGUIR_INSTALACAO" == "1" ]] || return 0
  RW_URL="https://${NOC_HOST}/api/v1/write"
  LOKI_URL="https://${NOC_HOST}/loki/api/v1/push"

  detect_os
  detect_docker
  detect_databases
  show_detection
  collect_inputs
  show_plan

  check_connectivity || {
    warn "Conectividade com o NOC falhou."
    ask_yes_no "Continuar mesmo assim?" n || exit 1
  }

  install_alloy
  install_coleta_complementar
  coleta_enabled || desligar_coleta_complementar
  prepare_snmp_config
  write_blackbox_config
  configure_service_env
  generate_config
  validate_and_start

  rm -f "${CONFIG_FILE}.nextec-preinstall"
  # Depois do Alloy validado: uma falha aqui não desfaz o monitoramento.
  salvar_estado_instalacao completo
  install_atualizador
  final_summary
}

case "${1:-}" in
  --somente-coleta) main_somente_coleta ;;
  --atualizar) main_atualizar ;;
  *) main "$@" ;;
esac
