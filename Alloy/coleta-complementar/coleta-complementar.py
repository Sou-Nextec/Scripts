#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Coleta Complementar Nextec (Linux)

Completa o que o Grafana Alloy não coleta sozinho. Não envia nada para a
central: grava métricas em arquivos .prom (lidos pelo coletor textfile do
Alloy) e eventos em JSON por linha (lidos pelo loki.source.file do Alloy).

Módulos:
  internet    saída padrão, DNS, IP público e diagnóstico (ligado por padrão)
  links       cada link de internet do local: status, qualidade, link em
              uso (failover), gateway da operadora e causa das quedas
  docker      estado, health, saída, consumo, configuração e eventos dos
              containers (os logs dos containers ficam com o Alloy)
  velocidade  teste de velocidade (Ookla Speedtest CLI)
  acessos     logins no servidor (SSH e console), sudo e su, com IP de
              origem; marca acesso privilegiado, origem nova e fora do
              horário para os alertas de acesso privilegiado
  bancos      bancos sem exportador próprio (Firebird, Oracle, SQL Anywhere,
              SQL Server e arquivos SQLite): no ar, conexões, memória,
              tempo ligado e tamanho das bases, no padrão nextec_banco_*
  virtualizacao  hipervisores (Proxmox VE e KVM/libvirt no próprio
              servidor; VMware, Proxmox e XCP-ng pela rede): hosts, VMs,
              armazenamento, snapshots e cluster, no padrão
              nextec_hipervisor_* e nextec_vm_*

Uso:
  coleta-complementar.py executar            roda os módulos ligados (serviço)
  coleta-complementar.py uma-vez [módulo]    uma rodada, para teste
  coleta-complementar.py verificar           confere configuração e dependências
  coleta-complementar.py versao

