<#
.SYNOPSIS
Antigravity Image Quota Tracker - Cross-platform Hook & CLI (Windows PowerShell 5.1+)

Tracks built-in image generation usage across rolling time windows using official
Gemini image resolution tiers (512=0.67u, 1K=1.0u, 2K=1.5u, 4K=2.25u), counts
multi-round subagent refinements, auto-calibrates on rate-limit errors, and
emits inline user-only status notices via PreInvocation/PostInvocation hooks.
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RestArgs
)

$ErrorActionPreference = "Stop"
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# ---------------------------------------------------------------------------
# Paths & State Helpers
# ---------------------------------------------------------------------------

function Get-DataDir {
    $candidates = @()
    if ($env:IMAGE_QUOTA_DATA_DIR) { $candidates += $env:IMAGE_QUOTA_DATA_DIR }
    if ($env:PLUGIN_DATA) { $candidates += $env:PLUGIN_DATA }
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) ".data")
    $candidates += (Join-Path (Join-Path (Join-Path $HOME ".gemini") "antigravity") "image-quota-tracker")

    foreach ($dir in $candidates) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $probe = Join-Path $dir ".write_probe_$PID"
            [System.IO.File]::WriteAllText($probe, "ok")
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $dir
        } catch {
            continue
        }
    }
    throw "No writable data directory available for image-quota-tracker."
}

function Get-StatePath {
    return (Join-Path (Get-DataDir) "quota-state.json")
}

function Write-DebugLog([string]$Message) {
    if ($env:IMAGE_QUOTA_DEBUG -eq "1") {
        try {
            $logPath = Join-Path (Get-DataDir) "debug.log"
            $ts = [DateTimeOffset]::UtcNow.ToString("o")
            [System.IO.File]::AppendAllText($logPath, "[$ts] $Message`n", [System.Text.Encoding]::UTF8)
        } catch {}
    }
}

function New-DefaultState {
    return [ordered]@{
        version = 1
        config = [ordered]@{
            windowHours = 5.0
            accountingMode = "weighted"          # "weighted" | "count"
            estimatedLimitUnits = 10.0           # 1K-equivalent units per window
            estimatedLimitCount = 10             # raw image count per window
            warnThresholdUnits = 2.0
            confirmBeforeLowQuota = $false
            autoCalibrate = $true
            showInlineNotice = $true
        }
        calibration = [ordered]@{
            samples = @()
            lastRateLimitAt = $null
            activeCooldownUntil = $null
            detectedModel = $null
        }
        pendingSubagents = @()
        events = @()
    }
}

function ConvertTo-OrderedDict($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $Obj.Keys) { $out[$k] = ConvertTo-OrderedDict $Obj[$k] }
        return $out
    }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) {
            $out[$p.Name] = ConvertTo-OrderedDict $p.Value
        }
        return $out
    }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $Obj) { [void]$arr.Add((ConvertTo-OrderedDict $item)) }
        return ,$arr.ToArray()
    }
    return $Obj
}

function Read-State {
    $path = Get-StatePath
    $def = New-DefaultState
    if (-not (Test-Path -LiteralPath $path)) {
        return $def
    }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $def }
        $parsed = ConvertTo-OrderedDict ($raw | ConvertFrom-Json)
        if (-not $parsed.Contains("config")) { $parsed["config"] = $def["config"] }
        foreach ($k in $def["config"].Keys) {
            if (-not $parsed["config"].Contains($k)) { $parsed["config"][$k] = $def["config"][$k] }
        }
        if (-not $parsed.Contains("calibration")) { $parsed["calibration"] = $def["calibration"] }
        foreach ($k in $def["calibration"].Keys) {
            if (-not $parsed["calibration"].Contains($k)) { $parsed["calibration"][$k] = $def["calibration"][$k] }
        }
        if (-not $parsed.Contains("pendingSubagents") -or $null -eq $parsed["pendingSubagents"]) {
            $parsed["pendingSubagents"] = @()
        }
        if (-not $parsed.Contains("events") -or $null -eq $parsed["events"]) {
            $parsed["events"] = @()
        }
        return $parsed
    } catch {
        Write-DebugLog "Read-State failed: $($_.Exception.Message)"
        return $def
    }
}

