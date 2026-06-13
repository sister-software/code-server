import UIKit
import WebKit
import ObjectiveC

extension WKWebView {
    private static var suppressBarsKey: UInt8 = 0

    /// Opt-in flag: only web views with this set get the iPad input-assistant
    /// bar suppressed. The workbench sets it (kills the floating pill); the
    /// OAuth popup leaves it false so password AutoFill still appears.
    var suppressesNativeInputBars: Bool {
        get { (objc_getAssociatedObject(self, &Self.suppressBarsKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.suppressBarsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Walks up from a WKContentView to its owning WKWebView.
    fileprivate static func owningWebView(of view: AnyObject) -> WKWebView? {
        var current = view as? UIView
        while let v = current {
            if let webView = v as? WKWebView { return webView }
            current = v.superview
        }
        return nil
    }

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

    /// Neutralizes the iPad **input assistant** bar at the class level: overrides
    /// `inputAssistantItem` on `WKContentView` so its button groups are emptied
    /// every time the system fetches the item to assemble the bar.
    ///
    /// Instance-level clearing (see `clearInputAssistant`) is timing-dependent:
    /// focusing the editor purely via hardware keys (e.g. arrow keys on a fresh
    /// page, no touch) builds the bar before any keyboard notification lets us
    /// clear it. The class override has no such window.
    static func disableInputAssistantGlobally() {
        guard let contentViewClass = NSClassFromString("WKContentView") else { return }
        let selector = #selector(getter: UIResponder.inputAssistantItem)
        guard let template = class_getInstanceMethod(UIResponder.self, selector) else { return }

        // Call through to the inherited getter (the item is stored per responder),
        // then strip its groups before handing it back.
        typealias Getter = @convention(c) (AnyObject, Selector) -> UITextInputAssistantItem
        let original = unsafeBitCast(method_getImplementation(template), to: Getter.self)
        let block: @convention(block) (AnyObject) -> UITextInputAssistantItem = { receiver in
            let item = original(receiver, selector)
            // Only suppress for opted-in web views (the workbench). The OAuth
            // popup keeps its assistant bar so password AutoFill is offered.
            if WKWebView.owningWebView(of: receiver)?.suppressesNativeInputBars == true {
                item.leadingBarButtonGroups = []
                item.trailingBarButtonGroups = []
            }
            return item
        }
        let implementation = imp_implementationWithBlock(block)
        let typeEncoding = method_getTypeEncoding(template)

        // Add as an override on WKContentView only — never touch UIResponder's
        // own method, which every responder in the app inherits.
        if !class_addMethod(contentViewClass, selector, implementation, typeEncoding) {
            if let existing = class_getInstanceMethod(contentViewClass, selector) {
                method_setImplementation(existing, implementation)
            }
        }
    }

    /// Instance-level backstop for an assistant bar that already materialized:
    /// empties the content view's assistant groups and forces the system to
    /// rebuild input views so a visible bar is torn down, not just orphaned.
    @discardableResult
    func clearInputAssistant() -> String {
        func find(_ view: UIView) -> UIView? {
            if String(describing: type(of: view)).hasPrefix("WKContentView") { return view }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        guard let contentView = find(self) else { return "no-content-view" }
        let item = contentView.inputAssistantItem
        let before = item.leadingBarButtonGroups.count + item.trailingBarButtonGroups.count
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        if contentView.isFirstResponder {
            contentView.reloadInputViews()
        }
        return "\(type(of: contentView)) groups:\(before)->0 accessory:\(contentView.inputAccessoryView == nil ? "nil" : "set")"
    }
}
