import AppKit

/// 포커스와 상관없이 앱 창의 키보드/휠 이벤트를 받는다.
/// 시트(이름 바꾸기 창)나 텍스트 입력 중에는 건드리지 않는다.
final class EventMonitor {
    private var token: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { e in
            if NSApp.keyWindow?.attachedSheet != nil { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }
            return handler(e) ? nil : e
        }
    }

    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }

    deinit { stop() }
}
