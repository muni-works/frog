#!/usr/bin/env python3
"""Exercise Screenshot -> Compare -> durable stop through the real frog engine.
Use --screenshot-endpoint to additionally test live page rendering.
"""
import argparse
import base64
import json
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from test_image_tool import Fixture, Frog, png

class VisualFixture(Fixture):
    judge_calls = 0
    capture_calls = 0
    capture_args = {'url':'page.html','width':320,'height':192,'output_path':'actual.png'}
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/v1/screenshots':
            type(self).capture_calls += 1
            self.json({'data': [{'b64_json': base64.b64encode(png()).decode()}]})
            return
        if not body.get('tools'):
            type(self).judge_calls += 1
            images = [p for m in body['messages'] if isinstance(m['content'], list) for p in m['content'] if p.get('type') == 'image_url']
            assert len(images) >= 4, 'judge missing full images/crop pairs'
            schema = body['response_format']['json_schema']['schema']
            assert {'target_description', 'actual_description', 'score', 'diffs'} == set(schema['required'])
            assert schema['properties']['diffs']['maxItems'] == 8
            verdict = {'target_description':'A matching reference page.', 'actual_description':'The same rendered page.', 'score':92, 'diffs':[]}
            self.send_response(200); self.send_header('Content-Type','text/event-stream');self.end_headers()
            self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':json.dumps(verdict)},'finish_reason':None}]})+'\n\n').encode())
            self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]})+'\n\ndata: [DONE]\n\n').encode());self.wfile.flush()
            return
        results = [m for m in body['messages'] if m['role'] == 'tool']
        if not results:
            name, args = 'Screenshot', type(self).capture_args
        elif len(results) < 3:
            # Second Compare must fail before another judge call: first one matched.
            name, args = 'Compare', {'target':'target.png','actual':'actual.png','loop_id':'fixture','threshold':85,'max_rounds':6}
        else:
            name = None
        delta = {'content':'Visual loop completed.'} if not name else {'tool_calls':[{'index':0,'id':f'call-{len(results)}','type':'function','function':{'name':name,'arguments':json.dumps(args)}}]}
        self.send_response(200); self.send_header('Content-Type','text/event-stream');self.end_headers()
        self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':delta,'finish_reason':None}]})+'\n\n').encode())
        self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':{},'finish_reason':'tool_calls' if name else 'stop'}]})+'\n\ndata: [DONE]\n\n').encode());self.wfile.flush()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--frog',type=Path,required=True);parser.add_argument('--screenshot-endpoint');parser.add_argument('--judge-endpoint');parser.add_argument('--judge-model');parser.add_argument('--output',type=Path)
    parser.add_argument('--target',type=Path,help='Existing raster target instead of capturing an identical reference')
    parser.add_argument('--page',type=Path,help='Existing HTML/SVG implementation to capture')
    parser.add_argument('--width',type=int,default=320);parser.add_argument('--height',type=int,default=192)
    args=parser.parse_args();output=(args.output or Path(tempfile.mkdtemp(prefix='frog-visual-test-'))).resolve();output.mkdir(parents=True,exist_ok=True)
    server=ThreadingHTTPServer(('127.0.0.1',0),VisualFixture);port=server.server_address[1];threading.Thread(target=server.serve_forever,daemon=True).start()
    endpoint=args.screenshot_endpoint or f'http://127.0.0.1:{port}/v1/screenshots'
    cfg=output/'config.toml';cfg.write_text(f'''default_model = "fixture"
load_claude_md = false
screenshot_endpoint = "{endpoint}"
[models.fixture]
provider = "openai"
model = "image-fixture"
base_url = "http://127.0.0.1:{port}/v1"
context_window = 65536
tool_mode = "native"
vision = true
''')
    if args.judge_endpoint:
        assert args.judge_model, '--judge-model is required with --judge-endpoint'
        text=cfg.read_text();cfg.write_text('compare_model = "judge"\n'+text+f'''\n[models.judge]
provider = "openai"
model = "{args.judge_model}"
base_url = "{args.judge_endpoint}"
context_window = 8192
vision = true
''')
    (output/'target.png').write_bytes(png());(output/'page.html').write_text('<!doctype html><style>html,body{margin:0;background:#508764;width:100%;height:100%}</style><h1>Frog capture</h1>')
    page=args.page.resolve().as_uri() if args.page else (output/'page.html').as_uri()
    VisualFixture.capture_args={'url':page,'width':args.width,'height':args.height,'output_path':'actual.png'}
    if args.target:
        assert args.screenshot_endpoint and args.page, 'an existing target requires a real renderer and --page'
        (output/'target.png').write_bytes(args.target.read_bytes())
    elif args.screenshot_endpoint:
        import urllib.request
        request=urllib.request.Request(endpoint,data=json.dumps({'url':page,'width':args.width,'height':args.height,'settle_ms':200}).encode(),headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=45) as response:
            (output/'target.png').write_bytes(base64.b64decode(json.load(response)['data'][0]['b64_json']))
    frog=Frog(args.frog.resolve(),cfg,output)
    try:
        frog.send(op='submit',text='Rebuild the target with a bounded visual loop.')
        while True:
            event=frog.until(lambda e:e['event'] in ('permission_request','turn_ended'),timeout=300 if args.judge_endpoint else 30)
            if event['event']=='turn_ended': break
            frog.send(op='permission',id=event['id'],decision='allow')
        frog.until(lambda e:e['event']=='idle')
        (output/'events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in frog.events))
        completed=[e['item'] for e in frog.events if e['event']=='item_completed' and e['item'].get('name') in ('Screenshot','Compare')]
        assert [x['name'] for x in completed]==['Screenshot','Compare','Compare'],completed
        assert completed[0]['outcome']=='ok' and completed[0]['images'],completed[0]
        assert completed[1]['outcome']=='ok',completed[1]
        verdict=json.loads(completed[1]['output']);assert verdict['stop_reason']=='matched',verdict
        if not args.judge_endpoint:
            assert verdict['target_description']=='A matching reference page.' and verdict['actual_description']=='The same rendered page.',verdict
        assert completed[2]['outcome']=='error' and 'already stopped' in completed[2]['output'],completed[2]
        assert VisualFixture.judge_calls==(0 if args.judge_endpoint else 1),VisualFixture.judge_calls
        state=json.loads((output/'.frog/visual-loops/fixture.json').read_text());assert state['stopped'] and len(state['target'])<500,state
        assert (output/'actual.png').exists()
        (output/'events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in frog.events))
        header={'type':'header','version':1,'id':'visual-loop','cwd':str(output),'model':'fixture','created':frog.events[0]['created']}
        (output/'visual-loop.jsonl').write_text(json.dumps(header)+'\n'+''.join(json.dumps({'type':'event','env':e})+'\n' for e in frog.events if e['event'] in ('turn_started','item_started','item_completed','turn_ended')))
        frog.close()
        frog=Frog(args.frog.resolve(),cfg,output)
        frog.send(op='submit',text='Verify the stopped visual loop after restarting Frog.')
        while True:
            event=frog.until(lambda e:e['event'] in ('permission_request','turn_ended'),timeout=300 if args.judge_endpoint else 30)
            if event['event']=='turn_ended':break
            frog.send(op='permission',id=event['id'],decision='allow')
        frog.until(lambda e:e['event']=='idle')
        assert VisualFixture.judge_calls==(0 if args.judge_endpoint else 1),'restarting bypassed durable stop'
        print(f'PASS capture, crop judging, score and durable stop across restart: {output}')
    finally: frog.close();server.shutdown();server.server_close()

if __name__=='__main__':main()
