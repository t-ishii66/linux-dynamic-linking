![](../../images/08.png)

# 付録 A. 用語と表記の規約

本書全体で使う用語と記号を集めた辞書。詳しい説明は各 Step / 付録に譲り、
ここでは **短い定義と参照先** を並べる。読み進めていて用語が引っかかった
ときの帰り先として使う。

- **第 1 部**: 本書独自の表記の規約 (`base_main`、`add@plt+N` など)
- **第 2 部**: ELF ファイルの構造に登場する用語 (ELF ヘッダ、Program
  header、`.dynamic`、シンボルテーブル、PLT/GOT、再配置)
- **第 3 部**: 実行時に登場する用語 (auxv、link_map、lookup scope、
  遅延束縛、resolver、ライブラリ探索)
- **第 4 部**: 本書で使うダンプツール (`readelf` / `objdump`) の主要オプション

---

# 第 1 部: 表記の規約

## VA = Virtual Address (仮想アドレス)

プロセスから見えるアドレス空間の番地のこと。本書で「VA」と書いたら常に
これを指す。CPU が実行時に MMU を介して物理アドレスに変換するが、その
物理アドレスは本書の話には出てこない (動的リンクは VA 上ですべて完結する)。

PIE (位置独立実行ファイル) では、`readelf` などで見える **ELF ファイル
中のアドレス値** (例: `0x1050`) は実行時の VA そのものではなく、
「ベースアドレスからのオフセット」として書かれている。実 VA はプロセスに
ロードされた後に確定する:

```
   ELF ファイル中のアドレス値 "0x1050"  +  base_main  =  実 VA
```

参照: Step 1 § `e_type`。

## ベースアドレスのラベル

各 ELF が起動時にロードされた VA の先頭を、それぞれ次のラベルで表す:

| ラベル | 意味 |
|---|---|
| `base_main` | `main` の base |
| `base_libmylib` | `libmylib.so` の base |
| `base_libc` | `libc.so.6` の base |
| `base_ld` | `ld-linux.so` 自身の base |

PIE のため ASLR で起動毎に値が変わるが、ある一回の実行の中では固定。

## シンボル表記 vs 具体値

具体値 (`0x1036`, `0x10f9` など) はビルドごとに変わるので、本文では
**シンボル表記を主役** にし、**生の数値は括弧内** に置く:

```
   add@plt (= 0x1030)
   add@plt+6 (= 0x1036)
   GOT[add] の実 VA  (= base_main + 0x4000)
   GOT[add] の初期値 (= base_main + 0x1036)
   st_value(add)  (= 0x10f9)
   add の実 VA  (= base_libmylib + st_value(add) = base_libmylib + 0x10f9)
```

コンパイラやリンカのバージョンによって数値は変わるが、シンボル間の関係は
変わらない。生の数値は、掲載したダンプ内の対応関係を確認する目安として扱う。

## `add@plt+N` 形式

`add@plt` は `add` の PLT スタブの先頭 VA を指すシンボル名 (実体は
`objdump` などが生アドレスに貼っているラベル)。

- **スタブの先頭を指す時は裸の `add@plt`** (`+0` は書かない)
  - 例: `add@plt (= 0x1030)`, `call add@plt`, `jmp add@plt`
- **先頭からのバイトオフセットが必要な時だけ `+N`** を付ける
  - 例: `add@plt+6 (= 0x1036)` (スタブの 2 命令目 `push 0x0` の場所)

同様に `add@got.plt` は `add` 用の GOT スロットの番地を指すラベル。

参照: Step 6 § 全体図 の記法テーブル。

## 静的リンカ vs 動的リンカ

| 呼称 | 実体 | 担当 |
|---|---|---|
| **静的リンカ** | `binutils ld` | ビルド時に `.got.plt` などの初期値を書き込む |
| **動的リンカ** | `/lib64/ld-linux-x86-64.so.2` (以降 `ld-linux.so`) | 起動時 / 実行時に再配置とシンボル解決を行う |

