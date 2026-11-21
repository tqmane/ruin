#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>

#define _dyld_register_func_for_add_image RUINTestRegisterFuncForAddImage
#define CALayer RUINSecondaryFixtureLayer
#define NSLayoutConstraint RUINSecondaryFixtureLayoutConstraint
#define NSLayoutAnchor RUINSecondaryFixtureLayoutAnchor
#define NSLayoutDimension RUINSecondaryFixtureLayoutDimension
void RUINTestRegisterFuncForAddImage(void (*callback)(const struct mach_header *, intptr_t));

typedef NS_ENUM(NSInteger, UIUserInterfaceIdiom) { UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad };
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged, UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed,
    UIGestureRecognizerStateRecognized = UIGestureRecognizerStateEnded
};
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleActionSheet, UIAlertControllerStyleAlert };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) { UIAlertActionStyleDefault, UIAlertActionStyleCancel, UIAlertActionStyleDestructive };
typedef NS_ENUM(NSInteger, UISceneActivationState) {
    UISceneActivationStateUnattached, UISceneActivationStateForegroundActive,
    UISceneActivationStateForegroundInactive, UISceneActivationStateBackground
};
typedef NSUInteger UIControlEvents;
enum { UIControlEventTouchUpInside = 1 << 6 };
typedef NSUInteger UIControlState;
enum { UIControlStateNormal = 0 };
typedef NSInteger UIButtonType;
enum { UIButtonTypeCustom = 0 };
typedef CGFloat UIFontWeight;
static const UIFontWeight UIFontWeightSemibold = 0.3;
typedef uint64_t UIAccessibilityTraits;
enum { UIAccessibilityTraitButton = 1, UIAccessibilityTraitNotEnabled = 1 << 8 };

@class UIView, UIWindow, UIWindowScene, UIScene, UIApplication, UIViewController, UIGestureRecognizer, UITouch, UIAlertAction, UIPopoverPresentationController, CALayer, UIFont, UIColor, UILayoutGuide, NSLayoutAnchor, NSLayoutDimension, NSLayoutConstraint, UILabel, UIButton;
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
- (id)accessibilityHitTest:(CGPoint)point withEvent:(id)event;
@end

@interface CALayer : NSObject
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) CGFloat borderWidth;
@property(nonatomic) CGColorRef borderColor;
@end
@interface UIFont : NSObject
+ (instancetype)systemFontOfSize:(CGFloat)fontSize weight:(UIFontWeight)weight;
@end
@interface UIColor : NSObject
@property(nonatomic, readonly) CGColorRef CGColor;
+ (instancetype)whiteColor;
+ (instancetype)blackColor;
+ (instancetype)systemBackgroundColor;
+ (instancetype)labelColor;
+ (instancetype)separatorColor;
+ (instancetype)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha;
@end
@interface NSLayoutConstraint : NSObject
+ (void)activateConstraints:(NSArray<NSLayoutConstraint *> *)constraints;
@end
@interface NSLayoutAnchor : NSObject
- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutAnchor *)anchor;
- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutAnchor *)anchor constant:(CGFloat)c;
@end
@interface NSLayoutDimension : NSLayoutAnchor
- (NSLayoutConstraint *)constraintEqualToConstant:(CGFloat)c;
@end
@interface UILayoutGuide : NSObject
@property(nonatomic, readonly) NSLayoutAnchor *leadingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *trailingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *bottomAnchor;
@end
@interface UILabel : NSObject
@property(nonatomic, strong) UIFont *font;
@end

@interface UIView : NSObject <UIAccessibilityIdentification>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@property(nonatomic, copy) NSString *accessibilityLabel;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) CGRect bounds;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, copy) NSArray<UIView *> *subviews;
@property(nonatomic, strong) UIColor *backgroundColor;
@property(nonatomic, readonly) CALayer *layer;
@property(nonatomic) BOOL translatesAutoresizingMaskIntoConstraints;
@property(nonatomic, readonly) UILayoutGuide *safeAreaLayoutGuide;
@property(nonatomic, readonly) NSLayoutAnchor *leadingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *trailingAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *topAnchor;
@property(nonatomic, readonly) NSLayoutAnchor *bottomAnchor;
@property(nonatomic, readonly) NSLayoutDimension *heightAnchor;
@property(nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *gestureRecognizers;
@property(nonatomic, strong) id fixtureAccessibilityHit;
@property(nonatomic) CGPoint fixtureScreenOrigin;
- (void)addSubview:(UIView *)view;
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer;
@end
@interface UIWindow : UIView
@property(nonatomic, weak) UIWindowScene *windowScene;
@property(nonatomic, strong) UIViewController *rootViewController;
@end
@interface UIAccessibilityElement : NSObject <UIAccessibilityIdentification>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end
@interface UIControl : UIView
@property(nonatomic, strong) id actionOwner;
@property(nonatomic, weak) id addedTarget;
@property(nonatomic) SEL addedAction;
@property(nonatomic) UIControlEvents addedEvents;
@property(nonatomic, readonly) NSSet *allTargets;
- (NSArray<NSString *> *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents;
@end
@interface UIButton : UIControl
@property(nonatomic, readonly) UILabel *titleLabel;
@property(nonatomic, copy) NSString *currentTitle;
+ (instancetype)buttonWithType:(UIButtonType)buttonType;
- (void)setTitle:(NSString *)title forState:(UIControlState)state;
- (void)setTitleColor:(UIColor *)color forState:(UIControlState)state;
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, readonly) UIView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic, copy) NSArray<UIViewController *> *childViewControllers;
@property(nonatomic) NSUInteger loads, appearances, disappearances;
- (void)viewDidLoad;
- (void)viewDidAppear:(_Bool)animated;
- (void)viewDidDisappear:(_Bool)animated;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@interface UIScene : NSObject
@property(nonatomic) UISceneActivationState activationState;
@end
@interface UIWindowScene : UIScene
@property(nonatomic, copy) NSArray<UIWindow *> *windows;
@end
@interface UIApplication : NSObject
@property(nonatomic, copy) NSSet<UIScene *> *connectedScenes;
+ (instancetype)sharedApplication;
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
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) NSMutableArray<UIAlertAction *> *actions;
@property(nonatomic, strong) UIPopoverPresentationController *popoverPresentationController;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end
@interface UIPasteboard : NSObject
@property(nonatomic, copy) NSString *string;
+ (instancetype)generalPasteboard;
@end
@interface UIDevice : NSObject
@property(nonatomic, readonly) UIUserInterfaceIdiom userInterfaceIdiom;
+ (instancetype)currentDevice;
@end

static inline CGRect UIAccessibilityConvertFrameToScreenCoordinates(CGRect frame, UIView *view) {
    frame.origin.x += view.fixtureScreenOrigin.x;
    frame.origin.y += view.fixtureScreenOrigin.y;
    return frame;
}
