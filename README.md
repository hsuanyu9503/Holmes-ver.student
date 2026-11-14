# 606 情報局 v2.9.0 Classroom｜部署與維護指南

**版本日期：2026-11-14。** 以 v2.8.0 Stable 為基準，新增「近距課堂」模式：老師用一台控制平板帶全班，學生掃碼報到，每輪六組各派一人上場。單機、近距小組、遠距文字、遠距語音的行為不變。

## v2.9.0 更新步驟（已在使用 v2.8.0 的專案）
1. **在下課時段**於 Supabase SQL Editor 執行 `supabase/606-v2.8.0-to-v2.9.0-classroom-upgrade.sql`（只新增資料表與函式；可重複執行，不刪改既有資料）。v2.7.x 專案先執行 2.7.1→2.8.0 升級檔，再執行本檔。
2. GitHub Pages 上傳／覆蓋：`online.html`、`assets/online-v2.9.0-classroom.js`、`assets/classroom-v2.9.0.js`、`assets/classroom-v2.9.0.css`、`assets/classroom/`（8 張 webp）。`online-config.js` 保留你自己的版本；`online-v2.8.0-stable.css`、`voice-v2.8.0-stable.js`、Edge Function 不需更動。
3. **Supabase → Authentication → Rate Limits**：全班學生在同一個校園網路（同一個對外 IP）同時匿名登入，預設的匿名登入上限（每小時每 IP 約 30 次）可能不夠。請把 *Anonymous sign-ins* 上限調到至少「每節課人數 × 2」（例如 100），並確認 Realtime 已啟用。
4. 頁尾應顯示 `v2.9.0 Classroom`。

## 近距課堂怎麼用
- **教師控制平板**：首頁選「近距課堂」→ 建立連線房間 → 按「🖥 投影畫面」把連結開在接投影機的電腦（全螢幕）。學生掃描控制台上的 QR Code（也可勾選「在大螢幕顯示報到 QR Code」）。
- 第 1～6 組各點選一名玩家 → 「啟動身分認證」→ 六名玩家都翻牌後「進入擲骰」→「擲骰」→ 學生私下看完後「公開情報卡」→ 現場發言、口頭投票 → 點選最高票玩家（或「重投後仍平手」）→ 若指認到臥底，臥底口頭猜一次，老師點選他說的詞 → 結局 → 「下一輪」（保留名單並預選上一輪六人）。
- 「取消本輪・重新選人」可在玩家缺席時中止本輪；「離開」不會結束課堂，可從「我的房間」重新進入。
- 需先在「情報卡資料庫」建立至少一張**啟用的 3×3** 情報卡。
- 臥底、投影端、教師端在結局前都拿不到機密代碼與正確詞語；判定由資料庫完成，老師不必事先知道誰是臥底。

## 遊戲模式
- **近距任務**：現場口頭討論，原有同步倒數、主控推進維持原樣。
- **遠距純文字**：逐座位輸入文字線索、文字聊天室，保留文字紀錄，不顯示語音面板。
- **遠距純語音**：逐座位口述線索與多人 LiveKit 即時討論；資料庫僅記錄必要的完成／略過進度，不錄音、不轉文字、不保存口述內容；投票階段關閉語音。

## 先分辨專案原有版本（v2.8.0 時期的升級表，保留供舊專案參考）
| 現在資料庫版本 | 需執行 SQL？ | 網站／Edge Function  |
| --- | --- | --- |
| v2.8.0 Beta.2（已完成先前升級） | **不需要** | 更新 GitHub Pages；Edge Function 若與 Beta.2 相同可保留 |
| v2.8.0 Beta / Beta.1（已執行 2.8 SQL） | **不需要** | 更新 GitHub Pages + 新版 Edge Function |
| v2.7.0 / v2.7.1 | **需要** | 執行 `supabase/606-v2.7.1-to-v2.8.0-stable-upgrade.sql`，再更新網站 + Edge Function |
| v2.8.0 Stable（要使用近距課堂） | **需要** | 執行 `supabase/606-v2.8.0-to-v2.9.0-classroom-upgrade.sql`，再更新網站 |
| 全新空白 Supabase 專案 | **需要** | 只用 `supabase/606-intelligence-v2.9.0-classroom-full-new-project.sql` 建立，再部署網站 + Edge Function |

