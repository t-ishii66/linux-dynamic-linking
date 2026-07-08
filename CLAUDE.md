# DynamicLinkLibrary 学習プロジェクト

## 目的

Linux のダイナミックリンクライブラリ (共有ライブラリ, `.so`) の **内部構造と実行時処理** を理解する学習プロジェクト。

最終的に「ELFファイルのどの情報が、どの順序で使われて、ライブラリ関数の呼び出しが成立するのか」を一本のストーリーとして説明できる状態を目指す。

## アプローチ: 最小サンプル1つを徹底的に追う

抽象的な解説ではなく、**極小の具体例を1セット用意し、それをスコープの全項目について端から端まで追いかける**。
このサンプルを追いきれば、スコープが過不足なく理解できる、という構成にする。

### サンプルコード (想定)

```c
// mylib.c  →  libmylib.so にコンパイル
int add(int a, int b) { return a + b; }
```

```c
// main.c   →  実行ファイル main にリンク
int add(int, int);
int main(void) { return add(2, 3); }
```

ビルド:
```sh
gcc -shared -fPIC -o libmylib.so mylib.c
gcc -o main main.c -L. -lmylib -Wl,-rpath,'$ORIGIN'
```

### この1サンプルで追う流れ (= 学習の目次)

1. **ELFヘッダ** を `readelf -h main` / `readelf -h libmylib.so` で見る — エントリポイント, プログラムヘッダの位置
2. **プログラムヘッダ** を `readelf -l` で見る
   - `PT_INTERP` → `/lib64/ld-linux-x86-64.so.2` (動的リンカ)
   - `PT_LOAD` × 数個 → メモリへのマッピング
   - `PT_DYNAMIC` → `.dynamic` の位置
3. **動的リンカの起動** — カーネルが `PT_INTERP` のリンカを起動し、リンカが `main` をロードする流れ
4. **`.dynamic`** を `readelf -d` で見る
   - `DT_NEEDED`: `libmylib.so`, `libc.so.6`
   - `DT_STRTAB` / `DT_SYMTAB` / `DT_GNU_HASH`
   - `DT_PLTGOT` / `DT_JMPREL` / `DT_PLTRELSZ` / `DT_RELA`
5. **シンボル解決** — `add` を探す具体的手順
   - `DT_GNU_HASH` でバケットを引く
   - `DT_SYMTAB` のエントリを舐める
   - `DT_STRTAB` で名前文字列を比較
   - `libmylib.so` 側の `add` のアドレスが確定
6. **PLT / GOT** を `objdump -d -j .plt main` と `readelf -r main` で見る
   - `add@plt` のスタブが存在
   - 対応する GOT エントリ (`add@got.plt`) と `R_X86_64_JUMP_SLOT` 再配置
7. **実行時の関数呼び出し** — `main` の中の `call add@plt` がどう実関数に到達するか
   - **初回**: PLT スタブ → GOT の初期値が「次の命令」を指す → 解決ルーチン (`_dl_runtime_resolve`) へ → 上記5でアドレス確定 → GOT を書き換え → `add` へジャンプ
   - **2回目以降**: PLT スタブ → GOT に書かれた `add` の実アドレス → 直接ジャンプ
   - これが **遅延束縛 (lazy binding)**

この1〜7を `main` と `libmylib.so` の実バイナリに対して実際にダンプを取りながら順に確認する。

## スコープ

毎回必ず行われる、本質的な仕組みだけを追う。上記1〜7に出てくるものが「扱う対象」、出てこないものは「無視する対象」とほぼ一致する。

### 意図的に無視するもの

- セクションヘッダ全般 (実行時には使われない)
- デバッグ情報 (`.debug_*`)
- シンボルバージョニングの詳細 (`DT_VERSYM`, `DT_VERNEED`) — サンプル中に出てきたら「あるが今は読まない」と扱う
- TLS の細部
- IFUNC
- 32bit ELF の差分 (x86_64 のみ)
- 古い `DT_HASH` のアルゴリズム詳細 (`DT_GNU_HASH` 側のみ追う)
- プリリンク, `LD_PRELOAD` の特殊挙動
- `dlopen` / `dlsym` の API 詳細 (内部は同じ仕組み、で済ませる)
- `-z now` (eager binding) — 遅延束縛だけ理解する

## 進め方

- 上の目次を1ステップずつ進める。ステップごとに「実バイナリのダンプ」と「その意味」をセットで確認する
- 「この情報がなぜ必要か」「なければ何が起きるか」を毎回押さえる
- 一度に欲張らず、サンプル1つに対して順番にやり切る

## 環境メモ

- 作業マシンは macOS (Mach-O ネイティブ)。ELF/`.so` の実物は Docker か Linux VM で扱う
- サンプルは `samples/` に置く想定 (mylib.c, main.c, ビルドスクリプト, 観察結果メモ)

## 出力スタイル

- 説明は日本語
- ステップごとに「ダンプ → 着目点 → 仕組みの意味」の順で示す
