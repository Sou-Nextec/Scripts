#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Atualizador Nextec (Linux)

Mantém o monitoramento Nextec deste servidor na versão publicada pela Nextec,
sem ninguém precisar entrar na máquina.

Como funciona, a cada execução (timer do systemd, de madrugada):
  1. Baixa o manifesto publicado e a assinatura dele, por HTTPS.
  2. Confere a assinatura RSA com as chaves públicas gravadas NESTE arquivo.
     Manifesto sem assinatura válida é descartado: nem o GitHub nem o
     servidor da Nextec conseguem mandar nada sem a chave privada, que fica
     fora de qualquer servidor.
  3. Recusa manifesto vencido e manifesto com sequência menor que a última
     aceita (impede reenviar uma versão antiga e vulnerável).
  4. Respeita a pausa geral e a onda deste servidor (0, 1 ou 2).
  5. Baixa cada arquivo da versão e confere o SHA-256 listado no manifesto.
  6. Guarda uma cópia do que está instalado, roda o instalador em modo
     --atualizar (sem perguntas, com as respostas gravadas na instalação) e
     confere a saúde do Alloy. Se não ficar saudável, volta tudo como estava.
  7. Grava métricas para o NOC (versão, onda, resultado) e um evento por
     atualização.

Não aceita comando avulso: só aplica o que veio num manifesto assinado.

Uso:
  nextec-atualizador.py executar     execução normal (a do timer)
  nextec-atualizador.py verificar    mostra a situação sem alterar nada
  nextec-atualizador.py versao
"""

import base64
import configparser
import datetime
import hashlib
import hmac
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

VERSAO = "1.0.0"

# ---------------------------------------------------------------------------
# Chaves públicas confiáveis (RSA, módulo em hexadecimal).
# Preenchidas pelo publicar-versao.py ("gerar-chave"). Para trocar a chave,
# publique uma versão assinada pela chave atual que já traga a chave nova.
# ---------------------------------------------------------------------------
CHAVES_CONFIAVEIS = [
]

MANIFESTO_URL_PADRAO = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/atualizador/manifesto.json"

CONFIG = "/etc/nextec/atualizador.conf"
INSTALACAO = "/etc/nextec/instalacao.conf"
DADOS = "/var/lib/nextec-atualizador"
ESTADO = os.path.join(DADOS, "estado.json")
TRAVA = os.path.join(DADOS, "trava")
STAGING = os.path.join(DADOS, "staging")
BACKUPS = os.path.join(DADOS, "backup")
LOG_DIR = "/var/log/nextec"
LOG_INSTALADOR = os.path.join(LOG_DIR, "atualizador-instalador.log")
TEXTFILE = "/var/lib/coleta-complementar/textfile/atualizador.prom"
EVENTOS = "/var/log/coleta-complementar/eventos.jsonl"
ALLOY_READY = "http://127.0.0.1:12345/-/ready"

# O que a volta automática restaura. Credenciais incluídas: a cópia fica em
# pasta só do root e é apagada depois de cada atualização bem-sucedida.
CAMINHOS_BACKUP = [
    "/etc/alloy",
    "/etc/default/alloy",
    "/etc/systemd/system/alloy.service.d",
    "/etc/coleta-complementar",
    "/etc/systemd/system/coleta-complementar.service",
    "/usr/local/lib/nextec",
    "/etc/nextec",
    "/etc/systemd/system/nextec-atualizador.service",
    "/etc/systemd/system/nextec-atualizador.timer",
    # Só existem quando o Alloy foi instalado pelo binário (sem pacote).
    "/usr/local/bin/alloy",
    "/etc/systemd/system/alloy.service",
]

FORMATO_MANIFESTO = 1
TAMANHO_MINIMO_CHAVE = 3072
LIMITE_MANIFESTO = 1024 * 1024
LIMITE_ARQUIVO = 50 * 1024 * 1024
TEMPO_INSTALADOR = 1800
TEMPO_SAUDE = 180
ARQUIVOS_LINUX = ("instalador", "coleta", "atualizador")
RE_VERSAO = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{0,40}")
RE_SHA256 = re.compile(r"[0-9a-f]{64}")
RE_ALLOY = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
ARQUITETURAS = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}

# DigestInfo DER do SHA-256 (RFC 8017, seção 9.2): prefixo fixo do bloco
# assinado em RSASSA-PKCS1-v1_5.
DIGESTINFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")


class Recusa(Exception):
    """Situação conhecida que encerra a execução com um resultado nomeado."""

    def __init__(self, resultado, detalhe, nivel="aviso"):
        super().__init__(detalhe)
        self.resultado = resultado
        self.detalhe = detalhe
        self.nivel = nivel


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def agora():
    return datetime.datetime.now(datetime.timezone.utc)


def log(nivel, msg, **campos):
    extras = " ".join('{}="{}"'.format(k, str(v).replace('"', "'")) for k, v in campos.items())
    print('nivel={} msg="{}" {}'.format(nivel, msg, extras).rstrip(), flush=True)


def ler_data(texto, campo):
    """Lê data ISO 8601 em UTC no formato AAAA-MM-DDTHH:MM:SSZ."""
    if not isinstance(texto, str):
        raise Recusa("manifesto_invalido", "campo {} sem data".format(campo), "erro")
    try:
        return datetime.datetime.strptime(texto, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise Recusa("manifesto_invalido", "data inválida em {}: {}".format(campo, texto), "erro")


def gravar_atomico(caminho, conteudo, modo=0o600):
    pasta = os.path.dirname(caminho)
    os.makedirs(pasta, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=pasta, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(conteudo if isinstance(conteudo, bytes) else conteudo.encode("utf-8"))
        os.chmod(tmp, modo)
        os.replace(tmp, caminho)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class SoHttps(urllib.request.HTTPRedirectHandler):
    """Segue redirecionamento só para HTTPS."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise urllib.error.URLError("redirecionamento para fora do HTTPS recusado: " + newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


