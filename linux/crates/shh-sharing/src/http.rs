//! Just enough HTTP/1.1 for one JSON request and one JSON reply per connection.
//!
//! It rides inside Tailscale's WireGuard tunnel, so plain HTTP is already
//! encrypted and authenticated end to end.
use serde_json::Value;
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub const MAX_REQUEST: usize = 32 * 1024;

pub struct Request {
    pub method: String,
    pub path: String,
    pub body: Vec<u8>,
    /// The peer's address, as the socket saw it.
    pub remote_ip: Option<String>,
}

pub struct Response {
    pub status: u16,
    pub json: Value,
}

impl Response {
    pub fn error(status: u16, message: &str) -> Response {
        Response { status, json: serde_json::json!({ "error": message }) }
    }
}

/// Called once the reply was written (or wasn't): `true` if the peer got it.
pub type Delivered = Box<dyn FnOnce(bool) + Send>;

pub fn ip_string(addr: &SocketAddr) -> String {
    match addr.ip() {
        IpAddr::V4(a) => a.to_string(),
        // a v4-mapped v6 address is really the v4 one
        IpAddr::V6(a) => match a.to_ipv4_mapped() {
            Some(v4) => v4.to_string(),
            None => a.to_string(),
        },
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Split "head\r\n\r\nbody" once the whole message (per Content-Length) is in.
/// None means keep reading.
pub fn parse(data: &[u8]) -> Option<(Vec<String>, Vec<u8>)> {
    let at = find(data, b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&data[..at]).into_owned();
    let lines: Vec<String> = head.split("\r\n").map(|s| s.to_string()).collect();
    let mut length = 0usize;
    for l in lines.iter().skip(1) {
        if let Some((k, v)) = l.split_once(':') {
            if k.trim().eq_ignore_ascii_case("content-length") {
                length = v.trim().parse().unwrap_or(0);
            }
        }
    }
    let body = &data[at + 4..];
    if body.len() < length {
        return None;
    }
    Some((lines, body[..length].to_vec()))
}

pub fn encode(status: u16, json: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(json).unwrap_or_else(|_| b"{}".to_vec());
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        _ => "Error",
    };
    let mut out = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(&body);
    out
}

pub fn encode_post(host: &str, path: &str, json: &Value) -> Vec<u8> {
    let body = serde_json::to_vec(json).unwrap_or_default();
    let mut out = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(&body);
    out
}

// ---- server ----------------------------------------------------------------

pub type Handler = Arc<dyn Fn(Request) -> (Response, Option<Delivered>) + Send + Sync>;

/// Bound to exactly one local address, so the service is unreachable from any
/// network but the one that address belongs to.
pub struct Server {
    stop: Arc<AtomicBool>,
    pub local: SocketAddr,
}

impl Server {
    pub fn start(host: &str, port: u16, handler: Handler) -> std::io::Result<Server> {
        let ip: IpAddr = host
            .parse()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "not an address"))?;
        let listener = TcpListener::bind(SocketAddr::new(ip, port))?;
        listener.set_nonblocking(true)?;
        let local = listener.local_addr()?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            while !flag.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, addr)) => {
                        let h = handler.clone();
                        std::thread::spawn(move || serve(stream, addr, h));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(150));
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(500)),
                }
            }
        });
        Ok(Server { stop, local })
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Has the far side hung up? Only meaningful once its request is fully read.
fn peer_gone(stream: &TcpStream) -> bool {
    if stream.set_nonblocking(true).is_err() {
        return true;
    }
    let mut b = [0u8; 1];
    let gone = match stream.peek(&mut b) {
        Ok(0) => true,
        Ok(_) => false,
        Err(e) => e.kind() != std::io::ErrorKind::WouldBlock,
    };
    let _ = stream.set_nonblocking(false);
    gone
}

fn serve(mut stream: TcpStream, addr: SocketAddr, handler: Handler) {
    let _ = stream.set_nonblocking(false);
    // a client that connects and says nothing must not hold a socket open
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let (head, body) = loop {
        if let Some(parsed) = parse(&buf) {
            break parsed;
        }
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() || buf.len() > MAX_REQUEST {
            return;
        }
        let _ = stream.set_read_timeout(Some(left));
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        if buf.len() > MAX_REQUEST {
            return;
        }
    };
    let mut first = head.first().map(|s| s.as_str()).unwrap_or("").split(' ').filter(|p| !p.is_empty());
    let req = Request {
        method: first.next().unwrap_or("").to_string(),
        path: first.next().unwrap_or("").to_string(),
        body,
        remote_ip: Some(ip_string(&addr)),
    };
    // the request is in; how long the handler takes is its business (it may be
    // waiting on a person to click Allow)
    let (resp, delivered) = handler(req);
    let ok = !peer_gone(&stream)
        && stream.write_all(&encode(resp.status, &resp.json)).is_ok()
        && stream.flush().is_ok();
    let _ = stream.shutdown(std::net::Shutdown::Both);
    if let Some(d) = delivered {
        d(ok);
    }
}

