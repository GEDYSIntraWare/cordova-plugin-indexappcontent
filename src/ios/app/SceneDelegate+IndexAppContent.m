//
//  SceneDelegate+IndexAppContent.m
//
//  Created for cordova-ios@8 Scene API support
//  Handles Spotlight interactions via SceneDelegate instead of AppDelegate
//

#import "SceneDelegate+IndexAppContent.h"
#import <objc/runtime.h>
#import <CoreSpotlight/CoreSpotlight.h>
#import <Cordova/CDV.h>

#define kCALL_DELAY_MILLISECONDS 25

@implementation CDVSceneDelegate (IndexAppContent)

/*
 In cordova-ios@8, the app uses Scene API, so user activities come through SceneDelegate
 instead of AppDelegate. We need to swizzle the SceneDelegate method to handle Spotlight.
 */
+ (void)load {
    NSLog(@"[IndexAppContent] ===== LOADING IndexAppContent Category =====");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swizzle CDVSceneDelegate directly since SceneDelegate inherits from it
        Class targetClass = [CDVSceneDelegate class];
        
        NSLog(@"[IndexAppContent] Using CDVSceneDelegate class: %@", targetClass);

        SEL originalSEL = @selector(scene:continueUserActivity:);
        SEL swizzledSEL = @selector(indexAppContent_scene:continueUserActivity:);
        
        Method originalMethod = class_getInstanceMethod(targetClass, originalSEL);
        Method swizzledMethod = class_getInstanceMethod(targetClass, swizzledSEL);
        
        NSLog(@"[IndexAppContent] Original method on CDVSceneDelegate: %@", 
              originalMethod ? @"FOUND" : @"NOT FOUND");
        NSLog(@"[IndexAppContent] Swizzled method on CDVSceneDelegate: %@", 
              swizzledMethod ? @"FOUND" : @"NOT FOUND");
        
        if (swizzledMethod) {
            if (originalMethod) {
                // Method exists - swizzle it
                method_exchangeImplementations(originalMethod, swizzledMethod);
                NSLog(@"[IndexAppContent] Swizzled scene:continueUserActivity: in CDVSceneDelegate");
            } else {
                // Method doesn't exist - add it
                NSLog(@"[IndexAppContent] Adding scene:continueUserActivity: to CDVSceneDelegate");
                IMP swizzledIMP = method_getImplementation(swizzledMethod);
                const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
                
                BOOL didAdd = class_addMethod(targetClass, originalSEL, swizzledIMP, swizzledTypes);
                if (didAdd) {
                    NSLog(@"[IndexAppContent] Added scene:continueUserActivity: to CDVSceneDelegate");
                } else {
                    NSLog(@"[IndexAppContent]  Failed to add method to CDVSceneDelegate");
                }
            }
            NSLog(@"[IndexAppContent] ===== IndexAppContent Setup COMPLETE =====");
        } else {
            NSLog(@"[IndexAppContent]  ERROR: Swizzled method not found on CDVSceneDelegate");
        }
    });
}

