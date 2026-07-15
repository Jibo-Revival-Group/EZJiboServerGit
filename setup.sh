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
# Presentation layer
# ---------------------------------------------------------------------------

# Colors, only when stdout is a real terminal.
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
  C_BLUE="\033[38;5;39m"; C_CYAN="\033[38;5;44m"; C_GREEN="\033[38;5;42m"
  C_YELLOW="\033[38;5;220m"; C_RED="\033[38;5;203m"; C_GREY="\033[38;5;245m"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_CYAN=""; C_GREEN=""
  C_YELLOW=""; C_RED=""; C_GREY=""
fi

# Glyphs: unicode when the locale looks like UTF-8, else ASCII fallbacks.
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then
  G_OK="✓"; G_WARN="!"; G_ERR="✗"; G_DOT="•"; G_ARROW="➜"
  B_TL="╭"; B_TR="╮"; B_BL="╰"; B_BR="╯"; B_H="─"; B_V="│"
  T_MID="├─"; T_END="╰─"
else
  G_OK="+"; G_WARN="!"; G_ERR="x"; G_DOT="*"; G_ARROW=">"
  B_TL="+"; B_TR="+"; B_BL="+"; B_BR="+"; B_H="-"; B_V="|"
  T_MID="|-"; T_END="\`-"
fi

STEP=0
TOTAL_STEPS=10
BOX_W=54          # inner width of banner/rules
START_TS="$(date +%s)"

repeat() { local n="$1" s="$2" out=""; while (( n-- > 0 )); do out+="$s"; done; printf '%s' "$out"; }

rule() { printf "${C_GREY}%s${C_RESET}\n" "$(repeat $((BOX_W + 4)) "$B_H")"; }

banner() {
  local bar; bar="$(repeat $((BOX_W + 2)) "$B_H")"
  printf "\n${C_CYAN}%s%s%s${C_RESET}\n" "$B_TL" "$bar" "$B_TR"
  printf "${C_CYAN}${B_V}${C_RESET}  ${C_BOLD}${C_BLUE}%s${C_RESET}\n" "$BRAND"
  printf "${C_CYAN}${B_V}${C_RESET}  ${C_GREY}%s${C_RESET}\n" "One-command OpenJibo cloud installer"
  printf "${C_CYAN}%s%s%s${C_RESET}\n" "$B_BL" "$bar" "$B_BR"
}

step() {
  STEP=$((STEP + 1))
  printf "\n${C_BOLD}${C_BLUE}${G_ARROW}${C_RESET} ${C_DIM}[%d/%d]${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$STEP" "$TOTAL_STEPS" "$*"
}

info() { printf "   ${C_GREY}${G_DOT}${C_RESET} ${C_GREY}%s${C_RESET}\n" "$*"; }
ok()   { printf "   ${C_GREEN}${G_OK}${C_RESET} %s\n" "$*"; }
warn() { printf "   ${C_YELLOW}${G_WARN}${C_RESET} ${C_YELLOW}%s${C_RESET}\n" "$*" >&2; }
die()  { printf "\n${C_RED}${C_BOLD}${G_ERR} error:${C_RESET} ${C_RED}%s${C_RESET}\n" "$*" >&2; exit 1; }

