import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'vendor_ollama.py'
spec = importlib.util.spec_from_file_location('vendor_ollama', SCRIPT)
vendor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vendor)


class VendorOllamaTests(unittest.TestCase):
    def archive(self, root, extra=None):
        archive = root / 'test.tgz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ['ollama', 'llama-server', 'mlx_metal_v3/libmlx.dylib']:
                item = tarfile.TarInfo(name)
                item.size = 4
                tar.addfile(item, io.BytesIO(b'test'))
            if extra:
                tar.addfile(extra)
        return archive

    def test_bundles_libraries_and_preserves_runtime_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self.archive(root)
            destination = root / 'runtime'
            with patch.object(vendor, 'SHA256', hashlib.sha256(archive.read_bytes()).hexdigest()):
                vendor.extract_verified(archive, destination)
            self.assertTrue((destination / 'mlx_metal_v3/libmlx.dylib').is_file())
            self.assertTrue((destination / 'ollama').stat().st_mode & 0o111)
            self.assertTrue((destination / 'runtime.json').is_file())

    def test_ignores_appledouble_sidecars_that_dmg_would_remove(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self.archive(root, tarfile.TarInfo('mlx_metal_v3/._mlx.metallib'))
            with patch.object(vendor, 'SHA256', hashlib.sha256(archive.read_bytes()).hexdigest()):
                vendor.extract_verified(archive, root / 'runtime')
            self.assertFalse((root / 'runtime/mlx_metal_v3/._mlx.metallib').exists())

    def test_rejects_modified_archive_before_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self.archive(root)
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                vendor.extract_verified(archive, root / 'runtime')
            self.assertFalse((root / 'runtime').exists())

    def test_rejects_escaping_path_and_symlink(self):
        for kind in ['path', 'symlink']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                item = tarfile.TarInfo('../escape' if kind == 'path' else 'escape')
                if kind == 'symlink':
                    item.type = tarfile.SYMTYPE
                    item.linkname = '/tmp/escape'
                archive = self.archive(root, item)
                with patch.object(vendor, 'SHA256', hashlib.sha256(archive.read_bytes()).hexdigest()):
                    with self.assertRaisesRegex(ValueError, 'Unsafe'):
                        vendor.extract_verified(archive, root / 'runtime')



class PatchedRuntimeTests(unittest.TestCase):
    def test_rejects_cli_that_does_not_match_provenance(self):
        import json
        import sys
        sys.path.insert(0, str(SCRIPT.parent))
        from rebuild_ollama import SOURCE_COMMIT, SOURCE_SHA256, GO_VERSION, REVISION, ROOT, digest
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); destination=root/'runtime';destination.mkdir()
            (destination/'runtime.json').write_text('{}')
            cli=root/'ollama';cli.write_bytes(b'validated-cli')
            metadata=dict(native_patch_sha256=__import__('ollama_patches').native_patch_digest(ROOT), security_patch_sha256=digest(ROOT/'runtime/ollama/hermeneus_security.go'), revision=REVISION, source_commit=SOURCE_COMMIT, source_sha256=SOURCE_SHA256,
                go_version=GO_VERSION, minimum_macos='14.0', architecture='arm64', cli_sha256=digest(cli),
                go_mod_sha256=digest(ROOT/'runtime/ollama/go.mod'), go_sum_sha256=digest(ROOT/'runtime/ollama/go.sum'))
            record=root/'build.json';record.write_text(json.dumps(metadata))
            vendor.apply_security_revision(destination,cli,record)
            self.assertEqual((destination/'ollama').read_bytes(),b'validated-cli')
            cli.write_bytes(b'modified-cli')
            with self.assertRaisesRegex(ValueError,'pinned security build'):
                vendor.apply_security_revision(destination,cli,record)
            self.assertEqual((destination/'ollama').read_bytes(),b'validated-cli')

class NativeRuntimeTests(unittest.TestCase):
    def test_rejects_unverified_native_payload_and_rpc(self):
        import json, sys
        sys.path.insert(0, str(SCRIPT.parent))
        from rebuild_ollama import SOURCE_COMMIT, SOURCE_SHA256, ROOT, digest
        from rebuild_native_ollama import LLAMA_COMMIT, LLAMA_SHA256, CMAKE_VERSION
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);runtime=root/'runtime';runtime.mkdir()
            (runtime/'runtime.json').write_text('{}')
            runner=root/'runner';runner.write_bytes(b'verified-native-runner')
            metadata=dict(ollama_source_commit=SOURCE_COMMIT,ollama_source_sha256=SOURCE_SHA256,
                llama_commit=LLAMA_COMMIT,llama_archive_sha256=LLAMA_SHA256,
                runner_sha256=digest(runner),minimum_macos='14.0',architecture='arm64',
                rpc_enabled=False,metal_enabled=True,cmake_version=CMAKE_VERSION,gif_disabled=True,
                recipe_sha256=digest(ROOT/'scripts/rebuild_native_ollama.py'))
            record=root/'native.json';record.write_text(json.dumps(metadata))
            vendor.apply_native_revision(runtime,runner,record)
            self.assertEqual((runtime/'llama-server').read_bytes(),b'verified-native-runner')
            metadata['gif_disabled']=False;record.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError,'GIF decoder'):
                vendor.apply_native_revision(runtime,runner,record)
            metadata['gif_disabled']=True
            metadata['rpc_enabled']=True;record.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError,'pinned source build'):
                vendor.apply_native_revision(runtime,runner,record)
            metadata['rpc_enabled']=False;record.write_text(json.dumps(metadata))
            runner.write_bytes(b'modified-native-runner')
            with self.assertRaisesRegex(ValueError,'pinned source build'):
                vendor.apply_native_revision(runtime,runner,record)
            self.assertEqual((runtime/'llama-server').read_bytes(),b'verified-native-runner')

if __name__ == '__main__': unittest.main()
