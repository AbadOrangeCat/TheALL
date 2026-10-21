# Auto Release From Commits — Design

## Context

theall 目前的 release 流程是**人工 tag**触发：开发者在本地 `git tag v1.2.3 && git push --tags`，`.github/workflows/release.yml` 响应 tag push，跑完 libghostty 构建 → xcodebuild → DMG 打包 → Sparkle EdDSA 签名 → appcast 渲染 → `gh release create`。

这个流程可靠，但有两个摩擦点：
1. **版本号 bump 和 tag 是两个动作**。`project.yml` 的 `MARKETING_VERSION` 要手动改、commit、push，之后还要单独 tag 一次。容易忘记其中一步，或者 tag 的 commit 跟版本号变更的 commit 不一致。
2. **Changelog 是裸 commit 列表**。`git-cliff --latest --strip all` 输出的是扁平 bullet，没有按 feat/fix/refactor 分组，直接进 GitHub Release 和 Sparkle 更新弹窗时可读性一般。

计划将"提 PR 合进 master → 发版"一体化，采用"检测版本号变化 → 自动 tag → 复用现有 release.yml"的两段式结构。本文记录早期方案，当前发布流程以 `.github/workflows/release.yml` 为准。

## Goals

- 开发者改 `project.yml` 的 `MARKETING_VERSION` 并 push 到 master，CI 自动完成剩下所有发版动作。
- 不破坏现有 tag 触发路径 —— 人工 `git tag` 仍然可用，作为紧急发版退路。
- Release note 和 Sparkle 更新弹窗按 commit 类型分组（Features / Bug Fixes / ...），而不是扁平列表。
- Sparkle 判升级靠 `CURRENT_PROJECT_VERSION`（build number），CI 自动 bump，开发者不需要手动维护。

## Non-Goals

- **不做 semver 自动推算**。版本号由开发者手动决定（选 `project.yml` B 方案）。
- **不做 changelog 手写介入**。完全依赖 git-cliff 解析 commit。
- **不做 pre-release / draft release**。直接 publish，跟现状一致。
- **不做 workflow_dispatch 手动入口**。YAGNI。

## Architecture

```
push to master
  │
  ▼
auto-tag.yml（新增）
  │ 检测 project.yml 的 MARKETING_VERSION 相比 HEAD^ 是否变化
  ├── 没变 / 是 bot 自己的 commit → exit 0
  └── 变了
        │ 1. bump CURRENT_PROJECT_VERSION（build number）
        │ 2. commit "chore(release): bump build to N for v<ver> [skip auto-tag]"
        │ 3. git tag v<ver>
        │ 4. push master + tag
        ▼
tag push
  │
  ▼
release.yml（已存在，一行改动接入 cliff.toml）
  │ libghostty → xcodebuild → DMG → Sparkle 签名 → appcast → gh release create
  ▼
GitHub Release（用户可见）+ appcast.xml（Sparkle 已安装用户自动升级）
```

## Component 1 — `.github/workflows/auto-tag.yml`

### 触发器

```yaml
on:
  push:
    branches: [master]
    paths: ['project.yml']

concurrency:
  group: auto-tag
  cancel-in-progress: false

permissions:
  contents: write
```

- `paths: ['project.yml']` 让只改 Swift 代码的 push 跳过 workflow 启动阶段（省 CI 分钟数）。
- `concurrency` 防止并发版本号竞争。
- `contents: write` 允许默认 `GITHUB_TOKEN` push commit + tag。

### Job: detect-and-tag

runs-on: `ubuntu-latest`（不需要 macOS，所以用 ubuntu 省钱）。

步骤：

1. **Checkout** `fetch-depth: 0`，`persist-credentials: true`（默认 true，但显式声明）。
2. **Skip 自身 bump commit**：读 HEAD commit message，如果包含 `[skip auto-tag]` 则 `exit 0`。
3. **Diff `MARKETING_VERSION`**：
   ```bash
   NEW=$(grep -E '^ +MARKETING_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
   OLD=$(git show HEAD^:project.yml | grep -E '^ +MARKETING_VERSION:' | awk '{print $2}' | tr -d '"')
   ```
   - `NEW == OLD` → echo "no version change" → exit 0。
