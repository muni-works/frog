//! Shared bounded raster I/O for generated assets, captures and visual comparison.
use super::Ctx;
use crate::protocol::Image;
use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use image::{DynamicImage, ImageFormat, ImageReader};
use std::{io::Cursor, path::Path};

pub const MAX_BYTES: usize = 64 * 1024 * 1024;

pub fn decode(bytes: &[u8]) -> Result<DynamicImage> {
    if bytes.len() > MAX_BYTES {
        bail!("image exceeds 64 MiB");
    }
    let format = image::guess_format(bytes).context("unrecognized image format")?;
    if !matches!(
        format,
        ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::WebP
    ) {
        bail!("expected PNG, JPEG or WebP");
    }
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().context("invalid or oversized image")
}

pub async fn read(ctx: &Ctx, path: &str) -> Result<DynamicImage> {
    let path = ctx.resolve(path);
    let metadata = tokio::fs::metadata(&path)
        .await
        .with_context(|| format!("reading {}", path.display()))?;
    if metadata.len() > MAX_BYTES as u64 {
        bail!("image exceeds 64 MiB");
    }
    let bytes = tokio::fs::read(&path).await?;
    tokio::task::spawn_blocking(move || decode(&bytes)).await?
}

pub fn png(image: &DynamicImage) -> Result<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    image.write_to(&mut out, ImageFormat::Png)?;
    Ok(out.into_inner())
}

pub fn attachment(image: &DynamicImage) -> Result<Image> {
    Ok(Image {
        mime: "image/png".into(),
        data: STANDARD.encode(png(image)?),
    })
}

/// Visual assets remain under the project even in sessions with broader write permissions.
pub fn workspace_path(ctx: &Ctx, path: &Path) -> Result<()> {
    ctx.check_writable(path)?;
    let root = ctx.root.canonicalize()?;
    let mut ancestor = path.to_path_buf();
    let mut tail = Vec::new();
    while !ancestor.exists() {
        tail.push(
            ancestor
                .file_name()
                .context("invalid output path")?
                .to_owned(),
        );
        if !ancestor.pop() {
            bail!("invalid output path");
        }
    }
    let mut resolved = ancestor.canonicalize()?;
    for part in tail.into_iter().rev() {
        if part == ".." {
            resolved.pop();
        } else if part != "." {
            resolved.push(part);
        }
    }
    if !resolved.starts_with(root) {
        bail!("visual output must be inside the workspace");
    }
    Ok(())
}

pub async fn save(ctx: &Ctx, path: &Path, bytes: &[u8]) -> Result<()> {
    workspace_path(ctx, path)?;
    if tokio::fs::try_exists(path).await? {
        bail!(
            "{} already exists; choose a new output path",
            path.display()
        );
    }
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    use tokio::io::AsyncWriteExt;
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .await?;
    file.write_all(bytes).await?;
    // Tokio writes may still be pending after write_all; consumers read assets immediately.
    file.flush().await?;
    Ok(())
}

pub async fn response(mut response: reqwest::Response) -> Result<serde_json::Value> {
    if !response.status().is_success() {
        bail!("visual endpoint returned HTTP {}", response.status());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len().saturating_add(chunk.len()) > MAX_BYTES {
            bail!("visual response exceeds 64 MiB");
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).context("invalid JSON from visual endpoint")
}

/// Supplied numeric options must be integers; malformed values never silently use defaults.
pub fn integer(input: &serde_json::Value, key: &str, default: u64) -> Result<u64> {
    match input.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_u64()
            .with_context(|| format!("{key} must be a nonnegative integer")),
    }
}
