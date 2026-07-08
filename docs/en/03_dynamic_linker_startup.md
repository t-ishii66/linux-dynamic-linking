![](../../images/03.png)

# Step 3. Dynamic Linker Startup

By the end of Step 2, the kernel had finished mapping both `main` and
`ld-linux.so` into memory, and finally jumped to **`ld-linux.so`'s
e_entry**.

In this step we follow what happens from the moment the kernel jumps
into `ld-linux.so` until `ld-linux.so` passes control into `main`.
The rough flow is:

```
   kernel
     -> ld-linux.so starts up                                    (end of Step 2)
     -> ld-linux.so receives info about main from the stack      (this chapter §"Stack" §"Auxiliary Vector")
     -> ld-linux.so loads main's dependent libraries             (this chapter §"Dynamic linking by ld-linux.so")
     -> ld-linux.so jumps to main's _start
     -> main() is called                                         (Step 4 onward)
```


---

## How the kernel passes information to the dynamic linker: the stack

If you're not fully at home with the basics of the stack — which
direction it grows, `RSP`, and the C-language convention of `argc` /
`argv` / `envp` — see over here:
[Appendix B: How to Read the Startup Stack](./09_startup_stack.md).

Just before starting `ld-linux.so`, the kernel piles up **process
startup information** on the user stack. The layout is fixed by the
System V x86_64 ABI:

