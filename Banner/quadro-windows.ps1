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
        Add-Content -LiteralPath (Join-Path $PastaUsuario 'quadro.log') -Value $registro -Encoding UTF8 -ErrorAction SilentlyContinue
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
using System.Text;
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
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct PONTO { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct TAMANHO { public int L, A; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct MISTURA { public byte Op, Flags, Alfa, Formato; }
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dcDestino, IntPtr pontoDestino, ref TAMANHO tamanho, IntPtr dcOrigem, ref PONTO pontoOrigem, int chave, ref MISTURA mistura, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr objeto);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr objeto);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint comando);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder nome, int tamanho);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool herdar, uint acesso);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int atributo, out int valor, int tamanho);

    // Como o painel foi ancorado na última busca (vai para o quadro.log): WorkerW, Progman ou janela comum
    public static string Modo = "";
    // Nível de ancoragem, subido pela validação na tela quando o painel não aparece:
    // 0 = automático, 1 = filho do Progman em camada, 2 = janela comum logo acima da área de trabalho
    public static int Nivel = 0;
    static IntPtr abaixoDe = new IntPtr(1);   // HWND_BOTTOM

    static string Classe(IntPtr h)
    {
        StringBuilder nome = new StringBuilder(64);
        GetClassName(h, nome, nome.Capacity);
        return nome.ToString();
    }

    static bool Oculta(IntPtr h)
    {
        if (!IsWindowVisible(h) || IsIconic(h)) return true;
        int ocultaDwm;
        // 14 = DWMWA_CLOAKED: janelas de apps universais escondidas pelo Windows
        return DwmGetWindowAttribute(h, 14, out ocultaDwm, 4) == 0 && ocultaDwm != 0;
    }

    // Janela de topo mais alta da área de trabalho: o WorkerW com os ícones ou o Progman
    static IntPtr TopoDaAreaDeTrabalho()
    {
        IntPtr achado = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            string c = Classe(h);
            if (c == "Progman" || (c == "WorkerW" && FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero))
            {
                achado = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return achado;
    }

    // Tela bloqueada ou sessão RDP desconectada: não dá para conferir a tela
    public static bool TelaDisponivel()
    {
        IntPtr d = OpenInputDesktop(0, false, 0x0100);   // DESKTOP_SWITCHDESKTOP
        if (d == IntPtr.Zero) return false;
        CloseDesktop(d);
        return true;
    }

    // Existe janela de aplicativo (visível, não minimizada) sobre o ponto, acima do painel?
    public static bool Coberto(int x, int y, IntPtr janela)
    {
        IntPtr raiz = GetAncestor(janela, 2);   // GA_ROOT
        bool coberto = false;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (h == raiz) return false;
            string c = Classe(h);
            if (c == "Progman" || c == "WorkerW" || Oculta(h)) return true;
            RECT r;
            if (GetWindowRect(h, out r) && x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom)
            {
                coberto = true;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return coberto;
    }

    // Desenha a imagem (com transparência por pixel) na janela em camada; a posição fica como está
    public static void Camada(IntPtr janela, Bitmap imagem)
    {
        IntPtr tela = GetDC(IntPtr.Zero);
        IntPtr memoria = CreateCompatibleDC(tela);
        IntPtr bitmap = imagem.GetHbitmap(Color.FromArgb(0));
        IntPtr anterior = SelectObject(memoria, bitmap);
        try
        {
            TAMANHO tamanho = new TAMANHO { L = imagem.Width, A = imagem.Height };
            PONTO origem = new PONTO();
            MISTURA mistura = new MISTURA { Op = 0, Flags = 0, Alfa = 255, Formato = 1 };   // AC_SRC_OVER, AC_SRC_ALPHA
            UpdateLayeredWindow(janela, tela, IntPtr.Zero, ref tamanho, memoria, ref origem, 0, ref mistura, 2);   // ULW_ALPHA
        }
        finally
        {
            SelectObject(memoria, anterior);
            DeleteObject(bitmap);
            DeleteDC(memoria);
            ReleaseDC(IntPtr.Zero, tela);
        }
    }

    public static bool ShellPronto()
    {
        return FindWindow("Progman", null) != IntPtr.Zero;
    }

    // Janela da área de trabalho que serve de pai do painel. Sem Progman (Explorer fora do ar) devolve zero.
    //   Windows 11 24H2 em diante: ícones (SHELLDLL_DefView) e fundo (WorkerW) ficam dentro do Progman; o painel vira
    //   filho do Progman, logo abaixo dos ícones.
    //   Windows 8 a 11 23H2 e Server 2012 a 2022: os ícones vão para um WorkerW de topo e o fundo fica no WorkerW
    //   seguinte; o painel vira filho desse segundo WorkerW.
    public static IntPtr AcharPai()
    {
        abaixoDe = new IntPtr(1);
        IntPtr progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) { Modo = "janela comum (sem Progman)"; return IntPtr.Zero; }
        if (Nivel >= 2) { Modo = "janela comum"; return IntPtr.Zero; }
        UIntPtr resultado;
        // 0x052C pede ao Progman que separe o fundo dos ícones (cria o WorkerW); repetir não tem efeito
        SendMessageTimeout(progman, 0x052C, UIntPtr.Zero, IntPtr.Zero, 0, 1000, out resultado);
        if (FindWindowEx(progman, IntPtr.Zero, "WorkerW", null) == IntPtr.Zero)
            SendMessageTimeout(progman, 0x052C, new UIntPtr(0xD), new IntPtr(1), 0, 1000, out resultado);   // variante usada em builds mais novos

        IntPtr iconesNoProgman = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (Nivel == 1)
        {
            if (iconesNoProgman == IntPtr.Zero) { Modo = "janela comum"; return IntPtr.Zero; }
            abaixoDe = iconesNoProgman;
            Modo = "Progman (forçado)";
            return progman;
        }
        if (iconesNoProgman != IntPtr.Zero && FindWindowEx(progman, IntPtr.Zero, "WorkerW", null) != IntPtr.Zero)
        {
            abaixoDe = iconesNoProgman;
            Modo = "Progman (24H2)";
            return progman;
        }

        IntPtr achado = IntPtr.Zero;
        EnumWindows(delegate(IntPtr topo, IntPtr l)
        {
            if (achado == IntPtr.Zero && topo != progman && FindWindowEx(topo, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                achado = FindWindowEx(IntPtr.Zero, topo, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        if (achado != IntPtr.Zero && IsWindowVisible(achado)) { Modo = "WorkerW"; return achado; }

        if (iconesNoProgman != IntPtr.Zero)
        {
            abaixoDe = iconesNoProgman;
            Modo = "Progman";
            return progman;
        }
        Modo = "janela comum (sem WorkerW)";
        return IntPtr.Zero;
    }

    // Ancora a janela na área de trabalho e a posiciona (x e y em coordenadas de tela). Sem pai, a janela fica como
    // janela comum logo acima da área de trabalho, atrás dos aplicativos (cobre os ícones naquele canto). Devolve o pai usado.
    public static IntPtr Fixar(IntPtr janela, int x, int y, int largura, int altura)
    {
        const uint SEM_ATIVAR = 0x10, MUDOU_MOLDURA = 0x20, MOSTRAR = 0x40;
        IntPtr pai = AcharPai();
        if (pai == IntPtr.Zero)
        {
            IntPtr depoisDe = IntPtr.Zero;   // HWND_TOP quando não há nada acima da área de trabalho
            IntPtr topo = TopoDaAreaDeTrabalho();
            if (topo != IntPtr.Zero)
            {
                IntPtr acima = GetWindow(topo, 3);   // GW_HWNDPREV
                if (acima != IntPtr.Zero && acima != janela) depoisDe = acima;
                else if (acima == janela) depoisDe = new IntPtr(-2);   // já está no lugar: não mexe na ordem
            }
            uint flags = SEM_ATIVAR | MOSTRAR;
            if (depoisDe == new IntPtr(-2)) { flags |= 0x4; depoisDe = IntPtr.Zero; }   // SWP_NOZORDER
            SetWindowPos(janela, depoisDe, x, y, largura, altura, flags);
            return IntPtr.Zero;
        }
        SetParent(janela, pai);
        int estilo = GetWindowLong(janela, -16);                 // GWL_STYLE
        estilo = (estilo & ~unchecked((int)0x80000000)) | 0x40000000 | 0x10000000;   // sem POPUP, com CHILD e VISIBLE
        SetWindowLong(janela, -16, estilo);
        RECT r;
        GetWindowRect(pai, out r);
        SetWindowPos(janela, abaixoDe, x - r.Left, y - r.Top, largura, altura, SEM_ATIVAR | MUDOU_MOLDURA | MOSTRAR);
        return pai;
    }
}

public class NextecPainel : Form
{
    // Cabeçalho: nome do servidor, função e ambiente; corpo: métricas
    public string Titulo = "";
    public string Funcao = "";
    public string Ambiente = "";
    public Color CorAmbiente = Color.FromArgb(102, 187, 106);
    public List<NextecLinha> Linhas = new List<NextecLinha>();
    public int Opacidade = 190;   // fundo do painel, 0 a 255; o texto fica sempre opaco
    public IntPtr Pai = IntPtr.Zero;
    public int Margem, Px;

    static readonly Color CorPainel = Color.FromArgb(10, 16, 34);
    static readonly Color CorTitulo = Color.FromArgb(255, 255, 255);
    static readonly Color CorSuave = Color.FromArgb(160, 170, 200);
    static readonly Color CorValor = Color.FromArgb(236, 239, 246);
    static readonly Color CorRodape = Color.FromArgb(150, 160, 190);
    static readonly Color CorNextec = Color.FromArgb(110, 150, 255);
    const string TextoAviso = "Alterações neste servidor devem ser combinadas com a Nextec.";
    static readonly string[] SegTexto = { "Gerenciado pela ", "Nextec", "  ·  (62) 3602-1667  ·  noc@nex.tec.br" };
    static readonly bool[] SegNegrito = { false, true, false };

    Font fTitulo, fSub, fEtiqueta, fRotulo, fValor, fRodape, fRodapeB;
    StringFormat formato;
    // Medidas (Medir)
    int folga, raio, barra, x0, alturaLinha, alturaTitulo, alturaSub, alturaRodape, espacoSecao;
    float colunaRotulo, larguraConteudo, larguraEtiqueta, alturaEtiqueta;
    int larguraTotal, alturaTotal;
    bool eventoAtivo;

    public NextecPainel()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        formato = (StringFormat)StringFormat.GenericTypographic.Clone();
        formato.FormatFlags = formato.FormatFlags | StringFormatFlags.MeasureTrailingSpaces;
    }

    // Cor da faixa lateral: a do ambiente ou, sem ambiente, a da Nextec. A validação na tela procura essa cor.
    public Color CorFaixa { get { return Ambiente.Length > 0 ? CorAmbiente : CorNextec; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED (transparência por pixel) | WS_EX_TRANSPARENT (clique passa)
            cp.ExStyle |= 0x80 | 0x08000000 | 0x80000 | 0x20;
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

    // A janela pode ser destruída por fora (Explorer reiniciado leva o pai junto); o script percebe e recria
    protected override void OnHandleDestroyed(EventArgs e)
    {
        if (eventoAtivo) { SystemEvents.DisplaySettingsChanged -= TelaMudou; eventoAtivo = false; }
        base.OnHandleDestroyed(e);
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

    static int R(double v) { return (int)Math.Round(v); }

    void CriarFontes(int px)
    {
        DescartarFontes();
        Px = px;
        fTitulo = new Font("Segoe UI Semibold", R(px * 1.3), FontStyle.Regular, GraphicsUnit.Pixel);
        fSub = new Font("Segoe UI", R(px * 0.95), FontStyle.Regular, GraphicsUnit.Pixel);
        fEtiqueta = new Font("Segoe UI", R(px * 0.8), FontStyle.Bold, GraphicsUnit.Pixel);
        fRotulo = new Font("Segoe UI", R(px * 0.92), FontStyle.Regular, GraphicsUnit.Pixel);
        fValor = new Font("Segoe UI", px, FontStyle.Regular, GraphicsUnit.Pixel);
        fRodape = new Font("Segoe UI", R(px * 0.82), FontStyle.Regular, GraphicsUnit.Pixel);
        fRodapeB = new Font("Segoe UI", R(px * 0.82), FontStyle.Bold, GraphicsUnit.Pixel);
    }

    void Medir(Graphics g)
    {
        Rectangle tela = Screen.PrimaryScreen.Bounds;
        int altura = tela.Height >= 600 ? tela.Height : 1080;
        int px = Math.Max(15, R(altura / 62.0));
        if (fTitulo == null || px != Px) CriarFontes(px);
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

        Margem = R(px * 1.6);
        folga = R(px * 1.25);
        raio = R(px * 0.8);
        barra = Math.Max(4, R(px * 0.28));
        x0 = barra + folga;
        alturaLinha = R(px * 1.6);
        alturaTitulo = R(px * 1.3 * 1.4);
        alturaSub = R(px * 1.55);
        alturaRodape = R(px * 1.3);
        espacoSecao = R(px * 1.5);
        alturaEtiqueta = R(px * 1.3);

        float largura = Larg(g, Titulo, fTitulo);
        larguraEtiqueta = Ambiente.Length > 0 ? Larg(g, Ambiente.ToUpper(), fEtiqueta) + px : 0;
        largura = Math.Max(largura, Larg(g, Funcao, fSub) + (larguraEtiqueta > 0 ? px + larguraEtiqueta : 0));

        colunaRotulo = 0;
        float larguraValor = 0;
        foreach (NextecLinha l in Linhas)
        {
            if (l.Espaco) continue;
            colunaRotulo = Math.Max(colunaRotulo, Larg(g, l.Rotulo, fRotulo));
            larguraValor = Math.Max(larguraValor, Larg(g, l.Valor, l.Negrito ? fTitulo : fValor));
        }
        colunaRotulo += px * 1.6f;
        largura = Math.Max(largura, colunaRotulo + larguraValor);
        largura = Math.Max(largura, Larg(g, TextoAviso, fRodape));
        float contato = 0;
        for (int i = 0; i < SegTexto.Length; i++) contato += Larg(g, SegTexto[i], SegNegrito[i] ? fRodapeB : fRodape);
        larguraConteudo = Math.Max(largura, contato);

        int metricas = 0;
        foreach (NextecLinha l in Linhas) metricas += l.Espaco ? R(alturaLinha * 0.5) : alturaLinha;
        larguraTotal = x0 + (int)Math.Ceiling(larguraConteudo) + folga;
        alturaTotal = folga + alturaTitulo + (Funcao.Length > 0 || Ambiente.Length > 0 ? alturaSub : 0)
                    + espacoSecao + metricas + espacoSecao + 2 * alturaRodape + folga;
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

    // Recalcula o tamanho, posiciona no canto superior direito da tela principal, ancora na área de trabalho e redesenha
    public void Aplicar()
    {
        using (Bitmap b = new Bitmap(1, 1))
        using (Graphics g = Graphics.FromImage(b)) Medir(g);
        Rectangle tela = Screen.PrimaryScreen.Bounds;
        int x = tela.Right - Margem - larguraTotal;
        int y = tela.Top + Margem;
        if (!IsHandleCreated) { SetBounds(x, y, larguraTotal, alturaTotal); return; }   // com a janela criada, quem posiciona é o Fixar
        Pai = NextecWin32.Fixar(Handle, x, y, larguraTotal, alturaTotal);
        using (Bitmap imagem = Renderizar()) NextecWin32.Camada(Handle, imagem);
    }

    void Separador(Graphics g, float y)
    {
        using (Pen p = new Pen(Color.FromArgb(38, 255, 255, 255), 1)) g.DrawLine(p, x0, y, larguraTotal - folga, y);
    }

    void Texto(Graphics g, string texto, Font f, Color cor, float x, float y)
    {
        using (SolidBrush b = new SolidBrush(cor)) g.DrawString(texto, f, b, x, y, formato);
    }

    void Desenhar(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);

        // Fundo translúcido, faixa lateral opaca na cor do ambiente e borda leve
        using (GraphicsPath painel = Arredondado(0.5f, 0.5f, larguraTotal - 1, alturaTotal - 1, raio))
        {
            using (SolidBrush fundo = new SolidBrush(Color.FromArgb(Opacidade, CorPainel))) g.FillPath(fundo, painel);
            g.SetClip(painel);
            using (SolidBrush faixa = new SolidBrush(CorFaixa)) g.FillRectangle(faixa, 0, 0, barra, alturaTotal);
            g.ResetClip();
            using (Pen borda = new Pen(Color.FromArgb(50, 255, 255, 255), 1)) g.DrawPath(borda, painel);
        }

        // Cabeçalho
        float y = folga;
        Texto(g, Titulo, fTitulo, CorTitulo, x0, y);
        y += alturaTitulo;
        if (Funcao.Length > 0 || Ambiente.Length > 0)
        {
            Texto(g, Funcao, fSub, CorSuave, x0, y + R(Px * 0.12));
            if (larguraEtiqueta > 0)
            {
                // Etiqueta do ambiente à direita: fundo na cor do ambiente, bem suave, e texto na cor cheia
                float ex = larguraTotal - folga - larguraEtiqueta;
                using (GraphicsPath etiqueta = Arredondado(ex, y, larguraEtiqueta, alturaEtiqueta, alturaEtiqueta / 2))
                using (SolidBrush b = new SolidBrush(Color.FromArgb(55, CorAmbiente)))
                    g.FillPath(b, etiqueta);
                Texto(g, Ambiente.ToUpper(), fEtiqueta, CorAmbiente, ex + Px / 2f, y + (alturaEtiqueta - fEtiqueta.Height) / 2f);
            }
            y += alturaSub;
        }

        // Métricas: rótulo discreto à esquerda, valor claro (amarelo ou vermelho quando alto)
        y += espacoSecao / 2f;
        Separador(g, y);
        y += espacoSecao / 2f;
        foreach (NextecLinha l in Linhas)
        {
            if (l.Espaco) { y += R(alturaLinha * 0.5); continue; }
            Texto(g, l.Rotulo, fRotulo, CorSuave, x0, y + R(Px * 0.06));
            Texto(g, l.Valor, fValor, l.TemCor ? l.Cor : CorValor, x0 + colunaRotulo, y);
            y += alturaLinha;
        }

        // Rodapé
        y += espacoSecao / 2f;
        Separador(g, y);
        y += espacoSecao / 2f;
        Texto(g, TextoAviso, fRodape, CorRodape, x0, y);
        y += alturaRodape;
        float x = x0;
        for (int i = 0; i < SegTexto.Length; i++)
        {
            Font f = SegNegrito[i] ? fRodapeB : fRodape;
            Texto(g, SegTexto[i], f, SegNegrito[i] ? CorTitulo : CorRodape, x, y);
            x += Larg(g, SegTexto[i], f);
        }
    }

    public string Leitura = "";

    // Confere na tela se o painel aparece: lê pixels da faixa lateral, que é opaca.
    // 1 = visível, 0 = não apareceu, -1 = não deu para conferir (tela bloqueada ou área coberta por outra janela)
    public int Validar()
    {
        Leitura = "";
        if (!IsHandleCreated || !NextecWin32.TelaDisponivel()) return -1;
        Color esperada = CorFaixa;
        int xi = barra / 2;
        int[] alturas = { alturaTotal / 4, alturaTotal / 2, alturaTotal * 3 / 4 };
        bool conferiu = false;
        foreach (int yi in alturas)
        {
            Point p = PointToScreen(new Point(xi, yi));
            if (NextecWin32.Coberto(p.X, p.Y, Handle)) continue;
            try
            {
                using (Bitmap b = new Bitmap(1, 1))
                using (Graphics g = Graphics.FromImage(b))
                {
                    g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(1, 1), CopyPixelOperation.SourceCopy | CopyPixelOperation.CaptureBlt);   // CaptureBlt: inclui janelas translúcidas
                    Color c = b.GetPixel(0, 0);
                    conferiu = true;
                    Leitura += string.Format("({0},{1})=RGB {2},{3},{4} ", p.X, p.Y, c.R, c.G, c.B);
                    if (Math.Abs(c.R - esperada.R) <= 12 && Math.Abs(c.G - esperada.G) <= 12 && Math.Abs(c.B - esperada.B) <= 12) return 1;
                }
            }
            catch (Exception ex) { Leitura = "captura falhou: " + ex.Message; return -1; }
        }
        if (!conferiu) Leitura = "pontos cobertos por outras janelas ou tela indisponível";
        return conferiu ? 0 : -1;
    }

    // Imagem do painel com transparência; chame Aplicar (ou Medir) antes
    public Bitmap Renderizar()
    {
        if (fTitulo == null) { using (Bitmap t = new Bitmap(1, 1)) using (Graphics g = Graphics.FromImage(t)) Medir(g); }
        Bitmap b = new Bitmap(larguraTotal, alturaTotal, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) Desenhar(g);
        return b;
    }

    void DescartarFontes()
    {
        if (fTitulo == null) return;
        fTitulo.Dispose(); fSub.Dispose(); fEtiqueta.Dispose(); fRotulo.Dispose(); fValor.Dispose(); fRodape.Dispose(); fRodapeB.Dispose();
        fTitulo = null;
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

    # Amarelo a partir de 80%, vermelho a partir de 90%
    $corAlerta  = [System.Drawing.Color]::FromArgb(255, 213, 79)
    $corCritica = [System.Drawing.Color]::FromArgb(239, 83, 80)
    function CorDoUso([double]$porcento) {
        if ($porcento -ge 90) { return $corCritica }
        if ($porcento -ge 80) { return $corAlerta }
        return $null
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

        $paginacao = 'não configurada'
        $pagUso = 0
        $arquivos = Seguro { @(Get-CimInstance Win32_PageFileUsage) } $null
        if ($arquivos) {
            $total = ($arquivos | Measure-Object AllocatedBaseSize -Sum).Sum
            $usado = ($arquivos | Measure-Object CurrentUsage -Sum).Sum
            if ($total -gt 0) { $pagUso = $usado / $total * 100; $paginacao = '{0:N0}% de {1:N1} GB' -f $pagUso, ($total / 1024) }
        }

        $disco = 'não identificado'
        $discoUso = 0
        $d = Seguro { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" } $null
        if ($d -and $d.Size) {
            $discoUso = ($d.Size - $d.FreeSpace) / $d.Size * 100
            $disco = '{0:N0}% usado ({1:N0} GB de {2:N0} GB)' -f $discoUso, (($d.Size - $d.FreeSpace) / 1GB), ($d.Size / 1GB)
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
        $linhas.Add((NovaLinha 'Carga' ('{0}% de CPU ({1} CPUs)' -f $cpuUso, $cpus) $false (CorDoUso $cpuUso)))
        $linhas.Add((NovaLinha 'Memória' $memoria $false (CorDoUso $memUso)))
        $linhas.Add((NovaLinha 'Disco' $disco $false (CorDoUso $discoUso)))
        $linhas.Add((NovaLinha 'Paginação' $paginacao $false (CorDoUso $pagUso)))
        $espaco = New-Object NextecLinha
        $espaco.Espaco = $true
        $linhas.Add($espaco)
        $linhas.Add((NovaLinha 'Uptime' $uptime))
        $linhas.Add((NovaLinha 'Processos' ('{0}  ·  Usuários: {1}' -f $processos, $usuarios)))
        $linhas.Add((NovaLinha 'IP' $ip))

        return [pscustomobject]@{ Titulo = $servidor; Funcao = $funcao; Ambiente = $ambiente; CorAmbiente = $corAmbiente; Linhas = $linhas }
    }

    # Opacidade do fundo do painel: NEXTEC_OPACIDADE (0 a 255) ou 190. Lida a cada segundo, para ajustar ao vivo
    function LerOpacidade {
        $lida = 0
        if ([int]::TryParse((Ler 'NEXTEC_OPACIDADE'), [ref]$lida) -and $lida -ge 0 -and $lida -le 255) { return $lida }
        return 190
    }

    function Preencher($painel) {
        $dados = Coletar
        $painel.Titulo = $dados.Titulo
        $painel.Funcao = $dados.Funcao
        $painel.Ambiente = $dados.Ambiente
        $painel.CorAmbiente = $dados.CorAmbiente
        $painel.Linhas = $dados.Linhas
        $painel.Opacidade = LerOpacidade
    }

    # ---------- Só gerar a imagem (conferência visual) ----------
    if ($SalvarEm) {
        $p = New-Object NextecPainel
        Preencher $p
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
        $g.DrawImage($imgPainel, ($w - $p.Margem - $imgPainel.Width), $p.Margem)
        $g.Dispose()
        $imagem.Save($SalvarEm, [System.Drawing.Imaging.ImageFormat]::Png)
        $imagem.Dispose(); $imgPainel.Dispose(); $p.Dispose()
        Write-Host "Imagem gerada em $SalvarEm"
        return
    }

    # ---------- Uma instância por sessão (o prefixo Local\ isola cada sessão, inclusive RDP) ----------
    $criado = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\NextecBannerPainel', [ref]$criado)
    if (-not $criado) { $mutex.Dispose(); Write-Host 'O painel já está aberto nesta sessão.'; return }

    # ---------- Papel de parede ----------
    $chaveDesktop = 'HKCU:\Control Panel\Desktop'
    $escolhaFundo = if ($PapelDeParede) { $PapelDeParede } else { Ler 'NEXTEC_PAPEL_DE_PAREDE' }
    $fundoPreto = [bool]($escolhaFundo -match '^(preto|remover)')

    # Devolve o papel de parede guardado quando o fundo preto foi aplicado (ou pela versão antiga, em que o papel de
    # parede do usuário era o próprio quadro.bmp). Só age se o papel de parede atual está vazio ou é o quadro.bmp
    function DevolverFundoAntigo {
        $atual = (Get-ItemProperty -Path $chaveDesktop -ErrorAction SilentlyContinue).Wallpaper
        if ($atual -and ($atual -ine $ArquivoQuadro)) { return }
        if (-not (Test-Path -LiteralPath $ArquivoEstado)) { return }
        $original = ''
        $estado = Get-Content -LiteralPath $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($estado.Caminho -and (Test-Path -LiteralPath $estado.Caminho)) {
            $original = $estado.Caminho
            if ($estado.Estilo) { Set-ItemProperty -Path $chaveDesktop -Name 'WallpaperStyle' -Value "$($estado.Estilo)" }
            if ($estado.Tile)   { Set-ItemProperty -Path $chaveDesktop -Name 'TileWallpaper' -Value "$($estado.Tile)" }
        }
        # 20 = SPI_SETDESKWALLPAPER; 3 = grava no perfil e avisa as janelas
        [void][NextecWin32]::SystemParametersInfo(20, 0, $original, 3)
        Remove-Item -LiteralPath $ArquivoEstado -Force -ErrorAction SilentlyContinue
        Registrar "Papel de parede devolvido: '$original'"
    }

    # Preto liso: guarda o papel de parede atual, tira a imagem e deixa a cor da área de trabalho preta (só no perfil do usuário)
    function AplicarFundoPreto {
        $d = Get-ItemProperty -Path $chaveDesktop -ErrorAction SilentlyContinue
        $atual = "$($d.Wallpaper)"
        if ($atual) {
            if ($atual -ine $ArquivoQuadro) {
                New-Item -ItemType Directory -Path $PastaUsuario -Force | Out-Null
                [pscustomobject]@{ Caminho = $atual; Estilo = "$($d.WallpaperStyle)"; Tile = "$($d.TileWallpaper)" } |
                    ConvertTo-Json | Set-Content -LiteralPath $ArquivoEstado -Encoding UTF8
            }
            [void][NextecWin32]::SystemParametersInfo(20, 0, '', 3)
        }
        $cor = (Get-ItemProperty -Path 'HKCU:\Control Panel\Colors' -ErrorAction SilentlyContinue).Background
        if ($cor -ne '0 0 0') {
            Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name 'Background' -Value '0 0 0'
            [void][NextecWin32]::SetSysColors(1, @(1), @(0))   # 1 = COLOR_DESKTOP
        }
    }

    try {
        if ($fundoPreto) { AplicarFundoPreto } else { DevolverFundoAntigo }
    } catch { Registrar "Papel de parede: $($_.Exception.Message)" }

    try {
        $so = Get-CimInstance -ClassName Win32_OperatingSystem
        Registrar ("Início: {0} (build {1}), sessão {2}, PowerShell {3}" -f $so.Caption, $so.BuildNumber, (Get-Process -Id $PID).SessionId, $PSVersionTable.PSVersion)
    } catch { }

    # No logon o Explorer pode demorar; espera até um minuto antes de abrir o painel
    for ($i = 0; ($i -lt 30) -and (-not [NextecWin32]::ShellPronto()); $i++) { Start-Sleep -Seconds 2 }

    # ---------- Painel: um laço de mensagens só; a janela é recriada dentro dele quando o Explorer reinicia ----------
    # Erros dentro da janela vão para o log, sem caixa de diálogo
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({ Registrar "Janela: $($args[1].Exception.Message)" })

    $script:painel = $null
    $script:ciclos = 0
    $script:modoRegistrado = ''
    $script:avisouSemConferir = $false

    function NovoPainel {
        if ($script:painel) { try { $script:painel.Dispose() } catch { } }
        $script:validacao = 'pendente'   # pendente, ok ou falhou
        $script:falhas = 0
        $script:painel = New-Object NextecPainel
        Preencher $script:painel
        $script:painel.Aplicar()
        $script:painel.Show()             # sem roubar o foco; ao aparecer, ancora na área de trabalho
    }

    function Tique {
        $timer.Interval = $IntervaloMs
        $pai = [NextecWin32]::AcharPai()
        if (-not $script:painel.IsHandleCreated -or ($pai.ToInt64() -ne $script:painel.Pai.ToInt64())) {
            # Explorer reiniciou (a janela foi junto) ou a área de trabalho mudou: recria o painel
            Registrar 'Área de trabalho mudou; recriando o painel'
            NovoPainel
            return
        }

        # Validação na tela: duas conferências seguidas sem o painel = passa para o próximo modo de ancoragem
        if ($script:validacao -eq 'pendente') {
            $resultado = $script:painel.Validar()
            if ($resultado -eq 1) {
                $script:validacao = 'ok'
                Registrar "Painel visível na tela: $([NextecWin32]::Modo)"
            } elseif ($resultado -eq -1) {
                if (-not $script:avisouSemConferir) {
                    $script:avisouSemConferir = $true
                    Registrar "Conferência na tela indisponível: $($script:painel.Leitura)"
                }
            } elseif ($resultado -eq 0) {
                $script:falhas++
                $modo = [NextecWin32]::Modo
                Registrar "Conferência sem o painel no modo '$modo': $($script:painel.Leitura)"
                if ($script:falhas -ge 2) {
                    if ([NextecWin32]::Nivel -lt 2) {
                        if ([NextecWin32]::Nivel -eq 0 -and $modo -like 'Progman*') { [NextecWin32]::Nivel = 2 } else { [NextecWin32]::Nivel++ }
                        Registrar "Painel não apareceu no modo '$modo'; tentando o próximo"
                        NovoPainel
                        return
                    }
                    $script:validacao = 'falhou'
                    Registrar "Painel não apareceu em nenhum modo de ancoragem (último: '$modo')"
                }
            }
        }

        Preencher $script:painel
        $script:painel.Aplicar()
        if ([NextecWin32]::Modo -ne $script:modoRegistrado) {
            $script:modoRegistrado = [NextecWin32]::Modo
            Registrar "Painel ancorado: $($script:modoRegistrado)"
        }
        $script:ciclos++
        if ($fundoPreto -and ($script:ciclos % 6 -eq 0)) { AplicarFundoPreto }
    }

    while ($true) {
        $timer = New-Object System.Windows.Forms.Timer
        try {
            NovoPainel
            $timer.Interval = 2000   # primeira conferência logo depois de abrir; depois a cada 10 segundos
            $timer.Add_Tick({
                try { Tique } catch { Registrar "Atualização: $($_.Exception.Message)" }
            })
            $timer.Start()
            $timerOpacidade = New-Object System.Windows.Forms.Timer
            $timerOpacidade.Interval = 1000
            $timerOpacidade.Add_Tick({
                try {
                    $nova = LerOpacidade
                    if ($script:painel -and $script:painel.IsHandleCreated -and $nova -ne $script:painel.Opacidade) {
                        $script:painel.Opacidade = $nova
                        $script:painel.Aplicar()
                        Registrar "Opacidade ajustada para $nova"
                    }
                } catch { Registrar "Opacidade: $($_.Exception.Message)" }
            })
            $timerOpacidade.Start()
            [System.Windows.Forms.Application]::Run()
        } catch {
            Registrar "Painel: $($_.Exception.Message)"
        } finally {
            $timer.Stop()
            $timer.Dispose()
            if ($timerOpacidade) { $timerOpacidade.Stop(); $timerOpacidade.Dispose() }
            if ($script:painel) { try { $script:painel.Dispose() } catch { } }
            $script:painel = $null
        }
        Start-Sleep -Seconds 5
    }
} catch {
    Registrar $_.Exception.Message
    throw
}
