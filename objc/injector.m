#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static NSString *const kTextEditPath = @"/System/Applications/TextEdit.app";
static int64_t const kEventTag = 0x56484944;
static NSInteger gSleepScale = 1;

@interface BrowserTarget : NSObject
@property(nonatomic, strong) NSRunningApplication *application;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, assign) pid_t pid;
@property(nonatomic, copy) NSString *windowTitle;
@property(nonatomic, assign) CGRect frame;
@end

@implementation BrowserTarget
@end

static void SleepMs(int milliseconds) {
    [NSThread sleepForTimeInterval:((double)milliseconds * (double)MAX(gSleepScale, 1)) / 1000.0];
}

static NSString *IsoTimestamp(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL EnsureAccessibilityTrusted(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static id AXCopyAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || !value) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static BOOL AXCopyCGPoint(AXUIElementRef element, CFStringRef attribute, CGPoint *point) {
    id value = AXCopyAttribute(element, attribute);
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != AXValueGetTypeID()) {
        return NO;
    }
    return AXValueGetValue((__bridge AXValueRef)value, kAXValueCGPointType, point);
}

static BOOL AXCopyCGSize(AXUIElementRef element, CFStringRef attribute, CGSize *size) {
    id value = AXCopyAttribute(element, attribute);
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != AXValueGetTypeID()) {
        return NO;
    }
    return AXValueGetValue((__bridge AXValueRef)value, kAXValueCGSizeType, size);
}

static CGRect AXCopyFrame(AXUIElementRef window) {
    CGPoint point = CGPointZero;
    CGSize size = CGSizeZero;
    if (!AXCopyCGPoint(window, kAXPositionAttribute, &point) || !AXCopyCGSize(window, kAXSizeAttribute, &size)) {
        return CGRectNull;
    }
    return CGRectMake(point.x, point.y, size.width, size.height);
}

static BrowserTarget *ResolveTarget(NSArray<NSString *> *bundleIdentifiers) {
    for (NSString *bundleIdentifier in bundleIdentifiers) {
        NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
        for (NSRunningApplication *app in apps) {
            if (app.terminated) {
                continue;
            }
            AXUIElementRef appElement = AXUIElementCreateApplication(app.processIdentifier);
            id focusedWindow = AXCopyAttribute(appElement, kAXFocusedWindowAttribute);
            NSArray *windows = nil;
            if (!focusedWindow) {
                windows = AXCopyAttribute(appElement, kAXWindowsAttribute);
            }

            NSArray *candidates = focusedWindow ? @[focusedWindow] : (windows ?: @[]);
            for (id windowObj in candidates) {
                AXUIElementRef window = (__bridge AXUIElementRef)windowObj;
                CGRect frame = AXCopyFrame(window);
                if (CGRectIsNull(frame) || frame.size.width < 240 || frame.size.height < 240) {
                    continue;
                }

                BrowserTarget *target = [BrowserTarget new];
                target.application = app;
                target.bundleIdentifier = bundleIdentifier;
                target.pid = app.processIdentifier;
                target.frame = frame;
                NSString *title = AXCopyAttribute(window, kAXTitleAttribute);
                target.windowTitle = [title isKindOfClass:[NSString class]] ? title : @"";
                CFRelease(appElement);
                return target;
            }
            CFRelease(appElement);
        }
    }
    return nil;
}

static CGPoint PointInFrame(CGRect frame, CGFloat xFactor, CGFloat yFactor) {
    return CGPointMake(CGRectGetMinX(frame) + CGRectGetWidth(frame) * xFactor,
                       CGRectGetMinY(frame) + CGRectGetHeight(frame) * yFactor);
}

static NSArray<NSValue *> *InterpolatedPath(CGPoint start, CGPoint end, NSUInteger steps) {
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    if (steps < 2) {
        [points addObject:[NSValue valueWithPoint:NSPointFromCGPoint(start)]];
        [points addObject:[NSValue valueWithPoint:NSPointFromCGPoint(end)]];
        return points;
    }
    for (NSUInteger index = 0; index < steps; index += 1) {
        CGFloat progress = (CGFloat)index / (CGFloat)(steps - 1);
        CGFloat eased = progress * progress * (3.0 - 2.0 * progress);
        CGPoint point = CGPointMake(start.x + (end.x - start.x) * eased,
                                    start.y + (end.y - start.y) * eased);
        [points addObject:[NSValue valueWithPoint:NSPointFromCGPoint(point)]];
    }
    return points;
}

