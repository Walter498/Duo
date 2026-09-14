/*
 * DuoStatusBar —— iPhone Duo 風格狀態欄 v1.1
 * iOS 16-17 / RootHide rootless / SpringBoard
 *
 * v1.1 修復：
 *   1. 原生控件內容靠子視圖/子圖層渲染，僅換 drawRect 不夠 → 重排時一併隱藏原生子內容
 *   2. 雙卡機型訊號視圖是 STUIStatusBarDualCellularSignalView → 同樣 hook，並用
 *      CoreTelephony CTGetSignalStrength 直接取「主卡」格數
 *   3. 1 秒定時器主動觸發重繪（原生繪製被抑制後也要保持電量/訊號實時更新）
 *   4. 設置面板恢復為 PreferenceBundle（CI 上出真 arm64e）
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>

#pragma mark - 偏好（suite: com.shuijia.duostatus）

static BOOL    g_enabled  = YES;
static CGFloat g_scale    = 1.0;
static CGFloat g_dx       = 0.0;
static CGFloat g_dy       = 0.0;
static CGFloat g_gap1     = 2.0;
static CGFloat g_gap2     = 2.0;

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

#pragma mark - CoreTelephony 主卡訊號（雙卡機型用）

typedef int (*CTGetSignalStrength_t)(int *, int *);
static CTGetSignalStrength_t pCTGetSignalStrength;

static int CAPrimaryBars(void) {
    if (!pCTGetSignalStrength) return 0;
    int bars = 0, raw = 0;
    pCTGetSignalStrength(&bars, &raw);
    if (bars < 0) bars = 0;
    if (bars > 4) bars = 4;
    return bars;
}

#pragma mark - CANativeStatusState

@interface CANativeStatusState : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) UIView *battery;
@property (nonatomic, weak) UIView *cellular;      // 單卡 SignalView 或雙卡 DualCellularSignalView
@property (nonatomic, weak) UIView *network;       // WifiSignalView 或 CellularNetworkTypeView
@property (nonatomic, assign) BOOL applyingLayout;
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

// v1.1：原生控件的內容是子視圖/子圖層畫的，必須一併隱藏，否則會與我們的繪製疊在一起
static void CAHideNativeContent(UIView *v, BOOL hide) {
    for (UIView *sub in v.subviews) sub.hidden = hide;
    for (CALayer *sl in v.layer.sublayers) sl.hidden = hide;
}

#pragma mark - 前向聲明
static void (*orig_batt_draw)(UIView *, SEL);
static void hook_batt_draw(UIView *self, SEL _cmd);
static void (*orig_sig_draw)(UIView *, SEL);
static void hook_sig_draw(UIView *self, SEL _cmd);
static void (*orig_dual_draw)(UIView *, SEL);
static void (*orig_fg_layout)(UIView *, SEL);
static void hook_fg_layout(UIView *self, SEL _cmd);
static void (*orig_batt_tint)(UIView *, SEL);
static void hook_batt_tint(UIView *self, SEL _cmd);
static void (*orig_sig_tint)(UIView *, SEL);
static void hook_sig_tint(UIView *self, SEL _cmd);

#pragma mark - 電池圓環

static void hook_batt_draw(UIView *self, SEL _cmd) {
    if (!g_enabled || !CAInMainStatusBar(self)) { orig_batt_draw(self, _cmd); return; }

    CGFloat pct = 0;
    BOOL charging = NO, saver = NO;
    @try { pct = [[self valueForKey:@"chargePercent"] floatValue]; } @catch (id e) {}
    @try { charging = [[self valueForKey:@"chargingState"] intValue] != 0; } @catch (id e) {}
    @try { saver = [[self valueForKey:@"saverModeActive"] boolValue]; } @catch (id e) {}
    if (pct < 0) pct = 0; if (pct > 1) pct = 1;

    CGRect b = self.bounds;
    CGFloat k = MIN(CGRectGetWidth(b), CGRectGetHeight(b)) / 18.0;
    if (k <= 0) k = 1;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextClearRect(ctx, b);
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

#pragma mark - 訊號四點（單卡/雙卡通用）

static void hook_sig_draw(UIView *self, SEL _cmd) {
    BOOL isDual = [NSStringFromClass(self.class) containsString:@"DualCellular"];
    if (!g_enabled || !CAInMainStatusBar(self)) {
        (isDual ? orig_dual_draw : orig_sig_draw)(self, _cmd);
        return;
    }

    NSInteger bars;
    if (isDual) {
        bars = CAPrimaryBars();      // 雙卡：直接取主卡
    } else {
        bars = 0;
        @try { bars = [[self valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
    }
    if (bars < 0) bars = 0; if (bars > 4) bars = 4;

    CGRect b = self.bounds;
    CGFloat k = CGRectGetWidth(b) / 22.0; if (k <= 0) k = 1;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextClearRect(ctx, b);
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

#pragma mark - 前景重排

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

    UIView *batt = nil, *cell = nil, *wifi = nil, *net = nil;
    for (UIView *v in self.subviews) {
        if (clsBatt && [v isKindOfClass:clsBatt]) batt = v;
        else if (clsWifi && [v isKindOfClass:clsWifi]) wifi = v;
        else if (clsNet  && [v isKindOfClass:clsNet])  net = v;
        else if (clsDual && [v isKindOfClass:clsDual]) cell = v;   // 雙卡
        else if (clsSig  && [v isKindOfClass:clsSig])  cell = v;   // 單卡
    }
    s.battery = batt;
    s.cellular = cell;
    s.network = wifi ?: net;   // Wi-Fi 優先，無 Wi-Fi 時顯示 4G/5G

    CGRect axis = CGRectNull;
    for (UIView *v in @[batt ?: (UIView *)[NSNull null],
                        s.network ?: (UIView *)[NSNull null],
                        cell ?: (UIView *)[NSNull null]]) {
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

    if (batt) {
        batt.frame = CGRectMake(cx - 9 * sc, top, 18 * sc, 18 * sc);
        CAHideNativeContent(batt, YES);
        [batt setNeedsDisplay];
    }
    if (s.network) {
        s.network.frame = CGRectMake(cx - 12 * sc,
                                     top + 18 * sc + g_gap1,
                                     24 * sc, 10 * sc);
    }
    if (cell) {
        cell.frame = CGRectMake(cx - 11 * sc,
                                top + 18 * sc + g_gap1 + 10 * sc + g_gap2,
                                22 * sc, 7 * sc);
        CAHideNativeContent(cell, YES);
        [cell setNeedsDisplay];
    }

    [CATransaction commit];
    s.applyingLayout = NO;
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

#pragma mark - 1 秒定時刷新（原生繪製被抑制後保持實時）
static void CAScheduleRefresh(void) {
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (!g_enabled) return;
        for (UIView *host in g_hosts.allObjects) {
            CANativeStatusState *s = objc_getAssociatedObject(host, &kCAStateKey);
            [s.battery setNeedsDisplay];
            [s.cellular setNeedsDisplay];
        }
    }];
}

#pragma mark - 偏好變更
static void CAReloadAll(void) {
    CALoadPrefs();
    for (UIView *host in g_hosts.allObjects) {
        CANativeStatusState *s = objc_getAssociatedObject(host, &kCAStateKey);
        // 關閉時恢復原生內容可見性，再交還原生佈局
        if (s.battery)  CAHideNativeContent(s.battery, g_enabled ? YES : NO);
        if (s.cellular) CAHideNativeContent(s.cellular, g_enabled ? YES : NO);
        [host setNeedsLayout];
        [host layoutIfNeeded];
        [s.battery setNeedsDisplay];
        [s.cellular setNeedsDisplay];
    }
}

#pragma mark - Hook 安裝
static void CAInstallHooks(void) {
    Class fg = ClassOrNil(@"STUIStatusBarForegroundView");
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");
    Class sg = ClassOrNil(@"STUIStatusBarCellularSignalView");
    Class dg = ClassOrNil(@"STUIStatusBarDualCellularSignalView");

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
    if (dg) {
        MSHookMessageEx(dg, @selector(drawRect:), (IMP)hook_sig_draw, (IMP *)&orig_dual_draw);
    }

    void *ct = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (ct) pCTGetSignalStrength = (CTGetSignalStrength_t)dlsym(ct, "CTGetSignalStrength");
}

#pragma mark - 入口
__attribute__((constructor)) static void ca_init(void) {
    CALoadPrefs();
    g_hosts = [NSHashTable weakObjectsHashTable];
    CAInstallHooks();

    // SpringBoard 啟動後啟動定時刷新
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { CAScheduleRefresh(); }];

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)CAReloadAll,
        CFSTR("com.shuijia.duostatus/preferencesChanged"), NULL,
        (CFNotificationSuspensionBehavior)0);
}
