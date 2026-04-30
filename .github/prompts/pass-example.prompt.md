---
agent: agent
description: 为 torq-compiler 的某个 Pass 分析代码并补一个可运行的示例 MLIR，覆盖关键功能点
tools: ['search', 'editFiles', 'runCommands']
---

# 任务

为 Pass `${input:passName:CompileTimeConstCompute}` 补一个可运行的示例，目标是：

1. 基于 Pass 实现分析其触发条件、改写目标、关键属性与依赖约束。
2. 在 `demo/mlir/` 下新增或重写示例文件 `demo/mlir/${input:exampleName:compile_time_const_compute}.mlir`。
3. 如仓库内没有可直接复用的运行入口，则新增或重写配套脚本 `demo/mlir/run_${input:exampleName:compile_time_const_compute}.sh`。
4. 运行最小验证命令，确认该示例至少能走通到目标 Pass 所在流水线，并覆盖该 Pass 的关键功能点。

不要修改与本示例无关的源码文件；若验证依赖本地构建产物或环境变量，在结果中明确说明前置条件。

# 上下文

以下上下文必须全部读入后再动笔：

- Pass 源码：先用 search 工具定位 `compiler/torq/Codegen/${input:passName}Pass.cpp`；若不存在，继续定位该 Pass 的实际实现文件
- Pass 声明：#file:../../compiler/torq/Codegen/Passes.td
- Pass 头文件：#file:../../compiler/torq/Codegen/Passes.h
- 流水线挂载：#file:../../compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp
- 开发规范：#file:../../doc/dev-manual/add_pass.md
- 示例参考：#file:../../demo/mlir/matmul_slice.mlir
- 运行脚本参考：#file:../../demo/mlir/run_slice.sh
- 代码库全局检索：#codebase

若该 Pass 依赖 `compiler/torq/Utils/` 下的工具函数，先用 search 工具定位实际调用点，再据此设计示例；不要凭名字猜测行为。

# 执行步骤（严格顺序）

1. **分析 Pass 触发面**
   - 定位 `runOnOperation`、核心 `RewritePattern`、辅助判定函数、依赖的 Utils。
   - 明确该 Pass 真正匹配的 op 形态、必要属性、禁止条件、是否依赖前序 Pass 打标。
   - 如果发现 `${input:passName}Pass.cpp` 不是主要实现入口，继续追到最近的实际控制点再继续。

2. **设计示例覆盖点**
   - 至少列出 3 个关键功能点，并据此设计示例 IR。
   - 优先覆盖：Pass 会命中的主路径、一个容易出错的边界条件、一个能从输出 IR 明确观察到的改写结果。
   - 若单个 `.mlir` 无法兼顾，可在同一文件中放多个 `module`，并用注释标出各自目标。

3. **编写示例 MLIR**
   - 优先复用 `demo/mlir/`、`demo/add/`、`tests/testdata/` 中已有写法和方言组合。
   - 示例应尽量最小化，但必须真实触发该 Pass；不要写只“看起来相关”却无法命中的 IR。
   - 在文件头部用简短注释说明每个片段覆盖的功能点与预期观察结果。

4. **编写运行入口**
   - 优先复用现有 `torq-compile` / `torq-compile-main` 调用方式。
   - 若新建脚本，脚本只做最小必要的环境设置、编译命令和输出目录准备；保持与仓库现有 demo 脚本风格一致。
   - 命令必须能让使用者观察到该 Pass 的效果：优先使用单 Pass 管线、IR dump、或 `--mlir-print-ir-after-all` 配合 grep。

5. **验证**
   - 实际运行最小命令验证示例。
   - 若全量编译链路依赖本地环境无法完成，至少验证输入文件、Pass 名称、命令行参数、输出目录和脚本语法无误，并在结果中说明未完成的外部依赖。
   - 若验证失败，先修正示例或脚本，再重复同一验证。

# 输出要求

完成修改后，在回复中按以下结构汇报：

1. 改动摘要：说明新增或修改了哪些示例文件，以及各自覆盖的功能点。
2. 设计依据：说明该示例为何能命中该 Pass，引用关键实现位置。
3. 运行方式：给出实际验证过的命令；如果有环境前置条件，单独写清楚。
4. 验证结果：说明命令是否成功，以及观察到的关键现象。
5. 风险与缺口：说明哪些功能点仍未覆盖，或哪些验证受本地环境限制。

# 约束

- 只允许修改示例相关文件；默认范围是 `demo/mlir/`，如确有必要写入 `tests/testdata/`，必须先说明理由并保持改动最小。
- 不要为了让示例通过而顺带修改 Pass 源码。
- 不要生成大而全的模型；示例优先“小而准”。
- 若需要引用仓库内路径，在回复中使用 markdown 文件链接。
- shell 脚本需可重复运行；若创建脚本，默认使用 bash。

# 验收标准

- `demo/mlir/${input:exampleName:compile_time_const_compute}.mlir` 已落盘，且内容能对上 Pass 的真实触发条件。
- 若新增脚本，脚本路径和命令均已验证到可执行或至少语法正确。
- 回复中明确列出“覆盖的关键功能点”与“未覆盖的点”。
- 没有修改与该示例无关的源码文件。