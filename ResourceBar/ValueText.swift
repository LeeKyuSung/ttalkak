// 창·기록에 쓰는 숫자 글자. (메뉴 막대 렌더러는 BarLayout.swift에만 기대므로 자기 포맷터를 따로 둔다.)
import Foundation

enum ValueText {
    /// 0...1 → "23%"
    static func percent(_ ratio: Double) -> String {
        let v = ratio.isFinite ? max(ratio, 0) : 0
        return "\(Int((v * 100).rounded()))%"
    }

    /// 프로세스 CPU(코어 하나 = 100%) → "12.3%" / "105%"
    static func processCPU(_ pct: Double) -> String {
        let v = pct.isFinite ? max(pct, 0) : 0
        if v >= 99.95 { return "\(Int(v.rounded()))%" }
        return String(format: "%.1f%%", v)
    }

    /// 메모리(1024 단위) → "12.3 GB" / "345 MB" / "12 KB"
    static func memory(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        let gb = b / 1_073_741_824
        if gb >= 99.95 { return "\(Int(gb.rounded())) GB" }
        if gb >= 0.995 { return String(format: "%.1f GB", gb) }
        let mb = b / 1_048_576
        if mb >= 0.995 { return "\(Int(mb.rounded())) MB" }
        return "\(Int((b / 1024).rounded())) KB"
    }

    /// 디스크(1000 단위, Finder와 같음) → "812 GB" / "45.3 GB" / "1.2 TB"
    static func disk(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 999.5 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 99.5 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }

    /// 초당 바이트 → "28 KB/s" (메뉴바와 같은 규칙: 1024 단위, 정수부 최대 3자리)
    static func rate(_ bps: Double) -> String {
        let b = bps.isFinite ? max(bps, 0) : 0
        if b < 999.5 { return "\(Int(b.rounded())) B/s" }
        let kb = b / 1024
        if kb < 999.5 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 9.95 { return String(format: "%.1f MB/s", mb) }
        if mb < 999.5 { return "\(Int(mb.rounded())) MB/s" }
        return String(format: "%.1f GB/s", mb / 1024)
    }

    /// 한국어 목적격 조사: 앞 말의 마지막 소리에 받침이 있으면 "을", 없으면 "를".
    /// "(PID 123)"처럼 숫자로 끝나면 숫자 읽기로 정한다.
    static func objectParticle(after text: String) -> String {
        guard let last = text.last(where: { !")]}\"' ".contains($0) }) else { return "을" }
        if let d = last.wholeNumberValue {
            // 영 일 이 삼 사 오 육 칠 팔 구 → 받침: 영·일·삼·육·칠·팔
            return [0, 1, 3, 6, 7, 8].contains(d) ? "을" : "를"
        }
        if let s = last.unicodeScalars.first, (0xAC00...0xD7A3).contains(s.value) {
            return (s.value - 0xAC00) % 28 == 0 ? "를" : "을"
        }
        return "을"
    }
}
