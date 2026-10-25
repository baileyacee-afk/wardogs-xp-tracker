#Requires -Version 5.1
<#
  Wardogs XP Tracker
  A small always-on-top window that tracks the XP you earn each match toward the
  2,500 XP end-of-match bonus cap. It reads your XP from the in-game "Wardog Level"
  screen with Windows' built-in OCR (screenshots only, never the game's memory).

  Hotkeys:
    Ctrl+Shift+N          Next match (files the current one into history)
    Ctrl+Shift+U          Find the Wardog Level panel now (open it in game first)
    Ctrl+Shift+O          Show / hide
    Ctrl+Shift+L          Click-through on/off
    Ctrl+Shift+PageUp     More opaque
    Ctrl+Shift+PageDown   More transparent
    Ctrl+Shift+M          Move to the next corner of the screen (or drag it anywhere)
    Ctrl+Shift+R          Start / stop recording samples of the top-right corner (class picked in the tray)
    Ctrl+Shift+S          Save a full screenshot of the game (e.g. the end-of-match screen)

  -Demo plays back made-up reads (no game needed) using a throwaway data folder.
#>
param([switch]$Demo)

# Matches the GitHub release tag (v1.0, v1.1, ...) and CHANGELOG.md.
$AppVersion = '1.1'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# The launcher runs this hidden, so surface startup errors in a dialog.
trap {
    if ($LogFile) { Add-Content -Path $LogFile -Value "$(Get-Date -Format s) ERROR $_" -Encoding utf8 }
    [System.Windows.Forms.MessageBox]::Show("Wardogs XP Tracker failed:`n`n$_", 'Wardogs XP Tracker') | Out-Null
    exit 1
}

# ---------------------------------------------------------------- single instance
$mutex = New-Object System.Threading.Mutex($false, $(if ($Demo) { 'Local\WardogsXpTrackerDemo' } else { 'Local\WardogsXpTracker' }))
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }  # previous run was killed
if (-not $owned) {
    [System.Windows.Forms.MessageBox]::Show('Wardogs XP Tracker is already running (see the tray icon).', 'Wardogs XP Tracker') | Out-Null
    exit
}

# ---------------------------------------------------------------- native helpers
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class WdNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr h, int idx, int v);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);

    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    const uint NOSIZE = 0x1, NOMOVE = 0x2, NOACTIVATE = 0x10;

    public static void KeepOnTop(IntPtr h) { SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, NOSIZE | NOMOVE | NOACTIVATE); }

    public static void SetClickThrough(IntPtr h, bool on) {
        const int GWL_EXSTYLE = -20, WS_EX_TRANSPARENT = 0x20;
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, on ? (ex | WS_EX_TRANSPARENT) : (ex & ~WS_EX_TRANSPARENT));
    }
}

