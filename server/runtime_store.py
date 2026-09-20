from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class RuntimeStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.init_schema()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def init_schema(self) -> None:
        with self.connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS epochs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    ordinal INTEGER NOT NULL,
                    context_window INTEGER NOT NULL DEFAULT 40,
                    created_at TEXT NOT NULL,
                    closed_at TEXT
                );
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    epoch_id TEXT NOT NULL REFERENCES epochs(id),
                    role TEXT NOT NULL CHECK(role IN ('user','assistant','system','tool')),
                    content TEXT NOT NULL,
                    reasoning TEXT NOT NULL DEFAULT '',
                    generation_id TEXT,
                    created_at TEXT NOT NULL,
                    provider_usage_json TEXT NOT NULL DEFAULT '{}',
                    deleted_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_messages_conversation_created
                ON messages(conversation_id, created_at);
                """
            )

    def _ensure_conversation(self, db: sqlite3.Connection, conversation_id: str) -> str:
        row = db.execute(
            "SELECT id FROM conversations WHERE id = ?", (conversation_id,)
        ).fetchone()
        if row is None:
            now = utc_now()
            db.execute(
                "INSERT INTO conversations(id,title,created_at) VALUES(?,?,?)",
                (conversation_id, "Conversation", now),
            )
            epoch_id = str(uuid.uuid4())
            db.execute(
                "INSERT INTO epochs(id,conversation_id,ordinal,created_at) VALUES(?,?,1,?)",
                (epoch_id, conversation_id, now),
            )
            return epoch_id
        epoch = db.execute(
            "SELECT id FROM epochs WHERE conversation_id=? AND closed_at IS NULL "
            "ORDER BY ordinal DESC LIMIT 1",
            (conversation_id,),
        ).fetchone()
        if epoch is None:
            return self._new_epoch(db, conversation_id, 40)
        return str(epoch["id"])

    def _new_epoch(
        self, db: sqlite3.Connection, conversation_id: str, context_window: int
    ) -> str:
        now = utc_now()
        db.execute(
            "UPDATE epochs SET closed_at=? WHERE conversation_id=? AND closed_at IS NULL",
            (now, conversation_id),
        )
        ordinal = db.execute(
            "SELECT COALESCE(MAX(ordinal),0)+1 FROM epochs WHERE conversation_id=?",
            (conversation_id,),
        ).fetchone()[0]
        epoch_id = str(uuid.uuid4())
        db.execute(
            "INSERT INTO epochs(id,conversation_id,ordinal,context_window,created_at) "
            "VALUES(?,?,?,?,?)",
            (epoch_id, conversation_id, ordinal, context_window, now),
        )
        return epoch_id

    def rollover(self, conversation_id: str, context_window: int = 40) -> dict[str, Any]:
        if not 1 <= context_window <= 500:
            raise ValueError("context_window must be between 1 and 500")
        with self.connect() as db:
            self._ensure_conversation(db, conversation_id)
            epoch_id = self._new_epoch(db, conversation_id, context_window)
            return dict(
                db.execute("SELECT * FROM epochs WHERE id=?", (epoch_id,)).fetchone()
            )

    def add_message(
        self,
        conversation_id: str,
        role: str,
        content: str,
        *,
        reasoning: str = "",
        generation_id: str | None = None,
        provider_usage: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        with self.connect() as db:
            epoch_id = self._ensure_conversation(db, conversation_id)
            message_id = str(uuid.uuid4())
            db.execute(
                "INSERT INTO messages(id,conversation_id,epoch_id,role,content,reasoning,"
                "generation_id,created_at,provider_usage_json) VALUES(?,?,?,?,?,?,?,?,?)",
                (
                    message_id,
                    conversation_id,
                    epoch_id,
                    role,
                    content,
                    reasoning,
                    generation_id,
                    utc_now(),
                    json.dumps(provider_usage or {}, ensure_ascii=False),
                ),
            )
            return self.get_message(message_id, db=db)

    def get_message(
        self, message_id: str, *, db: sqlite3.Connection | None = None
    ) -> dict[str, Any]:
        if db is None:
            with self.connect() as connection:
                return self.get_message(message_id, db=connection)
        row = db.execute("SELECT * FROM messages WHERE id=?", (message_id,)).fetchone()
        if row is None:
            raise KeyError(message_id)
        return self._message(row)

    @staticmethod
    def _message(row: sqlite3.Row) -> dict[str, Any]:
        item = dict(row)
        item["provider_usage"] = json.loads(item.pop("provider_usage_json"))
        return item

    def messages(self, conversation_id: str = "default", limit: int = 200) -> list[dict[str, Any]]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT * FROM messages WHERE conversation_id=? AND deleted_at IS NULL "
                "ORDER BY created_at ASC LIMIT ?",
                (conversation_id, min(max(limit, 1), 1000)),
            ).fetchall()
            return [self._message(row) for row in rows]

    def context(self, conversation_id: str) -> list[dict[str, str]]:
        with self.connect() as db:
            epoch = db.execute(
                "SELECT id,context_window FROM epochs WHERE conversation_id=? "
                "AND closed_at IS NULL ORDER BY ordinal DESC LIMIT 1",
                (conversation_id,),
            ).fetchone()
            if epoch is None:
                return []
            rows = db.execute(
                "SELECT role,content FROM messages WHERE epoch_id=? AND deleted_at IS NULL "
                "ORDER BY created_at DESC LIMIT ?",
                (epoch["id"], epoch["context_window"]),
            ).fetchall()
            return [dict(row) for row in reversed(rows)]

    def edit(self, message_id: str, content: str) -> dict[str, Any]:
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE messages SET content=? WHERE id=? AND deleted_at IS NULL",
                (content, message_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(message_id)
            return self.get_message(message_id, db=db)

    def delete(self, message_id: str) -> None:
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE messages SET deleted_at=? WHERE id=? AND deleted_at IS NULL",
                (utc_now(), message_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(message_id)

    def calendar(self) -> list[dict[str, Any]]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT substr(created_at,1,10) day, provider_usage_json "
                "FROM messages WHERE deleted_at IS NULL ORDER BY day"
            ).fetchall()
        totals: dict[str, dict[str, Any]] = {}
        for row in rows:
            item = totals.setdefault(
                row["day"],
                {"day": row["day"], "message_count": 0, "provider_usage_count": 0,
                 "input_tokens": 0, "output_tokens": 0},
            )
            item["message_count"] += 1
            usage = json.loads(row["provider_usage_json"])
            if usage:
                item["provider_usage_count"] += 1
                item["input_tokens"] += int(usage.get("prompt_tokens", usage.get("input_tokens", 0)))
                item["output_tokens"] += int(usage.get("completion_tokens", usage.get("output_tokens", 0)))
        return list(totals.values())