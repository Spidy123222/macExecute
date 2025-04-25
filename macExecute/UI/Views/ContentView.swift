//
//  ContentView.swift
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

import Foundation
import Darwin
import MachO
import SwiftUI
import MachOKit

class LogCapture {
    static let shared = LogCapture()

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let originalStdout: Int32
    private let originalStderr: Int32

    var capturedLogs: [String] = [] {
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

            if let logString = String(data: data, encoding: .utf8),
               let cleanedLog = self?.cleanLog(logString, isStdout: isStdout), !cleanedLog.isEmpty {
                self?.capturedLogs.append(cleanedLog)
            }
        }
    }

    private func cleanLog(_ raw: String, isStdout: Bool) -> String? {
        let lines = raw.split(separator: "\n")
        var filteredLines = lines.filter { line in
            // General check to determine if the line is likely from system logs or app logs
            if isSystemLog(String(line)) {
                return false // It's a system log, skip it
            }

            return true
        }

        // Clean up and remove extra spaces or empty lines
        let cleaned = filteredLines.map { line -> String in
            if let tabRange = line.range(of: "\t") {
                return line[tabRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")

        return cleaned.isEmpty ? nil : cleaned.replacingOccurrences(of: "\n\n", with: "\n")
    }

    // Determine if a log is likely from the system, based on content and known patterns
    private func isSystemLog(_ line: String) -> Bool {
        // Check if the line contains any known system log patterns
        let systemKeywords = [
            "debugger", "fatal error", "Thread", "EXC_BAD_ACCESS", "signal", "mach_error",
            "libSystem", "dispatch", "pthread", "systemd", "Apple", "dyld", "InputSystenClient", "emoji"
        ]
        
        // Check for a pattern that typically indicates a system-level log
        for keyword in systemKeywords {
            if line.lowercased().contains(keyword.lowercased()) {
                return true
            }
        }
        
        // Check for system log structure (e.g., log entry format)
        if line.lowercased().hasPrefix("process") || line.lowercased().contains("backtrace") {
            return true
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

import Combine

class LogViewModel: ObservableObject {
    @Published var logs: [String] = []
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        _ = LogCapture.shared
        
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
    @State var textinput = ""
    @StateObject private var logsModel = LogViewModel()
    
    @StateObject private var runner = DylibMainRunner.shared
    
    @State private var hideButtons = false
    
    init() {
        setenv("LC_HOME_PATH", getenv("HOME"), 1)
        init_bypassDyldLibValidation()
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Log display section
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logsModel.logs, id: \.self) { log in
                        Text(log)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(4)
                            .transition(.opacity)
                            .contextMenu() {
                                Button("Copy") {
                                    // UIPasteboard.general.string = log
                                }
                            }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            
            TextInputView()
                .contextMenu() {
                    Button {
                        hideButtons.toggle()
                    } label: {
                        Text(hideButtons ? "Show Buttons" : "Hide Buttons")
                    }
                }
            
            // Main action button
            if !hideButtons {
                Button(action: {
                    if certificate == nil || password == nil {
                        showFileImporter = true
                        let url = URL(string: "sidestore://certificate?callback_template=macexecute%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29")
                        if let url {
                            // UIApplication.shared.open(url)
                        }
                    } else {
                        showFileImporter = true
                    }
                }) {
                    Text(statusMessage)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                
                // Reset credentials button
                Button(action: {
                    certificate = nil
                    password = nil
                    statusMessage = "Tap to select executable"
                }) {
                    Text("Reset Credentials")
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleFileImport(result)
        }
    }
    
    
    
    private func handleIncomingURL(_ url: URL) {
        guard url.host == "certificate" else { return }
        
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems?.reduce(into: [String: String]()) {
                $0[$1.name.lowercased()] = $1.value
            } ?? [:]
            
            guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                  let password = queryItems["password"],
                  let certData = Data(base64Encoded: encodedCert) else {
                logMessage("Failed to parse certificate data")
                return
            }
            
            self.certificate = certData
            self.password = password
            logMessage("Certificate and password received")
            statusMessage = "Ready to select executable"
        }
    }
    
    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            processSelectedFile(fileURL)
        case .failure(let error):
            logMessage("File import failed: \(error.localizedDescription)")
        }
    }
    
    

    
    private func processSelectedFile(_ fileURL: URL) {
        logMessage("Processing file: \(fileURL.lastPathComponent)")
        
        runner.stop()
        
        
        // Enable security-scoped resource access
        let hasSecurityAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        // Step 1: Patch executable to make it a dylib
        #if os(iOS)
        guard let patchedPath = patchExecutable(origPath: fileURL.path, targetPlatform: UInt32(PLATFORM_IOS)) else {
            logMessage("Failed to patch executable")
            return
        }
        
        replacePatternInFile(at: patchedPath, pattern: "/usr/lib/libpcre.0.dylib", replacement: "@rpath/libpcre.1.dylib")
        replacePatternInFile(at: patchedPath, pattern: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", replacement: "/System/Library/Frameworks/Foundation.framework/Foundation")
        replacePatternInFile(at: patchedPath, pattern: "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices", replacement: "/System/Library/Frameworks/CoreServices.framework/CoreServices")
        replacePatternInFile(at: patchedPath, pattern: "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", replacement: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        replacePatternInFile(at: patchedPath, pattern: "/System/Library/Frameworks/Security.framework/Versions/A/Security", replacement: "/System/Library/Frameworks/Security.framework/Security")
        
        #elseif os(macOS)
        guard let patchedPath = patchExecutable(origPath: fileURL.path, targetPlatform: UInt32(PLATFORM_MACOS)) else {
            logMessage("Failed to patch executable")
            return
        }
        #endif
        
        patchMachO(path: patchedPath)
        logMessage("Successfully patched executable")
        
        
        // Step 2: Create minimal app bundle with the patched dylib
        let appURL = URL.temporaryDirectory.appendingPathComponent("coolApp.app")
        guard let appPath = createMinimalIOSAppBundle(outputPath: appURL.path, dylibPath: patchedPath) else {
            logMessage("Failed to create app bundle")
            return
        }
        
        // Step 4: Prepare entitlements
        let entitlementsURL = prepareEntitlements()
        
        // Step 5: Sign and export the app
        do {
            let exportedAppPath = try exportIPA()
            logMessage("App exported to: \(exportedAppPath)")
            
            // Sign the app

            
            
            /*
            ZSigner.sign(withAppPath: appPath.path, prov: nil, key: self.certificate, pass: password) { cool, error in
                print(error)
                print(cool)
                
                logMessage("App signed successfully")
                
                var dylibURL = appURL.appendingPathComponent("Frameworks").appendingPathComponent("patched_exec.dylib")
                logMessage("Loading dylib from: \(dylibURL.path)")
                
                // Execute with proper error handling
                oadAndExecuteMain(from: appURL.appendingPathComponent("Frameworks").appendingPathComponent("patched_exec.dylib").path)")
                
                // Clean up temporary files
                try? FileManager.default.removeItem(atPath: patchedPath)
            }
            */
            logMessage("Loading dylib from: \(patchedPath)")
            
            // Execute with proper error handling
            
            runner.run(dylibPath: patchedPath)
            
            // Clean up temporary files
            try? FileManager.default.removeItem(atPath: patchedPath)
            
        } catch {
            logMessage("Error during app processing: \(error.localizedDescription)")
        }
    }
    
    private func prepareEntitlements() -> URL {
        let entitlements: [String: Any] = [
            "application-identifier": Bundle.main.bundleIdentifier ?? "com.example.app",
            "get-task-allow": true,

        ]
        
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let entitlementsURL = documents.appendingPathComponent("entitlements.plist")
        
        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            try plistData.write(to: entitlementsURL)
            logMessage("Entitlements saved to: \(entitlementsURL.path)")
        } catch {
            logMessage("Failed to save entitlements: \(error.localizedDescription)")
        }
        
        return entitlementsURL
    }
    
    private func logMessage(_ message: String) {
        NSLog(message)
    }
}


func exportIPA() throws -> String {
    let fileManager = FileManager.default
    let bundleURL = Bundle.main.bundleURL
    
    let temporaryDirectory = fileManager.temporaryDirectory
    let appURL = temporaryDirectory.appendingPathComponent("currentApp.app")
    
    if fileManager.fileExists(atPath: appURL.path) {
        try fileManager.removeItem(at: appURL)
    }
    
    try fileManager.copyItem(at: bundleURL, to: appURL)
    
    return appURL.path
}




#Preview {
    ContentView()
}
