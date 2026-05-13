# OutlineSliceProgramsPass 技术文档

## 1. 技术背景与目标

OutlineSliceProgramsPass（源码实现类为 OutlineSliceTasksPass）负责把函数体中适合在 Slice 上执行的算子外提为独立的 `torq_hl.program`，并在原位置生成 `create_invocation`、`start_program`、`wait_program` 这一套显式执行边界。

它位于可执行目标的 slice lowering 路径中，挂载在 `TORQLowerExecutableTargetPass` 的 slice 子流水线里，紧跟 slicing 之后、在最终的 fold/常量计算之前运行。它不是普通的 canonicalize/folder，因为它同时重构了控制流、代码段驻留位置和硬件调度信息：

- 把一个内联算子改写成 Program + Invocation 双层结构。
- 把 code section 从默认结果搬运到 LRAM 执行区。
- 对 `scf.forall` 做面向 Slice 并行语义的定制展开。
- 扫描 `start_program` / `wait_program` 生命周期并分配 `executor_id`。

从流水线语义上看，这个 Pass 是 Slice 程序“显式化”的分界点。在它之前，IR 里仍是内联的 torq_hl 计算 op 和 scf.forall；在它之后，IR 已经具备后续 [../../compiler/torq/Codegen/OutlineNSSProgramsPass.cpp](../../compiler/torq/Codegen/OutlineNSSProgramsPass.cpp) 与 [../../compiler/torq/Codegen/ResolveInvocationArgumentsPass.cpp](../../compiler/torq/Codegen/ResolveInvocationArgumentsPass.cpp) 所依赖的 program、invocation 与 executor_id 约定。

## 2. 技术架构

### 模块位置表

