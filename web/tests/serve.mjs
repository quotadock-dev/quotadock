import { createBridge } from '../../bridge/server.mjs';
const server = await createBridge({ token: 'a'.repeat(64), getSnapshot: async () => ({ schemaVersion: 1, demo: true, generatedAt: new Date().toISOString(), providers: [] }) });
server.listen(4317, '127.0.0.1');
