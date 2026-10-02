# Diagnostico-Windows

Diagnóstico completo de uma máquina Windows para suporte. **Somente leitura**: coleta evidências e aponta os problemas por severidade, sem alterar configuração, registro, serviços nem arquivos do sistema. Grava apenas a pasta de saída e um `.zip`.

Funciona no Windows PowerShell 5.1 (já vem no Windows 10/11). Sem administrador a coleta fica incompleta, por isso o script se reabre elevado sozinho (pede o UAC).

## Uso rápido

Num PowerShell, troque a tag pela versão desejada:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $f="$env:TEMP\Diag.ps1"; iwr 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/diagnostico-windows-v2.1/Diagnostico-Windows/Diagnostico-Windows.ps1' -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Dias 30; ri $f
```

- Depois do aviso do UAC, o script abre uma janela elevada e roda lá. Os parâmetros que você passar vão para ela.
- O relatório vai para `C:\Temp\Diagnóstico\Diagnostico_<PC>_<data>` e um `.zip` ao lado. **Nada abre sozinho**: ao final o script mostra o caminho do `RESUMO.html`.
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
| `-Abrir` | Abre o `RESUMO.html` no navegador ao terminar (por padrão não abre). |
| `-SemZip` | Não gera o `.zip`. |
| `-SemElevar` | Não tenta elevar (coleta incompleta). |

## O que coleta

Sistema e ciclo de vida do Windows, hardware (discos com SMART, RAM, bateria, dispositivos com erro), eventos e logs `.evtx`, telas azuis e travamentos de aplicativos, desempenho e processos (com assinatura digital), serviços, rede (DNS, Wi-Fi, VPN, TLS, proxy), segurança (Defender, BitLocker, TPM, firewall, contas), Windows Update, integridade (DISM, SFC), software instalado, inicialização, Office/OneDrive/Teams, energia, políticas de grupo e identidade (Entra ID/Intune). No fim gera uma linha do tempo única do que mudou e do que falhou.

O relatório lista também as **lacunas de coleta** (o que não foi possível coletar). A ausência de achado nesses itens não prova que estejam saudáveis.

## Análise com o Claude

Depois da coleta, leve o resultado ao Claude e peça a análise. Envie o `RESUMO.txt` (e, se precisar de mais detalhe, o `achados.json` e os arquivos de evidência citados). Sugestão de pedido:

> Analise este diagnóstico de uma máquina Windows. Liste os problemas por ordem de prioridade, explique a causa provável de cada um, o que fazer para corrigir e o que ainda precisa ser verificado. Considere as lacunas de coleta.

Antes de enviar, confira se o material tem dados que o cliente não autoriza compartilhar. Prefira rodar com `-SemDadosSensiveis`.

## Confidencialidade

O material pode conter nomes de usuário, programas instalados, redes e logs. Trate o zip como confidencial. Variáveis de ambiente com cara de segredo e senhas em linhas de comando são mascaradas. O script **não envia nada a lugar nenhum**: só o script é baixado.

## Verificação de integridade

SHA-256 do `Diagnostico-Windows.ps1` desta versão (v2.1):

```
046DD3C18CF62F0F58F88B80DAA1E98F9BCB7AE6D2FA3FBDE24079D42EED04B2
```

```powershell
(Get-FileHash $env:TEMP\Diag.ps1 -Algorithm SHA256).Hash
```

## Notas

- O `RESUMO.html` leva o logo da Nextec embutido (arquivo único, sem requisição externa).
- Salve o `.ps1` sempre em UTF-8 **com BOM** e CRLF (o `.gitattributes` desta pasta impede o Git de converter). Sem o BOM, os acentos quebram no PowerShell 5.1.
- As datas de fim de suporte do Windows ficam numa tabela no script; revise uma vez por ano em https://learn.microsoft.com/lifecycle.
- Clientes com EDR podem bloquear ou alertar sobre o download e a execução de um `.ps1`. Avise a equipe de segurança antes.

## Histórico

- **v2.1**: textos e relatório acentuados; logo da Nextec no `RESUMO.html`; o relatório não abre mais sozinho (`-Abrir` para abrir).
- **v2.0**: primeira versão publicada.
