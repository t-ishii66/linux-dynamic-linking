![](../../images/04.png)

# Step 4. .dynamic セクション

Step 3 で動的リンカが `main` の **`PT_DYNAMIC` の Program header** を
見つけた。その `p_vaddr` が指す先に **`.dynamic` セクション** が
置かれている。

`.dynamic` は **動的リンクの情報** で、動的リンクで使う各種テーブルが
どこにあるかを集約したエントリ群。本章ではそのうち、依存ライブラリの
ロードに使う `DT_NEEDED` を追う (`DT_SYMTAB` や `DT_PLTGOT` など他の
`DT_*` は Step 5 以降で登場する)。

---

## .dynamic の構造

中身は単純で、**`(tag, value)` のペアの配列**。

```c
typedef struct {
    int64_t  d_tag;      // [0..7]  DT_NEEDED, DT_STRTAB, ... の番号
    union {
        uint64_t d_val;  // [8..15] 整数値 として解釈する場合
        uint64_t d_ptr;  // [8..15] 仮想アドレス として解釈する場合
    } d_un;
} Elf64_Dyn;             // 1エントリ = 16 bytes
```

`d_tag` ごとに「`d_un` を整数として読むか / アドレスとして読むか」の
解釈が決まっている。配列の終端は `d_tag == DT_NULL (0)`。

つまり `.dynamic` の実体は、`PT_DYNAMIC` の `p_vaddr` が指す領域に
並んだ `Elf64_Dyn` の配列である:

```
   +---- PT_DYNAMIC (Program header) の p_vaddr が指す領域 ----+
   |                                                           |
   |   .dynamic  (Elf64_Dyn の配列)                            |
   |                                                           |
   |   +------+------------------+                             |
   |   | tag1 | d_val1 or d_ptr1 |                             |
   |   +------+------------------+                             |
   |   | tag2 | d_val2 or d_ptr2 |                             |
   |   +------+------------------+                             |
   |   |  ... |       ...        |                             |
   |   +------+------------------+                             |
   |   |  0   |        0         |   <-- DT_NULL 終端          |
   |   +------+------------------+                             |
   |                                                           |
   +-----------------------------------------------------------+
```

題材の `main` の `.dynamic` に、実際のエントリを埋めるとこうなる (抜粋):

```
   .dynamic  (Elf64_Dyn の配列)
   +------------+------------------+
   | DT_NEEDED  |  d_val = 107     |   <-- 整数 (ライブラリ名を指すオフセット)
   +------------+------------------+
   | DT_NEEDED  |  d_val = 119     |   <-- 整数 (ライブラリ名を指すオフセット)
   +------------+------------------+
   | DT_RUNPATH |  d_val = 152     |   <-- 整数 (ライブラリ探索パスを指すオフセット、後述)
   +------------+------------------+
   |    ...     |       ...        |
   +------------+------------------+
   | DT_STRTAB  |  d_ptr = 0x478   |   <-- アドレス (.dynstr の位置、後述)
   +------------+------------------+
   |    ...     |       ...        |
   +------------+------------------+
   |  DT_NULL   |        0         |   <-- 終端
   +------------+------------------+
```

`DT_NEEDED` は整数を、`DT_STRTAB` はアドレスを持っている。この 2 つを
組み合わせて依存ライブラリ名 `"libmylib.so"` を取り出すのが次の節。

---

## DT_NEEDED を辿る

本章の主題は
 **`DT_NEEDED` から依存ライブラリを見つけて `mmap` するまで**
の流れ。`main` の `.dynamic` の中に並んでいる `DT_NEEDED` を 1 つ
取り出し、それが `"libmylib.so"` というライブラリ名を表していることを
確認する。

### `.dynamic` の生バイト (先頭)

`.dynamic` を生バイトで覗いた様子 (頭の数エントリ):

