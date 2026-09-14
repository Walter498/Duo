/*
 * DuoStatusBar —— iPhone Duo 風格狀態欄 v1.3
 * iOS 16-17 / RootHide rootless / SpringBoard
 *
 * 最終設計（參考官方變形動畫）：
 *   一個整圓：
 *     頂部 280° 大弧 = 電量圓環（充電綠 / 平時跟隨狀態欄顏色）
 *     底部缺口     = 主卡訊號四點（4 個點就排在圓弧的缺口上）
 *     圓心         = Wi-Fi 符號；無 Wi-Fi 時顯示 5G / 4G / 3G
 *
 * v1.3：
 *   - 全部元素集中畫在電量控件一個視圖裡（環 + Wi-Fi + 點），不再分三個槽位
 *   - 取色：applyStyleAttributes: 捕獲 → 時鐘標籤 textColor 兜底 → 白色
 *   - 黑底：接管時清背景 + 每秒壓制原生子內容
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

#pragma mark - 偏好（suite: com.shuijia.duostatus）

static BOOL    g_enabled   = YES;
static CGFloat g_scale     = 1.0;
static CGFloat g_dx        = 0.0;
static CGFloat g_dy        = 0.0;
static CGFloat g_ringW     = 2.6;    // 圓環線寬
static CGFloat g_dotSize   = 1.5;    // 訊號點半徑
static CGFloat g_wifiOff   = -0.5;   // 圓心圖標上下微調

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
    g_enabled  = CAPrefFloat(@"enabled", 1) != 0;
    g_scale    = MAX(0.5, MIN(1.8, CAPrefFloat(@"scale", 1.0)));
    g_dx       = CAPrefFloat(@"offsetX", 0);
    g_dy       = CAPrefFloat(@"offsetY", 0);
    g_ringW    = MAX(1.0, MIN(4.5, CAPrefFloat(@"ringWidth", 2.6)));
    g_dotSize  = MAX(0.8, MIN(3.0, CAPrefFloat(@"dotSize", 1.5)));
    g_wifiOff  = MAX(-4, MIN(4, CAPrefFloat(@"wifiOffset", -0.5)));
}

#pragma mark - 動態符號

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

static BOOL CAWiFiConnected(void) {   // iPhone 上 en0 拿到 IP 即 Wi-Fi 已連
    struct ifaddrs *list = NULL;
    BOOL ok = NO;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *p = list; p; p = p->ifa_next) {
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET &&
                strcmp(p->ifa_name, "en0") == 0 && !(p->ifa_flags & IFF_LOOPBACK)) {
                ok = YES; break;
            }
        }
        freeifaddrs(list);
    }
    return ok;
}

static NSString *CARATString(void) {
    static CTTelephonyNetworkInfo *info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ info = [CTTelephonyNetworkInfo new]; });
    NSDictionary *dict = info.serviceCurrentRadioAccessTechnology;
    NSString *tech = dict.allValues.firstObject ?: @"";
    if ([tech containsString:@"NR"])    return @"5G";
    if ([tech containsString:@"LTE"])   return @"4G";
    if ([tech containsString:@"WCDMA"] || [tech containsString:@"HSDPA"] ||
        [tech containsString:@"HSUPA"]) return @"3G";
    if ([tech containsString:@"Edge"])  return @"E";
    return @"";
}

#pragma mark - 墨水色

static UIColor *g_ink = nil;
static UIColor *CAInk(void) { return g_ink ?: UIColor.whiteColor; }

static UIColor *CAScanClockColor(UIView *anyStatusView) {
    UIView *root = anyStatusView;
    while (root.superview && [NSStringFromClass(root.superview.class) containsString:@"StatusBar"])
        root = root.superview;
    if (!root.superview) root = anyStatusView.window ?: anyStatusView;

    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *l = (UILabel *)v;
            if (l.text.length > 0 && l.textColor && l.alpha > 0.1 && !l.hidden)
                return l.textColor;
        }
        for (UIView *s in v.subviews)
            if (s.alpha > 0.05 && !s.hidden) [q addObject:s];
    }
    return nil;
}

#pragma mark - CANativeStatusState

@interface CANativeStatusState : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) UIView *battery;    // 畫布：環 + Wi-Fi + 點
@property (nonatomic, weak) UIView *cellular;
@property (nonatomic, weak) UIView *wifi;
@property (nonatomic, weak) UIView *netType;
@property (nonatomic, assign) BOOL applyingLayout;
@end

@implementation CANativeStatusState
@end

static const char kCAStateKey = 0;
static NSHashTable<UIView *> *g_hosts;

#pragma mark - 工具

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

static void CATakeOver(UIView *v, BOOL yes) {
    if (yes) {
        v.opaque = NO;
        if (![v.backgroundColor isEqual:UIColor.clearColor]) v.backgroundColor = UIColor.clearColor;
        v.layer.backgroundColor = NULL;
        for (UIView *sub in v.subviews) sub.hidden = YES;
        for (CALayer *sl in v.layer.sublayers) sl.hidden = YES;
    } else {
        for (UIView *sub in v.subviews) sub.hidden = NO;
        for (CALayer *sl in v.layer.sublayers) sl.hidden = NO;
        [v setNeedsDisplay];
    }
}

#pragma mark - 前向聲明
static void (*orig_batt_draw)(UIView *, SEL);
static void hook_batt_draw(UIView *self, SEL _cmd);
static void (*orig_fg_layout)(UIView *, SEL);
static void hook_fg_layout(UIView *self, SEL _cmd);
static void (*orig_applyStyle)(UIView *, SEL, id);
static void hook_applyStyle(UIView *self, SEL _cmd, id attrs);

#pragma mark - 繪製部件

static void CADrawWifi(CGContextRef ctx, CGPoint c, CGFloat s, UIColor *ink) {
    CGContextSetLineWidth(ctx, 1.35 * s);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGPoint base = CGPointMake(c.x, c.y + 2.4 * s);
    const CGFloat radii[3] = {1.15, 2.75, 4.35};
    for (int i = 0; i < 3; i++) {
        CGContextAddArc(ctx, base.x, base.y, radii[i] * s, -M_PI * 0.86, -M_PI * 0.14, 0);
        CGContextStrokePath(ctx);
    }
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(base.x - 0.95 * s, base.y - 0.95 * s, 1.9 * s, 1.9 * s));
}

// 整圓繪製：頂部電量弧 + 底部缺口的訊號點 + 圓心 Wi-Fi / 制式文字
static void CADrawWidget(UIView *self, CGContextRef ctx, CGRect b) {
    CGFloat S = MIN(CGRectGetWidth(b), CGRectGetHeight(b));
    CGFloat k = S / 22.0;
    if (k <= 0) k = 1;
    CGContextClearRect(ctx, b);

    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat lw = g_ringW * k;
    CGFloat r = S / 2.0 - lw / 2.0 - 0.5 * k;   // 圓弧半徑（點也排在這條線上）

    CGFloat pct = 0;
    BOOL charging = NO;
    @try { pct = [[self valueForKey:@"chargePercent"] floatValue]; } @catch (id e) {}
    @try { charging = [[self valueForKey:@"chargingState"] intValue] != 0; } @catch (id e) {}
    if (pct < 0) pct = 0; if (pct > 1) pct = 1;

    UIColor *ink = charging ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                            : CAInk();

    // 弧線：130° 起、順時針 280°（底部留 80° 缺口）
    const CGFloat gapHalf = M_PI * 80.0 / 360.0;        // 半缺口 40°
    const CGFloat startA  = M_PI_2 + gapHalf;           // 140°
    const CGFloat sweep   = 2 * M_PI - 2 * gapHalf;     // 280°

    // 底槽
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, [ink colorWithAlphaComponent:0.22].CGColor);
    CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep, 0);
    CGContextStrokePath(ctx);

    // 電量弧
    if (pct > 0.003) {
        CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
        CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep * pct, 0);
        CGContextStrokePath(ctx);
    }

    // 底部缺口：主卡訊號四點（排在圓弧上，左起第 1 格）
    int bars = CAPrimaryBars();
    const int dotCount = 4;
    // 缺口左右端各內縮 12°，四點均勻分佈
    CGFloat leftA  = M_PI_2 + gapHalf - M_PI * 12.0 / 180.0;   // 118°
    CGFloat rightA = M_PI_2 - gapHalf + M_PI * 12.0 / 180.0;   // 62°
    CGFloat dotR = g_dotSize * k;
    UIColor *dim = [ink colorWithAlphaComponent:0.22];
    for (int i = 0; i < dotCount; i++) {
        CGFloat t = (CGFloat)i / (dotCount - 1);
        CGFloat ang = leftA + (rightA - leftA) * t;
        CGPoint d = CGPointMake(c.x + cos(ang) * r, c.y + sin(ang) * r);
        BOOL on = (i < bars);
        CGContextSetFillColorWithColor(ctx, (on ? ink : dim).CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(d.x - dotR, d.y - dotR, dotR * 2, dotR * 2));
    }

    // 圓心：Wi-Fi 符號 或 制式文字
    CGPoint wc = CGPointMake(c.x, c.y + g_wifiOff * k);
    if (CAWiFiConnected()) {
        CADrawWifi(ctx, wc, r / 9.5, ink);
    } else {
        NSString *rat = CARATString();
        if (rat.length) {
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:7.6 * k weight:UIFontWeightBold],
                NSForegroundColorAttributeName: ink
            };
            CGSize sz = [rat sizeWithAttributes:attrs];
            [rat drawAtPoint:CGPointMake(wc.x - sz.width / 2.0, wc.y - sz.height / 2.0)
              withAttributes:attrs];
        }
    }
}

static void hook_batt_draw(UIView *self, SEL _cmd) {
    if (!g_enabled || !CAInMainStatusBar(self)) { orig_batt_draw(self, _cmd); return; }
    CADrawWidget(self, UIGraphicsGetCurrentContext(), self.bounds);
}

#pragma mark - 樣式捕獲

static void hook_applyStyle(UIView *self, SEL _cmd, id attrs) {
    if (orig_applyStyle) orig_applyStyle(self, _cmd, attrs);
    UIColor *c = nil;
    for (NSString *key in @[@"foregroundColor", @"textColor", @"color", @"tintColor"]) {
        @try {
            id v = [attrs valueForKey:key];
            if ([v isKindOfClass:UIColor.class]) { c = v; break; }
        } @catch (id e) {}
    }
    if (c && CGColorGetAlpha(c.CGColor) > 0.05) {
        g_ink = c;
        for (UIView *h in g_hosts.allObjects) {
            CANativeStatusState *s = objc_getAssociatedObject(h, &kCAStateKey);
            [s.battery setNeedsDisplay];
        }
    }
}

#pragma mark - 前景重排（只保留電量控件一座畫布，其餘全部讓位）

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
        else if (clsDual && [v isKindOfClass:clsDual]) cell = v;
        else if (clsSig  && [v isKindOfClass:clsSig])  cell = v;
    }
    s.battery = batt; s.cellular = cell; s.wifi = wifi; s.netType = net;
    if (!batt) return;

    if (!g_ink) {
        UIColor *clock = CAScanClockColor(batt);
        if (clock) g_ink = clock;
    }

    CGRect barBounds = batt.superview ? batt.superview.bounds : self.bounds;
    CGFloat barMidY = CGRectGetMidY(barBounds);
    if (barMidY <= 0) barMidY = 27.0;
    CGFloat S = 22.0 * g_scale;
    CGFloat cx = CGRectGetMidX(batt.frame) + g_dx;
    CGFloat top = barMidY - S / 2.0 + 1.0 + g_dy;

    s.applyingLayout = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    batt.frame = CGRectMake(cx - S / 2.0, top, S, S);
    CATakeOver(batt, YES);
    [batt setNeedsDisplay];

    // 其他所有原生槽位全部讓位（內容已進圓環）
    if (cell)  cell.alpha = 0;
    if (wifi)  wifi.alpha = 0;
    if (net)   net.alpha = 0;

    [CATransaction commit];
    s.applyingLayout = NO;
}

#pragma mark - 1 秒定時刷新
static void CAScheduleRefresh(void) {
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (!g_enabled) return;
        for (UIView *host in g_hosts.allObjects) {
            CANativeStatusState *s = objc_getAssociatedObject(host, &kCAStateKey);
            if (s.battery)  CATakeOver(s.battery, YES);
            if (s.cellular) CATakeOver(s.cellular, YES);
            [s.battery setNeedsDisplay];
        }
    }];
}

#pragma mark - 偏好變更
static void CAReloadAll(void) {
    CALoadPrefs();
    for (UIView *host in g_hosts.allObjects) {
        CANativeStatusState *s = objc_getAssociatedObject(host, &kCAStateKey);
        if (s.battery)  CATakeOver(s.battery, g_enabled ? YES : NO);
        if (s.cellular) CATakeOver(s.cellular, g_enabled ? YES : NO);
        s.wifi.alpha = g_enabled ? 0 : 1;
        s.netType.alpha = g_enabled ? 0 : 1;
        s.cellular.alpha = g_enabled ? 0 : 1;
        [host setNeedsLayout];
        [host layoutIfNeeded];
        [s.battery setNeedsDisplay];
    }
}

#pragma mark - Hook 安裝
static void CAInstallHooks(void) {
    Class fg = ClassOrNil(@"STUIStatusBarForegroundView");
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");

    if (fg) MSHookMessageEx(fg, @selector(layoutSubviews),
                            (IMP)hook_fg_layout, (IMP *)&orig_fg_layout);
    if (bt) MSHookMessageEx(bt, @selector(drawRect:), (IMP)hook_batt_draw, (IMP *)&orig_batt_draw);

    SEL styleSel = NSSelectorFromString(@"applyStyleAttributes:");
    Class candidates[2] = {fg, bt};
    for (int i = 0; i < 2; i++) {
        Class c = candidates[i];
        if (!c) continue;
        if (class_getInstanceMethod(c, styleSel)) {
            MSHookMessageEx(c, styleSel, (IMP)hook_applyStyle, (IMP *)&orig_applyStyle);
            break;
        }
    }

    void *ct = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (ct) pCTGetSignalStrength = (CTGetSignalStrength_t)dlsym(ct, "CTGetSignalStrength");
}

#pragma mark - 入口
__attribute__((constructor)) static void ca_init(void) {
    CALoadPrefs();
    g_hosts = [NSHashTable weakObjectsHashTable];
    CAInstallHooks();

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