function Save-State($State) {
    $path = Get-StatePath
    $tmp = "$path.tmp.$PID"
    # Keep at most 500 recent events and 50 calibration samples
    if ($State["events"].Count -gt 500) {
        $State["events"] = @($State["events"] | Select-Object -Last 500)
    }
    if ($State["calibration"]["samples"].Count -gt 50) {
        $State["calibration"]["samples"] = @($State["calibration"]["samples"] | Select-Object -Last 50)
    }
    $json = $State | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ---------------------------------------------------------------------------
# Binary Image Header Dimension Reader (Zero Dependencies)
# ---------------------------------------------------------------------------

function Get-ImageDimensions([string]$FilePath) {
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $null }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $null }
    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $maxRead = [Math]::Min([int]$fs.Length, 65536)
            if ($maxRead -lt 24) { return $null }
            $b = New-Object byte[] $maxRead
            $read = $fs.Read($b, 0, $maxRead)
            if ($read -lt 24) { return $null }

            # PNG: 89 50 4E 47 0D 0A 1A 0A
            if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47 -and
                $b[4] -eq 0x0D -and $b[5] -eq 0x0A -and $b[6] -eq 0x1A -and $b[7] -eq 0x0A) {
                $w = ([uint32]$b[16] -shl 24) -bor ([uint32]$b[17] -shl 16) -bor ([uint32]$b[18] -shl 8) -bor [uint32]$b[19]
                $h = ([uint32]$b[20] -shl 24) -bor ([uint32]$b[21] -shl 16) -bor ([uint32]$b[22] -shl 8) -bor [uint32]$b[23]
                if ($w -gt 0 -and $h -gt 0) { return @{ width = [int]$w; height = [int]$h } }
            }

            # WebP: RIFF....WEBP
            if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46 -and
                $b[8] -eq 0x57 -and $b[9] -eq 0x45 -and $b[10] -eq 0x42 -and $b[11] -eq 0x50) {
                $chunk = [System.Text.Encoding]::ASCII.GetString($b, 12, 4)
                if ($chunk -eq "VP8X" -and $read -ge 30) {
                    $w = 1 + ([int]$b[24] -bor ([int]$b[25] -shl 8) -bor ([int]$b[26] -shl 16))
                    $h = 1 + ([int]$b[27] -bor ([int]$b[28] -shl 8) -bor ([int]$b[29] -shl 16))
                    return @{ width = $w; height = $h }
                } elseif ($chunk -eq "VP8L" -and $read -ge 25) {
                    $bits = [uint32]$b[21] -bor ([uint32]$b[22] -shl 8) -bor ([uint32]$b[23] -shl 16) -bor ([uint32]$b[24] -shl 24)
                    $w = 1 + [int]($bits -band 0x3FFF)
                    $h = 1 + [int](($bits -shr 14) -band 0x3FFF)
                    return @{ width = $w; height = $h }
                } elseif ($chunk -eq "VP8 " -and $read -ge 30) {
                    if ($b[23] -eq 0x9D -and $b[24] -eq 0x01 -and $b[25] -eq 0x2A) {
                        $w = ([int]$b[26] -bor ([int]$b[27] -shl 8)) -band 0x3FFF
                        $h = ([int]$b[28] -bor ([int]$b[29] -shl 8)) -band 0x3FFF
                        return @{ width = $w; height = $h }
                    }
                }
            }

            # JPEG: FF D8
            if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8) {
                $pos = 2
                $sofMarkers = @(0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF)
                while ($pos + 9 -lt $read) {
                    if ($b[$pos] -ne 0xFF) { $pos++; continue }
                    while ($pos -lt $read -and $b[$pos] -eq 0xFF) { $pos++ }
                    if ($pos -ge $read) { break }
                    $marker = $b[$pos]; $pos++
                    if ($marker -eq 0xD9 -or $marker -eq 0xDA) { break }
                    if ($marker -eq 0x01 -or ($marker -ge 0xD0 -and $marker -le 0xD7)) { continue }
                    if ($pos + 2 -gt $read) { break }
                    $segLen = ([int]$b[$pos] -shl 8) -bor [int]$b[$pos + 1]
                    if ($segLen -lt 2) { break }
                    if ($sofMarkers -contains $marker -and ($pos + 7) -lt $read) {
                        $h = ([int]$b[$pos + 3] -shl 8) -bor [int]$b[$pos + 4]
                        $w = ([int]$b[$pos + 5] -shl 8) -bor [int]$b[$pos + 6]
                        if ($w -gt 0 -and $h -gt 0) { return @{ width = $w; height = $h } }
                    }
                    $pos += $segLen
                }
            }
        } finally {
            $fs.Dispose()
        }
    } catch {
        Write-DebugLog "Get-ImageDimensions failed for ${FilePath}: $($_.Exception.Message)"
    }
    return $null
}

# Official gemini-3.1-flash-image token tiers:
#   512 -> 747 tokens (0.67x)
#   1K  -> 1120 tokens (1.00x)
#   2K  -> 1680 tokens (1.50x)
#   4K  -> 2520 tokens (2.25x)
# Using geometric mean sqrt(w*h) handles all aspect ratios (1:1, 16:9, 4:1, etc.) accurately.
function Get-ResolutionTier($Dims) {
    if ($null -eq $Dims -or $Dims.width -le 0 -or $Dims.height -le 0) {
        return [ordered]@{
            tier = "1K*"
            weight = 1.0
            tokens = 1120
            width = 0
            height = 0
            estimated = $true
        }
    }
    $equiv = [Math]::Sqrt([double]$Dims.width * [double]$Dims.height)
    if ($equiv -le 768.0) {
        return [ordered]@{ tier = "512"; weight = 0.67; tokens = 747; width = $Dims.width; height = $Dims.height; estimated = $false }
    } elseif ($equiv -le 1536.0) {
        return [ordered]@{ tier = "1K"; weight = 1.0; tokens = 1120; width = $Dims.width; height = $Dims.height; estimated = $false }
    } elseif ($equiv -le 3072.0) {
        return [ordered]@{ tier = "2K"; weight = 1.5; tokens = 1680; width = $Dims.width; height = $Dims.height; estimated = $false }
    } else {
        return [ordered]@{ tier = "4K"; weight = 2.25; tokens = 2520; width = $Dims.width; height = $Dims.height; estimated = $false }
    }
}

function Get-TierByName([string]$TierName) {
    switch ($TierName.ToUpperInvariant()) {
        "512"  { return [ordered]@{ tier = "512"; weight = 0.67; tokens = 747; width = 512; height = 512; estimated = $false } }
        "0.5K" { return [ordered]@{ tier = "512"; weight = 0.67; tokens = 747; width = 512; height = 512; estimated = $false } }
        "1K"   { return [ordered]@{ tier = "1K";  weight = 1.0;  tokens = 1120; width = 1024; height = 1024; estimated = $false } }
        "2K"   { return [ordered]@{ tier = "2K";  weight = 1.5;  tokens = 1680; width = 2048; height = 2048; estimated = $false } }
        "4K"   { return [ordered]@{ tier = "4K";  weight = 2.25; tokens = 2520; width = 4096; height = 4096; estimated = $false } }
        default { return [ordered]@{ tier = "1K*"; weight = 1.0; tokens = 1120; width = 0; height = 0; estimated = $true } }
    }
}

# ---------------------------------------------------------------------------
# Rolling Window Calculations & Calibration
# ---------------------------------------------------------------------------

function Get-NowUtc {
    if ($env:IMAGE_QUOTA_NOW_UTC) {
        return [DateTimeOffset]::Parse($env:IMAGE_QUOTA_NOW_UTC).ToUniversalTime()
    }
    return [DateTimeOffset]::UtcNow
}

