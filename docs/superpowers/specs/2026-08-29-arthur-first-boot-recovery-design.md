# Arthur First-Boot Recovery Design

## Scope

This design repairs only the rejected candidate's first-boot transaction and the separately observed QuickStart/web-stack runtime defect. It does not modify the failed router, rebuild the rejected artifact, change target/kernel/feed pins, or create a release tag.

## Evidence and root cause

The clean-flash evidence proves that the LAN transaction completed (`192.168.6.1/24`) and that the root-password branch did not abort. The installed `99-xinzhao-defaults` script was removed, yet `/etc/config/xinzhaowrt` and both required markers were absent.

An isolated real-UCI experiment on the failed Arthur showed that `uci -c <empty-dir> -q batch` reports `uci: Entry not found` for the first `set xinzhaowrt.system=system`, returns exit code zero, and creates no package. Removing `-q` exposes the same error. Explicitly creating an empty `xinzhaowrt` package file first lets the identical transaction create and commit the expected sections. Therefore the first failed operation is the marker package set; `-q` masks the failure from `set -eu` and lets uci-defaults exit successfully.

## First-boot transaction

The defaults script becomes an explicit staged transaction. It logs `FIRSTBOOT_START`, records a pass after LAN configuration and root-credential handling, creates `/etc/config/xinzhaowrt` atomically before invoking UCI, applies and verifies both markers, commits the package, and emits `FIRSTBOOT_COMPLETE` only after every check passes.

Any failed required operation emits `FIRSTBOOT_FAIL stage=<stage>` and returns nonzero. That preserves the uci-defaults script for diagnosis instead of creating a false initialized state. Existing initialized systems remain a no-op; existing non-default LAN and non-empty root credentials are preserved.

## Runtime gate

`FIRST_BOOT_RUNTIME_GATE` executes the real shell transaction against disposable configuration and shadow fixtures using the real `uci` executable. It starts with no xinzhaowrt package, asserts the first-run observable state, then reruns against the same fixture to prove idempotence and preservation of a pre-existing LAN/password state. It is a pre-full-build gate; `check-defaults.sh` remains a static contract check and is renamed in output only.

## Web-stack gate

QuickStart is diagnosed separately from the marker issue. The observed `ash` syntax error means its runtime executable is not valid POSIX shell input despite being invoked by `/etc/rc.d/S93startdhns`. The gate will inspect the package's shebang/file type/init invocation and assert Nginx owns management ports while uhttpd is disabled and QuickStart has no crash-loop condition. The fix must adapt the package/runtime invocation without removing QuickStart or selecting the uhttpd-oriented LuCI meta collections.

## Build lane

No build is launched while bootstrap run `33196164359` is active. After it passes, select ImageBuilder for overlay/service-only changes. Escalate only if the QuickStart executable or package init artifact must be rebuilt, in which case build QuickStart through the SDK and assemble with ImageBuilder. A full build is prohibited unless a target/kernel/ABI/feed change is proven necessary.
