//
//  Tweak.mm — Cytus2-120FPS
//
//  用途：在 LiveContainer（ElleKit / rootless 越狱）里把 Cytus II 的刷新率强制到 120Hz。
//        也可直接装在越狱设备上的原版 Cytus II 上使用。
//
//  原理（详见 docs/01-refresh-rate-analysis.md）：
//    Cytus II 的 Rayark.Cytus2.FrameRateAdjuster 把默认帧率硬编码为 60，
//    设置里的 FPS Limit 默认档位就是 60fps；游戏通过
//        Application.targetFrameRate = v
//    →   il2cpp icall → Unity C++ 引擎（gTargetFrameRate = v）
//    →   -[UnityAppController callbackFramerateChange:v]
//    →   -[CADisplayLink setPreferredFrameRateRange:] / setPreferredFramesPerSecond:
//    来限制帧率。iOS 上渲染节拍完全由 CADisplayLink 决定，
//    所以只要在这里把 rate 改成 120 就能解除限制。
//
//  这个 tweak 做四件事：
//    1. hook -[UnityAppController callbackFramerateChange:] → 强制 min(120, 屏幕上限)
//    2. 保险：只对 Unity 自己的那个 CADisplayLink 强制 rate（防止未来 Unity 换实现）
//    3. 可选：用 il2cpp API 把引擎内部值也同步成 120（无硬编码地址）
//    4. 诊断：每秒统计真实渲染 FPS + 关键环境信息，写到游戏容器 Documents/120fps.log
//
//  不依赖 libsubstrate：直接用 ObjC runtime 换 IMP，LiveContainer 的 TweakLoader
//  和 ElleKit 两种注入方式都能跑。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <stdarg.h>
#import <stdio.h>
#import <limits.h>

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

// 目标帧率
#define NPL_TARGET_FPS              120

// 1 = 不管 [UIScreen mainScreen].maximumFramesPerSecond 报多少，display link 都请求 120。
//     60Hz 设备上系统会把 display link 夹回 60，不会出问题；
//     而在「设备支持 120 但系统闸门(Info.plist)没开」的情况下，这是唯一可能生效的路径。
// 0 = 严格按屏幕上限夹住（保守做法）
#define NPL_IGNORE_SCREEN_MAX       1

// 是否用 il2cpp API 把 UnityEngine.Application.targetFrameRate 也同步成目标值
// （让引擎内部状态一致；不影响渲染节拍，渲染节拍由 display link 决定）
#define NPL_SYNC_ENGINE_FPS         1

// 是否把 CADisableMinimumFrameDurationOnPhone=true 写进 guest app 的 Info.plist 文件。
// 注意：会破坏 app 签名，只在 TrollStore / 可以重新签名的环境下打开。
#define NPL_MODIFY_ON_DISK_PLIST    0

// 只对指定 bundle id 生效；空字符串 = 所有 Unity 游戏都生效
#define NPL_ONLY_BUNDLEID           @""

// 是否每秒写一行 FPS 统计日志（最多记录 10 分钟）
#define NPL_FPS_LOG                 1

// CAFrameRateRange 是 iOS 15 才有的类型；用私有定义避免依赖 SDK 版本
typedef struct {
    float minimum;
    float maximum;
    float preferred;
} NPLFrameRateRange;

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

static void NPLLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[Cytus2-120FPS] %@", msg);

    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("cytus2-120fps.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        // 在 LiveContainer 里 HOME 被重定向到 guest app 的容器，
        // 所以日志会落在游戏自己的 Documents 里，方便用文件管理器查看。
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            dir = NSTemporaryDirectory();
        }
        NSString *path = [dir stringByAppendingPathComponent:@"120fps.log"];
        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (!f) return;

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
        fputs(line.UTF8String, f);
        fclose(f);
    });
}

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

static NSString *NPLMainBundleID(void) {
    @try {
        return [NSBundle mainBundle].bundleIdentifier ?: @"(nil)";
    } @catch (__unused NSException *e) {
        return @"(exception)";
    }
}

static NSInteger NPLScreenMaxFPS(void) {
    NSInteger maxFPS = 60;
    @try {
        maxFPS = [UIScreen mainScreen].maximumFramesPerSecond;
    } @catch (__unused NSException *e) {
    }
    if (maxFPS <= 0) maxFPS = 60;
    return maxFPS;
}

