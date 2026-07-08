![](../../images/06.png)

# Step 6. PLT / GOT の静的構造

Step 5 で、`add` の実行時の VA は `base_libmylib + 0x10f9`
と分かった。問題はここから: **`main` の中の `call` 命令を、どうやって
そのアドレスに到達させるか?**

このステップでは、その仕掛けである **PLT (Procedure Linkage Table)** と
**GOT (Global Offset Table)** の **静的な構造** を見る。
(実行時にどう動くかは Step 7)。

---

## 解きたい問題

`main.c` の `add(2, 3)` をコンパイルした時点では、`add` の
実行時アドレスは決まっていない。理由は次のとおり:

```
   - add は別の .so にある
   - その .so がロードされる base アドレスは ASLR で毎回違う
   - 同名の定義が複数の共有ライブラリに存在する可能性がある
```

つまり **「`add` 本体の実 VA を `call` 命令に直接埋め込むことはできない」**。
そこで、実行ファイル内に固定して置ける `add@plt` をいったん呼び出す
形にする。

そこで採用する方針:

```
   関数アドレスを書き込む箱を 1 つ用意する。
   call はその箱を経由する間接ジャンプにする。
   箱の中身は ld-linux.so 内のルーチンが実行時に書き込む。
```

この方針を図にすると:

```
                        (initially: box holds a placeholder
                         that routes to the resolver;
                         on the first call: the resolver
                         writes add's actual VA here)
                             |
                             v
     +--------+           +-----+            +-----------+
     |  main  |---call--->| box |----jmp---->|    add    |
     +--------+           +-----+            +-----------+
                       (indirect jump:
                        jump to the address stored in the box)
```

box の初期値は **アドレス解決ルーチン (resolver)** に到達する経路になっている。
1 回目の call でこの経路が起動し、resolver が `add` の実 VA を求めて box に
書き込む。2 回目以降の call は、書き換わった box を経由して直接 `add` へ
ジャンプする (詳しくは Step 7)。

この「箱」が **GOT エントリ (= スロット)**、そのスロットを経由して
呼ぶ補助コードが **PLT エントリ (= スタブ)**。以降は **「GOT スロット」
「PLT スタブ」** の語で統一して扱う。

(GOT は「間接アクセス用のアドレス表」の一般概念で、Linux ELF では
`.got` (データや eager binding される関数ポインタ) と `.got.plt`
(PLT 経由で呼ぶ関数、遅延束縛) の 2 セクションに分かれる。本書で
扱う「GOT スロット」は全て `.got.plt` のエントリを指す。)

---

## 全体図

```
   .text (RX)                 .plt (RX)              .got.plt (RW)
   +----------------+         +-----------+          +-------------+
   | main:          |         | PLT0:     |          | [0] &.dynamic|
   |   ...          |         |   ...     |          | [1] link_map |
   |   call add@plt | -.      |   ...     |          | [2] resolver |
   |   ...          |  |      +-----------+          +-------------+
   +----------------+  |      | add@plt:  |          | [3] add 用   |<--,
                       '----->|   jmp *[ ]|---,      +-------------+   |
                              |   push N  |   |      | [4] printf 用 |   |
                              |   jmp PLT0|   |      +-------------+   |
                              +-----------+   |                        |
                                              +------------------------'
                                              "add の実アドレスを読む"
```

要点:

- 題材の `call add@plt` は PLT の add@plt: エントリへ進む
- `add@plt` の jmp *[ ]は GOT エントリの中身にジャンプする
- GOT エントリは `add` の本当のアドレスを入れるためのスロット
- しかし、初期値は jmp *[ ] の次の番地 (push N の場所)
- つまり、１回目の `call add@plt` は PLT0: 経由で解決ルーチンを呼ぶ (これは Step 7 で詳述)

`add@plt` などの記法は、`objdump -d` などのツールが生アドレスにシンボル名
を貼って読みやすく表示している形で、実体はただの番地:

