//
//  execApp.c
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include "execApp.h"

@import Darwin;
@import Foundation;
@import MachO;

typedef void (^LCParseMachOCallback)(const char *path, struct mach_header_64 *header, int fd, void* filePtr);

NSString *LCParseMachO(const char *path, LCParseMachOCallback callback) {
    int fd = open(path, O_RDWR, (mode_t)0600);
    struct stat s;
    fstat(fd, &s);
    void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
    }

    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM) {
        // Find compatible slice
        struct fat_header *header = (struct fat_header *)map;
        struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
        for (int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            if (OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64) {
                callback(path, (struct mach_header_64 *)(map + OSSwapInt32(arch->offset)), fd, map);
            }
            arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        callback(path, (struct mach_header_64 *)map, fd, map);
    } else {
        return @"Not a Mach-O file";
    }

    msync(map, s.st_size, MS_SYNC);
    munmap(map, s.st_size);
    close(fd);
    return nil;
}


void patchMachO(NSString *path) {
    __block bool has64bitSlice = NO;
    NSString *error = LCParseMachO(path.UTF8String, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
        if(header->cputype == CPU_TYPE_ARM64) {
            has64bitSlice |= YES;
            LCPatchExecSlice(path, header, true);
        }
    });
}

void LCPatchExecSlice(const
                      char *path, struct mach_header_64 *header, bool doInject) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);

    // Literally convert an executable to a dylib
    if (header->magic == MH_MAGIC_64) {
        //assert(header->flags & MH_PIE);
        header->filetype = MH_DYLIB;
        header->flags |= MH_NO_REEXPORTED_DYLIBS;
        header->flags &= ~MH_PIE;
    }

    // Patch __PAGEZERO to map just a single zero page, fixing "out of address space"
    struct segment_command_64 *seg = (struct segment_command_64 *)imageHeaderPtr;
    assert(seg->cmd == LC_SEGMENT_64 || seg->cmd == LC_ID_DYLIB);
    if (seg->cmd == LC_SEGMENT_64 && seg->vmaddr == 0) {
        assert(seg->vmsize == 0x100000000);
        seg->vmaddr = 0x100000000 - 0x4000;
        seg->vmsize = 0x4000;
    }

    BOOL hasDylibCommand = NO;
    struct dylib_command * dylibLoaderCommand = 0;
    const char *libCppPath = "/usr/lib/libc++.1.dylib";
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_ID_DYLIB) {
            hasDylibCommand = YES;
        } else if(command->cmd == 0x114514) {
            dylibLoaderCommand = (struct dylib_command *)command;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }

    // Add LC_LOAD_DYLIB first, since LC_ID_DYLIB will change overall offsets
    if (dylibLoaderCommand) {
        dylibLoaderCommand->cmd = doInject ? LC_LOAD_DYLIB : 0x114514;
        strcpy((void *)dylibLoaderCommand + dylibLoaderCommand->dylib.name.offset, libCppPath);
    } else {
        insertDylibCommand(doInject ? LC_LOAD_DYLIB : 0x114514, libCppPath, header);
    }
    if (!hasDylibCommand) {
        insertDylibCommand(LC_ID_DYLIB, path, header);
    }
}

static void insertDylibCommand(uint32_t cmd, const char *path, struct mach_header_64 *header) {
    const char *name = cmd== LC_ID_DYLIB ? basename((char *)path) : path;
    struct dylib_command *dylib;
    size_t cmdsize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(name) + 1, 8);
    if (cmd == LC_ID_DYLIB) {
        // Make this the first load command on the list (like dylibify does), or some UE3 games may break
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (uintptr_t)header);
        memmove((void *)((uintptr_t)dylib + cmdsize), (void *)dylib, header->sizeofcmds);
        bzero(dylib, cmdsize);
    } else {
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (void *)header+header->sizeofcmds);
    }
    dylib->cmd = cmd;
    dylib->cmdsize = cmdsize;
    dylib->dylib.name.offset = sizeof(struct dylib_command);
    dylib->dylib.compatibility_version = 0x10000;
    dylib->dylib.current_version = 0x10000;
    dylib->dylib.timestamp = 2;
    strncpy((void *)dylib + dylib->dylib.name.offset, name, strlen(name));
    header->ncmds++;
    header->sizeofcmds += dylib->cmdsize;
}


uint32_t rnd32(uint32_t v, uint32_t r) {
    r--;
    return (v + r) & ~r;
}
