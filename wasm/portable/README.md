# Portable Herb WebAssembly experiment

This module compiles libherb and its vendored Prism sources to a host-neutral `wasm32-wasip1` reactor. It is separate from the Emscripten/Embind module in the parent directory because JRuby's Endive runtime does not provide a JavaScript host environment.

The experiment currently exports:

- guest allocation and release;
- owned result-buffer release;
- libherb and Prism versions;
- HTML extraction;
- a temporary codec that parses `html: false` documents containing literal nodes.

The temporary literal codec proves that Endive can return real Herb Ruby AST objects. It is not the complete AST wire format.

## Build

Install or unpack a complete WASI SDK. The initial experiment uses WASI SDK 34.

```sh
WASI_SDK_PATH=/path/to/wasi-sdk-34 \
  RBENV_VERSION=4.0.3 \
  bundle exec rake wasm:portable
```

The module is written to `wasm/portable/build/herb.wasm` and is intentionally ignored by Git.

Run its focused tests with:

```sh
JRUBY_JSA_HOME=/tmp/herb-jruby-jsa \
  RBENV_VERSION=jruby-10.1.2.0 \
  bundle exec ruby -Itest test/wasm/backend_test.rb
```

The public experiment can be selected with `HERB_BACKEND=wasm`. Operations that have not crossed the Wasm boundary yet raise `NotImplementedError` rather than silently falling back to the pure-Ruby backend.

## ABI

Each operation returns a pointer to an owned buffer in Wasm memory:

```text
u32 status
u32 payload_length
u8  payload[payload_length]
```

Integers are explicitly little-endian. The caller copies the payload and calls `herb_wasm_result_free`. Inputs are passed as pointer/length pairs and released separately with `herb_wasm_deallocate`.
