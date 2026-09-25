/*
 * LockLayout —— 鎖屏排版微調（媒體播放器 / 通知列表 起始高度）v1.1
 * iOS 16–17 / RootHide rootless / SpringBoard
 *
 * v1.1：
 *   1. 修復 hook 原函數指針共用導致的互相覆蓋（每個類獨立保存原 IMP）
 *   2. 診斷報告改為「鎖屏內直接彈出分享面板 + 同時複製到剪貼板」（不再依賴寫檔）
 *   3. 鎖屏出現後自動收集視圖樹（每 15 秒刷新一次），點按鈕即可立即分享
 *   4. 載入標記檔：驗證插件是否真的被注入
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define kDomain      CFSTR("com.shuijia.locklayout")
#define kNotifyPrefs CFSTR("com.shuijia.locklayout/prefs")
#define kNotifyScan  CFSTR("com.shuijia.locklayout/scan")

#pragma mark - 偏好

static BOOL    g_enabled  = YES;
static BOOL    g_mediaOn  = YES;
static BOOL    g_notifOn  = YES;
static CGFloat g_mediaOff = 0.0;
static CGFloat g_notifOff = 0.0;

static CGFloat LLPrefFloat(NSString *key, CGFloat def) {
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDomain);
    if (!n) return def;
    CGFloat v = def;
    CFNumberGetValue(n, kCFNumberCGFloatType, &v);
    CFRelease(n);
    return v;
}

static void LLLoadPrefs(void) {
    CFPreferencesAppSynchronize(kDomain);
    g_enabled = LLPrefFloat(@"enabled", 1) != 0;
    g_mediaOn = LLPrefFloat(@"mediaEnabled", 1) != 0;
    g_notifOn = LLPrefFloat(@"notifEnabled", 1) != 0;
    CGFloat mv = LLPrefFloat(@"mediaOffset", 1);
    if (mv < -0.001 || mv > 2.001) mv = 1;
    g_mediaOff = (mv - 1) * 100.0;
    CGFloat nv = LLPrefFloat(@"notifOffset", 1);
    if (nv < -0.001 || nv > 2.001) nv = 1;
    g_notifOff = (nv - 1) * 250.0;
}

#pragma mark - 語境與匹配

static BOOL LLIsLockContext(UIView *v) {
    UIResponder *r = v;
    int d = 0;
    while (r && d++ < 40) {
        NSString *cn = NSStringFromClass(r.class);
        if ([cn rangeOfString:@"CoverSheet" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cn rangeOfString:@"LockScreen" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
        if ([cn rangeOfString:@"Window" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return NO;
        r = r.nextResponder;
    }
    return NO;
}

static BOOL LLMatchMedia(NSString *cn) {
    return [cn containsString:@"MediaControls"] ||
           [cn containsString:@"NowPlaying"] ||
           [cn containsString:@"MRUNowPlaying"];
}

static BOOL LLMatchNotif(NSString *cn) {
    if ([cn containsString:@"NotificationListView"]) return YES;
    if ([cn containsString:@"CombinedListView"]) return YES;
    if ([cn containsString:@"NotificationListViewController"]) return YES;
    return NO;
}

#pragma mark - 施加位移

static __weak UIView *g_mediaView = nil;
static __weak UIView *g_notifView = nil;
static NSString *g_matchInfo = @"(尚未掃描)";

static CGFloat LLArea(UIView *v) { return v.frame.size.width * v.frame.size.height; }

// 收集：鎖屏內的通知列表 / 媒體播放器候選
static void LLCollectTargets(UIView **outMedia, UIView **outNotif,
                             NSMutableArray *mediaCands, NSMutableArray *notifCands) {
    UIView *media = nil, *notif = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        int guard = 0;
        while (q.count && guard++ < 6000) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            if (LLIsLockContext(v)) {
                if (LLMatchMedia(cn)) {
                    if (mediaCands) [mediaCands addObject:v];
                    if (!media || LLArea(v) > LLArea(media)) media = v;
                }
                if (LLMatchNotif(cn)) {
                    if (notifCands) [notifCands addObject:v];
                    if (!notif || LLArea(v) > LLArea(notif)) notif = v;
                }
            }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    }
    if (outMedia) *outMedia = media;
    if (outNotif) *outNotif = notif;
}

static void LLApplyNow(void) {
    if (!g_enabled) {
        if (g_mediaView) g_mediaView.transform = CGAffineTransformIdentity;
        if (g_notifView) g_notifView.transform = CGAffineTransformIdentity;
        return;
    }
    UIView *media = nil, *notif = nil;
    LLCollectTargets(&media, &notif, nil, nil);

    if (g_mediaOn && media) {
        g_mediaView = media;
        media.transform = CGAffineTransformMakeTranslation(0, g_mediaOff);
    } else if (g_mediaView) {
        g_mediaView.transform = CGAffineTransformIdentity;
    }
    if (g_notifOn && notif) {
        g_notifView = notif;
        notif.transform = CGAffineTransformMakeTranslation(0, g_notifOff);
    } else if (g_notifView) {
        g_notifView.transform = CGAffineTransformIdentity;
    }
}

static void LLApplyAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ LLApplyNow(); });
}

#pragma mark - 診斷報告：收集 + 分享/剪貼板

static NSString *g_lastReport = nil;
static NSString *g_lastLockReport = nil;      // 最近一次在鎖屏狀態擷取的報告
static NSDate   *g_lastLockReportAt = nil;

static BOOL LLockScreenVisible(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSString *cn = NSStringFromClass(w.class);
        if ([cn containsString:@"CoverSheetWindow"]) return !w.hidden;
    }
    return NO;
}

static NSString *LLBuildReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# LockLayout 鎖屏視圖報告 v1.3\n"];
    [out appendFormat:@"# 生成時間: %@\n", [NSDate date]];

    NSMutableArray *mediaCands = [NSMutableArray array];
    NSMutableArray *notifCands = [NSMutableArray array];
    UIView *m = nil, *n = nil;
    LLCollectTargets(&m, &n, mediaCands, notifCands);

    [out appendFormat:@"\n== 擷取情境 ==\n鎖屏可見=%@\n", LLockScreenVisible() ? @"YES" : @"NO"];
    [out appendString:@"\n== 命中目標（插件實際會移動的視圖）==\n"];
    [out appendFormat:@"媒體: %@  frame=%@\n", m ? NSStringFromClass(m.class) : @"(未找到)", m ? NSStringFromCGRect(m.frame) : @"-"];
    [out appendFormat:@"通知: %@  frame=%@\n", n ? NSStringFromClass(n.class) : @"(未找到)", n ? NSStringFromCGRect(n.frame) : @"-"];
    [out appendFormat:@"媒體候選 %lu 個：\n", (unsigned long)mediaCands.count];
    for (UIView *v in mediaCands)
        [out appendFormat:@"   - %@ frame=%@\n", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    [out appendFormat:@"通知候選 %lu 個：\n", (unsigned long)notifCands.count];
    for (UIView *v in notifCands)
        [out appendFormat:@"   - %@ frame=%@\n", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];

    g_matchInfo = [NSString stringWithFormat:@"媒體=%@ 通知=%@",
                   m ? NSStringFromClass(m.class) : @"無", n ? NSStringFromClass(n.class) : @"無"];

    // 所有視窗中的「媒體相關」與「通知相關」視圖（幫作者定位，不論是否鎖屏）
    [out appendString:@"\n== 媒體相關視圖（全部視窗）==\n"];
    [out appendString:@"\n== 通知相關視圖（全部視窗）==\n"];

    NSArray *keys = @[@"Media", @"NowPlaying", @"MRU", @"Notif", @"List", @"CoverSheet",
                      @"Lock", @"Poster", @"Complication", @"Chrono", @"Control"];
    NSMutableArray *mediaAll = [NSMutableArray array];
    NSMutableArray *notifAll = [NSMutableArray array];

    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        [out appendFormat:@"\n== WINDOW %@ level=%.0f frame=%@\n", NSStringFromClass(w.class),
            (double)w.windowLevel, NSStringFromCGRect(w.frame)];
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        NSMutableArray *dep = [NSMutableArray arrayWithObject:@0];
        int guard = 0;
        while (q.count && guard++ < 6000) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            NSNumber *d = dep.firstObject; [dep removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            if (LLMatchMedia(cn)) [mediaAll addObject:[NSString stringWithFormat:@"%@ (%@) %@",
                                    cn, NSStringFromClass(w.class), NSStringFromCGRect(v.frame)]];
            if (LLMatchNotif(cn)) [notifAll addObject:[NSString stringWithFormat:@"%@ (%@) %@",
                                    cn, NSStringFromClass(w.class), NSStringFromCGRect(v.frame)]];
            BOOL interesting = NO;
            for (NSString *k in keys)
                if ([cn rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    interesting = YES; break;
                }
            BOOL inLock = LLIsLockContext(v);
            BOOL bigEnough = v.frame.size.width > 20 && v.frame.size.height > 8;
            if ((interesting || inLock) && bigEnough) {
                [out appendFormat:@"%@%@%@ frame=%@ hidden=%d alpha=%.2f\n",
                    [@"" stringByPaddingToLength:d.intValue * 2 withString:@" " startingAtIndex:0],
                    inLock ? @"[LOCK] " : @"", cn,
                    NSStringFromCGRect(v.frame), v.hidden, v.alpha];
            }
            for (UIView *s in v.subviews) {
                [q addObject:s];
                [dep addObject:@(d.intValue + 1)];
            }
        }
    }
    // 插入媒體/通知總表
    NSMutableString *extra = [NSMutableString string];
    [extra appendString:@"\n== 媒體相關視圖（全部視窗）==\n"];
    for (NSString *l in mediaAll) [extra appendFormat:@"  %@\n", l];
    if (!mediaAll.count) [extra appendString:@"  (無)\n"];
    [extra appendString:@"\n== 通知相關視圖（全部視窗）==\n"];
    for (NSString *l in notifAll) [extra appendFormat:@"  %@\n", l];
    if (!notifAll.count) [extra appendString:@"  (無)\n"];

    [out insertString:extra atIndex:0];
    return out;
}

static void LLWriteReportFile(NSString *text) {
    NSArray *paths = @[@"/var/mobile/Library/Preferences/LockLayoutTree.txt",
                       @"/var/jb/var/mobile/Library/Preferences/LockLayoutTree.txt",
                       @"/var/mobile/Documents/LockLayoutTree.txt"];
    for (NSString *p in paths) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        [data writeToFile:p atomically:YES];
    }
}

// 在 SpringBoard 內直接彈分享面板（同時複製到剪貼板，雙保險）
static void LLPresentReport(NSString *text) {
    UIPasteboard.generalPasteboard.string = text;   // 一定可用的交付方式

    UIWindow *win = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (w.isKeyWindow) { win = w; break; }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;

    UIViewController *root = win.rootViewController;
    if (!root) return;

    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;

    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    av.modalPresentationStyle = UIModalPresentationPageSheet;
    if (av.popoverPresentationController) {
        av.popoverPresentationController.sourceView = top.view;
        av.popoverPresentationController.sourceRect =
            CGRectMake(top.view.bounds.size.width / 2.0, top.view.bounds.size.height / 2.0, 1, 1);
    }
    @try {
        [top presentViewController:av animated:YES completion:nil];
    } @catch (NSException *e) {
        UIAlertController *al = [UIAlertController
            alertControllerWithTitle:@"LockLayout"
                             message:@"報告已複製到剪貼板，直接貼到聊天視窗發給作者即可。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        @try { [top presentViewController:al animated:YES completion:nil]; } @catch (NSException *e2) {}
    }
}

static void LLScanNow(void) {
    NSString *rep = nil;
    if (g_lastLockReport) {
        NSTimeInterval age = g_lastLockReportAt ? -[g_lastLockReportAt timeIntervalSinceNow] : 9999;
        rep = [NSString stringWithFormat:@"# （此報告擷取自鎖屏狀態，%.0f 秒前）\n%@", age, g_lastLockReport];
    } else {
        rep = [NSString stringWithFormat:@"# （鎖屏時未成功擷取 → 以下是即時擷取；若鎖屏可見=NO，請先鎖屏停留 15 秒再點按鈕）\n%@",
               LLBuildReport()];
    }
    g_lastReport = rep;
    LLWriteReportFile(rep);
    LLPresentReport(rep);
}

#pragma mark - Hook（每個類獨立原函數指針，絕不共用）

#define LL_DEFINE_HOOK(name, sel, T)                       \
    static void (*orig_##name)(T, SEL);                    \
    static void hook_##name(T self, SEL _cmd) {            \
        if (orig_##name) orig_##name(self, _cmd);          \
        LLApplyAsync();                                    \
    }

LL_DEFINE_HOOK(cs_root,   viewDidLayoutSubviews, UIViewController *)
LL_DEFINE_HOOK(cs_list,   viewDidLayoutSubviews, UIViewController *)
LL_DEFINE_HOOK(cs_media,  viewDidLayoutSubviews, UIViewController *)
LL_DEFINE_HOOK(nc_list,   layoutSubviews,        UIView *)
LL_DEFINE_HOOK(cs_view,   layoutSubviews,        UIView *)
LL_DEFINE_HOOK(nc_vc,     viewDidLayoutSubviews, UIViewController *)
LL_DEFINE_HOOK(mru_view,  layoutSubviews,        UIView *)
LL_DEFINE_HOOK(cs_cl_view, layoutSubviews,       UIView *)

static void LLHook(NSString *clsName, SEL sel, IMP hook, IMP *orig) {
    Class c = NSClassFromString(clsName);
    if (!c) return;
    if (!class_getInstanceMethod(c, sel)) return;
    MSHookMessageEx(c, sel, hook, orig);
}

#pragma mark - 通知回調

static void LLPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LLLoadPrefs();
        LLApplyNow();
    });
}

static void LLScanCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ LLScanNow(); });
}

#pragma mark - 鎖屏自動收集（每 15 秒一次，讓報告隨時可用）

static void LLHookLockAppear(void) {
    // 鎖屏可見時自動擷取（節流 10 秒），保存「最近一次鎖屏狀態」的報告
    if (!LLockScreenVisible()) return;
    static double last = 0;
    double now = CACurrentMediaTime();
    if (now - last < 10.0) return;
    last = now;
    NSString *rep = LLBuildReport();
    g_lastLockReport = rep;
    g_lastLockReportAt = [NSDate date];
    LLWriteReportFile(rep);
}

#pragma mark - 入口

__attribute__((constructor)) static void ll_init(void) {
    LLLoadPrefs();

    // 載入標記檔（確認插件真的被注入）
    NSString *mark = [NSString stringWithFormat:@"LockLayout loaded at %@\n", [NSDate date]];
    [mark writeToFile:@"/var/mobile/Library/Preferences/LockLayoutLoaded.txt"
           atomically:YES encoding:NSUTF8StringEncoding error:nil];

    LLHook(@"CSCoverSheetView",                 @selector(layoutSubviews),        (IMP)hook_cs_view,  (IMP *)&orig_cs_view);
    LLHook(@"CSCoverSheetViewController",       @selector(viewDidLayoutSubviews), (IMP)hook_cs_root,  (IMP *)&orig_cs_root);
    LLHook(@"CSCombinedListViewController",     @selector(viewDidLayoutSubviews), (IMP)hook_cs_list,  (IMP *)&orig_cs_list);
    LLHook(@"CSCombinedListView",               @selector(layoutSubviews),        (IMP)hook_cs_cl_view, (IMP *)&orig_cs_cl_view);
    LLHook(@"CSMediaControlsViewController",    @selector(viewDidLayoutSubviews), (IMP)hook_cs_media, (IMP *)&orig_cs_media);
    LLHook(@"NCNotificationListView",           @selector(layoutSubviews),        (IMP)hook_nc_list,  (IMP *)&orig_nc_list);
    LLHook(@"NCNotificationListViewController", @selector(viewDidLayoutSubviews), (IMP)hook_nc_vc,    (IMP *)&orig_nc_vc);
    LLHook(@"MRUNowPlayingView",                @selector(layoutSubviews),        (IMP)hook_mru_view, (IMP *)&orig_mru_view);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        LLPrefsChangedCallback, kNotifyPrefs, NULL, (CFNotificationSuspensionBehavior)0);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        LLScanCallback, kNotifyScan, NULL, (CFNotificationSuspensionBehavior)0);

    // 每 5 秒兜底：套用位移 + 節流收集報告
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
            LLApplyNow();
            LLHookLockAppear();
        }];
    });
}