static NSDictionary *EventRecord(NSString *type, CGPoint *location, NSString *key, NSNumber *virtualKey, NSNumber *deltaY) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"type"] = type;
    record[@"timestamp"] = IsoTimestamp();
    if (location) {
        record[@"location"] = @{ @"x" : @(location->x), @"y" : @(location->y) };
    }
    if (key) {
        record[@"key"] = key;
    }
    if (virtualKey) {
        record[@"virtualKey"] = virtualKey;
    }
    if (deltaY) {
        record[@"deltaY"] = deltaY;
    }
    return record;
}

static void PostMouseEvent(pid_t pid, CGEventType type, CGPoint location, CGMouseButton button) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, location, button);
    if (!event) {
        return;
    }
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kEventTag);
    CGEventPostToPid(pid, event);
    CFRelease(event);
}

static void PostKeyboardEvent(pid_t pid, CGKeyCode keyCode, BOOL keyDown, UniChar character) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, keyCode, keyDown);
    if (!event) {
        return;
    }
    if (character != 0) {
        CGEventKeyboardSetUnicodeString(event, 1, &character);
    }
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kEventTag);
    CGEventPostToPid(pid, event);
    CFRelease(event);
}

static void PostScrollEvent(pid_t pid, int32_t deltaY) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, deltaY);
    if (!event) {
        return;
    }
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kEventTag);
    CGEventPostToPid(pid, event);
    CFRelease(event);
}

static NSDictionary<NSString *, NSNumber *> *KeyMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"a": @0, @"b": @11, @"c": @8, @"d": @2, @"e": @14, @"f": @3, @"g": @5, @"h": @4,
            @"i": @34, @"j": @38, @"k": @40, @"l": @37, @"m": @46, @"n": @45, @"o": @31, @"p": @35,
            @"q": @12, @"r": @15, @"s": @1, @"t": @17, @"u": @32, @"v": @9, @"w": @13, @"x": @7,
            @"y": @16, @"z": @6,
            @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"5": @23, @"6": @22, @"7": @26, @"8": @28, @"9": @25, @"0": @29,
            @" ": @49
        };
    });
    return map;
}

static NSNumber *KeyCodeForCharacter(unichar character) {
    NSString *key = [[[NSString stringWithCharacters:&character length:1] lowercaseString] copy];
    return KeyMap()[key];
}

static NSRunningApplication *ActivateTextEdit(void) {
    [[NSWorkspace sharedWorkspace] launchApplication:kTextEditPath];
    SleepMs(500);
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"];
    NSRunningApplication *textEdit = apps.firstObject;
    [textEdit activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    SleepMs(400);
    return textEdit;
}

static void PrepareFocus(BrowserTarget *target, BOOL active) {
    if (active) {
        [target.application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        SleepMs(350);
        return;
    }
    ActivateTextEdit();
}

static NSDictionary *ScenarioEnvelope(NSString *scenario, BrowserTarget *target, NSString *startTime, NSArray *events) {
    return @{
        @"scenario": scenario,
        @"targetPid": @(target.pid),
        @"targetBundleId": target.bundleIdentifier,
        @"targetWindowTitle": target.windowTitle ?: @"",
        @"targetFrame": @{ @"x": @(target.frame.origin.x), @"y": @(target.frame.origin.y), @"width": @(target.frame.size.width), @"height": @(target.frame.size.height) },
        @"startTime": startTime,
        @"endTime": IsoTimestamp(),
        @"events": events,
    };
}

static NSDictionary *RunMouseMoveClick(BrowserTarget *target, BOOL active) {
    PrepareFocus(target, active);
    NSString *scenario = active ? @"mouse_move_click_active" : @"mouse_move_click_blur";
    NSString *startTime = IsoTimestamp();
    NSMutableArray *events = [NSMutableArray array];
    CGPoint start = PointInFrame(target.frame, 0.25, 0.34);
    CGPoint end = PointInFrame(target.frame, 0.74, 0.60);
    NSArray<NSValue *> *path = InterpolatedPath(start, end, 20);
    for (NSValue *value in path) {
        CGPoint point = [value pointValue];
        PostMouseEvent(target.pid, kCGEventMouseMoved, point, kCGMouseButtonLeft);
        [events addObject:EventRecord(@"mouseMoved", &point, nil, nil, nil)];
        SleepMs(28);
    }
    CGPoint clickPoint = [[path lastObject] pointValue];
    PostMouseEvent(target.pid, kCGEventLeftMouseDown, clickPoint, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"leftMouseDown", &clickPoint, nil, nil, nil)];
    SleepMs(50);
    PostMouseEvent(target.pid, kCGEventLeftMouseUp, clickPoint, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"leftMouseUp", &clickPoint, nil, nil, nil)];
    SleepMs(160);

    return ScenarioEnvelope(scenario, target, startTime, events);
}

