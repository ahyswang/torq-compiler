下面给出在 VS Code 中配置 clangd 以获得 C/C++ 代码提示和补全的完整步骤。

## 一次性准备
1) 安装 VS Code 扩展  
   - 打开扩展市场搜索并安装 **clangd**（官方 clangd 插件）。  
   - 如果已安装 Microsoft 的 C/C++ 扩展（ms-vscode.cpptools），建议关闭其 IntelliSense 功能以避免冲突（见后文）。

2) 安装 clangd 可执行文件  
   - macOS：`brew install llvm`（clangd 位于 `/usr/local/opt/llvm/bin/clangd` 或 `/opt/homebrew/opt/llvm/bin/clangd`）。  
   - Ubuntu/Debian：`sudo apt-get install clangd`（或 `clangd-17` 等版本）。  
   - Windows：  
     - 安装 LLVM/Clang（官方安装包或 `winget install LLVM.LLVM`），记下 `clangd.exe` 路径；  
     - 若用 MSYS2，可 `pacman -S mingw-w64-ucrt-x86_64-clang-tools-extra`。

3) 在 VS Code 设置中指定 clangd 路径（如路径不在系统 PATH）  
   - `Ctrl/Cmd + ,` 搜索 `clangd: Path`，填入完整路径，如：  
     - macOS (Apple Silicon)：`/opt/homebrew/opt/llvm/bin/clangd`  
     - macOS (Intel)：`/usr/local/opt/llvm/bin/clangd`  
     - Linux：`/usr/bin/clangd` 或 `/usr/bin/clangd-17`  
     - Windows：`C:\\Program Files\\LLVM\\bin\\clangd.exe`

## 在项目中生成编译数据库 compile_commands.json
clangd 依赖编译数据库理解包含路径与编译参数。常见生成方式：
- **CMake**：配置时加 `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`，生成的 `compile_commands.json` 复制或链接到项目根目录。  
- **Ninja/其他构建**：使用 [bear](https://github.com/rizsotto/Bear) 包装一次构建，生成 `compile_commands.json`。示例：  
  - `bear -- make -j` 或 `bear -- ninja`。  
- **已有 JSON 不在根目录**：在项目根创建一个符号链接或拷贝 `compile_commands.json` 到根目录，或在 `.clangd` 里设置 `CompileFlags: CompilationDatabase: <path>`。

## 建议的 VS Code 设置（`settings.json`）
```json
{
  // 禁用 cpptools 的 IntelliSense，避免与 clangd 冲突
  "C_Cpp.intelliSenseEngine": "Disabled",

  // clangd 路径（可省略如果在 PATH 中）
  "clangd.path": "/usr/bin/clangd",

  // 常用 clangd 参数
  "clangd.arguments": [
    "--background-index",        // 后台全量索引
    "--clang-tidy",              // 启用 clang-tidy 诊断
    "--completion-style=detailed",
    "--header-insertion=iwyu",   // 智能补全自动插入需要的头
    "--cross-file-rename=true"   // 支持跨文件重命名
  ]
}
```

## 可选：.clangd 配置文件（放在项目根）
```
CompileFlags:
  CompilationDatabase: ./build   # 如果 compile_commands.json 在 build 目录
  Add: [-std=c++20]              # 额外编译标志

Diagnostics:
  ClangTidy:                    # 选择启用的 tidy 检查
    Add: [modernize-*, performance-*, bugprone-*]
    Remove: [modernize-use-trailing-return-type]
```

## 使用技巧与排错
- 确认 `compile_commands.json` 覆盖你要编辑的目标（含正确的 include 路径与宏定义）。  
- 在 VS Code 命令面板运行 **clangd: Restart Language Server** 以重启。  
- 若提示缺少头文件，确认编译命令中 `-I` 目录正确；可在 `.clangd` 用 `CompileFlags: Add: [-I/path]` 临时补充。  
- 若同时使用 cpptools 的调试功能，保持 IntelliSense 关掉即可，调试仍可用。  
- Windows 下路径和权限问题常见：确保 clangd 路径无空格或使用引号；若使用 WSL，直接在 WSL 环境中安装 clangd 并用 WSL 远程扩展。  

照此配置后，保存或编辑 C/C++ 文件即可获得 clangd 的补全、跳转、重命名和诊断。