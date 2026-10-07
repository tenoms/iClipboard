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
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Label("偏好设置", systemImage: "gearshape.2.fill")
                    .font(.system(.callout))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                ForEach(SettingsSection.allCases) { section in
                    SidebarSelectionRow(
                        title: section.title,
                        symbol: section.icon,
                        isSelected: activeSection == section
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selection = section
                        }
                        isSidebarFocused = true
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .focusable()
        .focused($isSidebarFocused)
        .onMoveCommand(perform: moveSidebarSelection)
        .background(palette.sidebar)
        .frame(width: AppConstants.Panel.settingsSidebarWidth)
        .frame(maxHeight: .infinity)
    }

    private var activeSection: SettingsSection {
        selection ?? .history
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

    private func moveSidebarSelection(_ direction: MoveCommandDirection) {
        let sections = SettingsSection.allCases
        guard let currentIndex = sections.firstIndex(of: activeSection) else { return }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(sections.startIndex, currentIndex - 1)
        case .down:
            nextIndex = min(sections.index(before: sections.endIndex), currentIndex + 1)
        default:
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            selection = sections[nextIndex]
        }
    }
}

// Placeholder for search action
