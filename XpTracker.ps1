#Requires -Version 5.1
<#
  Wardogs XP Tracker
  A small always-on-top window that tracks the XP each class earns per match toward its
  2,500 XP end-of-match bonus cap. It reads the XP/cash popups live and the in-game
  "Wardog Level" screen with Windows' built-in OCR (screenshots only, never the game's
  memory), keeps a breakdown of every popup per match, and deduces the end-of-match bonus.

  Hotkeys:
    Ctrl+Shift+N          End match (the next Wardog Level read files it, with the deduced bonus)
    Ctrl+Shift+C          Live popup tracking on/off
    Ctrl+Shift+U          Find the Wardog Level panel now (open it in game first)
    Ctrl+Shift+O          Show / hide
    Ctrl+Shift+L          Click-through on/off
    Ctrl+Shift+PageUp     More opaque
    Ctrl+Shift+PageDown   More transparent
    Ctrl+Shift+M          Move to the next corner of the screen (or drag it anywhere)

  -Demo plays back made-up reads (no game needed) using a throwaway data folder.
#>
param([switch]$Demo)

# Matches the GitHub release tag (v1.0, v1.1, ...) and CHANGELOG.md.
$AppVersion = '2.5'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# The launcher runs this hidden, so surface startup errors in a dialog.
trap {
    if ($LogFile) { Add-Content -Path $LogFile -Value "$(Get-Date -Format s) ERROR $_`n$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)" -Encoding utf8 }
    if (-not $env:WD_NO_DIALOG) { [System.Windows.Forms.MessageBox]::Show("Wardogs XP Tracker failed:`n`n$_", 'Wardogs XP Tracker') | Out-Null }
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
# Logging must never stop the tracker (e.g. if the log is open in another program).
function Write-Log([string]$Text) { try { Add-Content -Path $LogFile -Value "$(Get-Date -Format s) $Text" -Encoding utf8 -ErrorAction Stop } catch {} }

$SettingsFile = Join-Path $DataDir 'settings.json'
$Settings = [ordered]@{
    Opacity      = 100
    ClickThrough = $false
    PanelRect    = $null   # "x,y,w,h": where the in-game Wardog Level panel was last found
    PanelRoles   = 0       # how many roles were readable when it was found
    Continuous   = $true   # live popup tracking on
    PopupPollMs  = 300     # how often the popup area is checked (about 3 times a second)
    PopupRect    = $null   # "x,y,w,h": where XP/cash popups appear; default is under the top-right cash boxes
    WindowPos    = $null   # "x,y": where you last dragged the window
    StartMenuShortcut = $true    # "Wardogs XP Tracker" in the Start menu
    DesktopShortcut   = $false
    StartWithWindows  = $false
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
. (Join-Path $PSScriptRoot 'PopupReader.ps1')
Initialize-SymbolBank
Initialize-Tracker $DataDir

# ---------------------------------------------------------------- window
$Gold = '#D8B45A'; $Green = '#5BD06E'; $Ink = '#EADFC4'; $Muted = '#9A8F78'; $Dim = '#6F6654'

$tickBorders = (1..$TierCount | ForEach-Object { if ($_ -lt $TierCount) { '<Border BorderBrush="#0B0907" BorderThickness="0,0,2,0"/>' } else { '<Border/>' } }) -join ''

# Class symbols, drawn on a 24x24 grid in the spirit of the game's own (our drawings, not game art):
# Assault arrowhead, Medic cross, Support wrench, Recon crosshair, Driver steering wheel, Pilot wings.
# "C" is replaced with the color; Update-UI recolors them afterwards.
$RoleIcons = @{
    infantry = '<Path Data="M12,1.5 L22.5,22 L12,15 L1.5,22 Z" Fill="C"/>'
    medic    = '<Path Data="M8.5,2 H15.5 V8.5 H22 V15.5 H15.5 V22 H8.5 V15.5 H2 V8.5 H8.5 Z" Fill="C"/>'
    support  = '<Line X1="4.5" Y1="19.5" X2="12.5" Y2="11.5" Stroke="C" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>' +
               '<Path Data="M18.5,3.7 A5,5 0 1 0 20.7,9.7" Stroke="C" StrokeThickness="4.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>'
    recon    = '<Ellipse Canvas.Left="3.5" Canvas.Top="3.5" Width="17" Height="17" Stroke="C" StrokeThickness="2.4"/>' +
               '<Line X1="12" Y1="1" X2="12" Y2="4.5" Stroke="C" StrokeThickness="2.6"/><Line X1="12" Y1="19.5" X2="12" Y2="23" Stroke="C" StrokeThickness="2.6"/>' +
               '<Line X1="1" Y1="12" X2="4.5" Y2="12" Stroke="C" StrokeThickness="2.6"/><Line X1="19.5" Y1="12" X2="23" Y2="12" Stroke="C" StrokeThickness="2.6"/>'
    driver   = '<Ellipse Canvas.Left="2" Canvas.Top="2" Width="20" Height="20" Stroke="C" StrokeThickness="3"/>' +
               '<Ellipse Canvas.Left="9" Canvas.Top="10" Width="6" Height="6" Fill="C"/>' +
               '<Line X1="3.5" Y1="11" X2="20.5" Y2="11" Stroke="C" StrokeThickness="3"/>' +
               '<Line X1="12" Y1="14" X2="12" Y2="21" Stroke="C" StrokeThickness="3"/>'
    pilot    = '<Path Data="M3,21 C5,13 12,6 22,2.5 C21,6 18.5,8.5 15.5,9.8 C18,9.8 19.5,9.5 20.5,9.2 C19,12.5 16,14.5 12.5,15 C14,15.4 15.2,15.5 16.2,15.4 C13,19 8,20.6 3,21 Z" Fill="C"/>'
}
function Get-RoleIconXaml([string]$Role, [double]$Size, [string]$Name = '', [string]$Margin = '0') {
    $n = if ($Name) { ' x:Name="{0}"' -f $Name } else { '' }
    $shapes = $RoleIcons[$Role].Replace('"C"', ('"{0}"' -f $Ink))
    '<Viewbox{0} Width="{1}" Height="{1}" Margin="{2}" VerticalAlignment="Center"><Canvas Width="24" Height="24">{3}</Canvas></Viewbox>' -f $n, $Size, $Margin, $shapes
}

# One row per role: name, level, XP this match, bonus tier, and a bar toward the 2,500 cap.
$roleRows = foreach ($r in $RoleOrder) {
@"
        <Grid Margin="0,5,0,5">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              $(Get-RoleIconXaml $r 14 "${r}_Icon" '0,0,7,0')
              <TextBlock x:Name="${r}_Name" Text="$($RoleNames[$r])" FontSize="14" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="${r}_To" Text=" " FontSize="11" Foreground="$Dim" Margin="21,0,0,0"/>
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

# Match bonus overview: each role's symbol with a mini bar toward its 2,500 XP cap.
$bonusChips = foreach ($r in $RoleOrder) {
@"
        <StackPanel Margin="4,0,4,0" ToolTip="$($RoleNames[$r])">
          $(Get-RoleIconXaml $r 18 "${r}_Chip" '0,0,0,6')
          <Grid Height="4">
            <Border Background="#2B2519" CornerRadius="2"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition x:Name="${r}_ChipF" Width="0*"/><ColumnDefinition x:Name="${r}_ChipR" Width="1*"/></Grid.ColumnDefinitions>
              <Border x:Name="${r}_ChipFill" Background="$Gold" CornerRadius="2"/>
            </Grid>
          </Grid>
        </StackPanel>
"@
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
          <TextBlock Text="//WARDOG LEVEL" FontSize="11" FontWeight="SemiBold" Foreground="$Gold"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="TxtWardogLv" Text="-" FontSize="40" FontWeight="Bold" LineHeight="42" LineStackingStrategy="BlockLineHeight"/>
            <TextBlock x:Name="TxtLvGain" Text=" " FontSize="12.5" FontWeight="SemiBold" Foreground="$Green" VerticalAlignment="Bottom" Margin="9,0,0,6"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Button x:Name="BtnDetails" Style="{StaticResource Flat}" Content="DETAILS" Margin="0,0,4,0" ToolTip="Every XP and cash popup this match, grouped by reason"/>
          <Button x:Name="BtnNext" Style="{StaticResource Flat}" Content="END MATCH" ToolTip="The match is over: the next Wardog Level read files it with the deduced bonus (Ctrl+Shift+N)"/>
          <Button x:Name="BtnHide" Style="{StaticResource Flat}" Content="&#x2013;" Margin="4,0,0,0" ToolTip="Hide (Ctrl+Shift+O)"/>
        </StackPanel>
      </Grid>

      <!-- match bonus: how many roles have maxed their bonus this match -->
      <Border Height="1" Background="#2E271A" Margin="14,10,14,8"/>
      <TextBlock Text="MATCH BONUS" FontSize="11" FontWeight="SemiBold" Foreground="$Gold" Margin="14,0,14,2"/>
      <Grid Margin="14,0,14,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
          <TextBlock x:Name="TxtMaxed" Text="0" FontSize="44" FontWeight="Bold" LineHeight="44" LineStackingStrategy="BlockLineHeight"/>
          <TextBlock Text="/ $($RoleOrder.Count) roles maxed" FontSize="17" Foreground="$Muted" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
        </StackPanel>
        <Border x:Name="Badge" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,8" Visibility="Collapsed"
                BorderBrush="$Green" BorderThickness="1" CornerRadius="3" Padding="7,2">
          <TextBlock Text="ALL MAXED" FontSize="12" FontWeight="SemiBold" Foreground="$Green"/>
        </Border>
      </Grid>
      <!-- one symbol per role with a mini bar toward its cap -->
      <UniformGrid Columns="$($RoleOrder.Count)" Margin="10,10,10,0">
$($bonusChips -join "`n")
      </UniformGrid>
      <TextBlock x:Name="TxtNote" Text=" " FontSize="12.5" Foreground="$Muted" Margin="14,10,14,0" TextWrapping="Wrap"/>
      <Grid Margin="14,6,14,0">
        <TextBlock Text="Cash this match" FontSize="12.5" Foreground="$Muted"/>
        <TextBlock x:Name="TxtCash" Text="`$0" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>

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

# Recolors every shape inside a class symbol.
function Set-IconColor($Icon, $Brush) {
    if (-not $Icon) { return }
    foreach ($shape in $Icon.Child.Children) {
        if ($shape.Fill) { $shape.Fill = $Brush }
        if ($shape.Stroke) { $shape.Stroke = $Brush }
    }
}

function Update-UI {
    $gains  = Get-RoleGains
    $active = Get-ActiveRole

    # Wardog level: all six role levels added up, plus levels gained this match.
    $wl = Get-WardogLevel
    $ui.TxtWardogLv.Text = if ($null -ne $wl) { "$wl" } else { '-' }
    $gained = Get-LevelsGained
    $ui.TxtLvGain.Text = if ($gained -gt 0) { "+$gained this match" } else { ' ' }

    # Match bonus: how many roles have maxed theirs, and a symbol + mini bar per role.
    $maxed = @($RoleOrder | Where-Object { $gains[$_] -ge $MatchCap }).Count
    $all = $maxed -eq $RoleOrder.Count
    $ui.TxtMaxed.Text = "$maxed"
    $ui.TxtMaxed.Foreground = if ($maxed -gt 0) { $Brush.Green } else { $Brush.Ink }
    $ui.Badge.Visibility = if ($all) { 'Visible' } else { 'Collapsed' }
    foreach ($r in $RoleOrder) {
        $g = $gains[$r]; $rmax = $g -ge $MatchCap
        Set-Bar $ui["${r}_ChipF"] $ui["${r}_ChipR"] $g
        $ui["${r}_ChipFill"].Background = if ($rmax) { $Brush.Green } else { $Brush.Gold }
        Set-IconColor $ui["${r}_Chip"] $(if ($rmax) { $Brush.Green } elseif ($r -eq $active) { $Brush.Gold } elseif ($g -gt 0) { $Brush.Muted } else { $Brush.Dim })
    }

    # One line about the role you're playing (or what to do to finish the match).
    $live = $Settings.Continuous -and -not $Demo
    $ui.TxtNote.Text =
        if ($State.EndRequested) { 'Match over. Open the Wardog Level screen to read your final XP; the bonus is worked out from it. (END MATCH again files it without the bonus.)' }
        elseif (-not $State.Base -and -not $live -and -not @($State.Events).Count) { 'Open the Wardog Level screen in game to save your starting XP.' }
        elseif ($all)         { 'Every role has maxed its bonus this match.' }
        elseif (-not $active) { 'Each role has its own 2,500 XP bonus. Earn XP in a role to start its bar.' }
        else {
            $xp = $gains[$active]; $tier = Get-Tier $xp; $name = $RoleNames[$active]
            if ($xp -ge $MatchCap) { "Playing $name`: maxed. Switch to another role to earn another bonus." }
            else { "Playing $name`: $('{0:N0}' -f $xp) / $('{0:N0}' -f $MatchCap) XP, $('{0:N0}' -f ($TierSize * ($tier + 1) - $xp)) to tier $($tier + 1)." }
        }
    $ui.TxtNote.Foreground = if ($State.EndRequested) { $Brush.Gold } else { $Brush.Muted }
    $ui.BtnNext.Content = if ($State.EndRequested) { 'FILE NOW' } else { 'END MATCH' }

    # Cash from popups (the game resets its own counter every life).
    $cash = Get-MatchCash
    $ui.TxtCash.Text = (Format-Cash $cash) + $(if ($null -eq $State.BankNow -and [int]$State.CashUncertain -gt 0) { "  ($($State.CashUncertain) uncertain)" } else { '' })
    $ui.TxtCash.Foreground = if ($cash -gt 0) { $Brush.Green } elseif ($cash -lt 0) { New-Brush '#E0705A' } else { $Brush.Dim }

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
        Set-IconColor $ui["${r}_Icon"] $(if ($rmax) { $Brush.Green } elseif ($r -eq $active) { $Brush.Gold } else { $Brush.Muted })
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
        $tb.Text = 'Matches show up here after you press End Match.'
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
        $amount.Text = ('{0:N0} XP' -f [long]$m.Xp) + $(if ($null -ne $m.BonusTotal) { "  incl. +$('{0:N0}' -f [long]$m.BonusTotal) bonus" } else { '' }) + $(if (@($m.Warnings).Count) { '  !' } else { '' })
        $amount.FontSize = 12.5; $amount.Foreground = $Brush.Muted
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
        # Click a past match to see its breakdown.
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.ToolTip = 'Show this match''s breakdown'
        $row.Tag = $m
        $row.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Show-MatchDetails $s.Tag })
        $row.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })   # don't start a window drag
        [void]$ui.HistoryList.Children.Add($row)
    }

    Update-StatusLine
}

