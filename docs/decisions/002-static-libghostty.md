---
date: 2026-04-13
status: accepted
---

# ADR 002: 使用静态库 libghostty.a 而非动态库

## 决策

链接 `libghostty.a`（静态库），不使用 `libghostty.dylib`（动态库）。

## 原因

- ghostty 官方在 macOS 上构建产物是 `.a`，不提供 `.dylib`
- 静态链接消除运行时 dylib 路径问题（`@rpath` 配置复杂）
- `LD_RUNPATH_SEARCH_PATHS` 设为空字符串，明确不依赖 rpath

## 影响

- `Vendor/ghostty/lib/libghostty.a` 加入 `.gitignore`（体积大）
- 每台开发机首次需要运行 `scripts/build-vendor.sh` 构建
- `project.yml` 中 `OTHER_LDFLAGS = -lghostty -lc++ -framework Carbon`
