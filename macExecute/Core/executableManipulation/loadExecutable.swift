//
//  loadExecutable.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Foundation
import Darwin

class DylibMainRunner: ObservableObject {
    private var dylibHandle: UnsafeMutableRawPointer?
    private var inputPipe: [Int32] = [0, 0] // [readFd, writeFd]
    private var progName: UnsafeMutablePointer<CChar>?
    public var inputBuffer: [UInt8] = []  // Tracks all sent characters
    private var isRunning = false
    
    public var threads: [Thread] = []
    
    private init() {}
    
    static var shared = DylibMainRunner()
    
    func stop() {
        isRunning = false
        
        if let handle = dylibHandle {
            dlclose(handle)
            dylibHandle = nil
        }
        if let prog = progName {
            free(prog)
            progName = nil
        }
        
        for fd in [inputPipe[0], inputPipe[1]] {
            if fd != 0 {
                close(fd)
            }
        }
        
        inputPipe = [0, 0]
        
        for thread in threads {
            thread.cancel()
        }
    }
    
    func run(dylibPath: String) {
        NSLog("Attempting to run dylib at path: %@", dylibPath)

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            NSLog("File does not exist at path: %@", dylibPath)
            return
        }

        // Create pipes for communication
        guard pipe(&inputPipe) == 0 else {
            NSLog("Failed to create input pipe.")
            return
        }

        // Redirect stdin to our input pipe
        dup2(inputPipe[0], STDIN_FILENO)
        NSLog("Standard input redirected.")

        dylibHandle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL)
        guard let handle = dylibHandle else {
            if let error = dlerror() {
                let message = String(cString: error)
                print("Failed to load dylib with dlopen: \(message)")
            }
            return
        }
        NSLog("Dylib loaded successfully.")

        // Set up environment variables
        let shellEnv = "zsh"
        let homeEnv = URL.homeDirectory
        let pathEnv = "/bin:/usr/bin:/usr/local/bin"
        let termEnv = "dumb"

        setenv("SHELL", shellEnv, 1)
        setenv("HOME", homeEnv.path, 1)
        setenv("PATH", pathEnv, 1)
        setenv("TERM", termEnv, 1)
        setenv("LANG", "en_US.UTF-8", 1)
        NSLog("Environment variables set.")

        // Configure terminal settings
        var termios = termios()
        if tcgetattr(STDIN_FILENO, &termios) == 0 {
            termios.c_lflag &= ~UInt(ECHO | ICANON)
            termios.c_cc.18 = 1 // VMIN
            termios.c_cc.19 = 0 // VTIME
            tcsetattr(STDIN_FILENO, TCSANOW, &termios)
            NSLog("Terminal attributes configured.")
        } else {
            NSLog("Failed to get terminal attributes.")
        }

        // Set up environment for the shell
        var envp: [UnsafeMutablePointer<CChar>?] = [
            strdup("SHELL=\(shellEnv)"),
            strdup("HOME=\(homeEnv.path)"),
            strdup("PATH=\(pathEnv)"),
            strdup("TERM=\(termEnv)"),
            strdup("LANG=en_US.UTF-8"),
            nil
        ]
        NSLog("Shell environment prepared.")

        // Find entry point
        let symbols = ["main", "_main", "start", "_start", "entry", "_entry"]
        var entrySymbol: UnsafeMutableRawPointer?

        for symbol in symbols {
            dlerror()
            
            if let sym = dlsym(handle, symbol), dlerror() == nil {
                entrySymbol = sym
                NSLog("Found entry symbol: %@", symbol)
                break
            }
        }

        guard let symbol = entrySymbol else {
            NSLog("No entry symbol found.")
            return
        }

        // Convert entry point to function pointer
        typealias EntryFunc = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        let entry = unsafeBitCast(symbol, to: EntryFunc.self)

        progName = strdup((dylibPath as NSString).lastPathComponent)
        var argv: [UnsafeMutablePointer<CChar>?] = [
            progName,
            strdup("-f"),
            nil
        ]

        isRunning = true
        NSLog("Starting background thread for dylib execution.")

        // Execute entry point in background
        let argc: Int32 = 1
        var thread = Thread {
            LogCapture.shared.startCapturing()
            let result = entry(argc, &argv, &envp)
        }

        thread.name = (dylibPath as NSString).lastPathComponent
        thread.qualityOfService = .userInteractive
        thread.start()
        threads.append(thread)
        NSLog("Execution thread started.")
    }

    
    func sendInput(_ text: String) {
        guard isRunning else { return }
        
        let bytes = Array(text.utf8)
        inputBuffer.append(contentsOf: bytes)
        
        text.utf8CString.withUnsafeBufferPointer { buffer in
            write(inputPipe[1], buffer.baseAddress, buffer.count - 1)
        }
    }
    
    func sendControlSequence(_ controlChar: UInt8) {
        guard isRunning else { return }
        
        var ctrlChar = controlChar
        write(inputPipe[1], &ctrlChar, 1)
    }
    
    func removeFromIndex(_ index: Int) {
        guard index >= 0 && index < inputBuffer.count, isRunning else {
            return
        }
        
        // Send backspace to delete character
        var backspace: UInt8 = 8
        write(inputPipe[1], &backspace, 1)
        
        // Update internal buffer
        inputBuffer.remove(at: index)
    }
    
    // Improved line editing capabilities
    func clearLine() {
        guard isRunning else { return }
        
        // Send Ctrl+U to clear line
        sendControlSequence(21)
        inputBuffer.removeAll()
    }
    
    func cursorLeft() {
        guard isRunning else { return }
        
        // Send left arrow escape sequence
        let escSequence = "\u{1B}[D"
        escSequence.utf8CString.withUnsafeBufferPointer { buffer in
            write(inputPipe[1], buffer.baseAddress, buffer.count - 1)
        }
    }
    
    func cursorRight() {
        guard isRunning else { return }
        
        // Send right arrow escape sequence
        let escSequence = "\u{1B}[C"
        escSequence.utf8CString.withUnsafeBufferPointer { buffer in
            write(inputPipe[1], buffer.baseAddress, buffer.count - 1)
        }
    }
}
