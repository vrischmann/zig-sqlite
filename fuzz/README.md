# fuzz testing

This repository contains a binary used for fuzz testing.

# Acknowledgments

The fuzz setup with AFL++ comes from [Ryan Liptak's](https://www.ryanliptak.com/blog/fuzzing-zig-code/) blog post. See [this example repo](https://github.com/squeek502/zig-fuzzing-example) too.

# Prerequisites

To build the fuzz binary we need the `afl-clang-lto` binary in the system path.
The recommended way to get that is to [install AFL++](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/INSTALL.md).

If you don't want to install it system-wide you can also do this instead:
```
make PREFIX=$HOME/local install
```
then make sure that `$HOME/local/bin` is in your system path.

If you installed LLVM from source as described in the [Zig wiki](https://github.com/ziglang/zig/wiki/How-to-build-LLVM,-libclang,-and-liblld-from-source#posix), do this instead:
```
LLVM_CONFIG=$HOME/local/llvm15-release/bin/llvm-config make PREFIX=$HOME/local install
```

# Build and run

Once AFL++ is installed, build the fuzz binary:
```
$ zig build fuzz
```

Finally to run the fuzzer do this:
```
$ afl-fuzz -i - -o fuzz/outputs -- ./zig-out/bin/fuzz
```

Note that `afl-fuzz` might complain about core dumps being sent to an external utility (usually systemd).

You'll have to do this as root:
```
# echo core > /proc/sys/kernel/core_pattern
```

`afl-fuzz` might also complain about the scaling governor, setting `AFL_SKIP_CPUFREQ` as suggested is good enough:
```
$ AFL_SKIP_CPUFREQ=1 afl-fuzz -i - -o fuzz/outputs -- ./zig-out/bin/fuzz
```

# Debugging a crash

If `afl-fuzz` finds a crash it will be added to `fuzz/outputs/default/crashes.XYZ`.

To debug the crash you can run the fuzz binary and giving it the content of the crash via stdin, for example:
```
$ ./zig-out/bin/fuzz < 'fuzz/outputs/default/crashes.2021-12-31-12:43:12/id:000000,sig:06,src:000004,time:210548,execs:1011599,op:havoc,rep:2'
```
