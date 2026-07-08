![](../../images/07.png)

# Step 7. Reaching the Real Function via Lazy Binding

By the end of Step 6, we had the static structure of the **state in
which `add`'s actual VA has not yet been written into `.got.plt[3]`**
(= "the unresolved state"). In this step, when `main` first calls
`add(2, 3)`, we follow the **lazy binding** that the resolver performs.

We then confirm that from the second call onward, `add`'s
address-resolution processing is skipped.

---

## Starting point

The 4 values inherited from Step 6 (all offsets within `main`'s image;
the actual VA is `base_main + each value`):

```
   add@plt                    = 0x1030
   PLT0                       = 0x1020
   location of .got.plt[3]    = 0x4000
   initial value of .got.plt[3] = 0x1036 (= add@plt+6)
```

From here, we follow the first execution of `call add@plt`.

---

## Information used for resolution

Before tracing the instruction sequence, let's confirm the roles of
`link_map` and `_dl_runtime_resolve`.

### What is `link_map`

It is a **linked-list data structure held internally by** ld-linux.so.
For each loaded ELF (main / libmylib.so / libc.so.6 / ld-linux.so
itself), there is one **link_map node**. The main members of a
link_map node (`struct link_map`):

- `l_addr` — the base address at which it was loaded
- `l_ld` — the location of that ELF's `.dynamic`
- `l_next` / `l_prev` — pointers to adjacent link_map nodes
- (others include cached symbol table and relocation table references)