static NSDictionary *RunMouseDrag(BrowserTarget *target, BOOL active) {
    PrepareFocus(target, active);
    NSString *startTime = IsoTimestamp();
    NSMutableArray *events = [NSMutableArray array];
    CGPoint start = PointInFrame(target.frame, 0.80, 0.78);
    CGPoint end = PointInFrame(target.frame, 0.46, 0.52);
    NSArray<NSValue *> *path = InterpolatedPath(start, end, 18);

    PostMouseEvent(target.pid, kCGEventMouseMoved, start, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"mouseMoved", &start, nil, nil, nil)];
    SleepMs(36);
    PostMouseEvent(target.pid, kCGEventLeftMouseDown, start, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"leftMouseDown", &start, nil, nil, nil)];
    SleepMs(42);

    for (NSValue *value in path) {
        CGPoint point = [value pointValue];
        PostMouseEvent(target.pid, kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
        [events addObject:EventRecord(@"leftMouseDragged", &point, nil, nil, nil)];
        SleepMs(28);
    }
    CGPoint finish = [[path lastObject] pointValue];
    PostMouseEvent(target.pid, kCGEventLeftMouseUp, finish, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"leftMouseUp", &finish, nil, nil, nil)];
    SleepMs(150);

    return ScenarioEnvelope(active ? @"mouse_drag_active" : @"mouse_drag_blur", target, startTime, events);
}

static NSDictionary *RunScroll(BrowserTarget *target, BOOL active) {
    PrepareFocus(target, active);
    NSString *scenario = active ? @"scroll_active" : @"scroll_blur";
    NSString *startTime = IsoTimestamp();
    NSMutableArray *events = [NSMutableArray array];
    CGPoint hoverPoint = PointInFrame(target.frame, 0.19, 0.78);
    PostMouseEvent(target.pid, kCGEventMouseMoved, hoverPoint, kCGMouseButtonLeft);
    [events addObject:EventRecord(@"mouseMoved", &hoverPoint, nil, nil, nil)];
    SleepMs(120);

    NSArray<NSNumber *> *deltas = @[ @(-3), @(-3), @(-4), @(-4), @(4), @(4), @(3), @(3) ];
    for (NSNumber *delta in deltas) {
        PostScrollEvent(target.pid, delta.intValue);
        [events addObject:EventRecord(@"scrollWheel", &hoverPoint, nil, nil, delta)];
        SleepMs(90);
    }
    SleepMs(180);

    return ScenarioEnvelope(scenario, target, startTime, events);
}

static NSDictionary *RunKeyboardType(BrowserTarget *target, BOOL active, NSString *input) {
    PrepareFocus(target, active);
    NSString *scenario = active ? @"keyboard_type_active" : @"keyboard_type_blur";
    NSString *startTime = IsoTimestamp();
    NSMutableArray *events = [NSMutableArray array];
    for (NSUInteger index = 0; index < input.length; index += 1) {
        unichar character = [input characterAtIndex:index];
        NSNumber *keyCode = KeyCodeForCharacter(character);
        if (!keyCode) {
            continue;
        }
        CGKeyCode code = (CGKeyCode)keyCode.unsignedShortValue;
        PostKeyboardEvent(target.pid, code, YES, character);
        [events addObject:EventRecord(@"keyDown", NULL, [NSString stringWithCharacters:&character length:1], keyCode, nil)];
        SleepMs(34);
        PostKeyboardEvent(target.pid, code, NO, character);
        [events addObject:EventRecord(@"keyUp", NULL, [NSString stringWithCharacters:&character length:1], keyCode, nil)];
        SleepMs(44);
    }
    SleepMs(120);

    return ScenarioEnvelope(scenario, target, startTime, events);
}

