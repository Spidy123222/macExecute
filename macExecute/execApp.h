//
//  execApp.h
//  macExecute
//
//  Created by Stossy11 on 22/04/2025.
//

#ifndef MACHO_EXECUTOR_H
#define MACHO_EXECUTOR_H

#define PLATFORM_MACOS        1
#define PLATFORM_IOS          2
#define PLATFORM_TVOS         3
#define PLATFORM_WATCHOS      4
#define PLATFORM_BRIDGEOS     5
#define PLATFORM_MACCATALYST  6
#define PLATFORM_IOSSIMULATOR 7
#define PLATFORM_TVOSSIMULATOR 8
#define PLATFORM_WATCHOSSIMULATOR 9
#define PLATFORM_DRIVERKIT    10

#define MH_EXECUTE 0x2
#define MH_DYLIB   0x6

#include <stddef.h>
#import <Foundation/Foundation.h>

typedef void (^LCParseMachOCallback)(const char *path, struct mach_header_64 *header, int fd, void* filePtr);

NSString *LCParseMachO(const char *path, LCParseMachOCallback callback);

void LCPatchExecSlice(const
                      char *path, struct mach_header_64 *header, bool doInject);

uint32_t rnd32(uint32_t v, uint32_t r);

void patchMachO(NSString *path);

static void insertDylibCommand(uint32_t cmd, const char *path, struct mach_header_64 *header);

#endif /* MACHO_EXECUTOR_H */
