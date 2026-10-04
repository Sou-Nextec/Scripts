# Changelog do monitoramento Nextec

O que mudou nos instaladores, na Coleta Complementar e no atualizador automático. As entradas mais recentes ficam no topo.

Os números de versão seguem `MAIOR.MENOR.CORREÇÃO`:

- **MAIOR**: muda quando é preciso fazer algo à mão nas máquinas;
- **MENOR**: recurso novo;
- **CORREÇÃO**: ajuste sem mudança de comportamento.

| Componente | Arquivo | Versão atual |
| --- | --- | --- |
| Instalador Linux | `install-nextec-monitoring-linux-v2.sh` | 2.7.0 |
| Instalador Windows | `install-nextec-monitoring-windows-v2.ps1` | 2.17.1 |
| Coleta Complementar | `coleta-complementar/` | 1.2.0 |
| Atualizador automático | `atualizador/` | 1.0.0 |

## 2026-10-04

### Instalador Windows 2.17.1

- **Ícone da janela.** A tela de instalação, a janela de andamento e a janela do equipamento SNMP mostram o emblema da Nextec na barra de título e na barra de tarefas, no lugar do ícone do PowerShell.

### Instalador Windows 2.17.0

- **Campos obrigatórios marcados.** Asterisco vermelho no rótulo (Cliente, Nome do host, Local, Destino, credencial do NOC) e no título das colunas obrigatórias das grades, com a legenda "* campo obrigatório" em cada aba.
- **Recursos.** O perfil básico abre recolhido. Ao lado do intervalo do Speedtest aparece a recomendação (30 min) e o aviso fica vermelho abaixo de 15 min.
- **Links de internet.** Velocidade em Mbps (500, 1000 ou 600/300). Função com inicial maiúscula: Principal, Reserva e SD-WAN.
- **Conectividade.** Os seis testes ficam numerados do mais simples ao mais completo: 1 Ping, 2 TCP, 3 DNS, 4 HTTP, 5 HTTPS com certificado, 6 Conteúdo. A mesma ordem vale no console.
- **SNMP.** O equipamento é cadastrado numa janela só: nome, endereço, fabricante, tipo e credencial, mostrando apenas os campos da versão escolhida (v2c ou v3). Editar e remover pela lista. Fabricante fora da lista traz o aviso para solicitar a inclusão ao NOC.
- **Exporters.** A árvore mostra só o nome do serviço (Redis, Nginx, Elasticsearch...), sem porta. A aba traz o passo a passo para cadastrar outro serviço com métricas Prometheus.
- **Andamento na própria tela.** Depois de confirmar, o console fica escondido e uma janela com o mesmo cabeçalho mostra o log em tempo real, com o download em porcentagem. No fim aparece "Simulação concluída" ou o resultado da instalação, e a janela só fecha quando o técnico clica em Fechar.
- **Telas com zoom.** No PowerShell 7, com a tela em 125% ou 150%, os rótulos saíam cortados (texto ampliado e layout não). Agora a tela inteira acompanha a escala.

### Instalador Linux 2.7.0

- **Conectividade.** Seis testes, na mesma ordem do Windows (Ping, TCP, DNS, HTTP, HTTPS com certificado e Conteúdo). O blackbox.yml passa a ter os módulos `http_2xx_ssl`, `http_2xx_content` e `dns_udp`, e o endereço é conferido conforme o teste (TCP pede host:porta).
- **Obrigatórios.** Pergunta obrigatória sai com asterisco vermelho, com a legenda na identificação.
- **Links.** Velocidade em Mbps e Função com inicial maiúscula (Principal, Reserva, SD-WAN).
- **Speedtest.** A recomendação de 30 minutos aparece no checklist e na pergunta.
- **Exporters.** Catálogo pelo nome do serviço e passo a passo para outro serviço com métricas Prometheus.
- **SNMP.** Aviso para solicitar ao NOC fabricante que não está na lista.

