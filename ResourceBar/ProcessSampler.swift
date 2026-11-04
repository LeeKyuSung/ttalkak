// 프로세스 표본. 목록을 보여 주는 창이 열려 있을 때(2초마다)와 기록이 남을 때만 돈다. 평소에는 0.
// proc_listallpids → proc_pid_rusage(RUSAGE_INFO_V2: CPU 시간·footprint·디스크 읽기/쓰기 누계).
// CPU %와 초당 바이트는 두 표본의 차이로 낸다. 이름은 proc_name(→ proc_pidpath 이름 → 짧은 BSD 정보),
// 소유자는 proc_pidinfo(PROC_PIDT_SHORTBSDINFO)로 상위 몇 개만 묻는다.
//
// 권한(macOS 26.6.2 실측, 일반 계정): proc_pid_rusage·PROC_PIDTBSDINFO·proc_name은 같은 계정 프로세스만 된다
// (633개 중 457개, 나머지 176개는 EPERM). PROC_PIDT_SHORTBSDINFO·proc_pidpath·sysctl KERN_PROC_PID(시작 시각)는 전부 된다.
// root·_windowserver 등 다른 계정 프로세스(WindowServer …)의 CPU·메모리는 공개 API로 못 읽는다.
// sysctl KERN_PROC의 p_pctcpu·p_rtime은 0으로만 온다. top은 한 번에 CPU 약 1초를 써서 못 쓴다.
// 그래서 includeSystem일 때만 직접 못 읽은 PID를 /bin/ps(setuid root)에 넘겨 CPU 시간 누계와 RSS를 받는다
// (목록이 있는 CPU·메모리 창이 열려 있을 때 2초마다, 그리고 기록할 때만). 약 200개에 5에서 12ms.
// 한계: kernel_task는 ps에도 없다. 메모리는 RSS라 footprint와 기준이 다르다(압축·그래픽 메모리가 빠져
// WindowServer는 RSS 107 MB, 활성 상태 보기 549 MB로 실측). 디스크 읽기·쓰기는 ps가 주지 않는다.
import Foundation
import Darwin

struct ProcCounters {
    var startAbs: UInt64
    /// user + system, mach 시간 단위
    var cpuAbs: UInt64
    var footprint: UInt64
    var diskRead: UInt64
    var diskWrite: UInt64
}

/// 직접 못 읽는(다른 계정) 프로세스를 ps로 받은 값
struct SystemCounters {
    /// sysctl p_starttime(마이크로초). PID가 다른 프로세스에 재사용됐는지 가른다
    var startKey: UInt64
    /// ps time: 사용자 + 시스템 CPU 시간 누계(초, 1/100초 단위)
    var cpuSeconds: Double
    /// ps rss(바이트)
    var rss: UInt64
}

struct ProcSample {
    var uptimeNs: UInt64
    var counters: [pid_t: ProcCounters]
    /// proc_listallpids가 돌려준 수
    var listed: Int
    /// 권한이 없어 직접 못 읽은 수(EPERM)
    var denied: Int
    /// 직접 못 읽어 ps로 받은 것(includeSystem일 때만 채운다)
    var system: [pid_t: SystemCounters] = [:]
    /// ps를 실행한 시각(실행 전후의 가운데). ps를 안 돌렸거나 실패했으면 0
    var systemUptimeNs: UInt64 = 0
    /// ps를 돌리려 했는데 실패·시한 초과였다
    var systemFailed = false
}

struct ProcStat {
    let pid: pid_t
    /// 시작 시각(ri_proc_start_abstime). 종료 직전에 같은 프로세스인지(PID 재사용 아님) 다시 확인할 때 쓴다
    var startAbs: UInt64 = 0
    var name: String = ""
    var uid: uid_t?
    /// 코어 하나 = 100. 이전 표본이 없거나 새로 뜬 프로세스면 nil
    var cpuPct: Double?
    /// 메모리. 보통은 phys_footprint, isSystem이면 ps의 RSS
    var footprint: UInt64
    var readBps: Double?
    var writeBps: Double?
    /// ps로 받은 다른 계정 프로세스(메모리는 RSS, 디스크 값 없음, 종료 불가)
    var isSystem = false
    /// isSystem일 때 sysctl 시작 시각(이름 캐시 열쇠)
    var systemStartKey: UInt64 = 0

