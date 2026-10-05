#!/usr/bin/env python3
"""Exercise the real frog --serve binary with local chat/image HTTP fixtures.

python3 scripts/test_image_tool.py --frog target/debug/frog
--server-only --output /tmp/frog-image-ui writes isolated configs for native testing.
No external inference service or API key is used.
"""
import argparse
import base64
import json
import queue
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def png(variant=0):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    colors = [(80, 135, 100), (210, 230, 205)] if variant == 0 else [(95, 125, 180), (215, 225, 245)]
    rows = b''.join(b'\0' + b''.join(bytes(colors[(x // 32 + y // 32) % 2]) for x in range(320)) for y in range(192))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 320, 192, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Fixture(BaseHTTPRequestHandler):
    tool_args = None
    image_requests = []
    vision_requests = []
    image_started = threading.Event()
    release_image = threading.Event()

    def log_message(self, *args):
        pass

    def json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/props':
            self.json({'n_ctx': 65536})
        else:
            self.json({'data': [{'id': 'image-fixture', 'max_model_len': 65536, 'capabilities': ['vision']}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/v1/images/generations':
            self.image_requests.append(body)
            if 'cancel' in body['prompt']:
                self.image_started.set()
                self.release_image.wait(15)
            if 'malformed' in body['prompt']:
                self.json({'data': [{'b64_json': 'invalid'}]})
            elif 'http-error' in body['prompt']:
                self.json({'error': 'fixture failure'}, 503)
            else:
                result = {'data': [{'b64_json': base64.b64encode(png(i)).decode()} for i in range(body['n'])]}
                if self.headers.get('x-frog-progress') == 'sse':
                    self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                    frames = ''.join('event: progress\ndata: ' + json.dumps({'step': step, 'of': 8}) + '\n\n' for step in [0, 1, 8])
                    frames += 'event: result\ndata: ' + json.dumps(result) + '\n\n'
                    data = frames.encode()
                    for offset in range(0, len(data), 7): self.wfile.write(data[offset:offset + 7])
                    self.wfile.flush()
                else:
                    self.json(result)
            return
        if self.path != '/v1/chat/completions':
            self.json({}, 404)
            return
        messages = body['messages']
        # The last textual user prompt starts a new turn. Image-only user parts follow results.
        start = max(i for i, m in enumerate(messages) if m['role'] == 'user' and isinstance(m['content'], str))
        prompt = messages[start]['content']
        tool_results = [m for m in messages[start + 1:] if m['role'] == 'tool']
        if tool_results:
            images = [p for m in messages[start + 1:] if m['role'] == 'user' and isinstance(m['content'], list) for p in m['content'] if p.get('type') == 'image_url']
            self.vision_requests.append(images)
            delta = {'content': 'Image test completed.'}
            finish = 'stop'
        else:
            assert any(t['function']['name'] == 'Image' for t in body.get('tools', [])), 'Image not offered'
            args = {'prompt': prompt, 'size': '320x192', 'count': 2, 'seed': 42}
            if self.tool_args is not None:
                args = self.tool_args
            delta = {'tool_calls': [{'index': 0, 'id': 'image-call', 'type': 'function', 'function': {'name': 'Image', 'arguments': json.dumps(args)}}]}
            finish = 'tool_calls'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for value in [{'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}, {'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]}, {'choices': [], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}]:
            self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


def config(output, port, backend, image_endpoint=None):
    path = output / f'{backend}.toml'
    path.write_text(f'''default_model = "fixture"
load_claude_md = false
[models.fixture]
provider = "openai"
model = "image-fixture"
base_url = "http://127.0.0.1:{port}/v1"
context_window = 65536
tool_mode = "native"
vision = true
[image]
backend = "{backend}"
endpoint = "{image_endpoint or f'http://127.0.0.1:{port}/v1/images/generations'}"
model = "{'z-image-turbo' if image_endpoint else 'fixture-image'}"
''')
    return path


class Frog:
    def __init__(self, binary, cfg, cwd, resume=None):
        self.events = []
        self.lines = queue.Queue()
        self.err = (cwd / 'stderr.log').open('w')
        args = [str(binary), '--serve', '--config', str(cfg)]
        if resume:
            args += ['--resume', resume]
        self.proc = subprocess.Popen(args, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, text=True)
        def read():
            for line in self.proc.stdout:
                self.lines.put(json.loads(line))
            self.lines.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.until(lambda e: e['event'] == 'idle')

    def send(self, **op):
        self.proc.stdin.write(json.dumps(op) + '\n')
        self.proc.stdin.flush()

    def until(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            event = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            assert event is not None, 'frog exited unexpectedly; see stderr.log'
            self.events.append(event)
            if predicate(event):
                return event

    def close(self):
        self.send(op='shutdown')
        self.proc.stdin.close()
        assert self.proc.wait(timeout=15) == 0
        self.err.close()


def run_case(binary, output, cfg, name, decision='allow', resume=None, timeout=30):
    cwd = output / name
    cwd.mkdir(exist_ok=True)
    frog = Frog(binary, cfg, cwd, resume)
    frog.send(op='submit', text=f'Generate images for the {name} test.')
    permission = frog.until(lambda e: e['event'] == 'permission_request')
    assert permission['name'] == 'Image'
    assert permission['always'] == 'always allow image generation this session'
    frog.send(op='permission', id=permission['id'], decision=decision)
    if name == 'cancel':
        assert Fixture.image_started.wait(10), 'generation never started'
        frog.send(op='interrupt')
    frog.until(lambda e: e['event'] == 'turn_ended', timeout=timeout)
    frog.until(lambda e: e['event'] == 'idle')
    frog.close()
    (cwd / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in frog.events))
    completed = [e for e in frog.events if e['event'] == 'item_completed' and e['item'].get('name') == 'Image']
    if name == 'cancel':
        end = next(e for e in frog.events if e['event'] == 'turn_ended')
        assert end['reason']['type'] == 'cancelled', end
        Fixture.release_image.set()
    else:
        result = completed[-1]['item']
        expected = 'denied' if decision == 'deny' else ('error' if name in ('malformed', 'http-error') else 'ok')
        assert result['outcome'] == expected, result
        count = Fixture.tool_args['count'] if Fixture.tool_args else 2
        assert len(result.get('images', [])) == (count if expected == 'ok' else 0)
        if expected == 'ok':
            assert len(Fixture.vision_requests[-1]) == count, 'images did not reach vision model'
            for i, image in enumerate(result['images']):
                (cwd / f'image-{i}.png').write_bytes(base64.b64decode(image['data']))
            # A replay fixture directly from the real binary's event envelopes.
            header = {'type': 'header', 'version': 1, 'id': name, 'cwd': str(cwd), 'model': 'fixture', 'created': frog.events[0]['created']}
            durable = [e for e in frog.events if e['event'] in ('turn_started', 'item_started', 'item_completed', 'turn_ended')]
            (output / f'{name}.jsonl').write_text(json.dumps(header) + '\n' + ''.join(json.dumps({'type': 'event', 'env': e}) + '\n' for e in durable))
    print(f'PASS {name}', flush=True)
    return frog.events[-1]['session']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frog', type=Path, default=Path('target/debug/frog'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--server-only', action='store_true')
    parser.add_argument('--image-endpoint', help='Test an explicitly selected real tang image backend; chat remains a local fixture')
    args = parser.parse_args()
    output = (args.output or Path(tempfile.mkdtemp(prefix='frog-image-test-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    port = server.server_address[1]
    stub, remote = [config(output, port, b) for b in ('stub', 'remote')]
    print(f'Artifacts: {output}; fixture: http://127.0.0.1:{port}', flush=True)
    if args.server_only:
        server.serve_forever()
        return
    threading.Thread(target=server.serve_forever, daemon=True).start()
    binary = args.frog.resolve()
    try:
        if args.image_endpoint:
            Fixture.tool_args = {'prompt': 'A small green frog sitting on a mossy stone beside a pond, natural daylight, photograph', 'size': '320x192', 'count': 1, 'seed': 42, 'steps': 8, 'output_dir': 'assets'}
            tang = config(output, port, 'tang', args.image_endpoint)
            run_case(binary, output, tang, 'trained-tang', timeout=300)
            return
        sid = run_case(binary, output, stub, 'stub')
        resumed = Frog(binary, stub, output / 'stub', sid)
        resumed.send(op='subscribe', after=0)
        resumed.until(lambda e: e['event'] == 'synced')
        replay = [e for e in resumed.events if e['event'] == 'item_completed' and e['item'].get('name') == 'Image']
        assert len(replay[-1]['item']['images']) == 2, 'images missing after resume'
        resumed.close()
        print('PASS resume', flush=True)
        run_case(binary, output, remote, 'deny', 'deny')
        assert not Fixture.image_requests, 'denied generation reached backend'
        run_case(binary, output, remote, 'remote')
        tang = config(output, port, 'tang')
        run_case(binary, output, tang, 'tang-stream')
        assert Fixture.image_requests[-1]['seed'] == 42
        run_case(binary, output, remote, 'malformed')
        run_case(binary, output, remote, 'http-error')
        run_case(binary, output, remote, 'cancel')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
