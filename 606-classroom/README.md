# 606 情報局｜近距課堂（Supabase 版）

老師用一台**控制平板**帶領全班遊戲，**教室大螢幕**同步投影，學生用自己的平板**掃碼報到**、翻開身分卡、接收私人情報。

- **後端：Supabase**。遊戲規則全部寫成資料庫函式（`supabase/migrations/…_c606_classroom.sql`），即時同步用 Supabase Realtime。
- **前端：純靜態網頁**（`public/`），不需要建置。可以放在 GitHub Pages、Netlify、Cloudflare Pages 或任何靜態主機。
- 身分分配、18 格對照表與機密代碼**只存在資料庫**。前端只能呼叫函式，函式依教師金鑰、學生個人憑證或投影身分過濾資料後才回傳。

> 請使用**全新的 Supabase 專案**。本專案的資料表與函式都以 `c606_` 開頭，不會用到舊版 606 情報局的 `intel606_*` 資料表。

---

## 1. 建立 Supabase 後端（約 5 分鐘）

1. 到 <https://supabase.com> 登入，按 **New project** 建立新專案（區域建議選 Tokyo 或 Singapore）。
2. 進入專案，左側選單點 **SQL Editor** → **New query**。
3. 打開本 repo 的 `606-classroom/supabase/migrations/20261115000000_c606_classroom.sql`，**全部複製貼上**，按 **Run**。看到 `Success. No rows returned` 就完成了。這個檔案可以重複執行。
4. （建議）設定教師通行碼，避免陌生人建立課堂。在 SQL Editor 執行：
   ```sql
   insert into c606_private.settings (key, value) values ('teacher_passcode', '自訂通行碼')
   on conflict (key) do update set value = excluded.value;
   ```
   設定後，首頁「建立新課堂」會要求輸入這個通行碼。要取消就執行 `delete from c606_private.settings where key = 'teacher_passcode';`。
5. 到 **Project Settings → API**（新版介面為 **Project Settings → API Keys**），記下兩個值：
   - **Project URL**：`https://xxxxxxxx.supabase.co`
   - **anon public key**（新版叫 **Publishable key**，`sb_publishable_…`）

   這兩個值本來就會出現在網頁中，可以公開。**不要**使用 `service_role` 或 Secret key。

Realtime 不需要另外開啟：SQL 已把通知表 `c606_signals` 加入 `supabase_realtime` 發佈。如果在 **Database → Publications** 看不到它，請重新執行一次 SQL。

## 2. 發佈網站（取得網址）

### 方式 A：GitHub Pages（自動部署）

1. GitHub repo → **Settings → Secrets and variables → Actions → Variables** 分頁 → **New repository variable**，新增：
   | 名稱 | 值 |
   |---|---|
   | `C606_SUPABASE_URL` | 第 1 節的 Project URL |
   | `C606_SUPABASE_ANON_KEY` | 第 1 節的 anon／Publishable key |
2. **Settings → Pages** → **Build and deployment** 的 Source 選 **GitHub Actions**。
3. **Actions** 分頁 → 左側 **606 classroom → GitHub Pages** → **Run workflow**（選要部署的分支）。之後推送到 `main`／`master` 且修改 `606-classroom/public/` 時會自動重新部署。
4. 完成後網址是 `https://帳號.github.io/repo名稱/`，也會顯示在 Actions 執行結果與 Settings → Pages。

> 注意：一個 repo 只有一個 GitHub Pages 網站。如果這個 repo 目前已經用 Pages 放舊版網站，改成 GitHub Actions 後會被新網站取代。要兩者並存，請把 `606-classroom/` 放到另一個 repo，或用方式 B。

### 方式 B：其他靜態主機（Netlify、Cloudflare Pages、學校網頁空間）

1. 複製 `public/config.example.js` 為 `public/config.js`，填入 Project URL 與 anon key。
2. 上傳整個 `public/` 資料夾（Netlify 可直接拖放；Cloudflare Pages 的輸出目錄設為 `606-classroom/public`，不需建置指令）。

### 本機預覽

