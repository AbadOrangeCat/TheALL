# Auto Release From Commits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让开发者改 `project.yml` 的 `MARKETING_VERSION` 并 push 到 master 就自动发版。CI 检测版本号变化后自动 bump `CURRENT_PROJECT_VERSION`、打 tag、push，让现有 `release.yml` 接手构建 + Sparkle 签名 + 发 GitHub Release。

**Architecture:** 两段式 workflow。新增 `auto-tag.yml`（ubuntu, push 到 master 触发，`paths: project.yml` 过滤）检测 `MARKETING_VERSION` 变化 → bump build number → commit + tag + push，tag push 被现有 `release.yml` 接管。新增 `cliff.toml` 让 release note 和 Sparkle 弹窗按 feat/fix/refactor 分组；`release.yml` 仅一行改动接入 cliff 配置。递归防护靠 bump commit message 里的 `[skip auto-tag]` 自定义标记（不用 `[skip ci]`，那会同时阻止 tag 触发 release.yml）。

**Tech Stack:** GitHub Actions / git-cliff / bash / sort -V semver / YAML

**Spec reference:** `docs/2026-04-19-auto-release-from-commits-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `cliff.toml` | Create | Conventional-commit 分组模板，feat/fix/refactor 等；docs/chore skip |
| `.github/workflows/auto-tag.yml` | Create | Push to master → 检测 `MARKETING_VERSION` → bump build → commit + tag + push |
| `.github/workflows/release.yml` | Modify | `git-cliff` 步骤接入 `--config cliff.toml --strip header` |
| `docs/build.md` | Modify | Release 流程小节改写：默认 commit-driven + 退路手动 tag |
| `CLAUDE.md` | Modify | Common Tasks 表格加 "发新版本" 一行 |

不改 Swift 代码、不改 `project.yml`、不改 `project.yml`-generated 的 `TheAll.xcodeproj`。这是纯 CI + 文档改动。

---

## Pre-Flight Assumptions

- master 分支**未开启** branch protection（或 protection 不要求 PR review / linear history / signed commits）。默认 `GITHUB_TOKEN` 直接能 push commit + tag 到 master。
- 本地装了 `git-cliff`（`brew install git-cliff`）用于 Task 1 的验证。如果没装，跳过本地验证步骤；CI 里反正会重新跑一遍。
- 当前分支是 `agent/auto-update`，基于 master。所有 commit 打在该分支上，PR 合并后生效。

---

## Task 1: 新增 `cliff.toml`

**Files:**
- Create: `cliff.toml`

- [ ] **Step 1.1: 写入 `cliff.toml`**

在仓库根目录（`/Users/zhenghui/Documents/repos/TheAll/cliff.toml`）创建，完整内容：

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

- [ ] **Step 1.2: 验证本地 git-cliff 能解析配置**

```bash
which git-cliff || brew install git-cliff
```

Expected: `/opt/homebrew/bin/git-cliff` 或类似路径。首次装耗时 ~10-30s。

- [ ] **Step 1.3: 在仓库根跑 git-cliff 预览输出**

```bash
cd /Users/zhenghui/Documents/repos/theall
git-cliff --latest --strip header --config cliff.toml
```

Expected: 输出分组 markdown，形如：

```
### Build System
- build(ci): bump sign_update pin to 2.9.1 + CDATA-split in appcast
- build(ci): add release workflow (tag-triggered, EdDSA-signed, appcast)
```

最近没有 tag（`git tag -l` 之前是空的），所以 `--latest` 会把全部 commit 当作一个"unreleased"范围输出。不 fail 即可。

肉眼检查：
- 分组标题是 `### Features` / `### Bug Fixes` 等（不是扁平 bullet）
- `docs:` 和 `chore:` 开头的 commit **没有**出现在输出里
- 不符合 `type(scope): ...` 规范的 commit（如果有）被过滤

如果输出异常，重新检查 `cliff.toml` 的语法。

- [ ] **Step 1.4: Commit**

