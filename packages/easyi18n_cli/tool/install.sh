#!/bin/sh
# Installs the easyi18n CLI as a standalone binary: no Dart SDK needed.
#
#   curl -fsSL https://github.com/easyi18n-com/dart/releases/latest/download/install.sh | sh
#
# EASYI18N_VERSION      a release such as 1.0.0 (default: the latest one)
# EASYI18N_INSTALL_DIR  where `easyi18n` goes (default: ~/.local/bin)
#
# macOS (arm64, x64), Linux x64 and Windows x64 under Git Bash, where it
# installs `easyi18n.exe`. Elsewhere, or with Dart installed, use
# `dart pub global activate easyi18n_cli`.
set -eu

releases="${EASYI18N_RELEASES_URL:-https://github.com/easyi18n-com/dart/releases}"
dest="${EASYI18N_INSTALL_DIR:-$HOME/.local/bin}"

die() {
  echo "easyi18n install: $*" >&2
  exit 1
}

os="$(uname -s)"
arch="$(uname -m)"
# A shell running under Rosetta reports x86_64 on Apple silicon.
if [ "$os" = Darwin ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
  arch=arm64
fi
exe=easyi18n
case "$os/$arch" in
  Darwin/arm64) asset=easyi18n-macos-arm64 ;;
  Darwin/x86_64) asset=easyi18n-macos-x64 ;;
  Linux/x86_64) asset=easyi18n-linux-x64 ;;
  MINGW*/x86_64 | MSYS*/x86_64 | CYGWIN*/x86_64) asset=easyi18n-windows-x64.exe exe=easyi18n.exe ;;
  *) die "no prebuilt binary for $os $arch; install with \`dart pub global activate easyi18n_cli\`" ;;
esac

if [ -n "${EASYI18N_VERSION:-}" ]; then
  base="$releases/download/cli-v$EASYI18N_VERSION"
else
  base="$releases/latest/download"
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
else
  die "needs curl or wget"
fi
if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  die "needs sha256sum or shasum to verify the download"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch "$base/$asset" "$tmp/$exe" || die "download failed: $base/$asset"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS"

expected="$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || die "no checksum for $asset in SHA256SUMS"
actual="$(digest "$tmp/$exe")"
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset: expected $expected, got $actual"

chmod 755 "$tmp/$exe"
version="$("$tmp/$exe" --version)" || die "the downloaded $asset does not run on this machine"

mkdir -p "$dest"
mv -f "$tmp/$exe" "$dest/$exe"
echo "installed $version to $dest/$exe"
case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "add $dest to your PATH to run \`easyi18n\`" ;;
esac
