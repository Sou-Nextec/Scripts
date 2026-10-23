#!/usr/bin/env bash
# Nextec - Verificação e correção de vulnerabilidades
#   Kernel Linux: CVE-2026-99999
#   PHP: CVE-2026-109618 e CVE-2026-109619 (correção) | CVE-2026-115560 (mitigação)
set -euo pipefail
shopt -s nullglob

readonly CVE_KERNEL="CVE-2026-99999"
readonly CVES_PHP=("CVE-2026-109618" "CVE-2026-109619")
readonly CVE_PHP_SEM_CORRECAO="CVE-2026-115560"
declare -Ar PHP_MINIMA=( [8.2]="8.2.35" [8.3]="8.3.36" [8.4]="8.4.27" [8.5]="8.5.12" )

readonly DIR="/usr/local/sbin/nextec-cve"
readonly SCRIPT="${DIR}/nextec-cve.sh"
readonly SELECAO="${DIR}/selecao.env"
readonly ENV_EMAIL="/etc/nextec/notificacao.env"
readonly LOG="/var/log/nextec-cve.log"
readonly INI_MITIGACAO="99-nextec-upload-progress.ini"
readonly UN_ATUALIZAR="nextec-cve-atualizar"
readonly UN_REINICIAR="nextec-cve-reiniciar"
readonly UN_POS="nextec-cve-pos-reinicio"

# Envio de e-mail (Brevo). As chaves não ficam no script: vêm das variáveis de ambiente
# NEXTEC_BREVO_API_KEY (API, porta 443) e NEXTEC_SMTP_SENHA (SMTP), ou são pedidas na tela.
readonly SMTP_SERVIDOR_PADRAO="smtp-relay.brevo.com"
readonly SMTP_PORTAS=(587 2525 465)
readonly SMTP_TIMEOUT_CONEXAO=8
readonly SMTP_TIMEOUT_TOTAL=60
readonly SMTP_USUARIO_PADRAO="a00fba001@smtp-brevo.com"
readonly EMAIL_DE_PADRAO="nsoc@nex.tec.br"
readonly EMAIL_DE_NOME="Nextec | Operations Center"
readonly EMAIL_PARA_PADRAO="operacoes.suporte@nex.tec.br"
readonly BREVO_API_URL="https://api.brevo.com/v3/smtp/email"
readonly LOGO_URL="https://raw.githubusercontent.com/Sou-Nextec/img/main/logo.png"
BREVO_API_KEY="${NEXTEC_BREVO_API_KEY:-}"
SMTP_SENHA="${NEXTEC_SMTP_SENHA:-}"

VERDE=$'\033[1;32m'; VERMELHO=$'\033[1;31m'; AMARELO=$'\033[1;33m'; FIM=$'\033[0m'
readonly SEP=$'\x1f'
EMAIL_ATIVO=0

# ---------------------------------------------------------------- utilitários
log()   { printf '%s | %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }
aviso() { printf '%s%s%s\n' "$AMARELO" "$1" "$FIM" >&2; }
linha() { RELATORIO+="$1"$'\n'; }
h()     { RELATORIO_HTML+="$1"$'\n'; }

html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

status_cor() {
  case "$1" in
    CORRIGIDO|PROTEGIDO)                           printf '%s%s%s' "$VERDE" "$1" "$FIM" ;;
    "NÃO CORRIGIDO"|"SEM PROTEÇÃO"|"SEM SUPORTE"|PENDENTE) printf '%s%s%s' "$VERMELHO" "$1" "$FIM" ;;
    *)                                             printf '%s%s%s' "$AMARELO" "$1" "$FIM" ;;
  esac
}

status_html() {
  local cor
  case "$1" in
    CORRIGIDO|PROTEGIDO)                                    cor="#1E7B45" ;;
    "NÃO CORRIGIDO"|"SEM PROTEÇÃO"|"SEM SUPORTE"|PENDENTE)  cor="#B42318" ;;
    *)                                                      cor="#8A5A00" ;;
  esac
  printf '<strong style="color:%s;">%s</strong>' "$cor" "$(html_esc "$1")"
}

gerenciador() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  else echo ""; fi
}

pacote_do_arquivo() {
  local arq="$1"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -S "$arq" 2>/dev/null | head -n1 | cut -d: -f1 || true
  elif command -v rpm >/dev/null 2>&1; then
    if rpm -qf "$arq" >/dev/null 2>&1; then rpm -qf "$arq" | head -n1; fi
  fi
}

changelog_do_pacote() {
  local pkg="$1" texto="" f
  if command -v dpkg >/dev/null 2>&1; then
    texto="$(timeout 30 apt-get -o Acquire::http::Timeout=10 changelog "$pkg" 2>/dev/null || true)"
    if [ -z "$texto" ]; then
      for f in /usr/share/doc/"$pkg"/changelog*.gz; do
        texto="$(zcat "$f" 2>/dev/null || true)"
      done
    fi
  elif command -v rpm >/dev/null 2>&1; then
    texto="$(rpm -q --changelog "$pkg" 2>/dev/null || true)"
  fi
  printf '%s' "$texto"
}

pacotes_apt_instalados() {
  dpkg-query -W -f='${db:Status-Abbrev}|${Package}\n' "$@" 2>/dev/null | awk -F'|' '$1 ~ /^ii/ {print $2}' || true
}

