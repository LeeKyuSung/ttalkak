// MicRecorder — 메뉴 막대에서 좌클릭 한 번으로 마이크 녹음을 시작/중지한다.
//
// 저장 위치는 ~/Downloads. 파일은 .m4a(AAC) 이므로 Whisper 계열 전사 도구에 그대로 넘길 수 있다.

import AppKit
import AVFoundation

// MARK: - 상수

enum RK {
    static let micUIDKey = "micUniqueID"

    /// 내장 마이크 uniqueID. 첫 실행 기본값으로 쓴다 —
    /// AirPods 계열을 입력으로 잡으면 HFP 로 내려가 출력 음질이 통화 수준으로 떨어진다.
    static let builtInMicUID = "BuiltInMicrophoneDevice"

    static let filesAndFoldersURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
}

enum RecError: KoreanError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
    case inputFailed(String)
    case cannotCreateDir(String, String)

    var description: String {
        switch self {
        case .noDevice:           return "사용 가능한 마이크가 없습니다"
        case .cannotAddInput:     return "선택한 마이크를 캡처 세션에 추가할 수 없습니다"
        case .cannotAddOutput:    return "오디오 파일 출력을 추가할 수 없습니다"
        case .inputFailed(let m): return m
        case .cannotCreateDir(let p, let m): return "저장 폴더를 쓸 수 없습니다:\n\(p)\n\(m)"
        }
    }
}

// MARK: - Recorder

