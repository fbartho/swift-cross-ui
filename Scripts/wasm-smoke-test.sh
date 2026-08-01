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
# Drops the dependencies that can't build for wasm; see Package.swift.
export SCUI_WASM=1

PATH="$LLD_BIN:$PATH" swift build \
	--build-system native \
	--swift-sdk "$SWIFT_SDK" \
	--product WasmSmokeTest

node Scripts/run-wasm-smoke-test.mjs \
	".build/wasm32-unknown-wasip1/debug/WasmSmokeTest.wasm"
