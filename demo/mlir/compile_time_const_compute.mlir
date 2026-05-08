// CompileTimeConstComputePass example.
// Coverage:
// 1. The RHS weights are compile-time constants, so KernelSelection can pack them.
// 2. The LHS activation remains a runtime argument, so only the marked weight path is folded.
// 3. After torq-compile-time-const-compute, the packed weight slice should become arith.constant.

module {
  func.func @main(%arg0: tensor<1x128xf16>) -> tensor<1x256xf16> {
    %weights = arith.constant dense<1.0> : tensor<256x128xf16>
    %transpose_init = tensor.empty() : tensor<128x256xf16>
    %weights_t = linalg.transpose ins(%weights : tensor<256x128xf16>) outs(%transpose_init : tensor<128x256xf16>) permutation = [1, 0]

    %matmul_init = tensor.empty() : tensor<1x256xf16>
    %result = linalg.matmul ins(%arg0, %weights_t : tensor<1x128xf16>, tensor<128x256xf16>) outs(%matmul_init : tensor<1x256xf16>) -> tensor<1x256xf16>
    return %result : tensor<1x256xf16>
  }
}