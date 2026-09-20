from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from memory.recall import rank_cards
from memory.store import MemoryStore


class MemoryStoreTest(unittest.TestCase):
    def test_crud_stats_and_recall(self) -> None:
        with TemporaryDirectory() as directory:
            store = MemoryStore(Path(directory) / "memory.sqlite3")
            card = store.create("FastAPI notes", "SQLite with WAL mode", ["python"])
            store.create("Flutter notes", "Streaming SSE client", ["dart"])
            store.update(card["id"], "FastAPI storage", "SQLite canonical store", ["python"])
            results = rank_cards("sqlite store", store.list())
            self.assertEqual(results[0]["id"], card["id"])
            self.assertGreater(results[0]["score"], 0)
            self.assertEqual(store.stats()["total"], 2)
            store.delete(card["id"])
            self.assertEqual(store.stats()["total"], 1)


if __name__ == "__main__":
    unittest.main()