#!/usr/bin/env python3
"""
Antigravity Image Quota Tracker - Cross-platform Hook & CLI (macOS / Linux Python 3.8+)

Zero-dependency standard-library implementation with exact parity to hook.ps1.
Tracks built-in image generation usage across rolling time windows using official
Gemini image resolution tiers (512=0.67u, 1K=1.0u, 2K=1.5u, 4K=2.25u), counts
multi-round subagent refinements, auto-calibrates on rate-limit errors, and
emits inline user-only status notices via PreInvocation/PostInvocation hooks.
"""

from __future__ import annotations

import json
import math
import os
import re
import struct
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Paths & State Helpers
# ---------------------------------------------------------------------------

def get_data_dir() -> Path:
    candidates: List[Path] = []
    if os.environ.get("IMAGE_QUOTA_DATA_DIR"):
        candidates.append(Path(os.environ["IMAGE_QUOTA_DATA_DIR"]))
    if os.environ.get("PLUGIN_DATA"):
        candidates.append(Path(os.environ["PLUGIN_DATA"]))
    candidates.append(Path(__file__).resolve().parent.parent / ".data")
    candidates.append(Path.home() / ".gemini" / "antigravity" / "image-quota-tracker")

    for d in candidates:
        try:
            d.mkdir(parents=True, exist_ok=True)
            probe = d / f".write_probe_{os.getpid()}"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            return d
        except Exception:
            continue
    raise RuntimeError("No writable data directory available for image-quota-tracker.")


def get_state_path() -> Path:
    return get_data_dir() / "quota-state.json"


def debug_log(msg: str) -> None:
    if os.environ.get("IMAGE_QUOTA_DEBUG") == "1":
        try:
            ts = datetime.now(timezone.utc).isoformat()
            with (get_data_dir() / "debug.log").open("a", encoding="utf-8") as f:
                f.write(f"[{ts}] {msg}\n")
        except Exception:
            pass


def default_state() -> Dict[str, Any]:
    return {
        "version": 1,
        "config": {
            "windowHours": 5.0,
            "accountingMode": "weighted",
            "estimatedLimitUnits": 10.0,
            "estimatedLimitCount": 10,
            "warnThresholdUnits": 2.0,
            "confirmBeforeLowQuota": False,
            "autoCalibrate": True,
            "showInlineNotice": True,
        },
        "calibration": {
            "samples": [],
            "lastRateLimitAt": None,
            "activeCooldownUntil": None,
            "detectedModel": None,
        },
        "pendingSubagents": [],
        "events": [],
    }


def read_state() -> Dict[str, Any]:
    path = get_state_path()
    base = default_state()
    if not path.is_file():
        return base
    try:
        raw = path.read_text(encoding="utf-8")
        if not raw.strip():
            return base
        data = json.loads(raw)
        if not isinstance(data, dict):
            return base
        cfg = dict(base["config"])
        if isinstance(data.get("config"), dict):
            cfg.update(data["config"])
        cal = dict(base["calibration"])
        if isinstance(data.get("calibration"), dict):
            cal.update(data["calibration"])
        return {
            "version": data.get("version", 1),
            "config": cfg,
            "calibration": cal,
            "pendingSubagents": data.get("pendingSubagents") or [],
            "events": data.get("events") or [],
        }
    except Exception as exc:
        debug_log(f"read_state failed: {exc}")
        return base


def save_state(state: Dict[str, Any]) -> None:
    path = get_state_path()
    if len(state["events"]) > 500:
        state["events"] = state["events"][-500:]
    if len(state["calibration"]["samples"]) > 50:
        state["calibration"]["samples"] = state["calibration"]["samples"][-50:]
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def now_utc() -> datetime:
    override = os.environ.get("IMAGE_QUOTA_NOW_UTC")
    if override:
        return parse_iso(override) or datetime.now(timezone.utc)
    return datetime.now(timezone.utc)


def parse_iso(text: Optional[str]) -> Optional[datetime]:
    if not text:
        return None
    try:
        s = text.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Binary Image Header Dimension Reader (Zero Dependencies)
# ---------------------------------------------------------------------------

