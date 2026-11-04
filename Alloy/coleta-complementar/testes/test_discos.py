#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Testes do módulo discos da Coleta Complementar (Linux).

Rodar da raiz do repositório Scripts:
    python3 -m unittest discover -s Alloy/coleta-complementar/testes -v

As saídas em smartctl/ seguem o formato JSON do smartctl 7.4 (-j -a -n standby).
O sysfs é montado numa pasta temporária, então os testes rodam em qualquer
máquina, sem disco físico e sem root.
"""

import configparser
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest

AQUI = os.path.dirname(os.path.abspath(__file__))
SAIDAS = os.path.join(AQUI, "smartctl")
ARQUIVO_COLETA = os.path.join(os.path.dirname(AQUI), "coleta-complementar.py")

spec = importlib.util.spec_from_file_location("coleta_complementar", ARQUIVO_COLETA)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

# Contrato usado pela regra "Disco NVMe com problema" (uid nx-disco-nvme-problema).
CONTRATO = {
    "nextec_disco_smart_ok", "nextec_disco_aviso_critico", "nextec_disco_desgaste_percentual",
    "nextec_disco_erros_midia", "nextec_disco_temperatura_celsius",
    "nextec_disco_link_largura", "nextec_disco_link_largura_max",
}
ROTULOS_CONTRATO = {"disco", "modelo", "serie"}
RE_LINHA = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? (-?[0-9.eE+]+|NaN)$')
RE_ROTULO = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def saida(nome):
    with open(os.path.join(SAIDAS, nome), encoding="utf-8") as arquivo:
        return arquivo.read()


def ler_prom(caminho):
    """{(métrica, frozenset(rótulos)): valor}, validando a sintaxe de cada linha."""
    amostras = {}
    tipos = set()
    with open(caminho, encoding="utf-8") as arquivo:
        texto = arquivo.read()
    assert texto.endswith("\n"), "o .prom precisa terminar com quebra de linha"
    for linha in texto.splitlines():
        if linha.startswith("# TYPE "):
            tipos.add(linha.split()[2])
            continue
        if linha.startswith("#") or not linha:
            continue
        casamento = RE_LINHA.match(linha)
        assert casamento, f"linha inválida no .prom: {linha!r}"
        nome, rotulos, valor = casamento.groups()
        assert nome in tipos, f"{nome} sem # TYPE antes"
        pares = frozenset(RE_ROTULO.findall(rotulos or ""))
        chave = (nome, pares)
        assert chave not in amostras, f"série duplicada: {linha}"
        amostras[chave] = float(valor)
    return amostras


def valor(amostras, nome, disco):
    achados = [v for (n, r), v in amostras.items() if n == nome and ("disco", disco) in r]
    assert len(achados) <= 1
    return achados[0] if achados else None


def rotulos_de(amostras, nome, disco):
    for (n, r), _ in amostras.items():
        if n == nome and ("disco", disco) in r:
            return dict(r)
    return None


class SysFalso:
    """Monta /sys/block e /sys/class/nvme numa pasta temporária."""

    def __init__(self):
        self.raiz = tempfile.mkdtemp(prefix="sys-falso-")
        os.makedirs(os.path.join(self.raiz, "block"))

    def escrever(self, caminho, texto):
        completo = os.path.join(self.raiz, caminho)
        os.makedirs(os.path.dirname(completo), exist_ok=True)
        with open(completo, "w", encoding="utf-8") as arquivo:
            arquivo.write(texto + "\n")

    def disco(self, nome, dispositivo, vendor="", model="", removable="0"):
        """Cria o disco em devices/... e o link /sys/block/<nome>, como no kernel."""
        real = os.path.join(self.raiz, "devices", dispositivo, "block", nome)
        os.makedirs(os.path.join(real, "device"), exist_ok=True)
        for campo, texto in (("vendor", vendor), ("model", model)):
            if texto:
                self.escrever(os.path.join(real, "device", campo), texto)
        self.escrever(os.path.join(real, "removable"), removable)
        os.symlink(real, os.path.join(self.raiz, "block", nome))

    def nvme(self, controlador, atual, maxima):
        self.escrever(f"class/nvme/{controlador}/device/current_link_width", str(atual))
        self.escrever(f"class/nvme/{controlador}/device/max_link_width", str(maxima))

    def remover(self):
        shutil.rmtree(self.raiz, ignore_errors=True)


class EventosFalsos:
    def __init__(self):
        self.registros = []

    def registrar(self, tipo, categoria, evento, nivel="info", **campos):
        self.registros.append(dict(campos, tipo=tipo, categoria=categoria, evento=evento, nivel=nivel))


def config_discos(texto="[discos]\nativo = sim\nintervalo_minutos = 10\n"):
    config = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";", "#"))
    config.optionxform = str
    config.read_string(texto)
    return config


class TesteInterpretacao(unittest.TestCase):
    def test_nvme_saudavel(self):
        leitura = cc.interpretar_smartctl(0, saida("nvme-saudavel.json"))
        self.assertEqual(leitura.erro, "")
        self.assertEqual(cc.valores_disco(leitura.dados), {
            "smart_ok": 1, "aviso_critico": 0, "desgaste_percentual": 0,
            "erros_midia": 0, "temperatura_celsius": 24,
        })

    def test_nvme_com_aviso_critico(self):
        # Bit 3 (8) do código de saída é "SMART reprovado": só aviso, a leitura vale.
        leitura = cc.interpretar_smartctl(8, saida("nvme-aviso-critico.json"))
        self.assertEqual(leitura.erro, "")
        valores = cc.valores_disco(leitura.dados)
        self.assertEqual(valores["smart_ok"], 0)
        self.assertEqual(valores["aviso_critico"], 1)
        self.assertEqual(valores["desgaste_percentual"], 87)
        self.assertEqual(valores["erros_midia"], 12)

    def test_sata_com_setores_realocados(self):
        leitura = cc.interpretar_smartctl(64, saida("sata-realocados.json"))
        valores = cc.valores_disco(leitura.dados)
        self.assertEqual(valores["smart_ok"], 1)
        self.assertEqual(valores["erros_midia"], 8 + 2 + 1)  # atributos 5, 197 e 198
        self.assertEqual(valores["desgaste_percentual"], 7)  # 177: normalizado 93
        self.assertEqual(valores["temperatura_celsius"], 35)
        self.assertIsNone(valores["aviso_critico"])

    def test_vida_util_pelos_atributos_231_e_233(self):
        for ident in (231, 233):
            dados = {"ata_smart_attributes": {"table": [{"id": ident, "value": 60, "raw": {"value": 0}}]}}
            self.assertEqual(cc.valores_disco(dados)["desgaste_percentual"], 40, ident)

    def test_disco_virtual_pelo_smart(self):
        leitura = cc.interpretar_smartctl(4, saida("qemu-virtual.json"))
        self.assertTrue(cc.disco_virtual_smart(leitura.dados))
        self.assertFalse(cc.disco_virtual_smart(json.loads(saida("sata-realocados.json"))))

    def test_smartctl_falhando(self):
        leitura = cc.interpretar_smartctl(2, saida("falha-abrir.json"))
        self.assertIn("No such device", leitura.erro)
        self.assertFalse(leitura.espera)

    def test_volume_de_raid_e_ignorado(self):
        leitura = cc.interpretar_smartctl(2, saida("raid-megaraid.json"))
        self.assertTrue(leitura.erro)
        self.assertTrue(cc.atras_de_controladora(leitura))
        self.assertFalse(cc.atras_de_controladora(cc.interpretar_smartctl(2, saida("falha-abrir.json"))))

    def test_saida_ilegivel(self):
        leitura = cc.interpretar_smartctl(1, "smartctl: opção inválida")
        self.assertIn("ilegível", leitura.erro)

    def test_hd_em_espera_nao_e_erro(self):
        for arquivo in ("hd-em-espera.json", "hd-em-sleep.json"):
            leitura = cc.interpretar_smartctl(3, saida(arquivo))
            self.assertTrue(leitura.espera, arquivo)
            self.assertEqual(leitura.erro, "", arquivo)

    def test_sleep_em_smartctl_sem_codigo_proprio(self):
        # smartctl que devolve 2 em vez do código configurado: vale a mensagem.
        texto = json.dumps({"smartctl": {"messages": [{"string": "Device is in SLEEP mode, exit(2)"}]}})
        self.assertTrue(cc.interpretar_smartctl(2, texto).espera)


class TesteDescoberta(unittest.TestCase):
    def setUp(self):
        self.sys = SysFalso()

    def tearDown(self):
        self.sys.remover()

    def test_ignora_virtuais_e_logicos(self):
        self.sys.disco("nvme0n1", "pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0")
        self.sys.disco("sda", "pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0", vendor="ATA", model="Samsung SSD 870")
        self.sys.disco("vda", "pci0000:00/0000:00:04.0/virtio2")
        self.sys.disco("sdb", "pci0000:00/0000:00:10.0/host2/target2:0:0/2:0:0:0", vendor="VMware", model="Virtual disk")
        self.sys.disco("sdc", "LNXSYSTM:00/VMBUS:00/f8b3781b/host3/target3:0:0/3:0:0:0", vendor="Msft", model="Virtual Disk")
        self.sys.disco("sdd", "pci0000:00/0000:00:14.0/usb1/1-1/host4", vendor="Generic", model="SD Card", removable="1")
        self.sys.disco("nvme9n1", "pci0000:00/0000:00:03.0/0000:03:00.0/nvme/nvme9", model="QEMU NVMe Ctrl")
        self.sys.disco("sde", "pci0000:00/0000:00:1c.0/0000:05:00.0/host5/target5:2:0/5:2:0:0", vendor="DELL", model="PERC H730P Mini")
        for nome in ("dm-0", "loop0", "zram0", "md127", "zd16", "sr0"):
            self.sys.disco(nome, f"virtual/block/{nome}")
        self.assertEqual(cc.discos_fisicos(self.sys.raiz), ["nvme0n1", "sda"])

    def test_largura_do_link_nvme(self):
        self.sys.disco("nvme0n1", "pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0")
        self.sys.nvme("nvme0", 1, 4)
        self.assertEqual(cc.controlador_nvme(self.sys.raiz, "nvme0n1"), "nvme0")
        self.assertEqual(cc.largura_link_nvme(self.sys.raiz, "nvme0"), (1, 4))
        self.assertEqual(cc.largura_link_nvme(self.sys.raiz, "nvme7"), (None, None))

    def test_sem_sys_block(self):
        self.assertEqual(cc.discos_fisicos(os.path.join(self.sys.raiz, "nao-existe")), [])


class TesteRodada(unittest.TestCase):
    """Rodada completa: valida o .prom gravado (nomes, rótulos e valores)."""

    def setUp(self):
        self.sys = SysFalso()
        self.textfile = tempfile.mkdtemp(prefix="textfile-")
        self.eventos = EventosFalsos()
        self.sys.disco("nvme0n1", "pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0")
        self.sys.disco("nvme1n1", "pci0000:00/0000:00:01.2/0000:02:00.0/nvme/nvme1")
        self.sys.disco("sda", "pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0", vendor="ATA")
        self.sys.disco("sdb", "pci0000:00/0000:00:17.0/ata2/host1/target1:0:0/1:0:0:0", vendor="ATA")
        self.sys.disco("sdc", "pci0000:00/0000:00:17.0/ata3/host2/target2:0:0/2:0:0:0", vendor="ATA")
        self.sys.disco("vda", "pci0000:00/0000:00:04.0/virtio2")
        self.sys.nvme("nvme0", 1, 4)
        self.sys.nvme("nvme1", 4, 4)
        self.respostas = {
            "nvme0n1": (0, "nvme-saudavel.json"),
            "nvme1n1": (8, "nvme-aviso-critico.json"),
            "sda": (64, "sata-realocados.json"),
            "sdb": (4, "qemu-virtual.json"),
            "sdc": (2, "falha-abrir.json"),
        }
        self.chamados = []

    def tearDown(self):
        self.sys.remover()
        shutil.rmtree(self.textfile, ignore_errors=True)

    def smartctl_falso(self, nome):
        self.chamados.append(nome)
        codigo, arquivo = self.respostas[nome]
        if arquivo is None:
            raise OSError("dispositivo travado")
        return cc.interpretar_smartctl(codigo, saida(arquivo))

    def modulo(self, varredura=()):
        return cc.ModuloDiscos(config_discos(), self.eventos, None, self.textfile,
                               raiz_sys=self.sys.raiz, smartctl=self.smartctl_falso,
                               varrer=lambda: list(varredura))

    def test_prom_gerado(self):
        modulo = self.modulo()
        self.assertEqual(modulo.intervalo, 600)
        self.assertEqual(modulo.rodada(), 4)  # sdb é virtual (QEMU), vda nem é lido
        self.assertNotIn("vda", self.chamados)

        caminho = os.path.join(self.textfile, "coleta_complementar_discos.prom")
        amostras = ler_prom(caminho)
        self.assertFalse(os.path.exists(caminho + ".tmp"), "gravação deve ser atômica")

        nomes = {n for n, _ in amostras}
        self.assertTrue(CONTRATO <= nomes, CONTRATO - nomes)
        for (nome, rotulos), _ in amostras.items():
            if nome in CONTRATO:
                self.assertEqual({k for k, _ in rotulos}, ROTULOS_CONTRATO, nome)

        self.assertEqual(rotulos_de(amostras, "nextec_disco_smart_ok", "nvme0n1"),
                         {"disco": "nvme0n1", "modelo": "Lexar NM790 SSD 1TB", "serie": "RC9381Z001575P2202"})
        esperado = {
            ("nvme0n1", "smart_ok"): 1, ("nvme0n1", "aviso_critico"): 0, ("nvme0n1", "desgaste_percentual"): 0,
            ("nvme0n1", "erros_midia"): 0, ("nvme0n1", "temperatura_celsius"): 24,
            ("nvme0n1", "link_largura"): 1, ("nvme0n1", "link_largura_max"): 4,
            ("nvme1n1", "smart_ok"): 0, ("nvme1n1", "aviso_critico"): 1, ("nvme1n1", "desgaste_percentual"): 87,
            ("nvme1n1", "erros_midia"): 12, ("nvme1n1", "link_largura"): 4, ("nvme1n1", "link_largura_max"): 4,
            ("sda", "smart_ok"): 1, ("sda", "erros_midia"): 11, ("sda", "desgaste_percentual"): 7,
            ("sda", "temperatura_celsius"): 35,
        }
        for (disco, chave), numero in esperado.items():
            self.assertEqual(valor(amostras, f"nextec_disco_{chave}", disco), numero, (disco, chave))

        # SATA não tem aviso crítico nem link PCIe; virtual não aparece; falha fica só em leitura_ok.
        self.assertIsNone(valor(amostras, "nextec_disco_aviso_critico", "sda"))
        self.assertIsNone(valor(amostras, "nextec_disco_link_largura", "sda"))
        self.assertIsNone(valor(amostras, "nextec_disco_leitura_ok", "sdb"))
        self.assertIsNone(valor(amostras, "nextec_disco_smart_ok", "sdb"))
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "sdc"), 0)
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "sda"), 1)
        self.assertIsNone(valor(amostras, "nextec_disco_smart_ok", "sdc"))
        self.assertEqual(amostras[("nextec_discos_encontrados", frozenset())], 4)

    def test_falha_vira_evento_uma_vez_e_volta(self):
        modulo = self.modulo()
        modulo.rodada()
        modulo.rodada()
        falhas = [e for e in self.eventos.registros if e["evento"] == "disco_sem_resposta"]
        self.assertEqual(len(falhas), 1, "a mesma falha não deve repetir o evento a cada rodada")
        self.assertEqual(falhas[0]["disco"], "sdc")
        self.assertEqual(falhas[0]["tipo"], "disco_evento")
        self.assertIn("No such device", falhas[0]["detalhe"])

        self.respostas["sdc"] = (64, "sata-realocados.json")
        modulo.rodada()
        voltas = [e for e in self.eventos.registros if e["evento"] == "disco_voltou"]
        self.assertEqual([e["disco"] for e in voltas], ["sdc"])

    def test_excecao_em_um_disco_nao_para_a_rodada(self):
        self.respostas["nvme1n1"] = (0, None)
        modulo = self.modulo()
        modulo.rodada()
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "nvme1n1"), 0)
        self.assertEqual(valor(amostras, "nextec_disco_smart_ok", "nvme0n1"), 1)

    def test_todos_falhando_marca_modulo_com_erro(self):
        for nome in self.respostas:
            self.respostas[nome] = (2, "falha-abrir.json")
        with self.assertRaises(RuntimeError):
            self.modulo().rodada()
        # Mesmo assim grava o arquivo, para o NOC ver leitura_ok = 0.
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "nvme0n1"), 0)

    def test_hd_em_espera_repete_ultima_leitura(self):
        modulo = self.modulo()
        modulo.rodada()
        self.respostas["sda"] = (3, "hd-em-sleep.json")
        modulo.rodada()
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_erros_midia", "sda"), 11)
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "sda"), 1)

    def test_codigo_4_sem_dados_vira_falha(self):
        self.respostas["sda"] = (4, "sata-sem-dados.json")
        modulo = self.modulo()
        modulo.rodada()
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "sda"), 0)
        self.assertIsNone(valor(amostras, "nextec_disco_smart_ok", "sda"))
        falha = next(e for e in self.eventos.registros if e["evento"] == "disco_sem_resposta" and e["disco"] == "sda")
        self.assertIn("código 4", falha["detalhe"])
        self.assertIn("SMART Status command failed", falha["detalhe"])

    def test_codigo_4_com_dados_parciais_mantem_o_que_veio(self):
        self.respostas["sda"] = (4, "sata-status-falhou.json")
        modulo = self.modulo()
        modulo.rodada()
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "sda"), 1)
        self.assertIsNone(valor(amostras, "nextec_disco_smart_ok", "sda"))
        self.assertEqual(valor(amostras, "nextec_disco_erros_midia", "sda"), 11)
        self.assertEqual(valor(amostras, "nextec_disco_temperatura_celsius", "sda"), 35)

    def test_volume_de_raid_nao_vira_falha(self):
        self.respostas["sdc"] = (2, "raid-megaraid.json")
        modulo = self.modulo()
        self.assertEqual(modulo.rodada(), 3)
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertIsNone(valor(amostras, "nextec_disco_leitura_ok", "sdc"))
        self.assertEqual([e for e in self.eventos.registros if e["evento"] == "disco_sem_resposta"], [])

    def test_espera_a_coleta_avulsa_sair(self):
        avulso = os.path.join(self.textfile, "smart.prom")
        with open(avulso, "w", encoding="utf-8") as arquivo:
            arquivo.write('nextec_disco_smart_ok{disco="nvme0n1",modelo="x",serie="y"} 1\n')
        modulo = self.modulo()
        self.assertEqual(modulo.rodada(), 0)
        caminho = os.path.join(self.textfile, "coleta_complementar_discos.prom")
        self.assertFalse(os.path.exists(caminho), "não pode duplicar as séries da coleta avulsa")
        self.assertEqual(self.chamados, [])
        os.remove(avulso)
        self.assertEqual(modulo.rodada(), 4)
        self.assertTrue(os.path.exists(caminho))

    def test_discos_atras_da_controladora_raid(self):
        # Servidor Dell: o volume do PERC (sde) fica de fora e os discos entram pela controladora.
        self.sys.disco("sde", "pci0000:00/0000:00:1c.0/0000:05:00.0/host5/target5:2:0/5:2:0:0",
                       vendor="DELL", model="PERC H730P Mini")
        self.respostas["megaraid_disk_00"] = (0, "sata-realocados.json")
        self.respostas["megaraid_disk_01"] = (2, "falha-abrir.json")
        varredura = cc.interpretar_varredura(saida("varredura-megaraid.json"))
        modulo = self.modulo(varredura)
        self.assertEqual(modulo.rodada(), 7)
        self.assertNotIn("sde", self.chamados)
        amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
        self.assertEqual(valor(amostras, "nextec_disco_erros_midia", "megaraid_disk_00"), 11)
        self.assertEqual(rotulos_de(amostras, "nextec_disco_smart_ok", "megaraid_disk_00")["modelo"],
                         "Samsung SSD 870 EVO 500GB")
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "megaraid_disk_01"), 0)
        self.assertEqual(modulo.alvos["megaraid_disk_00"], ("/dev/bus/0", "megaraid,0", ""))
        # Disco que a varredura não abriu: falha visível, sem chamar o smartctl.
        self.assertEqual(valor(amostras, "nextec_disco_leitura_ok", "megaraid_disk_02"), 0)
        self.assertNotIn("megaraid_disk_02", self.chamados)
        falhas = [e for e in self.eventos.registros if e["evento"] == "disco_sem_resposta"]
        self.assertIn("INQUIRY failed", next(e["detalhe"] for e in falhas if e["disco"] == "megaraid_disk_02"))

    def test_vm_sem_disco_fisico(self):
        vazio = SysFalso()
        try:
            vazio.disco("vda", "pci0000:00/0000:00:04.0/virtio2")
            modulo = cc.ModuloDiscos(config_discos(), self.eventos, None, self.textfile,
                                     raiz_sys=vazio.raiz, smartctl=self.smartctl_falso, varrer=list)
            self.assertEqual(modulo.rodada(), 0)
            amostras = ler_prom(os.path.join(self.textfile, "coleta_complementar_discos.prom"))
            self.assertEqual(amostras[("nextec_discos_encontrados", frozenset())], 0)
        finally:
            vazio.remover()


class TesteControladora(unittest.TestCase):
    def test_varredura_megaraid(self):
        self.assertEqual(cc.interpretar_varredura(saida("varredura-megaraid.json")), [
            ("megaraid_disk_00", "/dev/bus/0", "megaraid,0", ""),
            ("megaraid_disk_01", "/dev/bus/0", "megaraid,1", ""),
            ("megaraid_disk_02", "/dev/bus/0", "megaraid,2", "/dev/bus/0 [megaraid_disk_02]: INQUIRY failed"),
        ])

    def test_varredura_real_do_hv01_sem_controladora(self):
        # Saída real do nxt-srv-hv01 (smartctl 7.5): só NVMe direto, que já vem do /sys/block.
        self.assertEqual(cc.interpretar_varredura(saida("varredura-hv01.json")), [])

    def test_varredura_com_duas_controladoras(self):
        texto = json.dumps({"devices": [
            {"name": "/dev/bus/0", "info_name": "/dev/bus/0 [megaraid_disk_00]", "type": "megaraid,0"},
            {"name": "/dev/bus/1", "info_name": "/dev/bus/1 [megaraid_disk_00]", "type": "megaraid,0"},
            {"name": "/dev/sg1", "info_name": "/dev/sg1", "type": "cciss,3"},
        ]})
        self.assertEqual([r for r, _, _, _ in cc.interpretar_varredura(texto)],
                         ["megaraid_disk_00_0", "megaraid_disk_00_1", "sg1_cciss_3"])

    def test_varredura_ilegivel(self):
        self.assertEqual(cc.interpretar_varredura("não é json"), [])
        self.assertEqual(cc.discos_controladora(""), [])

    def test_comando_usa_o_tipo_da_controladora(self):
        chamadas = []

        class Resultado:
            returncode = 0
            stdout = saida("sata-realocados.json")

        original = cc.subprocess.run
        cc.subprocess.run = lambda comando, **_: chamadas.append(comando) or Resultado()
        try:
            cc.rodar_smartctl("/usr/sbin/smartctl", "/dev/bus/0", "megaraid,0")
            cc.rodar_smartctl("/usr/sbin/smartctl", "/dev/sda")
        finally:
            cc.subprocess.run = original
        self.assertEqual(chamadas, [
            ["/usr/sbin/smartctl", "-j", "-a", "-n", "standby,3", "-d", "megaraid,0", "/dev/bus/0"],
            ["/usr/sbin/smartctl", "-j", "-a", "-n", "standby,3", "/dev/sda"],
        ])


class TesteLigarModulo(unittest.TestCase):
    def test_desligado_sem_smartctl(self):
        config = config_discos("[internet]\nativo = nao\n[discos]\nativo = sim\nsmartctl = /caminho/que/nao/existe\n")
        self.assertNotIn("discos", cc.modulos_ligados(config))
        self.assertTrue(cc.discos_pedido(config))

    def test_ligado_com_smartctl(self):
        pasta = tempfile.mkdtemp()
        try:
            binario = os.path.join(pasta, "smartctl")
            with open(binario, "w", encoding="utf-8") as arquivo:
                arquivo.write("#!/bin/sh\nexit 0\n")
            os.chmod(binario, 0o755)
            config = config_discos(f"[internet]\nativo = nao\n[discos]\nativo = sim\nsmartctl = {binario}\n")
            self.assertIn("discos", cc.modulos_ligados(config))
        finally:
            shutil.rmtree(pasta, ignore_errors=True)

    def test_ativo_nao(self):
        self.assertNotIn("discos", cc.modulos_ligados(config_discos("[discos]\nativo = nao\n")))

    def test_intervalo_minimo(self):
        modulo = cc.ModuloDiscos(config_discos("[discos]\nintervalo_minutos = 1\n"), None, None, tempfile.gettempdir())
        self.assertEqual(modulo.intervalo, 300)


if __name__ == "__main__":
    unittest.main()