Configuração: /etc/coleta-complementar/coleta-complementar.ini
(caminho alternativo na variável COLETA_COMPLEMENTAR_CONFIG)
"""

import configparser
import glob
import grp
import http.client
import ipaddress
import json
import os
import pwd
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import xmlrpc.client
from xml.sax.saxutils import escape as xml_escape
from datetime import datetime, timedelta, timezone

VERSAO = "1.5.0"

CONFIG_PADRAO = "/etc/coleta-complementar/coleta-complementar.ini"
DIR_DADOS_PADRAO = "/var/lib/coleta-complementar"
ARQ_EVENTOS_PADRAO = "/var/log/coleta-complementar/eventos.jsonl"
TAMANHO_MAX_EVENTOS = 10 * 1024 * 1024

URLS_IP_PUBLICO = [
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com",
]

CAUSA_FIREWALL = "rede local: firewall sem resposta"
CAUSA_GATEWAY = "operadora: gateway sem resposta"
CAUSA_SEM_SAIDA = "operadora: gateway responde, sem saída para a internet"
CAUSA_GERAL = "todos os links sem saída com gateways respondendo: instabilidade geral ou firewall"
CAUSA_SEM_GATEWAY = "sem saída para a internet (gateway da operadora não configurado)"

FORA, OK, DEGRADADO = 0, 1, 2


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def agora():
    return time.time()


def log(nivel, mensagem, **campos):
    """Log estruturado em uma linha, para o journald. Nunca registra segredo."""
    extras = " ".join(f'{k}="{v}"' for k, v in campos.items())
    print(f"nivel={nivel} msg=\"{mensagem}\" {extras}".rstrip(), file=sys.stderr, flush=True)


def escapar_rotulo(valor):
    return str(valor).replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def lista(texto):
    return [p.strip() for p in str(texto or "").split(",") if p.strip()]


def sim(texto, padrao=False):
    if texto is None or str(texto).strip() == "":
        return padrao
    return str(texto).strip().lower() in ("sim", "s", "yes", "true", "1", "ligado")


class Metricas:
    """Acumula métricas no formato texto do Prometheus."""

    def __init__(self):
        self._tipos = {}
        self._linhas = {}

    def add(self, nome, valor, rotulos=None, tipo="gauge", ajuda=""):
        if valor is None:
            return
        if nome not in self._tipos:
            self._tipos[nome] = (tipo, ajuda)
            self._linhas[nome] = []
        texto_rotulos = ""
        if rotulos:
            pares = ",".join(f'{k}="{escapar_rotulo(v)}"' for k, v in rotulos.items())
            texto_rotulos = "{" + pares + "}"
        if isinstance(valor, float):
            valor = f"{valor:.6f}".rstrip("0").rstrip(".") if valor == valor else "NaN"
        self._linhas[nome].append(f"{nome}{texto_rotulos} {valor}")

    def texto(self):
        partes = []
        for nome, (tipo, ajuda) in self._tipos.items():
            if ajuda:
                partes.append(f"# HELP {nome} {ajuda}")
            partes.append(f"# TYPE {nome} {tipo}")
            partes.extend(self._linhas[nome])
        return "\n".join(partes) + "\n"


def gravar_atomico(caminho, conteudo):
    """Escreve em arquivo temporário e troca, para o Alloy nunca ler pela metade."""
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    temporario = f"{caminho}.tmp"
    with open(temporario, "w", encoding="utf-8") as arquivo:
        arquivo.write(conteudo)
    os.replace(temporario, caminho)


class Eventos:
    """Grava eventos em JSON por linha, com rotação simples por tamanho."""

    def __init__(self, caminho):
        self.caminho = caminho
        self._trava = threading.Lock()
        os.makedirs(os.path.dirname(caminho), exist_ok=True)

    def registrar(self, tipo, categoria, evento, nivel="info", **campos):
        registro = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "tipo": tipo,
            "categoria": categoria,
            "evento": evento,
            "nivel": nivel,
        }
        registro.update({k: v for k, v in campos.items() if v is not None and v != ""})
        linha = json.dumps(registro, ensure_ascii=False)
        with self._trava:
            try:
                if os.path.exists(self.caminho) and os.path.getsize(self.caminho) > TAMANHO_MAX_EVENTOS:
                    os.replace(self.caminho, self.caminho + ".1")
                with open(self.caminho, "a", encoding="utf-8") as arquivo:
                    arquivo.write(linha + "\n")
            except OSError as erro:
                log("erro", "falha ao gravar evento", erro=erro)


class Estado:
    """Estado persistente (contadores e transições), sobrevive a reinício."""

    def __init__(self, caminho):
        self.caminho = caminho
        self._trava = threading.Lock()
        self.dados = {}
        try:
            with open(caminho, encoding="utf-8") as arquivo:
                self.dados = json.load(arquivo)
        except FileNotFoundError:
            self.dados = {}
        except (OSError, ValueError) as erro:
            log("aviso", "estado ilegível, recomeçando do zero", erro=erro)
            self.dados = {}

    def secao(self, nome):
        with self._trava:
            return self.dados.setdefault(nome, {})

    def salvar(self):
        with self._trava:
            gravar_atomico(self.caminho, json.dumps(self.dados, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Rede: ping, rota, DNS e IP público
# ---------------------------------------------------------------------------

RE_PERDA = re.compile(r"(\d+(?:\.\d+)?)% packet loss")
RE_RTT = re.compile(r"= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms")


class ResultadoPing:
    def __init__(self, alvo, perda=100.0, latencia=None, jitter=None):
        self.alvo = alvo
        self.perda = perda
        self.latencia = latencia
        self.jitter = jitter

    @property
    def respondeu(self):
        return self.perda < 100.0


def pingar(alvo, quantidade=5, origem=None, timeout=1):
    comando = ["ping", "-n", "-q", "-c", str(quantidade), "-i", "0.2", "-W", str(timeout)]
    if origem:
        comando += ["-I", origem]
    comando.append(alvo)
    try:
        saida = subprocess.run(
            comando, capture_output=True, text=True,
            timeout=quantidade * (timeout + 1) + 5,
        ).stdout
    except (subprocess.TimeoutExpired, OSError) as erro:
        log("aviso", "ping falhou", alvo=alvo, erro=erro)
        return ResultadoPing(alvo)
    perda = RE_PERDA.search(saida)
    rtt = RE_RTT.search(saida)
    resultado = ResultadoPing(alvo, perda=float(perda.group(1)) if perda else 100.0)
    if rtt:
        resultado.latencia = float(rtt.group(2))
        resultado.jitter = float(rtt.group(4))
    return resultado


def pingar_varios(alvos, origem=None, quantidade=5):
    resultados = {}
    threads = []

    def executar(alvo):
        resultados[alvo] = pingar(alvo, quantidade=quantidade, origem=origem)

    for alvo in alvos:
        thread = threading.Thread(target=executar, args=(alvo,), daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    return [resultados[a] for a in alvos]


def rota_ate(alvo, origem=None):
    """Registra a rota no momento da queda. Usa tracepath ou traceroute."""
    if shutil.which("traceroute"):
        comando = ["traceroute", "-n", "-q", "1", "-w", "1", "-m", "15"]
        if origem:
            comando += ["-s", origem]
        comando.append(alvo)
    elif shutil.which("tracepath"):
        comando = ["tracepath", "-n", "-m", "15", alvo]
    else:
        return None, "rota não registrada: instale traceroute"
    try:
        saida = subprocess.run(comando, capture_output=True, text=True, timeout=40).stdout
    except (subprocess.TimeoutExpired, OSError) as erro:
        return None, f"rota não registrada: {erro}"
    saltos = []
    for linha in saida.splitlines():
        campos = linha.split()
        if len(campos) >= 2 and campos[0].rstrip(":").isdigit():
            ip = campos[1]
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) and ip not in saltos:
                saltos.append(ip)
    ultimo = saltos[-1] if saltos else None
    return ultimo, " > ".join(saltos) if saltos else "nenhum salto respondeu"


def gateway_padrao():
    try:
        with open("/proc/net/route", encoding="ascii") as arquivo:
            for linha in arquivo.readlines()[1:]:
                campos = linha.split()
                if campos[1] == "00000000" and int(campos[3], 16) & 2:
                    return socket.inet_ntoa(struct.pack("<L", int(campos[2], 16)))
    except (OSError, ValueError, IndexError):
        return None
    return None


def consultar_dns(servidor, nome, timeout=2.0):
    """Consulta A mínima em UDP. Retorna (sucesso, tempo_ms)."""
    inicio = time.perf_counter()
    if servidor == "sistema":
        try:
            socket.getaddrinfo(nome, None, socket.AF_INET)
            return True, (time.perf_counter() - inicio) * 1000
        except socket.gaierror:
            return False, None
    identificador = random.randint(0, 65535)
    cabecalho = struct.pack(">HHHHHH", identificador, 0x0100, 1, 0, 0, 0)
    pergunta = b"".join(bytes([len(p)]) + p.encode("ascii") for p in nome.split(".")) + b"\x00"
    pacote = cabecalho + pergunta + struct.pack(">HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as conexao:
            conexao.settimeout(timeout)
            conexao.sendto(pacote, (servidor, 53))
            resposta, _ = conexao.recvfrom(2048)
    except OSError:
        return False, None
    if len(resposta) < 12:
        return False, None
    rid, flags, _, respostas = struct.unpack(">HHHH", resposta[:8])
    sucesso = rid == identificador and (flags & 0x000F) == 0 and respostas > 0
    return sucesso, (time.perf_counter() - inicio) * 1000 if sucesso else None


def ip_publico(urls, timeout=5):
    for url in urls:
        try:
            requisicao = urllib.request.Request(url, headers={"User-Agent": "coleta-complementar"})
            with urllib.request.urlopen(requisicao, timeout=timeout) as resposta:
                texto = resposta.read(64).decode("ascii", "ignore").strip()
            if re.match(r"^[0-9a-fA-F:.]{3,45}$", texto):
                return texto
        except (OSError, ValueError):
            continue
    return None


# ---------------------------------------------------------------------------
# Módulo internet e links
# ---------------------------------------------------------------------------

class Link:
    def __init__(self, nome, secao):
        self.nome = nome
        self.papel = secao.get("papel", "primario")
        self.operadora = secao.get("operadora", "")
        self.tipo = secao.get("tipo", "")
        self.suporte = secao.get("suporte", "")
        self.ip_publico = secao.get("ip_publico", "")
        self.gateway = secao.get("gateway", "")
        self.alvos = lista(secao.get("alvos", ""))
        self.origem = secao.get("origem", "")
        self.firewall = secao.get("firewall", "")
        self.interface_firewall = secao.get("interface_firewall", "")
        self.teste_velocidade = secao.get("teste_velocidade", "nao")
        # Velocidade contratada em Mbps, padronizada pelo instalador.
        self.velocidade_mbps = _mbps(secao.get("velocidade_mbps", ""))
        self.velocidade_upload_mbps = _mbps(secao.get("velocidade_upload_mbps", ""))


def _mbps(texto):
    texto = (texto or "").strip()
    return int(texto) if texto.isdigit() and 0 < int(texto) <= 100000 else None


class ModuloLinks:
    nome = "internet"

    def __init__(self, config, eventos, estado, dir_textfile):
        geral = config["geral"] if config.has_section("geral") else {}
        internet = config["internet"] if config.has_section("internet") else {}
        self.intervalo = max(10, int(geral.get("intervalo_links_segundos", "15")))
        self.limite_latencia = float(geral.get("limite_latencia_ms", "150"))
        self.limite_perda = float(geral.get("limite_perda_percentual", "5"))
        self.alvos_internet = lista(internet.get("alvos", "1.1.1.1, 8.8.8.8"))
        self.firewall_local = internet.get("firewall", "") or gateway_padrao() or ""
        self.dns_servidores = lista(internet.get("dns_servidores", "sistema, 1.1.1.1, 8.8.8.8"))
        self.dns_nome = internet.get("dns_nome", "google.com")
        self.urls_ip = lista(internet.get("ip_publico_urls", "")) or URLS_IP_PUBLICO
        self.intervalo_ip = max(60, int(internet.get("ip_publico_intervalo_segundos", "300")))
        self.links = [
            Link(s.split(":", 1)[1].strip(), config[s])
            for s in config.sections() if s.lower().startswith("link:")
        ]
        self.eventos = eventos
        self.estado = estado
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_links.prom")
        self._ultimo_ip = 0.0
        self._ip_atual = None

    # Classificação ----------------------------------------------------------

    def classificar(self, resultados):
        respondendo = [r for r in resultados if r.respondeu]
        if not respondendo:
            return FORA, 100.0, None, None
        # Perda do link é a do melhor destino: um destino externo instável
        # não torna o link ruim (vira evento de instabilidade externa).
        perda = min(r.perda for r in resultados)
        latencia = sum(r.latencia for r in respondendo) / len(respondendo)
        jitter = sum(r.jitter for r in respondendo) / len(respondendo)
        if perda > self.limite_perda or latencia > self.limite_latencia:
            return DEGRADADO, perda, latencia, jitter
        return OK, perda, latencia, jitter

    def motivo_degradado(self, perda, latencia):
        motivos = []
        if perda is not None and perda > self.limite_perda:
            motivos.append("perda alta")
        if latencia is not None and latencia > self.limite_latencia:
            motivos.append("latência alta")
        return "degradado: " + " e ".join(motivos) if motivos else "degradado"

    # Contadores e transições ----------------------------------------------

    def contabilizar(self, chave, status):
        memoria = self.estado.secao("links").setdefault(chave, {
            "rodadas": 0, "fora": 0, "degradado": 0, "segundos_fora": 0.0,
            "status": None, "desde": agora(), "queda_id": None, "inicio_queda": None,
        })
        memoria["rodadas"] += 1
        if status == FORA:
            memoria["fora"] += 1
            memoria["segundos_fora"] += self.intervalo
        elif status == DEGRADADO:
            memoria["degradado"] += 1
        anterior = memoria["status"]
        if anterior != status:
            memoria["desde"] = agora()
        memoria["status"] = status
        return memoria, anterior

    def tratar_transicao(self, memoria, anterior, status, rotulo_link, causa, alvo_rota, origem=None):
        """Gera eventos de queda, volta, degradação e normalização."""
        prefixo = "link" if rotulo_link else "internet"
        if anterior is None:
            return
        if status == FORA and anterior != FORA:
            momento = agora()
            memoria["queda_id"] = f"{rotulo_link or 'internet'}-{int(momento)}"
            memoria["inicio_queda"] = momento
            self.eventos.registrar(
                "links_evento", "queda", f"{prefixo}_caiu", "critico",
                link=rotulo_link, causa=causa, queda_id=memoria["queda_id"],
            )
            if alvo_rota:
                ultimo, rota = rota_ate(alvo_rota, origem=origem)
                self.eventos.registrar(
                    "links_evento", "queda", "rota_na_queda", "aviso",
                    link=rotulo_link, queda_id=memoria["queda_id"],
                    ultimo_salto=ultimo, rota=rota, alvo=alvo_rota,
                )
        elif anterior == FORA and status != FORA:
            duracao = round(agora() - (memoria.get("inicio_queda") or agora()))
            self.eventos.registrar(
                "links_evento", "queda", f"{prefixo}_voltou", "info",
                link=rotulo_link, queda_id=memoria.get("queda_id"), duracao_s=duracao,
            )
            memoria["queda_id"] = None
            memoria["inicio_queda"] = None
        if status == DEGRADADO and anterior == OK:
            self.eventos.registrar("links_evento", "qualidade", f"{prefixo}_degradado", "aviso", link=rotulo_link)
        elif status == OK and anterior == DEGRADADO:
            self.eventos.registrar("links_evento", "qualidade", f"{prefixo}_normalizado", "info", link=rotulo_link)

    def tratar_destinos(self, grupo, resultados, rotulo_link):
        """Destino que para de responder enquanto os outros respondem: instabilidade externa."""
        memoria = self.estado.secao("destinos").setdefault(grupo, {})
        algum_ok = any(r.respondeu for r in resultados)
        for resultado in resultados:
            caiu = algum_ok and not resultado.respondeu
            antes = memoria.get(resultado.alvo, False)
            if caiu and not antes:
                self.eventos.registrar(
                    "links_evento", "instabilidade_externa", "destino_sem_resposta", "aviso",
                    link=rotulo_link, alvo=resultado.alvo,
                )
            elif antes and resultado.respondeu:
                self.eventos.registrar(
                    "links_evento", "instabilidade_externa", "destino_voltou", "info",
                    link=rotulo_link, alvo=resultado.alvo,
                )
            memoria[resultado.alvo] = caiu

    # Rodada -----------------------------------------------------------------

    def rodada(self):
        metricas = Metricas()
        momento = agora()

        firewall_ok = None
        if self.firewall_local:
            firewall_ok = pingar(self.firewall_local, quantidade=2).respondeu

        # Internet pela saída padrão
        resultados_internet = pingar_varios(self.alvos_internet)
        status_internet, perda, latencia, jitter = self.classificar(resultados_internet)
        if status_internet == FORA:
            causa_internet = CAUSA_FIREWALL if firewall_ok is False else "sem saída para a internet"
            diagnostico_internet = f"fora: {causa_internet}"
        elif status_internet == DEGRADADO:
            causa_internet = None
            diagnostico_internet = self.motivo_degradado(perda, latencia)
        else:
            causa_internet = None
            diagnostico_internet = "normal"
        memoria, anterior = self.contabilizar("__internet__", status_internet)
        self.tratar_transicao(memoria, anterior, status_internet, None, causa_internet,
                              self.alvos_internet[0] if self.alvos_internet else None)
        self.tratar_destinos("__internet__", resultados_internet, None)

        metricas.add("nextec_internet_status", status_internet, ajuda="0 fora, 1 normal, 2 degradada (saída padrão)")
        metricas.add("nextec_internet_latencia_ms", latencia)
        metricas.add("nextec_internet_perda_percentual", perda)
        metricas.add("nextec_internet_jitter_ms", jitter)
        metricas.add("nextec_internet_diagnostico", 1, {"diagnostico": diagnostico_internet})
        metricas.add("nextec_internet_estado_desde_segundos", round(memoria["desde"]))
        metricas.add("nextec_internet_rodadas_total", memoria["rodadas"], tipo="counter")
        metricas.add("nextec_internet_rodadas_fora_total", memoria["fora"], tipo="counter")
        metricas.add("nextec_internet_rodadas_degradado_total", memoria["degradado"], tipo="counter")
        metricas.add("nextec_internet_segundos_fora_total", memoria["segundos_fora"], tipo="counter")
        for resultado in resultados_internet:
            metricas.add("nextec_internet_alvo_latencia_ms", resultado.latencia, {"alvo": resultado.alvo})
            metricas.add("nextec_internet_alvo_perda_percentual", resultado.perda, {"alvo": resultado.alvo})
        if firewall_ok is not None:
            metricas.add("nextec_internet_firewall_status", 1 if firewall_ok else 0,
                         {"firewall": self.firewall_local})

        # Cada link: primeiro mede todos, depois decide a causa (a causa geral
        # depende de todos os links estarem fora ao mesmo tempo)
        medicoes = []
        for link in self.links:
            resultados = pingar_varios(link.alvos, origem=link.origem or None) if link.alvos else []
            status, perda, latencia, jitter = self.classificar(resultados) if resultados else (FORA, 100.0, None, None)
            gateway = pingar(link.gateway, quantidade=3, origem=link.origem or None) if link.gateway else None
            medicoes.append((link, resultados, status, perda, latencia, jitter, gateway))

        todos_fora_com_gateway = bool(medicoes) and len(medicoes) > 1 and all(
            m[2] == FORA and m[6] is not None and m[6].respondeu for m in medicoes
        )
        estados_links = {}
        mudou_algum = False
        for link, resultados, status, perda, latencia, jitter, gateway in medicoes:
            estados_links[link.nome] = (status, gateway)
            if status == FORA:
                if firewall_ok is False:
                    causa = CAUSA_FIREWALL
                elif todos_fora_com_gateway:
                    causa = CAUSA_GERAL
                elif gateway is None:
                    causa = CAUSA_SEM_GATEWAY
                elif not gateway.respondeu:
                    causa = CAUSA_GATEWAY
                else:
                    causa = CAUSA_SEM_SAIDA
                diagnostico = f"fora: {causa}"
            elif status == DEGRADADO:
                causa = None
                diagnostico = self.motivo_degradado(perda, latencia)
            else:
                causa = None
                diagnostico = "normal"

            memoria, anterior = self.contabilizar(link.nome, status)
            if anterior is not None and (anterior == FORA) != (status == FORA):
                mudou_algum = True
            self.tratar_transicao(memoria, anterior, status, link.nome, causa,
                                  link.alvos[0] if link.alvos else None, origem=link.origem or None)
            self.tratar_destinos(link.nome, resultados, link.nome)

            rotulo = {"link": link.nome}
            metricas.add("nextec_link_status", status, rotulo, ajuda="0 fora, 1 normal, 2 degradado")
            metricas.add("nextec_link_diagnostico", 1, {"link": link.nome, "diagnostico": diagnostico})
            metricas.add("nextec_link_latencia_ms", latencia, rotulo)
            metricas.add("nextec_link_perda_percentual", perda, rotulo)
            metricas.add("nextec_link_jitter_ms", jitter, rotulo)
            metricas.add("nextec_link_estado_desde_segundos", round(memoria["desde"]), rotulo)
            metricas.add("nextec_link_rodadas_total", memoria["rodadas"], rotulo, tipo="counter")
            metricas.add("nextec_link_rodadas_fora_total", memoria["fora"], rotulo, tipo="counter")
            metricas.add("nextec_link_rodadas_degradado_total", memoria["degradado"], rotulo, tipo="counter")
            metricas.add("nextec_link_segundos_fora_total", memoria["segundos_fora"], rotulo, tipo="counter")
            if gateway is not None:
                metricas.add("nextec_link_gateway_status", 1 if gateway.respondeu else 0, rotulo)
                metricas.add("nextec_link_gateway_latencia_ms", gateway.latencia, rotulo)
            for resultado in resultados:
                metricas.add("nextec_link_alvo_latencia_ms", resultado.latencia,
                             {"link": link.nome, "alvo": resultado.alvo})
                metricas.add("nextec_link_alvo_perda_percentual", resultado.perda,
                             {"link": link.nome, "alvo": resultado.alvo})
            metricas.add("nextec_link_info", 1, {
                "link": link.nome, "papel": link.papel, "operadora": link.operadora,
                "tipo": link.tipo, "suporte": link.suporte,
                "ip_publico": link.ip_publico or self.ip_aprendido(link.nome),
                "gateway": link.gateway, "alvos": ", ".join(link.alvos),
                "firewall": link.firewall, "interface_firewall": link.interface_firewall,
                "teste_velocidade": link.teste_velocidade,
                "velocidade_mbps": str(link.velocidade_mbps or ""),
                "velocidade_upload_mbps": str(link.velocidade_upload_mbps or ""),
            })
            for sentido, valor in (("download", link.velocidade_mbps), ("upload", link.velocidade_upload_mbps)):
                if valor:
                    metricas.add("nextec_link_velocidade_contratada_mbps", valor,
                                 {"link": link.nome, "sentido": sentido})

        # IP público e link em uso
        if mudou_algum or momento - self._ultimo_ip >= self.intervalo_ip:
            self._ultimo_ip = momento
            novo_ip = ip_publico(self.urls_ip)
            memoria_ip = self.estado.secao("ip_publico")
            if novo_ip and memoria_ip.get("ip") and novo_ip != memoria_ip.get("ip"):
                self.eventos.registrar("links_evento", "failover", "ip_publico_mudou", "aviso",
                                       de=memoria_ip.get("ip"), para=novo_ip)
            if novo_ip:
                memoria_ip["ip"] = novo_ip
            self._ip_atual = novo_ip
        metricas.add("nextec_internet_ip_publico_sucesso", 1 if self._ip_atual else 0)
        if self._ip_atual:
            metricas.add("nextec_internet_ip_publico_info", 1, {"ip": self._ip_atual})

        link_ativo = self.descobrir_link_ativo(estados_links)
        if self.links:
            for link in self.links:
                metricas.add("nextec_link_ativo", 1 if link.nome == link_ativo else 0, {"link": link.nome})
            if link_ativo:
                metricas.add("nextec_internet_link_ativo_info", 1, {"link": link_ativo})
            memoria_ativo = self.estado.secao("link_ativo")
            if link_ativo and memoria_ativo.get("link") and link_ativo != memoria_ativo.get("link"):
                self.eventos.registrar("links_evento", "failover", "link_ativo_mudou", "aviso",
                                       de=memoria_ativo.get("link"), para=link_ativo)
            if link_ativo:
                memoria_ativo["link"] = link_ativo

        # DNS
        memoria_dns = self.estado.secao("dns")
        for servidor in self.dns_servidores:
            sucesso, tempo = consultar_dns(servidor, self.dns_nome)
            contagem = memoria_dns.setdefault(servidor, {"consultas": 0, "falhas": 0})
            contagem["consultas"] += 1
            contagem["falhas"] += 0 if sucesso else 1
            rotulo = {"servidor": servidor}
            metricas.add("nextec_dns_sucesso", 1 if sucesso else 0, rotulo)
            metricas.add("nextec_dns_resposta_ms", tempo, rotulo)
            metricas.add("nextec_dns_consultas_total", contagem["consultas"], rotulo, tipo="counter")
            metricas.add("nextec_dns_falhas_total", contagem["falhas"], rotulo, tipo="counter")

        metricas.add("nextec_links_intervalo_segundos", self.intervalo)
        metricas.add("nextec_links_limite_latencia_ms", self.limite_latencia)
        metricas.add("nextec_links_limite_perda_percentual", self.limite_perda)
        metricas.add("nextec_links_coletor_ultima_execucao_segundos", round(agora()),
                     ajuda="Horário da última rodada do monitor de internet e links")

        gravar_atomico(self.arquivo, metricas.texto())
        self.estado.salvar()

    def ip_aprendido(self, nome):
        """Último IP público visto quando só este link estava no ar."""
        melhor, quando = "", 0
        for ip, info in self.estado.secao("ip_links").items():
            if isinstance(info, dict) and info.get("link") == nome and info.get("visto", 0) > quando:
                melhor, quando = ip, info.get("visto", 0)
        return melhor

    def aprender_ip(self, nome):
        """Com um só link no ar, o IP público de saída é dele: guarda o par.
        Assim ninguém precisa informar o IP de cada link na instalação."""
        aprendidos = self.estado.secao("ip_links")
        aprendidos[self._ip_atual] = {"link": nome, "visto": round(agora())}
        if len(aprendidos) > 20:
            mais_antigo = min(aprendidos, key=lambda ip: aprendidos[ip].get("visto", 0)
                              if isinstance(aprendidos[ip], dict) else 0)
            aprendidos.pop(mais_antigo, None)

    def descobrir_link_ativo(self, estados_links):
        if not self.links:
            return None
        no_ar = [l for l in self.links if estados_links.get(l.nome, (FORA, None))[0] != FORA]
        if self._ip_atual:
            for link in self.links:
                if link.ip_publico and link.ip_publico == self._ip_atual:
                    return link.nome
            if len(no_ar) == 1:
                self.aprender_ip(no_ar[0].nome)
            info = self.estado.secao("ip_links").get(self._ip_atual)
            if isinstance(info, dict) and any(l.nome == info.get("link") for l in no_ar):
                return info["link"]
        if len(no_ar) == 1:
            return no_ar[0].nome
        primarios = [l for l in no_ar if l.papel == "primario"]
        return primarios[0].nome if primarios else (no_ar[0].nome if no_ar else None)


# ---------------------------------------------------------------------------
# Módulo Docker
# ---------------------------------------------------------------------------

class ConexaoUnix(http.client.HTTPConnection):
    def __init__(self, caminho, timeout=30):
        super().__init__("localhost", timeout=timeout)
        self.caminho = caminho

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.caminho)


class ApiDocker:
    def __init__(self, socket_docker):
        self.socket = socket_docker

    def get(self, caminho, timeout=30):
        conexao = ConexaoUnix(self.socket, timeout=timeout)
        try:
            conexao.request("GET", caminho)
            resposta = conexao.getresponse()
            corpo = resposta.read()
            if resposta.status >= 400:
                raise RuntimeError(f"API do Docker respondeu {resposta.status} em {caminho}")
            return json.loads(corpo) if corpo else None
        finally:
            conexao.close()

    def eventos(self, filtros):
        conexao = ConexaoUnix(self.socket, timeout=None)
        consulta = urllib.parse.urlencode({"filters": json.dumps(filtros)})
        conexao.request("GET", f"/events?{consulta}")
        resposta = conexao.getresponse()
        if resposta.status >= 400:
            raise RuntimeError(f"API do Docker respondeu {resposta.status} em /events")
        while True:
            linha = resposta.readline()
            if not linha:
                raise RuntimeError("fluxo de eventos do Docker encerrado")
            linha = linha.strip()
            if linha:
                yield json.loads(linha)


def epoch_docker(texto):
    """Converte data do Docker (RFC 3339 com nanossegundos) em epoch; 0 se vazia."""
    if not texto or texto.startswith("0001-"):
        return 0
    base = re.sub(r"\.(\d{6})\d*", r".\1", texto.replace("Z", "+00:00"))
    try:
        return int(datetime.fromisoformat(base).timestamp())
    except ValueError:
        return 0


def stack_do(rotulos):
    rotulos = rotulos or {}
    return (rotulos.get("com.docker.compose.project")
            or rotulos.get("com.docker.stack.namespace")
            or "avulso")


class ModuloDocker:
    nome = "docker"

    def __init__(self, config, eventos, estado, dir_textfile):
        secao = config["docker"] if config.has_section("docker") else {}
        self.api = ApiDocker(secao.get("socket", "/var/run/docker.sock"))
        self.intervalo = max(30, int(secao.get("intervalo_segundos", "60")))
        self.intervalo_espaco = max(300, int(secao.get("intervalo_espaco_segundos", "900")))
        self.eventos = eventos
        self.estado = estado
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_docker.prom")
        self._espaco = None
        self._ultimo_espaco = 0.0
        self._imagens = {}
        self._testes_saude = {}
        self._execs_ignorados = set()
        self._paradas_pedidas = {}

    def criacao_imagem(self, imagem_id):
        if imagem_id not in self._imagens:
            try:
                self._imagens[imagem_id] = epoch_docker(self.api.get(f"/images/{imagem_id}/json").get("Created"))
            except (OSError, RuntimeError, ValueError):
                self._imagens[imagem_id] = None
        return self._imagens[imagem_id]

    def espaco(self):
        if self._espaco is None or agora() - self._ultimo_espaco >= self.intervalo_espaco:
            try:
                df = self.api.get("/system/df", timeout=120)
                imagens = df.get("Images") or []
                containers = df.get("Containers") or []
                volumes = df.get("Volumes") or []
                cache = df.get("BuildCache") or []
                self._espaco = {
                    "imagens": (sum(i.get("Size", 0) for i in imagens),
                                sum(i.get("Size", 0) for i in imagens if i.get("Containers", 0) == 0)),
                    "containers": (sum(c.get("SizeRw", 0) or 0 for c in containers),
                                   sum(c.get("SizeRw", 0) or 0 for c in containers if c.get("State") != "running")),
                    "volumes": (sum((v.get("UsageData") or {}).get("Size", 0) or 0 for v in volumes),
                                sum((v.get("UsageData") or {}).get("Size", 0) or 0 for v in volumes
                                    if (v.get("UsageData") or {}).get("RefCount", 1) == 0)),
                    "cache": (sum(c.get("Size", 0) for c in cache),
                              sum(c.get("Size", 0) for c in cache if not c.get("InUse"))),
                }
                self._ultimo_espaco = agora()
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "não foi possível ler o espaço do Docker", erro=erro)
        return self._espaco

    def rodada(self):
        metricas = Metricas()
        try:
            info = self.api.get("/info")
            lista_containers = self.api.get("/containers/json?all=1")
        except (OSError, RuntimeError, ValueError) as erro:
            log("erro", "Docker não respondeu", erro=erro)
            metricas.add("docker_engine_ativo", 0, ajuda="1 se a API do Docker respondeu")
            metricas.add("docker_coletor_ultima_execucao_segundos", round(agora()))
            gravar_atomico(self.arquivo, metricas.texto())
            return

        metricas.add("docker_engine_ativo", 1, ajuda="1 se a API do Docker respondeu")
        metricas.add("docker_engine_info", 1, {
            "versao": info.get("ServerVersion", ""),
            "sistema": info.get("OperatingSystem", ""),
        })
        metricas.add("docker_engine_cpus", info.get("NCPU"))
        metricas.add("docker_engine_memoria_bytes", info.get("MemTotal"))

        rodando = [r["Id"] for r in lista_containers if r.get("State") == "running"]
        recursos = self.recursos(rodando)
        for resumo in lista_containers:
            try:
                c = self.api.get(f"/containers/{resumo['Id']}/json")
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "container sumiu durante a leitura", id=resumo.get("Id", "")[:12], erro=erro)
                continue
            self.metricas_container(metricas, c)
            self.metricas_recursos(metricas, c, recursos.get(resumo["Id"]))

        espaco = self.espaco()
        if espaco:
            for tipo, (usado, recuperavel) in espaco.items():
                metricas.add("docker_espaco_bytes", usado, {"tipo": tipo})
                metricas.add("docker_espaco_recuperavel_bytes", recuperavel, {"tipo": tipo})

        metricas.add("docker_coletor_ultima_execucao_segundos", round(agora()),
                     ajuda="Horário da última leitura completa do Docker")
        gravar_atomico(self.arquivo, metricas.texto())

    def recursos(self, ids):
        """Lê o consumo dos containers em paralelo (one-shot: sem esperar 1 s por container)."""
        resultado = {}

        def ler(container_id):
            try:
                resultado[container_id] = self.api.get(
                    f"/containers/{container_id}/stats?stream=false&one-shot=true", timeout=20)
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "consumo do container indisponível", id=container_id[:12], erro=erro)

        fila = list(ids)
        while fila:
            lote, fila = fila[:8], fila[8:]
            threads = [threading.Thread(target=ler, args=(i,), daemon=True) for i in lote]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
        return resultado

    def metricas_recursos(self, metricas, c, stats):
        """CPU, memória, rede e disco. O cAdvisor não enxerga containers no Docker
        com o armazenamento de imagens do containerd, então a leitura vem da API."""
        if not stats:
            return
        nome = (c.get("Name") or "").lstrip("/")
        rotulo = {"name": nome, "stack": stack_do((c.get("Config") or {}).get("Labels"))}
        cpu = ((stats.get("cpu_stats") or {}).get("cpu_usage") or {}).get("total_usage")
        if cpu is not None:
            metricas.add("docker_container_cpu_segundos_total", cpu / 1e9, rotulo, tipo="counter")
        memoria = stats.get("memory_stats") or {}
        if memoria.get("usage") is not None:
            detalhe = memoria.get("stats") or {}
            inativo = detalhe.get("inactive_file", detalhe.get("total_inactive_file", 0)) or 0
            metricas.add("docker_container_memoria_bytes", max(0, memoria["usage"] - inativo), rotulo)
        redes = stats.get("networks") or {}
        if redes:
            metricas.add("docker_container_rede_recebido_bytes_total",
                         sum(r.get("rx_bytes", 0) for r in redes.values()), rotulo, tipo="counter")
            metricas.add("docker_container_rede_enviado_bytes_total",
                         sum(r.get("tx_bytes", 0) for r in redes.values()), rotulo, tipo="counter")
        lido = escrito = 0
        for item in ((stats.get("blkio_stats") or {}).get("io_service_bytes_recursive") or []):
            operacao = str(item.get("op", "")).lower()
            if operacao == "read":
                lido += item.get("value", 0)
            elif operacao == "write":
                escrito += item.get("value", 0)
        metricas.add("docker_container_disco_lido_bytes_total", lido, rotulo, tipo="counter")
        metricas.add("docker_container_disco_escrito_bytes_total", escrito, rotulo, tipo="counter")

    def metricas_container(self, metricas, c):
        nome = (c.get("Name") or "").lstrip("/")
        config = c.get("Config") or {}
        host_config = c.get("HostConfig") or {}
        estado = c.get("State") or {}
        rotulos = config.get("Labels") or {}
        imagem = config.get("Image", "")
        rotulo = {"name": nome, "stack": stack_do(rotulos)}

        if estado.get("Restarting"):
            codigo_estado = 2
        elif estado.get("Paused"):
            codigo_estado = 3
        elif estado.get("Running"):
            codigo_estado = 1
        else:
            codigo_estado = 0
        metricas.add("docker_container_estado", codigo_estado, rotulo,
                     ajuda="0 parado, 1 rodando, 2 reiniciando, 3 pausado")

        saude = (estado.get("Health") or {}).get("Status")
        if saude:
            metricas.add("docker_container_health", {"healthy": 1, "unhealthy": 0}.get(saude, 2), rotulo,
                         ajuda="1 saudável, 0 com falha, 2 iniciando")

        politica = (host_config.get("RestartPolicy") or {}).get("Name") or "no"
        metricas.add("docker_container_info", 1, dict(rotulo, image=imagem, restart_policy=politica))
        metricas.add("docker_container_criacao_segundos", epoch_docker(c.get("Created")), rotulo)
        metricas.add("docker_container_inicio_segundos", epoch_docker(estado.get("StartedAt")), rotulo)
        metricas.add("docker_container_fim_segundos", epoch_docker(estado.get("FinishedAt")), rotulo)
        metricas.add("docker_container_reinicios_total", c.get("RestartCount", 0), rotulo, tipo="counter")
        metricas.add("docker_container_codigo_saida", estado.get("ExitCode", 0), rotulo)
        metricas.add("docker_container_oom", 1 if estado.get("OOMKilled") else 0, rotulo)
        metricas.add("docker_container_limite_memoria_bytes", host_config.get("Memory", 0) or 0, rotulo)

        usuario = (config.get("User") or "").strip()
        montagens = c.get("Mounts") or []
        socket_montado = any(
            (m.get("Source") or "") in ("/var/run/docker.sock", "/run/docker.sock") for m in montagens
        )
        metricas.add("docker_container_privilegiado", 1 if host_config.get("Privileged") else 0, rotulo)
        metricas.add("docker_container_docker_sock", 1 if socket_montado else 0, rotulo)
        metricas.add("docker_container_rede_host", 1 if host_config.get("NetworkMode") == "host" else 0, rotulo)
        metricas.add("docker_container_usuario_root", 1 if usuario in ("", "root", "0", "0:0") else 0, rotulo)
        sem_tag = ":" not in imagem.rsplit("/", 1)[-1] and "@" not in imagem
        metricas.add("docker_container_tag_latest", 1 if imagem.endswith(":latest") or sem_tag else 0, rotulo)
        criacao_imagem = self.criacao_imagem(c.get("Image", ""))
        metricas.add("docker_container_imagem_criacao_segundos", criacao_imagem, rotulo)

        for montagem in montagens:
            metricas.add("docker_container_montagem", 1, dict(
                rotulo,
                tipo=montagem.get("Type", ""),
                origem=montagem.get("Source") or montagem.get("Name", ""),
                destino=montagem.get("Destination", ""),
                modo="rw" if montagem.get("RW", True) else "ro",
            ))

        redes = (c.get("NetworkSettings") or {}).get("Networks") or {}
        for nome_rede, dados in redes.items():
            metricas.add("docker_container_rede", 1, dict(rotulo, rede=nome_rede, ip=(dados or {}).get("IPAddress", "")))

        portas = (c.get("NetworkSettings") or {}).get("Ports") or {}
        for porta_container, publicacoes in portas.items():
            numero, _, protocolo = porta_container.partition("/")
            if not publicacoes:
                metricas.add("docker_container_porta", 1, dict(
                    rotulo, porta_host="", porta_container=numero, protocolo=protocolo, ip="", exposicao="interna"))
                continue
            for publicacao in publicacoes:
                ip = publicacao.get("HostIp", "")
                if ip in ("", "0.0.0.0", "::"):
                    exposicao = "publica"
                elif ip in ("127.0.0.1", "::1"):
                    exposicao = "local"
                else:
                    exposicao = "restrita"
                metricas.add("docker_container_porta", 1, dict(
                    rotulo, porta_host=publicacao.get("HostPort", ""), porta_container=numero,
                    protocolo=protocolo, ip=ip, exposicao=exposicao))

    # Eventos ----------------------------------------------------------------

    def comando_teste_saude(self, container_id):
        """Comando do health check do container, para não confundir com acesso de pessoa."""
        if container_id not in self._testes_saude:
            comando = None
            try:
                teste = ((self.api.get(f"/containers/{container_id}/json", timeout=5).get("Config") or {})
                         .get("Healthcheck") or {}).get("Test") or []
                if teste and teste[0] == "CMD-SHELL":
                    comando = "/bin/sh -c " + " ".join(teste[1:])
                elif teste and teste[0] == "CMD":
                    comando = " ".join(teste[1:])
            except (OSError, RuntimeError, ValueError):
                comando = None
            self._testes_saude[container_id] = comando
        return self._testes_saude[container_id]

    ACOES_AUDITORIA = {
        "create": ("criado", "Container criado"),
        "destroy": ("removido", "Container removido"),
        "start": ("iniciado", "Container iniciado"),
        "restart": ("reiniciado", "Container reiniciado"),
        "rename": ("renomeado", "Container renomeado"),
        "update": ("alterado", "Configuração do container alterada"),
        "pause": ("pausado", "Container pausado"),
        "unpause": ("retomado", "Container retomado"),
        "commit": ("imagem_gerada", "Imagem gerada a partir do container"),
    }
    ACOES_ARQUIVO = {
        "archive-path": ("arquivo_lido", "Arquivo copiado do container"),
        "extract-to-dir": ("arquivo_gravado", "Arquivo copiado para o container"),
        "export": ("exportado", "Container exportado"),
    }
    ACOES_IMAGEM = {
        "pull": ("imagem_baixada", "Imagem baixada"),
        "push": ("imagem_enviada", "Imagem enviada"),
        "delete": ("imagem_removida", "Imagem removida"),
        "tag": ("imagem_marcada", "Tag aplicada na imagem"),
        "untag": ("imagem_desmarcada", "Tag removida da imagem"),
        "import": ("imagem_importada", "Imagem importada"),
        "load": ("imagem_carregada", "Imagem carregada"),
        "save": ("imagem_salva", "Imagem salva em arquivo"),
    }

    def acompanhar_eventos(self, parar):
        filtros = {"type": ["container", "image"]}
        while not parar.is_set():
            try:
                for evento in self.api.eventos(filtros):
                    self.tratar_evento(evento)
                    if parar.is_set():
                        return
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "leitura de eventos do Docker interrompida, tentando de novo em 10 s", erro=erro)
                parar.wait(10)

    def tratar_evento(self, evento):
        tipo = evento.get("Type")
        acao = evento.get("Action") or evento.get("status") or ""
        ator = evento.get("Actor") or {}
        atributos = ator.get("Attributes") or {}
        nome = atributos.get("name", "")
        stack = stack_do(atributos)
        base = {"container": nome, "stack": stack}

        if tipo == "image":
            chave = acao.split(":")[0]
            if chave in self.ACOES_IMAGEM:
                evento_nome, texto = self.ACOES_IMAGEM[chave]
                imagem = atributos.get("name") or ator.get("ID", "")
                self.eventos.registrar("docker_evento", "imagem", evento_nome, "info",
                                       imagem=imagem, detalhe=f"{texto}: {imagem}")
            return

        container_id = ator.get("ID", "")
        if acao in ("kill", "stop"):
            self._paradas_pedidas[container_id] = agora()
            return
        if acao == "destroy":
            self._testes_saude.pop(container_id, None)
        if acao == "die":
            codigo = atributos.get("exitCode", "0")
            pedida = agora() - self._paradas_pedidas.pop(container_id, 0) < 60
            if codigo != "0" and not pedida:
                self.eventos.registrar("docker_evento", "falha", "caiu", "erro", codigo_saida=codigo,
                                       detalhe=f"{nome} parou com código {codigo}", **base)
            else:
                motivo = "a pedido (stop, restart ou atualização)" if pedida else "normalmente"
                self.eventos.registrar("docker_evento", "auditoria", "parado", "info", codigo_saida=codigo,
                                       detalhe=f"{nome} parou {motivo}", **base)
        elif acao == "oom":
            self.eventos.registrar("docker_evento", "falha", "sem_memoria", "erro",
                                   detalhe=f"{nome} ficou sem memória", **base)
        elif acao.startswith("health_status"):
            situacao = acao.split(":", 1)[1].strip() if ":" in acao else ""
            if situacao == "unhealthy":
                self.eventos.registrar("docker_evento", "falha", "unhealthy", "aviso",
                                       detalhe=f"{nome}: teste de saúde falhando", **base)
            elif situacao == "healthy":
                self.eventos.registrar("docker_evento", "falha", "healthy", "info",
                                       detalhe=f"{nome}: teste de saúde normalizado", **base)
        elif acao.startswith("exec_start"):
            exec_id = atributos.get("execID", "")
            tty, comando, usuario = "false", acao.split(":", 1)[1].strip() if ":" in acao else "", "root"
            if exec_id:
                try:
                    dados = self.api.get(f"/exec/{exec_id}/json", timeout=5)
                    processo = dados.get("ProcessConfig") or {}
                    tty = "true" if processo.get("tty") else "false"
                    partes = [processo.get("entrypoint", "")] + list(processo.get("arguments") or [])
                    comando = " ".join(p for p in partes if p) or comando
                    usuario = processo.get("user") or "root"
                except (OSError, RuntimeError, ValueError):
                    pass
            if tty != "true" and comando and comando == self.comando_teste_saude(container_id):
                self._execs_ignorados.add(exec_id)
                return
            nivel = "aviso" if tty == "true" else "info"
            descricao = "Terminal aberto" if tty == "true" else "Comando executado"
            origem_ip, usuario_login = origem_do_exec(container_id, nome)
            de_onde = f" por {usuario_login or 'usuário desconhecido'} de {origem_ip}" if origem_ip else ""
            self.eventos.registrar("docker_evento", "acesso", "acesso_inicio", nivel,
                                   exec_id=exec_id, tty=tty, comando=comando[:300], usuario_container=usuario,
                                   origem_ip=origem_ip, usuario_login=usuario_login,
                                   detalhe=f"{descricao} em {nome}{de_onde}: {comando[:120]}", **base)
        elif acao.startswith("exec_die"):
            if atributos.get("execID", "") in self._execs_ignorados:
                self._execs_ignorados.discard(atributos.get("execID", ""))
                return
            self.eventos.registrar("docker_evento", "acesso", "acesso_fim", "info",
                                   exec_id=atributos.get("execID", ""), codigo_saida=atributos.get("exitCode", ""),
                                   detalhe=f"Acesso encerrado em {nome}", **base)
        elif acao in self.ACOES_ARQUIVO:
            evento_nome, texto = self.ACOES_ARQUIVO[acao]
            caminho = atributos.get("path", "")
            self.eventos.registrar("docker_evento", "acesso", evento_nome, "aviso", caminho=caminho,
                                   detalhe=f"{texto}: {nome} {caminho}".strip(), **base)
        elif acao in self.ACOES_AUDITORIA:
            evento_nome, texto = self.ACOES_AUDITORIA[acao]
            self.eventos.registrar("docker_evento", "auditoria", evento_nome, "info",
                                   imagem=atributos.get("image", ""), detalhe=f"{texto}: {nome}", **base)


# ---------------------------------------------------------------------------
# Módulo velocidade
# ---------------------------------------------------------------------------

class ModuloVelocidade:
    nome = "velocidade"

    def __init__(self, config, eventos, estado, dir_textfile):
        secao = config["velocidade"] if config.has_section("velocidade") else {}
        self.intervalo = max(15, int(secao.get("intervalo_minutos", "30"))) * 60
        self.binario = secao.get("speedtest", "") or shutil.which("speedtest") or "/usr/bin/speedtest"
        self.eventos = eventos
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_velocidade.prom")

    def rodada(self):
        metricas = Metricas()
        inicio = agora()
        try:
            saida = subprocess.run(
                [self.binario, "--accept-license", "--accept-gdpr", "-f", "json"],
                capture_output=True, text=True, timeout=180,
            )
            dados = json.loads(saida.stdout)
            download = dados["download"]["bandwidth"] * 8
            upload = dados["upload"]["bandwidth"] * 8
            latencia = dados["ping"]["latency"]
            jitter = dados["ping"].get("jitter")
            perda = dados.get("packetLoss", 0)
            servidor = dados.get("server") or {}
        except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError) as erro:
            log("erro", "teste de velocidade falhou", erro=erro)
            metricas.add("nextec_speedtest_up", 0)
            metricas.add("nextec_speedtest_last_run_timestamp_seconds", round(inicio))
            gravar_atomico(self.arquivo, metricas.texto())
            self.eventos.registrar("links_evento", "velocidade", "teste_velocidade", "aviso",
                                   detalhe=f"teste falhou: {erro}")
            return

        metricas.add("nextec_speedtest_up", 1, ajuda="1 se o último teste terminou com sucesso")
        metricas.add("nextec_speedtest_download_bits_per_second", download)
        metricas.add("nextec_speedtest_upload_bits_per_second", upload)
        metricas.add("nextec_speedtest_ping_latency_milliseconds", latencia)
        metricas.add("nextec_speedtest_ping_jitter_milliseconds", jitter)
        metricas.add("nextec_speedtest_packet_loss_percent", perda)
        metricas.add("nextec_speedtest_last_run_timestamp_seconds", round(inicio))
        metricas.add("nextec_speedtest_server_info", 1, {
            "server_id": str(servidor.get("id", "")),
            "server_name": servidor.get("name", ""),
            "server_location": servidor.get("location", ""),
        })
        gravar_atomico(self.arquivo, metricas.texto())
        self.eventos.registrar(
            "links_evento", "velocidade", "teste_velocidade", "info",
            download_mbps=round(download / 1e6, 1), upload_mbps=round(upload / 1e6, 1),
            latencia_ms=round(latencia, 1), detalhe=servidor.get("name", ""),
        )


# ---------------------------------------------------------------------------
# Execução
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Módulo acessos
# ---------------------------------------------------------------------------
# Lê o journal (sshd, sudo, su, login) e grava um evento por acesso, com o IP
# de origem e a classificação usada pelos alertas de acesso privilegiado:
#   alerta=critico  login direto como root, ou usuário privilegiado entrando
#                   de IP público que ele não usou neste servidor nos últimos
#                   30 dias
#   alerta=resumo   usuário privilegiado fora do horário comercial
#   alerta=nenhum   só registro
# A rede interna (IP privado, VPN) e o próprio IP público do local não contam
# como origem nova.

FUSO_BRASILIA = timezone(timedelta(hours=-3))
HORARIO_PADRAO = "seg-sex 07:00-19:00; sab 07:00-14:00"
DIAS_SEMANA = {"seg": 0, "ter": 1, "qua": 2, "qui": 3, "sex": 4, "sab": 5, "dom": 6}
REDE_COMPARTILHADA = ipaddress.ip_network("100.64.0.0/10")
IDENTIFICADORES_ACESSO = ("sshd", "sshd-session", "sudo", "su", "login")
RE_SSH_ACEITO = re.compile(r"^Accepted (\S+) for (\S+) from (\S+) port \d+")
RE_SUDO = re.compile(r"^\s*(\S+) : (?:.*?; )?TTY=(\S+) ; PWD=.*? ; USER=(\S+) ; (?:.*?; )?COMMAND=(.*)$")
RE_SESSAO_ABERTA = re.compile(r"session opened for user ([^\s(]+)(?:\(uid=\d+\))? by ([^\s(]*)\(uid=(\d+)\)")
TTY_SEM_SESSAO = ("", "unknown", "none", "(none)")


def ler_horario(texto):
    """'seg-sex 07:00-19:00; sab 07:00-14:00' vira {dia_da_semana: [(início, fim) em minutos]}."""
    grade = {}
    for parte in str(texto or "").split(";"):
        achado = re.match(r"^([a-z]{3})(?:-([a-z]{3}))?\s+(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$", parte.strip().lower())
        if not achado:
            continue
        primeiro = DIAS_SEMANA.get(achado.group(1))
        ultimo = DIAS_SEMANA.get(achado.group(2) or achado.group(1))
        if primeiro is None or ultimo is None:
            continue
        faixa = (int(achado.group(3)) * 60 + int(achado.group(4)), int(achado.group(5)) * 60 + int(achado.group(6)))
        dia = primeiro
        while True:
            grade.setdefault(dia, []).append(faixa)
            if dia == ultimo:
                break
            dia = (dia + 1) % 7
    return grade


def fora_do_horario(grade, instante):
    local = datetime.fromtimestamp(instante, FUSO_BRASILIA)
    minuto = local.hour * 60 + local.minute
    return not any(inicio <= minuto < fim for inicio, fim in grade.get(local.weekday(), []))


def classificar_origem(ip, ip_publico_local, conhecidas):
    """local (console), conhecida (lista do ini), rede_local (mesmo IP público
    do local), rede_interna (IP privado ou VPN) ou publica."""
    if not ip:
        return "local"
    try:
        endereco = ipaddress.ip_address(ip)
    except ValueError:
        return "publica"  # nome em vez de IP (UseDNS): tratado como desconhecido
    if endereco.is_loopback:
        return "local"
    if any(endereco.version == rede.version and endereco in rede for rede in conhecidas):
        return "conhecida"
    if ip_publico_local and ip == ip_publico_local:
        return "rede_local"
    if endereco.is_private or endereco.is_link_local or (endereco.version == 4 and endereco in REDE_COMPARTILHADA):
        return "rede_interna"
    return "publica"


def prefixo_origem(ip):
    """IPv4 por /24 e IPv6 por /64: troca de IP dentro da mesma rede não é origem nova."""
    try:
        endereco = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    return str(ipaddress.ip_network(f"{ip}/{24 if endereco.version == 4 else 64}", strict=False))


def nivel_alerta(privilegiado, emergencia, tipo_origem, nova, fora):
    if emergencia:
        return "critico"
    if privilegiado and tipo_origem == "publica" and nova:
        return "critico"
    if privilegiado and fora:
        return "resumo"
    return "nenhum"


def origem_por_tty(tty):
    """IP da sessão dona do terminal (pts/0), pelo utmp (comando who)."""
    if tty in TTY_SEM_SESSAO or not shutil.which("who"):
        return ""
    tty = tty.replace("/dev/", "")
    try:
        saida = subprocess.run(["who"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=5, check=False).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""
    for linha in saida.splitlines():
        partes = linha.split()
        if len(partes) >= 2 and partes[1] == tty:
            achado = re.search(r"\(([^)]+)\)\s*$", linha)
            if achado and not achado.group(1).startswith(":"):
                return achado.group(1)
    return ""


def origem_por_sessao(sessao):
    """IP remoto de uma sessão do logind (campo _AUDIT_SESSION do journal)."""
    if not sessao or not shutil.which("loginctl"):
        return ""
    try:
        saida = subprocess.run(["loginctl", "show-session", str(sessao), "-p", "RemoteHost", "--value"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return saida.stdout.decode("utf-8", "replace").strip()


def ler_proc(pid, arquivo):
    try:
        with open(f"/proc/{pid}/{arquivo}", "rb") as f:
            return f.read()
    except OSError:
        return b""


def ssh_do_processo(pid, limite=40):
    """Sobe na árvore de processos até achar SSH_CONNECTION (IP de quem abriu a sessão).

    O sudo limpa o ambiente, mas o shell da sessão SSH acima dele ainda tem a
    variável. Devolve (ip, usuário de login).
    """
    usuario = ""
    for _ in range(limite):
        ambiente = ler_proc(pid, "environ").split(b"\0")
        for item in ambiente:
            if item.startswith(b"SUDO_USER=") and not usuario:
                usuario = item.split(b"=", 1)[1].decode("utf-8", "replace")
            if item.startswith(b"SSH_CONNECTION="):
                ip = item.split(b"=", 1)[1].decode("utf-8", "replace").split(" ")[0]
                if not usuario:
                    for outro in ambiente:
                        if outro.startswith(b"USER="):
                            usuario = outro.split(b"=", 1)[1].decode("utf-8", "replace")
                return ip, usuario
        stat = ler_proc(pid, "stat").decode("utf-8", "replace")
        try:
            pid = int(stat.rsplit(")", 1)[1].split()[1])
        except (IndexError, ValueError):
            break
        if pid <= 1:
            break
    return "", usuario


def origem_do_exec(container_id, nome):
    """Quem abriu o docker exec: procura o processo do cliente docker e sobe até a sessão SSH.

    Exec aberto pela API (ex.: console do Portainer) não tem processo local e
    fica sem origem aqui.
    """
    curto = (container_id or "")[:12]
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return "", ""
    for pid in pids:
        args = [a.decode("utf-8", "replace") for a in ler_proc(pid, "cmdline").split(b"\0") if a]
        if len(args) < 3 or os.path.basename(args[0]) not in ("docker", "docker-compose", "podman"):
            continue
        if "exec" not in args:
            continue
        if (nome and nome in args) or (curto and any(a.startswith(curto) for a in args)):
            return ssh_do_processo(int(pid))
    return "", ""


class ModuloAcessos:
    nome = "acessos"

    def __init__(self, config, eventos, estado, dir_textfile):
        secao = config["acessos"] if config.has_section("acessos") else {}
        self.intervalo = 300
        self.eventos = eventos
        self.estado = estado
        self.grade = ler_horario(secao.get("horario", HORARIO_PADRAO)) or ler_horario(HORARIO_PADRAO)
        self.grupos = set(lista(secao.get("grupos_privilegiados", "sudo, wheel, admin, docker")))
        self.dias = max(1, int(secao.get("dias_origem_conhecida", "30")))
        self.conhecidas = []
        for item in lista(secao.get("origens_conhecidas", "")):
            try:
                self.conhecidas.append(ipaddress.ip_network(item, strict=False))
            except ValueError:
                log("aviso", "origem conhecida inválida ignorada", valor=item)
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_acessos.prom")

    # -- classificação -----------------------------------------------------

    def privilegiado(self, usuario):
        if usuario == "root":
            return True
        try:
            conta = pwd.getpwnam(usuario)
            grupos = {grp.getgrgid(g).gr_name for g in os.getgrouplist(usuario, conta.pw_gid)}
        except (KeyError, OSError):
            return False  # usuário de diretório (LDAP/SSSD) sem resolução local
        return conta.pw_uid == 0 or bool(grupos & self.grupos)

    def ip_publico_local(self):
        return (self.estado.secao("ip_publico") if self.estado else {}).get("ip", "")

    def origem_nova(self, usuario, ip, instante):
        """Registra a origem e diz se o usuário não a usou nos últimos N dias."""
        historico = self.estado.secao("acessos_origens")
        prefixo = prefixo_origem(ip)
        # Mesma trava do Estado: o salvar() serializa estes dicionários.
        with self.estado._trava:
            vistos = historico.setdefault(usuario, {})
            anterior = vistos.get(prefixo, 0)
            vistos[prefixo] = int(instante)
        return instante - anterior > self.dias * 86400

    def contar(self, privilegiado, alerta):
        contagem = self.estado.secao("acessos_contagem")
        chave = f"{'sim' if privilegiado else 'nao'}|{alerta}"
        with self.estado._trava:
            contagem[chave] = int(contagem.get(chave, 0)) + 1

    # -- registro ----------------------------------------------------------

    def registrar_login(self, usuario, canal, metodo, ip, instante):
        emergencia = usuario == "root"
        privilegiado = emergencia or self.privilegiado(usuario)
        tipo = classificar_origem(ip, self.ip_publico_local(), self.conhecidas)
        nova = self.origem_nova(usuario, ip, instante) if tipo == "publica" else False
        fora = fora_do_horario(self.grade, instante)
        alerta = nivel_alerta(privilegiado, emergencia, tipo, nova, fora)
        nivel = {"critico": "erro", "resumo": "aviso"}.get(alerta, "info")
        onde = f"de {ip}" if ip else "no console"
        self.eventos.registrar(
            "acesso_evento", "login", "login", nivel,
            usuario=usuario, canal=canal, metodo=metodo, origem_ip=ip, origem_tipo=tipo,
            origem_nova="sim" if nova else "nao", privilegiado="sim" if privilegiado else "nao",
            conta_emergencia="sim" if emergencia else "nao", fora_horario="sim" if fora else "nao",
            alerta=alerta, detalhe=f"{usuario} entrou por {canal} {onde}")
        self.contar(privilegiado, alerta)

    def registrar_elevacao(self, meio, usuario, destino, tty, comando, entrada):
        ip = origem_por_sessao(entrada.get("_AUDIT_SESSION")) or origem_por_tty(tty)
        tipo = classificar_origem(ip, self.ip_publico_local(), self.conhecidas)
        self.eventos.registrar(
            "acesso_evento", "elevacao", meio, "info",
            usuario=usuario, usuario_destino=destino, tty=tty, comando=comando[:300],
            origem_ip=ip, origem_tipo=tipo, privilegiado="sim", alerta="nenhum",
            detalhe=f"{usuario} virou {destino} por {meio}" + (f" (sessão de {ip})" if ip else ""))
        self.contar(True, "nenhum")

    def tratar(self, entrada):
        identificador = entrada.get("SYSLOG_IDENTIFIER", "")
        mensagem = entrada.get("MESSAGE", "")
        if isinstance(mensagem, list):
            mensagem = bytes(mensagem).decode("utf-8", "replace")
        try:
            instante = int(entrada.get("__REALTIME_TIMESTAMP", "0")) / 1e6 or agora()
        except ValueError:
            instante = agora()
        if identificador in ("sshd", "sshd-session"):
            achado = RE_SSH_ACEITO.match(mensagem)
            if achado:
                self.registrar_login(achado.group(2), "ssh", achado.group(1), achado.group(3), instante)
        elif identificador == "sudo":
            achado = RE_SUDO.match(mensagem)
            # sudo sem terminal é automação (cron, scripts): não é acesso de pessoa.
            if achado and achado.group(2) not in TTY_SEM_SESSAO:
                self.registrar_elevacao("sudo", achado.group(1), achado.group(3), achado.group(2), achado.group(4), entrada)
        elif identificador == "su":
            achado = RE_SESSAO_ABERTA.search(mensagem)
            if achado and "(su" in mensagem:
                origem = achado.group(2)
                if not origem:
                    try:
                        origem = pwd.getpwuid(int(achado.group(3))).pw_name
                    except (KeyError, ValueError):
                        origem = achado.group(3)
                self.registrar_elevacao("su", origem, achado.group(1), "", "", entrada)
        elif identificador == "login":
            achado = RE_SESSAO_ABERTA.search(mensagem)
            if achado and achado.group(2) == "LOGIN":
                self.registrar_login(achado.group(1), "console", "senha", "", instante)

    def acompanhar(self, parar):
        """Segue o journal; o cursor salvo evita perder acesso durante um reinício."""
        if not shutil.which("journalctl"):
            log("aviso", "journalctl não encontrado: o módulo acessos fica parado")
            parar.wait()
            return
        memoria = self.estado.secao("acessos_journal")
        with self.estado._trava:
            memoria.setdefault("cursor", None)
        while not parar.is_set():
            cursor = memoria.get("cursor")
            comando = ["journalctl", "-f", "-o", "json", "--no-pager"]
            comando += [f"--after-cursor={cursor}"] if cursor else ["-n", "0"]
            comando += [f"SYSLOG_IDENTIFIER={i}" for i in IDENTIFICADORES_ACESSO]
            lidas = 0
            try:
                processo = subprocess.Popen(comando, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                for linha in processo.stdout:
                    if parar.is_set():
                        processo.terminate()
                        break
                    try:
                        entrada = json.loads(linha)
                    except ValueError:
                        continue
                    lidas += 1
                    try:
                        self.tratar(entrada)
                    except Exception as erro:  # uma linha estranha não para o módulo
                        log("erro", "falha ao tratar linha do journal", erro=repr(erro))
                    if entrada.get("__CURSOR"):
                        memoria["cursor"] = entrada["__CURSOR"]
                processo.wait()
                if processo.returncode not in (0, None) and lidas == 0 and cursor:
                    log("aviso", "cursor do journal inválido; seguindo do momento atual")
                    memoria.pop("cursor", None)
            except OSError as erro:
                log("erro", "leitura do journal interrompida", erro=erro)
            parar.wait(10)

    def rodada(self):
        historico = self.estado.secao("acessos_origens")
        contagem = self.estado.secao("acessos_contagem")
        limite = agora() - self.dias * 86400
        metricas = Metricas()
        with self.estado._trava:
            for usuario in list(historico):
                for prefixo, visto in list(historico[usuario].items()):
                    if visto < limite:
                        del historico[usuario][prefixo]
                if not historico[usuario]:
                    del historico[usuario]
            for chave, total in sorted(contagem.items()):
                privilegiado, alerta = chave.split("|", 1)
                metricas.add("nextec_acessos_total", total, {"privilegiado": privilegiado, "alerta": alerta},
                             tipo="counter", ajuda="Acessos registrados (logins, sudo e su).")
        metricas.add("nextec_acessos_coletor_ultima_execucao_segundos", int(agora()))
        gravar_atomico(self.arquivo, metricas.texto())
        self.estado.salvar()

# ---------------------------------------------------------------------------
# Módulo bancos
# ---------------------------------------------------------------------------
# Bancos que não têm exportador Prometheus de uso simples. A coleta não usa
# driver nem senha: olha os processos do banco, as portas em que eles
# escutam, as conexões estabelecidas nessas portas e o tamanho dos arquivos
# das bases. Sai no padrão nextec_banco_* que o painel "Nextec | Banco de
# dados" já converte junto com SQL Server, MySQL/MariaDB e PostgreSQL.
#
# Configuração ([bancos] no INI):
#   ativo = sim
#   motores = firebird, oracle, sqlanywhere, sqlserver
#       motores esperados neste servidor. O que estiver na lista e não tiver
#       processo no ar sai com nextec_banco_up 0. Os que não estão na lista
#       entram quando são encontrados.
#   arquivos = sqlite:/srv/app/dados/*.db, firebird:/dados/*.fdb
#       bases para medir o tamanho, como motor:caminho (curinga aceito).
#       Firebird e SQL Anywhere também têm as bases descobertas sozinhas.

MOTORES_BANCO = {
    "firebird": "Firebird",
    "oracle": "Oracle",
    "sqlanywhere": "SQL Anywhere",
    "sqlserver": "SQL Server",
    "sqlite": "SQLite",
}
RE_FIREBIRD = re.compile(r"^(firebird|fbserver|fb_smp_server|fb_inet_server|fbsuperserver)$")
RE_SQLANYWHERE = re.compile(r"^(dbsrv|dbeng)\d+$")
RE_ORACLE_PMON = re.compile(r"^ora_pmon_(.+)$")
CONFIGS_FIREBIRD = [
    "/opt/firebird/databases.conf", "/opt/firebird/aliases.conf",
    "/etc/firebird/*/databases.conf", "/etc/firebird/*/aliases.conf",
    "/etc/firebird*/databases.conf", "/etc/firebird*/aliases.conf",
]
PASTAS_SQLSERVER = ["/var/opt/mssql/data/*.mdf", "/var/opt/mssql/data/*.ndf"]


def processos():
    """Lista (pid, comm, argumentos) dos processos do sistema."""
    lista_proc = []
    for nome in os.listdir("/proc"):
        if not nome.isdigit():
            continue
        try:
            with open(f"/proc/{nome}/comm", encoding="utf-8", errors="replace") as arq:
                comm = arq.read().strip()
            with open(f"/proc/{nome}/cmdline", "rb") as arq:
                args = [a.decode("utf-8", "replace") for a in arq.read().split(b"\0") if a]
        except OSError:
            continue
        lista_proc.append((int(nome), comm, args))
    return lista_proc


def memoria_processo(pid):
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as arq:
            for linha in arq:
                if linha.startswith("VmRSS:"):
                    return int(linha.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


def inicio_processo(pid):
    """Momento (epoch) em que o processo começou."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as arq:
            campos = arq.read().rsplit(")", 1)[1].split()
        with open("/proc/stat", encoding="utf-8") as arq:
            boot = next(int(l.split()[1]) for l in arq if l.startswith("btime"))
        return boot + int(campos[19]) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError, StopIteration):
        return None


