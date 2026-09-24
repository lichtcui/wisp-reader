//! HarmonyOS NAPI bindings over `legado-engine`.
//!
//! All structured data crosses the boundary as JSON strings (coarse-grained),
//! matching the architecture in `docs/architecture.md`: input a full JSON, get
//! a structured JSON back; no per-field cross-language callbacks.

use napi_ohos::bindgen_prelude::*;
use napi_derive_ohos::napi;
use serde::Deserialize;

use legado_engine as engine;

fn err(msg: impl std::fmt::Display) -> Error {
    Error::from_reason(msg.to_string())
}

fn sources_from_json(json: &str) -> Result<Vec<engine::types::BookSource>> {
    serde_json::from_str::<Vec<engine::types::BookSource>>(json)
        .map_err(|e| err(format!("invalid sources json: {e}")))
}

fn source_from_json(json: &str) -> Result<engine::types::BookSource> {
    serde_json::from_str::<engine::types::BookSource>(json)
        .map_err(|e| err(format!("invalid source json: {e}")))
}

#[derive(Debug, Deserialize, Default)]
#[allow(non_snake_case)]
struct SearchOpts {
    #[serde(default)]
    timeoutMs: Option<u64>,
    #[serde(default)]
    concurrency: Option<usize>,
}

/// Extract values from HTML/JSON content applying a Legado DSL rule (legacy).
#[napi]
pub fn parse(content: String, content_type: String, rule: String) -> Vec<String> {
    engine::parse_values(&content, &content_type, &rule)
}

/// Like `parse`, but returns JSON `{ values, diagnostics }` for the debugger.
#[napi]
pub fn parse_with_diagnostics(content: String, content_type: String, rule: String) -> String {
    let out = engine::parse_with_diagnostics(&content, &content_type, &rule);
    serde_json::to_string(&out).unwrap_or_else(|_| "{\"values\":[],\"diagnostics\":[]}".to_string())
}

/// Fetch a URL over the network (async, returns a Promise in ArkTS).
#[napi]
pub async fn fetch_text(url: String) -> Result<String> {
    engine::fetch_text(&url).await.map_err(err)
}

/// Apply the v1 import gate; returns JSON `{ total, eligible, excluded }`.
#[napi]
pub fn gate_sources(sources_json: String) -> Result<String> {
    let sources = sources_from_json(&sources_json)?;
    let out = engine::gate::run(sources);
    serde_json::to_string(&out).map_err(err)
}

/// Aggregate search across sources; returns JSON `{ items, sources }`.
#[napi]
pub async fn search(
    sources_json: String,
    keyword: String,
    opts_json: String,
) -> Result<String> {
    let sources = sources_from_json(&sources_json)?;
    let opts: SearchOpts = serde_json::from_str(&opts_json).unwrap_or_default();
    let options = engine::runtime::SearchOptions {
        timeout_ms: opts.timeoutMs.unwrap_or(10_000),
        concurrency: opts.concurrency.unwrap_or(8),
    };
    let out = engine::runtime::search(&sources, &keyword, &options).await;
    serde_json::to_string(&out).map_err(err)
}

/// Fetch and parse a book detail page; returns JSON `BookInfo`.
#[napi]
pub async fn book_info(source_json: String, book_url: String) -> Result<String> {
    let source = source_from_json(&source_json)?;
    let info = engine::runtime::book_info(&source, &book_url)
        .await
        .map_err(err)?;
    serde_json::to_string(&info).map_err(err)
}

/// Fetch a (paginated) TOC; returns JSON `Chapter[]`.
#[napi]
pub async fn toc(source_json: String, toc_url: String) -> Result<String> {
    let source = source_from_json(&source_json)?;
    let chapters = engine::runtime::toc(&source, &toc_url).await.map_err(err)?;
    serde_json::to_string(&chapters).map_err(err)
}

/// Fetch a whole chapter (following `nextContentUrl`); returns JSON
/// `{ content, nextUrl }`.
#[napi]
pub async fn content(source_json: String, chapter_url: String) -> Result<String> {
    let source = source_from_json(&source_json)?;
    let out = engine::runtime::content(&source, &chapter_url)
        .await
        .map_err(err)?;
    serde_json::to_string(&out).map_err(err)
}

/// Detect whether sources can complete a reading chain; returns JSON
/// `DetectResult[]`. `opts_json` may carry `{ keyword, concurrency }`.
#[napi]
pub async fn detect(sources_json: String, opts_json: String) -> Result<String> {
    let sources = sources_from_json(&sources_json)?;
    #[derive(Deserialize, Default)]
    struct DetectOpts {
        #[serde(default)]
        keyword: Option<String>,
        #[serde(default)]
        concurrency: Option<usize>,
    }
    let opts: DetectOpts = serde_json::from_str(&opts_json).unwrap_or_default();
    let results = engine::runtime::detect(
        &sources,
        opts.keyword.as_deref().unwrap_or("重生"),
        opts.concurrency.unwrap_or(4),
    )
    .await;
    serde_json::to_string(&results).map_err(err)
}

/// Download a cover into `dest_dir`; returns the written file path.
#[napi]
pub async fn download_cover(
    source_json: String,
    cover_url: String,
    dest_dir: String,
) -> Result<String> {
    let source = source_from_json(&source_json)?;
    engine::runtime::download_cover(&source, &cover_url, &dest_dir)
        .await
        .map_err(err)
}