#!/usr/bin/env bash
# ==============================================================================
# Nextec NOC Monitoring Installer for Linux
# Versão: 2.0.0
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

INSTALLER_VERSION="2.0.0"
DEFAULT_NOC_HOST="noc.nex.tec.br"
NOC_HOST="${DEFAULT_NOC_HOST}"
RW_URL=""
LOKI_URL=""

CONFIG_DIR="/etc/alloy"
CONFIG_FILE="${CONFIG_DIR}/config.alloy"
BACKUP_DIR="${CONFIG_DIR}/backup"
BLACKBOX_FILE="${CONFIG_DIR}/blackbox.yml"
SNMP_FILE="${CONFIG_DIR}/snmp.yml"

# O pacote oficial usa /etc/default/alloy em Debian. No fallback binário também
# adotamos o mesmo local para manter um único padrão de manutenção.
ENV_FILE="/etc/default/alloy"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/alloy.service.d"
SYSTEMD_OVERRIDE="${SYSTEMD_OVERRIDE_DIR}/10-nextec.conf"

# Cores ANSI. Se o terminal não suportar cores, o conteúdo continua legível.
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[0;37m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✔${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }
step() { echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$*${NC}"; }

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
  clear 2>/dev/null || true
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
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+|_+$//g; s/_+/_/g'
  else
    printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+|_+$//g; s/_+/_/g'
  fi
}

ask_required() {
  local prompt="$1" default="${2:-}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")" value
      value="${value:-$default}"
    else
      read -r -p "$(echo -e "${CYAN}?${NC} ${prompt}: ")" value
    fi
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "Campo obrigatório."
  done
}

ask_secret() {
  local prompt="$1" value
  while true; do
    read -r -s -p "$(echo -e "${CYAN}?${NC} ${prompt}: ")" value
    echo
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "Campo obrigatório."
  done
}

ask_yes_no() {
  local prompt="$1" default="${2:-s}" answer suffix
  [[ "$default" == "s" ]] && suffix="[S/n]" || suffix="[s/N]"
  while true; do
    read -r -p "$(echo -e "${CYAN}?${NC} ${prompt} ${suffix}: ")" answer
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

  echo -e "${CYAN}?${NC}  ${prompt}"
  for i in "${!options[@]}"; do
    printf '  %b[%d]%b %s
' "$WHITE" "$((i+1))" "$NC" "${options[$i]}"
  done

  while true; do
    read -r -p "> " choice
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
  read -r -p "?  ENTER para continuar ou D para alterar: " action

  # Qualquer coisa diferente de D mantém o destino padrão.
  [[ "${action,,}" != "d" ]] && return 0

  while true; do
    read -r -p "?  Novo destino: " input

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

  printf '%s' "$label"
  printf '%*s' "$pad" ''
  printf '%s\n' "$value"
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
    INSTALLER_VERSION="2.0.0"
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
  apt-get install -y alloy
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
  if [[ "$PKG_FAMILY" == "dnf" ]]; then dnf install -y alloy; else yum install -y alloy; fi
}

install_alloy_zypper() {
  rpm --import https://rpm.grafana.com/gpg.key
  zypper --non-interactive removerepo grafana >/dev/null 2>&1 || true
  zypper --non-interactive addrepo https://rpm.grafana.com grafana
  zypper --non-interactive --gpg-auto-import-keys refresh
  zypper --non-interactive install alloy
}

