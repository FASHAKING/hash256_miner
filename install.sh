#!/usr/bin/env bash
# HASH256 GPU Miner cross-platform installer (Linux / macOS).
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fashaking/hash256_miner/main/install.sh | bash
# To skip the auto-launch:
#   curl -fsSL https://raw.githubusercontent.com/fashaking/hash256_miner/main/install.sh | bash -s -- --no-start

set -euo pipefail

color_cyan="\033[36m"
color_green="\033[32m"
color_yellow="\033[33m"
color_red="\033[31m"
color_reset="\033[0m"

info() { printf "${color_cyan}[hash256]${color_reset} %s\n" "$*"; }
ok()   { printf "${color_green}[hash256]${color_reset} %s\n" "$*"; }
warn() { printf "${color_yellow}[hash256]${color_reset} %s\n" "$*"; }
err()  { printf "${color_red}[hash256]${color_reset} %s\n" "$*" >&2; }

NO_START=0
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
  esac
done

# Ensure we have a controlling TTY for prompts when piped from curl.
if [ ! -t 0 ]; then
  if [ -r /dev/tty ]; then
    exec </dev/tty
  else
    err "No TTY available for interactive prompts. Re-run from a terminal."
    exit 1
  fi
fi

detect_os() {
  case "$(uname -s)" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}

require_cmd() {
  local name="$1"; local hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    err "Required tool not found on PATH: $name"
    err "$hint"
    exit 1
  fi
}

prompt() {
  # prompt <var_name> <message> [default]
  local __var="$1"; local __msg="$2"; local __default="${3-}"
  local __input=""
  while :; do
    if [ -n "$__default" ]; then
      printf "%s [%s]: " "$__msg" "$__default"
    else
      printf "%s: " "$__msg"
    fi
    IFS= read -r __input || true
    if [ -z "$__input" ] && [ -n "$__default" ]; then
      __input="$__default"
    fi
    if [ -n "$__input" ]; then
      printf -v "$__var" '%s' "$__input"
      return
    fi
    warn "Value is required."
  done
}

prompt_secret() {
  # prompt_secret <var_name> <message>
  local __var="$1"; local __msg="$2"; local __input=""
  while :; do
    printf "%s: " "$__msg"
    stty -echo 2>/dev/null || true
    IFS= read -r __input || true
    stty echo 2>/dev/null || true
    printf "\n"
    if [ -n "$__input" ]; then
      printf -v "$__var" '%s' "$__input"
      return
    fi
    warn "Value is required."
  done
}

OS=$(detect_os)
info "Detected OS: $OS"

require_cmd git  "Install git (e.g. 'sudo apt install git' / 'brew install git') and re-run."
require_cmd node "Install Node.js 20+ from https://nodejs.org (or via nvm / brew) and re-run."
require_cmd npm  "Install Node.js 20+ from https://nodejs.org (or via nvm / brew) and re-run."

REPO_URL="https://github.com/fashaking/hash256_miner.git"
INSTALL_DIR="${HASH256_DIR:-$PWD/hash256_miner}"

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/package.json" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
  info "Running from existing checkout at $INSTALL_DIR"
elif [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating existing checkout at $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only >/dev/null
else
  info "Cloning repository into $INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" >/dev/null
fi

cd "$INSTALL_DIR"

info "Installing Node dependencies"
npm install --no-audit --no-fund

ENV_PATH="$INSTALL_DIR/.env"
SKIP_PROMPTS=0
if [ -f "$ENV_PATH" ]; then
  warn ".env already exists at $ENV_PATH"
  printf "Overwrite it? [y/N]: "
  IFS= read -r overwrite || true
  case "${overwrite:-}" in
    y|Y|yes|YES) SKIP_PROMPTS=0 ;;
    *) info "Keeping existing .env"; SKIP_PROMPTS=1 ;;
  esac
fi

if [ "$SKIP_PROMPTS" -eq 0 ]; then
  info "Please provide miner configuration (press Enter to accept defaults)"

  prompt_secret PRIVATE_KEY "Wallet PRIVATE_KEY (hex, with ETH for gas)"
  case "$PRIVATE_KEY" in
    0x*) ;;
    *) PRIVATE_KEY="0x$PRIVATE_KEY" ;;
  esac

  prompt ETH_RPC_URL     "ETH_RPC_URL (read RPC)"      "https://ethereum.publicnode.com"
  prompt ETH_TX_RPC_URL  "ETH_TX_RPC_URL (tx RPC)"     "https://rpc.mevblocker.io/fast"
  prompt BROADCAST_RPCS  "BROADCAST_RPCS (comma list)" "https://rpc.mevblocker.io/fast,https://rpc.flashbots.net/fast"
  prompt TIP_GWEI        "TIP_GWEI"                    "25"

  default_backend="opencl"
  [ "$OS" = "windows" ] && default_backend="cuda"
  prompt MINER_BACKEND   "MINER_BACKEND (cuda or opencl)" "$default_backend"
  MINER_BACKEND=$(printf '%s' "$MINER_BACKEND" | tr '[:upper:]' '[:lower:]')
  if [ "$MINER_BACKEND" != "cuda" ] && [ "$MINER_BACKEND" != "opencl" ]; then
    warn "Unknown backend '$MINER_BACKEND', defaulting to $default_backend"
    MINER_BACKEND="$default_backend"
  fi

  prompt MINER_WORKERS "MINER_WORKERS" "1"

  umask 077
  cat > "$ENV_PATH" <<EOF
PRIVATE_KEY=$PRIVATE_KEY
TIP_GWEI=$TIP_GWEI
ETH_RPC_URL=$ETH_RPC_URL
ETH_TX_RPC_URL=$ETH_TX_RPC_URL
BROADCAST_RPCS=$BROADCAST_RPCS
MINER_BACKEND=$MINER_BACKEND
MINER_WORKERS=$MINER_WORKERS
CUDA_BLOCKS=0
CUDA_THREADS=384
CUDA_HASHES_PER_THREAD=96
EOF
  ok ".env written to $ENV_PATH"
fi

if [ "$OS" != "windows" ]; then
  warn "The repository ships Windows-only native binaries (native/bin/*.exe)."
  warn "On $OS you will need to build hash256-cuda or hash256-opencl from source"
  warn "before 'npm start' can run a GPU miner."
fi

if [ "$NO_START" -eq 1 ]; then
  info "Skipping launch. Start later with: cd \"$INSTALL_DIR\" && npm start"
  exit 0
fi

printf "Launch miner now? [Y/n]: "
IFS= read -r launch || true
case "${launch:-}" in
  n|N|no|NO)
    info "Skipping launch. Start later with: cd \"$INSTALL_DIR\" && npm start"
    exit 0
    ;;
esac

info "Starting miner (Ctrl+C to stop)"
exec npm start
