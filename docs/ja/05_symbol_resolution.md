![](../../images/05.png)

# Step 5. シンボル解決

Step 4 で `.dynstr` (文字列表) の場所と構造を押さえた。本章では
これに `.dynsym` (シンボル表) を加え、**「文字列 `"add"` から
`libmylib.so` 内の関数アドレスを引く」** 手順を追う。これが動的
リンクの中核処理。

`.dynsym` を先頭から順に走査するだけで、 **動的リンクの本質は掴める** 。
本章はこの素朴な走査で説明する。実際の glibc は `.gnu.hash` という
ハッシュ機構で高速化しているが、章末で触れるだけにする。

---

## 解きたい問題

`main` の機械語は関数 `add` を呼び出そうとしているが、`main` 自身は
`add` のアドレスを知らない。`main` の `.dynsym` には `add` が「未定義
シンボル (UND)」として名前だけ載っている:

```
   readelf -s --dyn-syms main:
       Num:   Value  Size  Type   Bind   Ndx   Name
       ...
         3:   0x0    0     FUNC   GLOBAL UND   add
```

`FUNC` = 関数、`UND` = 未定義 (`SHN_UNDEF`)。ここから `add` の定義が
どの ELF にあるのかを引くのが本章の課題。

---

## lookup scope: どの .so を順に検索するか

ld-linux.so がシンボルを引くとき、**呼び出し元 ELF が持つ lookup scope**
(= 検索範囲) というリストを見る (実体は、ld-linux.so が各 ELF ごとに
持つ `link_map` の `l_scope` フィールドが指すリスト。詳細は Step 7)。
今回の題材では `main` の中で `add` が呼ばれるので、`main` の lookup
scope を上から順に検索する:

```
   main の lookup scope:
       1. main 自身                  -> "add" 無し (UND だけ)
       2. libmylib.so                -> "add" 発見!  ここで終了
       (3. libc.so.6                 -> 試さない)
       (4. ld-linux.so               -> 試さない)
```

**最初にヒットした .so が勝ち** ── これが「ライブラリのロード順序が
挙動に影響する」ゆえん。そのロード順序が具体的にどう決まるか (`-l` の
指定 → `DT_NEEDED` → lookup scope の順序) は
[付録 D](./11_load_order.md) で追う。

ここから先は **「ある 1 つの .so の中で `"add"` をどう見つけるか」** に
集中する。

---

## 検索に使う 2 つのテーブル

ある 1 つの .so の中で、シンボル探しに最低限必要なのは 2 つ:

| テーブル | 意味 |
|---|---|
| `.dynstr` | 文字列の倉庫 (Step 4 で扱った表)。今回はシンボル名 (`add` など) もここに入っている |
| `.dynsym` | シンボル定義の表 (`Elf64_Sym` の配列)。各エントリは `st_name` (`.dynstr` のオフセット = 名前)、`st_value` (仮想アドレス、相対) など (次節で詳述) |

`.dynstr` の位置は Step 4 で見た `DT_STRTAB`、`.dynsym` の位置は
`DT_SYMTAB` (どちらも `.dynamic` から辿れる)。

---

## .dynsym の1エントリ: Elf64_Sym

```c
typedef struct {
    uint32_t st_name;   // [ 0.. 3] .dynstr 内のオフセット
    uint8_t  st_info;   // [ 4]    type (関数/変数/...) と binding (GLOBAL/LOCAL/WEAK)
    uint8_t  st_other;  // [ 5]    visibility (DEFAULT/HIDDEN/...)
    uint16_t st_shndx;  // [ 6.. 7] 所属セクション。SHN_UNDEF=未定義 を意味する
    uint64_t st_value;  // [ 8..15] 仮想アドレス (.so 内の相対)
    uint64_t st_size;   // [16..23] サイズ (バイト)
} Elf64_Sym;            // 1 entry = 24 bytes
```

本シリーズで触るのは:

| メンバー | 意味 |
|---|---|
| `st_name` | シンボルの名前 (`.dynstr` 内のオフセット) |
| `st_value` | シンボルの相対アドレス<br>・**定義済の場合**: 関数/変数が置かれているオフセット (実呼び出しでは `base + st_value`)<br>・**未定義の場合**: まだ値が無いので `0` (プレースホルダ) |
| `st_shndx` | シンボルが「この ELF のどのセクションに属するか」を表すインデックス<br>・**`SHN_UNDEF` (= 0)**: この ELF に定義無し (= 要解決)<br>・**それ以外**: その番号のセクションに属する (今回は `11 = .text`) |

---

## libmylib.so 側 の .dynsym

§ 解きたい問題 で見たとおり、`main` 側の `add` は「未定義 (UND)」。
一方 `libmylib.so` 側の `.dynsym` を覗くと、`add` は定義済みで並んでいる:

```
   libmylib.so の .dynsym (抜粋, readelf -s --dyn-syms libmylib.so):
       Num:   Value     Size  Type   Bind   Ndx   Name
         0:   0x0       0     NOTYPE LOCAL  UND   (null)
         1..4:                              UND   各種 weak シンボル
         5:   0x10f9    20    FUNC   GLOBAL  11   add
```

`add` について、 `main` と `libmylib.so` を比較:

| エントリ | `st_value` | `st_shndx` |
|---|---|---|
| `main:.dynsym[3]` | `0` | `UND` |
| `libmylib.so:.dynsym[5]` | `0x10f9` | `11 (.text)` |

