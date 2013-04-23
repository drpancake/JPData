//
//  JPData.m
//  Takota
//
//  Created by James Potter on 22/04/2013.
//  Copyright (c) 2013 Takota. All rights reserved.
//

#import <objc/runtime.h>
#import "JPData.h"
#import "NSDictionary+UrlEncoding.h"

@interface JPData ()

- (NSManagedObject *)managedObjectFromDictionary:(NSDictionary *)dict key:(NSString *)key;
- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data;

// Returns YES if elapsed duration between 'loadTime' and now has exceeded cache time given key
- (BOOL)isCacheTimeExceededForTime:(NSDate *)loadTime withKey:(NSString *)key;

/*
  Returns nil if no objects are cached. 'stale' is a pointer to a BOOL and
  indicates that returned objects are old/stale.
*/
- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale withID:(NSNumber *)id_;
- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale;
- (NSManagedObject *)cachedModelObjectForKey:(NSString *)key withID:(NSNumber *)id_ stale:(BOOL *)stale;

// If mapping contains the key 'order' the objects will be sorted using that as a keyPath
- (NSArray *)sortModelObjects:(NSArray *)objects withMapping:(NSDictionary *)mappingDict;

// All times in Unix format
- (NSNumber *)lastMissTimeForKey:(NSString *)key;
- (NSNumber *)lastMissTimeForKey:(NSString *)key withID:(NSNumber *)id_;
- (void)setMissTimeForKey:(NSString *)key; // sets it to now
- (void)setMissTimeForKey:(NSString *)key withID:(NSNumber *)id_; // sets it to now

// How long this key's data is fresh for
- (NSInteger)cacheTimeForKey:(NSString *)key;

// Discards dead cache entries older than two weeks
- (void)cleanMisses;

// Clean up any orphaned IDs which no longer exist as objects in Core Data
- (void)cleanManagedObjectKeys;

- (void)associateObject:(NSManagedObject *)object withKey:(NSString *)key;

- (void)sendErrorMessage:(NSString *)message toDelegate:(id<JPDataDelegate>)delegate;

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
        _mapping = [JPData keyMappings];
        
        _keyToManagedObjectMapping = [_def objectForKey:JP_DATA_MANAGED_OBJECT_KEYS];
        if (_keyToManagedObjectMapping == nil) {
            _keyToManagedObjectMapping = [NSMutableDictionary dictionary];
        } else {
            [self cleanManagedObjectKeys];
        }
        
        _misses = [_def objectForKey:JP_DATA_MISSES_KEY];
        if (_misses == nil) {
            _misses = [NSMutableDictionary dictionary];
        } else {
            [self cleanMisses];
        }
    }
    return self;
}

+ (JPData *)sharedData
{
    static JPData *instance = nil;
    if (instance == nil) {
        instance = [[JPData alloc] init];
    }
    return instance;
}

#pragma mark -
#pragma mark Methods for subclassing

+ (NSDictionary *)keyMappings
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

- (NSArray *)dictionariesFromResult:(NSDictionary *)result
{
    NSArray *dicts = nil;
    if (result) dicts = @[result];
    return dicts;
}

- (NSDictionary *)dictionaryFromResult:(NSDictionary *)result
{
    return result;
}

- (NSString *)entityNameForKey:(NSString *)key jsonData:(NSDictionary *)dict
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

- (void)didReceiveHTTPStatusCode:(NSInteger)statusCode
{
    
}

- (BOOL)willSetValue:(id)value forProperty:(NSString *)propertyName inObject:(NSManagedObject *)object
{
    return YES;
}

- (void)setValue:(id)value forSpecialProperty:(NSString *)propertyName inObject:(NSManagedObject *)object
{
    
}

#pragma mark -
#pragma mark Fetch methods

