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
    async def cards(include_archived: bool = False) -> dict[str, object]:
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

    @application.get("/recall", dependencies=[Depends(require_api_token)])
    async def recall(q: str = Query(min_length=1), limit: int = Query(10, ge=1, le=100)) -> dict[str, object]:
        return {"cards": rank_cards(q, application.state.store.list(), limit)}

    return application


app = create_app()


if __name__ == "__main__":
    import uvicorn

    loaded = Settings()
    uvicorn.run("memory.app:app", host=loaded.bind, port=loaded.port, reload=False)