def get_image_dimensions(file_path: str) -> Optional[Tuple[int, int]]:
    if not file_path:
        return None
    p = Path(file_path)
    if not p.is_file():
        return None
    try:
        with p.open("rb") as f:
            b = f.read(65536)
        n = len(b)
        if n < 24:
            return None

        # PNG
        if b[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", b[16:24])
            if w > 0 and h > 0:
                return int(w), int(h)

        # WebP
        if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
            chunk = b[12:16]
            if chunk == b"VP8X" and n >= 30:
                w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16))
                h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16))
                return w, h
            if chunk == b"VP8L" and n >= 25:
                bits = struct.unpack("<I", b[21:25])[0]
                w = 1 + (bits & 0x3FFF)
                h = 1 + ((bits >> 14) & 0x3FFF)
                return w, h
            if chunk == b"VP8 " and n >= 30 and b[23:26] == b"\x9d\x01\x2a":
                w = (b[26] | (b[27] << 8)) & 0x3FFF
                h = (b[28] | (b[29] << 8)) & 0x3FFF
                return w, h

        # JPEG
        if b[:2] == b"\xff\xd8":
            pos = 2
            sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
            while pos + 9 < n:
                if b[pos] != 0xFF:
                    pos += 1
                    continue
                while pos < n and b[pos] == 0xFF:
                    pos += 1
                if pos >= n:
                    break
                marker = b[pos]
                pos += 1
                if marker in (0xD9, 0xDA):
                    break
                if marker == 0x01 or (0xD0 <= marker <= 0xD7):
                    continue
                if pos + 2 > n:
                    break
                seg_len = (b[pos] << 8) | b[pos + 1]
                if seg_len < 2:
                    break
                if marker in sof and pos + 7 < n:
                    h = (b[pos + 3] << 8) | b[pos + 4]
                    w = (b[pos + 5] << 8) | b[pos + 6]
                    if w > 0 and h > 0:
                        return w, h
                pos += seg_len
    except Exception as exc:
        debug_log(f"get_image_dimensions failed for {file_path}: {exc}")
    return None


def classify_tier(dims: Optional[Tuple[int, int]]) -> Dict[str, Any]:
    if not dims or dims[0] <= 0 or dims[1] <= 0:
        return {"tier": "1K*", "weight": 1.0, "tokens": 1120, "width": 0, "height": 0, "estimated": True}
    w, h = dims
    equiv = math.sqrt(float(w) * float(h))
    if equiv <= 768.0:
        return {"tier": "512", "weight": 0.67, "tokens": 747, "width": w, "height": h, "estimated": False}
    if equiv <= 1536.0:
        return {"tier": "1K", "weight": 1.0, "tokens": 1120, "width": w, "height": h, "estimated": False}
    if equiv <= 3072.0:
        return {"tier": "2K", "weight": 1.5, "tokens": 1680, "width": w, "height": h, "estimated": False}
    return {"tier": "4K", "weight": 2.25, "tokens": 2520, "width": w, "height": h, "estimated": False}


def tier_by_name(name: str) -> Dict[str, Any]:
    key = name.strip().upper()
    table = {
        "512": {"tier": "512", "weight": 0.67, "tokens": 747, "width": 512, "height": 512, "estimated": False},
        "0.5K": {"tier": "512", "weight": 0.67, "tokens": 747, "width": 512, "height": 512, "estimated": False},
        "1K": {"tier": "1K", "weight": 1.0, "tokens": 1120, "width": 1024, "height": 1024, "estimated": False},
        "2K": {"tier": "2K", "weight": 1.5, "tokens": 1680, "width": 2048, "height": 2048, "estimated": False},
        "4K": {"tier": "4K", "weight": 2.25, "tokens": 2520, "width": 4096, "height": 4096, "estimated": False},
    }
    return table.get(key, {"tier": "1K*", "weight": 1.0, "tokens": 1120, "width": 0, "height": 0, "estimated": True})


# ---------------------------------------------------------------------------
# Window Stats & Calibration
# ---------------------------------------------------------------------------

