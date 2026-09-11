//
//  Tweak.mm — Cytus2-120FPS  (v1.1, 稳定性修复版)
//
//  用途：在 LiveContainer（ElleKit / rootless 越狱）里把 Cytus II 的刷新率强制到 120Hz。
//
//  原理（详见 docs/01-refresh-rate-analysis.md）：
//    Cytus II 的 Rayark.Cytus2.FrameRateAdjuster 把默认帧率硬编码为 60，
//    游戏通过 Application.targetFrameRate = v
//      → il2cpp icall → Unity C++ 引擎（gTargetFrameRate = v）
//      → -[UnityAppController callbackFramerateChange:v]
//      → -[CADisplayLink setPreferredFrameRateRange:] / setPreferredFramesPerSecond:
//    来限制帧率。iOS 上渲染节拍完全由 CADisplayLink 决定（repaint 里没有任何按帧率跳帧的逻辑），
//    所以只要把这里传入的 rate 改成 120 就解除了限制。
//
//  v1.1 相对 v1.0 的改动（v1.0 会闪退）：
//    1. il2cpp 同步默认关闭（NPL_SYNC_ENGINE_FPS=0）。
//       在「引擎自己的帧率通知」里面再调用 Application.set_targetFrameRate 会重入引擎的
//       SetTargetFramerate 路径（很可能拿同一把锁），风险极高；而且渲染节拍由 display link
//       决定，这个同步本来就是多余的。
//    2. Info.plist 内存补丁默认关闭（NPL_PATCH_INFOPLIST=0）。
//       iPad 上 CADisableMinimumFrameDurationOnPhone 本来就被忽略，
//       真机日志里 maximumFramesPerSecond 已经是 120，完全不需要动 CFBundle。
//    3. CADisplayLink 的全局 swizzle 默认关闭（NPL_HOOK_CADISPLAYLINK=0）。
//       已经用 xref 验证过：整个二进制里 setPreferredFramesPerSecond:/
//       setPreferredFrameRateRange: 只在 callbackFramerateChange: 一处被调用，
//       所以只 hook 这一个方法就足够，尽量少碰系统类。
//    4. hook 只在主线程安装（v1.0 是后台队列里 swizzle，可能与主线程的引擎启动竞争）。
//    5. 日志改成同步写盘（v1.0 是 dispatch_async，崩溃前几行会丢），
//       并加了信号/异常处理器，崩溃时把回溯写进同一个日志文件。
//    6. 增加一键禁用开关：在游戏容器 Documents/ 下建一个空文件 120fps.disable 即可跳过全部逻辑。
//
//  配置宏见下面「配置」一节。
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <execinfo.h>
#import <pthread.h>
#import <limits.h>

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

// 目标帧率
#define NPL_TARGET_FPS              120

// 1 = 不管 [UIScreen mainScreen].maximumFramesPerSecond 报多少都请求 120
//     （60Hz 设备上系统会自己夹回 60，无副作用）
#define NPL_IGNORE_SCREEN_MAX       1

// 是否用 il2cpp API 把 Application.targetFrameRate 也同步成目标值。
// ⚠ 默认关闭：会从引擎的帧率通知里重入引擎，v1.0 的闪退嫌疑点；而且对渲染节拍没有影响。
#define NPL_SYNC_ENGINE_FPS         0

// 是否在内存里把 CADisableMinimumFrameDurationOnPhone 改成 true。
// ⚠ 默认关闭：iPad 忽略该键（真机日志已确认 maximumFramesPerSecond=120），没必要动 CFBundle。
#define NPL_PATCH_INFOPLIST         0

// 是否 hook CADisplayLink 的 rate setter（只作用于 Unity 那一个 link）。
// ⚠ 默认关闭：callbackFramerateChange: 已经是唯一的设置点，少碰系统类更安全。
#define NPL_HOOK_CADISPLAYLINK      0

// 每秒统计一次真实渲染 FPS 写日志（最多 10 分钟）
#define NPL_FPS_LOG                 1