public class WdHotkeys : NativeWindow, IDisposable {
    public event Action<int> Pressed;
    int count;
    public WdHotkeys() { CreateHandle(new CreateParams()); }
    public bool Add(int id, uint mods, uint vk) { count = Math.Max(count, id); return WdNative.RegisterHotKey(Handle, id, mods | 0x4000, vk); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= count; i++) WdNative.UnregisterHotKey(Handle, i); DestroyHandle(); }
}
'@
# Real pixel coordinates everywhere, so placement and screenshots line up on scaled monitors.
[WdNative]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------- data & settings
$DataDir = if ($Demo) { Join-Path $env:TEMP 'WardogsXpTracker-demo' } else { Join-Path $env:LOCALAPPDATA 'WardogsXpTracker' }
if ($Demo -and (Test-Path $DataDir)) { Remove-Item -Recurse -Force $DataDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$LogFile = Join-Path $DataDir 'tracker.log'
Set-Content -Path $LogFile -Value "$(Get-Date -Format s) starting v$AppVersion" -Encoding utf8
function Write-Log([string]$Text) { Add-Content -Path $LogFile -Value "$(Get-Date -Format s) $Text" -Encoding utf8 }

$SettingsFile = Join-Path $DataDir 'settings.json'
$Settings = [ordered]@{
    Opacity      = 100
    ClickThrough = $false
    PanelRect    = $null   # "x,y,w,h": where the in-game Wardog Level panel was last found
    PanelRoles   = 0       # how many roles were readable when it was found
    RecordRect   = $null   # "x,y,w,h": area the sample recorder saves; default is the game's top-right
    RecordLabel  = 'Unlabeled'   # class picked for the next recording
    WindowPos    = $null   # "x,y": where you last dragged the window
}
if (Test-Path $SettingsFile) {
    try {
        $saved = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($k in @($Settings.Keys)) { if ($null -ne $saved.$k) { $Settings[$k] = $saved.$k } }
    } catch {}
}
function Save-Settings { $Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding utf8 }

. (Join-Path $PSScriptRoot 'GameReader.ps1')
. (Join-Path $PSScriptRoot 'TrackerCore.ps1')
. (Join-Path $PSScriptRoot 'Recorder.ps1')
Initialize-Tracker $DataDir

# ---------------------------------------------------------------- window
$Gold = '#D8B45A'; $Green = '#5BD06E'; $Ink = '#EADFC4'; $Muted = '#9A8F78'; $Dim = '#6F6654'

$tickBorders = (1..$TierCount | ForEach-Object { if ($_ -lt $TierCount) { '<Border BorderBrush="#0B0907" BorderThickness="0,0,2,0"/>' } else { '<Border/>' } }) -join ''

# One row per role: name, level, XP this match, bonus tier, and a bar toward the 2,500 cap.
$roleRows = foreach ($r in $RoleOrder) {
@"
        <Grid Margin="0,5,0,5">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock x:Name="${r}_Name" Text="$($RoleNames[$r])" FontSize="14" FontWeight="SemiBold"/>
            <TextBlock x:Name="${r}_To" Text=" " FontSize="11" Foreground="$Dim"/>
          </StackPanel>
          <StackPanel Grid.Column="1">
            <TextBlock x:Name="${r}_Gain" Text="+0" FontSize="15" FontWeight="SemiBold" Foreground="$Dim" HorizontalAlignment="Right"/>
            <TextBlock x:Name="${r}_Tier" Text="Tier 0 / $TierCount" FontSize="11" Foreground="$Dim" HorizontalAlignment="Right"/>
          </StackPanel>
          <Grid Grid.Row="1" Grid.ColumnSpan="2" Height="5" Margin="0,4,0,0">
            <Border Background="#2B2519" CornerRadius="2"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name="${r}_ColF" Width="0*"/><ColumnDefinition x:Name="${r}_ColR" Width="1*"/></Grid.ColumnDefinitions>
              <Border x:Name="${r}_Fill" Background="$Gold" CornerRadius="2"/>
            </Grid>
            <UniformGrid Columns="$TierCount">$tickBorders</UniformGrid>
          </Grid>
        </Grid>
"@
}

$tierLabels = foreach ($t in 1..$TierCount) {
    "<TextBlock x:Name=`"T$t`" Text=`"$('{0:N0}' -f ($t * $TierSize))`" FontSize=`"10.5`" Foreground=`"$Dim`" HorizontalAlignment=`"Right`"/>"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wardogs XP Tracker" Width="330" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        FontFamily="Bahnschrift, Segoe UI" Foreground="$Ink" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Flat" TargetType="Button">
      <Setter Property="Foreground" Value="$Muted"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#4A3F28"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="3" Padding="8,3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2B2519"/>
                <Setter Property="Foreground" Value="$Ink"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Frame" CornerRadius="6" BorderBrush="#4A3F28" BorderThickness="1">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#FF1A150C" Offset="0"/>
        <GradientStop Color="#FF0B0907" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <StackPanel>

      <!-- header: drag to move -->
      <Grid x:Name="Header" Background="#01000000" Margin="14,10,10,0" Cursor="SizeAll">
        <StackPanel>
          <TextBlock Text="//WARDOGS" FontSize="11" FontWeight="SemiBold" Foreground="$Gold"/>
          <TextBlock Text="MATCH BONUS" FontSize="16" FontWeight="SemiBold"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Button x:Name="BtnNext" Style="{StaticResource Flat}" Content="NEXT MATCH" ToolTip="File this match and start a new one (Ctrl+Shift+N)"/>
          <Button x:Name="BtnHide" Style="{StaticResource Flat}" Content="&#x2013;" Margin="4,0,0,0" ToolTip="Hide (Ctrl+Shift+O)"/>
        </StackPanel>
      </Grid>

      <!-- featured role: the one you're playing -->
      <TextBlock x:Name="TxtRole" Text="NO XP YET" FontSize="13" FontWeight="SemiBold" Foreground="$Gold" Margin="14,12,14,0"/>
      <Grid Margin="14,0,14,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
          <TextBlock x:Name="TxtXp" Text="0" FontSize="44" FontWeight="Bold" LineHeight="44" LineStackingStrategy="BlockLineHeight"/>
          <TextBlock x:Name="TxtCap" Text="/ $('{0:N0}' -f $MatchCap)" FontSize="17" Foreground="$Muted" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
        </StackPanel>
        <Border x:Name="Badge" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,8"
                BorderBrush="#4A3F28" BorderThickness="1" CornerRadius="3" Padding="7,2">
          <TextBlock x:Name="TxtTier" Text="TIER 0 / $TierCount" FontSize="12" FontWeight="SemiBold" Foreground="$Gold"/>
        </Border>
      </Grid>

      <Grid Height="10" Margin="14,8,14,0">
        <Border Background="#2B2519" CornerRadius="5"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition x:Name="ColFill" Width="0*"/>
            <ColumnDefinition x:Name="ColRest" Width="1*"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="Fill" Background="$Gold" CornerRadius="5"/>
        </Grid>
        <UniformGrid Columns="$TierCount">$tickBorders</UniformGrid>
      </Grid>
      <UniformGrid Columns="$TierCount" Margin="14,4,14,0">
        $($tierLabels -join "`n        ")
      </UniformGrid>
      <TextBlock x:Name="TxtNote" Text=" " FontSize="12.5" Foreground="$Muted" Margin="14,8,14,0" TextWrapping="Wrap"/>

      <!-- roles -->
      <Border Height="1" Background="#2E271A" Margin="14,12,14,6"/>
      <Grid Margin="14,0,14,0">
        <TextBlock Text="ROLES" FontSize="11" FontWeight="SemiBold" Foreground="$Gold"/>
        <TextBlock Text="XP THIS MATCH" FontSize="11" Foreground="$Dim" HorizontalAlignment="Right"/>
      </Grid>
      <StackPanel Margin="14,2,14,0">
$($roleRows -join "`n")
      </StackPanel>

      <!-- history -->
      <Border Height="1" Background="#2E271A" Margin="14,8,14,6"/>
      <TextBlock Text="RECENT MATCHES" FontSize="11" FontWeight="SemiBold" Foreground="$Gold" Margin="14,0,14,2"/>
      <StackPanel x:Name="HistoryList" Margin="14,0,14,0"/>

      <!-- status -->
      <Border Background="#0F0C08" CornerRadius="0,0,6,6" Margin="0,10,0,0" Padding="14,7">
        <TextBlock x:Name="TxtStatus" Text="Starting..." FontSize="11" Foreground="$Dim" TextWrapping="Wrap"/>
      </Border>
    </StackPanel>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $win.FindName($name) }
}

function New-Brush([string]$Hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)) }
$Brush = @{ Gold = New-Brush $Gold; Green = New-Brush $Green; Ink = New-Brush $Ink; Muted = New-Brush $Muted; Dim = New-Brush $Dim }

