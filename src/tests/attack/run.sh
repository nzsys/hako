#!/bin/sh
# 攻撃試験（app-rce）の実行: 起動し、脆弱なアプリに差し替えて
# PoC と確認を回し、元のアプリに戻す。FreeBSD の root で実行する。
set -eu
[ "$(id -u)" = "0" ] || { echo "run.sh: root で実行してください" >&2; exit 1; }
SRC_DIR=$(cd "$(dirname "$0")/../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
APP_LIVE=/usr/local/box/app
INDEX_BAK=$(mktemp /tmp/box-index.XXXXXX)
cp "$APP_LIVE/public/index.php" "$INDEX_BAK"
restore() {
    cp "$INDEX_BAK" "$APP_LIVE/public/index.php"
    rm -f "$INDEX_BAK"
    echo "== アプリを元に戻しました"
}
trap restore EXIT INT TERM

echo "== 段階0 setup / start"
sh "$SRC_DIR/install/stage0.sh" setup
# setup がアプリを上書きするので、脆弱な index.php はこの後に差す
cp "$HERE/app-rce/app/public/index.php" "$APP_LIVE/public/index.php"
sh "$SRC_DIR/install/stage0.sh" start

echo "== PoC"
sh "$HERE/app-rce/poc.sh" || true

echo "== 封じ込めの確認"
sh "$HERE/app-rce/verify.sh"

echo "== 段階0 stop"
sh "$SRC_DIR/install/stage0.sh" stop
