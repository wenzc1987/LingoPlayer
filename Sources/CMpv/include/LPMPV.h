#ifndef LPMPV_H
#define LPMPV_H
#include <stddef.h>
#include <stdint.h>
typedef struct LPPlayer LPPlayer;
typedef struct LPRenderer LPRenderer;
typedef void (*LPUpdateCallback)(void *);
LPPlayer *lp_create(const char *path, char *error, size_t error_size);
void lp_destroy(LPPlayer *player);
int lp_command(LPPlayer *player, const char *const *args);
int lp_set_string(LPPlayer *player, const char *key, const char *value);
double lp_get_double(LPPlayer *player, const char *key, double fallback);
char *lp_get_string(LPPlayer *player, const char *key);
void lp_free_string(LPPlayer *player, char *string);
int lp_poll_event(LPPlayer *player, int *error);
const char *lp_error(LPPlayer *player, int code);
LPRenderer *lp_render_create(LPPlayer *player, LPUpdateCallback callback, void *context, int *error);
void lp_render_draw(LPRenderer *renderer, int width, int height);
void lp_render_free(LPRenderer *renderer);
#endif
