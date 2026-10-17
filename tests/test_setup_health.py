"""Exercise the setup protocol without downloading or loading multi-GB models."""
import ast
import json
import threading
import types
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'asr_server' / 'server.py'


class SetupHealthTests(unittest.TestCase):
    def setUp(self):
        tree = ast.parse(SOURCE.read_text())
        names = {'setup_health', 'prepare_speech_models'}
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
        for node in nodes:
            node.decorator_list = []
        self.calls = []
        self.env = {
            'json': json, 'response': types.SimpleNamespace(),
            '_SETUP_READY': False, '_SETUP_ERROR': None, '_WS_READY': False,
            '_SETUP_LOCK': threading.Lock(), 'es_lock': threading.Lock(),
            'paraformer_model': object(), 'WHISPER_BACKEND': 'mlx',
            'TARGET_SR': 16000, 'np': types.SimpleNamespace(zeros=lambda *a, **k: 'silence', float32=float),
            'run_whisper': lambda audio, lang: self.calls.append((audio, lang)),
            'print': lambda *a: None,
        }
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), 'exec'), self.env)

    def health(self):
        return json.loads(self.env['setup_health']())

    def test_model_inference_and_websocket_must_both_be_ready(self):
        self.assertFalse(self.health()['ready'])
        self.env['prepare_speech_models']()
        self.assertEqual(self.calls, [('silence', 'es')])
        self.assertFalse(self.health()['ready'])
        self.env['_WS_READY'] = True
        self.assertTrue(self.health()['ready'])
        self.assertEqual(self.health()['service'], 'hermeneus-asr')

    def test_failed_download_can_be_retried(self):
        def fail(*args):
            raise RuntimeError('network unavailable')
        self.env['run_whisper'] = fail
        self.env['prepare_speech_models']()
        self.assertFalse(self.health()['ready'])
        self.assertEqual(self.health()['setup_error'], 'network unavailable')
        self.assertFalse(self.env['_SETUP_LOCK'].locked())
        self.env['run_whisper'] = lambda *a: None
        self.env['prepare_speech_models']()
        self.env['_WS_READY'] = True
        self.assertTrue(self.health()['ready'])
        self.assertIsNone(self.health()['setup_error'])

    def test_duplicate_prepare_does_not_start_another_inference(self):
        self.env['_SETUP_LOCK'].acquire()
        self.env['prepare_speech_models']()
        self.assertEqual(self.calls, [])
        self.env['_SETUP_LOCK'].release()


if __name__ == '__main__':
    unittest.main()
