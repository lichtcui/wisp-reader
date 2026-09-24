//! Build HTTP request specs from a book source's `searchUrl` (templates, POST
//! convention, `@js:` L1 resolution, header parsing, URL resolution).

use regex::Regex;

use crate::types::BookSource;

#[derive(Debug, Clone)]
pub struct RequestSpec {
    pub url: String,
    pub method: String,
    pub body: Option<String>,
    pub headers: Vec<(String, String)>,
    pub charset: Option<String>,
    pub no_redirect: bool,
}

/// Build an HTTP request spec from a book source and search keyword.
///
/// Returns `None` when the search URL is a JS pattern v1 cannot resolve
/// (`<js>` blocks or non-L1 `@js:`).
pub fn build_request(source: &BookSource, keyword: &str) -> Option<RequestSpec> {
    let search_url = source.searchUrl.as_deref()?;
    let base_url = &source.bookSourceUrl;

    let effective_url = if search_url.starts_with("@js:") {
        resolve_js_l1(search_url, base_url, keyword)?
    } else if search_url.contains("<js>") {
        return None;
    } else {
        resolve_template(search_url, keyword)
    };

    if let Some(spec) = try_parse_post(&effective_url, base_url) {
        return Some(spec);
    }

    let full_url = resolve_url(&effective_url, base_url);
    Some(RequestSpec {
        url: full_url,
        method: "GET".to_string(),
        body: None,
        headers: Vec::new(),
        charset: None,
        no_redirect: false,
    })
}

