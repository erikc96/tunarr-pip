import base64
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / 'tunarrd'))

from bus import Bus


class PanelBusTests(unittest.TestCase):
    def test_panel_asset_replaces_font_marker(self):
        root = ROOT
        rendered = (root / 'panel.html').read_text().replace(
            '{{FONT}}', base64.b64encode((root / 'vt323.woff2').read_bytes()).decode())
        self.assertNotIn('{{FONT}}', rendered)
        self.assertIn('data:font/woff2;base64,', rendered)

    def test_stateful_events_replay_in_ready_order(self):
        bus = Bus()
        bus.emit('tab', 'vhs')
        bus.emit('casts', ['Living room'])
        bus.emit('now', 'CH 8')
        bus.emit('surf', 'SURF', False)
        client = bus.connect()
        self.assertEqual(
            [client.get_nowait().split('\n', 1)[0] for _ in range(4)],
            ['event: tab', 'event: casts', 'event: now', 'event: surf'],
        )


if __name__ == '__main__':
    unittest.main()
