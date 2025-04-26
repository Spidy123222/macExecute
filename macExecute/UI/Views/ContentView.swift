//
//  ContentView.swift
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Combine

class LogCapture {
    static let shared = LogCapture()

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let originalStdout: Int32
    private let originalStderr: Int32
    
    var allLogs: [String] = []

    var capturedLogs: [(text: String, color: Color)] = [] {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .newLogCaptured, object: nil)
            }
        }
    }

    private init() {
        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)
    }

    func startCapturing() {
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        redirectOutput(to: stdoutPipe!, fileDescriptor: STDOUT_FILENO)
        redirectOutput(to: stderrPipe!, fileDescriptor: STDERR_FILENO)

        setupReadabilityHandler(for: stdoutPipe!, isStdout: true)
        setupReadabilityHandler(for: stderrPipe!, isStdout: false)
    }

    func stopCapturing() {
        dup2(originalStdout, STDOUT_FILENO)
        dup2(originalStderr, STDERR_FILENO)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private func redirectOutput(to pipe: Pipe, fileDescriptor: Int32) {
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileDescriptor)
    }

    private func setupReadabilityHandler(for pipe: Pipe, isStdout: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            let originalFD = isStdout ? self?.originalStdout : self?.originalStderr
            write(originalFD ?? STDOUT_FILENO, (data as NSData).bytes, data.count)

            if let logString = String(data: data, encoding: .utf8) {
                if !logString.isEmpty {
                    self?.processLog(logString, isStdout: isStdout)
                }
            }
        }
    }
    
    private func processLog(_ raw: String, isStdout: Bool) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        
        for line in lines {
            let osLogPattern = "OSLOG-[A-F0-9\\-]+\\s+\\d+\\s+\\d+\\s+[L]\\s+\\d+\\s+\\{.*\\}"
            let processedLine = line.trimmingCharacters(in: .newlines).replacingOccurrences(of: osLogPattern, with: "", options: .regularExpression)
            
            if processedLine.isEmpty || isSystemLog(String(processedLine)) {
                if !processedLine.isEmpty {
                    allLogs.append(processedLine)
                }
                continue
            }
            
            let (text, color) = parseAnsiEscapeCodes(input: String(processedLine))
            
            let pattern = "oo'\"mobile@localhost"
            let modifiedString = text.replacingOccurrences(of: pattern, with: "oo'\"\n\nmobile@localhost")
            
            capturedLogs.append((text: modifiedString, color: color))
            allLogs.append(text)
        }
    }


    private func isSystemLog(_ line: String) -> Bool {
        // Keep only essential system log filters to preserve ASCII art
        let patterns: [String] = [
            #"debugged"#,
            #"EXC_BAD_ACCESS"#,
            #"signal"#,
            #"dispatch"#,
            #"pthread"#,
            #"systemd"#,
            #"Apple"#,
            #"InputSystemClient"#,
            #"emoji"#,
            #"called - stubbed"#,
            #"forEach<Array"#,
            #"Hang detected: \d+\.\d+s \(debugger attached, not reporting\)"#,
            #"The view service did terminate with error: Error Domain=_UIViewServiceErrorDomain Code=1 \"\(null\)\" UserInfo=\{Terminated=disconnect method\}"#,
        ]
        
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    return true
                }
            }
        }
        
        return false
    }


    deinit {
        stopCapturing()
    }
}

extension Notification.Name {
    static let newLogCaptured = Notification.Name("newLogCaptured")
}



