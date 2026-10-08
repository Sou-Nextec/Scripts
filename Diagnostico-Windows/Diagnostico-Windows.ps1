<#
.SYNOPSIS
    Diagnóstico completo de uma máquina Windows: coleta evidências de sistema,
    hardware, eventos, falhas, rede, segurança, updates e software.

.DESCRIPTION
    Gera uma pasta com todas as evidências (txt, csv, evtx, html) e um
    RESUMO.html com os achados classificados por severidade. No final
    compacta tudo em um .zip pronto para enviar/analisar.

    Execute como Administrador para coleta completa (SMART, BitLocker,
    log de Segurança, DISM, etc). Sem admin o script roda, mas com lacunas.

.PARAMETER OutputPath
    Pasta onde o diagnóstico será salvo. Padrão: C:\Temp\Diagnóstico (criada se não existir).

.PARAMETER Dias
    Quantos dias de eventos analisar. Padrão: 7.

.PARAMETER Completo
    Inclui coletas demoradas: SFC /verifyonly, powercfg /energy (60s),
    msinfo32, Get-WindowsUpdateLog e busca de updates pendentes.

.PARAMETER SemRede
    Pula testes ativos de conectividade (ping, DNS, portas).

.PARAMETER SemZip
    Não gera o arquivo .zip no final.

.PARAMETER Abrir
    Abre o RESUMO.html no navegador ao terminar. Por padrão não abre: o caminho do relatório é mostrado no final.

.PARAMETER SemDadosSensiveis
    Não coleta: log de Segurança, cache DNS, conexões TCP, Wi-Fi (SSID), whoami /all,
    gpresult, contas locais e dsregcmd bruto. Use quando o zip vai sair da empresa/cliente.

.PARAMETER Comparar
    Caminho de um achados.json de uma execução anterior. O RESUMO mostra o que e novo
    e o que foi resolvido desde então.

.PARAMETER SemElevar
    Por padrão, se não estiver como Administrador o script se reabre elevado (pede o UAC) com os mesmos
    parametros. Use -SemElevar para rodar sem elevar (coleta incompleta).

.PARAMETER ApagarScriptAoFinal
    Uso interno do Executar-Diagnostico.bat: remove a cópia temporaria do script ao terminar.

.NOTES
    Somente leitura: não altera configuração, registro, serviços nem arquivos do sistema.
    Grava apenas a pasta de saída e o .zip. O zip pode conter dados pessoais (nomes de
    usuário, programas, redes); trate-o como confidencial.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnostico-Windows.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnostico-Windows.ps1 -Dias 30 -Completo
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\Temp\Diagnóstico',
    [ValidateRange(1, 365)][int]$Dias = 7,
    [switch]$Completo,
    [switch]$SemRede,
    [switch]$SemZip,
    [switch]$Abrir,
    [switch]$SemDadosSensiveis,
    [switch]$SemElevar,
    [string]$Comparar,
    [switch]$ApagarScriptAoFinal
)

# Auto-elevacao: sem administrador a coleta fica incompleta. Reabre uma copia do script elevada (pede o UAC)
# com os mesmos parametros. A copia fica em pasta local porque a sessao elevada nao enxerga unidades de rede
# mapeadas, e se apaga ao terminar. Se o UAC for recusado, segue sem elevar.
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin -and -not $SemElevar -and $PSCommandPath) {
    try {
        $copia = Join-Path $env:PUBLIC 'Diagnostico-Windows-run.ps1'
        Copy-Item -LiteralPath $PSCommandPath -Destination $copia -Force -ErrorAction Stop
        $aspas = [char]34
        $lista = New-Object System.Collections.Generic.List[string]
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -in 'SemElevar', 'ApagarScriptAoFinal') { continue }
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) { if ($v.IsPresent) { $lista.Add("-$k") } }
            else { $lista.Add("-$k"); $lista.Add("$aspas$v$aspas") }
        }
        $linha = '-NoProfile -ExecutionPolicy Bypass -NoExit -File {0}{1}{0} -SemElevar -ApagarScriptAoFinal {2}' -f $aspas, $copia, ($lista.ToArray() -join ' ')
        Write-Host 'Reabrindo como Administrador (confirme o aviso do UAC)...' -ForegroundColor Yellow
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $linha -ErrorAction Stop
        return
    } catch {
        Write-Warning "Não foi possível elevar ($($_.Exception.Message)). Seguindo sem administrador: a coleta ficará incompleta."
    }
}

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
# Se o script foi chamado de dentro do PowerShell 7, o PSModulePath herdado aponta para modulos que o
# Windows PowerShell 5.1 nao consegue carregar. Vale so para este processo.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $caminhosModulo = @($env:PSModulePath -split ';' | Where-Object { $_ -match 'WindowsPowerShell' })
    if ($caminhosModulo.Count) { $env:PSModulePath = $caminhosModulo -join ';' }
}
$script:Versao         = '2.1.1'
$script:Rotulo         = @{ CRITICO = 'CRÍTICO'; ALTO = 'ALTO'; MEDIO = 'MÉDIO'; BAIXO = 'BAIXO'; INFO = 'INFO' }
$script:Inicio         = Get-Date
$script:DesdeData      = (Get-Date).AddDays(-$Dias)

# ---------------------------------------------------------------------------
# Preparação
# ---------------------------------------------------------------------------
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$carimbo      = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:Raiz  = Join-Path $OutputPath ("Diagnostico_{0}_{1}" -f $env:COMPUTERNAME, $carimbo)
# wevtutil e outras ferramentas falham com caminhos acima de 260 caracteres (Desktop no OneDrive, pasta profunda)
if (($script:Raiz.Length + 110) -gt 255) {
    $OutputPath = Join-Path $env:PUBLIC 'Diagnostico'
    $script:Raiz = Join-Path $OutputPath ("Diagnostico_{0}_{1}" -f $env:COMPUTERNAME, $carimbo)
    Write-Warning "Caminho de saída muito longo; usando $OutputPath"
}
$pastas = '01_Sistema', '02_Hardware', '03_Eventos', '04_Falhas', '05_Desempenho',
          '06_Servicos', '07_Rede', '08_Seguranca', '09_Updates', '10_Integridade',
          '11_Software', '12_Energia', '13_Politicas'
foreach ($p in $pastas) { New-Item -ItemType Directory -Path (Join-Path $script:Raiz $p) -Force | Out-Null }

$script:LogFile  = Join-Path $script:Raiz '_execucao.log'
$script:Achados  = New-Object System.Collections.Generic.List[object]
$script:Etapas   = New-Object System.Collections.Generic.List[object]
$script:Lacunas  = New-Object System.Collections.Generic.List[object]
$script:EtapaAtual = ''
$script:MinidumpsRecentes = 0
$script:Travamentos = @()

# ---------------------------------------------------------------------------
# Funções auxiliares
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Nivel = 'INFO')
    $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Nivel, $Msg
    Add-Content -Path $script:LogFile -Value $linha -Encoding UTF8
    $cor = switch ($Nivel) { 'ERRO' { 'Red' } 'AVISO' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $linha -ForegroundColor $cor
}

function Add-Achado {
    <# Severidade: CRITICO, ALTO, MEDIO, BAIXO, INFO #>
    param(
        [ValidateSet('CRITICO', 'ALTO', 'MEDIO', 'BAIXO', 'INFO')][string]$Severidade,
        [string]$Categoria,
        [string]$Titulo,
        [string]$Detalhe = '',
        [string]$Evidencia = ''
    )
    $ordem = @{ CRITICO = 0; ALTO = 1; MEDIO = 2; BAIXO = 3; INFO = 4 }[$Severidade]
    $script:Achados.Add([pscustomobject]@{
        Ordem = $ordem; Severidade = $Severidade; Categoria = $Categoria
        Titulo = $Titulo; Detalhe = $Detalhe; Evidencia = $Evidencia
    })
    $nivelLog = if ($ordem -le 1) { 'AVISO' } else { 'INFO' }
    Write-Log ("ACHADO [{0}] {1}: {2}" -f $script:Rotulo[$Severidade], $Categoria, $Titulo) $nivelLog
}

function Invoke-Etapa {
    <# Executa um bloco isolado: erro em uma etapa nunca derruba o script. #>
    param([string]$Nome, [scriptblock]$Bloco)
    Write-Log "Iniciando: $Nome"
    $script:EtapaAtual = $Nome
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $status = 'OK'; $erro = ''
    try { & $Bloco }
    catch {
        $status = 'FALHOU'; $erro = $_.Exception.Message
        Write-Log "Falha em '$Nome': $erro" 'ERRO'
    }
    $sw.Stop()
    $script:Etapas.Add([pscustomobject]@{
        Etapa = $Nome; Status = $status; Segundos = [math]::Round($sw.Elapsed.TotalSeconds, 1); Erro = $erro
    })
}

function Save-Texto {
    param([string]$Pasta, [string]$Arquivo, $Conteudo)
    $destino = Join-Path (Join-Path $script:Raiz $Pasta) $Arquivo
    $Conteudo | Out-String -Width 4096 | Out-File -FilePath $destino -Encoding UTF8
}

function Save-Csv {
    param([string]$Pasta, [string]$Arquivo, $Dados)
    $destino = Join-Path (Join-Path $script:Raiz $Pasta) $Arquivo
    if ($null -eq $Dados) { 'Sem dados' | Out-File $destino -Encoding UTF8; return }
    $Dados | Export-Csv -Path $destino -NoTypeInformation -Encoding UTF8 -Delimiter ';'
}

function Add-Lacuna {
    <# Registra algo que NAO foi coletado (sem permissao, comando ausente, timeout). Aparece no RESUMO. #>
    param([string]$Item, [string]$Motivo)
    $script:Lacunas.Add([pscustomobject]@{ Etapa = $script:EtapaAtual; Item = $Item; Motivo = $Motivo })
    Write-Log ("LACUNA em '{0}': {1} ({2})" -f $script:EtapaAtual, $Item, $Motivo) 'AVISO'
}

function Invoke-Externo {
    <# Roda comando de console com timeout e salva a saída em arquivo. Registra lacuna se falhar. #>
    param([string]$Pasta, [string]$Arquivo, [string]$Comando, [int]$TimeoutSeg = 120)
    $destino = Join-Path (Join-Path $script:Raiz $Pasta) $Arquivo
    $argLinha = '/d /c chcp 65001 >nul & {0} > "{1}" 2>&1' -f $Comando, $destino
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList $argLinha `
        -WindowStyle Hidden -PassThru
    if (-not $proc.WaitForExit($TimeoutSeg * 1000)) {
        # Mata a arvore inteira: matar so o cmd deixaria o filho rodando e segurando o arquivo.
        & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F *> $null
        Start-Sleep -Milliseconds 300
        try { Add-Content -Path $destino -Value "`r`n*** TIMEOUT após $TimeoutSeg s ***" -Encoding UTF8 } catch { }
        Add-Lacuna $Arquivo "timeout de $TimeoutSeg s"
        return $null
    }
    if (Test-Path -LiteralPath $destino) {
        $ini = Get-Content -LiteralPath $destino -TotalCount 15 -Encoding UTF8 -ErrorAction SilentlyContinue | Out-String
        if ($ini -match '(?im)n.o . reconhecido|is not recognized|Acesso negado|Access is denied|requer privil|requires elevation|requer eleva|^(Erro|Error)\b') {
            Add-Lacuna $Arquivo ((($ini -replace '\s+', ' ').Trim()) -replace '^(.{140}).*', '$1...')
        }
    }
    return $proc.ExitCode
}

function Get-EventosSeguro {
    <# Get-WinEvent que devolve vazio quando nao ha eventos e registra lacuna quando falha de verdade. #>
    param([hashtable]$Filtro, [int]$Max = 5000)
    try { Get-WinEvent -FilterHashtable $Filtro -MaxEvents $Max -ErrorAction Stop }
    catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound|NoMatchingLogsFound|LogsAndProvidersDontOverlap') {
            Add-Lacuna ("log " + $Filtro.LogName) $_.Exception.Message
        }
        @()
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}


$script:RegexVirtuais = 'Virtual|VPN|TAP|Hyper-V|VMware|VirtualBox|Npcap|Loopback|WAN Miniport|Bluetooth|Wintun|WireGuard|ZeroTier|Tailscale|Docker|vEthernet'

function Remove-Segredo {
    <# Mascara senhas/tokens que aparecem em linhas de comando e argumentos. #>
    param([string]$Texto)
    if (-not $Texto) { return $Texto }
    $t = $Texto -replace '(?i)((?:password|passwd|pwd|pass|senha|token|secret|apikey|api-key|api_key|key|credential|auth)\w*\s*[=:]\s*)("[^"]*"|\S+)', '$1***'
    $t = $t -replace '(?i)(\s[-/]{1,2}(?:password|passwd|pwd|pass|senha|token|secret|apikey|key)\s+)("[^"]*"|\S+)', '$1***'
    return $t
}

function Get-TamanhoPasta {
    <# Soma o tamanho de uma pasta com limite de tempo (nao quebra em pasta sem permissao). #>
    param([string]$Caminho, [int]$LimiteSeg = 25)
    if (-not (Test-Path -LiteralPath $Caminho -ErrorAction SilentlyContinue)) { return $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = [int64]0; $arqs = 0; $completo = $true
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($Caminho)
    while ($pilha.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $LimiteSeg) { $completo = $false; break }
        $dir = $pilha.Pop()
        try {
            $di = New-Object IO.DirectoryInfo $dir
            foreach ($f in $di.EnumerateFiles()) { $total += $f.Length; $arqs++ }
            foreach ($s in $di.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pilha.Push($s.FullName) }
            }
        } catch { }
    }
    [pscustomobject]@{ Caminho = $Caminho; Bytes = $total; Tamanho = (Format-Bytes $total); Arquivos = $arqs; Completo = $completo }
}

function Test-Porta {
    <# Teste TCP com timeout (independente de Test-NetConnection, que e lento e faz ping junto). #>
    param([string]$Alvo, [int]$Porta, [int]$TimeoutMs = 4000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cli = New-Object Net.Sockets.TcpClient
    try {
        $ar = $cli.BeginConnect($Alvo, $Porta, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { try { $cli.EndConnect($ar) } catch { $ok = $false } }
        $ip = ''
        if ($ok) { $ip = $cli.Client.RemoteEndPoint.Address.ToString() }
        [pscustomobject]@{ Host = $Alvo; Porta = $Porta; Aberta = [bool]$ok; Ms = $sw.ElapsedMilliseconds; IP = $ip }
    } catch {
        [pscustomobject]@{ Host = $Alvo; Porta = $Porta; Aberta = $false; Ms = $sw.ElapsedMilliseconds; IP = '' }
    } finally { $cli.Close() }
}

$script:CimFalhas = @{}

function Get-CimSeguro {
    <# Get-CimInstance que nao derruba a etapa quando o repositorio WMI esta corrompido
       (HRESULT 0x80041010 "Classe inválida", provider ausente etc). Devolve $null e registra a lacuna uma vez por classe.
       Com -ErrorAction Stop o erro e repassado (para quem ja trata com try/catch). #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ClassName,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter,
        [switch]$Silencioso
    )
    $param = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
    if ($Filter) { $param.Filter = $Filter }
    try { Get-CimInstance @param }
    catch {
        $chave = "$Namespace\$ClassName"
        $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
        $primeira = -not $script:CimFalhas.ContainsKey($chave)
        if ($primeira) { $script:CimFalhas[$chave] = $msg }
        if ("$($PSBoundParameters['ErrorAction'])" -eq 'Stop') { throw }
        if ($primeira -and -not $Silencioso) { Add-Lacuna "WMI $chave" $msg }
        return $null
    }
}

function Get-MemoriaFallback {
    <# Memoria fisica sem WMI (Microsoft.VisualBasic.Devices.ComputerInfo). Devolve TotalKB e LivreKB, ou $null. #>
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
        [pscustomobject]@{ TotalKB = [double]$ci.TotalPhysicalMemory / 1KB; LivreKB = [double]$ci.AvailablePhysicalMemory / 1KB }
    } catch { $null }
}

function Get-DadosSistemaSemWmi {
    <# Monta objetos equivalentes a Win32_OperatingSystem / ComputerSystem / BIOS lendo registro e .NET,
       para o diagnostico continuar util quando o WMI esta quebrado. #>
    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $bz = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
    $ip = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction SilentlyContinue
    $nl = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -ErrorAction SilentlyContinue
    $instalado = $null
    if ($nt.InstallDate) {
        try { $instalado = ([datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)).AddSeconds([double]$nt.InstallDate).ToLocalTime() } catch { }
    }
    $boot = $null
    try { $boot = (Get-Process -Id 4 -ErrorAction Stop).StartTime } catch { }
    $mem = Get-MemoriaFallback
    $dominio = $nl.DomainName
    $versao = if ($nt.CurrentMajorVersionNumber) { '{0}.{1}.{2}' -f $nt.CurrentMajorVersionNumber, $nt.CurrentMinorVersionNumber, $nt.CurrentBuildNumber } else { '{0}.{1}' -f $nt.CurrentVersion, $nt.CurrentBuildNumber }
    [pscustomobject]@{
        OS = [pscustomobject]@{
            Caption = $nt.ProductName; Version = $versao; BuildNumber = $nt.CurrentBuildNumber
            OSArchitecture = $(if ([Environment]::Is64BitOperatingSystem) { '64 bits' } else { '32 bits' })
            InstallDate = $instalado; LastBootUpTime = $boot
        }
        CS = [pscustomobject]@{
            Domain = $(if ($dominio) { $dominio } else { $ip.Domain }); PartOfDomain = [bool]$dominio
            Manufacturer = $bz.SystemManufacturer; Model = $bz.SystemProductName
            TotalPhysicalMemory = $(if ($mem) { $mem.TotalKB * 1KB } else { 0 })
        }
        BIOS = [pscustomobject]@{ SerialNumber = '(indisponível sem WMI)'; SMBIOSBIOSVersion = $bz.BIOSVersion; ReleaseDate = $bz.BIOSReleaseDate }
    }
}

function Get-UsuarioAlvo {
    <# Descobre o usuario que esta usando a maquina (quem abriu o explorer.exe), mesmo que o script
       tenha sido elevado com outra conta. Dados por usuario (registro HKCU, perfil) vem dele. #>
    $atual = [Security.Principal.WindowsIdentity]::GetCurrent()
    $res = [pscustomobject]@{ Nome = $atual.Name; SID = $atual.User.Value; Perfil = $env:USERPROFILE
        Origem = 'usuário do processo'; HKU = "Registry::HKEY_USERS\$($atual.User.Value)"; Outro = $false }
    try {
        $console = (Get-CimSeguro Win32_ComputerSystem -ErrorAction Stop).UserName
        $cands = foreach ($p in (Get-CimSeguro Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
            $own = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($sid) { [pscustomobject]@{ SID = $sid; Nome = "$($own.Domain)\$($own.User)" } }
        }
        $alvo = $cands | Where-Object { $_.Nome -eq $console } | Select-Object -First 1
        if (-not $alvo) { $alvo = $cands | Select-Object -First 1 }
        if ($alvo) {
            $perfil = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($alvo.SID)" -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $perfil) { $perfil = $env:USERPROFILE }
            $res = [pscustomobject]@{ Nome = $alvo.Nome; SID = $alvo.SID; Perfil = $perfil
                Origem = 'usuário logado (explorer.exe)'; HKU = "Registry::HKEY_USERS\$($alvo.SID)"
                Outro = ($alvo.SID -ne $atual.User.Value) }
        }
    } catch {
        # Sem WMI: tenta o dono do explorer.exe pelo proprio Get-Process (precisa de administrador)
        try {
            $exp = Get-Process -Name explorer -IncludeUserName -ErrorAction Stop | Select-Object -First 1
            if ($exp -and $exp.UserName) {
                $sid = (New-Object Security.Principal.NTAccount($exp.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
                $perfil = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
                if (-not $perfil) { $perfil = $env:USERPROFILE }
                $res = [pscustomobject]@{ Nome = $exp.UserName; SID = $sid; Perfil = $perfil
                    Origem = 'usuário logado (explorer.exe, sem WMI)'; HKU = "Registry::HKEY_USERS\$sid"
                    Outro = ($sid -ne $atual.User.Value) }
            }
        } catch { }
    }
    return $res
}
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  DIAGNÓSTICO COMPLETO DO WINDOWS' -ForegroundColor Cyan
Write-Host "  Máquina : $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  Período : últimos $Dias dias" -ForegroundColor Cyan
Write-Host "  Saída   : $script:Raiz" -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''

if (-not $script:IsAdmin) {
    Write-Log 'Script NÃO está rodando como Administrador. Várias coletas ficarão incompletas.' 'AVISO'
    Add-Achado -Severidade MEDIO -Categoria 'Execução' -Titulo 'Diagnóstico executado sem privilégios de administrador' `
        -Detalhe 'SMART, BitLocker, log de Segurança, DISM e alguns eventos não foram coletados. Rode novamente como Administrador.'
}

# Saude do WMI: varias coletas (hardware, servicos, desempenho) dependem dele. Se estiver quebrado, o script
# usa fontes alternativas (registro, .NET, Get-Service) e registra o problema como achado.
$null = Get-CimSeguro Win32_OperatingSystem -Silencioso -ErrorAction SilentlyContinue
if ($script:CimFalhas.Count -gt 0) {
    $classe = ($script:CimFalhas.Keys | Select-Object -First 1)
    Write-Log "WMI com defeito: $classe ($($script:CimFalhas[$classe])). Usando fontes alternativas." 'AVISO'
    Invoke-Externo '01_Sistema' 'wmi_verificacao.txt' 'winmgmt /verifyrepository' 90 | Out-Null
    $detalheWmi = ('Falha ao consultar {0}: {1}. Coletas que dependem de WMI (hardware, serviços, contadores, drivers, segurança) ficaram incompletas ou usaram fontes alternativas. ' -f $classe, $script:CimFalhas[$classe]) +
        'Correção (administrador): winmgmt /verifyrepository; se inconsistente, winmgmt /salvagerepository e reiniciar o serviço (net stop winmgmt && net start winmgmt). Se persistir, recompilar os MOFs ou, como último recurso, winmgmt /resetrepository (apaga o repositório: reinstalar aplicativos que registram WMI, como agentes de monitoramento e backup).'
    Add-Achado ALTO 'Sistema' 'Repositório WMI corrompido ou inconsistente' $detalheWmi '01_Sistema\wmi_verificacao.txt'
}

$script:Alvo = Get-UsuarioAlvo
Write-Log ("Usuário alvo: {0} (SID {1}, origem: {2})" -f $script:Alvo.Nome, $script:Alvo.SID, $script:Alvo.Origem)
if ($script:Alvo.Outro) {
    Add-Achado INFO 'Execução' "Script elevado com outra conta: dados por usuário foram lidos do usuário logado ($($script:Alvo.Nome))" `
        'Programas, inicialização, proxy, unidades mapeadas e Office refletem o usuário logado, não a conta administrativa.'
}
if ($SemDadosSensiveis) {
    Write-Log 'Modo -SemDadosSensiveis: log de Segurança, cache DNS, conexões, Wi-Fi, whoami, gpresult e contas locais NÃO serão coletados.' 'AVISO'
}




# ---------------------------------------------------------------------------
# 01 SISTEMA
# ---------------------------------------------------------------------------
Invoke-Etapa 'Sistema operacional' {
    $os   = Get-CimSeguro Win32_OperatingSystem
    $cs   = Get-CimSeguro Win32_ComputerSystem
    $bios = Get-CimSeguro Win32_BIOS
    if (-not $os -or -not $cs -or -not $bios) {
        # WMI indisponivel: completa o que faltou lendo registro e .NET
        $alt = Get-DadosSistemaSemWmi
        if (-not $os)   { $os = $alt.OS }
        if (-not $cs)   { $cs = $alt.CS }
        if (-not $bios) { $bios = $alt.BIOS }
        Save-Texto '01_Sistema' 'nota_sem_wmi.txt' 'Dados do sistema lidos do registro e do .NET porque o WMI não respondeu. Serial e alguns campos ficam indisponíveis.'
    }
    $uptime = $null
    if ($os.LastBootUpTime) { $uptime = (Get-Date) - $os.LastBootUpTime }

    $info = [ordered]@{
        Computador      = $env:COMPUTERNAME
        Usuario         = "$env:USERDOMAIN\$env:USERNAME"
        Dominio         = $cs.Domain
        ParteDominio    = $cs.PartOfDomain
        Fabricante      = $cs.Manufacturer
        Modelo          = $cs.Model
        Serial          = $bios.SerialNumber
        BIOS            = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
        SO              = $os.Caption
        Versao          = $os.Version
        Build           = "$($os.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR)"
        DisplayVersion  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        Arquitetura     = $os.OSArchitecture
        Instalado       = $os.InstallDate
        UltimoBoot      = $os.LastBootUpTime
        Uptime          = $(if ($uptime) { '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes } else { 'indisponível' })
        FusoHorario     = (Get-TimeZone).DisplayName
        RAMTotal        = Format-Bytes $cs.TotalPhysicalMemory
        Admin           = $script:IsAdmin
        PowerShell      = $PSVersionTable.PSVersion.ToString()
    }
    Save-Texto '01_Sistema' 'resumo_sistema.txt' ([pscustomobject]$info | Format-List)
    $script:InfoSistema = $info

    if ($uptime -and $uptime.TotalDays -gt 30) {
        Add-Achado ALTO 'Sistema' "Máquina ligada há $([int]$uptime.TotalDays) dias sem reiniciar" `
            'Uptime longo acumula vazamento de memória e impede a conclusão de updates.' '01_Sistema\resumo_sistema.txt'
    }

    # Ciclo de vida. Datas de fim de suporte por build (Home/Pro, Enterprise/Education).
    # Revisar 1x por ano em https://learn.microsoft.com/lifecycle
    if ($os.Caption -match 'Windows 7|Windows 8|2008|2012') {
        Add-Achado CRITICO 'Sistema' "Sistema operacional fora de suporte: $($os.Caption)"
    }
    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [int]$os.BuildNumber
    $edicaoEnt = ($nt.EditionID -match 'Enterprise|Education') -or ($os.Caption -match 'Enterprise|Education')
    $ltsc = ($nt.EditionID -match 'LTSC|LTSB|IoTEnterpriseS') -or ($os.Caption -match 'LTSC|LTSB')
    $ciclo = @{
        19045 = @('Windows 10 22H2', '2025-10-14', '2025-10-14')
        22000 = @('Windows 11 21H2', '2023-10-10', '2024-10-08')
        22621 = @('Windows 11 22H2', '2024-10-08', '2025-10-14')
        22631 = @('Windows 11 23H2', '2025-11-11', '2026-11-10')
        26100 = @('Windows 11 24H2', '2026-10-13', '2027-10-12')
        26200 = @('Windows 11 25H2', '2027-10-12', '2028-10-10')
    }
    if (-not $ltsc) {
        if ($ciclo.ContainsKey($build)) {
            $c = $ciclo[$build]
            $dataFim = [datetime]::ParseExact($(if ($edicaoEnt) { $c[2] } else { $c[1] }), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $dias = [int]($dataFim - (Get-Date)).TotalDays
            if ($dias -lt 0) {
                $extra = if ($build -lt 22000) { 'Windows 10 só recebe correções com ESU (pago). Planeje a migração para o Windows 11.' } else { 'Atualize para a versão mais recente do Windows 11.' }
                Add-Achado ALTO 'Sistema' "$($c[0]) sem suporte desde $($dataFim.ToString('dd/MM/yyyy'))" "Não recebe correções de segurança. $extra" '01_Sistema\resumo_sistema.txt'
            } elseif ($dias -le 120) {
                Add-Achado MEDIO 'Sistema' "$($c[0]) perde o suporte em $dias dias ($($dataFim.ToString('dd/MM/yyyy')))" 'Planeje a atualização de versão.' '01_Sistema\resumo_sistema.txt'
            }
        } elseif ($build -lt 19045 -and $build -ge 10240) {
            Add-Achado CRITICO 'Sistema' "Build do Windows 10 antigo e sem suporte ($build)" 'Versão muito antiga: atualizar para o Windows 11.' '01_Sistema\resumo_sistema.txt'
        }
    }

    Invoke-Externo '01_Sistema' 'systeminfo.txt' 'systeminfo' 120 | Out-Null
    # Valores com cara de segredo sao mascarados; PATH e quebrado em linhas.
    $vars = Get-ChildItem Env: | Sort-Object Name | ForEach-Object {
        $v = $_.Value
        if ($_.Name -match 'KEY|TOKEN|SECRET|PASS|PWD|CREDENTIAL|COOKIE|AUTH') { $v = '***MASCARADO***' }
        elseif ($_.Name -match '^(Path|PSModulePath)$') { $v = ($v -split ';') -join "`r`n    " }
        [pscustomobject]@{ Nome = $_.Name; Valor = $v }
    }
    Save-Texto '01_Sistema' 'variaveis_ambiente.txt' ($vars | Format-List)
}