- (void)fetchMany:(NSString *)key withParams:(NSDictionary *)params append:(BOOL)append delegate:(id<JPDataDelegate>)delegate
{
    NSDictionary *mappingDict = _mapping[key];
    if (mappingDict == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unknown key '%@' for method %@.", key, NSStringFromSelector(_cmd)];
    }
    
    // Attempt to fetch cached objects for this key
    BOOL stale;
    NSArray *cachedObjects = [self cachedModelObjectsForKey:key stale:&stale];
    
    /*
      If we have any objects stored in the cache for this key, then send them straight to our delegate
      object regardless of freshness, unless append=YES in which case we fetch fresh objects anyway and
      append them to any cached objects we might have.
    */
    
    if (append == NO && (cachedObjects && [cachedObjects count] > 0)) {
        NSArray *sorted = [self sortModelObjects:cachedObjects withMapping:mappingDict];
        
        if (stale) {
            if ([delegate respondsToSelector:@selector(data:didReceiveStaleObjects:)])
                [delegate data:self didReceiveStaleObjects:sorted];
        } else {
            if ([delegate respondsToSelector:@selector(data:didReceiveObjects:more:)])
                [delegate data:self didReceiveObjects:sorted more:NO];
            
            // The cache is fresh so we don't need to do anything else
            return;
        }
    }
    
    /*
      At this point, either the cache was empty (i.e. this is the initial fetch for this key), the
      returned objects are stale and need updating OR append=YES and we're adding new objects.
     
      In any case, we need to perform an API call.
    */
    
    [self requestWithMethod:@"GET" endpoint:mappingDict[@"endpoint"] params:params completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            
            if ([delegate respondsToSelector:@selector(data:didFailWithError:)])
                [delegate data:self didFailWithError:error];
            
        } else {
            NSMutableArray *newObjects = [NSMutableArray array];
            
            // -- Delete previously stored objects, unless append=YES in which case we add to them --
            
            if (!append) {
                for (NSManagedObject *object in cachedObjects)
                    [_managedObjectContext deleteObject:object];
            } else if (cachedObjects != nil) {
                [newObjects addObjectsFromArray:cachedObjects];
            }
            
            // -- Convert JSON into model objects --
            
            for (NSDictionary *dict in [self dictionariesFromResult:result]) {
                
                // Sanity check
                if (![dict isKindOfClass:[NSDictionary class]]) {
                    NSLog(@"WARNING: expecting a dictionary from dictionariesFromResult: but found '%@'",
                          NSStringFromClass([dict class]));
                    continue;
                }
                
                NSManagedObject *object = [self managedObjectFromDictionary:dict key:key];
                if (object == nil) continue;
                
                [self populateModelObject:object withData:dict];
                [newObjects addObject:object];
            }
            
            [_managedObjectContext save:nil];
            
            // Keep track of which key these objects are associated with (must be done after saving)
            for (NSManagedObject *object in newObjects)
                [self associateObject:object withKey:key];
            
            // Update cache miss time, even if we're appending objects to possibly stale cached objects --
            [self setMissTimeForKey:key];
            
            // -- Send objects to delegate --
            
            // Are there more results to fetch after this?
            BOOL more = [self serverHasMoreAfterResult:result];
            
            NSArray *sorted = [self sortModelObjects:newObjects withMapping:mappingDict];
            if ([delegate respondsToSelector:@selector(data:didReceiveObjects:more:)])
                [delegate data:self didReceiveObjects:sorted more:more];
        }
    }];
}