summary() {
  local secs=$(( $(date +%s) - START_TS ))
  printf "\n"
  rule
  printf "  ${C_GREEN}${C_BOLD}${G_OK} %s is ready${C_RESET}  ${C_GREY}(%dm %02ds)${C_RESET}\n" "$BRAND" "$((secs / 60))" "$((secs % 60))"
  rule
  printf "\n  ${C_BOLD}Installed at${C_RESET}  ${C_CYAN}%s${C_RESET}\n\n" "$EZJIBOSERVER_HOME"
  printf "   ${C_GREY}%s${C_RESET}\n" "${EZJIBOSERVER_HOME}/"
  printf "   ${C_GREY}${T_MID}${C_RESET} ${C_BOLD}%-18s${C_RESET}${C_GREY}%s${C_RESET}\n" "run.sh" "start the OpenJibo server"
  printf "   ${C_GREY}${T_MID}${C_RESET} ${C_BOLD}%-18s${C_RESET}${C_GREY}%s${C_RESET}\n" "update.sh" "git pull the latest OpenJibo"
  printf "   ${C_GREY}${T_MID}${C_RESET} ${C_BOLD}%-18s${C_RESET}${C_GREY}%s${C_RESET}\n" "certs/" "self-signed TLS for live mode"
  printf "   ${C_GREY}${T_MID}${C_RESET} ${C_BOLD}%-18s${C_RESET}${C_GREY}%s${C_RESET}\n" "whisper.cpp/" "local speech-to-text"
  printf "   ${C_GREY}${T_END}${C_RESET} ${C_BOLD}%-18s${C_RESET}${C_GREY}%s${C_RESET}\n" "JiboExperiments/" "cloned OpenJibo source"
  printf "\n  ${C_BOLD}Next steps${C_RESET}\n"
  printf "    ${C_BLUE}${G_ARROW}${C_RESET} cd %s\n" "$EZJIBOSERVER_HOME"
  printf "    ${C_BLUE}${G_ARROW}${C_RESET} ${C_BOLD}./run.sh${C_RESET}        ${C_GREY}# https://localhost:24604  http://localhost:24605${C_RESET}\n"
  printf "    ${C_BLUE}${G_ARROW}${C_RESET} ${C_BOLD}./run.sh live${C_RESET}   ${C_GREY}# port 443 + TLS (real Jibo, uses sudo)${C_RESET}\n"
  printf "    ${C_BLUE}${G_ARROW}${C_RESET} ${C_BOLD}./update.sh${C_RESET}     ${C_GREY}# pull the latest OpenJibo${C_RESET}\n"
  printf "\n  ${C_GREY}Health check (local): http://localhost:24605/health${C_RESET}\n\n"
}

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
  step "Installing base tools (git, openssl, ffmpeg, curl, build toolchain, cmake)"

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
  step "Ensuring .NET $DOTNET_CHANNEL SDK is available"

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

  info "Installing .NET $DOTNET_CHANNEL via official dotnet-install script into $LOCAL_DOTNET"
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
  step "Ensuring PowerShell (pwsh) is available"

  # pwsh may already be installed as a .NET global tool.
  [[ -d "$HOME/.dotnet/tools" ]] && export PATH="$HOME/.dotnet/tools:$PATH"

  if have pwsh; then
    ok "found pwsh $(pwsh --version 2>/dev/null || echo '?')"
    return 0
  fi

  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    warn "pwsh not found and --skip-deps set; continuing without it"
    return 0
  fi

  # 1) Distro package where it is reliable.
  case "$PKG" in
    pacman)
      if have yay; then yay -S --needed --noconfirm powershell-bin >/dev/null 2>&1 || true
      elif have paru; then paru -S --needed --noconfirm powershell-bin >/dev/null 2>&1 || true; fi
      ;;
    apt)  install_powershell_ms_apt || true ;;
    dnf)  install_powershell_ms_dnf || true ;;
    brew) brew install --cask powershell >/dev/null 2>&1 || brew install powershell >/dev/null 2>&1 || true ;;
  esac
  if have pwsh; then ok "installed pwsh via $PKG"; return 0; fi

  # 2) .NET global tool. Works on any distro since the SDK is already installed,
  #    and needs no Microsoft apt/yum repo (great for brand-new distro releases).
  if resolve_dotnet; then
    info "Installing PowerShell as a .NET global tool"
    if "$DOTNET_BIN" tool install --global PowerShell >/dev/null 2>&1 \
       || "$DOTNET_BIN" tool update --global PowerShell >/dev/null 2>&1; then
      export PATH="$HOME/.dotnet/tools:$PATH"
      if have pwsh; then ok "installed pwsh $(pwsh --version 2>/dev/null || echo '') via dotnet tool"; return 0; fi
    fi
  fi

  # 3) Official tarball (last resort).
  if install_powershell_tarball && have pwsh; then
    return 0
  fi

  # PowerShell is optional: run.sh runs the server without it (it is only needed
  # for the repo's auxiliary .ps1 helper scripts).
  warn "could not install PowerShell; continuing (the server still runs without it)"
  return 0
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

