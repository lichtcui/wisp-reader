//! HTTP client: rustls TLS, per-source cookie isolation, encoding detection and
//! per-domain rate limiting.
//!
//! Security: `danger_accept_invalid_certs` is deliberately NOT used — the app
//! must never disable certificate validation.

// ─── 文件索引（改本文件先看这里）─────────────────────────────────────
//   定位用 `grep -n "<名字>" rust/legado-engine/src/http_client.rs`。
//   取 client：    engine()（全局单例）/ Engine / client_for（每源一个，Cookie 隔离，MAX_CLIENTS=64 后回收）
//   发请求：      SourceClient::fetch（限速 concurrentRate）/ FetchResult / RequestSpec（见 search_url.rs）
//   失败分类：    FetchError / FailReason / classify_status（HTTP 码 → 失败原因）/ looks_like_tls / fail_reason
//   头与编码：    parse_headers / decode_body / extract_charset_from_header / USER_AGENT / domain_of
//   注意：切 TLS 行为/证书校验前先看本文件头部的安全注释（禁止放行）
// ──────────────────────────────────────────────────────────────────────

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use encoding_rs::Encoding;
use reqwest::{Client, ClientBuilder};
use tokio::sync::Mutex as AsyncMutex;

use crate::search_url::RequestSpec;
use crate::status::FailReason;
use crate::types::{parse_concurrent_rate, BookSource};
use crate::url_fixer::normalized_domain;

pub const USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

#[derive(Debug)]
pub enum FetchError {
    Timeout(String),
    Connect(String),
    Tls(String),
    Server { status: u16, url: String },
    Http { status: u16 },
    Body(String),
    Other(String),
}

impl FetchError {
    pub fn fail_reason(&self) -> FailReason {
        match self {
            FetchError::Timeout(_) => FailReason::Timeout,
            FetchError::Server { .. } => FailReason::ServerError,
            FetchError::Http { status } => classify_status(*status),
            _ => FailReason::NetworkError,
        }
    }

    fn classify(err: reqwest::Error) -> FetchError {
        if err.is_timeout() {
            return FetchError::Timeout(err.to_string());
        }
        if err.is_connect() {
            return FetchError::Connect(err.to_string());
        }
        if let Some(status) = err.status()
            && status.as_u16() >= 500
        {
            return FetchError::Server {
                status: status.as_u16(),
                url: err.url().map(|u| u.to_string()).unwrap_or_default(),
            };
        }
        if looks_like_tls(&err) {
            return FetchError::Tls(err.to_string());
        }
        if err.is_body() || err.is_decode() {
            return FetchError::Body(err.to_string());
        }
        FetchError::Other(err.to_string())
    }
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::Timeout(e) => write!(f, "timeout: {e}"),
            FetchError::Connect(e) => write!(f, "connect failed: {e}"),
            FetchError::Tls(e) => write!(f, "tls error: {e}"),
            FetchError::Server { status, url } => write!(f, "HTTP {status} for {url}"),
            FetchError::Http { status } => write!(f, "HTTP {status}"),
            FetchError::Body(e) => write!(f, "body error: {e}"),
            FetchError::Other(e) => write!(f, "request error: {e}"),
        }
    }
}

pub fn classify_status(status: u16) -> FailReason {
    match status {
        401 | 403 => FailReason::Blocked,
        404 => FailReason::NotFound,
        408 | 429 => FailReason::RateLimited,
        500..=599 => FailReason::ServerError,
        _ => FailReason::HttpError,
    }
}

fn looks_like_tls(err: &reqwest::Error) -> bool {
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(err);
    for _ in 0..8 {
        let Some(src) = cur else { break };
        let d = format!("{src:?}").to_lowercase();
        if d.contains("tls")
            || d.contains("handshake")
            || d.contains("certificate")
            || d.contains("rustls")
            || d.contains("ssl")
        {
            return true;
        }
        cur = src.source();
    }
    false
}

#[derive(Debug)]
pub struct FetchResult {
    pub body_text: String,
    pub body_bytes: Vec<u8>,
    pub content_type: String,
    pub status_code: u16,
    pub elapsed_ms: u64,
    pub charset_detected: Option<String>,
    pub charset_uncertain: bool,
}

/// A reqwest client bound to one book source (cookie isolation) with an
/// optional minimum inter-request interval from `concurrentRate`.
pub struct SourceClient {
    client: Client,
    no_redirect_client: Client,
    rate: Option<Duration>,
    last: AsyncMutex<Option<Instant>>,
}

