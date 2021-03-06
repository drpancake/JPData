//
//  JPData.m
//  Takota
//
//  Created by James Potter on 22/04/2013.
//  Copyright (c) 2013 Takota. All rights reserved.
//

#import <objc/runtime.h>
#import "JPData.h"
#import "JPManagedObject.h"
#import "NSDictionary+UrlEncoding.h"

@interface JPData ()

// Only one of 'delegate' and 'block' should be passed in as arguments, never both
- (void)_fetchMany:(NSString *)key
      withEndpoint:(NSString *)endpoint
            params:(NSDictionary *)params
            append:(BOOL)append
          delegate:(id<JPDataDelegate>)delegate
             block:(JPDataFetchManyBlock)block
          cacheKey:(NSString *)cacheKey;

// Only one of 'delegate' and 'block' should be passed in as arguments, never both
- (void)_fetch:(NSString *)key
        withID:(NSString *)id_
      endpoint:(NSString *)endpoint
        params:(NSDictionary *)params
      delegate:(id<JPDataDelegate>)delegate
         block:(JPDataFetchBlock)block
      cacheKey:(NSString *)cacheKey;

- (NSManagedObject *)managedObjectFromDictionary:(NSDictionary *)dict
                                             key:(NSString *)key
                            managedObjectContext:(NSManagedObjectContext *)managedObjectContext;

// Returns YES if elapsed duration between 'loadTime' and now has exceeded cache time given key
- (BOOL)isCacheTimeExceededForTime:(NSDate *)loadTime withKey:(NSString *)key;

/*
  Returns nil if no objects are cached. 'stale' is a pointer to a BOOL and
  indicates that returned objects are old/stale.
*/
- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale withID:(NSString *)id_ cacheKey:(NSString *)cacheKey;
- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale cacheKey:(NSString *)cacheKey;
- (NSManagedObject *)cachedModelObjectForKey:(NSString *)key withID:(NSString *)id_ stale:(BOOL *)stale cacheKey:(NSString *)cacheKey;

// If mapping contains the key 'order' the objects will be sorted using that as a keyPath
- (NSArray *)sortModelObjects:(NSArray *)objects withMapping:(NSDictionary *)mappingDict;

// All times in Unix format
- (NSNumber *)lastMissTimeForKey:(NSString *)key withCacheKey:(NSString *)cacheKey;
- (NSNumber *)lastMissTimeForKey:(NSString *)key withID:(NSString *)id_ cacheKey:(NSString *)cacheKey;
- (void)setMissTimeForKey:(NSString *)key withCacheKey:(NSString *)cacheKey; // sets it to now
- (void)setMissTimeForKey:(NSString *)key withID:(NSString *)id_ cacheKey:(NSString *)cacheKey; // sets it to now

// How long this key's data is fresh for
- (NSInteger)cacheTimeForKey:(NSString *)key;

// Discards dead cache entries older than two weeks
- (void)cleanMisses;

- (void)associateObject:(NSManagedObject *)object withKey:(NSString *)key cacheKey:(NSString *)cacheKey;

// Helper
- (void)sendErrorMessage:(NSString *)message toDelegate:(id<JPDataDelegate>)delegate orBlock:(JPDataFetchBlock)block;

- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data managedObjectContext:(NSManagedObjectContext *)managedObjectContext;

@end

@implementation JPData

- (id)init {
    self = [super init];
    if (self) {
        id appDelegate = [UIApplication sharedApplication].delegate;
        _managedObjectContext = [appDelegate valueForKey:@"managedObjectContext"];
        
        _debug = NO;
        _def = [NSUserDefaults standardUserDefaults];
        _parser = [[SBJsonParser alloc] init];
        _mapping = [self keyMappings];
        
        // Fetch stored dictionary or create one
        _misses = [_def objectForKey:JP_DATA_MISSES_KEY];
        if (_misses == nil) {
            _misses = [NSMutableDictionary dictionary];
        } else {
            [self cleanMisses];
        }
        
        // Cache entities list
        NSManagedObjectModel *managedObjectModel = self.managedObjectContext.persistentStoreCoordinator.managedObjectModel;
        _entities = [[managedObjectModel entitiesByName] allKeys];
    }
    return self;
}