# Non-fatal: returns non-zero on failure so callers can fall through.
install_powershell_tarball() {
  have curl || return 1
  info "Installing PowerShell from the official GitHub release tarball into ~/.powershell"

  local arch tag asset
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "unsupported CPU architecture for PowerShell tarball: $(uname -m)"; return 1 ;;
  esac

  tag="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
  [[ -n "$tag" ]] || { warn "could not determine latest PowerShell release"; return 1; }

  if [[ "$OS" == "Darwin" ]]; then
    asset="powershell-${tag}-osx-${arch}.tar.gz"
  else
    asset="powershell-${tag}-linux-${arch}.tar.gz"
  fi

  local url="https://github.com/PowerShell/PowerShell/releases/download/v${tag}/${asset}"
  local dest="$HOME/.powershell"
  mkdir -p "$dest"

  # Stream straight into tar to avoid a large intermediate file (some minimal
  # containers fail writing big temp files: "curl: (23) Failure writing output").
  if ! curl -fSL --retry 3 --retry-delay 2 "$url" 2>/dev/null | tar -xz -C "$dest"; then
    warn "failed to download/extract $url"
    return 1
  fi
  [[ -x "$dest/pwsh" ]] || { warn "PowerShell extracted but $dest/pwsh is missing"; return 1; }
  chmod +x "$dest/pwsh"
  export PATH="$dest:$PATH"
  ok "installed pwsh $(pwsh --version 2>/dev/null || echo "$tag") into $dest"
  return 0
}

build_whisper() {
  step "Building whisper.cpp (local speech-to-text)"

  if [[ "$SKIP_WHISPER" -eq 1 ]]; then
    warn "--skip-whisper set; skipping whisper.cpp build and model download"
    return 0
  fi

  info "Target: $WHISPER_DIR"

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
    # Cap parallel compile jobs by available RAM (~1.5 GB per C++ job) so the
    # build does not get OOM-killed in small containers/LXCs.
    local cores mem_mb jobs
    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
    jobs=$(( mem_mb / 1500 ))
    [[ "$jobs" -lt 1 ]] && jobs=1
    [[ "$jobs" -gt "$cores" ]] && jobs="$cores"
    info "Compiling with $jobs job(s) (cores: $cores, RAM: ${mem_mb} MB)"
    ( cd "$WHISPER_DIR" \
      && cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && cmake --build build --config Release -j "$jobs" >/dev/null )
    [[ -x "$cli" ]] || die "whisper.cpp build finished but $cli is missing"
    ok "built whisper-cli"
  fi

  if [[ -f "$model" ]]; then
    ok "whisper model present ($model)"
  else
    info "Downloading whisper model: $WHISPER_MODEL"
    ( cd "$WHISPER_DIR" && bash ./models/download-ggml-model.sh "$WHISPER_MODEL" )
    [[ -f "$model" ]] || die "model download finished but $model is missing"
    ok "downloaded $model"
  fi
}

# ---------------------------------------------------------------------------
# Clone + configure OpenJibo
# ---------------------------------------------------------------------------

clone_repo() {
  step "Fetching JiboExperiments"
  info "Into $REPO_DIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only && ok "updated existing checkout" \
      || warn "could not fast-forward existing checkout; leaving as-is"
  else
    git clone "$REPO_URL" "$REPO_DIR"
    ok "cloned $REPO_URL"
  fi

  [[ -d "$OPENJIBO_DIR" ]] || die "expected OpenJibo directory not found at $OPENJIBO_DIR"
}

