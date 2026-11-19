#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// Keep the async JavaScript entry point on WebKit's Objective-C API so this
// request does not require the Swift WebKit overlay on older simulator runtimes.
@interface OrbitJarvisScriptRunner : NSObject
+ (void)execute:(NSString *)script
        webView:(WKWebView *)webView
      arguments:(NSDictionary<NSString *, id> *)arguments
     completion:(void (^)(id _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
