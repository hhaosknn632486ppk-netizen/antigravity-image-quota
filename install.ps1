<#
.SYNOPSIS
One-click Windows installer for Antigravity Image Quota Tracker plugin.
Installs to %USERPROFILE%\.gemini\config\plugins\image-quota-tracker.
#>
$ErrorActionPreference = "Stop"

$src = $PSScriptRoot
$dst = Join-Path (Join-Path (Join-Path (Join-Path $HOME ".gemini") "config") "plugins") "image-quota-tracker"

Write-Host "Installing image-quota-tracker to: $dst"
New-Item -ItemType Directory -Path $dst -Force | Out-Null

foreach ($f in @("plugin.json", "hooks.json", "README.md", "LICENSE")) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination $dst -Force
}
foreach ($d in @("scripts", "skills", "assets", "ui")) {
    Copy-Item -LiteralPath (Join-Path $src $d) -Destination $dst -Recurse -Force
}

# Write Windows-native mcp_config.json (zero extra dependencies; uses built-in PowerShell)
$mcpConfig = @'
{
  "mcpServers": {
    "dashboard": {
      "command": "powershell.exe",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${PLUGIN_ROOT}/scripts/mcp-server.ps1"
      ],
      "env": {
        "IMAGE_QUOTA_DATA_DIR": "${PLUGIN_DATA}"
      }
    }
  }
}
'@
[System.IO.File]::WriteAllText((Join-Path $dst "mcp_config.json"), $mcpConfig, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Done! Open Antigravity -> Side Pane (+) or Left Sidebar -> 'Image Quota'."
Write-Host "If it does not appear immediately, toggle the plugin in Customizations or reload the Antigravity window."
