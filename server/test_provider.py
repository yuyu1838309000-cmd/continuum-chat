from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from server.provider import ProviderConfig, _provider_events, _sse_data


async def _lines(*values: str):
    for value in values:
        yield value


class ProviderStreamTest(unittest.IsolatedAsyncioTestCase):
    async def test_sse_data_joins_multi_line_events_and_flushes_eof(self) -> None:
        values = [
            value
            async for value in _sse_data(
                _lines('data: {"choices":', 'data: []}', "", "data: [DONE]")
            )
        ]
        self.assertEqual(values, ['{"choices":\n[]}', "[DONE]"])

    async def test_provider_error_payload_is_not_silently_ignored(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "provider unavailable"):
            _provider_events({"error": {"message": "provider unavailable"}})

    async def test_provider_config_rejects_invalid_urls(self) -> None:
        with TemporaryDirectory() as directory:
            path = Path(directory) / "provider.json"
            with self.assertRaises(ValueError):
                ProviderConfig(base_url="file:///tmp/provider").save(path)


if __name__ == "__main__":
    unittest.main()