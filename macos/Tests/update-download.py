#!/usr/bin/env python3
"""Native default TLS must reject a local untrusted leaf before sending HTTP."""
import http.server
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading


def main():
    requests = []
    failures = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.end_headers()

        def log_message(self, *_):
            pass

    class Server(http.server.HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            try:
                return context.wrap_socket(connection, server_side=True), address
            except ssl.SSLError as error:
                failures.append(error.reason)
                connection.close()
                raise

    with tempfile.TemporaryDirectory(prefix="forever-untrusted-tls-") as folder:
        certificate = Path(folder) / "test.crt"
        key = Path(folder) / "test.key"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                        "-keyout", str(key), "-out", str(certificate)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o600)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server = Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            subprocess.run([sys.argv[1], f"https://localhost:{server.server_port}/manifest.json"],
                           check=True, timeout=40)
            assert failures and not requests, "local TLS rejection did not precede HTTP"
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
