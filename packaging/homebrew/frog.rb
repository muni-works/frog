# Homebrew formula for Frog - a coding agent for local models
# Run `brew install muni-works/muni/frog` to install

class Frog < Formula
  desc "Frog - a coding agent for local models"
  homepage "https://frog.toys"
  url "https://github.com/muni-works/frog.git",
      tag:      "v0.1.0-rc1",
      revision: "HEAD"
  license "MIT OR Apache-2.0"

  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args
  end

  test do
    system "frog", "--version"
  end
end