| 表記 | 意味 | 今回の値 |
|---|---|---|
| `add@plt` | `add` の PLT スタブが置かれている番地 | `0x1030` |
| `add@plt+6` | PLT スタブの 2 命令目 (`push N`) の番地 | `0x1036` |
| `add@got.plt` | `add` 用の GOT スロットの番地(上図の [3]add 用 と書いてあるスロット) | `0x4000` (`.got.plt[3]`) |

---

## .got.plt の中身

`.got.plt` は uint64 の配列。**先頭3つは予約**、4つ目以降が
1関数につき1スロット:

```
   .got.plt:
   +--------------------------+
   | [0]  &.dynamic           |   .dynamic セクションのアドレス (静的リンカが書き込む)
   +--------------------------+
   | [1]  link_map ポインタ    |   ld-linux.so が起動時に書き込む (link_map は Step 7 で詳述)
   +--------------------------+
   | [2]  _dl_runtime_resolve |   ld-linux.so が起動時に書き込む
   |                          |   = アドレス解決ルーチン (resolver) 本体のアドレス
   +--------------------------+
   | [3]  add のアドレス       |   ←初期値は PLT 内を指す "add@plt+6" 
   +--------------------------+
   | [4]  printf のアドレス    |   (もし printf を使っていれば。)
   +--------------------------+
   | ...                      |
```

`[1]` と `[2]` は ld-linux.so が **link map (後述)を組んでから** 書き込む。
`[3]` 以降は **PLT が解決される時** (= **関数初回呼出し時** ) に書き換わる。

---

## main のアセンブリコード: call add@plt

`main.c` をコンパイルする時点では `add` の実アドレスは分からない
(§ 解きたい問題 参照)。そこでコンパイラは `add` への **未解決の call と
再配置情報** を含むオブジェクトファイルを出す。それを受けた **静的
リンカ (binutils ld)** が `add@plt` (PLT スタブ) を作り、`call` の
飛び先を `add@plt` の番地に書き換える。結果として最終的な `main` の
機械語は `call 0x1030 <add@plt>` になる。実際に `objdump -d main` で
`main` 関数を見ると:

```
0000000000001139 <main>:
    1139:  55                   push   rbp
    113a:  48 89 e5             mov    rbp,rsp
    113d:  be 03 00 00 00       mov    esi,3            ; 第2引数 = 3
    1142:  bf 02 00 00 00       mov    edi,2            ; 第1引数 = 2
    1147:  e8 e4 fe ff ff       call   0x1030 <add@plt> ; <-- ここ!
    114c:  5d                   pop    rbp
    114d:  c3                   ret
```

`call 0x1030` の飛び先 `0x1030` は `add@plt` のアドレス。
`add@plt` は **`main` と同じ ELF ファイル内** にあるので、静的リンカは
その位置を確定でき、`call` の飛び先として書き込める。だから `add` の
実 VA が実行時まで不明でも、リンク時点で `main` から `add@plt` を呼ぶ
機械語は完成させられる。

---

## add@plt のアセンブリコード

`add@plt` は PLT スタブ 1 エントリで、16 バイト・3 命令:

```
0000000000001030 <add@plt>:
    1030:  ff 25 ca 2f 00 00    jmp    QWORD PTR [rip+0x2fca]   # 4000 <add@got.plt>
    1036:  68 00 00 00 00       push   0x0
    103b:  e9 e0 ff ff ff       jmp    0x1020 <PLT0>
```

3 命令の意味:

- `jmp QWORD [rip+0x2fca]` — `rip` (= 次命令アドレス `0x1036`) + `0x2fca`
  = `0x4000` は `add` 用の GOT スロット (`add@got.plt` = `.got.plt[3]`)。
  そのスロットに書かれた QWORD 値へ間接ジャンプ。静的リンカ (binutils
  ld) はビルド時にこのスロットの **初期値** として `add@plt+6`
  (= 次命令 `push 0x0` の番地 `0x1036`) を書き込んでおく。したがって
  未解決時、この間接 `jmp` は下の命令 (`push 0x0`) に「戻って」くる。
