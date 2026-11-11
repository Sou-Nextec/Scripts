#!/usr/bin/env bash
# ==============================================================================
# Testes do instalador Linux: saúde dos discos (ENABLE_DISCOS).
#
# Rodar da raiz do repositório Scripts (não precisa de root nem de systemd):
#   bash Alloy/testes/instalador-linux-discos.testes.sh
#
# Cada cenário roda num subshell que carrega o instalador com "source", troca
# os caminhos do sistema por uma pasta temporária, simula o /sys e substitui
# por funções o que mexe no servidor (pacotes, systemctl, Alloy). A Coleta
# Complementar instalada é a do próprio repositório.
# ==============================================================================

# As variáveis abaixo são lidas pelo instalador carregado com "source".
# shellcheck disable=SC2034
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALADOR="${AQUI}/../install-nextec-monitoring-linux-v2.sh"
COLETA="${AQUI}/../coleta-complementar/coleta-complementar.py"
BASE="$(mktemp -d -t instalador-discos.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

PASSOU=0
FALHOU=0

# ------------------------------------------------------------------------------
# Ambiente falso
# ------------------------------------------------------------------------------

# sys_falso PASTA 'disco|caminho_do_dispositivo[|vendor|model]' ...
sys_falso() {
  local raiz="$1" item nome disp vendor model real
  shift
  mkdir -p "${raiz}/block"
  for item in "$@"; do
    IFS='|' read -r nome disp vendor model <<<"$item"
    real="${raiz}/devices/${disp}/block/${nome}"
    mkdir -p "${real}/device"
    echo 0 > "${real}/removable"
    [[ -n "$vendor" ]] && echo "$vendor" > "${real}/device/vendor"
    [[ -n "$model" ]] && echo "$model" > "${real}/device/model"
    ln -s "$real" "${raiz}/block/${nome}"
  done
}

SYS_FISICO="${BASE}/sys-fisico"
sys_falso "$SYS_FISICO" \
  "nvme0n1|pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0" \
  "sda|pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0|ATA|Samsung SSD 870" \
  "dm-0|virtual/block/dm-0" "loop0|virtual/block/loop0" \
  "sdb|pci0000:00/0000:00:1c.0/0000:05:00.0/host5/target5:2:0/5:2:0:0|DELL|PERC H730P Mini"

SYS_VM="${BASE}/sys-vm"
sys_falso "$SYS_VM" "vda|pci0000:00/0000:00:04.0/virtio2" \
  "sda|pci0000:00/0000:00:10.0/host2/target2:0:0/2:0:0:0|QEMU|QEMU HARDDISK" "zram0|virtual/block/zram0"

# Respostas gravadas por um instalador antigo (2.15.0), sem ENABLE_DISCOS.
conf_antigo() {
  cat <<'EOF'
# Respostas da instalação Nextec (2026-10-21T13:00:00Z).
# Lido pelo instalador em --atualizar. Sem senha: credenciais ficam em /etc/default/alloy.
FORMATO=1
INSTALADOR_VERSAO=2.15.0
MODO=completo
NOC_HOST=noc.nex.tec.br
CLIENTE=nextec
HOST_LABEL=nxt-srv-hv01
AMBIENTE=producao
LOCAL=eveo
CRITICIDADE=critico
MONITOR_SERVER=1
COLLECTOR=0
ENABLE_LOGS=1
ENABLE_DOCKER=0
ENABLE_DATABASES=0
ENABLE_BLACKBOX=0
ENABLE_SNMP=0
ENABLE_EXPORTERS=0
ENABLE_INTERNET=1
ENABLE_LINKS=0
ENABLE_VELOCIDADE=0
ENABLE_ACESSOS=1
BANCOS_SQLITE=
ENABLE_VIRT=0
EOF
}

ini_antigo() {
  cat <<'EOF'
[geral]
intervalo_links_segundos = 15
limite_latencia_ms = 200

[internet]
ativo = sim
alvos = 1.1.1.1, 8.8.8.8

[acessos]
ativo = sim
horario = seg-sex 07:00-19:00; sab 07:00-14:00
origens_conhecidas = 203.0.113.0/24
EOF
}

# preparar_cenario NOME SYS: cria a pasta do cenário com conf e ini antigos.
preparar_cenario() {
  local dir="${BASE}/$1"
  mkdir -p "${dir}/etc/nextec" "${dir}/etc/coleta-complementar" "${dir}/etc/systemd/system" "${dir}/log"
  conf_antigo > "${dir}/etc/nextec/instalacao.conf"
  ini_antigo > "${dir}/etc/coleta-complementar/coleta-complementar.ini"
  echo "$dir"
}

