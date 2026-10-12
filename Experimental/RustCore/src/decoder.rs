//! Port of LayoutDecoder.evaluate and its helpers (EnglishSourceClassifier,
//! CompoundWordAnalyzer, ScriptMismatchHeuristics, LanguageBelief,
//! FrequentWordLexicon). Constants and operation order follow the Swift source.

use crate::model::{EnglishTier, LanguageModel, Thresholds};
use crate::text::*;
use crate::tokenizer::{self, Candidate, CandidateKind, TokenKind};
use std::collections::HashSet;
use std::fmt;
use std::sync::OnceLock;

// MARK: FrequentWordLexicon

const RU_FREQUENT: &[&str] = &[
    "и", "в", "не", "на", "я", "с", "что", "а", "по", "это", "он", "как", "к", "у",
    "же", "за", "то", "но", "мы", "вы", "из", "от", "так", "для", "о", "бы", "или", "если",
    "да", "нет", "есть", "был", "она", "они", "его", "ее", "ещё", "уже", "только", "можно",
    "нужно", "будет", "когда", "где", "кто", "почему", "чтобы", "тоже", "очень", "все", "всё",
    "мой", "моя", "ваш", "наш", "ты", "мне", "вам", "нас", "их", "до", "при", "без", "над",
    "под", "про", "между", "после", "перед", "раз", "два", "три", "день", "время", "работа",
    "текст", "слово", "язык", "план", "программа", "система", "проект", "файл", "код", "данные",
    "привет", "приветствую", "спасибо", "пожалуйста", "хорошо", "сейчас", "потом", "сегодня",
];
const EN_FREQUENT: &[&str] = &[
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on",
    "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we",
    "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
    "so", "up", "out", "if", "about", "who", "get", "which", "go", "me", "when", "make", "can",
    "like", "time", "no", "just", "him", "know", "take", "people", "into", "year", "your", "good",
    "some", "could", "them", "see", "other", "than", "then", "now", "look", "only", "come", "its",
    "over", "think", "also", "back", "after", "use", "two", "how", "our", "work", "first", "well",
    "way", "even", "new", "want", "because", "these", "give", "day", "most", "us", "hello", "plan",
];