final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    static let shared = Recorder()

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    /// 세션 설정/구동은 블로킹이라 전용 직렬 큐에서 돌린다. 상태 변수는 메인 스레드에서만 만진다.
    private let sessionQueue = DispatchQueue(label: "MicRecorder.session")

    private(set) var isRecording = false
    /// 클릭 ~ 실제 시작 사이의 창. 블루투스 장치는 여기서 수백 ms ~ 수 초가 걸리므로
    /// 이 플래그가 없으면 사용자가 "안 눌렸나?" 하고 두 번 눌러 두 개의 녹음이 서로를 죽인다.
    private(set) var starting = false
    private(set) var stopping = false
    private(set) var currentURL: URL?
    private(set) var lastURL: URL?
    private var startedAt = Date()
    private var runtimeError: Error?

    var isBusy: Bool { isRecording || starting || stopping }

    /// 녹음 종료(성공/실패) 통지. 메인 스레드에서 호출된다.
    var onFinish: ((URL, Error?) -> Void)?
    /// 상태가 바뀌어 아이콘을 다시 그려야 할 때.
    var onStateChange: (() -> Void)?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError, object: session)
    }

    /// 런타임 오류는 알림을 따로 띄우지 않고 여기 담아 두었다가,
    /// 파일이 마무리된 뒤 "원인 + 파일의 운명" 을 한 번에 알리는 데 쓴다.
    func consumeRuntimeError() -> Error? {
        defer { runtimeError = nil }
        return runtimeError
    }

    // MARK: 저장 위치

    /// ~/Downloads. 폴더 자체는 항상 존재하지만, 접근 권한(TCC)이 거부되면 여기서 실패한다.
    /// 실패를 삼키면(try?) 녹음을 다 하고 나서야 문제를 알게 되므로 던진다.
    static func saveDir() throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw RecError.cannotCreateDir(dir.path, (error as NSError).localizedDescription)
        }
        return dir
    }

    /// 같은 초에 두 번 시작하면 충돌하므로(AVCaptureFileOutput 은 이미 존재하는 URL 로의 시작을
    /// 실패시킨다) 겹치면 접미사를 붙인다.
    static func newFileURL() throws -> URL {
        let dir = try saveDir()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "녹음_" + f.string(from: Date())
        var url = dir.appendingPathComponent("\(base).m4a")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path), n < 1000 {
            url = dir.appendingPathComponent("\(base)-\(n).m4a")
            n += 1
        }
        return url
    }

    // MARK: 장치

    /// 오래 살려 두는 DiscoverySession.
    /// 매번 새로 만들면 첫 생성에 170~410ms 가 걸린다. 한 번 만들어 두면 프레임워크가 갱신해 준다.
    ///
    /// `.microphone` 하나로 내장/블루투스/가상/연속성(iPhone) 마이크가 모두 나온다.
    private static let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)

    static func devices() -> [AVCaptureDevice] { discovery.devices }

    static func warmUp() { _ = discovery.devices }

    /// 저장된 uniqueID → 내장 마이크(첫 실행) → 시스템 기본 → 첫 번째.
    static func resolveDevice(in all: [AVCaptureDevice]) -> (device: AVCaptureDevice?, savedMissing: Bool) {
        guard !all.isEmpty else { return (nil, false) }
        if let uid = UserDefaults.standard.string(forKey: RK.micUIDKey) {
            if let match = all.first(where: { $0.uniqueID == uid }) { return (match, false) }
            return (fallbackDevice(all), true)   // 저장된 장치가 사라짐
        }
        return (fallbackDevice(all), false)
    }

    static func resolveDevice() -> (device: AVCaptureDevice?, savedMissing: Bool) {
        resolveDevice(in: devices())
    }

    private static func fallbackDevice(_ all: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let builtIn = all.first(where: { $0.uniqueID == RK.builtInMicUID }) { return builtIn }
        if let def = AVCaptureDevice.default(for: .audio),
           all.contains(where: { $0.uniqueID == def.uniqueID }) { return def }
        return all.first
    }

    // MARK: 경과 시간

    var elapsedString: String {
        let e = max(0, Int(Date().timeIntervalSince(startedAt)))
        return e >= 3600
            ? String(format: "%d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
            : String(format: "%02d:%02d", e / 60, e % 60)
    }

    // MARK: 시작 / 중지

    /// `completion` 은 메인 스레드에서 호출된다. nil 이면 녹음이 시작된 것. 메인 스레드 전용.
    func start(device: AVCaptureDevice, completion: @escaping (Error?) -> Void) {
        guard !isBusy else { completion(nil); return }

        let url: URL
        do { url = try Recorder.newFileURL() } catch { completion(error); return }

        starting = true   // 두 번째 클릭을 여기서 막는다 (isRecording 은 한참 뒤에나 true 가 된다)
        onStateChange?()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configure(device: device)
            } catch {
                DispatchQueue.main.async {
                    self.starting = false
                    self.onStateChange?()
                    completion(error)
                }
                return
            }
            self.session.startRunning()
            // AVSampleRateKey 는 힌트일 뿐이라 지정하지 않는다 — 장치 네이티브 레이트로 기록된다.
            // Whisper 쪽에서 `ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav` 로 맞추면 된다.
            self.output.audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            DispatchQueue.main.async {
                self.currentURL = url
                self.startedAt = Date()
                self.isRecording = true
                self.starting = false
                self.stopping = false
                self.runtimeError = nil
                self.output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
                self.onStateChange?()
                completion(nil)
            }
        }
    }

    private func configure(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        var committed = false
        defer { if !committed { session.commitConfiguration() } }

        session.inputs.forEach { session.removeInput($0) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecError.inputFailed((error as NSError).localizedDescription)
        }
        guard session.canAddInput(input) else { throw RecError.cannotAddInput }
        session.addInput(input)

        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw RecError.cannotAddOutput }
            session.addOutput(output)
        }
        session.commitConfiguration()
        committed = true
    }

    /// 파일 마무리(moov atom 기록)는 비동기다. 완료는 delegate 에서만 확인할 것.
    /// 여기서 기다리지 않고 프로세스를 죽이면 파일은 헤더 없는 mdat 덩어리가 되어 복구가 사실상 불가능하다.
    func stop() {
        guard isRecording, !stopping else { return }
        stopping = true
        onStateChange?()
        output.stopRecording()
    }

    // MARK: Delegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 이전 녹음의 뒤늦은 콜백이면 지금 돌고 있는 녹음의 상태를 절대 건드리지 않는다.
            guard self.currentURL == nil || self.currentURL == outputFileURL else {
                self.onFinish?(outputFileURL, error)
                return
            }
            self.sessionQueue.async { [weak self] in self?.session.stopRunning() }
            self.isRecording = false
            self.stopping = false
            self.currentURL = nil
            self.lastURL = outputFileURL
            self.onStateChange?()
            self.onFinish?(outputFileURL, error)
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.runtimeError = err
            self.stop()   // 알림은 여기서 띄우지 않는다. 파일이 마무리된 뒤 한 번만 알린다.
        }
    }
}

/// AVFoundation 오류 코드를 한국어로. 녹음이 왜 끊겼는지 사용자가 알아야 한다.
func avReasonText(_ error: Error?) -> String {
    guard let e = error as NSError? else { return "" }
    switch e.code {
    case -11808: return "입력 장치의 연결이 끊겼습니다 (AirPods 등)"
    case -11807: return "디스크 공간이 부족합니다"
    case -11811: return "파일 크기 한도에 도달했습니다"
    case -11819: return "미디어 서비스가 재설정되었습니다"
    default:     return e.localizedDescription
    }
}

// MARK: - AppDelegate

final class MicRecorderDelegate: NSObject, NSApplicationDelegate {
    private var icon: StatusIcon!
    private var tickTimer: Timer?
    private var savedMicMissing = false
    /// 종료 대기 중인가 (녹음 마무리를 기다리는 중).
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMeta.displayName = "녹음"

