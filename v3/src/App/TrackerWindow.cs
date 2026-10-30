using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Wardogs.Core;
using Wardogs.Reading;
using Forms = System.Windows.Forms;

namespace Wardogs.App
{
    // The small always-on-top tracker window. It only draws what the tracker and worker know.
    // It has a taskbar button while it's open; minimizing (or the "-" button) hides it to the tray.
    public sealed class TrackerWindow
    {
        public readonly Window Win;
        readonly Dictionary<string, object> ui = new();   // named parts (elements and bar columns)
        readonly Tracker tracker;
        readonly Settings settings;
        Worker worker;

        public IntPtr Hwnd { get; private set; }
        volatile bool hidden;
        public bool Hidden => hidden;
        public event Action VisibilityChanged;

        public TrackerWindow(Tracker tracker, Settings settings)
        {
            this.tracker = tracker; this.settings = settings;
            Win = (Window)XamlReader.Parse(BuildXaml());
            foreach (var name in names) ui[name] = Win.FindName(name);
            Win.Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Assets/tracker.ico"));

            ((Button)ui["BtnNext"]).Click += (_, _) => EndMatch();
            ((Button)ui["BtnDetails"]).Click += (_, _) => MatchDetails.Show(null);
            ((Button)ui["BtnHide"]).Click += (_, _) => HideToTray();
            ((Button)ui["BtnVersions"]).Click += (_, _) => Program.OpenReleases();
            // Drag from any empty spot to move it (buttons still click normally).
            Win.MouseLeftButtonDown += (_, e) =>
            {
                try { Win.DragMove(); } catch { return; }   // throws if the button was already released
                var r = Native.WindowRect(Hwnd);
                settings.WindowPos = $"{r.X},{r.Y}"; Program.SaveSettings();
                ResizeToScreen(CurrentScreen());
            };
            Win.SourceInitialized += (_, _) =>
            {
                Hwnd = new WindowInteropHelper(Win).Handle;
                // A borderless window has no minimize box, so the taskbar button couldn't minimize it.
                const int GWL_STYLE = -16, WS_MINIMIZEBOX = 0x20000;
                Native.SetWindowLong(Hwnd, GWL_STYLE, Native.GetWindowLong(Hwnd, GWL_STYLE) | WS_MINIMIZEBOX);
                if (settings.ClickThrough) Native.SetClickThrough(Hwnd, true);
            };
            Win.StateChanged += (_, _) => { if (Win.WindowState == WindowState.Minimized) HideToTray(); };
            // Closing it (Alt+F4) also just hides it; Exit is in the tray menu.
            Win.Closing += (_, e) => { if (!Program.Exiting) { e.Cancel = true; HideToTray(); } };

            var topTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            topTimer.Tick += (_, _) => { if (!hidden) Native.KeepOnTop(Hwnd); };
            topTimer.Start();
        }

        public void Attach(Worker w) { worker = w; }

        // ------------------------------------------------------------ markup
        static readonly List<string> names = new();

        static string N(string name) { names.Add(name); return name; }

