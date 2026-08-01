#!/bin/sh
set -e

cd "$(dirname "$0")"/../

# Builds and runs the experimental wasm runtime smoke test.
#
# Requires:
#   - Swift 6.3.2 toolchain (selected via TOOLCHAINS below)
#   - the wasm32-unknown-wasip1 Swift SDK named in SWIFT_SDK
#   - LLD 21 on PATH (the SDK's linker)
#   - Node with WASI support (v22+); Deno's node:wasi shim is a stub and
#     cannot run these modules
#
# Override any of these from the environment to test other combinations.

TOOLCHAINS="${TOOLCHAINS:-org.swift.632202605101a}"
SWIFT_SDK="${SWIFT_SDK:-6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1}"
LLD_BIN="${LLD_BIN:-/opt/homebrew/opt/lld@21/bin}"

export TOOLCHAINS
# ImageFormats can't build for wasm; see the comment in Package.swift.
export SCUI_WASM=1

# swift-mutex 0.0.6 only defines its `Storage` type for Darwin, Glibc/Musl/
# Bionic and WinSDK, so wasip1 gets no implementation at all and the module
# fails to compile. SwiftCrossUI depends on it directly, so there's no way to
# route around it. Until that lands upstream, redirect the dependency at a
# locally patched copy that adds a no-op lock for WASILibc.
#
# `swift package edit` rewrites Package.resolved, so the redirect is undone
# on the way out to keep the working tree clean.
cleanup() {
	swift package unedit swift-mutex >/dev/null 2>&1 || true
	git checkout -- Package.resolved >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

swift package unedit swift-mutex >/dev/null 2>&1 || true
swift package edit swift-mutex --path .wasm-spike-deps/swift-mutex

PATH="$LLD_BIN:$PATH" swift build \
	--build-system native \
	--swift-sdk "$SWIFT_SDK" \
	--product WasmSmokeTest

node Scripts/run-wasm-smoke-test.mjs \
	".build/wasm32-unknown-wasip1/debug/WasmSmokeTest.wasm"
