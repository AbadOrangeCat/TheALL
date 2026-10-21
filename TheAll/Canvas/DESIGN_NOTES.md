# Canvas — Design Notes

## 为什么用纯 AppKit

SwiftUI 的 `ZStack` + `.offset` 方案在自由重叠、z-order 提升（activate on click）、
拖拽时有已知 bug（focus ring 跑偏、HitTest 失效）。AppKit NSView 完全控制 frame 和 subview 顺序。

## CanvasContentView 职责

- 持有所有 `TerminalWindowView`，管理其生命周期（创建/移除）
- 响应 workspace 切换：旧 workspace 的 view 从 superview 移除，surface 保留在内存（不 free）
- 双击空白处 → 在点击坐标创建新 TerminalWindowView
- 监听 `theAllCreateTerminalAtVisibleCenter` 通知（Cmd+T）

## TerminalWindowView 尺寸

v1 固定尺寸：宽 720pt，高 480pt（TitleBar 32pt + Terminal 448pt）。
resize 句柄是 v2 特性，v1 不实现。

## 激活状态边框

```swift
// 激活
layer.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
layer.borderWidth = 1.5

// 非激活
layer.borderColor = theme.border.withAlphaComponent(0.08).cgColor
layer.borderWidth = 1.0
```

点击 TerminalWindowView 时将其移到 superview.subviews 末尾（最上层），其他的更新为非激活状态。

## 拖拽实现

TitleBarView 处理 `mouseDragged`，不在 TerminalWindowView 里处理（避免和 GhosttyTerminalView 的鼠标事件冲突）。
拖拽结束（`mouseUp`）才写回 WorkspaceStore，拖拽过程中只更新 view.frame，不触发持久化。
