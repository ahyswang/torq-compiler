# VirtualMemory 技术文档

## 1. 技术背景

### 1.1 问题描述

在面向专用硬件（如 NPU/DSP）的编译器中，目标设备通常具有容量非常有限的本地存储器（如 LRAM — Local RAM）。编译期间，编译器会为每一个中间张量（tensor）分配缓冲区（buffer），但本地存储器的容量往往不足以同时容纳一个函数中所有活跃的缓冲区。

为了解决这一问题，Torq 编译器引入了**虚拟内存（Virtual Memory）**机制。该机制允许编译器在编译阶段像拥有"无限大"的本地存储器一样进行缓冲区分配（即虚拟分配），然后在后续的代码生成阶段，通过一个转换 pass 将虚拟缓冲区映射到有限大小的物理存储器上。当物理存储器空间不足时，系统会自动将最近最少使用（LRU）的缓冲区换出（swap out）到扩展存储器（XRAM），需要时再换回（swap in）。

### 1.2 硬件存储层次

Torq 编译器面向的硬件具有多级存储层次：

| 存储空间 | 枚举值 | 说明 |
|---------|--------|------|
| Host    | 5      | 主机端内存 |
| Itcm    | 4      | 指令紧耦合内存（Instruction TCM） |
| Dtcm    | 3      | 数据紧耦合内存（Data TCM） |
| Lram    | 2      | 本地 RAM，容量小、速度快 |
| Xram    | 1      | 扩展 RAM，容量大、速度较慢 |

虚拟内存系统主要管理 **LRAM** 和 **XRAM** 之间的数据交换：
- 当目标内存空间为 **LRAM** 时，换出目的地为 **XRAM**
- 当目标内存空间为 **XRAM** 时，换出目的地为 **LRAM**

### 1.3 核心概念

- **虚拟缓冲区（Virtual Buffer）**：编译器在 IR 中分配的逻辑缓冲区，假设存储空间无限。
- **物理缓冲区（Physical Buffer）**：实际映射到有限物理内存池（Pool）中的缓冲区，具有真实地址。
- **虚拟别名（Virtual Alias）**：对虚拟缓冲区（或其他别名）的引用视图（如 `memref.subview`），不占用额外物理空间。
- **换出（Swap Out）**：当物理内存不足时，将缓冲区数据复制到交换存储空间（XRAM/LRAM），释放物理内存。
- **换入（Swap In）**：需要访问已换出的缓冲区时，在物理内存中重新分配空间，并将数据从交换区复制回来。
- **固定（Pin）**：标记缓冲区不可被换出，用于保证操作执行期间操作数的可用性。
- **碎片整理（Defragment）**：将所有未固定的物理缓冲区换出再换入，以消除内存碎片。

---

## 2. 技术路线

### 2.1 整体架构

虚拟内存系统由以下核心类组成：

```
VirtualMemory（虚拟内存管理器）
├── VirtualObjects（虚拟对象管理）
│   ├── VirtualBuffer（虚拟缓冲区）
│   │   └── VirtualAlias（虚拟别名，可嵌套）
│   └── VirtualObject（抽象基类）
├── PhysicalMemory（物理内存管理）
│   ├── PhysicalBuffer（物理缓冲区）
│   ├── PhysicalAlias（物理别名）
│   └── PhysicalObject（抽象基类）
└── Pool（地址池，管理实际地址分配）
```

### 2.2 类层次结构

#### 物理对象层

```
PhysicalObject（抽象基类）
├── PhysicalBuffer  ── 持有真实物理地址，由 Pool 分配
└── PhysicalAlias   ── 指向父物理对象的别名视图
```

#### 虚拟对象层

```
VirtualObject（抽象基类）
├── VirtualBuffer  ── 代表一个独立的缓冲区分配
│   ├── 持有 PhysicalBuffer（已换入状态）
│   └── 持有 swappedOutValue（已换出状态）
└── VirtualAlias   ── 代表对缓冲区的别名引用
    └── 持有 PhysicalAlias（已换入状态）
```

### 2.3 核心算法流程

`convertVirtualToPhysicalMemRefs` 函数的执行流程如下：

1. **初始化**：创建 `VirtualMemory` 实例，遍历函数体中的所有操作。

