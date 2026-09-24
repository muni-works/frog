//! Image files named in a prompt ("/Users/me/Desktop/shot.png what's this?") are attached as
//! images, the way a pasted or dropped image is: a path is text to the model, and a model left
//! with only the path will try to fetch it by some other means (or invent one).

use crate::protocol::Image;
use base64::Engine as _;
use regex::Regex;
use std::path::PathBuf;
use std::sync::LazyLock;

/// Larger files are left as paths; providers reject very large images anyway.
const MAX_BYTES: u64 = 20 * 1024 * 1024;

/// Absolute or home-relative paths ending in an image extension, at the start of the text or
/// after whitespace, a quote, `@` or `(`. Spaces are allowed inside (macOS screenshot names
/// have them), so the match runs lazily to the first image extension.
static PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:^|[\s"'`@(])((?:~/|/)[^\n"'`]*?\.(?:png|jpe?g|gif|webp))\b"#).unwrap()
});

fn mime(path: &str) -> &'static str {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".png") {
        "image/png"
    } else if lower.ends_with(".gif") {
        "image/gif"
    } else if lower.ends_with(".webp") {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

fn resolve(raw: &str) -> PathBuf {
    // Terminals escape spaces when a file is dragged in.
    let raw = raw.replace("\\ ", " ");
    match raw.strip_prefix("~/") {
        Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        None => PathBuf::from(raw),
    }
}

/// The images named in `text` that exist, and the text with each such path replaced by a short
/// note (so the model reads the picture, not a path it can't open).
pub fn attach(text: &str) -> (String, Vec<Image>) {
    let mut images = Vec::new();
    let mut out = text.to_string();
    for m in PATH.captures_iter(text).filter_map(|c| c.get(1)) {
        let path = resolve(m.as_str());
        let fits = std::fs::metadata(&path)
            .map(|md| md.is_file() && md.len() <= MAX_BYTES)
            .unwrap_or(false);
        if !fits {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        images.push(Image {
            mime: mime(m.as_str()).into(),
            data: base64::engine::general_purpose::STANDARD.encode(bytes),
        });
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        out = out.replacen(m.as_str(), &format!("[attached image: {name}]"), 1);
    }
    (out, images)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attaches_existing_image_paths_with_spaces_and_leaves_the_rest() {
        let dir = std::env::temp_dir().join(format!("frog-image-paths-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let shot = dir.join("Screenshot 2026-07-15 at 4.05.04\u{202f}PM.png");
        std::fs::write(&shot, b"\x89PNG fake").unwrap();
        let text = format!("{} how many credits are left?", shot.display());
        let (clean, images) = attach(&text);
        assert_eq!(images.len(), 1);
        assert_eq!(images[0].mime, "image/png");
        assert_eq!(
            clean,
            "[attached image: Screenshot 2026-07-15 at 4.05.04\u{202f}PM.png] how many credits are left?"
        );

        let at = format!("look at @{}", shot.display());
        assert_eq!(attach(&at).1.len(), 1);

        let (same, none) = attach("see /nope/missing.png and src/main.rs");
        assert!(none.is_empty());
        assert_eq!(same, "see /nope/missing.png and src/main.rs");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
