using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using Wardogs.Core;

namespace Wardogs.App
{
    // One match's breakdown: totals, the deduced bonus, totals by reason, and every popup in order.
    // Shown in a window, and saved as a single HTML page (with the picture of the tracker after the match).
    public static class MatchDetails
    {
        public sealed class Line
        {
            public string Kind;   // head | row | note
            public string Left, Right, LeftColor, RightColor = Theme.Ink, Weight = "Normal";
            public double Top;
        }

        static string Title(string s) => CultureInfo.CurrentCulture.TextInfo.ToTitleCase((s ?? "").ToLower());

        public static List<Line> Lines(HistoryEntry e, List<PopupEvent> events, bool live)
        {
            var o = new List<Line>();
            void Head(string t) => o.Add(new Line { Kind = "head", Left = t, LeftColor = Theme.Gold });
            void Note(string t, string c, double top) => o.Add(new Line { Kind = "note", Left = t, LeftColor = c, Top = top });
            void Row(string l, string r, string lc = Theme.Ink, string rc = Theme.Ink, string w = "Normal") => o.Add(new Line { Kind = "row", Left = l, Right = r, LeftColor = lc, RightColor = rc, Weight = w });
            static string CashColor(long v) => v >= 0 ? Theme.Green : Theme.Red;

            Head("SUMMARY");
            Row("Total XP", $"+{e.Xp:N0}", Theme.Muted, Theme.Ink, "SemiBold");
            foreach (var r in Roles.Order)
                if (e.Roles.TryGetValue(r, out var g)) { int t = Roles.Tier(g); Row($"   {Roles.Names[r]}", $"+{g:N0}  {(t >= Roles.TierCount ? "MAX" : "T" + t)}", Theme.Muted, t >= Roles.TierCount ? Theme.Green : Theme.Ink); }
            if (e.BonusTotal != null)
            {
                Row("End-of-match bonus (deduced)" + (e.Placement != null ? $", {e.Placement}" : ""), $"+{e.BonusTotal:N0}", Theme.Gold, Theme.Gold, "SemiBold");
                foreach (var r in Roles.Order) if (e.Bonus.TryGetValue(r, out var b) && b != 0) Row($"   {Roles.Names[r]}", $"+{b:N0}", Theme.Muted, Theme.Gold);
            }
            else if (!live) Row("End-of-match bonus (deduced)", "not available", Theme.Muted, Theme.Dim);
            if (e.NetCash != null) Row("Cash this match (incl. gear bought)", Theme.Cash(e.NetCash.Value), Theme.Muted, CashColor(e.NetCash.Value), "SemiBold");
            Row("Cash from popups", Theme.Cash(e.Cash), Theme.Muted, CashColor(e.Cash), e.NetCash == null ? "SemiBold" : "Normal");
            if (e.ResultsCash != null) Row("Cash on the results screen", Theme.Cash(e.ResultsCash.Value), Theme.Muted, Theme.Ink);
            if (events.Count > 0)
            {
                var (kills, assists) = Kills.Count(events);
                Row("Kills", kills.ToString(), Theme.Muted, Theme.Ink);
                Row("Kill assists", assists.ToString(), Theme.Muted, Theme.Ink);
            }

            if (e.Warnings.Count > 0)
            {
                Head("CONFIDENCE");
                foreach (var w in e.Warnings) Note("!  " + w, Theme.Warn, 2);
            }

            foreach (var (head, kind) in new[] { ("XP BY REASON", "xp"), ("CASH BY REASON", "cash") })
            {
                var list = events.Where(x => x.Kind == kind).ToList();
                if (list.Count == 0) continue;
                Head(head);
                foreach (var g in list.GroupBy(x => x.Reason ?? "").OrderBy(g => -Math.Abs(g.Sum(x => x.Amount))))
                {
                    long sum = g.Sum(x => x.Amount);
                    var label = g.Key.Length > 0 ? Title(g.Key) : "Unlabeled";
                    Row($"{label}  x{g.Count()}", kind == "xp" ? $"+{sum:N0} XP" : Theme.Cash(sum));
                }
            }

            if (events.Count > 0)
            {
                Head($"EVERY POPUP ({events.Count})");
                foreach (var x in events)
                {
                    var t = x.T.LocalDateTime.ToString("h:mm:ss");
                    if (x.Kind == "xp") Row($"{t}   {Title(x.Reason)}", $"+{x.Amount:N0} XP  {(x.HasRole ? Roles.Name(x.Role) : "?")}", Theme.Muted, Theme.Ink);
                    else Row($"{t}   {Title(x.Reason)}", Theme.Cash(x.Amount) + (x.Uncertain ? " ?" : ""), Theme.Muted, CashColor(x.Amount));
                }
            }
            else Note("No popups were recorded for this match.", Theme.Dim, 14);
            return o;
        }

