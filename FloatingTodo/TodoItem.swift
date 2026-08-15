import Foundation

enum TodoReminderProvider: String, Codable {
    case appleReminders
    case localNotification
}

enum TodoPagePriority: String, Codable, CaseIterable {
    case high
    case normal
    case low

    var displayName: String {
        switch self {
        case .high: return "高"
        case .normal: return "普通"
        case .low: return "低"
        }
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var completed: Bool
    var createdAt: Date
    var note: String
    var reminderDate: Date?
    var reminderProvider: TodoReminderProvider?
    var eventKitIdentifier: String?

    init(
        id: UUID = UUID(),
        text: String,
        completed: Bool = false,
        createdAt: Date = Date(),
        note: String = "",
        reminderDate: Date? = nil,
        reminderProvider: TodoReminderProvider? = nil,
        eventKitIdentifier: String? = nil
    ) {
        self.id = id
        self.text = text
        self.completed = completed
        self.createdAt = createdAt
        self.note = note
        self.reminderDate = reminderDate
        self.reminderProvider = reminderProvider
        self.eventKitIdentifier = eventKitIdentifier
    }

    /// 兼容旧数据：note 字段可能不存在
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        completed = try container.decode(Bool.self, forKey: .completed)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        reminderDate = try container.decodeIfPresent(Date.self, forKey: .reminderDate)
        reminderProvider = try container.decodeIfPresent(TodoReminderProvider.self, forKey: .reminderProvider)
        eventKitIdentifier = try container.decodeIfPresent(String.self, forKey: .eventKitIdentifier)
    }
}

struct TodoPage: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var todos: [TodoItem]
    var createdAt: Date
    /// 页面身份色；可选值让历史 JSON 在第一次加载时平滑迁移。
    var colorHue: Double?
    /// Sticky 管理的 Obsidian 笔记文件名；首次迁移后保持稳定。
    var obsidianNoteFilename: String?
    /// 标签的重要性只影响视觉提示，不强制改变用户的手动排序。
    var priority: TodoPagePriority

    init(
        id: UUID = UUID(),
        title: String = "待办事项",
        todos: [TodoItem] = [],
        createdAt: Date = Date(),
        colorHue: Double? = nil,
        obsidianNoteFilename: String? = nil,
        priority: TodoPagePriority = .normal
    ) {
        self.id = id
        self.title = title
        self.todos = todos
        self.createdAt = createdAt
        self.colorHue = colorHue
        self.obsidianNoteFilename = obsidianNoteFilename
        self.priority = priority
    }

    /// 兼容早期测试数据：createdAt 字段可能不存在
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        todos = try container.decode([TodoItem].self, forKey: .todos)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        colorHue = try container.decodeIfPresent(Double.self, forKey: .colorHue)
        obsidianNoteFilename = try container.decodeIfPresent(String.self, forKey: .obsidianNoteFilename)
        priority = try container.decodeIfPresent(TodoPagePriority.self, forKey: .priority) ?? .normal
    }
}
