# Contributing to mmx

Keep changes focused. Make the behavior clear, test it, and document what still
needs work. Fixes, new features, useful test models, and clearer docs all help.

## Get running

Follow the [quick start](QUICKSTART.md) for the platform setup. Use Flutter
**3.47.9**, the version pinned in CI, with its bundled Dart SDK. Desktop builds
also need Rust **1.99.1**, Python **3.11+**, and the native tools for your OS.

From the repository root, run `python3 start.py --debug` for development and hot
reload. On Windows, use `py -3 start.py --debug`. Tests use repository fixtures;
you do not need Meshmixer installed.

Use `make build` for optimized CLI and Studio binaries, or `make cli` and
`make studio` for one component. Without Make, use `python3 tool/build.py` (Windows:
`py -3 tool/build.py`). Build on the target OS; staged outputs and packaging
commands are documented in the [quick start](QUICKSTART.md#optimized-binaries-with-make).

## Know where the change belongs

| Path | What belongs here |
|---|---|
| `packages/mmx_core/lib/src/` | Pure Dart geometry, file formats, scene history, and CPU rendering |
| `packages/mmx_core/bin/` | CLI commands, scan reports and batch orchestration |
| `apps/mmx_studio/lib/` | Desktop state, controls, and rendering integration |
| `apps/mmx_studio/native_renderer/` | Rust/wgpu renderer and shaders |
| Each package's `test/` | Unit tests and fixtures |
| `apps/mmx_studio/integration_test/` | Native desktop workflows |
| `tool/` and `docs/` | Verification, packaging, and project documentation |

Read the [architecture](docs/ARCHITECTURE.md) before changing boundaries between
components. Keep Flutter out of the kernel.

## Write code we can maintain

- Use two-space indentation in Dart, `lower_snake_case.dart` filenames,
  `UpperCamelCase` types, and `lowerCamelCase` members. Run `dart format` on
  changed Dart files. The analyzers use `lints/recommended` and `flutter_lints`.
- Bound allocations and use typed arrays in geometry loops. Preserve supported
  mesh attributes, undo, and cancellation behavior.
- Report algorithm fallbacks and approximations. Failed edits must leave the
  document intact; failed exports must preserve existing files.
- This is a clean-room project. Do not copy Autodesk source. Cite algorithm
  sources and label claims **observed**, **inferred**, or **unknown**, following
  the [reverse-engineering guide](docs/REVERSE-ENGINEERING.md).

## Check your work

From the repository root, run:

```sh
./tool/verify.sh
```

On Windows, run that script in Git Bash, or use `py -3 tool/build.py --verify`.
`make test` invokes the same portable verifier. It fetches dependencies, checks
Dart formatting, runs both analyzers, and runs the kernel and Studio test suites.

Use `*_test.dart` names. The kernel uses `package:test`; Studio uses
`flutter_test`. For a focused run, use `dart test test/remesh_test.dart` from
`packages/mmx_core/` or `flutter test test/interaction_test.dart` from Studio.
Geometry changes need watertightness, manifoldness, winding, and volume
assertions. Target more than 80% line coverage for new kernel modules.

For renderer changes, run `cargo fmt --check`, `cargo test --locked`, and
`cargo clippy --locked --all-targets -- -D warnings` from the renderer directory.
See [testing](docs/TESTING.md) for coverage and native integration checks.

## Submit the change

Open an issue before a large change. Small fixes can go straight to a pull
request. Use a topic branch and concise imperative commits, such as
`Fix material export paths`.

Follow the [PR template](.github/PULL_REQUEST_TEMPLATE.md): explain the resulting
behavior, link the issue or reproducer, and list verification commands and
known limits. Include screenshots for visible UI changes. Update affected docs
and wait for CI to pass.

Bug reports should include the commit, OS/toolchain, input model where possible,
reproduction steps, and expected versus actual results. Report security issues
through [SECURITY.md](SECURITY.md). Follow the [code of conduct](CODE_OF_CONDUCT.md).
Contributions use the project's [Apache-2.0 license](LICENSE).
