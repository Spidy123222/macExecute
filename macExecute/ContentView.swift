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
import UIKit

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
        startCapturing()
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
               let cleanedLog = self?.cleanLog(logString), !cleanedLog.isEmpty {
                self?.capturedLogs.append(cleanedLog)
            }
        }
    }

    private func cleanLog(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n")
        let filteredLines = lines.filter { line in
            !line.contains("SwiftUI") &&
            !line.contains("ForEach") &&
            !line.contains("VStack") &&
            !line.contains("Invalid frame dimension (negative or non-finite).")
        }

        let cleaned = filteredLines.map { line -> String in
            if let tabRange = line.range(of: "\t") {
                return line[tabRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")

        return cleaned.isEmpty ? nil : cleaned.replacingOccurrences(of: "\n\n", with: "\n")
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
    @StateObject private var logsModel = LogViewModel()
    
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
                                    UIPasteboard.general.string = log
                                }
                            }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Main action button
            Button(action: {
                if certificate == nil || password == nil {
                    let url = URL(string: "sidestore://certificate?callback_template=macexecute%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29")
                    if let url {
                        UIApplication.shared.open(url)
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
        
        // Enable security-scoped resource access
        let hasSecurityAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Step 1: Patch executable to make it a dylib
        guard let patchedPath = patchExecutable(origPath: fileURL.path, targetPlatform: UInt32(PLATFORM_IOS)) else {
            logMessage("Failed to patch executable")
            return
        }
        
        patchMachO(patchedPath)
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
            guard let password = self.password else {
                logMessage("Password not available")
                return
            }
            
            
            ZSigner.sign(withAppPath: exportedAppPath, prov: (try? Data(contentsOf: URL(string: exportedAppPath)!.appendingPathComponent("embedded.mobileprovision"))), key: self.certificate, pass: password) { cool, error in
                print(error)
                print(cool)
                
                logMessage("App signed successfully")
                
                var dylibURL = appURL.appendingPathComponent("Frameworks").appendingPathComponent("patched_exec.dylib")
                logMessage("Loading dylib from: \(dylibURL.path)")
                
                // Execute with proper error handling
                let result = loadAndExecuteMain(from: appURL.appendingPathComponent("Frameworks").appendingPathComponent("patched_exec.dylib").path)
                logMessage("Execution completed with result: \(result)")
                
                // Clean up temporary files
                try? FileManager.default.removeItem(atPath: patchedPath)
            }
            
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

func createMinimalIOSAppBundle(outputPath: String, dylibPath: String? = nil) -> URL? {
    let fileManager = FileManager.default
    
    do {
        // Get current bundle
        let currentBundle = Bundle.main.bundleURL
        
        // Create temporary directory for the minimal bundle
        let tempBundlePath = URL(fileURLWithPath: outputPath)
        
        // Remove if exists
        if fileManager.fileExists(atPath: tempBundlePath.path) {
            try fileManager.removeItem(at: tempBundlePath)
        }
        
        // Create bundle directory structure
        try fileManager.createDirectory(at: tempBundlePath, withIntermediateDirectories: true)
        
        // Setup paths
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? "Unknown"
        
        // Copy Info.plist
        let sourcePlist = currentBundle.appendingPathComponent("Info.plist")
        let destPlist = tempBundlePath.appendingPathComponent("Info.plist")
        if fileManager.fileExists(atPath: sourcePlist.path) {
            try fileManager.copyItem(at: sourcePlist, to: destPlist)
        }
        
        // Copy executable
        let sourceExec = currentBundle.appendingPathComponent(executableName)
        let destExec = tempBundlePath.appendingPathComponent(executableName)
        if fileManager.fileExists(atPath: sourceExec.path) {
            try fileManager.copyItem(at: sourceExec, to: destExec)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destExec.path)
        }
        
        // Create Frameworks directory and add dylib if provided
        if let dylibPath = dylibPath {
            // Create Frameworks directory
            let frameworksDir = tempBundlePath.appendingPathComponent("Frameworks")
            try fileManager.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
            
            // Get dylib file URL
            let dylibURL = URL(fileURLWithPath: dylibPath)
            let dylibName = dylibURL.lastPathComponent
            let destDylibPath = frameworksDir.appendingPathComponent(dylibName)
            
            // Copy dylib to Frameworks directory
            if fileManager.fileExists(atPath: dylibPath) {
                try fileManager.copyItem(at: dylibURL, to: destDylibPath)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDylibPath.path)
                print("Added dylib \(dylibName) to Frameworks directory")
            } else {
                print("Warning: Dylib not found at path: \(dylibPath)")
            }
        }
        
        print("Created minimal iOS app bundle at: \(tempBundlePath.path)")
        return tempBundlePath
        
    } catch {
        print("Error creating minimal iOS app bundle: \(error)")
        return nil
    }
}

func patchExecutable(origPath: String, targetPlatform: UInt32) -> String? {
    let tempDirectory = NSTemporaryDirectory()
    let tempPath = (tempDirectory as NSString).appendingPathComponent("patched_exec.dylib")
    let fileName = URL(fileURLWithPath: tempPath).lastPathComponent
    
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: origPath))
        try data.write(to: URL(fileURLWithPath: tempPath))
    } catch {
        NSLog("Error copying file: \(error)")
        return nil
    }

    let fd = open(tempPath, O_RDWR)
    if fd < 0 {
        NSLog("Failed to open file: \(String(cString: strerror(errno)))")
        return nil
    }
    defer { close(fd) }

    var stat = stat()
    if fstat(fd, &stat) != 0 {
        NSLog("Failed to get file stats: \(String(cString: strerror(errno)))")
        return nil
    }
    
    guard let fileData = mmap(nil, Int(stat.st_size),
                              PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) else {
        NSLog("Failed to mmap file: \(String(cString: strerror(errno)))")
        return nil
    }
    defer { munmap(fileData, Int(stat.st_size)) }

    let header = fileData.assumingMemoryBound(to: mach_header_64.self)
    if header.pointee.magic != MH_MAGIC_64 {
        NSLog("Invalid Mach-O file (wrong magic)")
        return nil
    }
    
    var cmdPtr = fileData.advanced(by: MemoryLayout<mach_header_64>.size)
    var cmd = cmdPtr.assumingMemoryBound(to: load_command.self)
    var platformFound = false

    for _ in 0..<header.pointee.ncmds {
        if cmd.pointee.cmd == LC_BUILD_VERSION {
            let buildCmd = UnsafeMutablePointer<build_version_command>(OpaquePointer(cmd))
            NSLog("Patching platform from \(buildCmd.pointee.platform) to \(targetPlatform)")
            buildCmd.pointee.platform = targetPlatform
            platformFound = true
        }
        
        cmdPtr = cmdPtr.advanced(by: Int(cmd.pointee.cmdsize))
        cmd = cmdPtr.assumingMemoryBound(to: load_command.self)
    }

    if !platformFound {
        NSLog("Warning: LC_BUILD_VERSION not found")
    }
    
    
    msync(fileData, Int(stat.st_size), MS_SYNC)
    munmap(fileData, Int(stat.st_size))
    close(fd)
    
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        return tempPath
        
    } catch {
        NSLog("Error adding LC_ID_DYLIB: \(error)")
        return nil
    }
}

