# Homebrew formula for Frog - a coding agent for local models
# Run `brew install muni-works/muni/frog` to install
#
# TEMPLATE: the @VERSION@ / @SHA256_*@ placeholders are filled in by the release workflow
# (.github/workflows/release.yml, "homebrew formula" step) from the release tarballs'
# .sha256 files. The rendered frog.rb is attached to each GitHub release and, when the
# HOMEBREW_TAP_TOKEN secret is set, committed to muni-works/homebrew-muni.

class Frog < Formula
  desc "Frog - a coding agent for local models"
  homepage "https://frog.toys"
  version "@VERSION@"
  license "MIT OR Apache-2.0"

  on_macos do
    depends_on arch: :arm64
    url "https://github.com/muni-works/frog/releases/download/v#{version}/frog-v#{version}-aarch64-apple-darwin.tar.gz"
    sha256 "@SHA256_AARCH64_APPLE_DARWIN@"
  end

  on_linux do
    on_arm do
      url "https://github.com/muni-works/frog/releases/download/v#{version}/frog-v#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "@SHA256_AARCH64_UNKNOWN_LINUX_GNU@"
    end
    on_intel do
      url "https://github.com/muni-works/frog/releases/download/v#{version}/frog-v#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "@SHA256_X86_64_UNKNOWN_LINUX_GNU@"
    end
  end

  def install
    bin.install "frog"
  end

  test do
    system bin/"frog", "--version"
  end
end
