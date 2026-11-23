#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain of an NSException caught by `RafuObjCExceptionGuard`.
FOUNDATION_EXPORT NSErrorDomain const RafuObjCExceptionErrorDomain;

/// The user-info keys that carry the caught exception's name and reason.
FOUNDATION_EXPORT NSErrorUserInfoKey const RafuObjCExceptionNameKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const RafuObjCExceptionReasonKey;

/// Runs one Objective-C call and turns an NSException it raises into an
/// NSError. Swift cannot catch an NSException; without this guard it aborts
/// the whole app. Rule: each guarded block holds one Objective-C call and no
/// other Swift work. The guard does not log.
@interface RafuObjCExceptionGuard : NSObject

/// Swift: `try RafuObjCExceptionGuard.perform { ... }`.
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