function Format-When([string]$Iso) {
    $t = [datetime]::Parse($Iso)
    $day = if ($t.Date -eq (Get-Date).Date) { 'Today' } elseif ($t.Date -eq (Get-Date).Date.AddDays(-1)) { 'Yesterday' } else { $t.ToString('MMM d') }
    "$day $($t.ToString('h:mm tt'))"
}

$script:Status = ''
function Set-Status([string]$Text) { $script:Status = $Text; Update-UI }

function Set-Bar($ColFill, $ColRest, [long]$Xp) {
    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $Xp / [double]$MatchCap))
    $ColFill.Width = New-Object System.Windows.GridLength $ratio, 'Star'
    $ColRest.Width = New-Object System.Windows.GridLength (1 - $ratio), 'Star'
}

function Update-UI {
    $gains  = Get-RoleGains
    $active = Get-ActiveRole

    # Featured role at the top.
    $xp   = if ($active) { $gains[$active] } else { [long]0 }
    $tier = Get-Tier $xp
    $max  = $xp -ge $MatchCap
    $ui.TxtRole.Text = if ($active) { $RoleNames[$active].ToUpper() } else { 'NO XP YET THIS MATCH' }
    $ui.TxtXp.Text = '{0:N0}' -f $xp
    $ui.TxtXp.Foreground = if ($max) { $Brush.Green } else { $Brush.Ink }
    Set-Bar $ui.ColFill $ui.ColRest $xp
    $ui.Fill.Background = if ($max) { $Brush.Green } else { $Brush.Gold }
    $ui.TxtTier.Text = if ($max) { 'MAX BONUS' } else { "TIER $tier / $TierCount" }
    $ui.TxtTier.Foreground = if ($max) { $Brush.Green } else { $Brush.Gold }
    $ui.Badge.BorderBrush = if ($max) { $Brush.Green } else { New-Brush '#4A3F28' }
    foreach ($t in 1..$TierCount) { $ui["T$t"].Foreground = if ($tier -ge $t) { $ui.Fill.Background } else { $Brush.Dim } }

    $ui.TxtNote.Text =
        if (-not $State.Base) { 'Open the Wardog Level screen in game to save your starting XP.' }
        elseif (-not $active) { 'Each role has its own 2,500 XP bonus cap. The role you earn XP in shows up here.' }
        elseif ($max)         { "$($RoleNames[$active]) is maxed for this match. Another role can still earn its own bonus." }
        else                  { "$('{0:N0}' -f ($TierSize * ($tier + 1) - $xp)) XP to tier $($tier + 1)" }

    # Every role's own progress toward its cap.
    $dot = [char]0xB7
    foreach ($r in $RoleOrder) {
        $lv = $State.Levels[$r]; $last = $State.Last[$r]; $next = $State.Next[$r]
        $g = $gains[$r]; $t = Get-Tier $g; $rmax = $g -ge $MatchCap
        $toNext =
            if ($null -eq $last -or $null -eq $next) { '' }
            elseif ($next -le $last)                 { "  $dot  Level up!" }
            else                                     { "  $dot  $('{0:N0}' -f ($next - $last)) to Lv $($lv + 1)" }
        $ui["${r}_To"].Text = if ($null -ne $lv) { "Lv $lv$toNext" } else { ' ' }
        $ui["${r}_Name"].Foreground = if ($r -eq $active) { $Brush.Gold } else { $Brush.Ink }
        $ui["${r}_Gain"].Text = '+{0:N0}' -f $g
        $ui["${r}_Gain"].Foreground = if ($rmax) { $Brush.Green } elseif ($g -gt 0) { $Brush.Ink } else { $Brush.Dim }
        $ui["${r}_Tier"].Text = if ($rmax) { 'MAX' } else { "Tier $t / $TierCount" }
        $ui["${r}_Tier"].Foreground = if ($rmax) { $Brush.Green } elseif ($t -gt 0) { $Brush.Gold } else { $Brush.Dim }
        Set-Bar $ui["${r}_ColF"] $ui["${r}_ColR"] $g
        $ui["${r}_Fill"].Background = if ($rmax) { $Brush.Green } else { $Brush.Gold }
    }

    $ui.HistoryList.Children.Clear()
    $recent = @($History | Select-Object -First 5)
    if (-not $recent.Count) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'Matches show up here after you press Next Match.'
        $tb.FontSize = 12; $tb.Foreground = $Brush.Dim; $tb.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        [void]$ui.HistoryList.Children.Add($tb)
    }
    foreach ($m in $recent) {
        # Line 1: when + total XP. Line 2: each role played, with its bonus result.
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Margin = New-Object System.Windows.Thickness 0, 3, 0, 4
        $top = New-Object System.Windows.Controls.Grid
        $when = New-Object System.Windows.Controls.TextBlock
        $when.Text = Format-When $m.Start; $when.FontSize = 12.5; $when.Foreground = $Brush.Muted
        $amount = New-Object System.Windows.Controls.TextBlock
        $amount.Text = '{0:N0} XP' -f [long]$m.Xp; $amount.FontSize = 12.5; $amount.Foreground = $Brush.Muted
        $amount.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        foreach ($c in $when, $amount) { [void]$top.Children.Add($c) }
        $roles = New-Object System.Windows.Controls.TextBlock
        $roles.FontSize = 12.5; $roles.TextWrapping = 'Wrap'
        $first = $true
        foreach ($r in $RoleOrder) {
            if (-not $m.Roles -or $null -eq $m.Roles[$r]) { continue }
            $g = [long]$m.Roles[$r]; $t = Get-Tier $g
            if (-not $first) { $roles.Inlines.Add((New-Object System.Windows.Documents.Run "   ")) }
            $first = $false
            $name = New-Object System.Windows.Documents.Run "$($RoleNames[$r]) $('{0:N0}' -f $g) "
            $name.Foreground = $Brush.Ink
            $badge = New-Object System.Windows.Documents.Run $(if ($t -ge $TierCount) { 'MAX' } else { "T$t" })
            $badge.FontWeight = [System.Windows.FontWeights]::SemiBold
            $badge.Foreground = if ($t -ge $TierCount) { $Brush.Green } elseif ($t -gt 0) { $Brush.Gold } else { $Brush.Dim }
            $roles.Inlines.Add($name); $roles.Inlines.Add($badge)
        }
        [void]$row.Children.Add($top); [void]$row.Children.Add($roles)
        [void]$ui.HistoryList.Children.Add($row)
    }

    Update-StatusLine
}

