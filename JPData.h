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

// Note: if stale=YES, expect another call to follow with fresh objects
- (void)data:(JPData *)data didReceiveObjects:(NSArray *)objects more:(BOOL)more stale:(BOOL)stale;
- (void)data:(JPData *)data didReceiveObject:(id)object stale:(BOOL)stale;

- (void)data:(JPData *)data didFailWithError:(NSError *)error;

@end


typedef void(^JPDataRequestBlock)(NSDictionary *result, NSError *error);
typedef void(^JPDataFetchManyBlock)(NSArray *objects, BOOL more, NSError *error);
typedef void(^JPDataFetchBlock)(id object, NSError *error);

@interface JPData : NSObject {
@private
    SBJsonParser *_parser;
    NSUserDefaults *_def;
    NSDictionary *_mapping; // key (NSString) -> parameters (NSDictionary)
    NSMutableDictionary *_misses; // key (NSString) -> Unix time of last cache miss (NSNumber)
    NSMutableDictionary *_keyToManagedObjectMapping; // key (NSString) -> list of object UUIDs (NSArray)
    NSArray *_entities;
}

+ (JPData *)sharedData; // Singleton

/*
  Fetch multiple objects.
 
  Note: given 'key' must be present as a key in the dictionary returned by the abstract method 'keyMappings'.
 
  The method fetchMany:withParams:block: doesn't return stale cached objects (otherwise the block would have to be
  called twice). The delegate versions therefore might return two sets of objects.
*/
- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate;
- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params append:(BOOL)append delegate:(id<JPDataDelegate>)delegate;
- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params block:(JPDataFetchManyBlock)completion; // note: only fresh objects returned

/*
  Fetch a single object. The given ID is appended to the endpoint associated with this key,
  resulting in an URL of the form:
 
  http://somedomain.com/<endpoint>/<id>
 
  The method fetch:withID:params:block: doesn't return stale cached objects (otherwise the block would have to be
  called twice). The delegate versions therefore might return two sets of objects.
 
  Note: given 'key' must be present as a key in the dictionary returned by the abstract method 'keyMappings'.
 */
- (void)fetch:(NSString *)key withID:(NSNumber *)id_ params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate;
- (void)fetch:(NSString *)key withID:(NSNumber *)id_ params:(NSDictionary *)params block:(JPDataFetchBlock)completion;

- (void)clearCacheForKey:(NSString *)key;
- (void)clearCache; // wipe cache of all keys
- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data;

// Helper methods for miscellaneous API calls

- (void)requestWithMethod:(NSString *)method
                 endpoint:(NSString *)endpoint
                   params:(NSDictionary *)params
               completion:(JPDataRequestBlock)requestBlock;

- (void)requestWithMethod:(NSString *)method
                      url:(NSURL *)url
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
  If no 'entities' is specified for the given key in keyMappings instead of the standard 'entity',
  then this method is called to determine the entity name to use for a given JSON object.
 
  This method must be subclassed in 'entities' is used once or more.
*/
- (NSString *)entityNameForJsonData:(NSDictionary *)dict withKey:(NSString *)key;

/*
 Called by fetchMany:withParams:append:delegate: when a JSON result comes back.
 
 Default implementation returns NO.
 */
- (BOOL)serverHasMoreAfterResult:(NSDictionary *)result;

/*
 Subclasses may override this to handle certain content or HTTP status codes, e.g. 401 or 404.
 If an NSError object is returned it is passed to the block or delegate passed by caller.
 
 Default implementation returns nil.
 */
- (NSError *)didReceiveResult:(NSDictionary *)result withHTTPStatusCode:(NSInteger)statusCode;

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

/*
  If an entry in 'keyMappings' has no "endpoint" key, subclasses should supply it with this method.
  
  Default implementation throws an exception.
*/
- (NSString *)endpointForName:(NSString *)name;

@end