// 只对指定 bundle id 生效；空字符串 = 所有 Unity 游戏
#define NPL_ONLY_BUNDLEID           @""

// ---------------------------------------------------------------------------
// 日志（同步写盘；崩溃处理器也用同一个 fd）
// ---------------------------------------------------------------------------

static int gLogFD = -1;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;

static void NPLOpenLogFD(void) {
    if (gLogFD >= 0) return;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        dir = NSTemporaryDirectory();
    }
    NSString *path = [dir stringByAppendingPathComponent:@"120fps.log"];
    gLogFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void NPLTimestamp(char *out, size_t n) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    snprintf(out, n, "%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

static void NPLLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[Cytus2-120FPS] %@", msg);

    NPLOpenLogFD();
    if (gLogFD < 0) return;

    char ts[32];
    NPLTimestamp(ts, sizeof(ts));
    char line[4096];
    int n = snprintf(line, sizeof(line), "%s %s\n", ts, msg.UTF8String);
    if (n <= 0) return;
    if ((size_t)n > sizeof(line)) n = (int)sizeof(line);

    pthread_mutex_lock(&gLogLock);
    ssize_t ignore = write(gLogFD, line, (size_t)n);
    (void)ignore;
    pthread_mutex_unlock(&gLogLock);
}

// ---------------------------------------------------------------------------
// 崩溃处理器（写回到同一个日志文件，方便定位闪退）
// ---------------------------------------------------------------------------

static void NPLWriteCrash(const char *s, size_t n) {
    if (gLogFD >= 0) {
        ssize_t ignore = write(gLogFD, s, n);
        (void)ignore;
    }
}

static void NPLSignalHandler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    char buf[512];
    const char *name = strsignal(sig);
    int n = snprintf(buf, sizeof(buf), "\n!!!!!! CRASH: signal %d (%s) addr=%p pid=%d thread=%s\n",
                     sig, name ? name : "?", info ? info->si_addr : NULL, getpid(),
                     pthread_main_np() ? "main" : "other");
    if (n > 0) NPLWriteCrash(buf, (size_t)n);

    void *frames[80];
    int count = backtrace(frames, 80);
    backtrace_symbols_fd(frames, count, gLogFD >= 0 ? gLogFD : STDERR_FILENO);
    NPLWriteCrash("!!!!!! end crash backtrace\n", 27);

    signal(sig, SIG_DFL);
    raise(sig);
}

static void NPLExceptionHandler(NSException *e) {
    char buf[2048];
    int n = snprintf(buf, sizeof(buf), "\n!!!!!! ObjC EXCEPTION: %s: %s\n%s\n",
                     e.name.UTF8String, e.reason.UTF8String,
                     e.callStackSymbols.description.UTF8String);
    if (n > 0) {
        if ((size_t)n > sizeof(buf)) n = (int)sizeof(buf);
        NPLWriteCrash(buf, (size_t)n);
    }
}

static void NPLInstallCrashHandlers(void) {
    static struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = NPLSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    const int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
    NSSetUncaughtExceptionHandler(&NPLExceptionHandler);
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

static int NPLDesiredFPS(void) {
    NSInteger maxFPS = NPLScreenMaxFPS();
    int want = NPL_TARGET_FPS;
#if !NPL_IGNORE_SCREEN_MAX
    if (want > (int)maxFPS) want = (int)maxFPS;
#endif
    if (want < 1) want = (int)maxFPS;
    return want;
}

static BOOL NPLDisabledByUser(void) {
    NSString *marker = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/120fps.disable"];
    return [[NSFileManager defaultManager] fileExistsAtPath:marker];
}

static IMP NPLSwizzle(Class cls, SEL sel, IMP newIMP) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;

    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    Class super = class_getSuperclass(cls);

    // 继承来的方法：在子类上加覆盖，别动父类
    if (super && class_getInstanceMethod(super, sel) == m) {
        if (!class_addMethod(cls, sel, newIMP, types)) return NULL;
        return orig;
    }
    method_setImplementation(m, newIMP);
    return orig;
}

