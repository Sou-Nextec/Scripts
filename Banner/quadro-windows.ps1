# Nextec | Quadro informativo no papel de parede dos servidores Windows
# Lê NEXTEC_NOME_SERVIDOR, NEXTEC_FUNCAO e NEXTEC_AMBIENTE das variáveis da máquina.
# Roda a cada login pela tarefa agendada criada pelo aplicar-banner.ps1.
#
# Uso manual:
#   .\quadro-windows.ps1                                 # aplica no papel de parede do usuário atual
#   .\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png    # só gera a imagem, para conferir o resultado
#
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [string]$SalvarEm = ''
)

$ErrorActionPreference = 'Stop'
$PastaUsuario = Join-Path $env:LOCALAPPDATA 'Nextec'

try {
    # ---------- Variáveis do servidor ----------
    function Ler([string]$nome) {
        $valor = [Environment]::GetEnvironmentVariable($nome, 'Machine')
        if (-not $valor) { $valor = [Environment]::GetEnvironmentVariable($nome, 'Process') }
        if (-not $valor) { return '' }
        return ($valor -replace '[\x00-\x1F\x7F]', '').Trim()
    }

    $nome     = Ler 'NEXTEC_NOME_SERVIDOR'
    $funcao   = Ler 'NEXTEC_FUNCAO'
    $ambiente = Ler 'NEXTEC_AMBIENTE'
    $host_    = $env:COMPUTERNAME.ToUpper()
    $servidor = if ($nome) { "$($nome.ToUpper()) ($host_)" } else { $host_ }

    # ---------- Resumo do sistema (cada item falha sozinho, sem derrubar o quadro) ----------
    function Seguro([scriptblock]$bloco, $padrao = 'não identificado') {
        try { $resultado = & $bloco; if ($null -eq $resultado -or "$resultado" -eq '') { return $padrao }; return $resultado }
        catch { return $padrao }
    }

    $sistema  = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpus     = Seguro { (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum } 0
    $cpuUso   = Seguro { [math]::Round((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average) } 0
    $memTotal = $sistema.TotalVisibleMemorySize / 1MB
    $memUso   = (1 - ($sistema.FreePhysicalMemory / $sistema.TotalVisibleMemorySize)) * 100
    $memoria  = '{0:N0}% de {1:N1} GB' -f $memUso, $memTotal

    $paginacao = Seguro {
        $arquivos = @(Get-CimInstance Win32_PageFileUsage)
        $total = ($arquivos | Measure-Object AllocatedBaseSize -Sum).Sum
        $usado = ($arquivos | Measure-Object CurrentUsage -Sum).Sum
        if ($total -gt 0) { '{0:N0}% de {1:N1} GB' -f ($usado / $total * 100), ($total / 1024) } else { 'não configurada' }
    } 'não configurada'

    $disco = Seguro {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
        '{0:N0}% usado ({1:N0} GB de {2:N0} GB)' -f (($d.Size - $d.FreeSpace) / $d.Size * 100), (($d.Size - $d.FreeSpace) / 1GB), ($d.Size / 1GB)
    }

    $atividade = New-TimeSpan -Start $sistema.LastBootUpTime -End (Get-Date)
    $uptime = '{0}d {1}h {2}min' -f $atividade.Days, $atividade.Hours, $atividade.Minutes

    $processos = Seguro { (Get-Process).Count } 0
    $usuarios  = Seguro {
        $linhasQuser = @(cmd /c 'quser 2>nul')
        if ($linhasQuser.Count -gt 1) { $linhasQuser.Count - 1 } else { 0 }
    } 0

    $ip = Seguro {
        $config = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        @($config.IPv4Address)[0].IPAddress
    }

    # ---------- Quadro (mesmas informações do quadro Linux) ----------
    $rotulos = New-Object System.Collections.ArrayList
    function Campo([string]$rotulo, [string]$valor, [bool]$negrito = $false, $cor = $null) {
        [void]$rotulos.Add([pscustomobject]@{ Rotulo = $rotulo; Valor = $valor; Negrito = $negrito; Cor = $cor })
    }
    function Espaco { [void]$rotulos.Add($null) }

    # ---------- Desenho ----------
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('NextecWin32' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class NextecWin32 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    }
    [void][NextecWin32]::SetProcessDPIAware()

    $corRotulo = [System.Drawing.Color]::FromArgb(154, 150, 184)
    $corValor  = [System.Drawing.Color]::FromArgb(244, 244, 244)
    $corAmbiente = switch -Wildcard ($ambiente.ToLower()) {
        'produ*'   { [System.Drawing.Color]::FromArgb(239, 83, 80) }
        'homolog*' { [System.Drawing.Color]::FromArgb(255, 213, 79) }
        default    { [System.Drawing.Color]::FromArgb(102, 187, 106) }
    }

    Campo 'Servidor' $servidor $true
    if ($funcao)   { Campo 'Função' $funcao }
    if ($ambiente) { Campo 'Ambiente' $ambiente $true $corAmbiente }
    Espaco
    Campo 'Carga' ('{0}% de CPU ({1} CPUs)' -f $cpuUso, $cpus)
    Campo 'Disco' $disco
    Campo 'Memória' $memoria
    Campo 'Paginação' $paginacao
    Campo 'Uptime' $uptime
    Campo 'Processos' ('{0}  |  Usuários: {1}' -f $processos, $usuarios)
    Campo 'IP' $ip

    $tela = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $largura = if ($tela.Width -ge 800) { $tela.Width } else { 1920 }
    $altura  = if ($tela.Height -ge 600) { $tela.Height } else { 1080 }

    $px = [math]::Max(15, [math]::Round($altura / 62))
    $fonte      = New-Object System.Drawing.Font('Segoe UI', $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fonteBold  = New-Object System.Drawing.Font('Segoe UI', $px, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fontePeq   = New-Object System.Drawing.Font('Segoe UI', [math]::Round($px * 0.85), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fontePeqB  = New-Object System.Drawing.Font('Segoe UI', [math]::Round($px * 0.85), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $alturaLinha = [math]::Round($px * 1.7)
    $margem = [math]::Round($px * 2.4)

    $imagem = New-Object System.Drawing.Bitmap($largura, $altura)
    $g = [System.Drawing.Graphics]::FromImage($imagem)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $formato = [System.Drawing.StringFormat]::GenericTypographic.Clone()
    $formato.FormatFlags = $formato.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

    function Largura([string]$texto, $f) { $g.MeasureString($texto, $f, 10000, $formato).Width }
    function Escrever([string]$texto, $f, $cor, [single]$x, [single]$y) {
        $pincel = New-Object System.Drawing.SolidBrush($cor)
        $g.DrawString($texto, $f, $pincel, $x, $y, $formato)
        $pincel.Dispose()
    }

    # Fundo em degradê (azul acinzentado escuro)
    $fundo = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, $altura)),
        [System.Drawing.Color]::FromArgb(14, 26, 48), [System.Drawing.Color]::FromArgb(21, 35, 66))
    $g.FillRectangle($fundo, 0, 0, $largura, $altura)
    $fundo.Dispose()

    # Medidas do bloco
    $larguraRotulo = ($rotulos | Where-Object { $_ } | ForEach-Object { Largura $_.Rotulo $fonte } | Measure-Object -Maximum).Maximum + ($px * 2)
    $larguraValor  = ($rotulos | Where-Object { $_ } | ForEach-Object { Largura $_.Valor $(if ($_.Negrito) { $fonteBold } else { $fonte }) } | Measure-Object -Maximum).Maximum
    $textoAviso    = 'Alterações neste servidor devem ser combinadas com a Nextec.'
    $segmentos = @(
        @('Gerenciado pela ', $corRotulo, $false), @('Nextec', $corValor, $true),
        @('   (62) 3602-1667 ', $corValor, $false), @('· ', $corRotulo, $false), @('noc@nex.tec.br', $corValor, $false)
    )
    $larguraContato = 0
    foreach ($s in $segmentos) { $larguraContato += Largura $s[0] $(if ($s[2]) { $fontePeqB } else { $fontePeq }) }
    $larguraAviso = Largura $textoAviso $fontePeq
    $larguraBloco = [math]::Max($larguraRotulo + $larguraValor, [math]::Max($larguraAviso, $larguraContato))
    $x0 = $largura - $margem - $larguraBloco
    $y  = $margem

    foreach ($linha in $rotulos) {
        if ($null -eq $linha) { $y += [math]::Round($alturaLinha * 0.6); continue }
        $corLinha = if ($linha.Cor) { $linha.Cor } else { $corValor }
        Escrever $linha.Rotulo $fonte $corRotulo $x0 $y
        Escrever $linha.Valor $(if ($linha.Negrito) { $fonteBold } else { $fonte }) $corLinha ($x0 + $larguraRotulo) $y
        $y += $alturaLinha
    }

    $y += [math]::Round($alturaLinha * 0.5)
    Escrever $textoAviso $fontePeq $corRotulo ($x0 + $larguraBloco - $larguraAviso) $y
    $y += [math]::Round($alturaLinha * 1.1)
    $x = $x0 + $larguraBloco - $larguraContato
    foreach ($s in $segmentos) {
        $f = if ($s[2]) { $fontePeqB } else { $fontePeq }
        Escrever $s[0] $f $s[1] $x $y
        $x += Largura $s[0] $f
    }
    $g.Dispose()

    # ---------- Salva e aplica ----------
    if ($SalvarEm) {
        $imagem.Save($SalvarEm, [System.Drawing.Imaging.ImageFormat]::Png)
        $imagem.Dispose()
        Write-Host "Imagem gerada em $SalvarEm"
        return
    }

    New-Item -ItemType Directory -Path $PastaUsuario -Force | Out-Null
    $arquivo = Join-Path $PastaUsuario 'quadro.bmp'
    $imagem.Save($arquivo, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $imagem.Dispose()

    $chave = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $chave -Name 'WallpaperStyle' -Value '10'
    Set-ItemProperty -Path $chave -Name 'TileWallpaper' -Value '0'
    # 20 = SPI_SETDESKWALLPAPER; 3 = grava no perfil e avisa as janelas
    if ([NextecWin32]::SystemParametersInfo(20, 0, $arquivo, 3) -eq 0) {
        throw 'o Windows recusou o papel de parede (uma GPO pode estar bloqueando a troca).'
    }
} catch {
    New-Item -ItemType Directory -Path $PastaUsuario -Force -ErrorAction SilentlyContinue | Out-Null
    $registro = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $_.Exception.Message
    Add-Content -LiteralPath (Join-Path $PastaUsuario 'quadro.log') -Value $registro -ErrorAction SilentlyContinue
    throw
}
