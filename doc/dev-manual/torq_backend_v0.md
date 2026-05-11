# Torq backend v0

## 范围

本文档说明以
`compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp` 中
`TORQLowerExecutableTargetPass::runOnOperation` 为入口的 lowering pipeline 实现。

本文重点关注以下内容：

- pipeline 是如何分阶段组织的；
- 每个阶段使用了哪些 pass；
- 每个 pass 的主要职责是什么；
- 哪些命令行选项会改变 pipeline 的形状；
- TORQ backend 的关键技术点是什么。

这是一份 v0 版本的技术说明，目标是解释当前实现，而不是定义一个稳定的编译器契约。

## 入口

入口函数是 `TORQLowerExecutableTargetPass::runOnOperation`。

从高层来看，它完成 4 个步骤：

1. 校验 executable inner module 中只包含一个 dispatch function；
2. 在该 function 上运行 IREE 的 workgroup 分发；
3. 根据编译选项组装 TORQ 专用 pass pipeline；
4. 在整个 module 上执行组装好的 pipeline。

这条 pipeline 被有意拆分为 3 条主要子流水线：

- Slice 路径：把适合 NPU 的计算准备并降低为 `torq_hl` kernel。
- CPU 回退路径：接管那些不会在 NSS 上运行的操作，并为 CSS 或 Host 编译可执行程序。
- NSS 物化路径：完成 bufferize、outline、地址分配、降低到 `torq_hw`，并附加运行时元数据。

## 顶层控制流

`runOnOperation` 的控制流如下：

```text
ModuleOp
  |
  +-- getDispatchFunction()
  |     校验内部恰好存在一个 func.func。
  |
  +-- createTileAndDistributeToWorkgroupsPass()
  |     仅在 dispatch function 上执行。
  |
  +-- Build TORQ pipeline
        |
        +-- addSlicePasses()   if !torq-from-prebufferized-ir && !torq-disable-slices
        |
        +-- addCpuPasses()     if !torq-disable-css || !torq-disable-host
        |
        +-- addNssPasses()     always
  |
  +-- runPipeline(pipeline, module)
```

## 整体 pass 流程图

下图展示实现中的阶段划分以及主要 pass 组。

```text
                           +--------------------------------------+
                           | runOnOperation                       |
                           | ModuleOp -> validate dispatch func   |
                           +------------------+-------------------+
                                              |
                                              v
                    +------------------------------------------------------+
                    | Stage 0: IREE distribution                            |
                    | createTileAndDistributeToWorkgroupsPass               |
                    +------------------+-----------------------------------+
                                       |
                                       v
        +--------------------------------------------------------------------------+
        | Stage 1: Slice/NPU preparation                                            |
        | DecomposeSoftmax -> OptimizeLinalgForTorq -> ElementwiseToLinalg          |
        | -> optional MarkPatterns/TensorToLinalg/TileAndFuse/Unroll                |
        | -> optional PreConversion -> ValidToSamePad -> LramTile                    |
        | -> optional SpecializeGeneric -> optional Unroll                           |
        | -> ArithToTorqHL -> LinalgToTorqHL -> optional FoldPValueInits             |
        | -> optional TorqHlTile -> KernelSelection -> OptimizeSegmentation          |
        | -> EncodeTensors -> optional Slicing -> FoldConvert -> CompileTimeConst    |
        +------------------+-------------------------------------------------------+
                           |
                           +---------------------------+
                                                       |
                                                       v
        +--------------------------------------------------------------------------+
        | Stage 2: CPU/CSS/Host fallback                                           |
        | optional DtcmTile -> AssignOperationsToCpuPrograms                        |
        | -> OutlineCpuPrograms -> CompileCpuPrograms                               |
        | -> ScalarsToTensors -> optional Unroll -> FoldConvert -> Canonicalize     |
        +------------------+-------------------------------------------------------+
                           |
                           v
        +--------------------------------------------------------------------------+
        | Stage 3: NSS final materialization                                       |
        | optional LowerArithConstants -> ComprehensiveBufferize -> EraseHALDesc    |
        | -> MapBindings -> LowerCallProgramToStartWait -> optional Unroll          |
        | -> OutlineSlicePrograms -> Canonicalize -> optional AddDeallocation       |
        | -> optional Unroll -> AssignAddresses -> ConvertSliceProgramToTorqHw      |
        | -> OutlineNSSPrograms -> ResolveInvocationArguments                       |
        | -> ConvertNssProgramToTorqHw -> ResolveAddresses                          |
        | -> AssignObjectsIdentifiers -> optional Profiling                         |
        +--------------------------------------------------------------------------+
```

