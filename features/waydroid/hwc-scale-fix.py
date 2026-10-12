"""
Waydroid's hwcomposer turns a fractional display scale into the next integer
some time into a session, and from then on Android is drawn at 0.75 of its
window (on a 1.5 output) with the black background around it. The fix is a
23-byte patch to the vendor image's hwcomposer.waydroid.so, installed through
the vendor overlay (/var/lib/waydroid/overlay/vendor, mounted over /vendor).

The bug (android_hardware_waydroid, hwcomposer/wayland-hwc.cpp):

    static void output_handle_scale(void *data, struct wl_output *, int32_t scale)
    {
        struct display *d = (struct display*)data;
        d->scale = std::max((int)d->scale, scale);
    }

display->scale is ONE value written by two sources. wp_fractional_scale sets it
to 1.5 while the window is calibrated, and Android's display is sized from that
(1912 x 1.5 = 2868). Every later wl_output.scale -- ceil(1.5) = 2, which a
compositor may re-send on any mode change, a rotation say -- becomes
max((int)1.5, 2) = 2 for the rest of the session: each layer's viewport
destination is then displayFrame / 2, while the background surface stays the
window's size. Surviving a window reopen is the tell -- the value is
session-wide.

The patch replaces that handler with "take wl_output.scale only while
display->scale is still unset (0)": the bind-time value seeds it, the
fractional scale overrides it, and nothing after that can. (Upstream-worthy
form: ignore wl_output.scale once a fractional preferred scale has arrived.
This one, which had to fit the old handler's 32 bytes, differs only on a
compositor WITHOUT fractional scaling and several outputs: the first output's
scale wins, not the largest.)

It is tied to known vendor builds by hash. Any other build is left alone (and a
patched copy from an older build is removed) with a message, rather than
patching bytes at an offset that may now be something else.
"""
import hashlib, os, subprocess, sys, tempfile

IMG = "/var/lib/waydroid/images/vendor.img"
REL = "lib64/hw/hwcomposer.waydroid.so"
OUT = "/var/lib/waydroid/overlay/vendor/" + REL
DEBUGFS = sys.argv[1]

# sha256 of the original hwcomposer.waydroid.so -> (file offset of output_handle_scale,
# sha256 after patching). Same bytes in each build, only the offset moves.
BUILDS = {
    # vendor build 2026-04-28 (MAINLINE, 508512 bytes): vaddr 0x4bda0; .text vaddr 0x3de20
    # is file offset 0x3ce20
    "00934e9739ce5d09c650d8bfc03c0788c986c8bbe37652d4d36abb61b368fded":
        (0x4ada0, "c1efebf68290baf5eb3148879730b8b8fcb4571760586759c1e745780e90c3d4"),
    # vendor build 2026-09-27 (MAINLINE): vaddr 0x4c620; .text vaddr 0x3dfe0 is file offset
    # 0x3cfe0. The first with "Call hotplug on display resize" (upstream 40c54a5e), so
    # Android's display follows the window's size; output_handle_scale is still unfixed.
    "34a0ab934e0fb83ed1f7b290dd52c0a1073e6458c408f1f8463cbfa477005a51":
        (0x4b620, "aff3687cb8e11773ae425ae02a1f1f8af52d0c40b61a513ba0ad3244143f6b51"),
}
PATCHED_ANY = {patched for _, patched in BUILDS.values()}
BEFORE = bytes.fromhex(
    "f20f2c87d8000000"  # cvttsd2si eax,[rdi+0xd8]   ; (int)d->scale
    "39d0"              # cmp eax,edx
    "0f4cc2"            # cmovl eax,edx              ; max(.., scale)
    "f20f2ac0"          # cvtsi2sd xmm0,eax
    "f20f1187d8000000"  # movsd [rdi+0xd8],xmm0      ; d->scale = ..
    "c3" "cccccccccccc"
)
AFTER = bytes.fromhex(
    "4883bfd800000000"  # cmp qword [rdi+0xd8],0     ; d->scale still unset?
    "750c"              # jne ret                    ; no: keep it
    "f20f2ac2"          # cvtsi2sd xmm0,edx
    "f20f1187d8000000"  # movsd [rdi+0xd8],xmm0      ; d->scale = scale
    "c3"
) + b"\xcc" * 9


def sha(b):
    return hashlib.sha256(b).hexdigest()


def remove_ours(why):
    try:
        if sha(open(OUT, "rb").read()) in PATCHED_ANY:
            os.unlink(OUT)
            print(f"hwc-scale-fix: removed the patched hwcomposer: {why}")
    except FileNotFoundError:
        pass


if not os.path.exists(IMG):
    sys.exit(0)  # not initialised yet

with tempfile.TemporaryDirectory() as tmp:
    dumped = os.path.join(tmp, "hwc.so")
    subprocess.run([DEBUGFS, "-R", f"dump /{REL} {dumped}", IMG],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    orig = open(dumped, "rb").read() if os.path.exists(dumped) else b""

if sha(orig) not in BUILDS:
    remove_ours("the vendor image is a different build")
    print("hwc-scale-fix: vendor hwcomposer is not the build this patch was made for "
          f"(sha256 {sha(orig)}); NOT patched -- check whether upstream fixed "
          "output_handle_scale, else redo the patch (features/waydroid/hwc-scale-fix.py)")
    sys.exit(0)

OFF, PATCHED = BUILDS[sha(orig)]
if os.path.exists(OUT) and sha(open(OUT, "rb").read()) == PATCHED:
    sys.exit(0)

data = bytearray(orig)
assert data[OFF:OFF + len(BEFORE)] == BEFORE
data[OFF:OFF + len(AFTER)] = AFTER
assert sha(data) == PATCHED
os.makedirs(os.path.dirname(OUT), mode=0o755, exist_ok=True)
tmp = OUT + ".new"
with open(tmp, "wb") as f:
    f.write(data)
os.chmod(tmp, 0o644)
os.replace(tmp, OUT)
print("hwc-scale-fix: installed the patched hwcomposer in the vendor overlay")
