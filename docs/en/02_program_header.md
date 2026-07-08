![](../../images/02.png)

# Step 2. Program Headers

After the ELF header come the program headers. This chapter reads the
structure of a program header (`Elf64_Phdr`).


---

## The whole-file picture

```
   offset 0
       +------------------------+
       |  Elf64_Ehdr (64B)      |
       +------------------------+ <-- e_phoff
       |  Elf64_Phdr [0]        | \
       |  Elf64_Phdr [1]        |  |
       |  ...                   |  > 13 entries (e_phnum), 56B each (e_phentsize)
       |  Elf64_Phdr [12]       | /
       +------------------------+
       |                        |
       |  data body             |
       |  .text, .rodata, .data,|
       |  .dynamic, .plt, .got, |
       |  .dynsym, .dynstr,     |
       |  .gnu.hash, ...        |
       |                        |
       +------------------------+
       |  Section headers       |
       +------------------------+
   end
```

A program header is a 56-byte struct (`Elf64_Phdr`), and it represents
either **a region loaded into memory** or **a region that conveys
information to the execution environment (the kernel / the dynamic
linker)**. The former is called a **segment**.
Our subject has 13 program headers in total; of those, only 4 are the
`PT_LOAD` ones that are actually loaded into memory. The rest, such as
`PT_INTERP` (the dynamic linker's path) or `PT_DYNAMIC` (the position of
`.dynamic`), each have their own separate role.

Inside a segment there are **sections** such as `.text`
(segment ≠ section; a single segment bundles multiple sections together).

---

## The structure of Elf64_Phdr

Each Program header entry is a 56-byte struct called `Elf64_Phdr`.
Written in C it looks like this (defined in `/usr/include/elf.h`):

```c
typedef struct {
    uint32_t p_type;     // [ 0.. 3] segment type
    uint32_t p_flags;    // [ 4.. 7] access permissions (R/W/X)
    uint64_t p_offset;   // [ 8..15] file offset (where from)
    uint64_t p_vaddr;    // [16..23] virtual address (where to place)
    uint64_t p_paddr;    // [24..31] physical address
    uint64_t p_filesz;   // [32..39] size in the file
    uint64_t p_memsz;    // [40..47] size in memory (>= p_filesz)
    uint64_t p_align;    // [48..55] alignment (0x1000 in our subject)
} Elf64_Phdr;            // 56 bytes total
```

The struct members we touch in this series, grouped by purpose, are
listed below.

### `p_type` — the segment type

Out of an endless list, the p_types that always show up are 4.
The `= number` is the type ID fixed by the ELF specification:

```
   PT_LOAD     (= 1)   Indicates a range to place in memory and its protection attributes
                       (4 entries in our subject)
   PT_DYNAMIC  (= 2)   The .dynamic section lives inside this segment
                       (used in Step 4)
   PT_INTERP   (= 3)   The content of this segment is a path string to the dynamic linker
                       (= "/lib64/ld-linux-x86-64.so.2")
   PT_PHDR     (= 6)   This segment itself points to the "program header table"
```

### `p_offset` / `p_vaddr` — address-related

- `p_offset` — offset from the start of the file (in bytes)
- `p_vaddr` — address in memory

`p_vaddr` is an "address value in the ELF" as seen in Chapter 01, so the
actual VA is `base_main + p_vaddr`. For example, the `p_vaddr` of the
program header that `.text` belongs to is `0x1000`, and in one run where
`base_main = 0x5555_5555_4000`, the actual head of this segment is
`0x5555_5555_5000`. The next time it starts, `base_main` changes, so the
segment's address changes too.

### `p_filesz` / `p_memsz` — size-related

- `p_filesz` — number of bytes read from the file
- `p_memsz` — number of bytes reserved in memory (`p_memsz >= p_filesz`)

The difference when `p_memsz > p_filesz` is a region that does not exist
in the file, which the kernel zero-initializes (= zero-initialized
regions such as `.bss`). In our subject, in the PT_LOAD that contains
`.data` / `.bss`, 8 bytes fall into this category (concrete example in
the PT_LOAD section further down).

### `p_flags` — R/W/X

Page protection attributes. `.text` is `R-X`, `.rodata` is `R--`,
`.data` / `.bss` are `RW-`, and so on — each segment is given the
minimum necessary permissions.

### `p_paddr` / `p_align`

`p_paddr` is the physical address. In Linux user processes it is not
used (in our subject it happens to equal `p_vaddr`, but they are not
always the same).
`p_align` is the alignment. In our subject it is `0x1000` (= 4KB page).

---

## Output of readelf -l main