func parseAnsiEscapeCodes(input: String) -> (string: String, color: Color) {
    var outputString = ""
    var currentIndex = input.startIndex
    var currentColor = Color.white
    
    while currentIndex < input.endIndex {
        if input[currentIndex] == "\u{1B}" && input[input.index(after: currentIndex)] == "[" {
            // Found an ANSI escape sequence
            var escapeEndIndex = currentIndex
            
            // Find the end of the escape sequence (marked by 'm', 'C', etc.)
            while escapeEndIndex < input.endIndex && !input[escapeEndIndex].isNewline && !input[escapeEndIndex].isWhitespace && input[escapeEndIndex] != "m" && input[escapeEndIndex] != "C" {
                escapeEndIndex = input.index(after: escapeEndIndex)
            }
            
            // Check if we are still within bounds after the loop
            if escapeEndIndex < input.endIndex {
                // Include the escape character and the sequence character (e.g., 'm' or 'C')
                escapeEndIndex = input.index(after: escapeEndIndex)
                
                // Extract the escape sequence
                let escapeSequence = String(input[currentIndex..<escapeEndIndex])
                
                // Process the color code(s)
                let components = escapeSequence.dropFirst().dropLast().split(separator: ";")
                for component in components {
                    if component == "0" {
                        currentColor = .white
                    } else if component == "30" {
                        currentColor = .black
                    } else if component == "31" {
                        currentColor = .red
                    } else if component == "32" {
                        currentColor = .green
                    } else if component == "33" {
                        currentColor = .yellow
                    } else if component == "34" {
                        currentColor = .blue
                    } else if component == "35" {
                        currentColor = .purple // SwiftUI uses .purple instead of .magenta
                    } else if component == "36" {
                        currentColor = .cyan
                    } else if component == "37" {
                        currentColor = .white
                    }
                }
                
                // Handle Cursor movement (e.g., [34C)
                if escapeEndIndex < input.endIndex && input[escapeEndIndex] == "C" {
                    // Cursor movement, we just move the index forward and don't change color
                    currentIndex = escapeEndIndex
                    continue
                }
                
                // Move past this escape sequence
                currentIndex = escapeEndIndex
            } else {
                // Incomplete escape sequence, just add the ESC character and move on
                outputString.append(input[currentIndex])
                currentIndex = input.index(after: currentIndex)
            }
        } else {
            // Not an escape sequence, add the character to the output
            outputString.append(input[currentIndex])
            currentIndex = input.index(after: currentIndex)
        }
    }
    
    return (string: outputString, color: currentColor)
}


class LogViewModel: ObservableObject {
    @Published var logs: [(text: String, color: Color)] = []
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        LogCapture.shared.stopCapturing()
        
        NotificationCenter.default.publisher(for: .newLogCaptured)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLogs()
            }
            .store(in: &cancellables)
        
        updateLogs()
    }
    
    func updateLogs() {
        logs = LogCapture.shared.capturedLogs
    }
    
    func clearLogs() {
        LogCapture.shared.capturedLogs = []
        updateLogs()
    }
}

struct ContentView: View {
    @State private var showFileImporter = false
    @State private var statusMessage = "Tap to select executable"
    @AppStorage("certificate") private var certificate: Data?
    @AppStorage("password") private var password: String?
    @State private var inputText = ""
    
    @State private var currentBinaryPath: String? = nil
    
    @StateObject private var logsModel = LogViewModel()
    @StateObject private var runner = DylibMainRunner.shared
    