/// 想要的目标帧率
static int NPLDesiredFPS(void) {
    NSInteger maxFPS = NPLScreenMaxFPS();
    int want = NPL_TARGET_FPS;
#if !NPL_IGNORE_SCREEN_MAX
    if (want > (int)maxFPS) want = (int)maxFPS;
#endif
    if (want < 1) want = (int)maxFPS;
    return want;
}

static IMP NPLSwizzle(Class cls, SEL sel, IMP newIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;

    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    Class super = class_getSuperclass(cls);

    // 如果方法是从父类继承的，就在子类上加一个覆盖，别动父类
    if (super && class_getInstanceMethod(super, sel) == m) {
        if (!class_addMethod(cls, sel, newIMP, types)) return NULL;
        return orig;
    }
    method_setImplementation(m, newIMP);
    return orig;
}

// ---------------------------------------------------------------------------
// il2cpp API（UnityFramework 导出了完整 il2cpp_* 符号，动态查即可，无硬编码地址）
// ---------------------------------------------------------------------------

#if NPL_SYNC_ENGINE_FPS

typedef struct Il2CppDomain   Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage    Il2CppImage;
typedef struct Il2CppClass    Il2CppClass;
typedef struct Il2CppObject   Il2CppObject;
typedef struct Il2CppThread   Il2CppThread;
typedef struct Il2CppException Il2CppException;
typedef struct MethodInfo     MethodInfo;

typedef Il2CppDomain *(*npl_domain_get_t)(void);
typedef const Il2CppAssembly **(*npl_domain_get_assemblies_t)(const Il2CppDomain *, size_t *);
typedef Il2CppAssembly *(*npl_domain_assembly_open_t)(const Il2CppDomain *, const char *);
typedef Il2CppImage *(*npl_assembly_get_image_t)(const Il2CppAssembly *);
typedef const char *(*npl_image_get_name_t)(const Il2CppImage *);
typedef Il2CppClass *(*npl_class_from_name_t)(const Il2CppImage *, const char *, const char *);
typedef const MethodInfo *(*npl_class_get_method_from_name_t)(Il2CppClass *, const char *, int);
typedef Il2CppObject *(*npl_runtime_invoke_t)(const MethodInfo *, void *, void **, Il2CppException **);
typedef Il2CppThread *(*npl_thread_current_t)(void);

static npl_domain_get_t                 p_domain_get;
static npl_domain_get_assemblies_t      p_domain_get_assemblies;
static npl_domain_assembly_open_t       p_domain_assembly_open;
static npl_assembly_get_image_t         p_assembly_get_image;
static npl_image_get_name_t             p_image_get_name;
static npl_class_from_name_t            p_class_from_name;
static npl_class_get_method_from_name_t p_class_get_method_from_name;
static npl_runtime_invoke_t             p_runtime_invoke;
static npl_thread_current_t             p_thread_current;

static const MethodInfo *gAppSetTargetFPS = NULL;
static BOOL gAppSetTargetFPSResolveFailed = NO;

static void *NPLUnitySymbol(const char *name) {
    // UnityFramework 被 guest app 载入后其符号一般是全局的；不行就按镜像路径 dlopen(RTLD_NOLOAD)
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) return sym;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, "UnityFramework")) continue;
        void *h = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
        if (!h) continue;
        sym = dlsym(h, name);
        if (sym) return sym;
    }
    return NULL;
}

