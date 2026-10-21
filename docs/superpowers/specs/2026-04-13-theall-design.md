# theall 设计文档

**日期:** 2026-04-13  
**项目:** theall — macOS 白板式终端,基于 libghostty

---

## 概述

theall 是一个 macOS 原生终端应用,以 libghostty 作为终端渲染引擎,外壳用 Swift/AppKit + SwiftUI 实现。核心差异化特性:

1. **白板式内容区** — 多个终端窗口可在无限画布上自由浮动、重叠、拖拽
2. **展开式侧边栏** — 180px 常驻侧边栏,每个 workspace 显示 git 分支、PR 状态、工作目录、监听端口、agent 通知
3. **主题适配** — 支持 macOS 深色/浅色模式,同时读取 ghostty config 主题,不硬编码颜色

不 fork ghostty 源码,不复制第三方代码,仅参考同类项目的 libghostty 集成逻辑。

---

## 方案选择

**选定方案:SwiftUI 侧边栏 + AppKit Canvas(混合)**

- 侧边栏用 SwiftUI:声明式 UI,列表/状态刷新省力
- 白板 Canvas 用 AppKit NSView:自由浮动、重叠、z-order 管理需要完全控制
- 通过 `NSViewRepresentable` 桥接两层
- 仅支持 macOS,不考虑 Linux/Windows

**放弃的方案:**
- 纯 AppKit:侧边栏代码量大,维护繁琐
- 纯 SwiftUI:自由重叠 + 焦点路由在 SwiftUI 有已知坑

---

## 架构

```
TheAll.app
├── Sidebar (SwiftUI)          — workspace 列表 + 元信息
├── CanvasArea (AppKit)        — 白板画布,内含浮动终端窗口
│   └── NSViewRepresentable   — SwiftUI ↔ AppKit 桥接
├── WorkspaceStore             — 纯 Swift 状态管理 (@Observable)
├── ThemeManager               — 主题解析与分发
└── libghostty (C API)         — 终端渲染引擎
```

数据流方向:WorkspaceStore → Sidebar + CanvasArea(单向),用户交互 → WorkspaceStore(写回)。

---

## 核心组件

### ThemeManager

从以下来源解析主题,按优先级合并:

1. theall 用户手动覆盖(最高)
2. `~/.config/ghostty/config` 中的 `theme =` 字段
3. macOS 系统深色/浅色模式(兜底)

暴露 `AppTheme` 结构体,包含 token:
- `background`, `foreground`, `border`, `accent`, `selection`
- 所有 UI 组件从 token 取色,不硬编码任何颜色值

ghostty config 解析失败时降级到系统模式,不 crash。

### WorkspaceStore

`@Observable` 类,持有:

```swift
struct Workspace {
    let id: UUID
    var name: String
    var metadata: WorkspaceMetadata   // git、PR、端口、通知
    var terminals: [TerminalState]    // 每个终端的 surface + frame
}

struct TerminalState {
    let id: UUID
    var surfaceHandle: OpaquePointer  // ghostty_surface_t
    var frame: CGRect
}
```

持久化:UserDefaults + Codable,存 workspace 列表和每个终端的 frame(surface 不序列化,重启后重建)。

### Sidebar (SwiftUI)

```
WorkspaceListView
  └── WorkspaceRowView
        ├── workspace 名称
        ├── ⎇ git 分支
        ├── PR 状态 badge (open/merged/closed)
        ├── 工作目录(截断显示)
        ├── 监听端口 tags (:3000 :8080)
        └── 最新 agent 通知文本
  └── "+" 新建 workspace 按钮
```

`WorkspaceMetadata` 后台每 5 秒刷新一次(git status、lsof 端口扫描)。OSC 9/99/777 通知实时推送,不轮询。

### CanvasView (AppKit)

```
CanvasScrollView : NSScrollView
  └── CanvasContentView : NSView   (无限大,clipsToBounds = false)
        └── TerminalWindowView[]   (可拖拽浮动)
```

- 双击空白处 → 在点击坐标创建新 TerminalWindowView
- Cmd+T / 工具栏按钮 → 在画布中心创建
- 切换 workspace → 旧 workspace 的视图从 canvas 移除(surface 保留),新 workspace 视图按存储 frame 恢复

### TerminalWindowView (AppKit)

```
TerminalWindowView : NSView
  ├── TitleBarView                  (拖拽手柄 + 交通灯按钮)
  │     mouseDragged → 更新 frame
  └── GhosttyTerminalView : NSView  (持有 ghostty_surface_t)
        ├── keyDown/mouseDown → ghostty_surface_input_*
        └── Metal CALayer 渲染(libghostty 管理)
```

视觉规格:
- `layer.cornerRadius = 12`
- `layer.masksToBounds = true`
- 无阴影(`layer.shadowOpacity = 0`)
- 激活状态:细边框 `rgba(accent, 0.5)`,非激活:细边框 `rgba(border, 0.08)`

---

## 数据流

### Workspace 切换
```
点击侧边栏 WorkspaceRow
→ WorkspaceStore.select(id)
→ CanvasView 移除旧 workspace 视图(surface 不释放)
→ 按存储 frame 恢复新 workspace 视图
```

### 新建终端
```
双击画布 / Cmd+T / 工具栏按钮
→ CanvasView.createTerminal(at: CGPoint)
→ ghostty_surface_new()
→ TerminalWindowView 加入 canvas
→ WorkspaceStore 记录初始 frame
```

### 拖拽移动
```
TitleBarView mouseDragged
→ TerminalWindowView.frame 实时更新
→ mouseUp → WorkspaceStore.updateTerminalFrame(id, frame)
```

### 主题更新
```
系统外观变化 / ghostty config 变更 / 用户切换
→ ThemeManager 发出通知
→ SwiftUI 侧边栏自动重绘
→ CanvasView 遍历所有 TerminalWindowView 更新 layer 颜色
→ ghostty_surface_set_config() 通知各 surface
```

### OSC 通知
```
agent 输出 OSC 9/99/777
→ libghostty 解析,回调 notification handler
→ WorkspaceMetadata.latestNotification 更新
→ 侧边栏 WorkspaceRowView 刷新
```

---

## 错误处理

| 场景 | 处理方式 |
|------|---------|
| `ghostty_surface_new()` 失败 | canvas 内显示 inline error banner,不用系统 alert |
| libghostty 未安装 | 启动时检测,显示引导页说明安装步骤 |
| ghostty config 解析失败 | 降级到系统深色/浅色,不 crash |
| 持久化失败(磁盘满等) | 静默跳过,重启后位置重置为默认,不丢 session |

---

## 测试策略

| 类型 | 覆盖内容 |
|------|---------|
| 单元测试 | ThemeManager 解析、WorkspaceStore CRUD、frame 计算 |
| 集成测试 | libghostty surface 创建/销毁/输入转发 最小 harness |
| UI 快照测试 | 侧边栏深色/浅色主题渲染(XCTest 截图比对) |
| 手动验收 | 多窗口拖拽、workspace 切换 surface 状态保留、OSC 通知 |

---

## 项目边界(不在 v1 范围内)

- Linux / Windows 支持
- 终端窗口 resize 手柄(v1 固定尺寸,后续迭代)
- 画布缩放(pinch-to-zoom)
- workspace 云同步
- 插件系统

---

## 参考

- ghostty 源码: https://github.com/ghostty-org/ghostty
- libghostty C API: ghostty 仓库 `include/ghostty.h`
