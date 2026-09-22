import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from fastapi.testclient import TestClient

from server.app import create_app
from server.config import Settings


def _events(response) -> list[str]:
    return [
        line.removeprefix("data: ")
        for line in response.text.splitlines()
        if line.startswith("data: ")
    ]


class ChatCompatibilityTest(unittest.TestCase):
    def _app(self, root: Path):
        return create_app(Settings(
            data_dir=root,
            api_token="test-token",
            provider_config=root / "provider.json",
            mcp_config=root / "mcp.json",
        ))

    def test_legacy_request_keeps_custom_event_contract(self) -> None:
        with TemporaryDirectory() as directory, TestClient(self._app(Path(directory))) as client:
            response = client.post(
                "/chat",
                json={"message": "hello", "conversation_id": "legacy"},
                headers={"Authorization": "Bearer test-token"},
            )
            self.assertEqual(response.status_code, 200)
            events = [json.loads(value) for value in _events(response)]
            self.assertEqual(events[0]["type"], "text")
            self.assertEqual(events[-1]["type"], "done")
            self.assertNotIn("choices", events[0])

    def test_frontend_messages_stream_and_persist_only_new_pair(self) -> None:
        with TemporaryDirectory() as directory, TestClient(self._app(Path(directory))) as client:
            headers = {"Authorization": "Bearer test-token"}
            response = client.post(
                "/chat",
                json={
                    "messages": [
                        {"role": "system", "content": "public context"},
                        {"role": "user", "content": "old question"},
                        {"role": "assistant", "content": "old answer"},
                        {"role": "user", "content": [
                            {"type": "text", "text": "你好呀"},
                            {"type": "image_url", "image_url": {"url": "ignored"}},
                        ]},
                    ],
                    "conversation_id": "frontend",
                    "model": "ignored",
                    "temperature": 0.2,
                    "client_event_id": "ignored",
                    "generation_id": "gen-test-1",
                },
                headers=headers,
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.headers.get("x-generation-id"), "gen-test-1")
            events = _events(response)
            self.assertEqual(events[-1], "[DONE]")
            chunks = [json.loads(value) for value in events[:-1]]
            visible = "".join(
                choice["delta"].get("content", "")
                for chunk in chunks
                for choice in chunk.get("choices", [])
            )
            self.assertEqual(visible.rstrip(), "Mock response: 你好呀")
            self.assertTrue(any("usage" in chunk for chunk in chunks))
            self.assertTrue(
                any(
                    chunk.get("type") == "generation_terminal"
                    and chunk.get("status") == "completed"
                    for chunk in chunks
                )
            )

            history = client.get(
                "/runtime/history/messages?conversation_id=frontend", headers=headers
            ).json()["messages"]
            self.assertEqual(
                [(item["role"], item["content"]) for item in history],
                [("user", "你好呀"), ("assistant", "Mock response: 你好呀")],
            )

    def test_frontend_chat_still_requires_token(self) -> None:
        with TemporaryDirectory() as directory, TestClient(self._app(Path(directory))) as client:
            response = client.post(
                "/chat", json={"messages": [{"role": "user", "content": "hello"}]}
            )
            self.assertEqual(response.status_code, 401)


if __name__ == "__main__":
    unittest.main()
