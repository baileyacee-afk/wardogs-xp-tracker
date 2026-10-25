# Match XP bookkeeping for the Wardogs XP Tracker. No UI in here, so it can be tested on its own.
#
# The end-of-match bonus is per role (class): each role gets one tier per 500 XP it earns in the
# match, up to 5 tiers (2,500 XP), paid out at a fixed amount per tier that depends on placement
# (seen: 700 per tier for 2nd place; 1st/3rd are believed to be 800/600). It lands silently after
# the match, so it is deduced: XP after the match minus XP just before it ended.
#
# Two sources feed a role's XP this match:
#   - Wardog Level reads (exact totals; the source of truth whenever one comes in), and
#   - popups (live XP/cash events between reads; reset to the read's total when a read arrives).
#
# Dot-source, then: Initialize-Tracker <dataDir>; Add-Read <progress>; Add-PopupEvent ...;
# Request-EndMatch; (the next read files the match) or Complete-Match -NoFinalRead.

$MatchCap  = 2500
$TierSize  = 500
$TierCount = $MatchCap / $TierSize
$RoleOrder = 'infantry', 'medic', 'support', 'recon', 'driver', 'pilot'
$MinRoles  = 4   # a read needs at least this many roles; OCR occasionally misses one
$MaxJump   = 15000   # a role can't really gain more than this between two reads
$ConfirmReads = 3    # identical reads needed before an unusual change is believed
$RoleNames = @{ infantry = 'Assault'; medic = 'Medic'; support = 'Support'; recon = 'Recon'; driver = 'Driver'; pilot = 'Pilot' }
$Placements = @{ 800 = '1st place'; 700 = '2nd place'; 600 = '3rd place' }   # bonus XP per tier

# ConvertFrom-Json gives PSCustomObjects; turn them back into hashtables.
function ConvertTo-Hashtable($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($Object -is [array]) { return , @($Object | ForEach-Object { ConvertTo-Hashtable $_ }) }
    $Object
}

function New-MatchState {
    [ordered]@{
        Start    = (Get-Date).ToString('o')
        Base     = $null          # XP per role when the match started
        Last     = [ordered]@{}   # latest accepted Wardog Level XP per role
        Levels   = [ordered]@{}
        BaseLevels = [ordered]@{} # level per role when the match started
        Next     = [ordered]@{}   # XP needed for the next level, per role
        Tiers    = [ordered]@{}   # highest bonus tier already announced, per role
        Active   = $null          # the role that most recently gained XP (the one you're playing)
        LastRead = $null
        # popups
        Events   = @()            # every XP/cash popup: Id, T, Kind, Amount, Reason, Role, Uncertain
        NextEventId = 1
        PopupXp  = [ordered]@{}   # popup XP per role over the whole match
        PopupSinceRead = [ordered]@{}   # popup XP per role since that role's last Wardog Level read
        UnknownXp = 0             # popup XP whose class couldn't be told
        Cash     = 0              # sum of cash popups (earnings and small costs; not gear bought)
        BankStart = $null         # banked cash when the first life read this match began
        BankNow  = $null          # latest banked cash read; BankNow - BankStart is the match's net cash
        CashUncertain = 0         # cash popups whose "$" was misread
        Unparsed = 0              # popup reads that couldn't be parsed
        LiveGapSeconds = 0        # time this match with continuous mode off or the game not found
        # end of match
        EndRequested = $null
        EndXp    = $null          # estimated XP per role at the moment the match ended
        EndGains = $null          # match XP per role at that moment (before the bonus)
        ResultsCash = $null       # match cash from the results screen, if it was seen
    }
}

function Initialize-Tracker([string]$DataDir) {
    $script:DataDir = $DataDir
    New-Item -ItemType Directory -Force -Path $DataDir, (Join-Path $DataDir 'matches') | Out-Null
    $script:State   = New-MatchState
    $script:History = @()
    $script:Pending = @{}
    $script:LastSave = [datetime]::MinValue
    $script:SaveDue = $false
    try {
        if (Test-Path "$DataDir\match.json") {
            $saved = ConvertTo-Hashtable (Get-Content "$DataDir\match.json" -Raw | ConvertFrom-Json)
            foreach ($k in @($script:State.Keys)) { if ($null -ne $saved[$k]) { $script:State[$k] = $saved[$k] } }
            $script:State.Events = @($script:State.Events)
        }
    } catch {}
    try {
        if (Test-Path "$DataDir\history.json") {
            # Assigning first, then piping, unrolls the JSON array (PS 5.1 emits it as one object).
            $raw = Get-Content "$DataDir\history.json" -Raw | ConvertFrom-Json
            $script:History = @($raw | Where-Object { $_ } | ForEach-Object { ConvertTo-Hashtable $_ })
        }
    } catch {}
}

