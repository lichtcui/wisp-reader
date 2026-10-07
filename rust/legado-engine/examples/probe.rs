//! 主机侧引擎探针（probe）：不上设备、不装 HAP，直接在 macOS 上跑一遍书源链路。
//!
//! 用法（等价于 `make probe ARGS='…'`）：
//!   cargo run --release --example probe -- <sources.json> <命令> [参数] [选项]
//!
//! 命令：
//!   gate                        走一遍导入门禁，打印 eligible / excluded 摘要
//!   search <关键词>             并发搜索（默认并发 8、超时 10s）
//!   info  <bookUrl>             书源详情
//!   toc   <tocUrl>              目录（含卷标记统计）
//!   content <chapterUrl>        整章正文（含 nextUrl）
//!   detect [关键词]             逐源校验「搜索→详情→目录→正文」链路
//!   fetch <url>                 直接抓一个 URL（看长度/编码效果/前缀）
//!   parse <contentType> <rule>  从 stdin 读正文，单条规则 DSL 调试 + 诊断
//!
//! 选项：
//!   --index N        用第 N 个源（默认 0，供 info/toc/content 这类单源命令用）
//!   --limit N        样本条数上限（默认 5）
//!   --concurrency N  搜索并发（默认 8）
//!   --timeout MS     单请求超时毫秒（默认 10000；detect 默认用引擎的 45000）
//!   --json           直接 dump 完整 JSON（默认只打印摘要，免得刷爆上下文）
//!
//! `sources.json` 可以是 `[ … ]`（多源）或 `{ … }`（单源）；内置源可直接用
//! `entry/src/main/resources/rawfile/bundled-sources.json`。
//!
//! 注意：`info` 的 name/author 可能是空串——部分源压根没写 `ruleBookInfo.name/author`（详情页由搜索结果兼底），
//! 所以这不是引擎 bug；`detect` 只看「搜索→详情→目录→正文」能不能走通，不看字段是否齐全。
//!
//! 为什么要它：改规则 DSL / URL 模板 / 门禁时，这是**秒级**反馈（无需设备、
//! 无需 HAP），而 `make run` 一轮要分钟级。网络仍全部在 Rust 侧，与 App 同一条链路。

use std::io::Read;
use std::process::ExitCode;

use legado_engine::{gate, runtime, types};

struct Opts {
    index: usize,
    limit: usize,
    concurrency: usize,
    timeout_ms: u64,
    json: bool,
}

impl Default for Opts {
    fn default() -> Self {
        Self { index: 0, limit: 5, concurrency: 8, timeout_ms: 10_000, json: false }
    }
}

/// 按字符（而非字节）截断，避免切坏中文。
fn head(s: &str, n: usize) -> String {
    let mut out: String = s.chars().take(n).collect();
    if s.chars().count() > n {
        out.push('…');
    }
    out
}

fn dump<T: serde::Serialize>(value: &T) {
    match serde_json::to_string_pretty(value) {
        Ok(s) => println!("{s}"),
        Err(e) => println!("（JSON 序列化失败：{e}）"),
    }
}

fn load_sources(path: &str) -> Result<Vec<types::BookSource>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("读不到 {path}：{e}"))?;
    let trimmed = text.trim_start();
    if trimmed.starts_with('[') {
        serde_json::from_str::<Vec<types::BookSource>>(&text)
            .map_err(|e| format!("书源数组解析失败：{e}"))
    } else {
        serde_json::from_str::<types::BookSource>(&text)
            .map(|s| vec![s])
            .map_err(|e| format!("单书源解析失败：{e}"))
    }
}

fn one<'a>(sources: &'a [types::BookSource], opts: &Opts) -> Result<&'a types::BookSource, String> {
    sources
        .get(opts.index)
        .ok_or_else(|| format!("--index {} 越界（共 {} 个源）", opts.index, sources.len()))
}

