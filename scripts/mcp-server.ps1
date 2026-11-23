<#
.SYNOPSIS
Antigravity Image Quota Tracker - Zero-Dependency MCP App Stdio Server (Windows PowerShell 5.1+)

Serves the interactive Image Quota Dashboard MCP App (`ui://image-quota/dashboard.html`)
with both `aux_pane` (side pane) and `global` (left sidebar) entrypoints.
#>

$ErrorActionPreference = "Stop"
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = $PSScriptRoot
$PluginRoot = Split-Path -Parent $ScriptDir
$HookScript = Join-Path $ScriptDir "hook.ps1"
$DashboardHtmlPath = Join-Path (Join-Path $PluginRoot "ui") "dashboard.html"
$AppUri = "ui://image-quota/dashboard.html"

if (-not $env:IMAGE_QUOTA_DATA_DIR -and $env:PLUGIN_DATA) {
    $env:IMAGE_QUOTA_DATA_DIR = $env:PLUGIN_DATA
}

function Invoke-HookCli([string[]]$CliArgs) {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HookScript @CliArgs 2>$null
    $joined = ($output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return @{} }
    try { return ($joined | ConvertFrom-Json) } catch { return @{ raw = $joined } }
}

function Get-DashboardSnapshot {
    $status = Invoke-HookCli @("status")
    $analysis = Invoke-HookCli @("analyze")
    return [ordered]@{
        status = $status
        analysis = $analysis
        serverTimeLocal = (Get-Date).ToString("HH:mm:ss")
    }
}

function Format-TextSummary($Snap) {
    $st = $Snap.status
    if ($null -eq $st) { return "Image Quota Tracker dashboard opened." }
    if ($st.inCooldown) {
        return "生图额度冷却中（预计 $($st.cooldownUntilLocal) 恢复）｜近 $($st.windowHours)h 已用 $($st.usedUnits) 点（$($st.usedCount) 张）。"
    }
    return "生图额度估算：近 $($st.windowHours)h 已用 $($st.usedUnits) / ~$($st.estimatedLimitUnits) 点（$($st.usedCount) / ~$($st.estimatedLimitCount) 张），预计剩余 ~$($st.remainingUnits) 点。"
}

