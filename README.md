# Codex Computer Use Windows 临时修复工具

## English summary

This unofficial Windows workaround restores `cua_node` and the bundled Browser, Chrome, and Computer Use plugins from the healthy Microsoft Store Codex package already installed on the same machine. It never downloads or redistributes OpenAI binaries.

**v1.3.0 checks resources and Chrome desktop integration.** Extract the release ZIP and double-click `Run-Codex-Computer-Use-Repair.cmd`. The launcher checks the trusted installed package, runtime, plugins, configuration, marketplace initialization, Chrome Native Messaging manifest/HKCU registration, bridge, `latest` junction and both v2 resource registrations. Missing registration can no longer be reported as healthy. Healthy runs preserve resources, integration files, configuration and backups; diagnostic logs/check state still update.

Checks run **only when you run the CMD file**. There are no startup entries, scheduled tasks, background services or periodic checks. If repair is needed, fully quit ChatGPT/Codex from the tray; the CMD waits up to 120 seconds. For incomplete Chrome integration, it prepares a verified decrypted resource view and opens the trusted desktop app once to run its own initialization. It waits up to another 120 seconds for valid registration. A timeout returns `Deferred`, never success. Unrelated Stream Deck/Node processes remain excluded; no user process is killed.

This addresses a diagnosed WindowsApps copy failure: the extension and desktop app are installed, but bundled marketplace initialization stops before Native Messaging registration, so the extension still asks to download the desktop app. It does not explain every Chrome connection failure. `Healthy` means verified local integration state, not a tested Chrome handshake. The initialization path is recognized from the installed package's implementation, not a public compatibility promise; unknown layouts fail closed. See the validation limits below.

## 用法：双击 CMD，先检查，有问题才修复

