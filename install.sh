#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_DIR="${HOME}/.gemini/config/plugins/image-quota-tracker"

echo "Installing image-quota-tracker to: ${DST_DIR}"
mkdir -p "${DST_DIR}"

cp -f "${SRC_DIR}/plugin.json" "${SRC_DIR}/hooks.json" "${SRC_DIR}/README.md" "${SRC_DIR}/LICENSE" "${DST_DIR}/"
rm -rf "${DST_DIR}/scripts" "${DST_DIR}/skills" "${DST_DIR}/assets" "${DST_DIR}/ui"
cp -R "${SRC_DIR}/scripts" "${SRC_DIR}/skills" "${SRC_DIR}/assets" "${SRC_DIR}/ui" "${DST_DIR}/"

chmod +x "${DST_DIR}/scripts/run-hook.cmd" "${DST_DIR}/scripts/run-mcp.cmd" "${DST_DIR}/scripts/hook.py" "${DST_DIR}/scripts/mcp-server.py"

# Write macOS/Linux-native mcp_config.json (uses standard library python3)
cat > "${DST_DIR}/mcp_config.json" <<'EOF'
{
  "mcpServers": {
    "dashboard": {
      "command": "python3",
      "args": [
        "${PLUGIN_ROOT}/scripts/mcp-server.py"
      ],
      "env": {
        "IMAGE_QUOTA_DATA_DIR": "${PLUGIN_DATA}"
      }
    }
  }
}
EOF

echo "Done! Open Antigravity -> Side Pane (+) or Left Sidebar -> 'Image Quota'."
echo "If it does not appear immediately, toggle the plugin in Customizations or reload the Antigravity window."
