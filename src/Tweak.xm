/*
 * DuoStatusBar —— iPhone Duo 風格狀態欄 v1.4
 * iOS 16-17 / RootHide rootless / SpringBoard
 *
 * v1.4 修復：
 *   1. 每個電池控件實例獨立接管（含控制中心/鎖屏語境）：
 *      drawRect 內自我接管——就地變正方、清黑底、藏鄰居，不再依賴單一前景視圖 hook
 *   2. 個人熱點：偵測原生熱點控件（類名含 Hotspot）→ 隱藏它，圓心改畫「鏈環」圖標
 *   3. 訊號讀取：優先讀原生訊號控件 KVC（單卡直接讀；雙卡讀上排/下排可選），
 *      CoreTelephony 僅作兜底 → 修「明明有訊號顯示沒訊號」
 *   4. 圓弧長度可調（缺口角度 60°–160°，預設 110°），四個訊號點往內縮 18°，
 *      不再被圓環兩端覆蓋
 *   5. 錨點改為「每個實例首次出現時的自然中心」，樂園島動畫期間不再錯位
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <math.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

#pragma mark - 偏好（suite: com.shuijia.duostatus）

static BOOL    g_enabled  = YES;
static CGFloat g_scale    = 1.0;
static CGFloat g_dx       = 0.0;
static CGFloat g_dy       = 0.0;
static CGFloat g_ringW    = 2.6;
static CGFloat g_dotSize  = 1.1;
static CGFloat g_wifiOff  = -0.5;
static CGFloat g_arcGap   = 120.0;   // 缺口角度（圓環 = 360 - gap）
static BOOL    g_dualBot  = NO;      // 雙卡時主卡是否在下排

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
    g_scale   = MAX(0.5, MIN(1.8, CAPrefFloat(@"scale", 1.0)));
    g_dx      = CAPrefFloat(@"offsetX", 0);
    g_dy      = CAPrefFloat(@"offsetY", 0);
    g_ringW   = MAX(1.0, MIN(4.5, CAPrefFloat(@"ringWidth", 2.6)));
    g_dotSize = MAX(0.8, MIN(3.0, CAPrefFloat(@"dotSize", 1.1)));
    g_wifiOff = MAX(-4, MIN(4, CAPrefFloat(@"wifiOffset", -0.5)));
    g_arcGap  = MAX(60, MIN(160, CAPrefFloat(@"arcGap", 120)));
    g_dualBot = CAPrefFloat(@"dualBottom", 0) != 0;
}

#pragma mark - 動態符號

typedef int (*CTGetSignalStrength_t)(int *, int *);
static CTGetSignalStrength_t pCTGetSignalStrength;

static int CACTBars(void) {   // CoreTelephony 兜底（默認線路＝主卡）
    if (!pCTGetSignalStrength) return -1;
    int a = 0, b = 0;
    pCTGetSignalStrength(&a, &b);
    if (a >= 0 && a <= 4 && b < 0) return a;              // a=格數 b=dBm
    if (a < 0 && b >= 0 && b <= 4) return b;              // a=dBm b=格數
    int dbm = 0;
    if (a < -30 && a > -140) dbm = a;
    else if (b < -30 && b > -140) dbm = b;
    else return -1;
    if (dbm >= -85) return 4;
    if (dbm >= -95) return 3;
    if (dbm >= -105) return 2;
    if (dbm >= -113) return 1;
    return 0;
}

static BOOL CAWiFiConnected(void) {
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

#pragma mark - 每個電池實例的獨立狀態

@interface CABattInfo : NSObject
@property (nonatomic, assign) CGPoint naturalCenter;   // 首次出現時的自然中心
@property (nonatomic, assign) BOOL captured;
@property (nonatomic, assign) CGPoint appliedCenter;
@property (nonatomic, assign) CGFloat appliedSide;
@end
@implementation CABattInfo
@end

static const char kCABattInfoKey = 0;
static NSHashTable<UIView *> *g_battViews;   // 所有接管的電池控件（弱引用）

#pragma mark - 工具

static Class ClassOrNil(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) c = NSClassFromString([name stringByReplacingOccurrencesOfString:@"STUI" withString:@"UI"]);
    return c;
}

static BOOL CAIsStatusContext(UIView *v) {
    UIResponder *r = v;
    while (r) {
        NSString *cn = NSStringFromClass(r.class);
        if ([cn containsString:@"StatusBar"]) return YES;
        r = r.nextResponder;
    }
    return NO;
}

static BOOL CAClassNameIs(UIView *v, NSString *needle) {
    return [NSStringFromClass(v.class) rangeOfString:needle
                                             options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// 隐藏性質的鄰居（Wi-Fi/蜂窩/熱點等原生槽位，內容已由我們繪製）
static BOOL CAShouldHideSibling(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    return [cn rangeOfString:@"Wifi" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Cellular" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Hotspot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"NetworkType" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Signal" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// 熱點控件是否存在且可見
static BOOL CAHotspotActive(UIView *batt) {
    UIView *container = batt.superview;
    if (!container) return NO;
    for (UIView *sib in container.subviews) {
        if (sib == batt) continue;
        if (CAClassNameIs(sib, @"Hotspot") && !sib.hidden && sib.alpha > 0.01) return YES;
    }
    // 有時熱點控件在更深層
    NSMutableArray *q = [NSMutableArray arrayWithObject:container];
    int guard = 0;
    while (q.count && guard++ < 120) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt && CAClassNameIs(v, @"Hotspot") && !v.hidden && v.alpha > 0.01) return YES;
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return NO;
}

// 找到原生訊號控件並讀主卡格數
static int CANativeBars(UIView *batt) {
    UIView *container = batt.superview;
    if (!container) return -1;
    NSMutableArray *cands = [NSMutableArray array];
    NSMutableArray *q = [NSMutableArray arrayWithObject:container];
    int guard = 0;
    while (q.count && guard++ < 200) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt && [NSStringFromClass(v.class) containsString:@"SignalView"]) [cands addObject:v];
        for (UIView *s in v.subviews) [q addObject:s];
    }
    BOOL dual = NO;
    for (UIView *v in cands)
        if ([NSStringFromClass(v.class) containsString:@"Dual"]) dual = YES;

    if (!dual) {
        for (UIView *v in cands) {
            NSInteger b = -1;
            @try { b = [[v valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
            if (b >= 0) return (int)MIN(MAX(b, 0), 4);
        }
        return -1;
    }
    // 雙卡：優先 topSignalView / 首個子視圖；可切換下排
    for (UIView *dualView in cands) {
        if (![NSStringFromClass(dualView.class) containsString:@"Dual"]) continue;
        UIView *row = nil;
        @try { row = [dualView valueForKey:@"topSignalView"]; } @catch (id e) {}
        if (!row && dualView.subviews.count) {
            row = g_dualBot ? dualView.subviews.lastObject : dualView.subviews.firstObject;
        } else if (row && g_dualBot) {
            for (UIView *s in dualView.subviews)
                if (s != row && [NSStringFromClass(s.class) containsString:@"SignalView"]) { row = s; break; }
        }
        if (row) {
            NSInteger b = -1;
            @try { b = [[row valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
            if (b < 0) {
                @try { b = [[dualView valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
            }
            if (b >= 0) return (int)MIN(MAX(b, 0), 4);
        }
    }
    return -1;
}

static int CAPrimaryBars(UIView *batt) {
    int b = CANativeBars(batt);
    if (b >= 0) return b;
    int ct = CACTBars();
    return ct >= 0 ? ct : 0;
}

#pragma mark - 接管（清黑底 + 藏原生內容與鄰居 + 就地變正方）

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

static void CADressBattery(UIView *batt) {
    CABattInfo *info = objc_getAssociatedObject(batt, &kCABattInfoKey);
    if (!info) {
        info = [CABattInfo new];
        info.naturalCenter = batt.center;
        info.captured = YES;
        objc_setAssociatedObject(batt, &kCABattInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [g_battViews addObject:batt];
    }

    CGFloat S = 22.0 * g_scale;

    // 絕對錨定：以狀態欄容器「右緣」為基準 + 偏好偏移，
    // 與任何其他元素（樂園島/熱點/其他圖標）完全無關 → 位置永久固定
    UIView *container = batt.superview;
    CGPoint want;
    if (container && container.bounds.size.width > 40) {
        CGFloat W = container.bounds.size.width;
        CGFloat H = container.bounds.size.height;
        if (H < 20) H = 54.0;
        want = CGPointMake(W - 8.0 - S / 2.0 + g_dx, H / 2.0 + g_dy);
    } else {
        want = CGPointMake(info.naturalCenter.x + g_dx, info.naturalCenter.y + g_dy);
    }

    BOOL sizeDiff = fabs(batt.bounds.size.width - S) > 0.5 || fabs(batt.bounds.size.height - S) > 0.5;
    BOOL posDiff  = fabs(batt.center.x - want.x) > 0.5 || fabs(batt.center.y - want.y) > 0.5;
    if (sizeDiff || posDiff) {
        if (sizeDiff) batt.bounds = CGRectMake(0, 0, S, S);
        batt.center = want;
        info.appliedCenter = want;
        info.appliedSide = S;
    }

    CATakeOver(batt, YES);
    for (UIView *sib in batt.superview.subviews) {
        if (sib == batt) continue;
        if (CAShouldHideSibling(sib) && sib.alpha > 0.01) sib.alpha = 0;
    }
}

#pragma mark - 前向聲明
static void (*orig_batt_draw)(UIView *, SEL);
static void hook_batt_draw(UIView *self, SEL _cmd);
static void (*orig_applyStyle)(UIView *, SEL, id);
static void hook_applyStyle(UIView *self, SEL _cmd, id attrs);

#pragma mark - 繪製部件

static void CADrawWifi(CGContextRef ctx, CGPoint c, CGFloat s, UIColor *ink) {
    CGContextSetLineWidth(ctx, 1.35 * s);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGPoint base = CGPointMake(c.x, c.y + 2.3 * s);
    const CGFloat radii[3] = {1.5, 3.6, 5.7};        // 按參考圖比例：寬:高 ≈ 1:0.82
    const CGFloat halfA = 0.26 * M_PI;               // 各弧 ±46.8°
    for (int i = 0; i < 3; i++) {
        CGContextAddArc(ctx, base.x, base.y, radii[i] * s, -M_PI_2 - halfA, -M_PI_2 + halfA, 0);
        CGContextStrokePath(ctx);
    }
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(base.x - 1.1 * s, base.y - 1.1 * s, 2.2 * s, 2.2 * s));
}

// 個人熱點「鏈環」圖標：兩個互鎖的圓角環
static void CADrawHotspot(CGContextRef ctx, CGPoint c, CGFloat s, UIColor *ink) {
    CGContextSetLineWidth(ctx, 1.3 * s);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, c.x, c.y);
    CGContextRotateCTM(ctx, -0.30);
    UIBezierPath *l = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-4.0 * s, -1.75 * s, 5.6 * s, 3.5 * s)
                                                cornerRadius:1.75 * s];
    CGContextAddPath(ctx, l.CGPath);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, c.x + 1.9 * s, c.y);
    CGContextRotateCTM(ctx, 0.30);
    UIBezierPath *r = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-1.6 * s, -1.75 * s, 5.6 * s, 3.5 * s)
                                                cornerRadius:1.75 * s];
    CGContextAddPath(ctx, r.CGPath);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

#pragma mark - 主繪製：一個整圓

static void CADrawWidget(UIView *self, CGContextRef ctx, CGRect b) {
    CGFloat S = MIN(CGRectGetWidth(b), CGRectGetHeight(b));
    CGFloat k = S / 22.0;
    if (k <= 0) k = 1;
    CGContextClearRect(ctx, b);

    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat lw = g_ringW * k;
    CGFloat r = S / 2.0 - lw / 2.0 - 0.5 * k;

    CGFloat pct = 0;
    BOOL charging = NO;
    @try { pct = [[self valueForKey:@"chargePercent"] floatValue]; } @catch (id e) {}
    @try { charging = [[self valueForKey:@"chargingState"] intValue] != 0; } @catch (id e) {}
    if (pct < 0) pct = 0; if (pct > 1) pct = 1;

    UIColor *ink = charging ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                            : CAInk();

    CGFloat gapHalf = M_PI * (g_arcGap / 2.0) / 180.0;
    CGFloat startA  = M_PI_2 + gapHalf;
    CGFloat sweep   = 2 * M_PI - 2 * gapHalf;

    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, [ink colorWithAlphaComponent:0.22].CGColor);
    CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep, 0);
    CGContextStrokePath(ctx);

    if (pct > 0.003) {
        CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
        CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep * pct, 0);
        CGContextStrokePath(ctx);
    }

    // 訊號四點（缺口內，兩端各內縮 28°，與參考圖一致）
    int bars = CAPrimaryBars(self);
    const int dotCount = 4;
    CGFloat inset = M_PI * 28.0 / 180.0;
    CGFloat leftA  = M_PI_2 + gapHalf - inset;
    CGFloat rightA = M_PI_2 - gapHalf + inset;
    if (leftA < rightA) { CGFloat t = leftA; leftA = rightA; rightA = t; }   // 防呆
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

    // 圓心：熱點鏈環 > (Wi-Fi 符號 / 制式文字)
    CGPoint wc = CGPointMake(c.x, c.y + g_wifiOff * k);
    if (CAHotspotActive(self)) {
        CADrawHotspot(ctx, wc, r / 9.5, ink);
    } else if (CAWiFiConnected()) {
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
    if (!g_enabled || !CAIsStatusContext(self)) { orig_batt_draw(self, _cmd); return; }
    if (!g_ink) {
        UIColor *clock = CAScanClockColor(self);
        if (clock) g_ink = clock;
    }
    CADressBattery(self);   // 就地接管：變正方 + 清黑底 + 藏鄰居
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
        for (UIView *v in g_battViews.allObjects) [v setNeedsDisplay];
    }
}

#pragma mark - 1 秒定時刷新
static void CAScheduleRefresh(void) {
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (!g_enabled) return;
        for (UIView *v in g_battViews.allObjects) {
            CADressBattery(v);          // 每秒重新釘回固定位置，任何東西都移不動
            [v setNeedsDisplay];
        }
    }];
}

#pragma mark - 偏好變更
static void CAReloadAll(void) {
    CALoadPrefs();
    for (UIView *v in g_battViews.allObjects) {
        if (!g_enabled) CATakeOver(v, NO);
        [v setNeedsDisplay];
    }
}

#pragma mark - Hook 安裝
static void CAInstallHooks(void) {
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");

    if (bt) MSHookMessageEx(bt, @selector(drawRect:), (IMP)hook_batt_draw, (IMP *)&orig_batt_draw);

    SEL styleSel = NSSelectorFromString(@"applyStyleAttributes:");
    if (bt && class_getInstanceMethod(bt, styleSel))
        MSHookMessageEx(bt, styleSel, (IMP)hook_applyStyle, (IMP *)&orig_applyStyle);

    void *ct = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (ct) pCTGetSignalStrength = (CTGetSignalStrength_t)dlsym(ct, "CTGetSignalStrength");
}

#pragma mark - 入口
__attribute__((constructor)) static void ca_init(void) {
    CALoadPrefs();
    g_battViews = [NSHashTable weakObjectsHashTable];
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