**絕對不要在既有資料庫重跑 `full-new-project.sql`。** 正式更新之前先結束對局並備份。若 Beta.2 已能正常運作，請只用 `606-intelligence-v2.8.0-stable-web-update.zip` 即可。

## GitHub Pages
1. 在 repo 根目錄上傳 `online.html`（覆蓋）及 `assets/online-v2.8.0-stable.css`、`assets/online-v2.9.0-classroom.js`、`assets/classroom-v2.9.0.*`、`assets/classroom/`、`assets/voice-v2.8.0-stable.js`；`index.html` 與其他圖片沿用。
2. **保留你目前自己的 `online-config.js`**；本完整包附的是空白公開設定範例，不可覆寫既有設定。網頁右上「連線設定」可提供公開的 Supabase URL / publishable key；不得放 private/service_role secret。
3. 檢查頁尾是否顯示 `v2.9.0 Classroom`；若仍是 Beta，請強制重新整理或檢查 GitHub Pages 部署狀態。
4. 正式版 JS/CSS 使用獨立檔名，以降低瀏覽器快取使用舊版檔案的風險。舊版 Beta 資產不需立即刪除，也不會被新 HTML 引用。

## Supabase + LiveKit
- Edge Function：`supabase/functions/intel606-voice-token/index.ts`，部署名稱 **`intel606-voice-token`**，JWT 驗證 **保持啟用**。
- Supabase → Edge Functions → Secrets 必須具備 `LIVEKIT_URL`（wss://...livekit.cloud，無尾斜線）、`LIVEKIT_API_KEY`、`LIVEKIT_API_SECRET`。
- 只有遠距純語音房間的合法成員可取得語音憑證。加入先只有收聽權限；由 Edge Function 依 Supabase 實際遊戲階段與發言座位校正 LiveKit 發言權限。
- LiveKit API Secret **只能存放 Supabase Secrets**，不可放到 GitHub / online-config.js / 邀請連結。
- `supabase/config.toml` 保留 `verify_jwt = true`。若使用 Supabase Dashboard 直接編輯程式，仍須在函式設定確認 JWT 驗證啟用。

## 版本與依賴
- Supabase JavaScript CDN：`@supabase/supabase-js@2.119.0`（固定版，2026-11-04 已公開發行；LiveKit SDK 保留已使用的 `livekit-client@2.23.0`）。
- 這次只固定公開 CDN 的 Supabase 版本；無法在離線驗證實際 CDN 存取，部署後須確認 Supabase SDK 能正常載入，並執行登入／建房測試。

## 權限同步限制
- `UpdateParticipant` 可授予／撤銷語音發布權限；討論暫停時會要求關麥並撤權，恢復後仍需玩家自行點擊開麥。
- 房間狀態刷新與 LiveKit 權限更新**不是同一個資料庫交易**；在網路不良或用戶端中斷時，可能短暫延遲。不得宣稱完全即時、絕無競態。
- 目前未從使用者環境取得 Beta.2 的真實 LiveKit 雲端授權測試結果；請先依 `TESTING.md` 實測通過，再將本版視為正式公開使用的已驗收版本。

## 檔案說明
- `online.html` + `assets/online-v2.9.0-classroom.js` + `assets/online-v2.8.0-stable.css` + `assets/voice-v2.8.0-stable.js`：連線網頁主程式。
- `assets/classroom-v2.9.0.js` / `.css` / `assets/classroom/*.webp`：近距課堂三種畫面與素材（角色卡、卡背、結局圖已裁掉內嵌標語並壓縮）。
- `supabase/606-v2.8.0-to-v2.9.0-classroom-upgrade.sql`：給 **v2.8.0** 既有專案。
- `tests/classroom/`：本機驗證工具（不需部署；說明見該資料夾 README）。
- `supabase/606-v2.7.1-to-v2.8.0-stable-upgrade.sql`：給 **v2.7.0 / v2.7.1** 既有專案。
- `supabase/606-intelligence-v2.9.0-classroom-full-new-project.sql`：給 **新建空白** Supabase 專案（＝v2.8.0 全新建置＋v2.9.0 升級）。
- `supabase/functions/intel606-voice-token/index.ts`：給需要部署或更新 Edge Function 的專案。
- `RELEASE_NOTES.md`：變動與已知限制；`TESTING.md`：實機驗收表；`SHA256SUMS.txt`：每個封裝檔案的 SHA-256。