# rodar_atualizar DIR SYS VIRTUAL(0|1) SMARTCTL_INSTALADO(0|1) PACOTE_OK(0|1)
# Roda main_atualizar com o instalador carregado e grava a saída em DIR/saida.log.
rodar_atualizar() {
  local dir="$1" sys="$2" virtual="$3" tem_smartctl="$4" pacote_ok="$5"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    SYS_RAIZ="$sys"
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
    CONFIG_FILE="${dir}/etc/alloy/config.alloy"
    COLETA_ARQUIVO="$COLETA"
    export COLETA_COMPLEMENTAR_CONFIG="$COLETA_CONFIG"

    need_root() { :; }
    need_systemd() { :; }
    banner() { :; }
    detect_os() { PKG_FAMILY="apt"; ARCH="amd64"; }
    detect_idrac() { IDRAC_DETECTADO=0; IDRAC_ENDERECO=""; }
    detect_virtualizacao() { VIRT_DETECTADA=""; }
    install_alloy() { echo "STUB install_alloy"; }
    install_atualizador() { echo "STUB install_atualizador"; }
    install_speedtest_cli() { :; }
    prepare_snmp_config() { :; }
    write_blackbox_config() { :; }
    configure_service_env() { :; }
    generate_config() { :; }
    validate_and_start() { :; }
    systemctl() { local IFS=' '; echo "STUB systemctl $*" >> "${dir}/log/systemctl"; return 0; }
    smartctl_instalado() { [[ "$tem_smartctl" == "1" ]]; }
    apt-get() { local IFS=' '; echo "$*" >> "${dir}/log/apt-get"; [[ "$pacote_ok" == "1" ]]; }
    if [[ "$virtual" == "1" ]]; then
      systemd-detect-virt() { return 0; }
    else
      systemd-detect-virt() { return 1; }
    fi
    main_atualizar
  ) > "${dir}/saida.log" 2>&1
}

valor_conf() { sed -n "s/^${2}=//p" "$1/etc/nextec/instalacao.conf"; }

valor_ini() {
  python3 - "$1/etc/coleta-complementar/coleta-complementar.ini" "$2" "$3" <<'PY'
import configparser, sys
c = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";", "#"))
c.optionxform = str
c.read(sys.argv[1], encoding="utf-8")
print(c.get(sys.argv[2], sys.argv[3], fallback="<ausente>"))
PY
}

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

# ------------------------------------------------------------------------------
# Cenários
# ------------------------------------------------------------------------------

echo "1. --atualizar, instalação antiga sem ENABLE_DISCOS, servidor físico"
d="$(preparar_cenario fisico)"
rodar_atualizar "$d" "$SYS_FISICO" 0 0 1
conferir "termina sem erro" "$(grep -c 'Atualização concluída' "$d/saida.log")" "1"
conferir "ENABLE_DISCOS gravado ligado" "$(valor_conf "$d" ENABLE_DISCOS)" "1"
conferir "versão do instalador atualizada" "$(valor_conf "$d" INSTALADOR_VERSAO)" "$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$INSTALADOR")"
conferir "respostas antigas mantidas" "$(valor_conf "$d" HOST_LABEL)" "nxt-srv-hv01"
conferir "[discos] ativo no .ini" "$(valor_ini "$d" discos ativo)" "sim"
conferir "[discos] intervalo de 10 min" "$(valor_ini "$d" discos intervalo_minutos)" "10"
conferir "ajuste local do .ini preservado" "$(valor_ini "$d" geral limite_latencia_ms)" "200"
conferir "origens conhecidas preservadas" "$(valor_ini "$d" acessos origens_conhecidas)" "203.0.113.0/24"
conferir_contem "instala o smartmontools sem recommends" "$d/log/apt-get" "--no-install-recommends smartmontools"
conferir_contem "desliga o smartd do pacote" "$d/log/systemctl" "disable --now smartmontools.service"
conferir_contem "mostra os discos encontrados" "$d/saida.log" "Saúde dos discos: 2 disco(s): nvme0n1, sda e 1 volume(s) RAID, discos lidos pela controladora."

echo "2. --atualizar, instalação antiga sem ENABLE_DISCOS, VM"
d="$(preparar_cenario vm)"
rodar_atualizar "$d" "$SYS_VM" 1 0 1
conferir "termina sem erro" "$(grep -c 'Atualização concluída' "$d/saida.log")" "1"
conferir "ENABLE_DISCOS gravado desligado" "$(valor_conf "$d" ENABLE_DISCOS)" "0"
conferir "[discos] desligado no .ini" "$(valor_ini "$d" discos ativo)" "nao"
conferir_nao_contem "não instala o smartmontools" "$d/log/apt-get" "smartmontools"

echo "3. --atualizar respeita ENABLE_DISCOS=0 gravado, mesmo com disco físico"
d="$(preparar_cenario desligado)"
echo "ENABLE_DISCOS=0" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" "$SYS_FISICO" 0 0 1
conferir "ENABLE_DISCOS continua 0" "$(valor_conf "$d" ENABLE_DISCOS)" "0"
conferir "[discos] desligado no .ini" "$(valor_ini "$d" discos ativo)" "nao"
conferir_nao_contem "não instala o smartmontools" "$d/log/apt-get" "smartmontools"

