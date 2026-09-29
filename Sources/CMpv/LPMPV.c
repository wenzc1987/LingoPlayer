#include "LPMPV.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// Minimal stable libmpv ABI declarations. libmpv is loaded at runtime so the
// app and its core tests can still run when the media runtime is not installed.
typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct { int type; void *data; } render_param;
typedef struct { void *(*get_proc_address)(void *, const char *); void *ctx; } gl_init;
typedef struct { int fbo, w, h, internal_format; } gl_fbo;
typedef struct { int id, error; uint64_t userdata; void *data; } mpv_event;
struct LPPlayer {
    void *library;
    mpv_handle *handle;
    mpv_handle *(*create)(void);
    int (*initialize)(mpv_handle *);
    void (*terminate_destroy)(mpv_handle *);
    int (*set_option_string)(mpv_handle *, const char *, const char *);
    int (*set_property_string)(mpv_handle *, const char *, const char *);
    int (*get_property)(mpv_handle *, const char *, int, void *);
    char *(*get_property_string)(mpv_handle *, const char *);
    int (*command)(mpv_handle *, const char *const *);
    void (*free)(void *);
    mpv_event *(*wait_event)(mpv_handle *, double);
    int (*observe_property)(mpv_handle *, uint64_t, const char *, int);
    const char *(*error_string)(int);
    int (*render_create)(mpv_render_context **, mpv_handle *, render_param *);
    void (*render_callback)(mpv_render_context *, LPUpdateCallback, void *);
    int (*render)(mpv_render_context *, render_param *);
    void (*render_free)(mpv_render_context *);
};
struct LPRenderer { LPPlayer *player; mpv_render_context *context; };

