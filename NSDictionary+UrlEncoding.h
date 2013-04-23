//
//  NSDictionary+UrlEncoding.h
//  Takota
//
//  Created by James Potter on 07/09/2012.
//  Copyright (c) 2012 Takota. All rights reserved.
//

#import <Foundation/Foundation.h>

// Credit: http://stackoverflow.com/a/718480

@interface NSDictionary (UrlEncoding)

- (NSString *)urlEncodedString;

@end
