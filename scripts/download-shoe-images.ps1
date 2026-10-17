$ErrorActionPreference = 'Continue'
Set-Location "$PSScriptRoot\.."

function Get-CleanQuery {
  param([string]$Name)
  $q = $Name
  $q = $q -replace '(?i)womens|women''s', ''
  $q = $q -replace '(?i)mens|men''s', ''
  $q = $q -replace '(?i)bowling shoe|performance shoe|shoe', ''
  $q = $q -replace '(?i)\bthe\b', ''
  $q = $q -replace '\s+', ' '
  return $q.Trim()
}

function Get-FromShopify {
  param([string]$Domain, [string]$Query)
  try {
    $url = "https://$Domain/search/suggest.json?q=$([uri]::EscapeDataString($Query))&resources[type]=product&resources[limit]=6"
    $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
    $products = $resp.resources.results.products
    if ($products -and $products.Count -gt 0) {
      foreach ($p in $products) {
        $img = $null
        if ($p.image) { $img = $p.image }
        elseif ($p.images -and $p.images.Count -gt 0) { $img = $p.images[0] }

        if ($img) {
          return @{ imageUrl = $img; sourceLabel = $Domain; sourceUrl = "https://$Domain/products/$($p.handle)" }
        }
      }
    }
  }
  catch {}

  return $null
}

function Get-FromBowlersMart {
  param([string]$Query)
  try {
    $url = "https://www.bowlersmart.com/wp-json/wc/store/v1/products?search=$([uri]::EscapeDataString($Query))&per_page=8"
    $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
    if ($resp -and $resp.Count -gt 0) {
      foreach ($p in $resp) {
        if ($p.images -and $p.images.Count -gt 0 -and $p.images[0].src) {
          return @{ imageUrl = $p.images[0].src; sourceLabel = 'BowlersMart'; sourceUrl = $p.permalink }
        }
      }
    }
  }
  catch {}

  return $null
}

function Resolve-Image {
  param([string]$Name)

  $clean = Get-CleanQuery -Name $Name
  $queries = @(
    $clean,
    $Name,
    ($clean -replace '(?i)boa', ''),
    ($clean -replace '(?i)the\s*9', '9')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($q in $queries) {
    $hit = Get-FromBowlersMart -Query $q
    if ($hit) { return $hit }

    $hit = Get-FromShopify -Domain 'www.bowlersparadise.com' -Query $q
    if ($hit) { return $hit }

    $hit = Get-FromShopify -Domain 'www.discountbowlingsupply.com' -Query $q
    if ($hit) { return $hit }
  }

  return $null
}

function Get-ImageExt {
  param([string]$Url)
  try {
    $u = [uri]$Url
    $path = $u.AbsolutePath.ToLowerInvariant()
    if ($path -match '\.(jpg|jpeg|png|webp|gif)$') {
      return "." + $matches[1]
    }
  }
  catch {}

  return '.jpg'
}

function Save-ImageLocal {
  param([string]$Url, [string]$Id)

  $ext = Get-ImageExt -Url $Url
  $folder = "public/images/shoes/$Id"
  if (-not (Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder | Out-Null
  }

  $name = "product$ext"
  $dest = Join-Path $folder $name
  Invoke-WebRequest -Uri $Url -OutFile $dest -TimeoutSec 30

  return "/images/shoes/$Id/$name"
}

$files = @('src/data/shoes-mens.json', 'src/data/shoes-womens.json')
$changedFiles = @()
$ok = @()
$miss = @()

foreach ($file in $files) {
  $items = Get-Content -Raw $file | ConvertFrom-Json
  $changed = $false

  foreach ($item in $items) {
    $resolved = Resolve-Image -Name $item.name
    if (-not $resolved) {
      $miss += "$file :: $($item.id) :: no_match"
      continue
    }

    try {
      $localUrl = Save-ImageLocal -Url $resolved.imageUrl -Id $item.id
      $alt = "$($item.name) bowling shoe product image"

      if ($item.PSObject.Properties.Name -contains 'imageUrl') { $item.imageUrl = $localUrl }
      else { Add-Member -InputObject $item -NotePropertyName imageUrl -NotePropertyValue $localUrl }

      if ($item.PSObject.Properties.Name -contains 'imageAlt') { $item.imageAlt = $alt }
      else { Add-Member -InputObject $item -NotePropertyName imageAlt -NotePropertyValue $alt }

      if ($item.PSObject.Properties.Name -contains 'imageSourceLabel') { $item.imageSourceLabel = $resolved.sourceLabel }
      else { Add-Member -InputObject $item -NotePropertyName imageSourceLabel -NotePropertyValue $resolved.sourceLabel }

      if ($item.PSObject.Properties.Name -contains 'imageSourceUrl') { $item.imageSourceUrl = $resolved.sourceUrl }
      else { Add-Member -InputObject $item -NotePropertyName imageSourceUrl -NotePropertyValue $resolved.sourceUrl }

      $ok += "$file :: $($item.id) :: $localUrl :: $($resolved.sourceLabel)"
      $changed = $true
    }
    catch {
      $miss += "$file :: $($item.id) :: download_failed"
    }
  }

  if ($changed) {
    $json = $items | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText((Resolve-Path $file), $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
    $changedFiles += $file
  }
}

"CHANGED_FILES=$($changedFiles.Count)"
$changedFiles | ForEach-Object { "CHANGED::$_" }
"OK_COUNT=$($ok.Count)"
$ok | ForEach-Object { "OK::$_" }
"MISS_COUNT=$($miss.Count)"
$miss | ForEach-Object { "MISS::$_" }
