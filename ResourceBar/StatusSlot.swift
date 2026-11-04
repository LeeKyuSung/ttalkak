// 메뉴바 칸 하나와 "오른쪽 끝에 고정"(docs/resourcebar.md 3절). Shared/Shared.swift의 StatusIcon과 같은 방식이다
// (칸을 24pt 아이콘이 아니라 직접 그린 넓은 칸으로 쓰기 때문에 따로 둔다).
//  - 위치는 autosaveName 기준 defaults 키 "NSStatusItem Preferred Position <이름>"(오른쪽 끝에서의 거리, 0 = 제어 센터 바로 왼쪽).
//    AppKit은 이 값을 칸을 만들 때만 읽으므로, 고정이 켜져 있으면 만들기 전에 0을 쓰고, 켜고 끌 때는 칸을 다시 만든다.
//  - 고정을 켜기 직전 자리를 남겨 두었다가 끌 때 되돌린다(없었으면 -1 → 키를 지워 macOS가 놓게 둔다).
//  - removeStatusItem이 저장 키를 한 박자 늦게 지우므로(macOS 26 실측) 1초 뒤 비었으면 다시 쓴다.
//  - 고정이 꺼져 있으면 위치에 손대지 않는다(⌘드래그로 옮긴 자리를 지킨다).
//  - --no-pin: 저장된 설정은 그대로 두고 이번 실행에만 고정을 끈다(위치 키를 지워 macOS 기본 자리에 놓는다).
import AppKit

final class StatusSlot {
    static let autosaveName = "ResourceBar"
    private static let pinKey = "PinToRightEnd"
    private static let prePinKey = "PositionBeforePin"
    private static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }

    private(set) var item: NSStatusItem
    /// 이번 실행에서 실제로 오른쪽 끝에 고정했는가(메뉴 체크 표시)
    private(set) var pinnedThisRun: Bool

    /// 칸을 없애기 직전(렌더러·창 정리)
    var willRebuild: (() -> Void)?
    /// 새 칸을 만든 직후(버튼 동작·렌더러 다시 붙이기)
    var didRebuild: ((NSStatusItem) -> Void)?

    init(noPin: Bool) {
        let d = UserDefaults.standard
        d.register(defaults: [Self.pinKey: true])   // 기본 켜짐
        let stored = d.bool(forKey: Self.pinKey)
        if stored && !noPin {
            d.set(0, forKey: Self.positionKey)      // 칸을 만들기 전에 써야 한다
        } else if stored && noPin {
            d.removeObject(forKey: Self.positionKey)
        }
        pinnedThisRun = stored && !noPin
        item = Self.makeItem()
    }

    private static func makeItem() -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: BarLayout.totalWidth)
        // autosaveName이 없으면 macOS가 "Item-N"을 배정하고, 숨김으로 저장된 옛 상태를 물려받을 수 있다
        it.autosaveName = autosaveName
        it.isVisible = true
        return it
    }

    /// 메뉴의 "오른쪽 끝에 고정" 켜기·끄기. 켜면 바로 오른쪽 끝으로, 끄면 켜기 전 자리로.
    func togglePin() {
        let d = UserDefaults.standard
        let turningOn = !pinnedThisRun
        let target: Double?
        if turningOn {
            // 저장된 설정이 꺼져 있던 경우에만 되돌릴 자리를 남긴다(--no-pin 실행에서 켜는 경우는 이미 기록돼 있다)
            if !d.bool(forKey: Self.pinKey) {
                d.set((d.object(forKey: Self.positionKey) as? Double) ?? -1, forKey: Self.prePinKey)
            }
            target = 0
        } else if let before = d.object(forKey: Self.prePinKey) as? Double, before >= 0 {
            target = before
        } else {
            target = nil
        }
        d.set(turningOn, forKey: Self.pinKey)
        pinnedThisRun = turningOn
        rebuild(position: target)
    }

    /// 칸을 없애고 다시 만든다. 우클릭 메뉴의 performClick이 아직 스택에 있을 수 있어 한 턴 미룬다.
    private func rebuild(position: Double?) {
        let key = Self.positionKey
        DispatchQueue.main.async { [self] in
            willRebuild?()
            NSStatusBar.system.removeStatusItem(item)
            if let p = position {
                UserDefaults.standard.set(p, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            item = Self.makeItem()   // 여기서 위치를 읽는다
            didRebuild?(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let p = position, UserDefaults.standard.object(forKey: key) == nil {
                    UserDefaults.standard.set(p, forKey: key)
                }
            }
        }
    }
}
