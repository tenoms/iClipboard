# <img width="64" height="64" alt="icon_64" src="https://github.com/user-attachments/assets/66cb9df3-5696-461a-a289-a86a89b2f848" /> iClipboard for macOS

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg) ![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)

iClipboard 一个小巧精致的 macOS 剪贴板管理工具。

[English Documentation](README_EN.md)

---

## ✨ 功能特性

- **📋 历史记录**: 自动记录复制过的内容。
- **📂 智能分类**:
  - 自动将内容识别为 **文本** 📄、**图片** 🖼️ 或 **文件** 📁。
  - 创建 **收藏列表** ⭐ 来归档和管理重要内容。
- **🔍 便捷搜索**: 通过全局搜索栏快速找到您需要的内容。
- **👁️ 快速预览**: 
  - **右键点击** 任意文本条目，即可打开详细的预览窗口。
  - 富文本显示支持。
- **🎨 现代自适应 UI**:
  - **主题切换**: 支持浅色、深色及跟随系统模式。
  - **可调整面板**: 自由调整喜欢的面板宽度。
- **📊 数据管理**:
  - **收藏导出**: 收藏文本导出为 JSON 文件。
- **⚙️ 个性化**:
  - **全局快捷键**: 随时随地瞬间唤出面板。
  - **捕获控制**: 精细控制文本、富文本、图片和文件的捕获开关。
  - **历史记录限制**: 自定义保留的条目数量，高效管理存储空间。
  - **窗口置顶**: 点击 Pin 保持窗口悬浮，方便对照使用。

## 🛠️系统要求

- macOS 13.6 或更高版本
- Xcode 15+ (用于源码构建)

## 📦 安装说明

### 源码构建
1. 克隆仓库:
   ```bash
   git clone https://github.com/tenoms/iClipboard.git
   ```
2. 在 Xcode 中打开 `iClipboard.xcodeproj`。
3. 构建并运行 (Cmd+R)。

## 💡 使用指南

### 基础操作
- **打开**: 点击菜单栏图标 📋 唤出面板。
- **复制**: 点击列表中的任意条目，即可将其重新复制到剪贴板。
- **固定窗口**: 点击顶部的 **Pin** 图标 📌，可保持窗口持久显示。

### 进阶功能
- **预览**: **右键点击** 文本条目，可打开独立的大窗口进行查看。
- **删除**: 鼠标悬停在条目上，点击 **垃圾桶** 图标 🗑️ 即可删除。顶部提供“全部清除”功能。
- **收藏**: 点击 **星标** 图标 ⭐ 将条目加入收藏列表。

## 🖼️ 预览

<img src="https://github.com/user-attachments/assets/62f196a2-7fe3-475e-9519-d6536f088a92" alt="fig1" width="900" />

<img src="https://github.com/user-attachments/assets/9a65bdef-bec0-4b7f-9923-332ce74f0122" alt="fig2" width="900" />

<img src="https://github.com/user-attachments/assets/d47f2480-7f66-46ca-92e7-11d26782cf92" alt="fig3" width="900" />

## 👨‍💻 开发者

- Gemini 3.0 Pro
- GPT-5.1-Codex-Max

## 🤝 贡献代码

欢迎提交 Pull Request 来改进这个项目！
