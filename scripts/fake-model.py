#!/usr/bin/env python3
"""A fake OpenAI-compatible server that streams a long reply slowly, for eyeballing the TUI
without a real model:

    python3 scripts/fake-model.py &
    OPENAI_BASE_URL=http://127.0.0.1:8765/v1 frog -m openai/fake --tool-mode native

A message containing "tool" gets a Write call back, to try permission prompts, and one
containing "ask" an Ask question.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
WORDS = ("Here is a slow streamed reply so you can watch the status bar stay pinned "
         "to the bottom row while text scrolls above it. ") * 12
DELAY = 0.04


class H(BaseHTTPRequestHandler):
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client interrupted the reply

    def log_message(self, *a):
        pass

    def send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json({"data": [{"id": "fake", "context_length": 32768}]})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["content-length"])) or b"{}")
        if not req.get("stream"):
            # Probes and titles: answer at once.
            return self.send_json({
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": "ok"}}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 1},
            })
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def chunk(delta, finish=None, usage=None):
            c = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                c["usage"] = usage
            self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            self.wfile.flush()

        msgs = req.get("messages", [])
        last = msgs[-1] if msgs else {}
        text = json.dumps(last.get("content"))
        if last.get("role") == "user" and "ask" in text:
            args = {"question": "Which color?", "multi": True,
                    "options": [{"label": "red"}, {"label": "green", "detail": "the frog one"},
                                {"label": "blue"}]}
            call = {"index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "Ask", "arguments": json.dumps(args)}}
            chunk({"tool_calls": [call]})
            chunk({}, "tool_calls", {"prompt_tokens": 9000, "completion_tokens": 20})
            self.wfile.write(b"data: [DONE]\n\n")
            return
        if last.get("role") == "user" and "tool" in text:
            # Ask to write a file, so permission prompts can be tried (sandboxed Bash
            # commands don't ask).
            args = {"file_path": "fake-model-was-here.txt", "content": "ribbit\n"}
            call = {"index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "Write", "arguments": json.dumps(args)}}
            chunk({"tool_calls": [call]})
            chunk({}, "tool_calls", {"prompt_tokens": 9000, "completion_tokens": 20})
            self.wfile.write(b"data: [DONE]\n\n")
            return
        for i, w in enumerate(WORDS.split(" ")):
            chunk({"content": w + " "})
            if i % 20 == 19:
                chunk({"content": "\n"})
            time.sleep(DELAY)
        chunk({}, "stop", {"prompt_tokens": 9000, "completion_tokens": 300,
                           "prompt_tokens_details": {"cached_tokens": 8500}})
        self.wfile.write(b"data: [DONE]\n\n")


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