fn frequent_sets() -> &'static [HashSet<&'static str>; 2] {
    static SETS: OnceLock<[HashSet<&'static str>; 2]> = OnceLock::new();
    SETS.get_or_init(|| [RU_FREQUENT.iter().copied().collect(), EN_FREQUENT.iter().copied().collect()])
}

pub fn frequent_contains(word: &str, language: &str) -> bool {
    // Swift uses the raw two-letter prefix here, not LanguageCode.canonical.
    let lang: String = lowercased(language).chars().take(2).collect();
    let n = normalize(word);
    match lang.as_str() {
        "ru" => frequent_sets()[0].contains(n.as_str()),
        "en" => frequent_sets()[1].contains(n.as_str()),
        _ => false,
    }
}

// MARK: LanguageBelief

#[derive(Debug, Clone, Copy, Default)]
pub struct LanguageBelief {
    russian_log_odds: f64,
}

impl LanguageBelief {
    pub fn observe(&mut self, language: Option<&str>, weight: f64) {
        self.russian_log_odds *= 0.72;
        let Some(language) = language else { return };
        match canonical_language(language).as_str() {
            "ru" => self.russian_log_odds += 1.35 * weight.max(0.0),
            "en" => self.russian_log_odds -= 1.35 * weight.max(0.0),
            _ => {}
        }
        self.russian_log_odds = self.russian_log_odds.max(-8.0).min(8.0);
    }

    pub fn probability(&self, language: &str) -> f64 {
        let ru = 1.0 / (1.0 + (-self.russian_log_odds).exp());
        match canonical_language(language).as_str() {
            "ru" => ru,
            "en" => 1.0 - ru,
            _ => 0.5,
        }
    }

    pub fn score(&self, language: &str) -> f64 {
        (self.probability(language) - 0.5) * 5.0
    }
}

// MARK: EnglishSourceClassifier

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnglishSourceConfidence {
    Frequent,
    Dictionary,
    PlausibleOov,
    Unlikely,
}

pub fn classify_english_source(word: &str, model: &LanguageModel) -> EnglishSourceConfidence {
    let n = normalize(&tokenizer::lexical_core(word));
    if n.chars().count() < 2 {
        return EnglishSourceConfidence::Unlikely;
    }
    if model.word_log_probability(&n, "en").is_some() {
        return EnglishSourceConfidence::Frequent;
    }
    if model.is_extended_english_word(&n) {
        return EnglishSourceConfidence::Dictionary;
    }
    if model.character_log_probability(&n, "en") >= model.thresholds.english_source_character_floor {
        return EnglishSourceConfidence::PlausibleOov;
    }
    EnglishSourceConfidence::Unlikely
}

// MARK: CompoundWordAnalyzer

#[derive(Clone)]
pub struct Compound {
    pub segments: Vec<String>,
    pub score: f64,
}

pub fn analyze_compound(word: &str, language: &str, model: &LanguageModel) -> Option<Compound> {
    const MAX_SEGMENTS: usize = 4;
    let chars: Vec<char> = normalize(word).chars().collect();
    let n = chars.len();
    if !(6..=40).contains(&n) {
        return None;
    }
    let mut best: Vec<Option<Compound>> = vec![None; n + 1];
    best[0] = Some(Compound { segments: vec![], score: 0.0 });
    let store = |best: &mut Vec<Option<Compound>>, at: usize, c: Compound| {
        if c.score > best[at].as_ref().map_or(f64::NEG_INFINITY, |s| s.score) {
            best[at] = Some(c);
        }
    };
    for start in 0..n {
        let Some(state) = best[start].clone() else { continue };
        if state.segments.len() >= MAX_SEGMENTS || start + 3 > n {
            continue;
        }
        for end in (start + 3)..=n {
            let segment: String = chars[start..end].iter().collect();
            let seg_len = (end - start) as f64;
            let is_productive_prefix = start == 0 && model.productive_parts.contains(&segment) && end < n;
            let is_productive_suffix = end == n
                && start >= 4
                && model.productive_suffixes.contains(&segment)
                && model.contains(&chars[..start].iter().collect::<String>(), language);
            let mut segments = state.segments.clone();
            match model.word_log_probability(&segment, language) {
                None => {
                    if !is_productive_prefix && !is_productive_suffix {
                        continue;
                    }
                    let bonus = if is_productive_suffix { 2.4 } else { 1.2 };
                    let score = state.score + bonus + seg_len * 0.08;
                    segments.push(segment);
                    store(&mut best, end, Compound { segments, score });
                }
                Some(word_score) => {
                    let normalized_frequency = (7.5 + word_score * 0.55).max(0.2);
                    let split_penalty = if state.segments.is_empty() { 0.0 } else { 1.8 };
                    let score = state.score + normalized_frequency + seg_len * 0.08 - split_penalty;
                    segments.push(segment);
                    store(&mut best, end, Compound { segments, score });
                }
            }
        }
    }
    best[n].take().filter(|r| r.segments.len() >= 2)
}

// MARK: ScriptMismatchHeuristics

pub fn has_strong_mismatch(typed: &str, converted: &str, target_language: &str) -> bool {
    let target = canonical_language(target_language);
    let typed_letters: Vec<char> = typed.chars().filter(|&c| is_letter_scalar(c)).collect();
    let converted_letters: Vec<char> = converted.chars().filter(|&c| is_letter_scalar(c)).collect();
    if typed_letters.len() < 4 || converted_letters.len() < 4 {
        return false;
    }
    let ratio = |s: &[char], latin: bool| -> f64 {
        let m = s.iter().filter(|&&c| if latin { is_ascii_latin(c) } else { is_cyrillic(c) }).count();
        m as f64 / s.len() as f64
    };
    match target.as_str() {
        "ru" | "uk" | "be" | "bg" => ratio(&typed_letters, true) >= 0.8 && ratio(&converted_letters, false) >= 0.8,
        "en" | "de" | "fr" | "es" | "pt" | "pl" => ratio(&typed_letters, false) >= 0.8 && ratio(&converted_letters, true) >= 0.8,
        _ => false,
    }
}

// MARK: LayoutDecoder

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    SwitchToConverted,
    Keep,
    Undecided,
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Verdict::SwitchToConverted => "switchToConverted",
            Verdict::Keep => "keep",
            Verdict::Undecided => "undecided",
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    FrequentShort,
    FrequentWord,
    Dictionary,
    CharacterModel,
    PhraseContext,
    Compound,
    ConfirmedByUser,
    BlockedNever,
    BlockedCodeLike,
    BlockedContext,
    BlockedLearned,
    BlockedEditing,
    KeepCurrentWord,
    AlwaysConvert,
    Undecided,
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Reason::FrequentShort => "frequentShort",
            Reason::FrequentWord => "frequentWord",
            Reason::Dictionary => "dictionary",
            Reason::CharacterModel => "characterModel",
            Reason::PhraseContext => "phraseContext",
            Reason::Compound => "compound",
            Reason::ConfirmedByUser => "confirmedByUser",
            Reason::BlockedNever => "blockedNever",
            Reason::BlockedCodeLike => "blockedCodeLike",
            Reason::BlockedContext => "blockedContext",
            Reason::BlockedLearned => "blockedLearned",
            Reason::BlockedEditing => "blockedEditing",
            Reason::KeepCurrentWord => "keepCurrentWord",
            Reason::AlwaysConvert => "alwaysConvert",
            Reason::Undecided => "undecided",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Evidence {
    Frequent,
    CharacterModel,
    PhraseContext,
    Compound(Vec<usize>),
    ConfirmedByUser,
    BlockedCode,
    BlockedNever,
    BlockedEditing,
    BlockedContext,
    PunctuationPath,
    Abstained,
    EnglishSourceFrequent,
    EnglishSourceDictionary,
    EnglishSourcePlausible,
    EnglishSourceUnlikely,
    EnglishTargetDictionary,
    RussianSourceDictionary,
    RussianTargetDictionary,
}

impl fmt::Display for Evidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Evidence::Compound(lengths) => {
                let parts: Vec<String> = lengths.iter().map(|l| l.to_string()).collect();
                return write!(f, "compound(segmentLengths: [{}])", parts.join(", "));
            }
            Evidence::Frequent => "frequent",
            Evidence::CharacterModel => "characterModel",
            Evidence::PhraseContext => "phraseContext",
            Evidence::ConfirmedByUser => "confirmedByUser",
            Evidence::BlockedCode => "blockedCode",
            Evidence::BlockedNever => "blockedNever",
            Evidence::BlockedEditing => "blockedEditing",
            Evidence::BlockedContext => "blockedContext",
            Evidence::PunctuationPath => "punctuationPath",
            Evidence::Abstained => "abstained",
            Evidence::EnglishSourceFrequent => "englishSourceFrequent",
            Evidence::EnglishSourceDictionary => "englishSourceDictionary",
            Evidence::EnglishSourcePlausible => "englishSourcePlausible",
            Evidence::EnglishSourceUnlikely => "englishSourceUnlikely",
            Evidence::EnglishTargetDictionary => "englishTargetDictionary",
            Evidence::RussianSourceDictionary => "russianSourceDictionary",
            Evidence::RussianTargetDictionary => "russianTargetDictionary",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Clone)]