impl SourceClient {
    fn build() -> (Client, Client) {
        let client = ClientBuilder::new()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(10))
            .user_agent(USER_AGENT)
            .gzip(true)
            .cookie_store(true)
            .build()
            .unwrap_or_else(|_| Client::new());
        let no_redirect_client = ClientBuilder::new()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(10))
            .user_agent(USER_AGENT)
            .gzip(true)
            .cookie_store(true)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap_or_else(|_| Client::new());
        (client, no_redirect_client)
    }

    async fn rate_limit_acquire(&self) {
        let Some(interval) = self.rate else { return };
        let mut last = self.last.lock().await;
        if let Some(prev) = *last {
            let elapsed = prev.elapsed();
            if elapsed < interval {
                tokio::time::sleep(interval - elapsed).await;
            }
        }
        *last = Some(Instant::now());
    }

    pub async fn fetch(&self, spec: &RequestSpec) -> Result<FetchResult, FetchError> {
        self.rate_limit_acquire().await;
        let start = Instant::now();
        let client = if spec.no_redirect {
            &self.no_redirect_client
        } else {
            &self.client
        };

        let response = match spec.method.as_str() {
            "POST" => {
                let mut req = client.post(&spec.url);
                if let Some(ref body) = spec.body {
                    req = req.body(body.clone());
                }
                let has_ct = spec
                    .headers
                    .iter()
                    .any(|(k, _)| k.eq_ignore_ascii_case("content-type"));
                if !has_ct {
                    req = req.header(
                        reqwest::header::CONTENT_TYPE,
                        "application/x-www-form-urlencoded",
                    );
                }
                for (k, v) in &spec.headers {
                    req = req.header(k, v);
                }
                req.send().await.map_err(FetchError::classify)?
            }
            _ => {
                let mut req = client.get(&spec.url);
                for (k, v) in &spec.headers {
                    req = req.header(k, v);
                }
                req.send().await.map_err(FetchError::classify)?
            }
        };

        let status_code = response.status().as_u16();
        if status_code >= 400 {
            return Err(FetchError::Http { status: status_code });
        }

        let content_type = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();

        let elapsed_ms = start.elapsed().as_millis() as u64;
        let body_bytes = response.bytes().await.map_err(FetchError::classify)?.to_vec();
        let (body_text, charset_detected, charset_uncertain) =
            decode_body(&body_bytes, &content_type, &spec.charset);

        Ok(FetchResult {
            body_text,
            body_bytes,
            content_type,
            status_code,
            elapsed_ms,
            charset_detected,
            charset_uncertain,
        })
    }
}

/// Process-wide client pool, keyed by `bookSourceUrl`.
pub struct Engine {
    clients: Mutex<HashMap<String, Arc<SourceClient>>>,
}

const MAX_CLIENTS: usize = 64;

impl Engine {
    pub fn client_for(&self, source: &BookSource) -> Arc<SourceClient> {
        let key = source.bookSourceUrl.clone();
        let mut map = self.clients.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(c) = map.get(&key) {
            return c.clone();
        }
        if map.len() >= MAX_CLIENTS {
            map.clear();
        }
        let rate = parse_concurrent_rate(source.concurrentRate.as_ref());
        let (client, no_redirect_client) = SourceClient::build();
        let sc = Arc::new(SourceClient {
            client,
            no_redirect_client,
            rate,
            last: AsyncMutex::new(None),
        });
        map.insert(key, sc.clone());
        sc
    }
}

pub fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| Engine {
        clients: Mutex::new(HashMap::new()),
    })
}

/// Parse the Python-dict style header string into key-value pairs.
pub fn parse_headers(header_str: &str) -> Vec<(String, String)> {
    let mut headers = Vec::new();
    if header_str.is_empty() {
        return headers;
    }
    // 静态正则：`parse_headers` 每条源请求都会走，`Regex::new` 每次编译约几十µs。
    static HEADER_RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = HEADER_RE.get_or_init(|| {
        regex::Regex::new(r#"['"]([^'"]+)['"]\s*:\s*['"]([^'"]*)['"]"#)
            .expect("static header regex is valid")
    });
    for cap in re.captures_iter(header_str) {
        headers.push((cap[1].to_string(), cap[2].to_string()));
    }
    headers
}

fn decode_body(
    bytes: &[u8],
    content_type: &str,
    url_charset: &Option<String>,
) -> (String, Option<String>, bool) {
    if let Some(charset_str) = extract_charset_from_header(content_type)
        && let Some(encoding) = Encoding::for_label(charset_str.as_bytes())
    {
        let (text, _, _) = encoding.decode(bytes);
        return (text.into_owned(), Some(charset_str), false);
    }
    if let Some(charset) = url_charset
        && let Some(encoding) = Encoding::for_label(charset.as_bytes())
    {
        let (text, _, had_errors) = encoding.decode(bytes);
        if !had_errors {
            return (text.into_owned(), Some(charset.clone()), false);
        }
    }
    let mut detector = chardetng::EncodingDetector::new();
    detector.feed(bytes, bytes.len() < 1024);
    let encoding = detector.guess(None, true);
    let (text, _, had_errors) = encoding.decode(bytes);
    let name = encoding.name().to_lowercase();
    let uncertain = had_errors || bytes.len() < 64;
    (text.into_owned(), Some(name), uncertain)
}

fn extract_charset_from_header(content_type: &str) -> Option<String> {
    let lower = content_type.to_lowercase();
    let pos = lower.find("charset=")?;
    let rest = &lower[pos + 8..];
    let charset = rest.split([';', ' ', ',']).next().unwrap_or("");
    if charset.is_empty() {
        None
    } else {
        Some(charset.to_string())
    }
}

/// Normalized domain helper re-exported for rate/HTTP call sites.
pub fn domain_of(url: &str) -> Option<String> {
    normalized_domain(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_headers() {
        let h = parse_headers("{'User-Agent': 'Mozilla/5.0', \"Referer\": \"https://x\"}");
        assert_eq!(h.len(), 2);
        assert_eq!(h[0].0, "User-Agent");
    }

    #[test]
    fn test_extract_charset_from_header() {
        assert_eq!(
            extract_charset_from_header("text/html; charset=gbk"),
            Some("gbk".into())
        );
        assert_eq!(extract_charset_from_header("text/html"), None);
    }

    #[test]
    fn test_classify_status() {
        assert_eq!(classify_status(403), FailReason::Blocked);
        assert_eq!(classify_status(404), FailReason::NotFound);
        assert_eq!(classify_status(429), FailReason::RateLimited);
        assert_eq!(classify_status(503), FailReason::ServerError);
    }
}