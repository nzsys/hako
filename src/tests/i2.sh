#!/bin/sh
# 箱: dispatcher のテストハーネス
#
# 前提:
# * FreeBSD の実機であること。このハーネスは Linux では意味を持たない
# * install/build.sh と install/stage0.sh setup / start が済んでいて、
#   スロットの子 jail が動いていること
# * スロットの子 jail 名は環境変数で渡す:
#     SLOT_JAIL_A   試験に使うスロット（例: ap.slot1）
#     SLOT_JAIL_B   「同時に動いている別のスロット」の確認用（任意）
#   未指定のケースは SKIP と表示する
#
# 自動化の範囲（正直な線引き）:
# * 自動化できているのは「jexec でスロットの子 jail にペイロードを
#   入れて、その場で結果を見る」ケースだけ
# * 「片付けの後」を確かめるケースは、片付けの契機がフローに無いため
#   TODO と明記し、手順だけを書いてある。TODO のケースは数に数えるが
#   PASS にはしない
# * 振り分けの入力ケースは python3 があれば実ソケットで試す
#
# 終了コード: FAIL が1つでもあれば 1、無ければ 0（TODO/SKIP では落とさない）

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD_SRC="$HERE/payloads"
PAYLOAD_BIN="$HERE/payloads/build"
SLOT_JAIL_A=${SLOT_JAIL_A:-}
SLOT_JAIL_B=${SLOT_JAIL_B:-}
DISP_SOCK=${DISP_SOCK:-/var/jails/sock/disp/disp.sock}
DISP_PIDFILE=${DISP_PIDFILE:-/var/run/box/dispatcher.pid}

pass=0; fail=0; todo=0; skip=0
ok()   { pass=$((pass + 1)); echo "PASS: $1"; }
ng()   { fail=$((fail + 1)); echo "FAIL: $1"; }
td()   { todo=$((todo + 1)); echo "TODO: $1 -- $2"; }
sk()   { skip=$((skip + 1)); echo "SKIP: $1 -- $2"; }

# --- ペイロードのビルド ---------------------------------------------------------
build_payloads() {
    command -v cc >/dev/null 2>&1 || { echo "cc がありません" >&2; exit 1; }
    mkdir -p "$PAYLOAD_BIN"
    for p in shm_create fork_storm sock_inet; do
        if [ ! -x "$PAYLOAD_BIN/$p" ]; then
            cc -O2 -Wall -o "$PAYLOAD_BIN/$p" "$PAYLOAD_SRC/$p.c"
        fi
    done
}

# スロット jail の中でコマンドを動かす
in_slot() {
    jail_name=$1; shift
    jexec "$jail_name" "$@"
}

# ペイロードをスロットに持ち込む（jail のルートへ置く。/tmp は子 jail の
# ルート配下なのでホストから見える）
stage_payload() {
    jail_name=$1; payload=$2
    root=$(jls -j "$jail_name" path)
    cp "$PAYLOAD_BIN/$payload" "$root/tmp/$payload"
    echo "/tmp/$payload"
}

build_payloads

# スロットから socket(AF_INET) / socket(AF_INET6) -> 失敗する
if [ -n "$SLOT_JAIL_A" ]; then
    p=$(stage_payload "$SLOT_JAIL_A" sock_inet)
    if in_slot "$SLOT_JAIL_A" "$p" >/dev/null 2>&1; then
        ok "I1 sock_inet: スロットに INET ソケットが無い"
    else
        ng "I1 sock_inet: スロットで INET ソケットが作れた"
    fi
else
    sk "I1 sock_inet" "SLOT_JAIL_A が未指定"
fi

# POSIX 共有メモリ
#   - スロットで作れる（前提の確認）
#   - 同時に動いている別スロットからは開けない
#   - 次の世代から見えない …… TODO（手順のみ）
SHM_NAME=/box_stage0_i2
if [ -n "$SLOT_JAIL_A" ]; then
    p=$(stage_payload "$SLOT_JAIL_A" shm_create)
    if in_slot "$SLOT_JAIL_A" "$p" "$SHM_NAME" >/dev/null 2>&1; then
        ok "I2 shm: スロットで POSIX 共有メモリを作れる"
    else
        ng "I2 shm: スロットで POSIX 共有メモリを作れなかった"
    fi

    if [ -n "$SLOT_JAIL_B" ]; then
        q=$(stage_payload "$SLOT_JAIL_B" shm_create)
        if in_slot "$SLOT_JAIL_B" "$q" --open-only "$SHM_NAME" >/dev/null 2>&1; then
            ng "I2 shm: 別スロットから共有メモリを開けた"
        else
            ok "I2 shm: 別スロットからは開けない"
        fi
    else
        sk "I2 shm (別スロット)" "SLOT_JAIL_B が未指定"
    fi
else
    sk "I2 shm" "SLOT_JAIL_A が未指定"
fi
td "I2 shm 世代またぎ" "次の世代から見えないことの確認は、振り分けの世代交代（段階1以降）で自動化する"
td "I2 shm 片付け中の競合" "多数のスレッドが shm_open(O_CREAT) を繰り返す最中の片付けは、負荷ペイロードと片付け契機が揃ってから"