static BOOL NPLLoadIl2cppAPI(void) {
    if (p_runtime_invoke) return YES;

    p_domain_get                 = (npl_domain_get_t)NPLUnitySymbol("il2cpp_domain_get");
    p_domain_get_assemblies      = (npl_domain_get_assemblies_t)NPLUnitySymbol("il2cpp_domain_get_assemblies");
    p_domain_assembly_open       = (npl_domain_assembly_open_t)NPLUnitySymbol("il2cpp_domain_assembly_open");
    p_assembly_get_image         = (npl_assembly_get_image_t)NPLUnitySymbol("il2cpp_assembly_get_image");
    p_image_get_name             = (npl_image_get_name_t)NPLUnitySymbol("il2cpp_image_get_name");
    p_class_from_name            = (npl_class_from_name_t)NPLUnitySymbol("il2cpp_class_from_name");
    p_class_get_method_from_name = (npl_class_get_method_from_name_t)NPLUnitySymbol("il2cpp_class_get_method_from_name");
    p_runtime_invoke             = (npl_runtime_invoke_t)NPLUnitySymbol("il2cpp_runtime_invoke");
    p_thread_current             = (npl_thread_current_t)NPLUnitySymbol("il2cpp_thread_current");

    return (p_domain_get && p_class_from_name && p_class_get_method_from_name &&
            p_runtime_invoke && p_thread_current);
}

static const MethodInfo *NPLResolveApplicationSetTargetFPS(void) {
    if (gAppSetTargetFPS || gAppSetTargetFPSResolveFailed) return gAppSetTargetFPS;

    if (!NPLLoadIl2cppAPI()) return NULL;

    Il2CppDomain *domain = p_domain_get();
    if (!domain) return NULL;   // il2cpp 还没初始化

    Il2CppImage *coreImage = NULL;

    // 1) 首选按名字找 UnityEngine.CoreModule.dll
    if (p_domain_get_assemblies && p_assembly_get_image) {
        size_t count = 0;
        const Il2CppAssembly **assemblies = p_domain_get_assemblies(domain, &count);
        for (size_t i = 0; assemblies && i < count; i++) {
            Il2CppImage *img = p_assembly_get_image(assemblies[i]);
            const char *name = (img && p_image_get_name) ? p_image_get_name(img) : NULL;
            if (name && strstr(name, "UnityEngine.CoreModule")) {
                coreImage = img;
                break;
            }
        }
    }
    // 2) 退路：il2cpp_domain_assembly_open
    if (!coreImage && p_domain_assembly_open && p_assembly_get_image) {
        Il2CppAssembly *assembly = p_domain_assembly_open(domain, "UnityEngine.CoreModule");
        if (assembly) coreImage = p_assembly_get_image(assembly);
    }
    if (!coreImage) return NULL;    // 下次再试

    Il2CppClass *klass = p_class_from_name(coreImage, "UnityEngine", "Application");
    if (!klass) {
        gAppSetTargetFPSResolveFailed = YES;
        NPLLog(@"il2cpp: 找不到 UnityEngine.Application 类");
        return NULL;
    }

    const MethodInfo *mi = p_class_get_method_from_name(klass, "set_targetFrameRate", 1);
    if (!mi) {
        gAppSetTargetFPSResolveFailed = YES;
        NPLLog(@"il2cpp: 找不到 Application.set_targetFrameRate");
        return NULL;
    }

    gAppSetTargetFPS = mi;
    NPLLog(@"il2cpp: 已解析 Application.set_targetFrameRate = %p", mi);
    return mi;
}

/// 把引擎内部 Application.targetFrameRate 同步成 fps
/// （只在主线程、已 attach 到 il2cpp 的线程上调用；不 attach/detach，避免破坏 Unity 的主线程）
static void NPLSyncEngineTargetFPS(int fps) {
    if (![NSThread isMainThread]) return;
    if (!NPLLoadIl2cppAPI()) return;
    if (!p_domain_get || !p_domain_get()) return;          // il2cpp 未初始化
    if (!p_thread_current || !p_thread_current()) return;  // 当前线程没 attach，别乱动

    const MethodInfo *mi = NPLResolveApplicationSetTargetFPS();
    if (!mi) return;

    int value = fps;
    void *params[1] = { &value };
    Il2CppException *exc = NULL;
    p_runtime_invoke(mi, NULL, params, &exc);
    if (exc) {
        static int warnCount = 0;
        if (warnCount++ < 3) NPLLog(@"il2cpp: set_targetFrameRate(%d) 抛出异常", fps);
    } else {
        static int lastSynced = -1;
        if (lastSynced != fps) {
            lastSynced = fps;
            NPLLog(@"il2cpp: Application.targetFrameRate 已同步为 %d", fps);
        }
    }
}

#endif // NPL_SYNC_ENGINE_FPS

