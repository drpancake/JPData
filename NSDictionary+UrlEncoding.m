//
//  NSDictionary+UrlEncoding.m
//  Takota
//
//  Created by James Potter on 07/09/2012.
//  Copyright (c) 2012 Takota. All rights reserved.
//

#import "NSDictionary+UrlEncoding.h"

// Helper function: get the string form of any object
static NSString *toString(id object) {
    return [NSString stringWithFormat:@"%@", object];
}

// Helper function: get the url encoded string form of any object
static NSString *urlEncode(id object) {
    NSString *string = toString(object);
    return [string stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

@implementation NSDictionary (UrlEncoding)

- (NSString *)urlEncodedString
{
    NSMutableArray *parts = [NSMutableArray array];
    for (id key in self) {
        id value = [self objectForKey:key];
        NSString *part = [NSString stringWithFormat:@"%@=%@", urlEncode(key), urlEncode(value)];
        [parts addObject:part];
    }
    return [parts componentsJoinedByString:@"&"];
}

@end