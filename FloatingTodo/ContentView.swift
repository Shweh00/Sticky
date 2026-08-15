import SwiftUI
import AppKit

// MARK: - Design Tokens

private enum Theme {
    static let surface = Color.black.opacity(0.04)
    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.primary.opacity(0.2)
    static let accent = Color.primary
    static let accentSoft = Color.primary.opacity(0.04)
    static let danger = Color.primary.opacity(0.4)
    static let dangerSoft = Color.primary.opacity(0.03)
    static let success = Color.primary.opacity(0.25)
    static let divider = Color.primary.opacity(0.08)
    static let inputBg = Color.clear
    static let checkboxBorder = Color.primary.opacity(0.15)
    static let cornerRadius: CGFloat = 16
    static let innerRadius: CGFloat = 8
    static let noteText = Color.primary.opacity(0.55)
    static let noteBg = Color.primary.opacity(0.025)
    static let noteBorder = Color.primary.opacity(0.06)
    static let tabText = Color(red: 0.20, green: 0.18, blue: 0.16)
    static let confettiColors: [Color] = [
        Color(red: 0.94, green: 0.56, blue: 0.64),
        Color(red: 0.96, green: 0.75, blue: 0.38),
        Color(red: 0.47, green: 0.76, blue: 0.61),
        Color(red: 0.49, green: 0.67, blue: 0.92),
        Color(red: 0.63, green: 0.53, blue: 0.87),
        Color(red: 0.94, green: 0.56, blue: 0.77)
    ]

}

// MARK: - Notebook Paper Palette

private enum StickyColorTheme: String, CaseIterable, Identifiable {
    case rose
    case mistBlue
    case sage

    var id: String { rawValue }

    var hue: Double {
        switch self {
        case .rose: return 0.955
        case .mistBlue: return 0.58
        case .sage: return 0.39
        }
    }

    var displayName: String {
        switch self {
        case .rose: return "樱花粉"
        case .mistBlue: return "雾霭蓝"
        case .sage: return "鼠尾草绿"
        }
    }
}

private struct NotebookPaperStyle {
    let paper: Color
    let paperHighlight: Color
    let tab: Color
    let tabEdge: Color
    let ink: Color
    let composerControl: Color
    let brand: Color
    let priorityHigh: Color
    let priorityLow: Color
}

private enum NotebookPaperPalette {
    static func style(theme: StickyColorTheme) -> NotebookPaperStyle {
        return NotebookPaperStyle(
            paper: color(theme, saturation: 0.043, brightness: 1.0),
            paperHighlight: color(theme, saturation: 0.012, brightness: 1.0),
            tab: color(theme, saturation: 0.219, brightness: 0.949),
            tabEdge: color(theme, saturation: 0.357, brightness: 0.549),
            ink: color(theme, saturation: 0.329, brightness: 0.322),
            composerControl: color(theme, saturation: 0.056, brightness: 0.98),
            brand: color(theme, saturation: 0.47, brightness: 0.76),
            priorityHigh: color(theme, saturation: 0.319, brightness: 0.91),
            priorityLow: color(theme, saturation: 0.112, brightness: 0.985)
        )
    }

    static func swatch(for theme: StickyColorTheme) -> Color {
        color(theme, saturation: 0.48, brightness: 0.82)
    }

    private static func color(
        _ theme: StickyColorTheme,
        saturation: Double,
        brightness: Double
    ) -> Color {
        Color(hue: theme.hue, saturation: saturation, brightness: brightness)
    }
}

private struct StickyPaperStyleKey: EnvironmentKey {
    static let defaultValue = NotebookPaperPalette.style(theme: .rose)
}

private extension EnvironmentValues {
    var stickyPaperStyle: NotebookPaperStyle {
        get { self[StickyPaperStyleKey.self] }
        set { self[StickyPaperStyleKey.self] = newValue }
    }
}

private struct PaperSurface: View {
    let style: NotebookPaperStyle
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(style.paper)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [style.paperHighlight, style.paper],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                PaperTextureOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
    }
}