        icon = StatusIcon(pinDefault: true)   // 녹음 표시는 내장 화면에서도 항상 보여야 하니 켠 채로 시작
        icon.state = {
            // 대기는 채운 마이크, 녹음 중은 빨간 점. 모양과 색이 둘 다 달라서 흘깃 봐도 구분된다.
            // 맨 마이크(mic)는 획이 얇아 옆 시스템 아이콘에 묻힌다 — 채운 것을 쓴다.
            // macOS 의 "마이크 사용 중" 표시와 글리프가 비슷하지만, 그 표시는 녹음 중에만 뜨고
            // 그때 이 아이콘은 이미 빨간 점이라 실제로 겹치지 않는다.
            let r = Recorder.shared
            if r.isRecording { return IconLook("record.circle.fill", "녹음 중 \(r.elapsedString) — 클릭하면 중지", tint: .systemRed) }
            if r.starting    { return IconLook("record.circle", "시작하는 중…", tint: .systemRed, weight: .bold) }
            if r.stopping    { return IconLook("record.circle", "저장하는 중…", tint: .systemRed, weight: .bold) }
            return IconLook("mic.fill", "녹음 — 클릭하면 시작")
        }
        icon.onClick = { [weak self] in self?.toggleRecording() }
        icon.buildMenu = { [weak self] in self?.menu() ?? NSMenu() }
        icon.render()   // init 시점에는 state 가 아직 비어 있어 기본 아이콘으로 그려진다. 여기서 다시 그린다.

        Recorder.shared.onStateChange = { [weak self] in
            self?.icon.render()
            self?.updateTimer()
        }
        Recorder.shared.onFinish = { [weak self] url, err in
            self?.recordingFinished(url: url, error: err)
        }

        DispatchQueue.global(qos: .utility).async {
            Recorder.warmUp()
            LoginItem.refreshAsync()
        }

        // 로그아웃/재시동 경로. 종료 애플이벤트보다 먼저 도착할 수 있으므로 여기서도 파일을 마무리시킨다.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    // MARK: 경과 시간 표시

