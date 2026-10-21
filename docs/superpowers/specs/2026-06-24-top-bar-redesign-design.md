# 顶部栏重构 + 快捷操作下拉化

日期：2026-06-24

## 背景

当前顶部有一条 28pt 空白带（`trafficLightInset`）：左侧是侧边栏 toggle + 新建 workspace 的 `＋`，
右侧是 `quickActionsBar`（Claude/Codex 等快捷操作图标），中间内容卡片在带子下方。空白带视觉上浪费，
快捷操作图标常驻顶部右上也偏重。

## 目标

1. 去掉顶部 28pt 空白带，tab 栏上移到顶部，与 toggle 同一水平线。traffic light 竖向空间仍保留。
2. 右上角 `quickActionsBar` 整条移除；快捷操作改为 tab 栏 `＋` 的下拉菜单：第一项「Terminal」（普通新 tab），
   其后是 `quickActionsStore.displayList`（已启用的快捷操作，带图标）。
3. 侧边栏折叠时：
   - 新建 workspace 的 `＋` 消失（现状已如此）。
   - 品牌名 + 设置齿轮从侧边栏 footer 渐显到顶部 toggle 左侧（顺序：traffic / 品牌 / 齿轮 / toggle / tab 栏）。
   - tab 栏左移并略微变宽，占用 `＋` 消失后释放的空间。
   - 折叠后顶部左区由容器（canvas）色覆盖。

## 设计

### 顶部控件簇（`ContentView` 顶层 ZStack overlay）
- 展开：`[toggle][addWorkspace ＋]`（保持现状）。
- 折叠：`[品牌按钮（贴红绿灯右侧）] …留白… [齿轮][toggle]`——品牌名贴左，齿轮 + toggle 成组贴右（齿轮与展开态 ＋ 同槽位），品牌/齿轮复用现有跳转通知（Settings → Update / 打开设置）。
- 品牌按钮 + 齿轮抽成可共享小视图，`SidebarView` footer 与顶部 overlay 复用，避免重复实现。

### tab 栏 `＋` 下拉（`TabBarView`）
- `＋` 单击弹出原生 `NSMenu`，锚定在 `＋` 按钮下方。
- 菜单项：`Terminal`（→ `onAddTab`）／分隔线／`displayList` 每项（→ 新增 `onAddQuickActionTab(id)`）。
- 菜单项图标复用 `TabItemView` 已有的 quick-action icon 渲染逻辑（SF Symbol / asset / letter）。

### tab 栏左移/变宽（`TabContentView`）
- 新增 `tabStripLeadingInset`（展开 = 0；折叠 = 为左侧 traffic + 品牌 + 齿轮 + toggle 让出空间）。
- 只移动 tab 栏 frame，pane 容器仍满宽。

### 数据流
- `ContentView` → `TabBridge` 新增传 `tabStripLeadingInset`。
- `TabContentView.tabBar.onAddQuickActionTab` → `store.addQuickActionTab` + `pwdStore.inherit` + reload（复用原
  `ContentView.quickActionButton` 的逻辑）。

### 动画
- 折叠/展开沿用 toggle 现有 `withAnimation(.easeInOut(0.2))`。
- 品牌 + 齿轮：`.transition(.opacity)` 渐显/渐隐。
- tab 栏宽度变化：`TabContentView` 在 `tabStripLeadingInset` 改变时用 `NSAnimationContext`（≈0.2s）动画 tab 栏
  frame，与 SwiftUI 侧侧边栏移动 / 卡片左移同步。

## 影响文件
`TheAll/ContentView.swift`、`TheAll/Bridge/TabBridge.swift`、`TheAll/TabContent/TabContentView.swift`、
`TheAll/TabContent/TabBarView.swift`、`TheAll/Localization/Localizable.xcstrings` + `L10n.swift`（「Terminal」菜单项），
必要时抽 `TheAll/Sidebar/SidebarView.swift` 的 footer 小视图。无新增/删除目录或文件，不触发文档漂移。

## 非目标
- 不改快捷操作的持久化模型、Settings → Quick Actions 配置 UI。
- 不重构 sidebar / pane 的整体架构，仅顶部栏与 tab `＋` 行为。
- 像素级对齐（tab 栏与控件垂直居中、折叠各元素精确 inset）在实现时配合截图微调。
