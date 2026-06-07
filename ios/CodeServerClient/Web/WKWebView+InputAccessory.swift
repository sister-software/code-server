import UIKit
import WebKit
import ObjectiveC

/// Removes the input accessory view — the floating bar above the keyboard with
/// the prev/next arrows and dictation control — from a WKWebView.
///
/// WKWebView delegates first-responder duties to an internal `WKContentView`, so
/// overriding `inputAccessoryView` on WKWebView has no effect. Instead we install
/// a runtime subclass of the content view whose `inputAccessoryView` returns nil.
/// On a code editor that bar is pure noise and it shoves the web content upward
/// every time an input is focused.
extension WKWebView {
    func removeInputAccessoryView() {
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let targetClass = object_getClass(contentView) else {
            return
        }

        let newClassName = "\(targetClass)_NoInputAccessory"

        if let existing = NSClassFromString(newClassName) {
            object_setClass(contentView, existing)
            return
        }

        guard let newClass = objc_allocateClassPair(targetClass, newClassName, 0) else { return }
        if let method = class_getInstanceMethod(
            NoInputAccessoryShim.self,
            #selector(getter: NoInputAccessoryShim.inputAccessoryView)
        ) {
            class_addMethod(
                newClass,
                #selector(getter: UIResponder.inputAccessoryView),
                method_getImplementation(method),
                method_getTypeEncoding(method)
            )
        }
        objc_registerClassPair(newClass)
        object_setClass(contentView, newClass)
    }
}

private final class NoInputAccessoryShim: NSObject {
    @objc var inputAccessoryView: UIView? { nil }
}
