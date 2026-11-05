import AppKit
import SwiftUI
import TouchOSCore

/// 调试模式（D52，修订见 D57）：通用设置最底下的开关。开启时诊断日志开始记录、预演脚本可用，
/// 手感调试附带排查用的工具；手感调试本身由菜单栏打开，与这个开关无关。不随 iCloud 同步
enum DebugMode {
    static let defaultsKey = "showDebugOverlayMenu"
    static let didChange = Notification.Name("ai.nekro.touchos.debugModeChanged")

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// 调试模式下手感调试的按钮：日志清除、标记、复制与 AC-17（D51、D52）
enum DebugActions {
    /// AC-17：点按钮后留给用户唤起面板的时间
    static let stallDelay: TimeInterval = 5

    @MainActor
    static func make(tap: EventTapController, cursor: CursorLock, model: TouchTunerModel) -> [(title: String, run: () -> Void)] {
        [
            ("清除日志", { DiagnosticLog.shared.clear() }),
            ("标记：在动", { DiagnosticLog.shared.record("★ 用户标记：光标在动") }),
            ("标记：不动", { DiagnosticLog.shared.record("★ 用户标记：光标不动") }),
            ("复制日志", {
                DiagnosticLog.shared.copyToPasteboard(cursorMode: cursor.mode.rawValue)
                model.log("诊断日志已复制")
            }),
            ("阻塞拦截", {
                tap.scheduleDebugStall(after: stallDelay)
                model.log("已预约：\(Int(stallDelay)) 秒后阻塞拦截（AC-17）")
            }),
        ]
    }
}

/// 调试模式附带的部分：只给开发与排查用，不翻译（D45）
struct DebugSections: View {
    let model: TouchTunerModel
    let actions: [(title: String, run: () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("调试模式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // 五个按钮一行放不下，分两行
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(actions.prefix(3).enumerated()), id: \.offset) { _, a in Button(a.title, action: a.run) }
                }
                GridRow {
                    ForEach(Array(actions.dropFirst(3).enumerated()), id: \.offset) { _, a in Button(a.title, action: a.run) }
                }
            }
            .controlSize(.small)
            Group {
                LatencySection(model: model)
                CursorSection(model: model)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.session.enumerated()), id: \.offset) { _, line in Text(line).lineLimit(1) }
                }
                .frame(height: CGFloat(TouchTunerModel.sessionLines) * 14, alignment: .top)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .lineLimit(1)  // 数值变长时不换行，面板高度不变
        }
    }
}

/// 指针诊断（D47）：面板打开时滑动手指，看事件有没有到拦截、光标有没有被校正
private struct CursorSection: View {
    let model: TouchTunerModel

    /// 应用链接的 SDK 版本（系统按它决定部分行为）。符号来自 dyld 的未公开接口，取不到时显示"—"
    private static let linkedSDK: String = {
        typealias Getter = @convention(c) () -> UInt32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_get_program_sdk_version") else { return "—" }
        let v = unsafeBitCast(symbol, to: Getter.self)()
        return "\(v >> 16).\((v >> 8) & 0xFF)"
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SDK \(Self.linkedSDK) · 丢弃指针事件 \(model.droppedMoves) · 时钟重对齐 \(model.clockResyncs)")
            // 第一次刷新前也占住这一行，面板高度不变
            if let c = model.cursor {
                Text(String(format: "校验 %llu · 校正 %llu · 最大偏离 事件 %.1f / 屏幕 %.1f pt", c.checks, c.corrections,
                            c.maxEventDeviation, c.maxScreenDeviation))
            } else {
                Text("校验 — · 校正 — · 最大偏离 —")
            }
        }
    }
}

/// 延迟实测（NFR-1、NFR-2、AC-1）
private struct LatencySection: View {
    let model: TouchTunerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("指示点 \(summary(model.pointerLatency, p: 0.95, label: "p95"))")
            Text("拦截回调 \(model.tapTiming.map { summary($0, p: 0.99, label: "p99", micro: true) } ?? "—")")
            if let s = model.lastPanelShown {
                Text(String(format: "确认→激活 %.0f ms · 激活→面板 %.0f ms", s.armToActive * 1000, s.activeToShown * 1000))
            } else {
                Text("确认→激活 — · 激活→面板 —")
            }
        }
    }

    private func summary(_ h: LatencyHistogram, p: Double, label: String, micro: Bool = false) -> String {
        guard let v = h.percentile(p) else { return "—" }
        let (scale, unit) = micro ? (1e6, "µs") : (1e3, "ms")
        return String(format: "%@ %.1f %@ · max %.1f %@ · %llu 次", label, v * scale, unit, h.max * scale, unit, h.count)
    }
}
