// 메뉴 막대 칸 배치와 렌더러 약속. 앱(AppController)과 렌더러(StandardRenderer)가 함께 쓴다.
import AppKit

/// 메뉴 막대 칸 안의 위젯. 왼쪽부터 이 순서로 그린다(Stats와 같은 순서. GPU 게이지·온도는 뺐다).
enum WidgetKind: Int, CaseIterable {
    case ssd, gpu, cpu, ram, net
}

/// 렌더러가 tick마다 받는 값. 비율은 0...1, 이력은 오래된 값부터 최대 BarLayout.historyCount개.
struct BarFrame {
    /// SSD 실제 사용률 = 1 - f_bavail/f_blocks (/System/Volumes/Data). 비울 수 있는 공간을 여유로 치지 않는다.
    var ssdUsed: Double
    var gpuHistory: [Double]
    var cpuHistory: [Double]
    var ramHistory: [Double]
    /// bytes/s
    var netUpBps: Double
    /// bytes/s
    var netDownBps: Double
}

/// 칸 배치(포인트, 버튼 좌표계, 원점 왼쪽 아래). 렌더러는 이 배치대로 그리고,
/// 앱은 클릭 위치를 이 배치로 위젯에 대응시킨다. 칸 길이는 totalWidth로 고정한다.
enum BarLayout {
    static let historyCount = 60
    static let order: [WidgetKind] = [.ssd, .gpu, .cpu, .ram, .net]
    static let gap: CGFloat = 4
    static let sidePadding: CGFloat = 2

    static func width(_ k: WidgetKind) -> CGFloat {
        switch k {
        case .ssd: return 20
        case .gpu, .cpu, .ram: return 44
        case .net: return 56
        }
    }

    static var totalWidth: CGFloat {
        sidePadding * 2 + order.map(width).reduce(0, +) + gap * CGFloat(order.count - 1)
    }

    /// 위젯 영역(버튼 좌표). 높이는 칸 전체 높이.
    static func frame(of k: WidgetKind, height: CGFloat) -> NSRect {
        var x = sidePadding
        for o in order {
            if o == k { return NSRect(x: x, y: 0, width: width(o), height: height) }
            x += width(o) + gap
        }
        return .zero
    }

    /// 클릭 x(버튼 좌표) → 위젯. 위젯 사이 틈이나 바깥은 가장 가까운 위젯으로 본다.
    static func widget(atX x: CGFloat) -> WidgetKind {
        var best = WidgetKind.ssd
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for k in order {
            let f = frame(of: k, height: 1)
            let d = x < f.minX ? f.minX - x : (x > f.maxX ? x - f.maxX : 0)
            if d < bestDistance { bestDistance = d; best = k }
        }
        return best
    }
}

/// 렌더러 약속. NSObject 하위 final 클래스로 만든다.
protocol BarRenderer: NSObject {
    /// statusItem.button 안에 자기 뷰를 붙인다. 칸 길이·autosaveName·클릭 처리·메뉴는 앱이 맡는다.
    /// 붙이는 뷰는 hitTest(_:)에서 nil을 돌려 클릭이 버튼으로 가게 한다.
    init(statusItem: NSStatusItem)
    /// 매 tick(1초) 메인 스레드에서 호출된다. 보이는 내용이 실제로 바뀌어야 한다.
    func update(_ frame: BarFrame)
    /// 실제로 다시 그린 위젯 수의 누계(위젯 하나 = 1, 한 번에 다섯 개를 그리면 5).
    var renderCount: Int { get }
    /// 다른 화면용 복제본 갱신을 일으킨 횟수 누계. 렌더러가 직접 제어하지 않으면 -1.
    var replicaRefreshCount: Int { get }
    /// 붙인 뷰를 떼고 정리한다.
    func teardown()
}
