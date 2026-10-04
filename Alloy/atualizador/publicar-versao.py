#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Publicação de versões do monitoramento Nextec para o atualizador automático.

Roda NO COMPUTADOR DE QUEM PUBLICA, nunca em servidor. A chave privada fica
nesse computador (com senha) e é o que garante que só a Nextec consegue
mandar atualização para os clientes.

Requisitos: Python 3.8+, git e openssl no PATH (no Windows, o Git for Windows
já traz o openssl), e este repositório clonado.

Comandos (rode da raiz do repositório Scripts):

  gerar-chave --pasta CAMINHO
      Cria o par de chaves RSA 4096 (a privada protegida por senha) e grava a
      chave pública dentro dos dois atualizadores. Faça uma vez. Commit e
      push dos atualizadores depois.

  publicar --commit SHA --alloy 1.20.1 --chave CAMINHO [--onda1-horas 24] [--validade-dias 30]
      Publica a versão daquele commit: onda 0 na hora, onda 1 depois de
      --onda1-horas, onda 2 só com "aprovar". O commit precisa estar no GitHub.

  aprovar --chave CAMINHO
      Libera a versão atual para todos (onda 2).

  renovar --chave CAMINHO [--validade-dias 30]
      Renova o vencimento do manifesto atual sem mudar a versão.

  pausar --motivo "texto"    /    retomar
      Suspende ou retoma todas as atualizações. Não precisa de chave: a pausa
      só consegue impedir atualização, nunca instalar nada.

  verificar
      Confere a assinatura do manifesto atual e mostra a situação.

