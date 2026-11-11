#!/usr/bin/env bash
# ==============================================================================
# Testes do instalador Linux: leitura de saídas longas sem SIGPIPE (código 141).
#
# Rodar da raiz do repositório Scripts (não precisa de root):
#   bash Alloy/testes/instalador-linux-sigpipe.testes.sh
#
# O instalador roda com "set -Eeuo pipefail". Um awk que sai no meio da leitura
# fecha o pipe e mata quem escreve nele com SIGPIPE, o que derruba a instalação.
# Os cenários carregam o instalador com "source" e trocam os comandos externos
# por funções que escrevem listas longas.
# ==============================================================================

set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALADOR="${AQUI}/../install-nextec-monitoring-linux-v2.sh"

PASSOU=0
FALHOU=0

verificar() {
  local nome="$1" esperado="$2" obtido="$3"
  if [[ "$obtido" == "$esperado" ]]; then
    PASSOU=$((PASSOU + 1)); echo "ok   ${nome}"
  else
    FALHOU=$((FALHOU + 1)); echo "FALHA ${nome}: esperado [${esperado}], obtido [${obtido}]"
  fi
}

# Lista no formato do apt-cache madison: a versão procurada no topo e milhares
# de linhas depois, o bastante para encher o buffer do pipe.
madison_longo() {
  local alvo="$1" i
  echo "     alloy | ${alvo} | https://apt.grafana.com stable/main amd64 Packages"
  for ((i = 0; i < 20000; i++)); do
    echo "     alloy | 0.${i}.0 | https://apt.grafana.com stable/main amd64 Packages"
  done
}

# rodar_versao VERSAO_PROCURADA VERSAO_NO_TOPO: imprime "<saída>|<código>".
rodar_versao() {
  local procurada="$1" topo="$2"
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    set -Eeuo pipefail
    apt-cache() { madison_longo "$topo"; }
    r="$(versao_alloy_apt "$procurada")"
    echo "${r}|0"
  ) 2>/dev/null || echo "|$?"
}

verificar "versão exata no topo de lista longa" "1.20.1|0" "$(rodar_versao 1.20.1 1.20.1)"
verificar "versão com revisão Debian" "1.20.1-1|0" "$(rodar_versao 1.20.1 1.20.1-1)"
verificar "não confunde 1.20.10 com 1.20.1" "|0" "$(rodar_versao 1.20.1 1.20.10)"
verificar "versão ausente devolve vazio sem erro" "|0" "$(rodar_versao 9.9.9 1.20.1)"

# Leitura do IP do iDRAC: mesma armadilha com o ipmitool.
rodar_idrac() {
  (
    # shellcheck disable=SC1090
    source "$INSTALADOR"
    trap - ERR
    set -Eeuo pipefail
    linha="$(grep -n 'IDRAC_ENDERECO="\$(timeout 15 ipmitool' "$INSTALADOR" | head -n1 | cut -d: -f2-)"
    timeout() { shift; "$@"; }
    ipmitool() {
      local i
      echo "IP Address Source       : Static Address"
      echo "IP Address              : 10.0.0.120"
      for ((i = 0; i < 20000; i++)); do echo "Cipher Suite Priv Max   : XaaaXXaaaXaaaXa ${i}"; done
    }
    eval "$linha"
    echo "${IDRAC_ENDERECO}|0"
  ) 2>/dev/null || echo "|$?"
}

verificar "IP do iDRAC com saída longa do ipmitool" "10.0.0.120|0" "$(rodar_idrac)"

echo
echo "Passaram: ${PASSOU}  Falharam: ${FALHOU}"
[[ "$FALHOU" -eq 0 ]]
