/*
 * AgentGhosttyBridge — stable, narrow C ABI owned by AgentTerminal.
 *
 * This is OUR contract: it deliberately does NOT include ghostty.h so that no
 * target outside TerminalKit ever transitively sees libghostty types
 * (architecture notes §2.3, §3.2, ADR-0002). Every libghostty union, tagged
 * enum, and callback payload is translated here into plain owned structs:
 * strings handed across this boundary are always malloc'd copies, never
 * Zig-internal pointers. Event-payload strings are valid ONLY inside the
 * callback that receives them; the bridge frees them after the consumer
 * callback returns (the consumer converts to its own value types in-callback).
 * Strings returned by read/diagnostic entry points transfer ownership and are
 * released with agt_bridge_string_free.
 *
 * Threading rules (architecture §3.18):
 *   - Callbacks may fire on any thread. The consumer must copy/convert the
 *     AGTEvent synchronously inside the callback, then hop to the main actor.
 *   - Surface create/free are main-thread-only operations (ADR-0002 teardown
 *     policy); everything else is thread-tolerant but the consumer funnels
 *     commands through the main actor.
 *
 * Lifecycle rules (validated by Spike/RESULTS.md + ADR-0002):
 *   - agt_bridge_global_init() MUST run once before any other call
 *     (ghostty_init global-bootstrap requirement).
 *   - Runtime callbacks are cloned at app creation; the callbacks struct is
 *     copied inside agt_bridge_runtime_create before ghostty_app_new.
 *   - One runtime per process is supported (GhosttyEngine is a @MainActor
 *     singleton per architecture §3.8).
 */
#ifndef AGENT_GHOSTTY_BRIDGE_H
#define AGENT_GHOSTTY_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles. The runtime handle backs a libghostty app + config pair,
// the surface handle a libghostty surface. They are deliberately plain
// `void*` at this boundary: forward-declared C structs do not import into
// Swift, and no consumer code may ever dereference them.

/// Stable result codes across the bridge boundary.
typedef enum {
    AGTStatusOK = 0,
    AGTStatusNotInitialized = 1,
    AGTStatusInvalidArgument = 2,
    AGTStatusInternal = 3
} AGTStatusCode;

/// ABI version of this bridge. Bumped only on breaking changes to this header.
uint32_t agt_bridge_abi_version(void);

/// Process-global libghostty bootstrap (ghostty_init). Idempotent; MUST be
/// called once before any other bridge entry point. Returns AGTStatusOK when
/// the library is initialized (by this or a previous call).
AGTStatusCode agt_bridge_global_init(void);

// ---------------------------------------------------------------------------
// Enums mirrored from libghostty (values kept in sync with ghostty.h).
// ---------------------------------------------------------------------------

/// Mirrors ghostty_input_mods_e bit values.
enum {
    AGTModsNone        = 0,
    AGTModsShift       = 1 << 0,
    AGTModsCtrl        = 1 << 1,
    AGTModsAlt         = 1 << 2,
    AGTModsSuper       = 1 << 3,
    AGTModsCaps        = 1 << 4,
    AGTModsNum         = 1 << 5,
};

/// Mirrors ghostty_input_action_e.
typedef enum {
    AGTKeyActionRelease = 0,
    AGTKeyActionPress = 1,
    AGTKeyActionRepeat = 2,
} AGTKeyAction;

/// Mirrors ghostty_input_mouse_state_e.
typedef enum {
    AGTMouseRelease = 0,
    AGTMousePress = 1,
} AGTMouseState;

/// Mirrors ghostty_input_mouse_button_e.
typedef enum {
    AGTMouseUnknown = 0,
    AGTMouseLeft = 1,
    AGTMouseRight = 2,
    AGTMouseMiddle = 3,
    AGTMouseFour = 4,
    AGTMouseFive = 5,
} AGTMouseButton;

/// Mirrors ghostty_clipboard_e.
typedef enum {
    AGTClipboardStandard = 0,
    AGTClipboardSelection = 1,
} AGTClipboardKind;

/// Mirrors ghostty_clipboard_request_e.
typedef enum {
    AGTClipboardRequestPaste = 0,
    AGTClipboardRequestOsc52Read = 1,
    AGTClipboardRequestOsc52Write = 2,
} AGTClipboardRequest;

/// Mirrors ghostty_action_progress_report_state_e.
typedef enum {
    AGTProgressRemove = 0,
    AGTProgressSet = 1,
    AGTProgressError = 2,
    AGTProgressIndeterminate = 3,
    AGTProgressPause = 4,
} AGTProgressState;

