//! Where credentials live, in one place: the Bash sandbox hides these paths, the Read tool
//! refuses them, the command classifier asks before a command mentions them, and sandboxed
//! commands get an environment without secret-shaped variables.

use std::path::{Path, PathBuf};

/// Credential locations under `$HOME`. The Bash sandbox masks them, Read refuses them, and a
/// command that names one (`~/x` or `$HOME/x`) asks first.
pub const HOME_SECRETS: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".netrc",
    ".docker/config.json",
    ".kube",
    ".config/gh",
    ".gh",
    ".config/gcloud",
    ".azure",
    ".password-store",
    "Library/Keychains",
    // frog's config dir holds config.toml (which may embed `api_key`) and models.json. The
    // non-secret file agents read, config.toml, is allowed by name (`READABLE_IN_SECRETS`);
    // keys added to this dir later (providers' `keys*`) stay hidden.
    ".config/frog",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    ".config/op",
    ".vault-token",
    ".wrangler",
    ".config/wrangler",
];

/// Files inside a [`HOME_SECRETS`] dir that hold no credential and that agents read.
pub const READABLE_IN_SECRETS: &[&str] = &[".config/frog/config.toml"];

/// File names that are credentials wherever they sit (a key copied into a project).
const SECRET_FILE_NAMES: &[&str] = &[
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "authorized_keys",
    ".netrc",
    ".git-credentials",
    ".vault-token",
];

/// Strings in a command that point at credentials beyond the home paths: keychain reads,
/// dotenv files, service-account JSON. False positives only ask.
const COMMAND_MARKERS: &[&str] = &[
    ".netrc",
    "keychain",
    "security find-generic-password",
    "security find-internet-password",
    "security dump-keychain",
    ".env",
    "credentials.json",
    "service-account",
    "id_rsa",
    "id_ed25519",
    "authorized_keys",
];

/// Environment variable names (lowercase substrings) that hold secrets, for the classifier.
const SECRET_ENV_MENTIONS: &[&str] = &[
    "aws_secret_access_key",
    "aws_session_token",
    "api_key",
    "apikey",
    "secret_key",
    "access_token",
    "auth_token",
    "private_key",
    "gcp_service_account",
];

/// Whether a command mentions a credential path, a keychain read or a secret variable.
/// Checked against the raw command (so it also flags what the parser can't parse), with
/// `~` and `$HOME` forms both matched. False positives are fine: they only ask.
pub fn mentioned(cmd: &str) -> bool {
    let lowered = cmd.to_lowercase();
    let home_path = HOME_SECRETS.iter().any(|s| {
        let s = s.to_lowercase();
        ["~/", "$home/", "${home}/"]
            .iter()
            .any(|h| lowered.contains(&format!("{h}{s}")))
    });
    if home_path {
        return true;
    }
    if COMMAND_MARKERS.iter().any(|c| {
        if *c == ".env" {
            // A file mention, not the word "environment".
            lowered.contains(".env") && !lowered.contains("environment")
        } else {
            lowered.contains(c)
        }
    }) {
        return true;
    }
    SECRET_ENV_MENTIONS.iter().any(|v| lowered.contains(v))
}

/// Whether reading `path` would read a credential: under a [`HOME_SECRETS`] location (by
/// its own path or where its symlinks lead), or a key file by name. `home` is `$HOME`.
pub fn is_secret_path(path: &Path, home: &Path) -> bool {
    let real_home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let mut forms: Vec<PathBuf> = vec![path.to_path_buf()];
    if let Ok(real) = path.canonicalize() {
        forms.push(real);
    }
    forms.iter().any(|p| {
        let named = p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
            SECRET_FILE_NAMES.contains(&n)
                || SECRET_FILE_NAMES
                    .iter()
                    .any(|k| k.starts_with("id_") && n.starts_with(k) && !n.ends_with(".pub"))
        });
        named
            || [home, real_home.as_path()].iter().any(|h| {
                HOME_SECRETS.iter().any(|s| p.starts_with(h.join(s)))
                    && !READABLE_IN_SECRETS.iter().any(|r| p == &h.join(r))
            })
    })
}

/// Whether an environment variable is secret-shaped, so a sandboxed command doesn't inherit
/// it: `env | curl …` would otherwise send it anywhere the network allows.
pub fn is_secret_env(name: &str) -> bool {
    const EXACT: &[&str] = &[
        "FROG_LISTEN_TOKEN",
        "FROG_GIT_CREDENTIAL_GATEWAY",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ];
    let n = name.to_ascii_uppercase();
    EXACT.contains(&n.as_str())
        || n.starts_with("RUNPOD_SECRET_")
        || n.ends_with("_KEY")
        || n.ends_with("_TOKEN")
        || n.ends_with("_PASSWORD")
        || n.ends_with("_PASSWD")
        || n.ends_with("_CREDENTIALS")
        || n.contains("_SECRET")
        || n.starts_with("SECRET")
        || n.contains("API_KEY")
        || n.contains("PRIVATE_KEY")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_paths_under_home_and_by_name() {
        let home = Path::new("/home/u");
        for p in [
            "/home/u/.ssh/id_ed25519",
            "/home/u/.aws/credentials",
            "/home/u/.config/gh/hosts.yml",
            "/home/u/.config/frog/models.json",
            "/home/u/.git-credentials",
            "/work/proj/id_rsa",
            "/work/proj/id_ed25519_deploy",
        ] {
            assert!(is_secret_path(Path::new(p), home), "{p}");
        }
        for p in [
            "/home/u/.config/frog/config.toml",
            "/home/u/.sshrc-notes",
            "/home/u/proj/src/main.rs",
            "/work/proj/id_ed25519.pub",
        ] {
            assert!(!is_secret_path(Path::new(p), home), "{p}");
        }
    }

    #[test]
    fn secret_env_names() {
        for k in [
            "ANTHROPIC_API_KEY",
            "GITHUB_TOKEN",
            "GH_TOKEN",
            "CLIENT_SECRET",
            "MY_SECRET_THING",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_ACCESS_KEY_ID",
            "AWS_SESSION_TOKEN",
            "RUNPOD_SECRET_hf_token",
            "FROG_LISTEN_TOKEN",
            "FROG_GIT_CREDENTIAL_GATEWAY",
            "STRIPE_KEY",
            "DB_PASSWORD",
        ] {
            assert!(is_secret_env(k), "{k}");
        }
        for k in [
            "PATH",
            "HOME",
            "TERM",
            "AWS_REGION",
            "CARGO_HOME",
            "LANG",
            "SSH_AUTH_SOCK",
        ] {
            assert!(!is_secret_env(k), "{k}");
        }
    }

    #[test]
    fn mentions_both_home_forms() {
        assert!(mentioned("cat ~/.aws/credentials"));
        assert!(mentioned("cat $HOME/.config/gh/hosts.yml"));
        assert!(mentioned("cat ${HOME}/.kube/config"));
        assert!(!mentioned("cargo test"));
    }
}
