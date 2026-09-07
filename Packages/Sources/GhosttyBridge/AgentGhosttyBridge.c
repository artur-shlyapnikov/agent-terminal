/*
 * AgentGhosttyBridge — translation layer over the pinned vendored libghostty
 * (commit da5ddcb0857c0e4ddb32f7a089911e9038d040f3, ADR-0002).
 *
 * Every libghostty union/tagged-enum/callback payload is converted here into
 * plain-C data. Strings that escape to the consumer are malloc'd copies;
 * Zig pointers never cross the boundary. Event-payload strings are borrowed
 * to the consumer for the duration of the callback only; read/diagnostic
 * results transfer ownership. See AgentGhosttyBridge.h for the threading and
 * lifecycle contract.
 */
#include "include/AgentGhosttyBridge.h"

#define GHOSTTY_STATIC 1
#include <ghostty.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define AGT_BRIDGE_ABI_VERSION 2u

uint32_t agt_bridge_abi_version(void) {
    return AGT_BRIDGE_ABI_VERSION;
}

// ---------------------------------------------------------------------------
// Process-global bootstrap (ADR-0002 finding 1: ghostty_init is mandatory and
// must run exactly once before any other API call).
// ---------------------------------------------------------------------------

static pthread_mutex_t g_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_initialized = 0;

AGTStatusCode agt_bridge_global_init(void) {
    pthread_mutex_lock(&g_init_mutex);
    if (!g_initialized) {
        int rc = ghostty_init(0, NULL);
        if (rc != GHOSTTY_SUCCESS) {
            pthread_mutex_unlock(&g_init_mutex);
            return AGTStatusInternal;
        }
        g_initialized = 1;
    }
    pthread_mutex_unlock(&g_init_mutex);
    return AGTStatusOK;
}

void agt_bridge_string_free(char* string) {
    free(string);
}

static char* agt_strdup(const char* source) {
    if (source == NULL) {
        return NULL;
    }
    size_t len = strlen(source);
    char* copy = malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, source, len + 1);
    return copy;
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

struct AGTBridgeRuntime {
    ghostty_app_t app;
    ghostty_config_t config;
    /// Copy of the consumer callback set; callbacks.userdata is echoed back.
    AGTRuntimeCallbacks callbacks;
    /// Diagnostics captured at config finalize time (malloc'd strings).
    char** diagnostics;
    uint32_t diagnostic_count;
};

/// action_cb has no userdata parameter, so the runtime is resolved through a
/// process-global slot. GhosttyEngine is a @MainActor singleton per
/// architecture §3.8; exactly one runtime per process is supported. Callbacks
/// may arrive on any thread, so access is mutex-guarded (clang rejects
/// __atomic builtins on struct-pointer _Atomic slots on this toolchain).
/// Recursive because ghostty_surface_free may synchronously re-enter bridge
/// callbacks (e.g. close_surface_cb) that lock this mutex on the same thread.
/// It is held across agt_bridge_surface_free to serialize against in-flight
/// callback trampolines that dereference the surface's Swift callback box.
static pthread_mutex_t g_runtime_mutex;

/// Attribute-based init: PTHREAD_MUTEX_INITIALIZER cannot express
/// PTHREAD_MUTEX_RECURSIVE. Constructors run at load, before any bridge call.
__attribute__((constructor)) static void agt_init_runtime_mutex(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_runtime_mutex, &attr);
    pthread_mutexattr_destroy(&attr);
}

/// Set across agt_bridge_runtime_free: libghostty-reentrant trampolines
/// during ghostty_app_free bail on this instead of using a freed runtime or
/// deadlocking on g_runtime_mutex.
static atomic_bool g_teardown_in_progress = false;

