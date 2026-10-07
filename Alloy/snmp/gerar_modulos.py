#!/usr/bin/env python3
"""Gera os snmp.yml homologados da Nextec (todos os fabricantes, menos o pfSense).

Fabricantes de rede (firewall, switch, AP), NAS (QNAP, Synology, TrueNAS e
o módulo genérico "nas") e servidores Dell pelo iDRAC (módulo "dell").

Cada fabricante sai com duas variantes do mesmo módulo, `<fabricante>_v2c` e
`<fabricante>_v3`. O conteúdo é igual; o sufixo só existe para o instalador
escolher a variante pela versão SNMP da credencial.

O pfsense.yml não sai daqui: ele é gerado pelo generator oficial do
snmp_exporter, a partir das MIBs do pfSense.

Os nomes das métricas são os que os painéis do NOC consultam (Nextec |
Firewall, Nextec | NAS e Nextec | Hardware). Trocar um nome aqui
sem trocar no painel apaga o gráfico.

Uso: python3 gerar_modulos.py   (grava os .yml nesta pasta)
"""

from pathlib import Path

PASTA = Path(__file__).resolve().parent

# Interfaces (IF-MIB). Os painéis usam ifName para identificar a porta, os
# contadores de 64 bits (ifHC*) e ifHighSpeed (Mbps).
INTERFACE = [
    ("ifAdminStatus", "1.3.6.1.2.1.2.2.1.7", "gauge", "Estado configurado da interface (1=up 2=down 3=testing)"),
    ("ifOperStatus", "1.3.6.1.2.1.2.2.1.8", "gauge", "Estado operacional da interface (1=up 2=down)"),
    ("ifInDiscards", "1.3.6.1.2.1.2.2.1.13", "counter", "Pacotes recebidos descartados"),
    ("ifInErrors", "1.3.6.1.2.1.2.2.1.14", "counter", "Pacotes recebidos com erro"),
    ("ifOutDiscards", "1.3.6.1.2.1.2.2.1.19", "counter", "Pacotes enviados descartados"),
    ("ifOutErrors", "1.3.6.1.2.1.2.2.1.20", "counter", "Pacotes enviados com erro"),
    ("ifHCInOctets", "1.3.6.1.2.1.31.1.1.1.6", "counter", "Bytes recebidos (64 bits)"),
    ("ifHCOutOctets", "1.3.6.1.2.1.31.1.1.1.10", "counter", "Bytes enviados (64 bits)"),
    ("ifHighSpeed", "1.3.6.1.2.1.31.1.1.1.15", "gauge", "Velocidade da interface em Mbps"),
]

# Lookups aplicados em todas as métricas de interface.
LOOKUPS_INTERFACE = [
    ("ifName", "1.3.6.1.2.1.31.1.1.1.1"),
    ("ifAlias", "1.3.6.1.2.1.31.1.1.1.18"),
    ("ifDescr", "1.3.6.1.2.1.2.2.1.2"),
]

SISTEMA = [
    ("sysDescr", "1.3.6.1.2.1.1.1", "DisplayString", "Descrição do equipamento e firmware"),
    ("sysUpTime", "1.3.6.1.2.1.1.3", "gauge", "Tempo ligado, em centésimos de segundo"),
]

# HOST-RESOURCES-MIB: processador e memória. O painel usa hrProcessorLoad e
# hrStorage com descrição "main memory", "physical memory" ou "ram".
HOST_RESOURCES = [
    ("hrStorageDescr", "1.3.6.1.2.1.25.2.3.1.3", "DisplayString", "Descrição da área de armazenamento"),
    ("hrStorageAllocationUnits", "1.3.6.1.2.1.25.2.3.1.4", "gauge", "Tamanho da unidade de alocação em bytes"),
    ("hrStorageSize", "1.3.6.1.2.1.25.2.3.1.5", "gauge", "Tamanho em unidades de alocação"),
    ("hrStorageUsed", "1.3.6.1.2.1.25.2.3.1.6", "gauge", "Uso em unidades de alocação"),
    ("hrProcessorLoad", "1.3.6.1.2.1.25.3.3.1.2", "gauge", "Uso de cada processador no último minuto, em porcentagem"),
]

# UCD-SNMP-MIB (net-snmp): CPU e memória dos equipamentos com Linux embarcado,
# como os UniFi. Escalares, lidos por "get".
UCD = [
    ("ssCpuIdle", "1.3.6.1.4.1.2021.11.11", "gauge", "CPU ociosa em porcentagem"),
    ("memTotalReal", "1.3.6.1.4.1.2021.4.5", "gauge", "Memória total em KB"),
    ("memAvailReal", "1.3.6.1.4.1.2021.4.6", "gauge", "Memória livre em KB"),
    ("memBuffer", "1.3.6.1.4.1.2021.4.14", "gauge", "Memória em buffers em KB"),
    ("memCached", "1.3.6.1.4.1.2021.4.15", "gauge", "Memória em cache em KB"),
]

