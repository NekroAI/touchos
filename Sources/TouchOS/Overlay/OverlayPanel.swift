import AppKit
import SwiftUI
import TouchOSCore

/// 浮层面板（SRS 8.1、8.2）：永不获得焦点、鼠标穿透、出现在所有桌面和全屏应用之上；只渲染视图模型，不处理输入。
/// 启动时创建并保持隐藏，激活时只切换可见性（FR-8.4）。
final class OverlayPanel: NSPanel {
    /// FR-8.8：显示时透明度 0 → 1 的时长；隐藏立即生效
    static let fadeInDuration: TimeInterval = 0.12

    init(model: OverlayModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 出现在所有桌面并能叠加在全屏应用上；不进入窗口循环与 Mission Control（FR-8.2、8.3）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        contentView = NSHostingView(rootView: PanelView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显示在鼠标（冻结光标）所在屏幕，居中于其可见区域（FR-8.5）
    func show(size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height),
                     display: false)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        alphaValue = 0
        orderOut(nil)
    }
}

@MainActor
@Observable
final class OverlayModel {
    var state: PanelState?
    var flashing: SlotID?
    var slotGap = 0.0
}

/// 面板渲染（SRS 8.3 的最简版本；完整视觉、轨迹、指示点插值在 K10）
private struct PanelView: View {
    let model: OverlayModel

    var body: some View {
        if let state = model.state {
            let tester = HitTester(layout: state.layout, panelSize: state.size, slotGap: model.slotGap, hysteresis: 0)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
                ForEach(state.layout.slots, id: \.id) { slot in
                    let r = tester.visualRect(of: slot)
                    SlotCard(slot: slot, hovered: state.hovered == slot.id, flashing: model.flashing == slot.id)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                Text(state.layout.name).font(.caption2).foregroundStyle(.secondary).padding(8)
                if let p = state.pointer {
                    Circle().fill(Color.accentColor)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(x: p.x, y: p.y)
                }
            }
            .frame(width: state.size.width, height: state.size.height)
        }
    }
}

private struct SlotCard: View {
    let slot: Slot
    let hovered: Bool
    let flashing: Bool

    var body: some View {
        let isNull = slot.action == .none
        VStack(spacing: 6) {
            Image(systemName: slot.symbol).font(.system(size: 32))
            Text(slot.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.center)
        }
        .foregroundStyle(isNull ? .secondary : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            if isNull {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.secondary)
            } else {
                shape.fill(Color.primary.opacity(hovered || flashing ? 0.16 : 0.06))
            }
            if hovered { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .scaleEffect(hovered ? 1.04 : 1)
        .animation(.easeOut(duration: 0.08), value: hovered)
    }
}
