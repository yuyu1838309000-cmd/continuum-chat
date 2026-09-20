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


class MemoryStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        with self.connect() as db:
            db.execute(
                """CREATE TABLE IF NOT EXISTS cards (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    archived_at TEXT,
                    deleted_at TEXT
                )"""
            )

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        try:
            yield db
            db.commit()
        finally:
            db.close()

    @staticmethod
    def _card(row: sqlite3.Row) -> dict[str, Any]:
        card = dict(row)
        card["tags"] = json.loads(card.pop("tags_json"))
        return card

    def create(self, title: str, content: str, tags: list[str]) -> dict[str, Any]:
        card_id, now = str(uuid.uuid4()), utc_now()
        with self.connect() as db:
            db.execute(
                "INSERT INTO cards(id,title,content,tags_json,created_at,updated_at) VALUES(?,?,?,?,?,?)",
                (card_id, title, content, json.dumps(tags, ensure_ascii=False), now, now),
            )
            return self.get(card_id, db=db)

    def get(self, card_id: str, *, db: sqlite3.Connection | None = None) -> dict[str, Any]:
        if db is None:
            with self.connect() as connection:
                return self.get(card_id, db=connection)
        row = db.execute(
            "SELECT * FROM cards WHERE id=? AND deleted_at IS NULL", (card_id,)
        ).fetchone()
        if row is None:
            raise KeyError(card_id)
        return self._card(row)

    def list(self, include_archived: bool = False) -> list[dict[str, Any]]:
        clause = "deleted_at IS NULL" if include_archived else "deleted_at IS NULL AND archived_at IS NULL"
        with self.connect() as db:
            rows = db.execute(f"SELECT * FROM cards WHERE {clause} ORDER BY updated_at DESC").fetchall()
            return [self._card(row) for row in rows]

    def update(self, card_id: str, title: str, content: str, tags: list[str]) -> dict[str, Any]:
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE cards SET title=?,content=?,tags_json=?,updated_at=? "
                "WHERE id=? AND deleted_at IS NULL",
                (title, content, json.dumps(tags, ensure_ascii=False), utc_now(), card_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(card_id)
            return self.get(card_id, db=db)

    def delete(self, card_id: str) -> None:
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE cards SET deleted_at=?,updated_at=? WHERE id=? AND deleted_at IS NULL",
                (utc_now(), utc_now(), card_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(card_id)

    def stats(self) -> dict[str, int]:
        with self.connect() as db:
            row = db.execute(
                "SELECT COUNT(*) total, SUM(archived_at IS NOT NULL) archived "
                "FROM cards WHERE deleted_at IS NULL"
            ).fetchone()
            return {"total": int(row["total"] or 0), "archived": int(row["archived"] or 0)}