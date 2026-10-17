import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'asr_server'))
from asr_security import authorized, local_ollama_url
from secure_paths import job_identifier, contained, atomic_private_text


class IPCBoundaryTests(unittest.TestCase):
    def test_only_native_authenticated_loopback_requests(self):
        token = 'a' * 44
        self.assertTrue(authorized('127.0.0.1', '127.0.0.1:8080', None, 'Bearer ' + token, token, 8080))
        for peer, host, origin, header in [
            ('127.0.0.1', '127.0.0.1:8080', 'https://evil.example', 'Bearer ' + token),
            ('127.0.0.1', 'evil.example:8080', None, 'Bearer ' + token),
            ('192.0.2.1', '127.0.0.1:8080', None, 'Bearer ' + token),
            ('127.0.0.1', '127.0.0.1:8080', None, None),
            ('127.0.0.1', '127.0.0.1:8080', None, 'Bearer wrong'),
        ]:
            with self.subTest(peer=peer, host=host, origin=origin):
                self.assertFalse(authorized(peer, host, origin, header, token, 8080))

    def test_offline_translation_rejects_remote_or_credential_urls(self):
        self.assertEqual(local_ollama_url('http://127.0.0.1:11434/api/generate'), 'http://127.0.0.1:11434/api/generate')
        for url in ['https://evil.example/api/generate', 'http://127.0.0.1.evil.example/api/generate',
                    'http://user:pass@127.0.0.1/api/generate', 'http://127.0.0.1/other',
                    'http://127.0.0.1/api/generate?secret=x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                local_ollama_url(url)

    def test_offline_capability_is_sent_only_to_expected_port(self):
        from unittest.mock import patch
        tree = ast.parse((ROOT / 'asr_server/offline_batch_worker.py').read_text())
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in {'ollama_headers', 'translate_local', 'ensure_local_ollama'}]
        captured = []
        class Result:
            def raise_for_status(self): pass
            def json(self): return {'response': 'hola', 'models': [{'name': 'model'}]}
        class Client:
            def get(self, url, **kwargs):
                captured.append((url, kwargs))
                return Result()
            def post(self, url, **kwargs):
                captured.append((url, kwargs))
                return Result()
        namespace = {'os': os, 'HTTP': Client(), 'local_ollama_url': local_ollama_url}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(ROOT), 'exec'), namespace)
        with patch.dict(os.environ, {'HERMENEUS_OLLAMA_TOKEN': 'test-capability', 'HERMENEUS_OLLAMA_PORT': '54321'}):
            for port in (54321, 54322):
                namespace['translate_local']('你好', 'model', f'http://127.0.0.1:{port}/api/generate', '中文', '西语')
            with self.assertRaises(ValueError):
                namespace['translate_local']('你好', 'model', 'http://attacker.invalid:54321/api/generate', '中文', '西语')
        self.assertEqual(captured[0][1]['headers'], {'Authorization': 'Bearer test-capability'})
        self.assertEqual(captured[1][1]['headers'], {})
        self.assertEqual(len(captured), 2)
        self.assertFalse(captured[0][1]['allow_redirects'])
        captured.clear()
        with patch.dict(os.environ, {'HERMENEUS_OLLAMA_TOKEN': 'test-capability', 'HERMENEUS_OLLAMA_PORT': '54321'}):
            for port in (54321, 54322):
                namespace['ensure_local_ollama']('model', f'http://127.0.0.1:{port}/api/generate')
        self.assertEqual(captured[0][1]['headers'], {'Authorization': 'Bearer test-capability'})
        self.assertEqual(captured[1][1]['headers'], {})
        self.assertFalse(captured[0][1]['allow_redirects'])

    def test_wsgi_rejects_before_parsing_uploaded_body(self):
        tree = ast.parse((ROOT / 'asr_server/server.py').read_text())
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'secure_http_app')
        invoked = []
        env = {'authorized': authorized, 'IPC_TOKEN': 'a' * 44, 'HTTP_PORT': 8080,
               'MAX_HTTP_REQUEST_BYTES': 1024, 'default_app': lambda: lambda e, s: invoked.append(True) or [b'ok']}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(ROOT), 'exec'), env)
        request = {'REMOTE_ADDR': '127.0.0.1', 'HTTP_HOST': '127.0.0.1:8080',
                   'HTTP_AUTHORIZATION': 'Bearer ' + 'a' * 44, 'REQUEST_METHOD': 'POST', 'CONTENT_LENGTH': '999999999'}
        result = []
        env['secure_http_app'](request, lambda status, headers: result.append(status))
        self.assertEqual(result, ['413 Payload Too Large'])
        self.assertFalse(invoked)
        request['CONTENT_LENGTH'] = '10'
        self.assertEqual(env['secure_http_app'](request, lambda *a: None), [b'ok'])
        request['HTTP_ORIGIN'] = 'null'
        result.clear()
        env['secure_http_app'](request, lambda status, headers: result.append(status))
        self.assertEqual(result, ['403 Forbidden'])


class PrivateStorageTests(unittest.TestCase):
    def test_rejects_path_traversal_job_id(self):
        with self.assertRaises(ValueError): job_identifier('../../outside')
        self.assertEqual(job_identifier('12345678-1234-1234-1234-123456789abc'), '12345678-1234-1234-1234-123456789abc')

    def test_rejects_storage_symlink_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            selected = root / 'selected'; selected.mkdir()
            outside = root / 'outside'; outside.mkdir()
            (selected / 'Hermeneus Data').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError): contained(selected, 'Hermeneus Data', 'jobs', 'abc')

    def test_atomic_output_is_private_and_does_not_follow_destination_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            outside = root / 'outside'; outside.write_text('unchanged')
            output = root / 'output'; output.symlink_to(outside)
            atomic_private_text(output, 'new transcript')
            self.assertEqual(outside.read_text(), 'unchanged')
            self.assertEqual(output.read_text(), 'new transcript')
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__': unittest.main()
