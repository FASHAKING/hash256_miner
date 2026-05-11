#!/usr/bin/env pwsh
# HASH256 GPU Miner cross-platform installer (PowerShell).
# Usage (Windows / PowerShell on Linux or macOS):
#   irm https://raw.githubusercontent.com/fashaking/hash256_miner/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

function Write-Info($message)    { Write-Host "[hash256] $message" -ForegroundColor Cyan }
function Write-Ok($message)      { Write-Host "[hash256] $message" -ForegroundColor Green }
function Write-Warn($message)    { Write-Host "[hash256] $message" -ForegroundColor Yellow }
function Write-Err($message)     { Write-Host "[hash256] $message" -ForegroundColor Red }

function Read-Required($prompt, [switch]$Secret, $default) {
  while ($true) {
    $hint = if ($default) { " [$default]" } else { "" }
    if ($Secret) {
      $secure = Read-Host -AsSecureString "$prompt$hint"
      $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
      $value = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    } else {
      $value = Read-Host "$prompt$hint"
    }
    if (-not $value -and $default) { return $default }
    if ($value)                    { return $value }
    Write-Warn "Value is required."
  }
}

function Detect-Os {
  if ($IsWindows -or $env:OS -eq "Windows_NT") { return "windows" }
  if ($IsMacOS)                                { return "macos" }
  if ($IsLinux)                                { return "linux" }
  $u = (uname).ToLower()
  if ($u -like "darwin*") { return "macos" }
  return "linux"
}

function Ensure-Command($name, $installHint) {
  if (Get-Command $name -ErrorAction SilentlyContinue) { return }
  Write-Err "Required tool not found on PATH: $name"
  Write-Err $installHint
  exit 1
}

$os = Detect-Os
Write-Info "Detected OS: $os"

Ensure-Command "git"  "Install git from https://git-scm.com/downloads and re-run."
Ensure-Command "node" "Install Node.js 20+ from https://nodejs.org and re-run."
Ensure-Command "npm"  "Install Node.js 20+ from https://nodejs.org and re-run."

$repoUrl    = "https://github.com/fashaking/hash256_miner.git"
$installDir = if ($env:HASH256_DIR) { $env:HASH256_DIR } else { Join-Path (Get-Location) "hash256_miner" }

if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "package.json"))) {
  $installDir = $PSScriptRoot
  Write-Info "Running from existing checkout at $installDir"
} elseif (Test-Path (Join-Path $installDir ".git")) {
  Write-Info "Updating existing checkout at $installDir"
  Push-Location $installDir
  git pull --ff-only | Out-Null
  Pop-Location
} else {
  Write-Info "Cloning repository into $installDir"
  git clone --depth 1 $repoUrl $installDir | Out-Null
}

Set-Location $installDir

Write-Info "Installing Node dependencies"
npm install --no-audit --no-fund | Out-Host

$envPath = Join-Path $installDir ".env"
if (Test-Path $envPath) {
  Write-Warn ".env already exists at $envPath"
  $overwrite = Read-Host "Overwrite it? [y/N]"
  if ($overwrite -notmatch "^(y|yes)$") {
    Write-Info "Keeping existing .env"
    $skipPrompts = $true
  }
}

if (-not $skipPrompts) {
  Write-Info "Please provide miner configuration (press Enter to accept defaults)"

  $privateKey  = Read-Required "Wallet PRIVATE_KEY (hex, with ETH for gas)" -Secret
  if ($privateKey -notmatch "^0x") { $privateKey = "0x$privateKey" }

  $ethRpc      = Read-Required "ETH_RPC_URL (read RPC)"          "https://ethereum.publicnode.com"
  $ethTxRpc    = Read-Required "ETH_TX_RPC_URL (tx RPC)"         "https://rpc.mevblocker.io/fast"
  $broadcast   = Read-Required "BROADCAST_RPCS (comma list)"     "https://rpc.mevblocker.io/fast,https://rpc.flashbots.net/fast"
  $tipGwei     = Read-Required "TIP_GWEI"                        "25"

  $defaultBackend = if ($os -eq "windows") { "cuda" } else { "opencl" }
  $backend = (Read-Required "MINER_BACKEND (cuda or opencl)" $defaultBackend).ToLower()
  if ($backend -ne "cuda" -and $backend -ne "opencl") {
    Write-Warn "Unknown backend '$backend', defaulting to $defaultBackend"
    $backend = $defaultBackend
  }

  $workers = Read-Required "MINER_WORKERS" "1"

  $lines = @(
    "PRIVATE_KEY=$privateKey",
    "TIP_GWEI=$tipGwei",
    "ETH_RPC_URL=$ethRpc",
    "ETH_TX_RPC_URL=$ethTxRpc",
    "BROADCAST_RPCS=$broadcast",
    "MINER_BACKEND=$backend",
    "MINER_WORKERS=$workers",
    "CUDA_BLOCKS=0",
    "CUDA_THREADS=384",
    "CUDA_HASHES_PER_THREAD=96"
  )
  Set-Content -Path $envPath -Value $lines -Encoding utf8
  Write-Ok ".env written to $envPath"
}

if ($os -ne "windows") {
  Write-Warn "The repository ships Windows-only native binaries (native/bin/*.exe)."
  Write-Warn "On $os you will need to build hash256-cuda or hash256-opencl from source"
  Write-Warn "before 'npm start' can run a GPU miner."
}

$launch = Read-Host "Launch miner now? [Y/n]"
if ($launch -match "^(n|no)$") {
  Write-Info "Skipping launch. Start later with: npm start"
  exit 0
}

Write-Info "Starting miner (Ctrl+C to stop)"
npm start