/// Mirrors ghostty_action_open_url_kind_e.
typedef enum {
    AGTOpenURLUnknown = 0,
    AGTOpenURLText = 1,
    AGTOpenURLHTML = 2,
    AGTOpenURLOsc8 = 3,
} AGTOpenURLKind;

// ---------------------------------------------------------------------------
// Events: the translated form of every action_cb / close_surface_cb payload.
// ---------------------------------------------------------------------------

typedef enum {
    AGTEventRender = 0,
    AGTEventTitle = 1,
    AGTEventPwd = 2,
    AGTEventChildExited = 3,
    AGTEventCommandFinished = 4,
    AGTEventProgress = 5,
    AGTEventBell = 6,
    AGTEventSelectionChanged = 7,
    AGTEventNotification = 8,
    AGTEventOpenURL = 9,
    AGTEventMouseShape = 10,
    AGTEventCloseWindow = 11,
} AGTEventKind;

/// Plain-data event translated from a libghostty action. String fields
/// (`title`, `body`, `pwd`, `url`) are borrowed: they are valid only for the
/// duration of the event callback invocation — the bridge frees them as soon
/// as the callback returns. The consumer MUST convert them into owned values
/// synchronously. NULL means "no payload for this kind".
typedef struct AGTEvent {
    AGTEventKind kind;
    /// Consumer userdata pointer handed to agt_bridge_surface_create for
    /// surface-targeted events; NULL for app-targeted events.
    void* surface_context;
    uint32_t exit_code;          ///< AGTEventChildExited (0-255).
    int16_t command_exit_code;   ///< AGTEventCommandFinished (-1 = unknown).
    uint64_t duration_ns;        ///< AGTEventCommandFinished.
    int8_t progress_percent;     ///< AGTEventProgress (-1 = none).
    int32_t progress_state;      ///< AGTEventProgress (AGTProgressState).
    int32_t mouse_shape;         ///< AGTEventMouseShape (raw ghostty value).
    int32_t url_kind;            ///< AGTEventOpenURL (AGTOpenURLKind).
    char* title;                 ///< Title / notification title.
    char* body;                  ///< Notification body.
    char* pwd;                   ///< Working directory report.
    char* url;                   ///< OpenURL target.
} AGTEvent;

/// Releases a string owned by the consumer (read_screen/read_viewport/
/// diagnostic results).
void agt_bridge_string_free(char* string);

// ---------------------------------------------------------------------------
// Runtime (app-level) lifecycle
// ---------------------------------------------------------------------------

/// Key/value pair for the surface environment.
typedef struct AGTEnvVar {
    const char* key;
    const char* value;
} AGTEnvVar;

/// Key press/release description. `text` is borrowed ONLY for the duration of
/// the call that receives this struct (libghostty encodes it synchronously).
typedef struct AGTKeyEvent {
    int32_t action;               ///< AGTKeyAction.
    uint32_t mods;                ///< AGTMods* bits.
    uint32_t consumed_mods;       ///< AGTMods* bits.
    uint32_t keycode;             ///< Platform (macOS virtual) keycode.
    const char* text;             ///< UTF-8 text to encode; NULL allowed.
    uint32_t unshifted_codepoint;
    bool composing;
} AGTKeyEvent;

typedef void (*AGTWakeupCallback)(void* userdata);
typedef void (*AGTEventCallback)(const AGTEvent* event, void* userdata);
typedef void (*AGTCloseSurfaceCallback)(bool process_alive, void* userdata);
typedef bool (*AGTReadClipboardCallback)(int32_t clipboard_kind, void* userdata);
typedef void (*AGTConfirmReadClipboardCallback)(const char* prompt,
                                                int32_t request_kind,
                                                void* userdata);
typedef void (*AGTWriteClipboardCallback)(int32_t clipboard_kind,
                                          const char* mime,
                                          const char* data,
                                          void* userdata);

/// Callback set installed with the runtime. Copied by the bridge before the
/// underlying app exists, so callers may release their copy afterwards.
typedef struct AGTRuntimeCallbacks {
    void* userdata;                    /// Echoed back to every callback.
    AGTWakeupCallback wakeup;          /// May be NULL.
    AGTEventCallback event;            /// Required.
    AGTCloseSurfaceCallback close_surface; /// May be NULL.
    AGTReadClipboardCallback read_clipboard;           /// NULL = deny reads.
    AGTConfirmReadClipboardCallback confirm_read_clipboard; ///< NULL = ignore.
    AGTWriteClipboardCallback write_clipboard;         /// NULL = drop writes.
} AGTRuntimeCallbacks;

/// Creates the app runtime. `config_path` may be NULL (pure defaults); when
/// present, diagnostics of an unloadable file are reported through
/// AGTStatusInternal-free semantics: the file load failure is non-fatal and
/// surfaced via agt_bridge_runtime_diagnostic_count/get.
AGTStatusCode agt_bridge_runtime_create(const char* config_path,
                                        const AGTRuntimeCallbacks* callbacks,
                                        void** out_runtime);

