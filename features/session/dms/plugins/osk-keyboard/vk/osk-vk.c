/*
 * osk-vk: one persistent Wayland virtual keyboard for the on-screen keyboard
 * (features/dms/plugins/osk-keyboard). Reads commands on stdin, one per line:
 *
 *   d <evdev keycode>   press      u <evdev keycode>   release
 *   x                   release every pressed key
 *
 * Why not wtype: wtype creates a fresh virtual keyboard with its own keymap per
 * invocation. Hyprland hands each new keymap to the input method, and a burst of
 * them hung fcitx5 outright (measured 2026-10-08: 50 single-key wtype runs, fcitx
 * stopped answering D-Bus, no key arrived). This keeps ONE keyboard with the
 * standard US keymap for its whole life: fcitx sees one stable keymap, keycodes
 * mean what they mean on the physical keyboard (Hyprland resolves binds through
 * the US translation keymap, so Super+... binds match as from hardware), and keys
 * can be held -- clients repeat them like real keys.
 *
 * Modifier state is tracked with xkbcommon and sent with every change, as the
 * virtual-keyboard protocol leaves that to the client (wtype does the same).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static struct zwp_virtual_keyboard_v1 *kbd;
static struct xkb_state *state;
static unsigned char pressed[256];

static void global_add(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version)
{
	(void)data;
	if (!strcmp(iface, wl_seat_interface.name) && !seat)
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
		manager = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	(void)version;
}
static void global_remove(void *data, struct wl_registry *reg, uint32_t name) { (void)data; (void)reg; (void)name; }
static const struct wl_registry_listener reg_listener = { global_add, global_remove };

static uint32_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void send_mods(void)
{
	zwp_virtual_keyboard_v1_modifiers(kbd,
		xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
		xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
		xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
		xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
}

static void key(unsigned code, int down)
{
	if (code >= 256 || pressed[code] == down)
		return;
	pressed[code] = down;
	zwp_virtual_keyboard_v1_key(kbd, now_ms(), code,
		down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
	/* xkb keycodes are evdev + 8 */
	enum xkb_state_component changed = xkb_state_update_key(state, code + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
	if (changed)
		send_mods();
}

static void release_all(void)
{
	for (unsigned c = 0; c < 256; c++)
		if (pressed[c])
			key(c, 0);
}

int main(void)
{
	struct wl_display *dpy = wl_display_connect(NULL);
	if (!dpy) {
		fprintf(stderr, "osk-vk: cannot connect to the Wayland display\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!seat || !manager) {
		fprintf(stderr, "osk-vk: compositor lacks wl_seat or zwp_virtual_keyboard_manager_v1\n");
		return 1;
	}
	kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);

	/* the standard US keymap, the same one the physical keyboard uses */
	struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_rule_names names = { .rules = NULL, .model = NULL, .layout = "us", .variant = NULL, .options = NULL };
	struct xkb_keymap *keymap = ctx ? xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
	if (!keymap) {
		fprintf(stderr, "osk-vk: cannot compile the US keymap (XKB_CONFIG_ROOT?)\n");
		return 1;
	}
	state = xkb_state_new(keymap);
	char *str = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
	size_t len = strlen(str) + 1;
	int fd = memfd_create("osk-vk-keymap", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, (off_t)len) < 0) {
		perror("osk-vk: keymap memfd");
		return 1;
	}
	void *map = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		perror("osk-vk: mmap");
		return 1;
	}
	memcpy(map, str, len);
	munmap(map, len);
	free(str);
	zwp_virtual_keyboard_v1_keymap(kbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len);
	close(fd);
	wl_display_roundtrip(dpy);

	/* line-buffered commands; Wayland events are only drained so the socket never fills */
	char line[64];
	struct pollfd fds[2] = { { STDIN_FILENO, POLLIN, 0 }, { wl_display_get_fd(dpy), POLLIN, 0 } };
	setvbuf(stdin, NULL, _IOLBF, 0);
	for (;;) {
		wl_display_flush(dpy);
		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (fds[1].revents & POLLIN) {
			if (wl_display_dispatch(dpy) < 0)
				break;
		}
		if (fds[0].revents & (POLLIN | POLLHUP)) {
			if (!fgets(line, sizeof line, stdin))
				break; /* stdin closed: the keyboard went away */
			unsigned code;
			if (line[0] == 'd' && sscanf(line + 1, "%u", &code) == 1)
				key(code, 1);
			else if (line[0] == 'u' && sscanf(line + 1, "%u", &code) == 1)
				key(code, 0);
			else if (line[0] == 'x')
				release_all();
			/* anything else is ignored */
		}
	}
	release_all();
	wl_display_flush(dpy);
	return 0;
}
