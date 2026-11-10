#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift test --enable-code-coverage -Xswiftc -warnings-as-errors
COVERAGE_JSON=$(swift test --show-codecov-path)
swift Scripts/check_coverage.swift "${COVERAGE_JSON}" 45.0
