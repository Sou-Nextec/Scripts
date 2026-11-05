#!/usr/bin/env bash
# Nextec | Testes do aplicar-banner.sh
#
# Simula as famílias de distribuição isolando uma cópia do /etc (namespace de montagem),
# então não altera o servidor onde roda. Requer root, unshare, OpenSSH Server, script e busybox.
#
# Cenários:
#   debian   update-motd + sshd_config.d com Include (Ubuntu, Debian)
#   centos8  sem update-motd e sem sshd_config.d, com /etc/motd.d do Cockpit (CentOS 8, RHEL 8)
#   rhel9    sem update-motd, com sshd_config.d e Include (RHEL 9, Rocky 9, Alma 9, Fedora)
#   busybox  quadros executados só com bash + busybox (Alpine e sistemas mínimos)
#
# Uso: sudo bash testes/testar-banner.sh [cenario ...]
# Os arquivos são lidos da pasta local (BANNER_BASE_URL=file://), nada é baixado do GitHub.
set -euo pipefail

PASTA="$(cd "$(dirname "$0")/.." && pwd)"
CENARIOS=("debian" "centos8" "rhel9" "busybox")

FALHAS=0
TOTAL=0
ok()     { TOTAL=$((TOTAL + 1)); printf '    ok    %s\n' "$1"; }
erro()   { TOTAL=$((TOTAL + 1)); FALHAS=$((FALHAS + 1)); printf '    FALHA %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/          /'; return 0; }
checar() { local desc="$1"; shift; local saida; if saida="$("$@" 2>&1)"; then ok "$desc"; else erro "$desc" "$saida"; fi; }
resultado() { echo "    ${TOTAL} testes, ${FALHAS} falhas"; [[ $FALHAS -eq 0 ]]; }

aplicar() {
  TIPO="$1" NOME="TGA" FUNCAO="Painel de senhas" AMBIENTE="Produção" \
    BANNER_BASE_URL="file://${PASTA}" bash "${PASTA}/aplicar-banner.sh"
}

# Monta uma cópia do /etc no lugar do original, só dentro deste namespace
isolar_etc() {
  local w
  w="$(mktemp -d)"
  mount --make-rprivate /
  cp -a /etc "${w}/etc"
  mount --bind "${w}/etc" /etc
  mkdir -p /run/sshd
  ssh-keygen -A >/dev/null
  echo "mensagem antiga" > /etc/motd
}

montar_cenario() {
  case "$1" in
    debian) ;;
    centos8)
      rm -rf /etc/update-motd.d /etc/ssh/sshd_config.d
      sed -i '/^[[:space:]]*Include/d' /etc/ssh/sshd_config
      mkdir -p /etc/motd.d && ln -sf /run/cockpit/motd /etc/motd.d/cockpit ;;
    rhel9)
      rm -rf /etc/update-motd.d
      mkdir -p /etc/motd.d && ln -sf /run/cockpit/motd /etc/motd.d/cockpit ;;
  esac
}