/// Frees the runtime. All surfaces created from it MUST already be freed.
/// After return, no further callbacks are delivered for this runtime.
void agt_bridge_runtime_free(void* runtime);

/// Drives the libghostty event loop; call repeatedly from the main loop.
void agt_bridge_runtime_tick(void* runtime);

uint32_t agt_bridge_runtime_diagnostic_count(void* runtime);
/// Returns a malloc'd diagnostic message; consumer frees via
/// agt_bridge_string_free. NULL when index is out of range.
char* agt_bridge_runtime_diagnostic(void* runtime, uint32_t index);

// ---------------------------------------------------------------------------
// Surface lifecycle
// ---------------------------------------------------------------------------

typedef struct AGTSurfaceConfig {
    /// NSView pointer (macOS platform handoff). Required.
    void* nsview;
    /// Working directory for the child; NULL = inherit.
    const char* working_directory;
    /// Exact argv string word-split and exec'd WITHOUT shell interpolation;
    /// NULL = user default shell.
    const char* command;
    const AGTEnvVar* env_vars;
    size_t env_var_count;
    /// Input written to the child right after start; NULL = none.
    const char* initial_input;
    double scale_factor;
    float font_size;              ///< 0 = config default.
    bool wait_after_command;
    /// Opaque consumer pointer echoed in AGTEvent.surface_context. Must stay
    /// valid until agt_bridge_surface_free returns (two-phase teardown).
    void* userdata;
} AGTSurfaceConfig;

/// Creates a surface. Main thread only (ADR-0002). The bridge copies all
/// strings in the config into storage that lives as long as the surface.
AGTStatusCode agt_bridge_surface_create(void* runtime,
                                        const AGTSurfaceConfig* config,
                                        void** out_surface);

/// Native free. Main thread only. After it returns, no callbacks referencing
/// this surface's userdata can fire anymore (two-phase teardown phase 2).
void agt_bridge_surface_free(void* surface);

void agt_bridge_surface_set_focus(void* surface, bool focused);
void agt_bridge_surface_set_occlusion(void* surface, bool occluded);
void agt_bridge_surface_set_size(void* surface,
                                 uint32_t width_px,
                                 uint32_t height_px);
void agt_bridge_surface_set_content_scale(void* surface, double scale);

/// Poll-based child-exit evidence (PRIMARY lifecycle signal; ADR-0002 finding
/// 5: SHOW_CHILD_EXITED delivery is unreliable under many live surfaces).
bool agt_bridge_surface_process_exited(void* surface);

/// PID of the current foreground child process; 0 when unknown/exited.
uint64_t agt_bridge_surface_foreground_pid(void* surface);

/// Grid geometry in cells; either out param may be NULL.
void agt_bridge_surface_grid_size(void* surface,
                                  uint32_t* out_columns,
                                  uint32_t* out_rows);

// -- Input ------------------------------------------------------------------

/// IME-style text commit (safe for arbitrary Unicode including newlines).
void agt_bridge_surface_send_text(void* surface,
                                  const char* text,
                                  size_t length_bytes);
bool agt_bridge_surface_send_key(void* surface,
                                 const AGTKeyEvent* key);
void agt_bridge_surface_send_preedit(void* surface,
                                     const char* text,
                                     size_t length_bytes);
bool agt_bridge_surface_mouse_button(void* surface,
                                     int32_t state,
                                     int32_t button,
                                     uint32_t mods);
void agt_bridge_surface_mouse_pos(void* surface,
                                  double x,
                                  double y,
                                  uint32_t mods);
void agt_bridge_surface_mouse_scroll(void* surface,
                                     double dx,
                                     double dy,
                                     int32_t packed_mods);

// -- Screen reading ----------------------------------------------------------
//
// VERDICT from ADR-0002: GHOSTTY_POINT_SCREEN corners read the live active
// screen INCLUDING scrollback and are byte-identical regardless of viewport
// scroll position. This is the detection-grade read. Viewport read reflects
// what the user currently sees.

/// Reads the full live screen (scroll-independent) into a fresh malloc'd
/// buffer (NUL-terminated; `out_length` excludes the terminator). Consumer
/// frees via agt_bridge_string_free.
AGTStatusCode agt_bridge_surface_read_screen(void* surface,
                                             char** out_text,
                                             size_t* out_length);

/// Same, for the visible viewport.
AGTStatusCode agt_bridge_surface_read_viewport(void* surface,
                                               char** out_text,
                                               size_t* out_length);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_GHOSTTY_BRIDGE_H */
