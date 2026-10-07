import SwiftUI

struct TranslationSettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject private var preferences = TranslationPreferences.shared

    @State private var sessionIDDraft = ""
    @State private var isSessionVisible = false
    @State private var credentialMessage: CredentialMessage?
    @State private var testState: TestState = .idle

    private let translationClient = DoubaoTranslationClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                featureCard
                permissionCard
                accountCard
                providerCard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            sessionIDDraft = preferences.currentSessionIDForEditing()
            preferences.refreshAccessibilityStatus()
        }
    }

    private var featureCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SettingsSymbol(
                        name: "character.bubble.fill",
                        tint: palette.accent
                    )
                    Text("全局划词翻译")
                        .font(.system(.headline))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $preferences.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if preferences.isEnabled && !preferences.hasSessionID {
                    InlineNotice(
                        icon: "key.fill",
                        text: "保存 sessionid 后才能发送翻译请求",
                        tint: palette.favorite
                    )
                }
            }
        }
    }

    private var permissionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                permissionStatusRow(
                    title: "辅助功能权限",
                    description: preferences.accessibilityTrusted
                        ? "已授权，可读取其他应用主动选中的文字"
                        : "用于读取你主动选择的文本和选区位置",
                    isGranted: preferences.accessibilityTrusted,
                    missingSymbol: "hand.raised.fill"
                )

                if !preferences.accessibilityTrusted {
                    HStack {
                        Button("请求授权") {
                            preferences.requestAccessibilityAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("打开系统设置") {
                            preferences.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func permissionStatusRow(
        title: String,
        description: String,
        isGranted: Bool,
        missingSymbol: String
    ) -> some View {
        HStack(spacing: 12) {
            SettingsSymbol(
                name: isGranted ? "checkmark.shield.fill" : missingSymbol,
                tint: isGranted ? palette.success : palette.favorite
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 8)
        }
    }

    private var accountCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("豆包会话", systemImage: "person.crop.circle.badge.key.fill")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 8) {
                    Group {
                        if isSessionVisible {
                            TextField("输入 sessionid", text: $sessionIDDraft)
                        } else {
                            SecureField("输入 sessionid", text: $sessionIDDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        isSessionVisible.toggle()
                    } label: {
                        Image(systemName: isSessionVisible ? "eye.slash" : "eye")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(isSessionVisible ? "隐藏 sessionid" : "显示 sessionid")
                }

                HStack(spacing: 8) {
                    Button("保存") { saveSessionID() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sessionIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if preferences.hasSessionID {
                        Button("移除", role: .destructive) { clearSessionID() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Spacer()

                    if let credentialMessage {
                        Label(credentialMessage.text, systemImage: credentialMessage.symbol)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(credentialMessage.isError ? palette.destructive : palette.success)
                    }
                }
            }
        }
    }

    private var providerCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("翻译服务", systemImage: "network")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("翻译服务", selection: $preferences.provider) {
                        ForEach(TranslationProvider.allCases) { provider in
                            Label(provider.title, systemImage: provider.symbolName)
                                .tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 136)
                }

                HStack {
                    Button {
                        testConfiguration()
                    } label: {
                        switch testState {
                        case .testing:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在验证")
                            }
                        default:
                            Label("验证配置", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!preferences.hasSessionID || testState == .testing)

                    Spacer()

                    switch testState {
                    case .idle, .testing:
                        EmptyView()
                    case let .success(text):
                        Label(text, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(palette.success)
                            .lineLimit(1)
                    case let .failure(text):
                        Label(text, systemImage: "xmark.circle.fill")
                            .foregroundStyle(palette.destructive)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
            }
        }
    }

    private func saveSessionID() {
        do {
            try preferences.saveSessionID(sessionIDDraft)
            credentialMessage = CredentialMessage(text: "已保存", symbol: "checkmark.circle.fill", isError: false)
            TranslationCoordinator.shared.refreshMonitoringState()
        } catch {
            credentialMessage = CredentialMessage(
                text: error.localizedDescription,
                symbol: "xmark.circle.fill",
                isError: true
            )
        }
    }

    private func clearSessionID() {
        do {
            try preferences.clearSessionID()
            sessionIDDraft = ""
            credentialMessage = CredentialMessage(text: "已移除", symbol: "checkmark.circle.fill", isError: false)
        } catch {
            credentialMessage = CredentialMessage(
                text: error.localizedDescription,
                symbol: "xmark.circle.fill",
                isError: true
            )
        }
    }

    private func testConfiguration() {
        testState = .testing
        Task {
            do {
                let sessionID = try preferences.sessionID()
                let result = try await translationClient.translate(
                    text: "just go for it",
                    provider: preferences.provider,
                    sessionID: sessionID
                )
                testState = .success(result.translatedText)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.appPalette) private var palette
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(palette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            }
    }
}

private struct SettingsSymbol: View {
    let name: String
    let tint: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct InlineNotice: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CredentialMessage {
    let text: String
    let symbol: String
    let isError: Bool
}

private enum TestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}
