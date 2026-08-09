import ArgumentParser

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a window, an app's frontmost window, or an entire display.",
        discussion: """
        Exactly one of --window, --app, or --screen selects the capture target. \
        Pass --annotate to overlay numbered boxes on every accessibility element \
        in the window and get back a JSON legend mapping numbers to element ids, \
        roles, titles, and frames — feed the returned image to a vision-capable \
        model, then reference elements by number.
        """
    )

    @Option(help: "Capture this window id (from `windows`).")
    var window: Int?

    @Option(help: "Capture this app's frontmost on-screen window (name substring, bundle id, or pid).")
    var app: String?

    @Option(help: "Capture this display by index (from 0), instead of a window.")
    var screen: Int?

    @Option(help: "Output PNG path. Defaults to ~/.uictl/screenshots/<timestamp>.png.")
    var out: String?

    @Flag(help: "Overlay numbered boxes on every accessibility element and return a legend.")
    var annotate = false

    @Option(help: "When annotating, only include elements with this AXRole (e.g. AXButton).")
    var role: String?

    func run() throws {
        var params: JSONDict = ["annotate": annotate]
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        if let screen { params["screen"] = screen }
        if let out { params["out"] = out }
        if let role { params["role"] = role }
        emit(DaemonClient.send(command: "screenshot", params: params))
    }
}

struct ElementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elements",
        abstract: "Walk a window's accessibility tree and return every element's id, role, title, value, and frame."
    )

    @Option(help: "Window id (from `windows`). Either this or --app is required.")
    var window: Int?

    @Option(help: "App to inspect's frontmost window (name substring, bundle id, or pid).")
    var app: String?

    @Option(help: "Only include elements with this AXRole (e.g. AXButton, AXTextField).")
    var role: String?

    @Option(help: "Only include elements whose title/description contains this substring.")
    var title: String?

    @Option(help: "Maximum tree depth to walk.")
    var maxDepth: Int?

    @Option(help: "Stop after this many matching elements.")
    var maxElements: Int?

    func run() throws {
        var params: JSONDict = [:]
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        if let role { params["role"] = role }
        if let title { params["title"] = title }
        if let maxDepth { params["maxDepth"] = maxDepth }
        if let maxElements { params["maxElements"] = maxElements }
        emit(DaemonClient.send(command: "elements", params: params))
    }
}

struct OCRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ocr", abstract: "Recognize text in an image file or a window, optionally restricted to a region.")

    @Option(help: "Path to a PNG file to run OCR on, instead of capturing a window.")
    var image: String?

    @Option(help: "Window id to capture and OCR (from `windows`).")
    var window: Int?

    @Option(help: "App whose frontmost window to capture and OCR.")
    var app: String?

    @Option(help: "Restrict OCR to this region, in the same coordinate space as `elements` frames: \"x,y,w,h\".")
    var region: String?

    func run() throws {
        var params: JSONDict = [:]
        if let image { params["image"] = image }
        if let window { params["window"] = window }
        if let app { params["app"] = app }
        if let region { params["region"] = region }
        emit(DaemonClient.send(command: "ocr", params: params))
    }
}

struct PixelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pixel", abstract: "Sample the color of a single screen pixel.")

    @Option(help: "Screen point to sample: \"x,y\".")
    var at: String

    func run() throws {
        emit(DaemonClient.send(command: "pixel", params: ["at": at]))
    }
}
