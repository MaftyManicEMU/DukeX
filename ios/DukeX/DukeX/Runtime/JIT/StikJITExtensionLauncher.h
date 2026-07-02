#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// XPC contract between the DukeX app (host) and the StikJIT runner extension.
// The Swift side of the extension declares matching @objc protocols in
// StikJIT/StikJIT.swift; the two declarations live in separate processes and are
// kept compatible by matching selector names, not a shared type.

@protocol StikJITRunnerXPCProtocol
- (void)enableJITForParentPID:(int32_t)pid
                  pairingData:(NSData *)pairingData
             scriptIdentifier:(NSString *)scriptIdentifier;
@end

@protocol StikJITHostXPCProtocol
- (void)jitLog:(NSString *)line;
- (void)jitFinished:(BOOL)ok error:(nullable NSString *)error;
@end

// Launches the embedded StikJIT runner .appex as its own process via the private
// NSExtension API and wires up a bidirectional anonymous XPC connection. This
// replaces the ExtensionKit AppExtensionPoint flow, which requires an
// app-scoped extension-point entitlement that cannot be provisioned normally.
@interface StikJITExtensionLauncher : NSObject

- (instancetype)initWithHost:(id<StikJITHostXPCProtocol>)host;

- (void)launchWithCompletion:(void (^)(int32_t pid,
                                       id<StikJITRunnerXPCProtocol> _Nullable runner,
                                       NSError *_Nullable error))completion;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
