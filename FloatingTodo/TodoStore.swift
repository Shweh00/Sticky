import Foundation
import Combine
import SwiftUI
import AppKit

class TodoStore: ObservableObject {
    @Published var pages: [TodoPage] = []
    @Published var activePageId: UUID?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var canUndoDelete = false

    private let jsonURL: URL
    private let backupURL: URL
    private let markdownURL: URL
    private let pageNotesDirectoryName = "Sticky"
    private let tasksStartMarker = "<!-- sticky:tasks:start -->"
    private let tasksEndMarker = "<!-- sticky:tasks:end -->"
    private var lastDeletedTodo: DeletedTodo?
    private var undoWorkItem: DispatchWorkItem?
    private var syncMonitor: DispatchSourceTimer?
    private var lastKnownObsidianContents: [String: String] = [:]
    private let reminderManager = ReminderManager()

    init(storageDirectory: URL? = nil, markdownURL: URL? = nil) {
        let dir = storageDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".floating-todo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.jsonURL = dir.appendingPathComponent("todos.json")
        self.backupURL = dir.appendingPathComponent("todos.json.bak")
        self.markdownURL = markdownURL ?? Self.markdownURL(in: dir)
        load()
        _ = importObsidianChanges()
        performSave()
        startObsidianSyncMonitoring()
    }

    deinit {
        syncMonitor?.cancel()
    }

    var todos: [TodoItem] {
        guard let index = activePageIndex else { return [] }
        return pages[index].todos
    }

    var activePageTitle: String {
        guard let index = activePageIndex else { return "待办事项" }
        return pages[index].title
    }

    private var activePageIndex: Int? {
        guard !pages.isEmpty else { return nil }
        if let activePageId,
           let index = pages.firstIndex(where: { $0.id == activePageId }) {
            return index
        }
        return 0
    }

