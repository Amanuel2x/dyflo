"""Live poll-proof: confirm each watcher constructs + can poll its repo/label.
Usage: python3 validate.py <watcher1.py> <watcher2.py> ...
Run from the repo root (where agent_watcher.py lives). Requires gh auth or GITHUB_TOKEN.
"""
import importlib.util
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
from agent_watcher import get_open_tickets  # noqa: E402

for path in sys.argv[1:]:
    spec = importlib.util.spec_from_file_location(Path(path).stem, path)
    m = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(m)   # builds CONFIG; run() is __main__-guarded
        c = m.CONFIG
        tix = get_open_tickets(c)
        ok = c.go_prompt_file.exists() and (c.queue_file is None or c.queue_file.exists())
        print(f"OK  {c.name:10} repo={c.repo} label={c.label} "
              f"tickets={len(tix)} files_ok={ok} cfg_dir={c.claude_config_dir}")
    except Exception as e:
        print(f"FAIL {path}: {type(e).__name__}: {e}")
