import argparse
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

from adapters import claude_code, codex
from db import get_conn, init_db

SESSION_RETENTION_DAYS = 7


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _human_age(iso_ts: str) -> str:
    if not iso_ts:
        return "?"
    try:
        ts = iso_ts.rstrip("Z")
        if "+" not in ts[10:] and ts.count("-") <= 2:
            ts += "+00:00"
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        s = int((datetime.now(timezone.utc) - dt).total_seconds())
        if s < 60:
            return f"{s}s ago"
        if s < 3600:
            return f"{s // 60}m ago"
        if s < 86400:
            return f"{s // 3600}h ago"
        return f"{s // 86400}d ago"
    except Exception:
        return iso_ts[:10]


def _resolve_task(conn, name_or_id: str):
    if name_or_id.isdigit():
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (int(name_or_id),)).fetchone()
    else:
        row = conn.execute("SELECT * FROM tasks WHERE name = ?", (name_or_id,)).fetchone()
    if not row:
        print(f"Task not found: {name_or_id}", file=sys.stderr)
        sys.exit(1)
    return row


def _resolve_session(conn, sid: str):
    rows = conn.execute(
        "SELECT id, source, title FROM sessions WHERE id LIKE ?",
        (f"%{sid}%",),
    ).fetchall()
    if not rows:
        print(f"No session matches: {sid}", file=sys.stderr)
        sys.exit(1)
    if len(rows) > 1:
        print(f"Ambiguous: '{sid}' matches {len(rows)} sessions:", file=sys.stderr)
        for r in rows[:10]:
            print(f"  {r['id']} | {r['title'][:50]}", file=sys.stderr)
        sys.exit(1)
    return rows[0]


def cmd_scan(args):
    init_db()
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SESSION_RETENTION_DAYS)).isoformat()
    all_records = claude_code.scan_all() + codex.scan_all()
    fresh = [r for r in all_records if r["last_active"] and r["last_active"] >= cutoff]
    with get_conn() as conn:
        for r in fresh:
            conn.execute(
                """
                INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
                VALUES(:id, :source, :host_app, :title, :cwd, :last_active, :last_message, :raw_path)
                ON CONFLICT(id) DO UPDATE SET
                    host_app = excluded.host_app,
                    title = excluded.title,
                    cwd = excluded.cwd,
                    last_active = excluded.last_active,
                    last_message = excluded.last_message,
                    raw_path = excluded.raw_path
                """,
                r,
            )
        deleted = conn.execute(
            """
            DELETE FROM sessions
            WHERE last_active < ?
              AND id NOT IN (SELECT session_id FROM session_task_links)
            """,
            (cutoff,),
        ).rowcount
    print(f"Scanned {len(fresh)} fresh sessions (of {len(all_records)} total), pruned {deleted} stale")


def cmd_new(args):
    init_db()
    with get_conn() as conn:
        try:
            cur = conn.execute(
                "INSERT INTO tasks(name, status, created_at, updated_at) VALUES(?, 'active', ?, ?)",
                (args.name, now_iso(), now_iso()),
            )
            print(f"Created task #{cur.lastrowid}: {args.name}")
        except sqlite3.IntegrityError:
            print(f"Task '{args.name}' already exists", file=sys.stderr)
            sys.exit(1)


def cmd_tag(args):
    with get_conn() as conn:
        task = _resolve_task(conn, args.task)
        sess = _resolve_session(conn, args.session)
        conn.execute(
            "INSERT OR REPLACE INTO session_task_links(session_id, task_id, linked_at) VALUES(?, ?, ?)",
            (sess["id"], task["id"], now_iso()),
        )
        conn.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (now_iso(), task["id"]))
        print(f"Linked {sess['id']} → '{task['name']}'")


def cmd_untag(args):
    with get_conn() as conn:
        task = _resolve_task(conn, args.task)
        sess = _resolve_session(conn, args.session)
        cur = conn.execute(
            "DELETE FROM session_task_links WHERE session_id = ? AND task_id = ?",
            (sess["id"], task["id"]),
        )
        if cur.rowcount:
            print(f"Unlinked {sess['id']} from '{task['name']}'")
        else:
            print(f"No link existed", file=sys.stderr)


