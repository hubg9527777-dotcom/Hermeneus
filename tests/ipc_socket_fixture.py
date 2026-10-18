"""Child used by the Swift handoff integration test; never loads AI models."""
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'asr_server'))
from asr_security import inherited_listener
http = inherited_listener(0, int(os.environ['ASR_HTTP_PORT']))
ws = inherited_listener(1, int(os.environ['ASR_WS_PORT']))
os.dup2(2, 1)
import asyncio
import threading
import ast
from wsgiref.simple_server import WSGIServer
from socketserver import ThreadingMixIn
from bottle import WSGIRefServer
source = Path(__file__).resolve().parents[1] / 'asr_server/server.py'
nodes = [n for n in ast.parse(source.read_text()).body if isinstance(n, ast.ClassDef) and n.name in {'ThreadedWSGIServer', 'ThreadedServer'}]
namespace = dict(threading=threading, WSGIServer=WSGIServer, ThreadingMixIn=ThreadingMixIn, WSGIRefServer=WSGIRefServer, _INHERITED_HTTP_SOCKET=http)
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), 'exec'), namespace)
def app(env, start):
    if env['PATH_INFO'] == '/redirect':
        start('302 Found', [('Location', 'http://127.0.0.1:1/must-not-follow')]);return [b'']
    assert env.get('HTTP_AUTHORIZATION') == 'Bearer ' + os.environ['HERMENEUS_ASR_TOKEN']
    start('200 OK', [('Content-Type', 'text/plain')]);return [b'inherited-http']
threading.Thread(target=lambda: namespace['ThreadedServer'](host='127.0.0.1', port=http.getsockname()[1]).run(app), daemon=True).start()
import websockets
async def handler(connection):
    assert connection.request.headers['Authorization'] == 'Bearer ' + os.environ['HERMENEUS_ASR_TOKEN']
    await connection.send('inherited-ws')
async def main():
    async with websockets.serve(handler, sock=ws): await asyncio.Future()
asyncio.run(main())