/// Double-entry guard for agt_bridge_runtime_create. Documented usage is
/// single-threaded (@MainActor), so a plain atomic flag is enough: the first
/// create claims it before ghostty_app_new and releases it on every exit
/// path, and any concurrent entry fails with AGTStatusInternal instead of
/// racing past the active-runtime check and double-publishing (or leaking)
/// a second runtime. Deliberately NOT held via g_runtime_mutex across
/// ghostty_app_new: that call can re-enter bridge callbacks which take the
/// same mutex, so serializing create under it risks self-deadlock.
static atomic_bool g_runtime_create_in_progress = false;

static struct AGTBridgeRuntime* g_active_runtime = NULL;

static bool agt_claim_runtime_create(void) {
    return !atomic_exchange(&g_runtime_create_in_progress, true);
}

static void agt_release_runtime_create(void) {
    atomic_store(&g_runtime_create_in_progress, false);
}

/// Liveness registry for native surfaces, guarded by g_runtime_mutex.
/// agt_action_cb validates its target here after acquiring the lock;
/// agt_bridge_surface_free unregisters BEFORE ghostty_surface_free under
/// the same lock. A trampoline that was blocked on the lock while a
/// surface was freed therefore observes the removal and bails instead of
/// calling ghostty_surface_userdata on freed memory (and dispatching
/// through a dead Swift callback box). Check-then-use is atomic: any
/// trampoline past the check holds the lock through dispatch, and the
/// free waits for that lock.
#define AGT_MAX_LIVE_SURFACES 64
static ghostty_surface_t g_live_surfaces[AGT_MAX_LIVE_SURFACES];

/// All three require g_runtime_mutex held.
static void agt_surface_registry_add(ghostty_surface_t surface) {
    if (surface == NULL) {
        return;
    }
    for (size_t i = 0; i < AGT_MAX_LIVE_SURFACES; i++) {
        if (g_live_surfaces[i] == NULL) {
            g_live_surfaces[i] = surface;
            return;
        }
    }
    // Registry exhausted: leave unregistered — fail-closed, the action
    // callback then drops this surface's events rather than risk them.
}

static void agt_surface_registry_remove(ghostty_surface_t surface) {
    if (surface == NULL) {
        return;
    }
    for (size_t i = 0; i < AGT_MAX_LIVE_SURFACES; i++) {
        if (g_live_surfaces[i] == surface) {
            g_live_surfaces[i] = NULL;
            return;
        }
    }
}

static bool agt_surface_registry_contains(ghostty_surface_t surface) {
    if (surface == NULL) {
        return false;
    }
    for (size_t i = 0; i < AGT_MAX_LIVE_SURFACES; i++) {
        if (g_live_surfaces[i] == surface) {
            return true;
        }
    }
    return false;
}

static struct AGTBridgeRuntime* agt_active_runtime(void) {
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    pthread_mutex_unlock(&g_runtime_mutex);
    return runtime;
}

static void agt_set_active_runtime(struct AGTBridgeRuntime* runtime) {
    pthread_mutex_lock(&g_runtime_mutex);
    g_active_runtime = runtime;
    pthread_mutex_unlock(&g_runtime_mutex);
}

