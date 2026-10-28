//! box-adapter: ホスト上で動く入口。
use std::io::{Read, Write};
use std::os::unix::io::{FromRawFd, RawFd};

use box_proto as bp;

static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn next_rid() -> String {
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{}-{}", std::process::id(), n)
}


#[derive(Clone)]
struct Config {
    disp_sock: String,
    auth_sock: String,
    docroot: String, // スロット内でのパス（/app/public）
}

fn log_line(msg: &str) {
    eprintln!("[adapter] {}", msg);
}


struct Route {
    scope: &'static str,
    resource: Option<String>,
    is_write: bool,
}

fn parse_route(method: &str, path: &str) -> Option<Route> {
    let seg: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let is_uuid = |s: &str| bp::is_uuid(s);
    match (method, seg.as_slice()) {
        ("GET", ["memos"]) => Some(Route { scope: "memo.index", resource: None, is_write: false }),
        ("POST", ["memos"]) => Some(Route { scope: "memo.create", resource: None, is_write: true }),
        ("GET", ["memos", "new"]) => Some(Route { scope: "memo.create", resource: None, is_write: false }),
        ("GET", ["memos", id]) if is_uuid(id) => {
            Some(Route { scope: "memo.show", resource: Some(id.to_string()), is_write: false })
        }
        ("GET", ["memos", id, "edit"]) if is_uuid(id) => {
            Some(Route { scope: "memo.edit", resource: Some(id.to_string()), is_write: false })
        }
        ("POST", ["memos", id]) if is_uuid(id) => {
            Some(Route { scope: "memo.update", resource: Some(id.to_string()), is_write: true })
        }
        ("POST", ["memos", id, "delete"]) if is_uuid(id) => {
            Some(Route { scope: "memo.delete", resource: Some(id.to_string()), is_write: true })
        }
        _ => None,
    }
}


