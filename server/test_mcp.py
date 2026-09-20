from pathlib import Path
from stat import S_IMODE
from tempfile import TemporaryDirectory
import unittest

from server.mcp_client import McpClient


class McpConfigTest(unittest.TestCase):
    def test_save_validates_server_entries_and_writes_owner_only(self) -> None:
        invalid_configs = [
            {"servers": []},
            {"servers": {"bad": []}},
            {"servers": {"bad": {"enabled": "yes", "transport": "stdio", "command": "tool"}}},
            {"servers": {"bad": {"enabled": False, "transport": "http", "url": "file:///tmp/tool"}}},
            {"servers": {"bad": {"enabled": False, "transport": "stdio", "command": "tool", "args": [1]}}},
        ]
        with TemporaryDirectory() as directory:
            path = Path(directory) / "mcp.json"
            client = McpClient(path)
            for config in invalid_configs:
                with self.subTest(config=config), self.assertRaises(ValueError):
                    client.save(config)

            client.save({
                "servers": {
                    "demo": {
                        "enabled": False,
                        "transport": "stdio",
                        "command": "tool",
                        "args": ["--demo"],
                    }
                }
            })
            self.assertEqual(S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()