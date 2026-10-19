# Nextec | Painel informativo dinâmico sobre a área de trabalho dos servidores Windows
# Lê NEXTEC_NOME_SERVIDOR, NEXTEC_FUNCAO e NEXTEC_AMBIENTE das variáveis da máquina.
# Roda a cada login pela tarefa agendada criada pelo aplicar-banner.ps1 e fica aberto durante toda a sessão.
#
# O painel é uma janela sem borda, ancorada na área de trabalho (atrás das janelas e dos ícones), no canto superior
# direito. Não pega clique, não rouba o foco e não aparece na barra de tarefas. Cada sessão (console ou RDP) tem o
# seu próprio painel. As métricas são atualizadas a cada 10 segundos. Nenhuma imagem é gerada e o papel de parede
# (inclusive o da GPO) não é alterado.
#
# Uso manual:
#   .\quadro-windows.ps1                                 # abre o painel na sessão atual (fica rodando)
#   .\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png    # só gera a imagem, para conferir o resultado
#   .\quadro-windows.ps1 -SalvarEm C:\Temp\quadro.png -Fundo C:\Windows\Web\Wallpaper\Windows\img0.jpg
#
# A variável de máquina NEXTEC_PAPEL_DE_PAREDE escolhe o fundo: Manter (padrão) não mexe no papel de parede;
# Preto troca o papel de parede do usuário por preto liso. Remover é o nome antigo de Preto e continua valendo.
# O parâmetro -PapelDeParede tem o mesmo efeito e vale mais que a variável.
#
# Este arquivo deve ficar salvo em UTF-8 com BOM, para o Windows PowerShell 5.1 ler os acentos.
[CmdletBinding()]
param(
    [string]$SalvarEm = '',
    [string]$Fundo = '',     # Só com -SalvarEm: imagem usada como papel de parede, para conferir o resultado
    [string]$PapelDeParede = ''
)

$ErrorActionPreference = 'Stop'
$PastaUsuario  = Join-Path $env:LOCALAPPDATA 'Nextec'
$ArquivoQuadro = Join-Path $PastaUsuario 'quadro.bmp'            # versão antiga, que gerava o papel de parede
$ArquivoEstado = Join-Path $PastaUsuario 'fundo-original.json'   # versão antiga, guardava o papel de parede original
$IntervaloMs   = 10000

function Registrar([string]$mensagem) {
    try {
        New-Item -ItemType Directory -Path $PastaUsuario -Force -ErrorAction SilentlyContinue | Out-Null
        $registro = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $mensagem
        Add-Content -LiteralPath (Join-Path $PastaUsuario 'quadro.log') -Value $registro -ErrorAction SilentlyContinue
    } catch { }
}