### Instalador Windows 2.16.2

- **Logo na tela de instalação.** O cabeçalho da janela mostra a logo da Nextec (versão clara), embutida no script para continuar funcionando pelo comando direto do GitHub. Se a imagem não carregar, a tela abre sem ela.

### Instalador Windows 2.16.1

- **Execução direta do GitHub.** O comando `& ([scriptblock]::Create((irm <url>)))` falhava com `Unexpected attribute 'CmdletBinding'` desde a 2.15.4. O arquivo tem BOM (necessário para os acentos no Windows PowerShell 5.1), o `irm` entrega esse BOM como primeiro caractere e o PowerShell não o trata como espaço, então o `param()` deixava de ser a primeira instrução. O comando correto remove o BOM antes de montar o scriptblock:

  ```powershell
  $u = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/install-nextec-monitoring-windows-v2.ps1"
  & ([scriptblock]::Create((irm $u).TrimStart([char]0xFEFF)))
  ```

  Parâmetros vão no fim (`-Simular`, `-Console`, etc.). O `irm ... | iex` tinha o mesmo problema e foi substituído por esse comando na documentação.
- **Perfil básico visível na tela Recursos.** CPU, memória, discos, rede, uptime e serviços do Windows aparecem no topo da árvore, marcados e em cinza, sem a opção de desmarcar. Antes eram só citados no texto acima da árvore. O que é coletado não mudou.

### Instalador Windows 2.16.0

- **Tela de instalação.** Com área de trabalho, o instalador abre uma janela com abas: identificação, recursos, links de internet, conectividade, SNMP, exporters, credenciais e resumo. Cada aba confere os campos ao avançar (cliente, endereços, velocidade, host:porta, credencial SNMP) e mostra o erro no rodapé. A instalação em si continua a mesma do console, com o andamento na janela do PowerShell.
- **Quando a tela não abre.** RMM e tarefas como SYSTEM, sessão sem área de trabalho, Server Core, `-Silent`, `-Atualizar` e `-Console` seguem no console, como antes.
- **Exporters em árvore na tela.** Marcar um exporter já traz o endereço padrão; "Outro endpoint" abre uma linha livre.
- **Credencial SNMP na tela.** Botão "Definir..." por equipamento, com v2c ou v3 (authPriv ou authNoPriv). Senha não aparece na tela nem no resumo.
- **Simulação.** `-Simular` abre as telas e mostra o resumo sem instalar nada e sem pedir Administrador. As respostas, sem senha, ficam em `%TEMP%\nextec-simulacao.json`. Serve para treinar e para conferir antes de ir ao cliente.
- **SNMP.** SonicWall entra no catálogo. Baixar de novo um fabricante atualiza o módulo dele no snmp.yml (antes o antigo ficava). Com mais de um fabricante no arquivo, o técnico escolhe qual vale para o equipamento; antes o equipamento recebia os módulos de todos.
- **Menu de instalação existente igual ao Linux.** Mostra o pacote Nextec aplicado pelo atualizador e as coletas ligadas. Ao ligar logs ou a Coleta num host sem credencial do Loki, pede só a do Loki (antes pedia de novo a do remote_write).

### Instalador Linux 2.6.0