Invoke-Etapa 'Reinicialização pendente' {
    $motivos = New-Object System.Collections.Generic.List[string]
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $motivos.Add('CBS (componentes do Windows)') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $motivos.Add('Windows Update') }
    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $motivos.Add('Renomeação de arquivos pendente') }
    $atual = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    $novo  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($atual -ne $novo) { $motivos.Add("Troca de nome do computador ($atual -> $novo)") }

    Save-Texto '01_Sistema' 'reboot_pendente.txt' $(if ($motivos.Count) { $motivos.ToArray() } else { 'Nenhuma reinicialização pendente' })
    if ($motivos.Count) {
        Add-Achado MEDIO 'Sistema' 'Reinicialização pendente' ($motivos.ToArray() -join '; ') '01_Sistema\reboot_pendente.txt'
    }
}

Invoke-Etapa 'Ativação do Windows' {
    $lic = Get-CimSeguro SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue
    $status = @{ 0 = 'Não licenciado'; 1 = 'Licenciado'; 2 = 'Período OOB'; 3 = 'Período OOT'; 4 = 'Não original'; 5 = 'Notificação'; 6 = 'Período estendido' }
    $dados = $lic | Select-Object Name, Description, @{n = 'Status'; e = { $status[[int]$_.LicenseStatus] } }, PartialProductKey
    Save-Texto '01_Sistema' 'ativacao.txt' ($dados | Format-List)
    if ($lic -and -not ($lic | Where-Object LicenseStatus -eq 1)) {
        Add-Achado MEDIO 'Sistema' 'Windows não está ativado' ($dados.Status -join ', ') '01_Sistema\ativacao.txt'
    }
}

# ---------------------------------------------------------------------------
# 02 HARDWARE
# ---------------------------------------------------------------------------
Invoke-Etapa 'CPU e memória' {
    $cpu = Get-CimSeguro Win32_Processor
    if ($cpu) {
        Save-Texto '02_Hardware' 'cpu.txt' ($cpu | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors,
            MaxClockSpeed, CurrentClockSpeed, LoadPercentage, L2CacheSize, L3CacheSize, VirtualizationFirmwareEnabled | Format-List)
    } else {
        $rc = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
        Save-Texto '02_Hardware' 'cpu.txt' ([pscustomobject]@{ Name = $rc.ProcessorNameString; NumberOfLogicalProcessors = [Environment]::ProcessorCount
            MaxClockSpeed = $rc.'~MHz'; Fonte = 'registro (WMI indisponível)' } | Format-List)
    }

    $pentes = Get-CimSeguro Win32_PhysicalMemory
    Save-Csv '02_Hardware' 'memoria_pentes.csv' ($pentes | Select-Object BankLabel, DeviceLocator, Manufacturer, PartNumber,
        SerialNumber, @{n = 'Capacidade'; e = { Format-Bytes $_.Capacity } }, Speed, ConfiguredClockSpeed)

    $os = Get-CimSeguro Win32_OperatingSystem
    $totalKB = 0; $livreKB = 0
    if ($os) { $totalKB = [double]$os.TotalVisibleMemorySize; $livreKB = [double]$os.FreePhysicalMemory }
    else {
        $mf = Get-MemoriaFallback
        if ($mf) { $totalKB = $mf.TotalKB; $livreKB = $mf.LivreKB }
    }
    if ($totalKB -gt 0) {
        $usoRam = [math]::Round((1 - $livreKB / $totalKB) * 100, 1)
        if ($usoRam -ge 90) {
            Add-Achado ALTO 'Hardware' "Memória RAM com $usoRam% de uso no momento da coleta" 'Verifique os processos em 05_Desempenho.'
        }
        $totalGB = [math]::Round($totalKB / 1MB, 1)
        if ($totalGB -lt 7.5) {
            Add-Achado MEDIO 'Hardware' "Pouca memória RAM instalada ($totalGB GB)" 'Para Windows 10/11 com uso corporativo o recomendado é 8 GB ou mais.'
        }
    } else {
        Add-Lacuna 'uso e total de memória RAM' 'WMI indisponível e a leitura alternativa falhou'
    }
    $velocidades = $pentes | Select-Object -ExpandProperty ConfiguredClockSpeed -Unique
    if (($velocidades | Measure-Object).Count -gt 1) {
        Add-Achado BAIXO 'Hardware' 'Pentes de memória com velocidades diferentes' ($velocidades -join ', ')
    }
}

Invoke-Etapa 'Discos e volumes' {
    $fisicos = Get-PhysicalDisk -ErrorAction SilentlyContinue
    Save-Csv '02_Hardware' 'discos_fisicos.csv' ($fisicos | Select-Object FriendlyName, SerialNumber, MediaType, BusType,
        HealthStatus, OperationalStatus, @{n = 'Tamanho'; e = { Format-Bytes $_.Size } }, FirmwareVersion)

    foreach ($d in $fisicos) {
        switch ("$($d.HealthStatus)") {
            'Unhealthy' {
                Add-Achado CRITICO 'Hardware' "Disco '$($d.FriendlyName)' com saúde: Unhealthy" `
                    "Status operacional: $($d.OperationalStatus). Faça backup imediatamente." '02_Hardware\discos_fisicos.csv'
            }
            'Warning' {
                Add-Achado ALTO 'Hardware' "Disco '$($d.FriendlyName)' com saúde: Warning" `
                    "Status operacional: $($d.OperationalStatus). Confira o SMART e faça backup." '02_Hardware\discos_fisicos.csv'
            }
            'Unknown' {
                Add-Achado BAIXO 'Hardware' "Disco '$($d.FriendlyName)' com saúde desconhecida ($($d.BusType))" `
                    'Comum em USB e leitor de cartão, que não expõem SMART. Não indica defeito por si só.' '02_Hardware\discos_fisicos.csv'
            }
        }
    }

    # SMART / contadores de confiabilidade (requer admin)
    if ($script:IsAdmin -and $fisicos) {
        $smart = foreach ($d in $fisicos) {
            $r = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($r) {
                [pscustomobject]@{
                    Disco = $d.FriendlyName; Temperatura = $r.Temperature; TempMax = $r.TemperatureMax
                    Desgaste = $r.Wear; ErrosLeituraNaoCorrigidos = $r.ReadErrorsUncorrected
                    ErrosEscritaNaoCorrigidos = $r.WriteErrorsUncorrected; ErrosLeituraTotal = $r.ReadErrorsTotal
                    HorasLigado = $r.PowerOnHours; CiclosLiga = $r.StartStopCycleCount; LatenciaMaxLeitura = $r.ReadLatencyMax
                }
            }
        }
        Save-Csv '02_Hardware' 'smart_confiabilidade.csv' $smart
        foreach ($s in $smart) {
            if ($s.ErrosLeituraNaoCorrigidos -gt 0 -or $s.ErrosEscritaNaoCorrigidos -gt 0) {
                Add-Achado CRITICO 'Hardware' "Disco '$($s.Disco)' com erros não corrigidos (SMART)" `
                    "Leitura: $($s.ErrosLeituraNaoCorrigidos) / Escrita: $($s.ErrosEscritaNaoCorrigidos)" '02_Hardware\smart_confiabilidade.csv'
            }
            if ($s.Desgaste -ge 80) {
                Add-Achado ALTO 'Hardware' "SSD '$($s.Disco)' com $($s.Desgaste)% de desgaste" 'Planeje a substituição.'
            }
            if ($s.Temperatura -ge 60) {
                Add-Achado MEDIO 'Hardware' "Disco '$($s.Disco)' a $($s.Temperatura) C" 'Temperatura elevada para disco.'
            }
        }
    }
    # wmic foi removido do Windows 11 25H2: usar CIM
    $dd = Get-CimSeguro Win32_DiskDrive -ErrorAction SilentlyContinue
    Save-Csv '02_Hardware' 'discos_cim.csv' ($dd | Select-Object Model, SerialNumber, Status, InterfaceType, MediaType, FirmwareRevision,
        Partitions, @{n = 'Tamanho'; e = { Format-Bytes $_.Size } }, PNPDeviceID)
    foreach ($x in $dd | Where-Object { $_.Status -and $_.Status -ne 'OK' }) {
        Add-Achado ALTO 'Hardware' "Disco '$($x.Model)' com status '$($x.Status)'" 'Status reportado pelo firmware/SMART (Pred Fail = falha prevista).' '02_Hardware\discos_cim.csv'
    }
    if ($script:IsAdmin) {
        $pred = Get-CimSeguro -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
        if ($pred) {
            Save-Texto '02_Hardware' 'smart_predicao.txt' ($pred | Select-Object InstanceName, PredictFailure, Reason, Active | Format-Table -AutoSize)
            foreach ($p in $pred | Where-Object PredictFailure) {
                Add-Achado CRITICO 'Hardware' "SMART prevê falha iminente do disco ($($p.InstanceName))" 'Faça backup imediatamente e substitua o disco.' '02_Hardware\smart_predicao.txt'
            }
        } else {
            Save-Texto '02_Hardware' 'smart_predicao.txt' 'Indisponível (comum em NVMe). Veja smart_confiabilidade.csv.'
        }
    }
    $chk = @(Get-EventosSeguro @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Wininit'; Id = 1001 } 10) +
           @(Get-EventosSeguro @{ LogName = 'Application'; ProviderName = 'Chkdsk'; Id = 26212, 26226 } 10)
    Save-Csv '02_Hardware' 'chkdsk_historico.csv' ($chk | Sort-Object TimeCreated -Descending | Select-Object TimeCreated, ProviderName, Id,
        @{n = 'Resultado'; e = { ($_.Message -replace '\s+', ' ').Trim() } })

    $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size -gt 0 }
    Save-Csv '02_Hardware' 'volumes.csv' ($vols | Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, HealthStatus,
        @{n = 'Tamanho'; e = { Format-Bytes $_.Size } }, @{n = 'Livre'; e = { Format-Bytes $_.SizeRemaining } },
        @{n = 'PctLivre'; e = { [math]::Round($_.SizeRemaining / $_.Size * 100, 1) } })

    foreach ($v in $vols | Where-Object DriveType -eq 'Fixed') {
        $pct = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
        if ($pct -lt 5) {
            Add-Achado CRITICO 'Hardware' "Unidade $($v.DriveLetter): quase cheia ($pct% livre, $(Format-Bytes $v.SizeRemaining))" '' '02_Hardware\volumes.csv'
        } elseif ($pct -lt 15) {
            Add-Achado ALTO 'Hardware' "Unidade $($v.DriveLetter): com pouco espaço ($pct% livre, $(Format-Bytes $v.SizeRemaining))" '' '02_Hardware\volumes.csv'
        }
        if ($v.HealthStatus -and $v.HealthStatus -ne 'Healthy') {
            Add-Achado ALTO 'Hardware' "Volume $($v.DriveLetter): com status $($v.HealthStatus)" 'Rode chkdsk /scan.'
        }
    }

    # Bit "dirty" do NTFS (chkdsk agendado por corrupção). Via CIM: o texto do fsutil muda com o idioma
    # ("esta sujo" e "NAO esta sujo" casavam na mesma busca).
    $sujos = New-Object System.Collections.Generic.List[string]
    foreach ($v in Get-CimSeguro Win32_Volume -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DirtyBitSet }) {
        $sujos.Add($v.DriveLetter)
    }
    if ($sujos.Count) {
        Add-Achado ALTO 'Hardware' "Volume marcado como corrompido (dirty bit): $($sujos.ToArray() -join ', ')" 'O Windows vai forçar chkdsk no próximo boot.'
    }
}

Invoke-Etapa 'Dispositivos com erro' {
    $codigos = @{
        1 = 'Não configurado'; 3 = 'Driver corrompido/pouca memória'; 10 = 'Não pode iniciar'; 12 = 'Conflito de recursos'
        14 = 'Requer reinicio'; 18 = 'Reinstalar driver'; 19 = 'Registro corrompido'; 22 = 'Desabilitado'
        24 = 'Não presente/sem driver'; 28 = 'Driver não instalado'; 31 = 'Não funciona corretamente'
        32 = 'Serviço do driver desabilitado'; 37 = 'Falha na inicialização do driver'; 39 = 'Driver corrompido ou ausente'
        43 = 'Dispositivo reportou problema'; 45 = 'Desconectado'; 52 = 'Assinatura do driver inválida'
    }
    $todos = Get-CimSeguro Win32_PnPEntity
    $comErro = $todos | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object Name, PNPClass, Manufacturer, ConfigManagerErrorCode,
            @{n = 'Significado'; e = { $codigos[[int]$_.ConfigManagerErrorCode] } }, DeviceID
    Save-Csv '02_Hardware' 'dispositivos_com_erro.csv' $comErro
    Save-Csv '02_Hardware' 'dispositivos_todos.csv' ($todos | Select-Object Name, PNPClass, Manufacturer, Status, ConfigManagerErrorCode, DeviceID)

    foreach ($d in $comErro | Where-Object ConfigManagerErrorCode -ne 22) {
        Add-Achado ALTO 'Hardware' "Dispositivo com erro: $($d.Name)" "Código $($d.ConfigManagerErrorCode): $($d.Significado)" '02_Hardware\dispositivos_com_erro.csv'
    }

    $drivers = Get-CimSeguro Win32_PnPSignedDriver | Where-Object DeviceName |
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, DriverProviderName, IsSigned, InfName
    Save-Csv '02_Hardware' 'drivers.csv' $drivers
    $naoAssinados = $drivers | Where-Object { $_.IsSigned -eq $false }
    if ($naoAssinados) {
        Add-Achado MEDIO 'Hardware' "$(($naoAssinados | Measure-Object).Count) driver(s) não assinado(s)" (($naoAssinados.DeviceName | Select-Object -First 5) -join '; ') '02_Hardware\drivers.csv'
    }
    Invoke-Externo '02_Hardware' 'driverquery.txt' 'driverquery /v /fo table' 90 | Out-Null
}

Invoke-Etapa 'Vídeo, bateria e temperatura' {
    Save-Texto '02_Hardware' 'video.txt' (Get-CimSeguro Win32_VideoController | Select-Object Name, DriverVersion, DriverDate,
        VideoModeDescription, @{n = 'VRAM'; e = { Format-Bytes $_.AdapterRAM } }, Status | Format-List)

    $bat = Get-CimSeguro Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        Invoke-Externo '02_Hardware' 'powercfg_bateria_saida.txt' ("powercfg /batteryreport /output `"{0}`"" -f (Join-Path $script:Raiz '02_Hardware\relatorio_bateria.html')) 60 | Out-Null
        $full   = (Get-CimSeguro -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $design = (Get-CimSeguro -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        if ($full -and $design) {
            $saude = [math]::Round($full / $design * 100, 1)
            Save-Texto '02_Hardware' 'bateria.txt' "Capacidade projetada: $design mWh`r`nCapacidade atual: $full mWh`r`nSaúde: $saude%"
            if ($saude -lt 50) { Add-Achado ALTO 'Hardware' "Bateria com apenas $saude% da capacidade original" '' '02_Hardware\relatorio_bateria.html' }
            elseif ($saude -lt 70) { Add-Achado MEDIO 'Hardware' "Bateria degradada ($saude% da capacidade original)" '' '02_Hardware\relatorio_bateria.html' }
        }
    }

    $temps = Get-CimSeguro -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
    if ($temps) {
        $lista = $temps | Select-Object InstanceName, @{n = 'Celsius'; e = { [math]::Round($_.CurrentTemperature / 10 - 273.15, 1) } }
        Save-Texto '02_Hardware' 'temperatura_acpi.txt' ($lista | Format-Table -AutoSize)
        foreach ($t in $lista | Where-Object { $_.Celsius -ge 85 -and $_.Celsius -lt 150 }) {
            Add-Achado ALTO 'Hardware' "Zona térmica $($t.InstanceName) a $($t.Celsius) C" 'Possível superaquecimento: verifique ventoinha e pasta térmica.'
        }
    }
}


Invoke-Etapa 'Diagnóstico de memória do Windows' {
    $ev = @(Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; Id = 1201, 1202 } 10)
    Save-Csv '02_Hardware' 'diagnostico_memoria_windows.csv' ($ev | Select-Object TimeCreated, Id,
        @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } })
    $ultimo = $ev | Sort-Object TimeCreated -Descending | Select-Object -First 1
    if (-not $ultimo) {
        Save-Texto '02_Hardware' 'diagnostico_memoria_nota.txt' 'O Diagnóstico de Memória do Windows (mdsched.exe) nunca foi executado nesta máquina.'
    } elseif ($ultimo.Id -eq 1202) {
        Add-Achado CRITICO 'Hardware' "Diagnóstico de Memória do Windows encontrou ERROS (em $($ultimo.TimeCreated.ToString('dd/MM/yyyy')))" `
            'RAM defeituosa: teste pente a pente e substitua o que falhar.' '02_Hardware\diagnostico_memoria_windows.csv'
    } else {
        Add-Achado INFO 'Hardware' "Diagnóstico de Memória do Windows sem erros (teste de $($ultimo.TimeCreated.ToString('dd/MM/yyyy')))" '' '02_Hardware\diagnostico_memoria_windows.csv'
    }
}

Invoke-Etapa 'Uso de espaço em disco' {
    $perfil = $script:Alvo.Perfil
    $pastas = New-Object System.Collections.Generic.List[object]
    $limite = 25
    $pastas.Add(@('Temp do usuário', (Join-Path $perfil 'AppData\Local\Temp'), $true))
    $pastas.Add(@('Temp do Windows', "$env:SystemRoot\Temp", $true))
    $pastas.Add(@('Cache de download do Windows Update', "$env:SystemRoot\SoftwareDistribution\Download", $true))
    $pastas.Add(@('Windows.old', "$env:SystemDrive\Windows.old", $true))
    $pastas.Add(@('Downloads do usuário', (Join-Path $perfil 'Downloads'), $false))
    $pastas.Add(@('AppData Local do usuário', (Join-Path $perfil 'AppData\Local'), $false))
    $pastas.Add(@('Logs do Windows', "$env:SystemRoot\Logs", $false))
    $pastas.Add(@('Relatórios de erro (WER)', "$env:ProgramData\Microsoft\Windows\WER", $true))
    if ($Completo) {
        $limite = 90
        $pastas.Add(@('Perfil completo do usuário', $perfil, $false))
        $pastas.Add(@('ProgramData', $env:ProgramData, $false))
        $pastas.Add(@('Program Files', $env:ProgramFiles, $false))
        $pastas.Add(@('Program Files (x86)', ${env:ProgramFiles(x86)}, $false))
        $pastas.Add(@('WinSxS', "$env:SystemRoot\WinSxS", $false))
        $pastas.Add(@('Windows Installer', "$env:SystemRoot\Installer", $false))
    }
    $linhas = New-Object System.Collections.Generic.List[object]
    $recuperavel = [int64]0
    # Orcamento total de tempo da etapa: pastas grandes (perfil, WinSxS) podem levar minutos
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    $orcamento = if ($Completo) { 240 } else { 90 }
    foreach ($p in $pastas.ToArray()) {
        if (-not $p[1]) { continue }
        $restante = $orcamento - $relogio.Elapsed.TotalSeconds
        if ($restante -lt 5) {
            Add-Lacuna 'uso de espaço em disco' "orçamento de $orcamento s esgotado; pastas seguintes não foram medidas (a partir de '$($p[0])')"
            break
        }
        $t = Get-TamanhoPasta $p[1] ([math]::Min($limite, [int]$restante))
        if (-not $t) { continue }
        $linhas.Add([pscustomobject]@{ Descricao = $p[0]; Caminho = $p[1]; Tamanho = $t.Tamanho; Bytes = $t.Bytes; Arquivos = $t.Arquivos
            Medicao = $(if ($t.Completo) { 'completa' } else { "parcial (limite de $limite s)" }) })
        if ($p[2]) { $recuperavel += $t.Bytes }
    }
    # Arquivos especiais que ocupam muito espaco
    foreach ($nome in 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys') {
        $a = Get-Item -LiteralPath (Join-Path $env:SystemDrive $nome) -Force -ErrorAction SilentlyContinue
        if ($a) { $linhas.Add([pscustomobject]@{ Descricao = "Arquivo $nome"; Caminho = $a.FullName; Tamanho = (Format-Bytes $a.Length); Bytes = $a.Length; Arquivos = 1; Medicao = 'completa' }) }
    }
    Save-Csv '02_Hardware' 'uso_espaco.csv' ($linhas.ToArray() | Sort-Object Bytes -Descending)
    if ($recuperavel -ge 5GB) {
        Add-Achado MEDIO 'Hardware' "$(Format-Bytes $recuperavel) em temporários, caches e Windows.old" `
            'Espaço recuperável (Temp, cache do Windows Update, relatórios de erro, instalação anterior do Windows).' '02_Hardware\uso_espaco.csv'
    }
    $wo = $linhas.ToArray() | Where-Object { $_.Descricao -eq 'Windows.old' -and $_.Bytes -gt 0 }
    if ($wo) { Add-Achado INFO 'Hardware' "Windows.old presente ($($wo.Tamanho))" 'Cópia da versão anterior do Windows; pode ser removida pela Limpeza de Disco após validar a atualização.' '02_Hardware\uso_espaco.csv' }
}

# ---------------------------------------------------------------------------
# 03 EVENTOS
# ---------------------------------------------------------------------------
Invoke-Etapa 'Exportar logs de eventos (evtx)' {
    $logs = 'System', 'Application', 'Setup',
            'Microsoft-Windows-WindowsUpdateClient/Operational',
            'Microsoft-Windows-Kernel-PnP/Configuration',
            'Microsoft-Windows-Diagnostics-Performance/Operational',
            'Microsoft-Windows-DNS-Client/Operational',
            'Microsoft-Windows-NetworkProfile/Operational',
            'Microsoft-Windows-WLAN-AutoConfig/Operational',
            'Microsoft-Windows-GroupPolicy/Operational',
            'Microsoft-Windows-Windows Defender/Operational',
            'Microsoft-Windows-TaskScheduler/Operational',
            'Microsoft-Windows-PrintService/Admin',
            'Microsoft-Windows-Storage-Storport/Operational',
            'Microsoft-Windows-Ntfs/Operational'
    if ($script:IsAdmin -and -not $SemDadosSensiveis) { $logs += 'Security' }

    $ms = [int64]$Dias * 86400000
    $cultura = (Get-Culture).Name
    foreach ($l in $logs) {
        $nome = ($l -replace '[\\/ ]', '_') + '.evtx'
        $destino = Join-Path $script:Raiz "03_Eventos\evtx\$nome"
        New-Item -ItemType Directory -Path (Split-Path $destino) -Force | Out-Null
        & wevtutil.exe epl $l $destino "/q:*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]" /ow:true 2>$null
        if ($LASTEXITCODE -ne 0) { Add-Lacuna "evtx $l" "wevtutil epl retornou $LASTEXITCODE (log inexistente ou sem permissão)"; continue }
        # 'al' grava os metadados de mensagem ao lado do .evtx: sem isso, em outra maquina os eventos de
        # programas de terceiros aparecem sem texto.
        & wevtutil.exe al $destino "/l:$cultura" 2>$null
    }
}

Invoke-Etapa 'Erros e críticos (System/Application)' {
    $eventos = foreach ($log in 'System', 'Application') {
        Get-EventosSeguro @{ LogName = $log; Level = 1, 2; StartTime = $script:DesdeData } 10000
    }
    $tabela = $eventos | Select-Object TimeCreated, LogName, ProviderName, Id, LevelDisplayName,
        @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } }
    Save-Csv '03_Eventos' 'erros_criticos.csv' $tabela

    # Agrupado: o que mais se repete aparece no topo
    $top = $eventos | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 40 |
        ForEach-Object {
            $e = $_.Group[0]
            [pscustomobject]@{
                Ocorrencias = $_.Count; Log = $e.LogName; Fonte = $e.ProviderName; ID = $e.Id
                Primeiro = ($_.Group | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
                Ultimo = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                Exemplo = (($e.Message -replace '\s+', ' ').Trim() -replace '^(.{300}).*', '$1...')
            }
        }
    Save-Csv '03_Eventos' 'erros_agrupados_top40.csv' $top

    foreach ($t in $top | Where-Object Ocorrencias -ge 20 | Select-Object -First 8) {
        Add-Achado MEDIO 'Eventos' "Erro recorrente: $($t.Fonte) ID $($t.ID) ($($t.Ocorrencias)x em $Dias dias)" $t.Exemplo '03_Eventos\erros_agrupados_top40.csv'
    }
    Save-Texto '03_Eventos' 'contagem_por_nivel.txt' ($eventos | Group-Object LogName, LevelDisplayName | Select-Object Count, Name | Format-Table -AutoSize)
}

Invoke-Etapa 'Eventos conhecidos de problema' {
    # Cada regra: log, fonte, IDs, severidade e explicacao.
    # Kernel-Power 41, BugCheck 1001 e 6008 ficam na etapa 'Resumo de travamentos do sistema'
    # (o mesmo travamento gerava tres achados). Em 'Leves', eventos de nivel Aviso (ex.: WHEA corrigido)
    # viram um achado separado e mais brando.
    $regras = @(
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-WHEA-Logger'; Ids = 1, 17, 18, 19, 20, 46, 47; Sev = 'CRITICO'
           Tit = 'Erro de hardware NÃO corrigido (WHEA)'; Exp = 'Erro fatal reportado pelo hardware: CPU, memória, PCIe ou barramento.'
           Leves = @{ Tit = 'Erros de hardware corrigidos (WHEA)'; Sev = 'BAIXO'; SevMuitos = 'MEDIO'; Limite = 10
                      Exp = 'O próprio hardware corrigiu (ex.: PCIe AER). Costuma ser energia/ASPM de Wi-Fi ou NVMe: atualize BIOS e drivers; se for frequente, investigue o dispositivo indicado.' } }
        @{ Log = 'System'; Fonte = $null; Ids = 7, 11, 15, 51, 52, 153, 129; Sev = 'CRITICO'; Tit = 'Erro de disco/controladora (7/11/15/51/52/129/153)'; Exp = 'Setores ruins, timeout de I/O ou cabo/controladora com defeito.'; Provs = 'disk', 'Disk', 'storahci', 'stornvme', 'iaStorA', 'iaStorAC', 'nvme', 'atapi', 'Ntfs' }
        @{ Log = 'System'; Fonte = 'Ntfs'; Ids = 55, 137, 140; Sev = 'ALTO'; Tit = 'Corrupção no sistema de arquivos NTFS'; Exp = 'Rode chkdsk /f no volume afetado.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Ids = 2004; Sev = 'ALTO'; Tit = 'Falta de memória virtual (2004)'; Exp = 'Algum processo consumiu toda a memória. O evento indica qual.' }
        @{ Log = 'System'; Fonte = 'Service Control Manager'; Ids = 7000, 7001, 7009, 7011, 7022, 7023, 7024, 7026, 7031, 7032, 7034, 7043; Sev = 'MEDIO'; Tit = 'Serviços falhando ao iniciar ou parando inesperadamente'; Exp = 'Veja quais serviços em 03_Eventos\eventos_conhecidos.csv.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-DNS-Client'; Ids = 1014; Sev = 'MEDIO'; Tit = 'Falhas de resolução DNS (1014)'; Exp = 'Timeout ao consultar os servidores DNS configurados.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-Time-Service'; Ids = 36, 47, 129, 134; Sev = 'BAIXO'; Tit = 'Falha na sincronização de horário'; Exp = 'Horário incorreto quebra Kerberos, TLS e autenticação.' }
        @{ Log = 'System'; Fonte = 'NETLOGON'; Ids = 3210, 5719, 5722, 5723, 5805; Sev = 'ALTO'; Tit = 'Falha de comunicação com o controlador de domínio'; Exp = 'Relação de confiança, rede ou DNS com o AD.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-GroupPolicy'; Ids = 1030, 1058, 1085, 1096, 1129; Sev = 'MEDIO'; Tit = 'Falha ao aplicar GPO'; Exp = 'Veja 13_Politicas\gpresult.html.' }
        @{ Log = 'System'; Fonte = 'volmgr'; Ids = 45, 46, 49, 161; Sev = 'ALTO'; Tit = 'Falha ao gravar dump de memória'; Exp = 'Pagefile ausente/pequeno: o Windows não consegue registrar a causa das telas azuis.' }
        @{ Log = 'System'; Fonte = 'Display'; Ids = 4101; Sev = 'MEDIO'; Tit = 'Driver de vídeo parou de responder e recuperou (TDR)'; Exp = 'Atualize/reinstale o driver de vídeo.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-Kernel-Processor-Power'; Ids = 37; Sev = 'MEDIO'; Tit = 'CPU com velocidade limitada pelo firmware (37)'; Exp = 'Throttling por temperatura ou energia.' }
        @{ Log = 'System'; Fonte = 'Microsoft-Windows-Kernel-PnP'; Ids = 219; Sev = 'BAIXO'; Tit = 'Driver falhou ao carregar (Kernel-PnP 219)'; Exp = 'Dispositivo sem driver ou driver incompatível.' }
        @{ Log = 'Application'; Fonte = 'Application Error'; Ids = 1000; Sev = 'MEDIO'; Tit = 'Aplicativos travando (Application Error 1000)'; Exp = 'Veja quais executáveis em 04_Falhas\crashes_aplicativos.csv.' }
        @{ Log = 'Application'; Fonte = 'Application Hang'; Ids = 1002; Sev = 'MEDIO'; Tit = 'Aplicativos congelando (Application Hang 1002)'; Exp = 'Veja 04_Falhas\crashes_aplicativos.csv.' }
        @{ Log = 'Application'; Fonte = '.NET Runtime'; Ids = 1026; Sev = 'BAIXO'; Tit = 'Exceções .NET não tratadas (1026)'; Exp = '' }
        @{ Log = 'Application'; Fonte = 'Microsoft-Windows-User Profiles Service'; Ids = 1500, 1511, 1515, 1521, 1542; Sev = 'ALTO'; Tit = 'Problema no perfil de usuário (perfil temporario/corrompido)'; Exp = 'Usuário pode estar entrando com perfil temporário.' }
        @{ Log = 'Application'; Fonte = 'ESENT'; Ids = 454, 455, 465, 467, 489; Sev = 'BAIXO'; Tit = 'Corrupção em banco ESENT (Search/Update)'; Exp = '' }
        @{ Log = 'Application'; Fonte = 'Microsoft-Windows-Winlogon'; Ids = 6004; Sev = 'BAIXO'; Tit = 'Falha em notificação do Winlogon'; Exp = '' }
    )

    $todos = New-Object System.Collections.Generic.List[object]
    foreach ($r in $regras) {
        $filtro = @{ LogName = $r.Log; Id = $r.Ids; StartTime = $script:DesdeData }
        if ($r.Fonte -and -not $r.Provs) { $filtro.ProviderName = $r.Fonte }
        $ev = @(Get-EventosSeguro $filtro 2000)
        if ($r.Provs) { $ev = @($ev | Where-Object { $r.Provs -contains $_.ProviderName }) }
        if ($ev.Count -eq 0) { continue }

        foreach ($e in $ev) {
            $todos.Add([pscustomobject]@{
                Regra = $r.Tit; TimeCreated = $e.TimeCreated; Fonte = $e.ProviderName; ID = $e.Id; Nivel = $e.LevelDisplayName
                Mensagem = ($e.Message -replace '\s+', ' ').Trim()
            })
        }

        $grupos = @()
        if ($r.Leves) {
            $graves = @($ev | Where-Object { $_.Level -le 2 })
            $leves  = @($ev | Where-Object { $_.Level -ge 3 })
            if ($graves.Count) { $grupos += , @{ Ev = $graves; Sev = $r.Sev; Tit = $r.Tit; Exp = $r.Exp } }
            if ($leves.Count) {
                $sevL = if ($leves.Count -ge $r.Leves.Limite) { $r.Leves.SevMuitos } else { $r.Leves.Sev }
                $grupos += , @{ Ev = $leves; Sev = $sevL; Tit = $r.Leves.Tit; Exp = $r.Leves.Exp }
            }
        } else {
            $grupos += , @{ Ev = $ev; Sev = $r.Sev; Tit = $r.Tit; Exp = $r.Exp }
        }

        foreach ($g in $grupos) {
            $ultimo = $g.Ev | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $amostra = (($ultimo.Message -replace '\s+', ' ').Trim() -replace '^(.{250}).*', '$1...')
            $extra = ''
            if ($r.Fonte -match 'WHEA') {
                $comp = $g.Ev | ForEach-Object {
                    $m = ($_.Message -replace '\s+', ' ')
                    if ($m -match '(?:Componente|Component):\s*(.+?)\s+(?:Origem do Erro|Error Source)') { $Matches[1] }
                } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3
                if ($comp) { $extra = ' Componentes: ' + (($comp | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join ', ') + '.' }
            }
            Add-Achado $g.Sev 'Eventos' "$($g.Tit): $($g.Ev.Count) ocorrência(s), última em $($ultimo.TimeCreated.ToString('dd/MM/yyyy HH:mm'))" `
                "$($g.Exp)$extra Exemplo: $amostra" '03_Eventos\eventos_conhecidos.csv'
        }
    }
    Save-Csv '03_Eventos' 'eventos_conhecidos.csv' ($todos.ToArray() | Sort-Object TimeCreated -Descending)
}

