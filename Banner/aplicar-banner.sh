#!/usr/bin/env bash
# Nextec | Aplica o aviso de acesso (antes da senha) e o quadro informativo (depois do login)
#
# Funciona em qualquer Linux com bash e OpenSSH Server:
#   Ubuntu/Debian (update-motd), CentOS/RHEL/Rocky/Alma/Fedora, SUSE, Alpine e outros.
#
# Uso (dentro da sessão SSH do servidor):
#   TIPO='cliente'               # cliente | nextec
#   NOME=''                      # Vazio = usa o hostname
#   FUNCAO='Servidor Escriba'
#   AMBIENTE='Produção'          # Produção | Homologação | Testes
#   curl -fsSL https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner/aplicar-banner.sh -o /tmp/aplicar-banner.sh
#   sudo TIPO="$TIPO" NOME="$NOME" FUNCAO="$FUNCAO" AMBIENTE="$AMBIENTE" bash /tmp/aplicar-banner.sh
#
# Pode ser executado de novo a qualquer momento: faz backup do que existe e regrava tudo.
set -euo pipefail

BASE_URL="${BANNER_BASE_URL:-https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/01-nextec-aviso.conf"
NEXTEC_DIR="/etc/nextec"
PROFILE_RUNNER="/etc/profile.d/00-nextec-motd.sh"
MARCADOR="# Nextec: aviso de acesso antes da senha"
STAMP="$(date +%Y%m%d%H%M%S)"

TIPO="${TIPO:-}"
NOME="${NOME:-}"
FUNCAO="${FUNCAO:-}"
AMBIENTE="${AMBIENTE:-}"

falha() { echo "Erro: $*" >&2; exit 1; }
aviso() { echo "Aviso: $*" >&2; }

# Remove quebras de linha e caracteres de controle antes de gravar em /etc/environment
limpar() { printf '%s' "$1" | tr -d '\000-\037\\'; }

# Grava o conteúdo de $2 em $1 mantendo dono, permissões e contexto SELinux do arquivo original
regravar() { cat "$2" > "$1"; }

# ---------- Validação ----------
[[ $EUID -eq 0 ]] || falha "execute como root (use sudo)."

case "$TIPO" in
  cliente) ARQUIVOS=("05-servidor") ;;
  nextec)  ARQUIVOS=("05-nextec" "10-nextec-info") ;;
  *)       falha "TIPO deve ser 'cliente' ou 'nextec'." ;;
esac

NOME="$(limpar "$NOME")"
FUNCAO="$(limpar "$FUNCAO")"
AMBIENTE="$(limpar "$AMBIENTE")"
[[ -n "$FUNCAO" ]]   || falha "informe FUNCAO."
[[ -n "$AMBIENTE" ]] || falha "informe AMBIENTE."

command -v curl >/dev/null || falha "curl não encontrado."
SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
[[ -n "$SSHD_BIN" ]] || { [[ -x /usr/sbin/sshd ]] && SSHD_BIN=/usr/sbin/sshd; }
[[ -n "$SSHD_BIN" ]] || falha "OpenSSH Server (sshd) não encontrado."
[[ -f "$SSHD_CONFIG" ]] || falha "${SSHD_CONFIG} não encontrado."

# ---------- Como o sistema exibe a mensagem depois do login ----------
# update-motd: Ubuntu/Debian, o PAM executa os scripts de /etc/update-motd.d.
# profile:     demais distribuições, os scripts ficam em /etc/nextec/motd.d e são
#              executados no login interativo por /etc/profile.d/00-nextec-motd.sh.
if [[ -d /etc/update-motd.d ]] && grep -qs 'pam_motd' /etc/pam.d/sshd; then
  MODO="update-motd"
  MOTD_DIR="/etc/update-motd.d"
else
  MODO="profile"
  MOTD_DIR="${NEXTEC_DIR}/motd.d"
fi
echo "Sistema: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-desconhecido}" || echo desconhecido) | modo: ${MODO}"

KEEP=("${ARQUIVOS[@]}" "98-reboot-required" "98-fsck-at-reboot")

# ---------- 1. Baixa os arquivos do repositório ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for arquivo in "${ARQUIVOS[@]}" "aviso-acesso.txt"; do
  curl -fsSL "${BASE_URL}/${arquivo}" -o "${TMP}/${arquivo}" || falha "não foi possível baixar ${arquivo}."
  [[ -s "${TMP}/${arquivo}" ]] || falha "${arquivo} veio vazio."
