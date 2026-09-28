set minimum-version := "1.55.0"

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Build the CLI and both stubs, run the unit tests, lint.
build:
    zig build
    zig build test --summary all
    ziglint src/ build.zig
    @echo "ok: build"

# Run the full e2e battery (tests/e2e.sh): pack fixtures, dispatch fat
# binaries natively where the host can and under qemu where the CPU
# identity must be controlled, and assert outputs and exit codes.
test: build
    tests/e2e.sh

default: test

# Audit GitHub Actions workflows with zizmor.
lint-actions:
    zizmor --format=plain --min-confidence=medium .

# Check that GitHub Actions references are SHA-pinned with valid version
# comments.
pinact-check:
    pinact run -check --verify -min-age 3 .github/workflows/*.yaml .github/actions/*/action.y*
