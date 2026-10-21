# <img width="32" height="32" alt="icon_64" src="https://github.com/user-attachments/assets/66cb9df3-5696-461a-a289-a86a89b2f848" /> iClipboard for macOS

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg) ![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)

iClipboard is a simple and exquisite macOS clipboard management tool.

[中文文档 (Chinese)](README.md)

---

## ✨ Features

- **📋 History**: Automatically records copied content.
- **📂 Smart Organization**:
  - Automatically categorizes items into **Text** 📄, **Images** 🖼️, and **Files** 📁.
  - Create **Favorites Lists** ⭐ to pin and organize important clippings.
- **🔍 Convenient Search**: Quickly find what you need with the global search bar.
- **👁️ Quick Preview**: 
  - **Right-click** on any text item to open a detailed preview window.
  - Rich text display support.
- **🎨 Modern Adaptive UI**:
  - **Theme Switcher**: Support for Light, Dark, and System modes.
  - **Resizable Panel**: Freely adjust the panel width.
- **📊 Data Management**:
  - **Export Favorites**: Export favorite text items as JSON files.
- **🪄 AirDrop Quick Share**:
  - Drag files to the notch area at the top of the screen to instantly open the AirDrop sharing panel.
  - Supports dragging and sharing multiple files at once.
- **🧩 Notch-Hidden Menu Bar Items**:
  - Access app menu bar items that become unreachable behind the notch when space is limited on a notched MacBook.
  - Right-click the iClipboard menu bar icon to list them. Click an item to activate it, or **Option-click** to try to open its menu.
  - Requires Accessibility permission for iClipboard.
- **📷 Image Tools**:
  - **Capture and annotate**: Select a region, window, or interface element; add shapes, arrows, text, freehand drawings, and pixelation, with undo and redo.
  - **Floating images**: Pin screenshots or clipboard images on screen, with multiple pins, proportional resizing, adjustable opacity, and always-on-top controls.
  - **Extract image text**: Select text directly on supported devices or copy all image text at once. Recognition runs on your Mac without uploading images.
  - **Pick colors and save**: Inspect magnified pixels, copy HEX colors, and copy images to the clipboard or save them as PNG.
- **⚙️ Personalization**:
  - **Global Shortcut**: Toggle the panel instantly from anywhere.
  - **Capture Control**: Granular toggles for Text, Rich Text, Image, and File capture.
  - **History Limit**: Customize how many items to keep to manage storage.
  - **Pin to Top**: Keep the window floating for reference.

## 🛠️ Requirements

- macOS 13.6 or later
- Xcode 15+ (for building from source)

## 📦 Installation

### From Source
1. Clone the repository:
   ```bash
   git clone https://github.com/tenoms/iClipboard.git
   ```
2. Open `iClipboard.xcodeproj` in Xcode.
3. Build and run (Cmd+R).

## 💡 Usage Guide

### Basics
- **Access**: Click the menu bar icon 📋 to open the panel.
- **Copy**: Click on any item in the list to copy it back to your clipboard.
- **Pin**: Click the **Pin** icon 📌 in the header to keep the window permanently visible.

### Image Tools
- **Start a capture**: Right-click the menu bar icon and choose the region capture action, use the image tools menu at the bottom of the panel, or set your own capture shortcut. Drag to select a region; press `Esc` to cancel.
- **Smart selection**: Choose None, Windows, or Elements in settings. When enabled, click a highlighted area to select the corresponding window or interface element.
- **Annotate and export**: Use the selection toolbar to add annotations, then copy, save, or pin the result. The toolbar appears near where you finish selecting; drag its background or status text to move it out of the way.
- **Extract text**: On supported devices, select image text and press `⌘C` to copy it. Use the full-text copy button or your configured shortcut to extract all text from a capture selection or the current pin.
- **Use floating images**: Pin a clipboard image from the menu bar, or pin a selection from the capture toolbar. Drag blank space, or hold `Option` while dragging the image, to move it. Resize from an edge or corner, or use the mouse wheel. Toolbar controls adjust opacity, toggle always-on-top, and close a pin; the menu bar context menu can show, hide, or close all pins.
- **Pick colors**: During capture, move the pointer to inspect a magnified pixel preview and right-click to copy its HEX color. After selecting a region, hold `Option` to view the pixel preview.
- **Save images**: Set a default save folder for direct saving, or choose a destination each time. PNG files receive automatic names without overwriting existing files. You can also right-click an image in history to edit, pin, or save it.

Screen Recording permission is required for the first capture. Image text recognition works locally and offline, without a login or image uploads. Scrolling screenshots, GIF, and video recording are not supported.

### Advanced Actions
- **Preview**: **Right-click** on a text item to view it in a large independent window.
- **Delete**: Hover over an item and click the **Trash** icon 🗑️ to remove it. "Delete All" is available in the header.
- **Favorites**: Click the **Star** icon ⭐ to add an item to a list.
- **Use items hidden behind the notch**: **Right-click** the iClipboard menu bar icon, then select the otherwise unreachable app item. **Option-click** an item to try to open its menu directly.

## 🖼️ Preview

<img src="https://github.com/user-attachments/assets/62f196a2-7fe3-475e-9519-d6536f088a92" alt="fig1" width="900" />

<img src="https://github.com/user-attachments/assets/9a65bdef-bec0-4b7f-9923-332ce74f0122" alt="fig2" width="900" />

<img src="https://github.com/user-attachments/assets/d47f2480-7f66-46ca-92e7-11d26782cf92" alt="fig3" width="900" />

## 👨‍💻 Developers

- Gemini 3.0 Pro
- GPT-5.1-Codex-Max

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