pub struct Evaluation {
    pub verdict: Verdict,
    pub reason: Reason,
    pub candidate: Candidate,
    pub literal_score: f64,
    pub converted_score: f64,
    pub threshold: f64,
    pub evidence: Vec<Evidence>,
}

impl Evaluation {
    pub fn confidence_margin(&self) -> f64 {
        self.converted_score - self.literal_score
    }
}

/// Inputs the app supplies but the corpus simulator leaves empty.
#[derive(Default)]
pub struct Policy {
    pub never_convert: HashSet<String>,
    pub always_convert: HashSet<String>,
}

pub struct Request<'a> {
    pub typed: &'a str,
    pub converted: &'a str,
    pub current_language: &'a str,
    pub target_language: &'a str,
    pub caps_lock: bool,
    pub context_words: &'a [String],
    pub belief: LanguageBelief,
    pub policy: &'a Policy,
    pub adaptive_bias: &'a dyn Fn(&str, &str) -> f64,
    pub is_confirmed: &'a dyn Fn(&str, &str) -> bool,
}

const UNLISTED_TARGET_CHARACTER_FLOOR: f64 = -13.0;
const RARE_SOURCE_FREQUENCY_MARGIN: f64 = 2.5;

fn follower_continuation_floor() -> f64 {
    0.01f64.ln()
}

fn fixed(candidate: Candidate, verdict: Verdict, reason: Reason, evidence: Vec<Evidence>) -> Evaluation {
    let switched = verdict == Verdict::SwitchToConverted;
    Evaluation {
        verdict,
        reason,
        candidate,
        literal_score: if switched { 0.0 } else { 100.0 },
        converted_score: if switched { 100.0 } else { 0.0 },
        threshold: 0.0,
        evidence,
    }
}

fn candidate_word(c: &Candidate) -> String {
    normalize(&tokenizer::lexical_core(&c.converted_word))
}

fn char_count(s: &str) -> usize {
    s.chars().count()
}

fn has_suffix(s: &str, suffix: &str) -> bool {
    s.ends_with(suffix)
}

fn last_chars(s: &str, n: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    chars[chars.len().saturating_sub(n)..].iter().collect()
}

fn preserved_decoration_count(c: &Candidate) -> usize {
    char_count(&c.prefix) + char_count(&c.suffix)
}

fn preserves_typed_suffix(c: &Candidate) -> bool {
    !c.suffix.is_empty() && has_suffix(&c.typed_raw, &c.suffix)
}

fn preserves_layout_letter_prefix(c: &Candidate) -> bool {
    !c.prefix.is_empty() && convert_layout(&c.prefix).chars().any(is_letter)
}

fn preserves_layout_letter_suffix(c: &Candidate) -> bool {
    preserves_typed_suffix(c)
        && !c.suffix.chars().any(|ch| "]}".contains(ch))
        && last_chars(&c.converted_raw, char_count(&c.suffix)).chars().any(is_letter)
}

