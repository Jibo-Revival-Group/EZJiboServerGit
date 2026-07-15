#!/usr/bin/env bash
#
# EZJiboServer setup.sh
#
# One-command bootstrap for running JiboExperiments/OpenJibo.
#
# This script is meant to be run straight from the internet:
#
#   curl -fsSL https://raw.githubusercontent.com/Jibo-Revival-Group/EZJiboServer/main/setup.sh | bash
#
# It installs the required toolchain (.NET 10 SDK, PowerShell, openssl, ffmpeg,
# git, C/C++ build tools, and a locally built whisper.cpp + model), clones
# JiboExperiments into $EZJIBOSERVER_HOME, writes a ready-to-use OpenJibo/.env,
# generates self-signed TLS certs for live/device mode, warms up the build, and
# writes run.sh + update.sh into $EZJIBOSERVER_HOME.
#
# setup.sh itself is NOT left behind in the install directory; only run.sh and
# update.sh are. (This file lives in the EZJiboServer git repo as the source.)
#
# Usage (when downloaded locally):
#   ./setup.sh [--home DIR] [--skip-deps] [--skip-whisper] [--skip-build]
#              [--skip-certs] [--force-certs] [-y]
#
# Environment:
#   EZJIBOSERVER_HOME   Target directory (default: ~/EZJiboServer)
#   REPO_URL            Git URL to clone (default: the JiboExperiments repo)
#   WHISPER_MODEL       Whisper model name to download (default: base.en)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration and constants
# ---------------------------------------------------------------------------

BRAND="EZJiboServer"
REPO_URL="${REPO_URL:-https://github.com/Jibo-Revival-Group/JiboExperiments.git}"
DOTNET_CHANNEL="10.0"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"
WHISPER_MODEL="${WHISPER_MODEL:-base.en}"

# Hostnames a real Jibo expects; baked into the self-signed certificate SANs.
CERT_HOSTS=(api.jibo.com api-socket.jibo.com neo-hub.jibo.com localhost)

# Distro-packaged .NET 10 SDKs (e.g. Arch) often ship the AspNetCore shared
# framework without the new "prune package data", which makes restore fail with
# NETSDK1226. MSBuild reads env vars as properties, so exporting this relaxes
# that error for every dotnet invocation below.
export AllowMissingPrunePackageData=true

# Defaults; can be overridden by flags below.
EZJIBOSERVER_HOME="${EZJIBOSERVER_HOME:-$HOME/EZJiboServer}"
SKIP_DEPS=0
SKIP_WHISPER=0
SKIP_BUILD=0
SKIP_CERTS=0
FORCE_CERTS=0
ASSUME_YES=0

# ---------------------------------------------------------------------------
# Pretty logging
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_BLUE="\033[34m"
  C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()  { printf "${C_BLUE}${C_BOLD}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}  ok${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}  !!${C_RESET} %s\n" "$*" >&2; }
die()  { printf "${C_RED}${C_BOLD}error:${C_RESET} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
$BRAND setup

Usage: ./setup.sh [options]

Options:
  --home DIR       Install location (default: ~/EZJiboServer)
  --skip-deps      Do not install system dependencies (only verify)
  --skip-whisper   Do not build whisper.cpp or download a model
  --skip-build     Do not run the dotnet restore/build warm-up
  --skip-certs     Do not generate TLS certificates
  --force-certs    Regenerate TLS certificates even if they exist
  -y, --yes        Non-interactive; assume "yes" to prompts
  -h, --help       Show this help

Environment:
  EZJIBOSERVER_HOME  Same as --home
  REPO_URL           Git URL to clone (default JiboExperiments)
  WHISPER_MODEL      Whisper model to download (default base.en)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)        EZJIBOSERVER_HOME="${2:?--home needs a value}"; shift 2 ;;
    --home=*)      EZJIBOSERVER_HOME="${1#*=}"; shift ;;
    --skip-deps)   SKIP_DEPS=1; shift ;;
    --skip-whisper) SKIP_WHISPER=1; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    --skip-certs)  SKIP_CERTS=1; shift ;;
    --force-certs) FORCE_CERTS=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

