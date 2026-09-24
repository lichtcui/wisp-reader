//! Typed test statuses and failure reasons, serialized to stable short strings
//! that the ArkTS UI can map to user-facing messages.

use serde::{Deserialize, Serialize};

/// Why a source failed. Strings match the desktop tool's cache vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailReason {
    NoResults,
    TocParse,
    ContentShort,
    Blocked,
    NotFound,
    RateLimited,
    NetworkError,
    BookinfoFetch,
    TocFetch,
    ChapterFetch,
    ServerError,
    BuilderError,
    NoTocRule,
    NoContentRule,
    ContentEmpty,
    HttpError,
    NoBookUrl,
    StaticList,
    Mismatch,
    Timeout,
}

impl FailReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailReason::NoResults => "no_results",
            FailReason::TocParse => "toc_parse",
            FailReason::ContentShort => "content_short",
            FailReason::Blocked => "blocked",
            FailReason::NotFound => "not_found",
            FailReason::RateLimited => "rate_limited",
            FailReason::NetworkError => "network_error",
            FailReason::BookinfoFetch => "bookinfo_fetch",
            FailReason::TocFetch => "toc_fetch",
            FailReason::ChapterFetch => "chapter_fetch",
            FailReason::ServerError => "server_error",
            FailReason::BuilderError => "builder_error",
            FailReason::NoTocRule => "no_toc_rule",
            FailReason::NoContentRule => "no_content_rule",
            FailReason::ContentEmpty => "content_empty",
            FailReason::HttpError => "http_error",
            FailReason::NoBookUrl => "no_book_url",
            FailReason::StaticList => "static_list",
            FailReason::Mismatch => "mismatch",
            FailReason::Timeout => "timeout",
        }
    }

    pub fn from_str(s: &str) -> Option<FailReason> {
        Some(match s {
            "no_results" => FailReason::NoResults,
            "toc_parse" => FailReason::TocParse,
            "content_short" => FailReason::ContentShort,
            "blocked" => FailReason::Blocked,
            "not_found" => FailReason::NotFound,
            "rate_limited" => FailReason::RateLimited,
            "network_error" => FailReason::NetworkError,
            "bookinfo_fetch" => FailReason::BookinfoFetch,
            "toc_fetch" => FailReason::TocFetch,
            "chapter_fetch" => FailReason::ChapterFetch,
            "server_error" => FailReason::ServerError,
            "builder_error" => FailReason::BuilderError,
            "no_toc_rule" => FailReason::NoTocRule,
            "no_content_rule" => FailReason::NoContentRule,
            "content_empty" => FailReason::ContentEmpty,
            "http_error" => FailReason::HttpError,
            "no_book_url" => FailReason::NoBookUrl,
            "static_list" => FailReason::StaticList,
            "mismatch" => FailReason::Mismatch,
            "timeout" => FailReason::Timeout,
            _ => return None,
        })
    }
}

/// Human-readable message for the ArkTS UI.
pub fn fail_message(reason: &str) -> String {
    let msg = match reason {
        "no_results" => "未搜索到结果",
        "toc_parse" => "目录解析失败",
        "content_short" => "正文过短",
        "blocked" => "被站点拦截（403/401）",
        "not_found" => "页面不存在（404）",
        "rate_limited" => "请求过于频繁",
        "network_error" => "网络错误",
        "bookinfo_fetch" => "详情页获取失败",
        "toc_fetch" => "目录页获取失败",
        "chapter_fetch" => "章节页获取失败",
        "server_error" => "服务器错误（5xx）",
        "builder_error" => "无法构建搜索请求",
        "no_toc_rule" => "缺少目录规则",
        "no_content_rule" => "缺少正文规则",
        "content_empty" => "正文为空",
        "http_error" => "HTTP 错误",
        "no_book_url" => "未解析到书籍地址",
        "static_list" => "搜索结果疑似写死",
        "mismatch" => "详情页书名与搜索结果不一致",
        "timeout" => "超时",
        "needs_js" => "需要 JS（v1 不支持）",
        "needs_login" => "需要登录（v1 不支持）",
        "non_text" => "非文字源",
        "bad_url" => "书源地址无效",
        "no_capability" => "无搜索能力",
        "no_search_rule" => "缺少搜索规则",
        _ => "未知错误",
    };
    msg.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reason_roundtrip() {
        for r in [
            FailReason::NoResults,
            FailReason::Blocked,
            FailReason::NetworkError,
            FailReason::Timeout,
        ] {
            assert_eq!(FailReason::from_str(r.as_str()), Some(r));
        }
        assert_eq!(FailReason::from_str("bogus"), None);
    }
}