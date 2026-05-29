<#
.SYNOPSIS
  Calls Horizon's item API and writes ../data/ah_prices.json (median AH vs vendor, liquidity rules).

.DESCRIPTION
  Default: uses slugs in scripts/item_sources.json and a **session Bearer token** from your logged-in Horizon site
  (`Authorization` header on `GET …/items/{slug}/auction-detail?stack=N`). Set **HORIZONXI_TOKEN** or **-Token**.

  **-NoApi**: rebuild from **vendor_gil** only (no HTTP); use when API is down or you intentionally want an NPC snapshot.

  Rows with **manual_ah_net_per_unit** skip the slug fetch. Prior **ah_net_per_unit** is reused on API failure unless **-NoApi**.

.EXAMPLE
  $env:HORIZONXI_TOKEN = '<JWT from browser - see HORIZON_SESSION_TOKEN.md>'
  .\update_ah_prices.ps1

.EXAMPLE
  .\update_ah_prices.ps1 -NoApi
#>
[CmdletBinding()]
param(
  [switch]$NoApi,
  [string]$BaseUrl = 'https://api.horizonxi.com/api/v1/items',
  [string]$Sources = "",
  [string]$OutFile = "",
  [string]$Token = "",
  [double]$LiquidityPct = 7.5,
  [double]$SlowMarketBypassPremiumPct = 50,
  [double]$LiquidityAuctionMinDailySales = 1.0,
  [double]$LiquidityGilGapCap = 0,
  [int]$MinAhNetForListing = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MedianRounded([int[]]$Values) {
  $a = $Values | Sort-Object
  $c = $a.Count
  if ($c -eq 0) { return $null }
  $mid = [math]::Floor($c / 2)
  if ($c % 2 -eq 1) {
    return [int]$a[$mid]
  }
  return [int][math]::Round(($a[$mid - 1] + $a[$mid]) / 2.0)
}

function Get-SalePrice([object]$Row) {
  if ($null -eq $Row) { return $null }
  if ($null -ne $Row.PSObject.Properties['price']) {
    return [int]$Row.price
  }
  if ($null -ne $Row.PSObject.Properties['sale']) {
    return [int]$Row.sale
  }
  return $null
}

function Get-SaleEpoch([object]$Row) {
  if ($null -eq $Row) { return $null }
  if ($null -ne $Row.PSObject.Properties['sell_date']) {
    try { return [double][int64]$Row.sell_date } catch { return $null }
  }
  if ($null -ne $Row.PSObject.Properties['sellDate']) {
    $s = [string]$Row.sellDate
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try {
      return [double][DateTimeOffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUnixTimeSeconds()
    }
    catch { return $null }
  }
  return $null
}

function Get-EstSalesPerDay([object[]]$HistoryRows) {
  if ($null -eq $HistoryRows) { return $null }
  $c = $HistoryRows.Count
  if ($c -lt 2) { return $null }
  $epochs = @()
  foreach ($r in $HistoryRows) {
    $e = Get-SaleEpoch -Row $r
    if ($null -ne $e) { $epochs += $e }
  }
  if ($epochs.Count -lt 2) { return $null }
  $minE = ($epochs | Measure-Object -Minimum).Minimum
  $maxE = ($epochs | Measure-Object -Maximum).Maximum
  $spanDays = ($maxE - $minE) / 86400.0
  if (($null -eq $spanDays) -or ($spanDays -eq 0)) { return $null }
  $spanDays = [math]::Max($spanDays, (1.0 / 1440))
  return [double]$epochs.Count / [double]$spanDays
}

function Get-AhSalesRowsFromApiResponse([object]$Resp, [int]$MaxSales) {
  $rows = @()
  if ($null -eq $Resp) { return $rows }
  # Horizon 2026+: { item, ah: { sales: [{ price, sellDate, ... }] }, bazaar, ... }
  if ($null -ne $Resp.PSObject.Properties['ah']) {
    $ah = $Resp.ah
    if (($null -ne $ah) -and ($null -ne $ah.PSObject.Properties['sales']) -and ($null -ne $ah.sales)) {
      $rows = @($ah.sales)
    }
  }
  # Legacy: JSON array of { sale, sell_date }
  if ($rows.Count -eq 0) {
    if ($Resp -is [System.Array]) {
      $rows = @($Resp)
    }
    elseif ($null -ne $Resp.PSObject.Properties['sale']) {
      $rows = @($Resp)
    }
  }
  if ($rows.Count -gt $MaxSales) {
    $rows = $rows[0 .. ($MaxSales - 1)]
  }
  return $rows
}

function Get-ManualAhNetUnit([PSObject]$Entry) {
  if ($null -eq $Entry) { return $null }
  foreach ($prop in @('manual_ah_net_per_unit','override_ah_net_per_unit')) {
    if ($null -eq $Entry.PSObject.Properties[$prop]) {
      continue
    }
    $v = $Entry.$prop
    if ($null -eq $v) {
      continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$v)) {
      continue
    }
    try {
      return [int]$v
    }
    catch {}
  }
  return $null
}
$Root = Split-Path -Parent $PSScriptRoot
# Resolve Game\config\addons\ClammyHorizon\ relative to the addon directory
$_gameDir = Split-Path -Parent (Split-Path -Parent $Root)
$_clammyConfig = Join-Path $_gameDir 'config\addons\ClammyHorizon\data'
if ([string]::IsNullOrWhiteSpace($OutFile)) {
  $OutFile = Join-Path $_clammyConfig 'ah_prices.json'
}
if ([string]::IsNullOrWhiteSpace($Sources)) {
  $Sources = Join-Path $PSScriptRoot 'item_sources.json'
}

if (-not (Test-Path -LiteralPath $Sources)) {
  Write-Error "Missing sources file: $Sources"
}

$list = Get-Content -LiteralPath $Sources -Raw | ConvertFrom-Json
if ($null -eq $list) { Write-Error "item_sources.json parsed to null." }

if ($list -isnot [System.Array]) {
  $list = @($list)
}

$tok = $Token
if ([string]::IsNullOrWhiteSpace($tok)) { $tok = [Environment]::GetEnvironmentVariable('HORIZONXI_TOKEN', 'Process') }
if ([string]::IsNullOrWhiteSpace($tok)) { $tok = [Environment]::GetEnvironmentVariable('HORIZONXI_TOKEN', 'User') }
if (-not [string]::IsNullOrWhiteSpace($tok)) {
  $tok = $tok.Trim()
  if ($tok -match '^(?i)Bearer\s+') {
    $tok = $tok -replace '^(?i)Bearer\s+', ''
  }
}

if ($NoApi -eq $true) {
  Write-Host 'NoApi mode: rebuilding data/ah_prices.json from vendor_gil only (no HTTP, no reuse of prior AH nets).'
  $tok = ''
}

$anySlug = $false
foreach ($e in $list) {
  if ($null -eq $e) { continue }
  if ($null -ne $e.PSObject.Properties['slug']) {
    $ts = [string]$e.slug
    if (-not [string]::IsNullOrWhiteSpace($ts)) { $anySlug = $true; break }
  }
}
if ($NoApi -ne $true) {
  if ($anySlug -and [string]::IsNullOrWhiteSpace($tok)) {
    $helpMd = Join-Path $PSScriptRoot 'HORIZON_SESSION_TOKEN.md'
    Write-Error "Horizon API needs a session Bearer token (Horizon does not publish a permanent API key for this). Set `$env:HORIZONXI_TOKEN or pass -Token. See: $helpMd Or use -NoApi for vendor-only output."
  }
  elseif (-not $anySlug) {
    Write-Host 'No item slug in sources - skipping API (vendor-only ah_prices.json).'
  }
}

$prevLookup = @{ }
if ($NoApi -ne $true) {
  if (Test-Path -LiteralPath $OutFile) {
    try {
      $prevObj = Get-Content -LiteralPath $OutFile -Raw | ConvertFrom-Json
      if (($null -ne $prevObj) -and ($null -ne $prevObj.items)) {
        foreach ($p in $prevObj.items.PSObject.Properties) {
          $prevLookup[$p.Name] = $p.Value
        }
      }
    }
    catch {
      Write-Warning "Could not read previous $OutFile for AH carry-over: $($_.Exception.Message)"
    }
  }
}

# Snapshot previous ah_net_per_unit values into ah_prices_prev.json so the
# in-game item browser can show up/down change arrows after reloadah.
if ($prevLookup.Count -gt 0) {
  $prevSnap = [ordered]@{}
  foreach ($key in ($prevLookup.Keys | Sort-Object)) {
    $val = $prevLookup[$key]
    if ($null -ne $val -and $null -ne $val.PSObject.Properties['ah_net_per_unit'] -and $null -ne $val.ah_net_per_unit) {
      try { $prevSnap[$key] = [int]$val.ah_net_per_unit } catch {}
    }
  }
  if ($prevSnap.Count -gt 0) {
    $prevOutFile = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($OutFile), 'ah_prices_prev.json')
    try {
      $prevSnap | ConvertTo-Json -Depth 1 | Set-Content -LiteralPath $prevOutFile -Encoding UTF8
    } catch {
      Write-Warning "Could not write $prevOutFile`: $($_.Exception.Message)"
    }
  }
}
$headers = @{
  'Accept'        = 'application/json, text/plain, */*'
  'Authorization' = "Bearer $tok"
}