Invoke-Etapa 'Histórico de boot/desligamento' {
    $ev = Get-EventosSeguro @{ LogName = 'System'; Id = 12, 13, 41, 1074, 6005, 6006, 6008, 1, 42, 107, 109; StartTime = $script:DesdeData } 3000
    $ev = $ev | Where-Object { $_.Id -ne 1 -or $_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' }
    Save-Csv '03_Eventos' 'boot_desligamento_suspensao.csv' ($ev | Select-Object TimeCreated, Id, ProviderName,
        @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } })

    # Desempenho de boot (Diagnostics-Performance 100 = tempo de boot)
    $boot = Get-EventosSeguro @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100, 101, 102, 103, 106, 109; StartTime = $script:DesdeData } 500
    $lentos = $boot | ForEach-Object {
        $x = [xml]$_.ToXml()
        $d = @{}; foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
        [pscustomobject]@{ Data = $_.TimeCreated; ID = $_.Id; BootMs = $d['BootTime']; MainPathMs = $d['MainPathBootTime']
            Arquivo = $d['FileName']; Nome = $d['FriendlyName']; TempoTotalMs = $d['TotalTime']; DegradacaoMs = $d['DegradationTime'] }
    }
    Save-Csv '03_Eventos' 'desempenho_boot.csv' $lentos
    $ultimoBoot = $lentos | Where-Object ID -eq 100 | Select-Object -First 1
    if ($ultimoBoot -and [int]$ultimoBoot.BootMs -gt 120000) {
        Add-Achado MEDIO 'Desempenho' "Boot lento: $([math]::Round([int]$ultimoBoot.BootMs / 1000)) segundos" 'Veja os itens que degradaram o boot em 03_Eventos\desempenho_boot.csv.'
    }
}

# ---------------------------------------------------------------------------
# 04 FALHAS (BSOD, dumps, crashes de aplicativos, confiabilidade)
# ---------------------------------------------------------------------------
Invoke-Etapa 'Telas azuis e dumps' {
    $bug = Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } 100
    Save-Csv '04_Falhas' 'bsod_historico_completo.csv' ($bug | Select-Object TimeCreated, @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } })

    $cfg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    $tipos = @{ 0 = 'Nenhum'; 1 = 'Completo'; 2 = 'Kernel'; 3 = 'Pequeno (minidump)'; 7 = 'Automático' }
    Save-Texto '04_Falhas' 'config_dump.txt' ("Tipo de dump: {0}`r`nArquivo: {1}`r`nPasta minidump: {2}`r`nReiniciar automaticamente: {3}" -f
        $tipos[[int]$cfg.CrashDumpEnabled], $cfg.DumpFile, $cfg.MinidumpDir, $cfg.AutoReboot)
    if ($cfg -and [int]$cfg.CrashDumpEnabled -eq 0) {
        Add-Achado MEDIO 'Falhas' 'Gravação de dump de memória desabilitada' 'Sem dump não da para descobrir a causa de telas azuis.'
    }

    $pastaMini = Join-Path $env:SystemRoot 'Minidump'
    $minis = Get-ChildItem $pastaMini -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    Save-Texto '04_Falhas' 'minidumps_lista.txt' ($minis | Select-Object Name, LastWriteTime, @{n = 'Tamanho'; e = { Format-Bytes $_.Length } } | Format-Table -AutoSize)
    if ($minis) {
        $destino = Join-Path $script:Raiz '04_Falhas\minidumps'
        New-Item -ItemType Directory -Path $destino -Force | Out-Null
        $minis | Select-Object -First 15 | Copy-Item -Destination $destino -ErrorAction SilentlyContinue
        # O achado de tela azul e feito em 'Resumo de travamentos do sistema' (evita contar 3 vezes).
        $script:MinidumpsRecentes = ($minis | Where-Object LastWriteTime -ge $script:DesdeData | Measure-Object).Count
    }
    $memDmp = Join-Path $env:SystemRoot 'MEMORY.DMP'
    if (Test-Path $memDmp) {
        $f = Get-Item $memDmp
        Save-Texto '04_Falhas' 'memory_dmp.txt' "MEMORY.DMP encontrado: $(Format-Bytes $f.Length), gerado em $($f.LastWriteTime). Não copiado por tamanho."
    }

    # Codigos de parada lidos do texto do evento 1001
    $codigos = foreach ($b in $bug) { if ($b.Message -match '0x[0-9a-fA-F]{8}') { $matches[0] } }
    if ($codigos) {
        Save-Texto '04_Falhas' 'bsod_codigos.txt' ($codigos | Group-Object | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize)
    }
}

Invoke-Etapa 'Resumo de travamentos do sistema' {
    # Consolida Kernel-Power 41, BugCheck 1001, 6008 e minidumps: um travamento = uma linha.
    $nomes = @{
        '0x0000000A' = 'IRQL_NOT_LESS_OR_EQUAL: driver acessou memória inválida. Atualize ou remova drivers recentes.'
        '0x0000001A' = 'MEMORY_MANAGEMENT: RAM defeituosa ou driver. Rode o Diagnóstico de Memória (mdsched).'
        '0x0000001E' = 'KMODE_EXCEPTION_NOT_HANDLED: exceção em driver. Veja o modulo no dump.'
        '0x00000024' = 'NTFS_FILE_SYSTEM: problema no disco ou sistema de arquivos. Rode chkdsk e confira o SMART.'
        '0x0000003B' = 'SYSTEM_SERVICE_EXCEPTION: driver, antivírus ou driver de vídeo.'
        '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA: RAM defeituosa ou driver.'
        '0x0000007A' = 'KERNEL_DATA_INPAGE_ERROR: leitura de disco falhou (disco, cabo ou controladora).'
        '0x0000007B' = 'INACCESSIBLE_BOOT_DEVICE: controladora de disco, modo SATA/RAID na BIOS ou disco.'
        '0x0000007E' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: driver. Veja o modulo no dump.'
        '0x0000009C' = 'MACHINE_CHECK_EXCEPTION: erro de CPU/hardware, temperatura ou overclock.'
        '0x0000009F' = 'DRIVER_POWER_STATE_FAILURE: driver não concluiu a troca de estado de energia (rede, vídeo, chipset).'
        '0x000000BE' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY: driver.'
        '0x000000C2' = 'BAD_POOL_CALLER: driver.'
        '0x000000D1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver (rede, antivírus, VPN).'
        '0x000000EF' = 'CRITICAL_PROCESS_DIED: processo crítico do Windows encerrou (disco, corrupção, driver).'
        '0x000000F4' = 'CRITICAL_OBJECT_TERMINATION: disco ou controladora.'
        '0x00000101' = 'CLOCK_WATCHDOG_TIMEOUT: CPU não respondeu (BIOS, virtualização, hardware).'
        '0x00000109' = 'CRITICAL_STRUCTURE_CORRUPTION: driver, RAM ou hardware.'
        '0x00000116' = 'VIDEO_TDR_FAILURE: driver de vídeo.'
        '0x00000117' = 'VIDEO_TDR_TIMEOUT_DETECTED: driver de vídeo.'
        '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR: erro fatal de hardware (CPU, RAM, PCIe).'
        '0x00000133' = 'DPC_WATCHDOG_VIOLATION: driver ou firmware de SSD.'
        '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE: driver, RAM ou corrupção.'
        '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION: SSD ou antivírus.'
    }
    $k41   = @(Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $script:DesdeData } 500)
    $s6008 = @(Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $script:DesdeData } 500)
    $b1001 = @(Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $script:DesdeData } 500)

    $linhas = New-Object System.Collections.Generic.List[object]
    foreach ($e in $k41) {
        $cod = [int64]0
        try { $cod = [int64]$e.Properties[0].Value } catch { }
        $hex = '0x{0:X8}' -f $cod
        $sig = if ($cod -ne 0) { $nomes[$hex] } else { 'Sem bugcheck: queda de energia, travamento total (hang) ou botão de energia mantido pressionado' }
        if (-not $sig) { $sig = '(código sem descrição na tabela do script)' }
        $linhas.Add([pscustomobject]@{ Data = $e.TimeCreated; Tipo = $(if ($cod -ne 0) { 'Tela azul' } else { 'Desligamento inesperado' })
            Codigo = $(if ($cod -ne 0) { $hex } else { '' }); Significado = $sig; Fonte = 'Kernel-Power 41' })
    }
    foreach ($e in $b1001) {
        $perto = $linhas | Where-Object { [math]::Abs(($_.Data - $e.TimeCreated).TotalMinutes) -le 15 }
        if ($perto) { continue }
        $hex = ''
        if ($e.Message -match '0x[0-9a-fA-F]{8}') { $hex = '0x' + $Matches[0].Substring(2).ToUpper() }
        $sig = $nomes[$hex]; if (-not $sig) { $sig = '(código sem descrição na tabela do script)' }
        $linhas.Add([pscustomobject]@{ Data = $e.TimeCreated; Tipo = 'Tela azul'; Codigo = $hex; Significado = $sig; Fonte = 'BugCheck 1001' })
    }
    foreach ($e in $s6008) {
        $perto = $linhas | Where-Object { [math]::Abs(($_.Data - $e.TimeCreated).TotalMinutes) -le 15 }
        if ($perto) { continue }
        $linhas.Add([pscustomobject]@{ Data = $e.TimeCreated; Tipo = 'Desligamento inesperado'; Codigo = ''; Significado = 'Registrado no boot seguinte (6008)'; Fonte = 'EventLog 6008' })
    }
    $script:Travamentos = $linhas.ToArray()
    Save-Csv '04_Falhas' 'travamentos_consolidado.csv' ($linhas.ToArray() | Sort-Object Data -Descending)

    $telas  = @($linhas.ToArray() | Where-Object Tipo -eq 'Tela azul')
    $quedas = @($linhas.ToArray() | Where-Object Tipo -eq 'Desligamento inesperado')
    if ($telas.Count) {
        $top = $telas | Where-Object Codigo | Group-Object Codigo | Sort-Object Count -Descending | Select-Object -First 3
        $det = ($top | ForEach-Object { "$($_.Name) ($($_.Count)x): $($nomes[$_.Name])" }) -join ' | '
        if ($script:MinidumpsRecentes -gt 0) { $det += " | $($script:MinidumpsRecentes) minidump(s) em 04_Falhas\minidumps (analise com WinDbg: !analyze -v)" }
        Add-Achado CRITICO 'Falhas' "$($telas.Count) tela(s) azul(is) nos últimos $Dias dias" $det '04_Falhas\travamentos_consolidado.csv'
    }
    if ($quedas.Count) {
        Add-Achado ALTO 'Falhas' "$($quedas.Count) desligamento(s) inesperado(s) sem tela azul nos últimos $Dias dias" `
            'Queda de energia, travamento total (hang) ou botão de energia mantido. Em notebook verifique bateria e carregador; em desktop, fonte e nobreak.' '04_Falhas\travamentos_consolidado.csv'
    }
}

Invoke-Etapa 'Crashes de aplicativos' {
    $ev = Get-EventosSeguro @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang', 'Windows Error Reporting'; StartTime = $script:DesdeData } 3000
    $lista = $ev | Where-Object { $_.Id -in 1000, 1002, 1001 } | ForEach-Object {
        $p = $_.Properties
        [pscustomobject]@{
            Data = $_.TimeCreated; ID = $_.Id; Fonte = $_.ProviderName
            Aplicativo = if ($_.Id -eq 1001) { $p[5].Value } else { $p[0].Value }
            Versao = if ($_.Id -ne 1001) { $p[1].Value } else { '' }
            Modulo = if ($_.Id -eq 1000) { $p[3].Value } else { '' }
            Excecao = if ($_.Id -eq 1000) { $p[6].Value } else { '' }
            Evento = if ($_.Id -eq 1001) { $p[2].Value } else { '' }
        }
    }
    Save-Csv '04_Falhas' 'crashes_aplicativos.csv' $lista
    $ranking = $lista | Where-Object { $_.ID -in 1000, 1002 } | Group-Object Aplicativo | Sort-Object Count -Descending
    Save-Texto '04_Falhas' 'crashes_ranking.txt' ($ranking | Select-Object Count, Name | Format-Table -AutoSize)
    foreach ($r in $ranking | Where-Object Count -ge 3 | Select-Object -First 5) {
        $mods = ($r.Group | Where-Object Modulo | Group-Object Modulo | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join ', '
        Add-Achado MEDIO 'Falhas' "$($r.Name) travou/fechou $($r.Count) vezes" "Modulos com falha: $mods" '04_Falhas\crashes_aplicativos.csv'
    }
}

Invoke-Etapa 'Relatórios WER' {
    $bases = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
             "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"
    $rel = foreach ($b in $bases) {
        Get-ChildItem $b -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $script:DesdeData |
            Select-Object @{n = 'Origem'; e = { $b } }, Name, LastWriteTime
    }
    Save-Csv '04_Falhas' 'wer_relatorios.csv' $rel
    $destino = Join-Path $script:Raiz '04_Falhas\wer'
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    foreach ($r in $rel | Sort-Object LastWriteTime -Descending | Select-Object -First 30) {
        $wer = Join-Path (Join-Path $r.Origem $r.Name) 'Report.wer'
        if (Test-Path $wer -ErrorAction SilentlyContinue) { Copy-Item $wer (Join-Path $destino "$($r.Name).wer") -ErrorAction SilentlyContinue }
    }
    $kernel = Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter *.dmp -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -ge $script:DesdeData
    if ($kernel) {
        Save-Texto '04_Falhas' 'live_kernel_reports.txt' ($kernel | Select-Object FullName, LastWriteTime, Length | Format-Table -AutoSize)
        Add-Achado ALTO 'Falhas' "$(($kernel | Measure-Object).Count) LiveKernelReport(s) recentes" 'Normalmente travamento de driver de vídeo, USB ou rede (WATCHDOG).' '04_Falhas\live_kernel_reports.txt'
    }
}

Invoke-Etapa 'Monitor de confiabilidade' {
    $rel = Get-CimSeguro Win32_ReliabilityRecords -ErrorAction SilentlyContinue | Where-Object TimeGenerated -ge $script:DesdeData
    Save-Csv '04_Falhas' 'confiabilidade_registros.csv' ($rel | Select-Object TimeGenerated, SourceName, EventIdentifier, ProductName,
        @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } })
    $idx = Get-CimSeguro Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue | Sort-Object TimeGenerated -Descending | Select-Object -First 30
    Save-Csv '04_Falhas' 'confiabilidade_indice.csv' ($idx | Select-Object TimeGenerated, SystemStabilityIndex)
    $atual = $idx | Select-Object -First 1
    if ($atual -and $atual.SystemStabilityIndex -lt 5) {
        Add-Achado ALTO 'Falhas' "Índice de estabilidade baixo: $([math]::Round($atual.SystemStabilityIndex, 2)) de 10" '' '04_Falhas\confiabilidade_indice.csv'
    }
}


# ---------------------------------------------------------------------------
# 05 DESEMPENHO
# ---------------------------------------------------------------------------
Invoke-Etapa 'Processos e contadores' {
    # Amostra de CPU em dois momentos para calcular % real por processo
    $nucleos = [Environment]::ProcessorCount
    $a = Get-Process | Select-Object Id, ProcessName, CPU
    Start-Sleep -Seconds 3
    $b = Get-Process
    $mapaA = @{}; foreach ($p in $a) { $mapaA[$p.Id] = $p.CPU }
    $procs = foreach ($p in $b) {
        $cpuPct = if ($mapaA.ContainsKey($p.Id) -and $p.CPU) { [math]::Round((($p.CPU - $mapaA[$p.Id]) / 3) / $nucleos * 100, 1) } else { 0 }
        [pscustomobject]@{
            PID = $p.Id; Nome = $p.ProcessName; CPUPct = $cpuPct; CPUSegTotal = [math]::Round($p.CPU, 1)
            MemoriaMB = [math]::Round($p.WorkingSet64 / 1MB, 1); PrivadaMB = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            Handles = $p.HandleCount; Threads = $p.Threads.Count; Inicio = $p.StartTime; Caminho = $p.Path
            Empresa = $p.Company
        }
    }
    Save-Csv '05_Desempenho' 'processos.csv' ($procs | Sort-Object MemoriaMB -Descending)
    Save-Texto '05_Desempenho' 'top_cpu.txt' ($procs | Sort-Object CPUPct -Descending | Select-Object -First 20 PID, Nome, CPUPct, MemoriaMB, Caminho | Format-Table -AutoSize)
    Save-Texto '05_Desempenho' 'top_memoria.txt' ($procs | Sort-Object MemoriaMB -Descending | Select-Object -First 20 PID, Nome, MemoriaMB, PrivadaMB, Handles | Format-Table -AutoSize)

    foreach ($p in $procs | Where-Object { $_.CPUPct -ge 50 -and $_.Nome -ne 'Idle' }) {
        Add-Achado MEDIO 'Desempenho' "Processo $($p.Nome) (PID $($p.PID)) usando $($p.CPUPct)% de CPU" $p.Caminho '05_Desempenho\top_cpu.txt'
    }
    foreach ($p in $procs | Where-Object { $_.Handles -ge 50000 }) {
        Add-Achado MEDIO 'Desempenho' "Processo $($p.Nome) com $($p.Handles) handles (possível vazamento)" '' '05_Desempenho\processos.csv'
    }

    Invoke-Externo '05_Desempenho' 'tasklist_servicos.txt' 'tasklist /svc' 60 | Out-Null

    # Contadores via CIM: Get-Counter usa nomes localizados e falha em Windows pt-BR.
    # Latência de disco é PERF_AVERAGE_TIMER: precisa de duas amostras brutas (delta / frequência / delta base).
    try {
        $disco1 = Get-CimSeguro Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
        $linhas = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt 5; $i++) {
            Start-Sleep -Seconds 2
            $cpu = Get-CimSeguro Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $mem = Get-CimSeguro Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
            $dsk = Get-CimSeguro Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
            $sis = Get-CimSeguro Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop
            $linhas.Add([pscustomobject]@{
                Hora = Get-Date -Format 'HH:mm:ss'; CPUPct = $cpu.PercentProcessorTime; MemDisponivelMB = $mem.AvailableMBytes
                PaginasSeg = $mem.PagesPersec; MemComprometidaPct = $mem.PercentCommittedBytesInUse
                DiscoOcupadoPct = $dsk.PercentDiskTime; FilaDisco = $dsk.CurrentDiskQueueLength; FilaCPU = $sis.ProcessorQueueLength
            })
        }
        $disco2 = Get-CimSeguro Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
        $lat = foreach ($tipo in 'Read', 'Write') {
            $dBase = [double]$disco2."AvgDisksecPer${tipo}_Base" - [double]$disco1."AvgDisksecPer${tipo}_Base"
            $dVal  = [double]$disco2."AvgDisksecPer$tipo" - [double]$disco1."AvgDisksecPer$tipo"
            $ms = if ($dBase -gt 0) { [math]::Round($dVal / [double]$disco2.Frequency_PerfTime / $dBase * 1000, 2) } else { 0 }
            [pscustomobject]@{ Operacao = $(if ($tipo -eq 'Read') { 'Leitura' } else { 'Escrita' }); LatenciaMediaMs = $ms; Operacoes = $dBase }
        }
        Save-Csv '05_Desempenho' 'contadores.csv' $linhas.ToArray()
        $media = $linhas.ToArray() | Measure-Object CPUPct, MemDisponivelMB, PaginasSeg, MemComprometidaPct, DiscoOcupadoPct, FilaDisco, FilaCPU -Average |
            Select-Object @{n = 'Contador'; e = { $_.Property } }, @{n = 'Media'; e = { [math]::Round($_.Average, 1) } }
        Save-Texto '05_Desempenho' 'contadores_media.txt' (($media | Format-Table -AutoSize | Out-String) + ($lat | Format-Table -AutoSize | Out-String))

        foreach ($l in $lat | Where-Object LatenciaMediaMs -gt 50) {
            Add-Achado ALTO 'Desempenho' "Latência de disco alta na $($l.Operacao.ToLower()): $($l.LatenciaMediaMs) ms" 'Acima de 20 ms já é lento; acima de 50 ms indica disco sobrecarregado ou falhando.' '05_Desempenho\contadores_media.txt'
        }
        $commit = ($media | Where-Object Contador -eq 'MemComprometidaPct').Media
        if ($commit -gt 90) { Add-Achado ALTO 'Desempenho' "Memória comprometida em $commit%" 'Risco de falta de memória virtual.' '05_Desempenho\contadores.csv' }
        $cpuMedia = ($media | Where-Object Contador -eq 'CPUPct').Media
        if ($cpuMedia -gt 85) { Add-Achado ALTO 'Desempenho' "CPU com média de $cpuMedia% durante a coleta" 'Veja 05_Desempenho\top_cpu.txt.' '05_Desempenho\contadores.csv' }
        $discoMedia = ($media | Where-Object Contador -eq 'DiscoOcupadoPct').Media
        if ($discoMedia -gt 90) { Add-Achado MEDIO 'Desempenho' "Disco ocupado $discoMedia% do tempo durante a coleta" '' '05_Desempenho\contadores.csv' }
    } catch {
        # Contadores corrompidos: lodctr /r e winmgmt /resyncperf corrigem
        Add-Achado BAIXO 'Desempenho' 'Não foi possível ler os contadores de desempenho' "Possível corrupção. Correção (admin): lodctr /r e depois winmgmt /resyncperf. Erro: $($_.Exception.Message)"
    }
}

Invoke-Etapa 'Processos detalhados e assinaturas' {
    $cim = @(Get-CimSeguro Win32_Process)
    $porId = @{}
    foreach ($p in $cim) { $porId[[int]$p.ProcessId] = $p }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $linhas = foreach ($p in $cim) {
        $dono = ''
        if ($sw.Elapsed.TotalSeconds -lt 30) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($o -and $o.User) { $dono = "$($o.Domain)\$($o.User)" }
        }
        $pai = $porId[[int]$p.ParentProcessId]
        [pscustomobject]@{
            PID = $p.ProcessId; Nome = $p.Name; PIDPai = $p.ParentProcessId; Pai = $(if ($pai) { $pai.Name } else { '(encerrado)' })
            Dono = $dono; Inicio = $p.CreationDate; Caminho = $p.ExecutablePath; LinhaComando = (Remove-Segredo $p.CommandLine)
        }
    }
    $linhas = @($linhas)

    # Assinatura digital dos executaveis fora de C:\Windows (limite de 150 arquivos / 60 s)
    $caminhos = @($linhas | Where-Object { $_.Caminho -and $_.Caminho -notlike "$env:SystemRoot\*" } |
        Select-Object -ExpandProperty Caminho -Unique | Select-Object -First 150)
    $assin = @{}
    $sw.Restart()
    foreach ($c in $caminhos) {
        if ($sw.Elapsed.TotalSeconds -gt 60) { Add-Lacuna 'assinaturas digitais' 'limite de 60 s atingido; alguns executáveis não foram verificados'; break }
        if ($c -like '*\WindowsApps\*') { $assin[$c] = [pscustomobject]@{ Status = 'Indisponível (WindowsApps)'; Assinante = '' }; continue }
        try { $s = Get-AuthenticodeSignature -LiteralPath $c -ErrorAction Stop }
        catch {
            Add-Lacuna 'assinaturas digitais' $_.Exception.Message
            break
        }
        $quem = ''
        if ($s -and $s.SignerCertificate) { $quem = ($s.SignerCertificate.Subject -replace '.*?CN=([^,]+).*', '$1') }
        $assin[$c] = [pscustomobject]@{ Status = "$($s.Status)"; Assinante = $quem }
    }
    $final = foreach ($l in $linhas) {
        $a = $null
        if ($l.Caminho) { $a = $assin[$l.Caminho] }
        $l | Add-Member -NotePropertyName Assinatura -NotePropertyValue $(if ($a) { $a.Status } else { '' }) -PassThru |
            Add-Member -NotePropertyName Assinante -NotePropertyValue $(if ($a) { $a.Assinante } else { '' }) -PassThru
    }
    Save-Csv '05_Desempenho' 'processos_detalhados.csv' ($final | Sort-Object Nome)

    foreach ($p in $final | Where-Object { $_.Assinatura -eq 'HashMismatch' } | Select-Object -First 5) {
        Add-Achado ALTO 'Segurança' "Executável em uso com assinatura inválida (alterado?): $($p.Nome)" $p.Caminho '05_Desempenho\processos_detalhados.csv'
    }
    $gravaveis = '\\AppData\\|\\Temp\\|\\Downloads\\|\\Users\\Public\\|\\ProgramData\\'
    $suspeitos = @($final | Where-Object { $_.Assinatura -eq 'NotSigned' -and $_.Caminho -match $gravaveis } | Sort-Object Nome -Unique)
    if ($suspeitos.Count) {
        $nomes = ($suspeitos | Select-Object -First 8 | ForEach-Object { $_.Nome }) -join ', '
        Add-Achado MEDIO 'Segurança' "$($suspeitos.Count) processo(s) sem assinatura digital rodando de pasta gravável pelo usuário" `
            "Confirme a origem: $nomes" '05_Desempenho\processos_detalhados.csv'
    }
}

