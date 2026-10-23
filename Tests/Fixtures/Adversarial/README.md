# Handwritten adversarial phrases

Messages written by hand to catch the switcher on mistakes. They do not come
from any corpus, dictionary or earlier test set.

- `handwritten-v1.txt` is a broad sweep: words that are valid in both layouts,
  letters on punctuation keys, slang, transliteration, code inside Russian
  text, short words, abbreviations, names, hyphens, capitals, typos, emoticons
  and numbers.
- `handwritten-v2.txt` digs into the weak spots of v1: more two-layout words,
  chat abbreviations in both languages, words ending in `ж б ю х`, and letter
  names.
- `handwritten-v3.txt` holds long, natural mixed messages about marketplaces,
  code, prices and names.

Run them all with:

```bash
bash scripts/run_adversarial_phrases.sh
```

Each line becomes up to four rows, built by `scripts/make_text_mixed_tsv.py`:
the whole message typed in the EN layout, the whole message in the RU layout,
each word in its own layout, and a slip into the wrong layout mid-message. The
runner writes every wrong decision to `.build/adversarial-findings.tsv`.

## Build 161 findings

The snapshot is in `findings-build161.tsv`. There are 4 wrong replacements, 17
false positives and 243 misses. In 45 of the misses an earlier word of the same
message was already converted (`earlier_switch` = `yes`). In the app the layout
switches after that conversion, so those keys would arrive in the right layout,
and the miss may not happen while typing.

The long natural messages (v3) produced no wrong replacement and no false
positive. The errors cluster in short messages, first words, slang and letter
names.

### Harmful classes, fix first

1. **A short Russian word typed correctly at the start of a message becomes
   English.** Examples: `ща` -> `of`, `ку` -> `re`, `ша` -> `if`, `шт` -> `in`,
   and `туче` -> `next` inside Russian prose. Build 157, before the conversational
   rules, already converted all of them except `шт` -> `in`, which build 158's
   "far more common reading" rule added. Chat Russian uses these words, and the
   frequency gap does not make them typos.
2. **A last letter on a punctuation key is cut off.** Examples: `rhby;` ->
   `крин;` instead of `кринж`, `dfq,` -> `вай,` instead of `вайб`, and `gfcb,` ->
   `паси,` instead of `пасиб`. When the shorter word exists, the final `;` or
   `,` stays punctuation.
3. **Letter names convert.** Examples: `витамин C` -> `С`, `буква B` -> `И`,
   `витамин D` -> `В`, and `c и g это буквы` -> `с`.
4. **Chat abbreviations typed correctly convert.** Examples: `afk` -> `фал` and
   `gl hf` -> `gl ра`.
5. **A meme word typed correctly converts.** `йцукен` -> `qwerty`.

### Miss classes

- Russian interjections and slang in the EN layout: `jr` (`ок`), `kz` (`ля`),
  `'v` (`эм`), `,h` (`бр`), `ae` (`фу`), `fq` (`ай`), `g;` (`пж`), `rtr` (`кек`),
  `rvr` (`кмк`), `v,` (`мб`), `vlf` (`мда`), `kc` (`лс`).
- Repeated and hyphenated interjections: `lf-lf` (`да-да`), `ye-ye` (`ну-ну`),
  `f-f-f` (`а-а-а`), `'-'-'` (`э-э-э`), `yt-f` (`не-а`).
- Words that are valid in both layouts: `ye`/`ну`, `tot`/`еще`, `of`/`ща`,
  `her`/`рук`, `here`/`руку`, `herb`/`руки`, `bob`/`ищи`, `next`/`туче`.
- Words that start with a punctuation key: `[kt,` (`хлеб`), `'[?` (`эх,`),
  `` `; `` (`ёж`), `<` (`Б`).
- Slashed and dotted abbreviations: `,/e` (`б/у`), `;/l` (`ж/д`), `n/t/` (`т.е.`).
- Acronyms and chat abbreviations typed in the RU layout: `СУЩ` (`CEO`),
  `СЕК` (`CTR`), `ЦИ` (`WB`), `МЗТ` (`VPN`), `ЗВА` (`PDF`), `пп` (`gg`), `цз` (`wp`),
  `тмь` (`nvm`), `лл` (`kk`), `уя` (`ez`).
- Russian acronyms in the EN layout: `HA` (`РФ`), `GR` (`ПК`), `NP` (`ТЗ`),
  `VUE` (`МГУ`), `DEP` (`ВУЗ`), `:R{` (`ЖКХ`).
- Brands, camelCase and code in the RU layout: `Щящт` (`Ozon`), `Вщеф` (`Dota`),
  `ФшкЗщвы` (`AirPods`), `ьфсЩЫ` (`macOS`), `сщтыщдуюдщп` (`console.log`),
  `гыук_шв` (`user_id`), `лгиусед` (`kubectl`), `пшергиюсщь` (`github.com`).
- Hyphenated names in the EN layout: `Cfyrn-Gtnth,ehu` (`Санкт-Петербург`),
  `Ym.-Qjhr` (`Нью-Йорк`), `Kjc-Fyl;tktc` (`Лос-Анджелес`).
- Single letters: `b` (`и`), `d` (`в`), `z` (`я`), and `с`/`c` in both directions.
