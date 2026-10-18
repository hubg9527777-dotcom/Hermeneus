"""Real websocket handshake tests with a stub inference handler; no model loads."""
import ast
import asyncio
from pathlib import Path
import sys
import unittest
import websockets

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'asr_server'))
from asr_security import authorized


class WebsocketSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        tree = ast.parse((ROOT / 'asr_server/server.py').read_text())
        handler = next(n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == 'handle_asr_session')
        self.calls = []
        async def inference(socket):
            self.calls.append(True)
            await socket.send('ready')
            await socket.close()
        self.env = {'asyncio': asyncio, 'authorized': authorized, 'IPC_TOKEN': 'a' * 44,
                    '_WS_CONNECTION_SLOTS': None, 'MAX_SESSION_SECONDS': 45,
                    '_handle_authorized_session': inference}
        exec(compile(ast.Module(body=[handler], type_ignores=[]), str(ROOT), 'exec'), self.env)
        self.server = await websockets.serve(self.env['handle_asr_session'], '127.0.0.1', 0,
                                            origins=[None], compression=None)
        self.port = self.server.sockets[0].getsockname()[1]
        self.env['WS_PORT'] = self.port
        self.url = f'ws://127.0.0.1:{self.port}/ws/asr'

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()

    async def test_native_client_with_capability_connects(self):
        async with websockets.connect(self.url, additional_headers={'Authorization': 'Bearer ' + 'a' * 44}) as connection:
            self.assertEqual(await connection.recv(), 'ready')
        self.assertEqual(self.calls, [True])

    async def test_missing_credential_cannot_reach_inference(self):
        async with websockets.connect(self.url) as connection:
            with self.assertRaises(websockets.exceptions.ConnectionClosedError):
                await connection.recv()
        self.assertFalse(self.calls)

    async def test_browser_origin_is_rejected_during_handshake(self):
        with self.assertRaises(websockets.exceptions.InvalidStatus):
            async with websockets.connect(self.url, origin='https://evil.example',
                additional_headers={'Authorization': 'Bearer ' + 'a' * 44}): pass
        self.assertFalse(self.calls)

    async def test_wrong_path_does_not_reach_inference(self):
        async with websockets.connect(self.url.replace('/ws/asr', '/wrong'),
                additional_headers={'Authorization': 'Bearer ' + 'a' * 44}) as connection:
            with self.assertRaises(websockets.exceptions.ConnectionClosedError):
                await connection.recv()
        self.assertFalse(self.calls)


if __name__ == '__main__': unittest.main()
