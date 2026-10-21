# 004 — Shell 从状态指示 pipeline 中移除

**Status**: Accepted
**Date**: 2026-04-20
**Supersedes**: 部分代替 `docs/superpowers/specs/2026-04-17-terminal-status-v2-agent-hooks.md` 中 shell 部分的设定。

## Context

在 2026-04 以前，theall 的终端状态图标有 4 种来源：shell 的 zsh/bash/fish preexec/precmd 钩子，以及 Claude Code / Codex / OpenCode 三个 agent wrapper。shell 钩子在每次命令（甚至空回车）都会发 `running` / `idle` / `finished` 事件对，导致 socket 流量极高而信息量低——大部分用户对着不断跳动的图标看的是"shell 刚执行了什么"，但真正想看的是 "agent turn 还在跑吗 / 有没有需要我确认的提示"。

单一总开关 `theall-status-indicators` 也无法让用户只打开"想关心的 agent"，只能整体 opt-in 或 opt-out。

## Decision

shell 从状态指示 pipeline 中彻底移除：

- 删除 `Resources/agent-hooks/shell-hooks.{zsh,bash,fish}` 三个脚本；`bootstrap.*` 不再 source 它们。
- `HookMessage.Agent` 枚举不含 `.shell` case。`TerminalStatus.success/.failed` 与 `TerminalStatusStore.setFinished` 不再有 `.shell` 默认参数。`TerminalStatusIconView` tooltip 的 shell 分支被合并，统一走 agent 格式。
- 总开关 `theall-status-indicators` 下线。取而代之的是三个独立 per-agent key：`theall-agent-status-claude` / `-codex` / `-opencode`，默认全部关闭。UI 上汇入新的 Settings → Agents 分组。
- 图标的 UI gate（`showStatusIndicators`）从"读总开关"变为"任一 per-agent key 为 true"。

## Consequences

**正面**：
- Socket 流量显著下降（按人均每天打几百次 prompt 估算）。
- 用户可按 agent 精确选择想看到的状态，UI 噪声减少。
- 扩展到第 4 个 code agent 的路径清晰：加 `HookMessage.Agent` 枚举 case + 翻译 key + wrapper 脚本，Swift 侧其它代码自动派生新 toggle。

**负面 / 风险**：
- 老用户升级后状态图标默认消失，直到在 Settings → Agents 里至少打开一个。文档与 release note 需要注明。
- "shell 命令耗时 / 退出码"这个能力彻底没了。假如未来有需求（如"上条命令失败了显示红点"），需要重新引入 shell hooks 或改造为另一条独立 UI。
- 老用户 theall config 里残留的 `theall-status-indicators = ...` 不会被自动清理（行级 ConfigLine 解析保留未知 KV），但不再被读取。无害，自愿手动清理。

## Alternatives Considered

**A. 保留 shell 源，加个只读总开关过滤 UI**：复杂度没降，socket 流量没降。放弃。

**B. 保留 shell，全收全存，视图层按 agent 过滤**：TerminalStatus 所有 case 需要带 agent 字段，下游 sidebar/tab/view 都要改，换来的只是一个罕见边缘场景（toggle 中途关再开）更丝滑。成本收益比不划算。放弃。

**C. 当前方案：监听层按 agent 过滤 + 派生总开关**。选定。