## Stage 0：Dispatch 校验与 workgroup 分发

### `getDispatchFunction`

这个辅助函数保证 executable inner module 中恰好只包含一个 `func.func`。
后续 lowering 都默认只有一个 dispatch body，因此如果存在多个 function，
会在这里直接失败。

### `createTileAndDistributeToWorkgroupsPass`

这是 IREE 提供的 dispatch 级 workgroup 分发 pass。
在 TORQ backend 中，它是第一个真正改变 IR 结构的 lowering 步骤，主要作用是：

- 在进入 backend 专用流程前先建立 workgroup 执行结构；
- 保持 pipeline 与 IREE executable lowering 约定一致；
- 把通用 dispatch 并行化与 TORQ 专用的内存、kernel 决策分开。

## Stage 1：Slice 路径

这一阶段负责把 dispatch 中适合 NPU 的那部分计算降低到 `torq_hl`。
从概念上看，它完成图清理、tiling、向 TORQ 高层 kernel 的语义转换、编码，
以及可选的多 slice 并行化。

### Stage 1 流程

```text
Linalg/Tensor/Arith IR
  -> DecomposeSoftmax
  -> OptimizeLinalgForTorq
  -> ConvertElementwiseToLinalg
  -> optional TileAndFuse preparation and execution
  -> optional LinalgToTorqHLPreConversion
  -> ValidToSamePad
  -> LramTile
  -> optional UnrollLoop
  -> ArithToTorqHL
  -> LinalgToTorqHL
  -> optional TorqHlTile
  -> KernelSelection
  -> OptimizeSegmentation
  -> EncodeTensors
  -> optional Slicing
  -> FoldConvert
  -> CompileTimeConstCompute
```

### Stage 1 中的 pass

#### `createDecomposeSoftmaxPass`

把 softmax 分解成更基础的计算块，这样 TORQ pipeline 就不需要在后期再专门处理一条 softmax lowering 路径。
这是一个典型的“复杂算子先拆成简单图”的预处理 pass。

#### `createOptimizeLinalgForTorqPass`

在映射到硬件之前，对 linalg IR 做 TORQ 定制优化。
目标是把 linalg 图整理成更适合后续 tiling 和 kernel pattern matching 的形态。

#### `createCanonicalizerPass`

它会在多个重写型 pass 后反复使用。
其职责是去掉无用或冗余 IR、折叠简单变换，并在主要 lowering 阶段之间稳定 IR 形态。

#### `createConvertElementwiseToLinalgPass`

把 tensor 层面的 elementwise arith 运算统一改写为 `linalg.generic`。
这样后续 pass 就可以在统一的 Linalg 抽象上工作，而不需要同时处理 tensor 和 arith 两套表示。

#### `createMarkPatternsForTileAndFusePass`

只有在 `--torq-enable-tile-and-fuse` 打开时才启用。
它会识别那些在 tiling 和 fusion 过程中必须保持在一起的匹配模式，但当前阶段并不真正改写图。
它更像是在为下一步做规划。

#### `createTensorToLinalgPass`

只有在 `--torq-enable-tile-and-fuse` 打开时才启用。
它把部分 tensor 形状操作降低为 `linalg.generic`，以免这些 op 打断 tile-and-fuse 的模式形成。

#### `createTileAndFusePass`

只有在 `--torq-enable-tile-and-fuse` 打开时才启用。
它对操作进行 tile，并把 producer 融合进 tile 后的计算中，用于减少中间 tensor 和片上内存搬运。

