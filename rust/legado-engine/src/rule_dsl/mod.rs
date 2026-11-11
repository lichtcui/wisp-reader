pub mod combinator;
pub mod html_extractor;
pub mod json_extractor;
pub mod parser;

use crate::types::{ContentRule, Diagnostic, SearchRule, TocRule};
use parser::RuleToken;

/// Extract values from `content` (HTML or JSON) applying a single Legado DSL rule.
pub fn extract_single(content: &str, content_type: &str, rule: &str) -> Vec<String> {
    let tokens = parser::tokenize(rule);
    if json_ct(content_type) {
        match serde_json::from_str(content) {
            Ok(json) => json_extractor::extract(&json, &tokens),
            Err(_) => Vec::new(),
        }
    } else {
        html_extractor::extract(content, &tokens)
    }
}

fn json_ct(content_type: &str) -> bool {
    content_type.contains("json")
}

/// Whether a rule string needs the JS runtime (which v1 does not execute).
pub fn is_js_rule(v: &str) -> bool {
    let v = v.trim();
    v.starts_with("@js:") || v.starts_with("<js>") || v.contains("java.") || v.contains("<js>")
}

/// Whether a search rule contains JS in any field.
pub fn search_rule_has_js(rule: &SearchRule) -> bool {
    [
        rule.bookList.as_deref(),
        rule.name.as_deref(),
        rule.author.as_deref(),
        rule.bookUrl.as_deref(),
        rule.coverUrl.as_deref(),
        rule.intro.as_deref(),
        rule.kind.as_deref(),
        rule.lastChapter.as_deref(),
        rule.wordCount.as_deref(),
    ]
    .into_iter()
    .flatten()
    .any(is_js_rule)
}

pub fn toc_rule_has_js(rule: &TocRule) -> bool {
    [
        rule.chapterList.as_deref(),
        rule.chapterName.as_deref(),
        rule.chapterUrl.as_deref(),
        rule.nextTocUrl.as_deref(),
    ]
    .into_iter()
    .flatten()
    .any(is_js_rule)
}

pub fn content_rule_has_js(rule: &ContentRule) -> bool {
    [rule.content.as_deref(), rule.nextContentUrl.as_deref()]
        .into_iter()
        .flatten()
        .any(is_js_rule)
}

// ── Search ────────────────────────────────────────────────────

/// One row of a book-search result (7 fields, matching Legado).
#[derive(Debug, Clone, Default)]
pub struct SearchItem {
    pub name: String,
    pub author: String,
    pub book_url: String,
    pub cover_url: String,
    pub intro: String,
    pub kind: String,
    pub word_count: String,
    pub last_chapter: String,
}

/// Extract per-item search rows. Each item keeps its HTML/JSON snippet so
/// field rules run in the item's own context (not the whole document).
pub fn extract_search_items(content: &str, content_type: &str, rule: &SearchRule) -> Vec<SearchItem> {
    let Some(book_list) = rule.bookList.as_deref() else {
        return Vec::new();
    };
    let items = extract_items_raw(content, content_type, book_list);
    let mut out = Vec::with_capacity(items.len());
    for item in &items {
        let row = SearchItem {
            name: apply_field(item, content_type, rule.name.as_deref()),
            author: apply_field(item, content_type, rule.author.as_deref()),
            book_url: apply_field(item, content_type, rule.bookUrl.as_deref()),
            cover_url: apply_field(item, content_type, rule.coverUrl.as_deref()),
            intro: apply_field(item, content_type, rule.intro.as_deref()),
            kind: apply_field(item, content_type, rule.kind.as_deref()),
            word_count: apply_field(item, content_type, rule.wordCount.as_deref()),
            last_chapter: apply_field(item, content_type, rule.lastChapter.as_deref()),
        };
        if !row.name.trim().is_empty() || !row.author.trim().is_empty() || !row.book_url.trim().is_empty()
        {
            out.push(row);
        }
    }
    out
}

/// Whether extracted search rows contain usable data.
pub fn has_valid_results(items: &[SearchItem]) -> bool {
    items
        .iter()
        .any(|i| !i.name.trim().is_empty() || !i.author.trim().is_empty())
}

/// Extract raw item snippets via the `bookList` rule; JSON arrays are expanded
/// into individual elements.
pub fn extract_items_raw(content: &str, content_type: &str, book_list_rule: &str) -> Vec<String> {
    let rule = if book_list_rule.trim().is_empty() {
        "."
    } else {
        book_list_rule
    };
    let vals = extract_single(content, content_type, rule);
    let mut items = Vec::new();
    for v in vals {
        let v = v.trim();
        if v.is_empty() {
            continue;
        }
        if let serde_json::Value::Array(elems) =
            serde_json::from_str::<serde_json::Value>(v).unwrap_or(serde_json::Value::Null)
        {
            for e in elems {
                items.push(e.to_string());
            }
            continue;
        }
        items.push(v.to_string());
    }
    items
}

