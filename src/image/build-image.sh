#!/bin/sh
# 箱: 検証用 VM イメージの自動生成
#
# 公式の FreeBSD VM イメージ（UFS / qcow2）を土台に、箱一式を
# 仕込んだ起動可能イメージを作る。生成されたイメージは起動すると
# rc.d/box が自動で立ち上げ、http://127.0.0.1:8080/ で
# 試せる状態になる（ログイン: box / box、検証専用）。
#
# 実行環境: FreeBSD の実機または VM の root で実行すること。
#   生成ホストのリリースとイメージのリリースを一致させること
#   （chroot の中で uname がホストのカーネルを返すため。既定は
#   15.1-RELEASE で、ホストが 15.1-RELEASE-p* なら一致とみなす）。
# 必要なもの: qemu-img（pkg install qemu）、ネットワーク
#   （公式イメージと pkg と crates.io へ届くこと）。
#
# 使い方:
#   sh image/build-image.sh [--out DIR] [--work DIR] [--release 15.1-RELEASE]
#
# 生成物（--out の先、既定は ./image-out）:
#   box-15.1-RELEASE-amd64.qcow2   QEMU 用
#   box-15.1-RELEASE-amd64.vmdk    VirtualBox 用
#   SHA256SUMS
set -eu

[ "$(id -u)" = "0" ] || { echo "build-image.sh: root で実行してください" >&2; exit 1; }
[ "$(uname -s)" = "FreeBSD" ] || { echo "build-image.sh: FreeBSD 上で実行してください" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || {
    echo "build-image.sh: qemu-img がありません（pkg install qemu）" >&2; exit 1;
}

REL=15.1-RELEASE
OUT_DIR=image-out
WORK_DIR=""
QCOW2_ONLY=""
# 公式イメージのルートは約5GBしかなく、一式（jail ツリー約7GB）
# とビルド中の道具（rust 等）が入らない。ディスク自体を広げて GPT と
# UFS を追随させる（下の展開手順）。環境変数 IMG_GROW で変更可。
IMG_GROW=${IMG_GROW:-+14G}
while [ $# -gt 0 ]; do
    case "$1" in
        --release) REL=$2; shift 2 ;;
        --out) OUT_DIR=$2; shift 2 ;;
        --work) WORK_DIR=$2; shift 2 ;;
        --qcow2-only) QCOW2_ONLY=1; shift ;;
        *) echo "usage: $0 [--release REL] [--out DIR] [--work DIR] [--qcow2-only]" >&2; exit 64 ;;
    esac
done
ARCH=$(uname -m)
HOST_REL=$(uname -r | sed 's/-p[0-9]*$//')
[ "$HOST_REL" = "$REL" ] || {
    echo "build-image.sh: 生成ホスト ($HOST_REL) とイメージ ($REL) のリリースが一致しません" >&2
    exit 1
}
[ -n "$WORK_DIR" ] || WORK_DIR=$(mktemp -d /tmp/box-image.XXXXXX)
SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMG_NAME="FreeBSD-$REL-$ARCH-ufs.qcow2"
BASE_URL="https://download.freebsd.org/releases/VM-IMAGES/$REL/$ARCH/Latest"
MNT=$WORK_DIR/mnt
MD=""
DEVFS_ON=""

# $MNT とその配下のマウントを深い順に全部外す。setup（chroot）が
# 内側に作る nullfs マウントが残ると $MNT 本体を外せないため、
# 片付けは必ずこちらを使うこと
umount_tree() {
    mount | sed -n "s|.* on \($MNT[^ ]*\) .*|\1|p" | sort -r | \
        while read -r mp; do
            umount "$mp" 2>/dev/null || umount -f "$mp" 2>/dev/null || true
        done
}

