#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>

#define kDomain CFSTR("com.shuijia.duostatus")
#define kNotify CFSTR("com.shuijia.duostatus/preferencesChanged")

@interface DuoStatusRootListController : PSListController
@end

@implementation DuoStatusRootListController

#pragma mark - 規格表建構（依語言載入 RootCN / Root）

- (BOOL)ca_langCN {
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue(CFSTR("langSimple"), kDomain, &ok);
    return ok && v;
}

- (NSArray *)ca_buildSpecifiers {
    NSString *name = [self ca_langCN] ? @"RootCN" : @"Root";
    return [self loadSpecifiersFromPlistName:name target:self];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self ca_buildSpecifiers] mutableCopy];
    }
    return _specifiers;
}

#pragma mark - 語言切換 → 立即重建本頁

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    [super setPreferenceValue:value specifier:spec];
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:@"langSimple"]) {
        _specifiers = [[self ca_buildSpecifiers] mutableCopy];
        [self reloadSpecifiers];
    }
}

#pragma mark - 滑桿右側數字：點擊精確輸入（0–2）

- (BOOL)ca_isSliderKey:(NSString *)key {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"scale", @"offsetX", @"offsetY", @"ringWidth", @"arcGap",
                 @"wifiOffset", @"pctSize", @"pctOffsetX", @"pctOffsetY", @"dotSize"];
    });
    return key && [keys containsObject:key];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [super tableView:tv cellForRowAtIndexPath:ip];
    PSSpecifier *spec = [self specifierAtIndexPath:ip];
    NSString *key = [spec propertyForKey:@"key"];
    if ([self ca_isSliderKey:key]) {
        UIButton *btn = [cell.contentView viewWithTag:0xD0D0];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = 0xD0D0;
            btn.backgroundColor = UIColor.clearColor;
            btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                   UIViewAutoresizingFlexibleHeight;
            [btn addTarget:self action:@selector(ca_tapValue:)
          forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
        }
        // 覆蓋右側數值顯示區域
        CGFloat w = tv.bounds.size.width;
        btn.frame = CGRectMake(w - 92, 0, 92, cell.contentView.bounds.size.height);
        objc_setAssociatedObject(btn, "ca_spec", spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cell;
}

- (void)ca_tapValue:(UIButton *)btn {
    PSSpecifier *spec = objc_getAssociatedObject(btn, "ca_spec");
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return;

    CGFloat cur = 1.0;
    CFNumberRef n = (CFNumberRef)CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDomain);
    if (n) {
        CFNumberGetValue(n, kCFNumberCGFloatType, &cur);
        CFRelease(n);
    }

    BOOL cn = [self ca_langCN];
    NSString *title = cn ? @"精确输入数值" : @"精確輸入數值";
    NSString *msg   = cn ? @"可输入 0 – 2 之间的小数，例如 1.25" : @"可輸入 0 – 2 之間的小數，例如 1.25";

    UIAlertController *al = [UIAlertController alertControllerWithTitle:title
                                                                 message:msg
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.2f", cur];
        tf.textAlignment = NSTextAlignmentCenter;
    }];
    [al addAction:[UIAlertAction actionWithTitle:(cn ? @"取消" : @"取消")
                                           style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:(cn ? @"确定" : @"確定")
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        CGFloat v = [al.textFields.firstObject.text doubleValue];
        v = MAX(0.0, MIN(2.0, v));
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberCGFloatType, &v);
        CFPreferencesSetAppValue((__bridge CFStringRef)key, num, kDomain);
        CFRelease(num);
        CFPreferencesAppSynchronize(kDomain);
        // 通知 SpringBoard 立即生效
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kNotify, NULL, NULL, true);
        [self reloadSpecifier:spec animated:YES];
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

@end
