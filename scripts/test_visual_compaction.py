#!/usr/bin/env python3
"""Verify reference retention through real Frog resume and 8K compaction.

Uses a local chat fixture and labeled stub image, with no external inference.
"""
import argparse
from http.server import ThreadingHTTPServer
from io import BytesIO
import json
from pathlib import Path
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from test_image_tool import Fixture, Frog, config, run_case


class CompactFixture(Fixture):
    compacted = False
    after = None

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        body = json.loads(raw)
        if self.path == '/v1/chat/completions' and (not body.get('tools') or type(self).compacted):
            if not body.get('tools'):
                type(self).compacted = True
                # Deliberately omit the reference: the engine must preserve it.
                result = 'Continue the implementation.'
            else:
                type(self).after = body['messages']
                result = 'Reference preserved.'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            events = [
                {'choices': [{'index': 0, 'delta': {'content': result}, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]},
                {'choices': [], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20}},
            ]
            for event in events:
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        else:
            self.rfile = BytesIO(raw)
            super().do_POST()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frog', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True)
    else:
        output = Path(tempfile.mkdtemp(prefix='frog-visual-compaction-'))
    server = ThreadingHTTPServer(('127.0.0.1', 0), CompactFixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cfg = config(output, server.server_address[1], 'stub')
    cfg.write_text(cfg.read_text().replace('context_window = 65536', 'context_window = 8192'))
    Fixture.tool_args = {'prompt': 'a frog target', 'size': '64x64', 'count': 1, 'seed': 43, 'output_dir': 'assets'}
    binary = args.frog.resolve()
    sid = run_case(binary, output, cfg, 'stub')
    frog = Frog(binary, cfg, output / 'stub', sid)
    try:
        frog.send(op='compact')
        frog.until(lambda e: e['event'] == 'idle')
        assert any(e['event'] == 'compacted' for e in frog.events)
        frog.send(op='submit', text='Continue with the existing reference.')
        frog.until(lambda e: e['event'] == 'idle')
        messages = CompactFixture.after
        (output / 'after-compaction-request.json').write_text(json.dumps(messages, indent=2))
        encoded = json.dumps(messages)
        assets = list((output / 'stub/assets').glob('*.png'))
        assert len(assets) == 1 and str(assets[0]) in encoded
        images = [p for m in messages if isinstance(m.get('content'), list) for p in m['content'] if p.get('type') == 'image_url']
        assert len(images) == 1
        assert images == Fixture.vision_requests[-1], 'reference model input changed through compaction'
        print(f'PASS real Frog 8K compaction retains exact asset path and reference vision input: {output}')
    finally:
        (output / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in frog.events))
        frog.close()
        server.shutdown()


if __name__ == '__main__':
    main()
