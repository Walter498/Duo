/*
 * DuoStatusBar —— iPhone Duo 風格狀態欄（CAiPhoneDuoStatus 重構增強版）
 * iOS 16-17 / RootHide rootless / SpringBoard
 *
 * 架構：MSHookMessageEx 替換原生狀態欄控件方法，系統控件自己重畫成 Duo 樣式。
 * 數據（電量/充電/訊號格/Wi-Fi/4G-5G）全部讀原生控件屬性，系統自動更新。
 *
 * 新增：偏好設定（設置 App 內調節，即時生效，無需 respring）
 *   enabled    總開關
 *   scale      整體圖標縮放 (0.5 - 1.6)
 *   offsetX    左右位置微調
 *   offsetY    上下位置微調
 *   gapRingMid 圓環 ↔ Wi-Fi/4G/5G 間距
 *   gapMidDots 中間圖標 ↔ 訊號四點間距
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#pragma mark - 偏好（suite: com.shuijia.duostatus）

static BOOL    g_enabled  = YES;
static CGFloat g_scale    = 1.0;
static CGFloat g_dx       = 0.0;
static CGFloat g_dy       = 0.0;
static CGFloat g_gap1     = 2.0;   // 圓環 ↔ 中間
static CGFloat g_gap2     = 2.0;   // 中間 ↔ 四點

static void CALoadPrefs(void);

static CGFloat CAPrefFloat(NSString *key, CGFloat def) {
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                              CFSTR("com.shuijia.duostatus"));
    if (!n) return def;
    CGFloat v = def;
    CFNumberGetValue(n, kCFNumberCGFloatType, &v);
    CFRelease(n);
    return v;
}

static void CALoadPrefs(void) {
    CFPreferencesAppSynchronize(CFSTR("com.shuijia.duostatus"));
    g_enabled = CAPrefFloat(@"enabled", 1) != 0;
    g_scale   = MAX(0.5, MIN(1.6, CAPrefFloat(@"scale", 1.0)));
    g_dx      = CAPrefFloat(@"offsetX", 0);
    g_dy      = CAPrefFloat(@"offsetY", 0);
    g_gap1    = CAPrefFloat(@"gapRingMid", 2);
    g_gap2    = CAPrefFloat(@"gapMidDots", 2);
}

#pragma mark - CANativeStatusState

@interface CANativeStatusState : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) UIView *battery;
@property (nonatomic, weak) UIView *cellular;
@property (nonatomic, weak) UIView *cellularSource;
@property (nonatomic, weak) UIView *network;
@property (nonatomic, assign) CGRect batteryFrame;
@property (nonatomic, assign) CGRect cellularFrame;
@property (nonatomic, assign) CGRect networkFrame;
@property (nonatomic, assign) BOOL applyingLayout;
@property (nonatomic, assign) BOOL hasBaseline;
@end

@implementation CANativeStatusState
@end

static const char kCAStateKey = 0;

#pragma mark - 工具

static NSHashTable<UIView *> *g_hosts;

static Class ClassOrNil(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) c = NSClassFromString([name stringByReplacingOccurrencesOfString:@"STUI" withString:@"UI"]);
    return c;
}

static BOOL CAInMainStatusBar(UIView *v) {
    UIResponder *r = v.nextResponder;
    while (r) {
        NSString *cn = NSStringFromClass(r.class);
        if ([cn hasPrefix:@"STUIStatusBar"] || [cn hasPrefix:@"_UIStatusBar"] ||
            [cn hasPrefix:@"UIStatusBar"]) return YES;
        if ([cn containsString:@"LockScreen"] || [cn containsString:@"Notification"] ||
            [cn containsString:@"ControlCenter"]) return NO;
        r = r.nextResponder;
    }
    return NO;
}

static CANativeStatusState *CAStateFor(UIView *foreground) {
    CANativeStatusState *s = objc_getAssociatedObject(foreground, &kCAStateKey);
    if (!s) {
        s = [CANativeStatusState new];
        s.host = foreground;
        objc_setAssociatedObject(foreground, &kCAStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [g_hosts addObject:foreground];
    }
    return s;
}

#pragma mark - 前向聲明
static void (*orig_batt_draw)(UIView *, SEL);
static void hook_batt_draw(UIView *self, SEL _cmd);
static void (*orig_sig_draw)(UIView *, SEL);
static void hook_sig_draw(UIView *self, SEL _cmd);
static void (*orig_fg_layout)(UIView *, SEL);
static void hook_fg_layout(UIView *self, SEL _cmd);
static void (*orig_batt_tint)(UIView *, SEL);
static void (*orig_sig_tint)(UIView *, SEL);
static void hook_batt_tint(UIView *self, SEL _cmd);
static void hook_sig_tint(UIView *self, SEL _cmd);

#pragma mark - 電池圓環（drawRect: 替代實現，隨 bounds 自動縮放）

static void hook_batt_draw(UIView *self, SEL _cmd) {
    if (!g_enabled || !CAInMainStatusBar(self)) { orig_batt_draw(self, _cmd); return; }

    CGFloat pct = 0;
    BOOL charging = NO, saver = NO;
    @try { pct = [[self valueForKey:@"chargePercent"] floatValue]; } @catch (id e) {}
    @try { charging = [[self valueForKey:@"chargingState"] intValue] != 0; } @catch (id e) {}
    @try { saver = [[self valueForKey:@"saverModeActive"] boolValue]; } @catch (id e) {}
    if (pct < 0) pct = 0; if (pct > 1) pct = 1;

    CGRect b = self.bounds;
    CGFloat k = MIN(CGRectGetWidth(b), CGRectGetHeight(b)) / 18.0;   // 相對 18pt 基準縮放
    if (k <= 0) k = 1;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat r = MIN(CGRectGetWidth(b), CGRectGetHeight(b)) / 2.0 - 1.5 * k;

    UIColor *ink = self.tintColor ?: UIColor.blackColor;
    if (charging)        ink = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    else if (saver)      ink = [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0];
    else if (pct <= 0.2) ink = UIColor.redColor;

    CGContextSetLineWidth(ctx, 2.2 * k);
    CGContextSetStrokeColorWithColor(ctx, [ink colorWithAlphaComponent:0.22].CGColor);
    CGContextAddArc(ctx, c.x, c.y, r, 0, 2 * M_PI, 0);
    CGContextStrokePath(ctx);

    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGContextAddArc(ctx, c.x, c.y, r, -M_PI_2, -M_PI_2 + 2 * M_PI * pct, 0);
    CGContextStrokePath(ctx);

    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 1.6 * k, c.y - 1.6 * k, 3.2 * k, 3.2 * k));
}

#pragma mark - 訊號四點（drawRect: 替代實現）

static void hook_sig_draw(UIView *self, SEL _cmd) {
    if (!g_enabled || !CAInMainStatusBar(self)) { orig_sig_draw(self, _cmd); return; }

    NSInteger bars = 0;
    @try { bars = [[self valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
    if (bars < 0) bars = 0; if (bars > 4) bars = 4;

    CGRect b = self.bounds;
    CGFloat k = CGRectGetWidth(b) / 22.0; if (k <= 0) k = 1;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIColor *ink = self.tintColor ?: UIColor.blackColor;
    UIColor *dim = [ink colorWithAlphaComponent:0.22];

    CGFloat dotR = 1.9 * k, gap = 2.6 * k;
    CGFloat total = 4 * dotR * 2 + 3 * gap;
    CGFloat x = CGRectGetMidX(b) - total / 2.0;
    CGFloat y = CGRectGetMidY(b) - dotR;

    for (int i = 0; i < 4; i++) {
        CGContextSetFillColorWithColor(ctx, (i < bars ? ink : dim).CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(x, y, dotR * 2, dotR * 2));
        x += dotR * 2 + gap;
    }
}

#pragma mark - 前景重排（偏好設定驅動的 Duo 豎排佈局）

static void hook_fg_layout(UIView *self, SEL _cmd) {
    orig_fg_layout(self, _cmd);
    if (!g_enabled || !CAInMainStatusBar(self)) return;

    CANativeStatusState *s = CAStateFor(self);
    if (s.applyingLayout) return;

    Class clsBatt = ClassOrNil(@"STUIStatusBarStaticBatteryView");
    Class clsWifi = ClassOrNil(@"STUIStatusBarWifiSignalView");
    Class clsSig  = ClassOrNil(@"STUIStatusBarCellularSignalView");
    Class clsDual = ClassOrNil(@"STUIStatusBarDualCellularSignalView");
    Class clsNet  = ClassOrNil(@"STUIStatusBarCellularNetworkTypeView");

    for (UIView *v in self.subviews) {
        if (clsBatt && [v isKindOfClass:clsBatt]) s.battery = v;
        else if (clsWifi && [v isKindOfClass:clsWifi]) s.network = v;
        else if (clsNet  && [v isKindOfClass:clsNet])  s.network = v;
        else if (clsDual && [v isKindOfClass:clsDual]) s.cellularSource = v;
        else if (clsSig  && [v isKindOfClass:clsSig])  s.cellular = v;
    }
    if (!s.cellular && s.cellularSource) s.cellular = s.cellularSource;

    CGRect axis = CGRectNull;
    for (UIView *v in @[s.battery ?: (UIView *)[NSNull null],
                        s.network ?: (UIView *)[NSNull null],
                        s.cellular ?: (UIView *)[NSNull null]]) {
        if ([v isKindOfClass:UIView.class] && [(UIView *)v superview])
            axis = CGRectIsNull(axis) ? [(UIView *)v frame]
                                      : CGRectUnion(axis, [(UIView *)v frame]);
    }
    if (CGRectIsNull(axis) || CGRectIsEmpty(axis)) return;

    CGFloat cx = CGRectGetMidX(axis) + g_dx;
    CGFloat top = CGRectGetMinY(axis) + 1 + g_dy;
    CGFloat sc = g_scale;

    s.applyingLayout = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // 圓環
    if (s.battery) {
        s.batteryFrame = CGRectMake(cx - 9 * sc, top, 18 * sc, 18 * sc);
        s.battery.frame = s.batteryFrame;
        [s.battery setNeedsDisplay];
    }
    // 中間：Wi-Fi / 4G-5G（與圓環間距 g_gap1）
    if (s.network) {
        s.networkFrame = CGRectMake(cx - 12 * sc,
                                    top + 18 * sc + g_gap1,
                                    24 * sc, 10 * sc);
        s.network.frame = s.networkFrame;
    }
    // 訊號四點（與中間間距 g_gap2）
    if (s.cellular) {
        s.cellularFrame = CGRectMake(cx - 11 * sc,
                                     top + 18 * sc + g_gap1 + 10 * sc + g_gap2,
                                     22 * sc, 7 * sc);
        s.cellular.frame = s.cellularFrame;
        [s.cellular setNeedsDisplay];
    }

    [CATransaction commit];
    s.applyingLayout = NO;
    s.hasBaseline = YES;
}

#pragma mark - 深淺色適配
static void hook_batt_tint(UIView *self, SEL _cmd) {
    orig_batt_tint(self, _cmd);
    if (g_enabled && CAInMainStatusBar(self)) [self setNeedsDisplay];
}
static void hook_sig_tint(UIView *self, SEL _cmd) {
    orig_sig_tint(self, _cmd);
    if (g_enabled && CAInMainStatusBar(self)) [self setNeedsDisplay];
}

#pragma mark - 偏好變更 → 刷新所有狀態欄
static void CAReloadAll(void) {
    CALoadPrefs();
    for (UIView *v in g_hosts.allObjects) {
        [v setNeedsLayout];
        [v layoutIfNeeded];
    }
}

#pragma mark - Hook 安裝
static void CAInstallHooks(void) {
    Class fg = ClassOrNil(@"STUIStatusBarForegroundView");
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");
    Class sg = ClassOrNil(@"STUIStatusBarCellularSignalView");

    if (fg) MSHookMessageEx(fg, @selector(layoutSubviews),
                            (IMP)hook_fg_layout, (IMP *)&orig_fg_layout);
    if (bt) {
        MSHookMessageEx(bt, @selector(drawRect:), (IMP)hook_batt_draw, (IMP *)&orig_batt_draw);
        MSHookMessageEx(bt, @selector(tintColorDidChange), (IMP)hook_batt_tint, (IMP *)&orig_batt_tint);
    }
    if (sg) {
        MSHookMessageEx(sg, @selector(drawRect:), (IMP)hook_sig_draw, (IMP *)&orig_sig_draw);
        MSHookMessageEx(sg, @selector(tintColorDidChange), (IMP)hook_sig_tint, (IMP *)&orig_sig_tint);
    }
}

#pragma mark - 控制中心
static void CAObserveControlCenter(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:@"SBControlCenterControllerWillPresentNotification"
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) {
        for (UIView *v in g_hosts.allObjects) [v setNeedsLayout];
    }];
    [nc addObserverForName:@"SBControlCenterControllerDidDismissNotification"
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) {
        for (UIView *v in g_hosts.allObjects) [v setNeedsLayout];
    }];
}

#pragma mark - 入口
__attribute__((constructor)) static void ca_init(void) {
    CALoadPrefs();
    g_hosts = [NSHashTable weakObjectsHashTable];
    CAInstallHooks();
    CAObserveControlCenter();

    // 設置面板保存 → Darwin 通知 → 即時生效
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)CAReloadAll,
        CFSTR("com.shuijia.duostatus/preferencesChanged"), NULL,
        (CFNotificationSuspensionBehavior)0);
}
