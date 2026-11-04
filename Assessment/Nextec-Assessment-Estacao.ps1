#Requires -Version 5.1
<#
.SYNOPSIS
    Coleta local e silenciosa de uma estação (ou servidor) para o Assessment Nextec.

.DESCRIPTION
    Roda na própria máquina, como SYSTEM, por tarefa agendada criada por GPO (veja Instalar-Assessment-Estacao.ps1).
    É somente leitura: não altera nada na máquina. Grava um arquivo <NOME-DA-MAQUINA>.json na pasta
    compartilhada do servidor e uma cópia local em C:\ProgramData\Nextec\Assessment\Estacao.
    O Nextec-Assessment-v2.ps1 lê esses arquivos no lugar de consultar as estações pela rede,
    então firewall e permissão remota deixam de ser problema.

    Sem janela, sem pergunta, sem saída no console. Código de saída: 0 = gravou no compartilhamento,
    1 = coletou mas não alcançou o compartilhamento (a cópia local fica e a próxima execução tenta de novo).

.PARAMETER Destino
    Pasta compartilhada de destino, por exemplo \\SERVIDOR01\Assessment$\Estacoes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destino,
    [string]$PastaLocal
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$versaoColetor = '2.0'
# Consulta WMI/CIM travada não pode segurar a coleta da estação.
$PSDefaultParameterValues['Get-CimInstance:OperationTimeoutSec'] = 60

$pastaLocal = if ($PastaLocal) { $PastaLocal } else { Join-Path $env:ProgramData 'Nextec\Assessment\Estacao' }
try { New-Item -ItemType Directory -Path $pastaLocal -Force | Out-Null }
catch {
    # Sem permissão na pasta padrão (execução fora do SYSTEM): usa a pasta temporária do usuário.
    $pastaLocal = Join-Path $env:TEMP 'Nextec-Assessment-Estacao'
    New-Item -ItemType Directory -Path $pastaLocal -Force | Out-Null
}
$logLocal = Join-Path $pastaLocal 'coleta-estacao.log'

function Write-LogEstacao {
    param([string]$Mensagem)
    try {
        if ((Test-Path $logLocal) -and (Get-Item $logLocal).Length -gt 512KB) { Move-Item $logLocal "$logLocal.antigo" -Force }
        Add-Content -Path $logLocal -Value ("{0} {1}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Mensagem) -Encoding UTF8
    } catch { }
}

function Format-DataEstacao {
    param($Data)
    if ($null -eq $Data -or $Data -eq [datetime]::MinValue) { return '' }
    ([datetime]$Data).ToString('dd/MM/yyyy HH:mm')
}

function Invoke-Seguro {
    # Cada item é independente: se um falha, os demais continuam e o campo sai com o valor padrão.
    param([scriptblock]$Bloco, $Padrao = $null)
    try { & $Bloco } catch { Write-LogEstacao "Item ignorado: $($_.Exception.Message)"; $Padrao }
}

function Invoke-ComLimite {
    # Consulta que pode travar (licença, disco, eventos) roda à parte; sem resposta no prazo, a coleta segue sem o dado.
    # O bloco não enxerga variáveis nem funções do script: valores entram por -Argumentos.
    param([scriptblock]$Bloco, [string]$Descricao = 'Consulta', [int]$TimeoutSeg = 60, $Padrao = $null, [object[]]$Argumentos = @())
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Bloco.ToString())
    foreach ($a in $Argumentos) { [void]$ps.AddArgument($a) }
    $assinc = $ps.BeginInvoke()
    if ($assinc.AsyncWaitHandle.WaitOne($TimeoutSeg * 1000)) {
        try { $ps.EndInvoke($assinc) }
        catch { Write-LogEstacao "$Descricao ignorada: $($_.Exception.Message)"; $Padrao }
        finally { $ps.Dispose() }
    } else {
        [void]$ps.BeginStop($null, $null)
        Write-LogEstacao "$Descricao sem resposta em $TimeoutSeg s: a coleta seguiu sem esse dado."
        $Padrao
    }
}

function Get-ExecutavelDoComando {
    # Só o executável: argumento de linha de comando pode carregar senha e não precisa sair da máquina.
    param([string]$Comando)
    $c = "$Comando".Trim()
    if ($c -match '^"([^"]+)"') { return $Matches[1] }
    if ($c -match '^(.+?\.(exe|com|cmd|bat|ps1|vbs|js|msi|dll|sys))(\s|,|$)') { return $Matches[1] }
    ($c -split '\s')[0]
}

function Test-CaminhoDoWindows {
    # O que vem do próprio Windows ou da Microsoft é padrão; o resto é o que interessa revisar.
    param([string]$Caminho)
    ($Caminho -match '(?i)^(\\\?\?\\)?(\\SystemRoot|%SystemRoot%|%windir%|[a-z]:\\windows)\\') -or
    ($Caminho -match '(?i)\\(Windows Defender|Windows Media Player|Windows Mail|Common Files\\Microsoft Shared|Microsoft Office|Microsoft OneDrive|Microsoft\\OneDrive|Microsoft\\Teams|Microsoft\\Edge|Microsoft Update Health Tools|WindowsApps)\\')
}

function Get-PerfisUsuario {
    # Como SYSTEM, só a hive de quem está logado aparece em HKEY_USERS. NTUSER.DAT de ninguém é carregado.
    foreach ($k in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue) {
        if ($k.PSChildName -notmatch '^S-1-(5-21|12-1)-') { continue }
        $pasta = "$($k.GetValue('ProfileImagePath'))"
        if (-not $pasta -or -not (Test-Path -LiteralPath $pasta)) { continue }
        $raiz = "Registry::HKEY_USERS\$($k.PSChildName)"
        [pscustomobject]@{ Usuario = (Split-Path $pasta -Leaf); Pasta = $pasta; Raiz = $raiz; Carregado = [bool](Test-Path -LiteralPath $raiz) }
    }
}

function ConvertTo-CanalLicenca {
    param([string]$Canal)
    if ($Canal -match '(?i)^OEM') { return 'OEM' }
    if ($Canal -match '(?i)GVLK') { return 'Volume (KMS)' }
    if ($Canal -match '(?i)MAK') { return 'Volume (MAK)' }
    if ($Canal -match '(?i)Retail') { return 'Varejo' }
    "$Canal"
}

function ConvertTo-StatusLicenca {
    param($Status)
    $mapa = @{ 0 = 'Não licenciado'; 1 = 'Licenciado'; 2 = 'Em carência'; 3 = 'Em carência'; 4 = 'Em carência (não original)'; 5 = 'Notificação'; 6 = 'Em carência' }
    if ($null -ne $Status -and $mapa.ContainsKey([int]$Status)) { return $mapa[[int]$Status] }
    'Não identificado'
}

function Get-AtivacaoLicenca {
    # Da chave, só os 5 últimos caracteres que o Windows já expõe. A chave completa não é lida.
    param([string]$IdAplicacao, [string]$Descricao)
    $itens = @(Invoke-ComLimite {
        param($Id)
        Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$Id' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Select-Object Name, LicenseStatus, ProductKeyChannel, PartialProductKey
    } $Descricao 60 @() @($IdAplicacao))
    $itens | Sort-Object @{ e = { [int]$_.LicenseStatus -eq 1 } } -Descending | Select-Object -First 1
}