ABRIR = urllib.request.build_opener(SoHttps).open


def baixar(url, limite):
    """Baixa por HTTPS com certificado validado. Recusa outro esquema."""
    if not url.startswith("https://"):
        raise Recusa("manifesto_invalido", "endereço sem HTTPS recusado: {}".format(url), "erro")
    req = urllib.request.Request(url, headers={"User-Agent": "nextec-atualizador/" + VERSAO, "Cache-Control": "no-cache"})
    with ABRIR(req, timeout=60) as resp:
        dados = resp.read(limite + 1)
    if len(dados) > limite:
        raise Recusa("falha_download", "arquivo maior que o limite: {}".format(url), "erro")
    return dados


# ---------------------------------------------------------------------------
# Assinatura RSA (PKCS#1 v1.5, SHA-256), só biblioteca padrão
# ---------------------------------------------------------------------------

def chaves_validas():
    validas = []
    for chave in CHAVES_CONFIAVEIS:
        try:
            n = int(chave["n"], 16)
            e = int(chave["e"])
        except (KeyError, TypeError, ValueError):
            continue
        if n.bit_length() >= TAMANHO_MINIMO_CHAVE and e >= 3 and e % 2 == 1:
            validas.append({"id": str(chave.get("id", "")), "n": n, "e": e})
    return validas


def assinatura_confere(dados, assinatura, chaves):
    """Devolve o id da chave que confere a assinatura, ou None."""
    resumo = hashlib.sha256(dados).digest()
    for chave in chaves:
        n, e = chave["n"], chave["e"]
        k = (n.bit_length() + 7) // 8
        if len(assinatura) != k:
            continue
        s = int.from_bytes(assinatura, "big")
        if s >= n:
            continue
        bloco = pow(s, e, n).to_bytes(k, "big")
        preenchimento = k - 3 - len(DIGESTINFO_SHA256) - len(resumo)
        if preenchimento < 8:
            continue
        esperado = b"\x00\x01" + b"\xff" * preenchimento + b"\x00" + DIGESTINFO_SHA256 + resumo
        if hmac.compare_digest(bloco, esperado):
            return chave["id"] or "sem_id"
    return None


# ---------------------------------------------------------------------------
# Configuração, estado e identificação do servidor
# ---------------------------------------------------------------------------

