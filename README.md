# Antigravity Image Quota Tracker (`image-quota-tracker`)

> A zero-dependency **Google Antigravity (2.0 / IDE / CLI)** plugin that brings **real-time built-in image generation quota tracking**, **resolution-tier weighting (`512` / `1K` / `2K` / `4K`)**, **auto-calibration on rate limits**, and an **interactive Side-Pane / Sidebar Dashboard (MCP App)** to Antigravity.

[中文说明](#中文说明) · [English](#english)

---

## 中文说明

### 为什么做这个插件？
在 Google Antigravity 中，**View Usage（查看用量）** 面板目前只展示主对话模型组（Gemini / Claude / GPT）的额度，而内置生图工具（`image-generator` / `gemini-3.1-flash-image`）使用的是**独立的 5 小时滚动配额池**——平时看不到余量，常常画到一半突然撞上限额才知道要等好几个小时。

由于官方接口暂未向客户端暴露内置生图池的真实余量，本插件采用 **「本地精确记账 + 官方分辨率加权 + 5 小时滑动窗口 + 撞墙自动校准」** 方案，全部运行在本地，**零第三方依赖**、**零外部网络请求**。

### 核心特性

* **右侧辅助面板 & 左侧栏可视化仪表盘（MCP App）**
  * 自适应 Antigravity 深色 / 浅色主题，支持 **中 / EN** 一键切换，每 15 秒自动刷新；
  * 实时展示余额进度条、**按当前余量预计还能再画几张（`512 / 1K / 2K / 4K`）**、最早恢复时间与倒计时；
  * 支持单条记录一键删除（`×`）、手动补记（`+1 512/1K/2K/4K`）、撞限额校准、快捷解除冷却与参数设置。
* **基于官方 Token 阶梯的分辨率加权模型**
  * 参考 Google 官方 `gemini-3.1-flash-image`（Nano Banana 2）输出 Token 规范，自动读取生成图片（PNG / JPEG / WebP）二进制文件头获取真实像素，并用几何平均边长 `sqrt(width × height)` 精准归档（同一档位下 1:1 / 16:9 / 4:1 等宽高比消耗一致）：

| 清晰度档位 | 典型尺寸 | 官方输出 Tokens | 1K 等效权重 | 判定范围 (`sqrt(w × h)`) |
| :--- | :--- | ---: | ---: | :--- |
| **512 (0.5K)** | ~512×512 (~0.25 MP) | 747 | `0.67` | `≤ 768` |
| **1K (默认)** | ~1024×1024 / 1376×768 (~1 MP) | 1,120 | `1.00` | `769 ~ 1536` |
| **2K** | ~2048×2048 / 2752×1536 (~4 MP) | 1,680 | `1.50` | `1537 ~ 3072` |
| **4K** | ~4096×4096 (~16 MP) | 2,520 | `2.25` | `> 3072` |

* **自动捕获子代理多轮精修**
  * 绘图子代理在后台自动精修的多轮产物（如 `_v1 / _v2 / _v3`）会逐张记账，同时自动排除 `.user_uploaded/` 里的参考图。
* **双轨记账 + 撞墙自校准 & 算法验证**
  * 同时追踪 **1K 等效加权点数 (`weighted`)** 与 **原始张数 (`count`)**；
  * 触发 `RESOURCE_EXHAUSTED` / `429` 时自动解析重置倒计时并更新参考上限；收集 ≥2 次不同清晰度组合的撞墙样本后，自动对比离散度（CV），帮助实测后台计费规律。
* **对话内零上下文消耗提示条 + 低额度防撞墙提醒**
  * 每次生图后通过 Hook 的 `metadata.user_markdown` 在对话中渲染一行估算条（`systemMessage: ""`，不占模型上下文）；可选开启低额度 / 冷却期生图前弹窗确认。

### 快速安装

#### Windows（零依赖，使用系统内置 PowerShell）
```powershell
git clone https://github.com/hhaosknn632486ppk-netizen/antigravity-image-quota.git
cd antigravity-image-quota
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

#### macOS / Linux（零依赖，使用 Python 3 标准库）
```bash
git clone https://github.com/hhaosknn632486ppk-netizen/antigravity-image-quota.git
cd antigravity-image-quota
chmod +x install.sh && ./install.sh
```

安装完成后：
1. 在 Antigravity 右上角打开右侧辅助面板（**Toggle Side Pane**），点击顶部 **`+`** → 选择 **Image Quota** 即可常驻边聊边看；
2. 或在最左侧栏直接点击 **Image Quota** 全屏查看；
3. 如果未立即出现，在 **Customizations（自定义）** 里开关一次 `image-quota-tracker` 或执行 **View → Reload Window**。

### 运行测试
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

---

## English

### Why?
Antigravity's built-in **View Usage** panel currently shows quotas for main chat model groups (Gemini / Claude / GPT), while the built-in image generator (`image-generator` / `gemini-3.1-flash-image`) draws from a **separate rolling 5-hour quota pool** that is not surfaced in the UI until you hit a rate-limit error.

**Image Quota Tracker** is a 100% local, zero-dependency Antigravity plugin (Hooks + Skill + MCP App) that estimates remaining image quota in real time, weights outputs using Google's official image token tiers (`512=0.67u`, `1K=1.0u`, `2K=1.5u`, `4K=2.25u`), counts hidden multi-round subagent refinements, and auto-calibrates whenever you hit an actual rate limit.

### Features
- **Interactive MCP App Dashboard** in both the Antigravity **Side Pane (`+` → Image Quota)** and **Left Sidebar**, with dark/light host theme sync, `EN / 中文` toggle, per-tier remaining capacity estimate (`512 / 1K / 2K / 4K`), per-item undo/delete, manual logging, and live auto-refresh.
- **Zero-Dependency Image Header Inspection**: reads exact PNG / JPEG / WebP dimensions directly from binary headers and classifies resolution tiers via geometric mean `sqrt(width * height)` (aspect-ratio invariant).
- **Multi-Round Subagent Tracking**: captures intermediate refinement rounds (`_v1`, `_v2`, `_v3`) while ignoring uploaded reference images.
- **Auto-Calibration & Variance Analysis**: parses rate-limit reset timers automatically, updates estimated caps, and compares weighted vs. raw-count variance across mixed-resolution hits.
- **Zero-Token Inline Chat Notices**: renders a single-line status bar to the user via `metadata.user_markdown` without adding tokens to the model context.

### Installation
- **Windows**: `powershell -ExecutionPolicy Bypass -File .\install.ps1`
- **macOS / Linux**: `chmod +x install.sh && ./install.sh`

### Limitations & Privacy
- Tracks generations performed on **this machine's Antigravity** only (use the `+1` quick buttons to log generations made on other devices).
- Displayed figures are **local estimates** refined through calibration, not exact server-side balances.
- 100% local storage (`quota-state.json`); zero telemetry, zero external network calls.

## License

[MIT](LICENSE)
