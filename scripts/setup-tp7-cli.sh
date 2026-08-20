#!/bin/zsh
# Builds the tp7 CLI (github.com/totocaster/tp7) with our audio-mode PID patch
# and installs it to /opt/homebrew/bin. Requires a Rust toolchain (brew install rust).
set -euo pipefail

UPSTREAM=https://github.com/totocaster/tp7
PINNED_COMMIT=d01a28284d9bd832abe0ae09071d6a14518132de
PATCH="$(cd "$(dirname "$0")/.." && pwd)/vendor/tp7-audio-mode-pid.patch"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

git clone "$UPSTREAM" "$workdir/tp7"
cd "$workdir/tp7"
git checkout "$PINNED_COMMIT"
git apply "$PATCH"
cargo build --release
install -m 755 target/release/tp7 /opt/homebrew/bin/tp7
echo "Installed $(tp7 --version) to /opt/homebrew/bin/tp7"
