#import <Cocoa/Cocoa.h>
#import "SULocalizations.h"
#import "SUErrors.h"
#import "SUInstaller.h"
#import "SUHost.h"
#import "SUStandardVersionComparator.h"
#import "SUStatusController.h"
#import "SULog.h"
#import "SUInstallerProtocol.h"
#import "TerminationListener.h"

#include <unistd.h>
#include <signal.h>

// Upgrade lock file path - used across all lock operations
static NSString * const SUUpgradeLockFilePath = @"/tmp/ai.genspark.lock";

// Static cleanup function for main() usage when AppInstaller is not available
static void staticCleanupAndExit(int exitCode) {
    SULog(SULogLevelDefault, @"staticCleanupAndExit called with code: %d", exitCode);

    // Direct cleanup of lock file since no AppInstaller instance available
    if ([[NSFileManager defaultManager] fileExistsAtPath:SUUpgradeLockFilePath]) {
        if ([[NSFileManager defaultManager] removeItemAtPath:SUUpgradeLockFilePath error:nil]) {
            SULog(SULogLevelDefault, @"Static cleanup of upgrade lock successful");
        } else {
            SULog(SULogLevelError, @"Static cleanup of upgrade lock failed");
        }
    }

    // Call system exit immediately (no complex logging to wait for)
    exit(exitCode);
}

// Simple upgrade lock implementation
@interface SUUpgradeLock : NSObject
- (instancetype)init;
- (BOOL)createLock;
- (BOOL)releaseLock;
- (void)emergencyCleanup;
@end

@interface SUUpgradeLock ()
@property (nonatomic, copy, nullable) NSString *lockFilePath;
@end

@implementation SUUpgradeLock

- (instancetype)init {
    if (!(self = [super init])) {
        return nil;
    }
    return self;
}

- (BOOL)createLock {
    if (self.lockFilePath) {
        return YES;
    }
    
    NSString *lockPath = SUUpgradeLockFilePath;

    if ([[NSFileManager defaultManager] fileExistsAtPath:lockPath]) {
        SULog(SULogLevelDefault, @"Upgrade lock exists, overwriting with current process info");
    }
    
    self.lockFilePath = lockPath;
    
    // URL query format for easier parsing
    NSString *lockContent = [NSString stringWithFormat:@"pid=%d&start_time=%.0f", 
                            getpid(), 
                            [[NSDate date] timeIntervalSince1970]];
    
    if ([lockContent writeToFile:self.lockFilePath
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil]) {
        SULog(SULogLevelDefault, @"Created upgrade lock at path: %@", self.lockFilePath);
        return YES;
    } else {
        SULog(SULogLevelError, @"Failed to create upgrade lock at path: %@", lockPath);
        self.lockFilePath = nil;
        return NO;
    }
}

- (BOOL)releaseLock {
    if (!self.lockFilePath) {
        return YES;
    }
    
    NSError *error = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:self.lockFilePath error:&error]) {
        SULog(SULogLevelDefault, @"Released upgrade lock at path: %@", self.lockFilePath);
        self.lockFilePath = nil;
        return YES;
    } else {
        SULog(SULogLevelError, @"Failed to release upgrade lock at path: %@", self.lockFilePath);
        return NO;
    }
}

- (void)emergencyCleanup {
    if (self.lockFilePath && [[NSFileManager defaultManager] fileExistsAtPath:self.lockFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.lockFilePath error:nil];
        SULog(SULogLevelDefault, @"Emergency cleanup: removed upgrade lock at path: %@", self.lockFilePath);
    }
    self.lockFilePath = nil;
}

@end

/*!
 * If the Installation takes longer than this time the Application Icon is shown in the Dock so that the user has some feedback.
 */
static const NSTimeInterval SUInstallationTimeLimit = 5;

/*!
 * Terminate the application after a delay from launching the new update to avoid OS activation issues
 * This delay should be be high enough to increase the likelihood that our updated app will be launched up front,
 * but should be low enough so that the user doesn't ponder why the updater hasn't finished terminating yet
 */
static const NSTimeInterval SUTerminationTimeDelay = 0.5;

/*! 
 * Additional delay after parent process termination before starting installation
 * This ensures system resources are fully released and helps prevent file replacement failures
 * that can occur during the critical Progress 9/10 installation phase
 */
static const NSTimeInterval SUPreInstallationDelay = 3.0;

