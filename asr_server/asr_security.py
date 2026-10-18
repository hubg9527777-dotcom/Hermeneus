"""Local IPC boundary, imported before AI dependencies. No credentials are stored."""
import hmac
from urllib.parse import urlsplit


def authorized(peer, host, origin, authorization, token, port):
    if peer not in {'127.0.0.1', '::1'} or origin is not None or len(token) < 32:
        return False
    if host not in {f'127.0.0.1:{port}', f'localhost:{port}', f'[::1]:{port}'}:
        return False
    return hmac.compare_digest((authorization or '').encode('utf-8'), ('Bearer ' + token).encode('utf-8'))


def local_ollama_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'http' or parsed.hostname not in {'127.0.0.1', 'localhost', '::1'}
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path != '/api/generate'):
        raise ValueError('Only a local Ollama /api/generate endpoint is allowed')
    return value


def inherited_listener(fd, expected_port):
    """Duplicate and validate a parent-held loopback listener, never rebind it."""
    import os
    import socket
    listener = socket.socket(fileno=os.dup(int(fd)))
    try:
        if (listener.family != socket.AF_INET or
                listener.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM or
                not 0 < expected_port < 65536 or
                listener.getsockname() != ('127.0.0.1', expected_port)):
            raise ValueError('Invalid inherited local service listener')
        # SO_ACCEPTCONN is not available through getsockopt on every Darwin
        # release. listen() is idempotent and never releases the bound address.
        listener.listen(16)
        listener.set_inheritable(False)
        return listener
    except BaseException:
        listener.close()
        raise
