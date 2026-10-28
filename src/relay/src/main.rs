//! box-relay: データ中継。
use std::collections::BTreeMap;
use std::os::unix::io::RawFd;

use box_proto as bp;


trait Backend {
    fn call(&mut self, op: &str, user_id: &str, args: &serde_json::Map<String, serde_json::Value>) -> Result<serde_json::Value, &'static str>;
}

/// メモリ内の固定データで応えるスタブ。
struct StubBackend {
    memos: Vec<serde_json::Value>,
}

impl StubBackend {
    fn new(demo_user: &str) -> Self {
        let mk = |id: &str, title: &str, body: &str, updated: &str| {
            serde_json::json!({
                "id": id, "user_id": demo_user, "title": title, "body": body,
                "updated_at": updated,
            })
        };
        StubBackend {
            memos: vec![
                mk("22222222-2222-4222-8222-222222222222", "買い物リスト", "牛乳、卵、醤油", "2026-10-20T09:00:00Z"),
                mk("33333333-3333-4333-8333-333333333333", "箱の設計メモ", "中継は範囲と対象と回数を保持する", "2026-10-24T12:30:00Z"),
            ],
        }
    }
}

fn arg_str<'a>(args: &'a serde_json::Map<String, serde_json::Value>, key: &str) -> Result<&'a str, &'static str> {
    match args.get(key) {
        Some(serde_json::Value::String(s)) => Ok(s.as_str()),
        _ => Err("bad_request"),
    }
}

fn check_title_body(args: &serde_json::Map<String, serde_json::Value>) -> Result<(String, String), &'static str> {
    let title = arg_str(args, "title")?;
    let body = arg_str(args, "body")?;
    if title.is_empty() || title.chars().count() > 200 || body.chars().count() > 10_000 {
        return Err("bad_request");
    }
    Ok((title.to_string(), body.to_string()))
}

impl Backend for StubBackend {
    fn call(&mut self, op: &str, user_id: &str, args: &serde_json::Map<String, serde_json::Value>) -> Result<serde_json::Value, &'static str> {
        match op {
            "memo.list" => {
                let items: Vec<serde_json::Value> = self.memos.iter()
                    .filter(|m| m["user_id"] == user_id)
                    .map(|m| serde_json::json!({"id": m["id"], "title": m["title"], "updated_at": m["updated_at"]}))
                    .collect();
                Ok(serde_json::json!({"items": items}))
            }
            "memo.get" => {
                let id = arg_str(args, "id")?;
                if !bp::is_uuid(id) { return Err("bad_request"); }
                match self.memos.iter().find(|m| m["id"] == id && m["user_id"] == user_id) {
                    Some(m) => Ok(serde_json::json!({
                        "id": m["id"], "title": m["title"], "body": m["body"], "updated_at": m["updated_at"]
                    })),
                    None => Err("not_found"),
                }
            }
            "memo.create" => {
                let (title, body) = check_title_body(args)?;
                // 乱数の依存を持たないため、固定の接頭辞 + 連番で代用する。
                let id = format!("44444444-4444-4444-8444-{:012}", self.memos.len() + 1);
                let m = serde_json::json!({
                    "id": id, "user_id": user_id, "title": title, "body": body,
                    "updated_at": "2026-10-26T00:00:00Z",
                });
                self.memos.push(m.clone());
                Ok(serde_json::json!({
                    "id": m["id"], "title": m["title"], "body": m["body"], "updated_at": m["updated_at"]
                }))
            }
            "memo.update" => {
                let id = arg_str(args, "id")?;
                if !bp::is_uuid(id) { return Err("bad_request"); }
                let (title, body) = check_title_body(args)?;
                match self.memos.iter_mut().find(|m| m["id"] == id && m["user_id"] == user_id) {
                    Some(m) => {
                        m["title"] = serde_json::Value::String(title);
                        m["body"] = serde_json::Value::String(body);
                        m["updated_at"] = serde_json::Value::String("2026-10-26T00:00:00Z".into());
                        Ok(serde_json::json!({
                            "id": m["id"], "title": m["title"], "body": m["body"], "updated_at": m["updated_at"]
                        }))
                    }
                    None => Err("not_found"),
                }
            }
            "memo.delete" => {
                let id = arg_str(args, "id")?;
                if !bp::is_uuid(id) { return Err("bad_request"); }
                let before = self.memos.len();
                self.memos.retain(|m| !(m["id"] == id && m["user_id"] == user_id));
                if self.memos.len() == before { Err("not_found") } else { Ok(serde_json::json!({"deleted": true})) }
            }
            _ => Err("forbidden"),
        }
    }
}


