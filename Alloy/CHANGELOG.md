# Changelog do monitoramento Nextec

O que mudou nos instaladores, na Coleta Complementar e no atualizador automático. As entradas mais recentes ficam no topo.

Os números de versão seguem `MAIOR.MENOR.CORREÇÃO`:

- **MAIOR**: muda quando é preciso fazer algo à mão nas máquinas;
- **MENOR**: recurso novo;
- **CORREÇÃO**: ajuste sem mudança de comportamento.

| Componente | Arquivo | Versão atual |
| --- | --- | --- |
| Instalador Linux | `install-nextec-monitoring-linux-v2.sh` | 2.5.0 |
| Instalador Windows | `install-nextec-monitoring-windows-v2.ps1` | 2.14.1 |
| Coleta Complementar | `coleta-complementar/` | 1.1.0 |
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
