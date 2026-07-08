![](../../images/10.png)

# 付録 C. 自己再配置の仕組み

Step 3 §「ld-linux.so による動的リンク」の A **自己再配置 (self-relocation)**

— 自身の中の実 VA 参照を `base_ld` を加味して書き換える処理 — 

---

## なぜ必要か

`ld-linux.so` は `ET_DYN`。`main` や `libmylib.so` と同じく、ファイル上
の絶対アドレス値は「`base = 0` と仮定したときのオフセット」として
書かれている。実 VA は実行時に決まる `base_ld` を足したもの。

書き換えが要る代表例:

- グローバル変数の初期化子 (`static int *p = &x;` の `p` — `x` の場所を埋め込む)
- 関数ポインタが並んだ配列 (`static void (*handlers[])() = { fn1, fn2 };` — 各要素に関数の場所を埋め込む)
- 文字列テーブル (`static const char *msgs[] = { "hello", "world" };` — 各要素に文字列リテラルの場所を埋め込む)

これらは「ld-linux.so の中の `x` の場所」を指したいので、ファイル上では
`x` の `base = 0` 起点のオフセットだけが書かれている。`base_ld` を足して 実VA に変換する。

---

## 指示書 `.rela.dyn` と `Elf64_Rela`

「どこを書き換えるか」「どう書き換えるか」は `ld-linux.so` 自身の
`.rela.dyn` に並ぶ再配置エントリが指示する。

- **`.rela.dyn` が置かれている場所**: 1 つ目の `PT_LOAD` (R only) の中
  (読むだけで書き換えないので R only で足りる)
- **`.rela.dyn` の位置とサイズを知る方法**: `PT_DYNAMIC` が指す
  `.dynamic` の中の **`DT_RELA` / `DT_RELASZ` / `DT_RELAENT`** から辿る
  (それぞれ表の位置、サイズ、1 エントリのバイト数)
- **書き換え先の実体**: `.got` などがある 4 つ目の `PT_LOAD` (RW) の中
  (書き換えるので RW が必要)

つまり自己再配置は「**指示書は R only な PT_LOAD、書き換え先は RW な
PT_LOAD**」という、性質の違う 2 種類のセグメントにまたがった処理になる。

各エントリは `Elf64_Rela` 構造体で 24 バイト:

```c
typedef struct {
    uint64_t r_offset;   // 書き換える先 (ELF 内オフセット)
    uint64_t r_info;     // 型と (もしあれば) シンボル番号
    int64_t  r_addend;   // 値を計算するための加数
} Elf64_Rela;
```

これが `.rela.dyn` に配列として並ぶ:

```
   .rela.dyn   (DT_RELA が指す位置から DT_RELASZ バイト分の領域)
               (各エントリ 24 バイト = DT_RELAENT)

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
   (数値は典型的な例。実際の glibc ld-linux.so では数百エントリある。)
```

再配置エントリ全般の話 (`r_info` の分解、他の再配置型など) は
Step 6 で扱う。本付録では「書き換える場所と方法を並べた配列」として
扱う。

---

## 自己再配置で使う型 `R_X86_64_RELATIVE`

自己再配置でほぼ唯一使われる再配置型。意味は:

```
   *(base_ld + r_offset) = base_ld + r_addend
```

「`base_ld + r_offset` の番地に、`base_ld + r_addend` の値を書く」だけ。
シンボル名を引いて他の `.so` のアドレスを探す、といったことは一切
不要。`base_ld` の加算だけで済む。

`ld-linux.so` の `.rela.dyn` のエントリは、ほとんどが
`R_X86_64_RELATIVE`。シンボル解決を要する他の再配置型 (`JUMP_SLOT`,
`GLOB_DAT` など) は、`ld-linux.so` 自身では使われないか、後段の
通常再配置 (Step 3 の E) で処理される。

---

## 具体例 — entry [0] を実行してみる

上の `.rela.dyn` 表の `entry [0]` を実際に処理してみる。仮の前提:

- `ld-linux.so` の C ソースに `static int x; static int *p = &x;`
  という宣言があり、ELF 内オフセット `0x1e10` に `x`、`0x21d8` に
  `p` が置かれているとする
- 起動時 ASLR で `base_ld = 0x7f4d2e9b2000` に決まったとする
  (= Step 3 § auxv の表示例 と同じ値)

エントリの値:

```
   r_offset = 0x21d8                <-- p の場所 (ELF 内オフセット)
   r_info   = R_X86_64_RELATIVE
   r_addend = 0x1e10                <-- x の場所 (ELF 内オフセット)
```

### 書き換え前のメモリ

```
   実 VA                内容
   ----------------     ---------------------------------------
   0x7f4d2e9b3e10       int x (= 0)                              <-- x の実体
       ︙
   0x7f4d2e9b41d8       int *p = 0  (仮値)                       <-- p の中身。まだ x を指していない
```

### 書き換え式の適用

`*(base_ld + r_offset) = base_ld + r_addend` を当てはめる:

```
   左辺 = *(0x7f4d2e9b2000 + 0x21d8) = *(0x7f4d2e9b41d8)
   右辺 =  0x7f4d2e9b2000 + 0x1e10  =  0x7f4d2e9b3e10
```

### 書き換え後のメモリ

```
   実 VA                内容
   ----------------     ---------------------------------------
   0x7f4d2e9b3e10       int x (= 0)                              <-- 変化なし
       ︙
   0x7f4d2e9b41d8       int *p = 0x7f4d2e9b3e10                  <-- &x の実 VA が入った
```

これで `p` は `x` の実 VA を指す状態になり、コード中で `*p` を読めば
`x` の値が取れる。`.rela.dyn` の残り `N-1` 個のエントリにも同じ処理を
かけることで、`ld-linux.so` 内のすべてのポインタ参照が実 VA に揃う。

---

## 流れ

1. `AT_BASE` から `base_ld` を得る (auxv 経由)。
2. 自身の Program header の位置を求め (`e_phoff` はファイルオフセット
   なので、先頭 `PT_LOAD` の `p_offset` / `p_vaddr` の対応を経由して
   VA に変換する。今回の題材のように先頭 `PT_LOAD` が `p_offset=0`,
   `p_vaddr=0` の場合は結果的に `base_ld + e_phoff` と一致する)、
   `PT_DYNAMIC` のエントリを見つける。
3. `.dynamic` を読んで `DT_RELA` / `DT_RELASZ` / `DT_RELAENT` を取得。
   これらが `ld-linux.so` の `.rela.dyn` の場所・サイズ・1 エントリの
   バイト数 (= 24)。
4. `.rela.dyn` の各エントリを順に走査し、`R_X86_64_RELATIVE` のものに
   ついて `*(base_ld + r_offset) = base_ld + r_addend` を実行。

この 4 ステップは、グローバル変数や外部関数を一切呼ばずに実行できる
ように慎重に書かれている (まだ自己再配置が終わっていない状態なので、
グローバル変数のポインタは仮値のままで使えない)。

---

## 完了後

自己再配置が終わると、`ld-linux.so` 内のグローバル変数や絶対アドレス
参照は実 VA で書かれた状態になる。以降は通常の C 関数を自由に呼べ、
Step 3 の B 以降 (auxv を読む、依存ライブラリをロード、再配置の実行、
…) に進める。

`main` や `libmylib.so` / `libc.so.6` の再配置は、Step 3 の E で
まとめて行う。型としては `R_X86_64_RELATIVE` 以外に、シンボル解決を
要する `R_X86_64_GLOB_DAT` / `R_X86_64_JUMP_SLOT` などが出てくる
(詳細は Step 5 と Step 6)。
