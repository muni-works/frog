#!/usr/bin/env python3
"""Loopback Chromium Screenshot endpoint. Install Playwright explicitly before use."""
import argparse
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


def capture(request, executable=None):
    if not isinstance(request, dict):
        raise ValueError('request must be an object')
    url = request.get('url')
    if not isinstance(url, str) or len(url) > 8192:
        raise ValueError('url must be a string of at most 8192 characters')
    parts = urlsplit(url)
    if parts.scheme not in ('http', 'https', 'file'):
        raise ValueError('url must use http, https or file')
    if parts.scheme == 'file' and parts.netloc not in ('', 'localhost'):
        raise ValueError('file URL must be local')
    values = {}
    for name, default, low, high in [('width', 1280, 64, 2048), ('height', 720, 64, 2048), ('settle_ms', 350, 0, 5000)]:
        value = request.get(name, default)
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f'{name} must be an integer from {low} to {high}')
        values[name] = value
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=executable, headless=True, chromium_sandbox=True)
        try:
            context = browser.new_context(viewport={k: values[k] for k in ('width', 'height')}, device_scale_factor=1, accept_downloads=False)
            try:
                page = context.new_page()
                page.set_default_timeout(10000)
                response = page.goto(url, wait_until='load', timeout=20000)
                if response and response.status >= 400:
                    raise ValueError(f'page returned HTTP {response.status}')
                page.evaluate('''async () => {
                    await Promise.race([
                        Promise.all([document.fonts.ready, ...Array.from(document.images, image =>
                            image.complete ? Promise.resolve() : new Promise(resolve => {
                                image.addEventListener('load', resolve, {once:true});
                                image.addEventListener('error', resolve, {once:true});
                            }))]),
                        new Promise(resolve => setTimeout(resolve, 5000))
                    ]);
                }''')
                page.wait_for_timeout(values['settle_ms'])
                return page.screenshot(type='png', full_page=False, scale='css', timeout=10000)
            finally:
                context.close()
        finally:
            browser.close()


class Server(ThreadingHTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    slots = threading.BoundedSemaphore(2)
    executable = None

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200 if self.path == '/health' else 404, {'renderer': 'chromium'} if self.path == '/health' else {'error': {'message': 'not found'}})

    def do_POST(self):
        if self.path != '/v1/screenshots':
            self.reply(404, {'error': {'message': 'not found'}})
            return
        if not self.slots.acquire(blocking=False):
            self.reply(429, {'error': {'message': 'renderer busy'}})
            return
        try:
            self.connection.settimeout(10)
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 65536:
                raise ValueError('request body must be 1–65536 bytes')
            request = json.loads(self.rfile.read(length))
            image = capture(request, self.executable)
            self.reply(200, {'data': [{'b64_json': base64.b64encode(image).decode()}]})
        except (ValueError, UnicodeError) as error:
            self.reply(400, {'error': {'message': str(error)}})
        except Exception as error:
            self.reply(503, {'error': {'message': f'Chromium capture failed: {error}'}})
        finally:
            self.slots.release()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8914)
    parser.add_argument('--executable-path', help='Existing Chrome/Chromium executable; otherwise use explicitly installed Playwright Chromium')
    args = parser.parse_args()
    Handler.executable = args.executable_path
    server = Server(('127.0.0.1', args.port), Handler)
    print(f'frog-chromium: http://127.0.0.1:{args.port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
