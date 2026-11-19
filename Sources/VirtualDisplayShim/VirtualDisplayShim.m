#import "VirtualDisplayShim.h"

// Gränssnitten finns i CoreGraphics men saknas i SDK:ns headers. Klasserna hämtas via
// NSClassFromString så att appen inte länkar mot privata symboler och klarar sig om de försvinner.

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static const unsigned int kMaxWidth = 3840;
static const unsigned int kMaxHeight = 2160;

id BSSCreateVirtualDisplay(NSString *name, unsigned int width, unsigned int height, double refreshRate, void (^onTerminate)(void)) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !displayClass) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = kMaxWidth;
    descriptor.maxPixelsHigh = kMaxHeight;
    descriptor.sizeInMillimeters = CGSizeMake(600, 340);
    descriptor.vendorID = 0x4253;   // "BS"
    descriptor.productID = 0x5343;  // "SC"
    descriptor.serialNum = 1;
    if (onTerminate) {
        descriptor.terminationHandler = ^(id a, id b) { onTerminate(); };
    }

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) return nil;
    if (!BSSApplyVirtualDisplayMode(display, width, height, refreshRate)) return nil;
    return display;
}

CGDirectDisplayID BSSVirtualDisplayID(id display) {
    if (![display respondsToSelector:@selector(displayID)]) return 0;
    return ((CGVirtualDisplay *)display).displayID;
}

BOOL BSSApplyVirtualDisplayMode(id display, unsigned int width, unsigned int height, double refreshRate) {
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!settingsClass || !modeClass || ![display respondsToSelector:@selector(applySettings:)]) return NO;

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[[[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate]];
    return [(CGVirtualDisplay *)display applySettings:settings];
}