# Ensure the OPENJIBO_STT_* keys carry the given values, replacing any existing
# ones and leaving every other line (encryption secrets, search config, ...)
# exactly as-is. Safe to run repeatedly.
write_stt_paths() {
  local file="$1" ffmpeg="$2" cli="$3" model="$4"
  local tmp; tmp="$(mktemp)"

  # Drop any prior STT keys + our generated STT comment, then trim trailing
  # blank lines so repeated runs never accumulate whitespace.
  { grep -vE '^(OPENJIBO_STT_(FFMPEG_PATH|WHISPER_CLI_PATH|WHISPER_MODEL_PATH)=|# Local speech-to-text)' "$file" || true; } \
    | awk '{ lines[n++]=$0 } END { last=n; while (last>0 && lines[last-1]=="") last--; for (i=0;i<last;i++) print lines[i] }' \
    > "$tmp"

  {
    echo ""
    echo "# Local speech-to-text (whisper.cpp) paths. Auto-configured by $BRAND setup.sh."
    echo "OPENJIBO_STT_FFMPEG_PATH=\"${ffmpeg}\""
    echo "OPENJIBO_STT_WHISPER_CLI_PATH=\"${cli}\""
    echo "OPENJIBO_STT_WHISPER_MODEL_PATH=\"${model}\""
  } >> "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

setup_env() {
  step "Configuring environment (.env)"

  local env_file="$OPENJIBO_DIR/.env"
  local example="$OPENJIBO_DIR/.env.example"

  local ffmpeg_path whisper_cli whisper_model
  ffmpeg_path="$(command -v ffmpeg || echo /usr/bin/ffmpeg)"
  whisper_cli="$WHISPER_DIR/build/bin/whisper-cli"
  whisper_model="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"

  # Existing .env: keep secrets/other settings, just (re)write the STT paths.
  if [[ -f "$env_file" ]]; then
    info "Existing .env found; refreshing speech-to-text paths (secrets untouched)"
    write_stt_paths "$env_file" "$ffmpeg_path" "$whisper_cli" "$whisper_model"
    chmod 600 "$env_file" 2>/dev/null || true
    ok "ensured STT paths in $env_file"
    return 0
  fi

  info "Creating $env_file"
  [[ -f "$example" ]] || die "missing $example to base the .env on"

  local encrypt salt
  encrypt="$(openssl rand -base64 48 | tr -d '\n')"
  salt="$(openssl rand -hex 16)"

  # Start from the example, then strip the placeholder secret/STT lines so we
  # can append freshly generated values.
  grep -vE '^(OPENJIBO_USER_ENCRYPT|OPENJIBO_USER_SALT|OPENJIBO_STT_)' "$example" > "$env_file"

  {
    echo ""
    echo "# --- Generated by $BRAND setup.sh ---"
    echo "# Encryption material for user data. DO NOT CHANGE after first run."
    echo "OPENJIBO_USER_ENCRYPT=\"${encrypt}\""
    echo "OPENJIBO_USER_SALT=\"${salt}\""
  } >> "$env_file"

  write_stt_paths "$env_file" "$ffmpeg_path" "$whisper_cli" "$whisper_model"

  chmod 600 "$env_file" 2>/dev/null || true
  ok "wrote $env_file with generated secrets and STT paths"
}

generate_certs() {
  step "Generating TLS certificates (live/device mode)"

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

  info "Writing self-signed pair into $CERT_DIR"
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
  step "Warming up the .NET build (restore + build)"

  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    warn "--skip-build set; skipping dotnet restore/build warm-up"
    return 0
  fi

  resolve_dotnet || die "cannot warm up build: no usable dotnet found"

  local proj="$OPENJIBO_DIR/src/Jibo.Cloud/dotnet/src/Jibo.Cloud.Api/Jibo.Cloud.Api.csproj"
  [[ -f "$proj" ]] || die "API project not found at $proj"

  info "This can take a minute on first run..."
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
  step "Writing launcher scripts (run.sh, update.sh)"
  info "Into $EZJIBOSERVER_HOME"

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

# Make locally installed toolchains discoverable.
[[ -d "$HOME/.dotnet/tools" ]] && export PATH="$HOME/.dotnet/tools:$PATH"
[[ -d "$HOME/.powershell" ]] && export PATH="$HOME/.powershell:$PATH"

# Point DOTNET_ROOT at a REAL .NET install. Standalone apphosts (e.g. the pwsh
# dotnet-tool) locate the runtime via DOTNET_ROOT, so a wrong value (~/.dotnet
# with only a tools/ dir and no runtime) breaks them. Prefer a local SDK under
# ~/.dotnet, otherwise resolve the system dotnet's real install directory.
if [[ -x "$HOME/.dotnet/dotnet" ]]; then
  export PATH="$HOME/.dotnet:$PATH"
  export DOTNET_ROOT="$HOME/.dotnet"
elif command -v dotnet >/dev/null 2>&1; then
  _dn="$(readlink -f "$(command -v dotnet)" 2>/dev/null || command -v dotnet)"
  _dn_dir="$(dirname "$_dn")"
  [[ -d "$_dn_dir/shared" ]] && export DOTNET_ROOT="$_dn_dir"
fi

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
  command -v dotnet >/dev/null 2>&1 || {
    echo "error: dotnet not found on PATH. Re-run setup.sh." >&2
    exit 1
  }
  echo "Starting OpenJibo (local dev): https://localhost:24604  http://localhost:24605"

  # Prefer the repo's PowerShell launcher when pwsh is available (keeps parity
  # with the upstream tooling). Otherwise run dotnet directly with the same
  # capture directories the .ps1 sets up -- PowerShell is not required.
  if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "scripts/cloud/Start-OpenJiboDotNet.ps1"
  fi

  echo "(pwsh not found -- running dotnet directly)"
  CAP_WS="$OPENJIBO_DIR/captures/websocket"
  CAP_HTTP="$OPENJIBO_DIR/captures/http"
  mkdir -p "$CAP_WS" "$CAP_HTTP"
  export OpenJibo__Telemetry__DirectoryPath="$CAP_WS"
  export OpenJibo__ProtocolTelemetry__DirectoryPath="$CAP_HTTP"
  exec dotnet run \
    --project "src/Jibo.Cloud/dotnet/src/Jibo.Cloud.Api/Jibo.Cloud.Api.csproj" \
    --launch-profile Jibo.Cloud.Api
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
RUN=(env "PATH=$PATH" \
     "AllowMissingPrunePackageData=true" \
     "CERT_PEM=$CERT_PEM" "KEY_PEM=$KEY_PEM")
[[ -n "${DOTNET_ROOT:-}" ]] && RUN+=("DOTNET_ROOT=$DOTNET_ROOT")
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

[[ -d "$HOME/.dotnet/tools" ]] && export PATH="$HOME/.dotnet/tools:$PATH"

# Point DOTNET_ROOT at a real .NET install (see run.sh for details).
if [[ -x "$HOME/.dotnet/dotnet" ]]; then
  export PATH="$HOME/.dotnet:$PATH"
  export DOTNET_ROOT="$HOME/.dotnet"
elif command -v dotnet >/dev/null 2>&1; then
  _dn="$(readlink -f "$(command -v dotnet)" 2>/dev/null || command -v dotnet)"
  _dn_dir="$(dirname "$_dn")"
  [[ -d "$_dn_dir/shared" ]] && export DOTNET_ROOT="$_dn_dir"
fi

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
  banner

  step "Checking system"
  info "Install location: $EZJIBOSERVER_HOME"
  detect_platform
  if [[ -n "$PKG" ]]; then
    ok "detected $OS with package manager: $PKG"
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

  summary
}

main "$@"