private struct PaperTextureOverlay: View {
    var body: some View {
        if let textureURL = AppResources.url(
            forResource: "paper-texture",
            withExtension: "png"
        ), let texture = NSImage(contentsOf: textureURL) {
            Image(nsImage: texture)
                .resizable(
                    capInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                    resizingMode: .tile
                )
                .opacity(0.075)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @ObservedObject var store: TodoStore
    let onInteractionChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newTodoText = ""
    @FocusState private var inputFocused: Bool
    // 拖拽状态（放在父级，跨 child rebuild 保持稳定）
    @State private var draggingId: UUID? = nil
    @State private var dragAccumulated: CGFloat = 0
    @State private var draggingPageId: UUID? = nil
    @State private var pageDragOriginIndex: Int? = nil
    @State private var confettiBurst = 0
    @State private var showsCompletionConfetti = false
    @State private var isEditingPageTitle = false
    @State private var pageTitleText = ""
    @FocusState private var pageTitleFocused: Bool
    @State private var rowEditorFocused = false
    @AppStorage("sticky.selectedColorTheme") private var selectedThemeRaw = StickyColorTheme.rose.rawValue

    init(store: TodoStore, onInteractionChange: @escaping (Bool) -> Void = { _ in }) {
        self._store = ObservedObject(wrappedValue: store)
        self.onInteractionChange = onInteractionChange
    }

    private var pending: [TodoItem] { store.todos.filter { !$0.completed } }
    private var completed: [TodoItem] { store.todos.filter { $0.completed } }
    private var selectedTheme: StickyColorTheme {
        StickyColorTheme(rawValue: selectedThemeRaw) ?? .rose
    }
    private var activePaperStyle: NotebookPaperStyle {
        NotebookPaperPalette.style(theme: selectedTheme)
    }
    private var displayPageTitle: String {
        let trimmed = store.activePageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "待办事项" : trimmed
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            outerWindow
                .offset(x: 8, y: 4)

            bookmarkEdge
                .offset(x: 330, y: 86)

            if showsCompletionConfetti && !reduceMotion {
                CompletionConfettiView(seed: confettiBurst)
                    .frame(width: 316, height: 250)
                    .offset(x: 28, y: 72)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(confettiBurst)
            }
        }
        .frame(width: 430, height: 430, alignment: .topLeading)
        .environment(\.stickyPaperStyle, activePaperStyle)
        .environment(\.colorScheme, .light)
        .onChange(of: store.activePageId) {
            newTodoText = ""
            draggingId = nil
            dragAccumulated = 0
            isEditingPageTitle = false
            pageTitleText = store.activePageTitle
            rowEditorFocused = false
            publishInteractionState()
        }
        .onChange(of: inputFocused) { publishInteractionState() }
        .onChange(of: pageTitleFocused) { publishInteractionState() }
        .onChange(of: draggingId) { publishInteractionState() }
        .onChange(of: draggingPageId) { publishInteractionState() }
        .onChange(of: rowEditorFocused) { publishInteractionState() }
        .onDisappear { onInteractionChange(false) }
    }

    private var outerWindow: some View {
        VStack(spacing: 0) {
            chromeBar

            VStack(spacing: 0) {
                headerView

                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 0.6)
                    .padding(.horizontal, 30)
                    .padding(.top, 2)

                if store.todos.isEmpty {
                    emptyState
                } else {
                    todoList
                }

                inputBar
            }
            .frame(width: 316, height: 330)
            .background(PaperSurface(style: activePaperStyle, cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(activePaperStyle.tabEdge.opacity(0.14), lineWidth: 0.9)
            )
            .padding(.top, 8)
        }
        .frame(width: 354, height: 410, alignment: .top)
        .background(PaperSurface(style: activePaperStyle, cornerRadius: 30))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(activePaperStyle.tabEdge.opacity(0.14), lineWidth: 0.8)
        )
    }

    private var chromeBar: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(StickyColorTheme.allCases) { theme in
                themeButton(theme)
            }

            Spacer()

            progressRing
            Text("\(completed.count)/\(store.todos.count)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if store.canUndoDelete {
                Text("已删除")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)

