// module {
//   func.func @main(%arg0: tensor<128x1024xi8>, %arg1: tensor<128x1024xi8>) -> (tensor<128x1024xi8>) attributes {tf_saved_model.exported_names = ["serving_default"]} {
//     %136 = tosa.add %arg0, %arg1 : (tensor<128x1024xi8>, tensor<128x1024xi8>) -> tensor<128x1024xi8>
//     //%137 = tosa.sqrt %136 : (tensor<128x1024xi8>) -> tensor<128x1024xi8>
//     return %136 : tensor<128x1024xi8>
//   }
// }

// lram:512K
module {
  func.func @main(%arg0: tensor<256x1024xi8>, %arg1: tensor<256x1024xi8>) -> (tensor<256x1024xi8>) attributes {tf_saved_model.exported_names = ["serving_default"]} {
    %136 = tosa.add %arg0, %arg1 : (tensor<256x1024xi8>, tensor<256x1024xi8>) -> tensor<256x1024xi8>
    //%137 = tosa.sqrt %136 : (tensor<256x1024xi8>) -> tensor<256x1024xi8>
    return %136 : tensor<256x1024xi8>
  }
}