function Get-SituacaoOffice {
    # Tipo de licença e estado são coisas distintas: a edição diz que é assinatura, não que está ativa. Sem consulta de licença, o estado fica em aberto.
    param($Licenca, [string]$Edicao)
    [pscustomobject]@{
        Licenca  = if ($Edicao -match '(?i)O365|Microsoft365') { 'Assinatura Microsoft 365' } elseif ($Licenca) { ConvertTo-CanalLicenca $Licenca.ProductKeyChannel } else { '' }
        Ativacao = if ($Licenca) { "$(ConvertTo-StatusLicenca $Licenca.LicenseStatus) ($(ConvertTo-CanalLicenca $Licenca.ProductKeyChannel))" } else { 'Não identificada' }
    }
}

function Get-OfficeEstacao {
    param($Softwares, $Perfis)
    $canais = @{
        '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Atual'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Atual (prévia)'
        '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Empresarial mensal'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Empresarial semestral'
        'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Empresarial semestral (prévia)'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
        'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'Volume 2019'; '5030841d-c919-4594-8d2d-84ae4f96e58e' = 'Volume 2021'; '7983bac0-e531-40cf-be00-fd24fe66619c' = 'Volume 2024'
    }
    $edicao = ''; $versao = ''; $canal = ''
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r -and $c2r.ProductReleaseIds) {
        $edicao = "$($c2r.ProductReleaseIds)"
        $versao = "$($c2r.VersionToReport)"
        $origem = "$($c2r.UpdateChannel) $($c2r.CDNBaseUrl)"
        if ($origem -match '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') {
            $id = $Matches[0].ToLower()
            $canal = if ($canais.ContainsKey($id)) { $canais[$id] } else { $id }
        }
    } else {
        $msi = @($Softwares | Where-Object { $_.Nome -match '(?i)^Microsoft (Office|365)\b' -and $_.Nome -notmatch '(?i)MUI|Proofing|Revis|Click-to-Run|Shared|Language|Idioma' }) | Select-Object -First 1
        if ($msi) { $edicao = "$($msi.Nome)"; $versao = "$($msi.Versao)"; $canal = 'MSI (sem canal)' }
    }
    if (-not $edicao) { return [pscustomobject]@{ Edicao = ''; Versao = ''; Canal = ''; Licenca = ''; Ativacao = ''; Conta = '' } }
    $lic = Get-AtivacaoLicenca '0ff1ce15-a989-479d-af46-f275c6370663' 'Ativação do Office'
    $situacao = Get-SituacaoOffice $lic $edicao
    # Conta conectada: só de quem está logado agora.
    $contas = @(foreach ($p in @($Perfis | Where-Object { $_.Carregado })) {
        foreach ($i in Get-ChildItem -LiteralPath "$($p.Raiz)\Software\Microsoft\Office\16.0\Common\Identity\Identities" -ErrorAction SilentlyContinue) {
            $email = "$($i.GetValue('EmailAddress'))"
            if ($email) { $email }
        }
    })
    [pscustomobject]@{ Edicao = $edicao; Versao = $versao; Canal = $canal; Licenca = $situacao.Licenca; Ativacao = $situacao.Ativacao; Conta = (@($contas | Select-Object -Unique) -join '; ') }
}

function ConvertTo-LinhaCertificado {
    # Só certificado ICP-Brasil. O tipo (A1, A3) vem da política do certificado, e não de como ele está instalado.
    param($Certificado, [string]$Usuario, [string]$Repositorio)
    $politicas = @($Certificado.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.32' } | ForEach-Object { $_.Format($false) }) -join ' '
    $oid = [regex]::Match($politicas, '2\.16\.76\.1\.2\.(\d)')
    if (-not $oid.Success -and $Certificado.Issuer -notmatch '(?i)ICP-Brasil') { return }
    # O CN do e-CPF traz "NOME:CPF": o CPF não precisa sair da máquina.
    $titular = $Certificado.GetNameInfo('SimpleName', $false) -replace ':\d{11}$', ''
    [pscustomobject]@{
        Titular       = $titular
        Tipo          = if ($oid.Success) { "A$($oid.Groups[1].Value)" } else { 'Não identificado' }
        Emissor       = $Certificado.GetNameInfo('SimpleName', $true)
        ValidoAte     = Format-DataEstacao $Certificado.NotAfter
        DiasRestantes = [int][math]::Floor(($Certificado.NotAfter - (Get-Date)).TotalDays)
        Usuario       = $Usuario
        Repositorio   = $Repositorio
    }
}

function Get-CertificadosIcp {
    # Lê a parte pública, do repositório de cada perfil. Chave privada e pasta Crypto não são tocadas.
    param($Perfis)
    $candidatos = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Perfis)) {
        $pasta = Join-Path $p.Pasta 'AppData\Roaming\Microsoft\SystemCertificates\My\Certificates'
        foreach ($a in Get-ChildItem -LiteralPath $pasta -File -Force -ErrorAction SilentlyContinue) {
            try {
                $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [IO.File]::ReadAllBytes($a.FullName))
                $candidatos.Add([pscustomobject]@{ Certificado = $c; Usuario = $p.Usuario; Repositorio = 'Usuário' })
            } catch { }
        }
        if ($p.Carregado) {
            foreach ($k in Get-ChildItem -LiteralPath "$($p.Raiz)\Software\Microsoft\SystemCertificates\My\Certificates" -ErrorAction SilentlyContinue) {
                try {
                    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$k.GetValue('Blob'))
                    $candidatos.Add([pscustomobject]@{ Certificado = $c; Usuario = $p.Usuario; Repositorio = 'Usuário' })
                } catch { }
            }
        }
    }
    foreach ($c in Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue) {
        $candidatos.Add([pscustomobject]@{ Certificado = $c; Usuario = ''; Repositorio = 'Computador' })
    }
    $vistos = @{}
    foreach ($item in $candidatos) {
        $chave = "$($item.Usuario)|$($item.Certificado.Thumbprint)"
        if ($vistos.ContainsKey($chave)) { continue }
        $vistos[$chave] = $true
        ConvertTo-LinhaCertificado $item.Certificado $item.Usuario $item.Repositorio
    }
}

function Test-PortaCoberta {
    # LocalPort vem como número, faixa (5000-6000), nome (RPC, RPCEPMap) ou Any.
    param($Portas, [string[]]$Alvos)
    foreach ($p in @($Portas)) {
        $texto = "$p"
        if ($texto -eq 'Any' -or $Alvos -contains $texto) { return $true }
        if ($texto -match '^(\d+)-(\d+)$') {
            $de = [int]$Matches[1]; $ate = [int]$Matches[2]
            foreach ($a in $Alvos) { if ($a -match '^\d+$' -and [int]$a -ge $de -and [int]$a -le $ate) { return $true } }
        }
    }
    $false
}

function Get-SituacaoPortaFirewall {
    # Só conta regra do perfil ativo; bloqueio vence permissão. Com mais de uma rede ativa, vale a mais aberta: basta uma deixar entrar.
    param($Regras, [string[]]$Alvos, $Perfis)
    $melhor = 'bloqueada'
    foreach ($perfil in @($Perfis)) {
        if (-not $perfil.Filtra) { return 'liberada' }
        $daqui = @($Regras | Where-Object {
            $nomes = "$($_.Perfis)" -split ',\s*'
            ($nomes -contains 'Any' -or $nomes -contains $perfil.Nome) -and (Test-PortaCoberta $_.Portas $Alvos)
        })
        $bloqueios = @($daqui | Where-Object { $_.Acao -eq 'Block' })
        if (@($bloqueios | Where-Object { -not $_.Restrita }).Count) { continue }
        $permissoes = @($daqui | Where-Object { $_.Acao -eq 'Allow' })
        if (-not $perfil.PadraoPermite -and -not $permissoes.Count) { continue }
        $paraTodos = $perfil.PadraoPermite -or @($permissoes | Where-Object { -not $_.Restrita }).Count -gt 0
        if ($paraTodos -and -not $bloqueios.Count) { return 'liberada' }
        $melhor = 'restrita'
    }
    $melhor
}

