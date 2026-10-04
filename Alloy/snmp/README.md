# Módulos SNMP homologados

Arquivos `snmp.yml` que os instaladores baixam quando o técnico escolhe o fabricante do equipamento. Eles dizem **o que coletar**. A credencial (community ou usuário SNMPv3) é do cliente e nunca entra aqui: o instalador grava em `snmp-auth.yml`, só no servidor ou na estação que faz a coleta.

| Arquivo | Fabricante | Origem |
| --- | --- | --- |
| `fortigate.yml` | FortiGate (FortiOS) | `gerar_modulos.py` |
| `sonicwall.yml` | SonicWall (SonicOS) | `gerar_modulos.py` |
| `mikrotik.yml` | MikroTik (RouterOS) | `gerar_modulos.py` |
| `pfsense.yml` | pfSense | generator oficial do snmp_exporter, com as MIBs do pfSense |
| `ubiquiti.yml` | Ubiquiti (UniFi e EdgeMAX) | `gerar_modulos.py` |
| `cisco.yml` | Cisco (IOS, IOS-XE e Catalyst) | `gerar_modulos.py` |
| `hp.yml` | HP / Aruba (ProCurve, ArubaOS-Switch e Comware) | `gerar_modulos.py` |
| `tplink.yml` | TP-Link (JetStream e Omada) | `gerar_modulos.py` |
| `intelbras.yml` | Intelbras (switches e roteadores) | `gerar_modulos.py` |

Cada arquivo tem duas variantes do mesmo módulo, `<fabricante>_v2c` e `<fabricante>_v3`. O conteúdo é igual; o instalador escolhe a variante pela versão da credencial.

## O que cada módulo coleta

| | FortiGate | SonicWall | MikroTik | pfSense |
| --- | --- | --- | --- | --- |
| Equipamento e firmware (`sysDescr`), tempo ligado | ✓ | ✓ | ✓ | ✓ |
| Interfaces: estado, velocidade, tráfego (64 bits), erros e descartes | ✓ | ✓ | ✓ | ✓ |
| CPU | `fgSysCpuUsage` | `sonicCurrentCPUUtil` | `hrProcessorLoad` | `hrProcessorLoad` |
| Memória | `fgSysMemUsage` | `sonicCurrentRAMUtil` | `hrStorage` | `hrStorage` |
| Conexões ativas | `fgSysSesCount` | `sonicCurrentConnCacheEntries` | | `pfStateTableCount` |
| Túneis IPsec | `fgVpnTunEnt*` | | | interfaces `ipsec*` |
| Usuários na VPN SSL | `fgVpnSslStatsLoginUsers` | | | |

Os nomes são os que o painel **Nextec | Firewall** consulta. Trocar um nome aqui sem trocar no painel apaga o gráfico.

### Switches, access points e roteadores

Todos coletam equipamento e firmware, tempo ligado e interfaces (estado, velocidade, tráfego de 64 bits, erros e descartes), com os mesmos nomes dos firewalls.

| | Ubiquiti | Cisco | HP / Aruba | TP-Link | Intelbras |
| --- | --- | --- | --- | --- | --- |
| CPU | `hrProcessorLoad`, `ssCpuIdle` | `cpmCPUTotal1minRev`, `cpmCPUTotal5minRev` | `hpSwitchCpuStat` (ProCurve), `hh3cEntityExtCpuUsage` (Comware) | `tpSysMonitorCpu1Minute` | `hrProcessorLoad`, se publicada |
| Memória | `memTotalReal`, `memAvailReal`, `hrStorage` | `ciscoMemoryPool*`, `cempMemPoolHC*` (IOS-XE) | `hpLocalMem*Bytes` (ProCurve), `hh3cEntityExtMemUsage` (Comware) | `tpSysMonitorMemoryUtilization` | `hrStorage`, se publicada |
| Temperatura e hardware | | `ciscoEnvMonTemperature*`, `ciscoEnvMonFanState`, `ciscoEnvMonSupplyState` | `hh3cEntityExtTemperature` (Comware) | | |
| Wi-Fi | `unifiVapNumStations` por SSID (UniFi AP) | | | | |

A linha Intelbras usa firmwares de origens diferentes, sem MIB própria comum a todos, por isso o módulo fica no padrão. Os cinco foram conferidos no simulador (snmpsim) com os OIDs das MIBs de cada fabricante; confirme no primeiro equipamento real de cada um.

## Alterar ou incluir um fabricante

1. Edite `gerar_modulos.py` (OIDs da MIB do fabricante) e rode `python3 gerar_modulos.py`.
2. Confira a sintaxe com o snmp_exporter: `snmp_exporter --dry-run --config.file=auth.yml --config.file=<fabricante>.yml`, com um `auth.yml` de teste.
3. Teste contra um equipamento real ou um simulador (snmpsim) e veja as métricas em `/snmp?target=...&module=<fabricante>_v2c&auth=...`.
4. Inclua o fabricante na lista `SNMP_FABRICANTES` do instalador Linux e em `$NextecSnmpVendors` do instalador Windows.
5. Registre no `Alloy/CHANGELOG.md`.

O SonicWall também foi conferido só no simulador, com os OIDs da SONICWALL-FIREWALL-IP-STATISTICS-MIB. Confirme no primeiro equipamento real.
