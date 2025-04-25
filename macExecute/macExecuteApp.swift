//
//  macExecuteApp.swift
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

import SwiftUI
import Foundation

typealias ForkFunction = @convention(c) () -> pid_t
typealias ExecveFunction = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
typealias VforkFunction = @convention(c) () -> pid_t
typealias PosixSpawnFunction = @convention(c) (UnsafeMutablePointer<pid_t>?, UnsafePointer<CChar>?, UnsafePointer<posix_spawn_file_actions_t?>?, UnsafePointer<posix_spawnattr_t?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32


private var original_fork: ForkFunction?
private var original_execve: ExecveFunction?
private var original_vfork: VforkFunction?
private var original_posix_spawn: PosixSpawnFunction?
private var original_posix_spawnp: PosixSpawnFunction?


private func fork_replacement() -> pid_t {
    NSLog("[HOOK] fork() called - stubbed")
    return getpid()
}

private func execve_replacement(
    _ path: UnsafePointer<CChar>?,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    if let pathString = path.map({ String(cString: $0) }) {
        NSLog("[HOOK] execve() called for path: \(pathString) - stubbed")
    } else {
        NSLog("[HOOK] execve() called with nil path - stubbed")
    }
    return 0
}

private func vfork_replacement() -> pid_t {
    print("[HOOK] vfork() called - stubbed")
    return getpid()
}

private func makeCString(_ string: String) -> UnsafePointer<CChar> {
    let cString = strdup(string)
    return UnsafePointer(cString!)
}

private func createRebinding(name: String, replacement: UnsafeMutableRawPointer, replaced: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> rebinding {
    var rebind = rebinding()
    rebind.name = makeCString(name)
    rebind.replacement = replacement
    rebind.replaced = replaced
    return rebind
}

public func installProcessCreationHooks() {
    var rebindings = [
        createRebinding(
            name: "fork",
            replacement: unsafeBitCast(fork_replacement as ForkFunction, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_fork, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        createRebinding(
            name: "execve",
            replacement: unsafeBitCast(execve_replacement as ExecveFunction, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_execve, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        createRebinding(
            name: "vfork",
            replacement: unsafeBitCast(vfork_replacement as VforkFunction, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_vfork, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
    ]
    
    rebind_symbols(&rebindings, rebindings.count)
    
    print("[+] All process creation functions have been stubbed")
}

@main
struct macExecuteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear() {
                    installProcessCreationHooks()
                }
        }
    }
}