function Get-WindowStats($State, [DateTimeOffset]$NowUtc) {
    $windowHours = [double]$State["config"]["windowHours"]
    if ($windowHours -le 0) { $windowHours = 5.0 }
    $cutoff = $NowUtc.AddHours(-$windowHours)

    $activeEvents = @()
    $usedUnits = 0.0
    $usedCount = 0
    $tierCounts = [ordered]@{}
    $earliestTs = $null

    foreach ($ev in $State["events"]) {
        try {
            $ts = [DateTimeOffset]::Parse([string]$ev["timestamp"]).ToUniversalTime()
        } catch { continue }
        if ($ts -ge $cutoff -and $ts -le $NowUtc.AddMinutes(5)) {
            $activeEvents += $ev
            $usedUnits += [double]$ev["weight"]
            $usedCount += 1
            $t = [string]$ev["tier"]
            if (-not $tierCounts.Contains($t)) { $tierCounts[$t] = 0 }
            $tierCounts[$t] += 1
            if ($null -eq $earliestTs -or $ts -lt $earliestTs) { $earliestTs = $ts }
        }
    }

    $usedUnits = [Math]::Round($usedUnits, 2)
    $mode = [string]$State["config"]["accountingMode"]
    $limitUnits = [double]$State["config"]["estimatedLimitUnits"]
    $limitCount = [int]$State["config"]["estimatedLimitCount"]

    $cooldownUntil = $null
    $inCooldown = $false
    if ($State["calibration"]["activeCooldownUntil"]) {
        try {
            $cd = [DateTimeOffset]::Parse([string]$State["calibration"]["activeCooldownUntil"]).ToUniversalTime()
            if ($cd -gt $NowUtc) {
                $cooldownUntil = $cd
                $inCooldown = $true
            }
        } catch {}
    }

    $remainingUnits = if ($inCooldown) { 0.0 } else { [Math]::Round([Math]::Max(0.0, $limitUnits - $usedUnits), 2) }
    $remainingCount = if ($inCooldown) { 0 } else { [Math]::Max(0, $limitCount - $usedCount) }

    $nextRecoveryAt = $null
    if ($inCooldown) {
        $nextRecoveryAt = $cooldownUntil
    } elseif ($null -ne $earliestTs) {
        $nextRecoveryAt = $earliestTs.AddHours($windowHours)
    }

    return [ordered]@{
        windowHours = $windowHours
        mode = $mode
        usedUnits = $usedUnits
        usedCount = $usedCount
        limitUnits = $limitUnits
        limitCount = $limitCount
        remainingUnits = $remainingUnits
        remainingCount = $remainingCount
        inCooldown = $inCooldown
        cooldownUntil = $cooldownUntil
        nextRecoveryAt = $nextRecoveryAt
        tierCounts = $tierCounts
        activeEvents = $activeEvents
        sampleCount = @($State["calibration"]["samples"]).Count
    }
}

function Add-ImageEvent($State, [string]$DedupId, [DateTimeOffset]$TimestampUtc, [string]$Source, [string]$SubagentId, [string]$FilePath, $TierInfo, [string]$ModelName) {
    foreach ($existing in $State["events"]) {
        if ([string]$existing["id"] -eq $DedupId) {
            return $null
        }
    }
    $ev = [ordered]@{
        id = $DedupId
        timestamp = $TimestampUtc.ToString("o")
        source = $Source
        subagentId = $SubagentId
        filePath = $FilePath
        width = $TierInfo["width"]
        height = $TierInfo["height"]
        tier = $TierInfo["tier"]
        weight = $TierInfo["weight"]
        tokens = $TierInfo["tokens"]
        model = $ModelName
        notified = $false
    }
    $State["events"] = @($State["events"]) + @($ev)
    return $ev
}

function Parse-RateLimitInfo([string]$Text, [DateTimeOffset]$RefTimeUtc) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $isLimit = ($Text -match '(?i)(RESOURCE_EXHAUSTED|rate[\s_-]?limit|quota.*(exceed|exhaust|limit|reach)|429|too many requests|生图.{0,8}(配额|额度|限额).{0,6}(满|耗尽|用完|上限))')
    if (-not $isLimit) { return $null }

    $model = $null
    if ($Text -match '(?i)(gemini-[a-z0-9\.\-]+image[a-z0-9\.\-]*)') {
        $model = $Matches[1]
    }

    $resetAt = $null
    # Relative duration: "4h 45m", "4 hours 45 minutes", "4 小时 45 分钟", "45m", "17100s"
    if ($Text -match '(?i)(\d+)\s*(?:h|hr|hrs|hour|hours|小时)\s*(?:(\d+)\s*(?:m|min|mins|minute|minutes|分钟))?(?:\s*(\d+)\s*(?:s|sec|secs|second|seconds|秒))?') {
        $h = [int]$Matches[1]
        $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $s = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        if ($h -gt 0 -or $m -gt 0 -or $s -gt 0) {
            $resetAt = $RefTimeUtc.AddHours($h).AddMinutes($m).AddSeconds($s)
        }
    } elseif ($Text -match '(?i)(?:reset|retry|wait|恢复|重置).{0,20}?(\d+)\s*(?:m|min|mins|minute|minutes|分钟)') {
        $m = [int]$Matches[1]
        if ($m -gt 0) { $resetAt = $RefTimeUtc.AddMinutes($m) }
    } elseif ($Text -match '(?i)(?:reset|retry|wait|恢复|重置).{0,20}?(\d+)\s*(?:s|sec|secs|second|seconds|秒)') {
        $s = [int]$Matches[1]
        if ($s -gt 0) { $resetAt = $RefTimeUtc.AddSeconds($s) }
    } elseif ($Text -match '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))') {
        try { $resetAt = [DateTimeOffset]::Parse($Matches[1]).ToUniversalTime() } catch {}
    }

    $snippet = $Text.Trim()
    if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 240) + "..." }

    return [ordered]@{
        model = $model
        resetAt = $resetAt
        snippet = $snippet
    }
}

