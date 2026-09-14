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
#include "hotspot_icon.h"

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
// 電量數字（新功能）
static BOOL    g_pctOn    = YES;
static CGFloat g_pctSize  = 10.0;   // v=1 → 10pt
static CGFloat g_pctX     = 0.0;    // v=1 → 0
static CGFloat g_pctY     = 0.0;    // v=1 → 0
static BOOL    g_pctRight = NO;     // 數字顯示在圓環右側（預設左側）
static BOOL    g_ccOn     = YES;    // 控制中心狀態欄：顯示 Duo 圖標（關閉＝完全原生）
// 控制中心專用微調（默認 1＝與主畫面一致）
static CGFloat g_ccScale  = 1.0;
static CGFloat g_ccDx     = 0.0;
static CGFloat g_ccDy     = 0.0;
// 元件開關（v1.8 精簡模式：默認只畫電量弧）
static BOOL    g_showTrack  = YES;  // 圓環底槽（v1.8.2 恢復默認顯示）
static BOOL    g_showDots   = YES;  // 訊號點（v1.8.2 恢復默認顯示）
static BOOL    g_showCenter = YES;  // 圓心 Wi-Fi/5G/熱點（v1.8.2 恢復默認顯示）

static CGFloat CAPrefFloat(NSString *key, CGFloat def) {
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                              CFSTR("com.shuijia.duostatus"));
    if (!n) return def;
    CGFloat v = def;
    CFNumberGetValue(n, kCFNumberCGFloatType, &v);
    CFRelease(n);
    return v;
}


// v1.10 基準遷移：滑桿一律歸 1；「1」的真實數值已改為用戶校準後的外觀
static void CAMigrateV110(void) {
    if (CAPrefFloat(@"v110", 0) != 0) return;
    NSArray *keys = @[@"scale", @"offsetX", @"offsetY", @"ringWidth", @"dotSize", @"arcGap",
                      @"wifiOffset", @"pctSize", @"pctOffsetX", @"pctOffsetY",
                      @"ccScale", @"ccOffsetX", @"ccOffsetY"];
    CGFloat one = 1.0;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberCGFloatType, &one);
    for (NSString *k in keys)
        CFPreferencesSetAppValue((__bridge CFStringRef)k, num, CFSTR("com.shuijia.duostatus"));
    CFRelease(num);
    CFNumberRef flag = CFNumberCreate(NULL, kCFNumberCGFloatType, &one);
    CFPreferencesSetAppValue(CFSTR("v110"), flag, CFSTR("com.shuijia.duostatus"));
    CFRelease(flag);
    CFPreferencesAppSynchronize(CFSTR("com.shuijia.duostatus"));
}