struct HttpReq {
    method: String,
    target: String, // パス + クエリ
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl HttpReq {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

fn read_http(stream: &mut std::net::TcpStream) -> Option<HttpReq> {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let head_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > bp::MAX_MSG {
            return None;
        }
        match stream.read(&mut chunk) {
            Ok(0) => return None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(_) => return None,
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.lines();
    let first = lines.next()?;
    let mut parts = first.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    let path = target.split('?').next().unwrap_or("/").to_string();
    let mut req = HttpReq { method, target, path, headers, body: Vec::new() };
    if req.header("transfer-encoding").is_some() {
        return None; // chunked は扱わない
    }
    let len: usize = req.header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    if len > bp::MAX_MSG {
        return None;
    }
    let mut body = buf.split_off(head_end);
    while body.len() < len {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
            Err(_) => return None,
        }
    }
    body.truncate(len);
    req.body = body;
    Some(req)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn respond(stream: &mut std::net::TcpStream, status: u16, reason: &str, ctype: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        status, reason, ctype, body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

fn respond_text(stream: &mut std::net::TcpStream, status: u16, reason: &str, text: &str) {
    respond(stream, status, reason, "text/plain; charset=utf-8", text.as_bytes());
}


fn disp_alloc(cfg: &Config, rid: &str) -> Result<(u32, RawFd, RawFd), String> {
    let fd = bp::seqpacket_connect(&cfg.disp_sock).map_err(|e| e.to_string())?;
    let req = bp::DispReq { v: 1, t: "alloc".into(), rid: rid.to_string(), slot: None };
    let out = (|| -> Option<(u32, RawFd, RawFd)> {
        bp::send_msg(fd, &bp::to_bytes(&req), &[]).ok()?;
        let res = bp::recv_msg(fd).ok()??;
        if res.ctrunc || (bp::eor_required() && !res.eor) {
            bp::close_fds(&res.fds);
            return None;
        }
        let r: bp::DispRes = bp::parse_strict(&res.data)?;
        if r.t != "allocated" || res.fds.len() != 2 {
            bp::close_fds(&res.fds);
            return None;
        }
        Some((r.slot?, res.fds[0], res.fds[1]))
    })();
    bp::close_fd(fd);
    out.ok_or_else(|| "alloc failed".to_string())
}

fn disp_release(cfg: &Config, rid: &str, slot: u32) {
    if let Ok(fd) = bp::seqpacket_connect(&cfg.disp_sock) {
        let req = bp::DispReq { v: 1, t: "release".into(), rid: rid.to_string(), slot: Some(slot) };
        let _ = bp::send_msg(fd, &bp::to_bytes(&req), &[]);
        let _ = bp::recv_msg(fd);
        bp::close_fd(fd);
    }
}

fn grant(cfg: &Config, rid: &str, session: &str, route: &Route, gesture: bool) -> Result<RawFd, String> {
    let fd = bp::seqpacket_connect(&cfg.auth_sock).map_err(|e| e.to_string())?;
    let req = bp::GrantReq {
        v: 1,
        t: "grant".into(),
        rid: rid.to_string(),
        session: session.to_string(),
        scope: route.scope.to_string(),
        resource: route.resource.clone(),
        gesture,
    };
    let out = (|| -> Option<RawFd> {
        bp::send_msg(fd, &bp::to_bytes(&req), &[]).ok()?;
        let res = bp::recv_msg(fd).ok()??;
        if res.ctrunc || (bp::eor_required() && !res.eor) {
            bp::close_fds(&res.fds);
            return None;
        }
        let r: bp::GrantRes = bp::parse_strict(&res.data)?;
        if r.t != "granted" || res.fds.len() != 1 {
            bp::close_fds(&res.fds);
            return None;
        }
        Some(res.fds[0])
    })();
    bp::close_fd(fd);
    out.ok_or_else(|| "denied".to_string())
}


const FCGI_BEGIN: u8 = 1;
const FCGI_END: u8 = 3;
const FCGI_PARAMS: u8 = 4;
const FCGI_STDIN: u8 = 5;
const FCGI_STDOUT: u8 = 6;
const FCGI_STDERR: u8 = 7;

fn fcgi_record(out: &mut Vec<u8>, typ: u8, req_id: u16, content: &[u8]) {
    out.push(1);
    out.push(typ);
    out.extend_from_slice(&req_id.to_be_bytes());
    out.extend_from_slice(&(content.len() as u16).to_be_bytes());
    out.push(0);
    out.push(0);
    out.extend_from_slice(content);
}

fn fcgi_param(out: &mut Vec<u8>, name: &str, value: &str) {
    let enc = |out: &mut Vec<u8>, n: usize| {
        if n < 128 {
            out.push(n as u8);
        } else {
            out.extend_from_slice(&((n as u32) | 0x8000_0000).to_be_bytes());
        }
    };
    enc(out, name.len());
    enc(out, value.len());
    out.extend_from_slice(name.as_bytes());
    out.extend_from_slice(value.as_bytes());
}

fn fastcgi_call(fcgi_fd: RawFd, req: &HttpReq, cfg: &Config) -> Result<(u16, Vec<(String, String)>, Vec<u8>), String> {
    let mut stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fcgi_fd) };
    stream.set_read_timeout(Some(std::time::Duration::from_secs(35))).map_err(|e| e.to_string())?;
    let mut out: Vec<u8> = Vec::new();
    // BEGIN_REQUEST: role=responder(1), flags=0
    fcgi_record(&mut out, FCGI_BEGIN, 1, &[0, 1, 0, 0, 0, 0, 0, 0]);
    // PARAMS
    let mut params: Vec<u8> = Vec::new();
    let script = format!("{}/index.php", cfg.docroot);
    fcgi_param(&mut params, "REQUEST_METHOD", &req.method);
    fcgi_param(&mut params, "REQUEST_URI", &req.target);
    fcgi_param(&mut params, "SCRIPT_NAME", "/index.php");
    fcgi_param(&mut params, "SCRIPT_FILENAME", &script);
    fcgi_param(&mut params, "QUERY_STRING", req.target.split('?').nth(1).unwrap_or(""));
    fcgi_param(&mut params, "CONTENT_TYPE", req.header("content-type").unwrap_or(""));
    fcgi_param(&mut params, "CONTENT_LENGTH", &req.body.len().to_string());
    fcgi_param(&mut params, "SERVER_PROTOCOL", "HTTP/1.1");
    fcgi_param(&mut params, "GATEWAY_INTERFACE", "CGI/1.1");
    for (k, v) in &req.headers {
        let name = format!("HTTP_{}", k.to_uppercase().replace('-', "_"));
        fcgi_param(&mut params, &name, v);
    }
    fcgi_record(&mut out, FCGI_PARAMS, 1, &params);
    fcgi_record(&mut out, FCGI_PARAMS, 1, &[]);
    // STDIN
    fcgi_record(&mut out, FCGI_STDIN, 1, &req.body);
    fcgi_record(&mut out, FCGI_STDIN, 1, &[]);
    stream.write_all(&out).map_err(|e| e.to_string())?;

    // 応答: END_REQUEST まで読む。STDOUT を集め、STDERR は長さだけ記録する。
    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr_len = 0usize;
    let mut hdr = [0u8; 8];
    loop {
        stream.read_exact(&mut hdr).map_err(|e| format!("fcgi read: {}", e))?;
        let typ = hdr[1];
        let req_id = u16::from_be_bytes([hdr[2], hdr[3]]);
        let clen = u16::from_be_bytes([hdr[4], hdr[5]]) as usize;
        let plen = hdr[6] as usize;
        let mut content = vec![0u8; clen];
        stream.read_exact(&mut content).map_err(|e| e.to_string())?;
        if plen > 0 {
            let mut pad = vec![0u8; plen];
            stream.read_exact(&mut pad).map_err(|e| e.to_string())?;
        }
        if req_id != 1 {
            continue;
        }
        match typ {
            FCGI_STDOUT => stdout.extend_from_slice(&content),
            FCGI_STDERR => stderr_len += clen,
            FCGI_END => {
                if content.len() >= 5 && content[4] != 0 {
                    return Err(format!("fcgi protocol status {}", content[4]));
                }
                break;
            }
            _ => {}
        }
    }
    if stderr_len > 0 {
        log_line(&format!("app stderr: {} bytes (content not stored, I19)", stderr_len));
    }
    let split = find(&stdout, b"\r\n\r\n").map(|p| p + 4).or_else(|| find(&stdout, b"\n\n").map(|p| p + 2));
    let (head_bytes, body) = match split {
        Some(p) => (&stdout[..p], stdout[p..].to_vec()),
        None => (&[][..], stdout),
    };
    let head = String::from_utf8_lossy(head_bytes).to_string();
    let mut status: u16 = 200;
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in head.lines() {
        if let Some((k, v)) = line.split_once(':') {
            let (k, v) = (k.trim().to_string(), v.trim().to_string());
            if k.eq_ignore_ascii_case("status") {
                status = v.split_whitespace().next().and_then(|s| s.parse().ok()).unwrap_or(200);
            } else {
                headers.push((k, v));
            }
        }
    }
    Ok((status, headers, body))
}


fn handle(mut stream: std::net::TcpStream, cfg: Config) {
    let req = match read_http(&mut stream) {
        Some(r) => r,
        None => {
            respond_text(&mut stream, 400, "Bad Request", "bad request\n");
            return;
        }
    };
    let route = match parse_route(&req.method, &req.path) {
        Some(r) => r,
        None => {
            respond_text(&mut stream, 404, "Not Found", "not found\n");
            return;
        }
    };
    let gesture = req.header("sec-fetch-user") == Some("?1");
    if route.is_write {
        let site = req.header("sec-fetch-site").unwrap_or("");
        if !site.is_empty() && site != "same-origin" {
            respond_text(&mut stream, 403, "Forbidden", "forbidden\n");
            return;
        }
    }
    if !gesture {
        // 利用者の操作でない遷移・送信には範囲を与えない。
        respond_text(&mut stream, 403, "Forbidden", "forbidden (no user gesture)\n");
        return;
    }
    // セッション Cookie（box_session）。
    let session = req
        .header("cookie")
        .and_then(|c| c.split(';').find_map(|p| p.trim().strip_prefix("box_session=")))
        .unwrap_or("")
        .to_string();

    let rid = next_rid();
    let (slot, recv_fd, fcgi_fd) = match disp_alloc(&cfg, &rid) {
        Ok(v) => v,
        Err(_) => {
            respond_text(&mut stream, 503, "Service Unavailable", "no slot\n");
            return;
        }
    };
    // ここからはどの経路でも release する。
    let result = (|| -> Result<(u16, Vec<(String, String)>, Vec<u8>), (u16, &'static str)> {
        let relay_fd = match grant(&cfg, &rid, &session, &route, gesture) {
            Ok(f) => f,
            Err(_) => {
                bp::close_fd(recv_fd);
                bp::close_fd(fcgi_fd);
                return Err((401, "unauthorized"));
            }
        };
        // 中継の fd を受け取り口へ（1回だけ）。自分の複製は閉じる。
        let sent = bp::send_msg(recv_fd, b"{}", &[relay_fd]);
        bp::close_fd(relay_fd);
        bp::close_fd(recv_fd);
        if sent.is_err() {
            bp::close_fd(fcgi_fd);
            return Err((502, "bad gateway"));
        }
        let (status, headers, body) = fastcgi_call(fcgi_fd, &req, &cfg).map_err(|_| (502, "bad gateway"))?;
        // 303 は POST の応答にだけ許す。GET 応答の 303 や未知の 3xx は 502 にする。
        let status = if route.is_write {
            status
        } else if status == 303 || (300..400).contains(&status) {
            502
        } else {
            status
        };
        Ok((status, headers, body))
    })();
    disp_release(&cfg, &rid, slot);
    match result {
        Ok((status, headers, body)) => {
            let ctype = headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| "text/html; charset=utf-8".to_string());
            let location = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("location")).map(|(_, v)| v.clone());
            let mut head = format!(
                "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
                status,
                reason_phrase(status),
                ctype,
                body.len()
            );
            if let Some(loc) = location {
                head += &format!("Location: {}\r\n", loc);
            }
            head += "\r\n";
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body);
        }
        Err((status, msg)) => {
            respond_text(&mut stream, status, reason_phrase(status), &format!("{}\n", msg));
        }
    }
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        303 => "See Other",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn main() {
    let mut listen = "127.0.0.1:8080".to_string();
    let mut cfg = Config {
        disp_sock: "/var/jails/sock/disp/disp.sock".into(),
        auth_sock: "/var/jails/sock/auth/auth.sock".into(),
        docroot: "/app/public".into(),
    };
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--listen" => { i += 1; listen = args.get(i).cloned().unwrap_or_default(); }
            "--disp-sock" => { i += 1; cfg.disp_sock = args.get(i).cloned().unwrap_or_default(); }
            "--auth-sock" => { i += 1; cfg.auth_sock = args.get(i).cloned().unwrap_or_default(); }
            "--docroot" => { i += 1; cfg.docroot = args.get(i).cloned().unwrap_or_default(); }
            other => { eprintln!("unknown arg: {}", other); std::process::exit(2); }
        }
        i += 1;
    }
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let listener = std::net::TcpListener::bind(&listen).unwrap_or_else(|e| {
        eprintln!("[adapter] bind {}: {}", listen, e);
        std::process::exit(1);
    });
    log_line(&format!("listening on {} (stage0: edge+gateway combined)", listen));
    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let cfg2 = cfg.clone();
                std::thread::spawn(move || handle(s, cfg2));
            }
            Err(_) => continue,
        }
    }
}