function Format-AcessoEntrada {
    # Responde por que a consulta remota falha. "restrita": a regra vale só para algumas origens, então a resposta depende de quem consulta.
    param($Regras, $Perfis)
    if ($null -eq $Regras -or -not $Perfis) { return 'N/D' }
    $servicos = [ordered]@{
        'WinRM 5985'  = @('5985', '5986')
        'WMI/RPC 135' = @('RPC', 'RPCEPMap', '135')
        'SMB 445'     = @('445')
        'RDP 3389'    = @('3389')
    }
    @(foreach ($s in $servicos.Keys) {
        "${s}: $(Get-SituacaoPortaFirewall $Regras $servicos[$s] $Perfis)"
    }) -join ' | '
}

function Get-FirewallEntrada {
    # Regras efetivas (inclui as de GPO) e perfis das redes ativas. Exige administrador: fora disso devolve $null e o campo sai N/D.
    Invoke-ComLimite {
        $regras = @{}
        Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Enabled True -ErrorAction Stop | ForEach-Object { $regras[$_.InstanceID] = @{ Acao = "$($_.Action)"; Perfis = "$($_.Profile)" } }
        $abertas = @{}
        Get-NetFirewallAddressFilter -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
            $abertas[$_.InstanceID] = -not @(@($_.RemoteAddress) + @($_.LocalAddress) | Where-Object { "$_" -ne 'Any' }).Count
        }
        $lista = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $regras.ContainsKey($_.InstanceID) -and "$($_.Protocol)" -in 'TCP', '6', 'Any' } |
            ForEach-Object {
                $r = $regras[$_.InstanceID]
                # Sem filtro de endereço conhecido, não dá para afirmar que vale para todas as origens.
                [pscustomobject]@{ Acao = $r.Acao; Perfis = $r.Perfis; Portas = [string[]]@($_.LocalPort | ForEach-Object { "$_" }); Restrita = (-not $abertas[$_.InstanceID]) }
            })
        $ativos = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
            switch ("$($_.NetworkCategory)") { 'DomainAuthenticated' { 'Domain' } 'Private' { 'Private' } default { 'Public' } }
        })
        if (-not $ativos.Count) { $ativos = @('Public') }
        $perfis = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { $ativos -contains "$($_.Name)" } | ForEach-Object {
            [pscustomobject]@{ Nome = "$($_.Name)"; Filtra = ("$($_.Enabled)" -ne 'False'); PadraoPermite = ("$($_.DefaultInboundAction)" -eq 'Allow') }
        })
        [pscustomobject]@{ Regras = $lista; Perfis = $perfis }
    } 'Regras do firewall' 120 $null
}

function Get-SituacaoLaps {
    # Raízes de política documentadas pela Microsoft, na ordem em que o Windows as consulta.
    foreach ($raiz in 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS') {
        $p = Get-ItemProperty $raiz -ErrorAction SilentlyContinue
        if ($p -and $null -ne $p.BackupDirectory -and [int]$p.BackupDirectory -ne 0) {
            return "Windows LAPS ($(if ([int]$p.BackupDirectory -eq 1) { 'Entra ID' } else { 'Active Directory' }))"
        }
    }
    $legado = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd' -ErrorAction SilentlyContinue
    if ($legado -and [int]$legado.AdmPwdEnabled -eq 1) { return 'LAPS legado (AdmPwd)' }
    'Não configurado'
}

function Get-PoliticaSenha {
    # Política aplicada por GPO, sem abrir o net.exe. Exige administrador: fora disso sai N/D.
    $dados = @(Invoke-ComLimite {
        Get-CimInstance -Namespace root\rsop\computer -ClassName RSOP_SecuritySettingNumeric -ErrorAction Stop | Where-Object { $_.Precedence -eq 1 } | Select-Object KeyName, @{ n = 'Valor'; e = { $_.Setting } }
        Get-CimInstance -Namespace root\rsop\computer -ClassName RSOP_SecuritySettingBoolean -ErrorAction Stop | Where-Object { $_.Precedence -eq 1 } | Select-Object KeyName, @{ n = 'Valor'; e = { $_.Setting } }
    } 'Política de senha' 30 @('N/D'))
    if ($dados -contains 'N/D') { return 'N/D' }
    Format-PoliticaSenha $dados
}

function Format-PoliticaSenha {
    param($Dados)
    $v = @{}
    foreach ($d in @($Dados)) { $v["$($d.KeyName)"] = $d.Valor }
    $partes = @(
        if ($v.ContainsKey('MinimumPasswordLength')) { "Mínimo $($v['MinimumPasswordLength'])" }
        if ($v.ContainsKey('PasswordComplexity')) { "Complexidade $(if ($v['PasswordComplexity'] -in $true, 'True', 1) { 'sim' } else { 'não' })" }
        if ($v.ContainsKey('MaximumPasswordAge')) { "Validade $($v['MaximumPasswordAge']) d" }
        if ($v.ContainsKey('PasswordHistorySize')) { "Histórico $($v['PasswordHistorySize'])" }
        if ($v.ContainsKey('LockoutBadCount')) { "Bloqueio após $($v['LockoutBadCount'])" }
    )
    if ($partes.Count) { $partes -join ' | ' } else { 'Sem política de senha por GPO' }
}

function Get-SituacaoUsb {
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' -ErrorAction SilentlyContinue
    if ($pol -and [int]$pol.Deny_All -eq 1) { return 'Bloqueado por política' }
    # {53f5630d...} é a classe de disco removível.
    $classe = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}' -ErrorAction SilentlyContinue
    if ($classe -and ([int]$classe.Deny_Read -eq 1 -or [int]$classe.Deny_Write -eq 1)) { return 'Bloqueado por política' }
    $inicio = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start -ErrorAction SilentlyContinue).Start
    if ($inicio -eq 4) { return 'Bloqueado (driver USBSTOR desativado)' }
    'Liberado'
}

function Format-BloqueioTela {
    # InactivitySeg vem da política da máquina; os outros, da proteção de tela do usuário (política ou preferência).
    param($InactivitySeg, $Ativo, $ComSenha, $TimeoutSeg, [bool]$TemUsuario = $true)
    if ($InactivitySeg -and [int]$InactivitySeg -gt 0) { return "Por política da máquina: $([int][math]::Ceiling([int]$InactivitySeg / 60)) min" }
    if ("$Ativo" -eq '1' -and "$ComSenha" -eq '1' -and [int]"0$TimeoutSeg" -gt 0) { return "Proteção de tela com senha: $([int][math]::Ceiling([int]$TimeoutSeg / 60)) min" }
    if (-not $TemUsuario) { return 'Não avaliado (ninguém logado)' }
    'Não configurado'
}

