export function startMock(opts?: { port?: number; fixture?: string; delayMs?: number; previewScript?: string }): Promise<{ port: number; close(): Promise<void> }>;