def sockets_por_pid():
    """inode do socket -> pid dono."""
    donos = {}
    for nome in os.listdir("/proc"):
        if not nome.isdigit():
            continue
        try:
            for fd in os.listdir(f"/proc/{nome}/fd"):
                alvo = os.readlink(f"/proc/{nome}/fd/{fd}")
                if alvo.startswith("socket:["):
                    donos[alvo[8:-1]] = int(nome)
        except OSError:
            continue
    return donos


def tabela_tcp():
    """Lista (porta_local, estado, inode) de /proc/net/tcp e tcp6."""
    linhas = []
    for arquivo in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(arquivo, encoding="utf-8") as arq:
                next(arq)
                for linha in arq:
                    campos = linha.split()
                    porta = int(campos[1].rsplit(":", 1)[1], 16)
                    linhas.append((porta, campos[3], campos[9]))
        except (OSError, ValueError, IndexError, StopIteration):
            continue
    return linhas


def bases_firebird():
    caminhos = set()
    for padrao in CONFIGS_FIREBIRD:
        for arquivo in glob.glob(padrao):
            try:
                with open(arquivo, encoding="utf-8", errors="replace") as arq:
                    for linha in arq:
                        linha = linha.split("#", 1)[0].strip()
                        if "=" in linha and not linha.startswith(("{", "}")):
                            valor = linha.split("=", 1)[1].strip().strip('"')
                            if valor.startswith("/") and "{" not in valor:
                                caminhos.add(valor)
            except OSError:
                continue
    return sorted(caminhos)