- (void)fetch:(NSString *)key withID:(NSNumber *)id_ params:(NSDictionary *)params delegate:(id<JPDataDelegate>)delegate
{
    NSDictionary *mappingDict = _mapping[key];
    if (mappingDict == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Unknown key '%@' for method %@.", key, NSStringFromSelector(_cmd)];
    }
    
    // Attempt to fetch cached objects for this key
    BOOL stale;
    NSManagedObject *cachedObject = [self cachedModelObjectForKey:key withID:id_ stale:&stale];
    
    // If we have an object stored in the cache for this key, then send it straight to our delegate
    
    if (cachedObject) {
        if (stale) {
            if ([delegate respondsToSelector:@selector(data:didReceiveStaleObject:)])
                [delegate data:self didReceiveStaleObject:cachedObject];
        } else {
            if ([delegate respondsToSelector:@selector(data:didReceiveObject:)])
                [delegate data:self didReceiveObject:cachedObject];
            
            // The cache is fresh so we don't need to do anything else
            return;
        }
    }
    
    /*
     At this point, either the cache was empty (i.e. this is the initial fetch for this key) OR the
     returned object is stale and needs updating.
     
     In any case, we need to perform an API call.
     */
    
    NSString *endpoint = [NSString stringWithFormat:@"%@/%@", mappingDict[@"endpoint"], id_];
    
    [self requestWithMethod:@"GET" endpoint:endpoint params:params completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            if ([delegate respondsToSelector:@selector(data:didFailWithError:)])
                [delegate data:self didFailWithError:error];
            return;
        }
        
        NSDictionary *dict = [self dictionaryFromResult:result];
        
        if (dict == nil) {
            NSString *msg = [NSString stringWithFormat:@"Empty dictionary received for endpoint '%@'", endpoint];
            [self sendErrorMessage:msg toDelegate:delegate];
            return;
        }
        
        if (![dict isKindOfClass:[NSDictionary class]]) {
            NSString *msg = [NSString stringWithFormat:@"Expecting a dictionary for endpoint '%@' but found '%@'",
                             endpoint, NSStringFromClass([result class])];
            [self sendErrorMessage:msg toDelegate:delegate];
            return;
        }
        
        @try {
            // Delete cached object if there is one
            if (cachedObject) [self.managedObjectContext deleteObject:cachedObject];
            
            // -- Convert JSON to Core Data model object --
            
            NSManagedObject *object = [self managedObjectFromDictionary:dict key:key];
            
            if (object == nil) {
                NSString *msg = [NSString stringWithFormat:@"Unable to create object for endpoint '%@'.", endpoint];
                [self sendErrorMessage:msg toDelegate:delegate];
                return;
            }
            
            [self populateModelObject:object withData:dict];
            [_managedObjectContext save:nil];
            
            // Keep track of which key this object is associated with (must be done after saving)
            [self associateObject:object withKey:key];
            
            // -- Update cache miss time and send to delegate --
            
            [self setMissTimeForKey:key withID:id_];
            
            if ([delegate respondsToSelector:@selector(data:didReceiveObject:)])
                [delegate data:self didReceiveObject:object];
            
        } @catch (NSException *exception) {
            NSString *msg = [NSString stringWithFormat:@"Problem communicating with the server. [%@]", exception.reason];
            [self sendErrorMessage:msg toDelegate:delegate];
        }
    }];
}

#pragma mark -
#pragma mark Helper methods

- (void)requestWithMethod:(NSString *)method
                 endpoint:(NSString *)endpoint
                   params:(NSDictionary *)params
               completion:(JPDataRequestBlock)requestBlock
{
    NSString *baseString = [[self baseURL] absoluteString];
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@%@", baseString, endpoint];
    if ([method isEqualToString:@"GET"] && params) {
        [urlString appendFormat:@"?%@", [params urlEncodedString]];
    }
    
    if (self.debug) NSLog(@"REQ: %@", urlString);
    
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    [request setHTTPMethod:method];
    
    if ([method isEqualToString:@"POST"] && params) {
        NSString *paramsString = [params urlEncodedString];
        NSData *requestData = [NSData dataWithBytes:[paramsString UTF8String] length:[paramsString length]];
        [request setHTTPBody:requestData];
        
        if (self.debug) NSLog(@"--> PARAMS: %@", paramsString);
    }
    
    if ([method isEqualToString:@"POST"])
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"content-type"];
    
    // Last chance for subclasses to customise the request
    [self willSendRequest:request];
    
    // Show the status bar spinner
    UIApplication *app = [UIApplication sharedApplication];
    app.networkActivityIndicatorVisible = YES;
    
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *responseData, NSError *error) {
                               NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                               if (error && error.code == NSURLErrorUserCancelledAuthentication) statusCode = 401;
                               
                               [self didReceiveHTTPStatusCode:statusCode];
                               
                               // Hide the spinner
                               app.networkActivityIndicatorVisible = NO;
                               
                               if (statusCode == 200) {
                                   
                                   NSDictionary *result = nil;
                                   if (!error) {
                                       // JSON -> dictionary
                                       NSString *text = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];
                                       result = [_parser objectWithString:text];
                                   }
                                   
                                   requestBlock(result, nil);
                                   
                               } else if (statusCode == 400 || statusCode == 404) {
                                   NSString *text = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];
                                   NSDictionary *json = [_parser objectWithString:text];
                                   NSString *message;
                                   if (json && json[@"error"] != nil) {
                                       message = json[@"error"];
                                   } else {
                                       message = @"There was a problem connecting to the server.";
                                   }
                                   
                                   NSDictionary *userInfo = @{NSLocalizedDescriptionKey : message};
                                   error = [NSError errorWithDomain:@"Urbantribe" code:1 userInfo:userInfo];
                                   requestBlock(nil, error);
                                   
                               } else {
                                   requestBlock(nil, error);
                               }
                           }];
}