@interface AppInstaller : NSObject <NSApplicationDelegate>

/*
 * hostPath - path to host (original) application
 * relaunchPath - path to what the host wants to relaunch (default is same as hostPath)
 * parentProcessId - process identifier of the host before launching us
 * updateFolderPath - path to update folder (i.e, temporary directory containing the new update)
 * shouldRelaunch - indicates if the new installed app should re-launched
 * shouldShowUI - indicates if we should show the status window when installing the update
 */
- (instancetype)initWithHostPath:(NSString *)hostPath relaunchPath:(NSString *)relaunchPath parentProcessId:(pid_t)parentProcessId updateFolderPath:(NSString *)updateFolderPath shouldRelaunch:(BOOL)shouldRelaunch shouldShowUI:(BOOL)shouldShowUI;

@end

@interface AppInstaller ()

@property (nonatomic, strong) TerminationListener *terminationListener;
@property (nonatomic, strong) SUStatusController *statusController;

@property (nonatomic, copy) NSString *updateFolderPath;
@property (nonatomic, copy) NSString *hostPath;
@property (nonatomic, copy) NSString *relaunchPath;
@property (nonatomic, assign) BOOL shouldRelaunch;
@property (nonatomic, assign) BOOL shouldShowUI;

@property (nonatomic, assign) BOOL isTerminating;

@property (nonatomic, strong) SUUpgradeLock *upgradeLock;

- (void)cleanupAndExit:(int)exitCode;

@end

@implementation AppInstaller

@synthesize terminationListener = _terminationListener;
@synthesize statusController = _statusController;
@synthesize updateFolderPath = _updateFolderPath;
@synthesize hostPath = _hostPath;
@synthesize relaunchPath = _relaunchPath;
@synthesize shouldRelaunch = _shouldRelaunch;
@synthesize shouldShowUI = _shouldShowUI;
@synthesize isTerminating = _isTerminating;
@synthesize upgradeLock = _upgradeLock;

- (instancetype)initWithHostPath:(NSString *)hostPath relaunchPath:(NSString *)relaunchPath parentProcessId:(pid_t)parentProcessId updateFolderPath:(NSString *)updateFolderPath shouldRelaunch:(BOOL)shouldRelaunch shouldShowUI:(BOOL)shouldShowUI
{
    if (!(self = [super init])) {
        return nil;
    }
    
    self.hostPath = hostPath;
    self.relaunchPath = relaunchPath;
    SULog(SULogLevelDefault, @"PID to listen: %d", parentProcessId);
    self.terminationListener = [[TerminationListener alloc] initWithProcessIdentifier:@(parentProcessId)];
    self.updateFolderPath = updateFolderPath;
    self.shouldRelaunch = shouldRelaunch;
    self.shouldShowUI = shouldShowUI;
    
    // Create and initialize upgrade lock (best effort, don't block upgrade on failure)
    @try {
        self.upgradeLock = [[SUUpgradeLock alloc] init];
        if (![self.upgradeLock createLock]) {
            SULog(SULogLevelDefault, @"Could not create upgrade lock, continuing without it");
            self.upgradeLock = nil;
        }
    } @catch (NSException *exception) {
        SULog(SULogLevelDefault, @"Exception creating upgrade lock: %@, continuing without it", exception.reason);
        self.upgradeLock = nil;
    }
    
    return self;
}

- (void)cleanupAndExit:(int)exitCode
{
    SULog(SULogLevelDefault, @"cleanupAndExit called with code: %d", exitCode);

    // Cleanup upgrade lock if available
    if (self.upgradeLock) {
        [self.upgradeLock emergencyCleanup];
        SULog(SULogLevelDefault, @"Cleaned up upgrade lock via AppInstaller");
    } else {
        // Fallback: direct cleanup of lock file
        NSString *lockPath = SUUpgradeLockFilePath;
        if ([[NSFileManager defaultManager] fileExistsAtPath:lockPath]) {
            if ([[NSFileManager defaultManager] removeItemAtPath:lockPath error:nil]) {
                SULog(SULogLevelDefault, @"Direct cleanup of upgrade lock successful");
            } else {
                SULog(SULogLevelError, @"Direct cleanup of upgrade lock failed");
            }
        }
    }

    // Delay exit to allow async file logging to complete
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(exitCode);
    });
}

