/*
 * LockLayout —— 鎖屏排版微調（媒體播放器 / 通知列表 起始高度）
 * iOS 16–17 / RootHide rootless / SpringBoard
 *
 * 定位：
 *   CSCoverSheetViewController  鎖屏根控制器（CoverSheet）
 *   CSMediaControlsViewController 鎖屏媒體播放器
 *   CSCombinedListViewController / NCNotificationListView 鎖屏通知列表
 *
 * 做法：hook 佈局回調 → 系統排完版後，對目標視圖施加垂直 transform
 *       （transform 不會被系統佈局覆蓋；只影響鎖屏，其它語境不碰）
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#define kDomain CFSTR("com.shuijia.locklayout")
#define kNotifyPrefs CFSTR("com.shuijia.locklayout/prefs")
#define kNotifyScan  CFSTR("com.shuijia.locklayout/scan")

#pragma mark - 偏好

static BOOL    g_enabled  = YES;
static BOOL    g_mediaOn  = YES;
static BOOL    g_notifOn  = YES;
static CGFloat g_mediaOff = 0.0;    // pt，負=上移
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
    CGFloat mv = LLPrefFloat(@"mediaOffset", 1);   // 0–2，1＝原位（±100pt）
    if (mv < -0.001 || mv > 2.001) mv = 1;
    g_mediaOff = (mv - 1) * 100.0;
    CGFloat nv = LLPrefFloat(@"notifOffset", 1);   // 0–2，1＝原位（±250pt）
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

static void LLApplyNow(void) {
    if (!g_enabled) {
        if (g_mediaView) g_mediaView.transform = CGAffineTransformIdentity;
        if (g_notifView) g_notifView.transform = CGAffineTransformIdentity;
        return;
    }

    UIView *media = nil, *notif = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        int guard = 0;
        while (q.count && guard++ < 4000) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            if (!media && LLMatchMedia(cn) && LLIsLockContext(v)) media = v;
            if (!notif && LLMatchNotif(cn) && LLIsLockContext(v)) notif = v;
            if (media && notif) break;
            for (UIView *s in v.subviews) [q addObject:s];
        }
        if (media && notif) break;
    }

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

#pragma mark - Hook：佈局回調（系統排完版後立即套用）

static void (*orig_cs_root)(UIViewController *, SEL);
static void hook_cs_root(UIViewController *self, SEL _cmd) {
    orig_cs_root(self, _cmd);
    LLApplyAsync();
}

static void (*orig_cs_list)(UIViewController *, SEL);
static void hook_cs_list(UIViewController *self, SEL _cmd) {
    orig_cs_list(self, _cmd);
    LLApplyAsync();
}

static void (*orig_cs_media)(UIViewController *, SEL);
static void hook_cs_media(UIViewController *self, SEL _cmd) {
    orig_cs_media(self, _cmd);
    LLApplyAsync();
}

static void (*orig_nc_view)(UIView *, SEL);
static void hook_nc_view(UIView *self, SEL _cmd) {
    orig_nc_view(self, _cmd);
    LLApplyAsync();
}

static void LLHook(NSString *clsName, SEL sel, IMP hook, IMP *orig) {
    Class c = NSClassFromString(clsName);
    if (!c) return;
    if (!class_getInstanceMethod(c, sel)) return;
    MSHookMessageEx(c, sel, hook, orig);
}

#pragma mark - 掃描診斷：把鎖屏視圖樹導出成檔案（供作者精準定位）

static void LLDumpTree(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"# LockLayout lock-screen tree dump\n"];
    NSArray *keys = @[@"Media", @"NowPlaying", @"MRU", @"Notif", @"List",
                      @"CoverSheet", @"Lock", @"Poster", @"Complication", @"Chrono", @"Control"];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        [out appendFormat:@"\n== WINDOW %@ level=%.0f frame=%@\n",
            NSStringFromClass(w.class), (double)w.windowLevel, NSStringFromCGRect(w.frame)];
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        NSMutableArray *depth = [NSMutableArray arrayWithObject:@0];
        int guard = 0;
        while (q.count && guard++ < 4000) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            NSNumber *d = depth.firstObject; [depth removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            BOOL interesting = NO;
            for (NSString *k in keys)
                if ([cn rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) { interesting = YES; break; }
            if (interesting) {
                [out appendFormat:@"%@%@  frame=%@  hidden=%d alpha=%.2f\n",
                    [@"" stringByPaddingToLength:d.intValue * 2 withString:@" " startingAtIndex:0],
                    cn, NSStringFromCGRect(v.frame), v.hidden, v.alpha];
            }
            for (UIView *s in v.subviews) {
                [q addObject:s];
                [depth addObject:@(d.intValue + 1)];
            }
        }
    }
    NSString *path = @"/var/mobile/Library/Preferences/LockLayoutTree.txt";
    NSError *err = nil;
    BOOL ok = [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (!ok) {
        [out writeToFile:@"/tmp/LockLayoutTree.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        path = @"/tmp/LockLayoutTree.txt";
    }
    NSLog(@"[LockLayout] tree dumped to %@ (%@)", path, err);
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
    dispatch_async(dispatch_get_main_queue(), ^{ LLDumpTree(); });
}

#pragma mark - 入口

__attribute__((constructor)) static void ll_init(void) {
    LLLoadPrefs();

    LLHook(@"CSCoverSheetViewController",       @selector(viewDidLayoutSubviews), (IMP)hook_cs_root,  (IMP *)&orig_cs_root);
    LLHook(@"CSCombinedListViewController",     @selector(viewDidLayoutSubviews), (IMP)hook_cs_list,  (IMP *)&orig_cs_list);
    LLHook(@"CSMediaControlsViewController",    @selector(viewDidLayoutSubviews), (IMP)hook_cs_media, (IMP *)&orig_cs_media);
    LLHook(@"NCNotificationListView",           @selector(layoutSubviews),        (IMP)hook_nc_view,  (IMP *)&orig_nc_view);
    LLHook(@"NCNotificationListViewController", @selector(viewDidLayoutSubviews), (IMP)hook_cs_list,  (IMP *)&orig_cs_list);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        LLPrefsChangedCallback, kNotifyPrefs, NULL, (CFNotificationSuspensionBehavior)0);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        LLScanCallback, kNotifyScan, NULL, (CFNotificationSuspensionBehavior)0);

    // 每秒兜底（鎖屏捲動、動畫期間持續套用）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            LLApplyNow();
        }];
    });
}