2. **逐操作处理**：对每个操作按以下步骤处理：

   a. **特殊处理 `dealloc`**：直接释放对应虚拟缓冲区的物理内存。

   b. **特殊处理别名操作**（如 `subview`）：创建虚拟别名，不执行换入操作。

   c. **常规操作**：
      - 收集操作的 memref 操作数和结果
      - 固定（pin）已在物理内存中的操作数，防止被换出
      - 释放足够空间容纳需要换入的操作数和新结果
      - 换入（swap in）被换出的操作数
      - 为新结果分配物理缓冲区
      - 将操作的虚拟值替换为物理值

   d. **异步操作特殊处理**：
      - `StartProgramOp`：记录并保持操作数固定状态
      - `WaitProgramOp`：释放对应 `Start` 固定的操作数

### 2.4 内存分配策略

`Pool` 类实现了地址分配策略：
- 小对象（< `largeAllocSizeBytes`）从地址空间**低端**分配
- 大对象从地址空间**高端**分配
- 这种双向分配策略可减少内存碎片
- 所有分配按字（word）对齐

### 2.5 换出/换入机制

#### 换出流程
1. 在交换存储空间（XRAM）分配临时缓冲区
2. 使用 `torq_hl::StoreOp` 将数据从物理缓冲区复制到交换区
3. 使所有指向该物理缓冲区的别名失效
4. 释放物理缓冲区（`memref::DeallocOp` + Pool::free）
5. 记录换出值引用

#### 换入流程
1. 在目标内存空间分配新物理缓冲区（`memref::AllocOp`）
2. 使用 `torq_hl::LoadOp` 将数据从交换区复制到新缓冲区
3. 释放交换区临时缓冲区（`memref::DeallocOp`）
4. 在 Pool 中注册新物理缓冲区地址
5. 如果分配失败则尝试碎片整理后重试

---

## 3. 预期成果

### 3.1 功能目标

- 实现有限物理内存下的透明缓冲区管理
- 自动处理缓冲区的换入/换出
- 支持 LRU 策略的缓冲区置换
- 支持内存碎片整理
- 支持缓冲区固定（Pin）机制以保证操作执行正确性
- 支持异步操作（Start/Wait）期间的缓冲区生命周期管理

### 3.2 性能目标

- 最小化换出/换入次数（通过 LRU 策略）
- 最小化碎片整理次数（通过双向分配策略）
- 换出/换入操作使用高效的 `torq_hl::LoadOp` / `torq_hl::StoreOp`

### 3.3 输出

- 函数中所有目标内存空间的虚拟 memref 被替换为物理 memref
- 物理 memref 具有在 Pool 中分配的真实地址
- 必要时插入 Load/Store 操作进行数据搬移
- 打印统计信息（碎片整理次数、换出次数）

---

## 4. 代码详细实现

### 4.1 命令行选项与常量

```c++
// 启用后，为每个虚拟缓冲区在其定义操作上添加 ID 属性，用于调试追踪
static llvm::cl::opt<bool> clAnnotateVirtualBufferIds(
    "torq-vm-annotate-virtual-buffer-ids", ...);

// 启用后，在 pass 结束时输出统计信息（碎片整理次数、换出次数）
static llvm::cl::opt<bool> clPrintStatistics(
    "torq-vm-print-statistics", ...);

// 虚拟对象 ID 属性名
static const std::string VIRTUAL_OBJECT_ID_ATTR_NAME = "torq-virtual-buffer-id";
```

### 4.2 PhysicalObject 类（物理对象基类）

```c++
class PhysicalObject {
    Value value_;  // 物理内存中的 MLIR Value
public:
    // touch(): 更新该物理对象的最近使用时间戳（LRU 管理）
    virtual void touch() = 0;

    // vm(): 获取所属的 VirtualMemory 管理器
    VirtualMemory &vm();

    // isPinned(): 检查关联的虚拟对象是否被固定
    bool isPinned();

    // value(): 返回物理值
    Value value() const;

    // virtualObject(): 获取关联的虚拟对象
    virtual VirtualObject &virtualObject() = 0;
};
```

### 4.3 PhysicalBuffer 类（物理缓冲区）

```c++
class PhysicalBuffer : public PhysicalObject {
    VirtualBuffer &virtualBuffer_;  // 关联的虚拟缓冲区
    int address_;                   // Pool 分配的物理地址

public:
    // address(): 返回 Pool 中分配的物理地址
    int address() const;

    // size(): 返回缓冲区大小（委托给关联的 VirtualBuffer）
    int size();

    // touch(): 更新 LRU 时间戳
    // 实现：调用 vm().physicalMemory.touch(*this)
    virtual void touch() override;

    // 构造函数：需要物理 Value、关联的 VirtualBuffer、以及 Pool 分配的地址
    PhysicalBuffer(Value value, VirtualBuffer &virtualBuffer, int address);
};
```