function Save-Tracker {
    try {
        ConvertTo-Json -InputObject $script:State -Depth 6 | Set-Content "$script:DataDir\match.json" -Encoding utf8 -ErrorAction Stop
        ConvertTo-Json -InputObject @($script:History) -Depth 6 | Set-Content "$script:DataDir\history.json" -Encoding utf8 -ErrorAction Stop
        $script:LastSave = Get-Date
        $script:SaveDue = $false
    } catch { $script:SaveDue = $true }   # file busy (another program has it open): try again shortly
}

# Popups can arrive several times a second; write the files at most every few seconds.
function Save-TrackerSoon {
    if (((Get-Date) - $script:LastSave).TotalSeconds -ge 3) { Save-Tracker } else { $script:SaveDue = $true }
}
function Save-TrackerIfDue { if ($script:SaveDue) { Save-Tracker } }

# XP earned this match, per role: from Wardog Level reads, plus popups since each role's last read.
function Get-RoleGains {
    $gains = [ordered]@{}
    foreach ($r in $RoleOrder) {
        $base = if ($script:State.Base) { $script:State.Base[$r] } else { $null }
        $last = $script:State.Last[$r]
        # Never below 0: XP doesn't go down within a match, so a negative would only be a bad read.
        $read = if ($null -ne $base -and $null -ne $last) { [long][Math]::Max(0, [long]$last - [long]$base) } else { [long]0 }
        $gains[$r] = $read + [long]$script:State.PopupSinceRead[$r]
    }
    $gains
}

function Get-Tier([long]$Xp) { [int][Math]::Min($TierCount, [Math]::Floor($Xp / $TierSize)) }

# Wardog level = the six role levels added up (what the game shows on the Wardog Level screen).
# $null until every role's level has been read.
function Get-WardogLevel {
    $known = @($RoleOrder | Where-Object { $null -ne $script:State.Levels[$_] })
    if ($known.Count -lt $RoleOrder.Count) { return $null }
    [int]($known | ForEach-Object { [int]$script:State.Levels[$_] } | Measure-Object -Sum).Sum
}

# Levels gained this match, across all roles.
function Get-LevelsGained {
    [int](@($RoleOrder | ForEach-Object {
        $now = $script:State.Levels[$_]; $start = $script:State.BaseLevels[$_]
        if ($null -ne $now -and $null -ne $start) { [Math]::Max(0, [int]$now - [int]$start) } else { 0 }
    }) | Measure-Object -Sum).Sum
}

# The role to feature: the one that last gained XP, else the one with the most this match.
function Get-ActiveRole {
    if ($script:State.Active) { return $script:State.Active }
    $gains = Get-RoleGains
    $best = $RoleOrder | Sort-Object { -$gains[$_] } | Select-Object -First 1
    if ($gains[$best] -gt 0) { $best } else { $null }
}

# Tiers reached since they were last announced (not after the match ended: the bonus would trip them).
function Get-NewTiers {
    if ($script:State.EndRequested) { return @() }
    $newTiers = @()
    $gains = Get-RoleGains
    foreach ($r in $RoleOrder) {
        $tier = Get-Tier $gains[$r]
        $had = if ($null -ne $script:State.Tiers[$r]) { [int]$script:State.Tiers[$r] } else { 0 }
        if ($tier -gt $had) { $newTiers += @{ Role = $r; Tier = $tier }; $script:State.Tiers[$r] = $tier }
    }
    $newTiers
}

# Applies one read of the Wardog Level panel.
# Returns @{ Accepted; Note; NewTiers; Filed } - Filed is the history entry when this read finished a match.
# A role's level from a read; OCR sometimes can't read it (the icon above it confuses it), and then
# the last known level stands.
function Get-ReadLevel($Progress, [string]$Role) {
    if ($null -ne $Progress[$Role].Level) { $Progress[$Role].Level } else { $script:State.Levels[$Role] }
}