def ler_config():
    cfg = {"habilitado": True, "onda": "auto", "manifesto_url": MANIFESTO_URL_PADRAO}
    if os.path.isfile(CONFIG):
        parser = configparser.ConfigParser()
        parser.read(CONFIG, encoding="utf-8")
        if parser.has_section("atualizador"):
            sec = parser["atualizador"]
            cfg["habilitado"] = sec.get("habilitado", "sim").strip().lower() in ("sim", "s", "1", "true")
            cfg["onda"] = sec.get("onda", "auto").strip().lower()
            cfg["manifesto_url"] = sec.get("manifesto_url", MANIFESTO_URL_PADRAO).strip() or MANIFESTO_URL_PADRAO
    if cfg["onda"] not in ("auto", "0", "1", "2"):
        log("aviso", "onda inválida na configuração; usando auto", onda=cfg["onda"])
        cfg["onda"] = "auto"
    return cfg


def ler_estado():
    try:
        with open(ESTADO, encoding="utf-8") as f:
            estado = json.load(f)
        if isinstance(estado, dict):
            return estado
    except (OSError, ValueError):
        pass
    return {}


def salvar_estado(estado):
    gravar_atomico(ESTADO, json.dumps(estado, ensure_ascii=False, indent=2))


def ler_instalacao():
    """Lê cliente, host e modo gravados pelo instalador (sem executar o arquivo)."""
    dados = {}
    if not os.path.isfile(INSTALACAO):
        return dados
    with open(INSTALACAO, encoding="utf-8") as f:
        for linha in f:
            linha = linha.rstrip("\n")
            if "=" not in linha or linha.startswith("#"):
                continue
            chave, valor = linha.split("=", 1)
            if chave in ("CLIENTE", "HOST_LABEL", "MODO", "FORMATO"):
                dados[chave] = valor
    return dados


def onda_do_servidor(cfg, instalacao):
    if cfg["onda"] != "auto":
        return int(cfg["onda"])
    cliente = instalacao.get("CLIENTE", "")
    host = instalacao.get("HOST_LABEL", "")
    if cliente == "nextec":
        return 0
    # Sorteio fixo por servidor: ~10% dos servidores dos clientes na onda 1.
    sorteio = int(hashlib.sha256("{}/{}".format(cliente, host).encode("utf-8")).hexdigest()[:8], 16)
    return 1 if sorteio % 10 == 0 else 2


# ---------------------------------------------------------------------------
# Manifesto
# ---------------------------------------------------------------------------

