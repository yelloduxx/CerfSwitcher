//! Unicode predicates and key mapping that mirror Foundation/Swift semantics.
//!
//! Swift `Character` is a grapheme cluster; this port works on scalars. For
//! NFC Latin/Cyrillic text the two coincide (the CLI counts tokens with
//! combining marks so the assumption is observed, not assumed).

use std::collections::HashMap;
use std::sync::OnceLock;
use unicode_general_category::{GeneralCategory as G, get_general_category};
use unicode_normalization::UnicodeNormalization;

/// `CharacterSet.punctuationCharacters`: general category P*.
pub fn is_punctuation_scalar(c: char) -> bool {
    matches!(
        get_general_category(c),
        G::ConnectorPunctuation
            | G::DashPunctuation
            | G::OpenPunctuation
            | G::ClosePunctuation
            | G::InitialPunctuation
            | G::FinalPunctuation
            | G::OtherPunctuation
    )
}

/// `CharacterSet.letters`: general categories L* and M*.
pub fn is_letter_scalar(c: char) -> bool {
    matches!(
        get_general_category(c),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
            | G::NonspacingMark
            | G::SpacingMark
            | G::EnclosingMark
    )
}

pub fn is_mark_scalar(c: char) -> bool {
    matches!(
        get_general_category(c),
        G::NonspacingMark | G::SpacingMark | G::EnclosingMark
    )
}

/// `CharacterSet.decimalDigits`: general category Nd.
pub fn is_decimal_digit(c: char) -> bool {
    get_general_category(c) == G::DecimalNumber
}

/// `Character.isLetter`: Alphabetic property of the first scalar.
#[inline]
pub fn is_letter(c: char) -> bool {
    c.is_alphabetic()
}

/// `Character.isNumber`: the scalar has a numeric type.
#[inline]
pub fn is_number(c: char) -> bool {
    c.is_numeric()
}

#[inline]
pub fn is_uppercase(c: char) -> bool {
    c.is_uppercase()
}

/// Swift `String.lowercased()` maps scalar by scalar (no final-sigma context).
pub fn lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

pub fn uppercased(s: &str) -> String {
    s.chars().flat_map(char::to_uppercase).collect()
}

/// `FrequentWordLexicon.normalize`: lowercase, then NFC.
pub fn normalize(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    lowercased(s).nfc().collect()
}

#[inline]
pub fn is_cyrillic(c: char) -> bool {
    ('\u{0400}'..='\u{04FF}').contains(&c)
}

#[inline]
pub fn is_ascii_latin(c: char) -> bool {
    c.is_ascii_alphabetic()
}

pub fn canonical_language(language: &str) -> String {
    let prefix: String = lowercased(language).chars().take(2).collect();
    match prefix.as_str() {
        "uk" | "be" | "bg" => "ru".to_string(),
        "de" | "fr" | "es" | "pt" | "pl" => "en".to_string(),
        _ => prefix,
    }
}

const EN_TO_RU: &[(char, char)] = &[
    ('q', 'й'), ('w', 'ц'), ('e', 'у'), ('r', 'к'), ('t', 'е'), ('y', 'н'),
    ('u', 'г'), ('i', 'ш'), ('o', 'щ'), ('p', 'з'), ('[', 'х'), (']', 'ъ'),
    ('a', 'ф'), ('s', 'ы'), ('d', 'в'), ('f', 'а'), ('g', 'п'), ('h', 'р'),
    ('j', 'о'), ('k', 'л'), ('l', 'д'), (';', 'ж'), ('\'', 'э'),
    ('z', 'я'), ('x', 'ч'), ('c', 'с'), ('v', 'м'), ('b', 'и'), ('n', 'т'),
    ('m', 'ь'), (',', 'б'), ('.', 'ю'), ('/', '.'),
    ('\\', 'ё'), ('`', 'ё'),
    ('Q', 'Й'), ('W', 'Ц'), ('E', 'У'), ('R', 'К'), ('T', 'Е'), ('Y', 'Н'),
    ('U', 'Г'), ('I', 'Ш'), ('O', 'Щ'), ('P', 'З'), ('{', 'Х'), ('}', 'Ъ'),
    ('A', 'Ф'), ('S', 'Ы'), ('D', 'В'), ('F', 'А'), ('G', 'П'), ('H', 'Р'),
    ('J', 'О'), ('K', 'Л'), ('L', 'Д'), (':', 'Ж'), ('"', 'Э'),
    ('Z', 'Я'), ('X', 'Ч'), ('C', 'С'), ('V', 'М'), ('B', 'И'), ('N', 'Т'),
    ('M', 'Ь'), ('<', 'Б'), ('>', 'Ю'), ('?', ','), ('&', '?'),
    ('|', 'Ё'), ('~', 'Ё'),
];

struct Maps {
    en_to_ru: HashMap<char, char>,
    ru_to_en: HashMap<char, char>,
}

fn maps() -> &'static Maps {
    static MAPS: OnceLock<Maps> = OnceLock::new();
    MAPS.get_or_init(|| {
        let en_to_ru: HashMap<char, char> = EN_TO_RU.iter().copied().collect();
        // Swift builds ruToEn by iterating a Dictionary (unordered); the only
        // duplicate Russian values are ё/Ё, which are then overridden explicitly.
        let mut ru_to_en: HashMap<char, char> = EN_TO_RU.iter().map(|&(en, ru)| (ru, en)).collect();
        ru_to_en.insert('ё', '`');
        ru_to_en.insert('Ё', '~');
        Maps { en_to_ru, ru_to_en }
    })
}

/// `KeyMapping.convert`: the direction follows whether any Cyrillic scalar exists.
pub fn convert_layout(text: &str) -> String {
    let m = maps();
    let map = if text.chars().any(is_cyrillic) { &m.ru_to_en } else { &m.en_to_ru };
    text.chars().map(|c| *map.get(&c).unwrap_or(&c)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_punctuation_matches_foundation() {
        // Foundation punctuationCharacters over printable ASCII (P* only).
        let expected = "!\"#%&'()*,-./:;?@[\\]_{}";
        let actual: String = (0x20u8..0x7f).map(char::from).filter(|&c| is_punctuation_scalar(c)).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn convert_roundtrip() {
        assert_eq!(convert_layout("ghbdtn"), "привет");
        assert_eq!(convert_layout("руддщ"), "hello");
        assert_eq!(convert_layout("гыуб"), "use,");
    }
}
