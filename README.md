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

## Tools

| Tool       | Purpose                                                    |
| ---------- | ---------------------------------------------------------- |
| `lpmake`   | Create a super image (`--device-size=auto` is supported)   |
| `lpunpack` | Extract partitions from a super image (`-i` for extra images) |
| `lpadd`    | Add or replace (`--replace`) a partition in a super image  |
| `lpflash`  | Write a super image to a block device                      |
| `lpdump`   | Print super image metadata (`--json` for JSON output)      |

Run any tool without arguments for its usage.