/// Fills `event` with the translated form of a surface/app action. String
/// fields are fresh malloc'd copies, freed by the bridge once the consumer
/// callback returns. Returns false for actions we deliberately do not
/// surface (structural tab/split commands etc.).
static bool agt_translate_action(ghostty_target_s target,
                                 ghostty_action_s action,
                                 AGTEvent* event) {
    memset(event, 0, sizeof(*event));
    if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface != NULL) {
        // The userdata pointer is read only after agt_action_cb proved the
        // surface is still in the liveness registry (same lock), so it
        // cannot belong to an already-freed surface here.
        event->surface_context = ghostty_surface_userdata(target.target.surface);
    }
    event->progress_percent = -1;
    event->command_exit_code = -1;

    switch (action.tag) {
        case GHOSTTY_ACTION_RENDER:
            event->kind = AGTEventRender;
            return true;
        case GHOSTTY_ACTION_SET_TITLE:
        case GHOSTTY_ACTION_SET_WINDOW_TITLE:
            event->kind = AGTEventTitle;
            event->title = agt_strdup(action.action.set_title.title);
            return true;
        case GHOSTTY_ACTION_PWD:
            event->kind = AGTEventPwd;
            event->pwd = agt_strdup(action.action.pwd.pwd);
            return true;
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Opportunistic accelerator only — unreliable under many live
            // surfaces (ADR-0002 finding 5). Polling is the primary signal.
            event->kind = AGTEventChildExited;
            event->exit_code = action.action.child_exited.exit_code;
            return true;
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            event->kind = AGTEventCommandFinished;
            event->command_exit_code = action.action.command_finished.exit_code;
            event->duration_ns = action.action.command_finished.duration;
            return true;
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            event->kind = AGTEventProgress;
            event->progress_state = (int32_t)action.action.progress_report.state;
            event->progress_percent = action.action.progress_report.progress;
            return true;
        case GHOSTTY_ACTION_RING_BELL:
            event->kind = AGTEventBell;
            return true;
        case GHOSTTY_ACTION_SELECTION_CHANGED:
            event->kind = AGTEventSelectionChanged;
            return true;
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            event->kind = AGTEventNotification;
            event->title = agt_strdup(action.action.desktop_notification.title);
            event->body = agt_strdup(action.action.desktop_notification.body);
            return true;
        case GHOSTTY_ACTION_OPEN_URL:
            event->kind = AGTEventOpenURL;
            event->url_kind = (int32_t)action.action.open_url.kind;
            if (action.action.open_url.url != NULL &&
                action.action.open_url.len > 0) {
                size_t len = (size_t)action.action.open_url.len;
                event->url = malloc(len + 1);
                if (event->url != NULL) {
                    memcpy(event->url, action.action.open_url.url, len);
                    event->url[len] = '\0';
                }
            }
            return true;
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            event->kind = AGTEventMouseShape;
            event->mouse_shape = (int32_t)action.action.mouse_shape;
            return true;
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            // Structural decisions belong to the app (§3.8): Ghostty must not
            // own layout/window structure, but we still forward the intent.
            event->kind = AGTEventCloseWindow;
            return true;
        default:
            return false;
    }
}

static bool agt_action_cb(ghostty_app_t app,
                          ghostty_target_s target,
                          ghostty_action_s action) {
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return true;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime == NULL || runtime->app != app ||
        runtime->callbacks.event == NULL) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return true;
    }

    // Surface-targeted events must prove the surface is still live: a
    // trampoline that waited on this lock while the surface was freed
    // would otherwise read freed memory in agt_translate_action and
    // dispatch through a dead Swift box.
    if (target.tag == GHOSTTY_TARGET_SURFACE &&
        !agt_surface_registry_contains(target.target.surface)) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return true;
    }

    AGTEvent event;
    if (!agt_translate_action(target, action, &event)) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return true;
    }

    runtime->callbacks.event(&event, runtime->callbacks.userdata);

    // Strings inside `event` were borrowed to the consumer for the duration
    // of the callback only; release them now (header contract).
    agt_bridge_string_free(event.title);
    agt_bridge_string_free(event.body);
    agt_bridge_string_free(event.pwd);
    agt_bridge_string_free(event.url);
    pthread_mutex_unlock(&g_runtime_mutex);
    return true;
}

static void agt_wakeup_cb(void* ud) {
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime != NULL && runtime->callbacks.userdata == ud &&
        runtime->callbacks.wakeup != NULL) {
        runtime->callbacks.wakeup(ud);
    }
    pthread_mutex_unlock(&g_runtime_mutex);
}

