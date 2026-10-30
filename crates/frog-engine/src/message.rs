use serde::{Deserialize, Serialize};
use schemars::JsonSchema;
use serde_json::Value;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
}

/// Provider-neutral content block. Modeled on the Anthropic shape since it's the richest.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Block {
    Text {
        text: String,
    },
    Thinking {
        text: String,
        /// Only Anthropic needs this to replay thinking; other providers ignore it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },
    ToolUse {
        id: String,
        name: String,
        input: Value,
    },
    ToolResult {
        id: String,
        name: String,
        content: String,
        #[serde(default)]
        is_error: bool,
    },
    /// An image the model can look at (attached by the user, or returned by a tool). Base64.
    Image {
        mime: String,
        data: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct Message {
    pub role: Role,
    pub content: Vec<Block>,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: vec![Block::Text { text: text.into() }],
        }
    }

    pub fn text(&self) -> String {
        self.content
            .iter()
            .filter_map(|b| match b {
                Block::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("")
    }

    pub fn tool_uses(&self) -> Vec<(String, String, Value)> {
        self.content
            .iter()
            .filter_map(|b| match b {
                Block::ToolUse { id, name, input } => {
                    Some((id.clone(), name.clone(), input.clone()))
                }
                _ => None,
            })
            .collect()
    }
}

#[derive(Default, Clone, Debug)]
pub struct Usage {
    /// Prompt tokens not read from the cache (prefilled), including `cache_write`.
    pub input: u64,
    pub output: u64,
    /// Prompt tokens read from the provider's cache (billed at its cached rate).
    pub cache_read: u64,
    /// The part of `input` written to the cache (Anthropic bills these above the input rate).
    pub cache_write: u64,
    pub model: Option<String>,
    /// The response's `x-frog-upstream` header (frog cloud says who served the call).
    pub upstream: Option<String>,
}

impl Usage {
    /// Tokens occupying the context window after this call.
    pub fn context(&self) -> u64 {
        self.input + self.cache_read + self.output
    }
}
