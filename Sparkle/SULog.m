//
//  SULog.m
//  Sparkle
//
//  Created by Mayur Pawashe on 5/18/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#include "SULog.h"

#include <asl.h>
#include <Availability.h>

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101200
#include <os/log.h>
#else

typedef struct os_log_s *os_log_t;
#define os_log_create(subsystem, category) nil

#define os_log(log, format, ...)
#define os_log_error(log, format, ...)

#endif

#include "AppKitPrevention.h"
#import "SUOperatingSystem.h"

// For converting constants to string literals using the preprocessor
#define STRINGIFY(x) #x
#define TO_STRING(x) STRINGIFY(x)

// File logging macro control
#ifndef SPARKLE_FILE_LOGGING
#define SPARKLE_FILE_LOGGING 1  // Default enabled, set to 0 to disable
#endif

#if SPARKLE_FILE_LOGGING
// File logging helper function declaration
static void SUWriteToLogFile(NSString *message, SULogLevel level);
#endif // SPARKLE_FILE_LOGGING


void SULog(SULogLevel level, NSString *format, ...)
{
    static aslclient client;
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;

    static os_log_t logger;
    static BOOL hasOSLogging;

    dispatch_once(&onceToken, ^{
        NSBundle *mainBundle = [NSBundle mainBundle];

        hasOSLogging = [SUOperatingSystem isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10, 12, 0}];
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101200
        hasOSLogging = NO;
#endif

        if (hasOSLogging) {
            const char *subsystem = SPARKLE_BUNDLE_IDENTIFIER;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
            // This creates a thread-safe object
            logger = os_log_create(subsystem, "Sparkle");
#pragma clang diagnostic pop
        } else {
            uint32_t options = ASL_OPT_NO_DELAY;
            // Act the same way os_log() does; don't log to stderr if a terminal device is attached
            if (!isatty(STDERR_FILENO)) {
                options |= ASL_OPT_STDERR;
            }

            NSString *displayName = [[NSFileManager defaultManager] displayNameAtPath:mainBundle.bundlePath];
            client = asl_open([displayName stringByAppendingString:@" [Sparkle " TO_STRING(SPARKLE_VERSION) "]"].UTF8String, SPARKLE_BUNDLE_IDENTIFIER, options);
            queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
        }
    });

    if (!hasOSLogging && client == NULL) {
        return;
    }

    va_list ap;
    va_start(ap, format);
    NSString *logMessage = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    // Add file logging when macro enabled
#if SPARKLE_FILE_LOGGING
    SUWriteToLogFile(logMessage, level);
#endif

    // Use os_log if available (on 10.12+)
    if (hasOSLogging) {
        // We'll make all of our messages formatted as public; just don't log sensitive information.
        // Note we don't take advantage of info like the source line number because we wrap this macro inside our own function
        // And we don't really leverage of os_log's deferred formatting processing because we format the string before passing it in
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
        switch (level) {
            case SULogLevelDefault:
                // See docs for OS_LOG_TYPE_DEFAULT
                // By default, OS_LOG_TYPE_DEFAULT seems to be more noticable than OS_LOG_TYPE_INFO
                os_log(logger, "%{public}@", logMessage);
                break;
            case SULogLevelError:
                // See docs for OS_LOG_TYPE_ERROR
                os_log_error(logger, "%{public}@", logMessage);
                break;
        }
#pragma clang diagnostic pop
        return;
    }

    // Otherwise use ASL
    // Make sure we do not async, because if we async, the log may not be delivered deterministically
    dispatch_sync(queue, ^{
        aslmsg message = asl_new(ASL_TYPE_MSG);
        if (message == NULL) {
            return;
        }

        if (asl_set(message, ASL_KEY_MSG, logMessage.UTF8String) != 0) {
            return;
        }
        
        int levelSetResult;
        switch (level) {
            case SULogLevelDefault:
                // Just use one level below the error level
                levelSetResult = asl_set(message, ASL_KEY_LEVEL, TO_STRING(ASL_LEVEL_WARNING));
                break;
            case SULogLevelError:
                levelSetResult = asl_set(message, ASL_KEY_LEVEL, TO_STRING(ASL_LEVEL_ERR));
                break;
        }
        if (levelSetResult != 0) {
            return;
        }
        
        asl_send(client, message);
    });
}

#if SPARKLE_FILE_LOGGING
// File logging helper function
static void SUWriteToLogFile(NSString *message, SULogLevel level) {
    static NSString *logFilePath = nil;
    static dispatch_queue_t fileQueue = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        // Try write paths in priority order
        NSArray *candidatePaths = @[
            @"/tmp/sparkle_debug.log",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"sparkle_debug.log"]
        ];
        
        // Test which path is writable - format with timestamp and PID like other log entries
        NSDateFormatter *initFormatter = [[NSDateFormatter alloc] init];
        [initFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *initTime = [initFormatter stringFromDate:[NSDate date]];
        NSString *testContent = [NSString stringWithFormat:@"%@ INFO  [PID:%d] Sparkle log init\n",
                                initTime, getpid()];
        for (NSString *testPath in candidatePaths) {
            NSFileHandle *testHandle = [NSFileHandle fileHandleForWritingAtPath:testPath];
            if (testHandle) {
                // Test actual write capability
                [testHandle seekToEndOfFile];
                [testHandle writeData:[testContent dataUsingEncoding:NSUTF8StringEncoding]];
                [testHandle closeFile];
                logFilePath = [testPath copy];
                break;
            } else {
                // File not exist, try to create and write
                if ([testContent writeToFile:testPath atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
                    logFilePath = [testPath copy];
                    break;
                }
            }
        }
        
        if (logFilePath) {
            fileQueue = dispatch_queue_create("sparkle.file.log", DISPATCH_QUEUE_SERIAL);
        }
    });
    
    // Silent return if no available path
    if (!logFilePath || !fileQueue) {
        return;
    }
    
    // Async file write
    dispatch_async(fileQueue, ^{
        @try {
            // Optimized log formatting
            static NSDateFormatter *dateFormatter = nil;
            static dispatch_once_t formatterToken;
            dispatch_once(&formatterToken, ^{
                dateFormatter = [[NSDateFormatter alloc] init];
                [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
            });
            
            NSString *formattedDate = [dateFormatter stringFromDate:[NSDate date]];
            NSString *levelStr = (level == SULogLevelError) ? @"ERROR" : @"INFO ";

            // Format: datetime level [PID:xxxxx] message
            NSString *timestampedMessage = [NSString stringWithFormat:@"%@ %@ [PID:%d] %@\n",
                                           formattedDate, levelStr, getpid(), message];
            
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
            if (fileHandle) {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:[timestampedMessage dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle synchronizeFile];
                [fileHandle closeFile];
            } else {
                // File not exist, write directly
                [timestampedMessage writeToFile:logFilePath 
                                     atomically:NO 
                                       encoding:NSUTF8StringEncoding 
                                          error:nil];
            }
        } @catch (NSException *exception) {
            // Silent exception handling
        }
    });
}
#endif // SPARKLE_FILE_LOGGING