// ---------------------------------------------------------------------------
// Hook 1: -[UnityAppController callbackFramerateChange:]
// ---------------------------------------------------------------------------

typedef void (*npl_callback_framerate_change_t)(id, SEL, int);
static npl_callback_framerate_change_t npl_origCallbackFramerateChange = NULL;

static BOOL gInCallbackHook = NO;
static __weak CADisplayLink *gUnityDisplayLink = nil;

static void npl_callbackFramerateChange(id self, SEL _cmd, int fps) {
    if (!npl_origCallbackFramerateChange) return;

    // 递归保护：Unity 在「请求值 > 屏幕上限」时会夹回并重新通知（notify → 本方法），
    // 嵌套调用时原样放行，避免死循环。
    if (gInCallbackHook) {
        npl_origCallbackFramerateChange(self, _cmd, fps);
        return;
    }

    int want = NPLDesiredFPS();
    gInCallbackHook = YES;

    // 记下 Unity 的 display link，供 CADisplayLink hook 用
    if ([self respondsToSelector:NSSelectorFromString(@"unityDisplayLink")]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id link = [self performSelector:NSSelectorFromString(@"unityDisplayLink")];
#pragma clang diagnostic pop
            if ([link isKindOfClass:objc_getClass("CADisplayLink")]) gUnityDisplayLink = link;
        } @catch (__unused NSException *e) {
        }
    }

#if NPL_SYNC_ENGINE_FPS
    NPLSyncEngineTargetFPS(want);
#endif

    npl_origCallbackFramerateChange(self, _cmd, want);
    gInCallbackHook = NO;

    // 只在值发生变化时打日志，避免刷屏
    static int lastFrom = INT_MIN, lastTo = INT_MIN;
    if (fps != lastFrom || want != lastTo) {
        lastFrom = fps;
        lastTo = want;
        NPLLog(@"callbackFramerateChange: 游戏请求 %d → 强制 %d（屏幕上限 %ld, displayLink=%p）",
               fps, want, (long)NPLScreenMaxFPS(), gUnityDisplayLink);
    }
}

// ---------------------------------------------------------------------------
// Hook 2（保险）: CADisplayLink 的 rate setter —— 只作用于 Unity 那一个 link
// ---------------------------------------------------------------------------

typedef void (*npl_set_preferred_fps_t)(id, SEL, NSInteger);
typedef void (*npl_set_preferred_range_t)(id, SEL, NPLFrameRateRange);
static npl_set_preferred_fps_t   npl_origSetPreferredFPS = NULL;
static npl_set_preferred_range_t npl_origSetPreferredRange = NULL;

static void npl_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (!npl_origSetPreferredFPS) return;
    CADisplayLink *unityLink = gUnityDisplayLink;
    if (unityLink && self == unityLink) {
        NSInteger want = NPLDesiredFPS();
        if (fps != want) {
            NPLLog(@"CADisplayLink.setPreferredFramesPerSecond: %ld → %ld", (long)fps, (long)want);
            fps = want;
        }
    }
    npl_origSetPreferredFPS(self, _cmd, fps);
}

static void npl_setPreferredFrameRateRange(id self, SEL _cmd, NPLFrameRateRange range) {
    if (!npl_origSetPreferredRange) return;
    CADisplayLink *unityLink = gUnityDisplayLink;
    if (unityLink && self == unityLink) {
        float want = (float)NPLDesiredFPS();
        if (range.preferred != want || range.maximum != want) {
            NPLLog(@"CADisplayLink.setPreferredFrameRateRange: %.0f → %.0f", (double)range.preferred, (double)want);
            range.minimum = want;
            range.maximum = want;
            range.preferred = want;
        }
    }
    npl_origSetPreferredRange(self, _cmd, range);
}

// ---------------------------------------------------------------------------
// Hook 3（诊断）: 统计真实渲染 FPS
// ---------------------------------------------------------------------------

typedef void (*npl_repaint_display_link_t)(id, SEL);
static npl_repaint_display_link_t npl_origRepaintDisplayLink = NULL;

static int gFrameCounter = 0;