### 4.4 PhysicalAlias 类（物理别名）

```c++
class PhysicalAlias : public PhysicalObject {
    VirtualAlias &virtualAlias_;  // 关联的虚拟别名

public:
    // parent(): 获取父物理对象
    // 实现：通过 virtualAlias_.parent().physicalObject() 获取
    PhysicalObject &parent();

    // touch(): 触摸父物理对象（LRU 传播到根缓冲区）
    // 实现：调用 parent().touch()
    virtual void touch() override;

    // 构造函数：需要别名 Value 和关联的 VirtualAlias
    PhysicalAlias(Value value, VirtualAlias &virtualAlias);
};
```

### 4.5 VirtualObject 类（虚拟对象基类）

```c++
class VirtualObject {
    int id_;            // 唯一标识符，由 VirtualMemory::getNextId() 分配
    VirtualMemory &vm_; // 所属虚拟内存管理器
    Value value_;       // 虚拟空间中的 MLIR Value
    int pinCount_{0};   // 固定计数器，> 0 时不可被换出
    SmallVector<std::unique_ptr<VirtualAlias>> aliases_; // 子别名列表

public:
    // root(): 获取根 VirtualBuffer（每个别名链最终指向一个 Buffer）
    virtual VirtualBuffer &root() = 0;

    // pin(): 递增固定计数，防止被换出
    virtual void pin() { pinCount_++; }

    // unpin(): 递减固定计数
    virtual void unpin() { pinCount_--; }

    // swapIn(): 将已换出的虚拟对象换入物理内存
    virtual FailureOr<PhysicalObject *>
    swapIn(IRRewriter &rewriter, Location loc, bool allowDefragment) = 0;

    // touch(): 更新关联物理对象的 LRU 时间戳
    void touch() { physicalObject().touch(); }

    // addAlias(): 为当前虚拟对象创建一个别名
    VirtualAlias &addAlias(Value virtualValue);

    // 构造函数：自动分配唯一 ID
    VirtualObject(VirtualMemory &vm, Value value);
};
```

### 4.6 VirtualBuffer 类（虚拟缓冲区）

```c++
class VirtualBuffer : public VirtualObject {
    int size_;                                    // 缓冲区大小（字节）
    std::optional<PhysicalBuffer *> maybePhysicalBuffer_; // 已换入时指向物理缓冲区
    Value swappedOutValue_;                       // 已换出时指向交换区的 Value

public:
    // initialize(): 初始化虚拟缓冲区
    // 步骤：
    //   1. 使用虚拟 Value 作为初始物理 Value
    //   2. 调用 PhysicalMemory::add() 在 Pool 中分配物理地址
    //   3. 保存返回的 PhysicalBuffer 指针
    LogicalResult initialize();

    // pin(): 固定缓冲区
    // 步骤：
    //   1. 如果当前 pinCount 为 0，则通知 PhysicalMemory 固定物理缓冲区
    //   2. 调用基类 pin() 递增计数
    virtual void pin() override;

    // unpin(): 解除固定
    // 步骤：
    //   1. 调用基类 unpin() 递减计数
    //   2. 如果 pinCount 变为 0，则通知 PhysicalMemory 解除固定
    virtual void unpin() override;

    // swapIn(): 换入操作
    // 步骤：
    //   1. 断言当前处于换出状态
    //   2. 创建 memref::AllocOp 分配新物理缓冲区
    //   3. 创建 torq_hl::LoadOp 从交换区加载数据
    //   4. 创建 memref::DeallocOp 释放交换区缓冲区
    //   5. 调用 PhysicalMemory::add() 注册新物理缓冲区
    //   6. 如果 add 失败（碎片导致），返回失败
    //   7. 更新 maybePhysicalBuffer_
    virtual FailureOr<PhysicalObject *>
    swapIn(IRRewriter &rewriter, Location loc, bool allowDefragment) override;

    // swapOut(): 换出操作
    // 步骤：
    //   1. 断言未换出且未固定
    //   2. 创建交换区类型（修改编码的内存空间）
    //   3. 创建 memref::AllocOp 在交换区分配缓冲区
    //   4. 创建 torq_hl::StoreOp 将数据存储到交换区
    //   5. 使所有子别名失效
    //   6. 创建 memref::DeallocOp 释放物理缓冲区
    //   7. 从 PhysicalMemory 中移除，重置 maybePhysicalBuffer_
    void swapOut(IRRewriter &rewriter, Location loc);

    // 构造函数：
    //   1. 通过 getEncodedTotalSizeBytes 计算缓冲区大小
    //   2. 可选地在定义操作上设置虚拟缓冲区 ID 属性
    VirtualBuffer(Value value, VirtualMemory &vm);
};
```

