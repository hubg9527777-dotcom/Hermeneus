import socket
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'asr_server'))
from asr_security import inherited_listener


class InheritedListenerTests(unittest.TestCase):
    def test_parent_retains_port_when_child_duplicate_is_closed(self):
        with socket.socket() as parent:
            parent.bind(('127.0.0.1', 0)); parent.listen(1)
            port = parent.getsockname()[1]
            child = inherited_listener(parent.fileno(), port)
            child.close()
            with socket.socket() as attacker, self.assertRaises(OSError):
                attacker.bind(('127.0.0.1', port))
            self.assertEqual(parent.getsockname(), ('127.0.0.1', port))

    def test_rejects_wrong_port_and_wildcard_binding(self):
        for host, listening, wrong_port in [('0.0.0.0', True, False), ('127.0.0.1', True, True)]:
            with socket.socket() as parent:
                parent.bind((host, 0))
                if listening: parent.listen(1)
                port = parent.getsockname()[1] + int(wrong_port)
                with self.subTest(host=host, listening=listening, wrong_port=wrong_port), self.assertRaises(ValueError):
                    inherited_listener(parent.fileno(), port)
                self.assertGreaterEqual(parent.fileno(), 0)