                Button("撤销") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        store.undoLastDelete()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(activePaperStyle.brand)
                .help("恢复刚刚删除的待办")
            }

            if let syncErrorMessage = store.syncErrorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .help(syncErrorMessage)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 15)
        .frame(height: 58)
    }

    private func themeButton(_ theme: StickyColorTheme) -> some View {
        let color = NotebookPaperPalette.swatch(for: theme)
        let isSelected = theme == selectedTheme

        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                selectedThemeRaw = theme.rawValue
            }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.72), lineWidth: 0.8)
                )
                .overlay(
                    Circle()
                        .stroke(activePaperStyle.ink.opacity(isSelected ? 0.58 : 0), lineWidth: 1.2)
                        .padding(-3)
                )
                .shadow(color: color.opacity(isSelected ? 0.34 : 0.20), radius: isSelected ? 4 : 2, x: 0, y: 2)
                .scaleEffect(isSelected ? 1 : 0.88)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("切换为\(theme.displayName)主题")
        .accessibilityLabel("\(theme.displayName)主题\(isSelected ? "，已选择" : "")")
    }

    // MARK: - Bookmark Sidebar

    private var bookmarkEdge: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                    BookmarkButton(
                        page: page,
                        isActive: page.id == store.activePageId,
                        action: { selectPage(page.id) },
                        openNote: { store.openObsidianNote(for: page.id) },
                        editTitle: { beginPageTitleEditing(for: page.id) },
                        canDelete: store.pages.count > 1,
                        deletePage: { _ = store.deletePage(page.id) }
                    )
                    .offset(x: page.id == store.activePageId ? 0 : 14, y: CGFloat(index) * 31)
                    .opacity(draggingPageId == page.id ? 0.68 : 1)
                    .scaleEffect(draggingPageId == page.id ? 0.97 : 1)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { value in
                                updatePageDrag(page.id, translation: value.translation.height)
                            }
                            .onEnded { _ in
                                finishPageDrag()
                            }
                    )
                    .zIndex(
                        draggingPageId == page.id
                            ? 20
                            : (page.id == store.activePageId ? 10 : Double(store.pages.count - index))
                    )
                }

                if store.pages.count < 2 {
                    GhostBookmarkButton(title: "灵感") {
                        addPage(title: "灵感")
                    }
                    .offset(x: 14, y: CGFloat(store.pages.count) * 31)
                    .zIndex(1)
                }

                addPageButton
                    .offset(x: 14, y: CGFloat(max(store.pages.count, 1)) * 31 + 6)
            }
            .frame(width: 100, height: tabStackHeight, alignment: .topLeading)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: store.activePageId)
        }
        .frame(width: 100, height: 320, alignment: .topLeading)
    }

    private var tabStackHeight: CGFloat {
        max(76, CGFloat(max(store.pages.count, 1)) * 31 + 48)
    }

    private var addPageButton: some View {
        Button { addPage(title: nil) } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(activePaperStyle.ink.opacity(0.72))
        .background(Circle().fill(activePaperStyle.paperHighlight))
        .overlay(Circle().strokeBorder(activePaperStyle.tabEdge.opacity(0.20), lineWidth: 0.7))
        .shadow(color: activePaperStyle.tabEdge.opacity(0.07), radius: 2, x: 0, y: 1)
        .help("新建便贴")
    }

    private func selectPage(_ pageId: UUID) {
        guard !reduceMotion else {
            store.selectPage(pageId)
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            store.selectPage(pageId)
        }
    }

    private func addPage(title: String?) {
        guard !reduceMotion else {
            store.addPage(title: title)
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            store.addPage(title: title)
        }
    }

    private func updatePageDrag(_ pageId: UUID, translation: CGFloat) {
        if draggingPageId == nil {
            guard let originIndex = store.pages.firstIndex(where: { $0.id == pageId }) else { return }
            draggingPageId = pageId
            pageDragOriginIndex = originIndex
        }

        guard draggingPageId == pageId,
              let originIndex = pageDragOriginIndex,
              let currentIndex = store.pages.firstIndex(where: { $0.id == pageId }) else { return }

        let step = Int((translation / 31).rounded())
        let targetIndex = min(max(originIndex + step, 0), store.pages.count - 1)
        guard targetIndex != currentIndex else { return }

        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.84)) {
            store.movePage(pageId, toIndex: targetIndex)
        }
    }

    private func finishPageDrag() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            draggingPageId = nil
            pageDragOriginIndex = nil
        }
    }

    private func beginPageTitleEditing(for pageId: UUID? = nil) {
        if let pageId, pageId != store.activePageId {
            store.selectPage(pageId)
        }

        DispatchQueue.main.async {
            pageTitleText = store.activePageTitle
            isEditingPageTitle = true
            DispatchQueue.main.async {
                pageTitleFocused = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                if isEditingPageTitle {
                    TextField("这里可以写标题...", text: $pageTitleText)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .textFieldStyle(.plain)
                        .focused($pageTitleFocused)
                        .frame(height: 29)
                        .onSubmit(finishPageTitleEditing)
                        .onChange(of: pageTitleFocused) {
                            if !pageTitleFocused {
                                finishPageTitleEditing()
                            }
                        }
                } else {
                    Text(displayPageTitle)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(height: 29, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            beginPageTitleEditing()
                        }
                }

                Text("专注当下，一件件完成。")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var progressRing: some View {
        let progress = store.todos.isEmpty ? 0.0 : Double(completed.count) / Double(store.todos.count)
        let allDone = !store.todos.isEmpty && pending.isEmpty

        return ZStack {
            Circle()
                .stroke(Theme.divider, lineWidth: 2)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    allDone ? activePaperStyle.brand : Theme.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.75), value: completed.count)

            if allDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(activePaperStyle.brand)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("✨")
                .font(.system(size: 32))
            Text("享受当下的空闲时刻")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.vertical, 16)
    }

    // MARK: - Todo List

    private var todoList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(store.todos) { item in
                    todoRow(item: item)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 188)
    }

    private func todoRow(item: TodoItem) -> some View {
        return TodoRowContent(
            item: item,
            store: store,
            isDragging: draggingId == item.id,
            showGrip: !item.completed,
            onComplete: celebrateCompletion,
            onDragChanged: { value in
                handleDrag(value, for: item)
            },
            onDragEnded: finishDrag,
            onInteractionChange: { isFocused in
                rowEditorFocused = isFocused
            }
        )
    }

    private func handleDrag(_ value: DragGesture.Value, for item: TodoItem) {
        if draggingId == nil {
            draggingId = item.id
            dragAccumulated = 0
        }
        var effective = value.translation.height - dragAccumulated
        let rowH: CGFloat = 44

        while true {
            let currentPending = store.todos.filter { !$0.completed }
            guard let currentIndex = currentPending.firstIndex(where: { $0.id == item.id }) else { break }

            if effective > rowH * 0.55 && currentIndex < currentPending.count - 1 {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    store.moveDown(item)
                }
                dragAccumulated += rowH
                effective -= rowH
            } else if effective < -rowH * 0.55 && currentIndex > 0 {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    store.moveUp(item)
                }
                dragAccumulated -= rowH
                effective += rowH
            } else {
                break
            }
        }
    }

    private func finishDrag() {
        withAnimation(.easeOut(duration: 0.2)) {
            draggingId = nil
            dragAccumulated = 0
        }
    }

    private func celebrateCompletion() {
        CompletionSoundPlayer.shared.playTripleChime()
        guard !reduceMotion else { return }

        confettiBurst += 1

        withAnimation(.easeOut(duration: 0.12)) {
            showsCompletionConfetti = true
        }

        let currentBurst = confettiBurst
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
            guard currentBurst == confettiBurst else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showsCompletionConfetti = false
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 11) {
            Button(action: submitNewTodo) {
                ZStack {
                    Circle()
                        .fill(inputFocused ? activePaperStyle.tab : activePaperStyle.composerControl)

                    Circle()
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.9)

                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(activePaperStyle.ink)
                }
                .frame(width: 40, height: 40)
                .shadow(
                    color: activePaperStyle.tabEdge.opacity(inputFocused ? 0.24 : 0.16),
                    radius: inputFocused ? 5 : 3,
                    x: 0,
                    y: 2
                )
                .animation(.easeOut(duration: 0.18), value: inputFocused)
            }
            .buttonStyle(.plain)
            .help("添加待办")

            TextField(
                "",
                text: $newTodoText,
                prompt: Text("添加新待办…")
                    .foregroundStyle(activePaperStyle.ink.opacity(0.42))
            )
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(activePaperStyle.ink)
                .focused($inputFocused)
                .onSubmit {
                    submitNewTodo()
                }

            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(activePaperStyle.ink.opacity(0.48))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(activePaperStyle.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(activePaperStyle.tabEdge.opacity(0.14), lineWidth: 0.7)
                        )
                )
                .padding(.trailing, 10)
        }
        .frame(height: 48)
        .background(
            Capsule()
                .fill(activePaperStyle.paperHighlight)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            activePaperStyle.tabEdge.opacity(inputFocused ? 0.30 : 0.15),
                            lineWidth: inputFocused ? 1.0 : 0.8
                        )
                )
                .overlay(alignment: .top) {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.52), lineWidth: 0.8)
                        .padding(1)
                }
                .shadow(color: Color.black.opacity(0.045), radius: 3, x: 0, y: 2)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .overlay(
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.6)
                .padding(.horizontal, 30),
            alignment: .top
        )
    }

    private func finishPageTitleEditing() {
        guard isEditingPageTitle else { return }
        store.updateActivePageTitle(pageTitleText)
        isEditingPageTitle = false
    }

    private func submitNewTodo() {
        let trimmed = newTodoText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.add(trimmed)
        }
        newTodoText = ""
    }

    private func publishInteractionState() {
        onInteractionChange(
            inputFocused
                || pageTitleFocused
                || rowEditorFocused
                || draggingId != nil
                || draggingPageId != nil
        )
    }
}

