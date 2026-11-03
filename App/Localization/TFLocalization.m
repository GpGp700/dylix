#import "TFLocalization.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>

static BOOL TFIsArabic = NO;
static NSDictionary<NSString *, NSString *> *TFTranslationTable = nil;
static NSCache<NSString *, NSString *> *TFTranslationCache = nil;
static NSDictionary<NSString *, NSArray<NSDictionary *> *> *TFTemplatesByCharacter = nil;

static BOOL TFHasHan(NSString *text) {
    if (text.length == 0) return NO;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if ((character >= 0x3400 && character <= 0x4DBF) ||
            (character >= 0x4E00 && character <= 0x9FFF) ||
            (character >= 0xF900 && character <= 0xFAFF)) {
            return YES;
        }
    }
    return NO;
}

static BOOL TFDetectArabic(void) {
    const char *forced = getenv("DYLIX_ARABIC");
    if (forced && forced[0] && !(forced[0] == '0' && forced[1] == '\0')) return YES;
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument isEqualToString:@"-DylixArabic"] || [argument isEqualToString:@"--dylix-arabic"]) return YES;
    }

    NSString *language = [[NSUserDefaults standardUserDefaults] arrayForKey:@"AppleLanguages"].firstObject;
    if (language.length == 0) language = NSLocale.preferredLanguages.firstObject;
    if ([language.lowercaseString hasPrefix:@"ar"]) return YES;

    NSString *preferred = NSBundle.mainBundle.preferredLocalizations.firstObject;
    return [preferred.lowercaseString hasPrefix:@"ar"];
}

static NSRegularExpression *TFSpecificationExpression(void) {
    static NSRegularExpression *expression = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Matches the printf-style placeholders used by the app, including %@,
        // %lu, %.1f, positional forms, and the literal %%.
        expression = [NSRegularExpression regularExpressionWithPattern:
                      @"%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|z|t|j)?[diuoxXfFeEgGcs@%]"
                                                               options:0 error:nil];
    });
    return expression;
}

static NSString *TFEscapedPattern(NSString *literal) {
    static NSCharacterSet *metacharacters = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        metacharacters = [NSCharacterSet characterSetWithCharactersInString:@"\\^$.*+?()[]{}|"];
    });
    NSMutableString *escaped = [NSMutableString stringWithCapacity:literal.length + 8];
    for (NSUInteger index = 0; index < literal.length; index++) {
        unichar character = [literal characterAtIndex:index];
        if ([metacharacters characterIsMember:character]) [escaped appendString:@"\\"];
        [escaped appendFormat:@"%C", character];
    }
    return escaped;
}

static NSDictionary *TFTemplateForKey(NSString *key, NSString *translation, NSRegularExpression *specification) {
    NSArray<NSTextCheckingResult *> *keyMatches = [specification matchesInString:key options:0 range:NSMakeRange(0, key.length)];
    if (keyMatches.count == 0) return nil;

    NSMutableString *pattern = [NSMutableString stringWithString:@"^"];
    NSMutableArray<NSString *> *specifications = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in keyMatches) {
        if (match.range.location > cursor) {
            [pattern appendString:TFEscapedPattern([key substringWithRange:NSMakeRange(cursor, match.range.location - cursor)])];
        }
        NSString *token = [key substringWithRange:match.range];
        if ([token isEqualToString:@"%%"]) {
            [pattern appendString:@"%"];
        } else {
            [pattern appendString:@"(.+?)"];
            [specifications addObject:token];
        }
        cursor = NSMaxRange(match.range);
    }
    if (cursor < key.length) [pattern appendString:TFEscapedPattern([key substringFromIndex:cursor])];
    [pattern appendString:@"$"];

    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                options:NSRegularExpressionDotMatchesLineSeparators
                                                                                  error:nil];
    if (!expression) return nil;

    NSMutableArray<NSString *> *translatedSpecifications = [NSMutableArray array];
    for (NSTextCheckingResult *match in [specification matchesInString:translation options:0 range:NSMakeRange(0, translation.length)]) {
        NSString *token = [translation substringWithRange:match.range];
        if (![token isEqualToString:@"%%"]) [translatedSpecifications addObject:token];
    }
    if (![translatedSpecifications isEqualToArray:specifications]) return nil;

    return @{@"key": key, @"expression": expression, @"translation": translation, @"specifications": specifications};
}

