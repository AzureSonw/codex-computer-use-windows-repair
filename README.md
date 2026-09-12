# Codex Computer Use Windows 临时修复工具

## English summary

This unofficial Windows workaround restores `cua_node` and the bundled Browser, Chrome, and Computer Use plugins from the healthy Microsoft Store Codex package already installed on the same machine. It never downloads or redistributes OpenAI binaries.

**v1.2.1 checks first.** Extract [the latest release ZIP](https://github.com/AzureSonw/codex-computer-use-windows-repair/releases/latest) and double-click `Run-Codex-Computer-Use-Repair.cmd`. The launcher checks the installed package identity/version, runtime directory hash, plugin resources, and local integrity. It invokes the repair PowerShell script only when needed. Healthy runs leave runtime, plugins, and configuration unchanged. The same ZIP can usually be reused after Codex updates.

Checks run **only when you run the CMD file**. There are no startup entries, scheduled tasks, background services, or automatic app launches. If repair is needed while ChatGPT/Codex is running, keep the CMD open and fully quit the app from the tray. This invocation waits up to 120 seconds and continues when blockers exit. v1.2.1 fixes unrelated Stream Deck Node processes falsely blocking repair when PowerShell cannot read their module paths. Existing backups and failed staging directories are retained. The original manual repair script remains available.

Verified with isolated behavior tests on Windows PowerShell 5.1 and PowerShell 7.x and clean isolated restoration of Codex `26.908.4834.0`. This workaround concerns [openai/codex#25220](https://github.com/openai/codex/issues/25220); unrelated Computer Use failures may require a different fix.

## 用法：双击 CMD，先检查，有问题才修复

1. 从 [Releases](https://github.com/AzureSonw/codex-computer-use-windows-repair/releases/latest) 下载 `Codex-Computer-Use-Repair-v1.2.1.zip`。
2. 解压到普通文件夹；不要在 ZIP 预览窗口中运行。
3. 双击 `Run-Codex-Computer-Use-Repair.cmd`。
4. 看到 `Healthy` 表示文件完整，无需修复；看到 `Repaired` 表示所需修复已完成。
5. 如果列出 `Blocking processes`，保持 CMD 窗口打开，从托盘完全退出 ChatGPT/Codex。工具在本次窗口内最多等待 120 秒，进程退出后继续修复。超时才显示 `Deferred`；可根据列出的 PID 在任务管理器核对残留进程，再重跑。修复完成后重新打开 Codex，新建任务测试 Computer Use。

**已经从托盘退出，却一直提示正在运行？** v1.2.0 可能把路径读不到的其他 Node 程序误判为 Codex，例如 Elgato Stream Deck。请换用 v1.2.1；它会使用 Windows 的有限权限进程路径查询来区分这些程序，不需要退出 Stream Deck。若路径仍确实无法确认，会显示具体 PID 和原因，保持安全停止，不会强制结束任何进程。

**Codex 更新后，通常只需再次运行同一份 CMD，无需重新下载修复工具。** 工具每次都重新发现本机最新的可信安装包，不会把 Codex 版本或插件版本写死。若未来官方改变资源布局或运行时命名规则，工具会停止并提供诊断，届时可能仍需要新版工具。

只在你运行 CMD 时检查。**没有开机检查、每 15 分钟检查、计划任务、常驻进程或自动启动 Codex。** 无需安装，也无需卸载服务；不再需要时删除解压的工具文件夹即可。已经修复的文件和备份会保留，回退方法见下文。

> [!WARNING]
> 这是社区临时解决方案，不是 OpenAI 官方修复。需要修复时会修改当前用户的 Codex 运行时、相关插件缓存及必要的 `config.toml` 条目。只支持 Windows 上通过 Microsoft Store/MSIX 安装的 Codex。

## 它检查什么

- **包身份和版本**：仅接受 `OpenAI.Codex_2p2nqsd0c76g0`，要求发布者 ID 正确、签名类型为 Store、状态正常；按数字版本选择当前用户安装的最新包。
- **运行时目录**：使用本机包的 `manifest.json`、`node.exe`、`node_repl.exe` 计算 Codex 使用的 16 位目录哈希。
- **资源变化**：比较完整源文件清单和内容指纹；插件版本号没变但内容变了，也能识别。
- **目标完整性**：检查文件路径、数量、大小和 SHA-256，涵盖运行时、bundled marketplace 及三个插件缓存。只恢复有差异的目录。
- **必要配置**：CMD 按需修复时保留已有的插件 `enabled = false` 选择，不会因为用户禁用插件而反复修复。仅相关配置不完整时更新，并保留无关条目。

首次检查计算所有文件的 SHA-256。后续用文件大小和 UTC 修改时间复用已验证哈希，每次仍重新枚举文件并校验关键文件哈希；距上次全量校验超过 24 小时，会在**下一次运行工具时**重新计算全部哈希。这不是后台定时任务。可用 `-FullCheck` 随时强制全量校验。

此缓存用于检测复制失败和普通文件损坏，不是对抗篡改的安全扫描。若非关键文件的内容、大小和修改时间被同时伪造，快速检查可能要到全量校验时才发现。

## 修复时的保护

- 只从本机已验证的官方安装包读取解密后的字节流，不修改 WindowsApps，不下载运行时，不上传个人数据。
- 支持 Microsoft Store 将注册的包目录链接到另一磁盘；拒绝资源树内部或修复目标中的目录链接，避免写出预期范围。
- 先复制到临时目录并校验，再备份、替换原目录。失败的临时目录会保留；替换失败且目标尚未生成时恢复旧目录。
- 检测 ChatGPT/Codex、Computer Use 相关进程及使用该运行时的 Node；读不到 Node 的常规路径时使用 Windows `QueryFullProcessImageName` 确认归属，排除 Stream Deck 等无关 Node。开始修复和每次正式替换前再次检查，不会强制关闭用户应用。
- 新建临时目录遇到短暂的访问/占用错误时，最多重试 1 秒，并在每次重试前检查应用进程；持续占用时仍停止并保留备份。
- 同一运行时目录使用独占检查锁，连续双击不会并行修复。检查脚本只会向修复脚本单向调用，不会递归启动。
- 恢复后执行 Node `--version` 自检，有 10 秒超时，失败时报告错误并保留已有备份。
- 同一资源连续失败后，按需模式第一次等待 1 小时、第二次等待 4 小时再允许重试，第三次暂停；只有你再次运行工具时才会尝试。更新后的新资源会重新计算重试状态；手动入口可在排查后立即重试。
- 若检测到上次修复被中断，按需模式暂停并提示查看日志、备份后运行手动入口。

请在需要修复时完全退出 Codex，并在工具结束前不要重新启动。Windows 没有为本工具提供原子化的“阻止应用启动并替换目录”接口；脚本通过重复进程检查和替换失败回退来处理竞争情况。

## 命令行与原有手动入口

需要 Windows PowerShell 5.1 或 PowerShell 7.x。CMD 优先使用 PowerShell 7，没有则使用 Windows PowerShell 5.1。执行策略 Bypass 只作用于该次子进程。

只检查并生成诊断，不修复 Codex：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\check-codex-computer-use.ps1 -CheckOnly
```

强制全量检查，有问题再修复：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\check-codex-computer-use.ps1 -FullCheck
```

需要修复时最多等待应用退出 60 秒，超时后退出；不启动后台等待：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\check-codex-computer-use.ps1 -WaitSeconds 60
```

**原有手动修复入口**，适合排查失败原因后立即重试。此入口会完整校验，并按原有行为重新启用三个插件、备份及更新相关配置：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\repair-codex-computer-use.ps1
```

脚本遵循 `CODEX_HOME` 环境变量；未设置时使用 `%USERPROFILE%\.codex`。运行时位于 `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node`。请预留至少 1 GB 空间，已有备份时可能需要更多。

## 诊断、退出码和备份

检查记录位于 `%LOCALAPPDATA%\OpenAI\Codex\computer-use-repair\`：

- `last-result.json`：本次状态、安装包版本、资源指纹、变化组件、备份路径、日志路径，以及 `BlockingProcesses` 中阻塞进程的名称、PID、路径和原因。
- `state.json`：完整性缓存、上次全量校验时间和失败重试状态。
- `logs\`：最近 20 次检查的日志。备份和失败临时目录不会随日志清理而删除。
- `check.lock`：进程运行时持有的独占锁；文件存在不代表工具常驻。

| 退出码 | 状态 | 下一步 |
| --- | --- | --- |
| 0 | Healthy / Repaired | 无需修复，或所需修复成功 |
| 2 | NeedsRepair | 只检查模式发现需要修复 |
| 10 | Deferred | 应用运行、包正在更新或另一检查持有锁；稍后手动重跑 |
| 11 | Cooldown | 失败后的重试冷却中；查看诊断 |
| 12 | Paused | 连续失败或上次修复被中断；查看诊断后使用手动入口 |
| 1 | Failed | 检查或修复失败；保留错误输出和备份 |

被替换目录备份为 `*.before-computer-use-repair-时间戳`；配置备份为 `config.toml.before-computer-use-repair-时间戳`。若失败后旧目录已自动恢复，其备份路径可能已移回原名，请结合日志判断。不同哈希的旧运行时也会保留。

回退时完全退出 Codex，将新生成的对应目录或配置移到别处，再把备份改回原名。多个组件分步替换，部分成功后失败时请按诊断中列出的组件回退。确认稳定后可自行整理备份、失败的 `.staging-*` 目录和旧运行时。不要把含个人配置的文件提交到 GitHub。

## 开发与验证

```text
Run-Codex-Computer-Use-Repair.cmd   # 双击：先检查
check-codex-computer-use.ps1        # 正常退出；需要时调用修复入口
repair-codex-computer-use.ps1       # 保留的手动/按需修复入口
Repair.Engine.ps1                  # 版本发现、检查流程、锁和诊断
Repair.Core.ps1                    # 文件校验、复制、备份和配置处理
tests/Test-Repair.ps1              # 不依赖 Pester 的隔离行为测试
tests/Test-Processes.ps1           # Stream Deck 误判和进程识别回归测试
tests/Test-InstalledPackage.ps1     # 本机官方包的隔离端到端验证
tools/New-ReleasePackage.ps1       # Release ZIP 和 SHA-256
```

运行隔离行为测试（不会改动真实 Codex 配置）：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\Test-Repair.ps1
pwsh.exe -NoLogo -NoProfile -File .\tests\Test-Repair.ps1
powershell.exe -NoLogo -NoProfile -File .\tests\Test-Processes.ps1
pwsh.exe -NoLogo -NoProfile -File .\tests\Test-Processes.ps1
```

用本机官方包验证完整检查 → 按需恢复 → 重复检查流程；所有恢复文件写入仓库的 `work/`：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\Test-InstalledPackage.ps1
```

底层 `-PackageRoot` 和 `-SkipProcessCheck` 仅可配合隔离 `-TestRoot` 使用，不能用于真实用户目录的修复。行为测试使用小型假资源和替代 Node 自检；官方包端到端测试则实际恢复文件并执行恢复出的 Node。

v1.2.0 在 Windows PowerShell 5.1 和 PowerShell 7.x 下均通过 40 项隔离行为断言及官方包端到端验证。本机 Codex `26.901.6511.0` x64：运行时 4,684 文件 / 337,646,562 字节，marketplace 849 文件 / 81,880,577 字节，Node `v24.19.0`。重复检查在本机隔离环境中，PowerShell 7 约 4–6 秒，5.1 约 13 秒；实际耗时取决于环境。旧版 v1.1.0 曾验证 `26.820.9563.0`；其他官方版本按本机内容动态检测，不保证未来布局始终兼容。

v1.2.1 针对 Codex `26.908.4834.0` x64 完成全新隔离恢复：运行时 4,123 文件 / 263,414,106 字节，marketplace 952 文件 / 82,779,095 字节，Node `v24.20.0`；重复检查未改动配置或新增备份。两个 PowerShell 版本均验证进程路径回退、Stream Deck 排除、真实运行时保留拦截，以及限时等待/超时诊断。

生成发布包：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\New-ReleasePackage.ps1
```

`dist/` 下生成 ZIP 和 `.sha256`。ZIP 使用明确的文件白名单，只包含原创工具脚本、CMD、README、CHANGELOG、VERSION 和许可证，不包含测试输出、官方运行时、插件源码、缓存或个人配置。

下载后可以核对校验值：

```powershell
(Get-FileHash .\Codex-Computer-Use-Repair-v1.2.1.zip -Algorithm SHA256).Hash
```

## License and disclaimer

原创脚本使用 [MIT License](LICENSE)。许可不适用于 OpenAI/Codex 软件、运行时或插件；这些内容不在本仓库中分发。项目与 OpenAI 无隶属或授权关系，使用者需自行评估此临时修复是否适用于自己的故障。