Depois de cada comando que altera arquivo, faça commit e push da pasta
Alloy/atualizador. As máquinas leem o manifesto da branch main.
"""

import argparse
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO_PADRAO = "Sou-Nextec/Scripts"
PASTA = os.path.join("Alloy", "atualizador")
MANIFESTO = os.path.join(PASTA, "manifesto.json")
ASSINATURA = MANIFESTO + ".sig"
PAUSA = os.path.join(PASTA, "pausa.json")
AGENTE_LINUX = os.path.join(PASTA, "nextec-atualizador.py")
AGENTE_WINDOWS = os.path.join(PASTA, "nextec-atualizador.ps1")

# Arquivos de cada sistema, no caminho do repositório.
ARQUIVOS = {
    "linux": {
        "instalador": "Alloy/install-nextec-monitoring-linux-v2.sh",
        "coleta": "Alloy/coleta-complementar/coleta-complementar.py",
        "atualizador": "Alloy/atualizador/nextec-atualizador.py",
    },
    "windows": {
        "instalador": "Alloy/install-nextec-monitoring-windows-v2.ps1",
        "coleta": "Alloy/coleta-complementar/coleta-complementar.ps1",
        "atualizador": "Alloy/atualizador/nextec-atualizador.ps1",
    },
}
ALLOY_WINDOWS = "alloy-installer-windows-amd64.exe"
ALLOY_LINUX = {"amd64": "alloy-linux-amd64.zip", "arm64": "alloy-linux-arm64.zip"}
RAMO = "main"
RE_ALLOY = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
RE_COMMIT = re.compile(r"^[0-9a-f]{40}$")


def falhar(msg):
    print("ERRO: " + msg, file=sys.stderr)
    sys.exit(1)


def agora():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def data(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def rodar(cmd, entrada=None):
    proc = subprocess.run(cmd, input=entrada, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        falhar("comando falhou: {}\n{}".format(" ".join(cmd), proc.stderr.decode("utf-8", "replace")))
    return proc.stdout


def exigir_ferramentas():
    for ferramenta in ("git", "openssl"):
        if not shutil.which(ferramenta):
            falhar("{} não encontrado no PATH.".format(ferramenta))
    if not os.path.isfile(AGENTE_LINUX):
        falhar("rode este comando na raiz do repositório Scripts.")


def carregar_agente():
    """Importa o atualizador Linux para usar a mesma verificação das máquinas."""
    spec = importlib.util.spec_from_file_location("nextec_atualizador", AGENTE_LINUX)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


# ---------------------------------------------------------------------------
# Chaves
# ---------------------------------------------------------------------------

def chave_publica_de(caminho_pem, publica=False):
    args = ["openssl", "rsa", "-noout", "-modulus", "-in", caminho_pem]
    if publica:
        args.insert(2, "-pubin")
    saida = rodar(args).decode().strip()
    if not saida.startswith("Modulus="):
        falhar("não foi possível ler o módulo da chave.")
    modulo = saida.split("=", 1)[1].strip().lower()
    texto = rodar(["openssl", "rsa", "-noout", "-text"] + (["-pubin"] if publica else []) + ["-in", caminho_pem]).decode()
    achado = re.search(r"(?:publicExponent|Exponent): (\d+)", texto)
    expoente = int(achado.group(1)) if achado else 65537
    if int(modulo, 16).bit_length() < 4096:
        falhar("a chave precisa ter 4096 bits.")
    chave_id = hashlib.sha256(bytes.fromhex(modulo)).hexdigest()[:16]
    return {"id": chave_id, "n": modulo, "e": expoente}


def gravar_chave_nos_agentes(chave):
    # Linux
    with open(AGENTE_LINUX, encoding="utf-8") as f:
        texto = f.read()
    if chave["n"] in texto:
        print("A chave {} já está no atualizador Linux.".format(chave["id"]))
    else:
        entrada = '    {{"id": "{}", "e": {}, "n": "{}"}},\n'.format(chave["id"], chave["e"], chave["n"])
        texto, n = re.subn(r"(CHAVES_CONFIAVEIS = \[\n)", lambda m: m.group(1) + entrada, texto, count=1)
        if n != 1:
            falhar("não encontrei CHAVES_CONFIAVEIS no atualizador Linux.")
        with open(AGENTE_LINUX, "w", encoding="utf-8", newline="\n") as f:
            f.write(texto)
    # Windows (arquivo com BOM)
    with open(AGENTE_WINDOWS, encoding="utf-8-sig") as f:
        texto = f.read()
    if chave["n"] in texto:
        print("A chave {} já está no atualizador Windows.".format(chave["id"]))
    else:
        entrada = '    @{{ Id = "{}"; E = {}; N = "{}" }}\n'.format(chave["id"], chave["e"], chave["n"])
        texto, n = re.subn(r"(\$script:ChavesConfiaveis = @\(\r?\n)", lambda m: m.group(1) + entrada, texto, count=1)
        if n != 1:
            falhar("não encontrei $script:ChavesConfiaveis no atualizador Windows.")
        with open(AGENTE_WINDOWS, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write(texto.replace("\r\n", "\n"))


def cmd_gerar_chave(args):
    exigir_ferramentas()
    os.makedirs(args.pasta, exist_ok=True)
    privada = os.path.join(args.pasta, "nextec-atualizador-privada.pem")
    publica = os.path.join(args.pasta, "nextec-atualizador-publica.pem")
    if os.path.exists(privada):
        falhar("já existe {}. Não sobrescrevo chave.".format(privada))
    print("Defina a senha da chave privada (o openssl vai pedir duas vezes).")
    proc = subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:4096",
                           "-aes-256-cbc", "-out", privada], check=False)
    if proc.returncode != 0 or not os.path.isfile(privada):
        falhar("geração da chave falhou.")
    rodar(["openssl", "rsa", "-in", privada, "-pubout", "-out", publica])
    chave = chave_publica_de(publica, publica=True)
    gravar_chave_nos_agentes(chave)
    print("\nChave criada: {}".format(chave["id"]))
    print("  Privada (guarde com cuidado, faça cópia no cofre): {}".format(privada))
    print("  Pública: {}".format(publica))
    print("A chave pública foi gravada nos dois atualizadores. Faça commit e push de {}.".format(PASTA))


def cmd_adicionar_chave(args):
    exigir_ferramentas()
    chave = chave_publica_de(args.publica, publica=True)
    gravar_chave_nos_agentes(chave)
    print("Chave {} adicionada. Publique uma versão assinada pela chave atual para ela chegar às máquinas.".format(chave["id"]))


# ---------------------------------------------------------------------------
# Manifesto
# ---------------------------------------------------------------------------

def exigir_sincronia():
    """O manifesto local precisa ser igual ao publicado na main do GitHub.

    Impede assinar por cima de um manifesto alterado no repositório ou de um
    clone desatualizado (sequência repetida com conteúdo diferente).
    """
    rodar(["git", "fetch", "--quiet", "origin", RAMO])
    caminho = MANIFESTO.replace(os.sep, "/")
    remoto = subprocess.run(["git", "show", "origin/{}:{}".format(RAMO, caminho)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    local = open(MANIFESTO, "rb").read() if os.path.isfile(MANIFESTO) else None
    if remoto.returncode != 0:
        if local is not None:
            falhar("há manifesto local, mas nenhum publicado em origin/{}. Confira antes de seguir.".format(RAMO))
        return
    if local != remoto.stdout:
        falhar("o manifesto local é diferente do publicado em origin/{}. Rode git pull (ou descarte a alteração local) e tente de novo.".format(RAMO))


def ler_manifesto():
    """Manifesto atual, só depois de conferir a assinatura dele."""
    if not os.path.isfile(MANIFESTO):
        return None
    manifesto, _ = manifesto_atual_verificado()
    return manifesto


def proxima_sequencia(anterior):
    # Sequência baseada no relógio: dois publicadores nunca geram o mesmo número.
    return max(int(anterior["sequencia"]) + 1 if anterior else 1, int(time.time()))


def assinar_e_gravar(manifesto, chave_privada):
    agente = carregar_agente()
    chaves = agente.chaves_validas()
    if not chaves:
        falhar("o atualizador ainda não tem chave pública. Rode gerar-chave primeiro.")
    conteudo = (json.dumps(manifesto, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    with tempfile.TemporaryDirectory() as tmp:
        arquivo = os.path.join(tmp, "manifesto.json")
        saida = os.path.join(tmp, "manifesto.sig")
        with open(arquivo, "wb") as f:
            f.write(conteudo)
        print("Assinando (o openssl vai pedir a senha da chave privada)...")
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", chave_privada, "-out", saida, arquivo], check=False)
        if proc.returncode != 0:
            falhar("assinatura falhou.")
        with open(saida, "rb") as f:
            assinatura = f.read()
    chave_id = agente.assinatura_confere(conteudo, assinatura, chaves)
    if not chave_id:
        falhar("a chave privada usada não corresponde a nenhuma chave pública dos atualizadores.")
    with open(MANIFESTO, "wb") as f:
        f.write(conteudo)
    with open(ASSINATURA, "w", encoding="ascii", newline="\n") as f:
        f.write(base64.b64encode(assinatura).decode("ascii") + "\n")
    print("Manifesto assinado com a chave {}: versão {}, sequência {}.".format(chave_id, manifesto["versao"], manifesto["sequencia"]))
    print("Agora: git add {} && git commit -m \"Publica {}\" && git push".format(PASTA, manifesto["versao"]))


def sha256_no_commit(commit, caminho):
    return hashlib.sha256(rodar(["git", "show", "{}:{}".format(commit, caminho)])).hexdigest()


def sha256_alloy(versao):
    """Hashes publicados pela Grafana para a versão (SHA256SUMS do release)."""
    url = "https://github.com/grafana/alloy/releases/download/v{}/SHA256SUMS".format(versao)
    with urllib.request.urlopen(url, timeout=60) as resp:
        texto = resp.read().decode("utf-8")
    hashes = {}
    for linha in texto.splitlines():
        partes = linha.split()
        if len(partes) == 2 and re.fullmatch(r"[0-9a-fA-F]{64}", partes[0]):
            hashes[partes[1].lstrip("*")] = partes[0].lower()
    for nome in [ALLOY_WINDOWS] + list(ALLOY_LINUX.values()):
        if nome not in hashes:
            falhar("{} não está no SHA256SUMS da versão {} do Alloy.".format(nome, versao))
    return hashes


def proxima_versao(anterior):
    base = agora().strftime("%Y.%m.%d")
    n = 1
    if anterior and str(anterior.get("versao", "")).startswith(base + "-"):
        try:
            n = int(str(anterior["versao"]).rsplit("-", 1)[1]) + 1
        except ValueError:
            n = 1
    return "{}-{}".format(base, n)


def cmd_publicar(args):
    exigir_ferramentas()
    commit = rodar(["git", "rev-parse", args.commit]).decode().strip()
    if not RE_COMMIT.match(commit):
        falhar("commit inválido.")
    remotos = rodar(["git", "branch", "-r", "--contains", commit]).decode().strip()
    if not remotos:
        falhar("o commit {} não está no GitHub. Faça push antes de publicar.".format(commit[:10]))
    if not RE_ALLOY.match(args.alloy):
        falhar("versão do Alloy inválida (ex.: 1.20.1).")

    exigir_sincronia()
    anterior = ler_manifesto()
    sequencia = proxima_sequencia(anterior)
    inicio = agora()
    manifesto = {
        "formato": 1,
        "versao": args.versao or proxima_versao(anterior),
        "sequencia": sequencia,
        "commit": commit,
        "publicado_em": data(inicio),
        "valido_ate": data(inicio + datetime.timedelta(days=args.validade_dias)),
        "ondas": {
            "0": data(inicio),
            "1": data(inicio + datetime.timedelta(hours=args.onda1_horas)),
            "2": None,
        },
    }
    if anterior and anterior.get("versao") == manifesto["versao"]:
        falhar("a versão {} já foi publicada; use outro --versao.".format(manifesto["versao"]))
    for sistema, arquivos in ARQUIVOS.items():
        secao = {"arquivos": {}}
        for nome, caminho in arquivos.items():
            secao["arquivos"][nome] = {
                "url": "https://raw.githubusercontent.com/{}/{}/{}".format(args.repo, commit, caminho),
                "sha256": sha256_no_commit(commit, caminho),
            }
        manifesto[sistema] = secao
    hashes = sha256_alloy(args.alloy)
    base = "https://github.com/grafana/alloy/releases/download/v{}/".format(args.alloy)
    manifesto["linux"]["alloy"] = args.alloy
    # Para servidor sem pacote (instalação pelo binário): hash por arquitetura.
    manifesto["linux"]["alloy_binario"] = {
        arq: {"url": base + nome, "sha256": hashes[nome]} for arq, nome in ALLOY_LINUX.items()
    }
    manifesto["windows"]["alloy"] = {
        "versao": args.alloy,
        "url": base + ALLOY_WINDOWS,
        "sha256": hashes[ALLOY_WINDOWS],
    }
    # A volta automática do Windows reinstala o Alloy anterior por este item.
    if anterior and isinstance(anterior.get("windows", {}).get("alloy"), dict):
        alloy_ant = anterior["windows"]["alloy"]
        if alloy_ant.get("versao") != args.alloy:
            manifesto["windows"]["alloy_anterior"] = alloy_ant
        elif anterior["windows"].get("alloy_anterior"):
            manifesto["windows"]["alloy_anterior"] = anterior["windows"]["alloy_anterior"]

    assinar_e_gravar(manifesto, args.chave)
    print("Onda 0 (Nextec) liberada agora; onda 1 em {}; onda 2 só com 'aprovar'.".format(manifesto["ondas"]["1"]))


def manifesto_atual_verificado():
    agente = carregar_agente()
    if not os.path.isfile(MANIFESTO) or not os.path.isfile(ASSINATURA):
        falhar("não há manifesto publicado.")
    with open(MANIFESTO, "rb") as f:
        conteudo = f.read()
    manifesto = json.loads(conteudo.decode("utf-8"))
    with open(ASSINATURA, encoding="ascii") as f:
        assinatura = base64.b64decode(f.read().strip(), validate=True)
    chave_id = agente.assinatura_confere(conteudo, assinatura, agente.chaves_validas())
    if not chave_id:
        falhar("a assinatura do manifesto atual NÃO confere. Não altere: investigue.")
    return manifesto, chave_id


def cmd_aprovar(args):
    exigir_ferramentas()
    exigir_sincronia()
    manifesto, _ = manifesto_atual_verificado()
    inicio = data(agora())
    manifesto["sequencia"] = proxima_sequencia(manifesto)
    if manifesto["ondas"].get("1") is None or manifesto["ondas"]["1"] > inicio:
        manifesto["ondas"]["1"] = inicio
    manifesto["ondas"]["2"] = inicio
    assinar_e_gravar(manifesto, args.chave)
    print("Versão {} liberada para todos.".format(manifesto["versao"]))


def cmd_renovar(args):
    exigir_ferramentas()
    exigir_sincronia()
    manifesto, _ = manifesto_atual_verificado()
    manifesto["sequencia"] = proxima_sequencia(manifesto)
    manifesto["valido_ate"] = data(agora() + datetime.timedelta(days=args.validade_dias))
    assinar_e_gravar(manifesto, args.chave)


def cmd_pausar(args):
    with open(PAUSA, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"pausado": True, "motivo": args.motivo, "desde": data(agora())}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("Pausa gravada. git add {} && git commit -m \"Pausa atualizações\" && git push".format(PAUSA))


def cmd_retomar(_args):
    if os.path.exists(PAUSA):
        os.unlink(PAUSA)
    print("Pausa removida. git add -A {} && git commit -m \"Retoma atualizações\" && git push".format(PASTA))


def cmd_verificar(_args):
    manifesto, chave_id = manifesto_atual_verificado()
    print("Assinatura confere (chave {}).".format(chave_id))
    print("Versão:     {} (sequência {})".format(manifesto["versao"], manifesto["sequencia"]))
    print("Commit:     {}".format(manifesto.get("commit", "")))
    print("Válido até: {}".format(manifesto["valido_ate"]))
    for onda in ("0", "1", "2"):
        print("Onda {}:     {}".format(onda, manifesto["ondas"].get(onda) or "aguardando aprovação"))
    print("Pausa:      {}".format("SIM" if os.path.exists(PAUSA) else "não"))


def main():
    parser = argparse.ArgumentParser(description="Publicação do atualizador Nextec")
    sub = parser.add_subparsers(dest="comando", required=True)

    p = sub.add_parser("gerar-chave")
    p.add_argument("--pasta", required=True)
    p.set_defaults(func=cmd_gerar_chave)

    p = sub.add_parser("adicionar-chave")
    p.add_argument("--publica", required=True)
    p.set_defaults(func=cmd_adicionar_chave)

    p = sub.add_parser("publicar")
    p.add_argument("--commit", required=True)
    p.add_argument("--alloy", required=True)
    p.add_argument("--chave", required=True)
    p.add_argument("--versao", default="")
    p.add_argument("--repo", default=REPO_PADRAO)
    p.add_argument("--onda1-horas", type=int, default=24)
    p.add_argument("--validade-dias", type=int, default=30)
    p.set_defaults(func=cmd_publicar)

    p = sub.add_parser("aprovar")
    p.add_argument("--chave", required=True)
    p.set_defaults(func=cmd_aprovar)

    p = sub.add_parser("renovar")
    p.add_argument("--chave", required=True)
    p.add_argument("--validade-dias", type=int, default=30)
    p.set_defaults(func=cmd_renovar)

    p = sub.add_parser("pausar")
    p.add_argument("--motivo", required=True)
    p.set_defaults(func=cmd_pausar)

    p = sub.add_parser("retomar")
    p.set_defaults(func=cmd_retomar)

    p = sub.add_parser("verificar")
    p.set_defaults(func=cmd_verificar)

    args = parser.parse_args()
    if getattr(args, "validade_dias", 1) < 1 or getattr(args, "validade_dias", 1) > 60:
        falhar("--validade-dias entre 1 e 60: validade longa abre espaço para segurar uma versão antiga.")
    args.func(args)


if __name__ == "__main__":
    main()
