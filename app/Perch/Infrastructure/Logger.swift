import os

enum AppLog {
    static let subsystem = "com.jurajkrivda.perch"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let menu = Logger(subsystem: subsystem, category: "menu")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let windows = Logger(subsystem: subsystem, category: "windows")
}