// ---- client ----------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum ClientError {
    Unreachable(String),
    TimedOut,
    BadReply,
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Unreachable(host) => write!(
                f,
                "Couldn't reach {host}. Check that Tailscale is connected on both machines \
                 and that this one can see the other."
            ),
            ClientError::TimedOut => write!(f, "The other machine didn't answer in time."),
            ClientError::BadReply => {
                write!(f, "The other machine sent a reply shh doesn't understand.")
            }
        }
    }
}

fn connect(host: &str, port: u16, timeout: Duration) -> Option<TcpStream> {
    let addrs = (host, port).to_socket_addrs().ok()?;
    for a in addrs {
        if let Ok(s) = TcpStream::connect_timeout(&a, timeout) {
            return Some(s);
        }
    }
    None
}

/// POST a JSON body; blocks until the reply (status, json) or `timeout`.
pub fn post(host: &str, port: u16, path: &str, json: &Value, timeout: Duration)
    -> Result<(u16, Value), ClientError>
{
    let deadline = std::time::Instant::now() + timeout;
    let mut stream = connect(host, port, Duration::from_secs(10).min(timeout))
        .ok_or_else(|| ClientError::Unreachable(host.to_string()))?;
    stream
        .write_all(&encode_post(host, path, json))
        .map_err(|_| ClientError::Unreachable(host.to_string()))?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if let Some((head, body)) = parse(&buf) {
            let status = head
                .first()
                .and_then(|l| l.split(' ').filter(|p| !p.is_empty()).nth(1))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            return match serde_json::from_slice::<Value>(&body) {
                Ok(v) if v.is_object() => Ok((status, v)),
                _ => Err(ClientError::BadReply),
            };
        }
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Err(ClientError::TimedOut);
        }
        let _ = stream.set_read_timeout(Some(left));
        match stream.read(&mut chunk) {
            Ok(0) => return Err(ClientError::BadReply),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                return Err(ClientError::TimedOut)
            }
            Err(_) => return Err(ClientError::BadReply),
        }
    }
}

/// Is something accepting TCP on host:port?
pub fn probe(host: &str, port: u16, timeout: Duration) -> bool {
    connect(host, port, timeout).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_only_complete_requests() {
        let body = br#"{"token":"t"}"#;
        let mut req = format!("POST /shh/join HTTP/1.1\r\nHost: x\r\ncontent-LENGTH: {}\r\n\r\n", body.len()).into_bytes();
        assert!(parse(&req[..10]).is_none());
        assert!(parse(&req).is_none());
        req.extend_from_slice(&body[..5]);
        assert!(parse(&req).is_none());
        req.extend_from_slice(&body[5..]);
        req.extend_from_slice(b"trailing");
        let (head, got) = parse(&req).unwrap();
        assert_eq!(head[0], "POST /shh/join HTTP/1.1");
        assert_eq!(got, body);
    }

    #[test]
    fn round_trip_over_loopback() {
        let handler: Handler = Arc::new(|req: Request| {
            assert_eq!(req.remote_ip.as_deref(), Some("127.0.0.1"));
            if req.method == "POST" && req.path == "/shh/join" {
                let v: Value = serde_json::from_slice(&req.body).unwrap();
                (Response { status: 200, json: serde_json::json!({"echo": v["token"]}) }, None)
            } else {
                (Response::error(404, "Not found."), None)
            }
        });
        let server = Server::start("127.0.0.1", 0, handler).unwrap();
        let port = server.local.port();
        let (status, json) = post("127.0.0.1", port, "/shh/join",
            &serde_json::json!({"token": "abc"}), Duration::from_secs(5)).unwrap();
        assert_eq!((status, json["echo"].as_str()), (200, Some("abc")));
        let (status, json) = post("127.0.0.1", port, "/nope", &serde_json::json!({}), Duration::from_secs(5)).unwrap();
        assert_eq!((status, json["error"].as_str()), (404, Some("Not found.")));
        assert!(probe("127.0.0.1", port, Duration::from_secs(1)));
        server.stop();
    }
}