#### `createUnrollLoopPass`

这个 pass 在多个阶段都会出现。
在 Slice 路径中，它可能在 tile-and-fuse 之后执行，也可能在该阶段稍后执行，取决于
`--torq-unroll-loop-after-bufferization`。
它的目标是把基于 loop 的 IR 线性化，便于硬件执行。

#### `createLinalgToTorqHLPreConversionPass`

在非 experimental 路径里，它会插在 tiling 之前；在 experimental 路径里，
它会插在主 linalg 转换之前。
它的作用是在完整转换发生前，先把部分 linalg 操作向 `torq_hl` 做预降低。

#### `createValidToSamePadPass`

把带 `VALID` padding 的卷积类操作改写为等价的 `SAME` 风格形式，具体方式是显式插入 padding 和 slicing。
之所以这样做，是因为 TORQ 硬件及后续 lowering 更适合处理这种变换后的表示。

#### `createLramTilePass`

对 linalg 或 tiling-interface 操作进行切块，使其满足 LRAM 约束。
这是 backend 中最关键的 memory-aware transformation 之一。

#### `createSpecializeLinalgGenericOpPass`

只有在编译启用了 `ENABLE_TORQ_GENERIC` 时才存在。
它会把部分 `linalg.generic` 再特化回命名 linalg op，以帮助后续转换和模式匹配。

#### `createArithToTorqHLConversionPass`

把 arithmetic 操作降低为 `torq_hl`。
执行到这一步时，硬件路径所需的标量或 elementwise arithmetic 已经被表示成 TORQ 高层形式。

#### `createLinalgToTorqHLConversionPass`

这是从通用 linalg 算子到 `torq_hl` kernel 的主语义 lowering。
从这一阶段开始，IR 不再是纯通用的 tensor algebra，而是逐渐变成 TORQ 的执行语义。

#### `createFoldPValueInitsPass`

只有在编译启用了 `ENABLE_TORQ_GENERIC` 时才存在。
它会把某些用于 p-value 初始化的 `linalg.fill` 折叠成常量，避免后续生成没有必要的 generic TORQ 操作。

#### `createTorqHlTilePass`

当 tile-and-fuse 关闭，或者设置了 `--torq-force-torq-hl-tiling` 时执行。
它在 `torq_hl` 语义层上继续做 tiling。

#### `createKernelSelectionPass`

为 `torq_hl` 操作选择具体 kernel 形式和执行模式。
其中包括 vectorization mode 选择，以及面向硬件的权重布局变换。
这是整个 backend 最重要的决策点之一。

#### `torq_hl::createTorqHLOptimizeSegmentationPass`

优化为了适配硬件而引入的 segmentation 操作，例如处理 stride 敏感卷积时插入的 segmentation。
目标是尽可能降低 segmentation 带来的额外开销。

#### `createEncodeTensorsPass`

为 TORQ 操作需要的 tensor 显式写入布局或内存相关编码信息。
经过这一步之后，value 上携带的信息已经足够支持后续的内存规划和硬件 lowering。

#### `createSlicingPass`

只有在未禁用 slicing 且硬件 slice 数量大于 1 时才执行。
它会把部分 `torq_hl` 操作切分成多个 slice 并行执行。
实现上依赖 `scf.forall` 和 tensor slice 来描述并行子计算。

#### `createFoldConvertPass` in the slice path

折叠前面 lowering 过程中引入的冗余 convert 操作。
这个 pass 的目的是在进入最终物化阶段之前先把 IR 噪声降下来。

#### `createCompileTimeConstComputePass`

对被标记为 compile-time-constant 的操作在编译期直接求值。
这可以减少运行时工作量，并简化后续地址和序列化逻辑。

### Stage 1 技术说明

- 当前实现中，slicing 被有意放在 kernel selection 之后。
  代码注释明确说明，更理想的顺序应该更早，但 kernel selection 会做权重重排，
  而该过程无法直接作用于 subview。
- Slice 路径混合使用了通用 MLIR canonicalization 和 TORQ 专用语义 lowering。
  这样做的目的是让代价更高的硬件专用 pass 能在更干净的图上运行。
