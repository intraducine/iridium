#import "JITExtension.h"
#import <objc/message.h>
#import <Security/Security.h>

extern CFTypeRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(CFTypeRef task, CFStringRef name, CFErrorRef *error);
BOOL IRHasDebugEntitlement(void) {
    CFTypeRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), NULL);
    BOOL allowed = value && CFEqual(value, kCFBooleanTrue);
    if (value) CFRelease(value);
    CFRelease(task);
    return allowed;
}

// Private NSExtension entry points, also used by the DolphiniOS StikJIT proposal.
// The helper allows only NSXPCListenerEndpoint in addition to Apple's normal decoder rules.
@interface NSObject (IRJITPrivateExtension)
+ (id)extensionWithIdentifier:(NSString *)identifier excludingDisabledExtensions:(BOOL)exclude error:(NSError **)error;
- (id)beginExtensionRequestWithInputItems:(NSArray *)items error:(NSError **)error;
- (pid_t)pidForRequestIdentifier:(NSUUID *)request;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)request;
@end

@interface JITExtension () <NSXPCListenerDelegate>
@property NSXPCListener *listener;
@property NSXPCConnection *connection;
@property id extension;
@property NSUUID *request;
@property id host;
@property Protocol *hostProtocol;
@property Protocol *workerProtocol;
@property(copy) void (^completion)(id, NSError *);
@property pid_t helperPID;
@end

@implementation JITExtension
- (void)fail:(NSString *)message {
    if (!self.completion) return;
    void (^callback)(id, NSError *) = self.completion;
    self.completion = nil;
    callback(nil, [NSError errorWithDomain:@"Iridium.BuiltinJIT" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}]);
}
- (void)startWithHost:(id)host hostProtocol:(Protocol *)hostProtocol
      workerProtocol:(Protocol *)workerProtocol completion:(void (^)(id, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Start the helper on the main thread");
    self.host = host;
    self.hostProtocol = hostProtocol;
    self.workerProtocol = workerProtocol;
    self.completion = completion;
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"IridiumJITHelper.appex"];
    NSString *identifier = [NSBundle bundleWithURL:url].bundleIdentifier;
    Class cls = NSClassFromString(@"NSExtension");
    if (!identifier || ![cls respondsToSelector:@selector(extensionWithIdentifier:excludingDisabledExtensions:error:)]) {
        [self fail:@"The built-in JIT helper is missing or unavailable on this iOS version."]; return;
    }
    NSError *error = nil;
    self.extension = [cls extensionWithIdentifier:identifier excludingDisabledExtensions:NO error:&error];
    if (!self.extension || ![self.extension respondsToSelector:@selector(beginExtensionRequestWithInputItems:error:)] ||
        ![self.extension respondsToSelector:@selector(pidForRequestIdentifier:)]) {
        [self fail:@"iOS could not load the JIT extension. Check this installation's signing."]; return;
    }
    self.listener = [NSXPCListener anonymousListener];
    self.listener.delegate = self;
    [self.listener resume];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{@"IridiumJITEndpoint": self.listener.endpoint};
    self.request = [self.extension beginExtensionRequestWithInputItems:@[item] error:&error];
    if (!self.request) {
        // Domain/code are diagnostic identifiers, never pairing data or raw userInfo.
        NSMutableArray *causes = [NSMutableArray array];
        for (NSError *cause = error; cause && causes.count < 4; cause = cause.userInfo[NSUnderlyingErrorKey]) {
            [causes addObject:[NSString stringWithFormat:@"%@ (%ld)", cause.domain, (long)cause.code]];
        }
        [self fail:[NSString stringWithFormat:@"iOS refused to start the JIT helper. %@", causes.count ? [causes componentsJoinedByString:@" → "] : @"No system error was provided."]];
        return;
    }
    self.helperPID = [self.extension pidForRequestIdentifier:self.request];
    __weak JITExtension *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf fail:@"The JIT helper did not connect. Check extension signing and restart Iridium."];
    });
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.completion || self.connection || self.helperPID <= 0 || connection.processIdentifier != self.helperPID) {
            [connection invalidate]; return;
        }
        self.connection = connection;
        connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:self.hostProtocol];
        connection.exportedObject = self.host;
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:self.workerProtocol];
        __weak JITExtension *weakSelf = self;
        void (^lost)(void) = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.failureHandler) weakSelf.failureHandler(@"The JIT helper connection ended. Restart Iridium before retrying.");
            });
        };
        connection.interruptionHandler = lost;
        connection.invalidationHandler = lost;
        [connection resume];
        id worker = [connection remoteObjectProxy];
        void (^callback)(id, NSError *) = self.completion;
        self.completion = nil;
        callback(worker, nil);
    });
    return YES;
}
- (void)invalidate {
    self.completion = nil;
    [self.connection invalidate]; self.connection = nil;
    [self.listener invalidate]; self.listener = nil;
    if (self.request && [self.extension respondsToSelector:@selector(cancelExtensionRequestWithIdentifier:)])
        [self.extension cancelExtensionRequestWithIdentifier:self.request];
    self.request = nil; self.extension = nil; self.host = nil;
}
@end
