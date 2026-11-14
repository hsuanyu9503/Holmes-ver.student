// 測試用：模擬 Supabase API Gateway（Kong）。
//   /rest/v1/*      → PostgREST
//   /realtime/v1/*  → Realtime（WebSocket，Host 帶租戶名稱 realtime-dev）
// 並提供以 JWT 秘鑰簽出的 anon key。僅供本機端對端測試使用。
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';

export function anonKey(secret) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ iss: 'supabase-demo', role: 'anon', iat: now, exp: now + 86400 })}`;
  return `${body}.${crypto.createHmac('sha256', secret).update(body).digest('base64url')}`;
}

export function createGateway({ rest = 'http://127.0.0.1:54330', realtime = 'http://127.0.0.1:54340' } = {}) {
  const R = new URL(rest);
  const RT = new URL(realtime);
  const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, accept-profile, content-profile, prefer, x-supabase-api-version',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
  };
  const server = http.createServer((req, res) => {
    if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
    if (!req.url.startsWith('/rest/v1/')) { res.writeHead(404, cors); return res.end(); }
    const up = http.request({ host: R.hostname, port: R.port, method: req.method, path: req.url.slice('/rest/v1'.length), headers: { ...req.headers, host: R.host } }, (u) => {
      const h = { ...u.headers };
      for (const k of Object.keys(h)) if (k.startsWith('access-control-')) delete h[k];
      res.writeHead(u.statusCode, { ...h, ...cors });
      u.pipe(res);
    });
    up.on('error', () => { res.writeHead(502, cors); res.end(); });
    req.pipe(up);
  });
  server.on('upgrade', (req, socket, head) => {
    if (!req.url.startsWith('/realtime/v1/')) return socket.destroy();
    const path = '/socket/' + req.url.slice('/realtime/v1/'.length);
    const up = net.connect(RT.port, RT.hostname, () => {
      const headers = { ...req.headers, host: `realtime-dev.localhost:${RT.port}` };
      up.write(`GET ${path} HTTP/1.1\r\n` + Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') + '\r\n\r\n');
      if (head && head.length) up.write(head);
      up.pipe(socket);
      socket.pipe(up);
    });
    up.on('error', () => socket.destroy());
    socket.on('error', () => up.destroy());
  });
  return server;
}