- tiling 可能发生在 `torq_hl` 转换前，也可能发生在转换后，具体取决于选项和算子形态。

## Stage 2：CPU、CSS 与 Host 回退路径

这一阶段接管那些没有继续留在 Slice/NSS 路径上的工作。
它的输出不是抽象的 fallback 标记，而是会为 CSS 或 Host 真正编译出可执行二进制。

### Stage 2 流程

```text
Residual mixed IR
  -> optional DtcmTile
  -> AssignOperationsToCpuPrograms
  -> OutlineCpuPrograms
  -> CompileCpuPrograms
  -> ScalarsToTensors
  -> optional UnrollLoop
  -> FoldConvert
  -> Canonicalize
```

### Stage 2 中的 pass

#### `createDtcmTilePass`

只有在 CSS fallback 启用时才会执行。
它会把操作切块到能够放进 DTCM，作用与 Slice 路径中的 `LramTilePass` 类似，但目标是 CSS 的内存约束。

#### `createAssignOperationsToCpuProgramsPass`

把合适的操作迁移到 CPU program 中。
这个 pass 会根据 disable 选项决定剩余操作应该落到 CSS 还是 Host。

#### `createOutlineCpuProgramsPass`

把 CPU program 区域 outline 成独立函数或 module，便于与剩余 TORQ 路径解耦并单独编译。

#### `createCompileCpuProgramsPass`

把每个 outline 出来的 CPU program 编译为二进制表示。

对于 CSS program，这个 pass 会构建一条专门的 lowering pipeline，最终生成 `llvm-css` executable。
对于 Host program，则使用 LLVM CPU lowering 路径。
在 codegen 和链接完成后，原始 executable variant 会被替换为包含已编译代码的
`IREE::HAL::ExecutableBinaryOp`。

#### `createScalarsToTensorsPass`

把剩余标量值包装成 tensor。
这样可以避免 value 穿越 program 边界时，由于后续阶段要求 tensor-like operand 而产生不匹配。

#### `createFoldConvertPass` in the CPU fallback path

折叠 CPU 执行和内存传输周围插入的 convert 链。

### Stage 2 技术说明

- CSS fallback 不是解释执行路径，而是真正的编译路径，会产出二进制。
- Host fallback 仍然集成在同一条 executable lowering 框架中。
- 这一阶段可以与 Slice 路径同时存在于同一个 dispatch 中，说明 backend 天生就是异构执行模型。

## Stage 3：NSS 最终物化路径

这一阶段把前面准备好的高层 IR 变成具体可执行的 TORQ program、地址以及运行时可见元数据。

### Stage 3 流程

```text
TorqHL + CPU binaries + mixed memory values
  -> LowerArithConstants
  -> ComprehensiveBufferize
  -> EraseHALDescriptorTypeFromMemRef
  -> MapBindings
  -> LowerCallProgramToStartWait
  -> optional UnrollLoop
  -> OutlineSlicePrograms
  -> Canonicalize
  -> optional AddDeallocation
  -> optional UnrollLoop
  -> AssignAddresses
  -> ConvertSliceProgramToTorqHw
  -> OutlineNSSPrograms
  -> ResolveInvocationArguments
  -> ConvertNssProgramToTorqHw
  -> ResolveAddresses
  -> AssignObjectsIdentifiers
  -> optional Profiling
```

### Stage 3 中的 pass

#### `createLowerArithConstantsPass`

把 `arith.constant` 降低为 `torq_hl.const`，使常量值成为显式的 TORQ 对象，
从而能够参与 XRAM 地址计算与运行时序列化。

#### `addTorqComprehensiveBufferizePasses`

这是 TORQ 专用的 bufferization pass 组合。它依次完成：

1. 消除 empty tensor；
2. 把 empty tensor 转换为 alloc tensor；
3. 使用 TORQ 自定义的 allocation、copy 和 memory-space hook 做 comprehensive bufferization；
4. 执行 bufferization 之后的清理。

