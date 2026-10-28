#!/usr/bin/env python3
"""中継（box-relay）と認証スタブ（box-grant）のプロトコル試験。

FreeBSD の jail が無くても、プロトコルそのものは Linux でも確かめられる
（tests/proto-test.sh がビルドとサーバーの起動・終了をまとめて行う）。
確かめること:
  1. grant → 中継の fd → memo.get が値を返す
  2. budget を使い切ると接続が閉じる
  3. resource の不一致は forbidden
  4. grant を通さず budget を広げた宣言は中継が bad_request で拒む
  5. セッションが違えば denied（fd は渡らない）

前提: 環境変数 BOX_TEST_DIR にソケット置き場、BOX_TEST_UID に接続元 uid。
"""
import socket, json, os, sys

BASE = os.environ.get("BOX_TEST_DIR", "/tmp/box-test")

MEMO1 = "22222222-2222-4222-8222-222222222222"
MEMO2 = "33333333-3333-4333-8333-333333333333"

def recv_rec(s):
    data, anc, flags, _ = s.recvmsg(70000, socket.CMSG_SPACE(4*4))
    fds = []
    for level, typ, dat in anc:
        if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
            import array
            a = array.array("i"); a.frombytes(dat[:len(dat)//4*4]); fds = a.tolist()
    return data, fds, flags

def grant(scope, resource):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.connect(BASE + "/auth.sock")
    req = {"v":1,"t":"grant","rid":"t1","session":"stage0-demo-session","scope":scope,"gesture":True}
    if resource: req["resource"] = resource
    s.sendmsg([json.dumps(req).encode()], [], socket.MSG_EOR)
    data, fds, flags = recv_rec(s)
    s.close()
    res = json.loads(data)
    assert res["t"] == "granted", res
    assert len(fds) == 1, fds
    r = socket.fromfd(fds[0], socket.AF_UNIX, socket.SOCK_SEQPACKET)
    os.close(fds[0])
    return r

def op(s, opname, args):
    try:
        s.sendmsg([json.dumps({"v":1,"t":"op","op":opname,"args":args}).encode()], [], socket.MSG_EOR)
        data, fds, flags = recv_rec(s)
    except (BrokenPipeError, ConnectionResetError, OSError):
        return None
    if not data: return None
    return json.loads(data)

ok = 0
# 1. 正常系: grant → memo.get が値を返す
r = grant("memo.show", MEMO1)
res = op(r, "memo.get", {"id": MEMO1})
assert res and res["ok"] and res["result"]["title"] == "買い物リスト", res
print("1. grant->memo.get OK"); ok += 1
# 2. budget は1回だけ: 接続は切れているはず
res2 = op(r, "memo.get", {"id": MEMO1})
assert res2 is None, res2
print("2. budget exhaustion closes connection OK"); ok += 1
r.close()
# 3. resource 不一致は forbidden
r = grant("memo.show", MEMO2)
res = op(r, "memo.get", {"id": MEMO1})
assert res and not res["ok"] and res["error"] == "forbidden", res
print("3. resource mismatch forbidden OK"); ok += 1
r.close()
# 4. grant を通さず中継へ budget を広げた宣言 → bad_request
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.connect(BASE + "/relay.sock")
decl = {"v":1,"t":"declare","rid":"x","user_id":"11111111-1111-4111-8111-111111111111","scope":"memo.show","resource":MEMO1,"budget":{"memo.get":2},"gesture":True}
s.sendmsg([json.dumps(decl).encode()], [], socket.MSG_EOR)
data, fds, flags = recv_rec(s)
res = json.loads(data)
assert not res["ok"] and res["error"] == "bad_request", res
print("4. widened budget rejected OK"); ok += 1
s.close()
# 5. セッション違いは denied
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.connect(BASE + "/auth.sock")
req = {"v":1,"t":"grant","rid":"t2","session":"wrong","scope":"memo.index","gesture":True}
s.sendmsg([json.dumps(req).encode()], [], socket.MSG_EOR)
data, fds, flags = recv_rec(s)
res = json.loads(data)
assert res["t"] == "denied" and not fds, res
print("5. bad session denied OK"); ok += 1
s.close()
print(f"ALL {ok} PROTOCOL TESTS PASSED")
