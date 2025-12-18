import SwiftUI
import CoreData

struct SidebarView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var isPresentedAddListPopover: Bool
    @AppStorage("favoritesSectionExpanded") private var isFavoritesExpanded = true
    @AppStorage("typesSectionExpanded") private var isTypesExpanded = true

    @State private var newListName: String = ""
    @State private var addError: String?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            allRow

            Divider().opacity(0.12)

            favoritesHeader

            if isFavoritesExpanded {
                if store.favoriteLists.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂无收藏列表")
                        Text("点击右上角 + 创建新列表")
                    }
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.favoriteLists) { list in
                                FavoriteListRow(
                                    list: list,
                                    isSelected: store.selectedListID == list.id,
                                    onSelect: { store.selectedListID = list.id },
                                    onDelete: { store.deleteFavoriteList(list) }
                                )
                            }
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            
            Divider().opacity(0.12)
            
            typesHeader
            
            if isTypesExpanded {
                VStack(spacing: 2) {
                    ForEach(ClipboardContentKind.allCases, id: \.self) { kind in
                        TypeRow(
                            kind: kind,
                            isSelected: store.selectedKind == kind,
                            onSelect: { store.selectedKind = kind }
                        )
                    }
                }
            } else {
                Spacer()
            }

        }
        .padding(10)
        .frame(width: 190, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 0.8)
        )
    }

    private var favoritesHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { isFavoritesExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFavoritesExpanded ? 90 : 0))
                    
                    Label("收藏列表", systemImage: "star.fill")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Button {
                addError = nil
                newListName = ""
                isPresentedAddListPopover = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help("添加收藏列表")
            .popover(isPresented: $isPresentedAddListPopover) {
                addListPopover
                    .onAppear { isNameFieldFocused = true }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private var typesHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { isTypesExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isTypesExpanded ? 90 : 0))
                    
                    Label("类型", systemImage: "square.grid.2x2.fill")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private var allRow: some View {
        Button {
            store.selectedListID = nil
            store.selectedKind = nil
        } label: {
            HStack {
                Label("全部记录", systemImage: "tray.full")
                    .font(.system(.callout, design: .rounded))
                Spacer(minLength: 8)
                Text("\(store.entries.count)")
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isActive: store.selectedListID == nil && store.selectedKind == nil))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke((store.selectedListID == nil && store.selectedKind == nil) ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }


private struct TypeRow: View {
    let kind: ClipboardContentKind
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label(kind.label, systemImage: kind.icon)
                    .font(.system(.callout, design: .rounded))
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
    private var addListPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加收藏列表")
                .font(.system(.headline, design: .rounded))

            TextField("列表名称", text: $newListName)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)
                .onSubmit { submitNewList() }

            if let addError {
                Text(addError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    closeAddPopover()
                }
                Button("添加") {
                    submitNewList()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func submitNewList() {
        let error = store.addFavoriteList(named: newListName)
        if let error {
            addError = error
        } else {
            closeAddPopover()
        }
    }

    private func closeAddPopover() {
        isPresentedAddListPopover = false
        newListName = ""
        addError = nil
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.02))
    }
}

private struct FavoriteListRow: View {
    let list: FavoriteListModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showDeletePopover = false

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onSelect) {
                HStack {
                    Image(systemName: "tag")
                        .opacity(isHovering ? 0 : 1)
                    Text(list.name)
                        .font(.system(.callout, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(list.count)")
                        .font(.system(.footnote, design: .rounded).bold())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
                showDeletePopover = true
            } label: {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(.red)
                    .padding(.leading, 10)
            }
            .buttonStyle(.plain)
            .help("删除列表")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .popover(isPresented: $showDeletePopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("删除列表？")
                        .font(.system(.headline, design: .rounded))
                    Text("删除后其中的记录也会被移除。")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("取消") { showDeletePopover = false }
                        Button("删除", role: .destructive) {
                            showDeletePopover = false
                            onDelete()
                        }
                    }
                }
                .padding(14)
                .frame(width: 220)
            }
        }
        .onHover { isHovering = $0 }
    }
}
