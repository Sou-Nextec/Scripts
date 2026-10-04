# Changelog do monitoramento Nextec

O que mudou nos instaladores, na Coleta Complementar e no atualizador automático. As entradas mais recentes ficam no topo.

Os números de versão seguem `MAIOR.MENOR.CORREÇÃO`:

- **MAIOR**: muda quando é preciso fazer algo à mão nas máquinas;
- **MENOR**: recurso novo;
- **CORREÇÃO**: ajuste sem mudança de comportamento.

| Componente | Arquivo | Versão atual |
| --- | --- | --- |
| Instalador Linux | `install-nextec-monitoring-linux-v2.sh` | 2.5.3 |
| Instalador Windows | `install-nextec-monitoring-windows-v2.ps1` | 2.15.3 |
| Coleta Complementar | `coleta-complementar/` | 1.2.0 |
| Atualizador automático | `atualizador/` | 1.0.0 |

## 2026-10-03

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
