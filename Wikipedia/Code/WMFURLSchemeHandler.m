#import "WMFURLSchemeHandler.h"
#import "Wikipedia-Swift.h"
#import <WMF/WMFImageTag.h>
#import <WMF/WMFImageTag+TargetImageWidthURL.h>
#import <WMF/NSString+WMFHTMLParsing.h>
#import <WMF/WMFFIFOCache.h>
#import <WMF/NSURL+WMFSchemeHandler.h>
#import "MWKArticle.h"

static const NSInteger WMFCachedResponseCountLimit = 6;

@interface WMFURLSchemeHandler ()
@property (nonatomic, strong) WMFFIFOCache<NSString *, NSCachedURLResponse *> *responseCache;
@property (nonatomic, strong) WMFFIFOCache<NSString *, MWKArticle *> *articleCache;
@property (nonatomic, copy, nonnull) NSString *hostedFolderPath;
@property (nonatomic, strong) WMFSession *session;
@property (nonatomic, strong) NSMutableSet *activeTasks;
@end

@implementation WMFURLSchemeHandler

+ (WMFURLSchemeHandler *)shared {
    static dispatch_once_t onceToken;
    static WMFURLSchemeHandler *shared;
    dispatch_once(&onceToken, ^{
        shared = [[WMFURLSchemeHandler alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.responseCache = [[WMFFIFOCache alloc] initWithCountLimit:WMFCachedResponseCountLimit];
    self.articleCache = [[WMFFIFOCache alloc] initWithCountLimit:WMFCachedResponseCountLimit];
    self.hostedFolderPath = [WikipediaAppUtils assetsPath];
    self.session = [WMFSession shared];
    self.activeTasks = [[NSMutableSet alloc] init];
}

#pragma mark - Task handling

- (BOOL)isTaskActive:(id<WKURLSchemeTask>)task {
    WMFAssertMainThread(@"isTaskActive must be called on the main thread");
    if (!task) {
        return NO;
    }
    return [self.activeTasks containsObject:task];
}

- (void)finishTask:(id<WKURLSchemeTask>)task withResponse:(nullable NSURLResponse *)response data:(nullable NSData *)data error:(nullable NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isTaskActive:task]) {
            return;
        }
        if (error) {
            [task didFailWithError:error];
        } else if (response) {
            [task didReceiveResponse:response];
            if (data) {
                [task didReceiveData:data];
            }
            [task didFinish];
        } else {
            [task didFailWithError:[WMFFetcher unexpectedResponseError]];
        }
        [self.activeTasks removeObject:task];
    });
}

- (void)finishTask:(id<WKURLSchemeTask>)task withProxiedResponse:(NSURLResponse *)proxiedResponse data:(nullable NSData *)data error:(NSError *)error {
    if (error) {
        [self finishTask:task withResponse:nil data:nil error:error];
        return;
    }
    if (![proxiedResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        [self finishTask:task withResponse:nil data:nil error:[WMFFetcher unexpectedResponseError]];
        return;
    }
    [self finishTask:task withResponse:proxiedResponse data:data];
}

- (void)finishTask:(id<WKURLSchemeTask>)task withResponse:(NSURLResponse *)response data:(nullable NSData *)data {
    [self finishTask:task withResponse:response data:data error:nil];
}

- (void)finishTask:(id<WKURLSchemeTask>)task withCachedResponse:(NSCachedURLResponse *)cachedResponse {
    [self finishTask:task withResponse:cachedResponse.response data:cachedResponse.data];
}

- (void)finishTask:(id<WKURLSchemeTask>)task withError:(NSError *)error {
    [self finishTask:task withResponse:nil data:nil error:error];
}

- (void)finishTaskWith404:(id<WKURLSchemeTask>)task requestURL:(NSURL *)requestURL {
    [self finishTask:task withResponse:[[NSHTTPURLResponse alloc] initWithURL:requestURL statusCode:404 HTTPVersion:nil headerFields:nil] data:nil error:nil];
}

#pragma mark - Specific Handlers

- (void)handleAPIRequestForURL:(NSURL *)URL task:(id<WKURLSchemeTask>)task {
    NSAssert(URL, @"Wikipedia API URL should not be nil");
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setValue:[WikipediaAppUtils versionedUserAgent] forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *APIRequestTask = [self.session chunkingDataTaskWith:request response:^(NSURLSessionTask * _Nonnull sessionTask, NSURLResponse * _Nonnull response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isTaskActive:task]) {
                return;
            }
            
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode != 200) {
                    [sessionTask cancel];
                    //todo: get rid of this error when we move to swift
                    NSError *error = [NSError errorWithDomain:@"Scheme Handler Error" code:1 userInfo:nil];
                    [task didFailWithError:error];
                } else {
                    [task didReceiveResponse:response];
                }
            }
        });
    } data:^(NSData * _Nonnull data) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isTaskActive:task]) {
                return;
            }
            
            [task didReceiveData:data];
        });
    } success:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isTaskActive:task]) {
                return;
            }
            
            [task didFinish];
            
            [self.activeTasks removeObject:task];
        });
    } failure:^(NSURLSessionTask * _Nonnull sessionTask, NSError * _Nonnull error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isTaskActive:task]) {
                return;
            }
            
            [sessionTask cancel];
            [task didFailWithError:error];
            
            [self.activeTasks removeObject:task];
        });
    }];
    
    APIRequestTask.priority = NSURLSessionTaskPriorityLow;
    [APIRequestTask resume];
}