static void TFPrepareTemplates(void) {
    if (TFTranslationTable.count == 0) return;
    NSRegularExpression *specification = TFSpecificationExpression();
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *index = [NSMutableDictionary dictionary];
    for (NSString *key in TFTranslationTable) {
        if ([key rangeOfString:@"%"].location == NSNotFound) continue;
        NSString *translation = TFTranslationTable[key];
        NSDictionary *template = TFTemplateForKey(key, translation, specification);
        if (!template) continue;
        NSString *first = [key substringToIndex:1];
        if ([first isEqualToString:@"%"]) first = @"*";
        NSMutableArray<NSDictionary *> *bucket = index[first];
        if (!bucket) {
            bucket = [NSMutableArray array];
            index[first] = bucket;
        }
        [bucket addObject:template];
    }
    for (NSString *character in index) {
        [index[character] sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSUInteger leftLength = [left[@"key"] length];
            NSUInteger rightLength = [right[@"key"] length];
            if (leftLength > rightLength) return NSOrderedAscending;
            if (leftLength < rightLength) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    TFTemplatesByCharacter = index;
}

static NSString *TFApplyTemplate(NSDictionary *template, NSString *text, NSTextCheckingResult *match) {
    NSString *translation = template[@"translation"];
    NSArray<NSString *> *specifications = template[@"specifications"];
    NSMutableString *result = [NSMutableString stringWithCapacity:translation.length + 16];
    NSUInteger cursor = 0;
    NSUInteger specificationIndex = 0;
    for (NSTextCheckingResult *tokenMatch in [TFSpecificationExpression() matchesInString:translation options:0 range:NSMakeRange(0, translation.length)]) {
        if (tokenMatch.range.location > cursor) {
            [result appendString:[translation substringWithRange:NSMakeRange(cursor, tokenMatch.range.location - cursor)]];
        }
        NSString *token = [translation substringWithRange:tokenMatch.range];
        if ([token isEqualToString:@"%%"]) {
            [result appendString:@"%"];
        } else {
            if (specificationIndex >= specifications.count || specificationIndex + 1 >= match.numberOfRanges) return nil;
            NSRange valueRange = [match rangeAtIndex:specificationIndex + 1];
            if (valueRange.location == NSNotFound) return nil;
            [result appendString:[text substringWithRange:valueRange]];
            specificationIndex++;
        }
        cursor = NSMaxRange(tokenMatch.range);
    }
    if (cursor < translation.length) [result appendString:[translation substringFromIndex:cursor]];
    return result;
}

static NSString *TFLocalizedByTemplate(NSString *text) {
    if (TFTemplatesByCharacter.count == 0) return nil;
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seenCharacters = [NSMutableSet set];
    for (NSUInteger index = 0; index < text.length && seenCharacters.count < 96; index++) {
        NSString *character = [text substringWithRange:NSMakeRange(index, 1)];
        if (![seenCharacters containsObject:character]) {
            [seenCharacters addObject:character];
            NSArray<NSDictionary *> *bucket = TFTemplatesByCharacter[character];
            if (bucket.count) [candidates addObjectsFromArray:bucket];
        }
    }
    NSArray<NSDictionary *> *wildcards = TFTemplatesByCharacter[@"*"];
    if (wildcards.count) [candidates addObjectsFromArray:wildcards];
    for (NSDictionary *template in candidates) {
        NSRegularExpression *expression = template[@"expression"];
        NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (!match) continue;
        NSString *translated = TFApplyTemplate(template, text, match);
        if (translated) return translated;
    }
    return nil;
}

NSString *TFLocalized(NSString *text) {
    if (!TFIsArabic || text.length == 0 || !TFHasHan(text)) return text;

    NSString *cached = [TFTranslationCache objectForKey:text];
    if (cached) return cached;

    NSString *translated = TFTranslationTable[text];
    if (!translated) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length && ![trimmed isEqualToString:text]) translated = TFTranslationTable[trimmed];
    }
    if (!translated) translated = TFLocalizedByTemplate(text);
    if (!translated && [text containsString:@"\n"]) {
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *translatedLines = [NSMutableArray arrayWithCapacity:lines.count];
        BOOL changed = NO;
        for (NSString *line in lines) {
            NSString *lineTranslation = TFTranslationTable[line];
            if (!lineTranslation) lineTranslation = TFLocalizedByTemplate(line);
            if (lineTranslation && ![lineTranslation isEqualToString:line]) changed = YES;
            [translatedLines addObject:lineTranslation ?: line];
        }
        if (changed) translated = [translatedLines componentsJoinedByString:@"\n"];
    }
    if (!translated) translated = text;

    [TFTranslationCache setObject:translated forKey:text];
    return translated;
}

