# Match XP bookkeeping for the Wardogs XP Tracker. No UI in here, so it can be tested on its own.
#
# The end-of-match bonus is per role (class): each role gets one tier per 500 XP it earns in the
# match, up to 5 tiers (2,500 XP). A role's match XP = its XP now - its XP when the match started.
#
# Dot-source, then: Initialize-Tracker <dataDir>; Add-Read <progress from GameReader>; Start-NextMatch

$MatchCap  = 2500
$TierSize  = 500
$TierCount = $MatchCap / $TierSize
$RoleOrder = 'infantry', 'medic', 'support', 'recon', 'driver', 'pilot'
$MinRoles  = 4   # a read needs at least this many roles; OCR occasionally misses one
$MaxJump   = 15000   # a role can't really gain more than this between two reads
$ConfirmReads = 3    # identical reads needed before an unusual change is believed
$RoleNames = @{ infantry = 'Assault'; medic = 'Medic'; support = 'Support'; recon = 'Recon'; driver = 'Driver'; pilot = 'Pilot' }

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
        Base     = $null          # XP per role when the match started (set by the first read)
        Last     = [ordered]@{}   # latest accepted XP per role
        Levels   = [ordered]@{}
        BaseLevels = [ordered]@{} # level per role when the match started
        Next     = [ordered]@{}   # XP needed for the next level, per role
        Tiers    = [ordered]@{}   # highest bonus tier already announced, per role
        Active   = $null          # the role that most recently gained XP (the one you're playing)
        LastRead = $null
    }
}

function Initialize-Tracker([string]$DataDir) {
    $script:DataDir = $DataDir
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $script:State   = New-MatchState
    $script:History = @()
    $script:Pending = @{}
    try {
        if (Test-Path "$DataDir\match.json") {
            $saved = ConvertTo-Hashtable (Get-Content "$DataDir\match.json" -Raw | ConvertFrom-Json)
            foreach ($k in @($script:State.Keys)) { if ($null -ne $saved[$k]) { $script:State[$k] = $saved[$k] } }
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
    ConvertTo-Json -InputObject $script:State -Depth 5 | Set-Content "$script:DataDir\match.json" -Encoding utf8
    ConvertTo-Json -InputObject @($script:History) -Depth 5 | Set-Content "$script:DataDir\history.json" -Encoding utf8
}

# XP earned this match, per role.
function Get-RoleGains {
    $gains = [ordered]@{}
    foreach ($r in $RoleOrder) {
        $base = if ($script:State.Base) { $script:State.Base[$r] } else { $null }
        $last = $script:State.Last[$r]
        # Never below 0: XP doesn't go down within a match, so a negative would only be a bad read.
        $gains[$r] = if ($null -ne $base -and $null -ne $last) { [long][Math]::Max(0, [long]$last - [long]$base) } else { [long]0 }
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

# Applies one read of the Wardog Level panel.
# Returns @{ Accepted; Note; NewTiers } where NewTiers lists @{ Role; Tier } for tiers just reached.
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
        $levelDrop = $null -ne $prevLv -and $Progress[$r].Level -lt $prevLv
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

    # Starting XP is saved per role, the first time each role is read this match.
    if (-not $script:State.Base) { $script:State.Base = [ordered]@{} }
    $fresh = @($xp.Keys | Where-Object { $null -eq $script:State.Base[$_] })
    foreach ($r in $fresh) { $script:State.Base[$r] = $xp[$r]; $script:State.BaseLevels[$r] = $Progress[$r].Level }

    # Whichever role gained the most since the last read is the one being played.
    $bestDelta = 0
    foreach ($r in $xp.Keys) {
        $prev = $script:State.Last[$r]
        if ($fresh -notcontains $r -and $corrected -notcontains $r -and $null -ne $prev -and $xp[$r] - $prev -gt $bestDelta) { $bestDelta = $xp[$r] - $prev; $script:State.Active = $r }
        $script:State.Last[$r]   = $xp[$r]
        $script:State.Levels[$r] = $Progress[$r].Level
        if ($null -ne $Progress[$r].NextXp) { $script:State.Next[$r] = [long]$Progress[$r].NextXp }
    }
    $script:State.LastRead = (Get-Date).ToString('o')

    $newTiers = @()
    $gains = Get-RoleGains
    foreach ($r in $RoleOrder) {
        $tier = Get-Tier $gains[$r]
        $had = if ($null -ne $script:State.Tiers[$r]) { [int]$script:State.Tiers[$r] } else { 0 }
        if ($tier -gt $had) { $newTiers += @{ Role = $r; Tier = $tier }; $script:State.Tiers[$r] = $tier }
    }
    Save-Tracker
    @{ Accepted = $true; NewTiers = $newTiers; Note = $notes -join '; ' }
}

# Files the current match into history (if it earned anything) and starts a fresh one.
function Start-NextMatch {
    $gains = Get-RoleGains
    $total = [long]($gains.Values | Measure-Object -Sum).Sum
    if ($script:State.Base -and $total -gt 0) {
        $roles = [ordered]@{}
        foreach ($r in $RoleOrder) { if ($gains[$r] -gt 0) { $roles[$r] = $gains[$r] } }
        $entry = [ordered]@{ Start = $script:State.Start; End = (Get-Date).ToString('o'); Xp = $total; Roles = $roles }
        $script:History = @(@($entry) + @($script:History) | Select-Object -First 100)
    }
    $previous = $script:State
    $script:State = New-MatchState
    # Keep the latest numbers so the role list stays filled in and misread checks keep working.
    $script:State.Last   = $previous.Last
    $script:State.Levels = $previous.Levels
    $script:State.Next   = $previous.Next
    $script:Pending = @{}
    Save-Tracker
}
