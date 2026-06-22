//
//  IndexAppContent.h
//
//  Created by Johan Blomgren on 12/02/16.
//
//

#import "Cordova/CDV.h"
#import "Cordova/CDVViewController.h"
#import "UIKit/UITouch.h"
#import "IndexAppContent.h"
#import <CoreSpotlight/CoreSpotlight.h>

@interface IndexAppContent () {
    dispatch_group_t _group;
    dispatch_queue_t _queue;
}

@end

#define kGROUP_IDENTIFIER "com.appindexcontent.group"

#define kINDEX_TIMESTAMP_KEY @"kINDEX_TIMESTAMP_KEY"
#define kINDEXING_INTERVAL_KEY @"kINDEX_INTERVAL_KEY"

#define kDEFAULT_INDEXING_INTERVAL 1440 // Minutes

@implementation IndexAppContent

/**
 *  NSUserDefaults key used to persist a Spotlight identifier across a cold launch.
 *  Written by SceneDelegate+IndexAppContent (scene:willConnectToSession:options:)
 *  and consumed here once the WebView is ready.
 */
static NSString *const kIACTmpIdentifier = @"IACTmpIdentifier";

#pragma mark - Public (Overriden)

- (void)pluginInitialize {
    // Restore Spotlight identifier saved during cold launch (by scene:willConnectToSession:options:).
    // The SceneDelegate writes it before the WebView exists; we read it here when the WebView is ready.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *identifier = [defaults stringForKey:kIACTmpIdentifier];
    if (identifier) {
        // iOS/macOS may return the identifier in NFD (decomposed) Unicode form.
        // The GI server stores and expects NFC (precomposed) form, so normalise here.
        identifier = [identifier precomposedStringWithCanonicalMapping];
        NSLog(@"[IndexAppContent] pluginInitialize: found stored Spotlight identifier: %@", identifier);
        [defaults removeObjectForKey:kIACTmpIdentifier];
        [defaults synchronize];

        // Build the JS call using NSJSONSerialization so the identifier is
        // properly escaped — raw %@-interpolation would silently mangle
        // identifiers that contain backslashes, single-quotes, or other
        // special characters (e.g. Notes pointers like server\db.nsf/0/UNID).
        NSDictionary *payload = @{@"identifier": identifier};
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSString *command = [NSString stringWithFormat:@"window.plugins.indexAppContent.onItemPressed(%@)", jsonString];

        NSLog(@"[IndexAppContent] pluginInitialize: dispatching cold-launch Spotlight command");

        // Poll until the JavaScript handler is registered (Cordova webView may not have
        // finished loading the app JS yet even though pluginInitialize was called).
        __weak __typeof(self) weakSelf = self;
        __block NSString *storedCommand = command;
        __block int retryCount = 0;

        __block void (^checkAndExecute)(void) = ^void(void) {
            retryCount++;
            NSLog(@"[IndexAppContent] pluginInitialize JS attempt #%d", retryCount);
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            id<CDVWebViewEngineProtocol> webViewEngine = strongSelf.webViewEngine;
            if (!webViewEngine) {
                NSLog(@"[IndexAppContent] pluginInitialize: WebViewEngine not available yet, retrying...");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
                return;
            }

            NSString *check = @"(window && window.plugins && window.plugins.indexAppContent && typeof window.plugins.indexAppContent.onItemPressed == 'function') ? true : false";
            [webViewEngine evaluateJavaScript:check completionHandler:^(id result, NSError *error) {
                if (error || [result boolValue] == NO) {
                    NSLog(@"[IndexAppContent] pluginInitialize: JS not ready (attempt #%d), retrying...", retryCount);
                    if (error) NSLog(@"[IndexAppContent] Error: %@", error);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
                } else {
                    NSLog(@"[IndexAppContent] pluginInitialize: JS ready after %d attempts, executing", retryCount);
                    [webViewEngine evaluateJavaScript:storedCommand completionHandler:^(id _Nullable r, NSError * _Nullable e) {
                        if (e) {
                            NSLog(@"[IndexAppContent] pluginInitialize: Error executing JS: %@", e);
                        } else {
                            NSLog(@"[IndexAppContent] pluginInitialize: Cold-launch Spotlight command executed successfully");
                        }
                    }];
                }
            }];
        };

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), checkAndExecute);
    }
}

- (void)onAppTerminate {
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Public

- (void)isIndexingAvailable:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:[CSSearchableIndex isIndexingAvailable]] callbackId:command.callbackId];
}

