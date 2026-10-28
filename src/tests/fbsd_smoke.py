#!/usr/bin/env python3
"""FreeBSD の機構スモークテスト。

土台にしている OS の事実が、その FreeBSD 上で本当に成り立つか
小さく殴って確かめる。実機でも、仮想マシンでも、CI でも同じものが回る。

確かめること:
  1. SOCK_SEQPACKET で MSG_EOR が受信側に立つ
  2. SCM_RIGHTS で fd を別プロセスへ渡せる
  3. jail を作って消せる（root が要る）
  4. jail の中から host の unix ソケットへ繋いでも、LOCAL_PEERCRED が
     接続元の uid を返す（root が要る）

使い方: python3 tests/fbsd_smoke.py （3 と 4 は root で実行したときだけ）
終了コード: FAIL があれば 1。
"""
import array
import ctypes
import os
import socket
import subprocess
import sys
import tempfile

results = []


def report(name, ok, note=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'}: {name}" + (f" -- {note}" if note else ""))


def skip(name, why):
    print(f"SKIP: {name} -- {why}")


def recv_rec(s):
    data, anc, flags, _ = s.recvmsg(65536, socket.CMSG_SPACE(4 * 4))
    fds = []
    for level, typ, dat in anc:
        if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
            a = array.array("i")
            a.frombytes(dat[: len(dat) // 4 * 4])
            fds = a.tolist()
    return data, fds, flags


def test_msg_eor():
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    a.sendmsg([b"hello"], [], socket.MSG_EOR)
    data, _, flags = recv_rec(b)
    ok = data == b"hello" and bool(flags & socket.MSG_EOR)
    report("MSG_EOR on SEQPACKET (V12)", ok, f"flags={flags:#x}")
    a.close(); b.close()


def test_fd_passing():
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    path = os.path.join(tempfile.mkdtemp(), "t.sock")
    listener.bind(path)
    listener.listen(1)
    pid = os.fork()
    if pid == 0:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        conn.connect(path)
        # 自分の stdin(fd 0) を相手へ渡す代わりに、開いたファイルを渡す
        f = open("/etc/hosts", "rb")
        conn.sendmsg([b"fd"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                 array.array("i", [f.fileno()]))], socket.MSG_EOR)
        os._exit(0)
    server, _ = listener.accept()
    data, fds, _ = recv_rec(server)
    ok = data == b"fd" and len(fds) == 1
    if ok:
        got = os.read(fds[0], 64)
        ok = len(got) > 0  # 渡された fd が実際に読める
    report("SCM_RIGHTS fd passing (V9)", ok)
    os.waitpid(pid, 0)
    listener.close()


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def test_jail_lifecycle():
    if not sys.platform.startswith("freebsd"):
        skip("jail lifecycle", "FreeBSD でない")
        return
    if os.geteuid() != 0:
        skip("jail lifecycle", "root でない")
        return
    name = "boxsmoke"
    run(["jail", "-r", name])
    r = run(["jail", "-c", f"name={name}", "path=/", "ip4=disable",
             "ip6=disable", "persist"])
    if r.returncode != 0:
        report("jail lifecycle", False, r.stderr.strip()[:120])
        return
    r2 = run(["jexec", name, "/usr/bin/true"])
    r3 = run(["jail", "-r", name])
    report("jail lifecycle", r2.returncode == 0 and r3.returncode == 0)


def test_peercred_across_jail():
    if not sys.platform.startswith("freebsd"):
        skip("LOCAL_PEERCRED across jail", "FreeBSD でない")
        return
    if os.geteuid() != 0:
        skip("LOCAL_PEERCRED across jail", "root でない")
        return
    # jail の中（path=/ で同じファイルシステム）から host のソケットへ繋ぎ、
    # host 側で LOCAL_PEERCRED を読む。python3 は jail の中でも同じものを使う。
    d = tempfile.mkdtemp()
    path = os.path.join(d, "peer.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    listener.bind(path)
    listener.listen(1)
    name = "boxsmoke2"
    run(["jail", "-r", name])
    r = run(["jail", "-c", f"name={name}", "path=/", "ip4=disable",
             "ip6=disable", "persist"])
    if r.returncode != 0:
        report("LOCAL_PEERCRED across jail", False, "jail create failed")
        listener.close()
        return
    client = (
        "import socket,sys;"
        f"s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET);"
        f"s.connect({path!r});s.sendmsg([b'x'],[],socket.MSG_EOR)"
    )
    proc = subprocess.Popen(["jexec", name, "/usr/local/bin/python3", "-c", client])
    listener.settimeout(10)
    try:
        conn, _ = listener.accept()
        # LOCAL_PEERCRED = 1, level SOL_LOCAL = 0。xucred の先頭は
        # cr_version (u_short), cr_uid (uid_t) の並び。
        libc = ctypes.CDLL("libc.so.7", use_errno=True)
        buf = ctypes.create_string_buffer(128)
        length = ctypes.c_uint(128)
        rc = libc.getsockopt(conn.fileno(), 0, 1, buf, ctypes.byref(length))
        uid = ctypes.c_uint.from_buffer_copy(buf.raw, 4).value if rc == 0 else -1
        # jail の中の root から繋いでいるので uid は 0 のはず
        report("LOCAL_PEERCRED across jail (C2)", rc == 0 and uid == 0,
               f"uid={uid}")
        conn.close()
    except Exception as e:  # noqa: BLE001
        report("LOCAL_PEERCRED across jail (C2)", False, str(e)[:120])
    proc.wait()
    run(["jail", "-r", name])
    listener.close()


def main():
    if sys.platform != "freebsd" and not sys.platform.startswith("freebsd"):
        print(f"note: this smoke test targets FreeBSD (running on {sys.platform});"
              " checks 1-2 are portable, 3-4 will be skipped or fail")
    test_msg_eor()
    test_fd_passing()
    test_jail_lifecycle()
    test_peercred_across_jail()
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
