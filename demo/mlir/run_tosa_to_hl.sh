#!/bin/bash
source /workspace/yswang26/mlir/venv/bin/activate
export PATH=/workspace/yswang26/mlir/iree-build/third_party/iree/tools/:$PATH

mkdir -p ./data.ignore

iree-opt --torq-tosa-transformation-pipeline \
    ./reducesum-avgpool.mlir -o ./data.ignore/output.mlir  \
    --mlir-print-ir-after-all --debug \
    > ./data.ignore/log.txt 2>&1 