```
$ readelf -l main

Elf file type is DYN (Position-Independent Executable file)
Entry point 0x1050
There are 13 program headers, starting at offset 64

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  PHDR           0x0000000000000040 0x0000000000000040 0x0000000000000040
                 0x00000000000002d8 0x00000000000002d8  R      0x8
  INTERP         0x0000000000000318 0x0000000000000318 0x0000000000000318
                 0x000000000000001c 0x000000000000001c  R      0x1
      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  LOAD           0x0000000000000000 0x0000000000000000 0x0000000000000000
                 0x0000000000000630 0x0000000000000630  R      0x1000
  LOAD           0x0000000000001000 0x0000000000001000 0x0000000000001000
                 0x0000000000000159 0x0000000000000159  R E    0x1000
  LOAD           0x0000000000002000 0x0000000000002000 0x0000000000002000
                 0x00000000000000dc 0x00000000000000dc  R      0x1000
  LOAD           0x0000000000002da0 0x0000000000003da0 0x0000000000003da0
                 0x0000000000000278 0x0000000000000280  RW     0x1000
  DYNAMIC        0x0000000000002db0 0x0000000000003db0 0x0000000000003db0
                 0x0000000000000210 0x0000000000000210  RW     0x8
  NOTE           ...
  GNU_PROPERTY   ...
  GNU_EH_FRAME   ...
  GNU_STACK      ...
  GNU_RELRO      ...
```

The 4 p_types worth focusing on are:

```
   PHDR        offset 0x40, size 0x2d8  (0x2d8 = 13 * 56 = 728)
                 -> matches e_phoff / e_phnum

   INTERP      the string "/lib64/ld-linux-x86-64.so.2"  (28 bytes)
                 -> used in Step 3

   LOAD x 4    covered below (4 LOADs in our subject)

   DYNAMIC     virtual address 0x3db0, size 0x210
                 -> used in Step 4
```

---

## PT_LOAD — pasting into memory

Placing the 4 `PT_LOAD`s side by side:

```
   #   p_type  p_offset    p_vaddr     p_filesz   p_memsz    flags
   --  ------  ----------  ----------  ---------  ---------  -----
   1   LOAD    0x0000      0x0000      0x0630     0x0630     R
   2   LOAD    0x1000      0x1000      0x0159     0x0159     R E       <-- .text
   3   LOAD    0x2000      0x2000      0x00dc     0x00dc     R         <-- .rodata
   4   LOAD    0x2da0      0x3da0      0x0278     0x0280     RW        <-- .data/.bss
```

