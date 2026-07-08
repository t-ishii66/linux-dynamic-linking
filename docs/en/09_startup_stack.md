![](../../images/09.png)

# Appendix B. How to Read the Startup Stack

To read the stack figure (the picture where argc / argv / envp / auxv
are piled up) that appears in Step 3 § "How the kernel passes
information to the dynamic linker: the stack", the following prerequisites
are required:

- Which direction the stack grows
- Where `RSP` points to
- The C convention of `argc` / `argv` / `envp`
- The fact that the pointer array and the string bodies live in different places
- What `auxv` is

This appendix builds them up in order with the minimal example of
`./main`.

---

## The stack grows downward (toward lower addresses)

On x86-64, the stack grows **from higher addresses toward lower
addresses**. When you `push` a new value, the address decreases:

```
   high address
       +------+
       | A    |   <-- pushed first
       +------+
       | B    |   <-- pushed next
       +------+
       | C    |   <-- pushed last (= current top)
       +------+
   low address
```

In the figure, "what was pushed earlier" is at the top, and "what was
pushed later" comes at the bottom.

---

## RSP — the current position of the stack

The CPU register `RSP` (Stack Pointer) points at **the current top of
the stack = the address of the last value pushed**. A new push decreases
`RSP`, a pop increases it.

The `C` in the figure above (last pushed) is what the current `RSP`
points at. It is also the entry point at which the program first
accesses the stack.

---

## argc / argv / envp — startup arguments for a C program

The `main` of a C program receives startup arguments in the form

```c
int main(int argc, char **argv, char **envp);
```

- `argc` — the number of command-line arguments (including the program
  name itself)
- `argv` — a pointer array to the argument strings, terminated by
  `argv[argc] = NULL`
- `envp` — a pointer array to the environment-variable strings (of the
  form `"PATH=..."`), terminated by `NULL` at the end

These values are laid out on the stack by the kernel at `execve` time.
The program did not push them itself.

---

## The whole picture of the stack at `./main` startup

The stack the kernel prepares when `./main` is started with no arguments
(assuming a single environment variable `PATH=/usr/bin` as well):

```
   high address
       +-----------------------------+
       | (string bodies: ./main\0,   |
       |  PATH=...\0, etc.)          |
       +-----------------------------+
       | auxv: AT_NULL, 0            |
       | auxv: ... contents ...      |  <-- passes ELF info to ld-linux.so
       | auxv: AT_PHDR, ...          |
       +-----------------------------+
       | envp[1] = NULL              |
       | envp[0] = (address of PATH...) |
       +-----------------------------+
       | argv[1] = NULL              |
       | argv[0] = (address of ./main)  |
       +-----------------------------+
       | argc                        |  <-- RSP
       +-----------------------------+
   low address
```

Structural key points:

- At the very top (high-address side) sits the **string body**. It is
  not a fixed-size array but consecutive `\0`-terminated C strings.
- Below that is the **pointer array** — 3 blocks: auxv, envp[], argv[].
  Each element is 8 bytes (only auxv is 16 bytes: 8-byte key + 8-byte
  value); each is either an address pointing to a string body above, or
  `NULL`.
- At the very bottom (low-address side = where `RSP` points) is `argc`.

That is, "the pointer array" and "the string body" live in different
places — **a two-tier structure**.
`argv[0]` is not the string itself; it is the address where the string
is placed.

### The role of auxv

The `Auxiliary Vector` (auxv) piled above envp[] is
**a dedicated channel that passes information needed only by the side
loading the ELF (= `ld-linux.so`)**:

- Where main's Program headers are (`AT_PHDR`)
- Where main's `e_entry` is (`AT_ENTRY`)
- Where `ld-linux.so`'s own `base` is (`AT_BASE`)

Values that only the kernel knows at the moment `./main` is started are
conveyed to `ld-linux.so` via auxv.
auxv is an array of `(key, value)` pairs, terminated by an `AT_NULL = 0`
key.

For the meaning of the 5 auxv keys used in this series, see Step 3 §
The contents of the Auxiliary Vector (auxv).

---

## Back to the stack figure of Step 3

Reproducing the stack figure of Step 3:

```
   high address
       +------------------------------+
       | (env string data)             |   "PATH=/usr/bin\0"  and so on
       | (arg string data)             |   "./main\0"
       +------------------------------+
       | Auxiliary Vector (auxv)      |
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

Correspondence:

- The topmost "env string data / arg string data" = the "string body"
  tier of this appendix
- `Auxiliary Vector (auxv)` = the auxv tier of this appendix
- `envp[]` / `argv[]` = the pointer array tier of this appendix
  (`NULL`-terminated at the end)
- `argc` = the location pointed to by `RSP` = the first value ld-linux.so
  sees at the moment it starts

Even in an example with real arguments (e.g. `./main foo bar` →
`argc = 3`, `argv[0..3]` with `NULL` at the end), the shape is the
same; only "the length of the pointer array and the amount of string
body content" grows.