private struct BookmarkButton: View {
    let page: TodoPage
    let isActive: Bool
    let action: () -> Void
    let openNote: () -> Void
    let editTitle: () -> Void
    let canDelete: Bool
    let deletePage: () -> Void
    @State private var isHovering = false
    @State private var showsDeleteConfirmation = false
    @Environment(\.stickyPaperStyle) private var paperStyle

    private var displayTitle: String {
        let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    private var tabFill: Color {
        switch page.priority {
        case .high:
            return paperStyle.priorityHigh
        case .normal:
            return paperStyle.tab
        case .low:
            return paperStyle.priorityLow
        }
    }

    private var priorityEdgeOpacity: Double {
        switch page.priority {
        case .high: return isActive ? 0.58 : 0.42
        case .normal: return isActive ? 0.32 : 0.10
        case .low: return isActive ? 0.24 : 0.07
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: action) {
                Text(displayTitle)
                    .font(.system(size: isActive ? 15 : 12, weight: isActive ? .bold : .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, isActive || isHovering ? 29 : 13)
                    .padding(.trailing, isHovering && canDelete ? 25 : 11)
                    .frame(width: isActive ? 92 : 72, height: 34, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: isActive ? 10 : 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded(editTitle)
            )

            Button(action: openNote) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(paperStyle.ink.opacity(isActive ? 0.72 : 0.58))
            .opacity(isActive || isHovering ? 1 : 0)
            .allowsHitTesting(isActive || isHovering)
            .padding(.leading, 3)
            .help("在 Obsidian 中打开 \(displayTitle)")
            .accessibilityLabel("在 Obsidian 中打开 \(displayTitle)")

            if canDelete {
                Button {
                    showsDeleteConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(paperStyle.ink.opacity(0.52))
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .padding(.trailing, 3)
                .frame(width: isActive ? 92 : 72, alignment: .trailing)
                .help("删除标签")
                .accessibilityLabel("删除标签 \(displayTitle)")
            }
        }
        .frame(width: isActive ? 92 : 72, height: 34)
        .foregroundStyle(isActive ? paperStyle.ink : paperStyle.ink.opacity(0.72))
        .background(
            RoundedRectangle(cornerRadius: isActive ? 10 : 8, style: .continuous)
                .fill(tabFill)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: isActive ? 10 : 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .shadow(
                    color: paperStyle.tabEdge.opacity(isActive ? 0.12 : 0.07),
                    radius: isActive ? 3 : 1.5,
                    x: 0,
                    y: 1
                )
        )
        .overlay(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(paperStyle.tabEdge.opacity(priorityEdgeOpacity), lineWidth: 0.9)
                }
            }
        )
        .help("\(displayTitle) · \(page.priority.displayName)重要性 · 拖动排序 · 双击重命名")
        .zIndex(isActive ? 10 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .contextMenu {
            Button("重命名标签", action: editTitle)
            Button("在 Obsidian 中打开", action: openNote)
            if canDelete {
                Divider()
                Button("删除标签", role: .destructive) {
                    showsDeleteConfirmation = true
                }
            }
        }
        .alert("删除“\(displayTitle)”？", isPresented: $showsDeleteConfirmation) {
            Button("删除标签", role: .destructive, action: deletePage)
            Button("取消", role: .cancel) {}
        } message: {
            Text("标签及其中的任务将被删除，对应的 Obsidian 笔记会移入废纸篓。")
        }
    }

}

private struct GhostBookmarkButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.stickyPaperStyle) private var paperStyle

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .frame(width: 72, height: 34, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(paperStyle.ink.opacity(0.72))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(paperStyle.tab)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(paperStyle.tabEdge.opacity(0.10), lineWidth: 0.6)
        )
        .help(title)
    }
}

