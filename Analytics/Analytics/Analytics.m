// Analytics.m
// Copyright 2013 Segment.io

#import <UIKit/UIKit.h>
#import "SOUtils.h"
#import "Provider.h"
#import "SegmentioProvider.h"
#import "AmplitudeProvider.h"
#import "BugsnagProvider.h"
#import "ChartbeatProvider.h"
#import "CountlyProvider.h"
#import "FlurryProvider.h"
#import "GoogleAnalyticsProvider.h"
#import "KISSmetricsProvider.h"
#import "LocalyticsProvider.h"
#import "MixpanelProvider.h"
#import "Analytics.h"

static NSString * const kAnalyticsSettings = @"kAnalyticsSettings";
static NSInteger const AnalyticsSettingsUpdateInterval = 3600;

@interface Analytics ()

@property(nonatomic, strong) NSArray *providers;

// Settings
@property(nonatomic, strong) NSTimer *updateTimer;
@property(nonatomic, strong) NSURLConnection *connection;
@property(nonatomic, assign) NSInteger responseCode;
@property(nonatomic, strong) NSMutableData *responseData;

@end

@implementation Analytics {
    dispatch_queue_t _serialQueue;
}

- (id)initWithSecret:(NSString *)secret {
    NSParameterAssert(secret.length);
    
    if (self = [self init]) {
        _secret = secret;
        _providers = @[
            [SegmentioProvider withSecret:secret],
            [AmplitudeProvider withNothing],
            [BugsnagProvider withNothing],
            [ChartbeatProvider withNothing],
            [CountlyProvider withNothing],
            [FlurryProvider withNothing],
            [GoogleAnalyticsProvider withNothing],
            [KISSmetricsProvider withNothing],
            [LocalyticsProvider withNothing],
            [MixpanelProvider withNothing]
        ];
        // Update settings on each provider immediately
        [self updateProvidersWithSettings:[self localSettings]];
        _updateTimer = [NSTimer scheduledTimerWithTimeInterval:AnalyticsSettingsUpdateInterval
                                                        target:self
                                                      selector:@selector(requestSettingsFromNetwork)
                                                      userInfo:nil
                                                       repeats:YES];
        
        // Attach to application state change hooks
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,
                                 UIApplicationWillEnterForegroundNotification,
                                 UIApplicationWillTerminateNotification,
                                 UIApplicationWillResignActiveNotification,
                                 UIApplicationDidBecomeActiveNotification]) {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(handleAppStateNotification:)
                                                         name:name
                                                       object:nil];
        }
    }
    return self;
}

- (void)reset {
    [self requestSettingsFromNetwork];
}

- (void)debug:(BOOL)showDebugLogs {
    SetShowDebugLogs(showDebugLogs);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Analytics secret:%@>", self.secret];
}

#pragma mark - Private Helpers

- (NSDictionary *)sengmentIOContext:(NSDictionary *)context {
    NSMutableDictionary *providersDict = [context[@"providers"] mutableCopy];
    for (Provider *provider in self.providers)
        if (![provider.name isEqualToString:@"Segment.io"])
            providersDict[provider.name] = @NO;
    NSMutableDictionary *sioContext = [context mutableCopy];
    sioContext[@"providers"] = providersDict;
    return sioContext;
}

- (BOOL)isProvider:(Provider *)provider enabledInContext:(NSDictionary *)context {
    // checks if context.providers is enabling this provider
    
    if (!context) return YES;
    
    NSDictionary* providers = [context objectForKey:@"providers"];
    if (!providers) return YES;
    
    BOOL enabled = YES;
    // from: http://stackoverflow.com/questions/3822601/restoring-a-bool-inside-an-nsdictionary-from-a-plist-file
    if ([providers valueForKey:@"all"])
        enabled = [providers[@"all"] boolValue];
    if ([providers valueForKey:@"All"])
        enabled = [providers[@"All"] boolValue];
    
    if ([providers valueForKey:provider.name])
        enabled = [providers[provider.name] boolValue];
    
    return enabled;
}

- (void)handleAppStateNotification:(NSNotification *)note {
    SOLog(@"Application state change notification: %@", note.name);
    static NSDictionary *selectorMapping;
    static dispatch_once_t selectorMappingOnce;
    dispatch_once(&selectorMappingOnce, ^{
        selectorMapping = @{
            UIApplicationDidEnterBackgroundNotification:
                NSStringFromSelector(@selector(applicationDidEnterBackground)),
            UIApplicationWillEnterForegroundNotification:
                NSStringFromSelector(@selector(applicationWillEnterForeground)),
            UIApplicationWillTerminateNotification:
                NSStringFromSelector(@selector(applicationWillTerminate)),
            UIApplicationWillResignActiveNotification:
                NSStringFromSelector(@selector(applicationWillResignActive)),
            UIApplicationDidBecomeActiveNotification:
                NSStringFromSelector(@selector(applicationDidBecomeActive))
        };
    });
    NSString *selectorName = selectorMapping[note.name];
    if (selectorName) {
        SEL selector = NSSelectorFromString(selectorName);
        for (Provider *provider in self.providers) {
            if (!provider.ready)
                continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [provider performSelector:selector];
#pragma clang diagnostic pop
        }
    }
}


#pragma mark - Analytics API

