---
mode: agent
description: 按 add_pass.md 规范为 torq-compiler 创建一个新 Pass 的完整骨架
tools: ['search', 'editFiles', 'runCommands']
---

# 任务

在 `compiler/torq/Codegen/` 下新增一个名为 `${input:passName:MyNew}` 的
`FunctionOpInterface` Pass，并完成全部注册步骤，保证工程能编译通过。

命令行标志（kebab-case）：`${input:passFlag:torq-my-new}`
构造函数：`mlir::syna::torq::create${input:passName}Pass()`

# 上下文

- 开发规范：#file:doc/dev-manual/add_pass.md
- Pass 声明文件：#file:compiler/torq/Codegen/Passes.td
- Pass 头文件：#file:compiler/torq/Codegen/Passes.h
- 构建清单：#file:compiler/torq/Codegen/CMakeLists.txt
- 流水线入口：#file:compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp
- 模板参考：#file:compiler/torq/Codegen/CompileTimeConstComputePass.cpp
- 代码库全局检索：#codebase

# 执行步骤（严格顺序，每一步完成后再进入下一步）

1. **Passes.td**：在现有条目间按字母序插入
   ```
   def ${input:passName}
       : InterfacePass<"${input:passFlag}", "mlir::FunctionOpInterface"> {
     let summary = "${input:passSummary:Describe what this pass does}";
     let constructor = "mlir::syna::torq::create${input:passName}Pass()";
     let dependentDialects = [
       "syna::torq_hl::TorqHLDialect"
     ];
   }
   ```
   如需更多方言，先 search 确认后再加入 `dependentDialects`。

2. **Passes.h**：添加声明
   ```cpp
   std::unique_ptr<InterfacePass<FunctionOpInterface>>
   create${input:passName}Pass();
   ```
   位置按字母序放入现有声明块。

3. **新建 `compiler/torq/Codegen/${input:passName}Pass.cpp`**：
   - 顶部包含 SPDX 头（复制自 `CompileTimeConstComputePass.cpp`）。
   - `#include "PassesDetail.h"` 及必要的方言头。
   - 使用 CRTP 继承 `${input:passName}Base<${input:passName}Pass>`。
   - 实现 `runOnOperation()`，先留 `// TODO` 占位，但必须能编译。
   - 实现 `create${input:passName}Pass()` 返回 `std::make_unique<...>()`。
   - 整个实现放在 `namespace mlir::syna::torq` 中。

4. **CMakeLists.txt**：在 `compiler/torq/Codegen/CMakeLists.txt` 的源文件列表里
   按字母序加入 `${input:passName}Pass.cpp`。

5. **挂载到流水线**：在 `TORQLowerExecutableTargetPass.cpp` 中找到合适的
   `funcPm.addPass(...)` 序列位置，插入
   `funcPm.addPass(create${input:passName}Pass());`。
   默认放在与模板 Pass 相邻的位置；如果不确定，就放在现有 pipeline 末尾，
   并在对话中说明选择理由。

6. **构建验证**：执行
   ```bash
   cmake --build build --target torq-compiler -j
   ```
   如果构建失败，根据报错修正第 1~5 步的内容，然后再次构建，直到成功。

# 约束

- 全部新增代码必须带 Apache-2.0 WITH LLVM-exception 的 SPDX 头。
- 不允许修改除上述 5 个文件及新建 .cpp 之外的任何文件。
- 不要引入多余的依赖方言；`dependentDialects` 只写真正用到的。
- 不要在本次任务里实现具体业务逻辑，`runOnOperation` 保持空壳 + TODO。

# 验收

- 新文件已创建并通过编译。
- `torq-compile-main --help 2>&1 | grep ${input:passFlag}` 能看到新 Pass。
- 运行 `git status` 只列出预期内的 6 个文件变更。
