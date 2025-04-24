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
    
    // If standard symbols aren't found, try to find entry point in loaded image
    if entrySymbol == nil {
        NSLog("No standard entry point found, trying to find entry point from dyld...")
        
        if let entryPointAddress = findEntryPointInLoadedImage(dylibPath) {
            NSLog("Found entry point at: 0x\(String(entryPointAddress, radix: 16))")
            
            // Try to use the address directly
            entryPoint = entryPointAddress
            entrySymbol = UnsafeMutableRawPointer(bitPattern: Int(entryPointAddress))
            
            if entrySymbol == nil {
                NSLog("Failed to create function pointer from entry point address")
                return -1
            }
        } else {
            NSLog("Failed to find entry point in loaded image")
            return -1
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
    if isAddressExecutable(UnsafeRawPointer(bitPattern: UInt(entryPoint))!) {
        NSLog("Entry point address is executable")
        let result = entryFunction(argc, &argv, &envp)
        
        NSLog("Execution returned: \(result)")
        
        return result
    } else {
        NSLog("Entry point address is NOT executable")
        
        let pageSize = getpagesize()
        let pageStart = UInt(bitPattern: entrySymbol) & ~(UInt(pageSize - 1))

        let result = mprotect(UnsafeMutableRawPointer(bitPattern: pageStart), Int(pageSize), PROT_READ | PROT_EXEC)

        if result != 0 {
            perror("mprotect failed")
            return -1
        }
        let result2 = entryFunction(argc, &argv, &envp)
        
        return result2
    }
    
    
}

func isAddressExecutable(_ addr: UnsafeRawPointer) -> Bool {
    var address = vm_address_t(UInt(bitPattern: addr))
    var size: vm_size_t = 0
    var info = vm_region_basic_info_64()
    var infoCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    var objectName: mach_port_t = 0
    
    let protection = info.protection

    return withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: Int32.self, capacity: Int(infoCount)) { reboundInfoPtr in
            let result = vm_region_64(
                mach_task_self_,
                &address,
                &size,
                VM_REGION_BASIC_INFO_64,
                reboundInfoPtr,
                &infoCount,
                &objectName
            )

            if result == KERN_SUCCESS {
                return protection & VM_PROT_EXECUTE != 0
            } else {
                NSLog("vm_region_64 failed with code: \(result)")
                return false
            }
        }
    }
}

func findEntryPointInLoadedImage(_ path: String) -> UInt64? {
    NSLog("Searching for loaded image: \(path)")
    let imageCount = _dyld_image_count()
    
    for i in 0..<imageCount {
        guard let cName = _dyld_get_image_name(i) else { continue }
        let imagePath = String(cString: cName)
        
        if imagePath == path {
            NSLog("Found matching image: \(imagePath)")
            
            guard let headerPtr = _dyld_get_image_header(i) else {
                NSLog("Failed to get Mach-O header")
                continue
            }
            
            let slide = _dyld_get_image_vmaddr_slide(i)
            let headerMagic = UnsafePointer<UInt32>(OpaquePointer(headerPtr)).pointee
            guard headerMagic == MH_MAGIC_64 || headerMagic == MH_CIGAM_64 else {
                NSLog("Image is not a 64-bit Mach-O binary")
                continue
            }
            
            let header = UnsafePointer<mach_header_64>(OpaquePointer(headerPtr))
            var cmdPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            var textSegmentVMAddr: UInt64? = nil
            
            for _ in 0..<header.pointee.ncmds {
                let loadCmd = cmdPtr.load(as: load_command.self)
                
                if loadCmd.cmd == LC_SEGMENT_64 {
                    let segCmd = cmdPtr.load(as: segment_command_64.self)
                    let segName = withUnsafePointer(to: segCmd.segname) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 16) {
                            String(cString: $0)
                        }
                    }
                    if segName == "__TEXT" {
                        textSegmentVMAddr = segCmd.vmaddr
                    }
                } else if loadCmd.cmd == LC_MAIN {
                    let epCmd = cmdPtr.load(as: entry_point_command.self)
                    let entryPoint = UInt64(slide) + epCmd.entryoff
                    NSLog("Found LC_MAIN entry point at 0x\(String(entryPoint, radix: 16))")
                    return entryPoint
                }
                if loadCmd.cmdsize < MemoryLayout<load_command>.size {
                    NSLog("Invalid command size: \(loadCmd.cmdsize)")
                    break
                }
                
                cmdPtr = cmdPtr.advanced(by: Int(loadCmd.cmdsize))
            }
        }
    }
    
    NSLog("Entry point not found in loaded images")
    return nil
}
