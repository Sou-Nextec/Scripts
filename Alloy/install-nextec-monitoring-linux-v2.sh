#!/usr/bin/env bash
# ==============================================================================
# Nextec NOC Monitoring Installer for Linux
# Versão: 2.4.0 (atualizador automático: respostas gravadas e modo --atualizar)
#
# USO
# ---
#   sudo bash install-nextec-monitoring-linux-v2.sh                   instalação completa
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

INSTALLER_VERSION="2.4.0"
DEFAULT_NOC_HOST="noc.nex.tec.br"
NOC_HOST="${DEFAULT_NOC_HOST}"
RW_URL=""
LOKI_URL=""

CONFIG_DIR="/etc/alloy"
CONFIG_FILE="${CONFIG_DIR}/config.alloy"
BACKUP_DIR="${CONFIG_DIR}/backup"
BLACKBOX_FILE="${CONFIG_DIR}/blackbox.yml"
SNMP_FILE="${CONFIG_DIR}/snmp.yml"

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
  local texto="$1" padrao="${2:-}" dica="${3:-}" saida
  saida="${CYAN}?${NC} ${BOLD}${texto}${NC}"
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
  echo -e "${NC}${BOLD}NOC Monitoring Installer, Linux${NC}"
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
      read -r -p "$(pergunta "$prompt" "$default")" value || entrada_encerrada
      value="${value:-$default}"
    else
      read -r -p "$(pergunta "$prompt")" value || entrada_encerrada
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


# ------------------------------------------------------------------------------
# DESTINO DO MONITORAMENTO E FORMATAÇÃO DO RESUMO
# ------------------------------------------------------------------------------