fn apply_field(item: &str, content_type: &str, rule: Option<&str>) -> String {
    let Some(rule) = rule.map(str::trim).filter(|r| !r.is_empty() && *r != "-" && *r != "#") else {
        return String::new();
    };
    if is_js_rule(rule) {
        return String::new();
    }
    let out = extract_single(item, content_type, rule);
    if let Some(first) = out.first().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
        return first;
    }
    // Template rules like `https://api/x?id={{$.id}}` against JSON items.
    if rule.contains("{{") && json_ct(content_type)
        && let Ok(json) = serde_json::from_str::<serde_json::Value>(item)
        && let Some(expanded) = expand_template(rule, &json)
    {
        return expanded;
    }
    String::new()
}

// ── TOC ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct TocItem {
    pub name: String,
    pub url: String,
    pub is_vip: bool,
    pub is_volume: bool,
}

/// Extract TOC entries (name, url, isVip, isVolume).
pub fn extract_toc(content: &str, content_type: &str, rule: &TocRule) -> Vec<TocItem> {
    let Some(chapter_list) = rule.chapterList.as_deref() else {
        return Vec::new();
    };
    let items = extract_items_raw(content, content_type, chapter_list);
    let mut out = Vec::with_capacity(items.len());
    for item in &items {
        let name = apply_field(item, content_type, rule.chapterName.as_deref());
        let url = apply_field(item, content_type, rule.chapterUrl.as_deref());
        if name.is_empty() && url.is_empty() {
            continue;
        }
        let is_vip = !apply_field(item, content_type, rule.isVip.as_deref()).is_empty();
        let is_volume = !apply_field(item, content_type, rule.isVolume.as_deref()).is_empty();
        out.push(TocItem { name, url, is_vip, is_volume });
    }
    out
}

// ── Templates ─────────────────────────────────────────────────

/// Expand every `{{...}}` placeholder against a JSON value. Supports fallbacks
/// like `{{$.a||$.b}}`. Returns None if any placeholder fails to resolve.
pub fn expand_template(tpl: &str, json: &serde_json::Value) -> Option<String> {
    // 静态正则：`{{...}}` 模板在目录/正文规则里频繁出现，避免每次重新编译。
    static TEMPLATE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = TEMPLATE_RE.get_or_init(|| {
        regex::Regex::new(r"\{\{(.*?)}}").expect("static template regex is valid")
    });
    let mut out = tpl.to_string();
    for cap in re.captures_iter(tpl) {
        let inner = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let mut resolved = None;
        for seg in inner.split("||") {
            let path = seg.trim().trim_start_matches('$').trim_start_matches('.');
            if let Some(v) = json_extractor::json_path_find(json, path)
                && !v.is_empty()
            {
                resolved = Some(v);
                break;
            }
        }
        let Some(v) = resolved else {
            return None;
        };
        out = out.replacen(cap.get(0).map(|m| m.as_str()).unwrap_or(""), &v, 1);
    }
    if out.contains("{{") { None } else { Some(out) }
}

// ── Diagnostics ───────────────────────────────────────────────

/// Validate a rule and report unsupported / un-compilable parts (Java-regex
/// lookaround, bad CSS selectors) instead of silently returning empty.
pub fn diagnose(rule: &str) -> Vec<Diagnostic> {
    let mut diags = Vec::new();
    for token in parser::tokenize(rule) {
        match token {
            RuleToken::RegexReplace { pattern, .. } => {
                if let Err(e) = regex::Regex::new(&pattern) {
                    diags.push(Diagnostic {
                        kind: "regex".into(),
                        rule: rule.into(),
                        message: format!("正则编译失败（Rust regex 不支持 Java lookaround/反向引用）: {e}"),
                    });
                }
            }
            RuleToken::CssClass(name) => check_css(&format!(".{name}"), rule, &mut diags),
            RuleToken::CssId(name) => check_css(&format!("#{name}"), rule, &mut diags),
            RuleToken::CssOverride(sel) => check_css(&sel, rule, &mut diags),
            RuleToken::TagName(name) | RuleToken::TagShort(name) => check_css(&name, rule, &mut diags),
            RuleToken::JsBlock(_) | RuleToken::JsTransform(_) => {
                diags.push(Diagnostic {
                    kind: "js".into(),
                    rule: rule.into(),
                    message: "包含 JS 规则，v1 不执行 JS 运行时".into(),
                });
            }
            RuleToken::Unsupported(token) => {
                diags.push(Diagnostic {
                    kind: "unsupported".into(),
                    rule: rule.into(),
                    message: format!("不支持的规则段: {token}"),
                });
            }
            _ => {}
        }
    }
    diags
}

