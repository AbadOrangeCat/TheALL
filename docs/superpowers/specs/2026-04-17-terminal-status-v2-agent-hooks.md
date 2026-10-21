# 终端状态图标 v2 — Agent Hook 驱动

> Status: draft · 2026-04-17 · 对 `2026-04-17-terminal-status-icon-design.md` 的补丁 / 部分重写

## 背景与动机

v1 版本上线后（已合入 `agent/terminal-status-icon` 分支 14 个 commit），用户测试时发现一个根本性问题：

对于 **Claude Code / opencode / Codex CLI** 这类长跑 TUI agent，v1 的信号源是**外层 shell 级别**的（OSC 133 COMMAND_FINISHED + Return-key 启发）——但外层的 `claude` / `codex` / `opencode` 命令本身从未结束，所以：

- shell 永远处于"一条命令正在跑"的状态
- 用户在 Claude Code 里空闲等待输入时，图标仍显示 running
- 无法感知 agent 内部是不是在思考/工作 vs 等用户输入

用户的真实期望：**只有当 agent 在实际处理任务时才显示 running；agent 回到 prompt 等待输入时显示 idle；agent 等待用户批准工具调用时显示 needsInput**。

## 方案：双通道 Hook IPC

设计两条并行的信号通道：

```
通道 A: Shell-level preexec/precmd  →  普通 shell 命令的 running/idle
通道 B: Agent-level wrapper + hooks →  claude/opencode/codex 精细三态
```

两条通道都通过 **Unix Domain Socket** 上报到 theall app 进程；app 侧合并后写入 `TerminalStatusStore`。

### 传输层：Unix Socket

- App 启动时在 `~/Library/Caches/theall/hooks.sock` 起 `DispatchSourceRead` listener
- 每个 ghostty surface 创建时通过 `ghostty_surface_config_s.env` 注入两个环境变量：
  - `THEALL_HOOK_SOCK=<socket path>`
  - `THEALL_TERMINAL_ID=<uuid>`
- 子 shell 继承这两个环境变量；所有 hook 脚本读它们后向 socket 写一行 JSON
- 消息格式（**line-delimited JSON**，每行一条消息）：
  ```json
  {"terminalId": "uuid", "event": "running|idle|needsInput", "agent": "shell|claude|opencode|codex", "at": 1713345678.123, "meta": {...}}
  ```
- App 侧解析 JSON → 按 terminalId + event 调对应 store 方法

### 为什么不是 OSC？
- OSC 9 会触发 macOS 桌面通知（打扰用户）
- OSC 2 会污染窗口标题
- 自定义 OSC 需要修改 libghostty（超出范围）
- Unix Socket 零耦合、可结构化、易扩展（未来支持双向推送给 hook）

## 状态模型扩展

### 新增枚举 case

```swift
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date)
    case idle(since: Date)                    // 新增
    case needsInput(since: Date)              // 新增
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
}
```

### 新聚合优先级

```
needsInput  >  running  >  failed  >  success  >  idle  >  neverRan
```

- `needsInput` 最高——要用户立即介入
- `idle` 低于 success/failed——后两者携带 exit code 信息更精确

### 视觉映射

| 状态 | 视觉 |
|------|------|
| `neverRan` | 空心灰描边圆 |
| `running` | 转动 270° 弧（主色） |
| `idle` | 空心淡灰描边圆（和 neverRan 几乎一样，仅 tooltip 区分） |
| `needsInput` | **琥珀色实心圆 + 0.8Hz 脉冲** |
| `success` | 实心绿圆 |
| `failed` | 实心红圆 |

### Tooltip

| 状态 | Tooltip |
|------|---------|
| `neverRan` | 无 |
| `running` | `Running for 1m23s` |
| `idle` | `Idle for 5m12s` |
| `needsInput` | `Needs input (5s ago)` |
| `success` | `Succeeded in 2m31s · exit 0` |
| `failed` | `Failed after 45s · exit 1` |

## Hook 脚本清单

所有 hook 脚本存放于 `Resources/agent-hooks/`，构建时复制到 app bundle `Contents/Resources/agent-hooks/`。

### Shell-level（通道 A）

`shell-hooks.zsh` / `shell-hooks.bash` / `shell-hooks.fish`：
- 注入 `preexec` → 发 `{"event":"running"}`
- 注入 `precmd` → 发 `{"event":"idle"}`
- 由我们自己维护（不复用 ghostty 的 shell-integration——那套目标不同）

shell-integration 脚本在用户 shell 初始化时 source 我们的 `shell-hooks.*`，并定义三个 shell function 拦截 agent 命令：

```zsh
claude()   { exec "$THEALL_AGENT_HOOKS_DIR/claude-wrapper.sh"   "$@" }
opencode() { exec "$THEALL_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@" }
codex()    { exec "$THEALL_AGENT_HOOKS_DIR/codex-wrapper.sh"    "$@" }
```

### Claude Code Wrapper

`claude-wrapper.sh`（bash）：
1. 找到真 claude 二进制（`which -a claude | grep -v theall | head -1` 或查 `$THEALL_REAL_CLAUDE` env 覆盖）
2. 构造 `--settings` JSON，注入 5 个 hooks：
   - `UserPromptSubmit` → hook-emit `running`
   - `PreToolUse` → hook-emit `running`（避免被误降为 idle）
   - `Stop` → hook-emit `idle`
   - `Notification` → hook-emit `needsInput`
   - `SessionEnd` → hook-emit `idle`
