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
    /// "stub", "remote", "tang", or "apple". Unset disables generation.
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
    output_dir: Option<String>,
    steps: Option<usize>,
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
        if req.steps.is_some_and(|steps| !(1..=100).contains(&steps)) {
            bail!("steps must be between 1 and 100");
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
            "count":{"type":"integer", "minimum":1, "maximum":4, "default":1},
            "output_dir":{"type":"string", "description":"Optional workspace directory for new PNG assets and generation metadata"},
            "steps":{"type":"integer","minimum":1,"maximum":100,"description":"Optional inference steps; requires backend support"}
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
    let output_dir = request.output_dir.as_ref().map(|p| ctx.resolve(p));
    if let Some(dir) = &output_dir {
        super::visual::workspace_path(ctx, &dir.join("asset.png"))?;
    }
    let settings = &ctx.image;
    let backend = settings
        .backend
        .as_deref()
        .context("Image is not configured. Set [image].backend to remote, tang, apple or stub in config.toml")?;
    if backend == "apple" && (request.seed.is_some() || request.steps.is_some()) {
        bail!("Apple ImageCreator does not support seeds or inference steps");
    }
    progress(ctx, "Generating images…");
    let mut generation_metadata = Value::Null;
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
        "remote" | "tang" | "apple" => {
            let endpoint = if backend == "apple" {
                let mut profile = crate::config::Profile::new(
                    crate::config::ProviderKind::Openai,
                    crate::sidecar::APPLE,
                );
                profile.sidecar = Some(crate::sidecar::APPLE.into());
                crate::sidecar::ensure(&profile).await?;
                format!(
                    "{}/images/generations",
                    crate::sidecar::base_url(crate::sidecar::APPLE)
                )
            } else {
                settings
                    .endpoint
                    .clone()
                    .context("[image].endpoint is required for remote/tang generation")?
            };
            let url = reqwest::Url::parse(&endpoint).context("invalid image endpoint")?;
            if !matches!(url.scheme(), "http" | "https")
                || !url.username().is_empty()
                || url.password().is_some()
            {
                bail!("image endpoint must be http(s) without embedded credentials");
            }
            let model = settings
                .model
                .as_deref()
                .or((backend == "apple").then_some("apple/illustration"))
                .filter(|m| !m.trim().is_empty())
                .context("[image].model is required for remote generation")?;
            let mut body = json!({"model":model, "prompt":request.prompt, "size":request.size, "n":request.count, "response_format":"b64_json"});
            if let Some(seed) = request.seed {
                body["seed"] = json!(seed);
            }
            if let Some(steps) = request.steps {
                body["steps"] = json!(steps);
            }
            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(300))
                .redirect(reqwest::redirect::Policy::none())
                .build()?;
            let mut http = client.post(url).json(&body);
            if backend == "tang" {
                http = http.header("x-frog-progress", "sse");
            }
            if let Some(env) = &settings.api_key_env {
                let token = std::env::var(env).with_context(|| {
                    format!("image API key environment variable {env} is missing")
                })?;
                if token.trim().is_empty() {
                    bail!("image API key environment variable {env} is empty");
                }
                http = http.bearer_auth(token);
            }
            let response = http
                .send()
                .await
                .map_err(|e| anyhow::anyhow!("image request failed: {}", e.without_url()))?;
            let value = receive_response(response, ctx).await?;
            generation_metadata = json!({"model":value["model"].as_str().filter(|s| s.len() <= 128), "images":value["data"].as_array().map(|items| items.iter().take(4).map(|item| json!({"seed":item["seed"].as_u64(),"steps":item["steps"].as_u64(),"width":item["width"].as_u64(),"height":item["height"].as_u64()})).collect::<Vec<_>>())});
            (decode_response(&value, request.count)?, model.to_string())
        }
        _ => bail!("unknown image backend `{backend}`; expected stub, remote, tang or apple"),
    };
    let mut saved = Vec::new();
    if let Some(dir) = output_dir {
        let id = crate::session::new_id();
        for (i, image) in images.iter().enumerate() {
            let raster = super::visual::decode(&STANDARD.decode(&image.data)?)?;
            let path = dir.join(format!("image-{id}-{}.png", i + 1));
            super::visual::save(ctx, &path, &super::visual::png(&raster)?).await?;
            saved.push(path.display().to_string());
        }
        let metadata = json!({"backend":backend,"model":model,"prompt":request.prompt,"requested_size":request.size,"seed":request.seed,"steps":request.steps,"generation":generation_metadata,"files":saved});
        super::visual::save(
            ctx,
            &dir.join(format!("image-{id}.json")),
            &serde_json::to_vec_pretty(&metadata)?,
        )
        .await?;
    }
    progress(ctx, "Images ready.");
    Ok(Output {
        content: format!(
            "{} image(s) shown to the user. Backend: {backend}; model: {model}; requested size: {}; seed: {}.{} Saved assets: {}. Generation parameters: {}",
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
            },
            serde_json::to_string(&saved)?,
            generation_metadata
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

/// Tang's optional SSE transport carries bounded numeric step progress and a final
/// OpenAI-compatible data array. Parsing handles arbitrary TCP chunk boundaries.
async fn receive_response(mut response: reqwest::Response, ctx: &Ctx) -> Result<Value> {
    if !response.status().is_success() {
        bail!("image endpoint returned HTTP {}", response.status());
    }
    let streaming = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("text/event-stream"));
    let mut parser = Sse::default();
    let mut bytes = Vec::new();
    let mut total = 0usize;
    while let Some(chunk) = response.chunk().await.context("reading image response")? {
        total = total.saturating_add(chunk.len());
        if total > MAX_RESPONSE {
            bail!("image response exceeds 64 MiB");
        }
        if streaming {
            for value in parser.push(&chunk)? {
                if let (Some(step), Some(of)) = (value["step"].as_u64(), value["of"].as_u64()) {
                    if of > 0 && of <= 400 && step <= of {
                        progress(ctx, &format!("Generating images: step {step}/{of}…"));
                    }
                }
                if value.get("error").is_some() {
                    bail!("image generation stream reported an error");
                }
                if value["data"].is_array() {
                    if parser.result.replace(value).is_some() {
                        bail!("duplicate final image response");
                    }
                }
            }
        } else {
            bytes.extend_from_slice(&chunk);
        }
    }
    if streaming {
        if !parser.buffer.iter().all(u8::is_ascii_whitespace) {
            bail!("truncated image event stream");
        }
        parser
            .result
            .context("image event stream ended without a result")
    } else {
        serde_json::from_slice(&bytes).context("invalid JSON from image endpoint")
    }
}
#[derive(Default)]
struct Sse {
    buffer: Vec<u8>,
    searched: usize,
    result: Option<Value>,
}
impl Sse {
    fn push(&mut self, chunk: &[u8]) -> Result<Vec<Value>> {
        self.buffer.extend_from_slice(chunk);
        let mut values = Vec::new();
        loop {
            let boundary = (self.searched..self.buffer.len()).find_map(|i| {
                if self.buffer[i..].starts_with(b"\r\n\r\n") {
                    Some((i, 4))
                } else if self.buffer[i..].starts_with(b"\n\n") {
                    Some((i, 2))
                } else {
                    None
                }
            });
            let Some((end, delimiter)) = boundary else {
                self.searched = self.buffer.len().saturating_sub(3);
                break;
            };
            let frame =
                std::str::from_utf8(&self.buffer[..end]).context("invalid UTF-8 image event")?;
            let data = frame
                .lines()
                .filter_map(|line| line.strip_prefix("data:"))
                .map(|s| s.strip_prefix(' ').unwrap_or(s))
                .collect::<Vec<_>>()
                .join("\n");
            if !data.is_empty() && data != "[DONE]" {
                values.push(serde_json::from_str(&data).context("invalid image event JSON")?);
            }
            self.buffer.drain(..end + delimiter);
            self.searched = 0;
        }
        Ok(values)
    }
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
            super::visual::decode(&bytes)?;
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
    fn image_events_handle_fragmented_utf8_and_crlf() {
        let stream = "event: progress\r\ndata: {\"step\":1,\"of\":8}\r\n\r\nevent: result\ndata: {\"data\":[],\"note\":\"🐸\"}\n\ndata: [DONE]\n\n";
        for size in 1..32 {
            let mut parser = Sse::default();
            let values: Vec<_> = stream
                .as_bytes()
                .chunks(size)
                .flat_map(|c| parser.push(c).unwrap())
                .collect();
            assert_eq!(values.len(), 2);
            assert_eq!(values[0]["step"], 1);
            assert_eq!(values[1]["note"], "🐸");
            assert!(parser.buffer.is_empty());
        }
    }
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
            json!({"data":[{"b64_json":STANDARD.encode(b"\x89PNG\r\n\x1a\ntruncated")}]} ),
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
    async fn saves_new_assets_and_metadata_inside_workspace() {
        let root = std::env::temp_dir().join(format!("frog-assets-{}", crate::session::new_id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut ctx = Ctx::new(root.clone());
        ctx.image.backend = Some("stub".into());
        let output = run(
            &json!({"prompt":"sprite", "size":"64x64", "output_dir":"assets", "seed":42}),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(output.content.contains("assets/image-"));
        let paths: Vec<_> = std::fs::read_dir(root.join("assets"))
            .unwrap()
            .map(|p| p.unwrap().path())
            .collect();
        assert_eq!(paths.len(), 2);
        let meta = paths
            .iter()
            .find(|p| p.extension().is_some_and(|e| e == "json"))
            .unwrap();
        let meta: Value = serde_json::from_slice(&std::fs::read(meta).unwrap()).unwrap();
        assert_eq!(meta["seed"], 42);
        assert_eq!(meta["prompt"], "sprite");
        assert!(
            run(
                &json!({"prompt":"sprite", "output_dir":"../outside"}),
                &mut ctx
            )
            .await
            .is_err()
        );
        std::fs::remove_dir_all(root).unwrap();
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
