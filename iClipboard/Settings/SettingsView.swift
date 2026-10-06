import SwiftUI

struct SettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var store: ClipboardStore
    var onBack: () -> Void
    @State private var selection: SettingsSection? = .history
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ThemeDivider()
            HStack(spacing: 0) {
                sidebar
                ThemeDivider(vertical: true)
                detail
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .foregroundStyle(palette.text)
    }

    private var headerBar: some View {
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
                Text("自定义 iClipboard 的行为与存储策略")
                    .font(.system(.footnote))
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .frame(width: 120)
        .frame(maxHeight: .infinity)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            switch selection ?? .history {
            case .history:
                HistorySettingsView(store: store)
            case .capture:
                CaptureSettingsView(store: store)
            case .keyboard:
                ShortcutsSettingsView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Placeholder for search action