- (void)setItems:(CDVInvokedUrlCommand *)command
{

    if (![self _shouldUpdateIndex]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Will not update index"] callbackId:command.callbackId];

        return;
    }

    _group = dispatch_group_create();
    _queue = dispatch_queue_create(kGROUP_IDENTIFIER, NULL);

    NSArray *items = [command.arguments firstObject];

    __block NSMutableArray *searchableItems = [[NSMutableArray alloc] init];

    for (NSDictionary *item in items) {
        dispatch_group_async(_group, _queue, ^{
            NSString *domain = [item objectForKey:@"domain"];
            NSString *identifier = [item objectForKey:@"identifier"];
            NSString *title = [item objectForKey:@"title"];
            NSString *description = [item objectForKey:@"description"];
            NSString *url = [item objectForKey:@"url"];

            // Optional
            NSNumber *rating = [NSNumber numberWithInteger:[[item objectForKey:@"rating"] integerValue]];
            NSArray *keywords = [item objectForKey:@"keywords"];
            NSInteger lifetime = [[item objectForKey:@"lifetime"] integerValue];

            NSLog(@"Indexing %@", title);

            CSSearchableItemAttributeSet *attributes = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:(__bridge NSString *)kUTTypeText];

            attributes.title = title;
            attributes.contentDescription = description;
            attributes.thumbnailData = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
            attributes.displayName = title;
            attributes.rating = rating;
            attributes.keywords = keywords;

            CSSearchableItem *item = [[CSSearchableItem alloc] initWithUniqueIdentifier:identifier domainIdentifier:domain attributeSet:attributes];
            item.expirationDate = lifetime ? [self _dateByMinuteOffset:lifetime] : nil;

            [searchableItems addObject:item];
        });
    }

    dispatch_group_notify(_group, _queue, ^{
        [[CSSearchableIndex defaultSearchableIndex] indexSearchableItems:searchableItems completionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"%@", error);
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]] callbackId:command.callbackId];
            } else {
                NSLog(@"Indexing complete. Next indexing possible in %zd", [self _getIndexingInterval]);
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
            }
        }];
    });
}

- (void)clearItemsForDomains:(CDVInvokedUrlCommand *)command
{
    NSArray *domains = [command.arguments firstObject];

    [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithDomainIdentifiers:domains completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"%@", error);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]] callbackId:command.callbackId];
        } else {
            NSLog(@"Index removed for domains %@", domains);
            [self _clearTimestamp];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    }];
}

- (void)clearItemsForIdentifiers:(CDVInvokedUrlCommand *)command
{
    NSArray *identifiers = [command.arguments firstObject];

    [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithIdentifiers:identifiers completionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"%@", error);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]] callbackId:command.callbackId];
        } else {
            NSLog(@"Items removed with identifiers %@", identifiers);
            [self _clearTimestamp];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    }];
}

- (void)setIndexingInterval:(CDVInvokedUrlCommand *)command
{
    NSInteger interval = [[command.arguments firstObject] integerValue];

    if ([self _setIndexingInterval:interval]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    } else {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid time interval"] callbackId:command.callbackId];
    }
}

#pragma mark - Private

- (BOOL)_shouldUpdateIndex
{
    NSDate *indexLastUpdatedAt = [self _getTimestamp];
    NSInteger timeIntervalInMinutesUntilNextUpdateIsProhibited = [self _getIndexingInterval];
    int minutesSinceLastIndexUpdate = [self _getMinutesSince:indexLastUpdatedAt];
    BOOL shouldUpdate = YES;

    if (indexLastUpdatedAt && minutesSinceLastIndexUpdate < timeIntervalInMinutesUntilNextUpdateIsProhibited) {
        NSLog(@"Will not update index. Last update: %@", indexLastUpdatedAt);
        shouldUpdate = NO;
    } else {
        [self _setTimestamp];
    }

    return shouldUpdate;
}

- (void)_setTimestamp
{
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kINDEX_TIMESTAMP_KEY];
}

- (int)_getMinutesSince:(NSDate*)date {
    return [[NSDate date] timeIntervalSinceDate:date] / 60;
}

- (NSDate *)_dateByMinuteOffset:(NSInteger)minuteOffset
{
    NSDateComponents *minuteComponent = [[NSDateComponents alloc] init];
    minuteComponent.minute = minuteOffset;

    return [[NSCalendar currentCalendar] dateByAddingComponents:minuteComponent toDate:[NSDate date] options:0];
}

- (NSDate *)_getTimestamp
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:kINDEX_TIMESTAMP_KEY];
}

- (void)_clearTimestamp
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kINDEX_TIMESTAMP_KEY];
}

- (NSInteger)_getIndexingInterval
{
    if (![[NSUserDefaults standardUserDefaults] objectForKey:kINDEXING_INTERVAL_KEY]) { // nil
        return kDEFAULT_INDEXING_INTERVAL;
    } else { // 0 or greater
        return [[[NSUserDefaults standardUserDefaults] objectForKey:kINDEXING_INTERVAL_KEY] integerValue];
    }
}

- (BOOL)_setIndexingInterval:(NSInteger)interval
{
    if (interval < 0) {
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setObject:@(interval) forKey:kINDEXING_INTERVAL_KEY];

    return YES;
}

@end
