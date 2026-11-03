# Testes das funções puras do Nextec-Assessment-Estacao.ps1 (Pester 3.4+, Windows PowerShell 5.1).
# Carrega só as funções pelo AST, sem executar a coleta. Não exige administrador.
$script:Raiz = Split-Path -Parent $PSScriptRoot
$arquivo = Join-Path $script:Raiz 'Nextec-Assessment-Estacao.ps1'
$tokens = $null; $erros = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros)

$nomes = 'Get-ExecutavelDoComando', 'Test-CaminhoDoWindows', 'ConvertTo-CanalLicenca', 'ConvertTo-StatusLicenca',
    'Format-DataEstacao', 'ConvertTo-LinhaCertificado', 'Format-AcessoEntrada', 'Format-PoliticaSenha',
    'Format-BloqueioTela', 'Get-TamanhoPasta', 'Get-ResumoEventos', 'Format-SaudeDiscos'
$achadas = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $nomes }, $true))
foreach ($f in $achadas) {
    . ([scriptblock]::Create($f.Extent.Text))
}

# Apoio dos testes: pasta temporária própria e certificado autoassinado.
function New-PastaTemp {
    $p = Join-Path $env:TEMP ('NxtColeta_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $p -Force)
    $p
}

function New-ArquivoComBytes {
    param([string]$Caminho, [int]$Tamanho)
    $pai = Split-Path -Parent $Caminho
    if (-not (Test-Path -LiteralPath $pai)) { [void](New-Item -ItemType Directory -Path $pai -Force) }
    [IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Tamanho))
}

$script:TemCertificateRequest = [bool]('System.Security.Cryptography.X509Certificates.CertificateRequest' -as [type])

function New-CertificadoTeste {
    param([string]$Assunto, [byte[]]$Politica, [int]$Dias = 100)
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest ($Assunto, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if ($Politica) {
        $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509Extension ('2.5.29.32', $Politica, $false)))
    }
    $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays($Dias))
}

# Política ICP-Brasil 2.16.76.1.2.3.1 (A3) e 2.16.76.1.2.1.1 (A1) em DER.
$script:PoliticaA3 = [byte[]](0x30, 0x0A, 0x30, 0x08, 0x06, 0x06, 0x60, 0x4C, 0x01, 0x02, 0x03, 0x01)
$script:PoliticaA1 = [byte[]](0x30, 0x0A, 0x30, 0x08, 0x06, 0x06, 0x60, 0x4C, 0x01, 0x02, 0x01, 0x01)

Describe 'Nextec-Assessment-Estacao.ps1' {
    It 'não tem erro de sintaxe' {
        @($erros).Count | Should Be 0
    }
    It 'tem todas as funções testadas aqui' {
        @($achadas | ForEach-Object { $_.Name } | Sort-Object -Unique).Count | Should Be $nomes.Count
    }
    It 'não consulta Get-NetFirewallProfile sem -PolicyStore ActiveStore' {
        $semStore = Select-String -Path $arquivo -Pattern 'Get-NetFirewallProfile\s+-ErrorAction' -Encoding UTF8
        @($semStore).Count | Should Be 0
        $chamadas = @(Get-Content -LiteralPath $arquivo -Encoding UTF8 | Where-Object { $_ -match 'Get-NetFirewallProfile' -and $_ -notmatch '^\s*#' })
        $chamadas.Count | Should BeGreaterThan 0
        @($chamadas | Where-Object { $_ -notmatch '-PolicyStore\s+ActiveStore' }).Count | Should Be 0
    }
}

Describe 'Regex de antivírus por serviço' {
    $texto = [IO.File]::ReadAllText($arquivo, [Text.Encoding]::UTF8)
    $m = [regex]::Match($texto, '\$regexAv\s*=\s*''([^'']+)''')
    It 'encontra a linha $regexAv no coletor' {
        $m.Success | Should Be $true
    }
    $regexAv = $m.Groups[1].Value
    It 'não casa o serviço Reset' {
        ('Reset' -match $regexAv) | Should Be $false
    }
    It 'não casa o Acronis Managed Machine Service' {
        ('Acronis Managed Machine Service' -match $regexAv) | Should Be $false
    }
    It 'casa o ESET Service' {
        ('ESET Service' -match $regexAv) | Should Be $true
    }
    It 'casa o Acronis Active Protection Service' {
        ('Acronis Active Protection Service' -match $regexAv) | Should Be $true
    }
    It 'casa o serviço WinDefend e não casa nome parecido' {
        ('WinDefend' -match $regexAv) | Should Be $true
        ('WinDefendX' -match $regexAv) | Should Be $false
    }
}

