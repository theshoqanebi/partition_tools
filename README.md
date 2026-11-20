# lpunpack and lpmake

Static builds of the AOSP dynamic partition tools (`lpmake`, `lpunpack`,
`lpadd`, `lpflash`, `lpdump`) for Linux, macOS and Windows.

Source code is from AOSP: `partition_tools` is synced with
[system/extras](https://android.googlesource.com/platform/system/extras/+/main/partition_tools)
`main`, and `lib/` holds the libraries they depend on.

## Requirements

- `clang` / `clang++`
- `make`, `ar`, `strip`

## Build

```
make -j$(nproc)
```

The binaries are written to `bin/`, and intermediate files to `build/`.

| Command         | Description                                 |
| --------------- | ------------------------------------------- |
| `make`          | Build all tools                             |
| `make V=1`      | Show the full compiler commands             |
| `make clean`    | Delete `build/` and `bin/`                  |
| `make CC=gcc CXX=g++` | Use another compiler (untested)       |

### Windows (MinGW)

Tested with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (clang,
x86_64) and Git for Windows. The recipes need a POSIX shell, so build from
Git Bash or MSYS2:

```
mingw32-make -j8
```

From PowerShell or cmd, put Git's tools on `PATH` first:

```
$env:Path = "C:\Program Files\Git\usr\bin;$env:Path"
mingw32-make -j8
```

This produces `bin/lpmake.exe`, `bin/lpunpack.exe`, `bin/lpadd.exe`,
`bin/lpflash.exe` and `bin/lpdump.exe`. The Windows build uses the shims in
`lib/compat/win32/` for headers MinGW does not provide, and `lpdump` only
dumps image files (it cannot read device fstab or snapshot state).

### Android (NDK)

Cross-builds static Android binaries with the NDK (tested with r28, from
Windows/Git Bash):

```
make -j8 ANDROID=1
```

The NDK is taken from `ANDROID_NDK_HOME` / `ANDROID_NDK_ROOT`, or the newest
one under `$ANDROID_HOME/ndk` (`%LOCALAPPDATA%\Android\Sdk\ndk` on Windows).

| Variable                  | Default     | Description                                   |
| ------------------------- | ----------- | --------------------------------------------- |
| `ANDROID_ABI`             | `arm64-v8a` | Also `armeabi-v7a`, `x86_64`, `x86`           |
| `ANDROID_API`             | `30`        | Minimum API level (29 or newer is required)   |

Binaries are written to `bin/android-<abi>/`. Copy them to the device with
`adb push` (e.g. to `/data/local/tmp`) and run them from there.

`lpdump` is not built for Android: its on-device code needs `fs_mgr` and
`libsnapshot`, which are not in `lib/`. `lpmake` and `lpunpack` were
verified on an arm64 device. `lpadd` fails there with a permission error on
`/dev/block/by-name/super`, because upstream `lpadd` always looks up the
super block device by name.

## Tools

| Tool       | Purpose                                                    |
| ---------- | ---------------------------------------------------------- |
| `lpmake`   | Create a super image (`--device-size=auto` is supported)   |
| `lpunpack` | Extract partitions from a super image (`-i` for extra images) |
| `lpadd`    | Add or replace (`--replace`) a partition in a super image  |
| `lpflash`  | Write a super image to a block device                      |
| `lpdump`   | Print super image metadata (`--json` for JSON output)      |

Run any tool without arguments for its usage.
