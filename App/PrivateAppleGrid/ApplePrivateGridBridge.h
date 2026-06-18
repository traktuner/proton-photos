#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPApplePrivateGridRuntime : NSObject
+ (BOOL)loadPrivateFrameworks;
+ (BOOL)isGridLayoutAvailable;
+ (NSString *)diagnostics;
@end

@interface PPApplePrivateGridLayout : NSObject
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) NSInteger numberOfVisualColumns;
@property (nonatomic, readonly) NSInteger numberOfVisualRows;
@property (nonatomic, readonly) CGFloat contentHeight;
@property (nonatomic, readonly) NSRange itemsToLoad;

- (instancetype)initWithItemCount:(NSInteger)itemCount;
- (void)configureWithItemCount:(NSInteger)itemCount
                       columns:(NSInteger)columns
                         width:(CGFloat)width
                 viewportHeight:(CGFloat)viewportHeight
                    visibleRect:(CGRect)visibleRect
                            gap:(CGFloat)gap
          anchorObjectReference:(nullable id)anchorObjectReference
            anchorViewportCenter:(CGPoint)anchorViewportCenter;
- (CGRect)frameForItem:(NSInteger)item;
- (NSRange)itemRangeInRect:(CGRect)rect;
@end

@interface PPApplePrivatePinchFilter : NSObject
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) BOOL isTrackingPinch;
@property (nonatomic, readonly) NSInteger lastDirection;

- (void)reset;
- (NSInteger)filterScale:(double)scale;
@end

NS_ASSUME_NONNULL_END
