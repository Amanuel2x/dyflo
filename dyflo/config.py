#!/usr/bin/env python3
"""
config.py — read/write dyflo.config.json deterministically.

The menu's ask-line can auto-configure Dyflo, but an LLM must never hand-edit this
file: a hallucinated key or a dropped brace silently breaks routing. So every write
goes through here — a fixed set of keys, validated values, atomic write, unknown
keys preserved.

    python3 config.py get [key] [--dir REPO]
    python3 config.py set runtime cursor [--dir REPO]
    python3 config.py set model gpt-5 [--dir REPO]
    python3 config.py set label auto bot-ok [--dir REPO]
    python3 config.py --self-check
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

CONFIG_NAME = "dyflo.config.json"
RUNTIMES = ("claude", "cursor")
DEFAULTS = {"adapter": "github", "labels": {"auto": "auto", "hitl": "hitl"}, "runtime": "claude"}


def path_for(repo: Path) -> Path:
    return Path(repo) / CONFIG_NAME


def load(repo: Path) -> dict:
    p = path_for(repo)
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}  # malformed → callers fall back to defaults, never crash


def save(repo: Path, data: dict) -> Path:
    """Atomic write so a crash mid-write can't leave a truncated config."""
    p = path_for(repo)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    tmp.replace(p)
    return p


def get(repo: Path, key: str | None = None):
    data = {**DEFAULTS, **load(repo)}
    if key is None:
        return data
    if key == "model":
        return data.get("model", "")
    return data.get(key, "")


def set_runtime(repo: Path, value: str) -> str:
    v = value.strip().lower()
    if v not in RUNTIMES:
        raise ValueError(f"runtime must be one of {', '.join(RUNTIMES)} (got {value!r})")
    data = load(repo)
    data["runtime"] = v
    save(repo, data)
    return v


def set_model(repo: Path, value: str) -> str:
    """Empty value clears it → each CLI falls back to its own default model."""
    v = value.strip()
    data = load(repo)
    if v:
        data["model"] = v
    else:
        data.pop("model", None)
    save(repo, data)
    return v


def set_label(repo: Path, lane: str, value: str) -> str:
    lane = lane.strip().lower()
    if lane not in ("auto", "hitl"):
        raise ValueError(f"lane must be 'auto' or 'hitl' (got {lane!r})")
    v = value.strip()
    if not v:
        raise ValueError("label cannot be empty")
    data = load(repo)
    labels = dict(data.get("labels") or {})
    labels.setdefault("auto", "auto")
    labels.setdefault("hitl", "hitl")
    labels[lane] = v
    data["labels"] = labels
    save(repo, data)
    return v


def set_adapter(repo: Path, value: str) -> str:
    v = value.strip().lower()
    if not v:
        raise ValueError("adapter cannot be empty")
    data = load(repo)
    data["adapter"] = v
    save(repo, data)
    return v


def _self_check() -> None:
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        # no file → defaults, no crash
        assert get(repo, "runtime") == "claude"
        assert get(repo, "model") == ""
        assert get(repo)["labels"] == {"auto": "auto", "hitl": "hitl"}

        # set runtime, validated
        assert set_runtime(repo, "CURSOR") == "cursor", "case-insensitive + normalized"
        assert get(repo, "runtime") == "cursor"
        try:
            set_runtime(repo, "gpt"); assert False, "must reject unknown runtime"
        except ValueError:
            pass
        assert get(repo, "runtime") == "cursor", "rejected write left config intact"

        # model set/clear
        set_model(repo, "gpt-5")
        assert get(repo, "model") == "gpt-5"
        set_model(repo, "")
        assert get(repo, "model") == "", "empty clears → CLI default"
        assert "model" not in load(repo), "cleared key is removed, not left empty"

        # labels
        set_label(repo, "auto", "bot-ok")
        assert get(repo)["labels"] == {"auto": "bot-ok", "hitl": "hitl"}
        try:
            set_label(repo, "nope", "x"); assert False, "must reject unknown lane"
        except ValueError:
            pass

        # unknown keys preserved across writes (never clobber a user's extra config)
        data = load(repo); data["custom_thing"] = {"keep": True}; save(repo, data)
        set_runtime(repo, "claude")
        assert load(repo)["custom_thing"] == {"keep": True}, "unknown keys survive"

        # malformed file → defaults, no crash
        path_for(repo).write_text("{not json", encoding="utf-8")
        assert get(repo, "runtime") == "claude", "malformed → safe defaults"

        # adapter
        set_adapter(repo, "jira")
        assert get(repo, "adapter") == "jira"
    print("config self-check OK — defaults, validation, clear, unknown-key preservation, malformed-safe")


def main() -> int:
    ap = argparse.ArgumentParser(description="Dyflo config")
    ap.add_argument("action", nargs="?", default="get", choices=["get", "set"])
    ap.add_argument("key", nargs="?")
    ap.add_argument("value", nargs="*")
    ap.add_argument("--dir", default=".")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        _self_check()
        return 0

    repo = Path(args.dir)
    if args.action == "get":
        out = get(repo, args.key)
        print(json.dumps(out, indent=2) if isinstance(out, dict) else out)
        return 0

    # set
    if not args.key:
        print("usage: config.py set runtime|model|adapter <value> | set label auto|hitl <value>",
              file=sys.stderr)
        return 2
    try:
        if args.key == "runtime":
            print(f"runtime → {set_runtime(repo, args.value[0] if args.value else '')}")
        elif args.key == "model":
            v = set_model(repo, args.value[0] if args.value else "")
            print("model → " + (v or "(cleared — each CLI uses its own default)"))
        elif args.key == "adapter":
            print(f"adapter → {set_adapter(repo, args.value[0] if args.value else '')}")
        elif args.key == "label":
            if len(args.value) < 2:
                print("usage: config.py set label auto|hitl <value>", file=sys.stderr)
                return 2
            print(f"label {args.value[0]} → {set_label(repo, args.value[0], args.value[1])}")
        else:
            print(f"unknown key {args.key!r}; use runtime|model|adapter|label", file=sys.stderr)
            return 2
    except (ValueError, IndexError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