#pragma mark -
#pragma mark Cache control

- (void)clearCacheForKey:(NSString *)key
{
    // Clear any persisted objects
    BOOL stale;
    NSArray *objects = [self cachedModelObjectsForKey:key stale:&stale];
    for (NSManagedObject *object in objects) [self.managedObjectContext deleteObject:object];
    [self.managedObjectContext save:nil];
    
    // Forget last cache misses for this key
    [_misses removeObjectForKey:key];
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)clearCache
{
    for (NSString *key in _mapping)
        [self clearCacheForKey:key];
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

- (NSNumber *)lastMissTimeForKey:(NSString *)key
{
    return _misses[key];
}

- (NSNumber *)lastMissTimeForKey:(NSString *)key withID:(NSNumber *)id_
{
    NSString *k = [NSString stringWithFormat:@"%@_%@", key, id_];
    return _misses[k];
}

- (void)setMissTimeForKey:(NSString *)key
{
    _misses[key] = @([[NSDate date] timeIntervalSince1970]);

    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)setMissTimeForKey:(NSString *)key withID:(NSNumber *)id_
{
    NSString *k = [NSString stringWithFormat:@"%@_%@", key, id_];
    _misses[k] = @([[NSDate date] timeIntervalSince1970]);
    
    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale withID:(NSNumber *)id_
{
    *stale = NO;
    
    NSNumber *lastFetchTime = nil;
    if (id_) {
        lastFetchTime = [self lastMissTimeForKey:key withID:id_];
    } else {
        lastFetchTime = [self lastMissTimeForKey:key];
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
    } else {
        [entities addObjectsFromArray:[mappingDict[@"entities"] allValues]];
    }
    
    NSAssert([entities count] > 0, @"Expecting entities for key '%@'", key);
    
    /*
      Fetch cached objects for each entity associated with this key.
      Checks _keyToManagedObjectMapping to make sure the entity was saved for this key
      and not another.
    */
    
    NSMutableArray *objects = [NSMutableArray array];
    for (NSString *entityName in entities) {
        
        NSArray *objectIDs = _keyToManagedObjectMapping[key];
        if (objectIDs == nil || [objectIDs count] < 1) continue;
        
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
        request.predicate = [NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
            NSManagedObject *object = evaluatedObject;
            
            BOOL valid = [objectIDs containsObject:object.objectID.URIRepresentation];
            if (id_ && ![[object valueForKey:@"id_"] isEqual:id_]) valid = NO;
            
            return valid;
        }];
        
        NSArray *results = [self.managedObjectContext executeFetchRequest:request error:nil];
        [objects addObjectsFromArray:results];
    }
    
    if ([objects count] > 0) return [NSArray arrayWithArray:objects];
    return nil;
}

- (NSArray *)cachedModelObjectsForKey:(NSString *)key stale:(BOOL *)stale
{
    return [self cachedModelObjectsForKey:key stale:stale withID:nil];
}

- (NSManagedObject *)cachedModelObjectForKey:(NSString *)key withID:(NSNumber *)id_ stale:(BOOL *)stale
{
    return [[self cachedModelObjectsForKey:key stale:stale withID:id_] lastObject];
}

- (NSArray *)sortModelObjects:(NSArray *)objects withMapping:(NSDictionary *)mappingDict
{
    NSString *order = mappingDict[@"order"];
    if (order == nil) order = [self defaultOrderingPropertyName];
    if (order == nil) return objects; // no sort for this key
    
    NSSortDescriptor *descriptor = [NSSortDescriptor sortDescriptorWithKey:order ascending:NO];
    return [objects sortedArrayUsingDescriptors:@[descriptor]];
}

- (NSManagedObject *)managedObjectFromDictionary:(NSDictionary *)dict key:(NSString *)key
{
    NSDictionary *mappingDict = _mapping[key];
    NSString *entityName = mappingDict[@"entity"];
    
    // When 
    if (!entityName) entityName = [self entityNameForKey:key jsonData:dict];
    if (!entityName) return nil;
    
    return [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:self.managedObjectContext];
}

- (void)populateModelObject:(NSManagedObject *)object withData:(NSDictionary *)data
{
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
        
        // JSON keys of type NSDictionary should be handled by subclass, as they're probably
        // needing to be turned into Core Data models
        if ([value isKindOfClass:[NSDictionary class]]) {
            [self setValue:value forSpecialProperty:propertyName inObject:object];
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

- (void)cleanMisses
{
    // Discard dead cache entries older than two weeks
    int threshold = 3600 * 24 * 14;
    for (id key in [_misses allKeys]) {
        NSNumber *missTime = _misses[key];
        if (([[NSDate date] timeIntervalSince1970] - [missTime doubleValue]) > threshold)
            [_misses removeObjectForKey:key];
    }
    
    // Persist
    [_def setObject:_misses forKey:JP_DATA_MISSES_KEY];
    [_def synchronize];
}

- (void)cleanManagedObjectKeys
{
    for (id key in [_keyToManagedObjectMapping allKeys]) {
        for (NSString *s in _keyToManagedObjectMapping[key]) {
            NSManagedObjectID *objectID = [_managedObjectContext.persistentStoreCoordinator
                                           managedObjectIDForURIRepresentation:[NSURL URLWithString:s]];
            NSError *error = nil;
            NSManagedObject *object = [_managedObjectContext existingObjectWithID:objectID error:&error];
            if (error != nil || object == nil) {
                NSLog(@"clean it! err = %@", error);
            }
        }
    }
    
    [_def setObject:_keyToManagedObjectMapping forKey:JP_DATA_MANAGED_OBJECT_KEYS];
    [_def synchronize];
}

- (void)associateObject:(NSManagedObject *)object withKey:(NSString *)key
{
    /*
      This method associates the Core Data assigned UUID of 'object' with the key that was used
      to fetch the given object. This is required so that the same Core Data entities can be
      used across multiple keys.
    */
    
    NSArray *idStrings = _keyToManagedObjectMapping[key];
    NSMutableArray *newStrings = [NSMutableArray array];
    if (idStrings != nil) [newStrings addObjectsFromArray:idStrings];
    
    [newStrings addObject:[object.objectID.URIRepresentation absoluteString]];
    _keyToManagedObjectMapping[key] = newStrings;
    
    // Persist
    [_def setObject:_keyToManagedObjectMapping forKey:JP_DATA_MANAGED_OBJECT_KEYS];
    [_def synchronize];
}

- (void)sendErrorMessage:(NSString *)message toDelegate:(id<JPDataDelegate>)delegate
{
    NSError *error = [NSError errorWithDomain:@"JPDataError" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    
    if ([delegate respondsToSelector:@selector(data:didFailWithError:)])
        [delegate data:self didFailWithError:error];
}

@end
