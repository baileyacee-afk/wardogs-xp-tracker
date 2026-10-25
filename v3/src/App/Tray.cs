using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using Wardogs.Reading;

namespace Wardogs.App
{
    // The tray icon: always there while the app runs. Double-click shows the window; right-click
    // has Show/Hide, Pause/Resume, Exit and the rest of the tracker's options.
    public sealed class Tray : IDisposable
    {
        readonly NotifyIcon icon;
        readonly ToolStripMenuItem miShow, miPause, miLive, miClick, miStartup, miScStart, miScDesk, miOpacity;

        public Tray()
        {
            var w = Program.Window; var s = Program.Settings;
            icon = new NotifyIcon { Icon = Badge(SystemInformation.SmallIconSize.Width), Text = $"Wardogs XP Tracker v{Program.Version}{(Program.Demo ? " (demo)" : "")}" };
            var menu = new ContextMenuStrip();
            ToolStripMenuItem Add(string text, Action click, string keys = null)
            {
                var mi = new ToolStripMenuItem(text) { ShortcutKeyDisplayString = keys };
                mi.Click += (_, _) => click();
                menu.Items.Add(mi);
                return mi;
            }
            miShow = Add("Hide window", () => w.Toggle(), "Ctrl+Shift+O");
            miShow.Font = new Font(miShow.Font, FontStyle.Bold);
            miPause = Add("Pause tracking", () => Program.SetPaused(!Program.Worker.Paused));
            menu.Items.Add(new ToolStripSeparator());
            Add("End match", () => w.EndMatch(), "Ctrl+Shift+N");
            Add("Match details", () => MatchDetails.Show(null));
            miLive = Add("Live popup tracking", () => Program.ToggleLive(), "Ctrl+Shift+C");
            Add("Set popup area...", () => Program.SetPopupArea());
            Add("Reset popup area", () => { s.PopupRect = null; Program.SaveSettings(); Program.Worker.ResetPopups(); Balloon("Wardogs XP Tracker", "Popup area reset to the default spot."); });
            Add("Find Wardog Level screen", () => Program.Worker.ManualFind(), "Ctrl+Shift+U");
            miClick = Add("Click-through", () => Program.ToggleClickThrough(), "Ctrl+Shift+L");

            miOpacity = new ToolStripMenuItem("Opacity");
            foreach (var v in new[] { 100, 95, 90, 80, 70, 60, 50 })
            {
                var mi = new ToolStripMenuItem($"{v}%") { Tag = v };
                mi.Click += (o, _) => { w.SetOpacity((int)((ToolStripMenuItem)o).Tag); Sync(); };
                miOpacity.DropDownItems.Add(mi);
            }
            menu.Items.Add(miOpacity);

            var miMove = new ToolStripMenuItem("Move window");
            foreach (var (label, spot) in new[] { ("Top right", "TopRight"), ("Top left", "TopLeft"), ("Bottom right", "BottomRight"), ("Bottom left", "BottomLeft"), ("Center", "Center") })
            {
                var mi = new ToolStripMenuItem(label);
                mi.Click += (_, _) => { if (w.Hidden) w.ShowWindow(); w.MoveToSpot(spot); };
                miMove.DropDownItems.Add(mi);
            }
            miMove.DropDownItems.Add(new ToolStripSeparator());
            var miNextScreen = new ToolStripMenuItem("Next monitor");
            miNextScreen.Click += (_, _) => { if (w.Hidden) w.ShowWindow(); w.MoveToNextMonitor(); };
            miMove.DropDownItems.Add(miNextScreen);
            var miCycle = new ToolStripMenuItem("Next corner") { ShortcutKeyDisplayString = "Ctrl+Shift+M" };
            miCycle.Click += (_, _) => { if (w.Hidden) w.ShowWindow(); w.MoveToNextCorner(); };
            miMove.DropDownItems.Add(miCycle);
            // Only offer "Next monitor" when there is more than one.
            miMove.DropDownOpening += (_, _) => miNextScreen.Visible = Screen.AllScreens.Length > 1;
            menu.Items.Add(miMove);

            menu.Items.Add(new ToolStripSeparator());
            miStartup = Add("Start with Windows", () => { Shortcuts.Switch(Shortcuts.Kind.Startup); Sync(); });
            var miShortcuts = new ToolStripMenuItem("Shortcuts");
            miScStart = new ToolStripMenuItem("In the Start menu"); miScStart.Click += (_, _) => { Shortcuts.Switch(Shortcuts.Kind.StartMenu); Sync(); };
            miScDesk = new ToolStripMenuItem("On the desktop"); miScDesk.Click += (_, _) => { Shortcuts.Switch(Shortcuts.Kind.Desktop); Sync(); };
            miShortcuts.DropDownItems.Add(miScStart); miShortcuts.DropDownItems.Add(miScDesk);
            menu.Items.Add(miShortcuts);
            Add("Open data folder", () => System.Diagnostics.Process.Start("explorer.exe", Program.DataDir));
            menu.Items.Add(new ToolStripSeparator());
            Add("Exit", () => Program.Exit());

            menu.Opening += (_, _) => Sync();
            icon.ContextMenuStrip = menu;
            icon.DoubleClick += (_, _) => w.BringToFront();
            icon.Visible = true;
        }