$itemsOut = @{ }
$utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$reportRows = [System.Collections.Generic.List[object]]::new()  # for end-of-run report

$totalItems  = @($list | Where-Object { $null -ne $_ }).Count
$slugItems   = @($list | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['slug'] -and -not [string]::IsNullOrWhiteSpace($_.slug) }).Count
$itemIndex   = 0
$slugIndex   = 0

if ($NoApi -ne $true -and $slugItems -gt 0) {
  Write-Host ("Fetching AH prices for {0} item(s) from api.horizonxi.com (parallel, up to 15 at once)..." -f $slugItems) -ForegroundColor Cyan
}

# ── Parallel pre-fetch: fire all jobs, process + display each result as it lands ──
$computedItems = @{}
if ($NoApi -ne $true -and $anySlug -and -not [string]::IsNullOrWhiteSpace($tok)) {
  $entryByName = @{}
  foreach ($e in $list) {
    if ($null -ne $e) { $n = [string]$e.item; if (-not [string]::IsNullOrWhiteSpace($n)) { $entryByName[$n] = $e } }
  }
  $slugEntries = @($list | Where-Object {
    $null -ne $_ -and
    $null -ne $_.PSObject.Properties['slug'] -and
    -not [string]::IsNullOrWhiteSpace($_.slug) -and
    $null -eq (Get-ManualAhNetUnit -Entry $_)
  })
  if ($slugEntries.Count -gt 0) {
    $fetchScript = {
      param($Uri, $Headers)
      try {
        $resp = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
        return [pscustomobject]@{ ok = $true; resp = $resp; statusCode = $null; error = $null }
      } catch {
        $sc = $null; try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
        return [pscustomobject]@{ ok = $false; resp = $null; statusCode = $sc; error = $_.Exception.Message }
      }
    }
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 15)
    $pool.Open()
    $allJobs = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $slugEntries) {
      $qs = 1; if ($null -ne $e.PSObject.Properties['query_stack']) { $qs = [int]$e.query_stack }
      $uri = "$BaseUrl/$($e.slug)/auction-detail?stack=$qs"
      $ps2 = [System.Management.Automation.PowerShell]::Create()
      $ps2.RunspacePool = $pool
      [void]$ps2.AddScript($fetchScript).AddParameters(@{ Uri = $uri; Headers = $headers })
      $allJobs.Add([pscustomobject]@{ PS = $ps2; Handle = $ps2.BeginInvoke(); Name = [string]$e.item })
    }
    $doneCount = 0
    foreach ($job in $allJobs) {
      $doneCount++
      $raw = $job.PS.EndInvoke($job.Handle); $job.PS.Dispose()
      $fr = if ($raw -is [array]) { $raw[0] } else { $raw }
      $e   = $entryByName[$job.Name]
      $vG  = [int]$e.vendor_gil
      $ups = 1
      if ($null -ne $e.PSObject.Properties['stack_size'])    { $ups = [int]$e.stack_size }
      elseif ($null -ne $e.PSObject.Properties['units_per_sale']) { $ups = [int]$e.units_per_sale }
      if ($ups -le 0) { $ups = 1 }
      $ms2 = 30; if ($null -ne $e.PSObject.Properties['max_sales']) { $ms2 = [math]::Max(1,[int]$e.max_sales) }
      $lpc2 = [double]$LiquidityPct;                  if ($null -ne $e.PSObject.Properties['liquidity_pct_cap'])                    { $lpc2 = [double]$e.liquidity_pct_cap }
      $lsr2 = [double]$LiquidityAuctionMinDailySales; if ($null -ne $e.PSObject.Properties['liquidity_auction_min_daily_sales'])     { $lsr2 = [double]$e.liquidity_auction_min_daily_sales }
      $lsb2 = [double]$SlowMarketBypassPremiumPct;    if ($null -ne $e.PSObject.Properties['liquidity_slow_market_bypass_pct'])     { $lsb2 = [double]$e.liquidity_slow_market_bypass_pct }
      $lgc2 = [double]$LiquidityGilGapCap;            if ($null -ne $e.PSObject.Properties['liquidity_gil_gap_cap'])                { $lgc2 = [double]$e.liquidity_gil_gap_cap }
      $man2 = [int]$MinAhNetForListing;               if ($null -ne $e.PSObject.Properties['min_ah_net_for_listing'])               { $man2 = [int]$e.min_ah_net_for_listing }
      $eSlug = ''; if ($null -ne $e.PSObject.Properties['slug']) { $eSlug = [string]$e.slug }
      $mRaw=$null; $mNet=$null; $ahN=$null; $smp=0; $hist2=$null; $fromC=$false

      if ($fr.ok) {
        $rows2 = @(Get-AhSalesRowsFromApiResponse -Resp $fr.resp -MaxSales $ms2)
        $smp = $rows2.Count
        if ($smp -gt 0) {
          $hist2 = $rows2
          $nets2 = [System.Collections.Generic.List[int]]::new()
          $raws2 = [System.Collections.Generic.List[int]]::new()
          foreach ($r2 in $rows2) {
            $s2 = Get-SalePrice -Row $r2; if ($null -eq $s2) { continue }
            $f2 = [int][math]::Ceiling([double]$s2 * 0.01)
            $nets2.Add([int]($s2 - $f2)); $raws2.Add([int]$s2)
          }
          $smp = $nets2.Count
          if ($smp -gt 0) {
            $mNet = Get-MedianRounded -Values $nets2.ToArray()
            $mRaw = Get-MedianRounded -Values $raws2.ToArray()
            if ($null -ne $mNet) { $ahN = [int][math]::Floor([double]$mNet / [double]$ups) }
          }
        }
      } else {
        if ($fr.statusCode -eq 401) {
          $wm2 = 'AH token expired for ''{0}''. Run /clammyh reloadah to refresh.' -f $job.Name
          Write-Warning $wm2
          $reportRows.Add([pscustomobject]@{ item=$job.Name; slug=$eSlug; reason='token_expired'; note=$wm2 })
        } else {
          $wm2 = 'AH fetch failed for ''{0}'': {1}' -f $job.Name, $fr.error
          Write-Warning $wm2
          $reportRows.Add([pscustomobject]@{ item=$job.Name; slug=$eSlug; reason='fetch_error'; note=$fr.error })
        }
      }
      if ($smp -eq 0 -and $null -eq $ahN -and -not [string]::IsNullOrWhiteSpace($eSlug)) {
        $reportRows.Add([pscustomobject]@{ item=$job.Name; slug=$eSlug; reason='no_ah_sales'; note='API returned 0 sales — using vendor price' })
      }
      # Fallback to cached prior value
      if ($null -eq $ahN) {
        $prv2 = $prevLookup[$job.Name]
        if ($null -ne $prv2 -and $null -ne $prv2.PSObject.Properties['ah_net_per_unit'] -and $null -ne $prv2.ah_net_per_unit) {
          try {
            $ahN = [int]$prv2.ah_net_per_unit; $fromC = $true
            if ($null -ne $prv2.PSObject.Properties['median_net_sale']  -and $null -ne $prv2.median_net_sale)  { try { $mNet = [int]$prv2.median_net_sale  } catch {} }
            if ($null -ne $prv2.PSObject.Properties['median_raw_sale']  -and $null -ne $prv2.median_raw_sale)  { try { $mRaw = [int]$prv2.median_raw_sale  } catch {} }
            if ($null -ne $prv2.PSObject.Properties['sample_count']     -and $null -ne $prv2.sample_count)     { try { $smp  = [int]$prv2.sample_count     } catch {} }
          } catch {}
        }
      }
      $spd2 = Get-EstSalesPerDay -HistoryRows $hist2
      if ($null -eq $spd2) {
        $prv2 = $prevLookup[$job.Name]
        if ($null -ne $prv2 -and $null -ne $prv2.PSObject.Properties['estimated_sales_rate_per_day'] -and $null -ne $prv2.estimated_sales_rate_per_day) {
          try { $spd2 = [double]$prv2.estimated_sales_rate_per_day } catch {}
        }
      }
      # Routing
      $effG2=[int]$vG; $prefV2=$true; $rR2='npc_no_ah_data'; $lN2=''
      if ($null -eq $ahN)        { $rR2='npc_no_ah_value' }
      elseif ($ahN -lt $vG)      { $rR2='npc_ah_below_vendor' }
      elseif ($ahN -eq $vG)      { $rR2='npc_tie' }
      else {
        $prefV2=$false; $effG2=[int]$ahN; $rR2='auction_house'
        if ($vG -le 0) { $rR2='auction_no_vendor_price' }
        else {
          $dG2=[double]($ahN-$vG); $pG2=100.0*$dG2/[math]::Max([double]$vG,1.0); $fN2=$false
          if (($man2 -gt 0) -and (($ahN * $ups) -le $man2))                                                           { $fN2=$true; $lN2='below_min_ah_net' }
          if ((-not $fN2) -and ($pG2 -le $lpc2))                                                                       { $fN2=$true; $lN2='tight_margin_vs_npc' }
          if ((-not $fN2) -and ($lgc2 -gt 0) -and ($dG2 -le $lgc2) -and ($pG2 -le ($lpc2*1.75)))                     { $fN2=$true; $lN2='small_gil_gap_vs_npc' }
          if ((-not $fN2) -and ($null -ne $spd2) -and ($spd2 -lt $lsr2) -and ($pG2 -lt $lsb2))                       { $fN2=$true; $lN2='slow_market_liquidity' }
          if ($fN2) { $prefV2=$true; $effG2=[int]$vG; $rR2='npc_liquidity' }
        }
      }
      # Display immediately
      $pStr2  = if ($null -ne $ahN) { '{0:N0}g' -f $ahN } else { 'no data' }
      $vStr2  = if ($vG -gt 0) { '(npc {0:N0}g)' -f $vG } else { '' }
      $rTag2  = if ($lN2 -eq 'below_min_ah_net') { ('NPC (AH stack < {0}g min)' -f $man2) } else {
        switch ($rR2) {
          'auction_house'           { 'AH' }; 'auction_no_vendor_price' { 'AH' }
          'npc_liquidity'           { 'NPC (low margin)' }; 'npc_ah_below_vendor' { 'NPC (AH < vendor)' }
          'npc_tie'                 { 'NPC (tie)' }; 'npc_no_ah_data' { 'NPC (no AH)' }
          'npc_no_ah_value'         { 'NPC' }; default { $rR2 }
        }
      }
      $clr2=$null; if ($prefV2) { $clr2='DarkGray' } else { $clr2='Green' }
      $chgT2=''; $chgC2=$clr2
      $prE2 = $prevLookup[$job.Name]
      if ($null -ne $prE2 -and $null -ne $prE2.PSObject.Properties['prefer_vendor'] -and $null -ne $prE2.prefer_vendor) {
        $pv2 = [bool]$prE2.prefer_vendor
        if ($pv2 -and -not $prefV2) { $chgT2='  << NPC->AH'; $chgC2='Cyan' }
        elseif (-not $pv2 -and $prefV2) { $chgT2='  << AH->NPC'; $chgC2='Yellow' }
      }
      Write-Host ('  {0,-28} {1,8}  -> {2,-20}  {3}{4}' -f $job.Name, $pStr2, $rTag2, $vStr2, $chgT2) -ForegroundColor $chgC2
      # Store for JSON building
      $computedItems[$job.Name] = [pscustomobject]@{
        vendorGil=$vG; sampleCount=$smp; ahFromCachedRun=$fromC; effectiveGil=$effG2
        preferVendor=$prefV2; routeReason=$rR2; liquidityNote=$lN2; salesPerDayEst=$spd2
        ahNetPerUnit=$ahN; medianNet=$mNet; medianRaw=$mRaw
      }
    }
    $pool.Close(); $pool.Dispose()
  }
}

