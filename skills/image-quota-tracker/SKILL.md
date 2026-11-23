---
name: image-quota-tracker
description: Inspect, configure, manually record, calibrate, or analyze local Antigravity built-in image generation quota usage (rolling 5h window with 512/1K/2K/4K resolution weighting). Use whenever the user asks about remaining image quota, image generation history, changing estimated limits or accounting mode, toggling low-quota warnings, or analyzing rate-limit calibration samples.
---

# Image Quota Tracker

This skill controls the **Image Quota Tracker** plugin, which tracks built-in Antigravity image generation usage locally across a rolling 5-hour window, weights outputs by official Gemini image resolution tiers, and auto-calibrates when rate limits are hit.

## Resolution Weighting Model

Based on official `gemini-3.1-flash-image` output token tiers (aspect ratio does not change tokens within a tier; classified by geometric mean `sqrt(width * height)`):

| Tier | Typical Size | Official Image Tokens | 1K-Equivalent Weight |
| :--- | :--- | ---: | ---: |
| `512` | ~512×512 (~0.25 MP) | 747 | `0.67` |
| `1K` | ~1024×1024 / 1376×768 (~1 MP) | 1,120 | `1.00` |
| `2K` | ~2048×2048 / 2752×1536 (~4 MP) | 1,680 | `1.50` |
| `4K` | ~4096×4096 (~16 MP) | 2,520 | `2.25` |

## CLI Commands

Locate the plugin script relative to this `SKILL.md` (`../../scripts/run-hook.cmd`, or `../../scripts/hook.ps1` on Windows / `../../scripts/hook.py` on macOS/Linux) and run one of the commands below:

- **View current status & recent history**:
  - Windows PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin_dir>/scripts/hook.ps1" status`
  - macOS / Linux: `python3 "<plugin_dir>/scripts/hook.py" status`
- **Configure settings** (`windowHours`, `accountingMode=weighted|count`, `estimatedLimitUnits`, `estimatedLimitCount`, `warnThresholdUnits`, `confirmBeforeLowQuota=true|false`, `autoCalibrate=true|false`, `showInlineNotice=true|false`):
  - `... config estimatedLimitUnits=6 confirmBeforeLowQuota=true`
- **Record manual usage** (e.g., images generated on another device):
  - `... add 2K 2` or `... add /path/to/image.png 1`
- **Record a manual rate-limit calibration** (e.g., if user reports a reset countdown):
  - `... calibrate "4h 45m"`
- **Analyze calibration samples** (compares weighted vs count variance across past rate-limit hits):
  - `... analyze`
- **Clear usage events & cooldown** (preserves config):
  - `... reset`

## Reporting Guidelines

- Always state clearly that the displayed remaining figure is a **local estimate** (and indicate whether it is based on initial defaults or calibrated from `N` rate-limit hits).
- Show **both** the 1K-equivalent weighted units and raw image count, plus the resolution tier breakdown and earliest slot recovery time.
- When `inCooldown` is true, highlight the expected unlock time clearly.
