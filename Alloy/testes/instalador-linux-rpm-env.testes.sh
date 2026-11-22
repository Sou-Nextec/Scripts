#!/usr/bin/env bash
# ==============================================================================
# Testes do instalador Linux: credenciais em /etc/default/alloy também no RPM
# (RHEL, Rocky, Alma, CentOS), onde o alloy.service lê /etc/sysconfig/alloy.
#
# Rodar da raiz do repositório Scripts (não precisa de root nem de systemd):
#   bash Alloy/testes/instalador-linux-rpm-env.testes.sh
#
# Cada cenário roda num subshell que carrega o instalador com "source", leva o
# drop-in para uma pasta temporária e troca o systemctl por uma função que lê a
# unidade e o drop-in de verdade, para o resultado não depender da máquina. Se
# houver systemd-analyze, a sintaxe do drop-in também é conferida por ele.
# ==============================================================================

# As variáveis abaixo são lidas pelo instalador carregado com "source"; as
# funções falsas (systemctl, alloy...) só são chamadas por ele (SC2317).
# shellcheck disable=SC2034,SC1090,SC2317
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALADOR="${AQUI}/../install-nextec-monitoring-linux-v2.sh"
CHANGELOG="${AQUI}/../CHANGELOG.md"
BASE="$(mktemp -d -t instalador-rpm-env.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

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

contar() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# Unidades do alloy.service como cada pacote entrega
# ------------------------------------------------------------------------------
unidade_rpm() {
  cat <<'EOF'
[Unit]
Description=Vendor-neutral programmable telemetry collector
After=network-online.target

[Service]
Restart=always
User=alloy
Environment=HOSTNAME=%H
EnvironmentFile=/etc/sysconfig/alloy
WorkingDirectory=/var/lib/alloy
ExecStart=/usr/bin/alloy run $CUSTOM_ARGS --storage.path=/var/lib/alloy/data $CONFIG_FILE

[Install]
WantedBy=multi-user.target
EOF
}

unidade_deb() {
  sed 's#/etc/sysconfig/alloy#/etc/default/alloy#' <(unidade_rpm)
}

unidade_binario() {
  sed 's#EnvironmentFile=/etc/sysconfig/alloy#EnvironmentFile=-/etc/default/alloy#' <(unidade_rpm)
}

# preparar_cenario NOME TIPO: monta a unidade (rpm | deb | binario | nenhuma) e
# a pasta de drop-ins; devolve a pasta do cenário.
preparar_cenario() {
  local dir="${BASE}/$1" tipo="$2"
  mkdir -p "${dir}/unit" "${dir}/dropins"
  : > "${dir}/systemctl.log"
  case "$tipo" in
    rpm) unidade_rpm > "${dir}/unit/alloy.service" ;;
    deb) unidade_deb > "${dir}/unit/alloy.service" ;;
    binario) unidade_binario > "${dir}/unit/alloy.service" ;;
  esac
  echo "$dir"
}