+ (JPData *)sharedData
{
    static JPData *instance = nil;
    if (instance == nil) {
        instance = [[[self class] alloc] init]; // allows for subclassing
    }
    return instance;
}

- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data managedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    if (managedObjectContext == nil) managedObjectContext = self.managedObjectContext;
    
    NSArray *jsonKeys = [data allKeys];
    
    NSUInteger count = 0;
    objc_property_t* properties = class_copyPropertyList([object class], &count);
    for (int i = 0; i < count; i++) {
        NSString *propertyName = [NSString stringWithUTF8String:property_getName(properties[i])];
        
        // Usually the JSON key will match the name of the property, but sometimes (e.g. "id") there's
        // a conflict with Obj-C reserved keywords, so a trailing underscore is used in the entity
        NSString *jsonKey = propertyName;
        if ([jsonKey characterAtIndex:[jsonKey length] - 1] == '_')
            jsonKey = [jsonKey substringToIndex:[jsonKey length] - 1];
        
        // Make sure we have a corresponding JSON value for this @property before carrying on
        if (![jsonKeys containsObject:jsonKey]) {
            if (self.debug) NSLog(@"WARNING: no key in JSON matching property @%@", propertyName);
            continue;
        }
        
        id value = [data objectForKey:jsonKey];
        
        // NSSet properties (i.e. relations) should be handled by subclass
        NSString *attrs = [NSString stringWithUTF8String:property_getAttributes(properties[i])];
        if ([attrs rangeOfString:@"NSSet"].location != NSNotFound) {
            [self setValue:value forSpecialProperty:propertyName inObject:object];
            continue;
        }
        
        // NSDictionary properties can sometimes be handled automatically
        if ([value isKindOfClass:[NSDictionary class]]) {
            // Try to guess Core Data entity based on the @property name and ensure it exists
            NSString *entityName = [propertyName capitalizedString];
            if (![_entities containsObject:entityName]) {
                
                // Unable to do this automatically so let subclass handle it
                [self setValue:value forSpecialProperty:propertyName inObject:object];
                
                continue;
            }
            
            NSManagedObject *otherObject = [NSEntityDescription insertNewObjectForEntityForName:entityName
                                                                         inManagedObjectContext:managedObjectContext];
            [self populateModelObject:otherObject withData:value];
            [object setValue:otherObject forKey:propertyName];
            continue;
        }
        
        // Convert NSNull to nil
        if ([value isKindOfClass:[NSNull class]])
            value = nil;
        
        @try {
            // Here the subclass can jump in to handle a special case
            if ([self willSetValue:value forProperty:propertyName inObject:object]) {
                // Subclass returned YES, so attempt to assign value automatically
                [object setValue:value forKey:propertyName];
            }
        } @catch (NSException *exception) {
            NSLog(@"ERROR setting property '%@' to value '%@' for model class: %@", propertyName, value, [object class]);
        }
    }
    
    free(properties);
}

- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data
{
    [self populateModelObject:object withData:data managedObjectContext:nil];
}

#pragma mark -
#pragma mark Methods for subclassing

- (NSDictionary *)keyMappings
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass.", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSString *)defaultOrderingPropertyName
{
    return nil;
}

- (NSURL *)baseURL
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass.", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (void)willSendRequest:(NSMutableURLRequest *)request
{
    
}

- (NSArray *)dictionariesFromResult:(NSDictionary *)result withKey:(NSString *)key endpoint:(NSString *)endpoint
{
    NSArray *dicts = nil;
    if (result) dicts = @[result];
    return dicts;
}