function Record-RateLimitCalibration($State, $RateLimitInfo, [DateTimeOffset]$NowUtc) {
    $cal = $State["calibration"]
    # Dedup rate-limit event within 2 minutes
    if ($cal["lastRateLimitAt"]) {
        try {
            $lastTs = [DateTimeOffset]::Parse([string]$cal["lastRateLimitAt"]).ToUniversalTime()
            if (($NowUtc - $lastTs).TotalSeconds -lt 120) {
                return $false
            }
        } catch {}
    }

    $stats = Get-WindowStats $State $NowUtc
    $cal["lastRateLimitAt"] = $NowUtc.ToString("o")
    if ($RateLimitInfo["model"]) { $cal["detectedModel"] = $RateLimitInfo["model"] }
    if ($null -ne $RateLimitInfo["resetAt"]) {
        $cal["activeCooldownUntil"] = $RateLimitInfo["resetAt"].ToString("o")
    }

    $sample = [ordered]@{
        timestamp = $NowUtc.ToString("o")
        usedUnitsAtLimit = $stats["usedUnits"]
        usedCountAtLimit = $stats["usedCount"]
        tierBreakdown = $stats["tierCounts"]
        resetAt = if ($null -ne $RateLimitInfo["resetAt"]) { $RateLimitInfo["resetAt"].ToString("o") } else { $null }
        model = $RateLimitInfo["model"]
        snippet = $RateLimitInfo["snippet"]
    }
    $cal["samples"] = @($cal["samples"]) + @($sample)

    if ($State["config"]["autoCalibrate"] -and $stats["usedUnits"] -gt 0) {
        $validUnitSamples = @()
        $validCountSamples = @()
        foreach ($s in $cal["samples"]) {
            if ([double]$s["usedUnitsAtLimit"] -gt 0) { $validUnitSamples += [double]$s["usedUnitsAtLimit"] }
            if ([int]$s["usedCountAtLimit"] -gt 0) { $validCountSamples += [int]$s["usedCountAtLimit"] }
        }
        if ($validUnitSamples.Count -gt 0) {
            $sortedU = $validUnitSamples | Sort-Object
            $midU = $sortedU[[int][Math]::Floor($sortedU.Count / 2)]
            $State["config"]["estimatedLimitUnits"] = [Math]::Round([double]$midU, 2)
        }
        if ($validCountSamples.Count -gt 0) {
            $sortedC = $validCountSamples | Sort-Object
            $midC = $sortedC[[int][Math]::Floor($sortedC.Count / 2)]
            $State["config"]["estimatedLimitCount"] = [int]$midC
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Transcript & Subagent Inspection
# ---------------------------------------------------------------------------

function Get-BrainRootFromTranscript([string]$TranscriptPath) {
    if ([string]::IsNullOrWhiteSpace($TranscriptPath)) { return $null }
    try {
        # <brain>/<convId>/.system_generated/logs/transcript.jsonl
        $logsDir = Split-Path -Parent $TranscriptPath
        $sysDir = Split-Path -Parent $logsDir
        $convDir = Split-Path -Parent $sysDir
        $brainRoot = Split-Path -Parent $convDir
        if (Test-Path -LiteralPath $brainRoot) { return $brainRoot }
    } catch {}
    return $null
}

function Normalize-PathKey([string]$PathStr) {
    if ([string]::IsNullOrWhiteSpace($PathStr)) { return "" }
    return ($PathStr.Replace('\', '/').Trim().ToLowerInvariant())
}

function Extract-ImagePathsFromText([string]$Text) {
    $found = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return ,$found.ToArray() }
    # Match Windows paths (C:/... or C:\...) or Unix paths (/...) ending with png/jpg/jpeg/webp
    $pattern = '(?:[A-Za-z]:[\\/][^\s"''<>|*?`\(\)\[\]]+|/(?:[^\s"''<>|*?`\(\)\[\]]+/)+[^\s"''<>|*?`\(\)\[\]]+)\.(?:png|jpg|jpeg|webp)'
    $matches = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches) {
        $p = $m.Value.TrimEnd('.', ',', ';', ')')
        $norm = Normalize-PathKey $p
        if ($norm -match '/\.user_uploaded/' -or $norm -match '/browser_sandbox/references/') { continue }
        if (-not ($found -contains $p)) { [void]$found.Add($p) }
    }
    return ,$found.ToArray()
}

function Scan-SubagentTranscript($State, [string]$SubagentId, [string]$BrainRoot, [DateTimeOffset]$NowUtc) {
    $addedEvents = @()
    $rateLimitTriggered = $false
    if ([string]::IsNullOrWhiteSpace($SubagentId) -or [string]::IsNullOrWhiteSpace($BrainRoot)) {
        return @{ added = $addedEvents; rateLimited = $false; completed = $false }
    }

    $subDir = Join-Path $BrainRoot $SubagentId
    $subTranscript = Join-Path (Join-Path (Join-Path $subDir ".system_generated") "logs") "transcript.jsonl"
    $completed = $false

    if (Test-Path -LiteralPath $subTranscript -PathType Leaf) {
        try {
            $lines = [System.IO.File]::ReadAllLines($subTranscript, [System.Text.Encoding]::UTF8)
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $step = $line | ConvertFrom-Json } catch { continue }

                $stepTs = $NowUtc
                if ($step.created_at) {
                    try { $stepTs = [DateTimeOffset]::Parse([string]$step.created_at).ToUniversalTime() } catch {}
                }
                $stepType = [string]$step.type
                $stepSource = [string]$step.source
                $stepContent = [string]$step.content
                $stepIdx = [string]$step.step_index

                # Detect rate-limit error in subagent steps
                $rl = Parse-RateLimitInfo $stepContent $stepTs
                if ($null -ne $rl) {
                    if (Record-RateLimitCalibration $State $rl $stepTs) {
                        $rateLimitTriggered = $true
                    }
                }

                # Check if subagent finished/sent message back
                if ($step.tool_calls) {
                    foreach ($tc in $step.tool_calls) {
                        $tcName = [string]$tc.name
                        if ($tcName -match '(?i)send_message') { $completed = $true }
                    }
                }

                # Skip user input media so reference images are never counted as generated outputs
                if ($stepType -eq "USER_INPUT" -or $stepSource -eq "USER_EXPLICIT") { continue }

                $stepPaths = New-Object System.Collections.ArrayList
                # 1) media URIs on non-user steps
                if ($step.media) {
                    foreach ($med in $step.media) {
                        $uri = [string]$med.uri
                        if ($uri -match '\.(png|jpg|jpeg|webp)$') {
                            $norm = Normalize-PathKey $uri
                            if (-not ($norm -match '/\.user_uploaded/' -or $norm -match '/browser_sandbox/references/')) {
                                if (-not ($stepPaths -contains $uri)) { [void]$stepPaths.Add($uri) }
                            }
                        }
                    }
                }
                # 2) Image paths printed in tool output / response content
                $contentPaths = Extract-ImagePathsFromText $stepContent
                foreach ($cp in $contentPaths) {
                    if (-not ($stepPaths -contains $cp)) { [void]$stepPaths.Add($cp) }
                }

                foreach ($imgPath in $stepPaths) {
                    $dims = Get-ImageDimensions $imgPath
                    if ($null -eq $dims) {
                        # Only record paths that actually exist on disk OR come from an image tool result
                        if (-not (Test-Path -LiteralPath $imgPath -PathType Leaf)) { continue }
                    }
                    $tierInfo = Get-ResolutionTier $dims
                    $dedup = "img:" + (Normalize-PathKey $imgPath)
                    $ev = Add-ImageEvent $State $dedup $stepTs "image-generator" $SubagentId $imgPath $tierInfo $State["calibration"]["detectedModel"]
                    if ($null -ne $ev) { $addedEvents += $ev }
                }

                # 3) Fallback: if a generate_image / image tool step completed with DONE and no file path was found
                if ($step.tool_calls) {
                    foreach ($tc in $step.tool_calls) {
                        $tcName = [string]$tc.name
                        if ($tcName -match '(?i)^(generate_image|edit_image|create_image)$') {
                            # Wait for result path from files/subsequent steps; only record step fallback if completed and 0 files found later
                            $completed = $completed
                        }
                    }
                }
            }
        } catch {
            Write-DebugLog "Scan-SubagentTranscript error: $($_.Exception.Message)"
        }
    }

    # Also scan files inside subagent's own brain dir (excluding .user_uploaded and .system_generated)
    if (Test-Path -LiteralPath $subDir -PathType Container) {
        try {
            $imgFiles = Get-ChildItem -LiteralPath $subDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -match '^\.(png|jpg|jpeg|webp)$' -and
                $_.FullName -notmatch '[\\/]\.user_uploaded[\\/]' -and
                $_.FullName -notmatch '[\\/]\.system_generated[\\/]'
            }
            foreach ($f in $imgFiles) {
                $dedup = "img:" + (Normalize-PathKey $f.FullName)
                $dims = Get-ImageDimensions $f.FullName
                $tierInfo = Get-ResolutionTier $dims
                $tsUtc = [DateTimeOffset]$f.LastWriteTimeUtc
                $ev = Add-ImageEvent $State $dedup $tsUtc "image-generator" $SubagentId $f.FullName $tierInfo $State["calibration"]["detectedModel"]
                if ($null -ne $ev) { $addedEvents += $ev }
            }
        } catch {}
    }

    return @{ added = $addedEvents; rateLimited = $rateLimitTriggered; completed = $completed }
}