function Update-StatusLine {
    $started = "Match started $(([datetime]::Parse($State.Start)).ToString('h:mm tt'))"
    $read = if ($State.LastRead) { "last read $(([datetime]::Parse($State.LastRead)).ToString('h:mm:ss tt'))" } else { 'no reads yet' }
    $lines = @("$started  |  $read")
    $rec = Get-RecordStatus
    if ($rec) { $lines += "$rec  (Ctrl+Shift+R to stop)" }
    if ($script:Status) { $lines += $script:Status }
    $ui.TxtStatus.Text = $lines -join "`n"
    $ui.TxtStatus.Foreground = if ($rec) { New-Brush '#E0705A' } else { $Brush.Dim }
}

# ---------------------------------------------------------------- placement, show/hide, opacity
$script:hwnd = [IntPtr]::Zero
$script:Hidden = $false

# Screen pixels per WPF unit (1.0 at 100% scaling).
function Get-Scale { [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11 }

# Moves the window to screen pixel (x, y). Done through WPF so it keeps track of where it is.
function Move-Window([int]$X, [int]$Y) {
    $s = Get-Scale
    $win.Left = $X / $s
    $win.Top  = $Y / $s
}

# The monitor the window is mostly on.
function Get-CurrentScreen { [System.Windows.Forms.Screen]::FromRectangle((Get-OwnRect)) }

# Shrinks the whole window evenly if it's taller than the screen (small laptop screens), else full size.
function Resize-ToScreen($Screen) {
    $s = Get-Scale
    $ui.Frame.LayoutTransform = [System.Windows.Media.Transform]::Identity
    $win.Width = 330
    $win.UpdateLayout()
    $fit = ($Screen.WorkingArea.Height / $s) / [Math]::Max(1, $win.ActualHeight)
    if ($fit -lt 1) {
        $ui.Frame.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $fit, $fit
        $win.Width = 330 * $fit
        $win.UpdateLayout()
    }
}

# Places the window at a corner (or the center) of a monitor and remembers it.
$Spots = 'TopRight', 'BottomRight', 'BottomLeft', 'TopLeft'
function Move-ToSpot([string]$Spot, $Screen) {
    if (-not $Screen) { $Screen = Get-CurrentScreen }
    Resize-ToScreen $Screen
    $wa = $Screen.WorkingArea
    $s = Get-Scale
    $w = [int]($win.ActualWidth * $s); $h = [int]($win.ActualHeight * $s)
    $x = switch -Wildcard ($Spot) { '*Right' { $wa.Right - $w } '*Left' { $wa.Left } default { $wa.Left + [int](($wa.Width - $w) / 2) } }
    $y = switch -Wildcard ($Spot) { 'Top*' { $wa.Top } 'Bottom*' { $wa.Bottom - $h } default { $wa.Top + [int](($wa.Height - $h) / 2) } }
    Move-Window $x $y
    $script:Spot = $Spot
    $Settings.WindowPos = "$x,$y"; Save-Settings
}

# Ctrl+Shift+M: next corner of the same monitor.
function Move-ToNextCorner {
    $i = [array]::IndexOf($Spots, $script:Spot)
    Move-ToSpot $Spots[($i + 1) % $Spots.Count]
}

function Move-ToNextMonitor {
    $all = @([System.Windows.Forms.Screen]::AllScreens)
    $cur = Get-CurrentScreen
    $i = 0; for ($k = 0; $k -lt $all.Count; $k++) { if ($all[$k].DeviceName -eq $cur.DeviceName) { $i = $k } }
    Move-ToSpot 'TopRight' $all[($i + 1) % $all.Count]
}

function Set-StartPosition {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($Settings.WindowPos) {
        $p = $Settings.WindowPos -split ',' | ForEach-Object { [int]$_ }
        # Reuse the saved spot only if it's still on a connected monitor.
        $screen = $screens | Where-Object { $_.WorkingArea.Contains($p[0] + 20, $p[1] + 20) } | Select-Object -First 1
        if ($screen) {
            Resize-ToScreen $screen
            Move-Window $p[0] $p[1]
            return
        }
    }
    # First run: top-right of a second monitor if there is one, otherwise the main screen.
    $screen = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if (-not $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
    Move-ToSpot 'TopRight' $screen
}

function Set-Visible([bool]$Show) {
    $script:Hidden = -not $Show
    [WdNative]::ShowWindow($script:hwnd, $(if ($Show) { 4 } else { 0 })) | Out-Null   # SW_SHOWNOACTIVATE / SW_HIDE
    if ($Show) { [WdNative]::KeepOnTop($script:hwnd) }
    $miShow.Text = if ($Show) { 'Hide' } else { 'Show' }
}

function Set-ClickThrough([bool]$On) {
    $Settings.ClickThrough = $On; Save-Settings
    [WdNative]::SetClickThrough($script:hwnd, $On)
    $miClick.Checked = $On
    $tray.ShowBalloonTip(1500, 'Wardogs XP Tracker', $(if ($On) { 'Click-through ON (Ctrl+Shift+L to turn off)' } else { 'Click-through OFF' }), 'None')
}

function Set-Opacity([int]$Value) {
    $Settings.Opacity = [Math]::Max(30, [Math]::Min(100, $Value)); Save-Settings
    $win.Opacity = $Settings.Opacity / 100.0
    foreach ($mi in $miOpacity.DropDownItems) { $mi.Checked = ([int]$mi.Tag -eq $Settings.Opacity) }
}

# ---------------------------------------------------------------- reading the game
$script:Busy = $false
$script:Tick = 0
$script:FindNote = ''
$script:ShortReads = 0
$script:LastRoles = ''

function Get-PanelRect {
    if (-not $Settings.PanelRect) { return $null }
    $p = $Settings.PanelRect -split ',' | ForEach-Object { [int]$_ }
    New-Object System.Drawing.Rectangle $p[0], $p[1], $p[2], $p[3]
}

function Get-OwnRect {
    $r = New-Object WdNative+RECT
    [WdNative]::GetWindowRect($script:hwnd, [ref]$r) | Out-Null
    New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
}

# Screenshot an area, briefly hiding our window if it's in the way.
function Get-Capture([System.Drawing.Rectangle]$Rect) {
    $hide = -not $script:Hidden -and $Rect.IntersectsWith((Get-OwnRect))
    try {
        if ($hide) { [WdNative]::ShowWindow($script:hwnd, 0) | Out-Null; Start-Sleep -Milliseconds 120 }
        Get-ScreenBitmap $Rect
    } finally {
        if ($hide) { [WdNative]::ShowWindow($script:hwnd, 4) | Out-Null; [WdNative]::KeepOnTop($script:hwnd) }
    }
}

function Read-Area([System.Drawing.Rectangle]$Rect) {
    $bmp = Get-Capture $Rect
    try { Get-RoleProgress @(Read-OcrWords $bmp) } finally { $bmp.Dispose() }
}

function Use-Read($Progress) {
    # While recording samples, note every Wardog Level read so popups can be matched to roles later.
    if ($script:Rec) { Write-RecLog ('read: ' + (($Progress.Keys | ForEach-Object { "$_=$($Progress[$_].Xp)(Lv$($Progress[$_].Level))" }) -join ' ')) }
    $res = Add-Read $Progress
    if ($res.Note -and $res.Note -ne $script:LastNote) { Write-Log "read: $($res.Note)" }
    $script:LastNote = $res.Note
    if (-not $res.Accepted) { return }
    foreach ($n in $res.NewTiers) { Show-TierAlert $n.Role $n.Tier }
    $script:Status = ''
    Update-UI
}

function Show-TierAlert([string]$Role, [int]$Tier) {
    $xp = (Get-RoleGains)[$Role]
    $name = $RoleNames[$Role]
    Write-Log "$Role tier $Tier at $xp XP"
    if ($Demo) {
        # Demo stays quiet: no sounds or notifications, just the frame pulse below.
    } elseif ($Tier -ge $TierCount) {
        [System.Media.SystemSounds]::Exclamation.Play()
        $tray.ShowBalloonTip(6000, "$($name.ToUpper()) MAX BONUS", "$('{0:N0}' -f $xp) $name XP this match. You've hit the $('{0:N0}' -f $MatchCap) cap.", 'Info')
    } else {
        [System.Media.SystemSounds]::Asterisk.Play()
        $tray.ShowBalloonTip(4000, "$name bonus tier $Tier of $TierCount", "$('{0:N0}' -f $xp) / $('{0:N0}' -f $MatchCap) $name XP this match", 'None')
    }
    # Pulse the frame so it's noticeable at a glance.
    $anim = New-Object System.Windows.Media.Animation.ColorAnimation
    $anim.From = [System.Windows.Media.ColorConverter]::ConvertFromString($(if ($Tier -ge $TierCount) { $Green } else { $Gold }))
    $anim.To = [System.Windows.Media.ColorConverter]::ConvertFromString('#4A3F28')
    $anim.Duration = [TimeSpan]::FromSeconds(2.5)
    $frameBrush = New-Brush '#4A3F28'
    $ui.Frame.BorderBrush = $frameBrush
    $ui.Frame.BorderThickness = New-Object System.Windows.Thickness 2
    $frameBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
}

# Where to search for the panel: the game window if we can find it, otherwise every monitor.
function Get-SearchAreas {
    if (Get-GameProcess) { return , @(Get-GameRect) }
    , @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds })
}