# ---------------------------------------------------------------- verificação: kernel
# Versões corrigidas publicadas pelos fabricantes, para quando o changelog não cita o CVE.
# Proxmox: PSA-2026-00068-1 (proxmox-kernel 7.0.14-24). Debian 13: DSA-6568-1 (6.12.113-1).
kernel_corrigido_por_versao() {
  local release="$1" pacote="$2" versao_pacote
  case "$release" in
    7.0.*-pve)
      if [ "$(printf '%s\n7.0.14-24\n' "${release%-pve}" | sort -V | head -n1)" = "7.0.14-24" ]; then
        KERNEL_OBS="versão igual ou superior à corrigida (Proxmox PSA-2026-00068-1)"; return 0
      fi
      KERNEL_OBS="corrigido a partir do proxmox-kernel 7.0.14-24"; return 1 ;;
    *-pve)
      KERNEL_OBS="série de kernel do Proxmox sem suporte: migrar para a série 7.0"; return 1 ;;
  esac
  if [[ "$pacote" == linux-image-6.12* ]] && command -v dpkg-query >/dev/null 2>&1; then
    versao_pacote="$(dpkg-query -W -f='${Version}' "$pacote" 2>/dev/null || true)"
    if [ -n "$versao_pacote" ] && dpkg --compare-versions "$versao_pacote" ge "6.12.113-1"; then
      KERNEL_OBS="versão igual ou superior à corrigida (Debian DSA-6568-1)"; return 0
    fi
  fi
  return 1
}

# Verifica se o repositório da distribuição já tem kernel mais novo para instalar.
kernel_atualizacao_disponivel() {
  local pacotes rc=0
  case "$(gerenciador)" in
    apt)
      timeout 90 apt-get -o Acquire::http::Timeout=10 update -qq >/dev/null 2>&1 || true
      pacotes="$(pacotes_apt_instalados 'linux-image-*' 'proxmox-kernel-*' 'proxmox-default-kernel' 'pve-kernel-*')"
      if [ -z "$pacotes" ]; then return 1; fi
      # shellcheck disable=SC2086
      apt-get -s install --only-upgrade $pacotes 2>/dev/null | grep -q '^Inst ' ;;
    dnf|yum)
      "$(gerenciador)" -q check-update kernel >/dev/null 2>&1 || rc=$?
      [ "$rc" = 100 ] ;;
    *) return 0 ;;
  esac
}

verificar_kernel() {
  local texto
  KERNEL_VERSAO="$(uname -r)"
  KERNEL_PACOTE="$(pacote_do_arquivo "/boot/vmlinuz-${KERNEL_VERSAO}")"
  KERNEL_OBS=""
  if [ -z "$KERNEL_PACOTE" ]; then
    KERNEL_STATUS="NÃO VERIFICADO"; KERNEL_OBS="pacote do kernel não identificado"; return 0
  fi
  texto="$(changelog_do_pacote "$KERNEL_PACOTE")"
  if [ -n "$texto" ] && grep -q "$CVE_KERNEL" <<<"$texto"; then
    KERNEL_STATUS="CORRIGIDO"
  elif kernel_corrigido_por_versao "$KERNEL_VERSAO" "$KERNEL_PACOTE"; then
    KERNEL_STATUS="CORRIGIDO"
  elif [ -z "$texto" ] && [ -z "$KERNEL_OBS" ]; then
    KERNEL_STATUS="NÃO VERIFICADO"; KERNEL_OBS="sem acesso ao changelog"
  else
    KERNEL_STATUS="NÃO CORRIGIDO"
  fi
  KERNEL_SEM_PACOTE=0
  if [ "$KERNEL_STATUS" = "NÃO CORRIGIDO" ] && ! kernel_atualizacao_disponivel; then
    KERNEL_SEM_PACOTE=1
    KERNEL_OBS="${KERNEL_OBS:+${KERNEL_OBS}; }distribuição ainda não publicou kernel corrigido"
  fi
}

# ---------------------------------------------------------------- verificação: PHP
status_php() {
  local versao="$1" ramo="$2" pacote="$3" minima texto
  if [ -n "$pacote" ]; then
    texto="$(changelog_do_pacote "$pacote")"
    if grep -q "${CVES_PHP[0]}" <<<"$texto" && grep -q "${CVES_PHP[1]}" <<<"$texto"; then
      echo "CORRIGIDO"; return 0
    fi
  fi
  minima="${PHP_MINIMA[$ramo]:-}"
  if [ -z "$minima" ]; then
    if [ "$(printf '%s\n8.5\n' "$ramo" | sort -V | tail -n1)" = "$ramo" ]; then echo "CORRIGIDO"; else echo "SEM SUPORTE"; fi
    return 0
  fi
  if [ "$(printf '%s\n%s\n' "$minima" "$versao" | sort -V | head -n1)" = "$minima" ]; then
    echo "CORRIGIDO"
  else
    echo "NÃO CORRIGIDO"
  fi
}