シンボル解決とは、main 側の **未定義シンボル**
`(name="add", st_value=0)` に対応する **定義** を別の ELF オブジェクトから
探す処理である。
(これ以降は libmylib.so 側のインデックス `dynsym[5]` を使う。)

---

## .dynstr の中身 (libmylib.so 側)

Step 4 で見た `.dynstr` と構造は同じ (NUL 区切りの文字列連結)。
libmylib.so 側の中身は:

```
   オフセット   バイト                             文字列
   ---------   ------------------------------     -------------
       0       00                                 ""
       1       5f 5f 67 6d 6f 6e 5f 73 ... 00     "__gmon_start__"
      16       5f 49 54 4d 5f ... 00              "_ITM_..."  (色々)
      ...
      71       61 64 64 00                        "add"        <-- !
      75       6c 69 62 63 2e 73 6f 2e 36 00      "libc.so.6"
      ...
```

`add` はオフセット 71 にある、と仮定する (実際の値はビルドで変わる)。
つまり `add` の `st_name` は 71。

---

## 線形検索: .dynsym を先頭から順に見る

以下は **1 つの `.so` の中** の走査 (= 内ループ)。全体としては scope 順に
対象 `.so` を切り替える外ループがあり、各 `.so` の中で以下の内ループが
走る。見つかった時点で外ループごと終了:

```c
// 外ループ (scope 走査、概念コード)
// scope[] = [ main の link_map,
//             libmylib.so の link_map,
//             libc.so.6 の link_map,
//             ld-linux.so の link_map ]
for (int i = 0; scope[i]; i++) {
    link_map *so = scope[i];
    Elf64_Sym *s = find(so, "add", so->n_sym);   // ← 内ループ (下の find)
    if (s) return so->l_addr + s->st_value;      // 発見、即返す
}
```

内ループ (`find`) は `.dynstr` と `.dynsym` だけを使って `"add"` を
探す。単純に書けば:

```c
const Elf64_Sym *find(const char *name, int n_sym) {
    for (int i = 0; i < n_sym; i++) {
        const Elf64_Sym *s = &dynsym[i];
        if (s->st_shndx == SHN_UNDEF) continue;   // 未定義 (要解決) は飛ばす
        const char *cand = dynstr + s->st_name;
        if (strcmp(cand, name) == 0) return s;
    }
    return NULL;
}
```

引数:

| 引数 | 意味 | 今回の値 |
|---|---|---|
| `name` | 探したいシンボル名 | `"add"` |
| `n_sym` | 走査対象の `.dynsym` のエントリ数 | `libmylib.so` の `.dynsym` の総エントリ数 |

コード中の `dynsym` / `dynstr` はそれぞれ `libmylib.so` の `DT_SYMTAB` /
`DT_STRTAB` が指す先の先頭アドレス (Step 4 参照)。

(注: `.dynamic` には `DT_SYMTAB` と `DT_SYMENT` (1 エントリのサイズ) は
あるが、`.dynsym` の総エントリ数を示す標準タグはない。実際の glibc は
`.gnu.hash` などのハッシュ表を使って候補範囲を決めるため、ここでは
説明用に `n_sym` が既知として扱う。)

libmylib.so に対してこれを実行すると、各反復はこう進む:

```
   i = 0  dynsym[0]  null entry              skip (UND)
   i = 1  dynsym[1]  _ITM_deregister...      skip (UND)
   i = 2  dynsym[2]  __gmon_start__          skip (UND)
   i = 3  dynsym[3]  _ITM_register...        skip (UND)
   i = 4  dynsym[4]  __cxa_finalize          skip (UND)
   i = 5  dynsym[5]  add                     st_shndx = 11 (.text)
                                              dynstr+71 = "add"
                                              strcmp("add", "add") == 0 → 命中!
                                              return &dynsym[5]
```

結果:

```
   sym = dynsym[5]
   st_value = 0x10f9     # libmylib.so 内の相対アドレス
```

これでシンボル解決の「中身」は終わり。`.dynstr` と `.dynsym` だけで
完結している。

---

## 求めた結果は何か

`dynsym[5].st_value = 0x10f9` は **libmylib.so 内の相対アドレス**。

実際のメモリ上の VA は:

```
   real_addr = base_libmylib + st_value
             = base_libmylib + 0x10f9
```

これが `add` 関数の機械語の先頭。
次章では、`main` の呼び出し命令からこのアドレスへ到達する仕組みを扱う。

---

## 実際は `.gnu.hash` で高速化する

上の線形走査は理屈は正しいが、公開シンボルが多い `.so` に対しては遅い。
実際の glibc は `.gnu.hash` (`DT_GNU_HASH` が指すハッシュ表) で同じ検索
を高速化する。詳しい仕組みは本書では扱わない (参照: `man elf` の
"Hash table" 節、glibc の `elf/dl-lookup.c`)。

---

## 今回押さえたこと (次章へ持ち越す要点)

```
   [x] .dynstr (名前文字列) と .dynsym (シンボル表) があれば、
       線形走査で "add" を見つけられる
   [x] 最終確認は .dynstr で名前を直接比較
   [x] 実 VA = 定義側 .so の base + st_value(シンボル)
        ── 題材では base_libmylib + st_value(add) = base_libmylib + 0x10f9
   [x] 実際は .gnu.hash で高速化している (本書では扱わない)
```

次は **Step 6: PLT / GOT の静的構造** —
求めた `add` の実 VA を、main の中の `call` 命令から
どう参照するための仕掛けか、その箱の中身を見る。