configure_noc_destination() {
  local action input

  # O NOC da Nextec é o destino padrão e não exige confirmação.
  NOC_HOST="${DEFAULT_NOC_HOST}"
  RW_URL="https://${NOC_HOST}/api/v1/write"
  LOKI_URL="https://${NOC_HOST}/loki/api/v1/push"

  echo
  echo -e "${BOLD}Destino:${NC} ${CYAN}${NOC_HOST}${NC}"
  read -r -p "$(pergunta "ENTER para continuar ou D para alterar")" action

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

collect_links_inputs() {
  step "Links de internet"
  info "Cada link precisa de pelo menos um destino que saia SOMENTE por ele."
  info "Use uma rota por link no firewall (ex.: 8.8.8.8 pelo link 1, 1.1.1.1 pelo link 2),"
  info "ou um IP de origem deste servidor que saia pela WAN do link."
  local nome papel choice operadora tipo suporte ip_publico gateway alvos origem firewall interface
  while true; do
    while true; do
      nome="$(ini_value "$(ask_required "Nome do link (ex.: Cyberline Fibra)")")"
      # Nome repetido vira seção [link:...] duplicada e a Coleta não inicia.
      nome_existe "$nome" "${LINKS[@]}" || break
      warn "Já existe um link chamado '${nome}'. Use outro nome."
    done
    choose "Papel do link" "primario" "failover" "sdwan"
    choice="$CHOOSE_RESULT"
    case "$choice" in 1) papel=primario;; 2) papel=failover;; 3) papel=sdwan;; esac
    operadora="$(ini_value "$(ask_required "Operadora" "$nome")")"
    tipo="$(ini_value "$(ask_required "Tipo (fibra, radio, 4g, satelite, dedicado)" "fibra")")"
    read -r -p "$(pergunta "Telefone/protocolo de suporte da operadora" "" "ENTER para pular")" suporte || entrada_encerrada
    ip_publico="$(ask_address "IP público fixo do link (dinâmico: deixe vazio)" "" ip 1)"
    gateway="$(ask_address "Gateway da operadora para testar" "" host 1)"
    alvos="$(ask_address "Destinos que saem por este link, separados por vírgula" "8.8.8.8" host 0 1)"
    while true; do
      origem="$(ask_address "IP de origem neste servidor para este link" "" ip 1)"
      [[ -z "$origem" ]] && break
      ip -o addr show 2>/dev/null | grep -qw "inet ${origem}" && break
      warn "O IP ${origem} não existe neste servidor. Informe um IP local ou deixe vazio."
    done
    firewall=""
    read -r -p "$(pergunta "Nome do firewall no NOC, para tráfego por SNMP" "" "ENTER para pular")" firewall || entrada_encerrada
    firewall="$(trim "$firewall")"
    [[ -n "$firewall" ]] && firewall="$(normalize_slug "$firewall")"
    interface=""
    while [[ -n "$firewall" ]]; do
      read -r -p "$(pergunta "Interface WAN do link no firewall" "" "ex.: igb1")" interface || entrada_encerrada
      interface="$(trim "$interface")"
      [[ "$interface" =~ $RE_INTERFACE ]] && break
      warn "Interface inválida. Use o nome como aparece no firewall, ex.: igb1, ether1, wan1."
    done
    LINKS+=("$(ini_value "$nome")|${papel}|$(ini_value "$operadora")|$(ini_value "$tipo")|$(ini_value "$suporte")|$(ini_value "$ip_publico")|$(ini_value "$gateway")|$(ini_value "$alvos")|$(ini_value "$origem")|$(ini_value "$firewall")|$(ini_value "$interface")")
    ok "Link adicionado: ${nome} (${papel})"
    ask_yes_no "Adicionar outro link?" n || break
  done
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
    local item nome papel operadora tipo suporte ip_publico gateway alvos origem firewall interface
    for item in "${LINKS[@]}"; do
      IFS='|' read -r nome papel operadora tipo suporte ip_publico gateway alvos origem firewall interface <<<"$item"
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
// O arquivo nextec-snmp.yml deve ser homologado para os equipamentos escolhidos.
// -----------------------------------------------------------------------------
prometheus.exporter.snmp "network" {
  config_file = "${SNMP_FILE}"
EOF
      local item sn_name sn_addr sn_module sn_auth sn_type sn_os
      for item in "${SNMP_TARGETS[@]}"; do
        IFS='|' read -r sn_name sn_addr sn_module sn_auth sn_type sn_os <<<"$item"
        cat <<EOF
  target "$(alloy_escape "$sn_name")" {
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

prometheus.scrape "snmp" {
  targets         = prometheus.exporter.snmp.network.targets
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "60s"
  scrape_timeout  = "30s"
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

  tcp_connect:
    prober: tcp
    timeout: 5s
EOF
  chmod 0640 "$BLACKBOX_FILE"
  chown root:alloy "$BLACKBOX_FILE" 2>/dev/null || true
}

prepare_snmp_config() {
  [[ "$ENABLE_SNMP" == "1" ]] || return 0
  if [[ "$MODO_ATUALIZACAO" == "1" ]]; then
    [[ -f "$SNMP_FILE" ]] || { err "SNMP ligado, mas ${SNMP_FILE} não existe."; exit 1; }
    ok "snmp.yml mantido em ${SNMP_FILE}."
    return 0
  fi

  step "Preparando configuração SNMP"
  warn "SNMP exige um snmp.yml homologado com módulos e autenticações compatíveis."

  local src
  while true; do
    src="$(ask_required "Caminho do snmp.yml homologado pela Nextec")"
    [[ -f "$src" ]] && break
    warn "Arquivo não encontrado: $src"
  done

  install -m 0640 -o root -g alloy "$src" "$SNMP_FILE"
  ok "snmp.yml instalado em ${SNMP_FILE}."
}

# ------------------------------------------------------------------------------
# VALIDAÇÃO E START
# ------------------------------------------------------------------------------
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
  local -a selected=(0 0 0 0 0 0 1 0 1 1)
  local -a disabled=(0 0 0 0 0 0 0 0 0 0)
  local -a labels=(
    "Docker / containers"
    "Logs do sistema, warning/error/critical"
    "Banco de dados"
    "SNMP, firewalls/switches/UPS/APs"
    "Conectividade e disponibilidade (Blackbox), ping/HTTP/TCP"
    "Exporters adicionais"
    "Internet e DNS (saída padrão, IP público, diagnóstico)"
    "Links de internet (mais de um link neste local)"
    "Teste de velocidade (Speedtest)"
    "Acessos ao servidor (logins com origem, alerta de acesso privilegiado)"
  )
  local -a details=("" "" "" "" "" "" "recomendado" "" "recomendado" "recomendado")

  if [[ "$DOCKER_DETECTED" == "1" && "${DOCKER_DAEMON_AVAILABLE:-0}" == "1" ]]; then
    selected[0]=1
    details[0]="detectado"
  elif [[ "$DOCKER_DETECTED" == "1" ]]; then
    disabled[0]=1
    details[0]="detectado, daemon indisponível"
  else
    disabled[0]=1
    details[0]="não detectado"
  fi

  if [[ "$db_available" == "1" ]]; then
    selected[2]=1
    details[2]="${#DETECTED_DATABASES[@]} detectado(s): ${DETECTED_DATABASES[*]}"
  else
    disabled[2]=1
    details[2]="nenhum PostgreSQL, MySQL/MariaDB ou SQL Server detectado"
  fi

  # --------------------------------------------------------------------------
  # FALLBACK SEM TTY
  # --------------------------------------------------------------------------
  # Quando stdin/stdout não são terminais reais, setas e leitura por tecla não
  # são confiáveis. Nesse cenário, usa seleção numérica tradicional.
  if [[ ! -t 0 || ! -t 1 ]]; then
    local input token
    while true; do
      echo
      echo -e "${BOLD}Recursos adicionais${NC}"
      echo -e "${DIM}Digite números separados por espaço para marcar/desmarcar. ENTER confirma.${NC}"
      echo
      if [[ "${MONITOR_SERVER:-0}" == "1" ]]; then
        echo -e "  ${GREEN}[✓]${NC} Servidor: CPU, memória, discos, rede, load e uptime ${DIM}(sempre ativo, não precisa marcar)${NC}"
        echo
      fi

      local i
      for i in "${!labels[@]}"; do
        local mark=" "
        [[ "${selected[$i]}" == "1" ]] && mark="✓"
        if [[ "${disabled[$i]}" == "1" ]]; then
          printf '  [%s] %d. %s %b(%s)%b\n' "$mark" "$((i+1))" "${labels[$i]}" "$DIM" "${details[$i]}" "$NC"
        elif [[ -n "${details[$i]}" ]]; then
          printf '  [%s] %d. %s %b(%s)%b\n' "$mark" "$((i+1))" "${labels[$i]}" "$DIM" "${details[$i]}" "$NC"
        else
          printf '  [%s] %d. %s\n' "$mark" "$((i+1))" "${labels[$i]}"
        fi
      done

      echo
      read -r -p "$(echo -e "${CYAN}›${NC} ")" input || entrada_encerrada
      [[ -z "${input//[[:space:]]/}" ]] && break

      # O script globalmente remove espaço do IFS. Aqui definimos IFS localmente
      # para que "2 6" seja interpretado como duas escolhas diferentes.
      local -a tokens=()
      IFS=' ,' read -r -a tokens <<< "$input"

      for token in "${tokens[@]}"; do
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#labels[@]} )); then
          local idx=$((token-1))
          if [[ "${disabled[$idx]}" == "1" ]]; then
            warn "${labels[$idx]} não está disponível neste host."
          else
            [[ "${selected[$idx]}" == "1" ]] && selected[$idx]=0 || selected[$idx]=1
          fi
        else
          warn "Opção inválida: ${token}. Use números de 1 a ${#labels[@]}."
        fi
      done
    done
  else
    # ------------------------------------------------------------------------
    # TUI INTERATIVO
    # ------------------------------------------------------------------------
    # Teclas:
    #   ↑ / ↓  navega
    #   Espaço marca/desmarca
    #   Enter  confirma
    #
    # Não depende de whiptail/dialog. Usa somente sequências ANSI e read Bash.
    local cursor=0
    local key rest message=""
    local count="${#labels[@]}"

    # Garante que o primeiro cursor fique em item utilizável quando possível.
    while [[ "$cursor" -lt "$count" && "${disabled[$cursor]}" == "1" ]]; do
      cursor=$((cursor+1))
    done
    [[ "$cursor" -ge "$count" ]] && cursor=0

    # Restaura o cursor mesmo se a função sair de forma antecipada.
    printf '\033[?25l'

    while true; do
      clear 2>/dev/null || printf '\033[2J\033[H'
      banner

      echo -e "${BOLD}Recursos adicionais${NC}"
      echo -e "${DIM}Use ↑/↓ para navegar, ESPAÇO para marcar/desmarcar e ENTER para continuar.${NC}"
      echo
      if [[ "${MONITOR_SERVER:-0}" == "1" ]]; then
        echo -e "  ${GREEN}[✓]${NC} Servidor: CPU, memória, discos, rede, load e uptime ${DIM}(sempre ativo, não precisa marcar)${NC}"
        echo
      fi

      local i mark prefix suffix
      for i in "${!labels[@]}"; do
        mark=" "
        [[ "${selected[$i]}" == "1" ]] && mark="✓"

        prefix="  "
        [[ "$i" -eq "$cursor" ]] && prefix="❯ "

        suffix=""
        [[ -n "${details[$i]}" ]] && suffix=" (${details[$i]})"

        if [[ "${disabled[$i]}" == "1" ]]; then
          if [[ "$i" -eq "$cursor" ]]; then
            printf '%b%s[%s] %s%s%b\n' "$CYAN" "$prefix" "$mark" "${labels[$i]}" "$suffix" "$NC"
          else
            printf '%b%s[%s] %s%s%b\n' "$DIM" "$prefix" "$mark" "${labels[$i]}" "$suffix" "$NC"
          fi
        elif [[ "$i" -eq "$cursor" ]]; then
          printf '%b%b%s[%s] %s%s%b\n' "$CYAN" "$BOLD" "$prefix" "$mark" "${labels[$i]}" "$suffix" "$NC"
        else
          printf '%s[%s] %s%s\n' "$prefix" "$mark" "${labels[$i]}" "$suffix"
        fi
      done

      echo
      [[ -n "$message" ]] && echo -e "${YELLOW}${message}${NC}"
      echo -e "${DIM}Itens detectados podem iniciar pré-marcados.${NC}"

      IFS= read -rsn1 key || true

      case "$key" in
        $'\x1b')
          # Sequência típica das setas: ESC [ A/B
          rest=""
          IFS= read -rsn2 -t 0.15 rest || true
          case "$rest" in
            "[A")
              # Sobe, pulando itens bloqueados quando houver opção disponível.
              local attempts=0
              while (( attempts < count )); do
                cursor=$(( (cursor - 1 + count) % count ))
                [[ "${disabled[$cursor]}" != "1" ]] && break
                attempts=$((attempts+1))
              done
              ;;
            "[B")
              # Desce, pulando itens bloqueados quando houver opção disponível.
              local attempts=0
              while (( attempts < count )); do
                cursor=$(( (cursor + 1) % count ))
                [[ "${disabled[$cursor]}" != "1" ]] && break
                attempts=$((attempts+1))
              done
              ;;
          esac
          message=""
          ;;
        " ")
          if [[ "${disabled[$cursor]}" == "1" ]]; then
            message="${labels[$cursor]} não está disponível neste host."
          else
            [[ "${selected[$cursor]}" == "1" ]] && selected[$cursor]=0 || selected[$cursor]=1
            message=""
          fi
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
  ENABLE_LINKS="${selected[7]}"
  ENABLE_VELOCIDADE="${selected[8]}"
  ENABLE_ACESSOS="${selected[9]}"
  # Links dependem do módulo de internet (mesmo laço de medição).
  [[ "$ENABLE_LINKS" == "1" ]] && ENABLE_INTERNET=1

  if [[ "$ENABLE_SNMP" == "1" || "$ENABLE_BLACKBOX" == "1" ]]; then
    COLLECTOR=1
  fi

  echo -e "${BOLD}Recursos selecionados:${NC}"
  local i
  for i in "${!labels[@]}"; do
    if [[ "${selected[$i]}" == "1" ]]; then
      echo "  ✓ ${labels[$i]}"
    fi
  done
  echo

  return 0
}

