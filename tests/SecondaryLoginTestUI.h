#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, UIUserInterfaceIdiom) { UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad };
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged, UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed,
    UIGestureRecognizerStateRecognized = UIGestureRecognizerStateEnded
};
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleActionSheet, UIAlertControllerStyleAlert };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) { UIAlertActionStyleDefault, UIAlertActionStyleCancel };
typedef NSUInteger UIControlEvents;
enum { UIControlEventTouchUpInside = 1 << 6 };
typedef uint64_t UIAccessibilityTraits;
enum { UIAccessibilityTraitButton = 1, UIAccessibilityTraitNotEnabled = 1 << 8 };

@class UIView, UIWindow, UIGestureRecognizer, UITouch, UIAlertAction, UIPopoverPresentationController;
@protocol UIGestureRecognizerDelegate <NSObject>
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch;
@end
@protocol UIAccessibilityIdentification <NSObject>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end

@interface NSObject (RUINSecondaryTestAccessibility)
@property(nonatomic) UIAccessibilityTraits accessibilityTraits;
@property(nonatomic) CGRect accessibilityFrame;
@property(nonatomic) BOOL accessibilityElementsHidden;
@property(nonatomic, copy) NSArray *fixtureAccessibilityElements;
- (NSInteger)accessibilityElementCount;
- (id)accessibilityElementAtIndex:(NSInteger)index;
@end

@interface UIView : NSObject <UIAccessibilityIdentification>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) CGRect bounds;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, copy) NSArray<UIView *> *subviews;
@property(nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *gestureRecognizers;
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer;
@end
@interface UIWindow : UIView @end
@interface UIAccessibilityElement : NSObject <UIAccessibilityIdentification>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end
@interface UIControl : UIView
@property(nonatomic, strong) id actionOwner;
@property(nonatomic, readonly) NSSet *allTargets;
- (NSArray<NSString *> *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event;
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, readonly) UIView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic) NSUInteger loads, appearances, disappearances;
- (void)viewDidLoad;
- (void)viewDidAppear:(_Bool)animated;
- (void)viewDidDisappear:(_Bool)animated;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@interface UIGestureRecognizer : NSObject
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id<UIGestureRecognizerDelegate> delegate;
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic) BOOL cancelsTouchesInView;
@property(nonatomic) CGPoint fixturePoint;
@property(nonatomic, strong) UIGestureRecognizer *requiredFailure;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)requireGestureRecognizerToFail:(UIGestureRecognizer *)recognizer;
- (CGPoint)locationInView:(UIView *)view;
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)recognizer;
@end
@interface UILongPressGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSTimeInterval minimumPressDuration;
@end
@interface UITapGestureRecognizer : UIGestureRecognizer @end
@interface UITouch : NSObject
@property(nonatomic) CGPoint point;
- (CGPoint)locationInView:(UIView *)view;
@end
@interface UIPopoverPresentationController : NSObject
@property(nonatomic, strong) UIView *sourceView;
@property(nonatomic) CGRect sourceRect;
@end
@interface UIAlertAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) UIAlertActionStyle style;
@property(nonatomic, copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@interface UIAlertController : UIViewController
@property(nonatomic, strong) NSMutableArray<UIAlertAction *> *actions;
@property(nonatomic, strong) UIPopoverPresentationController *popoverPresentationController;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end
@interface UIDevice : NSObject
@property(nonatomic, readonly) UIUserInterfaceIdiom userInterfaceIdiom;
+ (instancetype)currentDevice;
@end

static inline CGRect UIAccessibilityConvertFrameToScreenCoordinates(CGRect frame, __unused UIView *view) {
    return frame;
}
