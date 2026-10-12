//! RSLM v1/v2 container loader (port of LanguageModelStore + RussianSpellingBloom).

use crate::text::{canonical_language, normalize};
use base64::Engine;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

pub type Table = HashMap<String, f64>;

#[derive(Debug)]
pub enum ModelError {
    InvalidHeader,
    UnsupportedVersion(u16),
    InvalidDirectory,
    ChecksumMismatch,
    MissingSection(u16),
    InvalidSection(u16),
    Io(std::io::Error),
}

#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub format_version: i64,
    pub model_version: String,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Thresholds {
    pub short: f64,
    pub russian_context: f64,
    pub neutral: f64,
    pub english_context: f64,
    #[serde(rename = "russianOOVNeutral")]
    pub russian_oov_neutral: f64,
    #[serde(rename = "russianOOVEnglishLong")]
    pub russian_oov_english_long: f64,
    pub english_source_character_floor: f64,
    pub english_source_plausible_bonus: f64,
    pub english_target_character_advantage: f64,
    #[serde(default = "d3_1")]
    pub english_target_common_bonus: f64,
    #[serde(default = "d2_5")]
    pub english_target_standard_bonus: f64,
    #[serde(default = "d1_8")]
    pub english_target_rare_bonus: f64,
    #[serde(default = "d0_35")]
    pub english_target_character_weight: f64,
    #[serde(default = "d3_0")]
    pub english_target_strong_character_bonus: f64,
    #[serde(default = "d1_0")]
    pub english_target_common_context_recovery: f64,
    #[serde(default = "d0_7")]
    pub english_target_standard_context_recovery: f64,
    #[serde(default = "d0_35")]
    pub english_target_rare_context_recovery: f64,
    #[serde(default = "d1_0")]
    pub english_target_strong_character_context_recovery: f64,
    pub compound_bonus: f64,
    pub confirmed_bonus: f64,
}

fn d3_1() -> f64 { 3.1 }
fn d2_5() -> f64 { 2.5 }
fn d1_8() -> f64 { 1.8 }
fn d0_35() -> f64 { 0.35 }
fn d3_0() -> f64 { 3.0 }
fn d1_0() -> f64 { 1.0 }
fn d0_7() -> f64 { 0.7 }

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum EnglishTier {
    Rare = 1,
    Standard = 2,
    Common = 3,
}

impl EnglishTier {
    fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::Rare),
            2 => Some(Self::Standard),
            3 => Some(Self::Common),
            _ => None,
        }
    }
}

struct Bloom {
    hash_count: u64,
    bit_count: u64,
    bits: Vec<u8>,
}

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

fn fnv1a64<I: IntoIterator<Item = u8>>(bytes: I) -> u64 {
    bytes.into_iter().fold(FNV_OFFSET, |h, b| (h ^ b as u64).wrapping_mul(FNV_PRIME))
}

impl Bloom {
    fn new(data: &[u8]) -> Result<Self, ModelError> {
        let bad = ModelError::InvalidSection(13);
        if data.len() < 20 || &data[0..4] != b"RSBF" || u16le(data, 4) != 1 {
            return Err(bad);
        }
        let hash_count = u16le(data, 6) as u64;
        let bit_count = u32le(data, 8) as u64;
        if hash_count == 0 || bit_count == 0 || bit_count.count_ones() != 1 || data.len() as u64 != 20 + bit_count / 8 {
            return Err(bad);
        }
        Ok(Self { hash_count, bit_count, bits: data[20..].to_vec() })
    }

    fn contains(&self, word: &str) -> bool {
        let bytes = word.as_bytes();
        if bytes.is_empty() {
            return false;
        }
        let first = fnv1a64(bytes.iter().copied());
        let second = fnv1a64(bytes.iter().rev().copied()) | 1;
        let mask = self.bit_count - 1;
        (0..self.hash_count).all(|i| {
            let bit = first.wrapping_add(i.wrapping_mul(second)) & mask;
            self.bits[(bit >> 3) as usize] & (1u8 << (bit & 7)) != 0
        })
    }
}

/// Language index: 0 = ru, 1 = en. Other languages have no tables.
fn lang_index(language: &str) -> Option<usize> {
    match canonical_language(language).as_str() {
        "ru" => Some(0),
        "en" => Some(1),
        _ => None,
    }
}

