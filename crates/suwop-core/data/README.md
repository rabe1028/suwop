# EmbeddingGemma 2 tokenizer data

`embeddinggemma2-tokenizer.bin` is a compact binary conversion of the `tokenizer.json`
of `google/embeddinggemma-2` (revision `914f7f89142e33e77833254d9c9b90c3cef7303b`),
licensed under the Apache License 2.0 by Google. This file is a derived work of that
tokenizer (vocabulary and BPE merge list); no other changes were made to its content.

Source `tokenizer.json` SHA-256:
`4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4` (also stored in the
binary header). Regenerate with `scripts/generate-gemma-tokenizer.py`; the binary format
is documented in that script's docstring.
