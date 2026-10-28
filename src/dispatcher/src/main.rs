//! box-dispatcher: 振り分け（ap jail 内の root）。仕事は3つだけ: スロットの子 jail の作成・削除と、fd の受け渡し。
use std::os::unix::io::RawFd;

use box_proto as bp;


#[cfg(target_os = "freebsd")]
mod jailx {
    use std::ffi::CString;
    use std::io;

    // jailparam_* は libc ではなく FreeBSD base の libjail の関数。
    // dispatcher/build.rs で -ljail をリンクする。
    //
    // 注意（FreeBSD 15.1 で実測）: 現在の libjail の jailparam は
    // パラメータ1つごとに struct jailparam を用意する形。
    //   jailparam_init(jp, "name") / jailparam_import(jp, "値") を
    //   パラメータの数だけ繰り返し、配列を jailparam_set へ渡す。
    // 値のないフラグ（persist 等）は import に "true" を渡す。
    // 空文字列では値が入らず、set が EINVAL になる。
    #[repr(C)]
    struct JailParam {
        jp_name: *mut libc::c_char,
        jp_value: *mut libc::c_void,
        jp_valuelen: usize,
        jp_elemlen: usize,
        jp_ctltype: libc::c_int,
        jp_structtype: libc::c_int,
        jp_flags: libc::c_uint,
    }

    impl JailParam {
        fn zeroed() -> Self {
            JailParam {
                jp_name: std::ptr::null_mut(),
                jp_value: std::ptr::null_mut(),
                jp_valuelen: 0,
                jp_elemlen: 0,
                jp_ctltype: 0,
                jp_structtype: 0,
                jp_flags: 0,
            }
        }
    }

    extern "C" {
        fn jailparam_init(jp: *mut JailParam, name: *const libc::c_char) -> libc::c_int;
        fn jailparam_import(jp: *mut JailParam, value: *const libc::c_char) -> libc::c_int;
        fn jailparam_set(jp: *mut JailParam, njp: libc::c_uint, flags: libc::c_int) -> libc::c_int;
        fn jailparam_free(jp: *mut JailParam, njp: libc::c_uint);
    }