def nome_base(caminho):
    return os.path.splitext(os.path.basename(caminho))[0]


class ModuloBancos:
    nome = "bancos"

    def __init__(self, config, eventos, estado, dir_textfile):
        secao = config["bancos"] if config.has_section("bancos") else {}
        self.intervalo = max(30, int(secao.get("intervalo_segundos", "60")))
        self.esperados = [m.lower() for m in lista(secao.get("motores", "")) if m.lower() in MOTORES_BANCO]
        self.arquivos = []
        for item in lista(secao.get("arquivos", "")):
            motor, _, caminho = item.partition(":")
            if motor.lower() in MOTORES_BANCO and caminho:
                self.arquivos.append((motor.lower(), caminho.strip()))
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_bancos.prom")

    def instancias(self):
        """motor -> instância -> {pids, bases}."""
        achados = {}

        def anotar(motor, instancia, pid, bases=()):
            item = achados.setdefault(motor, {}).setdefault(instancia, {"pids": set(), "bases": set()})
            item["pids"].add(pid)
            item["bases"].update(bases)

        lista_proc = processos()
        # O comm do Linux corta em 15 caracteres; o nome completo dos
        # processos do Oracle (ora_pmon_<SID>, oracle<SID>) está no argv[0].
        nomes = {pid: (args[0].split()[0] if args else comm) for pid, comm, args in lista_proc}
        sids = {RE_ORACLE_PMON.match(n).group(1) for n in nomes.values() if RE_ORACLE_PMON.match(n)}
        for pid, comm, args in lista_proc:
            if RE_FIREBIRD.match(comm):
                anotar("firebird", "padrao", pid)
            elif RE_SQLANYWHERE.match(comm):
                nome = comm
                if "-n" in args and args.index("-n") + 1 < len(args):
                    nome = args[args.index("-n") + 1]
                anotar("sqlanywhere", nome, pid, [a for a in args if a.lower().endswith(".db")])
            elif comm == "sqlservr":
                anotar("sqlserver", "MSSQLSERVER", pid)
            elif comm == "tnslsnr" and sids:
                for sid in sids:
                    anotar("oracle", sid, pid)
            else:
                nome = nomes[pid]
                for sid in sids:
                    if (nome.startswith("ora_") and nome.endswith(f"_{sid}")) or nome == f"oracle{sid}":
                        anotar("oracle", sid, pid)
        return achados

    def rodada(self):
        metricas = Metricas()
        achados = self.instancias()
        donos = sockets_por_pid() if achados else {}
        tcp = tabela_tcp() if achados else []
        momento = agora()

        for motor in sorted(set(achados) | set(self.esperados)):
            rotulo_motor = MOTORES_BANCO[motor]
            instancias = achados.get(motor, {})
            if not instancias and motor in self.esperados and motor != "sqlite":
                metricas.add("nextec_banco_up", 0, {"motor": rotulo_motor, "instancia": "padrao"},
                             ajuda="1 no ar, 0 parado (processo do banco ausente)")
            for instancia, dados in sorted(instancias.items()):
                rotulos = {"motor": rotulo_motor, "instancia": instancia}
                pids = dados["pids"]
                portas = {porta for porta, est, inode in tcp if est == "0A" and donos.get(inode) in pids}
                conexoes = sum(1 for porta, est, _ in tcp if est == "01" and porta in portas)
                metricas.add("nextec_banco_up", 1, rotulos, ajuda="1 no ar, 0 parado (processo do banco ausente)")
                metricas.add("nextec_banco_conexoes_total", conexoes, rotulos,
                             ajuda="Conexões TCP estabelecidas nas portas do banco")
                for porta in sorted(portas):
                    metricas.add("nextec_banco_porta_info", 1, dict(rotulos, porta=str(porta)))
                # No Oracle a memória é compartilhada entre os processos e a
                # soma mostraria um valor várias vezes maior que o real.
                if motor != "oracle":
                    metricas.add("nextec_banco_memoria_bytes", sum(memoria_processo(p) for p in pids), rotulos,
                                 ajuda="Memória residente dos processos do banco")
                inicios = [i for i in (inicio_processo(p) for p in pids) if i]
                if inicios:
                    metricas.add("nextec_banco_ligado_segundos", round(momento - min(inicios)), rotulos,
                                 ajuda="Tempo desde que o banco foi iniciado")

        bases = []
        for motor, instancias in achados.items():
            for instancia, dados in instancias.items():
                bases += [(motor, instancia, b) for b in dados["bases"]]
        if "firebird" in achados:
            bases += [("firebird", "padrao", b) for b in bases_firebird()]
        if "sqlserver" in achados:
            for padrao in PASTAS_SQLSERVER:
                bases += [("sqlserver", "MSSQLSERVER", b) for b in glob.glob(padrao)]
        for motor, padrao in self.arquivos:
            encontrados = glob.glob(padrao)
            # SQLite não tem processo: a pasta das bases é a instância, e ela
            # fica "no ar" enquanto o arquivo existir.
            instancia = os.path.dirname(padrao) or padrao if motor == "sqlite" else "padrao"
            if motor == "sqlite":
                metricas.add("nextec_banco_up", 1 if encontrados else 0, {"motor": "SQLite", "instancia": instancia})
            bases += [(motor, instancia, b) for b in encontrados]
        vistos = set()
        for motor, instancia, caminho in bases:
            chave = (motor, os.path.realpath(caminho))
            if chave in vistos:
                continue
            vistos.add(chave)
            try:
                tamanho = os.path.getsize(caminho)
            except OSError:
                continue
            metricas.add("nextec_banco_tamanho_bytes", tamanho,
                         {"motor": MOTORES_BANCO[motor], "instancia": instancia, "banco": nome_base(caminho)},
                         ajuda="Tamanho do arquivo da base")

        metricas.add("nextec_bancos_coletor_ultima_execucao_segundos", int(momento))
        gravar_atomico(self.arquivo, metricas.texto())