function Get-BloqueioTela {
    param($Perfis)
    $maquina = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue).InactivityTimeoutSecs
    $logados = @($Perfis | Where-Object { $_.Carregado })
    $resultado = Format-BloqueioTela $maquina $null $null $null ($logados.Count -gt 0)
    foreach ($p in $logados) {
        if ($resultado -notin 'Não configurado', 'Não avaliado (ninguém logado)') { break }
        foreach ($sub in 'Software\Policies\Microsoft\Windows\Control Panel\Desktop', 'Control Panel\Desktop') {
            $d = Get-ItemProperty -LiteralPath "$($p.Raiz)\$sub" -ErrorAction SilentlyContinue
            if ($d -and $d.ScreenSaveActive) {
                $resultado = Format-BloqueioTela $null $d.ScreenSaveActive $d.ScreenSaverIsSecure $d.ScreenSaveTimeOut $true
                break
            }
        }
    }
    $resultado
}

function Test-ItemLocal {
    # Arquivo só na nuvem fica de fora, e pasta nessa condição nem é listada (listar baixaria o conteúdo dela).
    # O ReparsePoint sozinho não basta: no OneDrive, pasta e arquivo já baixados também o têm, sem ser atalho.
    # Offline 0x1000, RecallOnOpen 0x40000, RecallOnDataAccess 0x400000.
    param([int]$Atributos, [string]$Vinculo)
    if ($Vinculo) { return $false }
    ($Atributos -band 0x441000) -eq 0
}