function Update-StatusLine {
    $started = "Match started $(([datetime]::Parse($State.Start)).ToString('h:mm tt'))"
    $read = if ($State.LastRead) { "last read $(([datetime]::Parse($State.LastRead)).ToString('h:mm:ss tt'))" } else { 'no reads yet' }
    $lines = @("$started  |  $read")
    $lines += switch ($script:LiveState) {
        'on'      { "LIVE: reading popups  |  $(@($State.Events).Count) this match" }
        'off'     { 'Live popup tracking is off (Ctrl+Shift+C)' }
        'blocked' { 'LIVE paused: this window covers the popup area. Move it (Ctrl+Shift+M).' }
        default   { 'LIVE paused: waiting for Wardogs' }
    }
    if ($script:Status) { $lines += $script:Status }
    $ui.TxtStatus.Text = $lines -join "`n"
    $ui.TxtStatus.Foreground = $Brush.Dim
}

function Format-Cash([long]$Amount) {
    if ($Amount -lt 0) { '-${0:N0}' -f [Math]::Abs($Amount) } else { '+${0:N0}' -f $Amount }
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
    $res = Add-Read $Progress
    if ($res.Note -and $res.Note -ne $script:LastNote) { Write-Log "read: $($res.Note)" }
    $script:LastNote = $res.Note
    if (-not $res.Accepted) { return }
    foreach ($n in $res.NewTiers) { Show-TierAlert $n.Role $n.Tier }
    $script:Status = ''
    if ($res.Filed) { Show-Filed $res.Filed }
    Update-UI
    if ($res.Filed) { Save-FiledSnapshot $res.Filed }
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
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $script:Tick++
        Save-TrackerIfDue
        Write-PerfLog
        if ($Demo) { Invoke-DemoStep; return }
        $game = Get-GameProcess
        $script:GameNow = [bool]$game   # the popup poll uses this instead of looking up the game itself
        # Time in a match without live tracking makes the deduced bonus less certain.
        if ((Test-MatchActive) -and -not $State.EndRequested -and $script:LiveState -ne 'on') { Add-LiveGap 2 }
        if ($game -and $Settings.Continuous) { $csw = [Diagnostics.Stopwatch]::StartNew(); Invoke-CashCheck; Add-Perf 'cash' $csw }
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
        # Known panel spot: check it every 2 s while the game is detected, every 6 s otherwise, and
        # only run OCR when its white text changed (or every 10 s), so a closed panel costs nothing.
        if (-not $game -and $script:Tick % 3 -ne 0) { return }
        $bmp = Get-Capture $rect
        try {
            $grid = [WdPopup]::WhiteGrid($bmp, 24, 16, $PopupGateWhite, $PopupGateSpread)
            $changed = [WdPopup]::GridDiff($grid, $script:PanelLastGrid) -ge 0.03
            $since = ((Get-Date) - $script:PanelLastOcr).TotalSeconds
            # While the panel is closed the game scene behind it keeps changing, so look again
            # only every 6 s until it shows up.
            $wait = if ($script:PanelOpen) { 0 } else { 6 }
            if ([WdPopup]::Sum($grid) -lt 30 -or $since -lt $wait -or (-not $changed -and $since -lt 10)) { return }
            $script:PanelLastGrid = $grid; $script:PanelLastOcr = Get-Date
            $osw = [Diagnostics.Stopwatch]::StartNew()
            $progress = Get-RoleProgress @(Read-OcrWords $bmp)
            Add-Perf 'panel-ocr' $osw
        } finally { $bmp.Dispose() }
        $script:PanelOpen = $progress.Count -gt 0
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
    } finally { $script:Busy = $false; Add-Perf 'panel-and-results' $sw }
}

