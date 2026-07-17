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
BUILTIN_RUNTIMES = ("claude", "cursor")
DEFAULTS = {"adapter": "github", "labels": {"auto": "auto", "hitl": "hitl"}, "runtime": "claude"}

# A custom runtime is any other agent CLI the user declares (codex, grok, gemini…).
# Dyflo can't know their flags, so the user supplies them once and the engine stays
# generic. Required: bin. Optional: headless/interactive flag lists, model_flag,
# ask_model. ponytail: no validation of the flags themselves — we can't verify a CLI
# we don't have; a wrong flag surfaces immediately on first run, loudly.
CUSTOM_RUNTIME_KEYS = ("bin", "headless", "interactive", "model_flag", "ask_model")


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


def known_runtimes(repo: Path) -> tuple[str, ...]:
    """Built-ins plus any custom runtimes declared in this repo's config."""
    custom = tuple((load(repo).get("runtimes") or {}).keys())
    return BUILTIN_RUNTIMES + custom


def set_runtime(repo: Path, value: str) -> str:
    v = value.strip().lower()
    allowed = known_runtimes(repo)
    if v not in allowed:
        raise ValueError(
            f"runtime must be one of {', '.join(allowed)} (got {value!r}). "
            f"To use another agent CLI, declare it first: config.py add-runtime <name> <bin> ...")
    data = load(repo)
    data["runtime"] = v
    save(repo, data)
    return v


def add_runtime(repo: Path, name: str, bin_: str, *, headless: list[str] | None = None,
                interactive: list[str] | None = None, model_flag: str = "--model",
                ask_model: str = "") -> str:
    """Declare a custom agent CLI (codex, grok, gemini, …) so DYFLO_RUNTIME=<name>
    works without engine changes. The user owns the flags — we can't verify a CLI we
    don't have installed."""
    n = name.strip().lower()
    if not n:
        raise ValueError("runtime name cannot be empty")
    if n in BUILTIN_RUNTIMES:
        raise ValueError(f"{n!r} is built in; no need to declare it")
    if not bin_.strip():
        raise ValueError("runtime bin cannot be empty")
    data = load(repo)
    runtimes = dict(data.get("runtimes") or {})
    entry = {"bin": bin_.strip(), "model_flag": model_flag}
    if headless:
        entry["headless"] = list(headless)
    if interactive:
        entry["interactive"] = list(interactive)
    if ask_model:
        entry["ask_model"] = ask_model
    runtimes[n] = entry
    data["runtimes"] = runtimes
    save(repo, data)
    return n


def get_runtime_spec(repo: Path, name: str) -> dict:
    """Flags for a runtime: {} for built-ins (engine knows them), the declared entry
    for a custom one."""
    return dict((load(repo).get("runtimes") or {}).get(name.strip().lower(), {}))


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

    # custom runtimes: declare one, then it becomes selectable
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        assert known_runtimes(repo) == BUILTIN_RUNTIMES
        try:
            set_runtime(repo, "codex"); assert False, "undeclared runtime must be rejected"
        except ValueError as e:
            assert "declare it first" in str(e), "error must say how to fix it"
        add_runtime(repo, "codex", "codex", headless=["exec", "--full-auto"],
                    model_flag="--model", ask_model="gpt-5-mini")
        assert "codex" in known_runtimes(repo)
        assert set_runtime(repo, "codex") == "codex", "declared runtime is selectable"
        spec = get_runtime_spec(repo, "codex")
        assert spec["bin"] == "codex" and spec["headless"] == ["exec", "--full-auto"]
        assert spec["ask_model"] == "gpt-5-mini"
        assert get_runtime_spec(repo, "claude") == {}, "built-ins have no declared spec"
        try:
            add_runtime(repo, "claude", "claude"); assert False, "can't redeclare a built-in"
        except ValueError:
            pass
        # declaring a runtime must not disturb other config
        set_label(repo, "auto", "bot-ok")
        add_runtime(repo, "grok", "grok")
        assert get(repo)["labels"]["auto"] == "bot-ok", "add-runtime preserves other keys"
        assert set(load(repo)["runtimes"]) == {"codex", "grok"}

    # CLI: dash-leading values ("-p") must work via --flag=value. The space form is
    # an argparse trap ("expected one argument") that silently broke the wizard once.
    import subprocess
    with tempfile.TemporaryDirectory() as d:
        me = str(Path(__file__).resolve())
        r = subprocess.run([sys.executable, me, "add-runtime", "grok", "--bin=grok",
                            "--headless=-p", "--model-flag=--model",
                            "--ask-model=grok-3-mini", f"--dir={d}"],
                           capture_output=True, text=True)
        assert r.returncode == 0, f"--flag=value form must work: {r.stderr}"
        spec = get_runtime_spec(Path(d), "grok")
        assert spec["headless"] == ["-p"], spec
        assert spec["ask_model"] == "grok-3-mini", spec
    print("config self-check OK — defaults, validation, clear, unknown-key preservation, "
          "malformed-safe, custom runtimes")


def main() -> int:
    ap = argparse.ArgumentParser(description="Dyflo config")
    ap.add_argument("action", nargs="?", default="get",
                    choices=["get", "set", "add-runtime", "runtimes"])
    ap.add_argument("key", nargs="?")
    ap.add_argument("value", nargs="*")
    ap.add_argument("--dir", default=".")
    # These take values that often START WITH A DASH ("-p", "--model"). argparse
    # rejects those with the space form, so callers must use --flag=value; the
    # self-check pins that behavior.
    ap.add_argument("--bin", default="")
    ap.add_argument("--headless", default="", help="space-separated flags, e.g. 'exec --full-auto'")
    ap.add_argument("--interactive", default="")
    ap.add_argument("--model-flag", default="--model")
    ap.add_argument("--ask-model", default="")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        _self_check()
        return 0

    repo = Path(args.dir)
    if args.action == "runtimes":
        print("\n".join(known_runtimes(repo)))
        return 0

    if args.action == "add-runtime":
        if not args.key:
            print("usage: config.py add-runtime <name> --bin <cli> [--headless '...'] "
                  "[--interactive '...'] [--model-flag --model] [--ask-model <id>]", file=sys.stderr)
            return 2
        try:
            n = add_runtime(repo, args.key, args.bin or args.key,
                            headless=args.headless.split() if args.headless else None,
                            interactive=args.interactive.split() if args.interactive else None,
                            model_flag=args.model_flag, ask_model=args.ask_model)
            print(f"declared runtime {n!r} → use it with: DYFLO_RUNTIME={n} (or config.py set runtime {n})")
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0

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
