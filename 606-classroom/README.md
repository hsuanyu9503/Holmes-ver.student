# 606 情報局｜近距課堂

老師用一台**控制平板**帶領全班遊戲，**教室大螢幕**同步投影，學生用自己的平板**掃碼報到**、翻開身分卡並接收私人情報。三種畫面由同一台伺服器即時同步（Server-Sent Events），身分、對照表與機密代碼只存在伺服器，依身分過濾後才送到各裝置。

本專案從空白目錄撰寫，可獨立建置及部署，不依賴舊版 606 情報局的程式、Supabase 資料庫或 LiveKit。

- 執行環境：Node.js 20 以上（已在 Node 22 測試）
- 執行期相依套件：只有 `qrcode`（產生報到 QR Code）
- 不需要資料庫；課堂資料存在記憶體並定期寫入 `DATA_DIR/rooms.json`

---

## 1. 快速開始（本機）

```bash
cd 606-classroom
```

```bash
npm ci
```

```bash
npm start
```

啟動後開啟 <http://localhost:3606>，按「建立新課堂」。若要讓教室裡的平板連線，請用電腦的區網 IP（例如 `http://192.168.1.20:3606`），或依第 4 節部署到公開網址。

選填設定：複製 `.env.example` 為 `.env` 後修改（說明見第 5 節）。

## 2. 三種畫面的進入方式

| 使用者 | 網址 | 說明 |
|---|---|---|
| 教師控制平板 | `/` → 「建立新課堂」 → 自動進入 `/teacher.html?room=房間碼` | 建立課堂時會在這台裝置存下教師金鑰。要換裝置操作，在控制台按「投影畫面」可看到含金鑰的控制台連結（請勿外流）。 |
| 教室大螢幕 | `/s/房間碼` | 在接投影機的電腦開啟，按右下角「全螢幕」。只顯示公開資訊，不需要登入。 |
| 學生平板 | 掃控制台「QR Code」，或開 `/j/房間碼` | 房間碼由連結帶入，學生只輸入姓名、點選組別。 |

## 3. 一輪課堂流程

1. **報到**：學生掃碼 → 輸入姓名、點選第 1～6 組 → 「加入情報任務」→ 等待畫面。大螢幕只顯示「606 情報局｜任務集結中」與即時人數（教師、投影不計入；學生重整不重複計入）。
2. **選人**：教師平板依組別列出學生，每組點一人（金色標示，啟動前可改選）。六組都選好才可按「啟動身分認證」。可在此選情報卡主題（自動輪替、10 組內建主題或自訂九個詞語）。
3. **身分認證**：系統在六名玩家中隨機分配 **5 名情報員 + 1 名臥底**，其餘學生為**局內人（觀察員）**。大螢幕播放「正在啟動身份認證⋯」；所有學生平板一律顯示卡背，點卡即翻牌並算確認。教師平板顯示「玩家已翻牌 x／6」，局內人翻牌另計、不影響進度。
4. **擲骰**：六名玩家都翻牌後，「擲骰」才可按。藍骰 1～6、紅骰 1／1／2／2／3／3，由伺服器統一產生。大螢幕跳動約 2.6 秒後定格「藍 4 ／ 紅 3」。動畫結束時伺服器才釋出：情報員與局內人的金框顯示本輪代碼（如 B2），臥底的金框顯示「機密任務：觀察其他玩家的發言，推理本輪的機密情報。」
5. **公開情報卡**：老師留時間讓學生看平板後按「公開情報卡」，大螢幕與全班平板同時顯示同一張未標記答案的 3×3 卡。發言由老師現場點名、投票由老師現場計票（學生端沒有發言或投票按鈕）。大螢幕下方的步驟提示可選擇切換。
6. **結局**：教師平板操作
   - 點「第 N 組」= 最高票組別 → 系統判定：不是臥底 → **臥底勝利！**（玩家指認錯人）；是臥底 → 進入最後一猜。
   - 「重投後仍平手」→ **臥底勝利！**（再次投票仍平手）。
   - 最後一猜：臥底口頭猜一次，老師在 3×3 卡上點選臥底說的詞語並確認 → 猜中 **臥底逆轉勝利！**／猜錯 **情報員勝利！**。
   老師不需要事先知道答案；判定由伺服器完成，確認後才公布結局、臥底身分與機密詞語。
7. **下一輪**：保留全班名單與組別（學生免重新掃碼），預選上一輪六人，可部分或全部換人。身分、翻牌、骰點、代碼、公開卡、結局全部重新建立。