### 4.7 VirtualAlias 类（虚拟别名）

```c++
class VirtualAlias : public VirtualObject {
    std::optional<PhysicalAlias> maybePhysicalAlias; // 已换入时的物理别名
    VirtualObject &parent_;                          // 父虚拟对象
    OpOperand &parentOperand_;                       // 父操作数引用

public:
    // root(): 沿着父链递归到根 VirtualBuffer
    virtual VirtualBuffer &root() override { return parent().root(); }

    // pin()/unpin(): 递归固定/解固定父对象
    // 确保整个别名链（直到根 Buffer）都被正确固定
    virtual void pin() override {
        VirtualObject::pin();
        parent_.pin();
    }

    // invalidate(): 使当前物理别名失效
    // 步骤：
    //   1. 重置 maybePhysicalAlias 为 nullopt
    //   2. 递归使所有子别名失效
    void invalidate();

    // swapIn(): 换入别名
    // 步骤：
    //   1. 如果父对象已换出，先递归换入父对象
    //   2. 克隆定义该别名的操作
    //   3. 将克隆操作的输入操作数替换为父对象当前的物理值
    //   4. 创建 PhysicalAlias 指向克隆操作的结果
    virtual FailureOr<PhysicalObject *>
    swapIn(IRRewriter &rewriter, Location loc, bool allowDefragment) override;

    // 构造函数：
    //   1. 通过 getDerivedMemRefBase 获取父操作数
    //   2. 如果父对象已换入且物理值等于虚拟值，直接创建物理别名
    VirtualAlias(Value value, VirtualObject &parent, VirtualMemory &vm);
};
```

### 4.8 PhysicalMemory 类（物理内存管理器）

```c++
class PhysicalMemory {
    VirtualMemory &vm_;
    DenseMap<VirtualBuffer *, std::unique_ptr<PhysicalBuffer>> physicalBuffers_; // 活跃物理缓冲区
    SetVector<PhysicalBuffer *> lastUsedPhysicalBuffer_;                         // LRU 有序集合
    DenseMap<PhysicalBuffer *, int> pinnedBuffers_;                              // 固定缓冲区及计数
    int totalPinnedSize_ = 0;  // 已固定缓冲区总大小
    Pool &pool_;               // 地址分配池
    int defragCount_ = 0;     // 碎片整理次数
    int swapOutCount_ = 0;    // 换出次数

public:
    // pin(): 固定物理缓冲区
    // 步骤：
    //   1. 查询当前固定计数
    //   2. 如果从 0 变为 1，累加固定大小
    //   3. 递增固定计数
    void pin(PhysicalBuffer &object);

    // unpin(): 解除固定
    // 步骤：
    //   1. 如果固定计数从 1 变为 0，移除记录并减去大小
    //   2. 否则递减计数
    void unpin(PhysicalBuffer &object);

    // defragment(): 碎片整理
    // 步骤：
    //   1. 收集所有未固定的活跃缓冲区
    //   2. 按顺序将它们全部换出
    //   3. 再按顺序将它们全部换入
    //   4. 由于换出释放了空间，换入时可以紧凑排列
    //   5. 递增 defragCount_
    LogicalResult defragment(IRRewriter &rewriter, Location loc);

    // add(): 添加物理缓冲区
    // 步骤：
    //   1. 断言该 VirtualBuffer 尚无关联的物理缓冲区
    //   2. 断言总大小不超过 Pool 可用空间
    //   3. 调用 Pool::allocate() 获取地址
    //   4. 如果分配失败（碎片化）且允许碎片整理，则执行 defragment 后重试
    //   5. 创建 PhysicalBuffer 并加入 LRU 集合
    FailureOr<PhysicalBuffer *> add(VirtualBuffer &obj, Value value, bool allowDefragment);

    // remove(): 移除物理缓冲区
    // 步骤：
    //   1. 从 LRU 集合中移除
    //   2. 调用 Pool::free() 释放地址
    //   3. 从映射中移除
    void remove(VirtualBuffer &obj);

    // touch(): 更新 LRU 顺序
    // 步骤：
    //   1. 从 LRU 集合中移除
    //   2. 重新插入（移到末尾，表示最近使用）
    void touch(PhysicalBuffer &object);

    // freeSpace(): 释放指定大小的空间
    // 步骤：
    //   1. 从 LRU 集合的头部（最久未使用）开始遍历
    //   2. 跳过已固定的缓冲区
    //   3. 换出未固定的缓冲区直到满足空间需求
    //   4. 如果遍历完所有缓冲区仍不满足，返回失败
    LogicalResult freeSpace(int space, IRRewriter &rewriter, Location loc);
};
```

