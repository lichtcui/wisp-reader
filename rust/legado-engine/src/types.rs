//! Legado book-source domain types.
//!
//! Field names match the ArkTS side (`engine/types.ets`) and the original
//! Legado JSON so serde can round-trip without a conversion layer.

// ─── 文件索引（改本文件先看这里）─────────────────────────────────────
// ⚠️ **本文件的字段名就是跨 NAPI 的 JSON 契约**：新增/改名一个字段要同步三处——
//    此处 struct、`entry/src/main/ets/engine/types.ets` 的 interface、
//    `entry/obfuscation-rules.txt` 的 `-keep-property-name`；漏第三处 = release 读到 undefined。
//    `make check` 会核对后两处。契约说明见 `docs/engine.md` §JSON 契约。
//   书源与规则：  BookSource / SearchRule / BookInfoRule / ContentRule / TocRule / ExploreRule
//   搜索与详情：  BookSearchItem / SourceStatus / SearchOutput / BookInfo
//   目录与正文：  Chapter / ContentResult / DetectResult
//   诊断：        Diagnostic / ParseOutput（给 parseWithDiagnostics 用）
//   工具：        parse_concurrent_rate / default_true / Extra（未知字段透传，保证 round-trip 不掉规则）
// ──────────────────────────────────────────────────────────────────────

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

/// Preserve any fields not explicitly modeled in a struct, so a round-trip
/// (parse → serialize) never drops Legado rules we don't know about yet.
type Extra = serde_json::Map<String, Value>;

// ── Book source ───────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[allow(non_snake_case)]
pub struct BookSource {
    pub bookSourceName: String,
    pub bookSourceUrl: String,
    pub bookSourceType: i64,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookSourceGroup: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookSourceComment: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookUrlPattern: Option<String>,

    #[serde(default)]
    pub customOrder: i64,

    #[serde(default = "default_true")]
    pub enabled: bool,

    #[serde(default)]
    pub enabledCookieJar: bool,

    #[serde(default)]
    pub enabledExplore: bool,

    #[serde(default)]
    pub enabledReview: bool,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exploreUrl: Option<Value>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loginUrl: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loginUi: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loginCheckJs: Option<String>,

    #[serde(default)]
    pub lastUpdateTime: i64,

    #[serde(default)]
    pub respondTime: i64,

    #[serde(default)]
    pub weight: i64,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub concurrentRate: Option<Value>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverDecodeJs: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exploreScreen: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jsLib: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variableComment: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub searchUrl: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleSearch: Option<SearchRule>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleBookInfo: Option<BookInfoRule>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleContent: Option<ContentRule>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleToc: Option<TocRule>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleExplore: Option<ExploreRule>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ruleReview: Option<Value>,

    #[serde(flatten)]
    pub extra: Extra,
}

fn default_true() -> bool {
    true
}

// ── Rule structs ──────────────────────────────────────────────

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[allow(non_snake_case)]
pub struct SearchRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookList: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lastChapter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wordCount: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkKeyWord: Option<String>,

    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[allow(non_snake_case)]
pub struct BookInfoRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub init: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wordCount: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lastChapter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tocUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canReName: Option<String>,

    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[allow(non_snake_case)]
pub struct ContentRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,

    /// Rule extracting the URL of the next page of a paginated chapter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nextContentUrl: Option<String>,

    /// Regex cleaning applied to the assembled content (`##pattern##replacement`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replaceRegex: Option<String>,

    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[allow(non_snake_case)]
pub struct TocRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapterList: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapterName: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapterUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isVip: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updateTime: Option<String>,

    /// Rule extracting the next TOC page URL (paginated TOC). v1 addition.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nextTocUrl: Option<String>,

    /// Rule deciding whether an entry is a volume divider rather than a chapter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isVolume: Option<String>,

    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[allow(non_snake_case)]
pub struct ExploreRule {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookList: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverUrl: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lastChapter: Option<String>,

    #[serde(flatten)]
    pub extra: Extra,
}