```bash
git add cliff.toml
git commit -m "$(cat <<'EOF'
build(ci): add cliff.toml for grouped changelog

Defines conventional-commit parsers and per-group markdown template.
docs/chore are skipped so release notes and Sparkle update dialog only
surface user-visible changes.
EOF
)"
```

---

## Task 2: 修改 `release.yml` 接入 `cliff.toml`

**Files:**
- Modify: `.github/workflows/release.yml:67-68`

- [ ] **Step 2.1: 显示原行**

```bash
sed -n '67,68p' .github/workflows/release.yml
```

Expected 输出：

```
      - name: Generate changelog
        run: git-cliff --latest --strip all --output CHANGELOG.md
```

- [ ] **Step 2.2: 替换为使用 cliff.toml**

用 Edit 工具把：

```
      - name: Generate changelog
        run: git-cliff --latest --strip all --output CHANGELOG.md
```

替换成：

```
      - name: Generate changelog
        run: git-cliff --latest --strip header --config cliff.toml --output CHANGELOG.md
```

变化两处：`--strip all` → `--strip header`，新增 `--config cliff.toml`。

- [ ] **Step 2.3: 本地模拟 CI 跑同样命令，验证与 Task 1 Step 1.3 一致**

```bash
cd /Users/zhenghui/Documents/repos/theall
git-cliff --latest --strip header --config cliff.toml --output /tmp/changelog-preview.md
cat /tmp/changelog-preview.md
```

Expected: 输出跟 Task 1 Step 1.3 一致（`--output` 只改写入目标，不改内容）。

- [ ] **Step 2.4: 验证 yaml 仍可解析**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "OK"
```

Expected: `OK`。如果报 YAML 解析错误，查 diff。

- [ ] **Step 2.5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
build(ci): use cliff.toml in release changelog

Switch git-cliff invocation to --config cliff.toml --strip header so
release notes and appcast match the grouped format defined in cliff.toml.
EOF
)"
```

---

## Task 3: 新增 `.github/workflows/auto-tag.yml`

**Files:**
- Create: `.github/workflows/auto-tag.yml`

- [ ] **Step 3.1: 写入完整 workflow**

创建 `.github/workflows/auto-tag.yml`，完整内容：

```yaml
name: Auto Tag

on:
  push:
    branches: [master]
    paths: ['project.yml']

concurrency:
  group: auto-tag
  cancel-in-progress: false

permissions:
  contents: write

jobs:
  detect-and-tag:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: true

      - name: Skip bot's own bump commits
        id: check_skip
        run: |
          MSG=$(git log -1 --pretty=%s)
          echo "HEAD commit subject: $MSG"
          if printf '%s' "$MSG" | grep -q '\[skip auto-tag\]'; then
            echo "commit contains [skip auto-tag], exiting"
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Read version fields
        if: steps.check_skip.outputs.skip != 'true'
        id: versions
        run: |
          NEW=$(grep -E '^ +MARKETING_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
          OLD=$(git show HEAD^:project.yml 2>/dev/null | grep -E '^ +MARKETING_VERSION:' | awk '{print $2}' | tr -d '"' || echo "")
          BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
          NEW_BUILD=$((BUILD + 1))
          echo "MARKETING_VERSION: '$OLD' -> '$NEW'"
          echo "CURRENT_PROJECT_VERSION: $BUILD -> $NEW_BUILD"
          echo "new=$NEW" >> "$GITHUB_OUTPUT"
          echo "old=$OLD" >> "$GITHUB_OUTPUT"
          echo "build=$BUILD" >> "$GITHUB_OUTPUT"
          echo "new_build=$NEW_BUILD" >> "$GITHUB_OUTPUT"

      - name: Decide whether to tag
        if: steps.check_skip.outputs.skip != 'true'
        id: decide
        run: |
          NEW='${{ steps.versions.outputs.new }}'
          OLD='${{ steps.versions.outputs.old }}'
          if [ -z "$NEW" ]; then
            echo "::error::MARKETING_VERSION not found in project.yml"
            exit 1
          fi
          if [ "$NEW" = "$OLD" ]; then
            echo "MARKETING_VERSION unchanged ($NEW), nothing to tag"
            echo "should_tag=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          if git rev-parse "v$NEW" >/dev/null 2>&1; then
            echo "::error::tag v$NEW already exists (version rollback?)"
            exit 1
          fi
          if [ -n "$OLD" ]; then
            TOP=$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -1)
            if [ "$TOP" != "$NEW" ]; then
              echo "::error::version rollback not allowed ($OLD -> $NEW)"
              exit 1
            fi
          fi
          echo "should_tag=true" >> "$GITHUB_OUTPUT"

      - name: Bump CURRENT_PROJECT_VERSION
        if: steps.check_skip.outputs.skip != 'true' && steps.decide.outputs.should_tag == 'true'
        run: |
          BUILD='${{ steps.versions.outputs.build }}'
          NEW_BUILD='${{ steps.versions.outputs.new_build }}'
          sed -i "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
          grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml

      - name: Commit, tag, push
        if: steps.check_skip.outputs.skip != 'true' && steps.decide.outputs.should_tag == 'true'
        run: |
          NEW='${{ steps.versions.outputs.new }}'
          NEW_BUILD='${{ steps.versions.outputs.new_build }}'
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "chore(release): bump build to $NEW_BUILD for v$NEW [skip auto-tag]"
          git tag "v$NEW"
          git push origin master --follow-tags
```

