use regex::Regex;

use super::parser::RuleToken;

/// Apply a chain of rule tokens against extracted strings.
///
/// Handles `||` fallback, `##` regex replacement, and `!0` index exclusion.
pub fn apply_combinators(values: Vec<String>, tokens: &[RuleToken]) -> Vec<String> {
    let mut results = values;
    let mut remaining = tokens;

    while !remaining.is_empty() {
        let token = &remaining[0];
        remaining = &remaining[1..];

        match token {
            RuleToken::Fallback => {
                // If we already have results, stop — || means "use first non-empty"
                if !results.is_empty() && !results.iter().all(|s| s.trim().is_empty()) {
                    return results;
                }
                // Otherwise clear and continue with next segment
                results.clear();
            }
            RuleToken::RegexReplace { pattern, replacement } => {
                if let Ok(re) = Regex::new(pattern) {
                    let expanded = normalize_replacement(replacement);
                    results = results
                        .into_iter()
                        .map(|s| re.replace_all(&s, expanded.as_str()).to_string())
                        .collect();
                }
            }
            // Index / ExcludeIndex are fully consumed by the HTML/JSON
            // extractors (`.n` takes, `!n` excludes). Applying them again here
            // would double-apply and delete already-extracted values, so they
            // are intentionally ignored.
            _ => {}
        }
    }

    results
}

/// Rewrite Java-style `$1` replacement references into the `regex` crate's
/// unambiguous `${1}` form. Without this, `$1s` is read as capture group `"1s"`
/// (which does not exist) and silently expands to an empty string — Legado
/// sources use patterns like `.../$1s.jpg`.
fn normalize_replacement(replacement: &str) -> String {
    let mut out = String::with_capacity(replacement.len() + 4);
    let mut chars = replacement.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if c != '$' {
            out.push(c);
            continue;
        }
        let start = i + 1;
        let mut end = start;
        while let Some(&(j, d)) = chars.peek() {
            if d.is_ascii_digit() {
                end = j + 1;
                chars.next();
            } else {
                break;
            }
        }
        if end > start {
            out.push_str("${");
            out.push_str(&replacement[start..end]);
            out.push('}');
        } else {
            out.push('$');
        }
    }
    out
}

/// Merge multiple rule result sets using `||` semantics:
/// Return the first non-empty set, or empty if all empty.
pub fn merge_fallback(results: &[Vec<String>]) -> Vec<String> {
    for r in results {
        if !r.is_empty() && !r.iter().all(|s| s.trim().is_empty()) {
            return r.clone();
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rule_dsl::parser::tokenize;

    #[test]
    fn test_regex_replace() {
        let tokens = tokenize("$.name##(\\d+)##NUM:$1");
        // tokens: [JsonPath, RegexReplace]
        assert_eq!(tokens.len(), 2);
    }

    #[test]
    fn test_fallback_semantics() {
        let first = vec!["".to_string()];
        let second = vec!["result".to_string()];
        let merged = merge_fallback(&[first, second]);
        assert_eq!(merged, vec!["result"]);
    }

    #[test]
    fn test_apply_combinators_noop() {
        // No combinator tokens → unchanged
        let tokens = tokenize("class.name@text");
        let values = vec!["hello".to_string()];
        let result = apply_combinators(values.clone(), &tokens);
        assert_eq!(result, vec!["hello"]);
    }

    #[test]
    fn test_apply_combinators_regex_replace() {
        let tokens = tokenize("$.name##(\\d+)##NUM:$1");
        let values = vec!["page123".to_string()];
        let result = apply_combinators(values, &tokens);
        // re.replace_all replaces the matched portion, preserving prefix text
        assert_eq!(result[0], "pageNUM:123");
    }

    #[test]
    fn test_normalize_replacement_java_style() {
        assert_eq!(normalize_replacement("$1s.jpg"), "${1}s.jpg");
        assert_eq!(normalize_replacement("${1}s.jpg"), "${1}s.jpg");
        assert_eq!(normalize_replacement("x/$2/$1"), "x/${2}/${1}");
        assert_eq!(normalize_replacement("plain"), "plain");
    }

    #[test]
    fn test_regex_replace_group_followed_by_letter() {
        // Legado cover rule: `.../$1s.jpg` must expand group 1 then literal `s`.
        let tokens = tokenize("$.id##^(\\d+)$##http://x/$1/$1s.jpg");
        let values = vec!["19525".to_string()];
        let result = apply_combinators(values, &tokens);
        assert_eq!(result[0], "http://x/19525/19525s.jpg");
    }

    #[test]
    fn test_apply_combinators_ignores_index_tokens() {
        // Index/ExcludeIndex are consumed by the extractors; the combinator
        // must NOT re-apply them (that used to delete extracted values).
        let tokens = vec![RuleToken::Index(0)];
        let values = vec!["first".to_string(), "second".to_string()];
        let result = apply_combinators(values, &tokens);
        assert_eq!(result, vec!["first", "second"]);
    }

    #[test]
    fn test_apply_combinators_fallback_uses_first() {
        // With fallback semantics, first non-empty result wins
        let tokens = tokenize("class.a@text||class.b@text");
        let values = vec!["first".to_string()];
        let result = apply_combinators(values, &tokens);
        // Fallback token stops at first non-empty — "first" is non-empty
        assert_eq!(result, vec!["first"]);
    }
}
