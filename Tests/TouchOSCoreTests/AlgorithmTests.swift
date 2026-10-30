import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

@Suite struct AlgorithmTests {
    @Test func triggerZonesForEveryDirection() {
        // D38：四个角 0.1 × 0.2，四条边的中段夹在两角之间
        #expect(triggerZone(.bottomLeft, width: 0.1, height: 0.2) == CGRect(x: 0, y: 0, width: 0.1, height: 0.2))
        #expect(triggerZone(.bottomRight, width: 0.1, height: 0.2) == CGRect(x: 0.9, y: 0, width: 0.1, height: 0.2))
        #expect(triggerZone(.topLeft, width: 0.1, height: 0.2) == CGRect(x: 0, y: 0.8, width: 0.1, height: 0.2))
        #expect(triggerZone(.topRight, width: 0.1, height: 0.2) == CGRect(x: 0.9, y: 0.8, width: 0.1, height: 0.2))
        #expect(triggerZone(.top, width: 0.1, height: 0.2) == CGRect(x: 0.1, y: 0.8, width: 1 - 2 * 0.1, height: 0.2))
        #expect(triggerZone(.bottom, width: 0.1, height: 0.2) == CGRect(x: 0.1, y: 0, width: 1 - 2 * 0.1, height: 0.2))
        #expect(triggerZone(.left, width: 0.1, height: 0.2) == CGRect(x: 0, y: 0.2, width: 0.1, height: 1 - 2 * 0.2))
        #expect(triggerZone(.right, width: 0.1, height: 0.2) == CGRect(x: 0.9, y: 0.2, width: 0.1, height: 1 - 2 * 0.2))
    }

    @Test func mapperNormalizesClampsAndFlipsY() {
        let m = Mapper(margin: 0.05, scale: 0.9)
        let origin = m.normalizedPanelPoint(CGPoint(x: 0.05, y: 0.05))
        #expect(abs(origin.x) < 1e-9 && abs(origin.y - 1) < 1e-9)
        let corner = m.normalizedPanelPoint(CGPoint(x: 0.95, y: 0.95))
        #expect(abs(corner.x - 1) < 1e-9 && abs(corner.y) < 1e-9)
        #expect(m.normalizedPanelPoint(CGPoint(x: -1, y: 2)) == CGPoint(x: 0, y: 0))
        let p = m.panelPoint(CGPoint(x: 0.5, y: 0.5), panelSize: CGSize(width: 600, height: 400))
        #expect(abs(p.x - 300) < 1e-9 && abs(p.y - 200) < 1e-9)
        #expect(m.acceptsPointerStart(CGPoint(x: 0.5, y: 0.5)))
        #expect(!m.acceptsPointerStart(CGPoint(x: 0.02, y: 0.5)))
        #expect(!m.acceptsPointerStart(CGPoint(x: 0.5, y: 0.97)))
    }

    @Test func smallerMappingRectIsCenteredAndClampsBeyond() {
        let m = Mapper(margin: 0.05, scale: 0.6)
        #expect(m.mappingRect == CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let mid = m.normalizedPanelPoint(CGPoint(x: 0.35, y: 0.65))
        #expect(abs(mid.x - 0.25) < 1e-9 && abs(mid.y - 0.25) < 1e-9)
        // 映射区以外、边缘以内：仍可落指，坐标钳制到面板边缘
        #expect(m.acceptsPointerStart(CGPoint(x: 0.9, y: 0.9)))
        #expect(m.normalizedPanelPoint(CGPoint(x: 0.9, y: 0.9)) == CGPoint(x: 1, y: 0))
    }

    @Test func panelKeepsDeviceAspectInsideScaledScreen() {
        #expect(panelSize(screen: CGSize(width: 1000, height: 1000), deviceMM: CGSize(width: 150, height: 100), scale: 0.6)
                == CGSize(width: 600, height: 400))
        // 宽屏：受高度限制
        #expect(panelSize(screen: CGSize(width: 2000, height: 500), deviceMM: CGSize(width: 150, height: 100), scale: 1)
                == CGSize(width: 750, height: 500))
    }

    @Test func hitTesterRespectsGapsAndZOrder() {
        let t = HitTester(layout: .test, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0.02)
        #expect(t.hit(CGPoint(x: 500, y: 60)) == "close")
        #expect(t.hit(CGPoint(x: 300, y: 200)) == nil)        // 空单元格
        #expect(t.hit(CGPoint(x: 402, y: 60)) == nil)         // 槽位之间内缩形成的空隙
        #expect(t.hit(CGPoint(x: 600, y: 0)) == "close")      // 面板外边不留空隙
        let visual = t.visualRect(of: Layout.test.slots[1])!
        #expect(abs(visual.minX - 406) < 1e-9 && abs(visual.minY - 6) < 1e-9 && abs(visual.maxX - 594) < 1e-9)
        let overlap = Layout(id: "o", name: "o", rows: 1, cols: 1, slots: [
            Slot(id: "first", cell: GridCell(row: 0, col: 0), title: "", symbol: "", action: .none),
            Slot(id: "last", cell: GridCell(row: 0, col: 0), title: "", symbol: "", action: .none),
        ])
        #expect(HitTester(layout: overlap, panelSize: CGSize(width: 10, height: 10), slotGap: 0, hysteresis: 0)
            .hit(CGPoint(x: 5, y: 5)) == "last")
    }

    @Test func hysteresisKeepsCurrentSlotNearItsEdge() {
        let t = HitTester(layout: .test, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0.02)
        // "关闭"槽位可命中区域为 x ≥ 406；滞回 12 pt 封顶为空隙的一半 3 pt（D31），外扩后为 x ≥ 403
        #expect(t.hit(CGPoint(x: 404, y: 60), current: "close") == "close")
        #expect(t.hit(CGPoint(x: 401, y: 60), current: "close") == nil)
        #expect(t.hit(CGPoint(x: 404, y: 60), current: nil) == nil)
        // 没有空隙时滞回不封顶
        let tight = HitTester(layout: .test, panelSize: CGSize(width: 600, height: 400), slotGap: 0, hysteresis: 0.02)
        #expect(tight.hit(CGPoint(x: 392, y: 60), current: "close") == "close")
        #expect(t.hit(CGPoint(x: 500, y: 200), current: "close") == "vol")
    }

    @Test func liftStabilizerLooksBack() {
        var track = PointerTrack(id: 1, t: 0, p: CGPoint(x: 0.1, y: 0.1))
        track.append(t: 0.1, p: CGPoint(x: 0.2, y: 0.2))
        track.append(t: 0.15, p: CGPoint(x: 0.3, y: 0.3))
        #expect(track.commitPoint(liftAt: 0.17, lookback: 0.06) == CGPoint(x: 0.2, y: 0.2))
        #expect(track.commitPoint(liftAt: 0.05, lookback: 0.06) == CGPoint(x: 0.1, y: 0.1))  // 历史不足取最早
        #expect(track.latest == CGPoint(x: 0.3, y: 0.3))
        track.append(t: 0.5, p: CGPoint(x: 0.4, y: 0.4))
        #expect(track.samples.count == 1)  // 只保留最近 200 ms
    }
}