    pub fn create(params: &[String]) -> io::Result<i32> {
        unsafe {
            // "key=value" を (key, value) に割り、値のないフラグは
            // (key, "true") とする。CString は set が終わるまで生かす
            let mut keys: Vec<CString> = Vec::with_capacity(params.len());
            let mut vals: Vec<CString> = Vec::with_capacity(params.len());
            for p in params {
                let (k, v) = match p.split_once('=') {
                    Some((k, v)) => (k, v),
                    None => (p.as_str(), "true"),
                };
                let bad = || io::Error::new(io::ErrorKind::InvalidInput, "bad jail param");
                keys.push(CString::new(k).map_err(|_| bad())?);
                vals.push(CString::new(v).map_err(|_| bad())?);
            }
            let mut jps: Vec<JailParam> = (0..params.len()).map(|_| JailParam::zeroed()).collect();
            let mut result: io::Result<i32> = Ok(0);
            for i in 0..params.len() {
                if jailparam_init(&mut jps[i], keys[i].as_ptr()) < 0 {
                    result = Err(io::Error::last_os_error());
                    break;
                }
                if jailparam_import(&mut jps[i], vals[i].as_ptr()) < 0 {
                    result = Err(io::Error::last_os_error());
                    break;
                }
            }
            if result.is_ok() {
                let jid = jailparam_set(jps.as_mut_ptr(), jps.len() as u32, libc::JAIL_CREATE);
                result = if jid < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(jid)
                };
            }
            jailparam_free(jps.as_mut_ptr(), jps.len() as u32);
            result
        }
    }

    pub fn attach(jid: i32) -> io::Result<()> {
        if unsafe { libc::jail_attach(jid) } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub fn remove(jid: i32) -> io::Result<()> {
        if unsafe { libc::jail_remove(jid) } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub fn exists(jid: i32) -> bool {
        unsafe {
            let name_key = b"jid\0";
            let mut jid_val: i32 = jid;
            let lastjid_key = b"lastjid\0";
            let mut lastjid_val: i32 = 0;
            let mut iov = [
                libc::iovec { iov_base: name_key.as_ptr() as *mut libc::c_void, iov_len: name_key.len() },
                libc::iovec { iov_base: &mut jid_val as *mut i32 as *mut libc::c_void, iov_len: 4 },
                libc::iovec { iov_base: lastjid_key.as_ptr() as *mut libc::c_void, iov_len: lastjid_key.len() },
                libc::iovec { iov_base: &mut lastjid_val as *mut i32 as *mut libc::c_void, iov_len: 4 },
            ];
            libc::jail_get(iov.as_mut_ptr(), (iov.len()) as u32, 0) >= 0
        }
    }

    pub fn mount_tmpfs(path: &str, size_bytes: u64) -> io::Result<()> {
        let pairs: [(&str, String); 3] = [
            ("fstype", "tmpfs".to_string()),
            ("fspath", path.to_string()),
            ("size", size_bytes.to_string()),
        ];
        let mut iovs: Vec<libc::iovec> = Vec::new();
        let mut storage: Vec<Vec<u8>> = Vec::new();
        for (k, v) in pairs.iter() {
            storage.push(k.as_bytes().iter().cloned().chain([0]).collect());
            storage.push(v.as_bytes().iter().cloned().chain([0]).collect());
        }
        for chunk in storage.iter() {
            iovs.push(libc::iovec { iov_base: chunk.as_ptr() as *mut libc::c_void, iov_len: chunk.len() });
        }
        if unsafe { libc::nmount(iovs.as_mut_ptr(), iovs.len() as u32, 0) } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub fn unmount(path: &str) -> io::Result<()> {
        let c = CString::new(path).unwrap();
        if unsafe { libc::unmount(c.as_ptr(), 0) } < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

#[cfg(not(target_os = "freebsd"))]
mod jailx {
    use std::io;
    pub fn create(_params: &[String]) -> io::Result<i32> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "jail is FreeBSD only"))
    }
    pub fn attach(_jid: i32) -> io::Result<()> { Err(io::Error::new(io::ErrorKind::Unsupported, "jail")) }
    pub fn remove(_jid: i32) -> io::Result<()> { Err(io::Error::new(io::ErrorKind::Unsupported, "jail")) }
    pub fn exists(_jid: i32) -> bool { false }
    pub fn mount_tmpfs(_path: &str, _size: u64) -> io::Result<()> { Err(io::Error::new(io::ErrorKind::Unsupported, "nmount")) }
    pub fn unmount(_path: &str) -> io::Result<()> { Err(io::Error::new(io::ErrorKind::Unsupported, "unmount")) }
}


struct Config {
    sock: String,
    slots: u32,
    slots_root: String, // /slots
    run_dir: String,    // /run/slots
    php_cgi: String,
    force_clean_secs: u64,
    peer_uid: Option<u32>,
    tmpfs_size: u64,
}

#[derive(PartialEq, Clone, Copy, Debug)]
enum State {
    Free,
    Busy,
    Quarantined,
}

struct Slot {
    k: u32,
    state: State,
    generation: u64,
    jid: Option<i32>,
    php_pid: Option<i32>,
    fcgi_listen: RawFd,
    busy_since: Option<std::time::Duration>,
}

fn log_line(msg: &str) {
    eprintln!("[dispatcher] {}", msg);
}

fn stream_listener(path: &str) -> std::io::Result<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let bytes = path.as_bytes();
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as _;
    for (i, &b) in bytes.iter().enumerate() {
        addr.sun_path[i] = b as _;
    }
    unsafe { libc::unlink(addr.sun_path.as_ptr()) };
    let rc = unsafe { libc::bind(fd, &addr as *const libc::sockaddr_un as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_un>() as u32) };
    if rc < 0 {
        let e = std::io::Error::last_os_error();
        bp::close_fd(fd);
        return Err(e);
    }
    unsafe { libc::chmod(addr.sun_path.as_ptr(), 0o600) };
    if unsafe { libc::listen(fd, 16) } < 0 {
        let e = std::io::Error::last_os_error();
        bp::close_fd(fd);
        return Err(e);
    }
    Ok(fd)
}

