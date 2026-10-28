# DOMOS Lucky Spin

DOMOS 展場幸運轉盤。客人輸入手機號就能轉，不用登入。資料存在你自己的 Supabase，網站放在 Vercel。

- **伺服器決定獎品**：Supabase 的 `spin()` 函式負責抽獎、扣庫存、產生兌換碼。網頁只負責把轉盤轉到伺服器給的那一格，所以指針停的格子一定等於出來的獎品。
- **防超發**：多台 iPad 同時轉，庫存也不會變負數；同一個號碼連按也只算一次。
- **員工後台**：連點左上角 Logo 5 次，或打開 `你的網址/#staff`，輸入 PIN。可以兌換、查紀錄、導出 CSV、改獎品和機率、改每日次數。
- **三種風格**：後台 **Event settings → Look** 可以切換 Luxe（預設，深藍金色）、Graphite（炭灰＋香檳金）、Classic（深色海軍藍＋黃銅）、Neon（Cyberpunk）。選了會先預覽，按 Save 後所有 iPad 一起換。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `index.html` | 整個網站（客人頁 + 員工後台） |
| `config.js` | Supabase 網址和 publishable key |
| `supabase/schema.sql` | 資料表、抽獎函式、權限、預設 6 個獎品 |
| `manifest.webmanifest`, `icons/` | 讓 iPad「加入主畫面」後全螢幕執行 |
| `vercel.json` | Vercel 設定 |

## 第一次設定

### 1. Supabase：建立資料表

1. 打開 [Supabase](https://supabase.com/dashboard) → 你的專案 → 左邊 **SQL Editor** → **New query**。
2. 把 `supabase/schema.sql` 全部內容貼上，按 **Run**。看到 `Success. No rows returned` 就完成了。
3. 這個 SQL 可以重複執行，不會清掉資料。之後更新版本（例如加入主題切換）時，再貼一次執行即可。

### 2. Vercel：上線

1. 打開 [vercel.com/new](https://vercel.com/new)，用 GitHub 登入。
2. 選 `domos-lucky-spin` 這個 repo → **Import**。
3. Framework Preset 選 **Other**，其他都不用改，按 **Deploy**。
4. 完成後會得到一個網址，例如 `domos-lucky-spin.vercel.app`。之後每次 push 到 GitHub，Vercel 會自動更新。
5. 想用自己的網域（例如 `spin.domos.com.my`）：Vercel 專案 → **Settings → Domains** 加上去，再到你的 DNS 加一筆 CNAME。

### 3. 馬上改 PIN

預設 PIN 是 **8888**。上線後先進後台 → **Event settings** → 改成 6 位數字的新 PIN。

### 4. iPad 設定（全螢幕、沒有網址列）

1. 用 Safari 打開網站。
2. 按分享按鈕 → **加入主畫面**。
3. 從主畫面的 DOMOS Spin 圖示打開，就是全螢幕，沒有任何瀏覽器工具列。
4. 建議到 **設定 → 輔助使用 → 引導使用模式** 開啟，展場時客人就跳不出這個 App。

### 5. 活動開始前

先自己轉幾次測試，然後到後台 **Event settings** 最下面輸入 `RESET`，清除測試紀錄並把庫存補回總數。

## 安全說明

- `config.js` 裡的 publishable key 本來就是公開的。資料表開了 Row Level Security，而且沒有任何 policy，瀏覽器無法直接讀寫資料表，只能呼叫 `schema.sql` 裡授權的函式。
- 員工功能都要帶 PIN，PIN 只存在資料庫裡，不會出現在網頁原始碼。
- PIN 輸錯 10 分鐘內超過 20 次會暫時鎖住。
- 需要網路才能轉（每次都要跟 Supabase 確認庫存）。

## 什麼時候需要做什麼

- **後台改獎品、機率、庫存、活動設定、主題**：直接在 Control Room 按 Save，立刻存進 Supabase。不用 push，也不用跑 SQL。
- **改網站程式或設計**：push 到 GitHub，Vercel 會自動更新。
- **改資料庫結構**（`schema.sql` 有更新時）：到 Supabase SQL Editor 重跑一次 `schema.sql`。