def window_stats(state: Dict[str, Any], now: datetime) -> Dict[str, Any]:
    cfg = state["config"]
    win_h = float(cfg.get("windowHours", 5.0)) or 5.0
    cutoff = now - timedelta(hours=win_h)

    active: List[Dict[str, Any]] = []
    used_units = 0.0
    tier_counts: Dict[str, int] = {}
    earliest: Optional[datetime] = None

    for ev in state["events"]:
        ts = parse_iso(ev.get("timestamp"))
        if not ts:
            continue
        if cutoff <= ts <= now + timedelta(minutes=5):
            active.append(ev)
            used_units += float(ev.get("weight", 1.0))
            t = str(ev.get("tier", "1K*"))
            tier_counts[t] = tier_counts.get(t, 0) + 1
            if earliest is None or ts < earliest:
                earliest = ts

    used_units = round(used_units, 2)
    used_count = len(active)
    limit_units = float(cfg.get("estimatedLimitUnits", 10.0))
    limit_count = int(cfg.get("estimatedLimitCount", 10))

    cd = parse_iso(state["calibration"].get("activeCooldownUntil"))
    in_cooldown = bool(cd and cd > now)

    rem_units = 0.0 if in_cooldown else round(max(0.0, limit_units - used_units), 2)
    rem_count = 0 if in_cooldown else max(0, limit_count - used_count)
    next_rec = cd if in_cooldown else (earliest + timedelta(hours=win_h) if earliest else None)

    return {
        "windowHours": win_h,
        "mode": cfg.get("accountingMode", "weighted"),
        "usedUnits": used_units,
        "usedCount": used_count,
        "limitUnits": limit_units,
        "limitCount": limit_count,
        "remainingUnits": rem_units,
        "remainingCount": rem_count,
        "inCooldown": in_cooldown,
        "cooldownUntil": cd if in_cooldown else None,
        "nextRecoveryAt": next_rec,
        "tierCounts": tier_counts,
        "activeEvents": active,
        "sampleCount": len(state["calibration"].get("samples") or []),
    }


def add_event(
    state: Dict[str, Any],
    dedup_id: str,
    ts: datetime,
    source: str,
    subagent_id: str,
    file_path: str,
    tier_info: Dict[str, Any],
    model: Optional[str],
) -> Optional[Dict[str, Any]]:
    for existing in state["events"]:
        if existing.get("id") == dedup_id:
            return None
    ev = {
        "id": dedup_id,
        "timestamp": ts.isoformat(),
        "source": source,
        "subagentId": subagent_id,
        "filePath": file_path,
        "width": tier_info["width"],
        "height": tier_info["height"],
        "tier": tier_info["tier"],
        "weight": tier_info["weight"],
        "tokens": tier_info["tokens"],
        "model": model,
        "notified": False,
    }
    state["events"].append(ev)
    return ev


def parse_rate_limit(text: str, ref_time: datetime) -> Optional[Dict[str, Any]]:
    if not text:
        return None
    if not re.search(
        r"(RESOURCE_EXHAUSTED|rate[\s_-]?limit|quota.*(exceed|exhaust|limit|reach)|429|too many requests|生图.{0,8}(配额|额度|限额).{0,6}(满|耗尽|用完|上限))",
        text,
        re.IGNORECASE,
    ):
        return None

    m_model = re.search(r"(gemini-[a-z0-9.\-]+image[a-z0-9.\-]*)", text, re.IGNORECASE)
    model = m_model.group(1) if m_model else None

    reset_at: Optional[datetime] = None
    m_hm = re.search(
        r"(\d+)\s*(?:h|hr|hrs|hour|hours|小时)\s*(?:(\d+)\s*(?:m|min|mins|minute|minutes|分钟))?(?:\s*(\d+)\s*(?:s|sec|secs|second|seconds|秒))?",
        text,
        re.IGNORECASE,
    )
    if m_hm:
        h = int(m_hm.group(1))
        m = int(m_hm.group(2) or 0)
        s = int(m_hm.group(3) or 0)
        if h or m or s:
            reset_at = ref_time + timedelta(hours=h, minutes=m, seconds=s)
    else:
        m_min = re.search(r"(?:reset|retry|wait|恢复|重置).{0,20}?(\d+)\s*(?:m|min|mins|minute|minutes|分钟)", text, re.IGNORECASE)
        m_sec = re.search(r"(?:reset|retry|wait|恢复|重置).{0,20}?(\d+)\s*(?:s|sec|secs|second|seconds|秒)", text, re.IGNORECASE)
        m_iso = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))", text)
        if m_min and int(m_min.group(1)) > 0:
            reset_at = ref_time + timedelta(minutes=int(m_min.group(1)))
        elif m_sec and int(m_sec.group(1)) > 0:
            reset_at = ref_time + timedelta(seconds=int(m_sec.group(1)))
        elif m_iso:
            reset_at = parse_iso(m_iso.group(1))

    snippet = text.strip()
    if len(snippet) > 240:
        snippet = snippet[:240] + "..."
    return {"model": model, "resetAt": reset_at, "snippet": snippet}