# ---------------------------------------------------------------- live popups
# Time spent per kind of work, written to the log once a minute (for keeping CPU use low).
$script:Perf = @{}
$script:PerfSince = Get-Date
function Add-Perf([string]$Name, [System.Diagnostics.Stopwatch]$Sw) {
    $p = $script:Perf[$Name]; if (-not $p) { $p = @{ N = 0; Ms = 0 }; $script:Perf[$Name] = $p }
    $p.N++; $p.Ms += $Sw.Elapsed.TotalMilliseconds
}
function Write-PerfLog {
    $secs = ((Get-Date) - $script:PerfSince).TotalSeconds
    if ($secs -lt 60) { return }
    $parts = foreach ($k in ($script:Perf.Keys | Sort-Object)) { "{0} {1}x {2:N0}ms" -f $k, $script:Perf[$k].N, $script:Perf[$k].Ms }
    $total = ($script:Perf.Values | ForEach-Object { $_.Ms } | Measure-Object -Sum).Sum
    Write-Log ("perf (last {0:N0}s, {1:N1}% of a core): {2}" -f $secs, (100 * $total / 1000 / $secs), ($parts -join '; '))
    $script:Perf = @{}; $script:PerfSince = Get-Date
}

$script:LiveState = 'waiting'   # on | off | blocked | waiting
$script:PanelLastGrid = $null
$script:PanelLastOcr = [datetime]::MinValue
$script:PanelOpen = $false
$script:GameNow = $false
$script:PopLastGrid = $null
$script:PopLastOcr = [datetime]::MinValue
$script:UnparsedSeen = @{}

# (not "$State": functions called from here would see it instead of the match state)
function Set-LiveState([string]$Value) {
    if ($script:LiveState -eq $Value) { return }
    $script:LiveState = $Value
    Update-StatusLine
}

# Runs every PopupPollMs (about 3 times a second): grabs the small popup area, and only runs OCR
# when its white text changed.
function Invoke-PopupPoll {
    if ($Demo) { return }
    if (-not $Settings.Continuous) { Set-LiveState 'off'; return }
    if (-not $script:GameNow) { Set-LiveState 'waiting'; return }
    $rect = Get-PopupRect
    if (-not $script:Hidden -and $rect.IntersectsWith((Get-OwnRect))) { Set-LiveState 'blocked'; return }
    Set-LiveState 'on'
    $now = Get-Date
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $bmp = Get-ScreenBitmap $rect
    $ocr = $false
    try {
        $grid = [WdPopup]::WhiteGrid($bmp, 24, 16, $PopupGateWhite, $PopupGateSpread)
        $diff = [WdPopup]::GridDiff($grid, $script:PopLastGrid)
        $since = ($now - $script:PopLastOcr).TotalSeconds
        if (($diff -lt $PopupGateDiff -and $since -lt $PopupForceOcr) -or $since -lt $PopupMinOcrGap) { Update-PopupTracksSeen $now; return }
        $script:PopLastGrid = $grid
        if ($script:PopTracks.Count -eq 0 -and -not (Test-PopupsShowing $bmp)) { return }   # no popups showing
        $script:PopLastOcr = $now
        $ocr = $true
        $rows = @(Read-PopupArea $bmp)
        $res = Update-PopupTracks $rows $now
        $changed = $false
        foreach ($t in $res.New) {
            $out = Add-PopupEvent $t.Kind $t.Amount $t.Reason $t.Role $t.Uncertain
            $t.EventId = $out.Event.Id
            foreach ($n in $out.NewTiers) { Show-TierAlert $n.Role $n.Tier }
            $changed = $true
        }
        foreach ($t in $res.Changed) {
            if (-not $t.EventId) { continue }
            foreach ($n in (Update-PopupEvent $t.EventId $t.Amount $t.Uncertain)) { Show-TierAlert $n.Role $n.Tier }
            $changed = $true
        }
        foreach ($r in $rows | Where-Object Kind -eq 'unparsed') { Save-UnparsedRead $bmp $r $now }
        if ($changed) { Update-UI }
    } catch {
        Write-Log "popup ERROR $_"
    } finally { $bmp.Dispose(); Add-Perf $(if ($ocr) { 'popup-ocr' } else { 'popup-check' }) $sw }
}

