// Types for ws.mjs, the vendored mock's websocket (tests that run their own small gateway).
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
export type MockConn = { send: (text: string) => void; close: () => void; onmessage: ((text: string) => void) | null; onclose: (() => void) | null };
export declare function accept(req: IncomingMessage, socket: Duplex, opts?: { protocol?: string }): MockConn | null;
