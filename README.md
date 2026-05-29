# ClammyHorizon
FFXI addon for AshitaXI v4 that displays basic clamming information and pulls relevent AH data for Horizon server. Bucket size & weight, countdown timer, and contents.

**Updated By Ferris** (Original Designers: MathMatic/DrifterX)

### Cleaning up old config
If you are updating from a previous version, please delete your old config file at:

`%gameinstalldirectory%\Game\config\addons\ClammyHorizon\%charactername%_######\settings.lua`

## Commands:
### Options
 `/clammyh` *Opens a config menu for general configs*
 `/clammyh showvalue [true/false/...]` *Turn display of estimated value on/off*
 `/clammyh showitems [true/false/...]` *Turn display of individual items on/off*
 `/clammyh log [true/false/...]` *Turns on/off CSV-style dig logging - files under `Game\config\addons\ClammyHorizon\<CharName>\logs\`*
 `/clammyh tone [true/false/...]` *Turns on/off playing a tone when clamming point is ready to dig*
 `/clammyh logbrokenbucketitems [true/false/...]` *Turns on/off logging if the bucket breaks*
 `/clammyh showsessioninfo [true/false/...]` *Turns on/off showing gil/hr, buckets purchased, and total gil earned*
 `/clammyh usebucketvalueforweightcolor [true/false/...]` *turns on/off current weight value turning red at certain gil amounts*
 `/clammyh setweightvalues [highvalue/midvalue/lowvalue] #####` *Specify a value for when bucket color should turn red*
 `/clammyh reloadah` *Auto-capture + AH refresh: reads token saved by the Chrome extension, fetches live AH prices, rewrites `config/addons/ClammyHorizon/data/ah_prices.json`, and applies values in-game.*
 `/clammyh reloadah local` *Re-read existing `config/addons/ClammyHorizon/data/ah_prices.json` (and overrides) only -- no browser / no API.*
 `/clammyh horizonauth` *Same as `/clammyh reloadah` (legacy alias).*

### Debug
 `/clammyh reset` *Manually clear bucket information*
 `/clammyh weight` *Manually adjust bucket weight*

### Single source when using AH pricing

Ashita caches per-item gil/vendor in `config/addons/ClammyHorizon/<char>/settings.lua`. With **Apply AH JSON** on, ClammyHorizon reapplies **`config/addons/ClammyHorizon/data/ah_prices.json`** (then optional **`config/addons/ClammyHorizon/data/ah_prices_overrides.json`**) so file-based pricing wins.

| What | Purpose |
|------|--------|
| **`config/addons/ClammyHorizon/data/ah_prices.json`** | **Output of `scripts/update_ah_prices.ps1`**. Use **`/clammyh reloadah`** in-game to regenerate and apply; **`reloadah local`** applies the file on disk without fetching. |
| **`config/addons/ClammyHorizon/data/ah_prices_overrides.json`** | Optional local overlay (create it yourself). `{ "items": { "Exact name": { "effective_gil": 1234, "prefer_vendor": false } } }`. |
| **`scripts/clammyh_horizon_capture_and_update.ps1`** | Token capture + **`update_ah_prices.ps1`**. Run from the game via **`/clammyh reloadah`**. |
| **`scripts/item_sources.json`** | Rows: in-game **`item`**, NPC **`vendor_gil`**, Horizon **`slug`** / stack fields, optional **`manual_ah_net_per_unit`**. Fork from **`item_sources.example.json`** for a clean template. |
| **`scripts/update_ah_prices.ps1`** | **Normal use:** calls **`api.horizonxi.com`** with a session Bearer token. **`-NoApi`** = vendor-only rebuild. |
| **`scripts/HORIZON_SESSION_TOKEN.md`** | Manual DevTools copy of Bearer token (fallback if extension is not installed). |
| **`chrome-extension/`** | **Recommended:** install once and the token is captured silently every time you visit horizonxi.com. See `chrome-extension/README.md`. |
| **`constants.lua`** | Names, weights, rarity; legacy **`gil`** only if AH-from-file is off / JSON missing. |

## Config folder layout

Everything ClammyHorizon writes at runtime goes under `Game\config\addons\ClammyHorizon\`:

```
config\addons\ClammyHorizon\
  <CharName>\                  <- one folder per character (Ashita-managed)
    settings.lua               <- Ashita settings (auto-created)
    logs\                      <- this character's session logs
      log_YYYY_MM_DD__*.txt    <- per-session dig log (CSV)
      log_broken_*.txt         <- broken-bucket log
      session_*.txt            <- session summary report
  data\                        <- shared addon data (not per-character)
    ah_prices.json             <- AH price data (written by /clammyh reloadah)
    ah_missing_items.json      <- items with no AH data found last run
    ah_prices_overrides.json   <- optional manual price overrides (create yourself)
    horizon_bearer.txt         <- saved HorizonXI session JWT
    horizon_helper.log         <- full PowerShell script transcript
    last_helper_exitcode.txt   <- 0 = OK, nonzero = something failed
    horizon_helper.lock        <- IPC lock (deleted when script finishes)
```

> **On failure**, check `data\horizon_helper.log` and `data\last_helper_exitcode.txt`.

## Token capture -- Chrome Extension (recommended)

Install the Chrome extension once (`chrome-extension/README.md`) and the token is captured automatically whenever you visit horizonxi.com. No manual steps after that.

## Updating AH prices

### From the game (recommended -- install Chrome extension + Node.js once)

1. Install the Chrome extension: follow **`chrome-extension/README.md`**.
2. Install **[Node.js LTS](https://nodejs.org)** if you haven't already.
3. Log in to [horizonxi.com](https://horizonxi.com) -- the extension captures your token silently.
4. In FFXI: **`/clammyh reloadah`** -- fetches live AH prices, rewrites `config/addons/ClammyHorizon/data/ah_prices.json`, and applies values immediately (~10-30s).
5. On failure, check **`Game\config\addons\ClammyHorizon\data\horizon_helper.log`** and **`data\last_helper_exitcode.txt`** (`0` = OK).
6. To re-read a JSON you already have without hitting Horizon: **`/clammyh reloadah local`**.

**First-time Node setup:** From a normal PowerShell window, run **`npm.cmd install`** inside **`addons/clammyhhorizon/scripts`** once. That avoids locking FFXI while packages download.

### Manual: DevTools Bearer + updater

Horizon exposes a session JWT (`Authorization: Bearer ...`). See **`scripts/HORIZON_SESSION_TOKEN.md`** for how to copy it manually.

```powershell
$env:HORIZONXI_TOKEN = '<JWT from browser>'
powershell -NoProfile -File .\scripts\update_ah_prices.ps1
```

**`-NoApi`** on **`update_ah_prices.ps1`** = vendor-only rebuild (no auction API) -- emergency / offline use.

### `item_sources.json` fields

- **`item`** -- Exact name as in **`constants.lua`**.
- **`vendor_gil`** -- NPC gil per unit.
- **`slug`**, **`query_stack`**, **`stack_size`**, **`max_sales`** -- API fetch behaviour.
- **`manual_ah_net_per_unit`** (alias **`override_ah_net_per_unit`**) -- net per unit after fee; skips slug call for that row.
- Per-row **`liquidity_*`** overrides -- see script header; fee: **`net = sale - Ceiling(sale * 0.01)`**.

### API slug notes

Item pages use **`/items/<slug>`**; match **`query_stack`** to Horizon's Network panel if medians look wrong.