(This stack is not a PT_LOAD; it is a region the kernel separately
reserves for the new process. It is reserved just before jumping into
ld-linux.so, after the PT_LOADs have been mmap'd in Step 2.)

```
   high address
       +------------------------------+
       | (env string data)             |   "PATH=/usr/bin\0"  and so on
       | (arg string data)             |   "./main\0"
       +------------------------------+
       | Auxiliary Vector (auxv)      |   <-- what the dynamic linker cares about (contents in the next section)
       |   AT_NULL,  0                |
       |   ...                        |
       |   AT_ENTRY, base_main+0x1050 |   (= actual VA, base added because of PIE)
       |   AT_BASE,  base_ld          |
       |   AT_PHNUM, 13               |
       |   AT_PHENT, 56               |
       |   AT_PHDR,  &main_phdr       |
       +------------------------------+
       | envp[N] = NULL               |
       | envp[N-1] = "PATH=..."       |
       | ...                          |
       | envp[0]                      |
       +------------------------------+
       | argv[argc] = NULL            |
       | argv[argc-1]                 |
       | ...                          |
       | argv[0] = "./main"           |
       +------------------------------+
       | argc                         |   <-- RSP is pointing here
       +------------------------------+
   low address
```

**Just before** jumping to ld-linux.so's `e_entry`, the kernel sets the
`RSP` register to point at the top of this stack (the position where
argc lives). So from the very moment ld-linux.so starts, using:

- **Location**: passed via the `RSP` register
- **Format**: the order argc → argv → envp → auxv is fixed by the System V x86_64 ABI

as its 2 handholds, it walks the stack structure accurately (the length
of argv is determined by argc; envp is read until the terminating NULL,
auxv until the AT_NULL terminator, and thus the length of each section
falls out in turn). This is why `ld-linux.so`, which has been "merely
mmap'd", can still reach the process startup information sitting on the
stack.

---

## The contents of the Auxiliary Vector (auxv)

We now decode the block placed near the center of the previous stack
figure, `Auxiliary Vector (auxv)` — the region we annotated as "what
the dynamic linker cares about."

auxv is an array of `(key, value)` pairs. Each entry is 16 bytes
(8-byte key + 8-byte value). It terminates with `AT_NULL = 0`.

The "key" is placed on the stack as an integer.
Names like `AT_PHDR` are the names (constant macros) given to those
integers by the C header; for example `AT_PHDR` is an alias for `3`.

The 5 keys we focus on are:

```
   Key (8 bytes)         Value (8 bytes)
   ------------------    --------------------------------------
   AT_PHDR   (= 3)       Address of main's Program header array
                         (= base_main + e_phoff in our case)
   AT_PHENT  (= 4)       Size of one Program header (= 56)
   AT_PHNUM  (= 5)       Number of Program headers (= 13)
   AT_BASE   (= 7)       base_ld of ld-linux.so
   AT_ENTRY  (= 9)       Actual VA of main's entry point
                         (= base_main + e_entry = base_main + 0x1050)
```

In our current binary, `PT_PHDR`'s `p_vaddr` and `e_phoff` are both
`0x40`, so we can write `AT_PHDR = base_main + e_phoff`.
In general, `AT_PHDR` is the actual VA of the Program header array in
memory.

---

## Example auxv display

The content is visible with `LD_SHOW_AUXV=1 ./main`:

```
$ LD_SHOW_AUXV=1 ./main
AT_SYSINFO_EHDR: 0x7ffe123fa000
AT_HWCAP:        0x178bfbff
AT_PAGESZ:       4096
AT_CLKTCK:       100
AT_PHDR:         0x55b3a4d2e040          <-- actual VA of main's phdr
AT_PHENT:        56
AT_PHNUM:        13
AT_BASE:         0x7f4d2e9b2000          <-- base_ld
AT_FLAGS:        0x0
AT_ENTRY:        0x55b3a4d2f050          <-- actual VA of main's _start
AT_UID:          1000
...
```

---

## Dynamic linking by ld-linux.so

(Terminology: **relocation** is the operation of filling in, at runtime,
the actual addresses at places in the ELF marked as "rewrite here once
loaded". This is necessary because addresses cannot be written before
ASLR fixes the base. The concrete structure of relocation entries
(`Elf64_Rela`, `r_offset`, `r_info`, ...) and specific types (such as
`R_X86_64_JUMP_SLOT`) are treated in Step 6.)

```
   A. Self-relocation
        ld-linux.so is itself ET_DYN and has rewrite targets inside itself too.
        At this point it executes relocations that do not involve symbol resolution
        (type R_X86_64_RELATIVE = just adding base_ld in various places); once done,
        it is in a state where ordinary C functions can be freely called.

   B. Read auxv
        From AT_PHDR / AT_PHNUM, learn the location of main's Program headers.
        From AT_BASE, learn its own base_ld.
        Remember AT_ENTRY for later use.

   C. Find main's PT_DYNAMIC  (details: Step 4)
        Walk the Program header array starting at AT_PHDR in order,
        and find the entry with p_type == PT_DYNAMIC.
        Its p_vaddr (+ base_main) is the address of main's .dynamic.

   D. Load dependent libraries  (details: Step 4)
        Process .dynamic's DT_NEEDED entries in order:
          mmap libmylib.so
          mmap libc.so.6
        Then recursively process each .so's .dynamic
        (libc.so.6's DT_NEEDED, etc.)

   E. Run relocations  (details: Steps 5-7)
        Process each ELF's ordinary relocations (.rela.dyn pointed to by DT_RELA).
        Relocations for function calls via the PLT live in a separate table
        (.rela.plt pointed to by DT_JMPREL); at this point they are not
        resolved directly, but rigged to be resolved at the first call
        (= lazy binding).

   F. Run .init_array
        Call each .so's constructors (libc initialization, etc.).

   G. Jump to AT_ENTRY
        At last, pass control to main's _start.
```

The concrete rewrite procedure of self-relocation (A) is covered in
[Appendix C: The Self-Relocation Mechanism](./10_self_relocation.md).

---

## Aside: what is `.init_array` in F

`.init_array`, which `ld-linux.so` calls in F, is **an array of function
pointers held by each ELF, of "functions to be executed exactly once at
startup"**. Functions marked with C's
`__attribute__((constructor))`, and constructors of C++ static-storage
objects, are placed here by the compiler. libc/libmylib.so's own
internal initialization routines are lined up here as well.

Structure:

- `DT_INIT_ARRAY` inside `.dynamic` points to `.init_array`'s location,
  and `DT_INIT_ARRAYSZ` gives the number of bytes
- The content is just an array of `void (*)(void)` function pointers

```
   .init_array   (DT_INIT_ARRAYSZ bytes starting at what DT_INIT_ARRAY points to)
       +----------------+
       | fn1  : void(*)(void) |
       +----------------+
       | fn2  : void(*)(void) |
       +----------------+
       :                :
```

Once A-E are all done, `ld-linux.so` (internally `_dl_init`), **just
before** jumping into `main`'s `_start`, walks this array **from the
leaves of the dependency graph up to the root** and calls each
function. For our subject in this book, that is:

```
   libc.so.6's .init_array  →  libmylib.so's .init_array  →  main's .init_array
```

in that order. After libc's initialization is done, then libmylib, and
finally main — this order guarantees that "the initialization of the
dependent side runs while the depended-upon side is already complete".

The `add(2, 3)` of our subject is a story about tracing the function-call
path (Steps 5-7), so the actual contents of `.init_array` do not
appear. Its point of contact with this book is: within the startup
flow, it sits "between E and G".

---

## Aside: what is main's "_start"

The address that `AT_ENTRY` points to (= `base_main + e_entry` =
`base_main + 0x1050`, an actual VA because of PIE) is not the user-written
`main()`; **instead**, there is a small assembly stub called `_start`
from the C runtime.

Looking at `_start` via `objdump -d main`:

```
0000000000001050 <_start>:
    1050:  31 ed                  xor    ebp,ebp
    1052:  49 89 d1               mov    r9,rdx
    1055:  5e                     pop    rsi
    1056:  48 89 e2               mov    rdx,rsp
    1059:  48 83 e4 f0            and    rsp,0xfffffffffffffff0
    105d:  50                     push   rax
    105e:  54                     push   rsp
    105f:  45 31 c0               xor    r8d,r8d
    1062:  31 c9                  xor    ecx,ecx
    1064:  48 8d 3d ce 00 00 00   lea    rdi,[rip+0xce]      # address of main
    106b:  ff 15 4f 2f 00 00      call   QWORD PTR [rip+0x2f4f]  # call __libc_start_main
    1071:  f4                     hlt
```

The point is the 2 lines with the comments. `_start` packs the address
of `main` into one of the arguments and calls `__libc_start_main`. So
inside that call, `main()` eventually gets called.

`__libc_start_main` is a libc function, and internally it:
   - calls initialization routines
   - calls `main(argc, argv, envp)`
   - passes `main`'s return value to `exit()`

does all of the above.

In this series, we stop at the understanding that **`main()` is called
via `_start` and then `__libc_start_main()`**, and do not chase deeper.

```
   ld-linux.so   --jump-->   _start (= main's e_entry)
                                 |
                                 +--call--> __libc_start_main
                                                |
                                                +--call--> main()
                                                              |
                                                              +--call--> add(2, 3)
                                                                            ^
                                                                            |
                                                              The territory of Step 6, 7
```

---

## What we nailed down this time (points to carry into the next chapter)

```
   [x] Via auxv (AT_PHDR / AT_PHNUM / AT_BASE / AT_ENTRY),
       ld-linux.so obtains main's Program headers / its own base / the startup destination
   [x] Following DT_NEEDED, it recursively mmaps the dependent .so files
       (= the main topic of Step 4)
   [x] In the order "self-relocate → load dependencies → relocate → jump to AT_ENTRY",
       it hands over to main's _start
```

Next is **Step 4: The .dynamic section** —
in the next chapter, we find `.dynamic` from main's `PT_DYNAMIC` and
read `DT_NEEDED`, `DT_STRTAB`, `DT_SYMTAB` and friends.

