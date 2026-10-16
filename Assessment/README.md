# Assessment

Levantamento completo e **somente leitura** do ambiente de TI de um cliente (servidor, Active Directory, estações, rede e topologia), com relatório em HTML, CSVs e um `.zip`. Roda sem perguntas: dois cliques e, no máximo, um login e senha.

Funciona no Windows PowerShell 5.1. Executar no servidor principal do cliente, de preferência o controlador de domínio.

## Uso rápido

Num PowerShell **aberto como administrador**, no servidor do cliente (troque a tag pela versão desejada):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $d='C:\ProgramData\Nextec\Assessment'; New-Item -ItemType Directory -Path $d -Force | Out-Null; $f="$d\Nextec-Assessment-v2.ps1"; iwr 'https://raw.githubusercontent.com/Sou-Nextec/Scripts/assessment-v2.8/Assessment/Nextec-Assessment-v2.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Automatico
```

- Sem parâmetros, o script inicia a coleta completa. Exige PowerShell aberto como administrador: se não estiver elevado, avisa e encerra. Depois valida o ambiente antes de coletar.
- A coleta das estações tenta WinRM, DCOM e, como última alternativa, PsExec por SMB/445. Se a conta atual não alcançar as máquinas, abre **uma** janela de login e senha do domínio. A credencial vale só para a execução e não é gravada.
- O inventário consulta todos os computadores habilitados no AD e os Windows prováveis encontrados nas sub-redes locais descobertas. Prefixos maiores que `/22` continuam limitados pelo modo seguro; informe redes roteadas com `-Subredes`.
- A lista de softwares por estação está ligada por padrão; `-SemSoftwareEstacoes` desativa essa coleta. Ela usa WinRM (ou o PsExec, quando a máquina não tem WinRM nem DCOM); máquina inventariada só por DCOM fica sem a lista. `-SoftwareEstacoes` é aceito por compatibilidade, sem efeito.
- O script fica em `C:\ProgramData\Nextec\Assessment\`, a pasta a liberar no antivírus. Se houver antivírus com bloqueio por comportamento, o script avisa logo no início.
- O resultado fica em `C:\Temp\<cliente>_<servidor>_<data>.zip` (mude com `-Saida`). A pasta de trabalho é removida assim que o `.zip` é gerado (se o zip falhar, a pasta é mantida). Ao terminar, o Explorer abre com o `.zip` selecionado.
- Use sempre uma **tag**, nunca a `main`: assim uma alteração futura no repositório não passa a rodar como administrador nas máquinas dos clientes.

Alternativa por arquivo: baixe os dois arquivos desta pasta, na mesma pasta, e execute `Executar-Assessment.cmd` com botão direito, Executar como administrador.

## Parâmetros mais usados

| Parâmetro | Efeito |
|---|---|
| `-Automatico` | Força o fluxo automático; também é o padrão sem parâmetros. |
| `-SoValidar` | Só a pré-validação do ambiente, sem coletar. |
| `-Cliente "Nome"` | Nome do cliente nos arquivos. Sem ele, usa o domínio. |
| `-Subredes 192.168.0.0/24` | Sub-redes a varrer. Sem ele, detecta sozinho. |
| `-SemVarreduraRede` | Não varre a rede. |
| `-SemInventarioRemoto` | Não consulta as estações. |
| `-SemAD` | Não coleta o Active Directory. |
| `-SemConsultaInternet` | Nenhuma consulta pela internet. |
| `-PedirCredencial` | Abre o login e senha do domínio logo no início. |
| `-SemSoftwareEstacoes` | Não coleta o inventário de softwares nas estações. |
| `-SemPsExec` | Desativa o fallback PsExec. |
| `-PsExecPath` | Define o caminho de um PsExec local já assinado pela Microsoft. |
| `-TimeoutPsExecSegundos` | Limite local de espera do PsExec (padrão: 120 segundos). |

Todos os parâmetros e o que é coletado estão no próprio cabeçalho do script (`Get-Help .\Nextec-Assessment-v2.ps1 -Full`).

## Confidencialidade

O material contém nomes de usuário, IPs, softwares e configurações do cliente. Trate a pasta e o `.zip` como confidenciais. A coleta é somente leitura. PsExec, quando necessário, cria um serviço temporário na estação e o remove ao encerrar normalmente; se houver timeout, o encerramento remoto não pode ser confirmado. O executável não é baixado: deve estar instalado localmente (por exemplo, `C:\Tools\PsExec64.exe`) e ter assinatura Microsoft válida. O script grava a pasta de saída e um cache de fabricantes em `%LOCALAPPDATA%\Nextec-Assessment`. As únicas consultas externas são a base de fabricantes da IEEE, o `api.macvendors.com` (só o prefixo do MAC) e o `ipinfo.io`; `-SemConsultaInternet` desliga todas.

## Verificação de integridade

SHA-256 do `Nextec-Assessment-v2.ps1` da tag `assessment-v2.8`:

```
2F17249D5424B73B10E603BABCA39DB45FE38188D1E07826F6373CE9DF475BF4
```

```powershell
(Get-FileHash C:\ProgramData\Nextec\Assessment\Nextec-Assessment-v2.ps1 -Algorithm SHA256).Hash
```

## Notas

- Salve o `.ps1` sempre em UTF-8 **com BOM** (o `.gitattributes` desta pasta impede o Git de converter). Sem o BOM, os acentos quebram no PowerShell 5.1.
- Clientes com EDR podem alertar sobre o download e a execução de um `.ps1` e sobre a varredura de portas. Avise a equipe de segurança antes.

## Histórico

- **v2.8**: memória (pentes, slots e máximo), saúde SMART dos discos (desgaste, temperatura, horas, erros), alerta de servidor sem RAID, RAID por utilitário (storcli/perccli/ssacli/arcconf), link de garantia, alerta de estação no papel de servidor, velocidade/duplex das placas, qualidade do link (latência e perda), DNS em uso e Wi-Fi do ambiente.
- **v2.7**: nome NetBIOS aceita resposta com nome comprimido e a máquina de coleta usa o próprio nome; título das páginas web dos equipamentos sai legível (sem códigos HTML).
- **v2.6**: tela reorganizada: cabeçalho, seções numeradas, uma linha por etapa com tempo e resumo final com alertas por severidade. O `coleta.log` continua completo, com hora e nível.
- **v2.5**: nome NetBIOS consultado direto pela rede (sem `nbtstat.exe`); aviso no início quando há antivírus com bloqueio por comportamento; script em `C:\ProgramData\Nextec\Assessment\` e resultado em `C:\Temp`.
- **v2.4**: o script deixou de se elevar sozinho (sem `RunAs` nem `-EncodedCommand`, que disparavam o antivírus); exige PowerShell aberto como administrador.
- **v2.3**: depois de gerar o `.zip`, a pasta de saída é removida do servidor (só o zip fica).
- **v2.2**: base de fabricantes embutida passou a carregar (antes ficava vazia e o fabricante saía em branco); textos de alerta e da pré-validação mais claros.
- **v2.1**: modo sem intervenção (`-Automatico`), pré-validação, login único, relatório separa credencial recusada de máquina desligada.
- **v2.0**: versão de 29/09/2026.
