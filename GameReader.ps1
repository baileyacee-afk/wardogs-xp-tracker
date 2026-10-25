# Reads role levels and XP from the in-game "Wardog Level" screen.
# Takes a screenshot of the game window and runs the OCR built into Windows on it.
# It never touches the game process itself, only pixels on screen.
#
# Dot-source this file, then:  Read-GameProgress  ->  @{ infantry = @{ Level = 21; Xp = 130627; NextXp = 145400 }; ... }
# Standalone test on an image:  . .\GameReader.ps1; Read-GameProgress -ImagePath shot.png

Add-Type -AssemblyName System.Runtime.WindowsRuntime, System.Drawing, System.Windows.Forms
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

# On-screen label -> the site's role id
$GameRoles = [ordered]@{ ASSAULT = 'infantry'; MEDIC = 'medic'; SUPPORT = 'support'; RECON = 'recon'; DRIVER = 'driver'; PILOT = 'pilot' }

$script:AsTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRt($Operation, [Type]$ResultType) {
    $task = $script:AsTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait() | Out-Null
    $task.Result
}

# The game's program is normally WardogsClient-Win64-Shipping, but other stores or builds may name it
# differently, so also accept any program starting with "Wardogs" or a window titled just "Wardogs".
# Listing every process is slow and this is asked several times a second, so the answer is kept for 5 s.
$script:GameProc = $null
$script:GameProcAt = [datetime]::MinValue
function Get-GameProcess {
    if (((Get-Date) - $script:GameProcAt).TotalSeconds -lt 5) {
        if (-not $script:GameProc) { return $null }
        try { if (-not $script:GameProc.HasExited) { return $script:GameProc } } catch {}
    }
    $script:GameProc = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and
        ($_.ProcessName -like 'Wardogs*' -or $_.MainWindowTitle.Trim() -eq 'Wardogs')
    } | Sort-Object { $_.ProcessName -ne 'WardogsClient-Win64-Shipping' } | Select-Object -First 1
    $script:GameProcAt = Get-Date
    $script:GameProc
}

# Screen rectangle of the game window (borderless/windowed), or the main screen if the game isn't running.
function Get-GameRect {
    $game = Get-GameProcess
    if ($game) {
        $r = New-Object WdNative+RECT
        if ([WdNative]::GetWindowRect($game.MainWindowHandle, [ref]$r) -and ($r.Right - $r.Left) -gt 200) {
            return New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
        }
    }
    [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
}

function Get-ScreenBitmap([System.Drawing.Rectangle]$Rect) {
    $bmp = New-Object System.Drawing.Bitmap $Rect.Width, $Rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Rect.Location, [System.Drawing.Point]::Empty, $Rect.Size)
    $g.Dispose()
    $bmp
}

function Get-GameScreenshot { Get-ScreenBitmap (Get-GameRect) }

# True when a capture is (nearly) all black, which is what exclusive fullscreen and some HDR setups give.
function Test-BlankBitmap([System.Drawing.Bitmap]$Bitmap) {
    $step = [Math]::Max(1, [int]([Math]::Min($Bitmap.Width, $Bitmap.Height) / 24))
    for ($y = 0; $y -lt $Bitmap.Height; $y += $step) {
        for ($x = 0; $x -lt $Bitmap.Width; $x += $step) {
            if ($Bitmap.GetPixel($x, $y).GetBrightness() -gt 0.06) { return $false }
        }
    }
    $true
}

