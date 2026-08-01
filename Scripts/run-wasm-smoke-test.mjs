// Runs a wasm32-unknown-wasip1 executable under Node's built-in WASI support.
//
// Usage: node Scripts/run-wasm-smoke-test.mjs <path-to-.wasm>
//
// Exits with the wasm module's own exit code so callers can gate on it.

import { WASI } from "node:wasi";
import { readFile } from "node:fs/promises";
import { argv, exit, stdout } from "node:process";

const modulePath = argv[2];
if (!modulePath) {
	stdout.write("usage: node run-wasm-smoke-test.mjs <path-to-.wasm>\n");
	exit(2);
}

const wasi = new WASI({
	version: "preview1",
	args: [modulePath],
	env: {},
	returnOnExit: true,
});

const bytes = await readFile(modulePath);
const wasmModule = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(
	wasmModule,
	wasi.getImportObject(),
);

const exitCode = wasi.start(instance);
exit(exitCode);