Invoke-Etapa 'Arquivo de paginação' {
    $pf = Get-CimSeguro Win32_PageFileUsage -ErrorAction SilentlyContinue
    $cfg = Get-CimSeguro Win32_ComputerSystem
    $pagReg = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction SilentlyContinue).PagingFiles) | Where-Object { $_ }
    Save-Texto '05_Desempenho' 'pagefile.txt' (("Gerenciado automaticamente: {0}" -f $cfg.AutomaticManagedPagefile),
        ($pf | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage | Format-Table -AutoSize | Out-String),
        ("Registro (PagingFiles): {0}" -f ($pagReg -join '; ')))
    if (-not $pf -and -not $pagReg) {
        Add-Achado MEDIO 'Desempenho' 'Sem arquivo de paginação' 'Pode causar falta de memória e impede gravação de dumps de tela azul.'
    }
}

# ---------------------------------------------------------------------------
# 06 SERVICOS
# ---------------------------------------------------------------------------
Invoke-Etapa 'Serviços' {
    $svcs = Get-CimSeguro Win32_Service
    if (-not $svcs) {
        # Sem WMI: usa o gerenciador de servicos (nao traz conta, caminho nem codigo de saida)
        $mapaInicio = @{ Automatic = 'Auto'; Manual = 'Manual'; Disabled = 'Disabled' }
        $svcs = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; State = "$($_.Status)"
                StartMode = $(if ($mapaInicio.ContainsKey("$($_.StartType)")) { $mapaInicio["$($_.StartType)"] } else { "$($_.StartType)" })
                StartName = ''; ExitCode = 0; PathName = '' }
        })
        if ($svcs.Count) { Save-Texto '06_Servicos' 'nota_sem_wmi.txt' 'Lista de serviços obtida via Get-Service porque o WMI não respondeu: sem conta de execução, caminho e código de saída.' }
    }
    Save-Csv '06_Servicos' 'servicos_todos.csv' ($svcs | Select-Object Name, DisplayName, State, StartMode, StartName, ExitCode, PathName | Sort-Object Name)

    # Automáticos parados (ignorando os que normalmente param sozinhos)
    $ignorar = 'gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'MapsBroker', 'RemoteRegistry', 'sppsvc', 'wuauserv',
               'TrustedInstaller', 'CDPSvc', 'tiledatamodelsvc', 'WbioSrvc', 'GoogleUpdaterService*', 'GoogleUpdaterInternalService*',
               'clr_optimization*', 'BITS', 'UsoSvc', 'DoSvc', 'ShellHWDetection', 'StateRepository', 'Wecsvc', 'dbupdate*', 'MozillaMaintenance'
    $parados = $svcs | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } | Where-Object {
        $n = $_.Name; -not ($ignorar | Where-Object { $n -like $_ })
    }
    # Delayed start/trigger: só aponta se tiver código de saída de erro
    $problema = $parados | Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 }
    Save-Csv '06_Servicos' 'automaticos_parados.csv' ($parados | Select-Object Name, DisplayName, State, ExitCode, PathName)
    foreach ($s in $problema) {
        Add-Achado MEDIO 'Serviços' "Serviço automático parado com erro: $($s.DisplayName)" "Nome: $($s.Name), código de saída: $($s.ExitCode)" '06_Servicos\automaticos_parados.csv'
    }

    # Serviços essenciais
    $essenciais = @{ 'Dhcp' = 'Cliente DHCP'; 'Dnscache' = 'Cliente DNS'; 'EventLog' = 'Log de eventos'; 'LanmanWorkstation' = 'Estação de trabalho'
                     'RpcSs' = 'RPC'; 'Winmgmt' = 'WMI'; 'mpssvc' = 'Firewall'; 'CryptSvc' = 'Criptografia'; 'Schedule' = 'Agendador'
                     'Spooler' = 'Spooler de impressão'; 'W32Time' = 'Horário do Windows'; 'AudioSrv' = 'Áudio'; 'nsi' = 'NSI (rede)' }
    foreach ($k in $essenciais.Keys) {
        $s = $svcs | Where-Object Name -eq $k
        if ($s -and $s.State -ne 'Running' -and $s.StartMode -ne 'Disabled' -and $k -ne 'W32Time') {
            Add-Achado ALTO 'Serviços' "Serviço essencial parado: $($essenciais[$k]) ($k)" "Modo: $($s.StartMode)"
        }
        if ($s -and $s.StartMode -eq 'Disabled' -and $k -in 'Dhcp', 'Dnscache', 'EventLog', 'RpcSs', 'Winmgmt', 'mpssvc', 'CryptSvc') {
            Add-Achado ALTO 'Serviços' "Serviço essencial DESABILITADO: $($essenciais[$k]) ($k)"
        }
    }

    # Serviços de terceiros com caminho sem aspas e com espaço (vulnerabilidade clássica)
    $semAspas = $svcs | Where-Object { $_.PathName -and $_.PathName -notmatch '^"' -and $_.PathName -match '^[^"]+\s[^"]+\.exe' -and $_.PathName -notmatch '^C:\\Windows\\' }
    if ($semAspas) {
        Save-Csv '06_Servicos' 'caminho_sem_aspas.csv' ($semAspas | Select-Object Name, PathName, StartName)
        Add-Achado BAIXO 'Segurança' "$(($semAspas | Measure-Object).Count) serviço(s) com caminho sem aspas (unquoted service path)" '' '06_Servicos\caminho_sem_aspas.csv'
    }
}

# ---------------------------------------------------------------------------
# 07 REDE
# ---------------------------------------------------------------------------
Invoke-Etapa 'Configuração de rede' {
    Invoke-Externo '07_Rede' 'ipconfig_all.txt'       'ipconfig /all' 30 | Out-Null
    Invoke-Externo '07_Rede' 'route_print.txt'        'route print' 30 | Out-Null
    Invoke-Externo '07_Rede' 'proxy_winhttp.txt'      'netsh winhttp show proxy' 30 | Out-Null
    Invoke-Externo '07_Rede' 'firewall_perfis.txt'    'netsh advfirewall show allprofiles' 30 | Out-Null
    Invoke-Externo '07_Rede' 'wifi_drivers.txt'       'netsh wlan show drivers' 30 | Out-Null
    Invoke-Externo '07_Rede' 'compartilhamentos.txt'  'net share' 30 | Out-Null
    Invoke-Externo '07_Rede' 'winsock_catalogo.txt'   'netsh winsock show catalog' 30 | Out-Null
    Invoke-Externo '07_Rede' 'netstat_estatisticas.txt' 'netstat -s' 60 | Out-Null
    if (-not $SemDadosSensiveis) {
        Invoke-Externo '07_Rede' 'arp.txt'            'arp -a' 30 | Out-Null
        Invoke-Externo '07_Rede' 'netstat.txt'        'netstat -ano' 60 | Out-Null
        Invoke-Externo '07_Rede' 'unidades_mapeadas_sessao.txt' 'net use' 30 | Out-Null
        if ($script:IsAdmin) {
            Invoke-Externo '07_Rede' 'wlanreport_saida.txt' 'netsh wlan show wlanreport' 90 | Out-Null
            $wr = "$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
            if (Test-Path $wr) { Copy-Item $wr (Join-Path $script:Raiz '07_Rede\relatorio_wifi.html') -ErrorAction SilentlyContinue }
        }
    }

    $adapt = Get-NetAdapter -ErrorAction SilentlyContinue
    Save-Csv '07_Rede' 'adaptadores.csv' ($adapt | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaConnectionState,
        MacAddress, DriverVersion, DriverDate, FullDuplex)
    $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue
    Save-Csv '07_Rede' 'adaptadores_estatisticas.csv' ($stats | Select-Object Name, ReceivedBytes, SentBytes, ReceivedDiscardedPackets,
        ReceivedPacketErrors, OutboundDiscardedPackets, OutboundPacketErrors)
    foreach ($s in $stats | Where-Object { ($_.ReceivedPacketErrors + $_.OutboundPacketErrors) -gt 100 }) {
        Add-Achado MEDIO 'Rede' "Adaptador '$($s.Name)' com erros de pacote" "Recebidos: $($s.ReceivedPacketErrors) / Enviados: $($s.OutboundPacketErrors). Cabo, porta do switch ou driver." '07_Rede\adaptadores_estatisticas.csv'
    }
    foreach ($a in $adapt | Where-Object { $_.Status -eq 'Up' -and $_.LinkSpeed -match '^(10|100) Mbps' -and $_.InterfaceDescription -notmatch 'Virtual|VPN|TAP|Hyper-V|Wi-?Fi|Wireless' }) {
        Add-Achado MEDIO 'Rede' "Adaptador '$($a.Name)' negociando apenas $($a.LinkSpeed)" 'Provável cabo ruim ou porta de switch limitada.'
    }

    $ipcfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue
    Save-Texto '07_Rede' 'ip_configuracao.txt' ($ipcfg | Format-List InterfaceAlias, IPv4Address, IPv6Address, IPv4DefaultGateway, DNSServer, NetProfile)
    foreach ($c in $ipcfg | Where-Object { $_.NetAdapter.Status -eq 'Up' -and "$($_.InterfaceAlias) $($_.InterfaceDescription)" -notmatch $script:RegexVirtuais }) {
        foreach ($ip in $c.IPv4Address) {
            if ($ip.IPAddress -like '169.254.*') {
                Add-Achado ALTO 'Rede' "Adaptador '$($c.InterfaceAlias)' com IP APIPA ($($ip.IPAddress))" 'Não obteve IP do DHCP.'
            }
        }
    }
    Save-Csv '07_Rede' 'dns_servidores.csv' (Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, AddressFamily, @{n = 'Servidores'; e = { $_.ServerAddresses -join ', ' } })
    Save-Csv '07_Rede' 'perfis_rede.csv' (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity)
    if (-not $SemDadosSensiveis) {
        Save-Csv '07_Rede' 'dns_cache.csv' (Get-DnsClientCache -ErrorAction SilentlyContinue | Select-Object Entry, RecordName, Type, Status, Data, TimeToLive)
        Save-Csv '07_Rede' 'conexoes_tcp.csv' (Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess,
            @{n = 'Processo'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } })
    }

    # Dados por usuario: lidos do usuario logado (HKU), nao de quem elevou o script
    $inet = Get-ItemProperty "$($script:Alvo.HKU)\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    Save-Texto '07_Rede' 'proxy_usuario.txt' ($inet | Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL | Format-List)
    $map = Get-ChildItem "$($script:Alvo.HKU)\Network" -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        [pscustomobject]@{ Letra = $_.PSChildName; Caminho = $p.RemotePath; Usuario = $p.UserName }
    }
    Save-Csv '07_Rede' 'unidades_mapeadas_usuario.csv' $map
    if ($inet.AutoConfigURL) { $script:UrlPac = $inet.AutoConfigURL }

    $hosts = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue
    Save-Texto '07_Rede' 'hosts.txt' $hosts
    $entradas = $hosts | Where-Object { $_ -match '^\s*[^#\s]' -and $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost' }
    if ($entradas) {
        Add-Achado BAIXO 'Rede' "Arquivo hosts com $(($entradas | Measure-Object).Count) entrada(s) personalizada(s)" (($entradas | Select-Object -First 5) -join ' | ') '07_Rede\hosts.txt'
    }
}

Invoke-Etapa 'Wi-Fi' {
    $wl = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|WLAN' -and $_.InterfaceDescription -notmatch 'Virtual|Direct' })
    if (-not $wl.Count) { Save-Texto '07_Rede' 'wifi_analise.txt' 'Sem adaptador Wi-Fi nesta máquina.'; return }

    $txt = (& netsh.exe wlan show interfaces 2>&1 | Out-String)
    $d = @{}
    foreach ($l in $txt -split "`r?`n") { if ($l -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') { $d[$Matches[1].Trim()] = $Matches[2] } }
    $pegar = { param($pad) ($d.GetEnumerator() | Where-Object { $_.Key -match $pad } | Select-Object -First 1).Value }
    $ssid = & $pegar '^SSID$'; $bssid = & $pegar '^(AP )?BSSID$'
    if ($SemDadosSensiveis) { $ssid = '(oculto)'; $bssid = '(oculto)' }
    $sinal = & $pegar '^(Signal|Sinal)$'
    $resumo = [ordered]@{
        Estado = (& $pegar '^(State|Estado)$'); SSID = $ssid; BSSID = $bssid
        TipoRadio = (& $pegar '(Radio type|Tipo de r.{1,3}dio)'); Banda = (& $pegar '^(Band|Banda)$'); Canal = (& $pegar '^(Channel|Canal)$')
        Sinal = $sinal; TaxaRecepcao = (& $pegar '(Receive rate|Taxa de recep)'); TaxaTransmissao = (& $pegar '(Transmit rate|Taxa de transm)')
        Autenticacao = (& $pegar '^(Authentication|Autentica)')
    }
    Save-Texto '07_Rede' 'wifi_analise.txt' ([pscustomobject]$resumo | Format-List)
    if (-not $SemDadosSensiveis) { Save-Texto '07_Rede' 'wifi_interfaces.txt' $txt }

    if ($sinal -match '(\d+)\s*%') {
        $pct = [int]$Matches[1]
        if ($pct -lt 40) { Add-Achado MEDIO 'Rede' "Sinal Wi-Fi fraco no momento da coleta ($pct%)" 'Aproxime-se do roteador ou revise o posicionamento do ponto de acesso.' '07_Rede\wifi_analise.txt' }
    }
    if ($resumo.TipoRadio -match '802\.11(n|g|b|a)\b' -and $resumo.TipoRadio -notmatch 'ac|ax|be') {
        Add-Achado BAIXO 'Rede' "Wi-Fi conectado em padrão antigo ($($resumo.TipoRadio))" 'Roteador ou adaptador limitam a velocidade; verifique 5 GHz / Wi-Fi 5 ou 6.' '07_Rede\wifi_analise.txt'
    }

    # Quedas e falhas de conexao no periodo
    $ev = @(Get-EventosSeguro @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8001, 8002, 8003; StartTime = $script:DesdeData } 3000)
    $desc = @($ev | Where-Object Id -eq 8003); $falha = @($ev | Where-Object Id -eq 8002)
    $porDia = $desc | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending | Select-Object Name, Count
    Save-Texto '07_Rede' 'wifi_quedas_por_dia.txt' ("Conexões: $(@($ev | Where-Object Id -eq 8001).Count)  Desconexões: $($desc.Count)  Falhas ao conectar: $($falha.Count)`r`n" + ($porDia | Format-Table -AutoSize | Out-String))
    if (-not $SemDadosSensiveis) {
        Save-Csv '07_Rede' 'wifi_eventos.csv' ($ev | Select-Object TimeCreated, Id, @{n = 'Mensagem'; e = { ($_.Message -replace '\s+', ' ').Trim() } })
    }
    if ($desc.Count -ge 30) { Add-Achado MEDIO 'Rede' "$($desc.Count) desconexões do Wi-Fi em $Dias dias" 'Quedas frequentes: sinal, roaming entre pontos, driver ou economia de energia do adaptador.' '07_Rede\wifi_quedas_por_dia.txt' }
    if ($falha.Count -ge 10) { Add-Achado MEDIO 'Rede' "$($falha.Count) falhas ao conectar no Wi-Fi em $Dias dias" '' '07_Rede\wifi_quedas_por_dia.txt' }
    foreach ($a in $wl | Where-Object { $_.DriverDate -and $_.DriverDate -lt (Get-Date).AddYears(-3) }) {
        Add-Achado BAIXO 'Rede' "Driver do Wi-Fi com mais de 3 anos ($($a.DriverDate.ToString('dd/MM/yyyy')))" $a.InterfaceDescription '07_Rede\adaptadores.csv'
    }
}

Invoke-Etapa 'VPN' {
    $padrao = 'VPN|GlobalProtect|AnyConnect|Cisco Secure Client|Fortinet|FortiClient|WireGuard|OpenVPN|TAP-Windows|Wintun|Zscaler|Pulse|Ivanti|Check Point|NordLynx|ProtonVPN|ExpressVPN|Tailscale|ZeroTier|SonicWall|Palo Alto|Netskope|WARP'
    $ads = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match $padrao -or $_.Name -match $padrao })
    $svcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { ($_.DisplayName -match $padrao -or $_.Name -match $padrao) -and $_.Status -eq 'Running' })
    $vpnWin = @()
    try { $vpnWin = @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -ErrorAction SilentlyContinue) } catch { }
    $saida = New-Object System.Collections.Generic.List[string]
    $saida.Add('ADAPTADORES'); foreach ($a in $ads) { $saida.Add(("  {0} | {1} | {2}" -f $a.Name, $a.InterfaceDescription, $a.Status)) }
    $saida.Add('SERVIÇOS EM EXECUÇÃO'); foreach ($s in $svcs) { $saida.Add(("  {0} ({1})" -f $s.DisplayName, $s.Name)) }
    $saida.Add('CONEXÕES VPN DO WINDOWS'); foreach ($v in $vpnWin) { $saida.Add(("  {0} | {1} | {2}" -f $v.Name, $v.ServerAddress, $v.ConnectionStatus)) }
    Save-Texto '07_Rede' 'vpn.txt' $saida.ToArray()
    $ativas = @($ads | Where-Object Status -eq 'Up') + @($vpnWin | Where-Object { $_.ConnectionStatus -eq 'Connected' })
    if ($ativas.Count) {
        $nomes = (($ads | Where-Object Status -eq 'Up' | ForEach-Object { $_.InterfaceDescription }) + ($vpnWin | Where-Object { $_.ConnectionStatus -eq 'Connected' } | ForEach-Object { $_.Name })) -join ', '
        Add-Achado INFO 'Rede' "VPN ativa: $nomes" 'A VPN pode forçar rotas e DNS: relevante para lentidão, falha de DNS e erros de Windows Update (ex.: 0x800F0922).' '07_Rede\vpn.txt'
    }
}

if (-not $SemRede) {
    Invoke-Etapa 'Testes de conectividade' {
        # Gateway da rota padrão com menor métrica (a que o Windows realmente usa)
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object NextHop -ne '0.0.0.0' |
               Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).NextHop
        $alvos = New-Object System.Collections.Generic.List[object]
        if ($gw) { $alvos.Add(@{ Nome = 'Gateway'; Host = $gw }) }
        $alvos.Add(@{ Nome = 'DNS Google'; Host = '8.8.8.8' })
        $alvos.Add(@{ Nome = 'DNS Cloudflare'; Host = '1.1.1.1' })
        $alvos.Add(@{ Nome = 'Microsoft'; Host = 'www.microsoft.com' })

        $res = foreach ($a in $alvos.ToArray()) {
            # Pré-teste rápido: evita 10 timeouts de 4s em host que não responde
            if (-not (Test-Connection -ComputerName $a.Host -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
                [pscustomobject]@{ Alvo = $a.Nome; Host = $a.Host; Respostas = '0/2'; PerdaPct = 100; MediaMs = $null; MaxMs = $null }
                continue
            }
            # PS 5.1 devolve ResponseTime; PS 7 devolve Latency e Status
            $p = Test-Connection -ComputerName $a.Host -Count 10 -BufferSize 32 -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSObject.Properties['Status'] -or "$($_.Status)" -eq 'Success' }
            $tempos = foreach ($x in $p) { if ($x.PSObject.Properties['Latency']) { $x.Latency } else { $x.ResponseTime } }
            $ok = ($p | Measure-Object).Count
            $lat = if ($ok) { [math]::Round(($tempos | Measure-Object -Average).Average, 1) } else { $null }
            $max = if ($ok) { ($tempos | Measure-Object -Maximum).Maximum } else { $null }
            [pscustomobject]@{ Alvo = $a.Nome; Host = $a.Host; Respostas = "$ok/10"; PerdaPct = (10 - $ok) * 10; MediaMs = $lat; MaxMs = $max }
        }
        $res = @($res)
        Save-Texto '07_Rede' 'ping.txt' ($res | Format-Table -AutoSize)

        # TCP: em rede corporativa o ICMP e o DNS externo costumam ser bloqueados sem que haja problema
        $portas = foreach ($t in @(@('www.microsoft.com', 443), @('login.microsoftonline.com', 443), @('www.google.com', 443), @('8.8.8.8', 53))) { Test-Porta $t[0] $t[1] }
        $portas = @($portas)
        Save-Texto '07_Rede' 'teste_portas.txt' ($portas | Format-Table -AutoSize)

        $tcpOk  = @($portas | Where-Object { $_.Porta -eq 443 -and $_.Aberta }).Count
        $pingOk = @($res | Where-Object { $_.PerdaPct -lt 100 }).Count
        $internetOk = ($tcpOk -gt 0) -or ($pingOk -gt 0)
        if (-not $internetOk) {
            Add-Achado ALTO 'Rede' 'Sem conectividade com a internet (nenhum ping nem conexão TCP respondeu)' 'Verifique cabo/Wi-Fi, gateway, proxy e firewall.' '07_Rede\ping.txt'
        } else {
            foreach ($r in $res) {
                if ($r.PerdaPct -eq 100) {
                    Add-Achado INFO 'Rede' "$($r.Alvo) ($($r.Host)) não responde ping, mas a internet responde" 'Normal quando o roteador/firewall bloqueia ICMP.' '07_Rede\ping.txt'
                } elseif ($r.PerdaPct -ge 20) {
                    Add-Achado MEDIO 'Rede' "Perda de pacotes para $($r.Alvo): $($r.PerdaPct)%" '' '07_Rede\ping.txt'
                }
                if ($r.Alvo -eq 'Gateway' -and $r.MediaMs -gt 20) { Add-Achado MEDIO 'Rede' "Latência alta até o gateway: $($r.MediaMs) ms" 'Rede local congestionada ou Wi-Fi fraco.' '07_Rede\ping.txt' }
            }
            foreach ($p in $portas | Where-Object { -not $_.Aberta }) {
                if ($p.Porta -eq 53) { Add-Achado INFO 'Rede' "DNS externo $($p.Host):53 bloqueado" 'Normal em rede que obriga o uso do DNS interno.' '07_Rede\teste_portas.txt' }
                else { Add-Achado MEDIO 'Rede' "Sem conexão TCP em $($p.Host):$($p.Porta) (os demais destinos respondem)" 'Site bloqueado por firewall/proxy ou indisponível.' '07_Rede\teste_portas.txt' }
            }
        }

        # DNS: consulta direta a cada servidor configurado (o teste pelo resolvedor do sistema mede o cache local)
        $indicesUp = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { $_.ifIndex })
        $servidores = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses -and $_.InterfaceAlias -notmatch $script:RegexVirtuais -and $indicesUp -contains $_.InterfaceIndex } |
            ForEach-Object { $_.ServerAddresses } | Where-Object { $_ -and $_ -ne '0.0.0.0' } | Select-Object -Unique)
        $nomesDns = 'www.microsoft.com', 'www.google.com', 'login.microsoftonline.com'
        $dnsRes = foreach ($srv in $servidores) {
            foreach ($n in $nomesDns) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $r = $null
                try { $r = Resolve-DnsName $n -Server $srv -DnsOnly -Type A -ErrorAction Stop; $ok = $true } catch { $ok = $false }
                $sw.Stop()
                [pscustomobject]@{ Servidor = $srv; Nome = $n; Resolveu = $ok; Ms = $sw.ElapsedMilliseconds; IPs = (($r | Where-Object IPAddress).IPAddress -join ', ') }
            }
        }
        $dnsRes = @($dnsRes)
        Save-Texto '07_Rede' 'teste_dns_por_servidor.txt' ($dnsRes | Format-Table -AutoSize)
        # Resolvedor do sistema (usa cache): so evidencia
        $dnsSis = foreach ($n in $nomesDns) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $r = Resolve-DnsName $n -DnsOnly -ErrorAction Stop; $ok = $true } catch { $ok = $false }
            $sw.Stop()
            [pscustomobject]@{ Nome = $n; Resolveu = $ok; Ms = $sw.ElapsedMilliseconds }
        }
        Save-Texto '07_Rede' 'teste_dns_sistema.txt' ($dnsSis | Format-Table -AutoSize)

        $porSrv = $dnsRes | Group-Object Servidor
        $bons = @($porSrv | Where-Object { @($_.Group | Where-Object Resolveu).Count -gt 0 })
        foreach ($g in $porSrv) {
            $oks = @($g.Group | Where-Object Resolveu)
            if ($oks.Count -eq 0) {
                if ($bons.Count) { Add-Achado MEDIO 'Rede' "Servidor DNS $($g.Name) não responde (outro servidor responde)" 'Se for o primeiro da lista, cada consulta espera o timeout antes de usar o outro.' '07_Rede\teste_dns_por_servidor.txt' }
                else { Add-Achado ALTO 'Rede' "Servidor DNS $($g.Name) não respondeu a nenhuma consulta" '' '07_Rede\teste_dns_por_servidor.txt' }
            } else {
                $media = [math]::Round(($oks | Measure-Object Ms -Average).Average)
                if ($media -gt 300) { Add-Achado MEDIO 'Rede' "Servidor DNS $($g.Name) lento (média de $media ms)" '' '07_Rede\teste_dns_por_servidor.txt' }
            }
        }
        if (-not $servidores.Count) { Add-Lacuna 'DNS por servidor' 'nenhum servidor DNS IPv4 encontrado nos adaptadores físicos' }

        # HTTP/TLS: portal cativo, proxy interferindo e inspecao de certificado (TLS interceptado)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $http = New-Object System.Collections.Generic.List[object]
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
            $req.Timeout = 8000; $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $corpo = $sr.ReadToEnd(); $sr.Close()
            $loc = $resp.Headers['Location']; $cod = [int]$resp.StatusCode; $resp.Close()
            $ok = ($cod -eq 200 -and $corpo -match 'Microsoft Connect Test')
            $http.Add([pscustomobject]@{ Teste = 'Portal cativo (connecttest)'; Alvo = 'msftconnecttest.com'; Status = $cod; Ms = $sw.ElapsedMilliseconds; Ok = $ok; Detalhe = $loc })
            if (-not $ok) {
                Add-Achado MEDIO 'Rede' "Resposta inesperada ao teste de conectividade do Windows (HTTP $cod)" "Portal cativo, proxy ou filtro de conteúdo alterando a resposta. Location: $loc" '07_Rede\teste_http_tls.csv'
            }
        } catch {
            $http.Add([pscustomobject]@{ Teste = 'Portal cativo (connecttest)'; Alvo = 'msftconnecttest.com'; Status = 'erro'; Ms = ''; Ok = $false; Detalhe = $_.Exception.Message })
            if ($internetOk) { Add-Achado BAIXO 'Rede' 'Teste HTTP de conectividade do Windows falhou' $_.Exception.Message '07_Rede\teste_http_tls.csv' }
        }
        $esperado = @{ 'www.microsoft.com' = 'Microsoft|DigiCert'; 'login.microsoftonline.com' = 'Microsoft|DigiCert'; 'www.google.com' = 'Google|GTS' }
        foreach ($h in $esperado.Keys) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $cod = 'erro'; $erro = ''; $proxyUsado = ''; $emissorCompleto = ''
            $req = [Net.HttpWebRequest]::Create("https://$h/")
            $req.Timeout = 12000; $req.AllowAutoRedirect = $false
            $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Diagnóstico-Windows'
            try { $proxyUsado = $req.Proxy.GetProxy($req.RequestUri).AbsoluteUri } catch { }
            try {
                $resp = $req.GetResponse(); $cod = [int]$resp.StatusCode; $resp.Close()
            } catch [Net.WebException] {
                # 4xx/5xx ainda provam que o TLS funcionou; timeout ou falha de handshake nao
                if ($_.Exception.Response) { $cod = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() }
                else { $erro = $_.Exception.Message }
            } catch { $erro = $_.Exception.Message }
            # O certificado fica disponivel depois do handshake, mesmo que a requisicao HTTP falhe depois
            try {
                if ($req.ServicePoint.Certificate) {
                    $emissorCompleto = (New-Object Security.Cryptography.X509Certificates.X509Certificate2($req.ServicePoint.Certificate)).Issuer
                }
            } catch { }
            $emissor = ($emissorCompleto -replace '.*?CN=([^,]+).*', '$1')
            $ok = [bool]($emissorCompleto -and ($emissorCompleto -match $esperado[$h]))
            $http.Add([pscustomobject]@{ Teste = 'TLS'; Alvo = $h; Status = $cod; Ms = $sw.ElapsedMilliseconds; Ok = $ok
                Detalhe = ("Emissor: {0} | Proxy: {1} {2}" -f $emissor, $proxyUsado, $erro).Trim() })
            if ($emissorCompleto -and -not $ok) {
                Add-Achado MEDIO 'Rede' "Possível inspeção TLS em $h (emissor do certificado: $emissor)" 'Proxy, firewall ou antivírus reemite certificados. Aplicativos sem a CA da empresa falham com erro de certificado.' '07_Rede\teste_http_tls.csv'
            } elseif (-not $emissorCompleto -and $tcpOk -gt 0) {
                Add-Achado MEDIO 'Rede' "Falha TLS/HTTPS ao acessar $h" "$erro (a porta 443 responde, mas o handshake TLS não concluiu)" '07_Rede\teste_http_tls.csv'
            }
        }
        if ($script:UrlPac) {
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $req = [Net.HttpWebRequest]::Create($script:UrlPac); $req.Timeout = 5000; $req.Proxy = $null
                $resp = $req.GetResponse(); $tam = $resp.ContentLength; $cod = [int]$resp.StatusCode; $resp.Close()
                $http.Add([pscustomobject]@{ Teste = 'Script PAC'; Alvo = $script:UrlPac; Status = $cod; Ms = $sw.ElapsedMilliseconds; Ok = ($cod -eq 200); Detalhe = "$tam bytes" })
            } catch {
                $http.Add([pscustomobject]@{ Teste = 'Script PAC'; Alvo = $script:UrlPac; Status = 'erro'; Ms = ''; Ok = $false; Detalhe = $_.Exception.Message })
                Add-Achado MEDIO 'Rede' "Script PAC de proxy inacessível: $($script:UrlPac)" $_.Exception.Message '07_Rede\teste_http_tls.csv'
            }
        }
        Save-Csv '07_Rede' 'teste_http_tls.csv' $http.ToArray()

        Invoke-Externo '07_Rede' 'tracert_8.8.8.8.txt' 'tracert -d -h 20 -w 1000 8.8.8.8' 90 | Out-Null

        # Horário: diferença para servidor NTP
        Invoke-Externo '07_Rede' 'w32tm_status.txt' 'w32tm /query /status' 30 | Out-Null
        Invoke-Externo '07_Rede' 'w32tm_stripchart.txt' 'w32tm /stripchart /computer:time.windows.com /samples:3 /dataonly' 40 | Out-Null
        $sc = Get-Content (Join-Path $script:Raiz '07_Rede\w32tm_stripchart.txt') -ErrorAction SilentlyContinue | Select-String '([+-]\d+[.,]\d+)s' | Select-Object -Last 1
        if ($sc -and [math]::Abs([double]($sc.Matches[0].Groups[1].Value -replace ',', '.')) -gt 120) {
            Add-Achado ALTO 'Sistema' "Relógio da máquina com diferença de $($sc.Matches[0].Groups[1].Value)s" 'Mais de 5 minutos quebra autenticação Kerberos/Microsoft 365.' '07_Rede\w32tm_stripchart.txt'
        }
    }
}