function Add-Read($Progress) {
    # Roles whose XP was read this time. Usually all six; a role OCR couldn't read keeps its last value.
    $xp = [ordered]@{}
    foreach ($r in $RoleOrder) { if ($Progress.Contains($r) -and $null -ne $Progress[$r].Xp) { $xp[$r] = [long]$Progress[$r].Xp } }
    if ($xp.Count -lt $MinRoles) { return @{ Accepted = $false; Note = "only read $($xp.Count) of 6 roles" } }

    # Misread protection, per role, so one bad number doesn't block the other roles.
    # - In a match, a role's XP or level can't really drop, and a big drop is always a misread: never taken.
    # - A small drop or a big jump is taken only after $ConfirmReads identical reads in a row; that's how a
    #   value is corrected after an earlier misread slipped through.
    $notes = @(); $corrected = @()
    foreach ($r in @($xp.Keys)) {
        $prev = $script:State.Last[$r]
        if ($null -eq $prev) { continue }
        $delta = $xp[$r] - $prev
        $inMatch = $script:State.Base -and $null -ne $script:State.Base[$r]
        $prevLv = $script:State.Levels[$r]
        $levelDrop = $null -ne $prevLv -and $null -ne $Progress[$r].Level -and $Progress[$r].Level -lt $prevLv
        if ($inMatch -and ($delta -lt -$MaxJump -or $levelDrop)) {
            $xp.Remove($r); $script:Pending.Remove($r); $notes += "$r rejected ($prev -> $($Progress[$r].Xp))"
            continue
        }
        if ($delta -lt 0 -or $delta -gt $MaxJump) {
            $p = $script:Pending[$r]
            $script:Pending[$r] = if ($p -and $p.Value -eq $xp[$r]) { @{ Value = $xp[$r]; Count = $p.Count + 1 } } else { @{ Value = $xp[$r]; Count = 1 } }
            if ($script:Pending[$r].Count -lt $ConfirmReads) { $xp.Remove($r); $notes += "$r held ($prev -> $($Progress[$r].Xp))"; continue }
            $corrected += $r
        }
        $script:Pending.Remove($r)
    }
    if (-not $xp.Count) { return @{ Accepted = $false; Note = $notes -join '; ' } }

    # Starting XP is saved per role the first time each role is read this match; popups counted before
    # that read are already in its total, so they're taken back out of the start.
    if (-not $script:State.Base) { $script:State.Base = [ordered]@{} }
    $fresh = @($xp.Keys | Where-Object { $null -eq $script:State.Base[$_] })
    foreach ($r in $fresh) {
        $script:State.Base[$r] = $xp[$r] - [long]$script:State.PopupSinceRead[$r]
        $script:State.BaseLevels[$r] = Get-ReadLevel $Progress $r
    }

    # Whichever role gained the most since the last read is the one being played.
    $bestDelta = 0
    foreach ($r in $xp.Keys) {
        $prev = $script:State.Last[$r]
        if ($fresh -notcontains $r -and $corrected -notcontains $r -and $null -ne $prev -and $xp[$r] - $prev -gt $bestDelta) { $bestDelta = $xp[$r] - $prev; $script:State.Active = $r }
        $script:State.Last[$r]   = $xp[$r]
        $script:State.Levels[$r] = Get-ReadLevel $Progress $r
        if ($null -ne $Progress[$r].NextXp) { $script:State.Next[$r] = [long]$Progress[$r].NextXp }
        $script:State.PopupSinceRead[$r] = 0   # the read is the truth; popups count on from here
    }
    $script:State.LastRead = (Get-Date).ToString('o')

    if ($script:State.EndRequested) {
        $entry = Complete-Match
        return @{ Accepted = $true; NewTiers = @(); Note = $notes -join '; '; Filed = $entry }
    }
    $newTiers = Get-NewTiers
    Save-Tracker
    @{ Accepted = $true; NewTiers = $newTiers; Note = $notes -join '; ' }
}

# One XP or cash popup. Returns @{ Event; NewTiers }.
function Add-PopupEvent([string]$Kind, [long]$Amount, [string]$Reason, [string]$Role, [bool]$Uncertain) {
    $s = $script:State
    $e = [ordered]@{ Id = [int]$s.NextEventId; T = (Get-Date).ToString('o'); Kind = $Kind; Amount = $Amount; Reason = $Reason; Role = $Role; Uncertain = $Uncertain }
    $s.NextEventId = [int]$s.NextEventId + 1
    $s.Events = @($s.Events) + @($e)
    Add-EventTotals $e 1
    if ($Kind -eq 'xp' -and $Role) { $s.Active = $Role }
    $tiers = Get-NewTiers
    Save-TrackerSoon
    @{ Event = $e; NewTiers = $tiers }
}