# Windows' OCR engine, created once. English if it's installed, otherwise the user's own languages.
function Get-OcrEngine {
    if (-not $script:OcrEngine) {
        $lang = New-Object Windows.Globalization.Language 'en-US'
        $script:OcrEngine = if ([Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($lang)) { [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang) }
                            else { [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
        if (-not $script:OcrEngine) {
            throw "Windows text recognition isn't installed. Open Settings > Time & language > Language & region, add English (United States), then restart the tracker."
        }
    }
    $script:OcrEngine
}

# Returns every recognized word with its position in the original image's pixels.
function Read-OcrWords([System.Drawing.Bitmap]$Bitmap, [double]$Scale = 2.0) {
    # Upscaling makes the small XP text much more reliable.
    $scale = [Math]::Min($Scale, [Windows.Media.Ocr.OcrEngine]::MaxImageDimension / [double][Math]::Max($Bitmap.Width, $Bitmap.Height))
    $big = New-Object System.Drawing.Bitmap ([int]($Bitmap.Width * $scale)), ([int]($Bitmap.Height * $scale))
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($Bitmap, 0, 0, $big.Width, $big.Height)
    $g.Dispose()

    $png = New-Object IO.MemoryStream
    $big.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()
    $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $writer = New-Object Windows.Storage.Streams.DataWriter($stream)
    $writer.WriteBytes($png.ToArray())
    Wait-WinRt ($writer.StoreAsync()) ([uint32]) | Out-Null
    $stream.Seek(0)
    $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $soft = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $result = Wait-WinRt ((Get-OcrEngine).RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])

    foreach ($line in $result.Lines) {
        foreach ($w in $line.Words) {
            $b = $w.BoundingRect
            [pscustomobject]@{
                Text = $w.Text
                X = $b.X / $scale; Y = $b.Y / $scale; W = $b.Width / $scale; H = $b.Height / $scale
                CX = ($b.X + $b.Width / 2) / $scale
            }
        }
    }
}

# "130,627/" -> 130627, "145,400XP" -> 145400, "2O" -> 20. Returns $null if it isn't a number.
function ConvertTo-GameNumber([string]$Text) {
    $t = $Text -replace '(?i)xp$', '' -replace '[,./\s]', ''
    $t = $t -replace '[Oo]', '0' -replace '[Il|]', '1' -replace 'S', '5' -replace 'B', '8'
    if ($t -match '^\d{1,9}$') { [int]$t } else { $null }
}

function Get-EditDistance([string]$A, [string]$B) {
    $prev = 0..$B.Length
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = @($i) + (1..$B.Length | ForEach-Object { 0 })
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    $prev[$B.Length]
}

# Which role a word names, allowing one OCR slip ("SUPP0RT", "PILOT|", "Recon"); $null if none.
function Get-RoleFromLabel([string]$Text) {
    $t = $Text.ToUpper() -replace '0', 'O' -replace '1', 'I' -replace '5', 'S' -replace '8', 'B' -replace '[^A-Z]', ''
    if ($t.Length -lt 4 -or $t.Length -gt 9) { return $null }
    if ($GameRoles.Contains($t)) { return $GameRoles[$t] }
    foreach ($name in $GameRoles.Keys) {
        if ([Math]::Abs($name.Length - $t.Length) -le 1 -and (Get-EditDistance $t $name) -le 1) { return $GameRoles[$name] }
    }
    $null
}

# Also sets $script:PanelBounds: the area (in image pixels) covering every word that was used,
# so later reads can capture just that part of the screen.
function Get-RoleProgress($Words) {
    # Role-name labels. (Our own window also shows role names, but it's hidden while we take screenshots.)
    $labels = @(foreach ($w in $Words) {
        $r = Get-RoleFromLabel $w.Text
        if ($r) { $w | Add-Member -NotePropertyName Role -NotePropertyValue $r -Force -PassThru }
    })
    $progress = [ordered]@{}
    $script:PanelBounds = $null
    $script:PanelGrid = $null
    $usedLabels = @()

    foreach ($label in $labels) {
        $role = $label.Role
        if ($progress.Contains($role)) { continue }

        # Words in this label's column: the nearest label above them (same column) is this one.
        $tol = $label.W + 10
        $mine = $Words | Where-Object {
            $w = $_
            if ($w.Y -le $label.Y -or [Math]::Abs($w.CX - $label.CX) -gt $tol) { return $false }
            $owner = $labels | Where-Object { $_.Y -lt $w.Y -and [Math]::Abs($w.CX - $_.CX) -le ($_.W + 10) } |
                Sort-Object Y -Descending | Select-Object -First 1
            $owner -eq $label
        } | Sort-Object Y

        # OCR sometimes splits one number ("278,152 /" -> "278," "152/"). Rejoin pieces that sit on the
        # same line, left to right, so they aren't read as separate numbers in the wrong order.
        $lines = @()
        foreach ($w in $mine) {
            $mid = $w.Y + $w.H / 2
            $line = $lines | Where-Object { [Math]::Abs($mid - $_.Mid) -lt [Math]::Max($w.H, $_.H) * 0.6 } | Select-Object -First 1
            if ($line) { $line.Parts += $w } else { $lines += [pscustomobject]@{ Mid = $mid; H = $w.H; Parts = @($w) } }
        }
        $mine = foreach ($line in ($lines | Sort-Object Mid)) {
            $parts = @($line.Parts | Sort-Object X)
            $x1 = ($parts | Measure-Object X -Minimum).Minimum
            $x2 = ($parts | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
            [pscustomobject]@{
                Text = ($parts | ForEach-Object Text) -join ''
                X = $x1; Y = ($parts | Measure-Object Y -Minimum).Minimum; W = $x2 - $x1
                H = ($parts | Measure-Object H -Maximum).Maximum; CX = ($x1 + $x2) / 2
            }
        }

        $level = $null; $xp = $null; $next = $null; $used = @()
        foreach ($w in $mine) {
            $n = ConvertTo-GameNumber $w.Text
            if ($null -eq $n) { continue }
            if ($w.Text -match '(?i)xp$')                     { if ($null -eq $next) { $next = $n; $used += $w } }
            elseif ($null -eq $level -and $w.Text -notmatch '[,/]' -and $n -le 300) { $level = $n; $used += $w }
            elseif ($null -ne $level -and $null -eq $xp)      { $xp = $n; $used += $w }
        }
        if ($null -eq $level) { continue }
        if ($null -ne $xp -and $null -ne $next -and $xp -gt $next) { $xp = $null }   # misread, don't trust it
        $progress[$role] = [pscustomobject]@{ Level = $level; Xp = $xp; NextXp = $next }
        $usedLabels += $label

        foreach ($w in @($label) + $used) {
            $r = New-Object System.Drawing.RectangleF ([float]$w.X), ([float]$w.Y), ([float]$w.W), ([float]$w.H)
            $script:PanelBounds = if ($script:PanelBounds) { [System.Drawing.RectangleF]::Union($script:PanelBounds, $r) } else { $r }
        }
    }

    # The panel is a 3 x 2 grid of roles. Measure its column and row spacing from the labels that
    # were read (or estimate it), so a box around a partial read can be widened to the whole grid.
    if ($usedLabels.Count) {
        $maxW = ($usedLabels | Measure-Object W -Maximum).Maximum
        $maxH = ($usedLabels | Measure-Object H -Maximum).Maximum
        $gap = {
            param($values, $minGap)
            $v = @($values | Sort-Object); $d = @()
            for ($i = 1; $i -lt $v.Count; $i++) { if ($v[$i] - $v[$i - 1] -gt $minGap) { $d += $v[$i] - $v[$i - 1] } }
            if ($d.Count) { ($d | Measure-Object -Minimum).Minimum } else { $null }
        }
        $col = & $gap ($usedLabels | ForEach-Object CX) ($maxW * 0.8)
        $row = & $gap ($usedLabels | ForEach-Object Y) ($maxH * 2)
        $script:PanelGrid = @{
            Col = if ($col) { $col } else { 2.4 * $maxW }
            Row = if ($row) { $row } else { 1.1 * $script:PanelBounds.Height }
        }
    }
    $progress
}

function Read-GameProgress([string]$ImagePath) {
    $bmp = if ($ImagePath) { [System.Drawing.Bitmap]::FromFile((Resolve-Path $ImagePath)) } else { Get-GameScreenshot }
    try { Get-RoleProgress @(Read-OcrWords $bmp) } finally { $bmp.Dispose() }
}