# ---------------------------------------------------------------------------
# Módulo virtualização
# ---------------------------------------------------------------------------
# Hipervisores no padrão nextec_hipervisor_* (host, armazenamento, cluster) e
# nextec_vm_* (cada VM ou contêiner). Fontes:
#   local     Proxmox VE (pvesh, como root, sem senha) ou KVM/libvirt (virsh)
#             no próprio servidor
#   [hipervisor:<nome>]  consulta pela rede: VMware ESXi ou vCenter (SOAP),
#             Proxmox VE (API com token) e XCP-ng (XAPI). Senha e token ficam
#             no arquivo de segredos (permissão 600), nunca no .ini.
# Snapshots e discos mudam pouco e custam uma chamada por VM: são lidos a cada
# 30 minutos e repetidos nas rodadas do meio.

ARQ_SEGREDOS_PADRAO = "/etc/coleta-complementar/segredos.ini"
PLATAFORMAS = {
    "proxmox": "Proxmox VE",
    "libvirt": "KVM/libvirt",
    "vmware": "VMware",
    "xcpng": "XCP-ng",
}
VM_LIGADA, VM_DESLIGADA, VM_PAUSADA = 1, 0, 2
INTERVALO_DETALHES = 1800


def contexto_tls(verificar):
    contexto = ssl.create_default_context()
    if not verificar:
        # Hipervisor com certificado próprio (padrão do ESXi, Proxmox e
        # XCP-ng): a conexão segue cifrada, só sem conferir quem assinou.
        contexto.check_hostname = False
        contexto.verify_mode = ssl.CERT_NONE
    return contexto