# A popup row with numbers that couldn't be understood: log it once, keep a picture for tuning
# (the last 50), and count it toward the match's confidence warning. Rows that are just a misread
# of a row already being followed don't count.
function Save-UnparsedRead([System.Drawing.Bitmap]$Bitmap, $Row, [datetime]$Now) {
    if ($script:PopTracks | Where-Object { [Math]::Abs($_.Y - $Row.Y) -lt 0.8 * $Row.H }) { return }
    $last = $script:UnparsedSeen[$Row.Text]
    if ($last -and ($Now - $last).TotalSeconds -lt 6) { return }
    $script:UnparsedSeen[$Row.Text] = $Now
    Add-UnparsedRead
    Write-Log "unparsed popup: $($Row.Text)"
    try {
        $dir = Join-Path $DataDir 'unparsed'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $y = [Math]::Max(0, [int]($Row.Y - 0.6 * $Row.H)); $h = [Math]::Min($Bitmap.Height - $y, [int](2.2 * $Row.H))
        $crop = $Bitmap.Clone((New-Object System.Drawing.Rectangle 0, $y, $Bitmap.Width, $h), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $crop.Save((Join-Path $dir ($Now.ToString('yyyyMMdd-HHmmss-fff') + '.png')), [System.Drawing.Imaging.ImageFormat]::Png); $crop.Dispose()
        Get-ChildItem $dir -Filter '*.png' | Sort-Object Name -Descending | Select-Object -Skip 50 | Remove-Item -Force
    } catch {}
}

# Reads this life's cash and banked cash at the top right while playing, so the match's cash includes
# gear bought (which has no popup). OCR sometimes drops the minus sign, so a read only counts when
# the one before it agrees on the banked cash this life started with.
$script:CashLastGrid = $null
$script:CashLastOcr = [datetime]::MinValue
$script:CashPrevLifeStart = $null
function Invoke-CashCheck {
    if ($State.EndRequested) { return }   # after the match: the results payout isn't this match's play
    $bmp = Get-ScreenBitmap (Get-CashRect)
    try {
        $grid = [WdPopup]::WhiteGrid($bmp, 24, 4, $PopupGateWhite, $PopupGateSpread)
        $stale = ((Get-Date) - $script:CashLastOcr).TotalSeconds -ge 10
        if ([WdPopup]::GridDiff($grid, $script:CashLastGrid) -lt 0.05 -and -not $stale) { return }
        $script:CashLastGrid = $grid; $script:CashLastOcr = Get-Date
        $read = Read-CashHud $bmp
        if (-not $read) { return }
        $lifeStart = $read.Banked - $read.Life
        $confirmed = $lifeStart -eq $script:CashPrevLifeStart
        $script:CashPrevLifeStart = $lifeStart
        if ($confirmed -and (Set-BankRead $read.Banked $lifeStart)) { Update-UI }
    } catch {
        Write-Log "cash check ERROR $_"
    } finally { $bmp.Dispose() }
}

# Ctrl+Shift+C / tray
function Switch-Continuous {
    $Settings.Continuous = -not $Settings.Continuous; Save-Settings
    $miLive.Checked = $Settings.Continuous
    Reset-PopupTracks
    if ($Settings.Continuous) { $script:PopLastGrid = $null; Set-LiveState 'waiting' } else { Set-LiveState 'off' }
    $tray.ShowBalloonTip(2000, 'Wardogs XP Tracker', $(if ($Settings.Continuous) { 'Live popup tracking on.' } else { 'Live popup tracking off.' }), 'None')
}

# ---------------------------------------------------------------- end of match
# Ctrl+Shift+N / END MATCH: marks the match over; the next Wardog Level read files it with the bonus.
# Pressing it again files it right away, without the bonus.
function Invoke-EndMatch {
    $filed = $null
    if (-not $State.EndRequested) {
        if (-not (Test-MatchActive)) { Set-Status 'Nothing to file yet: no XP or popups this match.'; return }
        [void](Request-EndMatch)
        Reset-PopupTracks
        Write-Log 'match ended'
        $tray.ShowBalloonTip(5000, 'Match ended', 'Open the Wardog Level screen to read your final XP. The tracker works out the end-of-match bonus from it.', 'None')
    } else {
        $filed = Complete-Match -NoFinalRead
        Show-Filed $filed
    }
    $ui.Frame.BorderThickness = New-Object System.Windows.Thickness 1
    $ui.Frame.BorderBrush = New-Brush '#4A3F28'
    $script:Status = ''
    Update-UI
    if ($filed) { Save-FiledSnapshot $filed }
}

# A picture of the tracker window as it looks now (2x size, for a sharp image).
function Save-WindowSnapshot([string]$Path) {
    try {
        $el = $win.Content
        if (-not $el -or $el.ActualWidth -lt 10) { return $false }
        $wd = $el.ActualWidth; $ht = $el.ActualHeight
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle((New-Brush '#14100A'), $null, (New-Object System.Windows.Rect 0, 0, $wd, $ht))
        $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush $el), $null, (New-Object System.Windows.Rect 0, 0, $wd, $ht))
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($wd * 2)), ([int]($ht * 2)), 192, 192, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        $true
    } catch { Write-Log "snapshot ERROR $_"; $false }
}

# The window right after a match is filed (the match at the top of Recent Matches, with the Wardog
# level), saved next to the match's popups as matches\<start>.png.
function Save-FiledSnapshot($Entry) {
    $win.UpdateLayout()
    $rel = 'matches\{0}.png' -f ([datetime]::Parse($Entry.Start)).ToString('yyyyMMdd-HHmmss')
    if (Save-WindowSnapshot (Join-Path $DataDir $rel)) { $Entry.Snapshot = $rel; Save-TrackerSoon }
}

function Show-Filed($Entry) {
    if (-not $Entry) { return }
    Write-Log ("match filed: {0} XP, bonus {1}, cash {2} (popups {3}), {4} popups, warnings {5}" -f $Entry.Xp, $Entry.BonusTotal, $Entry.NetCash, $Entry.Cash, $Entry.EventCount, @($Entry.Warnings).Count)
    $bonus = if ($null -ne $Entry.BonusTotal) { "End-of-match bonus: +$('{0:N0}' -f [long]$Entry.BonusTotal) XP$(if ($Entry.Placement) { " ($($Entry.Placement))" })." } else { 'No end-of-match bonus deduced.' }
    if (-not $Demo) { $tray.ShowBalloonTip(6000, 'Match filed', "$bonus Click it under Recent Matches for the full breakdown.", 'None') }
}

# ---------------------------------------------------------------- demo mode (made-up match)
$script:DemoXp = [ordered]@{ infantry = 130627; medic = 269872; support = 118408; recon = 43655; driver = 45030; pilot = 37159 }
$script:DemoLv = [ordered]@{ infantry = 21; medic = 28; support = 20; recon = 13; driver = 14; pilot = 12 }
$script:DemoNext = [ordered]@{ infantry = 145400; medic = 288450; support = 127200; recon = 43750; driver = 54750; pilot = 37500 }
$script:DemoSteps = @(
    'read',
    @(@('xp', 250, 'KILL', 'infantry'), @('cash', 160, 'CONTROL ZONE PRESENCE', '')),
    @(@('xp', 200, 'KILL ASSIST', 'infantry'), @('xp', 8, 'BUILDING', 'support'), @('xp', 8, 'BUILDING', 'support')),
    @(@('xp', 250, 'REVIVED TEAMMATE', 'medic'), @('cash', 375, 'REVIVED PLAYER ASSIST', '')),
    @(@('xp', 525, 'SUPPLIES DELIVERED', 'driver'), @('cash', -20, 'VEHICLE REFUELLING', '')),
    @(@('xp', 250, 'KILL', 'infantry'), @('xp', 250, 'KILL', 'infantry'), @('xp', 150, 'SPOTTED TARGET DESTROYED', 'recon')),
    @(@('xp', 400, 'SUPPLIES DELIVERED', 'pilot'), @('xp', 25, 'TACTICAL DEPLOYMENT', 'pilot')),
    @(@('xp', 250, 'KILL', 'infantry'), @('xp', 200, 'KILL ASSIST', 'infantry'), @('cash', 250, 'CONTROL ZONE ENTERED', '')),
    @(@('xp', 250, 'KILL', 'infantry'), @('xp', 250, 'KILL', 'infantry'), @('xp', 180, 'SUPPLIES DEPOSITED', 'support')),
    @(@('xp', 250, 'KILL', 'infantry'), @('xp', 250, 'KILL', 'infantry'), @('xp', 250, 'KILL', 'infantry')),
    'end', 'final')
