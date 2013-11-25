//
//  JPManagedObject.h
//  JPData
//
//  Created by James Potter on 25/11/2013.
//
#import <CoreData/CoreData.h>

@interface JPManagedObject : NSManagedObject

@property (nonatomic, retain) NSString *cacheKey;

@end
