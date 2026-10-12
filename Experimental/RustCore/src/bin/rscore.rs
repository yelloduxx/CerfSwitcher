//! rscore: trace / bench / load modes over simulator phrase JSONL.
//! Never prints user text: trace output goes to a file; stdout carries counts.

use ruswitcher_core::model::LanguageModel;
use ruswitcher_core::phrase::{PhraseFixture, run_phrase};
use ruswitcher_core::text::is_mark_scalar;
use serde_json::json;
use std::io::{BufRead, BufWriter, Write};
use std::time::Instant;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn load_phrases(path: &str) -> Vec<PhraseFixture> {
    let file = std::fs::File::open(path).expect("open phrases");
    std::io::BufReader::new(file)
        .lines()
        .enumerate()
        .filter_map(|(n, line)| {
            let line = line.expect("read phrases");
            if line.trim().is_empty() {
                return None;
            }
            Some(serde_json::from_str(&line).unwrap_or_else(|_| panic!("invalid phrase JSONL at line {}", n + 1)))
        })
        .collect()
}

fn percentile(sorted: &[u64], p: f64) -> u64 {
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).cloned().unwrap_or_default();
    let model_path = arg(&args, "--model")
        .unwrap_or_else(|| "../../Sources/RuSwitcherCore/Resources/language-model-v1.bin".into());
    let started = Instant::now();
    let model = LanguageModel::load(std::path::Path::new(&model_path)).expect("model");
    let load_ms = started.elapsed().as_secs_f64() * 1e3;
    if mode == "load" {
        println!(
            "{}",
            json!({"engine": "rust", "loadMilliseconds": load_ms, "modelVersion": model.metadata.model_version})
        );
        return;
    }
    let phrases = load_phrases(&arg(&args, "--phrases").expect("--phrases"));
    match mode.as_str() {
        "trace" => {
            let out = arg(&args, "--out").expect("--out");
            let mut w = BufWriter::new(std::fs::File::create(&out).expect("create out"));
            let mut tokens = 0usize;
            let mut marked = 0usize;
            for p in &phrases {
                let steps = run_phrase(p, &model, || 0);
                marked += p.steps.iter().filter(|s| s.typed.chars().any(is_mark_scalar)).count();
                tokens += steps.len();
                let rows: Vec<_> = steps
                    .iter()
                    .map(|s| {
                        let e = &s.evaluation;
                        json!({
                            "verdict": e.verdict.to_string(),
                            "resolved": s.resolved,
                            "reason": e.reason.to_string(),
                            "literalScore": e.literal_score,
                            "convertedScore": e.converted_score,
                            "threshold": e.threshold,
                            "evidence": e.evidence.iter().map(|v| v.to_string()).collect::<Vec<_>>(),
                            "prefix": e.candidate.prefix,
                            "suffix": e.candidate.suffix,
                            "kind": format!("{:?}", e.candidate.kind),
                        })
                    })
                    .collect();
                serde_json::to_writer(&mut w, &json!({"id": p.id, "steps": rows})).unwrap();
                w.write_all(b"\n").unwrap();
            }
            println!(
                "{}",
                json!({"engine": "rust", "phrases": phrases.len(), "tokens": tokens,
                       "tokensWithCombiningMarks": marked, "loadMilliseconds": load_ms})
            );
        }
        "bench" => {
            let clock = Instant::now();
            let now = || clock.elapsed().as_nanos() as u64;
            // Warm pass, untimed; then one timed pass on the same input.
            for p in &phrases {
                run_phrase(p, &model, || 0);
            }
            let wall = Instant::now();
            let mut samples: Vec<u64> = Vec::new();
            for p in &phrases {
                samples.extend(run_phrase(p, &model, now).iter().map(|s| s.nanos));
            }
            let wall_ms = wall.elapsed().as_secs_f64() * 1e3;
            samples.sort_unstable();
            let mean = samples.iter().sum::<u64>() as f64 / samples.len() as f64;
            println!(
                "{}",
                json!({
                    "engine": "rust",
                    "measured": "KeyMapping.convert + LayoutDecoder.evaluate per token, single thread, second pass",
                    "samples": samples.len(),
                    "p50Micros": percentile(&samples, 50.0) as f64 / 1e3,
                    "p90Micros": percentile(&samples, 90.0) as f64 / 1e3,
                    "p99Micros": percentile(&samples, 99.0) as f64 / 1e3,
                    "p999Micros": percentile(&samples, 99.9) as f64 / 1e3,
                    "maxMicros": *samples.last().unwrap() as f64 / 1e3,
                    "meanMicros": mean / 1e3,
                    "timedPassMilliseconds": wall_ms,
                    "loadMilliseconds": load_ms,
                })
            );
        }
        _ => {
            eprintln!("usage: rscore load|trace|bench --model M [--phrases P] [--out O]");
            std::process::exit(64);
        }
    }
}
