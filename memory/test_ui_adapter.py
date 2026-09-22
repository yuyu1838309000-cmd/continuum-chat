from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from fastapi.testclient import TestClient

from memory.app import create_app
from memory.config import Settings


class MemoryUiAdapterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.app = create_app(
            Settings(data_dir=Path(self.temp.name), bind="127.0.0.1", api_token="")
        )
        self.client_context = TestClient(self.app)
        self.client = self.client_context.__enter__()

    def tearDown(self) -> None:
        self.client_context.__exit__(None, None, None)
        self.temp.cleanup()

    def _create_legacy_card(self) -> dict[str, object]:
        response = self.client.post(
            "/cards",
            json={
                "title": "Reference memory",
                "content": "Synthetic public test content",
                "tags": ["demo", "safe"],
            },
        )
        self.assertEqual(response.status_code, 201)
        return response.json()

    def test_legacy_cards_contract_is_preserved(self) -> None:
        created = self._create_legacy_card()
        response = self.client.get("/cards")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertIsInstance(payload, dict)
        self.assertIn("cards", payload)
        self.assertEqual(payload["cards"][0]["id"], created["id"])

    def test_read_adapter_shapes(self) -> None:
        self._create_legacy_card()

        response = self.client.get("/cards?ui=true")
        self.assertEqual(response.status_code, 200)
        cards = response.json()
        self.assertEqual(len(cards), 1)
        card = cards[0]
        self.assertIsInstance(card["id"], int)
        self.assertEqual(card["title"], "Reference memory")
        self.assertEqual(card["tags"], "demo,safe")

        ui_id = card["id"]
        days = self.client.get("/days").json()
        self.assertEqual(len(days), 1)
        self.assertEqual(next(iter(days.values()))[0]["id"], ui_id)

        latest = self.client.get("/latest")
        self.assertEqual(latest.status_code, 200)
        self.assertEqual(latest.json()["id"], ui_id)

        detail = self.client.get(f"/card/{ui_id}")
        self.assertEqual(detail.status_code, 200)
        self.assertEqual(detail.json()["rings"], [])
        self.assertFalse(detail.json()["reproducible"])

        mood = self.client.get("/mood/history?limit=20")
        self.assertEqual(mood.status_code, 200)
        self.assertEqual(mood.json(), [])

        stats = self.client.get("/stats").json()
        self.assertEqual(stats["total"], 1)
        self.assertEqual(stats["fresh"], 1)
        self.assertEqual(stats["sunk"], 0)
        self.assertEqual(stats["rings"], 0)

    def test_write_update_keywords_archive_and_trash(self) -> None:
        write = self.client.post(
            "/write",
            json={"title": "", "content": "Created through UI adapter", "source": "manual"},
        )
        self.assertEqual(write.status_code, 200)
        self.assertEqual(write.json()["action"], "new")

        cards = self.client.get("/cards?ui=true").json()
        self.assertEqual(len(cards), 1)
        ui_id = cards[0]["id"]

        updated = self.client.post(
            "/update",
            json={
                "card_id": ui_id,
                "expected_current_revision_id": ui_id,
                "title": "Updated title",
                "content": "Updated content",
                "tags": "alpha,beta",
            },
        )
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(updated.json()["title"], "Updated title")
        self.assertEqual(updated.json()["tags"], "alpha,beta")

        keywords = self.client.post(
            "/keywords",
            json={"card_id": ui_id, "action": "add", "keyword": "gamma"},
        )
        self.assertEqual(keywords.status_code, 200)
        self.assertEqual(keywords.json()["keywords"], ["alpha", "beta", "gamma"])

        archived = self.client.post(
            "/archive", json={"card_id": ui_id, "action": "archive"}
        )
        self.assertEqual(archived.status_code, 200)
        self.assertEqual(self.client.get("/cards?ui=true").json(), [])
        archive_list = self.client.get("/archive").json()
        self.assertEqual(archive_list[0]["id"], ui_id)

        unarchived = self.client.post(
            "/archive", json={"card_id": ui_id, "action": "unarchive"}
        )
        self.assertEqual(unarchived.status_code, 200)

        trashed = self.client.post(
            "/trash", json={"card_id": ui_id, "action": "trash"}
        )
        self.assertEqual(trashed.status_code, 200)
        trash_list = self.client.get("/trash").json()
        self.assertEqual(trash_list[0]["id"], ui_id)

        restored = self.client.post(
            "/trash", json={"card_id": ui_id, "action": "restore"}
        )
        self.assertEqual(restored.status_code, 200)
        self.assertEqual(len(self.client.get("/cards?ui=true").json()), 1)


if __name__ == "__main__":
    unittest.main()
