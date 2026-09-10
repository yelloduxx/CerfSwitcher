# FLORES-200 Clean EN/RU Evaluation Text

This is an evaluation-only derivative of the original FLORES-200 release from
the NLLB Team / Meta, not RuSwitcher training data. Dataset text and this derived
representation are licensed under **CC BY-SA 4.0**, separately from application
code. The full license is in `LICENSE_CC-BY-SA.txt`.

Source: [FLORES-200 documentation](https://github.com/facebookresearch/flores/blob/a6c830c6e1051fb4ac1a44b32358f00463f332bd/flores200/README.md).
Citation: NLLB Team, *No Language Left Behind: Scaling Human-Centered Machine
Translation*, 2022. Each row retains its original source article URL, topic and
both professionally translated sentences. Original text strings are unchanged;
JSON packaging, document groups and evaluation splits are our additions.

`clean.jsonl.gz` contains 2,009 paired sentences (4,018 EN/RU phrases) from 562
articles. Documents and exact normalized translation duplicates stay in one
split. The fixed hash allocation is approximately 60/20/20:

| Split | Pairs | Document Groups | EN Whitespace Tokens | RU Whitespace Tokens |
| --- | ---: | ---: | ---: | ---: |
| development | 1222 | 339 | 26146 | 23599 |
| calibration | 400 | 113 | 8484 | 7662 |
| test | 387 | 110 | 8225 | 7555 |

Do not tune decoder rules on `test` or reroll this split after evaluating it.
Calibration and test have not been passed through the decoder at this checkpoint.
The fixed source archive, six input members, license and generated data hashes
are recorded in `manifest.json`. No private user text is included.

This is news, explanatory text and travel writing, not a complete chat/work/code
benchmark. It is not a lexical-family OOV split or a physical keyboard fixture.
The test set is too small for the planned 50,000-token-per-language confidence
gate. Source punctuation must not be silently normalized to make physical input
possible; unsupported input belongs in a labelled text-only evaluation.

## Reproduction

Download the original archive from the `sourceURL` in `manifest.json` and the
license from the pinned upstream repository revision. Then run from the repo:

```bash
python3 scripts/prepare_independent_corpus.py \
  --archive .build/flores200_dataset.tar.gz \
  --license Tests/Fixtures/Independent/flores200-clean-v1/LICENSE_CC-BY-SA.txt \
  --output .build/flores200-reproduction
```

The importer checks both input hashes, uses a fixed seed, performs no network
requests and refuses to overwrite an existing output directory. Compare the
generated data and manifest with the frozen files here. Error profiles and
decoder evaluations are separate future steps, not claimed by preparation.