        // The match in progress, as an entry.
        static (HistoryEntry, List<PopupEvent>) Current(Tracker tr)
        {
            lock (tr.Sync)
            {
                var s = tr.State; var gains = tr.RoleGains();
                var e = new HistoryEntry
                {
                    Start = s.Start, End = null, Roles = gains.Where(g => g.Value > 0).ToDictionary(g => g.Key, g => g.Value),
                    Cash = s.Cash, ResultsCash = s.ResultsCash, NetCash = s.BankStart != null && s.BankNow != null ? tr.MatchCash() : null, Unparsed = s.Unparsed,
                };
                e.Xp = e.Roles.Values.Sum();
                if (s.Unparsed > 0) e.Warnings.Add($"{s.Unparsed} popup reads couldn't be understood so far.");
                if (s.UnknownXp > 0) e.Warnings.Add($"{s.UnknownXp} popup XP couldn't be matched to a class.");
                if (s.CashUncertain > 0) e.Warnings.Add($"{s.CashUncertain} cash amounts are uncertain (the $ sign was misread).");
                return (e, s.Events.ToList());
            }
        }

        // entry: a filed match from history, or null for the match in progress.
        public static void Show(HistoryEntry entry)
        {
            var tr = Program.Tracker;
            bool live = entry == null;
            List<PopupEvent> events;
            if (live) (entry, events) = Current(tr); else events = tr.LoadEvents(entry);
            var lines = Lines(entry, events, live);

            var when = Theme.When(entry.Start) + (entry.End != null ? $" - {entry.End.Value.LocalDateTime:h:mm tt}" : "  (in progress)");
            var w = (Window)XamlReader.Parse(Theme.Fill(@"
<Window xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml""
        Title=""Match details"" Width=""440"" SizeToContent=""Height"" WindowStyle=""None"" AllowsTransparency=""True"" Background=""Transparent""
        Topmost=""True"" ShowInTaskbar=""False"" ResizeMode=""NoResize"" FontFamily=""Bahnschrift, Segoe UI"" Foreground=""%INK%"" UseLayoutRounding=""True"">
  <Border CornerRadius=""6"" BorderBrush=""%LINE%"" BorderThickness=""1"" Background=""#FF14100A"">
    <DockPanel>
      <Grid DockPanel.Dock=""Top"" x:Name=""DHead"" Background=""#01000000"" Margin=""16,12,10,6"" Cursor=""SizeAll"">
        <StackPanel>
          <TextBlock Text=""//MATCH DETAILS"" FontSize=""11"" FontWeight=""SemiBold"" Foreground=""%GOLD%""/>
          <TextBlock x:Name=""DWhen"" FontSize=""16"" FontWeight=""SemiBold""/>
        </StackPanel>
        <StackPanel Orientation=""Horizontal"" HorizontalAlignment=""Right"" VerticalAlignment=""Top"">
          <Button x:Name=""DPic"" Content=""PICTURE"" ToolTip=""The tracker right after this match was filed"" Foreground=""%MUTED%"" Background=""Transparent"" BorderBrush=""%LINE%"" Padding=""8,3"" FontSize=""11"" Cursor=""Hand"" Margin=""0,0,6,0""/>
          <Button x:Name=""DSave"" Content=""SAVE"" ToolTip=""Save this page (with the picture) to Documents\Wardogs XP Tracker and open it"" Foreground=""%GOLD%"" Background=""Transparent"" BorderBrush=""%LINE%"" Padding=""8,3"" FontSize=""11"" Cursor=""Hand"" Margin=""0,0,6,0""/>
          <Button x:Name=""DClose"" Content=""CLOSE"" Foreground=""%MUTED%"" Background=""Transparent"" BorderBrush=""%LINE%"" Padding=""8,3"" FontSize=""11"" Cursor=""Hand""/>
        </StackPanel>
      </Grid>
      <ScrollViewer x:Name=""DScroll"" VerticalScrollBarVisibility=""Auto"" Margin=""16,0,8,14"">
        <StackPanel x:Name=""DBody"" Margin=""0,0,8,0""/>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>"));
            var body = (StackPanel)w.FindName("DBody");
            ((TextBlock)w.FindName("DWhen")).Text = when;
            ((Button)w.FindName("DClose")).Click += (_, _) => w.Close();
            ((FrameworkElement)w.FindName("DHead")).MouseLeftButtonDown += (_, _) => { try { w.DragMove(); } catch { } };
            ((ScrollViewer)w.FindName("DScroll")).MaxHeight = Math.Max(300, SystemParameters.WorkArea.Height * 0.8);

            foreach (var ln in lines)
            {
                if (ln.Kind == "row")
                {
                    var g = new Grid { Margin = new Thickness(0, 2, 0, 0) };
                    var weight = ln.Weight == "SemiBold" ? FontWeights.SemiBold : FontWeights.Normal;
                    g.Children.Add(new TextBlock { Text = ln.Left, Foreground = Theme.Brush(ln.LeftColor), FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 90, 0), FontWeight = weight });
                    g.Children.Add(new TextBlock { Text = ln.Right, Foreground = Theme.Brush(ln.RightColor), FontSize = 13, HorizontalAlignment = HorizontalAlignment.Right, FontWeight = weight });
                    body.Children.Add(g);
                }
                else
                {
                    bool head = ln.Kind == "head";
                    body.Children.Add(new TextBlock
                    {
                        Text = ln.Left, Foreground = Theme.Brush(ln.LeftColor), TextWrapping = TextWrapping.Wrap,
                        FontSize = head ? 11 : 12.5, FontWeight = head ? FontWeights.SemiBold : FontWeights.Normal,
                        Margin = new Thickness(0, head ? 14 : ln.Top, 0, 0),
                    });
                }
            }

            // PICTURE: the tracker right after the match was filed (matches filed from v2.3 on).
            var pic = entry.Snapshot != null ? Path.Combine(tr.DataDir, entry.Snapshot) : null;
            var picBtn = (Button)w.FindName("DPic");
            if (pic != null && File.Exists(pic)) picBtn.Click += (_, _) => Open(pic); else picBtn.Visibility = Visibility.Collapsed;
            ((Button)w.FindName("DSave")).Click += (_, _) =>
            {
                try
                {
                    var file = Export(entry, lines, live);
                    Log.Write("match saved to " + file);
                    Open(file);
                }
                catch (Exception ex) { Log.Write("save ERROR " + ex.Message); Program.Window.ExtraStatus = "Couldn't save the match: " + ex.Message; Program.Window.DrawStatus(); }
            };

            // Open next to the tracker, on the same screen.
            var main = Program.Window.Win;
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = Math.Max(0, main.Left - 450); w.Top = main.Top;
            if (w.Left + 10 < SystemParameters.VirtualScreenLeft) w.Left = main.Left + main.ActualWidth + 10;
            w.Show();
        }

        static void Open(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception e) { Log.Write("open ERROR " + e.Message); } }

