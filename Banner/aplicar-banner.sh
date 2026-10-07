#!/usr/bin/env bash
# Nextec | Aplica o aviso de acesso (antes da senha) e o quadro informativo (depois do login)
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
MOTD_DIR="/etc/update-motd.d"
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-nextec-aviso.conf"
STAMP="$(date +%Y%m%d%H%M%S)"

TIPO="${TIPO:-}"
NOME="${NOME:-}"
FUNCAO="${FUNCAO:-}"
AMBIENTE="${AMBIENTE:-}"

falha() { echo "Erro: $*" >&2; exit 1; }

# Remove quebras de linha e caracteres de controle antes de gravar em /etc/environment
limpar() { printf '%s' "$1" | tr -d '\000-\037\\'; }

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
command -v sshd >/dev/null || falha "OpenSSH Server (sshd) não encontrado."

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
cp -a /etc/environment "/etc/environment.bak.${STAMP}"
sed -i '/^NEXTEC_\(NOME_SERVIDOR\|FUNCAO\|AMBIENTE\)=/d' /etc/environment
[[ -n "$NOME" ]] && printf 'NEXTEC_NOME_SERVIDOR=%s\n' "$NOME" >> /etc/environment
printf 'NEXTEC_FUNCAO=%s\nNEXTEC_AMBIENTE=%s\n' "$FUNCAO" "$AMBIENTE" >> /etc/environment
echo "Variáveis gravadas em /etc/environment"

# ---------- 3. Remove restos de versões anteriores ----------
rm -f "${MOTD_DIR}/01-nextec" /etc/ssh/sshd_config.d/10-banner.conf
for antigo in /etc/nextec/motd.conf /etc/nextec/motd-header.sh; do
  if [[ -f "$antigo" ]]; then
    mv "$antigo" "${antigo}.bak.${STAMP}"
    echo "Arquivo antigo desativado: ${antigo}"
  fi
done

# ---------- 4. Instala o quadro informativo ----------
for arquivo in "${ARQUIVOS[@]}"; do
  destino="${MOTD_DIR}/${arquivo}"
  [[ -f "$destino" ]] && cp -a "$destino" "${destino}.bak.${STAMP}"
  install -o root -g root -m 755 "${TMP}/${arquivo}" "$destino"
  echo "Instalado: ${destino}"
done

# ---------- 5. Desativa os demais scripts de MOTD ----------
for path in "$MOTD_DIR"/*; do
  name="$(basename "$path")"
  [[ " ${KEEP[*]} " == *" ${name} "* ]] && continue
  [[ -f "$path" && -x "$path" ]] || continue
  if dpkg -S "$path" >/dev/null 2>&1 && ! dpkg-statoverride --list "$path" >/dev/null 2>&1; then
    dpkg-statoverride --update --add root root 0644 "$path"
  fi
  chmod 0644 "$path"
  echo "Desativado: ${name}"
done

if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
fi
systemctl disable --now motd-news.timer >/dev/null 2>&1 || true

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

printf '# Nextec: aviso de acesso antes da senha\nBanner /etc/issue.net\n' > "$SSHD_DROPIN"
chown root:root "$SSHD_DROPIN"
chmod 644 "$SSHD_DROPIN"

if ! sshd -t; then
  rm -f "$SSHD_DROPIN"
  falha "configuração do SSH inválida. Aviso desfeito, nada foi recarregado."
fi
systemctl try-reload-or-restart ssh 2>/dev/null || systemctl try-reload-or-restart sshd

# ---------- 7. Conferência ----------
echo
echo "Banner ativo no SSH:"
sshd -T 2>/dev/null | grep -i '^banner' || echo "  não encontrado"
echo
run-parts --lsbsysinit "$MOTD_DIR"
echo "Concluído. Teste em uma nova sessão SSH antes de fechar esta."