# ---------------------------------------------------------------------------
# 08 SEGURANCA
# ---------------------------------------------------------------------------
Invoke-Etapa 'Antivírus e Defender' {
    $av = Get-CimSeguro -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
    $lista = foreach ($a in $av) {
        $hex = '{0:X6}' -f [int]$a.productState
        [pscustomobject]@{ Produto = $a.displayName; Ativo = ($hex.Substring(2, 2) -in '10', '11')
            Atualizado = ($hex.Substring(4, 2) -eq '00'); Executavel = $a.pathToSignedProductExe; Estado = $hex }
    }
    Save-Texto '08_Seguranca' 'antivirus.txt' ($lista | Format-Table -AutoSize)
    if ($lista -and -not ($lista | Where-Object Ativo)) { Add-Achado CRITICO 'Segurança' 'Nenhum antivírus ativo' '' '08_Seguranca\antivirus.txt' }
    foreach ($a in $lista | Where-Object { $_.Ativo -and -not $_.Atualizado }) { Add-Achado ALTO 'Segurança' "Antivírus desatualizado: $($a.Produto)" }
    if (($lista | Where-Object Ativo | Measure-Object).Count -gt 1) {
        Add-Achado MEDIO 'Segurança' 'Mais de um antivírus ativo ao mesmo tempo' (($lista | Where-Object Ativo).Produto -join ', ')
    }

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        Save-Texto '08_Seguranca' 'defender_status.txt' ($mp | Format-List)
        Save-Texto '08_Seguranca' 'defender_preferencias.txt' (Get-MpPreference -ErrorAction SilentlyContinue | Format-List)
        if ($mp.AMRunningMode -eq 'Normal' -and -not $mp.RealTimeProtectionEnabled) { Add-Achado CRITICO 'Segurança' 'Proteção em tempo real do Defender desativada' }
        if ($mp.AntivirusSignatureAge -gt 7 -and $mp.AMRunningMode -eq 'Normal') { Add-Achado ALTO 'Segurança' "Assinaturas do Defender com $($mp.AntivirusSignatureAge) dias" }
        if ($mp.IsTamperProtected -eq $false -and $mp.AMRunningMode -eq 'Normal') { Add-Achado BAIXO 'Segurança' 'Proteção contra adulteração (Tamper Protection) desativada' }
        $excl = Get-MpPreference -ErrorAction SilentlyContinue
        $qtdExcl = ($excl.ExclusionPath | Measure-Object).Count + ($excl.ExclusionProcess | Measure-Object).Count
        if ($qtdExcl -gt 0 -and $excl.ExclusionPath -notmatch 'N/A: Must be') {
            Add-Achado BAIXO 'Segurança' "Defender com $qtdExcl exclusão(ões) configurada(s)" 'Revise se são legítimas.' '08_Seguranca\defender_preferencias.txt'
        }
    }
    $ameacas = Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object InitialDetectionTime -ge (Get-Date).AddDays(-30)
    if ($ameacas) {
        $nomes = Get-MpThreat -ErrorAction SilentlyContinue
        Save-Csv '08_Seguranca' 'ameacas_detectadas.csv' ($ameacas | Select-Object InitialDetectionTime, ThreatID, ActionSuccess, ProcessName,
            @{n = 'Ameaça'; e = { $id = $_.ThreatID; ($nomes | Where-Object ThreatID -eq $id).ThreatName } }, @{n = 'Recursos'; e = { $_.Resources -join ' | ' } })
        Add-Achado ALTO 'Segurança' "$(($ameacas | Measure-Object).Count) ameaça(s) detectada(s) pelo Defender nos últimos 30 dias" '' '08_Seguranca\ameacas_detectadas.csv'
    }
}

Invoke-Etapa 'Firewall, BitLocker, TPM, Secure Boot, UAC' {
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    Save-Texto '08_Seguranca' 'firewall.txt' ($fw | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogFileName | Format-Table -AutoSize)
    foreach ($p in $fw | Where-Object { -not $_.Enabled }) { Add-Achado ALTO 'Segurança' "Firewall do Windows desativado no perfil $($p.Name)" }

    if ($script:IsAdmin) {
        Invoke-Externo '08_Seguranca' 'bitlocker.txt' 'manage-bde -status' 60 | Out-Null
        $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue
        $sis = $bl | Where-Object MountPoint -eq $env:SystemDrive
        if ($sis -and $sis.ProtectionStatus -ne 'On') {
            Add-Achado MEDIO 'Segurança' "Unidade do sistema ($env:SystemDrive) sem BitLocker ativo" "Status: $($sis.VolumeStatus)" '08_Seguranca\bitlocker.txt'
        }
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        Save-Texto '08_Seguranca' 'tpm.txt' ($tpm | Format-List)
        if ($tpm -and -not $tpm.TpmReady) { Add-Achado MEDIO 'Segurança' 'TPM presente mas não está pronto' "Presente: $($tpm.TpmPresent), Habilitado: $($tpm.TpmEnabled)" }
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            Save-Texto '08_Seguranca' 'secureboot.txt' "Secure Boot: $sb"
            if (-not $sb) { Add-Achado MEDIO 'Segurança' 'Secure Boot desativado' }
        } catch { Save-Texto '08_Seguranca' 'secureboot.txt' "Não suportado ou BIOS legado: $($_.Exception.Message)" }
    }

    $uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    Save-Texto '08_Seguranca' 'uac.txt' ($uac | Select-Object EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop, FilterAdministratorToken | Format-List)
    if ($uac.EnableLUA -eq 0) { Add-Achado ALTO 'Segurança' 'UAC (Controle de Conta de Usuário) desativado' }

    $rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
    $nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).UserAuthentication
    Save-Texto '08_Seguranca' 'rdp.txt' "RDP habilitado: $($rdp -eq 0)`r`nNLA exigido: $($nla -eq 1)"
    if ($rdp -eq 0 -and $nla -ne 1) { Add-Achado MEDIO 'Segurança' 'Área de Trabalho Remota habilitada sem NLA' }

    # Win32_OptionalFeature não exige elevação (Get-WindowsOptionalFeature exige)
    $smb1 = Get-CimSeguro Win32_OptionalFeature -Filter "Name='SMB1Protocol'" -ErrorAction SilentlyContinue
    if ($smb1 -and $smb1.InstallState -eq 1) { Add-Achado MEDIO 'Segurança' 'Protocolo SMBv1 habilitado' 'Protocolo obsoleto é explorado por ransomware (WannaCry).' }
}

Invoke-Etapa 'Contas e logons' {
    if ($SemDadosSensiveis) {
        Save-Texto '08_Seguranca' 'contas_nao_coletadas.txt' 'Modo -SemDadosSensiveis: contas locais, administradores e logons não foram coletados.'
        return
    }
    $admins = $null
    try {
        $admins = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource
    } catch {
        # Falha conhecida do Get-LocalGroupMember com SID orfao (Entra ID / dominio): usa CIM
        $grp = Get-CimSeguro Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction SilentlyContinue
        if ($grp) {
            $admins = Get-CimAssociatedInstance -InputObject $grp -Association Win32_GroupUser -ErrorAction SilentlyContinue |
                Select-Object @{n = 'Name'; e = { "$($_.Domain)\$($_.Name)" } }, @{n = 'ObjectClass'; e = { $_.CimClass.CimClassName } }, @{n = 'PrincipalSource'; e = { 'CIM' } }
        }
    }
    Save-Texto '08_Seguranca' 'administradores_locais.txt' ($admins | Format-Table -AutoSize)
    if (-not $admins) { Add-Lacuna 'administradores locais' 'lista vazia ou indisponível' }
    elseif (@($admins).Count -gt 4) { Add-Achado BAIXO 'Segurança' "$(@($admins).Count) membros no grupo Administradores local" 'Revise se todos precisam de privilégio administrativo.' '08_Seguranca\administradores_locais.txt' }

    $usuarios = Get-LocalUser -ErrorAction SilentlyContinue
    Save-Csv '08_Seguranca' 'usuarios_locais.csv' ($usuarios | Select-Object Name, Enabled, LastLogon, PasswordLastSet, PasswordExpires, PasswordRequired, Description)
    $guest = $usuarios | Where-Object { $_.SID -like '*-501' -and $_.Enabled }
    if ($guest) { Add-Achado ALTO 'Segurança' 'Conta Convidado (Guest) habilitada' }
    Invoke-Externo '08_Seguranca' 'whoami.txt' 'whoami /all' 30 | Out-Null

    if ($script:IsAdmin) {
        $falhas = @(Get-EventosSeguro @{ LogName = 'Security'; Id = 4625; StartTime = $script:DesdeData } 5000)
        $bloqueios = @(Get-EventosSeguro @{ LogName = 'Security'; Id = 4740; StartTime = $script:DesdeData } 500)
        $resumo = $falhas | ForEach-Object {
            [pscustomobject]@{ Conta = $_.Properties[5].Value; Dominio = $_.Properties[6].Value; TipoLogon = $_.Properties[10].Value
                Origem = $_.Properties[19].Value; Estacao = $_.Properties[13].Value }
        } | Group-Object Conta, Origem | Sort-Object Count -Descending |
            Select-Object Count, @{n = 'Conta_Origem'; e = { $_.Name } } -First 50
        Save-Texto '08_Seguranca' 'logons_falhos.txt' ($resumo | Format-Table -AutoSize)
        if ($falhas.Count -ge 50) { Add-Achado ALTO 'Segurança' "$($falhas.Count) tentativas de logon com falha em $Dias dias" 'Possível ataque de força bruta ou senha antiga salva em algum serviço.' '08_Seguranca\logons_falhos.txt' }
        if ($bloqueios.Count) { Add-Achado MEDIO 'Segurança' "$($bloqueios.Count) bloqueio(s) de conta" '' '03_Eventos\evtx\Security.evtx' }
    }
}

Invoke-Etapa 'Identidade (Entra ID / Intune)' {
    $arq = Join-Path $script:Raiz '08_Seguranca\dsregcmd_status.txt'
    Invoke-Externo '08_Seguranca' 'dsregcmd_status.txt' 'dsregcmd /status' 60 | Out-Null
    $linhas = Get-Content -LiteralPath $arq -ErrorAction SilentlyContinue
    $kv = @{}
    foreach ($l in $linhas) { if ($l -match '^\s*\|?\s*([A-Za-z]+)\s*:\s*(.+?)\s*$') { if (-not $kv.ContainsKey($Matches[1])) { $kv[$Matches[1]] = $Matches[2] } } }
    $campos = 'AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DeviceAuthStatus', 'TenantName', 'MdmUrl', 'AzureAdPrt', 'NgcSet', 'WorkplaceJoined', 'WamDefaultSet'
    $resumo = $campos | ForEach-Object { [pscustomobject]@{ Campo = $_; Valor = $kv[$_] } }
    Save-Texto '08_Seguranca' 'identidade_resumo.txt' ($resumo | Format-Table -AutoSize)
    if ($SemDadosSensiveis) { Remove-Item -LiteralPath $arq -Force -ErrorAction SilentlyContinue }   # contem IDs de tenant/dispositivo
    if (-not $kv.Count) { return }

    $hibrido = ($kv['AzureAdJoined'] -eq 'YES' -and $kv['DomainJoined'] -eq 'YES')
    $tipo = if ($hibrido) { 'Híbrido (AD + Entra ID)' } elseif ($kv['AzureAdJoined'] -eq 'YES') { 'Entra ID (somente nuvem)' } elseif ($kv['DomainJoined'] -eq 'YES') { 'Domínio AD' } else { 'Grupo de trabalho' }
    if ($kv['WorkplaceJoined'] -eq 'YES') { $tipo += ' + conta de trabalho/escola registrada' }
    Add-Achado INFO 'Identidade' "Tipo de ingresso: $tipo$(if ($kv['MdmUrl']) { ' | gerenciado por MDM (Intune)' })" '' '08_Seguranca\identidade_resumo.txt'
    if ($kv['AzureAdJoined'] -eq 'YES' -and $kv['DeviceAuthStatus'] -and $kv['DeviceAuthStatus'] -ne 'SUCCESS') {
        Add-Achado ALTO 'Identidade' "Dispositivo não autenticado no Entra ID (DeviceAuthStatus: $($kv['DeviceAuthStatus']))" 'O dispositivo pode ter sido desabilitado/removido no Entra ID ou ter perdido o certificado.' '08_Seguranca\identidade_resumo.txt'
    }
    if ($kv['AzureAdJoined'] -eq 'YES' -and $kv['AzureAdPrt'] -eq 'NO') {
        $nota = if ($script:Alvo.Outro) { ' Atenção: este valor é da conta que elevou o script, não do usuário logado; rode sem elevar para ver o do usuário.' } else { '' }
        Add-Achado MEDIO 'Identidade' 'Sem token de SSO (PRT) do Entra ID para este usuário' "Sem PRT o usuário vê pedidos repetidos de login no Microsoft 365/Teams. Verifique acesso a login.microsoftonline.com, horário e a conta.$nota" '08_Seguranca\identidade_resumo.txt'
    }
}


# ---------------------------------------------------------------------------
# 09 WINDOWS UPDATE
# ---------------------------------------------------------------------------
Invoke-Etapa 'Windows Update' {
    $hf = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object { try { [datetime]$_.InstalledOn } catch { [datetime]::MinValue } } -Descending
    Save-Csv '09_Updates' 'hotfixes.csv' ($hf | Select-Object HotFixID, Description, InstalledOn, InstalledBy)
    $ultimo = $hf | Where-Object InstalledOn | Select-Object -First 1
    if ($ultimo -and $ultimo.InstalledOn -lt (Get-Date).AddDays(-60)) {
        Add-Achado ALTO 'Updates' "Último update instalado há $([int]((Get-Date) - $ultimo.InstalledOn).TotalDays) dias ($($ultimo.HotFixID))" 'Windows Update pode estar quebrado ou bloqueado.' '09_Updates\hotfixes.csv'
    }

    # Histórico via COM (inclui falhas com código de erro)
    try {
        $sessao = New-Object -ComObject Microsoft.Update.Session
        $busca = $sessao.CreateUpdateSearcher()
        $total = $busca.GetTotalHistoryCount()
        $hist = if ($total -gt 0) { $busca.QueryHistory(0, [math]::Min($total, 200)) } else { @() }
        $res = @{ 0 = 'Não iniciado'; 1 = 'Em andamento'; 2 = 'Sucesso'; 3 = 'Sucesso com erros'; 4 = 'Falhou'; 5 = 'Abortado' }
        # Significado resumido dos codigos mais comuns do Windows Update
        $erros = @{
            '0x80240034' = 'Falha no download (WU_E_DOWNLOAD_FAILED): rede, proxy ou cache de download corrompido'
            '0x80246007' = 'Update não foi baixado (WU_E_DM_NOTDOWNLOADED): comum em driver; repetir ou ignorar'
            '0x80070002' = 'Arquivo não encontrado: cache do Windows Update corrompido'
            '0x80070005' = 'Acesso negado: permissão, antivírus ou política'
            '0x80070057' = 'Parâmetro inválido: componente de servicing danificado'
            '0x80070643' = 'Erro fatal na instalação (MSI, .NET ou Defender)'
            '0x80070BC9' = 'Reinicialização pendente impede a instalação'
            '0x80073712' = 'Componente do Windows ausente/corrompido (CBS): DISM /RestoreHealth e sfc /scannow'
            '0x800F081F' = 'Arquivos de origem não encontrados (DISM/.NET)'
            '0x800F0922' = 'Falha de servicing: pouco espaço na partição de sistema ou VPN ativa'
            '0x8024402C' = 'Não resolveu o nome do servidor de updates (proxy, DNS ou firewall)'
            '0x80072EE2' = 'Timeout de rede com o servidor de updates'
            '0x80244022' = 'Servidor de updates indisponível (HTTP 503)'
            '0x8024001E' = 'Operação interrompida (serviço parado ou desligamento)'
            '0x80240438' = 'Sem conexão com o serviço de updates (proxy/WSUS)'
            '0x8007000E' = 'Memória insuficiente'
            '0x800705B4' = 'Timeout: operação não concluída a tempo'
        }
        $linhas = foreach ($h in $hist) {
            $hr = '0x{0:X8}' -f $h.HResult
            [pscustomobject]@{ Data = $h.Date; Titulo = $h.Title; Resultado = $res[[int]$h.ResultCode]
                HResult = $hr; Significado = $erros[$hr]; Operacao = $h.Operation }
        }
        $linhas = @($linhas)
        Save-Csv '09_Updates' 'historico_windows_update.csv' $linhas

        # Falhas dos ultimos 30 dias, agrupadas por update. Uma falha seguida de instalacao bem-sucedida
        # do mesmo update vira informativo; app da Store e driver pesam menos que update do Windows.
        $desde30 = (Get-Date).AddDays(-30)
        $falhas = @($linhas | Where-Object { $_.Resultado -eq 'Falhou' -and $_.Data -ge $desde30 })
        $itens = foreach ($g in $falhas | Group-Object Titulo) {
            $ult = $g.Group | Sort-Object Data -Descending | Select-Object -First 1
            $depois = $linhas | Where-Object { $_.Titulo -eq $g.Name -and $_.Resultado -eq 'Sucesso' -and $_.Data -ge $ult.Data } | Select-Object -First 1
            $classe = if ($g.Name -match '^[0-9A-Z]{12}-') { 'Loja' }
                      elseif ($g.Name -match 'KB\d{6,}|Atualiza|Security|Cumulative|Defender|Definition|Malicious|Windows') { 'Windows' }
                      else { 'Driver' }
            [pscustomobject]@{ Titulo = $g.Name; Classe = $classe; Vezes = $g.Count; Ultima = $ult.Data; HResult = $ult.HResult
                Significado = $ult.Significado; Resolvida = [bool]$depois }
        }
        $itens = @($itens)
        Save-Csv '09_Updates' 'falhas_update_30dias.csv' $itens
        foreach ($i in $itens | Where-Object { $_.Classe -eq 'Windows' -and -not $_.Resolvida } | Select-Object -First 5) {
            Add-Achado ALTO 'Updates' "Update do Windows não instalado: $($i.Titulo) ($($i.Vezes) falha(s), última em $($i.Ultima.ToString('dd/MM/yyyy')))" "$($i.HResult) $($i.Significado)" '09_Updates\falhas_update_30dias.csv'
        }
        foreach ($i in $itens | Where-Object { $_.Classe -eq 'Driver' -and -not $_.Resolvida } | Select-Object -First 5) {
            Add-Achado BAIXO 'Updates' "Driver/firmware não instalado pelo Windows Update: $($i.Titulo)" "$($i.HResult) $($i.Significado)" '09_Updates\falhas_update_30dias.csv'
        }
        $lojaPend = @($itens | Where-Object { $_.Classe -eq 'Loja' -and -not $_.Resolvida })
        if ($lojaPend.Count) { Add-Achado INFO 'Updates' "$($lojaPend.Count) app(s) da Store com falha de atualização" (($lojaPend | Select-Object -First 3 | ForEach-Object { $_.Titulo }) -join '; ') '09_Updates\falhas_update_30dias.csv' }
        $resolvidas = @($itens | Where-Object { $_.Resolvida })
        if ($resolvidas.Count) { Add-Achado INFO 'Updates' "$($resolvidas.Count) update(s) falharam mas foram instalados depois" '' '09_Updates\falhas_update_30dias.csv' }

        if ($Completo) {
            Write-Log 'Buscando updates pendentes (pode demorar)...'
            $pend = $busca.Search("IsInstalled=0 and IsHidden=0").Updates
            $lp = foreach ($u in $pend) { [pscustomobject]@{ Titulo = $u.Title; KB = ($u.KBArticleIDs -join ','); Severidade = $u.MsrcSeverity; Tamanho = Format-Bytes $u.MaxDownloadSize } }
            Save-Csv '09_Updates' 'updates_pendentes.csv' $lp
            $crit = $lp | Where-Object Severidade -in 'Critical', 'Important'
            if ($crit) { Add-Achado ALTO 'Updates' "$(($crit | Measure-Object).Count) update(s) de segurança crítico/importante pendente(s)" '' '09_Updates\updates_pendentes.csv' }
        }
    } catch {
        Add-Achado MEDIO 'Updates' 'Não foi possível consultar o Windows Update' $_.Exception.Message
    }

    foreach ($s in 'wuauserv', 'BITS', 'CryptSvc', 'TrustedInstaller', 'UsoSvc') {
        $svc = Get-Service $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -eq 'Disabled') { Add-Achado ALTO 'Updates' "Serviço $s ($($svc.DisplayName)) está desabilitado" 'Windows Update não funciona sem ele.' }
    }
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    Save-Texto '09_Updates' 'politicas_update.txt' ($pol | Format-List)
    if ($pol | Where-Object { $_.NoAutoUpdate -eq 1 }) { Add-Achado MEDIO 'Updates' 'Atualização automática desabilitada por política' '' '09_Updates\politicas_update.txt' }

    if ($Completo) {
        Write-Log 'Gerando WindowsUpdate.log (pode demorar)...'
        Get-WindowsUpdateLog -LogPath (Join-Path $script:Raiz '09_Updates\WindowsUpdate.log') -ErrorAction SilentlyContinue *> $null
    }
}

# ---------------------------------------------------------------------------
# 10 INTEGRIDADE DO SISTEMA
# ---------------------------------------------------------------------------
Invoke-Etapa 'Integridade (DISM, SFC, CBS)' {
    if ($script:IsAdmin) {
        Invoke-Externo '10_Integridade' 'dism_checkhealth.txt' 'DISM /Online /Cleanup-Image /CheckHealth' 300 | Out-Null
        $txt = Get-Content (Join-Path $script:Raiz '10_Integridade\dism_checkhealth.txt') -Raw -ErrorAction SilentlyContinue
        # "Nenhuma corrupcao ... detectada" contem a palavra corrupcao: so a palavra "repar" (repairable/reparavel/reparado)
        # indica problema real. Resultado fora do esperado vira informativo.
        if ($txt -match '(?i)repar') {
            Add-Achado ALTO 'Integridade' 'Imagem do Windows com corrupção detectada pelo DISM' 'Correção: DISM /Online /Cleanup-Image /RestoreHealth e depois sfc /scannow.' '10_Integridade\dism_checkhealth.txt'
        } elseif ($txt -notmatch '(?i)(No component store corruption|Nenhuma corrup)') {
            Add-Achado BAIXO 'Integridade' 'Resultado do DISM /CheckHealth não reconhecido' 'Leia 10_Integridade\dism_checkhealth.txt.' '10_Integridade\dism_checkhealth.txt'
        }
        if ($Completo) {
            Write-Log 'Rodando SFC /verifyonly (10 a 20 minutos)...'
            Invoke-Externo '10_Integridade' 'sfc_verifyonly.txt' 'sfc /verifyonly' 1800 | Out-Null
            # SFC grava em UTF-16; normaliza para leitura
            $sfc = (Get-Content (Join-Path $script:Raiz '10_Integridade\sfc_verifyonly.txt') -Raw -ErrorAction SilentlyContinue) -replace "`0", ''
            # "nao encontrou violacoes de integridade" tambem contem "violacoes": testar a negativa primeiro
            if ($sfc -match '(?i)n.{1,3}o encontrou|did not find|found no integrity') {
                Save-Texto '10_Integridade' 'sfc_conclusao.txt' 'SFC: nenhuma violação de integridade.'
            } elseif ($sfc -match '(?i)encontrou viola|found integrity violations') {
                Add-Achado ALTO 'Integridade' 'SFC encontrou arquivos de sistema corrompidos' 'Correção: sfc /scannow (como admin).' '10_Integridade\sfc_verifyonly.txt'
            } else {
                Add-Achado BAIXO 'Integridade' 'SFC /verifyonly não concluiu ou resultado não reconhecido' 'Leia 10_Integridade\sfc_verifyonly.txt.' '10_Integridade\sfc_verifyonly.txt'
            }
        }
    }
    $cbs = "$env:SystemRoot\Logs\CBS\CBS.log"
    if (Test-Path $cbs) {
        Get-Content $cbs -Tail 3000 -ErrorAction SilentlyContinue | Out-File (Join-Path $script:Raiz '10_Integridade\CBS_ultimas3000.log') -Encoding UTF8
    }
    $dism = "$env:SystemRoot\Logs\DISM\dism.log"
    if (Test-Path $dism) {
        Get-Content $dism -Tail 2000 -ErrorAction SilentlyContinue | Out-File (Join-Path $script:Raiz '10_Integridade\dism_ultimas2000.log') -Encoding UTF8
    }

    # Repositório WMI
    $wmi = & winmgmt /verifyrepository 2>&1 | Out-String
    Save-Texto '10_Integridade' 'wmi_repositorio.txt' $wmi
    if ($script:IsAdmin -and $wmi -match 'inconsisten') {
        Add-Achado ALTO 'Integridade' 'Repositório WMI inconsistente' 'Correção: winmgmt /salvagerepository.' '10_Integridade\wmi_repositorio.txt'
    }
}


