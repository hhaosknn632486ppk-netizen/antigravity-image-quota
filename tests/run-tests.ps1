$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$hookCmd = Join-Path (Join-Path $repoRoot "scripts") "run-hook.cmd"
$tmpRoot = Join-Path $repoRoot ".data_test_$PID"
$dataDir = Join-Path $tmpRoot "data"
$brainDir = Join-Path $tmpRoot "brain"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
New-Item -ItemType Directory -Path $brainDir -Force | Out-Null

$env:IMAGE_QUOTA_DATA_DIR = $dataDir
$env:IMAGE_QUOTA_NOW_UTC = "2026-11-23T12:00:00Z"

function New-MockPng([string]$Path, [int]$W, [int]$H) {
    $bytes = New-Object byte[] 24
    # PNG signature
    $sig = @(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 0x00,0x00,0x00,0x0D, 0x49,0x48,0x44,0x52)
    for ($i = 0; $i -lt 16; $i++) { $bytes[$i] = [byte]$sig[$i] }
    $bytes[16] = [byte](($W -shr 24) -band 0xFF)
    $bytes[17] = [byte](($W -shr 16) -band 0xFF)
    $bytes[18] = [byte](($W -shr 8) -band 0xFF)
    $bytes[19] = [byte]($W -band 0xFF)
    $bytes[20] = [byte](($H -shr 24) -band 0xFF)
    $bytes[21] = [byte](($H -shr 16) -band 0xFF)
    $bytes[22] = [byte](($H -shr 8) -band 0xFF)
    $bytes[23] = [byte]($H -band 0xFF)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-HookJson([string]$JsonPayload) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c `"`"$hookCmd`"`""
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $sw = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    $sw.Write($JsonPayload)
    $sw.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($err) { Write-Host "STDERR: $err" }
    return $out.Trim()
}

function Assert-True([bool]$Cond, [string]$Msg) {
    if (-not $Cond) { throw "ASSERTION FAILED: $Msg" }
    Write-Host "[PASS] $Msg"
}

try {
    # 1. Test synthetic PNG resolution classification (512, 1K, 1K panoramic 4:1, 2K, 4K)
    $imgDir = Join-Path $tmpRoot "imgs"
    New-Item -ItemType Directory -Path $imgDir -Force | Out-Null
    $p512  = Join-Path $imgDir "t512.png";  New-MockPng $p512 512 512
    $p1k   = Join-Path $imgDir "t1k.png";   New-MockPng $p1k 1376 768
    $p1kp  = Join-Path $imgDir "t1kp.png";  New-MockPng $p1kp 2048 512
    $p2k   = Join-Path $imgDir "t2k.png";   New-MockPng $p2k 2752 1536
    $p4k   = Join-Path $imgDir "t4k.png";   New-MockPng $p4k 4096 4096

    & cmd /c "`"$hookCmd`" add `"$p512`" 1" | Out-Null
    & cmd /c "`"$hookCmd`" add `"$p1k`" 1" | Out-Null
    & cmd /c "`"$hookCmd`" add `"$p1kp`" 1" | Out-Null
    & cmd /c "`"$hookCmd`" add `"$p2k`" 1" | Out-Null
    & cmd /c "`"$hookCmd`" add `"$p4k`" 1" | Out-Null

    $st1 = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($st1.usedCount -eq 5) "5 images recorded across all resolution tiers"
    Assert-True ([Math]::Abs([double]$st1.usedUnits - 6.42) -lt 0.01) "Weighted sum 0.67+1.0+1.0+1.5+2.25 = 6.42 (got $($st1.usedUnits))"
    Assert-True ($st1.tierBreakdown.'1K' -eq 2) "Panoramic 2048x512 classified accurately as 1K via sqrt(w*h)"

    # Reset for subagent E2E test
    & cmd /c "`"$hookCmd`" reset" | Out-Null

    # 2. Simulate parent conversation + 3-round image-generator subagent (_v1 1K, _v2 2K, _v3 2K)
    $parentId = "11111111-1111-1111-1111-111111111111"
    $subId    = "22222222-2222-2222-2222-222222222222"
    $parentLogDir = Join-Path (Join-Path (Join-Path $brainDir $parentId) ".system_generated") "logs"
    $subDir       = Join-Path $brainDir $subId
    $subLogDir    = Join-Path (Join-Path $subDir ".system_generated") "logs"
    New-Item -ItemType Directory -Path $parentLogDir -Force | Out-Null
    New-Item -ItemType Directory -Path $subLogDir -Force | Out-Null

    $parentTranscript = Join-Path $parentLogDir "transcript.jsonl"
    $subTranscript    = Join-Path $subLogDir "transcript.jsonl"

    $parentLine = (@{
        step_index = 5
        type = "TOOL_RESULT"
        created_at = "2026-11-23T12:00:00Z"
        content = "Launched image-generator subagent with conversationId: $subId"
    } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($parentTranscript, "$parentLine`n", (New-Object System.Text.UTF8Encoding($false)))

    # PostToolUse for invoke_subagent
    $postPayload = (@{
        hookEventName = "PostToolUse"
        conversationId = $parentId
        transcriptPath = $parentTranscript
        toolCall = @{ id = "call_1"; name = "invoke_subagent"; args = @{ TypeName = "image-generator" } }
    } | ConvertTo-Json -Depth 6 -Compress)
    $postResp = Invoke-HookJson $postPayload
    Assert-True ($postResp -eq "{}") "PostToolUse registers pending image-generator subagent cleanly"

    # Subagent generates 3 rounds + reference image in .user_uploaded (must be ignored!)
    $uDir = Join-Path $subDir ".user_uploaded"
    New-Item -ItemType Directory -Path $uDir -Force | Out-Null
    New-MockPng (Join-Path $uDir "ref.png") 4096 4096
    $v1 = Join-Path $subDir "hero_v1.png"; New-MockPng $v1 1024 1024
    $v2 = Join-Path $subDir "hero_v2.png"; New-MockPng $v2 2048 2048
    $v3 = Join-Path $subDir "hero_v3.png"; New-MockPng $v3 2048 2048
    $subSteps = @(
        (@{ step_index = 1; type = "USER_INPUT"; created_at = "2026-11-23T12:00:02Z"; content = "draw hero"; media = @(@{ uri = (Join-Path $uDir "ref.png") }) } | ConvertTo-Json -Depth 5 -Compress),
        (@{ step_index = 2; type = "TOOL_RESULT"; created_at = "2026-11-23T12:00:10Z"; content = "Saved $v1" } | ConvertTo-Json -Compress),
        (@{ step_index = 3; type = "TOOL_RESULT"; created_at = "2026-11-23T12:00:20Z"; content = "Saved $v2" } | ConvertTo-Json -Compress),
        (@{ step_index = 4; type = "TOOL_RESULT"; created_at = "2026-11-23T12:00:30Z"; content = "Saved $v3"; tool_calls = @(@{ name = "send_message" }) } | ConvertTo-Json -Depth 5 -Compress)
    ) -join "`n"
    [System.IO.File]::WriteAllText($subTranscript, "$subSteps`n", (New-Object System.Text.UTF8Encoding($false)))

    # PreInvocation fires on parent wakeup
    $preInvPayload = (@{
        hookEventName = "PreInvocation"
        conversationId = $parentId
        transcriptPath = $parentTranscript
        invocationNum = 2
    } | ConvertTo-Json -Compress)
    $preRespObj = (Invoke-HookJson $preInvPayload) | ConvertFrom-Json
    Assert-True ($null -ne $preRespObj.injectSteps -and $preRespObj.injectSteps.Count -eq 1) "PreInvocation emits inline user_markdown notice"
    $md = $preRespObj.injectSteps[0].systemMessage.metadata.user_markdown
    Write-Host "  Inline notice: $md"
    Assert-True ($md -match "\+3 张" -and $md -match "4 / ~10 点") "Counted all 3 refinement rounds (1K+2K+2K = 4.0u) and ignored .user_uploaded ref image"

    # Second PreInvocation must NOT duplicate notice
    $preResp2 = Invoke-HookJson $preInvPayload
    Assert-True ($preResp2 -eq "{}") "Deduplication prevents duplicate inline notice"

    # 3. Simulate rate-limit error & auto-calibration
    $rlLine = (@{
        step_index = 6
        type = "TOOL_RESULT"
        created_at = "2026-11-23T12:05:00Z"
        content = "Error from gemini-3.1-flash-image: RESOURCE_EXHAUSTED, resets in 4h 45m"
    } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText($parentTranscript, "$rlLine`n", (New-Object System.Text.UTF8Encoding($false)))
    $env:IMAGE_QUOTA_NOW_UTC = "2026-11-23T12:05:05Z"
    $rlRespObj = (Invoke-HookJson $preInvPayload) | ConvertFrom-Json
    $rlMd = $rlRespObj.injectSteps[0].systemMessage.metadata.user_markdown
    Write-Host "  Rate-limit notice: $rlMd"
    Assert-True ($rlMd -match "已自动记录校准" -and $rlMd -match "~4 点") "Auto-calibrated limit to 4.0u on rate-limit error"

    # 4. PreToolUse guard when confirmBeforeLowQuota=true during cooldown
    & cmd /c "`"$hookCmd`" config confirmBeforeLowQuota=true" | Out-Null
    $preToolPayload = (@{
        hookEventName = "PreToolUse"
        conversationId = $parentId
        transcriptPath = $parentTranscript
        toolCall = @{ id = "call_2"; name = "invoke_subagent"; args = @{ TypeName = "image-generator" } }
    } | ConvertTo-Json -Depth 6 -Compress)
    $guardResp = (Invoke-HookJson $preToolPayload) | ConvertFrom-Json
    Assert-True ($guardResp.decision -eq "ask") "PreToolUse prompts confirmation while in cooldown"

    # 5. Rolling 5h window expiry check (advance clock +6h)
    $env:IMAGE_QUOTA_NOW_UTC = "2026-11-23T18:06:00Z"
    $stExpired = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($stExpired.usedCount -eq 0 -and $stExpired.usedUnits -eq 0 -and (-not $stExpired.inCooldown)) "Events and cooldown expire cleanly after 5h window"

    # 6. Test delete single event & clear-cooldown
    $env:IMAGE_QUOTA_NOW_UTC = "2026-11-23T19:00:00Z"
    & cmd /c "`"$hookCmd`" add 2K 1" | Out-Null
    & cmd /c "`"$hookCmd`" add 512 1" | Out-Null
    $stBeforeDel = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($stBeforeDel.usedCount -eq 2) "Two manual entries recorded before delete test"
    $delId = $stBeforeDel.recentEvents[0].id
    & cmd /c "`"$hookCmd`" delete `"$delId`"" | Out-Null
    $stAfterDel = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($stAfterDel.usedCount -eq 1 -and [Math]::Abs([double]$stAfterDel.usedUnits - 0.67) -lt 0.01) "Single event deleted accurately (remaining 0.67u)"

    & cmd /c "`"$hookCmd`" calibrate `"2h 0m`"" | Out-Null
    $stCd = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($stCd.inCooldown -eq $true) "Manual calibrate activates cooldown"
    & cmd /c "`"$hookCmd`" clear-cooldown" | Out-Null
    $stCleared = (& cmd /c "`"$hookCmd`" status") | ConvertFrom-Json
    Assert-True ($stCleared.inCooldown -eq $false -and $stCleared.usedCount -eq 1) "clear-cooldown removes cooldown without wiping history"

    # 7. Test MCP App stdio server (initialize, tools/list, resources/read, tools/call)
    $mcpScript = Join-Path (Join-Path $repoRoot "scripts") "mcp-server.ps1"
    $mcpMsgs = @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}',
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
        '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"ui://image-quota/dashboard.html"}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"open_image_quota","arguments":{}}}'
    ) -join "`n"
    $psiMcp = New-Object System.Diagnostics.ProcessStartInfo
    $psiMcp.FileName = "powershell.exe"
    $psiMcp.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mcpScript`""
    $psiMcp.RedirectStandardInput = $true
    $psiMcp.RedirectStandardOutput = $true
    $psiMcp.RedirectStandardError = $true
    $psiMcp.UseShellExecute = $false
    $psiMcp.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $pMcp = [System.Diagnostics.Process]::Start($psiMcp)
    $swMcp = New-Object System.IO.StreamWriter($pMcp.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
    $swMcp.WriteLine($mcpMsgs)
    $swMcp.Close()
    $mcpOut = ($pMcp.StandardOutput.ReadToEnd()).Trim() -split "`n"
    $pMcp.WaitForExit()
    Assert-True ($mcpOut.Count -eq 4) "MCP server returned 4 JSON-RPC responses"
    $mcpInit = $mcpOut[0] | ConvertFrom-Json
    $mcpTools = $mcpOut[1] | ConvertFrom-Json
    $mcpHtml = $mcpOut[2] | ConvertFrom-Json
    $mcpCall = $mcpOut[3] | ConvertFrom-Json
    Assert-True ($mcpInit.result.serverInfo.version -eq "0.3.0") "MCP server reports v0.3.0"
    Assert-True ($mcpTools.result.tools.Count -eq 2) "MCP server exposes open_image_quota + app-only quota_action"
    Assert-True ($mcpHtml.result.contents[0].mimeType -eq "text/html;profile=mcp-app" -and $mcpHtml.result.contents[0].text.Length -gt 10000) "MCP server serves valid self-contained HTML dashboard"
    Assert-True ($mcpCall.result.structuredContent.status.usedCount -eq 1) "MCP open_image_quota returns live structured snapshot"

    Write-Host "`nALL TESTS PASSED!"
} finally {
    Remove-Item Env:IMAGE_QUOTA_DATA_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:IMAGE_QUOTA_NOW_UTC -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
