/*
 * DuoStatusBar —— iPhone Duo 風格狀態欄 v1.5
 * iOS 16-17 / RootHide rootless / SpringBoard
 *
 * v1.5 修復：
 *   1. 設定「即時生效」根治：每秒定時器主動重讀偏好，不依賴 Darwin 通知；
 *      之前通知鏈路不可靠導致「左右/上下/大小拖了沒反應，要 respring 才生效」
 *   2. 移除「隱形邊框」：關閉畫布所有祖先視圖的 clipsToBounds，放大/移動不再被裁掉
 *   3. 黑底閃現：hook setBackgroundColor:/setOpaque:，系統想刷黑底直接攔掉
 *   4. CC 訊號讀不到：訊號檢索擴大到整個狀態欄視圖樹；原生讀不到時用 CoreTelephony 補
 *   5. 設定面板：所有滑桿 0–2、默認顯示 1（內部實際默認值不變），逐項詳細說明
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
/*
 * 新設定格式：所有滑桿 0–2，1 = 標準（內部實際默認值不變）
 * 舊值自動換算（偵測到超出 0–2 範圍的舊格式時）
 */

static BOOL    g_enabled  = YES;
static CGFloat g_scale    = 1.0;    // v=1 → 1.0
static CGFloat g_dx       = 0.0;    // v=1 → 0
static CGFloat g_dy       = 0.0;    // v=1 → 0
static CGFloat g_ringW    = 2.6;    // v=1 → 2.6
static CGFloat g_dotSize  = 1.1;    // v=1 → 1.1
static CGFloat g_wifiOff  = -0.5;   // v=1 → -0.5
static CGFloat g_arcGap   = 120.0;  // v=1 → 120°
static BOOL    g_dualBot  = NO;

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

    // scale：舊範圍 0.5–1.8 直接兼容（新舊都是「直接值」語義）
    g_scale = CAPrefFloat(@"scale", 1.0);
    if (g_scale > 2.001) g_scale = 1.0;                 // 異常值保護
    g_scale = MAX(0.4, MIN(2.2, g_scale));

    // offsetX：新 = (v-1)*60；舊格式（±60）→ 換算
    {
        CGFloat raw = CAPrefFloat(@"offsetX", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1 + MAX(-60.0, MIN(60.0, raw)) / 60.0;
        g_dx = (raw - 1) * 60;
    }
    // offsetY：新 = (v-1)*30
    {
        CGFloat raw = CAPrefFloat(@"offsetY", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1 + MAX(-30.0, MIN(30.0, raw)) / 30.0;
        g_dy = (raw - 1) * 30;
    }
    // ringWidth：新 = 2.6*v
    {
        CGFloat raw = CAPrefFloat(@"ringWidth", 1);
        if (raw < -0.001 || raw > 2.001) raw = MAX(0.4, MIN(2.2, raw / 2.6));
        g_ringW = MAX(0.8, MIN(5.6, 2.6 * raw));
    }
    // dotSize：新 = 1.1*v
    {
        CGFloat raw = CAPrefFloat(@"dotSize", 1);
        if (raw < -0.001 || raw > 2.001) raw = MAX(0.45, MIN(2.3, raw / 1.1));
        g_dotSize = MAX(0.5, MIN(2.5, 1.1 * raw));
    }
    // arcGap：新 = 120*v
    {
        CGFloat raw = CAPrefFloat(@"arcGap", 1);
        if (raw < -0.001 || raw > 2.001) raw = MAX(0.4, MIN(2.0, raw / 120.0));
        g_arcGap = MAX(60, MIN(170, 120.0 * raw));
    }
    // wifiOffset：新 = -0.5 + (v-1)*4
    {
        CGFloat raw = CAPrefFloat(@"wifiOffset", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1 + MAX(-4.0, MIN(4.0, raw)) / 4.0;
        g_wifiOff = MAX(-4, MIN(4, -0.5 + (raw - 1) * 4));
    }
    g_dualBot = CAPrefFloat(@"dualBottom", 0) != 0;
}

#pragma mark - 動態符號

typedef int (*CTGetSignalStrength_t)(int *, int *);
static CTGetSignalStrength_t pCTGetSignalStrength;

static int CACTBars(void) {
    if (!pCTGetSignalStrength) return -1;
    int a = 0, b = 0;
    pCTGetSignalStrength(&a, &b);
    if (a >= 0 && a <= 4 && b < 0) return a;
    if (a < 0 && b >= 0 && b <= 4) return b;
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

#pragma mark - 每個電池實例

@interface CABattInfo : NSObject
@property (nonatomic, assign) CGPoint naturalCenter;
@property (nonatomic, assign) BOOL captured;
@property (nonatomic, assign) CGPoint appliedCenter;
@end
@implementation CABattInfo
@end

static const char kCABattInfoKey = 0;
static NSHashTable<UIView *> *g_battViews;

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

// 走到狀態欄語境的根（最上層含 StatusBar 的祖先）
static UIView *CAStatusRoot(UIView *v) {
    UIView *root = v;
    while (root.superview &&
           ([NSStringFromClass(root.superview.class) containsString:@"StatusBar"] ||
            [NSStringFromClass(root.class) containsString:@"StatusBar"]))
        root = root.superview;
    return root;
}

static BOOL CAHideMatch(NSString *cn) {
    return [cn rangeOfString:@"Wifi" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Cellular" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Hotspot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"NetworkType" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Signal" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

#pragma mark - 接管

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

// 熱點 / 訊號：在整個狀態欄樹裡找
static BOOL CAHotspotActive(UIView *batt) {
    UIView *root = CAStatusRoot(batt);
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt) {
            NSString *cn = NSStringFromClass(v.class);
            if ([cn rangeOfString:@"Hotspot" options:NSCaseInsensitiveSearch].location != NSNotFound &&
                !v.hidden && v.alpha > 0.01) return YES;
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return NO;
}

static int CANativeBars(UIView *batt) {
    UIView *root = CAStatusRoot(batt);
    NSMutableArray *cands = [NSMutableArray array];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt && [NSStringFromClass(v.class) containsString:@"SignalView"])
            [cands addObject:v];
        for (UIView *s in v.subviews) [q addObject:s];
    }

    UIView *dual = nil, *single = nil;
    for (UIView *v in cands) {
        if ([NSStringFromClass(v.class) containsString:@"Dual"]) { dual = v; break; }
    }
    if (!dual)
        for (UIView *v in cands)
            if (![NSStringFromClass(v.class) containsString:@"Dual"]) { single = v; break; }

    if (dual) {
        UIView *row = nil;
        @try { row = [dual valueForKey:@"topSignalView"]; } @catch (id e) {}
        if (g_dualBot || !row) {
            UIView *other = nil;
            for (UIView *s in dual.subviews)
                if ([NSStringFromClass(s.class) containsString:@"SignalView"] && s != row) { other = s; break; }
            if (other) row = other;
            else if (!row && dual.subviews.count) row = dual.subviews.firstObject;
        }
        if (row) {
            NSInteger b = -1;
            @try { b = [[row valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
            if (b >= 0) return (int)MIN(MAX(b, 0), 4);
        }
        NSInteger b2 = -1;
        @try { b2 = [[dual valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
        if (b2 >= 0) return (int)MIN(MAX(b2, 0), 4);
    }
    if (single) {
        NSInteger b = -1;
        @try { b = [[single valueForKey:@"numberOfActiveBars"] integerValue]; } @catch (id e) {}
        if (b >= 0) return (int)MIN(MAX(b, 0), 4);
    }
    return -1;
}

static int CAPrimaryBars(UIView *batt) {
    int native = CANativeBars(batt);
    int ct = CACTBars();
    if (native <= 0 && ct > 0) return ct;          // 原生讀不到有效值 → CT 補
    if (native >= 0) return native;
    return ct >= 0 ? ct : 0;
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

    // 關掉所有祖先的裁剪 → 修「隱形邊框」：放大/移動不再被裁掉
    UIView *anc = batt;
    for (int i = 0; i < 12 && anc; i++) {
        if (anc.clipsToBounds) anc.clipsToBounds = NO;
        anc = anc.superview;
    }

    CGFloat S = 22.0 * g_scale;
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
    }

    CATakeOver(batt, YES);

    // 隱藏原生槽位（擴大到整個狀態欄樹）
    UIView *root = CAStatusRoot(batt);
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt && CAHideMatch(NSStringFromClass(v.class)) && v.alpha > 0.01)
            v.alpha = 0;
        for (UIView *s in v.subviews) [q addObject:s];
    }
}

#pragma mark - 前向聲明
static void (*orig_batt_draw)(UIView *, SEL);
static void hook_batt_draw(UIView *self, SEL _cmd);
static void (*orig_applyStyle)(UIView *, SEL, id);
static void hook_applyStyle(UIView *self, SEL _cmd, id attrs);
static void (*orig_setBg)(UIView *, SEL, UIColor *);
static void hook_setBg(UIView *self, SEL _cmd, UIColor *color);
static void (*orig_setOpaque)(UIView *, SEL, BOOL);
static void hook_setOpaque(UIView *self, SEL _cmd, BOOL opaque);

#pragma mark - 繪製部件

static void CADrawWifi(CGContextRef ctx, CGPoint c, CGFloat s, UIColor *ink) {
    CGContextSetLineWidth(ctx, 1.35 * s);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, ink.CGColor);
    CGPoint base = CGPointMake(c.x, c.y + 2.3 * s);
    const CGFloat radii[3] = {1.5, 3.6, 5.7};
    const CGFloat halfA = 0.26 * M_PI;
    for (int i = 0; i < 3; i++) {
        CGContextAddArc(ctx, base.x, base.y, radii[i] * s, -M_PI_2 - halfA, -M_PI_2 + halfA, 0);
        CGContextStrokePath(ctx);
    }
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(base.x - 1.1 * s, base.y - 1.1 * s, 2.2 * s, 2.2 * s));
}

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

#pragma mark - 主繪製

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

    int bars = CAPrimaryBars(self);
    const int dotCount = 4;
    CGFloat inset = M_PI * 28.0 / 180.0;
    CGFloat leftA  = M_PI_2 + gapHalf - inset;
    CGFloat rightA = M_PI_2 - gapHalf + inset;
    if (leftA < rightA) { CGFloat t = leftA; leftA = rightA; rightA = t; }
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
    CADressBattery(self);
    CADrawWidget(self, UIGraphicsGetCurrentContext(), self.bounds);
}

#pragma mark - 攔截系統刷黑底

static void hook_setBg(UIView *self, SEL _cmd, UIColor *color) {
    if (g_enabled && [self isKindOfClass:ClassOrNil(@"STUIStatusBarStaticBatteryView")]) {
        color = UIColor.clearColor;   // 黑底閃現根治：畫布永遠透明
    }
    if (orig_setBg) orig_setBg(self, _cmd, color);
}

static void hook_setOpaque(UIView *self, SEL _cmd, BOOL opaque) {
    if (g_enabled && [self isKindOfClass:ClassOrNil(@"STUIStatusBarStaticBatteryView")]) {
        opaque = NO;
    }
    if (orig_setOpaque) orig_setOpaque(self, _cmd, opaque);
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

#pragma mark - 每秒心跳：重讀偏好 + 重新釘位 + 重繪
static void CATick(void) {
    CGFloat os_ = g_scale, ox = g_dx, oy = g_dy, ow = g_ringW,
            od = g_dotSize, og = g_arcGap, of_ = g_wifiOff, ob = g_dualBot;
    BOOL oe = g_enabled;

    CALoadPrefs();

    BOOL changed = (os_ != g_scale) || (ox != g_dx) || (oy != g_dy) || (ow != g_ringW) ||
                   (od != g_dotSize) || (og != g_arcGap) || (of_ != g_wifiOff) ||
                   (ob != g_dualBot) || (oe != g_enabled);

    for (UIView *v in g_battViews.allObjects) {
        if (!g_enabled) {
            if (changed) CATakeOver(v, NO);
            else CATakeOver(v, NO);
            [v setNeedsDisplay];
            continue;
        }
        CADressBattery(v);       // 每秒釘位，任何東西都移不動
        [v setNeedsDisplay];
    }
}

#pragma mark - Hook 安裝

static void CAInstallHooks(void) {
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");

    if (bt) {
        MSHookMessageEx(bt, @selector(drawRect:), (IMP)hook_batt_draw, (IMP *)&orig_batt_draw);
        MSHookMessageEx(bt, @selector(setBackgroundColor:), (IMP)hook_setBg, (IMP *)&orig_setBg);
        MSHookMessageEx(bt, @selector(setOpaque:), (IMP)hook_setOpaque, (IMP *)&orig_setOpaque);
    }

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
                usingBlock:^(NSNotification *n) {
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            CATick();
        }];
    }];
}
