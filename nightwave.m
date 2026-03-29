#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const backendURL = @"http://192.168.50.177:3551";
static NSString * const backendHost = @"192.168.50.177";
static NSInteger  const backendPort = 3551;

// ─── HTTP/HTTPS via NSURLProtocol ───────────────────────────────────────────

@interface Nightwave : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation Nightwave

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL.absoluteString) return NO;
    NSString *urlString = request.URL.absoluteString;
    NSArray *domains = @[
        @"ol.epicgames.com", @"ol.epicgames.net",
        @"on.epicgames.com", @"ak.epicgames.com",
        @"graphql.epicgames.com"
    ];
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
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]];
        return;
    }
    components.path = self.request.URL.path ?: @"";
    components.query = self.request.URL.query ?: nil;
    NSURL *newURL = components.URL;
    if (!newURL) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]];
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

// ─── WebSocket redirect via NSURLRequest swizzle ────────────────────────────
// NSURLProtocol cannot intercept ws:// or wss:// — we swizzle the URL
// before NSURLSessionWebSocketTask or CFNetwork ever sees it.

static BOOL shouldRedirectWebSocketURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"ws"] && ![scheme isEqualToString:@"wss"]) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSArray *xmppDomains = @[
        @"ol.epicgames.com", @"ol.epicgames.net",
        @"on.epicgames.com", @"ak.epicgames.com"
    ];
    for (NSString *domain in xmppDomains) {
        if ([host hasSuffix:domain]) return YES;
    }
    // also catch anything with "xmpp" in the host or path
    if ([host containsString:@"xmpp"] || [url.path containsString:@"xmpp"]) return YES;
    return NO;
}

static NSURL *redirectedWebSocketURL(NSURL *original) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:original resolvingAgainstBaseURL:NO];
    c.scheme = @"ws";   // backend is plain ws, not wss
    c.host   = backendHost;
    c.port   = @(backendPort);
    return c.URL ?: original;
}

// Swizzle -[NSURLRequest URL] is too broad; instead swizzle the
// NSURLSession webSocketTaskWithURL: and webSocketTaskWithRequest: entrypoints.

static IMP original_webSocketTaskWithURL = NULL;
static IMP original_webSocketTaskWithURLProtocols = NULL;
static IMP original_webSocketTaskWithRequest = NULL;

static id swizzled_webSocketTaskWithURL(id self, SEL _cmd, NSURL *url) {
    if (shouldRedirectWebSocketURL(url)) url = redirectedWebSocketURL(url);
    return ((id(*)(id,SEL,NSURL*))original_webSocketTaskWithURL)(self, _cmd, url);
}

static id swizzled_webSocketTaskWithURLProtocols(id self, SEL _cmd, NSURL *url, NSArray *protocols) {
    if (shouldRedirectWebSocketURL(url)) url = redirectedWebSocketURL(url);
    return ((id(*)(id,SEL,NSURL*,NSArray*))original_webSocketTaskWithURLProtocols)(self, _cmd, url, protocols);
}

static id swizzled_webSocketTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (shouldRedirectWebSocketURL(request.URL)) {
        NSMutableURLRequest *mr = [request mutableCopy];
        mr.URL = redirectedWebSocketURL(request.URL);
        request = mr;
    }
    return ((id(*)(id,SEL,NSURLRequest*))original_webSocketTaskWithRequest)(self, _cmd, request);
}

static void swizzleWebSocketMethods(void) {
    Class cls = NSClassFromString(@"__NSURLSessionLocal");
    if (!cls) cls = objc_getClass("NSURLSession");
    if (!cls) return;

    SEL sel1 = NSSelectorFromString(@"webSocketTaskWithURL:");
    SEL sel2 = NSSelectorFromString(@"webSocketTaskWithURL:protocols:");
    SEL sel3 = NSSelectorFromString(@"webSocketTaskWithRequest:");

    Method m1 = class_getInstanceMethod(cls, sel1);
    Method m2 = class_getInstanceMethod(cls, sel2);
    Method m3 = class_getInstanceMethod(cls, sel3);

    if (m1) original_webSocketTaskWithURL         = method_setImplementation(m1, (IMP)swizzled_webSocketTaskWithURL);
    if (m2) original_webSocketTaskWithURLProtocols = method_setImplementation(m2, (IMP)swizzled_webSocketTaskWithURLProtocols);
    if (m3) original_webSocketTaskWithRequest      = method_setImplementation(m3, (IMP)swizzled_webSocketTaskWithRequest);
}

// ─── Init ────────────────────────────────────────────────────────────────────

__attribute__((constructor))
static void initNightwave(void) {
    @try {
        [NSURLProtocol registerClass:[Nightwave class]];
    } @catch (NSException *ex) {}

    @try {
        swizzleWebSocketMethods();
    } @catch (NSException *ex) {}
}