function Invoke-DemoStep {
    $script:LiveState = 'on'
    $i = $script:Tick - 1
    if ($i -ge $script:DemoSteps.Count) { return }
    $step = $script:DemoSteps[$i]
    if ($step -eq 'end') { Invoke-EndMatch; return }
    if ($step -is [array]) {
        foreach ($p in $step) {
            $role = if ($p[3]) { $p[3] } else { $null }
            $out = Add-PopupEvent $p[0] $p[1] $p[2] $role $false
            foreach ($n in $out.NewTiers) { Show-TierAlert $n.Role $n.Tier }
        }
        Update-UI
        return
    }
    # 'read' at the start; 'final' after the match: the bonus is 700 XP per tier (2nd place)
    if ($step -eq 'final') {
        foreach ($r in $RoleOrder) { $script:DemoXp[$r] += [long]$State.EndGains[$r] + 700 * (Get-Tier ([long]$State.EndGains[$r])) }
    }
    foreach ($r in $RoleOrder) { while ($script:DemoXp[$r] -ge $script:DemoNext[$r]) { $script:DemoLv[$r]++; $script:DemoNext[$r] += 12000 } }
    $p = [ordered]@{}
    foreach ($r in $RoleOrder) { $p[$r] = [pscustomobject]@{ Level = $script:DemoLv[$r]; Xp = $script:DemoXp[$r]; NextXp = $script:DemoNext[$r] } }
    Use-Read $p
    if ($step -eq 'final' -and @($History).Count) { Show-MatchDetails $History[0] }
}

# ---------------------------------------------------------------- match details window
# (events can be dictionaries, which Measure-Object can't read by name, so sum them directly)
function Get-AmountSum($List) { $t = [long]0; foreach ($e in @($List)) { $t += [long]$e.Amount }; $t }

# One match's breakdown as a list of lines (head / row / note, with colors), shared by the details
# window and the saved page: totals, the deduced bonus, totals by reason, and every popup in order.
function Get-MatchLines($Entry, $Events, [bool]$Live) {
    $red = '#E0705A'
    $out = New-Object System.Collections.Generic.List[object]
    function Add-Head([string]$Text) { $out.Add([pscustomobject]@{ Kind = 'head'; Left = $Text; LeftColor = $Gold }) }
    function Add-Note([string]$Text, [string]$Color, [double]$Top) { $out.Add([pscustomobject]@{ Kind = 'note'; Left = $Text; LeftColor = $Color; Top = $Top }) }
    function Add-Line([string]$Left, [string]$Right, [string]$LeftColor = $Ink, [string]$RightColor = $Ink, [string]$Weight = 'Normal') {
        $out.Add([pscustomobject]@{ Kind = 'row'; Left = $Left; Right = $Right; LeftColor = $LeftColor; RightColor = $RightColor; Weight = $Weight })
    }
    $cashColor = { param([long]$v) if ($v -ge 0) { $Green } else { $red } }

    Add-Head 'SUMMARY'
    Add-Line 'Total XP' ('+{0:N0}' -f [long]$Entry.Xp) $Muted $Ink 'SemiBold'
    foreach ($r in $RoleOrder) {
        if ($Entry.Roles -and $null -ne $Entry.Roles[$r]) { $g = [long]$Entry.Roles[$r]; $t = Get-Tier $g; Add-Line "   $($RoleNames[$r])" ('+{0:N0}  {1}' -f $g, $(if ($t -ge $TierCount) { 'MAX' } else { "T$t" })) $Muted $(if ($t -ge $TierCount) { $Green } else { $Ink }) }
    }
    if ($null -ne $Entry.BonusTotal) {
        Add-Line ('End-of-match bonus (deduced)' + $(if ($Entry.Placement) { ", $($Entry.Placement)" })) ('+{0:N0}' -f [long]$Entry.BonusTotal) $Gold $Gold 'SemiBold'
        foreach ($r in $RoleOrder) { if ($Entry.Bonus -and $null -ne $Entry.Bonus[$r] -and [long]$Entry.Bonus[$r] -ne 0) { Add-Line "   $($RoleNames[$r])" ('+{0:N0}' -f [long]$Entry.Bonus[$r]) $Muted $Gold } }
    } elseif (-not $Live) { Add-Line 'End-of-match bonus (deduced)' 'not available' $Muted $Dim }
    if ($null -ne $Entry.NetCash) { Add-Line 'Cash this match (incl. gear bought)' (Format-Cash ([long]$Entry.NetCash)) $Muted (& $cashColor ([long]$Entry.NetCash)) 'SemiBold' }
    Add-Line 'Cash from popups' (Format-Cash ([long]$Entry.Cash)) $Muted (& $cashColor ([long]$Entry.Cash)) $(if ($null -eq $Entry.NetCash) { 'SemiBold' } else { 'Normal' })
    if ($null -ne $Entry.ResultsCash) { Add-Line 'Cash on the results screen' (Format-Cash ([long]$Entry.ResultsCash)) $Muted $Ink }

    if (@($Entry.Warnings).Count) {
        Add-Head 'CONFIDENCE'
        foreach ($wn in $Entry.Warnings) { Add-Note "!  $wn" '#E0B05A' 2 }
    }

    $xpEv = @($Events | Where-Object { $_.Kind -eq 'xp' }); $cashEv = @($Events | Where-Object { $_.Kind -eq 'cash' })
    foreach ($grp in @(@('XP BY REASON', $xpEv, 'xp'), @('CASH BY REASON', $cashEv, 'cash'))) {
        if (-not @($grp[1]).Count) { continue }
        Add-Head $grp[0]
        foreach ($g in (@($grp[1]) | Group-Object { $_.Reason } | Sort-Object { -[Math]::Abs((Get-AmountSum $_.Group)) })) {
            $sum = Get-AmountSum $g.Group
            $label = if ($g.Name) { (Get-Culture).TextInfo.ToTitleCase($g.Name.ToLower()) } else { 'Unlabeled' }
            $amount = if ($grp[2] -eq 'xp') { '+{0:N0} XP' -f $sum } else { Format-Cash $sum }
            Add-Line "$label  x$($g.Count)" $amount
        }
    }

    if (@($Events).Count) {
        Add-Head "EVERY POPUP ($(@($Events).Count))"
        foreach ($e in $Events) {
            $t = ([datetime]::Parse($e.T)).ToString('h:mm:ss')
            $label = (Get-Culture).TextInfo.ToTitleCase(([string]$e.Reason).ToLower())
            if ($e.Kind -eq 'xp') {
                $who = if ($e.Role) { $RoleNames[$e.Role] } else { '?' }
                Add-Line "$t   $label" ('+{0:N0} XP  {1}' -f [long]$e.Amount, $who) $Muted $Ink
            } else {
                Add-Line "$t   $label" ((Format-Cash ([long]$e.Amount)) + $(if ($e.Uncertain) { ' ?' } else { '' })) $Muted (& $cashColor ([long]$e.Amount))
            }
        }
    } else { Add-Note 'No popups were recorded for this match.' $Dim 14 }
    , $out
}