- **SNMP por fabricante.** O técnico escolhe FortiGate, SonicWall, pfSense ou MikroTik e o instalador baixa o módulo homologado do repositório, como no Windows. Sem acesso ao GitHub, aceita o arquivo local. "Outro" usa um snmp.yml próprio.
- **Credencial SNMP separada.** Community ou usuário SNMPv3 são perguntados na instalação, sem aparecer na tela, e ficam só em `/etc/alloy/snmp-auth.yml`. O `snmp.yml` guarda só os módulos e junta os fabricantes do mesmo servidor.
- **Instalação antiga.** O snmp.yml com módulo e credencial juntos é separado sozinho na próxima alteração. Sem alteração, continua funcionando como está.
- **Conferência antes de aplicar.** Equipamento com módulo ou credencial que não existe para o instalador, em vez de subir sem coletar.
- **Nome do equipamento.** Hífen e ponto viram sublinhado: o nome é rótulo no config.alloy, e "fw-matriz" quebrava a validação.
- **Intervalo do SNMP.** Coleta a cada 120 s com 60 s de limite, igual ao Windows. Walk em equipamento de entrada passa de 30 s.
- **Exporters em árvore.** "Exporters adicionais" abre no próprio checklist com o catálogo (Redis, Nginx, Apache, RabbitMQ, Elasticsearch, MongoDB, NVIDIA DCGM e outro endpoint). Depois o instalador pergunta só o endereço dos marcados, com o padrão pronto. Na alteração, desmarcar tira o exporter e os que continuam marcados não são perguntados de novo.

### Módulos SNMP (`snmp/`)

- **SonicWall.** Módulo novo: CPU, memória, conexões, interfaces e firmware.
- **FortiGate.** Ganhou interfaces com nome, tráfego de 64 bits, erros e velocidade, túneis IPsec, usuários da VPN SSL e versão do FortiOS. A taxa de sessões lia o OID errado.
- **MikroTik.** CPU e memória passam a vir da HOST-RESOURCES-MIB: o OID usado antes era o do firmware. Ganhou as mesmas métricas de interface.
- **Gerador.** `gerar_modulos.py` gera os três arquivos com os nomes que o painel Nextec | Firewall usa. Instruções em `snmp/README.md`.
- O instalador Windows baixa os mesmos arquivos quando o fabricante ainda não está instalado no host. O SonicWall entra no catálogo do Windows na próxima versão dele.

## 2026-10-03

### Repositório

- **Validação automática (GitHub Actions).** Todo push e pull request confere:
  - sintaxe e ShellCheck do Bash;
  - compilação e nomes indefinidos do Python;
  - sintaxe do PowerShell no 7 e no Windows PowerShell 5.1, com PSScriptAnalyzer;
  - UTF-8, BOM dos `.ps1` com acento e versões desta tabela contra os scripts.

### Instalador Linux 2.5.0

- **Instalação existente.** Rodar o instalador num servidor que já tem o Alloy abre um menu de manutenção. O menu mostra:
  - a versão do instalador e a versão que fez a instalação atual;
  - as versões do Alloy, da Coleta e do atualizador;
  - as coletas que estão ligadas.
- **Opções do menu.** Ver e alterar a configuração, reconfigurar tudo, atualizar só o Alloy e validar e reiniciar. ENTER cancela.
- **Ver e alterar.** Parte das respostas gravadas. Permite mudar só uma parte:
  - identificação e recursos;
  - bancos, alvos de conectividade, SNMP, exporters e links;
  - credenciais e destino.

  As credenciais que não foram alteradas continuam como estão.
- **Credencial do Loki.** Quando logs ou eventos são ligados num servidor que ainda não tinha credencial do Loki, o instalador pede essa credencial antes de aplicar.
- **Modo somente coleta.** O modo `--somente-coleta` usa as respostas gravadas como padrão (ENTER mantém). Num servidor nesse modo, o instalador completo pergunta antes de instalar o Alloy por cima.
- **Coleta Complementar sem módulos.** Ela é desligada quando nenhum módulo fica ativo.
- **Horário do atualizador.** Passa a rodar entre 01h e 05h no horário de Brasília, mesmo em servidor com outro fuso (o timer usa `America/Sao_Paulo`, no systemd 235 ou mais novo).
- **Banner.** Mostra a versão do instalador.
- **Correção SNMP.** O tipo "ups" era gravado como "storage".

### Instalador Linux 2.5.4