- [ ] **Step 3.2: YAML 语法校验**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/auto-tag.yml'))" && echo "OK"
```

Expected: `OK`。

- [ ] **Step 3.3: 关键字段存在性检查**

```bash
grep -n "branches: \[master\]" .github/workflows/auto-tag.yml
grep -n "paths: \['project.yml'\]" .github/workflows/auto-tag.yml
grep -n "permissions:" .github/workflows/auto-tag.yml
grep -n "contents: write" .github/workflows/auto-tag.yml
grep -n "\[skip auto-tag\]" .github/workflows/auto-tag.yml
grep -n "git push origin master --follow-tags" .github/workflows/auto-tag.yml
```

Expected: 每条都有一行命中。如果有缺失说明复制漏了。

确认 **不包含** `[skip ci]`：

```bash
if grep -n '\[skip ci\]' .github/workflows/auto-tag.yml; then
  echo "ERROR: [skip ci] must not appear — it would block tag push from triggering release.yml"
  exit 1
else
  echo "OK: no [skip ci] present"
fi
```

Expected: `OK: no [skip ci] present`。

- [ ] **Step 3.4: 干跑 sed 替换的正则（本地 project.yml 验证）**

```bash
# 复制一份到临时文件，模拟 sed 替换
cp project.yml /tmp/project-bumped.yml
BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
NEW_BUILD=$((BUILD + 1))
# 注意：macOS 的 sed 需要 -i ''，这里只在 /tmp 上做干跑，不会污染 repo
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" /tmp/project-bumped.yml
diff project.yml /tmp/project-bumped.yml
rm /tmp/project-bumped.yml
```

Expected: `diff` 只报一行 `CURRENT_PROJECT_VERSION: "1"` → `"2"`（或当前 build 数 +1）。

> ⚠️ **不要在仓库根跑带 `-i` 没参数的 sed** —— 会污染 `project.yml`。上面的命令只动 `/tmp/project-bumped.yml`。

- [ ] **Step 3.5: Commit**

```bash
git add .github/workflows/auto-tag.yml
git commit -m "$(cat <<'EOF'
build(ci): add auto-tag workflow for commit-driven releases

Push to master with a MARKETING_VERSION bump in project.yml now triggers
auto-tag.yml, which bumps CURRENT_PROJECT_VERSION, creates v<version>
tag, and pushes. The existing tag-triggered release.yml then takes over.

Bump commits carry [skip auto-tag] to prevent recursion; [skip ci] is
deliberately avoided so the tag push still triggers release.yml.
EOF
)"
```

---

## Task 4: 更新 `docs/build.md` 的 Release 流程小节

**Files:**
- Modify: `docs/build.md:62-97` (the `## Release 流程` section through the end of the file)

