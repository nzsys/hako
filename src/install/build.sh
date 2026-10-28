#!/bin/sh
# 箱: ビルドと配置
#
# FreeBSD 上で実行する。やること:
#   1. Rust 部品を cargo build --release する（バイナリ名は
#      box-dispatcher / box-relay / box-grant / box-adapter）
#   2. バイナリを /usr/local/box/bin/ に配置する
#   3. スロットのルートになる slotbase（/var/jails/slotbase）を用意する:
#      base.txz の展開 + pkg で PHP と sockets を入れ、PHP 拡張（boxfd）を
#      slotbase の中で chroot ビルドして有効化する
#
# 前提: root で実行すること。pkg の rust / cargo が入っていること。
# 初回の cargo build は crates.io へのアクセスが要る
# （オフラインの構築機では事前に vendor しておく）。
# PHP の pkg 名は PHP_PKG で上書きできる（既定は php85 → php84 → php83）。
set -eu

[ "$(id -u)" = "0" ] || { echo "build.sh: root で実行してください" >&2; exit 1; }

SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN_DIR=/usr/local/box/bin
JAILS=/var/jails
SLOTBASE=$JAILS/slotbase


command -v cargo >/dev/null 2>&1 || {
    echo "build.sh: cargo が見つかりません（pkg install rust）" >&2; exit 1;
}

echo "== cargo build --release (in $SRC_DIR)"
(cd "$SRC_DIR" && cargo build --release)

install -d -m 0755 "$BIN_DIR"
for b in box-dispatcher box-relay box-grant box-adapter; do
    install -m 0755 "$SRC_DIR/target/release/$b" "$BIN_DIR/$b"
    echo "   installed $BIN_DIR/$b"
done


echo "== slotbase: $SLOTBASE"
install -d -m 0755 "$JAILS"
if [ ! -f "$JAILS/base.txz" ]; then
    rel=$(uname -r | sed 's/-p[0-9]*$//')
    arch=$(uname -m)
    fetch -o "$JAILS/base.txz" \
        "https://download.freebsd.org/releases/$arch/$arch/$rel/base.txz"
fi
if [ ! -x "$SLOTBASE/bin/sh" ]; then
    install -d -m 0755 "$SLOTBASE"
    tar -xJf "$JAILS/base.txz" -C "$SLOTBASE"
fi
# スロットの中で要る置き場所（app は stage0.sh が nullfs で上書きマウントする）
install -d -m 0755 "$SLOTBASE/app" "$SLOTBASE/work"

if [ ! -x "$SLOTBASE/usr/local/bin/php-cgi" ]; then
    echo "== slotbase: pkg install php (+sockets)"
    PHP_PKG_USED=""
    for cand in ${PHP_PKG:-} php85 php84 php83; do
        [ -n "$cand" ] || continue
        if pkg -r "$SLOTBASE" install -y "$cand" "$cand-sockets" 2>/dev/null; then
            PHP_PKG_USED=$cand
            break
        fi
    done
    [ -n "$PHP_PKG_USED" ] || {
        echo "build.sh: PHP の pkg を入れられませんでした。PHP_PKG=<pkg名> で指定してください" >&2
        exit 1
    }
    echo "   installed $PHP_PKG_USED (+ $PHP_PKG_USED-sockets)"
fi

# base の cc と slotbase の phpize を使う。ビルドの間だけ devfs を張る。

if [ ! -f "$SLOTBASE/usr/local/etc/php/20-boxfd.ini" ]; then
    echo "== php extension build (chroot in slotbase)"
    # phpize は autoconf を要するが base には無い。ビルドの間だけ入れ、
    # 終わったら消す（ルートにビルド道具を残さない）。
    pkg -r "$SLOTBASE" install -y autoconf >/dev/null || {
        echo "build.sh: autoconf を slotbase へ入れられませんでした" >&2
        exit 1
    }
    rm -rf "$SLOTBASE/root/php-ext"
    cp -a "$SRC_DIR/php-ext" "$SLOTBASE/root/php-ext"
    DEVFS_MOUNTED=""
    if mount | grep -qF "on $SLOTBASE/dev ("; then
        DEVFS_MOUNTED=1
    else
        mount -t devfs devfs "$SLOTBASE/dev"
    fi
    chroot "$SLOTBASE" /bin/sh -c \
        'cd /root/php-ext && phpize && ./configure && make' || {
        [ -n "$DEVFS_MOUNTED" ] || umount "$SLOTBASE/dev" || true
        echo "build.sh: 拡張のビルドに失敗しました" >&2
        exit 1
    }
    [ -n "$DEVFS_MOUNTED" ] || umount "$SLOTBASE/dev" || true

    SO=$(find "$SLOTBASE/root/php-ext/modules" -name '*.so' -type f | head -n 1)
    [ -n "$SO" ] || { echo "build.sh: .so が生成されませんでした" >&2; exit 1; }
    SO_NAME=$(basename "$SO")
    EXT_DIR=$(chroot "$SLOTBASE" php-config --extension-dir)
    install -m 0755 "$SO" "$SLOTBASE$EXT_DIR/$SO_NAME"
    printf 'extension=%s\n' "$SO_NAME" > "$SLOTBASE/usr/local/etc/php/20-boxfd.ini"
    echo "   installed slotbase$EXT_DIR/$SO_NAME"
    # 動作確認: slotbase の php-cgi が拡張を読めること
    chroot "$SLOTBASE" /usr/local/bin/php-cgi -m 2>/dev/null | grep -qi boxfd && \
        echo "   php-cgi -m: boxfd ok" || \
        echo "   [warn] php-cgi -m に boxfd が見えません（要確認）"
    # ビルド道具の後片付け
    pkg -r "$SLOTBASE" delete -y autoconf >/dev/null 2>&1 || true
    pkg -r "$SLOTBASE" autoremove -y >/dev/null 2>&1 || true
fi

echo "== done"
