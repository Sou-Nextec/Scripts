#!/usr/bin/env python3
"""Confere o que não depende de linguagem: codificação dos arquivos e versões.

- Todo arquivo de texto versionado precisa ser UTF-8 válido.
- Todo .ps1 com caractere fora do ASCII precisa de BOM UTF-8: sem ele o
  Windows PowerShell 5.1 lê o arquivo como ANSI e quebra os acentos.
- As versões da tabela do Alloy/CHANGELOG.md precisam bater com as
  constantes dentro dos scripts.
"""
import re
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
EXTENSOES_TEXTO = {".md", ".py", ".ps1", ".sh", ".yml", ".yaml", ".example", ".bat", ".json", ".txt"}
BOM = b"\xef\xbb\xbf"

# Componente da tabela do CHANGELOG -> arquivos e o padrão que guarda a versão.
VERSOES = {
    "Instalador Linux": [("Alloy/install-nextec-monitoring-linux-v2.sh", r'^INSTALLER_VERSION="([^"]+)"')],
    "Instalador Windows": [("Alloy/install-nextec-monitoring-windows-v2.ps1", r'^\$InstallerVersion = "([^"]+)"')],
    "Coleta Complementar": [
        ("Alloy/coleta-complementar/coleta-complementar.py", r'^VERSAO = "([^"]+)"'),
        ("Alloy/coleta-complementar/coleta-complementar.ps1", r'^\$Versao = "([^"]+)"'),
    ],
    "Atualizador automático": [
        ("Alloy/atualizador/nextec-atualizador.py", r'^VERSAO = "([^"]+)"'),
        ("Alloy/atualizador/nextec-atualizador.ps1", r'^\$script:Versao = "([^"]+)"'),
    ],
}


def arquivos_versionados():
    saida = subprocess.run(["git", "ls-files", "-z"], cwd=RAIZ, check=True, stdout=subprocess.PIPE).stdout
    return [RAIZ / nome for nome in saida.decode("utf-8").split("\0") if nome]


def conferir_codificacao(erros):
    for caminho in arquivos_versionados():
        if caminho.suffix.lower() not in EXTENSOES_TEXTO:
            continue
        dados = caminho.read_bytes()
        relativo = caminho.relative_to(RAIZ)
        try:
            dados.decode("utf-8")
        except UnicodeDecodeError as exc:
            erros.append(f"{relativo}: não é UTF-8 válido ({exc})")
            continue
        if caminho.suffix.lower() == ".ps1" and not dados.startswith(BOM) and any(b > 0x7F for b in dados):
            erros.append(f"{relativo}: tem acento e está sem BOM UTF-8 (o PowerShell 5.1 vai ler como ANSI)")


def conferir_versoes(erros):
    changelog = (RAIZ / "Alloy/CHANGELOG.md").read_text(encoding="utf-8")
    tabela = dict(re.findall(r"^\| ([^|]+?) \| `[^`]+` \| ([0-9.]+) \|$", changelog, re.MULTILINE))
    for componente, fontes in VERSOES.items():
        esperada = tabela.get(componente)
        if not esperada:
            erros.append(f"Alloy/CHANGELOG.md: componente '{componente}' fora da tabela de versões")
            continue
        for arquivo, padrao in fontes:
            texto = (RAIZ / arquivo).read_text(encoding="utf-8-sig")
            achado = re.search(padrao, texto, re.MULTILINE)
            if not achado:
                erros.append(f"{arquivo}: constante de versão não encontrada")
            elif achado.group(1) != esperada:
                erros.append(f"{arquivo}: versão {achado.group(1)}, mas o CHANGELOG diz {esperada} para {componente}")


def main():
    erros = []
    conferir_codificacao(erros)
    conferir_versoes(erros)
    for erro in erros:
        print(f"::error::{erro}")
    if erros:
        print(f"{len(erros)} problema(s) encontrado(s).")
        return 1
    print("Codificação e versões OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
