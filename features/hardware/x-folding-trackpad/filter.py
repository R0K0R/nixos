#!/usr/bin/env python3
"""
Natural scrolling for the X-Folding RGB trackpad that leaves pinch-zoom alone.

The firmware does not report touches. It turns a two-finger swipe into mouse
wheel events and a pinch into Ctrl + wheel (captured with libinput: no
GESTURE_PINCH at all, 23 LEFTCTRL press/release pairs each wrapping a burst of
wheel events). So a compositor-side natural_scroll inverts both, and zoom runs
backwards.

This sits in front of the device, inverts the wheel for scrolling, and passes
it through unchanged while the firmware's Ctrl is held -- i.e. for a pinch.
The first wheel events of a pinch can arrive just BEFORE its Ctrl press, so a
burst that starts without Ctrl is held back briefly: if Ctrl follows inside
the window, the held events were a pinch and go out unchanged after it;
otherwise they were a scroll and go out inverted. Only the start of a burst
waits; the rest of a scroll passes straight through.

The decision logic (Classifier) is pure and knows nothing about evdev, so it
can be tested against recorded sequences; main() does the device plumbing.
"""
import os
import select
import sys
import time

# linux/input-event-codes.h -- inlined so Classifier needs no evdev import.
EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 0x06, 0x08, 0x0B, 0x0C
KEY_LEFTCTRL = 29

WHEEL = {REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES}

HOLD = float(os.environ.get("XFOLD_HOLD", "0.025"))  # s to wait for a pinch's Ctrl
BURST_GAP = float(os.environ.get("XFOLD_BURST_GAP", "0.15"))  # s of quiet that ends a burst


def has_wheel(frame):
    return any(t == EV_REL and c in WHEEL for t, c, _ in frame)


def ctrl_change(frame):
    """1 = Ctrl pressed, 0 = released, None = no Ctrl edge in this frame."""
    for t, c, v in frame:
        if t == EV_KEY and c == KEY_LEFTCTRL and v in (0, 1):
            return v
    return None


def inverted(frame):
    return [(t, c, -v if (t == EV_REL and c in WHEEL) else v) for t, c, v in frame]


class Classifier:
    """Frames in, frames out. A frame is a list of (type, code, value) up to SYN_REPORT."""

    def __init__(self, hold=HOLD, burst_gap=BURST_GAP):
        self.hold, self.burst_gap = hold, burst_gap
        self.ctrl = False
        self.pending = []  # wheel frames held while deciding
        self.pending_since = None
        self.scrolling_until = 0.0  # inside a burst already classified as scroll

    def deadline(self):
        return None if not self.pending else self.pending_since + self.hold

    def feed(self, frame, now):
        out = []
        edge = ctrl_change(frame)
        if edge == 1:
            self.ctrl = True
            self.scrolling_until = 0.0
            out.append(frame)
            # Held wheel events were the start of this pinch: release them
            # after Ctrl, unchanged, so the app sees them as zoom.
            out.extend(self.pending)
            self._clear()
            return out
        if edge == 0:
            self.ctrl = False
            out.extend(self.flush_scroll(now))  # anything still held was scroll
            out.append(frame)
            return out
        if not has_wheel(frame):
            out.append(frame)
            return out
        if self.ctrl:
            out.append(frame)  # pinch in progress: zoom as sent
        elif now < self.scrolling_until:
            out.append(inverted(frame))  # mid-scroll: no need to wait again
            self.scrolling_until = now + self.burst_gap
        else:
            if not self.pending:
                self.pending_since = now
            self.pending.append(frame)
        return out

    def tick(self, now):
        """Call when deadline() passes: nothing claimed the held frames, so they were a scroll."""
        if self.pending and now >= self.pending_since + self.hold:
            return self.flush_scroll(now)
        return []

    def flush_scroll(self, now):
        if not self.pending:
            return []
        out = [inverted(f) for f in self.pending]
        self._clear()
        self.scrolling_until = now + self.burst_gap
        return out

    def _clear(self):
        self.pending, self.pending_since = [], None


def main(path):
    import evdev  # only the plumbing needs it

    dev = evdev.InputDevice(path)
    dev.grab()  # exclusive: libinput and keyd must see only our copy
    ui = evdev.UInput.from_device(
        dev,
        name=dev.name + " (filtered)",
        # A different product id from the raw 04e8:7021, which keyd is told to
        # skip -- so keyd grabs THIS device and its remaps still apply.
        vendor=0x04E8,
        product=0xF021,
        version=dev.info.version,
        bustype=dev.info.bustype,
    )
    clf = Classifier()
    frame = []

    def emit(frames):
        for f in frames:
            for t, c, v in f:
                ui.write(t, c, v)
            ui.syn()

    try:
        while True:
            dl = clf.deadline()
            timeout = None if dl is None else max(0.0, dl - time.monotonic())
            r, _, _ = select.select([dev.fd], [], [], timeout)
            if not r:
                emit(clf.tick(time.monotonic()))
                continue
            for ev in dev.read():
                if ev.type == EV_SYN:
                    if ev.code == SYN_REPORT and frame:
                        emit(clf.feed(frame, time.monotonic()))
                        frame = []
                    continue
                frame.append((ev.type, ev.code, ev.value))
    except OSError:
        # Device went away (Bluetooth disconnect). systemd stops this instance
        # with the device anyway; exit cleanly rather than traceback.
        pass
    finally:
        try:
            ui.close()
        except Exception:
            pass


if __name__ == "__main__":
    main(sys.argv[1])
