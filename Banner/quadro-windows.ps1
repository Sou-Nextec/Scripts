# Nextec | Quadro informativo sobre o papel de parede dos servidores Windows
# Lê NEXTEC_NOME_SERVIDOR, NEXTEC_FUNCAO e NEXTEC_AMBIENTE das variáveis da máquina.
# Roda a cada login pela tarefa agendada criada pelo aplicar-banner.ps1.
#
# O papel de parede de cada usuário é preservado: o quadro é desenhado por cima dele.
# Na primeira execução o papel de parede original é copiado para %LOCALAPPDATA%\Nextec; se o usuário
# trocar o papel de parede depois, o novo passa a ser o original no próximo login.
#
# Uso manual:
#   .\quadro-windows.ps1                                 # aplica sobre o papel de parede do usuário atual
#   .\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png    # só gera a imagem, para conferir o resultado
#   .\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png -Fundo C:\Windows\Web\Wallpaper\Windows\img0.jpg
#
# A variável de máquina NEXTEC_PAPEL_DE_PAREDE escolhe o fundo: Manter (padrão) desenha o quadro sobre o
# papel de parede do usuário; Azul troca o papel de parede pelo azul Nextec liso (0D0035); Preto troca por
# preto liso. Remover é o nome antigo de Azul e continua valendo.
# O parâmetro -PapelDeParede tem o mesmo efeito e vale mais que a variável (útil para conferir o resultado).
#
# O painel atrás do texto tem opacidade 215 (de 255) por padrão, para dar contraste sobre qualquer papel de
# parede. A variável de máquina NEXTEC_OPACIDADE ou o parâmetro -Opacidade (0 a 255) ajustam esse valor.
#
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [string]$SalvarEm = '',
    [string]$Fundo = '',     # Só com -SalvarEm: imagem usada como papel de parede, para conferir o resultado
    [ValidateSet('', 'Manter', 'Azul', 'Preto', 'Remover')]
    [string]$PapelDeParede = '',
    [ValidateRange(0, 255)]
    [int]$Opacidade = -1     # Opacidade do painel (0 a 255); sem valor usa NEXTEC_OPACIDADE ou 215
)

