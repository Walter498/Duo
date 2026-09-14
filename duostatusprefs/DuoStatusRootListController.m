#import <Preferences/PSListController.h>

@interface DuoStatusRootListController : PSListController
@end

@implementation DuoStatusRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