def cmd_note(args):
    with get_conn() as conn:
        task = _resolve_task(conn, args.task)
        conn.execute(
            "INSERT INTO notes(task_id, content, created_at) VALUES(?, ?, ?)",
            (task["id"], args.text, now_iso()),
        )
        conn.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (now_iso(), task["id"]))
        print(f"Note added to '{task['name']}'")


def cmd_done(args):
    with get_conn() as conn:
        task = _resolve_task(conn, args.task)
        conn.execute(
            "UPDATE tasks SET status = 'done', updated_at = ? WHERE id = ?",
            (now_iso(), task["id"]),
        )
        print(f"Marked done: '{task['name']}'")


def cmd_list(args):
    with get_conn() as conn:
        tasks_rows = conn.execute(
            "SELECT * FROM tasks WHERE status = 'active' ORDER BY updated_at DESC"
        ).fetchall()
        if not tasks_rows:
            print("No active tasks. `cli.py new <name>` to create one.")
            return
        print(f"{len(tasks_rows)} active task(s):\n")
        for t in tasks_rows:
            sess_rows = conn.execute(
                """
                SELECT s.* FROM sessions s
                JOIN session_task_links l ON l.session_id = s.id
                WHERE l.task_id = ? AND s.hidden_at IS NULL
                ORDER BY s.last_active DESC
                """,
                (t["id"],),
            ).fetchall()
            notes_rows = conn.execute(
                "SELECT content, created_at FROM notes WHERE task_id = ? ORDER BY created_at DESC LIMIT 3",
                (t["id"],),
            ).fetchall()
            print(f"▸ {t['name']}  ({len(sess_rows)} session(s))")
            for s in sess_rows:
                title = s["title_override"] or s["title"]
                print(f"    [{s['source']:>11}] {_human_age(s['last_active']):>8} | {title[:60]}")
            for n in notes_rows:
                print(f"    note: {n['content'][:80]}")
            print()


def cmd_sessions(args):
    with get_conn() as conn:
        if args.unlinked:
            q = """
                SELECT s.* FROM sessions s
                LEFT JOIN session_task_links l ON l.session_id = s.id
                WHERE l.session_id IS NULL
                  AND s.hidden_at IS NULL
                ORDER BY s.last_active DESC LIMIT ?
            """
        else:
            q = "SELECT * FROM sessions WHERE hidden_at IS NULL ORDER BY last_active DESC LIMIT ?"
        rows = conn.execute(q, (args.limit,)).fetchall()
        for s in rows:
            sid_short = s["id"].split(":", 1)[-1][:8]
            title = s["title_override"] or s["title"]
            print(
                f"{s['source']:>11} {sid_short}  {_human_age(s['last_active']):>8}  {title[:70]}"
            )


def main():
    p = argparse.ArgumentParser(prog="st", description="sessiontracker")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("scan", help="Scan adapters and refresh sessions DB").set_defaults(func=cmd_scan)
    sub.add_parser("list", help="List active tasks with their sessions").set_defaults(func=cmd_list)

    s = sub.add_parser("new", help="Create a task")
    s.add_argument("name")
    s.set_defaults(func=cmd_new)

    s = sub.add_parser("tag", help="Link a session to a task")
    s.add_argument("session", help="Session id (prefix or substring)")
    s.add_argument("task", help="Task name or id")
    s.set_defaults(func=cmd_tag)

    s = sub.add_parser("untag", help="Unlink a session from a task")
    s.add_argument("session")
    s.add_argument("task")
    s.set_defaults(func=cmd_untag)

    s = sub.add_parser("note", help="Add a note to a task")
    s.add_argument("task")
    s.add_argument("text")
    s.set_defaults(func=cmd_note)

    s = sub.add_parser("done", help="Mark a task done")
    s.add_argument("task")
    s.set_defaults(func=cmd_done)

    s = sub.add_parser("sessions", help="List recent sessions")
    s.add_argument("--unlinked", action="store_true", help="Only sessions not linked to any task")
    s.add_argument("--limit", type=int, default=30)
    s.set_defaults(func=cmd_sessions)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