function Get-TamanhoPasta {
    # Soma só metadados: nenhum arquivo é aberto. Atalho de pasta e o que está só na nuvem não contam.
    param([string]$Caminho, [Diagnostics.Stopwatch]$Relogio, [int]$PrazoSeg = 120)
    $bytes = [int64]0; $arquivos = 0; $parcial = $false
    $disponivel = [bool](Test-Path -LiteralPath $Caminho)
    if ($disponivel) {
        $pilha = New-Object System.Collections.Generic.Stack[string]
        $pilha.Push($Caminho)
        while ($pilha.Count -gt 0 -and -not $parcial) {
            $pasta = $pilha.Pop()
            try {
                foreach ($i in (New-Object IO.DirectoryInfo $pasta).EnumerateFileSystemInfos()) {
                    # Dentro do laço: uma pasta só, com muitos arquivos, também tem que respeitar o prazo.
                    if ($Relogio.Elapsed.TotalSeconds -gt $PrazoSeg) { $parcial = $true; break }
                    $ehPasta = $i -is [IO.DirectoryInfo]
                    $vinculo = if ($ehPasta -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { "$($i.LinkType)" } else { '' }
                    if (-not (Test-ItemLocal ([int]$i.Attributes) $vinculo)) { continue }
                    if ($ehPasta) { $pilha.Push($i.FullName) }
                    else { $bytes += $i.Length; $arquivos++ }
                }
            } catch { if ($pasta -eq $Caminho) { $disponivel = $false } }
        }
    }
    [pscustomobject]@{ Bytes = $bytes; Arquivos = $arquivos; Parcial = $parcial; Disponivel = $disponivel }
}

function Resolve-PastaUsuario {
    # Recebe o valor como está gravado (%USERPROFILE%\Documents). Expandir pelo ambiente do processo daria a pasta de quem roda a coleta (SYSTEM).
    # Devolve $null se sobrar variável sem valor conhecido.
    param([string]$Bruto, [string]$Perfil, [string]$Padrao, [hashtable]$Variaveis = @{})
    if (-not $Bruto) { return (Join-Path $Perfil $Padrao) }
    $caminho = [regex]::Replace($Bruto, '%USERPROFILE%', $Perfil.Replace('$', '$$'), 'IgnoreCase')
    foreach ($n in $Variaveis.Keys) {
        $caminho = [regex]::Replace($caminho, [regex]::Escape("%$n%"), "$($Variaveis[$n])".Replace('$', '$$'), 'IgnoreCase')
    }
    if ($caminho -match '%[^%\\]+%') { return $null }
    $caminho
}

function Test-CaminhoNaRede {
    param([string]$Caminho)
    if ($Caminho -match '^\\\\') { return $true }
    if ($Caminho -notmatch '^[A-Za-z]:') { return $false }
    try { "$((New-Object IO.DriveInfo $Caminho.Substring(0, 1)).DriveType)" -eq 'Network' } catch { $false }
}

function Test-CaminhoDentroDe {
    param([string]$Caminho, [string]$Pai)
    $c = $Caminho.TrimEnd('\'); $p = $Pai.TrimEnd('\')
    $c -ieq $p -or $c.StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-PastasConhecidas {
    # Só a hive carregada diz para onde a pasta foi. Sem ela, vale o padrão mais as pastas do OneDrive no perfil, o redirecionamento mais comum.
    param($Perfil)
    $chave = $null; $variaveis = @{}
    if ($Perfil.Carregado) {
        $chave = Get-Item -LiteralPath "$($Perfil.Raiz)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
        foreach ($sub in 'Environment', 'Volatile Environment') {
            $k = Get-Item -LiteralPath "$($Perfil.Raiz)\$sub" -ErrorAction SilentlyContinue
            if (-not $k) { continue }
            foreach ($n in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer', 'HOMEDRIVE', 'HOMEPATH', 'HOMESHARE') {
                $v = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                if ($v) { $variaveis[$n] = "$v" }
            }
        }
    }
    $nuvens = @(Get-ChildItem -LiteralPath $Perfil.Pasta -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($d in @(
        @{ Nome = 'Área de Trabalho'; Valores = @('Desktop'); Padrao = 'Desktop'; NaNuvem = @('Desktop', 'Área de Trabalho') }
        @{ Nome = 'Documentos'; Valores = @('Personal', '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'); Padrao = 'Documents'; NaNuvem = @('Documents', 'Documentos') }
        @{ Nome = 'Downloads'; Valores = @('{374DE290-123F-4565-9164-39C4925E467B}'); Padrao = 'Downloads'; NaNuvem = @('Downloads') }
    )) {
        $padrao = Join-Path $Perfil.Pasta $d.Padrao
        if ($chave) {
            $bruto = @($d.Valores | ForEach-Object { $chave.GetValue($_, $null, 'DoNotExpandEnvironmentNames') } | Where-Object { $_ }) | Select-Object -First 1
            $real = Resolve-PastaUsuario "$bruto" $Perfil.Pasta $d.Padrao $variaveis
            [pscustomobject]@{ Nome = $d.Nome; Caminhos = @($real); Redirecionada = ($real -and -not (Test-CaminhoDentroDe $real $padrao)) }
        } else {
            $achadas = @(foreach ($n in $nuvens) { foreach ($s in $d.NaNuvem) { $c = Join-Path $n $s; if (Test-Path -LiteralPath $c) { $c } } })
            [pscustomobject]@{ Nome = $d.Nome; Caminhos = @(@($padrao) + $achadas); Redirecionada = $false }
        }
    }
}

function Get-PastasUsuarios {
    param($Perfis)
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    foreach ($p in @($Perfis)) {
        $pastas = @(Get-PastasConhecidas $p)
        $todos = @($pastas | ForEach-Object { $_.Caminhos } | Where-Object { $_ })
        $medidos = New-Object System.Collections.Generic.List[string]
        $notas = New-Object System.Collections.Generic.List[string]
        $gb = @{}; $total = [int64]0; $arquivos = 0; $parcial = $false; $revisar = $false
        foreach ($pasta in $pastas) {
            $bytes = [int64]0
            foreach ($c in @($pasta.Caminhos)) {
                if (-not $c) { $notas.Add("$($pasta.Nome): caminho não resolvido"); $revisar = $true; continue }
                if (Test-CaminhoNaRede $c) { $notas.Add("$($pasta.Nome): na rede, fora da conta"); $revisar = $true; continue }
                # Mesma pasta, ou pasta dentro de outra da lista, só conta uma vez.
                if ($medidos -contains $c -or @($todos | Where-Object { $_ -ine $c -and (Test-CaminhoDentroDe $c $_) }).Count) { continue }
                $medidos.Add($c)
                $m = Get-TamanhoPasta $c $relogio
                $bytes += $m.Bytes; $arquivos += $m.Arquivos
                if ($m.Parcial) { $parcial = $true }
                if (-not $m.Disponivel) { $notas.Add("$($pasta.Nome): indisponível"); $revisar = $true }
                elseif ($pasta.Redirecionada) { $notas.Add("$($pasta.Nome) em $c") }
            }
            $gb[$pasta.Nome] = $bytes; $total += $bytes
        }
        if ($total -eq 0 -and -not $parcial -and -not $revisar) { continue }
        if (-not $p.Carregado) { $notas.Add('Usuário não logado: redirecionamento não confirmado') }
        [pscustomobject]@{
            Usuario         = $p.Usuario
            AreaTrabalhoGB  = [math]::Round($gb['Área de Trabalho'] / 1GB, 2)
            DocumentosGB    = [math]::Round($gb['Documentos'] / 1GB, 2)
            DownloadsGB     = [math]::Round($gb['Downloads'] / 1GB, 2)
            TotalGB         = [math]::Round($total / 1GB, 2)
            Arquivos        = $arquivos
            Parcial         = $parcial
            OneDriveNoPerfil = [bool](Get-ChildItem -LiteralPath $p.Pasta -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            Observacao      = ($notas.ToArray() -join '; ')
        }
    }
}

function Get-RedeEstacao {
    $virtuais = '(?i)Hyper-V|VMware|VirtualBox|WAN Miniport|TAP-|Tunnel|Loopback|Bluetooth|WireGuard|Fortinet|OpenVPN|Tailscale|ZeroTier'
    $placas = @{}
    foreach ($a in Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue) { $placas[[int]$a.Index] = $a }
    $perfisRede = @{}
    foreach ($n in Get-NetConnectionProfile -ErrorAction SilentlyContinue) { $perfisRede[[int]$n.InterfaceIndex] = "$($n.Name)" }
    foreach ($c in Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop) {
        if ($c.Description -match $virtuais) { continue }
        $placa = $placas[[int]$c.Index]
        $conexao = "$($placa.NetConnectionID)"
        $wifi = "$($c.Description) $conexao" -match '(?i)Wi-?Fi|Wireless|802\.11|WLAN'
        [pscustomobject]@{
            Placa      = $c.Description
            Conexao    = $conexao
            Tipo       = if ($c.DHCPEnabled) { 'DHCP' } else { 'Fixo' }
            IP         = (@($c.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', ')
            Gateway    = (@($c.DefaultIPGateway | Where-Object { $_ -match '^\d+\.' }) -join ', ')
            DNS        = (@($c.DNSServerSearchOrder) -join ', ')
            MAC        = $c.MACAddress
            WiFi       = $wifi
            RedeWiFi   = if ($wifi) { $perfisRede[[int]$c.InterfaceIndex] } else { '' }
        }
    }
}

function Get-ImpressorasEstacao {
    param($Perfis)
    $virtuais = '(?i)PDF|XPS|OneNote|Fax|Send To|Enviar para|AnyDesk'
    foreach ($p in Get-CimInstance Win32_Printer -ErrorAction Stop) {
        if ($p.Name -match $virtuais) { continue }
        [pscustomobject]@{ Nome = $p.Name; Driver = $p.DriverName; Porta = $p.PortName; Compartilhada = [bool]$p.Shared; Origem = 'Computador' }
    }
    # Impressora de rede conectada pelo usuário não aparece para o SYSTEM: vem da hive de quem está logado.
    foreach ($u in @($Perfis | Where-Object { $_.Carregado })) {
        foreach ($k in Get-ChildItem -LiteralPath "$($u.Raiz)\Printers\Connections" -ErrorAction SilentlyContinue) {
            [pscustomobject]@{ Nome = ($k.PSChildName -replace ',', '\'); Driver = ''; Porta = ''; Compartilhada = $false; Origem = $u.Usuario }
        }
    }
}

function Get-UnidadesMapeadas {
    param($Perfis)
    foreach ($u in @($Perfis | Where-Object { $_.Carregado })) {
        foreach ($k in Get-ChildItem -LiteralPath "$($u.Raiz)\Network" -ErrorAction SilentlyContinue) {
            [pscustomobject]@{ Usuario = $u.Usuario; Unidade = "$($k.PSChildName):"; Caminho = "$($k.GetValue('RemotePath'))" }
        }
    }
}

function Get-CompartilhamentosEstacao {
    $padrao = '^(ADMIN\$|IPC\$|[A-Za-z]\$|print\$)$'
    foreach ($s in Get-CimInstance Win32_Share -Filter 'Type=0' -ErrorAction Stop) {
        if ($s.Name -match $padrao) { continue }
        # SID S-1-1-0 é "Todos" em qualquer idioma; o nome devolvido muda conforme o Windows.
        $todos = Invoke-Seguro {
            $acessos = @(Get-SmbShareAccess -Name $s.Name -ErrorAction Stop)
            $nomeTodos = (New-Object Security.Principal.SecurityIdentifier 'S-1-1-0').Translate([Security.Principal.NTAccount]).Value
            (@($acessos | Where-Object { $_.AccountName -eq $nomeTodos -and $_.AccessControlType -eq 'Allow' } | ForEach-Object { "$($_.AccessRight)" }) -join ',')
        } ''
        [pscustomobject]@{ Compartilhamento = $s.Name; Caminho = $s.Path; Descricao = $s.Description; AcessoTodos = $todos }
    }
}

function Get-TarefasForaPadrao {
    @(Invoke-ComLimite {
        $ruido = '(?i)^(MicrosoftEdgeUpdate|OneDrive|GoogleUpdate|GoogleUpdater|Nextec - )'
        Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and "$($_.State)" -ne 'Disabled' -and $_.TaskName -notmatch $ruido } |
            Select-Object -First 100 |
            ForEach-Object {
                # Só o executável: o argumento da tarefa pode conter senha.
                [pscustomobject]@{ Tarefa = $_.TaskName; Pasta = $_.TaskPath; Estado = "$($_.State)"; Conta = $_.Principal.UserId; Executavel = (@($_.Actions | ForEach-Object { $_.Execute }) -join '; '); Autor = $_.Author }
            }
    } 'Tarefas agendadas' 60 @())
}

function Get-ServicosForaPadrao {
    foreach ($s in Get-CimInstance Win32_Service -ErrorAction Stop) {
        if ($s.StartMode -eq 'Disabled' -or -not $s.PathName) { continue }
        $exe = Get-ExecutavelDoComando $s.PathName
        if (Test-CaminhoDoWindows $exe) { continue }
        [pscustomobject]@{ Servico = $s.Name; Nome = $s.DisplayName; Estado = $s.State; Inicio = $s.StartMode; Conta = $s.StartName; Executavel = $exe }
    }
}

function Get-InicializacaoForaPadrao {
    foreach ($i in Get-CimInstance Win32_StartupCommand -ErrorAction Stop) {
        $exe = Get-ExecutavelDoComando $i.Command
        if ((Test-CaminhoDoWindows $exe) -or $i.Name -match '(?i)^SecurityHealth') { continue }
        [pscustomobject]@{ Nome = $i.Name; Executavel = $exe; Origem = $i.Location; Usuario = $i.User }
    }
}

function Get-LogonsComFalha {
    # Agrupado por conta e origem: em máquina exposta são milhares de eventos. Devolve $null se o log não puder ser lido.
    param([int]$Dias = 7)
    Invoke-ComLimite {
        param($Dias)
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddDays(-$Dias) } -MaxEvents 2000 -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ Conta = "$($_.Properties[5].Value)"; Origem = "$($_.Properties[19].Value)"; TipoLogon = "$($_.Properties[10].Value)"; Quando = $_.TimeCreated } }
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { throw }
            [pscustomobject]@{ Conta = ''; Origem = ''; TipoLogon = ''; Quando = $null }
        }
    } 'Logons com falha' 60 $null @($Dias)
}

function Get-ResumoLogons {
    param($Eventos)
    $reais = @($Eventos | Where-Object { $_.Conta -or $_.Origem })
    $grupos = @($reais | Group-Object Conta, Origem, TipoLogon | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
        $g = $_.Group[0]
        [pscustomobject]@{ Conta = $g.Conta; Origem = $g.Origem; TipoLogon = $g.TipoLogon; Quantidade = $_.Count; Ultimo = Format-DataEstacao (($_.Group | Sort-Object Quando -Descending | Select-Object -First 1).Quando) }
    })
    [pscustomobject]@{ Total = $reais.Count; Grupos = $grupos }
}

function Get-EventosSistema {
    param([int]$Dias = 30)
    @(Invoke-ComLimite {
        param($Dias)
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-$Dias) } -MaxEvents 1000 -ErrorAction SilentlyContinue |
            Group-Object ProviderName, Id |
            ForEach-Object {
                # A mensagem é cara de montar: lê uma por grupo, não uma por evento.
                $m = "$($_.Group[0].Message)" -replace '\s+', ' '
                [pscustomobject]@{
                    Origem = $_.Group[0].ProviderName; Id = [int]$_.Group[0].Id; Nivel = [int]$_.Group[0].Level; Quantidade = $_.Count
                    Ultimo = $_.Group[0].TimeCreated.ToString('dd/MM/yyyy HH:mm'); Mensagem = $(if ($m.Length -gt 200) { $m.Substring(0, 200) } else { $m })
                }
            }
    } 'Eventos do sistema' 90 @() @($Dias))
}

