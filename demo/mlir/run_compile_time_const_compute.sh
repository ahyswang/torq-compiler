#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUT_MLIR="$ROOT_DIR/demo/mlir/compile_time_const_compute.mlir"
OUTPUT_DIR="$ROOT_DIR/demo/mlir/data.ignore/compile_time_const_compute"

if [[ -n "${TORQ_VENV:-}" ]]; then
  # Optional virtualenv activation for local developer setups.
  source "$TORQ_VENV/bin/activate"
fi

if [[ -n "${TORQ_COMPILE_BIN:-}" ]]; then
  TORQ_COMPILE="$TORQ_COMPILE_BIN"
elif command -v torq-compile >/dev/null 2>&1; then
  TORQ_COMPILE="$(command -v torq-compile)"
elif command -v torq-compile-main >/dev/null 2>&1; then
  TORQ_COMPILE="$(command -v torq-compile-main)"
else
  echo "torq-compile or torq-compile-main not found; set TORQ_COMPILE_BIN to override." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

"$TORQ_COMPILE" "$INPUT_MLIR" \
  -o "$OUTPUT_DIR/output.vmfb" \
  --mlir-print-ir-after-all \
  --dump-compilation-phases-to="$OUTPUT_DIR" \
  > "$OUTPUT_DIR/log.txt" 2>&1

grep -n "CompileTimeConstCompute" "$OUTPUT_DIR/log.txt" || true
grep -n "torq-compile-time-const" "$OUTPUT_DIR/log.txt" || true