static void npl_repaintDisplayLink(id self, SEL _cmd) {
    __sync_fetch_and_add(&gFrameCounter, 1);
    if (npl_origRepaintDisplayLink) npl_origRepaintDisplayLink(self, _cmd);
}

static void NPLStartFPSMeter(void) {
#if NPL_FPS_LOG
    static dispatch_source_t timer = NULL;
    if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        int frames = __sync_lock_test_and_set(&gFrameCounter, 0);
        if (frames <= 0) return;
        static int logged = 0;
        if (logged >= 600) return;   // 最多记录 10 分钟，避免日志无限增长
        logged++;
        CADisplayLink *link = gUnityDisplayLink;
        NSString *extra = link ? [NSString stringWithFormat:@" link(fps=%ld, paused=%d)",
                                  (long)link.preferredFramesPerSecond, link.paused]
                               : @"";
        NPLLog(@"FPS ≈ %d%@", frames, extra);
    });
    dispatch_resume(timer);
#endif
}

// ---------------------------------------------------------------------------
// Info.plist 相关
// ---------------------------------------------------------------------------

/// 把 CADisableMinimumFrameDurationOnPhone 塞进内存里的主 bundle info dictionary。
/// （LiveContainer 会把 CFBundleGetMainBundle() 重定向到 guest app 的 bundle，
///   而 guest 的 plist 里这个键是 false，可能就是 iPhone 上锁 60 的原因。）
static void NPLPatchMainBundleInfoDict(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return;

    CFStringRef key = CFSTR("CADisableMinimumFrameDurationOnPhone");
    if (CFBundleGetValueForInfoDictionaryKey(bundle, key) == kCFBooleanTrue) {
        NPLLog(@"Info.plist: CADisableMinimumFrameDurationOnPhone 已是 true");
        return;
    }

    CFMutableDictionaryRef info = (CFMutableDictionaryRef)CFBundleGetInfoDictionary(bundle);
    if (!info) return;

    // 只有可变字典才能原地修改
    if ([(__bridge NSDictionary *)info respondsToSelector:@selector(setObject:forKey:)]) {
        @try {
            [(__bridge NSMutableDictionary *)info setObject:@YES forKey:@"CADisableMinimumFrameDurationOnPhone"];
            NPLLog(@"Info.plist: 已在内存中把 CADisableMinimumFrameDurationOnPhone 设为 true");
        } @catch (NSException *e) {
            NPLLog(@"Info.plist: 内存补丁失败: %@", e.reason);
        }
    } else {
        NPLLog(@"Info.plist: info dictionary 不可变，内存补丁跳过");
    }

#if NPL_MODIFY_ON_DISK_PLIST
    // 会破坏签名，只在 TrollStore / 能重新签名的环境下开启
    NSString *plistPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (dict) {
        dict[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
        if ([dict writeToFile:plistPath atomically:YES]) {
            NPLLog(@"Info.plist: 已写入磁盘 %@（下次启动生效）", plistPath);
        } else {
            NPLLog(@"Info.plist: 写磁盘失败 %@", plistPath);
        }
    }
#endif
}

// ---------------------------------------------------------------------------
// 安装 hook（UnityFramework 可能是启动后才 dlopen 进来的，所以要等）
// ---------------------------------------------------------------------------

static BOOL gHookedCallback = NO;
static BOOL gHookedRepaint  = NO;
static BOOL gHookedCADisplayLink = NO;
static BOOL gAnnounced = NO;

static void NPLInstallHooks(void) {
    if (gHookedCallback && gHookedRepaint && gHookedCADisplayLink) return;

    Class appController = objc_getClass("UnityAppController");
    if (!appController) return;      // UnityFramework 还没加载 / 类还没注册

    if (!gHookedCallback) {
        SEL sel = NSSelectorFromString(@"callbackFramerateChange:");
        if (class_getInstanceMethod(appController, sel)) {
            npl_origCallbackFramerateChange =
                (npl_callback_framerate_change_t)NPLSwizzle(appController, sel, (IMP)npl_callbackFramerateChange);
            gHookedCallback = (npl_origCallbackFramerateChange != NULL);
        }
    }

    if (!gHookedRepaint) {
        SEL sel = NSSelectorFromString(@"repaintDisplayLink");
        if (class_getInstanceMethod(appController, sel)) {
            npl_origRepaintDisplayLink =
                (npl_repaint_display_link_t)NPLSwizzle(appController, sel, (IMP)npl_repaintDisplayLink);
            gHookedRepaint = (npl_origRepaintDisplayLink != NULL);
        }
    }

    if (!gHookedCADisplayLink) {
        Class linkClass = objc_getClass("CADisplayLink");
        if (linkClass) {
            BOOL a = NO, b = NO;
            SEL fpsSel = NSSelectorFromString(@"setPreferredFramesPerSecond:");
            if (class_getInstanceMethod(linkClass, fpsSel)) {
                npl_origSetPreferredFPS =
                    (npl_set_preferred_fps_t)NPLSwizzle(linkClass, fpsSel, (IMP)npl_setPreferredFramesPerSecond);
                a = (npl_origSetPreferredFPS != NULL);
            }
            SEL rangeSel = NSSelectorFromString(@"setPreferredFrameRateRange:");
            if (class_getInstanceMethod(linkClass, rangeSel)) {
                npl_origSetPreferredRange =
                    (npl_set_preferred_range_t)NPLSwizzle(linkClass, rangeSel, (IMP)npl_setPreferredFrameRateRange);
                b = (npl_origSetPreferredRange != NULL);
            }
            gHookedCADisplayLink = (a || b);
        }
    }

    if (!gHookedCallback) return;    // 核心 hook 没装上，继续重试

    if (!gAnnounced) {
        gAnnounced = YES;
        NPLLog(@"已安装 hook: callback=%d repaint=%d displayLink=%d (UnityAppController=%p)",
               gHookedCallback, gHookedRepaint, gHookedCADisplayLink, appController);
        NPLStartFPSMeter();
    }
}

static void NPLRetryHook(int attempt);

static void NPLRetryHook(int attempt) {
    if (gHookedCallback && gHookedRepaint && gHookedCADisplayLink) return;
    if (attempt > 600) return;       // 最多重试 60 秒
    NPLInstallHooks();
    if (gHookedCallback && gHookedRepaint && gHookedCADisplayLink) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NPLRetryHook(attempt + 1);
    });
}