- (NSDictionary *)dictionaryFromResult:(NSDictionary *)result withKey:(NSString *)key endpoint:(NSString *)endpoint
{
    return result;
}

- (NSString *)entityNameForJsonData:(NSDictionary *)dict withKey:(NSString *)key
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass if 'entity' not specified for a key.",
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (BOOL)serverHasMoreAfterResult:(NSDictionary *)result
{
    return NO;
}

- (NSError *)didReceiveResult:(NSDictionary *)result withHTTPStatusCode:(NSInteger)statusCode
{
    return nil;
}

- (BOOL)willSetValue:(id)value forProperty:(NSString *)propertyName inObject:(NSManagedObject *)object
{
    return YES;
}

- (void)setValue:(id)value forSpecialProperty:(NSString *)propertyName inObject:(NSManagedObject *)object
{
    
}

- (NSString *)endpointForName:(NSString *)name
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass if 'endpoint' not specified for a key.",
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

#pragma mark -
#pragma mark Fetch methods

- (void)_fetchMany:(NSString *)key
      withEndpoint:(NSString *)endpoint
            params:(NSDictionary *)params
            append:(BOOL)append
          delegate:(id<JPDataDelegate>)delegate
             block:(JPDataFetchManyBlock)block
          cacheKey:(NSString *)cacheKey
{
    NSDictionary *mappingDict = _mapping[key];
    if (mappingDict == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unknown key '%@' for method %@.", key, NSStringFromSelector(_cmd)];
    }
    
    // Attempt to fetch cached objects for this key
    BOOL stale;
    NSArray *cachedObjects = [self cachedModelObjectsForKey:key stale:&stale cacheKey:cacheKey];
    
    /*
      If we have any objects stored in the cache for this key, then send them straight to our delegate
      object regardless of freshness, unless append=YES in which case we fetch fresh objects anyway and
      append them to any cached objects we might have.
    */
    
    if (append == NO && (cachedObjects && [cachedObjects count] > 0)) {
        NSArray *sorted = [self sortModelObjects:cachedObjects withMapping:mappingDict];
        
        if (delegate && [delegate respondsToSelector:@selector(data:didReceiveObjects:more:stale:)]) {
            [delegate data:self didReceiveObjects:sorted more:NO stale:stale];
        } else if (block && !stale) {
            block(sorted, NO, nil);
        }
        
        // The cache is fresh so we don't need to do anything else
        if (!stale) return;
    }
    
    /*
      At this point, either the cache was empty (i.e. this is the initial fetch for this key), the
      returned objects are stale and need updating OR append=YES and we're adding new objects.
     
      In any case, we need to perform an API call.
    */
    
    if (!endpoint) {
        if (mappingDict[@"endpoint"]) {
            endpoint = mappingDict[@"endpoint"];
        } else {
            endpoint = [self endpointForName:key];
        }
    }
    
    [self requestWithMethod:@"GET" endpoint:endpoint params:params completion:^(NSDictionary *result, NSError *error) {
        
        // Get off the main thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (error) {
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (delegate && [delegate respondsToSelector:@selector(data:didFailWithError:)]) {
                        [delegate data:self didFailWithError:error];
                    } else if (block) {
                        block(nil, NO, error);
                    }
                });
                
            } else {
                // Managed object context for this thread
                NSManagedObjectContext *backgroundManagedObjectContext = [[NSManagedObjectContext alloc] init];
                [backgroundManagedObjectContext setPersistentStoreCoordinator:_managedObjectContext.persistentStoreCoordinator];
                
                NSMutableArray *newObjects = [NSMutableArray array];
                
                // -- Delete previously stored objects, unless append=YES in which case we add to them --
                
                if (!append) {
                    for (NSManagedObject *object in cachedObjects) {
                        // Fetch the object in this thread's context and delete
                        NSManagedObject *_object = [backgroundManagedObjectContext objectWithID:object.objectID];
                        [backgroundManagedObjectContext deleteObject:_object];
                    }
                } else if (cachedObjects != nil) {
                    [newObjects addObjectsFromArray:cachedObjects];
                }
                
                // -- Convert JSON into model objects --
                
                
                NSArray *dictionaries = [self dictionariesFromResult:result withKey:key endpoint:endpoint];
                for (NSDictionary *dict in dictionaries) {
                    
                    // Sanity check
                    if (![dict isKindOfClass:[NSDictionary class]]) {
                        NSLog(@"WARNING: expecting a dictionary from dictionariesFromResult: but found '%@'",
                              NSStringFromClass([dict class]));
                        continue;
                    }
                    
                    // Create the new object in this thread's context
                    NSManagedObject *object = [self managedObjectFromDictionary:dict key:key managedObjectContext:backgroundManagedObjectContext];
                    if (object == nil) continue;
                    
                    [self populateModelObject:object withData:dict managedObjectContext:backgroundManagedObjectContext];
                    [newObjects addObject:object];
                }
                
                // Keep track of which key these objects are associated with (must be done after saving)
                for (NSManagedObject *object in newObjects) [self associateObject:object withKey:key cacheKey:cacheKey];
                
                [backgroundManagedObjectContext save:nil];
                
                // Update cache miss time, even if we're appending objects to possibly stale cached objects --
                [self setMissTimeForKey:key withCacheKey:cacheKey];
                
                // -- Send objects to delegate --
                
                // Are there more results to fetch after this?
                BOOL more = [self serverHasMoreAfterResult:result];
                
                // Sort
                NSArray *sorted = [self sortModelObjects:newObjects withMapping:mappingDict];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    
                    // Fetch the objects in the main thread's managed object context
                    NSMutableArray *_sorted = [NSMutableArray array];
                    for (NSManagedObject *object in sorted)
                        [_sorted addObject:[_managedObjectContext objectWithID:object.objectID]];
                    
                    if (delegate && [delegate respondsToSelector:@selector(data:didReceiveObjects:more:stale:)]) {
                        [delegate data:self didReceiveObjects:_sorted more:more stale:NO];
                    } else if (block) {
                        block(_sorted, more, nil);
                    }
                });
            }
            
        }); // end of dispatch_async()
        
    }]; // end of completion block
}

- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params append:(BOOL)append delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetchMany:key withEndpoint:nil params:params append:append delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetchMany:key withEndpoint:nil params:params append:NO delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetchMany:(NSString *)key withEndpoint:(NSString *)endpoint params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetchMany:key withEndpoint:endpoint params:params append:NO delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetchMany:(NSString *)key withEndpoint:(NSString *)endpoint params:(NSDictionary *)params append:(BOOL)append delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetchMany:key withEndpoint:endpoint params:params append:append delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params cacheKey:(NSString *)cacheKey block:(JPDataFetchManyBlock)completion
{
    [self _fetchMany:key withEndpoint:nil params:params append:NO delegate:nil block:completion cacheKey:cacheKey];
}

- (void)_fetch:(NSString *)key
        withID:(NSString *)id_
      endpoint:(NSString *)endpoint
        params:(NSDictionary *)params
      delegate:(id<JPDataDelegate>)delegate
         block:(JPDataFetchBlock)block
      cacheKey:(NSString *)cacheKey
{
    NSDictionary *mappingDict = _mapping[key];
    if (mappingDict == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unknown key '%@' for method %@.", key, NSStringFromSelector(_cmd)];
    }
    
    // Attempt to fetch cached objects for this key
    BOOL stale;
    NSManagedObject *cachedObject = [self cachedModelObjectForKey:key withID:id_ stale:&stale cacheKey:cacheKey];
    
    // If we have an object stored in the cache for this key, then send it straight to our delegate
    
    if (cachedObject) {
        if (delegate && [delegate respondsToSelector:@selector(data:didReceiveObject:stale:)]) {
            [delegate data:self didReceiveObject:cachedObject stale:stale];
        } else if (block && !stale) {
            block(cachedObject, nil);
        }
        
        // The cache is fresh so we don't need to do anything else
        if (!stale) return;
    }
    
    /*
     At this point, either the cache was empty (i.e. this is the initial fetch for this key) OR the
     returned object is stale and needs updating.
     
     In any case, we need to perform an API call.
     */
    
    if (endpoint == nil) {
        endpoint = mappingDict[@"endpoint"];
        if (endpoint == nil) endpoint = [self endpointForName:key];
        if (id_) endpoint = [NSString stringWithFormat:@"%@/%@", endpoint, id_];
    }
    
    [self requestWithMethod:@"GET" endpoint:endpoint params:params completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            if (delegate && [delegate respondsToSelector:@selector(data:didFailWithError:)]) {
                [delegate data:self didFailWithError:error];
            } else if (block) {
                block(nil, error);
            }
            return;
        }
        
        NSDictionary *dict = [self dictionaryFromResult:result withKey:key endpoint:endpoint];
        
        if (dict == nil) {
            NSString *msg = [NSString stringWithFormat:@"Empty dictionary received for endpoint '%@'", endpoint];
            [self sendErrorMessage:msg toDelegate:delegate orBlock:block];
            return;
        }
        
        if (![dict isKindOfClass:[NSDictionary class]]) {
            NSString *msg = [NSString stringWithFormat:@"Expecting a dictionary for endpoint '%@' but found '%@'",
                             endpoint, NSStringFromClass([result class])];
            [self sendErrorMessage:msg toDelegate:delegate orBlock:block];
            return;
        }
        
        @try {
            // Delete cached object if there is one
            if (cachedObject) [self.managedObjectContext deleteObject:cachedObject];
            
            // -- Convert JSON to Core Data model object --
            
            NSManagedObject *object = [self managedObjectFromDictionary:dict key:key managedObjectContext:nil]; // will use default context
            
            if (object == nil) {
                NSString *msg = [NSString stringWithFormat:@"Unable to create object for endpoint '%@'.", endpoint];
                [self sendErrorMessage:msg toDelegate:delegate orBlock:block];
                return;
            }
            
            [self populateModelObject:object withData:dict];
            
            // If the server didn't return an "id" for the object, manually assign it
            // with the one used to do this fetch
            
            if (id_ && [object valueForKey:@"id_"] == nil) [object setValue:id_ forKey:@"id_"];
            
            // Keep track of which key this object is associated with (must be done after saving)
            [self associateObject:object withKey:key cacheKey:cacheKey];
            
            [_managedObjectContext save:nil];
            
            // -- Update cache miss time and send to delegate --
            
            [self setMissTimeForKey:key withID:id_ cacheKey:cacheKey];
            
            if (delegate && [delegate respondsToSelector:@selector(data:didReceiveObject:stale:)]) {
                [delegate data:self didReceiveObject:object stale:NO];
            } else if (block) {
                block(object, nil);
            }
            
        } @catch (NSException *exception) {
            NSString *msg = [NSString stringWithFormat:@"Problem communicating with the server. [%@]", exception.reason];
            [self sendErrorMessage:msg toDelegate:delegate orBlock:block];
        }
    }];
}

