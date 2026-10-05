//! Explicitly configured image generation; no implicit paid backend or silent stub fallback.
use super::{Ctx, Output};
use crate::{protocol::Image, provider::ToolSpec};
use anyhow::{Context, Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

const MAX_RESPONSE: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Settings {
    /// "stub" or "remote". Unset disables generation.
    pub backend: Option<String>,
    /// Full OpenAI-compatible generations URL, including /v1/images/generations.
    pub endpoint: Option<String>,
    pub model: Option<String>,
    /// Environment variable containing the bearer token; never a literal secret.
    pub api_key_env: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    prompt: String,
    #[serde(default = "default_size")]
    size: String,
    seed: Option<u64>,
    #[serde(default = "default_count")]
    count: usize,
}
fn default_size() -> String {
    "1024x1024".into()
}
fn default_count() -> usize {
    1
}

impl Request {
    fn parse(input: &Value) -> Result<(Self, u32, u32)> {
        let req: Self = serde_json::from_value(input.clone()).context("invalid Image arguments")?;
        if req.prompt.trim().is_empty() || req.prompt.len() > 32_000 {
            bail!("prompt must contain 1–32000 bytes of text");
        }
        if !(1..=4).contains(&req.count) {
            bail!("count must be between 1 and 4");
        }
        let dimensions = req
            .size
            .split_once('x')
            .and_then(|(w, h)| Some((w.parse::<u32>().ok()?, h.parse::<u32>().ok()?)))
            .filter(|(w, h)| (64..=2048).contains(w) && (64..=2048).contains(h));
        let (w, h) =
            dimensions.context("size must be WIDTHxHEIGHT, each dimension between 64 and 2048")?;
        Ok((req, w, h))
    }
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "Image".into(),
        description: "Generate images only when the user requests them. Pictures appear in the transcript and lightbox. Uses the configured image backend; remote generation may incur costs. Stub results are labeled placeholders. Do not call this tool unprompted.".into(),
        schema: json!({"type":"object", "properties": {
            "prompt":{"type":"string"},
            "size":{"type":"string", "description":"WIDTHxHEIGHT, 64–2048 per dimension; default 1024x1024"},
            "seed":{"type":"integer", "minimum":0},
            "count":{"type":"integer", "minimum":1, "maximum":4, "default":1}
        }, "required":["prompt"], "additionalProperties":false}),
    }
}

fn progress(ctx: &Ctx, message: &str) {
    if let Some(tx) = &ctx.progress {
        let _ = tx.send(message.into());
    }
}

pub async fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let (request, width, height) = Request::parse(input)?;
    let settings = &ctx.image;
    let backend = settings
        .backend
        .as_deref()
        .context("Image is not configured. Set [image].backend to remote or stub in config.toml")?;
    progress(ctx, "Generating images…");
    let (images, model) = match backend {
        "stub" => {
            let mut bytes = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut bytes, width, height);
                encoder.set_color(png::ColorType::Rgb);
                encoder.set_depth(png::BitDepth::Eight);
                let mut writer = encoder.write_header()?;
                let pixels: Vec<u8> = (0..width * height)
                    .flat_map(|i| {
                        if ((i % width) / 32 + (i / width) / 32) % 2 == 0 {
                            [200, 210, 220]
                        } else {
                            [230, 235, 240]
                        }
                    })
                    .collect();
                writer.write_image_data(&pixels)?;
            }
            let image = Image {
                mime: "image/png".into(),
                data: STANDARD.encode(bytes),
            };
            (vec![image; request.count], "stub placeholder".to_string())
        }
        "remote" => {
            let endpoint = settings
                .endpoint
                .as_deref()
                .context("[image].endpoint is required for remote generation")?;
            let url = reqwest::Url::parse(endpoint).context("invalid image endpoint")?;
            if !matches!(url.scheme(), "http" | "https")
                || !url.username().is_empty()
                || url.password().is_some()
            {
                bail!("image endpoint must be http(s) without embedded credentials");
            }
            let model = settings
                .model
                .as_deref()
                .filter(|m| !m.trim().is_empty())
                .context("[image].model is required for remote generation")?;
            let mut body = json!({"model":model, "prompt":request.prompt, "size":request.size, "n":request.count, "response_format":"b64_json"});
            if let Some(seed) = request.seed {
                body["seed"] = json!(seed);
            }
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(300))
                .redirect(reqwest::redirect::Policy::none())
                .build()?;
            let mut http = client.post(url).json(&body);
            if let Some(env) = &settings.api_key_env {
                let token = std::env::var(env).with_context(|| {
                    format!("image API key environment variable {env} is missing")
                })?;
                if token.trim().is_empty() {
                    bail!("image API key environment variable {env} is empty");
                }
                http = http.bearer_auth(token);
            }
            let mut response = http
                .send()
                .await
                .map_err(|e| anyhow::anyhow!("image request failed: {}", e.without_url()))?;
            if !response.status().is_success() {
                bail!("image endpoint returned HTTP {}", response.status());
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.context("reading image response")? {
                if bytes.len().saturating_add(chunk.len()) > MAX_RESPONSE {
                    bail!("image response exceeds 64 MiB");
                }
                bytes.extend_from_slice(&chunk);
            }
            let value: Value =
                serde_json::from_slice(&bytes).context("invalid JSON from image endpoint")?;
            (decode_response(&value, request.count)?, model.to_string())
        }
        _ => bail!("unknown image backend `{backend}`; expected stub or remote"),
    };
    progress(ctx, "Images ready.");
    Ok(Output {
        content: format!(
            "{} image(s) shown to the user. Backend: {backend}; model: {model}; size: {}; seed: {}.{}",
            images.len(),
            request.size,
            request
                .seed
                .map(|s| s.to_string())
                .unwrap_or_else(|| "unspecified".into()),
            if backend == "stub" {
                " These are test placeholders, not generated artwork."
            } else {
                ""
            }
        ),
        display: Some(format!(
            "{} {} · {}",
            images.len(),
            if backend == "stub" {
                "test placeholders"
            } else {
                "images"
            },
            request.size
        )),
        images,
        ..Default::default()
    })
}