// MARK: - Todo Row Content (非泛型，纯展示+交互)

struct TodoRowContent: View {
    let item: TodoItem
    @ObservedObject var store: TodoStore
    let isDragging: Bool
    let showGrip: Bool
    let onComplete: (() -> Void)?
    let onDragChanged: ((DragGesture.Value) -> Void)?
    let onDragEnded: (() -> Void)?
    let onInteractionChange: (Bool) -> Void
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool
    @State private var isEditingTitle = false
    @State private var titleText = ""
    @FocusState private var titleFocused: Bool
    @State private var showsReminderPopover = false
    @State private var reminderDate = Date()
    @Environment(\.stickyPaperStyle) private var paperStyle

    private var hasNote: Bool { !item.note.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    if item.completed {
                        Circle()
                            .fill(paperStyle.brand)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.white)
                            )
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.36))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.26), lineWidth: 1.2)
                                    .frame(width: 20, height: 20)
                            )
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                .onTapGesture(count: 1) {
                    toggleCompletion()
                }

                if isEditingTitle && !item.completed {
                    TextField("任务名称", text: $titleText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .focused($titleFocused)
                        .onSubmit(finishTitleEditing)
                        .onChange(of: titleFocused) {
                            if !titleFocused {
                                finishTitleEditing()
                            }
                        }
                } else {
                    Text(item.text)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(item.completed ? Theme.textTertiary.opacity(0.82) : Theme.text)
                        .blur(radius: item.completed ? 0.6 : 0)
                        .scaleEffect(item.completed ? 0.98 : 1.0, anchor: .leading)
                        .lineLimit(1)
                        .overlay(alignment: .center) {
                            Rectangle()
                                .fill(Theme.textTertiary)
                                .frame(height: 1.4)
                                .scaleEffect(x: item.completed ? 1 : 0, anchor: .leading)
                                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: item.completed)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if !item.completed {
                                titleText = item.text
                                isEditingTitle = true
                                titleFocused = true
                            }
                        }
                        .onTapGesture(count: 1) {
                            if !isEditingTitle {
                                toggleCompletion()
                            }
                        }
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: item.completed)
                }

                if item.reminderDate != nil || isHovering || showsReminderPopover {
                    reminderButton
                }

                if hasNote || isHovering || isExpanded {
                    noteButton
                }

                if showGrip && (isHovering || isDragging) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                                .onChanged { value in onDragChanged?(value) }
                                .onEnded { _ in onDragEnded?() }
                        )
                        .help("拖动排序")
                }

                if isHovering {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.62))
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                store.delete(item)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                }
            }

            if isExpanded {
                noteEditor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(isHovering ? Theme.surface : .clear)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        )
        .opacity(isDragging ? 0.65 : 1.0)
        .scaleEffect(isDragging ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            noteText = item.note
        }
        .onChange(of: item.note) {
            if !noteFocused { noteText = item.note }
        }
        .onChange(of: titleFocused) {
            publishInteractionState()
        }
        .onChange(of: noteFocused) {
            publishInteractionState()
        }
        .onChange(of: showsReminderPopover) {
            publishInteractionState()
        }
        .onDisappear { onInteractionChange(false) }
    }

    private var reminderButton: some View {
        Button {
            reminderDate = item.reminderDate ?? store.suggestedReminderDate(for: item.text)
            showsReminderPopover = true
        } label: {
            Image(systemName: item.reminderDate == nil ? "bell" : "bell.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(item.reminderDate == nil ? Theme.textTertiary : paperStyle.brand)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reminderHelpText)
        .accessibilityLabel(reminderHelpText)
        .popover(isPresented: $showsReminderPopover, arrowEdge: .trailing) {
            reminderPopover
        }
    }

    private var reminderPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(paperStyle.brand)
                Text("事项提醒")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }

            Text(item.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)

            DatePicker(
                "提醒时间",
                selection: $reminderDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .font(.system(size: 12, design: .rounded))

            Text(reminderProviderDescription)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                if item.reminderDate != nil {
                    Button("移除提醒", role: .destructive) {
                        store.removeReminder(item)
                        showsReminderPopover = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.red.opacity(0.75))
                }

                Spacer()

                Button("设置提醒") {
                    store.setReminder(item, at: reminderDate)
                    showsReminderPopover = false
                }
                .buttonStyle(.borderedProminent)
                .tint(paperStyle.brand)
                .controlSize(.small)
                .disabled(reminderDate <= Date())
            }
        }
        .padding(16)
        .frame(width: 286)
    }

    private var reminderHelpText: String {
        guard let date = item.reminderDate else { return "设置提醒" }
        return "提醒：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var reminderProviderDescription: String {
        switch item.reminderProvider {
        case .appleReminders:
            return "已同步到 Apple「提醒事项」的 Sticky 列表。"
        case .localNotification:
            return "当前由 Sticky 的系统通知提醒。"
        case .none:
            return "优先同步到 Apple「提醒事项」；若权限不可用，则使用 Sticky 系统通知。"
        }
    }

    private var noteButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: hasNote ? "note.text" : "plus")
                .font(.system(size: hasNote ? 11 : 10, weight: .medium))
                .foregroundStyle(hasNote ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasNote ? "编辑备注" : "添加备注")
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.noteBorder)
                .frame(height: 0.5)
                .padding(.leading, 36)
                .padding(.trailing, 8)
                .padding(.vertical, 4)

            TextEditor(text: $noteText)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(Theme.noteText)
                .scrollContentBackground(.hidden)
                .focused($noteFocused)
                .frame(minHeight: 36, maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.noteBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(noteFocused ? Theme.accent.opacity(0.2) : Theme.noteBorder, lineWidth: 0.5)
                        .animation(.easeOut(duration: 0.15), value: noteFocused)
                )
                .padding(.leading, 36)
                .padding(.trailing, 8)
                .onChange(of: noteFocused) {
                    publishInteractionState()
                }
                .onChange(of: noteText) {
                    store.updateNote(item, note: noteText)
                }

            if noteText.isEmpty && !noteFocused {
                Text("添加备注…")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 44)
                    .padding(.top, -32)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, 4)
    }

    private func toggleCompletion() {
        let wasCompleted = item.completed

        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            store.toggle(item)
        }

        if !wasCompleted {
            onComplete?()
        }
    }

    private func finishTitleEditing() {
        guard isEditingTitle else { return }

        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.text {
            store.updateText(item, text: trimmed)
            // 标题编辑是用户明确提交的动作，不能等异步写回再让旧内容覆盖视图。
            store.saveImmediately()
        }

        isEditingTitle = false
    }

    private func publishInteractionState() {
        onInteractionChange(titleFocused || noteFocused || showsReminderPopover)
    }
}