```bash
cd 606-classroom
```
```bash
cp public/config.example.js public/config.js
```
編輯 `public/config.js` 填入 Supabase 的值後：
```bash
npm run serve
```
開啟 <http://localhost:8606>。同一個 Wi-Fi 的平板可以用 `http://電腦IP:8606` 連線。

## 3. 三種畫面的進入方式

| 使用者 | 網址 | 說明 |
|---|---|---|
| 教師控制平板 | 網站首頁 → 「建立新課堂」 | 自動進入 `teacher.html?room=房間碼`。教師金鑰存在這台裝置；要換裝置，在控制台按「投影畫面」可看到含金鑰的連結（請勿外流）。 |
| 教室大螢幕 | `screen.html?room=房間碼` | 控制台「投影畫面」會列出完整網址。在投影電腦開啟後按右下角「全螢幕」。 |
| 學生平板 | 掃控制台「QR Code」 | 開啟 `join.html?room=房間碼`，學生只輸入姓名、點選組別。 |

QR Code 預設使用目前網址產生。若網站有自訂網域，可在 `config.js` 的 `publicBaseUrl`（或 GitHub 變數 `C606_PUBLIC_BASE_URL`）填入。

## 4. 一輪課堂流程

1. **報到**：學生掃碼 → 姓名、第 1～6 組 → 「加入情報任務」→ 等待畫面。大螢幕只顯示即時人數（教師與投影不計入，學生重整不重複計入）。
2. **選人**：教師平板依組別列出學生（綠點表示在線），每組點一人，六組都選好才能「啟動身分認證」。可選情報卡主題（自動輪替、10 組內建、或自訂九個詞語）。
3. **身分認證**：資料庫在六名玩家中隨機分配 5 名情報員與 1 名臥底，其餘為局內人。全班平板顯示卡背，點卡即翻牌並算確認。教師平板顯示「玩家已翻牌 x／6」，局內人翻牌另計、不影響進度。
4. **擲骰**：六名玩家都翻牌後才能擲骰。藍骰 1～6、紅骰 1／1／2／2／3／3，由資料庫產生並查對照表。大螢幕跳動約 2.6 秒後定格；動畫結束後資料庫才放行代碼：情報員與局內人看到代碼，臥底看到機密任務。
5. **公開情報卡**：老師留時間讓學生看平板後按下，全班看到同一張未標記答案的 3×3 卡。發言與投票在現場口頭進行。
6. **結局**：老師點最高票的組別，由資料庫判定是否為臥底；或按「重投後仍平手」。臥底被指認時，老師在九格卡上點選臥底口頭猜的詞語，由資料庫判定猜中或猜錯。老師不需要事先知道答案。
7. **下一輪**：保留名單，預選上一輪六人，可部分換人；身分、翻牌、骰點、代碼、公開卡、結局全部重建。

其他：學生同一輪重整會回到原階段；中途報到的學生自動成為局內人；「作廢本輪」可重來；「名單管理」可移除學生，或在學生換裝置時「允許重新登入」。

## 5. 專案結構

```
606-classroom/
├─ supabase/
│  ├─ migrations/20261115000000_c606_classroom.sql   資料表、遊戲函式、權限、Realtime（貼到 SQL Editor 即可）
│  └─ config.toml        Supabase CLI 本機開發設定
├─ public/                靜態網站（直接部署這個資料夾）
│  ├─ index.html  teacher.html  screen.html  join.html
│  ├─ config.example.js  → 複製為 config.js
│  ├─ css/  js/  img/
│  └─ vendor/            supabase-js 2.118.0、qrcode-generator 1.4.4（已內建，不依賴 CDN）
├─ tools/serve.mjs        本機預覽伺服器
├─ tests/
│  ├─ db.test.js          資料庫函式與權限測試
│  └─ e2e/                瀏覽器端對端測試
└─ docs/                  教室驗收表、畫面截圖
```

### 資料庫設計