// ---------------------------------------------------------------------------
// Hook 1: -[UnityAppController callbackFramerateChange:]   （核心）
// ---------------------------------------------------------------------------

#if NPL_SYNC_ENGINE_FPS
static void NPLSyncEngineTargetFPS(int fps);   // 定义见后面 il2cpp 一节
#endif

typedef void (*npl_callback_framerate_change_t)(id, SEL, int);
static npl_callback_framerate_change_t npl_origCallbackFramerateChange = NULL;

static BOOL gInCallbackHook = NO;
static __weak CADisplayLink *gUnityDisplayLink = nil;

static void npl_callbackFramerateChange(id self, SEL _cmd, int fps) {
    if (!npl_origCallbackFramerateChange) return;

    // 递归保护：Unity 在「请求值 > 屏幕上限」时会夹回并重新通知（notify → 本方法），
    // 嵌套调用原样放行，避免死循环。
    if (gInCallbackHook) {
        npl_origCallbackFramerateChange(self, _cmd, fps);
        return;
    }

    int want = NPLDesiredFPS();
    gInCallbackHook = YES;

    static int callCount = 0;
    int n = ++callCount;

    // 记录 Unity 的 display link（只用于日志/可选 hook）
    if ([self respondsToSelector:NSSelectorFromString(@"unityDisplayLink")]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id link = [self performSelector:NSSelectorFromString(@"unityDisplayLink")];
#pragma clang diagnostic pop
            if (link && [link isKindOfClass:objc_getClass("CADisplayLink")]) gUnityDisplayLink = link;
        } @catch (__unused NSException *e) {
        }
    }

    NPLLog(@"#%d callbackFramerateChange: 游戏请求 %d → 强制 %d（屏幕上限 %ld, displayLink=%p）",
           n, fps, want, (long)NPLScreenMaxFPS(), gUnityDisplayLink);

#if NPL_SYNC_ENGINE_FPS
    NPLSyncEngineTargetFPS(want);
#endif

    npl_origCallbackFramerateChange(self, _cmd, want);

    gInCallbackHook = NO;
    NPLLog(@"#%d callbackFramerateChange: 原实现返回", n);
}

#if NPL_HOOK_CADISPLAYLINK

typedef void (*npl_set_preferred_fps_t)(id, SEL, NSInteger);
typedef struct { float minimum, maximum, preferred; } NPLFrameRateRange;
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

#endif // NPL_HOOK_CADISPLAYLINK

// ---------------------------------------------------------------------------
// Hook 2（诊断）: 统计真实渲染 FPS
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
        if (logged >= 600) return;
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
// il2cpp API（默认关闭，见 NPL_SYNC_ENGINE_FPS 的说明）
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