func loadAndExecuteMain(from dylibPath: String) -> Int32 {
    guard FileManager.default.fileExists(atPath: dylibPath) else {
        NSLog("Error: Dylib not found at \(dylibPath)")
        return -1
    }
    
    // Try to open the library
    NSLog("Opening dylib: \(dylibPath)")
    guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
        if let error = dlerror() {
            NSLog("dlopen failed: \(String(cString: error))")
        } else {
            NSLog("dlopen failed with no error message")
        }
        return -1
    }
    defer { dlclose(handle) }

    NSLog("Looking for main symbol...")
    guard let mainSymbol = dlsym(handle, "main") else {
        if let error = dlerror() {
            NSLog("dlsym failed: \(String(cString: error))")
        } else {
            NSLog("main symbol not found")
        }
        return -1
    }
    
    NSLog("Main symbol found, executing...")
    
    typealias MainFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    
    let mainFunction = unsafeBitCast(mainSymbol, to: MainFunction.self)
    
    let progName = strdup(dylibPath)
    defer { free(progName) }
    
    var argv: [UnsafeMutablePointer<CChar>?] = [progName, nil]
    let argc: Int32 = 1
    
    NSLog("Calling main function...")
    let result = mainFunction(argc, &argv)
    NSLog("Main function returned: \(result)")
    
    return result
}


#Preview {
    ContentView()
}
