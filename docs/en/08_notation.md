![](../../images/08.png)

# Appendix A. Terminology and Notation Conventions

A dictionary of the terms and symbols used throughout the book. Detailed
explanations are left to each Step / Appendix; here we simply line up
**short definitions and pointers to references**. Use this as a place
to come back to when a term trips you up while reading.

- **Part 1**: This book's own notation conventions (`base_main`,
  `add@plt+N`, etc.)
- **Part 2**: Terms that appear in the structure of ELF files (the ELF
  header, Program headers, `.dynamic`, the symbol table, PLT/GOT,
  relocations)
- **Part 3**: Terms that appear at runtime (auxv, link_map, lookup
  scope, lazy binding, the resolver, library search)
- **Part 4**: Main options of the dump tools used in this book
  (`readelf` / `objdump`)

---

# Part 1: Notation Conventions

## VA = Virtual Address

An address in the address space as seen by the process. Whenever this
book writes "VA", it always means this. The CPU converts it to a
physical address via the MMU at runtime, but that physical address does
not appear in the story of this book (dynamic linking is entirely
carried out on VAs).

For a PIE (position-independent executable), the **address values in
the ELF file** visible via `readelf` etc. (e.g. `0x1050`) are not the
runtime VA themselves; they are written as "offsets from the base
address". The actual VA is determined after the process has been
loaded:

```
   Address value in the ELF file "0x1050"  +  base_main  =  actual VA
```

Reference: Step 1 § `e_type`.

## Labels for base addresses

The head of the VA at which each ELF is loaded at startup is
represented by the following labels respectively:

| Label | Meaning |
|---|---|
| `base_main` | base of `main` |
| `base_libmylib` | base of `libmylib.so` |
| `base_libc` | base of `libc.so.6` |
| `base_ld` | base of `ld-linux.so` itself |

Because of PIE, the value changes on each startup due to ASLR, but is
fixed within a single run.

## Symbolic notation vs concrete values

Concrete values (`0x1036`, `0x10f9`, etc.) change with each build, so in
the body text we **use symbolic notation as the star** and **put the raw
numbers in parentheses**:

```
   add@plt (= 0x1030)
   add@plt+6 (= 0x1036)
   actual VA of GOT[add]     (= base_main + 0x4000)
   initial value of GOT[add] (= base_main + 0x1036)
   st_value(add)  (= 0x10f9)
   actual VA of add  (= base_libmylib + st_value(add) = base_libmylib + 0x10f9)
```

Numbers change with compiler and linker versions, but the relationships
between symbols do not change. Treat raw numbers as reference points
for confirming the correspondences in the dumps we've included.

## The `add@plt+N` form

`add@plt` is the symbol name pointing at the head VA of `add`'s PLT
stub (the substance is a label that tools such as `objdump` attach to
raw addresses).