FABRICANTES = {
    "fortigate": {
        "titulo": "FortiGate (FortiOS)",
        "mib": "FORTINET-FORTIGATE-MIB",
        "host_resources": False,
        "escalares": [
            ("fgSysVersion", "1.3.6.1.4.1.12356.101.4.1.1", "DisplayString", "Versão do FortiOS"),
            ("fgSysCpuUsage", "1.3.6.1.4.1.12356.101.4.1.3", "gauge", "Uso de CPU em porcentagem"),
            ("fgSysMemUsage", "1.3.6.1.4.1.12356.101.4.1.4", "gauge", "Uso de memória em porcentagem"),
            ("fgSysMemCapacity", "1.3.6.1.4.1.12356.101.4.1.5", "gauge", "Memória total em KB"),
            ("fgSysSesCount", "1.3.6.1.4.1.12356.101.4.1.8", "gauge", "Sessões ativas"),
            ("fgSysSesRate1", "1.3.6.1.4.1.12356.101.4.1.11", "gauge", "Novas sessões por segundo, média de 1 minuto"),
            ("fgHaSystemMode", "1.3.6.1.4.1.12356.101.13.1.1", "gauge", "Modo de HA (1=standalone 2=activeActive 3=activePassive)"),
        ],
        # Túneis IPsec (fgVpnTunTable). Status: 1=down 2=up.
        "tabelas": [
            {
                "indice": "fgVpnTunEntIndex",
                "walk": "1.3.6.1.4.1.12356.101.12.2.2.1",
                "lookups": [("fgVpnTunEntPhase1Name", "1.3.6.1.4.1.12356.101.12.2.2.1.2"),
                            ("fgVpnTunEntPhase2Name", "1.3.6.1.4.1.12356.101.12.2.2.1.3")],
                "metricas": [
                    ("fgVpnTunEntInOctets", "1.3.6.1.4.1.12356.101.12.2.2.1.18", "counter", "Bytes recebidos pelo túnel"),
                    ("fgVpnTunEntOutOctets", "1.3.6.1.4.1.12356.101.12.2.2.1.19", "counter", "Bytes enviados pelo túnel"),
                    ("fgVpnTunEntStatus", "1.3.6.1.4.1.12356.101.12.2.2.1.20", "gauge", "Estado do túnel (1=down 2=up)"),
                ],
            },
            {
                "indice": "fgVpnSslStatsIndex",
                "walk": "1.3.6.1.4.1.12356.101.12.2.3.1",
                "lookups": [],
                "metricas": [
                    ("fgVpnSslStatsLoginUsers", "1.3.6.1.4.1.12356.101.12.2.3.1.2", "gauge", "Usuários conectados na VPN SSL"),
                ],
            },
        ],
    },
    "mikrotik": {
        "titulo": "MikroTik (RouterOS)",
        "mib": "HOST-RESOURCES-MIB (o RouterOS publica CPU e memória por ela)",
        "host_resources": True,
        "escalares": [],
        "tabelas": [],
    },
    "sonicwall": {
        "titulo": "SonicWall (SonicOS)",
        "mib": "SONICWALL-FIREWALL-IP-STATISTICS-MIB",
        "host_resources": False,
        "escalares": [
            ("sonicMaxConnCacheEntries", "1.3.6.1.4.1.8741.1.3.1.1", "gauge", "Máximo de conexões suportado"),
            ("sonicCurrentConnCacheEntries", "1.3.6.1.4.1.8741.1.3.1.2", "gauge", "Conexões ativas"),
            ("sonicCurrentCPUUtil", "1.3.6.1.4.1.8741.1.3.1.3", "gauge", "Uso de CPU em porcentagem"),
            ("sonicCurrentRAMUtil", "1.3.6.1.4.1.8741.1.3.1.4", "gauge", "Uso de memória em porcentagem"),
        ],
        "tabelas": [],
    },
    "ubiquiti": {
        "titulo": "Ubiquiti (UniFi e EdgeMAX)",
        "mib": "HOST-RESOURCES-MIB, UCD-SNMP-MIB e UBNT-UniFi-MIB",
        "host_resources": True,
        "escalares": UCD,
        # Redes Wi-Fi do access point UniFi (unifiVapTable): uma linha por SSID
        # e rádio. Em switch e roteador a tabela não existe e fica vazia.
        "tabelas": [
            {
                "indice": "unifiVapIndex",
                "walk": "1.3.6.1.4.1.41112.1.6.1.2.1",
                "lookups": [("unifiVapEssId", "1.3.6.1.4.1.41112.1.6.1.2.1.6"),
                            ("unifiVapRadio", "1.3.6.1.4.1.41112.1.6.1.2.1.9")],
                "metricas": [
                    ("unifiVapChannel", "1.3.6.1.4.1.41112.1.6.1.2.1.4", "gauge", "Canal do rádio"),
                    ("unifiVapNumStations", "1.3.6.1.4.1.41112.1.6.1.2.1.8", "gauge", "Clientes conectados no SSID"),
                ],
            },
        ],
    },
    "cisco": {
        "titulo": "Cisco (IOS, IOS-XE e Catalyst)",
        "mib": "CISCO-PROCESS-MIB, CISCO-MEMORY-POOL-MIB, CISCO-ENHANCED-MEMPOOL-MIB e CISCO-ENVMON-MIB",
        "host_resources": False,
        "escalares": [],
        "tabelas": [
            {
                "indice": "cpmCPUTotalIndex",
                "walk": ["1.3.6.1.4.1.9.9.109.1.1.1.1.7", "1.3.6.1.4.1.9.9.109.1.1.1.1.8"],
                "lookups": [],
                "metricas": [
                    ("cpmCPUTotal1minRev", "1.3.6.1.4.1.9.9.109.1.1.1.1.7", "gauge", "Uso de CPU em porcentagem, média de 1 minuto"),
                    ("cpmCPUTotal5minRev", "1.3.6.1.4.1.9.9.109.1.1.1.1.8", "gauge", "Uso de CPU em porcentagem, média de 5 minutos"),
                ],
            },
            # Memória: modelos antigos publicam a CISCO-MEMORY-POOL-MIB e os
            # novos (IOS-XE) a CISCO-ENHANCED-MEMPOOL-MIB. Coleta as duas; o
            # equipamento responde só a que tem.
            {
                "indice": "ciscoMemoryPoolType",
                "walk": ["1.3.6.1.4.1.9.9.48.1.1.1.2", "1.3.6.1.4.1.9.9.48.1.1.1.5", "1.3.6.1.4.1.9.9.48.1.1.1.6"],
                "lookups": [("ciscoMemoryPoolName", "1.3.6.1.4.1.9.9.48.1.1.1.2")],
                "metricas": [
                    ("ciscoMemoryPoolUsed", "1.3.6.1.4.1.9.9.48.1.1.1.5", "gauge", "Memória usada no pool, em bytes"),
                    ("ciscoMemoryPoolFree", "1.3.6.1.4.1.9.9.48.1.1.1.6", "gauge", "Memória livre no pool, em bytes"),
                ],
            },
            {
                "indice": ["entPhysicalIndex", "cempMemPoolIndex"],
                "walk": ["1.3.6.1.4.1.9.9.221.1.1.1.1.3", "1.3.6.1.4.1.9.9.221.1.1.1.1.18", "1.3.6.1.4.1.9.9.221.1.1.1.1.20"],
                "lookups": [("cempMemPoolName", "1.3.6.1.4.1.9.9.221.1.1.1.1.3")],
                "metricas": [
                    ("cempMemPoolHCUsed", "1.3.6.1.4.1.9.9.221.1.1.1.1.18", "gauge", "Memória usada no pool, em bytes (64 bits)"),
                    ("cempMemPoolHCFree", "1.3.6.1.4.1.9.9.221.1.1.1.1.20", "gauge", "Memória livre no pool, em bytes (64 bits)"),
                ],
            },
            # Ambiente (CISCO-ENVMON-MIB). Estado: 1=normal 2=warning
            # 3=critical 4=shutdown 5=notPresent 6=notFunctioning.
            {
                "indice": "ciscoEnvMonTemperatureStatusIndex",
                "walk": ["1.3.6.1.4.1.9.9.13.1.3.1.2", "1.3.6.1.4.1.9.9.13.1.3.1.3", "1.3.6.1.4.1.9.9.13.1.3.1.6"],
                "lookups": [("ciscoEnvMonTemperatureStatusDescr", "1.3.6.1.4.1.9.9.13.1.3.1.2")],
                "metricas": [
                    ("ciscoEnvMonTemperatureStatusValue", "1.3.6.1.4.1.9.9.13.1.3.1.3", "gauge", "Temperatura em graus Celsius"),
                    ("ciscoEnvMonTemperatureState", "1.3.6.1.4.1.9.9.13.1.3.1.6", "gauge", "Estado do sensor de temperatura (1=normal 2=warning 3=critical)"),
                ],
            },
            {
                "indice": "ciscoEnvMonFanStatusIndex",
                "walk": ["1.3.6.1.4.1.9.9.13.1.4.1.2", "1.3.6.1.4.1.9.9.13.1.4.1.3"],
                "lookups": [("ciscoEnvMonFanStatusDescr", "1.3.6.1.4.1.9.9.13.1.4.1.2")],
                "metricas": [
                    ("ciscoEnvMonFanState", "1.3.6.1.4.1.9.9.13.1.4.1.3", "gauge", "Estado da ventoinha (1=normal 2=warning 3=critical)"),
                ],
            },
            {
                "indice": "ciscoEnvMonSupplyStatusIndex",
                "walk": ["1.3.6.1.4.1.9.9.13.1.5.1.2", "1.3.6.1.4.1.9.9.13.1.5.1.3"],
                "lookups": [("ciscoEnvMonSupplyStatusDescr", "1.3.6.1.4.1.9.9.13.1.5.1.2")],
                "metricas": [
                    ("ciscoEnvMonSupplyState", "1.3.6.1.4.1.9.9.13.1.5.1.3", "gauge", "Estado da fonte (1=normal 2=warning 3=critical)"),
                ],
            },
        ],
    },
    "hp": {
        "titulo": "HP / Aruba (ProCurve, ArubaOS-Switch e Comware)",
        "mib": "STATISTICS-MIB e NETSWITCH-MIB (ProCurve/ArubaOS-Switch) e HH3C-ENTITY-EXT-MIB (Comware)",
        "host_resources": False,
        # ProCurve e ArubaOS-Switch.
        "escalares": [
            ("hpSwitchCpuStat", "1.3.6.1.4.1.11.2.14.11.5.1.9.6.1", "gauge", "Uso de CPU em porcentagem (ProCurve/ArubaOS-Switch)"),
        ],
        "tabelas": [
            {
                "indice": "hpLocalMemSlotIndex",
                "walk": ["1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.5", "1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.6"],
                "lookups": [],
                "metricas": [
                    ("hpLocalMemTotalBytes", "1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.5", "gauge", "Memória total em bytes (ProCurve/ArubaOS-Switch)"),
                    ("hpLocalMemFreeBytes", "1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.6", "gauge", "Memória livre em bytes (ProCurve/ArubaOS-Switch)"),
                ],
            },
            # Comware (série 1920/1950/5130 e H3C): uma linha por entidade
            # física; as que não são placa ou módulo respondem 0.
            {
                "indice": "hh3cEntityExtPhysicalIndex",
                "walk": ["1.3.6.1.4.1.25506.2.6.1.1.1.1.6", "1.3.6.1.4.1.25506.2.6.1.1.1.1.8", "1.3.6.1.4.1.25506.2.6.1.1.1.1.12"],
                "lookups": [],
                "metricas": [
                    ("hh3cEntityExtCpuUsage", "1.3.6.1.4.1.25506.2.6.1.1.1.1.6", "gauge", "Uso de CPU em porcentagem (Comware)"),
                    ("hh3cEntityExtMemUsage", "1.3.6.1.4.1.25506.2.6.1.1.1.1.8", "gauge", "Uso de memória em porcentagem (Comware)"),
                    ("hh3cEntityExtTemperature", "1.3.6.1.4.1.25506.2.6.1.1.1.1.12", "gauge", "Temperatura em graus Celsius (Comware)"),
                ],
            },
        ],
    },
    "tplink": {
        "titulo": "TP-Link (JetStream e Omada)",
        "mib": "TPLINK-SYSMONITOR-MIB",
        "host_resources": False,
        "escalares": [],
        "tabelas": [
            {
                "indice": "tpSysMonitorCpuNumber",
                "walk": ["1.3.6.1.4.1.11863.6.4.1.1.1.1.2", "1.3.6.1.4.1.11863.6.4.1.1.1.1.3"],
                "lookups": [],
                "metricas": [
                    ("tpSysMonitorCpu5Seconds", "1.3.6.1.4.1.11863.6.4.1.1.1.1.2", "gauge", "Uso de CPU em porcentagem, últimos 5 segundos"),
                    ("tpSysMonitorCpu1Minute", "1.3.6.1.4.1.11863.6.4.1.1.1.1.3", "gauge", "Uso de CPU em porcentagem, último minuto"),
                ],
            },
            {
                "indice": "tpSysMonitorMemoryNumber",
                "walk": ["1.3.6.1.4.1.11863.6.4.1.2.1.1.2"],
                "lookups": [],
                "metricas": [
                    ("tpSysMonitorMemoryUtilization", "1.3.6.1.4.1.11863.6.4.1.2.1.1.2", "gauge", "Uso de memória em porcentagem"),
                ],
            },
        ],
    },
    # A linha de switches Intelbras usa firmwares de fabricantes diferentes,
    # sem MIB própria comum a todos. O módulo fica no padrão: equipamento,
    # interfaces e, quando publicada, a HOST-RESOURCES-MIB.
    "intelbras": {
        "titulo": "Intelbras (switches e roteadores)",
        "mib": "HOST-RESOURCES-MIB (quando o equipamento publica)",
        "host_resources": True,
        "escalares": [],
        "tabelas": [],
    },
    # ------------------------------------------------------------------
    # NAS e servidores. As MIBs desses fabricantes usam nomes genéricos
    # (diskStatus, raidStatus, temperature) que se repetem entre eles com
    # significados diferentes. Por isso as métricas levam o prefixo do
    # fabricante (qnap, syno, truenas, idrac): o mesmo nome nunca mistura
    # dois fabricantes num painel ou numa regra.
    #
    # Estado em texto (DisplayString) vira rótulo: a série sai com valor 1 e o
    # texto no rótulo de mesmo nome, ex.: qnapRaidStatus{qnapRaidStatus="Ready"}.
    # ------------------------------------------------------------------
    # QNAP (QTS e QuTS hero), NAS-MIB. Dois ramos convivem: o "EX"
    # (24681.1.3), presente desde o QTS 4.0, e o do QTS 4.x em diante
    # (24681.1.4), que traz pool, RAID, SMART em número, fonte e estado das
    # ventoinhas. Coleta os dois; o equipamento responde só o que tem.
    # Capacidades em bytes. A memória (EX) também em bytes.
    "qnap": {
        "titulo": "QNAP (QTS e QuTS hero)",
        "mib": "NAS-MIB (QNAP), HOST-RESOURCES-MIB e UCD-SNMP-MIB",
        "painel": "Nextec | NAS",
        "host_resources": True,
        "escalares": [
            ("qnapCpuUsage", "1.3.6.1.4.1.24681.1.3.1", "gauge", "Uso de CPU em porcentagem"),
            ("qnapMemTotal", "1.3.6.1.4.1.24681.1.3.2", "gauge", "Memória total em bytes"),
            ("qnapMemFree", "1.3.6.1.4.1.24681.1.3.3", "gauge", "Memória livre em bytes"),
            ("qnapCpuTemperature", "1.3.6.1.4.1.24681.1.3.5", "gauge", "Temperatura da CPU em graus Celsius"),
            ("qnapSystemTemperature", "1.3.6.1.4.1.24681.1.3.6", "gauge", "Temperatura do sistema em graus Celsius"),
            ("qnapModel", "1.3.6.1.4.1.24681.1.3.12", "DisplayString", "Modelo do NAS"),
        ] + UCD,
        "tabelas": [
            # Discos (ramo EX). hdStatus: 0=ready -4=unknown -5=noDisk
            # -6=invalid -9=rwError. hdSmartInfo em texto (GOOD, Normal...).
            {
                "indice": "hdIndex",
                "walk": "1.3.6.1.4.1.24681.1.3.11.1",
                "lookups": [("hdDescr", "1.3.6.1.4.1.24681.1.3.11.1.2"),
                            ("hdModel", "1.3.6.1.4.1.24681.1.3.11.1.5")],
                "metricas": [
                    ("qnapHdTemperature", "1.3.6.1.4.1.24681.1.3.11.1.3", "gauge", "Temperatura do disco em graus Celsius"),
                    ("qnapHdStatus", "1.3.6.1.4.1.24681.1.3.11.1.4", "gauge", "Estado do disco (0=ready -4=unknown -5=noDisk -6=invalid -9=rwError)"),
                    ("qnapHdCapacity", "1.3.6.1.4.1.24681.1.3.11.1.6", "gauge", "Capacidade do disco em bytes"),
                    ("qnapHdSmartInfo", "1.3.6.1.4.1.24681.1.3.11.1.7", "DisplayString", "Resumo SMART do disco, em texto"),
                ],
            },
            # Discos (QTS 4.x+). diskSmartInfo: 0=good 1=warning 2=abnormal -1=error.
            {
                "indice": "diskIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.1.5.2.1",
                "lookups": [("diskModel", "1.3.6.1.4.1.24681.1.4.1.1.1.1.5.2.1.8")],
                "metricas": [
                    ("qnapDiskSmartInfo", "1.3.6.1.4.1.24681.1.4.1.1.1.1.5.2.1.5", "gauge", "SMART do disco (0=good 1=warning 2=abnormal -1=error)"),
                    ("qnapDiskTemperature", "1.3.6.1.4.1.24681.1.4.1.1.1.1.5.2.1.6", "gauge", "Temperatura do disco em graus Celsius"),
                    ("qnapDiskCapacity", "1.3.6.1.4.1.24681.1.4.1.1.1.1.5.2.1.9", "gauge", "Capacidade do disco em bytes"),
                ],
            },
            # Ventoinhas: velocidade (EX) e estado (QTS 4.x+, 0=ok -1=fail).
            {
                "indice": "sysFanIndex",
                "walk": "1.3.6.1.4.1.24681.1.3.15.1",
                "lookups": [("sysFanDescr", "1.3.6.1.4.1.24681.1.3.15.1.2")],
                "metricas": [
                    ("qnapFanSpeed", "1.3.6.1.4.1.24681.1.3.15.1.3", "gauge", "Velocidade da ventoinha em RPM"),
                ],
            },
            {
                "indice": "systemFanIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.1.2.2.1",
                "lookups": [],
                "metricas": [
                    ("qnapSystemFanStatus", "1.3.6.1.4.1.24681.1.4.1.1.1.1.2.2.1.4", "gauge", "Estado da ventoinha (0=ok -1=fail)"),
                    ("qnapSystemFanSpeed", "1.3.6.1.4.1.24681.1.4.1.1.1.1.2.2.1.5", "gauge", "Velocidade da ventoinha em RPM"),
                ],
            },
            # Fontes (só em modelo com fonte redundante). 0=ok -1=fail.
            {
                "indice": "systemPowerIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.1.3.2.1",
                "lookups": [],
                "metricas": [
                    ("qnapPowerStatus", "1.3.6.1.4.1.24681.1.4.1.1.1.1.3.2.1.4", "gauge", "Estado da fonte (0=ok -1=fail)"),
                    ("qnapPowerTemperature", "1.3.6.1.4.1.24681.1.4.1.1.1.1.3.2.1.6", "gauge", "Temperatura da fonte em graus Celsius"),
                ],
            },
            # Volumes (ramo EX), em bytes. Estado em texto (Ready, Warning...).
            {
                "indice": "sysVolumeIndex",
                "walk": "1.3.6.1.4.1.24681.1.3.17.1",
                "lookups": [("sysVolumeDescr", "1.3.6.1.4.1.24681.1.3.17.1.2")],
                "metricas": [
                    ("qnapSysVolumeTotalSize", "1.3.6.1.4.1.24681.1.3.17.1.4", "gauge", "Tamanho do volume em bytes"),
                    ("qnapSysVolumeFreeSize", "1.3.6.1.4.1.24681.1.3.17.1.5", "gauge", "Espaço livre do volume em bytes"),
                    ("qnapSysVolumeStatus", "1.3.6.1.4.1.24681.1.3.17.1.6", "DisplayString", "Estado do volume, em texto"),
                ],
            },
            # Volumes (QTS 4.x+), em bytes. Estado em texto.
            {
                "indice": "volumeIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.2.3.2.1",
                "lookups": [("volumeName", "1.3.6.1.4.1.24681.1.4.1.1.1.2.3.2.1.8")],
                "metricas": [
                    ("qnapVolumeCapacity", "1.3.6.1.4.1.24681.1.4.1.1.1.2.3.2.1.3", "gauge", "Tamanho do volume em bytes"),
                    ("qnapVolumeFreeSize", "1.3.6.1.4.1.24681.1.4.1.1.1.2.3.2.1.4", "gauge", "Espaço livre do volume em bytes"),
                    ("qnapVolumeStatus", "1.3.6.1.4.1.24681.1.4.1.1.1.2.3.2.1.5", "DisplayString", "Estado do volume, em texto"),
                ],
            },
            # Pools de armazenamento. 0=ready -1=warning -2=notReady -3=error.
            {
                "indice": "poolIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.2.2.2.1",
                "lookups": [],
                "metricas": [
                    ("qnapPoolCapacity", "1.3.6.1.4.1.24681.1.4.1.1.1.2.2.2.1.3", "gauge", "Tamanho do pool em bytes"),
                    ("qnapPoolFreeSize", "1.3.6.1.4.1.24681.1.4.1.1.1.2.2.2.1.4", "gauge", "Espaço livre do pool em bytes"),
                    ("qnapPoolStatus", "1.3.6.1.4.1.24681.1.4.1.1.1.2.2.2.1.5", "gauge", "Estado do pool (0=ready -1=warning -2=notReady -3=error)"),
                ],
            },
            # Grupos RAID. A MIB declara o estado como texto, mas há firmware
            # que responde número (0=Ready 1=Degraded 2=Rebuilding
            # 3=Synchronizing 4=Failure 5=Offline 6=Migrating). Como texto, o
            # rótulo traz o que vier, palavra ou número.
            {
                "indice": "raidIndex",
                "walk": "1.3.6.1.4.1.24681.1.4.1.1.1.2.1.2.1",
                "lookups": [("raidLevel", "1.3.6.1.4.1.24681.1.4.1.1.1.2.1.2.1.7")],
                "metricas": [
                    ("qnapRaidCapacity", "1.3.6.1.4.1.24681.1.4.1.1.1.2.1.2.1.3", "gauge", "Tamanho do RAID em bytes"),
                    ("qnapRaidFreeSize", "1.3.6.1.4.1.24681.1.4.1.1.1.2.1.2.1.4", "gauge", "Espaço livre do RAID em bytes"),
                    ("qnapRaidStatus", "1.3.6.1.4.1.24681.1.4.1.1.1.2.1.2.1.5", "DisplayString", "Estado do RAID (Ready, Degraded, Rebuilding...)"),
                ],
            },
        ],
    },
    # Synology (DSM), SYNOLOGY-SYSTEM/DISK/RAID-MIB.
    "synology": {
        "titulo": "Synology (DSM)",
        "mib": "SYNOLOGY-SYSTEM-MIB, SYNOLOGY-DISK-MIB, SYNOLOGY-RAID-MIB, HOST-RESOURCES-MIB e UCD-SNMP-MIB",
        "painel": "Nextec | NAS",
        "host_resources": True,
        "escalares": [
            ("synoSystemStatus", "1.3.6.1.4.1.6574.1.1", "gauge", "Estado do sistema (1=normal 2=failed)"),
            ("synoTemperature", "1.3.6.1.4.1.6574.1.2", "gauge", "Temperatura do sistema em graus Celsius"),
            ("synoPowerStatus", "1.3.6.1.4.1.6574.1.3", "gauge", "Estado da fonte (1=normal 2=failed)"),
            ("synoSystemFanStatus", "1.3.6.1.4.1.6574.1.4.1", "gauge", "Estado da ventoinha do sistema (1=normal 2=failed)"),
            ("synoCpuFanStatus", "1.3.6.1.4.1.6574.1.4.2", "gauge", "Estado da ventoinha da CPU (1=normal 2=failed)"),
            ("synoModelName", "1.3.6.1.4.1.6574.1.5.1", "DisplayString", "Modelo do NAS"),
            ("synoVersion", "1.3.6.1.4.1.6574.1.5.3", "DisplayString", "Versão do DSM"),
            ("synoUpgradeAvailable", "1.3.6.1.4.1.6574.1.5.4", "gauge", "Atualização do DSM (1=disponível 2=sem atualização 3=conectando 4=desconectado 5=outro)"),
        ] + UCD,
        "tabelas": [
            # diskStatus: 1=normal 2=initialized 3=notInitialized
            # 4=systemPartitionFailed 5=crashed. diskHealthStatus (DSM 7.1+):
            # 1=normal 2=warning 3=critical 4=failing.
            {
                "indice": "diskIndex",
                "walk": "1.3.6.1.4.1.6574.2.1.1",
                "lookups": [("diskID", "1.3.6.1.4.1.6574.2.1.1.2"),
                            ("diskModel", "1.3.6.1.4.1.6574.2.1.1.3")],
                "metricas": [
                    ("synoDiskStatus", "1.3.6.1.4.1.6574.2.1.1.5", "gauge", "Estado do disco (1=normal 2=initialized 3=notInitialized 4=systemPartitionFailed 5=crashed)"),
                    ("synoDiskTemperature", "1.3.6.1.4.1.6574.2.1.1.6", "gauge", "Temperatura do disco em graus Celsius"),
                    ("synoDiskBadSector", "1.3.6.1.4.1.6574.2.1.1.9", "gauge", "Setores defeituosos do disco"),
                    ("synoDiskRemainLife", "1.3.6.1.4.1.6574.2.1.1.11", "gauge", "Vida restante estimada do disco em porcentagem (SSD)"),
                    ("synoDiskHealthStatus", "1.3.6.1.4.1.6574.2.1.1.13", "gauge", "Saúde do disco (1=normal 2=warning 3=critical 4=failing)"),
                ],
            },
            # raidStatus: 1=normal 11=degrade 12=crashed; 2 a 10 são
            # operações em andamento (repairing, migrating, expanding,
            # deleting, creating, syncing, parityChecking, assembling, canceling).
            {
                "indice": "raidIndex",
                "walk": "1.3.6.1.4.1.6574.3.1.1",
                "lookups": [("raidName", "1.3.6.1.4.1.6574.3.1.1.2")],
                "metricas": [
                    ("synoRaidStatus", "1.3.6.1.4.1.6574.3.1.1.3", "gauge", "Estado do RAID (1=normal 2-10=operação em andamento 11=degrade 12=crashed)"),
                    ("synoRaidFreeSize", "1.3.6.1.4.1.6574.3.1.1.4", "gauge", "Espaço livre do RAID em bytes"),
                    ("synoRaidTotalSize", "1.3.6.1.4.1.6574.3.1.1.5", "gauge", "Tamanho do RAID em bytes"),
                ],
            },
        ],
    },
    # TrueNAS (CORE 12+ e SCALE), TRUENAS-MIB. A ocupação dos pools e
    # datasets vem da HOST-RESOURCES-MIB (hrStorage, um ponto de montagem
    # por dataset). A FREENAS-MIB antiga (FreeNAS 11) usa os mesmos OIDs
    # com outro significado e não é suportada.
    "truenas": {
        "titulo": "TrueNAS (CORE e SCALE)",
        "mib": "TRUENAS-MIB, HOST-RESOURCES-MIB e UCD-SNMP-MIB",
        "painel": "Nextec | NAS",
        "host_resources": True,
        "escalares": [
            ("truenasZfsArcSize", "1.3.6.1.4.1.50536.1.3.1", "gauge", "Tamanho do cache ARC do ZFS em KB"),
        ] + UCD,
        "tabelas": [
            # zpoolHealth em texto: ONLINE, DEGRADED, FAULTED, OFFLINE,
            # UNAVAIL, REMOVED.
            {
                "indice": "zpoolIndex",
                "walk": ["1.3.6.1.4.1.50536.1.1.1.1.2", "1.3.6.1.4.1.50536.1.1.1.1.3"],
                "lookups": [("zpoolName", "1.3.6.1.4.1.50536.1.1.1.1.2")],
                "metricas": [
                    ("truenasZpoolHealth", "1.3.6.1.4.1.50536.1.1.1.1.3", "DisplayString", "Saúde do pool ZFS (ONLINE, DEGRADED, FAULTED...)"),
                ],
            },
            {
                "indice": "hddTempIndex",
                "walk": "1.3.6.1.4.1.50536.3.1",
                "lookups": [("hddTempDevice", "1.3.6.1.4.1.50536.3.1.2")],
                "metricas": [
                    ("truenasHddTemp", "1.3.6.1.4.1.50536.3.1.3", "gauge", "Temperatura do disco em milésimos de grau Celsius"),
                ],
            },
        ],
    },
    # NAS sem MIB própria suportada (Asustor, TerraMaster, WD My Cloud,
    # Buffalo e outros com Linux e net-snmp): equipamento, interfaces,
    # volumes pela HOST-RESOURCES-MIB e CPU e memória pela UCD-SNMP-MIB.
    "nas": {
        "titulo": "NAS genérico (Asustor, TerraMaster, WD, Buffalo e outros)",
        "mib": "HOST-RESOURCES-MIB e UCD-SNMP-MIB",
        "painel": "Nextec | NAS",
        "host_resources": True,
        "escalares": UCD,
        "tabelas": [],
    },
    # Dell PowerEdge pelo iDRAC (7, 8, 9 e 10), IDRAC-MIB-SMIv2. Estado
    # (ObjectStatusEnum): 1=other 2=unknown 3=ok 4=nonCritical 5=critical
    # 6=nonRecoverable. Estado de sensor (StatusProbeEnum): 3=ok, 4 a 9
    # são limites ultrapassados (4/7 aviso, 5/8 crítico, 6/9 irrecuperável)
    # e 10=failed. Habilitar no iDRAC: iDRAC Settings > Services > SNMP Agent.
    "dell": {
        "titulo": "Dell PowerEdge (iDRAC)",
        "mib": "IDRAC-MIB-SMIv2",
        "painel": "Nextec | Hardware",
        "host_resources": False,
        "escalares": [
            ("idracGlobalSystemStatus", "1.3.6.1.4.1.674.10892.5.2.1", "gauge", "Estado geral do servidor (3=ok 4=nonCritical 5=critical 6=nonRecoverable)"),
            ("idracSystemLCDStatus", "1.3.6.1.4.1.674.10892.5.2.2", "gauge", "Estado mostrado no painel frontal (3=ok 4=nonCritical 5=critical 6=nonRecoverable)"),
            ("idracGlobalStorageStatus", "1.3.6.1.4.1.674.10892.5.2.3", "gauge", "Estado geral do armazenamento (3=ok 4=nonCritical 5=critical 6=nonRecoverable)"),
            ("idracSystemPowerState", "1.3.6.1.4.1.674.10892.5.2.4", "gauge", "Energia do servidor (3=off 4=on)"),
            ("idracFirmwareVersion", "1.3.6.1.4.1.674.10892.5.1.1.8", "DisplayString", "Versão do firmware do iDRAC"),
            ("idracSystemServiceTag", "1.3.6.1.4.1.674.10892.5.1.3.2", "DisplayString", "Service tag do servidor"),
            ("idracSystemModelName", "1.3.6.1.4.1.674.10892.5.1.3.12", "DisplayString", "Modelo do servidor"),
        ],
        "tabelas": [
            # Estado consolidado por componente, um por chassi.
            {
                "indice": "systemStatechassisIndex",
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.200.10.1.{c}" for c in (9, 12, 15, 21, 24, 27, 30, 50, 52)],
                "lookups": [],
                "metricas": [
                    ("idracPowerSupplyStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.9", "gauge", "Estado consolidado das fontes (3=ok 4=nonCritical 5=critical)"),
                    ("idracVoltageStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.12", "gauge", "Estado consolidado das tensões (3=ok 4=nonCritical 5=critical)"),
                    ("idracAmperageStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.15", "gauge", "Estado consolidado das correntes (3=ok 4=nonCritical 5=critical)"),
                    ("idracCoolingDeviceStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.21", "gauge", "Estado consolidado das ventoinhas (3=ok 4=nonCritical 5=critical)"),
                    ("idracTemperatureStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.24", "gauge", "Estado consolidado das temperaturas (3=ok 4=nonCritical 5=critical)"),
                    ("idracMemoryDeviceStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.27", "gauge", "Estado consolidado da memória (3=ok 4=nonCritical 5=critical)"),
                    ("idracChassisIntrusionStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.30", "gauge", "Estado do sensor de abertura do gabinete (3=ok 4=nonCritical 5=critical)"),
                    ("idracProcessorDeviceStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.50", "gauge", "Estado consolidado dos processadores (3=ok 4=nonCritical 5=critical)"),
                    ("idracBatteryStatusCombined", "1.3.6.1.4.1.674.10892.5.4.200.10.1.52", "gauge", "Estado consolidado das baterias (3=ok 4=nonCritical 5=critical)"),
                ],
            },
            # Temperatura em décimos de grau Celsius.
            {
                "indice": ["temperatureProbechassisIndex", "temperatureProbeIndex"],
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.700.20.1.{c}" for c in (5, 6, 8)],
                "lookups": [("temperatureProbeLocationName", "1.3.6.1.4.1.674.10892.5.4.700.20.1.8")],
                "metricas": [
                    ("idracTemperatureProbeStatus", "1.3.6.1.4.1.674.10892.5.4.700.20.1.5", "gauge", "Estado do sensor de temperatura (3=ok 4-9=limite ultrapassado 10=failed)"),
                    ("idracTemperatureProbeReading", "1.3.6.1.4.1.674.10892.5.4.700.20.1.6", "gauge", "Temperatura em décimos de grau Celsius"),
                ],
            },
            {
                "indice": ["coolingDevicechassisIndex", "coolingDeviceIndex"],
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.700.12.1.{c}" for c in (5, 6, 8)],
                "lookups": [("coolingDeviceLocationName", "1.3.6.1.4.1.674.10892.5.4.700.12.1.8")],
                "metricas": [
                    ("idracCoolingDeviceStatus", "1.3.6.1.4.1.674.10892.5.4.700.12.1.5", "gauge", "Estado da ventoinha (3=ok 4-9=limite ultrapassado 10=failed)"),
                    ("idracCoolingDeviceReading", "1.3.6.1.4.1.674.10892.5.4.700.12.1.6", "gauge", "Velocidade da ventoinha em RPM"),
                ],
            },
            {
                "indice": ["powerSupplychassisIndex", "powerSupplyIndex"],
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.600.12.1.{c}" for c in (5, 6, 8)],
                "lookups": [("powerSupplyLocationName", "1.3.6.1.4.1.674.10892.5.4.600.12.1.8")],
                "metricas": [
                    ("idracPowerSupplyStatus", "1.3.6.1.4.1.674.10892.5.4.600.12.1.5", "gauge", "Estado da fonte (3=ok 4=nonCritical 5=critical 6=nonRecoverable)"),
                    ("idracPowerSupplyOutputWatts", "1.3.6.1.4.1.674.10892.5.4.600.12.1.6", "gauge", "Potência máxima da fonte em décimos de watt"),
                ],
            },
            # Consumo: a linha com amperageProbeType 26 é o consumo do
            # sistema em watts; as de tipo 23 são correntes em décimos de ampère.
            {
                "indice": ["amperageProbechassisIndex", "amperageProbeIndex"],
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.600.30.1.{c}" for c in (5, 6, 7, 8)],
                "lookups": [("amperageProbeLocationName", "1.3.6.1.4.1.674.10892.5.4.600.30.1.8")],
                "metricas": [
                    ("idracAmperageProbeStatus", "1.3.6.1.4.1.674.10892.5.4.600.30.1.5", "gauge", "Estado do sensor de corrente ou consumo (3=ok)"),
                    ("idracAmperageProbeReading", "1.3.6.1.4.1.674.10892.5.4.600.30.1.6", "gauge", "Leitura em watts no tipo 26 e em décimos de ampère no tipo 23"),
                    ("idracAmperageProbeType", "1.3.6.1.4.1.674.10892.5.4.600.30.1.7", "gauge", "Tipo do sensor (23=corrente da fonte 24=watts da fonte 26=consumo do sistema)"),
                ],
            },
            {
                "indice": ["memoryDevicechassisIndex", "memoryDeviceIndex"],
                "walk": [f"1.3.6.1.4.1.674.10892.5.4.1100.50.1.{c}" for c in (5, 8)],
                "lookups": [("memoryDeviceLocationName", "1.3.6.1.4.1.674.10892.5.4.1100.50.1.8")],
                "metricas": [
                    ("idracMemoryDeviceStatus", "1.3.6.1.4.1.674.10892.5.4.1100.50.1.5", "gauge", "Estado do pente de memória (3=ok 4=nonCritical 5=critical)"),
                ],
            },
            # Controladora RAID, discos físicos, discos virtuais e bateria
            # da controladora. physicalDiskState: 1=unknown 2=ready 3=online
            # 4=foreign 5=offline 6=blocked 7=failed 8=nonraid 9=removed
            # 10=readonly. virtualDiskState: 1=unknown 2=online 3=failed 4=degraded.
            {
                "indice": "controllerNumber",
                "walk": ["1.3.6.1.4.1.674.10892.5.5.1.20.130.1.1.38", "1.3.6.1.4.1.674.10892.5.5.1.20.130.1.1.79"],
                "lookups": [("controllerDisplayName", "1.3.6.1.4.1.674.10892.5.5.1.20.130.1.1.79")],
                "metricas": [
                    ("idracControllerComponentStatus", "1.3.6.1.4.1.674.10892.5.5.1.20.130.1.1.38", "gauge", "Estado da controladora (3=ok 4=nonCritical 5=critical)"),
                ],
            },
            {
                "indice": "physicalDiskNumber",
                "walk": [f"1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.{c}" for c in (4, 11, 24, 31, 55)],
                "lookups": [("physicalDiskDisplayName", "1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.55")],
                "metricas": [
                    ("idracPhysicalDiskState", "1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.4", "gauge", "Estado do disco físico (3=online 7=failed 5=offline 9=removed)"),
                    ("idracPhysicalDiskCapacityInMB", "1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.11", "gauge", "Capacidade do disco físico em MB"),
                    ("idracPhysicalDiskComponentStatus", "1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.24", "gauge", "Estado do disco físico (3=ok 4=nonCritical 5=critical)"),
                    ("idracPhysicalDiskSmartAlert", "1.3.6.1.4.1.674.10892.5.5.1.20.130.4.1.31", "gauge", "Falha prevista pelo SMART (0=não 1=sim)"),
                ],
            },
            {
                "indice": "virtualDiskNumber",
                "walk": [f"1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.{c}" for c in (4, 20, 36)],
                "lookups": [("virtualDiskDisplayName", "1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.36")],
                "metricas": [
                    ("idracVirtualDiskState", "1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.4", "gauge", "Estado do disco virtual (2=online 3=failed 4=degraded)"),
                    ("idracVirtualDiskComponentStatus", "1.3.6.1.4.1.674.10892.5.5.1.20.140.1.1.20", "gauge", "Estado do disco virtual (3=ok 4=nonCritical 5=critical)"),
                ],
            },
            {
                "indice": "batteryNumber",
                "walk": ["1.3.6.1.4.1.674.10892.5.5.1.20.130.15.1.6", "1.3.6.1.4.1.674.10892.5.5.1.20.130.15.1.21"],
                "lookups": [("batteryDisplayName", "1.3.6.1.4.1.674.10892.5.5.1.20.130.15.1.21")],
                "metricas": [
                    ("idracBatteryComponentStatus", "1.3.6.1.4.1.674.10892.5.5.1.20.130.15.1.6", "gauge", "Estado da bateria da controladora (3=ok 4=nonCritical 5=critical)"),
                ],
            },
        ],
    },
}


