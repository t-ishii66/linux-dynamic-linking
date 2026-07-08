![](../../images/03.png)

# Step 3. 動的リンカの起動

Step 2 までで、カーネルは `main` と `ld-linux.so` の両方を
メモリにマップし終え、最後に **`ld-linux.so` の e_entry** に
ジャンプした。

このステップでは、カーネルが `ld-linux.so` にジャンプしてから、
`ld-linux.so` が `main` の中に処理を渡すまでを追う。ざっくりした流れ:

```
   kernel
     -> ld-linux.so が起動する                              (Step 2 の末尾)
     -> ld-linux.so がスタックから main の情報を受け取る    (本章 §「スタック」§「Auxiliary Vector」)
     -> ld-linux.so が main の依存ライブラリをロードする    (本章 §「ld-linux.so による動的リンク」)
     -> ld-linux.so が main の _start にジャンプする
     -> main() が呼ばれる                                   (Step 4 以降)
```


---

## カーネルから動的リンカへの情報の渡し方: スタック

スタックの基本 — 伸びる向き、`RSP`、`argc` / `argv` / `envp` の C 言語規約に不慣れな場合は、
こちらへ [付録 B 起動スタックの読み方](./09_startup_stack.md)。

カーネルは `ld-linux.so` を起動する直前に、ユーザスタックに
**プロセス起動情報** を積んでおく。レイアウトは System V x86_64 ABI で
決まっている:

(このスタックは PT_LOAD ではなく、カーネルが新規プロセス向けに別途
確保した領域。Step 2 で PT_LOAD を mmap した後、ld-linux.so にジャンプ
する直前に確保される。)

```
   高アドレス
       +------------------------------+
       | (env 文字列 の実体)            |   "PATH=/usr/bin\0"  など
       | (arg 文字列 の実体)            |   "./main\0"
       +------------------------------+
       | Auxiliary Vector (auxv)      |   <-- 動的リンカが重要視する (中身は次節)
       |   AT_NULL,  0                |
       |   ...                        |
       |   AT_ENTRY, base_main+0x1050 |   (= 実 VA、PIE のため base 加算)
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
       | argc                         |   <-- RSP はここを指している
       +------------------------------+
   低アドレス
```

カーネルは ld-linux.so の `e_entry` にジャンプする **直前**、
`RSP` レジスタをこのスタックの先頭 (argc がある位置) に向けて
セットしておく。だから ld-linux.so は起動した瞬間から:

- **位置**: `RSP` レジスタ経由で渡されている
- **形式**: argc → argv → envp → auxv の順番は System V x86_64 ABI で固定

の2点を頼りに、スタックの構造を正確に辿る
(argv の長さは argc で確定。envp は NULL 終端まで、auxv は AT_NULL
終端まで読めば、各セクションの長さが順に決まる)。これが「ただ
mmap されただけ」の `ld-linux.so` がスタック上のプロセス起動情報に
手が届く理由。

---

## Auxiliary Vector (auxv) の中身

前のスタック図で中央付近に置かれていた `Auxiliary Vector (auxv)` の
ブロック ── 「動的リンカが重要視する」と注釈を付けたあの領域 ──
を、ここで解読する。

auxv は `(キー, 値)` の配列。各エントリは 16 バイト
(8バイトのキー + 8バイトの値)。`AT_NULL = 0` で終端。

「キー」はスタック上には整数として置かれている。
`AT_PHDR` などはその整数に C のヘッダで付けられた名前 (定数マクロ)
で、たとえば `AT_PHDR` は `3` の別名。

着目するキーは以下5つ:

```
   キー (8 bytes)        値 (8 bytes)
   ------------------    --------------------------------------
   AT_PHDR   (= 3)       main の Program header 配列のアドレス
                         (= 今回は base_main + e_phoff)
   AT_PHENT  (= 4)       Program header 1 個のサイズ (= 56)
   AT_PHNUM  (= 5)       Program header の個数 (= 13)
   AT_BASE   (= 7)       ld-linux.so の base_ld
   AT_ENTRY  (= 9)       main のエントリポイント実 VA
                         (= base_main + e_entry = base_main + 0x1050)
```

今回のバイナリでは `PT_PHDR` の `p_vaddr` と `e_phoff` がともに
`0x40` なので、`AT_PHDR = base_main + e_phoff` と書ける。
一般には `AT_PHDR` はメモリ上の Program header 配列の実 VA である。

---

## auxv の表示例

`LD_SHOW_AUXV=1 ./main` で内容が見える:

```
$ LD_SHOW_AUXV=1 ./main
AT_SYSINFO_EHDR: 0x7ffe123fa000
AT_HWCAP:        0x178bfbff
AT_PAGESZ:       4096
AT_CLKTCK:       100
AT_PHDR:         0x55b3a4d2e040          <-- main の phdr の実 VA
AT_PHENT:        56
AT_PHNUM:        13
AT_BASE:         0x7f4d2e9b2000          <-- base_ld
AT_FLAGS:        0x0
AT_ENTRY:        0x55b3a4d2f050          <-- main の _start の実 VA
AT_UID:          1000
...
```

---

## ld-linux.so による動的リンク

(用語: **再配置 (relocation)** とは、ELF の中で「ロードされたら
ここを書き換えて」とマークされた箇所を、実行時の実アドレスで
埋め直す操作。ASLR で base が確定するまでアドレスが書けない、という
事情のために必要になる。再配置エントリの具体構造 (`Elf64_Rela`,
`r_offset`, `r_info`, ...) と具体的な型 (`R_X86_64_JUMP_SLOT` など)
の詳細は Step 6 で扱う。)

