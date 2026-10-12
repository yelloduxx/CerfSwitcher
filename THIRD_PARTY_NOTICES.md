# Third-Party Data Notices

## Google Books n-gram frequency lists

`language-model-v1.bin` contains derived aggregate statistics from the
`orgtre/google-books-ngram-frequency` project, revision
`e20471c15a758be3362b16d07870b34df4f7ccc3`.

The source data is licensed under the Creative Commons Attribution 3.0
Unported License. Copyright and attribution belong to the source project and
the Google Books Ngram Corpus contributors.

- Source: https://github.com/orgtre/google-books-ngram-frequency
- License: https://creativecommons.org/licenses/by/3.0/

The application ships only the derived frequency tables required for local
language scoring. It does not contain source texts and never downloads model
data at runtime.

## English Speller Database / SCOWL

The English plausibility lexicon in `language-model-v1.bin` is
derived from the English Speller Database (formerly SCOWL), release
`rel-2026.02.25`, commit `7e99edab8e32f9f9ea2b15f249ca8d4d67237410`.
RuSwitcher Pro reproducibly derives level-35, level-50 and level-60
American/British lists from that same pinned source. The nested levels provide
common, standard and rare spelling-confidence tiers. They protect valid English
source words and contribute ranked evidence for RU-to-EN candidates together
with source-language membership, character probability and phrase context;
no individual word is promoted by application code.

- Source: https://github.com/en-wl/wordlist
- Copyright: 2000-2026 Kevin Atkinson
- Full notice: `SCOWL_COPYRIGHT.txt`

## LibreOffice Russian Hunspell Dictionary

The Russian spelling Bloom filter in `language-model-v1.bin` is derived from
the `ru_RU` Hunspell dictionary and suffix rules in LibreOffice Dictionaries,
commit `38d96a4d54ec3449cf7f28cddae1fce32e2b15a7`. RuSwitcher Pro expands the rules
offline and ships only a compact probabilistic membership filter. This derived
representation is modified and is not a replacement dictionary distribution.

- Source: https://github.com/LibreOffice/dictionaries/tree/master/ru_RU
- Copyright: 1997-2008 Alexander I. Lebedev
- License: permissive three-clause notice in `RUSSIAN_HUNSPELL_COPYRIGHT.txt`

`LayoutRerankerV4.mlmodelc` is a derived model trained from those aggregate
word and phrase frequencies plus synthetic keyboard-layout corruptions. The
checked bootstrap artifact does not contain Wikipedia, Tatoeba, user text, or
other source sentences. Exact inputs, seed and artifact checksum are recorded
in `scripts/v4_training_sources.json`.

## Tatoeba next-word statistics

Since model `2026.10-v3.2-context`, `language-model-v1.bin` contains a small
derived table of next-word probabilities computed from the Tatoeba English and
Russian per-language sentence exports (downloaded 2026-10-12). It covers only
words whose keys also spell a frequent word in the other layout, such as
`here`/`руку`. No sentences are shipped; `scripts/data/tatoeba-followers.json.gz`
records the export SHA-256 hashes and is rebuilt by
`scripts/build_tatoeba_followers.py`.

- Source: https://tatoeba.org
- License: https://creativecommons.org/licenses/by/2.0/fr/
- Attribution: Tatoeba contributors

## FLORES-200 Evaluation Corpus (Tests Only)

`Tests/Fixtures/Independent/flores200-clean-v1` contains an evaluation-only
EN/RU derivative of FLORES-200, NLLB Team / Meta, 2022. Dataset text and the
derived corpus representation are licensed under CC BY-SA 4.0, separately
from application code. The full license, attribution, source article URLs,
transformation description and pinned hashes accompany that corpus.

- Source: https://github.com/facebookresearch/flores/tree/a6c830c6e1051fb4ac1a44b32358f00463f332bd/flores200
- Citation: NLLB Team, *No Language Left Behind: Scaling Human-Centered Machine Translation*, 2022.
- The corpus is not included in the application bundle or used to train its model.
