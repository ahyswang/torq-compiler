// not fully_connected
// module {
//   func.func @main(%arg0: tensor<1x128x256xi8> {ml_program.identifier = "serving_default_keras_tensor_1:0", tf_saved_model.index_path = ["keras_tensor_1"]}, %arg1: tensor<1x64x128xi8> {ml_program.identifier = "serving_default_keras_tensor:0", tf_saved_model.index_path = ["keras_tensor"]}) -> (tensor<1x64x256xi16> {ml_program.identifier = "PartitionedCall_1:0", tf_saved_model.index_path = ["output_0"]}) attributes {tf_saved_model.exported_names = ["serving_default"]} {
//     %0 = tosa.matmul %arg1, %arg0 : (tensor<1x64x128xi8>, tensor<1x128x256xi8>) -> tensor<1x64x256xi16>
//     return %0 : tensor<1x64x256xi16>
//   }
// }

// module {
//   func.func @main(%arg0: tensor<1x1x256xi8> {ml_program.identifier = "serving_default_keras_tensor_1:0", tf_saved_model.index_path = ["keras_tensor_1"]}, %arg1: tensor<1x256x128xi8> {ml_program.identifier = "serving_default_keras_tensor:0", tf_saved_model.index_path = ["keras_tensor"]}) -> (tensor<1x1x128xi16> {ml_program.identifier = "PartitionedCall_1:0", tf_saved_model.index_path = ["output_0"]}) attributes {tf_saved_model.exported_names = ["serving_default"]} {
//     %0 = tosa.matmul %arg0, %arg1 : (tensor<1x1x256xi8>, tensor<1x256x128xi8>) -> tensor<1x1x128xi16>
//     return %0 : tensor<1x1x128xi16>
//   }
// }



// module {
//   func.func @main(%arg0: tensor<1x1x256xf16> {ml_program.identifier = "serving_default_keras_tensor_1:0", tf_saved_model.index_path = ["keras_tensor_1"]}, %arg1: tensor<1x256x128xf16> {ml_program.identifier = "serving_default_keras_tensor:0", tf_saved_model.index_path = ["keras_tensor"]}) -> (tensor<1x1x128xf16> {ml_program.identifier = "PartitionedCall_1:0", tf_saved_model.index_path = ["output_0"]}) attributes {tf_saved_model.exported_names = ["serving_default"]} {
//     %0 = tosa.matmul %arg0, %arg1 : (tensor<1x1x256xf16>, tensor<1x256x128xf16>) -> tensor<1x1x128xf16>
//     return %0 : tensor<1x1x128xf16>
//   }
// }

// module {
//   func.func @main(%arg0: tensor<128x256xi8>, %arg1: tensor<64x128xi8>) -> (tensor<64x256xi16>) {
//     %init = tensor.empty() : tensor<64x256xi16>
//     %0 = linalg.matmul ins(%arg1, %arg0 : tensor<64x128xi8>, tensor<128x256xi8>) outs(%init : tensor<64x256xi16>) -> tensor<64x256xi16>
//     return %0 : tensor<64x256xi16>
//   }
// }


// module {
//   func.func @main(%arg0: tensor<128x256xi8>, %arg1: tensor<1x128xi8>) -> (tensor<1x256xi16>) {
//     %init = tensor.empty() : tensor<1x256xi16>
//     %0 = linalg.matmul ins(%arg1, %arg0 : tensor<1x128xi8>, tensor<128x256xi8>) outs(%init : tensor<1x256xi16>) -> tensor<1x256xi16>
//     return %0 : tensor<1x256xi16>
//   }
// }

// fully_connected ok 

module {
  func.func @main(%arg1: tensor<1x128xf16>) -> (tensor<1x256xf16>) {
    //%1 = "arith.constant"() {value = 42 : i32} : () -> i32
    %cst = arith.constant dense<1.0> : tensor<256x128xf16>
    %init1 = tensor.empty() : tensor<128x256xf16>
    %1 = linalg.transpose ins(%cst:tensor<256x128xf16>) outs(%init1:tensor<128x256xf16>) permutation = [1, 0]
    %init = tensor.empty() : tensor<1x256xf16>
    %0 = linalg.matmul ins(%arg1, %1 : tensor<1x128xf16>, tensor<128x256xf16>) outs(%init : tensor<1x256xf16>) -> tensor<1x256xf16>
    return %0 : tensor<1x256xf16>
  }
}
