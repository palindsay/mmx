# Documentation

Start here:

- [Quick start](../QUICKSTART.md) - install the tools, build, and run Studio or the CLI.
- [Studio workflow](../apps/mmx_studio/README.md#scan-to-print) - inspect a scan,
  preview cleanup, compare the original and export; includes New Project behavior.
- [Optimized builds](../QUICKSTART.md#optimized-binaries-with-make) - Make targets,
  portable Python commands and native platform output paths.
- [Contributor guide](../CONTRIBUTING.md) - project layout, coding standards, tests, and pull requests.
- [`REVERSE-ENGINEERING.md`](REVERSE-ENGINEERING.md) - the evidence-backed
  report on Meshmixer 3.5.0: artifact identity, `.mix` layout, tool semantics,
  RTTI, method names, and what remains unknown.
- [`RTTI.md`](RTTI.md) - class and vtable attribution.
- [`METHODS.md`](METHODS.md) - recovered `Class::Method` names and related
  open-source projects.
- [`TOOL-MATRIX.md`](TOOL-MATRIX.md) - every recovered tool/action mapped to
  the kernel, Studio UI, tests and status.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) - technology choices, module map and
  performance engineering.
- [`CLI.md`](CLI.md) - command-line reference, scan/cleanup/batch, recipe contracts
  and report limitations; [example cleanup recipe](scan/cleanup.recipe.json).
- [`TESTING.md`](TESTING.md) - test commands, coverage and known gaps.
- [`PRODUCTION-READINESS.md`](PRODUCTION-READINESS.md) - current implementation, evidence and outstanding release gates.
- [`RELEASE.md`](RELEASE.md) - native installers, signing, acceptance and rollback.
- [`release/ACCEPTANCE.md`](release/ACCEPTANCE.md) - release evidence, native checks and required external inputs.
- [`PERFORMANCE.md`](PERFORMANCE.md) - repeatable latency and peak-memory measurements.
- [`FEATURE-COMPLETION.md`](FEATURE-COMPLETION.md) - historical PR #5 desktop checkpoint.
- [`MANIPULATORS.md`](MANIPULATORS.md) - local/world axes, snapping and numeric transforms.
- [`MATERIALS.md`](MATERIALS.md) - supported textures, UVs, formats and editing limits.
- [`WALL-THICKNESS.md`](WALL-THICKNESS.md) - verified directional clearance, bounded growth and assumptions.
- [Native renderer](../apps/mmx_studio/native_renderer/README.md) - build requirements, fallback and graphics validation.
- [`REMEDIATION-PLAN.md`](REMEDIATION-PLAN.md) - historical correctness and coverage work.
- [`FINISH-PLAN.md`](FINISH-PLAN.md) - historical plan for broader parity:
  evidence closure, feature parity, oracle validation and release.
- [`reference/`](reference/) - public Autodesk API headers, help notes and the
  command parameter reference used as source evidence.

The project labels claims as **[observed]** (directly evidenced from the
binary, public headers or runtime), **[inferred]** (a reasoned conclusion) and
**[unknown]** (not established). Keep that distinction when editing docs.