static void agt_close_surface_cb(void* ud, bool process_alive) {
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime == NULL || runtime->callbacks.close_surface == NULL) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return;
    }
    // Identity: app-scoped deliveries carry the runtime box, but libghostty
    // may also deliver surface-scoped closes with the per-surface userdata
    // (GhosttyEngine installs a DeliveryBox per surface via
    // AGTSurfaceConfig.userdata). The vendored Zig sources are not
    // inspectable, so accept EITHER pointer: anything that is not the
    // runtime box must match the native userdata of a surface that is still
    // live in the registry (same liveness proof agt_action_cb requires);
    // unknown pointers are dropped rather than guessed at. Valid closes are
    // then routed through the runtime identity — the consumer contract
    // echoes callbacks.userdata, and the router resolves its delegate from
    // that box alone.
    if (runtime->callbacks.userdata != ud) {
        bool known_surface = false;
        for (size_t i = 0; i < AGT_MAX_LIVE_SURFACES && !known_surface; i++) {
            ghostty_surface_t live = g_live_surfaces[i];
            known_surface = live != NULL && ghostty_surface_userdata(live) == ud;
        }
        if (!known_surface) {
            pthread_mutex_unlock(&g_runtime_mutex);
            return;
        }
        ud = runtime->callbacks.userdata;
    }
    runtime->callbacks.close_surface(process_alive, ud);
    pthread_mutex_unlock(&g_runtime_mutex);
}

static bool agt_read_clipboard_cb(void* ud, ghostty_clipboard_e clipboard, void* context) {
    (void)context;
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return false;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime == NULL || runtime->callbacks.userdata != ud ||
        runtime->callbacks.read_clipboard == NULL) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return false; // deny by default: policy lives in TerminalKit
    }
    bool allow = runtime->callbacks.read_clipboard((int32_t)clipboard, ud);
    pthread_mutex_unlock(&g_runtime_mutex);
    return allow;
}

static void agt_confirm_read_clipboard_cb(void* ud,
                                          const char* prompt,
                                          void* context,
                                          ghostty_clipboard_request_e request) {
    (void)context;
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime == NULL || runtime->callbacks.userdata != ud ||
        runtime->callbacks.confirm_read_clipboard == NULL) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return;
    }
    char* prompt_copy = agt_strdup(prompt);
    runtime->callbacks.confirm_read_clipboard(prompt_copy, (int32_t)request, ud);
    agt_bridge_string_free(prompt_copy);
    pthread_mutex_unlock(&g_runtime_mutex);
}

static void agt_write_clipboard_cb(void* ud,
                                   ghostty_clipboard_e clipboard,
                                   const ghostty_clipboard_content_s* contents,
                                   size_t count,
                                   bool from_osc52) {
    (void)from_osc52;
    // Teardown in progress: g_active_runtime may already be freed, so bail
    // before touching the mutex or the runtime.
    if (atomic_load(&g_teardown_in_progress)) {
        return;
    }
    // Hold the lock across the whole body so the resolved runtime cannot be
    // freed mid-callback (consumer callbacks never block).
    pthread_mutex_lock(&g_runtime_mutex);
    struct AGTBridgeRuntime* runtime = g_active_runtime;
    if (runtime == NULL || runtime->callbacks.userdata != ud ||
        runtime->callbacks.write_clipboard == NULL || contents == NULL) {
        pthread_mutex_unlock(&g_runtime_mutex);
        return;
    }
    for (size_t i = 0; i < count; i++) {
        char* mime = agt_strdup(contents[i].mime);
        char* data = agt_strdup(contents[i].data);
        runtime->callbacks.write_clipboard((int32_t)clipboard, mime, data, ud);
        agt_bridge_string_free(mime);
        agt_bridge_string_free(data);
    }
    pthread_mutex_unlock(&g_runtime_mutex);
}

