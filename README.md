# Codex Computer Use Windows 临时修复工具

> [!WARNING]
> 这是社区提供的临时解决方案，不是 OpenAI 官方修复，也不代表 OpenAI。它会修改当前 Windows 用户的 Codex 运行时、插件缓存和 `config.toml`；运行前请先阅读本页并完全退出 Codex。

当 Windows 版 Codex 因 WindowsApps/EFS 复制错误而无法生成 `cua_node`，或 Browser、Chrome、Computer Use 内置插件不可用时，本工具会尝试从同一台电脑上已经安装的 Microsoft Store Codex 软件包恢复所需文件。

本仓库只包含可审阅的 PowerShell 脚本和 CMD 启动器，不包含、分发或重新打包任何 OpenAI 二进制文件、插件源码、缓存或用户配置。

当前稳定版为 **v1.0.0**。普通用户请从 GitHub Releases 下载单个 ZIP 包；仓库根目录保留原始脚本，方便审阅。

## 适用症状

- Computer Use、Browser 或 Chrome 插件显示不可用。
- `node_repl`、`cua_node` 或 `codex-computer-use.exe` 未生成到用户目录。
- Codex 安装包内存在完整运行时，但客户端无法把它复制出来。
- 日志中出现 WindowsApps、EFS、`copyfile`、`Access is denied` 等复制错误。

