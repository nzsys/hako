//! box-proto: 箱の部品が共有するプロトコル定義。
use std::collections::BTreeMap;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::RawFd;

use serde::{Deserialize, Serialize};

/// 1メッセージの上限（バイト）。
pub const MAX_MSG: usize = 64 * 1024;

/// 中継の接続の期限（秒）。宣言時点からの絶対時間。
pub const RELAY_DEADLINE_SECS: u64 = 30;


/// 範囲1つ分の定義。`budget` は「操作名 → その接続で許す回数」。
pub struct ScopeSpec {
    pub name: &'static str,
    pub budget: &'static [(&'static str, u32)],
    pub needs_resource: bool,
    pub needs_gesture: bool,
}

pub const SCOPES: &[ScopeSpec] = &[
    ScopeSpec { name: "memo.index",  budget: &[("memo.list", 1)],   needs_resource: false, needs_gesture: true },
    ScopeSpec { name: "memo.show",   budget: &[("memo.get", 1)],    needs_resource: true,  needs_gesture: true },
    ScopeSpec { name: "memo.edit",   budget: &[("memo.get", 1)],    needs_resource: true,  needs_gesture: true },
    ScopeSpec { name: "memo.create", budget: &[("memo.create", 1)], needs_resource: false, needs_gesture: true },
    ScopeSpec { name: "memo.update", budget: &[("memo.update", 1)], needs_resource: true,  needs_gesture: true },
    ScopeSpec { name: "memo.delete", budget: &[("memo.delete", 1)], needs_resource: true,  needs_gesture: true },
];

pub fn scope_spec(name: &str) -> Option<&'static ScopeSpec> {
    SCOPES.iter().find(|s| s.name == name)
}

pub fn budget_map(spec: &ScopeSpec) -> BTreeMap<String, u32> {
    spec.budget.iter().map(|(k, v)| (k.to_string(), *v)).collect()
}

pub fn is_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 36 {
        return false;
    }
    for (i, &c) in b.iter().enumerate() {
        match i {
            8 | 13 | 18 | 23 => {
                if c != b'-' {
                    return false;
                }
            }
            _ => {
                if !c.is_ascii_hexdigit() {
                    return false;
                }
            }
        }
    }
    true
}


/// 中継への宣言（接続の最初の1通）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Declare {
    pub v: u32,
    pub t: String,
    pub rid: String,
    pub user_id: String,
    pub scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
    pub budget: BTreeMap<String, u32>,
    pub gesture: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Op {
    pub v: u32,
    pub t: String,
    pub op: String,
    #[serde(default)]
    pub args: serde_json::Map<String, serde_json::Value>,
}

/// 中継の応答。result と error はどちらか一方だけ。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpResult {
    pub v: u32,
    pub t: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl OpResult {
    pub fn ok(result: serde_json::Value) -> Self {
        OpResult { v: 1, t: "result".into(), ok: true, result: Some(result), error: None }
    }
    pub fn err(code: &str) -> Self {
        OpResult { v: 1, t: "result".into(), ok: false, result: None, error: Some(code.into()) }
    }
}

/// 認証への許可の依頼。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantReq {
    pub v: u32,
    pub t: String,
    pub rid: String,
    pub session: String,
    pub scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
    pub gesture: bool,
}

/// 認証の応答。`t = "granted"` のときは中継の接続の fd が1つ付く。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantRes {
    pub v: u32,
    pub t: String,
    pub rid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 振り分けへの依頼。`t = "alloc"` | `"release"`。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DispReq {
    pub v: u32,
    pub t: String,
    pub rid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot: Option<u32>,
}

/// 振り分けの応答。`t = "allocated"` のときは fd が2つ付く:
/// [0] = スロットの受け取り口（エッジが中継の fd を送る側）、
/// [1] = FastCGI の接続済み fd（ゲートウェイが使う側）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DispRes {
    pub v: u32,
    pub t: String,
    pub rid: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// JSON を厳格に読む。UTF-8 でない、末尾にゴミがある、未知の属性がある場合は None。
pub fn parse_strict<T: serde::de::DeserializeOwned>(data: &[u8]) -> Option<T> {
    if data.is_empty() || data.len() > MAX_MSG {
        return None;
    }
    serde_json::from_slice(data).ok()
}

pub fn to_bytes<T: Serialize>(v: &T) -> Vec<u8> {
    serde_json::to_vec(v).expect("serialize")
}


pub fn monotonic_now() -> std::time::Duration {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    std::time::Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}


pub fn send_msg(fd: RawFd, data: &[u8], fds: &[RawFd]) -> io::Result<()> {
    if data.len() > MAX_MSG || fds.len() > 4 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "message too large"));
    }
    let mut iov = libc::iovec { iov_base: data.as_ptr() as *mut libc::c_void, iov_len: data.len() };
    let mut cbuf = [0u8; 128];
    let mut hdr: libc::msghdr = unsafe { std::mem::zeroed() };
    hdr.msg_iov = &mut iov;
    hdr.msg_iovlen = 1;
    if !fds.is_empty() {
        let space = unsafe { libc::CMSG_SPACE((fds.len() * std::mem::size_of::<RawFd>()) as u32) } as usize;
        hdr.msg_control = cbuf.as_mut_ptr() as *mut libc::c_void;
        hdr.msg_controllen = space as _;
        let cmsg = unsafe { libc::CMSG_FIRSTHDR(&hdr) };
        unsafe {
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN((fds.len() * std::mem::size_of::<RawFd>()) as u32) as _;
            let dst = libc::CMSG_DATA(cmsg) as *mut RawFd;
            for (i, f) in fds.iter().enumerate() {
                std::ptr::write(dst.add(i), *f);
            }
        }
    }
    loop {
        let n = unsafe { libc::sendmsg(fd, &hdr, libc::MSG_EOR) };
        if n >= 0 {
            if n as usize != data.len() {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "short sendmsg"));
            }
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