mitigacao_php() {
  local bin="$1" ramo="$2" dir valor avaliou=0 aberto=0
  local codigo='echo ini_get("session.upload_progress.enabled") ? "On" : "Off";'
  for dir in /etc/php/"${ramo}"/*/; do
    dir="${dir%/}"
    if [ ! -f "${dir}/php.ini" ]; then continue; fi
    valor="$(PHP_INI_SCAN_DIR="${dir}/conf.d" "$bin" -c "${dir}/php.ini" -r "$codigo" 2>/dev/null || true)"
    avaliou=1
    if [ "$valor" != "Off" ]; then aberto=1; fi
  done
  if [ "$avaliou" = 0 ]; then
    valor="$("$bin" -r "$codigo" 2>/dev/null || true)"
    if [ "$valor" != "Off" ]; then aberto=1; fi
  fi
  if [ "$aberto" = 1 ]; then echo "SEM PROTEÇÃO"; else echo "PROTEGIDO"; fi
}

# Cada item: instalação | versão | correção | mitigação | origem
coletar_php() {
  PHP_ITENS=(); PHP_PRECISA=0; PHP_PENDENTE=0; PHP_SEM_SUPORTE=0
  local -A vistos=()
  local b real versao ramo pacote status mitig origem
  local candidatos=(/usr/bin/php /usr/bin/php[0-9]* /usr/local/bin/php
                    /opt/remi/*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/bin/php /opt/plesk/php/*/bin/php)
  for b in "${candidatos[@]}"; do
    if [[ ! "$(basename "$b")" =~ ^php([0-9]+(\.[0-9]+)?)?$ ]] || [ ! -x "$b" ]; then continue; fi
    real="$(readlink -f "$b")"
    if [ -n "${vistos[$real]:-}" ]; then continue; fi
    vistos[$real]=1
    versao="$("$real" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    versao="${versao%%[^0-9.]*}"
    if [ -z "$versao" ]; then continue; fi
    ramo="$(cut -d. -f1,2 <<<"$versao")"
    pacote="$(pacote_do_arquivo "$real")"
    status="$(status_php "$versao" "$ramo" "$pacote")"
    mitig="$(mitigacao_php "$real" "$ramo")"
    if [ -n "$pacote" ]; then origem="pacote ${pacote}"; else origem="sem pacote: atualizar pelo painel ou manualmente"; fi
    PHP_ITENS+=("${real}${SEP}${versao}${SEP}${status}${SEP}${mitig}${SEP}${origem}")
    if [ "$status" != "CORRIGIDO" ] || [ "$mitig" = "SEM PROTEÇÃO" ]; then PHP_PENDENTE=1; fi
    if [ "$status" = "SEM SUPORTE" ]; then PHP_SEM_SUPORTE=1; fi
    if [ "$status" != "CORRIGIDO" ] && [ -n "$pacote" ]; then PHP_PRECISA=1; fi
    if [ "$mitig" = "SEM PROTEÇÃO" ]; then PHP_PRECISA=1; fi
  done
}

coletar_php_docker() {
  if ! command -v docker >/dev/null 2>&1; then return 0; fi
  local c versao ramo status
  while read -r c; do
    if [ -z "$c" ]; then continue; fi
    versao="$(timeout 15 docker exec "$c" sh -c 'command -v php >/dev/null 2>&1 && php -r "echo PHP_VERSION;"' 2>/dev/null || true)"
    versao="${versao%%[^0-9.]*}"
    if [ -z "$versao" ]; then continue; fi
    ramo="$(cut -d. -f1,2 <<<"$versao")"
    status="$(status_php "$versao" "$ramo" "")"
    PHP_ITENS+=("container ${c}${SEP}${versao}${SEP}${status}${SEP}não se aplica${SEP}atualizar a imagem do container")
    if [ "$status" != "CORRIGIDO" ]; then PHP_PENDENTE=1; fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null || true)
}