裸の「リンカ」「`ld`」は使わない (必ず「静的」「動的」を明示)。

## シンボル解決 という語

`ld-linux.so` が `add` の実 VA を確定するまでの一連の処理を本書では
「**シンボル解決**」と呼ぶ。「シンボル探索」「シンボル検索」は使わない
(用語のブレを避けるため)。

ただし「シンボル解決」全体の中の個別操作 (例: `.dynsym` を走査する、
`.gnu.hash` でハッシュ表を引く) を言及するのは OK。

## `readelf -h` の Type 表示

PIE (位置独立実行ファイル) の Type 表示は本書では
`Type: DYN (Position-Independent Executable file)` で統一する
(binutils 2.39+ の標準出力)。古い binutils では `Type: DYN (Shared object
file)` と出るが、本書の掲載値は前者で揃えている。

---

# 第 2 部: ELF ファイルの構造用語

## ELF 全般

| 用語 | 意味 |
|---|---|
| **ELF** (Executable and Linkable Format) | Linux/Unix 系の実行ファイル・共有ライブラリ・オブジェクトファイルの形式 |
| **ELF64** | 64bit ELF。本書はすべてこれ |
| **`Elf64_Ehdr`** | 先頭 64 バイトの ELF ヘッダ構造体。ファイル全体を読み解く起点 |
| **`e_type`** | ファイル種別 (`ET_REL` / `ET_EXEC` / `ET_DYN`) |
| **`ET_REL`** (= 1) | 再配置可能ファイル (`.o`) |
| **`ET_EXEC`** (= 2) | 固定アドレスの実行ファイル (非 PIE) |
| **`ET_DYN`** (= 3) | 共有ライブラリまたは PIE 実行ファイル |
| **`e_entry`** | エントリポイント (プログラム開始位置)。PIE では image 内オフセット |
| **`e_phoff` / `e_phentsize` / `e_phnum`** | Program header 表のファイルオフセット / エントリサイズ / 個数 |
| **PIE** (Position-Independent Executable) | 位置独立実行ファイル。共有ライブラリと同じ仕組みでロードする実行ファイル |
| **ASLR** (Address Space Layout Randomization) | ロード VA を起動毎にランダム化するセキュリティ機構 |

参照: Step 1 全体。

## Program header (Elf64_Phdr)

| 用語 | 意味 |
|---|---|
| **プログラムヘッダ** | 1 つ 56 バイトの構造体 (`Elf64_Phdr`)。**メモリにロードされる領域** または **実行環境に情報を伝える領域** を 1 つ表す |
| **セグメント** | プログラムヘッダが表す領域のうち、メモリにロードされる方 (= `PT_LOAD`) |
| **セクション** | `.text` などの内部区画。1 セグメントに複数セクションが束ねて入る |
| **`p_type`** | セグメント種別 (`PT_LOAD` / `PT_INTERP` / `PT_DYNAMIC` / `PT_PHDR` など) |
| **`PT_LOAD`** (= 1) | メモリへ配置する範囲と保護属性を示す (題材では 4 個) |
| **`PT_DYNAMIC`** (= 2) | このセグメントに `.dynamic` が入る |
| **`PT_INTERP`** (= 3) | 動的リンカのパス文字列 (`"/lib64/ld-linux-x86-64.so.2"`) |
| **`PT_PHDR`** (= 6) | Program header 表自身を指す |
| **`p_offset`** | ファイル先頭からのオフセット |
| **`p_vaddr`** | メモリ上の番地 (PIE では image 内オフセット、実 VA は `base_main + p_vaddr`) |
| **`p_filesz` / `p_memsz`** | ファイル上のサイズ / メモリ上のサイズ (差分は `.bss` などゼロ初期化領域) |
| **`p_flags`** | R/W/X 保護属性 |

