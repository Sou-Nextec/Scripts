#!/usr/bin/env bash
# ==============================================================================
# Testes do instalador Linux: bloqueios de entrada do firewall (ENABLE_FIREWALL).
#
# Rodar da raiz do repositório Scripts (não precisa de root nem de systemd):
#   bash Alloy/testes/instalador-linux-firewall.testes.sh
#
# Cada cenário roda num subshell que carrega o instalador com "source", troca
# os caminhos do sistema por uma pasta temporária e substitui por funções o que
# mexe no servidor (pacotes, systemctl, Alloy) e os comandos do firewall.
# Para conferir o bloco no Alloy de verdade, ALLOY_BIN aponta para o binário:
#   ALLOY_BIN=/usr/bin/alloy bash Alloy/testes/instalador-linux-firewall.testes.sh
# ==============================================================================

# As variáveis abaixo são lidas pelo instalador carregado com "source".
# shellcheck disable=SC2034
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALADOR="${AQUI}/../install-nextec-monitoring-linux-v2.sh"
COLETA="${AQUI}/../coleta-complementar/coleta-complementar.py"
BASE="$(mktemp -d -t instalador-firewall.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

VERSAO_ESPERADA="$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$INSTALADOR")"

PASSOU=0
FALHOU=0

conferir() {
  local descricao="$1" obtido="$2" esperado="$3"
  if [[ "$obtido" == "$esperado" ]]; then
    PASSOU=$((PASSOU + 1))
    echo "  ok    ${descricao}"
  else
    FALHOU=$((FALHOU + 1))
    echo "  FALHA ${descricao}: obtido '${obtido}', esperado '${esperado}'"
  fi
}

conferir_contem() {
  local descricao="$1" arquivo="$2" trecho="$3"
  if [[ -f "$arquivo" ]] && grep -qF -- "$trecho" "$arquivo"; then
    conferir "$descricao" "sim" "sim"
  else
    conferir "$descricao" "não" "sim"
  fi
}

conferir_nao_contem() {
  local descricao="$1" arquivo="$2" trecho="$3"
  if [[ -f "$arquivo" ]] && grep -qF -- "$trecho" "$arquivo"; then
    conferir "$descricao" "sim" "não"
  else
    conferir "$descricao" "não" "não"
  fi
}

# Respostas gravadas por um instalador anterior (2.16.0), sem ENABLE_FIREWALL.
conf_antigo() {
  cat <<'EOF'
# Respostas da instalação Nextec (2026-11-10T13:00:00Z).
# Lido pelo instalador em --atualizar. Sem senha: credenciais ficam em /etc/default/alloy.
FORMATO=1
INSTALADOR_VERSAO=2.16.0
MODO=completo
NOC_HOST=noc.nex.tec.br
CLIENTE=nextec
HOST_LABEL=nxt-srv-app03
AMBIENTE=producao
LOCAL=contabo
CRITICIDADE=alto
MONITOR_SERVER=1
COLLECTOR=0
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
BANCOS_SQLITE=
ENABLE_VIRT=0
ENABLE_DISCOS=0
EOF
}

preparar_cenario() {
  local dir="${BASE}/$1"
  mkdir -p "${dir}/etc/nextec" "${dir}/etc/coleta-complementar" "${dir}/etc/systemd/system" "${dir}/etc/alloy" "${dir}/log"
  conf_antigo > "${dir}/etc/nextec/instalacao.conf"
  echo "$dir"
}

# firewall_falso TIPO: substitui os comandos do firewall por funções. Os
# quatro existem sempre, com saída de firewall desligado, para o resultado não
# depender do que está instalado na máquina que roda o teste.
#   nenhum | ufw_log | ufw_sem_log | firewalld_sem_log | nft_log | iptables_sem_log | docker_so
#   (docker_so: só as regras de encaminhamento do Docker, em iptables e nft)
firewall_falso() {
  local tipo="$1"
  ufw() { printf 'Status: inactive\n'; }
  firewall-cmd() { echo "not running"; return 252; }
  nft() { :; }
  iptables-save() { :; }
  case "$tipo" in
    ufw_log)
      ufw() { printf 'Status: active\nLogging: on (low)\nDefault: deny (incoming)\n'; } ;;
    ufw_sem_log)
      ufw() { printf 'Status: active\nLogging: off\n'; } ;;
    firewalld_sem_log)
      firewall-cmd() { case "$1" in --state) echo running ;; --get-log-denied) echo off ;; esac; } ;;
    nft_log)
      nft() { printf 'table inet filter {\n  chain input {\n    type filter hook input priority 0; policy drop;\n    log prefix "nft drop: " drop\n  }\n}\n'; } ;;
    iptables_sem_log)
      iptables-save() { printf '*filter\n:INPUT ACCEPT [0:0]\n-A INPUT -p tcp --dport 3306 -j DROP\nCOMMIT\n'; } ;;
    docker_so)
      iptables-save() { printf '*filter\n:INPUT ACCEPT [0:0]\n:DOCKER - [0:0]\n-A FORWARD -j DOCKER\n-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP\nCOMMIT\n'; }
      nft() { printf 'table ip filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t}\n\tchain DOCKER-ISOLATION-STAGE-2 {\n\t\toifname "docker0" counter drop\n\t}\n}\n'; } ;;
  esac
}