# Normalize to an absolute path.
mkdir -p "$EZJIBOSERVER_HOME"
EZJIBOSERVER_HOME="$(cd "$EZJIBOSERVER_HOME" && pwd)"

REPO_DIR="$EZJIBOSERVER_HOME/JiboExperiments"
OPENJIBO_DIR="$REPO_DIR/OpenJibo"
WHISPER_DIR="$EZJIBOSERVER_HOME/whisper.cpp"
CERT_DIR="$EZJIBOSERVER_HOME/certs"
LOCAL_DOTNET="$HOME/.dotnet"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a usable `dotnet` binary that is >= major version 10.
DOTNET_BIN=""
dotnet_major() {
  local bin="$1" ver
  ver="$("$bin" --version 2>/dev/null | head -n1)" || return 1
  [[ -n "$ver" ]] || return 1
  printf '%s' "${ver%%.*}"
}

resolve_dotnet() {
  local candidate
  for candidate in dotnet "$LOCAL_DOTNET/dotnet"; do
    if have "$candidate" || [[ -x "$candidate" ]]; then
      local maj
      maj="$(dotnet_major "$candidate" 2>/dev/null || true)"
      if [[ -n "$maj" && "$maj" -ge 10 ]]; then
        DOTNET_BIN="$candidate"
        return 0
      fi
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Platform / package-manager detection
# ---------------------------------------------------------------------------

OS="$(uname -s)"
PKG=""          # pacman | apt | dnf | brew
SUDO=""

detect_platform() {
  if [[ "$OS" == "Darwin" ]]; then
    have brew || die "Homebrew is required on macOS. Install from https://brew.sh and re-run."
    PKG="brew"
  elif have pacman; then
    PKG="pacman"
  elif have apt-get; then
    PKG="apt"
  elif have dnf; then
    PKG="dnf"
  elif have brew; then
    PKG="brew"
  else
    PKG=""
  fi

  # Determine whether we need (and have) sudo for system installs.
  if [[ "$PKG" != "brew" && "$(id -u)" -ne 0 ]]; then
    if have sudo; then
      SUDO="sudo"
    else
      warn "Not running as root and 'sudo' not found; system package installs may fail."
    fi
  fi
}

pm_update_done=0
pm_update() {
  [[ "$pm_update_done" -eq 1 ]] && return 0
  case "$PKG" in
    pacman) $SUDO pacman -Sy --noconfirm >/dev/null ;;
    apt)    $SUDO apt-get update -y >/dev/null ;;
    dnf)    : ;;
    brew)   : ;;
  esac
  pm_update_done=1
}

pm_install() {
  # pm_install pkg [pkg...]
  [[ $# -gt 0 ]] || return 0
  pm_update
  case "$PKG" in
    pacman) $SUDO pacman -S --needed --noconfirm "$@" ;;
    apt)    $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    brew)   brew install "$@" ;;
    *)      die "no supported package manager to install: $*" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency installation
# ---------------------------------------------------------------------------

install_base_tools() {
  log "Installing base tools (git, openssl, ffmpeg, curl, build toolchain, cmake)"

  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    warn "--skip-deps set; only verifying base tools are present"
    for t in git openssl ffmpeg curl cmake; do
      have "$t" && ok "$t" || warn "$t missing"
    done
    return 0
  fi

  case "$PKG" in
    pacman)
      pm_install base-devel cmake git openssl ffmpeg curl
      ;;
    apt)
      pm_install build-essential cmake git openssl ffmpeg curl ca-certificates
      ;;
    dnf)
      $SUDO dnf groupinstall -y "Development Tools" || true
      pm_install cmake git openssl ffmpeg curl ca-certificates gcc-c++
      ;;
    brew)
      pm_install cmake git openssl ffmpeg curl
      ;;
    *)
      warn "unknown package manager; verifying tools only"
      for t in git openssl ffmpeg curl cmake; do
        have "$t" && ok "$t" || warn "$t missing (install it manually)"
      done
      ;;
  esac
  ok "base tools ready"
}

