import Foundation

// 布局编辑器的纯逻辑（K12、FR-11.4、FR-10.6）：放置校验、改网格大小、环形重建、生成不重复的 ID

extension Layout {
    /// 网格单元能否放下（不越界、不与其它网格槽位重叠）；`ignoring` 为正在移动的槽位自身
    public func canPlace(_ cell: GridCell, ignoring: SlotID? = nil) -> Bool {
        guard cell.row >= 0, cell.col >= 0, cell.rowSpan >= 1, cell.colSpan >= 1,
              cell.row + cell.rowSpan <= rows, cell.col + cell.colSpan <= cols else { return false }
        return !slots.contains { s in
            guard s.id != ignoring, case .cell(let c) = s.shape else { return false }
            return c.overlaps(cell)
        }
    }

    /// 某个单元格上的槽位
    public func slot(atRow row: Int, col: Int) -> Slot? {
        slots.first { s in
            guard case .cell(let c) = s.shape else { return false }
            return (c.row..<(c.row + c.rowSpan)).contains(row) && (c.col..<(c.col + c.colSpan)).contains(col)
        }
    }

    /// 拖动放置（D29）：落点空着就移过去；压到别的按钮时，被压住的按钮整体平移到空出来的位置
    /// （同尺寸即互换）。平移后越界或重叠时放不下，返回 nil
    public func moving(_ id: SlotID, to target: GridCell) -> Layout? {
        guard let i = slots.firstIndex(where: { $0.id == id }), case .cell(let source) = slots[i].shape else { return nil }
        if target == source { return self }
        let dr = source.row - target.row, dc = source.col - target.col
        var copy = self
        copy.slots[i].shape = .cell(target)
        for (j, s) in slots.enumerated() where j != i {
            guard case .cell(let c) = s.shape, c.overlaps(target) else { continue }
            copy.slots[j].shape = .cell(GridCell(row: c.row + dr, col: c.col + dc, rowSpan: c.rowSpan, colSpan: c.colSpan))
        }
        let cells = copy.slots.compactMap { s -> GridCell? in if case .cell(let c) = s.shape { c } else { nil } }
        for (k, c) in cells.enumerated() {
            guard c.row >= 0, c.col >= 0, c.row + c.rowSpan <= rows, c.col + c.colSpan <= cols,
                  !cells[(k + 1)...].contains(where: c.overlaps) else { return nil }
        }
        return copy
    }

    /// 环形外圈的项目移到第 `index` 位（顺时针，从正上方起）
    public func movingRingItem(_ id: SlotID, to index: Int) -> Layout {
        var items = ringItems
        guard let from = items.firstIndex(where: { $0.id == id }) else { return self }
        let item = items.remove(at: from)
        items.insert(item, at: min(max(index, 0), items.count))
        return rebuiltRing(items: items)
    }

    /// 改网格行列数；有槽位会越界时返回 nil（编辑器提示先移动或删除）
    public func resized(rows: Int, cols: Int) -> Layout? {
        guard (1...AppConfig.maxRows).contains(rows), (1...AppConfig.maxCols).contains(cols) else { return nil }
        var copy = self
        copy.rows = rows
        copy.cols = cols
        let fits = slots.allSatisfy { s in
            guard case .cell(let c) = s.shape else { return true }
            return c.row + c.rowSpan <= rows && c.col + c.colSpan <= cols
        }
        return fits ? copy : nil
    }

    /// 环形布局的外圈项目（按顺时针顺序）与中心
    public var ringItems: [Slot] { slots.filter { !Self.isRingCenter($0) } }
    public var ringCenter: Slot? { slots.first(where: Self.isRingCenter) }

    static func isRingCenter(_ s: Slot) -> Bool {
        if case .sector(let sector) = s.shape { sector.innerRadius == 0 && sector.isFullCircle } else { false }
    }

    /// 按新的项目列表重建环形布局（保留 ID、名称与中心）
    public func rebuiltRing(items: [Slot], center: Slot?? = .none) -> Layout {
        Layout.ring(id: id, name: name, items: items, center: center ?? ringCenter)
    }
}

extension GridCell {
    func overlaps(_ o: GridCell) -> Bool {
        row < o.row + o.rowSpan && o.row < row + rowSpan && col < o.col + o.colSpan && o.col < col + colSpan
    }
}

extension AppConfig {
    /// 在 `existing` 之外生成形如 `base`、`base-2`、`base-3` 的 ID
    public static func uniqueID(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    public var allSlotIDs: Set<String> { Set(panels.flatMap { $0.slots.map(\.id.raw) }) }

    /// 复制面板：新的面板 ID 与槽位 ID，名称加"副本"
    public func duplicate(_ panel: Layout) -> Layout {
        var copy = Self.instance(of: panel, id: Self.uniqueID(panel.id, existing: Set(panels.map(\.id))), used: allSlotIDs)
        copy.name = panel.name + " 副本"
        return copy
    }

    /// 重置面板：换成模板的内容（含名称），保留面板 ID 与指向它的绑定；按钮 ID 重新生成
    public mutating func resetPanel(_ id: String, to template: Layout) {
        guard let i = panels.firstIndex(where: { $0.id == id }) else { return }
        let used = Set(panels.filter { $0.id != id }.flatMap { $0.slots.map(\.id.raw) })
        panels[i] = Self.instance(of: template, id: id, used: used)
    }

    /// 以 `id` 为新面板 ID 的模板副本，按钮 ID 改为 `<id>.<原后缀>` 并避开 `used`
    static func instance(of panel: Layout, id: String, used: Set<String>) -> Layout {
        var used = used
        var copy = panel
        copy.id = id
        copy.slots = panel.slots.map { s in
            var t = s
            let suffix = s.id.raw.hasPrefix(panel.id + ".") ? String(s.id.raw.dropFirst(panel.id.count + 1)) : s.id.raw
            let new = uniqueID("\(id).\(suffix)", existing: used)
            used.insert(new)
            t.id = SlotID(new)
            return t
        }
        return copy
    }

    /// 删除面板，同时删掉指向它的绑定；最后一个面板不能删
    public mutating func removePanel(_ id: String) {
        guard panels.count > 1 else { return }
        panels.removeAll { $0.id == id }
        bindings.removeAll { $0.panel == id }
    }

    /// 某个唤起方式绑定的面板；nil 为默认面板
    public func binding(for trigger: PanelTrigger) -> String? {
        bindings.first { $0.trigger == trigger.key }?.panel
    }

    public mutating func bind(_ trigger: PanelTrigger, to panel: String?) {
        bindings.removeAll { $0.trigger == trigger.key }
        if let panel { bindings.append(Binding(trigger: trigger, panel: panel)) }
    }
}
