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
# Realistic corpus (after build_realistic_corpus.py); a later pair overrides
# the default manifest:
#   ./gauntlet/asr_eval/run_eval.sh /tmp/raw_real.json ORTTAAI_ASR_EVAL_PATHS=live \
#     ORTTAAI_ASR_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus_realistic/manifest_realistic.json
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

# ORTTAAI_EVAL_CONFIG=Release runs the (production-optimized) Release build with
# testability forced on; useful when the Debug provisioning profile is stale.
CONFIG="${ORTTAAI_EVAL_CONFIG:-Debug}"
EXTRA=()
if [ "$CONFIG" = "Release" ]; then EXTRA+=("ENABLE_TESTABILITY=YES"); fi
# ORTTAAI_EVAL_XCODEBUILD_EXTRA passes extra whitespace-separated xcodebuild
# arguments, e.g. "-derivedDataPath ./.dd -clonedSourcePackagesDirPath .spm-local
# -disableAutomaticPackageResolution" when running from a worktree.
if [ -n "${ORTTAAI_EVAL_XCODEBUILD_EXTRA:-}" ]; then
  read -r -a PASSTHROUGH <<< "$ORTTAAI_EVAL_XCODEBUILD_EXTRA"
  EXTRA+=("${PASSTHROUGH[@]}")
fi

cd "$REPO"
env "${ENV_ARGS[@]}" xcodebuild \
  -project Orttaai.xcodeproj \
  -scheme Orttaai \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -skip-testing:OrttaaiUITests \
  -only-testing:OrttaaiTests/ASREvalRunnerTests \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  test 2>&1 | grep -E "ASR-EVAL|Test (case|session|Suite)|TEST|error:" | tail -120
