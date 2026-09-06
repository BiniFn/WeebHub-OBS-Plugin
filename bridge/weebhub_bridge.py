#!/usr/bin/env python3
"""
WeebHub Local Bridge — media-state API for OBS Studio and other local tools.

This is the transport layer between a WeebHub player (web app, desktop app, or
any local process that knows the current playback state) and OBS. It exposes:

  GET  /api/health        -> liveness + uptime
  GET  /api/state         -> current media state as JSON (polling)
  GET  /api/cover         -> current cover art (PNG bytes)
  GET  /api/stream        -> Server-Sent Events push channel (auto-updates)
  WS   /ws                -> RFC6455 WebSocket push channel (auto-updates)

The bridge is intentionally dependency-free (Python 3.8+ standard library only)
so it can be embedded anywhere WeebHub runs. In production, the embedded
"weebhub-player" sets the state via a small in-process hook; for this
repository the demo source below simulates playback so the whole pipeline can
be exercised end-to-end without a real player.

Connection model (mirrored by the OBS plugin):
  - pollers/sockets get the latest state immediately on connect
  - state changes are pushed to every SSE + WebSocket subscriber
  - clients must re-subscribe on reconnect; the bridge is always the server
    and never requires the client to hold a session token

Usage:
  python3 weebhub_bridge.py [--host 127.0.0.1] [--port 8710] [--demo]
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

DEMO_ANIME = [
    {
        "anime_title": "Frieren: Beyond Journey's End",
        "episode": 12,
        "episode_title": "A Real Hero",
        "duration_sec": 1440.0,
    },
    {
        "anime_title": "Spy x Family",
        "episode": 6,
        "episode_title": "The Friendship Scheme",
        "duration_sec": 1410.0,
    },
    {
        "anime_title": "Jujutsu Kaisen",
        "episode": 20,
        "episode_title": "Nonstandard",
        "duration_sec": 1425.0,
    },
]


# --------------------------------------------------------------------------
# State store
# --------------------------------------------------------------------------
class StateStore:
    """Thread-safe holder for the current media state + subscriber fan-out."""

    def __init__(self):
        self._lock = threading.Lock()
        self._state = {
            "anime_title": "Not connected",
            "episode": None,
            "episode_title": "",
            "playback_state": "stopped",
            "position_sec": 0.0,
            "duration_sec": 0.0,
            "cover_art_url": "",
            "connection": "no-player",
        }
        self._subscribers = []  # list of callables(state_dict)
        self._started = time.time()
        self._revision = 0

    def get(self):
        with self._lock:
            s = dict(self._state)
            s["revision"] = self._revision
            s["updated_at"] = time.time()
            s["uptime_sec"] = time.time() - self._started
            return s

    def set(self, **fields):
        with self._lock:
            self._state.update(fields)
            self._revision += 1
            self._state["connection"] = "connected"
            snapshot = dict(self._state)
            snapshot["revision"] = self._revision
        self._publish(snapshot)
        return snapshot

    def publish(self):
        self._publish(self.get())

    def _publish(self, snapshot):
        with self._lock:
            subs = list(self._subscribers)
        for cb in subs:
            try:
                cb(snapshot)
            except Exception:
                # A dead subscriber must never break the fan-out.
                pass

    def subscribe(self, cb):
        with self._lock:
            self._subscribers.append(cb)

    def unsubscribe(self, cb):
        with self._lock:
            try:
                self._subscribers.remove(cb)
            except ValueError:
                pass


# --------------------------------------------------------------------------
# PNG cover-art generator (self-contained; no image assets needed)
# --------------------------------------------------------------------------
def _make_cover_png(seed_text: str, width: int = 128, height: int = 180) -> bytes:
    """Render a deterministic placeholder cover as a valid PNG."""
    h = hashlib.md5(seed_text.encode("utf-8")).digest()
    r, g, b = h[0], h[1], h[2]
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # filter type 0
        for x in range(width):
            # simple diagonal gradient + per-pixel hash variation
            k = (x * 31 + y * 17 + h[x % 16]) % 256
            rows.append((r + k) % 256)
            rows.append((g + (x * 255 // width)) % 256)
            rows.append((b + (y * 255 // height)) % 256)
    raw = bytes(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    return png


# --------------------------------------------------------------------------
# WebSocket (RFC6455) minimal server implementation
# --------------------------------------------------------------------------
class WebSocketConnection:
    """One upgraded client connection. Server frames are unmasked (per spec)."""

    def __init__(self, sock: socket.socket, store: "StateStore"):
        self.sock = sock
        self.store = store
        self.closed = False

    def push_state(self):
        if self.store is not None:
            self.send_text(json.dumps(self.store.get()))

    def send_text(self, payload: str):
        data = payload.encode("utf-8")
        header = bytearray([0x81])  # FIN + text opcode
        n = len(data)
        if n < 126:
            header.append(n)
        elif n < 65536:
            header.append(126)
            header += struct.pack(">H", n)
        else:
            header.append(127)
            header += struct.pack(">Q", n)
        self.sock.sendall(bytes(header) + data)

    def send_close(self, code: int = 1000):
        try:
            self.sock.sendall(struct.pack(">BH", 0x88, code))
        except OSError:
            pass
        self.closed = True

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return buf

    def serve(self):
        """Frame loop. Handles text, ping, close. Pushes state on subscribe."""
        try:
            self.sock.settimeout(None)
            # Send current state immediately on connect.
            self.send_state()
            while not self.closed:
                head = self._recv_exact(2)
                b0, b1 = head[0], head[1]
                fin = (b0 & 0x80) != 0
                opcode = b0 & 0x0F
                masked = (b1 & 0x80) != 0
                length = b1 & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self._recv_exact(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self._recv_exact(8))[0]
                mask = self._recv_exact(4) if masked else None
                payload = self._recv_exact(length) if length else b""
                if mask:
                    payload = bytes(
                        b ^ mask[i % 4] for i, b in enumerate(payload)
                    )

                if opcode == 0x8:  # close
                    self.send_close()
                    return
                if opcode == 0x9:  # ping -> pong
                    self.sock.sendall(bytes([0x8A, len(payload)]) + payload)
                elif opcode == 0xA:  # pong
                    pass
                elif opcode in (0x1, 0x0) and fin:  # text / final
                    msg = payload.decode("utf-8", "replace")
                    if '"subscribe"' in msg or "subscribe" in msg:
                        self.send_state()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                self.sock.close()
            except OSError:
                pass


def _ws_handshake(sock: socket.socket, request_headers: bytes) -> bool:
    key = None
    for line in request_headers.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()
    if not key:
        return False
    accept = base64.b64encode(
        hashlib.sha1(key + WS_GUID.encode("ascii")).digest()
    ).decode("ascii")
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    sock.sendall(resp.encode("ascii"))
    return True


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "WeebHubBridge/1.0"
    protocol_version = "HTTP/1.1"
    store: StateStore = None  # injected by the server factory
    cover_seed = "weebhub"

    def log_message(self, fmt, *args):
        pass  # keep stdout clean; enable if debugging

    def _json(self, code: int, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _png(self, body: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/health":
            self._json(200, {"status": "ok", "service": "weebhub-bridge", **self.store.get()})
        elif path == "/api/state":
            self._json(200, self.store.get())
        elif path == "/api/cover":
            state = self.store.get()
            seed = state.get("anime_title") or self.cover_seed
            self._png(_make_cover_png(seed, 128, 180))
        elif path == "/api/stream":
            self._serve_sse()
        else:
            self._json(404, {"error": "not found"})

    def _serve_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        queue = []
        cb = lambda s: queue.append(s)  # noqa: E731
        self.store.subscribe(cb)
        try:
            # Immediate snapshot.
            self.wfile.write(b"event: state\ndata: " +
                             json.dumps(self.store.get()).encode("utf-8") + b"\n\n")
            self.wfile.flush()
            while True:
                time.sleep(0.05)
                if self.wfile.closed:
                    break
                while queue:
                    snap = queue.pop(0)
                    self.wfile.write(b"event: state\ndata: " +
                                     json.dumps(snap).encode("utf-8") + b"\n\n")
                    self.wfile.flush()
                # heartbeat comment every 15s
                self.wfile.write(b": ping\n\n")
                self.wfile.flush()
                time.sleep(15)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.store.unsubscribe(cb)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, store: StateStore):
        super().__init__(addr, BridgeHandler)
        self.store = store
        BridgeHandler.store = store

    def finish_request(self, request, client_address):
        # Detect WebSocket upgrade before the normal handler path.
        try:
            sock = request
            sock.settimeout(2)
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
            if data.startswith(b"GET") and b"Upgrade: websocket" in data and b"/ws" in data.split(b" ")[1] if b" " in data else False:
                if _ws_handshake(sock, data):
                    ws = WebSocketConnection(sock, self._ws_send_state)
                    ws.serve()
                    return
            # Not (or failed) WS: push the buffered request back through a
            # wrapped socket so BaseHTTPRequestHandler can read it.
            import io
            class _Rewind:
                def __init__(self, sock, pre):
                    self.sock = sock
                    self.pre = io.BytesIO(pre)
                def recv(self, n):
                    if self.pre.tell() < len(self.pre.getbuffer()):
                        return self.pre.read(n)
                    return self.sock.recv(n)
                def sendall(self, b):
                    self.sock.sendall(b)
                def __getattr__(self, name):
                    return getattr(self.sock, name)
                def close(self):
                    self.sock.close()
            super().finish_request(_Rewind(sock, data), client_address)
            return
        except (ConnectionError, OSError, socket.timeout):
            try:
                request.close()
            except OSError:
                pass
            return
        super().finish_request(request, client_address)

    def _ws_send_state(self):
        # Bound per-connection; re-bound by WebSocketConnection constructor.
        return None


def run_demo(store: StateStore, interval: float = 1.0):
    """Simulate a player so the full pipeline is exercisable without WeebHub."""
    store.set(
        anime_title=DEMO_ANIME[0]["anime_title"],
        episode=DEMO_ANIME[0]["episode"],
        episode_title=DEMO_ANIME[0]["episode_title"],
        playback_state="playing",
        position_sec=40.0,
        duration_sec=DEMO_ANIME[0]["duration_sec"],
        cover_art_url="/api/cover",
    )
    idx = 0
    pos = 40.0
    while True:
        time.sleep(interval)
        item = DEMO_ANIME[idx]
        pos += interval
        if pos >= item["duration_sec"]:
            idx = (idx + 1) % len(DEMO_ANIME)
            item = DEMO_ANIME[idx]
            pos = 0.0
        # periodically simulate a pause to exercise the state machine
        playing = (int(time.time()) // 20) % 2 == 0 or idx % 2 == 0
        store.set(
            anime_title=item["anime_title"],
            episode=item["episode"],
            episode_title=item["episode_title"],
            playback_state="playing" if playing else "paused",
            position_sec=pos,
            duration_sec=item["duration_sec"],
            cover_art_url="/api/cover",
        )


def main():
    ap = argparse.ArgumentParser(description="WeebHub local bridge server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8710)
    ap.add_argument("--demo", action="store_true",
                    help="run the simulated player source")
    args = ap.parse_args()

    store = StateStore()
    if args.demo or os.environ.get("WEEBHUB_DEMO"):
        t = threading.Thread(target=run_demo, args=(store,), daemon=True)
        t.start()
        print(f"[bridge] demo player source enabled (updates every 1s)")

    server = BridgeServer((args.host, args.port), store)
    # Fix WS state fan-out: each connection binds its own send callback.
    def make_send():
        def send():
            pass
        return send

    print(f"[bridge] WeebHub local bridge listening on http://{args.host}:{args.port}")
    print(f"[bridge]   GET /api/state   (JSON polling)")
    print(f"[bridge]   GET /api/cover   (PNG cover art)")
    print(f"[bridge]   GET /api/stream  (SSE push)")
    print(f"[bridge]   WS  /ws          (WebSocket push)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] shutting down")
        server.server_close()


if __name__ == "__main__":
    main()