fn has_lexical_target_evidence(e: &Evaluation) -> bool {
    e.evidence.iter().any(|ev| {
        matches!(
            ev,
            Evidence::Frequent
                | Evidence::EnglishTargetDictionary
                | Evidence::RussianTargetDictionary
                | Evidence::ConfirmedByUser
                | Evidence::Compound(_)
        )
    })
}

fn is_punctuation(c: char) -> bool {
    is_punctuation_scalar(c)
}

fn is_decoration(c: char) -> bool {
    is_punctuation_scalar(c) || c == '&'
}

fn uses_translated_punctuation_suffix(c: &Candidate) -> bool {
    let n = char_count(&c.suffix);
    if n != 1 || !has_suffix(&c.converted_raw, &c.suffix) || has_suffix(&c.typed_raw, &c.suffix) {
        return false;
    }
    last_chars(&c.typed_raw, n).chars().all(is_decoration) && c.suffix.chars().all(is_decoration)
}

fn trailing_decoration(text: &str) -> String {
    let rev: Vec<char> = text.chars().rev().take_while(|&c| !is_letter(c) && !is_number(c)).collect();
    rev.into_iter().rev().collect()
}

fn punctuation_comparable_core(text: &str) -> String {
    let without_prefix: Vec<char> = text.chars().skip_while(|&c| !is_letter(c) && !is_number(c)).collect();
    let rev: Vec<char> = without_prefix.into_iter().rev().skip_while(|&c| !is_letter(c) && !is_number(c)).collect();
    normalize(&rev.into_iter().rev().collect::<String>())
}

fn punctuation_sequence_score(suffix: &str) -> i32 {
    match suffix {
        "..." => 10,
        "?!" | "!?" => 9,
        "!!" | "??" => 8,
        "." | "," | "?" | "!" | ";" | ":" => 6,
        _ => {
            if suffix.contains('&') || suffix.contains('/') || suffix.contains('\\') {
                return -3;
            }
            if suffix.contains(",!") || suffix.contains(",?") {
                return -2;
            }
            if suffix.chars().all(|c| ".!?".contains(c)) { 4 } else { 0 }
        }
    }
}

fn english_target_dictionary_bonus(tier: EnglishTier, t: &Thresholds) -> f64 {
    match tier {
        EnglishTier::Common => t.english_target_common_bonus,
        EnglishTier::Standard => t.english_target_standard_bonus,
        EnglishTier::Rare => t.english_target_rare_bonus,
    }
}

fn english_target_context_recovery(tier: EnglishTier, t: &Thresholds) -> f64 {
    match tier {
        EnglishTier::Common => t.english_target_common_context_recovery,
        EnglishTier::Standard => t.english_target_standard_context_recovery,
        EnglishTier::Rare => t.english_target_rare_context_recovery,
    }
}

fn lexical_score(word: &str, language: &str, known: Option<f64>, model: &LanguageModel) -> f64 {
    let character = 13.0 + model.character_log_probability(word, language);
    match known {
        None => character,
        Some(k) => character + 7.5 + k * 0.55,
    }
}

