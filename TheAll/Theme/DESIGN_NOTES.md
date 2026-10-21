# Theme — Design Notes

## Token-first 原则

所有视图从 `AppTheme` token 取色，不硬编码颜色值。
新增颜色需求时：
1. 先在 `AppTheme.swift` 添加 token
2. 在 `ThemeManager.swift` 的三个来源（覆盖/ghostty/系统）里填充新 token
3. 视图里使用新 token

不要在视图里用 `.primary`、`.secondary` 等系统颜色（主题切换时行为不可预测）。

## 优先级合并

```
ThemeManager.computeTheme():
1. 用户手动覆盖（userOverrides dict）— 最高优先
2. ghostty config 颜色（GhosttyConfigReader）
3. macOS 系统深色/浅色（NSApp.effectiveAppearance）— 兜底
```

任何一层失败，直接跳到下一层，不抛出异常。

## GhosttyConfigReader

只负责把 `ghostty_config_color_s` 转换为 `NSColor`。
不做任何状态管理，是纯函数工具类。
解析失败（ghostty 未初始化、key 不存在）返回 nil，调用方降级处理。