3. `exec` 真 claude 带上原始参数和 `--settings "$json"`

hooks 调用的 emit 脚本：`hook-emit.sh <event> [meta...]`，读 `$THEALL_HOOK_SOCK` + `$THEALL_TERMINAL_ID` → 构造 JSON → 通过 `nc -U` 或 Python `socket` 发送到 socket。

### opencode Wrapper

`opencode-wrapper.sh`：
1. 准备一个临时插件目录
2. 写入 `theall-status-plugin.js`，订阅：
   - `session.status` 或 `tool.execute.before` → `running`
   - `session.idle` → `idle`
   - `permission.asked` → `needsInput`
   - `permission.replied` → （如果 reply != reject 则 `running`，否则 `idle`）
3. 通过环境变量或 CLI 参数指向该插件目录
4. `exec` 真 opencode

插件用 Node/TypeScript 的 `net` 模块发 Unix Socket 消息。

### Codex CLI Wrapper

`codex-wrapper.sh`：
1. 在 `$CODEX_HOME` 或临时目录构造 `config.toml` 覆盖层，设置 `notify = ["$THEALL_HOOK_EMIT --agent=codex --event=idle"]`
2. 如果 codex 版本支持实验 `hooks.json`，同时在其中注入 `UserPromptSubmit → running` / `PreToolUse → running` / `Stop → idle`
3. 读 codex 的 `tui.notification_method = "osc9"` 作为兜底（虽然我们不用 OSC 作为主通道，但 codex 的 notify 语义是"turn 完成"——在稳定版上唯一可靠的信号）
4. `exec` 真 codex 带上修改后的 config

**注**：Codex CLI 的 hooks.json 当前是 experimental 功能，若 feature flag 未开启，我们只能拿到 turn 完成信号——等价于"每次 agent 回到 prompt 触发一次 idle"。这已经比什么都没有好得多。

## 要拆除的 v1 代码

### 完全删除

- `GhosttyBridge.onEnterKey` 闭包
- `GhosttyBridge.onCommandFinished` 闭包
- `GhosttyBridge.onPromptStart` 闭包（从未用上）
- `GhosttyTerminalView.keyDown` 里的 `keyCode == 36` 分支
- `GhosttyBridge.actionCallback` 里 `GHOSTTY_ACTION_COMMAND_FINISHED` 的业务分支（router 骨架保留——未来可能用 `GHOSTTY_ACTION_SET_TITLE` 之类做兜底）
- `ContentView.onAppear` 里对 `onEnterKey` / `onCommandFinished` 的 wiring

### 保留（继续复用）

- `TerminalStatus` enum（扩两个 case）
- `TerminalStatusStore`（加 `setIdle` / `setNeedsInput` 方法）
- 聚合函数（仅调整 priority 数字）
- `TerminalStatusIconView`（加 2 个 case 的渲染分支 + tooltip）
- Tab/Sidebar 的图标接入
- shell-integration vendor + copy phase（现在同时打包我们自己的 hook 脚本）
- `GhosttyBridge` 的 resources-dir 加载（依然用于定位我们的 hook 脚本）
- `GhosttyTerminalView.terminalId` + surface lookup（不再被 COMMAND_FINISHED 用，但可能将来其他 action 需要）

## 环境变量注入机制

两个关键变量必须进入每个 shell：

```
THEALL_HOOK_SOCK=/Users/xxx/Library/Caches/theall/hooks.sock
THEALL_TERMINAL_ID=<per-surface UUID>
```

方案：

1. **Socket path**：全局常量，theall 启动时用 `setenv("THEALL_HOOK_SOCK", ..., 1)` 设好——子进程自动继承。
2. **Terminal ID**：每个 surface 不同——必须走 `ghostty_surface_config_s.env` 字段注入（ghostty C API 支持）。

若 ghostty_surface_config_s 没有 env 字段，备选：每次 `newSurface` 前临时 `setenv`——但有竞态风险（两个 surface 几乎同时创建时可能拿到错的 ID）。优先走 C API 方式；若不可行再搬出备选。

## 实现顺序

**Phase 1 — 基础设施（必须先做完）**

1. App 侧 Unix socket listener
2. 环境变量注入（每个 surface 独立 TERMINAL_ID）
3. 拆除 v1 的 Return-key 和 COMMAND_FINISHED 业务逻辑
4. 状态模型扩两个 case、聚合优先级更新、图标渲染加两个分支、tooltip 扩展

**Phase 2 — Shell 级 hooks（通道 A）**

5. 写 shell-hooks.{zsh,bash,fish} 脚本，内含 preexec/precmd
6. 写 `hook-emit.sh` 工具脚本（所有 wrapper 都用）
7. 集成到 shell-integration 启动脚本

**Phase 3 — Agent wrapper**

8. `claude-wrapper.sh` + 集成测试（需要用户手工验证）
9. `opencode-wrapper.sh` + 插件 JS
10. `codex-wrapper.sh`（稳定 notify + 实验 hooks.json 双路径）

每个 Phase 结束后做一次端到端手动验证才进下一个。

## 非目标（YAGNI）

- 不在 hook 里做复杂的 payload（只传 event + 最小 metadata）
- 不同时支持 OSC 兜底（纯 socket）
- 不做 hook 内容的持久化/历史
- 不做 agent 之外的第三方 CLI 适配（aider、mentat 等另起话题）
- 不在 app 侧给 hook 反向推送消息（未来可以，现在 socket 是单向的）
