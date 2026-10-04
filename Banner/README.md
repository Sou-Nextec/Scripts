# Banner de login dos servidores

Aviso de acesso antes da senha e quadro informativo depois do login, nos servidores Linux e Windows da Nextec e dos clientes. O passo a passo completo fica no Confluence, na página "Como configurar o aviso de acesso e o banner de login nos servidores" (espaço Documentação Interna).

| Arquivo | Onde vai | Para quê |
| --- | --- | --- |
| `05-servidor` | `/etc/update-motd.d/05-servidor` | Quadro neutro para servidores de clientes, sem logotipo |
| `05-nextec` | `/etc/update-motd.d/05-nextec` | Quadro com o logotipo da Nextec, só para servidores da Nextec |
| `exemplos/` | | Como cada tela fica |

Os dois scripts leem as variáveis de `/etc/environment`:

| Variável | O que é |
| --- | --- |
| `NEXTEC_NOME_SERVIDOR` | Nome do servidor como a Nextec o chama. Sai em caixa alta. Sem ela, aparece o nome real da máquina |
| `NEXTEC_FUNCAO` | Para que o servidor serve (só no `05-servidor`) |
| `NEXTEC_AMBIENTE` | Produção, homologação ou testes (só no `05-servidor`) |

Os valores são tratados só como texto: aspas, barras e caracteres de controle gravados por engano são ignorados.

## Histórico

| Versão | Data | Mudanças |
| --- | --- | --- |
| 1.0.0 | 2026-10-04 | Primeira versão: `05-nextec` (logotipo Nextec, nome real e nome Nextec do servidor) e `05-servidor` (quadro neutro para clientes, com contato noc@nex.tec.br) |
