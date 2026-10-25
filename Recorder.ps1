# Sample recorder: saves what appears in the top-right corner of the game (XP/cash popups and the
# cash boxes) so the popup reader can be built and tuned from real examples. Temporary: it goes
# away once the popup reader exists.
#
# Which class a popup belongs to is worked out afterwards from the Wardog Level reads in
# session.log (whichever role's XP rose between two reads), so recordings aren't tied to a class.
#
# Each recording is one session folder under <data>\samples\<date_time>\ with:
#   frames\HHmmss-fff.jpg   the corner, 2 frames a second, skipping frames identical to the last
#   full-HHmmss.jpg         the whole game window every 2 minutes (and on Ctrl+Shift+S)
#   session.log             start/stop, settings used, and every Wardog Level read while recording
#
# Needs GameReader.ps1 (Get-GameProcess, Get-GameRect, Get-ScreenBitmap) and the caller's Write-Log.

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Cheap frame comparison: shrink to a small grayscale thumbnail and compare those.
public static class WdFrames {
    public static byte[] Thumb(Bitmap src, int w, int h) {
        using (var small = new Bitmap(w, h, PixelFormat.Format24bppRgb))
        using (var g = Graphics.FromImage(small)) {
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.DrawImage(src, 0, 0, w, h);
            var data = small.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            var buf = new byte[data.Stride * h];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            small.UnlockBits(data);
            var gray = new byte[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++) {
                    int i = y * data.Stride + x * 3;
                    gray[y * w + x] = (byte)((buf[i] * 29 + buf[i + 1] * 150 + buf[i + 2] * 77) >> 8);
                }
            return gray;
        }
    }

    // Mean absolute difference per pixel, 0 (identical) to 255.
    public static double Diff(byte[] a, byte[] b) {
        if (a == null || b == null || a.Length != b.Length) return 255;
        long sum = 0;
        for (int i = 0; i < a.Length; i++) sum += Math.Abs(a[i] - b[i]);
        return (double)sum / a.Length;
    }
}
'@

$RecordFps        = 2       # frames a second while recording
$RecordMaxFrames  = 5000    # a session stops itself after this many saved frames
$RecordMinFreeGB  = 2       # ...or when the disk has less free space than this
$RecordFullEvery  = 120     # seconds between whole-window screenshots
$RecordSameFrame  = 1.0     # thumbnail difference below this counts as "nothing changed"

$script:Rec = $null   # the active session, or $null
$script:JpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'

function Save-Jpeg([System.Drawing.Bitmap]$Bitmap, [string]$Path, [int]$Quality = 80) {
    $params = New-Object System.Drawing.Imaging.EncoderParameters 1
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$Quality)
    $Bitmap.Save($Path, $script:JpegCodec, $params)
}

# The area recorded: the right 40% and top half of the game window, unless RecordRect is set.
function Get-RecordRect {
    if ($Settings.RecordRect) {
        $p = $Settings.RecordRect -split ',' | ForEach-Object { [int]$_ }
        return New-Object System.Drawing.Rectangle $p[0], $p[1], $p[2], $p[3]
    }
    $g = Get-GameRect
    New-Object System.Drawing.Rectangle ([int]($g.X + $g.Width * 0.6)), $g.Y, ([int]($g.Width * 0.4)), ([int]($g.Height * 0.5))
}

function Get-SamplesDir { Join-Path $DataDir 'samples' }

function Write-RecLog([string]$Text) {
    if ($script:Rec) { Add-Content -Path (Join-Path $script:Rec.Dir 'session.log') -Value "$(Get-Date -Format 'HH:mm:ss.fff') $Text" -Encoding utf8 }
}

function Start-Recording {
    if ($script:Rec) { return }
    $dir = Join-Path (Get-SamplesDir) (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'frames') | Out-Null
    $script:Rec = @{ Dir = $dir; Start = Get-Date; Frames = 0; Skipped = 0; LastThumb = $null; LastFull = [datetime]::MinValue }
    Write-RecLog "start: area=$(Get-RecordRect) fps=$RecordFps tracker=v$AppVersion"
    Write-Log "recording started -> $dir"
}

function Stop-Recording([string]$Why = 'stopped') {
    if (-not $script:Rec) { return }
    $mins = ((Get-Date) - $script:Rec.Start).TotalMinutes
    Write-RecLog ("stop ({0}): {1} frames saved, {2} unchanged skipped, {3:N1} min" -f $Why, $script:Rec.Frames, $script:Rec.Skipped, $mins)
    Write-Log "recording stopped ($Why): $($script:Rec.Frames) frames in $($script:Rec.Dir)"
    $script:Rec = $null
}

# One recorder tick. Returns a reason string if the session stopped itself, else $null.
function Invoke-RecordTick {
    if (-not $script:Rec) { return $null }
    if (-not (Get-GameProcess)) { return $null }   # game closed or not detected: just wait
    if ($script:Rec.Frames -ge $RecordMaxFrames) { Stop-Recording "reached $RecordMaxFrames frames"; return "Recording stopped after $RecordMaxFrames frames." }
    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($DataDir))
    if ($drive.AvailableFreeSpace -lt $RecordMinFreeGB * 1GB) { Stop-Recording 'disk almost full'; return "Recording stopped: less than $RecordMinFreeGB GB free on $($drive.Name)." }

    $now = Get-Date
    $bmp = Get-ScreenBitmap (Get-RecordRect)
    try {
        $thumb = [WdFrames]::Thumb($bmp, 64, 40)
        if ([WdFrames]::Diff($thumb, $script:Rec.LastThumb) -lt $RecordSameFrame) { $script:Rec.Skipped++ }
        else {
            Save-Jpeg $bmp (Join-Path $script:Rec.Dir ("frames\{0}.jpg" -f $now.ToString('HHmmss-fff')))
            $script:Rec.LastThumb = $thumb
            $script:Rec.Frames++
        }
    } finally { $bmp.Dispose() }

    if (($now - $script:Rec.LastFull).TotalSeconds -ge $RecordFullEvery) { Save-FullScreenshot | Out-Null }
    $null
}

# Whole game window, into the current session (or samples\manual when not recording). Returns the path.
function Save-FullScreenshot([switch]$Manual) {
    $dir = if ($script:Rec) { $script:Rec.Dir } else { Join-Path (Get-SamplesDir) 'manual' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ("{0}full-{1}.jpg" -f $(if ($Manual) { 'manual-' } else { '' }), (Get-Date -Format 'HHmmss'))
    $bmp = Get-ScreenBitmap (Get-GameRect)
    try { Save-Jpeg $bmp $path 90 } finally { $bmp.Dispose() }
    if ($script:Rec) { $script:Rec.LastFull = Get-Date; Write-RecLog "full screenshot $(Split-Path $path -Leaf)$(if ($Manual) { ' (manual)' })" }
    $path
}

# Short text for the status line, e.g. "REC 12:04 - 830 frames".
function Get-RecordStatus {
    if (-not $script:Rec) { return '' }
    $t = (Get-Date) - $script:Rec.Start
    "REC {0:00}:{1:00} - {2} frames" -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds, $script:Rec.Frames
}
