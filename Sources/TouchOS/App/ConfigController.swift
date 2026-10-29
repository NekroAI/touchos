import AppKit
import Observation
import OSLog
import TouchOSCore

/// 用户配置（K8）：启动时加载，修改后 300 ms 防抖写盘（FR-10.3），变更通知各模块。
/// 加载失败时使用默认配置且不覆盖原文件，直到用户修改或从备份恢复（FR-10.2）
@MainActor
@Observable
final class ConfigController {
    /// FR-10.3
    static let saveDelay: TimeInterval = 0.3
    /// 导出文件扩展名（FR-10.9）
    static let exportExtension = "touchos.json"

    @ObservationIgnored private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "config")
    @ObservationIgnored private let store: ConfigStore
    private(set) var config: AppConfig
    /// 加载失败的原因，设置页显示"配置已损坏，可从备份恢复"
    private(set) var problem: String?
    /// 首次启动（没有配置文件）：显示引导
    let isFirstLaunch: Bool
    @ObservationIgnored private var observers: [(AppConfig) -> Void] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(store: ConfigStore = .standard) {
        self.store = store
        let loaded = store.load()
        config = loaded.config
        isFirstLaunch = loaded.isNew
        if case .damaged(let reason) = loaded.problem {
            problem = reason
            log.error("config damaged: \(reason, privacy: .public)")
        }
        if loaded.isNew { scheduleSave() }
    }

    /// 注册变更回调并立即以当前配置调用一次
    func observe(_ handler: @escaping (AppConfig) -> Void) {
        observers.append(handler)
        handler(config)
    }

    func update(_ change: (inout AppConfig) -> Void) {
        var c = config
        change(&c)
        replace(c)
    }

    /// 整体替换（导入、恢复、编辑器保存）
    func replace(_ new: AppConfig) {
        guard new != config else { return }
        config = new
        for o in observers { o(new) }
        scheduleSave()
    }

    /// 退出前立即写盘
    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        save()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func save() {
        saveWork = nil
        do {
            try store.save(config)
            problem = nil
        } catch {
            log.error("config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 备份、导入、导出

    var backups: [URL] { store.backups() }

    func restore(_ backup: URL) throws {
        let c = try store.restore(backup)
        config = c
        problem = nil
        for o in observers { o(c) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    func export(to url: URL) throws {
        try config.encoded().write(to: url, options: .atomic)
    }

    /// 读取导入文件；返回其中会运行命令的动作，由界面逐条确认后再替换（FR-9.5）
    static func readImport(_ url: URL) throws -> (config: AppConfig, risky: [(panel: String, slot: String, action: Action)]) {
        let c = try AppConfig.decode(try Data(contentsOf: url))
        let risky = c.panels.flatMap { p in p.slots.filter(\.action.runsCode).map { (p.name, $0.title, $0.action) } }
        return (c, risky)
    }
}
