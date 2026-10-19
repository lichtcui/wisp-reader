//! Runtime engine: search / bookInfo / toc / content / detect / cover download.
//!
//! v1 does not execute JS: sources that need it are excluded by the gate, so
//! these paths only run DSL rules.

// ─── 文件索引（改本文件先看这里；本文件约 900 行）──────────────────────────
// 下面只列**名字**，不列行号（行号会漂）；定位用 `grep -n "<名字>" rust/legado-engine/src/runtime.rs`。
//   对外入口：  search / book_info / toc / content / detect / verify_chain / download_cover
//   搜索：      search_one（单源）/ SourceSearch（单源结果）/ SearchOptions
//   链路校验：  DetectMode / detect_one / detect_chain（搜索→详情→目录→正文）/ DEFAULT_DETECT_TIMEOUT_MS
//   正文清洗：  ct_of / spec_for / clean_text / strip_script_style / eval_rule_concat
//   书名匹配：  normalize_book_name / names_match / bigram_jaccard
//   封面：      cover_cache_path / looks_like_image / has_image_magic /
//               starts_like_markup / cached_cover_is_usable / download_cover
//   测试基建：  文件尾部 `#[cfg(test)]` 内有 mock_server（本地 TcpListener 造页面，可复用）
// ──────────────────────────────────────────────────────────────────────

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::Duration;

use futures::stream::{self, StreamExt};

use crate::http_client::{engine, FetchResult, SourceClient};
use crate::rule_dsl;
use crate::search_url::{self, page_headers, resolve_url, source_headers, RequestSpec};
use crate::status::FailReason;
use crate::types::*;

fn ct_of(result: &FetchResult) -> &'static str {
    if result.content_type.contains("json") {
        "json"
    } else {
        "html"
    }
}

fn spec_for(url: &str, headers: &[(String, String)]) -> RequestSpec {
    RequestSpec {
        url: url.to_string(),
        method: "GET".to_string(),
        body: None,
        headers: headers.to_vec(),
        charset: None,
        no_redirect: false,
    }
}

/// Strip tags/whitespace for readability, turning `<br>` into newlines and
/// decoding HTML entities (Legado-compatible). `<script>`/`<style>` bodies are
/// dropped entirely so inline ad code never surfaces as 正文.
fn clean_text(raw: &str) -> String {
    let stripped = strip_script_style(raw);
    let with_breaks = stripped
        .replace("<br>", "\n")
        .replace("<br/>", "\n")
        .replace("<br />", "\n");
    let doc = scraper::Html::parse_fragment(&with_breaks);
    doc.root_element().text().collect::<String>()
}

