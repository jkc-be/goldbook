"""The release.json WowUp reads to pick the ZIP for each game flavor."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('addon_package', Path(__file__).resolve().parents[1] / 'package.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ReleaseMetadataTests(unittest.TestCase):
    def source(self, root, interface):
        (root / 'Goldbook').mkdir()
        (root / 'Goldbook/Goldbook.toc').write_text(f'## Interface: {interface}\n## Version: 1.2.3\nCore.lua\n')
        (root / 'Goldbook/Core.lua').write_text('')
        (root / 'LICENSE').write_text('All rights reserved.')
        return root

    def test_forever_zip_is_described_next_to_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.source(Path(temporary), '16001')
            archive = PACKAGE.package(root / 'dist', root)
            self.assertEqual(archive.name, 'Goldbook-1.2.3.zip')
            self.assertEqual(json.loads((root / 'dist/release.json').read_text()), {'releases': [{
                'name': 'Goldbook', 'version': '1.2.3', 'filename': 'Goldbook-1.2.3.zip', 'nolib': False,
                'metadata': [{'flavor': 'forever', 'interface': 16001}],
            }]})

    def test_each_interface_gets_its_flavor(self):
        metadata = PACKAGE.release_metadata('## Interface: 11507, 16001, 50500, 110200\n', '1.2.3')
        self.assertEqual(metadata['releases'][0]['metadata'], [
            {'flavor': 'classic', 'interface': 11507}, {'flavor': 'forever', 'interface': 16001},
            {'flavor': 'mists', 'interface': 50500}, {'flavor': 'mainline', 'interface': 110200},
        ])

    def test_unknown_interface_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.source(Path(temporary), '90001')
            with self.assertRaisesRegex(ValueError, 'No release.json flavor for interface 90001'):
                PACKAGE.package(root / 'dist', root)
            self.assertFalse((root / 'dist').exists())


if __name__ == '__main__':
    unittest.main()
