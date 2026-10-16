"""The distributed ZIP must install directly into Interface/AddOns."""
import importlib.util
from pathlib import Path, PurePosixPath
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('addon_package', ROOT / 'addon/package.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class AddonPackageTests(unittest.TestCase):
    def test_release_has_matching_folder_toc_and_all_runtime_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = PACKAGE.package(Path(temporary))
            first = destination.read_bytes()
            self.assertEqual(PACKAGE.package(Path(temporary)).read_bytes(), first)
            with zipfile.ZipFile(destination) as archive:
                names = archive.namelist()
                self.assertEqual({PurePosixPath(name).parts[0] for name in names}, {'Goldbook'})
                self.assertIn('Goldbook/Goldbook.toc', names)
                self.assertIn('Goldbook/LICENSE', names)
                toc = archive.read('Goldbook/Goldbook.toc').decode()
                for line in toc.splitlines():
                    line = line.strip()
                    if line and not line.startswith('#'):
                        self.assertIn('Goldbook/' + line.replace('\\', '/'), names)
                for name in names:
                    self.assertNotIn('/tests/', name)
                    self.assertNotIn('/.github/', name)
                archive.extractall(temporary)
            self.assertTrue((Path(temporary) / 'Goldbook/Goldbook.toc').is_file())

    def test_missing_runtime_file_is_rejected_before_writing_a_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / 'Goldbook').mkdir()
            (source / 'Goldbook/Goldbook.toc').write_text('## Version: 1.2.3\nMissing.lua\n')
            (source / 'LICENSE').write_text('All rights reserved.')
            with self.assertRaisesRegex(ValueError, 'TOC references a missing file: Missing.lua'):
                PACKAGE.package(source / 'output', source)
            self.assertFalse((source / 'output').exists())
