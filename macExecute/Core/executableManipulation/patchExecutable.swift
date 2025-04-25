//
//  executable.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Foundation
import Darwin
import MachO
import MachOKit

func OSSwapInt32(_ cool: UInt32) -> UInt32 {
    cool.byteSwapped
}

func OSSwapInt32(_ cool: Int32) -> Int32 {
    cool.byteSwapped
}

typealias ParseMachOCallback = (
    _ path: UnsafePointer<CChar>,
    _ header: UnsafeMutablePointer<mach_header_64>,
    _ fd: Int32,
    _ filePtr: UnsafeMutableRawPointer
) -> Void

func parseMachO(path: UnsafePointer<CChar>, callback: ParseMachOCallback) -> String? {
    let fd = open(path, O_RDWR, 0o600)
    var stat = stat()
    fstat(fd, &stat)
    
    guard let map = mmap(nil, Int(stat.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) else {
        return String(format: "Failed to map %s: %s", path, strerror(errno))
    }
    
    if map == MAP_FAILED {
        return String(format: "Failed to map %s: %s", path, strerror(errno))
    }
    
    let magic = map.load(as: UInt32.self)
    
    if magic == FAT_CIGAM {
        // Find compatible slice
        let header = map.bindMemory(to: fat_header.self, capacity: 1)
        var arch = (map + MemoryLayout<fat_header>.size).bindMemory(to: fat_arch.self, capacity: 1)
        
        for _ in 0..<OSSwapInt32(header.pointee.nfat_arch) {
            if OSSwapInt32(arch.pointee.cputype) == CPU_TYPE_ARM64 {
                let offset = Int(OSSwapInt32(arch.pointee.offset))
                let machHeader = (map + offset).bindMemory(to: mach_header_64.self, capacity: 1)
                callback(path, machHeader, fd, map)
            }
            arch = arch.advanced(by: 1)
        }
    } else if magic == MH_MAGIC_64 || magic == MH_MAGIC {
        let machHeader = map.bindMemory(to: mach_header_64.self, capacity: 1)
        callback(path, machHeader, fd, map)
    } else {
        return "Not a Mach-O file"
    }
    
    msync(map, Int(stat.st_size), MS_SYNC)
    munmap(map, Int(stat.st_size))
    close(fd)
    return nil
}



@discardableResult
func replacePatternInFile(at filePath: String, pattern: String, replacement: String) -> Bool {
    // Check if the file exists
    if !FileManager.default.fileExists(atPath: filePath) {
        print("File does not exist at path: \(filePath)")
        return false
    }
    
    do {
        // Read the binary file content as Data
        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        
        // Convert the pattern and replacement strings to Data using UTF-8 encoding
        guard let patternData = pattern.data(using: .utf8),
              let replacementData = replacement.data(using: .utf8) else {
            print("Failed to convert strings to data.")
            return false
        }
        
        // Create a mutable copy of the file data
        var modifiedData = fileData
        
        // Find all occurrences of the pattern
        var currentIndex = 0
        while let range = modifiedData.range(of: patternData, options: [], in: currentIndex..<modifiedData.count) {
            let patternLength = range.upperBound - range.lowerBound
            let replacementLength = replacementData.count
            
            // If the replacement is shorter, pad with zeroes (to maintain the structure like a Mach-O file)
            if replacementLength < patternLength {
                modifiedData.replaceSubrange(range, with: replacementData + Data(repeating: 0, count: patternLength - replacementLength))
            } else {
                // If the replacement is longer, just replace it (you'll need to handle Mach-O specifics here)
                modifiedData.replaceSubrange(range, with: replacementData)
            }
            
            // Move to the next part of the data
            currentIndex = range.upperBound
        }
        
        // Write the modified binary data back to the file
        try modifiedData.write(to: URL(fileURLWithPath: filePath))
        print("File successfully modified.")
        return true
    } catch {
        print("Error reading or writing the file: \(error)")
        return false
    }
}


func patchMachO(path: String) {
    var has64bitSlice = false
    
   //  getSymbols(path)
    
    let error = parseMachO(path: path.cString(using: .utf8)!) { path, header, fd, filePtr in
        if header.pointee.cputype == CPU_TYPE_ARM64 {
            has64bitSlice = true
            patchExecSlice(path: path, header: header, doInject: true)
        }
    }
}


func patchExecSlice(path: UnsafePointer<CChar>, header: UnsafeMutablePointer<mach_header_64>, doInject: Bool) {
    let imageHeaderPtr = UnsafeMutableRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    
    // Literally convert an executable to a dylib
    if header.pointee.magic == MH_MAGIC_64 {
        //assert(header.pointee.flags & MH_PIE != 0)
        header.pointee.filetype = UInt32(MH_DYLIB)
        header.pointee.flags |= UInt32(MH_NO_REEXPORTED_DYLIBS)
        header.pointee.flags &= ~UInt32(MH_PIE)
    }
    
    // Patch __PAGEZERO to map just a single zero page, fixing "out of address space"
    let seg = imageHeaderPtr.bindMemory(to: segment_command_64.self, capacity: 1)
    assert(seg.pointee.cmd == LC_SEGMENT_64 || seg.pointee.cmd == LC_ID_DYLIB)
    
    if seg.pointee.cmd == LC_SEGMENT_64 && seg.pointee.vmaddr == 0 {
        assert(seg.pointee.vmsize == 0x100000000)
        seg.pointee.vmaddr = 0x100000000 - 0x4000
        seg.pointee.vmsize = 0x4000
    }
    
    var hasDylibCommand = false
    var dylibLoaderCommand: UnsafeMutablePointer<dylib_command>? = nil
    let libCppPath = "/usr/lib/libc++.1.dylib"
    
    var command = imageHeaderPtr.bindMemory(to: load_command.self, capacity: 1)
    
    for _ in 0..<header.pointee.ncmds {
        if command.pointee.cmd == LC_ID_DYLIB {
            hasDylibCommand = true
        } else if command.pointee.cmd == 0x114514 {
            dylibLoaderCommand = UnsafeMutablePointer<dylib_command>(OpaquePointer(command))
        }
        
        command = UnsafeMutableRawPointer(command).advanced(by: Int(command.pointee.cmdsize))
            .bindMemory(to: load_command.self, capacity: 1)
    }
    
    // Add LC_LOAD_DYLIB first, since LC_ID_DYLIB will change overall offsets
    if let dylibLoaderCommand = dylibLoaderCommand {
        dylibLoaderCommand.pointee.cmd = doInject ? UInt32(LC_LOAD_DYLIB) : 0x114514
        
        let namePtr = UnsafeMutableRawPointer(dylibLoaderCommand).advanced(by: Int(dylibLoaderCommand.pointee.dylib.name.offset))
        strcpy(namePtr.assumingMemoryBound(to: CChar.self), libCppPath)
    } else {
        insertDylibCommand(cmd: doInject ? UInt32(LC_LOAD_DYLIB) : 0x114514, path: libCppPath, header: header)
    }
    
    if !hasDylibCommand {
        insertDylibCommand(cmd: UInt32(LC_ID_DYLIB), path: path, header: header)
    }
}

func insertDylibCommand(cmd: UInt32, path: UnsafePointer<CChar>, header: UnsafeMutablePointer<mach_header_64>) {
    let name: UnsafePointer<CChar>
    if cmd == LC_ID_DYLIB {
        guard let base = basename(UnsafeMutablePointer(mutating: path)) else {
            return
        }
        name = UnsafePointer(base)
    } else {
        name = path
    }

    let nameLength = strlen(name) + 1
    let cmdSize = MemoryLayout<dylib_command>.size + Int(rnd32(UInt32(nameLength), 8))

    let headerPtr = UnsafeMutableRawPointer(header)
    var dylibPtr: UnsafeMutablePointer<dylib_command>

    if cmd == LC_ID_DYLIB {
        dylibPtr = headerPtr.advanced(by: MemoryLayout<mach_header_64>.size).assumingMemoryBound(to: dylib_command.self)

        // Move existing load commands forward to make space
        let loadCmdsSize = Int(header.pointee.sizeofcmds)
        let src = UnsafeRawPointer(dylibPtr)
        let dst = headerPtr.advanced(by: MemoryLayout<mach_header_64>.size + cmdSize)
        memmove(dst, src, loadCmdsSize)
        memset(dylibPtr, 0, cmdSize)
    } else {
        dylibPtr = headerPtr.advanced(by: MemoryLayout<mach_header_64>.size + Int(header.pointee.sizeofcmds))
            .assumingMemoryBound(to: dylib_command.self)
    }

    dylibPtr.pointee.cmd = cmd
    dylibPtr.pointee.cmdsize = UInt32(cmdSize)
    dylibPtr.pointee.dylib.name.offset = UInt32(MemoryLayout<dylib_command>.size)
    dylibPtr.pointee.dylib.compatibility_version = 0x10000
    dylibPtr.pointee.dylib.current_version = 0x10000
    dylibPtr.pointee.dylib.timestamp = 2

    let nameDst = UnsafeMutableRawPointer(dylibPtr).advanced(by: Int(dylibPtr.pointee.dylib.name.offset))
    strncpy(nameDst.assumingMemoryBound(to: CChar.self), name, nameLength)

    header.pointee.ncmds += 1
    header.pointee.sizeofcmds += UInt32(cmdSize)
}

func rnd32(_ v: UInt32, _ r: UInt32) -> UInt32 {
    let adjustedR = r - 1
    return (v + adjustedR) & ~adjustedR
}