static void NPLImageAdded(const struct mach_header *header, intptr_t slide) {
    const char *name = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (_dyld_get_image_header(i) == header) {
            name = _dyld_get_image_name(i);
            break;
        }
    }
    if (name && strstr(name, "UnityFramework")) {
        NPLRetryHook(0);
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

static void NPLPrintEnvironment(void) {
    char machine[128] = {0};
    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);

    NPLLog(@"=========== Cytus2-120FPS 载入 ===========");
    NPLLog(@"device=%s  ios=%@  process=%@", machine,
           [UIDevice currentDevice].systemVersion, [NSProcessInfo processInfo].processName);
    NPLLog(@"mainBundle=%@", NPLMainBundleID());
    NPLLog(@"bundlePath=%@", [NSBundle mainBundle].bundlePath);
    NPLLog(@"maximumFramesPerSecond=%ld  target=%d  ->  want=%d",
           (long)NPLScreenMaxFPS(), NPL_TARGET_FPS, NPLDesiredFPS());
    NPLLog(@"CADisableMinimumFrameDurationOnPhone = %@",
           [[NSBundle mainBundle].infoDictionary objectForKey:@"CADisableMinimumFrameDurationOnPhone"] ?: @"(missing)");
    NPLLog(@"HOME=%@", NSHomeDirectory());
}

__attribute__((constructor))
static void NPLInit(void) {
    NSString *only = NPL_ONLY_BUNDLEID;
    if (only.length > 0) {
        NSString *bid = NPLMainBundleID();
        if (![bid isEqualToString:only]) {
            NSLog(@"[Cytus2-120FPS] bundle %@ != %@，跳过", bid, only);
            return;
        }
    }

    NPLPrintEnvironment();
    NPLPatchMainBundleInfoDict();

    // UnityFramework 已经加载的情况
    NPLInstallHooks();

    // UnityFramework 之后才 dlopen 的情况（LiveContainer 常见）
    _dyld_register_func_for_add_image(NPLImageAdded);
    NPLRetryHook(0);
}
