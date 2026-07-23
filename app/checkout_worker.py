"""
checkout_worker.py - a minimal, from-scratch "checkout service" simulator.

This stands in for a real payment/checkout microservice for the purposes of
this demo: it accepts HTTP requests and, for each one, does a small amount of
real work that legitimately needs memory (building a receipt/cart object and
keeping a short-lived history buffer). Under sustained traffic this pushes
memory usage up in a way that is realistic, not artificial.

When the container has no resources.requests/limits (or a limit set far below
what the workload actually needs), the Linux kernel OOM killer or the kubelet
eventually kills the process once the node or cgroup runs out of memory -
this shows up in `kubectl describe pod` as "OOMKilled" / Exit Code 137, and
the Deployment cycles into CrashLoopBackOff as Kubernetes keeps restarting it.

Environment variables:
  ORDERS_PER_SEC     simulated checkout throughput (affects memory growth rate)
  HISTORY_CEILING    if set, cap the in-memory order history at this many
                     entries (the "fixed" manifest sets this to a sane bound;
                     the "broken" manifest leaves it unset)
"""

import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORDERS_PER_SEC = float(os.environ.get("ORDERS_PER_SEC", "20"))
_ceiling_env = os.environ.get("HISTORY_CEILING")
HISTORY_CEILING = int(_ceiling_env) if _ceiling_env else None

_order_history = []
_history_lock = threading.Lock()
_started_at = time.time()


def _make_order():
    # A "receipt" with enough padding to resemble a real order payload
    # (line items, customer info, promo metadata, etc.).
    return {
        "id": str(uuid.uuid4()),
        "ts": time.time(),
        "payload": bytearray(256 * 1024),  # 256KB per simulated order
    }


def _process_orders():
    interval = 1.0 / max(ORDERS_PER_SEC, 0.1)
    while True:
        order = _make_order()
        with _history_lock:
            _order_history.append(order)
            if HISTORY_CEILING is not None:
                while len(_order_history) > HISTORY_CEILING:
                    _order_history.pop(0)
        time.sleep(interval)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        with _history_lock:
            count = len(_order_history)
            approx_mb = count * 256 / 1024
        uptime = time.time() - _started_at
        body = (
            f"checkout-worker up {uptime:.0f}s, "
            f"{count} orders in memory (~{approx_mb:.1f}MB)\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # keep container logs quiet; kubectl events/k8sgpt tell the story


def main():
    threading.Thread(target=_process_orders, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
