//
//  NotchDropZoneView.swift
//  iClipboard
//
//  Created by tenom on 2026/04/11.
//

import SwiftUI
import AppKit

// MARK: - SwiftUI Drop Zone Visual

/// SwiftUI 视图：刘海区域的拖拽 drop zone 视觉反馈
struct NotchDropZoneContentView: View {
    @Binding var isDragHovering: Bool
    
    var body: some View {
        ZStack {
            // 背景高亮
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    isDragHovering
                    ? Color.blue.opacity(0.35)
                    : Color.white.opacity(0.08)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            isDragHovering
                            ? Color.blue.opacity(0.8)
                            : Color.white.opacity(0.2),
                            lineWidth: 1.5
                        )
                )
            
            // AirDrop 图标 + 文字
            VStack(spacing: 4) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isDragHovering ? .white : .white.opacity(0.7))
                    .scaleEffect(isDragHovering ? 1.15 : 1.0)
                
                Text("AirDrop")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isDragHovering ? .white : .white.opacity(0.6))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragHovering)
    }
}

// MARK: - NSView Drop Zone

/// NSView 子类，作为拖拽目标，接收文件放置并触发 AirDrop
final class NotchDropZoneView: NSView {
    
    /// 当文件进入/离开 drop zone 时回调
    var onDragHoverChanged: ((Bool) -> Void)?
    
    private var hostingView: NSHostingView<NotchDropZoneContentView>?
    @objc dynamic var isDragHovering = false
    
    // 为 SwiftUI 绑定提供桥梁
    private class HoverState: ObservableObject {
        @Published var isHovering = false
    }
    private let hoverState = HoverState()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        
        // 注册接受文件 URL 拖拽
        registerForDraggedTypes([.fileURL])
        
        // 嵌入 SwiftUI 视觉内容
        let binding = Binding<Bool>(
            get: { [weak self] in self?.hoverState.isHovering ?? false },
            set: { [weak self] in self?.hoverState.isHovering = $0 }
        )
        let contentView = NotchDropZoneContentView(isDragHovering: binding)
        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hosting.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        
        self.hostingView = hosting
    }
    
    // MARK: - NSDraggingDestination
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender) else { return [] }
        setHovering(true)
        return .copy
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender) else { return [] }
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHovering(false)
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return hasFileURLs(sender)
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHovering(false)
        
        guard let urls = extractFileURLs(from: sender), !urls.isEmpty else {
            return false
        }
        
        print("[NotchDropZone] 收到 \(urls.count) 个文件，发起 AirDrop")
        
        // 延迟一小点触发 AirDrop，让 drop 动画完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AirDropService.shared.share(fileURLs: urls)
        }
        
        return true
    }
    
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setHovering(false)
    }
    
    // MARK: - Helpers
    
    private func setHovering(_ hovering: Bool) {
        isDragHovering = hovering
        hoverState.isHovering = hovering
        onDragHoverChanged?(hovering)
    }
    
    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])
    }
    
    private func extractFileURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return nil
        }
        return items
    }
}