def epoch_iso(texto):
    """Data ISO 8601 (com ou sem fuso) para epoch; None se não der para ler."""
    if not texto:
        return None
    texto = str(texto).strip().replace("Z", "+00:00")
    texto = re.sub(r"(\.\d{6})\d+", r"\1", texto)
    try:
        data = datetime.fromisoformat(texto)
    except ValueError:
        # Formato básico da XAPI (20261001T10:00:00Z), sempre em UTC.
        achado = re.match(r"(\d{4})-?(\d{2})-?(\d{2})T(\d{2}):?(\d{2}):?(\d{2})", texto)
        if not achado:
            return None
        data = datetime(*(int(g) for g in achado.groups()))
    if data.tzinfo is None:
        data = data.replace(tzinfo=timezone.utc)
    return data.timestamp()


def novo_inventario():
    return {"hosts": [], "vms": [], "armazenamentos": [], "clusters": []}


def resumo_snapshots(datas):
    datas = [d for d in datas if d]
    return len(datas), (min(datas) if datas else None)


class LeitorHostLocal:
    """CPU, memória e tempo ligado do próprio servidor, para o libvirt."""

    def __init__(self):
        self._cpu_anterior = None

    def cpu_percentual(self):
        with open("/proc/stat", encoding="ascii") as arquivo:
            campos = [int(v) for v in arquivo.readline().split()[1:]]
        ocioso, total = campos[3] + (campos[4] if len(campos) > 4 else 0), sum(campos)
        anterior, self._cpu_anterior = self._cpu_anterior, (ocioso, total)
        if anterior is None or total == anterior[1]:
            return None
        return round(100.0 * (1 - (ocioso - anterior[0]) / (total - anterior[1])), 2)

    @staticmethod
    def memoria():
        valores = {}
        with open("/proc/meminfo", encoding="ascii") as arquivo:
            for linha in arquivo:
                chave, _, resto = linha.partition(":")
                valores[chave] = int(resto.split()[0]) * 1024
        total = valores.get("MemTotal", 0)
        return total - valores.get("MemAvailable", 0), total

    @staticmethod
    def ligado():
        with open("/proc/uptime", encoding="ascii") as arquivo:
            return int(float(arquivo.read().split()[0]))


class FonteProxmox:
    """Proxmox VE pelo pvesh (local, como root) ou pela API com token."""

    plataforma = "proxmox"

    def __init__(self, nome, endereco="", usuario="", token="", verificar=False):
        self.nome = nome
        self.local = not endereco
        self.endereco = endereco if ":" in endereco or not endereco else f"{endereco}:8006"
        self.usuario = usuario
        self.token = token
        self.contexto = contexto_tls(verificar)
        self._detalhes = {}
        self._ultimo_detalhe = 0.0

    def get(self, caminho):
        if self.local:
            saida = subprocess.run(["pvesh", "get", caminho, "--output-format", "json"],
                                   capture_output=True, text=True, timeout=60)
            if saida.returncode != 0:
                raise RuntimeError(f"pvesh {caminho}: {saida.stderr.strip()[:200]}")
            return json.loads(saida.stdout or "null")
        pedido = urllib.request.Request(f"https://{self.endereco}/api2/json{caminho}", headers={
            "Authorization": f"PVEAPIToken={self.usuario}={self.token}"})
        with urllib.request.urlopen(pedido, timeout=30, context=self.contexto) as resposta:
            return json.loads(resposta.read().decode("utf-8")).get("data")

    def coletar(self):
        inv = novo_inventario()
        versao = (self.get("/version") or {}).get("version", "")
        status = self.get("/cluster/status") or []
        local = next((s.get("name") for s in status if s.get("type") == "node" and s.get("local")), None)
        cluster = next((s for s in status if s.get("type") == "cluster"), None)
        if cluster:
            nos = [s for s in status if s.get("type") == "node"]
            inv["clusters"].append({"cluster": cluster.get("name", ""), "quorum": int(bool(cluster.get("quorate"))),
                                    "nos_online": sum(1 for n in nos if n.get("online")), "nos": len(nos)})
        nome_cluster = cluster.get("name", "") if cluster else ""
        recursos = self.get("/cluster/resources") or []
        # Com o agente em cada nó do cluster, cada um informa só o que é dele.
        def deste(r):
            return not self.local or local is None or r.get("node") == local

        for r in recursos:
            if not deste(r):
                continue
            tipo = r.get("type")
            if tipo == "node":
                online = r.get("status") == "online"
                inv["hosts"].append({
                    "no": r.get("node", ""), "versao": versao, "cluster": nome_cluster, "up": int(online),
                    "cpu_percentual": round(float(r.get("cpu", 0)) * 100, 2) if online else None,
                    "cpus": r.get("maxcpu"), "memoria_usada": r.get("mem"), "memoria_total": r.get("maxmem"),
                    "ligado_segundos": r.get("uptime") if online else None})
            elif tipo == "storage":
                inv["armazenamentos"].append({
                    "no": r.get("node", ""), "nome": r.get("storage", ""), "tipo": r.get("plugintype", ""),
                    "usado": r.get("disk"), "total": r.get("maxdisk"),
                    "saude": 1 if r.get("status") == "available" else 0})
            elif tipo in ("qemu", "lxc") and not r.get("template"):
                ligada = r.get("status") == "running"
                inv["vms"].append({
                    "no": r.get("node", ""), "vm": r.get("name", str(r.get("vmid"))), "id": str(r.get("vmid", "")),
                    "tipo": "VM" if tipo == "qemu" else "Contêiner", "so": "",
                    "estado": VM_LIGADA if ligada else VM_DESLIGADA,
                    "cpus": r.get("maxcpu"),
                    "cpu_percentual": round(float(r.get("cpu", 0)) * 100, 2) if ligada else None,
                    "memoria_usada": r.get("mem") if ligada else None, "memoria_total": r.get("maxmem"),
                    "disco_usado": r.get("disk") or None, "disco_total": r.get("maxdisk"),
                    "ligado_segundos": r.get("uptime") if ligada else None, "_tipo": tipo})

        if agora() - self._ultimo_detalhe >= INTERVALO_DETALHES:
            self._detalhes = self.ler_detalhes(inv)
            self._ultimo_detalhe = agora()
        for vm in inv["vms"]:
            vm["snapshots"], vm["snapshot_mais_antigo"] = self._detalhes.get(("vm", vm["id"]), (None, None))
        inv["armazenamentos"].extend(self._detalhes.get("zfs", []))
        return inv

    def ler_detalhes(self, inv):
        detalhes = {"zfs": []}
        online = {h["no"] for h in inv["hosts"] if h["up"]}
        for vm in inv["vms"]:
            if vm["no"] not in online:
                continue
            try:
                lista_snap = self.get(f"/nodes/{vm['no']}/{vm['_tipo']}/{vm['id']}/snapshot") or []
                detalhes[("vm", vm["id"])] = resumo_snapshots(
                    [s.get("snaptime") for s in lista_snap if s.get("name") != "current"])
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "snapshots não lidos", vm=vm["vm"], erro=erro)
        for host in inv["hosts"]:
            if not host["up"]:
                continue
            try:
                for pool in self.get(f"/nodes/{host['no']}/disks/zfs") or []:
                    detalhes["zfs"].append({
                        "no": host["no"], "nome": f"zfs:{pool.get('name')}", "tipo": "zfs",
                        "usado": pool.get("alloc"), "total": pool.get("size"),
                        "saude": 1 if pool.get("health") == "ONLINE" else 0})
            except (OSError, RuntimeError, ValueError):
                pass  # nó sem ZFS
        return detalhes