- (void)handleFileRequestForRelativePath:(NSString *)relativePath requestURL:(NSURL *)requestURL task:(id<WKURLSchemeTask>)task {
    if ([relativePath containsString:@".."]) {
        [self finishTaskWith404:task requestURL:requestURL];
        return;
    }
    NSCachedURLResponse *cachedResponse = [self cachedResponseForPath:relativePath];
    if (cachedResponse == nil) {
        NSString *fullPath = [self.hostedFolderPath stringByAppendingPathComponent:relativePath];
        NSURL *localFileURL = [NSURL fileURLWithPath:fullPath];
        NSNumber *isRegularFile = nil;
        NSError *fileReadError = nil;
        if ([localFileURL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:&fileReadError] && [isRegularFile boolValue]) {
            NSData *data = [NSData dataWithContentsOfURL:localFileURL];
            NSMutableDictionary<NSString *, NSString *> *headerFields = [NSMutableDictionary dictionaryWithCapacity:1];
            NSDictionary *types = @{@"css": @"text/css; charset=utf-8", @"html": @"text/html; charset=utf-8", @"js": @"application/javascript; charset=utf-8"};
            NSString *pathExtension = [localFileURL pathExtension];
            if (pathExtension) {
                [headerFields setValue:types[pathExtension] forKey:@"Content-Type"];
            }
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:requestURL statusCode:200 HTTPVersion:nil headerFields:headerFields];
            [self cacheResponse:response data:data forPath:relativePath];
            [self finishTask:task withResponse:response data:data];
        } else {
            [self finishTaskWith404:task requestURL:requestURL];
        }
    } else {
        [self finishTask:task withCachedResponse:cachedResponse];
    }
}

- (void)handleProxiedRequest:(NSURLRequest *)request task:(id<WKURLSchemeTask>)task {
    NSAssert(request, @"proxied request should not be nil");
    NSURLCache *URLCache = [NSURLCache sharedURLCache];
    NSCachedURLResponse *cachedResponse = [URLCache cachedResponseForRequest:request];
    if (cachedResponse.response && cachedResponse.data) {
        [self finishTask:task withCachedResponse:cachedResponse];
    } else {
        
        NSURLSessionDataTask *downloadTask = [self.session chunkingDataTaskWith:request response:^(NSURLSessionTask * _Nonnull sessionTask, NSURLResponse * _Nonnull response) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isTaskActive:task]) {
                    return;
                }
                
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                    if (httpResponse.statusCode != 200) {
                        [sessionTask cancel];
                        //todo: get rid of this error when we move to swift
                        NSError *error = [NSError errorWithDomain:@"Scheme Handler Error" code:1 userInfo:nil];
                        [task didFailWithError:error];
                    } else {
                        [task didReceiveResponse:response];
                    }
                }
            });
        } data:^(NSData * _Nonnull data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isTaskActive:task]) {
                    return;
                }
                
                [task didReceiveData:data];
            });
        } success:^{
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isTaskActive:task]) {
                    return;
                }
                
                [task didFinish];
                
                [self.activeTasks removeObject:task];
            });
        } failure:^(NSURLSessionTask * _Nonnull sessionTask, NSError * _Nonnull error) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isTaskActive:task]) {
                    return;
                }
                
                [sessionTask cancel];
                [task didFailWithError:error];
                
                [self.activeTasks removeObject:task];
            });
        }];
        
        [downloadTask resume];
    }
}

