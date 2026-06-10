#!/bin/sh
# Install ghostscreen from GitHub releases:
#
#   curl -fsSL https://raw.githubusercontent.com/coder/ghostscreen/main/install.sh | sh
#
# Environment variables:
#   GHOSTSCREEN_VERSION      Release version to install, e.g. "0.0.1".
#                            Defaults to the latest release.
#   GHOSTSCREEN_INSTALL_DIR  Where to put the binary. Defaults to
#                            /usr/local/bin when writable, otherwise
#                            ~/.local/bin.
set -eu

REPO="coder/ghostscreen"

log() { printf '%s\n' "$*" >&2; }
fail() {
	log "error: $*"
	exit 1
}

os=$(uname -s)
case "$os" in
Linux) os=linux ;;
Darwin) os=macos ;;
*) fail "unsupported operating system: $os" ;;
esac

arch=$(uname -m)
case "$arch" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) fail "unsupported architecture: $arch" ;;
esac

asset="ghostscreen-$arch-$os.tar.gz"
version="${GHOSTSCREEN_VERSION:-latest}"
if [ "$version" = "latest" ]; then
	url="https://github.com/$REPO/releases/latest/download/$asset"
else
	url="https://github.com/$REPO/releases/download/v${version#v}/$asset"
fi

if [ -n "${GHOSTSCREEN_INSTALL_DIR:-}" ]; then
	install_dir="$GHOSTSCREEN_INSTALL_DIR"
elif [ -w /usr/local/bin ]; then
	install_dir=/usr/local/bin
else
	install_dir="$HOME/.local/bin"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading $url"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL -o "$tmp/$asset" "$url" ||
		fail "download failed; is the release published and the repository public?"
elif command -v wget >/dev/null 2>&1; then
	wget -qO "$tmp/$asset" "$url" ||
		fail "download failed; is the release published and the repository public?"
else
	fail "curl or wget is required"
fi

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$install_dir"
install -m 0755 "$tmp/ghostscreen" "$install_dir/ghostscreen"

log "Installed $("$install_dir/ghostscreen" -V) to $install_dir/ghostscreen"
case ":$PATH:" in
*":$install_dir:"*) ;;
*) log "warning: $install_dir is not in your PATH" ;;
esac