function Get-ResumoEventos {
    param($Eventos)
    $lista = @($Eventos)
    $soma = { param($Filtrados) $t = 0; foreach ($e in @($Filtrados)) { $t += [int]$e.Quantidade }; $t }
    [pscustomobject]@{
        TelasAzuis      = & $soma ($lista | Where-Object { $_.Id -eq 1001 -and $_.Origem -match '(?i)WER-SystemErrorReporting|BugCheck' })
        Inesperados     = & $soma ($lista | Where-Object { ($_.Id -eq 41 -and $_.Origem -match '(?i)Kernel-Power') -or ($_.Id -eq 6008) })
        Criticos        = & $soma ($lista | Where-Object { $_.Nivel -eq 1 })
        Erros           = & $soma ($lista | Where-Object { $_.Nivel -eq 2 })
    }
}

function Get-DiscosEstacao {
    @(Invoke-ComLimite {
        Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            $r = try { $_ | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null }
            [pscustomobject]@{
                Modelo = "$($_.FriendlyName)".Trim(); Serie = "$($_.SerialNumber)".Trim(); Tipo = "$($_.MediaType)"; Barramento = "$($_.BusType)"
                TamanhoGB = [math]::Round($_.Size / 1GB, 0); Saude = "$($_.HealthStatus)"; Estado = (@($_.OperationalStatus | ForEach-Object { "$_" }) -join ',')
                DesgastePct = $r.Wear; TemperaturaC = $r.Temperature; HorasLigado = $r.PowerOnHours; ErrosLeitura = $r.ReadErrorsUncorrected
            }
        }
    } 'Discos físicos e SMART' 60 @())
}

function Format-SaudeDiscos {
    param($Discos, [bool]$PrevisaoFalha)
    $lista = @($Discos | Where-Object { $_ })
    $ruins = @($lista | Where-Object { $_.Saude -and $_.Saude -notmatch '(?i)^(Healthy|Saud[aá]vel)$' })
    if ($PrevisaoFalha -or $ruins.Count -gt 0) {
        return 'ATENÇÃO: ' + (@(
            if ($PrevisaoFalha) { 'SMART prevê falha' }
            $ruins | ForEach-Object { "$($_.Modelo) $($_.Saude)" }
        ) -join '; ')
    }
    if ($lista.Count -eq 0) { return 'N/D' }
    'Saudáveis'
}