pub struct RecvMsg {
    pub data: Vec<u8>,
    pub fds: Vec<RawFd>,
    /// MSG_EOR が立っていたか。立っていないレコードは不正として扱う。
    pub eor: bool,
    /// 制御メッセージが切り捨てられた（fd が溢れた）か。
    pub ctrunc: bool,
}

/// MSG_EOR の検査を必須とするか。FreeBSD では MSG_EOR がレコード境界を担うため必須。それ以外の環境では SOCK_SEQPACKET の境界だけに頼る（Linux の AF_UNIX では受信側に MSG_EOR が立たない）。
pub fn eor_required() -> bool {
    cfg!(target_os = "freebsd")
}

pub fn recv_msg(fd: RawFd) -> io::Result<Option<RecvMsg>> {
    let mut buf = vec![0u8; MAX_MSG + 1];
    let mut iov = libc::iovec { iov_base: buf.as_mut_ptr() as *mut libc::c_void, iov_len: buf.len() };
    let mut cbuf = [0u8; 128];
    let mut hdr: libc::msghdr = unsafe { std::mem::zeroed() };
    hdr.msg_iov = &mut iov;
    hdr.msg_iovlen = 1;
    hdr.msg_control = cbuf.as_mut_ptr() as *mut libc::c_void;
    hdr.msg_controllen = cbuf.len() as _;
    let n = loop {
        let n = unsafe { libc::recvmsg(fd, &mut hdr, 0) };
        if n >= 0 {
            break n;
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    };
    if n == 0 && hdr.msg_controllen == 0 {
        return Ok(None);
    }
    buf.truncate(n as usize);
    let mut fds = Vec::new();
    let mut cmsg = unsafe { libc::CMSG_FIRSTHDR(&hdr) };
    while !cmsg.is_null() {
        let c = unsafe { &*cmsg };
        if c.cmsg_level == libc::SOL_SOCKET && c.cmsg_type == libc::SCM_RIGHTS {
            let count = (c.cmsg_len as usize - unsafe { libc::CMSG_LEN(0) } as usize)
                / std::mem::size_of::<RawFd>();
            let src = unsafe { libc::CMSG_DATA(cmsg) } as *const RawFd;
            for i in 0..count {
                fds.push(unsafe { std::ptr::read(src.add(i)) });
            }
        }
        cmsg = unsafe { libc::CMSG_NXTHDR(&hdr, cmsg) };
    }
    Ok(Some(RecvMsg {
        data: buf,
        fds,
        eor: hdr.msg_flags & libc::MSG_EOR != 0,
        ctrunc: hdr.msg_flags & libc::MSG_CTRUNC != 0,
    }))
}

/// 余分に受け取った fd を全部閉じる。
pub fn close_fds(fds: &[RawFd]) {
    for &f in fds {
        unsafe { libc::close(f) };
    }
}

pub fn close_fd(fd: RawFd) {
    unsafe { libc::close(fd) };
}

pub fn wait_readable(fd: RawFd, timeout_ms: i32) -> io::Result<bool> {
    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    loop {
        let n = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
        if n >= 0 {
            return Ok(n > 0 && pfd.revents & (libc::POLLIN | libc::POLLHUP) != 0);
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}


/// SOCK_SEQPACKET の待ち受けソケットを作る。古いソケットファイルは消す。パーミッションは 0660。
pub fn seqpacket_listener(path: &str) -> io::Result<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let addr = sockaddr_un(path)?;
    unsafe { libc::unlink(addr.sun_path.as_ptr()) };
    if unsafe { libc::bind(fd, &addr as *const libc::sockaddr_un as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_un>() as u32) } < 0 {
        let e = io::Error::last_os_error();
        close_fd(fd);
        return Err(e);
    }
    unsafe { libc::chmod(addr.sun_path.as_ptr(), 0o660) };
    if unsafe { libc::listen(fd, 64) } < 0 {
        let e = io::Error::last_os_error();
        close_fd(fd);
        return Err(e);
    }
    Ok(fd)
}

pub fn seqpacket_connect(path: &str) -> io::Result<RawFd> {
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let addr = sockaddr_un(path)?;
    if unsafe { libc::connect(fd, &addr as *const libc::sockaddr_un as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_un>() as u32) } < 0 {
        let e = io::Error::last_os_error();
        close_fd(fd);
        return Err(e);
    }
    Ok(fd)
}

fn sockaddr_un(path: &str) -> io::Result<libc::sockaddr_un> {
    let bytes = std::ffi::OsStr::new(path).as_bytes();
    if bytes.len() >= 104 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "socket path too long"));
    }
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as _;
    for (i, &b) in bytes.iter().enumerate() {
        addr.sun_path[i] = b as _;
    }
    Ok(addr)
}

/// 接続してきた相手の uid を返す（LOCAL_PEERCRED）。
#[cfg(target_os = "freebsd")]
pub fn peer_uid(fd: RawFd) -> io::Result<u32> {
    let mut cred: libc::xucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::xucred>() as u32;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            0, // SOL_LOCAL
            libc::LOCAL_PEERCRED,
            &mut cred as *mut libc::xucred as *mut libc::c_void,
            &mut len,
        )
    };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cred.cr_uid)
}

#[cfg(target_os = "linux")]
pub fn peer_uid(fd: RawFd) -> io::Result<u32> {
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as u32;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut libc::ucred as *mut libc::c_void,
            &mut len,
        )
    };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cred.uid)
}

#[cfg(not(any(target_os = "freebsd", target_os = "linux")))]
pub fn peer_uid(_fd: RawFd) -> io::Result<u32> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "peer_uid"))
}