其结果是得到以 memref 为核心的 IR，为静态地址分配做好准备。

#### `createEraseHALDescriptorTypeFromMemRefPass`

从 memref 上移除 HAL descriptor type，
这样后续 pipeline 面对的是普通 memref，而不是 HAL 特定的类型包装。

#### `createMapBindingsPass`

把 `hal.interface.binding.subspan` 转换为 `torq_hl.map_binding`。
该 pass 会校验 layout 假设、byte offset 和自然 stride，然后把 binding 改写成 TORQ 专用表示，
并更新相关 subview 的类型。

#### `createLowerCallProgramToStartWaitPass`

把高层的 `torq_hl.call_program` 转换为显式运行时操作：
`create_invocation`、`start_program` 和 `wait_program`。

对于 CSS 调用，它还会进一步物化 code section 和 argument-address section，
并把它们转运到 LRAM、ITCM 和 DTCM 等正确的内存空间。

#### `createOutlineSliceProgramsPass`

把可在 slice 上执行的操作转换成独立的 `torq_hl.program` 对象。
它还会展开基于 `scf.forall` 的 slice 并行结构，并通过分配 executor id 的方式调度每个 slice invocation。

这是一个非常关键的转折点：原本只是 kernel 形态的操作，在这里变成了真正可调用的 slice program。

#### `createAddDeallocationPass`

在 LRAM buffer 生命周期结束时显式插入 deallocation。
这样后续静态分配器才能正确推导 buffer 的生命周期。

#### `createAssignAddressesPass`

对 TORQ 管理的内存空间中的 memref 执行静态地址分配。
它会先检查峰值内存占用是否超出 pool 大小，然后分配地址，并把基地址传播到 subview、reshape、
memory-space cast 等派生 memref 上。

#### `createConvertSliceProgramToTorqHwPass`

把 `Executor::Slice` 类型的 `torq_hl.program` 降低为 `torq_hw` 操作。
这个转换覆盖了实际硬件 kernel，例如 conv、depthwise、fully connected、segmentation、transpose、
elementwise 等。

#### `createOutlineNSSProgramsPass`

把 NSS 相关操作聚合成 `Executor::NSS` program。
该 pass 会按照 `--torq-nss-task-size` 切分操作，预留 XRAM code section，分配两个 LRAM code buffer
做双缓冲 program 装载，并建立 host copy 或上一个 task 预取下一个 program 的逻辑。

#### `createResolveInvocationArgumentsPass`

沿着执行结构做一遍静态遍历，把 `create_invocation` 和 `wait_program` 需要的 code section 地址、
参数地址以及返回 buffer 地址回填进去。
之所以必须在这里做，是因为这些物理地址只有在 bufferization、outline 和地址分配之后才能确定。

#### `createConvertNssProgramToTorqHwPass`

把 `Executor::NSS` 的 program 降低到 `torq_hw`。
这个转换负责的是在 slice program 已经降低完成之后，对任务管理和执行编排层进一步做硬件化。

#### `createResolveAddressesPass`

解析硬件相关操作最终需要的数值地址，例如 DMA 配置、CDMA start 和 CSS start 所需的地址。
经过这一步后，带地址的硬件操作不再依赖符号级 memref value。

#### `createAssignObjectsIdentifiersPass`

为运行时和序列化使用的对象分配稳定 id，包括：

- 每个 NSS invocation 的 job id；
- 产生 memref 的操作对应的 buffer id；
- 运行时可见 action 的 action id。

#### `createProfilingPass`

在打开 `--torq-enable-profiling` 时启用。
它会附加 profiling 相关元数据和分析结果，包括 LRAM 使用、DMA 时间线、slice 时间线以及周期估算信息。

### Stage 3 技术说明

- 这一阶段标志着 backend 不再只是高层编译器，而是开始构造真正供 TORQ runtime 和硬件执行的 program。
- 地址分配和 invocation 参数解析被故意拆成两个 pass：前者负责存储地址，后者负责把这些地址投影到可执行 invocation 上。
- NSS outlining 中显式使用了 code section 双缓冲，这不是纯粹的 IR 变换细节，而是重要的执行工程实现。