Because the resolver cannot operate without knowing "**on behalf of
which ELF**" the request is, PLT0 passes the address of this link_map
node to the resolver.
What lives in `.got.plt[1]` is the address of that link_map node (the
first of the slots we saw in Step 6 that "ld-linux.so fills in at
startup").

Turning this into a picture, the relationship between the link_map
linked list (left) and the lookup scope table pointed to by main's
`l_scope` (right) is:

```
   link_map (linked list)                       main's lookup scope
                                                (= the search-order list pointed to by main's l_scope)

   +--------------------------+               +--------------------+
   |  main                    |               |  [0] main          |
   |    l_addr = base_main    |               |  [1] libmylib.so   |
   |    l_ld   = &.dynamic    |               |  [2] libc.so.6     |
   |    l_scope --------------|-------------->|  [3] ld-linux.so   |
   |    l_next ---------.     |               +--------------------+
   +--------------------|-----+
                        |
                        v
   +--------------------------+
   |  libmylib.so             |
   |    l_addr = base_libmylib|
   |    l_ld   = &.dynamic    |
   |    l_scope               |
   |    l_next ---------.     |
   +--------------------|-----+
                        |
                        v
                       ...     (continues with libc.so.6, ld-linux.so)
```

(The table on the right is **the substance of "the symbol search order
list" touched on in Step 5 § lookup scope**, and the `l_scope` field of
the `link_map` is precisely a pointer to this table.)

What lives in `.got.plt[1]` is a pointer to the head (`main`'s) link_map
node. The resolver then, from here, walks through `l_scope` to
reference the table on the right, and searches each ELF's `.dynsym`
from the top down (in our subject in this book (simple static
dependencies), the order of this table nearly matches the linked-list
order on the left).

### Where does `_dl_runtime_resolve` live

It is a **function inside ld-linux.so**, and does not exist in main,
libmylib.so, or libc.so.6. At startup, ld-linux.so writes the address
of that function into `main`'s `.got.plt[2]` (the second of the slots
we saw in Step 6 that "ld-linux.so fills in at startup"). This is
precisely why the 2nd instruction of PLT0 we saw in Step 6,
`jmp [.got.plt[2]]`, is able to launch this `_dl_runtime_resolve`
(see Step 6 § The assembly code of PLT0).

## Details of add's first call

Starting from `call 0x1030 <add@plt>` inside `main`, we lay out
instructions the CPU executes in order, right up to landing on `add`'s
machine code.

The PLT/GOT we are chasing (Step 6's Big Picture, re-drawn with PLT0's
contents and `push 0` filled in):

```
   .text (RX)                 .plt (RX)                .got.plt (RW)
   +----------------+         +----------------+       +---------------+
   | main:          |         | PLT0:          |       | [0] &.dynamic |
   |   ...          |         |   push *[gp1]  |------>| [1] link_map  |
   |   call add@plt | -.      |   jmp  *[gp2]  |------>| [2] resolver  |
   |   pop rbp      |  |      +----------------+       +---------------+
   +----------------+  |      | add@plt:       |       | [3] for add   |<--,
                       '----->|   jmp *[gp3]   |----,  +---------------+   |
                              |   push 0       |    |  | [4] for printf |   |
                              |   jmp PLT0     |    |  +---------------+   |
                              +----------------+    |                      |
                                                    +----------------------'
                                                    (initial value: add@plt+6)
```

(gp1 / gp2 / gp3 are shorthand for `.got.plt[1]` / `[2]` / `[3]`.)

```
   Time  Instruction executed              What happens
   ----  ------------------------------  -----------------------------------
   T0    main: call add@plt              Push the return address (= address 0x114c of pop rbp, the instruction after call),
                                          PC <- 0x1030 (= add@plt)

   T1    add@plt: jmp [rip+0x2fca]       rip (= 0x1036, the address of the next instruction (push 0)) + 0x2fca = 0x4000
                                          = the address of .got.plt[3]
                                          (the slot's actual VA = base_main + 0x4000)
                                          slot content = base_main + 0x1036 (= actual VA of add@plt+6)
                                          PC <- base_main + 0x1036
                                          (= add@plt+6, loopback to the location of the next instruction push 0)

   T2    add@plt+6: push 0               Push reloc index = 0 onto the stack

   T3    add@plt+11: jmp 0x1020          PC <- PLT0 (0x1020)

   T4    PLT0: push [rip+0x2fca]         Push [.got.plt[1]] = link_map

   T5    PLT0+6: jmp [rip+0x2fcc]        [.got.plt[2]] = _dl_runtime_resolve
                                          PC <- resolution routine inside ld-linux.so

   T6    _dl_runtime_resolve             Save the registers needed to preserve add's arguments
                                          (still in the assembly world)
   T7    ↓
   T8    Call _dl_fixup                  **The C world for the first time here**
                                          (_dl_fixup is a C function in elf/dl-runtime.c)
   T9    ↓
   T10   Find add's real address         (= the procedure of Step 5)
   T11   Write into .got.plt[3]
   T12   _dl_runtime_resolve             Restore the registers saved in T6,
                                          jmp to add's actual VA and exit
                                          PC <- base_libmylib + 0x10f9

   T13   add: ...                        add's machine code runs
   T14   ↓
   T15   ret                              PC <- next instruction of main
                                          (the return address pushed at T0)

   T16   main: pop rbp                   main continues (T0's return address 0x114c)
```

T0-T5 is the "PLT-driven preamble",
T6-T11 is the "resolution routine's job",
T12-T15 is the "real function's execution".

---

## The state of the stack

The stack at time T6 (immediately after entering the resolver):

```
   high address
   +--------------------+
   |  main's return addr|   <-- pushed by main at T0
   +--------------------+
   |  reloc index = 0   |   <-- pushed by add@plt at T2
   +--------------------+
   |  link_map ptr      |   <-- pushed by PLT0 at T4 (top of stack = RSP)
   +--------------------+
   |  ...               |       (region below RSP is unused)
   low address
```

Resolver-entry state:

- **Stack**: the `link_map` and `reloc_index = 0` pushed by the PLT (see figure above)
- **RDI / RSI**: still hold the arguments (`edi = 2`, `esi = 3`) of the
  originally intended call `add(2, 3)`. If clobbered, `add(2, 3)`
  cannot be called.

Therefore, `_dl_runtime_resolve` (hand-written assembly) first saves
the **caller-saved register group** (the side that carries arguments
and temporary values during function calls, `RDI` / `RSI` included in
this group), then takes `link_map` / `reloc_index` off the stack, and
calls the C function `_dl_fixup(link_map, reloc_index)` (at this point,
in accordance with the System V x86_64 ABI, it puts the 1st argument
in `RDI` and the 2nd in `RSI`).

---

The key points here are 2:

1. **`_dl_fixup`'s return value = the actual VA of `add`** (= `base_libmylib + 0x10f9`).
2. **The resolver jumps to `add` with `jmp`, not `call`** (T12). Thus
   `add`'s trailing `ret` can return directly to main's `pop rbp` (see
   figure below).

The stack immediately before the resolver jmps to add (= the moment add
is called):

```
   high address
   +--------------------+
   |  main's return addr|   <-- top of stack (RSP)
   +--------------------+       (pushed at T0, still there through T6→T12)
   |  ...               |
   low address
```

At the moment we enter add, the top of the stack is **main's return
address**, so `ret` at the end of add pops it and returns straight back
to main's `pop rbp`.

From here we look at these details in order — the inside of
`_dl_fixup`, the value written into `.got.plt[3]`, `add`'s execution
and return to `main`.

---

## Inside _dl_fixup

It combines the materials from Steps 4-6 (`.dynamic` / `.dynsym` /
`.dynstr` / `.rela.plt`) to find `add`'s actual VA and write it into
`.got.plt[3]` — nothing conceptually new here. What we look at here is
how the 2 arguments are used:

- **`link_map`**: **main's** link_map node passed by PLT0 from
  `.got.plt[1]`. From here we walk main's lookup scope (see Step 5) and
  use it as the starting point for symbol resolution (in our subject in
  this book, this scope nearly matches the linked-list order
  `main → libmylib.so → ...`).
- **`reloc_index = 0`**: the value pushed by `add@plt` (T2) via
  `push 0`. It is an index that picks the N-th entry of `.rela.plt`,
  and **`0` points to the JUMP_SLOT entry for `add`**. By looking at
  just this one entry, both "which symbol (`add`)" and "which GOT slot
  (`.got.plt[3]`)" are identified (see Step 6 § R_X86_64_JUMP_SLOT
  relocation).