fn check_css(selector: &str, rule: &str, diags: &mut Vec<Diagnostic>) {
    if selector.trim().is_empty() {
        return;
    }
    if scraper::Selector::parse(selector).is_err() {
        diags.push(Diagnostic {
            kind: "css".into(),
            rule: rule.into(),
            message: format!("CSS 选择器解析失败: {selector}"),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(book_list: &str, name: &str, author: &str, url: &str) -> SearchRule {
        SearchRule {
            bookList: Some(book_list.into()),
            name: Some(name.into()),
            author: Some(author.into()),
            bookUrl: Some(url.into()),
            ..Default::default()
        }
    }

    #[test]
    fn test_extract_search_items_html() {
        let html = r#"<ul>
            <li class="book"><span class="title">Book1</span><span class="author">A1</span><a href="/b/1">go</a></li>
            <li class="book"><span class="title">Book2</span><span class="author">A2</span><a href="/b/2">go</a></li>
        </ul>"#;
        let r = rule("class.book", "class.title@text", "class.author@text", "a@href");
        let items = extract_search_items(html, "html", &r);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].name, "Book1");
        assert_eq!(items[0].book_url, "/b/1");
        assert_eq!(items[1].author, "A2");
    }

    #[test]
    fn test_extract_search_items_json() {
        let json = r#"{"books":[{"title":"B1","author":"A1","id":9}]}"#;
        let r = SearchRule {
            bookList: Some("$.books[*]".into()),
            name: Some("$.title".into()),
            author: Some("$.author".into()),
            bookUrl: Some("https://x/b/{{$.id}}".into()),
            ..Default::default()
        };
        let items = extract_search_items(json, "json", &r);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].name, "B1");
        assert_eq!(items[0].book_url, "https://x/b/9");
    }

    #[test]
    fn test_extract_toc_volume() {
        let html = r#"<div>
            <li class="vol"><span>第一卷</span></li>
            <li class="ch"><a href="/c/1">第1章</a></li>
            <li class="ch"><a href="/c/2">第2章</a></li>
        </div>"#;
        let r = TocRule {
            chapterList: Some("li".into()),
            chapterName: Some("@text".into()),
            chapterUrl: Some("a@href".into()),
            isVolume: Some("@css:span@text".into()),
            ..Default::default()
        };
        let toc = extract_toc(html, "html", &r);
        assert_eq!(toc.len(), 3);
        assert!(toc[0].is_volume);
        assert_eq!(toc[1].url, "/c/1");
        assert!(!toc[1].is_volume);
    }

    #[test]
    fn test_diagnose_bad_regex_and_ok_css() {
        let d = diagnose("$.name##(?<=a)b##x");
        assert!(d.iter().any(|x| x.kind == "regex"), "lookbehind must be flagged");
        let d = diagnose("class.book@tag.a@href");
        assert!(d.is_empty(), "valid rule has no diagnostics: {d:?}");
    }

    #[test]
    fn test_diagnose_unsupported_namespace() {
        let d = diagnose("xpath.body@text");
        assert_eq!(d.len(), 1, "{d:?}");
        assert_eq!(d[0].kind, "unsupported");

        let d = diagnose("div@xpath://p");
        assert!(d.iter().any(|x| x.kind == "unsupported"), "{d:?}");
    }

    #[test]
    fn test_diagnose_known_legado_gaps() {
        for rule in ["children.div@text", "div@ownText", "div@all"] {
            let d = diagnose(rule);
            assert_eq!(d.len(), 1, "{rule}: {d:?}");
            assert_eq!(d[0].kind, "unsupported", "{rule}: {d:?}");
        }
    }

    #[test]
    fn test_diagnose_keeps_valid_dotted_css_selectors() {
        for rule in [
            ".item@text",
            "span.last@text",
            "div#content.showtxt@text",
            "section.toolbar@text",
        ] {
            let d = diagnose(rule);
            assert!(d.is_empty(), "{rule}: {d:?}");
        }
    }

    #[test]
    fn test_valid_zero_results_are_not_diagnostics() {
        let html = "<div class='present'>正文</div>";
        assert!(extract_single(html, "html", "class.missing@text").is_empty());
        assert!(diagnose("class.missing@text").is_empty());
    }
}
