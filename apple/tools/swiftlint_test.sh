#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Runs the Bazel-fetched SwiftLint (the first argument) over the sources of
# the apple package, in the runfiles tree. It fails on any violation,
# warnings included.
set -euo pipefail
swiftlint=$(realpath "$1")
cd apple
exec "${swiftlint}" lint --strict --no-cache --config .swiftlint.yml
