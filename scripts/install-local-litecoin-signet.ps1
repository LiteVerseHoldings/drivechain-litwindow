param(
  [string]$LitecoinRepo = "",
  [string]$LitWindowDataDir = "$env:APPDATA\10520LayertwoLabs\BitWindow"
)

$ErrorActionPreference = "Stop"

if (-not $LitecoinRepo) {
  $candidates = @(
    "C:\Users\sages\Documents\LiteVerse_development\tools\litecoin-signet-build",
    "C:\Users\sages\Documents\allsage github\litecoin"
  )

  $LitecoinRepo = $candidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ "src\litecoind.exe")
  } | Select-Object -First 1

  if (-not $LitecoinRepo) {
    $LitecoinRepo = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
}

if (-not $LitecoinRepo) {
  throw "Could not find a Litecoin checkout. Pass -LitecoinRepo with the path to the signet build."
}

$srcDir = Join-Path $LitecoinRepo "src"
$binDir = Join-Path $LitWindowDataDir "assets\bin"

$litecoind = Join-Path $srcDir "litecoind.exe"
$litecoinCli = Join-Path $srcDir "litecoin-cli.exe"

if (-not (Test-Path -LiteralPath $litecoind)) {
  $elfLitecoind = Join-Path $srcDir "litecoind"
  if (Test-Path -LiteralPath $elfLitecoind) {
    $magic = Get-Content -LiteralPath $elfLitecoind -Encoding Byte -TotalCount 4
    if ($magic[0] -eq 0x7f -and $magic[1] -eq 0x45 -and $magic[2] -eq 0x4c -and $magic[3] -eq 0x46) {
      throw "Found an ELF/Linux litecoind at $elfLitecoind. LitWindow on Windows needs a Windows build at $litecoind."
    }
  }
  throw "Missing litecoind.exe at $litecoind. Build the Litecoin signet branch for Windows first."
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

Copy-Item -LiteralPath $litecoind -Destination (Join-Path $binDir "litecoind.exe") -Force

if (Test-Path -LiteralPath $litecoinCli) {
  Copy-Item -LiteralPath $litecoinCli -Destination (Join-Path $binDir "litecoin-cli.exe") -Force
}

Write-Host "Installed local Litecoin signet binaries to $binDir"
