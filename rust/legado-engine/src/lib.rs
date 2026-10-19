//! Legado book-source rule engine — pure Rust core (no NAPI).
//!
//! The ohos crate `legado-core` is a thin NAPI wrapper over this crate; the
//! desktop `bundled-gen` binary also depends on it, so the v1 import gate and
//! bundled-source generation share exactly one implementation.

pub mod gate;
pub mod http_client;
pub mod rule_dsl;
pub mod runtime;
pub mod search_url;
pub mod status;
pub mod types;
pub mod url_fixer;

use types::{Diagnostic, ParseOutput};

/// Extract values from HTML/JSON content applying a single Legado DSL rule.
pub fn parse_values(content: &str, content_type: &str, rule: &str) -> Vec<String> {
    rule_dsl::extract_single(content, content_type, rule)
}

/// Extract values plus rule diagnostics (bad regex / bad CSS / JS).
pub fn parse_with_diagnostics(content: &str, content_type: &str, rule: &str) -> ParseOutput {
    let values = rule_dsl::extract_single(content, content_type, rule);
    let diagnostics: Vec<Diagnostic> = rule_dsl::diagnose(rule);
    ParseOutput { values, diagnostics }
}

/// Fetch a URL as text using a throwaway source (no cookies/rate limit).
pub async fn fetch_text(url: &str) -> Result<String, String> {
    fetch_text_with_timeout(url, runtime::DEFAULT_FETCH_TIMEOUT_MS).await
}

/// Fetch a URL as text with an aggregate timeout around the whole request.
pub async fn fetch_text_with_timeout(url: &str, timeout_ms: u64) -> Result<String, String> {
    runtime::with_operation_timeout(timeout_ms, fetch_text_inner(url)).await
}

async fn fetch_text_inner(url: &str) -> Result<String, String> {
    let source = types::BookSource {
        bookSourceUrl: url.to_string(),
        ..Default::default()
    };
    let client = http_client::engine().client_for(&source);
    let spec = search_url::RequestSpec {
        url: url.to_string(),
        method: "GET".to_string(),
        body: None,
        headers: Vec::new(),
        charset: None,
        no_redirect: false,
    };
    let result = client.fetch(&spec).await.map_err(|e| e.to_string())?;
    Ok(result.body_text)
}
