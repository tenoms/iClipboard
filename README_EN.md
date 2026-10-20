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
  - Region capture, shapes/arrows/text/pixelation, undo/redo, and full-resolution PNG output.
  - Independent pinned images with scaling, opacity, always-on-top, editing, and OCR.
  - In-place text selection with system Live Text and offline recognition through Apple Vision, without a separate OCR window. Screen and image color picking.
  - Original images stored separately from lightweight history thumbnails. See the [image tools guide (Chinese)](docs/IMAGE_TOOLS.md).
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

### Image Workflow
- Open capture and pinning from the menu bar context menu or the history footer. Finish captures in place with a toolbar below the selection, without opening an editor window. The redundant capture-and-OCR menu entry has been removed.
- On supported devices, select recognized text and use `⌘C` to copy it. With no text selection, `⌘C` copies the image. Text and drawing annotations neither rerun OCR nor become part of the captured transcript; mosaic changes update recognition from the redacted source.
- During capture, the pin shortcut pins the current selection and exits. The configurable action “复制图像全文” (Copy Image Full Text, formerly Recognize Screen Text) copies an existing capture selection and exits, or copies all text from the focused pin without closing it. It preserves the existing binding but handles it locally in the relevant window, never reserves a global key, and leaves combinations such as `Shift+C` available for typing elsewhere. It never starts a capture and adds no hardcoded `⌘⇧C` binding. Right-click screenshot pixels to pick a color.
- Pinned images support in-place text selection with `⌘C`; full-text copying uses the same configured action and only the pin with keyboard focus. Drag blank pixels or hold Option to move a pin; scroll to resize it. Smaller pins hide their toolbar and restore it when enlarged. There is no built-in `⌘W` close binding. The configurable close-pin shortcut is window-local and only closes the pin with keyboard focus, never a hovered or recent pin. The close button and Escape remain available.
- Configured save folders enable direct saving without a panel; unconfigured saves still ask for a destination. Filenames use `iclipboard_yyMMdd_HHmmss.png` with no-overwrite collision handling.
- UI detection supports None, Windows, and Elements (default: Windows); pixel/color previews are integrated into capture.
- Captured pins retain the selection's on-screen size. Shortcut recording accepts modified Escape without a manual combination picker. Only history, capture, and pinning use global Carbon registration; full-text copying and closing a pin use window-local shortcuts.
- Right-click an image history entry to edit, pin, or save PNG. Text is selected directly in captures and pins; the recognize-text menu and standalone OCR window have been removed. Font-size, stroke-width, and mosaic sliders display live numeric values.
- Screen actions request Screen Recording permission on first use. Existing-image OCR runs locally without login or image uploads. Global text-selection translation remains a separate feature.
- Scrolling screenshots, GIF, and video recording are not included.

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