参照: Step 2 全体。

## `.dynamic` (Elf64_Dyn)

| 用語 | 意味 |
|---|---|
| **`.dynamic`** | 動的リンクの情報を集約したセクション。`(tag, value)` の配列 |
| **`Elf64_Dyn`** | 1 エントリ 16 バイト (`d_tag` + `d_val` or `d_ptr`) |
| **`d_tag`** | エントリの種別 (`DT_*`) |
| **`d_val`** | 整数値として解釈する場合 |
| **`d_ptr`** | 仮想アドレスとして解釈する場合 |
| **`DT_NULL`** (= 0) | 配列の終端 |
| **`DT_NEEDED`** (= 1) | 依存ライブラリ名 (`.dynstr` へのオフセット) |
| **`DT_STRTAB`** (= 5) | `.dynstr` のアドレス |
| **`DT_SYMTAB`** (= 6) | `.dynsym` のアドレス |
| **`DT_RELA`** (= 7) | `.rela.dyn` のアドレス (一般再配置表) |
| **`DT_RELASZ`** (= 8) | `.rela.dyn` のサイズ |
| **`DT_RELAENT`** (= 9) | `.rela.dyn` の 1 エントリのサイズ |
| **`DT_JMPREL`** (= 23) | `.rela.plt` のアドレス (PLT 用再配置表) |
| **`DT_PLTRELSZ`** (= 2) | `.rela.plt` のサイズ |
| **`DT_PLTGOT`** (= 3) | `.got.plt` のアドレス |
| **`DT_RUNPATH`** (= 29) | ライブラリ探索パス (`$ORIGIN` などの文字列オフセット) |
| **`DT_RPATH`** (= 15) | 旧式の探索パス。`DT_RUNPATH` があれば無視される |
| **`DT_GNU_HASH`** | `.gnu.hash` のアドレス。本書では詳しく扱わない |
| **`.dynstr`** | NULL 区切りの文字列を並べた領域。オフセットで文字列を 1 個取り出す |

参照: Step 4 全体。

## シンボルテーブル

| 用語 | 意味 |
|---|---|
| **`.dynsym`** | 動的シンボルテーブル。`Elf64_Sym` の配列 |
| **`Elf64_Sym`** | 1 エントリ 24 バイト |
| **`st_name`** | シンボル名 (`.dynstr` のオフセット) |
| **`st_value`** | シンボルの相対アドレス (実呼び出しでは `base + st_value`) |
| **`st_shndx`** | 所属セクションのインデックス。`SHN_UNDEF` (= 0) なら未定義 |
| **`SHN_UNDEF`** (= 0) / **`UND`** | この ELF に定義無し (要解決) |
| **`FUNC`** | シンボル種別: 関数 |
| **`GLOBAL`** / **`LOCAL`** / **`WEAK`** | シンボルの binding (公開範囲) |

参照: Step 5 全体。

## PLT / GOT

| 用語 | 意味 |
|---|---|
| **PLT** (Procedure Linkage Table) | 関数呼び出しを間接ジャンプで受ける 3 命令のスタブ群。`.plt` セクションにある |
| **GOT** (Global Offset Table) | 間接アクセス用のアドレス表。Linux ELF では `.got` と `.got.plt` の 2 セクションに分かれる |
| **`.got`** | データや eager binding される関数ポインタ |
| **`.got.plt`** | PLT 経由で呼ぶ関数 (遅延束縛) のスロット。本書で「GOT スロット」と言えばこちら |
| **PLT スタブ** | `.plt` 内の 1 エントリ (3 命令: `jmp *[GOT]`, `push N`, `jmp PLT0`) |
| **GOT スロット** | `.got.plt` の 1 エントリ (= 関数アドレスの入れ物) |
| **PLT0** | 全 PLT スタブの共通合流点。resolver に飛ぶ |
| **`add@plt`** | `add` の PLT スタブの先頭番地 (例: `0x1030`) |
| **`add@got.plt`** | `add` 用の GOT スロットの番地 (例: `0x4000`) |
| **`add@plt+6`** | PLT スタブの 2 命令目 (`push N`) の番地 |

