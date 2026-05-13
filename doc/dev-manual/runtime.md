# Runtime 技术文档（Torq HAL Driver）

## 1. 背景与目标

Torq runtime 以 IREE HAL 外部驱动的形式接入执行栈，目标是把编译产物中的 `torq-fb` 可执行数据在不同后端（sim/aws_fpga/soc_fpga/astra_machina）上统一执行。整体实现位于 `runtime/driver` 与 `runtime/torq_hw`：

- `runtime/driver`：实现 IREE HAL driver/device/command buffer/executable 等对象；
- `runtime/torq_hw`：抽象底层硬件访问（寄存器、XRAM/LRAM、启动/等待/结束、事件日志）。

## 2. 架构分层与关键模块

### 2.1 Driver 注册与创建

- `runtime/driver/registration/driver_module.c`
  - 向 IREE registry 注册 `torq` driver；
  - 创建默认参数、加载器（local loaders/plugins）和 heap allocator；
  - 调用 `iree_hal_torq_driver_create` 完成驱动实例化。
- `runtime/driver/torq_driver.c`
  - 维护 `identifier/default_params/loaders/device_allocator`；
  - `query_available_devices` 暴露默认设备 `default`；
  - `create_device_by_id` 创建 Torq device。

### 2.2 Device（HAL 设备语义）

- `runtime/driver/torq_device.c`
  - 维护 block pool、semaphore 共享状态、executable loaders；
  - 对外实现 HAL vtable（创建 command buffer、pipeline layout、event、semaphore、executable cache、queue execute/wait 等）；
  - `query_i64` 声明支持格式 `torq-fb` 与并发能力 `concurrency=1`（同步模型）。

### 2.3 Command Buffer（录制期即执行期）

- `runtime/driver/torq_command_buffer.c`
  - 内联同步 command buffer，特征是“记录时准备数据、dispatch 时直接执行”；
  - 维护 push constants、descriptor 映射后的扁平 binding 指针；
  - `dispatch` 最终调用 `iree_hal_torq_native_executable_run`。

### 2.4 Executable Cache 与 Executable

- `runtime/driver/nop_executable_cache.cc`
  - 只接受 `torq-fb`；
  - `prepare_executable` 创建 `iree_hal_torq_native_executable_t`。
- `runtime/driver/native_executable.cc`
  - 保存 flatbuffer program、pipeline layouts、常量；
  - 解析 `ExecutableDef`，搬运 code/bindings，驱动 `TorqHw` 执行 host actions；
  - 支持 profiling、host profiling、内存/IO/buffer dump、step-by-step 调试。

### 2.5 同步原语

- `runtime/driver/torq_semaphore.c`
  - 基于 `iree_notification_t + slim mutex` 实现单机同步 semaphore；
  - 提供 `multi_signal/multi_wait`；
  - wait mode 支持 `ALL/ANY`。
- `runtime/driver/torq_event.c`
  - event 为轻量对象，配合同步执行模型，屏障/事件操作大多 no-op。

### 2.6 硬件抽象层（TorqHw）

- `runtime/torq_hw/inc/TorqHw.h` + `runtime/torq_hw/src/TorqHw.cpp`
  - 定义统一硬件接口：`open/load/start/wait/end/release/close`、XRAM/LRAM 读写；
  - `newTorqHw` 根据 `--torq_hw_type` 选择具体实现；
  - `start/wait/end` 封装 NSS/CSS 寄存器控制与中断流程。

## 3. 运行时主流程（端到端）

1. **注册驱动**：`iree_hal_torq_driver_module_register` 注册 `torq`。
2. **创建设备**：driver 创建 device，device 创建 executable cache。
3. **加载可执行**：cache 验证 `torq-fb`，构造 `native_executable`。
4. **录制命令**：
   - push descriptor set：把 HAL buffer map 到 host 地址；
   - dispatch：生成 dense binding 列表并调用 native executable run。