- [ ] **Step 4.1: 读当前的 Release 流程小节**

```bash
sed -n '62,97p' docs/build.md
```

记下当前的 "首次发布一次性准备" 和 "常规发布" 结构 —— "首次发布一次性准备" 的 Sparkle key 步骤**保留原样**，只替换 "常规发布" 和 "Appcast 格式" 子节。

- [ ] **Step 4.2: 替换 "常规发布" 子节**

用 Edit 工具。**old_string**（docs/build.md 当前的 "### 常规发布" 到它闭合的 ```` ``` ```` 那段，共约 11 行）：

````
### 常规发布

```bash
# 先过一遍本地测试
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests

# 按需手动 bump 版本（MARKETING_VERSION / CURRENT_PROJECT_VERSION）
# 修改 project.yml 后 xcodegen generate 并 commit

# 打 tag + push
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
# → .github/workflows/release.yml 触发，~10 分钟后 Release 出现在 GitHub Releases 页面
```
````

**new_string**（新"常规发布"小节 + 新加的"退路：手动 tag"小节）：

````
### 常规发布（默认：commit-driven）

改 `project.yml` 的 `MARKETING_VERSION` 就会自动发版：

```bash
# 1. 本地自测
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests

# 2. 只改 MARKETING_VERSION（不要手动改 CURRENT_PROJECT_VERSION，CI 管）
#    示例：把 "0.1.0" 改成 "0.2.0"
$EDITOR project.yml

# 3. Commit + push
git commit -am "chore(release): bump version to 0.2.0"
git push origin master

# → .github/workflows/auto-tag.yml 检测到 MARKETING_VERSION 变化：
#     a. 自动把 CURRENT_PROJECT_VERSION +1
#     b. 以 github-actions[bot] 身份 commit 并 tag v0.2.0
#     c. push master + tag
# → tag push 触发 release.yml，~10 分钟后 Release 出现在 GitHub Releases 页面
```

注意事项：

- **不要手动改 `CURRENT_PROJECT_VERSION`** —— 由 CI 自动 bump。Sparkle 靠这个字段判断是否是新版本。
- Commit message 必须符合 `type(scope): description` 规范（见 `CLAUDE.md` Key Conventions），否则 `cliff.toml` 的 `filter_unconventional = true` 会把该 commit 从 release note 里丢掉（不影响发版本身，但更新弹窗看不到该改动）。
- CI 生成的 `chore(release): bump build to N for v<version> [skip auto-tag]` 属于 `chore`，被 `cliff.toml` skip，不出现在用户可见的更新日志里。

### 退路：手动 tag（紧急发版）

auto-tag.yml 失效或者需要补发一个特殊版本时：

```bash
# 手动 bump 两个字段（MARKETING_VERSION + CURRENT_PROJECT_VERSION）
$EDITOR project.yml
git commit -am "chore(release): bump to v0.2.1"

# 手动打 tag + push
git tag -a v0.2.1 -m "Release v0.2.1"
git push origin master v0.2.1
```

auto-tag.yml 在 master push 时会启动但 step 3 发现 `MARKETING_VERSION` 未变（相对 `HEAD^`）就 exit 0，不会干扰手动 tag。
````

- [ ] **Step 4.3: 保留 "Appcast 格式" 小节不动**

用 `sed -n '94,97p' docs/build.md` 确认 "### Appcast 格式" 还在文件末尾，没被意外删除。

- [ ] **Step 4.4: grep 关键字验证**

```bash
grep -c "commit-driven" docs/build.md
grep -c "MARKETING_VERSION" docs/build.md
grep -c "auto-tag.yml" docs/build.md
grep -c "紧急发版" docs/build.md
grep -c "CURRENT_PROJECT_VERSION" docs/build.md
```

Expected: 每个 grep 至少返回 1（新加的内容 + 可能还有原有的）。具体数字不重要，非零就行。

- [ ] **Step 4.5: Commit**

```bash
git add docs/build.md
git commit -m "$(cat <<'EOF'
docs(build): document commit-driven release flow