def bloco_metrica(linhas, nome, oid, tipo, ajuda, indices=None, lookups=None):
    # O help sai sem aspas no YAML: ": " ou "#" no texto quebram o arquivo.
    assert ": " not in ajuda and " #" not in ajuda, f"help de {nome} não pode ter ': ' nem ' #'"
    linhas.append(f"    - name: {nome}")
    linhas.append(f"      oid: {oid}")
    linhas.append(f"      type: {tipo}")
    linhas.append(f"      help: {ajuda}")
    if indices:
        linhas.append("      indexes:")
        for rotulo in indices:
            linhas.append(f"      - labelname: {rotulo}")
            linhas.append("        type: gauge")
    if lookups:
        linhas.append("      lookups:")
        for rotulo, oid_lookup in lookups:
            linhas.append("      - labels:")
            linhas += [f"        - {indice}" for indice in indices]
            linhas.append(f"        labelname: {rotulo}")
            linhas.append(f"        oid: {oid_lookup}")
            linhas.append("        type: DisplayString")


def modulo(nome_modulo, fab):
    walks = ["1.3.6.1.2.1.1", "1.3.6.1.2.1.2.2", "1.3.6.1.2.1.31.1.1"]
    if fab["host_resources"]:
        walks += ["1.3.6.1.2.1.25.2.3", "1.3.6.1.2.1.25.3.3"]
    for tabela in fab["tabelas"]:
        walk = tabela["walk"]
        walks += walk if isinstance(walk, list) else [walk]

    linhas = [f"  {nome_modulo}:", "    walk:"]
    linhas += [f"    - {w}" for w in walks]
    # Escalares fora das árvores percorridas vão no "get": o snmp_exporter só
    # publica o que leu, e um escalar que não está em walk nem em get some.
    if fab["escalares"]:
        linhas.append("    get:")
        linhas += [f"    - {oid}.0" for _, oid, _, _ in fab["escalares"]]
    linhas.append("    metrics:")

    for nome, oid, tipo, ajuda in SISTEMA:
        bloco_metrica(linhas, nome, oid, tipo, ajuda)
    for nome, oid, tipo, ajuda in fab["escalares"]:
        bloco_metrica(linhas, nome, oid, tipo, ajuda)
    for nome, oid, tipo, ajuda in INTERFACE:
        bloco_metrica(linhas, nome, oid, tipo, ajuda, ["ifIndex"], LOOKUPS_INTERFACE)
    if fab["host_resources"]:
        for nome, oid, tipo, ajuda in HOST_RESOURCES:
            if nome.startswith("hrStorage") and nome != "hrStorageDescr":
                bloco_metrica(linhas, nome, oid, tipo, ajuda, ["hrStorageIndex"],
                              [("hrStorageDescr", "1.3.6.1.2.1.25.2.3.1.3")])
            elif nome == "hrProcessorLoad":
                bloco_metrica(linhas, nome, oid, tipo, ajuda, ["hrDeviceIndex"])
    for tabela in fab["tabelas"]:
        for nome, oid, tipo, ajuda in tabela["metricas"]:
            indices = tabela["indice"] if isinstance(tabela["indice"], list) else [tabela["indice"]]
            bloco_metrica(linhas, nome, oid, tipo, ajuda, indices, tabela["lookups"])
    return linhas


def gerar(chave, fab):
    linhas = [
        "# " + "=" * 76,
        f"# Nextec, módulo SNMP para {fab['titulo']}",
        "# Gerado por gerar_modulos.py. Não edite à mão: altere o gerador e rode de novo.",
        "#",
        f"# Fontes: SNMPv2-MIB, IF-MIB, IF-X-MIB e {fab['mib']}.",
        f"# Os nomes das métricas são os usados pelo painel {fab.get('painel', 'Nextec | Firewall')}.",
        "#",
        "# Segurança: este arquivo NÃO contém community, usuário ou senha. As",
        "# credenciais ficam no snmp-auth.yml de cada cliente, gravado pelo instalador.",
        "# " + "=" * 76,
        "modules:",
    ]
    for versao in ("v2c", "v3"):
        linhas += modulo(f"{chave}_{versao}", fab)
    destino = PASTA / f"{chave}.yml"
    destino.write_text("\n".join(linhas) + "\n", encoding="utf-8")
    print(f"{destino.name}: {len(linhas)} linhas")


if __name__ == "__main__":
    for chave_fab, dados in FABRICANTES.items():
        gerar(chave_fab, dados)
