// 기록(docs/resourcebar.md 4절): 한도를 넘을 때만 그 순간의 상위 프로세스를 JSON 한 줄로 남긴다.
// 판정은 이미 매초 읽는 값(CPU·GPU·메모리 압박)으로만 한다 → 한도 아래에서는 비교 몇 번 말고 추가 비용 없음.
// 넘으면: 1초 간격 표본 두 개(CPU %·디스크 쓰기) + 둘째 표본의 메모리로 줄을 만든다(프로세스 표본 큐에서).
// 두 표본 모두 직접 못 읽는 다른 계정 프로세스를 ps로 받아 합친다(system: true, 메모리는 rss_mb).
// 30일 지난 파일은 시작할 때와 하루 한 번 지운다.
//
// 이유별 줄 남기는 규칙(메모리 압박이 평소에도 '경고'인 맥에서 1분마다 줄이 쌓이지 않게):
//  - CPU·GPU(80% 10초 지속), 압박 '위험'(4): 새로 시작되면 바로 한 줄, 이어지면 60초마다.
//    위험 줄은 60초에 한 번을 넘지 않는다(처음 위험은 바로).
//  - CPU·GPU 에피소드가 이어지는 동안은 한도 위인 tick이면 "있음"(지속 조건은 새로 열 때만).
//  - 압박 '경고'(2·3)만: 새로 시작되면 한 줄, 이어지면 10분마다. 경고 줄은 10분에 한 번을 넘지 않는다
//    (경고가 꺼졌다 켜졌다 해도 직전 경고 줄에서 10분이 안 됐으면 건너뛴다 — 에피소드 사이 쉬는 시간).
//  - 줄 하나에는 그 순간 한도를 넘은 이유를 모두 적는다. 그 줄에 든 이유는 모두 "방금 남김"으로 친다.
// 출렁임 처리(한도 근처를 오가는 값 때문에 start 줄과 프로세스 전체 표본이 몇 초마다 생기지 않게):
//  - "N초 지속": 한 tick만 한도 아래로 내려간 것은 봐준다. 연속 2 tick 아래여야 처음부터 다시 센다.
//  - "끝남": 이유가 quietSeconds(평소 10초) 동안 연속으로 없어야 그 이유의 에피소드가 끝난다.
//    그 전에 다시 넘으면 같은 에피소드다(반복 간격대로 continue만).
import Foundation

final class SpikeLogger {
    struct Rules {
        var cpu: Double
        var cpuSeconds: Double
        var gpu: Double
        var gpuSeconds: Double
        /// kern.memorystatus_vm_pressure_level 이 값 이상(2 = 경고)
        var pressureLevel: Int
        /// 이 값 이상이면 '위험'(4)
        var criticalLevel: Int
        /// CPU·GPU·위험이 이어질 때 반복 간격
        var repeatSeconds: Double
        /// 경고만 이어질 때 반복 간격이자, 경고 줄 사이 최소 간격
        var pressureRepeatSeconds: Double
        /// 이유가 이만큼 연속으로 없어야 그 이유의 에피소드가 끝난다
        var quietSeconds: Double
    }

    static let normalRules = Rules(cpu: 0.80, cpuSeconds: 10, gpu: 0.80, gpuSeconds: 10, pressureLevel: 2,
                                   criticalLevel: 4, repeatSeconds: 60, pressureRepeatSeconds: 600, quietSeconds: 10)
    /// --spike-test: 한도만 아주 낮춘다(CPU·GPU 1%를 3초, 끝남 3초). 반복 간격은 그대로(60초, 경고 10분).
    static let testRules = Rules(cpu: 0.01, cpuSeconds: 3, gpu: 0.01, gpuSeconds: 3, pressureLevel: 2,
                                 criticalLevel: 4, repeatSeconds: 60, pressureRepeatSeconds: 600, quietSeconds: 3)

    /// 줄을 남기는 이유. critical은 pressure를 포함한다(위험이면 경고 조건도 참)
    private enum Trigger: CaseIterable {
        case cpu, gpu, pressure, critical
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ResourceBar", isDirectory: true)
    }

    let directory: URL
    let rules: Rules
    private let sampler: ProcessSampler

    /// 지금까지 쓴 줄 수(메인 스레드)
    private(set) var linesWritten = 0
    private var cpuSince: Double?
    private var gpuSince: Double?
    /// 연속으로 한도 아래였던 tick 수
    private var cpuDips = 0
    private var gpuDips = 0
    /// 이유별로 마지막으로 줄에 든 시각
    private var lastLine: [Trigger: Double] = [:]
    /// 지금 에피소드에서 이미 줄에 든 이유(에피소드가 끝나면 빠진다)
    private var logged: Set<Trigger> = []
    /// 줄에 든 이유가 사라진 시각(다시 생기면 지운다)
    private var absentSince: [Trigger: Double] = [:]
    private var capturing = false
    private var dayObserver: NSObjectProtocol?

