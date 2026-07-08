![](../../images/10.png)

# Appendix C. The Self-Relocation Mechanism

Step 3 § "Dynamic linking by ld-linux.so" A — **self-relocation**

— the processing that rewrites the actual VA references inside itself,
accounting for `base_ld` —

---

## Why is it necessary

`ld-linux.so` is `ET_DYN`. Like `main` or `libmylib.so`, the absolute
address values in the file are written as "offsets assuming `base = 0`".
The actual VA is that plus the `base_ld` determined at runtime.

Representative cases that need rewriting:

- Initializers of global variables (`static int *p = &x;` — the location of `x` is embedded into `p`)
- Arrays of function pointers (`static void (*handlers[])() = { fn1, fn2 };` — each element embeds the location of a function)
- String tables (`static const char *msgs[] = { "hello", "world" };` — each element embeds the location of a string literal)

These want to point at "the location of `x` inside ld-linux.so", so on
file only the `base = 0`-anchored offset of `x` is written. `base_ld`
is added to convert it into an actual VA.

---

## The instruction book `.rela.dyn` and `Elf64_Rela`

"Where to rewrite" and "how to rewrite" are dictated by the relocation
entries lined up in `ld-linux.so`'s own `.rela.dyn`.

- **Where `.rela.dyn` is placed**: inside the 1st `PT_LOAD` (R only)
  (since it is only read, not written, R only is enough)
- **How to know `.rela.dyn`'s location and size**: follow from
  **`DT_RELA` / `DT_RELASZ` / `DT_RELAENT`** inside `.dynamic`, which is
  pointed to by `PT_DYNAMIC` (the position of the table, its size, and
  the byte size of one entry, respectively)
- **Where the rewrite targets actually live**: inside the 4th `PT_LOAD`
  (RW), which contains `.got` and friends (needs RW because it is
  written to)

That is, self-relocation is processing that straddles 2 kinds of
segments with different properties: **"the instruction book is in an
R-only PT_LOAD, and the write target is in an RW PT_LOAD."**

Each entry is an `Elf64_Rela` structure of 24 bytes:

```c
typedef struct {
    uint64_t r_offset;   // where to rewrite (offset within the ELF)
    uint64_t r_info;     // type and (if any) symbol number
    int64_t  r_addend;   // addend for computing the value
} Elf64_Rela;
```

These are lined up as an array in `.rela.dyn`:

```
   .rela.dyn   (DT_RELASZ bytes of region starting where DT_RELA points)
               (each entry 24 bytes = DT_RELAENT)

       +-----------------------------+
       | r_offset = 0x21d8           |
       | r_info   = R_X86_64_RELATIVE|  ← entry [0]
       | r_addend = 0x1e10           |
       +-----------------------------+
       | r_offset = 0x21e0           |
       | r_info   = R_X86_64_RELATIVE|  ← entry [1]
       | r_addend = 0x1e30           |
       +-----------------------------+
       | r_offset = 0x21e8           |
       | r_info   = R_X86_64_RELATIVE|  ← entry [2]
       | r_addend = 0x1e50           |
       +-----------------------------+
       :                             :
       +-----------------------------+
       | r_offset = ...              |
       | r_info   = R_X86_64_RELATIVE|  ← entry [N-1]
       | r_addend = ...              |
       +-----------------------------+

   N = DT_RELASZ / DT_RELAENT = DT_RELASZ / 24
   (Numbers are a typical example. In the actual glibc ld-linux.so there are hundreds of entries.)
```

The general story of relocation entries (breakdown of `r_info`, other
relocation types, etc.) is covered in Step 6. In this appendix we
treat it as "an array listing where and how to rewrite".

---

## The type used in self-relocation, `R_X86_64_RELATIVE`

Almost the only relocation type used in self-relocation. Its meaning is:

```
   *(base_ld + r_offset) = base_ld + r_addend
```

That is, just "write the value `base_ld + r_addend` at the address
`base_ld + r_offset`". There is no need whatsoever to look up a symbol
name or hunt for an address in another `.so`. It is done with just
adding `base_ld`.