Describe 'Get-ExecutavelDoComando' {
    It 'devolve o caminho entre aspas sem os argumentos' {
        Get-ExecutavelDoComando '"C:\Program Files\App Teste\app.exe" -k grupo -p senha123' | Should Be 'C:\Program Files\App Teste\app.exe'
    }
    It 'devolve o caminho sem aspas com espaços até o .exe' {
        Get-ExecutavelDoComando 'C:\Program Files\App Teste\app.exe /s /p senha123' | Should Be 'C:\Program Files\App Teste\app.exe'
    }
    It 'não deixa nenhum argumento no retorno' {
        $r = Get-ExecutavelDoComando 'C:\Program Files\App Teste\app.exe --token SEGREDO123 /x'
        $r | Should Not Match 'SEGREDO123'
        $r | Should Not Match '--token'
        $r | Should Not Match '/x'
    }
    It 'trata .exe seguido de vírgula (rundll32 e similares)' {
        Get-ExecutavelDoComando 'C:\Windows\System32\rundll32.exe,Control_RunDLL x' | Should Be 'C:\Windows\System32\rundll32.exe'
    }
    It 'devolve o caminho sozinho quando não há argumentos' {
        Get-ExecutavelDoComando 'C:\Windows\System32\svchost.exe' | Should Be 'C:\Windows\System32\svchost.exe'
    }
    It 'sem extensão conhecida devolve só a primeira palavra' {
        Get-ExecutavelDoComando 'notepad arquivo.txt' | Should Be 'notepad'
    }
    It 'texto vazio ou nulo devolve vazio' {
        Get-ExecutavelDoComando '' | Should BeNullOrEmpty
        Get-ExecutavelDoComando $null | Should BeNullOrEmpty
    }
}

Describe 'Test-CaminhoDoWindows' {
    It 'é verdadeiro para caminho sob a pasta do Windows' {
        Test-CaminhoDoWindows 'C:\Windows\System32\svchost.exe' | Should Be $true
        Test-CaminhoDoWindows 'D:\WINDOWS\system32\drivers\x.sys' | Should Be $true
    }
    It 'é verdadeiro para as formas \SystemRoot, %SystemRoot% e \??\' {
        Test-CaminhoDoWindows '\SystemRoot\System32\smss.exe' | Should Be $true
        Test-CaminhoDoWindows '%SystemRoot%\system32\x.exe' | Should Be $true
        Test-CaminhoDoWindows '\??\C:\Windows\system32\drivers\x.sys' | Should Be $true
    }
    It 'é verdadeiro para componentes da Microsoft fora da pasta do Windows' {
        Test-CaminhoDoWindows 'C:\Program Files\Windows Defender\MsMpEng.exe' | Should Be $true
        Test-CaminhoDoWindows 'C:\Program Files\Microsoft Office\root\Office16\x.exe' | Should Be $true
    }
    It 'é falso para C:\Program Files\X\y.exe' {
        Test-CaminhoDoWindows 'C:\Program Files\X\y.exe' | Should Be $false
    }
    It 'é falso para C:\Windowsfake\y.exe' {
        Test-CaminhoDoWindows 'C:\Windowsfake\y.exe' | Should Be $false
    }
    It 'é falso quando Windows aparece só dentro do perfil do usuário' {
        Test-CaminhoDoWindows 'C:\Users\fulano\Windows\y.exe' | Should Be $false
    }
}

