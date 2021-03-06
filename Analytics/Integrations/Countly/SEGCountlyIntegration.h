// CountlyIntegration.h
// Copyright (c) 2014 Segment.io. All rights reserved.

#import <Foundation/Foundation.h>
#import "SEGAnalyticsIntegration.h"


@interface SEGCountlyIntegration : SEGAnalyticsIntegration

@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) BOOL valid;
@property(nonatomic, assign) BOOL initialized;
@property(nonatomic, copy) NSDictionary *settings;

- (NSDictionary *)ensureNotNested:(NSDictionary *)dictionary;

@end