done
for arquivo in "${ARQUIVOS[@]}"; do
  head -1 "${TMP}/${arquivo}" | grep -q '^#!' || falha "${arquivo} não parece um script válido."
  bash -n "${TMP}/${arquivo}" || falha "${arquivo} tem erro de sintaxe."
done
echo "Arquivos baixados de ${BASE_URL}"

# ---------- 2. Variáveis do servidor ----------
touch /etc/environment
cp -a /etc/environment "/etc/environment.bak.${STAMP}"
sed -i '/^NEXTEC_\(NOME_SERVIDOR\|FUNCAO\|AMBIENTE\)=/d' /etc/environment
[[ -n "$NOME" ]] && printf 'NEXTEC_NOME_SERVIDOR=%s\n' "$NOME" >> /etc/environment
printf 'NEXTEC_FUNCAO=%s\nNEXTEC_AMBIENTE=%s\n' "$FUNCAO" "$AMBIENTE" >> /etc/environment
echo "Variáveis gravadas em /etc/environment"

# ---------- 3. Remove restos de versões anteriores ----------
rm -f /etc/update-motd.d/01-nextec /etc/ssh/sshd_config.d/10-banner.conf
for antigo in "${NEXTEC_DIR}/motd.conf" "${NEXTEC_DIR}/motd-header.sh"; do
  if [[ -f "$antigo" ]]; then
    mv "$antigo" "${antigo}.bak.${STAMP}"
    echo "Arquivo antigo desativado: ${antigo}"
  fi
done
# Quadros de outro TIPO aplicados antes (ex.: troca de cliente para nextec)
for antigo in 05-servidor 05-nextec 10-nextec-info; do
  [[ " ${ARQUIVOS[*]} " == *" ${antigo} "* ]] && continue
  rm -f "/etc/update-motd.d/${antigo}" "${NEXTEC_DIR}/motd.d/${antigo}"
done

# ---------- 4. Instala o quadro informativo ----------
mkdir -p "$MOTD_DIR"
for arquivo in "${ARQUIVOS[@]}"; do
  destino="${MOTD_DIR}/${arquivo}"
  # Backup fora da pasta de execução, para a cópia antiga não ser executada no login
  if [[ -f "$destino" ]]; then
    mkdir -p "${NEXTEC_DIR}/backup"
    cp -a "$destino" "${NEXTEC_DIR}/backup/${arquivo}.${STAMP}"
    chmod 0644 "${NEXTEC_DIR}/backup/${arquivo}.${STAMP}"
  fi
  install -o root -g root -m 755 "${TMP}/${arquivo}" "$destino"
  echo "Instalado: ${destino}"
done

if [[ "$MODO" == "profile" ]]; then
  cat > "${TMP}/runner" <<'RUNNER'
# Nextec: exibe o quadro informativo depois do login.
# Gerado pelo aplicar-banner.sh, não editar (é regravado a cada execução).
# Só roda em shell interativo com terminal, para não quebrar scp, sftp e rsync.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if [ -t 1 ] && [ -z "${NEXTEC_MOTD_EXIBIDO:-}" ] && [ -d /etc/nextec/motd.d ]; then
  NEXTEC_MOTD_EXIBIDO=1
  export NEXTEC_MOTD_EXIBIDO
  for _nx_script in /etc/nextec/motd.d/*; do
    case ${_nx_script##*/} in *.*) continue ;; esac
    [ -f "$_nx_script" ] && [ -x "$_nx_script" ] && "$_nx_script" 2>/dev/null
  done
  unset _nx_script
fi
RUNNER
  install -o root -g root -m 644 "${TMP}/runner" "$PROFILE_RUNNER"
  echo "Instalado: ${PROFILE_RUNNER}"
else
  rm -f "$PROFILE_RUNNER"
fi