class FonteLibvirt:
    """KVM/libvirt local pelo virsh."""

    plataforma = "libvirt"
    ESTADOS = {1: VM_LIGADA, 2: VM_LIGADA, 3: VM_PAUSADA, 7: VM_PAUSADA}

    def __init__(self, nome, uri="qemu:///system"):
        self.nome = nome
        self.uri = uri
        self.host = LeitorHostLocal()
        self._cpu_anterior = {}
        self._detalhes = {}
        self._ultimo_detalhe = 0.0

    def virsh(self, *args):
        saida = subprocess.run(["virsh", "-c", self.uri, *args], capture_output=True, text=True, timeout=60)
        if saida.returncode != 0:
            raise RuntimeError(f"virsh {args[0]}: {saida.stderr.strip()[:200]}")
        return saida.stdout

    @staticmethod
    def ler_domstats(texto):
        dominios, atual = [], None
        for linha in texto.splitlines():
            linha = linha.strip()
            if linha.startswith("Domain:"):
                atual = {"_nome": linha.split(":", 1)[1].strip().strip("'")}
                dominios.append(atual)
            elif "=" in linha and atual is not None:
                chave, _, valor = linha.partition("=")
                atual[chave] = valor
        return dominios

    def coletar(self):
        inv = novo_inventario()
        no = socket.gethostname()
        versao = ""
        for linha in self.virsh("version").splitlines():
            if "hypervisor" in linha.lower() or "hipervisor" in linha.lower():
                versao = linha.split(":", 1)[-1].strip()
        usada, total = self.host.memoria()
        inv["hosts"].append({"no": no, "versao": versao, "cluster": "", "up": 1,
                             "cpu_percentual": self.host.cpu_percentual(), "cpus": os.cpu_count(),
                             "memoria_usada": usada, "memoria_total": total,
                             "ligado_segundos": self.host.ligado()})
        momento = time.monotonic()
        for d in self.ler_domstats(self.virsh("domstats", "--raw")):
            estado = self.ESTADOS.get(int(d.get("state.state", 5)), VM_DESLIGADA)
            vcpus = int(d.get("vcpu.maximum", d.get("vcpu.current", 0)) or 0)
            cpu_percentual = None
            if estado == VM_LIGADA and "cpu.time" in d:
                tempo = int(d["cpu.time"])
                anterior = self._cpu_anterior.get(d["_nome"])
                self._cpu_anterior[d["_nome"]] = (tempo, momento)
                if anterior and momento > anterior[1] and vcpus:
                    cpu_percentual = round(100.0 * (tempo - anterior[0]) / ((momento - anterior[1]) * 1e9 * vcpus), 2)
            blocos = range(int(d.get("block.count", 0)))
            inv["vms"].append({
                "no": no, "vm": d["_nome"], "id": d["_nome"], "tipo": "VM", "so": "", "estado": estado,
                "cpus": vcpus or None, "cpu_percentual": cpu_percentual,
                "memoria_usada": int(d["balloon.rss"]) * 1024 if estado == VM_LIGADA and "balloon.rss" in d else None,
                "memoria_total": int(d["balloon.maximum"]) * 1024 if "balloon.maximum" in d else None,
                "disco_usado": sum(int(d.get(f"block.{i}.physical", 0)) for i in blocos) or None,
                "disco_total": sum(int(d.get(f"block.{i}.capacity", 0)) for i in blocos) or None,
                "ligado_segundos": None})
        if agora() - self._ultimo_detalhe >= INTERVALO_DETALHES:
            self._detalhes = self.ler_detalhes(inv)
            self._ultimo_detalhe = agora()
        for vm in inv["vms"]:
            vm["snapshots"], vm["snapshot_mais_antigo"] = self._detalhes.get(vm["vm"], (None, None))
        inv["armazenamentos"] = self._detalhes.get("_pools", [])
        return inv

    def ler_detalhes(self, inv):
        detalhes = {"_pools": []}
        for vm in inv["vms"]:
            try:
                datas = []
                for linha in self.virsh("snapshot-list", vm["vm"]).splitlines()[2:]:
                    achado = re.search(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ?([+-]\d{4})?", linha)
                    if achado:
                        fuso = achado.group(2) or "+0000"
                        datas.append(datetime.strptime(f"{achado.group(1)} {fuso}", "%Y-%m-%d %H:%M:%S %z").timestamp())
                detalhes[vm["vm"]] = resumo_snapshots(datas)
            except (OSError, RuntimeError, ValueError) as erro:
                log("aviso", "snapshots não lidos", vm=vm["vm"], erro=erro)
        no = inv["hosts"][0]["no"]
        for pool in [p for p in self.virsh("pool-list", "--all", "--name").splitlines() if p.strip()]:
            try:
                info = {}
                for linha in self.virsh("pool-info", pool.strip(), "--bytes").splitlines():
                    chave, _, valor = linha.partition(":")
                    info[chave.strip().lower()] = valor.strip()
                detalhes["_pools"].append({
                    "no": no, "nome": pool.strip(), "tipo": "libvirt",
                    "usado": int(info.get("allocation", "0").split()[0]),
                    "total": int(info.get("capacity", "0").split()[0]),
                    "saude": 1 if info.get("state") == "running" else 0})
            except (OSError, RuntimeError, ValueError):
                pass
        return detalhes


class FonteVMware:
    """VMware ESXi ou vCenter pela API SOAP (vim25), com usuário só leitura."""

    plataforma = "vmware"
    NS = {"s": "http://schemas.xmlsoap.org/soap/envelope/", "v": "urn:vim25"}
    PROPRIEDADES = {
        "HostSystem": ["name", "runtime.connectionState", "summary.quickStats.overallCpuUsage",
                       "summary.quickStats.overallMemoryUsage", "summary.quickStats.uptime",
                       "summary.hardware.cpuMhz", "summary.hardware.numCpuCores", "summary.hardware.numCpuThreads",
                       "summary.hardware.memorySize", "summary.config.product.fullName", "parent"],
        "VirtualMachine": ["name", "config.template", "config.uuid", "runtime.powerState", "runtime.host",
                           "summary.config.numCpu", "summary.config.memorySizeMB", "summary.config.guestFullName",
                           "summary.quickStats.overallCpuUsage", "summary.runtime.maxCpuUsage",
                           "summary.quickStats.guestMemoryUsage", "summary.quickStats.uptimeSeconds",
                           "summary.storage.committed", "summary.storage.uncommitted", "snapshot"],
        "Datastore": ["summary.name", "summary.type", "summary.capacity", "summary.freeSpace",
                      "summary.accessible", "host"],
        "ClusterComputeResource": ["name"],
    }

    def __init__(self, nome, endereco, usuario, senha, verificar=False):
        self.nome = nome
        self.url = f"https://{endereco}/sdk"
        self.usuario = usuario
        self.senha = senha
        self.contexto = contexto_tls(verificar)
        self.cookie = None
        self.versao_api = ""

    def chamar(self, corpo):
        envelope = ('<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope '
                    'xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" '
                    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:urn="urn:vim25">'
                    f'<soapenv:Body>{corpo}</soapenv:Body></soapenv:Envelope>')
        cabecalhos = {"Content-Type": "text/xml; charset=utf-8",
                      "SOAPAction": f"urn:vim25/{self.versao_api}" if self.versao_api else "urn:vim25"}
        if self.cookie:
            cabecalhos["Cookie"] = self.cookie
        pedido = urllib.request.Request(self.url, data=envelope.encode("utf-8"), headers=cabecalhos)
        try:
            with urllib.request.urlopen(pedido, timeout=60, context=self.contexto) as resposta:
                cookie = resposta.headers.get("Set-Cookie")
                if cookie:
                    self.cookie = cookie.split(";", 1)[0]
                return ET.fromstring(resposta.read())
        except urllib.error.HTTPError as erro:
            texto = erro.read().decode("utf-8", "replace")
            achado = re.search(r"<faultstring>(.*?)</faultstring>", texto, re.S)
            raise RuntimeError(f"VMware: {achado.group(1).strip() if achado else erro}") from None

    def coletar(self):
        self.cookie = None
        self.versao_api = ""
        conteudo = self.chamar('<urn:RetrieveServiceContent><urn:_this type="ServiceInstance">ServiceInstance'
                               '</urn:_this></urn:RetrieveServiceContent>').find(".//v:returnval", self.NS)
        texto = lambda caminho: (conteudo.findtext(caminho, "", self.NS) or "").strip()
        self.versao_api = texto("v:about/v:apiVersion")
        produto = texto("v:about/v:fullName")
        self.chamar(f'<urn:Login><urn:_this type="SessionManager">{texto("v:sessionManager")}</urn:_this>'
                    f'<urn:userName>{xml_escape(self.usuario)}</urn:userName>'
                    f'<urn:password>{xml_escape(self.senha)}</urn:password></urn:Login>')
        try:
            vista = self.chamar(
                f'<urn:CreateContainerView><urn:_this type="ViewManager">{texto("v:viewManager")}</urn:_this>'
                f'<urn:container type="Folder">{texto("v:rootFolder")}</urn:container>'
                + "".join(f"<urn:type>{t}</urn:type>" for t in self.PROPRIEDADES)
                + '<urn:recursive>true</urn:recursive></urn:CreateContainerView>').findtext(".//v:returnval", "", self.NS)
            objetos = self.ler_objetos(texto("v:propertyCollector"), vista)
            return self.montar(objetos, produto)
        finally:
            try:
                self.chamar(f'<urn:Logout><urn:_this type="SessionManager">{texto("v:sessionManager")}'
                            '</urn:_this></urn:Logout>')
            except (OSError, RuntimeError):
                pass

    def ler_objetos(self, coletor, vista):
        conjuntos = "".join(f"<urn:propSet><urn:type>{t}</urn:type>"
                            + "".join(f"<urn:pathSet>{p}</urn:pathSet>" for p in props) + "</urn:propSet>"
                            for t, props in self.PROPRIEDADES.items())
        corpo = (f'<urn:RetrievePropertiesEx><urn:_this type="PropertyCollector">{coletor}</urn:_this>'
                 f'<urn:specSet>{conjuntos}<urn:objectSet><urn:obj type="ContainerView">{vista}</urn:obj>'
                 '<urn:skip>true</urn:skip><urn:selectSet xsi:type="urn:TraversalSpec"><urn:name>vista</urn:name>'
                 '<urn:type>ContainerView</urn:type><urn:path>view</urn:path><urn:skip>false</urn:skip>'
                 '</urn:selectSet></urn:objectSet></urn:specSet><urn:options><urn:maxObjects>500</urn:maxObjects>'
                 '</urn:options></urn:RetrievePropertiesEx>')
        objetos = []
        resposta = self.chamar(corpo)
        while True:
            retorno = resposta.find(".//v:returnval", self.NS)
            if retorno is None:
                break
            for obj in retorno.findall("v:objects", self.NS):
                ref = obj.find("v:obj", self.NS)
                item = {"_tipo": ref.get("type"), "_id": (ref.text or "").strip()}
                for prop in obj.findall("v:propSet", self.NS):
                    item[prop.findtext("v:name", "", self.NS)] = prop.find("v:val", self.NS)
                objetos.append(item)
            ficha = retorno.findtext("v:token", "", self.NS)
            if not ficha:
                break
            resposta = self.chamar(f'<urn:ContinueRetrievePropertiesEx><urn:_this type="PropertyCollector">'
                                   f'{coletor}</urn:_this><urn:token>{ficha}</urn:token></urn:ContinueRetrievePropertiesEx>')
        return objetos

    @staticmethod
    def valor(item, chave, conversor=str):
        elemento = item.get(chave)
        if elemento is None or elemento.text is None:
            return None
        try:
            return conversor(elemento.text.strip())
        except ValueError:
            return None

    def montar(self, objetos, produto):
        inv = novo_inventario()
        hosts = {o["_id"]: o for o in objetos if o["_tipo"] == "HostSystem"}
        clusters = {o["_id"]: self.valor(o, "name") for o in objetos if o["_tipo"] == "ClusterComputeResource"}
        nomes_host = {i: self.valor(h, "name") or i for i, h in hosts.items()}
        for i, h in hosts.items():
            conectado = self.valor(h, "runtime.connectionState") == "connected"
            mhz, nucleos = self.valor(h, "summary.hardware.cpuMhz", int), self.valor(h, "summary.hardware.numCpuCores", int)
            uso = self.valor(h, "summary.quickStats.overallCpuUsage", int)
            memoria_mb = self.valor(h, "summary.quickStats.overallMemoryUsage", int)
            inv["hosts"].append({
                "no": nomes_host[i], "versao": self.valor(h, "summary.config.product.fullName") or produto,
                "cluster": clusters.get(self.valor(h, "parent") or "", "") or "", "up": int(conectado),
                "cpu_percentual": round(100.0 * uso / (mhz * nucleos), 2) if conectado and uso is not None and mhz and nucleos else None,
                "cpus": self.valor(h, "summary.hardware.numCpuThreads", int),
                "memoria_usada": memoria_mb * 1024 * 1024 if conectado and memoria_mb is not None else None,
                "memoria_total": self.valor(h, "summary.hardware.memorySize", int),
                "ligado_segundos": self.valor(h, "summary.quickStats.uptime", int) if conectado else None})
        unico = next(iter(nomes_host.values())) if len(nomes_host) == 1 else ""
        for o in objetos:
            if o["_tipo"] == "Datastore":
                total, livre = self.valor(o, "summary.capacity", int), self.valor(o, "summary.freeSpace", int)
                inv["armazenamentos"].append({
                    "no": unico, "nome": self.valor(o, "summary.name") or o["_id"], "tipo": self.valor(o, "summary.type") or "",
                    "usado": total - livre if total is not None and livre is not None else None, "total": total,
                    "saude": 1 if self.valor(o, "summary.accessible") == "true" else 0})
            elif o["_tipo"] == "VirtualMachine" and self.valor(o, "config.template") != "true":
                estado = {"poweredOn": VM_LIGADA, "suspended": VM_PAUSADA}.get(self.valor(o, "runtime.powerState"), VM_DESLIGADA)
                ligada = estado == VM_LIGADA
                uso, maximo = self.valor(o, "summary.quickStats.overallCpuUsage", int), self.valor(o, "summary.runtime.maxCpuUsage", int)
                memoria_mb = self.valor(o, "summary.config.memorySizeMB", int)
                convidado_mb = self.valor(o, "summary.quickStats.guestMemoryUsage", int)
                usado = self.valor(o, "summary.storage.committed", int)
                livre = self.valor(o, "summary.storage.uncommitted", int)
                snapshot = o.get("snapshot")
                datas = [epoch_iso(e.text) for e in snapshot.iter("{urn:vim25}createTime")] if snapshot is not None else []
                quantidade, antigo = resumo_snapshots(datas)
                inv["vms"].append({
                    "no": nomes_host.get(self.valor(o, "runtime.host") or "", ""), "vm": self.valor(o, "name") or o["_id"],
                    "id": o["_id"], "tipo": "VM", "so": self.valor(o, "summary.config.guestFullName") or "", "estado": estado,
                    "cpus": self.valor(o, "summary.config.numCpu", int),
                    "cpu_percentual": round(100.0 * uso / maximo, 2) if ligada and uso is not None and maximo else None,
                    "memoria_usada": convidado_mb * 1024 * 1024 if ligada and convidado_mb is not None else None,
                    "memoria_total": memoria_mb * 1024 * 1024 if memoria_mb is not None else None,
                    "disco_usado": usado, "disco_total": (usado or 0) + (livre or 0) or None,
                    "ligado_segundos": self.valor(o, "summary.quickStats.uptimeSeconds", int) if ligada else None,
                    "snapshots": quantidade, "snapshot_mais_antigo": antigo})
        return inv


class FonteXcp:
    """XCP-ng (e Citrix Hypervisor) pela XAPI, em XML-RPC."""

    plataforma = "xcpng"

    def __init__(self, nome, endereco, usuario, senha, verificar=False):
        self.nome = nome
        self.servidor = xmlrpc.client.ServerProxy(f"https://{endereco}", context=contexto_tls(verificar),
                                                  allow_none=True)
        self.usuario = usuario
        self.senha = senha

    @staticmethod
    def valor(resposta):
        if resposta.get("Status") != "Success":
            raise RuntimeError(f"XAPI: {resposta.get('ErrorDescription')}")
        return resposta["Value"]

    def coletar(self):
        x = self.servidor
        sessao = self.valor(x.session.login_with_password(self.usuario, self.senha, "1.0", "nextec-coleta"))
        try:
            return self.montar(sessao)
        finally:
            try:
                x.session.logout(sessao)
            except (OSError, xmlrpc.client.Error):
                pass

    def montar(self, s):
        x = self.servidor
        todos = lambda classe: self.valor(getattr(x, classe).get_all_records(s))
        inv = novo_inventario()
        pools = todos("pool")
        nome_pool = next(iter(pools.values()), {}).get("name_label", "") if pools else ""
        metricas_host, cpus_host = todos("host_metrics"), todos("host_cpu")
        hosts = todos("host")
        nomes = {ref: h.get("name_label", ref) for ref, h in hosts.items()}
        for ref, h in hosts.items():
            m = metricas_host.get(h.get("metrics"), {})
            vivo = bool(m.get("live", True))
            uso = [float(c.get("utilisation", 0)) for c in cpus_host.values() if c.get("host") == ref]
            total = int(m.get("memory_total", 0) or 0)
            inv["hosts"].append({
                "no": nomes[ref], "versao": "XCP-ng " + h.get("software_version", {}).get("product_version", ""),
                "cluster": nome_pool, "up": int(vivo),
                "cpu_percentual": round(100.0 * sum(uso) / len(uso), 2) if uso and vivo else None,
                "cpus": len(uso) or None, "memoria_usada": total - int(m.get("memory_free", 0) or 0) if total else None,
                "memoria_total": total or None, "ligado_segundos": None})
        vdis, vbds = todos("VDI"), todos("VBD")
        metricas_vm, convidado = todos("VM_metrics"), todos("VM_guest_metrics")
        vms = todos("VM")
        snapshots = {}
        for v in vms.values():
            if v.get("is_a_snapshot"):
                snapshots.setdefault(v.get("snapshot_of"), []).append(epoch_iso(str(v.get("snapshot_time"))))
        for ref, v in vms.items():
            if v.get("is_a_template") or v.get("is_control_domain") or v.get("is_a_snapshot"):
                continue
            estado = {"Running": VM_LIGADA, "Paused": VM_PAUSADA, "Suspended": VM_PAUSADA}.get(v.get("power_state"), VM_DESLIGADA)
            ligada = estado == VM_LIGADA
            m = metricas_vm.get(v.get("metrics"), {})
            discos = [vdis.get(vbds[b].get("VDI"), {}) for b in v.get("VBDs", []) if b in vbds and vbds[b].get("type") == "Disk"]
            inicio = epoch_iso(str(m.get("start_time", ""))) if ligada else None
            quantidade, antigo = resumo_snapshots(snapshots.get(ref, []))
            inv["vms"].append({
                "no": nomes.get(v.get("resident_on"), "") if ligada else "", "vm": v.get("name_label", ref),
                "id": v.get("uuid", ref), "tipo": "VM",
                "so": convidado.get(v.get("guest_metrics"), {}).get("os_version", {}).get("name", "").split("|")[0],
                "estado": estado, "cpus": int(v.get("VCPUs_at_startup", 0) or 0) or None, "cpu_percentual": None,
                "memoria_usada": (int(m.get("memory_actual", 0) or 0) or None) if ligada else None,
                "memoria_total": int(v.get("memory_static_max", 0) or 0) or None,
                "disco_usado": sum(int(d.get("physical_utilisation", 0) or 0) for d in discos) or None,
                "disco_total": sum(int(d.get("virtual_size", 0) or 0) for d in discos) or None,
                "ligado_segundos": round(agora() - inicio) if inicio and inicio > 0 else None,
                "snapshots": quantidade, "snapshot_mais_antigo": antigo})
        for sr in todos("SR").values():
            if sr.get("type") in ("iso", "udev") or not int(sr.get("physical_size", 0) or 0):
                continue
            inv["armazenamentos"].append({
                "no": "", "nome": sr.get("name_label", ""), "tipo": sr.get("type", ""),
                "usado": int(sr.get("physical_utilisation", 0) or 0), "total": int(sr.get("physical_size", 0) or 0),
                "saude": None})
        return inv


def gravar_inventario(metricas, fonte, inv):
    base = {"plataforma": PLATAFORMAS[fonte.plataforma], "hipervisor": fonte.nome}
    for c in inv["clusters"]:
        rotulos = {**base, "cluster": c["cluster"]}
        metricas.add("nextec_hipervisor_cluster_quorum", c["quorum"], rotulos, ajuda="1 com quórum")
        metricas.add("nextec_hipervisor_cluster_nos_online", c["nos_online"], rotulos)
        metricas.add("nextec_hipervisor_cluster_nos", c["nos"], rotulos)
    for h in inv["hosts"]:
        rotulos = {**base, "no": h["no"]}
        metricas.add("nextec_hipervisor_info", 1, {**rotulos, "versao": h["versao"], "cluster": h["cluster"]})
        metricas.add("nextec_hipervisor_host_up", h["up"], rotulos, ajuda="1 com o host conectado")
        metricas.add("nextec_hipervisor_cpu_percentual", h["cpu_percentual"], rotulos)
        metricas.add("nextec_hipervisor_cpus", h["cpus"], rotulos)
        metricas.add("nextec_hipervisor_memoria_usada_bytes", h["memoria_usada"], rotulos)
        metricas.add("nextec_hipervisor_memoria_total_bytes", h["memoria_total"], rotulos)
        metricas.add("nextec_hipervisor_ligado_segundos", h["ligado_segundos"], rotulos)
    for a in inv["armazenamentos"]:
        rotulos = {**base, "no": a["no"], "armazenamento": a["nome"], "tipo": a["tipo"]}
        metricas.add("nextec_hipervisor_armazenamento_usado_bytes", a["usado"], rotulos)
        metricas.add("nextec_hipervisor_armazenamento_total_bytes", a["total"], rotulos)
        metricas.add("nextec_hipervisor_armazenamento_saude", a["saude"], rotulos, ajuda="1 normal, 0 com falha")
    for v in inv["vms"]:
        rotulos = {**base, "no": v["no"], "vm": v["vm"], "vmid": v["id"]}
        metricas.add("nextec_vm_info", 1, {**rotulos, "tipo": v["tipo"], "so": v["so"]})
        metricas.add("nextec_vm_estado", v["estado"], rotulos, ajuda="1 ligada, 0 desligada, 2 pausada ou suspensa")
        metricas.add("nextec_vm_cpus", v["cpus"], rotulos)
        metricas.add("nextec_vm_cpu_percentual", v["cpu_percentual"], rotulos)
        metricas.add("nextec_vm_memoria_usada_bytes", v["memoria_usada"], rotulos)
        metricas.add("nextec_vm_memoria_total_bytes", v["memoria_total"], rotulos)
        metricas.add("nextec_vm_disco_usado_bytes", v["disco_usado"], rotulos)
        metricas.add("nextec_vm_disco_total_bytes", v["disco_total"], rotulos)
        metricas.add("nextec_vm_ligado_segundos", v["ligado_segundos"], rotulos)
        metricas.add("nextec_vm_snapshots", v.get("snapshots"), rotulos)
        if v.get("snapshot_mais_antigo"):
            metricas.add("nextec_vm_snapshot_mais_antigo_segundos", round(v["snapshot_mais_antigo"]), rotulos)


def detectar_virtualizacao_local():
    """proxmox, libvirt ou vazio, conforme o que roda neste servidor."""
    if os.path.isdir("/etc/pve") and shutil.which("pvesh"):
        return "proxmox"
    if shutil.which("virsh") and os.path.exists("/var/run/libvirt/libvirt-sock"):
        return "libvirt"
    return ""


def ler_segredos(config):
    geral = config["geral"] if config.has_section("geral") else {}
    caminho = geral.get("arquivo_segredos", ARQ_SEGREDOS_PADRAO)
    segredos = configparser.ConfigParser(interpolation=None)
    segredos.optionxform = str
    if os.path.exists(caminho):
        segredos.read(caminho, encoding="utf-8")
    return segredos


def fontes_virtualizacao(config):
    secao = config["virtualizacao"] if config.has_section("virtualizacao") else {}
    fontes = []
    local = (secao.get("local", "auto") or "").strip().lower()
    if local == "auto":
        local = detectar_virtualizacao_local()
    nome_local = socket.gethostname()
    if local == "proxmox":
        fontes.append(FonteProxmox(nome_local))
    elif local == "libvirt":
        fontes.append(FonteLibvirt(nome_local, secao.get("libvirt_uri", "qemu:///system")))
    segredos = ler_segredos(config)
    for nome_secao in config.sections():
        if not nome_secao.lower().startswith("hipervisor:"):
            continue
        dados = config[nome_secao]
        nome = nome_secao.split(":", 1)[1].strip()
        segredo = segredos[nome_secao] if segredos.has_section(nome_secao) else {}
        tipo = dados.get("tipo", "").strip().lower()
        endereco, usuario = dados.get("endereco", "").strip(), dados.get("usuario", "").strip()
        verificar = sim(dados.get("verificar_certificado"), False)
        if tipo == "vmware":
            fontes.append(FonteVMware(nome, endereco, usuario, segredo.get("senha", ""), verificar))
        elif tipo == "proxmox":
            fontes.append(FonteProxmox(nome, endereco, usuario, segredo.get("token", ""), verificar))
        elif tipo in ("xcpng", "xcp-ng", "xenserver"):
            fontes.append(FonteXcp(nome, endereco, usuario, segredo.get("senha", ""), verificar))
        else:
            log("aviso", "hipervisor com tipo desconhecido", secao=nome_secao, tipo=tipo)
    return fontes


class ModuloVirtualizacao:
    nome = "virtualizacao"

    def __init__(self, config, eventos, estado, dir_textfile):
        secao = config["virtualizacao"] if config.has_section("virtualizacao") else {}
        self.intervalo = max(60, int(secao.get("intervalo_segundos", "120")))
        self.fontes = fontes_virtualizacao(config)
        self.arquivo = os.path.join(dir_textfile, "coleta_complementar_virtualizacao.prom")

    def rodada(self):
        metricas = Metricas()
        falhas = 0
        for fonte in self.fontes:
            rotulos = {"plataforma": PLATAFORMAS[fonte.plataforma], "hipervisor": fonte.nome}
            inicio = agora()
            try:
                inv = fonte.coletar()
                gravar_inventario(metricas, fonte, inv)
                metricas.add("nextec_hipervisor_up", 1, rotulos, ajuda="1 com a consulta ao hipervisor funcionando")
            except Exception as erro:  # uma fonte fora não apaga as outras
                falhas += 1
                metricas.add("nextec_hipervisor_up", 0, rotulos)
                log("erro", "consulta ao hipervisor falhou", hipervisor=fonte.nome, erro=str(erro)[:300])
            metricas.add("nextec_hipervisor_coleta_duracao_segundos", round(agora() - inicio, 2), rotulos)
        metricas.add("nextec_hipervisor_coletor_ultima_execucao_segundos", round(agora()))
        gravar_atomico(self.arquivo, metricas.texto())
        if self.fontes and falhas == len(self.fontes):
            raise RuntimeError("nenhum hipervisor respondeu")


MODULOS = {"internet": ModuloLinks, "docker": ModuloDocker, "velocidade": ModuloVelocidade,
           "acessos": ModuloAcessos, "bancos": ModuloBancos, "virtualizacao": ModuloVirtualizacao}


def carregar_config():
    caminho = os.environ.get("COLETA_COMPLEMENTAR_CONFIG", CONFIG_PADRAO)
    config = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";", "#"))
    config.optionxform = str
    if not config.read(caminho, encoding="utf-8"):
        raise SystemExit(f"Configuração não encontrada: {caminho}")
    return config, caminho


