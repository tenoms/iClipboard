import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    var onBack: () -> Void
    @State private var selection: SettingsSection? = .history

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.12)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.1)
                detail
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(.headline, design: .rounded))
                Text("自定义 iClipboard 的行为与存储策略")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("偏好设置") {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .foregroundStyle(selection == section ? .primary : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .foregroundStyle(selection == section ? .primary : .primary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == section ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .tag(section as SettingsSection?)
                    .onTapGesture {
                        selection = section
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 140)
        .frame(maxHeight: .infinity)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            switch selection ?? .history {
            case .history:
                HistorySettingsView(store: store)
            case .capture:
                CaptureSettingsView(store: store)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.white.opacity(0.02)
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case history
    case capture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史记录"
        case .capture: return "捕获类型"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .capture: return "slider.horizontal.3"
        }
    }
}

private struct HistorySettingsView: View {
    @ObservedObject var store: ClipboardStore

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(store.historyLimit) },
            set: { 
                let rounded = (($0 / 10).rounded()) * 10
                store.updateHistoryLimit(Int(rounded))
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                limitCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var limitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("保存上限")
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(store.historyLimit) 条")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Slider(value: sliderBinding, in: 10...500)
                HStack {
                    Text("10")
                    Spacer()
                    Text("500")
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }
}

private struct CaptureSettingsView: View {
    @ObservedObject var store: ClipboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                typesCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var typesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("捕获类型")
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(ClipboardContentKind.allCases, id: \.self) { kind in
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon)
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(.secondary)
                        
                        Text(kind.label)
                            .font(.system(.body, design: .rounded))
                            
                        Spacer()
                        
                        Toggle(isOn: Binding(
                            get: { store.enabledTypes.contains(kind) },
                            set: { isEnabled in
                                if isEnabled {
                                    store.enabledTypes.insert(kind)
                                } else {
                                    store.enabledTypes.remove(kind)
                                }
                            }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }
}