AGTStatusCode agt_bridge_runtime_create(const char* config_path,
                                        const AGTRuntimeCallbacks* callbacks,
                                        void** out_runtime) {
    if (out_runtime == NULL || callbacks == NULL || callbacks->event == NULL) {
        return AGTStatusInvalidArgument;
    }
    if (agt_bridge_global_init() != AGTStatusOK) {
        return AGTStatusNotInitialized;
    }
    if (agt_active_runtime() != NULL || !agt_claim_runtime_create()) {
        // One runtime per process (§3.8 singleton engine); a concurrent
        // in-flight create counts as a violation too.
        return AGTStatusInternal;
    }

    struct AGTBridgeRuntime* runtime = calloc(1, sizeof(*runtime));
    if (runtime == NULL) {
        agt_release_runtime_create();
        return AGTStatusInternal;
    }
    runtime->callbacks = *callbacks;

    ghostty_config_t config = ghostty_config_new();
    if (config == NULL) {
        free(runtime);
        agt_release_runtime_create();
        return AGTStatusInternal;
    }
    if (config_path != NULL) {
        ghostty_config_load_file(config, config_path);
    }
    ghostty_config_finalize(config);
    runtime->config = config;

    uint32_t diag_count = ghostty_config_diagnostics_count(config);
    if (diag_count > 0) {
        runtime->diagnostics = calloc(diag_count, sizeof(char*));
        runtime->diagnostic_count = 0;
        for (uint32_t i = 0; i < diag_count && runtime->diagnostics != NULL; i++) {
            ghostty_diagnostic_s d = ghostty_config_get_diagnostic(config, i);
            if (d.message == NULL) {
                continue;
            }
            runtime->diagnostics[runtime->diagnostic_count++] =
                agt_strdup(d.message);
        }
    }

    ghostty_runtime_config_s runtime_config;
    memset(&runtime_config, 0, sizeof(runtime_config));
    runtime_config.supports_selection_clipboard = false;
    runtime_config.userdata = callbacks->userdata;
    runtime_config.wakeup_cb = agt_wakeup_cb;
    runtime_config.action_cb = agt_action_cb;
    runtime_config.read_clipboard_cb = agt_read_clipboard_cb;
    runtime_config.confirm_read_clipboard_cb = agt_confirm_read_clipboard_cb;
    runtime_config.write_clipboard_cb = agt_write_clipboard_cb;
    runtime_config.close_surface_cb = agt_close_surface_cb;

    // ADR-0002 finding 2: runtime config (incl. userdata) is cloned inside
    // ghostty_app_new — everything above must be in place before this call.
    ghostty_app_t app = ghostty_app_new(&runtime_config, config);
    if (app == NULL) {
        for (uint32_t i = 0; i < runtime->diagnostic_count; i++) {
            free(runtime->diagnostics[i]);
        }
        free(runtime->diagnostics);
        ghostty_config_free(config);
        free(runtime);
        agt_release_runtime_create();
        return AGTStatusInternal;
    }

    runtime->app = app;
    agt_set_active_runtime(runtime);
    *out_runtime = runtime;
    agt_release_runtime_create();
    return AGTStatusOK;
}

void agt_bridge_runtime_free(void* opaque) {
    struct AGTBridgeRuntime* runtime = (struct AGTBridgeRuntime*)opaque;
    if (runtime == NULL) {
        return;
    }
    // Detach first and raise the teardown flag under the lock: a trampoline
    // already past its unlocked check blocks here, then observes the NULL
    // runtime, while libghostty-reentrant trampolines during ghostty_app_free
    // below see the flag and bail instead of deadlocking on this mutex.
    pthread_mutex_lock(&g_runtime_mutex);
    if (g_active_runtime == runtime) {
        g_active_runtime = NULL;
    }
    atomic_store(&g_teardown_in_progress, true);
    pthread_mutex_unlock(&g_runtime_mutex);

    ghostty_app_free(runtime->app);
    ghostty_config_free(runtime->config);
    for (uint32_t i = 0; i < runtime->diagnostic_count; i++) {
        free(runtime->diagnostics[i]);
    }
    free(runtime->diagnostics);
    free(runtime);

    // Allow a subsequent runtime (one per process) to receive callbacks again.
    atomic_store(&g_teardown_in_progress, false);
}

