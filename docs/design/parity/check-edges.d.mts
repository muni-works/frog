// Types for check-edges.mjs, for apps/web/test/transcript-edges.test.ts.
export type Element = { kind: string; part: string; text: string; left: number; right: number; claims: string[] };
export type Dump = { format: string; app: string; width: number; height: number; look: string; column: number; indent: number; elements: Element[] };
export declare const REQUIRED: string[];
export declare function check(d: Dump, opts?: { tolerance?: number; require?: boolean }): string[];
export declare function table(d: Dump, tolerance?: number): string;
