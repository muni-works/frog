#!/bin/zsh
# Builds tang-llm-ios for device and simulator and wraps it as Tang/TangLLM.xcframework.
# TANG_DIR points at a tang checkout (default ../tang-ios-spike next to frog).
set -euo pipefail
here=${0:A:h}/..
tang=${TANG_DIR:-$HOME/Developer/tang-ios-spike}
cd $tang
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --release -p tang-llm-ios --lib --target $t
done
out=$here/Tang/TangLLM.xcframework
rm -rf $out
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libtang_llm_ios.a -headers $here/Tang/include \
  -library target/aarch64-apple-ios-sim/release/libtang_llm_ios.a -headers $here/Tang/include \
  -output $out
