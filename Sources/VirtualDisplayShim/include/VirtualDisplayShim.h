#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Skapar en virtuell skärm via macOS inbyggda (odokumenterade) CGVirtualDisplay.
/// Returnerar nil om funktionen saknas i den här macOS-versionen.
/// Skärmen finns kvar så länge det returnerade objektet lever.
id _Nullable BSSCreateVirtualDisplay(NSString *name,
                                     unsigned int width,
                                     unsigned int height,
                                     double refreshRate,
                                     void (^_Nullable onTerminate)(void));

/// Skärmens CGDirectDisplayID, eller 0.
CGDirectDisplayID BSSVirtualDisplayID(id display);

/// Byter upplösning (i pixlar) utan att skärmen tas bort.
BOOL BSSApplyVirtualDisplayMode(id display, unsigned int width, unsigned int height, double refreshRate);

NS_ASSUME_NONNULL_END