# Searches for the Wardog Level panel and remembers where it is.
# Returns a short reason when it can't find it, for the status line.
# Saves the screen box to read from now on, from the last Get-RoleProgress on an image taken at $Origin.
# With all 6 roles, a small margin is enough. With some missing, the box is widened by a whole column
# and row on every side, so the missing ones are inside it whichever side they're on.
function Set-PanelRect([System.Drawing.Rectangle]$Origin, [int]$Roles) {
    $b = $script:PanelBounds
    if ($Roles -ge 6) { $padX = 60; $padY = 60 }
    else { $padX = [int]($script:PanelGrid.Col + 40); $padY = [int]($script:PanelGrid.Row + 40) }
    $Settings.PanelRect = '{0},{1},{2},{3}' -f [int]($Origin.X + $b.X - $padX), [int]($Origin.Y + $b.Y - $padY), [int]($b.Width + 2 * $padX), [int]($b.Height + 2 * $padY)
    $Settings.PanelRoles = $Roles
    Save-Settings
}

$script:LastScanSaved = [datetime]::MinValue
# -Upgrade: a quiet re-search that only replaces the saved spot if it now sees more roles.
function Find-Panel([switch]$Manual, [switch]$Upgrade) {
    $blank = 0; $best = 0; $areas = Get-SearchAreas
    foreach ($area in $areas) {
        $bmp = Get-Capture $area
        try {
            if (Test-BlankBitmap $bmp) { $blank++; $words = @() } else { $words = @(Read-OcrWords $bmp) }
            $progress = Get-RoleProgress $words
            $best = [Math]::Max($best, $progress.Count)
            if ($Upgrade -and $progress.Count -le [int]$Settings.PanelRoles) { continue }
            # Two roles are enough to lock on: the box is widened to the whole grid until all 6 show.
            if ($progress.Count -ge 2 -and $script:PanelBounds) {
                Set-PanelRect $area $progress.Count
                Save-Settings
                Write-Log "panel found at $($Settings.PanelRect) with roles: $($progress.Keys -join ', ')$(if ($Upgrade) { ' (better lock)' })"
                $script:FindNote = ''
                Use-Read $progress
                if ($Manual) { $tray.ShowBalloonTip(2500, 'Wardogs XP Tracker', "Found the Wardog Level screen ($($progress.Count) of 6 roles). It will be read automatically from now on.", 'None') }
                return
            }
            if ($Upgrade) { continue }
            # Keep a copy of what we saw (at most every 30 s) so a failed search can be checked.
            if ($Manual -or ((Get-Date) - $script:LastScanSaved).TotalSeconds -gt 30) {
                $bmp.Save((Join-Path $DataDir 'last-scan.png'), [System.Drawing.Imaging.ImageFormat]::Png)
                $script:LastScanSaved = Get-Date
                Write-Log "scan of $area found $($words.Count) words, roles: $($progress.Keys -join ', ') $(if ($words.Count) { '| first words: ' + (($words | Select-Object -First 12 | ForEach-Object Text) -join ' ') })"
            }
        } finally { $bmp.Dispose() }
    }
    $script:FindNote =
        if ($blank -eq $areas.Count) { 'The screen capture came out black. Switch Wardogs to Borderless (not exclusive fullscreen) and turn off HDR if it is on.' }
        elseif ($best -gt 0)         { "Found only $best of 6 roles on the Wardog Level screen. Make sure the whole panel is visible." }
        else                         { 'Open the Wardog Level screen in game. If it is already open, press Ctrl+Shift+U.' }
    if ($Manual) { Set-Status "Couldn't find the Wardog Level screen. $script:FindNote" }
}