LPPlayer *lp_create(const char *path, char *error, size_t error_size) {
    LPPlayer *p = calloc(1, sizeof(*p));
    const char *paths[] = { path, "/opt/homebrew/lib/libmpv.dylib", "/usr/local/lib/libmpv.dylib", "libmpv.dylib", NULL };
    for (int i = 0; i < 4; ++i) {
        if (paths[i] && paths[i][0]) p->library = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (p->library) break;
    }
    if (!p->library) { snprintf(error, error_size, "libmpv 未就绪。请运行 scripts/setup-runtime.sh，或在设置中指定 libmpv 路径。"); free(p); return NULL; }
#define LOAD(field, name) do { *(void **)(&p->field) = dlsym(p->library, name); if (!p->field) { snprintf(error, error_size, "libmpv 缺少 %s", name); dlclose(p->library); free(p); return NULL; } } while (0)
    LOAD(create, "mpv_create"); LOAD(initialize, "mpv_initialize"); LOAD(terminate_destroy, "mpv_terminate_destroy");
    LOAD(set_option_string, "mpv_set_option_string"); LOAD(set_property_string, "mpv_set_property_string");
    LOAD(get_property, "mpv_get_property"); LOAD(get_property_string, "mpv_get_property_string");
    LOAD(command, "mpv_command"); LOAD(free, "mpv_free"); LOAD(wait_event, "mpv_wait_event"); LOAD(error_string, "mpv_error_string");
    LOAD(observe_property, "mpv_observe_property");
    LOAD(render_create, "mpv_render_context_create"); LOAD(render_callback, "mpv_render_context_set_update_callback");
    LOAD(render, "mpv_render_context_render"); LOAD(render_free, "mpv_render_context_free");
#undef LOAD
    p->handle = p->create();
    if (!p->handle) { snprintf(error, error_size, "无法创建播放内核。"); dlclose(p->library); free(p); return NULL; }
    const char *options[][2] = { {"config", "no"}, {"terminal", "no"}, {"vo", "libmpv"}, {"hwdec", "auto-safe"}, {"idle", "yes"}, {"keep-open", "yes"}, {"sub-auto", "no"}, {"sid", "no"}, {"input-default-bindings", "no"}, {"osd-level", "0"}, {"audio-client-name", "LingoPlayer"} };
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i) p->set_option_string(p->handle, options[i][0], options[i][1]);
    // Let libmpv deliver frames at their display time instead of holding the GL
    // context in an early-render wait. Geometry redraws can then use the same
    // renderer while dragging, retaining mpv's normal audio/video timing.
    // https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h
    p->set_option_string(p->handle, "video-timing-offset", "0");
    int result = p->initialize(p->handle);
    if (result < 0) { snprintf(error, error_size, "%s", p->error_string(result)); lp_destroy(p); return NULL; }
    // Metadata is read only after a change notification. Keep the playback
    // clock on its own 30 Hz path; observing it here would invalidate this cache.
    const char *properties[] = { "path", "duration", "pause", "eof-reached", "seeking", "dwidth", "dheight", "video-out-params/rotate" };
    const int formats[] = { 1, 5, 3, 3, 3, 5, 5, 5 }; // STRING, DOUBLE, FLAG
    for (unsigned i = 0; i < sizeof(properties) / sizeof(properties[0]); ++i) {
        // Typed observation suppresses low-level events with unchanged values.
        result = p->observe_property(p->handle, i + 1, properties[i], formats[i]);
        if (result < 0) { snprintf(error, error_size, "%s", p->error_string(result)); lp_destroy(p); return NULL; }
    }
    return p;
}
void lp_destroy(LPPlayer *p) { if (!p) return; if (p->handle) p->terminate_destroy(p->handle); if (p->library) dlclose(p->library); free(p); }
int lp_command(LPPlayer *p, const char *const *args) { return p->command(p->handle, args); }
int lp_set_string(LPPlayer *p, const char *key, const char *value) { return p->set_property_string(p->handle, key, value); }
double lp_get_double(LPPlayer *p, const char *key, double fallback) { double value; return p->get_property(p->handle, key, 5, &value) >= 0 ? value : fallback; }
char *lp_get_string(LPPlayer *p, const char *key) { return p->get_property_string(p->handle, key); }
void lp_free_string(LPPlayer *p, char *string) { if (string) p->free(string); }
int lp_poll_event(LPPlayer *p, int *error, int64_t *entry) {
    mpv_event *event = p->wait_event(p->handle, 0); *error = event->error; *entry = -1;
    if (event->id == 6 && event->data) *entry = *(int64_t *)event->data;
    // MPV_EVENT_END_FILE data starts with reason and error. Only expose failures.
    if (event->id == 7 && event->data) { const int *data = event->data; *entry = *(int64_t *)(data + 2); if (data[0] == 4) *error = data[1]; }
    return event->id;
}
const char *lp_error(LPPlayer *p, int code) { return p->error_string(code); }
static void *gl_address(void *unused, const char *name) {
    (void)unused;
    static void *framework = NULL;
    if (!framework) framework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    return framework ? dlsym(framework, name) : NULL;
}
LPRenderer *lp_render_create(LPPlayer *p, LPUpdateCallback callback, void *context, int *error) {
    LPRenderer *renderer = calloc(1, sizeof(*renderer)); renderer->player = p;
    gl_init init = { gl_address, NULL };
    render_param params[] = { {1, "opengl"}, {2, &init}, {0, NULL} };
    *error = p->render_create(&renderer->context, p->handle, params);
    if (*error < 0) { free(renderer); return NULL; }
    p->render_callback(renderer->context, callback, context);
    return renderer;
}
void lp_render_draw(LPRenderer *renderer, int width, int height) {
    gl_fbo fbo = { 0, width, height, 0 }; int flip = 1;
    render_param params[] = { {3, &fbo}, {4, &flip}, {0, NULL} };
    renderer->player->render(renderer->context, params);
}
void lp_render_free(LPRenderer *renderer) {
    if (!renderer) return;
    renderer->player->render_callback(renderer->context, NULL, NULL);
    renderer->player->render_free(renderer->context);
    free(renderer);
}