// MARK: - Completion Celebration

private struct CompletionConfettiView: View {
    let seed: Int

    @State private var isExpanded = false
    @Environment(\.stickyPaperStyle) private var paperStyle

    private var pieces: [ConfettiPiece] {
        (0..<88).map { ConfettiPiece(index: $0, seed: seed) }
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                ConfettiPieceView(piece: piece)
                    .frame(width: piece.size.width, height: piece.size.height)
                    .scaleEffect(isExpanded ? piece.endScale : 0.35)
                    .rotationEffect(.degrees(isExpanded ? piece.endRotation : piece.startRotation))
                    .position(x: 160 + piece.startX, y: 58 + piece.startY)
                    .offset(x: isExpanded ? piece.endX : 0, y: isExpanded ? piece.endY : 0)
                    .opacity(isExpanded ? 0 : 1)
                    .animation(
                        .easeOut(duration: piece.duration).delay(piece.delay),
                        value: isExpanded
                    )
            }

            Circle()
                .strokeBorder(paperStyle.brand.opacity(isExpanded ? 0 : 0.35), lineWidth: 2)
                .frame(width: isExpanded ? 154 : 18, height: isExpanded ? 154 : 18)
                .position(x: 160, y: 62)
                .opacity(isExpanded ? 0 : 1)
                .animation(.easeOut(duration: 0.55), value: isExpanded)
        }
        .onAppear {
            DispatchQueue.main.async {
                isExpanded = true
            }
        }
    }
}