testar_instalacao() {
  local cenario="$1" saida modo dir
  isolar_etc
  montar_cenario "$cenario"

  if saida="$(aplicar cliente 2>&1)"; then ok "aplicar TIPO=cliente"; else erro "aplicar TIPO=cliente" "$saida"; resultado; return; fi
  modo="$(printf '%s\n' "$saida" | sed -n 's/.*modo: \([a-z-]*\).*/\1/p')"
  echo "    modo detectado: ${modo}"
  if [[ "$cenario" == "debian" ]]; then
    checar "modo update-motd" test "$modo" = "update-motd"; dir=/etc/update-motd.d
  else
    checar "modo profile" test "$modo" = "profile"; dir=/etc/nextec/motd.d
  fi

  checar "sshd com Banner /etc/issue.net" sh -c 'sshd -T | grep -qi "^banner /etc/issue.net$"'
  checar "aviso gravado em /etc/issue.net" grep -q "ACESSO RESTRITO" /etc/issue.net
  checar "/etc/motd esvaziado" test ! -s /etc/motd
  checar "variáveis em /etc/environment" grep -qx "NEXTEC_FUNCAO=Painel de senhas" /etc/environment
  checar "quadro executa sem erro e mostra a função" \
    sh -c "out=\$($dir/05-servidor 2>/tmp/nx-err) && [ ! -s /tmp/nx-err ] && echo \"\$out\" | grep -q 'Painel de senhas' && echo \"\$out\" | grep -q 'Disco /:' || { cat /tmp/nx-err; echo \"\$out\"; exit 1; }"

  case "$cenario" in
    debian)
      checar "aviso no drop-in do sshd_config.d" grep -q "^Banner /etc/issue.net" /etc/ssh/sshd_config.d/01-nextec-aviso.conf
      checar "pam_motd (run-parts) mostra o quadro" sh -c 'run-parts --lsbsysinit /etc/update-motd.d | grep -q "Painel de senhas"'
      checar "demais scripts do update-motd desativados" \
        sh -c 'for f in /etc/update-motd.d/*; do n=$(basename "$f"); case "$n" in 05-servidor|98-*) continue;; esac; [ -x "$f" ] && { echo "ainda executável: $n"; exit 1; }; done; exit 0'
      checar "sem runner no profile.d" test ! -e /etc/profile.d/00-nextec-motd.sh ;;
    centos8)
      checar "aviso na primeira linha do sshd_config" sh -c 'head -2 /etc/ssh/sshd_config | grep -q "^Banner /etc/issue.net"'
      checar "nenhum drop-in criado" test ! -e /etc/ssh/sshd_config.d/01-nextec-aviso.conf ;;
    rhel9)
      checar "aviso no drop-in do sshd_config.d" grep -q "^Banner /etc/issue.net" /etc/ssh/sshd_config.d/01-nextec-aviso.conf
      checar "sshd_config sem bloco da Nextec" sh -c '! grep -q "^# Nextec" /etc/ssh/sshd_config' ;;
  esac

  if [[ "$modo" == "profile" ]]; then
    checar "login interativo mostra o quadro" sh -c "script -qec 'bash -lic exit' /dev/null | grep -q 'Painel de senhas'"
    checar "quadro aparece uma vez só no login" sh -c "[ \"\$(script -qec 'bash -lic exit' /dev/null | grep -c 'Servidor:')\" -eq 1 ]"
    checar "login não interativo sem saída extra (scp/sftp)" sh -c "[ \"\$(bash -lc 'echo ok' 2>&1)\" = ok ]"
    checar "login sh (dash) sem erro" sh -c "script -qec 'sh -lic exit' /dev/null | grep -q 'Painel de senhas'"
    checar "/etc/motd.d esvaziado (Cockpit)" sh -c '[ -z "$(ls -A /etc/motd.d)" ]'
  fi

  if saida="$(aplicar nextec 2>&1)"; then ok "reaplicar TIPO=nextec"; else erro "reaplicar TIPO=nextec" "$saida"; resultado; return; fi
  checar "quadro de cliente removido ao trocar o TIPO" test ! -e "$dir/05-servidor"
  checar "quadro Nextec mostra a gestão" sh -c "$dir/10-nextec-info | grep -q 'Gestão:'"
  checar "cabeçalho Nextec executa sem erro" sh -c "$dir/05-nextec >/dev/null 2>/tmp/nx-err && [ ! -s /tmp/nx-err ]"

  aplicar nextec >/dev/null 2>&1 || true
  checar "nenhum backup executável na pasta do quadro" \
    sh -c "for f in $dir/*.*; do [ -e \"\$f\" ] && [ -x \"\$f\" ] && { echo \"\$f\"; exit 1; }; done; exit 0"
  checar "Banner da Nextec gravado uma vez só depois de 3 execuções" \
    sh -c 'n=$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -c "^# Nextec: aviso de acesso"); [ "$n" -eq 1 ] || { echo "encontrado $n vezes"; exit 1; }'
  checar "sshd -t válido no final" sshd -t

  # Configuração do SSH inválida: o script deve falhar e devolver o sshd_config original
  echo "OpcaoInvalidaNextec sim" >> /etc/ssh/sshd_config
  md5sum /etc/ssh/sshd_config > /tmp/nx-antes
  if aplicar cliente >/dev/null 2>&1; then erro "falhar com sshd_config inválido"; else ok "falhar com sshd_config inválido"; fi
  checar "sshd_config restaurado depois da falha" md5sum -c --quiet /tmp/nx-antes
  checar "drop-in removido depois da falha" test ! -e /etc/ssh/sshd_config.d/01-nextec-aviso.conf

  checar "TIPO inválido é recusado" sh -c "! TIPO=outro FUNCAO=x AMBIENTE=y bash '${PASTA}/aplicar-banner.sh' 2>/dev/null"
  resultado
}

# Executa os quadros com um PATH que só tem bash e os comandos do busybox
testar_busybox() {
  local bin
  bin="$(mktemp -d)"
  ln -s "$(command -v bash)" "${bin}/bash"
  for cmd in $(busybox --list); do [[ -e "${bin}/${cmd}" ]] || ln -s "$(command -v busybox)" "${bin}/${cmd}"; done
  printf 'NEXTEC_FUNCAO=Painel de senhas\nNEXTEC_AMBIENTE=Produção\n' > /tmp/nx-env
  for f in 05-servidor 05-nextec 10-nextec-info; do
    checar "${f} só com busybox, sem erro" \
      env -i PATH="$bin" bash -c "sed 's#/etc/environment#/tmp/nx-env#g' '${PASTA}/${f}' > /tmp/nx-${f} && bash /tmp/nx-${f} >/tmp/nx-out 2>/tmp/nx-err; rc=\$?; [ \$rc -eq 0 ] && [ ! -s /tmp/nx-err ] || { cat /tmp/nx-err; exit 1; }"
  done
  checar "05-servidor com busybox mostra disco e memória" \
    env -i PATH="$bin" bash -c "bash /tmp/nx-05-servidor | grep -q 'Disco /:.*usado' && bash /tmp/nx-05-servidor | grep -q 'Memória:.*GB'"
  checar "05-servidor com busybox sem hostname do coreutils" \
    env -i PATH="$bin" bash -c "rm -f '${bin}/hostname'; bash /tmp/nx-05-servidor | grep -q 'Servidor:'"
  resultado
}

if [[ "${1:-}" == "--dentro" ]]; then
  if [[ "$2" == "busybox" ]]; then testar_busybox; else testar_instalacao "$2"; fi
  exit $?
fi

[[ $EUID -eq 0 ]] || { echo "Erro: execute como root." >&2; exit 1; }
[[ $# -gt 0 ]] && CENARIOS=("$@")

GERAL=0
for cenario in "${CENARIOS[@]}"; do
  echo
  echo "== ${cenario}"
  unshare -m bash "$0" --dentro "$cenario" || GERAL=1
done
echo
if [[ $GERAL -eq 0 ]]; then echo "Todos os cenários passaram."; else echo "Há falhas."; fi
exit $GERAL
