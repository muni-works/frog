export function startMock(opts?: { port?: number; fixture?: string; delayMs?: number }): Promise<{ port: number; close(): Promise<void> }>;
