'use strict';
const path = require('node:path');
const { createApp } = require('./app');

loadDotEnv(path.join(__dirname, '..', '.env'));

const PORT = Number(process.env.PORT) || 3606;
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR = process.env.DATA_DIR === '' ? null : path.resolve(process.env.DATA_DIR || path.join(__dirname, '..', 'data'));

const { server } = createApp({
  dataDir: DATA_DIR,
  teacherPasscode: process.env.TEACHER_PASSCODE || '',
  publicBaseUrl: process.env.PUBLIC_BASE_URL || '',
});

server.listen(PORT, HOST, () => {
  console.log(`606 情報局｜近距課堂 已啟動： http://localhost:${PORT}`);
  console.log(`資料目錄：${DATA_DIR || '（不寫檔，僅記憶體）'}`);
  if (process.env.TEACHER_PASSCODE) console.log('建立課堂需輸入教師通行碼。');
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    server.close();
    // SSE 連線不會自行結束；寫檔後直接離開
    setTimeout(() => process.exit(0), 300).unref();
  });
}

/** 讀取簡單的 .env（KEY=VALUE），不覆寫已存在的環境變數。 */
function loadDotEnv(file) {
  let text;
  try {
    text = require('node:fs').readFileSync(file, 'utf8');
  } catch {
    return;
  }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m || line.trim().startsWith('#')) continue;
    const v = m[2].replace(/^(['"])(.*)\1$/, '$2');
    if (process.env[m[1]] === undefined) process.env[m[1]] = v;
  }
}
