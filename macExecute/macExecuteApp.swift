//
//  macExecuteApp.swift
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

import SwiftUI
import Foundation
import Darwin


class ThreadProcessManager {
    static let shared = ThreadProcessManager()
    
    // Maps "process IDs" to ThreadProcess objects
    private var processes = [pid_t: ThreadProcess]()
    private let lock = NSLock()
    
    // Next available PID (starting high to avoid conflicts with real PIDs)
    private var nextPid: pid_t = 10000
    
    private init() {}
    
    // Create a thread-based representation of a process
    class ThreadProcess {
        let pid: pid_t
        let ppid: pid_t
        var thread: Thread?
        var status: Int32 = 0
        var isRunning: Bool = true
        var stdin: Int32 = -1
        var stdout: Int32 = -1
        var stderr: Int32 = -1
        var pgid: pid_t = 0
        var argv: [String] = []
        var envp: [String] = []
        var path: String = ""
        
        init(pid: pid_t, ppid: pid_t, thread: Thread? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.thread = thread
            self.pgid = pid // Default process group is same as pid
        }
    }
    
    func allocatePid() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        
        let pid = nextPid
        nextPid += 1
        return pid
    }
    
    func registerProcess(_ process: ThreadProcess) {
        lock.lock()
        processes[process.pid] = process
        lock.unlock()
    }
    
    func unregisterProcess(pid: pid_t) {
        lock.lock()
        processes.removeValue(forKey: pid)
        lock.unlock()
    }
    
    func getProcess(pid: pid_t) -> ThreadProcess? {
        lock.lock()
        defer { lock.unlock() }
        return processes[pid]
    }
    
    func getAllProcesses() -> [ThreadProcess] {
        lock.lock()
        defer { lock.unlock() }
        return Array(processes.values)
    }
    
    func getChildProcesses(ppid: pid_t) -> [ThreadProcess] {
        lock.lock()
        defer { lock.unlock() }
        return processes.values.filter { $0.ppid == ppid }
    }
}

// Extensions to DylibMainRunner to support POSIX-like functionality
extension DylibMainRunner {
    // Thread local storage key for current PID
    private static var currentPidKey: pthread_key_t = 0
    
    // Initialize thread-local storage for PIDs
    class func setupThreadLocalStorage() {
        pthread_key_create(&currentPidKey, nil)
        
        // Set main thread's PID to 1
        let mainPid: pid_t = 1
        pthread_setspecific(currentPidKey, UnsafeMutableRawPointer(bitPattern: UInt(mainPid)))
        
        // Register main thread as a process
        let mainProcess = ThreadProcessManager.ThreadProcess(pid: mainPid, ppid: 0)
        ThreadProcessManager.shared.registerProcess(mainProcess)
    }
    
    // Get current thread's PID
    class func getCurrentPid() -> pid_t {
        if let pidPtr = pthread_getspecific(currentPidKey) {
            return pid_t(UInt(bitPattern: pidPtr))
        }
        
        // If not set, allocate a new PID for this thread
        let newPid = ThreadProcessManager.shared.allocatePid()
        pthread_setspecific(currentPidKey, UnsafeMutableRawPointer(bitPattern: UInt(newPid)))
        
        // Register as a process with parent as main thread
        let process = ThreadProcessManager.ThreadProcess(pid: newPid, ppid: 1)
        ThreadProcessManager.shared.registerProcess(process)
        
        return newPid
    }
    
    // Set PID for current thread
    class func setCurrentPid(_ pid: pid_t) {
        pthread_setspecific(currentPidKey, UnsafeMutableRawPointer(bitPattern: UInt(pid)))
    }
    
    // Run a command as a thread, emulating exec behavior
    func spawnThread(
        path: String,
        args: [String],
        env: [String],
        stdin: Int32,
        stdout: Int32,
        stderr: Int32
    ) -> pid_t {
        let childPid = ThreadProcessManager.shared.allocatePid()
        let ppid = DylibMainRunner.getCurrentPid()
        
        // Create the thread process object
        let process = ThreadProcessManager.ThreadProcess(pid: childPid, ppid: ppid)
        process.path = path
        process.argv = args
        process.envp = env
        process.stdin = stdin
        process.stdout = stdout
        process.stderr = stderr
        
        // Create thread to execute the dylib
        let thread = Thread {
            // Set thread PID
            DylibMainRunner.setCurrentPid(childPid)
            
            // Redirect stdin/stdout/stderr
            if stdin != STDIN_FILENO && stdin >= 0 {
                dup2(stdin, STDIN_FILENO)
            }
            if stdout != STDOUT_FILENO && stdout >= 0 {
                dup2(stdout, STDOUT_FILENO)
            }
            if stderr != STDERR_FILENO && stderr >= 0 {
                dup2(stderr, STDERR_FILENO)
            }
            
            // Execute the dylib using existing run method
            // This is simplified - we'd need to adapt it to support args/env
            self.run(dylibPath: path)
            
            // Mark process as completed
            if let proc = ThreadProcessManager.shared.getProcess(pid: childPid) {
                proc.isRunning = false
                proc.status = 0  // Assuming success
            }
        }
        
        process.thread = thread
        ThreadProcessManager.shared.registerProcess(process)
        
        thread.name = "pid-\(childPid)-\((path as NSString).lastPathComponent)"
        thread.qualityOfService = .userInteractive
        thread.start()
        threads.append(thread)
        
        return childPid
    }
}