4. **守护**：
   - tag `v$NEW` 已存在 → `exit 1`，报错 "tag v$NEW already exists, check for version rollback"。
   - `NEW` 相比 `OLD` 是 semver 降级 → `exit 1`，报错 "version rollback not allowed (OLD → NEW)"。（用 `sort -V` 判定即可，不需要引入 semver 工具。）
5. **Bump build number**：
   ```bash
   BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
   NEW_BUILD=$((BUILD + 1))
   sed -i "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
   ```
6. **Commit + tag + push**：
   ```bash
   git config user.name "github-actions[bot]"
   git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
   git commit -am "chore(release): bump build to $NEW_BUILD for v$NEW [skip auto-tag]"
   git tag "v$NEW"
   git push origin master --follow-tags
   ```
7. tag push 被 `release.yml` 接管。

### 递归防护

bot 的 bump commit 只动 `project.yml`，所以 `paths: ['project.yml']` 过滤**不足以**阻止 auto-tag.yml 被自己触发。必须靠 commit message 里的 `[skip auto-tag]` 标记在 job 内 early-exit。

注意 **不能**用 GitHub 自带的 `[skip ci]`，那会同时阻止 tag push 触发的 release.yml —— 正好是我们想要触发的。所以用自定义标记 `[skip auto-tag]`。

### 权限假设

Master 分支未启用 branch protection（或 protection 不要求 PR / review）。默认 `GITHUB_TOKEN` 直接 push 到 master 可行。如果未来开了 protection，改用 repo secret `RELEASE_PAT`（fine-grained PAT，contents: write）。本设计不预先配置 PAT。

## Component 2 — `cliff.toml`

放仓库根目录。基于 input0 的配置，调整为 theall 的 type 白名单。

```toml
[changelog]
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group }}
{% for commit in commits %}\
- {{ commit.message | split(pat="\n") | first | trim }}
{% endfor %}
{% endfor %}"""
trim = true

[git]
conventional_commits = true
filter_unconventional = true
split_commits = false
commit_parsers = [
  { message = "^feat",      group = "Features" },
  { message = "^fix",       group = "Bug Fixes" },
  { message = "^perf",      group = "Performance" },
  { message = "^refactor",  group = "Refactoring" },
  { message = "^style",     group = "Styling" },
  { message = "^test",      group = "Tests" },
  { message = "^build",     group = "Build System" },
  { message = "^ci",        group = "CI" },
  { message = "^revert",    group = "Reverts" },
  { message = "^docs",      group = "Docs",   skip = true },
  { message = "^chore",     group = "Chores", skip = true },
]
```

- `filter_unconventional = true` 把不符合 `type(scope): description` 的 commit 丢掉，避免脏数据进 release note。
- `docs` 和 `chore` 被 skip —— 这两类不影响用户可见行为，用户看更新弹窗时不需要关心。
- 分组顺序由 git-cliff 的 `group_by` 决定（按 commit 类型出现顺序），不是预先排序；若未来有强需求再改成显式 `default_scope` 排序。

## Component 3 — 修改 `.github/workflows/release.yml`

唯一改动是 "Generate changelog" 步骤：

```diff
- run: git-cliff --latest --strip all --output CHANGELOG.md
+ run: git-cliff --latest --strip header --config cliff.toml --output CHANGELOG.md
```

- `--config cliff.toml` 启用分组模板。
- `--strip header` 去掉 "Changelog" 顶部标题（保留分组内容），跟 input0 一致。
- `--latest` 保持不变：只取从上一个 tag 到 HEAD 的 commits。

其他步骤完全不动。`render-appcast.sh` 照常把 `CHANGELOG.md` 嵌进 `<description><![CDATA[...]]></description>`，Sparkle 客户端把 markdown 当纯文本显示（现状行为，不产生回归）。

## Component 4 — 文档同步

### `docs/build.md` · Release 流程

在 "Release 流程" 小节新增 **默认路径**（Commit-driven）和 **退路**（手动 tag）两个子节：

