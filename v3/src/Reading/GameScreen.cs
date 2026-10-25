using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Linq;

namespace Wardogs.Reading
{
    // Finds the game's window and takes screenshots. Only pixels on screen: never the game itself.
    public static class GameScreen
    {
        static readonly object sync = new object();
        static Process game;
        static DateTime gameAt = DateTime.MinValue;

        // The game's program is normally WardogsClient-Win64-Shipping, but other stores or builds may name it
        // differently, so also accept any program starting with "Wardogs" or a window titled just "Wardogs".
        // Listing every process is slow and this is asked several times a second, so the answer is kept for 5 s.
        public static Process GameProcess()
        {
            lock (sync)
            {
                if ((DateTime.Now - gameAt).TotalSeconds < 5)
                {
                    if (game == null) return null;
                    try { if (!game.HasExited) return game; } catch { }
                }
                game = Find();
                gameAt = DateTime.Now;
                return game;
            }
        }

        // Program names come cheaply from the process list; window titles are read from the top-level
        // windows directly (asking every process for its main window title is slow).
        static Process Find()
        {
            int self = Environment.ProcessId;
            Process best = null;
            foreach (var p in Process.GetProcesses())
            {
                bool keep = false;
                try { keep = p.Id != self && p.ProcessName.StartsWith("Wardogs", StringComparison.OrdinalIgnoreCase) && p.MainWindowHandle != IntPtr.Zero; }
                catch { }
                if (keep && (best == null || p.ProcessName == "WardogsClient-Win64-Shipping" && best.ProcessName != "WardogsClient-Win64-Shipping"))
                {
                    best?.Dispose(); best = p;
                }
                else p.Dispose();
            }
            if (best != null) return best;
            uint pid = 0;
            EnumWindows((h, _) =>
            {
                if (!IsWindowVisible(h)) return true;
                var sb = new System.Text.StringBuilder(32);
                GetWindowText(h, sb, sb.Capacity);
                if (!sb.ToString().Trim().Equals("Wardogs", StringComparison.OrdinalIgnoreCase)) return true;
                GetWindowThreadProcessId(h, out pid);
                return pid == self;   // keep looking if it's our own window
            }, IntPtr.Zero);
            if (pid == 0 || pid == self) return null;
            try { return Process.GetProcessById((int)pid); } catch { return null; }
        }

        delegate bool EnumWindowsProc(IntPtr h, IntPtr lParam);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int max);
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

        // Screen rectangle of the game window (borderless/windowed), or the main screen if the game isn't running.
        public static Rectangle GameRect()
        {
            var g = GameProcess();
            if (g != null)
            {
                try
                {
                    var r = Native.WindowRect(g.MainWindowHandle);
                    if (r.Width > 200) return r;
                }
                catch { }
            }
            return System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        }

        public static Bitmap Capture(Rectangle r)
        {
            var bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size);
            return bmp;
        }

        public static Rectangle ParseRect(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return Rectangle.Empty;
            var p = text.Split(',').Select(s => int.Parse(s.Trim())).ToArray();
            return p.Length == 4 ? new Rectangle(p[0], p[1], p[2], p[3]) : Rectangle.Empty;
        }

        public static string FormatRect(Rectangle r) => $"{r.X},{r.Y},{r.Width},{r.Height}";
    }
}