    var isMine: Bool { uid == getuid() }
    /// 종료 버튼을 켤 수 있는가: 내 계정 소유이고 kernel_task(0)·launchd(1)·이 앱 자신이 아님
    /// (kill(0, …)은 프로세스 그룹 전체로 간다. 앱을 root로 띄우면 0·1도 isMine이 된다). 시스템 줄은 늘 끈다
    var canKill: Bool { !isSystem && isMine && pid > 1 && pid != getpid() }
}

/// 표본 두 개로 만든 목록 결과
struct ProcLists {
    var cpu: [ProcStat] = []
    var memory: [ProcStat] = []
    var disk: [ProcStat] = []
    var diskWrite: [ProcStat] = []
    var listed = 0
    /// 직접 못 읽은 수
    var denied = 0
    /// 그중 ps로 받은 수(ps를 안 돌렸으면 0)
    var viaPS = 0
    /// ps를 돌렸는가(성공한 경우)
    var systemIncluded = false
    /// ps를 돌리려 했는데 실패·시한 초과였다
    var systemFailed = false
    /// 이전 표본이 있었는가(없으면 CPU·디스크는 아직 못 낸다)
    var hasRates = false
    /// ps로도 못 읽은 수(kernel_task, 그사이 끝난 프로세스 등). ps를 안 돌렸으면 denied 전부
    var unreadable: Int { max(0, denied - viaPS) }
}

