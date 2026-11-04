# Assessment

Levantamento completo e **somente leitura** do ambiente de TI de um cliente (servidor, Active Directory, estações, rede e topologia), com relatório em HTML, CSVs e um `.zip`. Roda sem perguntas: dois cliques e, no máximo, um login e senha.

Funciona no Windows PowerShell 5.1. Executar no servidor principal do cliente, de preferência o controlador de domínio.

## Uso rápido

Num PowerShell **aberto como administrador**, no servidor do cliente (troque a tag pela versão desejada):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $d='C:\ProgramData\Nextec\Assessment'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $f="$d\Nextec-Assessment-v2.ps1"; iwr 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/assessment-v2.8/Assessment/Nextec-Assessment-v2.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Automatico
```

- O script não se eleva sozinho: se o PowerShell não estiver como administrador, avisa e encerra. Depois valida o ambiente antes de coletar.
- Se a conta atual não alcançar as estações, abre **uma** janela de login e senha do domínio. A credencial vale só para a execução e não é gravada.
- O script fica em `C:\ProgramData\Nextec\Assessment\`, a pasta a liberar no antivírus. Se houver antivírus com bloqueio por comportamento, o script avisa logo no início.
- O resultado fica em `C:\Temp\<cliente>_<servidor>_<data>.zip` (mude com `-Saida`). A pasta de trabalho é removida assim que o `.zip` é gerado (se o zip falhar, a pasta é mantida). Ao terminar, o Explorer abre com o `.zip` selecionado.
- Use sempre uma **tag**, nunca a `main`: assim uma alteração futura no repositório não passa a rodar como administrador nas máquinas dos clientes.

Alternativa por arquivo: baixe os dois arquivos desta pasta, na mesma pasta, e execute `Executar-Assessment.cmd` com botão direito, Executar como administrador.

## Coleta das estações por GPO (sem depender de firewall nem de máquina ligada)

Quando WinRM/DCOM estão bloqueados nas estações, o inventário remoto não funciona. Nesse caso cada estação coleta a si mesma, em segundo plano, e grava o resultado numa pasta compartilhada no servidor. O assessment lê esses arquivos no lugar de consultar as estações.

1. No controlador de domínio, como administrador, rode `Preparar-Compartilhamento-Assessment.ps1` (cria `Assessment$`, as permissões e copia os scripts para `NETLOGON\Nextec`). As estações só conseguem gravar arquivos novos; não listam nem leem o que existe.
2. Crie uma GPO ligada à OU dos computadores: Configuração do Computador, Políticas, Configurações do Windows, Scripts, Inicialização, aba Scripts do PowerShell. Nome do script: `\\<dominio>\NETLOGON\Nextec\Instalar-Assessment-Estacao.ps1`. Parâmetros: `-Destino "\\<servidor>\Assessment$\Estacoes"` (o passo 1 imprime os dois valores prontos).
3. Na inicialização, cada máquina registra a tarefa `Nextec - Assessment da estacao` (SYSTEM, visível no Agendador, na inicialização e todo dia por volta de 12:15) e coleta uma primeira vez. Sem janela e sem intervenção.
4. Rode o `Nextec-Assessment-v2.ps1` no servidor como de costume: ele acha `Assessment$` sozinho (ou use `-PastaEstacoes`) e usa os arquivos de até 7 dias (`-DiasValidadeColetaLocal`). Estações sem arquivo recente seguem pela consulta remota.

Para desfazer: `Instalar-Assessment-Estacao.ps1 -Destino x -Remover`, ou retire a GPO e remova a tarefa.

## Parâmetros mais usados

| Parâmetro | Efeito |
|---|---|
| `-Automatico` | Sem perguntas (o `.cmd` já usa). |
| `-SoValidar` | Só a pré-validação do ambiente, sem coletar. |
| `-Cliente "Nome"` | Nome do cliente nos arquivos. Sem ele, usa o domínio. |
| `-Subredes 192.168.0.0/24` | Sub-redes a varrer. Sem ele, detecta sozinho. |
| `-SemVarreduraRede` | Não varre a rede. |
| `-SemInventarioRemoto` | Não consulta as estações. |
| `-SemAD` | Não coleta o Active Directory. |
| `-SemConsultaInternet` | Nenhuma consulta pela internet. |
| `-PedirCredencial` | Abre o login e senha do domínio logo no início. |
| `-ComandosExternos` | Liga `net view` (compartilhamentos dos equipamentos da rede), `net accounts` e `vssadmin`. Desligado por padrão. |
| `-ConsultasWeb` | Liga `ipinfo.io` (cidade do IP público), `api.macvendors.com` e o download da base IEEE. Desligado por padrão. |

Todos os parâmetros e o que é coletado estão no próprio cabeçalho do script (`Get-Help .\Nextec-Assessment-v2.ps1 -Full`).

## Confidencialidade

O material contém nomes de usuário, IPs, softwares e configurações do cliente. Trate a pasta e o `.zip` como confidenciais. O script não altera nada no cliente: grava apenas a pasta de saída e um cache de fabricantes em `%LOCALAPPDATA%\Nextec-Assessment`. Por padrão, a única consulta externa é por DNS, para o IP público e a operadora (`ns1.google.com` e `asn.cymru.com`). Com `-ConsultasWeb` entram a base de fabricantes da IEEE, o `api.macvendors.com` (só o prefixo do MAC) e o `ipinfo.io`. `-SemConsultaInternet` desliga todas.

## Verificação de integridade

SHA-256 do `Nextec-Assessment-v2.ps1` da tag `assessment-v2.8`:

```
2F17249D5424B73B10E603BABCA39DB45FE38188D1E07826F6373CE9DF475BF4
```

```powershell
(Get-FileHash C:\ProgramData\Nextec\Assessment\Nextec-Assessment-v2.ps1 -Algorithm SHA256).Hash
```

## Notas

- Salve o `.ps1` sempre em UTF-8 **com BOM** (o `.gitattributes` desta pasta impede o Git de converter). Sem o BOM, os acentos quebram no PowerShell 5.1.
- Clientes com EDR podem alertar sobre o download e a execução de um `.ps1` e sobre a varredura de portas. Avise a equipe de segurança antes. O script não usa ofuscação nem desliga proteção; o que resolve de fato é assinatura Authenticode mais liberação por hash ou pela pasta. Enquanto não houver assinatura, o `.cmd` segue com `-ExecutionPolicy Bypass`.
- O coletor roda como SYSTEM: dados por usuário (conta do Office, unidades mapeadas, bloqueio de tela) só saem de quem está logado na hora, e certificado A3 só aparece se estiver registrado no repositório do Windows. Novas colunas só existem nas máquinas com o coletor 2.0; para atualizar, rode de novo o `Preparar-Compartilhamento-Assessment.ps1`.

## Histórico

- **v2.12**: coletor da estação 2.0: ativação do Windows e do Office, certificados ICP-Brasil e drivers de token, firewall, WinRM, SMB, administrador local, LAPS, política de senha, compartilhamentos, USB, bloqueio de tela, tarefas, serviços e inicialização fora do padrão, logons com falha, IP e Wi-Fi, impressoras, scanners, unidades mapeadas, saúde de disco, telas azuis, dados locais e BIOS, com CSVs `estacoes_*`, alertas e seção no relatório. Antivírus: base de fabricantes em texto puro (sem base64 e gzip), `net`, `vssadmin` e consultas web só por parâmetro, IP público por DNS, tarefa da estação sem janela oculta forçada e com `RemoteSigned`. Correções: inventário paralelo com prazo; firewall lê a política efetiva; `ESET` e `AVG` não casam mais "Reset" nem nomes parciais; suporte por edição (LTSC, Enterprise e Education); TPM sem leitura deixa de sair vazio; arquivo de estação validado antes de entrar em conta e no HTML; `Get-LocalGroupMember` com SID órfão não aborta a etapa; alerta de "nenhum backup" volta a disparar; ausência de monitor deixa de contar como erro; Office Click-to-Run aparece no resumo. `AcessoEntrada` considera o perfil de rede ativo, a origem permitida e as regras de bloqueio, e passa a ter o estado `restrita`. Os dados locais seguem as pastas redirecionadas da hive de quem está logado, contam o que já foi baixado do OneDrive e trazem a coluna `Observacao`. Os CSVs neutralizam fórmulas (valor ou nome de coluna iniciado por `=`, `+`, `-` ou `@` recebe apóstrofo; os nomes de coluna são mapeados uma vez por arquivo e nunca colidem, mesmo que a estação envie `=A` e `'=A`, ou `Campo` e `campo`). `OfficeLicenca` separa o tipo de licença do estado em `OfficeAtivacao`, que fica `Não identificada` sem consulta de licença.
- **v2.11**: toda consulta WMI/CIM tem prazo (60 s por padrão, 120 s para licenciamento), inclusive nas estações; Get-HotFix, BitLocker e impressoras (spooler) consultados com limite. WMI corrompido ou spooler travado faz a etapa falhar com aviso no log, sem parar a coleta.
- **v2.10**: fim das travas: Wi-Fi só consulta o netsh se houver placa Wi-Fi e serviço WLAN rodando, cada netsh roda uma vez e com limite de tempo; netsh, vssadmin, auditpol, net accounts, w32tm, omreport, dcdiag e repadmin passam a ter limite de tempo (se estourar, o processo é encerrado e o arquivo registra "sem resposta"); Defender, Windows Server Backup, TPM e discos físicos/SMART consultados com limite; inventário de software das estações via WinRM com tempo máximo de conexão e consulta; testes em `Testes\LimiteTempo.Tests.ps1` (Pester).
- **v2.9**: coleta local das estações por GPO (`Nextec-Assessment-Estacao.ps1`, `Instalar-Assessment-Estacao.ps1`, `Preparar-Compartilhamento-Assessment.ps1`) e leitura no assessment; alerta de estação sem resposta deixa de dizer "negou acesso" quando foi tempo esgotado; pré-validação só marca OK quando todas as estações testadas respondem; cobertura de antivírus informa quantos computadores ficaram sem inventário; saúde de disco de controladora RAID que esconde o SMART sai como "não lida" (antes saía 0% e 0°C); Windows Server Backup sem sucesso aparece como "nenhum backup concluído".
- **v2.8**: memória (pentes, slots e máximo), saúde SMART dos discos (desgaste, temperatura, horas, erros), alerta de servidor sem RAID, RAID por utilitário (storcli/perccli/ssacli/arcconf), link de garantia, alerta de estação no papel de servidor, velocidade/duplex das placas, qualidade do link (latência e perda), DNS em uso e Wi-Fi do ambiente.
- **v2.7**: nome NetBIOS aceita resposta com nome comprimido e a máquina de coleta usa o próprio nome; título das páginas web dos equipamentos sai legível (sem códigos HTML).
- **v2.6**: tela reorganizada: cabeçalho, seções numeradas, uma linha por etapa com tempo e resumo final com alertas por severidade. O `coleta.log` continua completo, com hora e nível.
- **v2.5**: nome NetBIOS consultado direto pela rede (sem `nbtstat.exe`); aviso no início quando há antivírus com bloqueio por comportamento; script em `C:\ProgramData\Nextec\Assessment\` e resultado em `C:\Temp`.
- **v2.4**: o script deixou de se elevar sozinho (sem `RunAs` nem `-EncodedCommand`, que disparavam o antivírus); exige PowerShell aberto como administrador.
- **v2.3**: depois de gerar o `.zip`, a pasta de saída é removida do servidor (só o zip fica).
- **v2.2**: base de fabricantes embutida passou a carregar (antes ficava vazia e o fabricante saía em branco); textos de alerta e da pré-validação mais claros.
- **v2.1**: modo sem intervenção (`-Automatico`), pré-validação, login único, relatório separa credencial recusada de máquina desligada.
- **v2.0**: versão de 29/09/2026.