# ------------------------------------------------------------------------------
# CATÁLOGO DE EXPORTERS PROMETHEUS EXTERNOS
# ------------------------------------------------------------------------------
# PostgreSQL e MySQL/MariaDB possuem fluxo próprio no instalador e são tratados
# na etapa de detecção de bancos. Este catálogo serve para endpoints Prometheus
# adicionais que JÁ ESTEJAM ativos.
select_specialized_exporter() {
  local choice

  echo
  echo -e "${BOLD}Exporters/integrações Prometheus que o instalador sabe cadastrar:${NC}"
  echo -e "${DIM}PostgreSQL e MySQL/MariaDB são tratados automaticamente na etapa de bancos.${NC}"
  echo

  choose "Selecione o exporter/integração" \
    "Redis Exporter              (padrão :9121)" \
    "Nginx Prometheus Exporter   (padrão :9113)" \
    "Apache Exporter             (padrão :9117)" \
    "RabbitMQ Prometheus         (padrão :15692)" \
    "Elasticsearch Exporter      (padrão :9114)" \
    "MongoDB Exporter            (padrão :9216)" \
    "NVIDIA DCGM Exporter        (padrão :9400)" \
    "Outro endpoint Prometheus"

  choice="$CHOOSE_RESULT"
  case "$choice" in
    1) EXPORTER_NAME="redis_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9121"; EXPORTER_SERVICE_LABEL="redis" ;;
    2) EXPORTER_NAME="nginx_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9113"; EXPORTER_SERVICE_LABEL="nginx" ;;
    3) EXPORTER_NAME="apache_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9117"; EXPORTER_SERVICE_LABEL="apache" ;;
    4) EXPORTER_NAME="rabbitmq_prometheus"; EXPORTER_DEFAULT_TARGET="127.0.0.1:15692"; EXPORTER_SERVICE_LABEL="rabbitmq" ;;
    5) EXPORTER_NAME="elasticsearch_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9114"; EXPORTER_SERVICE_LABEL="elasticsearch" ;;
    6) EXPORTER_NAME="mongodb_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9216"; EXPORTER_SERVICE_LABEL="mongodb" ;;
    7) EXPORTER_NAME="nvidia_dcgm_exporter"; EXPORTER_DEFAULT_TARGET="127.0.0.1:9400"; EXPORTER_SERVICE_LABEL="gpu" ;;
    8) EXPORTER_NAME=""; EXPORTER_DEFAULT_TARGET=""; EXPORTER_SERVICE_LABEL="" ;;
  esac
}