/// AP 由来の値は、長さと形だけをログに残す。
fn log_line(msg: &str) {
    eprintln!("[relay] {}", msg);
}

fn shape_of(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Null => "null".into(),
        serde_json::Value::Bool(_) => "bool".into(),
        serde_json::Value::Number(_) => "number".into(),
        serde_json::Value::String(s) => format!("string(len={})", s.chars().count()),
        serde_json::Value::Array(a) => format!("array(len={})", a.len()),
        serde_json::Value::Object(o) => {
            let keys: Vec<&str> = o.keys().map(|k| k.as_str()).collect();
            format!("object(keys={})", keys.join(","))
        }
    }
}


struct Conn {
    user_id: String,
    scope: String,
    resource: Option<String>,
    budget: BTreeMap<String, u32>,
    deadline: std::time::Duration,
}

fn handle_conn(fd: RawFd, expect_peer_uid: u32, backend: &mut dyn Backend) {
    match bp::peer_uid(fd) {
        Ok(uid) if uid == expect_peer_uid => {}
        Ok(uid) => {
            log_line(&format!("reject: peer uid {} != {}", uid, expect_peer_uid));
            return;
        }
        Err(e) => {
            log_line(&format!("reject: peer_uid failed: {}", e));
            return;
        }
    }

    let first = match bp::recv_msg(fd) {
        Ok(Some(m)) => m,
        _ => return,
    };
    if !first.fds.is_empty() || first.ctrunc {
        bp::close_fds(&first.fds);
        log_line("reject: declare with fds");
        return;
    }
    if bp::eor_required() && !first.eor {
        log_line("reject: declare without MSG_EOR");
        return;
    }
    let decl: bp::Declare = match bp::parse_strict(&first.data) {
        Some(d) => d,
        None => {
            let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("bad_request")), &[]);
            return;
        }
    };
    if decl.v != 1 || decl.t != "declare" || decl.rid.is_empty() || decl.rid.len() > 64 {
        let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("bad_request")), &[]);
        return;
    }
    let spec = match bp::scope_spec(&decl.scope) {
        Some(s) => s,
        None => {
            let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("bad_request")), &[]);
            return;
        }
    };
    if !bp::is_uuid(&decl.user_id)
        || (spec.needs_resource != decl.resource.is_some())
        || (spec.needs_resource && !bp::is_uuid(decl.resource.as_deref().unwrap_or("")))
        || decl.budget != bp::budget_map(spec)
        || (spec.needs_gesture && !decl.gesture)
    {
        let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("bad_request")), &[]);
        log_line(&format!("reject: bad declare scope={}", decl.scope));
        return;
    }
    let deadline = bp::monotonic_now() + std::time::Duration::from_secs(bp::RELAY_DEADLINE_SECS);
    let conn = Conn {
        user_id: decl.user_id.clone(),
        scope: decl.scope.clone(),
        resource: decl.resource.clone(),
        budget: decl.budget.clone(),
        deadline,
    };
    log_line(&format!("declared rid={} scope={} resource={}", decl.rid, conn.scope, conn.resource.is_some()));
    if bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::ok(serde_json::json!({"declared": true}))), &[]).is_err() {
        return;
    }

    let mut conn = conn;
    loop {
        let now = bp::monotonic_now();
        if now >= conn.deadline {
            log_line("close: deadline");
            return;
        }
        let remain_ms = (conn.deadline - now).as_millis() as i32;
        match bp::wait_readable(fd, remain_ms) {
            Ok(true) => {}
            Ok(false) => {
                log_line("close: deadline while waiting");
                return;
            }
            Err(_) => return,
        }
        let msg = match bp::recv_msg(fd) {
            Ok(Some(m)) => m,
            _ => return,
        };
        // fd 付き・切り捨て・EOR 無しは不正として切る。fd は即座に閉じる。
        if !msg.fds.is_empty() || msg.ctrunc || (bp::eor_required() && !msg.eor) {
            bp::close_fds(&msg.fds);
            log_line("close: protocol violation (fds/ctrunc/no-eor)");
            return;
        }
        let op: bp::Op = match bp::parse_strict(&msg.data) {
            Some(o) => o,
            None => {
                let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("bad_request")), &[]);
                continue;
            }
        };
        if op.v != 1 || op.t != "op" {
            log_line("close: unexpected message type");
            return;
        }
        let allowed = conn.budget.get(&op.op).copied().unwrap_or(0);
        let resource_ok = match (&conn.resource, op.args.get("id")) {
            (None, _) => true,
            (Some(r), Some(serde_json::Value::String(id))) => r == id,
            (Some(_), _) => false,
        };
        if allowed == 0 || !resource_ok {
            let _ = bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err("forbidden")), &[]);
            log_line(&format!("op forbidden op={} args={}", op.op, shape_of(&serde_json::Value::Object(op.args.clone()))));
            continue;
        }
        *conn.budget.get_mut(&op.op).unwrap() -= 1;
        log_line(&format!("op {} args={}", op.op, shape_of(&serde_json::Value::Object(op.args.clone()))));
        match backend.call(&op.op, &conn.user_id, &op.args) {
            Ok(result) => {
                if bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::ok(result)), &[]).is_err() {
                    return;
                }
            }
            Err(code) => {
                if bp::send_msg(fd, &bp::to_bytes(&bp::OpResult::err(code)), &[]).is_err() {
                    return;
                }
            }
        }
        if conn.budget.values().all(|&n| n == 0) {
            log_line("close: budget exhausted");
            return;
        }
    }
}