#pragma - File Proxy Paths &URLs

- (NSURLComponents *)baseURLComponents {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = WMFURLSchemeHandlerScheme;
    components.host = @"host";
    return components;
}

- (NSURL *)appSchemeURLForRelativeFilePath:(NSString *)relativeFilePath fragment:(NSString *)fragment {
    if (relativeFilePath == nil) {
        return nil;
    }

    NSURLComponents *components = [self baseURLComponents];
    components.path = [NSString pathWithComponents:@[@"/", WMFAppSchemeFileBasePath, relativeFilePath]];
    components.fragment = fragment;
    return components.URL;
}

- (NSURL *)appSchemeURLForWikipediaAPIHost:(NSString *)host {
    NSURLComponents *components = [self baseURLComponents];
    components.path = [NSString pathWithComponents:@[@"/", WMFAppSchemeAPIBasePath, host]];
    return components.URL;
}

#pragma - Article Section Data URLs

- (nullable NSURL *)articleSectionDataURLForArticleWithURL:(NSURL *)articleURL targetImageWidth:(NSInteger)targetImageWidth {
    NSString *key = articleURL.wmf_articleDatabaseKey;
    if (key == nil) {
        return nil;
    }
    NSURLComponents *components = [self baseURLComponents];
    components.path = [NSString pathWithComponents:@[@"/", WMFSchemeHandlerArticleSectionDataBasePath]];
    NSURLQueryItem *articleKeyQueryItem = [NSURLQueryItem queryItemWithName:WMFSchemeHandlerArticleKeyQueryItem value:key];
    NSString *imageWidthString = [NSString stringWithFormat:@"%lli", (long long)targetImageWidth];
    NSURLQueryItem *imageWidthQueryItem = [NSURLQueryItem queryItemWithName:WMFSchemeHandlerImageWidthQueryItem value:imageWidthString];
    if (!articleKeyQueryItem || !imageWidthString) {
        return nil;
    }

    components.queryItems = @[articleKeyQueryItem, imageWidthQueryItem];

    return components.URL;
}

#pragma - Image Proxy URLs

- (NSString *)stringByReplacingImageURLsWithAppSchemeURLsInHTMLString:(NSString *)HTMLString withBaseURL:(nullable NSURL *)baseURL targetImageWidth:(NSUInteger)targetImageWidth {

    //defensively copy
    HTMLString = [HTMLString copy];

    NSMutableString *newHTMLString = [NSMutableString stringWithString:@""];
    __block NSInteger location = 0;
    [HTMLString wmf_enumerateHTMLImageTagContentsWithHandler:^(NSString *imageTagContents, NSRange range) {
        //append the next chunk that we didn't match on to the new string
        NSString *nonMatchingStringToAppend = [HTMLString substringWithRange:NSMakeRange(location, range.location - location)];
        [newHTMLString appendString:nonMatchingStringToAppend];

        //update imageTagContents by changing the src, disabling the srcset, and adding other attributes used for scaling
        NSString *newImageTagContents = [self stringByUpdatingImageTagAttributesForProxyAndScalingInImageTagContents:imageTagContents withBaseURL:baseURL targetImageWidth:targetImageWidth];
        //append the updated image tag to the new string
        [newHTMLString appendString:[@[@"<img ", newImageTagContents, @">"] componentsJoinedByString:@""]];

        location = range.location + range.length;
    }];

    //append the final chunk of the original string
    if (HTMLString && location < HTMLString.length) {
        [newHTMLString appendString:[HTMLString substringWithRange:NSMakeRange(location, HTMLString.length - location)]];
    }

    return newHTMLString;
}