1. 从 [Releases](https://github.com/AzureSonw/codex-computer-use-windows-repair/releases) 下载 `Codex-Computer-Use-Repair-v1.3.0.zip`；若尚未发布该版本，可从源码运行下方打包命令。
2. 解压到普通文件夹；不要在 ZIP 预览窗口中运行。
3. 双击 `Run-Codex-Computer-Use-Repair.cmd`。
4. 看到 `Healthy` 表示资源与本地 Chrome 集成状态有效；`Repaired` 表示本次修复后校验通过。仍需在 Chrome 扩展中实际测试连接。
5. 如果列出 `Blocking processes`，保持 CMD 窗口打开，从托盘完全退出 ChatGPT/Codex。工具在本次窗口内最多等待 120 秒，进程退出后继续修复。超时才显示 `Deferred`；可根据列出的 PID 在任务管理器核对残留进程，再重跑。修复完成后重新打开 Codex，新建任务测试 Computer Use。

**已经从托盘退出，却一直提示正在运行？** v1.2.0 可能把路径读不到的其他 Node 程序误判为 Codex，例如 Elgato Stream Deck。v1.3.0 保留了 v1.2.1 的修正：使用 Windows 的有限权限进程路径查询来区分这些程序，不需要退出 Stream Deck。若路径仍确实无法确认，会显示具体 PID 和原因，保持安全停止，不会强制结束任何进程。

**Codex 更新后，通常只需再次运行同一份 CMD，无需重新下载修复工具。** 工具每次都重新发现本机最新的可信安装包，不会把 Codex 版本或插件版本写死。若未来官方改变资源布局或运行时命名规则，工具会停止并提供诊断，届时可能仍需要新版工具。

只在你运行 CMD 时检查。**没有开机检查、周期检查、计划任务或常驻修复服务。** 本次 CMD 仅在 Chrome 集成需要修复时启动一次官方 Codex，使用仅对子进程有效的资源路径变量，不设置永久环境变量。超时返回 `Deferred` 并保留备份；不会强制关闭应用。不再需要时可删除工具文件夹，已修复的资源和备份仍会保留。

**扩展一直提示下载桌面端？** 当 WindowsApps 普通文件复制失败时，资源可能部分恢复，但 marketplace 初始化标记、`latest`、v2 注册和 Native Messaging 尚未生成。v1.3.0 会检查这些缺失项。它先用解密字节流及 SHA-256 准备官方资源视图，再交给官方应用初始化，不猜测账号相关的 marketplace 标记，也不伪造在线进程信息。此问题以外的连接故障仍需单独诊断。

> [!WARNING]
> 这是社区临时解决方案，不是 OpenAI 官方修复。需要修复时会修改当前用户的 Codex 运行时、相关插件缓存及必要的 `config.toml` 条目。只支持 Windows 上通过 Microsoft Store/MSIX 安装的 Codex。

## 它检查什么

- **包身份和版本**：仅接受 `OpenAI.Codex_2p2nqsd0c76g0`，要求发布者 ID 正确、签名类型为 Store、状态正常；按数字版本选择当前用户安装的最新包。
- **运行时目录**：使用本机包的 `manifest.json`、`node.exe`、`node_repl.exe` 计算 Codex 使用的 16 位目录哈希。
- **资源变化**：比较完整源文件清单和内容指纹；插件版本号没变但内容变了，也能识别。
- **目标完整性**：检查文件路径、数量、大小和 SHA-256，涵盖运行时、bundled marketplace 及三个插件缓存。只恢复有差异的目录。
- **必要配置**：CMD 按需修复时保留已有的插件 `enabled = false` 选择，不会因为用户禁用插件而反复修复。仅相关配置不完整时更新，并保留无关条目。
- **Chrome 集成**：从可信包读取主机名、扩展 ID、桥接程序、版本与初始化格式；校验 manifest 的名称、stdio 类型、来源和路径，HKCU 默认值、当前 `latest` junction、两份 v2 的版本及可信可执行文件路径，以及 marketplace 标记和插件内容。只缺注册时，不重拷健康资源树。

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

请在需要修复时完全退出 Codex，并等待工具完成资源替换；需要 Chrome 初始化时由工具启动官方应用。Windows 没有为本工具提供原子化的“阻止应用启动并替换目录”接口；脚本通过重复进程检查和替换失败回退来处理竞争情况。

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

**原有手动修复入口**，适合排查失败原因后立即重试。此入口完整校验并保留插件启用偏好；健康状态同样不重复修复。使用 `-InitializeChrome` 才允许本次启动官方应用完成注册：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\repair-codex-computer-use.ps1 -InitializeChrome
```

脚本遵循 `CODEX_HOME` 环境变量；未设置时使用 `%USERPROFILE%\.codex`。运行时位于 `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node`。请预留至少 1 GB 空间，已有备份时可能需要更多。

PS1 不带 `-InitializeChrome` 时，仅准备缺失资源和解密视图；如果还需要桌面初始化，返回 `Deferred` 并说明下一步。`-InitializationSeconds 0..300` 控制手动入口的初始化等待时间。健康资源视图会复用；同卷优先复用哈希一致文件的硬链接，其他文件从可信包流式读取。

120 秒限制分别用于等待阻塞进程退出、等待桌面初始化完成，不包含资源复制及哈希校验。首次准备涉及数千个文件，可能耗时较长；资源视图准备期间每 500 个文件输出一次进度。

## 诊断、退出码和备份

检查记录位于 `%LOCALAPPDATA%\OpenAI\Codex\computer-use-repair\`：

- `last-result.json`：本次状态、安装包版本、资源指纹、变化组件、备份路径、日志路径，以及 `BlockingProcesses` 中阻塞进程的名称、PID、路径和原因。
- `state.json`：完整性缓存、上次全量校验时间和失败重试状态。
- `logs\`：最近 20 次检查的日志。备份和失败临时目录不会随日志清理而删除。
- `check.lock`：进程运行时持有的独占锁；文件存在不代表工具常驻。
- `ChromeIntegration`：`last-result.json` 中的集成状态、manifest、主机、HKCU 路径、桥接路径、扩展 ID 与具体问题。不会记录令牌或浏览器资料。
- `chrome.before-computer-use-repair-*`：启动官方初始化前保存 manifest、两份 v2、marketplace 标记/清单、HKCU 默认值及键是否存在、`latest` 目标。它是这些集成状态的备份，不是整个桌面应用的备份。
- `chrome-resources/`：供本次官方初始化读取的解密资源视图，仅保存在本机，不打包上传。

初始化启动失败时，在进程保护允许的情况下自动恢复集成快照。若应用仍在运行或等待超时，保留快照并返回诊断；完全退出应用后可以显式回滚：

```powershell
.\repair-codex-computer-use.ps1 -RestoreChromeBackup '诊断中给出的 chrome.before-computer-use-repair-* 完整路径'
```

回滚只写入该主机的 HKCU 默认值，保留其他主机和其他值；恢复前校验快照路径和文件哈希。成功返回 `Restored`，随后应运行只读检查。资源目录自身的备份仍按下方原有方式恢复。工具没有直接创建 Native Messaging 注册的兜底逻辑：当前优先让官方应用生成，无法验证时保留 `Deferred`。

| 退出码 | 状态 | 下一步 |
| --- | --- | --- |
| 0 | Healthy / Repaired / Restored | 本地状态有效、修复通过校验，或显式快照回滚完成 |
| 2 | NeedsRepair | 只检查模式发现需要修复 |
| 10 | Deferred | 进程/锁/更新阻塞，或仍需桌面初始化；按诊断处理后重跑 |
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
Repair.Chrome.ps1                  # Chrome 集成检查、官方初始化准备、快照回滚
tests/Test-Chrome.ps1              # 隔离 Chrome 故障和回滚测试
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
powershell.exe -NoLogo -NoProfile -File .\tests\Test-Chrome.ps1
pwsh.exe -NoLogo -NoProfile -File .\tests\Test-Chrome.ps1
```

用本机官方包验证完整检查 → 隔离资源恢复/解密视图 → 重复检查流程；所有恢复文件写入仓库的 `work/`。此测试不启动桌面端、不修改真实 Chrome 注册或 Codex 配置，因此 Chrome 初始化应明确保持 `Deferred`：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\Test-InstalledPackage.ps1
pwsh.exe -NoLogo -NoProfile -File .\tests\Test-InstalledPackage.ps1
```

底层 `-PackageRoot` 和 `-SkipProcessCheck` 仅可配合隔离 `-TestRoot` 使用，不能用于真实用户目录的修复。行为测试使用小型假资源和替代 Node 自检；官方包端到端测试则实际恢复文件并执行恢复出的 Node。

v1.2.0 在 Windows PowerShell 5.1 和 PowerShell 7.x 下均通过 40 项隔离行为断言及官方包端到端验证。本机 Codex `26.901.6511.0` x64：运行时 4,684 文件 / 337,646,562 字节，marketplace 849 文件 / 81,880,577 字节，Node `v24.19.0`。重复检查在本机隔离环境中，PowerShell 7 约 4–6 秒，5.1 约 13 秒；实际耗时取决于环境。旧版 v1.1.0 曾验证 `26.820.9563.0`；其他官方版本按本机内容动态检测，不保证未来布局始终兼容。

v1.2.1 针对 Codex `26.908.4834.0` x64 完成全新隔离恢复：运行时 4,123 文件 / 263,414,106 字节，marketplace 952 文件 / 82,779,095 字节，Node `v24.20.0`；重复检查未改动配置或新增备份。两个 PowerShell 版本均验证进程路径回退、Stream Deck 排除、真实运行时保留拦截，以及限时等待/超时诊断。

v1.3.0 在 Windows PowerShell 5.1 和 PowerShell 7 下分别通过 90 项隔离断言：42 项资源/引擎、37 项 Chrome、11 项进程测试。测试覆盖账号筛选后的 marketplace 仅缺标记、只修复注册、健康无改写、旧值备份、初始化失败自动回滚、显式回滚和超时保留状态。Chrome 初始化测试使用合成资源与替代初始化器，不代表真实扩展握手已经通过。

生成发布包：

```powershell
powershell.exe -NoLogo -NoProfile -File .\tools\New-ReleasePackage.ps1
```

`dist/` 下生成 ZIP 和 `.sha256`。ZIP 使用明确的文件白名单，只包含原创工具脚本、CMD、README、CHANGELOG、VERSION 和许可证，不包含测试输出、官方运行时、插件源码、缓存或个人配置。

下载后可以核对校验值：

```powershell
(Get-FileHash .\Codex-Computer-Use-Repair-v1.3.0.zip -Algorithm SHA256).Hash
```

## License and disclaimer

原创脚本使用 [MIT License](LICENSE)。许可不适用于 OpenAI/Codex 软件、运行时或插件；这些内容不在本仓库中分发。项目与 OpenAI 无隶属或授权关系，使用者需自行评估此临时修复是否适用于自己的故障。