# SAVE in match details: writes the page, with the picture of the tracker at the end of the match,
# as one HTML file in Documents\Wardogs XP Tracker. Returns the file's path.
function Export-MatchReport($Entry, $Lines, [bool]$Live) {
    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Wardogs XP Tracker'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $start = [datetime]::Parse($Entry.Start)
    $file = Join-Path $dir ('Wardogs match {0}.html' -f $start.ToString('yyyy-MM-dd h.mm tt'))
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

    # The picture: saved at the end of the match, or (for the match in progress) the window right now.
    $img = ''
    $pic = if ($Entry.Snapshot) { Join-Path $DataDir $Entry.Snapshot } else { $null }
    if ($Live) { $pic = Join-Path $env:TEMP 'wardogs-live-snapshot.png'; if (-not (Save-WindowSnapshot $pic)) { $pic = $null } }
    if ($pic -and (Test-Path $pic)) {
        $img = '<figure><img alt="The tracker after this match" src="data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($pic)) + '"><figcaption>' + $(if ($Live) { 'The tracker when this was saved' } else { 'The tracker right after this match was filed' }) + '</figcaption></figure>'
    }
    $when = $start.ToString('dddd, MMM d, yyyy h:mm tt') + $(if ($Entry.End) { ' - ' + ([datetime]::Parse($Entry.End)).ToString('h:mm tt') } else { ' (in progress)' })

    $rows = foreach ($ln in $Lines) {
        switch ($ln.Kind) {
            'head' { '<h2>' + (& $enc $ln.Left) + '</h2>' }
            'note' { '<p class="note" style="color:' + $ln.LeftColor + '">' + (& $enc $ln.Left) + '</p>' }
            default {
                $wt = if ($ln.Weight -eq 'SemiBold') { ' class="b"' } else { '' }
                '<div class="row"' + $wt + '><span style="color:' + $ln.LeftColor + '">' + (& $enc $ln.Left) + '</span><span style="color:' + $ln.RightColor + '">' + (& $enc $ln.Right) + '</span></div>'
            }
        }
    }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wardogs match $(& $enc $start.ToString('MMM d h:mm tt'))</title>
<style>
body { margin: 0; background: #0B0907; color: $Ink; font: 14px/1.45 Bahnschrift, 'Segoe UI', sans-serif; }
main { max-width: 820px; margin: 0 auto; padding: 28px 16px 48px; display: flex; gap: 32px; align-items: flex-start; flex-wrap: wrap; }
header { width: 100%; }
.eyebrow { color: $Gold; font-size: 12px; font-weight: 600; letter-spacing: .06em; }
h1 { margin: 2px 0 0; font-size: 22px; font-weight: 600; }
figure { margin: 0; flex: 0 0 auto; }
figure img { display: block; width: 330px; max-width: 100%; border-radius: 6px; border: 1px solid #4A3F28; }
figcaption { color: $Dim; font-size: 12px; margin-top: 6px; }
.list { flex: 1 1 360px; min-width: 0; }
h2 { color: $Gold; font-size: 12px; font-weight: 600; letter-spacing: .04em; margin: 18px 0 4px; }
.row { display: flex; justify-content: space-between; gap: 16px; padding: 2px 0; border-bottom: 1px solid #1E1912; }
.row span:first-child { white-space: pre-wrap; }
.row span:last-child { white-space: nowrap; text-align: right; }
.b { font-weight: 600; }
.note { margin: 4px 0; font-size: 13px; }
footer { width: 100%; color: $Dim; font-size: 12px; }
</style></head><body><main>
<header><div class="eyebrow">//MATCH DETAILS</div><h1>$(& $enc $when)</h1></header>
$img
<div class="list">
$($rows -join "`n")
</div>
<footer>Saved by Wardogs XP Tracker v$AppVersion.</footer>
</main></body></html>
"@
    [IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding $true))
    $file
}

# $Entry is a filed match from history, or $null for the match in progress.
function Show-MatchDetails($Entry) {
    $live = -not $Entry
    if ($live) {
        $gains = Get-RoleGains
        $roles = [ordered]@{}; foreach ($r in $RoleOrder) { if ($gains[$r] -gt 0) { $roles[$r] = $gains[$r] } }
        $events = @($State.Events)
        $Entry = [ordered]@{ Start = $State.Start; End = $null; Xp = [long](@($roles.Values) | Measure-Object -Sum).Sum; Roles = $roles
            Bonus = $null; BonusTotal = $null; Placement = $null; Payout = $null; Cash = [long]$State.Cash; ResultsCash = $State.ResultsCash
            NetCash = $(if ($null -ne $State.BankStart -and $null -ne $State.BankNow) { Get-MatchCash } else { $null })
            Unparsed = [int]$State.Unparsed; Warnings = @() }
        if ([int]$State.Unparsed -gt 0) { $Entry.Warnings += "$($State.Unparsed) popup reads couldn't be understood so far." }
        if ([long]$State.UnknownXp -gt 0) { $Entry.Warnings += "$($State.UnknownXp) popup XP couldn't be matched to a class." }
        if ([int]$State.CashUncertain -gt 0) { $Entry.Warnings += "$($State.CashUncertain) cash amounts are uncertain (the `$ sign was misread)." }
    } else { $events = @(Get-MatchEvents $Entry) }

    $start = [datetime]::Parse($Entry.Start)
    $when = "$(Format-When $Entry.Start)" + $(if ($Entry.End) { " - $(([datetime]::Parse($Entry.End)).ToString('h:mm tt'))" } else { '  (in progress)' })
    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Match details" Width="440" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" FontFamily="Bahnschrift, Segoe UI" Foreground="$Ink" UseLayoutRounding="True">
  <Border CornerRadius="6" BorderBrush="#4A3F28" BorderThickness="1" Background="#FF14100A">
    <DockPanel>
      <Grid DockPanel.Dock="Top" x:Name="DHead" Background="#01000000" Margin="16,12,10,6" Cursor="SizeAll">
        <StackPanel>
          <TextBlock Text="//MATCH DETAILS" FontSize="11" FontWeight="SemiBold" Foreground="$Gold"/>
          <TextBlock x:Name="DWhen" FontSize="16" FontWeight="SemiBold"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Button x:Name="DPic" Content="PICTURE" ToolTip="The tracker right after this match was filed" Foreground="$Muted" Background="Transparent" BorderBrush="#4A3F28" Padding="8,3" FontSize="11" Cursor="Hand" Margin="0,0,6,0"/>
          <Button x:Name="DSave" Content="SAVE" ToolTip="Save this page (with the picture) to Documents\Wardogs XP Tracker and open it" Foreground="$Gold" Background="Transparent" BorderBrush="#4A3F28" Padding="8,3" FontSize="11" Cursor="Hand" Margin="0,0,6,0"/>
          <Button x:Name="DClose" Content="CLOSE" Foreground="$Muted" Background="Transparent" BorderBrush="#4A3F28" Padding="8,3" FontSize="11" Cursor="Hand"/>
        </StackPanel>
      </Grid>
      <ScrollViewer x:Name="DScroll" VerticalScrollBarVisibility="Auto" Margin="16,0,8,14">
        <StackPanel x:Name="DBody" Margin="0,0,8,0"/>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $body = $w.FindName('DBody')
    $w.FindName('DWhen').Text = $when
    $w.FindName('DClose').add_Click({ $w.Close() }.GetNewClosure())
    $w.FindName('DHead').add_MouseLeftButtonDown({ try { $w.DragMove() } catch {} }.GetNewClosure())
    $w.FindName('DScroll').MaxHeight = [Math]::Max(300, [System.Windows.SystemParameters]::WorkArea.Height * 0.8)

    $lines = Get-MatchLines $Entry $events $live
    foreach ($ln in $lines) {
        if ($ln.Kind -eq 'row') {
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $ln.Left; $l.Foreground = New-Brush $ln.LeftColor; $l.FontSize = 13; $l.TextTrimming = 'CharacterEllipsis'; $l.Margin = New-Object System.Windows.Thickness 0, 0, 90, 0
            $r = New-Object System.Windows.Controls.TextBlock; $r.Text = $ln.Right; $r.Foreground = New-Brush $ln.RightColor; $r.FontSize = 13; $r.HorizontalAlignment = 'Right'
            $l.FontWeight = $r.FontWeight = [System.Windows.FontWeights]::($ln.Weight)
            [void]$g.Children.Add($l); [void]$g.Children.Add($r)
            [void]$body.Children.Add($g)
        } else {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $ln.Left; $t.Foreground = New-Brush $ln.LeftColor; $t.TextWrapping = 'Wrap'
            if ($ln.Kind -eq 'head') { $t.FontSize = 11; $t.FontWeight = [System.Windows.FontWeights]::SemiBold; $top = 14 } else { $t.FontSize = 12.5; $top = $ln.Top }
            $t.Margin = New-Object System.Windows.Thickness 0, $top, 0, 0
            [void]$body.Children.Add($t)
        }
    }

    # PICTURE: the window at the end of the match (filed matches from v2.3 on).
    $pic = if ($Entry.Snapshot) { Join-Path $DataDir $Entry.Snapshot } else { $null }
    # (Handlers get this match's data through the window's Tag: a closure couldn't see this script's functions.)
    $w.Tag = @{ Entry = $Entry; Lines = $lines; Live = $live; Pic = $pic }
    $picBtn = $w.FindName('DPic')
    if ($pic -and (Test-Path $pic)) {
        $picBtn.add_Click({ param($s) Start-Process ([System.Windows.Window]::GetWindow($s).Tag.Pic) })
    } else { $picBtn.Visibility = 'Collapsed' }
    $w.FindName('DSave').add_Click({
        param($s)
        $d = [System.Windows.Window]::GetWindow($s).Tag
        try {
            $file = Export-MatchReport $d.Entry $d.Lines $d.Live
            Write-Log "match saved to $file"
            Start-Process $file
        } catch { Write-Log "save ERROR $_"; Set-Status "Couldn't save the match: $($_.Exception.Message)" }
    })

    # Open next to the tracker, on the same screen.
    $w.WindowStartupLocation = 'Manual'
    $w.Left = [Math]::Max(0, $win.Left - 450); $w.Top = $win.Top
    if ($w.Left + 10 -lt [System.Windows.SystemParameters]::VirtualScreenLeft) { $w.Left = $win.Left + $win.ActualWidth + 10 }
    $w.Show()
}

# ---------------------------------------------------------------- popup area picker
# Dims the game's screen; drag a box around where the XP/cash popups appear, then Enter (Esc cancels).
function Show-AreaPicker([System.Drawing.Rectangle]$Current) {
    $screen = [System.Windows.Forms.Screen]::FromRectangle($Current)
    $b = $screen.Bounds
    $s = Get-Scale
    [xml]$x = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="#80000000" Topmost="True" ShowInTaskbar="False" Cursor="Cross">
  <Grid>
    <Canvas x:Name="Board" Background="#01000000">
      <Rectangle x:Name="Sel" Stroke="$Gold" StrokeThickness="2" Fill="#2AD8B45A"/>
    </Canvas>
    <Border VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,80,0,0" Background="#E614100A" BorderBrush="#4A3F28" BorderThickness="1" CornerRadius="4" Padding="14,10" Cursor="Arrow">
      <StackPanel>
        <TextBlock FontFamily="Bahnschrift, Segoe UI" FontSize="15" Foreground="$Ink" TextAlignment="Center"
                   Text="Drag a box around where the XP and cash popups appear (under the cash boxes, top right).&#x0a;Make it tall enough for a full stack of popups. Enter saves; Esc or right-click cancels."/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0">
          <Button x:Name="PickSave" Content="SAVE" Padding="16,4" Margin="0,0,8,0" Foreground="#15110A" Background="$Gold" BorderThickness="0" FontFamily="Bahnschrift, Segoe UI" FontWeight="SemiBold"/>
          <Button x:Name="PickCancel" Content="CANCEL" Padding="12,4" Foreground="$Ink" Background="Transparent" BorderBrush="#4A3F28" FontFamily="Bahnschrift, Segoe UI"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $w.Left = $b.X / $s; $w.Top = $b.Y / $s; $w.Width = $b.Width / $s; $w.Height = $b.Height / $s
    $sel = $w.FindName('Sel'); $board = $w.FindName('Board')
    $pick = @{ Start = $null; Rect = $null; Result = $null }
    $place = {
        param($x1, $y1, $x2, $y2)
        $l = [Math]::Min($x1, $x2); $t = [Math]::Min($y1, $y2)
        [System.Windows.Controls.Canvas]::SetLeft($sel, $l); [System.Windows.Controls.Canvas]::SetTop($sel, $t)
        $sel.Width = [Math]::Abs($x2 - $x1); $sel.Height = [Math]::Abs($y2 - $y1)
        $pick.Rect = @($l, $t, $sel.Width, $sel.Height)
    }
    # Show the current area to start with.
    & $place (($Current.X - $b.X) / $s) (($Current.Y - $b.Y) / $s) (($Current.Right - $b.X) / $s) (($Current.Bottom - $b.Y) / $s)
    $board.add_MouseLeftButtonDown({ param($o, $e) $p = $e.GetPosition($board); $pick.Start = $p; $board.CaptureMouse() | Out-Null }.GetNewClosure())
    $board.add_MouseMove({ param($o, $e) if ($pick.Start) { $p = $e.GetPosition($board); & $place $pick.Start.X $pick.Start.Y $p.X $p.Y } }.GetNewClosure())
    $board.add_MouseLeftButtonUp({ param($o, $e) $pick.Start = $null; $board.ReleaseMouseCapture() }.GetNewClosure())
    $save = {
        if ($pick.Rect -and $pick.Rect[2] -ge 40 -and $pick.Rect[3] -ge 30) {
            $r = $pick.Rect
            $pick.Result = New-Object System.Drawing.Rectangle ([int][Math]::Round($b.X + $r[0] * $s)), ([int][Math]::Round($b.Y + $r[1] * $s)), ([int][Math]::Round($r[2] * $s)), ([int][Math]::Round($r[3] * $s))
            $w.Close()
        }
    }.GetNewClosure()
    $w.FindName('PickSave').add_Click($save)
    $w.FindName('PickCancel').add_Click({ $w.Close() }.GetNewClosure())
    $board.add_MouseRightButtonUp({ $w.Close() }.GetNewClosure())
    $w.add_KeyDown({
        param($o, $e)
        if ($e.Key -eq 'Escape') { $w.Close() }
        if ($e.Key -eq 'Enter') { & $save }
    }.GetNewClosure())
    $w.add_ContentRendered({ $w.Activate() | Out-Null; $w.Focus() | Out-Null }.GetNewClosure())
    [void]$w.ShowDialog()
    $pick.Result
}

function Set-PopupArea {
    $picked = Show-AreaPicker (Get-PopupRect)
    if (-not $picked) { return }
    $Settings.PopupRect = '{0},{1},{2},{3}' -f $picked.X, $picked.Y, $picked.Width, $picked.Height
    Save-Settings
    Reset-PopupTracks; $script:PopLastGrid = $null
    Write-Log "popup area set to $($Settings.PopupRect)"
    $tray.ShowBalloonTip(2500, 'Wardogs XP Tracker', 'Popup area saved.', 'None')
}

# ---------------------------------------------------------------- tray icon
# The app's "XP" badge, drawn at any size (tray icon, shortcut icon).
function New-BadgeBitmap([int]$Size) {
    $k = $Size / 32.0
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 16, 10))), 0, 0, $Size, $Size)
    $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(216, 180, 90)), (2 * $k)), $k, $k, (29 * $k), (29 * $k))
    $font = New-Object System.Drawing.Font 'Bahnschrift', (15 * $k), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString('XP', $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(216, 180, 90))), (New-Object System.Drawing.RectangleF 0, $k, $Size, $Size), $fmt)
    $g.Dispose()
    $bmp
}