5. **执行 native executable**：
   - 解析 `ExecutableDef`；
   - 计算 XRAM footprint（segment/binding/alloc 三类来源）；
   - 通过 `newTorqHw` 初始化对应硬件后端；
   - 把 code segment 写入 XRAM；
   - 把输入 bindings 从 host 同步到 XRAM；
   - 按 host actions 执行（HostCopy / StartNSS / WaitNSS / Alloc / Dealloc / StartHost / WaitHost）；
   - 执行结束后把输出 bindings 从 XRAM 同步回 host；
   - 释放并关闭硬件资源。
6. **队列语义**：
   - `queue_execute` 先 wait 输入 semaphores，再应用 deferred command buffers，最后 signal 输出 semaphores；
   - 当前为同步串行模型，dispatch/device 并发都声明为 1。

## 4. 数据与控制细节

### 4.1 Binding 同步

`sync_binding(...)` 会校验：

- binding id 在 `state->binding_count` 范围内；
- offset/size 不越界 `binding_lengths[bindingId]`；
- 根据读写属性避免无意义拷贝（只读/只写）。

数据路径：

- host -> XRAM：执行前导入输入；
- XRAM -> host：执行后导出输出。

可选地按 flag 生成二进制 IO dump 与 hex 描述文件。

### 4.2 Host Action 调度

`ExecutionContext::run()` 顺序遍历 `ExecutableDef_actions`，并由 `processAction` 分派：

- `HostCopy`：支持多维 shape/stride 递归拷贝；
- `StartNSS`：启动 NPU，可进入 step-by-step 模式；
- `WaitNSS`：等待完成并记录 profiling；
- `StartHost`：动态加载 host code 并执行导出函数；
- `Alloc/Dealloc`：记录语义并按配置清零内存。

### 4.3 调试与剖析能力（CLI flags）

核心 flags（定义在 `native_executable.cc`）：

- `--torq_debug` / `--torq_verbose`
- `--torq_profile`（NSS job 级 profiling CSV）
- `--torq_profile_host`（host action 事件日志）
- `--torq_dump_mem_data_dir` / `--torq_desc_data_dir`
- `--torq_dump_io_data_dir`
- `--torq_dump_buffers_dir`（按 action dump `.npy`）
- `--torq_step_by_step`
- `--torq_hw_type`
- `--torq_clear_memory`

## 5. 线程与同步模型

- command buffer 为 inline/synchronous；
- barrier/event 操作基本 no-op（依赖同步执行语义）；
- semaphore 用于跨提交顺序保证；
- collectives、indirect dispatch、execute_commands 目前未实现。

这意味着 runtime 当前优先强调“可控、可调试、确定性”，而不是高并行吞吐。

## 6. 常见问题定位建议

1. **执行失败（启动/等待失败）**
   - 开启 `--torq_debug`，查看 NSS/CSS 相关日志；
   - 使用 `--torq_step_by_step` 逐条指令推进。
2. **输出异常**
   - 开启 `--torq_dump_io_data_dir` 对比输入输出；
   - 开启 `--torq_dump_buffers_dir` 检查中间 buffer 时序；
   - 检查 `sync_binding` 越界错误信息。
3. **性能分析**
   - `--torq_profile` 关注 job 时间；
   - `--torq_profile_host` 观察 host action 开销与重叠关系。

## 7. 当前限制与后续扩展点

已知限制（代码中显式 `TODO/UNIMPLEMENTED`）：

- collectives 未实现；
- indirect dispatch 未实现；
- execute nested command buffers 未实现；
- profiling 接口在 device 侧为占位实现；
- 同步模型并发度固定为 1。

可优先扩展方向：

- 增加异步队列/多并发执行模型；
- 完善 device profiling 接口与统一事件模型；
- 对 host action 与 buffer dump 做更细粒度开关；
- 补齐 collectives/indirect dispatch 等 HAL 能力。
