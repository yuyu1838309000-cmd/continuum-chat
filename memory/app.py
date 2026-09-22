from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import Depends, FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

from .auth import require_api_token
from .config import Settings
from .recall import rank_cards
from .store import MemoryStore


class CardBody(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    content: str = Field(min_length=1, max_length=100_000)
    tags: list[str] = Field(default_factory=list, max_length=50)


class WriteBody(BaseModel):
    title: str = Field(default="", max_length=300)
    content: str = Field(min_length=1, max_length=100_000)
    source: str = Field(default="manual", max_length=100)


class UpdateBody(BaseModel):
    card_id: int
    expected_current_revision_id: int | None = None
    title: str | None = Field(default=None, max_length=300)
    content: str | None = Field(default=None, max_length=100_000)
    tags: str | None = None


class ArchiveBody(BaseModel):
    card_id: int
    action: str


class TrashBody(BaseModel):
    card_id: int
    action: str


class KeywordsBody(BaseModel):
    card_id: int
    action: str
    keyword: str = Field(min_length=1, max_length=100)


def create_app(settings: Settings | None = None) -> FastAPI:
    current = settings or Settings()

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        current.validate()
        application.state.store = MemoryStore(current.data_dir / "memory.sqlite3")
        yield

    application = FastAPI(title="Continuum Chat Memory", version="0.1.0", lifespan=lifespan)
    application.state.settings = current

    @application.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "memory"}

    @application.get("/stats", dependencies=[Depends(require_api_token)])
    async def stats() -> dict[str, int]:
        return application.state.store.stats()

    @application.get("/cards", dependencies=[Depends(require_api_token)])
    async def cards(
        include_archived: bool = False,
        ui: bool = False,
        include_sunk: bool = False,
    ) -> object:
        if ui:
            state = "nondeleted" if include_archived or include_sunk else "active"
            return application.state.store.list_ui(state)
        return {"cards": application.state.store.list(include_archived)}

    @application.post("/cards", status_code=201, dependencies=[Depends(require_api_token)])
    async def create_card(body: CardBody) -> dict[str, object]:
        return application.state.store.create(body.title, body.content, body.tags)

    @application.put("/cards/{card_id}", dependencies=[Depends(require_api_token)])
    async def update_card(card_id: str, body: CardBody) -> dict[str, object]:
        try:
            return application.state.store.update(card_id, body.title, body.content, body.tags)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error

    @application.delete("/cards/{card_id}", dependencies=[Depends(require_api_token)])
    async def delete_card(card_id: str) -> dict[str, bool]:
        try:
            application.state.store.delete(card_id)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error
        return {"deleted": True}

    @application.get("/days", dependencies=[Depends(require_api_token)])
    async def days() -> dict[str, list[dict[str, object]]]:
        grouped: dict[str, list[dict[str, object]]] = {}
        for card in application.state.store.list_ui("active"):
            created_at = str(card.get("created_at") or "")
            day = created_at[:10] if len(created_at) >= 10 else "unknown"
            grouped.setdefault(day, []).append(card)
        return grouped

    @application.get("/archive", dependencies=[Depends(require_api_token)])
    async def archive_list() -> list[dict[str, object]]:
        return [
            {**card, "rings": [], "reproducible": False}
            for card in application.state.store.list_ui("archive")
        ]

    @application.get("/trash", dependencies=[Depends(require_api_token)])
    async def trash_list() -> list[dict[str, object]]:
        return [
            {**card, "rings": [], "reproducible": False}
            for card in application.state.store.list_ui("trash")
        ]

    @application.get("/latest", dependencies=[Depends(require_api_token)])
    async def latest() -> dict[str, object]:
        cards = application.state.store.list_ui("active")
        if not cards:
            raise HTTPException(status_code=404, detail="No active memory cards")
        return cards[0]

    @application.get("/mood/history", dependencies=[Depends(require_api_token)])
    async def mood_history(limit: int = Query(20, ge=1, le=100)) -> list[object]:
        _ = limit
        return []

    @application.get("/card/{ui_id}", dependencies=[Depends(require_api_token)])
    async def card_detail(ui_id: int) -> dict[str, object]:
        try:
            card = application.state.store.get_ui(ui_id)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error
        return {**card, "rings": [], "reproducible": False}

    @application.post("/write", dependencies=[Depends(require_api_token)])
    async def write_memory(body: WriteBody) -> dict[str, object]:
        title = body.title.strip() or "新记忆"
        card = application.state.store.create_ui(title, body.content, [])
        return {"action": "new", "card": card}

    @application.post("/update", dependencies=[Depends(require_api_token)])
    async def update_memory(body: UpdateBody) -> dict[str, object]:
        tags = None
        if body.tags is not None:
            tags = [tag.strip() for tag in body.tags.split(",") if tag.strip()]
        try:
            return application.state.store.update_ui(
                body.card_id,
                title=body.title,
                content=body.content,
                tags=tags,
            )
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error

    @application.post("/archive", dependencies=[Depends(require_api_token)])
    async def archive_memory(body: ArchiveBody) -> dict[str, bool]:
        if body.action not in {"archive", "unarchive"}:
            raise HTTPException(status_code=400, detail="Invalid archive action")
        try:
            application.state.store.set_archived_ui(
                body.card_id,
                archived=body.action == "archive",
            )
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error
        return {"success": True}

    @application.post("/trash", dependencies=[Depends(require_api_token)])
    async def trash_memory(body: TrashBody) -> dict[str, bool]:
        if body.action not in {"trash", "restore", "purge"}:
            raise HTTPException(status_code=400, detail="Invalid trash action")
        try:
            application.state.store.trash_ui(body.card_id, body.action)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error
        return {"ok": True}

    @application.post("/keywords", dependencies=[Depends(require_api_token)])
    async def keywords_memory(body: KeywordsBody) -> dict[str, object]:
        if body.action not in {"add", "remove"}:
            raise HTTPException(status_code=400, detail="Invalid keyword action")
        try:
            card = application.state.store.get_ui(body.card_id)
            tags = [part.strip() for part in str(card.get("tags") or "").split(",") if part.strip()]
            if body.action == "add" and body.keyword not in tags:
                tags.append(body.keyword)
            if body.action == "remove":
                tags = [tag for tag in tags if tag != body.keyword]
            updated = application.state.store.update_ui(body.card_id, tags=tags)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Card not found") from error
        keywords = [part.strip() for part in str(updated.get("tags") or "").split(",") if part.strip()]
        return {"success": True, "keywords": keywords}

    @application.get("/recall", dependencies=[Depends(require_api_token)])
    async def recall(q: str = Query(min_length=1), limit: int = Query(10, ge=1, le=100)) -> dict[str, object]:
        return {"cards": rank_cards(q, application.state.store.list(), limit)}

    return application


app = create_app()


if __name__ == "__main__":
    import uvicorn

    loaded = Settings()
    uvicorn.run("memory.app:app", host=loaded.bind, port=loaded.port, reload=False)