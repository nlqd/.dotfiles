// Long-lived virtual pointer for a wlroots compositor.
// Reads commands from stdin, one per line:
//   move X Y      absolute position in layout pixels
//   down | up     left button
// Usage: vpointer WIDTH HEIGHT   (layout extent used for absolute motion)
// The device exists for as long as this process runs, which gives the seat
// pointer capability so clients bind wl_pointer and see the cursor.
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;

static void on_global(void *data, struct wl_registry *registry, uint32_t name,
                      const char *interface, uint32_t version) {
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(registry, name,
                               &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void on_global_remove(void *data, struct wl_registry *r, uint32_t n) {}

static const struct wl_registry_listener registry_listener = {
    .global = on_global, .global_remove = on_global_remove};

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: vpointer WIDTH HEIGHT\n");
    return 2;
  }
  uint32_t width = atoi(argv[1]), height = atoi(argv[2]);

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "vpointer: cannot connect to WAYLAND_DISPLAY\n");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) {
    fprintf(stderr, "vpointer: compositor lacks zwlr_virtual_pointer_manager_v1\n");
    return 1;
  }
  struct zwlr_virtual_pointer_v1 *pointer =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
  wl_display_roundtrip(display);

  char line[128];
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready\n");
  while (fgets(line, sizeof line, stdin)) {
    double x, y;
    if (sscanf(line, "move %lf %lf", &x, &y) == 2) {
      zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), (uint32_t)x,
                                              (uint32_t)y, width, height);
    } else if (strncmp(line, "down", 4) == 0) {
      zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT,
                                     WL_POINTER_BUTTON_STATE_PRESSED);
    } else if (strncmp(line, "up", 2) == 0) {
      zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT,
                                     WL_POINTER_BUTTON_STATE_RELEASED);
    } else {
      fprintf(stderr, "vpointer: bad command: %s", line);
      continue;
    }
    zwlr_virtual_pointer_v1_frame(pointer);
    if (wl_display_roundtrip(display) < 0) {
      fprintf(stderr, "vpointer: compositor connection lost\n");
      return 1;
    }
  }
  zwlr_virtual_pointer_v1_destroy(pointer);
  wl_display_roundtrip(display);
  return 0;
}