function Add-EventTotals($E, [int]$Sign) {
    $s = $script:State
    $amt = [long]$E.Amount * $Sign
    if ($E.Kind -eq 'xp') {
        if ($E.Role) {
            $s.PopupXp[$E.Role] = [long]$s.PopupXp[$E.Role] + $amt
            $s.PopupSinceRead[$E.Role] = [long]$s.PopupSinceRead[$E.Role] + $amt
        } else { $s.UnknownXp = [long]$s.UnknownXp + $amt }
    } else {
        $s.Cash = [long]$s.Cash + $amt
        if ($E.Uncertain) { $s.CashUncertain = [int]$s.CashUncertain + $Sign }
    }
}

# A popup's amount was corrected by later readings of the same row.
function Update-PopupEvent([int]$Id, [long]$Amount, [bool]$Uncertain) {
    $e = @($script:State.Events) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $e) { return @() }
    Add-EventTotals $e -1
    $e.Amount = $Amount; $e.Uncertain = $Uncertain
    Add-EventTotals $e 1
    $tiers = Get-NewTiers
    Save-TrackerSoon
    $tiers
}

function Add-UnparsedRead { $script:State.Unparsed = [int]$script:State.Unparsed + 1 }
function Add-LiveGap([double]$Seconds) { $script:State.LiveGapSeconds = [double]$script:State.LiveGapSeconds + $Seconds }

# True once anything has happened this match (so an empty match isn't filed).
function Test-MatchActive { [bool]($script:State.Base -or @($script:State.Events).Count) }

# Marks the match as over. The next Wardog Level read files it with the deduced bonus.
function Request-EndMatch {
    $s = $script:State
    if ($s.EndRequested) { return $false }
    $s.EndRequested = (Get-Date).ToString('o')
    $s.EndGains = Get-RoleGains
    $s.EndXp = [ordered]@{}
    foreach ($r in $RoleOrder) { if ($null -ne $s.Last[$r]) { $s.EndXp[$r] = [long]$s.Last[$r] + [long]$s.PopupSinceRead[$r] } }
    Save-Tracker
    $true
}

function Set-ResultsCash([long]$Amount) { $script:State.ResultsCash = $Amount; Save-TrackerSoon }

# A confirmed read of the cash at the top right. $LifeStart is the banked cash when this life began
# (banked - this life's cash), so gear bought before the first read still counts against the match.
function Set-BankRead([long]$Banked, [long]$LifeStart) {
    if ($null -eq $script:State.BankStart) { $script:State.BankStart = $LifeStart }
    if ($script:State.BankNow -eq $Banked) { return $false }
    $script:State.BankNow = $Banked
    Save-TrackerSoon
    $true
}

# The match's net cash: banked cash change (includes gear bought), or the popup sum until the
# banked cash has been read.
function Get-MatchCash($S = $script:State) {
    if ($null -ne $S.BankStart -and $null -ne $S.BankNow) { [long]$S.BankNow - [long]$S.BankStart } else { [long]$S.Cash }
}