- `push 0x0` — reloc index (= `.rela.plt` 内の位置)。resolver に
  「どの再配置を解決するか」を伝える(下図参照)。
- `jmp 0x1020 <PLT0>` — PLT0 へ飛び、その後アドレス解決ルーチン (resolver) へ向かう (次節で詳述)。

PLT スタブは関数ごとに 1 個ずつ `.plt` に並んでいる。3 命令の形は同じで、
関数ごとに違うのは `jmp *[ ]` が参照する GOT スロットと、`push N` で
積む値 (= その関数用の reloc index) だけ:

```
   .plt:
   +--------------+
   | PLT0:        |
   |   ...        |
   +--------------+
   | add@plt:     |
   |   jmp *[ ]   |    <-- .got.plt[3] を参照
   |   push 0x0   |    <-- reloc index 0 (add を意味する)
   |   jmp PLT0   |
   +--------------+
   | printf@plt:  |
   |   jmp *[ ]   |    <-- .got.plt[4] を参照
   |   push 0x1   |    <-- reloc index 1 (printf を意味する)
   |   jmp PLT0   |
   +--------------+
        ...             (使う関数の数だけ並ぶ)
```

(題材の `main` は `add` のみ呼ぶので、実際は PLT0 と add@plt の 2 エントリ
だけ。上の printf@plt は「別の関数も呼んでいたらどうなるか」のパターン例示。)

### 初期値によるループバック

上の初期値の仕込みで、未解決時は 3 命令が「間接 `jmp` → `push 0x0` →
`jmp PLT0`」と順に流れ、PLT0 経由で resolver に到達する。この構造で
初回呼び出し時に実際に何が起きるかは Step 7 で **遅延束縛 (lazy
binding)** として追う。

---

## PLT0 のアセンブリコード

```
0000000000001020 <PLT0>:
    1020:  ff 35 ca 2f 00 00    push   QWORD PTR [rip+0x2fca]   # 3ff0 (= .got.plt+8 = .got.plt[1])
    1026:  ff 25 cc 2f 00 00    jmp    QWORD PTR [rip+0x2fcc]   # 3ff8 (= .got.plt+16 = .got.plt[2])
    102c:  0f 1f 40 00          nop
```

(リンカ構成によりオフセットは多少変わるが、指し先の GOT スロットは変わらない)

```
   1020: push [.got.plt[1]]    ; link_map ポインタを渡す (link_map は後述)
   1026: jmp  [.got.plt[2]]    ; resolver (_dl_runtime_resolve) に進む (resolver の動作は後述)
```

結果として `_dl_runtime_resolve(link_map, reloc_index)` の形で
解決ルーチンが呼ばれる (reloc_index は add@plt が push した 0)。

詳細な動きは Step 7。本章で見えるのは **PLT0 があらゆる関数解決の
合流地点** という構造までで、その合流地点で何が起きるかは次章で追う。

---

## R_X86_64_JUMP_SLOT 再配置

ここまでで `.plt` (PLT スタブ) と `.got.plt` (GOT スロット) の中身を
見た。だが、この 2 つだけを見ても、まだ答えられない疑問がある:

- resolver は `add@plt` から呼ばれた時、**どのシンボル** を解決すれば
  よいと分かるのか?
- 解決した実 VA を **どの GOT スロット** に書き込めばよいと分かるのか?

その答えを持つのが `.rela.plt` (= Step 4 で見た `DT_JMPREL` が指す表)。
ここに並ぶ各エントリは、静的リンカがビルド時に用意する
**「このスロットに、このシンボルの実 VA を書け」という指示** で、
実行時に resolver が読んで処理する。

指示のフォーマットは 1 種類ではない。ELF 仕様は用途別に複数の
**再配置タイプ (relocation type)** を定めていて、エントリごとにどのタイプ
かが記録されている。処理する側 (ld-linux.so や resolver) はこのタイプ
を見て「どう書き換えるか」を決める:

