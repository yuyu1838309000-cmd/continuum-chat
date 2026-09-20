from __future__ import annotations

import json
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .auth import require_api_token
from .config import Settings
from .mcp_client import McpClient
from .provider import ChatProvider, ProviderConfig
from .runtime_store import RuntimeStore


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=100_000)
    conversation_id: str = Field(default="default", min_length=1, max_length=100)


class EpochRequest(BaseModel):
    conversation_id: str = "default"
    context_window: int = Field(default=40, ge=1, le=500)


class EditRequest(BaseModel):
    content: str = Field(min_length=1, max_length=100_000)


class ProviderRequest(BaseModel):
    base_url: str = Field(min_length=1, max_length=2_000)
    model: str = Field(min_length=1, max_length=300)
    api_key: str = Field(default="", max_length=10_000)
    endpoint: str = Field(default="/chat/completions", min_length=1, max_length=2_000)


class McpTestRequest(BaseModel):
    server: str = Field(min_length=1, max_length=300)
    tool: str = Field(min_length=1, max_length=300)
    arguments: dict[str, Any] = Field(default_factory=dict)


def create_app(settings: Settings | None = None) -> FastAPI:
    current = settings or Settings()

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        current.validate()
        application.state.store = RuntimeStore(current.data_dir / "runtime.sqlite3")
        application.state.mcp = McpClient(current.mcp_config)
        yield

    application = FastAPI(title="Continuum Chat Runtime", version="0.1.0", lifespan=lifespan)
    application.state.settings = current
    if current.cors_origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=list(current.cors_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )

    @application.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "runtime"}

    @application.get("/config/public", dependencies=[Depends(require_api_token)])
    async def public_config() -> dict[str, Any]:
        return {"memory_url": current.memory_url, "auth_configured": bool(current.api_token)}

    @application.get("/config/provider", dependencies=[Depends(require_api_token)])
    async def get_provider() -> dict[str, Any]:
        return ProviderConfig.load(current.provider_config).public_dict()

    @application.put("/config/provider", dependencies=[Depends(require_api_token)])
    async def put_provider(body: ProviderRequest) -> dict[str, Any]:
        config = ProviderConfig(**body.model_dump())
        try:
            config.save(current.provider_config)
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        return config.public_dict()

    @application.get("/config/mcp", dependencies=[Depends(require_api_token)])
    async def get_mcp() -> dict[str, Any]:
        return application.state.mcp.load()

    @application.put("/config/mcp", dependencies=[Depends(require_api_token)])
    async def put_mcp(body: dict[str, Any]) -> dict[str, Any]:
        try:
            application.state.mcp.save(body)
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error
        return body

    @application.post("/chat", dependencies=[Depends(require_api_token)])
    async def chat(body: ChatRequest) -> StreamingResponse:
        store: RuntimeStore = application.state.store
        store.add_message(body.conversation_id, "user", body.message)
        context = store.context(body.conversation_id)
        provider = ChatProvider(ProviderConfig.load(current.provider_config))
        generation_id = str(uuid.uuid4())

        async def events() -> AsyncIterator[str]:
            text_parts: list[str] = []
            reasoning_parts: list[str] = []
            usage: dict[str, Any] = {}
            try:
                async for event in provider.stream(context):
                    if event.type == "text":
                        text_parts.append(str(event.data))
                    elif event.type == "reasoning":
                        reasoning_parts.append(str(event.data))
                    elif event.type == "usage":
                        usage.update(event.data)
                    payload = {"type": event.type, "data": event.data,
                               "generation_id": generation_id}
                    yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
                message = store.add_message(
                    body.conversation_id,
                    "assistant",
                    "".join(text_parts).rstrip(),
                    reasoning="".join(reasoning_parts),
                    generation_id=generation_id,
                    provider_usage=usage,
                )
                yield f"data: {json.dumps({'type': 'done', 'message': message}, ensure_ascii=False)}\n\n"
            except Exception as error:
                payload = {"type": "error", "error": str(error)}
                yield f"data: {json.dumps(payload)}\n\n"

        return StreamingResponse(events(), media_type="text/event-stream")

    @application.get(
        "/runtime/history/messages", dependencies=[Depends(require_api_token)]
    )
    async def history_messages(
        conversation_id: str = "default", limit: int = Query(200, ge=1, le=1000)
    ) -> dict[str, Any]:
        return {"messages": application.state.store.messages(conversation_id, limit)}

    @application.get(
        "/runtime/history/calendar", dependencies=[Depends(require_api_token)]
    )
    async def history_calendar() -> dict[str, Any]:
        return {"days": application.state.store.calendar()}

    @application.post("/runtime/epochs/rollover", dependencies=[Depends(require_api_token)])
    async def rollover(body: EpochRequest) -> dict[str, Any]:
        return application.state.store.rollover(body.conversation_id, body.context_window)

    @application.post("/runtime/events/{event_id}/edit", dependencies=[Depends(require_api_token)])
    async def edit_event(event_id: str, body: EditRequest) -> dict[str, Any]:
        try:
            return application.state.store.edit(event_id, body.content)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Event not found") from error

    @application.delete("/runtime/events/{event_id}", dependencies=[Depends(require_api_token)])
    async def delete_event(event_id: str) -> dict[str, bool]:
        try:
            application.state.store.delete(event_id)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Event not found") from error
        return {"deleted": True}

    @application.get("/mcp/tools", dependencies=[Depends(require_api_token)])
    async def mcp_tools() -> dict[str, Any]:
        try:
            return {"tools": await application.state.mcp.tools()}
        except (ValueError, RuntimeError) as error:
            raise HTTPException(status_code=502, detail=str(error)) from error

    @application.post("/mcp/test", dependencies=[Depends(require_api_token)])
    async def mcp_test(body: McpTestRequest) -> dict[str, Any]:
        try:
            result = await application.state.mcp.request(
                body.server, "tools/call", {"name": body.tool, "arguments": body.arguments}
            )
        except (ValueError, RuntimeError) as error:
            raise HTTPException(status_code=502, detail=str(error)) from error
        return {"result": result}

    return application


app = create_app()


if __name__ == "__main__":
    import uvicorn

    loaded = Settings()
    uvicorn.run("server.app:app", host=loaded.bind, port=loaded.port, reload=False)