#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL IRHasDebugEntitlement(void);
@interface JITExtension : NSObject
@property(copy, nullable) void (^failureHandler)(NSString *message);
- (void)startWithHost:(id)host
       hostProtocol:(Protocol *)hostProtocol
     workerProtocol:(Protocol *)workerProtocol
         completion:(void (^)(id _Nullable worker, NSError * _Nullable error))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
