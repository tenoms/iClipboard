//
//  AirDropService.swift
//  iClipboard
//
//  Created by tenom on 2026/04/11.
//

import AppKit

/// AirDrop 服务封装，负责调用系统 AirDrop 共享面板
final class AirDropService: NSObject, NSSharingServiceDelegate {
    
    static let shared = AirDropService()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// 通过 AirDrop 共享文件
    /// - Parameter fileURLs: 要共享的本地文件 URL 数组
    func share(fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            showAirDropUnavailableAlert()
            return
        }
        
        service.delegate = self
        
        let items: [Any] = fileURLs
        
        if service.canPerform(withItems: items) {
            service.perform(withItems: items)
        } else {
            showAirDropUnavailableAlert()
        }
    }
    
    // MARK: - NSSharingServiceDelegate
    
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("[AirDropService] 共享成功")
    }
    
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        print("[AirDropService] 共享失败: \(error.localizedDescription)")
    }
    
    // MARK: - Private
    
    private func showAirDropUnavailableAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "AirDrop 不可用"
            alert.informativeText = "请确保 Wi-Fi 和蓝牙已开启，并且 AirDrop 已启用。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
}