static void *NPLUnitySymbol(const char *name) {
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

static const MethodInfo *gAppSetTargetFPS = NULL;
static BOOL gAppSetTargetFPSResolveFailed = NO;

static const MethodInfo *NPLResolveApplicationSetTargetFPS(void) {
    if (gAppSetTargetFPS || gAppSetTargetFPSResolveFailed) return gAppSetTargetFPS;
    if (!NPLLoadIl2cppAPI()) return NULL;
    Il2CppDomain *domain = p_domain_get();
    if (!domain) return NULL;

    Il2CppImage *coreImage = NULL;
    if (p_domain_get_assemblies && p_assembly_get_image) {
        size_t count = 0;
        const Il2CppAssembly **assemblies = p_domain_get_assemblies(domain, &count);
        for (size_t i = 0; assemblies && i < count; i++) {
            Il2CppImage *img = p_assembly_get_image(assemblies[i]);
            const char *name = (img && p_image_get_name) ? p_image_get_name(img) : NULL;
            if (name && strstr(name, "UnityEngine.CoreModule")) { coreImage = img; break; }
        }
    }
    if (!coreImage && p_domain_assembly_open && p_assembly_get_image) {
        Il2CppAssembly *a = p_domain_assembly_open(domain, "UnityEngine.CoreModule");
        if (a) coreImage = p_assembly_get_image(a);
    }
    if (!coreImage) return NULL;

    Il2CppClass *klass = p_class_from_name(coreImage, "UnityEngine", "Application");
    if (!klass) { gAppSetTargetFPSResolveFailed = YES; NPLLog(@"il2cpp: 找不到 Application 类"); return NULL; }
    const MethodInfo *mi = p_class_get_method_from_name(klass, "set_targetFrameRate", 1);
    if (!mi) { gAppSetTargetFPSResolveFailed = YES; NPLLog(@"il2cpp: 找不到 set_targetFrameRate"); return NULL; }
    gAppSetTargetFPS = mi;
    NPLLog(@"il2cpp: 已解析 Application.set_targetFrameRate = %p", mi);
    return mi;
}

static void NPLSyncEngineTargetFPS(int fps) {
    if (![NSThread isMainThread]) return;
    if (!NPLLoadIl2cppAPI()) return;
    if (!p_domain_get || !p_domain_get()) return;
    if (!p_thread_current || !p_thread_current()) return;
    const MethodInfo *mi = NPLResolveApplicationSetTargetFPS();
    if (!mi) return;
    int value = fps;
    void *params[1] = { &value };
    Il2CppException *exc = NULL;
    NPLLog(@"il2cpp: 即将 invoke set_targetFrameRate(%d)", fps);
    p_runtime_invoke(mi, NULL, params, &exc);
    NPLLog(@"il2cpp: invoke 返回 (exc=%p)", exc);
}

#endif // NPL_SYNC_ENGINE_FPS

// ---------------------------------------------------------------------------
// Info.plist 内存补丁（默认关闭）
// ---------------------------------------------------------------------------

static void NPLReportInfoPlistKey(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    NSString *value = @"?";
    if (bundle) {
        CFTypeRef v = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CADisableMinimumFrameDurationOnPhone"));
        value = v ? [NSString stringWithFormat:@"%@", v] : @"(missing)";
    }
    NPLLog(@"Info.plist: CADisableMinimumFrameDurationOnPhone = %@（iPad 忽略该键）", value);

#if NPL_PATCH_INFOPLIST
    if (bundle && CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CADisableMinimumFrameDurationOnPhone")) != kCFBooleanTrue) {
        CFMutableDictionaryRef info = (CFMutableDictionaryRef)CFBundleGetInfoDictionary(bundle);
        if (info && [(__bridge NSDictionary *)info respondsToSelector:@selector(setObject:forKey:)]) {
            @try {
                [(__bridge NSMutableDictionary *)info setObject:@YES forKey:@"CADisableMinimumFrameDurationOnPhone"];
                NPLLog(@"Info.plist: 已在内存中设为 true");
            } @catch (NSException *e) {
                NPLLog(@"Info.plist: 内存补丁失败: %@", e.reason);
            }
        }
    }
#endif
}

// ---------------------------------------------------------------------------
// 安装 hook（只在主线程做；UnityFramework 可能是启动后才 dlopen 进来的）
// ---------------------------------------------------------------------------

static BOOL gHookedCallback = NO;
static BOOL gHookedRepaint  = NO;
static BOOL gHookedCADisplayLink = NO;
static BOOL gAnnounced = NO;

static void NPLInstallHooksOnMainThread(void) {
    if (gHookedCallback && gHookedRepaint && (gHookedCADisplayLink || !NPL_HOOK_CADISPLAYLINK)) return;

    Class appController = objc_getClass("UnityAppController");
    if (!appController) return;

    if (!gHookedCallback) {
        SEL sel = NSSelectorFromString(@"callbackFramerateChange:");
        if (class_getInstanceMethod(appController, sel)) {
            npl_origCallbackFramerateChange =
                (npl_callback_framerate_change_t)NPLSwizzle(appController, sel, (IMP)npl_callbackFramerateChange);
            gHookedCallback = (npl_origCallbackFramerateChange != NULL);
            NPLLog(@"安装 hook callbackFramerateChange: %@", gHookedCallback ? @"OK" : @"失败");
        }
    }

    if (!gHookedRepaint) {
        SEL sel = NSSelectorFromString(@"repaintDisplayLink");
        if (class_getInstanceMethod(appController, sel)) {
            npl_origRepaintDisplayLink =
                (npl_repaint_display_link_t)NPLSwizzle(appController, sel, (IMP)npl_repaintDisplayLink);
            gHookedRepaint = (npl_origRepaintDisplayLink != NULL);
            NPLLog(@"安装 hook repaintDisplayLink: %@", gHookedRepaint ? @"OK" : @"失败");
        }
    }

#if NPL_HOOK_CADISPLAYLINK
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
                    (npl_set_preferred_range_t)NPLSwizzle(linkClass, rangeSel, (IMP)npl_set_preferredFrameRateRange);
                b = (npl_origSetPreferredRange != NULL);
            }
            gHookedCADisplayLink = (a || b);
        }
    }
