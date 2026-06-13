# TileAndFusePass 技术文档

## 1. 技术背景与目标

TileAndFusePass 的目标是在 Linalg/TilingInterface 层对算子做 **内存约束驱动的切块（tile）**，并在同一循环内尽量融合 producer，减少中间张量峰值占用与搬运。该 pass 在 TORQ slice 路径中由 [TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp#L125-L132) 挂载，且仅在 `--torq-enable-tile-and-fuse` 打开时启用。

该 pass 不能被普通 folder 替代：

- 其核心决策依赖 `checkTileFitsInMemory`/`fitTileToMemory` 的内存估算与二分搜索，不是局部代数化简。
- 它需要按数据流后序顺序处理 `TilingInterface` op，避免 consumer 仍需切块时 producer 被提前处理。
- 它和 pattern fuse group（`torq-fuse-group*`）协同，要求“模式内算子一起融合”，这属于跨 op 的结构约束，不是单 op fold。

## 2. 技术架构

### 模块位置表

| 模块 | 位置 | 作用 |
| --- | --- | --- |
| Pass 源码 | [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L1-L991) | Tile/Fuse 主逻辑、内存拟合、融合控制。 |
| Pass 声明 | [Passes.td](../../compiler/torq/Codegen/Passes.td#L193-L204) | 注册 `torq-tile-and-fuse` 命令名与构造函数。 |
| Pass 头文件 | [Passes.h](../../compiler/torq/Codegen/Passes.h#L58-L60) | 暴露 `createTileAndFusePass()`。 |
| 流水线挂载 | [TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp#L125-L132) | 在 mark/tensor-to-linalg 之后执行 tile-and-fuse。 |
| fuse-group 工具声明 | [PatternUtils.h](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.h#L19-L155) | 声明 `TORQ_FUSE_GROUP*` 与判定/遍历 helper。 |
| fuse-group 工具实现 | [PatternUtils.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.cpp#L47-L313) | 定义 `isMarkedFuseGroup`、`isFuseGroupOutput` 等实现。 |
| fuse-group ID 赋值入口 | [Passes.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/Passes.cpp#L149-L164) | MarkPatterns pass 给 TilingInterface op 分配 UID。 |
| 硬件内存参数 | [TorqHw.h](../../compiler/torq/Utils/TorqHw.h#L24-L26) | 提供 `getAvailableMemoryForTiling()`。 |

### 组件图

```mermaid
flowchart TD
    A[TORQLowerExecutableTargetPass\n--torq-enable-tile-and-fuse] --> B[MarkPatternsForTileAndFusePass]
    B --> C[TensorToLinalgPass]
    C --> D[TileAndFusePass.runOnOperation]

    D --> E[orderTiOps: 数据流后序]
    E --> F[tileAndFuse(op)]
    F --> G[fitTileToMemory\ncheckTileFitsInMemory]
    G --> H[tileAndFuseToSize]
    H --> I[scf::tileConsumerAndFuseProducersUsingSCF]
    I --> J[applyTiledResults]

    K[PatternUtils\nTORQ_FUSE_GROUP / ID] --> F
    L[TorqHw.getAvailableMemoryForTiling] --> G
```

### 关键属性/约定

| 项目 | 说明 |
| --- | --- |
| `torq-fuse-group-id` | 模式主算子 UID，定义与使用见 [PatternUtils.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.cpp#L47-L48)、[Passes.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/Passes.cpp#L158-L163)。 |
| `torq-fuse-group` | 记录 op 所属 fuse group 数组属性，见 [PatternUtils.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.cpp#L150-L156)。 |
| `torq-tiling-dfs` | TileAndFuse 内部 DFS 访问标记，见 [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L87-L127)。 |
| `torq-tiling-fused` | 标记“已作为 producer 被融合”，避免再次作为 root tile，见 [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L633-L645)。 |
| pass 命令名 | `torq-tile-and-fuse`，见 [Passes.td](../../compiler/torq/Codegen/Passes.td#L193-L199)。 |
| 融合策略开关 | `--torq-tile-and-fuse-producers-fuse-mode`，见 [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L56-L77)。 |

## 3. 代码实现详细流程

### runOnOperation：后序收集并逐个处理

```cpp
void TileAndFusePass::runOnOperation() {
    auto funcOp = getOperation();
    MLIRContext *context = &getContext();

    SmallVector<Operation *> orderTi;
    orderTiOps(funcOp, orderTi);

    for (auto *op : orderTi) {
        tileAndFuse(context, op);
    }
}
```

- `orderTiOps` + `forwardDfs` 会沿 `result -> user` 方向做 DFS，并在回溯阶段把 op 追加到 `orderTi`；该顺序是当前实现用于避免重复处理的执行顺序，不等同于经典 dataflow 拓扑序。
- 这样当 producer 已在更下游 consumer 的 tiling loop 中被融合后，可通过 `torq-tiling-fused` 跳过重复处理。

### 核心重写：tileAndFuseToSize + SCF tile-and-fuse

```cpp
scf::SCFTileAndFuseOptions options{};
options.tilingOptions.setTileSizes(
    getAsIndexOpFoldResult(rewriter.getContext(), tileSizes));
options.setFusionControlFn([&](tensor::ExtractSliceOp candidateSliceOp,
                               OpResult producerOpResult,
                               bool isDestinationOperand) {
    switch (clTorqTileAndFuseProducersFuseMode.getValue()) {
    case TileAndFuseProducersFuseMode::MaxSize:
        return fuseControlMaxSize(...);
    case TileAndFuseProducersFuseMode::MaxProducers:
        return fuseControlMaxProducers(...);
    }
});
return scf::tileConsumerAndFuseProducersUsingSCF(rewriter, tilingInterfaceOp, options);
```

- 通过 `setFusionControlFn` 把“是否融合 producer”的策略下发给上游 SCF 通用实现。
- `MaxSize` 优先保证较大 tile；`MaxProducers` 优先融合更多 producer；另有 `OnlyPatterns/NoFuse`。

### 内存拟合：fitTileToMemory（二分搜索）

```cpp
auto tileFits = checkTileFitsInMemory(...);
if (*tileFits) {
    return false;
}

for (auto dim : tilingDimOrder) {
    int64_t size = *getConstantIntValue(sizes[dim]);
    if (size == 1) continue;
    sizes[dim] = one;
    ...
    while (maxFactor != minFactor + 1) {
        int64_t midFactor = midpoint(minFactor, maxFactor);
        sizes[dim] = rewriter.getIndexAttr(div_ceil(originalSizes[dim], midFactor));
        ...
    }
    return true;
}
```

- 先验证当前 tile 是否超内存。
- 若超限，则按 `tilingDimOrder` 在允许维度上做因子搜索，找到“最大可放入内存”的 tile。

### 依赖 Utils：fuse-group 相关判定

```cpp
bool isMarkedFuseGroup(Operation *op) {
    return (bool)op->getAttrOfType<ArrayAttr>(TORQ_FUSE_GROUP);
}

std::optional<int64_t> isFuseGroupOutput(Operation *op) {
    auto fuseGroupAttr = op->getAttrOfType<ArrayAttr>(TORQ_FUSE_GROUP);
    if (!fuseGroupAttr) return std::nullopt;
    ...
    return getConstantIntValue(intAttr);
}
```

- TileAndFuse 依赖这些 helper 判断：
  - 当前 op 是否属于某个 pattern fuse group；
  - 当前 op 是否为 group 的“底部输出 op”（仅该 op 驱动 tile）；
  - 如何找到 principal op 与其关键 operand。

## 4. 关键技术点

| 技术点 | 说明 |
| --- | --- |
| 后序处理避免冲突 | `orderTiOps` 先处理 consumer，减少 producer 重复 tile。 |
| 内存驱动 tile 搜索 | `checkTileFitsInMemory + fitTileToMemory` 组合实现容量约束。 |
| 融合策略可配置 | 通过 `--torq-tile-and-fuse-producers-fuse-mode` 切换融合偏好。 |
| fuse-group 约束保语义 | 对模式内 op 使用 group 属性保证“该融合的不被拆散”。 |
| 二次拟合机制 | `MaxProducers` 模式下先融合再复算 tile，避免 producer 加入后超内存。 |
| 结果回填与防重复 | `applyTiledResults` 替换 use-def 并写 `torq-tiling-fused`。 |

常见坑：

- 非 `TilingInterface` producer 不会进入融合。
- 对 fuse-group 只允许 bottom-most op 触发 tile，其他成员会被跳过。
- 迭代域尺寸必须可常量化，否则会直接报错退出。
- `NoFuse` 模式可能导致中间张量峰值升高，需结合模型与内存预算评估。

## 5. 示例展示

### Pass 前（真实输入片段）

以下片段来自 [add-int8_linalg_tiling.mlir](../../demo/mlir/add-int8_linalg_tiling.mlir#L10-L16)：

```mlir
module {
  func.func @main(%arg0: tensor<256x1024xi8>, %arg1: tensor<256x1024xi8>) -> (tensor<256x1024xi8>) {
    %136 = tosa.add %arg0, %arg1 : (tensor<256x1024xi8>, tensor<256x1024xi8>) -> tensor<256x1024xi8>
    return %136 : tensor<256x1024xi8>
  }
}
```

### Pass 后（典型输出结构）

```mlir
%init = tensor.empty() : tensor<256x1024xi8>
%c4 = arith.constant 4 : index
%tiled = scf.forall (%i) in (%c4) shared_outs(%out = %init) -> (tensor<256x1024xi8>) {
  %lhs = tensor.extract_slice %arg0[%i, 0] [64, 1024] [1, 1] : tensor<256x1024xi8> to tensor<64x1024xi8>
  %rhs = tensor.extract_slice %arg1[%i, 0] [64, 1024] [1, 1] : tensor<256x1024xi8> to tensor<64x1024xi8>
  %tile = tensor.extract_slice %out[%i, 0] [64, 1024] [1, 1] : tensor<256x1024xi8> to tensor<64x1024xi8>
  %sum = linalg.add ins(%lhs, %rhs : tensor<64x1024xi8>, tensor<64x1024xi8>) outs(%tile : tensor<64x1024xi8>) -> tensor<64x1024xi8>
  tensor.parallel_insert_slice %sum into %out[%i, 0] [64, 1024] [1, 1] : tensor<64x1024xi8> into tensor<256x1024xi8>
}
```

上例体现了 TileAndFuse 的核心形态：切出子块、在子块上计算、写回总输出；若存在可融合 producer，会被放入同一 tiled loop 体内。

### 可运行命令行

```bash
cd demo/mlir
torq-compile ./add-int8_linalg_tiling.mlir -o ./data.ignore/output.vmfb \
  --iree-input-type=linalg-torq \
  --torq-enable-tile-and-fuse \
  --mlir-print-ir-after-all \
  --dump-compilation-phases-to=data.ignore
```

也可参考 [tests/test_tile_and_fuse.py](../../tests/test_tile_and_fuse.py#L8-L23) 中的测试配置，它对 linalg/tosa/torch 样例统一追加 `--torq-enable-tile-and-fuse`。

## 6. 调试开关

| 开关/选项 | 位置 | 作用 |
| --- | --- | --- |
| `--torq-enable-tile-and-fuse` | [TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp#L71-L73) | 打开 tile-and-fuse 子流水线。 |
| `--torq-tile-and-fuse-producers-fuse-mode` | [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L56-L77) | 选择 producer 融合策略。 |
| `DEBUG_TYPE = "torq-tile-and-fuse"` | [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L46-L46) | 控制本 pass 的 LLVM debug 输出域。 |
| `-debug` | [demo/add/run.sh](../../demo/add/run.sh#L10-L10) | 打印 LLVM debug 日志（需编译时支持）。 |
| `--mlir-print-ir-after-all` | [demo/mlir/run_linalg_tiling.sh](../../demo/mlir/run_linalg_tiling.sh#L7-L9) | 打印全 pass IR 变化。 |
| `--dump-compilation-phases-to=<dir>` | [demo/mlir/run_linalg_tiling.sh](../../demo/mlir/run_linalg_tiling.sh#L7-L9) | 导出各阶段 IR 文件，便于离线比对。 |

## 7. 参考

- [TileAndFusePass.cpp](../../compiler/torq/Codegen/TileAndFusePass.cpp#L1-L991)
- [Passes.td](../../compiler/torq/Codegen/Passes.td#L193-L204)
- [Passes.h](../../compiler/torq/Codegen/Passes.h#L58-L60)
- [TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp#L71-L132)
- [PatternUtils.h](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.h#L19-L155)
- [PatternUtils.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/PatternUtils.cpp#L47-L313)
- [Passes.cpp](../../compiler/torq/Conversions/LinalgToTorqHL/Passes.cpp#L149-L164)
- [TorqHw.h](../../compiler/torq/Utils/TorqHw.h#L24-L26)
- [tests/test_tile_and_fuse.py](../../tests/test_tile_and_fuse.py#L8-L112)
- [add-int8_linalg_tiling.mlir](../../demo/mlir/add-int8_linalg_tiling.mlir#L10-L35)
- [super_tiling.md](../../doc/dev-manual/super_tiling.md#L1-L129)