        // SAVE: writes the page, with the picture of the tracker after the match, as one HTML file in
        // Documents\Wardogs XP Tracker. Returns the file's path.
        public static string Export(HistoryEntry e, List<Line> lines, bool live)
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Wardogs XP Tracker");
            Directory.CreateDirectory(dir);
            var start = e.Start.LocalDateTime;
            var file = Path.Combine(dir, $"Wardogs match {start:yyyy-MM-dd h.mm tt}.html");
            static string Enc(string s) => WebUtility.HtmlEncode(s ?? "");

            // The picture: saved after the match was filed, or (for the match in progress) the window right now.
            var img = "";
            var pic = e.Snapshot != null ? Path.Combine(Program.Tracker.DataDir, e.Snapshot) : null;
            if (live) { pic = Path.Combine(Path.GetTempPath(), "wardogs-live-snapshot.png"); if (!Program.Window.SaveSnapshot(pic)) pic = null; }
            if (pic != null && File.Exists(pic))
                img = "<figure><img alt=\"The tracker after this match\" src=\"data:image/png;base64," + Convert.ToBase64String(File.ReadAllBytes(pic)) + "\"><figcaption>" +
                      (live ? "The tracker when this was saved" : "The tracker right after this match was filed") + "</figcaption></figure>";
            var when = start.ToString("dddd, MMM d, yyyy h:mm tt") + (e.End != null ? " - " + e.End.Value.LocalDateTime.ToString("h:mm tt") : " (in progress)");