pub struct LanguageModel {
    pub metadata: Metadata,
    pub thresholds: Thresholds,
    pub productive_parts: HashSet<String>,
    pub productive_suffixes: HashSet<String>,
    english_tiers: HashMap<String, EnglishTier>,
    russian_bloom: Bloom,
    words: [Table; 2],
    rarest: [f64; 2],
    characters: [Table; 2],
    bigrams: [Table; 2],
    trigrams: [Table; 2],
    followers: [Table; 2],
    attested: [Table; 2],
}

fn u16le(d: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([d[o], d[o + 1]])
}
fn u32le(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(d[o..o + 4].try_into().unwrap())
}
fn u64le(d: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(d[o..o + 8].try_into().unwrap())
}

#[derive(Deserialize)]
struct RankedEnglish {
    words: Vec<String>,
    tiers: String,
}

impl LanguageModel {
    pub fn load(path: &std::path::Path) -> Result<Self, ModelError> {
        let data = std::fs::read(path).map_err(ModelError::Io)?;
        Self::from_bytes(&data)
    }

    pub fn from_bytes(data: &[u8]) -> Result<Self, ModelError> {
        if data.len() < 20 || &data[0..4] != b"RSLM" {
            return Err(ModelError::InvalidHeader);
        }
        let version = u16le(data, 4);
        if version != 1 && version != 2 {
            return Err(ModelError::UnsupportedVersion(version));
        }
        let count = u16le(data, 6) as usize;
        let payload_len = u32le(data, 8) as usize;
        let checksum = u64le(data, 12);
        let dir_end = 20 + count * 12;
        if count == 0 || dir_end > data.len() || data.len() - dir_end != payload_len {
            return Err(ModelError::InvalidDirectory);
        }
        if fnv1a64(data[dir_end..].iter().copied()) != checksum {
            return Err(ModelError::ChecksumMismatch);
        }
        let mut sections: HashMap<u16, &[u8]> = HashMap::new();
        for i in 0..count {
            let base = 20 + i * 12;
            let kind = u16le(data, base);
            if !(1..=17).contains(&kind) {
                continue;
            }
            let offset = u32le(data, base + 4) as usize;
            let length = u32le(data, base + 8) as usize;
            if offset + length > payload_len {
                return Err(ModelError::InvalidDirectory);
            }
            let start = dir_end + offset;
            sections.insert(kind, &data[start..start + length]);
        }
        fn decode<'a, T: Deserialize<'a>>(s: &HashMap<u16, &'a [u8]>, id: u16) -> Result<T, ModelError> {
            let bytes = s.get(&id).ok_or(ModelError::MissingSection(id))?;
            serde_json::from_slice(bytes).map_err(|_| ModelError::InvalidSection(id))
        }
        fn optional(s: &HashMap<u16, &[u8]>, id: u16) -> Result<Table, ModelError> {
            if s.contains_key(&id) { decode(s, id) } else { Ok(Table::new()) }
        }

        let metadata: Metadata = decode(&sections, 1)?;
        let thresholds: Thresholds = decode(&sections, 11)?;
        let productive: Vec<String> = decode(&sections, 10)?;
        let productive_parts = productive.iter().filter(|v| !v.starts_with('-')).cloned().collect();
        let productive_suffixes = productive.iter().filter_map(|v| v.strip_prefix('-').map(str::to_string)).collect();
        let words: [Table; 2] = [decode(&sections, 2)?, decode(&sections, 3)?];
        let rarest = [min_value(&words[0]), min_value(&words[1])];
        let characters = [decode(&sections, 4)?, decode(&sections, 5)?];
        let bigrams = [decode(&sections, 6)?, decode(&sections, 7)?];
        let trigrams = [decode(&sections, 8)?, decode(&sections, 9)?];

        let english_tiers = if version >= 2 {
            let ranked: RankedEnglish = decode(&sections, 12)?;
            let tiers = base64::engine::general_purpose::STANDARD
                .decode(ranked.tiers.as_bytes())
                .map_err(|_| ModelError::InvalidSection(12))?;
            if tiers.len() != ranked.words.len() || ranked.words.windows(2).any(|w| w[0] >= w[1]) {
                return Err(ModelError::InvalidSection(12));
            }
            let mut map = HashMap::with_capacity(tiers.len());
            for (word, tier) in ranked.words.into_iter().zip(tiers) {
                map.insert(word, EnglishTier::from_u8(tier).ok_or(ModelError::InvalidSection(12))?);
            }
            map
        } else {
            let list: Vec<String> = decode(&sections, 12)?;
            list.into_iter().map(|w| (w, EnglishTier::Standard)).collect()
        };
        let followers = [optional(&sections, 14)?, optional(&sections, 15)?];
        let attested = [optional(&sections, 16)?, optional(&sections, 17)?];
        let russian_bloom = Bloom::new(sections.get(&13).ok_or(ModelError::MissingSection(13))?)?;

        Ok(Self {
            metadata,
            thresholds,
            productive_parts,
            productive_suffixes,
            english_tiers,
            russian_bloom,
            words,
            rarest,
            characters,
            bigrams,
            trigrams,
            followers,
            attested,
        })
    }