install_alloy_binary() {
  local tmpdir asset_url archive bin
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/alloy.zip"
  asset_url="https://github.com/grafana/alloy/releases/latest/download/alloy-linux-${ARCH}.zip"

  info "Usando binário oficial do Alloy como fallback."
  curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$archive"

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

install_alloy() {
  step "Instalando Grafana Alloy"
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
  tmp="$(mktemp)"
  [[ -f "$ENV_FILE" ]] && grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '%s="%s"\n' "$key" "$escaped" >> "$tmp"
  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

configure_service_env() {
  step "Configurando credenciais e segurança local"

  append_env_var "NEXTEC_RW_USERNAME" "$RW_USERNAME"
  append_env_var "NEXTEC_RW_PASSWORD" "$RW_PASSWORD"

  if [[ "$ENABLE_LOGS" == "1" ]]; then
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

  ok "Segredos armazenados em ${ENV_FILE} com permissão 0600."
}

# ------------------------------------------------------------------------------
# GERADORES DE LABELS E CONFIGURAÇÃO ALLOY
# ------------------------------------------------------------------------------
write_common_relabels() {
  local src="$1" name="$2" service="$3" type="$4" os="$5" origin="${6:-alloy}"

  # IMPORTANTE PARA MANUTENÇÃO:
  # No Alloy/River, mantenha um atributo por linha dentro de cada bloco rule.
  cat <<EOF

discovery.relabel "${name}" {
  targets = ${src}

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

    if [[ "$ENABLE_DOCKER" == "1" ]]; then
      cat <<'EOF'

// -----------------------------------------------------------------------------
// DOCKER / CONTAINERS
// cAdvisor é embutido no Alloy. Não existe container cAdvisor separado.
// O usuário alloy precisa conseguir acessar o socket Docker.
// -----------------------------------------------------------------------------
prometheus.exporter.cadvisor "docker" {
  docker_host            = "unix:///var/run/docker.sock"
  storage_duration       = "5m"
  store_container_labels = false
}
EOF
      write_common_relabels 'prometheus.exporter.cadvisor.docker.targets' 'docker_labels' 'docker' 'container' 'linux' 'cadvisor'
      cat <<'EOF'

prometheus.scrape "docker" {
  targets         = discovery.relabel.docker_labels.output
  forward_to      = [prometheus.remote_write.nextec.receiver]
  scrape_interval = "30s"
  scrape_timeout  = "15s"
}
EOF
    fi

    generate_database_config

    if [[ "$ENABLE_LOGS" == "1" ]]; then
      cat <<EOF

// -----------------------------------------------------------------------------
// LOGS DO SISTEMA, OPCIONAL
// Não fazem parte do perfil mínimo de métricas do servidor.
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
  local -a selected=(0 0 0 0 0 0)
  local -a disabled=(0 0 0 0 0 0)
  local -a labels=(
    "Docker / containers"
    "Logs do sistema, warning/error/critical"
    "Banco de dados"
    "SNMP, firewalls/switches/UPS/APs"
    "Conectividade e disponibilidade (Blackbox), ping/HTTP/TCP"
    "Exporters adicionais"
  )
  local -a details=("" "" "" "" "" "")

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
      read -r -p "> " input
      [[ -z "${input//[[:space:]]/}" ]] && break

      # O script globalmente remove espaço do IFS. Aqui definimos IFS localmente
      # para que "2 6" seja interpretado como duas escolhas diferentes.
      local -a tokens=()
      IFS=' ,' read -r -a tokens <<< "$input"

      for token in "${tokens[@]}"; do
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^[1-6]$ ]]; then
          local idx=$((token-1))
          if [[ "${disabled[$idx]}" == "1" ]]; then
            warn "${labels[$idx]} não está disponível neste host."
          else
            [[ "${selected[$idx]}" == "1" ]] && selected[$idx]=0 || selected[$idx]=1
          fi
        else
          warn "Opção inválida: ${token}. Use números de 1 a 6."
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

  raw="$(ask_required "Cliente (ex.: advocacia_martins)")"
  CLIENTE="$(normalize_slug "$raw")"
  [[ "$CLIENTE" =~ ^[a-z0-9_]+$ ]] || { err "Cliente inválido: ${CLIENTE}"; exit 1; }

  detected="$(normalize_slug "$(hostname -s 2>/dev/null || hostname)")"
  HOST_LABEL="$(normalize_slug "$(ask_required "Hostname para monitoramento" "$detected")")"

  choose "Ambiente" "producao" "homologacao" "desenvolvimento" "backup" "teste"
  choice="$CHOOSE_RESULT"
  case "$choice" in
    1) AMBIENTE=producao;; 2) AMBIENTE=homologacao;; 3) AMBIENTE=desenvolvimento;;
    4) AMBIENTE=backup;; 5) AMBIENTE=teste;;
  esac

  LOCAL="$(normalize_slug "$(ask_required "Local" "matriz")")"

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
      bn="$(normalize_slug "$(ask_required "Nome do alvo (ex.: fw_matriz)")")"
      ba="$(ask_required "IP, FQDN ou URL")"

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
      sn="$(normalize_slug "$(ask_required "Nome do equipamento")")"
      sa="$(ask_required "IP/FQDN SNMP")"
      sm="$(ask_required "Módulo SNMP" "system,if_mib")"
      sau="$(ask_required "Auth SNMP" "public_v2")"

      choose "Tipo" "firewall" "switch" "storage" "ap" "ups"
      choice="$CHOOSE_RESULT"
      case "$choice" in 1) st=firewall;; 2) st=switch;; 3) st=storage;; 4) st=ap;; 5) st=storage;; esac

      sos="$(normalize_slug "$(ask_required "Sistema/fabricante" "network")")"
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
        ct="$(ask_required "Target host:porta" "$EXPORTER_DEFAULT_TARGET")"
        cs="$(normalize_slug "$(ask_required "Label servico" "$EXPORTER_SERVICE_LABEL")")"
      else
        cn="$(normalize_slug "$(ask_required "Nome do exporter")")"
        ct="$(ask_required "Target host:porta")"
        cs="$(normalize_slug "$(ask_required "Label servico" "$cn")")"
      fi

      CUSTOM_EXPORTERS+=("${cn}|${ct}|${cs}")
      ok "Integração adicionada: ${cn} -> ${ct} (servico=${cs})"

      ask_yes_no "Adicionar outro exporter?" n || break
    done
  fi

  step "Credenciais do NOC"
  info "Use a credencial cadastrada no NOC para autorizar o envio deste cliente."
  RW_USERNAME="$(ask_required "Usuário do remote_write")"
  RW_PASSWORD="$(ask_secret "Senha do remote_write")"

  if [[ "$ENABLE_LOGS" == "1" ]]; then
    echo
    info "Credencial do Loki:"
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

  echo
  ask_yes_no "Confirmar instalação e configuração?" s || { warn "Cancelado."; exit 0; }
}