function New-TrayIcon { [System.Drawing.Icon]::FromHandle((New-BadgeBitmap 32).GetHicon()) }

# ---------------------------------------------------------------- shortcuts
# Start menu (on by default), desktop and Start with Windows (off by default), each a tray toggle.
# They start the tracker the same way as Start XP Tracker.cmd, from wherever it's extracted.
$ShortcutName = 'Wardogs XP Tracker.lnk'
function Get-ShortcutPath([string]$Kind) {
    $folder = switch ($Kind) { 'StartMenu' { 'Programs' } 'Desktop' { 'Desktop' } 'Startup' { 'Startup' } }
    Join-Path ([Environment]::GetFolderPath($folder)) $ShortcutName
}

# A 256 px icon file for the shortcuts (an .ico holding one PNG image).
function Get-ShortcutIcon {
    $path = Join-Path $DataDir 'tracker.ico'
    if (Test-Path $path) { return $path }
    $bmp = New-BadgeBitmap 256
    $png = New-Object IO.MemoryStream
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $data = $png.ToArray()
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)              # icon file, one image
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0) # 256 x 256, no palette
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$data.Length); $w.Write([uint32]22)
    $w.Write($data); $w.Flush()
    [IO.File]::WriteAllBytes($path, $out.ToArray())
    $path
}

