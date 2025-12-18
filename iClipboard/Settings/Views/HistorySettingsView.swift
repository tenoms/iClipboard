import SwiftUI

struct HistorySettingsView: View {
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