- (void)identify:(NSString *)userId {
    [self identify:userId traits:nil context:nil];
}

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits {
    [self identify:userId traits:traits context:nil];
}

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits context:(NSDictionary *)context {
    traits = CoerceDictionary(traits);
    context = CoerceDictionary(context);
    
    // Iterate over providersArray and call identify.
    for (id object in self.providers) {
        Provider *provider = (Provider *)object;
        if ([provider ready] && [self isProvider:provider enabledInContext:context]) {
            if ([provider.name isEqualToString:@"Segment.io"]) {
                // Segment.io provider gets an augmented context to prevent server-side firing
                NSDictionary *augmentedContext = [self sengmentIOContext:context];
                [provider identify:userId traits:traits context:augmentedContext];
            } else {
                [provider identify:userId traits:traits context:context];
            }
        }
    }
}

- (void)track:(NSString *)event {
    [self track:event properties:nil context:nil];
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties {
    [self track:event properties:properties context:nil];
}

- (void)track:(NSString *)event properties:(NSDictionary *)properties context:(NSDictionary *)context {
    properties = CoerceDictionary(properties);
    context = CoerceDictionary(context);
    
    // Iterate over providersArray and call track.
    for (id object in self.providers) {
        Provider *provider = (Provider *)object;
        if ([provider ready] && [self isProvider:provider enabledInContext:context]) {
            if ([provider.name isEqualToString:@"Segment.io"]) {
                // Segment.io provider gets an augmented context to prevent server-side firing
                NSDictionary *augmentedContext = [self sengmentIOContext:context];
                [provider track:event properties:properties context:augmentedContext];
            } else {
                [provider track:event properties:properties context:context];
            }
        }
    }
}

- (void)screen:(NSString *)screenTitle {
    [self screen:screenTitle properties:nil context:nil];
}

- (void)screen:(NSString *)screenTitle properties:(NSDictionary *)properties {
    [self screen:screenTitle properties:properties context:nil];
}

- (void)screen:(NSString *)screenTitle properties:(NSDictionary *)properties context:(NSDictionary *)context {
    properties = CoerceDictionary(properties);
    context = CoerceDictionary(context);
    
    // Iterate over providersArray and call track.
    for (id object in self.providers) {
        Provider *provider = (Provider *)object;
        if ([provider ready] && [self isProvider:provider enabledInContext:context]) {
            if ([provider.name isEqualToString:@"Segment.io"]) {
                // Segment.io provider gets an augmented context to prevent server-side firing
                NSDictionary *augmentedContext = [self sengmentIOContext:context];
                [provider screen:screenTitle properties:properties context:augmentedContext];
            } else {
                [provider screen:screenTitle properties:properties context:context];
            }
        }
    }
}

#pragma mark - Settings

- (NSDictionary *)localSettings {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kAnalyticsSettings];
}

- (void)setLocalSettings:(NSDictionary *)settings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:settings forKey:kAnalyticsSettings];
    [self updateProvidersWithSettings:settings];
}

- (void)updateProvidersWithSettings:(NSDictionary *)settings {
    if (!settings)
        return;
    for (Provider *provider in self.providers) {
        if (![provider.name isEqualToString:@"Segment.io"]) {
            // Extract the settings for this provider and set them
            NSDictionary *providerSettings = settings[provider.name];
            
            // Google Analytics needs to be initialized on the main thread, but
            // dispatch-ing to the main queue when already on the main thread
            // causes the initialization to happen async. After first startup
            // we need the initialization to be synchronous.
            if ([NSThread isMainThread]) {
                [provider updateSettings:providerSettings];
            }
            else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [provider updateSettings:providerSettings];
                });
            }
        }
    }

}

- (void)requestSettingsFromNetwork {
    if (!self.connection) {
        NSString *urlString = [NSString stringWithFormat:@"http://api.segment.io/project/%@/settings", self.secret];
        NSURL *url = [NSURL URLWithString:urlString];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
        [request setHTTPMethod:@"GET"];
        
        SOLog(@"%@ Sending API settings request: %@", self, request);
        
        self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    }
}

#pragma mark - NSURLConnection Delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
    NSAssert([NSThread isMainThread], @"Should be on main since URL connection should have started on main");
    self.responseCode = [response statusCode];
    self.responseData = [NSMutableData data];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    NSAssert([NSThread isMainThread], @"Should be on main since URL connection should have started on main");
    [self.responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    dispatch_async(_serialQueue, ^{
        // Log the response status
        if (self.responseCode != 200) {
            SOLog(@"%@ Settings API request had an error: %@", self, [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding]);
        }
        else {
            // Try to interpret the data as an NSDictionary of NSDictionarys
            NSError* error;
            NSDictionary* settings = [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:&error];
            SOLog(@"%@ Settings API request succeeded 200 %@", self, settings);
            [self setLocalSettings:settings];
        }
        // Clear the request data
        self.responseCode = 0;
        self.responseData = nil;
        self.connection = nil;
    });
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    dispatch_async(_serialQueue, ^{
        SOLog(@"%@ Network failed while getting settings from API: %@", self, error);
        self.responseCode = 0;
        self.responseData = nil;
        self.connection = nil;
    });
}

#pragma mark - Class Methods

static Analytics *sharedInstance = nil;

+ (instancetype)withSecret:(NSString *)secret {
    NSParameterAssert(secret.length > 0);
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithSecret:secret];
    });
    return sharedInstance;
}

+ (instancetype)sharedAnalytics {
    NSAssert(sharedInstance, @"%@ sharedInstance called before withSecret", self);
    return sharedInstance;
}

@end