    init() {
        setenv("LC_HOME_PATH", getenv("HOME"), 1)
        init_bypassDyldLibValidation()
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { // Spacing: 0 for ASCII art
                            ForEach(Array(logsModel.logs.enumerated()), id: \.element.text) { index, log in
                                Text(log.text)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(log.color)
                                    .textSelection(.enabled)
                                    .id(index) // Ensure each log has a unique ID
                            }
                            Color.clear.frame(height: 1) // To anchor scroll
                                .id("bottom")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .background(Color.black)
                    .onChange(of: logsModel.logs.count) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                
                // Terminal input area
                HStack {
                    Text("›")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                    TextField("", text: $inputText)
                        .onSubmit {
                            sendInput()
                        }
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                        .background(Color.clear)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                }
                .padding(8)
                .background(Color.black)
                .overlay(Rectangle().frame(height: 1).foregroundColor(.gray), alignment: .top)
            }
            
            Button(action: {
                runner.stop()
                LogCapture.shared.stopCapturing()
                logsModel.clearLogs()
                // currentBinaryPath = nil
            }) {
                Text("Exit")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(8)
            }
        }
        .overlay {
            if currentBinaryPath == nil {
                ZStack(alignment: .center) {
                    Color.black.opacity(0.5)
                    
                    Button("Select Binary") {
                        currentBinaryPath = nil
                        showFileImporter = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onOpenURL { handleIncomingURL($0) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let fileURL) = result {
                processSelectedFile(fileURL)
            }
        }
    }
    
    private func sendInput() {
        guard !inputText.isEmpty else { return }
        runner.sendInput(inputText + "\n")
        inputText = ""
    }
    
    private func handleIncomingURL(_ url: URL) {
        guard url.host == "certificate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let cert = components.queryItems?.first(where: { $0.name == "cert" })?.value?.removingPercentEncoding,
              let pass = components.queryItems?.first(where: { $0.name == "password" })?.value,
              let certData = Data(base64Encoded: cert)
        else {
            logMessage("Failed to parse certificate")
            return
        }
        
        certificate = certData
        password = pass
        statusMessage = "Ready to select executable"
        logMessage("Certificate received")
    }
    
    private func processSelectedFile(_ fileURL: URL) {
        LogCapture.shared.stopCapturing()
        logsModel.clearLogs()
        
        logMessage("Processing: \(fileURL.lastPathComponent)")
        runner.stop()
        
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }

        #if os(iOS)
        guard let patched = patchExecutable(origPath: fileURL.path, targetPlatform: UInt32(PLATFORM_IOS)) else {
            logMessage("Patch failed")
            return
        }
        
        [
            ("/usr/lib/libpcre.0.dylib", "@rpath/libpcre.1.dylib"),
            ("/opt/homebrew/opt/pcre2/lib/libpcre2-32.0.dylib", "@rpath/libpcre.1.dylib"),
            ("/opt/homebrew/opt/ncurses/lib/libncursesw.6.dylib", "@rpath/libncursesw.6.dylib"),
            ("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", "/System/Library/Frameworks/Foundation.framework/Foundation"),
            ("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"),
            ("/System/Library/Frameworks/Security.framework/Versions/A/Security", "/System/Library/Frameworks/Security.framework/Security"),
            ("/System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation", "/System/Library/Frameworks/AVFoundation.framework/AVFoundation"),
            ("/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa", "@executable_path/Frameworks/Cocoa.framework/Cocoa"),
            ("/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio", "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"),
            ("/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia", "/System/Library/Frameworks/CoreMedia.framework/CoreMedia"),
            ("/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo", "/System/Library/Frameworks/CoreVideo.framework/CoreVideo"),
            ("/System/Library/Frameworks/CoreWLAN.framework/Versions/A/CoreWLAN", "@executable_path/Frameworks/Cocoa.framework/Cocoa"),
            ("/System/Library/Frameworks/IOBluetooth.framework/Versions/A/IOBluetooth", "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth"),
            ("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", "/System/Library/Frameworks/IOKit.framework/IOKit"),
            ("/System/Library/Frameworks/Metal.framework/Versions/A/Metal", "Metal.framework/Metal"),
            ("/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration", "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration"),
            ("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", "@executable_path/Frameworks/DisplayServices.framework/DisplayServices"),
            ("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "@executable_path/Frameworks/Tequila.framework/Tequila"),
            ("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics", "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        ].forEach { replacePatternInFile(at: patched, pattern: $0.0, replacement: $0.1) }
        
        #elseif os(macOS)
        guard let patched = patchExecutable(origPath: fileURL.path, targetPlatform: UInt32(PLATFORM_MACOS)) else {
            logMessage("Patch failed")
            return
        }
        #endif
        
        currentBinaryPath = patched
        
        patchMachO(path: patched)
        logMessage("Executable patched")
        
        runner.run(dylibPath: patched)
        try? FileManager.default.removeItem(atPath: patched)
    }
    
    private func logMessage(_ message: String) {
        // Add log message with white color
        LogCapture.shared.capturedLogs.append((text: message, color: .white))
        NSLog(message)
    }
}

#Preview {
    ContentView()
}