try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    # ---------- Janela e funções do Windows ----------
    if (-not ('NextecPainel' -as [type])) {
        $codigo = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

public class NextecLinha
{
    public string Rotulo = "";
    public string Valor = "";
    public bool Negrito;
    public bool TemCor;
    public Color Cor;
    public bool Espaco;
}

public static class NextecWin32
{
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    [DllImport("user32.dll")] public static extern bool SetSysColors(int n, int[] elementos, int[] cores);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string classe, string titulo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr pai, IntPtr apos, string classe, string titulo);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, IntPtr l, uint flags, uint tempo, out UIntPtr resultado);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr filho, IntPtr pai);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int indice);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int indice, int valor);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr depoisDe, int x, int y, int cx, int cy, uint flags);

    public static bool ShellPronto()
    {
        return FindWindow("Progman", null) != IntPtr.Zero;
    }

    // Janela da área de trabalho que serve de pai do painel: o WorkerW que fica atrás dos ícones (padrão do
    // Windows 8 em diante), o WorkerW filho do Progman (builds mais novos) ou o próprio Progman.
    // Sem Progman (Explorer fora do ar) devolve zero.
    public static IntPtr AcharPai()
    {
        IntPtr progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return IntPtr.Zero;
        IntPtr pai = ProcurarWorkerW(progman);
        if (pai == IntPtr.Zero)
        {
            UIntPtr resultado;
            // 0x052C pede ao Progman que crie o WorkerW atrás dos ícones
            SendMessageTimeout(progman, 0x052C, UIntPtr.Zero, IntPtr.Zero, 0, 1000, out resultado);
            pai = ProcurarWorkerW(progman);
        }
        return pai == IntPtr.Zero ? progman : pai;
    }

    static IntPtr ProcurarWorkerW(IntPtr progman)
    {
        IntPtr achado = IntPtr.Zero;
        EnumWindows(delegate(IntPtr topo, IntPtr l)
        {
            if (FindWindowEx(topo, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                achado = FindWindowEx(IntPtr.Zero, topo, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        if (achado == IntPtr.Zero) achado = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        return achado;
    }

    // Ancora a janela na área de trabalho e a posiciona (x e y em coordenadas de tela). Sem pai, a janela fica como
    // janela comum no fundo da pilha, atrás das demais. Devolve o pai usado.
    public static IntPtr Fixar(IntPtr janela, int x, int y, int largura, int altura)
    {
        const uint SEM_ATIVAR = 0x10, MUDOU_MOLDURA = 0x20, MOSTRAR = 0x40;
        IntPtr fundo = new IntPtr(1);   // HWND_BOTTOM
        IntPtr pai = AcharPai();
        if (pai == IntPtr.Zero)
        {
            SetWindowPos(janela, fundo, x, y, largura, altura, SEM_ATIVAR | MOSTRAR);
            return IntPtr.Zero;
        }
        SetParent(janela, pai);
        int estilo = GetWindowLong(janela, -16);                 // GWL_STYLE
        estilo = (estilo & ~unchecked((int)0x80000000)) | 0x40000000 | 0x10000000;   // sem POPUP, com CHILD e VISIBLE
        SetWindowLong(janela, -16, estilo);
        RECT r;
        GetWindowRect(pai, out r);
        SetWindowPos(janela, fundo, x - r.Left, y - r.Top, largura, altura, SEM_ATIVAR | MUDOU_MOLDURA | MOSTRAR);
        return pai;
    }
}

public class NextecPainel : Form
{
    public List<NextecLinha> Linhas = new List<NextecLinha>();
    public IntPtr Pai = IntPtr.Zero;
    public int Margem, Folga, Raio, Px, AlturaLinha;

    static readonly Color CorRotulo = Color.FromArgb(205, 210, 232);
    static readonly Color CorValor = Color.FromArgb(244, 244, 244);
    static readonly Color CorPainel = Color.FromArgb(8, 14, 30);
    const string TextoAviso = "Alterações neste servidor devem ser combinadas com a Nextec.";
    static readonly string[] SegTexto = { "Gerenciado pela ", "Nextec", "   (62) 3602-1667 ", "· ", "noc@nex.tec.br" };
    static readonly Color[] SegCor = { CorRotulo, CorValor, CorValor, CorRotulo, CorValor };
    static readonly bool[] SegNegrito = { false, true, false, false, false };

    Font fonte, fonteBold, fontePeq, fontePeqB;
    StringFormat formato;
    float larguraRotulo, larguraValor, larguraAviso, larguraContato, larguraBloco;
    int larguraTotal, alturaTotal;
    bool eventoAtivo;

    public NextecPainel()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = CorPainel;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        formato = (StringFormat)StringFormat.GenericTypographic.Clone();
        formato.FormatFlags = formato.FormatFlags | StringFormatFlags.MeasureTrailingSpaces;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x80 | 0x08000000;   // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x84) { m.Result = new IntPtr(-1); return; }   // WM_NCHITTEST: HTTRANSPARENT, o clique passa
        if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; }    // WM_MOUSEACTIVATE: MA_NOACTIVATE
        base.WndProc(ref m);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        SystemEvents.DisplaySettingsChanged += TelaMudou;
        eventoAtivo = true;
    }

    // Se a janela é destruída por fora (Explorer reiniciado leva o pai junto), encerra o laço de mensagens
    // para o script recriar o painel
    protected override void OnHandleDestroyed(EventArgs e)
    {
        if (eventoAtivo) { SystemEvents.DisplaySettingsChanged -= TelaMudou; eventoAtivo = false; }
        base.OnHandleDestroyed(e);
        Application.ExitThread();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Aplicar();
    }

    void TelaMudou(object remetente, EventArgs e)
    {
        try { if (IsHandleCreated) BeginInvoke(new MethodInvoker(Aplicar)); } catch { }
    }

    float Larg(Graphics g, string texto, Font f)
    {
        return g.MeasureString(texto, f, 10000, formato).Width;
    }

    void Medir(Graphics g)
    {
        Rectangle tela = Screen.PrimaryScreen.Bounds;
        int altura = tela.Height >= 600 ? tela.Height : 1080;
        int px = Math.Max(15, (int)Math.Round(altura / 62.0));
        if (fonte == null || px != Px)
        {
            DescartarFontes();
            Px = px;
            fonte = new Font("Segoe UI", px, FontStyle.Regular, GraphicsUnit.Pixel);
            fonteBold = new Font("Segoe UI", px, FontStyle.Bold, GraphicsUnit.Pixel);
            fontePeq = new Font("Segoe UI", (float)Math.Round(px * 0.92), FontStyle.Regular, GraphicsUnit.Pixel);
            fontePeqB = new Font("Segoe UI", (float)Math.Round(px * 0.92), FontStyle.Bold, GraphicsUnit.Pixel);
        }
        AlturaLinha = (int)Math.Round(px * 1.7);
        Margem = (int)Math.Round(px * 2.4);
        Folga = (int)Math.Round(px * 1.1);
        Raio = (int)Math.Round(px * 0.7);

        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        larguraRotulo = 0; larguraValor = 0;
        int alturaBloco = (int)Math.Round(AlturaLinha * 1.6) + px;
        foreach (NextecLinha l in Linhas)
        {
            if (l.Espaco) { alturaBloco += (int)Math.Round(AlturaLinha * 0.6); continue; }
            larguraRotulo = Math.Max(larguraRotulo, Larg(g, l.Rotulo, fonte));
            larguraValor = Math.Max(larguraValor, Larg(g, l.Valor, l.Negrito ? fonteBold : fonte));
            alturaBloco += AlturaLinha;
        }
        larguraRotulo += Px * 2;
        larguraAviso = Larg(g, TextoAviso, fontePeq);
        larguraContato = 0;
        for (int i = 0; i < SegTexto.Length; i++) larguraContato += Larg(g, SegTexto[i], SegNegrito[i] ? fontePeqB : fontePeq);
        larguraBloco = Math.Max(larguraRotulo + larguraValor, Math.Max(larguraAviso, larguraContato));
        larguraTotal = (int)Math.Ceiling(larguraBloco) + 2 * Folga;
        alturaTotal = alturaBloco + 2 * Folga;
    }

    static GraphicsPath Arredondado(float x, float y, float w, float h, float r)
    {
        GraphicsPath p = new GraphicsPath();
        float d = 2 * r;
        p.AddArc(x, y, d, d, 180, 90);
        p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    // Recalcula o tamanho e o canto superior direito da tela principal e, com a janela criada, ancora na área de trabalho
    public void Aplicar()
    {
        using (Bitmap b = new Bitmap(1, 1))
        using (Graphics g = Graphics.FromImage(b)) Medir(g);
        Rectangle tela = Screen.PrimaryScreen.Bounds;
        int x = tela.Right - Margem + Folga - larguraTotal;
        int y = tela.Top + Margem - Folga;
        if (!IsHandleCreated) SetBounds(x, y, larguraTotal, alturaTotal);   // com a janela criada, quem posiciona é o Fixar
        using (GraphicsPath caminho = Arredondado(0, 0, larguraTotal, alturaTotal, Raio))
        {
            Region = new Region(caminho);
        }
        if (IsHandleCreated) Pai = NextecWin32.Fixar(Handle, x, y, larguraTotal, alturaTotal);
        Invalidate();
    }

    void Desenhar(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using (GraphicsPath caminho = Arredondado(0.5f, 0.5f, larguraTotal - 1, alturaTotal - 1, Raio))
        using (SolidBrush fundo = new SolidBrush(CorPainel))
        using (Pen borda = new Pen(Color.FromArgb(90, 255, 255, 255), 1))
        {
            g.FillPath(fundo, caminho);
            g.DrawPath(borda, caminho);
        }
        float x0 = Folga;
        float y = Folga;
        foreach (NextecLinha l in Linhas)
        {
            if (l.Espaco) { y += (float)Math.Round(AlturaLinha * 0.6); continue; }
            Color cor = l.TemCor ? l.Cor : CorValor;
            using (SolidBrush p1 = new SolidBrush(CorRotulo)) g.DrawString(l.Rotulo, fonte, p1, x0, y, formato);
            using (SolidBrush p2 = new SolidBrush(cor)) g.DrawString(l.Valor, l.Negrito ? fonteBold : fonte, p2, x0 + larguraRotulo, y, formato);
            y += AlturaLinha;
        }
        y += (float)Math.Round(AlturaLinha * 0.5);
        using (SolidBrush p3 = new SolidBrush(CorRotulo)) g.DrawString(TextoAviso, fontePeq, p3, x0 + larguraBloco - larguraAviso, y, formato);
        y += (float)Math.Round(AlturaLinha * 1.1);
        float x = x0 + larguraBloco - larguraContato;
        for (int i = 0; i < SegTexto.Length; i++)
        {
            Font f = SegNegrito[i] ? fontePeqB : fontePeq;
            using (SolidBrush p4 = new SolidBrush(SegCor[i])) g.DrawString(SegTexto[i], f, p4, x, y, formato);
            x += Larg(g, SegTexto[i], f);
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Desenhar(e.Graphics);
    }

    // Imagem do painel (para conferir o visual sem abrir a janela); chame Aplicar antes
    public Bitmap Renderizar()
    {
        Bitmap b = new Bitmap(larguraTotal, alturaTotal);
        using (Graphics g = Graphics.FromImage(b)) Desenhar(g);
        return b;
    }

    void DescartarFontes()
    {
        if (fonte != null) { fonte.Dispose(); fonteBold.Dispose(); fontePeq.Dispose(); fontePeqB.Dispose(); fonte = null; }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { DescartarFontes(); formato.Dispose(); }
        base.Dispose(disposing);
    }
}
'@
        Add-Type -TypeDefinition $codigo -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -Language CSharp
    }
    [void][NextecWin32]::SetProcessDPIAware()

    # ---------- Variáveis do servidor ----------
    function Ler([string]$nome) {
        $valor = [Environment]::GetEnvironmentVariable($nome, 'Machine')
        if (-not $valor) { $valor = [Environment]::GetEnvironmentVariable($nome, 'Process') }
        if (-not $valor) { return '' }
        return ($valor -replace '[\x00-\x1F\x7F]', '').Trim()
    }

    # Cada item falha sozinho, sem derrubar o painel
    function Seguro([scriptblock]$bloco, $padrao = 'não identificado') {
        try { $resultado = & $bloco; if ($null -eq $resultado -or "$resultado" -eq '') { return $padrao }; return $resultado }
        catch { return $padrao }
    }

    function NovaLinha([string]$rotulo, [string]$valor, [bool]$negrito = $false, $cor = $null) {
        $l = New-Object NextecLinha
        $l.Rotulo = $rotulo
        $l.Valor = $valor
        $l.Negrito = $negrito
        if ($null -ne $cor) { $l.TemCor = $true; $l.Cor = $cor }
        return $l
    }

    # ---------- Métricas (mesmas informações do quadro Linux) ----------
    function Coletar {
        $nome     = Ler 'NEXTEC_NOME_SERVIDOR'
        $funcao   = Ler 'NEXTEC_FUNCAO'
        $ambiente = Ler 'NEXTEC_AMBIENTE'
        $host_    = $env:COMPUTERNAME.ToUpper()
        $servidor = if ($nome) { "$($nome.ToUpper()) ($host_)" } else { $host_ }

        $corAmbiente = switch -Wildcard ($ambiente.ToLower()) {
            'produ*'   { [System.Drawing.Color]::FromArgb(239, 83, 80) }
            'homolog*' { [System.Drawing.Color]::FromArgb(255, 213, 79) }
            default    { [System.Drawing.Color]::FromArgb(102, 187, 106) }
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

        $linhas = New-Object 'System.Collections.Generic.List[NextecLinha]'
        $linhas.Add((NovaLinha 'Servidor' $servidor $true))
        if ($funcao)   { $linhas.Add((NovaLinha 'Função' $funcao)) }
        if ($ambiente) { $linhas.Add((NovaLinha 'Ambiente' $ambiente $true $corAmbiente)) }
        $espaco = New-Object NextecLinha
        $espaco.Espaco = $true
        $linhas.Add($espaco)
        $linhas.Add((NovaLinha 'Carga' ('{0}% de CPU ({1} CPUs)' -f $cpuUso, $cpus)))
        $linhas.Add((NovaLinha 'Disco' $disco))
        $linhas.Add((NovaLinha 'Memória' $memoria))
        $linhas.Add((NovaLinha 'Paginação' $paginacao))
        $linhas.Add((NovaLinha 'Uptime' $uptime))
        $linhas.Add((NovaLinha 'Processos' ('{0}  |  Usuários: {1}' -f $processos, $usuarios)))
        $linhas.Add((NovaLinha 'IP' $ip))
        return ,$linhas
    }

    # ---------- Só gerar a imagem (conferência visual) ----------
    if ($SalvarEm) {
        $p = New-Object NextecPainel
        $p.Linhas = Coletar
        $p.Aplicar()
        $imgPainel = $p.Renderizar()
        $tela = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $w = if ($tela.Width -ge 800) { $tela.Width } else { 1920 }
        $h = if ($tela.Height -ge 600) { $tela.Height } else { 1080 }
        $imagem = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($imagem)
        $g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0))
        if ($Fundo -and (Test-Path -LiteralPath $Fundo)) {
            $fundoImg = [System.Drawing.Image]::FromFile($Fundo)
            $g.DrawImage($fundoImg, 0, 0, $w, $h)
            $fundoImg.Dispose()
        }
        $g.DrawImage($imgPainel, ($w - $p.Margem + $p.Folga - $imgPainel.Width), ($p.Margem - $p.Folga))
        $g.Dispose()
        $imagem.Save($SalvarEm, [System.Drawing.Imaging.ImageFormat]::Png)
        $imagem.Dispose(); $imgPainel.Dispose(); $p.Dispose()
        Write-Host "Imagem gerada em $SalvarEm"
        return
    }

    # ---------- Uma instância por sessão (o prefixo Local\ isola cada sessão, inclusive RDP) ----------
    $criado = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\NextecBannerPainel', [ref]$criado)
    if (-not $criado) { $mutex.Dispose(); return }

    # ---------- Papel de parede ----------
    $chaveDesktop = 'HKCU:\Control Panel\Desktop'
    $escolhaFundo = if ($PapelDeParede) { $PapelDeParede } else { Ler 'NEXTEC_PAPEL_DE_PAREDE' }
    $fundoPreto = [bool]($escolhaFundo -match '^(preto|remover)')

    # Versão antiga: o papel de parede do usuário era o próprio quadro.bmp; devolve o original
    function DevolverFundoAntigo {
        $atual = (Get-ItemProperty -Path $chaveDesktop -ErrorAction SilentlyContinue).Wallpaper
        if (-not $atual -or ($atual -ine $ArquivoQuadro)) { return }
        $original = ''
        if (Test-Path -LiteralPath $ArquivoEstado) {
            $estado = Get-Content -LiteralPath $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($estado.Caminho -and (Test-Path -LiteralPath $estado.Caminho)) {
                $original = $estado.Caminho
                if ($estado.Estilo) { Set-ItemProperty -Path $chaveDesktop -Name 'WallpaperStyle' -Value "$($estado.Estilo)" }
                if ($estado.Tile)   { Set-ItemProperty -Path $chaveDesktop -Name 'TileWallpaper' -Value "$($estado.Tile)" }
            }
        }
        # 20 = SPI_SETDESKWALLPAPER; 3 = grava no perfil e avisa as janelas
        [void][NextecWin32]::SystemParametersInfo(20, 0, $original, 3)
        Registrar "Papel de parede da versão antiga devolvido: '$original'"
    }

    # Preto liso: tira a imagem e deixa a cor da área de trabalho preta (só no perfil do usuário)
    function AplicarFundoPreto {
        $atual = (Get-ItemProperty -Path $chaveDesktop -ErrorAction SilentlyContinue).Wallpaper
        if ($atual) { [void][NextecWin32]::SystemParametersInfo(20, 0, '', 3) }
        $cor = (Get-ItemProperty -Path 'HKCU:\Control Panel\Colors' -ErrorAction SilentlyContinue).Background
        if ($cor -ne '0 0 0') {
            Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name 'Background' -Value '0 0 0'
            [void][NextecWin32]::SetSysColors(1, @(1), @(0))   # 1 = COLOR_DESKTOP
        }
    }

    try {
        if ($fundoPreto) { AplicarFundoPreto } else { DevolverFundoAntigo }
    } catch { Registrar "Papel de parede: $($_.Exception.Message)" }

    # No logon o Explorer pode demorar; espera até um minuto antes de abrir o painel
    for ($i = 0; ($i -lt 30) -and (-not [NextecWin32]::ShellPronto()); $i++) { Start-Sleep -Seconds 2 }

    # ---------- Painel: recriado sempre que o Explorer reinicia ----------
    $script:painel = $null
    $script:ciclos = 0
    while ($true) {
        $script:painel = New-Object NextecPainel
        $timer = New-Object System.Windows.Forms.Timer
        try {
            $script:painel.Linhas = Coletar
            $script:painel.Aplicar()
            $timer.Interval = $IntervaloMs
            $timer.Add_Tick({
                try {
                    $pai = [NextecWin32]::AcharPai()
                    if ($pai.ToInt64() -ne $script:painel.Pai.ToInt64()) {
                        # Explorer reiniciou ou o pai mudou: sai do laço para recriar o painel
                        [System.Windows.Forms.Application]::ExitThread()
                        return
                    }
                    $script:painel.Linhas = Coletar
                    $script:painel.Aplicar()
                    $script:ciclos++
                    if ($fundoPreto -and ($script:ciclos % 6 -eq 0)) { AplicarFundoPreto }
                } catch {
                    Registrar "Atualização: $($_.Exception.Message)"
                }
            })
            $timer.Start()
            [System.Windows.Forms.Application]::Run($script:painel)
        } catch {
            Registrar "Painel: $($_.Exception.Message)"
        } finally {
            $timer.Stop()
            $timer.Dispose()
            $script:painel.Dispose()
        }
        Start-Sleep -Seconds 3
    }
} catch {
    Registrar $_.Exception.Message
    throw
}
