//! v1 capability gate for imported book sources.
//!
//! On top of basic preflight (text-only, enabled, URL fixable, searchable),
//! v1 excludes sources that need a JS runtime or login, since the Rust engine
//! does not execute JS. `@js:` L1 search patterns are still resolved.
//!
//! Produces per-source reasons so the import UI can show
//! "成功 N / 排除 M（需 JS、需登录、非文字）".

use serde::{Deserialize, Serialize};

use crate::rule_dsl::{content_rule_has_js, is_js_rule, toc_rule_has_js};
use crate::search_url::resolve_js_l1;
use crate::types::BookSource;
use crate::url_fixer;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GateReason {
    NonText,
    Disabled,
    BadUrl,
    NoCapability,
    NoSearchRule,
    NoTocRule,
    NoContentRule,
    NeedsJs,
    NeedsLogin,
}

impl GateReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            GateReason::NonText => "non_text",
            GateReason::Disabled => "disabled",
            GateReason::BadUrl => "bad_url",
            GateReason::NoCapability => "no_capability",
            GateReason::NoSearchRule => "no_search_rule",
            GateReason::NoTocRule => "no_toc_rule",
            GateReason::NoContentRule => "no_content_rule",
            GateReason::NeedsJs => "needs_js",
            GateReason::NeedsLogin => "needs_login",
        }
    }

    /// Whether the source could become usable in a future version (v2 JS).
    pub fn recoverable(&self) -> bool {
        matches!(self, GateReason::NeedsJs | GateReason::NeedsLogin)
    }
}

#[derive(Debug, Clone, Serialize)]
#[allow(non_snake_case)]
pub struct ExcludedSource {
    pub bookSourceName: String,
    pub bookSourceUrl: String,
    pub reason: String,
    pub detail: String,
    pub recoverable: bool,
}

#[derive(Debug, Clone, Serialize, Default)]
#[allow(non_snake_case)]
pub struct GateResult {
    pub total: usize,
    pub eligible: Vec<BookSource>,
    pub excluded: Vec<ExcludedSource>,
}

fn non_empty(v: &Option<String>) -> bool {
    v.as_deref().is_some_and(|s| !s.trim().is_empty())
}

fn has_search(s: &BookSource) -> bool {
    s.searchUrl
        .as_deref()
        .is_some_and(|u| !u.trim().is_empty() && u.trim() != "-" && u.trim() != "#")
}

/// Decide whether a single source is v1-eligible. Returns the sanitized source
/// on success, or a reason + detail on exclusion.
pub fn gate_one(mut source: BookSource) -> Result<BookSource, (GateReason, String)> {
    if source.bookSourceType != 0 {
        return Err((GateReason::NonText, format!("type={}", source.bookSourceType)));
    }
    if !source.enabled {
        return Err((GateReason::Disabled, "已禁用".into()));
    }

    // URL fix
    let raw = std::mem::take(&mut source.bookSourceUrl);
    match url_fixer::fix_url(&raw) {
        Some(u) => source.bookSourceUrl = u,
        None => return Err((GateReason::BadUrl, raw)),
    }

    // Login sources
    if non_empty(&source.loginUrl) || non_empty(&source.loginUi) || non_empty(&source.loginCheckJs) {
        return Err((GateReason::NeedsLogin, "含 loginUrl/loginUi/loginCheckJs".into()));
    }

    // Search capability
    if !has_search(&source) {
        return Err((GateReason::NoCapability, "无 searchUrl（v1 不支持发现）".into()));
    }

    // JS gate
    let search_url = source.searchUrl.as_deref().unwrap_or("");
    if search_url.contains("<js>") {
        return Err((GateReason::NeedsJs, "searchUrl 含 <js> 块".into()));
    }
    if search_url.starts_with("@js:")
        && resolve_js_l1(search_url, &source.bookSourceUrl, "1").is_none()
    {
        return Err((GateReason::NeedsJs, "searchUrl 为非 L1 的 @js:".into()));
    }

    // Critical field-level JS
    if source.ruleSearch.as_ref().is_none() {
        return Err((GateReason::NoSearchRule, "缺少 ruleSearch".into()));
    }
    if let Some(rs) = source.ruleSearch.as_ref() {
        for (name, field) in [
            ("bookList", rs.bookList.as_deref()),
            ("name", rs.name.as_deref()),
            ("bookUrl", rs.bookUrl.as_deref()),
        ] {
            if field.is_some_and(is_js_rule) {
                return Err((GateReason::NeedsJs, format!("ruleSearch.{name} 含 JS")));
            }
        }
    }
    match source.ruleToc.as_ref() {
        None => return Err((GateReason::NoTocRule, "缺少 ruleToc".into())),
        Some(t) => {
            if !t.chapterList.as_deref().is_some_and(|s| !s.trim().is_empty()) {
                return Err((GateReason::NoTocRule, "缺少 ruleToc.chapterList".into()));
            }
            if toc_rule_has_js(t) {
                return Err((GateReason::NeedsJs, "ruleToc 含 JS".into()));
            }
        }
    }
    match source.ruleContent.as_ref() {
        None => return Err((GateReason::NoContentRule, "缺少 ruleContent".into())),
        Some(c) => {
            if !c.content.as_deref().is_some_and(|s| !s.trim().is_empty()) {
                return Err((GateReason::NoContentRule, "缺少 ruleContent.content".into()));
            }
            if content_rule_has_js(c) {
                return Err((GateReason::NeedsJs, "ruleContent 含 JS".into()));
            }
        }
    }

    // Optional field JS → degrade (drop the rule so we don't emit garbage).
    if let Some(rs) = source.ruleSearch.as_mut() {
        if rs.coverUrl.as_deref().is_some_and(is_js_rule) {
            rs.coverUrl = None;
        }
        if rs.intro.as_deref().is_some_and(is_js_rule) {
            rs.intro = None;
        }
        if rs.kind.as_deref().is_some_and(is_js_rule) {
            rs.kind = None;
        }
        if rs.lastChapter.as_deref().is_some_and(is_js_rule) {
            rs.lastChapter = None;
        }
        if rs.wordCount.as_deref().is_some_and(is_js_rule) {
            rs.wordCount = None;
        }
    }
    if let Some(bi) = source.ruleBookInfo.as_mut() {
        if bi.coverUrl.as_deref().is_some_and(is_js_rule) {
            bi.coverUrl = None;
        }
        if bi.intro.as_deref().is_some_and(is_js_rule) {
            bi.intro = None;
        }
        if bi.tocUrl.as_deref().is_some_and(is_js_rule) {
            bi.tocUrl = None;
        }
    }

    Ok(source)
}

