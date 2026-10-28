#!/bin/sh
# 箱: 構築・起動・停止
#
#   stage0.sh setup   グループ/ユーザー、jail ルート、ソケット用
#                     nullfs マウント、アプリ配置、jail.conf の配置までを行う
#                     （冪等に寄せてある）
#   stage0.sh start   ap / relay jail を作り、4部品を起動する
#   stage0.sh stop    逆順に止め、jail を消し、マウントを外す
#
# 先に install/build.sh でバイナリを /usr/local/box/bin/ に置くこと。
# root 必須。
#
#
# grant はホストで uid auth(2003)、adapter は uid edge(2001) で起動する。
# 中継が LOCAL_PEERCRED で接続元を確かめる（--peer-uid 2003）ため、
# ホスト上でも uid を合わせてある。
set -eu

[ "$(id -u)" = "0" ] || { echo "stage0.sh: root で実行してください" >&2; exit 1; }

SRC_DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN_DIR=/usr/local/box/bin
APP_DIR=/usr/local/box/app
JAILS=/var/jails
JAILCONF=/etc/jail.conf.d/box.conf
SOCK_HOST=$JAILS/sock
RUN_BOX=/var/run/box
SLOTS=4


# ツリーをハードリンクを保ったままコピーする: copy_tree <src> <dst>
# cp -a は /rescue のハードリンクを全部実体化してしまい、base の
# コピーが約4倍（+2.8GB）に膨れる（FreeBSD 15.1 で実測）。tar の
# 往復ならリンクが保たれる
copy_tree() {
    install -d -m 0755 "$2"
    tar -cf - -C "$1" . | tar -xpf - -C "$2"
}

# nullfs マウントが無ければ張る: ensure_mount <src> <dst> [opts]
ensure_mount() {
    if mount | grep -qF "on $3 ("; then
        return 0
    fi
    if [ -n "${2:-}" ]; then
        mount -t nullfs -o "$2" "$1" "$3"
    else
        mount -t nullfs "$1" "$3"
    fi
}

# マウントがあれば外す: drop_mount <dst>
drop_mount() {
    if mount | grep -qF "on $1 ("; then
        umount "$1" || umount -f "$1"
    fi
}

# グループが無ければ作る: ensure_group <gid> <name>
ensure_group() {
    pw groupshow -n "$2" >/dev/null 2>&1 || pw groupadd -n "$2" -g "$1"
}

# ユーザーが無ければ作る: ensure_user <uid> <name> [secondary groups csv]
ensure_user() {
    if pw usershow -n "$2" >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "${3:-}" ]; then
        pw useradd -n "$2" -u "$1" -g nogroup -G "$3" \
            -d /nonexistent -s /usr/sbin/nologin -c "box $2"
    else
        pw useradd -n "$2" -u "$1" -g nogroup \
            -d /nonexistent -s /usr/sbin/nologin -c "box $2"
    fi
}


