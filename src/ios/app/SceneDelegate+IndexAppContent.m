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

/**
 *  NSUserDefaults key used to persist a Spotlight identifier across a cold launch.
 *  Written here (scene:willConnectToSession:options:) and consumed by
 *  IndexAppContent.pluginInitialize once the WebView is ready.
 */
static NSString *const kIACTmpIdentifier = @"IACTmpIdentifier";

/**
 *  Tracks whether scene:continueUserActivity: was swizzled (exchange) vs. added.
 *  When added (not swizzled), the fallback call must be skipped to avoid infinite recursion.
 */
static BOOL sContinueUserActivityWasSwizzled = NO;

/**
 *  Tracks whether scene:willConnectToSession:options: was swizzled (exchange) vs. added.
 *  When added (not swizzled), the fallback call must be skipped to avoid infinite recursion.
 */
static BOOL sWillConnectWasSwizzled = NO;

@implementation CDVSceneDelegate (IndexAppContent)

/*
 In cordova-ios@8, the app uses Scene API, so user activities come through SceneDelegate
 instead of AppDelegate. We need to swizzle the SceneDelegate methods to handle Spotlight.

 Two methods are swizzled:
 1. scene:willConnectToSession:options: — called on COLD LAUNCH; the Spotlight activity
    is available in connectionOptions.userActivities. We save the identifier to NSUserDefaults
    here because the Cordova WebView is not ready yet.
 2. scene:continueUserActivity: — called when the app is already running (foreground/background).
    We dispatch the identifier directly via JavaScript once the WebView is ready.
 */
+ (void)load {
    NSLog(@"[IndexAppContent] ===== LOADING IndexAppContent Category =====");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swizzle CDVSceneDelegate directly since SceneDelegate inherits from it
        Class targetClass = [CDVSceneDelegate class];
        
        NSLog(@"[IndexAppContent] Using CDVSceneDelegate class: %@", targetClass);

        // ── Swizzle 1: scene:continueUserActivity: (app already running) ──────────────────────
        {
            SEL originalSEL = @selector(scene:continueUserActivity:);
            SEL swizzledSEL = @selector(indexAppContent_scene:continueUserActivity:);

            Method originalMethod = class_getInstanceMethod(targetClass, originalSEL);
            Method swizzledMethod = class_getInstanceMethod(targetClass, swizzledSEL);

            NSLog(@"[IndexAppContent] continueUserActivity — Original: %@, Swizzled: %@",
                  originalMethod ? @"FOUND" : @"NOT FOUND",
                  swizzledMethod ? @"FOUND" : @"NOT FOUND");

            if (swizzledMethod) {
                if (originalMethod) {
                    method_exchangeImplementations(originalMethod, swizzledMethod);
                    sContinueUserActivityWasSwizzled = YES;
                    NSLog(@"[IndexAppContent] Swizzled scene:continueUserActivity: in CDVSceneDelegate");
                } else {
                    IMP swizzledIMP = method_getImplementation(swizzledMethod);
                    const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
                    BOOL didAdd = class_addMethod(targetClass, originalSEL, swizzledIMP, swizzledTypes);
                    // sContinueUserActivityWasSwizzled stays NO — fallback call must be skipped
                    NSLog(@"[IndexAppContent] Added scene:continueUserActivity: to CDVSceneDelegate: %@",
                          didAdd ? @"SUCCESS" : @"FAILED");
                }
            } else {
                NSLog(@"[IndexAppContent] ERROR: indexAppContent_scene:continueUserActivity: not found");
            }
        }

        // ── Swizzle 2: scene:willConnectToSession:options: (cold launch) ─────────────────────
        {
            SEL originalSEL = @selector(scene:willConnectToSession:options:);
            SEL swizzledSEL = @selector(indexAppContent_scene:willConnectToSession:options:);

            Method originalMethod = class_getInstanceMethod(targetClass, originalSEL);
            Method swizzledMethod = class_getInstanceMethod(targetClass, swizzledSEL);

            NSLog(@"[IndexAppContent] willConnectToSession — Original: %@, Swizzled: %@",
                  originalMethod ? @"FOUND" : @"NOT FOUND",
                  swizzledMethod ? @"FOUND" : @"NOT FOUND");

            if (swizzledMethod) {
                if (originalMethod) {
                    method_exchangeImplementations(originalMethod, swizzledMethod);
                    sWillConnectWasSwizzled = YES;
                    NSLog(@"[IndexAppContent] Swizzled scene:willConnectToSession:options: in CDVSceneDelegate");
                } else {
                    IMP swizzledIMP = method_getImplementation(swizzledMethod);
                    const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
                    BOOL didAdd = class_addMethod(targetClass, originalSEL, swizzledIMP, swizzledTypes);
                    // sWillConnectWasSwizzled stays NO — fallback call must be skipped
                    NSLog(@"[IndexAppContent] Added scene:willConnectToSession:options: to CDVSceneDelegate: %@",
                          didAdd ? @"SUCCESS" : @"FAILED");
                }
            } else {
                NSLog(@"[IndexAppContent] ERROR: indexAppContent_scene:willConnectToSession:options: not found");
            }
        }

        NSLog(@"[IndexAppContent] ===== IndexAppContent Setup COMPLETE =====");
    });
}