参照: Step 6 全体。

## 再配置 (relocation)

| 用語 | 意味 |
|---|---|
| **再配置 (relocation)** | 「ロード後にここを書き換えて」とマークされた箇所を、実行時の実アドレスで埋め直す操作 |
| **`.rela.dyn`** | 一般再配置エントリの表 (`DT_RELA` が指す) |
| **`.rela.plt`** | PLT 用 (JUMP_SLOT) 再配置エントリの表 (`DT_JMPREL` が指す) |
| **`Elf64_Rela`** | 1 エントリ 24 バイト |
| **`r_offset`** | 書き換え先の仮想アドレス |
| **`r_info`** | 再配置タイプ + シンボル番号 (上位 32bit = sym、下位 32bit = type) |
| **`r_addend`** | 加算値 |
| **再配置タイプ (relocation type)** | 再配置の種別。ELF 仕様で用途別に定義された定数 |
| **`R_X86_64_RELATIVE`** (= 8) | `base + r_addend` を書き込む (自己再配置で使用) |
| **`R_X86_64_GLOB_DAT`** (= 6) | GOT 内のデータ参照 |
| **`R_X86_64_JUMP_SLOT`** (= 7) | PLT の GOT スロットへの書き込み (シンボル解決結果を格納) |
| **reloc index** | `.rela.plt` の N 番目を選ぶインデックス。PLT スタブが `push N` で resolver に渡す |

参照: Step 3 (`R_X86_64_RELATIVE` の自己再配置)、Step 6 (`R_X86_64_JUMP_SLOT`)、
付録 C (自己再配置の詳細)。

---

# 第 3 部: 実行時の用語

## 起動情報 (execve 時にカーネルが用意する)

| 用語 | 意味 |
|---|---|
| **argc / argv / envp** | プロセス起動時にスタックに積まれる引数と環境変数 |
| **auxv** (Auxiliary Vector) | カーネルが `ld-linux.so` に渡す ELF 情報の追加チャンネル。`(キー, 値)` の配列 |
| **`AT_NULL`** (= 0) | auxv の終端 |
| **`AT_PHDR`** (= 3) | `main` の Program header 配列の実 VA |
| **`AT_PHENT`** (= 4) | Program header 1 個のサイズ (= 56) |
| **`AT_PHNUM`** (= 5) | Program header の個数 |
| **`AT_BASE`** (= 7) | `ld-linux.so` の `base_ld` |
| **`AT_ENTRY`** (= 9) | `main` のエントリポイント実 VA (= `base_main + e_entry`) |

参照: Step 3 § Auxiliary Vector (auxv) の中身、付録 B 全体。

## 動的リンカの内部データ

| 用語 | 意味 |
|---|---|
| **`link_map`** | `ld-linux.so` が各 ELF ごとに 1 つ持つノード。全ノードは `l_next` / `l_prev` の連結リストで繋がる |
| **`l_addr`** | ロードされた base アドレス |
| **`l_ld`** | その ELF の `.dynamic` の位置 |
| **`l_next` / `l_prev`** | 隣の link_map ノードへのポインタ |
| **`l_scope`** | **lookup scope 表 (シンボル検索順序リスト)** を指すポインタ |
| **lookup scope** | 「どの ELF を、どの順で見るか」の検索順序リスト。各 ELF ごとに 1 つ持つ (= `l_scope` が指す表) |
| **link_map 連結リスト** vs **lookup scope 表** | 前者は全 ELF を組織する構造、後者は検索順を並べたリスト。本書の題材では順序は一致するが別のデータ構造 |

参照: Step 7 § link_map、付録 D (lookup scope の順序がどう決まるか)。

