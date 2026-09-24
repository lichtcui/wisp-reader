//! Auto-fix malformed `bookSourceUrl` values and normalize domains.

/// Returns `Some(fixed_url)` if fixable, `None` if irreparably broken.
pub fn fix_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();

    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Some(trimmed.to_string());
    }

    // `[图片]http://...` → strip prefix.
    if let Some(pos) = trimmed.find("http://").or_else(|| trimmed.find("https://"))
        && pos > 0
        && trimmed[..pos].contains("图片")
    {
        return Some(trimmed[pos..].to_string());
    }

    // `http:www.xxx.com` → add slash
    if trimmed.starts_with("http:") && !trimmed.starts_with("http://") {
        return Some(trimmed.replacen("http:", "http://", 1));
    }

    // `www.xxx.com` / `m.xxx.com` → prepend https://
    if trimmed.starts_with("www.") || trimmed.starts_with("m.") {
        return Some(format!("https://{}", trimmed));
    }

    // domain-like, no protocol
    if let Some(dot_pos) = trimmed.find('.') {
        let before_dot = &trimmed[..dot_pos];
        if before_dot
            .chars()
            .next()
            .is_some_and(|c| c.is_alphanumeric())
            && !trimmed.contains(char::is_whitespace)
            && !trimmed.contains("：")
        {
            return Some(format!("https://{}", trimmed));
        }
    }

    None
}

/// Normalize a URL's host to a canonical domain key: lowercase, strip a leading
/// `www.` and any trailing dot, drop the port.
pub fn normalized_domain(url: &str) -> Option<String> {
    let trimmed = url.trim();
    let parsed = url::Url::parse(trimmed)
        .or_else(|_| url::Url::parse(&format!("https://{trimmed}")))
        .ok()?;
    let host = parsed.host_str()?.trim_end_matches('.').to_lowercase();
    Some(host.strip_prefix("www.").unwrap_or(&host).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fix_url() {
        assert_eq!(fix_url("www.example.com"), Some("https://www.example.com".into()));
        assert_eq!(
            fix_url("[图片]http://www.sfacg.com"),
            Some("http://www.sfacg.com".into())
        );
        assert_eq!(fix_url("小说合集"), None);
        assert_eq!(fix_url(""), None);
    }

    #[test]
    fn test_normalized_domain() {
        assert_eq!(
            normalized_domain("https://www.example.com"),
            Some("example.com".into())
        );
        assert_eq!(normalized_domain("example.com"), Some("example.com".into()));
        assert_eq!(normalized_domain("not a url"), None);
    }
}