final class ProcessSampler: @unchecked Sendable {
    /// 표본은 이 큐에서만 뜬다(이름 캐시도 이 큐 전용).
    let queue = DispatchQueue(label: "ResourceBar.proc", qos: .utility)
    private var pidBuffer = [pid_t](repeating: 0, count: 2048)
    private var infoCache: [pid_t: (start: UInt64, name: String, uid: uid_t?)] = [:]
    private let absToNs: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        absToNs = tb.denom > 0 ? Double(tb.numer) / Double(tb.denom) : 1
    }

    /// 지금 표본. queue에서 부른다. includeSystem이면 직접 못 읽은 PID를 ps로 한 번 더 읽는다.
    func sample(includeSystem: Bool = false) -> ProcSample {
        dispatchPrecondition(condition: .onQueue(queue))
        let expected = Int(proc_listallpids(nil, 0))
        if expected + 64 > pidBuffer.count {
            pidBuffer = [pid_t](repeating: 0, count: expected * 2 + 64)
        }
        let got = pidBuffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let n = max(0, min(Int(got), pidBuffer.count))
        var counters = [pid_t: ProcCounters](minimumCapacity: n)
        var denied = 0
        var deniedPIDs: [pid_t] = []
        for i in 0..<n {
            let pid = pidBuffer[i]
            var ri = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if rc != 0 {
                if errno == EPERM {
                    denied += 1
                    // kernel_task(0)는 ps에도 나오지 않으므로 넘기지 않는다
                    if pid > 0 { deniedPIDs.append(pid) }
                }
                continue
            }
            counters[pid] = ProcCounters(startAbs: ri.ri_proc_start_abstime,
                                         cpuAbs: ri.ri_user_time &+ ri.ri_system_time,
                                         footprint: ri.ri_phys_footprint,
                                         diskRead: ri.ri_diskio_bytesread,
                                         diskWrite: ri.ri_diskio_byteswritten)
        }
        var s = ProcSample(uptimeNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), counters: counters, listed: n, denied: denied)
        if includeSystem, !deniedPIDs.isEmpty {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let rows = readWithPS(deniedPIDs)
            let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let rows {
                s.systemUptimeNs = t0 + (t1 &- t0) / 2
                var system = [pid_t: SystemCounters](minimumCapacity: rows.count)
                for r in rows {
                    // 시작 시각을 못 읽으면(그사이 끝남) 버린다
                    guard let key = Self.startKey(r.pid) else { continue }
                    system[r.pid] = SystemCounters(startKey: key, cpuSeconds: r.cpuSeconds, rss: r.rss)
                }
                s.system = system
            } else {
                s.systemFailed = true
            }
        }
        return s
    }

    // MARK: ps(다른 계정 프로세스)

    /// ps 시한. 보통 5에서 12ms라 넉넉하다. 넘기면 그 표본은 시스템 프로세스 없이 간다
    static let psTimeout = 2.0
    /// 시한을 넘겨 SIGKILL을 보냈는데 아직 거두지 못한 자식(표본 큐 전용). 남아 있으면 새 ps를 띄우지 않는다
    private var unreaped: [pid_t] = []

    /// /bin/ps -o pid=,time=,rss= -p <PID,…>. 실패·시한 초과면 nil. ps는 없는 PID를 건너뛴다.
    /// rss가 0인 줄은 ps가 실제로는 못 읽은 것(좀비 등)으로 보고 뺀다(못 읽은 수에 들어간다).
    private func readWithPS(_ pids: [pid_t]) -> [(pid: pid_t, cpuSeconds: Double, rss: UInt64)]? {
        guard let text = Self.runCommand("/bin/ps", ["-o", "pid=,time=,rss=", "-p", pids.map { String($0) }.joined(separator: ",")],
                                         timeout: Self.psTimeout, unreaped: &unreaped) else {
            return nil
        }
        var out: [(pid: pid_t, cpuSeconds: Double, rss: UInt64)] = []
        out.reserveCapacity(pids.count)
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let pid = pid_t(f[0]), let t = Self.parseCPUTime(f[1]), let kb = UInt64(f[2]), kb > 0 else {
                continue
            }
            out.append((pid, t, kb &* 1024))
        }
        return out
    }

    /// ps의 time 칸: "4:52.68"(분:초), "115:29.47", 혹시 모를 "1:02:03.04"·"1-02:03:04" 형식도 받는다
    static func parseCPUTime(_ s: Substring) -> Double? {
        var rest = Substring(s.replacingOccurrences(of: ",", with: "."))
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        var secs = 0.0
        for part in rest.split(separator: ":", omittingEmptySubsequences: false) {
            guard let v = Double(part), v >= 0 else { return nil }
            secs = secs * 60 + v
        }
        return days * 86_400 + secs
    }

    /// 명령을 직접 띄우고(posix_spawn, 셸 없음) 표준 출력을 읽는다. 소수점이 "."이 되게 LC_ALL=C.
    /// timeout(초)을 넘기면 SIGKILL을 보내고 nil(시한이 없으면 ps가 멈출 때 표본 큐 전체가 서고 기록이 조용히
    /// 끊긴다). 그렇게 끝낸 자식을 곧바로 거두지 못하면 unreaped에 남기고, 남아 있는 동안에는 새로 띄우지 않는다(nil).
    /// 신호로 끝났으면 출력을 버린다(nil). 종료 코드는 보지 않는다(ps는 없는 PID가 섞여도 나머지를 찍는다).
    static func runCommand(_ path: String, _ args: [String], timeout: Double, unreaped: inout [pid_t]) -> String? {
        // 지난번에 거두지 못한 자식을 먼저 거둔다
        unreaped.removeAll { p in
            var st: Int32 = 0
            let r = waitpid(p, &st, WNOHANG)
            return r == p || (r < 0 && errno == ECHILD)
        }
        guard unreaped.isEmpty else { return nil }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argStrings: [String] = [path] + args
        let envStrings: [String] = ["LC_ALL=C"]
        let argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, nil, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            return nil
        }
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &+ UInt64(max(timeout, 0.01) * 1e9)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        var timedOut = false
        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now >= deadline {
                timedOut = true
                break
            }
            var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(min(Double(deadline - now) / 1e6 + 1, 60_000)))
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue }   // 시한 확인으로 돌아간다
            let n = buf.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break   // 출력이 닫힘(EOF) 또는 오류
            }
        }
        close(fds[0])
        // 거두기: 출력이 닫혔으면 곧 끝난다. 그래도 시한까지만 기다리고, 넘기면 SIGKILL
        var status: Int32 = 0
        var reaped = false
        if !timedOut {
            while true {
                let r = waitpid(child, &status, WNOHANG)
                if r == child { reaped = true; break }
                if r < 0 && errno != EINTR { reaped = true; break }   // 이미 거둔 것으로 본다(ECHILD)
                if clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline { timedOut = true; break }
                usleep(500)
            }
        }
        if timedOut {
            kill(child, SIGKILL)
            // 커널 안에서 막혔으면 SIGKILL로도 바로 안 끝날 수 있다. 0.1초만 기다리고 못 거두면 다음 번에 거둔다
            for _ in 0..<100 {
                let r = waitpid(child, &status, WNOHANG)
                if r == child || (r < 0 && errno != EINTR) { reaped = true; break }
                usleep(1000)
            }
            if !reaped { unreaped.append(child) }
            return nil
        }
        // 신호로 끝났으면(WIFSIGNALED) 출력이 잘렸을 수 있어 버린다
        let sig = status & 0x7f
        if sig != 0 && sig != 0x7f { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// sysctl KERN_PROC_PID의 시작 시각(마이크로초). 다른 계정 프로세스도 된다. 없으면 nil
    static func startKey(_ pid: pid_t) -> UInt64? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = kp.kp_proc.p_starttime
        guard t.tv_sec > 0 else { return nil }
        return UInt64(t.tv_sec) &* 1_000_000 &+ UInt64(max(t.tv_usec, 0))
    }

    /// 두 표본으로 상위 목록을 만든다(이름·소유자는 뽑힌 것만 묻는다). queue에서 부른다.
    func lists(from prev: ProcSample?, to cur: ProcSample, cpuTop: Int, memoryTop: Int, diskTop: Int, writeTop: Int) -> ProcLists {
        dispatchPrecondition(condition: .onQueue(queue))
        var out = ProcLists()
        out.listed = cur.listed
        out.denied = cur.denied
        out.viaPS = cur.system.count
        out.systemIncluded = cur.systemUptimeNs != 0
        out.systemFailed = cur.systemFailed
        let dtNs = prev.map { cur.uptimeNs > $0.uptimeNs ? Double(cur.uptimeNs - $0.uptimeNs) : 0 } ?? 0
        out.hasRates = dtNs > 0
        var all: [ProcStat] = []
        all.reserveCapacity(cur.counters.count + cur.system.count)
        for (pid, c) in cur.counters {
            var s = ProcStat(pid: pid, startAbs: c.startAbs, footprint: c.footprint)
            if dtNs > 0, let p = prev?.counters[pid], p.startAbs == c.startAbs {
                let dCPU = c.cpuAbs >= p.cpuAbs ? Double(c.cpuAbs - p.cpuAbs) * absToNs : 0
                s.cpuPct = dCPU / dtNs * 100
                let sec = dtNs / 1e9
                s.readBps = c.diskRead >= p.diskRead ? Double(c.diskRead - p.diskRead) / sec : 0
                s.writeBps = c.diskWrite >= p.diskWrite ? Double(c.diskWrite - p.diskWrite) / sec : 0
            }
            all.append(s)
        }
        // ps로 받은 다른 계정 프로세스: CPU %는 ps 실행 시각끼리의 차이로, 메모리는 RSS. 디스크 값은 없다(목록에서 빠짐)
        let sysDtNs = prev.map { p -> Double in
            p.systemUptimeNs != 0 && cur.systemUptimeNs > p.systemUptimeNs ? Double(cur.systemUptimeNs - p.systemUptimeNs) : 0
        } ?? 0
        for (pid, c) in cur.system {
            var s = ProcStat(pid: pid, footprint: c.rss)
            s.isSystem = true
            s.systemStartKey = c.startKey
            if sysDtNs > 0, let p = prev?.system[pid], p.startKey == c.startKey {
                s.cpuPct = max(0, c.cpuSeconds - p.cpuSeconds) * 1e9 / sysDtNs * 100
            }
            all.append(s)
        }
        func pick(_ n: Int, _ key: (ProcStat) -> Double?) -> [ProcStat] {
            guard n > 0 else { return [] }
            // 값이 0인 것은 목록에 넣지 않는다(디스크를 안 쓰는 프로세스 등)
            let ranked = all.compactMap { s -> (Double, ProcStat)? in
                guard let v = key(s), v > 0 else { return nil }
                return (v, s)
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.pid < $1.1.pid }
            return ranked.prefix(n).map { named($0.1, start: $0.1.isSystem ? $0.1.systemStartKey : $0.1.startAbs) }
        }
        if out.hasRates {
            out.cpu = pick(cpuTop) { $0.cpuPct }
            out.disk = pick(diskTop) { s in s.readBps.map { $0 + (s.writeBps ?? 0) } }
            out.diskWrite = pick(writeTop) { $0.writeBps }
        }
        out.memory = pick(memoryTop) { Double($0.footprint) }
        // 끝난 프로세스의 이름 캐시는 버린다
        if infoCache.count > cur.counters.count + cur.system.count + 256 {
            infoCache = infoCache.filter { cur.counters[$0.key] != nil || cur.system[$0.key] != nil }
        }
        return out
    }

    /// 종료 직전 확인: 그 PID가 지금도 목록에서 본 프로세스인가(같은 시작 시각, 같은 소유자).
    /// 목록은 최대 2초 전 표본이고 확인 창은 누를 때까지 열려 있다. 그 사이 프로세스가 끝나고 PID가 다른 내 프로세스에
    /// 재사용됐으면 false. 이미 끝났으면(ESRCH) 역시 false. 아무 스레드에서나 불러도 된다.
    static func isStillSame(_ p: ProcStat) -> Bool {
        guard p.startAbs != 0, let uid = p.uid else { return false }
        var ri = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &ri) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p.pid, RUSAGE_INFO_V2, $0) }
        }
        guard rc == 0, ri.ri_proc_start_abstime == p.startAbs else { return false }
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(p.pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else { return false }
        return short.pbsi_uid == uid
    }

    private func named(_ s: ProcStat, start: UInt64) -> ProcStat {
        var s = s
        if let c = infoCache[s.pid], c.start == start {
            s.name = c.name
            s.uid = c.uid
            return s
        }
        let info = Self.lookup(s.pid)
        infoCache[s.pid] = (start, info.name, info.uid)
        s.name = info.name
        s.uid = info.uid
        return s
    }

    private static func lookup(_ pid: pid_t) -> (name: String, uid: uid_t?) {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let ok = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size
        let uid: uid_t? = ok ? short.pbsi_uid : nil

        var name = ""
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { name = String(cString: buf) }
        // proc_name은 31자에서 잘린다("Google Chrome Helper (Aperitif Renderer)" → "…(Aperitif").
        // 비었거나 잘렸을 수 있으면 실행 파일 이름을 본다.
        if name.isEmpty || name.utf8.count >= 31 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let base = (String(cString: path) as NSString).lastPathComponent
                if name.isEmpty || base.hasPrefix(name) { name = base }
            }
        }
        if !name.isEmpty { return (name, uid) }
        if ok {
            // pbsi_comm은 16바이트 고정 배열이라 NUL이 없을 수 있다
            let s = withUnsafeBytes(of: short.pbsi_comm) { raw -> String in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !s.isEmpty { return (s, uid) }
        }
        return ("PID \(pid)", uid)
    }
}
