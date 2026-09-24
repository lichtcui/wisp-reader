//! Generate `bundled-sources.json` — the v1-compatible subset of a Legado
//! source list — by running the same `gate` used at import time.
//!
//! Usage (from `rust/legado-engine`):
//!   cargo run --release --example bundled_gen -- <input.json> <output.json>

use std::process::ExitCode;

use legado_engine::gate;
use legado_engine::types::BookSource;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: cargo run --example bundled_gen -- <input.json> <output.json>");
        return ExitCode::from(2);
    }
    let input = &args[1];
    let output = &args[2];

    let raw = match std::fs::read_to_string(input) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("read {input} failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    let sources: Vec<BookSource> = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("parse {input} failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    let result = gate::run(sources);

    let mut counts: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for e in &result.excluded {
        *counts.entry(e.reason.clone()).or_insert(0) += 1;
    }

    let json = match serde_json::to_string_pretty(&result.eligible) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("serialize failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(parent) = std::path::Path::new(output).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(output, json) {
        eprintln!("write {output} failed: {e}");
        return ExitCode::FAILURE;
    }

    println!(
        "total={} eligible={} excluded={}",
        result.total,
        result.eligible.len(),
        result.excluded.len()
    );
    for (reason, n) in counts {
        println!("  excluded {reason}: {n}");
    }
    println!("wrote {output}");
    ExitCode::SUCCESS
}