### 4.9 VirtualObjects 类（虚拟对象管理器）

```c++
class VirtualObjects {
    DenseMap<Value, std::unique_ptr<VirtualBuffer>> virtualBuffers_; // 虚拟缓冲区集合
    DenseMap<Value, VirtualObject *> virtualObjects_;                 // Value -> 虚拟对象映射
    VirtualMemory &vm_;

public:
    // addBuffer(): 添加虚拟缓冲区
    // 步骤：
    //   1. 创建 VirtualBuffer 并记录到 virtualBuffers_
    //   2. 调用 initialize() 在物理内存中分配初始物理缓冲区
    //   3. 如果初始化失败，移除记录并返回失败
    //   4. 将虚拟对象注册到 virtualObjects_ 映射
    LogicalResult addBuffer(Value value);

    // addAlias(): 添加虚拟别名
    // 步骤：
    //   1. 获取别名的基 memref 操作数
    //   2. 查找父虚拟对象
    //   3. 调用父对象的 addAlias() 创建别名
    //   4. 注册到 virtualObjects_ 映射
    void addAlias(Value value);

    // getVirtualObject(): 通过 Value 查找虚拟对象
    VirtualObject &getVirtualObject(Value virtualValue);

    // getVirtualBuffer(): 通过 Value 查找虚拟缓冲区
    VirtualBuffer &getVirtualBuffer(Value virtualValue);

    // getPhysicalValue(): 获取虚拟值对应的当前物理值
    Value getPhysicalValue(Value virtualValue);
};
```

### 4.10 VirtualMemory 类（虚拟内存管理器）

```c++
class VirtualMemory {
public:
    VirtualObjects virtualObjects;     // 虚拟对象管理器
    PhysicalMemory physicalMemory;     // 物理内存管理器
    const torq_hl::MemorySpace memorySpace;   // 目标内存空间
    const torq_hl::MemorySpace swapMemSpace;  // 交换内存空间

    // 构造函数：
    //   memorySpace=Lram 时, swapMemSpace=Xram
    //   memorySpace=Xram 时, swapMemSpace=Lram
    VirtualMemory(Pool &pool, torq_hl::MemorySpace memorySpace);

    // getNextId(): 分配全局递增的唯一 ID
    int getNextId();

    // deallocate(): 释放虚拟缓冲区
    // 步骤：
    //   1. 查找对应的 VirtualBuffer
    //   2. 如果已换出，返回 swappedOutValue（调用者负责释放交换区缓冲区）
    //   3. 如果未换出，获取物理值，从 PhysicalMemory 中移除，返回物理值
    Value deallocate(Value virtualValue);

    // addAlias(): 注册虚拟别名
    void addAlias(Value virtualValue);

    // addAllocation(): 注册新的虚拟缓冲区分配
    LogicalResult addAllocation(Value virtualValue);

    // touch(): 更新虚拟值的使用时间戳
    void touch(Value virtualValue);

    // swapIn(): 换入虚拟值
    FailureOr<Value> swapIn(Value virtualValue, IRRewriter &rewriter, Location loc);

    // freeSpace(): 释放指定大小的物理内存空间
    LogicalResult freeSpace(int space, IRRewriter &rewriter, Location loc);

    // isSwappedOut(): 检查虚拟值是否已被换出
    bool isSwappedOut(Value virtualValue);

    // getPhysicalValue(): 获取虚拟值当前对应的物理值
    Value getPhysicalValue(Value virtualValue);

    // pin()/unpin(): 固定/解除固定虚拟值
    void pin(Value virtualValue);
    void unpin(Value virtualValue);
};
```

### 4.11 convertVirtualToPhysicalMemRefs 函数（入口函数）

