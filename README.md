# Sticky

Sticky 是一个轻量的 macOS 菜单栏待办应用，支持全局快捷键、多个标签、Apple 提醒事项，以及与 Obsidian Markdown 的双向同步。

## 下载与使用

1. 在仓库右侧打开 **Releases**，下载 `Sticky-macOS-universal.zip`。
2. 解压后将 `Sticky.app` 拖入“应用程序”。
3. 第一次启动时右键点按 App，选择“打开”。
4. 使用 `⌥⌘S` 在任何应用中显示或隐藏 Sticky。

支持 macOS 14 或更高版本，并同时支持 Apple 芯片与 Intel Mac。

## 功能

- 全局快捷键呼出或隐藏悬浮窗。
- 多标签管理；可拖动标签排序，并根据位置自动显示协调的优先级颜色。
- 粉、蓝、绿三套主题色。
- 每个标签内自动将未完成事项排在已完成事项之前。
- 新增、编辑、删除、完成、拖动事项，并支持备注、提示音、彩纸反馈和删除撤销。
- 可为单个事项建立 Apple 提醒事项；不可用时回退到本地通知。
- 与 Obsidian Markdown 双向同步，包括标签、事项、完成状态及标题/文件名。
- 本地数据保存与最近一次成功数据备份。

## Obsidian 连接

首次运行时，默认同步文件为：

```text
~/Documents/Sticky/Floating Todo.md
```

若要连接自己的 Obsidian 库，请创建或编辑：

```text
~/.floating-todo/config.json
```

示例：

```json
{
  "obsidianMarkdownPath": "/Users/你的用户名/Obsidian/Sticky/Floating Todo.md"
}
```

Sticky 会在安全标记范围内更新任务，并监听 Obsidian 中的改动。标题改名时，对应的 Markdown 文件名也会同步调整。

## Apple 提醒事项

第一次添加提醒时，请允许 Sticky 访问“提醒事项”和发送通知。若曾拒绝，可在“系统设置 → 隐私与安全性 → 提醒事项”中重新开启。

## 从源码安装

需要 Xcode Command Line Tools：

```bash
git clone https://github.com/Shweh00/Sticky.git
cd Sticky
./script/install_swift_app.sh
```

安装脚本会构建 Intel 与 Apple 芯片通用版本、本地签名，并安装到 `/Applications/Sticky.app`。已有版本会先安全移入废纸篓备份。

## 数据安全

本地数据与备份分别保存在：

```text
~/.floating-todo/todos.json
~/.floating-todo/todos.json.bak
```

这些个人数据不会包含在仓库或发布安装包中。

## License

MIT
