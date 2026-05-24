import sqlite3
from pathlib import Path

DB_PATH = Path.home() / ".sessiontracker" / "data.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    host_app TEXT,
    title TEXT,
    title_override TEXT,
    hidden_at TEXT,
    cwd TEXT,
    last_active TEXT NOT NULL,
    last_message TEXT,
    raw_path TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);
CREATE INDEX IF NOT EXISTS idx_sessions_last_active ON sessions(last_active);

CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);

CREATE TABLE IF NOT EXISTS session_task_links (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    linked_at TEXT NOT NULL,
    PRIMARY KEY (session_id, task_id)
);

CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL
);
"""


def get_conn() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    with get_conn() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(tasks)")]
        if "description" not in cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        if "sort_order" not in cols:
            conn.execute("ALTER TABLE tasks ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
        rows = conn.execute(
            "SELECT id FROM tasks WHERE status = 'active' ORDER BY sort_order ASC, updated_at DESC, id DESC"
        ).fetchall()
        for idx, row in enumerate(rows):
            conn.execute("UPDATE tasks SET sort_order = ? WHERE id = ?", (idx * 1000, row["id"]))
        scols = [r[1] for r in conn.execute("PRAGMA table_info(sessions)")]
        if "host_app" not in scols:
            conn.execute("ALTER TABLE sessions ADD COLUMN host_app TEXT")
        if "title_override" not in scols:
            conn.execute("ALTER TABLE sessions ADD COLUMN title_override TEXT")
        if "hidden_at" not in scols:
            conn.execute("ALTER TABLE sessions ADD COLUMN hidden_at TEXT")


if __name__ == "__main__":
    init_db()
    print(f"DB initialized at {DB_PATH}")
