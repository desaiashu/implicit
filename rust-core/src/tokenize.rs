//! Runtime keyword tokenisation, so the app can add words without shelling out
//! to Python. Loads the model's own `bpe.model` with sentencepiece and emits the
//! same `<tokens> @word` lines `scripts/fetch-model.sh` produces — the
//! GigaSpeech vocabulary is uppercase, so words are upper-cased first (lowercase
//! tokenises to OOV pieces and would be dropped).

use sentencepiece::SentencePieceProcessor;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

/// Tokenise `words` into sherpa keyword-file content using the BPE model under
/// `model_dir`. Skips blanks, `#` comments, and any word whose pieces aren't all
/// in the token table (so a bad entry can't break the whole file).
pub fn keywords_file_contents(model_dir: &Path, words: &[String]) -> Result<String, String> {
    let bpe = find_bpe_model(model_dir).ok_or("bpe.model not found under model dir")?;
    let spp = SentencePieceProcessor::open(&bpe).map_err(|e| format!("open bpe.model: {e}"))?;
    let tokens = load_token_set(&model_dir.join("tokens.txt"))?;

    let mut out = String::new();
    for raw in words {
        let word = raw.trim();
        if word.is_empty() || word.starts_with('#') {
            continue;
        }
        let pieces = spp
            .encode(&word.to_uppercase())
            .map_err(|e| format!("encode {word:?}: {e}"))?;
        let toks: Vec<&str> = pieces.iter().map(|p| p.piece.as_str()).collect();
        if toks.is_empty() || !toks.iter().all(|t| tokens.contains(*t)) {
            continue;
        }
        out.push_str(&toks.join(" "));
        out.push_str(" @");
        out.push_str(word);
        out.push('\n');
    }
    Ok(out)
}

fn find_bpe_model(model_dir: &Path) -> Option<PathBuf> {
    let direct = model_dir.join("bpe.model");
    if direct.is_file() {
        return Some(direct);
    }
    // Otherwise look one level down (the extracted model subdir).
    let entries = fs::read_dir(model_dir).ok()?;
    for e in entries.flatten() {
        let candidate = e.path().join("bpe.model");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn load_token_set(tokens_path: &Path) -> Result<HashSet<String>, String> {
    let text = fs::read_to_string(tokens_path).map_err(|e| format!("read tokens.txt: {e}"))?;
    Ok(text
        .lines()
        .filter_map(|l| l.split_whitespace().next().map(str::to_owned))
        .collect())
}
