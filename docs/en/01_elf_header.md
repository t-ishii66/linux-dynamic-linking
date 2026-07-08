![](../../images/01.png)

# Step 1. The ELF Header

## What is an ELF file

ELF (Executable and Linkable Format) is the object-file format used on
Linux/Unix-family systems. Executables, shared libraries (`.so`), and
object files (`.o`) are all ELF files.

The executable `main` and the dynamic library `libmylib.so` we use as our
subject are both ELF files.

---

## The overall structure of an ELF file

Laid out from the beginning of the file, the image is:

```
   offset 0
       +------------------------+
       |  ELF header            |   Fixed 64 bytes (ELF64)
       |  (Elf64_Ehdr)          |   Tells you where the Program headers
       |                        |   and Section headers are located
       +------------------------+
       |                        |
       |  Program headers       |   <-- Array of program headers.
       |  Elf64_Phdr * N        |
       |                        |
       +------------------------+
       |                        |
       |   ... segments ...     |
       |                        |
       |   .text     (machine code) |
       |   .rodata   (constants)    |
       |   .data     (initialized)  |
       |   .dynamic             |
       |   .plt   .got          |
       |   .dynsym .dynstr      |
       |   .gnu.hash            |
       |   ...                  |
       |                        |
       +------------------------+
       |                        |
       |  Section headers       |   <-- For linking / objdump.
       |  Elf64_Shdr * M        |       Not used at runtime.
       |                        |
       +------------------------+
   end of file
```

In other words, an ELF file is structured so that **"the first 64 bytes are the ELF header, and using the contents of the ELF header, you can decode the whole file"**.

---

## The structure of the ELF header (Elf64_Ehdr)

The ELF header is a 64-byte struct called `Elf64_Ehdr`.
Written in C it looks like this (defined in `/usr/include/elf.h`):

```c
typedef struct {
    unsigned char e_ident[16];   // [ 0..15] magic, etc.
    uint16_t      e_type;        // [16..17] file type
    uint16_t      e_machine;     // [18..19] CPU type
    uint32_t      e_version;     // [20..23] = 1
    uint64_t      e_entry;       // [24..31] entry point
    uint64_t      e_phoff;       // [32..39] file offset of the Program header table
    uint64_t      e_shoff;       // [40..47] file offset of the Section header table
    uint32_t      e_flags;       // [48..51] CPU-specific flags
    uint16_t      e_ehsize;      // [52..53] size of this header itself (=64)
    uint16_t      e_phentsize;   // [54..55] size of one Program header entry (=56)
    uint16_t      e_phnum;       // [56..57] number of Program headers
    uint16_t      e_shentsize;   // [58..59] size of one Section header entry (=64)
    uint16_t      e_shnum;       // [60..61] number of Section headers
    uint16_t      e_shstrndx;    // [62..63] index of the section-name table
} Elf64_Ehdr;                    // 64 bytes total
```

The 5 struct members this series touches are the following.

### `e_type` — the file type

```
   ET_REL  = 1   Relocatable file (.o)
   ET_EXEC = 2   Executable file (fixed address)
   ET_DYN  = 3   Shared library / PIE executable
```

Since our series uses **PIE**,
both `./main` and `libmylib.so` are `ET_DYN`.

**PIE** (Position-Independent Executable) is an executable file that is
loaded via the same mechanism as a shared library (`.so`). Every address
value inside the ELF is written as "an offset that assumes `base = 0`",
and the actual VA (Virtual Address) is obtained by adding the base
determined at startup:

```
   actual VA (Virtual Address) = base + (address value in the ELF)
```

We write the base address at which `./main` was loaded as `base_main`
throughout this series
(for base labels of other ELFs and the relationship with ASLR, see
[Appendix A: Terminology and Notation Conventions](./08_notation.md)).

### `e_entry` — the program's start location (address in memory)

`e_entry` is the program's start location.
Unlike file offsets such as `e_phoff`, it is an address in memory. The
"base + address value in the ELF" rule above applies, so the actual VA
is `base_main + e_entry` (details in Step 2).

### `e_phoff` / `e_phentsize` / `e_phnum` — location of the Program header table

```
   e_phoff       Where the program header array starts, as a byte offset from the start of the file   (= starting position)
   e_phentsize   Size in bytes of one entry in the program header array                              (= stride)
   e_phnum       Number of entries lined up                                                          (= count)
```

The side that reads the ELF (the kernel at startup time, and in a later
chapter `ld-linux.so` too) uses these 3 values to read out the range
`[e_phoff, e_phoff + e_phentsize*e_phnum)` as the Program header array.
The kernel reads directly from `e_phoff` in the file, and `ld-linux.so`
obtains the position from the already-mapped region and from `AT_PHDR`
etc. in the auxv (details in Step 2 / Step 3).

