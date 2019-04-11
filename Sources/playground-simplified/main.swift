import CommonMark
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var applicationHasStarted = false
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // the first instance of `NSDocumentController` becomes the shared controller...
        _ = MarkdownDocumentController()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationHasStarted = true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !applicationHasStarted else { return true }
        let controller = NSDocumentController.shared
        guard let recent = controller.recentDocumentURLs.first else { return true }
        controller.openDocument(withContentsOf: recent, display: true, completionHandler: { _, _, _ in () })
        return false
    }
}

let stdOutAttributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Monaco", size: 12)!, .foregroundColor: NSColor.textColor]
let stdErrAttributes: [NSAttributedString.Key: Any] = stdOutAttributes.merging([.foregroundColor: NSColor.red], uniquingKeysWith: { $1 })

protocol DocumentContext: class {
    var availableLocalLinks: [(url: URL, links: [String])] { get }
}

final class ViewController: NSViewController {
    let editor = NSTextView()
    let output = NSTextView()
    let editorDelegate = EditorDelegate()
    
    private var observationToken: Any?
    
    private var codeBlocks: [CodeBlock] = []
    private var repl: REPL<CodeBlock>?
    private let swiftHighlighter = SwiftHighlighter()
    weak var documentContext: DocumentContext?
    
    var text: String {
        get { return editor.string }
        set {
            editor.string = newValue
            highlight()
        }
    }
    