其他：學生同一輪重整或重新連線會回到自己當下的階段，身分與翻牌紀錄不變；本輪進行中才報到的學生自動成為局內人。「作廢本輪，回到選人」可在操作失誤時重來；「名單管理」可移除學生，或在學生換裝置時「允許重新登入」（以相同姓名＋組別接回原紀錄，舊裝置自動登出）。

## 4. 獨立部署

伺服器把課堂狀態放在記憶體，**請部署為單一長時間執行的實例**（不要水平擴充成多台，也不能用 Serverless／Edge Function，因為需要長連線 SSE）。

### 4.1 任何 Linux 主機／VM

```bash
git clone <你的 repo> && cd <repo>/606-classroom
```

```bash
npm ci --omit=dev
```

```bash
PORT=3606 DATA_DIR=/var/lib/intel606 TEACHER_PASSCODE=自訂通行碼 node server/index.js
```

建議用 systemd 或 pm2 常駐，前面放 HTTPS 反向代理（Nginx／Caddy）。Nginx 需讓 SSE 不被緩衝：

```nginx
location / {
  proxy_pass http://127.0.0.1:3606;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_buffering off;
  proxy_read_timeout 1h;
}
```

### 4.2 Docker

```bash
docker build -t intel606-classroom .
```

```bash
docker run -d --name intel606 -p 3606:3606 -v intel606-data:/data -e TEACHER_PASSCODE=自訂通行碼 intel606-classroom
```

### 4.3 PaaS（Render、Railway、Fly.io 等）

- Root directory：`606-classroom`
- Build：`npm ci --omit=dev`；Start：`npm start`（或直接用 Dockerfile）
- 環境變數：`TEACHER_PASSCODE`、（選填）`PUBLIC_BASE_URL`
- 若平台提供永久磁碟，掛載後設定 `DATA_DIR` 指向該路徑；沒有磁碟也能運作，只是重新部署時進行中的課堂會消失。
- Health check：`/healthz`

## 5. 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `PORT` | `3606` | 監聽埠 |
| `HOST` | `0.0.0.0` | 監聽位址 |
| `DATA_DIR` | `./data` | 課堂存檔目錄；設為空字串則只存在記憶體。閒置 24 小時的課堂自動清除。 |
| `TEACHER_PASSCODE` | （空） | 設定後，建立課堂需輸入此通行碼。公開部署建議設定。 |
| `PUBLIC_BASE_URL` | （空） | QR Code 使用的對外網址；未設定時依請求的 Host／X-Forwarded-Proto 判斷。 |

## 6. 專案結構

```
606-classroom/
├─ server/
│  ├─ index.js     進入點（讀 .env、啟動 HTTP）
│  ├─ app.js       路由、SSE 即時同步、QR Code、靜態檔
│  ├─ game.js      遊戲核心：報到、選人、角色、翻牌、骰子、對照表、結局、各端視圖過濾
│  ├─ decks.js     內建 3×3 情報卡主題
│  └─ store.js     記憶體＋JSON 檔持久化
├─ public/
│  ├─ index.html   教師首頁（建立課堂）
│  ├─ teacher.html 教師控制平板
│  ├─ screen.html  教室大螢幕
│  ├─ join.html    學生平板
│  ├─ css/ js/     樣式與前端程式（原生 ES modules，無需打包）
│  └─ img/         由素材包裁切、壓縮的 WebP
├─ tests/
│  ├─ game.test.js       遊戲規則與權限單元測試
│  ├─ api.test.js        HTTP／SSE 整合測試（23 人、兩輪）
│  └─ e2e/classroom.e2e.mjs  瀏覽器端對端測試（Playwright）
├─ docs/CLASSROOM-CHECKLIST.md  真實教室裝置驗收表
├─ Dockerfile  .env.example
```

### 資料結構（`server/game.js`）

