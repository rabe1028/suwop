//! `EmbeddingGemma` 2 tokenizer with parity to Hugging Face `tokenizers` BPE.
//!
//! Data comes from `data/embeddinggemma2-tokenizer.bin` (see `data/README.md`). Pipeline:
//! replace `' '` with `'▁'`, treat the whole string as one word (no spaces remain after
//! normalization), start from Unicode chars (byte fallback for chars outside the vocab),
//! merge the lowest-rank adjacent pair (leftmost on ties) until none remains, and wrap
//! the ids in `<bos>` (2) and `<eos>` (1).
//!
//! Intentional difference: special-token text such as `<bos>` or `<pad>` inside the input
//! is NOT recognised as a special token; it is tokenized as ordinary text.

use std::collections::HashMap;
use std::sync::OnceLock;

const DATA: &[u8] = include_bytes!("../data/embeddinggemma2-tokenizer.bin");
const MAGIC: &[u8; 4] = b"SWGT";
const VERSION: u32 = 1;
const BOS: u32 = 2;
const EOS: u32 = 1;
const HEADER_LEN: usize = 4 + 4 + 32 + 4 + 4;

struct Tokenizer {
    vocab: HashMap<&'static str, u32>,
    byte_tokens: [u32; 256],
    /// (left id, right id) -> (rank, merged id)
    merges: HashMap<(u32, u32), (u32, u32)>,
}

struct Reader {
    data: &'static [u8],
    pos: usize,
}

impl Reader {
    fn take(&mut self, len: usize) -> Result<&'static [u8], String> {
        let end = self.pos.checked_add(len).ok_or("tokenizer data overflow")?;
        let slice = self
            .data
            .get(self.pos..end)
            .ok_or("tokenizer data truncated")?;
        self.pos = end;
        Ok(slice)
    }

    fn u32(&mut self) -> Result<u32, String> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_| "tokenizer data truncated")?;
        Ok(u32::from_le_bytes(bytes))
    }

    fn u16(&mut self) -> Result<u16, String> {
        let bytes: [u8; 2] = self
            .take(2)?
            .try_into()
            .map_err(|_| "tokenizer data truncated")?;
        Ok(u16::from_le_bytes(bytes))
    }
}

impl Tokenizer {
    fn parse(data: &'static [u8]) -> Result<Self, String> {
        if data.len() < HEADER_LEN || &data[..4] != MAGIC {
            return Err("tokenizer data has a bad header".to_owned());
        }
        let mut reader = Reader { data, pos: 4 };
        if reader.u32()? != VERSION {
            return Err("unsupported tokenizer data version".to_owned());
        }
        reader.take(32)?;
        let vocab_count = reader.u32()?;
        let merge_count = reader.u32()?;
        let mut tokens: Vec<&'static str> = Vec::with_capacity(vocab_count as usize);
        let mut vocab = HashMap::with_capacity(vocab_count as usize);
        for id in 0..vocab_count {
            let len = usize::from(reader.u16()?);
            let text = std::str::from_utf8(reader.take(len)?)
                .map_err(|_| "tokenizer vocab is not UTF-8")?;
            tokens.push(text);
            vocab.insert(text, id);
        }
        let mut merges = HashMap::with_capacity(merge_count as usize);
        let mut joined = String::new();
        for rank in 0..merge_count {
            let left = reader.u32()?;
            let right = reader.u32()?;
            let (Some(l), Some(r)) = (tokens.get(left as usize), tokens.get(right as usize)) else {
                return Err("tokenizer merge references a missing token".to_owned());
            };
            joined.clear();
            joined.push_str(l);
            joined.push_str(r);
            let result = *vocab
                .get(joined.as_str())
                .ok_or("tokenizer merge result missing")?;
            merges.insert((left, right), (rank, result));
        }
        let mut byte_tokens = [0_u32; 256];
        for (byte, slot) in byte_tokens.iter_mut().enumerate() {
            let name = format!("<0x{byte:02X}>");
            *slot = *vocab
                .get(name.as_str())
                .ok_or("tokenizer lacks a byte fallback token")?;
        }
        Ok(Self {
            vocab,
            byte_tokens,
            merges,
        })
    }

    fn encode(&self, text: &str) -> Vec<u32> {
        let mut symbols: Vec<u32> = Vec::with_capacity(text.len() + 2);
        let mut buf = [0_u8; 4];
        for ch in text.chars() {
            let ch = if ch == ' ' { '\u{2581}' } else { ch };
            let s: &str = ch.encode_utf8(&mut buf);
            if let Some(&id) = self.vocab.get(s) {
                symbols.push(id);
            } else {
                symbols.extend(s.bytes().map(|b| self.byte_tokens[usize::from(b)]));
            }
        }
        loop {
            let mut best: Option<(u32, usize, u32)> = None;
            for (index, pair) in symbols.windows(2).enumerate() {
                if let Some(&(rank, merged)) = self.merges.get(&(pair[0], pair[1]))
                    && best.is_none_or(|(best_rank, _, _)| rank < best_rank)
                {
                    best = Some((rank, index, merged));
                }
            }
            let Some((_, index, merged)) = best else {
                break;
            };
            symbols[index] = merged;
            symbols.remove(index + 1);
        }
        let mut ids = Vec::with_capacity(symbols.len() + 2);
        ids.push(BOS);
        ids.extend(symbols);
        ids.push(EOS);
        ids
    }
}

/// Encode `text` into `[<bos>, ...tokens..., <eos>]` ids.
pub fn encode(text: &str) -> Result<Vec<u32>, String> {
    static TOKENIZER: OnceLock<Result<Tokenizer, String>> = OnceLock::new();
    match TOKENIZER.get_or_init(|| Tokenizer::parse(DATA)) {
        Ok(tokenizer) => Ok(tokenizer.encode(text)),
        Err(message) => Err(message.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::encode;

    #[derive(serde::Deserialize)]
    struct Case {
        text: String,
        ids: Vec<u32>,
    }

    #[test]
    fn empty_string_is_bos_eos() -> Result<(), String> {
        assert_eq!(encode("")?, vec![2, 1]);
        Ok(())
    }

    #[test]
    fn matches_hugging_face_tokenizers() -> Result<(), String> {
        let cases: Vec<Case> = serde_json::from_str(include_str!(
            "../tests/fixtures/gemma-tokenizer-parity.json"
        ))
        .map_err(|error| error.to_string())?;
        assert!(cases.len() >= 300);
        for case in cases {
            assert_eq!(encode(&case.text)?, case.ids, "text {:?}", case.text);
        }
        Ok(())
    }
}