| タイプ | 値 | 用途 |
|---|---|---|
| `R_X86_64_RELATIVE` | 8 | `base + r_addend` を書く (Step 3 の自己再配置および main / .so の一般再配置) |
| `R_X86_64_GLOB_DAT` | 6 | GOT 内のデータ参照 |
| `R_X86_64_JUMP_SLOT` | 7 | PLT の GOT スロットへの書き込み ← 本節 |

`.rela.plt` のエントリはすべて `R_X86_64_JUMP_SLOT` タイプで、
`add@plt` が push した reloc index (= 0) は、この表の何番目のエントリを
見よ、というインデックス。

1 エントリの構造:

```c
typedef struct {
    uint64_t r_offset;  // 書き換え先の仮想アドレス (= .got.plt[k])
    uint64_t r_info;    // 再配置タイプ + シンボル番号
    int64_t  r_addend;  // 加算値 (JUMP_SLOT では 0)
} Elf64_Rela;           // 1 entry = 24 bytes
```

`add` 用エントリの値:

```
   r_offset = 0x4000                  (= .got.plt[3] の位置)
   r_info   → sym = 3, type = 7 (= R_X86_64_JUMP_SLOT)
   r_addend = 0
```

`sym = 3` は Step 5 § 解きたい問題 で見た `main:.dynsym[3]` を指す
(そこに `add` の未定義シンボル (UND) が入っている)。

このエントリは resolver に次の処理を指示する ( **実際に実行するのは Step 7** ):

    *(base_main + r_offset)  =  sym (= add) の実 VA

左辺と右辺を今回の題材で具体化すると:

- **左辺** = `base_main + 0x4000` = **`.got.plt[3]` の実 VA** (書き込み先)
- **右辺** = `sym` (= `add`) の実 VA = **`base_libmylib + 0x10f9`** (Step 5 で求めた値)

つまりこの 1 エントリを実行すると、`.got.plt[3]` の中身が初期値の
loopback (`add@plt+6`) から `add` 関数の実アドレスに書き換わる。

`add` の `.rela.plt` エントリを `readelf` で見ると:

```
$ readelf -r main

Relocation section '.rela.plt' at offset 0x618 contains 1 entry:
  Offset           Info             Type           Sym. Value     Sym. Name + Addend
  0000000000004000 0000000300000007 R_X86_64_JUMP_SLOT 0000000000000000 add + 0
```

これが「`add` のアドレスを解決し、`.got.plt[3]` (= `0x4000`) に
書き込む」という指示である。
題材では、PLT 経由の関数 1 個につき
`R_X86_64_JUMP_SLOT` 再配置が 1 個対応する。

今回 main は PLT 経由で `add` 1 つしか呼ばないので、この唯一のエントリが
**`.rela.plt[0]`** に相当する (= Step 7 で `_dl_fixup` に `reloc_index = 0` として
渡される値で参照するエントリ)。

---

## Step 7 へ渡す値

ここまでに、実行時の追跡に必要な対応関係が分かった:

```
   call add@plt        -> add@plt (= 0x1030)
   add@plt             -> GOT[add] (= base_main + 0x4000)
   GOT[add] の初期値   -> add@plt+6 (= base_main + 0x1036)
   .rela.plt[0]        -> main:.dynsym[3] の add
```

本章で確認したのは、この静的な対応関係までである。次章では
`call add@plt` から始め、これらが実行時にどう使われるかを追う。

---

## 今回押さえたこと (次章へ持ち越す要点)

```
   [x] PLT は GOT スロットを経由する 3 命令のスタブ
       (= シンボル名による直接呼び出しの中継)
   [x] GOT[add] の初期値は add@plt+6 を指す
   [x] R_X86_64_JUMP_SLOT 再配置が「どの GOT スロットに何を書くか」を
       指示 (= Step 7 の _dl_fixup が読む情報源)
```

次は **Step 7: 遅延束縛で実関数に到達する** —
未解決な PLT エントリから resolver が呼ばれてから、
GOT が書き換わって `add` に着地し、戻ってくるまでを動的に追う。