pub fn evaluate(req: &Request, model: &LanguageModel) -> Evaluation {
    let typed = req.typed;
    let generated = tokenizer::candidates(typed, req.converted);
    if !typed.chars().any(is_letter) {
        let candidate = generated.into_iter().next().unwrap();
        return fixed(candidate, Verdict::Keep, Reason::BlockedCodeLike, vec![Evidence::BlockedCode]);
    }
    let target = canonical_language(req.target_language);
    let is_target_word = |c: &Candidate| -> bool {
        let w = candidate_word(c);
        model.word_log_probability(&w, &target).is_some()
            || (target == "en" && model.is_extended_english_word(&w))
            || (target == "ru" && model.is_extended_russian_word(&w))
    };
    let frequent: Vec<&Candidate> = generated
        .iter()
        .filter(|c| {
            let w = candidate_word(c);
            model.word_log_probability(&w, &target).is_some() || frequent_contains(&w, &target)
        })
        .collect();
    let spelling: Vec<&Candidate> = generated
        .iter()
        .filter(|c| {
            let w = candidate_word(c);
            (target == "en" && model.is_extended_english_word(&w)) || (target == "ru" && model.is_extended_russian_word(&w))
        })
        .collect();
    let confirmed: Vec<&Candidate> = generated.iter().filter(|c| (req.is_confirmed)(typed, &c.replacement())).collect();
    let candidates: Vec<&Candidate> = if !confirmed.is_empty() {
        confirmed
    } else if !frequent.is_empty() {
        let keeps_letter_suffix = frequent.iter().any(|c| preserves_layout_letter_suffix(c));
        let mut list = frequent.clone();
        if keeps_letter_suffix {
            for c in &spelling {
                if !preserves_layout_letter_suffix(c)
                    && !frequent.iter().any(|f| f == c)
                    && model.attested_word_log_probability(&candidate_word(c), &target).is_some()
                {
                    list.push(c);
                }
            }
        }
        list
    } else if !spelling.is_empty() {
        spelling
    } else {
        generated.iter().collect()
    };

    let evaluations: Vec<Evaluation> = candidates
        .into_iter()
        .map(|c| {
            let replacement = c.replacement();
            evaluate_candidate(
                c.clone(),
                req,
                (req.adaptive_bias)(typed, &replacement),
                (req.is_confirmed)(typed, &replacement),
                model,
            )
        })
        .collect();

    // Swift `max(by:)` keeps the first maximum: replace only when strictly less.
    let less = |lhs: &Evaluation, rhs: &Evaluation| -> bool {
        let ls = lhs.verdict == Verdict::SwitchToConverted;
        let rs = rhs.verdict == Verdict::SwitchToConverted;
        if ls && !rs {
            return false;
        }
        if !ls && rs {
            return true;
        }
        let lp = preserves_layout_letter_prefix(&lhs.candidate);
        let rp = preserves_layout_letter_prefix(&rhs.candidate);
        if lp != rp {
            let lc = has_lexical_target_evidence(lhs);
            let rc = has_lexical_target_evidence(rhs);
            if lp && !rp && (!lc || rc) {
                return true;
            }
            if rp && !lp && (!rc || lc) {
                return false;
            }
        }
        let lsuf = preserves_layout_letter_suffix(&lhs.candidate);
        let rsuf = preserves_layout_letter_suffix(&rhs.candidate);
        if lsuf != rsuf {
            if lsuf && is_target_word(&rhs.candidate) {
                return true;
            }
            if rsuf && is_target_word(&lhs.candidate) {
                return false;
            }
        }
        let lph = lhs.evidence.contains(&Evidence::PhraseContext);
        let rph = rhs.evidence.contains(&Evidence::PhraseContext);
        if lph != rph {
            return !lph && rph;
        }
        let lrep = lhs.candidate.replacement();
        let rrep = rhs.candidate.replacement();
        let lcore = punctuation_comparable_core(&lrep);
        let rcore = punctuation_comparable_core(&rrep);
        let ldec = trailing_decoration(&lrep);
        let rdec = trailing_decoration(&rrep);
        if lcore == rcore && char_count(&ldec).max(char_count(&rdec)) > 1 {
            let lscore = punctuation_sequence_score(&ldec);
            let rscore = punctuation_sequence_score(&rdec);
            if lscore != rscore {
                return lscore < rscore;
            }
        }
        let lt = uses_translated_punctuation_suffix(&lhs.candidate);
        let rt = uses_translated_punctuation_suffix(&rhs.candidate);
        if lt != rt {
            return !lt && rt;
        }
        let lpt = preserves_typed_suffix(&lhs.candidate);
        let rpt = preserves_typed_suffix(&rhs.candidate);
        if lpt != rpt {
            return !lpt && rpt;
        }
        if lpt {
            let a = preserved_decoration_count(&lhs.candidate);
            let b = preserved_decoration_count(&rhs.candidate);
            if a != b {
                return a < b;
            }
        }
        if (lhs.converted_score - rhs.converted_score).abs() > 0.000_001 {
            return lhs.converted_score < rhs.converted_score;
        }
        preserved_decoration_count(&lhs.candidate) < preserved_decoration_count(&rhs.candidate)
    };
    let mut iter = evaluations.into_iter();
    let Some(mut best) = iter.next() else {
        let candidate = Candidate {
            typed_raw: typed.to_string(),
            converted_raw: req.converted.to_string(),
            prefix: String::new(),
            converted_word: req.converted.to_string(),
            suffix: String::new(),
            kind: CandidateKind::DirectWord,
        };
        return fixed(candidate, Verdict::Undecided, Reason::Undecided, vec![]);
    };
    for e in iter {
        if less(&best, &e) {
            best = e;
        }
    }
    best
}

