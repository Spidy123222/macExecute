//
//  patchOperatingSystem.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Darwin
import Foundation
import MachO

func patchExecutable(origPath: String, targetPlatform: UInt32) -> String? {
    let tempDirectory = URL.documentsDirectory.path
    let tempPath = (tempDirectory as NSString).appendingPathComponent("patched_exec.dylib")

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

    guard let fileData = mmap(nil, Int(stat.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) else {
        NSLog("Failed to mmap file: \(String(cString: strerror(errno)))")
        return nil
    }
    defer { munmap(fileData, Int(stat.st_size)) }

    let magic = fileData.load(as: UInt32.self)
    var foundAny = false

    if magic == FAT_MAGIC || magic == FAT_CIGAM {
        let fatHeader = fileData.load(as: fat_header.self)
        let nfatArch = Int(UInt32(bigEndian: fatHeader.nfat_arch))

        for i in 0..<nfatArch {
            let archPtr = fileData.advanced(by: MemoryLayout<fat_header>.size + i * MemoryLayout<fat_arch>.size)
            let arch = archPtr.load(as: fat_arch.self)
            let offset = Int(UInt32(bigEndian: arch.offset))

            guard let patched = patchMachOSlice(fileData.advanced(by: offset), targetPlatform: targetPlatform) else {
                NSLog("Failed to patch slice at offset \(offset)")
                continue
            }

            foundAny = foundAny || patched
        }

        if !foundAny {
            NSLog("No LC_BUILD_VERSION found in any slice")
        }
    } else if magic == MH_MAGIC_64 {
        if let patched = patchMachOSlice(fileData, targetPlatform: targetPlatform) {
            foundAny = patched
        }
    } else {
        NSLog("Unsupported Mach-O magic: \(String(format: "%08x", magic))")
        return nil
    }

    msync(fileData, Int(stat.st_size), MS_SYNC)

    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        return tempPath
    } catch {
        NSLog("Failed to set permissions: \(error)")
        return nil
    }
}

private func patchMachOSlice(_ slicePtr: UnsafeRawPointer, targetPlatform: UInt32) -> Bool? {
    let header = slicePtr.assumingMemoryBound(to: mach_header_64.self)
    if header.pointee.magic != MH_MAGIC_64 {
        return nil
    }

    var cmdPtr = slicePtr.advanced(by: MemoryLayout<mach_header_64>.size)
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

    return platformFound
}
