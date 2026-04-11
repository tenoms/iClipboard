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
    
    /// drop zone 窗口的宽高
    private let dropZoneWidth: CGFloat = 180
    private let dropZoneHeight: CGFloat = 50
    
    private init() {}
    
    // MARK: - Public API
    
    /// 开始监听全局拖拽，应在 applicationDidFinishLaunching 中调用
    func startMonitoring() {
        setupDropWindow()
        startGlobalDragMonitoring()
        
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
        stopGlobalDragMonitoring()
        dropWindow?.orderOut(nil)
        dropWindow = nil
        dropZoneView = nil
        
        NotificationCenter.default.removeObserver(self)
        
        print("[NotchDropManager] 监听已停止")
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
    
    /// 计算刘海区域 drop zone 的位置
    private func calculateDropZoneFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: dropZoneWidth, height: dropZoneHeight)
        }
        
        // 菜单栏高度 = 屏幕总高度 - visibleFrame 可用高度 - visibleFrame 底部偏移
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height
            - (screen.visibleFrame.origin.y - screen.frame.origin.y)
        
        // 确保高度至少为 dropZoneHeight
        let height = max(menuBarHeight, dropZoneHeight)
        
        // 水平居中
        let x = screen.frame.midX - dropZoneWidth / 2
        
        // 紧贴屏幕顶部
        let y = screen.frame.maxY - height
        
        return NSRect(x: x, y: y, width: dropZoneWidth, height: height)
    }
    
    // MARK: - Global Drag Monitoring
    
    private func startGlobalDragMonitoring() {
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
        if isDragSessionActive {
            // 稍微延迟隐藏，给 performDragOperation 留时间执行
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.deactivateDragSession()
            }
        }
    }
    
    // MARK: - Session Management
    
    private func activateDragSession() {
        guard !isDragSessionActive else { return }
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
        
        // 渐隐动画后隐藏
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dropWindow?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dropWindow?.orderOut(nil)
            self?.dropWindow?.alphaValue = 1.0
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