- (NSString *)stringByUpdatingImageTagAttributesForProxyAndScalingInImageTagContents:(NSString *)imageTagContents withBaseURL:(NSURL *)baseURL targetImageWidth:(NSUInteger)targetImageWidth {

    NSMutableString *newImageTagContents = [imageTagContents mutableCopy];

    NSString *resizedSrc = nil;

    WMFImageTag *imageTag = [[WMFImageTag alloc] initWithImageTagContents:imageTagContents baseURL:baseURL];

    if (imageTag != nil) {
        NSString *src = imageTag.src;

        if ([imageTag isSizeLargeEnoughForGalleryInclusion]) {
            resizedSrc = [[imageTag URLForTargetWidth:targetImageWidth] absoluteString];
            if (resizedSrc) {
                src = resizedSrc;
            }
        }

        if (src) {
            NSString *srcWithProxy = [NSURL wmf_appSchemeURLForURLString:src].absoluteString;
            if (srcWithProxy) {
                NSString *newSrcAttribute = [@[@"src=\"", srcWithProxy, @"\""] componentsJoinedByString:@""];
                imageTag.src = newSrcAttribute;
                newImageTagContents = [imageTag.imageTagContents mutableCopy];
            }
        }
    }

    [newImageTagContents replaceOccurrencesOfString:@"srcset" withString:@"data-srcset-disabled" options:0 range:NSMakeRange(0, newImageTagContents.length)]; //disable the srcset since we put the correct resolution image in the src

    if (resizedSrc) {
        [newImageTagContents appendString:@" data-image-gallery=\"true\""]; //the javascript looks for this to know if it should attempt widening
    }

    return newImageTagContents;
}

#pragma mark - Cache

- (void)setResponseData:(nullable NSData *)data withContentType:(nullable NSString *)contentType forPath:(NSString *)path requestURL:(NSURL *)requestURL {
    NSMutableDictionary<NSString *, NSString *> *headerFields = [NSMutableDictionary dictionaryWithCapacity:1];
    if (contentType) {
        headerFields[@"Content-Type"] = contentType;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:requestURL statusCode:200 HTTPVersion:nil headerFields:headerFields];
    [self cacheResponse:response data:data forPath:path];
}

- (void)cacheResponse:(NSURLResponse *)response data:(NSData *)data forPath:(NSString *)path {
    if (path == nil) {
        return;
    }
    NSCachedURLResponse *cachedResponse = [[NSCachedURLResponse alloc] initWithResponse:response data:data];
    [self.responseCache setObject:cachedResponse forKey:path];
}

- (NSCachedURLResponse *)cachedResponseForPath:(NSString *)path {
    if (path == nil) {
        return nil;
    }
    return [self.responseCache objectForKey:path];
}

- (void)cacheSectionDataForArticle:(MWKArticle *)article {
    NSString *articleKey = article.url.wmf_articleDatabaseKey;
    if (articleKey == nil) {
        return;
    }
    [self.articleCache setObject:article forKey:articleKey];
}

- (MWKArticle *)articleForKey:(NSString *)path {
    if (path == nil) {
        return nil;
    }
    return [self.articleCache objectForKey:path];
}

#pragma mark - BaseURL (for testing only)

- (NSURL *)baseURL {
    return [[self baseURLComponents] URL];
}

