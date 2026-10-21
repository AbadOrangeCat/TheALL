---
date: 2026-04-19
status: accepted
supersedes_parts_of: 001-hybrid-appkit-swiftui.md
---

# ADR 003: 从无限白板 Canvas 切到标签页 + 分割窗格

## 决策

把终端容器从"无限画布 + 可自由拖拽浮动窗口"改为"Workspace → Tabs → SplitNode 树（二叉 split + 叶子终端）"。

## 背景

项目早期的 Canvas 形态（见 ADR 001 的原始语境）目标是白板式自由布局：用户双击空白处创建浮动终端窗口、拖拽重叠、保留 frame 到持久化。

实际使用几个月后暴露的问题：

1. **终端尺寸管理失控**：ghostty surface 对 frame 变化非常敏感，自由拖拽 + 重叠 + 调整大小三者组合容易让 Metal renderer 进入 0×0 / 错位中间态。
2. **"窗口"抽象成本高**：实现标题栏、交通灯按钮、z-order、focus 路由都要手写。投入产出比低。
3. **工作流与用户预期不符**：终端使用者日常需要的是"同项目的多组 shell 并排" + "不同项目之间快速切",而不是空间化的白板。白板形态反而让人找不到东西。
4. **键盘为主的焦点切换难做**：tmux / 常见终端 app 都走 tab + split，用户有现成肌肉记忆；Canvas 的空间焦点模型没有先例可抄。
5. **持久化复杂**：frame (x,y,w,h) 在多显示器、不同分辨率下回放容易错位。

## 评估方案

| 方案 | 优点 | 缺点 |
|------|------|------|
| 继续 Canvas + 打磨 | 保留差异化概念 | 上述 5 个问题都要持续投入，surface 渲染稳定性风险高 |
| **Workspace → Tabs → Split 树（选定）** | ghostty surface frame 由 NSSplitView 统一管理；tmux 式交互用户零学习成本；持久化只存树结构与 ratio，与显示器无关 | 失去"空间化"叙事；迁移需重写 Canvas 层 |
| 纯 Tab 无 split | 实现最简 | 退化太多；同屏多 pane 是终端核心场景 |

## 结果

- 删除 `Canvas/` 下所有 Swift 文件（`CanvasScrollView` / `CanvasContentView` / `TerminalWindowView` / `TitleBarView`）与 `Bridge/CanvasBridge.swift`；`Canvas/DESIGN_NOTES.md` 保留作历史笔记。
- 新增 `TabContent/`：`TabBarView` / `TabContentView` / `SplitPaneView` / `PasteboardTypes`。
- `Models/Workspace.swift` 用 `indirect enum SplitNode` 替换旧的 `TerminalState`（只存 UUID + ratio）。
- `Bridge/TabBridge.swift` 取代 `CanvasBridge`。
- 持久化 key 升版本：`theall.workspaces.v1` → `theall.workspaces.v2`。旧数据不迁移（项目仍在快速迭代，没有外部用户）。

## 影响

- ADR 001 仍然成立（SwiftUI 壳 + AppKit 核 + `NSViewRepresentable` 桥接），但"AppKit Canvas"换成"AppKit TabBar + SplitPane"。
- `docs/architecture.md` 的 Overview / Data Flow / Layer 小节全部重写。
- `CLAUDE.md` / `AGENTS.md` 的 Directory Structure、Key Conventions 第 4 / 5 / 7 条、Common Tasks 都要跟着更新 —— 由此催生了"文档与目录结构同步"这条新约束（见 `docs/conventions.md` 末段）以及 `scripts/check-doc-drift.sh`。
- 没有向后兼容包袱：旧的 `frame`/`TerminalState` 字段、Canvas 相关的 notification、键位全部删除。
