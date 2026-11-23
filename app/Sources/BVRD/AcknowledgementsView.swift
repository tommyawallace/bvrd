import AppKit
import SwiftUI

/// Shows THIRD_PARTY_NOTICES.md from the app.
struct AcknowledgementsView: View {
    var body: some View {
        NoticesTextView()
            .frame(minWidth: 560, minHeight: 480)
    }
}

/// AppKit text view. SwiftUI gets slow on a file this long.
private struct NoticesTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textStorage?.setAttributedString(Self.notices())
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    private static func notices() -> NSAttributedString {
        let text = (try? String(contentsOf: AppInfo.noticesURL, encoding: .utf8)) ?? "Acknowledgements file missing."
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.textColor]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 2), .foregroundColor: NSColor.textColor]
        let result = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            let isHeading = line.hasPrefix("#")
            let shown = isHeading ? line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) : line.replacingOccurrences(of: "**", with: "")
            result.append(NSAttributedString(string: shown + "\n", attributes: isHeading ? heading : body))
        }
        return result
    }
}