    // MARK: - CRUD

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateActivePage { page in
            page.todos.insert(TodoItem(text: trimmed), at: 0)
        }
    }

    func toggle(_ item: TodoItem) {
        updateActivePage { page in
            guard let index = page.todos.firstIndex(where: { $0.id == item.id }) else { return }
            page.todos[index].completed.toggle()
        }
        synchronizeReminder(for: item.id)
    }

    func delete(_ item: TodoItem) {
        var didDelete = false
        var deletedItem: TodoItem?
        updateActivePage { page in
            guard let index = page.todos.firstIndex(where: { $0.id == item.id }) else { return }
            lastDeletedTodo = DeletedTodo(pageId: page.id, item: page.todos[index], index: index)
            deletedItem = page.todos[index]
            page.todos.remove(at: index)
            didDelete = true
        }
        if didDelete {
            if let deletedItem {
                reminderManager.remove(item: deletedItem)
            }
            scheduleUndoExpiry()
        }
    }

    func undoLastDelete() {
        guard let deleted = lastDeletedTodo,
              let pageIndex = pages.firstIndex(where: { $0.id == deleted.pageId }) else {
            clearUndoState()
            return
        }

        let insertionIndex = min(deleted.index, pages[pageIndex].todos.count)
        pages[pageIndex].todos.insert(deleted.item, at: insertionIndex)
        _ = prioritizeIncompleteTodos(in: &pages[pageIndex])
        activePageId = pages[pageIndex].id
        clearUndoState()
        save()

        if let reminderDate = deleted.item.reminderDate {
            setReminder(deleted.item, at: reminderDate)
        }
    }

    func move(item: TodoItem, to target: TodoItem) {
        updateActivePage { page in
            guard let from = page.todos.firstIndex(where: { $0.id == item.id }),
                  let to = page.todos.firstIndex(where: { $0.id == target.id }),
                  from != to else { return }
            guard page.todos[from].completed == page.todos[to].completed else { return }
            page.todos.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    /// 在 pending 子列表中上移一位
    func moveUp(_ item: TodoItem) {
        updateActivePage { page in
            let pendingIds = page.todos.filter { !$0.completed }.map { $0.id }
            guard let pendingIndex = pendingIds.firstIndex(of: item.id),
                  pendingIndex > 0 else { return }
            // 在全量数组中交换，保证已完成事项不会被拖入待办区。
            let targetId = pendingIds[pendingIndex - 1]
            guard let fromGlobal = page.todos.firstIndex(where: { $0.id == item.id }),
                  let toGlobal = page.todos.firstIndex(where: { $0.id == targetId }) else { return }
            page.todos.swapAt(fromGlobal, toGlobal)
        }
    }

    /// 在 pending 子列表中下移一位
    func moveDown(_ item: TodoItem) {
        updateActivePage { page in
            let pendingIds = page.todos.filter { !$0.completed }.map { $0.id }
            guard let pendingIndex = pendingIds.firstIndex(of: item.id),
                  pendingIndex < pendingIds.count - 1 else { return }
            let targetId = pendingIds[pendingIndex + 1]
            guard let fromGlobal = page.todos.firstIndex(where: { $0.id == item.id }),
                  let toGlobal = page.todos.firstIndex(where: { $0.id == targetId }) else { return }
            page.todos.swapAt(fromGlobal, toGlobal)
        }
    }

    func updateNote(_ item: TodoItem, note: String) {
        updateActivePage { page in
            guard let index = page.todos.firstIndex(where: { $0.id == item.id }) else { return }
            page.todos[index].note = note
        }
        synchronizeReminder(for: item.id)
    }

    func updateText(_ item: TodoItem, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateActivePage { page in
            guard let index = page.todos.firstIndex(where: { $0.id == item.id }) else { return }
            page.todos[index].text = trimmed
        }
        synchronizeReminder(for: item.id)
    }

    func setReminder(_ item: TodoItem, at date: Date) {
        guard let location = itemLocation(for: item.id) else { return }
        pages[location.pageIndex].todos[location.itemIndex].reminderDate = date
        let scheduledItem = pages[location.pageIndex].todos[location.itemIndex]
        let pageTitle = displayTitle(for: pages[location.pageIndex])
        save()

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.reminderManager.schedule(
                    item: scheduledItem,
                    pageTitle: pageTitle,
                    at: date
                )
                await MainActor.run {
                    guard let currentLocation = self.itemLocation(for: item.id),
                          self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].reminderDate == date else {
                        var obsoleteReminder = scheduledItem
                        obsoleteReminder.reminderProvider = result.provider
                        obsoleteReminder.eventKitIdentifier = result.eventKitIdentifier
                        self.reminderManager.remove(item: obsoleteReminder)
                        return
                    }
                    self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].reminderDate = date
                    self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].reminderProvider = result.provider
                    self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].eventKitIdentifier = result.eventKitIdentifier
                    self.saveImmediately()
                }
            } catch {
                await MainActor.run {
                    if let currentLocation = self.itemLocation(for: item.id) {
                        self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].reminderDate = nil
                        self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].reminderProvider = nil
                        self.pages[currentLocation.pageIndex].todos[currentLocation.itemIndex].eventKitIdentifier = nil
                        self.saveImmediately()
                    }
                    self.publishSyncError("提醒设置失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func removeReminder(_ item: TodoItem) {
        guard let location = itemLocation(for: item.id) else { return }
        let linkedItem = pages[location.pageIndex].todos[location.itemIndex]
        reminderManager.remove(item: linkedItem)
        pages[location.pageIndex].todos[location.itemIndex].reminderDate = nil
        pages[location.pageIndex].todos[location.itemIndex].reminderProvider = nil
        pages[location.pageIndex].todos[location.itemIndex].eventKitIdentifier = nil
        save()
    }

    func suggestedReminderDate(for text: String, now: Date = Date()) -> Date {
        let calendar = Calendar.current

        if text.contains("明天") {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }

        if text.contains("今天") {
            let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
            return nineAM > now ? nineAM : now.addingTimeInterval(3_600)
        }

        if let regex = try? NSRegularExpression(pattern: #"([0-9]{1,2})\s*[号日]"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let dayRange = Range(match.range(at: 1), in: text),
           let day = Int(text[dayRange]), (1...31).contains(day) {
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = day
            components.hour = 9
            components.minute = 0
            components.second = 0

            if let candidate = calendar.date(from: components), candidate > now {
                return candidate
            }

            if let nextMonth = calendar.date(byAdding: .month, value: 1, to: now) {
                components = calendar.dateComponents([.year, .month], from: nextMonth)
                components.day = day
                components.hour = 9
                components.minute = 0
                components.second = 0
                if let candidate = calendar.date(from: components) {
                    return candidate
                }
            }
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    func selectPage(_ pageId: UUID) {
        guard pages.contains(where: { $0.id == pageId }) else { return }
        activePageId = pageId
        save()
    }

    func movePage(_ pageId: UUID, toIndex requestedIndex: Int) {
        guard let sourceIndex = pages.firstIndex(where: { $0.id == pageId }),
              !pages.isEmpty else { return }
        let targetIndex = min(max(requestedIndex, 0), pages.count - 1)
        guard sourceIndex != targetIndex else { return }

        let page = pages.remove(at: sourceIndex)
        pages.insert(page, at: min(targetIndex, pages.count))
        _ = synchronizePagePrioritiesWithOrder()
        save()
    }

    func addPage(title: String? = nil) {
        let page = TodoPage(
            title: title ?? "便贴 \(pages.count + 1)",
            colorHue: nextAvailablePageHue()
        )
        pages.append(page)
        _ = synchronizePagePrioritiesWithOrder()
        activePageId = page.id
        save()
    }

    func updateActivePageTitle(_ title: String) {
        updateActivePage { page in
            page.title = title
        }
        guard let pageIndex = activePageIndex else { return }
        for item in pages[pageIndex].todos where item.reminderDate != nil {
            synchronizeReminder(for: item.id)
        }
    }

    @discardableResult
    func deletePage(_ pageId: UUID) -> Bool {
        guard pages.count > 1,
              let index = pages.firstIndex(where: { $0.id == pageId }) else {
            return false
        }

        let pageToDelete = pages[index]
        let noteURL = pageMarkdownURL(for: pageToDelete)
        do {
            if FileManager.default.fileExists(atPath: noteURL.path) {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: noteURL, resultingItemURL: &trashedURL)
            }
        } catch {
            print("Failed to move Obsidian note to Trash: \(error)")
            publishSyncError("标签未删除：Obsidian 笔记无法移入废纸篓")
            return false
        }

        lastKnownObsidianContents.removeValue(forKey: noteURL.lastPathComponent.lowercased())
        for item in pageToDelete.todos where item.reminderDate != nil {
            reminderManager.remove(item: item)
        }
        pages.remove(at: index)
        _ = synchronizePagePrioritiesWithOrder()
        if activePageId == pageId {
            activePageId = pages[min(index, pages.count - 1)].id
        }
        clearUndoState()
        performSave()
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            normalizePages()
            return
        }

        do {
            try applyStoredData(from: jsonURL)
            // 迁移字段先在内存中补齐；读取 Obsidian 后再统一落盘，避免启动时覆盖外部修改。
            _ = normalizePages()
        } catch {
            print("Failed to load todos: \(error)")
            loadBackup()
        }
    }

    private var saveWorkItem: DispatchWorkItem?

    func save() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSave()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func saveImmediately() {
        saveWorkItem?.cancel()
        performSave()
    }

    private func performSave() {
        normalizePages()
        synchronizeNoteFilenamesWithTitles()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let workspace = TodoWorkspace(activePageId: activePageId, pages: pages)
            let data = try encoder.encode(workspace)
            backupCurrentDataIfNeeded()
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            print("Failed to save JSON: \(error)")
            publishSyncError("本地待办保存失败")
            return
        }

        syncMarkdown()
    }

    private func syncMarkdown() {
        do {
            try FileManager.default.createDirectory(
                at: markdownURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: pageNotesDirectoryURL,
                withIntermediateDirectories: true
            )

            for page in pages {
                let noteURL = pageMarkdownURL(for: page)
                let existingContent = try? String(contentsOf: noteURL, encoding: .utf8)
                let content = pageMarkdownContent(for: page, preserving: existingContent)
                if existingContent != content {
                    try content.write(to: noteURL, atomically: true, encoding: .utf8)
                }
                lastKnownObsidianContents[noteURL.lastPathComponent.lowercased()] = content
            }
            try markdownContent().write(to: markdownURL, atomically: true, encoding: .utf8)
            publishSyncError(nil)
        } catch {
            print("Failed to sync Obsidian markdown: \(error)")
            publishSyncError("Obsidian 同步失败")
        }
    }

    func markdownContent() -> String {
        var lines: [String] = ["# Floating Todo", ""]

        for page in pages {
            let noteName = (page.obsidianNoteFilename ?? "").replacingOccurrences(of: ".md", with: "")
            lines.append("## [[\(pageNotesDirectoryName)/\(noteName)|\(displayTitle(for: page))]]")
            lines.append("")

            appendMarkdown(for: page.todos.filter { !$0.completed }, checked: false, to: &lines)
            appendMarkdown(for: page.todos.filter { $0.completed }, checked: true, to: &lines)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    func openObsidianNote(for pageId: UUID) {
        if importObsidianChanges() {
            performSave()
        } else {
            syncMarkdown()
        }

        guard let page = pages.first(where: { $0.id == pageId }) else { return }

        let noteURL = pageMarkdownURL(for: page).deletingPathExtension().standardizedFileURL
        let fallbackRoot = markdownURL.deletingLastPathComponent().standardizedFileURL
        let vaultRoot = obsidianVaultRoot(containing: noteURL) ?? fallbackRoot
        let rootComponents = vaultRoot.pathComponents
        let noteComponents = noteURL.pathComponents
        let relativeNotePath: String
        if noteComponents.starts(with: rootComponents) {
            relativeNotePath = noteComponents.dropFirst(rootComponents.count).joined(separator: "/")
        } else {
            relativeNotePath = "\(pageNotesDirectoryName)/\(noteURL.lastPathComponent)"
        }

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultRoot.lastPathComponent),
            URLQueryItem(name: "file", value: relativeNotePath),
        ]

        if let obsidianURL = components.url, NSWorkspace.shared.open(obsidianURL) {
            return
        }

        NSWorkspace.shared.open(pageMarkdownURL(for: page))
    }

    private func obsidianVaultRoot(containing fileURL: URL) -> URL? {
        var directory = fileURL.deletingLastPathComponent().standardizedFileURL

        while directory.path != "/" {
            let settingsDirectory = directory.appendingPathComponent(".obsidian", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: settingsDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { break }
            directory = parent
        }

        return nil
    }

    private var pageNotesDirectoryURL: URL {
        markdownURL.deletingLastPathComponent()
            .appendingPathComponent(pageNotesDirectoryName, isDirectory: true)
    }

    private func pageMarkdownURL(for page: TodoPage) -> URL {
        let filename = page.obsidianNoteFilename ?? Self.safeNoteFilename(for: displayTitle(for: page))
        return pageNotesDirectoryURL.appendingPathComponent(filename)
    }

    private func pageMarkdownContent(for page: TodoPage, preserving existingContent: String?) -> String {
        var lines = existingContent?.components(separatedBy: .newlines) ?? []
        while lines.last == "" { lines.removeLast() }

        if lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") {
            if let idIndex = lines[1..<closingIndex].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("sticky-id:")
            }) {
                lines[idIndex] = "sticky-id: \(page.id.uuidString)"
            } else {
                lines.insert("sticky-id: \(page.id.uuidString)", at: closingIndex)
            }
        } else {
            lines.insert(contentsOf: ["---", "sticky-id: \(page.id.uuidString)", "---", ""], at: 0)
        }

        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[headingIndex] = "# \(displayTitle(for: page))"
        } else {
            let insertionIndex = (lines.dropFirst().firstIndex(of: "---") ?? 2) + 1
            lines.insert(contentsOf: ["", "# \(displayTitle(for: page))"], at: insertionIndex)
        }

        var preservedLines: [String] = []
        var insideManagedTasks = false
        var skippingTaskNote = false
        for line in lines {
            if line == tasksStartMarker {
                insideManagedTasks = true
                continue
            }
            if line == tasksEndMarker {
                insideManagedTasks = false
                continue
            }
            if insideManagedTasks { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.parseTaskLine(trimmed) != nil {
                skippingTaskNote = true
                continue
            }
            if skippingTaskNote, trimmed.hasPrefix(">") {
                continue
            }
            skippingTaskNote = false
            preservedLines.append(line)
        }

        while preservedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            preservedLines.removeLast()
        }
        preservedLines.append("")
        preservedLines.append(tasksStartMarker)
        appendMarkdown(for: page.todos.filter { !$0.completed }, checked: false, to: &preservedLines)
        appendMarkdown(for: page.todos.filter { $0.completed }, checked: true, to: &preservedLines)
        preservedLines.append(tasksEndMarker)
        preservedLines.append("")

        return preservedLines.joined(separator: "\n")
    }

    private func startObsidianSyncMonitoring() {
        guard syncMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let obsidianChanged = self.importObsidianChanges()
            let remindersChanged = self.importAppleReminderChanges()
            if obsidianChanged || remindersChanged {
                self.performSave()
            }
        }
        timer.resume()
        syncMonitor = timer
    }

    @discardableResult
    private func importObsidianChanges() -> Bool {
        do {
            try FileManager.default.createDirectory(at: pageNotesDirectoryURL, withIntermediateDirectories: true)
            let noteURLs = try FileManager.default.contentsOfDirectory(
                at: pageNotesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            var didChange = false
            var matchedPageIds = Set<UUID>()

            for noteURL in noteURLs {
                let content = try String(contentsOf: noteURL, encoding: .utf8)
                let contentKey = noteURL.lastPathComponent.lowercased()
                if lastKnownObsidianContents[contentKey] == content { continue }

                let parsed = parseObsidianPage(content, fallbackTitle: noteURL.deletingPathExtension().lastPathComponent)
                let matchingIndex = parsed.id.flatMap { id in
                    pages.firstIndex(where: { $0.id == id && !matchedPageIds.contains($0.id) })
                } ?? pages.firstIndex(where: {
                    $0.obsidianNoteFilename?.caseInsensitiveCompare(noteURL.lastPathComponent) == .orderedSame
                        && !matchedPageIds.contains($0.id)
                })

                if let index = matchingIndex {
                    let filenameChanged = pages[index].obsidianNoteFilename?.caseInsensitiveCompare(
                        noteURL.lastPathComponent
                    ) != .orderedSame
                    let importedTitle = filenameChanged && parsed.id != nil
                        ? noteURL.deletingPathExtension().lastPathComponent
                        : parsed.title
                    let reconciledTodos = reconcileTodos(parsed.tasks, with: pages[index].todos)
                    if pages[index].title != importedTitle
                        || pages[index].todos != reconciledTodos
                        || pages[index].obsidianNoteFilename != noteURL.lastPathComponent {
                        pages[index].title = importedTitle
                        pages[index].todos = reconciledTodos
                        pages[index].obsidianNoteFilename = noteURL.lastPathComponent
                        didChange = true
                    }
                    matchedPageIds.insert(pages[index].id)
                } else {
                    let newPage = TodoPage(
                        id: parsed.id ?? UUID(),
                        title: parsed.title,
                        todos: reconcileTodos(parsed.tasks, with: []),
                        colorHue: nextAvailablePageHue(),
                        obsidianNoteFilename: noteURL.lastPathComponent
                    )
                    pages.append(newPage)
                    matchedPageIds.insert(newPage.id)
                    didChange = true
                }

                lastKnownObsidianContents[contentKey] = content
            }

            if didChange {
                _ = normalizePages()
            }
            publishSyncError(nil)
            return didChange
        } catch {
            print("Failed to import Obsidian changes: \(error)")
            publishSyncError("Obsidian 双向同步失败")
            return false
        }
    }

    private func parseObsidianPage(_ content: String, fallbackTitle: String) -> ParsedObsidianPage {
        let lines = content.components(separatedBy: .newlines)
        var pageId: UUID?
        var title: String?
        var tasks: [ParsedObsidianTask] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("sticky-id:") {
                let rawId = trimmed.dropFirst("sticky-id:".count).trimmingCharacters(in: .whitespaces)
                pageId = UUID(uuidString: rawId)
                continue
            }
            if title == nil, line.hasPrefix("# ") {
                let heading = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !heading.isEmpty { title = heading }
                continue
            }
            if let parsedTask = Self.parseTaskLine(trimmed) {
                tasks.append(parsedTask)
                continue
            }
            if trimmed.hasPrefix(">"), !tasks.isEmpty {
                let noteLine = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                tasks[tasks.count - 1].note += tasks[tasks.count - 1].note.isEmpty ? noteLine : "\n\(noteLine)"
            }
        }

        return ParsedObsidianPage(id: pageId, title: title ?? fallbackTitle, tasks: tasks)
    }

    private static func parseTaskLine(_ line: String) -> ParsedObsidianTask? {
        let lowercased = line.lowercased()
        let completed: Bool
        if lowercased.hasPrefix("- [ ] ") {
            completed = false
        } else if lowercased.hasPrefix("- [x] ") {
            completed = true
        } else {
            return nil
        }

        let text = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ParsedObsidianTask(text: text, completed: completed, note: "")
    }

    private func reconcileTodos(_ parsedTasks: [ParsedObsidianTask], with existingTodos: [TodoItem]) -> [TodoItem] {
        var unmatchedTodos = existingTodos
        return parsedTasks.map { parsedTask in
            if let index = unmatchedTodos.firstIndex(where: { $0.text == parsedTask.text }) {
                var todo = unmatchedTodos.remove(at: index)
                todo.completed = parsedTask.completed
                todo.note = parsedTask.note
                return todo
            }
            return TodoItem(text: parsedTask.text, completed: parsedTask.completed, note: parsedTask.note)
        }
    }

    private func updateActivePage(_ update: (inout TodoPage) -> Void) {
        normalizePages()
        guard let index = activePageIndex else { return }
        update(&pages[index])
        _ = prioritizeIncompleteTodos(in: &pages[index])
        activePageId = pages[index].id
        save()
    }

    @discardableResult
    private func prioritizeIncompleteTodos(in page: inout TodoPage) -> Bool {
        let prioritizedTodos = page.todos.filter { !$0.completed } + page.todos.filter(\.completed)
        guard prioritizedTodos != page.todos else { return false }
        page.todos = prioritizedTodos
        return true
    }

    private func itemLocation(for itemId: UUID) -> (pageIndex: Int, itemIndex: Int)? {
        for pageIndex in pages.indices {
            if let itemIndex = pages[pageIndex].todos.firstIndex(where: { $0.id == itemId }) {
                return (pageIndex, itemIndex)
            }
        }
        return nil
    }

    private func synchronizeReminder(for itemId: UUID) {
        guard let location = itemLocation(for: itemId) else { return }
        let item = pages[location.pageIndex].todos[location.itemIndex]
        guard item.reminderDate != nil, item.reminderProvider != nil else { return }
        let pageTitle = displayTitle(for: pages[location.pageIndex])

        Task { [weak self] in
            await self?.reminderManager.update(item: item, pageTitle: pageTitle)
        }
    }

    @discardableResult
    private func importAppleReminderChanges() -> Bool {
        var didChange = false

        for pageIndex in pages.indices {
            for itemIndex in pages[pageIndex].todos.indices {
                let item = pages[pageIndex].todos[itemIndex]
                guard item.reminderProvider == .appleReminders,
                      let identifier = item.eventKitIdentifier,
                      let external = reminderManager.externalState(identifier: identifier) else { continue }

                let externalTitle = external.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !externalTitle.isEmpty, pages[pageIndex].todos[itemIndex].text != externalTitle {
                    pages[pageIndex].todos[itemIndex].text = externalTitle
                    didChange = true
                }
                if pages[pageIndex].todos[itemIndex].note != external.note {
                    pages[pageIndex].todos[itemIndex].note = external.note
                    didChange = true
                }
                if let dueDate = external.dueDate,
                   pages[pageIndex].todos[itemIndex].reminderDate != dueDate {
                    pages[pageIndex].todos[itemIndex].reminderDate = dueDate
                    didChange = true
                }
                if pages[pageIndex].todos[itemIndex].completed != external.completed {
                    pages[pageIndex].todos[itemIndex].completed = external.completed
                    didChange = true
                }
            }
        }

        return didChange
    }

    @discardableResult
    private func normalizePages() -> Bool {
        var didChange = false
        if pages.isEmpty {
            let page = TodoPage(colorHue: nextAvailablePageHue())
            pages = [page]
            activePageId = page.id
            return true
        }

        for index in pages.indices where pages[index].colorHue == nil {
            pages[index].colorHue = nextAvailablePageHue(excluding: index)
            didChange = true
        }

        for index in pages.indices where pages[index].obsidianNoteFilename == nil {
            pages[index].obsidianNoteFilename = nextAvailableNoteFilename(for: pages[index], excluding: index)
            didChange = true
        }

        for index in pages.indices where prioritizeIncompleteTodos(in: &pages[index]) {
            didChange = true
        }

        if activePageId == nil || !pages.contains(where: { $0.id == activePageId }) {
            activePageId = pages[0].id
            didChange = true
        }

        if synchronizePagePrioritiesWithOrder() {
            didChange = true
        }

        return didChange
    }

    @discardableResult
    private func synchronizePagePrioritiesWithOrder() -> Bool {
        guard !pages.isEmpty else { return false }
        var didChange = false

        for index in pages.indices {
            let expectedPriority: TodoPagePriority
            if index == 0 {
                expectedPriority = .high
            } else if pages.count >= 3, index == pages.count - 1 {
                expectedPriority = .low
            } else {
                expectedPriority = .normal
            }

            if pages[index].priority != expectedPriority {
                pages[index].priority = expectedPriority
                didChange = true
            }
        }

        return didChange
    }

    private func nextAvailableNoteFilename(for page: TodoPage, excluding index: Int) -> String {
        let baseFilename = Self.safeNoteFilename(for: displayTitle(for: page))
        let existingNames = Set(
            pages.enumerated().compactMap { currentIndex, page in
                currentIndex == index ? nil : page.obsidianNoteFilename?.lowercased()
            }
        )

        guard existingNames.contains(baseFilename.lowercased()) else {
            return baseFilename
        }

        let stem = URL(fileURLWithPath: baseFilename).deletingPathExtension().lastPathComponent
        return "\(stem)-\(page.id.uuidString.prefix(6)).md"
    }

    private static func safeNoteFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:#[]^|?*\"")
        let sanitized = title
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String((sanitized.isEmpty ? "未命名" : sanitized).prefix(80))
        return "\(stem).md"
    }

    private func synchronizeNoteFilenamesWithTitles() {
        do {
            try FileManager.default.createDirectory(at: pageNotesDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to prepare Obsidian notes directory: \(error)")
            publishSyncError("Obsidian 文件名同步失败")
            return
        }

        var reservedNames = Set<String>()

        for index in pages.indices {
            let currentFilename = pages[index].obsidianNoteFilename
                ?? Self.safeNoteFilename(for: displayTitle(for: pages[index]))
            let desiredFilename = availableNoteFilename(
                for: pages[index],
                currentFilename: currentFilename,
                excluding: index,
                reservedNames: reservedNames
            )
            reservedNames.insert(desiredFilename.lowercased())

            guard currentFilename != desiredFilename else {
                pages[index].obsidianNoteFilename = desiredFilename
                continue
            }

            let oldURL = pageNotesDirectoryURL.appendingPathComponent(currentFilename)
            let newURL = pageNotesDirectoryURL.appendingPathComponent(desiredFilename)

            do {
                if FileManager.default.fileExists(atPath: oldURL.path) {
                    if currentFilename.caseInsensitiveCompare(desiredFilename) == .orderedSame {
                        let temporaryURL = pageNotesDirectoryURL
                            .appendingPathComponent(".sticky-rename-\(UUID().uuidString).md")
                        try FileManager.default.moveItem(at: oldURL, to: temporaryURL)
                        do {
                            try FileManager.default.moveItem(at: temporaryURL, to: newURL)
                        } catch {
                            try? FileManager.default.moveItem(at: temporaryURL, to: oldURL)
                            throw error
                        }
                    } else {
                        try FileManager.default.moveItem(at: oldURL, to: newURL)
                    }
                }

                pages[index].obsidianNoteFilename = desiredFilename
                if let knownContent = lastKnownObsidianContents.removeValue(
                    forKey: currentFilename.lowercased()
                ) {
                    lastKnownObsidianContents[desiredFilename.lowercased()] = knownContent
                }
            } catch {
                print("Failed to rename Obsidian note \(currentFilename): \(error)")
                publishSyncError("Obsidian 文件名同步失败：\(currentFilename)")
            }
        }
    }

    private func availableNoteFilename(
        for page: TodoPage,
        currentFilename: String,
        excluding index: Int,
        reservedNames: Set<String>
    ) -> String {
        let baseFilename = Self.safeNoteFilename(for: displayTitle(for: page))
        let stem = URL(fileURLWithPath: baseFilename).deletingPathExtension().lastPathComponent
        var candidate = baseFilename
        var attempt = 0

        while true {
            let candidateKey = candidate.lowercased()
            let usedByAnotherPage = pages.enumerated().contains { currentIndex, otherPage in
                guard currentIndex != index else { return false }
                return otherPage.obsidianNoteFilename?.lowercased() == candidateKey
            }
            let candidateURL = pageNotesDirectoryURL.appendingPathComponent(candidate)
            let existsAsAnotherFile = FileManager.default.fileExists(atPath: candidateURL.path)
                && currentFilename.caseInsensitiveCompare(candidate) != .orderedSame

            if !reservedNames.contains(candidateKey), !usedByAnotherPage, !existsAsAnotherFile {
                return candidate
            }

            attempt += 1
            let suffix = attempt == 1
                ? String(page.id.uuidString.prefix(6))
                : "\(page.id.uuidString.prefix(6))-\(attempt)"
            candidate = "\(stem)-\(suffix).md"
        }
    }

    private func nextAvailablePageHue(excluding index: Int? = nil) -> Double {
        let existingHues = pages.enumerated().compactMap { currentIndex, page in
            currentIndex == index ? nil : page.colorHue
        }
        return PageColorDistributor.nextHue(avoiding: existingHues)
    }

    private func displayTitle(for page: TodoPage) -> String {
        let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    private func appendMarkdown(for items: [TodoItem], checked: Bool, to lines: inout [String]) {
        for item in items {
            lines.append("- [\(checked ? "x" : " ")] \(item.text)")
            if !item.note.isEmpty {
                for noteLine in item.note.components(separatedBy: "\n") {
                    lines.append("    > \(noteLine)")
                }
            }
        }
    }

    private func applyStoredData(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let workspace = try? decoder.decode(TodoWorkspace.self, from: data) {
            pages = workspace.pages
            activePageId = workspace.activePageId
            return
        }

        let legacyTodos = try decoder.decode([TodoItem].self, from: data)
        let page = TodoPage(title: "待办事项", todos: legacyTodos)
        pages = [page]
        activePageId = page.id
    }

    private func loadBackup() {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            publishSyncError("本地数据无法读取")
            normalizePages()
            return
        }

        do {
            try applyStoredData(from: backupURL)
            _ = normalizePages()
            publishSyncError("主数据损坏，已使用最近备份")
        } catch {
            print("Failed to load backup todos: \(error)")
            publishSyncError("本地数据和备份都无法读取")
            normalizePages()
        }
    }

    private func backupCurrentDataIfNeeded() {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        guard let data = try? Data(contentsOf: jsonURL),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: jsonURL, to: backupURL)
        } catch {
            print("Failed to create todos backup: \(error)")
        }
    }

    private func scheduleUndoExpiry() {
        undoWorkItem?.cancel()
        canUndoDelete = true

        let workItem = DispatchWorkItem { [weak self] in
            self?.clearUndoState()
        }
        undoWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func clearUndoState() {
        undoWorkItem?.cancel()
        undoWorkItem = nil
        lastDeletedTodo = nil
        canUndoDelete = false
    }

    private func publishSyncError(_ message: String?) {
        let update: () -> Void = { [weak self] in
            guard let self else { return }
            self.syncErrorMessage = message
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private static func markdownURL(in storageDirectory: URL) -> URL {
        let configURL = storageDirectory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let configuration = try? JSONDecoder().decode(SyncConfiguration.self, from: data),
           let path = configuration.obsidianMarkdownPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Sticky", isDirectory: true)
            .appendingPathComponent("Floating Todo.md")
    }
}

private enum PageColorDistributor {
    private static let firstHue = 0.57
    private static let goldenAngle = 0.61803398875
    private static let minimumDistance = 0.105

    static func nextHue(avoiding existingHues: [Double]) -> Double {
        for step in 0..<96 {
            let candidate = (firstHue + Double(step) * goldenAngle)
                .truncatingRemainder(dividingBy: 1)
            if existingHues.allSatisfy({ circularDistance($0, candidate) >= minimumDistance }) {
                return candidate
            }
        }

        // 页面数量远超常见浮窗容量时，仍保持稳定且可预测的色相分布。
        return (firstHue + Double(existingHues.count) * goldenAngle)
            .truncatingRemainder(dividingBy: 1)
    }

    private static func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }
}

private struct TodoWorkspace: Codable {
    var activePageId: UUID?
    var pages: [TodoPage]
}

private struct SyncConfiguration: Codable {
    var obsidianMarkdownPath: String?
}

private struct DeletedTodo {
    let pageId: UUID
    let item: TodoItem
    let index: Int
}

private struct ParsedObsidianPage {
    let id: UUID?
    let title: String
    let tasks: [ParsedObsidianTask]
}

private struct ParsedObsidianTask {
    let text: String
    let completed: Bool
    var note: String
}