```
   オフセット   バイト                                d_tag    d_val/d_ptr
   ---------   ----------------------------------    -------- ------------
   .dynamic +0  01 00 00 00 00 00 00 00              DT_NEEDED
                6b 00 00 00 00 00 00 00                       d_val = 0x6b = 107
   .dynamic +16 01 00 00 00 00 00 00 00              DT_NEEDED
                77 00 00 00 00 00 00 00                       d_val = 0x77 = 119
   .dynamic +32 1d 00 00 00 00 00 00 00              DT_RUNPATH
                98 00 00 00 00 00 00 00                       d_val = 0x98 = 152
                ...
   .dynamic +N  05 00 00 00 00 00 00 00              DT_STRTAB
                78 04 00 00 00 00 00 00                       d_ptr = 0x478
                ...
```

先頭の `DT_NEEDED` の `d_val` はただの整数 `0x6b` (= 107)。これだけでは
`"libmylib.so"` にはならない。この整数は次の `DT_STRTAB` が指す
`.dynstr` の中の **オフセット** として使う。

### DT_STRTAB と .dynstr

`DT_STRTAB` の `d_ptr` は `.dynstr` のアドレス。`main` は PIE
(`ET_DYN`) なので、実行時にメモリで参照する実 VA は
**`base_main + d_ptr`** になる (Step 2 の `p_vaddr` や Step 5 の
`st_value` と同じ扱い; 以下の図では `base_main` を省略する)。

`.dynstr` は **NULL 区切りの文字列が並んでいるだけの領域**。整数オフセット
を 1 つ与えると、そこから NULL までが 1 個の文字列:

```
   仮想アドレス  バイト列                              文字列
   -----------  ------------------------------------  -----------------------
   0x478 + 0     00                                    ""
   0x478 + 107   6c 69 62 6d 79 6c 69 62 2e 73 6f 00   "libmylib.so\0"
   0x478 + 119   6c 69 62 63 2e 73 6f 2e 36 00         "libc.so.6\0"
   0x478 + 152   24 4f 52 49 47 49 4e 00               "$ORIGIN\0"
   ...
```

`.dynstr` の先頭は慣習で空文字列 `""`。この表は Step 5 のシンボル解決
でも `.dynsym` の名前列として再利用される。

### DT_NEEDED から名前を取り出す

これで 1 番目の `DT_NEEDED` の処理は:

```
   1. DT_NEEDED エントリを読む              -> d_val = 0x6b (= 107)
   2. DT_STRTAB エントリを読む              -> d_ptr = 0x478
   3. アドレス (0x478 + 107) の文字列を読む -> "libmylib.so"
```

これで `DT_NEEDED` からライブラリ名 `"libmylib.so"` が取り出せた。

`readelf -d main` は上の生バイト解読を人間可読な形にしただけ:

```
$ readelf -d main | grep -E 'NEEDED|STRTAB'
 0x0000000000000001 (NEEDED)  Shared library: [libmylib.so]
 0x0000000000000001 (NEEDED)  Shared library: [libc.so.6]
 0x0000000000000005 (STRTAB)  0x478
```

---

## ライブラリ探索の順序

ここでは、**通常実行** で、`DT_NEEDED` が `libmylib.so` のような
**ライブラリ名だけを持つ** (パス区切り `/` を含まない) ケースに絞る
(secure-execution mode やパス付きの `DT_NEEDED` などは扱わない)。

`"libmylib.so"` という名前から実ファイルを見つける順序:

```
   1. DT_RPATH                          (DT_RUNPATH が無い場合のみ参照される、古い方式)
   2. 環境変数 LD_LIBRARY_PATH
   3. DT_RUNPATH                        今回の例: $ORIGIN ($ORIGINは実行ファイルのディレクトリ)
   4. /etc/ld.so.cache (ldconfig が作る)
   5. /lib, /usr/lib などのデフォルトパス
```

`build.sh` で `-Wl,-rpath,'$ORIGIN'` を付けているが、最近の linker は
これを **`DT_RUNPATH`** として書き出す (`DT_RPATH` ではない)。
そのため、優先順位は

```
   LD_LIBRARY_PATH  >  DT_RUNPATH ($ORIGIN)  >  ld.so.cache  >  デフォルトパス
```

