#!/bin/bash
source /workspace/yswang26/mlir/venv/bin/activate
export PATH=/workspace/yswang26/mlir/iree-build/third_party/iree/tools/:$PATH

mkdir -p ./data.ignore

torq-compile ./matmul_slice.mlir  -o ./data.ignore/output.vmfb  \
    --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore \
    > ./data.ignore/log.txt 2>&1 