foreach ($entry in $list) {
  $name = [string]$entry.item
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $itemIndex++

  $slug = ''
  if ($null -ne $entry.PSObject.Properties['slug']) {
    $tmp = [string]$entry.slug
    if (-not [string]::IsNullOrWhiteSpace($tmp)) { $slug = $tmp }
  }
  $vendorGil = [int]$entry.vendor_gil
  $queryStack = 1
  if ($null -ne $entry.PSObject.Properties['query_stack']) {
    $queryStack = [int]$entry.query_stack
  }
  $unitsPerSale = 1
  if ($null -ne $entry.PSObject.Properties['stack_size']) {
    $unitsPerSale = [int]$entry.stack_size
  } elseif ($null -ne $entry.PSObject.Properties['units_per_sale']) {
    $unitsPerSale = [int]$entry.units_per_sale
  }
  if ($unitsPerSale -le 0) { $unitsPerSale = 1 }
  $maxSales = 30
  if ($null -ne $entry.PSObject.Properties['max_sales']) {
    $maxSales = [int]$entry.max_sales
    if ($maxSales -lt 1) { $maxSales = 1 }
  }

  $manualAhNetUnit = Get-ManualAhNetUnit -Entry $entry

  $liqPctCap = [double]$LiquidityPct
  if ($null -ne $entry.PSObject.Properties['liquidity_pct_cap']) {
    $liqPctCap = [double]$entry.liquidity_pct_cap
  }
  $liqSlowMinRate = [double]$LiquidityAuctionMinDailySales
  if ($null -ne $entry.PSObject.Properties['liquidity_auction_min_daily_sales']) {
    $liqSlowMinRate = [double]$entry.liquidity_auction_min_daily_sales
  }
  $liqSlowBypass = [double]$SlowMarketBypassPremiumPct
  if ($null -ne $entry.PSObject.Properties['liquidity_slow_market_bypass_pct']) {
    $liqSlowBypass = [double]$entry.liquidity_slow_market_bypass_pct
  }
  $liqGilGapCap = [double]$LiquidityGilGapCap
  if ($null -ne $entry.PSObject.Properties['liquidity_gil_gap_cap']) {
    $liqGilGapCap = [double]$entry.liquidity_gil_gap_cap
  }
  $minAhNet = [int]$MinAhNetForListing
  if ($null -ne $entry.PSObject.Properties['min_ah_net_for_listing']) {
    $minAhNet = [int]$entry.min_ah_net_for_listing
  }

  $medianRaw = $null
  $medianNet = $null
  $ahNetPerUnit = $null
  $sampleCount = 0
  $histRowsForRate = $null
  $ahFromCachedRun = $false
  $salesPerDayEst = $null
  $effectiveGil = [int]$vendorGil
  $preferVendor = $true
  $routeReason = 'npc_no_ah_data'
  $liquidityNote = ''

  $cr = $computedItems[$name]
  if ($null -ne $cr) {
    # Already fetched, processed, and displayed during parallel collection
    $ahNetPerUnit   = $cr.ahNetPerUnit;   $medianRaw      = $cr.medianRaw
    $medianNet      = $cr.medianNet;      $sampleCount    = $cr.sampleCount
    $ahFromCachedRun= $cr.ahFromCachedRun;$salesPerDayEst = $cr.salesPerDayEst
    $effectiveGil   = $cr.effectiveGil;   $preferVendor   = $cr.preferVendor
    $routeReason    = $cr.routeReason;    $liquidityNote  = $cr.liquidityNote
  } else {
    # Manual override or vendor-only (no slug) item — process inline
    if ($null -ne $manualAhNetUnit) {
      $ahNetPerUnit = [int]$manualAhNetUnit
    }

    if ($null -eq $ahNetPerUnit) { $routeReason = 'npc_no_ah_value' }
    elseif ($ahNetPerUnit -lt $vendorGil) { $routeReason = 'npc_ah_below_vendor' }
    elseif ($ahNetPerUnit -eq $vendorGil) { $routeReason = 'npc_tie' }
    else {
      $preferVendor = $false
      $effectiveGil = [int]$ahNetPerUnit
      $routeReason = 'auction_house'
      if ($vendorGil -le 0) {
        $routeReason = 'auction_no_vendor_price'
      } else {
        $deltaGil = [double]($ahNetPerUnit - $vendorGil)
        $pctGain = 100.0 * $deltaGil / [math]::Max([double]$vendorGil, 1.0)
        $forceNpc = $false
        if (($minAhNet -gt 0) -and (($ahNetPerUnit * $unitsPerSale) -le $minAhNet))                                                                    { $forceNpc=$true; $liquidityNote='below_min_ah_net' }
        if ((-not $forceNpc) -and ($pctGain -le $liqPctCap))                                                                               { $forceNpc=$true; $liquidityNote='tight_margin_vs_npc' }
        if ((-not $forceNpc) -and ($liqGilGapCap -gt 0) -and ($deltaGil -le $liqGilGapCap) -and ($pctGain -le ($liqPctCap * 1.75)))       { $forceNpc=$true; $liquidityNote='small_gil_gap_vs_npc' }
        if ((-not $forceNpc) -and ($null -ne $salesPerDayEst) -and ($salesPerDayEst -lt $liqSlowMinRate) -and ($pctGain -lt $liqSlowBypass)) { $forceNpc=$true; $liquidityNote='slow_market_liquidity' }
        if ($forceNpc) { $preferVendor=$true; $effectiveGil=[int]$vendorGil; $routeReason='npc_liquidity' }
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($slug)) {
      $priceStr  = if ($null -ne $ahNetPerUnit) { '{0:N0}g' -f $ahNetPerUnit } else { 'no data' }
      $vendorStr = if ($vendorGil -gt 0) { '(npc {0:N0}g)' -f $vendorGil } else { '' }
      $routeTag  = if ($liquidityNote -eq 'below_min_ah_net') { ('NPC (AH stack < {0}g min)' -f $minAhNet) } else {
        switch ($routeReason) {
          'auction_house'           { 'AH' }; 'auction_no_vendor_price' { 'AH' }
          'npc_liquidity'           { 'NPC (low margin)' }; 'npc_ah_below_vendor' { 'NPC (AH < vendor)' }
          'npc_tie'                 { 'NPC (tie)' }; 'npc_no_ah_data' { 'NPC (no AH)' }
          'npc_no_ah_value'         { 'NPC' }; default { $routeReason }
        }
      }
      $color = if ($preferVendor) { 'DarkGray' } else { 'Green' }
      $changeTag = ''; $changeColor = $color
      $priorEntry = $prevLookup[$name]
      if ($null -ne $priorEntry -and $null -ne $priorEntry.PSObject.Properties['prefer_vendor'] -and $null -ne $priorEntry.prefer_vendor) {
        $prevVendor = [bool]$priorEntry.prefer_vendor
        if ($prevVendor -and -not $preferVendor)      { $changeTag='  << NPC->AH'; $changeColor='Cyan' }
        elseif (-not $prevVendor -and $preferVendor)  { $changeTag='  << AH->NPC'; $changeColor='Yellow' }
      }
      Write-Host ('  {0,-28} {1,8}  -> {2,-20}  {3}{4}' -f $name, $priceStr, $routeTag, $vendorStr, $changeTag) -ForegroundColor $changeColor
    }
  }


  # Build row; omit ah_net_per_unit when unknown so JSON preserves null semantics
  $row = [ordered]@{
    vendor_gil              = $vendorGil
    sample_count            = $sampleCount
    ah_from_prior_json      = [bool]$ahFromCachedRun
    effective_gil           = $effectiveGil
    prefer_vendor           = [bool]$preferVendor
    route_reason            = $routeReason
  }
  if ($liquidityNote -ne '') {
    $row['liquidity'] = $liquidityNote
  }
  if ($null -ne $salesPerDayEst) {
    $row['estimated_sales_rate_per_day'] = [math]::Round($salesPerDayEst, 6)
  }
  if (($null -ne $ahNetPerUnit) -and ($vendorGil -gt 0)) {
    $row['pct_gain_ah_over_vendor'] = [math]::Round(100.0 * ([double]$ahNetPerUnit - [double]$vendorGil) / [double]$vendorGil, 3)
  }
  if ($null -ne $medianRaw) {
    $row['median_raw_sale'] = $medianRaw
  }
  if ($null -ne $medianNet) {
    $row['median_net_sale'] = $medianNet
  }
  if ($null -ne $ahNetPerUnit) {
    $row['ah_net_per_unit'] = $ahNetPerUnit
  }
  if ($null -ne $manualAhNetUnit) {
    $row['manual_override'] = $true
  }

  $itemsOut[$name] = [hashtable]::new($row)
}

$obj = [ordered]@{
  schema                              = 2
  liquidity_pct_cap_default           = $LiquidityPct
  liquidity_auction_min_daily_sales   = $LiquidityAuctionMinDailySales
  liquidity_slow_market_bypass_pct    = $SlowMarketBypassPremiumPct
  min_ah_net_for_listing              = $MinAhNetForListing
  fee_percent                         = 1
  generated_utc                       = $utc
  'items'                             = $itemsOut
}

$dataDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dataDir)) {
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

$jsonLines = ($obj | ConvertTo-Json -Depth 16)
[System.IO.File]::WriteAllText($OutFile, $jsonLines)

Write-Progress -Activity 'Clammy: applying AH prices' -Completed -ErrorAction SilentlyContinue
Write-Host ('Wrote {0} ({1} items).' -f $OutFile, $itemsOut.Count)

# ── Missing / problem items report ────────────────────────────────────────────
if ($reportRows.Count -gt 0) {
  Write-Host ''
  Write-Host ('  {0} item(s) had no AH data or fetch errors (vendor price used):' -f $reportRows.Count) -ForegroundColor Yellow
  $maxLen = ($reportRows | ForEach-Object { $_.item.Length } | Measure-Object -Maximum).Maximum
  foreach ($r in $reportRows) {
    $pad = $r.item.PadRight($maxLen)
    $color = if ($r.reason -eq 'token_expired') { 'Red' } elseif ($r.reason -eq 'fetch_error') { 'DarkYellow' } else { 'DarkGray' }
    Write-Host ('    {0}  [{1}]  {2}' -f $pad, $r.reason, $r.note) -ForegroundColor $color
  }
  Write-Host ''

  # Write report JSON next to ah_prices.json
  $reportPath = Join-Path (Split-Path -Parent $OutFile) 'ah_missing_items.json'
  $reportObj = [ordered]@{
    generated_utc = $utc
    count         = $reportRows.Count
    items         = @($reportRows)
  }
  $reportObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8 -Force
  Write-Host ('  Report saved: {0}' -f $reportPath) -ForegroundColor DarkGray
}