setup() {
    echo "== groups / users (spec/topology.md)"
    # ソケットへの接続権限グループ
    ensure_group 2101 c_disp
    ensure_group 2102 c_gwfd
    ensure_group 2103 c_gw
    ensure_group 2104 c_auth
    ensure_group 2105 c_relay
    ensure_group 2106 c_db
    ensure_group 2107 c_egress

    ensure_user 2001 edge  c_disp,c_gw,c_auth
    ensure_user 2002 gw
    ensure_user 2003 auth  c_relay,c_db
    ensure_user 2004 relay c_db
    ensure_user 2005 send  c_db,c_egress
    ensure_user 2006 egress
    ensure_user 2007 acme  c_egress
    ensure_user 2008 admin c_db
    k=1
    while [ $k -le $SLOTS ]; do
        ensure_user $((3000 + k)) "slot$k"
        k=$((k + 1))
    done

    echo "== base.txz -> $JAILS/base"
    install -d -m 0755 "$JAILS"
    if [ ! -f "$JAILS/base.txz" ]; then
        rel=$(uname -r | sed 's/-p[0-9]*$//')
        arch=$(uname -m)
        fetch -o "$JAILS/base.txz" \
            "https://download.freebsd.org/releases/$arch/$arch/$rel/base.txz"
    fi
    if [ ! -x "$JAILS/base/bin/sh" ]; then
        install -d -m 0755 "$JAILS/base"
        tar -xJf "$JAILS/base.txz" -C "$JAILS/base"
    fi

    echo "== jail roots: ap, relay (base のコピー。段階0の簡略化)"
    for j in ap relay; do
        if [ ! -x "$JAILS/$j/bin/sh" ]; then
            copy_tree "$JAILS/base" "$JAILS/$j"
        fi
        # jail 内のユーザー DB をホストに合わせる（jexec -u 用）
        cp /etc/master.passwd /etc/passwd /etc/group "$JAILS/$j/etc/"
        pwd_mkdb -d "$JAILS/$j/etc" "$JAILS/$j/etc/master.passwd"
    done

    echo "== 部品バイナリを jail ルートへ配置"
    # バイナリは jail 内のパスで exec されるので、各 jail ルート配下にも置く
    [ -x "$BIN_DIR/box-dispatcher" ] && [ -x "$BIN_DIR/box-relay" ] || {
        echo "stage0.sh: 部品バイナリが未構築です。先に install/build.sh を実行してください" >&2
        exit 1
    }
    install -d -m 0755 "$JAILS/ap$BIN_DIR" "$JAILS/relay$BIN_DIR"
    install -m 0755 "$BIN_DIR/box-dispatcher" "$JAILS/ap$BIN_DIR/box-dispatcher"
    install -m 0755 "$BIN_DIR/box-relay" "$JAILS/relay$BIN_DIR/box-relay"

    echo "== スロットのルート（slotbase のコピー）"
    [ -x "$JAILS/slotbase/usr/local/bin/php-cgi" ] || {
        echo "stage0.sh: slotbase が未構築です。先に install/build.sh を実行してください" >&2
        exit 1
    }
    install -d -m 0755 "$JAILS/ap/slots"
    k=1
    while [ $k -le $SLOTS ]; do
        if [ ! -x "$JAILS/ap/slots/$k/usr/local/bin/php-cgi" ]; then
            rm -rf "$JAILS/ap/slots/$k"
            copy_tree "$JAILS/slotbase" "$JAILS/ap/slots/$k"
        fi
        k=$((k + 1))
    done

    echo "== jail 内ディレクトリ"
    install -d -m 0755 "$JAILS/ap/run/sock/disp"
    install -d -o root -g wheel -m 0700 "$JAILS/ap/run/slots"
    # relay: ソケットの置き場所
    install -d -m 0755 "$JAILS/relay/run/sock/relay"

    echo "== ホストのソケット用ディレクトリ (所有者=待ち受け側, 0750)"
    # disp: 待ち受けは振り分け (ap jail 内 root)。接続用グループ c_disp
    install -d -o root  -g c_disp  -m 0750 "$SOCK_HOST/disp"
    # auth: 待ち受けはホスト上の grant (uid auth)。マウントはしない
    install -d -o auth  -g c_auth  -m 0750 "$SOCK_HOST/auth"
    # relay: 待ち受けは中継 (uid relay)。接続用グループ c_relay
    install -d -o relay -g c_relay -m 0750 "$SOCK_HOST/relay"

    echo "== nullfs mounts (ソケット共有)"
    # 待ち受け側へのマウントは書き込み可（ソケットファイルを作るため）
    ensure_mount "$SOCK_HOST/disp"  "" "$JAILS/ap/run/sock/disp"
    ensure_mount "$SOCK_HOST/relay" "" "$JAILS/relay/run/sock/relay"

    echo "== アプリの配置とスロットへのマウント"
    install -d -m 0755 "$APP_DIR"
    if [ -d "$SRC_DIR/app" ]; then
        cp -a "$SRC_DIR/app/" "$APP_DIR/"
    fi
    # スロットの uid が読めないと php がスクリプトを開けない（EACCES で
    # "No input file specified" になる。実測）。
    chmod -R a+rX "$APP_DIR"
    k=1
    while [ $k -le $SLOTS ]; do
        ensure_mount "$APP_DIR" "ro,nosuid,noexec" "$JAILS/ap/slots/$k/app"
        k=$((k + 1))
    done

    echo "== jail.conf"
    install -d -m 0755 /etc/jail.conf.d
    install -m 0644 "$SRC_DIR/conf/jail.conf.stage0" "$JAILCONF"

    echo "== setup done"
}


