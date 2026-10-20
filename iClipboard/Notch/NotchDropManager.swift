//
//  NotchDropManager.swift
//  iClipboard
//
//  Created by tenom on 2026/04/11.
//

import AppKit

/// 刘海区域拖拽管理器
/// 负责创建覆盖刘海区域的透明窗口，监听全局拖拽事件，
/// 在用户拖拽文件时显示 drop zone，放置后触发 AirDrop。
final class NotchDropManager {
    
    static let shared = NotchDropManager()
    
    // MARK: - Properties
    
    /// Drop zone 覆盖窗口
    private var dropWindow: NSWindow?
    
    /// Drop zone 视图
    private var dropZoneView: NotchDropZoneView?
    
    /// 全局拖拽事件监听器
    private var dragMonitor: Any?
    
    /// 全局鼠标松开事件监听器
    private var mouseUpMonitor: Any?
    
    /// 拖拽粘贴板，用于检测拖拽会话
    private let dragPasteboard = NSPasteboard(name: .drag)
    
    /// 上一次检测到的 changeCount
    private var lastChangeCount: Int = 0
    
    /// 当前是否有活跃的拖拽会话
    private var isDragSessionActive = false
    private var isMonitoring = false
    private var presentationSuspensions = Set<UUID>()
    private var restoreVisibleDropZone = false
    private var presentationID = UUID()
    
    /// drop zone 窗口的宽高
    private let dropZoneWidth: CGFloat = 180
    private let dropZoneHeight: CGFloat = 50
    
    private init() {}
    
    // MARK: - Public API
    
    /// 开始监听全局拖拽，应在 applicationDidFinishLaunching 中调用
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        setupDropWindow()
        if presentationSuspensions.isEmpty {
            startGlobalDragMonitoring()
        }
        