        static string BuildXaml()
        {
            names.Clear();
            string ticks = string.Concat(Enumerable.Range(1, Roles.TierCount).Select(i => i < Roles.TierCount ? "<Border BorderBrush=\"#0B0907\" BorderThickness=\"0,0,2,0\"/>" : "<Border/>"));
            var rows = new StringBuilder();
            foreach (var r in Roles.Order)
            {
                rows.Append($@"
        <Grid Margin=""0,5,0,5"">
          <Grid.RowDefinitions><RowDefinition Height=""Auto""/><RowDefinition Height=""Auto""/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width=""*""/><ColumnDefinition Width=""Auto""/></Grid.ColumnDefinitions>
          <StackPanel>
            <StackPanel Orientation=""Horizontal"">
              {RoleIcons.Xaml(r, 14, Theme.Ink, N(r + "_Icon"), "0,0,7,0")}
              <TextBlock x:Name=""{N(r + "_Name")}"" Text=""{Roles.Names[r]}"" FontSize=""14"" FontWeight=""SemiBold""/>
            </StackPanel>
            <TextBlock x:Name=""{N(r + "_To")}"" Text="" "" FontSize=""11"" Foreground=""%DIM%"" Margin=""21,0,0,0""/>
          </StackPanel>
          <StackPanel Grid.Column=""1"">
            <TextBlock x:Name=""{N(r + "_Gain")}"" Text=""+0"" FontSize=""15"" FontWeight=""SemiBold"" Foreground=""%DIM%"" HorizontalAlignment=""Right""/>
            <TextBlock x:Name=""{N(r + "_Tier")}"" Text=""Tier 0 / {Roles.TierCount}"" FontSize=""11"" Foreground=""%DIM%"" HorizontalAlignment=""Right""/>
          </StackPanel>
          <Grid Grid.Row=""1"" Grid.ColumnSpan=""2"" Height=""5"" Margin=""0,4,0,0"">
            <Border Background=""#2B2519"" CornerRadius=""2""/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name=""{N(r + "_ColF")}"" Width=""0*""/><ColumnDefinition x:Name=""{N(r + "_ColR")}"" Width=""1*""/></Grid.ColumnDefinitions>
              <Border x:Name=""{N(r + "_Fill")}"" Background=""%GOLD%"" CornerRadius=""2""/>
            </Grid>
            <UniformGrid Columns=""{Roles.TierCount}"">{ticks}</UniformGrid>
          </Grid>
        </Grid>");
            }
            // Match bonus overview: each role's symbol with a mini bar toward its 2,500 XP cap.
            var chips = new StringBuilder();
            foreach (var r in Roles.Order)
            {
                chips.Append($@"
        <StackPanel Margin=""4,0,4,0"" ToolTip=""{Roles.Names[r]}"">
          {RoleIcons.Xaml(r, 18, Theme.Ink, N(r + "_Chip"), "0,0,0,6")}
          <Grid Height=""4"">
            <Border Background=""#2B2519"" CornerRadius=""2""/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name=""{N(r + "_ChipF")}"" Width=""0*""/><ColumnDefinition x:Name=""{N(r + "_ChipR")}"" Width=""1*""/></Grid.ColumnDefinitions>
              <Border x:Name=""{N(r + "_ChipFill")}"" Background=""%GOLD%"" CornerRadius=""2""/>
            </Grid>
          </Grid>
        </StackPanel>");
            }
            foreach (var n in new[] { "Frame", "Header", "TxtWardogLv", "TxtLvGain", "BtnDetails", "BtnNext", "BtnHide", "TxtMaxed", "Badge", "TxtNote", "TxtCash", "TxtKills", "HistoryList", "TxtStatus", "BtnVersions" }) names.Add(n);

            return Theme.Fill(MainXaml.Replace("@CHIPS@", chips.ToString()).Replace("@ROWS@", rows.ToString())
                .Replace("@ROLECOUNT@", Roles.Order.Length.ToString()).Replace("@VERSION@", Program.Version));
        }

        const string MainXaml = @"
<Window xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation""
        xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml""
        Title=""Wardogs XP Tracker"" Width=""330"" SizeToContent=""Height""
        WindowStyle=""None"" AllowsTransparency=""True"" Background=""Transparent"" ResizeMode=""NoResize""
        Topmost=""True"" ShowInTaskbar=""True"" ShowActivated=""False""
        FontFamily=""Bahnschrift, Segoe UI"" Foreground=""%INK%"" UseLayoutRounding=""True"">
  <Window.Resources>
    <Style x:Key=""Flat"" TargetType=""Button"">
      <Setter Property=""Foreground"" Value=""%MUTED%""/>
      <Setter Property=""Background"" Value=""Transparent""/>
      <Setter Property=""BorderBrush"" Value=""%LINE%""/>
      <Setter Property=""FontSize"" Value=""11""/>
      <Setter Property=""Cursor"" Value=""Hand""/>
      <Setter Property=""Focusable"" Value=""False""/>
      <Setter Property=""Template"">
        <Setter.Value>
          <ControlTemplate TargetType=""Button"">
            <Border x:Name=""b"" Background=""{TemplateBinding Background}"" BorderBrush=""{TemplateBinding BorderBrush}""
                    BorderThickness=""1"" CornerRadius=""3"" Padding=""8,3"">
              <ContentPresenter HorizontalAlignment=""Center"" VerticalAlignment=""Center""/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property=""IsMouseOver"" Value=""True"">
                <Setter TargetName=""b"" Property=""Background"" Value=""#2B2519""/>
                <Setter Property=""Foreground"" Value=""%INK%""/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name=""Frame"" CornerRadius=""6"" BorderBrush=""%LINE%"" BorderThickness=""1"">
    <Border.Background>
      <LinearGradientBrush StartPoint=""0,0"" EndPoint=""0,1"">
        <GradientStop Color=""#FF1A150C"" Offset=""0""/>
        <GradientStop Color=""#FF0B0907"" Offset=""1""/>
      </LinearGradientBrush>
    </Border.Background>
    <StackPanel>

      <Grid x:Name=""Header"" Background=""#01000000"" Margin=""14,10,10,0"" Cursor=""SizeAll"">
        <StackPanel>
          <TextBlock Text=""//WARDOG LEVEL"" FontSize=""11"" FontWeight=""SemiBold"" Foreground=""%GOLD%""/>
          <StackPanel Orientation=""Horizontal"">
            <TextBlock x:Name=""TxtWardogLv"" Text=""-"" FontSize=""40"" FontWeight=""Bold"" LineHeight=""42"" LineStackingStrategy=""BlockLineHeight""/>
            <TextBlock x:Name=""TxtLvGain"" Text="" "" FontSize=""12.5"" FontWeight=""SemiBold"" Foreground=""%GREEN%"" VerticalAlignment=""Bottom"" Margin=""9,0,0,6""/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation=""Horizontal"" HorizontalAlignment=""Right"" VerticalAlignment=""Top"">
          <Button x:Name=""BtnDetails"" Style=""{StaticResource Flat}"" Content=""DETAILS"" Margin=""0,0,4,0"" ToolTip=""Every XP and cash popup this match, grouped by reason""/>
          <Button x:Name=""BtnNext"" Style=""{StaticResource Flat}"" Content=""END MATCH"" ToolTip=""The match is over: the next Wardog Level read files it with the deduced bonus (Ctrl+Shift+N)""/>
          <Button x:Name=""BtnHide"" Style=""{StaticResource Flat}"" Content=""&#x2013;"" Margin=""4,0,0,0"" ToolTip=""Hide to the tray (Ctrl+Shift+O)""/>
        </StackPanel>
      </Grid>

      <Border Height=""1"" Background=""#2E271A"" Margin=""14,10,14,8""/>
      <TextBlock Text=""MATCH BONUS"" FontSize=""11"" FontWeight=""SemiBold"" Foreground=""%GOLD%"" Margin=""14,0,14,2""/>
      <Grid Margin=""14,0,14,0"">
        <StackPanel Orientation=""Horizontal"" VerticalAlignment=""Bottom"">
          <TextBlock x:Name=""TxtMaxed"" Text=""0"" FontSize=""44"" FontWeight=""Bold"" LineHeight=""44"" LineStackingStrategy=""BlockLineHeight""/>
          <TextBlock Text=""/ @ROLECOUNT@ roles maxed"" FontSize=""17"" Foreground=""%MUTED%"" VerticalAlignment=""Bottom"" Margin=""6,0,0,5""/>
        </StackPanel>
        <Border x:Name=""Badge"" HorizontalAlignment=""Right"" VerticalAlignment=""Bottom"" Margin=""0,0,0,8"" Visibility=""Collapsed""
                BorderBrush=""%GREEN%"" BorderThickness=""1"" CornerRadius=""3"" Padding=""7,2"">
          <TextBlock Text=""ALL MAXED"" FontSize=""12"" FontWeight=""SemiBold"" Foreground=""%GREEN%""/>
        </Border>
      </Grid>
      <UniformGrid Columns=""@ROLECOUNT@"" Margin=""10,10,10,0"">
@CHIPS@
      </UniformGrid>
      <TextBlock x:Name=""TxtNote"" Text="" "" FontSize=""12.5"" Foreground=""%MUTED%"" Margin=""14,10,14,0"" TextWrapping=""Wrap""/>
      <Grid Margin=""14,6,14,0"">
        <TextBlock Text=""Cash this match"" FontSize=""12.5"" Foreground=""%MUTED%""/>
        <TextBlock x:Name=""TxtCash"" Text=""$0"" FontSize=""13"" FontWeight=""SemiBold"" HorizontalAlignment=""Right""/>
      </Grid>
      <Grid Margin=""14,2,14,0"" ToolTip=""Counted from the KILL and KILL ASSIST popups (cash and XP rows of the same kill count once)"">
        <TextBlock Text=""Kills  ·  assists"" FontSize=""12.5"" Foreground=""%MUTED%""/>
        <TextBlock x:Name=""TxtKills"" Text=""0  ·  0"" FontSize=""13"" FontWeight=""SemiBold"" HorizontalAlignment=""Right""/>
      </Grid>

      <Border Height=""1"" Background=""#2E271A"" Margin=""14,12,14,6""/>
      <Grid Margin=""14,0,14,0"">
        <TextBlock Text=""ROLES"" FontSize=""11"" FontWeight=""SemiBold"" Foreground=""%GOLD%""/>
        <TextBlock Text=""XP THIS MATCH"" FontSize=""11"" Foreground=""%DIM%"" HorizontalAlignment=""Right""/>
      </Grid>
      <StackPanel Margin=""14,2,14,0"">
@ROWS@
      </StackPanel>

      <Border Height=""1"" Background=""#2E271A"" Margin=""14,8,14,6""/>
      <TextBlock Text=""RECENT MATCHES"" FontSize=""11"" FontWeight=""SemiBold"" Foreground=""%GOLD%"" Margin=""14,0,14,2""/>
      <StackPanel x:Name=""HistoryList"" Margin=""14,0,14,0""/>

      <Border Background=""#0F0C08"" CornerRadius=""0,0,6,6"" Margin=""0,10,0,0"" Padding=""14,7,10,7"">
        <DockPanel>
          <Button x:Name=""BtnVersions"" DockPanel.Dock=""Right"" VerticalAlignment=""Top"" Margin=""8,0,0,0"" Style=""{StaticResource Flat}"" FontSize=""10""
                  Content=""v@VERSION@ &#x00B7; VERSIONS"" ToolTip=""Every version on GitHub: download another one or see what changed""/>
          <TextBlock x:Name=""TxtStatus"" Text=""Starting..."" FontSize=""11"" Foreground=""%DIM%"" TextWrapping=""Wrap""/>
        </DockPanel>
      </Border>
    </StackPanel>
  </Border>
</Window>";

        T E<T>(string name) where T : class => ui[name] as T;

        // ------------------------------------------------------------ drawing
        static void SetBar(ColumnDefinition fill, ColumnDefinition rest, long xp)
        {
            double ratio = Math.Min(1.0, Math.Max(0.0, xp / (double)Roles.MatchCap));
            fill.Width = new GridLength(ratio, GridUnitType.Star);
            rest.Width = new GridLength(1 - ratio, GridUnitType.Star);
        }

        public void Refresh()
        {
            lock (tracker.Sync)
            {
                var s = tracker.State;
                var gains = tracker.RoleGains();
                var active = tracker.ActiveRole();

                // Wardog level: all six role levels added up, plus levels gained this match.
                var wl = tracker.WardogLevel();
                E<TextBlock>("TxtWardogLv").Text = wl != null ? wl.ToString() : "-";
                int gained = tracker.LevelsGained();
                E<TextBlock>("TxtLvGain").Text = gained > 0 ? $"+{gained} this match" : " ";

                // Match bonus: how many roles have maxed theirs, and a symbol + mini bar per role.
                int maxed = Roles.Order.Count(r => gains[r] >= Roles.MatchCap);
                bool all = maxed == Roles.Order.Length;
                E<TextBlock>("TxtMaxed").Text = maxed.ToString();
                E<TextBlock>("TxtMaxed").Foreground = maxed > 0 ? Theme.GreenB : Theme.InkB;
                E<Border>("Badge").Visibility = all ? Visibility.Visible : Visibility.Collapsed;
                foreach (var r in Roles.Order)
                {
                    long g = gains[r]; bool rmax = g >= Roles.MatchCap;
                    SetBar(E<ColumnDefinition>(r + "_ChipF"), E<ColumnDefinition>(r + "_ChipR"), g);
                    E<Border>(r + "_ChipFill").Background = rmax ? Theme.GreenB : Theme.GoldB;
                    RoleIcons.SetColor(E<Viewbox>(r + "_Chip"), rmax ? Theme.GreenB : r == active ? Theme.GoldB : g > 0 ? Theme.MutedB : Theme.DimB);
                }

                // One line about the role you're playing (or what to do to finish the match).
                bool live = settings.Continuous && !Program.Demo;
                string note;
                if (s.EndRequested != null) note = "Match over. Open the Wardog Level screen to read your final XP; the bonus is worked out from it. (END MATCH again files it without the bonus.)";
                else if (s.Base == null && !live && s.Events.Count == 0) note = "Open the Wardog Level screen in game to save your starting XP.";
                else if (all) note = "Every role has maxed its bonus this match.";
                else if (active == null) note = "Each role has its own 2,500 XP bonus. Earn XP in a role to start its bar.";
                else
                {
                    long xp = gains[active]; int tier = Roles.Tier(xp); var name = Roles.Names[active];
                    note = xp >= Roles.MatchCap ? $"Playing {name}: maxed. Switch to another role to earn another bonus."
                        : $"Playing {name}: {xp:N0} / {Roles.MatchCap:N0} XP, {Roles.TierSize * (tier + 1) - xp:N0} to tier {tier + 1}.";
                }
                E<TextBlock>("TxtNote").Text = note;
                E<TextBlock>("TxtNote").Foreground = s.EndRequested != null ? Theme.GoldB : Theme.MutedB;
                E<Button>("BtnNext").Content = s.EndRequested != null ? "FILE NOW" : "END MATCH";

                long cash = tracker.MatchCash();
                E<TextBlock>("TxtCash").Text = Theme.Cash(cash) + (s.BankNow == null && s.CashUncertain > 0 ? $"  ({s.CashUncertain} uncertain)" : "");
                E<TextBlock>("TxtCash").Foreground = cash > 0 ? Theme.GreenB : cash < 0 ? Theme.RedB : Theme.DimB;
                var (kills, assists) = Kills.Count(s.Events);
                E<TextBlock>("TxtKills").Text = $"{kills}  ·  {assists}";
                E<TextBlock>("TxtKills").Foreground = kills + assists > 0 ? Theme.InkB : Theme.DimB;

                // Every role's own progress toward its cap.
                foreach (var r in Roles.Order)
                {
                    var lv = s.Levels.GetValueOrDefault(r);
                    bool hasLast = s.Last.TryGetValue(r, out var last), hasNext = s.Next.TryGetValue(r, out var next);
                    long g = gains[r]; int t = Roles.Tier(g); bool rmax = g >= Roles.MatchCap;
                    string toNext = !hasLast || !hasNext ? "" : next <= last ? "  ·  Level up!" : $"  ·  {next - last:N0} to Lv {lv + 1}";
                    E<TextBlock>(r + "_To").Text = lv != null ? $"Lv {lv}{toNext}" : " ";
                    E<TextBlock>(r + "_Name").Foreground = r == active ? Theme.GoldB : Theme.InkB;
                    RoleIcons.SetColor(E<Viewbox>(r + "_Icon"), rmax ? Theme.GreenB : r == active ? Theme.GoldB : Theme.MutedB);
                    E<TextBlock>(r + "_Gain").Text = $"+{g:N0}";
                    E<TextBlock>(r + "_Gain").Foreground = rmax ? Theme.GreenB : g > 0 ? Theme.InkB : Theme.DimB;
                    E<TextBlock>(r + "_Tier").Text = rmax ? "MAX" : $"Tier {t} / {Roles.TierCount}";
                    E<TextBlock>(r + "_Tier").Foreground = rmax ? Theme.GreenB : t > 0 ? Theme.GoldB : Theme.DimB;
                    SetBar(E<ColumnDefinition>(r + "_ColF"), E<ColumnDefinition>(r + "_ColR"), g);
                    E<Border>(r + "_Fill").Background = rmax ? Theme.GreenB : Theme.GoldB;
                }

                DrawHistory();
                DrawStatus();
            }
        }

        void DrawHistory()
        {
            var list = E<StackPanel>("HistoryList");
            list.Children.Clear();
            var recent = tracker.History.Take(5).ToList();
            if (recent.Count == 0)
                list.Children.Add(new TextBlock { Text = "Matches show up here after you press End Match.", FontSize = 12, Foreground = Theme.DimB, Margin = new Thickness(0, 2, 0, 2) });
            foreach (var m in recent)
            {
                // Line 1: when + total XP. Line 2: each role played, with its bonus result.
                var row = new StackPanel { Margin = new Thickness(0, 3, 0, 4), Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = "Show this match's breakdown", Tag = m };
                var top = new Grid();
                top.Children.Add(new TextBlock { Text = Theme.When(m.Start), FontSize = 12.5, Foreground = Theme.MutedB });
                top.Children.Add(new TextBlock
                {
                    Text = $"{m.Xp:N0} XP" + (m.BonusTotal != null ? $"  incl. +{m.BonusTotal:N0} bonus" : "") + (m.Warnings.Count > 0 ? "  !" : ""),
                    FontSize = 12.5, Foreground = Theme.MutedB, HorizontalAlignment = HorizontalAlignment.Right,
                });
                var roles = new TextBlock { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
                bool first = true;
                foreach (var r in Roles.Order)
                {
                    if (!m.Roles.TryGetValue(r, out var g)) continue;
                    int t = Roles.Tier(g);
                    if (!first) roles.Inlines.Add(new Run("   "));
                    first = false;
                    roles.Inlines.Add(new Run($"{Roles.Names[r]} {g:N0} ") { Foreground = Theme.InkB });
                    roles.Inlines.Add(new Run(t >= Roles.TierCount ? "MAX" : $"T{t}") { FontWeight = FontWeights.SemiBold, Foreground = t >= Roles.TierCount ? Theme.GreenB : t > 0 ? Theme.GoldB : Theme.DimB });
                }
                row.Children.Add(top); row.Children.Add(roles);
                // Click a past match to see its breakdown.
                row.MouseLeftButtonUp += (o, e) => { e.Handled = true; MatchDetails.Show((HistoryEntry)((FrameworkElement)o).Tag); };
                row.MouseLeftButtonDown += (_, e) => e.Handled = true;   // don't start a window drag
                list.Children.Add(row);
            }
        }

        public void DrawStatus()
        {
            var s = tracker.State;
            var lines = new List<string> { $"Match started {s.Start.LocalDateTime:h:mm tt}  |  " + (s.LastRead != null ? $"last read {s.LastRead.Value.LocalDateTime:h:mm:ss tt}" : "no reads yet") };
            lines.Add((worker?.LiveState ?? "waiting") switch
            {
                "on" => $"LIVE: reading popups  |  {s.Events.Count} this match",
                "off" => "Live popup tracking is off (Ctrl+Shift+C)",
                "blocked" => "LIVE paused: this window covers the popup area. Move it (Ctrl+Shift+M).",
                "paused" => "Tracking paused (tray menu: Resume tracking)",
                _ => "LIVE paused: waiting for Wardogs",
            });
            var status = worker?.Status;
            if (!string.IsNullOrEmpty(status)) lines.Add(status);
            if (!string.IsNullOrEmpty(ExtraStatus)) lines.Add(ExtraStatus);
            E<TextBlock>("TxtStatus").Text = string.Join("\n", lines);
        }

        public string ExtraStatus;   // e.g. hotkeys another app already uses

        // ------------------------------------------------------------ end of match, tiers
        public void EndMatch()
        {
            ResetFrame();
            worker.EndMatch();
        }

        public void ResetFrame()
        {
            E<Border>("Frame").BorderThickness = new Thickness(1);
            E<Border>("Frame").BorderBrush = Theme.Brush(Theme.Line);
        }

        public void ShowTierAlert(TierUp t, Tray tray)
        {
            long xp = tracker.RoleGains()[t.Role];
            var name = Roles.Names[t.Role];
            if (!Program.Demo)
            {
                if (t.Tier >= Roles.TierCount)
                {
                    System.Media.SystemSounds.Exclamation.Play();
                    tray.Balloon($"{name.ToUpper()} MAX BONUS", $"{xp:N0} {name} XP this match. You've hit the {Roles.MatchCap:N0} cap.", Forms.ToolTipIcon.Info, 6000);
                }
                else
                {
                    System.Media.SystemSounds.Asterisk.Play();
                    tray.Balloon($"{name} bonus tier {t.Tier} of {Roles.TierCount}", $"{xp:N0} / {Roles.MatchCap:N0} {name} XP this match", Forms.ToolTipIcon.None, 4000);
                }
            }
            // Pulse the frame so it's noticeable at a glance.
            var anim = new ColorAnimation
            {
                From = (Color)ColorConverter.ConvertFromString(t.Tier >= Roles.TierCount ? Theme.Green : Theme.Gold),
                To = (Color)ColorConverter.ConvertFromString(Theme.Line),
                Duration = TimeSpan.FromSeconds(2.5),
            };
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(Theme.Line));
            E<Border>("Frame").BorderBrush = brush;
            E<Border>("Frame").BorderThickness = new Thickness(2);
            brush.BeginAnimation(SolidColorBrush.ColorProperty, anim);
        }

        // ------------------------------------------------------------ show, hide, tray
        // Shown without taking focus from the game (hotkey, tray).
        public void ShowWindow()
        {
            hidden = false;
            Win.Show();
            if (Win.WindowState == WindowState.Minimized) Win.WindowState = WindowState.Normal;
            Native.KeepOnTop(Hwnd);
            VisibilityChanged?.Invoke();
        }

        public void HideToTray()
        {
            hidden = true;
            if (Win.WindowState == WindowState.Minimized) Win.WindowState = WindowState.Normal;
            Win.Hide();
            VisibilityChanged?.Invoke();
        }

        public void Toggle() { if (hidden) ShowWindow(); else HideToTray(); }

        // Another copy was started: come to the front (this one does take focus).
        public void BringToFront()
        {
            ShowWindow();
            Win.Activate();
            Native.SetForegroundWindow(Hwnd);
        }

        // Makes the window invisible for a moment so a screenshot can see what's behind it.
        public void SetGhost(bool ghost) => Win.Opacity = ghost ? 0 : settings.Opacity / 100.0;

        public void SetClickThrough(bool on)
        {
            settings.ClickThrough = on; Program.SaveSettings();
            Native.SetClickThrough(Hwnd, on);
        }

        public void SetOpacity(int value)
        {
            settings.Opacity = Math.Max(30, Math.Min(100, value)); Program.SaveSettings();
            Win.Opacity = settings.Opacity / 100.0;
        }

        // ------------------------------------------------------------ placement
        // Screen pixels per WPF unit (1.0 at 100% scaling).
        public double Scale => PresentationSource.FromVisual(Win)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;

        void MoveTo(int x, int y) { var s = Scale; Win.Left = x / s; Win.Top = y / s; }

        Forms.Screen CurrentScreen() => Forms.Screen.FromRectangle(Native.WindowRect(Hwnd));

        // Shrinks the whole window evenly if it's taller than the screen (small laptop screens), else full size.
        void ResizeToScreen(Forms.Screen screen)
        {
            var s = Scale;
            var frame = E<Border>("Frame");
            frame.LayoutTransform = Transform.Identity;
            Win.Width = 330;
            Win.UpdateLayout();
            double fit = (screen.WorkingArea.Height / s) / Math.Max(1, Win.ActualHeight);
            if (fit < 1)
            {
                frame.LayoutTransform = new ScaleTransform(fit, fit);
                Win.Width = 330 * fit;
                Win.UpdateLayout();
            }
        }

        static readonly string[] spots = { "TopRight", "BottomRight", "BottomLeft", "TopLeft" };
        string spot;

        // Places the window at a corner (or the center) of a monitor and remembers it.
        public void MoveToSpot(string where, Forms.Screen screen = null)
        {
            screen ??= CurrentScreen();
            ResizeToScreen(screen);
            var wa = screen.WorkingArea; var s = Scale;
            int w = (int)(Win.ActualWidth * s), h = (int)(Win.ActualHeight * s);
            int x = where.EndsWith("Right") ? wa.Right - w : where.EndsWith("Left") ? wa.Left : wa.Left + (wa.Width - w) / 2;
            int y = where.StartsWith("Top") ? wa.Top : where.StartsWith("Bottom") ? wa.Bottom - h : wa.Top + (wa.Height - h) / 2;
            MoveTo(x, y);
            spot = where;
            settings.WindowPos = $"{x},{y}"; Program.SaveSettings();
        }

        public void MoveToNextCorner() => MoveToSpot(spots[(Array.IndexOf(spots, spot) + 1) % spots.Length]);

        public void MoveToNextMonitor()
        {
            var all = Forms.Screen.AllScreens; var cur = CurrentScreen();
            int i = Array.FindIndex(all, x => x.DeviceName == cur.DeviceName);
            MoveToSpot("TopRight", all[(Math.Max(0, i) + 1) % all.Length]);
        }

        public void PlaceAtStart()
        {
            try
            {
                var screens = Forms.Screen.AllScreens;
                var p = (settings.WindowPos ?? "").Split(',');
                if (p.Length == 2 && int.TryParse(p[0], out var x) && int.TryParse(p[1], out var y))
                {
                    // Reuse the saved spot only if it's still on a connected monitor.
                    var screen = screens.FirstOrDefault(sc => sc.WorkingArea.Contains(x + 20, y + 20));
                    if (screen != null) { ResizeToScreen(screen); MoveTo(x, y); return; }
                }
                // First run: top-right of a second monitor if there is one, otherwise the main screen.
                MoveToSpot("TopRight", screens.FirstOrDefault(sc => !sc.Primary) ?? Forms.Screen.PrimaryScreen);
            }
            catch (Exception e)
            {
                // Never leave the window stranded off-screen: fall back to the middle of the main screen.
                Log.Write("placement ERROR " + e.Message);
                try { MoveToSpot("Center", Forms.Screen.PrimaryScreen); } catch { Win.Left = 100; Win.Top = 100; }
            }
        }

        // ------------------------------------------------------------ pictures
        // A picture of the tracker window as it looks now (2x size, for a sharp image).
        public bool SaveSnapshot(string path)
        {
            try
            {
                if (Win.Content is not FrameworkElement el || el.ActualWidth < 10) return false;
                double w = el.ActualWidth, h = el.ActualHeight;
                var dv = new DrawingVisual();
                using (var dc = dv.RenderOpen())
                {
                    dc.DrawRectangle(Theme.Brush("#14100A"), null, new Rect(0, 0, w, h));
                    dc.DrawRectangle(new VisualBrush(el), null, new Rect(0, 0, w, h));
                }
                var rtb = new RenderTargetBitmap((int)(w * 2), (int)(h * 2), 192, 192, PixelFormats.Pbgra32);
                rtb.Render(dv);
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(rtb));
                using var fs = File.Create(path);
                enc.Save(fs);
                return true;
            }
            catch (Exception e) { Log.Write("snapshot ERROR " + e.Message); return false; }
        }

        // The window right after a match is filed (the match at the top of Recent Matches, with the Wardog
        // level), saved next to the match's popups as matches\<start>.png.
        public void SaveFiledSnapshot(HistoryEntry entry)
        {
            Win.UpdateLayout();
            var rel = $"matches\\{entry.Start.LocalDateTime:yyyyMMdd-HHmmss}.png";
            if (SaveSnapshot(Path.Combine(tracker.DataDir, rel))) tracker.SetSnapshot(entry, rel);
        }
    }
}