## 重要 pipeline 选项

下面这些选项会实质性改变 pipeline：

| Option | Effect |
| --- | --- |
| `--torq-disable-slices` | 完全跳过 Slice 路径。 |
| `--torq-disable-css` | 禁用 CSS fallback。 |
| `--torq-disable-host` | 禁用 Host fallback。 |
| `--torq-from-prebufferized-ir` | 跳过正常输入场景下预期的早期 tensor-to-buffer 准备步骤。 |
| `--torq-enable-tile-and-fuse` | 在 Slice 路径中启用 tile-and-fuse 子流水线。 |
| `--torq-force-torq-hl-tiling` | 即便启用了 tile-and-fuse，也强制再执行一层 `torq_hl` 级 tiling。 |
| `--torq-disable-slicing` | 禁用多 slice 切分。 |
| `--torq-unroll-loop-after-bufferization` | 把 loop unroll 延后到 bufferization 之后。 |
| `--torq-disable-segmentation-fusion` | 跳过 segmentation 优化或融合。 |
| `--torq-enable-profiling` | 在最终阶段增加 profiling 信息。 |

## 关键技术点

### 1. Backend 天生是异构执行模型

这条 pipeline 并不是强行把所有计算都压到 NSS 上。
相反，它原生支持把不同计算协同降低到 Slice、CSS 和 Host 三条执行路径。

### 2. `torq_hl` 是核心语义枢纽

通用的 tensor 和 linalg IR 会被逐步重写为 `torq_hl`，
而 `torq_hl` 是整个 backend 面向硬件的统一高层表示。

### 3. Memory-aware tiling 是核心能力

pipeline 中存在多层 tiling，原因是 TORQ 执行强依赖于把工作集放进受限的片上内存，例如 LRAM 和 DTCM。

### 4. Kernel selection 是真正的 lowering 决策点

`createKernelSelectionPass` 不只是“选一个符号上的 kernel”。
它还会决定 vectorization mode，并驱动硬件所需的权重布局变换。

### 5. Slicing 是并行化机制，不是末端序列化技巧

Slicing pass 会显式把工作切分到多个硬件 slice 上。
后续 pass 再把这些 slice 结果 outline 并调度成真正可执行的单元。

### 6. Bufferization 是围绕 TORQ 内存空间定制的

这不是一个只做通用 bufferization 的 backend。
allocation、copy 和默认 memory-space 选择都绑定了 TORQ 自己的工具函数和规则。

### 7. Program 调用会被显式重写成运行时协议操作

`call_program` 会被改写成 invocation 创建、program 启动和等待。
这样执行依赖和运行时载荷会在 IR 中被显式表达出来。

### 8. 静态地址规划是 backend 的核心服务

backend 会在编译期完成内存地址分配，并在最终硬件 lowering 之前验证峰值内存占用。

### 9. 存在两层不同粒度的 outlining

Slice outlining 负责生成可执行 kernel program。
NSS outlining 负责生成负责任务编排、数据搬运和 program 装载的 task program。

### 10. 最终硬件 lowering 被拆成语义转换和地址解析两步

backend 会先把 `torq_hl` program 转换为 `torq_hw`，再解析最终数值地址和运行时对象 id，
以满足序列化和执行的需要。

## 总结

`TORQLowerExecutableTargetPass::runOnOperation` 是 TORQ executable lowering pipeline 的总调度入口。
整个实现围绕以下几部分展开：

- 一个通用的 IREE workgroup 分发步骤；
- 一条把 linalg/tensor IR 降低为面向 NPU 的 `torq_hl` kernel 的 Slice 路径；
- 一条负责为 CSS 和 Host 编译二进制的 CPU fallback 路径；
- 一条负责 bufferize、outline、地址分配、降低到 `torq_hw` 并补齐运行时元数据的 NSS 物化路径。

其中最重要的实现主题包括：异构执行、memory-aware tiling、通过 `torq_hl` 完成语义 lowering、
静态地址规划，以及把 executable program 与 invocation 显式化。
