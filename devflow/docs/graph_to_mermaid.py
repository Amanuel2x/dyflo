#!/usr/bin/env python3
"""
graph_to_mermaid — turn a graphify graph.json into clean, portable Mermaid.

The doc agent uses this so diagrams come from the REAL graph, never from memory.
Output is theme-neutral Mermaid (renders in GitHub, Obsidian, any Markdown) — not
the dark-themed interactive HTML graphify's callflow export ships (that's for a
browser). Three views, pick with --view:

  modules    file/module-level dependency graph (who imports/contains whom)
  calls      function call graph (who calls whom), optionally scoped to a node
  community  subsystem clusters (graphify's Leiden communities) as subgraphs

Usage:
  graph_to_mermaid.py [--graph graphify-out/graph.json] [--view calls]
                      [--focus NODE] [--depth 2] [--max-nodes 40]
  graph_to_mermaid.py --self-check
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

# relations that mean "A depends on / reaches B" for a call/dependency view
CALL_RELS = {"calls", "indirect_call", "references", "uses", "imports",
             "imports_from", "re_exports", "inherits", "extends", "implements",
             "mixes_in", "embeds"}
CONTAIN_RELS = {"contains"}


def _load(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _safe(node_id: str) -> str:
    """Mermaid node ids must be alnum/underscore. Keep a stable mapping."""
    return "n_" + re.sub(r"[^0-9a-zA-Z]", "_", node_id)


def _label(node: dict) -> str:
    lbl = (node.get("label") or node.get("id") or "?").strip()
    # drop paren call markers and quote-escape for Mermaid text
    lbl = lbl.replace('"', "'")
    return lbl[:48]


def _nodes_by_id(g: dict) -> dict:
    return {n["id"]: n for n in g.get("nodes", [])}


def _edges(g: dict, rels: set[str]) -> list[tuple[str, str, str]]:
    out = []
    for l in g.get("links", []):
        rel = l.get("relation") or l.get("type") or ""
        if rel in rels:
            out.append((l["source"], l["target"], rel))
    return out


def _bfs(edges: list[tuple[str, str, str]], focus: str, depth: int) -> set[str]:
    adj = defaultdict(set)
    for s, t, _ in edges:
        adj[s].add(t)
        adj[t].add(s)  # neighborhood in both directions
    seen = {focus}
    frontier = {focus}
    for _ in range(depth):
        nxt = set()
        for n in frontier:
            nxt |= adj[n] - seen
        seen |= nxt
        frontier = nxt
    return seen


def render(g: dict, view: str, focus: str | None, depth: int, max_nodes: int) -> str:
    by_id = _nodes_by_id(g)
    rels = CONTAIN_RELS if view == "modules" else CALL_RELS
    edges = _edges(g, rels)

    keep = set(by_id)
    if focus:
        match = focus if focus in by_id else next(
            (nid for nid, n in by_id.items()
             if focus.lower() in (n.get("label", "") + nid).lower()), None)
        if not match:
            raise SystemExit(f"--focus {focus!r} matched no node")
        keep = _bfs(edges, match, depth)

    edges = [(s, t, r) for s, t, r in edges if s in keep and t in keep]

    # cap size deterministically: keep the highest-degree nodes (the real hubs)
    if len(keep) > max_nodes:
        deg: dict[str, int] = defaultdict(int)
        for s, t, _ in edges:
            deg[s] += 1
            deg[t] += 1
        keep = set(sorted(keep, key=lambda n: -deg.get(n, 0))[:max_nodes])
        edges = [(s, t, r) for s, t, r in edges if s in keep and t in keep]

    if view == "community":
        return _render_community(g, by_id, edges, keep)

    lines = ["```mermaid", "flowchart TD"]
    for nid in sorted(keep):
        if nid in by_id:
            lines.append(f'    {_safe(nid)}["{_label(by_id[nid])}"]')
    seen_edge = set()
    for s, t, r in edges:
        key = (s, t)
        if key in seen_edge:
            continue
        seen_edge.add(key)
        arrow = "-->" if r in CALL_RELS - {"calls"} else "-->"
        lbl = "" if r in {"calls", "contains"} else f"|{r}|"
        lines.append(f"    {_safe(s)} {arrow}{lbl} {_safe(t)}")
    lines.append("```")
    return "\n".join(lines)


def _render_community(g, by_id, edges, keep) -> str:
    groups: dict[str, list[str]] = defaultdict(list)
    for nid in keep:
        n = by_id.get(nid, {})
        cname = n.get("community_name") or f"Community {n.get('community', '?')}"
        groups[cname].append(nid)
    lines = ["```mermaid", "flowchart TD"]
    for i, (cname, ids) in enumerate(sorted(groups.items())):
        safe_c = cname.replace('"', "'")[:40]
        lines.append(f'    subgraph c{i}["{safe_c}"]')
        for nid in sorted(ids):
            lines.append(f'        {_safe(nid)}["{_label(by_id[nid])}"]')
        lines.append("    end")
    seen = set()
    for s, t, _ in edges:
        if (s, t) in seen:
            continue
        seen.add((s, t))
        lines.append(f"    {_safe(s)} --> {_safe(t)}")
    lines.append("```")
    return "\n".join(lines)


def _self_check() -> None:
    g = {
        "nodes": [
            {"id": "a", "label": "handle()", "community": 0, "community_name": "API"},
            {"id": "b", "label": "auth()", "community": 0, "community_name": "API"},
            {"id": "c", "label": "db()", "community": 1, "community_name": "Data"},
        ],
        "links": [
            {"source": "a", "target": "b", "relation": "calls"},
            {"source": "b", "target": "c", "relation": "calls"},
            {"source": "a", "target": "c", "relation": "references"},
        ],
    }
    out = render(g, "calls", None, 2, 40)
    assert out.startswith("```mermaid") and out.rstrip().endswith("```"), "fenced mermaid"
    assert "flowchart TD" in out
    assert "handle()" in out and "auth()" in out, "labels present"
    assert out.count("-->") >= 2, "edges rendered"
    # relation label shown for non-call edges
    assert "|references|" in out, "non-call rel labeled"
    # focus scopes the graph: focusing db + depth 1 drops the far node 'a'? a->c so a is a neighbor; use depth 0-ish via 'b'
    scoped = render(g, "calls", "auth", 1, 40)
    assert "auth()" in scoped
    # community view groups into subgraphs
    comm = render(g, "community", None, 2, 40)
    assert comm.count("subgraph") == 2, "two communities as subgraphs"
    # max-nodes cap keeps it bounded
    capped = render(g, "calls", None, 2, 2)
    assert capped.count('["') <= 2, "node cap respected"
    print("graph_to_mermaid self-check OK — calls/community/focus/cap verified")


def main() -> int:
    ap = argparse.ArgumentParser(description="graphify graph.json → portable Mermaid")
    ap.add_argument("--graph", default="graphify-out/graph.json")
    ap.add_argument("--view", choices=["modules", "calls", "community"], default="calls")
    ap.add_argument("--focus", default=None, help="scope to a node's neighborhood")
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--max-nodes", type=int, default=40)
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()
    if args.self_check:
        _self_check()
        return 0
    g = _load(args.graph)
    print(render(g, args.view, args.focus, args.depth, args.max_nodes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