function Find-SubagentIdInParentTranscript([string]$TranscriptPath, [string]$ToolCallId) {
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return $null
    }
    try {
        $lines = [System.IO.File]::ReadAllLines($TranscriptPath, [System.Text.Encoding]::UTF8)
        $start = [Math]::Max(0, $lines.Length - 30)
        for ($i = $lines.Length - 1; $i -ge $start; $i--) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                # Look specifically for invoke_subagent result or conversationId mention
                if ($line -match '(?i)(conversationId|conversation_id|image-generator|invoke_subagent)') {
                    $allUuids = [regex]::Matches($line, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
                    if ($allUuids.Count -gt 0) {
                        return $allUuids[$allUuids.Count - 1].Value
                    }
                }
            }
        }
    } catch {
        Write-DebugLog "Find-SubagentIdInParentTranscript error: $($_.Exception.Message)"
    }
    return $null
}

function Scan-ParentTranscriptForImageReplies($State, [string]$TranscriptPath, [DateTimeOffset]$NowUtc) {
    $addedEvents = @()
    $rateLimitTriggered = $false
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return @{ added = $addedEvents; rateLimited = $false }
    }
    try {
        $lines = [System.IO.File]::ReadAllLines($TranscriptPath, [System.Text.Encoding]::UTF8)
        $start = [Math]::Max(0, $lines.Length - 20)
        for ($i = $start; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '(?i)(image-generator|generate_image|flash-image|pro-image|RESOURCE_EXHAUSTED|\.png|\.jpg|\.webp)') {
                continue
            }
            try { $step = $line | ConvertFrom-Json } catch { continue }
            $stepSource = [string]$step.source
            $stepType = [string]$step.type
            if ($stepType -eq "USER_INPUT" -or $stepSource -eq "USER_EXPLICIT") { continue }

            $content = [string]$step.content
            $stepTs = $NowUtc
            if ($step.created_at) {
                try { $stepTs = [DateTimeOffset]::Parse([string]$step.created_at).ToUniversalTime() } catch {}
            }

            # Check if this message mentions one of our pending subagents or an image model error
            $isImageContext = ($content -match '(?i)(image-generator|generate_image|flash-image|pro-image)')
            if (-not $isImageContext) {
                foreach ($p in $State["pendingSubagents"]) {
                    if ($content -match [regex]::Escape([string]$p["subagentId"])) {
                        $isImageContext = $true
                        $p["replySeen"] = $true
                    }
                }
            }
            if ($isImageContext) {
                $rl = Parse-RateLimitInfo $content $stepTs
                if ($null -ne $rl) {
                    if (Record-RateLimitCalibration $State $rl $stepTs) {
                        $rateLimitTriggered = $true
                    }
                }
                $paths = Extract-ImagePathsFromText $content
                foreach ($imgPath in $paths) {
                    if (-not (Test-Path -LiteralPath $imgPath -PathType Leaf)) { continue }
                    $dims = Get-ImageDimensions $imgPath
                    $tierInfo = Get-ResolutionTier $dims
                    $dedup = "img:" + (Normalize-PathKey $imgPath)
                    $ev = Add-ImageEvent $State $dedup $stepTs "image-generator" "" $imgPath $tierInfo $State["calibration"]["detectedModel"]
                    if ($null -ne $ev) { $addedEvents += $ev }
                }
            }
        }
    } catch {
        Write-DebugLog "Scan-ParentTranscriptForImageReplies error: $($_.Exception.Message)"
    }
    return @{ added = $addedEvents; rateLimited = $rateLimitTriggered }
}

