#import "OrbitJarvisScriptRunner.h"

@implementation OrbitJarvisScriptRunner
+ (void)execute:(NSString *)script
        webView:(WKWebView *)webView
      arguments:(NSDictionary<NSString *, id> *)arguments
     completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [webView callAsyncJavaScript:script
                     arguments:arguments
                       inFrame:nil
                inContentWorld:WKContentWorld.pageWorld
             completionHandler:completion];
}
@end