/// Remove `<script>…</script>` and `<style>…</style>` blocks (case-insensitive).
fn strip_script_style(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0usize;
    while i < raw.len() {
        if lower[i..].starts_with("<script") {
            match lower[i..].find("</script>") {
                Some(rel) => i += rel + "</script>".len(),
                None => break,
            }
        } else if lower[i..].starts_with("<style") {
            match lower[i..].find("</style>") {
                Some(rel) => i += rel + "</style>".len(),
                None => break,
            }
        } else {
            let ch = raw[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

// ── Search ────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SearchOptions {
    pub timeout_ms: u64,
    pub concurrency: usize,
}

impl Default for SearchOptions {
    fn default() -> Self {
        SearchOptions {
            timeout_ms: 10_000,
            concurrency: 8,
        }
    }
}

/// Internal search outcome for one source.
struct SourceSearch {
    status: SourceStatus,
    items: Vec<BookSearchItem>,
}

impl SourceSearch {
    fn failed(source: &BookSource, reason: FailReason, elapsed_ms: u64) -> Self {
        SourceSearch {
            status: SourceStatus {
                sourceUrl: source.bookSourceUrl.clone(),
                sourceName: source.bookSourceName.clone(),
                ok: false,
                count: 0,
                error: reason.as_str().to_string(),
                elapsedMs: elapsed_ms,
            },
            items: Vec::new(),
        }
    }
}

pub async fn search(sources: &[BookSource], keyword: &str, opts: &SearchOptions) -> SearchOutput {
    let per_source = Duration::from_millis(opts.timeout_ms.clamp(3_000, 20_000));
    let concurrency = opts.concurrency.clamp(1, 16);
    let owned: Vec<BookSource> = sources.to_vec();
    let keyword = keyword.to_string();
    let results: Vec<SourceSearch> = stream::iter(owned.into_iter().map(|s| {
        let keyword = keyword.clone();
        async move {
            let client = engine().client_for(&s);
            tokio::time::timeout(per_source, search_one(&client, &s, &keyword))
                .await
                .unwrap_or_else(|_| {
                    SourceSearch::failed(&s, FailReason::Timeout, per_source.as_millis() as u64)
                })
        }
    }))
    .buffer_unordered(concurrency)
    .collect()
    .await;

    let mut out = SearchOutput::default();
    for r in results {
        out.sources.push(r.status);
        out.items.extend(r.items);
    }
    out
}

/// Run one source's search.
async fn search_one(client: &SourceClient, source: &BookSource, keyword: &str) -> SourceSearch {
    let started = std::time::Instant::now();

    let Some(mut spec) = search_url::build_request(source, keyword) else {
        return SourceSearch::failed(source, FailReason::BuilderError, 0);
    };
    spec.headers = source_headers(source);

    let result = match client.fetch(&spec).await {
        Ok(r) => r,
        Err(e) => {
            return SourceSearch::failed(
                source,
                e.fail_reason(),
                started.elapsed().as_millis() as u64,
            );
        }
    };
    let elapsed = result.elapsed_ms;
    if result.body_text.trim().is_empty() {
        return SourceSearch::failed(source, FailReason::NoResults, elapsed);
    }

    let content_type = if result.content_type.contains("json") {
        "json"
    } else if spec.url.contains("json") && !result.content_type.contains("html") {
        "json"
    } else {
        "html"
    };

    let items = match source.ruleSearch.as_ref() {
        Some(rule) => rule_dsl::extract_search_items(&result.body_text, content_type, rule),
        None => Vec::new(),
    };

    let items: Vec<BookSearchItem> = items
        .into_iter()
        .filter(|i| !i.name.trim().is_empty())
        .map(|i| BookSearchItem {
            sourceUrl: source.bookSourceUrl.clone(),
            sourceName: source.bookSourceName.clone(),
            name: i.name.trim().to_string(),
            author: i.author.trim().to_string(),
            bookUrl: resolve_url(&i.book_url, &source.bookSourceUrl),
            coverUrl: resolve_url(&i.cover_url, &source.bookSourceUrl),
            intro: i.intro.trim().to_string(),
            kind: i.kind.trim().to_string(),
            wordCount: i.word_count.trim().to_string(),
            lastChapter: i.last_chapter.trim().to_string(),
        })
        .collect();

    if items.is_empty() {
        return SourceSearch::failed(source, FailReason::NoResults, elapsed);
    }
    SourceSearch {
        status: SourceStatus {
            sourceUrl: source.bookSourceUrl.clone(),
            sourceName: source.bookSourceName.clone(),
            ok: true,
            count: items.len(),
            error: String::new(),
            elapsedMs: elapsed,
        },
        items,
    }
}

// ── Book info ─────────────────────────────────────────────────

pub async fn book_info(source: &BookSource, book_url: &str) -> Result<BookInfo, String> {
    let client = engine().client_for(source);
    let headers = source_headers(source);
    let result = client
        .fetch(&spec_for(book_url, &headers))
        .await
        .map_err(|e| e.fail_reason().as_str().to_string())?;
    let content_type = ct_of(&result);

    let mut info = BookInfo {
        sourceUrl: source.bookSourceUrl.clone(),
        bookUrl: book_url.to_string(),
        tocUrl: book_url.to_string(),
        ..Default::default()
    };

    if let Some(rule) = source.ruleBookInfo.as_ref() {
        let get = |r: &Option<String>| -> String {
            r.as_deref()
                .filter(|r| !r.trim().is_empty() && *r != "-" && *r != "#")
                .map(|r| {
                    rule_dsl::extract_single(&result.body_text, content_type, r)
                        .into_iter()
                        .map(|s| s.trim().to_string())
                        .find(|s| !s.is_empty())
                        .unwrap_or_default()
                })
                .unwrap_or_default()
        };
        info.name = get(&rule.name);
        info.author = get(&rule.author);
        info.kind = get(&rule.kind);
        info.wordCount = get(&rule.wordCount);
        info.lastChapterTitle = get(&rule.lastChapter);
        info.intro = get(&rule.intro);
        let cover = get(&rule.coverUrl);
        info.coverUrl = resolve_url(&cover, book_url);
        let toc = get(&rule.tocUrl);
        info.tocUrl = if toc.is_empty() {
            book_url.to_string()
        } else {
            resolve_url(&toc, book_url)
        };
    }
    Ok(info)
}

// ── TOC ───────────────────────────────────────────────────────

pub async fn toc(source: &BookSource, toc_url: &str) -> Result<Vec<Chapter>, String> {
    const MAX_TOC_PAGES: usize = 50;
    let client = engine().client_for(source);
    let src_headers = source_headers(source);

    let Some(toc_rule) = source.ruleToc.as_ref() else {
        return Err(FailReason::NoTocRule.as_str().to_string());
    };

    let mut chapters: Vec<Chapter> = Vec::new();
    let mut current_url = toc_url.to_string();
    let mut seen: Vec<String> = Vec::new();

    for _ in 0..MAX_TOC_PAGES {
        if seen.iter().any(|u| u == &current_url) {
            break;
        }
        seen.push(current_url.clone());

        let headers = page_headers(&src_headers, toc_url);
        let result = client
            .fetch(&spec_for(&current_url, &headers))
            .await
            .map_err(|e| e.fail_reason().as_str().to_string())?;
        let content_type = ct_of(&result);
        if result.body_text.trim().is_empty() {
            break;
        }

        let items = rule_dsl::extract_toc(&result.body_text, content_type, toc_rule);
        for item in items {
            let url = if item.is_volume {
                // Volumes only carry a title; never resolve a chapter URL.
                String::new()
            } else {
                resolve_url(&item.url, &current_url)
            };
            if item.name.is_empty() && url.is_empty() {
                continue;
            }
            chapters.push(Chapter {
                index: chapters.len() as i64,
                title: item.name.trim().to_string(),
                url,
                isVip: item.is_vip,
                isVolume: item.is_volume,
            });
        }

        let Some(next_rule) = toc_rule
            .nextTocUrl
            .as_deref()
            .filter(|r| !r.trim().is_empty() && *r != "-" && *r != "#")
        else {
            break;
        };
        let next = rule_dsl::extract_single(&result.body_text, content_type, next_rule)
            .into_iter()
            .map(|s| s.trim().to_string())
            .find(|s| !s.is_empty());
        match next {
            Some(n) => {
                let n = resolve_url(&n, &current_url);
                if n == current_url || n.is_empty() {
                    break;
                }
                current_url = n;
            }
            None => break,
        }
    }

    if chapters.is_empty() {
        return Err(FailReason::TocParse.as_str().to_string());
    }
    Ok(chapters)
}

// ── Content ───────────────────────────────────────────────────

pub async fn content(source: &BookSource, chapter_url: &str) -> Result<ContentResult, String> {
    const MAX_PAGES: usize = 30;
    let client = engine().client_for(source);
    let src_headers = source_headers(source);
    let chapter_headers = page_headers(&src_headers, chapter_url);

    let Some(content_rule) = source
        .ruleContent
        .as_ref()
        .and_then(|c| c.content.as_deref())
        .map(str::trim)
        .filter(|r| !r.is_empty())
    else {
        return Err(FailReason::NoContentRule.as_str().to_string());
    };
    let next_rule = source
        .ruleContent
        .as_ref()
        .and_then(|c| c.nextContentUrl.as_deref())
        .map(str::trim)
        .filter(|r| !r.is_empty() && *r != "-" && *r != "#");

    let mut paragraphs: Vec<String> = Vec::new();
    let mut current_url = chapter_url.to_string();

    for page in 0..MAX_PAGES {
        let result = client
            .fetch(&spec_for(&current_url, &chapter_headers))
            .await
            .map_err(|e| e.fail_reason().as_str().to_string())?;
        let content_type = ct_of(&result);
        let raw = eval_rule_concat(&result.body_text, content_type, content_rule);
        if !raw.is_empty() {
            for p in clean_text(&raw).split('\n') {
                let p = p.trim();
                if !p.is_empty() {
                    paragraphs.push(p.to_string());
                }
            }
        }

        let Some(nr) = next_rule else { break };
        if page + 1 >= MAX_PAGES {
            break;
        }
        let next = rule_dsl::extract_single(&result.body_text, content_type, nr)
            .into_iter()
            .map(|s| s.trim().to_string())
            .find(|s| !s.is_empty());
        let Some(next) = next else { break };
        let next = resolve_url(&next, &current_url);
        if next == current_url || next.is_empty() {
            break;
        }
        current_url = next;
    }

    if paragraphs.is_empty() {
        return Err(FailReason::ContentEmpty.as_str().to_string());
    }
    Ok(ContentResult {
        content: paragraphs.join("\n"),
        nextUrl: String::new(),
    })
}

fn eval_rule_concat(content: &str, content_type: &str, rule: &str) -> String {
    let vals = rule_dsl::extract_single(content, content_type, rule);
    let joined: Vec<String> = vals
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    joined.join("\n")
}

// ── Detect ────────────────────────────────────────────────────

/// Default per-source budget for a full detect chain (search → detail → toc →
/// chapter → content). Individual requests are already capped at 15s
/// (`http_client`), but the chain had no aggregate bound; a source could stall
/// for minutes. Mirrors the JS bridge's 45s overall cap upstream.
pub const DEFAULT_DETECT_TIMEOUT_MS: u64 = 45_000;
pub const PROBE_DETECT_TIMEOUT_MS: u64 = 8_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DetectMode {
    Probe,
    #[default]
    Full,
}

impl DetectMode {
    /// Missing and unknown values retain the legacy full-chain behavior.
    pub fn from_opt(value: Option<&str>) -> Self {
        match value {
            Some("probe") => Self::Probe,
            _ => Self::Full,
        }
    }

    pub fn default_timeout_ms(self) -> u64 {
        match self {
            Self::Probe => PROBE_DETECT_TIMEOUT_MS,
            Self::Full => DEFAULT_DETECT_TIMEOUT_MS,
        }
    }
}

pub async fn detect(
    sources: &[BookSource],
    keyword: &str,
    concurrency: usize,
    timeout_ms: u64,
    mode: DetectMode,
) -> Vec<DetectResult> {
    let owned: Vec<BookSource> = sources.to_vec();
    let keyword = keyword.to_string();
    let min_timeout_ms = match mode {
        DetectMode::Probe => 3_000,
        DetectMode::Full => 10_000,
    };
    let per_source = Duration::from_millis(timeout_ms.clamp(min_timeout_ms, 120_000));
    stream::iter(owned.into_iter().map(|s| {
        let keyword = keyword.clone();
        async move { detect_one(&s, &keyword, per_source, mode).await }
    }))
    .buffer_unordered(concurrency.clamp(1, 16))
    .collect()
    .await
}

/// Run one source's detection with an aggregate timeout. A timeout is reported
/// as `stage = "timeout"` and must be treated as *retryable* by the caller, not
/// as proof the source is broken.
async fn detect_one(
    source: &BookSource,
    keyword: &str,
    budget: Duration,
    mode: DetectMode,
) -> DetectResult {
    let started = std::time::Instant::now();
    match tokio::time::timeout(budget, detect_chain(source, keyword, mode)).await {
        Ok(mut out) => {
            out.elapsedMs = started.elapsed().as_millis() as u64;
            out
        }
        Err(_) => DetectResult {
            sourceUrl: source.bookSourceUrl.clone(),
            sourceName: source.bookSourceName.clone(),
            ok: false,
            stage: FailReason::Timeout.as_str().to_string(),
            detail: "检测超时".into(),
            contentLen: 0,
            elapsedMs: started.elapsed().as_millis() as u64,
        },
    }
}

async fn detect_chain(source: &BookSource, keyword: &str, mode: DetectMode) -> DetectResult {
    let mut out = DetectResult {
        sourceUrl: source.bookSourceUrl.clone(),
        sourceName: source.bookSourceName.clone(),
        ok: false,
        stage: String::new(),
        detail: String::new(),
        contentLen: 0,
        elapsedMs: 0,
    };

    let client = engine().client_for(source);
    let found = search_one(&client, source, keyword).await;
    if !found.status.ok || found.items.is_empty() {
        out.stage = if found.status.error.is_empty() {
            FailReason::NoResults.as_str().to_string()
        } else {
            found.status.error
        };
        out.detail = "搜索未命中".into();
        return out;
    }
    let item = &found.items[0];
    if item.bookUrl.trim().is_empty() {
        out.stage = FailReason::NoBookUrl.as_str().to_string();
        out.detail = "搜索结果缺少书籍地址".into();
        return out;
    }
    if mode == DetectMode::Probe {
        out.ok = true;
        out.stage = "search".into();
        out.detail = "搜索命中".into();
        return out;
    }
    let chain = verify_chain(source, &item.bookUrl, Some(&item.name)).await;
    out.ok = chain.0;
    out.stage = chain.1;
    out.detail = chain.2;
    out.contentLen = chain.3;
    out
}

/// Walk book detail → TOC → first chapter → content. Returns
/// `(ok, stage, detail, content_len)`.
pub async fn verify_chain(
    source: &BookSource,
    book_url: &str,
    expected_name: Option<&str>,
) -> (bool, String, String, usize) {
    let client = engine().client_for(source);
    let src_headers = source_headers(source);

    let book = match client.fetch(&spec_for(book_url, &src_headers)).await {
        Ok(r) if !r.body_text.trim().is_empty() => r,
        _ => {
            return (
                false,
                FailReason::BookinfoFetch.as_str().to_string(),
                book_url.to_string(),
                0,
            );
        }
    };
    let book_ct = ct_of(&book);

    // Name consistency (张冠李戴 guard).
    if let Some(expected) = expected_name
        && let Some(bi) = source.ruleBookInfo.as_ref()
        && let Some(name_rule) = bi.name.as_deref().map(str::trim).filter(|r| !r.is_empty())
    {
        let actual = rule_dsl::extract_single(&book.body_text, book_ct, name_rule)
            .into_iter()
            .map(|s| s.trim().to_string())
            .find(|s| !s.is_empty());
        if let Some(actual) = actual {
            let e = normalize_book_name(expected);
            let a = normalize_book_name(&actual);
            if e.chars().count() >= 4 && a.chars().count() >= 4 && !names_match(&e, &a) {
                return (
                    false,
                    FailReason::Mismatch.as_str().to_string(),
                    format!("search='{e}' vs detail='{a}'"),
                    0,
                );
            }
        }
    }

    // tocUrl
    let toc_url = match source.ruleBookInfo.as_ref().and_then(|b| b.tocUrl.as_deref()) {
        Some(rule) if !rule.trim().is_empty() && rule != "-" && rule != "#" => {
            let t = rule_dsl::extract_single(&book.body_text, book_ct, rule)
                .into_iter()
                .map(|s| s.trim().to_string())
                .find(|s| !s.is_empty())
                .unwrap_or_else(|| book_url.to_string());
            resolve_url(&t, book_url)
        }
        _ => book_url.to_string(),
    };

    let toc_headers = page_headers(&src_headers, book_url);
    let toc_page = match client.fetch(&spec_for(&toc_url, &toc_headers)).await {
        Ok(r) if !r.body_text.trim().is_empty() => r,
        _ => {
            return (
                false,
                FailReason::TocFetch.as_str().to_string(),
                toc_url,
                0,
            );
        }
    };
    let toc_ct = ct_of(&toc_page);

    let Some(toc_rule) = source.ruleToc.as_ref() else {
        return (
            false,
            FailReason::NoTocRule.as_str().to_string(),
            source.bookSourceName.clone(),
            0,
        );
    };
    let chapters = rule_dsl::extract_toc(&toc_page.body_text, toc_ct, toc_rule);
    let first = chapters
        .iter()
        .find(|c| !c.is_volume && !c.url.trim().is_empty());
    let Some(first) = first else {
        return (
            false,
            FailReason::TocParse.as_str().to_string(),
            toc_url,
            0,
        );
    };
    let chapter_url = resolve_url(&first.url, &toc_url);

    let chapter_headers = page_headers(&src_headers, &toc_url);
    let chapter = match client.fetch(&spec_for(&chapter_url, &chapter_headers)).await {
        Ok(r) if !r.body_text.trim().is_empty() => r,
        _ => {
            return (
                false,
                FailReason::ChapterFetch.as_str().to_string(),
                chapter_url,
                0,
            );
        }
    };
    let mut current_ct: &'static str = ct_of(&chapter);
    let mut current_body: String = chapter.body_text;
    let Some(content_rule) = source
        .ruleContent
        .as_ref()
        .and_then(|c| c.content.as_deref())
        .map(str::trim)
        .filter(|r| !r.is_empty())
    else {
        return (
            false,
            FailReason::NoContentRule.as_str().to_string(),
            source.bookSourceName.clone(),
            0,
        );
    };
    let next_rule = source
        .ruleContent
        .as_ref()
        .and_then(|c| c.nextContentUrl.as_deref())
        .map(str::trim)
        .filter(|r| !r.is_empty() && *r != "-" && *r != "#");

    // Follow `nextContentUrl` until the assembled text clears the threshold,
    // matching `content()` / upstream `content_check`: a paginated chapter whose
    // first page is short must not be misread as `content_short`.
    const MAX_PAGES: usize = 30;
    let mut len = 0usize;
    let mut pages = 0usize;
    let mut current_url = chapter_url.clone();
    loop {
        len += clean_text(&eval_rule_concat(&current_body, current_ct, content_rule))
            .chars()
            .count();
        pages += 1;
        if len >= 50 || pages >= MAX_PAGES {
            break;
        }
        let Some(nr) = next_rule else { break };
        let next = rule_dsl::extract_single(&current_body, current_ct, nr)
            .into_iter()
            .map(|s| s.trim().to_string())
            .find(|s| !s.is_empty());
        let Some(next) = next else { break };
        let next = resolve_url(&next, &current_url);
        if next.is_empty() || next == current_url {
            break;
        }
        let next_headers = page_headers(&src_headers, &current_url);
        let page = match client.fetch(&spec_for(&next, &next_headers)).await {
            Ok(r) if !r.body_text.trim().is_empty() => r,
            _ => break,
        };
        current_ct = ct_of(&page);
        current_body = page.body_text;
        current_url = next;
    }
    if len < 50 {
        return (
            false,
            FailReason::ContentShort.as_str().to_string(),
            format!("{len} chars"),
            len,
        );
    }
    (true, "content".to_string(), format!("{len} chars"), len)
}

pub fn normalize_book_name(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

fn bigram_jaccard(a: &str, b: &str) -> f64 {
    let bigrams = |s: &str| -> std::collections::HashSet<(char, char)> {
        let chars: Vec<char> = s.chars().collect();
        if chars.len() < 2 {
            return std::collections::HashSet::new();
        }
        chars.windows(2).map(|w| (w[0], w[1])).collect()
    };
    let ba = bigrams(a);
    let bb = bigrams(b);
    if ba.is_empty() || bb.is_empty() {
        return 0.0;
    }
    let inter = ba.intersection(&bb).count();
    let union = ba.len() + bb.len() - inter;
    if union == 0 { 0.0 } else { inter as f64 / union as f64 }
}

pub fn names_match(a: &str, b: &str) -> bool {
    if a.is_empty() || b.is_empty() {
        return false;
    }
    a.contains(b) || b.contains(a) || bigram_jaccard(a, b) >= 0.5
}

// ── Cover download ────────────────────────────────────────────

/// Returned when the cover URL answered with something that is not an image
/// (a detail page, an anti-hotlink stub, a JSON error body).
const COVER_NOT_IMAGE: &str = "not_image";

/// Cache slot for `cover_url`: `dest_dir/cover_<hash>.img`.
fn cover_cache_path(dest_dir: &str, cover_url: &str) -> String {
    let mut hasher = DefaultHasher::new();
    cover_url.hash(&mut hasher);
    format!("{}/cover_{:x}.img", dest_dir.trim_end_matches('/'), hasher.finish())
}

/// Bitmap container signatures the platform decoder (`ImageSource` →
/// `PixelMap`) understands. Everything else would only be written to the cache
/// to fail later with `Failed to create the image plugin` (62980118).
fn has_image_magic(b: &[u8]) -> bool {
    const MAGIC: [&[u8]; 6] = [
        b"\xFF\xD8\xFF",      // JPEG
        b"\x89PNG\r\n\x1a\n", // PNG
        b"GIF87a",            // GIF
        b"GIF89a",
        b"BM",                // BMP
        b"\x00\x00\x01\x00", // ICO
    ];
    if MAGIC.iter().any(|m| b.starts_with(m)) {
        return true;
    }
    // RIFF container: `RIFF????WEBP`
    if b.len() >= 12 && b.starts_with(b"RIFF") && &b[8..12] == b"WEBP" {
        return true;
    }
    // ISO base media file format: `ftyp` box at offset 4 (HEIC / HEIF / AVIF).
    b.len() >= 12 && &b[4..8] == b"ftyp"
}

/// Bodies that begin like markup / JSON / plain whitespace (an HTML page, a
/// hotlink-protection stub, an API error) are never bitmaps.
fn starts_like_markup(bytes: &[u8]) -> bool {
    let b = bytes.strip_prefix(b"\xEF\xBB\xBF".as_slice()).unwrap_or(bytes);
    match b.iter().find(|c| !c.is_ascii_whitespace()) {
        Some(c) => matches!(c, b'<' | b'{' | b'['),
        None => true,
    }
}

fn is_text_content_type(ct: &str) -> bool {
    ct.starts_with("text/")
        || ct.contains("json")
        || ct.contains("xml")
        || ct.contains("javascript")
}

/// Whether a fetched body is worth caching as a cover.
fn looks_like_image(bytes: &[u8], content_type: &str) -> bool {
    if bytes.is_empty() || starts_like_markup(bytes) {
        return false;
    }
    if has_image_magic(bytes) {
        return true;
    }
    // Unknown container: trust an explicit `image/*` answer. The App deletes the
    // file again if its decoder rejects it, so this cannot poison the cache.
    let ct: String = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    ct.starts_with("image/") && !is_text_content_type(&ct)
}

/// A cached `cover_*.img` is re-used unless it is empty or begins like markup —
/// builds before this check cached HTML pages here, which made every render log
/// `ImageSource` 62980118 and pinned the book to its placeholder forever.
fn cached_cover_is_usable(path: &str) -> bool {
    use std::io::Read;
    let Ok(mut f) = std::fs::File::open(path) else {
        return false;
    };
    let mut head = [0u8; 64];
    match f.read(&mut head) {
        Ok(n) => n > 0 && !starts_like_markup(&head[..n]),
        Err(_) => false,
    }
}

/// Download a cover with the source's headers/cookies and write it into
/// `dest_dir`. Returns the absolute file path.
pub async fn download_cover(
    source: &BookSource,
    cover_url: &str,
    dest_dir: &str,
) -> Result<String, String> {
    let path = cover_cache_path(dest_dir, cover_url);

    if std::path::Path::new(&path).exists() && cached_cover_is_usable(&path) {
        return Ok(path);
    }

    let client = engine().client_for(source);
    let headers = source_headers(source);
    let result = client
        .fetch(&spec_for(cover_url, &headers))
        .await
        .map_err(|e| e.fail_reason().as_str().to_string())?;
    if result.body_bytes.is_empty() {
        return Err(FailReason::NoResults.as_str().to_string());
    }
    if !looks_like_image(&result.body_bytes, &result.content_type) {
        // Never cache a non-image: the slot is keyed by URL alone, so a poisoned
        // file would outlive every retry (and every app launch).
        let _ = std::fs::remove_file(&path);
        return Err(COVER_NOT_IMAGE.to_string());
    }

    std::fs::write(&path, &result.body_bytes).map_err(|e| e.to_string())?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ContentRule, SearchRule, TocRule};

    #[test]
    fn test_clean_text() {
        let out = clean_text("<p>第一段</p><br>第二段<div>x</div>");
        assert!(!out.contains('<'));
        assert!(out.contains("第一段"));
        assert!(out.contains('\n'));
    }

    #[test]
    fn test_clean_text_decodes_entities() {
        let out = clean_text("<p>&nbsp;&nbsp;你好 &amp; 再见</p>");
        assert!(!out.contains("&nbsp;"), "entities must be decoded: {out:?}");
        assert!(!out.contains("&amp;"), "entities must be decoded: {out:?}");
        assert!(out.contains("你好"), "{out:?}");
        assert!(out.contains('&'), "{out:?}");
    }

    #[test]
    fn test_clean_text_drops_script_and_style() {
        let raw = "<div>正文<script>var cpro_id='u1';</script><style>.a{}</style>后文</div>";
        let out = clean_text(raw);
        assert!(out.contains("正文"), "{out:?}");
        assert!(out.contains("后文"), "{out:?}");
        assert!(!out.contains("cpro_id"), "script body leaked: {out:?}");
        assert!(!out.contains(".a{"), "style body leaked: {out:?}");
    }

    #[test]
    fn test_normalize_and_match() {
        assert_eq!(normalize_book_name("《测试 书名》"), "测试书名");
        assert!(names_match("测试书名", "测试书名的名字"));
        assert!(!names_match("测试书名", "完全不同的书名"));
    }

    #[test]
    fn test_detect_mode_defaults_to_full() {
        assert_eq!(DetectMode::from_opt(Some("probe")), DetectMode::Probe);
        assert_eq!(DetectMode::from_opt(Some("full")), DetectMode::Full);
        assert_eq!(DetectMode::from_opt(None), DetectMode::Full);
        assert_eq!(DetectMode::from_opt(Some("unknown")), DetectMode::Full);
        assert_eq!(DetectMode::Probe.default_timeout_ms(), PROBE_DETECT_TIMEOUT_MS);
        assert_eq!(DetectMode::Full.default_timeout_ms(), DEFAULT_DETECT_TIMEOUT_MS);
    }

    const DETECT_SEARCH_HTML: &str = "<ul>\
        <li class='item'><a href='/book/1'>书一</a></li>\
        <li class='item'><a href='/book/2'>书二</a></li>\
        </ul>";
    const DETECT_BOOK_HTML: &str =
        "<h1>书一</h1><div class='intro'>简介文字</div><a id='toc' href='/toc'>目录</a>";
    const DETECT_TOC_HTML: &str = "<ul>\
        <li class='vol'><span>第一卷</span></li>\
        <li class='item'><a href='/c/1'>第一章</a></li>\
        <li class='item'><a href='/c/2'>第二章</a></li>\
        </ul>";
    const DETECT_CHAPTER_HTML: &str = "<div id='content'>正文内容正文内容正文内容正文内容正文内容\
        正文内容正文内容正文内容正文内容正文内容正文内容正文内容正文内容</div>";

    /// Minimal blocking mock server: maps fixed fixture paths to fixed bodies.
    fn mock_server() -> (
        String,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
        std::thread::JoinHandle<()>,
    ) {
        mock_server_with_toc(true)
    }

    fn mock_server_with_toc(toc_available: bool) -> (
        String,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
        std::thread::JoinHandle<()>,
    ) {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{addr}");
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_for_thread = Arc::clone(&hits);
        let handle = std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut socket) = stream else { break };
                hits_for_thread.fetch_add(1, Ordering::SeqCst);
                let mut buf = [0u8; 4096];
                let n = socket.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let path = req
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .split('?')
                    .next()
                    .unwrap_or("/")
                    .to_string();
                let body = if path.starts_with("/search") {
                    DETECT_SEARCH_HTML.to_string()
                } else if path == "/book/1" {
                    DETECT_BOOK_HTML.to_string()
                } else if path == "/toc" && toc_available {
                    DETECT_TOC_HTML.to_string()
                } else if path == "/toc" {
                    String::new()
                } else if path.starts_with("/c/") {
                    DETECT_CHAPTER_HTML.to_string()
                } else {
                    "nf".to_string()
                };
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(resp.as_bytes());
            }
        });
        (base, hits, handle)
    }

    /// Binary-safe blocking server for the cover tests: routes by path.
    fn mock_cover_server() -> (String, std::thread::JoinHandle<()>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{addr}");
        let handle = std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut socket) = stream else { break };
                let mut buf = [0u8; 2048];
                let n = socket.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let path = req.split_whitespace().nth(1).unwrap_or("/").to_string();
                let (ct, body): (&str, Vec<u8>) = if path == "/cover.png" {
                    ("image/png", PNG_BYTES.to_vec())
                } else if path == "/cover.html" {
                    ("text/html", b"<!DOCTYPE html><html>403 hotlink</html>".to_vec())
                } else {
                    // Claims to be a JPEG but ships an HTML page.
                    ("image/jpeg", b"<!DOCTYPE html><html>stub</html>".to_vec())
                };
                let mut resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .into_bytes();
                resp.extend_from_slice(&body);
                let _ = socket.write_all(&resp);
            }
        });
        (base, handle)
    }

    /// Only the signature matters here — Rust never decodes the bitmap.
    const PNG_BYTES: &[u8] =
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00";

    #[test]
    fn test_looks_like_image() {
        assert!(looks_like_image(PNG_BYTES, "image/png"));
        assert!(looks_like_image(b"\xFF\xD8\xFF\xE0\x00\x10JFIF", ""), "jpeg");
        assert!(looks_like_image(b"RIFF\x00\x00\x00\x00WEBPVP8 ", ""), "webp");
        assert!(looks_like_image(b"GIF89a\x01\x00", "image/gif"), "gif");
        assert!(looks_like_image(b"\x00\x00\x00\x18ftypheic", ""), "heic");
        // A page / stub / API error body is never a cover.
        assert!(!looks_like_image(b"<!DOCTYPE html><html><body>403</body>", "text/html"));
        assert!(!looks_like_image(b"<!DOCTYPE html><html></html>", "image/png"), "lying ct");
        assert!(!looks_like_image(b"{\"code\":404}", "application/json"));
        assert!(!looks_like_image(b"", "image/png"));
        assert!(!looks_like_image(b"   \n\t ", "image/png"));
        assert!(!looks_like_image(b"\xEF\xBB\xBF<!DOCTYPE html>", "image/png"), "bom");
        // Unknown binary container: only an explicit `image/*` lets it through.
        assert!(!looks_like_image(b"ZZZZ\x01\x02", "application/octet-stream"));
        assert!(looks_like_image(b"ZZZZ\x01\x02", "image/avif"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_download_cover_validates_and_self_heals() {
        let (base, _h) = mock_cover_server();
        let source = sample_source(&base);
        let dir = std::env::temp_dir().join(format!("legado-cover-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir_s = dir.to_string_lossy().to_string();

        // 1. A page is refused and nothing is written (no poisoned slot).
        let page = format!("{base}/cover.html");
        assert_eq!(download_cover(&source, &page, &dir_s).await, Err(COVER_NOT_IMAGE.into()));
        assert!(!std::path::Path::new(&cover_cache_path(&dir_s, &page)).exists());
        // Same for a body that lies about its content type.
        let stub = format!("{base}/cover.stub");
        assert_eq!(download_cover(&source, &stub, &dir_s).await, Err(COVER_NOT_IMAGE.into()));
        assert!(!std::path::Path::new(&cover_cache_path(&dir_s, &stub)).exists());

        // 2. A real image is cached and re-used as-is.
        let png = format!("{base}/cover.png");
        let path = download_cover(&source, &png, &dir_s).await.unwrap();
        assert_eq!(path, cover_cache_path(&dir_s, &png));
        assert_eq!(std::fs::read(&path).unwrap(), PNG_BYTES);
        assert_eq!(download_cover(&source, &png, &dir_s).await.unwrap(), path);

        // 3. A slot poisoned by an older build is re-downloaded, not returned.
        std::fs::write(&path, b"<!DOCTYPE html><html>403</html>").unwrap();
        assert_eq!(download_cover(&source, &png, &dir_s).await.unwrap(), path);
        assert_eq!(std::fs::read(&path).unwrap(), PNG_BYTES);

        std::fs::remove_dir_all(&dir).ok();
    }

    fn sample_source(base: &str) -> BookSource {
        BookSource {
            bookSourceName: "mock".into(),
            bookSourceUrl: base.to_string(),
            bookSourceType: 0,
            enabled: true,
            searchUrl: Some("/search?q={{key}}".into()),
            ruleSearch: Some(SearchRule {
                bookList: Some("li.item".into()),
                name: Some("a@text".into()),
                bookUrl: Some("a@href".into()),
                ..Default::default()
            }),
            ruleBookInfo: Some(crate::types::BookInfoRule {
                name: Some("h1@text".into()),
                intro: Some("div.intro@text".into()),
                tocUrl: Some("a#toc@href".into()),
                ..Default::default()
            }),
            ruleToc: Some(TocRule {
                chapterList: Some("li".into()),
                chapterName: Some("a@text||@text".into()),
                chapterUrl: Some("a@href".into()),
                isVolume: Some("span@text".into()),
                ..Default::default()
            }),
            ruleContent: Some(ContentRule {
                content: Some("div#content@text".into()),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_search_and_chain_end_to_end() {
        let (base, _hits, _h) = mock_server();
        let source = sample_source(&base);

        let out = search(&[source.clone()], "书", &SearchOptions::default()).await;
        assert_eq!(out.sources.len(), 1);
        assert!(out.sources[0].ok, "search failed: {:?}", out.sources[0]);
        assert_eq!(out.items.len(), 2);
        assert_eq!(out.items[0].name, "书一");
        assert_eq!(out.items[0].bookUrl, format!("{base}/book/1"));

        let info = book_info(&source, &format!("{base}/book/1")).await.unwrap();
        assert_eq!(info.name, "书一");
        assert_eq!(info.tocUrl, format!("{base}/toc"));

        let chapters = toc(&source, &info.tocUrl).await.unwrap();
        // Volume header merged into the list, but it is not a readable chapter.
        assert_eq!(chapters.len(), 3);
        assert!(chapters[0].isVolume);
        assert!(chapters[0].url.is_empty());
        assert_eq!(chapters[0].title, "第一卷");
        assert!(!chapters[1].isVolume);
        assert_eq!(chapters[1].url, format!("{base}/c/1"));

        let content = content(&source, &chapters[1].url).await.unwrap();
        assert!(content.content.chars().count() > 50);

        let detected =
            detect(&[source], "书", 2, DEFAULT_DETECT_TIMEOUT_MS, DetectMode::Full).await;
        assert!(detected[0].ok, "detect failed: {:?}", detected[0]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_detect_probe_stops_after_search() {
        use std::sync::atomic::Ordering;

        let (base, hits, _h) = mock_server();
        let source = sample_source(&base);

        let detected = detect(
            &[source],
            "书",
            2,
            PROBE_DETECT_TIMEOUT_MS,
            DetectMode::Probe,
        )
        .await;

        assert!(detected[0].ok, "probe failed: {:?}", detected[0]);
        assert_eq!(detected[0].stage, "search");
        assert_eq!(detected[0].contentLen, 0);
        assert_eq!(hits.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_detect_probe_no_results_is_not_unavailable() {
        use std::sync::atomic::Ordering;

        let (base, hits, _h) = mock_server();
        let mut source = sample_source(&base);
        source
            .ruleSearch
            .as_mut()
            .unwrap()
            .bookList = Some("li.missing".into());

        let detected = detect(
            &[source],
            "书",
            2,
            PROBE_DETECT_TIMEOUT_MS,
            DetectMode::Probe,
        )
        .await;

        assert!(!detected[0].ok, "empty probe must fail: {:?}", detected[0]);
        assert_eq!(detected[0].stage, "no_results");
        assert_eq!(hits.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_detect_full_runs_complete_chain() {
        use std::sync::atomic::Ordering;

        let (base, hits, _h) = mock_server();
        let source = sample_source(&base);

        let detected = detect(
            &[source],
            "书",
            2,
            DEFAULT_DETECT_TIMEOUT_MS,
            DetectMode::Full,
        )
        .await;

        assert!(detected[0].ok, "full detect failed: {:?}", detected[0]);
        assert_eq!(detected[0].stage, "content");
        assert!(detected[0].contentLen >= 50);
        assert_eq!(hits.load(Ordering::SeqCst), 4);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_detect_full_toc_fetch_failure_is_explicit() {
        use std::sync::atomic::Ordering;

        let (base, hits, _h) = mock_server_with_toc(false);
        let source = sample_source(&base);

        let detected = detect(
            &[source],
            "书",
            2,
            DEFAULT_DETECT_TIMEOUT_MS,
            DetectMode::Full,
        )
        .await;

        assert!(!detected[0].ok, "toc failure must fail: {:?}", detected[0]);
        assert_eq!(detected[0].stage, FailReason::TocFetch.as_str());
        assert_eq!(detected[0].detail, format!("{base}/toc"));
        assert_eq!(detected[0].contentLen, 0);
        assert_eq!(hits.load(Ordering::SeqCst), 3);
    }
}
