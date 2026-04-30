#!/bin/bash
source /workspace/yswang26/mlir/venv/bin/activate
export PATH=/workspace/yswang26/mlir/iree-build/third_party/iree/tools/:$PATH

mkdir -p ./data.ignore

torq-compile ./add-bf16_css.mlir  -o ./data.ignore/output.vmfb  \
    --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore --torq-disable-slices \
    > ./data.ignore/log.txt 2>&1 

# iree-opt --torq-tosa-transformation-pipeline \
#     ./reducesum-avgpool.mlir -o ./data.ignore/output.mlir  \
#     --mlir-print-ir-after-all \
#     > ./data.ignore/log.txt 2>&1 