// ── Runtime output models (serialized to ArkTS) ───────────────

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct BookSearchItem {
    pub sourceUrl: String,
    pub sourceName: String,
    pub name: String,
    pub author: String,
    pub bookUrl: String,
    pub coverUrl: String,
    pub intro: String,
    pub kind: String,
    pub wordCount: String,
    pub lastChapter: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct SourceStatus {
    pub sourceUrl: String,
    pub sourceName: String,
    pub ok: bool,
    pub count: usize,
    pub error: String,
    pub elapsedMs: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct SearchOutput {
    pub items: Vec<BookSearchItem>,
    pub sources: Vec<SourceStatus>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct BookInfo {
    pub sourceUrl: String,
    pub bookUrl: String,
    pub name: String,
    pub author: String,
    pub coverUrl: String,
    pub intro: String,
    pub kind: String,
    pub wordCount: String,
    pub status: String,
    pub lastChapterTitle: String,
    pub tocUrl: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct Chapter {
    pub index: i64,
    pub title: String,
    pub url: String,
    pub isVip: bool,
    /// Volume header (`isVolume` rule matched). Volumes carry a title but no
    /// chapter URL; readers render them as non-clickable group headers.
    pub isVolume: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct ContentResult {
    pub content: String,
    pub nextUrl: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[allow(non_snake_case)]
pub struct DetectResult {
    pub sourceUrl: String,
    pub sourceName: String,
    pub ok: bool,
    pub stage: String,
    pub detail: String,
    pub contentLen: usize,
    pub elapsedMs: u64,
}

#[derive(Debug, Clone, Serialize)]
#[allow(non_snake_case)]
pub struct Diagnostic {
    pub kind: String,
    pub rule: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[allow(non_snake_case)]
pub struct ParseOutput {
    pub values: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
}

// ── concurrentRate ────────────────────────────────────────────

/// Parse a source's `concurrentRate` into a minimum inter-request interval.
///
/// Legado allows either a plain millisecond number (`"1000"`) or a JSON object
/// (`{"rate": N, "interval": N, "timeUnit": "ms"|"s"}`).
pub fn parse_concurrent_rate(v: Option<&Value>) -> Option<Duration> {
    let v = v?;
    match v {
        Value::String(s) => {
            let s = s.trim();
            if s.is_empty() {
                return None;
            }
            if let Ok(ms) = s.parse::<u64>() {
                return Some(Duration::from_millis(ms));
            }
            if let Ok(obj) = serde_json::from_str::<Value>(s) {
                return parse_concurrent_rate(Some(&obj));
            }
            None
        }
        Value::Object(obj) => {
            let interval_units = obj
                .get("interval")
                .and_then(|v| v.as_u64())
                .unwrap_or(1)
                .max(1);
            let rate = obj
                .get("rate")
                .and_then(|v| v.as_u64())
                .filter(|r| *r > 0)
                .unwrap_or(1);
            let time_unit = obj
                .get("timeUnit")
                .and_then(|v| v.as_str())
                .unwrap_or("ms")
                .to_lowercase();
            let unit_ms = match time_unit.as_str() {
                "s" | "second" | "seconds" => 1000u64,
                "m" | "minute" | "minutes" => 60_000u64,
                _ => 1u64,
            };
            let interval_ms = interval_units.saturating_mul(unit_ms).checked_div(rate);
            interval_ms.map(|ms| Duration::from_millis(ms.max(1)))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_roundtrip_preserves_unknown_fields() {
        let json = r###"{
            "bookSourceName": "示例",
            "bookSourceUrl": "https://example.com",
            "bookSourceType": 0,
            "searchUrl": "/s?q={{key}}",
            "futureTopLevel": {"a": 1},
            "ruleSearch": {"bookList": "ul", "name": "a@text", "futureSearch": "x"},
            "ruleToc": {"chapterList": "li", "nextTocUrl": "url", "isVolume": "true"}
        }"###;
        let source: BookSource = serde_json::from_str(json).unwrap();
        let back = serde_json::to_value(&source).unwrap();
        assert_eq!(back["futureTopLevel"], serde_json::json!({"a": 1}));
        assert_eq!(back["ruleSearch"]["futureSearch"], serde_json::json!("x"));
        assert_eq!(back["ruleToc"]["nextTocUrl"], serde_json::json!("url"));
        assert_eq!(back["ruleToc"]["isVolume"], serde_json::json!("true"));
    }

    #[test]
    fn test_parse_concurrent_rate() {
        use serde_json::json;
        assert_eq!(
            parse_concurrent_rate(Some(&json!("1000"))),
            Some(Duration::from_millis(1000))
        );
        assert_eq!(
            parse_concurrent_rate(Some(&json!({"rate": 2, "timeUnit": "s"}))),
            Some(Duration::from_millis(500))
        );
        assert_eq!(parse_concurrent_rate(None), None);
    }
}