- **Exporters adicionais com saída.** A lista ganhou a opção "Voltar, sem adicionar exporter", que é o padrão do ENTER. Quem marcou o item por engano sai sem cadastrar nada, e o item fica desligado.
- **Mais respostas prontas.** A criticidade vem com "alto" e o modo com "Servidor monitorado", iguais ao Windows: basta ENTER.

### Instalador Windows 2.15.4

- **Acentos no teste de velocidade.** O nome do servidor da Ookla chegava quebrado ao NOC ("Claro M├│vel"). A saída do Speedtest passa a ser lida como UTF-8, e o script da tarefa agendada é gravado com BOM.

### Instaladores Linux 2.5.3 e Windows 2.15.3

- **Destino.** Aparece uma vez só, no topo. A pergunta passa a ser "Destino do monitoramento" (ENTER mantém, D altera).
- **Arquivos pequenos.** O tamanho aparece em KB, não "0,0 MB".

### Instaladores Linux 2.5.2 e Windows 2.15.2

- **Quantos links.** O instalador pergunta "Quantos links de internet este local tem?", com 1 como padrão. A pergunta substitui o item "Links de internet" do checklist e a pergunta "tem mais de um link?".
- **Velocidade contratada.** Cada link tem a velocidade contratada, padronizada em Mbps. O técnico digita como quiser ("500", "500 Mega", "1 Giga", "1,5G", "600/300") e o instalador mostra como ficou registrada.
- **Destinos de teste prontos.** São três por link, de provedores diferentes, e não se repetem entre links. O técnico só digita se quiser trocar.
- **Telefone de suporte.** A pergunta saiu.
- **Função do link.** Só é perguntada quando o local tem mais de um link.

### Coleta Complementar 1.2.0

- **IP público de cada link.** A Coleta aprende o IP sozinha quando só aquele link está no ar. Ele aparece em `nextec_link_info` sem precisar ser informado na instalação.
- **Métrica nova.** `nextec_link_velocidade_contratada_mbps{link, sentido}` traz a velocidade contratada para comparar com o teste de velocidade.

### Instaladores Linux 2.5.1 e Windows 2.15.1

- **Cadastro de links.** Primeiro pergunta quantos links o local tem e passa por um de cada vez.
- **Perguntas por link.** Só operadora, tipo (lista), função (principal, reserva ou SD-WAN) e telefone de suporte.
- **Nome do link.** Sai da operadora e do tipo (ex.: "UAU Fibra"); a pergunta do nome saiu.
- **IP público.** É detectado e só confirmado para o link principal. Nos demais, a Coleta aprende sozinha.
- **Destino de teste.** Só é pedido com mais de um link, já sugerindo um destino diferente por link.
- **Opções avançadas.** Gateway da operadora, IP de origem e firewall ficam nelas (padrão: não).
- **Windows: links.** "Este local tem mais de um link?" passa a ter "não" como padrão. Antes, ENTER levava ao cadastro de links mesmo com um link só.
- **Windows: console.** Fundo preto durante a instalação; o azul do PowerShell apagava as cores. As cores originais voltam no fim.

### Instalador Windows 2.15.0

- **Saída.** Segue a mesma hierarquia visual do Linux:
  - logotipo e versão no topo;
  - etapas com barra e linha;
  - símbolos de status;
  - menus com o padrão marcado;
  - resumo com sim/não coloridos;
  - quadro final.
- **Downloads com porcentagem na mesma linha.** Vale para o Alloy, o Speedtest, a Coleta, o atualizador e o snmp.yml. O download não sai do HTTPS.
- **Correção na elevação.** Ao reabrir como Administrador, as variáveis `NEXTEC_COLETA_URL` e `NEXTEC_ATUALIZADOR_URL` passam para a nova sessão. Antes, a sessão elevada perdia a URL da branch de teste e baixava da `main`.
- **"Ver e alterar".** Instala o atualizador e, mesmo sem outra alteração, grava quando falta componente.
- **Status da instalação.** Mostra cliente, host e estado do Alloy em português. A versão do Alloy aparece só com os números.

