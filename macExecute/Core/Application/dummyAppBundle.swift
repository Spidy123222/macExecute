//
//  dummyAppBundle.swift
//  macExecute
//
//  Created by Stossy11 on 24/04/2025.
//

import Foundation

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

