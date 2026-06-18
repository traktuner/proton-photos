#import "ApplePrivateGridBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *PPDiagnostics = @"Not loaded";
static BOOL PPDidAttemptLoad = NO;
static BOOL PPLoaded = NO;

static void PPCallVoid(id object, SEL selector) {
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static void PPCallVoidInteger(id object, SEL selector, NSInteger value) {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
}

static void PPCallVoidDouble(id object, SEL selector, double value) {
    ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

static void PPCallVoidBool(id object, SEL selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static void PPCallVoidCGSize(id object, SEL selector, CGSize value) {
    ((void (*)(id, SEL, CGSize))objc_msgSend)(object, selector, value);
}

static void PPCallVoidCGPoint(id object, SEL selector, CGPoint value) {
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(object, selector, value);
}

static void PPCallVoidCGRect(id object, SEL selector, CGRect value) {
    ((void (*)(id, SEL, CGRect))objc_msgSend)(object, selector, value);
}

static void PPCallVoidObject(id object, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static NSInteger PPCallInteger(id object, SEL selector) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGRect PPCallRectInteger(id object, SEL selector, NSInteger value) {
    return ((CGRect (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
}

static NSRange PPCallRange(id object, SEL selector) {
    return ((NSRange (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSRange PPCallRangeCGRect(id object, SEL selector, CGRect rect) {
    return ((NSRange (*)(id, SEL, CGRect))objc_msgSend)(object, selector, rect);
}

@implementation PPApplePrivateGridRuntime

+ (BOOL)loadPrivateFrameworks {
    if (PPDidAttemptLoad) { return PPLoaded; }
    PPDidAttemptLoad = YES;

    NSArray<NSString *> *paths = @[
        @"/System/Library/PrivateFrameworks/Tungsten.framework/Tungsten",
        @"/System/Library/PrivateFrameworks/GridZero.framework/GridZero",
        @"/System/Library/PrivateFrameworks/PhotosUIFoundation.framework/PhotosUIFoundation",
        @"/System/Library/PrivateFrameworks/PhotosUICore.framework/PhotosUICore"
    ];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    BOOL ok = YES;
    for (NSString *path in paths) {
        void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            [lines addObject:[NSString stringWithFormat:@"loaded %@", path.lastPathComponent]];
        } else {
            const char *error = dlerror();
            [lines addObject:[NSString stringWithFormat:@"failed %@: %s", path.lastPathComponent, error ?: "unknown"]];
            ok = NO;
        }
    }

    BOOL hasGrid = NSClassFromString(@"PXGGridLayout") != Nil;
    BOOL hasPinch = NSClassFromString(@"PXCuratedLibraryZoomLevelPinchFilter") != Nil;
    [lines addObject:[NSString stringWithFormat:@"PXGGridLayout=%@", hasGrid ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"PXCuratedLibraryZoomLevelPinchFilter=%@", hasPinch ? @"yes" : @"no"]];

    PPLoaded = ok && hasGrid;
    PPDiagnostics = [lines componentsJoinedByString:@"\n"];
    return PPLoaded;
}

+ (BOOL)isGridLayoutAvailable {
    [self loadPrivateFrameworks];
    return NSClassFromString(@"PXGGridLayout") != Nil;
}

+ (NSString *)diagnostics {
    [self loadPrivateFrameworks];
    return PPDiagnostics;
}

@end

@implementation PPApplePrivateGridLayout {
    id _layout;
    NSInteger _itemCount;
    NSInteger _columns;
    CGFloat _contentHeight;
}

- (instancetype)initWithItemCount:(NSInteger)itemCount {
    self = [super init];
    if (!self) { return nil; }
    [PPApplePrivateGridRuntime loadPrivateFrameworks];
    Class cls = NSClassFromString(@"PXGGridLayout");
    if (cls) {
        _layout = [[cls alloc] init];
        _itemCount = MAX(0, itemCount);
        _columns = 1;
        if ([_layout respondsToSelector:@selector(setNumberOfItems:)]) {
            PPCallVoidInteger(_layout, @selector(setNumberOfItems:), _itemCount);
        }
    }
    return self;
}

- (BOOL)available {
    return _layout != nil;
}

- (NSInteger)numberOfVisualColumns {
    if (!_layout || ![_layout respondsToSelector:@selector(numberOfVisualColumns)]) { return _columns; }
    return PPCallInteger(_layout, @selector(numberOfVisualColumns));
}

- (NSInteger)numberOfVisualRows {
    if (!_layout || ![_layout respondsToSelector:@selector(numberOfVisualRows)]) { return 0; }
    return PPCallInteger(_layout, @selector(numberOfVisualRows));
}

- (CGFloat)contentHeight {
    return _contentHeight;
}

- (NSRange)itemsToLoad {
    if (!_layout || ![_layout respondsToSelector:@selector(itemsToLoad)]) { return NSMakeRange(0, 0); }
    return PPCallRange(_layout, @selector(itemsToLoad));
}

- (void)configureWithItemCount:(NSInteger)itemCount
                       columns:(NSInteger)columns
                         width:(CGFloat)width
                viewportHeight:(CGFloat)viewportHeight
                    visibleRect:(CGRect)visibleRect
                            gap:(CGFloat)gap
         anchorObjectReference:(id)anchorObjectReference
           anchorViewportCenter:(CGPoint)anchorViewportCenter {
    if (!_layout) { return; }
    _itemCount = MAX(0, itemCount);
    _columns = MAX(1, columns);
    CGFloat safeWidth = MAX(1, width);
    CGFloat safeHeight = MAX(1, viewportHeight);

    @try {
        if ([_layout respondsToSelector:@selector(setNumberOfItems:)]) {
            PPCallVoidInteger(_layout, @selector(setNumberOfItems:), _itemCount);
        }
        if ([_layout respondsToSelector:@selector(setNumberOfColumns:)]) {
            PPCallVoidInteger(_layout, @selector(setNumberOfColumns:), _columns);
        }
        if ([_layout respondsToSelector:@selector(setInterItemSpacing:)]) {
            PPCallVoidCGSize(_layout, @selector(setInterItemSpacing:), CGSizeMake(gap, gap));
        }
        if ([_layout respondsToSelector:@selector(setItemAspectRatio:)]) {
            PPCallVoidDouble(_layout, @selector(setItemAspectRatio:), 1.0);
        }
        if ([_layout respondsToSelector:@selector(setEnableEffects:)]) {
            PPCallVoidBool(_layout, @selector(setEnableEffects:), YES);
        }
        if ([_layout respondsToSelector:@selector(setEnablePerItemCornerRadius:)]) {
            PPCallVoidBool(_layout, @selector(setEnablePerItemCornerRadius:), YES);
        }
        if ([_layout respondsToSelector:@selector(setLoadItemsOutsideAnchorViewport:)]) {
            PPCallVoidBool(_layout, @selector(setLoadItemsOutsideAnchorViewport:), YES);
        }
        if ([_layout respondsToSelector:@selector(setReferenceSize:)]) {
            PPCallVoidCGSize(_layout, @selector(setReferenceSize:), CGSizeMake(safeWidth, safeHeight));
        }
        if ([_layout respondsToSelector:@selector(setVisibleRect:)]) {
            PPCallVoidCGRect(_layout, @selector(setVisibleRect:), visibleRect);
        }
        if (anchorObjectReference && [_layout respondsToSelector:@selector(setAnchorObjectReference:)]) {
            PPCallVoidObject(_layout, @selector(setAnchorObjectReference:), anchorObjectReference);
        }
        if ([_layout respondsToSelector:@selector(setAnchorViewportCenter:)]) {
            PPCallVoidCGPoint(_layout, @selector(setAnchorViewportCenter:), anchorViewportCenter);
        }
        if ([_layout respondsToSelector:@selector(update)]) {
            PPCallVoid(_layout, @selector(update));
        }

        if (_itemCount > 0 && [_layout respondsToSelector:@selector(frameForItem:)]) {
            CGRect lastFrame = PPCallRectInteger(_layout, @selector(frameForItem:), _itemCount - 1);
            _contentHeight = CGRectGetMaxY(lastFrame);
        } else {
            _contentHeight = safeHeight;
        }
    } @catch (NSException *exception) {
        NSLog(@"PPApplePrivateGridLayout configure failed: %@", exception);
        _contentHeight = safeHeight;
    }
}

- (CGRect)frameForItem:(NSInteger)item {
    if (!_layout || item < 0 || item >= _itemCount || ![_layout respondsToSelector:@selector(frameForItem:)]) {
        return CGRectNull;
    }
    @try {
        return PPCallRectInteger(_layout, @selector(frameForItem:), item);
    } @catch (NSException *exception) {
        NSLog(@"PPApplePrivateGridLayout frameForItem failed: %@", exception);
        return CGRectNull;
    }
}

- (NSRange)itemRangeInRect:(CGRect)rect {
    if (!_layout || ![_layout respondsToSelector:@selector(itemRangeInRect:)]) {
        return NSMakeRange(0, 0);
    }
    @try {
        return PPCallRangeCGRect(_layout, @selector(itemRangeInRect:), rect);
    } @catch (NSException *exception) {
        NSLog(@"PPApplePrivateGridLayout itemRangeInRect failed: %@", exception);
        return NSMakeRange(0, 0);
    }
}

@end

@implementation PPApplePrivatePinchFilter {
    id _filter;
}

- (instancetype)init {
    self = [super init];
    if (!self) { return nil; }
    [PPApplePrivateGridRuntime loadPrivateFrameworks];
    Class cls = NSClassFromString(@"PXCuratedLibraryZoomLevelPinchFilter");
    if (cls) {
        _filter = [[cls alloc] init];
    }
    return self;
}

- (BOOL)available {
    return _filter != nil;
}

- (BOOL)isTrackingPinch {
    if (!_filter) { return NO; }
    @try {
        return [[_filter valueForKey:@"isTrackingPinch"] boolValue];
    } @catch (NSException *exception) {
        return NO;
    }
}

- (NSInteger)lastDirection {
    if (!_filter) { return 0; }
    @try {
        return [[_filter valueForKey:@"lastDirection"] integerValue];
    } @catch (NSException *exception) {
        return 0;
    }
}

- (void)reset {
    if (_filter && [_filter respondsToSelector:@selector(reset)]) {
        PPCallVoid(_filter, @selector(reset));
    }
}

- (NSInteger)filterScale:(double)scale {
    if (!_filter || ![_filter respondsToSelector:@selector(filterPinchGestureWithScale:initialPinchHandler:subsequentDirectionChangeHandler:)]) {
        return 0;
    }
    __block NSInteger result = 0;
    void (^initial)(NSInteger) = ^(NSInteger direction) {
        result = direction;
    };
    void (^subsequent)(NSInteger) = ^(NSInteger direction) {
        result = direction * 2;
    };
    @try {
        ((void (*)(id, SEL, double, id, id))objc_msgSend)(
            _filter,
            @selector(filterPinchGestureWithScale:initialPinchHandler:subsequentDirectionChangeHandler:),
            scale,
            initial,
            subsequent
        );
    } @catch (NSException *exception) {
        NSLog(@"PPApplePrivatePinchFilter failed: %@", exception);
    }
    return result;
}

@end