```
   A. 自己再配置 (self-relocation)
        ld-linux.so 自身も ET_DYN で、自分自身の中にも書き換え対象がある。
        この時点でシンボル解決を伴わない再配置 (R_X86_64_RELATIVE 型 =
        base_ld を各所に加算するだけ) を実行し、完了すれば通常の C 関数を
        自由に呼べる状態になる。

   B. auxv を読む
        AT_PHDR / AT_PHNUM から main の Program header の在処を知る。
        AT_BASE から自分自身の base_ld を知る。
        AT_ENTRY を後で使うために覚えておく。

   C. main の PT_DYNAMIC を見つける  (詳細: Step 4)
        AT_PHDR から始まる Program header 配列を順に走査し、
        p_type == PT_DYNAMIC のエントリを探す。
        その p_vaddr (+ base_main) が main の .dynamic のアドレス。

   D. 依存ライブラリのロード  (詳細: Step 4)
        .dynamic の DT_NEEDED を順に処理:
          libmylib.so を mmap
          libc.so.6 を mmap
        さらに各 .so の .dynamic も再帰的に処理
        (libc.so.6 の DT_NEEDED ... など)

   E. 再配置の実行  (詳細: Step 5〜7)
        各 ELF の一般再配置 (DT_RELA が指す .rela.dyn) を処理する。
        PLT 経由の関数呼び出し用の再配置は別表 (DT_JMPREL が指す
        .rela.plt) にあり、この時点では実体解決せず、初回呼び出し時に
        解決するよう仕込む (= 遅延束縛)。

   F. .init_array の実行
        各 .so のコンストラクタ (libc の初期化など) を呼ぶ。

   G. AT_ENTRY に jump
        いよいよ main の _start に制御を渡す。
```

自己再配置 (A) の具体的な書き換え方法は
[付録 C 自己再配置の仕組み](./10_self_relocation.md) を参照。

---

## 参考: F の `.init_array` とは

F で `ld-linux.so` が呼ぶ `.init_array` は、**各 ELF が持つ「起動時に
一度だけ実行される関数」の関数ポインタ配列**。C の
`__attribute__((constructor))` を付けた関数や、C++ の静的記憶域オブジェクトの
コンストラクタが、コンパイラによってここに入れられる。libc/libmylib.so
自身の内部初期化ルーチンもここに並ぶ。

構造:

- `.dynamic` の中の `DT_INIT_ARRAY` が `.init_array` の位置、
  `DT_INIT_ARRAYSZ` がバイト数を指す
- 中身は `void (*)(void)` 型の関数ポインタが並ぶだけ

```
   .init_array   (DT_INIT_ARRAY が指す位置から DT_INIT_ARRAYSZ バイト分)
       +----------------+
       | fn1  : void(*)(void) |
       +----------------+
       | fn2  : void(*)(void) |
       +----------------+
       :                :
```

`ld-linux.so` (内部の `_dl_init`) は、A〜E がすべて終わった後、
`main` の `_start` に jmp する **直前** に、この配列を **依存の葉から根へ**
辿って各関数を呼ぶ。本書の題材で言えば:

```
   libc.so.6 の .init_array  →  libmylib.so の .init_array  →  main の .init_array
```

の順。libc の初期化が終わってから、libmylib、最後に main、という並びで、
「依存元の初期化を、依存先が完了した状態で走らせる」ことを保証する。

本書の題材の `add(2, 3)` は関数呼び出しの経路 (Step 5〜7) を追う話なので、
`.init_array` の中身自体は登場しない。起動フローの中で「E と G の間」に
位置する、というのが本書との接点。

---

## 参考: main の "_start" とは

`AT_ENTRY` が指すアドレス (= `base_main + e_entry` = `base_main + 0x1050`、PIE のため実 VA) には、
**ユーザが書いた `main()` ではなく**、C ランタイムの `_start` という
小さなアセンブリスタブが置かれている。

`objdump -d main` で `_start` を見ると:

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
    1064:  48 8d 3d ce 00 00 00   lea    rdi,[rip+0xce]      # main のアドレス
    106b:  ff 15 4f 2f 00 00      call   QWORD PTR [rip+0x2f4f]  # __libc_start_main を呼ぶ
    1071:  f4                     hlt
```

要点はコメントを入れた 2 行。`_start` は `main` のアドレスを引数の 1 つに
詰めて `__libc_start_main` を呼ぶ。だからその中で結局 `main()` が呼ばれる。

`__libc_start_main` は libc の関数で、内部で:
   - 初期化処理を呼ぶ
   - `main(argc, argv, envp)` を呼ぶ
   - `main` の戻り値を `exit()` に渡す
までやる。

このシリーズでは、**`_start` から `__libc_start_main()` を経由して
`main()` が呼び出される** という理解に留め、それ以上深追いはしない。

```
   ld-linux.so   --jump-->   _start (= main の e_entry)
                                 |
                                 +--call--> __libc_start_main
                                                |
                                                +--call--> main()
                                                              |
                                                              +--call--> add(2, 3)
                                                                            ^
                                                                            |
                                                              Step 6, 7 で扱う範囲
```

---

## 今回押さえたこと (次章へ持ち越す要点)

```
   [x] auxv (AT_PHDR / AT_PHNUM / AT_BASE / AT_ENTRY) で
       ld-linux.so は main の Program header / 自分の base / 起動先を得る
   [x] DT_NEEDED を辿って依存 .so を連鎖的に mmap する
       (= Step 4 の主役)
   [x] 「自己再配置 → 依存ロード → 再配置 → AT_ENTRY へ jump」の順で
       main の _start に橋渡しされる
```

次は **Step 4: .dynamic セクション** —
次章では、main の `PT_DYNAMIC` から `.dynamic` を見つけ、
`DT_NEEDED`、`DT_STRTAB`、`DT_SYMTAB` などを読む。