containers_parados() {
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --filter status=exited --format '{{.Names}} ({{.Status}})' 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- relatório (terminal e e-mail)
estilo_th='style="background:#0D0035;color:#FFFFFF;font-weight:600;text-align:left;padding:8px 10px;border:1px solid #0D0035;font-size:13px;"'
estilo_td='style="padding:8px 10px;border:1px solid #D9D9DE;font-size:13px;vertical-align:top;"'
estilo_tdk='style="padding:8px 10px;border:1px solid #D9D9DE;font-size:13px;background:#F4F4F4;width:150px;vertical-align:top;"'
estilo_tabela='role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%;font-family:Aptos,'"'"'Segoe UI'"'"',Arial,sans-serif;color:#000000;"'

html_secao() {
  h "<tr><td style=\"padding:22px 28px 0;font-family:Aptos,'Segoe UI',Arial,sans-serif;color:#000000;\">"
  h "<h2 style=\"margin:0 0 10px;font-size:16px;font-weight:600;color:#000000;\">$(html_esc "$1")</h2>"
}

montar_relatorio() {
  local contexto="${1:-}" distro host agora item instalacao versao status mitig origem parados ultimas l
  RELATORIO=""; RELATORIO_HTML=""
  host="$(hostname)"
  agora="$(date '+%d/%m/%Y %H:%M')"
  distro="$( (. /etc/os-release && printf '%s' "${PRETTY_NAME:-desconhecida}") 2>/dev/null || echo desconhecida)"

  verificar_kernel
  coletar_php
  coletar_php_docker
  if [ "${#PHP_ITENS[@]}" -eq 0 ]; then
    PHP_RESUMO="NÃO INSTALADO"
  elif [ "$PHP_PENDENTE" = 1 ]; then
    PHP_RESUMO="PENDENTE"
  else
    PHP_RESUMO="CORRIGIDO"
  fi
  parados="$(containers_parados)"

  # ---- terminal
  linha "=== ${host} | ${distro} | ${agora} ==="
  linha ""
  linha "Kernel (${CVE_KERNEL}): $(status_cor "$KERNEL_STATUS")"
  linha "  kernel ${KERNEL_VERSAO}${KERNEL_PACOTE:+ (${KERNEL_PACOTE})}${KERNEL_OBS:+, ${KERNEL_OBS}}"
  linha ""
  linha "PHP (${CVES_PHP[0]} e ${CVES_PHP[1]} | mitigação do ${CVE_PHP_SEM_CORRECAO}):"
  if [ "${#PHP_ITENS[@]}" -eq 0 ]; then
    linha "  Não instalado"
  else
    for item in "${PHP_ITENS[@]}"; do
      IFS="$SEP" read -r instalacao versao status mitig origem <<<"$item"
      linha "  ${instalacao} ${versao}: $(status_cor "$status") | mitigação: $(status_cor "$mitig") | ${origem}"
    done
    if [ "$PHP_SEM_SUPORTE" = 1 ]; then linha "  Ramo sem suporte: migrar para PHP 8.2 ou superior."; fi
  fi
  if [ -n "$contexto" ]; then linha ""; linha "Etapa: ${contexto}"; fi
  if [ -n "$parados" ]; then linha ""; linha "Containers parados:"; linha "$parados"; fi

  # ---- e-mail
  h '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Relatório de segurança</title></head>'
  h '<body style="margin:0;padding:0;background:#F4F4F4;">'
  h '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F4F4;"><tr><td align="center" style="padding:24px 12px;">'
  h '<table role="presentation" width="640" cellpadding="0" cellspacing="0" style="width:100%;max-width:640px;background:#FFFFFF;border:1px solid #E3E3E8;border-collapse:collapse;">'
  h "<tr><td style=\"background:#0D0035;padding:20px 28px;\"><img src=\"${LOGO_URL}\" width=\"210\" height=\"40\" alt=\"Nextec\" style=\"display:block;border:0;outline:none;\"></td></tr>"
  h '<tr><td style="height:3px;line-height:3px;font-size:0;background:#5C50FF;">&nbsp;</td></tr>'
  h "<tr><td style=\"padding:26px 28px 4px;font-family:Aptos,'Segoe UI',Arial,sans-serif;color:#000000;\">"
  h '<p style="margin:0 0 4px;font-size:13px;color:#5B5B66;">Relatório de segurança do servidor</p>'
  h "<h1 style=\"margin:0;font-size:22px;font-weight:600;color:#000000;\">$(html_esc "$host")</h1>"
  h "<p style=\"margin:10px 0 0;font-size:14px;\">Kernel: $(status_html "$KERNEL_STATUS")&nbsp;&nbsp;&nbsp;PHP: $(status_html "$PHP_RESUMO")</p>"
  h '</td></tr>'

  html_secao "Servidor"
  h "<table ${estilo_tabela}>"
  h "<tr><td ${estilo_tdk}>Servidor</td><td ${estilo_td}>$(html_esc "$host")</td></tr>"
  h "<tr><td ${estilo_tdk}>Sistema</td><td ${estilo_td}>$(html_esc "$distro")</td></tr>"
  h "<tr><td ${estilo_tdk}>Data</td><td ${estilo_td}>$(html_esc "$agora")</td></tr>"
  if [ -n "$contexto" ]; then h "<tr><td ${estilo_tdk}>Etapa</td><td ${estilo_td}>$(html_esc "$contexto")</td></tr>"; fi
  h '</table></td></tr>'

  html_secao "Kernel Linux (${CVE_KERNEL})"
  h "<table ${estilo_tabela}>"
  h "<tr><th ${estilo_th}>Kernel em uso</th><th ${estilo_th}>Pacote</th><th ${estilo_th}>Situação</th></tr>"
  h "<tr><td ${estilo_td}>$(html_esc "$KERNEL_VERSAO")</td><td ${estilo_td}>$(html_esc "${KERNEL_PACOTE:-não identificado}")</td><td ${estilo_td}>$(status_html "$KERNEL_STATUS")$( [ -n "$KERNEL_OBS" ] && printf '<br><span style="color:#5B5B66;">%s</span>' "$(html_esc "$KERNEL_OBS")" )</td></tr>"
  h '</table></td></tr>'

  html_secao "PHP (${CVES_PHP[0]} e ${CVES_PHP[1]})"
  if [ "${#PHP_ITENS[@]}" -eq 0 ]; then
    h '<p style="margin:0;font-size:13px;">PHP não instalado neste servidor.</p>'
  else
    h "<table ${estilo_tabela}>"
    h "<tr><th ${estilo_th}>Instalação</th><th ${estilo_th}>Versão</th><th ${estilo_th}>Correção</th><th ${estilo_th}>Mitigação</th><th ${estilo_th}>Origem</th></tr>"
    for item in "${PHP_ITENS[@]}"; do
      IFS="$SEP" read -r instalacao versao status mitig origem <<<"$item"
      h "<tr><td ${estilo_td}>$(html_esc "$instalacao")</td><td ${estilo_td}>$(html_esc "$versao")</td><td ${estilo_td}>$(status_html "$status")</td><td ${estilo_td}>$(status_html "$mitig")</td><td ${estilo_td}>$(html_esc "$origem")</td></tr>"
    done
    h '</table>'
    h "<p style=\"margin:8px 0 0;font-size:12px;color:#5B5B66;\">Mitigação: proteção para o ${CVE_PHP_SEM_CORRECAO}, que ainda não tem correção oficial.</p>"
    if [ "$PHP_SEM_SUPORTE" = 1 ]; then h '<p style="margin:8px 0 0;font-size:13px;">Há ramo sem suporte: migrar para PHP 8.2 ou superior.</p>'; fi
  fi
  h '</td></tr>'

  if [ -n "$parados" ]; then
    html_secao "Containers parados"
    h "<table ${estilo_tabela}>"
    while IFS= read -r l; do h "<tr><td ${estilo_td}>$(html_esc "$l")</td></tr>"; done <<<"$parados"
    h '</table></td></tr>'
  fi

  if [ -n "$contexto" ] && [ "$contexto" != "verificação" ] && [ -r "$LOG" ]; then
    ultimas="$(tail -n 20 "$LOG" 2>/dev/null | cut -c1-220 || true)"
    if [ -n "$ultimas" ]; then
      linha ""; linha "Últimas linhas do log:"; linha "$ultimas"
      html_secao "Últimas linhas do log"
      h "<pre style=\"margin:0;padding:12px;background:#F4F4F4;border:1px solid #D9D9DE;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.5;white-space:pre-wrap;word-break:break-word;color:#000000;\">$(html_esc "$ultimas")</pre>"
      h '</td></tr>'
    fi
  fi

  h "<tr><td style=\"padding:26px 28px 24px;font-family:Aptos,'Segoe UI',Arial,sans-serif;\">"
  h '<p style="margin:0;padding-top:14px;border-top:1px solid #E3E3E8;font-size:12px;color:#5B5B66;">Nextec Soluções em TI</p>'
  h '</td></tr>'
  h '</table></td></tr></table></body></html>'
}

# ---------------------------------------------------------------- e-mail
configurar_email() {
  local resp
  read -r -p "Enviar o relatório por e-mail? (s/n) " resp </dev/tty
  if [[ ! "$resp" =~ ^[sS]$ ]]; then return 1; fi
  read -r -p "Destinatário [${EMAIL_PARA_PADRAO}]: " EMAIL_PARA </dev/tty
  EMAIL_PARA="${EMAIL_PARA:-$EMAIL_PARA_PADRAO}"
  pedir_chave_api
  EMAIL_ATIVO=1
}

pedir_chave_api() {
  if [ -n "$BREVO_API_KEY" ] || [ -n "$SMTP_SENHA" ]; then return 0; fi
  read -r -s -p "Chave da API da Brevo (xkeysib-...): " BREVO_API_KEY </dev/tty; echo >/dev/tty
}

carregar_email() {
  EMAIL_ATIVO=0
  if [ -f "$ENV_EMAIL" ]; then . "$ENV_EMAIL"; EMAIL_ATIVO=1; fi
}

salvar_email() {
  if [ "$EMAIL_ATIVO" != 1 ]; then return 0; fi
  install -d -m 700 "$(dirname "$ENV_EMAIL")"
  ( umask 077; printf 'EMAIL_PARA=%q\nBREVO_API_KEY=%q\nSMTP_SENHA=%q\n' "$EMAIL_PARA" "$BREVO_API_KEY" "$SMTP_SENHA" >"$ENV_EMAIL" )
}

escapar_curl() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

montar_mensagem() {
  local assunto="$1" arquivo="$2" b_alt="alt-$(date +%s)-$$"
  {
    printf 'From: "%s" <%s>\r\n' "$EMAIL_DE_NOME" "$EMAIL_DE_PADRAO"
    printf 'To: %s\r\n' "$EMAIL_PARA"
    printf 'Subject: =?UTF-8?B?%s?=\r\n' "$(printf '%s' "$assunto" | base64 -w0)"
    printf 'Date: %s\r\n' "$(LC_ALL=C date -R)"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: multipart/alternative; boundary="%s"\r\n\r\n' "$b_alt"
    printf -- '--%s\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$b_alt"
    sed 's/\x1b\[[0-9;]*m//g' <<<"$RELATORIO" | base64 -w76 | sed 's/$/\r/'
    printf -- '--%s\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' "$b_alt"
    printf '%s' "$RELATORIO_HTML" | base64 -w76 | sed 's/$/\r/'
    printf -- '--%s--\r\n' "$b_alt"
  } >"$arquivo"
}

porta_aberta() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Envio por SMTP (portas 587, 2525 e 465). Portas fechadas são puladas em 3 segundos.
enviar_smtp() {
  local assunto="$1" cfg msg url porta erro rc=1
  if [ -z "$SMTP_SENHA" ]; then return 1; fi
  cfg="$(mktemp)"; msg="$(mktemp)"; chmod 600 "$cfg" "$msg"
  printf 'user = "%s:%s"\n' "$(escapar_curl "$SMTP_USUARIO_PADRAO")" "$(escapar_curl "$SMTP_SENHA")" >"$cfg"
  montar_mensagem "$assunto" "$msg"
  for porta in "${SMTP_PORTAS[@]}"; do
    if ! porta_aberta "$SMTP_SERVIDOR_PADRAO" "$porta"; then
      log "porta SMTP ${porta} fechada"
      continue
    fi
    if [ "$porta" = 465 ]; then url="smtps://${SMTP_SERVIDOR_PADRAO}:465"; else url="smtp://${SMTP_SERVIDOR_PADRAO}:${porta}"; fi
    if erro="$(curl --silent --show-error --ssl-reqd --connect-timeout "$SMTP_TIMEOUT_CONEXAO" --max-time "$SMTP_TIMEOUT_TOTAL" \
         --url "$url" -K "$cfg" --mail-from "$EMAIL_DE_PADRAO" --mail-rcpt "$EMAIL_PARA" --upload-file "$msg" 2>&1)"; then
      rc=0
      log "e-mail enviado por SMTP na porta ${porta} para ${EMAIL_PARA}: ${assunto}"
      break
    fi
    log "envio SMTP na porta ${porta} falhou: ${erro}"
  done
  rm -f "$cfg" "$msg"
  return "$rc"
}

# Envio pela API HTTPS da Brevo (porta 443), usado quando o SMTP está bloqueado.
enviar_api() {
  local assunto="$1" html texto cfg payload resposta codigo
  if [ -z "$BREVO_API_KEY" ]; then log "chave da API da Brevo não configurada"; return 1; fi
  html="$RELATORIO_HTML"
  texto="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$RELATORIO")"
  cfg="$(mktemp)"; payload="$(mktemp)"; resposta="$(mktemp)"; chmod 600 "$cfg" "$payload" "$resposta"
  printf 'header = "api-key: %s"\n' "$(escapar_curl "$BREVO_API_KEY")" >"$cfg"
  printf '{"sender":{"name":"%s","email":"%s"},"to":[{"email":"%s"}],"subject":"%s","htmlContent":"%s","textContent":"%s"}' \
    "$(json_esc "$EMAIL_DE_NOME")" "$(json_esc "$EMAIL_DE_PADRAO")" "$(json_esc "$EMAIL_PARA")" \
    "$(json_esc "$assunto")" "$(json_esc "$html")" "$(json_esc "$texto")" >"$payload"
  codigo="$(curl --silent --show-error --connect-timeout 10 --max-time 60 -K "$cfg" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -o "$resposta" -w '%{http_code}' --data-binary "@${payload}" "$BREVO_API_URL" 2>&1 || true)"
  if [ "$codigo" = 201 ]; then
    log "e-mail enviado pela API para ${EMAIL_PARA}: ${assunto}"
    rm -f "$cfg" "$payload" "$resposta"
    return 0
  fi
  log "envio pela API falhou (HTTP ${codigo}): $(head -c 300 "$resposta" 2>/dev/null)"
  rm -f "$cfg" "$payload" "$resposta"
  return 1
}

