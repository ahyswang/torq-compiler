#!/bin/bash
source /workspace/yswang26/mlir/venv/bin/activate
export PATH=/workspace/yswang26/mlir/iree-build/third_party/iree/tools/:$PATH

mkdir -p ./data.ignore

# pushd ../../
# pytest ./tests/test_keras_ops.py
# popd 
#iree-import-tflite ../../.pytest_cache/d/versioned_fixtures/quantized_tflite_model_file/quantized_tflite_model_file.0c11b10e45b57bdd0dc8a5279f8d4bdd83e24fb15763618fca48d23b85374977.tflite -o ./data.ignore/demo.tosa
iree-import-tflite ./quantized_tflite_model_file.0c11b10e45b57bdd0dc8a5279f8d4bdd83e24fb15763618fca48d23b85374977.tflite -o ./data.ignore/demo.tosa
torq-compile ./data.ignore/demo.tosa  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=./data.ignore/ > ./data.ignore/log.txt 2>&1 

