'use strict';
/** 課堂資料的持久化：記憶體為主，定期寫入 DATA_DIR/rooms.json，重啟後還原。 */
const fs = require('node:fs');
const path = require('node:path');

const ROOM_TTL_MS = 24 * 60 * 60 * 1000; // 閒置 24 小時的課堂自動清除

class Store {
  constructor(dataDir) {
    this.dataDir = dataDir;
    this.file = dataDir ? path.join(dataDir, 'rooms.json') : null;
    this.rooms = new Map();
    this.timer = null;
  }

  load() {
    if (!this.file || !fs.existsSync(this.file)) return;
    try {
      const data = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      for (const room of data.rooms || []) this.rooms.set(room.code, room);
    } catch (err) {
      console.error('[store] 無法讀取資料檔，改用空白狀態：', err.message);
    }
    this.prune();
  }

  get(code) {
    return this.rooms.get(String(code || '').toUpperCase()) || null;
  }

  add(room) {
    this.rooms.set(room.code, room);
    this.save();
  }

  prune(now = Date.now()) {
    for (const [code, room] of this.rooms) if (now - room.updatedAt > ROOM_TTL_MS) this.rooms.delete(code);
  }

  /** 延遲寫檔，合併短時間內的多次變更。 */
  save() {
    if (!this.file || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, 400);
  }

  flush() {
    if (!this.file) return;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    try {
      fs.mkdirSync(this.dataDir, { recursive: true });
      const tmp = this.file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify({ savedAt: Date.now(), rooms: [...this.rooms.values()] }));
      fs.renameSync(tmp, this.file);
    } catch (err) {
      console.error('[store] 寫入失敗：', err.message);
    }
  }
}

module.exports = { Store, ROOM_TTL_MS };