enviar_email() {
  local assunto="$1"
  if [ "$EMAIL_ATIVO" != 1 ]; then return 0; fi
  if enviar_smtp "$assunto"; then return 0; fi
  if enviar_api "$assunto"; then return 0; fi
  log "falha no envio do e-mail por SMTP e pela API: ${assunto}"
  aviso "Falha no envio por SMTP e pela API. Detalhes em ${LOG}."
  return 1
}

assunto() { printf 'Segurança | %s | Kernel: %s | PHP: %s | %s' "$(hostname)" "$KERNEL_STATUS" "$PHP_RESUMO" "$1"; }

enviar_relatorio() {
  local contexto="$1"
  montar_relatorio "$contexto"
  printf '%s\n' "$RELATORIO"
  enviar_email "$(assunto "$contexto")" || true
}

finalizar() {
  rm -f "$ENV_EMAIL"
  rm -rf "$DIR"
  log "agendamento encerrado, script e dados de e-mail removidos do servidor"
}

# ---------------------------------------------------------------- correção
atualizar_kernel() {
  local pacotes
  case "$(gerenciador)" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || return 1
      pacotes="$(pacotes_apt_instalados 'linux-image-*' 'proxmox-kernel-*' 'proxmox-default-kernel' 'pve-kernel-*')"
      if [ -n "$pacotes" ]; then
        # shellcheck disable=SC2086
        apt-get install --only-upgrade -y $pacotes || return 1
      fi ;;
    dnf)    dnf upgrade -y kernel || return 1 ;;
    yum)    yum update -y kernel || return 1 ;;
    zypper) zypper --non-interactive patch --category security || return 1 ;;
    *)      log "gerenciador de pacotes não suportado"; return 1 ;;
  esac
}

