using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Wardogs.Core;
using Wardogs.Reading;

namespace Wardogs.App
{
    // Wardogs XP Tracker v3: a small always-on-top window that tracks the XP each class earns per match
    // toward its 2,500 XP end-of-match bonus cap. It reads the XP/cash popups live and the in-game
    // "Wardog Level" screen with Windows' built-in OCR (screenshots only, never the game's memory),
    // keeps a breakdown of every popup per match, and deduces the end-of-match bonus.
    //
    // Hotkeys (Ctrl+Shift+): N end match, C live popups on/off, U find the Wardog Level screen,
    // O show/hide, L click-through, PageUp/PageDown opacity, M next corner.
    // --demo plays a made-up match (no game needed) in a throwaway data folder.
    public static class Program
    {
        // Matches the GitHub release tag and CHANGELOG.md.
        public const string Version = "3.0";

        public static bool Demo { get; private set; }
        public static bool Exiting { get; private set; }
        public static string DataDir { get; private set; }
        public static Settings Settings { get; private set; }
        public static Tracker Tracker { get; private set; }
        public static Worker Worker { get; private set; }
        public static TrackerWindow Window { get; private set; }
        public static Tray Tray { get; private set; }

        static Application app;
        static readonly object settingsSync = new object();

        [STAThread]
        static int Main(string[] args)
        {
            Demo = args.Any(a => a.Equals("--demo", StringComparison.OrdinalIgnoreCase) || a.Equals("-Demo", StringComparison.OrdinalIgnoreCase));
            bool noDialog = Environment.GetEnvironmentVariable("WD_NO_DIALOG") != null;

            // ------------------------------------------------ one copy at a time
            // Same lock name as the PowerShell version, so the two can't run at once either.
            var lockName = Demo ? @"Local\WardogsXpTrackerDemo" : @"Local\WardogsXpTracker";
            using var mutex = new Mutex(false, lockName);
            bool owned;
            try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }   // previous run was killed
            using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, lockName + ".Show");
            using var shownSignal = new EventWaitHandle(false, EventResetMode.AutoReset, lockName + ".Shown");
            using var exitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, lockName + ".Exit");
            bool exitRequest = args.Any(a => a.Equals("--exit", StringComparison.OrdinalIgnoreCase));
            if (exitRequest)
            {
                // "WardogsXpTracker.exe --exit" closes the running copy (same as Exit in the tray menu).
                if (owned) { try { mutex.ReleaseMutex(); } catch { } return 0; }
                exitSignal.Set();
                return 0;
            }
            if (!owned)
            {
                // Ask the running copy to come to the front. No answer means it's the old PowerShell version.
                Native.AllowSetForegroundWindow(-1);
                showSignal.Set();
                if (!shownSignal.WaitOne(3000) && !noDialog)
                    MessageBox.Show("Wardogs XP Tracker is already running (see the tray icon). If it's the older version, quit it from its tray icon first.", "Wardogs XP Tracker");
                return 0;
            }

            // ------------------------------------------------ data
            DataDir = Demo ? Path.Combine(Path.GetTempPath(), "WardogsXpTracker-demo") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WardogsXpTracker");
            if (Demo && Directory.Exists(DataDir)) { try { Directory.Delete(DataDir, true); } catch { } }
            Directory.CreateDirectory(DataDir);
            if (!Demo) BackupOnce();
            Log.Start(Path.Combine(DataDir, "tracker.log"), Version);
            try { Settings = Json.Read<Settings>(Path.Combine(DataDir, "settings.json")) ?? new Settings(); }
            catch (Exception e) { Log.Write("settings unreadable, using defaults: " + e.Message); Settings = new Settings(); }

            app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.DispatcherUnhandledException += (_, e) =>
            {
                Log.Write($"ERROR {e.Exception}");
                e.Handled = true;   // keep tracking; the log has the details
            };
            AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            {
                Log.Write($"FATAL {e.ExceptionObject}");
                if (!noDialog) MessageBox.Show($"Wardogs XP Tracker failed:\n\n{(e.ExceptionObject as Exception)?.Message}\n\nDetails are in tracker.log (tray menu: Open data folder).", "Wardogs XP Tracker");
            };

            Hotkeys hotkeys = null;
            Thread listener = null;
            var stopListening = new ManualResetEvent(false);
            try
            {
                Tracker = new Tracker(DataDir);
                Symbols.Init(DataDir, RoleIcons.DrawnGlyphs());

                Window = new TrackerWindow(Tracker, Settings);
                var dispatcher = app.Dispatcher;
                Worker = new Worker(Tracker, Settings, Demo,
                    post: a => dispatcher.BeginInvoke(a),
                    hwnd: () => Window.Hwnd,
                    windowHidden: () => Window.Hidden,
                    setWindowGhost: ghost => { try { dispatcher.Invoke(() => Window.SetGhost(ghost), DispatcherPriority.Send, CancellationToken.None, TimeSpan.FromMilliseconds(500)); } catch { } });
                Window.Attach(Worker);
                Tray = new Tray();

                Worker.Changed += () => Window.Refresh();
                Worker.TierReached += t => Window.ShowTierAlert(t, Tray);
                Worker.Balloon += (title, text) => Tray.Balloon(title, text, System.Windows.Forms.ToolTipIcon.None, 6000);
                Worker.EndedOrFiled += () => Window.ResetFrame();
                Worker.Filed += e => { Window.Refresh(); Window.SaveFiledSnapshot(e); };
                Worker.ShowDetails += e => MatchDetails.Show(e);
                Window.VisibilityChanged += () => Tray.Sync();

                hotkeys = new Hotkeys();
                uint mod = 0x2 | 0x4;   // Ctrl + Shift
                var keys = new (int Id, uint Vk, string Name)[] { (1, 0x4E, "N"), (2, 0x55, "U"), (3, 0x4F, "O"), (4, 0x4C, "L"), (5, 0x21, "PageUp"), (6, 0x22, "PageDown"), (7, 0x4D, "M"), (8, 0x43, "C") };
                var failed = keys.Where(k => !hotkeys.Add(k.Id, mod, k.Vk)).Select(k => "Ctrl+Shift+" + k.Name).ToList();
                if (failed.Count > 0) { Window.ExtraStatus = "Hotkeys already used by another app: " + string.Join(", ", failed); Log.Write(Window.ExtraStatus); }
                hotkeys.Pressed += id =>
                {
                    switch (id)
                    {
                        case 1: Window.EndMatch(); break;
                        case 2: Worker.ManualFind(); break;
                        case 3: Window.Toggle(); break;
                        case 4: ToggleClickThrough(); break;
                        case 5: Window.SetOpacity(Settings.Opacity + 10); Tray.Sync(); break;
                        case 6: Window.SetOpacity(Settings.Opacity - 10); Tray.Sync(); break;
                        case 7: if (Window.Hidden) Window.ShowWindow(); Window.MoveToNextCorner(); break;
                        case 8: ToggleLive(); break;
                    }
                };

                // A second copy asks this one to come to the front.
                listener = new Thread(() =>
                {
                    var handles = new WaitHandle[] { showSignal, exitSignal, stopListening };
                    while (true)
                    {
                        int which = WaitHandle.WaitAny(handles);
                        if (which == 0) { dispatcher.BeginInvoke(() => Window.BringToFront()); shownSignal.Set(); }
                        else if (which == 1) { dispatcher.BeginInvoke(() => Exit()); break; }
                        else break;
                    }
                }) { IsBackground = true, Name = "Wardogs show listener" };
                listener.Start();

                // Start off-screen; once its size is known it moves into place (avoids a flash on the main monitor).
                Window.Win.Opacity = Settings.Opacity / 100.0;
                Window.Win.Left = -32000; Window.Win.Top = -32000;
                bool placed = false;
                Window.Win.ContentRendered += (_, _) =>
                {
                    if (placed) return;
                    placed = true;
                    Window.PlaceAtStart();
                    AfterStart();
                };
                Window.Refresh();
                Window.Win.Show();
                Worker.Start();
                Log.Write($"ready (demo={Demo})");
                app.Run();
            }
            catch (Exception e)
            {
                Log.Write($"FATAL {e}");
                if (!noDialog) MessageBox.Show($"Wardogs XP Tracker failed:\n\n{e.Message}", "Wardogs XP Tracker");
                return 1;
            }
            finally
            {
                // Exit: stop the capture thread, save, and remove the tray icon, so nothing is left running.
                Exiting = true;
                stopListening.Set();
                Worker?.Stop();
                try { Tracker?.Save(); } catch { }
                hotkeys?.Dispose();
                Tray?.Dispose();
                listener?.Join(1000);
                Log.Write("exited");
                try { mutex.ReleaseMutex(); } catch { }
            }
            return 0;
        }

        static void AfterStart()
        {
            // The last match filed before pictures were taken: if nothing has happened since, the window
            // still shows it just as it looked when filed.
            try
            {
                if (!Demo && Tracker.History.Count > 0 && Tracker.History[0].Snapshot == null && !Tracker.IsMatchActive())
                    Window.SaveFiledSnapshot(Tracker.History[0]);
            }
            catch (Exception e) { Log.Write("snapshot ERROR " + e.Message); }
            bool newStart = Settings.StartMenuShortcut && Shortcuts.Managed && Shortcuts.StartMenuMissing;
            Shortcuts.Update();
            Tray.Sync();
            var where = System.Windows.Forms.Screen.AllScreens.Length > 1 ? "on your screen" : "in the corner of your screen";
            Tray.Balloon("Wardogs XP Tracker is running", newStart
                ? $"It's {where}. Next time, start it from the Start menu: search for Wardogs."
                : $"It's {where}. Drag it anywhere, or press Ctrl+Shift+M to jump between corners.", System.Windows.Forms.ToolTipIcon.None, 6000);
        }

        // The first time the .exe runs, keep a copy of the PowerShell version's data, just in case.
        static void BackupOnce()
        {
            var backup = Path.Combine(DataDir, "backup-before-exe");
            if (Directory.Exists(backup)) return;
            try
            {
                if (!Directory.EnumerateFileSystemEntries(DataDir).Any()) return;
                Directory.CreateDirectory(backup);
                foreach (var f in Directory.GetFiles(DataDir, "*.json")) File.Copy(f, Path.Combine(backup, Path.GetFileName(f)));
                var matches = Path.Combine(DataDir, "matches");
                if (Directory.Exists(matches))
                {
                    Directory.CreateDirectory(Path.Combine(backup, "matches"));
                    foreach (var f in Directory.GetFiles(matches)) File.Copy(f, Path.Combine(backup, "matches", Path.GetFileName(f)));
                }
            }
            catch { }
        }

        public static void SaveSettings()
        {
            lock (settingsSync)
            {
                try { Json.Write(Path.Combine(DataDir, "settings.json"), Settings); } catch (Exception e) { Log.Write("settings save ERROR " + e.Message); }
            }
        }

        // ------------------------------------------------ actions shared by the tray, hotkeys and buttons
        public static void SetPaused(bool paused)
        {
            Worker.Paused = paused;
            Worker.ResetPopups();
            Log.Write(paused ? "tracking paused" : "tracking resumed");
            Tray.Sync();
            Window.Refresh();
            Tray.Balloon("Wardogs XP Tracker", paused ? "Tracking paused. Nothing is read from the screen until you resume." : "Tracking resumed.");
        }

        public static void ToggleLive()
        {
            Settings.Continuous = !Settings.Continuous; SaveSettings();
            Worker.ResetPopups();
            Tray.Sync();
            Tray.Balloon("Wardogs XP Tracker", Settings.Continuous ? "Live popup tracking on." : "Live popup tracking off.", System.Windows.Forms.ToolTipIcon.None, 2000);
        }

        public static void ToggleClickThrough()
        {
            Window.SetClickThrough(!Settings.ClickThrough);
            Tray.Sync();
            Tray.Balloon("Wardogs XP Tracker", Settings.ClickThrough ? "Click-through ON (Ctrl+Shift+L to turn off)" : "Click-through OFF", System.Windows.Forms.ToolTipIcon.None, 1500);
        }

        public static void SetPopupArea()
        {
            var picked = AreaPicker.Pick(Popups.PopupRect(Settings.PopupRect), Window.Scale);
            if (picked == null) return;
            Settings.PopupRect = GameScreen.FormatRect(picked.Value);
            SaveSettings();
            Worker.ResetPopups();
            Log.Write($"popup area set to {Settings.PopupRect}");
            Tray.Balloon("Wardogs XP Tracker", "Popup area saved.");
        }

        public static void Exit()
        {
            Exiting = true;
            app.Shutdown();
        }
    }
}