- (void)indexAppContent_scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    NSLog(@"[IndexAppContent] ===== SPOTLIGHT TAP DETECTED =====");
    NSLog(@"[IndexAppContent] 📱 scene:continueUserActivity: called");
    NSLog(@"[IndexAppContent] Activity Type: %@", userActivity.activityType);
    NSLog(@"[IndexAppContent] User Info: %@", userActivity.userInfo);
    
    // Handle Spotlight activity FIRST
    if ([userActivity.activityType isEqualToString:CSSearchableItemActionType]) {
        NSString *identifier = userActivity.userInfo[CSSearchableItemActivityIdentifier];
        NSLog(@"[IndexAppContent] This IS a Spotlight activity!");
        NSLog(@"[IndexAppContent] Spotlight Item Identifier: %@", identifier);
        
        // Get the view controller from the scene
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            NSLog(@"[IndexAppContent] Scene is UIWindowScene");
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UIWindow *window = windowScene.windows.firstObject;
            NSLog(@"[IndexAppContent] Windows count: %lu", (unsigned long)windowScene.windows.count);
            
            if (window && window.rootViewController) {
                NSLog(@"[IndexAppContent] Window and rootViewController found");
                NSLog(@"[IndexAppContent] Root VC class: %@", NSStringFromClass([window.rootViewController class]));
                // Call JavaScript handler
                NSString *jsFunction = @"window.plugins.indexAppContent.onItemPressed";
                NSString *params = [NSString stringWithFormat:@"{'identifier':'%@'}", identifier];
                NSString *command = [NSString stringWithFormat:@"%@(%@)", jsFunction, params];
                
                NSLog(@"[IndexAppContent] Preparing to call JavaScript: %@", command);
                [self callJavascriptFunctionWhenAvailable:command fromWindow:window];
            } else {
                NSLog(@"[IndexAppContent]  ERROR: No window or rootViewController found");
                NSLog(@"[IndexAppContent] Window: %@, RootVC: %@", window, window.rootViewController);
            }
        } else {
            NSLog(@"[IndexAppContent]  ERROR: Scene is not UIWindowScene, it's: %@", NSStringFromClass([scene class]));
        }
        
        // We handled it, don't pass to other plugins
        NSLog(@"[IndexAppContent] ===== END SPOTLIGHT TAP HANDLING (handled by IndexAppContent) =====");
        return;
    } else {
        NSLog(@"[IndexAppContent] Not a Spotlight activity (CSSearchableItemActionType)");
        NSLog(@"[IndexAppContent] Expected: %@", CSSearchableItemActionType);
        NSLog(@"[IndexAppContent] Got: %@", userActivity.activityType);
    }
    
    // Not our activity type - call through to any other swizzled implementations
    // Due to method swizzling, this actually calls what was the "original" implementation
    NSLog(@"[IndexAppContent] Passing to other handlers (calling swizzled method)...");
    [self indexAppContent_scene:scene continueUserActivity:userActivity];
    
    NSLog(@"[IndexAppContent] ===== END SPOTLIGHT TAP HANDLING (passed to other handler) =====");
}

- (void)callJavascriptFunctionWhenAvailable:(NSString *)function fromWindow:(UIWindow *)window {
    NSLog(@"[IndexAppContent] >> Starting JavaScript call sequence");
    __block NSString *command = function;
    __weak UIWindow *weakWindow = window;
    __block int retryCount = 0;
    
    __block void (^checkAndExecute)(void) = ^void(void) {
        retryCount++;
        NSLog(@"[IndexAppContent] Attempt #%d to execute JavaScript", retryCount);
        
        UIWindow *strongWindow = weakWindow;
        if (!strongWindow) {
            NSLog(@"[IndexAppContent] Window deallocated");
            return;
        }
        
        // Get the Cordova view controller
        UIViewController *rootVC = strongWindow.rootViewController;
        if (![rootVC isKindOfClass:[CDVViewController class]]) {
            NSLog(@"[IndexAppContent] Root VC is not CDVViewController: %@", NSStringFromClass([rootVC class]));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCALL_DELAY_MILLISECONDS * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
            return;
        }
        
        NSLog(@"[IndexAppContent] CDVViewController found");
        CDVViewController *cordovaVC = (CDVViewController *)rootVC;
        id<CDVWebViewEngineProtocol> webViewEngine = cordovaVC.webViewEngine;
        
        if (!webViewEngine) {
            NSLog(@"[IndexAppContent] WebViewEngine not available yet");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCALL_DELAY_MILLISECONDS * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
            return;
        }
        
        NSLog(@"[IndexAppContent] WebViewEngine available");
        // Check if JavaScript is ready
        NSString *check = @"(window && window.plugins && window.plugins.indexAppContent && typeof window.plugins.indexAppContent.onItemPressed == 'function') ? true : false";
        
        [webViewEngine evaluateJavaScript:check completionHandler:^(id result, NSError *error) {
            if (error || [result boolValue] == NO) {
                NSLog(@"[IndexAppContent] JavaScript not ready (attempt #%d), retrying...", retryCount);
                if (error) {
                    NSLog(@"[IndexAppContent] Error: %@", error);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCALL_DELAY_MILLISECONDS * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
            } else {
                NSLog(@"[IndexAppContent] JavaScript ready after %d attempts!", retryCount);
                NSLog(@"[IndexAppContent] Executing: %@", command);
                [webViewEngine evaluateJavaScript:command completionHandler:^(id _Nullable result, NSError * _Nullable error) {
                    if (error) {
                        NSLog(@"[IndexAppContent] Error executing JavaScript: %@", error);
                    } else {
                        NSLog(@"[IndexAppContent] Successfully executed JavaScript");
                        NSLog(@"[IndexAppContent] Result: %@", result);
                    }
                }];
            }
        }];
    };
    
    // Start the check after a small delay
    NSLog(@"[IndexAppContent] Scheduling first JavaScript check in 100ms...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
}

@end