aplicar_mitigacao_php() {
  local d
  for d in /etc/php/*/*/conf.d /etc/php.d /etc/php[0-9]*/conf.d /etc/opt/remi/*/php.d; do
    if [ ! -d "$d" ]; then continue; fi
    printf '; Nextec - mitigação do %s até a correção oficial\nsession.upload_progress.enabled = Off\n' \
      "$CVE_PHP_SEM_CORRECAO" >"${d}/${INI_MITIGACAO}"
    log "mitigação aplicada em ${d}"
  done
}

reiniciar_servicos_php() {
  local s
  while read -r s; do
    if [ -z "$s" ]; then continue; fi
    if systemctl restart "$s"; then log "reiniciado ${s}"; else log "falha ao reiniciar ${s}"; fi
  done < <(systemctl list-units --type=service --state=running --no-legend --plain \
             'php*-fpm*' 'apache2*' 'httpd*' 'lsws*' 'litespeed*' 2>/dev/null | awk '{print $1}')
}

atualizar_php() {
  local pacotes rc=0
  case "$(gerenciador)" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || return 1
      pacotes="$(pacotes_apt_instalados 'php*' 'libapache2-mod-php*')"
      if [ -n "$pacotes" ]; then
        # shellcheck disable=SC2086
        apt-get install --only-upgrade -y $pacotes || rc=1
      fi ;;
    dnf)    dnf upgrade -y 'php*' || rc=1 ;;
    yum)    yum update -y 'php*' || rc=1 ;;
    zypper) zypper --non-interactive update 'php*' || rc=1 ;;
    *)      log "gerenciador de pacotes não suportado"; rc=1 ;;
  esac
  aplicar_mitigacao_php
  reiniciar_servicos_php
  return "$rc"
}

# ---------------------------------------------------------------- etapas agendadas
executar_atualizacao() {
  exec >>"$LOG" 2>&1
  if [ ! -f "$SELECAO" ]; then log "seleção não encontrada"; exit 1; fi
  . "$SELECAO"
  carregar_email
  log "atualização iniciada (kernel=${ATUALIZAR_KERNEL} php=${ATUALIZAR_PHP})"
  local falhou=0
  if [ "$ATUALIZAR_KERNEL" = 1 ]; then
    if ! atualizar_kernel; then falhou=1; log "falha na atualização do kernel"; fi
  fi
  if [ "$ATUALIZAR_PHP" = 1 ]; then
    if ! atualizar_php; then falhou=1; log "falha na atualização do PHP"; fi
  fi
  log "atualização finalizada"
  if [ "$ATUALIZAR_KERNEL" = 1 ] && [ "${REINICIAR_APOS:-0}" = 1 ]; then
    if [ "$falhou" = 1 ]; then
      enviar_relatorio "falha na atualização, reinício não executado"
      finalizar
    else
      reiniciar_se_kernel_novo
    fi
  elif [ "$ATUALIZAR_KERNEL" = 1 ]; then
    if [ "$falhou" = 1 ]; then enviar_relatorio "falha na atualização, reinício segue agendado"; fi
  else
    if [ "$falhou" = 1 ]; then enviar_relatorio "falha na atualização do PHP"; else enviar_relatorio "PHP atualizado"; fi
    finalizar
  fi
  [ "$falhou" = 0 ]
}

instalar_pos_reinicio() {
  cat >"/etc/systemd/system/${UN_POS}.service" <<EOF
[Unit]
Description=Nextec - Relatório após reinício (${CVE_KERNEL})
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT} --pos-reinicio
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${UN_POS}.service"
}

executar_reinicio() {
  exec >>"$LOG" 2>&1
  carregar_email
  reiniciar_se_kernel_novo
}

reiniciar_se_kernel_novo() {
  local mais_recente
  mais_recente="$(printf '%s\n' /boot/vmlinuz-* | sort -V | tail -n1)"
  if [ -n "$mais_recente" ] && [ "$mais_recente" != "/boot/vmlinuz-$(uname -r)" ]; then
    instalar_pos_reinicio
    log "reiniciando para ${mais_recente}"
    systemctl reboot
  else
    log "nenhum kernel novo instalado, reinício cancelado"
    enviar_relatorio "reinício cancelado: nenhum kernel novo instalado"
    finalizar
  fi
}

executar_pos_reinicio() {
  exec >>"$LOG" 2>&1
  carregar_email
  sleep 90
  enviar_relatorio "servidor reiniciado"
  systemctl disable "${UN_POS}.service" || true
  rm -f "/etc/systemd/system/${UN_POS}.service"
  systemctl daemon-reload || true
  finalizar
}

cancelar() {
  systemctl stop "${UN_ATUALIZAR}.timer" "${UN_REINICIAR}.timer" 2>/dev/null || true
  systemctl disable "${UN_POS}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${UN_POS}.service"
  systemctl daemon-reload || true
  finalizar
  echo "Agendamentos cancelados."
}

teste_email() {
  EMAIL_PARA="${1:-$EMAIL_PARA_PADRAO}"
  pedir_chave_api
  EMAIL_ATIVO=1
  montar_relatorio "teste de envio"
  if enviar_email "$(assunto "teste de envio")"; then
    printf '%sE-mail de teste enviado para %s.%s\n' "$VERDE" "$EMAIL_PARA" "$FIM"
  else
    printf '%sFalha no envio do e-mail de teste.%s\n' "$VERMELHO" "$FIM"; exit 1
  fi
}

# ---------------------------------------------------------------- interação
proxima_ocorrencia() {
  local hora="$1" ref="$2" dia alvo
  dia="$(date -d "@${ref}" +%F)"
  alvo="$(date -d "${dia} ${hora}" +%s)"
  if [ "$alvo" -le "$ref" ]; then
    alvo="$(date -d "$(date -d "${dia} +1 day" +%F) ${hora}" +%s)"
  fi
  echo "$alvo"
}

ler_hora() {
  local pergunta="$1" padrao="$2" palavra="$3" valor
  while true; do
    read -r -p "${pergunta} [${padrao}]: " valor </dev/tty
    valor="${valor:-$padrao}"
    if [ -n "$palavra" ] && [ "$valor" = "$palavra" ]; then echo "$valor"; return 0; fi
    if [[ "$valor" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then echo "$valor"; return 0; fi
    aviso "Formato inválido."
  done
}

agendar() {
  local unidade="$1" descricao="$2" quando="$3" acao="$4"
  systemctl stop "${unidade}.timer" 2>/dev/null || true
  systemctl reset-failed "${unidade}.service" "${unidade}.timer" 2>/dev/null || true
  systemd-run --unit="$unidade" --description="$descricao" \
    --on-calendar="$(date -d "@${quando}" '+%F %T')" "$SCRIPT" "$acao" >/dev/null
}

escolher_correcao() {
  ATUALIZAR_KERNEL=0; ATUALIZAR_PHP=0
  local k=0 p=0 opcao codigos=()
  if [ "$KERNEL_STATUS" = "NÃO CORRIGIDO" ] && [ "$KERNEL_SEM_PACOTE" = 0 ]; then k=1; fi
  if [ "$PHP_PRECISA" = 1 ]; then p=1; fi
  if [ "$k" = 0 ] && [ "$p" = 0 ]; then
    if [ "$KERNEL_SEM_PACOTE" = 1 ]; then
      printf '%sSem correção disponível ainda:%s a distribuição não publicou o kernel corrigido. Rode de novo quando sair.\n' "$AMARELO" "$FIM"
    else
      printf '%sNada a corrigir por pacote neste servidor.%s\n' "$VERDE" "$FIM"
    fi
    return 1
  fi
  echo "O que deseja corrigir?"
  if [ "$k" = 1 ] && [ "$p" = 1 ]; then
    echo "  1) Kernel e PHP"; echo "  2) Só o kernel"; echo "  3) Só o PHP"; codigos=(x ambos kernel php)
  elif [ "$k" = 1 ]; then
    echo "  1) Kernel"; codigos=(x kernel)
  else
    echo "  1) PHP (atualização e mitigação)"; codigos=(x php)
  fi
  echo "  0) Nada"
  while true; do
    read -r -p "Opção: " opcao </dev/tty
    if [ "$opcao" = 0 ]; then return 1; fi
    if [[ "$opcao" =~ ^[0-9]+$ ]] && [ "$opcao" -lt "${#codigos[@]}" ]; then break; fi
    aviso "Opção inválida."
  done
  case "${codigos[$opcao]}" in
    ambos)  ATUALIZAR_KERNEL=1; ATUALIZAR_PHP=1 ;;
    kernel) ATUALIZAR_KERNEL=1 ;;
    php)    ATUALIZAR_PHP=1 ;;
  esac
}

instalar_script() {
  install -d -m 700 "$DIR"
  if [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$SCRIPT" ]; then
    install -m 700 "${BASH_SOURCE[0]}" "$SCRIPT"
  fi
}

principal() {
  if [ "$(id -u)" -ne 0 ]; then aviso "Execute como root (sudo)."; exit 3; fi
  touch "$LOG"; chmod 600 "$LOG"

  echo "Verificando kernel e PHP (consulta os repositórios, pode levar até 2 minutos)..."
  montar_relatorio "verificação"
  printf '%s\n' "$RELATORIO"

  if configurar_email; then
    echo "Enviando relatório..."
    if enviar_email "$(assunto "verificação")"; then
      printf '%s✔ Relatório enviado para %s.%s\n' "$VERDE" "$EMAIL_PARA" "$FIM"
    else
      aviso "Falha no envio. Seguindo sem e-mail."
      EMAIL_ATIVO=0
    fi
  fi

  if ! escolher_correcao; then
    printf '%s✔ Verificação concluída. Nada agendado neste servidor.%s\n' "$VERDE" "$FIM"
    exit 0
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then aviso "Servidor sem systemd: agende manualmente."; exit 1; fi

  local agora hora_atualizar hora_reiniciar="" quando ref reiniciar_apos=0
  agora="$(date +%s)"
  hora_atualizar="$(ler_hora "Horário da atualização (HH:MM ou agora)" "23:00" "agora")"
  if [ "$ATUALIZAR_KERNEL" = 1 ]; then
    hora_reiniciar="$(ler_hora "Reinício (depois = logo após a atualização, ou HH:MM)" "depois" "depois")"
    if [ "$hora_reiniciar" = "depois" ]; then reiniciar_apos=1; fi
  fi

  instalar_script
  ( umask 077; printf 'ATUALIZAR_KERNEL=%s\nATUALIZAR_PHP=%s\nREINICIAR_APOS=%s\n' "$ATUALIZAR_KERNEL" "$ATUALIZAR_PHP" "$reiniciar_apos" >"$SELECAO" )
  salvar_email

  if [ "$hora_atualizar" = "agora" ]; then
    if [ "$reiniciar_apos" = 1 ]; then aviso "Se houver kernel novo, o servidor reinicia ao fim da atualização e esta sessão cai."; fi
    echo "Atualizando agora (log em ${LOG})..."
    if "$SCRIPT" --executar-atualizacao; then
      printf '%sAtualização concluída.%s\n' "$VERDE" "$FIM"
    else
      printf '%sFalha na atualização.%s Veja %s\n' "$VERMELHO" "$FIM" "$LOG"
    fi
    ref="$(date +%s)"
  else
    quando="$(proxima_ocorrencia "$hora_atualizar" "$agora")"
    agendar "$UN_ATUALIZAR" "Nextec - Atualização de segurança (kernel e PHP)" "$quando" "--executar-atualizacao"
    printf '%sAtualização agendada%s para %s\n' "$VERDE" "$FIM" "$(date -d "@${quando}" '+%d/%m/%Y %H:%M')"
    ref="$quando"
  fi

  if [ "$ATUALIZAR_KERNEL" = 1 ] && [ "$reiniciar_apos" = 1 ]; then
    printf '%sReinício%s logo após a atualização, se houver kernel novo.\n' "$VERDE" "$FIM"
  elif [ "$ATUALIZAR_KERNEL" = 1 ]; then
    quando="$(proxima_ocorrencia "$hora_reiniciar" "$ref")"
    agendar "$UN_REINICIAR" "Nextec - Reinício após atualização do kernel" "$quando" "--executar-reinicio"
    printf '%sReinício agendado%s para %s\n' "$VERDE" "$FIM" "$(date -d "@${quando}" '+%d/%m/%Y %H:%M')"
  fi

  echo "Conferir: systemctl list-timers 'nextec-cve-*'"
  echo "Cancelar: sudo ${SCRIPT} --cancelar"
  printf '%s✔ Concluído.%s\n' "$VERDE" "$FIM"
}

case "${1:-}" in
  "")                      principal ;;
  --executar-atualizacao)  executar_atualizacao ;;
  --executar-reinicio)     executar_reinicio ;;
  --pos-reinicio)          executar_pos_reinicio ;;
  --cancelar)              cancelar ;;
  --teste-email)           teste_email "${2:-}" ;;
  *)                       echo "Uso: sudo bash $0 [--cancelar | --teste-email destinatario]"; exit 64 ;;
esac