collect_inputs() {
  configure_noc_destination

  step "Identificação"
  local raw detected choice

  while true; do
    raw="$(ask_required "Cliente, identificador da empresa e não do servidor (ex.: advocacia_martins)")"
    # O rótulo cliente só aceita minúsculas, números e _: hífen e espaço viram _.
    CLIENTE="$(normalize_slug "$raw" | tr '-' '_' | sed -E 's/_+/_/g; s/^_+|_+$//g')"
    [[ "$CLIENTE" =~ ^[a-z0-9_]+$ ]] && break
    warn "Cliente inválido: ${raw}. Use letras, números e _. Tente de novo."
  done
  [[ "$CLIENTE" != "$raw" ]] && info "Cliente será registrado como: ${CLIENTE}"

  detected="$(normalize_slug "$(hostname -s 2>/dev/null || hostname)")"
  HOST_LABEL="$(ask_slug "Hostname para monitoramento" "$detected" host)"

  choose "Ambiente" "producao" "homologacao" "desenvolvimento" "backup" "teste"
  choice="$CHOOSE_RESULT"
  case "$choice" in
    1) AMBIENTE=producao;; 2) AMBIENTE=homologacao;; 3) AMBIENTE=desenvolvimento;;
    4) AMBIENTE=backup;; 5) AMBIENTE=teste;;
  esac

  LOCAL="$(ask_slug "Local" "matriz" label)"

  choose "Criticidade" "critico" "alto" "medio" "baixo"
  choice="$CHOOSE_RESULT"
  case "$choice" in
    1) CRITICIDADE=critico;; 2) CRITICIDADE=alto;; 3) CRITICIDADE=medio;; 4) CRITICIDADE=baixo;;
  esac

  step "Função deste Alloy"
  choose "Selecione o modo" "Servidor monitorado" "Collector de rede" "Servidor + Collector de rede"
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

  if [[ "$ENABLE_BLACKBOX" == "1" ]]; then
    step "Conectividade e disponibilidade (Blackbox)"
    while true; do
      local bn ba bm bt
      while true; do
        bn="$(ask_slug "Nome do alvo (ex.: fw_matriz)" "" host)"
        nome_existe "$bn" "${BLACKBOX_TARGETS[@]}" || break
        warn "Já existe um alvo chamado '${bn}'. Use outro nome."
      done
      ba="$(ask_address "IP, FQDN ou URL" "" destino)"

      choose "Tipo de teste" "ICMP/Ping" "HTTP/HTTPS 2xx" "TCP connect"
      choice="$CHOOSE_RESULT"
      case "$choice" in 1) bm=icmp_ipv4;; 2) bm=http_2xx;; 3) bm=tcp_connect;; esac

      choose "Tipo do ativo" "firewall" "switch" "link" "aplicacao" "storage"
      choice="$CHOOSE_RESULT"
      case "$choice" in 1) bt=firewall;; 2) bt=switch;; 3) bt=link;; 4) bt=aplicacao;; 5) bt=storage;; esac

      BLACKBOX_TARGETS+=("${bn}|${ba}|${bm}|${bt}")
      ask_yes_no "Adicionar outro alvo de conectividade/disponibilidade?" n || break
    done
  fi

  if [[ "$ENABLE_SNMP" == "1" ]]; then
    step "Targets SNMP"
    info "Nesta versão, módulo e auth precisam existir no snmp.yml homologado."
    info "O catálogo automático por fabricante, FortiGate, SonicWall, pfSense, MikroTik etc., será integrado depois."

    while true; do
      local sn sa sm sau st sos
      while true; do
        sn="$(ask_slug "Nome do equipamento" "" host)"
        nome_existe "$sn" "${SNMP_TARGETS[@]}" || break
        warn "Já existe um equipamento chamado '${sn}'. Use outro nome."
      done
      sa="$(ask_address "IP/FQDN SNMP" "" host)"
      sm="$(ask_pattern "Módulo SNMP" "system,if_mib" '^[A-Za-z0-9_,-]+$' "nomes de módulo do snmp.yml separados por vírgula, sem espaço")"
      sau="$(ask_pattern "Auth SNMP" "public_v2" '^[A-Za-z0-9_-]+$' "nome da auth do snmp.yml")"

      choose "Tipo" "firewall" "switch" "storage" "ap" "ups"
      choice="$CHOOSE_RESULT"
      case "$choice" in 1) st=firewall;; 2) st=switch;; 3) st=storage;; 4) st=ap;; 5) st=storage;; esac

      sos="$(ask_slug "Sistema/fabricante" "network" label)"
      SNMP_TARGETS+=("${sn}|${sa}|${sm}|${sau}|${st}|${sos}")
      ask_yes_no "Adicionar outro equipamento SNMP?" n || break
    done
  fi

  if [[ "$ENABLE_EXPORTERS" == "1" ]]; then
    echo
    echo -e "${BOLD}Exporters adicionais${NC}"
    echo -e "${DIM}Use somente para exporter/endpoint Prometheus que já esteja ativo.${NC}"

    while true; do
      local cn ct cs
      select_specialized_exporter

      if [[ -n "$EXPORTER_NAME" ]]; then
        cn="$EXPORTER_NAME"
        ct="$(ask_address "Target host:porta" "$EXPORTER_DEFAULT_TARGET" hostport)"
        cs="$(ask_slug "Label servico" "$EXPORTER_SERVICE_LABEL" label)"
      else
        cn="$(ask_slug "Nome do exporter" "" label)"
        ct="$(ask_address "Target host:porta" "" hostport)"
        cs="$(ask_slug "Label servico" "$cn" label)"
      fi

      CUSTOM_EXPORTERS+=("${cn}|${ct}|${cs}")
      ok "Integração adicionada: ${cn} -> ${ct} (servico=${cs})"

      ask_yes_no "Adicionar outro exporter?" n || break
    done
  fi

  if [[ "$ENABLE_LINKS" == "1" ]]; then
    collect_links_inputs
  fi

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

