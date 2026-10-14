#!/bin/zsh
# Fetch the official llama.cpp server for shipping inside Moku.app: the brain runs it on this Mac, only while
# Jev or Luna is failing, to judge screens and write lines with the local model (brain-go/internal/brain/local.go).
# Downloads llama-b11255-bin-macos-arm64.tar.gz (about 12 MB) from github.com/ggml-org/llama.cpp and
# verifies its SHA-256. The model itself (about 2.1 GB) is not bundled: the brain downloads it on first run.
set -euo pipefail
root=${0:A:h:h}
build=b11255
name="llama-$build-bin-macos-arm64"
sha256=108c641ea8a279e046faddc6f38b7b24736f83f70a3e33c71eafc8d7bebeb777
work=$(mktemp -d)
curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/$build/$name.tar.gz" -o "$work/$name.tar.gz"
echo "$sha256  $work/$name.tar.gz" | shasum -a 256 -c -
tar -xzf "$work/$name.tar.gz" -C "$work"
server=$(find "$work" -type f -name llama-server | head -1)
[[ -n "$server" ]] || { echo "llama-server not found in $name.tar.gz"; exit 1; }
rm -rf "$root/build/llama-runtime" && mkdir -p "$root/build/llama-runtime"
# The server and the libraries next to it (libllama, libggml*), nothing else.
cp "$server" "$root/build/llama-runtime/"
find "${server:h}" -maxdepth 1 -name '*.dylib' -exec cp -P {} "$root/build/llama-runtime/" \;
rm -rf "$work"
echo "llama.cpp server ready: $("$root/build/llama-runtime/llama-server" --version 2>&1 | head -1)"