static void CALoadPrefs(void) {
    CAMigrateV110();
    CFPreferencesAppSynchronize(CFSTR("com.shuijia.duostatus"));

    g_enabled = CAPrefFloat(@"enabled", 1) != 0;

    // scale：v=1 → 1.6（用戶校準），線性 ±1 → [0.6, 2.6]
    {
        CGFloat raw = CAPrefFloat(@"scale", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_scale = MAX(0.4, MIN(2.6, 0.6 + raw));
    }
    // offsetX：v=1 → -24pt（用戶校準）
    {
        CGFloat raw = CAPrefFloat(@"offsetX", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_dx = MAX(-80, MIN(80, -24.0 + (raw - 1) * 60));
    }
    // offsetY：v=1 → +3pt（用戶校準）
    {
        CGFloat raw = CAPrefFloat(@"offsetY", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_dy = MAX(-50, MIN(50, 3.0 + (raw - 1) * 30));
    }
    // ringWidth：v=1 → 1.95（用戶校準）
    {
        CGFloat raw = CAPrefFloat(@"ringWidth", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_ringW = MAX(0.8, MIN(5.2, 1.95 * raw));
    }
    // dotSize：v=1 → 1.155（用戶校準）
    {
        CGFloat raw = CAPrefFloat(@"dotSize", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_dotSize = MAX(0.5, MIN(2.5, 1.155 * raw));
    }
    // arcGap：新 = 120*v
    {
        CGFloat raw = CAPrefFloat(@"arcGap", 1);
        if (raw < -0.001 || raw > 2.001) raw = MAX(0.4, MIN(2.0, raw / 120.0));
        g_arcGap = MAX(60, MIN(170, 120.0 * raw));
    }
    // wifiOffset：v=1 → +0.3（用戶校準）
    {
        CGFloat raw = CAPrefFloat(@"wifiOffset", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_wifiOff = MAX(-4, MIN(4, 0.3 + (raw - 1) * 4));
    }
    g_dualBot = CAPrefFloat(@"dualBottom", 0) != 0;

    // 電量數字
    g_pctOn = CAPrefFloat(@"pctEnabled", 1) != 0;
    {
        CGFloat raw = CAPrefFloat(@"pctSize", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_pctSize = MAX(5.0, MIN(22.0, 8.0 * raw));   // v=1 → 8pt（用戶校準）
    }
    {
        CGFloat raw = CAPrefFloat(@"pctOffsetX", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1 + MAX(-40.0, MIN(40.0, raw)) / 40.0;
        g_pctX = (raw - 1) * 40;
    }
    {
        CGFloat raw = CAPrefFloat(@"pctOffsetY", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_pctY = 2.0 + (raw - 1) * 20;   // v=1 → +2pt（用戶校準）
    }
    g_pctRight = CAPrefFloat(@"pctRight", 0) != 0;
    g_ccOn     = CAPrefFloat(@"ccEnabled", 1) != 0;
    {
        CGFloat raw = CAPrefFloat(@"ccScale", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_ccScale = MAX(0.5, MIN(2.0, raw));
    }
    {
        CGFloat raw = CAPrefFloat(@"ccOffsetX", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_ccDx = (raw - 1) * 60;
    }
    {
        CGFloat raw = CAPrefFloat(@"ccOffsetY", 1);
        if (raw < -0.001 || raw > 2.001) raw = 1;
        g_ccDy = (raw - 1) * 30;
    }
    g_showTrack  = CAPrefFloat(@"showTrack", 1) != 0;
    g_showDots   = CAPrefFloat(@"showDots", 1) != 0;
    g_showCenter = CAPrefFloat(@"showCenter", 1) != 0;
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

// 控制中心語境（CC 狀態欄恢復原生，不接管）
static BOOL CAIsControlCenterContext(UIView *v) {
    UIResponder *r = v;
    while (r) {
        NSString *cn = NSStringFromClass(r.class);
        if ([cn containsString:@"ControlCenter"] || [cn containsString:@"CCUI"])
            return YES;
        r = r.nextResponder;
    }
    return NO;
}

// 走到狀態欄語境的根（最上層含 StatusBar 的祖先；絕不爬進 Window，避免波及控制中心/桌面其他視圖）
static UIView *CAStatusRoot(UIView *v) {
    UIView *root = v;
    while (root.superview) {
        NSString *pcn = NSStringFromClass(root.superview.class);
        if ([pcn containsString:@"Window"] || [pcn containsString:@"Scene"]) break;
        if ([pcn containsString:@"StatusBar"]) { root = root.superview; continue; }
        break;
    }
    return root;
}

// 熱點文本匹配（類名/標識/標籤，含中英多種寫法）
static BOOL CAIsHotspotText(NSString *t) {
    if (![t isKindOfClass:NSString.class] || t.length == 0) return NO;
    if ([t rangeOfString:@"hotspot" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([t rangeOfString:@"PersonalHotspot"].location != NSNotFound) return YES;
    if ([t containsString:@"热点"] || [t containsString:@"熱點"]) return YES;
    if ([t containsString:@"个人热点"] || [t containsString:@"個人熱點"]) return YES;
    return NO;
}

// 檢視任意視圖是否是「熱點原生控件」（檢查多個 KVC 鍵）
static BOOL CAViewIsHotspot(UIView *v) {
    if (CAIsHotspotText(NSStringFromClass(v.class))) return YES;
    for (NSString *key in @[@"identifier", @"itemIdentifier", @"_identifier",
                            @"identifierString", @"accessibilityIdentifier", @"accessibilityLabel"]) {
        @try {
            id val = [v valueForKey:key];
            if (CAIsHotspotText(val)) return YES;
        } @catch (id e) {}
    }
    // 有些版本把 item 掛在視圖上
    @try {
        id item = [v valueForKey:@"item"];
        if (item && CAIsHotspotText(NSStringFromClass([item class]))) return YES;
    } @catch (id e) {}
    return NO;
}

// 隱藏匹配：必須是狀態欄自己的控件（類名含 StatusBar）才隱藏，
// 且不碰控制中心模組（那裡的 SIM 訊號條要保留）
static BOOL CAHideMatch(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    if (CAIsHotspotText(cn)) return YES;    // 熱點控件不管叫什麼都藏
    if ([cn rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return NO;
    return [cn rangeOfString:@"Wifi" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [cn rangeOfString:@"Cellular" options:NSCaseInsensitiveSearch].location != NSNotFound ||
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

// 熱點：在整個窗口範圍內找（類名 + identifier/標籤 多重匹配）
static BOOL CAHotspotActive(UIView *batt) {
    UIView *root = batt.window ?: CAStatusRoot(batt);
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt && !v.hidden && v.alpha > 0.01) {
            if (CAViewIsHotspot(v)) return YES;
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return NO;
}

static int CANativeBars(UIView *batt) {
    // 在整個窗口範圍內找原生訊號控件（只認狀態欄自己的控件，控制中心模組不受影響）
    UIView *root = batt.window ?: CAStatusRoot(batt);
    NSMutableArray *cands = [NSMutableArray array];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 1500) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        if (v != batt && [cn containsString:@"StatusBar"] && [cn containsString:@"SignalView"])
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

    // 只關閉「狀態欄內部」視圖的裁剪與遮罩（絕不碰窗口/更高層，
    // 否則會破壞系統的圓角遮罩：開 App 動畫、後台卡片圓角變方形就是這個原因）
    // 控制中心語境：額外允許走 CC/CoverSheet 類祖先（修 CC 裡的隱形邊框），同樣遇 Window 即停
    BOOL inCC = CAIsControlCenterContext(batt);
    UIView *anc = batt;
    while (anc) {
        NSString *cn = NSStringFromClass(anc.class);
        if ([cn rangeOfString:@"Window" options:NSCaseInsensitiveSearch].location != NSNotFound) break;
        BOOL isSB = [cn rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL isCC = [cn rangeOfString:@"ControlCenter" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [cn rangeOfString:@"CCUI" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [cn rangeOfString:@"CoverSheet" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (anc != batt && !isSB && !(inCC && isCC)) break;
        if (anc.clipsToBounds) anc.clipsToBounds = NO;
        anc.layer.masksToBounds = NO;
        anc = anc.superview;
    }
    // 畫布自身：強制 CALayer 透明（對抗系統可能直接改 layer 的 opaque/背景）
    batt.layer.opaque = NO;
    batt.layer.backgroundColor = NULL;

    // 控制中心可用獨立縮放/偏移（ccScale/ccOffsetX/ccOffsetY，默認 1 與主畫面一致）
    CGFloat effScale = g_scale * (inCC ? g_ccScale : 1.0);
    CGFloat effDx = g_dx + (inCC ? g_ccDx : 0.0);
    CGFloat effDy = g_dy + (inCC ? g_ccDy : 0.0);

    CGFloat S = 22.0 * effScale;
    // 電量數字的預留寬度（畫布向右擴展，圓環仍貼右緣）
    CGFloat fontPt = g_pctSize * effScale;
    CGFloat tw = g_pctOn ? (fontPt * 3.1 + 4.0) : 0.0;
    CGFloat canvasW = S + tw;

    // 往上找到足夠寬的容器作錨定基準（避免被小包裝盒寬度干擾）
    UIView *container = batt.superview;
    while (container && container.bounds.size.width <= 100 && container.superview)
        container = container.superview;

    CGPoint want;
    if (container && container.bounds.size.width > 100) {
        // ★ 以「螢幕(視窗)座標」錨定右上角：主畫面與控制中心的圖標會落在同一位置，
        //   上/下拉控制中心過場時不會再出現兩個圖標錯位疊影
        CGFloat W = container.bounds.size.width;
        CGFloat H = container.bounds.size.height;
        if (H < 20) H = 54.0;
        CGPoint anchor = CGPointMake(W - 8.0 - canvasW / 2.0 + effDx, H / 2.0 + effDy);
        UIView *win = batt.window;
        if (win) {
            CGPoint inWin = [container convertPoint:anchor toView:nil];
            inWin.x = win.bounds.size.width - 8.0 - canvasW / 2.0 + effDx;
            anchor = [container convertPoint:inWin fromView:nil];
        }
        want = anchor;
    } else {
        want = CGPointMake(info.naturalCenter.x + effDx, info.naturalCenter.y + effDy);
    }

    BOOL sizeDiff = fabs(batt.bounds.size.width - canvasW) > 0.5 ||
                    fabs(batt.bounds.size.height - S) > 0.5;
    BOOL posDiff  = fabs(batt.center.x - want.x) > 0.5 || fabs(batt.center.y - want.y) > 0.5;
    if (sizeDiff || posDiff) {
        if (sizeDiff) batt.bounds = CGRectMake(0, 0, canvasW, S);
        batt.center = want;
        info.appliedCenter = want;
    }

    CATakeOver(batt, YES);

    // 控制中心語境：不隱藏任何原生項（左側雙卡訊號列/熱點圖標等全部保留），只接管電量畫布
    if (CAIsControlCenterContext(batt)) return;

    // 隱藏原生槽位（擴大到整個狀態欄樹；類名或 identifier 命中都藏）
    UIView *root = CAStatusRoot(batt);
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (q.count && guard++ < 800) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != batt) {
            if (CAHideMatch(v) && v.alpha > 0.01) v.alpha = 0;
        }
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
    CGPoint base = CGPointMake(c.x, c.y + 2.2 * s);
    const CGFloat radii[3] = {2.1, 3.9, 5.7};        // 內圈加大間距 → 底部圓點不再與弧線黏在一起
    const CGFloat halfA = 0.26 * M_PI;
    for (int i = 0; i < 3; i++) {
        CGContextAddArc(ctx, base.x, base.y, radii[i] * s, -M_PI_2 - halfA, -M_PI_2 + halfA, 0);
        CGContextStrokePath(ctx);
    }
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(base.x - 0.95 * s, base.y - 0.95 * s, 1.9 * s, 1.9 * s));
}

// 個人熱點「鏈環」圖標：使用嵌入的素材遮罩（灰度 alpha），以當前墨水色填充
static CGImageRef g_hotspotImg = NULL;
static CGImageRef CAHotspotImage(void) {
    if (g_hotspotImg) return g_hotspotImg;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, kHotspotMask,
                                                        (size_t)kHotspotW * kHotspotH, NULL);
    if (cs && dp) {
        g_hotspotImg = CGImageCreate(kHotspotW, kHotspotH, 8, 8, kHotspotW, cs,
                                     kCGImageAlphaNone, dp, NULL, false, kCGRenderingIntentDefault);
    }
    if (dp) CGDataProviderRelease(dp);
    if (cs) CGColorSpaceRelease(cs);
    return g_hotspotImg;
}

static void CADrawHotspot(CGContextRef ctx, CGPoint c, CGFloat s, UIColor *ink) {
    CGImageRef img = CAHotspotImage();
    if (!img) return;
    CGFloat w = 21.0 * s;                       // 顯示寬（素材比例 132:78）
    CGFloat h = w * (CGFloat)kHotspotH / (CGFloat)kHotspotW;
    CGRect ir = CGRectMake(c.x - w / 2.0, c.y - h / 2.0, w, h);
    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, ir, img);
    CGContextSetFillColorWithColor(ctx, ink.CGColor);
    CGContextFillRect(ctx, ir);
    CGContextRestoreGState(ctx);
}

#pragma mark - 主繪製

static void CADrawWidget(UIView *self, CGContextRef ctx, CGRect b) {
    CGFloat S = MIN(b.size.height, b.size.width);   // 圓的直徑＝畫布高度
    CGFloat k = S / 22.0;
    if (k <= 0) k = 1;
    // 不再使用 CGContextClearRect：在不透明渲染路徑下「清屏」會變黑，這裡完全不依賴清屏

    // 圓環位置：數字在左側時圓環靠畫布右緣；數字在右側時圓環靠畫布左緣
    CGPoint c = CGPointMake(g_pctRight ? (CGRectGetMinX(b) + S / 2.0)
                                       : (CGRectGetMaxX(b) - S / 2.0),
                            CGRectGetMidY(b));
    CGFloat lw = g_ringW * k;
    CGFloat r = S / 2.0 - lw / 2.0 - 0.5 * k;

    CGFloat pct = 0;
    BOOL charging = NO;
    @try { pct = [[self valueForKey:@"chargePercent"] floatValue]; } @catch (id e) {}
    @try { charging = [[self valueForKey:@"chargingState"] intValue] != 0; } @catch (id e) {}
    if (pct < 0 || pct > 1) {
        CGFloat lvl = UIDevice.currentDevice.batteryLevel;
        if (lvl >= 0) pct = lvl;
    }
    if (pct < 0) pct = 0; if (pct > 1) pct = 1;

    // 顏色規則：只有「電量弧」充電時變綠；其餘元素（底槽/訊號點/圓心圖標/電量數字）永遠保持原色
    UIColor *fancy  = CAInk();
    UIColor *arcInk = charging ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
                               : CAInk();

    CGFloat gapHalf = M_PI * (g_arcGap / 2.0) / 180.0;
    CGFloat startA  = M_PI_2 + gapHalf;
    CGFloat sweep   = 2 * M_PI - 2 * gapHalf;

    // 圓環底槽（默認關閉）
    if (g_showTrack) {
        CGContextSetLineWidth(ctx, lw);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetStrokeColorWithColor(ctx, [fancy colorWithAlphaComponent:0.22].CGColor);
        CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep, 0);
        CGContextStrokePath(ctx);
    }

    // 電量弧（核心元素：白色 / 充電綠色）
    if (pct > 0.003) {
        CGContextSetLineWidth(ctx, lw);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetStrokeColorWithColor(ctx, arcInk.CGColor);
        CGContextAddArc(ctx, c.x, c.y, r, startA, startA + sweep * pct, 0);
        CGContextStrokePath(ctx);
    }

    // 訊號四點（默認關閉）
    if (g_showDots) {
        int bars = CAPrimaryBars(self);
        const int dotCount = 4;
        CGFloat inset = M_PI * 28.0 / 180.0;
        CGFloat leftA  = M_PI_2 + gapHalf - inset;
        CGFloat rightA = M_PI_2 - gapHalf + inset;
        if (leftA < rightA) { CGFloat t = leftA; leftA = rightA; rightA = t; }
        CGFloat dotR = g_dotSize * k;
        UIColor *dim = [fancy colorWithAlphaComponent:0.22];
        for (int i = 0; i < dotCount; i++) {
            CGFloat t = (CGFloat)i / (dotCount - 1);
            CGFloat ang = leftA + (rightA - leftA) * t;
            CGPoint d = CGPointMake(c.x + cos(ang) * r, c.y + sin(ang) * r);
            BOOL on = (i < bars);
            CGContextSetFillColorWithColor(ctx, (on ? fancy : dim).CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(d.x - dotR, d.y - dotR, dotR * 2, dotR * 2));
        }
    }

    // 圓心圖標（默認關閉）
    if (g_showCenter) {
        CGPoint wc = CGPointMake(c.x, c.y + g_wifiOff * k);
        if (CAHotspotActive(self)) {
            CADrawHotspot(ctx, wc, r / 9.5, fancy);
        } else if (CAWiFiConnected()) {
            CADrawWifi(ctx, wc, r / 9.5, fancy);
        } else {
            NSString *rat = CARATString();
            if (rat.length) {
                NSDictionary *attrs = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:7.6 * k weight:UIFontWeightBold],
                    NSForegroundColorAttributeName: fancy
                };
                CGSize sz = [rat sizeWithAttributes:attrs];
                [rat drawAtPoint:CGPointMake(wc.x - sz.width / 2.0, wc.y - sz.height / 2.0)
                  withAttributes:attrs];
            }
        }
    }

    // 電量數字（可開關/調大小/調位置；可選在圓環左側或右側）
    if (g_pctOn) {
        NSString *txt = [NSString stringWithFormat:@"%d%%", (int)round(pct * 100)];
        UIFont *f = [UIFont monospacedDigitSystemFontOfSize:g_pctSize * g_scale
                                                     weight:UIFontWeightSemibold];
        NSDictionary *attrs = @{NSFontAttributeName: f, NSForegroundColorAttributeName: fancy};
        CGSize sz = [txt sizeWithAttributes:attrs];
        CGFloat x, y = c.y - sz.height / 2.0 + g_pctY * k;
        if (g_pctRight) {
            x = c.x + S / 2.0 + 4.0 + g_pctX * k;              // 圓環右側
        } else {
            x = c.x - S / 2.0 - 4.0 - sz.width + g_pctX * k;   // 圓環左側（預設）
        }
        [txt drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
    }
}

static void hook_batt_draw(UIView *self, SEL _cmd) {
    if (!g_enabled || !CAIsStatusContext(self)) { orig_batt_draw(self, _cmd); return; }
    // 控制中心語境：開關關閉時完全放行原生
    if (CAIsControlCenterContext(self) && !g_ccOn) { orig_batt_draw(self, _cmd); return; }
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

#pragma mark - 前景佈局 hook：系統排完版後立刻把我們的視圖釘回去（保證滑桿即時且位置不被系統覆蓋）

static void (*orig_fg_layout)(UIView *, SEL);
static void hook_fg_layout(UIView *self, SEL _cmd) {
    orig_fg_layout(self, _cmd);
    if (!g_enabled) return;
    for (UIView *v in g_battViews.allObjects) {
        // 只處理屬於這個狀態欄實例的電池視圖
        UIView *root = CAStatusRoot(v);
        if (root == self || [self isDescendantOfView:root] || [root isDescendantOfView:self]) {
            CADressBattery(v);
            [v setNeedsDisplay];
        }
    }
}

#pragma mark - Hook 安裝

static void CAInstallHooks(void) {
    Class bt = ClassOrNil(@"STUIStatusBarStaticBatteryView");
    Class fg = ClassOrNil(@"STUIStatusBarForegroundView");

    if (bt) {
        MSHookMessageEx(bt, @selector(drawRect:), (IMP)hook_batt_draw, (IMP *)&orig_batt_draw);
        MSHookMessageEx(bt, @selector(setBackgroundColor:), (IMP)hook_setBg, (IMP *)&orig_setBg);
        MSHookMessageEx(bt, @selector(setOpaque:), (IMP)hook_setOpaque, (IMP *)&orig_setOpaque);
    }
    if (fg) {
        MSHookMessageEx(fg, @selector(layoutSubviews), (IMP)hook_fg_layout, (IMP *)&orig_fg_layout);
    }

    SEL styleSel = NSSelectorFromString(@"applyStyleAttributes:");
    if (bt && class_getInstanceMethod(bt, styleSel))
        MSHookMessageEx(bt, styleSel, (IMP)hook_applyStyle, (IMP *)&orig_applyStyle);

    void *ct = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    if (ct) pCTGetSignalStrength = (CTGetSignalStrength_t)dlsym(ct, "CTGetSignalStrength");
}

#pragma mark - Darwin 通知（即時生效）
static void CAPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ CATick(); });
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
            CATick();   // 每秒兜底；正常情況滑桿一鬆手就會由通知即時觸發
        }];
    }];

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        CAPrefsChangedCallback,
        CFSTR("com.shuijia.duostatus/preferencesChanged"), NULL,
        (CFNotificationSuspensionBehavior)0);
}