    private func updateTimer() {
        let needed = Recorder.shared.isRecording
        if needed, tickTimer == nil {
            // .common 모드가 아니면 메뉴가 열려 있는 동안 멈춘다.
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.icon.render() }
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        } else if !needed {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: 녹음 토글

    private func toggleRecording() {
        let r = Recorder.shared
        if r.isRecording { r.stop(); return }
        guard !r.isBusy else { return }   // 시작/저장 중인 클릭은 무시

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            // 프롬프트가 뜨는 동안 메인 스레드를 모달로 막지 않는다.
            icon.flashInfo("마이크 권한을 허용해 주세요", seconds: 6)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.beginRecording() } else { self.micDenied(justRefused: true) }
                }
            }
        default:
            micDenied()
        }
    }

    private func micDenied(justRefused: Bool = false) {
        icon.flashErr("마이크 권한 없음")
        failAlert(justRefused ? "마이크 권한이 거부되었습니다" : "마이크 권한이 필요합니다",
                  "시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 ‘녹음’을 켜주세요.",
                  actionTitle: "설정 열기") {
            openURLString(UI.micSettingsURL, whatFailed: "마이크 설정")
        }
    }

    private func beginRecording() {
        let all = Recorder.devices()
        let (device, missing) = Recorder.resolveDevice(in: all)
        savedMicMissing = missing

        guard let device else {
            icon.flashErr("마이크 없음")
            failAlert("사용 가능한 마이크가 없습니다",
                      "입력 장치가 하나도 보이지 않습니다.\n"
                      + "오디오가 먹통이라면 ‘오디오 재시작’으로 CoreAudio를 되살린 뒤 다시 시도해 보세요.")
            return
        }

        Recorder.shared.start(device: device) { [weak self] error in
            guard let self else { return }
            guard let error else {
                self.icon.flashOK("✓ 녹음 시작")
                return
            }
            self.icon.flashErr("시작 실패")
            if case RecError.cannotCreateDir = error {
                failAlert("저장 폴더를 쓸 수 없습니다",
                          "\(errText(error))\n\n"
                          + "시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더에서 "
                          + "‘녹음’의 다운로드 폴더 접근을 허용해 주세요.",
                          actionTitle: "설정 열기") {
                    openURLString(RK.filesAndFoldersURL, whatFailed: "파일 및 폴더 설정")
                }
            } else {
                failAlert("녹음을 시작하지 못했습니다", errText(error))
            }
        }
    }

    // MARK: 녹음 종료

    private func recordingFinished(url: URL, error: Error?) {
        let runtime = Recorder.shared.consumeRuntimeError()

        // AVFoundation 은 "중단됐지만 파일은 재생 가능" 을 이 키로 알려 준다.
        let playable = (error as NSError?)?
            .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool

        let finishedOK = (error == nil) || (playable == true)

        if finishedOK {
            let interrupted = error != nil || runtime != nil
            icon.flashOK(interrupted ? "✓ 저장됨 (중단됨)" : "✓ 저장됨", seconds: 3)
            if interrupted {
                let why = avReasonText(error ?? runtime)
                failAlert("녹음이 중간에 끊겼습니다",
                          "\(why)\n\n그때까지 녹음된 내용은 정상적으로 저장되었으니 지우지 마세요.\n\n\(url.path)",
                          actionTitle: "폴더 열기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } else {
            icon.flashErr("저장 실패")
            failAlert("녹음을 저장하지 못했습니다",
                      "\(avReasonText(error ?? runtime))\n\n\(url.path)")
        }

        // 종료를 기다리던 중이었다면 이제 보내 준다.
        if terminating {
            terminating = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: 종료 처리

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Recorder.shared.isRecording || Recorder.shared.stopping else { return .terminateNow }
        terminating = true
        Recorder.shared.stop()
        // 마무리가 어떤 이유로든 끝나지 않으면 앱이 영영 안 닫히므로 감시 타이머를 둔다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.terminating else { return }
            self.terminating = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func willPowerOff() {
        // 로그아웃/재시동. 모달을 띄우면 종료가 막히므로 파일만 조용히 마무리시킨다.
        Recorder.shared.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: 메뉴 (우클릭)

    private func menu() -> NSMenu {
        let m = NSMenu()
        let r = Recorder.shared

        if r.isRecording {
            addDisabledLine(m, "녹음 중 · \(r.elapsedString)")
        } else if r.starting {
            addDisabledLine(m, "시작하는 중…")
        } else if r.stopping {
            addDisabledLine(m, "저장하는 중…")
        } else {
            addDisabledLine(m, "좌클릭 = 즉시 녹음 시작")
        }
        m.addItem(.separator())

        let devices = Recorder.devices()
        let (selected, _) = Recorder.resolveDevice(in: devices)
        let deviceItem = NSMenuItem(title: "입력 장치", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu(devices: devices, selected: selected)
        deviceItem.isEnabled = !r.isBusy
        m.addItem(deviceItem)

        addItem(m, "저장 폴더 열기", target: self, #selector(openFolder))

        m.addItem(.separator())
        addPinRightItem(m, icon, target: self, #selector(togglePinRight))
        addItem(m, "로그인 시 자동 실행", target: self, #selector(toggleLogin),
                checked: LoginItem.cachedStatus() == .enabled)
        m.addItem(.separator())
        addItem(m, "종료", target: self, #selector(quit))
        return m
    }

    private func deviceMenu(devices: [AVCaptureDevice], selected: AVCaptureDevice?) -> NSMenu {
        let sub = NSMenu()
        guard !devices.isEmpty else {
            addDisabledLine(sub, "사용 가능한 마이크 없음")
            return sub
        }
        if savedMicMissing {
            addDisabledLine(sub, "저장해 둔 마이크가 없어 다른 장치를 씁니다")
            sub.addItem(.separator())
        }
        for d in devices {
            let mi = NSMenuItem(title: d.localizedName, action: #selector(pickDevice(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = d.uniqueID
            mi.state = (d.uniqueID == selected?.uniqueID) ? .on : .off
            mi.isEnabled = !Recorder.shared.isBusy
            sub.addItem(mi)
        }
        return sub
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: RK.micUIDKey)
        savedMicMissing = false
        icon.flashOK("✓ 입력 장치 변경됨")
    }

    @objc private func openFolder() {
        if let last = Recorder.shared.lastURL,
           FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
            return
        }
        do {
            let dir = try Recorder.saveDir()
            if !NSWorkspace.shared.open(dir) {
                failAlert("폴더를 열 수 없습니다", dir.path,
                          actionTitle: "경로 복사") { copyToPasteboard(dir.path) }
            }
        } catch {
            failAlert("저장 폴더를 열 수 없습니다", errText(error))
        }
    }

    @objc private func toggleLogin() { LoginItem.toggleFromMenu() }

    /// 노치 맥에서 외장 모니터를 빼면 메뉴 막대가 좁아져 왼쪽 항목부터 사라진다.
    /// 켜 두면 매 실행마다 오른쪽 끝(제어 센터 옆)으로 간다. 끄면 켜기 전 자리로 돌아간다.
    @objc private func togglePinRight() { icon.togglePinnedToRight() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 진입점

@main
enum MicRecorderMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MicRecorderDelegate()
        app.delegate = delegate
        _ = delegate
        app.run()
    }
}
