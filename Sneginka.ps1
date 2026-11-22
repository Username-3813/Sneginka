# Снежинка для Windows 2.0 — снег поверх рабочего стола + ручной конструктор снеговика
$ErrorActionPreference = 'Stop'
$script:LogPath = Join-Path $env:TEMP 'Sneginka-error.log'
$mutex = New-Object System.Threading.Mutex($false, 'SneginkaOverlayV2')
if (-not $mutex.WaitOne(0)) { exit }
try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
namespace Sneg
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLL { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    public static class Native
    {
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
        [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int id, HookProc cb, IntPtr mod, uint tid);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
        public static void ClickThrough(IntPtr hwnd) { int ex = GetWindowLong(hwnd, -20); ex |= 0x80000 | 0x20 | 0x08000000 | 0x80; SetWindowLong(hwnd, -20, ex); }
    }
    public class Flake { public double x, y, z, vy, ph, rot, vr, sz; public int sp; public bool burst; }
    public class Particle { public double x, y, vx, vy, g, life, max, size; public int type; }
    public class Surface { public string id; public double x, y, w, max, px, py; public int cols; public double[] h; public bool win; }
    public class Ball { public double x, y, r, rot; }
    public class SnowEngine : FrameworkElement
    {
        public double Intensity = 0, Wind = 18, FlakeSize = 50, Accum = 50, PlowSpeed = 5, Volume = 0.2, Grow = 1;
        public bool PlowOn = true, SnowmanOn = true, FrostOn = true, SoundOn = true, Paused = false;
        public int Garland = 1, Quality = 2, Manual = 0; public bool PlowClears = true;
        public System.Collections.Concurrent.ConcurrentQueue<string> Events = new System.Collections.Concurrent.ConcurrentQueue<string>();
        double T = 0, W = 0, H = 0, dpi = 1, vx = 0, vy = 0, surfTimer = 0, garLit = 0;
        List<Flake> flakes = new List<Flake>(); List<Particle> parts = new List<Particle>();
        List<Surface> surfaces = new List<Surface>(); Dictionary<string, Surface> hmap = new Dictionary<string, Surface>();
        List<double[]> trails = new List<double[]>(); Random rnd = new Random(); Stopwatch clock = Stopwatch.StartNew(); double lastFrame = 0;
        uint myPid; IntPtr hook = IntPtr.Zero; HookProc hookProc; EnumProc enumProc;
        double plowX = -160, plowPause = 0, plowWheel = 0, plowPush = 0, plowHonk = 0, plowEx = 0, plowTrail = 0; int plowDir = 1; const double PL = 96;
        int smState = 0; double smX = 0, smCd = 0, smIdle = 0, smDec = 0, smBlink = 0, smBlinkT = 3, smWave = 0, smWaveT = 10, smWob = 0, smWobV = 0, smLand = 0, smRollX = 0, smRollR = 6, smRollTR = 26, smArcT = 0, smArcY0 = 0, smArcY1 = 0, smWait = 0; int smStage = 1, smFirst = 0;
        List<Ball> smBalls = new List<Ball>();
        List<Ball> free = new List<Ball>(); List<Ball> tower = new List<Ball>(); double towerX = 0;
        int hold = 0, hover = 0, hoverIndex = -1; double hoverTop = 0, hoverH = 0; Ball held = null; double holdOff = 0, holdLastX = 0; bool holdMoved = false;
        double ptrX = 0, ptrY = 0;
        SolidColorBrush snowTop, snowFar, snowMid, snowNear, coal, carrot, scarf, scarfDark, hat, wood, steel, glass, ice;
        LinearGradientBrush pileBrush, bodyBrush, bladeBrush; RadialGradientBrush glowAmber, ballBr, ballShade; Pen ballPen, frostPen;
        StreamGeometry[] crystals = new StreamGeometry[8]; StreamGeometry frostGeo;
        string[] garHex = new string[] { "#ff5f6d", "#ffc247", "#5df2a6", "#5fd4ff", "#ff6fd8" };
        Brush[] garBulb = new Brush[5]; Brush[] garGlow = new Brush[5]; Brush[] warmBulb = new Brush[4]; Brush[] warmGlow = new Brush[4]; Brush[] iceBulb = new Brush[4]; Brush[] iceGlow = new Brush[4];
        MediaPlayer windPlayer, jinglePlayer, honkPlayer, popPlayer, shakePlayer, whooshPlayer; string audioDir;
        Typeface hintFace;
        public SnowEngine()
        {
            IsHitTestVisible = false; myPid = (uint)Process.GetCurrentProcess().Id;
            hintFace = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
            InitBrushes(); InitCrystals(); InitAudio();
            hookProc = new HookProc(MouseHook); hook = Native.SetWindowsHookEx(14, hookProc, Native.GetModuleHandle(null), 0);
            enumProc = new EnumProc(EnumCallback); CompositionTarget.Rendering += OnFrame;
        }
        double R(double a, double b) { return a + rnd.NextDouble() * (b - a); }
        int RI(int a, int b) { return a + rnd.Next(b - a + 1); }
        double Clamp(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }
        static Dictionary<string, SolidColorBrush> bcache = new Dictionary<string, SolidColorBrush>();
        static Dictionary<string, Pen> pcache = new Dictionary<string, Pen>();
        static SolidColorBrush B(string hex) { SolidColorBrush b; if (bcache.TryGetValue(hex, out b)) return b; b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); b.Freeze(); bcache[hex] = b; return b; }
        static Pen P(string hex, double th) { string k = hex + "|" + th.ToString(CultureInfo.InvariantCulture); Pen p; if (pcache.TryGetValue(k, out p)) return p; p = new Pen(B(hex), th); p.StartLineCap = PenLineCap.Round; p.EndLineCap = PenLineCap.Round; p.LineJoin = PenLineJoin.Round; p.Freeze(); pcache[k] = p; return p; }
        static RadialGradientBrush Glow(string hex, double a) { Color c = (Color)ColorConverter.ConvertFromString(hex); var g = new RadialGradientBrush(); g.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(a * 255), c.R, c.G, c.B), 0)); g.GradientStops.Add(new GradientStop(Color.FromArgb((byte)(a * 100), c.R, c.G, c.B), 0.4)); g.GradientStops.Add(new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1)); g.Freeze(); return g; }
        void InitBrushes()
        {
            snowTop = B("#ffffff"); snowFar = B("#9fdcff"); snowMid = B("#cfe6ff"); snowNear = B("#f4f8ff");
            coal = B("#20242e"); carrot = B("#ff8c3a"); scarf = B("#e5484d"); scarfDark = B("#c23238"); hat = B("#1c2030"); wood = B("#5b4230"); steel = B("#8fa2c4"); glass = B("#101a33"); ice = B("#bfeaff");
            pileBrush = new LinearGradientBrush(Color.FromRgb(255, 255, 255), Color.FromRgb(195, 210, 238), new Point(0, 0), new Point(0, 1)); pileBrush.Freeze();
            bodyBrush = new LinearGradientBrush(Color.FromRgb(255, 210, 87), Color.FromRgb(240, 156, 30), new Point(0, 0), new Point(0, 1)); bodyBrush.Freeze();
            bladeBrush = new LinearGradientBrush(Color.FromRgb(199, 211, 232), Color.FromRgb(93, 112, 150), new Point(0, 0), new Point(1, 1)); bladeBrush.Freeze();
            glowAmber = Glow("#ff9e2c", 0.9);
            ballBr = new RadialGradientBrush(); ballBr.GradientOrigin = new Point(0.36, 0.3); ballBr.Center = new Point(0.5, 0.5); ballBr.RadiusX = 0.78; ballBr.RadiusY = 0.78;
            ballBr.GradientStops.Add(new GradientStop(Colors.White, 0)); ballBr.GradientStops.Add(new GradientStop(Color.FromRgb(244, 248, 255), 0.45)); ballBr.GradientStops.Add(new GradientStop(Color.FromRgb(222, 232, 248), 0.78)); ballBr.GradientStops.Add(new GradientStop(Color.FromRgb(178, 196, 228), 1)); ballBr.Freeze();
            ballShade = new RadialGradientBrush(); ballShade.GradientOrigin = new Point(0.4, 0.3); ballShade.Center = new Point(0.5, 0.5); ballShade.RadiusX = 0.55; ballShade.RadiusY = 0.55;
            ballShade.GradientStops.Add(new GradientStop(Color.FromArgb(0, 80, 105, 170), 0)); ballShade.GradientStops.Add(new GradientStop(Color.FromArgb(0, 80, 105, 170), 0.72)); ballShade.GradientStops.Add(new GradientStop(Color.FromArgb(105, 80, 105, 170), 1)); ballShade.Freeze();
            ballPen = new Pen(B("#8296acd6"), 0.9); ballPen.Freeze();
            frostPen = new Pen(ice, 1.0); frostPen.StartLineCap = PenLineCap.Round; frostPen.EndLineCap = PenLineCap.Round; frostPen.Freeze();
            for (int i = 0; i < 5; i++) { garBulb[i] = B(garHex[i]); garGlow[i] = Glow(garHex[i], 0.85); }
            string[] warm = new string[] { "#ffd27a", "#ffb347", "#ffe9b8", "#ffc247" }; string[] iceh = new string[] { "#bfeaff", "#7fd8ff", "#e8f7ff", "#9fb8ff" };
            for (int i = 0; i < 4; i++) { warmBulb[i] = B(warm[i]); warmGlow[i] = Glow(warm[i], 0.85); iceBulb[i] = B(iceh[i]); iceGlow[i] = Glow(iceh[i], 0.85); }
        }
        static Point AP(double an, double u, double v) { double sa = Math.Sin(an), ca = Math.Cos(an); return new Point(sa * u + ca * v, -ca * u + sa * v); }
        static void Seg(StreamGeometryContext c, Point a, Point b) { c.BeginFigure(a, false, false); c.LineTo(b, true, false); }
        static void Hex(StreamGeometryContext c, double r, double off) { c.BeginFigure(new Point(Math.Sin(off) * r, -Math.Cos(off) * r), false, true); for (int i = 1; i < 6; i++) { double an = off + i * Math.PI / 3; c.LineTo(new Point(Math.Sin(an) * r, -Math.Cos(an) * r), true, false); } }
        void InitCrystals()
        {
            for (int v = 0; v < 8; v++)
            {
                var g = new StreamGeometry();
                using (var c = g.Open())
                {
                    double L = 11 + (v % 3);
                    for (int a = 0; a < 6; a++)
                    {
                        double an = a * Math.PI / 3;
                        switch (v)
                        {
                            case 0:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L, 0));
                                    double[] ps = new double[] { 0.28, 0.46, 0.64, 0.82 }; double[] bl = new double[] { 3.0, 4.8, 3.8, 2.4 };
                                    for (int k = 0; k < 4; k++)
                                    {
                                        double p = L * ps[k];
                                        for (int sd = -1; sd <= 1; sd += 2)
                                        {
                                            Seg(c, AP(an, p, 0), AP(an, p + bl[k] * 0.85, sd * bl[k]));
                                            Seg(c, AP(an, p + bl[k] * 0.45, sd * bl[k] * 0.5), AP(an, p + bl[k] * 0.45 + 1.8, sd * (bl[k] * 0.5 + 1.2)));
                                        }
                                    }
                                    Seg(c, AP(an, L, 0), AP(an, L + 1.8, 1.4)); Seg(c, AP(an, L, 0), AP(an, L + 1.8, -1.4));
                                    break;
                                }
                            case 1:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L * 0.55, 0));
                                    Seg(c, AP(an, L * 0.55, 0), AP(an, L * 0.85, 3.2)); Seg(c, AP(an, L * 0.55, 0), AP(an, L * 0.85, -3.2));
                                    Seg(c, AP(an, L * 0.85, 3.2), AP(an, L, 0)); Seg(c, AP(an, L * 0.85, -3.2), AP(an, L, 0));
                                    Seg(c, AP(an, L * 0.3, 0), AP(an, L * 0.3 + 2.4, 2.2)); Seg(c, AP(an, L * 0.3, 0), AP(an, L * 0.3 + 2.4, -2.2));
                                    break;
                                }
                            case 2:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L + 1, 0));
                                    double[] ps2 = new double[] { 0.4, 0.62, 0.82 };
                                    for (int k = 0; k < 3; k++) { double p = L * ps2[k]; Seg(c, AP(an, p, 0), AP(an, p + 2.8, 3.1 - k * 0.5)); Seg(c, AP(an, p, 0), AP(an, p + 2.8, -(3.1 - k * 0.5))); }
                                    Seg(c, AP(an, L + 1, 0), AP(an, L - 1.2, 1.6)); Seg(c, AP(an, L + 1, 0), AP(an, L - 1.2, -1.6));
                                    break;
                                }
                            case 3:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L, 0));
                                    Seg(c, AP(an, L * 0.4, 0), AP(an, L * 0.6, 2.4)); Seg(c, AP(an, L * 0.6, 2.4), AP(an, L * 0.8, 0));
                                    Seg(c, AP(an, L * 0.8, 0), AP(an, L * 0.6, -2.4)); Seg(c, AP(an, L * 0.6, -2.4), AP(an, L * 0.4, 0));
                                    Seg(c, AP(an, L, 0), AP(an, L - 2.4, 1.8)); Seg(c, AP(an, L, 0), AP(an, L - 2.4, -1.8));
                                    break;
                                }
                            case 4:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L + 0.5, 0));
                                    for (int k = 1; k <= 6; k++) { double p = L * k / 7.0, bl2 = 4.2 * (1 - k / 7.5); Seg(c, AP(an, p, 0), AP(an, p + bl2 * 0.7, bl2)); Seg(c, AP(an, p, 0), AP(an, p + bl2 * 0.7, -bl2)); }
                                    break;
                                }
                            case 5:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L, 0));
                                    Seg(c, AP(an, L * 0.5, 0), AP(an, L * 0.5 + 3.5, 3.5)); Seg(c, AP(an, L * 0.5, 0), AP(an, L * 0.5 + 3.5, -3.5));
                                    Seg(c, AP(an, L - 1, -3.4), AP(an, L - 1, 3.4)); Seg(c, AP(an, L * 0.72, -2.4), AP(an, L * 0.72, 2.4));
                                    break;
                                }
                            case 6:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L, 0));
                                    Seg(c, AP(an, L * 0.55, 0), AP(an, L * 0.55 + 3.2, 3)); Seg(c, AP(an, L * 0.55, 0), AP(an, L * 0.55 + 3.2, -3));
                                    Seg(c, AP(an, L * 0.8, 0), AP(an, L * 0.8 + 2.4, 2.2)); Seg(c, AP(an, L * 0.8, 0), AP(an, L * 0.8 + 2.4, -2.2));
                                    break;
                                }
                            default:
                                {
                                    Seg(c, AP(an, 0, 0), AP(an, L, 0));
                                    Seg(c, AP(an, L, 0), AP(an, L - 3, 2.6)); Seg(c, AP(an, L, 0), AP(an, L - 3, -2.6));
                                    Seg(c, AP(an, L * 0.5, 0), AP(an, L * 0.5 + 2, 2)); Seg(c, AP(an, L * 0.5, 0), AP(an, L * 0.5 + 2, -2));
                                    break;
                                }
                        }
                    }
                    switch (v)
                    {
                        case 1: Hex(c, L * 0.36, 0); Hex(c, L * 0.2, Math.PI / 6); break;
                        case 3: Hex(c, L * 0.22, 0); break;
                        case 4: Hex(c, L * 0.16, 0); break;
                        case 6: Hex(c, L * 0.34, 0); break;
                        case 7: Hex(c, L * 0.2, 0); break;
                    }
                }
                g.Freeze(); crystals[v] = g;
            }
        }
        void BuildFrost()
        {
            var g = new StreamGeometry();
            using (var c = g.Open())
            {
                for (int i = 0; i < 34; i++)
                {
                    double t = i / 34.0, len = 50 + rnd.NextDouble() * 150, an = t * Math.PI / 2;
                    double sx = Math.Cos(an) * 8, sy = Math.Sin(an) * 8, ex = Math.Cos(an) * len, ey = Math.Sin(an) * len;
                    c.BeginFigure(new Point(sx, sy), false, false); c.LineTo(new Point(ex, ey), true, false);
                    for (int k = 1; k < 6; k++)
                    {
                        double f = k / 6.0, bx = sx + (ex - sx) * f, by = sy + (ey - sy) * f, bl = len * 0.2 * (1 - f);
                        for (int sd = -1; sd <= 1; sd += 2)
                        {
                            double ba = an + sd * 0.9, tx = bx + Math.Cos(ba) * bl, ty = by + Math.Sin(ba) * bl;
                            c.BeginFigure(new Point(bx, by), false, false); c.LineTo(new Point(tx, ty), true, false);
                            double mx = (bx + tx) / 2, my = (by + ty) / 2, tl = bl * 0.4;
                            c.BeginFigure(new Point(mx, my), false, false); c.LineTo(new Point(mx + Math.Cos(ba + 0.8) * tl, my + Math.Sin(ba + 0.8) * tl), true, false);
                            c.BeginFigure(new Point(mx, my), false, false); c.LineTo(new Point(mx + Math.Cos(ba - 0.8) * tl, my + Math.Sin(ba - 0.8) * tl), true, false);
                        }
                    }
                }
            }
            g.Freeze(); frostGeo = g;
        }
        void InitAudio() { try { audioDir = Path.Combine(Path.GetTempPath(), "Sneginka"); Directory.CreateDirectory(audioDir); int rate = 22050; WriteWav(Path.Combine(audioDir, "wind.wav"), WindSamples(rate), rate); WriteWav(Path.Combine(audioDir, "jingle.wav"), BellSamples(rate), rate); WriteWav(Path.Combine(audioDir, "honk.wav"), HonkSamples(rate), rate); WriteWav(Path.Combine(audioDir, "pop.wav"), PopSamples(rate), rate); WriteWav(Path.Combine(audioDir, "shake.wav"), NoiseSamples(rate, 0.4, 0.5), rate); WriteWav(Path.Combine(audioDir, "whoosh.wav"), NoiseSamples(rate, 0.8, 0.35), rate); windPlayer = NewPlayer("wind.wav"); jinglePlayer = NewPlayer("jingle.wav"); honkPlayer = NewPlayer("honk.wav"); popPlayer = NewPlayer("pop.wav"); shakePlayer = NewPlayer("shake.wav"); whooshPlayer = NewPlayer("whoosh.wav"); windPlayer.MediaEnded += delegate { if (SoundOn) { windPlayer.Position = TimeSpan.Zero; windPlayer.Play(); } }; ApplySound(); } catch { } }
        MediaPlayer NewPlayer(string n) { var p = new MediaPlayer(); p.Open(new Uri(Path.Combine(audioDir, n))); p.Volume = Volume; return p; }
        float[] WindSamples(int rate) { int n = rate * 6; float[] s = new float[n]; double last = 0; for (int i = 0; i < n; i++) { last += (rnd.NextDouble() * 2 - 1) * 0.035; last *= 0.995; double env = 0.6 + 0.4 * Math.Sin(2 * Math.PI * i / n * 2); double fade = Math.Min(1, Math.Min(i / (rate * 0.4), (n - i) / (rate * 0.4))); s[i] = (float)(last * 2.2 * env * fade); } return s; }
        float[] BellSamples(int rate) { int n = (int)(rate * 1.1); float[] s = new float[n]; double[] f = new double[] { 1568, 2093, 2637, 1760, 2349, 3136 }; for (int k = 0; k < 6; k++) { int st = (int)(k * 0.07 * rate); for (int i = st; i < n; i++) { double t = (i - st) / (double)rate, env = Math.Exp(-t * 7); s[i] += (float)((Math.Sin(2 * Math.PI * f[k] * t) + 0.35 * Math.Sin(2 * Math.PI * f[k] * 2.7 * t)) * env * 0.16); } } return s; }
        float[] HonkSamples(int rate) { int n = (int)(rate * 0.45); float[] s = new float[n]; for (int i = 0; i < n; i++) { double t = i / (double)rate; double env = (t < 0.2 || (t > 0.26 && t < 0.42)) ? Math.Min(1, t * 40) * Math.Exp(-(t % 0.26) * 4) : 0; s[i] = (float)((Math.Sin(2 * Math.PI * 292 * t) + Math.Sin(2 * Math.PI * 370 * t)) * 0.2 * env); } return s; }
        float[] PopSamples(int rate) { int n = (int)(rate * 0.16); float[] s = new float[n]; double ph = 0; for (int i = 0; i < n; i++) { double t = i / (double)rate, f = 520 - 350 * (t / 0.16); ph += 2 * Math.PI * f / rate; s[i] = (float)(Math.Sin(ph) * Math.Exp(-t * 22) * 0.3); } return s; }
        float[] NoiseSamples(int rate, double dur, double amp) { int n = (int)(rate * dur); float[] s = new float[n]; double last = 0; for (int i = 0; i < n; i++) { double t = i / (double)n; last += (rnd.NextDouble() * 2 - 1) * 0.3; last *= 0.9; s[i] = (float)(last * amp * Math.Sin(Math.PI * t)); } return s; }
        void WriteWav(string path, float[] s, int rate) { int n = s.Length; byte[] b = new byte[44 + n * 2]; Action<int, int> w4 = delegate(int pos, int val) { b[pos] = (byte)val; b[pos + 1] = (byte)(val >> 8); b[pos + 2] = (byte)(val >> 16); b[pos + 3] = (byte)(val >> 24); }; Action<int, short> w2 = delegate(int pos, short val) { b[pos] = (byte)val; b[pos + 1] = (byte)(val >> 8); }; b[0] = (byte)'R'; b[1] = (byte)'I'; b[2] = (byte)'F'; b[3] = (byte)'F'; w4(4, 36 + n * 2); b[8] = (byte)'W'; b[9] = (byte)'A'; b[10] = (byte)'V'; b[11] = (byte)'E'; b[12] = (byte)'f'; b[13] = (byte)'m'; b[14] = (byte)'t'; b[15] = (byte)' '; w4(16, 16); w2(20, 1); w2(22, 1); w4(24, rate); w4(28, rate * 2); w2(32, 2); w2(34, 16); b[36] = (byte)'d'; b[37] = (byte)'a'; b[38] = (byte)'t'; b[39] = (byte)'a'; w4(40, n * 2); for (int i = 0; i < n; i++) { double v = s[i]; if (v > 1) v = 1; if (v < -1) v = -1; short q = (short)(v * 32767); w2(44 + i * 2, q); } File.WriteAllBytes(path, b); }
        public void ApplySound() { MediaPlayer[] all = new MediaPlayer[] { windPlayer, jinglePlayer, honkPlayer, popPlayer, shakePlayer, whooshPlayer }; foreach (var p in all) { if (p != null) p.Volume = SoundOn ? Volume : 0; } if (windPlayer != null) { if (SoundOn) windPlayer.Play(); else windPlayer.Stop(); } }
        void Play(MediaPlayer p) { if (p == null || !SoundOn) return; p.Position = TimeSpan.Zero; p.Play(); }
        void Jingle() { Play(jinglePlayer); }
        double ActorGround() { Surface tb; if (hmap.TryGetValue("taskbar", out tb) && tb.y > H * 0.5) return tb.y; return H; }
        // ---- взаимодействие мышью ----
        IntPtr MouseHook(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0)
            {
                MSLL m = (MSLL)Marshal.PtrToStructure(l, typeof(MSLL));
                double px = (m.pt.X - vx) / dpi, py = (m.pt.Y - vy) / dpi; int msg = w.ToInt32();
                if (msg == 0x0200) { ptrX = px; ptrY = py; if (hold != 0) { MoveHold(px, py); } else { UpdateHover(px, py); } return Native.CallNextHookEx(hook, code, w, l); }
                if (msg == 0x0201) { if (BeginHold(px, py)) return (IntPtr)1; return Native.CallNextHookEx(hook, code, w, l); }
                if (msg == 0x0202) { if (hold != 0) { EndHold(); return (IntPtr)1; } return Native.CallNextHookEx(hook, code, w, l); }
            }
            return Native.CallNextHookEx(hook, code, w, l);
        }
        bool OverSnowman(double px, double py, double g) { return smState == 5 && Math.Abs(px - smX) < 42 && py > g - 130 && py < g + 6; }
        bool OverTower(double px, double py, double g) { return tower.Count > 0 && Math.Abs(px - towerX) < 40 && py > g - 150 && py < g + 6; }
        int FreeHit(double px, double py) { for (int i = 0; i < free.Count; i++) { Ball f = free[i]; double dx = px - f.x, dy = py - f.y; if (Math.Sqrt(dx * dx + dy * dy) < f.r + 6) return i; } return -1; }
        bool OverPlow(double px, double py, double g) { return PlowOn && plowActive && px > plowX - 8 && px < plowX + PL + 14 && py > g - 54 && py < g + 6; }
        bool InZone(double py, double g) { return py > g - 70 && py < g - 1; }
        void UpdateHover(double px, double py)
        {
            double g = ActorGround(); hover = 0; hoverIndex = -1;
            if (UiUnderCursor()) return;
            if (OverSnowman(px, py, g)) { hover = 1; return; }
            if (OverTower(px, py, g)) { hover = 2; return; }
            int i = FreeHit(px, py); if (i >= 0) { hover = 3; hoverIndex = i; return; }
            if (OverPlow(px, py, g)) { hover = 5; return; }
            double top, depth;
            if (SnowHit(px, py, out top, out depth) && SnowUiAllowed()) { hover = 4; hoverTop = top; hoverH = depth; }
        }
        bool BeginHold(double px, double py)
        {
            double g = ActorGround(); holdMoved = false; hover = 0; hoverIndex = -1;
            if (UiUnderCursor()) return false;
            if (OverSnowman(px, py, g)) { hold = 1; holdOff = px - smX; return true; }
            if (OverTower(px, py, g)) { hold = 2; holdOff = px - towerX; return true; }
            int i = FreeHit(px, py); if (i >= 0) { hold = 3; held = free[i]; free.RemoveAt(i); return true; }
            if (OverPlow(px, py, g)) { hold = 5; return true; }
            double top, depth;
            if (SnowHit(px, py, out top, out depth) && SnowUiAllowed())
            {
                if (Manual == 1) { hold = 4; held = new Ball(); held.x = px; held.r = 8; held.y = g - 8; holdLastX = px; return true; }
                SummonPlow(); return false;
            }
            return false;
        }
        void MoveHold(double px, double py)
        {
            holdMoved = true; double g = ActorGround();
            if (hold == 1) smX = Clamp(px - holdOff, 40, W - 40);
            else if (hold == 2) towerX = Clamp(px - holdOff, 40, W - 40);
            else if (hold == 3) { held.x = px; held.y = py; }
            else if (hold == 4)
            {
                double dx = px - holdLastX; held.x = px; double take = 0; Surface tb;
                if (hmap.TryGetValue("taskbar", out tb)) { int ci = (int)Math.Floor((px - tb.x) / 4); if (ci >= 0 && ci < tb.cols) { take = Math.Min(tb.h[ci], 2); tb.h[ci] -= take; } }
                held.r = Math.Min(40, held.r + Math.Abs(dx) * (Grow / 100) + take * 0.05); held.y = g - held.r; held.rot += dx / Math.Max(6, held.r); holdLastX = px;
            }
        }
        void EndHold()
        {
            if (hold == 1 && !holdMoved) { smWobV += 7; smWave = 1.6; Jingle(); }
            else if (hold == 5) { plowHonk = 1; Play(honkPlayer); }
            else if (hold == 3 || hold == 4) { if (held != null) TryStack(held); }
            hold = 0; held = null;
        }
        void SortTower() { tower.Sort(delegate(Ball a, Ball b) { return b.r.CompareTo(a.r); }); double g = ActorGround(), yy = g; for (int i = 0; i < tower.Count; i++) { Ball b = tower[i]; b.x = towerX; b.y = yy - b.r; yy = b.y - b.r * 0.78; } }
        void TryStack(Ball b)
        {
            double g = ActorGround();
            if (tower.Count > 0 && tower.Count < 3) { Ball top = tower[tower.Count - 1]; if (Math.Abs(b.x - towerX) < (b.r + top.r) * 0.9 && b.y < top.y) { tower.Add(b); SortTower(); Play(popPlayer); if (tower.Count >= 3) Promote(); return; } }
            for (int i = 0; i < free.Count; i++) { Ball f = free[i]; if (Math.Abs(b.x - f.x) < (b.r + f.r) * 0.9 && b.y < f.y - f.r * 0.2) { free.RemoveAt(i); tower = new List<Ball>(); tower.Add(b); tower.Add(f); towerX = f.x; SortTower(); Play(popPlayer); return; } }
            b.y = g - b.r; free.Add(b); Play(popPlayer);
        }
        void Promote() { smBalls = new List<Ball>(tower); smX = towerX; tower.Clear(); smState = 4; smDec = 0; Jingle(); Events.Enqueue("ready"); }
        public void Disassemble() { double g = ActorGround(); if (smState == 5 || smState == 4) { foreach (Ball b in smBalls) { b.x = smX + R(-14, 14); b.y = g - b.r; free.Add(b); } smBalls.Clear(); smState = 0; Play(shakePlayer); } }
        public void ClearBalls() { foreach (Ball b in free) Poof(b.x, b.y, 8, 80); foreach (Ball b in tower) Poof(b.x, b.y, 8, 80); free.Clear(); tower.Clear(); Play(shakePlayer); }
        // ---- поверхности ----
        bool EnumCallback(IntPtr h, IntPtr l) { if (!Native.IsWindowVisible(h) || Native.IsIconic(h)) return true; uint pid; Native.GetWindowThreadProcessId(h, out pid); if (pid == myPid) return true; var sb = new StringBuilder(64); Native.GetClassName(h, sb, 64); string cls = sb.ToString(); if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return true; int cloaked; if (Native.DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true; if (Native.GetWindowTextLength(h) == 0) return true; RECT r; if (Native.DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) Native.GetWindowRect(h, out r); double x = (r.L - vx) / dpi, y = (r.T - vy) / dpi, w = (r.R - r.L) / dpi; if (w < 90 || y < -40 || y > H || x > W || x + w < 0) return true; AddSurface("w" + h.ToInt64(), x, y, w, 17, true); return true; }
        void AddSurface(string id, double x, double y, double w, double max, bool win) { Surface s; if (!hmap.TryGetValue(id, out s)) { s = new Surface(); s.id = id; s.cols = Math.Max(2, (int)Math.Ceiling(w / 4)); s.h = new double[s.cols]; s.x = x; s.y = y; s.w = w; s.max = max; s.win = win; s.px = x; s.py = y; hmap[id] = s; } if (Math.Abs(s.w - w) > 2) { Shed(s, 1); s.cols = Math.Max(2, (int)Math.Ceiling(w / 4)); s.h = new double[s.cols]; s.w = w; } if (win && (Math.Abs(x - s.px) + Math.Abs(y - s.py)) > 3) Shed(s, 0.75); s.x = x; s.y = y; s.px = x; s.py = y; surfaces.Add(s); }
        void BuildSurfaces() { surfaces.Clear(); vx = Native.GetSystemMetrics(76); vy = Native.GetSystemMetrics(77); IntPtr tb = Native.FindWindow("Shell_TrayWnd", null); if (tb != IntPtr.Zero) { RECT r; Native.GetWindowRect(tb, out r); double x = (r.L - vx) / dpi, y = (r.T - vy) / dpi, w = (r.R - r.L) / dpi, h = (r.B - r.T) / dpi; if (w > h) AddSurface("taskbar", x, y, w, 26, false); } Native.EnumWindows(enumProc, IntPtr.Zero); var dead = new List<string>(); foreach (var kv in hmap) if (!surfaces.Contains(kv.Value)) dead.Add(kv.Key); foreach (var id in dead) { Shed(hmap[id], 1); hmap.Remove(id); } surfaces.Sort(delegate(Surface a, Surface b) { return a.y.CompareTo(b.y); }); }
        void Shed(Surface s, double f) { for (int i = 0; i < s.cols; i += 2) { double hh = s.h[i]; if (hh > 1.2 && parts.Count < PCap()) parts.Add(NewPart(s.x + i * 4, s.y - hh * R(0.2, 0.9), R(-30, 30) + Wind * 0.4, R(10, 60), 420, R(0.7, 1.4), R(1.5, 3.2), 0)); s.h[i] *= 1 - f; } }
        int PCap() { return Quality == 2 ? 700 : Quality == 1 ? 450 : 250; }
        int FBase() { return Quality == 2 ? 400 : Quality == 1 ? 240 : 130; }
        Particle NewPart(double x, double y, double a, double b, double g, double life, double size, int type) { var p = new Particle(); p.x = x; p.y = y; p.vx = a; p.vy = b; p.g = g; p.life = life; p.max = life; p.size = size; p.type = type; return p; }
        void Poof(double x, double y, int n, double spd) { for (int i = 0; i < n && parts.Count < PCap(); i++) { double a = R(0, 6.28), v = R(20, spd); parts.Add(NewPart(x, y, Math.Cos(a) * v, Math.Sin(a) * v - 30, 150, R(0.4, 0.9), R(2, 5), 1)); } }
        Flake NewFlake(bool top) { var f = new Flake(); double z = rnd.NextDouble(); f.x = R(-30, W + 30); f.y = top ? R(-140, -10) : R(-H * 0.3, H); f.z = z; f.vy = (26 + z * 72) * R(0.8, 1.2); f.ph = R(0, 7); f.rot = R(0, 7); f.vr = R(-1, 1); f.sp = z > 0.62 ? RI(0, 7) : -1; f.sz = 5 + z * 24; return f; }
        public void Burst() { Play(whooshPlayer); for (int i = 0; i < 230; i++) { var f = NewFlake(true); f.burst = true; f.y = R(-160, -5); flakes.Add(f); } }
        public void ShakeAll() { Play(shakePlayer); foreach (var s in surfaces) Shed(s, 1); if (smState == 5 || smState == 4) Disassemble(); plowHonk = Math.Max(plowHonk, 0.5); Events.Enqueue("shake"); }
        public void CallSnowman() { SnowmanOn = true; Manual = 0; if (smState == 0) { smCd = 0; StartSnowman(); Events.Enqueue("build"); } }
        void UpdateFlakes(double dt) { int target = (int)(FBase() * (0.12 + 0.88 * Intensity / 100) * Clamp(W * H / (1440 * 900), 0.5, 1.4)); int spawn = Math.Min(6, target - flakes.Count); while (spawn-- > 0) flakes.Add(NewFlake(true)); if (flakes.Count > target + 30) flakes.RemoveRange(target, flakes.Count - target); double sf = FlakeSize / 100; for (int i = flakes.Count - 1; i >= 0; i--) { var f = flakes[i]; double sway = Math.Sin(T * 1.3 + f.ph) * (7 + f.z * 13); double vxx = Wind * 1.05 * (0.3 + f.z * 0.9) + sway, py = f.y; f.y += f.vy * dt * (0.75 + 0.45 * sf); f.x += vxx * dt; f.rot += f.vr * dt; if (f.x < -40) f.x = W + 38; else if (f.x > W + 40) f.x = -38; bool landed = false; foreach (var s in surfaces) { if (f.x < s.x - 2 || f.x > s.x + s.w + 2) continue; int ci = (int)Clamp(Math.Floor((f.x - s.x) / 4), 0, s.cols - 1); double top = s.y - s.h[ci]; if (py < top && f.y >= top) { s.h[ci] = Math.Min(s.max, s.h[ci] + 0.4 * (0.5 + f.z) * sf); landed = true; break; } } if (landed || f.y > H + 30) { if (f.burst) flakes.RemoveAt(i); else { var nf = NewFlake(true); nf.y = R(-60, -10); flakes[i] = nf; } } } }
        void Deposit(double dt) { double dust = (Accum / 100) * 1.15 * (0.3 + 0.7 * Intensity / 100); int wdir = Wind < 0 ? -1 : 1; double wmag = Math.Abs(Wind) / 100; foreach (var s in surfaces) { double[] h = s.h; int n = s.cols; for (int i = 0; i < n; i++) { h[i] = Math.Min(s.max, h[i] + dust * dt * R(0.6, 1.4)); if (wmag > 0.05 && h[i] > 2) { int j = i + wdir; if (j >= 0 && j < n) { double tr = h[i] * wmag * 0.22 * dt; h[i] -= tr; h[j] = Math.Min(s.max, h[j] + tr); } } } double k = Math.Min(0.5, 2.4 * dt); for (int i = 1; i < n - 1; i++) h[i] += ((h[i - 1] + h[i + 1]) / 2 - h[i]) * k; } }
        void UpdateParts(double dt) { double ground = ActorGround(); for (int i = parts.Count - 1; i >= 0; i--) { var p = parts[i]; p.life -= dt; if (p.life <= 0) { parts.RemoveAt(i); continue; } p.vy += p.g * dt; p.vx += (Wind * 0.3 - p.vx * 0.1) * dt * 0.3; p.x += p.vx * dt; p.y += p.vy * dt; if (p.type == 0 && p.y >= ground - 1) { Surface tb; if (hmap.TryGetValue("taskbar", out tb)) { int ci = (int)Clamp(Math.Floor((p.x - tb.x) / 4), 0, tb.cols - 1); tb.h[ci] = Math.Min(tb.max, tb.h[ci] + 0.15); } parts.RemoveAt(i); } } }
        void UpdatePlow(double dt)
        {
            if (!PlowOn) { plowActive = false; return; }
            if (!plowActive) { plowWait += dt; if (plowWait >= PlowInterval) { plowWait = 0; SummonPlow(); } return; }
            double ground = ActorGround(), sp = 22 + PlowSpeed * 1.3;
            if (plowPause > 0) plowPause -= dt;
            else
            {
                if (PlowObstacle()) { return; }
                plowX += plowDir * sp * dt; plowWheel += sp * dt / 10;
                Surface tb;
                if (hmap.TryGetValue("taskbar", out tb))
                {
                    double front = plowDir > 0 ? plowX + PL + 6 : plowX - 6; double removed = 0;
                    for (int d = 0; d < 14; d++) { int ci = (int)Math.Floor((front + plowDir * d - tb.x) / 4); if (ci >= 0 && ci < tb.cols) { removed += tb.h[ci]; tb.h[ci] = 0; } }
                    int mi = (int)Math.Floor((front + plowDir * 17 - tb.x) / 4);
                    if (mi >= 0 && mi < tb.cols && removed > 0) tb.h[mi] = Math.Min(32, tb.h[mi] + removed * 0.55);
                    plowPush = plowPush * 0.85 + removed * 0.4;
                    if (removed > 0.5) for (int k = 0; k < Math.Min(3, removed * 0.5) && parts.Count < PCap(); k++) parts.Add(NewPart(front + plowDir * R(0, 8), ground - R(4, 20), plowDir * R(30, 90), R(-120, -40), 430, R(0.5, 1), R(1.4, 3), 0));
                }
                plowTrail += sp * dt;
                if (plowTrail > 7) { plowTrail = 0; trails.Add(new double[] { plowX + (plowDir > 0 ? 26 : PL - 26), ground + 3, 4 }); if (trails.Count > 160) trails.RemoveAt(0); }
                plowEx -= dt;
                if (plowEx <= 0) { plowEx = 0.32; parts.Add(NewPart(plowX + (plowDir > 0 ? 58 : PL - 58), ground - 40, R(-4, 4), R(-26, -16), -6, R(0.8, 1.5), R(2.5, 4), 3)); }
                if (plowDir > 0 && plowX > W + 50) { plowActive = false; plowWait = 0; }
                if (plowDir < 0 && plowX < -PL - 50) { plowActive = false; plowWait = 0; }
            }
            plowHonk = Math.Max(0, plowHonk - dt);
            for (int i = trails.Count - 1; i >= 0; i--) { trails[i][2] -= dt; if (trails[i][2] <= 0) trails.RemoveAt(i); }
        }
        bool PlowObstacle()
        {
            double g = ActorGround();
            double front = plowDir > 0 ? plowX + PL + 10 : plowX - 10;
            bool hit = false;
            for (int i = free.Count - 1; i >= 0; i--) { Ball b = free[i]; if (Math.Abs(b.x - front) < b.r + 12) { hit = true; if (PlowClears) { Poof(b.x, b.y, 14, 110); AddSnowAt(b.x, b.r * 0.5); free.RemoveAt(i); } } }
            if (tower.Count > 0 && Math.Abs(towerX - front) < 46) { hit = true; if (PlowClears) { foreach (Ball b in tower) { Poof(b.x, b.y, 14, 110); AddSnowAt(b.x, b.r * 0.5); } tower.Clear(); } }
            if ((smState == 5 || smState == 4) && Math.Abs(smX - front) < 48) { hit = true; if (PlowClears) { foreach (Ball b in smBalls) { Poof(smX, b.y, 18, 130); AddSnowAt(smX, b.r * 0.5); } smBalls.Clear(); smState = 0; smCd = 20; smIdle = 0; } }
            if (!hit) return false;
            if (PlowClears) { Play(shakePlayer); Events.Enqueue("plowed"); return false; }
            plowDir = -plowDir; plowPause = 1.0; plowHonk = 0.9; Play(honkPlayer); plowX += plowDir * 8;
            return true;
        }
        void AddSnowAt(double x, double amount) { Surface tb; if (hmap.TryGetValue("taskbar", out tb)) { int ci = (int)Math.Floor((x - tb.x) / 4); for (int d = -2; d <= 2; d++) { int j = ci + d; if (j >= 0 && j < tb.cols) tb.h[j] = Math.Min(tb.max, tb.h[j] + amount); } } }
        void StartSnowman() { smState = 1; smX = R(W * 0.32, W * 0.55); smBalls.Clear(); smRollX = -30; smRollR = 6; smRollTR = 26; smStage = 1; }
        void UpdateSnowman(double dt)
        {
            double ground = ActorGround();
            for (int i = 0; i < free.Count; i++) { free[i].y = ground - free[i].r; }
            if (tower.Count > 0) SortTower();
            if (Manual == 1) { if (smState == 4) { smDec += dt / 1.5; if (smDec >= 1) { smState = 5; smFirst = 1; } } else if (smState == 5) { AliveAnim(dt); } return; }
            if (!SnowmanOn) { if (smState == 5 || smState == 4) Disassemble(); smState = 0; return; }
            smCd = Math.Max(0, smCd - dt);
            if (smState == 0) { smIdle += dt; double avg = 0; Surface tb; if (hmap.TryGetValue("taskbar", out tb)) { for (int i = 0; i < tb.cols; i++) avg += tb.h[i]; avg /= tb.cols; } if (smCd <= 0 && (avg > 7 || smIdle > (smFirst == 1 ? 45 : 14))) { smIdle = 0; StartSnowman(); } return; }
            if (smState == 1) { smRollX += 95 * dt; Surface tb; if (hmap.TryGetValue("taskbar", out tb)) for (int d = -1; d <= 1; d++) { int ci = (int)Math.Floor((smRollX + d * smRollR * 0.6 - tb.x) / 4); if (ci >= 0 && ci < tb.cols) { double take = Math.Min(tb.h[ci], 26 * dt); tb.h[ci] -= take; smRollR += take * 0.05; } } smRollR = Math.Min(smRollTR, smRollR + dt * 4.2); double stopX = smX; if (smStage > 1 && smBalls.Count > 0) stopX = smX - (smBalls[0].r + smRollTR) * 0.9; if (smRollX >= stopX) { smRollX = stopX; smRollR = smRollTR; if (smStage == 1) { var b = new Ball(); b.r = smRollTR; b.y = ground - b.r; b.rot = R(0, 7); smBalls.Add(b); smState = 2; smWait = 0.55; smStage = 2; } else { Ball below = smBalls[smBalls.Count - 1]; smArcY0 = ground - smRollTR; smArcY1 = below.y - below.r * 0.78 - smRollTR * 0.82; smArcT = 0; smState = 3; } } return; }
            if (smState == 2) { smWait -= dt; if (smWait <= 0) { smState = 1; smRollX = -30; smRollR = 5; smRollTR = smStage == 2 ? 18 : 13; } return; }
            if (smState == 3) { smArcT += dt / 0.55; if (smArcT >= 1) { var b = new Ball(); b.r = smRollTR; b.y = smArcY1; b.rot = R(0, 7); smBalls.Add(b); smLand = 0.3; Play(popPlayer); Poof(smX, b.y + b.r * 0.6, 8, 60); if (smStage == 2) { smStage = 3; smState = 2; smWait = 0.55; } else { smState = 4; smDec = 0; } } return; }
            if (smState == 4) { smDec += dt / 1.5; if (smDec >= 1) { smState = 5; smFirst = 1; Jingle(); Events.Enqueue("ready"); for (int i = 0; i < 10; i++) parts.Add(NewPart(smX + R(-30, 30), ground - R(30, 110), R(-20, 20), R(-40, -10), 30, R(0.6, 1.2), R(3, 6), 2)); } return; }
            if (smState == 5) AliveAnim(dt);
        }
        void AliveAnim(double dt) { smBlinkT -= dt; if (smBlinkT <= 0) { smBlink = 0.14; smBlinkT = R(2.5, 6); } smBlink = Math.Max(0, smBlink - dt); smWaveT -= dt; if (smWaveT <= 0) { smWave = 1.6; smWaveT = R(10, 18); } smWave = Math.Max(0, smWave - dt); smWobV += (-smWob * 42 - smWobV * 4.5) * dt; smWob += smWobV * dt; smLand = Math.Max(0, smLand - dt); }
        void OnFrame(object sender, EventArgs e) { double now = clock.Elapsed.TotalSeconds; double interval = Quality == 2 ? 1.0 / 60 : Quality == 1 ? 1.0 / 45 : 1.0 / 30; if (now - lastFrame < interval) return; double dt = Math.Min(0.06, now - lastFrame); lastFrame = now; if (Paused) return; W = ActualWidth; H = ActualHeight; if (W < 10 || H < 10) return; var src = PresentationSource.FromVisual(this); if (src != null && src.CompositionTarget != null) dpi = src.CompositionTarget.TransformToDevice.M11; if (dpi <= 0) dpi = 1; T += dt; POINT cp; if (Native.GetCursorPos(out cp)) { ptrX = (cp.X - vx) / dpi; ptrY = (cp.Y - vy) / dpi; } if (hold == 0) UpdateHover(ptrX, ptrY); surfTimer -= dt; if (surfTimer <= 0) { surfTimer = 0.25; BuildSurfaces(); } Deposit(dt); UpdateFlakes(dt); UpdatePlow(dt); UpdateSnowman(dt); UpdateActors(dt); UpdateParts(dt); garLit = Math.Min(1, garLit + dt / 2.5); InvalidateVisual(); }
        protected override void OnRender(DrawingContext dc) { if (W < 10) return; if (FrostOn) DrawFrost(dc); if (Garland > 0) DrawGarland(dc); DrawPiles(dc); Pen trPen = new Pen(B("#9db4dd"), 1.4); trPen.Freeze(); foreach (var tr in trails) { dc.PushOpacity(tr[2] / 4 * 0.4); dc.DrawLine(trPen, new Point(tr[0] - 3, tr[1]), new Point(tr[0] + 3, tr[1])); dc.DrawLine(trPen, new Point(tr[0] - 3, tr[1] + 4), new Point(tr[0] + 3, tr[1] + 4)); dc.Pop(); } DrawManual(dc); DrawPlow(dc); DrawSnowmanScene(dc); DrawActors(dc); DrawParts(dc); DrawFlakes(dc); }
        void DrawFrost(DrawingContext dc)
        {
            if (frostGeo == null) BuildFrost();
            dc.PushOpacity(0.34);
            dc.DrawGeometry(null, frostPen, frostGeo);
            dc.PushTransform(new MatrixTransform(-1, 0, 0, 1, W, 0)); dc.DrawGeometry(null, frostPen, frostGeo); dc.Pop();
            dc.PushTransform(new MatrixTransform(1, 0, 0, -1, 0, H)); dc.DrawGeometry(null, frostPen, frostGeo); dc.Pop();
            dc.PushTransform(new MatrixTransform(-1, 0, 0, -1, W, H)); dc.DrawGeometry(null, frostPen, frostGeo); dc.Pop();
            dc.Pop();
        }
        void DrawGarland(DrawingContext dc)
        {
            Brush[] bulbs = Garland == 2 ? warmBulb : Garland == 3 ? iceBulb : garBulb;
            Brush[] glows = Garland == 2 ? warmGlow : Garland == 3 ? iceGlow : garGlow;
            int cn = bulbs.Length; Pen cable = P("#232c4a", 1.8), sheen = P("#5a6a9c", 0.6);
            double span = 150; int n = (int)Math.Ceiling(W / span); int idx = 0, total = n * 6;
            for (int k = 0; k < n; k++)
            {
                double x0 = k * span, x1 = Math.Min(W, x0 + span), sag = 22 + Math.Sin(k * 1.7) * 5, cx = (x0 + x1) / 2;
                var g = new StreamGeometry();
                using (var c = g.Open()) { c.BeginFigure(new Point(x0, 3), false, false); c.QuadraticBezierTo(new Point(cx, 3 + sag * 2), new Point(x1, 3), true, false); }
                g.Freeze(); dc.DrawGeometry(null, cable, g); dc.DrawGeometry(null, sheen, g);
                dc.DrawRoundedRectangle(B("#3a4670"), null, new Rect(x0 - 2.5, 0, 5, 5), 1.5, 1.5);
                int nb = Math.Max(3, (int)((x1 - x0) / 26));
                for (int b = 0; b < nb; b++)
                {
                    double t = (b + 0.5) / nb; double bx = (1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * cx + t * t * x1; double by = (1 - t) * (1 - t) * 3 + 2 * (1 - t) * t * (3 + sag * 2) + t * t * 3 + 4;
                    idx++; if (idx / (double)total > garLit) continue;
                    double br = 0.55 + 0.45 * Math.Sin(T * 2.3 + k * 9 + b * 1.3); int ci = (k * 9 + b) % cn; double gr = 10 + br * 5;
                    dc.DrawEllipse(glows[ci], null, new Point(bx, by + 1), gr, gr);
                    dc.DrawRoundedRectangle(B("#1a2038"), null, new Rect(bx - 1.9, by - 3.6, 3.8, 4.2), 1.2, 1.2);
                    dc.DrawEllipse(bulbs[ci], null, new Point(bx, by + 2.4), 2.9, 4.0);
                    dc.PushOpacity(0.25 + 0.5 * br); dc.DrawEllipse(B("#ffffff"), null, new Point(bx, by + 2.8), 1.5, 2.3); dc.Pop();
                    dc.DrawEllipse(B("#c0ffffff"), null, new Point(bx - 1.0, by + 1.3), 0.9, 1.3);
                }
            }
        }
        void PileTop(StreamGeometryContext c, Point[] pts)
        {
            int n = pts.Length;
            for (int i = 0; i < n - 1; i++)
            {
                Point p0 = pts[i > 0 ? i - 1 : 0], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2 < n ? i + 2 : n - 1];
                c.BezierTo(new Point(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6), new Point(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6), p2, true, true);
            }
        }
        void DrawPiles(DrawingContext dc)
        {
            Pen top = P("#ffffff", 1.4), under = P("#80a9c0e6", 1.6);
            foreach (var s in surfaces)
            {
                double mx = 0; for (int i = 0; i < s.cols; i++) if (s.h[i] > mx) mx = s.h[i];
                if (mx < 0.4) continue;
                Point[] pts = new Point[s.cols];
                for (int i = 0; i < s.cols; i++) pts[i] = new Point(s.x + i * 4 + 2, s.y - s.h[i]);
                var g = new StreamGeometry();
                using (var c = g.Open()) { c.BeginFigure(new Point(s.x - 3, s.y + 2), true, true); c.LineTo(pts[0], true, false); PileTop(c, pts); c.LineTo(new Point(s.x + s.w + 3, s.y + 2), true, false); }
                g.Freeze(); dc.DrawGeometry(pileBrush, null, g);
                var tg = new StreamGeometry();
                using (var c = tg.Open()) { c.BeginFigure(pts[0], false, false); PileTop(c, pts); }
                tg.Freeze();
                dc.PushTransform(new TranslateTransform(0, 2.4)); dc.DrawGeometry(null, under, tg); dc.Pop();
                dc.DrawGeometry(null, top, tg);
                for (int i = 3; i < s.cols - 3; i += 4)
                {
                    if (s.h[i] < 2.5) continue;
                    double ph = Math.Sin(T * 2.4 + i * 1.93 + s.x * 0.037); if (ph < 0.965) continue;
                    double k = (ph - 0.965) / 0.035, rr = 1.2 + 2.6 * k, sx = pts[i].X, sy = pts[i].Y + 2.4 + (i % 3);
                    Pen glowPen = P("#907fd8ff", 0.8), starPen = P("#ffffff", 0.9);
                    dc.DrawLine(glowPen, new Point(sx - rr - 1.2, sy), new Point(sx + rr + 1.2, sy)); dc.DrawLine(glowPen, new Point(sx, sy - rr - 1.2), new Point(sx, sy + rr + 1.2));
                    dc.DrawLine(starPen, new Point(sx - rr, sy), new Point(sx + rr, sy)); dc.DrawLine(starPen, new Point(sx, sy - rr), new Point(sx, sy + rr));
                }
            }
        }
        void DrawManual(DrawingContext dc)
        {
            double g = ActorGround();
            foreach (Ball b in free) DrawBall(dc, b.x, b.y, b.r, b.rot);
            foreach (Ball b in tower) DrawBall(dc, b.x, b.y, b.r, b.rot);
            if (held != null && (hold == 3 || hold == 4)) DrawBall(dc, held.x, held.y, held.r, held.rot);
            Pen ring = new Pen(ice, 1.6); ring.DashStyle = DashStyles.Dash;
            if (hover == 3 && hoverIndex >= 0 && hoverIndex < free.Count) { Ball f = free[hoverIndex]; dc.DrawEllipse(null, ring, new Point(f.x, f.y), f.r + 5, f.r + 5); }
            else if (hover == 1) dc.DrawEllipse(null, ring, new Point(smX, g - 62), 46, 66);
            else if (hover == 2) dc.DrawEllipse(null, ring, new Point(towerX, g - 60), 44, 64);
            else if (hover == 4)
            {
                double cy = hoverTop + hoverH / 2; double ry = Math.Max(3.5, hoverH / 2 + 2.5);
                dc.PushOpacity(0.3); dc.DrawEllipse(snowNear, null, new Point(ptrX, cy), 18, ry); dc.Pop();
                dc.DrawEllipse(null, ring, new Point(ptrX, cy), 18, ry);
            }
            if (smState != 5)
            {
                string line1 = Manual == 1 ? "Ручной режим: зажми ЛКМ на сугробе у панели и веди — ком растёт. Отпусти — ком останется." : "Клик по сугробу внизу экрана — вызвать снегоуборщик. Сам он выезжает каждые " + ((int)PlowInterval) + " с.";
                string line2 = Manual == 1 ? "Перетащи ком на ком — сложатся. Три кома = снеговик. Готового снеговика можно двигать." : "Снегоуборщик уберёт сугробы и уедет. Ручной режим включается в настройках.";
                var f1 = new FormattedText(line1, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, hintFace, 12, ice);
                var f2 = new FormattedText(line2, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, hintFace, 12, ice);
                dc.PushOpacity(0.85); dc.DrawText(f1, new Point(16, g - 104)); dc.DrawText(f2, new Point(16, g - 88)); dc.Pop();
                var f3 = new FormattedText("Башня: " + tower.Count + " / 3   Комьев: " + free.Count, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, hintFace, 12, snowTop);
                dc.DrawText(f3, new Point(16, g - 70));
            }
        }
        void DrawParts(DrawingContext dc) { foreach (var p in parts) { double lf = Clamp(p.life / p.max, 0, 1); if (p.type == 3) { dc.PushOpacity(0.25 * lf); dc.DrawEllipse(B("#bec8dc"), null, new Point(p.x, p.y), p.size + (1 - lf) * 9, p.size + (1 - lf) * 9); dc.Pop(); } else if (p.type == 2) { dc.PushOpacity(lf); dc.DrawEllipse(glowAmber, null, new Point(p.x, p.y), p.size * 2, p.size * 2); dc.Pop(); } else { dc.PushOpacity(0.9 * lf); dc.DrawEllipse(snowNear, null, new Point(p.x, p.y), p.size, p.size); dc.Pop(); } } }
        void DrawFlakes(DrawingContext dc)
        {
            double sf = FlakeSize / 100;
            foreach (var f in flakes)
            {
                double sz = f.sz * sf;
                if (f.sp >= 0 && Quality > 0)
                {
                    double s = sz / 22, ca = Math.Cos(f.rot) * s, sa = Math.Sin(f.rot) * s;
                    double th = Math.Max(0.8, Math.Min(1.7, sz * 0.09)) / s;
                    Pen pn = new Pen(snowNear, th); pn.StartLineCap = PenLineCap.Round; pn.EndLineCap = PenLineCap.Round; pn.LineJoin = PenLineJoin.Round;
                    dc.PushOpacity(0.6 + f.z * 0.4);
                    dc.PushTransform(new MatrixTransform(ca, sa, -sa, ca, f.x, f.y));
                    if (Quality > 1) dc.DrawEllipse(B("#30ffffff"), null, new Point(0, 0), 3.2, 3.2);
                    dc.DrawGeometry(null, pn, crystals[f.sp]);
                    dc.Pop(); dc.Pop();
                }
                else if (f.z > 0.45)
                {
                    dc.PushOpacity(0.5 + f.z * 0.4); dc.DrawEllipse(snowMid, null, new Point(f.x, f.y), sz / 2, sz / 2);
                    dc.DrawEllipse(snowTop, null, new Point(f.x - sz * 0.12, f.y - sz * 0.12), sz * 0.18, sz * 0.18); dc.Pop();
                }
                else { dc.PushOpacity(0.3 + f.z * 0.5); dc.DrawRectangle(snowFar, null, new Rect(f.x, f.y, sz * 0.4, sz * 0.4)); dc.Pop(); }
            }
        }
        void DrawPlow(DrawingContext dc)
        {
            if (!PlowOn || !plowActive) return;
            double ground = ActorGround() - (plowHonk > 0 ? Math.Sin(plowHonk * Math.PI * 3) * 4 : 0);
            dc.PushTransform(new TranslateTransform(plowX, ground));
            if (plowDir < 0) { dc.PushTransform(new TranslateTransform(PL, 0)); dc.PushTransform(new ScaleTransform(-1, 1)); }
            dc.PushOpacity(0.55); dc.DrawEllipse(B("#3c4a70"), null, new Point(PL / 2, 2), PL * 0.55, 4.5); dc.Pop();
            var cone = new StreamGeometry();
            using (var c = cone.Open()) { c.BeginFigure(new Point(86, -12), true, true); c.LineTo(new Point(172, -26), true, false); c.LineTo(new Point(172, 4), true, false); c.LineTo(new Point(86, -4), true, false); }
            cone.Freeze(); dc.PushOpacity(0.13); dc.DrawGeometry(B("#ffdc96"), null, cone); dc.Pop();
            if (plowPush > 0.4)
            {
                double ph = Math.Min(22, plowPush * 2.2); var curl = new StreamGeometry();
                using (var c = curl.Open()) { c.BeginFigure(new Point(96, 0), true, true); c.QuadraticBezierTo(new Point(104, -ph), new Point(94, -ph - 4), true, false); c.QuadraticBezierTo(new Point(112, -ph * 0.6), new Point(110, 0), true, false); }
                curl.Freeze(); dc.DrawGeometry(snowNear, P("#cfdaf0", 0.7), curl);
            }
            dc.DrawLine(P("#5d6f96", 3.4), new Point(74, -8), new Point(92, -16)); dc.DrawLine(P("#c7d3e8", 1.4), new Point(74, -9), new Point(92, -17));
            dc.DrawLine(P("#3d4a6b", 3.0), new Point(70, -20), new Point(91, -24)); dc.DrawLine(P("#aebbd6", 1.2), new Point(78, -21.5), new Point(91, -24.5));
            var blade = new StreamGeometry();
            using (var c = blade.Open()) { c.BeginFigure(new Point(88, -2), true, true); c.LineTo(new Point(90, -30), true, false); c.QuadraticBezierTo(new Point(100, -26), new Point(103, -2), true, false); }
            blade.Freeze(); dc.DrawGeometry(bladeBrush, P("#4f628a", 0.9), blade);
            Pen rib = P("#90e8f1ff", 0.9);
            dc.DrawLine(rib, new Point(92, -6), new Point(92.6, -26)); dc.DrawLine(rib, new Point(96, -5), new Point(96.8, -24.5)); dc.DrawLine(rib, new Point(100, -4), new Point(100.6, -22));
            dc.DrawRectangle(B("#2b2f3d"), null, new Rect(89.6, -31.4, 12, 2.4)); dc.DrawRectangle(B("#2b2f3d"), null, new Rect(87.5, -3.2, 16.5, 3.2));
            dc.PushOpacity(0.85); for (int i = 0; i < 4; i++) dc.DrawRectangle(i % 2 == 0 ? B("#1c1c22") : B("#ffb02c"), null, new Rect(88 + i * 4, -7, 4, 3.8)); dc.Pop();
            dc.DrawRoundedRectangle(bodyBrush, null, new Rect(14, -34, 46, 26), 5, 5);
            dc.DrawRoundedRectangle(bodyBrush, null, new Rect(58, -22, 28, 14), 4, 4);
            dc.DrawRectangle(B("#40ffffff"), null, new Rect(60, -21.4, 24, 1.3));
            dc.PushOpacity(0.25); dc.DrawRectangle(B("#784600"), null, new Rect(14, -12, 72, 4)); dc.Pop();
            dc.DrawRectangle(B("#70ffe9b8"), null, new Rect(16, -17, 68, 1.2));
            Pen vent = P("#a86a10", 1.2); for (int i = 0; i < 3; i++) dc.DrawLine(vent, new Point(64 + i * 4, -19.6), new Point(64 + i * 4, -14.4));
            dc.DrawRoundedRectangle(B("#2b2f3d"), null, new Rect(84.2, -20, 3.2, 7), 1, 1);
            for (int i = 0; i < 3; i++) dc.DrawLine(P("#8fa2c4", 0.7), new Point(84.4, -18.4 + i * 2.2), new Point(87.2, -18.4 + i * 2.2));
            dc.DrawRoundedRectangle(B("#2b2f3d"), null, new Rect(82, -9.5, 9, 3.6), 1.4, 1.4); dc.DrawRoundedRectangle(B("#2b2f3d"), null, new Rect(9.5, -10, 6, 3.6), 1.4, 1.4);
            for (int i = 0; i < 3; i++) dc.DrawRectangle(i % 2 == 0 ? B("#ffb02c") : B("#1c1c22"), null, new Rect(10 + i * 1.7, -9.7, 1.7, 3));
            dc.DrawRoundedRectangle(glass, P("#a86a10", 1.3), new Rect(20, -30, 32, 16), 3, 3);
            var refl = new StreamGeometry();
            using (var c = refl.Open()) { c.BeginFigure(new Point(22, -29), true, true); c.LineTo(new Point(31, -29), true, false); c.LineTo(new Point(24, -15), true, false); c.LineTo(new Point(22, -15), true, false); }
            refl.Freeze(); dc.PushOpacity(0.24); dc.DrawGeometry(B("#7fd8ff"), null, refl); dc.Pop();
            dc.DrawLine(P("#a86a10", 1.2), new Point(37, -30), new Point(37, -14));
            dc.DrawEllipse(B("#f2c9a6"), null, new Point(40, -20), 4.4, 4.4); dc.DrawEllipse(snowNear, null, new Point(40.4, -17.4), 3.6, 2.3);
            dc.DrawEllipse(B("#20242e"), null, new Point(41.4, -21.2), 0.6, 0.6); dc.DrawEllipse(B("#20242e"), null, new Point(43.2, -21.2), 0.6, 0.6);
            var hatG = new StreamGeometry();
            using (var c = hatG.Open()) { c.BeginFigure(new Point(35.4, -22.5), true, true); c.QuadraticBezierTo(new Point(40, -31), new Point(45, -23.5), true, false); }
            hatG.Freeze(); dc.DrawGeometry(scarf, null, hatG);
            dc.DrawEllipse(snowTop, null, new Point(45, -23.5), 1.7, 1.7); dc.DrawRectangle(snowTop, null, new Rect(35, -23.6, 10, 2));
            dc.DrawRoundedRectangle(snowNear, null, new Rect(12.5, -37, 49, 4.6), 2.3, 2.3);
            for (int i = 0; i < 6; i++) dc.DrawEllipse(snowNear, null, new Point(18 + i * 8, -33), 1.9, 2.2 + (i % 2));
            double bp = plowHonk > 0 ? Math.Abs(Math.Sin(T * 26)) : 0.5 + 0.5 * Math.Sin(T * 6);
            dc.DrawRoundedRectangle(B("#2b2f3d"), null, new Rect(31, -38, 12, 3), 1, 1);
            dc.DrawRoundedRectangle(B("#ff9e2c"), null, new Rect(32, -41, 10, 6), 3, 3); dc.DrawEllipse(B("#b0ffffff"), null, new Point(35, -39.4), 1.3, 0.8);
            dc.PushOpacity(0.35 + 0.65 * bp); dc.DrawEllipse(glowAmber, null, new Point(37, -37), 14, 14); dc.Pop();
            dc.DrawRectangle(steel, null, new Rect(56, -40, 4, 18)); dc.DrawRectangle(B("#c7d3e8"), null, new Rect(55, -42, 6, 3)); dc.DrawRectangle(B("#3b3f4e"), null, new Rect(55.4, -42, 5.2, 1.2));
            dc.DrawLine(P("#e8eefc", 0.8), new Point(57.2, -38), new Point(57.2, -24));
            dc.DrawEllipse(B("#50ffe9b8"), null, new Point(85, -11), 6, 6); dc.DrawEllipse(B("#fff3d0"), P("#8fa2c4", 0.9), new Point(85, -11), 3.2, 3.2); dc.DrawEllipse(B("#ffffff"), null, new Point(85.4, -11.4), 1.3, 1.3);
            dc.DrawEllipse(B("#40ff5f6d"), null, new Point(13, -17.5), 4.2, 4.2); dc.DrawRectangle(B("#ff5f6d"), null, new Rect(13, -20, 2.6, 5));
            Wheel(dc, 28, 11); Wheel(dc, 72, 9); Fender(dc, 28, 11); Fender(dc, 72, 9);
            if (plowDir < 0) { dc.Pop(); dc.Pop(); }
            dc.Pop();
        }
        void Fender(DrawingContext dc, double wx, double wr)
        {
            var g = new StreamGeometry();
            using (var c = g.Open()) { c.BeginFigure(new Point(wx - wr - 3, -5.5), false, false); c.ArcTo(new Point(wx + wr + 3, -5.5), new Size(wr + 3, wr + 3), 0, false, SweepDirection.Clockwise, true, false); }
            g.Freeze(); dc.DrawGeometry(null, P("#c07a14", 2.4), g);
        }
        void Wheel(DrawingContext dc, double wx, double wr)
        {
            Point wc = new Point(wx, -wr + 2);
            dc.DrawEllipse(B("#14171f"), null, wc, wr, wr);
            dc.PushTransform(new TranslateTransform(wc.X, wc.Y));
            dc.PushTransform(new RotateTransform(plowWheel * (11 / wr) * 57.2958));
            Pen tread = P("#303749", 1.7);
            for (int i = 0; i < 14; i++) { double an = i * Math.PI * 2 / 14; dc.DrawLine(tread, new Point(Math.Cos(an) * (wr - 2.6), Math.Sin(an) * (wr - 2.6)), new Point(Math.Cos(an) * (wr - 0.5), Math.Sin(an) * (wr - 0.5))); }
            dc.DrawEllipse(B("#232838"), null, new Point(0, 0), wr * 0.74, wr * 0.74);
            dc.DrawEllipse(B("#39415c"), P("#aab8d6", 1.0), new Point(0, 0), wr * 0.55, wr * 0.55);
            Pen spoke = P("#c7d3e8", 1.5);
            for (int i = 0; i < 5; i++) { double an = i * Math.PI * 2 / 5; dc.DrawLine(spoke, new Point(0, 0), new Point(Math.Cos(an) * wr * 0.5, Math.Sin(an) * wr * 0.5)); }
            for (int i = 0; i < 5; i++) { double an = i * Math.PI * 2 / 5 + 0.63; dc.DrawEllipse(B("#e8eefc"), null, new Point(Math.Cos(an) * wr * 0.3, Math.Sin(an) * wr * 0.3), 0.7, 0.7); }
            dc.Pop(); dc.Pop();
            dc.DrawEllipse(B("#e8eefc"), null, wc, 1.8, 1.8);
        }
        static double EaseOB(double t) { double c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.Pow(t - 1, 3) + c1 * Math.Pow(t - 1, 2); }
        void DrawBall(DrawingContext dc, double bx, double by, double r, double rot)
        {
            Point ctr = new Point(bx, by);
            dc.DrawEllipse(ballBr, ballPen, ctr, r, r);
            if (r > 7)
            {
                dc.PushTransform(new TranslateTransform(bx, by)); dc.PushTransform(new RotateTransform(rot * 57.2958));
                int cnt = r > 20 ? 14 : 9;
                for (int i = 0; i < cnt; i++)
                {
                    double an = i * 2.39996, rr = r * 0.8 * Math.Sqrt((i + 0.5) / cnt), sz = r * (0.045 + 0.03 * (i % 3)) + 0.4;
                    dc.DrawEllipse(i % 2 == 0 ? B("#608ea6cf") : B("#a0ffffff"), null, new Point(Math.Cos(an) * rr, Math.Sin(an) * rr), sz * 1.3, sz);
                }
                dc.DrawLine(P("#508ea6cf", 0.8), new Point(-r * 0.55, r * 0.15), new Point(-r * 0.25, r * 0.3));
                dc.DrawLine(P("#508ea6cf", 0.8), new Point(r * 0.2, -r * 0.5), new Point(r * 0.5, -r * 0.38));
                dc.Pop(); dc.Pop();
            }
            dc.DrawEllipse(ballShade, null, ctr, r, r);
            dc.PushTransform(new RotateTransform(-35, bx - r * 0.34, by - r * 0.4));
            dc.DrawEllipse(B("#b8ffffff"), null, new Point(bx - r * 0.34, by - r * 0.4), r * 0.26, r * 0.15);
            dc.Pop();
        }
        void DrawSnowmanScene(DrawingContext dc) { double ground = ActorGround(); if (smState == 1) { foreach (var b in smBalls) DrawBall(dc, smX, b.y, b.r, b.rot); DrawBall(dc, smRollX, ground - smRollR, smRollR, smRollX / Math.Max(6, smRollR)); return; } if (smState == 3) { foreach (var b in smBalls) DrawBall(dc, smX, b.y, b.r, b.rot); double t = Clamp(smArcT, 0, 1); double bx = smRollX + (smX - smRollX) * t, by = smArcY0 + (smArcY1 - smArcY0) * t - Math.Sin(Math.PI * t) * 70; DrawBall(dc, bx, by, smRollTR, t * 6); return; } if (smBalls.Count == 0) return; if (smState == 2) { foreach (var b in smBalls) DrawBall(dc, smX, b.y, b.r, b.rot); return; } double dec = smState == 5 ? 1 : smDec; double r1 = smBalls[0].r, r2 = smBalls.Count > 1 ? smBalls[1].r : 18, r3 = smBalls.Count > 2 ? smBalls[2].r : 13; double bob = Math.Sin(T * 2) * 1.6, squash = smLand > 0 ? 1 - Math.Sin(smLand / 0.3 * Math.PI) * 0.12 : 1; double y1 = ground - r1 * squash; double y2 = smBalls.Count > 1 ? smBalls[1].y + bob * 0.4 : y1 - r1 * 0.78 - r2 * 0.82; double y3 = smBalls.Count > 2 ? smBalls[2].y + bob : y2 - r2 * 0.8 - r3 * 0.85; dc.PushTransform(new TranslateTransform(smX, ground)); dc.PushTransform(new RotateTransform(smWob * 2.86)); dc.PushTransform(new TranslateTransform(-smX, -ground)); dc.PushOpacity(0.35); dc.DrawEllipse(B("#3c4a70"), null, new Point(smX, ground + 2), r1 * 1.15, 4); dc.Pop(); DrawBall(dc, smX, y1, r1, 0.4); if (smBalls.Count > 1) DrawBall(dc, smX, y2, r2, 1.7); if (smBalls.Count > 2) DrawBall(dc, smX, y3, r3, 3.1); if (smBalls.Count < 3) { dc.Pop(); dc.Pop(); dc.Pop(); return; } Func<double, double> pop = delegate(double th) { double t = Clamp((dec - th) / 0.12, 0, 1); return t <= 0 ? 0 : EaseOB(t); }; double ap = pop(0.72);
            if (ap > 0)
            {
                Pen arm = P("#5b4230", 3.2), armHi = P("#8a6a4c", 1.1), twig = P("#5b4230", 1.9);
                double waveA = smWave > 0 ? Math.Sin(smWave * 9) * 0.5 - 0.7 : 0;
                for (int side = -1; side <= 1; side += 2)
                {
                    double ax = smX + side * r2 * 0.9, ay = y2 - r2 * 0.1, lift = side > 0 ? waveA : 0;
                    double ex = ax + side * 24 * ap, ey = ay - 15 * ap + lift * 20;
                    double mx = ax + (ex - ax) * 0.55, my = ay + (ey - ay) * 0.55, mx2 = ax + (ex - ax) * 0.3, my2 = ay + (ey - ay) * 0.3;
                    dc.DrawLine(arm, new Point(ax, ay), new Point(ex, ey)); dc.DrawLine(armHi, new Point(ax, ay - 0.9), new Point(ex, ey - 0.9));
                    dc.DrawLine(twig, new Point(mx2, my2), new Point(mx2 + side * 3, my2 + 8 * ap));
                    dc.DrawLine(twig, new Point(mx, my), new Point(mx + side * 4, my - 9 * ap));
                    dc.DrawLine(twig, new Point(ex, ey), new Point(ex + side * 7, ey - 8)); dc.DrawLine(twig, new Point(ex, ey), new Point(ex + side * 8, ey + 1)); dc.DrawLine(twig, new Point(ex, ey), new Point(ex + side * 5, ey + 6));
                }
            }
            double bp = pop(0.42);
            if (bp > 0) for (int i = 0; i < 3; i++) { double bxx = smX, byy = y2 - r2 * 0.5 + i * r2 * 0.5; dc.DrawEllipse(coal, P("#60404a66", 0.8), new Point(bxx, byy), 2.7 * bp, 2.7 * bp); dc.DrawEllipse(B("#a0ffffff"), null, new Point(bxx - 0.8, byy - 0.9), 0.8 * bp, 0.8 * bp); }
            double sp = pop(0.55);
            if (sp > 0)
            {
                double sy0 = y3 + r3 * 0.62;
                dc.DrawRoundedRectangle(scarf, null, new Rect(smX - r3 * 1.05, sy0, r3 * 2.1, 5.5 * sp), 3, 3);
                for (int i = -2; i <= 2; i++) dc.DrawRectangle(scarfDark, null, new Rect(smX + i * r3 * 0.42 - 1.2, sy0, 2.4, 5.5 * sp));
                dc.DrawRectangle(B("#50ffffff"), null, new Rect(smX - r3 * 0.95, sy0 + 0.8, r3 * 1.9, 1.1 * sp));
                double fl = Math.Sin(T * 3.2) * 4 + Wind * 0.06;
                var tail = new StreamGeometry();
                using (var c = tail.Open()) { c.BeginFigure(new Point(smX + r3 * 0.4, y3 + r3 * 0.75), true, true); c.QuadraticBezierTo(new Point(smX + r3 * 0.7 + fl * 0.4, y3 + r3 * 1.5), new Point(smX + r3 * 0.55 + fl, y3 + r3 * 2.1), true, false); c.LineTo(new Point(smX + r3 * 0.05 + fl, y3 + r3 * 2.05), true, false); c.QuadraticBezierTo(new Point(smX + r3 * 0.25 + fl * 0.3, y3 + r3 * 1.4), new Point(smX + r3 * 0.05, y3 + r3 * 0.8), true, false); }
                tail.Freeze(); dc.DrawGeometry(scarf, null, tail);
                dc.DrawLine(P("#ffd6d8", 1.2), new Point(smX + r3 * 0.18 + fl * 0.35, y3 + r3 * 1.5), new Point(smX + r3 * 0.64 + fl * 0.35, y3 + r3 * 1.55));
                Pen fr = P("#c23238", 1.1);
                for (int i = 0; i < 4; i++) { double fx = smX + r3 * (0.08 + i * 0.14) + fl; dc.DrawLine(fr, new Point(fx, y3 + r3 * 2.05), new Point(fx + 0.6, y3 + r3 * 2.05 + 3.2)); }
            }
            double ep = pop(0.08);
            if (ep > 0)
            {
                double blink = smBlink > 0 ? 0.12 : 1;
                double edx = Clamp((ptrX - smX) / 160, -1, 1) * 2.2, edy = Clamp((ptrY - (ground - 95)) / 160, -1, 1) * 1.8;
                for (int side = -1; side <= 1; side += 2)
                {
                    double ex = smX + side * r3 * 0.38 + edx, ey = y3 - r3 * 0.22 + edy;
                    dc.DrawEllipse(coal, null, new Point(ex, ey), 2.5 * ep, 2.5 * ep * blink);
                    if (blink > 0.5) dc.DrawEllipse(snowTop, null, new Point(ex - 0.8, ey - 0.8), 0.9, 0.9);
                    if (ep > 0.6) dc.DrawLine(P("#3a3f4e", 1.2), new Point(ex - 2.5, ey - 4.7 + side * 0.5), new Point(ex + 2.5, ey - 4.7 - side * 0.5));
                    dc.DrawEllipse(B("#58ff8a9a"), null, new Point(smX + side * r3 * 0.64, y3 + r3 * 0.2), 2.8 * ep, 1.8 * ep);
                }
            }
            double cp = pop(0.2);
            if (cp > 0)
            {
                double cy0 = y3 + r3 * 0.02, cl = 17 * cp, cyt = cy0 - 0.8, cyb = cy0 + r3 * 0.3 + 0.8, cyk = cy0 + r3 * 0.28 + 1;
                var cg = new StreamGeometry();
                using (var c = cg.Open()) { c.BeginFigure(new Point(smX, cyt), true, true); c.LineTo(new Point(smX + cl, cyk), true, false); c.LineTo(new Point(smX, cyb), true, false); }
                cg.Freeze(); dc.DrawGeometry(carrot, null, cg);
                double[] rt = new double[] { 0.3, 0.55, 0.78 };
                for (int i = 0; i < 3; i++) dc.DrawLine(P("#c9561a", 0.9), new Point(smX + cl * rt[i], cyt + (cyk - cyt) * rt[i]), new Point(smX + cl * rt[i], cyb + (cyk - cyb) * rt[i]));
                dc.DrawLine(P("#70ffffff", 0.9), new Point(smX + 1, cyt + 0.8), new Point(smX + cl * 0.8, cyt + (cyk - cyt) * 0.8 + 0.8));
            }
            double mp = pop(0.3);
            if (mp > 0) for (int i = 0; i < 7; i++) { double an = Math.PI * 0.22 + i * Math.PI * 0.093, ms = (i == 0 || i == 6) ? 1.0 : 1.3; dc.DrawEllipse(coal, null, new Point(smX + Math.Cos(an) * r3 * 0.64, y3 + Math.Sin(an) * r3 * 0.64), ms * mp, ms * mp); }
            double hp = pop(0.88);
            if (hp > 0)
            {
                double drop = (1 - Clamp((dec - 0.88) / 0.12, 0, 1)) * -46, hy = y3 - r3 * 0.72 + drop;
                dc.DrawRoundedRectangle(hat, null, new Rect(smX - r3 * 1.05, hy - 3, r3 * 2.1, 4.5), 2, 2);
                dc.DrawRectangle(B("#40ffffff"), null, new Rect(smX - r3 * 1.0, hy - 2.6, r3 * 2.0, 0.9));
                dc.DrawRoundedRectangle(hat, null, new Rect(smX - r3 * 0.62, hy - 20 * hp, r3 * 1.24, 18 * hp), 2, 2);
                dc.DrawRectangle(B("#30ffffff"), null, new Rect(smX - r3 * 0.5, hy - 19 * hp, 2.2, 16 * hp));
                dc.DrawRectangle(scarf, null, new Rect(smX - r3 * 0.62, hy - 7, r3 * 1.24, 4));
                dc.DrawRectangle(null, P("#ffc247", 0.9), new Rect(smX - 2.6, hy - 7.4, 5.2, 4.8));
                dc.DrawRoundedRectangle(snowNear, null, new Rect(smX - r3 * 0.66, hy - 21.5 * hp, r3 * 1.32, 3.6), 2, 2);
            }
            dc.Pop(); dc.Pop(); dc.Pop(); }
        // ---- трактор по расписанию + пасхалка ----
        public double PlowInterval = 200; public bool ActorsOn = true;
        bool plowActive = false; double plowWait = 0;
        public class Guy { public int kind; public double x, dir, sp, ph, lean, arm, fightT, hicT, smashT; public int state; public double fightCd; }
        List<Guy> guys = new List<Guy>(); double guyTimer = 0; bool guyInit = false;
        public static class Native2 { [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt); [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags); }
        double SnowAt(double x) { Surface tb; if (hmap.TryGetValue("taskbar", out tb)) { int ci = (int)Math.Floor((x - tb.x) / 4); if (ci >= 0 && ci < tb.cols) return tb.h[ci]; } return 0; }
        bool UiUnderCursor()
        {
            POINT p; if (!Native.GetCursorPos(out p)) return false;
            IntPtr h = Native2.WindowFromPoint(p); if (h == IntPtr.Zero) return false;
            uint pid; Native.GetWindowThreadProcessId(h, out pid); if (pid == myPid) return true;
            StringBuilder sb = new StringBuilder(64); Native.GetClassName(h, sb, 64); string c = sb.ToString();
            IntPtr root = Native2.GetAncestor(h, 2); string r = "";
            if (root != IntPtr.Zero) { StringBuilder sb2 = new StringBuilder(64); Native.GetClassName(root, sb2, 64); r = sb2.ToString(); }
            if (c == "#32768" || r == "#32768") return true;
            if (c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" || c == "TrayNotifyWnd" || c == "NotifyIconOverflowWindow") return true;
            if (r == "Shell_TrayWnd" || r == "Shell_SecondaryTrayWnd" || r == "NotifyIconOverflowWindow") return true;
            string both = c + "|" + r;
            if (both.IndexOf("Menu", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("Xaml", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("Island", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("Overflow", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("Flyout", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("Popup", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (both.IndexOf("ToolTip", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false;
        }
        bool SnowUiAllowed()
        {
            POINT p; if (!Native.GetCursorPos(out p)) return false;
            IntPtr h = Native2.WindowFromPoint(p); if (h == IntPtr.Zero) return false;
            uint pid; Native.GetWindowThreadProcessId(h, out pid); if (pid == myPid) return false;
            StringBuilder sb = new StringBuilder(64); Native.GetClassName(h, sb, 64); string c = sb.ToString();
            IntPtr root = Native2.GetAncestor(h, 2); string r = "";
            if (root != IntPtr.Zero) { StringBuilder sb2 = new StringBuilder(64); Native.GetClassName(root, sb2, 64); r = sb2.ToString(); }
            if (c == "#32768" || r == "#32768") return false;
            if (c == "Progman" || c == "WorkerW" || c == "SHELLDLL_DefView" || c == "SysListView32") return true;
            if (r == "Progman" || r == "WorkerW") return true;
            if (c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" || c == "MSTaskSwWClass" || c == "MSTaskListWClass" || c == "TrayNotifyWnd") return true;
            if (r == "Shell_TrayWnd" || r == "Shell_SecondaryTrayWnd") return true;
            return false;
        }
        bool SnowHit(double px, double py, out double top, out double depth)
        {
            top = 0; depth = 0;
            Surface tb; if (!hmap.TryGetValue("taskbar", out tb)) return false;
            if (px < tb.x || px > tb.x + tb.w) return false;
            int ci = (int)Math.Floor((px - tb.x) / 4); if (ci < 0 || ci >= tb.cols) return false;
            depth = tb.h[ci]; if (depth < 3) return false;
            top = tb.y - depth;
            return py >= top - 3 && py <= tb.y + 2;
        }
        public void SummonPlow()
        {
            if (!PlowOn || plowActive) return;
            plowActive = true; plowDir = rnd.Next(2) == 0 ? 1 : -1;
            plowX = plowDir > 0 ? -PL - 20 : W + 20;
            plowPause = 0; plowPush = 0; plowHonk = 0.6; Play(honkPlayer); Events.Enqueue("plow");
        }
        public void CallDed()
        {
            ActorsOn = true;
            if (guys.Count >= 4) return;
            Guy a = new Guy(); a.kind = 0; a.dir = rnd.Next(2) == 0 ? 1 : -1;
            a.x = a.dir > 0 ? -60 : W + 60; a.sp = R(24, 38); a.ph = R(0, 7); a.hicT = R(2, 6); a.state = 0;
            guys.Add(a);
        }
        void SpawnGuys()
        {
            int side = rnd.Next(2);
            for (int i = 0; i < 2; i++)
            {
                Guy a = new Guy(); a.kind = 0;
                int sd = i == 0 ? side : 1 - side;
                a.dir = sd == 0 ? 1 : -1;
                a.x = sd == 0 ? -60 - i * 40 : W + 60 + i * 40;
                a.sp = R(26, 34); a.ph = R(0, 7); a.hicT = R(2, 6); a.state = 0; a.fightCd = 0;
                guys.Add(a);
            }
        }
        void TrySmash(Guy a, double g)
        {
            if (a.state != 0) return; bool did = false;
            for (int i = free.Count - 1; i >= 0; i--) { Ball b = free[i]; if (Math.Abs(b.x - a.x) < b.r + 16) { Poof(b.x, b.y, 16, 120); AddSnowAt(b.x, b.r * 0.5); free.RemoveAt(i); did = true; } }
            if (tower.Count > 0 && Math.Abs(towerX - a.x) < 44) { foreach (Ball b in tower) { Poof(b.x, b.y, 16, 120); AddSnowAt(b.x, b.r * 0.5); } tower.Clear(); did = true; }
            if ((smState == 5 || smState == 4) && Math.Abs(smX - a.x) < 46) { foreach (Ball b in smBalls) { Poof(smX, b.y, 20, 140); AddSnowAt(smX, b.r * 0.5); } smBalls.Clear(); smState = 0; smCd = 25; smIdle = 0; did = true; }
            if (did) { a.state = 2; a.smashT = 0.7; Play(shakePlayer); Events.Enqueue("smash"); }
        }
        void UpdateActors(double dt)
        {
            double g = ActorGround();
            if (!guyInit) { guyInit = true; guyTimer = R(900, 2400); }
            if (!ActorsOn) { guys.Clear(); return; }
            if (!plowActive && guys.Count == 0)
            {
                guyTimer -= dt;
                if (guyTimer <= 0) { guyTimer = R(1200, 3000); SpawnGuys(); }
            }
            for (int i = guys.Count - 1; i >= 0; i--)
            {
                Guy a = guys[i]; a.ph += dt; if (a.fightCd > 0) a.fightCd -= dt;
                if (plowActive) a.state = 3;
                if (a.state == 3)
                {
                    double away = plowX + PL / 2; a.dir = a.x < away ? -1 : 1; a.sp = 155;
                    a.x += a.dir * a.sp * dt; a.lean = 0.24 * a.dir; a.arm = 1.1 + Math.Sin(a.ph * 12) * 0.3;
                    if (rnd.NextDouble() < dt * 4) parts.Add(NewPart(a.x, g - R(60, 90), R(-20, 20), R(-40, -10), 200, R(.3, .6), R(1.5, 3), 1));
                    if (a.x < -90 || a.x > W + 90) guys.RemoveAt(i);
                    continue;
                }
                if (a.state == 1)
                {
                    a.fightT -= dt; a.arm = Math.Sin(a.ph * 14) * 0.95; a.lean = Math.Sin(a.ph * 9) * 0.12;
                    if (rnd.NextDouble() < dt * 7) parts.Add(NewPart(a.x + R(-16, 16), g - R(35, 85), R(-50, 50), R(-70, -15), 240, R(.3, .7), R(2, 4), 1));
                    continue;
                }
                if (a.state == 2) { a.smashT -= dt; a.arm = -1.2 + Math.Sin(a.smashT * 18) * 0.6; if (a.smashT <= 0) { a.state = 0; a.arm = 0; } continue; }
                double stag = Math.Sin(a.ph * 2.2) * 0.5 + Math.Sin(a.ph * 0.7) * 0.3;
                a.lean = stag * 0.22;
                double v = a.sp * (0.6 + 0.6 * Math.Abs(Math.Sin(a.ph * 1.1)));
                a.x += a.dir * v * dt;
                a.arm = Math.Sin(a.ph * 3.2) * 0.5;
                a.hicT -= dt; if (a.hicT <= 0) { a.hicT = R(4, 9); a.lean += 0.3; parts.Add(NewPart(a.x + a.dir * 10, g - 92, R(-6, 6), -22, -4, 1.2, 3, 3)); }
                TrySmash(a, g);
                if (a.x < -90 || a.x > W + 90) guys.RemoveAt(i);
            }
            for (int i = 0; i < guys.Count; i++)
                for (int j = i + 1; j < guys.Count; j++)
                {
                    Guy a = guys[i], b = guys[j];
                    if (a.state == 3 || b.state == 3) continue;
                    if (a.state == 0 && b.state == 0 && a.fightCd <= 0 && b.fightCd <= 0 && Math.Abs(a.x - b.x) < 42)
                    {
                        a.state = 1; b.state = 1; a.fightT = 15; b.fightT = 15;
                        a.dir = a.x < b.x ? 1 : -1; b.dir = -a.dir;
                        Play(shakePlayer);
                        for (int k = 0; k < 14; k++) parts.Add(NewPart((a.x + b.x) / 2 + R(-18, 18), g - R(30, 85), R(-80, 80), R(-100, -20), 260, R(.4, .9), R(2, 5), 1));
                    }
                    else if (a.state == 1 && b.state == 1 && a.fightT <= 0 && b.fightT <= 0)
                    {
                        int nd = rnd.Next(2) == 0 ? 1 : -1; double mid = (a.x + b.x) / 2; double sp2 = R(26, 34);
                        a.state = 0; b.state = 0; a.dir = nd; b.dir = nd; a.sp = sp2; b.sp = sp2;
                        a.x = mid - 20; b.x = mid + 20; b.ph = a.ph; a.fightCd = 90; b.fightCd = 90; a.arm = 0; b.arm = 0;
                    }
                }
        }
        void DrawActors(DrawingContext dc)
        {
            double g = ActorGround();
            foreach (Guy a in guys)
            {
                dc.PushTransform(new TranslateTransform(a.x, g));
                dc.PushTransform(new RotateTransform(a.lean * 57.2958));
                dc.PushOpacity(0.3); dc.DrawEllipse(B("#3c4a70"), null, new Point(0, 2), 20, 4); dc.Pop();
                dc.PushTransform(new ScaleTransform(a.dir, 1));
                if (a.kind == 0) DrawDed(dc, a); else DrawSnegur(dc, a);
                dc.Pop(); dc.Pop(); dc.Pop();
            }
        }
        void DrawDed(DrawingContext dc, Guy a)
        {
            double step = Math.Sin(a.ph * 3.0) * 4;
            for (int sd = 0; sd < 2; sd++)
            {
                double bx = sd == 0 ? -13 + step : 2 - step;
                dc.DrawRoundedRectangle(B("#3b2f4a"), null, new Rect(bx, -11, 12, 11), 3.5, 3.5);
                dc.DrawRectangle(B("#f2f6ff"), null, new Rect(bx - 0.5, -1.6, 13, 1.8));
                dc.DrawRoundedRectangle(snowNear, null, new Rect(bx - 1, -13.5, 14, 3.6), 1.8, 1.8);
                dc.DrawLine(P("#5a4a70", 0.9), new Point(bx + 2.5, -9), new Point(bx + 2.5, -3.5));
            }
            var coat = new StreamGeometry();
            using (var c = coat.Open()) { c.BeginFigure(new Point(-18, -8), true, true); c.LineTo(new Point(-13, -62), true, false); c.LineTo(new Point(13, -62), true, false); c.LineTo(new Point(18, -8), true, false); }
            coat.Freeze();
            var cg = new LinearGradientBrush(Color.FromRgb(226, 72, 80), Color.FromRgb(150, 32, 44), new Point(0, 0), new Point(1, 1));
            dc.DrawGeometry(cg, null, coat);
            var shade = new StreamGeometry();
            using (var c = shade.Open()) { c.BeginFigure(new Point(6, -62), true, true); c.LineTo(new Point(13, -62), true, false); c.LineTo(new Point(18, -8), true, false); c.LineTo(new Point(10, -8), true, false); }
            shade.Freeze(); dc.DrawGeometry(B("#386a1020"), null, shade);
            dc.DrawLine(P("#60ff9a9a", 1.4), new Point(-12, -58), new Point(-16.5, -14));
            dc.DrawRoundedRectangle(snowNear, null, new Rect(-20, -15, 40, 8), 4, 4);
            for (int i = 0; i < 9; i++) { dc.DrawEllipse(snowNear, null, new Point(-18 + i * 4.5, -15), 2.8, 2.8); dc.DrawEllipse(snowNear, null, new Point(-18 + i * 4.5, -7), 2.6, 2.6); }
            dc.DrawRectangle(snowNear, null, new Rect(-3, -60, 6, 46));
            dc.DrawLine(P("#c3d0e8", 0.9), new Point(-3, -60), new Point(-3, -16)); dc.DrawLine(P("#c3d0e8", 0.9), new Point(3, -60), new Point(3, -16));
            dc.DrawRectangle(B("#241c2a"), null, new Rect(-16, -40, 32, 6));
            dc.DrawRectangle(B("#ffc247"), P("#c98a1a", 0.8), new Rect(-4, -41, 8, 8)); dc.DrawRectangle(B("#241c2a"), null, new Rect(-2, -39, 4, 4));
            Pen gold = P("#ffc247", 0.9);
            for (int sx = -1; sx <= 1; sx += 2) { double ox = sx * 9.5; for (int i = 0; i < 3; i++) { double an = i * Math.PI / 3; dc.DrawLine(gold, new Point(ox - Math.Cos(an) * 3.2, -27 - Math.Sin(an) * 3.2), new Point(ox + Math.Cos(an) * 3.2, -27 + Math.Sin(an) * 3.2)); } }
            dc.DrawRoundedRectangle(snowNear, null, new Rect(-14, -65, 28, 7), 3.5, 3.5);
            double sw = a.arm;
            Pen sleeve = P("#c23238", 8);
            Point s1 = new Point(-12, -56), s2 = new Point(12, -56);
            Point h1 = new Point(-12 - 10 * Math.Cos(sw), -40 + 8 * Math.Sin(sw));
            Point h2 = new Point(12 + 12 * Math.Cos(sw * 0.8), -42 - 14 * Math.Sin(sw));
            dc.DrawLine(sleeve, s1, h1); dc.DrawLine(sleeve, s2, h2);
            Point k1 = new Point(s1.X + (h1.X - s1.X) * 0.86, s1.Y + (h1.Y - s1.Y) * 0.86), k2 = new Point(s2.X + (h2.X - s2.X) * 0.86, s2.Y + (h2.Y - s2.Y) * 0.86);
            dc.DrawEllipse(snowNear, null, k1, 5.2, 5.2); dc.DrawEllipse(snowNear, null, k2, 5.2, 5.2);
            dc.DrawEllipse(B("#d63a44"), null, h1, 3.8, 3.8); dc.DrawEllipse(B("#d63a44"), null, h2, 3.8, 3.8);
            dc.PushTransform(new TranslateTransform(h2.X, h2.Y)); dc.PushTransform(new RotateTransform(-25 + sw * 20));
            dc.DrawRoundedRectangle(B("#2fb67d"), P("#1f7f58", 0.8), new Rect(-3.3, -15, 6.6, 13), 2.2, 2.2);
            dc.DrawRoundedRectangle(B("#2fb67d"), P("#1f7f58", 0.8), new Rect(-1.6, -21.5, 3.2, 7.4), 1, 1);
            dc.DrawRectangle(B("#c98a4a"), null, new Rect(-1.8, -23, 3.6, 2));
            dc.DrawRectangle(B("#e9f2ff"), null, new Rect(-3.3, -11.2, 6.6, 4.4)); dc.DrawLine(P("#c23238", 0.9), new Point(-2.2, -9), new Point(2.2, -9));
            dc.DrawLine(P("#90ffffff", 0.9), new Point(-2.1, -14.2), new Point(-2.1, -3.5));
            dc.Pop(); dc.Pop();
            dc.DrawEllipse(B("#f2c9a6"), null, new Point(0, -72), 9, 9.5);
            dc.DrawEllipse(B("#70ff7a7a"), null, new Point(-5.6, -69.6), 2.6, 2.1); dc.DrawEllipse(B("#70ff7a7a"), null, new Point(5.6, -69.6), 2.6, 2.1);
            var beard = new StreamGeometry();
            using (var c = beard.Open())
            {
                c.BeginFigure(new Point(-9.4, -72), true, true);
                c.QuadraticBezierTo(new Point(-13.5, -60), new Point(-9.5, -53), true, false);
                c.QuadraticBezierTo(new Point(-8, -46), new Point(-3.2, -48.5), true, false);
                c.QuadraticBezierTo(new Point(0, -42.5), new Point(3.2, -48.5), true, false);
                c.QuadraticBezierTo(new Point(8, -46), new Point(9.5, -53), true, false);
                c.QuadraticBezierTo(new Point(13.5, -60), new Point(9.4, -72), true, false);
                c.QuadraticBezierTo(new Point(0, -62), new Point(-9.4, -72), true, false);
            }
            beard.Freeze(); dc.DrawGeometry(snowNear, P("#cfdaf0", 0.7), beard);
            var strands = new StreamGeometry();
            using (var c = strands.Open())
            {
                c.BeginFigure(new Point(-5, -60), false, false); c.QuadraticBezierTo(new Point(-8, -54), new Point(-4.4, -48.6), true, false);
                c.BeginFigure(new Point(0, -58), false, false); c.LineTo(new Point(0, -46.5), true, false);
                c.BeginFigure(new Point(5, -60), false, false); c.QuadraticBezierTo(new Point(8, -54), new Point(4.4, -48.6), true, false);
            }
            strands.Freeze(); dc.DrawGeometry(null, P("#c3d0e8", 0.8), strands);
            dc.DrawEllipse(B("#b23a48"), null, new Point(0, -65.6), 1.8, 0.9);
            dc.DrawEllipse(snowNear, null, new Point(-4.6, -67.6), 5.2, 2.6); dc.DrawEllipse(snowNear, null, new Point(4.6, -67.6), 5.2, 2.6);
            dc.DrawEllipse(snowNear, null, new Point(-9.6, -69.6), 1.9, 1.9); dc.DrawEllipse(snowNear, null, new Point(9.6, -69.6), 1.9, 1.9);
            dc.DrawEllipse(B("#ff7a7a"), null, new Point(1, -70.4), 3.4, 3.1); dc.DrawEllipse(B("#a0ffffff"), null, new Point(0.2, -71.4), 1, 0.8);
            dc.DrawEllipse(B("#20242e"), null, new Point(-3.8, -74.6), 1.3, 1.3); dc.DrawEllipse(B("#20242e"), null, new Point(3.8, -74.6), 1.3, 1.3);
            dc.DrawEllipse(B("#ffffff"), null, new Point(-4.2, -75), 0.45, 0.45); dc.DrawEllipse(B("#ffffff"), null, new Point(3.4, -75), 0.45, 0.45);
            dc.DrawEllipse(snowNear, null, new Point(-4.3, -77.3), 3.9, 1.7); dc.DrawEllipse(snowNear, null, new Point(4.3, -77.3), 3.9, 1.7);
            var hatG = new StreamGeometry();
            using (var c = hatG.Open()) { c.BeginFigure(new Point(-10, -80), true, true); c.QuadraticBezierTo(new Point(-4, -100), new Point(12, -95), true, false); c.LineTo(new Point(10, -80), true, false); }
            hatG.Freeze(); dc.DrawGeometry(B("#d63a44"), null, hatG);
            var fold = new StreamGeometry();
            using (var c = fold.Open())
            {
                c.BeginFigure(new Point(-3, -84), false, false); c.QuadraticBezierTo(new Point(2, -92), new Point(9, -93), true, false);
                c.BeginFigure(new Point(-7, -85), false, false); c.QuadraticBezierTo(new Point(-5, -92), new Point(-1, -96), true, false);
            }
            fold.Freeze(); dc.DrawGeometry(null, P("#a82a34", 1.1), fold);
            Pen star = P("#ffc247", 0.9);
            for (int i = 0; i < 3; i++) { double an = i * Math.PI / 3; dc.DrawLine(star, new Point(2 - Math.Cos(an) * 2.2, -89 - Math.Sin(an) * 2.2), new Point(2 + Math.Cos(an) * 2.2, -89 + Math.Sin(an) * 2.2)); }
            dc.DrawRoundedRectangle(snowNear, P("#cfdaf0", 0.7), new Rect(-11.5, -84.5, 23, 6.4), 3.2, 3.2);
            for (int i = 0; i < 5; i++) dc.DrawEllipse(snowNear, null, new Point(-9 + i * 4.5, -84.2), 2.6, 2.4);
            dc.DrawEllipse(snowNear, P("#cfdaf0", 0.7), new Point(13, -95), 4.6, 4.6); dc.DrawEllipse(snowNear, null, new Point(15.2, -93.2), 2.2, 2.2);
            if (a.state == 1) for (int i = 0; i < 3; i++) { double an = a.ph * 6 + i * 2.09; dc.DrawEllipse(B("#ffd27a"), null, new Point(Math.Cos(an) * 14, -98 + Math.Sin(an) * 5), 2.2, 2.2); }
        }
        void DrawSnegur(DrawingContext dc, Guy a)
        {
            double step = Math.Sin(a.ph * 2.6) * 3;
            dc.DrawRoundedRectangle(B("#dfe9fa"), null, new Rect(-10 + step, -8, 9, 8), 3, 3);
            dc.DrawRoundedRectangle(B("#dfe9fa"), null, new Rect(1 - step, -8, 9, 8), 3, 3);
            var coat = new StreamGeometry();
            using (var c = coat.Open()) { c.BeginFigure(new Point(-15, -7), true, true); c.LineTo(new Point(-10, -54), true, false); c.LineTo(new Point(10, -54), true, false); c.LineTo(new Point(15, -7), true, false); }
            coat.Freeze();
            var cg = new LinearGradientBrush(Color.FromRgb(150, 214, 255), Color.FromRgb(58, 110, 190), new Point(0, 0), new Point(1, 1));
            dc.DrawGeometry(cg, null, coat);
            dc.DrawRoundedRectangle(snowNear, null, new Rect(-17, -13, 34, 7), 3.5, 3.5);
            dc.DrawRectangle(snowNear, null, new Rect(-2.5, -52, 5, 40));
            Pen sw2 = new Pen(B("#e8f7ff"), 1.2);
            dc.DrawEllipse(null, sw2, new Point(-7, -30), 4, 4);
            dc.DrawEllipse(null, sw2, new Point(7, -22), 3.4, 3.4);
            var braid = new StreamGeometry();
            using (var c = braid.Open()) { c.BeginFigure(new Point(-8, -62), true, true); c.QuadraticBezierTo(new Point(-14, -40), new Point(-9, -22), true, false); c.LineTo(new Point(-4, -23), true, false); c.QuadraticBezierTo(new Point(-8, -42), new Point(-3, -62), true, false); }
            braid.Freeze(); dc.DrawGeometry(B("#f0e2b8"), null, braid);
            dc.DrawEllipse(B("#7fd8ff"), null, new Point(-7, -21), 3, 3);
            Pen sleeve = new Pen(B("#7fc4f0"), 6.5); sleeve.StartLineCap = PenLineCap.Round; sleeve.EndLineCap = PenLineCap.Round;
            Point h1 = new Point(-10 - 8 * Math.Cos(a.arm), -36 + 6 * Math.Sin(a.arm));
            Point h2 = new Point(10 + 9 * Math.Cos(a.arm * 0.9), -38 - 10 * Math.Sin(a.arm));
            dc.DrawLine(sleeve, new Point(-10, -50), h1); dc.DrawLine(sleeve, new Point(10, -50), h2);
            dc.DrawEllipse(snowNear, null, h1, 4, 4); dc.DrawEllipse(snowNear, null, h2, 4, 4);
            dc.DrawEllipse(B("#f6d6bb"), null, new Point(0, -63), 8, 8.5);
            dc.DrawEllipse(B("#2b5fd9"), null, new Point(-3, -65), 1.7, 2);
            dc.DrawEllipse(B("#2b5fd9"), null, new Point(3, -65), 1.7, 2);
            dc.PushOpacity(0.5); dc.DrawEllipse(B("#ff9aa8"), null, new Point(-5.5, -61), 2.2, 1.6); dc.DrawEllipse(B("#ff9aa8"), null, new Point(5.5, -61), 2.2, 1.6); dc.Pop();
            var sm = new StreamGeometry();
            using (var c = sm.Open()) { c.BeginFigure(new Point(-2.5, -59), false, false); c.QuadraticBezierTo(new Point(0, -57), new Point(2.5, -59), true, false); }
            sm.Freeze(); dc.DrawGeometry(null, new Pen(B("#c2606a"), 1.2), sm);
            var crown = new StreamGeometry();
            using (var c = crown.Open()) { c.BeginFigure(new Point(-9, -68), true, true); c.QuadraticBezierTo(new Point(0, -84), new Point(9, -68), true, false); }
            crown.Freeze(); dc.DrawGeometry(B("#5aa8e6"), null, crown);
            dc.DrawRoundedRectangle(snowNear, null, new Rect(-10, -70, 20, 5), 2.5, 2.5);
            for (int i = -2; i <= 2; i++) dc.DrawEllipse(snowNear, null, new Point(i * 4, -74 + Math.Abs(i) * 1.6), 1.5, 1.5);
            dc.DrawEllipse(B("#bfeaff"), null, new Point(0, -76), 2.2, 2.2);
        }
        public void Dispose() { CompositionTarget.Rendering -= OnFrame; if (hook != IntPtr.Zero) { Native.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } MediaPlayer[] all = new MediaPlayer[] { windPlayer, jinglePlayer, honkPlayer, popPlayer, shakePlayer, whooshPlayer }; foreach (var p in all) { if (p != null) { p.Stop(); p.Close(); } } try { if (audioDir != null && Directory.Exists(audioDir)) Directory.Delete(audioDir, true); } catch { } }
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -IgnoreWarnings -ReferencedAssemblies @('PresentationCore','PresentationFramework','WindowsBase','System.Xaml','System','System.Core')
[void][Sneg.Native]::SetProcessDPIAware()
$script:engine = New-Object Sneg.SnowEngine
$overlay = New-Object System.Windows.Window
$overlay.WindowStyle='None'; $overlay.ResizeMode='NoResize'; $overlay.AllowsTransparency=$true
$overlay.Background=[System.Windows.Media.Brushes]::Transparent; $overlay.Topmost=$true
$overlay.ShowInTaskbar=$false; $overlay.ShowActivated=$false; $overlay.IsHitTestVisible=$false; $overlay.Title='Снежинка'
$overlay.Left=[System.Windows.SystemParameters]::VirtualScreenLeft; $overlay.Top=[System.Windows.SystemParameters]::VirtualScreenTop
$overlay.Width=[System.Windows.SystemParameters]::VirtualScreenWidth; $overlay.Height=[System.Windows.SystemParameters]::VirtualScreenHeight
$overlay.Content=$script:engine
$overlay.Add_SourceInitialized({ $h=(New-Object System.Windows.Interop.WindowInteropHelper($overlay)).Handle; [Sneg.Native]::ClickThrough($h) })
$overlay.Show()
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Снежинка — настройки" Width="392" Height="700" WindowStartupLocation="CenterScreen" Background="#0d1120" Foreground="#e9efff" FontFamily="Segoe UI" FontSize="13" ResizeMode="CanMinimize">
 <Window.Resources>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#e9efff"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#e9efff"/><Setter Property="Margin" Value="0,5"/></Style>
  <Style TargetType="Slider"><Setter Property="Margin" Value="0,2,0,10"/></Style>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#e9efff"/><Setter Property="Padding" Value="10,7"/><Setter Property="Margin" Value="0,3"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="bd" CornerRadius="7" Background="#1a2140" BorderBrush="#3d5a9e" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#25305c"/><Setter TargetName="bd" Property="BorderBrush" Value="#7fd8ff"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#16224a"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="18,14">
  <StackPanel>
   <TextBlock Text="❄ СНЕЖИНКА 2.0" FontSize="20" FontWeight="Bold" Foreground="#7fd8ff"/>
   <TextBlock Text="Авто-снеговик собирается сам. Ручной режим: зажми ЛКМ на снегу у панели и веди — ком растёт; отпусти, перетащи ком на ком — сложатся. 3 кома = снеговик, его можно двигать." TextWrapping="Wrap" Foreground="#9fadc9" Margin="0,4,0,12"/>
   <Button x:Name="bMode" Content="Снеговик: авто  ⟳"/>
   <UniformGrid Columns="2"><Button x:Name="bDisasm" Content="Разобрать снеговика" Margin="0,3,3,3"/><Button x:Name="bClear" Content="Очистить комья" Margin="3,3,0,3"/></UniformGrid>
   <DockPanel><TextBlock Text="Скорость роста кома"/><TextBlock x:Name="vGrow" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel>
   <Slider x:Name="sGrow" Minimum="1" Maximum="20" Value="1"/>
   <TextBlock Text="СНЕГОПАД" FontWeight="SemiBold" Foreground="#6c7a9c" Margin="0,6,0,6"/>
   <DockPanel><TextBlock Text="Интенсивность"/><TextBlock x:Name="vInt" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sInt" Minimum="0" Maximum="100" Value="0"/>
   <DockPanel><TextBlock Text="Ветер"/><TextBlock x:Name="vWind" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sWind" Minimum="-100" Maximum="100" Value="18"/>
   <DockPanel><TextBlock Text="Размер снежинок"/><TextBlock x:Name="vSize" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sSize" Minimum="50" Maximum="200" Value="50"/>
   <DockPanel><TextBlock Text="Накопление сугробов"/><TextBlock x:Name="vAccum" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sAccum" Minimum="0" Maximum="100" Value="50"/>
   <TextBlock Text="СЦЕНА" FontWeight="SemiBold" Foreground="#6c7a9c" Margin="0,6,0,6"/>
   <CheckBox x:Name="cPlow" Content="Снегоуборщик на панели" IsChecked="True"/><CheckBox x:Name="cPlowClears" Content="Трактор сносит комья и снеговиков" IsChecked="True"/>
   <DockPanel><TextBlock Text="Скорость снегоуборщика"/><TextBlock x:Name="vPlow" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sPlow" Minimum="5" Maximum="100" Value="5"/>
   <DockPanel><TextBlock Text="Интервал выезда трактора (сек)"/><TextBlock x:Name="vPlowInt" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sPlowInt" Minimum="30" Maximum="600" Value="200"/>
   <CheckBox x:Name="cSnowman" Content="Авто-снеговик (в авторежиме)" IsChecked="True"/>
   <CheckBox x:Name="cFrost" Content="Иней по краям экрана" IsChecked="True"/>
   <Button x:Name="bGarland" Content="Гирлянда: разноцветная  ⟳"/>
   <TextBlock Text="СИСТЕМА" FontWeight="SemiBold" Foreground="#6c7a9c" Margin="0,8,0,6"/>
   <Button x:Name="bQuality" Content="Качество: высокое  ⟳"/>
   <CheckBox x:Name="cSound" Content="Звук метели и эффекты" IsChecked="True"/>
   <DockPanel><TextBlock Text="Громкость"/><TextBlock x:Name="vVol" DockPanel.Dock="Right" HorizontalAlignment="Right" Foreground="#7fd8ff"/></DockPanel><Slider x:Name="sVol" Minimum="0" Maximum="100" Value="20"/>
   <CheckBox x:Name="cAuto" Content="Запускать вместе с Windows"/>
   <TextBlock Text="ДЕЙСТВИЯ" FontWeight="SemiBold" Foreground="#6c7a9c" Margin="0,8,0,6"/>
   <UniformGrid Columns="2">
    <Button x:Name="bBurst" Content="❄ Снегопад!" Margin="0,3,3,3"/><Button x:Name="bShake" Content="Стряхнуть снег" Margin="3,3,0,3"/>
    <Button x:Name="bSnowman" Content="Позвать авто-снеговика" Margin="0,3,3,3"/><Button x:Name="bRandom" Content="🎲 Случайно" Margin="3,3,0,3"/>
    <Button x:Name="bReset" Content="↺ Сброс" Margin="0,3,3,3"/><Button x:Name="bPause" Content="⏸ Пауза" Margin="3,3,0,3"/>
    <Button x:Name="bPlow" Content="🚜 Вызвать трактор" Margin="0,3,3,3"/><Button x:Name="bShot" Content="📷 Снимок PNG" Margin="0,3,3,3"/><Button x:Name="bExit" Content="⏻ Выход" Margin="3,3,0,3"/>
   </UniformGrid>
   <TextBlock Text="Снежинка 2.0 · выход из трея · клики по snow-зоне панели перехватываются только в ручном режиме" Foreground="#6c7a9c" FontSize="11" Margin="0,12,0,4" TextWrapping="Wrap"/>
  </StackPanel>
 </ScrollViewer>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$settings = [System.Windows.Markup.XamlReader]::Load($reader)
$ctl = @{}
foreach ($n in 'vInt','vWind','vSize','vAccum','vPlow','vVol','vGrow','sInt','sWind','sSize','sAccum','sPlow','sVol','sGrow','cPlow','cPlowClears','cSnowman','cFrost','cSound','cAuto','bGarland','bQuality','bBurst','bShake','bSnowman','bRandom','bReset','bPause','bShot','bExit','bMode','bDisasm','bClear','sPlowInt','vPlowInt','bPlow') { $ctl[$n] = $settings.FindName($n) }
$script:garNames = @('выключена','разноцветная','тёплая','ледяная')
$script:qNames = @('экономное','среднее','высокое')
function Sync-UI {
 $e = $script:engine
 $ctl.sInt.Value=$e.Intensity; $ctl.vInt.Text=[string][int]$e.Intensity+'%'
 $ctl.sWind.Value=$e.Wind; $ctl.vWind.Text=$(if($e.Wind -lt 0){'← '}elseif($e.Wind -gt 0){'→ '}else{''})+[string][int][Math]::Abs($e.Wind)
 $ctl.sSize.Value=$e.FlakeSize; $ctl.vSize.Text=[string][int]$e.FlakeSize+'%'
 $ctl.sAccum.Value=$e.Accum; $ctl.vAccum.Text=[string][int]$e.Accum+'%'
 $ctl.sPlow.Value=$e.PlowSpeed; $ctl.vPlow.Text=[string][int]$e.PlowSpeed+'%'
 $ctl.sGrow.Value=$e.Grow; $ctl.vGrow.Text=[string][int]$e.Grow
 $ctl.sVol.Value=[int]($e.Volume*100); $ctl.vVol.Text=[string][int]($e.Volume*100)
 $ctl.cPlow.IsChecked=$e.PlowOn; $ctl.cPlowClears.IsChecked=$e.PlowClears; $ctl.sPlowInt.Value=$e.PlowInterval; $ctl.vPlowInt.Text=[string][int]$e.PlowInterval+" с"; $ctl.cSnowman.IsChecked=$e.SnowmanOn; $ctl.cFrost.IsChecked=$e.FrostOn; $ctl.cSound.IsChecked=$e.SoundOn
 $ctl.bGarland.Content='Гирлянда: '+$script:garNames[$e.Garland]+'  ⟳'
 $ctl.bQuality.Content='Качество: '+$script:qNames[$e.Quality]+'  ⟳'
 $ctl.bMode.Content=$(if($e.Manual -eq 1){'Снеговик: вручную  ⟳'}else{'Снеговик: авто  ⟳'})
 $ctl.bPause.Content=$(if($e.Paused){'▶ Продолжить'}else{'⏸ Пауза'})
 $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
 $ctl.cAuto.IsChecked=[bool](Get-ItemProperty -Path $runKey -Name 'Sneginka' -ErrorAction SilentlyContinue)
}
$ctl.sInt.Add_ValueChanged({ $script:engine.Intensity=$ctl.sInt.Value; $ctl.vInt.Text=[string][int]$ctl.sInt.Value+'%' })
$ctl.sWind.Add_ValueChanged({ $script:engine.Wind=$ctl.sWind.Value; $ctl.vWind.Text=$(if($ctl.sWind.Value -lt 0){'← '}elseif($ctl.sWind.Value -gt 0){'→ '}else{''})+[string][int][Math]::Abs($ctl.sWind.Value); $script:engine.ApplySound() })
$ctl.sSize.Add_ValueChanged({ $script:engine.FlakeSize=$ctl.sSize.Value; $ctl.vSize.Text=[string][int]$ctl.sSize.Value+'%' })
$ctl.sAccum.Add_ValueChanged({ $script:engine.Accum=$ctl.sAccum.Value; $ctl.vAccum.Text=[string][int]$ctl.sAccum.Value+'%' })
$ctl.sPlow.Add_ValueChanged({ $script:engine.PlowSpeed=$ctl.sPlow.Value; $ctl.vPlow.Text=[string][int]$ctl.sPlow.Value+'%' })
$ctl.sGrow.Add_ValueChanged({ $script:engine.Grow=$ctl.sGrow.Value; $ctl.vGrow.Text=[string][int]$ctl.sGrow.Value })
$ctl.sVol.Add_ValueChanged({ $script:engine.Volume=$ctl.sVol.Value/100; $ctl.vVol.Text=[string][int]$ctl.sVol.Value; $script:engine.ApplySound() })
$ctl.cPlow.Add_Checked({ $script:engine.PlowOn=$true }); $ctl.cPlow.Add_Unchecked({ $script:engine.PlowOn=$false }); $ctl.cPlowClears.Add_Checked({ $script:engine.PlowClears=$true }); $ctl.cPlowClears.Add_Unchecked({ $script:engine.PlowClears=$false })
$ctl.cSnowman.Add_Checked({ $script:engine.SnowmanOn=$true }); $ctl.cSnowman.Add_Unchecked({ $script:engine.SnowmanOn=$false })
$ctl.cFrost.Add_Checked({ $script:engine.FrostOn=$true }); $ctl.cFrost.Add_Unchecked({ $script:engine.FrostOn=$false })
$ctl.cSound.Add_Checked({ $script:engine.SoundOn=$true; $script:engine.ApplySound() }); $ctl.cSound.Add_Unchecked({ $script:engine.SoundOn=$false; $script:engine.ApplySound() })
$ctl.cAuto.Add_Checked({ $cmd='powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$PSCommandPath+'"'; Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Sneginka' -Value $cmd })
$ctl.cAuto.Add_Unchecked({ Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Sneginka' -ErrorAction SilentlyContinue })
$ctl.sPlowInt.Add_ValueChanged({ $script:engine.PlowInterval=$ctl.sPlowInt.Value; $ctl.vPlowInt.Text=[string][int]$ctl.sPlowInt.Value+" с" })
$ctl.bPlow.Add_Click({ $script:engine.SummonPlow() })
$ctl.bMode.Add_Click({ $script:engine.Manual = $(if($script:engine.Manual -eq 1){0}else{1}); Sync-UI })
$ctl.bDisasm.Add_Click({ $script:engine.Disassemble() })
$ctl.bClear.Add_Click({ $script:engine.ClearBalls() })
$ctl.bGarland.Add_Click({ $script:engine.Garland=($script:engine.Garland+1)%4; Sync-UI })
$ctl.bQuality.Add_Click({ $script:engine.Quality=($script:engine.Quality+1)%3; Sync-UI })
$ctl.bBurst.Add_Click({ $script:engine.Burst() })
$ctl.bShake.Add_Click({ $script:engine.ShakeAll() })
$ctl.bSnowman.Add_Click({ $script:engine.CallSnowman(); Sync-UI })
$ctl.bPause.Add_Click({ $script:engine.Paused=-not $script:engine.Paused; Sync-UI })
$ctl.bRandom.Add_Click({ $r=New-Object System.Random; $e=$script:engine; $e.Intensity=$r.Next(25,96); $e.Wind=$r.Next(-80,81); $e.FlakeSize=$r.Next(60,176); $e.Accum=$r.Next(25,101); $e.PlowSpeed=$r.Next(15,91); $e.Garland=$r.Next(1,4); Sync-UI; $e.ApplySound() })
$ctl.bReset.Add_Click({ $e=$script:engine; $e.Intensity=0; $e.Wind=18; $e.FlakeSize=50; $e.Accum=50; $e.PlowSpeed=5; $e.Grow=1; $e.Volume=0.2; $e.SoundOn=$true; $e.PlowOn=$true; $e.PlowClears=$true; $e.PlowInterval=200; $e.ActorsOn=$true; $e.SnowmanOn=$true; $e.FrostOn=$true; $e.Garland=1; $e.Quality=2; $e.Manual=0; $e.Paused=$false; Sync-UI; $e.ApplySound() })
$ctl.bShot.Add_Click({ try { Add-Type -AssemblyName System.Drawing; $vx=[Sneg.Native]::GetSystemMetrics(76); $vy=[Sneg.Native]::GetSystemMetrics(77); $vw=[Sneg.Native]::GetSystemMetrics(78); $vh=[Sneg.Native]::GetSystemMetrics(79); $bmp=New-Object System.Drawing.Bitmap($vw,$vh); $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($vx,$vy,0,0,$bmp.Size); $rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap($vw,$vh,96,96,[System.Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($script:engine); $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb)); $ms=New-Object System.IO.MemoryStream; $enc.Save($ms); $ms.Position=0; $ov=[System.Drawing.Image]::FromStream($ms); $g.DrawImage($ov,0,0,$vw,$vh); $g.Dispose(); $ov.Dispose(); $ms.Dispose(); $path=Join-Path ([Environment]::GetFolderPath('Desktop')) ('Снежинка-'+(Get-Date -Format 'yyyy-MM-dd-HHmmss')+'.png'); $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $tray.ShowBalloonTip(3000,'Снежинка','Снимок сохранён на рабочий стол.','Info') } catch { $tray.ShowBalloonTip(3000,'Снежинка','Не удалось сохранить снимок.','Warning') } })
$ctl.bExit.Add_Click({ $app.Shutdown() })
$settings.Add_Closing({ param($s,$e) $e.Cancel=$true; $settings.Hide() })
$bmp=New-Object System.Drawing.Bitmap(32,32); $gr=[System.Drawing.Graphics]::FromImage($bmp); $gr.SmoothingMode='AntiAlias'; $gr.Clear([System.Drawing.Color]::Transparent)
$pen=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(127,216,255),3); $pen.StartCap='Round'; $pen.EndCap='Round'
for ($i=0; $i -lt 6; $i++) { $a=$i*[Math]::PI/3; $gr.DrawLine($pen,16,16,[float](16+[Math]::Sin($a)*13),[float](16-[Math]::Cos($a)*13)) }
$gr.FillEllipse([System.Drawing.Brushes]::White,12,12,8,8); $gr.Dispose()
$tray=New-Object System.Windows.Forms.NotifyIcon; $tray.Icon=[System.Drawing.Icon]::FromHandle($bmp.GetHicon()); $tray.Text='Снежинка — снег на рабочем столе'; $tray.Visible=$true
$menu=New-Object System.Windows.Forms.ContextMenuStrip
$miSettings=$menu.Items.Add('⚙ Настройки'); $miBurst=$menu.Items.Add('❄ Снегопад!'); $miShake=$menu.Items.Add('Стряхнуть снег'); $miSnowman=$menu.Items.Add('Позвать авто-снеговика'); $miPlow=$menu.Items.Add('Вызвать снегоуборщик'); $miDed=$menu.Items.Add('🎅 Позвать Деда Мороза'); $miPause=$menu.Items.Add('⏸ Пауза'); [void]$menu.Items.Add('-'); $miExit=$menu.Items.Add('⏻ Выход')
$tray.ContextMenuStrip=$menu
$miSettings.Add_Click({ $settings.Show(); $settings.Activate() }); $miBurst.Add_Click({ $script:engine.Burst() }); $miShake.Add_Click({ $script:engine.ShakeAll() }); $miSnowman.Add_Click({ $script:engine.CallSnowman(); Sync-UI }); $miPlow.Add_Click({ $script:engine.SummonPlow() }); $miDed.Add_Click({ $script:engine.CallDed() }); $miPause.Add_Click({ $script:engine.Paused=-not $script:engine.Paused; Sync-UI }); $miExit.Add_Click({ $app.Shutdown() })
$tray.Add_DoubleClick({ $settings.Show(); $settings.Activate() })
$evtTimer=New-Object System.Windows.Threading.DispatcherTimer; $evtTimer.Interval=[TimeSpan]::FromMilliseconds(400)
$evtTimer.Add_Tick({ $msg=$null; while($script:engine.Events.TryDequeue([ref]$msg)){ if($msg -eq 'ready'){ $tray.ShowBalloonTip(3000,'Снежинка','Снеговик готов! Перетащи его мышкой.','Info') } elseif($msg -eq 'shake'){ $tray.ShowBalloonTip(2000,'Снежинка','Снег стряхнут.','Info') } elseif($msg -eq 'plowed'){ $tray.ShowBalloonTip(2500,'Снежинка','Трактор сгрёб комья и снеговика в сугроб.','Info') } elseif($msg -eq 'plow'){ $tray.ShowBalloonTip(2000,'Снежинка','Снегоуборщик выехал на панель 🚜','Info') } } })
$evtTimer.Start()
$topTimer=New-Object System.Windows.Threading.DispatcherTimer; $topTimer.Interval=[TimeSpan]::FromSeconds(2); $topTimer.Add_Tick({ if(-not $overlay.Topmost){ $overlay.Topmost=$true } }); $topTimer.Start()
$resizeHandler={ $overlay.Left=[System.Windows.SystemParameters]::VirtualScreenLeft; $overlay.Top=[System.Windows.SystemParameters]::VirtualScreenTop; $overlay.Width=[System.Windows.SystemParameters]::VirtualScreenWidth; $overlay.Height=[System.Windows.SystemParameters]::VirtualScreenHeight; $h=(New-Object System.Windows.Interop.WindowInteropHelper($overlay)).Handle; [Sneg.Native]::ClickThrough($h) }
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($resizeHandler)
Sync-UI; $settings.Show()
$tray.ShowBalloonTip(3000,'Снежинка 2.0 ❄','Снег идёт, снеговик собирается сам. Настройки и выход — значок снежинки в трее.','Info')
$app=New-Object System.Windows.Application; $app.ShutdownMode='OnExplicitShutdown'; [void]$app.Run()
} catch { $_ | Out-File $script:LogPath -Append; try { [System.Windows.MessageBox]::Show('Снежинка не смогла запуститься. Подробности: '+$script:LogPath+"`n`n"+$_.Exception.Message,'Снежинка','OK','Error') } catch {} }
finally { try{ if($evtTimer){$evtTimer.Stop()} }catch{}; try{ if($topTimer){$topTimer.Stop()} }catch{}; try{ [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($resizeHandler) }catch{}; try{ if($script:engine){$script:engine.Dispose()} }catch{}; try{ if($tray){$tray.Visible=$false;$tray.Dispose()} }catch{}; try{ if($overlay){$overlay.Close()} }catch{}; try{ $mutex.ReleaseMutex() }catch{}; try{ $mutex.Dispose() }catch{} }
