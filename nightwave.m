#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const backendURL = @"http://192.168.50.177:3551";

@interface Nightwave : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation Nightwave

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL.absoluteString) return NO;
    NSString *urlString = request.URL.absoluteString;
    
    NSArray *domains = @[@"ol.epicgames.com", @"ol.epicgames.net", @"on.epicgames.com", @"ak.epicgames.com", @"graphql.epicgames.com" /*doesnt work fyi*/];
    for (NSString *domain in domains) {
        if ([urlString containsString:domain]) return YES;
    }
    return NO;
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task {
    NSURLRequest *r = task.currentRequest ?: task.originalRequest;
    return [self canInitWithRequest:r];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    NSURLComponents *components = [NSURLComponents componentsWithString:backendURL];
    if (!components) {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        [self.client URLProtocol:self didFailWithError:err];
        return;
    }

    components.path = self.request.URL.path ?: @"";
    components.query = self.request.URL.query ?: nil;

    NSURL *newURL = components.URL;
    if (!newURL) {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        [self.client URLProtocol:self didFailWithError:err];
        return;
    }
    mutableReq.URL = newURL;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableArray *proto = [cfg.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [proto removeObject:[Nightwave class]];
    cfg.protocolClasses = proto;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
    self.task = [session dataTaskWithRequest:mutableReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            [self.client URLProtocol:self didFailWithError:error];
        } else {
            if (response) [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (data) [self.client URLProtocol:self didLoadData:data];
            [self.client URLProtocolDidFinishLoading:self];
        }
    }];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
}

@end

__attribute__((constructor))
static void initNightwave(void) {
    @try {
        [NSURLProtocol registerClass:[Nightwave class]];
    } @catch (NSException *ex) {}
}