/// Run the gate over a batch of sources, splitting eligible from excluded.
pub fn run(sources: Vec<BookSource>) -> GateResult {
    let total = sources.len();
    let mut eligible = Vec::new();
    let mut excluded = Vec::new();
    for source in sources {
        let name = source.bookSourceName.clone();
        let url = source.bookSourceUrl.clone();
        match gate_one(source) {
            Ok(s) => eligible.push(s),
            Err((reason, detail)) => excluded.push(ExcludedSource {
                bookSourceName: name,
                bookSourceUrl: url,
                reason: reason.as_str().to_string(),
                detail,
                recoverable: reason.recoverable(),
            }),
        }
    }
    GateResult {
        total,
        eligible,
        excluded,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ContentRule, SearchRule, TocRule};

    fn base() -> BookSource {
        BookSource {
            bookSourceName: "s".into(),
            bookSourceUrl: "https://x.com".into(),
            bookSourceType: 0,
            enabled: true,
            searchUrl: Some("/s?q={{key}}".into()),
            ruleSearch: Some(SearchRule {
                bookList: Some("class.item".into()),
                name: Some("a@text".into()),
                bookUrl: Some("a@href".into()),
                ..Default::default()
            }),
            ruleToc: Some(TocRule {
                chapterList: Some("li".into()),
                chapterUrl: Some("a@href".into()),
                chapterName: Some("a@text".into()),
                ..Default::default()
            }),
            ruleContent: Some(ContentRule {
                content: Some("div#content@text".into()),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn test_pass() {
        assert!(gate_one(base()).is_ok());
    }

    #[test]
    fn test_non_text() {
        let mut s = base();
        s.bookSourceType = 1;
        assert_eq!(gate_one(s).unwrap_err().0, GateReason::NonText);
    }

    #[test]
    fn test_needs_js_search() {
        let mut s = base();
        s.searchUrl = Some("<js>1</js>".into());
        assert_eq!(gate_one(s).unwrap_err().0, GateReason::NeedsJs);
    }

    #[test]
    fn test_needs_js_field() {
        let mut s = base();
        s.ruleSearch.as_mut().unwrap().bookUrl = Some("@js:1".into());
        assert_eq!(gate_one(s).unwrap_err().0, GateReason::NeedsJs);
    }

    #[test]
    fn test_needs_login() {
        let mut s = base();
        s.loginUrl = Some("https://x.com/login".into());
        assert_eq!(gate_one(s).unwrap_err().0, GateReason::NeedsLogin);
    }

    #[test]
    fn test_optional_js_degrades() {
        let mut s = base();
        s.ruleSearch.as_mut().unwrap().coverUrl = Some("@js:1".into());
        let ok = gate_one(s).unwrap();
        assert!(ok.ruleSearch.unwrap().coverUrl.is_none());
    }

    #[test]
    fn test_batch_run() {
        let mut a = base();
        a.bookSourceName = "good".into();
        let mut b = base();
        b.bookSourceName = "bad".into();
        b.bookSourceType = 1;
        let r = run(vec![a, b]);
        assert_eq!(r.total, 2);
        assert_eq!(r.eligible.len(), 1);
        assert_eq!(r.excluded.len(), 1);
        assert_eq!(r.excluded[0].reason, "non_text");
    }
}