// ResourceBar — 메뉴 막대 한 칸에 SSD·GPU·CPU·RAM·네트워크를 그리는 리소스 모니터.
// 왼쪽 클릭은 누른 위젯의 상세 창, 오른쪽 클릭(또는 control-클릭)은 설정 메뉴. 설계와 측정: docs/resourcebar.md
import AppKit
import ServiceManagement

@main
enum ResourceBarMain {
    static func main() {
        AppMeta.displayName = "리소스 모니터"
        let options = AppOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if options.loginItemInvalid {
            exit(2)
        }
        if let on = options.loginItem {
            exit(setLoginItem(on))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(options: options)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }

    /// --login-item on|off: 메뉴의 "로그인 시 자동 실행"과 같은 일(SMAppService.mainApp)을 하고 결과를 찍는다.
    /// 메뉴를 누를 수 없는 설치 스크립트용. 메뉴 막대 칸은 만들지 않는다.
    private static func setLoginItem(_ on: Bool) -> Int32 {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled {
                try service.register()
            } else if !on, service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            AppOptions.warn("로그인 항목을 바꾸지 못함: \(errText(error))")
            return 1
        }
        switch service.status {
        case .enabled: print("on")
        case .requiresApproval: print("requires-approval (시스템 설정 > 일반 > 로그인 항목에서 허용)")
        default: print("off")
        }
        return 0
    }
}
