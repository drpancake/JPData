//
//  JPData.h
//  Takota
//
//  Created by James Potter on 22/04/2013.
//  Copyright (c) 2013 Takota. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SBJsonParser.h"

#define JP_DATA_DEFAULT_CACHE_TIME 300 // used if cacheTimeForKey: is not overridden (seconds)
#define JP_DATA_MISSES_KEY @"JP_DATA_MISSES_KEY" // NSUserDefaults key for _misses
#define JP_DATA_MANAGED_OBJECT_KEYS @"JP_DATA_MANAGED_OBJECT_KEYS" // NSUserDefaults key for _keyToManagedObjectMapping


@class JPData;

@protocol JPDataDelegate <NSObject>
@optional

- (void)data:(JPData *)data didReceiveObjects:(NSArray *)objects more:(BOOL)more;
- (void)data:(JPData *)data didReceiveObject:(id)object; // only called when fetch: is used

// Cached but stale data, so expect a another call to didReceiveResult: soon afterwards
- (void)data:(JPData *)data didReceiveStaleObjects:(NSArray *)objects;
- (void)data:(JPData *)data didReceiveStaleObject:(id)object; // only called when fetch: is used

- (void)data:(JPData *)data didFailWithError:(NSError *)error;

@end


typedef void(^JPDataRequestBlock)(NSDictionary *result, NSError *error);

@interface JPData : NSObject {
@private
    SBJsonParser *_parser;
    NSUserDefaults *_def;
    NSDictionary *_mapping; // key (NSString) -> parameters (NSDictionary)
    NSMutableDictionary *_misses; // key (NSString) -> Unix time of last cache miss (NSNumber)
    NSMutableDictionary *_keyToManagedObjectMapping; // key (NSString) -> list of object UUIDs (NSArray)
}

+ (JPData *)sharedData; // Singleton

/*
  Fetch multiple objects.
 
  Note: given 'key' must be present as a key in the dictionary returned by the abstract method 'keyMappings'.
*/
- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate;
- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params append:(BOOL)append delegate:(id<JPDataDelegate>)delegate;

/*
  Fetch a single object. The given ID is appended to the endpoint associated with this key,
  resulting in an URL of the form:
 
  http://somedomain.com/<endpoint>/<id>
 
  Note: given 'key' must be present as a key in the dictionary returned by the abstract method 'keyMappings'.
 */
- (void)fetch:(NSString *)key withID:(NSNumber *)id_ params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate;

- (void)clearCacheForKey:(NSString *)key;
- (void)clearCache; // wipe cache of all keys

// Helper method for miscellaneous API calls
- (void)requestWithMethod:(NSString *)method
                 endpoint:(NSString *)endpoint
                   params:(NSDictionary *)params
               completion:(JPDataRequestBlock)requestBlock;

@property (nonatomic, assign) BOOL debug; // prints out useful debugging information, default=NO
@property (nonatomic, strong, readonly) NSManagedObjectContext *managedObjectContext;

// -- Methods for subclassing --

// Only called once, on initialization. This method must be subclassed.
- (NSDictionary *)keyMappings;

/*
  If no 'order' is specified for a key in 'keyMappings' then this value will
  be used. Returning nil prevents sorting for that key (default).
*/
- (NSString *)defaultOrderingPropertyName;

/*
  All requests to the server will take a given endpoint and prefix it with this URL.
  This method must be subclassed.
*/
- (NSURL *)baseURL;

/* 
  Called before every request to the server. This is a suitable place for adding authentication headers
  etc. to the request. The default implementation does nothing.
*/
- (void)willSendRequest:(NSMutableURLRequest *)request;

/*
  Called by fetchMany:withParams:append:delegate: when a JSON result comes back and it needs
  an array of NSDictionary objects to turn into CoreData models. The default implementation
  wraps the given dictionary in a newly created NSArray.
*/
- (NSArray *)dictionariesFromResult:(NSDictionary *)result;

/*
  Called by fetch:withID:params:delegate: when the JSON response comes back from the server.
  If the dictionary to be mapped to a Core Data model is somewhere within this data, this is 
  where it should be extracted.
 
  Default implementation returns the 'result' dictionary, i.e. does nothing.
*/
- (NSDictionary *)dictionaryFromResult:(NSDictionary *)result;

/*
  If no 'entity' is specified for the given key in keyMappings, this method is called
  to determine the entity name at runtime. If this is the case, this method must be subclassed.
*/
- (NSString *)entityNameForKey:(NSString *)key jsonData:(NSDictionary *)dict;

/*
 Called by fetchMany:withParams:append:delegate: when a JSON result comes back.
 
 Default implementation returns NO.
 */
- (BOOL)serverHasMoreAfterResult:(NSDictionary *)result;

// Subclasses may override this to handle certain HTTP status codes, e.g. 401 or 404.
- (void)didReceiveHTTPStatusCode:(NSInteger)statusCode;

/*
  Subclasses can use this to handle special cases, where mapping from JSON key to model field is not
  straightforward. If method returns NO then JPData will not attempt to do anything further for
  this property, i.e. it is assumed that this method handled it already.
 
  Default implementation always returns YES.
*/
- (BOOL)willSetValue:(id)value forProperty:(NSString *)propertyName inObject:(NSManagedObject *)object;

/*
  When JPData encounters a @property of type NSSet (i.e. a Core Data relation field) or a JSON value is of
  type NSDictionary (typically you'll want to convert this to a model object in its own right), then it
  calls this method and does not try to set it automatically.
*/
- (void)setValue:(id)value forSpecialProperty:(NSString *)propertyName inObject:(NSManagedObject *)object;

@end
