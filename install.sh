#!/bin/sh
# Install boo from GitHub releases:
#
#   curl -fsSL https://raw.githubusercontent.com/coder/boo/main/install.sh | sh
#
# Environment variables:
#   BOO_VERSION      Release version to install, e.g. "0.1.0".
#                    Defaults to the latest release.
#   BOO_INSTALL_DIR  Where to put the binary. Defaults to
#                    /usr/local/bin when writable, otherwise
#                    ~/.local/bin.
set -eu

REPO="coder/boo"

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

asset="boo-$arch-$os.tar.gz"
version="${BOO_VERSION:-latest}"
if [ "$version" = "latest" ]; then
	url="https://github.com/$REPO/releases/latest/download/$asset"
else
	url="https://github.com/$REPO/releases/download/v${version#v}/$asset"
fi

if [ -n "${BOO_INSTALL_DIR:-}" ]; then
	install_dir="$BOO_INSTALL_DIR"
elif [ -w /usr/local/bin ]; then
	install_dir=/usr/local/bin
else
	install_dir="$HOME/.local/bin"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading $url"
download() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$tmp/$asset" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$tmp/$asset" "$url"
	else
		fail "curl or wget is required"
	fi
}
if ! download; then
	# Private and internal repositories reject anonymous downloads.
	# Retry through gh, which uses its own authentication.
	command -v gh >/dev/null 2>&1 ||
		fail "download failed; is the release published and the repository public?"
	log "Anonymous download failed; retrying with gh"
	rm -f "$tmp/$asset"
	if [ "$version" = "latest" ]; then
		gh release download --repo "$REPO" --pattern "$asset" --dir "$tmp" ||
			fail "gh release download failed"
	else
		gh release download "v${version#v}" --repo "$REPO" --pattern "$asset" --dir "$tmp" ||
			fail "gh release download failed"
	fi
fi

tar -xzf "$tmp/$asset" -C "$tmp"
mkdir -p "$install_dir"
install -m 0755 "$tmp/boo" "$install_dir/boo"

log "Installed $("$install_dir/boo" -V 2>&1) to $install_dir/boo"
case ":$PATH:" in
*":$install_dir:"*) ;;
*)
	# Reference the directory via $HOME where possible so the
	# suggested rc line survives a home directory move.
	dir_ref=$install_dir
	case "$install_dir" in
	"$HOME"/*) dir_ref="\$HOME${install_dir#"$HOME"}" ;;
	esac
	log ""
	log "warning: $install_dir is not in your PATH"
	case "$(basename "${SHELL:-sh}")" in
	zsh)
		log "To add it, run:"
		log "  echo 'export PATH=\"$dir_ref:\$PATH\"' >> ~/.zshrc"
		log "then restart your shell."
		;;
	bash)
		log "To add it, run:"
		log "  echo 'export PATH=\"$dir_ref:\$PATH\"' >> ~/.bashrc"
		log "then restart your shell."
		;;
	fish)
		log "To add it, run:"
		log "  fish_add_path \"$install_dir\""
		;;
	*)
		log "Add it to your shell's PATH to run boo by name."
		;;
	esac
	log ""
	log "For a system-wide install instead, rerun with:"
	log "  curl -fsSL https://raw.githubusercontent.com/coder/boo/main/install.sh | sudo BOO_INSTALL_DIR=/usr/local/bin sh"
	;;
esac
