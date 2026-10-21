import AppKit
import SwiftUI

@MainActor
struct ImageToolsSettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject private var preferences = ImageToolsPreferences.shared
    @ObservedObject private var accessibility = AccessibilityAuthorizationService.shared
    @StateObject private var screenPermission = ScreenCapturePermissionController()
    @State private var directoryWarning: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionSection
                ThemeDivider()
                saveDirectorySection
                ThemeDivider()
                detectionSection
                ThemeDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("隐私与历史记录", systemImage: "lock.shield")
                        .font(.headline)
                    Text("截图、标注、取色和文字识别均在本机完成，不上传图片。")
                    Text("复制、保存或贴图后的图片会加入历史记录。收藏图片不会因历史条数限制被删除。")
                }
                .foregroundStyle(palette.secondaryText)
                ThemeDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("使用提示", systemImage: "cursorarrow")
                        .font(.headline)
                    Text("截图后可标注、复制、保存或贴图。Enter 复制图片，Esc 取消截图。")
                    Text("拖动工具栏的空白处或状态文字，可移开被遮挡的位置。")
                    Text("在支持的设备上，划选图片文字后按 ⌘C 复制；也可使用“复制图像全文”快捷键。")
                    Text("贴图可拖动边缘或滚动缩放，按住 Option 拖动移动。关闭快捷键可在“快捷键”中设置。")
                    Text("截图时右键复制色值；框选后按住 Option 查看像素预览。")
                }
                .foregroundStyle(palette.secondaryText)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .onAppear { refreshStatus() }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("屏幕录制权限", systemImage: "rectangle.dashed.badge.record")
                    .font(.headline)
                Spacer(minLength: 8)
                Toggle("屏幕录制权限", isOn: Binding(
                    get: { screenPermission.hasAccess },
                    set: { screenPermission.setAccessRequested($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text(screenPermission.hasAccess
                 ? "已授权，可截图和屏幕取色。"
                 : "截图和屏幕取色需要此权限。编辑、贴图或识别已有图片无需授权。")
                .foregroundStyle(palette.secondaryText)
            Text("关闭权限需前往系统设置。更改授权后可能需要重新启动应用。")
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var saveDirectorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("默认保存位置", systemImage: "folder")
                .font(.headline)
            Text(preferences.defaultSaveDirectory?.path ?? "每次保存时选择")
                .textSelection(.enabled)
                .foregroundStyle(palette.secondaryText)
            HStack(spacing: 10) {
                Button("选择文件夹…") {
                    do {
                        if try preferences.chooseDefaultSaveDirectory() {
                            refreshDirectoryWarning()
                        }
                    } catch {
                        directoryWarning = error.localizedDescription
                    }
                }
                Button("每次询问") {
                    preferences.restoreDefaultSaveDirectory()
                    refreshDirectoryWarning()
                }
                .disabled(preferences.defaultSaveDirectory == nil)
            }
            if let directoryWarning {
                Label(directoryWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.favorite)
            }
            Text("设置后直接保存为 PNG，同名文件自动编号，不会覆盖。选择“每次询问”仅更改保存方式，不删除已有图片。")
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("智能框选", systemImage: "viewfinder")
                .font(.headline)
            Picker("选取范围", selection: $preferences.detectionMode) {
                ForEach(CaptureDetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.menu)
            Text("鼠标移到目标上可预览，单击选中；也可随时拖动框选。")
                .foregroundStyle(palette.secondaryText)
            if preferences.detectionMode == .element {
                Text(accessibility.isTrusted
                     ? "已开启控件选取；无法识别控件时可选取整个窗口。"
                     : "选取控件需要辅助功能权限。未授权时仍可选取窗口。")
                    .foregroundStyle(palette.secondaryText)
                if !accessibility.isTrusted {
                    Button("授予辅助功能权限…") { accessibility.requestAccess() }
                }
            }
        }
    }

    private func refreshStatus() {
        accessibility.refresh()
        screenPermission.refresh()
        refreshDirectoryWarning()
    }

    private func refreshDirectoryWarning() {
        do {
            _ = try preferences.validatedDefaultSaveDirectory()
            directoryWarning = nil
        } catch {
            directoryWarning = error.localizedDescription
        }
    }
}
