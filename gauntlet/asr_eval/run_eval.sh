#!/bin/bash
# Runs the ASR eval through the real TranscriptionService via the env-gated
# XCTest runner (ASREvalRunnerTests). Produces a raw decode JSON that
# score.py turns into results/baseline numbers.
#
# Usage:
#   ./gauntlet/asr_eval/run_eval.sh OUT_RAW.json [extra TEST_RUNNER_ env pairs...]
# Example:
#   ./gauntlet/asr_eval/run_eval.sh /tmp/raw_baseline.json
#   ./gauntlet/asr_eval/run_eval.sh /tmp/raw_final.json ORTTAAI_ASR_EVAL_BIAS=1
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?output raw json path required}"
shift || true

ENV_ARGS=(
  "TEST_RUNNER_ORTTAAI_ASR_EVAL=1"
  "TEST_RUNNER_ORTTAAI_ASR_EVAL_MANIFEST=$REPO/gauntlet/asr_eval/corpus/manifest.json"
  "TEST_RUNNER_ORTTAAI_ASR_EVAL_OUT=$OUT"
)
for pair in "$@"; do
  ENV_ARGS+=("TEST_RUNNER_$pair")
done

cd "$REPO"
env "${ENV_ARGS[@]}" xcodebuild \
  -project Orttaai.xcodeproj \
  -scheme Orttaai \
  -configuration Debug \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -skip-testing:OrttaaiUITests \
  -only-testing:OrttaaiTests/ASREvalRunnerTests \
  test 2>&1 | grep -E "ASR-EVAL|Test (case|session|Suite)|TEST|error:" | tail -120
