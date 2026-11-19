// Types for edges.mjs, for apps/web/test/transcript-edges.test.ts.
import type { Dump } from "./check-edges.mjs";
export declare function measureEdges(): unknown;
export declare function measureURL(url: string, w: number, h: number, look?: string, opts?: { wait?: number; storage?: Record<string, string> }): Promise<Dump>;
