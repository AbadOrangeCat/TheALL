# Ghostty — Design Notes

## 封装原则

GhosttyBridge 是唯一允许调用 `ghostty_*` C 函数的文件（除 GhosttyTerminalView 的输入/渲染部分）。
如果需要新的 ghostty 功能，**先在 GhosttyBridge 添加方法，再从调用方调用**。
不要在 Model、Store、UI 层散落 C API 调用。

## 生命周期注意事项

- `ghostty_surface_t` 的 `nsview` 参数传入 unretained pointer，NSView **必须**比 surface 活得更长
- GhosttyTerminalView 在 `deinit` 里调用 `ghostty_surface_free()`
- `GhosttyBridge.teardown()` 只在 app 退出时调用（AppDelegate.applicationWillTerminate）

## wakeup 回调

ghostty 的渲染循环由 `wakeup_cb` 驱动：ghostty 内部需要刷新时调用此回调，
回调里在主线程调用 `ghostty_app_tick(appHandle)`。
不要用 `CADisplayLink` 或 `Timer` 定时 tick，浪费 CPU。

## 颜色读取 vs 主题应用

- `GhosttyBridge.readBackground/readForeground/readPalette` — 读 ghostty config 里用户设置的颜色，用于初始化 AppTheme
- `GhosttyBridge.applyColorScheme(_:)` — 通知 ghostty 切换深/浅模式，影响 ghostty 内部渲染（光标、选区等）
两者独立，都需要调用。
