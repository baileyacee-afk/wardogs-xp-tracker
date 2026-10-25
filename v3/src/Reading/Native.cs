using System;
using System.Drawing;
using System.Runtime.InteropServices;

namespace Wardogs.Reading
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int v);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

        public const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint NOSIZE = 0x1, NOMOVE = 0x2, NOACTIVATE = 0x10;

        public static void KeepOnTop(IntPtr h) { if (h != IntPtr.Zero) SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, NOSIZE | NOMOVE | NOACTIVATE); }

        public static void SetClickThrough(IntPtr h, bool on)
        {
            const int GWL_EXSTYLE = -20, WS_EX_TRANSPARENT = 0x20;
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            SetWindowLong(h, GWL_EXSTYLE, on ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT));
        }

        public static Rectangle WindowRect(IntPtr h)
        {
            if (h == IntPtr.Zero || !GetWindowRect(h, out var r)) return Rectangle.Empty;
            return new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
        }
    }
}