try {
    Write-LogEstacao "Início da coleta (coletor $versaoColetor) para $env:COMPUTERNAME"

    $cs    = Get-CimInstance Win32_ComputerSystem
    $bios  = Get-CimInstance Win32_BIOS
    $so    = Get-CimInstance Win32_OperatingSystem
    $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
    $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $perfis = @(Invoke-Seguro { Get-PerfisUsuario } @())

    # Antivírus: Security Center nas estações; em servidor, pelos serviços em execução.
    $av = Invoke-Seguro { (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop).displayName -join '; ' } ''
    if (-not $av) {
        $regexAv = '(?i)Acronis (Active Protection|Cyber Protection)|Kaspersky|\bESET\b|Sophos|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|SentinelOne|CrowdStrike|Avast|\bAVG\b|Norton|Panda|Webroot|Malwarebytes|Cylance|Cortex|Huntress|^WinDefend$'
        $av = Invoke-Seguro {
            (Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction Stop |
                Where-Object { $_.DisplayName -match $regexAv -or $_.Name -match $regexAv } |
                ForEach-Object { $_.DisplayName } | Select-Object -Unique -First 3) -join '; '
        } ''
        if (-not $av) { $av = 'N/D' }
    }

    $midia = Invoke-Seguro {
        (Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
            ForEach-Object { switch ([int]$_.MediaType) { 3 { 'HDD' } 4 { 'SSD' } default { 'Não informado' } } }) -join '; '
    } ''

    $bitlocker = Invoke-Seguro {
        (Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
            ForEach-Object {
                $st = switch ([int]$_.ProtectionStatus) { 0 { 'desprotegido' } 1 { 'protegido' } default { 'desconhecido' } }
                "$($_.DriveLetter) $st"
            }) -join '; '
    } 'N/D'

    $tempoReal = $null; $assinatura = $null
    try {
        $mp = Get-CimInstance -Namespace 'root\Microsoft\Windows\Defender' -ClassName MSFT_MpComputerStatus -ErrorAction Stop
        $tempoReal = $mp.RealTimeProtectionEnabled
        $assinatura = $mp.AntivirusSignatureLastUpdated
    } catch { }

    $ultimoPatch = Invoke-Seguro {
        (Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop |
            Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn
    }

    # Administradores locais pelo SID do grupo (o nome muda conforme o idioma).
    $admins = Invoke-Seguro {
        $grupo = Get-CimInstance Win32_Group -Filter "SID='S-1-5-32-544'" -ErrorAction Stop | Select-Object -First 1
        if ($grupo) {
            $consulta = "ASSOCIATORS OF {Win32_Group.Domain='$($grupo.Domain)',Name='$($grupo.Name)'} WHERE AssocClass=Win32_GroupUser Role=GroupComponent"
            (Get-CimInstance -Query $consulta -ErrorAction Stop | ForEach-Object { "$($_.Domain)\$($_.Name)" }) -join '; '
        } else { '' }
    } 'N/D'

    # Softwares instalados (registro 64 e 32 bits).
    $softwares = @(Invoke-Seguro {
        $chaves = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') +
                  @($perfis | Where-Object { $_.Carregado } | ForEach-Object { "$($_.Raiz)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" })
        Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
            Select-Object @{ n = 'Nome'; e = { $_.DisplayName.Trim() } },
                          @{ n = 'Versao'; e = { $_.DisplayVersion } },
                          @{ n = 'Fabricante'; e = { $_.Publisher } } |
            Sort-Object Nome, Versao -Unique
    } @())

    $tpm = Invoke-Seguro {
        $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($t -and $t.IsEnabled_InitialValue) { 'Presente e ativo' } elseif ($t) { 'Presente, desativado' } else { 'Ausente' }
    } 'N/D'
    $secureBoot = Invoke-Seguro { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'Ligado' } else { 'Desligado' } } 'N/D'
    $rdp = Invoke-Seguro {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections
        if ($v -eq 0) { 'Habilitado' } else { 'Desabilitado' }
    } 'N/D'
    $acessoRemoto = ($softwares | Where-Object { $_.Nome -match '(?i)AnyDesk|TeamViewer|RustDesk|Radmin|UltraVNC|TightVNC|Splashtop|LogMeIn|ScreenConnect|Chrome Remote' } |
        ForEach-Object { $_.Nome } | Select-Object -Unique) -join '; '
    $reinicioPendente = Invoke-Seguro {
        [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    } $null
    $firewall = Invoke-Seguro {
        (Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object { "$($_.Name): $(if ($_.Enabled) { 'ligado' } else { 'DESLIGADO' })" }) -join ' | '
    } 'N/D'

    # Licenças e software
    $licWindows = Get-AtivacaoLicenca '55c92734-d682-4d71-983e-d6ec3f16059f' 'Ativação do Windows'
    $office = Invoke-Seguro { Get-OfficeEstacao $softwares $perfis } ([pscustomobject]@{ Edicao = 'N/D'; Versao = ''; Canal = ''; Ativacao = 'N/D'; Conta = '' })
    $certificados = @(Invoke-Seguro { Get-CertificadosIcp $perfis } @())
    $leitoras = @(Invoke-Seguro { Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SmartCardReader' OR PNPClass='SmartCard'" -ErrorAction Stop | ForEach-Object { $_.Name } } @())
    $driversToken = (@(@($softwares | Where-Object { $_.Nome -match '(?i)SafeNet|SafeSign|eToken|Gemalto|Thales|Aladdin|StarSign|WatchData|Watchkey|ePass|Feitian|Pronova|Bit4id|Athena|\bToken\b' } | ForEach-Object { $_.Nome }) + $leitoras) | Select-Object -Unique) -join '; '

    # Segurança
    $acessoEntrada = Invoke-Seguro { $fw = Get-FirewallEntrada; if ($fw) { Format-AcessoEntrada $fw.Regras $fw.Perfis } else { 'N/D' } } 'N/D'
    $winrm = Invoke-Seguro {
        $s = Get-Service WinRM -ErrorAction Stop
        $ouvinte = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Listener' -ErrorAction SilentlyContinue).Count -gt 0
        "Serviço $(if ($s.Status -eq 'Running') { 'rodando' } else { 'parado' }), $(if ($ouvinte) { 'com' } else { 'sem' }) listener"
    } 'N/D'
    $smb = Invoke-Seguro { Get-SmbServerConfiguration -ErrorAction Stop } $null
    $contasLocais = @(Invoke-Seguro {
        Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=TRUE' -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Conta = $_.Name; Habilitada = -not $_.Disabled; SenhaObrigatoria = [bool]$_.PasswordRequired; SenhaExpira = [bool]$_.PasswordExpires; AdministradorEmbutido = ($_.SID -match '-500$') }
        }
    } @())
    $adminEmbutido = @($contasLocais | Where-Object { $_.AdministradorEmbutido }) | Select-Object -First 1
    $laps = Invoke-Seguro { Get-SituacaoLaps } 'N/D'
    $politicaSenha = Invoke-Seguro { Get-PoliticaSenha } 'N/D'
    $compartilhamentos = @(Invoke-Seguro { Get-CompartilhamentosEstacao } @())
    $usb = Invoke-Seguro { Get-SituacaoUsb } 'N/D'
    $bloqueioTela = Invoke-Seguro { Get-BloqueioTela $perfis } 'N/D'
    $tarefas = @(Invoke-Seguro { Get-TarefasForaPadrao } @())
    $servicosFora = @(Invoke-Seguro { Get-ServicosForaPadrao } @())
    $inicializacao = @(Invoke-Seguro { Get-InicializacaoForaPadrao } @())
    $logonsBrutos = Get-LogonsComFalha 7
    $logons = if ($null -ne $logonsBrutos) { Get-ResumoLogons $logonsBrutos } else { $null }

    # Rede e periféricos
    $rede = @(Invoke-Seguro { Get-RedeEstacao } @())
    $impressoras = @(Invoke-Seguro { Get-ImpressorasEstacao $perfis } @())
    $scanners = @(Invoke-Seguro {
        Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Image'" -ErrorAction Stop |
            Where-Object { $_.Name -notmatch '(?i)cam|c[aâ]mera' } | ForEach-Object { [pscustomobject]@{ Nome = $_.Name; Fabricante = $_.Manufacturer } }
    } @())
    $unidades = @(Invoke-Seguro { Get-UnidadesMapeadas $perfis } @())

    # Saúde e dados
    $discos = @(Get-DiscosEstacao)
    $previsaoFalha = @(Invoke-ComLimite {
        Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure }
    } 'Previsão de falha de disco' 30 @()).Count -gt 0
    $eventos = @(Get-EventosSistema 30)
    $resumoEventos = Get-ResumoEventos $eventos
    $minidumps = @(Get-ChildItem (Join-Path $env:SystemRoot 'Minidump') -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue).Count
    $pastasUsuarios = @(Invoke-Seguro { Get-PastasUsuarios $perfis } @())
    $dadosLocaisGB = 0.0
    foreach ($p in $pastasUsuarios) { $dadosLocaisGB += [double]$p.TotalGB }

    $inventario = [ordered]@{
        Computador            = "$env:COMPUTERNAME"
        Status                = 'OK'
        Origem                = 'Coleta local (GPO)'
        ColetadoEm            = (Get-Date).ToString('s')
        VersaoColetor         = $versaoColetor
        Fabricante            = $cs.Manufacturer
        Modelo                = $cs.Model
        NumeroSerie           = $bios.SerialNumber
        SO                    = $so.Caption
        Build                 = $so.BuildNumber
        Processador           = "$($cpu.Name)".Trim()
        MemoriaGB             = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        MemoriaLivreGB        = if ($so.FreePhysicalMemory) { [math]::Round($so.FreePhysicalMemory / 1MB, 1) } else { $null }
        DiscoCGB              = if ($disco) { [math]::Round($disco.Size / 1GB, 0) } else { $null }
        LivreCPct             = if ($disco -and $disco.Size) { [math]::Round($disco.FreeSpace / $disco.Size * 100, 0) } else { $null }
        TipoDisco             = $midia
        Antivirus             = $av
        DefenderTempoReal     = $tempoReal
        AssinaturaAV          = Format-DataEstacao $assinatura
        DiasAssinaturaAV      = if ($assinatura) { [int]((Get-Date) - $assinatura).TotalDays } else { $null }
        BitLocker             = $bitlocker
        UltimoPatch           = Format-DataEstacao $ultimoPatch
        DiasSemPatch          = if ($ultimoPatch) { [int]((Get-Date) - $ultimoPatch).TotalDays } else { $null }
        AdministradoresLocais = $admins
        UsuarioLogado         = $cs.UserName
        UltimoBoot            = Format-DataEstacao $so.LastBootUpTime
        InstaladoEm           = Format-DataEstacao $so.InstallDate
        TPM                   = $tpm
        SecureBoot            = $secureBoot
        RDP                   = $rdp
        AcessoRemotoInstalado = $acessoRemoto
        ReinicioPendente      = $reinicioPendente
        Firewall              = $firewall
        BiosVersao            = "$($bios.SMBIOSBIOSVersion)"
        BiosData              = Format-DataEstacao $bios.ReleaseDate
        WindowsAtivacao       = if ($licWindows) { ConvertTo-StatusLicenca $licWindows.LicenseStatus } else { 'N/D' }
        WindowsCanal          = if ($licWindows) { ConvertTo-CanalLicenca $licWindows.ProductKeyChannel } else { '' }
        WindowsChaveFinal     = if ($licWindows) { "$($licWindows.PartialProductKey)" } else { '' }
        OfficeEdicao          = $office.Edicao
        OfficeVersao          = $office.Versao
        OfficeCanal           = $office.Canal
        OfficeLicenca         = $office.Licenca
        OfficeAtivacao        = $office.Ativacao
        OfficeConta           = $office.Conta
        QtdCertificados       = $certificados.Count
        DriversToken          = $driversToken
        AcessoEntrada         = $acessoEntrada
        WinRM                 = $winrm
        SMBv1                 = if ($smb) { if ($smb.EnableSMB1Protocol) { 'Ligado' } else { 'Desligado' } } else { 'N/D' }
        SMBAssinatura         = if ($smb) { if ($smb.RequireSecuritySignature) { 'Obrigatória' } else { 'Opcional' } } else { 'N/D' }
        AdministradorLocal    = if ($adminEmbutido) { if ($adminEmbutido.Habilitada) { "Habilitada ($($adminEmbutido.Conta))" } else { 'Desabilitada' } } else { 'N/D' }
        ContasLocaisAtivas    = (@($contasLocais | Where-Object { $_.Habilitada } | ForEach-Object { $_.Conta }) -join '; ')
        ContasSemSenhaObrigatoria = (@($contasLocais | Where-Object { $_.Habilitada -and -not $_.SenhaObrigatoria } | ForEach-Object { $_.Conta }) -join '; ')
        LAPS                  = $laps
        PoliticaSenha         = $politicaSenha
        QtdCompartilhamentos  = $compartilhamentos.Count
        USB                   = $usb
        BloqueioTela          = $bloqueioTela
        QtdTarefasForaPadrao  = $tarefas.Count
        QtdServicosForaPadrao = $servicosFora.Count
        QtdInicializacao      = $inicializacao.Count
        LogonsFalha7d         = if ($logons) { $logons.Total } else { $null }
        IpTipo                = (@($rede | Where-Object { $_.IP } | ForEach-Object { $_.Tipo } | Select-Object -Unique) -join ' e ')
        IpLocal               = (@($rede | Where-Object { $_.IP } | ForEach-Object { $_.IP }) -join ', ')
        DnsServidores         = (@($rede | Where-Object { $_.DNS } | ForEach-Object { $_.DNS } | Select-Object -Unique) -join ', ')
        MAC                   = (@($rede | Where-Object { $_.IP } | ForEach-Object { $_.MAC }) -join ', ')
        UsaWiFi               = if ($rede.Count) { if (@($rede | Where-Object { $_.WiFi -and $_.IP }).Count) { 'Sim' } else { 'Não' } } else { 'N/D' }
        RedeWiFi              = (@($rede | Where-Object { $_.RedeWiFi } | ForEach-Object { $_.RedeWiFi } | Select-Object -Unique) -join ', ')
        QtdImpressoras        = $impressoras.Count
        QtdScanners           = $scanners.Count
        QtdUnidadesMapeadas   = $unidades.Count
        SaudeDiscos           = Format-SaudeDiscos $discos $previsaoFalha
        TelasAzuis30d         = $resumoEventos.TelasAzuis
        DesligamentosInesperados30d = $resumoEventos.Inesperados
        ErrosCriticos30d      = $resumoEventos.Criticos
        ErrosSistema30d       = $resumoEventos.Erros
        Minidumps             = $minidumps
        DadosLocaisGB         = [math]::Round($dadosLocaisGB, 2)
        QtdSoftwares          = $softwares.Count
        Softwares             = $softwares
        # Listas viram um CSV cada no assessment; ficam fora das colunas do inventário.
        Detalhes              = [ordered]@{
            Certificados      = $certificados
            ContasLocais      = $contasLocais
            Compartilhamentos = $compartilhamentos
            Tarefas           = $tarefas
            Servicos          = $servicosFora
            Inicializacao     = $inicializacao
            LogonsFalha       = @(if ($logons) { $logons.Grupos })
            Rede              = $rede
            Impressoras       = $impressoras
            Scanners          = $scanners
            Unidades          = $unidades
            Discos            = $discos
            Eventos           = @($eventos | Sort-Object Nivel, @{ e = { $_.Quantidade }; Descending = $true } | Select-Object -First 15)
            PastasUsuario     = $pastasUsuarios
        }
    }

    $json = $inventario | ConvertTo-Json -Depth 5
    $nomeArquivo = "$($env:COMPUTERNAME.ToUpper()).json"

    # Cópia local primeiro: se o compartilhamento estiver fora do ar, a próxima execução entrega.
    $arquivoLocal = Join-Path $pastaLocal $nomeArquivo
    [IO.File]::WriteAllText($arquivoLocal, $json, (New-Object System.Text.UTF8Encoding($true)))

    # Entrega atômica: grava com extensão temporária e renomeia, para o assessment nunca ler arquivo pela metade.
    $temporario = Join-Path $Destino "$nomeArquivo.tmp"
    $final = Join-Path $Destino $nomeArquivo
    try {
        [IO.File]::WriteAllText($temporario, $json, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temporario -Destination $final -Force
        Write-LogEstacao "Gravado em $final ($($softwares.Count) softwares)"
        exit 0
    } catch {
        Write-LogEstacao "Compartilhamento inalcançável ($Destino): $($_.Exception.Message). Cópia local mantida."
        exit 1
    }
} catch {
    Write-LogEstacao "ERRO: $($_.Exception.Message)"
    exit 2
}
