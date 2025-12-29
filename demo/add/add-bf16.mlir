// module {
//   func.func @main(%arg0: tensor<4xbf16>, %arg1: tensor<4xbf16>) -> (tensor<4xbf16>) attributes {tf_saved_model.exported_names = ["serving_default"]} {
//     %136 = tosa.add %arg0, %arg1 : (tensor<4xbf16>, tensor<4xbf16>) -> tensor<4xbf16>
//     //%137 = tosa.sqrt %136 : (tensor<4xbf16>) -> tensor<4xbf16>
//     return %136 : tensor<4xbf16>
//   }
// }


module {
  func.func @main(%arg0: tensor<4xbf16>, %arg1: tensor<4xbf16>) -> (tensor<4xbf16>)  {
    %136 = math.sqrt %arg0 : tensor<4xbf16> 
    return %136 : tensor<4xbf16>
  }
}