# Ctrl+Shift+U / tray: search now and say what happened.
function Invoke-ManualFind {
    if ($script:Busy) { return }
    $script:Busy = $true
    try { Find-Panel -Manual }
    catch {
        Write-Log "find ERROR $_"
        Set-Status "Problem reading the screen: $($_.Exception.Message)"
    } finally { $script:Busy = $false }
}

# Runs every 2 seconds.
function Invoke-Poll {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $script:Tick++
        if ($Demo) { Invoke-DemoStep; return }
        $game = Get-GameProcess
        $rect = Get-PanelRect
        if (-not $rect) {
            # Don't know where the panel is yet: search the game window every ~6 s, or all monitors
            # every ~10 s when the game window can't be identified.
            $where = if ($game) { 'Looking for the Wardog Level screen in the game window.' } else { "Game window not detected, searching all monitors." }
            $msg = "$where $($script:FindNote)".Trim()
            if ($script:Status -ne $msg) { Set-Status $msg }
            if ($script:Tick % $(if ($game) { 3 } else { 5 }) -eq 0) { Find-Panel }
            return
        }
        # Known panel spot: read it every 2 s while the game is detected, every 6 s otherwise.
        if (-not $game -and $script:Tick % 3 -ne 0) { return }
        $progress = Read-Area $rect
        if ($progress.Count -eq 0) { return }   # panel not open right now
        $roles = ($progress.Keys | Sort-Object) -join ','
        if ($roles -ne $script:LastRoles) { Write-Log "reading roles: $roles"; $script:LastRoles = $roles }
        if ($progress.Count -ge $MinRoles) { Use-Read $progress }
        # A widened box that now shows all 6 roles: tighten it so later reads are quicker.
        if ($progress.Count -eq 6 -and [int]$Settings.PanelRoles -lt 6) {
            Set-PanelRect $rect 6
            Write-Log "panel box tightened to $($Settings.PanelRect) (all 6 roles)"
        }
        # The panel is open but some roles are missing: every ~20 s, re-search for a better lock.
        if ($progress.Count -lt 6 -and $game) {
            $script:ShortReads++
            if ($script:ShortReads % 10 -eq 0) { Find-Panel -Upgrade }
        }
    } catch {
        Write-Log "poll ERROR $_"
        $msg = "Problem reading the screen: $($_.Exception.Message)"
        if ($script:Status -ne $msg) { Set-Status $msg }
    } finally { $script:Busy = $false }
}

# ---------------------------------------------------------------- sample recorder controls
function Update-RecordMenu {
    $miRecToggle.Text = if ($script:Rec) { "Stop recording ($($script:Rec.Label))" } else { "Start recording ($($Settings.RecordLabel))" }
    foreach ($mi in $miRecClasses) { $mi.Checked = ([string]$mi.Tag -eq $Settings.RecordLabel) }
    Update-StatusLine
}

function Start-RecordingAs([string]$Label) {
    $Settings.RecordLabel = $Label; Save-Settings
    Start-Recording $Label
    $tray.ShowBalloonTip(3000, "Recording samples: $Label", 'Saving the top-right corner while you play. Ctrl+Shift+R stops it.', 'None')
    Update-RecordMenu
}

# Ctrl+Shift+R: stop if recording, otherwise start with the last class picked.
function Switch-Recording {
    if ($script:Rec) {
        $n = $script:Rec.Frames; $label = $script:Rec.Label
        Stop-Recording
        $tray.ShowBalloonTip(3000, 'Recording stopped', "$label`: $n frames saved.", 'None')
        Update-RecordMenu
    } else { Start-RecordingAs $Settings.RecordLabel }
}