        // Brings every check mark and label in line with the current settings.
        public void Sync()
        {
            var s = Program.Settings; var w = Program.Window;
            miShow.Text = w.Hidden ? "Show window" : "Hide window";
            miPause.Text = Program.Worker.Paused ? "Resume tracking" : "Pause tracking";
            miLive.Checked = s.Continuous;
            miClick.Checked = s.ClickThrough;
            miStartup.Checked = s.StartWithWindows;
            miScStart.Checked = s.StartMenuShortcut;
            miScDesk.Checked = s.DesktopShortcut;
            foreach (ToolStripMenuItem mi in miOpacity.DropDownItems) mi.Checked = (int)mi.Tag == s.Opacity;
            icon.Text = $"Wardogs XP Tracker v{Program.Version}{(Program.Demo ? " (demo)" : "")}{(Program.Worker.Paused ? " - paused" : "")}";
        }

        public void Balloon(string title, string text, ToolTipIcon kind = ToolTipIcon.None, int ms = 3000)
        {
            if (Program.Demo) return;
            icon.ShowBalloonTip(ms, title, text, kind);
        }

        public void Dispose() { icon.Visible = false; icon.Dispose(); }

        // The app's "XP" badge, drawn at any size.
        public static Icon Badge(int size) => Icon.FromHandle(BadgeBitmap(size).GetHicon());

        public static Bitmap BadgeBitmap(int size)
        {
            float k = size / 32f;
            var bmp = new Bitmap(size, size);
            using var g = Graphics.FromImage(bmp);
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using (var bg = new SolidBrush(Color.FromArgb(20, 16, 10))) g.FillRectangle(bg, 0, 0, size, size);
            using (var pen = new Pen(Color.FromArgb(216, 180, 90), 2 * k)) g.DrawRectangle(pen, k, k, 29 * k, 29 * k);
            using var font = new Font("Bahnschrift", 15 * k, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            using var gold = new SolidBrush(Color.FromArgb(216, 180, 90));
            g.DrawString("XP", font, gold, new RectangleF(0, k, size, size), fmt);
            return bmp;
        }
    }

    // Global Ctrl+Shift hotkeys (work while the game has focus).
    public sealed class Hotkeys : NativeWindow, IDisposable
    {
        public event Action<int> Pressed;
        int count;
        public Hotkeys() { CreateHandle(new CreateParams()); }
        public bool Add(int id, uint mods, uint vk) { count = Math.Max(count, id); return Native.RegisterHotKey(Handle, id, mods | 0x4000, vk); }   // 0x4000: no repeat
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) Pressed?.Invoke(m.WParam.ToInt32());
            base.WndProc(ref m);
        }
        public void Dispose() { for (int i = 1; i <= count; i++) Native.UnregisterHotKey(Handle, i); DestroyHandle(); }
    }
}
