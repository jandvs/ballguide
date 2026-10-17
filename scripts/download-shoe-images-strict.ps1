$ErrorActionPreference = 'Continue'
Set-Location "$PSScriptRoot\.."

function Normalize-Text {
  param([string]$Text)
  if (-not $Text) { return '' }
  $t = $Text.ToLowerInvariant()
  $t = $t -replace '[^a-z0-9\s-]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}

function Get-Tokens {
  param([string]$Name)
  $stops = @('womens','women','mens','men','bowling','shoe','shoes','the','and','for','with','performance','right','left','unisex')
  $tokens = Normalize-Text $Name
  $tokens = $tokens.Split(' ') | Where-Object { $_ -and ($stops -notcontains $_) -and $_.Length -ge 2 }
  return $tokens | Select-Object -Unique
}

function Score-Candidate {
  param([string]$ProductTitle, [string[]]$TargetTokens, [string]$Brand)

  $title = Normalize-Text $ProductTitle
  $score = 0

  foreach ($tok in $TargetTokens) {
    if ($title -match "(^|\s)$([regex]::Escape($tok))(\s|$)") { $score += 1 }
  }

  $brandNorm = Normalize-Text $Brand
  if ($brandNorm -and $title -match "(^|\s)$([regex]::Escape($brandNorm))(\s|$)") { $score += 2 }

  return $score
}

function Build-Candidate {
  param([string]$Title, [string]$ImageUrl, [string]$SourceLabel, [string]$SourceUrl)
  if (-not $ImageUrl) { return $null }
  return @{ title = $Title; imageUrl = $ImageUrl; sourceLabel = $SourceLabel; sourceUrl = $SourceUrl }
}

function Get-Candidates-BowlersMart {
  param([string]$Query)
  $list = @()
  try {
    $url = "https://www.bowlersmart.com/wp-json/wc/store/v1/products?search=$([uri]::EscapeDataString($Query))&per_page=10"
    $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
    if ($resp) {
      foreach ($p in $resp) {
        $img = $null
        if ($p.images -and $p.images.Count -gt 0) { $img = $p.images[0].src }
        $cand = Build-Candidate -Title $p.name -ImageUrl $img -SourceLabel 'BowlersMart' -SourceUrl $p.permalink
        if ($cand) { $list += $cand }
      }
    }
  }
  catch {}
  return $list
}

function Get-Candidates-Shopify {
  param([string]$Domain, [string]$Query)
  $list = @()
  try {
    $url = "https://$Domain/search/suggest.json?q=$([uri]::EscapeDataString($Query))&resources[type]=product&resources[limit]=10"
    $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
    $products = $resp.resources.results.products
    if ($products) {
      foreach ($p in $products) {
        $img = $null
        if ($p.image) { $img = $p.image }
        elseif ($p.images -and $p.images.Count -gt 0) { $img = $p.images[0] }
        $cand = Build-Candidate -Title $p.title -ImageUrl $img -SourceLabel $Domain -SourceUrl ("https://$Domain/products/$($p.handle)")
        if ($cand) { $list += $cand }
      }
    }
  }
  catch {}
  return $list
}

function Resolve-BestImage {
  param([string]$Name, [string]$Brand)

  $clean = Normalize-Text $Name
  $queries = @(
    $Name,
    ($Name -replace '(?i)womens|women''s|mens|men''s', ''),
    ($Name -replace '(?i)\bTHE\s+9\b', '9'),
    ($Name -replace '(?i)\bBOA\b', '')
  ) | ForEach-Object { Normalize-Text $_ } | Where-Object { $_ } | Select-Object -Unique

  $tokens = Get-Tokens -Name $Name
  $best = $null
  $bestScore = -1

  foreach ($q in $queries) {
    $cands = @()
    $cands += Get-Candidates-BowlersMart -Query $q
    $cands += Get-Candidates-Shopify -Domain 'www.bowlersparadise.com' -Query $q
    $cands += Get-Candidates-Shopify -Domain 'www.discountbowlingsupply.com' -Query $q

    foreach ($c in $cands) {
      $s = Score-Candidate -ProductTitle $c.title -TargetTokens $tokens -Brand $Brand
      if ($s -gt $bestScore) {
        $bestScore = $s
        $best = $c
      }
    }
  }

  if ($best -and $bestScore -ge 4) {
    return $best
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
    $resolved = Resolve-BestImage -Name $item.name -Brand $item.brand
    if (-not $resolved) {
      $miss += "$file :: $($item.id) :: no_confident_match"
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

      $ok += "$file :: $($item.id) :: $localUrl :: $($resolved.sourceLabel) :: $($resolved.title)"
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