// Original function pointers (saved during rebinding)
typealias ExecveType = @convention(c) (UnsafePointer<CChar>, UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
typealias PosixSpawnType = @convention(c) (
    UnsafeMutablePointer<pid_t>?,
    UnsafePointer<CChar>,
    UnsafePointer<posix_spawn_file_actions_t?>?,
    UnsafePointer<posix_spawnattr_t?>?,
    UnsafePointer<UnsafePointer<CChar>?>,
    UnsafePointer<UnsafePointer<CChar>?>
) -> Int32
typealias WaitpidType = @convention(c) (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> pid_t
typealias KillType = @convention(c) (pid_t, Int32) -> Int32
typealias GetpidType = @convention(c) () -> pid_t
typealias GetppidType = @convention(c) () -> pid_t
typealias SetpgidType = @convention(c) (pid_t, pid_t) -> Int32
typealias TcsetpgrpType = @convention(c) (Int32, pid_t) -> Int32
typealias WaitType = @convention(c) (UnsafeMutablePointer<Int32>?) -> pid_t
typealias SignalHandler = @convention(c) (Int32) -> Void
typealias SignalType = @convention(c) (Int32, SignalHandler) -> SignalHandler?
typealias ForkType = @convention(c) () -> pid_t

var original_fork: ForkType!
var original_execve: ExecveType!
var original_posix_spawn: PosixSpawnType!
var original_waitpid: WaitpidType!
var original_kill: KillType!
var original_getpid: GetpidType!
var original_getppid: GetppidType!
var original_setpgid: SetpgidType!
var original_tcsetpgrp: TcsetpgrpType!
var original_wait: WaitType!
var original_signal: SignalType!



// MARK: - Replacement Functions

func replacement_execve(path: UnsafePointer<CChar>, argv: UnsafePointer<UnsafePointer<CChar>?>, envp: UnsafePointer<UnsafePointer<CChar>?>) -> Int32 {
    let pathString = String(cString: path)
    var args = [String]()
    var env = [String]()
    
    // Convert argv to Swift array
    var i = 0
    while let argPtr = argv[i] {
        args.append(String(cString: argPtr))
        i += 1
    }
    
    // Convert envp to Swift array
    i = 0
    while let envPtr = envp[i] {
        env.append(String(cString: envPtr))
        i += 1
    }
    
    // Use stdin/stdout/stderr as is
    let childPid = DylibMainRunner.shared.spawnThread(
        path: pathString,
        args: args,
        env: env,
        stdin: STDIN_FILENO,
        stdout: STDOUT_FILENO,
        stderr: STDERR_FILENO
    )
    
    // execve replaces the current process, but we can't do that in iOS
    // Instead, we'll terminate the current thread after spawning the new one
    Thread.current.cancel()
    
    // This point should not be reached in real execve
    return 0
}

func replacement_posix_spawn(
    pid: UnsafeMutablePointer<pid_t>?,
    path: UnsafePointer<CChar>,
    file_actions: UnsafePointer<posix_spawn_file_actions_t?>?,
    attrp: UnsafePointer<posix_spawnattr_t?>?,
    argv: UnsafePointer<UnsafePointer<CChar>?>,
    envp: UnsafePointer<UnsafePointer<CChar>?>
) -> Int32 {
    let pathString = String(cString: path)
    var args = [String]()
    var env = [String]()
    
    // Convert argv to Swift array
    var i = 0
    while let argPtr = argv[i] {
        args.append(String(cString: argPtr))
        i += 1
    }
    
    // Convert envp to Swift array
    i = 0
    while let envPtr = envp[i] {
        env.append(String(cString: envPtr))
        i += 1
    }
    
    // Handle file actions (simplified - would need more complete implementation)
    var stdinFd = STDIN_FILENO
    var stdoutFd = STDOUT_FILENO
    var stderrFd = STDERR_FILENO
    
    if let actions = file_actions?.pointee {
        // In a real implementation, we would parse file_actions to get redirections
        // This is simplified for demonstration
    }
    
    let childPid = DylibMainRunner.shared.spawnThread(
        path: pathString,
        args: args,
        env: env,
        stdin: stdinFd,
        stdout: stdoutFd,
        stderr: stderrFd
    )
    
    // Set the PID output parameter if provided
    if let pidPtr = pid {
        pidPtr.pointee = childPid
    }
    
    return 0
}

func replacement_waitpid(pid: pid_t, stat_loc: UnsafeMutablePointer<Int32>?, options: Int32) -> pid_t {
    // If PID is -1, wait for any child
    if pid == -1 {
        let currentPid = DylibMainRunner.getCurrentPid()
        let children = ThreadProcessManager.shared.getChildProcesses(ppid: currentPid)
        
        if children.isEmpty {
            return -1 // No children
        }
        
        // Non-blocking check
        if options & WNOHANG != 0 {
            for child in children {
                if !child.isRunning {
                    if let stat = stat_loc {
                        stat.pointee = child.status
                    }
                    return child.pid
                }
            }
            return 0 // No completed children
        }
        
        // Blocking wait
        while true {
            for child in ThreadProcessManager.shared.getChildProcesses(ppid: currentPid) {
                if !child.isRunning {
                    if let stat = stat_loc {
                        stat.pointee = child.status
                    }
                    return child.pid
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    } else {
        // Wait for specific PID
        if let process = ThreadProcessManager.shared.getProcess(pid: pid) {
            // Non-blocking check
            if options & WNOHANG != 0 {
                if !process.isRunning {
                    if let stat = stat_loc {
                        stat.pointee = process.status
                    }
                    return pid
                }
                return 0 // Process still running
            }
            
            // Blocking wait
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.01)
            }
            
            if let stat = stat_loc {
                stat.pointee = process.status
            }
            return pid
        }
        
        return -1 // No such process
    }
}


func replacement_kill(pid: pid_t, sig: Int32) -> Int32 {
    if let process = ThreadProcessManager.shared.getProcess(pid: pid) {
        if sig == SIGTERM || sig == SIGKILL {
            process.isRunning = false
            process.status = 128 + sig
            
            // Cancel the thread if it exists
            process.thread?.cancel()
            
            return 0
        }
        
        // Handle other signals as needed
        
        return 0
    }
    
    return -1 // No such process
}

func replacement_getpid() -> pid_t {
    return DylibMainRunner.getCurrentPid()
}

func replacement_getppid() -> pid_t {
    let currentPid = DylibMainRunner.getCurrentPid()
    if let process = ThreadProcessManager.shared.getProcess(pid: currentPid) {
        return process.ppid
    }
    return 1 // Default to main process
}

func replacement_setpgid(pid: pid_t, pgid: pid_t) -> Int32 {
    let targetPid = pid == 0 ? DylibMainRunner.getCurrentPid() : pid
    let targetPgid = pgid == 0 ? targetPid : pgid
    
    if let process = ThreadProcessManager.shared.getProcess(pid: targetPid) {
        process.pgid = targetPgid
        return 0
    }
    
    return -1 // No such process
}

func replacement_tcsetpgrp(fd: Int32, pgrp: pid_t) -> Int32 {
    // Simulate terminal control group setting
    // Not fully applicable in iOS but we'll simulate success
    return 0
}

func replacement_wait(stat_loc: UnsafeMutablePointer<Int32>?) -> pid_t {
    return replacement_waitpid(pid: -1, stat_loc: stat_loc, options: 0)
}


func replacement_fork() -> pid_t {
    let parentPid = DylibMainRunner.getCurrentPid()
    guard let parentProcess = ThreadProcessManager.shared.getProcess(pid: parentPid) else {
        return -1 // Error - parent process not found
    }
    
    let childPid = ThreadProcessManager.shared.allocatePid()
    
    // Create a child process object
    let childProcess = ThreadProcessManager.ThreadProcess(pid: childPid, ppid: parentPid)
    
    // Copy parent's environment, file descriptors, etc.
    childProcess.stdin = parentProcess.stdin
    childProcess.stdout = parentProcess.stdout
    childProcess.stderr = parentProcess.stderr
    childProcess.pgid = parentProcess.pgid
    childProcess.argv = parentProcess.argv
    childProcess.envp = parentProcess.envp
    childProcess.path = parentProcess.path
    
    // Create thread to execute the child process
    let thread = Thread {
        // Set thread's PID
        DylibMainRunner.setCurrentPid(childPid)
        
        // In a real fork, execution would continue from this point
        // with the same code, but since we can't clone the entire
        // execution state, we need to signal somehow that this is the child
        
        // Create a fork event loop that will keep the thread alive
        // until terminated or instructed to execute something
        while childProcess.isRunning {
            Thread.sleep(forTimeInterval: 0.01)
            // This thread will mostly wait for commands via exec calls
            // or be terminated via kill/exit
        }
    }
    
    childProcess.thread = thread
    ThreadProcessManager.shared.registerProcess(childProcess)
    
    thread.name = "fork-child-\(childPid)"
    thread.qualityOfService = .userInteractive
    thread.start()
    DylibMainRunner.shared.threads.append(thread)
    
    // The current thread is the parent, return child's PID
    return childPid
}

// Extension to ThreadProcessManager to support process forking
extension ThreadProcessManager {
    func forkProcess(parentPid: pid_t) -> pid_t {
        guard let parent = getProcess(pid: parentPid) else {
            return -1 // Parent not found
        }
        
        let childPid = allocatePid()
        
        // Create copy of the parent process
        let child = ThreadProcess(pid: childPid, ppid: parentPid)
        // Copy file descriptors
        child.stdin = parent.stdin
        child.stdout = parent.stdout
        child.stderr = parent.stderr
        // Copy process group
        child.pgid = parent.pgid
        // Copy arguments and environment
        child.argv = parent.argv
        child.envp = parent.envp
        child.path = parent.path
        
        registerProcess(child)
        
        return childPid
    }
}

// Update the installation function to include fork
func installPOSIXRebindings() {
    // Initialize thread local storage for PIDs
    DylibMainRunner.setupThreadLocalStorage()
    
    // Create rebindings using the structure from fishhook.h
    var rebindings = [
        rebinding(
            name: strdup("execve"),
            replacement: unsafeBitCast(replacement_execve as ExecveType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_execve, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("posix_spawn"),
            replacement: unsafeBitCast(replacement_posix_spawn as PosixSpawnType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_posix_spawn, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("waitpid"),
            replacement: unsafeBitCast(replacement_waitpid as WaitpidType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_waitpid, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("kill"),
            replacement: unsafeBitCast(replacement_kill as KillType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_kill, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("getpid"),
            replacement: unsafeBitCast(replacement_getpid as GetpidType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_getpid, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("getppid"),
            replacement: unsafeBitCast(replacement_getppid as GetppidType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_getppid, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("setpgid"),
            replacement: unsafeBitCast(replacement_setpgid as SetpgidType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_setpgid, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("tcsetpgrp"),
            replacement: unsafeBitCast(replacement_tcsetpgrp as TcsetpgrpType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_tcsetpgrp, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("wait"),
            replacement: unsafeBitCast(replacement_wait as WaitType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_wait, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
        rebinding(
            name: strdup("fork"),
            replacement: unsafeBitCast(replacement_fork as ForkType, to: UnsafeMutableRawPointer.self),
            replaced: unsafeBitCast(original_fork, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
        ),
    ]
    
    // Call rebind_symbols with our rebindings
    let result = rebind_symbols(&rebindings, size_t(rebindings.count))
    
    // Free the strdup'd strings
    for i in 0..<rebindings.count {
        free(UnsafeMutableRawPointer(mutating: rebindings[i].name))
    }
    
    if result == 0 {
        NSLog("POSIX rebindings installed successfully")
    } else {
        NSLog("POSIX rebindings installation failed with code: %d", result)
    }
}

// Extension to DylibMainRunner to support process execution in forked threads
extension DylibMainRunner {
    // Execute a dylib in a forked thread context
    func executeInForkedThread(dylibPath: String, childPid: pid_t) -> Bool {
        guard let childProcess = ThreadProcessManager.shared.getProcess(pid: childPid) else {
            return false
        }
        
        // Set the path for the child process
        childProcess.path = dylibPath
        
        // Execute the dylib
        if let childThread = childProcess.thread {
            // Signal the thread to execute the dylib
            // This would require a more sophisticated mechanism
            // in a real implementation
            
            // For now, we'll just start a new execution
            self.run(dylibPath: dylibPath)
            return true
        }
        
        return false
    }
}
@main
struct macExecuteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear() {
                    #if os(iOS)
                    installPOSIXRebindings()
                    #endif
                }
        }
    }
}