/// Resolve `@js:` L1 patterns with Rust-side string processing.
pub fn resolve_js_l1(search_url: &str, base_url: &str, keyword: &str) -> Option<String> {
    let js_body = search_url.strip_prefix("@js:")?;
    let key_enc = urlencoding(keyword);
    let re =
        Regex::new(r#"(?s)url\s*=\s*baseUrl\s*\+\s*"([^"]*)"\s*\+\s*(?:encodeURI\s*\(\s*)?key(?:\))?"#)
            .ok()?;
    if let Some(caps) = re.captures(js_body) {
        let path = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        let path_resolved = resolve_template(path, &key_enc);
        // The matched JS pattern is `baseUrl + "<path>" + key`, so the keyword
        // must be appended after the path (dropping it would break search).
        return Some(format!(
            "{}{}{}",
            base_url.trim_end_matches('/'),
            path_resolved,
            key_enc
        ));
    }
    None
}

fn resolve_template(s: &str, keyword: &str) -> String {
    s.replace("{{key}}", keyword)
        .replace("{{page}}", "1")
        .replace("{{KEY}}", keyword)
}

/// Resolve a possibly-relative URL against a base URL.
pub fn resolve_url(url: &str, base: &str) -> String {
    let url = url.trim();
    if url.is_empty() {
        return String::new();
    }
    if url.starts_with("http://") || url.starts_with("https://") {
        return url.to_string();
    }
    if let Some(rest) = url.strip_prefix("//") {
        if let Some(scheme) = base.split(':').next() {
            return format!("{}://{}", scheme, rest);
        }
        return format!("https://{}", rest);
    }
    if let Some(q) = url.strip_prefix('?') {
        let without_frag = base.split('#').next().unwrap_or(base);
        return format!("{}?{}", without_frag, q);
    }
    if let Some(f) = url.strip_prefix('#') {
        let without_frag = base.split('#').next().unwrap_or(base);
        return format!("{}#{}", without_frag, f);
    }

    let base = if base.starts_with("http://") || base.starts_with("https://") {
        base
    } else {
        return url.to_string();
    };

    let (head, base_path) = match base.find("://") {
        Some(pos) => {
            let rest = &base[pos + 3..];
            match rest.find('/') {
                Some(slash) => (&base[..pos + 3 + slash], &rest[slash..]),
                None => (base, "/"),
            }
        }
        None => ("", base),
    };

    if url.starts_with('/') {
        return format!("{}{}", head, url);
    }

    let base_dir = match base_path.rfind('/') {
        Some(idx) => &base_path[..idx + 1],
        None => "/",
    };
    let joined = format!("{}{}", base_dir, url);
    let mut parts: Vec<&str> = Vec::new();
    for seg in joined.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    format!("{}/{}", head, parts.join("/"))
}

fn try_parse_post(search_url: &str, base_url: &str) -> Option<RequestSpec> {
    if !contains_post_marker(search_url) {
        return None;
    }
    parse_post_request(search_url, base_url)
}

fn contains_post_marker(s: &str) -> bool {
    s.contains("'method':'POST'")
        || s.contains("\"method\":\"POST\"")
        || s.contains("'method':'post'")
        || s.contains("\"method\":\"post\"")
}

pub fn parse_post_request(search_url: &str, base_url: &str) -> Option<RequestSpec> {
    let body = extract_post_body(search_url)?;
    let charset = extract_charset(search_url);

    let url_part = if let Some(pos) = search_url.find(",{") {
        &search_url[..pos]
    } else if let Some(pos) = search_url.find(", {\"method\"") {
        &search_url[..pos]
    } else if let Some(pos) = search_url.find(", {'method'") {
        &search_url[..pos]
    } else {
        search_url
    };

    let full_url = resolve_url(url_part.trim(), base_url);

    Some(RequestSpec {
        url: full_url,
        method: "POST".to_string(),
        body: Some(body),
        headers: Vec::new(),
        charset,
        no_redirect: false,
    })
}

fn extract_post_body(s: &str) -> Option<String> {
    if let Some(start) = s.find("body") {
        let after_key = &s[start + 4..];
        if let Some(colon) = after_key.find(':') {
            let value = after_key[colon + 1..].trim_start();
            if value.starts_with('{') {
                let mut depth = 0i32;
                let mut in_str = false;
                for (i, ch) in value.char_indices() {
                    match ch {
                        '"' | '\'' => in_str = !in_str,
                        '{' if !in_str => depth += 1,
                        '}' if !in_str => {
                            depth -= 1;
                            if depth == 0 {
                                return Some(value[..=i].to_string());
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
    let re_single = Regex::new(r"'body'\s*:\s*'([^']*)'").ok()?;
    if let Some(caps) = re_single.captures(s) {
        return Some(caps[1].to_string());
    }
    let re_double = Regex::new(r#""body"\s*:\s*"([^"]*)""#).ok()?;
    if let Some(caps) = re_double.captures(s) {
        return Some(caps[1].to_string());
    }
    None
}

fn extract_charset(s: &str) -> Option<String> {
    let re_single = Regex::new(r"'charset'\s*:\s*'([^']*)'").ok()?;
    if let Some(caps) = re_single.captures(s) {
        return Some(caps[1].to_string().to_lowercase());
    }
    let re_double = Regex::new(r#""charset"\s*:\s*"([^"]*)""#).ok()?;
    if let Some(caps) = re_double.captures(s) {
        return Some(caps[1].to_string().to_lowercase());
    }
    None
}

/// Build request headers for a source: parse the `header` field and add a
/// `Referer` pointing at the source site unless the source sets one.
pub fn source_headers(source: &BookSource) -> Vec<(String, String)> {
    let mut headers = crate::http_client::parse_headers(source.header.as_deref().unwrap_or(""));
    let has_referer = headers
        .iter()
        .any(|(k, _)| k.eq_ignore_ascii_case("Referer"));
    if !has_referer {
        let base = source
            .bookSourceUrl
            .split('#')
            .next()
            .unwrap_or(&source.bookSourceUrl)
            .trim_end_matches('/');
        if base.starts_with("http://") || base.starts_with("https://") {
            headers.push(("Referer".to_string(), base.to_string()));
        }
    }
    headers
}

/// Merge source headers with a Referer for a specific page.
pub fn page_headers(source_headers: &[(String, String)], page_url: &str) -> Vec<(String, String)> {
    let mut headers: Vec<(String, String)> = source_headers.to_vec();
    let has_referer = headers
        .iter()
        .any(|(k, _)| k.eq_ignore_ascii_case("Referer"));
    if !has_referer && !page_url.is_empty() {
        headers.push(("Referer".to_string(), page_url.to_string()));
    }
    headers
}

fn urlencoding(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(byte as char);
            }
            0x20 => result.push('+'),
            _ => {
                result.push_str(&format!("%{:02X}", byte));
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::BookSource;

    #[test]
    fn test_template_and_resolve() {
        assert_eq!(
            resolve_template("/search?keyword={{key}}&page={{page}}", "测试"),
            "/search?keyword=测试&page=1"
        );
        assert_eq!(
            resolve_url("chapter/1.html", "https://example.com/novel/"),
            "https://example.com/novel/chapter/1.html"
        );
        assert_eq!(
            resolve_url("//cdn.x/a.jpg", "https://example.com"),
            "https://cdn.x/a.jpg"
        );
        // Empty input must stay empty (not fall back to the source base URL).
        assert_eq!(resolve_url("", "https://example.com"), "");
    }

    #[test]
    fn test_post_body_extraction() {
        let s = "/s.php,{'charset':'gbk','body':'searchkey={{key}}','method':'POST'}";
        let spec = parse_post_request(s, "http://example.com/").unwrap();
        assert_eq!(spec.method, "POST");
        assert_eq!(spec.charset.as_deref(), Some("gbk"));
        assert_eq!(spec.body.as_deref(), Some("searchkey={{key}}"));
    }

    #[test]
    fn test_resolve_js_l1() {
        let src = BookSource {
            bookSourceUrl: "https://x.com".into(),
            searchUrl: Some(r#"@js:url = baseUrl + "/search/"+key"#.into()),
            ..Default::default()
        };
        let spec = build_request(&src, "abc").unwrap();
        assert_eq!(spec.url, "https://x.com/search/abc");
    }

    #[test]
    fn test_js_block_returns_none() {
        let src = BookSource {
            bookSourceUrl: "https://x.com".into(),
            searchUrl: Some("<js>1+1</js>".into()),
            ..Default::default()
        };
        assert!(build_request(&src, "abc").is_none());
    }
}