- **When pointing at the head of the stub, bare `add@plt`** (don't write `+0`)
  - Examples: `add@plt (= 0x1030)`, `call add@plt`, `jmp add@plt`
- **Attach `+N` only when a byte offset from the head is needed**
  - Example: `add@plt+6 (= 0x1036)` (the location of the stub's 2nd instruction `push 0x0`)

Similarly, `add@got.plt` is a label pointing at the address of the GOT
slot for `add`.

Reference: the notation table in Step 6 § The big picture.

## Static linker vs dynamic linker

| Name | Actual thing | Responsibility |
|---|---|---|
| **Static linker** | `binutils ld` | Writes initial values into `.got.plt` and so on at build time |
| **Dynamic linker** | `/lib64/ld-linux-x86-64.so.2` (hereafter `ld-linux.so`) | Performs relocation and symbol resolution at startup / runtime |

Bare "linker" or "`ld`" is not used (always be explicit about "static"
or "dynamic").

## The term "symbol resolution"

The series of processing steps by which `ld-linux.so` pins down `add`'s
actual VA is called **"symbol resolution"** in this book. "Symbol
lookup" and "symbol search" are not used (to avoid terminology drift).

That said, mentioning individual operations within the whole of "symbol
resolution" (e.g. walking `.dynsym`, or looking up the hash table via
`.gnu.hash`) is OK.

## The Type display of `readelf -h`

For a PIE (position-independent executable), the Type display in this
book is unified as
`Type: DYN (Position-Independent Executable file)`
(the standard output of binutils 2.39+). Older binutils output
`Type: DYN (Shared object file)`, but the values shown in this book are
aligned to the former.

---

# Part 2: ELF File Structure Terminology

## ELF in general

| Term | Meaning |
|---|---|
| **ELF** (Executable and Linkable Format) | The format for executables, shared libraries, and object files on Linux/Unix-family systems |
| **ELF64** | 64-bit ELF. Everything in this book is this |
| **`Elf64_Ehdr`** | The 64-byte ELF header structure at the head. The starting point for decoding the whole file |
| **`e_type`** | File type (`ET_REL` / `ET_EXEC` / `ET_DYN`) |
| **`ET_REL`** (= 1) | Relocatable file (`.o`) |
| **`ET_EXEC`** (= 2) | Fixed-address executable (non-PIE) |
| **`ET_DYN`** (= 3) | Shared library, or PIE executable |
| **`e_entry`** | Entry point (program start location). Under PIE, an offset within the image |
| **`e_phoff` / `e_phentsize` / `e_phnum`** | File offset / entry size / count of the Program header table |
| **PIE** (Position-Independent Executable) | Position-independent executable. An executable loaded via the same mechanism as a shared library |
| **ASLR** (Address Space Layout Randomization) | A security mechanism that randomizes the load VA on every startup |

Reference: all of Step 1.

## Program header (Elf64_Phdr)

| Term | Meaning |
|---|---|
| **Program header** | A 56-byte struct (`Elf64_Phdr`). Represents one **region loaded into memory** or **region that conveys information to the execution environment** |
| **Segment** | Of the regions a program header represents, the one loaded into memory (= `PT_LOAD`) |
| **Section** | Internal subdivisions such as `.text`. One segment bundles multiple sections |
| **`p_type`** | Segment type (`PT_LOAD` / `PT_INTERP` / `PT_DYNAMIC` / `PT_PHDR`, etc.) |
| **`PT_LOAD`** (= 1) | Indicates a range to place in memory and its protection attributes (4 in our subject) |
| **`PT_DYNAMIC`** (= 2) | `.dynamic` lives in this segment |
| **`PT_INTERP`** (= 3) | A path string to the dynamic linker (`"/lib64/ld-linux-x86-64.so.2"`) |
| **`PT_PHDR`** (= 6) | Points at the Program header table itself |
| **`p_offset`** | Offset from the start of the file |
| **`p_vaddr`** | Address in memory (under PIE, an offset within the image; actual VA is `base_main + p_vaddr`) |
| **`p_filesz` / `p_memsz`** | Size in file / size in memory (the difference is zero-initialized regions such as `.bss`) |
| **`p_flags`** | R/W/X protection attributes |

Reference: all of Step 2.

## `.dynamic` (Elf64_Dyn)

| Term | Meaning |
|---|---|
| **`.dynamic`** | The section that consolidates dynamic linking information. An array of `(tag, value)` pairs |
| **`Elf64_Dyn`** | One entry, 16 bytes (`d_tag` + `d_val` or `d_ptr`) |
| **`d_tag`** | Entry type (`DT_*`) |
| **`d_val`** | When interpreted as an integer value |
| **`d_ptr`** | When interpreted as a virtual address |
| **`DT_NULL`** (= 0) | Terminator of the array |
| **`DT_NEEDED`** (= 1) | A dependent library name (offset into `.dynstr`) |
| **`DT_STRTAB`** (= 5) | Address of `.dynstr` |
| **`DT_SYMTAB`** (= 6) | Address of `.dynsym` |
| **`DT_RELA`** (= 7) | Address of `.rela.dyn` (general relocation table) |
| **`DT_RELASZ`** (= 8) | Size of `.rela.dyn` |
| **`DT_RELAENT`** (= 9) | Size of one entry in `.rela.dyn` |
| **`DT_JMPREL`** (= 23) | Address of `.rela.plt` (PLT relocation table) |
| **`DT_PLTRELSZ`** (= 2) | Size of `.rela.plt` |
| **`DT_PLTGOT`** (= 3) | Address of `.got.plt` |
| **`DT_RUNPATH`** (= 29) | Library search path (string offset such as `$ORIGIN`) |
| **`DT_RPATH`** (= 15) | Older-style search path. Ignored if `DT_RUNPATH` exists |
| **`DT_GNU_HASH`** | Address of `.gnu.hash`. Not covered in detail in this book |
| **`.dynstr`** | A region in which NULL-separated strings are lined up. Given an offset, one string is extracted |

Reference: all of Step 4.

## Symbol table

| Term | Meaning |
|---|---|
| **`.dynsym`** | Dynamic symbol table. An array of `Elf64_Sym` |
| **`Elf64_Sym`** | One entry, 24 bytes |
| **`st_name`** | Symbol name (offset into `.dynstr`) |
| **`st_value`** | The symbol's relative address (the actual call uses `base + st_value`) |
| **`st_shndx`** | The index of the section it belongs to. `SHN_UNDEF` (= 0) means undefined |
| **`SHN_UNDEF`** (= 0) / **`UND`** | Not defined in this ELF (needs resolution) |
| **`FUNC`** | Symbol type: function |
| **`GLOBAL`** / **`LOCAL`** / **`WEAK`** | The symbol's binding (visibility scope) |

Reference: all of Step 5.

## PLT / GOT

| Term | Meaning |
|---|---|
| **PLT** (Procedure Linkage Table) | A group of 3-instruction stubs that receive function calls via indirect jumps. Lives in the `.plt` section |
| **GOT** (Global Offset Table) | An address table for indirect access. In Linux ELF, split into 2 sections: `.got` and `.got.plt` |
| **`.got`** | Data, or function pointers subject to eager binding |
| **`.got.plt`** | Slots for functions called via the PLT (lazy binding). When this book says "GOT slot", it means one of these |
| **PLT stub** | One entry inside `.plt` (3 instructions: `jmp *[GOT]`, `push N`, `jmp PLT0`) |
| **GOT slot** | One entry of `.got.plt` (= container for the function address) |
| **PLT0** | The common confluence of all PLT stubs. Jumps to the resolver |
| **`add@plt`** | The head address of `add`'s PLT stub (example: `0x1030`) |
| **`add@got.plt`** | The address of the GOT slot for `add` (example: `0x4000`) |
| **`add@plt+6`** | The address of the 2nd instruction (`push N`) of the PLT stub |

Reference: all of Step 6.

## Relocation

| Term | Meaning |
|---|---|
| **relocation** | The operation of filling in, at runtime with actual addresses, spots marked as "rewrite here after loading" |
| **`.rela.dyn`** | Table of general relocation entries (pointed to by `DT_RELA`) |
| **`.rela.plt`** | Table of PLT (JUMP_SLOT) relocation entries (pointed to by `DT_JMPREL`) |
| **`Elf64_Rela`** | One entry, 24 bytes |
| **`r_offset`** | Virtual address of the write target |
| **`r_info`** | Relocation type + symbol number (upper 32 bits = sym, lower 32 bits = type) |
| **`r_addend`** | Addend value |
| **relocation type** | The kind of relocation. A set of constants defined by the ELF spec by use |
| **`R_X86_64_RELATIVE`** (= 8) | Writes `base + r_addend` (used in self-relocation) |
| **`R_X86_64_GLOB_DAT`** (= 6) | Data references inside GOT |
| **`R_X86_64_JUMP_SLOT`** (= 7) | Writes to the GOT slot for the PLT (stores the result of symbol resolution) |
| **reloc index** | Index that picks the N-th entry of `.rela.plt`. The PLT stub passes it to the resolver via `push N` |

Reference: Step 3 (self-relocation of `R_X86_64_RELATIVE`), Step 6
(`R_X86_64_JUMP_SLOT`), Appendix C (details of self-relocation).

---

# Part 3: Runtime Terminology

## Startup information (prepared by the kernel at execve time)

| Term | Meaning |
|---|---|
| **argc / argv / envp** | Arguments and environment variables pushed onto the stack at process startup |
| **auxv** (Auxiliary Vector) | An extra channel by which the kernel passes ELF information to `ld-linux.so`. An array of `(key, value)` pairs |
| **`AT_NULL`** (= 0) | Terminator of auxv |
| **`AT_PHDR`** (= 3) | Actual VA of `main`'s Program header array |
| **`AT_PHENT`** (= 4) | Size of one Program header (= 56) |
| **`AT_PHNUM`** (= 5) | Number of Program headers |
| **`AT_BASE`** (= 7) | `base_ld` of `ld-linux.so` |
| **`AT_ENTRY`** (= 9) | Actual VA of `main`'s entry point (= `base_main + e_entry`) |

Reference: Step 3 § The contents of the Auxiliary Vector (auxv), all of
Appendix B.

## Internal data of the dynamic linker

| Term | Meaning |
|---|---|
| **`link_map`** | A node `ld-linux.so` holds for each ELF. All nodes are linked in a linked list via `l_next` / `l_prev` |
| **`l_addr`** | The base address at which it was loaded |
| **`l_ld`** | The location of that ELF's `.dynamic` |
| **`l_next` / `l_prev`** | Pointers to adjacent link_map nodes |
| **`l_scope`** | Pointer to the **lookup scope table (symbol search order list)** |
| **lookup scope** | The search-order list of "which ELFs to look at, in what order". Each ELF holds one (= the table pointed to by `l_scope`) |
| **link_map linked list** vs **lookup scope table** | The former is the structure that organizes all ELFs; the latter is a list arranged in search order. In this book's subject, the order matches, but they are different data structures |

Reference: Step 7 § What is `link_map`, Appendix D (how the order of
lookup scope is determined).

## Startup processing

| Term | Meaning |
|---|---|
| **self-relocation** | The processing that runs `ld-linux.so`'s own `R_X86_64_RELATIVE` relocations without symbol resolution. The first step of startup |
| **`_start`** | The entry point pointed to by an ELF's `e_entry`. Not the user's `main()`, but an assembly stub from the C runtime |
| **`__libc_start_main`** | A libc function. Called from `_start`, it handles initialization → `main()` → `exit` |
| **`.init_array`** | An array of constructors of each `.so` (contains initializations such as libc's) |

Reference: Step 3 § Dynamic linking by ld-linux.so, all of Appendix C.

## Symbol resolution and lazy binding

| Term | Meaning |
|---|---|
| **symbol resolution** | Processing that searches lookup scope in order for definitions of undefined symbols (e.g. `add` on the `main` side) and pins down their actual VA |
| **lazy binding** | The mechanism that defers pinning down a function's actual VA until the first call. Costly only on the first call, direct jumps thereafter |
| **resolver** | The general name for the routine that resolves symbols in lazy binding. The substance is `_dl_runtime_resolve` |
| **`_dl_runtime_resolve`** | A hand-written assembly trampoline inside `ld-linux.so`. Its address is in `.got.plt[2]` |
| **`_dl_fixup`** | A C function called from `_dl_runtime_resolve`. Actually performs symbol resolution and rewrites the GOT slot |
| **`.gnu.hash`** | A hash table that speeds up `.dynsym` search (pointed to by `DT_GNU_HASH`). Not covered in detail in this book |

Reference: Step 5 (static perspective), Step 7 (dynamic flow).

## Dependent library loading

| Term | Meaning |
|---|---|
| **loading in dependency order** (breadth-first) | The method of following `DT_NEEDED` from the head and `mmap`ing in breadth-first order |
| **breadth-first (BFS = Breadth-First Search)** | Graph search strategy. Processes all nodes at the same level before descending to the next level |
| **load order** | The order in which `ld-linux.so` loads each ELF, determined by BFS |
| **library search order** | Resolution order from library name to actual file location. Priority: `LD_LIBRARY_PATH` > `DT_RUNPATH` > `ld.so.cache` > default paths |
| **`$ORIGIN`** | A special token that can be written into `DT_RUNPATH`. Points to the directory of the executable |
| **`ld.so.cache`** | The library cache created by `ldconfig` |

Reference: Step 4 § Library search order, all of Appendix D.

---

# Part 4: Dump Tools

The dump tools that appear in this book, and the main uses of each of
their options:

| Command | Main use | Reference in this book |
|---|---|---|
| `readelf -h main` | Display the ELF header | Step 1 |
| `readelf -l main` | Display Program headers | Step 2 |
| `readelf -d main` | Display the contents of `.dynamic` | Step 4 |
| `readelf -s --dyn-syms main` | Display `.dynsym` | Step 5 |
| `readelf -r main` | Display the relocation tables (`.rela.dyn` / `.rela.plt`) | Step 6 |
| `objdump -d main` | Disassemble `main` | Step 6 (`call add@plt`) / Step 7 |
| `objdump -d -j .plt main` | Disassemble only the `.plt` section | Step 6 (add@plt, PLT0) |
| `ldd main` | Show the resolution result of dependent `.so`s | Step 3 / Step 4 |
| `LD_SHOW_AUXV=1 ./main` | Display the auxv at startup | Step 3 |


