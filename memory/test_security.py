from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from fastapi.testclient import TestClient

from memory.app import create_app
from memory.config import Settings


class MemorySecurityTest(unittest.TestCase):
    def test_non_loopback_requires_token(self) -> None:
        with TemporaryDirectory() as directory:
            settings = Settings(data_dir=Path(directory), bind="0.0.0.0", api_token="")
            with self.assertRaises(RuntimeError):
                settings.validate()

    def test_token_protects_all_memory_routes(self) -> None:
        with TemporaryDirectory() as directory:
            app = create_app(Settings(data_dir=Path(directory), api_token="test-token"))
            with TestClient(app) as client:
                self.assertEqual(client.get("/health").status_code, 200)
                requests = [
                    ("GET", "/stats", None),
                    ("GET", "/cards", None),
                    ("GET", "/cards?ui=true", None),
                    ("GET", "/days", None),
                    ("GET", "/archive", None),
                    ("GET", "/trash", None),
                    ("GET", "/latest", None),
                    ("GET", "/mood/history?limit=20", None),
                    ("GET", "/card/1", None),
                    ("POST", "/cards", {
                        "title": "title", "content": "content", "tags": [],
                    }),
                    ("PUT", "/cards/missing", {
                        "title": "title", "content": "content", "tags": [],
                    }),
                    ("DELETE", "/cards/missing", None),
                    ("POST", "/write", {"title": "", "content": "content"}),
                    ("POST", "/update", {"card_id": 1, "content": "content"}),
                    ("POST", "/archive", {"card_id": 1, "action": "archive"}),
                    ("POST", "/trash", {"card_id": 1, "action": "trash"}),
                    ("POST", "/keywords", {
                        "card_id": 1, "action": "add", "keyword": "tag",
                    }),
                    ("GET", "/recall?q=notes", None),
                ]
                for method, path, body in requests:
                    with self.subTest(method=method, path=path):
                        response = client.request(method, path, json=body)
                        self.assertEqual(response.status_code, 401)
                response = client.get(
                    "/cards",
                    headers={"Authorization": "Bearer test-token"},
                )
                self.assertEqual(response.status_code, 200)


if __name__ == "__main__":
    unittest.main()