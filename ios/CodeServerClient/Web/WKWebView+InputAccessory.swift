import UIKit
import WebKit
import ObjectiveC

extension WKWebView {
    /// Removes the floating input accessory / assistant bar (the prev-next arrows
    /// + dictation pill) from every WKWebView by overriding `inputAccessoryView`
    /// on the private `WKContentView` class to return nil.
    ///
    /// Done at the class level (call once at launch) rather than per-instance: the
    /// per-instance `object_setClass` approach worked in the simulator but missed
    /// on device, because the content view that becomes first responder can be
    /// created/swapped after our hook ran. Overriding the class covers every
    /// instance regardless of timing.
    static func disableInputAccessoryViewGlobally() {
        guard let contentViewClass = NSClassFromString("WKContentView") else { return }
        let selector = #selector(getter: UIResponder.inputAccessoryView)

        let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        let implementation = imp_implementationWithBlock(block)

        guard let template = class_getInstanceMethod(UIResponder.self, selector) else { return }
        let typeEncoding = method_getTypeEncoding(template)

        // If WKContentView doesn't define its own getter, add ours (overrides the
        // inherited one). If it does, replace that implementation in place.
        if !class_addMethod(contentViewClass, selector, implementation, typeEncoding) {
            if let existing = class_getInstanceMethod(contentViewClass, selector) {
                method_setImplementation(existing, implementation)
            }
        }
    }

    /// Empties the iPad **input assistant** bar — the floating pill above/with the
    /// keyboard holding the prev/next arrows + dictation mic. That bar comes from
    /// `inputAssistantItem`, not `inputAccessoryView` (which defaults to nil), so
    /// removing it means clearing the assistant item's button groups on the web
    /// content view. Re-apply on focus/keyboard-show since the content view can be
    /// recreated.
    func clearInputAssistant() {
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        let item = contentView.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
    }
}
