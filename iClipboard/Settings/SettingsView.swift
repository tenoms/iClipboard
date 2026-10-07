import SwiftUI

struct SettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var store: ClipboardStore
    var onBack: () -> Void
    @State private var selection: SettingsSection? = .history
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            settingsLayout(
                isCompact: proxy.size.width < AppConstants.Panel.settingsCompactBreakpoint
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .foregroundStyle(palette.text)
    }

    private func settingsLayout(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            headerBar(isCompact: isCompact)
            ThemeDivider()

            if isCompact {
                detail
            } else {
                HStack(spacing: 0) {
                    sidebar
                    ThemeDivider(vertical: true)
                    detail
                }
            }
        }
    }

    private func headerBar(isCompact: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(padding: 0))

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(.headline))
                if !isCompact {
                    Text("自定义 iClipboard 的行为与存储策略")
                        .font(.system(.footnote))
                        .foregroundStyle(palette.secondaryText)
                }
            }

            Spacer()

            if isCompact {
                compactSectionMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var compactSectionMenu: some View {
        let activeSection = selection ?? .history
        return Menu {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Label(section.title, systemImage: section.icon)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeSection.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(activeSection.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                palette.controlHover,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换设置分类")
        .accessibilityLabel("设置分类")
        .accessibilityValue(activeSection.title)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: 6) {
                        Image(systemName: section.icon)
                            .foregroundStyle(selection == section && isSidebarFocused && palette.isActive ? Color.white : palette.secondaryText)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .foregroundStyle(selection == section && isSidebarFocused && palette.isActive ? Color.white : palette.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .layoutPriority(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .tag(section)
                }
            } header: {
                Text("偏好设置")
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .listStyle(.sidebar)
        .focused($isSidebarFocused)
        .scrollContentBackground(.hidden)
        .background(palette.sidebar)
        .frame(width: AppConstants.Panel.settingsSidebarWidth)
        .frame(maxHeight: .infinity)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            switch selection ?? .history {
            case .history:
                HistorySettingsView(store: store)
            case .capture:
                CaptureSettingsView(store: store)
            case .translation:
                TranslationSettingsView()
            case .keyboard:
                ShortcutsSettingsView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Placeholder for search action
