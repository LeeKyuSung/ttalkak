// 시스템 값 읽기.
// 매초(메뉴바·기록 판정): CPU·GPU(장치·렌더러·타일러·메모리)·RAM(내역 포함)·SSD·네트워크·메모리 압박.
// 창이 열렸을 때만: 스왑(readSwap).
// CPU는 코어별 배열 대신 합계 한 번(HOST_CPU_LOAD_INFO), 네트워크는 getifaddrs 대신
// sysctl NET_RT_IFLIST2(64비트 계수기, 버퍼 재사용), GPU는 IOAccelerator 항목을 한 번 찾아 붙잡아 둔다.
import Foundation
import Darwin
import IOKit

struct SystemSnapshot {
    /// 0...1 전체 코어 평균
    var cpu: Double = 0
    /// 0...1 IOAccelerator "Device Utilization %"
    var gpu: Double = 0
    var gpuRenderer: Double = 0
    var gpuTiler: Double = 0
    /// bytes, "In use system memory" (없으면 nil)
    var gpuMemoryInUse: UInt64?
    /// bytes, "Alloc system memory" (없으면 nil)
    var gpuMemoryAllocated: UInt64?
    /// 0...1 (앱 + 고정 + 압축) / 전체
    var ram: Double = 0
    var memoryTotal: UInt64 = 0
    /// 앱 메모리 = internal - purgeable
    var memoryApp: UInt64 = 0
    var memoryWired: UInt64 = 0
    /// 압축기가 차지한 페이지
    var memoryCompressed: UInt64 = 0
    /// 캐시된 파일 = external + purgeable 페이지(활성 상태 보기·Stats와 같은 기준. 앱 메모리에서 뺀 purgeable을 여기 센다)
    var memoryCached: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 정상, 2 경고, 4 위험 (못 읽으면 0)
    var pressureLevel: Int = 0
    /// 0...1 실제 사용률 = 1 - f_bavail/f_blocks
    var ssdUsed: Double = 0
    var ssdTotalBytes: UInt64 = 0
    /// 실제 여유(f_bavail). 비울 수 있는 공간은 넣지 않는다
    var ssdFreeBytes: UInt64 = 0
    var netUpBps: Double = 0
    var netDownBps: Double = 0
}

struct SwapUsage {
    var used: UInt64
    var total: UInt64
}

/// 최근 값 N개(오래된 값부터).
struct RollingSeries {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = capacity
        values.reserveCapacity(capacity)
    }

    mutating func push(_ v: Double) {
        if values.count >= capacity { values.removeFirst(values.count - capacity + 1) }
        values.append(v)
    }

    mutating func fill(_ v: Double) {
        values = [Double](repeating: v, count: capacity)
    }
}

enum MemoryPressure {
    static func label(_ level: Int) -> String {
        switch level {
        case 1: return "정상"
        case 2: return "경고"
        case 4: return "위험"
        default: return "알 수 없음"
        }
    }

    static func key(_ level: Int) -> String {
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }
}

final class SystemSampler {
    private let host: host_t = mach_host_self()
    private let pageSize: UInt64
    let memoryTotal: UInt64

    private var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var lastCPU = 0.0

    private var netMIB: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    private var netBuffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var prevNet: (up: UInt64, down: UInt64, ns: UInt64)?

    private var gpuEntry: io_registry_entry_t = 0
    private var gpuLookupAt: Double = -1_000

    private var pressureMIB = [Int32](repeating: 0, count: 8)
    private var pressureMIBCount = 0

    init() {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        memoryTotal = size
        var ps: vm_size_t = 0
        host_page_size(host, &ps)
        pageSize = UInt64(ps > 0 ? ps : 16_384)
        var n = pressureMIB.count
        if sysctlnametomib("kern.memorystatus_vm_pressure_level", &pressureMIB, &n) == 0 { pressureMIBCount = n }
        // 델타 계산용 기준값
        _ = readCPU()
        _ = readNet()
    }

    deinit {
        if gpuEntry != 0 { IOObjectRelease(gpuEntry) }
    }