BOOL TFLocalizationIsArabic(void) {
    return TFIsArabic;
}

static void TFSwizzleInstance(Class type, SEL original, SEL replacement) {
    Method first = class_getInstanceMethod(type, original);
    Method second = class_getInstanceMethod(type, replacement);
    if (first && second) method_exchangeImplementations(first, second);
}

static void TFSwizzleClass(Class type, SEL original, SEL replacement) {
    Method first = class_getClassMethod(type, original);
    Method second = class_getClassMethod(type, replacement);
    if (first && second) method_exchangeImplementations(first, second);
}

#pragma mark - UIKit hooks

@implementation UIWindow (TFArabic)
- (void)tf_setRootViewController:(UIViewController *)rootViewController {
    if (TFIsArabic) self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    [self tf_setRootViewController:rootViewController];
}
- (void)tf_makeKeyAndVisible {
    if (TFIsArabic) self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    [self tf_makeKeyAndVisible];
}
@end

static NSAttributedString *TFLocalizedAttributedString(NSAttributedString *text) {
    if (!TFIsArabic || text.length == 0 || !TFHasHan(text.string)) return text;
    // Attributed content is also used for streaming AI replies and rich code
    // blocks. Only exact catalog matches are translated here, so a model reply
    // is never mistaken for a format template.
    NSString *translated = TFTranslationTable[text.string];
    if (!translated) {
        NSString *trimmed = [text.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length && ![trimmed isEqualToString:text.string]) translated = TFTranslationTable[trimmed];
    }
    if (!translated || [translated isEqualToString:text.string]) return text;
    NSDictionary *attributes = [text attributesAtIndex:0 effectiveRange:NULL];
    return [[NSAttributedString alloc] initWithString:translated attributes:attributes];
}

@implementation UILabel (TFArabic)
- (void)tf_setText:(NSString *)text {
    [self tf_setText:TFLocalized(text)];
}
- (void)tf_setAttributedText:(NSAttributedString *)text {
    [self tf_setAttributedText:TFLocalizedAttributedString(text)];
}
@end

@implementation UIButton (TFArabic)
- (void)tf_setTitle:(NSString *)title forState:(UIControlState)state {
    [self tf_setTitle:TFLocalized(title) forState:state];
}
- (void)tf_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    [self tf_setAttributedTitle:TFLocalizedAttributedString(title) forState:state];
}
@end

@implementation UITextField (TFArabic)
- (void)tf_setPlaceholder:(NSString *)placeholder {
    [self tf_setPlaceholder:TFLocalized(placeholder)];
}
@end

@implementation UISearchBar (TFArabic)
- (void)tf_setPlaceholder:(NSString *)placeholder {
    [self tf_setPlaceholder:TFLocalized(placeholder)];
}
- (void)tf_setPrompt:(NSString *)prompt {
    [self tf_setPrompt:TFLocalized(prompt)];
}
@end

@implementation UIViewController (TFArabic)
- (void)tf_setTitle:(NSString *)title {
    [self tf_setTitle:TFLocalized(title)];
}
@end

@implementation UINavigationItem (TFArabic)
- (void)tf_setTitle:(NSString *)title {
    [self tf_setTitle:TFLocalized(title)];
}
- (void)tf_setPrompt:(NSString *)prompt {
    [self tf_setPrompt:TFLocalized(prompt)];
}
- (void)tf_setBackButtonTitle:(NSString *)title {
    [self tf_setBackButtonTitle:TFLocalized(title)];
}
@end