- (void)fetch:(NSString *)key withID:(NSString *)id_ params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetch:key withID:id_ endpoint:nil params:params delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetch:(NSString *)key withID:(NSString *)id_ endpoint:(NSString *)endpoint params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate cacheKey:(NSString *)cacheKey
{
    [self _fetch:key withID:id_ endpoint:endpoint params:params delegate:delegate block:nil cacheKey:cacheKey];
}

- (void)fetch:(NSString *)key withID:(NSString *)id_ params:(NSDictionary *)params cacheKey:(NSString *)cacheKey block:(JPDataFetchBlock)completion
{
    [self _fetch:key withID:id_ endpoint:nil params:params delegate:nil block:completion cacheKey:cacheKey];
}

#pragma mark -
#pragma mark Helper methods

- (void)requestWithMethod:(NSString *)method
                 endpoint:(NSString *)endpoint
                   params:(NSDictionary *)params
               completion:(JPDataRequestBlock)requestBlock
{
    NSString *baseString = [[self baseURL] absoluteString];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", baseString, endpoint]];
    [self requestWithMethod:method url:url params:params completion:requestBlock];
}

- (void)requestWithMethod:(NSString *)method
                      url:(NSURL *)url
                   params:(NSDictionary *)params
               completion:(JPDataRequestBlock)requestBlock
{
    // Discard empty params
    if (params && [params count] < 1)
        params = nil;
    
    NSMutableString *urlString = [NSMutableString stringWithString:[url absoluteString]];
    
    // GET parameters
    if ([method isEqualToString:@"GET"] && params) {
        if ([urlString rangeOfString:@"?"].location == NSNotFound) {
            [urlString appendFormat:@"?%@", [params urlEncodedString]];
        } else {
            [urlString appendFormat:@"&%@", [params urlEncodedString]];
        }
    }
    
    url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:15];
    
    [request setHTTPMethod:method];
    
    // PUT or POST parameters
    if ([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]) {
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"content-type"];
        
        if (params) {
            NSString *paramsString = [params urlEncodedString];
            NSData *requestData = [NSData dataWithBytes:[paramsString UTF8String] length:[paramsString length]];
            [request setHTTPBody:requestData];
            
            if (self.debug) NSLog(@"--> PARAMS: %@", paramsString);
        }
    }
    
    // Last chance for subclasses to customise the request
    [self willSendRequest:request];
    
    if (self.debug) NSLog(@"REQ: %@", request.URL);
    
    // Show the status bar spinner
    UIApplication *app = [UIApplication sharedApplication];
    app.networkActivityIndicatorVisible = YES;
    
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:queue
                           completionHandler:^(NSURLResponse *response, NSData *responseData, NSError *error) {
                               app.networkActivityIndicatorVisible = NO;
                               NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                               
                               // Special case for 401 error
                               if (error && error.code == NSURLErrorUserCancelledAuthentication) {
                                   statusCode = 401;
                                   error = nil;
                               }
                               
                               // If there was an error, don't go any further
                               if (error) {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       requestBlock(nil, error);
                                   });
                                   return;
                               }
                               
                               // This is the slow part
                               NSString *text = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];
                               NSDictionary *result = [_parser objectWithString:text];
                               if (result == nil) NSLog(@"JSON error: %@", _parser.error);
                               
                               dispatch_async(dispatch_get_main_queue(), ^{
                                   // Allow subclass to hook in here
                                   NSError *error = [self didReceiveResult:result withHTTPStatusCode:statusCode];
                                   
                                   if (error) {
                                       requestBlock(nil, error);
                                       return;
                                   }
                                   
                                   if (statusCode == 200) {
                                       requestBlock(result, nil);
                                   } else if (statusCode == 400 || statusCode == 404 || statusCode == 500) {
                                       
                                       NSString *text = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];
                                       NSDictionary *json = [_parser objectWithString:text];
                                       NSString *message;
                                       if (json && json[@"error"] != nil) {
                                           message = json[@"error"];
                                       } else {
                                           message = @"There was a problem connecting to the server.";
                                       }
                                       
                                       NSDictionary *userInfo = @{NSLocalizedDescriptionKey : message};
                                       NSError *error = [NSError errorWithDomain:@"JPData" code:1 userInfo:userInfo];
                                       requestBlock(nil, error);
                                       
                                   } else {
                                       requestBlock(result, error);
                                   }

                               });
                           }];
}