fn decode_response(value: &Value, count: usize) -> Result<Vec<Image>> {
    let data = value["data"]
        .as_array()
        .context("image response has no data array")?;
    if data.len() != count {
        bail!(
            "image endpoint returned {} images; expected {count}",
            data.len()
        );
    }
    data.iter()
        .map(|item| {
            let encoded = item["b64_json"]
                .as_str()
                .context("image endpoint must return b64_json (URL responses are unsupported)")?;
            let bytes = STANDARD
                .decode(encoded)
                .context("image endpoint returned invalid base64")?;
            let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
                "image/png"
            } else if bytes.starts_with(b"\xff\xd8\xff") {
                "image/jpeg"
            } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
                "image/webp"
            } else {
                bail!("image endpoint returned unsupported image data; expected PNG, JPEG or WebP");
            };
            Ok(Image {
                mime: mime.into(),
                data: STANDARD.encode(bytes),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_arguments_and_responses() {
        for input in [
            json!({"prompt":" "}),
            json!({"prompt":"x","count":0}),
            json!({"prompt":"x","count":5}),
            json!({"prompt":"x","size":"99999x64"}),
            json!({"prompt":"x","seed":-1}),
        ] {
            assert!(Request::parse(&input).is_err());
        }
        for value in [
            json!({"data":[]}),
            json!({"data":[{"url":"https://example.com/x"}]}),
            json!({"data":[{"b64_json":"!!!"}]}),
            json!({"data":[{"b64_json":STANDARD.encode(b"not an image")}]}),
        ] {
            assert!(decode_response(&value, 1).is_err());
        }
    }
    #[tokio::test]
    async fn stub_is_png_at_requested_dimensions_and_requires_configuration() {
        let mut ctx = Ctx::new(std::env::temp_dir());
        let input = json!({"prompt":"a frog", "size":"128x64", "count":2,"seed":42});
        assert!(run(&input, &mut ctx).await.is_err());
        ctx.image.backend = Some("stub".into());
        let out = run(&input, &mut ctx).await.unwrap();
        assert_eq!(out.images.len(), 2);
        assert!(out.content.contains("placeholders"));
        let bytes = STANDARD.decode(&out.images[0].data).unwrap();
        let reader = png::Decoder::new(std::io::Cursor::new(bytes))
            .read_info()
            .unwrap();
        assert_eq!((reader.info().width, reader.info().height), (128, 64));
        assert!(super::super::kind("Image") == super::super::Kind::Exec);
    }
    #[tokio::test]
    async fn remote_posts_parameters_and_returns_images_with_progress() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut ctx = Ctx::new(std::env::temp_dir());
        ctx.image.backend = Some("stub".into());
        let image = run(&json!({"prompt":"fixture", "size":"64x64"}), &mut ctx)
            .await
            .unwrap()
            .images
            .remove(0);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut received = Vec::new();
            let body = loop {
                let mut buf = [0u8; 4096];
                let n = socket.read(&mut buf).await.unwrap();
                assert!(n > 0);
                received.extend_from_slice(&buf[..n]);
                if let Some(end) = received.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&received[..end]);
                    assert!(headers.starts_with("POST /v1/images/generations HTTP/1.1"));
                    let len: usize = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(str::to_owned)
                        })
                        .unwrap()
                        .parse()
                        .unwrap();
                    if received.len() >= end + 4 + len {
                        break serde_json::from_slice::<Value>(&received[end + 4..end + 4 + len])
                            .unwrap();
                    }
                }
            };
            assert_eq!(
                body,
                json!({"model":"test-image", "prompt":"a frog", "size":"64x64", "n":1, "seed":42, "response_format":"b64_json"})
            );
            let response = json!({"data":[{"b64_json": image.data}]}).to_string();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).as_bytes()).await.unwrap();
        });
        ctx.image = Settings {
            backend: Some("remote".into()),
            endpoint: Some(format!("http://{addr}/v1/images/generations")),
            model: Some("test-image".into()),
            api_key_env: None,
        };
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        ctx.progress = Some(tx);
        let out = run(
            &json!({"prompt":"a frog", "size":"64x64", "seed":42}),
            &mut ctx,
        )
        .await
        .unwrap();
        server.await.unwrap();
        assert_eq!(out.images.len(), 1);
        assert_eq!(out.images[0].mime, "image/png");
        assert!(out.content.contains("test-image"));
        assert_eq!(rx.try_recv().unwrap(), "Generating images…");
        assert_eq!(rx.try_recv().unwrap(), "Images ready.");
    }
}