となる。何も環境変数を設定しなければ **main と同じディレクトリ**
(= `$ORIGIN`) が最初の有効な候補になり、そこに `libmylib.so` があるので
そのパスで `open()` + `mmap()` される。

(逆に言うと、`LD_LIBRARY_PATH=/somewhere` を設定するとそちらが
先に探されるので、`$ORIGIN` の `libmylib.so` は隠れる。)

---

## .so がロードされた後の世界

`libmylib.so` を mmap した。2 番目の `DT_NEEDED` にある `libc.so.6` も
同じ手順 (整数オフセット → `.dynstr` の名前 → 探索 → `mmap`) でロードする。
その結果、仮想アドレス空間は:

```
   base_main      +-----------------------------+
                  | main (全 PT_LOAD)            |
                  +-----------------------------+

   base_libmylib  +-----------------------------+
                  | libmylib.so (全 PT_LOAD)     |  <-- 新しく mmap
                  |   .text (add 関数の機械語)   |
                  |   .dynamic, .dynsym, ...    |
                  +-----------------------------+

   base_libc      +-----------------------------+
                  | libc.so.6 (全 PT_LOAD)       |  <-- これも mmap
                  +-----------------------------+

   base_ld        +-----------------------------+
                  | ld-linux.so                 |
                  +-----------------------------+
```

### 各 base の求め方

図に出てくる `base_main` / `base_libmylib` / `base_libc` / `base_ld` は
それぞれ異なる経路で決まる。`AT_BASE` (auxv キー 7) に対応するのは
**`base_ld` だけ**で、残りはそれぞれ別の経路で決まる。

| 名前 | 何の base か | 誰が決めるか | どこから来るか |
|---|---|---|---|
| `base_main` | main の PT_LOAD 群の先頭 | カーネルが ELF をマップした位置 (PIE なら ASLR で揺らぐ) | ld-linux.so は **`AT_PHDR` から逆算** して求める (PT_PHDR の `p_vaddr` と `AT_PHDR` の差) |
| `base_libmylib` | libmylib.so の PT_LOAD 群の先頭 | **ld-linux.so が `mmap()` した時の戻りアドレス** | ld-linux.so 内部の link_map に記録 |
| `base_libc` | libc.so.6 の PT_LOAD 群の先頭 | 同上 | 同上 |
| `base_ld` | ld-linux.so 自身の PT_LOAD 群の先頭 | カーネルが ld-linux.so を mmap した位置 | **`AT_BASE` (= auxv キー 7)** でカーネルから渡される |

要点:

- **`AT_BASE` は ld-linux.so だけのための情報**。ld-linux.so が「自分自身が
  どこにロードされたか」を知って、自分の自己再配置を実行するために必要。
- **main の base** は `AT_BASE` ではなく `AT_PHDR` から逆算する
  (Step 3 で auxv 経由でカーネルから渡されるのは `AT_PHDR` の方)。
- **`.so` の base** は完全にユーザ空間の出来事 — ld-linux.so が
  `mmap()` を呼んだ時に決まる値で、カーネルが auxv で渡すものではない。
  ld-linux.so はこれを **link_map** という内部データ構造に記録する。

各 .so に対しても、ld-linux.so はまた **その .so の `.dynamic`** を読み、
さらに `DT_NEEDED` があれば再帰的にロードする。これで全依存ライブラリが
メモリ上に揃う (= **link_map** が完成する)。

---

## 今回押さえたこと (次章へ持ち越す要点)

```
   [x] .dynamic は (tag, value) の配列。DT_NULL 終端
   [x] DT_NEEDED (整数オフセット) を DT_STRTAB が指す .dynstr に当てて
       ライブラリ名を取り出す
   [x] .dynstr は NULL 区切りの文字列を連結した表 (Step 5 でも再利用)
   [x] rpath / runpath / LD_LIBRARY_PATH で実ファイルを見つけて mmap
   [x] 各 .so の base はそれぞれ別経路で決まり、link_map に集約される
```

次は **Step 5: シンボル解決** — `libmylib.so` がロードできたので、
その中の `add` 関数のアドレスを引く手順を追う。