Summarized in 3 lines, the flow is:

1. From `reloc_index = 0`, read `.rela.plt[0]` (JUMP_SLOT) → the
   target symbol `add` and the write destination `.got.plt[3]` are known
2. Walk the lookup scope table pointed to by `main`'s `link_map`'s
   `l_scope` from top down, search for `add`, and find the actual VA
   (`base_libmylib + 0x10f9`) (Step 5)
3. Write that value into `.got.plt[3]`, and also return it as the return value

---

## The rewrite of .got.plt[3]

The value `_dl_fixup` writes into `.got.plt[3]` in step 3:

```
   value = base_libmylib + 0x10f9   (= actual VA of add obtained in Step 5)
```

Before and after the rewrite:

```
   .got.plt[3] before:   base_main + 0x1036     (= actual VA of add@plt+6, the unresolved marker)
                  --->
   .got.plt[3] after:    base_libmylib + 0x10f9 (= head of add's machine code)
```

With that, the GOT slot is rewritten from its initial value to the
actual VA of `add`. This value is used until the process ends.

---

## add's execution and return to main

After `_dl_runtime_resolve` `jmp`s to `add`'s address at T12:

```
   T13. add:                       ; base_libmylib + 0x10f9
            mov  eax, esi          ; eax = b = 3
            add  eax, edi          ; eax += a = 2 + 3 = 5
            ret                    ; pop the return address, PC <- next in main
```

`ret` pops the return address from the stack.
Important here: the reloc index pushed at T2 by `add@plt`, and the
link_map pushed at T4 by PLT0 — these have already been **popped and
consumed by the assembly inside `_dl_runtime_resolve`**.

Therefore, the top of the stack is **the original return address that
main pushed at T0**. Thus `add`'s `ret` returns cleanly to main. This
is the reason for using `jmp` (a tail call).

---

## The 2nd call

Supposing `main` had called `add` twice, the 2nd call would go like
this:

```
   T0'.  main: call add@plt        ; push return addr, PC <- 0x1030

   T1'.  add@plt: jmp [.got.plt[3]] ; now = base_libmylib + 0x10f9
                                    ; PC <- add function

   T2'.  add: ...
            ret                     ; back to main
```

T2-T11 **disappear entirely**.
Inside the PLT, only the indirect jump referencing GOT is executed.

That is why this is called **"lazy binding"**.
The cost of resolution is paid only on the first call, and thereafter
it is as close to a direct call as possible.

---

## Correspondence between commands and each step

When looking at the output of `readelf -h` / `readelf -l` /
`readelf -d` / `readelf -s` / `readelf -r` / `objdump -d`, one can map
each output to **where in this flow that information is used**:

```
   readelf -h main      ->  Step 1   (ELF header)
   readelf -l main      ->  Step 2   (PT_LOAD/PT_INTERP/PT_DYNAMIC)
   ldd main             ->  Step 3,4 (result of DT_NEEDED resolution)
   readelf -d main      ->  Step 4   (DT_NEEDED, DT_STRTAB, ...)
   readelf -s main      ->  Step 5   (.dynsym)
   readelf -r main      ->  Step 6   (R_X86_64_JUMP_SLOT)
   objdump -d -j .plt   ->  Step 6,7 (the 3 instructions of a PLT entry)
   objdump -d main      ->  Step 6,7 (call add@plt and the body of main)
```

---

## What we nailed down this time

```
   [x] On the 1st call, we reach _dl_fixup via PLT0
       (= using the loopback structure of the GOT slot's initial value)
   [x] _dl_fixup combines, in a single function, the materials seen in Steps 4-6
       (DT_JMPREL / DT_SYMTAB / DT_STRTAB / R_X86_64_JUMP_SLOT)
   [x] From the 2nd call onward, we proceed to the real function via an indirect jump
       through the GOT. This is the mechanism called lazy binding.
```

---

## Closing

That completes our joint trace from Step 1 through Step 7. Which
information inside the ELF file is used in what order, so that from
`main` the call to `libmylib.so`'s `add(2, 3)` is made to work — we have
traced the whole thing as a single story by following the actual binary
of one subject.

From now on, when peeking at another ELF via `readelf` or `objdump`, if
`PT_LOAD` / `DT_NEEDED` / `.dynsym` / `.got.plt` / `R_X86_64_JUMP_SLOT`
and friends click into place as "that's the thing from that Step", then
that is the destination this series aimed at.

The end.

