"""Tiny in-process SSE fan-out used by the panel and native UI."""
import json
import queue
import threading


STATEFUL = {'tab', 'casts', 'vibe', 'now', 'current', 'surf', 'shelves'}


class Bus:
    def __init__(self):
        self.lock = threading.Lock()
        self.clients = []
        self.saved = {}

    def emit(self, verb, *args):
        event = 'event: %s\ndata: %s\n\n' % (verb, json.dumps(list(args), separators=(',', ':')))
        with self.lock:
            if verb in STATEFUL:
                self.saved[verb] = event
            for client in self.clients[:]:
                client.put(event)

    def connect(self):
        q = queue.Queue()
        with self.lock:
            self.clients.append(q)
            # This order is the old ready handshake's useful first paint order.
            for verb in ('tab', 'casts', 'vibe', 'now', 'current', 'surf', 'shelves'):
                if verb in self.saved:
                    q.put(self.saved[verb])
        return q

    def disconnect(self, q):
        with self.lock:
            if q in self.clients:
                self.clients.remove(q)
