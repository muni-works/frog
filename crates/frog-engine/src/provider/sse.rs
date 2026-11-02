use anyhow::Result;
use futures_util::StreamExt;

/// Checks the status and surfaces the server's error body.
pub async fn check(resp: reqwest::Response) -> Result<reqwest::Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    // The edge's verdict for a billing refusal (its `x-frog-billing` header) rides along;
    // other providers don't send it, and the body decides instead.
    let billing = resp
        .headers()
        .get("x-frog-billing")
        .and_then(|v| v.to_str().ok())
        .and_then(super::Billing::from_header);
    let body = resp.text().await.unwrap_or_default();
    Err(super::HttpError {
        status: status.as_u16(),
        body: body.trim().to_string(),
        billing,
    }
    .into())
}

/// Calls `f` for every newline-delimited line in the body. Works for SSE and NDJSON.
pub async fn for_each_line(
    resp: reqwest::Response,
    mut f: impl FnMut(&str) -> Result<()>,
) -> Result<()> {
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        buf.extend_from_slice(&chunk?);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line);
            f(line.trim_end_matches(['\r', '\n']))?;
        }
    }
    if !buf.is_empty() {
        f(String::from_utf8_lossy(&buf).trim_end())?;
    }
    Ok(())
}
