// Test-only server for the Swift relay client. No real workspace data is used.
import net from 'node:net';
import { createRelay, parseConfig } from '../server.mjs';
const probe = net.createServer();
await new Promise((resolve, reject) => { probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve); });
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const relay = createRelay(parseConfig({ PUBLIC_ORIGIN: origin, THEALL_MAC_PUBLIC_KEY: process.env.THEALL_MAC_PUBLIC_KEY, PORT: String(port) }));
await relay.listen();
process.stdout.write(`${JSON.stringify({ port, origin })}\n`);
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => { await relay.close(); process.exit(0); });