        // 监听屏幕参数变化（如外接显示器插拔），重新计算位置
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        print("[NotchDropManager] 监听已启动")
    }
    
    /// 停止监听
    func stopMonitoring() {
        isMonitoring = false
        isDragSessionActive = false
        restoreVisibleDropZone = false
        presentationID = UUID()
        stopGlobalDragMonitoring()
        dropWindow?.orderOut(nil)
        dropWindow = nil
        dropZoneView = nil
        
        NotificationCenter.default.removeObserver(self)
        
        print("[NotchDropManager] 监听已停止")
    }
    
    /// Temporarily remove both global listeners and the overlay, without stopping the owner.
    @MainActor
    func suspendPresentation() -> @MainActor () -> Void {
        let token = UUID()
        if presentationSuspensions.isEmpty {
            restoreVisibleDropZone = dropWindow?.isVisible == true && isDragSessionActive
            presentationID = UUID()
            stopGlobalDragMonitoring()
            dropWindow?.orderOut(nil)
        }
        presentationSuspensions.insert(token)
        return { [weak self] in
            guard let self, self.presentationSuspensions.remove(token) != nil,
                  self.presentationSuspensions.isEmpty else { return }
            guard self.isMonitoring else {
                self.restoreVisibleDropZone = false
                return
            }
            // Don't resurrect a drag which ended while the screenshot UI owned the mouse.
            let dragStillActive = self.isDragSessionActive
                && NSEvent.pressedMouseButtons & 1 != 0
                && self.lastChangeCount == self.dragPasteboard.changeCount
            self.isDragSessionActive = dragStillActive
            self.startGlobalDragMonitoring()
            if self.restoreVisibleDropZone, dragStillActive {
                self.dropWindow?.setFrame(self.calculateDropZoneFrame(), display: true)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    self.dropWindow?.animator().alphaValue = 1
                }
                self.dropWindow?.orderFront(nil)
            }
            self.restoreVisibleDropZone = false
        }
    }

    // MARK: - Drop Window Setup
    
    private func setupDropWindow() {
        let frame = calculateDropZoneFrame()
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        window.level = .statusBar + 1  // 在菜单栏之上
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        
        // 创建 drop zone 视图
        let zoneView = NotchDropZoneView(frame: NSRect(origin: .zero, size: frame.size))
        zoneView.autoresizingMask = [.width, .height]
        window.contentView = zoneView
        
        self.dropZoneView = zoneView
        self.dropWindow = window
        
        // 初始隐藏
        window.orderOut(nil)
    }
    
    /// 计算刘海区域 drop zone 的位置（紧贴菜单栏下方，避免被刘海遮挡）
    private func calculateDropZoneFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: dropZoneWidth, height: dropZoneHeight)
        }
        
        // visibleFrame.maxY 就是菜单栏底边的 y 坐标
        // 将 drop zone 放在菜单栏正下方
        let x = screen.frame.midX - dropZoneWidth / 2
        let y = screen.visibleFrame.maxY - dropZoneHeight
        
        return NSRect(x: x, y: y, width: dropZoneWidth, height: dropZoneHeight)
    }
    
    // MARK: - Global Drag Monitoring
    
    private func startGlobalDragMonitoring() {
        guard isMonitoring, presentationSuspensions.isEmpty,
              dragMonitor == nil, mouseUpMonitor == nil else { return }
        lastChangeCount = dragPasteboard.changeCount
        
        // 监听全局拖拽事件
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.handleGlobalDrag(event)
        }
        
        // 监听鼠标松开，结束拖拽会话
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handleGlobalMouseUp(event)
        }
    }
    
    private func stopGlobalDragMonitoring() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }
    
    private func handleGlobalDrag(_ event: NSEvent) {
        guard isMonitoring, presentationSuspensions.isEmpty else { return }
        let currentChangeCount = dragPasteboard.changeCount
        
        // 检测到新的拖拽会话（pasteboard changeCount 变化）
        if currentChangeCount != lastChangeCount {
            lastChangeCount = currentChangeCount
            
            // 检查是否包含文件 URL
            if dragPasteboard.canReadObject(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) {
                activateDragSession()
            }
        }
    }
    
    private func handleGlobalMouseUp(_ event: NSEvent) {
        guard isMonitoring, presentationSuspensions.isEmpty else { return }
        if isDragSessionActive {
            let id = presentationID
            // 稍微延迟隐藏，给 performDragOperation 留时间执行
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.presentationID == id,
                      self.presentationSuspensions.isEmpty else { return }
                self.deactivateDragSession()
            }
        }
    }
    
    // MARK: - Session Management
    
    private func activateDragSession() {
        guard isMonitoring, presentationSuspensions.isEmpty, !isDragSessionActive else { return }
        presentationID = UUID()
        isDragSessionActive = true
        
        // 更新窗口位置（可能屏幕配置变了）
        dropWindow?.setFrame(calculateDropZoneFrame(), display: true)
        
        // 显示 drop zone
        dropWindow?.orderFront(nil)
        
        // 渐显动画
        dropWindow?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropWindow?.animator().alphaValue = 1.0
        }
        
        print("[NotchDropManager] Drop zone 已激活")
    }
    
    private func deactivateDragSession() {
        guard isDragSessionActive else { return }
        isDragSessionActive = false
        let dismissalID = UUID()
        presentationID = dismissalID
        guard presentationSuspensions.isEmpty else { return }

        // 渐隐动画后隐藏
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dropWindow?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentationID == dismissalID,
                  self.presentationSuspensions.isEmpty else { return }
            self.dropWindow?.orderOut(nil)
            self.dropWindow?.alphaValue = 1.0
        })
        
        print("[NotchDropManager] Drop zone 已隐藏")
    }
    
    // MARK: - Screen Changes
    
    @objc private func screenParametersChanged() {
        let newFrame = calculateDropZoneFrame()
        dropWindow?.setFrame(newFrame, display: true)
        print("[NotchDropManager] 屏幕参数变化，已更新 drop zone 位置")
    }
}