function Set-Shortcut([string]$Kind, [bool]$On) {
    $path = Get-ShortcutPath $Kind
    if (-not $On) { if (Test-Path $path) { Remove-Item $path -Force }; return }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'XpTracker.ps1')`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = Get-ShortcutIcon
    $lnk.WindowStyle = 7   # minimized, so no console window flashes up
    $lnk.Description = 'Wardogs XP Tracker'
    $lnk.Save()
}

# At startup: (re)write the shortcuts that are on, so they follow the folder if it was moved.
function Update-Shortcuts {
    foreach ($s in @(@('StartMenu', 'StartMenuShortcut'), @('Desktop', 'DesktopShortcut'), @('Startup', 'StartWithWindows'))) {
        if ($Settings[$s[1]]) { try { Set-Shortcut $s[0] $true } catch { Write-Log "shortcut ERROR ($($s[0])) $_" } }
    }
}

function Switch-Shortcut([string]$Kind, [string]$Setting, $MenuItem) {
    $on = -not $Settings[$Setting]
    try {
        Set-Shortcut $Kind $on
        $Settings[$Setting] = $on; Save-Settings
        $MenuItem.Checked = $on
    } catch {
        Write-Log "shortcut ERROR ($Kind) $_"
        $tray.ShowBalloonTip(4000, 'Wardogs XP Tracker', "Couldn't change the shortcut: $($_.Exception.Message)", 'Warning')
    }
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = "Wardogs XP Tracker v$AppVersion$(if ($Demo) { ' (demo)' })"
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow    = $menu.Items.Add('Hide');                $miShow.ShortcutKeyDisplayString  = 'Ctrl+Shift+O'
$miNext    = $menu.Items.Add('End match');           $miNext.ShortcutKeyDisplayString  = 'Ctrl+Shift+N'
$miDetails = $menu.Items.Add('Match details')
$miLive    = $menu.Items.Add('Live popup tracking'); $miLive.ShortcutKeyDisplayString  = 'Ctrl+Shift+C'
$miArea    = $menu.Items.Add('Set popup area...')
$miAreaReset = $menu.Items.Add('Reset popup area')
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
$miShortcuts = New-Object System.Windows.Forms.ToolStripMenuItem 'Shortcuts'
$miScStart = $miShortcuts.DropDownItems.Add('In the Start menu'); $miScStart.Checked = [bool]$Settings.StartMenuShortcut
$miScDesk  = $miShortcuts.DropDownItems.Add('On the desktop');    $miScDesk.Checked  = [bool]$Settings.DesktopShortcut
$miScBoot  = $miShortcuts.DropDownItems.Add('Start with Windows'); $miScBoot.Checked = [bool]$Settings.StartWithWindows
$miScStart.add_Click({ Switch-Shortcut 'StartMenu' 'StartMenuShortcut' $miScStart })
$miScDesk.add_Click({ Switch-Shortcut 'Desktop' 'DesktopShortcut' $miScDesk })
$miScBoot.add_Click({ Switch-Shortcut 'Startup' 'StartWithWindows' $miScBoot })
$menu.Items.Add($miShortcuts) | Out-Null
$miFolder  = $menu.Items.Add('Open data folder')
$menu.Items.Add('-') | Out-Null
$miQuit    = $menu.Items.Add('Quit')

$miShow.add_Click({ Set-Visible $script:Hidden })
$miNext.add_Click({ Invoke-EndMatch })
$miDetails.add_Click({ Show-MatchDetails $null })
$miLive.add_Click({ Switch-Continuous })
$miArea.add_Click({ Set-PopupArea })
$miAreaReset.add_Click({ $Settings.PopupRect = $null; Save-Settings; Reset-PopupTracks; $script:PopLastGrid = $null; $tray.ShowBalloonTip(2000, 'Wardogs XP Tracker', 'Popup area reset to the default spot.', 'None') })
$miFind.add_Click({ Invoke-ManualFind })
$miClick.add_Click({ Set-ClickThrough (-not $Settings.ClickThrough) })
$miFolder.add_Click({ Start-Process explorer.exe $DataDir })
$miQuit.add_Click({ $app.Shutdown() })
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Set-Visible $script:Hidden } })
$tray.ContextMenuStrip = $menu

# ---------------------------------------------------------------- wiring
$ui.BtnNext.add_Click({ Invoke-EndMatch })
$ui.BtnDetails.add_Click({ Show-MatchDetails $null })
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
    # The last match filed before pictures were taken: if nothing has happened since, the window
    # still shows it just as it looked when filed.
    try { if (-not $Demo -and @($History).Count -and -not $History[0].Snapshot -and -not (Test-MatchActive)) { Save-FiledSnapshot $History[0] } } catch { Write-Log "snapshot ERROR $_" }
    $newStart = $false
    if (-not $Demo) {
        $newStart = $Settings.StartMenuShortcut -and -not (Test-Path (Get-ShortcutPath 'StartMenu'))
        Update-Shortcuts
    }
    $where = if (@([System.Windows.Forms.Screen]::AllScreens).Count -gt 1) { 'on your screen' } else { 'in the corner of your screen' }
    $tip = if ($newStart) { "It's $where. Next time, start it from the Start menu: search for Wardogs. (Desktop shortcut and Start with Windows are in the tray menu under Shortcuts.)" } else { "It's $where. Drag it anywhere, or press Ctrl+Shift+M to jump between corners." }
    if (-not $Demo) { $tray.ShowBalloonTip(6000, 'Wardogs XP Tracker is running', $tip, 'None') }
})

$MOD = 0x2 -bor 0x4   # Ctrl + Shift
$hotkeys = New-Object WdHotkeys
$failed = @()
$keys = @{ 1 = 0x4E; 2 = 0x55; 3 = 0x4F; 4 = 0x4C; 5 = 0x21; 6 = 0x22; 7 = 0x4D; 8 = 0x43 }   # N U O L PageUp PageDown M C
$keyNames = @{ 1 = 'N'; 2 = 'U'; 3 = 'O'; 4 = 'L'; 5 = 'PageUp'; 6 = 'PageDown'; 7 = 'M'; 8 = 'C' }
foreach ($id in 1..8) { if (-not $hotkeys.Add($id, $MOD, $keys[$id])) { $failed += "Ctrl+Shift+$($keyNames[$id])" } }
$hotkeys.add_Pressed({
    param($id)
    switch ($id) {
        1 { Invoke-EndMatch }
        2 { Invoke-ManualFind }
        3 { Set-Visible $script:Hidden }
        4 { Set-ClickThrough (-not $Settings.ClickThrough) }
        5 { Set-Opacity ($Settings.Opacity + 10) }
        6 { Set-Opacity ($Settings.Opacity - 10) }
        7 { if ($script:Hidden) { Set-Visible $true }; Move-ToNextCorner }
        8 { Switch-Continuous }
    }
})
if ($failed) { $script:Status = "Hotkeys already used by another app: $($failed -join ', ')"; Write-Log $script:Status }

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromSeconds(2)
$pollTimer.add_Tick({ Invoke-Poll })

$topTimer = New-Object System.Windows.Threading.DispatcherTimer
$topTimer.Interval = [TimeSpan]::FromSeconds(2)
$topTimer.add_Tick({ if (-not $script:Hidden) { [WdNative]::KeepOnTop($script:hwnd) } })

$popupTimer = New-Object System.Windows.Threading.DispatcherTimer
$popupTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(100, [int]$Settings.PopupPollMs))
$popupTimer.add_Tick({ Invoke-PopupPoll })

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.add_Exit({
    $popupTimer.Stop()
    $pollTimer.Stop(); $topTimer.Stop()
    try { Save-Tracker } catch {}
    $hotkeys.Dispose()
    $tray.Visible = $false; $tray.Dispose()
})

$tray.Visible = $true
$miClick.Checked = $Settings.ClickThrough
Set-Opacity $Settings.Opacity
Update-UI
$miLive.Checked = $Settings.Continuous
$pollTimer.Start(); $topTimer.Start(); $popupTimer.Start()
Write-Log "ready (demo=$Demo)"
# Start off-screen; ContentRendered moves it into place once its size is known (avoids a flash on the main monitor).
$win.Left = -32000; $win.Top = -32000
$win.Show()
[void]$app.Run()
$mutex.ReleaseMutex()