---

## Looking at a real binary (hexdump)

Example output of `hexdump -C main | head -4`:

> Note: values will vary somewhat depending on the gcc version and
> optimization options.
> What follows is a typical byte layout for a PIE executable.

```
Offset    Bytes                                            ASCII
--------  -----------------------------------------------  ----------------
00000000  7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00  .ELF............
00000010  03 00 3e 00 01 00 00 00 50 10 00 00 00 00 00 00  ..>.....P.......
00000020  40 00 00 00 00 00 00 00 68 36 00 00 00 00 00 00  @.......h6......
00000030  00 00 00 00 40 00 38 00 0d 00 40 00 1f 00 1e 00  ....@.8...@.....
```

Applying this byte sequence to the struct above:

```
Offset       Bytes                     Meaning
----------   ----------------------    ----------------------------------------
[ 0.. 3]    7f 45 4c 46               Magic ".ELF"
[ 4]        02                        EI_CLASS    = 2  -> ELF64
[ 5]        01                        EI_DATA     = 1  -> little endian
[ 6]        01                        EI_VERSION  = 1
[ 7]        00                        EI_OSABI    = 0  -> System V
[ 8]        00                        EI_ABIVERSION = 0
[ 9..15]    00 00 00 00 00 00 00      Padding
                                      ----- end of e_ident[16] -----
[16..17]    03 00                     e_type      = 3        -> ET_DYN
[18..19]    3e 00                     e_machine   = 0x3e=62  -> EM_X86_64
[20..23]    01 00 00 00               e_version   = 1
[24..31]    50 10 00 00 00 00 00 00   e_entry     = 0x1050
[32..39]    40 00 00 00 00 00 00 00   e_phoff     = 0x40   (= byte 64)
[40..47]    68 36 00 00 00 00 00 00   e_shoff     = 0x3668
[48..51]    00 00 00 00               e_flags     = 0
[52..53]    40 00                     e_ehsize    = 0x40 = 64
[54..55]    38 00                     e_phentsize = 0x38 = 56
[56..57]    0d 00                     e_phnum     = 13
[58..59]    40 00                     e_shentsize = 0x40 = 64
[60..61]    1f 00                     e_shnum     = 31
[62..63]    1e 00                     e_shstrndx  = 30
```

Because this is little-endian, note that multi-byte numeric values are
read in reverse order:

```
   byte layout:   50 10 00 00 00 00 00 00
                  ^^ ^^ ^^ ^^ ^^ ^^ ^^ ^^
                  low order              high order
   as a number:   0x0000000000001050   ->   0x1050
```

---

## The file structure the ELF header reveals

```
   File start                                    Virtual address
   ==========                                    ===============

   offset 0
       +------------------------+
       |  Elf64_Ehdr            |  64 bytes
       |  (what we just read)   |
       +------------------------+ <-- e_phoff = 0x40
       |  Program header [0]    |  56 bytes
       +------------------------+
       |  Program header [1]    |  56 bytes
       +------------------------+
       |   ...                  |   13 entries
       +------------------------+
       |  Program header [12]   |  56 bytes
       +------------------------+
       |                        |
       :  ... machine code, data ... :     <-- Somewhere in here,
       :                        :             pointed to by e_entry = 0x1050,
       :                        :             is the first instruction of main.
       +------------------------+ <-- e_shoff = 0x3668
       |  Section header table  |     (not used at runtime)
       +------------------------+
   end
```

Key points:

- Because `e_phoff = 0x40`, the Program headers begin right after the ELF header
- `e_phentsize = 56` × `e_phnum = 13` = `728` bytes is the size of the entire Program header table

---

## Viewing with readelf -h main

If `readelf` decodes the same content we saw in the hexdump above:

```
$ readelf -h main
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x1050
  Start of program headers:          64 (bytes into file)
  Start of section headers:          13928 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         13
  Size of section headers:           64 (bytes)
  Number of section headers:         31
  Section header string table index: 30
```

It corresponds perfectly to the bytes we saw with hexdump.
The goal is to reach a state where the numbers on the left (offsets) and
the display on the right line up in your head.

---

## What we nailed down this time (points to carry into the next chapter)

```
   [x] e_entry is an address in memory (actual VA = base_main + e_entry)
   [x] e_phoff / e_phentsize / e_phnum let you walk the Program header array
       (= the entry point of the next chapter, Step 2)
   [x] This series assumes PIE (ET_DYN)
```

Next is **Step 2: Program headers** — this is where "how it is laid out in memory" is decided.