```text
Room {
  code, teacherKey, createdAt, updatedAt,
  students: { id → { id, name, group(1-6), token, variant('m'|'f'), joinedAt, reclaimable } },
  order: [studentId…],              // 報到順序
  selection: { 1..6 → studentId|null },  // 選人（下一輪預選上一輪玩家）
  deckChoice: 'auto' | 內建主題 id | 'custom', customDeck, usedDecks,
  roundNo, phase: 'lobby'|'identity'|'dice'|'card'|'guess'|'ending',
  round: {
    no, players: { 1..6 → studentId }, roles: { studentId → 'agent'|'spy'|'insider' }, spyId,
    flipped: { studentId → 時間 },
    codeMap: [18 個代碼],            // 藍 1～6 列 × 紅 1～3 欄；A1～C3 各兩次（洗牌）
    deck: { title, words[9] },        // A1 B1 C1 / A2 B2 C2 / A3 B3 C3
    dice: { blue, red, rolledAt, revealAt }, secretCode = codeMap[(藍-1)*3 + (紅-1)],
    cardPublic, step, accusedGroup, guessCode, ending: { type, at }
  },
  history: [ { no, type, deck, code, at } ]
}
```

### 權限（後端判定）

| 資料 | 教師平板 | 大螢幕 | 情報員／局內人 | 臥底 |
|---|---|---|---|---|
| 名單、選人、翻牌進度 | ✓ | 只有人數 | 只有自己 | 只有自己 |
| 自己的身分 | — | — | 翻牌後 | 翻牌後 |
| 骰點 | ✓ | ✓ | — | — |
| 對照表 `codeMap`、身分分配 | ✗ | ✗ | ✗ | ✗ |
| 本輪代碼 | 結局後 | 結局後 | 骰子動畫結束後 | 結局後 |
| 九個詞語 | 公開後 | 公開後 | 公開後 | 公開後 |

對照表與身分分配從不離開伺服器。代碼釋出時間由伺服器時間控制（`REVEAL_DELAY_MS = 2600`），並在那一刻主動推播。

## 7. API

| 方法 | 路徑 | 說明 |
|---|---|---|
| POST | `/api/rooms` | 建立課堂 `{passcode?}` → `{code, teacherKey}` |
| GET | `/api/rooms/:code` | 課堂是否存在 |
| POST | `/api/rooms/:code/join` | 報到 `{name, group}` 或 `{token}` → `{token, studentId}` |
| POST | `/api/rooms/:code/flip` | 翻牌 `{token}` → 學生視圖 |
| POST | `/api/rooms/:code/teacher` | 教師操作 `{key, action, …}`：`select`、`deck`、`start`、`roll`、`publish`、`step`、`accuse`、`tie`、`guess`、`next`、`abort`、`remove`、`unlock` |
| GET | `/api/rooms/:code/events?as=display` ／ `as=teacher&key=` ／ `as=student&token=` | SSE 即時視圖 |
| GET | `/api/rooms/:code/state?…` | 同上，一次性 |
| GET | `/api/rooms/:code/qr.svg` | 報到 QR Code |
| GET | `/j/:code`、`/s/:code`、`/t/:code` | 學生／投影／教師短網址 |

## 8. 測試

```bash
npm test
```

單元＋整合測試（Node 內建 test runner）：骰子機率、對照表、報到去重、選人、角色數量、翻牌門檻、各端資料不外洩、四種結局、下一輪換人、重新連線、持久化。

```bash
npm run test:e2e -- ./screenshots
```

瀏覽器端對端測試（需要已安裝 Playwright 與 Chromium，例如 `npm i -D playwright && npx playwright install chromium`）：教師、投影、3 台學生平板（含 1 台手機尺寸）與 20 名 API 學生共 23 人，連續跑 4 輪涵蓋四種結局與部分換人；附上資料夾參數會輸出各畫面截圖。

## 9. 素材對照

| 素材 | 用途 |
|---|---|
| 圖 1～3 | 登入、學生等待、集結人數（以 HTML／CSS 重現版面） |
| 圖 4～8 | 翻牌（卡背自圖 4 裁切為 `img/card-back.webp`）、私人情報、投影認證轉場 |
| 圖 9 | 公開 3×3 情報卡（版面重現；詞語依本局主題） |
| 圖 10／11／12 | 結局：情報員勝利／臥底勝利（錯指、平手共用）／臥底逆轉勝利。圖上原標語以面板覆蓋，改顯示本輪的標題與原因，避免與結果不一致。 |
| 圖 13 | 進度展示參考 → 大螢幕下方「① 輪流發言 ② 指認投票 ③ 最後一猜」 |
| 角色卡 5 張 | 情報員男／女、臥底男／女、局內人。男女版本在學生報到時隨機決定，整堂課固定。 |

示意圖中的姓名、人數、組別、骰點、B2 與詞語都只是範例，畫面一律依本局資料呈現。
- 截圖：`docs/screenshots/`（端對端測試實際畫面）
