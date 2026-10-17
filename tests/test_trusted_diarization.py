import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'asr_server'))
from public_diarization_models import copy_verified, checked_download_url, ensure_models


class TrustedModelTests(unittest.TestCase):
    def test_rejects_external_urls_and_credentials(self):
        for url in ['http://github.com/x', 'https://evil.invalid/model',
                    'https://github.com.evil.invalid/x', 'https://user:password@github.com/x',
                    'https://github.com:444/x', 'file:///etc/passwd']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                checked_download_url(url)
        self.assertEqual(checked_download_url('https://release-assets.githubusercontent.com/test'),
                         'https://release-assets.githubusercontent.com/test')

    def test_download_requires_explicit_confirmation(self):
        with tempfile.TemporaryDirectory() as folder, patch('public_diarization_models.download') as download:
            with self.assertRaises(ValueError):
                ensure_models(folder)
            download.assert_not_called()

    def test_copies_verified_bytes_then_rejects_tampering_and_links(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            source = root / 'weights'; source.write_bytes(b'official')
            sha = hashlib.sha256(b'official').hexdigest()
            destination = root / 'private-weights'
            copy_verified(source, destination, 8, sha)
            source.write_bytes(b'malware!')
            self.assertEqual(destination.read_bytes(), b'official')
            with self.assertRaises(ValueError):
                copy_verified(source, root / 'bad', 8, sha)
            link = root / 'link'; link.symlink_to(source)
            with self.assertRaises(ValueError):
                copy_verified(link, root / 'linked', 8, sha)
            with self.assertRaises(ValueError):
                copy_verified(source, root / 'oversize', 7, sha)