/// fd 4 以降を全部閉じる（子プロセスが exec の前に継承 fd を絞るため）。
#[cfg(target_os = "freebsd")]
unsafe fn close_from_4() {
    libc::closefrom(4);
}

#[cfg(not(target_os = "freebsd"))]
unsafe fn close_from_4() {
    // Linux 等での代替（コンパイル確認用。本番は FreeBSD の closefrom）。
    for fd in 4..4096 {
        libc::close(fd);
    }
}

fn socketpair_seqpacket() -> std::io::Result<(RawFd, RawFd)> {
    let mut pair: [RawFd; 2] = [-1, -1];
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0, pair.as_mut_ptr()) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok((pair[0], pair[1]))
}


fn prepare(cfg: &Config, slot: &mut Slot) -> Result<(RawFd, i32, i32), String> {
    let k = slot.k;
    let work = format!("{}/{}/work", cfg.slots_root, k);
    // 1. tmpfs（世代ごとに新しいもの）
    jailx::mount_tmpfs(&work, cfg.tmpfs_size).map_err(|e| format!("mount tmpfs {}: {}", work, e))?;

    // 2. 受け取り口の socketpair
    let (our_end, php_end) = socketpair_seqpacket().map_err(|e| format!("socketpair: {}", e))?;

    // 3. 子 jail の作成
    // 子 jail の名前は ap の中から作るので相対名にする。ドットを含む
    // 名前は jail の階層として解決され、実在しない親を探して ENOENT に
    // なる（FreeBSD 15.1 で実測）。ホストからは ap.slot1-g1 と見える
    let name = format!("slot{}-g{}", k, slot.generation);
    let path = format!("{}/{}", cfg.slots_root, k);
    let uid = 3000 + k;
    let params: Vec<String> = vec![
        format!("name={}", name),
        format!("path={}", path),
        format!("host.hostname=slot{}", k),
        "ip4=disable".into(),
        "ip6=disable".into(),
        "enforce_statfs=1".into(),
        "children.max=0".into(),
        "allow.sysvipc=0".into(),
        "persist".into(),
    ];
    let jid = match jailx::create(&params) {
        Ok(j) => j,
        Err(e) => {
            bp::close_fd(our_end);
            bp::close_fd(php_end);
            let _ = jailx::unmount(&work);
            return Err(format!("jail create {}: {}", name, e));
        }
    };

    // 4. php-cgi の起動（fork → jail_attach → fd の付け替え → uid を落とす → exec）
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        bp::close_fd(our_end);
        bp::close_fd(php_end);
        let _ = jailx::remove(jid);
        let _ = jailx::unmount(&work);
        return Err("fork failed".into());
    }
    if pid == 0 {
        // 子プロセス: ここからは失敗したら _exit するだけ。
        unsafe {
            if jailx::attach(jid).is_err() {
                libc::_exit(127);
            }
            // fd 0 = FastCGI の待ち受け、fd 3 = 受け取り口
            if slot.fcgi_listen != 0 {
                libc::dup2(slot.fcgi_listen, 0);
            }
            if php_end != 3 {
                libc::dup2(php_end, 3);
            }
            close_from_4();
            libc::setgroups(1, &uid);
            libc::setgid(uid);
            libc::setuid(uid);
            libc::chdir(b"/\0".as_ptr() as *const libc::c_char);
            let prog = std::ffi::CString::new(cfg.php_cgi.clone()).unwrap();
            let arg0 = std::ffi::CString::new("php-cgi").unwrap();
            let argv = [arg0.as_ptr(), std::ptr::null()];
            let e_path = std::ffi::CString::new("PATH=/usr/local/bin:/usr/bin:/bin").unwrap();
            let e_recv = std::ffi::CString::new("BOX_RECV_FD=3").unwrap();
            let e_maxreq = std::ffi::CString::new("PHP_FCGI_MAX_REQUESTS=1").unwrap();
            let envp = [e_path.as_ptr(), e_recv.as_ptr(), e_maxreq.as_ptr(), std::ptr::null()];
            libc::execve(prog.as_ptr(), argv.as_ptr(), envp.as_ptr());
            libc::_exit(127);
        }
    }
    // 親: php 側の端は閉じる。
    bp::close_fd(php_end);
    Ok((our_end, jid, pid))
}