static NSData *PrettyJSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try {
            NSMutableArray<NSString *> *bundleIdentifiers = [NSMutableArray arrayWithArray:@[@"com.apple.Safari", @"com.google.Chrome"]];
            NSMutableArray<NSString *> *scenarios = [NSMutableArray arrayWithArray:@[@"mouse_move_click_active", @"mouse_drag_active", @"scroll_active", @"keyboard_type_active", @"mouse_move_click_blur", @"mouse_drag_blur", @"scroll_blur", @"keyboard_type_blur"]];
            NSString *resultsDir = @"results";
            NSString *keyInput = @"abc123";
            gSleepScale = 1;

            for (int index = 1; index < argc; index += 1) {
                NSString *argument = [NSString stringWithUTF8String:argv[index]];
                if ([argument isEqualToString:@"--bundle"] && index + 1 < argc) {
                    [bundleIdentifiers removeAllObjects];
                    [bundleIdentifiers addObjectsFromArray:[[NSString stringWithUTF8String:argv[++index]] componentsSeparatedByString:@","]];
                } else if ([argument isEqualToString:@"--scenarios"] && index + 1 < argc) {
                    [scenarios removeAllObjects];
                    [scenarios addObjectsFromArray:[[NSString stringWithUTF8String:argv[++index]] componentsSeparatedByString:@","]];
                } else if ([argument isEqualToString:@"--results-dir"] && index + 1 < argc) {
                    resultsDir = [NSString stringWithUTF8String:argv[++index]];
                } else if ([argument isEqualToString:@"--key-input"] && index + 1 < argc) {
                    keyInput = [NSString stringWithUTF8String:argv[++index]];
                } else if ([argument isEqualToString:@"--sleep-scale"] && index + 1 < argc) {
                    gSleepScale = MAX(1, [[NSString stringWithUTF8String:argv[++index]] integerValue]);
                }
            }

            if (!EnsureAccessibilityTrusted()) {
                fprintf(stderr, "ERROR: 缺少 Accessibility 权限。\n");
                return 1;
            }

            [[NSFileManager defaultManager] createDirectoryAtPath:resultsDir withIntermediateDirectories:YES attributes:nil error:nil];
            BrowserTarget *target = ResolveTarget(bundleIdentifiers);
            if (!target) {
                fprintf(stderr, "ERROR: 未找到目标浏览器。\n");
                return 1;
            }

            NSDictionary *resolver = @{
                @"pid": @(target.pid),
                @"bundle": target.bundleIdentifier,
                @"title": target.windowTitle ?: @"",
                @"frame": @{ @"x": @(target.frame.origin.x), @"y": @(target.frame.origin.y), @"width": @(target.frame.size.width), @"height": @(target.frame.size.height) }
            };
            NSData *resolverData = PrettyJSONData(resolver);
            fwrite(resolverData.bytes, resolverData.length, 1, stdout);
            fwrite("\n", 1, 1, stdout);

            for (NSString *scenario in scenarios) {
                NSDictionary *result = nil;
                if ([scenario isEqualToString:@"mouse_move_click_active"]) {
                    result = RunMouseMoveClick(target, YES);
                } else if ([scenario isEqualToString:@"mouse_drag_active"]) {
                    result = RunMouseDrag(target, YES);
                } else if ([scenario isEqualToString:@"scroll_active"]) {
                    result = RunScroll(target, YES);
                } else if ([scenario isEqualToString:@"keyboard_type_active"]) {
                    result = RunKeyboardType(target, YES, keyInput);
                } else if ([scenario isEqualToString:@"mouse_move_click_blur"]) {
                    result = RunMouseMoveClick(target, NO);
                } else if ([scenario isEqualToString:@"mouse_drag_blur"]) {
                    result = RunMouseDrag(target, NO);
                } else if ([scenario isEqualToString:@"scroll_blur"]) {
                    result = RunScroll(target, NO);
                } else if ([scenario isEqualToString:@"keyboard_type_blur"]) {
                    result = RunKeyboardType(target, NO, keyInput);
                }
                if (!result) {
                    continue;
                }
                NSString *filePath = [resultsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", result[@"scenario"]]];
                [PrettyJSONData(result) writeToFile:filePath atomically:YES];
                NSData *stdoutData = PrettyJSONData(result);
                fwrite(stdoutData.bytes, stdoutData.length, 1, stdout);
                fwrite("\n", 1, 1, stdout);
            }
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "ERROR: %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
}
