# Coleta Complementar Nextec

Completa o que o Grafana Alloy não coleta sozinho. É um arquivo único por sistema, com módulos que se ligam pela configuração. Ela **não envia nada** para a central: grava métricas em arquivos `.prom` e eventos em JSON por linha, e o Alloy já instalado lê e envia com a mesma credencial e os mesmos rótulos do servidor.

| Item | Linux | Windows |
| --- | --- | --- |
| Arquivo | `coleta-complementar.py` (Python 3, só biblioteca padrão) | `coleta-complementar.ps1` (PowerShell 5.1) |
| Instalado em | `/usr/local/lib/nextec/coleta-complementar.py` | `C:\ProgramData\GrafanaLabs\Alloy\coleta-complementar\` |
| Configuração | `/etc/coleta-complementar/coleta-complementar.ini` | `...\coleta-complementar\coleta-complementar.ini` |
| Execução | serviço `coleta-complementar` (systemd) | tarefa agendada `NextecColetaComplementar` (SYSTEM) |
| Métricas | `/var/lib/coleta-complementar/textfile/*.prom` | `...\coleta-complementar\textfile\*.prom` |
| Eventos | `/var/log/coleta-complementar/eventos.jsonl` | `...\coleta-complementar\eventos.jsonl` |
| Módulos | internet, links, docker, velocidade | internet, links (velocidade fica com a tarefa NextecSpeedtest do instalador) |

Quem instala e liga é o instalador do Alloy (`install-nextec-monitoring-linux-v2.sh` 2.1.0+ e `install-nextec-monitoring-windows-v2.ps1` 2.12.0+): ao marcar Docker, Internet, Links ou Velocidade, ele baixa o arquivo deste diretório, grava a configuração, cria o serviço ou a tarefa e acrescenta no `config.alloy` a leitura dos arquivos. Modelo comentado da configuração: `coleta-complementar.ini.example`.

## Divisão com o Alloy

| Assunto | Alloy | Coleta Complementar |
| --- | --- | --- |
| Servidor (CPU, memória, disco, serviços) | Sim | |
| Logs do sistema | Sim | |
| Sites e sistemas (Blackbox) | Sim | |
| Logs dos containers | Sim (`loki.source.docker`) | |
| Docker: estado, health, saída, consumo, configuração, espaço, eventos | | Sim (API do Docker). O cAdvisor do Alloy não enxerga containers no Docker com armazenamento de imagens do containerd |
| Internet: status, DNS, IP público, diagnóstico | | Sim |
| Links: status, qualidade, link em uso, gateway da operadora, causa das quedas | | Sim |
| Velocidade no Linux | | Sim (Ookla Speedtest CLI) |

## Comandos

```bash
# Linux
python3 /usr/local/lib/nextec/coleta-complementar.py verificar   # configuração e dependências
python3 /usr/local/lib/nextec/coleta-complementar.py uma-vez      # uma rodada, mostra o que gravou
systemctl status coleta-complementar
journalctl -u coleta-complementar -n 50
```

```powershell
# Windows
$cc = "C:\ProgramData\GrafanaLabs\Alloy\coleta-complementar\coleta-complementar.ps1"
powershell -ExecutionPolicy Bypass -File $cc -Acao verificar
powershell -ExecutionPolicy Bypass -File $cc -Acao uma-vez
Get-ScheduledTask -TaskName NextecColetaComplementar | Get-ScheduledTaskInfo
Get-Content C:\ProgramData\GrafanaLabs\Alloy\coleta-complementar\coleta-complementar.log -Tail 30
```

## Contrato de métricas

Rótulos `cliente`, `host`, `ambiente`, `local` etc. são acrescentados pelo Alloy. O scrape usa `honor_labels = true` para manter os rótulos próprios (ex.: `tipo` do link).

**Internet e links** (job `integrations/coleta_complementar`)

| Métrica | Rótulos | Significado |
| --- | --- | --- |
| `nextec_internet_status` | | 0 fora, 1 normal, 2 degradada (saída padrão) |
| `nextec_internet_latencia_ms`, `_perda_percentual`, `_jitter_ms` | | Qualidade da saída padrão (perda do melhor destino) |
| `nextec_internet_alvo_latencia_ms`, `_alvo_perda_percentual` | alvo | Por destino |
| `nextec_internet_diagnostico` | diagnostico | Texto do diagnóstico atual |
| `nextec_internet_rodadas_total`, `_rodadas_fora_total`, `_rodadas_degradado_total`, `_segundos_fora_total` | | Contadores de disponibilidade |
| `nextec_internet_ip_publico_info`, `nextec_internet_ip_publico_sucesso` | ip | IP público atual |
| `nextec_internet_link_ativo_info` | link | Link em uso |
| `nextec_internet_firewall_status` | firewall | Firewall/gateway local respondendo |
| `nextec_link_status` | link | 0 fora, 1 normal, 2 degradado |
| `nextec_link_diagnostico` | link, diagnostico | Normal, degradado (motivo) ou fora (causa) |
| `nextec_link_latencia_ms`, `_perda_percentual`, `_jitter_ms` | link | Qualidade do link |
| `nextec_link_alvo_latencia_ms`, `_alvo_perda_percentual` | link, alvo | Por destino |
| `nextec_link_gateway_status`, `_gateway_latencia_ms` | link | Gateway da operadora |
| `nextec_link_ativo` | link | 1 no link que carrega o tráfego |
| `nextec_link_estado_desde_segundos` | link | Início do estado atual (epoch) |
| `nextec_link_rodadas_total`, `_rodadas_fora_total`, `_rodadas_degradado_total`, `_segundos_fora_total` | link | Contadores de disponibilidade |
| `nextec_link_info` | link, papel, operadora, tipo, suporte, ip_publico, gateway, alvos, firewall, interface_firewall | Ficha do link |
| `nextec_dns_sucesso`, `nextec_dns_resposta_ms`, `nextec_dns_consultas_total`, `nextec_dns_falhas_total` | servidor | DNS |
| `nextec_links_coletor_ultima_execucao_segundos`, `nextec_links_intervalo_segundos`, `nextec_links_limite_latencia_ms`, `nextec_links_limite_perda_percentual` | | Saúde e parâmetros do monitor |

Causas de queda: `rede local: firewall sem resposta`, `operadora: gateway sem resposta`, `operadora: gateway responde, sem saída para a internet`, `todos os links sem saída com gateways respondendo: instabilidade geral ou firewall`, `sem saída para a internet (gateway da operadora não configurado)`.

**Docker** (só Linux)

| Métrica | Rótulos | Significado |
| --- | --- | --- |
| `docker_engine_ativo`, `docker_engine_info`, `docker_engine_cpus`, `docker_engine_memoria_bytes` | versao, sistema | Docker do servidor |
| `docker_container_estado` | name, stack | 0 parado, 1 rodando, 2 reiniciando, 3 pausado |
| `docker_container_health` | name, stack | 1 saudável, 0 com falha, 2 iniciando (só com health check) |
| `docker_container_info` | name, stack, image, restart_policy | Ficha |
| `docker_container_criacao_segundos`, `_inicio_segundos`, `_fim_segundos` | name, stack | Datas (epoch) |
| `docker_container_reinicios_total`, `_codigo_saida`, `_oom` | name, stack | Estabilidade |
| `docker_container_cpu_segundos_total`, `_memoria_bytes`, `_rede_recebido_bytes_total`, `_rede_enviado_bytes_total`, `_disco_lido_bytes_total`, `_disco_escrito_bytes_total` | name, stack | Consumo |
| `docker_container_limite_memoria_bytes`, `_privilegiado`, `_docker_sock`, `_rede_host`, `_usuario_root`, `_tag_latest`, `_imagem_criacao_segundos` | name, stack | Configuração e segurança |
| `docker_container_porta` | name, stack, porta_host, porta_container, protocolo, ip, exposicao | `publica`, `local`, `restrita` ou `interna` |
| `docker_container_montagem` | name, stack, tipo, origem, destino, modo | Volumes e pastas |
| `docker_container_rede` | name, stack, rede, ip | Redes |
| `docker_espaco_bytes`, `docker_espaco_recuperavel_bytes` | tipo | imagens, containers, volumes, cache |
| `docker_coletor_ultima_execucao_segundos` | | Saúde do módulo |

`stack` é o projeto do compose (`com.docker.compose.project`) ou do Swarm; `avulso` quando não há.

**Velocidade** (Linux; mesmos nomes do instalador Windows): `nextec_speedtest_up`, `_download_bits_per_second`, `_upload_bits_per_second`, `_ping_latency_milliseconds`, `_ping_jitter_milliseconds`, `_packet_loss_percent`, `_last_run_timestamp_seconds`, `_server_info`.

**A própria coleta**: `nextec_coleta_complementar_info{versao, modulos}` e `nextec_coleta_complementar_modulo_ok{modulo}`.

## Eventos (Loki)

Um JSON por linha. `tipo`, `categoria` e `link` viram rótulos no Loki; o restante é lido com `| json`.

| tipo | categoria | evento |
| --- | --- | --- |
| `links_evento` | `queda` | `link_caiu` (causa, queda_id), `link_voltou` (duracao_s), `internet_caiu`, `internet_voltou`, `rota_na_queda` (rota, ultimo_salto) |
| `links_evento` | `qualidade` | `link_degradado`, `link_normalizado`, `internet_degradado`, `internet_normalizado` |
| `links_evento` | `failover` | `link_ativo_mudou`, `ip_publico_mudou` (de, para) |
| `links_evento` | `instabilidade_externa` | `destino_sem_resposta`, `destino_voltou` (alvo) |
| `links_evento` | `velocidade` | `teste_velocidade` (download_mbps, upload_mbps, latencia_ms) |
| `links_evento` | `sistema` | `coletor_iniciado` |
| `docker_evento` | `falha` | `caiu` (código diferente de 0, sem parada pedida), `sem_memoria`, `unhealthy`, `healthy` |
| `docker_evento` | `acesso` | `acesso_inicio` (tty, comando, usuario_container, exec_id), `acesso_fim`, `arquivo_lido`, `arquivo_gravado`, `exportado` |
| `docker_evento` | `auditoria` | `criado`, `removido`, `iniciado`, `parado`, `reiniciado`, `renomeado`, `alterado`, `pausado`, `retomado`, `imagem_gerada` |
| `docker_evento` | `imagem` | `imagem_baixada`, `imagem_removida`, `imagem_marcada`, `imagem_desmarcada`, `imagem_enviada`, `imagem_importada`, `imagem_carregada`, `imagem_salva` |

Execuções do health check não viram evento de acesso. Parada pedida (`stop`, `restart`, atualização) vira `parado`, não `caiu`.

## Servidor cujo Alloy não veio do instalador

Caso do servidor da central (`nxt-srv-app01`), coletado pelo Alloy da stack em container.

```bash
sudo bash install-nextec-monitoring-linux-v2.sh --somente-coleta
```

Instala só a Coleta Complementar (serviço `coleta-complementar`), sem tocar no Alloy. Depois, inclua no arquivo do cliente no Alloy central o bloco de `alloy-central.alloy.example`, com os caminhos como o container os enxerga (`/rootfs/var/lib/coleta-complementar/textfile` e `/var/log/coleta-complementar/eventos.jsonl`).

## Testar uma branch

```bash
COLETA_URL=https://raw.githubusercontent.com/Sou-Nextec/Scripts/<branch>/Alloy/coleta-complementar/coleta-complementar.py \
  bash install-nextec-monitoring-linux-v2.sh
```

```powershell
$env:NEXTEC_COLETA_URL = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/<branch>/Alloy/coleta-complementar/coleta-complementar.ps1"
```

## Histórico

| Versão | Data | Mudanças |
| --- | --- | --- |
| 1.0.0 | 03/10/2026 | Primeira versão: internet, links, Docker e velocidade (Linux); internet e links (Windows). |
