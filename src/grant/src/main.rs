//! box-grant: 認証のスタブ。セッションを固定の文字列1つで代用し、固定の利用者に結び付ける。
use std::os::unix::io::RawFd;

use box_proto as bp;

struct Config {
    sock: String,
    relay_sock: String,
    session: String,
    user_id: String,
    peer_uid: Option<u32>,
}

fn reply_err(fd: RawFd, rid: &str, code: &str) {
    let res = bp::GrantRes { v: 1, t: "denied".into(), rid: rid.to_string(), error: Some(code.into()) };
    let _ = bp::send_msg(fd, &bp::to_bytes(&res), &[]);
}

fn handle(fd: RawFd, cfg: &Config) {
    if let Some(expect) = cfg.peer_uid {
        match bp::peer_uid(fd) {
            Ok(uid) if uid == expect => {}
            _ => return,
        }
    }
    let msg = match bp::recv_msg(fd) {
        Ok(Some(m)) => m,
        _ => return,
    };
    if !msg.fds.is_empty() || msg.ctrunc || (bp::eor_required() && !msg.eor) {
        bp::close_fds(&msg.fds);
        return;
    }
    let req: bp::GrantReq = match bp::parse_strict(&msg.data) {
        Some(r) => r,
        None => return,
    };
    if req.v != 1 || req.t != "grant" || req.rid.is_empty() || req.rid.len() > 64 {
        return;
    }
    // セッションの解決（固定の1つだけ）。
    if req.session != cfg.session {
        reply_err(fd, &req.rid, "forbidden");
        return;
    }
    let spec = match bp::scope_spec(&req.scope) {
        Some(s) => s,
        None => {
            reply_err(fd, &req.rid, "bad_request");
            return;
        }
    };
    if spec.needs_resource != req.resource.is_some()
        || (spec.needs_resource && !bp::is_uuid(req.resource.as_deref().unwrap_or("")))
        || (spec.needs_gesture && !req.gesture)
    {
        reply_err(fd, &req.rid, "bad_request");
        return;
    }
    // 中継へ宣言する。budget は範囲の表から決め、広げることはできない。
    let relay = match bp::seqpacket_connect(&cfg.relay_sock) {
        Ok(f) => f,
        Err(_) => {
            reply_err(fd, &req.rid, "internal");
            return;
        }
    };
    let decl = bp::Declare {
        v: 1,
        t: "declare".into(),
        rid: req.rid.clone(),
        user_id: cfg.user_id.clone(),
        scope: req.scope.clone(),
        resource: req.resource.clone(),
        budget: bp::budget_map(spec),
        gesture: req.gesture,
    };
    let declared = (|| -> Option<()> {
        bp::send_msg(relay, &bp::to_bytes(&decl), &[]).ok()?;
        let res = bp::recv_msg(relay).ok()??;
        if !res.fds.is_empty() || res.ctrunc || (bp::eor_required() && !res.eor) {
            bp::close_fds(&res.fds);
            return None;
        }
        let r: bp::OpResult = bp::parse_strict(&res.data)?;
        if r.ok { Some(()) } else { None }
    })();
    if declared.is_none() {
        bp::close_fd(relay);
        reply_err(fd, &req.rid, "internal");
        return;
    }
    let res = bp::GrantRes { v: 1, t: "granted".into(), rid: req.rid.clone(), error: None };
    let _ = bp::send_msg(fd, &bp::to_bytes(&res), &[relay]);
    bp::close_fd(relay);
}

fn main() {
    let mut cfg = Config {
        sock: "/var/jails/sock/auth/auth.sock".into(),
        relay_sock: "/var/jails/sock/relay/relay.sock".into(),
        session: "stage0-demo-session".into(),
        user_id: "11111111-1111-4111-8111-111111111111".into(),
        peer_uid: None,
    };
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--sock" => { i += 1; cfg.sock = args.get(i).cloned().unwrap_or_default(); }
            "--relay-sock" => { i += 1; cfg.relay_sock = args.get(i).cloned().unwrap_or_default(); }
            "--session" => { i += 1; cfg.session = args.get(i).cloned().unwrap_or_default(); }
            "--user" => { i += 1; cfg.user_id = args.get(i).cloned().unwrap_or_default(); }
            "--peer-uid" => { i += 1; cfg.peer_uid = args.get(i).and_then(|s| s.parse().ok()); }
            other => { eprintln!("unknown arg: {}", other); std::process::exit(2); }
        }
        i += 1;
    }
    if let Some(dir) = std::path::Path::new(&cfg.sock).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let listener = match bp::seqpacket_listener(&cfg.sock) {
        Ok(fd) => fd,
        Err(e) => { eprintln!("[grant] listen {}: {}", cfg.sock, e); std::process::exit(1); }
    };
    eprintln!("[grant] listening on {} (stage0 stub user {})", cfg.sock, cfg.user_id);
    loop {
        let conn = unsafe { libc::accept(listener, std::ptr::null_mut(), std::ptr::null_mut()) };
        if conn < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted { continue; }
            continue;
        }
        handle(conn, &cfg);
        bp::close_fd(conn);
    }
}