- **默认**：改 `project.yml` 的 `MARKETING_VERSION` → commit 一行（推荐 message 格式 `chore(release): bump version to 1.2.3`，body 可选写 highlights） → push master → auto-tag.yml 自动 bump build number + tag + 触发 release.yml。
- **退路（紧急发版）**：本地 `git tag v1.2.3 && git push --tags`。auto-tag.yml 不会干扰（它只响应 `paths: project.yml`，手动 tag 不经过它）。

补说明：
- commit message 规范（type(scope): description）必须遵守，否则 cliff.toml 的 `filter_unconventional` 会把该 commit 从 release note 里丢掉（不影响发版本身）。
- CI 自动生成的 bump commit 是 type `chore`，会被 cliff.toml skip，不出现在用户看到的更新日志里 —— 符合预期。

### `CLAUDE.md` · Common Tasks

加一行：

| 任务 | 相关文件 / 命令 |
|------|----------------|
| 发新版本 | 改 `project.yml` 的 `MARKETING_VERSION` → commit → push master（详见 `docs/build.md#release-流程`） |

### `CLAUDE.md` · Directory Structure

`.github/` 在项目根，目录结构表里本来就没列 CI 文件；不需要改。但 `Agent Permissions` 的 "禁止（需人工确认）" 里已经写了 "修改 `.github/` CI 配置"，本次 PR 属于这条规则，人工确认即可，不需要改规则本身。

## Edge Cases

| 场景 | 行为 |
|------|------|
| Push 只改了 Swift 代码 | `paths: ['project.yml']` 过滤，workflow 完全不启动 |
| Push 改了 `project.yml` 但没动 `MARKETING_VERSION`（比如改了 bundle id） | workflow 启动，step 3 发现 OLD==NEW，exit 0 |
| 开发者同时 bump 了 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` | workflow 仍跑 sed，把 build number 再 +1。结果是开发者的值被覆盖。**约定**：不要手动动 `CURRENT_PROJECT_VERSION`，由 CI 管理（文档写清楚） |
| Tag `v$NEW` 已存在 | fail，阻止"版本号号回滚到已发布过的值"这种错误 |
| `MARKETING_VERSION` 降级（如 1.2.0 → 1.1.0） | fail |
| Force push 改写了 HEAD^ | 不特殊处理，按常规 git diff 跑 —— force push 到 master 本身是 agent permission 禁止动作 |
| git-cliff 解析到零个符合条件的 commit（极端情况：上次 tag 之后只有 docs/chore） | release note 是空分组列表。CI 不 fail，但这种情况很少见；文档提一句 "docs-only 版本应用 MARKETING_VERSION patch bump，commit message 单独写说明" |
| 工作流跑到一半失败（比如 push 被拒） | 已经 bump 过的 `project.yml` 不会留在 master（只 commit 在 runner 本地，push 失败就丢了）。手动重跑即可 |

## Test Plan

- **Dry-run 验证**：在 agent 分支上临时把 `auto-tag.yml` 的 `branches` 改成自己的分支名，bump `MARKETING_VERSION: 0.1.0 → 0.1.1`，push，观察 workflow 是否正确 bump build、创建 commit + tag，且 tag push 能触发 release.yml。验证后改回 `master`。
- **本地 `git-cliff` 渲染**：本地装 `git-cliff`，`git cliff --latest --strip header --config cliff.toml` 跑一遍现有 commit 历史，肉眼核对分组正确、docs/chore 被 skip。
- **版本回滚守护**：临时 bump `MARKETING_VERSION: 0.1.0 → 0.0.9`，预期 workflow fail 并打印清晰错误。
- **已存在 tag 守护**：bump 到一个已经存在的 tag 值（比如 `v0.1.0` 如果已发过），预期 fail。
- **`[skip auto-tag]` 递归防护**：手动构造一个只改 `project.yml` 且 commit message 带 `[skip auto-tag]` 的 commit，push，预期 workflow 启动但 step 2 early-exit。

## Rollout

- 本次 PR 合进 master 后不立刻触发 auto-tag（没动 MARKETING_VERSION）。
- 下一次真实发版：改 `MARKETING_VERSION: 0.1.0 → 0.2.0`，单独开 PR，合进 master，观察全链路。
- 如果 auto-tag 炸了 → revert PR，继续手动 `git tag` 发版。