# ---------------------------------------------------------------------------
# Formatting Helpers
# ---------------------------------------------------------------------------

function Format-LocalTime([DateTimeOffset]$Dto) {
    if ($null -eq $Dto) { return "-" }
    return $Dto.ToLocalTime().ToString("HH:mm")
}

function Format-Countdown([DateTimeOffset]$TargetUtc, [DateTimeOffset]$NowUtc) {
    if ($null -eq $TargetUtc) { return "" }
    $span = $TargetUtc - $NowUtc
    if ($span.TotalSeconds -le 0) { return "即将恢复" }
    $h = [int][Math]::Floor($span.TotalHours)
    $m = [int]$span.Minutes
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

function Build-InlineMarkdown($State, $NewEvents, [bool]$RateLimited, [DateTimeOffset]$NowUtc) {
    $stats = Get-WindowStats $State $NowUtc
    $mode = $stats["mode"]
    $calTag = if ($stats["sampleCount"] -gt 0) { "已校准×$($stats['sampleCount'])" } else { "初始估值" }

    if ($RateLimited -or $stats["inCooldown"]) {
        $resetStr = if ($stats["cooldownUntil"]) {
            "$(Format-LocalTime $stats['cooldownUntil'])（约 $(Format-Countdown $stats['cooldownUntil'] $NowUtc) 后）"
        } else { "待恢复" }
        return "⏳ **生图额度已达上限（已自动记录校准）**｜近 $($stats['windowHours'])h 本机统计：**$($stats['usedUnits']) 点**（$($stats['usedCount']) 张）｜预计恢复：**$resetStr**｜当前参考上限已更新为 ~$($stats['limitUnits']) 点 / ~$($stats['limitCount']) 张"
    }

    # Summarize newly recorded batch
    $batchUnits = 0.0
    $batchTiers = [ordered]@{}
    foreach ($ev in $NewEvents) {
        $batchUnits += [double]$ev["weight"]
        $t = [string]$ev["tier"]
        if (-not $batchTiers.Contains($t)) { $batchTiers[$t] = 0 }
        $batchTiers[$t] += 1
    }
    $batchUnits = [Math]::Round($batchUnits, 2)
    $tierSummary = ($batchTiers.Keys | ForEach-Object { "${_}×$($batchTiers[$_])" }) -join ", "

    $recStr = if ($stats["nextRecoveryAt"]) {
        "｜最早恢复：``$(Format-LocalTime $stats['nextRecoveryAt'])``"
    } else { "" }

    $warnIcon = if ($stats["remainingUnits"] -le [double]$State["config"]["warnThresholdUnits"]) { "⚠️" } else { "🎨" }

    if ($mode -eq "count") {
        return "$warnIcon **生图额度估算**（$calTag）｜本次 +$($NewEvents.Count) 张（$tierSummary，``+${batchUnits}u``）｜近 $($stats['windowHours'])h 已用 **$($stats['usedCount']) / ~$($stats['limitCount']) 张**（预计剩余 **~$($stats['remainingCount']) 张**）$recStr"
    } else {
        return "$warnIcon **生图额度估算**（$calTag）｜本次 +$($NewEvents.Count) 张（$tierSummary，``+${batchUnits}u``）｜近 $($stats['windowHours'])h 已用 **$($stats['usedUnits']) / ~$($stats['limitUnits']) 点**（$($stats['usedCount']) 张，预计剩余 **~$($stats['remainingUnits']) 点**）$recStr"
    }
}

# ---------------------------------------------------------------------------
# Hook Execution Entrypoint
# ---------------------------------------------------------------------------

function Invoke-HookMode {
    $rawStdin = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawStdin)) {
        Write-Output '{}'
        return
    }

    $payload = ConvertTo-OrderedDict ($rawStdin | ConvertFrom-Json)
    $eventName = [string]$payload["hookEventName"]
    $transcriptPath = [string]$payload["transcriptPath"]
    $nowUtc = Get-NowUtc
    $state = Read-State
    $dirty = $false

    if ($eventName -eq "PreToolUse") {
        $tc = $payload["toolCall"]
        $toolName = if ($tc) { [string]$tc["name"] } else { "" }
        $args = if ($tc -and $tc.Contains("args")) { $tc["args"] } else { $null }
        $isImgTool = ($toolName -match '(?i)^(generate_image|edit_image)$') -or (
            $toolName -eq "invoke_subagent" -and $args -and [string]$args["TypeName"] -eq "image-generator"
        )
        if ($isImgTool -and $state["config"]["confirmBeforeLowQuota"]) {
            $stats = Get-WindowStats $state $nowUtc
            if ($stats["inCooldown"]) {
                $tStr = Format-LocalTime $stats["cooldownUntil"]
                $resp = [ordered]@{
                    decision = "ask"
                    reason = "⏳ 生图额度仍在冷却期内（预计 $tStr 恢复），确定要继续调用生图吗？"
                }
                Write-Output ($resp | ConvertTo-Json -Compress)
                return
            } elseif ($stats["remainingUnits"] -le [double]$state["config"]["warnThresholdUnits"]) {
                $resp = [ordered]@{
                    decision = "ask"
                    reason = "⚠️ 生图额度估算偏低：近 $($stats['windowHours'])h 已用 $($stats['usedUnits'])/~$($stats['limitUnits']) 点（$($stats['usedCount']) 张），预计仅剩 ~$($stats['remainingUnits']) 点，确定继续生图吗？"
                }
                Write-Output ($resp | ConvertTo-Json -Compress)
                return
            }
        }
        Write-Output '{"decision":"allow"}'
        return
    }

    if ($eventName -eq "PostToolUse") {
        $tc = $payload["toolCall"]
        $toolName = if ($tc) { [string]$tc["name"] } else { "" }
        $args = if ($tc -and $tc.Contains("args")) { $tc["args"] } else { $null }
        $toolErr = [string]$payload["error"]

        if ($toolName -eq "invoke_subagent" -and $args -and [string]$args["TypeName"] -eq "image-generator") {
            $subId = Find-SubagentIdInParentTranscript $transcriptPath ([string]$tc["id"])
            if ($subId) {
                $exists = $false
                foreach ($p in $state["pendingSubagents"]) {
                    if ([string]$p["subagentId"] -eq $subId) { $exists = $true; break }
                }
                if (-not $exists) {
                    $entry = [ordered]@{
                        subagentId = $subId
                        startedAt = $nowUtc.ToString("o")
                        replySeen = $false
                    }
                    $state["pendingSubagents"] = @($state["pendingSubagents"]) + @($entry)
                    $dirty = $true
                }
            }
        } elseif ($toolName -match '(?i)^(generate_image|edit_image)$') {
            if ($toolErr) {
                $rl = Parse-RateLimitInfo $toolErr $nowUtc
                if ($null -ne $rl) {
                    if (Record-RateLimitCalibration $state $rl $nowUtc) { $dirty = $true }
                }
            } else {
                # Try to find generated image path from args or artifact dir
                $candidatePath = $null
                if ($args) {
                    foreach ($k in @("OutputPath","Path","ImagePath","output_path","path")) {
                        if ($args.Contains($k) -and $args[$k]) { $candidatePath = [string]$args[$k]; break }
                    }
                }
                $dims = if ($candidatePath) { Get-ImageDimensions $candidatePath } else { $null }
                $tierInfo = Get-ResolutionTier $dims
                $dedup = if ($candidatePath) { "img:" + (Normalize-PathKey $candidatePath) } else { "tool:$($payload['conversationId']):$($tc['id'])" }
                $ev = Add-ImageEvent $state $dedup $nowUtc $toolName "" ([string]$candidatePath) $tierInfo $state["calibration"]["detectedModel"]
                if ($null -ne $ev) { $dirty = $true }
            }
        }

        if ($dirty) { Save-State $state }
        Write-Output '{}'
        return
    }

    if ($eventName -eq "PreInvocation" -or $eventName -eq "PostInvocation") {
        $brainRoot = Get-BrainRootFromTranscript $transcriptPath
        $newRateLimited = $false

        # 1. Scan all pending image-generator subagents
        if ($state["pendingSubagents"].Count -gt 0) {
            $kept = @()
            foreach ($p in $state["pendingSubagents"]) {
                $subId = [string]$p["subagentId"]
                $res = Scan-SubagentTranscript $state $subId $brainRoot $nowUtc
                if ($res.added.Count -gt 0 -or $res.rateLimited) { $dirty = $true }
                if ($res.rateLimited) { $newRateLimited = $true }

                $ageMins = 0
                try {
                    $st = [DateTimeOffset]::Parse([string]$p["startedAt"]).ToUniversalTime()
                    $ageMins = ($nowUtc - $st).TotalMinutes
                } catch {}

                if (-not $res.completed -and -not $p["replySeen"] -and $ageMins -lt 30) {
                    $kept += $p
                } else {
                    $dirty = $true
                }
            }
            $state["pendingSubagents"] = $kept
        }

        # 2. Scan parent transcript for any image-generator reply or rate limit
        $parentRes = Scan-ParentTranscriptForImageReplies $state $transcriptPath $nowUtc
        if ($parentRes.added.Count -gt 0 -or $parentRes.rateLimited) { $dirty = $true }
        if ($parentRes.rateLimited) { $newRateLimited = $true }

        # 3. Collect unnotified events
        $unnotified = @()
        foreach ($ev in $state["events"]) {
            if (-not [bool]$ev["notified"]) {
                $unnotified += $ev
                $ev["notified"] = $true
                $dirty = $true
            }
        }

        if ($dirty) { Save-State $state }

        if ($state["config"]["showInlineNotice"] -and ($unnotified.Count -gt 0 -or $newRateLimited)) {
            $md = Build-InlineMarkdown $state $unnotified $newRateLimited $nowUtc
            $resp = [ordered]@{
                injectSteps = @(
                    [ordered]@{
                        systemMessage = [ordered]@{
                            systemMessage = ""
                            metadata = [ordered]@{
                                user_markdown = $md
                            }
                        }
                    }
                )
            }
            Write-Output ($resp | ConvertTo-Json -Depth 10 -Compress)
            return
        }

        Write-Output '{}'
        return
    }

    Write-Output '{}'
}