- (void)webView:(nonnull WKWebView *)webView startURLSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask {
    WMFAssertMainThread(@"startURLSchemeTask assumed to be called on the main thread");

    [self.activeTasks addObject:urlSchemeTask];

    NSURLRequest *request = [urlSchemeTask request];
    NSURL *requestURL = [request URL];
    if (!requestURL) {
        [urlSchemeTask didFailWithError:[WMFFetcher invalidParametersError]];
        return;
    }

    dispatch_block_t notFound = ^{
        [urlSchemeTask didFailWithError:[WMFFetcher invalidParametersError]];
    };

    NSURLComponents *URLComponents = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
    NSString *path = URLComponents.path;
    NSArray *components = [path pathComponents];

    if (components.count < 2) { //ensure components exist and there are at least three
        notFound();
        return;
    }

    NSString *baseComponent = components[1];

    if ([baseComponent isEqualToString:WMFAppSchemeFileBasePath]) {
        NSArray *localPathComponents = [components subarrayWithRange:NSMakeRange(2, components.count - 2)];
        NSString *relativePath = [NSString pathWithComponents:localPathComponents];
        [self handleFileRequestForRelativePath:relativePath requestURL:requestURL task:urlSchemeTask];
    } else if ([baseComponent isEqualToString:WMFSchemeHandlerArticleSectionDataBasePath]) {
        NSString *articleKey = [request.URL wmf_valueForQueryKey:WMFSchemeHandlerArticleKeyQueryItem];
        if (!articleKey) {
            notFound();
            return;
        }
        MWKArticle *article = [self articleForKey:articleKey];
        if (!article) {
            notFound();
            return;
        }
        NSString *imageWidthString = [request.URL wmf_valueForQueryKey:WMFSchemeHandlerImageWidthQueryItem];
        if (!imageWidthString) {
            notFound();
            return;
        }
        NSInteger imageWidth = [imageWidthString integerValue];
        if (imageWidth <= 0) {
            notFound();
            return;
        }
        MWKSectionList *sections = article.sections;
        NSInteger count = sections.count;
        NSMutableArray *sectionJSONs = [NSMutableArray arrayWithCapacity:count];
        NSURL *baseURL = article.url;
        for (MWKSection *section in sections) {
            NSString *sectionHTML = [self stringByReplacingImageURLsWithAppSchemeURLsInHTMLString:section.text withBaseURL:baseURL targetImageWidth:imageWidth];
            if (!sectionHTML) {
                continue;
            }
            NSMutableDictionary *sectionJSON = [NSMutableDictionary dictionaryWithCapacity:5];
            sectionJSON[@"id"] = @(section.sectionId);
            sectionJSON[@"line"] = section.line;
            sectionJSON[@"level"] = section.level;
            sectionJSON[@"anchor"] = section.anchor;
            sectionJSON[@"text"] = sectionHTML;
            [sectionJSONs addObject:sectionJSON];
        }
        NSMutableDictionary *responseJSON = [NSMutableDictionary dictionaryWithCapacity:1];
        NSMutableDictionary *mobileviewJSON = [NSMutableDictionary dictionaryWithCapacity:1];
        mobileviewJSON[@"sections"] = sectionJSONs;
        responseJSON[@"mobileview"] = mobileviewJSON;
        NSError *JSONError = nil;
        NSData *JSONData = [NSJSONSerialization dataWithJSONObject:responseJSON options:0 error:&JSONError];
        if (!JSONData) {
            DDLogError(@"Error serializing mobileview JSON: %@", JSONError);
            notFound();
            return;
        }
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:requestURL statusCode:200 HTTPVersion:nil headerFields:@{@"Content-Type": @"application/json; charset=utf-8"}];
        [self finishTask:urlSchemeTask withResponse:response data:JSONData];
    } else if ([baseComponent isEqualToString:WMFAppSchemeAPIBasePath]) {
        NSAssert(components.count == 5, @"Expected 5 components when using WMFAppSchemeAPIBasePath");
        if (components.count == 5) {

            // APIURL is APIProxyURL with components[3] as the host, components[4..5] as the path.
            NSURLComponents *APIProxyURLComponents = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
            APIProxyURLComponents.path = [NSString pathWithComponents:@[@"/", components[3], components[4]]];
            APIProxyURLComponents.host = components[2];
            APIProxyURLComponents.scheme = @"https";
            NSURL *APIURL = APIProxyURLComponents.URL;
            [self handleAPIRequestForURL:APIURL task:urlSchemeTask];
            return;
        }
        notFound();
    } else {
        NSURL *proxiedURL = [requestURL wmf_originalURLFromAppSchemeURL];
        if (!proxiedURL) {
            notFound();
            return;
        }
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        mutableRequest.URL = proxiedURL;
        [self handleProxiedRequest:mutableRequest task:urlSchemeTask];
    }
}

- (void)webView:(nonnull WKWebView *)webView stopURLSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask {
    WMFAssertMainThread(@"stopURLSchemeTask assumed to be called on the main thread");
    DDLogDebug(@"stopURLSchemeTask %@", urlSchemeTask);
    [self.activeTasks removeObject:urlSchemeTask];
}

@end