### Instalador Windows 2.14.1

- O menu de instalação existente mostra:
  - a versão do instalador;
  - a versão que gerou o `config.alloy` atual;
  - as versões da Coleta e do atualizador.

### Atualizador automático 1.0.0

- Primeira versão. As máquinas aplicam sozinhas as versões publicadas pela Nextec. Para cada versão, o atualizador:
  - confere a assinatura do manifesto (RSA 4096);
  - confere o SHA-256 de cada arquivo;
  - libera a versão em ondas (0, 1 e 2);
  - volta à versão anterior automaticamente quando algo falha.
- Para publicar, use `publicar-versao.py` (`gerar-chave`, `publicar`, `aprovar`, `renovar`, `pausar`, `retomar`, `verificar`). Detalhes em `atualizador/README.md`.
- Chave pública da Nextec gravada nos dois atualizadores.

### Instalador Linux 2.4.0 e Windows 2.14.0

- **Respostas gravadas.** O instalador grava as respostas, sem senha: no Linux em `/etc/nextec/instalacao.conf`, no Windows no cabeçalho do `config.alloy`.
- **Modo de atualização.** Novo modo sem perguntas: `--atualizar` no Linux, `-Atualizar` no Windows. É o modo usado pelo atualizador.
- **Alloy fixado.** A versão do Alloy passa a ser a definida pela Nextec. No Linux, o binário é conferido pelo SHA-256 do release.
- **Permissões no Windows.** Pastas executadas como SYSTEM ficam com ACL restrita: o usuário comum só lê.

### Coleta Complementar 1.1.0

- **Módulo de acessos.** Registra os logins no servidor com a origem:
  - Linux: SSH, sudo, su e console;
  - Windows: console, RDP e credencial em cache;
  - `docker exec`, inclusive quem entrou pelo SSH.
- **Alerta crítico.** Para root, Administrador (RID 500) ou usuário privilegiado vindo de uma origem pública nova.
- **Resumo fora do horário.** Acesso privilegiado fora do horário comercial (seg a sex 07h às 19h, sáb 07h às 14h) entra num resumo.

### Instaladores (vários ajustes do dia)

- Resumo final com hierarquia visual; job próprio da Coleta no Alloy; HOME do serviço para o Speedtest.
- Perguntas, opções e resumo com hierarquia visual; apt sem pergunta de conffile.
- `/etc/default/alloy` inválido é refeito, e as credenciais são gravadas com escape seguro.
- Todas as respostas são validadas: a pergunta se repete em vez de encerrar. Cliente com hífen ou acento é convertido para o padrão de labels.
- Linux 2.2.0: modo `--somente-coleta` e modelo para o Alloy central.

### Coleta Complementar 1.0.0, Linux 2.1.0 e Windows 2.12.0

- Primeira versão da Coleta Complementar:
  - internet (status, DNS, IP público e diagnóstico);
  - links (failover, gateway da operadora e causa das quedas);
  - estado e eventos do Docker;
  - teste de velocidade.
- A Coleta grava arquivos locais; quem envia ao NOC é o próprio Alloy.

## 2026-08-21

### Instalador Windows 2.6.0 a 2.11.0

- 2.11.0: corrige o registro da tarefa do Speedtest (HRESULT 0x80041318).
- 2.10.0: falha num item opcional não desfaz a instalação.
- 2.9.0: intervalo de sondagem configurável; o Speedtest roda no mínimo a cada 5 minutos.
- 2.7.0: Internet e Exporters sempre aparecem no menu de reconfiguração.
- 2.6.0: elevação automática para administrador e correções críticas.

## 2026-08-14

- snmp.yml homologados por fabricante; instalador 2.4.0 com download por fabricante.
- Primeira versão dos scripts de instalação do monitoramento (Alloy).