fn evaluate_candidate(
    candidate: Candidate,
    req: &Request,
    adaptive_bias: f64,
    confirmed: bool,
    model: &LanguageModel,
) -> Evaluation {
    let t = &model.thresholds;
    let typed = normalize(&candidate.typed_raw);
    let literal = tokenizer::lexical_core(&typed);
    let converted = normalize(&tokenizer::lexical_core(&candidate.converted_word));
    let shape = tokenizer::shape(&candidate.typed_raw);
    let replacement = candidate.replacement();
    let converted_shape = tokenizer::shape(&replacement);
    let current = canonical_language(req.current_language);
    let target = canonical_language(req.target_language);
    let literal_len = char_count(&literal);
    let converted_len = char_count(&converted);
    let target_known_for_shape = model.word_log_probability(&converted, &target);
    let target_english_tier = if target == "en" { model.english_spelling_tier(&converted) } else { None };
    let target_extended_english = target_english_tier.is_some();
    let target_extended_russian = target == "ru" && model.is_extended_russian_word(&converted);
    let confirmed_acronym_pair = confirmed
        && tokenizer::is_all_uppercase_word(&candidate.typed_raw)
        && tokenizer::is_all_uppercase_word(&replacement);

    if req.policy.never_convert.contains(&typed) || req.policy.never_convert.contains(&converted) {
        return fixed(candidate, Verdict::Keep, Reason::BlockedNever, vec![Evidence::BlockedNever]);
    }
    if literal.is_empty() {
        return fixed(candidate, Verdict::Keep, Reason::BlockedCodeLike, vec![Evidence::BlockedCode]);
    }
    let source_shape_protected = shape.kind.blocks_automatic_conversion()
        && !(converted_shape.kind == TokenKind::Lexical
            && (target_known_for_shape.is_some() || target_extended_english || target_extended_russian));
    let capital_is_other_layout_word = current == "ru"
        && literal_len == 1
        && !candidate.typed_raw.contains('.')
        && model.word_log_probability(&literal, &current).is_none()
        && !model.is_extended_russian_word(&literal)
        && target_known_for_shape.is_some();
    if (tokenizer::is_single_uppercase_letter(&candidate.typed_raw) && !capital_is_other_layout_word)
        || (source_shape_protected && !confirmed_acronym_pair)
        || (converted_shape.kind.blocks_automatic_conversion()
            && candidate.kind != CandidateKind::TrailingPunctuation
            && candidate.kind != CandidateKind::WrappingPunctuation
            && !confirmed_acronym_pair)
    {
        return fixed(candidate, Verdict::Keep, Reason::BlockedCodeLike, vec![Evidence::BlockedCode]);
    }

    if req.policy.always_convert.contains(&converted) {
        return fixed(candidate, Verdict::SwitchToConverted, Reason::AlwaysConvert, vec![Evidence::Frequent]);
    }
    if literal_len == 1 && frequent_contains(&literal, &current) {
        return fixed(candidate, Verdict::Keep, Reason::KeepCurrentWord, vec![Evidence::Frequent]);
    }
    if confirmed {
        return fixed(candidate, Verdict::SwitchToConverted, Reason::ConfirmedByUser, vec![Evidence::ConfirmedByUser]);
    }
    if adaptive_bias <= -10.0 {
        return fixed(candidate, Verdict::Keep, Reason::BlockedLearned, vec![Evidence::BlockedContext]);
    }

    let source_known = model.word_log_probability(&literal, &current);
    let source_extended_russian = current == "ru" && model.is_extended_russian_word(&literal);
    let target_known = target_known_for_shape;
    let ctx = req.context_words;
    let recent: Vec<String> = ctx[ctx.len().saturating_sub(4)..]
        .iter()
        .filter_map(|w| tokenizer::language_hint(w))
        .map(canonical_language)
        .collect();
    let recent_english = recent.iter().filter(|l| *l == "en").count();
    let recent_russian = recent.iter().filter(|l| *l == "ru").count();
    let last_two = &recent[recent.len().saturating_sub(2)..];
    let last_two_english = last_two.len() == 2 && last_two.iter().all(|l| l == "en");
    let frequent_english_target_beats_weak_source = target == "en"
        && target_known.is_some()
        && frequent_contains(&converted, &target)
        && (source_known.is_none() || (literal_len <= 2 && last_two_english))
        && (!source_extended_russian || (recent_english > 0 && recent_english >= recent_russian));
    let direct_consumes_leading_punctuation = target == "ru"
        && target_extended_russian
        && candidate.typed_raw.chars().nth(char_count(&candidate.prefix)).is_some_and(is_punctuation);
    let english_source_confidence = if current == "en" && target == "ru" {
        Some(if direct_consumes_leading_punctuation {
            EnglishSourceConfidence::Unlikely
        } else {
            classify_english_source(&literal, model)
        })
    } else {
        None
    };
    let strong_script_mismatch = has_strong_mismatch(&candidate.typed_raw, &converted, req.target_language);
    let converted_char_lp = model.character_log_probability(&converted, &target);
    let character_advantage = converted_char_lp - model.character_log_probability(&literal, &current);
    let extended_english_target_base = current == "ru"
        && target == "en"
        && target_english_tier.is_some()
        && converted_len >= 4
        && source_known.is_none()
        && !source_extended_russian;
    let strong_extended_english_target =
        extended_english_target_base && character_advantage >= t.english_target_character_advantage;
    let ranked_extended_english_target =
        extended_english_target_base && (model.metadata.format_version >= 2 || strong_extended_english_target);
    let strong_extended_russian_target = current == "en"
        && target_extended_russian
        && source_known.is_none()
        && english_source_confidence == Some(EnglishSourceConfidence::Unlikely);
    let source_spelling_only = source_known.is_none()
        && (source_extended_russian || (current == "en" && model.english_spelling_tier(&literal) == Some(EnglishTier::Rare)));
    let frequency_gap = target_known.map(|k| k - model.unlisted_word_log_probability_bound(&current));
    let frequent_target_outranks_rare_source = literal_len >= 2
        && source_spelling_only
        && frequency_gap.unwrap_or(f64::NEG_INFINITY) >= RARE_SOURCE_FREQUENCY_MARGIN;
    let previous_followed_by_target = recent.last().is_some_and(|l| *l == target)
        && ctx
            .last()
            .and_then(|p| model.follower_log_probability(&tokenizer::lexical_core(p), &converted, &target))
            .is_some_and(|v| v >= follower_continuation_floor());
    let context_continues_in_target = literal_len >= 2
        && target_known.is_some()
        && ((last_two.len() == 2 && last_two.iter().all(|l| *l == target)) || previous_followed_by_target);

    if literal_len >= 2
        && (source_known.is_some() || source_extended_russian)
        && (target_known.is_some() || target_extended_english || target_extended_russian)
        && !frequent_english_target_beats_weak_source
        && !frequent_target_outranks_rare_source
        && !context_continues_in_target
    {
        return fixed(candidate, Verdict::Keep, Reason::BlockedContext, vec![Evidence::BlockedContext]);
    }
    if literal_len >= 2 && english_source_confidence == Some(EnglishSourceConfidence::Frequent) && !context_continues_in_target {
        return fixed(candidate, Verdict::Keep, Reason::KeepCurrentWord, vec![Evidence::EnglishSourceFrequent]);
    }
    if literal_len >= 2 && english_source_confidence == Some(EnglishSourceConfidence::Dictionary) && !frequent_target_outranks_rare_source {
        return fixed(candidate, Verdict::Keep, Reason::KeepCurrentWord, vec![Evidence::EnglishSourceDictionary]);
    }
    if literal_len >= 2
        && source_extended_russian
        && !frequent_english_target_beats_weak_source
        && !frequent_target_outranks_rare_source
        && !context_continues_in_target
    {
        return fixed(candidate, Verdict::Keep, Reason::KeepCurrentWord, vec![Evidence::RussianSourceDictionary]);
    }
    if direct_consumes_leading_punctuation && strong_extended_russian_target {
        return fixed(
            candidate,
            Verdict::SwitchToConverted,
            Reason::FrequentWord,
            vec![Evidence::RussianTargetDictionary, Evidence::PunctuationPath],
        );
    }
    let compound = if source_known.is_none() { analyze_compound(&converted, &target, model) } else { None };
    let mut evidence = Vec::new();

    let mut literal_score = lexical_score(&literal, &current, source_known, model);
    let mut converted_score = lexical_score(&converted, &target, target_known, model);
    let current_belief = req.belief.score(&current);
    let target_belief = req.belief.score(&target);
    literal_score += current_belief;
    converted_score += target_belief + adaptive_bias;

    if current == "en"
        && target == "ru"
        && source_known.is_none()
        && target_known.is_none()
        && strong_script_mismatch
        && converted_len >= 6
        && character_advantage >= t.russian_oov_english_long
    {
        converted_score += (current_belief - target_belief).max(0.0);
    }
    if let (Some(tier), true) = (target_english_tier, ranked_extended_english_target) {
        let recovery = if strong_extended_english_target {
            t.english_target_strong_character_context_recovery
        } else {
            english_target_context_recovery(tier, t)
        };
        converted_score += (current_belief - target_belief).max(0.0) * recovery;
    }
    if frequent_english_target_beats_weak_source {
        converted_score += (current_belief - target_belief).max(0.0);
    }
    if strong_extended_russian_target {
        converted_score += (current_belief - target_belief).max(0.0);
    }
    if context_continues_in_target {
        converted_score += (current_belief - target_belief).max(0.0);
    }
    if let (true, Some(gap)) = (frequent_target_outranks_rare_source, frequency_gap) {
        converted_score += (current_belief - target_belief).max(0.0) + gap - RARE_SOURCE_FREQUENCY_MARGIN;
    }

    if source_known.is_some() {
        literal_score += 2.2;
    }
    match english_source_confidence {
        Some(EnglishSourceConfidence::PlausibleOov) => {
            literal_score += t.english_source_plausible_bonus;
            evidence.push(Evidence::EnglishSourcePlausible);
        }
        Some(EnglishSourceConfidence::Unlikely) => evidence.push(Evidence::EnglishSourceUnlikely),
        _ => {}
    }
    if target_known.is_some() {
        converted_score += 3.0;
        evidence.push(Evidence::Frequent);
    } else if let (Some(tier), true) = (target_english_tier, ranked_extended_english_target) {
        if strong_extended_english_target {
            converted_score += t.english_target_strong_character_bonus;
        } else {
            converted_score += english_target_dictionary_bonus(tier, t);
            converted_score += character_advantage.max(-3.0).min(3.0) * t.english_target_character_weight;
        }
        evidence.push(Evidence::EnglishTargetDictionary);
    } else if strong_extended_russian_target {
        converted_score += 3.0;
        evidence.push(Evidence::RussianTargetDictionary);
    } else {
        evidence.push(Evidence::CharacterModel);
    }

    if let Some(score) = model.phrase_log_probability(ctx, &literal, &current) {
        literal_score += (3.2 + score * 0.45).max(0.0);
    }
    if let Some(score) = model.phrase_log_probability(ctx, &converted, &target) {
        converted_score += (3.8 + score * 0.45).max(0.0);
        evidence.push(Evidence::PhraseContext);
    }
    if let Some(c) = &compound {
        converted_score += t.compound_bonus + (c.score * 0.18).min(4.0);
        evidence.push(Evidence::Compound(c.segments.iter().map(|s| char_count(s)).collect()));
    }

    if tokenizer::language_hint(&literal).is_some_and(|h| canonical_language(h) == current) {
        literal_score += 1.2;
    }
    if tokenizer::language_hint(&converted).is_some_and(|h| canonical_language(h) == target) {
        converted_score += 1.2;
    }
    if candidate.kind == CandidateKind::TrailingPunctuation || candidate.kind == CandidateKind::WrappingPunctuation {
        let core_has_lexical = target_known.is_some()
            || ranked_extended_english_target
            || strong_extended_russian_target
            || frequent_contains(&converted, &target);
        if core_has_lexical {
            converted_score += 0.35;
        } else if preserves_layout_letter_prefix(&candidate) {
            converted_score -= 1.25;
        } else {
            converted_score += 0.35;
        }
        if !candidate.suffix.is_empty()
            && preserves_typed_suffix(&candidate)
            && candidate.suffix.chars().all(|c| ".!?".contains(c))
        {
            converted_score += (char_count(&candidate.suffix) as f64 * 0.5).min(1.5);
        }
    }
    if req.caps_lock {
        literal_score += 1.0;
    }

    let target_probability = req.belief.probability(&target);
    let current_probability = req.belief.probability(&current);
    let mut threshold = if converted_len <= 2 {
        t.short
    } else if target_probability >= 0.68 {
        t.russian_context
    } else if current_probability >= 0.68 {
        t.english_context
    } else {
        t.neutral
    };
    if current == "en" && target == "ru" && source_known.is_none() && target_known.is_none() && strong_script_mismatch {
        if current_probability < 0.62 {
            threshold = threshold.min(t.russian_oov_neutral);
        } else if converted_len >= 6 {
            threshold = threshold.min(t.russian_oov_english_long);
        }
    }

    if converted_len == 1 && target == "ru" {
        let has_recent_russian = recent.iter().any(|l| l == "ru");
        let last_is_english = recent.last().is_some_and(|l| l == "en");
        if last_is_english && !has_recent_russian && target_probability < 0.55 {
            return fixed(candidate, Verdict::Keep, Reason::BlockedContext, vec![Evidence::BlockedContext]);
        }
    }
    if current == "ru" && target == "en" && source_known.is_none() && target_known.is_none() && !ranked_extended_english_target {
        let advantage = converted_char_lp - model.character_log_probability(&literal, &current);
        if converted_len < 5 || advantage < t.english_target_character_advantage || current_probability >= 0.62 {
            return fixed(candidate, Verdict::Keep, Reason::BlockedContext, vec![Evidence::BlockedContext]);
        }
    }

    let margin = converted_score - literal_score;
    let has_lexical_evidence = target_known.is_some()
        || ranked_extended_english_target
        || strong_extended_russian_target
        || compound.is_some()
        || (strong_script_mismatch
            && (converted_char_lp >= UNLISTED_TARGET_CHARACTER_FLOOR
                || model.attested_word_log_probability(&converted, &target).is_some()));
    let verdict = if margin >= threshold && has_lexical_evidence {
        Verdict::SwitchToConverted
    } else if source_known.is_some() || source_extended_russian {
        Verdict::Keep
    } else {
        Verdict::Undecided
    };
    if verdict == Verdict::Undecided {
        evidence.push(Evidence::Abstained);
    }
    let reason = if verdict == Verdict::SwitchToConverted {
        if compound.is_some() && target_known.is_none() {
            Reason::Compound
        } else if evidence.contains(&Evidence::PhraseContext) {
            Reason::PhraseContext
        } else if ranked_extended_english_target {
            Reason::Dictionary
        } else if target_known.is_some() || strong_extended_russian_target {
            if converted_len <= 3 { Reason::FrequentShort } else { Reason::FrequentWord }
        } else {
            Reason::CharacterModel
        }
    } else if verdict == Verdict::Keep {
        Reason::KeepCurrentWord
    } else {
        Reason::Undecided
    };
    Evaluation { verdict, reason, candidate, literal_score, converted_score, threshold, evidence }
}