# ソケットファイルの出現を少し待つ: wait_sock <path>
wait_sock() {
    i=0
    while [ ! -S "$1" ] && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -S "$1" ] || { echo "stage0.sh: $1 が現れませんでした" >&2; return 1; }
}

start() {
    install -d -m 0755 "$RUN_BOX"

    # stop でマウントは全部外れるので、start でも張り直す（ensure_mount は冪等）
    echo "== nullfs mounts (ソケット共有・アプリ)"
    ensure_mount "$SOCK_HOST/disp"  "" "$JAILS/ap/run/sock/disp"
    ensure_mount "$SOCK_HOST/relay" "" "$JAILS/relay/run/sock/relay"
    k=1
    while [ $k -le $SLOTS ]; do
        ensure_mount "$APP_DIR" "ro,nosuid,noexec" "$JAILS/ap/slots/$k/app"
        k=$((k + 1))
    done

    # jail(8) の -c に複数の名前を渡すと unknown parameter になる（実測）。
    # 1つずつ作る
    for j in ap relay; do
        if ! jls -j "$j" >/dev/null 2>&1; then
            echo "== jail -c $j"
            jail -f "$JAILCONF" -c "$j"
        fi
    done

    echo "== box-relay (relay jail, uid relay)"
    # daemon(8) が切り離しと pidfile を担い、jexec が jail 内で実行する
    # （jexec は exec するので pid はそのまま中継プロセスのものになる）
    daemon -f -p "$RUN_BOX/relay.pid" \
        jexec -u relay relay "$BIN_DIR/box-relay" \
            --sock /run/sock/relay/relay.sock --peer-uid 2003
    wait_sock "$SOCK_HOST/relay/relay.sock"

    echo "== box-dispatcher (ap jail, root)"
    daemon -f -p "$RUN_BOX/dispatcher.pid" \
        jexec ap "$BIN_DIR/box-dispatcher" \
            --sock /run/sock/disp/disp.sock
    wait_sock "$SOCK_HOST/disp/disp.sock"

    echo "== box-grant (ホスト上, uid auth)"
    daemon -f -p "$RUN_BOX/grant.pid" -u auth \
        "$BIN_DIR/box-grant" \
            --sock "$SOCK_HOST/auth/auth.sock" \
            --relay-sock "$SOCK_HOST/relay/relay.sock" \
            --session stage0-demo-session \
            --user 11111111-1111-4111-8111-111111111111
    wait_sock "$SOCK_HOST/auth/auth.sock"

    echo "== box-adapter (ホスト上, uid edge, 127.0.0.1:8080)"
    daemon -f -p "$RUN_BOX/adapter.pid" -u edge \
        "$BIN_DIR/box-adapter" \
            --listen 127.0.0.1:8080 \
            --disp-sock "$SOCK_HOST/disp/disp.sock" \
            --auth-sock "$SOCK_HOST/auth/auth.sock"

    echo "== start done"
    echo "   GET http://127.0.0.1:8080/memos/22222222-2222-4222-8222-222222222222"
    echo "   Cookie: box_session=stage0-demo-session / Sec-Fetch-User: ?1"
}


# pidfile のプロセスを止める: stop_one <name>
stop_one() {
    pf="$RUN_BOX/$1.pid"
    [ -f "$pf" ] || return 0
    pid=$(cat "$pf")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
}

stop() {
    echo "== stop (逆順)"
    stop_one adapter
    stop_one grant
    stop_one dispatcher
    stop_one relay

    # 子 jail（スロット）が残っていると ap は消せない。残っていたら片付け漏れ
    # なので、jail -r の失敗として表面化させる
    for j in ap relay; do
        if jls -j "$j" >/dev/null 2>&1; then
            jail -f "$JAILCONF" -r "$j"
        fi
    done

    k=1
    while [ $k -le $SLOTS ]; do
        drop_mount "$JAILS/ap/slots/$k/app"
        k=$((k + 1))
    done
    drop_mount "$JAILS/ap/run/sock/disp"
    drop_mount "$JAILS/relay/run/sock/relay"

    echo "== stop done"
}

case "${1:-}" in
    setup) setup ;;
    start) start ;;
    stop)  stop ;;
    *) echo "usage: $0 setup|start|stop" >&2; exit 64 ;;
esac