            var rows = new StringBuilder();
            foreach (var ln in lines)
            {
                if (ln.Kind == "head") rows.AppendLine($"<h2>{Enc(ln.Left)}</h2>");
                else if (ln.Kind == "note") rows.AppendLine($"<p class=\"note\" style=\"color:{ln.LeftColor}\">{Enc(ln.Left)}</p>");
                else rows.AppendLine($"<div class=\"row{(ln.Weight == "SemiBold" ? " b" : "")}\"><span style=\"color:{ln.LeftColor}\">{Enc(ln.Left)}</span><span style=\"color:{ln.RightColor}\">{Enc(ln.Right)}</span></div>");
            }
            var html = $@"<!doctype html>
<html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1"">
<title>Wardogs match {Enc(start.ToString("MMM d h:mm tt"))}</title>
<style>
body {{ margin: 0; background: #0B0907; color: {Theme.Ink}; font: 14px/1.45 Bahnschrift, 'Segoe UI', sans-serif; }}
main {{ max-width: 820px; margin: 0 auto; padding: 28px 16px 48px; display: flex; gap: 32px; align-items: flex-start; flex-wrap: wrap; }}
header {{ width: 100%; }}
.eyebrow {{ color: {Theme.Gold}; font-size: 12px; font-weight: 600; letter-spacing: .06em; }}
h1 {{ margin: 2px 0 0; font-size: 22px; font-weight: 600; }}
figure {{ margin: 0; flex: 0 0 auto; }}
figure img {{ display: block; width: 330px; max-width: 100%; border-radius: 6px; border: 1px solid {Theme.Line}; }}
figcaption {{ color: {Theme.Dim}; font-size: 12px; margin-top: 6px; }}
.list {{ flex: 1 1 360px; min-width: 0; }}
h2 {{ color: {Theme.Gold}; font-size: 12px; font-weight: 600; letter-spacing: .04em; margin: 18px 0 4px; }}
.row {{ display: flex; justify-content: space-between; gap: 16px; padding: 2px 0; border-bottom: 1px solid #1E1912; }}
.row span:first-child {{ white-space: pre-wrap; }}
.row span:last-child {{ white-space: nowrap; text-align: right; }}
.b {{ font-weight: 600; }}
.note {{ margin: 4px 0; font-size: 13px; }}
footer {{ width: 100%; color: {Theme.Dim}; font-size: 12px; }}
</style></head><body><main>
<header><div class=""eyebrow"">//MATCH DETAILS</div><h1>{Enc(when)}</h1></header>
{img}
<div class=""list"">
{rows}</div>
<footer>Saved by Wardogs XP Tracker v{Program.Version}.</footer>
</main></body></html>";
            File.WriteAllText(file, html, new UTF8Encoding(true));
            return file;
        }
    }
}