cleanup() {
    # 退避した pkg リポジトリ上書きを戻す（マウント中なら最優先で）
    if [ -f "$MNT/usr/local/etc/pkg/repos/FreeBSD.conf.boxoff" ]; then
        mv "$MNT/usr/local/etc/pkg/repos/FreeBSD.conf.boxoff" \
           "$MNT/usr/local/etc/pkg/repos/FreeBSD.conf" 2>/dev/null || true
    fi
    umount_tree
    [ -n "$MD" ] && mdconfig -d -u "$MD" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR" "$MNT" "$OUT_DIR"
echo "== 作業領域の容量"
df -h "$WORK_DIR" || true

echo "== 公式イメージの取得と検証: $IMG_NAME.xz"
cd "$WORK_DIR"
[ -f "$IMG_NAME.xz" ] || fetch -o "$IMG_NAME.xz" "$BASE_URL/$IMG_NAME.xz"
[ -f CHECKSUM.SHA256 ] || fetch -o CHECKSUM.SHA256 "$BASE_URL/CHECKSUM.SHA256"
WANT=$(grep -F "($IMG_NAME.xz)" CHECKSUM.SHA256 | sed 's/.*= //')
GOT=$(sha256 -q "$IMG_NAME.xz")
[ "$WANT" = "$GOT" ] || { echo "build-image.sh: チェックサム不一致" >&2; exit 1; }
echo "   sha256 ok"

echo "== raw へ変換してマウント"
xz -dkf "$IMG_NAME.xz"
qemu-img convert -O raw "$IMG_NAME" disk.raw
# 容量節約: 変換が済んだ元ファイルは早めに消す
rm -f "$IMG_NAME.xz" "$IMG_NAME" 
echo "== イメージのディスクを拡張 ($IMG_GROW)"
qemu-img resize -f raw disk.raw "$IMG_GROW"
MD=$(mdconfig -a -t vnode -f disk.raw)
ROOT_PART=""
for p in /dev/"$MD"p*; do
    if [ "$(fstyp "$p" 2>/dev/null || true)" = "ufs" ]; then
        ROOT_PART=$p
        break
    fi
done
[ -n "$ROOT_PART" ] || { echo "build-image.sh: UFS のルートが見つかりません" >&2; exit 1; }
# GPT の予備表を新しい末尾へ移し、UFS パーティションとファイル
# システムを空き領域いっぱいに広げる。イメージ側の growfs_enable は
# 初回起動時用で、オフラインで仕込むこの段階には間に合わない。
ROOT_IDX=${ROOT_PART##*p}
gpart recover "$MD" >/dev/null
gpart resize -i "$ROOT_IDX" "$MD" >/dev/null
growfs -y "$ROOT_PART" >/dev/null
mount "$ROOT_PART" "$MNT"
echo "   root: $ROOT_PART -> $MNT"

# イメージ側の /usr/local/etc/pkg/repos/FreeBSD.conf は FreeBSD-base を
# 有効化する1行ファイルで、pkg -r のたびに base リポジトリの更新が走る。
# base は使わないうえ、ミラー側の都合で更新が失敗するとビルド全体が
# 止まるため、ビルド中だけ退避し、終わりに cleanup で戻す。
OVERRIDE="$MNT/usr/local/etc/pkg/repos/FreeBSD.conf"
if [ -f "$OVERRIDE" ]; then
    mv "$OVERRIDE" "$OVERRIDE.boxoff"
    echo "   pkg repos override (FreeBSD-base) を退避"
fi

echo "== 箱のソースをイメージへ配置"
rm -rf "$MNT/usr/local/box/src"
install -d -m 0755 "$MNT/usr/local/box"
cp -a "$SRC_DIR" "$MNT/usr/local/box/src"
rm -rf "$MNT/usr/local/box/src/target"
# pkg / cargo の名前解決（DHCP が入る実環境では実行時に上書きされる）
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
mount -t devfs devfs "$MNT/dev"
DEVFS_ON=1

echo "== rust をイメージへ（ビルド用。後で消す）"
pkg -r "$MNT" install -y rust
# chroot 内では起動時の ldconfig が走っていないため、pkg で入れた
# /usr/local/lib の共有ライブラリがヒントキャッシュに無く、cargo が
# libcurl の依存（libnghttp2 等）を見つけられず起動できない。先に回す。
chroot "$MNT" /etc/rc.d/ldconfig onestart

echo "== chroot: install/build.sh（部品のビルドと slotbase）"
chroot "$MNT" /bin/sh -c 'cd /usr/local/box/src && sh install/build.sh'

echo "== chroot: install/stage0.sh setup（ユーザー、jail ルート、jail.conf）"
chroot "$MNT" /bin/sh -c 'sh /usr/local/box/src/install/stage0.sh setup'

echo "== 起動時の自動立ち上げ（rc.d/box）と検証用ログイン"
install -d "$MNT/usr/local/etc/rc.d"
install -m 0555 "$SRC_DIR/image/box.rc" "$MNT/usr/local/etc/rc.d/box"
for kv in 'box_enable="YES"' 'sshd_enable="YES"' 'ifconfig_DEFAULT="SYNCDHCP"' 'growfs_enable="YES"'; do
    key=${kv%%=*}
    grep -q "^$key=" "$MNT/etc/rc.conf" 2>/dev/null || echo "$kv" >> "$MNT/etc/rc.conf"
done
if ! chroot "$MNT" pw usershow -n box >/dev/null 2>&1; then
    chroot "$MNT" pw useradd -n box -c "box demo" -m -G wheel -s /bin/sh
    echo box | chroot "$MNT" pw usermod box -h 0
fi

echo "== 後片付け（ツールチェーンとキャッシュを消す）"
chroot "$MNT" pkg delete -y rust >/dev/null 2>&1 || true
chroot "$MNT" pkg autoremove -y >/dev/null 2>&1 || true
chroot "$MNT" pkg clean -y -a >/dev/null 2>&1 || true
rm -rf "$MNT/root/.cargo" "$MNT/usr/local/box/src/target"
rm -f "$MNT/etc/resolv.conf"

echo "== イメージへ戻す（qcow2 / vmdk）"
umount_tree; DEVFS_ON=""
mdconfig -d -u "$MD"; MD=""
OUT_BASE="box-$REL-$ARCH"
qemu-img convert -c -O qcow2 disk.raw "$OUT_DIR/$OUT_BASE.qcow2"
if [ -n "$QCOW2_ONLY" ]; then
    rm -f disk.raw
    (cd "$OUT_DIR" && sha256 "$OUT_BASE.qcow2" > SHA256SUMS)
    echo "== done: $OUT_DIR/$OUT_BASE.qcow2"
else
    # raw はここで消す。拡張後の raw（約21GB）と qcow2 と vmdk を
    # 同時に抱えると生成ホストのディスクが溢れる（30GB では不足
    # する）ため、vmdk は出来上がった qcow2 から変換する
    rm -f disk.raw
    qemu-img convert -O vmdk "$OUT_DIR/$OUT_BASE.qcow2" "$OUT_DIR/$OUT_BASE.vmdk"
    (cd "$OUT_DIR" && sha256 "$OUT_BASE.qcow2" "$OUT_BASE.vmdk" > SHA256SUMS)
    echo "== done: $OUT_DIR/$OUT_BASE.qcow2 / .vmdk"
fi
