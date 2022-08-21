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