    /// 매초 읽는 값 전부. 메인 스레드에서 부른다.
    func read() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu = readCPU()
        readMemory(into: &s)
        let net = readNet()
        s.netUpBps = net.up
        s.netDownBps = net.down
        readSSD(into: &s)
        readGPU(into: &s)
        s.pressureLevel = readPressure()
        return s
    }

    // MARK: CPU — 모든 코어의 틱 합계(한 번의 호출)

    private func readCPU() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return lastCPU }
        let t = info.cpu_ticks
        let cur = (user: t.0, sys: t.1, idle: t.2, nice: t.3)
        defer { prevTicks = cur }
        guard let p = prevTicks else { return 0 }
        // 32비트 계수기라 넘침을 감안해 &- 로 뺀다
        let busy = Double(cur.user &- p.user) + Double(cur.sys &- p.sys) + Double(cur.nice &- p.nice)
        let total = busy + Double(cur.idle &- p.idle)
        guard total > 0 else { return lastCPU }
        lastCPU = min(max(busy / total, 0), 1)
        return lastCPU
    }

    // MARK: RAM

    private func readMemory(into s: inout SystemSnapshot) {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        s.memoryTotal = memoryTotal
        guard kr == KERN_SUCCESS, memoryTotal > 0 else { return }
        let internalPages = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        s.memoryApp = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        s.memoryWired = UInt64(vm.wire_count) * pageSize
        s.memoryCompressed = UInt64(vm.compressor_page_count) * pageSize
        s.memoryCached = (UInt64(vm.external_page_count) + purgeable) * pageSize
        let used = Double(s.memoryApp + s.memoryWired + s.memoryCompressed)
        s.ram = min(max(used / Double(memoryTotal), 0), 1)
    }

    // MARK: 네트워크 — lo 를 뺀 모든 인터페이스 합

    private func readNet() -> (up: Double, down: Double) {
        guard let totals = netTotals() else { return (0, 0) }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { prevNet = (totals.up, totals.down, now) }
        guard let p = prevNet, now > p.ns else { return (0, 0) }
        let dt = Double(now - p.ns) / 1e9
        // 인터페이스가 사라지면 합이 줄 수 있다 → 0으로 본다
        let up = totals.up >= p.up ? Double(totals.up - p.up) : 0
        let down = totals.down >= p.down ? Double(totals.down - p.down) : 0
        return (up / dt, down / dt)
    }

    private func netTotals() -> (up: UInt64, down: UInt64)? {
        // 크기 질의(약 27µs)를 매번 하지 않고 재사용 버퍼에 바로 받는다. 모자랄 때(ENOMEM)만 크기를 묻고 늘린다.
        var size = netBuffer.count
        var rc = netBuffer.withUnsafeMutableBytes { sysctl(&netMIB, 6, $0.baseAddress, &size, nil, 0) }
        if rc != 0 && errno == ENOMEM {
            var needed = 0
            guard sysctl(&netMIB, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
            netBuffer = [UInt8](repeating: 0, count: needed + 4096)
            size = netBuffer.count
            rc = netBuffer.withUnsafeMutableBytes { sysctl(&netMIB, 6, $0.baseAddress, &size, nil, 0) }
        }
        guard rc == 0 else { return nil }
        var up: UInt64 = 0
        var down: UInt64 = 0
        let headerSize = MemoryLayout<if_msghdr2>.size
        netBuffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + 4 <= size {
                let p = base + off
                let msglen = Int(p.loadUnaligned(as: UInt16.self))
                if msglen <= 0 { break }
                let type = p.load(fromByteOffset: 3, as: UInt8.self)
                if Int32(type) == RTM_IFINFO2, off + headerSize <= size {
                    let m = p.loadUnaligned(as: if_msghdr2.self)
                    if m.ifm_flags & IFF_LOOPBACK == 0 {
                        up &+= m.ifm_data.ifi_obytes
                        down &+= m.ifm_data.ifi_ibytes
                    }
                }
                off += msglen
            }
        }
        return (up, down)
    }

    // MARK: SSD

    private func readSSD(into s: inout SystemSnapshot) {
        var st = statfs()
        guard statfs("/System/Volumes/Data", &st) == 0, st.f_blocks > 0 else { return }
        let bsize = UInt64(st.f_bsize)
        s.ssdTotalBytes = UInt64(st.f_blocks) * bsize
        s.ssdFreeBytes = UInt64(st.f_bavail) * bsize
        s.ssdUsed = 1 - Double(st.f_bavail) / Double(st.f_blocks)
    }

    // MARK: GPU — IOAccelerator PerformanceStatistics

    private func readGPU(into s: inout SystemSnapshot) {
        if gpuEntry == 0 {
            // 못 찾았으면 60초에 한 번만 다시 찾는다
            let now = ProcessInfo.processInfo.systemUptime
            guard now - gpuLookupAt >= 60 else { return }
            gpuLookupAt = now
            gpuEntry = Self.findAccelerator()
            if gpuEntry == 0 { return }
        }
        guard let stats = IORegistryEntryCreateCFProperty(gpuEntry, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary
        else {
            IOObjectRelease(gpuEntry)
            gpuEntry = 0
            return
        }
        func ratio(_ key: String) -> Double {
            guard let n = stats[key] as? NSNumber else { return 0 }
            return min(max(n.doubleValue / 100, 0), 1)
        }
        s.gpu = ratio("Device Utilization %")
        s.gpuRenderer = ratio("Renderer Utilization %")
        s.gpuTiler = ratio("Tiler Utilization %")
        s.gpuMemoryInUse = (stats["In use system memory"] as? NSNumber)?.uint64Value
        s.gpuMemoryAllocated = (stats["Alloc system memory"] as? NSNumber)?.uint64Value
    }

    /// PerformanceStatistics를 가진 첫 IOAccelerator 항목(붙잡아 둔다, 호출자가 해제).
    private static func findAccelerator() -> io_registry_entry_t {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(it) }
        while true {
            let e = IOIteratorNext(it)
            if e == 0 { return 0 }
            if IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() is NSDictionary {
                return e
            }
            IOObjectRelease(e)
        }
    }

    // MARK: 메모리 압박·스왑

    private func readPressure() -> Int {
        guard pressureMIBCount > 0 else { return 0 }
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&pressureMIB, UInt32(pressureMIBCount), &v, &size, nil, 0) == 0 else { return 0 }
        return Int(v)
    }

    /// 스왑 사용량(vm.swapusage). RAM 창이 열려 있을 때만 부른다.
    func readSwap() -> SwapUsage? {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(used: xsw.xsu_used, total: xsw.xsu_total)
    }
}
