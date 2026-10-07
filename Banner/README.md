# Banner de login dos servidores

Aviso de acesso antes da senha e quadro informativo depois do login, nos servidores Linux da Nextec e dos clientes. O passo a passo completo, inclusive a parte de Windows, fica no Confluence, na página "Como configurar o aviso de acesso e o banner de login nos servidores" (espaço Documentação Interna).

## Como aplicar

Dentro da sessão SSH do servidor, ajuste as quatro variáveis e cole o bloco:

```bash
TIPO='cliente'               # cliente | nextec
NOME=''                      # Vazio = usa o hostname
FUNCAO='Servidor Escriba'
AMBIENTE='Produção'          # Produção | Homologação | Testes
curl -fsSL https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner/aplicar-banner.sh -o /tmp/aplicar-banner.sh
sudo TIPO="$TIPO" NOME="$NOME" FUNCAO="$FUNCAO" AMBIENTE="$AMBIENTE" bash /tmp/aplicar-banner.sh
```

O `aplicar-banner.sh` baixa os demais arquivos desta pasta, faz backup do que existe e pode ser executado de novo a qualquer momento.

## Arquivos

| Arquivo | Onde vai | Para quê |
| --- | --- | --- |
| `aplicar-banner.sh` | Executado uma vez | Instala tudo: variáveis, quadro, aviso e limpeza do MOTD do Ubuntu |
| `aviso-acesso.txt` | `/etc/issue.net` e `/etc/issue` | Aviso legal antes da senha (SSH e console) |
| `05-servidor` | `/etc/update-motd.d/05-servidor` | Quadro neutro para servidores de clientes, sem logotipo |
| `05-nextec` | `/etc/update-motd.d/05-nextec` | Logotipo e boas-vindas, só para servidores da Nextec |
| `10-nextec-info` | `/etc/update-motd.d/10-nextec-info` | Identificação e resumo do sistema dos servidores da Nextec |
| `exemplos/` | | Telas da versão 1.0 |

## Variáveis

Gravadas pelo `aplicar-banner.sh` em `/etc/environment`:

| Variável | O que é |
| --- | --- |
| `NEXTEC_NOME_SERVIDOR` | Nome do servidor como a Nextec o chama. Sai em caixa alta, com o hostname entre parênteses. Sem ela, aparece o hostname em caixa alta |
| `NEXTEC_FUNCAO` | Para que o servidor serve |
| `NEXTEC_AMBIENTE` | Produção (vermelho), Homologação (amarelo) ou outro valor, como Testes (verde) |

Os valores são tratados só como texto: aspas, barras, quebras de linha e caracteres de controle são ignorados.

## Referências

- NIST SP 800-53, controle AC-8 (System Use Notification): conteúdo do aviso.
- CIS Benchmark do Ubuntu, seção "Command Line Warning Banners": aviso em `/etc/issue.net` e `/etc/issue`, sem sistema operacional nem versão, permissão 644.

## Histórico

| Versão | Data | Mudanças |
| --- | --- | --- |
| 2.0.0 | 2026-10-07 | Instalador único `aplicar-banner.sh`; aviso no padrão NIST AC-8, também no console; resumo do sistema no quadro; cor do ambiente; logotipo centralizado com separador; identificação no `10-nextec-info`; limpeza dos scripts de MOTD do Ubuntu |
| 1.0.0 | 2026-10-04 | Primeira versão: `05-nextec` (logotipo Nextec, nome real e nome Nextec do servidor) e `05-servidor` (quadro neutro para clientes, com contato noc@nex.tec.br) |