    override func loadView() {
        let editorScrollView = editor.configureAndWrapInScrollView(isEditable: true, inset: CGSize(width: 30, height: 30))
        let outputScrollView = output.configureAndWrapInScrollView(isEditable: false, inset: CGSize(width: 10, height: 30))
        output.delegate = self
        output.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        editor.allowsUndo = true
        editor.delegate = editorDelegate
        editorDelegate.onLocalLink = { [unowned self] link in
            guard let links = self.documentContext?.availableLocalLinks else { return }
            guard let url = links.first(where: { $0.links.contains(link) })?.url else {
                print("No such link") // todo show message
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true, completionHandler: { document, wasAlreadyOpen, err in
                guard let d = document as? MarkdownDocument else {
                    return // todo show message?
                }
                d.scrollToLink(link)
            })
            
        }
        let c = outputScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        c.priority = .defaultHigh
        c.isActive = true
        
        self.view = splitView([editorScrollView, outputScrollView])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observationToken = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: editor, queue: nil) { [unowned self] note in
            self.highlight()
        }
        setupREPL()
    }
    
    deinit {
        if let t = observationToken { NotificationCenter.default.removeObserver(t) }
    }
    
    override func viewDidAppear() {
        view.window!.makeFirstResponder(editor)
    }

    private func setupREPL() {
        repl = REPL(onOutput: { [unowned self] out in
           self.writeOutput(out)
        })
    }
    
    func writeOutput(_ out: REPL<CodeBlock>.Output<CodeBlock>) {
        let codeblock = out.metadata
        if let i = self.codeBlocks.firstIndex(where: { $0 == codeblock }) {
            if self.codeBlocks[i].error != out.stdErr {
                self.codeBlocks[i].error = out.stdErr
                self.highlight()
            }
        }
        let text = out.stdOut.isEmpty ? "No output" : out.stdOut
        writeOutput(text, source: codeblock)
        if let e = out.stdErr {
        	writeError(e, source: codeblock)
            self.scrollToError(codeblock.range)
        }
        self.output.scrollToEndOfDocument(nil)
    }
    
    func writeOutput(_ text: String, source: CodeBlock?) {
        var atts = stdOutAttributes
        if let s = source { atts[.link] = s.range }
        self.output.textStorage?.append(NSAttributedString(string: text + "\n", attributes: atts))
    }
    
    func writeError(_ string: String, source: CodeBlock?) {
        var atts = stdErrAttributes
        if let s = source { atts[.link] = s.range }
        self.output.textStorage?.append(NSAttributedString(string: string + "\n", attributes: atts))
    }
    
    func scrollToLink(_ name: String) {
        guard let range = editor.string.range(of: "{#\(name)}") else { return }
        editor.scrollRangeToVisible(NSRange(range, in: editor.string))
    }
    
    func highlight() {
        // todo: this code has too much knowledge about the highlighter.
        guard let att = editor.textStorage else { return }
        codeBlocks = att.highlightMarkdown(swiftHighlighter, codeBlocks: codeBlocks)
        guard !codeBlocks.isEmpty else { return }
        do {
            // if the call to highlight is *within* a `beginEditing` block, it crashes (!)
            let filtered = codeBlocks.filter { swiftHighlighter.cache[$0.text] == nil }
            let zipped = zip(filtered, try swiftHighlighter.highlight(filtered.map { $0.text }))
            for (block, result) in zipped {
                att.highlightCodeBlock(block: block, result: result)
            }
        } catch { print(error) }
    }
    
    @objc func execute() {
        guard let r = editor.selectedRanges.first?.rangeValue else { return }
        guard let found = codeBlocks.first(where: { ($0.range.lowerBound...$0.range.upperBound).contains(r.location) }) else { return }
        switch found.fenceInfo {
        case "swift", "swift-test":
            repl?.evaluate(found.text, metadata: found)
        case "swift-example":
            writeOutput("Not executing sample-only code", source: found)
        default:
            writeError("Unkown source type: \(found.fenceInfo ?? "<none>")", source: found)
        }
        
    }
    
    @objc func executeAll() {
        for b in codeBlocks {
            if b.fenceInfo == "swift-error" || b.fenceInfo == "swift-example" { continue }
            repl?.evaluate(b.text, metadata: b)
        }
    }
    
    @objc func reset() {
        setupREPL()
        for i in codeBlocks.indices { codeBlocks[i].error = nil } // reset error states
        output.string = ""
        highlight() // resets the error state in code blocks
    }
    
    @objc func verifyLinks() {
        var collectLinks: BlockAlgebra<[String]> = collect()
        collectLinks.inline.link = { _, _, url in url.map { [$0] } ?? [] }
        let node = Node(markdown: editor.string)!
        let links = node.reduce(collectLinks)
        
        let localLinks = (documentContext?.availableLocalLinks ?? []).flatMap {
            $0.links
        }
        
        // todo: the attributed strings could be much more rich (including a link)
        linkChecker(links, availableLocalLinks: localLinks, { [weak self] result in
            switch result.payload {
            case .invalidLocalLink:
                self?.writeError("Couldn't find local link \(result.link)", source: nil)
            case let .invalidURL(message: _):
                self?.writeError("Invalid URL \(result.link)", source: nil)
            case let .wrongStatusCode(statusCode: s, error: _):
                self?.writeError("Failed \(s) \(result.link)", source: nil)
            case let .other(message: m):
                self?.writeError("Failed \(result.link) \(m)", source: nil)
            case .success:
//                self?.writeOutput("200 OK \(result.link)", source: nil)
                ()
            }
        }, { [weak self] in
            self?.writeOutput("Link check done. Checked \(links.count) links.", source: nil)
        })
    }
    
    func scrollToError(_ range: NSRange) {
        editor.scrollRangeToVisible(range)
        editor.selectedRanges = [NSValue(range: NSRange(location: range.location, length: 0))]
        editor.window?.makeFirstResponder(editor)
    }
    
    func scrollTo(position: String.Index) {
        editor.scrollRangeToVisible(NSRange(position...position, in: editor.string))
    }
}

extension ViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let u = link as? NSRange {
            scrollToError(u)
            return true
        }
        
        return false
    }
}

final class EditorDelegate: NSObject, NSTextViewDelegate {
    var onLocalLink: (String) -> () = { _ in () }
    
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let l = link as? URL, l.absoluteString.hasPrefix("#") {
            let name = l.absoluteString.dropFirst()
            onLocalLink(String(name))
            return true
        } else {
            return false
        }
    }
}


let delegate = AppDelegate()
let app = application(delegate: delegate)
app.run()