Describe 'Get-TamanhoPasta' {
    It 'soma bytes e arquivos de uma árvore temporária' {
        $raiz = New-PastaTemp
        try {
            New-ArquivoComBytes (Join-Path $raiz 'a.bin') 100
            New-ArquivoComBytes (Join-Path $raiz 'sub\b.bin') 50
            New-ArquivoComBytes (Join-Path $raiz 'sub\fundo\c.bin') 25
            $r = Get-TamanhoPasta $raiz ([Diagnostics.Stopwatch]::StartNew()) 60
            $r.Bytes | Should Be 175
            $r.Arquivos | Should Be 3
            $r.Parcial | Should Be $false
        } finally { Remove-Item -LiteralPath $raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'pasta que não existe devolve zeros sem erro' {
        $r = Get-TamanhoPasta (Join-Path $env:TEMP ('NxtInexistente_' + [guid]::NewGuid().ToString('N'))) ([Diagnostics.Stopwatch]::StartNew()) 60
        $r.Bytes | Should Be 0
        $r.Arquivos | Should Be 0
        $r.Parcial | Should Be $false
    }
    It 'não segue junction e não conta o arquivo do destino' {
        $raiz = New-PastaTemp
        $externo = New-PastaTemp
        $junc = Join-Path $raiz 'atalho'
        try {
            New-ArquivoComBytes (Join-Path $raiz 'a.bin') 100
            New-ArquivoComBytes (Join-Path $externo 'grande.bin') 1048576
            & cmd.exe /c mklink /J $junc $externo | Out-Null
            Test-Path -LiteralPath (Join-Path $junc 'grande.bin') | Should Be $true
            $r = Get-TamanhoPasta $raiz ([Diagnostics.Stopwatch]::StartNew()) 60
            $r.Bytes | Should Be 100
            $r.Arquivos | Should Be 1
        } finally {
            if (Test-Path -LiteralPath $junc) { & cmd.exe /c rmdir $junc | Out-Null }
            Remove-Item -LiteralPath $raiz -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $externo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'com prazo 0 devolve Parcial verdadeiro sem varrer' {
        $raiz = New-PastaTemp
        try {
            New-ArquivoComBytes (Join-Path $raiz 'a.bin') 100
            $relogio = [Diagnostics.Stopwatch]::StartNew()
            Start-Sleep -Milliseconds 30
            $r = Get-TamanhoPasta $raiz $relogio 0
            $r.Parcial | Should Be $true
            $r.Arquivos | Should Be 0
        } finally { Remove-Item -LiteralPath $raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'com relógio já vencido devolve Parcial verdadeiro rapidamente' {
        $raiz = New-PastaTemp
        try {
            New-ArquivoComBytes (Join-Path $raiz 'a.bin') 100
            $relogio = [Diagnostics.Stopwatch]::StartNew()
            Start-Sleep -Milliseconds 1200
            $medida = [Diagnostics.Stopwatch]::StartNew()
            $r = Get-TamanhoPasta $raiz $relogio 1
            $medida.Stop()
            $r.Parcial | Should Be $true
            ($medida.Elapsed.TotalSeconds -lt 5) | Should Be $true
        } finally { Remove-Item -LiteralPath $raiz -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Format-AcessoEntrada' {
    It 'monta as quatro portas no formato esperado' {
        Format-AcessoEntrada -Portas ([string[]]('5985', '445')) | Should Be 'WinRM 5985: liberada | WMI/RPC 135: bloqueada | SMB 445: liberada | RDP 3389: bloqueada'
    }
    It 'sem nenhuma porta liberada tudo fica bloqueado' {
        Format-AcessoEntrada -Portas ([string[]]@()) | Should Be 'WinRM 5985: bloqueada | WMI/RPC 135: bloqueada | SMB 445: bloqueada | RDP 3389: bloqueada'
    }
    It 'regra Any libera todos os serviços' {
        Format-AcessoEntrada -Portas ([string[]]('Any')) | Should Be 'WinRM 5985: liberada | WMI/RPC 135: liberada | SMB 445: liberada | RDP 3389: liberada'
    }
    It 'RPC ou RPCEPMap libera o WMI/RPC' {
        Format-AcessoEntrada -Portas ([string[]]('RPCEPMap', '3389')) | Should Match 'WMI/RPC 135: liberada'
        Format-AcessoEntrada -Portas ([string[]]('RPCEPMap', '3389')) | Should Match 'RDP 3389: liberada'
    }
    It 'valor nulo vira N/D' {
        Format-AcessoEntrada -Portas $null | Should Be 'N/D'
    }
}

Describe 'Format-PoliticaSenha' {
    It 'monta a política com todos os dados' {
        $dados = @(
            [pscustomobject]@{ KeyName = 'MinimumPasswordLength'; Valor = 8 }
            [pscustomobject]@{ KeyName = 'PasswordComplexity'; Valor = 1 }
            [pscustomobject]@{ KeyName = 'MaximumPasswordAge'; Valor = 90 }
            [pscustomobject]@{ KeyName = 'PasswordHistorySize'; Valor = 24 }
            [pscustomobject]@{ KeyName = 'LockoutBadCount'; Valor = 5 }
        )
        Format-PoliticaSenha $dados | Should Be 'Mínimo 8 | Complexidade sim | Validade 90 d | Histórico 24 | Bloqueio após 5'
    }
    It 'complexidade zero ou falsa aparece como não' {
        Format-PoliticaSenha @([pscustomobject]@{ KeyName = 'PasswordComplexity'; Valor = 0 }) | Should Be 'Complexidade não'
        Format-PoliticaSenha @([pscustomobject]@{ KeyName = 'PasswordComplexity'; Valor = $false }) | Should Be 'Complexidade não'
    }
    It 'complexidade True aparece como sim' {
        Format-PoliticaSenha @([pscustomobject]@{ KeyName = 'PasswordComplexity'; Valor = $true }) | Should Be 'Complexidade sim'
    }
    It 'dados nulos devolvem a mensagem de sem política' {
        Format-PoliticaSenha $null | Should Be 'Sem política de senha por GPO'
    }
    It 'dados vazios devolvem a mensagem de sem política' {
        Format-PoliticaSenha @() | Should Be 'Sem política de senha por GPO'
    }
    It 'ignora chaves que não pertencem à política' {
        Format-PoliticaSenha @([pscustomobject]@{ KeyName = 'OutraCoisa'; Valor = 7 }) | Should Be 'Sem política de senha por GPO'
    }
}

Describe 'Format-BloqueioTela' {
    It 'política de inatividade da máquina em segundos vira minutos' {
        Format-BloqueioTela 900 $null $null $null $true | Should Be 'Por política da máquina: 15 min'
    }
    It 'arredonda a política da máquina para cima' {
        Format-BloqueioTela 61 $null $null $null $true | Should Be 'Por política da máquina: 2 min'
    }
    It 'a política da máquina vale mesmo sem usuário logado' {
        Format-BloqueioTela 600 $null $null $null $false | Should Be 'Por política da máquina: 10 min'
    }
    It 'sem política, proteção de tela com senha vale' {
        Format-BloqueioTela $null '1' '1' '600' $true | Should Be 'Proteção de tela com senha: 10 min'
    }
    It 'proteção de tela sem senha não conta' {
        Format-BloqueioTela $null '1' '0' '600' $true | Should Be 'Não configurado'
    }
    It 'proteção de tela inativa não conta' {
        Format-BloqueioTela $null '0' '1' '600' $true | Should Be 'Não configurado'
    }
    It 'nada configurado devolve Não configurado' {
        Format-BloqueioTela $null $null $null $null $true | Should Be 'Não configurado'
    }
    It 'sem usuário logado e sem política devolve Não avaliado' {
        Format-BloqueioTela $null $null $null $null $false | Should Be 'Não avaliado (ninguém logado)'
    }
}

Describe 'Get-ResumoEventos' {
    $eventos = @(
        [pscustomobject]@{ Origem = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Nivel = 2; Quantidade = 2; Ultimo = '01/11/2026 10:00'; Mensagem = 'BugCheck' }
        [pscustomobject]@{ Origem = 'Microsoft-Windows-Kernel-Power'; Id = 41; Nivel = 1; Quantidade = 3; Ultimo = '01/11/2026 09:00'; Mensagem = 'Reinício inesperado' }
        [pscustomobject]@{ Origem = 'EventLog'; Id = 6008; Nivel = 2; Quantidade = 1; Ultimo = '01/11/2026 09:00'; Mensagem = 'Desligamento inesperado' }
        [pscustomobject]@{ Origem = 'Disk'; Id = 7; Nivel = 2; Quantidade = 4; Ultimo = '02/11/2026 08:00'; Mensagem = 'Bloco inválido' }
        [pscustomobject]@{ Origem = 'Service Control Manager'; Id = 7000; Nivel = 3; Quantidade = 9; Ultimo = '02/11/2026 08:00'; Mensagem = 'Aviso' }
    )
    It 'conta telas azuis pelo evento 1001 de WER ou BugCheck' {
        (Get-ResumoEventos $eventos).TelasAzuis | Should Be 2
    }
    It 'conta desligamentos inesperados (Kernel-Power 41 e 6008) somando a quantidade' {
        (Get-ResumoEventos $eventos).Inesperados | Should Be 4
    }
    It 'conta críticos (nível 1)' {
        (Get-ResumoEventos $eventos).Criticos | Should Be 3
    }
    It 'conta erros (nível 2) e ignora avisos' {
        (Get-ResumoEventos $eventos).Erros | Should Be 7
    }
    It 'o evento 41 de outra origem não é desligamento inesperado' {
        $e = @([pscustomobject]@{ Origem = 'Outra'; Id = 41; Nivel = 4; Quantidade = 5; Ultimo = ''; Mensagem = '' })
        (Get-ResumoEventos $e).Inesperados | Should Be 0
    }
    It 'lista vazia dá zeros' {
        $r = Get-ResumoEventos @()
        $r.TelasAzuis | Should Be 0
        $r.Inesperados | Should Be 0
        $r.Criticos | Should Be 0
        $r.Erros | Should Be 0
    }
    It 'entrada nula também dá zeros' {
        $r = Get-ResumoEventos $null
        $r.TelasAzuis | Should Be 0
        $r.Erros | Should Be 0
    }
}

Describe 'Format-SaudeDiscos' {
    It 'todos saudáveis devolve Saudáveis' {
        $d = @(
            [pscustomobject]@{ Modelo = 'Disco A'; Saude = 'Healthy' }
            [pscustomobject]@{ Modelo = 'Disco B'; Saude = 'Saudável' }
        )
        Format-SaudeDiscos $d $false | Should Be 'Saudáveis'
    }
    It 'um disco com problema começa com ATENÇÃO e nomeia o disco' {
        $d = @(
            [pscustomobject]@{ Modelo = 'Disco A'; Saude = 'Healthy' }
            [pscustomobject]@{ Modelo = 'Disco B'; Saude = 'Unhealthy' }
        )
        $r = Format-SaudeDiscos $d $false
        $r | Should Match '^ATENÇÃO'
        $r | Should Match 'Disco B Unhealthy'
        $r | Should Not Match 'Disco A'
    }
    It 'previsão de falha com discos saudáveis começa com ATENÇÃO' {
        $d = @([pscustomobject]@{ Modelo = 'Disco A'; Saude = 'Healthy' })
        Format-SaudeDiscos $d $true | Should Be 'ATENÇÃO: SMART prevê falha'
    }
    It 'previsão de falha e disco com problema aparecem juntos' {
        $d = @([pscustomobject]@{ Modelo = 'Disco B'; Saude = 'Warning' })
        Format-SaudeDiscos $d $true | Should Be 'ATENÇÃO: SMART prevê falha; Disco B Warning'
    }
    It 'previsão de falha sem lista de discos ainda alerta' {
        Format-SaudeDiscos @() $true | Should Match '^ATENÇÃO'
    }
    It 'lista vazia devolve N/D' {
        Format-SaudeDiscos @() $false | Should Be 'N/D'
    }
    It 'entrada nula devolve N/D' {
        Format-SaudeDiscos $null $false | Should Be 'N/D'
    }
}

Describe 'ConvertTo-LinhaCertificado' {
    It 'tira o CPF do titular e identifica A3 pela política ICP-Brasil' -Skip:(-not $script:TemCertificateRequest) {
        $cert = New-CertificadoTeste 'CN=FULANO DE TAL:12345678901' $script:PoliticaA3
        $l = ConvertTo-LinhaCertificado $cert 'fulano' 'Usuário'
        $l.Titular | Should Be 'FULANO DE TAL'
        $l.Titular | Should Not Match '12345678901'
        $l.Tipo | Should Be 'A3'
        $l.Usuario | Should Be 'fulano'
        $l.Repositorio | Should Be 'Usuário'
    }
    It 'identifica A1 pela política 2.16.76.1.2.1' -Skip:(-not $script:TemCertificateRequest) {
        $cert = New-CertificadoTeste 'CN=BELTRANO:98765432100' $script:PoliticaA1
        $l = ConvertTo-LinhaCertificado $cert '' 'Computador'
        $l.Tipo | Should Be 'A1'
        $l.Titular | Should Be 'BELTRANO'
    }
    It 'calcula os dias restantes pela data de validade' -Skip:(-not $script:TemCertificateRequest) {
        $cert = New-CertificadoTeste 'CN=FULANO DE TAL:12345678901' $script:PoliticaA3 100
        $l = ConvertTo-LinhaCertificado $cert 'fulano' 'Usuário'
        ($l.DiasRestantes -ge 98 -and $l.DiasRestantes -le 100) | Should Be $true
        $l.ValidoAte | Should Match '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$'
    }
    It 'certificado vencido tem dias restantes negativos' -Skip:(-not $script:TemCertificateRequest) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest ('CN=VENCIDO:11122233344', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509Extension ('2.5.29.32', $script:PoliticaA3, $false)))
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-60), [DateTimeOffset]::UtcNow.AddDays(-10))
        $l = ConvertTo-LinhaCertificado $cert 'fulano' 'Usuário'
        ($l.DiasRestantes -lt 0) | Should Be $true
    }
    It 'emissor ICP-Brasil sem política devolve tipo Não identificado' -Skip:(-not $script:TemCertificateRequest) {
        $cert = New-CertificadoTeste 'CN=SEM POLITICA:12345678901, O=ICP-Brasil' $null
        $l = ConvertTo-LinhaCertificado $cert 'fulano' 'Usuário'
        $l.Tipo | Should Be 'Não identificado'
        $l.Titular | Should Not Match '12345678901'
    }
    It 'certificado que não é ICP-Brasil é descartado' -Skip:(-not $script:TemCertificateRequest) {
        $cert = New-CertificadoTeste 'CN=localhost' $null
        $l = ConvertTo-LinhaCertificado $cert 'fulano' 'Usuário'
        ($null -eq $l) | Should Be $true
    }
}

Describe 'ConvertTo-CanalLicenca' {
    It 'OEM' {
        ConvertTo-CanalLicenca 'OEM:NONSLP' | Should Be 'OEM'
    }
    It 'Volume com GVLK vira KMS' {
        ConvertTo-CanalLicenca 'Volume:GVLK' | Should Be 'Volume (KMS)'
    }
    It 'Volume com MAK' {
        ConvertTo-CanalLicenca 'Volume:MAK' | Should Be 'Volume (MAK)'
    }
    It 'Retail vira Varejo' {
        ConvertTo-CanalLicenca 'Retail' | Should Be 'Varejo'
    }
    It 'canal desconhecido volta como veio' {
        ConvertTo-CanalLicenca 'Canal Novo' | Should Be 'Canal Novo'
    }
    It 'canal nulo volta vazio' {
        ConvertTo-CanalLicenca $null | Should BeNullOrEmpty
    }
}

Describe 'ConvertTo-StatusLicenca' {
    It 'licenciado' {
        ConvertTo-StatusLicenca 1 | Should Be 'Licenciado'
    }
    It 'não licenciado' {
        ConvertTo-StatusLicenca 0 | Should Be 'Não licenciado'
    }
    It 'período de carência' {
        ConvertTo-StatusLicenca 2 | Should Be 'Em carência'
    }
    It 'carência de hardware não original' {
        ConvertTo-StatusLicenca 4 | Should Be 'Em carência (não original)'
    }
    It 'notificação' {
        ConvertTo-StatusLicenca 5 | Should Be 'Notificação'
    }
    It 'texto numérico também é entendido' {
        ConvertTo-StatusLicenca '1' | Should Be 'Licenciado'
    }
    It 'valor desconhecido ou nulo vira Não identificado' {
        ConvertTo-StatusLicenca 99 | Should Be 'Não identificado'
        ConvertTo-StatusLicenca $null | Should Be 'Não identificado'
    }
}