# ---------------------------------------------------------------------------
# 11 SOFTWARE
# ---------------------------------------------------------------------------
Invoke-Etapa 'Programas instalados' {
    $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              "$($script:Alvo.HKU)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $progs = Get-ItemProperty $chaves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 } |
        Select-Object DisplayName, DisplayVersion, Publisher,
            @{n = 'Instalado'; e = { if ($_.InstallDate -match '^\d{8}$') { [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } else { $_.InstallDate } } },
            @{n = 'TamanhoMB'; e = { if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1KB, 1) } } }, InstallLocation,
            @{n = 'Escopo'; e = { if ($_.PSPath -match 'HKEY_USERS') { 'Usuário' } elseif ($_.PSPath -match 'WOW6432') { '32 bits' } else { '64 bits' } } } |
        Sort-Object DisplayName -Unique
    Save-Csv '11_Software' 'programas_instalados.csv' $progs

    $recentes = $progs | Where-Object { $_.Instalado -match '^\d{4}-' -and [datetime]$_.Instalado -ge $script:DesdeData }
    Save-Csv '11_Software' 'instalados_no_periodo.csv' $recentes
    if ($recentes) {
        Add-Achado INFO 'Software' "$(($recentes | Measure-Object).Count) programa(s) instalado(s)/atualizado(s) nos últimos $Dias dias" `
            'Se o problema comecou recentemente, confira esta lista.' '11_Software\instalados_no_periodo.csv'
    }

    # Softwares de acesso remoto (evidência útil em incidentes)
    $remotos = $progs | Where-Object DisplayName -match 'AnyDesk|TeamViewer|RustDesk|UltraViewer|Supremo|ScreenConnect|ConnectWise|Splashtop|RemotePC|Ammyy|LogMeIn|NinjaOne|Atera|VNC'
    if ($remotos) {
        Add-Achado INFO 'Segurança' "Software de acesso remoto instalado: $(($remotos.DisplayName | Select-Object -Unique) -join ', ')" 'Confirme se é autorizado.' '11_Software\programas_instalados.csv'
    }

    # Com elevacao por outra conta, lista os apps do usuario logado (exige admin)
    $appxArg = @{}
    if ($script:Alvo.Outro -and $script:IsAdmin) { $appxArg['User'] = $script:Alvo.SID }
    $apps = @(Get-AppxPackage @appxArg -ErrorAction SilentlyContinue)
    Save-Csv '11_Software' 'apps_store.csv' ($apps | Select-Object Name, Version, Publisher, InstallLocation, Status)
    $quebrados = $apps | Where-Object { $_.Status -ne 'Ok' }
    if ($quebrados) { Add-Achado BAIXO 'Software' "$(($quebrados | Measure-Object).Count) app(s) da Store com status de erro" (($quebrados.Name | Select-Object -First 5) -join ', ') }

    Invoke-Externo '11_Software' 'dotnet_versoes.txt' 'reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP" /s /v Version' 30 | Out-Null
}

Invoke-Etapa 'Inicialização automática' {
    $itens = New-Object System.Collections.Generic.List[object]
    $runs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', "$($script:Alvo.HKU)\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "$($script:Alvo.HKU)\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    foreach ($r in $runs) {
        $p = Get-ItemProperty $r -ErrorAction SilentlyContinue
        if ($p) { foreach ($prop in $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $itens.Add([pscustomobject]@{ Local = $r; Nome = $prop.Name; Comando = (Remove-Segredo ([string]$prop.Value)) }) } }
    }
    foreach ($pasta in (Join-Path $script:Alvo.Perfil 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'), "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup") {
        Get-ChildItem $pasta -ErrorAction SilentlyContinue | ForEach-Object { $itens.Add([pscustomobject]@{ Local = $pasta; Nome = $_.Name; Comando = $_.FullName }) }
    }
    Save-Csv '11_Software' 'inicializacao.csv' $itens.ToArray()
    if ($itens.Count -gt 25) { Add-Achado BAIXO 'Desempenho' "$($itens.Count) itens na inicialização automática" 'Muitos itens deixam o logon lento.' '11_Software\inicializacao.csv' }

    # Winlogon alterado (Shell/Userinit) é sinal clássico de malware
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    Save-Texto '11_Software' 'winlogon.txt' ($wl | Select-Object Shell, Userinit, AutoAdminLogon, DefaultUserName | Format-List)
    if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { Add-Achado ALTO 'Segurança' "Shell do Winlogon alterado: $($wl.Shell)" 'Esperado: explorer.exe' }
    if ($wl.Userinit -and $wl.Userinit.TrimEnd(',') -notmatch '^C:\\Windows\\system32\\userinit\.exe$') { Add-Achado ALTO 'Segurança' "Userinit alterado: $($wl.Userinit)" }
    if ($wl.AutoAdminLogon -eq '1') { Add-Achado MEDIO 'Segurança' "Logon automático habilitado (usuário $($wl.DefaultUserName))" }
}

Invoke-Etapa 'Tarefas agendadas' {
    $tarefas = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object State -ne 'Disabled'
    $info = foreach ($t in $tarefas) {
        $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        [pscustomobject]@{ Caminho = $t.TaskPath; Nome = $t.TaskName; Estado = $t.State; UltimaExecucao = $i.LastRunTime
            UltimoResultado = if ($null -ne $i.LastTaskResult) { '0x{0:X}' -f $i.LastTaskResult } else { '' }; Proxima = $i.NextRunTime
            Acao = Remove-Segredo (($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | '); Autor = $t.Author }
    }
    Save-Csv '11_Software' 'tarefas_agendadas.csv' $info
    # 0x0 ok, 0x41301 rodando, 0x41303 nunca rodou, 0x41325 enfileirada, 0x800710E0 recusada por condição
    $normais = '0x0', '0x41300', '0x41301', '0x41303', '0x41325', '0x800710E0', '0x8004131F', '0x1', ''
    $falhas = $info | Where-Object { $_.UltimoResultado -notin $normais -and $_.Caminho -notlike '\Microsoft\*' }
    Save-Csv '11_Software' 'tarefas_com_falha.csv' $falhas
    if ($falhas) {
        Add-Achado BAIXO 'Software' "$(($falhas | Measure-Object).Count) tarefa(s) agendada(s) de terceiros com falha na última execução" (($falhas | Select-Object -First 5 | ForEach-Object { "$($_.Nome) [$($_.UltimoResultado)]" }) -join '; ') '11_Software\tarefas_com_falha.csv'
    }
}

Invoke-Etapa 'Impressoras' {
    Save-Csv '11_Software' 'impressoras.csv' (Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, DriverName, PortName, Shared, PrinterStatus, Type)
    $fila = Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue }
    if ($fila) {
        Save-Csv '11_Software' 'fila_impressao.csv' ($fila | Select-Object PrinterName, DocumentName, JobStatus, SubmittedTime, UserName)
        $travados = $fila | Where-Object { $_.JobStatus -match 'Error|Paused|Blocked' -or $_.SubmittedTime -lt (Get-Date).AddHours(-2) }
        if ($travados) { Add-Achado BAIXO 'Software' "$(($travados | Measure-Object).Count) trabalho(s) de impressão travado(s)" '' '11_Software\fila_impressao.csv' }
    }
}

Invoke-Etapa 'Office, OneDrive, Teams e navegadores' {
    $perfil = $script:Alvo.Perfil
    $hku = $script:Alvo.HKU
    $itens = New-Object System.Collections.Generic.List[object]
    $add = { param($grupo, $item, $valor) $itens.Add([pscustomobject]@{ Grupo = $grupo; Item = $item; Valor = $valor }) }

    # Microsoft 365 Apps (Click-to-Run)
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r) {
        $canais = @{
            '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
            '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
            '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
            '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
            'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
            '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
        }
        $guid = ("$($c2r.CDNBaseUrl)" -split '/')[-1]
        $canal = if ($canais.ContainsKey($guid)) { $canais[$guid] } else { "desconhecido ($guid)" }
        & $add 'Office' 'Versão' $c2r.VersionToReport
        & $add 'Office' 'Canal de atualização' $canal
        & $add 'Office' 'Plataforma' $c2r.Platform
        & $add 'Office' 'Produtos' $c2r.ProductReleaseIds
        & $add 'Office' 'Atualizações habilitadas' $c2r.UpdatesEnabled
        if ("$($c2r.UpdatesEnabled)" -eq 'False') { Add-Achado BAIXO 'Office' 'Atualizações automáticas do Office desabilitadas' 'Política ou configuração local impede updates.' '11_Software\office_colaboracao.csv' }
    } else {
        & $add 'Office' 'Click-to-Run' 'não instalado'
    }

    # Suplementos e suplementos desabilitados por falha (Resiliency)
    $falhaAddin = New-Object System.Collections.Generic.List[string]
    foreach ($app in 'Outlook', 'Word', 'Excel', 'PowerPoint') {
        $vistos = @{}
        foreach ($raiz in @(@('HKLM', "HKLM:\SOFTWARE\Microsoft\Office\$app\Addins"), @('HKLM-32bit', "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$app\Addins"), @('Usuário', "$hku\Software\Microsoft\Office\$app\Addins"))) {
            foreach ($k in Get-ChildItem $raiz[1] -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                $chv = "$($k.PSChildName)|$($raiz[0] -replace '-32bit', '')"
                if ($vistos.ContainsKey($chv)) { continue }
                $vistos[$chv] = $true
                & $add "Suplemento $app" $k.PSChildName ("{0} | LoadBehavior={1} | {2}" -f $p.FriendlyName, $p.LoadBehavior, $raiz[0])
            }
        }
        $res = "$hku\Software\Microsoft\Office\16.0\$app\Resiliency"
        foreach ($sub in 'DisabledItems', 'CrashingAddinList') {
            $k = Get-Item "$res\$sub" -ErrorAction SilentlyContinue
            if ($k) {
                foreach ($vn in $k.GetValueNames()) {
                    $v = $k.GetValue($vn)
                    $nome = if ($v -is [byte[]]) { ([Text.Encoding]::Unicode.GetString($v) -replace '[^\x20-\x7E]', ' ' -replace '\s+', ' ').Trim() } else { $vn }
                    & $add "Resiliency $app" $sub $nome
                    $falhaAddin.Add("${app}: $nome")
                }
            }
        }
    }
    if ($falhaAddin.Count) {
        $lista = ($falhaAddin.ToArray() | Select-Object -Unique) -join ' | '
        $relevantes = @($falhaAddin.ToArray() | Where-Object { $_ -notmatch 'visualiza|preview' })
        $sev = if ($relevantes.Count) { 'MEDIO' } else { 'BAIXO' }
        Add-Achado $sev 'Office' "$($falhaAddin.Count) item(ns) desativado(s) pelo próprio Office por falha (Resiliency)" "O Office desativa suplementos e visualizadores que travam. Itens: $lista" '11_Software\office_colaboracao.csv'
    }

    # Caixas de e-mail locais (OST/PST). O OST tem limite padrao de 50 GB.
    $ost = foreach ($dir in (Join-Path $perfil 'AppData\Local\Microsoft\Outlook'), (Join-Path $perfil 'Documents\Outlook Files')) {
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.ost', '.pst', '.nst' } |
            Select-Object Name, @{n = 'Tamanho'; e = { Format-Bytes $_.Length } }, @{n = 'Bytes'; e = { $_.Length } }, LastWriteTime, DirectoryName
    }
    Save-Csv '11_Software' 'outlook_ost_pst.csv' $ost
    foreach ($o in $ost | Where-Object { $_.Bytes -gt 40GB }) {
        Add-Achado MEDIO 'Office' "Arquivo do Outlook com $($o.Tamanho): $($o.Name)" 'O OST/PST perto do limite (50 GB) fica lento e pode corromper. Reduza o período de cache ou arquive.' '11_Software\outlook_ost_pst.csv'
    }

    # OneDrive
    $od = Get-Process OneDrive -ErrorAction SilentlyContinue
    $contas = @(Get-ChildItem "$hku\Software\Microsoft\OneDrive\Accounts" -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath })
    & $add 'OneDrive' 'Em execução' ([bool]$od)
    & $add 'OneDrive' 'Versão' (Get-ItemProperty "$hku\Software\Microsoft\OneDrive" -ErrorAction SilentlyContinue).Version
    foreach ($c in $contas | Where-Object { $_.UserEmail -or $_.UserFolder }) {
        $mail = if ($SemDadosSensiveis) { '(oculto)' } else { $c.UserEmail }
        & $add 'OneDrive' 'Conta' ("{0} | pasta: {1}" -f $mail, $c.UserFolder)
    }
    if ($contas.Count -and -not $od) { Add-Achado MEDIO 'Office' 'OneDrive configurado mas não está em execução' 'Sincronização parada: arquivos podem estar desatualizados.' '11_Software\office_colaboracao.csv' }

    # Teams (novo e classico)
    $apps = @(Get-AppxPackage MSTeams -ErrorAction SilentlyContinue)
    foreach ($a in $apps) { & $add 'Teams' 'Novo Teams (MSTeams)' $a.Version }
    $classico = Join-Path $perfil 'AppData\Local\Microsoft\Teams\current\Teams.exe'
    if (Test-Path -LiteralPath $classico) {
        & $add 'Teams' 'Teams clássico' (Get-Item -LiteralPath $classico).VersionInfo.ProductVersion
        Add-Achado BAIXO 'Office' 'Teams clássico ainda instalado' 'O Teams clássico foi descontinuado; migre para o novo Teams.' '11_Software\office_colaboracao.csv'
    }

    # WebView2 e navegadores
    $wv = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue).pv
    & $add 'Navegadores' 'WebView2 Runtime' $(if ($wv) { $wv } else { 'não instalado' })
    if (-not $wv) { Add-Achado BAIXO 'Office' 'WebView2 Runtime ausente' 'Necessário ao novo Outlook, Teams e vários aplicativos.' '11_Software\office_colaboracao.csv' }
    $navs = @{
        'Edge'   = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        'Chrome' = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        'Chrome (x86)' = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        'Firefox' = "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
    }
    foreach ($n in $navs.Keys) {
        if (Test-Path -LiteralPath $navs[$n]) { & $add 'Navegadores' $n (Get-Item -LiteralPath $navs[$n]).VersionInfo.ProductVersion }
    }
    Save-Csv '11_Software' 'office_colaboracao.csv' $itens.ToArray()
}


# ---------------------------------------------------------------------------
# 12 ENERGIA
# ---------------------------------------------------------------------------
Invoke-Etapa 'Energia' {
    Invoke-Externo '12_Energia' 'plano_ativo.txt' 'powercfg /getactivescheme' 30 | Out-Null
    Invoke-Externo '12_Energia' 'estados_suspensao.txt' 'powercfg /a' 30 | Out-Null
    Invoke-Externo '12_Energia' 'ultimo_despertar.txt' 'powercfg /lastwake' 30 | Out-Null
    Invoke-Externo '12_Energia' 'dispositivos_que_acordam.txt' 'powercfg /devicequery wake_armed' 30 | Out-Null
    Invoke-Externo '12_Energia' 'bloqueios_suspensao.txt' 'powercfg /requests' 30 | Out-Null
    if ($script:IsAdmin) {
        $html = Join-Path $script:Raiz '12_Energia\sleepstudy.html'
        Invoke-Externo '12_Energia' 'sleepstudy_saida.txt' "powercfg /sleepstudy /output `"$html`"" 90 | Out-Null
        if ($Completo) {
            Write-Log 'Rodando powercfg /energy (60 segundos)...'
            $en = Join-Path $script:Raiz '12_Energia\energy_report.html'
            Invoke-Externo '12_Energia' 'energy_saida.txt' "powercfg /energy /output `"$en`" /duration 60" 150 | Out-Null
            $saida = Get-Content (Join-Path $script:Raiz '12_Energia\energy_saida.txt') -Raw -ErrorAction SilentlyContinue
            if ($saida -match '(\d+)\s+(Errors|Erros)') { if ([int]$matches[1] -gt 0) {
                Add-Achado BAIXO 'Energia' "powercfg /energy reportou $($matches[1]) erro(s) de eficiência energética" '' '12_Energia\energy_report.html' } }
        }
    }
    $fast = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    Save-Texto '12_Energia' 'inicializacao_rapida.txt' "Inicialização rápida (Fast Startup): $(if ($fast -eq 1) { 'ATIVADA' } else { 'desativada' })"
    if ($fast -eq 1) {
        Add-Achado INFO 'Energia' 'Inicialização rápida (Fast Startup) ativada' '"Desligar" não zera o kernel: o uptime continua contando e drivers não reiniciam. Use Reiniciar para testes.'
    }
}

# ---------------------------------------------------------------------------
# 13 POLITICAS
# ---------------------------------------------------------------------------
Invoke-Etapa 'Políticas de grupo' {
    if ($SemDadosSensiveis) {
        Save-Texto '13_Politicas' 'gpresult_nao_coletado.txt' 'Modo -SemDadosSensiveis: gpresult não coletado.'
    } else {
        $escopo = if ($script:IsAdmin) { '' } else { '/scope user' }
        # gpresult recusa caminhos com mais de 127 caracteres (Desktop no OneDrive estoura): gera em pasta curta e move
        $base = if ($env:TEMP.Length -le 80) { $env:TEMP } else { $env:PUBLIC }
        $tmp = Join-Path $base ('gp_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')
        Invoke-Externo '13_Politicas' 'gpresult_saida.txt' "gpresult /h `"$tmp`" /f $escopo" 180 | Out-Null
        if (Test-Path -LiteralPath $tmp) {
            Move-Item -LiteralPath $tmp -Destination (Join-Path $script:Raiz '13_Politicas\gpresult.html') -Force
        } else {
            Add-Lacuna 'gpresult.html' 'relatório não foi gerado (veja gpresult_saida.txt)'
        }
        Invoke-Externo '13_Politicas' 'gpresult_resumo.txt' "gpresult /r $escopo" 120 | Out-Null
    }

    $cs = Get-CimSeguro Win32_ComputerSystem
    if (-not $cs) { $cs = (Get-DadosSistemaSemWmi).CS }
    if ($cs.PartOfDomain) {
        # Test-ComputerSecureChannel tambem falha quando o DC esta inacessivel (fora da rede/VPN): checar o DC antes
        $rc = Invoke-Externo '13_Politicas' 'nltest_dc.txt' "nltest /dsgetdc:$($cs.Domain)" 30
        if ($rc -ne 0) {
            Add-Achado MEDIO 'Rede' 'Controlador de domínio inacessível' "nltest /dsgetdc:$($cs.Domain) falhou (código $rc). Máquina fora da rede corporativa/VPN, DNS interno indisponível ou DC fora do ar. O canal seguro não foi testado." '13_Politicas\nltest_dc.txt'
        } elseif ($script:IsAdmin) {
            $canal = $null
            try { $canal = Test-ComputerSecureChannel -ErrorAction Stop } catch { Add-Lacuna 'canal seguro com o domínio' $_.Exception.Message }
            Save-Texto '13_Politicas' 'canal_seguro_dominio.txt' "Canal seguro com o domínio: $canal"
            if ($canal -eq $false) {
                Add-Achado CRITICO 'Rede' 'Relação de confiança com o domínio quebrada' 'DC acessível, mas o canal seguro falhou. Correção: Test-ComputerSecureChannel -Repair -Credential (Get-Credential)' '13_Politicas\canal_seguro_dominio.txt'
            }
        } else {
            Add-Lacuna 'canal seguro com o domínio' 'requer administrador'
        }
    }
}

