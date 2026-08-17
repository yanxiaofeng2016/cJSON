# AGENTS.md

## Cursor Cloud specific instructions

cJSON is a single C library (ANSI C89) — no servers, ports, databases, or package
managers. There is nothing long-running to "run"; the product is the built library
plus its test binaries. All test data (Unity, JSON Patch vectors) is vendored in-repo;
there are no git submodules to init.

Build tooling (`gcc`/`clang`, `cmake`, `make`) is provided by the environment and
refreshed by the update script — do not reinstall it manually.

### Build, test, and run (development)

Standard CMake flow (see `README.md` for full details). Enable the optional
`cJSON_Utils` library so its tests are built too:

```bash
mkdir -p build && cd build
cmake .. -DENABLE_CJSON_UTILS=ON
cmake --build .
ctest --output-on-failure   # runs the full 22-test suite
./cJSON_test                 # demo: parses/prints JSON from test.c
```

### Lint

There is no separate linter. `ENABLE_CUSTOM_COMPILER_FLAGS=ON` (default) enables
strict warning flags, so a clean `cmake --build .` with no warnings is the lint gate.

### Notes

- The legacy root `Makefile` (`make all && make test`) is deprecated and only runs the
  small `cJSON_test` demo, not the full Unity suite — prefer the CMake/CTest flow above.
- `BUILD_SHARED_LIBS=ON` is the default, so the demo/binaries link `libcjson.so`; run
  standalone consumers with `LD_LIBRARY_PATH=build`.
