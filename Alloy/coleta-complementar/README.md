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
| Módulos | internet, links, docker, velocidade, acessos, bancos | internet, links, acessos, bancos, velocidade |

Quem instala e liga é o instalador do Alloy (`install-nextec-monitoring-linux-v2.sh` 2.1.0+ e `install-nextec-monitoring-windows-v2.ps1` 2.12.0+; módulo acessos a partir de 2.4.0 e 2.14.0, que também instalam o [atualizador automático](../atualizador/README.md)): ao marcar Docker, Internet, Links, Velocidade ou um banco sem exportador próprio (Firebird, Oracle, SQL Anywhere, SQLite e, no Linux, SQL Server), ele baixa o arquivo deste diretório, grava a configuração, cria o serviço ou a tarefa e acrescenta no `config.alloy` a leitura dos arquivos. Modelo comentado da configuração: `coleta-complementar.ini.example`.

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
| Velocidade | | Sim (Ookla Speedtest CLI; no Windows a partir da 1.4.0, no lugar da tarefa NextecSpeedtest) |
| Acessos: logins com IP de origem, acesso privilegiado, origem nova, fora do horário | | Sim (journal no Linux; evento 4624 no Windows) |
| Bancos SQL Server (Windows), MySQL, MariaDB, PostgreSQL | Sim (coletores e exportadores do Alloy) | |
| Bancos Firebird, Oracle, SQL Anywhere, SQLite e SQL Server no Linux: no ar, conexões, memória, tempo ligado, tamanho das bases | | Sim (processo, portas e arquivos, sem driver nem login no banco) |

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
| `nextec_internet_estado_desde_segundos` | | Início do estado atual da saída padrão (epoch) |
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
| `nextec_link_info` | link, papel, operadora, tipo, suporte, ip_publico, gateway, alvos, firewall, interface_firewall, velocidade_mbps, velocidade_upload_mbps | Ficha do link. `ip_publico` vazio no INI é preenchido com o IP aprendido (visto quando só aquele link estava no ar) |
| `nextec_link_velocidade_contratada_mbps` | link, sentido (download, upload) | Velocidade contratada, informada na instalação |
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

**Velocidade** (Linux e Windows): `nextec_speedtest_up`, `_download_bits_per_second`, `_upload_bits_per_second`, `_ping_latency_milliseconds`, `_ping_jitter_milliseconds`, `_packet_loss_percent`, `_last_run_timestamp_seconds`, `_server_info`.

**Acessos** (Linux): `nextec_acessos_total{privilegiado, alerta}` e `nextec_acessos_coletor_ultima_execucao_segundos`.

**Bancos** (Linux e Windows). Mede pelo sistema operacional, sem driver nem usuário no banco: processo, portas em escuta, conexões TCP estabelecidas nessas portas e arquivos das bases. Requisições, cache, deadlocks e esperas precisam de SQL e ficam vazios no painel para esses motores.

| Métrica | Rótulos | Significado |
| --- | --- | --- |
| `nextec_banco_up` | motor, instancia | 1 com o processo no ar (SQLite: arquivo existe). Motor esperado (`motores`) e não encontrado sai com 0 |
| `nextec_banco_conexoes_total` | motor, instancia | Conexões TCP estabelecidas nas portas do banco |
| `nextec_banco_porta_info` | motor, instancia, porta | Portas em escuta |
| `nextec_banco_memoria_bytes` | motor, instancia | Memória do processo (não vale para Oracle, que usa memória compartilhada) |
| `nextec_banco_ligado_segundos` | motor, instancia | Tempo desde o início do processo |
| `nextec_banco_tamanho_bytes` | motor, instancia, banco | Tamanho de cada base: Firebird (`databases.conf`/`aliases.conf`), SQL Anywhere (arquivos `.db` da linha de comando), SQL Server no Linux (`/var/opt/mssql/data`), SQLite e `arquivos` |
| `nextec_bancos_coletor_ultima_execucao_segundos` | | Saúde do módulo |

`motor`: `Firebird`, `Oracle`, `SQL Anywhere`, `SQL Server` (só Linux) e `SQLite`. O painel "Nextec \| Banco de dados" converte essas métricas e as dos exportadores (`windows_mssql_*`, `mysql_*`, `pg_*`) para os mesmos indicadores, então todos os motores aparecem do mesmo jeito. No Linux o serviço roda com `ProtectHome=true`: base SQLite dentro de `/home` não é lida.

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

| `acesso_evento` | `login` | `login`: usuario, canal (`ssh`, `console`, `rdp`, `console_cache`), metodo, origem_ip, origem_tipo, origem_nova, privilegiado, conta_emergencia, fora_horario, alerta |
| `acesso_evento` | `elevacao` | `sudo`, `su` (Linux): usuario, usuario_destino, tty, comando, origem_ip da sessão |

Execuções do health check não viram evento de acesso. No `acesso_inicio` do Docker, `origem_ip` e `usuario_login` mostram a sessão SSH que abriu o `docker exec`; aberto pela API (console do Portainer), fica sem origem.

**Classificação dos acessos** (seção `[acessos]` do .ini):

| Campo | Valores |
| --- | --- |
| `origem_tipo` | `local` (console), `rede_interna` (IP privado, VPN, CGNAT), `rede_local` (mesmo IP público do local), `conhecida` (`origens_conhecidas`), `publica` |
| `origem_nova` | `sim` quando o usuário não entrou dessa rede (/24 no IPv4, /64 no IPv6) nos últimos 30 dias (`dias_origem_conhecida`) |
| `privilegiado` | Linux: root ou grupos `sudo`, `wheel`, `admin`, `docker` (`grupos_privilegiados`). Windows: token de administrador (ElevatedToken ou evento 4672) |
| `fora_horario` | Fora de `horario` (padrão `seg-sex 07:00-19:00; sab 07:00-14:00`, horário de Brasília) |
| `alerta` | `critico`: root ou Administrator embutido, ou privilegiado de origem pública nova. `resumo`: privilegiado fora do horário. `nenhum`: só registro |

Alertas no Grafana: "Acesso privilegiado suspeito" (alerta=critico, crítico) e "Acesso privilegiado fora do horário" (alerta=resumo, um aviso por dia por servidor). No primeiro mês de uso, toda origem pública é nova, então os primeiros acessos geram alerta até o histórico se formar. Parada pedida (`stop`, `restart`, atualização) vira `parado`, não `caiu`.

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
| 1.1.0 | 03/10/2026 | Módulo acessos (Linux e Windows) com origem e classificação para os alertas de acesso privilegiado; origem (usuário e IP da sessão SSH) no evento de terminal aberto em container. |
| 1.2.0 | 03/10/2026 | IP público de cada link aprendido sozinho (quando só ele está no ar), sem precisar informar na instalação; velocidade contratada por link (`nextec_link_velocidade_contratada_mbps`). |
| 1.4.0 | 05/10/2026 | Módulo velocidade no Windows (Speedtest CLI em segundo plano, sem atrasar os links), no lugar da tarefa NextecSpeedtest; `nextec_internet_estado_desde_segundos` (Linux e Windows), usado no painel NOC. |
| 1.3.0 | 05/10/2026 | Módulo bancos (Linux e Windows): Firebird, Oracle, SQL Anywhere, SQLite e SQL Server no Linux, com `nextec_banco_*`. No Windows, `[internet] ativo = nao` desliga a rodada de internet quando a coleta é instalada só para bancos. |