# rodar_atualizar DIR FIREWALL: main_atualizar com o instalador carregado e
# generate_config de verdade; a saída fica em DIR/saida.log.
rodar_atualizar() {
  local dir="$1" fw="$2"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    NEXTEC_DIR="${dir}/etc/nextec"
    ESTADO_INSTALACAO="${NEXTEC_DIR}/instalacao.conf"
    COLETA_BIN="${dir}/usr/local/lib/nextec/coleta-complementar.py"
    COLETA_CONFIG_DIR="${dir}/etc/coleta-complementar"
    COLETA_CONFIG="${COLETA_CONFIG_DIR}/coleta-complementar.ini"
    COLETA_SEGREDOS="${COLETA_CONFIG_DIR}/segredos.ini"
    COLETA_DADOS="${dir}/var/lib/coleta-complementar"
    COLETA_TEXTFILE="${COLETA_DADOS}/textfile"
    COLETA_EVENTOS="${dir}/var/log/coleta-complementar/eventos.jsonl"
    COLETA_SERVICE="${dir}/etc/systemd/system/coleta-complementar.service"
    CONFIG_DIR="${dir}/etc/alloy"
    CONFIG_FILE="${CONFIG_DIR}/config.alloy"
    BACKUP_DIR="${CONFIG_DIR}/backup"
    COLETA_ARQUIVO="$COLETA"
    export COLETA_COMPLEMENTAR_CONFIG="$COLETA_CONFIG"

    need_root() { :; }
    need_systemd() { :; }
    banner() { :; }
    detect_os() { PKG_FAMILY="apt"; ARCH="amd64"; }
    detect_idrac() { IDRAC_DETECTADO=0; IDRAC_ENDERECO=""; }
    detect_virtualizacao() { VIRT_DETECTADA=""; }
    detect_discos() { DISCOS_FISICOS=0; DISCOS_LISTA=""; DISCOS_RAID=0; EM_VIRTUAL=1; }
    install_alloy() { echo "STUB install_alloy"; }
    install_coleta_complementar() { echo "STUB install_coleta_complementar"; }
    install_atualizador() { echo "STUB install_atualizador"; }
    prepare_snmp_config() { :; }
    write_blackbox_config() { :; }
    configure_service_env() { :; }
    validate_and_start() { :; }
    has_systemd_runtime() { return 0; }
    chown() { :; }
    systemctl() { return 0; }
    firewall_falso "$fw"
    main_atualizar
  ) > "${dir}/saida.log" 2>&1
}

valor_conf() { sed -n "s/^${2}=//p" "$1/etc/nextec/instalacao.conf"; }

