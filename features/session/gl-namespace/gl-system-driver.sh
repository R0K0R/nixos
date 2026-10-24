# gl-system-driver COMMAND [ARGS...]
#
# Runs COMMAND with the graphics loaders pointed at the SYSTEM's driver tree
# (/run/gl-driver/system, the same tree everyone outside a mapped namespace
# sees as /run/opengl-driver), whatever this session's /run/opengl-driver is.
#
# For system programs that must not load a mapped user's own driver: the
# fallback session's cage and kitty run when the user's home generation is
# from another epoch, and its driver tree may then have been built against a
# different system. Environment only -- it cannot undo RUNPATH entries, so
# LD_LIBRARY_PATH (searched before RUNPATH) carries the system's lib first.
# Children inherit all of it, which is what the fallback session wants and
# why this is NOT a general compositor wrapper.

d=${GL_SYSTEM_DRIVER:-/run/gl-driver/system}

export LD_LIBRARY_PATH="$d/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export __EGL_VENDOR_LIBRARY_DIRS="$d/share/glvnd/egl_vendor.d"
export LIBGL_DRIVERS_PATH="$d/lib/dri"
export GBM_BACKENDS_PATH="$d/lib/gbm"
export LIBVA_DRIVERS_PATH="$d/lib/dri"
export VK_DRIVER_FILES="$d/share/vulkan/icd.d"
export VK_ICD_FILENAMES="$d/share/vulkan/icd.d"
export OCL_ICD_VENDORS="$d/etc/OpenCL/vendors"

exec "$@"
