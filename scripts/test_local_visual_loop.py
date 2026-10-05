#!/usr/bin/env python3
"""Opt-in fully local agent benchmark: generated target -> editable CSS -> Compare.
Requires running local image, vision/chat and screenshot services. No fixtures.
"""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
from test_image_tool import Frog


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frog', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--judge-base-url')
    parser.add_argument('--judge-model')
    parser.add_argument('--coder-no-vision', action='store_true')
    parser.add_argument('--write-only', action='store_true', help='Ask the model to revise by replacing the full file rather than using Edit')
    parser.add_argument('--image-endpoint', required=True)
    parser.add_argument('--screenshot-endpoint', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--context-window', type=int, default=16384)
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--tool-mode', choices=('json', 'text'), default='json')
    args = parser.parse_args()
    assert bool(args.judge_base_url) == bool(args.judge_model), 'specify both judge endpoint and model'
    assert not args.coder_no_vision or args.judge_base_url, 'a non-vision coder requires a separate vision judge'
    for endpoint in (args.base_url, args.image_endpoint, args.screenshot_endpoint, args.judge_base_url or args.base_url):
        url = urlsplit(endpoint)
        assert url.scheme == 'http' and url.hostname in ('localhost', '127.0.0.1', '::1'), 'benchmark endpoints must be local'
    output = args.output.resolve()
    output.mkdir()
    cfg = output / 'config.toml'
    # JSON quoting is also valid TOML string syntax and preserves paths literally.
    q = json.dumps
    cfg.write_text(f'''default_model = "local"
compare_model = {q('judge' if args.judge_base_url else 'local')}
load_claude_md = false
sandbox_shell = false
screenshot_endpoint = {q(args.screenshot_endpoint)}
[image]
backend = "tang"
endpoint = {q(args.image_endpoint)}
model = "z-image-turbo"
[models.local]
provider = "openai"
model = {q(args.model)}
base_url = {q(args.base_url)}
context_window = {args.context_window}
max_tokens = 2048
tool_mode = {q(args.tool_mode)}
vision = {'false' if args.coder_no_vision else 'true'}
thinking = "never"
[models.local.extra]
temperature = 0.0
''')
    if args.judge_base_url:
        with cfg.open('a') as f:
            f.write(f'''\n[models.judge]
provider = "openai"
model = {q(args.judge_model)}
base_url = {q(args.judge_base_url)}
context_window = 8192
max_tokens = 2048
vision = true
thinking = "never"
[models.judge.extra]
temperature = 0.0
''')
    frog = Frog(args.frog.resolve(), cfg, output)
    format_prompt = ('Every response MUST be a single JSON object with thought and action. To execute a tool use {"thought":"brief reason","action":{"tool":"Image","args":{"prompt":"...","size":"256x256","count":1,"seed":43,"steps":8,"output_dir":"assets"}}}. Use the same action structure for every other tool. Never write Python, tool_code, Markdown fences or simulated tool results. An answer action ends your turn, so use it only after Compare has stopped.' if args.tool_mode == 'json' else
        'Execute tools using <tool_call>{"name":"Image","arguments":{"prompt":"...","size":"256x256","count":1,"seed":43,"steps":8,"output_dir":"assets"}}</tool_call>. Use this tool_call format for every other tool. Never write Python, tool_code or simulated tool results. Stop after one tool call and wait for its result. Do not give a final answer until Compare has stopped.')
    prompt = format_prompt + '''\nComplete this small visual benchmark autonomously, working only in the current directory.
Use only Image, Write, Edit, Read, Screenshot and Compare. Do not use Bash, Task or other tools.
1. Generate ONE target with Image: prompt "A simple flat vector icon of a green frog face, two round eyes, symmetrical, centered, solid green shapes, white background, no text, no gradients, no shadows, minimalist app icon", size "256x256", count 1, seed 43, steps 8, output_dir "assets".
2. The Image result already includes the target image as vision input. Do not Read the binary PNG or Screenshot the PNG. Recreate its geometry and colors as editable HTML and CSS shapes in index.html, at a 256x256 viewport. Use CSS circles/ellipses. Do not embed the target or any raster image; no img, SVG, canvas, data URLs or CSS image URLs.
3. Screenshot index.html at width 256 and height 256 with a fresh output_path for every round, such as round-1.png.
4. Compare the generated saved PNG target against the screenshot, notes "Match the frog shape, eye placement, colors and white background; ignore minor antialiasing", loop_id "bench", threshold 85, max_rounds 6.
5. If stop_reason is continue, fix index.html using the differences, then screenshot and compare again with the SAME target and loop_id. Do not regenerate the target. Stop when matched, stalled or max_rounds.
Do not finish before the real Compare result. Report the final score and saved paths. Execute one tool action at a time.'''
    if args.coder_no_vision:
        prompt = prompt.replace('The Image result already includes the target image as vision input.',
            'Your coding model has no direct vision input. The Compare vision judge sees both the generated target and your captured page; use its differences and coordinates to refine your implementation.')
    if args.write_only:
        prompt += '\nFor every revision replace the complete index.html using Write. Do not use Edit; this avoids escaping a large old_string. You must still independently choose and execute the image, file, capture and comparison actions.'
    try:
        frog.send(op='submit', text=prompt)
        while True:
            event = frog.until(lambda e: e['event'] in ('permission_request', 'turn_ended'), timeout=args.timeout)
            if event['event'] == 'turn_ended':
                break
            name = event['name']
            allow = name in ('Image', 'Screenshot', 'Compare', 'Read', 'Write', 'Edit')
            if name in ('Write', 'Edit'):
                path = Path((event.get('preview') or {}).get('path', event['arg']))
                path = (output / path).resolve() if not path.is_absolute() else path.resolve()
                allow = allow and path.is_relative_to(output)
            frog.send(op='permission', id=event['id'], decision='allow' if allow else 'deny')
            print(f'Permission {name}: {"allow" if allow else "deny"}', flush=True)
        frog.until(lambda e: e['event'] == 'idle')
        successful = [e['item'] for e in frog.events if e['event'] == 'item_completed' and e['item'].get('outcome') == 'ok']
        names = [item.get('name') for item in successful]
        assert all(name in names for name in ('Image', 'Screenshot', 'Compare')) and any(name in names for name in ('Write', 'Edit')), names
        html = (output / 'index.html').read_text()
        assert not re.search(r'<(?:img|svg|canvas)\b|data:image|url\s*\(', html, re.I), 'implementation embeds an image instead of editable CSS'
        state = json.loads((output / '.frog/visual-loops/bench.json').read_text())
        assert state['stopped'] and state['scores'][-1] >= 85, state
        reports = [e['item']['text'] for e in frog.events if e['event'] == 'item_completed' and e['item'].get('type') == 'message']
        assert reports and not reports[-1].lstrip().startswith('{"thought"'), 'model ended with an unexecuted action instead of a final report'
        assert 'index.html' in reports[-1] and str(int(state['scores'][-1])) in reports[-1], 'final report must identify the implementation and score'
        print(f'PASS unattended local CSS visual loop: {state["scores"]}', flush=True)
    finally:
        (output / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in frog.events))
        if frog.events:
            header = {'type': 'header', 'version': 1, 'id': 'local-css-bench', 'cwd': str(output),
                'model': 'local', 'created': frog.events[0]['created']}
            (output / 'local-css-bench.jsonl').write_text(json.dumps(header) + '\n' + ''.join(
                json.dumps({'type': 'event', 'env': e}) + '\n' for e in frog.events
                if e['event'] in ('turn_started', 'item_started', 'item_completed', 'turn_ended')))
        frog.close()


if __name__ == '__main__':
    main()
