# 近距課堂本機驗證（不需部署）

需要 PostgreSQL 16、Node 22、Playwright（含 Chromium）。

```bash
cd tests/classroom && npm install
createdb -h /tmp -p 5433 -U postgres e2e
psql -h /tmp -p 5433 -U postgres -d e2e -f supabase-stub.sql
psql -h /tmp -p 5433 -U postgres -d e2e -f ../../supabase/606-intelligence-v2.9.0-classroom-full-new-project.sql
node sql-test.js e2e                       # 58 項 SQL 檢查
node server.js "$(cd ../.. && pwd)" e2e 8606 &   # 網站＋模擬 API
node e2e.js ./shots                        # 教師＋大螢幕＋23 名學生端對端
```

- `supabase-stub.sql` 只模擬 Supabase 的 `auth.users`、`auth.uid()` 與角色，**不可**在正式專案執行。
- `mock-supabase.js` 取代 CDN 的 supabase-js；Realtime 以每 0.4 秒讀取房間版本模擬。
- 連線埠與資料庫位置寫在各檔開頭，請依環境調整。