#[tokio::main]
async fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut positional: Vec<String> = Vec::new();
    let mut opts = Opts::default();

    let mut i = 0;
    while i < argv.len() {
        match argv[i].as_str() {
            "--json" => opts.json = true,
            "--index" | "--limit" | "--concurrency" | "--timeout" => {
                let key = argv[i].clone();
                let raw = argv.get(i + 1).cloned().unwrap_or_default();
                let val: u64 = match raw.parse() {
                    Ok(v) => v,
                    Err(_) => {
                        println!("{key} 需要一个数字，收到 `{raw}`");
                        return ExitCode::FAILURE;
                    }
                };
                match key.as_str() {
                    "--index" => opts.index = val as usize,
                    "--limit" => opts.limit = val as usize,
                    "--concurrency" => opts.concurrency = (val as usize).max(1),
                    _ => opts.timeout_ms = val,
                }
                i += 1;
            }
            other => positional.push(other.to_string()),
        }
        i += 1;
    }

    let (path, cmd) = match (positional.first(), positional.get(1)) {
        (Some(p), Some(c)) => (p.clone(), c.clone()),
        _ => {
            println!("用法：probe <sources.json> <gate|search|info|toc|content|detect|fetch|parse> [参数]");
            println!("详见本文件头部注释（rust/legado-engine/examples/probe.rs）");
            return ExitCode::FAILURE;
        }
    };
    let rest: Vec<String> = positional.iter().skip(2).cloned().collect();

    let sources = match load_sources(&path) {
        Ok(s) => s,
        Err(e) => {
            println!("✗ {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("探针：{} 个书源 ← {path}", sources.len());

    let result: Result<(), String> = match cmd.as_str() {
        "gate" => cmd_gate(sources, &opts),
        "search" => cmd_search(&sources, rest.first(), &opts).await,
        "info" => cmd_info(&sources, rest.first(), &opts).await,
        "toc" => cmd_toc(&sources, rest.first(), &opts).await,
        "content" => cmd_content(&sources, rest.first(), &opts).await,
        "detect" => cmd_detect(&sources, rest.first(), &opts).await,
        "fetch" => cmd_fetch(rest.first()).await,
        "parse" => cmd_parse(&rest),
        other => Err(format!("未知命令 `{other}`")),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            println!("✗ {e}");
            ExitCode::FAILURE
        }
    }
}

fn cmd_gate(sources: Vec<types::BookSource>, opts: &Opts) -> Result<(), String> {
    let out = gate::run(sources);
    println!(
        "门禁：total {} / eligible {} / excluded {}",
        out.total,
        out.eligible.len(),
        out.excluded.len()
    );
    if opts.json {
        dump(&out);
        return Ok(());
    }
    for e in out.excluded.iter().take(opts.limit.max(20)) {
        println!(
            "  [排除] {}（{}）{} · {}",
            e.bookSourceName,
            e.reason,
            e.bookSourceUrl,
            head(&e.detail, 60)
        );
    }
    if out.excluded.len() > opts.limit.max(20) {
        println!("  …（省略 {} 条）", out.excluded.len() - opts.limit.max(20));
    }
    Ok(())
}

async fn cmd_search(
    sources: &[types::BookSource],
    keyword: Option<&String>,
    opts: &Opts,
) -> Result<(), String> {
    let keyword = keyword.ok_or("用法：search <关键词>")?;
    let search_opts = runtime::SearchOptions {
        timeout_ms: opts.timeout_ms,
        concurrency: opts.concurrency,
    };
    let started = std::time::Instant::now();
    let out = runtime::search(sources, keyword, &search_opts).await;
    if opts.json {
        dump(&out);
        return Ok(());
    }
    let ok = out.sources.iter().filter(|s| s.ok).count();
    println!(
        "搜索「{}」：{} 源出 {} 条，成功 {}/{}，用时 {}ms",
        keyword,
        out.sources.len(),
        out.items.len(),
        ok,
        out.sources.len(),
        started.elapsed().as_millis()
    );
    for s in &out.sources {
        println!(
            "  [{}] {} {} 条 {}ms {}",
            if s.ok { "ok" } else { "!!" },
            s.sourceName,
            s.count,
            s.elapsedMs,
            head(&s.error, 60)
        );
    }
    println!("样本 {}/{}：", out.items.len().min(opts.limit), out.items.len());
    for (n, it) in out.items.iter().take(opts.limit).enumerate() {
        println!(
            "  {}. {} — {}（{}）{}",
            n + 1,
            it.name,
            it.author,
            it.sourceName,
            it.bookUrl
        );
    }
    Ok(())
}

async fn cmd_info(
    sources: &[types::BookSource],
    url: Option<&String>,
    opts: &Opts,
) -> Result<(), String> {
    let url = url.ok_or("用法：info <bookUrl>")?;
    let src = one(sources, opts)?;
    let info = runtime::book_info(src, url).await?;
    if opts.json {
        dump(&info);
        return Ok(());
    }
    println!("详情：{} — {}", info.name, info.author);
    println!("  来源：{}", info.sourceUrl);
    println!("  种类：{} · 状态：{} · 字数：{}", info.kind, info.status, info.wordCount);
    println!("  最新章节：{}", info.lastChapterTitle);
    println!("  封面：{}", info.coverUrl);
    println!("  目录页：{}", info.tocUrl);
    println!("  简介：{}", head(&info.intro, 120));
    Ok(())
}

async fn cmd_toc(
    sources: &[types::BookSource],
    url: Option<&String>,
    opts: &Opts,
) -> Result<(), String> {
    let url = url.ok_or("用法：toc <tocUrl>")?;
    let src = one(sources, opts)?;
    let chapters = runtime::toc(src, url).await?;
    if opts.json {
        dump(&chapters);
        return Ok(());
    }
    let volumes = chapters.iter().filter(|c| c.isVolume).count();
    let vip = chapters.iter().filter(|c| c.isVip).count();
    println!(
        "目录：{} 条（卷标记 {}，VIP {}）",
        chapters.len(),
        volumes,
        vip
    );
    for (n, c) in chapters.iter().take(opts.limit).enumerate() {
        println!(
            "  {}. {}{} {}",
            n + 1,
            if c.isVolume { "[卷] " } else { "" },
            c.title,
            c.url
        );
    }
    for c in chapters.iter().rev().take(2).rev() {
        println!("  … 末尾：{} {}", c.title, c.url);
    }
    Ok(())
}

async fn cmd_content(
    sources: &[types::BookSource],
    url: Option<&String>,
    opts: &Opts,
) -> Result<(), String> {
    let url = url.ok_or("用法：content <chapterUrl>")?;
    let src = one(sources, opts)?;
    let out = runtime::content(src, url).await?;
    if opts.json {
        dump(&out);
        return Ok(());
    }
    println!(
        "正文：{} 字，nextUrl={}",
        out.content.chars().count(),
        if out.nextUrl.is_empty() { "（无）" } else { &out.nextUrl }
    );
    println!("  开头：{}", head(&out.content, 200));
    let tail: String = out.content.chars().rev().take(120).collect::<Vec<char>>().into_iter().rev().collect();
    println!("  结尾：{}", tail.replace('\n', "⏎"));
    Ok(())
}

async fn cmd_detect(
    sources: &[types::BookSource],
    keyword: Option<&String>,
    opts: &Opts,
) -> Result<(), String> {
    let keyword = keyword.map(|s| s.as_str()).unwrap_or("重生");
    let timeout = if opts.timeout_ms == 10_000 {
        runtime::DEFAULT_DETECT_TIMEOUT_MS
    } else {
        opts.timeout_ms
    };
    let results = runtime::detect(sources, keyword, opts.concurrency, timeout).await;
    if opts.json {
        dump(&results);
        return Ok(());
    }
    let ok = results.iter().filter(|r| r.ok).count();
    println!("链路校验：{}/{} 可用（关键词「{keyword}」）", ok, results.len());
    for r in &results {
        println!(
            "  [{}] {} · {} · {} 字 · {}ms · {}",
            if r.ok { "ok" } else { "!!" },
            r.sourceName,
            r.stage,
            r.contentLen,
            r.elapsedMs,
            head(&r.detail, 70)
        );
    }
    Ok(())
}

async fn cmd_fetch(url: Option<&String>) -> Result<(), String> {
    let url = url.ok_or("用法：fetch <url>")?;
    let body = legado_engine::fetch_text(url).await?;
    println!("抓取：{} 字", body.chars().count());
    println!("  开头：{}", head(&body, 300));
    Ok(())
}

fn cmd_parse(rest: &[String]) -> Result<(), String> {
    let (content_type, rule) = match (rest.first(), rest.get(1)) {
        (Some(c), Some(r)) => (c.clone(), r.clone()),
        _ => return Err("用法：parse <contentType> <rule>（正文从 stdin 读）".to_string()),
    };
    let mut content = String::new();
    std::io::stdin()
        .read_to_string(&mut content)
        .map_err(|e| format!("读 stdin 失败：{e}"))?;
    let out: types::ParseOutput = legado_engine::parse_with_diagnostics(&content, &content_type, &rule);
    println!("规则 `{rule}`（{}）：{} 个结果", content_type, out.values.len());
    for (n, v) in out.values.iter().take(10).enumerate() {
        println!("  {}. {}", n + 1, head(v, 160));
    }
    if out.diagnostics.is_empty() {
        println!("  无诊断（规则本身没发现问题）");
    } else {
        for d in &out.diagnostics {
            println!("  ⚠ [{}] {} — {}", d.kind, d.rule, d.message);
        }
    }
    Ok(())
}
