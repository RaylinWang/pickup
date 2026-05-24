import json
import re
from pathlib import Path

CODEX_SESSIONS = Path.home() / ".codex" / "sessions"
CODEX_SESSION_INDEX = Path.home() / ".codex" / "session_index.jsonl"
ROLLOUT_RE = re.compile(
    r"rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"
)


def _is_real_user_text(text: str) -> bool:
    if not text:
        return False
    return not text.startswith(("<environment_context>", "<user_instructions>"))


def _extract_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("text")
        )
    return ""


def _summarize(text: str, limit: int = 100) -> str:
    if not text:
        return ""
    line = next((l.strip() for l in text.splitlines() if l.strip()), "")
    return line[:limit] + ("…" if len(line) > limit else "")


def _session_title(cwd: str | None, sid: str) -> str:
    index_title = _load_thread_names().get(sid)
    if index_title:
        return index_title
    return _summarize(first_meaningful_path_part(cwd) or "Codex session", 100)


def first_meaningful_path_part(cwd: str | None) -> str:
    if not cwd:
        return ""
    leaf = Path(cwd).name
    return leaf if leaf and leaf != str(Path.home().name) else cwd


def _load_thread_names() -> dict[str, str]:
    names: dict[str, str] = {}
    if not CODEX_SESSION_INDEX.exists():
        return names
    with open(CODEX_SESSION_INDEX) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            sid = d.get("id")
            name = (d.get("thread_name") or "").strip()
            if sid and name:
                names[sid] = name
    return names


def scan_session(path: Path) -> dict | None:
    m = ROLLOUT_RE.search(path.name)
    if not m:
        return None
    sid = m.group(1)
    cwd = None
    first_user_text = None
    last_timestamp = None
    last_text = None
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = d.get("type")
            p = d.get("payload") or {}
            if t in ("session_meta", "turn_context") and cwd is None:
                cwd = p.get("cwd")
            elif t == "response_item" and p.get("type") == "message":
                role = p.get("role")
                if role not in ("user", "assistant"):
                    continue
                text = _extract_text(p.get("content"))
                if role == "user" and first_user_text is None and _is_real_user_text(text):
                    first_user_text = text
                if text:
                    last_text = text
                    last_timestamp = d.get("timestamp")
    if last_timestamp is None:
        return None
    return {
        "id": f"codex:{sid}",
        "source": "codex",
        "host_app": "Codex",
        "title": _session_title(cwd, sid),
        "cwd": cwd,
        "last_active": last_timestamp,
        "last_message": _summarize(last_text or first_user_text or "", 200),
        "raw_path": str(path),
    }


def scan_all() -> list[dict]:
    if not CODEX_SESSIONS.exists():
        return []
    by_id: dict[str, dict] = {}
    for jsonl in CODEX_SESSIONS.rglob("rollout-*.jsonl"):
        rec = scan_session(jsonl)
        if not rec:
            continue
        existing = by_id.get(rec["id"])
        if not existing or rec["last_active"] > existing["last_active"]:
            by_id[rec["id"]] = rec
    return list(by_id.values())


if __name__ == "__main__":
    records = scan_all()
    print(f"Found {len(records)} Codex sessions")
    for r in sorted(records, key=lambda r: r["last_active"], reverse=True)[:5]:
        print(f"  {r['last_active'][:19]} | {r['title'][:60]}")
