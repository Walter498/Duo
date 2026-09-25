#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>

#define kDomain CFSTR("com.shuijia.locklayout")
#define kNotify CFSTR("com.shuijia.locklayout/prefs")
#define kScan   CFSTR("com.shuijia.locklayout/scan")

@interface LockLayoutRootListController : PSListController
@end

@implementation LockLayoutRootListController

- (BOOL)ll_langCN {
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue(CFSTR("langSimple"), kDomain, &ok);
    return ok && v;
}

- (NSArray *)ll_build {
    return [self loadSpecifiersFromPlistName:([self ll_langCN] ? @"RootCN" : @"Root") target:self];
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [[self ll_build] mutableCopy];
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    [super setPreferenceValue:value specifier:spec];
    if ([[spec propertyForKey:@"key"] isEqualToString:@"langSimple"]) {
        _specifiers = [[self ll_build] mutableCopy];
        [self reloadSpecifiers];
    }
}

#pragma mark - 掃描按鈕：請 SpringBoard 內的插件導出鎖屏視圖樹

- (void)ll_scan:(PSSpecifier *)spec {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kScan, NULL, NULL, true);
    BOOL cn = [self ll_langCN];
    NSString *msg = cn
        ? @"已在後台生成鎖屏視圖報告：\n/var/mobile/Library/Preferences/LockLayoutTree.txt\n\n請把這個檔案發給作者，就能精準對位。"
        : @"已在後台生成鎖屏視圖報告：\n/var/mobile/Library/Preferences/LockLayoutTree.txt\n\n請把這個檔案發給作者，就能精準對位。";
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"LockLayout"
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

#pragma mark - 滑桿右側數字：點擊精確輸入

- (BOOL)ll_isSliderKey:(NSString *)key {
    return [key isEqualToString:@"mediaOffset"] || [key isEqualToString:@"notifOffset"];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [super tableView:tv cellForRowAtIndexPath:ip];
    PSSpecifier *spec = [self specifierAtIndexPath:ip];
    NSString *key = [spec propertyForKey:@"key"];
    if ([self ll_isSliderKey:key]) {
        UIButton *btn = [cell.contentView viewWithTag:0xD0D1];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = 0xD0D1;
            btn.backgroundColor = UIColor.clearColor;
            btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                   UIViewAutoresizingFlexibleHeight;
            [btn addTarget:self action:@selector(ll_tapValue:)
          forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
        }
        btn.frame = CGRectMake(tv.bounds.size.width - 92, 0, 92, cell.contentView.bounds.size.height);
        objc_setAssociatedObject(btn, "ll_spec", spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)ll_tapValue:(UIButton *)btn {
    PSSpecifier *spec = objc_getAssociatedObject(btn, "ll_spec");
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return;
    CGFloat cur = 1.0;
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDomain);
    if (n) { CFNumberGetValue(n, kCFNumberCGFloatType, &cur); CFRelease(n); }

    BOOL cn = [self ll_langCN];
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:(cn ? @"精确输入数值" : @"精確輸入數值")
                         message:(cn ? @"可输入 0 – 2 之间的小数，1＝原始位置" : @"可輸入 0 – 2 之間的小數，1＝原始位置")
                  preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.2f", cur];
        tf.textAlignment = NSTextAlignmentCenter;
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:(cn ? @"确定" : @"確定")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        CGFloat v = MAX(0.0, MIN(2.0, [al.textFields.firstObject.text doubleValue]));
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberCGFloatType, &v);
        CFPreferencesSetAppValue((__bridge CFStringRef)key, num, kDomain);
        CFRelease(num);
        CFPreferencesAppSynchronize(kDomain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kNotify, NULL, NULL, true);
        [self reloadSpecifier:spec animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

@end