def modulos_ligados(config):
    internet = config["internet"] if config.has_section("internet") else {}
    tem_links = any(s.lower().startswith("link:") for s in config.sections())
    ligados = ["internet"] if sim(internet.get("ativo"), True) or tem_links else []
    if config.has_section("docker") and sim(config["docker"].get("ativo"), False):
        ligados.append("docker")
    if config.has_section("velocidade") and sim(config["velocidade"].get("ativo"), False):
        ligados.append("velocidade")
    if config.has_section("acessos") and sim(config["acessos"].get("ativo"), False):
        ligados.append("acessos")
    if config.has_section("bancos") and sim(config["bancos"].get("ativo"), False):
        ligados.append("bancos")
    if config.has_section("virtualizacao") and sim(config["virtualizacao"].get("ativo"), False):
        ligados.append("virtualizacao")
    return ligados


def preparar(config):
    geral = config["geral"] if config.has_section("geral") else {}
    dir_dados = geral.get("pasta_dados", DIR_DADOS_PADRAO)
    dir_textfile = geral.get("pasta_textfile", os.path.join(dir_dados, "textfile"))
    arq_eventos = geral.get("arquivo_eventos", ARQ_EVENTOS_PADRAO)
    os.makedirs(dir_textfile, exist_ok=True)
    eventos = Eventos(arq_eventos)
    estado = Estado(os.path.join(dir_dados, "estado.json"))
    return dir_textfile, eventos, estado


def gravar_saude(dir_textfile, ligados, saude):
    metricas = Metricas()
    metricas.add("nextec_coleta_complementar_info", 1, {"versao": VERSAO, "modulos": ",".join(ligados)})
    for nome in ligados:
        metricas.add("nextec_coleta_complementar_modulo_ok", 1 if saude.get(nome, True) else 0, {"modulo": nome})
    gravar_atomico(os.path.join(dir_textfile, "coleta_complementar.prom"), metricas.texto())


def laco(modulo, intervalo, parar, saude, aviso_saude):
    while not parar.is_set():
        inicio = agora()
        try:
            modulo.rodada()
            saude[modulo.nome] = True
        except Exception as erro:  # um módulo com erro não derruba os outros
            saude[modulo.nome] = False
            log("erro", "rodada do módulo falhou", modulo=modulo.nome, erro=repr(erro))
        aviso_saude()
        parar.wait(max(1.0, intervalo - (agora() - inicio)))


def executar():
    config, caminho = carregar_config()
    dir_textfile, eventos, estado = preparar(config)
    ligados = modulos_ligados(config)
    parar = threading.Event()
    saude = {}

    def aviso_saude():
        gravar_saude(dir_textfile, ligados, saude)

    log("info", "Coleta Complementar iniciada", versao=VERSAO, modulos=",".join(ligados), config=caminho)
    eventos.registrar("links_evento", "sistema", "coletor_iniciado", "info",
                      detalhe=f"Coleta Complementar {VERSAO}: {', '.join(ligados)}")

    threads = []
    for nome in ligados:
        modulo = MODULOS[nome](config, eventos, estado, dir_textfile)
        thread = threading.Thread(target=laco, args=(modulo, modulo.intervalo, parar, saude, aviso_saude),
                                  name=nome, daemon=True)
        threads.append(thread)
        if nome == "docker":
            threads.append(threading.Thread(target=modulo.acompanhar_eventos, args=(parar,),
                                            name="docker-eventos", daemon=True))
        if nome == "acessos":
            threads.append(threading.Thread(target=modulo.acompanhar, args=(parar,),
                                            name="acessos-journal", daemon=True))
    for thread in threads:
        thread.start()
    try:
        while True:
            time.sleep(60)
            for thread in threads:
                if not thread.is_alive():
                    log("erro", "thread parou inesperadamente; o serviço será reiniciado", thread=thread.name)
                    raise SystemExit(1)
    except KeyboardInterrupt:
        parar.set()


def uma_vez(nome=None):
    config, _ = carregar_config()
    dir_textfile, eventos, estado = preparar(config)
    ligados = [nome] if nome else modulos_ligados(config)
    for item in ligados:
        if item not in MODULOS:
            raise SystemExit(f"Módulo desconhecido: {item}. Opções: {', '.join(MODULOS)}")
        MODULOS[item](config, eventos, estado, dir_textfile).rodada()
        print(f"[{item}] rodada concluída")
    gravar_saude(dir_textfile, ligados, {})
    for arquivo in sorted(os.listdir(dir_textfile)):
        if arquivo.endswith(".prom"):
            print(f"--- {arquivo}")
            with open(os.path.join(dir_textfile, arquivo), encoding="utf-8") as conteudo:
                print(conteudo.read())


def verificar():
    problemas = []
    config, caminho = carregar_config()
    print(f"Configuração: {caminho}")
    ligados = modulos_ligados(config)
    print(f"Módulos ligados: {', '.join(ligados)}")
    if not shutil.which("ping"):
        problemas.append("comando ping não encontrado (pacote iputils-ping)")
    if not (shutil.which("traceroute") or shutil.which("tracepath")):
        problemas.append("traceroute/tracepath ausente: a rota na queda não será registrada")
    links = [s for s in config.sections() if s.lower().startswith("link:")]
    for secao in links:
        if not lista(config[secao].get("alvos", "")):
            problemas.append(f"[{secao}] sem alvos: o link nunca terá status")
    print(f"Links configurados: {len(links)}")
    if "docker" in ligados:
        socket_docker = config["docker"].get("socket", "/var/run/docker.sock")
        try:
            versao = ApiDocker(socket_docker).get("/version", timeout=5).get("Version")
            print(f"Docker: versão {versao}")
        except (OSError, RuntimeError, ValueError) as erro:
            problemas.append(f"Docker inacessível em {socket_docker}: {erro}")
    if "acessos" in ligados and not shutil.which("journalctl"):
        problemas.append("journalctl não encontrado: o módulo acessos não registra logins")
    if "velocidade" in ligados:
        modulo = ModuloVelocidade(config, None, None, "/tmp")
        if not os.path.exists(modulo.binario):
            problemas.append(f"Speedtest CLI não encontrado em {modulo.binario}")
    if "virtualizacao" in ligados:
        for fonte in fontes_virtualizacao(config):
            try:
                inv = fonte.coletar()
                print(f"Hipervisor {fonte.nome} ({PLATAFORMAS[fonte.plataforma]}): "
                      f"{len(inv['hosts'])} host(s), {len(inv['vms'])} VM(s), {len(inv['armazenamentos'])} armazenamento(s)")
            except Exception as erro:  # noqa: BLE001 - o motivo vai para o técnico
                problemas.append(f"hipervisor {fonte.nome} ({PLATAFORMAS[fonte.plataforma]}) sem resposta: {erro}")
    for problema in problemas:
        print(f"PROBLEMA: {problema}")
    if not problemas:
        print("Tudo certo.")
    return 1 if problemas else 0


def main():
    acao = sys.argv[1] if len(sys.argv) > 1 else "executar"
    if acao == "executar":
        executar()
    elif acao == "uma-vez":
        uma_vez(sys.argv[2] if len(sys.argv) > 2 else None)
    elif acao == "verificar":
        sys.exit(verificar())
    elif acao in ("versao", "--version"):
        print(VERSAO)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