```c++
LogicalResult convertVirtualToPhysicalMemRefs(
    FunctionOpInterface funcOp, Pool &pool, torq_hl::MemorySpace memorySpace
) {
    // 步骤 1：创建 VirtualMemory 实例和 IR Rewriter
    VirtualMemory vm(pool, memorySpace);
    IRRewriter rewriter(funcOp);

    // 步骤 2：收集函数体中所有需要处理的操作
    SmallVector<Operation *> ops;
    for (auto &op : funcOp.getFunctionBody().getOps()) {
        ops.push_back(&op);
    }

    // 步骤 3：创建映射表，跟踪 StartProgramOp 固定的虚拟值
    DenseMap<Value, SmallVector<Value>> invocationToVirtual;

    // 步骤 4：逐操作处理
    for (auto op : ops) {

        // 4a. 特殊处理 memref::DeallocOp
        //     - 检查操作数是否属于目标内存空间
        //     - 调用 vm.deallocate() 获取物理值
        //     - 更新 dealloc 操作指向物理值
        if (auto deallocOp = dyn_cast<memref::DeallocOp>(op)) {
            ...
        }

        // 4b. 特殊处理别名操作（如 subview、reshape）
        //     - 检查基 memref 是否属于目标内存空间
        //     - 调用 vm.addAlias() 注册虚拟别名
        //     - 不执行换入操作（延迟到实际使用时）
        if (isDerivedMemRefOperation(op)) {
            ...
        }

        // 4c. 常规操作处理
        //     步骤 c1: 收集属于目标内存空间的 memref 操作数
        //     步骤 c2: 收集属于目标内存空间的 memref 结果及总大小
        //     步骤 c3: 区分已换入和已换出的操作数
        //              - 已换入的操作数立即固定（pin），防止后续释放空间时被换出
        //              - 已换出的操作数加入待换入集合
        //     步骤 c4: 计算需要换入的操作数总大小
        //     步骤 c5: 设置 IR 插入点
        //     步骤 c6: 调用 vm.freeSpace() 释放空间
        //              - 空间需求 = 换入操作数大小 + 新结果大小
        //              - 失败则报错
        //     步骤 c7: 解除所有已固定操作数的固定状态
        //     步骤 c8: 换入所有已换出的操作数
        //     步骤 c9: 为所有 memref 结果分配物理缓冲区
        //     步骤 c10: 固定所有 memref 操作数，并将虚拟值替换为物理值
        //     步骤 c11: 处理异步操作
        //              - StartProgramOp: 保存固定的虚拟值到 invocationToVirtual
        //              - WaitProgramOp: 释放对应 Start 固定的虚拟值
        //              - 其他操作: 立即解除固定
    }

    // 步骤 5：输出统计信息（碎片整理次数、换出次数）
    if (clPrintStatistics) {
        ...
    }

    return success();
}
```

---

## 5. Draw.io 架构示意图

架构示意图文件位于 `doc/dev-manual/virtual_memory_architecture.drawio`，包含以下内容：

- **类层次结构图**：展示 VirtualObject / PhysicalObject 的继承关系和关联关系
- **状态转换图**：展示虚拟缓冲区在 SwappedIn / SwappedOut 之间的状态转换
- **核心流程图**：展示 `convertVirtualToPhysicalMemRefs` 的操作处理流程

---

## 6. 附录

### 6.1 关键依赖函数

| 函数 | 来源 | 说明 |
|------|------|------|
| `getEncodedTotalSizeBytes(ShapedType)` | EncodingUtils | 计算缓冲区在物理内存中的总大小（含 padding） |
| `getEncoding(ShapedType)` | EncodingUtils | 获取张量编码属性 |
| `cloneEncodingWithNewMemorySpace(...)` | EncodingUtils | 克隆编码并修改内存空间 |
| `createMemRefTypeWithEncoding(...)` | EncodingUtils | 创建带指定编码的 MemRefType |
| `isDerivedMemRefOperation(Operation*)` | MemoryUtils | 判断操作是否创建 memref 别名 |
| `getDerivedMemRefBase(Operation*)` | MemoryUtils | 获取别名操作的基 memref 操作数 |
| `getEncodingMemorySpace(ShapedType)` | MemoryUtils | 获取 memref 的内存空间枚举 |
| `Pool::allocate(Value)` | Pool | 在地址池中分配物理地址 |
| `Pool::free(Value)` | Pool | 释放地址池中的物理地址 |

### 6.2 调试方法

使用以下命令行选项启用调试输出：

```bash
# 启用虚拟内存调试日志
--debug-only=torq-virtual-memory

# 启用虚拟缓冲区 ID 标注
--torq-vm-annotate-virtual-buffer-ids

# 打印统计信息
--torq-vm-print-statistics

# 启用 Pool 调试日志
--debug-only=torq-pool
```