echo "4. --atualizar respeita ENABLE_DISCOS=1 gravado em VM (disco repassado)"
d="$(preparar_cenario ligado-vm)"
echo "ENABLE_DISCOS=1" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" "$SYS_VM" 1 1 1
conferir "ENABLE_DISCOS continua 1" "$(valor_conf "$d" ENABLE_DISCOS)" "1"
conferir_nao_contem "smartctl já instalado: não chama o apt" "$d/log/apt-get" "smartmontools"

echo "5. --atualizar com falha passageira ao instalar o smartmontools"
d="$(preparar_cenario falha-pacote)"
rodar_atualizar "$d" "$SYS_FISICO" 0 0 0
conferir "termina sem erro" "$(grep -c 'Atualização concluída' "$d/saida.log")" "1"
conferir "ENABLE_DISCOS não é desligado" "$(valor_conf "$d" ENABLE_DISCOS)" "1"
conferir_contem "avisa a nova tentativa" "$d/saida.log" "nova tentativa na próxima atualização"

echo "6. --atualizar com links (gera o .ini do zero)"
d="$(preparar_cenario com-link)"
echo "LINK=Cyberline Fibra|primario|Cyberline|fibra||||8.8.8.8|||||" >> "$d/etc/nextec/instalacao.conf"
sed -i 's/^ENABLE_LINKS=0/ENABLE_LINKS=1/' "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" "$SYS_FISICO" 0 0 1
conferir "[discos] ativo no .ini novo" "$(valor_ini "$d" discos ativo)" "sim"
conferir "link no .ini novo" "$(valor_ini "$d" 'link:Cyberline Fibra' papel)" "primario"

echo "6b. --atualizar em servidor Dell só com volume do PERC"
SYS_PERC="${BASE}/sys-perc"
sys_falso "$SYS_PERC" "sda|pci0000:00/0000:00:1c.0/0000:05:00.0/host5/target5:2:0/5:2:0:0|DELL|PERC H730P Mini"
d="$(preparar_cenario perc)"
rodar_atualizar "$d" "$SYS_PERC" 0 0 1
conferir "ENABLE_DISCOS gravado ligado" "$(valor_conf "$d" ENABLE_DISCOS)" "1"
conferir "[discos] ativo no .ini" "$(valor_ini "$d" discos ativo)" "sim"
conferir_contem "resumo cita o volume RAID" "$d/saida.log" "0 disco(s) e 1 volume(s) RAID"

echo "7. ENABLE_DISCOS inválido no instalacao.conf é recusado"
d="$(preparar_cenario invalido)"
echo "ENABLE_DISCOS=talvez" >> "$d/etc/nextec/instalacao.conf"
rodar_atualizar "$d" "$SYS_FISICO" 0 0 1
conferir_contem "erro claro" "$d/saida.log" "Valor inválido de ENABLE_DISCOS."
conferir "não grava respostas novas" "$(valor_conf "$d" INSTALADOR_VERSAO)" "2.15.0"

echo "8. Checklist (sem terminal): item de discos"
saida_check() {
  local sys="$1" virtual="$2"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    SYS_RAIZ="$sys"
    if [[ "$virtual" == "1" ]]; then systemd-detect-virt() { return 0; }; else systemd-detect-virt() { return 1; }; fi
    DETECTED_DATABASES=(); DOCKER_DETECTED=0; VIRT_DETECTADA=""; MONITOR_SERVER=1
    detect_discos
    resource_checklist >/dev/null 2>&1 <<<""
    echo "ENABLE_DISCOS=${ENABLE_DISCOS}"
  )
}
conferir "físico: vem marcado" "$(saida_check "$SYS_FISICO" 0)" "ENABLE_DISCOS=1"
conferir "VM: vem desmarcado" "$(saida_check "$SYS_VM" 1)" "ENABLE_DISCOS=0"

echo "9. Detecção igual à da Coleta Complementar"
lista_coleta="$(python3 - "$COLETA" "$SYS_FISICO" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cc", sys.argv[1])
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)
print(", ".join(cc.discos_fisicos(sys.argv[2])))
PY
)"
lista_instalador="$(
  # shellcheck disable=SC1090
  source "$INSTALADOR"; trap - ERR; SYS_RAIZ="$SYS_FISICO"; detect_discos; echo "$DISCOS_LISTA"
)"
conferir "mesma lista de discos" "$lista_instalador" "$lista_coleta"

echo
echo "Resultado: ${PASSOU} ok, ${FALHOU} falha(s)."
[[ "$FALHOU" == "0" ]]
