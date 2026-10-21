---
date: 2026-04-13
status: accepted
---

# ADR 001: SwiftUI 侧边栏 + AppKit Canvas 混合架构

## 决策

侧边栏用 SwiftUI，白板 Canvas 用 AppKit NSView，通过 NSViewRepresentable 桥接。

## 背景

需要在同一个 app 里实现：
1. 动态列表 + 状态刷新（侧边栏）
2. 自由浮动、重叠、z-order 可控的终端窗口（Canvas）

## 评估方案

| 方案 | 优点 | 缺点 |
|------|------|------|
| 纯 SwiftUI | 代码简洁，状态驱动 | 自由重叠 + 焦点路由有已知坑，z-order 不可靠 |
| 纯 AppKit | 完全控制 | 侧边栏代码量大，列表刷新繁琐 |
| **混合（选定）** | 各用所长 | 需要 NSViewRepresentable 桥接层 |

## 结果

- 侧边栏：SwiftUI，声明式 UI + @Observable 状态自动刷新
- Canvas：AppKit，自由控制 frame、z-order、拖拽
- 桥接：CanvasBridge (NSViewRepresentable)

## 影响

- Canvas 层不引入 SwiftUI 组件
- 侧边栏不使用 NSView subclass
- 状态通过 WorkspaceStore (@Observable) + Environment 在两层间共享