install_dotnet() {
  log "Ensuring .NET $DOTNET_CHANNEL SDK is available"

  if resolve_dotnet; then
    ok "found dotnet $("$DOTNET_BIN" --version) ($DOTNET_BIN)"
    return 0
  fi

  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    die ".NET 10 SDK not found and --skip-deps was set."
  fi

  # Try the distro package first where it is reliably new enough, otherwise
  # fall back to Microsoft's official install script (into ~/.dotnet).
  case "$PKG" in
    pacman)
      pm_install dotnet-sdk || true
      ;;
    brew)
      brew install --cask dotnet-sdk || brew install dotnet || true
      ;;
  esac

  if resolve_dotnet; then
    ok "installed dotnet $("$DOTNET_BIN" --version) via $PKG"
    return 0
  fi

  log "Installing .NET $DOTNET_CHANNEL via official dotnet-install script into $LOCAL_DOTNET"
  local script="$EZJIBOSERVER_HOME/.cache/dotnet-install.sh"
  mkdir -p "$(dirname "$script")"
  if have curl; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
  elif have wget; then
    wget -qO "$script" https://dot.net/v1/dotnet-install.sh
  else
    die "need curl or wget to download dotnet-install.sh"
  fi
  chmod +x "$script"
  "$script" --channel "$DOTNET_CHANNEL" --install-dir "$LOCAL_DOTNET"

  export PATH="$LOCAL_DOTNET:$PATH"
  resolve_dotnet || die ".NET install completed but a >=10 dotnet is still not resolvable."
  ok "installed dotnet $("$DOTNET_BIN" --version) into $LOCAL_DOTNET"
}

install_powershell() {
  log "Ensuring PowerShell (pwsh) is available"

  if have pwsh; then
    ok "found pwsh $(pwsh --version 2>/dev/null || echo '?')"
    return 0
  fi

  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    die "pwsh not found and --skip-deps was set."
  fi

  case "$PKG" in
    pacman)
      # PowerShell lives in the AUR; use an AUR helper if present.
      if have yay; then
        yay -S --needed --noconfirm powershell-bin && have pwsh && { ok "installed pwsh via yay"; return 0; }
      elif have paru; then
        paru -S --needed --noconfirm powershell-bin && have pwsh && { ok "installed pwsh via paru"; return 0; }
      fi
      ;;
    apt)
      # Prefer the Microsoft package feed; fall back to the tarball below.
      if install_powershell_ms_apt && have pwsh; then ok "installed pwsh via apt"; return 0; fi
      ;;
    dnf)
      if install_powershell_ms_dnf && have pwsh; then ok "installed pwsh via dnf"; return 0; fi
      ;;
    brew)
      brew install --cask powershell || brew install powershell || true
      have pwsh && { ok "installed pwsh via brew"; return 0; }
      ;;
  esac

  install_powershell_tarball
}

install_powershell_ms_apt() {
  local codename
  codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
  local deb="$EZJIBOSERVER_HOME/.cache/packages-microsoft-prod.deb"
  mkdir -p "$(dirname "$deb")"
  # This URL layout is per-distro; try the generic Ubuntu/Debian bootstrap.
  local id; id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
  local url="https://packages.microsoft.com/config/${id}/${codename}/packages-microsoft-prod.deb"
  if curl -fsSL "$url" -o "$deb" 2>/dev/null; then
    $SUDO dpkg -i "$deb" >/dev/null 2>&1 || true
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    $SUDO apt-get install -y powershell >/dev/null 2>&1 || true
  fi
  have pwsh
}

install_powershell_ms_dnf() {
  $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc >/dev/null 2>&1 || true
  curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo 2>/dev/null \
    | $SUDO tee /etc/yum.repos.d/microsoft-prod.repo >/dev/null 2>&1 || true
  $SUDO dnf install -y powershell >/dev/null 2>&1 || true
  have pwsh
}