# Files the match into history with its breakdown and starts the next one.
# The bonus per role = XP after the match (this read) - XP when it ended (last read + popups since).
function Complete-Match([switch]$NoFinalRead) {
    $s = $script:State
    $gains = if ($s.EndGains) { $s.EndGains } else { Get-RoleGains }
    $roles = [ordered]@{}; $bonus = [ordered]@{}; $popup = [ordered]@{}
    foreach ($r in $RoleOrder) {
        if ([long]$gains[$r] -gt 0) { $roles[$r] = [long]$gains[$r] }
        if ([long]$s.PopupXp[$r] -ne 0) { $popup[$r] = [long]$s.PopupXp[$r] }
        if (-not $NoFinalRead -and $s.EndXp -and $null -ne $s.EndXp[$r] -and $null -ne $s.Last[$r]) {
            $bonus[$r] = [long]$s.Last[$r] - [long]$s.EndXp[$r]
        }
    }
    $bonusTotal = if ($bonus.Count) { [long](@($bonus.Values) | Measure-Object -Sum).Sum } else { $null }

    # Placement: the bonus is a fixed XP per tier, so total bonus / total tiers gives the payout.
    $payout = $null; $placement = $null; $consistent = $null
    $tiers = 0; foreach ($r in $bonus.Keys) { $tiers += Get-Tier ([long]$gains[$r]) }
    if ($tiers -gt 0 -and $null -ne $bonusTotal) {
        $payout = [int]([Math]::Round($bonusTotal / $tiers / 100.0) * 100)
        $consistent = $true
        foreach ($r in $bonus.Keys) { if ([Math]::Abs($bonus[$r] - (Get-Tier ([long]$gains[$r])) * $payout) -gt 50) { $consistent = $false } }
        $placement = $Placements[$payout]
    }

    $warnings = @()
    if ($NoFinalRead) { $warnings += "There was no Wardog Level read after the match, so the end-of-match bonus couldn't be deduced." }
    if ([int]$s.Unparsed -gt 0) { $warnings += "$($s.Unparsed) popup reads couldn't be understood. A missed popup would show up as extra bonus." }
    if ([double]$s.LiveGapSeconds -ge 30) { $warnings += "Popup tracking was off or the game wasn't detected for about $([Math]::Max(1, [int]([double]$s.LiveGapSeconds / 60))) min of this match." }
    if ([long]$s.UnknownXp -gt 0) { $warnings += "$($s.UnknownXp) popup XP couldn't be matched to a class." }
    if ([int]$s.CashUncertain -gt 0) { $warnings += "$($s.CashUncertain) cash amounts were uncertain (the `$ sign was misread)." }
    if ($consistent -eq $false) { $warnings += "The deduced bonus isn't a clean multiple of $payout XP per tier for every class, so something was probably missed." }
    foreach ($r in $bonus.Keys) { if ($bonus[$r] -lt 0) { $warnings += "$($RoleNames[$r])'s deduced bonus is negative, so a popup was likely miscounted." } }

    $stamp = ([datetime]::Parse($s.Start)).ToString('yyyyMMdd-HHmmss')
    $eventsFile = "matches\$stamp.json"
    ConvertTo-Json -InputObject @($s.Events) -Depth 4 | Set-Content (Join-Path $script:DataDir $eventsFile) -Encoding utf8

    $total = [long](@($roles.Values) | Measure-Object -Sum).Sum + [long]$(if ($null -ne $bonusTotal) { $bonusTotal } else { 0 })
    $entry = [ordered]@{
        Start = $s.Start; End = $(if ($s.EndRequested) { $s.EndRequested } else { (Get-Date).ToString('o') })
        Xp = $total; Roles = $roles; PopupXp = $popup; Bonus = $bonus; BonusTotal = $bonusTotal
        Payout = $payout; Placement = $placement; Cash = [long]$s.Cash; ResultsCash = $s.ResultsCash
        NetCash = $(if ($null -ne $s.BankStart -and $null -ne $s.BankNow) { Get-MatchCash $s } else { $null })
        EventCount = @($s.Events).Count; Unparsed = [int]$s.Unparsed; Warnings = $warnings; EventsFile = $eventsFile
        Snapshot = $(if (Test-Path (Join-Path $script:DataDir "matches\$stamp.png")) { "matches\$stamp.png" } else { $null })
    }
    if ($total -gt 0 -or @($s.Events).Count) { $script:History = @(@($entry) + @($script:History) | Select-Object -First 100) }

    # Next match starts from here. After a final read that XP already includes the bonus.
    $previous = $s
    $script:State = New-MatchState
    $script:State.Last   = $previous.Last
    $script:State.Levels = $previous.Levels
    $script:State.Next   = $previous.Next
    $script:State.LastRead = $previous.LastRead
    if (-not $NoFinalRead -and $previous.Last.Count) {
        $script:State.Base = [ordered]@{}; foreach ($r in $previous.Last.Keys) { $script:State.Base[$r] = $previous.Last[$r] }
        $script:State.BaseLevels = [ordered]@{}; foreach ($r in $previous.Levels.Keys) { $script:State.BaseLevels[$r] = $previous.Levels[$r] }
    }
    $script:Pending = @{}
    Save-Tracker
    $entry
}

# Loads a filed match's full event list.
function Get-MatchEvents($Entry) {
    if (-not $Entry.EventsFile) { return @() }
    $path = Join-Path $script:DataDir $Entry.EventsFile
    if (-not (Test-Path $path)) { return @() }
    $raw = Get-Content $path -Raw | ConvertFrom-Json
    @($raw | Where-Object { $_ } | ForEach-Object { ConvertTo-Hashtable $_ })
}