contar() { grep -c -F -- "$2" "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# Cenários
# ------------------------------------------------------------------------------

echo "1. --atualizar, instalação anterior sem ENABLE_FIREWALL"
d="$(preparar_cenario antigo)"
rodar_atualizar "$d" ufw_log
conferir "termina sem erro" "$(contar "$d/saida.log" 'Atualização concluída')" "1"
conferir "ENABLE_FIREWALL gravado desligado" "$(valor_conf "$d" ENABLE_FIREWALL)" "0"
conferir "versão do instalador atualizada" "$(valor_conf "$d" INSTALADOR_VERSAO)" "$VERSAO_ESPERADA"
conferir_nao_contem "config sem o bloco do firewall" "$d/etc/alloy/config.alloy" 'firewall_linux'
conferir_nao_contem "sem loki.write quando nada usa o Loki" "$d/etc/alloy/config.alloy" 'loki.write "nextec"'

echo "2. --atualizar com ENABLE_FIREWALL=1 e ufw registrando"
d="$(preparar_cenario ligado)"
echo "ENABLE_FIREWALL=1" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" ufw_log
conferir "termina sem erro" "$(contar "$d/saida.log" 'Atualização concluída')" "1"
conferir "ENABLE_FIREWALL continua 1" "$(valor_conf "$d" ENABLE_FIREWALL)" "1"
conferir "um loki.source.journal do firewall" "$(contar "$d/etc/alloy/config.alloy" 'loki.source.journal "firewall_linux"')" "1"
conferir "um loki.process do firewall" "$(contar "$d/etc/alloy/config.alloy" 'loki.process "firewall_linux"')" "1"
conferir_contem "loki.write criado só pelo firewall" "$d/etc/alloy/config.alloy" 'loki.write "nextec"'
conferir_contem "lê o log do kernel" "$d/etc/alloy/config.alloy" 'matches    = "_TRANSPORT=kernel"'
conferir_contem "servico firewall_linux" "$d/etc/alloy/config.alloy" 'servico="firewall_linux"'
conferir_contem "canal firewall" "$d/etc/alloy/config.alloy" 'canal="firewall"'
conferir_contem "mensagem com o host em maiúsculas" "$d/etc/alloy/config.alloy" '🔐 NXT-SRV-APP03 · Bloqueio no firewall do Linux'
conferir_contem "freio de 20 por segundo" "$d/etc/alloy/config.alloy" 'rate  = 20'
conferir_contem "resumo do firewall na saída" "$d/saida.log" 'Bloqueios do firewall: ufw, registrando bloqueios.'
conferir_nao_contem "sem aviso quando registra" "$d/saida.log" 'não registra os bloqueios'

echo "3. --atualizar com ENABLE_FIREWALL=1 e ufw sem registro"
d="$(preparar_cenario sem-log)"
echo "ENABLE_FIREWALL=1" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" ufw_sem_log
conferir "termina sem erro" "$(contar "$d/saida.log" 'Atualização concluída')" "1"
conferir_contem "avisa sem alterar o firewall" "$d/saida.log" 'O ufw está ativo, mas não registra os bloqueios (ufw logging on).'
conferir_contem "bloco gerado mesmo assim" "$d/etc/alloy/config.alloy" 'loki.source.journal "firewall_linux"'

echo "4. --atualizar com ENABLE_FIREWALL=1 sem firewall ativo"
d="$(preparar_cenario sem-firewall)"
echo "ENABLE_FIREWALL=1" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" nenhum
conferir_contem "avisa que não há firewall" "$d/saida.log" 'Nenhum firewall ativo encontrado'

echo "5. Collector sem servidor monitorado não gera o bloco"
d="$(preparar_cenario collector)"
sed -i 's/^MONITOR_SERVER=1/MONITOR_SERVER=0/; s/^COLLECTOR=0/COLLECTOR=1/' "$d/etc/nextec/instalacao.conf"
echo "ENABLE_FIREWALL=1" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" ufw_log
conferir_nao_contem "sem bloco do firewall" "$d/etc/alloy/config.alloy" 'firewall_linux'

echo "6. ENABLE_FIREWALL inválido no instalacao.conf é recusado"
d="$(preparar_cenario invalido)"
echo "ENABLE_FIREWALL=talvez" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" ufw_log
conferir_contem "erro claro" "$d/saida.log" "Valor inválido de ENABLE_FIREWALL."
conferir "não grava respostas novas" "$(valor_conf "$d" INSTALADOR_VERSAO)" "2.16.0"

echo "7. Detecção do firewall"
deteccao() {
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    firewall_falso "$1"
    detect_firewall_linux
    echo "${FIREWALL_TIPO:-nenhum}|${FIREWALL_REGISTRA}|$(firewall_resumo)"
  )
}
conferir "ufw registrando" "$(deteccao ufw_log)" "ufw|1|ufw, registrando bloqueios"
conferir "ufw sem registro" "$(deteccao ufw_sem_log)" "ufw|0|ufw, sem registro de bloqueios"
conferir "firewalld com LogDenied off" "$(deteccao firewalld_sem_log)" "firewalld|0|firewalld, sem registro de bloqueios"
conferir "nftables com log" "$(deteccao nft_log)" "nftables|1|nftables, registrando bloqueios"
conferir "iptables sem LOG" "$(deteccao iptables_sem_log)" "iptables|0|iptables, sem registro de bloqueios"
conferir "só regras do Docker não contam" "$(deteccao docker_so)" "nenhum|0|nenhum firewall ativo encontrado"
conferir "nenhum firewall" "$(deteccao nenhum)" "nenhum|0|nenhum firewall ativo encontrado"

echo "8. needs_loki e firewall_enabled"
loki() {
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    ENABLE_LOGS=0; ENABLE_FIREWALL="$1"; MONITOR_SERVER="$2"
    coleta_enabled() { return 1; }
    syslog_origens() { :; }
    needs_loki && echo sim || echo nao
  )
}
conferir "firewall ligado no servidor usa o Loki" "$(loki 1 1)" "sim"
conferir "firewall desligado não usa" "$(loki 0 1)" "nao"
conferir "só collector não usa" "$(loki 1 0)" "nao"