相关公开问题：[openai/codex#25220](https://github.com/openai/codex/issues/25220)。如果故障原因不同，这个工具可能没有效果。

## 它会做什么

- 只接受包身份为 `OpenAI.Codex_2p2nqsd0c76g0`、状态正常且签名类型为 Microsoft Store 的已安装 Codex 包。
- 通过解密后的字节流恢复官方 `cua_node` 运行时和 `openai-bundled` marketplace。
- 初始化 Browser、Chrome、Computer Use 的本地插件缓存。
- 修改前为现有目录和 `config.toml` 创建带时间戳的备份。
- 比较源和目标的文件结构、大小及关键文件 SHA-256，最后运行恢复出的 Node.js 执行 `--version` 自检。
- 在失败且正式目标尚未生成时，自动恢复刚刚移走的旧目录。

它不会从第三方站点下载运行时，不会修改受保护的 WindowsApps 安装包，也不会上传配置、屏幕内容或账号信息。脚本本身不发起网络请求。

## 使用前

- 仅支持 Windows 上通过 Microsoft Store/MSIX 安装的 Codex。
- 需要 Windows PowerShell 5.1 或 PowerShell 7.x。
- 建议预留至少 1 GB 可用空间；存在旧运行时并创建备份时可能需要更多。
- 必须完全退出 Codex，包括系统托盘和后台进程。脚本检测到 Codex 仍在运行时会停止。

## 使用方法

1. 在仓库的 [Releases](https://github.com/AzureSonw/codex-computer-use-windows-repair/releases) 页面下载 `Codex-Computer-Use-Repair-v1.0.0.zip`。
2. 解压 ZIP；不要直接在压缩包预览窗口中运行文件。
3. 完全退出 Codex。
4. 双击 `Run-Codex-Computer-Use-Repair.cmd`。
5. 等待窗口显示 `Repair completed successfully.`。
6. 重新打开 Codex，并新建一个任务测试 Computer Use。

ZIP 同时提供 `.sha256` 校验文件。可在 PowerShell 中核对下载内容：

```powershell
(Get-FileHash .\Codex-Computer-Use-Repair-v1.0.0.zip -Algorithm SHA256).Hash
```

输出应与 `.sha256` 文件中的哈希一致。

也可以手动运行：

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\repair-codex-computer-use.ps1
```

如果没有 PowerShell 7，启动器会自动使用 Windows PowerShell 5.1。`ExecutionPolicy Bypass` 仅作用于这一次子进程，不会永久修改系统执行策略。

## 仓库结构

```text
.
├── repair-codex-computer-use.ps1   # 实际修复逻辑
├── Run-Codex-Computer-Use-Repair.cmd # 双击启动器
├── VERSION                          # 当前发布版本
├── CHANGELOG.md                     # 版本变更记录
├── tools/New-ReleasePackage.ps1     # 可重复生成 Release ZIP
├── README.md
└── LICENSE
```

Release ZIP 只包含运行所需脚本、使用说明、版本文件和许可证；不会包含恢复出的运行时、插件缓存或个人配置。

维护者可从仓库根目录重复生成相同结构的发布包：

```powershell
pwsh -NoLogo -NoProfile -File .\tools\New-ReleasePackage.ps1
```

生成的 ZIP 和 `.sha256` 文件位于 `dist/`，该目录不会提交到仓库。

## 验证

修复完成后：

1. 重新启动 Codex。
2. 打开插件设置，确认 Browser、Chrome 和 Computer Use 是否恢复。
3. 新建任务，让 Codex 尝试列出窗口或应用程序。
4. 如果仍失败，请保留修复窗口输出，并查看最新 Codex 日志确认是否是另一类故障。

## 备份与回退

被替换的目录会改名为 `*.before-computer-use-repair-时间戳`，配置备份名为 `config.toml.before-computer-use-repair-时间戳`。具体路径会打印在修复窗口中，脚本不会删除这些备份。

如需回退：

1. 完全退出 Codex。
2. 把修复后生成的对应目录或 `config.toml` 移到别处。
3. 将控制台中记录的备份改回原名称。
4. 重新启动 Codex。

多次运行会保留多份备份，请在确认 Codex 稳定后自行整理；不要把包含个人配置的备份提交到 GitHub。

## 已验证环境

- 工具版本：`v1.0.0`。
- Codex Microsoft Store 包：`26.715.8383.0`，x64。
- Windows PowerShell 5.1 与 PowerShell 7.x。
- 全新隔离恢复：`cua_node` 3,558 个文件 / 287,463,111 字节；bundled marketplace 838 个文件 / 67,865,356 字节；恢复后的 Node.js `v24.14.0`。
- 含单引号的用户路径和重复运行场景。

其他 Codex 版本会根据本机包内容动态计算运行时目录名，但尚未逐一验证。

## 已知局限

- 这是针对特定复制故障的变通方案，不保证修复所有 Computer Use 问题。
- Codex 更新、重装或启动时可能覆盖恢复结果；更新后可再次运行以从最新本机包刷新文件。
- 本地 marketplace 快照来自运行脚本时的已安装 Codex 版本，长期不重跑可能变旧。
- 官方插件界面状态仍由 Codex 客户端控制，本工具无法保证界面立即刷新。
- 请勿运行来源不明、经过修改或附带预编译运行时的版本。

## English summary

This is an unofficial Windows workaround for Codex installations where an EFS/WindowsApps copy failure prevents `cua_node` or the bundled Browser, Chrome, and Computer Use plugins from initializing.

The script restores components only from the healthy Microsoft Store Codex package already installed on the same machine. It does not download, bundle, or redistribute OpenAI binaries. Existing runtime directories, plugin caches, and `config.toml` are backed up before replacement. Fully quit Codex before running the launcher.

Download the single `Codex-Computer-Use-Repair-v1.0.0.zip` asset from GitHub Releases, extract it, and double-click `Run-Codex-Computer-Use-Repair.cmd`. Verify the ZIP against the accompanying `.sha256` asset if desired.

This workaround is related to [openai/codex#25220](https://github.com/openai/codex/issues/25220). It may need to be rerun after Codex updates and will not fix unrelated Computer Use failures.

## License and disclaimer

本仓库中的原创脚本以 [MIT License](LICENSE) 发布。该许可不适用于 OpenAI/Codex 软件、运行时或插件；这些内容不在本仓库中分发。

使用本工具需要自行承担风险。项目与 OpenAI 无隶属或授权关系；OpenAI 与 Codex 是其各自权利人的商标。
