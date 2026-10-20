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
                    Label("本地图像处理", systemImage: "lock.shield")
                        .font(.headline)
                    Text("截图、标注、取色和文字识别均在本机进行，不上传图片。识字直接在截图与贴图中完成，不再打开独立识别窗体；全局划词翻译仍使用单独的服务与凭据设置。")
                    Text("复制、保存或贴图会将完成的图片收录到历史。历史列表仅加载缩略图，原图按需打开；旧记录若只剩缩略图，会明确提示清晰度限制。")
                    Text("“捕获类型”仅控制被动剪贴板监听，不限制主动完成的图像结果。原图会占用更多磁盘空间，收藏中的图片不会随历史条数裁剪删除。")
                }
                .foregroundStyle(palette.secondaryText)
                ThemeDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("操作", systemImage: "cursorarrow")
                        .font(.headline)
                    Text("从菜单栏右键菜单或面板底部取景框打开工具。框选后用选区下沿工具栏原位标注、复制、保存或贴图，无需打开新编辑窗口。Enter 复制图片，Esc 取消；单次选区位于一块显示器内。")
                    Text("框选后识别原选区文字，支持 Live Text 的设备可直接划词并按 ⌘C。全文使用设置中的“复制图像全文”快捷键；截图选区和获得焦点的贴图共用此动作，不另设 ⌘⇧C。新增文字和绘图标注不参与识别，也不重复分析；马赛克改变时按遮挡后的底图更新。")
                    Text("“\(HotKeyAction.recognizeScreen.title)”快捷键：\(HotKeyAction.recognizeScreen.helpText)")
                    Text("贴图可直接划选文字，⌘C 复制所选文字，无文字选择时复制图片；贴图获得焦点后按已配置的“复制图像全文”快捷键复制全文。空白处或按 Option 拖动贴图，滚轮缩放，小尺寸隐藏工具条；字号等滑条显示实时数值。关闭贴图组合键也在“快捷键”中配置，不内置 ⌘W。")
                    Text("框选时光标旁显示像素放大及色块预览；编辑中按 Option 预览，右键复制 HEX。颜色为 SDR sRGB 数值，不代表 HDR、原彩或夜览后的物理屏幕颜色。")
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
                 ? "已授权，可使用区域截图、截图当前选区的文字识别与屏幕取色。"
                 : "打开开关以请求系统授权。已有图片的编辑、贴图与文字识别不需要此权限。")
                .foregroundStyle(palette.secondaryText)
            Text("权限由 macOS 控制。关闭开关会打开系统设置，请在那里撤销授权；实际撤销前开关仍显示开启。更改权限后可能需要退出并重新打开应用。")
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var saveDirectorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("图像默认保存目录", systemImage: "folder")
                .font(.headline)
            Text(preferences.defaultSaveDirectory?.path ?? "系统默认（由保存面板决定）")
                .textSelection(.enabled)
                .foregroundStyle(palette.secondaryText)
            HStack(spacing: 10) {
                Button("选择目录…") {
                    do {
                        if try preferences.chooseDefaultSaveDirectory() {
                            refreshDirectoryWarning()
                        }
                    } catch {
                        directoryWarning = error.localizedDescription
                    }
                }
                Button("恢复系统默认") {
                    preferences.restoreDefaultSaveDirectory()
                    refreshDirectoryWarning()
                }
                .disabled(preferences.defaultSaveDirectory == nil)
            }
            if let directoryWarning {
                Label(directoryWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.favorite)
            }
            Text("已设置目录时，点击保存会直接写入 PNG，同名文件自动编号且不会覆盖；未设置时才显示保存面板，由你选择位置。目录失效或不可写会明确报错，不会改存其他位置或自动创建文件夹。恢复默认只清除偏好，不删除文件。")
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("UI 智能检测", systemImage: "viewfinder")
                .font(.headline)
            Picker("检测范围", selection: $preferences.detectionMode) {
                ForEach(CaptureDetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.menu)
            Text("悬停预览窗口或控件，单击选中；拖动始终手动框选。默认仅检测窗口，无需额外授权。")
                .foregroundStyle(palette.secondaryText)
            if preferences.detectionMode == .element {
                Text(accessibility.isTrusted
                     ? "已获辅助功能权限。目标应用不支持控件检测时自动退回窗口。"
                     : "控件检测需要辅助功能权限；当前会使用窗口检测，不影响截图。")
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