- (void)applicationDidFinishLaunching:(NSNotification __unused *)notification
{
    SULog(SULogLevelDefault, @"Autoupdate process started");
    SULog(SULogLevelDefault, @"Process parameters:");
    SULog(SULogLevelDefault, @"Host path: %@", self.hostPath);
    SULog(SULogLevelDefault, @"Relaunch path: %@", self.relaunchPath);
    SULog(SULogLevelDefault, @"Update folder path: %@", self.updateFolderPath);
    SULog(SULogLevelDefault, @"Should relaunch: %@", self.shouldRelaunch ? @"YES" : @"NO");
    SULog(SULogLevelDefault, @"Should show UI: %@", self.shouldShowUI ? @"YES" : @"NO");

    [self.terminationListener startListeningWithCompletion:^(BOOL terminationSuccess) {
        self.terminationListener = nil;
        
        SULog(SULogLevelDefault, @"Parent process listening completed: %@", terminationSuccess ? @"SUCCESS" : @"FAILED");
        
        if (!terminationSuccess) {
            SULog(SULogLevelError, @"Failed to listen for application termination");
            // Continue on with the installation anyway?
        }

        if (self.shouldShowUI) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUInstallationTimeLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.isTerminating) {
                    // Show app icon in the dock
                    ProcessSerialNumber psn = { 0, kCurrentProcess };
                    TransformProcessType(&psn, kProcessTransformToForegroundApplication);
                }
            });
        }
        
        // Additional delay after parent process termination to ensure system resources are fully released
        SULog(SULogLevelDefault, @"Parent application terminated, waiting additional %.0f seconds before installation...", SUPreInstallationDelay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUPreInstallationDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SULog(SULogLevelDefault, @"Pre-installation wait period completed, starting installation...");
            [self install];
        });
    }];
}

- (void)showError:(NSError *)error
{
    if (self.shouldShowUI) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"";
        alert.informativeText = [NSString stringWithFormat:@"%@", [error localizedDescription]];
        [alert runModal];
    }
}

- (void)install
{
    SULog(SULogLevelDefault, @"Performing installation");
    
    NSBundle *theBundle = [NSBundle bundleWithPath:self.hostPath];
    SUHost *host = [[SUHost alloc] initWithBundle:theBundle];
    
    NSString *fileOperationToolPath = [[[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@""SPARKLE_FILEOP_TOOL_NAME];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileOperationToolPath]) {
        SULog(SULogLevelError, @"Potential installation error: File operation tool path not found: %@", fileOperationToolPath);
    }
    
    NSError *retrieveInstallerError = nil;
    id<SUInstallerProtocol> installer = [SUInstaller installerForHost:host fileOperationToolPath:fileOperationToolPath updateDirectory:self.updateFolderPath error:&retrieveInstallerError];
    if (installer == nil) {
        SULog(SULogLevelError, @"Retrieved installer error: %@", retrieveInstallerError);
        [self cleanupAndExit:EXIT_FAILURE];
    }
    
    SULog(SULogLevelDefault, @"Using installer: %@", NSStringFromClass([installer class]));
    SULog(SULogLevelDefault, @"Installer supports silent install: %@", [installer canInstallSilently] ? @"YES" : @"NO");
    
    if (self.shouldShowUI && [installer canInstallSilently]) {
        self.statusController = [[SUStatusController alloc] initWithHost:host];
        [self.statusController setButtonTitle:SULocalizedString(@"Cancel Update", @"") target:nil action:Nil isDefault:NO];
        [self.statusController beginActionWithTitle:SULocalizedString(@"Installing update...", @"")
                                   maxProgressValue:100 statusText: @""];
        [self.statusController showWindow:self];
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *initialInstallationError = nil;
        if (![installer performInitialInstallation:&initialInstallationError]) {
            SULog(SULogLevelError, @"Failed to perform initial installation: %@", initialInstallationError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:initialInstallationError];
                [self cleanupAndExit:EXIT_FAILURE];
            });
            return;
        }
        
        void(^progressBlock)(double) = ^(double progress){
            dispatch_async(dispatch_get_main_queue(), ^(){
                self.statusController.progressValue = progress * 100.0;
            });
        };

        NSError *finalInstallationError = nil;
        if (![installer performFinalInstallationProgressBlock:progressBlock error:&finalInstallationError]) {
            NSError *underlyingError = [finalInstallationError.userInfo objectForKey:NSUnderlyingErrorKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (underlyingError == nil || underlyingError.code != SUInstallationCancelledError) {
                    SULog(SULogLevelError, @"Failed to perform final installation: %@", finalInstallationError);
                    [self showError:finalInstallationError];
                }
                [self cleanupAndExit:EXIT_FAILURE];
            });
            return;
        }
        
        NSString *installationPath = [installer installationPath];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *pathToRelaunch = nil;
            // If the relaunch path is the same as the host bundle path, use the installation path from the installer which may be normalized
            // Otherwise use the requested relaunch path in all other cases
            if ([self.relaunchPath.pathComponents isEqualToArray:host.bundlePath.pathComponents]) {
                pathToRelaunch = installationPath;
            } else {
                pathToRelaunch = self.relaunchPath;
            }
            [self cleanupAndTerminateWithPathToRelaunch:pathToRelaunch];
        });
    });
}