void agt_bridge_runtime_tick(void* opaque) {
    struct AGTBridgeRuntime* runtime = (struct AGTBridgeRuntime*)opaque;
    if (runtime == NULL) {
        return;
    }
    ghostty_app_tick(runtime->app);
}

uint32_t agt_bridge_runtime_diagnostic_count(void* opaque) {
    struct AGTBridgeRuntime* runtime = (struct AGTBridgeRuntime*)opaque;
    return runtime == NULL ? 0 : runtime->diagnostic_count;
}

char* agt_bridge_runtime_diagnostic(void* opaque, uint32_t index) {
    struct AGTBridgeRuntime* runtime = (struct AGTBridgeRuntime*)opaque;
    if (runtime == NULL || index >= runtime->diagnostic_count) {
        return NULL;
    }
    return agt_strdup(runtime->diagnostics[index]);
}

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------

struct AGTBridgeSurface {
    ghostty_surface_t surface;
    /// Consumer pointer echoed through AGTEvent.surface_context.
    void* userdata;
    /// Owned copies of config strings: libghostty may borrow them beyond the
    /// create call (the spike pinned NSStrings for the same reason).
    char* working_directory;
    char* command;
    char* initial_input;
    AGTEnvVar* env_vars;
    size_t env_var_count;
};

AGTStatusCode agt_bridge_surface_create(void* opaque_runtime,
                                        const AGTSurfaceConfig* config,
                                        void** out_surface) {
    struct AGTBridgeRuntime* runtime = (struct AGTBridgeRuntime*)opaque_runtime;
    if (runtime == NULL || config == NULL || out_surface == NULL ||
        config->nsview == NULL) {
        return AGTStatusInvalidArgument;
    }

    struct AGTBridgeSurface* handle = calloc(1, sizeof(*handle));
    if (handle == NULL) {
        return AGTStatusInternal;
    }
    handle->userdata = config->userdata;
    handle->working_directory = agt_strdup(config->working_directory);
    handle->command = agt_strdup(config->command);
    handle->initial_input = agt_strdup(config->initial_input);
    if (config->env_var_count > 0 && config->env_vars != NULL) {
        handle->env_vars = calloc(config->env_var_count, sizeof(AGTEnvVar));
        if (handle->env_vars == NULL) {
            agt_bridge_surface_free(handle);
            return AGTStatusInternal;
        }
        handle->env_var_count = config->env_var_count;
        for (size_t i = 0; i < config->env_var_count; i++) {
            handle->env_vars[i].key = agt_strdup(config->env_vars[i].key);
            handle->env_vars[i].value = agt_strdup(config->env_vars[i].value);
        }
    }

    ghostty_surface_config_s native = ghostty_surface_config_new();
    native.platform_tag = GHOSTTY_PLATFORM_MACOS;
    native.platform.macos.nsview = config->nsview;
    native.userdata = config->userdata;
    native.scale_factor = config->scale_factor;
    native.font_size = config->font_size;
    native.working_directory = handle->working_directory;
    native.command = handle->command;
    native.env_vars = (ghostty_env_var_s*)handle->env_vars;
    native.env_var_count = handle->env_var_count;
    native.initial_input = handle->initial_input;
    native.wait_after_command = config->wait_after_command;
    native.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;

    ghostty_surface_t surface = ghostty_surface_new(runtime->app, &native);
    if (surface == NULL) {
        agt_bridge_surface_free(handle);
        return AGTStatusInternal;
    }
    handle->surface = surface;
    pthread_mutex_lock(&g_runtime_mutex);
    agt_surface_registry_add(surface);
    pthread_mutex_unlock(&g_runtime_mutex);
    *out_surface = handle;
    return AGTStatusOK;
}