#pragma mark -
#pragma mark Cache control

- (void)clearCacheForKey:(NSString *)key cacheKey:(NSString *)cacheKey
{
    // Clear any persisted objects
    BOOL stale;
    NSArray *objects = [self cachedModelObjectsForKey:key stale:&stale cacheKey:cacheKey];
    
    for (NSManagedObject *object in objects) [_managedObjectContext deleteObject:object];
    
    [self.managedObjectContext save:nil];
    
    // Forget last cache misses for this key
    
    NSString *k = key;
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
    
    [_misses removeObjectForKey:k];
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)clearCacheForKey:(NSString *)key
{
    [self clearCacheForKey:key cacheKey:nil];
}

- (void)clearCache
{
    for (NSString *key in _mapping)
        [self clearCacheForKey:key cacheKey:nil];
}

#pragma mark -
#pragma mark Private

- (BOOL)isCacheTimeExceededForTime:(NSDate *)loadTime withKey:(NSString *)key
{
    NSInteger cacheTime = [self cacheTimeForKey:key];
    if (([[NSDate date] timeIntervalSince1970] - [loadTime timeIntervalSince1970]) >= cacheTime) {
        return YES;
    } else {
        return NO;
    }
}

- (NSInteger)cacheTimeForKey:(NSString *)key
{
    NSInteger cacheTime = JP_DATA_DEFAULT_CACHE_TIME;

    NSDictionary *mappingDict = _mapping[key];
    NSNumber *t = mappingDict[@"cache"];
    if (t) cacheTime = [t intValue];

    return cacheTime;
}