#else
    gHookedCADisplayLink = YES;
#endif

    if (!gHookedCallback) return;

    if (!gAnnounced) {
        gAnnounced = YES;
        NPLLog(@"已安装 hook: callback=%d repaint=%d displayLink=%d (UnityAppController=%p)",
               gHookedCallback, gHookedRepaint, gHookedCADisplayLink, appController);
        NPLStartFPSMeter();
    }
}

static void NPLScheduleRetry(int attempt);

static void NPLRetryHook(int attempt) {
    if (gHookedCallback && gHookedRepaint && gHookedCADisplayLink) return;
    if (attempt > 1200) return;          // 最多重试 120 秒

    if (![NSThread isMainThread]) {      // 保证只在主线程 swizzle
        dispatch_async(dispatch_get_main_queue(), ^{ NPLRetryHook(attempt); });
        return;
    }
    NPLInstallHooksOnMainThread();
    if (gHookedCallback && gHookedRepaint && gHookedCADisplayLink) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        NPLRetryHook(attempt + 1);
    });
}
static void NPLScheduleRetry(int attempt) { NPLRetryHook(attempt); }

static void NPLImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
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

    NPLLog(@"=========== Cytus2-120FPS v1.1 载入 ===========");
    NPLLog(@"device=%s  ios=%@  process=%@", machine,
           [UIDevice currentDevice].systemVersion, [NSProcessInfo processInfo].processName);
    NPLLog(@"mainBundle=%@", NPLMainBundleID());
    NPLLog(@"bundlePath=%@", [NSBundle mainBundle].bundlePath);
    NPLLog(@"maximumFramesPerSecond=%ld  target=%d  ->  want=%d",
           (long)NPLScreenMaxFPS(), NPL_TARGET_FPS, NPLDesiredFPS());
    NPLLog(@"HOME=%@", NSHomeDirectory());
    NPLLog(@"配置: syncEngine=%d patchPlist=%d hookCADisplayLink=%d",
           NPL_SYNC_ENGINE_FPS, NPL_PATCH_INFOPLIST, NPL_HOOK_CADISPLAYLINK);
}

__attribute__((constructor))
static void NPLInit(void) {
    if (NPLDisabledByUser()) {
        NSLog(@"[Cytus2-120FPS] 检测到 Documents/120fps.disable，跳过");
        return;
    }

    NSString *only = NPL_ONLY_BUNDLEID;
    if (only.length > 0) {
        NSString *bid = NPLMainBundleID();
        if (![bid isEqualToString:only]) return;
    }

    NPLOpenLogFD();
    NPLInstallCrashHandlers();
    NPLPrintEnvironment();
    NPLReportInfoPlistKey();

    if ([NSThread isMainThread]) {
        NPLInstallHooksOnMainThread();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ NPLInstallHooksOnMainThread(); });
    }

    _dyld_register_func_for_add_image(NPLImageAdded);
    NPLScheduleRetry(0);
}