# Ctrl+Shift+S
function Save-ManualScreenshot {
    try {
        $path = Save-FullScreenshot -Manual
        $tray.ShowBalloonTip(2000, 'Screenshot saved', (Split-Path $path -Leaf), 'None')
    } catch {
        Write-Log "screenshot ERROR $_"
        Set-Status "Couldn't save the screenshot: $($_.Exception.Message)"
    }
}

function Start-Next {
    Start-NextMatch
    Write-Log 'next match'
    $ui.Frame.BorderThickness = New-Object System.Windows.Thickness 1
    $ui.Frame.BorderBrush = New-Brush '#4A3F28'
    $script:Status = ''
    Update-UI
}

# ---------------------------------------------------------------- demo mode (made-up reads)
$script:DemoXp = [ordered]@{ infantry = 130627; medic = 269872; support = 118408; recon = 43655; driver = 45030; pilot = 37159 }
$script:DemoLv = [ordered]@{ infantry = 21; medic = 28; support = 20; recon = 13; driver = 14; pilot = 12 }
$script:DemoNext = [ordered]@{ infantry = 145400; medic = 288450; support = 127200; recon = 43750; driver = 54750; pilot = 37500 }
$script:DemoGains = @(@{}, @{ medic = 325 }, @{ medic = 410 }, @{ medic = 380 }, @{ medic = 520 },
    @{ medic = 450 }, @{ medic = 540 }, @{ infantry = 300 }, @{ infantry = 420 }, @{ infantry = 260 })
function Invoke-DemoStep {
    $i = $script:Tick - 1
    # After the scripted gains: file the match into history, then take one read to start the next.
    if ($i -eq $script:DemoGains.Count) { Start-Next; return }
    if ($i -gt $script:DemoGains.Count + 1) { return }
    if ($i -gt $script:DemoGains.Count) { $i = 0 }
    foreach ($kv in $script:DemoGains[$i].GetEnumerator()) {
        $r = $kv.Key
        $script:DemoXp[$r] += $kv.Value
        if ($script:DemoXp[$r] -ge $script:DemoNext[$r]) { $script:DemoLv[$r]++; $script:DemoNext[$r] += 12000 }
    }
    $p = [ordered]@{}
    foreach ($r in $RoleOrder) { $p[$r] = [pscustomobject]@{ Level = $script:DemoLv[$r]; Xp = $script:DemoXp[$r]; NextXp = $script:DemoNext[$r] } }
    Use-Read $p
}

# ---------------------------------------------------------------- tray icon
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 16, 10))), 0, 0, 32, 32)
    $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(216, 180, 90)), 2), 1, 1, 29, 29)
    $font = New-Object System.Drawing.Font 'Bahnschrift', 15, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('XP', $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(216, 180, 90))), (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $fmt)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "Wardogs XP Tracker v$AppVersion$(if ($Demo) { ' (demo)' })"
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow    = $menu.Items.Add('Hide');                $miShow.ShortcutKeyDisplayString  = 'Ctrl+Shift+O'
$miNext    = $menu.Items.Add('Next match');          $miNext.ShortcutKeyDisplayString  = 'Ctrl+Shift+N'
$miFind    = $menu.Items.Add('Find Wardog Level screen'); $miFind.ShortcutKeyDisplayString = 'Ctrl+Shift+U'
$miClick   = $menu.Items.Add('Click-through');       $miClick.ShortcutKeyDisplayString = 'Ctrl+Shift+L'
$miOpacity = New-Object System.Windows.Forms.ToolStripMenuItem 'Opacity'
foreach ($v in 100, 95, 90, 80, 70, 60, 50) {
    $mi = $miOpacity.DropDownItems.Add("$v%"); $mi.Tag = $v
    $mi.add_Click({ param($s) Set-Opacity ([int]$s.Tag) })
}
$menu.Items.Add($miOpacity) | Out-Null
$miMove    = New-Object System.Windows.Forms.ToolStripMenuItem 'Move window'
foreach ($spot in @(@('Top right', 'TopRight'), @('Top left', 'TopLeft'), @('Bottom right', 'BottomRight'), @('Bottom left', 'BottomLeft'), @('Center', 'Center'))) {
    $mi = $miMove.DropDownItems.Add($spot[0]); $mi.Tag = $spot[1]
    $mi.add_Click({ param($s) Move-ToSpot ([string]$s.Tag) })
}
$miMove.DropDownItems.Add('-') | Out-Null
$miNextScreen = $miMove.DropDownItems.Add('Next monitor')
$miNextScreen.add_Click({ Move-ToNextMonitor })
$miCycle = $miMove.DropDownItems.Add('Next corner'); $miCycle.ShortcutKeyDisplayString = 'Ctrl+Shift+M'
$miCycle.add_Click({ Move-ToNextCorner })
# Only offer "Next monitor" when there is more than one.
$miMove.add_DropDownOpening({ $miNextScreen.Visible = @([System.Windows.Forms.Screen]::AllScreens).Count -gt 1 })
$menu.Items.Add($miMove) | Out-Null
# Sample recorder: pick the class you're about to play, then record; one session per class.
$miRecord  = New-Object System.Windows.Forms.ToolStripMenuItem 'Record samples'
$miRecToggle = $miRecord.DropDownItems.Add('Start recording'); $miRecToggle.ShortcutKeyDisplayString = 'Ctrl+Shift+R'
$miRecToggle.add_Click({ Switch-Recording })
$miRecord.DropDownItems.Add('-') | Out-Null
$miRecClasses = foreach ($label in @($RoleOrder | ForEach-Object { $RoleNames[$_] }) + 'Unlabeled') {
    $mi = $miRecord.DropDownItems.Add("Record as $label"); $mi.Tag = $label
    $mi.add_Click({ param($s) Start-RecordingAs ([string]$s.Tag) })
    $mi
}
$miRecord.DropDownItems.Add('-') | Out-Null
$miShot = $miRecord.DropDownItems.Add('Save full screenshot'); $miShot.ShortcutKeyDisplayString = 'Ctrl+Shift+S'
$miShot.add_Click({ Save-ManualScreenshot })
$miSamples = $miRecord.DropDownItems.Add('Open samples folder')
$miSamples.add_Click({ New-Item -ItemType Directory -Force -Path (Get-SamplesDir) | Out-Null; Start-Process explorer.exe (Get-SamplesDir) })
$menu.Items.Add($miRecord) | Out-Null
$miFolder  = $menu.Items.Add('Open data folder')
$menu.Items.Add('-') | Out-Null
$miQuit    = $menu.Items.Add('Quit')

