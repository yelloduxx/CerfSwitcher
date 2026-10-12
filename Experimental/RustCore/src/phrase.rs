//! Port of the RuSwitcherSimulator phrase loop: context is the previously
//! resolved tokens, belief is updated after every non-empty token.

use crate::decoder::{self, Evaluation, LanguageBelief, Policy, Request, Verdict};
use crate::model::LanguageModel;
use crate::text::{convert_layout, lowercased, uppercased};
use crate::tokenizer::lexical_core;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhraseStep {
    pub typed: String,
    pub manual_language: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhraseFixture {
    pub id: String,
    pub initial_language: String,
    pub steps: Vec<PhraseStep>,
}

pub struct StepOutcome {
    pub evaluation: Evaluation,
    pub resolved: String,
    pub nanos: u64,
}

/// Runs one phrase. `timer` wraps exactly `KeyMapping.convert` + `LayoutDecoder.evaluate`.
pub fn run_phrase(fixture: &PhraseFixture, model: &LanguageModel, mut timer: impl FnMut() -> u64) -> Vec<StepOutcome> {
    let policy = Policy::default();
    let bias = |_: &str, _: &str| 0.0;
    let confirmed = |_: &str, _: &str| false;
    let mut current = fixture.initial_language.clone();
    let mut context: Vec<String> = Vec::new();
    let mut belief = LanguageBelief::default();
    let mut out = Vec::with_capacity(fixture.steps.len());
    for step in &fixture.steps {
        if let Some(manual) = &step.manual_language {
            current = manual.clone();
        }
        let target = if current == "ru" { "en" } else { "ru" };
        let typed = step.typed.as_str();
        let start = timer();
        let converted = convert_layout(typed);
        let evaluation = decoder::evaluate(
            &Request {
                typed,
                converted: &converted,
                current_language: &current,
                target_language: target,
                caps_lock: typed == uppercased(typed) && typed != lowercased(typed),
                context_words: &context,
                belief,
                policy: &policy,
                adaptive_bias: &bias,
                is_confirmed: &confirmed,
            },
            model,
        );
        let nanos = timer() - start;
        let switched = evaluation.verdict == Verdict::SwitchToConverted;
        let resolved = if switched { evaluation.candidate.replacement() } else { typed.to_string() };
        let resolved_language = if switched { target.to_string() } else { current.clone() };
        let token = lexical_core(&resolved);
        if !token.is_empty() {
            context.push(token);
            if context.len() > 5 {
                let excess = context.len() - 5;
                context.drain(..excess);
            }
            belief.observe(Some(&resolved_language), if switched { 1.4 } else { 1.0 });
        }
        if switched {
            current = target.to_string();
        }
        out.push(StepOutcome { evaluation, resolved, nanos });
    }
    out
}
