#!/usr/bin/env bash
#
# smart-install.sh — idempotent installer / upgrade resolver for the kimi-code
# fork (csillag/kimi-code) prebuilt binaries.
#
#   curl -fsSL https://raw.githubusercontent.com/csillag/kimi-code/csillag/iframe-build/smart-install.sh | bash
#
# It checks the LOCALLY-installed `kimi --version` against the latest fork
# release and only acts when they differ. Four modes:
#
#   (default)     install/upgrade in place (download + verify + unzip + PATH)
#   --check       report status only; exit 0 if up-to-date, 3 if update needed
#   --url         print just the download URL for this machine's target, exit 0
#   --resolve     print JSON {needs_update,target,installed,latest,tag,url,sha256,
#                 sha256_url} so a caller (e.g. optio) can download it with its
#                 own tooling (progress/visibility) and verify the checksum
#
# There is deliberately no separate install.sh: this one script both resolves
# and (optionally) installs. Linux + macOS only; Windows is not supported.
#
# The GitHub release tag is `v<upstream>-csillag.<N>.<sha>`; the value
# `kimi --version` prints is `<upstream>-csillag.<N>` — recovered from the tag
# by stripping the leading `v` and the trailing `.<sha>` group. Keep that
# transform in sync with build-fork.yml.
set -euo pipefail

REPO="csillag/kimi-code"
APP="kimi"
INSTALL_DIR="${KIMI_INSTALL_DIR:-$HOME/.kimi-code/bin}"
MODE="install"
PIN_TAG=""
MODIFY_PATH=1

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'smart-install: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check" ;;
    --url)     MODE="url" ;;
    --resolve|--json) MODE="resolve" ;;
    -v|--version) PIN_TAG="${2:-}"; shift ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift ;;
    --no-modify-path) MODIFY_PATH=0 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# --- target detection (linux|darwin)-(x64|arm64) ----------------------------
detect_target() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) die "unsupported OS '$(uname -s)' (linux/macOS only)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "unsupported arch '$(uname -m)'" ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

# --- release resolution ------------------------------------------------------
latest_tag() {
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1
}

# tag (v<upstream>-csillag.<N>.<sha>) -> binary version (<upstream>-csillag.<N>)
tag_to_version() { printf '%s' "$1" | sed -E 's/^v//; s/\.[0-9a-f]+$//'; }

installed_version() {
  command -v "$APP" >/dev/null 2>&1 || return 0
  "$APP" --version 2>/dev/null | tr -d '[:space:]' | head -n1 || true
}

TARGET="$(detect_target)"
FILENAME="kimi-code-${TARGET}.zip"

if [ -n "$PIN_TAG" ]; then
  TAG="$PIN_TAG"
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
else
  TAG="$(latest_tag)"
  [ -n "$TAG" ] || die "could not resolve the latest release tag from github.com/${REPO}"
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
fi
LATEST_VERSION="$(tag_to_version "$TAG")"
URL="${BASE_URL}/${FILENAME}"
SHA_URL="${URL}.sha256"

INSTALLED="$(installed_version)"
NEEDS_UPDATE=1
# `kimi --version` prints the bare version string, so match it exactly (a
# substring test would treat 0.22.3-csillag.10 as matching ...csillag.1).
if [ -n "$INSTALLED" ] && [ "$INSTALLED" = "$LATEST_VERSION" ]; then
  NEEDS_UPDATE=0
fi

# --- non-installing modes ----------------------------------------------------
case "$MODE" in
  url)
    printf '%s\n' "$URL"
    exit 0
    ;;
  check)
    if [ "$NEEDS_UPDATE" -eq 0 ]; then
      log "kimi up-to-date ($LATEST_VERSION)"
      exit 0
    fi
    log "kimi update available: ${INSTALLED:-<none>} -> $LATEST_VERSION (tag $TAG)"
    exit 3
    ;;
  resolve)
    # Fetch the checksum sidecar (hex in the first field) for the caller to verify.
    SHA256="$(curl -fsSL "$SHA_URL" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    printf '{"needs_update":%s,"target":"%s","installed":%s,"latest":"%s","tag":"%s","url":"%s","sha256":%s,"sha256_url":"%s"}\n' \
      "$([ "$NEEDS_UPDATE" -eq 1 ] && echo true || echo false)" \
      "$TARGET" \
      "$([ -n "$INSTALLED" ] && printf '"%s"' "$INSTALLED" || echo null)" \
      "$LATEST_VERSION" "$TAG" "$URL" \
      "$([ -n "$SHA256" ] && printf '"%s"' "$SHA256" || echo null)" \
      "$SHA_URL"
    exit 0
    ;;
esac

# --- install mode ------------------------------------------------------------
if [ "$NEEDS_UPDATE" -eq 0 ]; then
  log "kimi $INSTALLED already up-to-date (latest $LATEST_VERSION, tag $TAG)"
  exit 0
fi
[ -n "$INSTALLED" ] \
  && log "kimi upgrade: $INSTALLED -> $LATEST_VERSION (tag $TAG)" \
  || log "kimi not installed; installing $LATEST_VERSION (tag $TAG)"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/$FILENAME"

log "downloading $URL"
curl -fSL --progress-bar "$URL" -o "$ZIP" || die "download failed: $URL"

# Verify SHA-256 against the sidecar when a checksum tool is available.
EXPECTED="$(curl -fsSL "$SHA_URL" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
if [ -n "$EXPECTED" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$ZIP" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  else
    ACTUAL=""
  fi
  if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$EXPECTED" ]; then
    die "checksum mismatch: expected $EXPECTED, got $ACTUAL"
  fi
  [ -n "$ACTUAL" ] && log "checksum ok"
else
  log "warning: no checksum sidecar found; skipping verification"
fi

unzip -qo "$ZIP" -d "$TMP" || die "unzip failed"
[ -f "$TMP/$APP" ] || die "archive did not contain '$APP'"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$TMP/$APP" "$INSTALL_DIR/$APP"
log "installed to $INSTALL_DIR/$APP"

# PATH hint / rc edit
case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *)
    if [ "$MODIFY_PATH" -eq 1 ]; then
      LINE="export PATH=\"$INSTALL_DIR:\$PATH\""
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        grep -qF "$LINE" "$rc" 2>/dev/null || printf '\n# kimi-code\n%s\n' "$LINE" >> "$rc"
      done
      log "added $INSTALL_DIR to PATH in your shell rc — restart your shell or: $LINE"
    else
      log "note: $INSTALL_DIR is not on PATH — add it: export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
    ;;
esac

log "done: $("$INSTALL_DIR/$APP" --version 2>/dev/null || echo "$LATEST_VERSION")"
