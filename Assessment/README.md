# Assessment

Levantamento completo e **somente leitura** do ambiente de TI de um cliente (servidor, Active Directory, estações, rede e topologia), com relatório em HTML, CSVs e um `.zip`. Roda sem perguntas: dois cliques e, no máximo, um login e senha.

Funciona no Windows PowerShell 5.1. Executar no servidor principal do cliente, de preferência o controlador de domínio.

## Uso rápido

Num PowerShell, no servidor do cliente (troque a tag pela versão desejada):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $f="$env:TEMP\Nextec-Assessment-v2.ps1"; iwr 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/assessment-v2.1/Assessment/Nextec-Assessment-v2.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Automatico
```

- O script se reabre como administrador sozinho (confirme o UAC) e valida o ambiente antes de coletar.
- Se a conta atual não alcançar as estações, abre **uma** janela de login e senha do domínio. A credencial vale só para a execução e não é gravada.
- O resultado vai para `C:\Assessment\<cliente>_<servidor>_<data>` e um `.zip` ao lado. Ao terminar, a pasta abre no Explorer.
- Use sempre uma **tag**, nunca a `main`: assim uma alteração futura no repositório não passa a rodar como administrador nas máquinas dos clientes.

Alternativa por arquivo: baixe os dois arquivos desta pasta, na mesma pasta, e dê duplo clique em `Executar-Assessment.cmd`.

## Parâmetros mais usados

| Parâmetro | Efeito |
|---|---|
| `-Automatico` | Sem perguntas (o `.cmd` já usa). |
| `-SoValidar` | Só a pré-validação do ambiente, sem coletar. |
| `-Cliente "Nome"` | Nome do cliente nos arquivos. Sem ele, usa o domínio. |
| `-Subredes 192.168.0.0/24` | Sub-redes a varrer. Sem ele, detecta sozinho. |
| `-SemVarreduraRede` | Não varre a rede. |
| `-SemInventarioRemoto` | Não consulta as estações. |
| `-SemAD` | Não coleta o Active Directory. |
| `-SemConsultaInternet` | Nenhuma consulta pela internet. |
| `-PedirCredencial` | Abre o login e senha do domínio logo no início. |

Todos os parâmetros e o que é coletado estão no próprio cabeçalho do script (`Get-Help .\Nextec-Assessment-v2.ps1 -Full`).

## Confidencialidade

O material contém nomes de usuário, IPs, softwares e configurações do cliente. Trate a pasta e o `.zip` como confidenciais. O script não altera nada no cliente: grava apenas a pasta de saída e um cache de fabricantes em `%LOCALAPPDATA%\Nextec-Assessment`. As únicas consultas externas são a base de fabricantes da IEEE, o `api.macvendors.com` (só o prefixo do MAC) e o `ipinfo.io`; `-SemConsultaInternet` desliga todas.

## Verificação de integridade

SHA-256 do `Nextec-Assessment-v2.ps1` da tag `assessment-v2.1`:

```
D6BA010BE9CAE0F1AC9F9D5A61386FA2EEA454FB2C09F7A7D0D7E8728C993F58
```

```powershell
(Get-FileHash $env:TEMP\Nextec-Assessment-v2.ps1 -Algorithm SHA256).Hash
```

## Notas

- Salve o `.ps1` sempre em UTF-8 **com BOM** (o `.gitattributes` desta pasta impede o Git de converter). Sem o BOM, os acentos quebram no PowerShell 5.1.
- Clientes com EDR podem alertar sobre o download e a execução de um `.ps1` e sobre a varredura de portas. Avise a equipe de segurança antes.

## Histórico

- **v2.1**: modo sem intervenção (`-Automatico`), pré-validação, login único, relatório separa credencial recusada de máquina desligada.
- **v2.0**: versão de 29/09/2026.