# ---------- 5. Desativa as demais mensagens de login ----------
if [[ "$MODO" == "update-motd" ]]; then
  for path in "$MOTD_DIR"/*; do
    name="$(basename "$path")"
    [[ " ${KEEP[*]} " == *" ${name} "* ]] && continue
    [[ -f "$path" && -x "$path" ]] || continue
    if command -v dpkg >/dev/null && dpkg -S "$path" >/dev/null 2>&1 \
       && ! dpkg-statoverride --list "$path" >/dev/null 2>&1; then
      dpkg-statoverride --update --add root root 0644 "$path"
    fi
    chmod 0644 "$path"
    echo "Desativado: ${name}"
  done
  if [[ -f /etc/default/motd-news ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  fi
  if command -v systemctl >/dev/null; then
    systemctl disable --now motd-news.timer >/dev/null 2>&1 || true
  fi
fi

# /etc/motd.d (RHEL e derivados): mensagens de outros pacotes, como o link do Cockpit
if [[ -d /etc/motd.d ]]; then
  for path in /etc/motd.d/*; do
    [[ -e "$path" || -L "$path" ]] || continue
    mkdir -p "${NEXTEC_DIR}/motd.d-desativado"
    mv "$path" "${NEXTEC_DIR}/motd.d-desativado/$(basename "$path").${STAMP}"
    echo "Desativado: /etc/motd.d/$(basename "$path")"
  done
fi

if [[ -s /etc/motd ]]; then
  cp -a /etc/motd "/etc/motd.bak.${STAMP}"
  truncate -s 0 /etc/motd
  echo "/etc/motd antigo esvaziado (backup criado)."
fi

# ---------- 6. Aviso antes da senha ----------
for file in /etc/issue.net /etc/issue; do
  [[ -f "$file" ]] && cp -a "$file" "${file}.bak.${STAMP}"
  install -o root -g root -m 644 "${TMP}/aviso-acesso.txt" "$file"
done
echo "Aviso gravado em /etc/issue.net e /etc/issue"

cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.${STAMP}"

# Remove o bloco que este script pode ter gravado antes direto no sshd_config
awk -v m="$MARCADOR" '
  $0 == m { pular = 1; next }
  pular == 1 && $0 ~ /^Banner / { pular = 0; next }
  { pular = 0; print }
' "$SSHD_CONFIG" > "${TMP}/sshd_config"
regravar "$SSHD_CONFIG" "${TMP}/sshd_config"

if [[ -d "$SSHD_DROPIN_DIR" ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG"; then
  printf '%s\nBanner /etc/issue.net\n' "$MARCADOR" > "$SSHD_DROPIN"
  chown root:root "$SSHD_DROPIN"
  chmod 644 "$SSHD_DROPIN"
  echo "Aviso configurado em ${SSHD_DROPIN}"
else
  # Sem sshd_config.d (ex.: CentOS 8): grava no início do sshd_config, porque no
  # OpenSSH vale o primeiro valor encontrado e o início fica fora de qualquer bloco Match.
  rm -f "$SSHD_DROPIN"
  { printf '%s\nBanner /etc/issue.net\n' "$MARCADOR"; cat "$SSHD_CONFIG"; } > "${TMP}/sshd_config"
  regravar "$SSHD_CONFIG" "${TMP}/sshd_config"
  echo "Aviso configurado no início de ${SSHD_CONFIG}"
fi

if ! "$SSHD_BIN" -t; then
  rm -f "$SSHD_DROPIN"
  regravar "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.${STAMP}"
  falha "configuração do SSH inválida. Aviso desfeito, nada foi recarregado."
fi

recarregar_ssh() {
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl try-reload-or-restart sshd 2>/dev/null || systemctl try-reload-or-restart ssh 2>/dev/null
  elif command -v rc-service >/dev/null; then
    rc-service sshd reload
  elif command -v service >/dev/null; then
    service sshd reload 2>/dev/null || service ssh reload
  else
    return 1
  fi
}
if recarregar_ssh; then
  echo "SSH recarregado."
else
  aviso "não foi possível recarregar o SSH. Recarregue manualmente para o aviso valer."
fi

# ---------- 7. Conferência ----------
echo
echo "Banner ativo no SSH:"
"$SSHD_BIN" -T 2>/dev/null | grep -i '^banner' || echo "  não encontrado"
echo
for script in "$MOTD_DIR"/*; do
  [[ "$(basename "$script")" == *.* ]] && continue
  [[ -f "$script" && -x "$script" ]] && "$script"
done
echo "Concluído. Teste em uma nova sessão SSH antes de fechar esta."
