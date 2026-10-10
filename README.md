# Scripts

## Instalador de monitoramento Windows

Executar em PowerShell como Administrador, direto do GitHub:

```powershell
$u = "https://raw.githubusercontent.com/Sou-Nextec/Scripts/main/Alloy/install-nextec-monitoring-windows-v2.ps1"
& ([scriptblock]::Create((irm $u).TrimStart([char]0xFEFF)))
```

Parâmetros vão no fim da segunda linha, por exemplo `-Simular` (abre as telas sem instalar nada) ou `-Console`.

O `TrimStart([char]0xFEFF)` é obrigatório: os `.ps1` do repositório são gravados em UTF-8 com BOM, e sem remover o BOM o PowerShell recusa o script com `Unexpected attribute 'CmdletBinding'`.

## Assessment Nextec

Levantamento completo e somente leitura do ambiente de TI de um cliente (servidor, AD, estações, rede e topologia), sem intervenção. Comando de execução, parâmetros e verificação de integridade em [Assessment/README.md](Assessment/README.md).
