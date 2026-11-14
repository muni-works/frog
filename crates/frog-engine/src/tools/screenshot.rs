use super::{Ctx, Output, str_arg, visual};
use crate::{
    config::{Profile, ProviderKind},
    provider::ToolSpec,
};
use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::time::Duration;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "Screenshot".into(),
        description: "Render a URL or local HTML/SVG file to PNG at a fixed viewport. Shows each capture in the transcript and optionally saves it to output_path for Compare. Waits for fonts and images. Use after each visual change to inspect it. Local WebKit is provided by frog-apple; other systems need a configured screenshot_endpoint.".into(),
        schema: json!({"type":"object", "properties": {
            "url":{"type":"string", "description":"http(s) URL or local HTML/SVG file path"},
            "width":{"type":"integer","minimum":64,"maximum":2048,"default":1280},
            "height":{"type":"integer","minimum":64,"maximum":2048,"default":720},
            "settle_ms":{"type":"integer","minimum":0,"maximum":5000,"default":200},
            "output_path":{"type":"string","description":"New PNG file in the workspace; existing files are never overwritten"}
        },"required":["url"],"additionalProperties":false}),
    }
}

pub async fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let raw = str_arg(input, "url")?;
    let width = visual::integer(input, "width", 1280)?;
    let height = visual::integer(input, "height", 720)?;
    let settle = visual::integer(input, "settle_ms", 200)?;
    if !(64..=2048).contains(&width) || !(64..=2048).contains(&height) || settle > 5000 {
        bail!("invalid viewport or settle_ms");
    }
    let url = if raw.starts_with("http://") || raw.starts_with("https://") {
        reqwest::Url::parse(raw).context("invalid capture URL")?
    } else {
        // Local files must stay inside the workspace, so a capture can't render secrets.
        let file = match raw.strip_prefix("file://") {
            Some(_) => reqwest::Url::parse(raw)
                .context("invalid capture URL")?
                .to_file_path()
                .map_err(|_| anyhow::anyhow!("invalid capture file path"))?,
            None => ctx.resolve(raw),
        };
        let file = file.canonicalize().context("capture file does not exist")?;
        if !file.starts_with(ctx.root.canonicalize()?) {
            bail!("local captures must be inside the workspace");
        }
        reqwest::Url::from_file_path(file)
            .map_err(|_| anyhow::anyhow!("invalid capture file path"))?
    };
    if !matches!(url.scheme(), "http" | "https" | "file")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        bail!("invalid capture URL");
    }
    let path = input["output_path"].as_str().map(|p| ctx.resolve(p));
    if let Some(path) = &path {
        visual::workspace_path(ctx, path)?;
        if path.exists() {
            bail!("output_path already exists");
        }
    }
    let endpoint = if let Some(endpoint) = &ctx.screenshot_endpoint {
        endpoint.clone()
    } else {
        let mut profile = Profile::new(ProviderKind::Openai, crate::sidecar::APPLE);
        profile.sidecar = Some(crate::sidecar::APPLE.into());
        crate::sidecar::ensure(&profile).await?;
        format!(
            "{}/screenshots",
            crate::sidecar::base_url(crate::sidecar::APPLE)
        )
    };
    let endpoint = reqwest::Url::parse(&endpoint).context("invalid screenshot endpoint")?;
    if !matches!(endpoint.scheme(), "http" | "https")
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
    {
        bail!("screenshot endpoint must be http(s) without embedded credentials");
    }
    if let Some(tx) = &ctx.progress {
        let _ = tx.send(format!("Rendering {width}×{height} viewport…"));
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(40))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let mut request = client.post(endpoint).json(&json!({
        "url": url.as_str(), "width": width, "height": height, "settle_ms": settle,
        // frog-apple renders file:// only inside this root.
        "root": ctx.root.canonicalize()?,
    }));
    if ctx.screenshot_endpoint.is_none()
        && let Some(t) = crate::sidecar::apple_token()
    {
        request = request.bearer_auth(t);
    }
    let value = visual::response(request.send().await?).await?;
    if value["data"].as_array().is_none_or(|data| data.len() != 1) {
        bail!("screenshot endpoint must return exactly one image");
    }
    let encoded = value["data"][0]["b64_json"]
        .as_str()
        .context("screenshot response has no image")?;
    let bytes = STANDARD
        .decode(encoded)
        .context("invalid screenshot base64")?;
    let image = visual::decode(&bytes)?;
    if image.width() as u64 != width || image.height() as u64 != height {
        bail!("screenshot raster does not match requested viewport");
    }
    if let Some(path) = &path {
        visual::save(ctx, path, &bytes).await?;
    }
    Ok(Output {
        content: format!(
            "Screenshot shown: {url}; viewport {width}×{height}; raster {}×{}.{}",
            image.width(),
            image.height(),
            path.as_ref()
                .map(|p| format!(" Saved to {}.", ctx.display(p)))
                .unwrap_or_default()
        ),
        display: Some(format!("{width}×{height} screenshot")),
        images: vec![visual::attachment(&image)?],
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn local_captures_stay_in_the_workspace() {
        let root = std::env::temp_dir().join(format!("frog-shot-{}", std::process::id()));
        let ws = root.join("ws");
        std::fs::create_dir_all(&ws).unwrap();
        std::fs::write(root.join("secret.html"), "secret").unwrap();
        let mut ctx = Ctx::new(ws.clone());
        for url in [
            "../secret.html".to_string(),
            format!("file://{}", root.join("secret.html").display()),
        ] {
            let Err(err) = run(&json!({ "url": url }), &mut ctx).await else {
                panic!("{url} was captured");
            };
            assert!(
                err.to_string().contains("inside the workspace"),
                "{url}: {err}"
            );
        }
        std::fs::remove_dir_all(&root).unwrap();
    }
}