install_powershell_tarball() {
  log "Installing PowerShell from the official GitHub release tarball into ~/.powershell"
  have curl || die "need curl to download PowerShell tarball"

  local arch tag asset
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported CPU architecture for PowerShell tarball: $(uname -m)" ;;
  esac

  tag="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
        | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
  [[ -n "$tag" ]] || die "could not determine latest PowerShell release"

  if [[ "$OS" == "Darwin" ]]; then
    asset="powershell-${tag}-osx-${arch}.tar.gz"
  else
    asset="powershell-${tag}-linux-${arch}.tar.gz"
  fi

  local url="https://github.com/PowerShell/PowerShell/releases/download/v${tag}/${asset}"
  local dest="$HOME/.powershell"
  local tarball="$EZJIBOSERVER_HOME/.cache/${asset}"
  mkdir -p "$dest" "$(dirname "$tarball")"

  curl -fsSL "$url" -o "$tarball" || die "failed to download $url"
  tar -xzf "$tarball" -C "$dest"
  chmod +x "$dest/pwsh"
  export PATH="$dest:$PATH"
  have pwsh || die "PowerShell tarball extracted but 'pwsh' is not on PATH ($dest)."
  ok "installed pwsh $(pwsh --version 2>/dev/null || echo "$tag") into $dest"
}

