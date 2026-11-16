# Porting swoosh to another platform

Only capture is Wayland-specific. The renderer needs nothing but a take, `raw.mp4` plus `cursor.jsonl` (format at the top of `scripts/demo_driver.py`), so a new platform only has to produce those.

In `Session`, everything is platform-neutral except six operations: start a display at a given size and scale, move the pointer, press and release a button, type text and named keys, and start and stop recording with the cursor left out of the capture. Possible backends, when one is needed:

- Browser only, any OS: headless Chrome, with input and frames over the DevTools protocol. No display needed, and the renderer draws the cursor anyway.
- X11: Xvfb, XTEST, `ffmpeg -f x11grab -draw_mouse 0`.
- macOS: the real screen via `ffmpeg -f avfoundation -capture_cursor 0`, with CGEvent input. Needs the screen-recording permission.
- Windows: `ffmpeg -f gdigrab -draw_mouse 0`, with `SendInput`.

The renderer reads its cursor sprites from the Adwaita theme and its font through `fc-match`; bundle those two when leaving Linux.
