---
mode: agent
description: 为 torq-compiler 的某个 Pass 生成标准化中文技术文档
tools: ['search', 'editFiles']
---

# 任务

为 Pass `${input:passName:CompileTimeConstCompute}` 生成一份标准化的中文技术文档，
输出路径固定为：`demo/doc/${input:passSnake:compile_time_const_compute_pass}.md`。

若目标文件已存在，则**覆盖重写**；不要修改任何源码文件。

# 上下文

以下上下文必须全部读入后再动笔：

- Pass 源码：#file:compiler/torq/Codegen/${input:passName}Pass.cpp
- Pass 声明：#file:compiler/torq/Codegen/Passes.td
- Pass 头文件：#file:compiler/torq/Codegen/Passes.h
- 流水线挂载：#file:compiler/torq/Codegen/TORQLowerExecutableTargetPass.cpp
- 文档规范参考：#file:doc/dev-manual/add_pass.md
- 代码库全局检索：#codebase

若该 Pass 依赖 `compiler/torq/Utils/` 下的工具函数，使用 search 工具定位后在文档中
用相对 markdown 链接引用其文件与行号（例如 `[ExecutorAssignment.cpp](../../compiler/torq/Utils/ExecutorAssignment.cpp#L33-L38)`）。

# 产出章节（全部使用中文，严格按此顺序）

1. **技术背景与目标** —— 说明该 Pass 在整条编译流水线中的作用。
2. **技术架构**
   - 模块位置表（源码/声明/相关 Utils/挂载点，各自给 markdown 链接）。
   - 一张 mermaid `flowchart` 组件图，体现主要数据流。
   - 列出关键属性/约定（属性名、设置函数、判定函数）。
3. **代码实现详细流程**
   - 按 `runOnOperation` → 核心 `RewritePattern` → 依赖的 Utils 函数逐段讲解。
   - 核心技术点函数的代码要求按行分析代码，按照函数展开说明，注释写在函数内部。
   - 分析容易忽视的技术细节；
4. **关键技术点** —— 使用两列表格（技术点 / 说明）总结；并另起一个"常见坑"小列表。
5. **示例展示**
   - 给出 Pass 前 / 后的 MLIR 片段（优先从 `demo/mlir/` 或 `tests/` 中找真实样例）。
   - 样例需要覆盖核心技术点。
   - 给出可运行的命令行（`torq-compile-main` 或相应测试入口）。
6. **调试开关** —— 枚举该 Pass 支持的 `llvm::cl::opt`、`DEBUG_TYPE`、IR dump 选项。
7. **参考** —— 相关源文件、上游 IREE/MLIR 头文件的链接清单。

# 格式约束

- 所有仓库内文件引用一律使用 **相对 markdown 链接**，严禁把文件路径放入反引号。
- 代码块必须标注语言（`cpp` / `mlir` / `bash` / `mermaid`）。
- 不要使用 emoji。
- 禁止出现"本文档由 AI 生成"之类的元说明。
- 文档开头只写一级标题 `# <PassName> 技术文档`，不写日期、作者。

# 验收标准

- 目标 md 文件已落盘，且七个小节齐全、顺序正确。
- 文档中出现的每一个仓库内路径，都能在工作区中实际找到（使用 search 工具自检）。
- 没有修改 `demo/dev/${input:passSnake}.md` 以外的任何文件。
- 文档可用于后续代码生成。
