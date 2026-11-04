// 실행 인자(docs/resourcebar.md 6절). 모르는 인자는 stderr에 알리고 무시한다.
import Foundation

struct AppOptions {
    /// nil이면 측정 없이 계속 실행
    var duration: Double?
    var warmup: Double = 3
    /// 시작하자마자 열 창
    var openKind: WidgetKind?
    var spikeTest = false
    var logDir: URL?
    var noPin = false
    /// --login-item on|off: 로그인 항목만 바꾸고 바로 끝낸다
    var loginItem: Bool?
    /// --login-item 값이 없거나 on·off가 아니었다. 설치 스크립트가 오타 하나로 메뉴 막대 앱을 띄우고 멈추지 않게
    /// 앱을 띄우지 않고 끝낸다
    var loginItemInvalid = false

    static func parse(_ args: [String]) -> AppOptions {
        var o = AppOptions()
        var i = 0
        /// 다음 인자를 값으로 가져간다. 다음 것이 "--"로 시작하면 값이 빠진 것으로 보고 가져가지 않는다
        /// (`--open --no-pin`에서 --no-pin이 값으로 먹히지 않게)
        func value() -> String? {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--duration":
                if let v = value(), let d = Double(v), d > 0 { o.duration = d }
            case "--warmup":
                if let v = value(), let d = Double(v), d >= 0 { o.warmup = d }
            case "--open":
                if let v = value() {
                    if let k = WidgetKind(optionName: v) { o.openKind = k } else { warn("--open 값을 모름: \(v)") }
                }
            case "--spike-test":
                o.spikeTest = true
            case "--log-dir":
                if let v = value() {
                    o.logDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
                }
            case "--no-pin":
                o.noPin = true
            case "--login-item":
                let v = value()
                switch v?.lowercased() {
                case "on"?: o.loginItem = true
                case "off"?: o.loginItem = false
                default:
                    warn("--login-item 값은 on 또는 off: \(v ?? "(없음)")")
                    o.loginItemInvalid = true
                }
            default:
                // Finder·Xcode가 붙이는 인자(-psn_…, -NS…)는 조용히 넘긴다
                if a.hasPrefix("--") { warn("모르는 인자: \(a)") }
            }
            i += 1
        }
        return o
    }

    static func warn(_ s: String) {
        FileHandle.standardError.write(Data("ResourceBar: \(s)\n".utf8))
    }
}

extension WidgetKind {
    /// 실행 인자·JSON에 쓰는 이름
    var optionName: String {
        switch self {
        case .ssd: return "ssd"
        case .gpu: return "gpu"
        case .cpu: return "cpu"
        case .ram: return "ram"
        case .net: return "net"
        }
    }

    init?(optionName: String) {
        guard let k = WidgetKind.allCases.first(where: { $0.optionName == optionName.lowercased() }) else { return nil }
        self = k
    }
}