private struct ConfettiPiece: Identifiable {
    let id: Int
    let color: Color
    let size: CGSize
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let startRotation: Double
    let endRotation: Double
    let endScale: CGFloat
    let delay: Double
    let duration: Double
    let shape: ConfettiShape

    init(index: Int, seed: Int) {
        id = index
        color = Theme.confettiColors[(index + seed) % Theme.confettiColors.count]

        let spread = ConfettiPiece.value(index, seed, salt: 7)
        let fall = ConfettiPiece.value(index, seed, salt: 19)
        let drift = ConfettiPiece.value(index, seed, salt: 31)
        let spin = ConfettiPiece.value(index, seed, salt: 43)
        let lift = ConfettiPiece.value(index, seed, salt: 59)

        size = CGSize(
            width: CGFloat(4 + (index + seed) % 7),
            height: CGFloat(index.isMultiple(of: 3) ? 4 : 8 + (index + seed) % 8)
        )
        startX = CGFloat((spread - 0.5) * 22)
        startY = CGFloat((drift - 0.5) * 14)
        endX = CGFloat((spread - 0.5) * 335)
        endY = CGFloat(56 + fall * 190 - lift * 42)
        startRotation = Double(index * 19 + seed * 11)
        endRotation = startRotation + Double(220 + spin * 720)
        endScale = CGFloat(0.72 + drift * 0.5)
        delay = Double(index % 14) * 0.012
        duration = 0.74 + Double(index % 8) * 0.06
        shape = ConfettiShape(rawValue: (index + seed) % ConfettiShape.allCases.count) ?? .rectangle
    }