Turning this into a picture (the 4 `PT_LOAD`s in the file being placed
into the virtual address space via the kernel's `mmap`):

```
   FILE (on disk)                       MEMORY (after mmap by kernel)
   ==============                       =============================

   offset 0x0000                        vaddr 0x0000 + base_main
       +-----------------+                  +-----------------+
       | ELF header      |                  | ELF header etc. |
       | Program headers | ---LOAD#1--->    | (R only)        |
       | INTERP string   |                  |                 |
       | .note ...       |                  |                 |
       +-----------------+                  +-----------------+
   offset 0x1000                        vaddr 0x1000 + base_main
       +-----------------+                  +-----------------+
       | .plt            |                  | .plt            |
       | .text (code)    | ---LOAD#2--->    | .text           |  R-X
       |  (add@plt ...)  |                  |  (add@plt ...)  |
       +-----------------+                  +-----------------+
   offset 0x2000                        vaddr 0x2000 + base_main
       +-----------------+                  +-----------------+
       | .rodata         | ---LOAD#3--->    | .rodata         |  R--
       | .eh_frame       |                  |                 |
       +-----------------+                  +-----------------+
   offset 0x2da0                        vaddr 0x3da0 + base_main
       +-----------------+                  +-----------------+
       | .init_array     |                  | .init_array     |
       | .dynamic        | ---LOAD#4--->    | .dynamic        |  RW-
       | .got  .got.plt  |                  | .got  .got.plt  |
       | .data           |                  | .data           |
       |                 |                  | .bss   (zero)   | <-- p_memsz is
       +-----------------+                  +-----------------+     8 bytes larger
```

LOAD#4 is the only one where `p_offset (0x2da0)` and `p_vaddr (0x3da0)`
are **misaligned**. This is an instruction that says, "on file, place it
packed up against the previous segment, but in memory place it beyond a
fresh page boundary (further past 0x3000)."

LOAD#4 has `p_memsz (0x280) > p_filesz (0x278)`, and the difference of 8
bytes is zero-initialized by the kernel as `.bss`.


---

## PT_INTERP — the dynamic linker's path

The content of PT_INTERP is **only a string**. Reading
`p_offset = 0x318`, `p_filesz = 0x1c (= 28 bytes)`:

```
   2f 6c 69 62 36 34 2f 6c 64 2d 6c 69 6e 75 78 2d
   78 38 36 2d 36 34 2e 73 6f 2e 32 00

   /  l  i  b  6  4  /  l  d  -  l  i  n  u  x  -
   x  8  6  -  6  4  .  s  o  .  2  \0
```

The kernel reads this string and executes
`/lib64/ld-linux-x86-64.so.2`. The dynamic linker specified by this
PT_INTERP is what **handles the dynamic linking work required by ./main**.

### The dynamic linker itself is also an ELF file

`/lib64/ld-linux-x86-64.so.2`, which PT_INTERP points to, is also an
**ELF file** (`Type: DYN`). Its content is machine code — it is not a
special format.
(From here on we sometimes abbreviate it as `ld-linux.so` in this
document, but that always refers to this same file.)

From the kernel's perspective, the load procedure is:

- Load main         → read the ELF header → read the Program headers → mmap the PT_LOADs
- Load ld-linux.so  → **exactly the same procedure** just repeated once more

Since ld-linux.so is also `ET_DYN`, the kernel maps it at a different
address from main. We write this starting position as **`base_ld`** (a
different address from `base_main`, coexisting in the same process's
virtual address space).

### Handover from the kernel to the dynamic linker

Once the kernel has finished mapping ld-linux.so, control is passed to
ld-linux.so's `e_entry`. It does **not** yet jump into main's `e_entry`.
The dynamic linker prepares various things, and only at the end jumps to
main's `e_entry` — that is the flow (details in Step 3).

Why isn't main called directly: main depends on `libmylib.so` /
`libc.so.6`, and unless those are loaded, the `call add@plt` — the call
to the add() function — fails. Preparing that is `ld-linux.so`'s job,
and `ld-linux.so` itself does not depend on any other ELF, so
`ld-linux.so` alone can run independently first.

---

## PT_DYNAMIC — a guide to .dynamic

The full set of metadata needed for dynamic linking lives in the
`.dynamic` section.
`.dynamic` is a table where entries beginning with `DT_` — such as
`DT_NEEDED` / `DT_SYMTAB` / `DT_STRTAB` — are lined up (the details of
its content are read in Step 4).

And the program header PT_DYNAMIC **points to "where that `.dynamic` is
in memory"**. PT_DYNAMIC itself contains no metadata; it merely conveys
the location (p_vaddr) and size (p_filesz) of the `.dynamic` body. The
dynamic linker follows this to reach `.dynamic`, and from there begins
the series of dynamic linking tasks.

```
   p_type   = PT_DYNAMIC
   p_offset = 0x2db0        <-- location in the file
   p_vaddr  = 0x3db0        <-- memory address at runtime
   p_filesz = 0x210         <-- 16 bytes * N entries
```


---

## The kernel's job and memory at this point

Summarizing what the kernel does immediately after `./main` is executed:

```
   1. Read the ELF header                              (detailed in Step 1)
   2. Read the Program headers                         (Step 2 = this chapter)
        - mmap each PT_LOAD → place main in the VA space (base_main)
        - Load ld-linux.so (referenced by PT_INTERP) in the same way (base_ld)
   3. Jump to ld-linux.so's e_entry                    (→ on to Step 3)
```

That is the kernel's part. From here on, ld-linux.so is in motion.
At this point the VA space looks like this:

```
   virtual address space (example)

       low   +-------------------------+
             |                         |
             | (empty)                 |
             |                         |
   base_main +-------------------------+ <-- determined by ASLR
             | main: LOAD#1 R--        |
             +-------------------------+
             | main: LOAD#2 R-X .text  |
             +-------------------------+
             | main: LOAD#3 R-- .rodata|
             +-------------------------+
             | main: LOAD#4 RW- .got   |
             |              .data .bss |
             +-------------------------+
             |                         |
             | (empty)                 |
             |                         |
   base_ld   +-------------------------+ <-- also determined by ASLR
             | ld-linux.so: LOAD#1 R-X |
             +-------------------------+
             | ld-linux.so: LOAD#2 RW- |
             +-------------------------+
             |                         |
             :                         :
       high
```

---

## What we nailed down this time (points to carry into the next chapter)

```
   [x] Since PIE, actual VA = base + p_vaddr (base is independent for main and ld-linux.so)
   [x] Each segment is mapped into memory according to PT_LOAD
       (the difference when p_memsz > p_filesz is zero-initialized as .bss)
   [x] The kernel passes control to the ld-linux.so pointed to by PT_INTERP (= on to Step 3)
   [x] PT_DYNAMIC tells us the location of .dynamic (= read in Step 4)
```

Next is **Step 3: Dynamic linker startup** —
starting immediately after `jumping to ld-linux.so's e_entry`,
and following it all the way until we land on `main's e_entry`.
