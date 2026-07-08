---
title: "Through ELF: Linux Dynamic Linking"
description: "A walkthrough of Linux dynamic linking through ELF binaries — from ELF header to PLT/GOT to lazy binding — traced on a minimal main + libmylib.so example."
keywords: "ELF, ELF64, Linux, dynamic linking, dynamic linker, ld-linux.so, ld.so, glibc, PLT, GOT, .plt, .got, .got.plt, lazy binding, symbol resolution, relocation, x86-64, x86_64, PIE, ASLR, position-independent executable, address space layout randomization, .dynamic, DT_NEEDED, DT_STRTAB, DT_SYMTAB, DT_GNU_HASH, R_X86_64_JUMP_SLOT, R_X86_64_RELATIVE, link_map, lookup scope, shared library, .so file, readelf, objdump, hexdump, ldd, strace, walkthrough, tutorial, systems programming, binary analysis, low-level"
lang: en
permalink: /
---

![](images/top.png)

# Through ELF: Linux Dynamic Linking

**English** | [日本語 (Japanese)](README-jp.md)

Two files, `main.c` and `mylib.c`, are provided: `main.c` is built into the executable `main`, and `mylib.c` is built into the shared library `libmylib.so`. `main` uses `libmylib.so`, but `libmylib.so` itself is not included inside `main`.

<!-- SEO intro added by setup-github-pages; review and adjust -->

If you have ever wanted to understand **Linux dynamic linking** from the
ground up — how a call to a function that lives in a **shared library**
(`.so`) actually reaches its real code at runtime — this walkthrough traces
the whole path on one tiny example. Topics covered include the **ELF** header
and program headers, the **dynamic linker** (`ld-linux.so`), the **`.dynamic`**
section, **symbol resolution** via **`DT_GNU_HASH`**, the **PLT/GOT** bridge,
**relocations** (`R_X86_64_JUMP_SLOT`), and **lazy binding** on **x86-64**
**PIE** binaries — inspected directly with `readelf`, `objdump`, and `strace`.

<!-- /SEO intro -->

## Subject

```c
// mylib.c → libmylib.so
int add(int a, int b) { return a + b; }
```

```c
// main.c → main
int add(int, int);
int main(void) { return add(2, 3); }
```

In this book we call these two files (`main` and `libmylib.so`) the
**subject**. Even though the body of `add` is nowhere inside `main`,
running `./main` returns `5`. The mechanism by which this call is made
to work internally — that is, **dynamic linking** — is what we will
trace, using the subject as our starting point.


## The Big Picture

```
   +------------------------+
   | Kernel (Linux)         |   Parses the ELF, maps it into memory,
   |                        |   and hands control to ld-linux.so
   +------------------------+

   +------------------------+
   | Dynamic Linker         |   Actual file: /lib64/ld-linux-x86-64.so.2
   | "ld-linux.so"          |   Loads dependent libraries and does symbol resolution
   +------------------------+

   +------------------------+
   | main (ELF)             |   The executable we wrote
   +------------------------+

   +------------------------+
   | libmylib.so (ELF)      |   The shared library we wrote
   +------------------------+
```

## Table of Contents

| Chapter | Contents |
|---|---|
| [01 ELF Header](docs/en/01_elf_header.md) | The structure of the first 64 bytes |
| [02 Program Headers](docs/en/02_program_header.md) | PT_LOAD / PT_INTERP / PT_DYNAMIC and the memory layout |
| [03 Dynamic Linker Startup](docs/en/03_dynamic_linker_startup.md) | The baton pass from the kernel to ld-linux.so |
| [04 The .dynamic Section](docs/en/04_dynamic_section.md) | A table of contents for the metadata dynamic linking needs |
| [05 Symbol Resolution](docs/en/05_symbol_resolution.md) | The procedure for looking up `add` from `libmylib.so`'s `.dynsym` |
| [06 PLT / GOT](docs/en/06_plt_got.md) | The structure of the "bridge" for the `add` call |
| [07 Lazy Binding](docs/en/07_lazy_binding.md) | Up to the moment the GOT is rewritten on the first call |

## Appendices

Supplementary material that is not needed for the main thread but is referenced from the body text.

| Appendix | Contents |
|---|---|
| [Appendix A: Terminology and Notation Conventions](docs/en/08_notation.md) | A list of labels such as `base_main` (refer to as needed) |
| [Appendix B: How to Read the Startup Stack](docs/en/09_startup_stack.md) | The layout of `argc` / `argv` / `envp` / `auxv` (if you get stuck at 03) |
| [Appendix C: The Self-Relocation Mechanism](docs/en/10_self_relocation.md) | The internals of how ld-linux.so rewrites itself (a deeper dive into 03 step 1) |
| [Appendix D: Library Load Order and Lookup Scope](docs/en/11_load_order.md) | The causal chain from `-lmylib` through DT_NEEDED, BFS loading, and lookup scope |

## Environment

| Item | Value |
|---|---|
| OS | Linux |
| Architecture | x86-64 |
| libc | glibc |
| Executable format | **PIE** (position-independent executable) |
| Dynamic linker | `/lib64/ld-linux-x86-64.so.2` (glibc) |
| Binding mode | **lazy binding** |


## Tools We Use to Investigate

Commands used for investigation:

```
   readelf -h   Show ELF header
   readelf -l   Show program headers
   readelf -d   Show .dynamic
   readelf -s   Show symbol tables (.dynsym, .symtab)
   readelf -r   Show relocation entries
   objdump -d   Disassemble
   hexdump -C   Show raw bytes in hex
   ldd          List dependent .so files
   strace       Trace system calls (execve, mmap, openat)
```

## Compile & Link & Run

The subject files are in [`samples/`](samples/). All of the `readelf` /
`objdump` outputs and concrete address values shown throughout this
series are taken from samples generated by GCC 14.3.0 in the following
way.

On a Linux x86-64 environment:

```sh
cd samples
sh build.sh
./main ; echo $?    # Success if 5 is printed
```

On non-Linux environments such as macOS, borrow gcc via Docker:

```sh
cd samples
docker run --rm -v "$PWD":/work -w /work gcc:14-bookworm sh -c "sh build.sh"
```

Once `libmylib.so` and `main` are built, you can reproduce the `readelf` /
`objdump` outputs in `docs/en/` verbatim (concrete values will vary somewhat
depending on the GCC version and linker settings).

## Out of Scope (things we don't cover)

To follow only "the mechanisms that appear without exception every time
we call `add()`", we deliberately leave the following out:

- Section headers in general / debug information (`.debug_*`)
- Symbol versioning (`DT_VERSYM`, `DT_VERNEED`)
- TLS internals, IFUNC, constructors (`DT_INIT_ARRAY` and friends)
- 32-bit ELF (x86_64 only)
- The older `DT_HASH` algorithm (`DT_GNU_HASH` only)
- Prelinking, and the special behavior of `LD_PRELOAD`
- The API details of `dlopen` / `dlsym`
- `-z now` (eager binding) — lazy binding only

## Credits

- Planning: t-ishii66 (studies physics at university. Systems engineer. Currently wrestling with English conversation)
- Design: t-ishii66
- Documentation: Claude Opus4.7, t-ishii66, GPT5.5
- Review: t-ishii66
- Illustrations: ChatGPT 5.5
- English translation: Claude Opus4.7
- Copyright(c) 2026 t-ishii66. All rights reserved.