void agt_bridge_surface_free(void* opaque) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL) {
        return;
    }
    // Unregister under the lock so a trampoline blocked on the mutex observes
    // the removal and bails (agt_action_cb) instead of touching freed memory,
    // then RELEASE before ghostty_surface_free: the free pthread-joins the
    // surface's renderer thread, whose callbacks (agt_wakeup_cb and siblings)
    // acquire this mutex — holding it across the join deadlocks (renderer
    // waits on the mutex, main joins the renderer; sampled 2026-08-25).
    // Runtime-level trampolines only touch g_active_runtime, which outlives
    // surface frees, so they are safe to run concurrently with the join.
    pthread_mutex_lock(&g_runtime_mutex);
    ghostty_surface_t native = surface->surface;
    if (native != NULL) {
        agt_surface_registry_remove(native);
        surface->surface = NULL;
    }
    pthread_mutex_unlock(&g_runtime_mutex);
    if (native != NULL) {
        // Main-thread-only per ADR-0002 teardown policy (enforced by callers).
        // ghostty_surface_free may synchronously re-enter bridge callbacks
        // (e.g. close_surface_cb); they take the lock fresh on this thread —
        // the recursive attr covers any same-thread nesting that remains.
        ghostty_surface_free(native);
    }
    // Struct-owned fields: freed only here on the main thread; trampolines
    // never dereference the AGTBridgeSurface, so no lock is needed.
    free(surface->working_directory);
    free(surface->command);
    free(surface->initial_input);
    for (size_t i = 0; i < surface->env_var_count; i++) {
        free((void*)surface->env_vars[i].key);
        free((void*)surface->env_vars[i].value);
    }
    free(surface->env_vars);
    free(surface);
}

void agt_bridge_surface_set_focus(void* opaque, bool focused) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_set_focus(surface->surface, focused);
    }
}

void agt_bridge_surface_set_occlusion(void* opaque, bool occluded) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_set_occlusion(surface->surface, occluded);
    }
}

void agt_bridge_surface_set_size(void* opaque,
                                 uint32_t width_px,
                                 uint32_t height_px) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_set_size(surface->surface, width_px, height_px);
    }
}

void agt_bridge_surface_set_content_scale(void* opaque, double scale) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_set_content_scale(surface->surface, scale, scale);
    }
}

bool agt_bridge_surface_process_exited(void* opaque) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL || surface->surface == NULL) {
        return true;
    }
    return ghostty_surface_process_exited(surface->surface);
}

uint64_t agt_bridge_surface_foreground_pid(void* opaque) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL || surface->surface == NULL) {
        return 0;
    }
    return ghostty_surface_foreground_pid(surface->surface);
}

void agt_bridge_surface_grid_size(void* opaque,
                                  uint32_t* out_columns,
                                  uint32_t* out_rows) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL || surface->surface == NULL) {
        if (out_columns != NULL) { *out_columns = 0; }
        if (out_rows != NULL) { *out_rows = 0; }
        return;
    }
    ghostty_surface_size_s size = ghostty_surface_size(surface->surface);
    if (out_columns != NULL) { *out_columns = (uint32_t)size.columns; }
    if (out_rows != NULL) { *out_rows = (uint32_t)size.rows; }
}

void agt_bridge_surface_send_text(void* opaque,
                                  const char* text,
                                  size_t length_bytes) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL && text != NULL) {
        ghostty_surface_text(surface->surface, text, (uintptr_t)length_bytes);
    }
}

bool agt_bridge_surface_send_key(void* opaque,
                                 const AGTKeyEvent* key) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL || surface->surface == NULL || key == NULL) {
        return false;
    }
    ghostty_input_key_s native;
    memset(&native, 0, sizeof(native));
    native.action = (ghostty_input_action_e)key->action;
    native.mods = (ghostty_input_mods_e)key->mods;
    native.consumed_mods = (ghostty_input_mods_e)key->consumed_mods;
    native.keycode = key->keycode;
    native.text = key->text;
    native.unshifted_codepoint = key->unshifted_codepoint;
    native.composing = key->composing;
    return ghostty_surface_key(surface->surface, native);
}

