#!/usr/bin/env python3
"""Gera os snmp.yml homologados da Nextec para FortiGate, MikroTik e SonicWall.

Cada fabricante sai com duas variantes do mesmo módulo, `<fabricante>_v2c` e
`<fabricante>_v3`. O conteúdo é igual; o sufixo só existe para o instalador
escolher a variante pela versão SNMP da credencial.

O pfsense.yml não sai daqui: ele é gerado pelo generator oficial do
snmp_exporter, a partir das MIBs do pfSense.

Os nomes das métricas são os que os painéis do NOC consultam (Nextec |
Firewall). Trocar um nome aqui sem trocar no painel apaga o gráfico.

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
}


def bloco_metrica(linhas, nome, oid, tipo, ajuda, indices=None, lookups=None):
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
            linhas.append(f"        - {indices[0]}")
            linhas.append(f"        labelname: {rotulo}")
            linhas.append(f"        oid: {oid_lookup}")
            linhas.append("        type: DisplayString")


def modulo(nome_modulo, fab):
    walks = ["1.3.6.1.2.1.1", "1.3.6.1.2.1.2.2", "1.3.6.1.2.1.31.1.1"]
    if fab["host_resources"]:
        walks += ["1.3.6.1.2.1.25.2.3", "1.3.6.1.2.1.25.3.3"]
    walks += [tabela["walk"] for tabela in fab["tabelas"]]

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
            bloco_metrica(linhas, nome, oid, tipo, ajuda, [tabela["indice"]], tabela["lookups"])
    return linhas


def gerar(chave, fab):
    linhas = [
        "# " + "=" * 76,
        f"# Nextec, módulo SNMP para {fab['titulo']}",
        "# Gerado por gerar_modulos.py. Não edite à mão: altere o gerador e rode de novo.",
        "#",
        f"# Fontes: SNMPv2-MIB, IF-MIB, IF-X-MIB e {fab['mib']}.",
        "# Os nomes das métricas são os usados pelo painel Nextec | Firewall.",
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
