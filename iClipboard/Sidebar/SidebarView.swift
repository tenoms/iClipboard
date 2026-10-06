import SwiftUI
import CoreData

struct SidebarView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var store: ClipboardStore
    @Binding var isPresentedAddListPopover: Bool
    @AppStorage("favoritesSectionExpanded") private var isFavoritesExpanded = true
    @AppStorage("typesSectionExpanded") private var isTypesExpanded = true

    @State private var newListName: String = ""
    @State private var addError: String?
    @FocusState private var isNameFieldFocused: Bool
    @State private var isHoveringAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            allRow

            ThemeDivider()

            favoritesHeader

            if isFavoritesExpanded {
                if store.favoriteLists.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂无收藏列表")
                        Text("点击右上角 + 创建新列表")
                    }
                    .font(.system(.footnote))
                    .foregroundStyle(palette.secondaryText)
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
            
            ThemeDivider()
            
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
        .frame(width: AppConstants.Panel.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.sidebar)
        )
    }

    private var favoritesHeader: some View {
        Button {
            withAnimation { isFavoritesExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .rotationEffect(.degrees(isFavoritesExpanded ? 90 : 0))
                
                Label("收藏列表", systemImage: "star.fill")
                    .font(.system(.callout))
                    .foregroundStyle(palette.text)
                
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private var typesHeader: some View {
        Button {
            withAnimation { isTypesExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .rotationEffect(.degrees(isTypesExpanded ? 90 : 0))
                
                Label("类型", systemImage: "square.grid.2x2.fill")
                    .font(.system(.callout))
                    .foregroundStyle(palette.text)
                
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .font(.system(.callout))
                Spacer(minLength: 8)
                Text("\(store.entries.count)")
                    .font(.system(.footnote).bold())
                    .foregroundStyle(palette.secondaryText)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule()
                            .fill(palette.control)
                    )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle((store.selectedListID == nil && store.selectedKind == nil) ? palette.selectionText : palette.text)
            .background(rowBackground(isActive: store.selectedListID == nil && store.selectedKind == nil, isHovering: isHoveringAll))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke((store.selectedListID == nil && store.selectedKind == nil) ? palette.selectionBorder : Color.clear, lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHoveringAll = $0 }
        .animation(.easeOut(duration: 0.15), value: isHoveringAll)
    }


    private var addListPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加收藏列表")
                .font(.system(.headline))

            TextField("列表名称", text: $newListName)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)
                .onSubmit { submitNewList() }

            if let addError {
                Text(addError)
                    .font(.system(.footnote))
                    .foregroundStyle(palette.destructive)
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

    private func rowBackground(isActive: Bool, isHovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? palette.selection : (isHovering ? palette.controlHover : Color.clear))
    }
}
