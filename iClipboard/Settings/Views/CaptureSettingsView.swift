import SwiftUI

struct CaptureSettingsView: View {
    @Environment(\.appPalette) private var palette
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
                    .font(.system(.headline))
                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(ClipboardContentKind.allCases, id: \.self) { kind in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            makeLabel(for: kind)
                            Spacer()
                            makeToggle(for: kind)
                        }
                        
                        VStack(spacing: 8) {
                            HStack {
                                makeLabel(for: kind)
                                Spacer()
                            }
                            HStack {
                                Spacer()
                                makeToggle(for: kind)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border, lineWidth: 0.5)
        )
    }

    private func makeLabel(for kind: ClipboardContentKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .frame(width: 20, alignment: .center)
                .foregroundStyle(palette.secondaryText)
            
            Text(kind.label)
                .font(.system(.body))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func makeToggle(for kind: ClipboardContentKind) -> some View {
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
