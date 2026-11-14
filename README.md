# 606 情報局 v2.8.0 Stable｜部署與維護指南

**版本日期：2026-11-08。** 此包以 v2.8.0 Beta.2 + Beta.1 版面修正為來源，統一正式版檔名及文件。既有遊戲核心、資料庫可執行 SQL、語音授權程式的行為均未重寫。

## 遊戲模式
- **近距任務**：現場口頭討論，原有同步倒數、主控推進維持原樣。
- **遠距純文字**：逐座位輸入文字線索、文字聊天室，保留文字紀錄，不顯示語音面板。
- **遠距純語音**：逐座位口述線索與多人 LiveKit 即時討論；資料庫僅記錄必要的完成／略過進度，不錄音、不轉文字、不保存口述內容；投票階段關閉語音。

## 重要：先分辨專案原有版本
| 現在資料庫版本 | 需執行 SQL？ | 網站／Edge Function  |
| --- | --- | --- |
| v2.8.0 Beta.2（已完成先前升級） | **不需要** | 更新 GitHub Pages；Edge Function 若與 Beta.2 相同可保留 |
| v2.8.0 Beta / Beta.1（已執行 2.8 SQL） | **不需要** | 更新 GitHub Pages + 新版 Edge Function |
| v2.7.0 / v2.7.1 | **需要** | 執行 `supabase/606-v2.7.1-to-v2.8.0-stable-upgrade.sql`，再更新網站 + Edge Function |
| 全新空白 Supabase 專案 | **需要** | 只用 `supabase/606-intelligence-v2.8.0-stable-full-new-project.sql` 建立，再部署網站 + Edge Function |

**絕對不要在既有資料庫重跑 `full-new-project.sql`。** 正式更新之前先結束對局並備份。若 Beta.2 已能正常運作，請只用 `606-intelligence-v2.8.0-stable-web-update.zip` 即可。

## GitHub Pages
1. 在 repo 根目錄上傳 `online.html`（覆蓋）及 `assets/online-v2.8.0-stable.css`、`assets/online-v2.8.0-stable.js`、`assets/voice-v2.8.0-stable.js`；`index.html` 與其他圖片沿用。
2. **保留你目前自己的 `online-config.js`**；本完整包附的是空白公開設定範例，不可覆寫既有設定。網頁右上「連線設定」可提供公開的 Supabase URL / publishable key；不得放 private/service_role secret。
3. 檢查頁尾是否顯示 `v2.8.0 Stable`；若仍是 Beta，請強制重新整理或檢查 GitHub Pages 部署狀態。
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
- `online.html` + `assets/online-v2.8.0-stable.*` + `assets/voice-v2.8.0-stable.js`：正式版網頁（現有專案主要更新項目）。
- `supabase/606-v2.7.1-to-v2.8.0-stable-upgrade.sql`：給 **v2.7.0 / v2.7.1** 既有專案。
- `supabase/606-intelligence-v2.8.0-stable-full-new-project.sql`：給 **新建空白** Supabase 專案。
- `supabase/functions/intel606-voice-token/index.ts`：給需要部署或更新 Edge Function 的專案。
- `RELEASE_NOTES.md`：變動與已知限制；`TESTING.md`：實機驗收表；`SHA256SUMS.txt`：每個封裝檔案的 SHA-256。
