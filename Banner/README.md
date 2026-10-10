# Banner de login dos servidores

Aviso de acesso antes da senha e quadro informativo depois do login, nos servidores Linux e Windows da Nextec e dos clientes. O passo a passo completo fica no Confluence, na página "Como configurar o aviso de acesso e o banner de login nos servidores" (espaço Documentação Interna).

## Como aplicar

### Linux

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

### Windows

No PowerShell como administrador, dentro do servidor, edite só os quatro valores no início da linha (entre aspas) e cole a linha inteira:

```powershell
$nome=''; $funcao='Servidor Escriba'; $ambiente='Produção'; $papel='Manter'; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Banner/aplicar-banner.ps1').Content.TrimStart([char]0xFEFF))) -Nome $nome -Funcao $funcao -Ambiente $ambiente -PapelDeParede $papel
```

O que editar:

| Valor | Opções |
| --- | --- |
| `$nome` | Vazio usa o nome real da máquina |
| `$funcao` | Texto livre, por exemplo `Servidor Escriba` |
| `$ambiente` | `Produção` (vermelho), `Homologação` (amarelo) ou `Testes` (verde) |
| `$papel` | `Manter` (quadro sobre o papel de parede atual), `Azul` (azul Nextec #0D0035 liso) ou `Preto` (preto liso) |

O `aplicar-banner.ps1` baixa o `quadro-windows.ps1` desta pasta, grava as variáveis, aplica o aviso antes da senha, registra a tarefa agendada que redesenha o quadro a cada login e já aplica na sessão atual. Pode ser executado de novo a qualquer momento, e é assim que se muda nome, função, ambiente ou papel de parede depois. Para só conferir o visual, sem alterar nada: `.\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png`.

Os dois arquivos `.ps1` ficam salvos em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.

## Arquivos

| Arquivo | Onde vai | Para quê |
| --- | --- | --- |
| `aplicar-banner.sh` | Executado uma vez | Instala tudo: variáveis, quadro, aviso e limpeza do MOTD do Ubuntu |
| `aviso-acesso.txt` | `/etc/issue.net` e `/etc/issue` | Aviso legal antes da senha (SSH e console) |
| `05-servidor` | `/etc/update-motd.d/05-servidor` | Quadro neutro para servidores de clientes, sem logotipo |
| `05-nextec` | `/etc/update-motd.d/05-nextec` | Logotipo e boas-vindas, só para servidores da Nextec |
| `10-nextec-info` | `/etc/update-motd.d/10-nextec-info` | Identificação e resumo do sistema dos servidores da Nextec |
| `aplicar-banner.ps1` | Executado uma vez | Windows: instala tudo (quadro, variáveis, aviso antes da senha e tarefa agendada) |
| `quadro-windows.ps1` | `C:\ProgramData\Nextec\Banner\` | Windows: desenha o quadro por cima do papel de parede do usuário a cada login, com as mesmas informações do quadro Linux |
| `exemplos/` | | Telas da versão 1.0 |

## Variáveis

Gravadas pelo `aplicar-banner.sh` em `/etc/environment` (Linux) e pelo `aplicar-banner.ps1` nas variáveis de ambiente da máquina (Windows):

| Variável | O que é |
| --- | --- |
| `NEXTEC_NOME_SERVIDOR` | Nome do servidor como a Nextec o chama. Sai em caixa alta, com o hostname entre parênteses. Sem ela, aparece o hostname em caixa alta |
| `NEXTEC_FUNCAO` | Para que o servidor serve |
| `NEXTEC_AMBIENTE` | Produção (vermelho), Homologação (amarelo) ou outro valor, como Testes (verde) |
| `NEXTEC_PAPEL_DE_PAREDE` | Só no Windows. `Manter` (padrão) desenha o quadro por cima do papel de parede de cada usuário; `Azul` troca o papel de parede pelo azul Nextec (#0D0035) liso; `Preto` troca por preto liso. `Remover` ainda é aceito e equivale a `Azul`. Para mudar depois, basta rodar o instalador de novo |
| `NEXTEC_OPACIDADE` | Opcional, só no Windows. Opacidade do painel atrás do quadro, de 0 a 255 (padrão 215). Aumentar melhora o contraste sobre papéis de parede claros |

Os valores são tratados só como texto: aspas, barras, quebras de linha e caracteres de controle são ignorados.

## Referências

- NIST SP 800-53, controle AC-8 (System Use Notification): conteúdo do aviso.
- CIS Benchmark do Ubuntu, seção "Command Line Warning Banners": aviso em `/etc/issue.net` e `/etc/issue`, sem sistema operacional nem versão, permissão 644.

## Histórico

| Versão | Data | Mudanças |
| --- | --- | --- |
| 2.1.0 | 2026-10-09 | Windows: instalador único `aplicar-banner.ps1` e `quadro-windows.ps1`, que desenha o quadro no papel de parede com as mesmas informações do Linux (cor do ambiente, carga, disco, memória, paginação, uptime, processos, usuários e IP), sem BGInfo e sem modelo binário; grupo Users resolvido pelo SID, que funciona em Windows em português |
| 2.1.1 | 2026-10-10 | Windows: o quadro é desenhado por cima do papel de parede do usuário (preservado e recuperado do histórico quando já foi sobrescrito), com painel translúcido para manter a leitura; novo parâmetro `-PapelDeParede` (Manter ou Remover) para escolher entre manter ou retirar o papel de parede |
| 2.1.2 | 2026-10-10 | Windows: mais contraste no quadro (painel mais opaco com borda leve, rótulos e rodapé mais claros, rodapé maior); opacidade ajustável por `NEXTEC_OPACIDADE` ou `-Opacidade` |
| 2.1.3 | 2026-10-10 | Windows: novas opções de fundo `Azul` (#0D0035) e `Preto` no `-PapelDeParede` (`Remover` segue valendo como `Azul`); comando de uma linha com os quatro valores editáveis no início |
| 2.0.0 | 2026-10-07 | Instalador único `aplicar-banner.sh`; aviso no padrão NIST AC-8, também no console; resumo do sistema no quadro; cor do ambiente; logotipo centralizado com separador; identificação no `10-nextec-info`; limpeza dos scripts de MOTD do Ubuntu |
| 1.0.0 | 2026-10-04 | Primeira versão: `05-nextec` (logotipo Nextec, nome real e nome Nextec do servidor) e `05-servidor` (quadro neutro para clientes, com contato noc@nex.tec.br) |
