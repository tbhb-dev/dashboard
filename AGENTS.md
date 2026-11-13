# Agent instructions

## Repository

`dashboard` is a public Apache-2.0 repository for future iOS and macOS apps. It currently contains repository gates and empty iOS and macOS apps.

## Layout

`MODULE.bazel` pins the shared rules and tools. `BUILD.bazel` defines the repository checks, formatters, and tool shims. `REPO.bazel` excludes generated directories from source discovery. `.bazelrc` loads the generated `preset.bazelrc`. `mise.toml` and `mise.lock` pin the bootstrap tools, and `.github/` holds CI and repository policy. `REUSE.toml`, `LICENSE`, and `LICENSES/` record the license. `apple/` holds the shared Swift library, the two empty apps, and their Bazel targets. Root configuration files and `.vale/` configure the shared gates.

## Commands

Run `mise install` to install the bootstrap tools, then run `bazelisk run //:bazel_env` to build the tool shims.

- Run `bazelisk test //...` to check every repository gate.
- Run `bazelisk run //:format` to format the repository.

Write each Markdown paragraph on one line. Use active voice, Oxford commas, sentence-case headings, and contractions. Avoid semicolons and future-tense phrasing. Keep private details out of this public repository.

Before choosing a model for a subagent or peer run, read models/README.md in tbhb-dev/wiki (<https://github.com/tbhb-dev/wiki/blob/main/models/README.md>).

## Signing and provisioning

The operator handles signing and provisioning. Agents never handle certificates or keys.

## Apple runners

Build Apple targets only on GitHub-hosted macOS runners. Never use self-hosted runners for Apple targets because this repository is public.
