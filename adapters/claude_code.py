from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator

CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
CLAUDE_HISTORY = Path.home() / ".claude" / "history.jsonl"


def _read_message_events(path: Path) -> Iterator[dict]:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") in ("user", "assistant"):
                yield d


def _extract_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def _summarize(text: str, limit: int = 100) -> str:
    if not text:
        return ""
    line = next((l.strip() for l in text.splitlines() if l.strip()), "")
    return line[:limit] + ("…" if len(line) > limit else "")


def _host_from_entrypoint(entrypoint: str | None) -> str:
    if entrypoint == "claude-desktop":
        return "Claude"
    return "Ghostty"  # default for cli; refine when we can detect TERM_PROGRAM


def _session_title(host: str, cwd: str | None, sid: str, first_user_text: str | None) -> str:
    history_title = _load_history_titles().get(sid)
    if history_title:
        return history_title
    if first_user_text:
        return _summarize(first_user_text, 100)
    if cwd:
        return Path(cwd).name or cwd
    return f"{host} session"


def _load_history_titles() -> dict[str, str]:
    titles: dict[str, str] = {}
    if not CLAUDE_HISTORY.exists():
        return titles
    with open(CLAUDE_HISTORY) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            sid = d.get("sessionId")
            display = (d.get("display") or "").strip()
            if sid and display and not display.startswith(("{", "[")):
                titles.setdefault(sid, _summarize(display, 100))
    return titles


def scan_session(path: Path) -> dict | None:
    first_user_text = None
    last_event = None
    last_text = None
    entrypoint = None
    for d in _read_message_events(path):
        if first_user_text is None and d.get("type") == "user":
            text = _extract_text(d.get("message", {}))
            if text:
                first_user_text = text
        if entrypoint is None and d.get("entrypoint"):
            entrypoint = d.get("entrypoint")
        last_event = d
        text = _extract_text(d.get("message", {}))
        if text:
            last_text = text
    if last_event is None:
        return None
    sid = path.stem
    host = _host_from_entrypoint(entrypoint)
    cwd = last_event.get("cwd")
    return {
        "id": f"claude:{sid}",
        "source": "claude_code",
        "host_app": host,
        "title": _session_title(host, cwd, sid, first_user_text),
        "cwd": cwd,
        "last_active": last_event.get("timestamp"),
        "last_message": _summarize(last_text or first_user_text or "", 200),
        "raw_path": str(path),
    }


def scan_all() -> list[dict]:
    if not CLAUDE_PROJECTS.exists():
        return []
    records = []
    for jsonl in CLAUDE_PROJECTS.rglob("*.jsonl"):
        rec = scan_session(jsonl)
        if rec and rec["last_active"]:
            records.append(rec)
    return records


if __name__ == "__main__":
    records = scan_all()
    print(f"Found {len(records)} Claude Code sessions")
    for r in sorted(records, key=lambda r: r["last_active"], reverse=True)[:5]:
        print(f"  {r['last_active'][:19]} | {r['title'][:60]}")