build_whisper() {
  if [[ "$SKIP_WHISPER" -eq 1 ]]; then
    warn "--skip-whisper set; skipping whisper.cpp build and model download"
    return 0
  fi

  log "Building whisper.cpp into $WHISPER_DIR"

  local cli="$WHISPER_DIR/build/bin/whisper-cli"
  local model="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"

  if [[ ! -d "$WHISPER_DIR/.git" ]]; then
    git clone --depth 1 "$WHISPER_REPO" "$WHISPER_DIR"
  else
    git -C "$WHISPER_DIR" pull --ff-only || warn "could not update existing whisper.cpp checkout"
  fi

  if [[ -x "$cli" ]]; then
    ok "whisper-cli already built ($cli)"
  else
    ( cd "$WHISPER_DIR" \
      && cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && cmake --build build --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" >/dev/null )
    [[ -x "$cli" ]] || die "whisper.cpp build finished but $cli is missing"
    ok "built whisper-cli"
  fi

  if [[ -f "$model" ]]; then
    ok "whisper model present ($model)"
  else
    log "Downloading whisper model: $WHISPER_MODEL"
    ( cd "$WHISPER_DIR" && bash ./models/download-ggml-model.sh "$WHISPER_MODEL" )
    [[ -f "$model" ]] || die "model download finished but $model is missing"
    ok "downloaded $model"
  fi
}

# ---------------------------------------------------------------------------
# Clone + configure OpenJibo
# ---------------------------------------------------------------------------

clone_repo() {
  log "Fetching JiboExperiments into $REPO_DIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only && ok "updated existing checkout" \
      || warn "could not fast-forward existing checkout; leaving as-is"
  else
    git clone "$REPO_URL" "$REPO_DIR"
    ok "cloned $REPO_URL"
  fi

  [[ -d "$OPENJIBO_DIR" ]] || die "expected OpenJibo directory not found at $OPENJIBO_DIR"
}

setup_env() {
  local env_file="$OPENJIBO_DIR/.env"
  local example="$OPENJIBO_DIR/.env.example"

  if [[ -f "$env_file" ]]; then
    warn "existing $env_file found; leaving it untouched (it may hold encryption keys)"
    return 0
  fi

  log "Creating $env_file"
  [[ -f "$example" ]] || die "missing $example to base the .env on"

  local encrypt salt ffmpeg_path whisper_cli whisper_model
  encrypt="$(openssl rand -base64 48 | tr -d '\n')"
  salt="$(openssl rand -hex 16)"
  ffmpeg_path="$(command -v ffmpeg || echo /usr/bin/ffmpeg)"
  whisper_cli="$WHISPER_DIR/build/bin/whisper-cli"
  whisper_model="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"

  # Start from the example, then strip the placeholder secret lines so we can
  # append freshly generated values.
  grep -vE '^(OPENJIBO_USER_ENCRYPT|OPENJIBO_USER_SALT|OPENJIBO_STT_)' "$example" > "$env_file"

  {
    echo ""
    echo "# --- Generated by $BRAND setup.sh ---"
    echo "# Encryption material for user data. DO NOT CHANGE after first run."
    echo "OPENJIBO_USER_ENCRYPT=\"${encrypt}\""
    echo "OPENJIBO_USER_SALT=\"${salt}\""
    echo ""
    echo "# Local speech-to-text (whisper.cpp) paths."
    echo "OPENJIBO_STT_FFMPEG_PATH=\"${ffmpeg_path}\""
    echo "OPENJIBO_STT_WHISPER_CLI_PATH=\"${whisper_cli}\""
    echo "OPENJIBO_STT_WHISPER_MODEL_PATH=\"${whisper_model}\""
  } >> "$env_file"

  chmod 600 "$env_file" 2>/dev/null || true
  ok "wrote $env_file with generated secrets and STT paths"
}

generate_certs() {
  if [[ "$SKIP_CERTS" -eq 1 ]]; then
    warn "--skip-certs set; skipping TLS certificate generation"
    return 0
  fi

  local cert="$CERT_DIR/cert.pem"
  local key="$CERT_DIR/key.pem"

  if [[ -f "$cert" && -f "$key" && "$FORCE_CERTS" -ne 1 ]]; then
    ok "TLS certificates already present ($cert)"
    return 0
  fi

  log "Generating self-signed TLS certificates in $CERT_DIR"
  mkdir -p "$CERT_DIR"

  # Build a SAN list from CERT_HOSTS (+ loopback IP). Universally supported via
  # an openssl config file (works across openssl versions).
  local cfg="$CERT_DIR/.openssl-cert.cnf"
  {
    echo "[req]"
    echo "distinguished_name = dn"
    echo "x509_extensions = v3"
    echo "prompt = no"
    echo "[dn]"
    echo "CN = ${CERT_HOSTS[0]}"
    echo "[v3]"
    echo "subjectAltName = @alt"
    echo "basicConstraints = critical, CA:TRUE"
    echo "[alt]"
    local i=1 h
    for h in "${CERT_HOSTS[@]}"; do
      echo "DNS.${i} = ${h}"
      i=$((i + 1))
    done
    echo "IP.1 = 127.0.0.1"
  } > "$cfg"

  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$key" -out "$cert" -config "$cfg" >/dev/null 2>&1 \
    || die "openssl failed to generate certificates"

  rm -f "$cfg"
  chmod 600 "$key" 2>/dev/null || true
  ok "wrote $cert and $key (SANs: ${CERT_HOSTS[*]}, 127.0.0.1)"
}

warmup_build() {
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    warn "--skip-build set; skipping dotnet restore/build warm-up"
    return 0
  fi

  resolve_dotnet || die "cannot warm up build: no usable dotnet found"

  local proj="$OPENJIBO_DIR/src/Jibo.Cloud/dotnet/src/Jibo.Cloud.Api/Jibo.Cloud.Api.csproj"
  [[ -f "$proj" ]] || die "API project not found at $proj"

  log "Warming up the .NET build (restore + build)"
  ( cd "$OPENJIBO_DIR" && "$DOTNET_BIN" restore "$proj" && "$DOTNET_BIN" build "$proj" -c Debug --nologo )
  ok "build warm-up complete"
}

# ---------------------------------------------------------------------------
# Generate run.sh and update.sh into the install directory
#
# These are written from embedded heredocs (quoted, so nothing expands here)
# so the whole installer works from a single `curl | bash` with no other files.
# ---------------------------------------------------------------------------

write_run_scripts() {
  log "Writing run.sh and update.sh into $EZJIBOSERVER_HOME"

  cat > "$EZJIBOSERVER_HOME/run.sh" <<'RUNSH_EOF'
#!/usr/bin/env bash
#
# EZJiboServer run.sh  (generated by setup.sh)
#
# Starts the OpenJibo .NET cloud.
#
#   ./run.sh              # local dev cloud (https://localhost:24604 / http://localhost:24605)
#   ./run.sh local        # same as above
#   ./run.sh live         # live-device mode on port 443 with TLS certs (needs sudo)
#
# Live mode uses TLS certificates. By default it uses the self-signed pair that
# setup.sh generated in <home>/certs. Override with:
#   CERT_PEM   path to cert.pem
#   KEY_PEM    path to key.pem
#   CHAIN_PEM  optional CA chain

set -euo pipefail

# EZJiboServer home = the directory this script lives in.
EZJIBOSERVER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENJIBO_DIR="$EZJIBOSERVER_HOME/JiboExperiments/OpenJibo"

# Make locally installed toolchains discoverable (setup.sh may have placed
# .NET in ~/.dotnet and PowerShell in ~/.powershell).
[[ -d "$HOME/.dotnet" ]] && export PATH="$HOME/.dotnet:$PATH"
[[ -d "$HOME/.powershell" ]] && export PATH="$HOME/.powershell:$PATH"
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"

# Distro-packaged .NET 10 SDKs (e.g. Arch) can miss AspNetCore prune data,
# causing NETSDK1226 on restore. MSBuild reads this env var as a property.
export AllowMissingPrunePackageData=true

usage() {
  cat <<USAGE
EZJiboServer run

Usage: ./run.sh [mode]

Modes:
  local   (default) Local dev cloud.
            HTTPS:  https://localhost:24604
            HTTP:   http://localhost:24605
            Health: http://localhost:24605/health
  live    Live-device cloud on port 443 with TLS certs.
            Uses <home>/certs/{cert,key}.pem by default (override with
            CERT_PEM/KEY_PEM) and runs with sudo to bind the privileged port.

Options:
  -h, --help   Show this help
USAGE
}

MODE="local"
case "${1:-}" in
  ""|local)      MODE="local" ;;
  live)          MODE="live" ;;
  -h|--help)     usage; exit 0 ;;
  *)             echo "unknown mode: $1 (try --help)" >&2; exit 1 ;;