Release 流程 section now leads with the new auto-tag path
(bump MARKETING_VERSION → push master → CI tags and releases).
Manual git tag path kept as emergency fallback.
EOF
)"
```

---

## Task 5: 更新 `CLAUDE.md` Common Tasks 表格

**Files:**
- Modify: `CLAUDE.md` (Common Tasks table, around line 115-128)

- [ ] **Step 5.1: 定位 Common Tasks 里 "改发布流水线" 那一行**

```bash
grep -n "改发布流水线" CLAUDE.md
```

Expected: 一行命中（约 line 120）。新增的"发新版本"一行放在它**正下方**，因为概念相邻。

- [ ] **Step 5.2: 插入新行**

用 Edit 工具在：

```
| 改发布流水线 / appcast 格式 | `.github/workflows/release.yml`, `.github/scripts/render-appcast.sh`, `docs/build.md` |
```

下方（同一表格内）插入一行，变成：

```
| 改发布流水线 / appcast 格式 | `.github/workflows/release.yml`, `.github/scripts/render-appcast.sh`, `docs/build.md` |
| 发新版本 | 改 `project.yml` 的 `MARKETING_VERSION` → commit → push master（自动 bump build + tag + 发版，详见 `docs/build.md#release-流程`） |
```

- [ ] **Step 5.3: 验证表格格式没坏**

```bash
grep -A 1 "改发布流水线" CLAUDE.md | head -2
```

Expected: 第一行是"改发布流水线"那行，第二行是新加的"发新版本"那行。两行的竖线对齐不需要完美 —— markdown 表格不要求。

- [ ] **Step 5.4: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: add '发新版本' to CLAUDE.md Common Tasks

Points to the new commit-driven release flow documented in docs/build.md.
EOF
)"
```

---

## Task 6: 最终检查

- [ ] **Step 6.1: 跑文档漂移检查**

```bash
cd /Users/zhenghui/Documents/repos/theall
./scripts/check-doc-drift.sh
```

Expected: 无输出或打印"OK/无漂移"之类。本次 PR 没改 `TheAll/` 目录结构，应该通过。如果报漂移，看错误信息 —— 通常是 CLAUDE.md 的 Directory Structure 跟磁盘不一致，跟本次改动无关的话先跳过，有关就修。

- [ ] **Step 6.2: 看一遍本分支的 commit 历史**

```bash
git log --oneline master..HEAD
```

Expected: 5 个新 commit，按顺序：

```
<sha> docs: add '发新版本' to CLAUDE.md Common Tasks
<sha> docs(build): document commit-driven release flow
<sha> build(ci): add auto-tag workflow for commit-driven releases
<sha> build(ci): use cliff.toml in release changelog
<sha> build(ci): add cliff.toml for grouped changelog
```

（顺序是反着的，最新的在上。）

spec commit（`docs(build): design auto release from MARKETING_VERSION changes`）已在执行本 plan 之前被合入，也会出现在 `git log` 里。

- [ ] **Step 6.3: 验证没有意外改动**

```bash
git diff master..HEAD --stat
```

Expected 文件清单（大小仅示意）：

```
 .github/workflows/auto-tag.yml            | 80+ ++++
 .github/workflows/release.yml             |  2 +-
 CLAUDE.md                                 |  1 +
 cliff.toml                                | 22 +++
 docs/build.md                             | 30+ ++++--
 docs/2026-04-19-auto-release-from-commits-design.md  | 219 +++   # spec, 已存在
 docs/superpowers/plans/2026-04-19-auto-release-from-commits.md  | <本文件>
```

**不应该**出现：`project.yml`、`TheAll.xcodeproj/`、`TheAll/` 下的 Swift 文件、`scripts/` 下的 shell 脚本、`Vendor/`。如果有，检查是不是执行步骤时误改了。

- [ ] **Step 6.4: 本地模拟 auto-tag.yml 的"不应触发"分支（smoke test）**