## 起動処理

| 用語 | 意味 |
|---|---|
| **自己再配置 (self-relocation)** | `ld-linux.so` 自身の `R_X86_64_RELATIVE` 再配置を、シンボル解決なしで実行する処理。起動最初の一歩 |
| **`_start`** | ELF の `e_entry` が指すエントリ点。ユーザの `main()` ではなく、C ランタイムのアセンブリスタブ |
| **`__libc_start_main`** | libc の関数。`_start` から呼ばれ、初期化 → `main()` → `exit` を担う |
| **`.init_array`** | 各 `.so` のコンストラクタ配列 (libc の初期化などが並ぶ) |

参照: Step 3 § ld-linux.so による動的リンク、付録 C 全体。

## シンボル解決と遅延束縛

| 用語 | 意味 |
|---|---|
| **シンボル解決** | 未定義シンボル (例: `main` 側の `add`) の定義を、lookup scope 順に検索して実 VA を確定する処理 |
| **遅延束縛 (lazy binding)** | 関数の実 VA 確定を初回呼び出しまで遅らせる仕組み。初回だけコスト、以降は直接ジャンプ |
| **resolver** | 遅延束縛でシンボルを解決するルーチンの総称。実体は `_dl_runtime_resolve` |
| **`_dl_runtime_resolve`** | `ld-linux.so` 内の手書きアセンブリ trampoline。`.got.plt[2]` にアドレスが入っている |
| **`_dl_fixup`** | `_dl_runtime_resolve` から呼ばれる C 関数。実際にシンボル解決を行い GOT スロットを書き換える |
| **`.gnu.hash`** | `.dynsym` の検索を高速化するハッシュ表 (`DT_GNU_HASH` が指す)。本書では詳しく扱わない |

参照: Step 5 (静的な視点)、Step 7 (動的な流れ)。

## 依存ライブラリのロード

| 用語 | 意味 |
|---|---|
| **依存の順にロード** (幅優先) | `DT_NEEDED` を先頭から辿り、幅優先で `mmap` していく方式 |
| **幅優先 (BFS = Breadth-First Search)** | グラフ探索戦略。同じ階層の全ノードを処理してから次の階層に降りる |
| **ロード順** | BFS で決まる、`ld-linux.so` が各 ELF をロードする順序 |
| **ライブラリ探索順序** | ライブラリ名 → 実ファイル位置の解決順序。優先度: `LD_LIBRARY_PATH` > `DT_RUNPATH` > `ld.so.cache` > デフォルトパス |
| **`$ORIGIN`** | `DT_RUNPATH` に書ける特殊トークン。実行ファイルのディレクトリを指す |
| **`ld.so.cache`** | `ldconfig` が作るライブラリキャッシュ |

参照: Step 4 § ライブラリ探索の順序、付録 D 全体。

---

# 第 4 部: ダンプツール

本書で登場するダンプツールと、それぞれのオプションの主な用途:

| コマンド | 主な用途 | 本書での参照先 |
|---|---|---|
| `readelf -h main` | ELF ヘッダを表示 | Step 1 |
| `readelf -l main` | Program header を表示 | Step 2 |
| `readelf -d main` | `.dynamic` の内容を表示 | Step 4 |
| `readelf -s --dyn-syms main` | `.dynsym` を表示 | Step 5 |
| `readelf -r main` | 再配置表 (`.rela.dyn` / `.rela.plt`) を表示 | Step 6 |
| `objdump -d main` | `main` の逆アセンブル | Step 6 (`call add@plt`) / Step 7 |
| `objdump -d -j .plt main` | `.plt` セクションだけ逆アセンブル | Step 6 (add@plt, PLT0) |
| `ldd main` | 依存 `.so` の解決結果 | Step 3 / Step 4 |
| `LD_SHOW_AUXV=1 ./main` | 起動時の auxv を表示 | Step 3 |