void agt_bridge_surface_send_preedit(void* opaque,
                                     const char* text,
                                     size_t length_bytes) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL && text != NULL) {
        ghostty_surface_preedit(surface->surface, text, (uintptr_t)length_bytes);
    }
}

bool agt_bridge_surface_mouse_button(void* opaque,
                                     int32_t state,
                                     int32_t button,
                                     uint32_t mods) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface == NULL || surface->surface == NULL) {
        return false;
    }
    return ghostty_surface_mouse_button(surface->surface,
                                        (ghostty_input_mouse_state_e)state,
                                        (ghostty_input_mouse_button_e)button,
                                        (ghostty_input_mods_e)mods);
}

void agt_bridge_surface_mouse_pos(void* opaque,
                                  double x,
                                  double y,
                                  uint32_t mods) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_mouse_pos(surface->surface, x, y,
                                  (ghostty_input_mods_e)mods);
    }
}

void agt_bridge_surface_mouse_scroll(void* opaque,
                                     double dx,
                                     double dy,
                                     int32_t packed_mods) {
    struct AGTBridgeSurface* surface = (struct AGTBridgeSurface*)opaque;
    if (surface != NULL && surface->surface != NULL) {
        ghostty_surface_mouse_scroll(surface->surface, dx, dy,
                                     (ghostty_input_scroll_mods_t)packed_mods);
    }
}

// -- Screen reading ----------------------------------------------------------

static AGTStatusCode agt_read_region(struct AGTBridgeSurface* surface,
                                     ghostty_point_tag_e tag,
                                     char** out_text,
                                     size_t* out_length) {
    if (surface == NULL || surface->surface == NULL || out_text == NULL ||
        out_length == NULL) {
        return AGTStatusInvalidArgument;
    }
    *out_text = NULL;
    *out_length = 0;

    // Corner coordinates are computed by libghostty from the tag; x/y are
    // ignored for TOP_LEFT/BOTTOM_RIGHT corner coords (spike-proven pattern).
    // VERDICT from ADR-0002: POINT_SCREEN reads the live active screen
    // including scrollback, byte-identical regardless of viewport scroll.
    ghostty_selection_s selection;
    selection.top_left.tag = tag;
    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.top_left.x = 0;
    selection.top_left.y = 0;
    selection.bottom_right.tag = tag;
    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.bottom_right.x = 0;
    selection.bottom_right.y = 0;
    selection.rectangle = false;

    ghostty_text_s text;
    memset(&text, 0, sizeof(text));
    if (!ghostty_surface_read_text(surface->surface, selection, &text) ||
        text.text == NULL) {
        return AGTStatusInternal;
    }

    size_t len = (size_t)text.text_len;
    char* copy = malloc(len + 1);
    if (copy == NULL) {
        ghostty_surface_free_text(surface->surface, &text);
        return AGTStatusInternal;
    }
    memcpy(copy, text.text, len);
    copy[len] = '\0';
    ghostty_surface_free_text(surface->surface, &text);
    *out_text = copy;
    *out_length = len;
    return AGTStatusOK;
}

AGTStatusCode agt_bridge_surface_read_screen(void* opaque,
                                             char** out_text,
                                             size_t* out_length) {
    return agt_read_region((struct AGTBridgeSurface*)opaque, GHOSTTY_POINT_SCREEN, out_text, out_length);
}

AGTStatusCode agt_bridge_surface_read_viewport(void* opaque,
                                               char** out_text,
                                               size_t* out_length) {
    return agt_read_region((struct AGTBridgeSurface*)opaque, GHOSTTY_POINT_VIEWPORT, out_text, out_length);
}