本地没法跑 GitHub Actions，但可以手动跑 workflow 的核心逻辑（bash 部分），验证关键守护在本机的 project.yml 上不会错误触发。

场景 A：假设当前 HEAD 没改 `MARKETING_VERSION`（执行计划的这些 commit 都没动 project.yml），干跑：

```bash
cd /Users/zhenghui/Documents/repos/theall
NEW=$(grep -E '^ +MARKETING_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
OLD=$(git show HEAD^:project.yml 2>/dev/null | grep -E '^ +MARKETING_VERSION:' | awk '{print $2}' | tr -d '"' || echo "")
echo "NEW='$NEW' OLD='$OLD'"
[ "$NEW" = "$OLD" ] && echo "would skip (correct)" || echo "would tag (wrong for this commit)"
```

Expected: `NEW='0.1.0' OLD='0.1.0'` and `would skip (correct)`。因为本 plan 不改 MARKETING_VERSION。

- [ ] **Step 6.5: 不 commit**

Task 6 不产生 commit。本步骤存在是为了执行 plan 的 agent 不会想着"要不要 commit 一下 Task 6"。

---

## 合并后验证（人工，不属于 plan 自动步骤）

这些步骤在 PR 合进 master 之后由人工触发，属于 spec 里 Test Plan 的实现。不写成 plan 的 checkbox，因为它们跨 PR 边界。

1. **首次真实发版（smoke）**：新开 PR，只改 `project.yml` 的 `MARKETING_VERSION: 0.1.0 → 0.2.0`，merge 后观察：
   - auto-tag.yml 成功跑完
   - master 多了一个 `chore(release): bump build to 2 for v0.2.0 [skip auto-tag]` commit
   - 有新 tag `v0.2.0`
   - release.yml 被 tag push 触发并成功发 Release
   - Release 页的 note 是按 `### Features` 等分组的 markdown
2. **版本回滚守护**：临时 PR bump 到一个小于当前的版本（比如 0.0.9），验证 auto-tag.yml fail 并打印清晰错误。**验证完不合并**。
3. **`[skip auto-tag]` 递归防护**：手动构造一个只改 `project.yml` 的 commit（比如改注释），message 写 `chore: test [skip auto-tag]`，push，验证 workflow 启动但 step 2 early-exit。验证完 revert。

---

## Self-Review

### 1. Spec coverage

| Spec 要点 | 对应 Task |
|-----------|-----------|
| auto-tag.yml 新增，检测 MARKETING_VERSION | Task 3 |
| 自动 bump CURRENT_PROJECT_VERSION | Task 3 (step 3.1 sed) |
| Commit + tag + push | Task 3 (step 3.1 final step) |
| `[skip auto-tag]` 递归防护 + 不用 `[skip ci]` | Task 3 (step 3.1 `check_skip`, step 3.3 验证) |
| paths 过滤 `project.yml` | Task 3 (step 3.1) |
| 版本回滚守护（sort -V） | Task 3 (step 3.1 decide) |
| tag 已存在守护 | Task 3 (step 3.1 decide) |
| cliff.toml 配置 | Task 1 |
| release.yml 接入 cliff.toml | Task 2 |
| docs/build.md 双路径说明 | Task 4 |
| CLAUDE.md Common Tasks 加行 | Task 5 |
| master 无 protection 假设 | Pre-Flight Assumptions |
| 文档漂移检查 | Task 6 (step 6.1) |
| Test Plan | "合并后验证" 小节 |

无 gap。

### 2. Placeholder scan

无 "TBD" / "TODO" / "implement later"。每个代码步骤都有完整内容。每个验证步骤都有具体命令和 expected 输出。

### 3. Type consistency

- output name 统一：`check_skip` / `versions` / `decide`（step id 没有下划线 / 连字符混用）
- commit message 统一格式：`type(scope): description`
- `[skip auto-tag]` 在 spec、workflow、docs 三处拼写一致
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 全大写下划线，未出现别名

无 inconsistency。
