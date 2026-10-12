//! Port of SmartTokenizer, AutoConvertCandidate and AutoConvertCandidateGenerator.

use crate::text::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    Lexical,
    Url,
    Email,
    Numeric,
    Identifier,
    MixedScript,
    Empty,
}

impl TokenKind {
    pub fn blocks_automatic_conversion(self) -> bool {
        self != TokenKind::Lexical
    }
}

pub struct TokenShape {
    pub prefix: String,
    pub lexical_core: String,
    pub suffix: String,
    pub kind: TokenKind,
}

const LEADING: &str = "([{<\"'«„“‘";
const TRAILING: &str = ".,!?;:)]}>\"'»”’…_-—–";

pub fn shape(raw: &str) -> TokenShape {
    if raw.is_empty() {
        return TokenShape { prefix: String::new(), lexical_core: String::new(), suffix: String::new(), kind: TokenKind::Empty };
    }
    let chars: Vec<char> = raw.chars().collect();
    let mut start = 0;
    let mut end = chars.len();
    while start < end && LEADING.contains(chars[start]) {
        start += 1;
    }
    while end > start && TRAILING.contains(chars[end - 1]) {
        end -= 1;
    }
    let core: String = chars[start..end].iter().collect();
    let kind = kind_of(raw, &core);
    TokenShape {
        prefix: chars[..start].iter().collect(),
        lexical_core: core,
        suffix: chars[end..].iter().collect(),
        kind,
    }
}

pub fn lexical_core(raw: &str) -> String {
    shape(raw).lexical_core
}

pub fn kind_of(raw: &str, token: &str) -> TokenKind {
    if token.is_empty() {
        return TokenKind::Empty;
    }
    let lower = lowercased(raw);
    if lower.contains("://") || lower.starts_with("www.") {
        return TokenKind::Url;
    }
    if raw.contains('@') && raw.contains('.') {
        return TokenKind::Email;
    }
    if token.chars().all(|c| is_decimal_digit(c) || ".,-+/:%".contains(c)) {
        return TokenKind::Numeric;
    }
    if has_mixed_scripts(token) {
        return TokenKind::MixedScript;
    }
    if looks_like_identifier(token) {
        return TokenKind::Identifier;
    }
    TokenKind::Lexical
}

pub fn language_hint(text: &str) -> Option<&'static str> {
    let mut latin = 0;
    let mut cyrillic = 0;
    for c in text.chars() {
        if is_ascii_latin(c) {
            latin += 1;
        } else if is_cyrillic(c) {
            cyrillic += 1;
        }
    }
    if latin > cyrillic {
        Some("en")
    } else if cyrillic > latin {
        Some("ru")
    } else {
        None
    }
}

pub fn is_single_uppercase_letter(text: &str) -> bool {
    let mut letters = text.chars().filter(|&c| is_letter(c));
    match (letters.next(), letters.next()) {
        (Some(l), None) => is_uppercase(l),
        _ => false,
    }
}

pub fn is_all_uppercase_word(text: &str) -> bool {
    let s = shape(text);
    let word = &s.lexical_core;
    if word.chars().count() < 2 || !word.chars().all(is_letter) || *word != uppercased(word) || *word == lowercased(word) {
        return false;
    }
    !s.prefix.chars().chain(s.suffix.chars()).any(|c| "_-/\\@".contains(c))
}

fn looks_like_identifier(raw: &str) -> bool {
    if raw.contains('/') || raw.contains('\\') || raw.contains('_') {
        return true;
    }
    if raw.chars().any(is_decimal_digit) {
        return true;
    }
    if raw.contains('.') {
        let pieces: Vec<&str> = raw.split('.').collect();
        if pieces.len() > 1 && pieces.iter().all(|p| !p.is_empty()) {
            return true;
        }
    }
    let letters: String = raw.chars().filter(|&c| is_letter(c)).collect();
    if letters.chars().count() > 1 && letters == uppercased(&letters) {
        return true;
    }
    raw.chars().skip(1).any(is_uppercase)
}

