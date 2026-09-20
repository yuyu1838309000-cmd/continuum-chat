from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from fastapi.testclient import TestClient

from server.app import create_app
from server.config import Settings


class RuntimeSecurityTest(unittest.TestCase):
    def test_non_loopback_requires_token(self) -> None:
        with TemporaryDirectory() as directory:
            settings = Settings(data_dir=Path(directory), bind="0.0.0.0", api_token="")
            with self.assertRaises(RuntimeError):
                settings.validate()

    def test_token_protects_all_runtime_routes(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            app = create_app(Settings(
                data_dir=root,
                api_token="test-token",
                provider_config=root / "provider.json",
                mcp_config=root / "mcp.json",
            ))
            with TestClient(app) as client:
                self.assertEqual(client.get("/health").status_code, 200)
                requests = [
                    ("GET", "/config/public", None),
                    ("GET", "/config/provider", None),
                    ("PUT", "/config/provider", {
                        "base_url": "mock://local", "model": "mock",
                    }),
                    ("GET", "/config/mcp", None),
                    ("PUT", "/config/mcp", {"servers": {}}),
                    ("POST", "/chat", {"message": "hello"}),
                    ("GET", "/runtime/history/messages", None),
                    ("GET", "/runtime/history/calendar", None),
                    ("POST", "/runtime/epochs/rollover", {}),
                    ("POST", "/runtime/events/missing/edit", {"content": "edited"}),
                    ("DELETE", "/runtime/events/missing", None),
                    ("GET", "/mcp/tools", None),
                    ("POST", "/mcp/test", {
                        "server": "missing", "tool": "missing", "arguments": {},
                    }),
                ]
                for method, path, body in requests:
                    with self.subTest(method=method, path=path):
                        response = client.request(method, path, json=body)
                        self.assertEqual(response.status_code, 401)
                response = client.get(
                    "/runtime/history/messages",
                    headers={"Authorization": "Bearer test-token"},
                )
                self.assertEqual(response.status_code, 200)

    def test_cors_has_no_default_wildcard(self) -> None:
        with TemporaryDirectory() as directory:
            app = create_app(Settings(data_dir=Path(directory)))
            with TestClient(app) as client:
                response = client.get(
                    "/health", headers={"Origin": "https://example.test"}
                )
                self.assertNotIn("access-control-allow-origin", response.headers)


if __name__ == "__main__":
    unittest.main()