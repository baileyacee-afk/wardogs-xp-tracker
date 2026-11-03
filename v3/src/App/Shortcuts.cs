using System;
using System.IO;
using Microsoft.Win32;
using Wardogs.Core;

namespace Wardogs.App
{
    // Start menu entry (on by default), desktop shortcut and Start with Windows (off by default).
    // They point at this .exe. Start with Windows uses the per-user Run key.
    public static class Shortcuts
    {
        public enum Kind { StartMenu, Desktop, Startup }

        const string LinkName = "Wardogs XP Tracker.lnk";
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunValue = "Wardogs XP Tracker";

        static string Exe => Environment.ProcessPath;

        // Running from a build folder (testing): leave the real shortcuts alone.
        public static bool Managed => !Program.Demo && !Program.Packaged && Exe != null && !Exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase);

        static string LinkPath(Kind k) => Path.Combine(Environment.GetFolderPath(k == Kind.StartMenu ? Environment.SpecialFolder.Programs : Environment.SpecialFolder.DesktopDirectory), LinkName);

        static bool IsOn(Kind k) => k switch
        {
            Kind.StartMenu => Program.Settings.StartMenuShortcut,
            Kind.Desktop => Program.Settings.DesktopShortcut,
            _ => Program.Settings.StartWithWindows,
        };

        static void Remember(Kind k, bool on)
        {
            if (k == Kind.StartMenu) Program.Settings.StartMenuShortcut = on;
            else if (k == Kind.Desktop) Program.Settings.DesktopShortcut = on;
            else Program.Settings.StartWithWindows = on;
            Program.SaveSettings();
        }

        public static bool StartMenuMissing => !File.Exists(LinkPath(Kind.StartMenu));

        static void Apply(Kind k, bool on)
        {
            if (k == Kind.Startup)
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (on) key.SetValue(RunValue, $"\"{Exe}\""); else key.DeleteValue(RunValue, false);
                return;
            }
            var path = LinkPath(k);
            if (!on) { if (File.Exists(path)) File.Delete(path); return; }
            var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            dynamic lnk = ((dynamic)shell).CreateShortcut(path);
            lnk.TargetPath = Exe;
            lnk.WorkingDirectory = Path.GetDirectoryName(Exe);
            lnk.IconLocation = Exe + ",0";
            lnk.Description = "Wardogs XP Tracker";
            lnk.Save();
        }

        // Store version: Windows makes the Start menu entry, and Start with Windows is the package's
        // startup task (also shown in Task Manager's Startup apps, where it can be turned off too).
        const string StartupTaskId = "WardogsXpTracker";

        static async void SwitchPackagedStartup()
        {
            try
            {
                var task = await global::Windows.ApplicationModel.StartupTask.GetAsync(StartupTaskId);
                var state = task.State;
                if (state == global::Windows.ApplicationModel.StartupTaskState.Enabled) { task.Disable(); state = task.State; }
                else state = await task.RequestEnableAsync();
                bool on = state == global::Windows.ApplicationModel.StartupTaskState.Enabled;
                Remember(Kind.Startup, on);
                Program.Tray.Sync();
                if (state == global::Windows.ApplicationModel.StartupTaskState.DisabledByUser)
                    Program.Tray.Balloon(Program.AppName, "Start with Windows was turned off in Task Manager. Turn it back on there, under Startup apps.", System.Windows.Forms.ToolTipIcon.Warning);
            }
            catch (Exception e) { Log.Write("startup task ERROR " + e.Message); }
        }

        static async void SyncPackagedStartup()
        {
            try
            {
                var task = await global::Windows.ApplicationModel.StartupTask.GetAsync(StartupTaskId);
                bool on = task.State is global::Windows.ApplicationModel.StartupTaskState.Enabled or global::Windows.ApplicationModel.StartupTaskState.EnabledByPolicy;
                if (on != Program.Settings.StartWithWindows) Remember(Kind.Startup, on);
                Program.Tray.Sync();
            }
            catch (Exception e) { Log.Write("startup task ERROR " + e.Message); }
        }

        public static void Switch(Kind k)
        {
            if (Program.Packaged) { if (k == Kind.Startup) SwitchPackagedStartup(); return; }
            if (!Managed) { Program.Tray.Balloon(Program.AppName, "Shortcuts aren't changed while running a test build."); return; }
            bool on = !IsOn(k);
            try { Apply(k, on); Remember(k, on); }
            catch (Exception e)
            {
                Log.Write($"shortcut ERROR ({k}) {e.Message}");
                Program.Tray.Balloon(Program.AppName, "Couldn't change the shortcut: " + e.Message, System.Windows.Forms.ToolTipIcon.Warning);
            }
        }

        // At startup: (re)write the shortcuts that are on, so they point at this .exe (also replacing the
        // PowerShell version's Start menu shortcut), and move its Startup-folder shortcut to the Run key.
        public static void Update()
        {
            if (Program.Packaged) { SyncPackagedStartup(); return; }
            if (!Managed) return;
            try
            {
                var oldStartup = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), LinkName);
                if (File.Exists(oldStartup)) { File.Delete(oldStartup); Remember(Kind.Startup, true); }
            }
            catch (Exception e) { Log.Write("shortcut ERROR (old startup) " + e.Message); }
            foreach (var k in new[] { Kind.StartMenu, Kind.Desktop, Kind.Startup })
                if (IsOn(k)) { try { Apply(k, true); } catch (Exception e) { Log.Write($"shortcut ERROR ({k}) {e.Message}"); } }
        }
    }
}
