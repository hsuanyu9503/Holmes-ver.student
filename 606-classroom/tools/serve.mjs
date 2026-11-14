// 本機預覽用的靜態伺服器（正式環境直接用 GitHub Pages 等靜態主機即可）。
//   npm run serve                    → http://localhost:8606 ，使用 public/config.js
//   SUPABASE_URL=… SUPABASE_ANON_KEY=… npm run serve  → 以環境變數產生 config.js
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.txt': 'text/plain; charset=utf-8' };

export function createStaticServer({ supabaseUrl, supabaseAnonKey } = {}) {
  return http.createServer((req, res) => {
    const url = new URL(req.url, 'http://local');
    let p = decodeURIComponent(url.pathname);
    if (p.endsWith('/')) p += 'index.html';
    if (p === '/config.js' && supabaseUrl) {
      res.writeHead(200, { 'Content-Type': TYPES['.js'], 'Cache-Control': 'no-store' });
      return res.end(`window.INTEL606_CONFIG = ${JSON.stringify({ supabaseUrl, supabaseAnonKey, publicBaseUrl: '' })};\n`);
    }
    const file = path.normalize(path.join(ROOT, p));
    if (!file.startsWith(ROOT + path.sep)) { res.writeHead(404); return res.end(); }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); return res.end('Not found'); }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      res.end(data);
    });
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT) || 8606;
  createStaticServer({ supabaseUrl: process.env.SUPABASE_URL, supabaseAnonKey: process.env.SUPABASE_ANON_KEY })
    .listen(port, () => console.log(`606 情報局｜近距課堂（本機預覽）：http://localhost:${port}`));
}