// ── Handler: cold launch via scene:willConnectToSession:options: ──────────────────────────────
//
// On cold launch, iOS delivers the Spotlight activity through connectionOptions.userActivities.
// The Cordova WebView is NOT ready at this point, so we cannot call JavaScript.
// Instead, we save the identifier to NSUserDefaults. IndexAppContent.pluginInitialize will
// read it later once the WebView has finished loading.
//
- (void)indexAppContent_scene:(UIScene *)scene
        willConnectToSession:(UISceneSession *)session
                      options:(UISceneConnectionOptions *)connectionOptions {

    NSLog(@"[IndexAppContent] ===== scene:willConnectToSession:options: called (cold launch check) =====");

    // Check connectionOptions.userActivities for a Spotlight tap
    for (NSUserActivity *activity in connectionOptions.userActivities) {
        NSLog(@"[IndexAppContent] Cold launch activity type: %@", activity.activityType);
        if ([activity.activityType isEqualToString:CSSearchableItemActionType]) {
            NSString *identifier = activity.userInfo[CSSearchableItemActivityIdentifier];
            // iOS/macOS may return the identifier in NFD (decomposed) Unicode form,
            // e.g. U+0055 U+0308 instead of the precomposed U+00DC (Ü).
            // The GI server stores and expects NFC (precomposed) form, so normalise here.
            identifier = [identifier precomposedStringWithCanonicalMapping];
            NSLog(@"[IndexAppContent] Cold launch Spotlight identifier found: %@", identifier);
            // Save identifier to NSUserDefaults so pluginInitialize can pick it up once the WebView is ready
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:identifier forKey:kIACTmpIdentifier];
            [defaults synchronize];
            NSLog(@"[IndexAppContent] Cold launch identifier saved to NSUserDefaults");
            break;
        }
    }

    // Always call through to the original implementation so Cordova can set up the WebView.
    // Guard against infinite recursion: only call through if the method was swizzled (exchanged),
    // not merely added. When added, this selector IS our implementation — calling it recurses.
    if (sWillConnectWasSwizzled) {
        NSLog(@"[IndexAppContent] Calling original scene:willConnectToSession:options:");
        [self indexAppContent_scene:scene willConnectToSession:session options:connectionOptions];
    } else {
        NSLog(@"[IndexAppContent] scene:willConnectToSession:options: was added (not swizzled) — skipping fallback to avoid recursion");
    }

    NSLog(@"[IndexAppContent] ===== END scene:willConnectToSession:options: =====");
}

// ── Handler: app already running via scene:continueUserActivity: ──────────────────────────────
//
// Called when the app is in the foreground or background and the user taps a Spotlight result.
// The Cordova WebView is ready, so we can call JavaScript directly (with polling until ready).
//
- (void)indexAppContent_scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    NSLog(@"[IndexAppContent] ===== SPOTLIGHT TAP DETECTED =====");
    NSLog(@"[IndexAppContent] scene:continueUserActivity: called");
    NSLog(@"[IndexAppContent] Activity Type: %@", userActivity.activityType);
    NSLog(@"[IndexAppContent] User Info: %@", userActivity.userInfo);
    
    // Handle Spotlight activity FIRST
    if ([userActivity.activityType isEqualToString:CSSearchableItemActionType]) {
        NSString *identifier = userActivity.userInfo[CSSearchableItemActivityIdentifier];
        // iOS/macOS may return the identifier in NFD (decomposed) Unicode form,
        // e.g. U+0055 U+0308 instead of the precomposed U+00DC (Ü).
        // The GI server stores and expects NFC (precomposed) form, so normalise here.
        identifier = [identifier precomposedStringWithCanonicalMapping];
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
                // Build the JS call using NSJSONSerialization so the identifier is
                // properly escaped — raw %@-interpolation would silently mangle
                // identifiers that contain backslashes, single-quotes, or other
                // special characters (e.g. Notes pointers like server\db.nsf/0/UNID).
                NSDictionary *payload = @{@"identifier": identifier};
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                NSString *command = [NSString stringWithFormat:@"window.plugins.indexAppContent.onItemPressed(%@)", jsonString];

                NSLog(@"[IndexAppContent] Preparing to call JavaScript: %@", command);
                [self callJavascriptFunctionWhenAvailable:command fromWindow:window];
            } else {
                NSLog(@"[IndexAppContent] ERROR: No window or rootViewController found");
                NSLog(@"[IndexAppContent] Window: %@, RootVC: %@", window, window.rootViewController);
            }
        } else {
            NSLog(@"[IndexAppContent] ERROR: Scene is not UIWindowScene, it's: %@", NSStringFromClass([scene class]));
        }
        
        // We handled it, don't pass to other plugins
        NSLog(@"[IndexAppContent] ===== END SPOTLIGHT TAP HANDLING (handled by IndexAppContent) =====");
        return;
    } else {
        NSLog(@"[IndexAppContent] Not a Spotlight activity (CSSearchableItemActionType)");
        NSLog(@"[IndexAppContent] Expected: %@", CSSearchableItemActionType);
        NSLog(@"[IndexAppContent] Got: %@", userActivity.activityType);
    }
    
    // Not our activity type — call through to any other handlers.
    // Guard against infinite recursion: only call through if the method was swizzled (exchanged),
    // not merely added. When added, this selector IS our implementation — calling it recurses.
    if (sContinueUserActivityWasSwizzled) {
        NSLog(@"[IndexAppContent] Passing to other handlers (calling original via swizzle)...");
        [self indexAppContent_scene:scene continueUserActivity:userActivity];
    } else {
        NSLog(@"[IndexAppContent] scene:continueUserActivity: was added (not swizzled) — skipping fallback to avoid recursion");
    }
    
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

