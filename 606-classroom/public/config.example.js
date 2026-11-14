// 606 情報局｜近距課堂 — 前端連線設定
// 複製為 config.js 並填入 Supabase 專案的值（Project Settings → API）。
// anon（publishable）key 本來就會公開在網頁中；請勿放 service_role／secret key。
window.INTEL606_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabaseAnonKey: 'YOUR-ANON-PUBLIC-KEY',
  // 選填：QR Code 使用的網站網址（例如 https://帳號.github.io/repo/606-classroom/public/）。
  // 留空則自動使用目前網址。
  publicBaseUrl: '',
};
