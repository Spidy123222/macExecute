//
//  loadExecutable.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Foundation
import Darwin
import MachO

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
    
    // Try multiple common entry point symbols
    let possibleSymbols = ["main", "_main", "start", "_start", "entry", "_entry", "__mh_execute_header"]
    var entrySymbol: UnsafeMutableRawPointer? = nil
    var entryPoint: UInt64 = 0
    
    for symbol in possibleSymbols {
        NSLog("Looking for symbol: \(symbol)")
        dlerror() // Clear any previous error
        entrySymbol = dlsym(handle, symbol)
        
        if entrySymbol != nil && dlerror() == nil {
            NSLog("Found entry point symbol: \(symbol)")
            break
        }
    }
    
    // Execute the entry point
    typealias EntryPointFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    
    let entryFunction = unsafeBitCast(entrySymbol, to: EntryPointFunction.self)
    
    // Setup arguments as a real executable would receive
    let progName = strdup(dylibPath)
    defer { free(progName) }
    
    var argv: [UnsafeMutablePointer<CChar>?] = [progName, nil]
    var envp: [UnsafeMutablePointer<CChar>?] = [nil]
    
    let argc: Int32 = 1
    
    NSLog("Executing entry point...")
    let result = entryFunction(argc, &argv, &envp)
    
    NSLog("Execution returned: \(result)")
    
    return result
    
}
