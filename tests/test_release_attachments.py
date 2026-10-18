import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from release_source import source_files, public_path
from verify_release import verify, digest

class ReleaseAttachmentTests(unittest.TestCase):
    def test_source_inventory_excludes_private_and_media_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in ('scripts/ok.py','asr_server/session.wav','asr_server/.env','audit-20261017/log.txt','CONTINUATION.md','LICENSE'):
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
            self.assertEqual(source_files(root),['LICENSE','scripts/ok.py'])
        for name in ('../scripts/ok.py','/scripts/ok.py','scripts/build/generated.py'):
            self.assertFalse(public_path(name))

    def test_reviewed_release_rejects_changed_extra_and_stale_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'root';root.mkdir();out=base/'out';out.mkdir()
            for name,content in [('VERSION','1.0.0'),('BUILD_NUMBER','2'),('release-security.json','{}')]:
                (root/name).write_text(content)
            names={'Hermeneus-v1.0.0-Full.dmg','SECURITY_AUDIT.md','DEPENDENCIES.md','dependency-sbom.json','RELEASE_NOTES.md'}
            for name in names:(out/name).write_text('fixture')
            with zipfile.ZipFile(out/'Hermeneus-v1.0.0-Source.zip','w') as archive:
                for name in source_files(root):archive.write(root/name,name)
            manifest=dict(version='1.0.0',build='2',source_sha256='reviewed',artifacts={p.name:digest(p)for p in out.iterdir()})
            (out/'release-manifest.json').write_text(json.dumps(manifest))
            (out/'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n'for p in sorted(out.iterdir())if p.name!='SHA256SUMS'))
            with patch('verify_release.check'),patch('verify_release.fingerprint',return_value='reviewed'):
                verify(out,root)
                (out/'extra.zip').write_text('unreviewed')
                with self.assertRaises(ValueError):verify(out,root)
                (out/'extra.zip').unlink()
                (out/'Hermeneus-v1.0.0-Full.dmg').write_text('replaced')
                with self.assertRaises(ValueError):verify(out,root)
                (out/'Hermeneus-v1.0.0-Full.dmg').write_text('fixture')
                (root/'LICENSE').write_text('source modified after review')
                with self.assertRaises(ValueError):verify(out,root)