fn has_mixed_scripts(text: &str) -> bool {
    text.chars().any(is_ascii_latin) && text.chars().any(is_cyrillic)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateKind {
    DirectWord,
    TrailingPunctuation,
    LayoutLetterTail,
    WrappingPunctuation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub typed_raw: String,
    pub converted_raw: String,
    pub prefix: String,
    pub converted_word: String,
    pub suffix: String,
    pub kind: CandidateKind,
}

impl Candidate {
    pub fn replacement(&self) -> String {
        let mut s = String::with_capacity(self.prefix.len() + self.converted_word.len() + self.suffix.len());
        s.push_str(&self.prefix);
        s.push_str(&self.converted_word);
        s.push_str(&self.suffix);
        s
    }
}

pub fn is_trailing_punctuation(c: char) -> bool {
    is_punctuation_scalar(c) || c == '&'
}

fn is_opening_bracket(c: char) -> bool {
    c == '[' || c == '{'
}

fn push_unique(result: &mut Vec<Candidate>, candidate: Candidate) {
    if !result.contains(&candidate) {
        result.push(candidate);
    }
}

pub fn candidates(typed: &str, converted: &str) -> Vec<Candidate> {
    let typed_chars: Vec<char> = typed.chars().collect();
    let converted_chars: Vec<char> = converted.chars().collect();
    let direct_kind = if typed_chars.last().is_some_and(|&c| is_trailing_punctuation(c)) {
        CandidateKind::LayoutLetterTail
    } else {
        CandidateKind::DirectWord
    };
    let mut result = vec![Candidate {
        typed_raw: typed.to_string(),
        converted_raw: converted.to_string(),
        prefix: String::new(),
        converted_word: converted.to_string(),
        suffix: String::new(),
        kind: direct_kind,
    }];

    let sh = shape(typed);
    let prefix_count = if sh.lexical_core.is_empty() { 0 } else { sh.prefix.chars().count() };
    for p in 1..(prefix_count + 1) {
        let prefix: String = typed_chars[..p].iter().collect();
        let remainder = &typed_chars[p..];
        let max_suffix = remainder.len().min(3);
        for suffix_len in 0..=max_suffix {
            let suffix_chars = &remainder[remainder.len() - suffix_len..];
            if suffix_len != 0 && !suffix_chars.iter().all(|&c| is_trailing_punctuation(c)) {
                continue;
            }
            if suffix_chars.iter().any(|&c| is_opening_bracket(c)) {
                continue;
            }
            let core = &remainder[..remainder.len() - suffix_len];
            if core.is_empty() {
                continue;
            }
            let core_s: String = core.iter().collect();
            let suffix_s: String = suffix_chars.iter().collect();
            let word = convert_layout(&core_s);
            push_unique(&mut result, Candidate {
                typed_raw: typed.to_string(),
                converted_raw: converted.to_string(),
                prefix: prefix.clone(),
                converted_word: word.clone(),
                suffix: suffix_s.clone(),
                kind: CandidateKind::WrappingPunctuation,
            });
            let translated = convert_layout(&suffix_s);
            if translated != suffix_s && translated.chars().all(is_trailing_punctuation) {
                push_unique(&mut result, Candidate {
                    typed_raw: typed.to_string(),
                    converted_raw: converted.to_string(),
                    prefix: prefix.clone(),
                    converted_word: word,
                    suffix: translated,
                    kind: CandidateKind::WrappingPunctuation,
                });
            }
        }
    }

    let max_suffix = 3.min(typed_chars.len()).min(converted_chars.len());
    if max_suffix == 0 {
        return result;
    }
    for len in 1..=max_suffix {
        let suffix_chars = &typed_chars[typed_chars.len() - len..];
        if !suffix_chars.iter().all(|&c| is_trailing_punctuation(c)) || suffix_chars.iter().any(|&c| is_opening_bracket(c)) {
            continue;
        }
        let word = &converted_chars[..converted_chars.len() - len];
        if word.is_empty() {
            continue;
        }
        result.push(Candidate {
            typed_raw: typed.to_string(),
            converted_raw: converted.to_string(),
            prefix: String::new(),
            converted_word: word.iter().collect(),
            suffix: suffix_chars.iter().collect(),
            kind: CandidateKind::TrailingPunctuation,
        });
    }
    for len in 1..=max_suffix {
        let suffix = &converted_chars[converted_chars.len() - len..];
        if !suffix.iter().all(|&c| is_trailing_punctuation(c)) {
            continue;
        }
        let word = &converted_chars[..converted_chars.len() - len];
        if word.is_empty() {
            continue;
        }
        push_unique(&mut result, Candidate {
            typed_raw: typed.to_string(),
            converted_raw: converted.to_string(),
            prefix: String::new(),
            converted_word: word.iter().collect(),
            suffix: suffix.iter().collect(),
            kind: CandidateKind::TrailingPunctuation,
        });
    }
    result
}