- (void)cleanupAndTerminateWithPathToRelaunch:(NSString *)relaunchPath
{
    SULog(SULogLevelDefault, @"Starting cleanup and relaunch process");
    SULog(SULogLevelDefault, @"Relaunch path: %@", relaunchPath);
    SULog(SULogLevelDefault, @"Should relaunch: %@", self.shouldRelaunch ? @"YES" : @"NO");
    
    self.isTerminating = YES;
    
    // Release upgrade lock before browser relaunch
    if (self.upgradeLock) {
        if ([self.upgradeLock releaseLock]) {
            SULog(SULogLevelDefault, @"Upgrade lock released successfully");
        } else {
            SULog(SULogLevelError, @"Failed to release upgrade lock");
        }
    }
    
    dispatch_block_t cleanupAndExit = ^{
        NSError *theError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:self.updateFolderPath error:&theError]) {
            SULog(SULogLevelError, @"Could not remove update folder: %@", theError);
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:[[NSBundle mainBundle] bundlePath] error:NULL];
        
        SULog(SULogLevelDefault, @"Autoupdate process will exit");
        [self cleanupAndExit:EXIT_SUCCESS];
    };
    
    if (self.shouldRelaunch) {
        // The auto updater can terminate before the newly updated app is finished launching
        // If that happens, the OS may not make the updated app active and frontmost
        // (Or it does become frontmost, but the OS backgrounds it afterwards.. It's some kind of timing/activation issue that doesn't occur all the time)
        // The only remedy I've been able to find is waiting an arbitrary delay before exiting our application
        
        // Don't use -launchApplication: because we may not be launching an application. Eg: it could be a system prefpane
        SULog(SULogLevelDefault, @"Preparing to launch new app: %@", relaunchPath);
        if (![[NSWorkspace sharedWorkspace] openFile:relaunchPath]) {
            SULog(SULogLevelError, @"Failed to launch: %@", relaunchPath);
        } else {
            SULog(SULogLevelDefault, @"Successfully launched new app");
        }
        
        [self.statusController close];
        
        // Don't even think about hiding the app icon from the dock if we've already shown it
        // Transforming the app back to a background one has a backfiring effect, decreasing the likelihood
        // that the updated app will be brought up front
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUTerminationTimeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            cleanupAndExit();
        });
    } else {
        cleanupAndExit();
    }
}

@end

int main(int __unused argc, const char __unused *argv[])
{
    @autoreleasepool
    {
        NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
        if (args.count < 5 || args.count > 7) {
            staticCleanupAndExit(EXIT_FAILURE);
            return EXIT_FAILURE; // This line won't be reached, but keeps compiler happy
        }
        
        NSApplication *application = [NSApplication sharedApplication];

        BOOL shouldShowUI = (args.count > 6) ? [[args objectAtIndex:6] boolValue] : YES;
        if (shouldShowUI) {
            [application activateIgnoringOtherApps:YES];
        }
        
        AppInstaller *appInstaller = [[AppInstaller alloc] initWithHostPath:[args objectAtIndex:1]
                                                               relaunchPath:[args objectAtIndex:2]
                                                            parentProcessId:[[args objectAtIndex:3] intValue]
                                                           updateFolderPath:[args objectAtIndex:4]
                                                             shouldRelaunch:(args.count > 5) ? [[args objectAtIndex:5] boolValue] : YES
                                                               shouldShowUI:shouldShowUI];

        [application setDelegate:appInstaller];
        [application run];
    }

    return EXIT_SUCCESS;
}