#[cfg(target_os = "freebsd")]
fn cap_enter() {
    // 開くものをすべて開いてから能力モードに入る。
    unsafe { libc::cap_enter() };
}

#[cfg(not(target_os = "freebsd"))]
fn cap_enter() {}

fn main() {
    let mut sock_path = "/run/sock/relay/relay.sock".to_string();
    let mut peer_uid: u32 = 2003; // auth の uid
    let mut demo_user = "11111111-1111-4111-8111-111111111111".to_string();
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--sock" => { i += 1; sock_path = args.get(i).cloned().unwrap_or_default(); }
            "--peer-uid" => { i += 1; peer_uid = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(2003); }
            "--demo-user" => { i += 1; demo_user = args.get(i).cloned().unwrap_or_default(); }
            other => { eprintln!("unknown arg: {}", other); std::process::exit(2); }
        }
        i += 1;
    }

    let listener = match bp::seqpacket_listener(&sock_path) {
        Ok(fd) => fd,
        Err(e) => { eprintln!("[relay] listen {}: {}", sock_path, e); std::process::exit(1); }
    };
    cap_enter();
    log_line(&format!("listening on {} (peer uid {})", sock_path, peer_uid));

    let mut backend = StubBackend::new(&demo_user);
    loop {
        let conn = unsafe { libc::accept(listener, std::ptr::null_mut(), std::ptr::null_mut()) };
        if conn < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted { continue; }
            log_line(&format!("accept failed: {}", e));
            continue;
        }
        handle_conn(conn, peer_uid, &mut backend);
        bp::close_fd(conn);
    }
}