esac

[[ -d "$OPENJIBO_DIR" ]] || {
  echo "error: OpenJibo not found at $OPENJIBO_DIR" >&2
  echo "Run setup.sh first." >&2
  exit 1
}

cd "$OPENJIBO_DIR"

if [[ "$MODE" == "local" ]]; then
  command -v pwsh >/dev/null 2>&1 || {
    echo "error: pwsh (PowerShell) not found on PATH. Re-run setup.sh." >&2
    exit 1
  }
  echo "Starting OpenJibo (local dev): https://localhost:24604  http://localhost:24605"
  exec pwsh -NoProfile -File "scripts/cloud/Start-OpenJiboDotNet.ps1"
fi

# live mode
CERT_PEM="${CERT_PEM:-$EZJIBOSERVER_HOME/certs/cert.pem}"
KEY_PEM="${KEY_PEM:-$EZJIBOSERVER_HOME/certs/key.pem}"

if [[ ! -f "$CERT_PEM" || ! -f "$KEY_PEM" ]]; then
  cat >&2 <<CERTERR
error: live mode needs TLS certificate material.
  CERT_PEM=$CERT_PEM
  KEY_PEM=$KEY_PEM
Re-run setup.sh (it generates these), or provide your own via CERT_PEM/KEY_PEM.
Use the same certificate material your Jibo routing already trusts.
CERTERR
  exit 1
fi

echo "Starting OpenJibo (live device) on port 443 using:"
echo "  cert: $CERT_PEM"
echo "  key:  $KEY_PEM"

# Binding 443 needs privilege. Preserve our PATH/env for the child process.
RUN=(env "PATH=$PATH" "DOTNET_ROOT=$DOTNET_ROOT" \
     "AllowMissingPrunePackageData=true" \
     "CERT_PEM=$CERT_PEM" "KEY_PEM=$KEY_PEM")
