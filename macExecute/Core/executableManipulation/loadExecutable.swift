//
//  loadExecutable.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Foundation
import Darwin
import MachO

class DylibMainRunner: ObservableObject {
    private var dylibHandle: UnsafeMutableRawPointer?
    private var inputPipe: [Int32] = [0, 0] // [readFd, writeFd]
    private var progName: UnsafeMutablePointer<CChar>?
    public var inputBuffer: [UInt8] = []  // Tracks all sent characters
    
    private init() {}
    
    static var shared = DylibMainRunner()
    
    func stop() {
        if let handle = dylibHandle {
            dlclose(handle)
        }
        if let prog = progName {
            free(prog)
        }
        if inputPipe[0] != 0 {
            close(inputPipe[0])
        }
        if inputPipe[1] != 0 {
            close(inputPipe[1])
        }
    }
    
    func run(dylibPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            NSLog("Dylib not found at \(dylibPath)")
            return false
        }
        
        guard pipe(&inputPipe) == 0 else {
            NSLog("Failed to create pipe")
            return false
        }
        
        // Redirect stdin to our pipe
        dup2(inputPipe[0], STDIN_FILENO)
        
        dylibHandle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL)
        guard let handle = dylibHandle else {
            NSLog("dlopen failed: \(String(cString: dlerror()!))")
            return false
        }
        
        let symbols = ["main", "_main", "start", "_start", "entry", "_entry"]
        var entrySymbol: UnsafeMutableRawPointer?
        
        for symbol in symbols {
            dlerror()
            if let sym = dlsym(handle, symbol), dlerror() == nil {
                entrySymbol = sym
                break
            }
        }
        
        guard let symbol = entrySymbol else {
            NSLog("Entry point not found")
            return false
        }
        
        typealias EntryFunc = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        let entry = unsafeBitCast(symbol, to: EntryFunc.self)
        
        progName = strdup(dylibPath)
        var argv: [UnsafeMutablePointer<CChar>?] = [progName, nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        let argc: Int32 = 1
        
        DispatchQueue.global(qos: .userInteractive).async {
            let result = entry(argc, &argv, &envp)
            NSLog("Entry point returned: \(result)")
        }
        
        return true
    }
    
    func sendInput(_ text: String) {
        let bytes = Array(text.utf8)
        inputBuffer.append(contentsOf: bytes)
        
        text.utf8CString.withUnsafeBufferPointer { buffer in
            write(inputPipe[1], buffer.baseAddress, buffer.count - 1)
        }
    }
    
    func removeFromIndex(_ index: Int) {
        guard index >= 0 && index < inputBuffer.count else {
            NSLog("Index out of range")
            return
        }
        
        // Calculate how many backspaces we need to send
        let positionsToMoveBack = inputBuffer.count - index
        
        // Send backspaces to move cursor to the target position
        for _ in 0..<positionsToMoveBack {
            var backspace: UInt8 = 8  // ASCII backspace
            write(inputPipe[1], &backspace, 1)
        }
        
        // Send remaining characters to overwrite the deleted portion
        let remainingChars = Array(inputBuffer[(index + 1)...])
        if !remainingChars.isEmpty {
            write(inputPipe[1], remainingChars, remainingChars.count)
        }
        
        // Send spaces to clear any remaining characters at the end
        let spacesNeeded = positionsToMoveBack - remainingChars.count
        if spacesNeeded > 0 {
            var space: UInt8 = 32  // ASCII space
            for _ in 0..<spacesNeeded {
                write(inputPipe[1], &space, 1)
            }
            // Move cursor back again
            for _ in 0..<spacesNeeded {
                var backspace: UInt8 = 8
                write(inputPipe[1], &backspace, 1)
            }
        }
        
        // Update our buffer
        inputBuffer.remove(at: index)
    }
}