| 角色 | 文件 |
| --- | --- |
| Pass 源码 | [../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp) |
| Pass 声明 | [../../compiler/torq/Codegen/Passes.td](../../compiler/torq/Codegen/Passes.td#L85-L90) |
| Pass 头文件 | [../../compiler/torq/Codegen/Passes.h](../../compiler/torq/Codegen/Passes.h#L28-L33) |
| 流水线挂载点 | [../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp#L278-L278) |
| 文档规范参考 | [../../doc/dev-manual/add_pass.md](../../doc/dev-manual/add_pass.md) |
| 依赖 Utils：编码构造 | [../../compiler/torq/Utils/EncodingUtils.h](../../compiler/torq/Utils/EncodingUtils.h#L83-L92) / [../../compiler/torq/Utils/EncodingUtils.cpp](../../compiler/torq/Utils/EncodingUtils.cpp#L425-L429) |
| 依赖 Codegen 工具：copy 生成 | [../../compiler/torq/Codegen/BufferizationUtils.h](../../compiler/torq/Codegen/BufferizationUtils.h#L9-L22) / [../../compiler/torq/Codegen/BufferizationUtils.cpp](../../compiler/torq/Codegen/BufferizationUtils.cpp#L263-L289) |
| 硬件 slice 数量来源 | [../../compiler/torq/Dialect/TorqHW/TorqHWInfo.h](../../compiler/torq/Dialect/TorqHW/TorqHWInfo.h#L23-L33) |

### 组件图

```mermaid
flowchart TD
    A[func.func 内的 DestinationStyleOp / scf.forall] --> B[outlineSlicePrograms]
    B --> C[outlineOp: 生成 torq_hl.program]
    C --> D[CreateInvocationOp + code section]
    D --> E[createDenseEncoding(..., Lram)]
    E --> F[createTorqCopy: XRAM-backed code -> LRAM]
    F --> G[start_program / wait_program]
    G --> H[unrollLoops: ForallOpPattern]
    H --> I[scheduleSliceTasks]
    I --> J[写入 executor_id]
    J --> K[后续 AssignAddresses / TorqHW 序列化]
```

### 关键属性与约定

| 属性或约定 | 设置函数 / 位置 | 判定函数 / 消费位置 |
| --- | --- | --- |
| Program 执行器 | `torq_hl::ProgramType::get(ctx, torq_hl::Executor::Slice)`，[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L112-L118) | `torq_hl::InvocationType::get(..., torq_hl::Executor::Slice)` 和后续 slice lowering |
| program 命名规则 | `slice_program_<opName>_<idx>`，[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L114-L118) | `CreateInvocationOp` 的 name 参数 |
| 代码段大小 | `size = 0xA00 * 2`，[OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L107-L110) | 需要和后续 code section 预估保持一致 |
| code section 目标编码 | `createDenseEncoding(programSectionType, torq_hl::MemorySpace::Lram)`，[OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L146-L149) | `createTorqCopy` 的目标 memref 编码 |
| forall 展开前提 | `getStaticUpperBound()` 只有 1 维静态上界，[OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L46-L48) | `ForallOpPattern` 内部 `assert` |
| executor_id | `invocationOp.setExecutorId(APInt(64, availableSlice))`，[OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L231-L244) | `invocationOp.getExecutorId()` / 序列化阶段 |
| slice 数量 | `HwInfo::slice_count`，[TorqHWInfo.h](../../compiler/torq/Dialect/TorqHW/TorqHWInfo.h#L31-L31) | `scheduleSliceTasks(..., HwInfo::slice_count)` |

## 3. 代码实现详细流程

### 3.1 `runOnOperation()` 主流程

```cpp
void OutlineSliceTasksPass::runOnOperation() {
    outlineSlicePrograms(getOperation());

    if (failed(unrollLoops(getOperation()))) {
        return signalPassFailure();
    }

    if (failed(scheduleSliceTasks(
            getOperation().getFunctionBody(), torq_hl::Executor::Slice, HwInfo::slice_count
        ))) {
        return signalPassFailure();
    }
}
```

这三个步骤的顺序是控制语义的核心：先外提可执行算子，再把 `scf.forall` 变成可线性调度的形式，最后给每个 `start_program` 绑定 slice executor。这里的失败返回不是“容错”，而是在 IR 结构不满足 slice 执行约束时直接中止整个 pass。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L275-L291)

### 3.2 核心 `RewritePattern`：`ForallOpPattern`

```cpp
llvm::ArrayRef<int64_t> upper = forallOp.getStaticUpperBound();
assert(upper.size() == 1 && "expected single static upper bound in forall op");
auto unrollFactor = upper[0];

auto builder = OpBuilder(forallOp);

SmallVector<IRMapping> operandMaps(unrollFactor - 1);

if (!forallOp.getInductionVar(0).use_empty()) {
    for (unsigned i = 1; i < unrollFactor; i++) {
        Value ivUnroll =
            rewriter.create<arith::ConstantOp>(forallOp.getLoc(), rewriter.getIndexAttr(i));
        operandMaps[i - 1].map(forallOp.getInductionVar(0), ivUnroll);
    }
}
```

按行看，这段逻辑的重点只有两个：

- 只接受单维静态上界，因为后续复制逻辑直接把上界值作为展开因子。
- 如果归纳变量被使用，就给每个额外副本放一个 `arith.constant index`，再用 `IRMapping` 替换原来的 induction variable。

这一步相当于给后续克隆准备“迭代上下文”。如果 `scf.forall` 的上界不是静态单值，这个 pass 不能安全展开。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L27-L66)

### 3.3 分段克隆与循环去壳

```cpp
for (auto op : originalOps) {
    if (isa<torq_hl::WaitProgramOp>(op) || op->getBlock()->getTerminator() == op) {
        builder.setInsertionPoint(op);
        for (unsigned i = 1; i < unrollFactor; i++) {
            for (auto prevOp : operationsToClone) {
                builder.clone(*prevOp, operandMaps[i - 1]);
            }
        }
        operationsToClone.clear();
    }
    operationsToClone.push_back(op);
}

forallOp.setStaticUpperBound(1);
if (failed(forallOp.promoteIfSingleIteration(rewriter))) {
    assert(false && "Unrolling of scf.forall failed");
}
```

这段是这个 pass 最关键的控制流改写：

- 它把 `wait_program` 或 block terminator 当作一个“复制边界”。
- 在边界前累积的一段操作，会被复制 `unrollFactor - 1` 次，形成并行 Slice 的重复执行骨架。
- 复制完成后把 `scf.forall` 改成单次迭代，再用 `promoteIfSingleIteration` 直接去壳。

这不是普通 loop unroll，而是带有语义边界的“分段复制”，因为 `wait_program` 之后的同步必须留在最终位置。

这里有一个很容易看错的时序细节：`operationsToClone` 在“当前这次触发复制”时，并不包含当前遇到的 `wait_program`。原因是循环体的执行顺序是先判断当前 `op` 是否为 `wait_program` 或 terminator，如果是，就先把已有的 `operationsToClone` 整段 clone 出去，然后 `clear()`，最后才执行 `operationsToClone.push_back(op)`。因此：

- 当扫描第一次遇到 `wait_program` 时，被 clone 的只是它前面的那一段启动类操作，例如 `create_invocation`、搬运 code section、`start_program`。
- 当前这个 `wait_program` 会在本次 clone 结束后才进入 `operationsToClone`。
- 接下来如果后面还有 `store` 之类的尾部操作，它们会和这个 `wait_program` 一起累积到下一段。
- 直到扫描到 block terminator 时，这一段以 `wait_program` 开头的尾部操作才会被统一 clone 到 terminator 前。

因此最终效果不是“每复制一份就立刻补一个 wait”，而是把额外迭代的 `start_program` 尽量前移，把额外迭代的 `wait_program` 延后到 loop body 的后半段。对于典型的 `start_program -> wait_program -> store -> terminator` 结构，展开后的顺序更接近：先排开多份 `start_program`，再集中出现多份 `wait_program` 和它们后面的收尾操作。这个行为正是注释里所说“把 Wait 和 Store 移到 unrolled loop 末尾”的具体实现方式。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L75-L95)

### 3.4 `outlineOp()`：从内联算子到独立 program

```cpp
auto programType = torq_hl::ProgramType::get(ctx, torq_hl::Executor::Slice);
std::string programName =
    "slice_program_" + op->getName().getStringRef().str() + "_" + std::to_string(idx);
auto programOp =
    builder.create<torq_hl::ProgramOp>(loc, programType, builder.getStringAttr(programName));

Block &body = programOp.getBody().emplaceBlock();
builder.setInsertionPointToStart(&body);

IRMapping map;
for (auto operand : op->getOperands()) {
    map.map(operand, body.addArgument(operand.getType(), loc));
}

builder.clone(*op, map);
builder.create<torq_hl::ReturnOp>(loc, ValueRange{});
```

这部分把一个算子包进新的 `torq_hl.program`：

- `ProgramType::get(..., Slice)` 明确 program 面向 slice executor。
- program body 不允许直接捕获外部 SSA 值，所以要把原 op 的 operands 显式重建成 block arguments。
- `builder.clone(*op, map)` 把原始计算主体搬进新 program。
- `torq_hl.return` 让这个 program 成为一个结构完整、可被引用的符号体。

接下来这段负责把 program 变成可执行 invocation，并准备 LRAM code section：

```cpp
auto createInvocationOp = builder.create<torq_hl::CreateInvocationOp>(
    loc, TypeRange{invocationType, programSectionType}, programOp.getName(),
    programOp.getProgram(), nullptr, nullptr, nullptr, nullptr
);

auto programSectionLramCodeType = MemRefType::get(
    {size}, builder.getI8Type(), nullptr,
    createDenseEncoding(programSectionType, torq_hl::MemorySpace::Lram)
);
auto lramCodeSection =
    builder.create<memref::AllocOp>(loc, programSectionLramCodeType, nullptr);

if (failed(
        createTorqCopy(builder, loc, createInvocationOp.getCodeSections()[0], lramCodeSection)
    )) {
    llvm::report_fatal_error("failed to create copy to LRAM");
}
```

这里的技术点是“代码段搬运”而不是普通 memcpy：`createInvocationOp` 先生成 invocation 和默认代码段，再用 `createDenseEncoding(..., Lram)` 指定 LRAM 编码，最后通过 `createTorqCopy` 让 code section 在目标内存空间落地。

紧接着，函数还会创建 `torq_hl.start_program` 和 `torq_hl.wait_program`，然后删除原始内联 op。也就是说，外提后的 IR 在原位置只保留“调用边界”，真正的计算主体已经被封装进 program body。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L100-L169)

### 3.5 `outlineSlicePrograms()`、`unrollLoops()`、`scheduleSliceTasks()`

`outlineSlicePrograms()` 的作用是遍历函数体，把可外提的 slice 算子收集到 `toOutline`，再逐个调用 `outlineOp()`。它会显式跳过不该继续向下递归的情况，只在需要时进入 `scf.forall` 和嵌套 `func.func` 的区域，这样既能找到内部的 destination-style op，又不会把不相关的嵌套图误外提。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L172-L195)

`scheduleSliceTasks()` 扫描 region 中的 `start_program` / `wait_program`，维护一个 `sliceBusy` 位图：

- 遇到 `start_program`，先从它的 `invocation` 反查 `CreateInvocationOp`。
- 如果 invocation 还没有 `executor_id`，就找第一个空闲 slice 并写入。
- 如果已经有 `executor_id`，就把对应 slice 标记为忙。
- 遇到 `wait_program`，把对应 slice 释放。

这一步是后续串行化/硬件化能否正确生成 action 的前提，因为它把“程序启动”和“slice 资源占用”显式绑定起来。

代码位置：[../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L208-L262)

### 3.6 依赖的 Utils 函数

`createDenseEncoding()` 的实现非常直接：它用给定的 memory space 和 padding 构造一个 `torq_hl::TensorEncodingAttr`，并把自然布局的 dense strides 交给后续 memref 类型使用。

代码位置：[../../compiler/torq/Utils/EncodingUtils.cpp](../../compiler/torq/Utils/EncodingUtils.cpp#L425-L429)

`createTorqCopy()` 则根据源/目标 memref 的 encoding memory space 选择不同的拷贝语义：Lram->Xram 走 store，Xram->Lram 走 load，Lram->Lram 走显式 LRAM copy，其他情况退化到普通 `memref::CopyOp`。这个 pass 把代码段从默认结果搬到 LRAM，正是依赖了 Xram->Lram 的那条分支。

代码位置：[../../compiler/torq/Codegen/BufferizationUtils.cpp](../../compiler/torq/Codegen/BufferizationUtils.cpp#L263-L289)

## 4. 关键技术点

| 技术点 | 说明 |
| --- | --- |
| Program 外提 | 把目标算子复制到新的 `torq_hl.program` 中，断开与外层控制流的耦合。 |
| Invocation 化 | 原位置改写为 `create_invocation` + `start_program` + `wait_program`，执行边界显式化。 |
| 代码段搬运 | 通过 `createDenseEncoding(..., Lram)` 和 `createTorqCopy()` 把 code section 落到 LRAM。 |
| 分段展开 | `scf.forall` 按 `wait_program` / terminator 分段复制，保证同步点不被打散。 |
| 调度写回 | `scheduleSliceTasks()` 给 `CreateInvocationOp` 写 `executor_id`，供后续序列化使用。 |
| 硬件感知 | `HwInfo::slice_count` 直接决定可调度的 slice 数量上限。 |

### 常见坑

- `scf.forall` 只支持单维静态上界；动态或多维场景会触发断言。
- `size = 0xA00 * 2` 是硬编码的 code section 预估值，硬件配置变化时要同步检查。
- `scheduleSliceTasks()` 假设 `start_program` 和 `wait_program` 由同一个 `CreateInvocationOp` 产生，否则会报错。
- 如果 slice 数量配置和 IR 中的并发数不匹配，会出现“all slices busy”之类的调度失败。

## 5. 示例展示

样例输入来自 [../mlir/matmul_slice.mlir](../mlir/matmul_slice.mlir)，对应的编译日志在 [../mlir/data.ignore/log.txt](../mlir/data.ignore/log.txt#L7928-L7995) 中可以直接看到 `OutlineSliceTasks` 前后的差异。

### Pass 前（LowerCallProgramToStartWait 之后）

```mlir
func.func @main_dispatch_0_matmul_1x256x128_f16() {
  %0 = "torq_hl.const"() <{value = dense<1.000000e+00> : tensor<2x128x64xf16>}> : () -> memref<2x128x64xf16>
  %1 = "torq_hl.const"() <{value = dense<0.000000e+00> : tensor<256xf32>}> : () -> memref<256xf32>
  %2 = "torq_hl.map_binding"() <{binding_index = 0 : index, is_read_only = true, is_write_only = false, offset = 0 : index}> : () -> memref<1x128xf16>
  %3 = "torq_hl.map_binding"() <{binding_index = 1 : index, is_read_only = false, is_write_only = false, offset = 0 : index}> : () -> memref<1x256xf16>
  scf.forall (%arg0) in (2) {
    %alloc_2 = memref.alloc() : memref<1x128xf16, #torq_hl<enc mem_space = lram counts = [1, 128] strides = [128, 1]>>
    "torq_hl.fully_connected"(%alloc_2, %alloc_0, %alloc_1, %alloc) ...
    %subview = memref.subview %3[0, %arg0 * 128] [1, 128] [1, 1] : memref<1x256xf16> to memref<1x128xf16, strided<[256, 1], offset: ?>>
    torq_hl.store %alloc_2 : memref<1x128xf16, #torq_hl<enc mem_space = lram counts = [1, 128] strides = [128, 1]>> to %subview : memref<1x128xf16, strided<[256, 1], offset: ?>>
  } {mapping = []}
  return
}
```

### Pass 后（OutlineSliceTasks 之后）

```mlir
func.func @main_dispatch_0_matmul_1x256x128_f16() {
  %c128 = arith.constant 128 : index
  %c0 = arith.constant 0 : index
  %4 = torq_hl.program "slice_program_torq_hl.fully_connected_0" : !torq_hl.program<slice> {
    ^bb0(%arg0: memref<1x128xf16, #torq_hl<enc mem_space = lram counts = [1, 128] strides = [128, 1]>>, %arg1: memref<2x128x64xf16, #torq_hl<enc mem_space = lram>>, %arg2: memref<256xf32, #torq_hl<enc mem_space = lram>>, %arg3: memref<1x128xf16, #torq_hl<enc mem_space = lram>>):
      "torq_hl.fully_connected"(%arg0, %arg1, %arg2, %arg3) ...
      torq_hl.return
  }
  %invocation, %code_sections = torq_hl.create_invocation "slice_program_torq_hl.fully_connected_0" program(%4 : !torq_hl.program<slice>) on 0 : !torq_hl.invocation<slice>, memref<5120xi8>
  %alloc_3 = memref.alloc() : memref<5120xi8, #torq_hl<enc mem_space = lram>>
  torq_hl.load %code_sections : memref<5120xi8> to %alloc_3 : memref<5120xi8, #torq_hl<enc mem_space = lram>>
  torq_hl.start_program %invocation : !torq_hl.invocation<slice> args(...) code(%alloc_3 : memref<5120xi8, #torq_hl<enc mem_space = lram>>)
  %5 = torq_hl.program "slice_program_torq_hl.fully_connected_0" : !torq_hl.program<slice> {
    ^bb0(...)
    torq_hl.return
  }
  %invocation_7, %code_sections_8 = torq_hl.create_invocation "slice_program_torq_hl.fully_connected_0" program(%5 : !torq_hl.program<slice>) on 1 : !torq_hl.invocation<slice>, memref<5120xi8>
  torq_hl.start_program %invocation_7 : !torq_hl.invocation<slice> args(...) code(...)
  torq_hl.wait_program %invocation : !torq_hl.invocation<slice>
  torq_hl.wait_program %invocation_7 : !torq_hl.invocation<slice>
  return
}
```

这个样例覆盖了三个核心点：外提成 `torq_hl.program`、代码段搬到 LRAM、`scf.forall` 被展开为两个 slice 迭代并产生独立的 `start/wait` 对。

### 可运行命令行

```bash
cd demo/mlir
torq-compile ./matmul_slice.mlir -o ./data.ignore/output.vmfb \
  --mlir-print-ir-after=torq-outline-slice-tasks \
  --dump-compilation-phases-to=./data.ignore \
  > ./data.ignore/log.txt 2>&1
```

如果只想快速确认 pass 生效，也可以直接看 `OutlineSliceTasks` 的 IR dump，命令核心只需要保留 `--mlir-print-ir-after=torq-outline-slice-tasks`。

## 6. 调试开关

- `DEBUG_TYPE = "torq-outline-slice-tasks"`，定义在 [../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp#L23-L23)。
- 本 pass 文件里没有额外的 `llvm::cl::opt` 选项。
- IR dump 常用选项：`--mlir-print-ir-after=torq-outline-slice-tasks`、`--mlir-print-ir-after-all`、`--dump-compilation-phases-to=<dir>`。
- 由于当前文件没有 `LLVM_DEBUG` 输出点，`--debug-only=torq-outline-slice-tasks` 目前不会打印额外日志，但保留了标准 debug type 约定。

## 7. 参考

- [../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp](../../compiler/torq/Codegen/OutlineSliceProgramsPass.cpp)
- [../../compiler/torq/Codegen/Passes.td](../../compiler/torq/Codegen/Passes.td)
- [../../compiler/torq/Codegen/Passes.h](../../compiler/torq/Codegen/Passes.h)
- [../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp](../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp)
- [../../compiler/torq/Utils/EncodingUtils.h](../../compiler/torq/Utils/EncodingUtils.h)
- [../../compiler/torq/Utils/EncodingUtils.cpp](../../compiler/torq/Utils/EncodingUtils.cpp)
- [../../compiler/torq/Codegen/BufferizationUtils.h](../../compiler/torq/Codegen/BufferizationUtils.h)
- [../../compiler/torq/Codegen/BufferizationUtils.cpp](../../compiler/torq/Codegen/BufferizationUtils.cpp)
- [../../compiler/torq/Dialect/TorqHW/TorqHWInfo.h](../../compiler/torq/Dialect/TorqHW/TorqHWInfo.h)
- [../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Transforms/GreedyPatternRewriteDriver.h](../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Transforms/GreedyPatternRewriteDriver.h)
- [../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Dialect/SCF/IR/SCF.h](../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Dialect/SCF/IR/SCF.h)
- [../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Dialect/MemRef/IR/MemRef.h](../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Dialect/MemRef/IR/MemRef.h)
- [../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Interfaces/FunctionInterfaces.h](../../third_party/iree/third_party/llvm-project/mlir/include/mlir/Interfaces/FunctionInterfaces.h)
