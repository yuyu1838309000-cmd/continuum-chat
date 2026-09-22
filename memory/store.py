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

    @staticmethod
    def _ui_card(row: sqlite3.Row) -> dict[str, Any]:
        tags = json.loads(row["tags_json"])
        archived = row["archived_at"] is not None
        deleted = row["deleted_at"] is not None
        status = "trash" if deleted else ("sunk" if archived else "active")
        return {
            "id": int(row["ui_id"]),
            "title": row["title"],
            "content": row["content"],
            "importance": 0.0,
            "tags": ",".join(tags),
            "keywords": ",".join(tags),
            "happened_at": None,
            "created_at": row["created_at"],
            "latest_activity_at": row["updated_at"],
            "latest_activity_content": row["content"],
            "latest_activity_kind": "update",
            "current_revision_id": int(row["ui_id"]),
            "status": status,
            "pinned": 0,
            "hits": 0,
            "freshness": "fresh" if status == "active" else "sunk",
        }

    def list_ui(self, state: str = "active") -> list[dict[str, Any]]:
        clauses = {
            "active": "deleted_at IS NULL AND archived_at IS NULL",
            "archive": "deleted_at IS NULL AND archived_at IS NOT NULL",
            "trash": "deleted_at IS NOT NULL",
            "all": "1=1",
            "nondeleted": "deleted_at IS NULL",
        }
        clause = clauses.get(state)
        if clause is None:
            raise ValueError(f"Unknown UI state: {state}")
        with self.connect() as db:
            rows = db.execute(
                f"SELECT rowid AS ui_id, * FROM cards WHERE {clause} ORDER BY updated_at DESC"
            ).fetchall()
            return [self._ui_card(row) for row in rows]

    def get_ui(self, ui_id: int) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute(
                "SELECT rowid AS ui_id, * FROM cards WHERE rowid=?",
                (ui_id,),
            ).fetchone()
            if row is None:
                raise KeyError(ui_id)
            return self._ui_card(row)

    def create_ui(self, title: str, content: str, tags: list[str]) -> dict[str, Any]:
        card = self.create(title, content, tags)
        with self.connect() as db:
            row = db.execute(
                "SELECT rowid AS ui_id, * FROM cards WHERE id=?",
                (card["id"],),
            ).fetchone()
            if row is None:
                raise KeyError(card["id"])
            return self._ui_card(row)

    def update_ui(
        self,
        ui_id: int,
        *,
        title: str | None = None,
        content: str | None = None,
        tags: list[str] | None = None,
    ) -> dict[str, Any]:
        with self.connect() as db:
            row = db.execute(
                "SELECT rowid AS ui_id, * FROM cards WHERE rowid=? AND deleted_at IS NULL",
                (ui_id,),
            ).fetchone()
            if row is None:
                raise KeyError(ui_id)
            next_title = row["title"] if title is None else title
            next_content = row["content"] if content is None else content
            next_tags = json.loads(row["tags_json"]) if tags is None else tags
            db.execute(
                "UPDATE cards SET title=?,content=?,tags_json=?,updated_at=? "
                "WHERE rowid=? AND deleted_at IS NULL",
                (
                    next_title,
                    next_content,
                    json.dumps(next_tags, ensure_ascii=False),
                    utc_now(),
                    ui_id,
                ),
            )
            updated = db.execute(
                "SELECT rowid AS ui_id, * FROM cards WHERE rowid=?",
                (ui_id,),
            ).fetchone()
            if updated is None:
                raise KeyError(ui_id)
            return self._ui_card(updated)

    def set_archived_ui(self, ui_id: int, archived: bool) -> dict[str, Any]:
        now = utc_now()
        with self.connect() as db:
            cursor = db.execute(
                "UPDATE cards SET archived_at=?,updated_at=? "
                "WHERE rowid=? AND deleted_at IS NULL",
                (now if archived else None, now, ui_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(ui_id)
        return self.get_ui(ui_id)

    def trash_ui(self, ui_id: int, action: str) -> None:
        now = utc_now()
        with self.connect() as db:
            if action == "trash":
                cursor = db.execute(
                    "UPDATE cards SET deleted_at=?,updated_at=? "
                    "WHERE rowid=? AND deleted_at IS NULL",
                    (now, now, ui_id),
                )
            elif action == "restore":
                cursor = db.execute(
                    "UPDATE cards SET deleted_at=NULL,updated_at=? "
                    "WHERE rowid=? AND deleted_at IS NOT NULL",
                    (now, ui_id),
                )
            elif action == "purge":
                cursor = db.execute(
                    "DELETE FROM cards WHERE rowid=? AND deleted_at IS NOT NULL",
                    (ui_id,),
                )
            else:
                raise ValueError(action)
            if cursor.rowcount == 0:
                raise KeyError(ui_id)

    def stats(self) -> dict[str, int]:
        with self.connect() as db:
            row = db.execute(
                "SELECT "
                "SUM(deleted_at IS NULL) total, "
                "SUM(deleted_at IS NULL AND archived_at IS NOT NULL) archived, "
                "SUM(deleted_at IS NULL AND archived_at IS NULL) fresh "
                "FROM cards"
            ).fetchone()
            total = int(row["total"] or 0)
            archived = int(row["archived"] or 0)
            fresh = int(row["fresh"] or 0)
            return {
                "total": total,
                "archived": archived,
                "fresh": fresh,
                "sunk": archived,
                "rings": 0,
            }
