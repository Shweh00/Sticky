# Sticky 发布流程

本仓库的 `main` 分支和 [Shweh00/Sticky](https://github.com/Shweh00/Sticky) 是 Sticky 的权威源码。发布只包含源码构建出的 App；个人待办、Obsidian 笔记和本机配置不得进入 Git 或安装包。

## 1. 开始更新

```bash
git switch main
git pull --ff-only origin main
git switch -c update/<简短名称>
```

修改前确认 `git status --short` 没有意外文件。功能完成后运行：

```bash
swift build
git diff --check
```

需要在本机真实使用环境中验收时运行：

```bash
./script/install_swift_app.sh
```

安装脚本会把现有 `/Applications/Sticky.app` 移入废纸篓备份，再安装并启动新版本；它不会删除 `~/.floating-todo/` 中的待办数据。

## 2. 准备版本

发布前在 `Info.plist` 中同步更新：

- `CFBundleShortVersionString`：面向用户的版本，例如 `1.0.1`。
- `CFBundleVersion`：本次构建编号。

提交经验证的源码并合并到 `main`，然后确认工作区干净：

```bash
git switch main
git pull --ff-only origin main
git status --short
```

## 3. 构建通用安装包

```bash
./script/package_release.sh
```

脚本会自动完成：

- 检查 Git 工作区和个人数据隔离。
- 分别构建 Apple 芯片与 Intel 版本。
- 合并为 Universal Binary。
- 组装并进行本地签名。
- 校验架构、签名、Info.plist 和 ZIP 完整性。
- 在 `dist/` 生成 ZIP 与 SHA-256 校验文件。

## 4. 发布 GitHub Release

下面的版本号和文件名以打包脚本输出为准：

```bash
git tag v1.0.1
git push origin main v1.0.1
gh release create v1.0.1 \
  dist/Sticky-1.0.1-macOS-universal.zip \
  dist/Sticky-1.0.1-macOS-universal.zip.sha256 \
  --repo Shweh00/Sticky \
  --title "Sticky 1.0.1" \
  --notes "说明本次用户可感知的变化和验证结果。"
```

发布后从 Release 页面重新下载一次，并运行：

```bash
shasum -a 256 -c Sticky-1.0.1-macOS-universal.zip.sha256
unzip -t Sticky-1.0.1-macOS-universal.zip
```

## 数据保护边界

以下内容只属于本机运行数据，任何时候都不能加入公开仓库或 Release：

- `~/.floating-todo/todos.json`
- `~/.floating-todo/todos.json.bak`
- `~/.floating-todo/config.json`
- Obsidian 中由 Sticky 生成的个人索引与标签笔记

发布前不要使用未经检查的 `git add -A`。应先查看 `git status --short`，再明确添加本次修改的文件。