show_plan() {
  step "Resumo antes da instalação"

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
  ask_yes_no "Confirmar instalação e configuração?" s || { warn "Cancelado."; exit 0; }
}

final_summary() {
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
  echo -e "${GREEN}${BOLD}  ║               ✔  INSTALAÇÃO CONCLUÍDA                ║${NC}"
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
    campo "Atualizador" "ligado, todo dia de madrugada" "$GREEN"
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
  # Madrugada, com atraso aleatório de até 4h por servidor (01h às 05h), para
  # a frota não atualizar toda no mesmo minuto. Persistent recupera execução
  # perdida com a máquina desligada.
  cat > "$ATUALIZADOR_TIMER" <<'EOF'
[Unit]
Description=Atualizador automático do monitoramento Nextec (diário, de madrugada)

[Timer]
OnCalendar=*-*-* 01:00:00
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
  local raw detected
  while true; do
    raw="$(ask_required "Cliente, identificador da empresa (ex.: nextec)")"
    CLIENTE="$(normalize_slug "$raw" | tr '-' '_' | sed -E 's/_+/_/g; s/^_+|_+$//g')"
    [[ "$CLIENTE" =~ ^[a-z0-9_]+$ ]] && break
    warn "Cliente inválido: ${raw}. Use letras, números e _. Tente de novo."
  done
  detected="$(normalize_slug "$(hostname -s 2>/dev/null || hostname)")"
  HOST_LABEL="$(ask_slug "Hostname para monitoramento" "$detected" host)"
  ENABLE_INTERNET=0
  ENABLE_LINKS=0
  ENABLE_VELOCIDADE=0
  ENABLE_DOCKER=0
  ENABLE_ACESSOS=0
  LINKS=()

  ask_yes_no "Medir a internet (status, DNS e IP público)?" s && ENABLE_INTERNET=1
  ask_yes_no "Cadastrar links de internet (local com mais de um link)?" n && { ENABLE_LINKS=1; ENABLE_INTERNET=1; }
  ask_yes_no "Teste de velocidade a cada 30 minutos?" s && ENABLE_VELOCIDADE=1
  if [[ "$DOCKER_DETECTED" == "1" ]]; then
    ask_yes_no "Coletar Docker (estado, consumo, health e eventos)?" s && ENABLE_DOCKER=1
  fi
  ask_yes_no "Registrar acessos ao servidor (logins com origem)?" s && ENABLE_ACESSOS=1

  if ! coleta_enabled; then
    warn "Nenhum módulo escolhido. Nada a fazer."
    exit 0
  fi
  [[ "$ENABLE_LINKS" == "1" ]] && collect_links_inputs

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
