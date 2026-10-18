"""Run the actual fallback decoder against an untrusted network playlist."""
import ast
import io
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch
import numpy as np

ROOT = Path(__file__).resolve().parents[1]

class MediaDecodeBoundaryTests(unittest.TestCase):
    def test_playlist_cannot_trigger_network_requests(self):
        binary = shutil.which('ffmpeg')
        if not binary: self.skipTest('FFmpeg not installed')
        hits = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(404); self.end_headers()
            def log_message(self, *args): pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            port = server.server_address[1]
            playlist = f'#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:{port}/private-audio.ts\n#EXT-X-ENDLIST\n'.encode()
            tree = ast.parse((ROOT/'asr_server/server.py').read_text())
            node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'decode_audio')
            env = dict(np=np, io=io, shutil=shutil, subprocess=subprocess, MAX_SESSION_SECONDS=45, TARGET_SR=16000)
            exec(compile(ast.Module(body=[node], type_ignores=[]), str(ROOT), 'exec'), env)
            # This forces the fallback path even if libsndfile learns playlists.
            with patch.dict(sys.modules, {'soundfile': None}):
                self.assertIsNone(env['decode_audio'](playlist))
            self.assertEqual(hits, [], 'Media decoder contacted a URL embedded in uploaded bytes')
        finally:
            server.shutdown(); server.server_close();thread.join(timeout=2)