    pub fn english_spelling_tier(&self, word: &str) -> Option<EnglishTier> {
        self.english_tiers.get(&normalize(word)).copied()
    }

    pub fn is_extended_english_word(&self, word: &str) -> bool {
        self.english_spelling_tier(word).is_some()
    }

    pub fn is_extended_russian_word(&self, word: &str) -> bool {
        self.russian_bloom.contains(&normalize(word))
    }

    pub fn unlisted_word_log_probability_bound(&self, language: &str) -> f64 {
        lang_index(language).map_or(0.0, |i| self.rarest[i])
    }

    pub fn word_log_probability(&self, word: &str, language: &str) -> Option<f64> {
        let i = lang_index(language)?;
        self.words[i].get(&normalize(word)).copied()
    }

    pub fn contains(&self, word: &str, language: &str) -> bool {
        self.word_log_probability(word, language).is_some()
    }

    pub fn character_log_probability(&self, word: &str, language: &str) -> f64 {
        let normalized = normalize(word);
        let Some(i) = lang_index(language).filter(|_| !normalized.is_empty()) else {
            return -16.0;
        };
        let model = &self.characters[i];
        let mut padded = Vec::with_capacity(normalized.len() + 2);
        padded.push('^');
        padded.extend(normalized.chars());
        padded.push('$');
        let mut total = 0.0;
        let mut count = 0usize;
        let mut key = String::with_capacity(24);
        for size in 2..=5 {
            if padded.len() < size {
                continue;
            }
            for index in 0..=(padded.len() - size) {
                key.clear();
                key.extend(&padded[index..index + size]);
                total += model.get(key.as_str()).copied().unwrap_or(-16.0);
                count += 1;
            }
        }
        if count == 0 { -16.0 } else { total / count as f64 }
    }

    pub fn attested_word_log_probability(&self, word: &str, language: &str) -> Option<f64> {
        let i = lang_index(language)?;
        let n = normalize(word);
        self.words[i].get(&n).or_else(|| self.attested[i].get(&n)).copied()
    }

    pub fn follower_log_probability(&self, previous: &str, word: &str, language: &str) -> Option<f64> {
        let i = lang_index(language)?;
        let key = format!("{}\u{1f}{}", normalize(previous), normalize(word));
        self.followers[i].get(&key).copied()
    }

    pub fn phrase_log_probability(&self, context: &[String], candidate: &str, language: &str) -> Option<f64> {
        let i = lang_index(language);
        let cand = normalize(candidate);
        let ctx: Vec<String> = context.iter().map(|w| normalize(w)).filter(|w| !w.is_empty()).collect();
        if ctx.len() >= 2 {
            let key = format!("{}\u{1f}{}\u{1f}{}", ctx[ctx.len() - 2], ctx[ctx.len() - 1], cand);
            if let Some(score) = i.and_then(|i| self.trigrams[i].get(&key)) {
                return Some(*score);
            }
        }
        let previous = ctx.last()?;
        let key = format!("{}\u{1f}{}", previous, cand);
        i.and_then(|i| self.bigrams[i].get(&key)).copied()
    }
}

fn min_value(table: &Table) -> f64 {
    // Swift: `values.min() ?? 0`.
    table.values().copied().fold(None, |acc: Option<f64>, v| Some(acc.map_or(v, |a| a.min(v)))).unwrap_or(0.0)
}
