#!/bin/bash
source /workspace/yswang26/mlir/venv/bin/activate
export PATH=/workspace/yswang26/mlir/iree-build/third_party/iree/tools/:$PATH

mkdir -p ./data.ignore


torq-compile /workspace/yswang26/mlir/torq-compiler/tests/testdata/tosa_ops/reducesum-avgpool.mlir  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore --torq-disable-slices > ./data.ignore/log.txt 2>&1 

# torq-compile ./add-bf16.mlir  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore --torq-enable-tile-and-fuse -debug > ./data.ignore/log.txt 2>&1 

# torq-compile ./add-bf16.mlir  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore --torq-disable-slices > ./data.ignore/log.txt 2>&1 

# iree-run-module --device=torq --module=./data.ignore/output.vmfb --function=main --input="4xbf16=1.0" --input="4xbf16=10.0"

#torq-compile ../../tests/testdata/linalg_ops/batch-n-matmul-in-int8-out-int16.mlir  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=data.ignore > ./data.ignore/log.txt 2>&1 

exit 0

# torq-compile ../../tests/testdata/tosa_ops/rescale-in-int8-out-uint8.mlir  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=./data.ignore/ > log.txt 2>&1 

pushd ../../
pytest ./tests/test_keras_ops.py
popd 
iree-import-tflite ../../.pytest_cache/d/versioned_fixtures/quantized_tflite_model_file/quantized_tflite_model_file.0c11b10e45b57bdd0dc8a5279f8d4bdd83e24fb15763618fca48d23b85374977.tflite -o ./data.ignore/demo.tosa
torq-compile ./data.ignore/demo.tosa  -o ./data.ignore/output.vmfb  --mlir-print-ir-after-all --dump-compilation-phases-to=./data.ignore/ > ./data.ignore/log.txt 2>&1 