final_summary() {
  echo
  echo -e "${GREEN}${BOLD}============================================================${NC}"
  echo -e "${GREEN}${BOLD}              INSTALAÇÃO CONCLUÍDA${NC}"
  echo -e "${GREEN}${BOLD}============================================================${NC}"
  echo -e "Cliente: ${BOLD}${CLIENTE}${NC}   Host: ${BOLD}${HOST_LABEL}${NC}   Alloy: ${GREEN}ativo${NC}"
  echo "Configuração: ${CONFIG_FILE}"
  echo "Segredos: ${ENV_FILE}"
  echo "UI local: http://127.0.0.1:12345"
  echo "Métricas: ${RW_URL}"
  [[ "$ENABLE_LOGS" == 1 ]] && echo "Logs: ${LOKI_URL}"
  [[ "$ENABLE_DOCKER" == 1 ]] && echo "Docker: habilitado via prometheus.exporter.cadvisor"
  (( ${#DATABASE_TARGETS[@]} > 0 )) && echo "Banco(s): ${#DATABASE_TARGETS[@]} integração(ões)/detecção(ões) registrada(s)"

  echo
  echo "Diagnóstico para manutenção:"
  echo "  systemctl status alloy"
  echo "  journalctl -u alloy -f"
  echo "  alloy validate ${CONFIG_FILE}"
  echo "  curl http://127.0.0.1:12345/-/ready"

  warn "Valide no NOC a chegada de cliente=\"${CLIENTE}\" e host=\"${HOST_LABEL}\"."
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
  prepare_snmp_config
  write_blackbox_config
  configure_service_env
  generate_config
  validate_and_start

  rm -f "${CONFIG_FILE}.nextec-preinstall"
  final_summary
}

main "$@"
