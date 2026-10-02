# Diagnostico-Windows

Diagnóstico completo de uma máquina Windows para suporte. **Somente leitura**: coleta evidências e aponta os problemas por severidade, sem alterar configuração, registro, serviços nem arquivos do sistema. Grava apenas a pasta de saída e um `.zip`.

Funciona no Windows PowerShell 5.1 (já vem no Windows 10/11). Sem administrador a coleta fica incompleta, por isso o script se reabre elevado sozinho (pede o UAC).

## Uso rápido

Num PowerShell, troque a tag pela versão desejada:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $f="$env:TEMP\Diag.ps1"; iwr 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/diagnostico-windows-v2.0/Diagnostico-Windows/Diagnostico-Windows.ps1' -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Dias 30; ri $f
```

- Depois do aviso do UAC, o script abre uma janela elevada e roda lá. Os parâmetros que você passar vão para ela.
- O relatório vai para `C:\Temp\Diagnóstico\Diagnostico_<PC>_<data>` e um `.zip` ao lado. Abra o `RESUMO.html` primeiro.
- Use sempre uma **tag**, nunca a `main`: assim uma alteração futura no repositório não passa a rodar como administrador nas máquinas dos clientes.

Alternativa por arquivo: baixe os dois arquivos desta pasta e dê duplo clique em `Executar-Diagnostico.bat`.

## Parâmetros

| Parâmetro | Efeito |
|---|---|
| `-Dias N` | Dias de eventos analisados (padrão 7). |
| `-Completo` | Inclui SFC, `powercfg /energy`, msinfo32, WindowsUpdate.log, busca de updates pendentes e medição maior de pastas. Leva cerca de 13 min. |
| `-SemRede` | Pula os testes ativos de conectividade. |
| `-SemDadosSensiveis` | Não coleta log de Segurança, cache DNS, conexões TCP, Wi-Fi (SSID), `whoami /all`, gpresult, contas locais e `dsregcmd` bruto. Use quando o zip sai da empresa. |
| `-OutputPath` | Pasta de saída (padrão `C:\Temp\Diagnóstico`). |
| `-Comparar achados.json` | Mostra o que é novo e o que foi resolvido em relação a uma execução anterior. |
| `-SemZip`, `-NaoAbrir` | Não gera o zip / não abre o relatório ao terminar. |
| `-SemElevar` | Não tenta elevar (coleta incompleta). |

## O que coleta

Sistema e ciclo de vida do Windows, hardware (discos com SMART, RAM, bateria, dispositivos com erro), eventos e logs `.evtx`, telas azuis e travamentos de aplicativos, desempenho e processos (com assinatura digital), serviços, rede (DNS, Wi-Fi, VPN, TLS, proxy), segurança (Defender, BitLocker, TPM, firewall, contas), Windows Update, integridade (DISM, SFC), software instalado, inicialização, Office/OneDrive/Teams, energia, políticas de grupo e identidade (Entra ID/Intune). No fim gera uma linha do tempo única do que mudou e do que falhou.

O relatório lista também as **lacunas de coleta** (o que não foi possível coletar). A ausência de achado nesses itens não prova que estejam saudáveis.

## Confidencialidade

O material pode conter nomes de usuário, programas instalados, redes e logs. Trate o zip como confidencial. Variáveis de ambiente com cara de segredo e senhas em linhas de comando são mascaradas. O relatório **não é enviado a lugar nenhum**: só o script é baixado.

## Verificação de integridade

SHA-256 do `Diagnostico-Windows.ps1` desta versão (v2.0):

```
CEAB3A3349D28CA842F8667CAAA7A209C447C5E41ED499F60676A466740E886E
```

```powershell
(Get-FileHash $env:TEMP\Diag.ps1 -Algorithm SHA256).Hash
```

## Notas

- Salve o `.ps1` sempre em UTF-8 **com BOM** e CRLF (o `.gitattributes` desta pasta impede o Git de converter). Sem o BOM, os acentos quebram no PowerShell 5.1.
- As datas de fim de suporte do Windows ficam numa tabela no script; revise uma vez por ano em https://learn.microsoft.com/lifecycle.
- Clientes com EDR podem bloquear ou alertar sobre o download e a execução de um `.ps1`. Avise a equipe de segurança antes.
