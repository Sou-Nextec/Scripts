#!/usr/bin/env bash
# ==============================================================================
# Testes do instalador Linux: escolha da versão do Alloy no apt sem SIGPIPE.
#
# Rodar da raiz do repositório Scripts (não precisa de root nem de apt):
#   bash Alloy/testes/instalador-linux-alloy-versao.testes.sh
#
# O instalador roda com "pipefail". Quando o awk saía no primeiro acerto, o
# apt-cache morria por SIGPIPE e o pipeline devolvia 141, derrubando a
# atualização automática mesmo com a versão encontrada. Aqui o apt-cache é uma
# função que imprime uma lista longa (maior que o buffer do pipe), para o
# problema aparecer sempre, e o comportamento antigo é reproduzido para provar
# que o teste detecta a falha.
# ==============================================================================

# As funções falsas só são chamadas pelo instalador carregado com "source" (SC2317).
# shellcheck disable=SC2034,SC1090,SC2317
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALADOR="${AQUI}/../install-nextec-monitoring-linux-v2.sh"
CHANGELOG="${AQUI}/../CHANGELOG.md"

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

# Lista no formato do "apt-cache madison", com o acerto logo no começo e muitas
# linhas depois, como no repositório da Grafana (64 linhas) e além.
lista_madison() {
  local i
  echo "     alloy | 1.22.0-1 | https://apt.grafana.com stable/main amd64 Packages"
  echo "     alloy | 1.21.3-1 | https://apt.grafana.com stable/main amd64 Packages"
  echo "     alloy | 1.20.1-1 | https://apt.grafana.com stable/main amd64 Packages"
  for ((i = 0; i < 20000; i++)); do
    echo "     alloy | 0.${i}.0-1 | https://apt.grafana.com stable/main amd64 Packages"
  done
}

# executar_instalador FUNCAO ARG...: carrega o instalador e roda a função com o
# apt-cache falso. Imprime o que a função imprimir e termina com o código dela.
executar_instalador() {
  (
    source "$INSTALADOR"
    trap - ERR
    set +e
    set -o pipefail
    apt-cache() { lista_madison; }
    "$@"
  )
}

# ------------------------------------------------------------------------------
echo "1. Comportamento antigo (awk com exit antecipado) falha com 141: o teste enxerga o problema"
antigo="$( set -o pipefail; lista_madison | awk -F'|' -v v="1.20.1" '{gsub(/ /,"",$2); if ($2==v || index($2, v"-")==1) {print $2; exit}}'; echo "codigo=$?" )"
conferir "pipeline antigo devolve 141" "$(grep -o 'codigo=[0-9]*' <<<"$antigo")" "codigo=141"

echo "2. Versão fixada que existe no repositório"
saida="$(executar_instalador alloy_candidato_apt 1.20.1; echo "codigo=$?")"
conferir "imprime a versão completa" "$(head -n1 <<<"$saida")" "1.20.1-1"
conferir "termina com código 0 (sem SIGPIPE)" "$(tail -n1 <<<"$saida")" "codigo=0"

echo "3. Repetição: sem falha intermitente"
falhas=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  saida="$(executar_instalador alloy_candidato_apt 1.20.1; echo "codigo=$?")"
  [[ "$(tail -n1 <<<"$saida")" == "codigo=0" && "$(head -n1 <<<"$saida")" == "1.20.1-1" ]] || falhas=$((falhas + 1))
done
conferir "10 execuções seguidas sem falha" "$falhas" "0"

echo "4. Versão que não existe no repositório"
saida="$(executar_instalador alloy_candidato_apt 9.9.9; echo "codigo=$?")"
conferir "não imprime versão" "$(head -n1 <<<"$saida")" "codigo=0"

echo "5. Versão em prefixo não casa por engano (1.20 não vira 1.20.1)"
saida="$(executar_instalador alloy_candidato_apt 1.2; echo "codigo=$?")"
conferir "não imprime versão" "$(head -n1 <<<"$saida")" "codigo=0"

echo "6. Só a primeira versão que casa é devolvida"
saida="$(
  (
    source "$INSTALADOR"; trap - ERR; set +e; set -o pipefail
    apt-cache() { printf '     alloy | 1.21.3-1 | x\n     alloy | 1.21.3-2 | x\n     alloy | 1.21.2-1 | x\n'; }
    alloy_candidato_apt 1.21.3
  )
)"
conferir "uma linha só, a primeira" "$saida" "1.21.3-1"

echo "7. install_alloy_apt usa a função e não tem mais o awk com exit antecipado"
corpo="$(source "$INSTALADOR"; trap - ERR; declare -f install_alloy_apt)"
conferir "chama alloy_candidato_apt" "$(grep -c 'alloy_candidato_apt "\$ALLOY_VERSAO"' <<<"$corpo")" "1"
conferir "sem 'print \$2; exit' no trecho do apt" "$(grep -c 'print \$2; exit' <<<"$corpo" || true)" "0"

echo "8. Versão do instalador e do CHANGELOG"
VERSAO="$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$INSTALADOR")"
conferir "cabeçalho do instalador com a versão" "$(grep -c "^# Versão: ${VERSAO} " "$INSTALADOR")" "1"
conferir "tabela do CHANGELOG com a versão" "$(grep -c "^| Instalador Linux | \`install-nextec-monitoring-linux-v2.sh\` | ${VERSAO} |$" "$CHANGELOG")" "1"
conferir "CHANGELOG tem entrada da versão" "$(grep -c "^### Instalador Linux ${VERSAO}" "$CHANGELOG")" "1"

echo
echo "Resultado: ${PASSOU} ok, ${FALHOU} falha(s)."
[[ "$FALHOU" == "0" ]]