$ErrorActionPreference = 'Stop'
$PastaUsuario = Join-Path $env:LOCALAPPDATA 'Nextec'
$ArquivoQuadro = Join-Path $PastaUsuario 'quadro.bmp'
$ArquivoEstado = Join-Path $PastaUsuario 'fundo-original.json'

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

    $corRotulo = [System.Drawing.Color]::FromArgb(205, 210, 232)
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

    # ---------- Papel de parede do usuário (o quadro vai por cima dele) ----------
    $chaveDesktop = 'HKCU:\Control Panel\Desktop'

    function LerFundoAtual {
        $d = Get-ItemProperty -Path $chaveDesktop -ErrorAction SilentlyContinue
        $c = Get-ItemProperty -Path 'HKCU:\Control Panel\Colors' -ErrorAction SilentlyContinue
        [pscustomobject]@{ Caminho = "$($d.Wallpaper)"; Estilo = "$($d.WallpaperStyle)"; Tile = "$($d.TileWallpaper)"; Cor = "$($c.Background)" }
    }

    # Quando o papel de parede atual é o próprio quadro e o original se perdeu, procura no histórico do Windows
    function BuscarNoHistorico {
        $historico = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -ErrorAction SilentlyContinue
        foreach ($i in 0..4) {
            $caminho = "$($historico."BackgroundHistoryPath$i")"
            if ($caminho -and ($caminho -ine $ArquivoQuadro) -and (Test-Path -LiteralPath $caminho)) { return $caminho }
        }
        return ''
    }

    $fundoAtual = LerFundoAtual
    $atualEhQuadro = [bool]($fundoAtual.Caminho -and ($fundoAtual.Caminho -ieq $ArquivoQuadro))
    $fundoOriginal = $fundoAtual
    if ($Fundo) {
        $fundoOriginal = [pscustomobject]@{ Caminho = $Fundo; Estilo = '10'; Tile = '0'; Cor = $fundoAtual.Cor }
    } elseif ($atualEhQuadro -and (Test-Path -LiteralPath $ArquivoEstado)) {
        $fundoOriginal = Get-Content -LiteralPath $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        if ($atualEhQuadro) { $fundoOriginal.Caminho = BuscarNoHistorico; $fundoOriginal.Estilo = '10'; $fundoOriginal.Tile = '0' }
        if (-not $SalvarEm) {
            if ($fundoOriginal.Caminho -and (Test-Path -LiteralPath $fundoOriginal.Caminho)) {
                New-Item -ItemType Directory -Path $PastaUsuario -Force | Out-Null
                $copia = Join-Path $PastaUsuario ('fundo-original' + [IO.Path]::GetExtension($fundoOriginal.Caminho))
                if ($fundoOriginal.Caminho -ine $copia) { Copy-Item -LiteralPath $fundoOriginal.Caminho -Destination $copia -Force }
                $fundoOriginal.Caminho = $copia
            }
            $fundoOriginal | ConvertTo-Json | Set-Content -LiteralPath $ArquivoEstado -Encoding UTF8
        }
    }

    function CorSolida([string]$texto) {
        $partes = @($texto -split '\s+' | Where-Object { $_ })
        if ($partes.Count -ne 3) { return $null }
        try { return [System.Drawing.Color]::FromArgb([math]::Min(255, [int]$partes[0]), [math]::Min(255, [int]$partes[1]), [math]::Min(255, [int]$partes[2])) }
        catch { return $null }
    }

    $tela = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $largura = if ($tela.Width -ge 800) { $tela.Width } else { 1920 }
    $altura  = if ($tela.Height -ge 600) { $tela.Height } else { 1080 }

    $px = [math]::Max(15, [math]::Round($altura / 62))
    $fonte      = New-Object System.Drawing.Font('Segoe UI', $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fonteBold  = New-Object System.Drawing.Font('Segoe UI', $px, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fontePeq   = New-Object System.Drawing.Font('Segoe UI', [math]::Round($px * 0.92), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fontePeqB  = New-Object System.Drawing.Font('Segoe UI', [math]::Round($px * 0.92), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
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

    # Fundo: o papel de parede do usuário (Manter); sem imagem, a cor sólida dele; sem nada disso, degradê azul acinzentado escuro; com Azul ou Preto, a cor lisa escolhida
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $escolhaFundo = if ($PapelDeParede) { $PapelDeParede } else { Ler 'NEXTEC_PAPEL_DE_PAREDE' }
    $corForcada = switch -Wildcard ($escolhaFundo.ToLower()) {
        'azul*'    { [System.Drawing.Color]::FromArgb(13, 0, 53) }
        'remov*'   { [System.Drawing.Color]::FromArgb(13, 0, 53) }
        'preto*'   { [System.Drawing.Color]::FromArgb(0, 0, 0) }
        default    { $null }
    }
    $removerFundo = [bool]$corForcada
    $imagemFundo = $null
    if (-not $removerFundo -and $fundoOriginal.Caminho -and (Test-Path -LiteralPath $fundoOriginal.Caminho)) {
        try { $imagemFundo = [System.Drawing.Image]::FromFile($fundoOriginal.Caminho) } catch { $imagemFundo = $null }
    }
    $corSolida = if ($removerFundo) { $corForcada } else { CorSolida $fundoOriginal.Cor }
    if ($corSolida) { $g.Clear($corSolida) }

    if ($imagemFundo) {
        $iw = [single]$imagemFundo.Width
        $ih = [single]$imagemFundo.Height
        if ($fundoOriginal.Tile -eq '1') {
            $pincelFundo = New-Object System.Drawing.TextureBrush($imagemFundo)
            $g.FillRectangle($pincelFundo, 0, 0, $largura, $altura)
            $pincelFundo.Dispose()
        } else {
            switch ($fundoOriginal.Estilo) {
                '0'     { $esc = 1 }                                                  # centralizado
                '2'     { $esc = 0 }                                                  # esticado
                '6'     { $esc = [math]::Min($largura / $iw, $altura / $ih) }         # ajustado
                default { $esc = [math]::Max($largura / $iw, $altura / $ih) }         # preenchido ou estendido
            }
            if ($esc -eq 0) { $dw = [single]$largura; $dh = [single]$altura } else { $dw = [single]($iw * $esc); $dh = [single]($ih * $esc) }
            $g.DrawImage($imagemFundo, [single](($largura - $dw) / 2), [single](($altura - $dh) / 2), $dw, $dh)
        }
        $imagemFundo.Dispose()
    } elseif (-not $corSolida) {
        $degrade = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, $altura)),
            [System.Drawing.Color]::FromArgb(14, 26, 48), [System.Drawing.Color]::FromArgb(21, 35, 66))
        $g.FillRectangle($degrade, 0, 0, $largura, $altura)
        $degrade.Dispose()
    }

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

    # Painel translúcido atrás do quadro, para o texto continuar legível sobre qualquer papel de parede
    $alturaBloco = [math]::Round($alturaLinha * 1.6) + $px
    foreach ($linha in $rotulos) { $alturaBloco += $(if ($null -eq $linha) { [math]::Round($alturaLinha * 0.6) } else { $alturaLinha }) }
    $folga = [math]::Round($px * 1.1)
    $raio  = [math]::Round($px * 0.7)
    $px0 = $x0 - $folga; $py0 = $y - $folga; $pw = $larguraBloco + 2 * $folga; $ph = $alturaBloco + 2 * $folga
    $caminhoPainel = New-Object System.Drawing.Drawing2D.GraphicsPath
    $caminhoPainel.AddArc($px0, $py0, 2 * $raio, 2 * $raio, 180, 90)
    $caminhoPainel.AddArc($px0 + $pw - 2 * $raio, $py0, 2 * $raio, 2 * $raio, 270, 90)
    $caminhoPainel.AddArc($px0 + $pw - 2 * $raio, $py0 + $ph - 2 * $raio, 2 * $raio, 2 * $raio, 0, 90)
    $caminhoPainel.AddArc($px0, $py0 + $ph - 2 * $raio, 2 * $raio, 2 * $raio, 90, 90)
    $caminhoPainel.CloseFigure()
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $opacidadePainel = $Opacidade
    if ($opacidadePainel -lt 0) {
        $lida = 0
        $opacidadePainel = if ([int]::TryParse((Ler 'NEXTEC_OPACIDADE'), [ref]$lida) -and $lida -ge 0 -and $lida -le 255) { $lida } else { 215 }
    }
    $pincelPainel = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($opacidadePainel, 8, 14, 30))
    $g.FillPath($pincelPainel, $caminhoPainel)
    $pincelPainel.Dispose()
    $canetaBorda = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 255, 255, 255), 1)
    $g.DrawPath($canetaBorda, $caminhoPainel)
    $canetaBorda.Dispose()
    $caminhoPainel.Dispose()

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
    $imagem.Save($ArquivoQuadro, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $imagem.Dispose()

    Set-ItemProperty -Path $chaveDesktop -Name 'WallpaperStyle' -Value '10'
    Set-ItemProperty -Path $chaveDesktop -Name 'TileWallpaper' -Value '0'
    # 20 = SPI_SETDESKWALLPAPER; 3 = grava no perfil e avisa as janelas
    if ([NextecWin32]::SystemParametersInfo(20, 0, $ArquivoQuadro, 3) -eq 0) {
        throw 'o Windows recusou o papel de parede (uma GPO pode estar bloqueando a troca).'
    }
} catch {
    New-Item -ItemType Directory -Path $PastaUsuario -Force -ErrorAction SilentlyContinue | Out-Null
    $registro = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $_.Exception.Message
    Add-Content -LiteralPath (Join-Path $PastaUsuario 'quadro.log') -Value $registro -ErrorAction SilentlyContinue
    throw
}