# executar DIR FUNCAO...: roda a função do instalador no cenário; a saída fica em
# DIR/saida.log e o código de saída em DIR/codigo. IGNORA_DROPIN=1 faz o systemd
# falso desconsiderar o drop-in (simula uma unidade que não o aplica).
executar() {
  local dir="$1"
  shift
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    set +e
    SYSTEMD_OVERRIDE_DIR="${dir}/dropins"
    SYSTEMD_ENV_DROPIN="${SYSTEMD_OVERRIDE_DIR}/nextec-env.conf"
    CONFIG_FILE="${dir}/config.alloy"
    : > "$CONFIG_FILE"

    systemctl() {
      # O instalador usa IFS=$'\n\t'; sem isto "$*" juntaria os argumentos por quebra de linha.
      local IFS=' ' arq
      echo "$*" >> "${dir}/systemctl.log"
      case "$1" in
        cat)
          [[ -f "${dir}/unit/alloy.service" ]] ;;
        show)
          case "$*" in
            *FragmentPath*) echo "FragmentPath=${dir}/unit/alloy.service" ;;
            *EnvironmentFile*)
              for arq in "${dir}/unit/alloy.service" "${SYSTEMD_OVERRIDE_DIR}"/*.conf; do
                [[ -f "$arq" ]] || continue
                [[ "$arq" == "${dir}/unit/alloy.service" || "${IGNORA_DROPIN:-0}" != "1" ]] || continue
                [[ "$arq" == "${dir}/unit/alloy.service" || "${EXIGE_RELOAD:-0}" != "1" || -f "${dir}/recarregado" ]] || continue
                sed -n 's/^EnvironmentFile=-\{0,1\}\(.*\)$/EnvironmentFiles=\1 (ignore_errors=no)/p' "$arq"
              done ;;
          esac ;;
        daemon-reload) : > "${dir}/recarregado" ;;
        *) return 0 ;;
      esac
    }
    alloy() { [[ "$1" == "fmt" ]] && cat "$2"; return 0; }
    liberar_syslog_firewall() { echo "liberar_syslog_firewall" >> "${dir}/systemctl.log"; }
    sleep() { :; }
    curl() { return 0; }
    journalctl() { :; }

    "$@"
  ) > "${dir}/saida.log" 2>&1
  echo $? > "${dir}/codigo"
}

codigo() { cat "$1/codigo"; }

# ------------------------------------------------------------------------------
echo "1. Unidade do pacote RPM (lê /etc/sysconfig/alloy): drop-in criado"
d="$(preparar_cenario rpm rpm)"
executar "$d" garantir_env_no_servico
DROPIN="${d}/dropins/nextec-env.conf"
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "drop-in gravado" "$([[ -f "$DROPIN" ]] && echo sim || echo nao)" "sim"
conferir "seção [Service]" "$(contar '^\[Service\]$' "$DROPIN")" "1"
conferir "EnvironmentFile aponta para /etc/default/alloy (sem duplicar o arquivo)" "$(contar '^EnvironmentFile=/etc/default/alloy$' "$DROPIN")" "1"
conferir "drop-in com permissão 0644" "$(stat -c '%a' "$DROPIN")" "644"
conferir "daemon-reload uma vez" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "1"
conferir "não reinicia o serviço (quem reinicia é validate_and_start)" "$(contar '^restart' "${d}/systemctl.log")" "0"
conferir "mensagem informa o drop-in" "$(grep -c 'passa a carregar /etc/default/alloy' "${d}/saida.log")" "1"
conferir "unidade original intacta" "$(contar 'EnvironmentFile=/etc/sysconfig/alloy' "${d}/unit/alloy.service")" "1"

echo "2. Idempotência: segunda execução não regrava o drop-in"
antes="$(cksum < "$DROPIN")"
: > "${d}/systemctl.log"
executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "drop-in igual" "$(cksum < "$DROPIN")" "$antes"
conferir "recarrega o systemd uma vez, antes da checagem" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "1"
conferir "continua com uma só linha EnvironmentFile" "$(contar '^EnvironmentFile=' "$DROPIN")" "1"
conferir "sem mensagem de alteração" "$(grep -c 'passa a carregar' "${d}/saida.log")" "0"

echo "3. Drop-in feito à mão (nextec-env.conf com outro conteúdo) é regravado"
printf '[Service]\nEnvironmentFile=/etc/default/alloy\n' > "$DROPIN"
: > "${d}/systemctl.log"
executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "ficou uma só linha EnvironmentFile" "$(contar '^EnvironmentFile=' "$DROPIN")" "1"
conferir "comentário do instalador presente" "$(contar '^# Gerado pelo instalador Nextec' "$DROPIN")" "1"
conferir "daemon-reload na regravação" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "1"

echo "4. Pasta de drop-ins ainda não existe"
d="$(preparar_cenario sem-pasta rpm)"
rmdir "${d}/dropins"
executar "$d" garantir_env_no_servico
conferir "pasta e drop-in criados" "$([[ -f "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "sim"
conferir "pasta com permissão 0755" "$(stat -c '%a' "${d}/dropins")" "755"

echo "5. Debian/Ubuntu (unidade já lê /etc/default/alloy): nada a fazer"
d="$(preparar_cenario deb deb)"
executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "sem drop-in" "$([[ -e "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "nao"
conferir "sem daemon-reload" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "0"

echo "6. Fallback binário (EnvironmentFile=-/etc/default/alloy): nada a fazer"
d="$(preparar_cenario binario binario)"
executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "sem drop-in" "$([[ -e "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "nao"

echo "7. Serviço sem unidade instalada: ignora"
d="$(preparar_cenario nenhuma nenhuma)"
executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "sem drop-in" "$([[ -e "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "nao"
conferir "sem daemon-reload" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "0"

echo "8. Drop-in que o systemd não aplica: falha e desfaz"
d="$(preparar_cenario nao-aplica rpm)"
IGNORA_DROPIN=1 executar "$d" garantir_env_no_servico
conferir "sai com erro" "$([[ "$(codigo "$d")" != "0" ]] && echo sim || echo nao)" "sim"
conferir "drop-in removido" "$([[ -e "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "nao"
conferir "systemd recarregado depois de desfazer" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "2"
conferir "mensagem de erro" "$(grep -c 'não carregou /etc/default/alloy' "${d}/saida.log")" "1"

echo "8b. Drop-in idêntico gravado sem o reload (execução interrompida): recarrega e passa"
d="$(preparar_cenario sem-reload rpm)"
executar "$d" garantir_env_no_servico
rm -f "${d}/recarregado"
: > "${d}/systemctl.log"
EXIGE_RELOAD=1 executar "$d" garantir_env_no_servico
conferir "terminou sem erro" "$(codigo "$d")" "0"
conferir "daemon-reload mesmo sem mudança no arquivo" "$(contar '^daemon-reload$' "${d}/systemctl.log")" "1"
conferir "drop-in continua gravado" "$([[ -f "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "sim"

echo "8c. Falha com drop-in feito à mão já existente: restaura o conteúdo anterior"
d="$(preparar_cenario restaura rpm)"
printf '[Service]\nEnvironmentFile=/etc/default/alloy\n# feito a mao\n' > "${d}/dropins/nextec-env.conf"
original="$(cksum < "${d}/dropins/nextec-env.conf")"
IGNORA_DROPIN=1 executar "$d" garantir_env_no_servico
conferir "sai com erro" "$([[ "$(codigo "$d")" != "0" ]] && echo sim || echo nao)" "sim"
conferir "drop-in à mão restaurado byte a byte" "$(cksum < "${d}/dropins/nextec-env.conf")" "$original"

echo "9. validate_and_start: drop-in aplicado antes do reinício"
d="$(preparar_cenario ordem rpm)"
executar "$d" validate_and_start
conferir "terminou sem erro" "$(codigo "$d")" "0"
ordem="$(grep -E '^(daemon-reload|restart alloy)$' "${d}/systemctl.log" | tr '\n' ',')"
conferir "daemon-reload do drop-in, daemon-reload do fluxo e só então restart" "$ordem" "daemon-reload,daemon-reload,restart alloy,"
conferir "drop-in gravado" "$([[ -f "${d}/dropins/nextec-env.conf" ]] && echo sim || echo nao)" "sim"

echo "10. Todos os caminhos que reiniciam o Alloy passam por validate_and_start"
for fn in main main_atualizar aplicar_edicao atualizar_somente_alloy validar_e_reiniciar; do
  corpo="$( (source "$INSTALADOR"; trap - ERR; set +e; declare -f "$fn") )"
  conferir "${fn} chama validate_and_start" "$(grep -c 'validate_and_start' <<<"$corpo")" "1"
done
corpo="$( (source "$INSTALADOR"; trap - ERR; set +e; declare -f validate_and_start) )"
conferir "validate_and_start chama garantir_env_no_servico antes do restart" "$(awk '/garantir_env_no_servico/ {a=NR} /systemctl restart alloy/ {r=NR} END {print (a>0 && a<r) ? "sim" : "nao"}' <<<"$corpo")" "sim"

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "11. systemd-analyze reconhece o drop-in (sintaxe)"
  d="${BASE}/analyze"
  mkdir -p "${d}/alloy.service.d"
  sed 's#^ExecStart=.*#ExecStart=/bin/true#' <(unidade_rpm) > "${d}/alloy.service"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"; trap - ERR; set +e
    printf '[Service]\nEnvironmentFile=%s\n' "$ENV_FILE" > "${d}/alloy.service.d/nextec-env.conf"
  )
  saida="$(systemd-analyze verify "${d}/alloy.service" 2>&1 || true)"
  conferir "sem 'Unknown' nem 'Failed to parse' no drop-in" "$(grep -ciE 'unknown (key|section)|failed to parse|nextec-env' <<<"$saida" || true)" "0"
fi

echo "12. Versão do instalador e do CHANGELOG"
VERSAO="$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$INSTALADOR")"
conferir "cabeçalho do instalador com a versão" "$(grep -c "^# Versão: ${VERSAO} " "$INSTALADOR")" "1"
conferir "tabela do CHANGELOG com a versão" "$(grep -c "^| Instalador Linux | \`install-nextec-monitoring-linux-v2.sh\` | ${VERSAO} |$" "$CHANGELOG")" "1"
conferir "CHANGELOG tem entrada da versão" "$(grep -c "^### Instalador Linux ${VERSAO}" "$CHANGELOG")" "1"

echo
echo "Resultado: ${PASSOU} ok, ${FALHOU} falha(s)."
[[ "$FALHOU" == "0" ]]