/// 片付け。失敗したら Err（隔離する）。
fn cleanup(cfg: &Config, slot: &mut Slot, recv_end: Option<RawFd>) -> Result<(), String> {
    if let Some(fd) = recv_end {
        bp::close_fd(fd);
    }
    let k = slot.k;
    // 1. 子 jail を消す（中のプロセスはカーネルがまとめて消す）
    if let Some(jid) = slot.jid.take() {
        jailx::remove(jid).map_err(|e| format!("jail_remove slot{}: {}", k, e))?;
        // 2. プロセスが残っていないことを確かめる（jail が消え切るまで待つ）
        let start = bp::monotonic_now();
        while jailx::exists(jid) {
            if bp::monotonic_now() - start > std::time::Duration::from_secs(5) {
                return Err(format!("slot{}: jail did not disappear", k));
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    if let Some(pid) = slot.php_pid.take() {
        // jail_remove でプロセスは消えているはず。残っていれば期限つきで待ち、
        // 最後は SIGKILL する（ブロックして片付け全体を止めない）。
        let start = bp::monotonic_now();
        loop {
            let mut status: i32 = 0;
            let r = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            if r != 0 {
                break;
            }
            if bp::monotonic_now() - start > std::time::Duration::from_secs(5) {
                unsafe { libc::kill(pid, libc::SIGKILL) };
                let mut status2: i32 = 0;
                unsafe { libc::waitpid(pid, &mut status2, 0) };
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    // 3. POSIX 共有メモリの残りを消す（jail 削除の前後で作られたものが残る）
    let shm_dir = format!("{}/{}/dev/shm", cfg.slots_root, k);
    if let Ok(entries) = std::fs::read_dir(&shm_dir) {
        for ent in entries.flatten() {
            let _ = std::fs::remove_file(ent.path());
        }
    }
    // 4. tmpfs をアンマウントする
    let work = format!("{}/{}/work", cfg.slots_root, k);
    jailx::unmount(&work).map_err(|e| format!("unmount {}: {}", work, e))?;
    Ok(())
}


fn main() {
    let mut cfg = Config {
        sock: "/run/sock/disp/disp.sock".into(),
        slots: 4,
        slots_root: "/slots".into(),
        run_dir: "/run/slots".into(),
        php_cgi: "/usr/local/bin/php-cgi".into(),
        force_clean_secs: 45,
        peer_uid: None,
        tmpfs_size: 64 * 1024 * 1024,
    };
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--sock" => { i += 1; cfg.sock = args.get(i).cloned().unwrap_or_default(); }
            "--slots" => { i += 1; cfg.slots = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(4); }
            "--slots-root" => { i += 1; cfg.slots_root = args.get(i).cloned().unwrap_or_default(); }
            "--run-dir" => { i += 1; cfg.run_dir = args.get(i).cloned().unwrap_or_default(); }
            "--php-cgi" => { i += 1; cfg.php_cgi = args.get(i).cloned().unwrap_or_default(); }
            "--force-clean-sec" => { i += 1; cfg.force_clean_secs = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(45); }
            "--peer-uid" => { i += 1; cfg.peer_uid = args.get(i).and_then(|s| s.parse().ok()); }
            other => { eprintln!("unknown arg: {}", other); std::process::exit(2); }
        }
        i += 1;
    }
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };

    let _ = std::fs::create_dir_all(&cfg.run_dir);
    // スロットごとに FastCGI の待ち受けを作る（世代をまたいで同じものを使う。
    // bind/listen は振り分けが行い、php-cgi は fd 0 として継承する）。
    let mut slots: Vec<Slot> = Vec::new();
    let mut recv_ends: Vec<Option<RawFd>> = Vec::new();
    for k in 1..=cfg.slots {
        let listen_path = format!("{}/{}.sock", cfg.run_dir, k);
        let listen_fd = match stream_listener(&listen_path) {
            Ok(fd) => fd,
            Err(e) => { eprintln!("[dispatcher] listen {}: {}", listen_path, e); std::process::exit(1); }
        };
        slots.push(Slot { k, state: State::Free, generation: 1, jid: None, php_pid: None, fcgi_listen: listen_fd, busy_since: None });
        recv_ends.push(None);
    }
    for idx in 0..slots.len() {
        let mut slot = std::mem::replace(&mut slots[idx], Slot { k: 0, state: State::Quarantined, generation: 0, jid: None, php_pid: None, fcgi_listen: -1, busy_since: None });
        match prepare(&cfg, &mut slot) {
            Ok((our_end, jid, pid)) => {
                slot.jid = Some(jid);
                slot.php_pid = Some(pid);
                recv_ends[idx] = Some(our_end);
            }
            Err(e) => {
                log_line(&format!("slot{} prepare failed: {} (quarantined)", slot.k, e));
                slot.state = State::Quarantined;
            }
        }
        slots[idx] = slot;
    }

    let listener = match bp::seqpacket_listener(&cfg.sock) {
        Ok(fd) => fd,
        Err(e) => { eprintln!("[dispatcher] listen {}: {}", cfg.sock, e); std::process::exit(1); }
    };
    log_line(&format!("listening on {} ({} slots)", cfg.sock, cfg.slots));

    loop {
        let now = bp::monotonic_now();
        let mut timeout_ms: i32 = 1000;
        for slot in slots.iter() {
            if slot.state == State::Busy {
                if let Some(since) = slot.busy_since {
                    let elapsed = now - since;
                    let limit = std::time::Duration::from_secs(cfg.force_clean_secs);
                    if elapsed >= limit {
                        timeout_ms = 0;
                    } else {
                        let remain = (limit - elapsed).as_millis() as i32;
                        if remain < timeout_ms { timeout_ms = remain; }
                    }
                }
            }
        }
        let readable = bp::wait_readable(listener, timeout_ms).unwrap_or(false);

        for idx in 0..slots.len() {
            if slots[idx].state == State::Busy {
                if let Some(since) = slots[idx].busy_since {
                    if bp::monotonic_now() - since >= std::time::Duration::from_secs(cfg.force_clean_secs) {
                        log_line(&format!("slot{}: force cleanup (no release)", slots[idx].k));
                        do_cleanup_cycle(&cfg, &mut slots, &mut recv_ends, idx);
                    }
                }
            }
        }

        if !readable {
            continue;
        }
        let conn = unsafe { libc::accept(listener, std::ptr::null_mut(), std::ptr::null_mut()) };
        if conn < 0 {
            continue;
        }
        handle_s1(conn, &cfg, &mut slots, &mut recv_ends);
        bp::close_fd(conn);
    }
}

fn do_cleanup_cycle(cfg: &Config, slots: &mut Vec<Slot>, recv_ends: &mut Vec<Option<RawFd>>, idx: usize) {
    let recv = recv_ends[idx].take();
    match cleanup(cfg, &mut slots[idx], recv) {
        Ok(()) => {
            slots[idx].generation += 1;
            slots[idx].busy_since = None;
            match prepare(cfg, &mut slots[idx]) {
                Ok((our_end, jid, pid)) => {
                    slots[idx].jid = Some(jid);
                    slots[idx].php_pid = Some(pid);
                    recv_ends[idx] = Some(our_end);
                    slots[idx].state = State::Free;
                }
                Err(e) => {
                    log_line(&format!("slot{} prepare failed: {} (quarantined)", slots[idx].k, e));
                    slots[idx].state = State::Quarantined;
                }
            }
        }
        Err(e) => {
            log_line(&format!("slot{} cleanup failed: {} (quarantined)", slots[idx].k, e));
            slots[idx].state = State::Quarantined;
        }
    }
}

fn handle_s1(conn: RawFd, cfg: &Config, slots: &mut Vec<Slot>, recv_ends: &mut Vec<Option<RawFd>>) {
    if let Some(expect) = cfg.peer_uid {
        match bp::peer_uid(conn) {
            Ok(uid) if uid == expect => {}
            _ => return,
        }
    }
    let msg = match bp::recv_msg(conn) {
        Ok(Some(m)) => m,
        _ => return,
    };
    // fd の付いた入力は不正として切る。fd は即座に閉じる。
    if !msg.fds.is_empty() || msg.ctrunc || (bp::eor_required() && !msg.eor) {
        bp::close_fds(&msg.fds);
        log_line("S1: protocol violation, dropped");
        return;
    }
    let req: bp::DispReq = match bp::parse_strict(&msg.data) {
        Some(r) => r,
        None => {
            log_line("S1: bad json, dropped");
            return;
        }
    };
    if req.v != 1 || req.rid.is_empty() || req.rid.len() > 64 {
        return;
    }
    match req.t.as_str() {
        "alloc" => {
            let idx = slots.iter().position(|s| s.state == State::Free);
            match idx {
                Some(idx) => {
                    let fcgi_path = format!("{}/{}.sock", cfg.run_dir, slots[idx].k);
                    let conn_fd = connect_stream(&fcgi_path);
                    match (conn_fd, recv_ends[idx]) {
                        (Ok(fcgi), Some(_)) => {
                            let our_end = recv_ends[idx].take().unwrap();
                            let res = bp::DispRes { v: 1, t: "allocated".into(), rid: req.rid.clone(), slot: Some(slots[idx].k), error: None };
                            let sent = bp::send_msg(conn, &bp::to_bytes(&res), &[our_end, fcgi]).is_ok();
                            bp::close_fd(our_end);
                            bp::close_fd(fcgi);
                            if sent {
                                slots[idx].state = State::Busy;
                                slots[idx].busy_since = Some(bp::monotonic_now());
                            } else {
                                // 受け取り口を渡し損ねた世代は使い物にならない。片付ける。
                                log_line(&format!("slot{}: alloc reply failed, recycling", slots[idx].k));
                                do_cleanup_cycle(cfg, slots, recv_ends, idx);
                            }
                        }
                        (Err(e), _) => {
                            log_line(&format!("slot{}: fcgi connect failed: {}", slots[idx].k, e));
                            let res = bp::DispRes { v: 1, t: "error".into(), rid: req.rid.clone(), slot: None, error: Some("internal".into()) };
                            let _ = bp::send_msg(conn, &bp::to_bytes(&res), &[]);
                        }
                        _ => {
                            let res = bp::DispRes { v: 1, t: "error".into(), rid: req.rid.clone(), slot: None, error: Some("internal".into()) };
                            let _ = bp::send_msg(conn, &bp::to_bytes(&res), &[]);
                        }
                    }
                }
                None => {
                    let res = bp::DispRes { v: 1, t: "error".into(), rid: req.rid.clone(), slot: None, error: Some("busy".into()) };
                    let _ = bp::send_msg(conn, &bp::to_bytes(&res), &[]);
                }
            }
        }
        "release" => {
            let k = req.slot.unwrap_or(0);
            if let Some(idx) = slots.iter().position(|s| s.k == k && s.state == State::Busy) {
                do_cleanup_cycle(cfg, slots, recv_ends, idx);
                let res = bp::DispRes { v: 1, t: "released".into(), rid: req.rid.clone(), slot: Some(k), error: None };
                let _ = bp::send_msg(conn, &bp::to_bytes(&res), &[]);
            } else {
                let res = bp::DispRes { v: 1, t: "error".into(), rid: req.rid.clone(), slot: Some(k), error: Some("bad_request".into()) };
                let _ = bp::send_msg(conn, &bp::to_bytes(&res), &[]);
            }
        }
        _ => {
            log_line("S1: unknown type, dropped");
        }
    }
}

fn connect_stream(path: &str) -> std::io::Result<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let bytes = path.as_bytes();
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as _;
    for (i, &b) in bytes.iter().enumerate() {
        addr.sun_path[i] = b as _;
    }
    if unsafe { libc::connect(fd, &addr as *const libc::sockaddr_un as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_un>() as u32) } < 0 {
        let e = std::io::Error::last_os_error();
        bp::close_fd(fd);
        return Err(e);
    }
    Ok(fd)
}