- (NSNumber *)lastMissTimeForKey:(NSString *)key withCacheKey:(NSString *)cacheKey
{
    NSString *k = key;
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", key, cacheKey];
    return _misses[k];
}

- (NSNumber *)lastMissTimeForKey:(NSString *)key withID:(NSString *)id_ cacheKey:(NSString *)cacheKey
{
    NSString *k = key;
    if (id_) k = [NSString stringWithFormat:@"%@_%@", k, id_];
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
    return _misses[k];
}

- (void)setMissTimeForKey:(NSString *)key withCacheKey:(NSString *)cacheKey
{
    NSString *k = key;
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
    
    _misses[k] = @([[NSDate date] timeIntervalSince1970]);

    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)setMissTimeForKey:(NSString *)key withID:(NSString *)id_ cacheKey:(NSString *)cacheKey
{
    NSString *k = key;
    if (id_) k = [NSString stringWithFormat:@"%@_%@", k, id_];
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
    _misses[k] = @([[NSDate date] timeIntervalSince1970]);
    
    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale withID:(NSString *)id_ cacheKey:(NSString *)cacheKey
{
    *stale = NO;
    
    NSNumber *lastFetchTime = nil;
    if (id_) {
        lastFetchTime = [self lastMissTimeForKey:key withID:id_ cacheKey:cacheKey];
    } else {
        lastFetchTime = [self lastMissTimeForKey:key withCacheKey:cacheKey];
    }
    
    if (lastFetchTime) {
        // How long until the cache is stale for this fetch type?
        int cacheTime = [self cacheTimeForKey:key];

        if (([[NSDate date] timeIntervalSince1970] - [lastFetchTime doubleValue]) > cacheTime)
            *stale = YES;
    }
    
    NSDictionary *mappingDict = _mapping[key];
    NSString *entityName = mappingDict[@"entity"];
    NSMutableArray *entities = [NSMutableArray array];
    
    if (entityName) {
        [entities addObject:entityName];
    } else if (mappingDict[@"entities"]) {
        [entities addObjectsFromArray:mappingDict[@"entities"]];
    } else {
//        NSLog(@"WARNING no 'entity' or 'entities' specified for key '%@'. Caching disabled.", key);
        return nil;
    }
    
    /*
      Fetch cached objects for each entity associated with this key.
      Checks _keyToManagedObjectMapping to make sure the entity was saved for this key
      and not another.
    */
    
    NSMutableArray *objects = [NSMutableArray array];
    for (NSString *entityName in entities) {
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
        
        NSMutableString *predicateString = [NSMutableString string];
        NSString *k = key;
        if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
        [predicateString appendFormat:@"cacheKey == '%@'", k];
        if (id_) [predicateString appendFormat:@" AND id_ == '%@'", id_];
        request.predicate = [NSPredicate predicateWithFormat:predicateString];
        
        NSArray *results = [self.managedObjectContext executeFetchRequest:request error:nil];
        [objects addObjectsFromArray:results];
    }
    
    if ([objects count] > 0) return [NSArray arrayWithArray:objects];
    return nil;
}

- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale cacheKey:(NSString *)cacheKey
{
    return [self cachedModelObjectsForKey:key stale:stale withID:nil cacheKey:cacheKey];
}

- (NSManagedObject *)cachedModelObjectForKey:(NSString *)key withID:(NSString *)id_ stale:(BOOL *)stale cacheKey:(NSString *)cacheKey
{
    return [[self cachedModelObjectsForKey:key stale:stale withID:id_ cacheKey:cacheKey] lastObject];
}

- (NSArray *)sortModelObjects:(NSArray *)objects withMapping:(NSDictionary *)mappingDict
{
    NSString *order = mappingDict[@"order"];
    if (order == nil) order = [self defaultOrderingPropertyName];
    if (order == nil) return objects; // no sort for this key
    
    NSArray *parts = [order componentsSeparatedByString:@","];
    NSMutableArray *descriptors = [NSMutableArray array];
    
    for (__strong NSString *part in parts) {
        
        BOOL ascending = NO;
        if ([part characterAtIndex:0] == '-') {
            ascending = YES;
            part = [part substringFromIndex:1];
        }
        
        NSSortDescriptor *descriptor = [NSSortDescriptor sortDescriptorWithKey:part ascending:ascending];
        [descriptors addObject:descriptor];
    }
    
    return [objects sortedArrayUsingDescriptors:descriptors];
}

- (NSManagedObject *)managedObjectFromDictionary:(NSDictionary *)dict key:(NSString *)key managedObjectContext:(NSManagedObjectContext *)managedObjectContext;
{
    NSDictionary *mappingDict = _mapping[key];
    NSString *entityName = mappingDict[@"entity"];
    
    if (!entityName) entityName = [self entityNameForJsonData:dict withKey:key];
    if (!entityName) return nil;
    
    // If nil is passed used the main thread's context
    NSManagedObjectContext *context = managedObjectContext;
    if (context == nil) context = self.managedObjectContext;
    
    return [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:context];
}

- (void)cleanMisses
{
    // Discard dead cache entries older than two weeks
    int threshold = 3600 * 24 * 14;
    for (NSString *key in [_misses allKeys]) {
        NSNumber *missTime = _misses[key];
        if (([[NSDate date] timeIntervalSince1970] - [missTime doubleValue]) > threshold)
            [_misses removeObjectForKey:key];
    }
    
    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)associateObject:(NSManagedObject *)object withKey:(NSString *)key cacheKey:(NSString *)cacheKey
{
    NSString *k = key;
    if (cacheKey) k = [NSString stringWithFormat:@"%@_%@", k, cacheKey];
    [object setValue:k forKey:@"cacheKey"];
}

- (void)sendErrorMessage:(NSString *)message toDelegate:(id<JPDataDelegate>)delegate orBlock:(JPDataFetchBlock)block
{
    NSError *error = [NSError errorWithDomain:@"JPData" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    
    if (delegate && [delegate respondsToSelector:@selector(data:didFailWithError:)]) {
        [delegate data:self didFailWithError:error];
    } else if (block) {
        block(nil, error);
    }
}

@end