def record_calibration(state: Dict[str, Any], rl: Dict[str, Any], now: datetime) -> bool:
    cal = state["calibration"]
    last = parse_iso(cal.get("lastRateLimitAt"))
    if last and (now - last).total_seconds() < 120:
        return False

    stats = window_stats(state, now)
    cal["lastRateLimitAt"] = now.isoformat()
    if rl.get("model"):
        cal["detectedModel"] = rl["model"]
    if rl.get("resetAt"):
        cal["activeCooldownUntil"] = rl["resetAt"].isoformat()

    cal["samples"].append({
        "timestamp": now.isoformat(),
        "usedUnitsAtLimit": stats["usedUnits"],
        "usedCountAtLimit": stats["usedCount"],
        "tierBreakdown": stats["tierCounts"],
        "resetAt": rl["resetAt"].isoformat() if rl.get("resetAt") else None,
        "model": rl.get("model"),
        "snippet": rl.get("snippet"),
    })

    if state["config"].get("autoCalibrate") and stats["usedUnits"] > 0:
        u_vals = sorted(float(s["usedUnitsAtLimit"]) for s in cal["samples"] if float(s.get("usedUnitsAtLimit", 0)) > 0)
        c_vals = sorted(int(s["usedCountAtLimit"]) for s in cal["samples"] if int(s.get("usedCountAtLimit", 0)) > 0)
        if u_vals:
            state["config"]["estimatedLimitUnits"] = round(u_vals[len(u_vals) // 2], 2)
        if c_vals:
            state["config"]["estimatedLimitCount"] = int(c_vals[len(c_vals) // 2])
    return True


# ---------------------------------------------------------------------------
# Transcript & Subagent Inspection
# ---------------------------------------------------------------------------

def norm_key(p: str) -> str:
    return p.replace("\\", "/").strip().lower()


def extract_image_paths(text: str) -> List[str]:
    if not text:
        return []
    pat = r'(?:[A-Za-z]:[\\/][^\s"\'<>|*?`()\[\]]+|/(?:[^\s"\'<>|*?`()\[\]]+/)+[^\s"\'<>|*?`()\[\]]+)\.(?:png|jpg|jpeg|webp)'
    out: List[str] = []
    for m in re.finditer(pat, text, re.IGNORECASE):
        p = m.group(0).rstrip(".,;)")
        nk = norm_key(p)
        if "/.user_uploaded/" in nk or "/browser_sandbox/references/" in nk:
            continue
        if p not in out:
            out.append(p)
    return out


def brain_root_from_transcript(transcript_path: str) -> Optional[Path]:
    if not transcript_path:
        return None
    try:
        # <brain>/<convId>/.system_generated/logs/transcript.jsonl
        root = Path(transcript_path).resolve().parents[3]
        return root if root.is_dir() else None
    except Exception:
        return None


def scan_subagent(state: Dict[str, Any], subagent_id: str, brain_root: Optional[Path], now: datetime) -> Tuple[List[Dict[str, Any]], bool, bool]:
    added: List[Dict[str, Any]] = []
    rate_limited = False
    completed = False
    if not subagent_id or not brain_root:
        return added, rate_limited, completed

    sub_dir = brain_root / subagent_id
    sub_transcript = sub_dir / ".system_generated" / "logs" / "transcript.jsonl"

    if sub_transcript.is_file():
        try:
            for line in sub_transcript.read_text(encoding="utf-8", errors="ignore").splitlines():
                if not line.strip():
                    continue
                try:
                    step = json.loads(line)
                except Exception:
                    continue
                step_ts = parse_iso(step.get("created_at")) or now
                content = str(step.get("content") or "")
                rl = parse_rate_limit(content, step_ts)
                if rl and record_calibration(state, rl, step_ts):
                    rate_limited = True
                for tc in step.get("tool_calls") or []:
                    if re.search(r"send_message", str(tc.get("name") or ""), re.IGNORECASE):
                        completed = True
                if step.get("type") == "USER_INPUT" or step.get("source") == "USER_EXPLICIT":
                    continue

                paths: List[str] = []
                for med in step.get("media") or []:
                    uri = str(med.get("uri") or "")
                    if re.search(r"\.(png|jpg|jpeg|webp)$", uri, re.IGNORECASE):
                        nk = norm_key(uri)
                        if "/.user_uploaded/" not in nk and "/browser_sandbox/references/" not in nk and uri not in paths:
                            paths.append(uri)
                for cp in extract_image_paths(content):
                    if cp not in paths:
                        paths.append(cp)

                for img_path in paths:
                    dims = get_image_dimensions(img_path)
                    if dims is None and not Path(img_path).is_file():
                        continue
                    ev = add_event(
                        state,
                        "img:" + norm_key(img_path),
                        step_ts,
                        "image-generator",
                        subagent_id,
                        img_path,
                        classify_tier(dims),
                        state["calibration"].get("detectedModel"),
                    )
                    if ev:
                        added.append(ev)
        except Exception as exc:
            debug_log(f"scan_subagent error: {exc}")

    if sub_dir.is_dir():
        try:
            for f in sub_dir.rglob("*"):
                if not f.is_file():
                    continue
                if f.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp"):
                    continue
                nk = norm_key(str(f))
                if "/.user_uploaded/" in nk or "/.system_generated/" in nk:
                    continue
                dims = get_image_dimensions(str(f))
                ts = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc)
                ev = add_event(
                    state,
                    "img:" + nk,
                    ts,
                    "image-generator",
                    subagent_id,
                    str(f),
                    classify_tier(dims),
                    state["calibration"].get("detectedModel"),
                )
                if ev:
                    added.append(ev)
        except Exception:
            pass

    return added, rate_limited, completed


def find_subagent_id_in_parent(transcript_path: str) -> Optional[str]:
    if not transcript_path or not Path(transcript_path).is_file():
        return None
    try:
        lines = Path(transcript_path).read_text(encoding="utf-8", errors="ignore").splitlines()
        for line in reversed(lines[-30:]):
            if re.search(r"(conversationId|conversation_id|image-generator|invoke_subagent)", line, re.IGNORECASE):
                uuids = re.findall(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", line)
                if uuids:
                    return uuids[-1]
    except Exception:
        pass
    return None


def scan_parent_replies(state: Dict[str, Any], transcript_path: str, now: datetime) -> Tuple[List[Dict[str, Any]], bool]:
    added: List[Dict[str, Any]] = []
    rate_limited = False
    if not transcript_path or not Path(transcript_path).is_file():
        return added, rate_limited
    try:
        lines = Path(transcript_path).read_text(encoding="utf-8", errors="ignore").splitlines()
        for line in lines[-20:]:
            if not re.search(r"(image-generator|generate_image|flash-image|pro-image|RESOURCE_EXHAUSTED|\.png|\.jpg|\.webp)", line, re.IGNORECASE):
                continue
            try:
                step = json.loads(line)
            except Exception:
                continue
            if step.get("type") == "USER_INPUT" or step.get("source") == "USER_EXPLICIT":
                continue
            content = str(step.get("content") or "")
            step_ts = parse_iso(step.get("created_at")) or now
            is_img_ctx = bool(re.search(r"(image-generator|generate_image|flash-image|pro-image)", content, re.IGNORECASE))
            for p in state["pendingSubagents"]:
                if p.get("subagentId") and p["subagentId"] in content:
                    is_img_ctx = True
                    p["replySeen"] = True
            if is_img_ctx:
                rl = parse_rate_limit(content, step_ts)
                if rl and record_calibration(state, rl, step_ts):
                    rate_limited = True
                for img_path in extract_image_paths(content):
                    if not Path(img_path).is_file():
                        continue
                    ev = add_event(
                        state,
                        "img:" + norm_key(img_path),
                        step_ts,
                        "image-generator",
                        "",
                        img_path,
                        classify_tier(get_image_dimensions(img_path)),
                        state["calibration"].get("detectedModel"),
                    )
                    if ev:
                        added.append(ev)
    except Exception as exc:
        debug_log(f"scan_parent_replies error: {exc}")
    return added, rate_limited


# ---------------------------------------------------------------------------
# Formatting & Hook Mode
# ---------------------------------------------------------------------------

def fmt_local(dt: Optional[datetime]) -> str:
    return dt.astimezone().strftime("%H:%M") if dt else "-"


def fmt_countdown(target: Optional[datetime], now: datetime) -> str:
    if not target:
        return ""
    secs = int((target - now).total_seconds())
    if secs <= 0:
        return "即将恢复"
    h, rem = divmod(secs, 3600)
    m = rem // 60
    return f"{h}h {m}m" if h > 0 else f"{m}m"


def build_markdown(state: Dict[str, Any], new_events: List[Dict[str, Any]], rate_limited: bool, now: datetime) -> str:
    st = window_stats(state, now)
    cal_tag = f"已校准×{st['sampleCount']}" if st["sampleCount"] > 0 else "初始估值"

    if rate_limited or st["inCooldown"]:
        reset_str = f"{fmt_local(st['cooldownUntil'])}（约 {fmt_countdown(st['cooldownUntil'], now)} 后）" if st["cooldownUntil"] else "待恢复"
        return (
            f"⏳ **生图额度已达上限（已自动记录校准）**｜近 {st['windowHours']:g}h 本机统计：**{st['usedUnits']} 点**"
            f"（{st['usedCount']} 张）｜预计恢复：**{reset_str}**｜当前参考上限已更新为 ~{st['limitUnits']} 点 / ~{st['limitCount']} 张"
        )

    batch_units = round(sum(float(e.get("weight", 1.0)) for e in new_events), 2)
    tiers: Dict[str, int] = {}
    for e in new_events:
        t = str(e.get("tier", "1K*"))
        tiers[t] = tiers.get(t, 0) + 1
    tier_str = ", ".join(f"{k}×{v}" for k, v in tiers.items())
    rec_str = f"｜最早恢复：`{fmt_local(st['nextRecoveryAt'])}`" if st["nextRecoveryAt"] else ""
    warn_icon = "⚠️" if st["remainingUnits"] <= float(state["config"].get("warnThresholdUnits", 2.0)) else "🎨"

    if st["mode"] == "count":
        return (
            f"{warn_icon} **生图额度估算**（{cal_tag}）｜本次 +{len(new_events)} 张（{tier_str}，`+{batch_units}u`）"
            f"｜近 {st['windowHours']:g}h 已用 **{st['usedCount']} / ~{st['limitCount']} 张**（预计剩余 **~{st['remainingCount']} 张**）{rec_str}"
        )
    return (
        f"{warn_icon} **生图额度估算**（{cal_tag}）｜本次 +{len(new_events)} 张（{tier_str}，`+{batch_units}u`）"
        f"｜近 {st['windowHours']:g}h 已用 **{st['usedUnits']} / ~{st['limitUnits']} 点**（{st['usedCount']} 张，预计剩余 **~{st['remainingUnits']} 点**）{rec_str}"
    )


def run_hook() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        print("{}")
        return
    payload = json.loads(raw)
    ev_name = str(payload.get("hookEventName") or "")
    transcript_path = str(payload.get("transcriptPath") or "")
    now = now_utc()
    state = read_state()
    dirty = False

    if ev_name == "PreToolUse":
        tc = payload.get("toolCall") or {}
        tname = str(tc.get("name") or "")
        args = tc.get("args") or {}
        is_img = bool(re.match(r"^(generate_image|edit_image)$", tname, re.IGNORECASE)) or (
            tname == "invoke_subagent" and args.get("TypeName") == "image-generator"
        )
        if is_img and state["config"].get("confirmBeforeLowQuota"):
            st = window_stats(state, now)
            if st["inCooldown"]:
                print(json.dumps({
                    "decision": "ask",
                    "reason": f"⏳ 生图额度仍在冷却期内（预计 {fmt_local(st['cooldownUntil'])} 恢复），确定要继续调用生图吗？",
                }, ensure_ascii=False))
                return
            if st["remainingUnits"] <= float(state["config"].get("warnThresholdUnits", 2.0)):
                print(json.dumps({
                    "decision": "ask",
                    "reason": f"⚠️ 生图额度估算偏低：近 {st['windowHours']:g}h 已用 {st['usedUnits']}/~{st['limitUnits']} 点（{st['usedCount']} 张），预计仅剩 ~{st['remainingUnits']} 点，确定继续生图吗？",
                }, ensure_ascii=False))
                return
        print('{"decision":"allow"}')
        return

    if ev_name == "PostToolUse":
        tc = payload.get("toolCall") or {}
        tname = str(tc.get("name") or "")
        args = tc.get("args") or {}
        err = str(payload.get("error") or "")

        if tname == "invoke_subagent" and args.get("TypeName") == "image-generator":
            sub_id = find_subagent_id_in_parent(transcript_path)
            if sub_id and not any(p.get("subagentId") == sub_id for p in state["pendingSubagents"]):
                state["pendingSubagents"].append({"subagentId": sub_id, "startedAt": now.isoformat(), "replySeen": False})
                dirty = True
        elif re.match(r"^(generate_image|edit_image)$", tname, re.IGNORECASE):
            if err:
                rl = parse_rate_limit(err, now)
                if rl and record_calibration(state, rl, now):
                    dirty = True
            else:
                cand = ""
                for k in ("OutputPath", "Path", "ImagePath", "output_path", "path"):
                    if args.get(k):
                        cand = str(args[k])
                        break
                dims = get_image_dimensions(cand) if cand else None
                dedup = "img:" + norm_key(cand) if cand else f"tool:{payload.get('conversationId')}:{tc.get('id')}"
                if add_event(state, dedup, now, tname, "", cand, classify_tier(dims), state["calibration"].get("detectedModel")):
                    dirty = True

        if dirty:
            save_state(state)
        print("{}")
        return

    if ev_name in ("PreInvocation", "PostInvocation"):
        broot = brain_root_from_transcript(transcript_path)
        new_rl = False

        if state["pendingSubagents"]:
            kept = []
            for p in state["pendingSubagents"]:
                added, rl, comp = scan_subagent(state, str(p.get("subagentId") or ""), broot, now)
                if added or rl:
                    dirty = True
                if rl:
                    new_rl = True
                started = parse_iso(p.get("startedAt")) or now
                age_mins = (now - started).total_seconds() / 60.0
                if not comp and not p.get("replySeen") and age_mins < 30:
                    kept.append(p)
                else:
                    dirty = True
            state["pendingSubagents"] = kept

        p_added, p_rl = scan_parent_replies(state, transcript_path, now)
        if p_added or p_rl:
            dirty = True
        if p_rl:
            new_rl = True

        unnotified = []
        for ev in state["events"]:
            if not ev.get("notified"):
                unnotified.append(ev)
                ev["notified"] = True
                dirty = True

        if dirty:
            save_state(state)

        if state["config"].get("showInlineNotice") and (unnotified or new_rl):
            md = build_markdown(state, unnotified, new_rl, now)
            print(json.dumps({
                "injectSteps": [{
                    "systemMessage": {
                        "systemMessage": "",
                        "metadata": {"user_markdown": md},
                    }
                }]
            }, ensure_ascii=False))
            return

    print("{}")


def run_cli(cmd: str, args: List[str]) -> None:
    now = now_utc()
    state = read_state()
    c = cmd.lower()

    if c == "status":
        st = window_stats(state, now)
        print(json.dumps({
            "dataPath": str(get_state_path()),
            "windowHours": st["windowHours"],
            "accountingMode": st["mode"],
            "usedUnits": st["usedUnits"],
            "estimatedLimitUnits": st["limitUnits"],
            "remainingUnits": st["remainingUnits"],
            "usedCount": st["usedCount"],
            "estimatedLimitCount": st["limitCount"],
            "remainingCount": st["remainingCount"],
            "inCooldown": st["inCooldown"],
            "cooldownUntilLocal": st["cooldownUntil"].astimezone().strftime("%Y-%m-%d %H:%M:%S") if st["cooldownUntil"] else None,
            "nextRecoveryLocal": st["nextRecoveryAt"].astimezone().strftime("%Y-%m-%d %H:%M:%S") if st["nextRecoveryAt"] else None,
            "tierBreakdown": st["tierCounts"],
            "calibrationSamples": st["sampleCount"],
            "warnThresholdUnits": float(state["config"].get("warnThresholdUnits", 2.0)),
            "confirmBeforeLowQuota": bool(state["config"].get("confirmBeforeLowQuota")),
            "autoCalibrate": bool(state["config"].get("autoCalibrate")),
            "showInlineNotice": bool(state["config"].get("showInlineNotice", True)),
            "recentEvents": st["activeEvents"][-20:],
        }, ensure_ascii=False, indent=2))
    elif c == "delete":
        target_id = args[0] if len(args) >= 1 else ""
        if not target_id:
            print('{"ok":false,"error":"Missing event id"}')
            return
        before = len(state["events"])
        state["events"] = [e for e in state["events"] if str(e.get("id") or "") != target_id]
        removed = before - len(state["events"])
        save_state(state)
        print(json.dumps({"ok": removed > 0, "removed": removed}))
    elif c == "clear-cooldown":
        state["calibration"]["activeCooldownUntil"] = None
        save_state(state)
        print('{"ok":true,"message":"Cleared active cooldown."}')
    elif c == "add":
        target = args[0] if len(args) >= 1 else "1K"
        cnt = max(1, int(args[1])) if len(args) >= 2 else 1
        for _ in range(cnt):
            if Path(target).is_file():
                tinfo = classify_tier(get_image_dimensions(target))
                fp = target
            else:
                tinfo = tier_by_name(target)
                fp = ""
            ev = add_event(state, "manual:" + str(uuid.uuid4()), now, "manual", "", fp, tinfo, None)
            if ev:
                ev["notified"] = True
        save_state(state)
        st = window_stats(state, now)
        print(json.dumps({"ok": True, "addedCount": cnt, "usedUnits": st["usedUnits"], "usedCount": st["usedCount"]}, ensure_ascii=False, indent=2))
    elif c == "config":
        cfg = state["config"]
        for pair in args:
            if "=" not in pair:
                continue
            k, v = pair.split("=", 1)
            k, v = k.strip(), v.strip()
            if k not in cfg:
                continue
            if k in ("windowHours", "estimatedLimitUnits", "warnThresholdUnits"):
                cfg[k] = float(v)
            elif k == "estimatedLimitCount":
                cfg[k] = int(v)
            elif k in ("confirmBeforeLowQuota", "autoCalibrate", "showInlineNotice"):
                cfg[k] = v.lower() in ("true", "1", "yes", "on")
            elif k == "accountingMode" and v in ("weighted", "count"):
                cfg[k] = v
        save_state(state)
        print(json.dumps({"ok": True, "config": cfg}, ensure_ascii=False, indent=2))
    elif c == "calibrate":
        text = " ".join(args) if args else "5h 0m"
        rl = parse_rate_limit("RESOURCE_EXHAUSTED " + text, now)
        state["calibration"]["lastRateLimitAt"] = None
        ok = record_calibration(state, rl, now) if rl else False
        save_state(state)
        print(json.dumps({"ok": ok, "calibration": state["calibration"], "config": state["config"]}, ensure_ascii=False, indent=2))
    elif c == "analyze":
        samples = [s for s in state["calibration"]["samples"] if float(s.get("usedUnitsAtLimit", 0)) > 0]
        if len(samples) < 2:
            print(json.dumps({"enoughData": False, "sampleCount": len(samples), "samples": samples}, ensure_ascii=False, indent=2))
            return
        u_vals = [float(s["usedUnitsAtLimit"]) for s in samples]
        c_vals = [float(s["usedCountAtLimit"]) for s in samples]
        u_mean = sum(u_vals) / len(u_vals)
        c_mean = sum(c_vals) / len(c_vals)
        u_cv = math.sqrt(sum((x - u_mean) ** 2 for x in u_vals) / len(u_vals)) / u_mean
        c_cv = math.sqrt(sum((x - c_mean) ** 2 for x in c_vals) / len(c_vals)) / c_mean
        rec = "weighted" if u_cv < c_cv else ("count" if c_cv < u_cv else "inconclusive")
        print(json.dumps({
            "enoughData": True,
            "sampleCount": len(samples),
            "weightedMean": round(u_mean, 2),
            "weightedCV": round(u_cv, 4),
            "countMean": round(c_mean, 2),
            "countCV": round(c_cv, 4),
            "recommendedMode": rec,
            "samples": samples,
        }, ensure_ascii=False, indent=2))
    elif c == "reset":
        cfg = state["config"]
        ns = default_state()
        ns["config"] = cfg
        save_state(ns)
        print('{"ok":true,"message":"Cleared usage events and cooldown state; preserved config."}')
    else:
        print('{"error":"Unknown command. Use: status | add | config | calibrate | analyze | reset"}')


if __name__ == "__main__":
    try:
        if len(sys.argv) <= 1:
            run_hook()
        else:
            run_cli(sys.argv[1], sys.argv[2:])
    except Exception as exc:
        debug_log(f"Top-level error: {exc}")
        if len(sys.argv) <= 1:
            print("{}")
        else:
            print(json.dumps({"error": str(exc)}, ensure_ascii=False))
        sys.exit(0)