$miShow.add_Click({ Set-Visible $script:Hidden })
$miNext.add_Click({ Start-Next })
$miFind.add_Click({ Invoke-ManualFind })
$miClick.add_Click({ Set-ClickThrough (-not $Settings.ClickThrough) })
$miFolder.add_Click({ Start-Process explorer.exe $DataDir })
$miQuit.add_Click({ $app.Shutdown() })
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Set-Visible $script:Hidden } })
$tray.ContextMenuStrip = $menu

# ---------------------------------------------------------------- wiring
$ui.BtnNext.add_Click({ Start-Next })
$ui.BtnHide.add_Click({ Set-Visible $false })
# Drag from any empty spot to move it (buttons still click normally).
$win.add_MouseLeftButtonDown({
    try { $win.DragMove() } catch { return }   # throws if the button was already released
    $r = Get-OwnRect
    $Settings.WindowPos = "$($r.X),$($r.Y)"; Save-Settings
    Resize-ToScreen (Get-CurrentScreen)
})

$win.add_SourceInitialized({
    $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    if ($Settings.ClickThrough) { [WdNative]::SetClickThrough($script:hwnd, $true) }
})
$script:Placed = $false
$win.add_ContentRendered({
    if ($script:Placed) { return }
    $script:Placed = $true
    try {
        Set-StartPosition
    } catch {
        # Never leave the window stranded off-screen: fall back to the middle of the main screen.
        Write-Log "placement ERROR $_"
        try { Move-ToSpot 'Center' ([System.Windows.Forms.Screen]::PrimaryScreen) } catch { $win.Left = 100; $win.Top = 100 }
    }
    $where = if (@([System.Windows.Forms.Screen]::AllScreens).Count -gt 1) { 'on your screen' } else { 'in the corner of your screen' }
    if (-not $Demo) { $tray.ShowBalloonTip(5000, 'Wardogs XP Tracker is running', "It's $where. Drag it anywhere, or press Ctrl+Shift+M to jump between corners.", 'None') }
})

$MOD = 0x2 -bor 0x4   # Ctrl + Shift
$hotkeys = New-Object WdHotkeys
$failed = @()
$keys = @{ 1 = 0x4E; 2 = 0x55; 3 = 0x4F; 4 = 0x4C; 5 = 0x21; 6 = 0x22; 7 = 0x4D; 8 = 0x52; 9 = 0x53 }   # N U O L PageUp PageDown M R S
$keyNames = @{ 1 = 'N'; 2 = 'U'; 3 = 'O'; 4 = 'L'; 5 = 'PageUp'; 6 = 'PageDown'; 7 = 'M'; 8 = 'R'; 9 = 'S' }
foreach ($id in 1..9) { if (-not $hotkeys.Add($id, $MOD, $keys[$id])) { $failed += "Ctrl+Shift+$($keyNames[$id])" } }
$hotkeys.add_Pressed({
    param($id)
    switch ($id) {
        1 { Start-Next }
        2 { Invoke-ManualFind }
        3 { Set-Visible $script:Hidden }
        4 { Set-ClickThrough (-not $Settings.ClickThrough) }
        5 { Set-Opacity ($Settings.Opacity + 10) }
        6 { Set-Opacity ($Settings.Opacity - 10) }
        7 { if ($script:Hidden) { Set-Visible $true }; Move-ToNextCorner }
        8 { Switch-Recording }
        9 { Save-ManualScreenshot }
    }
})
if ($failed) { $script:Status = "Hotkeys already used by another app: $($failed -join ', ')"; Write-Log $script:Status }

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromSeconds(2)
$pollTimer.add_Tick({ Invoke-Poll })

$topTimer = New-Object System.Windows.Threading.DispatcherTimer
$topTimer.Interval = [TimeSpan]::FromSeconds(2)
$topTimer.add_Tick({ if (-not $script:Hidden) { [WdNative]::KeepOnTop($script:hwnd) } })

$recTimer = New-Object System.Windows.Threading.DispatcherTimer
$recTimer.Interval = [TimeSpan]::FromMilliseconds(1000 / $RecordFps)
$recTimer.add_Tick({
    if (-not $script:Rec) { return }
    try {
        $stopped = Invoke-RecordTick
        if ($stopped) { $tray.ShowBalloonTip(5000, 'Wardogs XP Tracker', $stopped, 'Warning'); Update-RecordMenu }
    } catch { Write-Log "record ERROR $_" }
    Update-StatusLine   # keeps the REC timer and frame count current
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.add_Exit({
    Stop-Recording 'tracker closed'
    $recTimer.Stop()
    $pollTimer.Stop(); $topTimer.Stop()
    $hotkeys.Dispose()
    $tray.Visible = $false; $tray.Dispose()
})

$tray.Visible = $true
$miClick.Checked = $Settings.ClickThrough
Set-Opacity $Settings.Opacity
Update-UI
$pollTimer.Start(); $topTimer.Start(); $recTimer.Start()
Update-RecordMenu
Write-Log "ready (demo=$Demo)"
# Start off-screen; ContentRendered moves it into place once its size is known (avoids a flash on the main monitor).
$win.Left = -32000; $win.Top = -32000
$win.Show()
[void]$app.Run()
$mutex.ReleaseMutex()