if ($Completo) {
    Invoke-Etapa 'msinfo32' {
        Write-Log 'Gerando relatório msinfo32 (pode levar alguns minutos)...'
        $nfo = Join-Path $script:Raiz '01_Sistema\msinfo32.txt'
        $p = Start-Process msinfo32.exe -ArgumentList "/report `"$nfo`"" -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { }; Write-Log 'msinfo32 excedeu 10 minutos' 'AVISO' }
    }
}


Invoke-Etapa 'Linha do tempo' {
    # Junta mudancas (updates, instalacoes, servicos novos, drivers) e problemas (travamentos, crashes, ameacas)
    # em uma unica ordem cronologica, para responder "o que mudou antes de comecar?".
    $tl = New-Object System.Collections.Generic.List[object]
    $reg = { param($data, $tipo, $evento, $detalhe)
        $d = [string]$detalhe
        if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + '...' }
        $tl.Add([pscustomobject]@{ Data = $data; Tipo = $tipo; Evento = $evento; Detalhe = (Remove-Segredo $d) }) }
    $cond = { param($m) ($m -replace '\s+', ' ').Trim() }

    # Boots e desligamentos
    foreach ($e in Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12, 13; StartTime = $script:DesdeData } 500) {
        & $reg $e.TimeCreated 'Boot' $(if ($e.Id -eq 12) { 'Sistema iniciado' } else { 'Sistema desligado' }) ''
    }
    foreach ($e in Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074; StartTime = $script:DesdeData } 300) {
        & $reg $e.TimeCreated 'Boot' 'Reinicio/desligamento solicitado' (& $cond $e.Message)
    }
    foreach ($l in $script:Travamentos) {
        & $reg $l.Data $l.Tipo $(if ($l.Codigo) { $l.Codigo } else { 'sem bugcheck' }) $l.Significado
    }
    # Servicos instalados, falhas de servico
    foreach ($e in Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7045; StartTime = $script:DesdeData } 300) {
        & $reg $e.TimeCreated 'Serviço novo' "Serviço instalado: $($e.Properties[0].Value)" "$($e.Properties[1].Value)"
    }
    foreach ($e in Get-EventosSeguro @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $script:DesdeData } 300) {
        & $reg $e.TimeCreated 'Falha de serviço' "Serviço encerrou: $($e.Properties[0].Value)" ''
    }
    # Instalacoes (MSI), crashes de aplicativos, servicing do Windows e ameacas
    foreach ($e in Get-EventosSeguro @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 11707, 11708, 11724; StartTime = $script:DesdeData } 500) {
        $tipo = if ($e.Id -eq 11724) { 'Desinstalação' } else { 'Instalação' }
        & $reg $e.TimeCreated $tipo (& $cond $e.Message) ''
    }
    foreach ($e in Get-EventosSeguro @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002; StartTime = $script:DesdeData } 500) {
        & $reg $e.TimeCreated 'Travamento de app' "$($e.Properties[0].Value)" "modulo: $(if ($e.Id -eq 1000) { $e.Properties[3].Value })"
    }
    foreach ($e in Get-EventosSeguro @{ LogName = 'Setup'; Id = 2; StartTime = $script:DesdeData } 500) {
        & $reg $e.TimeCreated 'Update' 'Pacote do Windows instalado' (& $cond $e.Message)
    }
    foreach ($e in Get-EventosSeguro @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116; StartTime = $script:DesdeData } 200) {
        & $reg $e.TimeCreated 'Ameaça' 'Defender detectou ameaça' (& $cond $e.Message)
    }
    # Historico do Windows Update
    try {
        $busca = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $n = $busca.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($h in $busca.QueryHistory(0, [math]::Min($n, 200)) | Where-Object { $_.Date -ge $script:DesdeData }) {
                $res = switch ([int]$h.ResultCode) { 2 { 'instalado' } 3 { 'instalado com erros' } 4 { 'FALHOU' } 5 { 'abortado' } default { 'em andamento' } }
                $tipo = if ($h.Title -match '^[0-9A-Z]{12}-') { 'App da Store' } elseif ($h.Title -match 'Driver|Extension|Firmware|Corporation') { 'Driver' } else { 'Update' }
                & $reg $h.Date $tipo "$res : $($h.Title)" ('0x{0:X8}' -f $h.HResult)
            }
        }
    } catch { }
    # Programas instalados no periodo (so a data, sem hora)
    foreach ($p in @(Import-Csv -LiteralPath (Join-Path $script:Raiz '11_Software\instalados_no_periodo.csv') -Delimiter ';' -ErrorAction SilentlyContinue)) {
        if ($p.Instalado -match '^\d{4}-\d{2}-\d{2}$') { & $reg ([datetime]$p.Instalado) 'Instalação' "$($p.DisplayName) $($p.DisplayVersion)" $p.Publisher }
    }

    # O historico do Windows Update repete o mesmo item varias vezes no mesmo minuto: agrupa
    $ordenado = $tl.ToArray() | Group-Object { '{0:yyyyMMddHHmm}|{1}|{2}' -f $_.Data, $_.Tipo, $_.Evento } | ForEach-Object {
        $x = $_.Group[0]
        if ($_.Count -gt 1) { $x.Evento = "$($x.Evento) (x$($_.Count))" }
        $x
    } | Sort-Object Data -Descending
    Save-Csv '03_Eventos' 'linha_do_tempo.csv' $ordenado
    $txt = $ordenado | Select-Object -First 400 | ForEach-Object { '{0:dd/MM/yyyy HH:mm}  {1,-22} {2}  {3}' -f $_.Data, $_.Tipo, $_.Evento, $_.Detalhe }
    Save-Texto '03_Eventos' 'linha_do_tempo.txt' $txt

    # Correlacao: o que mudou nas 48 h antes do primeiro travamento do sistema do periodo?
    $primeiro = $tl.ToArray() | Where-Object { $_.Tipo -in 'Tela azul', 'Desligamento inesperado' } | Sort-Object Data | Select-Object -First 1
    if ($primeiro) {
        $ini = $primeiro.Data.AddHours(-48)
        $mud = @($tl.ToArray() | Where-Object { $_.Tipo -in 'Update', 'Driver', 'Instalação', 'Desinstalação', 'Serviço novo' -and $_.Data -ge $ini -and $_.Data -le $primeiro.Data } | Sort-Object Data)
        if ($mud.Count) {
            $lista = ($mud | Select-Object -First 6 | ForEach-Object { "$($_.Data.ToString('dd/MM HH:mm')) $($_.Tipo): $($_.Evento)" }) -join ' | '
            Add-Achado INFO 'Correlação' "$($mud.Count) mudança(s) nas 48 h antes do primeiro travamento do período ($($primeiro.Data.ToString('dd/MM HH:mm')))" $lista '03_Eventos\linha_do_tempo.txt'
        }
    }
}

# ---------------------------------------------------------------------------
# RESUMO
# ---------------------------------------------------------------------------
function ConvertTo-Html-Seguro([string]$t) { [System.Net.WebUtility]::HtmlEncode($t) }

$script:EtapaAtual = 'Resumo'
$duracao  = (Get-Date) - $script:Inicio
$achados  = @($script:Achados.ToArray() | Sort-Object Ordem, Categoria)
$etapas   = $script:Etapas.ToArray()
$contagem = @{}; foreach ($s in 'CRITICO', 'ALTO', 'MEDIO', 'BAIXO', 'INFO') { $contagem[$s] = @($achados | Where-Object Severidade -eq $s).Count }
if ($script:InfoSistema) {
    $script:InfoSistema['UsuarioLogado'] = $script:Alvo.Nome
    $script:InfoSistema['SemDadosSensiveis'] = [bool]$SemDadosSensiveis
}

# Chave estavel de um achado (numeros viram #): permite comparar execucoes mesmo que contagens mudem
$chave = { param($a) ('{0}|{1}' -f $a.Categoria, ($a.Titulo -replace '\d+', '#')) }

# Comparacao com execucao anterior (-Comparar achados.json)
$novos = @(); $resolvidos = @(); $anteriorEm = ''
if ($Comparar) {
    if (Test-Path -LiteralPath $Comparar) {
        try {
            $ant = Get-Content -LiteralPath $Comparar -Raw -Encoding UTF8 | ConvertFrom-Json
            $anteriorEm = $ant.GeradoEm
            $kAnt = @{}; foreach ($a in $ant.Achados) { $kAnt[$a.Chave] = $a }
            $kAtu = @{}; foreach ($a in $achados) { $kAtu[(& $chave $a)] = $a }
            $novos      = @($achados | Where-Object { -not $kAnt.ContainsKey((& $chave $_)) })
            $resolvidos = @($ant.Achados | Where-Object { -not $kAtu.ContainsKey($_.Chave) })
        } catch { Add-Lacuna 'comparação com execução anterior' $_.Exception.Message }
    } else { Add-Lacuna 'comparação com execução anterior' "arquivo não encontrado: $Comparar" }
}
$lacunas = $script:Lacunas.ToArray()

$veredito = if ($contagem.CRITICO) { 'Problemas críticos encontrados. Comece pelos itens em vermelho.' }
            elseif ($contagem.ALTO) { 'Problemas relevantes encontrados. Veja os itens de severidade alta.' }
            elseif ($contagem.MEDIO) { 'Máquina funcional, com pontos de atenção.' }
            else { 'Nenhum problema relevante detectado nas evidências coletadas.' }
if ($lacunas.Count) { $veredito += " Atenção: $($lacunas.Count) item(ns) NÃO foram coletados (veja Lacunas de coleta); a ausência de achados neles não significa que estão saudáveis." }

# JSON (para comparar execucoes e maquinas)
$sis = [ordered]@{}
if ($script:InfoSistema) { foreach ($k in $script:InfoSistema.Keys) { $sis[$k] = [string]$script:InfoSistema[$k] } }
$json = [ordered]@{
    VersaoScript = $script:Versao; GeradoEm = (Get-Date).ToString('s'); Computador = $env:COMPUTERNAME; DiasAnalisados = $Dias
    Admin = $script:IsAdmin; Completo = [bool]$Completo; SemDadosSensiveis = [bool]$SemDadosSensiveis; UsuarioAlvo = $script:Alvo.Nome
    Sistema = $sis
    Achados = @($achados | ForEach-Object { [ordered]@{ Chave = (& $chave $_); Severidade = $_.Severidade; Categoria = $_.Categoria
        Titulo = $_.Titulo; Detalhe = $_.Detalhe; Evidencia = $_.Evidencia } })
    Lacunas = @($lacunas | ForEach-Object { [ordered]@{ Etapa = $_.Etapa; Item = $_.Item; Motivo = $_.Motivo } })
    Etapas = @($etapas | ForEach-Object { [ordered]@{ Etapa = $_.Etapa; Status = $_.Status; Segundos = $_.Segundos; Erro = $_.Erro } })
}
$json | ConvertTo-Json -Depth 6 | Out-File (Join-Path $script:Raiz 'achados.json') -Encoding UTF8
Save-Csv '.' 'achados.csv' ($achados | Select-Object Severidade, Categoria, Titulo, Detalhe, Evidencia)
Save-Csv '.' 'lacunas.csv' $lacunas

# Resumo em texto (para colar em chamado)
$txt = New-Object System.Text.StringBuilder
[void]$txt.AppendLine("DIAGNÓSTICO WINDOWS v$($script:Versao): $env:COMPUTERNAME")
[void]$txt.AppendLine("Gerado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm') | Período analisado: $Dias dias | Duração: $([int]$duracao.TotalMinutes) min $($duracao.Seconds) s | Admin: $script:IsAdmin | Usuário: $($script:Alvo.Nome)")
if ($script:InfoSistema) { [void]$txt.AppendLine("SO: $($script:InfoSistema.SO) $($script:InfoSistema.DisplayVersion) build $($script:InfoSistema.Build) | $($script:InfoSistema.Fabricante) $($script:InfoSistema.Modelo) | Uptime $($script:InfoSistema.Uptime)") }
[void]$txt.AppendLine("Críticos: $($contagem.CRITICO) | Altos: $($contagem.ALTO) | Médios: $($contagem.MEDIO) | Baixos: $($contagem.BAIXO) | Info: $($contagem.INFO) | Lacunas: $($lacunas.Count)")
[void]$txt.AppendLine("Veredito: $veredito")
[void]$txt.AppendLine(('-' * 80))
foreach ($a in $achados) {
    [void]$txt.AppendLine("[$($script:Rotulo[$a.Severidade])] $($a.Categoria): $($a.Titulo)")
    if ($a.Detalhe)   { [void]$txt.AppendLine("    $($a.Detalhe)") }
    if ($a.Evidencia) { [void]$txt.AppendLine("    Evidência: $($a.Evidencia)") }
}
if ($lacunas.Count) {
    [void]$txt.AppendLine(('-' * 80)); [void]$txt.AppendLine('LACUNAS DE COLETA (não foi possível coletar)')
    foreach ($l in $lacunas) { [void]$txt.AppendLine("  [$($l.Etapa)] $($l.Item): $($l.Motivo)") }
}
if ($Comparar) {
    [void]$txt.AppendLine(('-' * 80)); [void]$txt.AppendLine("COMPARAÇÃO COM A EXECUÇÃO DE $anteriorEm")
    foreach ($a in $novos) { [void]$txt.AppendLine("  NOVO      [$($script:Rotulo[$a.Severidade])] $($a.Titulo)") }
    foreach ($a in $resolvidos) { [void]$txt.AppendLine("  RESOLVIDO [$($script:Rotulo[$a.Severidade])] $($a.Titulo)") }
}
[void]$txt.AppendLine(('-' * 80))
[void]$txt.AppendLine('ETAPAS')
foreach ($e in $etapas) { [void]$txt.AppendLine(('{0,-7} {1,6}s  {2} {3}' -f $e.Status, $e.Segundos, $e.Etapa, $e.Erro)) }
$txt.ToString() | Out-File (Join-Path $script:Raiz 'RESUMO.txt') -Encoding UTF8

@"
Diagnóstico Windows v$($script:Versao): $env:COMPUTERNAME
Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm')

COMO LER
  1. RESUMO.html (ou RESUMO.txt): achados por severidade, com o arquivo de evidência de cada um.
  2. 03_Eventos\linha_do_tempo.txt: o que mudou e o que falhou, em ordem cronológica.
  3. lacunas.csv: o que NÃO foi coletado (sem admin, sem permissão, timeout). Ausência de achado nesses itens não é prova de saúde.
  4. achados.json: mesmo conteúdo em JSON; use -Comparar para ver o que mudou entre duas execuções.

PASTAS
  01_Sistema 02_Hardware 03_Eventos 04_Falhas 05_Desempenho 06_Servicos 07_Rede
  08_Seguranca 09_Updates 10_Integridade 11_Software 12_Energia 13_Politicas

CONFIDENCIALIDADE
  Este material pode conter nomes de usuário, programas instalados, redes e logs. Trate como confidencial.
  Modo sem dados sensíveis: $([bool]$SemDadosSensiveis)
  Os arquivos .evtx abrem no Visualizador de Eventos do Windows.
"@ | Out-File (Join-Path $script:Raiz 'LEIA-ME.txt') -Encoding UTF8

# Resumo em HTML
$cores = @{ CRITICO = '#c62828'; ALTO = '#ef6c00'; MEDIO = '#f9a825'; BAIXO = '#1565c0'; INFO = '#607d8b' }
$linhas = foreach ($a in $achados) {
    $ev = if ($a.Evidencia) { "<a href=""$(ConvertTo-Html-Seguro ($a.Evidencia -replace '\\', '/'))"">$(ConvertTo-Html-Seguro $a.Evidencia)</a>" } else { '' }
    "<tr><td><span class='tag' style='background:$($cores[$a.Severidade])'>$($script:Rotulo[$a.Severidade])</span></td><td>$(ConvertTo-Html-Seguro $a.Categoria)</td>" +
    "<td><b>$(ConvertTo-Html-Seguro $a.Titulo)</b><div class='det'>$(ConvertTo-Html-Seguro $a.Detalhe)</div></td><td class='ev'>$ev</td></tr>"
}
$cards = foreach ($s in 'CRITICO', 'ALTO', 'MEDIO', 'BAIXO', 'INFO') {
    "<div class='card' style='border-top:4px solid $($cores[$s])'><div class='num'>$($contagem[$s])</div><div>$($script:Rotulo[$s])</div></div>"
}
$cards = @($cards) + "<div class='card' style='border-top:4px solid #6a1b9a'><div class='num'>$($lacunas.Count)</div><div>LACUNAS</div></div>"
$sisHtml = if ($script:InfoSistema) {
    ($script:InfoSistema.GetEnumerator() | ForEach-Object { "<tr><th>$($_.Key)</th><td>$(ConvertTo-Html-Seguro ([string]$_.Value))</td></tr>" }) -join ''
} else { '' }
$lEtapas = foreach ($e in $etapas) {
    $c = if ($e.Status -eq 'OK') { '#2e7d32' } else { '#c62828' }
    "<tr><td style='color:$c'><b>$($e.Status)</b></td><td>$(ConvertTo-Html-Seguro $e.Etapa)</td><td>$($e.Segundos)s</td><td>$(ConvertTo-Html-Seguro $e.Erro)</td></tr>"
}
$lLacunas = foreach ($l in $lacunas) {
    "<tr><td>$(ConvertTo-Html-Seguro $l.Etapa)</td><td>$(ConvertTo-Html-Seguro $l.Item)</td><td>$(ConvertTo-Html-Seguro $l.Motivo)</td></tr>"
}
$secLacunas = if ($lacunas.Count) { "<h2>Lacunas de coleta</h2><p class='sub'>Itens que o script não conseguiu coletar. Não há achado sobre eles, mas isso não prova que estejam saudáveis.</p><table><tr><th>Etapa</th><th>Item</th><th>Motivo</th></tr>$($lLacunas -join "`n")</table>" } else { '' }
$secComp = ''
if ($Comparar) {
    $lc = @($novos | ForEach-Object { "<tr><td><span class='tag' style='background:#c62828'>NOVO</span></td><td>$($script:Rotulo[$_.Severidade])</td><td>$(ConvertTo-Html-Seguro $_.Titulo)</td></tr>" }) +
          @($resolvidos | ForEach-Object { "<tr><td><span class='tag' style='background:#2e7d32'>RESOLVIDO</span></td><td>$($script:Rotulo[$_.Severidade])</td><td>$(ConvertTo-Html-Seguro $_.Titulo)</td></tr>" })
    $secComp = "<h2>Comparação com a execução de $(ConvertTo-Html-Seguro $anteriorEm)</h2><p class='sub'>$($novos.Count) novo(s), $($resolvidos.Count) resolvido(s).</p><table><tr><th>Situação</th><th>Severidade</th><th>Achado</th></tr>$($lc -join "`n")</table>"
}

# Logo da Nextec embutido em base64 (logo-dark.png): o relatório continua sendo um arquivo único
$logoNextec = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAABDUAAADNCAYAAACo/kuGAAAACXBIWXMAABYlAAAWJQFJUiTwAAAgAElEQVR4nO3dT3LiyPb28YdfVDAjLncFF6+gXQPGhYeM2rWCxisoewW2V2DXCkyvoNwjhlaPGZheQemu4PIGMya8gzwqy5j/KDMl8f1EVBS2QUokIZRHJ09KAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQL00YjcA2KbfmPeWfjUZLZrTGG0BAAAAAJQHQQ2UUr8xv5T0h6TLNU9JJN2PFs0kUJMAAAAAACVDUAOl0m/MB5JuJXV2fMn9aNG889UeAAAAAEB5EdRAdP3GvC3pWi4zo3PAIr6OFs3nQhsFAAAAACg9ghqIpt+YdyQNJH2T1D5iUelo0Twrok0AAAAAgOogqIHgLJhxKxfQKMrn0aI5KXB5AAAAAICS+xS7ATgdNovJN60v/nmMYzI9AAAAAAAVRFAD3tlMJt8k9SI3BQAAAABQIwQ14M0BM5kcg6EnAAAAAHBiCGqgUAXMZHKIdLRoTgOtCwAAAABQEgQ1UIgCZzI5RBJ4fQAAAACAEiCogaN4mslkX39HXDcAAAAAIBKCGjiI55lM9pXEbgAAAAAAIDyCGtiLBTNuVZ6ZTNLRopnGbgQAAAAAIDyCGthJ4JlM9pHEbgAAAAAAIA6CGljLZjIZyA0z6URtzHrU0wAAAACAE0VQAx/kpmWNMZPJviaxGwAAAAAAiKMRuwEoj5LMZLKP6WjR/HfsRgAAAAAA4iBTA1nxzz9UnWBGJondAAAAAABAPAQ1TlgJZzLZF/U0AAAAAOCEEdQ4Qf3G/FLSg8pb/HNXSewGAAAAAADioabGCbECoE+SLmO3pQDU0wAAAACAE0emxomwgMaLpPPYbSkIs54AAAAAwIn7v9gNgH81DGhI1NMAAAAAgJNHUOM03KpeAQ2JehoAAAAAcPKoqVFz/ca8I+ln7HYUbbRocuwCAAAAwIkjU6P+vsVugAdJ7AYAAAAAAOIjqFF/vdgN8IB6GgAAAAAAghonoG61NCQyNQAAAAAAIqhRa/3GvBe7DT6MFs0kdhsAAAAAAPER1Ki3XuwGeDCJ3QAAAAAAQDl8it0AePUldgM8SGI3AADqoqVuT+EC4OlM42GgdQEAgBNBUKPeerEb4AFFQgGgOD1Jt4HWlUgaBloXAAA4EQw/qam61tMQmRoAAAAAAENQo756sRvgwWS0aE5jNwIAAAAAUA4ENerrt9gN8CCJ3QAAAAAAQHkQ1KivXuwGePBP7AYAAAAAAMqDoEYN9Rvzc0nt2O3wIIndAAAAAABAeRDUqKde7AZ4kI4WzTR2IwAAAAAA5UFQo56+xG6AB0nsBgAAAAAAyoWgRj31YjfAg79jNwAAAAAAUC4ENWqGehoAAAAAgFNBUKN+zmM3wAPqaQAAAAAAPiCoUT91rKcxid0AAAAAAED5ENSon17sBnhAPQ0AAAAAwAcENWqk35h3JHUiN8OH59gNAAAAAACUz6fYDVil35i35WpD9HK/nkiaUFtho2+xG+DBI/scAAAAALBKqYIa/ca8J9cxv9zwnGdJN3R037NZT65jt6NgqaT72I0AAAAAAJRTKYaf9Bvzdr8x/yHpRRsCGuZS0s9+Y/5kwy1OnmW2PMVuR8Gmkr6OFs1p7IYAAAAAAMopelDDMgx+answY9lALrjxYJ36k2Tv/UX1msp1IulitGgy6wkAAAAAYK2oQQ0LaLxIOiYocS0X3Lg7teCGDdd5VX0CGlO54SYENAAAAAAAW0ULalgA4oeOC2hk2pJuZcGNApZXav3GvNNvzJ/kAkKdyM0pQhbMOBstmncMOQEAAAAA7CJmodBrFd8hb0u67Tfmf0i6Hy2aw4KXH5VlZtzq/awwVZZK+i5pSCCjvFrqnktKZxqzjwAAAACUSsyghs/pRzuSnvqN+a3cTCnPHtflXb8xv5TbXr3ITSlKqhoGnaqopW5HbvjSuaQv9uvemufmf0zt30TSfyUlM40ZMrTB0rb+j9x5Kpu+epvE/v9bLrNpMtM4WftsAKViweFzuc/9b3Kf/Y6239xJ7d9U0j/2eML59ji2Pzo67Hyc5v79V+57cDLTOC26nQCA3TRirNRqabwGXGUi14lOAq7zaP3GfCCXmdGJ25LCJKrgftiVdVoHodY30/jukNfZxdwfcsV5OwU2aSq3j/+S9HzqmR12PFzKBYt6Kmao3bKJ3Db/Wy6wFGWb2zEVpaZRzOCO7eNOpNVPlvf3gfvhD4U7b00k3RS0rGmZO/a2L/Kffx8SvX32E0/rqIWWuj25/eBzf+S/AxOCHAAQTqygxrWkhwirTlTyTrXVGrmWu9DsxG1NYYaS/izzdi+CXTS9hFrfTOOdP78tdWMcV0NJf57SxbZ1cr+p+IDRrp4VIajUUvdSrkZSDPeHBviOYZ+pV8XZz5OZxp+Xf9lS90X1yejbJplpfBG7EXn2Ofhd7vMfOsg3lX3+ZxpXOju1KJH3h+SCeH/KnY/TCOsHgJMRK6jxpIB3tFcYygU30ohteKffmHfktsk3Rbrj6cFQJdvOPpUxqJELZsQ8rhK5jmcSaf3etdQdyG3jMs1ENFTAoFJL3Qe5Yy2Gz6Hv2kd8v1NJF6veL0GN8HIZemW6ETGV+/x/P7XOtGXIZIHlMl1LPcvtjyR2QwCgjmIFNX6qHF/+Q0XudFsw41ZxgzxFmsoV/3w8teKfZQtqtNS9lju2ynJh9yzppi4X2SUJGO1iIncxPfS5EtseL4oT2AnawQ39WV9yM9P4cdUfCGqEY8GMKnx3D3UCGXMlDSyvkqjmQX4AiCF4UMOGV/wv9Ho3iNIJt5lMsrsJdZDqxGcyKUtQwy62n1TOzs1U7oJuZaesCioUzFiWSrryeTFtd0lD1kvKW9vZL1LkYScbO/IENfyrUDBjWa2CyhkLZlSx9lgighsAUJj/i7DOXoR1btKW+0L82W/M7yzo4k2/Mb/sN+Yvcp3fOgQ0UklXo0XzbLRonlx2RtnYGOJXle9zlmlLemip+8M6h5WS275lyoDZVUfSS0vdF+uYFc6GRNz7WPYObn29r+X1KE4Hairpa4T1Qi6Y1VL3TtJPVS+gIbnrjZ8tdR+qeO5d1lK311L3p1wAvxO5OYfoyZ2Pn+qwPwAgthhBjbKmBmbBjVebdaRQ/cZ8YMNufqi8Hc59TCRdWDBjGLsx+HXH6oeq0dm+lLugq0Jb1VK3Y3fBf6iaF9B5PbnOzZ2PhVvRzsTHsrdoy3VwvLFsrFh1Q65OfUahWGy/Z8HMqruW9GoB2sqx4NIPuRtDncjNKcJA7nxcyf0BAGURI6jxJcI699GR9NRvzH8WEdywzIwq301Y5Wa0aH6u+2wmVWL1M7x26Dw4l7uYK2ugU1Ilsl8OddtS99VTdsOVXGZBaD37LPgSY9YuSXpkRos4rCBsXTrQmY6kH1XL2rBz8U/VI8s1ry3bH7EbAgBVxfCT9TpywY1Xq3+xN5vlpQ53djNTueyMytZDqCPL0KjqxVBbJc7YaKmbfYZL2b4CnMvDXVsbt39T5DL34GUYimW2xAjApYo3pOdkWXbWq+Jl5oRwLXf+7cRuyCa57Iw6n4sl6doCzXV+jwDgRdCgRr8xL/Ud2TXOJb30G/OXfYIbJZi21ocrsjPKxQIaVcvQWFa6wIZdRL+qfp/hVbK7hIV23my2lRjZBW0VHOSzbKJYQw++MuwkrNxwkypes+wrC2yW8r1au+pSg2wXlchgBICyCZ2p0Qu8viL15IIbP2wa1rX6jfmd6tcZehwtmqQ/l4hd9FQ1Q2PZuUoSnMnN4HFqF5UPlplSpCu5TIPQLgvOPol1bN5b8VUEYoHiF9U7I2BZWy6wMYjdkDz7DMeaJjqmLNB/au8bAA4WOqjxW+D1+XApV0x05ZeNBTzqUEwsbyrSn8voSfW68L70XA9hq9xdwU7MdkQ0KDKwYRkGV0Utb0+FzCoQcdhJYkVXEUhNMt+O8VSWwEbFCl/7QGADAPZApsZhNlXZr1tAQ5Kemaq1lOp4sfMQa3x3LqBxqhfRmaIDG4mkGHV4jp4NxY7FGOf0mMGgk0RA45fogQ32xS8ENgBgR8GCGv3GvK163f087zfmq9Kb6zju8+/YDcBJCX4xS0Djg0GRlfhnGt/ITQMd2rHDUGJ1rG6s2CoCoBP9wVOsjjT74gMCGwCwg5CZGr2A6wrl3ZeMDUmpY6coid0AnJRe0bNxbGJDFE45zXmd64Lv2Maa5vWgYSg2FKpXfHO2erYiqwjAioLSif4oeEeagMZapSumDQBlEzKocQpR5l7sBngwHS2aaexG4OSELIB6yjU0tnkoqmNjBS9j1ObZezYUhp2cBju2f8RuR0m1VVBdml3UrPC1D2257yoAwAohgxpfAq4rljoUQl2WxG4ATlInxLhuG2JxCgHXQ2XTvRbSsZlp/Kg455SB3ZHfVawivEzfGogd03Urtly0IFMZ275g+N9250UOCwSAOmH4yXHSpZ97EdrgG/U0EMs3nwu3IS5RZ1upiI6K7dh8VYmHoUQcdvJoRVURBgHN3VwHGA7I8L/dhdgfAFA5QYIa66Y/rYEke2BTuXZiNcSjJHYDcLLOfY3pzt2lxW6u98x0WCviNK8dbQnORBx2MrFiqgjAOoWD2O2okAdfw1BsyuSej2XXWLBhQQBQFaEyNXqB1hPScq2JXqR2+DQdLZoxZiwAMr6yNUg731+R07w+SxoWtbw9bAvOPCjOcUEdjUAIaB6kIw/BPgtaxwgiVh3HMAAsCRXUOIVaE3WsGZLEbgBOXuFpttapJX13fx0bmlGUG30cwhfCyrucdvc+xnFxY0VUEcatCGge4toymYpEx/xwl0VlzwFAHYQKatRx+Mk/Sz/3YjTCs+X3CITW9jB+uIwX0hO5IOLyv7J1dm8LLBo6lauvEVpHS7VUIt69T6x4KgKwTnkZ6+gka/6lUVqzXmFZFVYIuo7XhqFMRXAOAH755HsF/ca8rXp+cSXZA3uPnWgt8SeJ3QBALgvquYgF2YV0p4hlHelZrghvsstdekvTPpf0u+JmmbTlOoV3RSxspvGkpe69wqeg37bUfc5t+xjDkXzUFrnR/u/jD4WrLzGRa2MRDik2W4aA5lTvP//pthfYHfme3Oc/5vXUoKXu/S5t3sSCiMzicbhnSVfMlAQAbxq+V9BvzHuq4dzao0Xz17brN+aXquFc9/n3iO3swrOsx/pE0l/2/1SuMOHULi6zi+SeXAChF6OBG6Qzjc+KWFBL3Z+KF9RIJX2XNDzmYtT22aVcIKBTSMv2M51p/O8iF9hS91XhO2uTmcafLRMoxvn7q9UWicoKNYYKKiUzjS8CreudEpyfE0nfj93nlm3yTS4QFeNO/XCm8VHBuMDH3L4SuXP1f1f87V9y56lzxdn2U7lgRvTzBgCUjfdMDZWvg1SE5Tur1NNAGU3lijF+X3dnzTrXif2YSL86zQO5C+eO1xbuptNSt33sXamIWRpTSfdFDTOw7TCUNLT3FLq4Zbul7mCm8bDAZX6V9Kqw7+O8pe6D4syCMaRjEtwfkdY7kaubkhSxMDuX3+QynEIPpzkqW8O+X7xO172n7Hz61z77yLLnegr3PUl2BgBsEKKmxil0+HsR2uDb37EbgKM8SzqbaXyz78XnTOPpTONHy46499K6/fUKWEaMO4PZfvBSN8ECC2cqaHjOHgrtlNgxGuNYu1b4O66pihuCgR1YdsMgwqrvZxp/LiqgkWfn6RtJnxW+9s7gyNeWoRZEKhck+Ld9Tyb7vHim8ST3PXkhfzeCUrmsrq8ENABgvRBBjTrW0/hVQPMUaoagcq6KugCaaXwnd9Ec+2LqqOCopZ53CmnJ7m5CXIha5+arwnaUz4ueCcECP6eQvcDd1vBCZwZMJX2286dXVhfmQmE/O8dkvcTO0pjKnZvPiso2m2mcDau6ULHFXR/ljqNTOC8CwFG8BjX6jXmscYe+JbnHvUht8Gq0aCax24CDXBU8LCC7aD5T3Jk4jg0chk49vwo9q4Wtr+jCk5v46JxcKX4Azad7H3ftsdUg4Lqmki5CTtObC2wOA62yY8Mv9mL1azrFN2dnE7kgga/MuUTuJsCxy0/ljqEbAqAAsBvfmRp1zGCYjhbNNPdzHd9jErsBOEjhAY2MXVjF7HAeHBzNFdYMxdt+2MbWGyqwUfg2jTjNawiTEHfu8Z51pEPdXAke0MizAp6h7uofEij+vfBW7G5oQ4FSnyvJDQv6qsO+L7PsjKTQhgFAzfkOapxCPY06vseYd+RxmKHvjrRdqIfMBMg7JngYslNzHyugkbH1h2hDp+ghKNKvu51Bs1wCqHOwpuxCdqSjBTRyrlTsEIh19gpq5gpQx3D0jC37siEjF9o9sJGK7AwAOBiZGvv7Z+nnXoxGeEaR0GqZKlA9BbtQizK+94gOdKjAY1KiO/E3KmHHZg/3qldw9eDZInC0UFla9yUIaOSz6nzbN6jZ89SObYIHNDK5eifbghT3VuMj8d8qAKgnb0GNUyig2W/Me/Ga4VUSuwHYS+g7O7Fmbugc+LpQnZpYWSwf2PEQYjYRLwGjgB2zEJ5D11eBYwWCQ2RppSUKaGbZTsMAq+rt8dwYQ08msQIamS2BjazGx13QRgFADfnM1KhjQGO5gGZd3yOpj9UxDT3cwe44B13noayYXYhOzbBsd+LtuEg9r6bna8HWGaj61Kd1Cs5UUS/Qesq4j8sW1Oz5asQapRnyZeey5bZk0/1Gz+4BitJS97ylbs/H0FRgG59BjZ7HZcey/OVTx5ld1G/MO7HbgJ0NI633e4R1dg54Ta/gNqwTogNxCN/tavu8eLEMh8TX8gNg+ta4Qgw9S8o4bMCCrL6HCu50Y8fOER2vLfmoVEO+7Bi5kTufkZ2B2rHMuFdJL5JerI4OCtJSt2MBo1IGjax9dy11B7Ha4DOoUccCmsnSz3WNsA9iNwA7+zPGSu3uUhp4tZ0DXhPiPFS6LI2cEPVPfGesVXWa10erQYN4egHWEeUcvKO/PC9/189+z2cjVkjLOORrpvHjTOMyFJMFCmUBjB/241Tueu3H2hfgEANZwEgl66dZVvRPSbeSnlrqvliQ47ql7qKl7kuIdjD8ZD/LRUITVfNie5tvVhMF5ZZGvjiqQoctxHnId8fhYJYlkHhejddtbAGjMqb3bzJRebN3ToJdZPkWfPjfnryfo+3u7Da/+W7HEj57eMc6WS+hOlcn6Idc9noi6bNc36jXUvcuYpsQzjf7fyKXQd6TC3I82O+DXCd7CWr0G/NQ49hDS/M/WO2JOn55tiW9MAyl9JLI66/CLDkdz8ufVuBuvO/99B/Py486686BGHYSXyfAOkp9TNox6Dvwvcu1XsibXGUPNCGOXu4fCmRZGm1ZHRu7EZHVkPF+fYBS+FuuP/zVijNf6O275zFU5twnT8utY0BDcifDJP+L0aL52G/M/yPpOkaDPDqX9NpvzL+PFs272I3BSv+NvP5Sp9DueAfxWO2WuosA6ymzTqD1XMmdl0Kt71ClmNoTQTrSg5jjh0viXNuDOyGDGsOA6wJO3kzjaUvdC0mdLJg/0zhpqXtRxnpDKN5yINn2++fQ7fAV1Kir3yXdLf9ytGje9Bvzv+TGEvUCt8mntqTbfmP+h6T70aI5jNwevJfEXPlM47SlbswmbFPX4GrZBOmw2IXTldx40rJKKABYGqGHPJyqf+3wnJDn4tIOB8QbGx7Wkzs2UrlzZ7rmuR29BbPT7HktdS/19v2zsmDvqpsbud9NswD00kxpE/u+actNCd/ZsPy2vY+N7Vhn3Xvb8Pys7VrTno61J1vmxNq0U+bgivez0+tte6ml7rVy+3SXdW5pz87HyZ7LvLQf3y1z1XGwZztly9t6Y+PYfbW0nGwZa4+hXd/b0jaXdjymlz4v715nf8uOqem67bPi+Eu1xz73FdTYaeUVdN5vzAerOvc21WvSb8wHcsGNTsiGedaR9JQLbiRRW4NMGdLbE5U3kFfHuj5lFKzDYnd/7uXOsWXD9K3lQlAzjI3n2UAZc79wZ7jcLBDxoBXXyC11E0k3Kzo8A72d8+9b6k4kPen9Z/y2pW4ql/6ef/2qIHj2u0QuTV7Wpp49vmipO7Xn5deR5NrattcMlpZ9a6/9vkeAO2tPKuls3ZMsK+zJfhwuted86T0sv3Yot23XdWTXvZ+trz9wn24UYZlDudmJ3h0H2hKYse3+pKXzoB2jV6vaeOy+WmGg3OdDK26+m43vbcP2yT5b96uG9m35LKRy2zX7PEnvP3fblpH9PdEO+9xLTY3Ropkq/nh/X54scLHSaNEcjhbNM7kDqwydziL15Gpt/KDeRnykuOMU2YViGY/9mxLPgnOKCGqcniR2A7Ce3cX/ofU3/XqSXrcM6fqit6KUyzpyU4muW/6u2voY0PjFOmCvWj8DRVuuQ/e6bVpT+85I7MfOliDgH7nHv2Zdsu31os03mAZy2/ZDENJ+t+n9ZK//ME1rQft0uT0+ljnYssyB9swCzc34ks8qyK5NziX9WLG9svX0Nix6oDX7ypeWug/avH06crOaPOV/ae9v02wsHVvu7xvWvcvx15M7/jY9x+vsJ1Wdhm8XT/3GfGMhTatDcSYpSHGUwC4l/ew35g/MkoISI/08kJBfvqZs3y/PFCcsHTK1yiHkNUIVilefpNxdYMmdu+8lnc00bshdK+eL7j9sCEz0cq+/sH/56+y23mfyZc/Rit/drFnHH3orfPlo60pyf39RLsVeLjukYe/lq953bHfJKsxPC/3HqifkhipIbohBYr/P7vpnn7NU7n3lt032XdmR65j++kzmOubZ+8nec34bpbn38yP32qL2af59+lhmT28ZLrL3kxWzvNDbTej8EJJd5IdaPM80Pptp/FlvGZsdvQ1zOXpf+WKBguvcrxK93z7D3N8GFnTK5IM6sudmr/uqt89N/jX5dbfl9k3HfrXp+GvL7fO13+3eamqMFs2035hfaHPkp8p6ch37odyQjHT5CTY7yk2/Mf8ut9N6AdsXwrWkAcVEUVIE3MIJuq1nGk9sGMrD1if7l4phJzhd24JHIYNLZQp04r38ufoin2lq2Qp3lqqeDSu51frz6sVSpmrSUve/uXUMstfmOv+/nrzDEKVLuc7ZhyEA1gHMjunnmcZf83+fafxsqfIv9rzrlrrfN2XxzTQettTNhq0PWuquGnrwLff4Xcdeb9+/z/o481bSUve73gIx53LX7nf292vl6jHIbdt06fVDvWWuLK87c+w+DbXMoc3OkZe01H2UyxbobFlWXv65/+TaObQhSMv1MY7dV4XLDfvIrNs+f1q7nmVBDgtA9ew5U338XErSswVB1l2rXet9psu64+9J7nOZtXc5UCnJb6aGRovmxIZiZONp6mggF9x4Wpe1MFo009GimUWdypg2fYy2XDHRn5uG5QBAkWyKsCR2O8T0rThtZQoe1+36qhbszmrHfhyuGzpr2W7Z3y5XPUcukPDh9fZ98Os8fGQtl1Traxrk0+hXZnrY6/Kd/3XvJS+frTFY8ffsd1PZbENL2RtTrfkusk5ivqP6x5rHV6uCL7bMC0mflzJEOvaUY/epPC6zo1yBSm3eZ/venHjOPf6WzyCYafyc3xcF7SsfskCB5IIwK7eB7fezmcZfc+3Ofxa+b9hfm67Vdj3+8tm5vXUZOkFmP7FpT4dyEZlvKteXYFEGki4tK+PRsjTesQKbnykmCgCF+CrpfxHXP6QwIQBslO94/rMl4DCR64S2W+qer+go/bPiNfnXblr2rv7cEKjO3stErgZGZ83z8q//ou1D0Yd6G6ryLf98yw75dYc/17Ze7vXPG9qcFdlO5a7V8+3O/k83fZetWHaR+9TnMvPL2GcbbWUZo896Cwy82s/fV2zLQ9vRaanb8Viv60vu8Z9rn6VfAZe8Xu7xcMt6/lx6/qpZW5IN657ath3k1v1hncGmdLVO/l2/MX+UC26UsXr9sbJUqG9bghvDfmP+rHoGeXqSevb+blYNywGAglxHXv9lS917CoQCwE72GTIY69o42eE559q9sOTW9zHTOLU0+4GsYGiuk5e/m53PAOnkHv93h3akudd0VvztUD72aVHL7OQe77uNtppp/NWKbGbXIpdy1wWp3s/Ec0w7OvI3q2gn93jfdfx67Q7XQKv+vu+689uts+oJXoefrDJaNKe5IprD0OsPJAtuvK4bknEC2+FSblhO7E4HgBqyuzixg+Nt5QqnAQBwoA8FQ21IQ89+lxBAL5+Zxjd6K2Ka3cjuKPAMJgeq1dDZYJkay+wO/lW/Mc+Kve0y5qxqOnJDMm7lhmQMl59gmRxXuWKiZf8A7Ouh35hrtGhuS70DgJ3kKraXwXlL3Qe7sAEAvJfvOF1VfKaoqVwwO51pfFbkgpeGHQysGHa+QOj3pZckegvs/64NBSXtO7OXX5f9PvtVr6Vue4/6UD72qY9lJjpwG+0jV8T0Ua5PO7A/3eptFpCj9tWO/rXhb6syWv7RW//7d+1XpyyRtbOl7uVM4+cNz/0wpasd79mPuxx/+WWsbGfwTI1lVkTzq1wRmiRyc3zp6G0a2N6qJ4wWzYncNqhV1Mw8bJr+FgD29EPlGrZ3bZXAgVNTpmuWMp0T8OZdQcVorShG9l46ns75+eEl3/TW4UyXO43W2c0+f+db2pPPanxe83ht5mNL3eWpPH3s08KXuRQQON9Sp2PvzM+Wupf5Zc40ni4V27zMtePYfbVOury+Fe3saPVN8/zyB5umyG2puzyFbn4K7bX7y14zWPPnXY+/S+UKvq4L9EQPamRGi2aSmyEkidwcX3qSXtYFN7IpYEM3KhAu+IH6Ctaxaal7p3JOj/206YIAqKl1BfoyIYMedct0rQW7iz20H89b6j7Z3eh3Wuq27W9e9+OR5+l80OFpXSe5pW6vpe7TAct/1ttn5lpvgbp1RRzz2RtPS4GHbJvmaz4svyb/+EFIGycAABd0SURBVNo6ru/2jS3zSdJDS90fkp996vE4ye+zH1Z4dXl5y9toq5a6P+VusLxr51K78ue/Y/fVOknucWf5uLPjfWVmq9X8yF7flvSyfEy31O3Yfr+W9DO3/R71fkaSH8ufLVtWNh3wKvscfx9eY5+z6+w10YafrGOzZiQ1nSEk05MrpnlvdTV+sSKih5wIy447KAitTHcQa21D5fFClaSOxjptuS/elfOnAycqyLnB/CfgurCfG7mg07lstkCbzSAr/veb3LVxW66D9LngqbJTvfUnXlvqTuSyH/aaxtMKel7JneuzTuBE0l/2lH/JvY9zSWqp+49Nabnr8pdnecisXMZM47uWul/0tu0eWure6u1z11t6yX3+LrcNAcgmcJD9f91SN3vOud5fv/+Ve+xjn/pY5qPc0IXsvTzZNkpXvMdUu/c7/9RbP/W1pW4WeMoXdv2ViXDsvlpnqcis5DIuLlcsNxs6texK0qv9raO3Y/pXwCL33KksCGLH6o3eAg6Xcvsra3Nbb4HmVCu2qx1/93q7rtt2/CUzje+kdwETye3fi9JkaiwbLZrD0aJ5pvdz09bN7ZpCmknohgA1tGnqN1RMyeporNOzTBLEF7IzjXIgU6OkrOP5VW+fy7ZcJ+zW/l3a71K5WSOKvu7PZzq05TpqnUMWZLUe8lnV53p7H9d6Ow4f9wlo5Nwv/Tzcsj2+6v2EA9n76y097ybrEOZZPajlLPHs9fkO5bs6Fz72qcdlXuj9d0JnxXu80n4zgDzmltnJtbFjv5vo43Y9al9tcKP37295uUOt+U60DJkLvX/v5yvalUq6yBerteNhOTCYvS77HKzaDvn13634e7aM/PE3lNt++Ta+e1zaoEbGimueqb4XKKvuOpLVAKAqQgWdy1ZHY53bLeN2EUZdb4aUTXrk34t0vipdHeUw0zidafxZrhP0rPef0USuY/N5ReZfan9PtPl4muSe9+7zbx2n+9zrp3pfE2Dta1exYMWZ3ndss7YO5Tp/Bw0nzw3DyNqzcQhCro7Dhb0uzf15Ym082xRg2fB+8q8frmrrgft00/vxsczp0jIzqdw2y97fzsdBbpn3+rjN7uWOgeXj8Jh9lWrN5yAXuLlf+tuzXPDnatN7m2k8scK3V/p4Yz215a7c5rbdsmMnv+5ELhD2eantq5axy+fpaml7DnPPvZGkxvKCy8oKTWbpMXVzYcNu1G/M25L+F7U1fvx6j3W1lArl3Uzj6J/flrovClff4H6fyLWl35X9zn4dJDONvQ65sDGV+8xbH9tU7sKk9B1ryywJNaTH+7GSsXHFgxDrOnFbz8stdReB2iJVf3YNAIjK6oV05DJGDsk2iqL0mRoZmwJ2GLkZvvRyj2uZPln3gAZKKY3dABzPim5VKaAhueA7AbW4/rv9KSjALoG7kJm2H6YOBADsxm4IduzHX8Vhq6AyQQ3z1/anVFL+oqAXqxEeJbEbgNMTqngl/HVYKlJHYx3qa8TF5z+MXbZz6rsROZfMQgQAh7Gpg8/k6ldM5c6pg6iN2lHpZj85UfmLgi/RWuEPF5eIZSL/2U9DrZ9u7RSkHpf9pGrPgHXbUjfZpYI5Chfqe2ff4nJ1s8t2/kdhp3X/pg2F6QAA61ldl9RmZzlXRUo/VC2oUYmNuq+loRm9OK3w6u/tTwG8CBHU6O07LRy2szoaITtCvvxoqVuJ+hp1YtPcTeX/uuE3ajhslSjsVMyDlrrf81X6yyArYsq5AEBZWabbQG763HO56+hhvBbtrmrDT+pYb+LXXY5+Y96L2A6fktgNwMkKEVDrVCU1ryoqWkdjnbbe5nFHWEmAdQyYcWOzCJlKbZXz/PEg6acFbAGgrLJRAzdaMYtLWVUtqFHHoRlJ7nEvUht8mowWzUp8GFBLSaD1hLwLWWsVr6OxziUdmShCBDXb4vO/i9DDUC+t4F0p2Od/IAu4tNR9ofYHgLKxKXUvZhp/nWn8WJWAhlS9oEYvdgM8+Cf3uO5BGyCobFxggFV1KApZmKrX0VjnwTJQTlkn8PqSQOu5Zt9uFaPQ+1MZAgeWybecOdKT9EqwEwCKUZmgRr8xr+sFQ5J7XMf3SD0NxPYcaD23dGyOU6M6Guv8OPGhCp2QnUybASkNtLqnE9+324Q6D+e1FfkzZwGNdcPPyNoAgIJUJqihemZpTEeLZir9CtrU8YIoid0AnLyQM5Oceqf1YBYQqnsaf0fU1wgdtArVma5THZjCBQ4w5Z1LeolxXt4S0MjrydXauPPZHgCosyoFNX6L3QAPktzjXqQ2+JRSTwOxBb6Y7ijSBfS+ynRn0LbXk+oZ2F126vU1vgVeX8ig5qClbiWCVpHOUbGmvs4CG8Ey6VrqPmj/AOZtS91XMv4AYH9VCmr0YjfAA+ppAGGEvJiOdmdwV3bB/bOlbi92W8yD4gy/SyOsUzrt+hodO/6CsKBmyCKVpQ5stNTttNR9UZxz1DDw+vKy87LXTKGWuuctdV8lHRq4PJertXFXXKsAoP4qEdToN+Zt1bNwXJJ73IvUBp+op4GyGAZeX3ZhWqqO64oL7h+x22gp2oMIq55KupD0GGHdUnmGKqUR1nkdOFvle8B1SS6wUZb9+4tt81e5643gwVcr3ByjtkYmq7FReA2LlrptC0S8qpgAbZa10StgWQBQe5UIaqieHX6NFs1Eop4G4JtdTA8Dr7ajktxxswvuJ3284G4rcFr2Urti1iG4sanLbhR+uknJHR9lqMGQRlrvg3X8O4e8eM9j9lkuiBXSpdznvxd4vR+01O1ZdsaD3l9rxMgqCx1gWqUnl6n2dOy5zzJf7iT9VPE1gbL981C2ABkAlE1VghqluttZkPxFdC9WIzxKsyKoQEnEGs9921I3ylCPpQvuwZqnRQlsRK6j8TzTeJj7+UrhO72Su6M/iLDesrjUW+dysC7AYUG5Xkvda3vuT7kA3U5mGk8VpzPdkftsHRy8OYZtsx+SXrT+OiNoYGOmcaLy3PAYyAWeflrgoLfLiyzj7dqy3rJghs/td62SBMgAoKw+xW7AjupYbyIf1Kh7EVQgupnGSUvdRHGCiB25jsNErnP1bB0tL2zc+O/afVhHFti4sBoEIcSso3GV/8VM40lL3XvFyZx4aKk7Cbjdl5WhmPPA/qmlrq91PMoVKY0RRLuUKxA7lPSndey9sODEpaQ/tPu5LgtsXPg8L+Xcq1w3czpygYNrO/5Src5gaiveTbaO3D56lHQfaD8BQGU0YjdgF/3GfBG7DR5cjRbNoST1G/Ofql/NkJvRohlrrHoUdhflJdT6ZhpH//xaSnMv0OruZxrfHbMAy0bY+Q6vR1O5lPi/JSU2POZgdhf4XC6QcanDO25TSd4DGxZ0+eFzHRtcrOtU2l3t0FOOSi7IHapD+UFL3Up+x+57DrSspTJMG5zKPv8zjY+uMWHntZ7cDaBjjt/nmcZfj23PLgJ/d9RNKunKZ3AMAKomeqdoG6s3UYZOSNE+jxbNSb8x78ilL9bN59GiGevOYxQENbw7OqghSVZbYnB0a4qV2r+/5QIL2z47Pfv/i1xAtFNwWz776mBbAOZVce6YbzyG7C73T8Vp23Cm8dX2pxXPhnN0Yqz7GAcENdpyx17HS4MOl83Q8l+tzxLIZNkC/7L/i67JFeQ4LFGAucpuZhqf1M0jAFinCsNP6lhPY5rr8PdiNsST6akFNFApNzoum8GHjv3rRW2F05HfVPQfirPtJ9uCYjONpy11vypgcDJn0FL376VaH6FMVL6OfuFs/94oXpbQOllwogwGLXXlO7BhQ74edfjUp6cuy/YDAKgahULrXk+jE6sRHiWxGwCsYx31m9jtKDkvxQNb6saqozGVtFNavaV0x7r7+RBpJpp/IqwzChvuQWdws4FltPl2r3iz71Td92OHLQJAnVQhqFGWuxdF+jt2Azyr+/tDxdndcDo2mxUa2LA6GrHuyt7s0wGIOM1rNiNMaKf2WYg1202VeA9sWIA5ypCrikuKGIoJAHVS6qBGvzGPWWnapyT3uI7DNJLYDQB2QMdmu0ICG1ZHI0ZnXfo4feuuYh0f55bREowVhj2Zz4J1poMUxKy4ge9j0TKj7n2uo2YIBAHACqUOaqieAY3paNFMcj8nqtnFJPU0UAXWsbmI3Y4KKCKwEauORqoDOwDW0Y/V2bq2zJaQTipbg870zq5b6g58rsCyDhKf66iRK4adAMBHZQ9q/B67AR58z/8wWjTrNr4/id0AYFfWceWu13bnOnAqzIh1NCTXATg4aGwzC8Tq7D9ZhksofwZcVylYZ3oYuRlV8GSze/n0VfXMXC3SfRFTAANAHZU2qGFDTwax21GwyWjRvFv+5WjRHKo+qfDU00Cl2NAEpsXbbKoDOr3WEYpVR+Pe7sYfK9a5ua2As3TYtkpDra9EYtVPqZJsyllvckOC6nAd5MOQOhoAsF5pgxpydwXLNOXisTaO4bXAxmdV/65RErsBwL6sMOQwdjtK7KtltezMhqvEmjpz6/Stu4pcfyF0fY2TG46RG4ZGYGO1iSRf0zu/Y8MqLkRgY9nE9xS7AFB1pQxq9Bvzgeo1d/lE0sVo0Uw3PWm0aKajRfNKLriRBGhX4ZbqhQCVYReNw9jtKKGrAzMeYtXRKDwIEXma12D1NSxrKQ2xrjIhsLHWVEcO4dqXBU8JbLzJtgcAYIPSBTUsoBGrSr4Pj3IBjZ0vlkaL5mS0aF7IfZGlvhrmQRK7AcAxCGx8cHXIzCEtde8k9YpuzI72mr51VxGneZXC1teoU42nnRHY+CCVy9AIvj1ygY009LpLJliWDABUXamCGv3G/E71CWgMJZ2NFs0bKwa6t9GimYwWzTNVp94G9TRQeRbYOPVU36ncxfRw3xdaHY2DiooW4NDpW3dV+/oaVojwJIsR5gIbw8hNiW0i6XOMgEbG1v1ZpxtkehYBDQDYWSmCGv3GfNBvzH8q3oVwUaZyY5L/PVo0r7YNN9mV1ds4U/nHOyexGwAUwTrGp5oCncpdTCf7vjByHY1UnoNRkad5PbcMmBCudKJ3yWcaTy2wWfbvW19K05k+4SDTcKbx1zLsAwCoimhBjX5j3u435tcWzHiS1InVlgJkwYyz0aJ5d2hmxiajRXNqM6ecqbxf8Kd6RwU1ZJ36U7tT+Kzj7tDGqqMhBRr7H3ma19sAU2syE4V+Tfd6aoHN+7J1pnNBpqpkrB7riqKgALC/4EENC2bcSfop6UHVDmak8hzMWJYrJnqhcmVGTEK8fyCkmcbpTOPPqv9d26lcLYqDOzSR62gUNX3rrmJ2sH5YRoxXFGz8Fdg8U/2H46Rywcy7yO1Yy7LnKltEfQep3D4YRm4HAFRSsKDGUjCj6tO1ppKuRotmsGDGMqu3cSF3Ny0Nvf4VktgNAHyxi/26XlAnchfTB8/u0VL3XPGGDxY2feuuIk/zGrK+BoENlynwVeX5ri3avSLXz9iVBZkvVL+sjUdVZB8AQFl5D2r0G/NOvzF/Uv2CGcPIbZEkjRbNZysmeqO4X/IUCUWtzTSe5C6o08jNKUIq6etM44tjZguJXEcjWnAh8jSvvVD1NXKBjZPucFkB1Sxrqw4d6kTS2UzjuzINN9mFZTOcKd7nryjZ7CY3VdsHAFA23oIaS8GMgaodzEgkfS1TMGPZaNF8VNxiokmk9QJBzTQezjTOZiVKIzfnEKncuO0z66gdK2ZNJC/Tt+4q8jSvQeprSO8CG2XqRMaYanRqWUFZbasqdkQTuY70UcHM2Gxf3KjcdcbWSeXOwZ8DD5sDgNoqPKjRb8zPl4IZVZZIuhgtmhejRbP0Y2ojFhOlngZOzlJwowp3sSd6C2YMi1hgS91rSZdFLOsAvqdv3VXt62tI7zqRZRiGNZQLskSRK16Z3UiowvdfNqvJQTMblZUNSanKvkhV8DkYAOA0ilpQvzHvyQ0v6RW1zIgSSfejRTOJ24zjBNwnj6NF88bzOkrP7pq+hFrfTOPCPr+Haqn7onCf+fsyF7KzuhLf5Dr5ZclMm8p1Zr4XPV7b3u9rkcvcQyo3Br0UHRgL7jxEWn1iw6KCyh3vg4CrzY7lJOA6d9JSdyDpd8UL8q2SSvpTborQNG5Twinhvkgk/UkgAwD8ObpTVLNgxlAumJFGbkeh+o35pfzONHNWt212CIIa3pU6qJHXUvdS7qK6p/BDM1K5i+i/Chpe8oFlB7wq3rCT0t1tbqn7Q/E6UTfHFHo9hh0L+eO96IBeIukvucyctOBlFy7A9thmordOdBUyyLxZ2hehP5sTuYBSJY5bAKi6gztF/cZ8IOkP1SOYMZF0U/XMjG36jfm1ii/Wem9DXgCs0FK3I3ee/CLp3P4VaWL//pabCeSkOzKIyzI4ziX9Zv+3tdsxP5HLLJpI+q/csZx4amYwFuzu6W17dApeRaK3z39SluylMlraFz0Vey2UPw8nBDIAIKy9gxqWmfGg4i/MYxnKBTRO4kKg35i3JWXBjWNl08oC2IN1/Np6Cwr/R9s7O6lcZ09yHZkpAQygeqxznQ/2fNnhZRNJ/09vgZ+UjvNxLJMjCzR1JP1Luwfg/p/cOTmtQ/ANAKpur6BGvzG/UzGd4bJ4Hi2aUaYDjK3fmHfk9uXgwEU8y01vexLBIAAAAABA+ewc1LAZTQb+mhJcKunzqXfKD6iJMpUbclKmqf0AAAAAACdop6CG1WKIVdndl6vRojmM3Yiy2KGYaCpX9Orx1ANBAAAAAIBy2BrUsGEKryrPFIVFmI4WzX/HbkQZ9RvzrMhbx36VSpqMFk3G7gMAAAAASuXTDs/5pnoFNCRXZA8rWPCCAAYAAAAAoPT+b4fnhJ7bO4S/YzcAAAAAAAAcZ2NQw4aedIK0JCwyEQAAAAAAqLhtmRq7zNddOaNFM4ndBgAAAAAAcJxTDGoksRsAAAAAAACOty2o8SVIK8Ji6AkAAAAAADWwLajRC9GIwCgSCgAAAABADawNavQb8zoOPZHI1AAAAAAAoBY2ZWr0QjUioHS0aKaxGwEAAAAAAI63KajxW7BWhEOWBgAAAAAANXFqmRrU0wAAAAAAoCZWBjX6jXlbUidsU4IgUwMAAAAAgJpYl6nRC9mIUEaLZhK7DQAAAAAAoBjrghp1nPkkid0AAAAAAABQnHVBjS9BWxEGQ08AAAAAAKiRUxp+QpFQAAAAAABq5ENQo9+Y13HoiUSmBgAAAAAAtbIqU6MXuhEBpKNFM43dCAAAAAAAUJxVQY3fgrfCP7I0AAAAAAComVPJ1PgrdgMAAAAAAECxGvkf+o15W9L/IrXFl3S0aJ7FbgQAAAAAACjWcqZGL0YjPLuK3QAAAAAAAFC85aBG3WY+uRotmknsRgAAAAAAgOItBzW+RGlF8aZyAY1h7IYAAAAAAAA/6jj8JJF0QUADAAAAAIB6+5Q96DfmVR96kki6Z7gJAAAAAACn4VPucS9WI440lPQnwQwAAAAAAE5LPqjxW7RWHGYol5mRRm4HAAAAAACIoIqZGkMRzAAAAAAA4OQ1JKnfmLcl/S9yWzaZSvouaUgwAwAAAAAASG+ZGr2YjdggC2Y8jhbNaezGAAAAAACA8siCGmWb+YRgBgAAAAAA2CgLanyJ2oo3qVy9jGHkdgAAAAAAgJIry/CTVAQzAAAAAADAHj71G/OYQ08mkr4TzAAAAAAAAPv6pDhZGolcZkYSYd0AAAAAAKAGPkn6LeD6EhHMAAAAAAAABfikMDOfDCX9STADAAAAAAAUxXdQYyiXmZF6XAcAAAAAADhBn7Y/5SBDEcwAAAAAAAAefZI0ldQuYFlTSd8lDQlmAAAAAAAA3z5JepY0OGIZWTDjcbRoTotoFAAAAAAAwDaNfmPekfSq/bM1CGYAAAAAAIBoGpLUb8zPJb1ot8BGKlcvY+ivWQAAAAAAAJs1sgf9xrwt6VZuKMqq4MazpL8IZgAAAAAAgDJorPqlDUnp2I/T0aI5CdUgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4BT9f5V7pEN9I+XcAAAAAElFTkSuQmCC'

$html = @"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>Diagnóstico $env:COMPUTERNAME</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;background:#f5f6f8}
h1{margin:0 0 4px}h2{margin-top:32px;border-bottom:2px solid #ddd;padding-bottom:4px}
.sub{color:#666;margin-bottom:16px}.veredito{background:#fff;border-left:6px solid #333;padding:12px 16px;margin:16px 0;font-size:1.1em}
.cards{display:flex;gap:12px;flex-wrap:wrap}.card{background:#fff;padding:12px 20px;border-radius:6px;min-width:90px;text-align:center;box-shadow:0 1px 3px #0002}
.num{font-size:2em;font-weight:bold}table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px #0002}
th,td{padding:8px 10px;border-bottom:1px solid #eee;text-align:left;vertical-align:top}th{background:#fafafa;white-space:nowrap}
.tag{color:#fff;padding:2px 8px;border-radius:10px;font-size:.8em;font-weight:bold}.det{color:#555;font-size:.9em;margin-top:4px}
.ev{font-size:.85em;white-space:nowrap}a{color:#1565c0}
.topo{display:flex;align-items:center;gap:16px;border-bottom:3px solid #4b00ff;padding-bottom:12px;margin-bottom:18px}
.topo img{height:46px;display:block}.topo .rot{color:#555;font-size:.95em;margin-left:auto;text-align:right}
@media print{body{background:#fff}.card,table{box-shadow:none}}
</style></head><body>
<div class="topo"><img src="$logoNextec" alt="Nextec"><div class="rot">Diagnóstico de máquina Windows<br>v$($script:Versao)</div></div>
<h1>Diagnóstico: $env:COMPUTERNAME</h1>
<div class="sub">v$($script:Versao) | Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm') | Últimos $Dias dias | Admin: $script:IsAdmin | Usuário: $(ConvertTo-Html-Seguro $script:Alvo.Nome) | Modo completo: $([bool]$Completo) | Duração: $([int]$duracao.TotalMinutes) min</div>
<div class="cards">$($cards -join '')</div>
<div class="veredito">$(ConvertTo-Html-Seguro $veredito)</div>
$secComp
<h2>Achados</h2>
<table><tr><th>Severidade</th><th>Categoria</th><th>Achado</th><th>Evidência</th></tr>$($linhas -join "`n")</table>
$secLacunas
<h2>Sistema</h2><table>$sisHtml</table>
<h2>Etapas executadas</h2><table><tr><th>Status</th><th>Etapa</th><th>Tempo</th><th>Erro</th></tr>$($lEtapas -join "`n")</table>
<p class="sub">Todas as evidências brutas estão nas subpastas deste diretório. Os arquivos .evtx abrem no Visualizador de Eventos. Material confidencial.</p>
</body></html>
"@
$html | Out-File (Join-Path $script:Raiz 'RESUMO.html') -Encoding UTF8

# Compactar
$zip = "$script:Raiz.zip"
if (-not $SemZip) {
    try {
        Write-Log 'Compactando evidências...'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $zip) { Remove-Item $zip -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($script:Raiz, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    } catch { Write-Log "Falha ao compactar: $($_.Exception.Message)" 'ERRO'; $zip = $null }
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host "  CONCLUÍDO em $([int]$duracao.TotalMinutes) min $($duracao.Seconds) s" -ForegroundColor Cyan
Write-Host ("  Críticos: {0}  Altos: {1}  Médios: {2}  Baixos: {3}  Lacunas: {4}" -f $contagem.CRITICO, $contagem.ALTO, $contagem.MEDIO, $contagem.BAIXO, $lacunas.Count) -ForegroundColor Cyan
Write-Host "  Pasta : $script:Raiz" -ForegroundColor Cyan
Write-Host "  Abrir : $(Join-Path $script:Raiz 'RESUMO.html')" -ForegroundColor Cyan
if ($zip -and -not $SemZip) { Write-Host "  Zip   : $zip" -ForegroundColor Cyan }
Write-Host '=====================================================' -ForegroundColor Cyan
foreach ($a in $achados | Where-Object Ordem -le 1) {
    $cor = if ($a.Severidade -eq 'CRITICO') { 'Red' } else { 'Yellow' }
    Write-Host "  [$($script:Rotulo[$a.Severidade])] $($a.Titulo)" -ForegroundColor $cor
}
Write-Host ''
if ($Abrir) { try { Start-Process (Join-Path $script:Raiz 'RESUMO.html') } catch { } }
# Copia temporaria criada pelo .bat: remove ao terminar
if ($ApagarScriptAoFinal -and $PSCommandPath) { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }
