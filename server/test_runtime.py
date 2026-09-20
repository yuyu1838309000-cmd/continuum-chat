from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from server.runtime_store import RuntimeStore


class RuntimeStoreTest(unittest.TestCase):
    def test_messages_rollover_edit_delete_and_calendar(self) -> None:
        with TemporaryDirectory() as directory:
            store = RuntimeStore(Path(directory) / "runtime.sqlite3")
            first = store.add_message("demo", "user", "hello")
            store.edit(first["id"], "updated")
            assistant = store.add_message(
                "demo", "assistant", "world", provider_usage={"input_tokens": 2, "output_tokens": 3}
            )
            self.assertEqual([item["content"] for item in store.messages("demo")], ["updated", "world"])
            day = store.calendar()[0]
            self.assertEqual((day["message_count"], day["input_tokens"], day["output_tokens"]), (2, 2, 3))
            epoch = store.rollover("demo", 2)
            self.assertEqual(epoch["context_window"], 2)
            self.assertEqual(store.context("demo"), [])
            second = store.add_message("demo", "user", "second epoch")
            third = store.add_message("demo", "assistant", "reply")
            fourth = store.add_message("demo", "user", "latest")
            self.assertEqual(
                [item["content"] for item in store.context("demo")],
                ["reply", "latest"],
            )
            store.edit(fourth["id"], "latest edited")
            store.delete(third["id"])
            self.assertEqual(store.context("demo"), [
                {"role": "user", "content": "second epoch"},
                {"role": "user", "content": "latest edited"},
            ])
            store.delete(first["id"])
            self.assertEqual(
                [item["id"] for item in store.messages("demo")],
                [assistant["id"], second["id"], fourth["id"]],
            )


if __name__ == "__main__":
    unittest.main()