Most of the entries in `ld-linux.so`'s `.rela.dyn` are
`R_X86_64_RELATIVE`. Other relocation types that require symbol
resolution (`JUMP_SLOT`, `GLOB_DAT`, etc.) are either not used in
`ld-linux.so` itself or handled by later ordinary relocation (Step 3
step E).

---

## A concrete example — executing entry [0]

Let's actually process `entry [0]` from the `.rela.dyn` table above.
Suppose:

- `ld-linux.so`'s C source has declarations like
  `static int x; static int *p = &x;`, and `x` is placed at ELF offset
  `0x1e10`, and `p` at `0x21d8`
- Startup ASLR pinned `base_ld = 0x7f4d2e9b2000`
  (= the same value as Step 3 § Example auxv display)

Entry values:

```
   r_offset = 0x21d8                <-- location of p (offset within the ELF)
   r_info   = R_X86_64_RELATIVE
   r_addend = 0x1e10                <-- location of x (offset within the ELF)
```

### Memory before the rewrite

```
   Actual VA            Content
   ----------------     ---------------------------------------
   0x7f4d2e9b3e10       int x (= 0)                              <-- body of x
       ︙
   0x7f4d2e9b41d8       int *p = 0  (provisional)                <-- content of p. does not yet point at x
```

### Applying the rewrite formula

Applying `*(base_ld + r_offset) = base_ld + r_addend`:

```
   LHS = *(0x7f4d2e9b2000 + 0x21d8) = *(0x7f4d2e9b41d8)
   RHS =  0x7f4d2e9b2000 + 0x1e10  =  0x7f4d2e9b3e10
```

### Memory after the rewrite

```
   Actual VA            Content
   ----------------     ---------------------------------------
   0x7f4d2e9b3e10       int x (= 0)                              <-- no change
       ︙
   0x7f4d2e9b41d8       int *p = 0x7f4d2e9b3e10                  <-- the actual VA of &x has been set
```

With this, `p` is in a state where it points at the actual VA of `x`,
and if the code reads `*p`, the value of `x` is obtained. Applying the
same processing to the remaining `N-1` entries of `.rela.dyn` brings
every pointer reference inside `ld-linux.so` into the actual VA state.

---

## The flow

1. Obtain `base_ld` from `AT_BASE` (via auxv).
2. Find the location of its own Program header (since `e_phoff` is a
   file offset, convert it to a VA via the correspondence between the
   first `PT_LOAD`'s `p_offset` / `p_vaddr`. As in this subject, when
   the first `PT_LOAD` has `p_offset=0`, `p_vaddr=0`, the result
   coincidentally equals `base_ld + e_phoff`), and find the
   `PT_DYNAMIC` entry.
3. Read `.dynamic` and obtain `DT_RELA` / `DT_RELASZ` / `DT_RELAENT`.
   These are the location, size, and per-entry byte size (= 24) of
   `ld-linux.so`'s `.rela.dyn`.
4. Walk each entry of `.rela.dyn` in order, and for each
   `R_X86_64_RELATIVE`, execute
   `*(base_ld + r_offset) = base_ld + r_addend`.

These 4 steps are carefully written so as to be executable without
calling any global variable or external function at all (self-relocation
is not yet done, so pointers of global variables are still their
provisional values and cannot be used).

---

## After completion

Once self-relocation is done, global variables and absolute address
references inside `ld-linux.so` are all in the actual-VA state. From
here on, ordinary C functions can be freely called, and it proceeds to
Step 3's B onward (read auxv, load dependent libraries, run
relocations, ...).

Relocations for `main` or `libmylib.so` / `libc.so.6` are all done
together in Step 3's E. Beyond `R_X86_64_RELATIVE`, the types that
appear include `R_X86_64_GLOB_DAT` / `R_X86_64_JUMP_SLOT`, which
require symbol resolution (details in Step 5 and Step 6).
