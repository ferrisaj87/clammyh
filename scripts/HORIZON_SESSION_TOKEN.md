# Horizon "API" access for `update_ah_prices.ps1`

## From ClammyHorizon (in game)

**Recommended:** Install the Chrome extension (`chrome-extension/README.md`) and the token is captured automatically whenever you visit horizonxi.com.

**Already have a token on disk:** **`/clammyh reloadah token`** -- reads **`horizon_bearer.txt`** from `config/addons/ClammyHorizon/data/` only, no browser.

**Disk only:** **`/clammyh reloadah local`** -- re-applies **`data/ah_prices.json`** without HTTP.

Logs/data: **`Game\config\addons\ClammyHorizon\data\`**. **`/clammyh reloadah unlock`** if stuck.

---

Horizon's AH numbers are served from **`api.horizonxi.com`**. The site does **not** advertise a permanent "personal API key" portal for addons. What the updater uses is the same credential your **logged-in browser** sends: an **`Authorization: Bearer ...`** value (typically a JWT) on each API request.

Treat it like a **session password**: anyone who has it can act as your site session until it expires. **Do not paste it into Discord**, stream it on screen, or commit it to git.

---

## Fastest manual grab (~60 seconds)

1. Open **Chrome** and log into **[horizonxi.com](https://horizonxi.com)** normally.
2. Press **F12** -> **Network** tab -> enable **Preserve log**.
3. In the filter box type **`api.horizonxi`**.
4. Navigate to **any item** that shows AH / sale info.
5. Click a **`.../auction-detail?stack=...`** row.
6. Open **Headers** -> **Request Headers** -> find **`authorization`**: `Bearer eyJhbGciOi...`
7. Copy **only** the long string **after** `Bearer ` -- **`update_ah_prices.ps1`** strips a leading **`Bearer`** for you.

Set it for the **current** PowerShell window (good for one session):

```powershell
$env:HORIZONXI_TOKEN = 'paste_the_long_string_here'
cd <path\to\addons\clammyhorizon>
powershell -NoProfile -File .\scripts\update_ah_prices.ps1
```

---

## Expiry

These tokens **expire** after ~3 days. If the script starts returning **401** / empty data, visit horizonxi.com while logged in and the Chrome extension will capture a fresh token automatically.

---

## Still stuck?

Run **vendor-only** (no Horizon HTTP) as a last resort -- does **not** pull live AH medians:

```powershell
.\scripts\update_ah_prices.ps1 -NoApi
```
