#!/bin/sh
# 中継と grant のプロトコル試験（jail 不要。Linux でも動く）。
# 使い方: src/ で `sh tests/proto-test.sh`
set -eu
cd "$(dirname "$0")/.."
# rustup で入れた場合は PATH に足す
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
cargo build --bins >/dev/null
DIR=$(mktemp -d /tmp/box-proto-test.XXXXXX)
trap 'kill $RELAY_PID $GRANT_PID 2>/dev/null || true; rm -rf "$DIR"' EXIT
UID_NOW=$(id -u)
./target/debug/box-relay --sock "$DIR/relay.sock" --peer-uid "$UID_NOW" &
RELAY_PID=$!
./target/debug/box-grant --sock "$DIR/auth.sock" --relay-sock "$DIR/relay.sock" &
GRANT_PID=$!
sleep 1
BOX_TEST_DIR="$DIR" python3 tests/proto_test.py