| 物件 | 說明 | 瀏覽器可否存取 |
|---|---|---|
| `c606_private.rooms` | 課堂、教師金鑰、階段、選人、主題、歷史 | ✗ |
| `c606_private.students` | 姓名、組別、個人憑證、角色卡男女版本 | ✗ |
| `c606_private.rounds` | 本輪玩家、臥底、18 格對照表、骰點、代碼、結局 | ✗ |
| `c606_private.round_roles` | 每位學生本輪身分與翻牌時間 | ✗ |
| `c606_private.decks`／`settings` | 內建主題／教師通行碼 | ✗ |
| `public.c606_signals` | 房間碼＋版本號（Realtime 通知用，不含任何名單或代碼） | 只能讀 |
| `public.c606_*()` 函式 | `create_room`、`room_exists`、`requires_passcode`、`join`、`flip`、`view`、`teacher` | 可呼叫 |

`c606_teacher` 的操作：`select`、`deck`、`start`、`roll`、`publish`、`step`、`accuse`、`tie`、`guess`、`next`、`abort`、`remove`、`unlock`。

### 資料可見範圍（由資料庫函式判定）

| 資料 | 教師平板 | 大螢幕 | 情報員／局內人 | 臥底 |
|---|---|---|---|---|
| 名單、翻牌進度 | ✓ | 只有人數 | 只有自己 | 只有自己 |
| 自己的身分 | — | — | 翻牌後 | 翻牌後 |
| 骰點 | ✓ | ✓ | — | — |
| 對照表、身分分配 | ✗ | ✗ | ✗ | ✗ |
| 本輪代碼 | 結局後 | 結局後 | 動畫結束後 | 結局後 |
| 九個詞語 | 公開後 | 公開後 | 公開後 | 公開後 |

### 即時同步

每次狀態變更都會遞增 `c606_signals.version`。各裝置透過 Realtime 收到通知後，重新呼叫 `c606_view` 取得**自己可見**的資料。另外：
- 骰子動畫結束時間到時，各裝置自動重新讀取，拿到剛放行的代碼。
- 備援輪詢：Realtime 未連上時每 2 秒、連上時每 15 秒一次，所以學校網路擋 WebSocket 時仍可運作，只是慢一點。左下角會顯示「已連線」或「已連線（輪詢）」。
- 教師平板的在線綠點使用 Realtime Presence。

閒置 24 小時的課堂會在下次建立課堂時自動清除。

## 6. 測試

測試需要一個套用了本專案 SQL 的 Supabase（或 Postgres）。在自己的電腦上最簡單的方法是 Supabase CLI（需要 Docker）：

```bash
cd 606-classroom
```
```bash
npm install
```
```bash
npx supabase start
```

**資料庫測試**（15 項：骰子機率、對照表、報到去重、角色數量、翻牌門檻、各端資料不外洩、四種結局、下一輪換人、重新連線、主題、Realtime 版本號）：
```bash
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres npm test
```

**瀏覽器端對端測試**（需要 Playwright：`npm i -D playwright && npx playwright install chromium`）：教師、投影、3 台學生平板與 20 名 API 學生共 23 人，連跑 4 輪涵蓋四種結局、部分換人，並檢查 Realtime 是否即時更新。
```bash
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<supabase start 顯示的 anon key> DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres npm run test:e2e -- ./screenshots
```

測試會建立測試用課堂，請**不要**對正式上課用的 Supabase 專案執行。

## 7. 素材對照

| 素材 | 用途 |
|---|---|
| 圖 1～3 | 登入、學生等待、集結人數 |
| 圖 4～8 | 翻牌（卡背自圖 4 裁切）、私人情報、投影認證轉場 |
| 圖 9 | 公開 3×3 情報卡（詞語依本局主題） |
| 圖 10／11／12 | 情報員勝利／臥底勝利（錯指、平手共用）／臥底逆轉勝利。圖上原標語以面板覆蓋，改顯示本輪標題與原因。 |
| 圖 13 | 大螢幕下方步驟提示 |
| 角色卡 5 張 | 情報員男／女、臥底男／女、局內人；男女版本在報到時隨機決定。 |

示意圖中的姓名、人數、組別、骰點、代碼與詞語都只是範例。截圖見 `docs/screenshots/`。