# fork・setsid・二重 fork したプロセスが片付けの後に残らない
#   「孫が残る」ところまでを自動化し、片付け側は TODO
if [ -n "$SLOT_JAIL_A" ]; then
    p=$(stage_payload "$SLOT_JAIL_A" fork_storm)
    out=$(in_slot "$SLOT_JAIL_A" "$p" 2>/dev/null)
    gpid=$(echo "$out" | sed -n 's/^grandchild=//p')
    if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then
        ok "I2 fork: 二重 fork + setsid の孫が残る（片付け前の前提）"
        echo "     grandchild pid=$gpid"
        echo "     -> 振り分けにこの世代を片付けさせた後、次で残っていないこと:"
        echo "        kill -0 $gpid  が失敗する / ps で jail 名に属するプロセスが無い"
    else
        ng "I2 fork: 孫プロセスが残らなかった（前提が崩れている）"
    fi
else
    sk "I2 fork" "SLOT_JAIL_A が未指定"
fi
td "I2 fork 片付け後" "片付けの後に孫が1つも残らないこと。契機は段階1のフローで"

# スロット J から /slots/K・/run/slots/K.sock・受け取り口に到達できない
if [ -n "$SLOT_JAIL_A" ]; then
    # 子 jail のルートは /slots/<K> 自身なので、兄弟のパス自体が見えないはず
    if in_slot "$SLOT_JAIL_A" sh -c 'test ! -e /slots && test ! -e /run/slots'; then
        ok "I2 到達性: スロット内に兄弟スロットや /run/slots が見えない"
    else
        ng "I2 到達性: スロット内に /slots か /run/slots が見える"
    fi
else
    sk "I2 到達性" "SLOT_JAIL_A が未指定"
fi

# uchg を付けたファイルを残しても片付け（アンマウント）が成功する
if [ -n "$SLOT_JAIL_A" ]; then
    if in_slot "$SLOT_JAIL_A" sh -c 'echo x > /work/uchg_test 2>/dev/null && chflags uchg /work/uchg_test 2>/dev/null'; then
        echo "     /work に uchg ファイルを用意した。片付け側の確認は TODO"
    fi
else
    sk "I2 uchg" "SLOT_JAIL_A が未指定"
fi
td "I2 uchg 片付け" "uchg ファイルを含む tmpfs のアンマウントが成功すること。片付け契機と合わせて段階1で"

# スロットから setuid バイナリを実行しても権限が上がらない
#   マウントが nosuid であることの確認までを自動化する
if mount | grep -q '/var/jails/ap/slots/'; then
    if mount | grep '/var/jails/ap/slots/' | grep -qv 'nosuid'; then
        ng "I3 nosuid: nosuid でないスロットマウントがある"
    else
        ok "I3 nosuid: スロットのマウントはすべて nosuid"
    fi
else
    sk "I3 nosuid" "スロットのマウントが見当たらない（stage0.sh setup 未実施?）"
fi
td "I3 setuid 実行" "setuid されたバイナリをスロット内で実行して euid が変わらないことの実地確認"

# フロー前提のケース: TODO
td "I8 fd の持ち越し" "片付けの後、振り分け・エッジ・php-cgi の誰も前の世代の受け取り口を持っていないこと。リクエストフローが必要"
td "I19 標準エラー出力" "php-cgi が stderr に大量に書いても溜まらないこと。スロットで php を動かすフローが必要"
td "失敗時 release 無し" "release を送らないリクエストが強制片付け期限で片付くこと"
td "失敗時 QUARANTINED" "片付けを失敗させると QUARANTINED になり空きに戻らないこと"

# 振り分けの入力: 壊れた JSON、上限超え、fd 付きメッセージを送る
#   -> 切られ、振り分けは落ちない
if [ -S "$DISP_SOCK" ] && command -v python3 >/dev/null 2>&1; then
    DISP_PID=""
    [ -f "$DISP_PIDFILE" ] && DISP_PID=$(cat "$DISP_PIDFILE")
    if python3 - "$DISP_SOCK" <<'PYEOF'
import socket, sys, os, array

path = sys.argv[1]

def send(payload, with_fd=False):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.settimeout(2.0)
    try:
        s.connect(path)
        if with_fd:
            f = os.open("/dev/null", os.O_RDONLY)
            anc = [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                    array.array("i", [f]))]
            s.sendmsg([payload], anc)
            os.close(f)
        else:
            s.sendall(payload)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
    except OSError:
        pass  # 切られるのは想定内
    finally:
        s.close()

send(b"{not json")                    # 壊れた JSON
send(b"A" * (1024 * 1024))             # 上限超えのはずの大きさ
send(b'{"v":1,"t":"bogus"}', with_fd=True)  # fd 付き
sys.exit(0)
PYEOF
    then
        if [ -n "$DISP_PID" ] && kill -0 "$DISP_PID" 2>/dev/null; then
            ok "振り分けの入力: 壊れた入力の後も振り分けが生きている"
        else
            ng "振り分けの入力: 振り分けが落ちた（または pidfile が読めない）"
        fi
    else
        ng "振り分けの入力: 送信側で想定外の失敗"
    fi
else
    sk "振り分けの入力" "disp ソケットが無い、または python3 が無い"
fi

# 性能: 片付けと準備にかかる時間と、毎秒のリクエスト数の上限
#   bench/bench.sh の結果をそのまま出す（合否は付けない）
if [ -x "$HERE/../bench/bench.sh" ]; then
    echo "-- 性能（参考値）: bench.sh 100 回"
    "$HERE/../bench/bench.sh" 100 || echo "   (bench が失敗。起動状態を確認)"
else
    sk "性能" "bench/bench.sh が無い"
fi
td "性能 片付けと準備" "子 jail の作成、tmpfs のマウント、php-cgi の起動にかかる時間の内訳測定"

echo "----"
echo "PASS=$pass FAIL=$fail TODO=$todo SKIP=$skip"
[ "$fail" -eq 0 ]