echo "9. Checklist (sem terminal): item do firewall"
checklist() {
  local monitor="$1" entrada="$2"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    firewall_falso ufw_log
    DETECTED_DATABASES=(); DOCKER_DETECTED=0; VIRT_DETECTADA=""; MONITOR_SERVER="$monitor"
    DISCOS_FISICOS=0; DISCOS_RAID=0; EM_VIRTUAL=1
    detect_firewall_linux
    resource_checklist >/dev/null 2>&1 <<<"$entrada"
    echo "ENABLE_FIREWALL=${ENABLE_FIREWALL}"
  )
}
conferir "vem desmarcado" "$(checklist 1 '')" "ENABLE_FIREWALL=0"
conferir "marcado pelo número 12" "$(checklist 1 $'12\n')" "ENABLE_FIREWALL=1"
conferir "bloqueado sem servidor monitorado" "$(checklist 0 $'12\n')" "ENABLE_FIREWALL=0"

echo "10. Escape dos rótulos"
escape="$(
  # shellcheck disable=SC1090
  source "$INSTALADOR"; trap - ERR
  CLIENTE='cli"ente' HOST_LABEL=srv01 AMBIENTE=producao CRITICIDADE=alto LOCAL=matriz MONITOR_SERVER=1 ENABLE_FIREWALL=1
  firewall_linux_alloy | grep -c 'cliente="cli\\"ente"'
)"
conferir "aspas escapadas no cliente" "$escape" "1"

echo "11. Filtro do destino: só o broadcast das redes do servidor é descartado"
# Lê do bloco gerado a expressão do estágio que filtra o ip_destino. O "ip" é
# trocado por uma função com a saída de "ip -4 -o addr show scope global".
expressao_destino() {
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"; trap - ERR
    CLIENTE=cli HOST_LABEL=srv01 AMBIENTE=producao CRITICIDADE=alto LOCAL=matriz MONITOR_SERVER=1 ENABLE_FIREWALL=1
    SAIDA_IP="$1"
    ip() { printf '%s' "$SAIDA_IP"; }
    firewall_linux_alloy | awk '/source.*"ip_destino"/ { getline; print }' | sed 's/^ *expression = `\(.*\)`$/\1/'
  )
}
destino() {
  python3 -c 'import re, sys; print("descarta" if re.search(sys.argv[1], sys.argv[2]) else "registra")' "$1" "$2"
}
REDES=$'2: eth0    inet 10.0.0.20/23 brd 10.0.1.255 scope global eth0\n3: eth1    inet 192.168.1.111/24 brd 192.168.1.255 scope global eth1\n'
com_redes="$(expressao_destino "$REDES")"
sem_redes="$(expressao_destino "")"
conferir "pontos escapados e uma alternativa por rede" "$([[ "$com_redes" == *'|^(10\.0\.1\.255|192\.168\.1\.255)$' ]] && echo sim || echo nao)" "sim"
conferir "broadcast da rede eth0 (10.0.1.255) é descartado" "$(destino "$com_redes" 10.0.1.255)" "descarta"
conferir "broadcast da rede eth1 (192.168.1.255) é descartado" "$(destino "$com_redes" 192.168.1.255)" "descarta"
conferir "host 10.0.0.255 da rede /23 é registrado" "$(destino "$com_redes" 10.0.0.255)" "registra"
conferir "broadcast limitado 255.255.255.255 é descartado" "$(destino "$com_redes" 255.255.255.255)" "descarta"
conferir "multicast 224.0.0.251 é descartado" "$(destino "$com_redes" 224.0.0.251)" "descarta"
conferir "multicast 239.255.255.250 é descartado" "$(destino "$com_redes" 239.255.255.250)" "descarta"
conferir "multicast IPv6 ff02::1 é descartado" "$(destino "$com_redes" ff02::1)" "descarta"
conferir "destino comum é registrado" "$(destino "$com_redes" 203.0.113.5)" "registra"
conferir "sem redes lidas: .255 é registrado" "$(destino "$sem_redes" 10.0.1.255)" "registra"
conferir "sem redes lidas: multicast continua descartado" "$(destino "$sem_redes" 224.0.0.251)" "descarta"

if [[ -n "${ALLOY_BIN:-}" ]]; then
  echo "12. alloy validate no config gerado"
  d="${BASE}/ligado"
  if "$ALLOY_BIN" validate "$d/etc/alloy/config.alloy" > "$d/validate.log" 2>&1; then
    conferir "config válido" "sim" "sim"
  else
    conferir "config válido ($(tr '\n' ' ' < "$d/validate.log"))" "não" "sim"
  fi
fi

echo
echo "Resultado: ${PASSOU} ok, ${FALHOU} falha(s)."
[[ "$FALHOU" == "0" ]]