    private static func value(_ index: Int, _ seed: Int, salt: Int) -> Double {
        let raw = abs((index + 1) * 1103515245 + (seed + 13) * 12345 + salt * 265443576)
        return Double(raw % 1000) / 1000.0
    }
}

private enum ConfettiShape: Int, CaseIterable {
    case rectangle
    case circle
    case capsule
}

private struct ConfettiPieceView: View {
    let piece: ConfettiPiece

    var body: some View {
        switch piece.shape {
        case .rectangle:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(piece.color)
        case .circle:
            Circle()
                .fill(piece.color)
        case .capsule:
            Capsule()
                .fill(piece.color)
        }
    }
}

private final class CompletionSoundPlayer: NSObject, NSSoundDelegate {
    static let shared = CompletionSoundPlayer()

    private var activeSounds: [NSSound] = []
    private let delays: [TimeInterval] = [0, 0.14, 0.28]

    func playTripleChime() {
        delays.forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.playBell()
            }
        }
    }

    private func playBell() {
        guard let soundURL = AppResources.url(
            forResource: "task-complete-bell",
            withExtension: "wav"
        ), let sound = NSSound(contentsOf: soundURL, byReference: false) else {
            NSSound.beep()
            return
        }

        sound.volume = 0.48
        sound.delegate = self
        activeSounds.append(sound)
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        activeSounds.removeAll { $0 === sound }
    }
}