def obter_manifesto(cfg, estado):
    chaves = chaves_validas()
    if not chaves:
        raise Recusa("sem_chave", "nenhuma chave pública configurada neste atualizador", "erro")

    url = cfg["manifesto_url"]
    try:
        bruto = baixar(url, LIMITE_MANIFESTO)
        assinatura_txt = baixar(url + ".sig", 16 * 1024)
    except (urllib.error.URLError, OSError) as erro:
        raise Recusa("erro_rede", "não foi possível baixar o manifesto: {}".format(erro))

    try:
        assinatura = base64.b64decode(assinatura_txt.strip(), validate=True)
    except (ValueError, TypeError):
        raise Recusa("assinatura_invalida", "arquivo de assinatura ilegível", "erro")

    chave_id = assinatura_confere(bruto, assinatura, chaves)
    if not chave_id:
        raise Recusa("assinatura_invalida", "assinatura do manifesto não confere com nenhuma chave confiável", "erro")

    try:
        manifesto = json.loads(bruto.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Recusa("manifesto_invalido", "manifesto assinado mas ilegível", "erro")

    validar_manifesto(manifesto)

    if agora() > ler_data(manifesto["valido_ate"], "valido_ate"):
        raise Recusa("manifesto_vencido", "manifesto vencido em {}".format(manifesto["valido_ate"]), "erro")

    ultima = int(estado.get("sequencia", 0))
    resumo = hashlib.sha256(bruto).hexdigest()
    if manifesto["sequencia"] < ultima:
        raise Recusa("versao_antiga",
                     "manifesto com sequência {} menor que a já aceita {}".format(manifesto["sequencia"], ultima),
                     "erro")
    if manifesto["sequencia"] == ultima and estado.get("manifesto_sha256") not in (None, resumo):
        # Duas publicações assinadas com a mesma sequência e conteúdo
        # diferente: não dá para saber qual é a atual.
        raise Recusa("manifesto_divergente",
                     "manifesto com a mesma sequência {} e conteúdo diferente do já aceito".format(ultima), "erro")
    # Aceito: a sequência fica registrada antes de pausa e onda (anti-rollback).
    estado["sequencia"] = manifesto["sequencia"]
    estado["manifesto_sha256"] = resumo
    manifesto["_pacote"] = impressao_pacote(manifesto)
    return manifesto


def impressao_pacote(manifesto):
    """Identifica o conteúdo do pacote Linux (arquivos e Alloy), não só o nome da versão."""
    return hashlib.sha256(json.dumps(manifesto["linux"], sort_keys=True).encode("utf-8")).hexdigest()[:16]


def validar_manifesto(m):
    if not isinstance(m, dict) or m.get("formato") != FORMATO_MANIFESTO:
        raise Recusa("manifesto_invalido", "formato de manifesto não suportado", "erro")
    if not isinstance(m.get("sequencia"), int) or m["sequencia"] < 1:
        raise Recusa("manifesto_invalido", "sequência inválida", "erro")
    if not isinstance(m.get("versao"), str) or not RE_VERSAO.fullmatch(m["versao"]):
        raise Recusa("manifesto_invalido", "versão inválida", "erro")
    ondas = m.get("ondas")
    if not isinstance(ondas, dict):
        raise Recusa("manifesto_invalido", "ondas ausentes", "erro")
    for onda in ("0", "1", "2"):
        if ondas.get(onda) is not None:
            ler_data(ondas[onda], "ondas." + onda)
    linux = m.get("linux")
    if not isinstance(linux, dict) or not isinstance(linux.get("arquivos"), dict):
        raise Recusa("manifesto_invalido", "seção linux ausente", "erro")
    alloy = linux.get("alloy", "")
    if alloy and not RE_ALLOY.fullmatch(str(alloy)):
        raise Recusa("manifesto_invalido", "versão do Alloy inválida", "erro")
    binarios = linux.get("alloy_binario") or {}
    if not isinstance(binarios, dict):
        raise Recusa("manifesto_invalido", "alloy_binario inválido", "erro")
    for arq, item in binarios.items():
        if not isinstance(item, dict) or not RE_SHA256.fullmatch(str(item.get("sha256", ""))):
            raise Recusa("manifesto_invalido", "alloy_binario {} sem SHA-256".format(arq), "erro")
    for nome in ARQUIVOS_LINUX:
        item = linux["arquivos"].get(nome)
        if not isinstance(item, dict):
            raise Recusa("manifesto_invalido", "arquivo {} ausente".format(nome), "erro")
        if not str(item.get("url", "")).startswith("https://"):
            raise Recusa("manifesto_invalido", "arquivo {} sem HTTPS".format(nome), "erro")
        if not RE_SHA256.fullmatch(str(item.get("sha256", ""))):
            raise Recusa("manifesto_invalido", "arquivo {} sem SHA-256".format(nome), "erro")


def pausa_ativa(cfg):
    """A pausa não é assinada de propósito: ela só consegue impedir, nunca instalar."""
    url = cfg["manifesto_url"].rsplit("/", 1)[0] + "/pausa.json"
    try:
        dados = json.loads(baixar(url, 16 * 1024).decode("utf-8"))
    except urllib.error.HTTPError as erro:
        if erro.code == 404:
            return None
        raise Recusa("erro_rede", "não foi possível ler a pausa: {}".format(erro))
    except (urllib.error.URLError, OSError) as erro:
        raise Recusa("erro_rede", "não foi possível ler a pausa: {}".format(erro))
    except ValueError:
        # Arquivo de pausa ilegível conta como pausa: na dúvida, não atualiza.
        return "arquivo de pausa ilegível"
    if isinstance(dados, dict) and dados.get("pausado") is True:
        return str(dados.get("motivo", "sem motivo informado"))[:200]
    return None


# ---------------------------------------------------------------------------
# Aplicação
# ---------------------------------------------------------------------------

def baixar_versao(manifesto):
    destino = os.path.join(STAGING, manifesto["versao"])
    if os.path.isdir(destino):
        shutil.rmtree(destino)
    os.makedirs(destino, mode=0o700)
    caminhos = {}
    for nome in ARQUIVOS_LINUX:
        item = manifesto["linux"]["arquivos"][nome]
        try:
            dados = baixar(item["url"], LIMITE_ARQUIVO)
        except (urllib.error.URLError, OSError) as erro:
            raise Recusa("falha_download", "falha ao baixar {}: {}".format(nome, erro))
        if not hmac.compare_digest(hashlib.sha256(dados).hexdigest(), item["sha256"]):
            raise Recusa("hash_invalido", "SHA-256 de {} não confere com o manifesto".format(nome), "erro")
        caminho = os.path.join(destino, nome)
        gravar_atomico(caminho, dados, 0o700)
        caminhos[nome] = caminho
    return caminhos


def versao_alloy():
    try:
        saida = subprocess.run(["alloy", "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=30, check=False).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""
    achado = re.search(r"v?([0-9]+\.[0-9]+\.[0-9]+)", saida)
    return achado.group(1) if achado else ""


def servico_ativo(nome):
    return subprocess.run(["systemctl", "is-active", "--quiet", nome], check=False).returncode == 0


def alloy_pronto():
    try:
        with urllib.request.urlopen(ALLOY_READY, timeout=5) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError):
        return False


def aguardar_saude(servicos):
    limite = time.monotonic() + TEMPO_SAUDE
    while time.monotonic() < limite:
        if all(servico_ativo(s) for s in servicos) and ("alloy" not in servicos or alloy_pronto()):
            # Confirma de novo depois de um intervalo: serviço que cai logo
            # depois de subir também é falha.
            time.sleep(20)
            if all(servico_ativo(s) for s in servicos):
                return True
        time.sleep(5)
    return False


def criar_backup():
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    caminho = os.path.join(BACKUPS, "antes-{}.tar.gz".format(agora().strftime("%Y%m%d-%H%M%S")))
    with tarfile.open(caminho, "w:gz") as tar:
        for item in CAMINHOS_BACKUP:
            if os.path.lexists(item):
                tar.add(item, arcname=item.lstrip("/"))
    os.chmod(caminho, 0o600)
    return caminho


def restaurar_backup(caminho):
    """Deixa os caminhos do backup exatamente como estavam antes da atualização.

    Tudo o que está na lista é apagado e depois extraído da cópia; o que não
    existia antes (ex.: um arquivo novo da versão que falhou) some.
    """
    # Primeiro extrai tudo numa pasta temporária: se a extração falhar (disco
    # cheio, arquivo corrompido), nada do que está instalado foi apagado.
    temporaria = tempfile.mkdtemp(dir=DADOS, prefix="restauracao-")
    try:
        with tarfile.open(caminho, "r:gz") as tar:
            membros = []
            for membro in tar.getmembers():
                # Só caminhos relativos e dentro da lista de backup.
                if membro.name.startswith("/") or ".." in membro.name.split("/"):
                    continue
                if any(membro.name == p.lstrip("/") or membro.name.startswith(p.lstrip("/") + "/") for p in CAMINHOS_BACKUP):
                    membros.append(membro)
            # Dono, grupo e permissões precisam voltar iguais (ex.: /etc/alloy é
            # root:alloy). O filtro "data" do Python 3.12+ descartaria o grupo.
            extras = {"numeric_owner": True}
            if hasattr(tarfile, "fully_trusted_filter"):
                extras["filter"] = "fully_trusted"
            for membro in membros:
                tar.extract(membro, temporaria, **extras)
        for item in CAMINHOS_BACKUP:
            if os.path.isdir(item) and not os.path.islink(item):
                shutil.rmtree(item)
            elif os.path.lexists(item):
                os.unlink(item)
            origem = os.path.join(temporaria, item.lstrip("/"))
            if os.path.lexists(origem):
                os.makedirs(os.path.dirname(item), exist_ok=True)
                shutil.move(origem, item)
    finally:
        shutil.rmtree(temporaria, ignore_errors=True)


def gerenciador_pacotes():
    for nome in ("apt-get", "dnf", "yum", "zypper"):
        if shutil.which(nome):
            return nome
    return ""


def reinstalar_alloy(versao):
    """Volta o pacote do Alloy para a versão anterior (repositório oficial assinado)."""
    if not versao:
        return False
    pm = gerenciador_pacotes()
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    if pm == "apt-get":
        lista = subprocess.run(["apt-cache", "madison", "alloy"], stdout=subprocess.PIPE, check=False).stdout.decode()
        pacote = ""
        for linha in lista.splitlines():
            partes = [p.strip() for p in linha.split("|")]
            if len(partes) >= 2 and (partes[1] == versao or partes[1].startswith(versao + "-")):
                pacote = partes[1]
                break
        if not pacote:
            return False
        cmd = ["apt-get", "install", "-y", "--allow-downgrades", "-o", "Dpkg::Options::=--force-confold",
               "alloy=" + pacote]
    elif pm in ("dnf", "yum"):
        cmd = [pm, "downgrade", "-y", "alloy-" + versao]
    elif pm == "zypper":
        cmd = ["zypper", "--non-interactive", "install", "--oldpackage", "alloy=" + versao]
    else:
        return False
    return subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=900, check=False).returncode == 0


def abrir_log():
    """Log do instalador numa pasta só do root, sem seguir link simbólico."""
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    os.chmod(LOG_DIR, 0o700)
    fd = os.open(LOG_INSTALADOR, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, "ab")


def executar_instalador(arquivos, manifesto):
    env = dict(os.environ)
    env.update({
        "NEXTEC_ATUALIZACAO": "1",
        "COLETA_ARQUIVO": arquivos["coleta"],
        "ATUALIZADOR_ARQUIVO": arquivos["atualizador"],
        "ALLOY_VERSAO": str(manifesto["linux"].get("alloy", "")),
        "NEXTEC_PACOTE_VERSAO": manifesto["versao"],
        "TERM": "dumb",
    })
    arquitetura = ARQUITETURAS.get(platform.machine().lower(), "")
    binario = (manifesto["linux"].get("alloy_binario") or {}).get(arquitetura)
    if binario:
        env["ALLOY_BINARIO_SHA256"] = binario["sha256"]
    with abrir_log() as saida:
        saida.write("\n===== {} versão {} =====\n".format(agora().isoformat(), manifesto["versao"]).encode())
        saida.flush()
        # Grupo de processos próprio: no tempo esgotado morrem também apt,
        # dpkg e o que mais o instalador tiver aberto.
        proc = subprocess.Popen(["bash", arquivos["instalador"], "--atualizar"], env=env,
                                stdin=subprocess.DEVNULL, stdout=saida, stderr=saida, start_new_session=True)
        try:
            return proc.wait(timeout=TEMPO_INSTALADOR)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            return 124


def recarregar_servicos(servicos):
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    for s in servicos:
        subprocess.run(["systemctl", "restart", s], check=False)


def aplicar(manifesto, estado, instalacao):
    # Desligar o serviço no meio de uma atualização deixaria a máquina pela
    # metade: daqui até o fim da volta automática, SIGTERM é ignorado.
    anterior = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        return aplicar_protegido(manifesto, estado, instalacao)
    finally:
        signal.signal(signal.SIGTERM, anterior)


def aplicar_protegido(manifesto, estado, instalacao):
    arquivos = baixar_versao(manifesto)
    somente_coleta = instalacao.get("MODO") == "somente_coleta"
    servicos = ["coleta-complementar"] if somente_coleta else ["alloy"]
    if servico_ativo("coleta-complementar") and "coleta-complementar" not in servicos:
        servicos.append("coleta-complementar")
    alloy_antes = "" if somente_coleta else versao_alloy()
    backup = criar_backup()
    log("info", "aplicando versão", versao=manifesto["versao"], backup=backup)

    codigo = executar_instalador(arquivos, manifesto)
    if codigo == 0 and aguardar_saude(servicos):
        os.unlink(backup)
        shutil.rmtree(os.path.dirname(arquivos["instalador"]), ignore_errors=True)
        return "ok", "versão {} aplicada".format(manifesto["versao"])

    motivo = "instalador terminou com código {}".format(codigo) if codigo else "serviço não ficou saudável"
    log("erro", "atualização falhou; voltando a versão anterior", motivo=motivo)
    try:
        restaurar_backup(backup)
        if not somente_coleta and alloy_antes and versao_alloy() != alloy_antes:
            reinstalar_alloy(alloy_antes)
            restaurar_backup(backup)
    except Exception as erro:  # noqa: BLE001 - os serviços precisam ser religados de qualquer jeito
        log("erro", "falha na volta automática", erro=repr(erro))
        recarregar_servicos(servicos)
        return "falha_rollback", "{}; a volta automática falhou: {!r} (backup em {})".format(motivo, erro, backup)
    recarregar_servicos(servicos)
    if aguardar_saude(servicos):
        os.unlink(backup)
        return "falha_instalacao", "{}; versão anterior restaurada".format(motivo)
    return "falha_rollback", "{}; a volta automática não deixou o serviço saudável (backup em {})".format(motivo, backup)


# ---------------------------------------------------------------------------
# Saídas para o NOC
# ---------------------------------------------------------------------------

def escapar_rotulo(valor):
    return str(valor).replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def gravar_metricas(estado, resultado, onda, manifesto):
    if not os.path.isdir(os.path.dirname(TEXTFILE)):
        return
    disponivel = manifesto.get("versao", "") if manifesto else ""
    validade = 0
    if manifesto:
        try:
            validade = int(ler_data(manifesto["valido_ate"], "valido_ate").timestamp())
        except Recusa:
            validade = 0
    linhas = [
        "# HELP nextec_atualizador_info Versões do atualizador e do pacote Nextec neste servidor.",
        "# TYPE nextec_atualizador_info gauge",
        'nextec_atualizador_info{{versao_agente="{}",versao_instalada="{}",versao_disponivel="{}",onda="{}"}} 1'.format(
            VERSAO, escapar_rotulo(estado.get("versao_instalada", "")), escapar_rotulo(disponivel), onda),
        "# HELP nextec_atualizador_resultado Resultado da última execução (1 no resultado atual).",
        "# TYPE nextec_atualizador_resultado gauge",
        'nextec_atualizador_resultado{{resultado="{}"}} 1'.format(escapar_rotulo(resultado)),
        "# HELP nextec_atualizador_ultima_execucao_segundos Fim da última execução (epoch).",
        "# TYPE nextec_atualizador_ultima_execucao_segundos gauge",
        "nextec_atualizador_ultima_execucao_segundos {}".format(int(time.time())),
        "# HELP nextec_atualizador_ultima_atualizacao_segundos Última versão aplicada com sucesso (epoch).",
        "# TYPE nextec_atualizador_ultima_atualizacao_segundos gauge",
        "nextec_atualizador_ultima_atualizacao_segundos {}".format(int(estado.get("aplicada_em", 0))),
        "# HELP nextec_atualizador_sequencia Sequência do último manifesto aceito.",
        "# TYPE nextec_atualizador_sequencia gauge",
        "nextec_atualizador_sequencia {}".format(int(estado.get("sequencia", 0))),
        "# HELP nextec_atualizador_manifesto_valido_ate_segundos Vencimento do manifesto atual (epoch).",
        "# TYPE nextec_atualizador_manifesto_valido_ate_segundos gauge",
        "nextec_atualizador_manifesto_valido_ate_segundos {}".format(validade),
    ]
    try:
        gravar_atomico(TEXTFILE, "\n".join(linhas) + "\n", 0o644)
    except OSError as erro:
        log("aviso", "não foi possível gravar as métricas", erro=erro)


def registrar_evento(evento, nivel, detalhe, versao=""):
    if not os.path.isdir(os.path.dirname(EVENTOS)):
        return
    linha = {
        "ts": agora().strftime("%Y-%m-%dT%H:%M:%S.000+00:00"),
        "tipo": "atualizador_evento",
        "categoria": "atualizacao",
        "evento": evento,
        "nivel": nivel,
        "detalhe": detalhe[:500],
    }
    if versao:
        linha["versao"] = versao
    try:
        with open(EVENTOS, "a", encoding="utf-8") as f:
            f.write(json.dumps(linha, ensure_ascii=False) + "\n")
    except OSError as erro:
        log("aviso", "não foi possível registrar o evento", erro=erro)


# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

def executar():
    import fcntl  # só existe no Linux; importado aqui para o publicador rodar no Windows

    os.makedirs(DADOS, mode=0o700, exist_ok=True)
    with open(TRAVA, "w") as trava:
        try:
            fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("aviso", "outra execução do atualizador está em andamento")
            return 0
        return ciclo()


def ciclo():
    estado = ler_estado()
    onda = -1
    manifesto = None
    resultado = "erro"
    aplicando = False
    try:
        cfg = ler_config()
        instalacao = ler_instalacao()
        onda = onda_do_servidor(cfg, instalacao)
        if not cfg["habilitado"]:
            raise Recusa("desligado", "atualizador desligado em " + CONFIG, "info")
        if not instalacao:
            raise Recusa("sem_estado", "instalação sem respostas gravadas; rode o instalador uma vez", "erro")

        manifesto = obter_manifesto(cfg, estado)
        motivo_pausa = pausa_ativa(cfg)
        if motivo_pausa:
            raise Recusa("pausado", "atualizações pausadas: " + motivo_pausa, "info")

        liberada = manifesto["ondas"].get(str(onda))
        if liberada is None or agora() < ler_data(liberada, "ondas"):
            raise Recusa("aguardando_onda", "versão {} ainda não liberada para a onda {}".format(manifesto["versao"], onda), "info")

        pacote = manifesto["_pacote"]
        if estado.get("pacote_instalado") == pacote:
            estado["versao_instalada"] = manifesto["versao"]
            raise Recusa("atualizado", "já na versão {}".format(manifesto["versao"]), "info")
        if pacote in estado.get("falhas", []):
            raise Recusa("falhou_antes", "versão {} já falhou neste servidor; aguardando nova versão".format(manifesto["versao"]))

        aplicando = True
        resultado, detalhe = aplicar(manifesto, estado, instalacao)
        aplicando = False
        if resultado == "ok":
            estado["versao_instalada"] = manifesto["versao"]
            estado["pacote_instalado"] = pacote
            estado["aplicada_em"] = int(time.time())
            registrar_evento("atualizacao_concluida", "info", detalhe, manifesto["versao"])
            log("info", detalhe)
        else:
            registrar_falha(estado, pacote)
            registrar_evento("atualizacao_falhou", "erro", detalhe, manifesto["versao"])
            log("erro", detalhe)
    except Recusa as recusa:
        resultado = recusa.resultado
        log(recusa.nivel, recusa.detalhe, resultado=resultado)
        if recusa.nivel == "erro":
            registrar_evento(resultado, "erro", recusa.detalhe, manifesto["versao"] if manifesto else "")
    except Exception as erro:  # noqa: BLE001 - registra qualquer falha inesperada antes de sair
        resultado = "erro"
        if aplicando and manifesto:
            # Falha no meio da aplicação: não tenta a mesma versão toda noite.
            registrar_falha(estado, manifesto["_pacote"])
        log("erro", "falha inesperada no atualizador", erro=repr(erro))
        registrar_evento("erro", "erro", "falha inesperada: {!r}".format(erro))
    finally:
        estado["ultimo_resultado"] = resultado
        estado["ultima_execucao"] = int(time.time())
        try:
            salvar_estado(estado)
        except OSError as erro:
            log("erro", "não foi possível salvar o estado", erro=erro)
        gravar_metricas(estado, resultado, onda, manifesto)
    return 0 if resultado not in ("erro", "falha_rollback") else 1


def registrar_falha(estado, pacote):
    falhas = estado.get("falhas", [])
    falhas.append(pacote)
    estado["falhas"] = falhas[-10:]


def verificar():
    cfg = ler_config()
    estado = ler_estado()
    instalacao = ler_instalacao()
    onda = onda_do_servidor(cfg, instalacao)
    print("Atualizador Nextec {}".format(VERSAO))
    print("Habilitado:        {}".format("sim" if cfg["habilitado"] else "não"))
    print("Manifesto:         {}".format(cfg["manifesto_url"]))
    print("Chaves confiáveis: {}".format(len(chaves_validas())))
    print("Cliente/host:      {}/{}".format(instalacao.get("CLIENTE", "?"), instalacao.get("HOST_LABEL", "?")))
    print("Onda:              {}{}".format(onda, " (automática)" if cfg["onda"] == "auto" else ""))
    print("Versão instalada:  {}".format(estado.get("versao_instalada", "nenhuma registrada")))
    print("Último resultado:  {}".format(estado.get("ultimo_resultado", "nunca executou")))
    try:
        manifesto = obter_manifesto(cfg, estado)
        liberada = manifesto["ondas"].get(str(onda))
        print("Versão publicada:  {} (sequência {}, válida até {})".format(
            manifesto["versao"], manifesto["sequencia"], manifesto["valido_ate"]))
        print("Liberada p/ onda:  {}".format(liberada or "ainda não"))
        pausa = pausa_ativa(cfg)
        print("Pausa:             {}".format(pausa or "não"))
    except Recusa as recusa:
        print("Manifesto:         {} ({})".format(recusa.resultado, recusa.detalhe))
        return 1
    return 0


def main(argv):
    comando = argv[1] if len(argv) > 1 else "executar"
    if comando == "versao":
        print(VERSAO)
        return 0
    if os.geteuid() != 0:
        print("Execute como root.", file=sys.stderr)
        return 1
    if comando == "executar":
        return executar()
    if comando == "verificar":
        return verificar()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
