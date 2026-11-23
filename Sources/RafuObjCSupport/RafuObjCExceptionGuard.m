#import "RafuObjCSupport.h"

NSErrorDomain const RafuObjCExceptionErrorDomain = @"RafuObjCException";
NSErrorUserInfoKey const RafuObjCExceptionNameKey = @"RafuObjCExceptionName";
NSErrorUserInfoKey const RafuObjCExceptionReasonKey = @"RafuObjCExceptionReason";

@implementation RafuObjCExceptionGuard

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSErrorUserInfoKey, id> *info =
                [NSMutableDictionary dictionaryWithCapacity:3];
            info[RafuObjCExceptionNameKey] = exception.name;
            NSString *reason = exception.reason;
            if (reason != nil) {
                info[RafuObjCExceptionReasonKey] = reason;
            }
            info[NSLocalizedDescriptionKey] = reason ?: exception.name;
            *error = [NSError errorWithDomain:RafuObjCExceptionErrorDomain
                                         code:1
                                     userInfo:info];
        }
        return NO;
    }
}

@end