function Write-RpcMessage($Obj) {
    $json = $Obj | ConvertTo-Json -Depth 15 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Send-RpcResult($Id, $Result) {
    Write-RpcMessage ([ordered]@{
        jsonrpc = "2.0"
        id = $Id
        result = $Result
    })
}

function Send-RpcError($Id, [int]$Code, [string]$Message) {
    Write-RpcMessage ([ordered]@{
        jsonrpc = "2.0"
        id = $Id
        error = [ordered]@{
            code = $Code
            message = $Message
        }
    })
}

function Get-ToolsList {
    return @(
        [ordered]@{
            name = "open_image_quota"
            title = "Image Quota"
            description = "Open the interactive Image Quota Tracker dashboard showing rolling 5-hour usage, resolution-weighted estimates, cooldown status, and calibration controls."
            inputSchema = [ordered]@{
                type = "object"
                properties = [ordered]@{}
                additionalProperties = $false
            }
            _meta = [ordered]@{
                ui = [ordered]@{
                    resourceUri = $AppUri
                }
                "com.google.antigravity/ui" = [ordered]@{
                    entrypoints = @(
                        [ordered]@{ type = "aux_pane"; title = "Image Quota" },
                        [ordered]@{ type = "global";   title = "Image Quota" }
                    )
                }
            }
        },
        [ordered]@{
            name = "quota_action"
            title = "Image Quota Action"
            description = "App-only backend action for refreshing, logging manual usage, updating config, calibrating, or resetting image quota state."
            inputSchema = [ordered]@{
                type = "object"
                properties = [ordered]@{
                    action = [ordered]@{ type = "string"; enum = @("refresh", "add", "delete", "config", "calibrate", "clear-cooldown", "reset") }
                    eventId = [ordered]@{ type = "string" }
                    tier = [ordered]@{ type = "string" }
                    count = [ordered]@{ type = "integer" }
                    resetText = [ordered]@{ type = "string" }
                    settings = [ordered]@{ type = "object" }
                }
                required = @("action")
            }
            _meta = [ordered]@{
                ui = [ordered]@{
                    visibility = @("app")
                }
            }
        }
    )
}

function Handle-ToolCall([string]$ToolName, $Arguments) {
    if ($ToolName -eq "open_image_quota") {
        $snap = Get-DashboardSnapshot
        return [ordered]@{
            content = @(
                [ordered]@{
                    type = "text"
                    text = (Format-TextSummary $snap)
                }
            )
            structuredContent = $snap
        }
    }

    if ($ToolName -eq "quota_action") {
        $act = if ($Arguments -and $Arguments.action) { [string]$Arguments.action } else { "refresh" }
        switch ($act) {
            "add" {
                $tier = if ($Arguments.tier) { [string]$Arguments.tier } else { "1K" }
                $cnt = if ($Arguments.count) { [string]$Arguments.count } else { "1" }
                [void](Invoke-HookCli @("add", $tier, $cnt))
            }
            "delete" {
                if ($Arguments.eventId) {
                    [void](Invoke-HookCli @("delete", [string]$Arguments.eventId))
                }
            }
            "clear-cooldown" {
                [void](Invoke-HookCli @("clear-cooldown"))
            }
            "config" {
                if ($Arguments.settings) {
                    $pairs = @("config")
                    foreach ($p in $Arguments.settings.PSObject.Properties) {
                        $pairs += "$($p.Name)=$($p.Value)"
                    }
                    if ($pairs.Count -gt 1) {
                        [void](Invoke-HookCli $pairs)
                    }
                }
            }
            "calibrate" {
                $rt = if ($Arguments.resetText) { [string]$Arguments.resetText } else { "5h 0m" }
                [void](Invoke-HookCli @("calibrate", $rt))
            }
            "reset" {
                [void](Invoke-HookCli @("reset"))
            }
        }
        $snap = Get-DashboardSnapshot
        return [ordered]@{
            content = @(
                [ordered]@{
                    type = "text"
                    text = (Format-TextSummary $snap)
                }
            )
            structuredContent = $snap
        }
    }

    return [ordered]@{
        isError = $true
        content = @(
            [ordered]@{
                type = "text"
                text = "Unknown tool: $ToolName"
            }
        )
    }
}

# Main JSON-RPC Stdio Loop
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $req = $null
    try {
        $req = $line | ConvertFrom-Json
    } catch {
        continue
    }

    $hasId = ($null -ne $req.PSObject.Properties["id"])
    $id = if ($hasId) { $req.id } else { $null }
    $method = [string]$req.method
    $params = if ($null -ne $req.PSObject.Properties["params"]) { $req.params } else { $null }

    try {
        switch ($method) {
            "initialize" {
                $clientProto = if ($params -and $params.protocolVersion) { [string]$params.protocolVersion } else { "2025-03-26" }
                Send-RpcResult $id ([ordered]@{
                    protocolVersion = $clientProto
                    capabilities = [ordered]@{
                        tools = [ordered]@{ listChanged = $false }
                        resources = [ordered]@{ subscribe = $false; listChanged = $false }
                    }
                    serverInfo = [ordered]@{
                        name = "image-quota-tracker"
                        version = "0.3.0"
                    }
                })
            }
            "notifications/initialized" {
                # Notification - no response
            }
            "ping" {
                if ($hasId) { Send-RpcResult $id ([ordered]@{}) }
            }
            "tools/list" {
                Send-RpcResult $id ([ordered]@{
                    tools = (Get-ToolsList)
                })
            }
            "tools/call" {
                $tName = if ($params -and $params.name) { [string]$params.name } else { "" }
                $tArgs = if ($params -and $params.arguments) { $params.arguments } else { $null }
                $res = Handle-ToolCall $tName $tArgs
                Send-RpcResult $id $res
            }
            "resources/list" {
                Send-RpcResult $id ([ordered]@{
                    resources = @(
                        [ordered]@{
                            uri = $AppUri
                            name = "Image Quota Dashboard"
                            description = "Interactive visual dashboard for Antigravity Image Quota Tracker"
                            mimeType = "text/html;profile=mcp-app"
                            _meta = [ordered]@{
                                ui = [ordered]@{
                                    prefersBorder = $false
                                }
                            }
                        }
                    )
                })
            }
            "resources/read" {
                $uri = if ($params -and $params.uri) { [string]$params.uri } else { "" }
                if ($uri -eq $AppUri -and (Test-Path -LiteralPath $DashboardHtmlPath -PathType Leaf)) {
                    $html = [System.IO.File]::ReadAllText($DashboardHtmlPath, [System.Text.Encoding]::UTF8)
                    Send-RpcResult $id ([ordered]@{
                        contents = @(
                            [ordered]@{
                                uri = $AppUri
                                mimeType = "text/html;profile=mcp-app"
                                text = $html
                                _meta = [ordered]@{
                                    ui = [ordered]@{
                                        prefersBorder = $false
                                    }
                                }
                            }
                        )
                    })
                } else {
                    Send-RpcError $id -32602 "Resource not found: $uri"
                }
            }
            default {
                if ($hasId) {
                    Send-RpcError $id -32601 "Method not found: $method"
                }
            }
        }
    } catch {
        if ($hasId) {
            Send-RpcError $id -32603 $_.Exception.Message
        }
    }
}