# ---------------------------------------------------------------------------
# CLI Mode (for Skill / Manual Inspection & Configuration)
# ---------------------------------------------------------------------------

function Invoke-CliMode([string]$Cmd, [string[]]$ArgsList) {
    $nowUtc = Get-NowUtc
    $state = Read-State

    switch ($Cmd.ToLowerInvariant()) {
        "status" {
            $stats = Get-WindowStats $state $nowUtc
            $out = [ordered]@{
                dataPath = Get-StatePath
                windowHours = $stats["windowHours"]
                accountingMode = $stats["mode"]
                usedUnits = $stats["usedUnits"]
                estimatedLimitUnits = $stats["limitUnits"]
                remainingUnits = $stats["remainingUnits"]
                usedCount = $stats["usedCount"]
                estimatedLimitCount = $stats["limitCount"]
                remainingCount = $stats["remainingCount"]
                inCooldown = $stats["inCooldown"]
                cooldownUntilLocal = if ($stats["cooldownUntil"]) { $stats["cooldownUntil"].ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                nextRecoveryLocal = if ($stats["nextRecoveryAt"]) { $stats["nextRecoveryAt"].ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                tierBreakdown = $stats["tierCounts"]
                calibrationSamples = $stats["sampleCount"]
                warnThresholdUnits = [double]$state["config"]["warnThresholdUnits"]
                confirmBeforeLowQuota = [bool]$state["config"]["confirmBeforeLowQuota"]
                autoCalibrate = [bool]$state["config"]["autoCalibrate"]
                showInlineNotice = [bool]$state["config"]["showInlineNotice"]
                recentEvents = @($stats["activeEvents"] | Select-Object -Last 20)
            }
            Write-Output ($out | ConvertTo-Json -Depth 8)
        }
        "delete" {
            $targetId = if ($ArgsList.Count -ge 1) { [string]$ArgsList[0] } else { "" }
            if ([string]::IsNullOrWhiteSpace($targetId)) {
                Write-Output '{"ok":false,"error":"Missing event id"}'
                return
            }
            $before = @($state["events"]).Count
            $state["events"] = @($state["events"] | Where-Object { [string]$_["id"] -ne $targetId })
            $removed = $before - @($state["events"]).Count
            Save-State $state
            Write-Output (@{ ok = ($removed -gt 0); removed = $removed } | ConvertTo-Json -Compress)
        }
        "clear-cooldown" {
            $state["calibration"]["activeCooldownUntil"] = $null
            Save-State $state
            Write-Output '{"ok":true,"message":"Cleared active cooldown."}'
        }
        "add" {
            # Usage: add <tier_or_filepath> [count]
            $target = if ($ArgsList.Count -ge 1) { $ArgsList[0] } else { "1K" }
            $cnt = if ($ArgsList.Count -ge 2) { [int]$ArgsList[1] } else { 1 }
            if ($cnt -lt 1) { $cnt = 1 }
            $added = @()
            for ($i = 0; $i -lt $cnt; $i++) {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $dims = Get-ImageDimensions $target
                    $tierInfo = Get-ResolutionTier $dims
                    $fp = $target
                } else {
                    $tierInfo = Get-TierByName $target
                    $fp = ""
                }
                $dedup = "manual:" + [Guid]::NewGuid().ToString()
                $ev = Add-ImageEvent $state $dedup $nowUtc "manual" "" $fp $tierInfo $null
                $ev["notified"] = $true
                $added += $ev
            }
            Save-State $state
            Write-Output (@{ ok = $true; addedCount = $added.Count; stats = (Get-WindowStats $state $nowUtc) } | ConvertTo-Json -Depth 6)
        }
        "config" {
            # Usage: config key=value [key=value ...]
            foreach ($pair in $ArgsList) {
                $parts = $pair -split '=', 2
                if ($parts.Length -ne 2) { continue }
                $k = $parts[0].Trim()
                $v = $parts[1].Trim()
                if (-not $state["config"].Contains($k)) { continue }
                switch ($k) {
                    "windowHours"           { $state["config"][$k] = [double]$v }
                    "estimatedLimitUnits"   { $state["config"][$k] = [double]$v }
                    "estimatedLimitCount"   { $state["config"][$k] = [int]$v }
                    "warnThresholdUnits"    { $state["config"][$k] = [double]$v }
                    "confirmBeforeLowQuota" { $state["config"][$k] = ($v -match '^(?i)(true|1|yes|on)$') }
                    "autoCalibrate"         { $state["config"][$k] = ($v -match '^(?i)(true|1|yes|on)$') }
                    "showInlineNotice"      { $state["config"][$k] = ($v -match '^(?i)(true|1|yes|on)$') }
                    "accountingMode"        { if ($v -in @("weighted","count")) { $state["config"][$k] = $v } }
                }
            }
            Save-State $state
            Write-Output (@{ ok = $true; config = $state["config"] } | ConvertTo-Json -Depth 6)
        }
        "calibrate" {
            # Usage: calibrate [error_text_or_duration]
            $text = if ($ArgsList.Count -ge 1) { ($ArgsList -join " ") } else { "RESOURCE_EXHAUSTED 5h 0m" }
            $rl = Parse-RateLimitInfo ("RESOURCE_EXHAUSTED " + $text) $nowUtc
            $state["calibration"]["lastRateLimitAt"] = $null # allow manual trigger
            $recorded = Record-RateLimitCalibration $state $rl $nowUtc
            Save-State $state
            Write-Output (@{ ok = $recorded; calibration = $state["calibration"]; config = $state["config"] } | ConvertTo-Json -Depth 8)
        }
        "analyze" {
            $samples = @($state["calibration"]["samples"] | Where-Object { [double]$_["usedUnitsAtLimit"] -gt 0 })
            if ($samples.Count -lt 2) {
                Write-Output (@{
                    enoughData = $false
                    sampleCount = $samples.Count
                    message = "需要至少 2 次不同清晰度组合的撞墙校准样本，才能对比谷歌后端更接近按分辨率加权还是按张数计费。"
                    samples = $samples
                } | ConvertTo-Json -Depth 6)
                return
            }
            $uVals = @($samples | ForEach-Object { [double]$_["usedUnitsAtLimit"] })
            $cVals = @($samples | ForEach-Object { [double]$_["usedCountAtLimit"] })
            $uMean = ($uVals | Measure-Object -Average).Average
            $cMean = ($cVals | Measure-Object -Average).Average
            $uVar = 0.0; foreach ($x in $uVals) { $uVar += [Math]::Pow($x - $uMean, 2) }; $uCv = [Math]::Sqrt($uVar / $uVals.Count) / $uMean
            $cVar = 0.0; foreach ($x in $cVals) { $cVar += [Math]::Pow($x - $cMean, 2) }; $cCv = [Math]::Sqrt($cVar / $cVals.Count) / $cMean
            $rec = if ($uCv -lt $cCv) { "weighted" } elseif ($cCv -lt $uCv) { "count" } else { "inconclusive" }
            Write-Output (@{
                enoughData = $true
                sampleCount = $samples.Count
                weightedMean = [Math]::Round($uMean, 2)
                weightedCV = [Math]::Round($uCv, 4)
                countMean = [Math]::Round($cMean, 2)
                countCV = [Math]::Round($cCv, 4)
                recommendedMode = $rec
                samples = $samples
            } | ConvertTo-Json -Depth 6)
        }
        "reset" {
            $newState = New-DefaultState
            $newState["config"] = $state["config"]
            Save-State $newState
            Write-Output '{"ok":true,"message":"Cleared usage events and cooldown state; preserved config."}'
        }
        default {
            Write-Output '{"error":"Unknown command. Use: status | add | config | calibrate | analyze | reset"}'
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Invoke-HookMode
    } else {
        Invoke-CliMode $Command $RestArgs
    }
} catch {
    Write-DebugLog "Top-level error: $($_.Exception.Message)"
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Output '{}'
    } else {
        Write-Output (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress)
    }
    exit 0
}