@implementation UIBarButtonItem (TFArabic)
- (instancetype)tf_initWithTitle:(NSString *)title style:(UIBarButtonItemStyle)style target:(id)target action:(SEL)action {
    return [self tf_initWithTitle:TFLocalized(title) style:style target:target action:action];
}
- (void)tf_setTitle:(NSString *)title {
    [self tf_setTitle:TFLocalized(title)];
}
@end

@implementation UITabBarItem (TFArabic)
- (instancetype)tf_initWithTitle:(NSString *)title image:(UIImage *)image tag:(NSInteger)tag {
    return [self tf_initWithTitle:TFLocalized(title) image:image tag:tag];
}
- (instancetype)tf_initWithTitle:(NSString *)title image:(UIImage *)image selectedImage:(UIImage *)selectedImage {
    return [self tf_initWithTitle:TFLocalized(title) image:image selectedImage:selectedImage];
}
- (void)tf_setTitle:(NSString *)title {
    [self tf_setTitle:TFLocalized(title)];
}
@end

@implementation UISegmentedControl (TFArabic)
- (instancetype)tf_initWithItems:(NSArray *)items {
    NSMutableArray *translated = [items mutableCopy];
    for (NSUInteger index = 0; index < translated.count; index++) {
        if ([translated[index] isKindOfClass:NSString.class]) translated[index] = TFLocalized(translated[index]);
    }
    return [self tf_initWithItems:translated];
}
- (void)tf_insertSegmentWithTitle:(NSString *)title atIndex:(NSUInteger)segment animated:(BOOL)animated {
    [self tf_insertSegmentWithTitle:TFLocalized(title) atIndex:segment animated:animated];
}
- (void)tf_setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment {
    [self tf_setTitle:TFLocalized(title) forSegmentAtIndex:segment];
}
@end

@implementation UIAlertAction (TFArabic)
+ (instancetype)tf_actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    return [self tf_actionWithTitle:TFLocalized(title) style:style handler:handler];
}
@end

@implementation UIAlertController (TFArabic)
+ (instancetype)tf_alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)preferredStyle {
    return [self tf_alertControllerWithTitle:TFLocalized(title) message:TFLocalized(message) preferredStyle:preferredStyle];
}
@end

@implementation UIAction (TFArabic)
+ (instancetype)tf_actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier handler:(void (^)(UIAction *))handler {
    return [self tf_actionWithTitle:TFLocalized(title) image:image identifier:identifier handler:handler];
}
+ (instancetype)tf_actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier discoverabilityTitle:(NSString *)discoverabilityTitle attributes:(UIMenuElementAttributes)attributes state:(UIMenuElementState)state handler:(void (^)(UIAction *))handler {
    return [self tf_actionWithTitle:TFLocalized(title) image:image identifier:identifier discoverabilityTitle:TFLocalized(discoverabilityTitle) attributes:attributes state:state handler:handler];
}
@end

@implementation UIMenu (TFArabic)
+ (instancetype)tf_menuWithTitle:(NSString *)title children:(NSArray<UIMenuElement *> *)children {
    return [self tf_menuWithTitle:TFLocalized(title) children:children];
}
+ (instancetype)tf_menuWithTitle:(NSString *)title image:(UIImage *)image identifier:(NSString *)identifier options:(UIMenuOptions)options children:(NSArray<UIMenuElement *> *)children {
    return [self tf_menuWithTitle:TFLocalized(title) image:image identifier:identifier options:options children:children];
}
@end

void TFLocalizationInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TFIsArabic = TFDetectArabic();
        if (!TFIsArabic) return;

        TFTranslationCache = [NSCache new];
        TFTranslationCache.countLimit = 4096;
        NSString *path = [NSBundle.mainBundle pathForResource:@"Arabic" ofType:@"plist"];
        if (path) TFTranslationTable = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
        if (TFTranslationTable.count == 0) {
            TFIsArabic = NO;
            return;
        }
        TFPrepareTemplates();

        // Arabic is right-to-left. The window attribute is applied before its
        // first layout, so leading/trailing Auto Layout anchors, table cells,
        // navigation bars, alerts and segmented controls all flip. Labels use
        // natural alignment by default in this app, so no text-alignment
        // swizzle is needed. The ar.lproj in the bundle also tells UIKit that
        // Arabic is a supported native localization.
        TFSwizzleInstance(UIWindow.class, @selector(setRootViewController:), @selector(tf_setRootViewController:));
        TFSwizzleInstance(UIWindow.class, @selector(makeKeyAndVisible), @selector(tf_makeKeyAndVisible));
        TFSwizzleInstance(UILabel.class, @selector(setText:), @selector(tf_setText:));
        TFSwizzleInstance(UILabel.class, @selector(setAttributedText:), @selector(tf_setAttributedText:));
        TFSwizzleInstance(UIButton.class, @selector(setTitle:forState:), @selector(tf_setTitle:forState:));
        TFSwizzleInstance(UIButton.class, @selector(setAttributedTitle:forState:), @selector(tf_setAttributedTitle:forState:));
        TFSwizzleInstance(UITextField.class, @selector(setPlaceholder:), @selector(tf_setPlaceholder:));
        TFSwizzleInstance(UISearchBar.class, @selector(setPlaceholder:), @selector(tf_setPlaceholder:));
        TFSwizzleInstance(UISearchBar.class, @selector(setPrompt:), @selector(tf_setPrompt:));
        TFSwizzleInstance(UIViewController.class, @selector(setTitle:), @selector(tf_setTitle:));
        TFSwizzleInstance(UINavigationItem.class, @selector(setTitle:), @selector(tf_setTitle:));
        TFSwizzleInstance(UINavigationItem.class, @selector(setPrompt:), @selector(tf_setPrompt:));
        TFSwizzleInstance(UINavigationItem.class, @selector(setBackButtonTitle:), @selector(tf_setBackButtonTitle:));
        TFSwizzleInstance(UIBarButtonItem.class, @selector(initWithTitle:style:target:action:), @selector(tf_initWithTitle:style:target:action:));
        TFSwizzleInstance(UIBarButtonItem.class, @selector(setTitle:), @selector(tf_setTitle:));
        TFSwizzleInstance(UITabBarItem.class, @selector(initWithTitle:image:tag:), @selector(tf_initWithTitle:image:tag:));
        TFSwizzleInstance(UITabBarItem.class, @selector(initWithTitle:image:selectedImage:), @selector(tf_initWithTitle:image:selectedImage:));
        TFSwizzleInstance(UITabBarItem.class, @selector(setTitle:), @selector(tf_setTitle:));
        TFSwizzleInstance(UISegmentedControl.class, @selector(initWithItems:), @selector(tf_initWithItems:));
        TFSwizzleInstance(UISegmentedControl.class, @selector(insertSegmentWithTitle:atIndex:animated:), @selector(tf_insertSegmentWithTitle:atIndex:animated:));
        TFSwizzleInstance(UISegmentedControl.class, @selector(setTitle:forSegmentAtIndex:), @selector(tf_setTitle:forSegmentAtIndex:));
        TFSwizzleClass(UIAlertAction.class, @selector(actionWithTitle:style:handler:), @selector(tf_actionWithTitle:style:handler:));
        TFSwizzleClass(UIAlertController.class, @selector(alertControllerWithTitle:message:preferredStyle:), @selector(tf_alertControllerWithTitle:message:preferredStyle:));
        TFSwizzleClass(UIAction.class, @selector(actionWithTitle:image:identifier:handler:), @selector(tf_actionWithTitle:image:identifier:handler:));
        TFSwizzleClass(UIAction.class, @selector(actionWithTitle:image:identifier:discoverabilityTitle:attributes:state:handler:), @selector(tf_actionWithTitle:image:identifier:discoverabilityTitle:attributes:state:handler:));
        TFSwizzleClass(UIMenu.class, @selector(menuWithTitle:children:), @selector(tf_menuWithTitle:children:));
        TFSwizzleClass(UIMenu.class, @selector(menuWithTitle:image:identifier:options:children:), @selector(tf_menuWithTitle:image:identifier:options:children:));
    });
}

@interface TFLocalizationBootstrap : NSObject
@end

@implementation TFLocalizationBootstrap
+ (void)load {
    TFLocalizationInstall();
}
@end