[[ -n "${CHAIN_PEM:-}" ]] && RUN+=("CHAIN_PEM=$CHAIN_PEM")
[[ -n "${ASPNETCORE_URLS:-}" ]] && RUN+=("ASPNETCORE_URLS=$ASPNETCORE_URLS")

if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E "${RUN[@]}" bash "scripts/cloud/start-dotnet-with-node-cert.sh"
  fi
  echo "warning: not root and sudo not found; binding 443 will likely fail." >&2
fi

exec "${RUN[@]}" bash "scripts/cloud/start-dotnet-with-node-cert.sh"
RUNSH_EOF

  cat > "$EZJIBOSERVER_HOME/update.sh" <<'UPDATESH_EOF'
#!/usr/bin/env bash
#
# EZJiboServer update.sh  (generated by setup.sh)
#
# Updates the local JiboExperiments checkout (git pull) and refreshes the
# .NET restore so the next ./run.sh picks up new dependencies.
#
#   ./update.sh              # pull + restore
#   ./update.sh --no-restore # pull only

set -euo pipefail

EZJIBOSERVER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$EZJIBOSERVER_HOME/JiboExperiments"
OPENJIBO_DIR="$REPO_DIR/OpenJibo"

[[ -d "$HOME/.dotnet" ]] && export PATH="$HOME/.dotnet:$PATH"
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"

# Distro-packaged .NET 10 SDKs (e.g. Arch) can miss AspNetCore prune data,
# causing NETSDK1226 on restore. MSBuild reads this env var as a property.
export AllowMissingPrunePackageData=true

DO_RESTORE=1
case "${1:-}" in
  --no-restore) DO_RESTORE=0 ;;
  -h|--help)
    echo "Usage: ./update.sh [--no-restore]"
    echo "  Pulls the latest JiboExperiments and (by default) runs dotnet restore."
    exit 0
    ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
esac

[[ -d "$REPO_DIR/.git" ]] || {
  echo "error: $REPO_DIR is not a git checkout. Re-run setup.sh first." >&2
  exit 1
}

echo "==> Updating JiboExperiments ($REPO_DIR)"
git -C "$REPO_DIR" pull --ff-only

if [[ "$DO_RESTORE" -eq 1 ]]; then
  proj="$OPENJIBO_DIR/src/Jibo.Cloud/dotnet/src/Jibo.Cloud.Api/Jibo.Cloud.Api.csproj"
  if command -v dotnet >/dev/null 2>&1 && [[ -f "$proj" ]]; then
    echo "==> Restoring .NET dependencies"
    ( cd "$OPENJIBO_DIR" && dotnet restore "$proj" )
  else
    echo "!! skipping restore (dotnet not found or project missing)" >&2
  fi
fi

echo "Done. Start the server with: ./run.sh"
UPDATESH_EOF

  chmod +x "$EZJIBOSERVER_HOME/run.sh" "$EZJIBOSERVER_HOME/update.sh"
  ok "$EZJIBOSERVER_HOME/run.sh"
  ok "$EZJIBOSERVER_HOME/update.sh"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  printf "${C_BOLD}%s setup${C_RESET}\n" "$BRAND"
  log "Install location: $EZJIBOSERVER_HOME"

  detect_platform
  if [[ -n "$PKG" ]]; then
    ok "package manager: $PKG"
  else
    warn "no supported package manager detected; will only verify dependencies"
    SKIP_DEPS=1
  fi

  install_base_tools
  install_dotnet
  install_powershell
  build_whisper

  clone_repo
  setup_env
  generate_certs
  warmup_build
  write_run_scripts

  printf "\n${C_GREEN}${C_BOLD}Done.${C_RESET}\n"
  cat <<EOF

Next steps:
  cd "$EZJIBOSERVER_HOME"
  ./run.sh            # local dev cloud -> https://localhost:24604  http://localhost:24605
  ./run.sh live       # live device on port 443 (uses certs/, runs with sudo)
  ./update.sh         # pull the latest JiboExperiments

Health check (local mode): http://localhost:24605/health
EOF
}

main "$@"