    init(directory: URL, rules: Rules, sampler: ProcessSampler) {
        self.directory = directory
        self.rules = rules
        self.sampler = sampler
    }

    deinit {
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    }

    /// 시작할 때 오래된 파일을 지우고, 날짜가 바뀔 때마다(하루 한 번) 다시 지운다.
    /// 24시간 반복 타이머는 잠든 시간을 세지 않아 밤마다 잠드는 노트북에서는 며칠에 한 번꼴로 돈다.
    /// NSCalendarDayChanged는 잠든 사이 날짜가 바뀌었으면 깨어날 때 한 번 온다.
    func start() {
        removeOldFiles()
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) {
            [weak self] _ in
            self?.removeOldFiles()
        }
    }

    // MARK: 판정(매 tick, 메인 스레드)

    func evaluate(_ s: SystemSnapshot, now: Double) {
        let cpuOver = s.cpu >= rules.cpu
        let gpuOver = s.gpu >= rules.gpu
        Self.track(&cpuSince, &cpuDips, over: cpuOver, now: now)
        Self.track(&gpuSince, &gpuDips, over: gpuOver, now: now)
        var present: Set<Trigger> = []
        // tick이 조금 늦거나 이르게 와도 "N초 지속"을 놓치지 않게 0.25초 여유. 이유는 지금 tick도 한도 위일 때만 든다.
        if cpuOver, let t = cpuSince, now - t >= rules.cpuSeconds - 0.25 { present.insert(.cpu) }
        if gpuOver, let t = gpuSince, now - t >= rules.gpuSeconds - 0.25 { present.insert(.gpu) }
        // 이미 줄에 든(진행 중인) CPU·GPU 에피소드는 지금 tick이 한도 위면 있음으로 친다. "10초 지속"은 새 에피소드를
        // 열 때만 요구하고, 끝남은 "10초 연속 한도 아래"가 된다. (이게 없으면 2초 이상 잠깐 내려갈 때마다
        // 지속 계수가 지워져 끝남이 먼저 오고, 다시 넘을 때마다 새 start 줄과 표본·ps 2번이 생겼다)
        if cpuOver, logged.contains(.cpu) { present.insert(.cpu) }
        if gpuOver, logged.contains(.gpu) { present.insert(.gpu) }
        if s.pressureLevel >= rules.pressureLevel { present.insert(.pressure) }
        if s.pressureLevel >= rules.criticalLevel { present.insert(.critical) }

        // 에피소드 끝: 줄에 든 이유가 quietSeconds 동안 연속으로 없으면 그 이유는 다음에 "새로 시작"이 된다
        for t in Trigger.allCases {
            if present.contains(t) {
                absentSince[t] = nil
            } else if logged.contains(t) {
                let a = absentSince[t] ?? now
                absentSince[t] = a
                if now - a >= rules.quietSeconds - 0.25 {
                    logged.remove(t)
                    absentSince[t] = nil
                }
            }
        }
        guard !present.isEmpty else { return }
        // 앞 줄을 아직 쓰는 중이면(부하로 표본 큐가 밀렸을 때) 상태를 바꾸지 않고 다음 tick에 다시 판정한다.
        // 먼저 바꿔 두면 새 에피소드의 start 줄이 통째로 빠진다.
        if capturing { return }

        // 줄을 남길 차례인 이유가 하나라도 있는가
        let due = present.contains { t in
            let since = lastLine[t].map { now - $0 } ?? .infinity
            switch t {
            case .cpu, .gpu:
                // 새로 시작이면 바로, 이어지면 60초마다
                return !logged.contains(t) || since >= rules.repeatSeconds - 0.25
            case .critical:
                // 위험: 처음이면 바로. 그다음은 새로 시작이어도 직전 위험 줄에서 60초가 지나야 한다
                // (위험은 지속 조건이 없어 4와 2를 오가면 12초마다 start가 나던 것을 막음)
                return since >= rules.repeatSeconds - 0.25
            case .pressure:
                // 경고: 줄 사이 최소 10분(새로 시작이어도 직전 경고 줄에서 10분이 안 됐으면 건너뜀)
                return since >= rules.pressureRepeatSeconds - 0.25
            }
        }
        guard due else { return }
        // 이 줄에 지금 에피소드에서 처음 드는 이유가 있으면 start
        let startsEpisode = present.contains { !logged.contains($0) }
        for t in present {
            lastLine[t] = now
            logged.insert(t)
        }
        var reasons: [String] = []
        if present.contains(.cpu) { reasons.append("cpu") }
        if present.contains(.gpu) { reasons.append("gpu") }
        if present.contains(.pressure) { reasons.append("memory_pressure") }
        capture(reasons, s, kind: startsEpisode ? "start" : "continue")
    }

    /// 한도 위면 지속 시작 시각을 잡는다. 한 tick 내려간 것은 봐주고, 연속 2 tick 아래면 지운다.
    private static func track(_ since: inout Double?, _ dips: inout Int, over: Bool, now: Double) {
        if over {
            dips = 0
            if since == nil { since = now }
        } else {
            dips += 1
            if dips >= 2 { since = nil }
        }
    }

    // MARK: 기록 한 줄(프로세스 표본 큐에서)

    private func capture(_ reasons: [String], _ s: SystemSnapshot, kind: String) {
        guard !capturing else { return }
        capturing = true
        let when = Date()
        let head: [(String, OrderedJSON)] = [
            ("time", .string(Self.isoFormatter.string(from: when))),
            ("reason", .array(reasons.map { .string($0) })),
            ("kind", .string(kind)),
            ("cpu_pct", .double(Self.round1(s.cpu * 100))),
            ("gpu_pct", .double(Self.round1(s.gpu * 100))),
            ("ram_pct", .double(Self.round1(s.ram * 100))),
            ("memory_pressure", .string(MemoryPressure.key(s.pressureLevel))),
            ("memory_pressure_level", .int(s.pressureLevel)),
        ]
        let sampler = self.sampler
        let dir = directory
        sampler.queue.async {
            // 두 표본 모두 다른 계정 프로세스를 ps로 함께 받는다(CPU %는 두 ps 결과의 차이)
            let a = sampler.sample(includeSystem: true)
            sampler.queue.asyncAfter(deadline: .now() + 1.0) {
                let b = sampler.sample(includeSystem: true)
                let lists = sampler.lists(from: a, to: b, cpuTop: 10, memoryTop: 10, diskTop: 0, writeTop: 5)
                func entry(_ p: ProcStat, _ key: String, _ value: Double) -> OrderedJSON {
                    var f: [(String, OrderedJSON)] = [("pid", .int(Int(p.pid))), ("name", .string(p.name)), (key, .double(value))]
                    if p.isSystem { f.append(("system", .bool(true))) }
                    return .object(f)
                }
                var fields = head
                // 머리의 cpu_pct(전체 기준, 최대 100)와 단위가 달라(코어 하나 = 100, 예: 637.6) 키를 나눈다
                fields.append(("top_cpu", .array(lists.cpu.map { entry($0, "cpu_core_pct", Self.round1($0.cpuPct ?? 0)) })))
                // 시스템(ps) 줄의 메모리는 RSS라 footprint와 키를 나눈다
                fields.append(("top_memory", .array(lists.memory.map {
                    entry($0, $0.isSystem ? "rss_mb" : "footprint_mb", Self.round1(Double($0.footprint) / 1_048_576))
                })))
                fields.append(("top_disk_write", .array(lists.diskWrite.map { entry($0, "write_bps", ($0.writeBps ?? 0).rounded()) })))
                fields.append(("processes_listed", .int(lists.listed)))
                fields.append(("processes_via_ps", .int(lists.viaPS)))
                fields.append(("processes_unreadable", .int(lists.unreadable)))
                let ok = Self.append(OrderedJSON.object(fields).text, to: dir, date: when)
                DispatchQueue.main.async {
                    self.capturing = false
                    if ok { self.linesWritten += 1 }
                }
            }
        }
    }

    private static func append(_ line: String, to dir: URL, date: Date) -> Bool {
        let data = Data((line + "\n").utf8)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppOptions.warn("기록 폴더를 만들지 못함: \(error.localizedDescription)")
            return false
        }
        let path = dir.appendingPathComponent("spikes-\(dayFormatter.string(from: date)).jsonl").path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            AppOptions.warn("기록 파일을 열지 못함: \(path)")
            return false
        }
        defer { close(fd) }
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return n == data.count
    }

    // MARK: 30일 보관

    func removeOldFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date())) else { return }
        for n in names where n.hasPrefix("spikes-") && n.hasSuffix(".jsonl") {
            let day = String(n.dropFirst("spikes-".count).dropLast(".jsonl".count))
            guard let d = Self.dayFormatter.date(from: day), d < cutoff else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(n))
        }
    }

    // MARK: 형식

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func round1(_ v: Double) -> Double { v.isFinite ? (v * 10).rounded() / 10 : 0 }
}
