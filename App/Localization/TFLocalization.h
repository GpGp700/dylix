#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the app should present its Arabic translation layer.
BOOL TFLocalizationIsArabic(void);

/// Returns the Arabic translation for a Chinese UI string, or the original
/// string when no translation applies. Only strings containing Han characters
/// are considered, so user content, paths and code are left untouched.
NSString *TFLocalized(NSString * _Nullable text);

/// Installs the UIKit swizzles. Called automatically from +load, and safe to
/// call more than once.
void TFLocalizationInstall(void);

NS_ASSUME_NONNULL_END
