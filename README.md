# hernes.el

ローカル LLM を使う Emacs 内蔵のコーディングエージェント・ハーネス。
[gptel](https://github.com/karthink/gptel) をトランスポート層として使い、
その上で**会話状態とターン制御を hernes 自身が所有**する。

設計の全体像・思想は [DESIGN.md](./DESIGN.md) を参照。本 README は使い方の骨子のみ。

## 位置づけ

- **gptel** = ループエンジン / SDK（バックエンド抽象・ツールスキーマ変換・通信）
- **hernes** = その上のハーネス（会話履歴の所有、ターンループ、安全網、並列ツール実行）

安全網はエディット単位の承認ではなく、**タスク単位 + git チェックポイント**で担保する。

## 必要環境

- GNU Emacs 29.1 以上
- `gptel`（インストール済みであること）
- OpenAI 互換のローカル LLM サーバー（LM Studio / llama-server / Ollama など）
  - 既定は `http://localhost:1234`
- 外部コマンド: `git`, `rg`(ripgrep)

## セットアップ

```elisp
(require 'hernes)
(require 'hernes-ui)   ; 対話バッファ UI（M-x hernes を提供）

;; バックエンド（エンドポイントとモデル名）
(setq hernes-backend '(:endpoint "http://localhost:1234" :model "local-model"))
```

`hernes.el` はコア（ヘッドレス）、`hernes-ui.el` は対話バッファ UI。`M-x hernes` を
使うには `hernes-ui` をロードする。ヘッドレス用途（`emacs --batch` / デーモン / cron）
では `hernes` だけで足りる。

## 使い方

`M-x hernes` を実行すると、現在のプロジェクト（`project-current`）のルートで
**セッションバッファ** `*hernes: <id>*` が開く（Claude Code 風の対話 UI）。
上部が読み取り専用のトランスクリプト、下部がプロンプトマーカー `❯ ` に続く入力エリア。

1. 入力エリアにタスク（や指示）を打ち込む（複数行可）
2. `RET` で送信

セッションはモデルがテキストで応答すると `status=done`（中断時は `stopped`）で完了し、
そのまま次の発話を入力して会話を続けられる。ターンごとに LLM の発話・ツール呼び出しと
結果の要約がトランスクリプトに追記される。`C-u M-x hernes` は既存バッファがあっても
新規セッションバッファを作る。

| キー | 動作 |
|---|---|
| `RET` | 送信（入力エリアが空なら何もしない） |
| `S-RET` / `C-j` | 入力エリアに改行を挿入 |
| `S-TAB` | モード巡回 `chat → plan → auto → chat`（実行中でも切替可、次の送信から反映） |
| `C-c C-k` | `hernes-ui-abort` — 実行中プロセスを kill してループを停止 |

header-line に `[モード] モデル名  turns:N  (idle|running)` を表示する。

### 入力行の特殊構文（Claude Code 互換）

| 構文 | 動作 |
|---|---|
| `!command` | モデルには送らず、人間の命令として即座に project root で非同期実行（`hernes-shell-file-name`、`hernes-command-timeout`）。**deny-list は適用しない**（人間の自己責任実行で `M-!` と同格）。実行中の表示・出力はトランスクリプトに追記し、結果は会話コンテキストにも積む（セッション完了済みなら即座に、未開始・実行中なら次の送信にまとめて同梱）。直前の `!` が終わるまで次の `!` は拒否される |
| `@path/to/file` | 送信時に実在するファイルなら `<context file="...">` ブロックへ内容を展開して同梱（`hernes-max-tool-output` で切り詰め）。トランスクリプトの表示は `@path` を含む原文のまま。実在しないパスはそのまま素通り。入力エリアで `@` に続けて入力すると `completion-at-point`（標準 capf。Corfu/Orderless がそのまま効く）でプロジェクト内ファイルパスを補完 |

**送信の意味論**: セッション未開始なら入力をタスクとして `hernes-loop` を起動、完了済みなら
`hernes-resume` で継続、実行中なら「Session is still running.」で拒否（入力は保持）。
`auto` モードでの送信前には git 安全網ブランチ `hernes/<session-id>` を用意し、ワーキング
ツリーが dirty なら送信を拒否して理由をトランスクリプトに表示する（`chat`/`plan` は
git に触れない）。プログラムから継続する場合は `(hernes-resume SESSION TEXT)`
（headless・バッファ/ミニバッファ非依存）。

## モード

| モード | 読み取りツール | 副作用ツール | git ブランチ | 用途 |
|---|---|---|---|---|
| `chat` | ✅ | ❌（スキーマ自体を渡さない） | 触らない | 調査・相談。ファイルは書き換えない |
| `plan` | ✅ | ❌（同上）+ 計画提示プロンプト | 触らない | 調査して実装計画を markdown で提示（実装はしない） |
| `auto` | ✅ | ✅ | 最初の `auto` 送信時に lazy 作成（dirty なら拒否） | 自律実行。git 安全網は常時有効 |

- ツールフィルタとシステムプロンプトは**送信ごとに現在モードから再計算**する。よって
  `S-TAB` でモードを変えると、次の送信からツールセット（と `plan` の計画プロンプト）が
  切り替わる。
- `plan` は `chat` と同じ読み取り専用ツールセットに `hernes-plan-prompt`（実装せず計画を
  提示せよ、という指示）を上乗せしたもの。計画に納得したら `S-TAB` で `auto` に切り替えて
  同じ会話のまま実行へ移れる。
- git ブランチはセッション開始時ではなく **`auto` モードでの最初の送信時**に作成する
  （`hernes--ensure-git`）。`chat`/`plan` の間は一切 git に触れない。
- `confirm`（ターンごとの一括承認）は P-B で追加予定。

## ツール（P-A）

| ツール | 種別 | 説明 |
|---|---|---|
| `read_file` / `write_file` | fs | project-root 配下のみ許可 |
| `list_files` | fs | `project.el` ベース、glob フィルタ可 |
| `grep` | fs | ripgrep（`.git/ node_modules/ tmp/ log/ public/` を除外） |
| `run_command` | exec | 非同期・cwd=root・タイムアウト・deny-list |
| `git_checkpoint` / `git_diff` | git | git CLI を非同期実行 |

## 常時有効な安全網

- **project-root ガード**: fs ツールはルート外への読み書きを拒否
- **deny-list**: `rm -rf` / `sudo` / `git push` / `--force` 等にマッチする
  `run_command` はモードに関わらず実行前に拒否（`hernes-command-deny-list` で調整）
- **git チェックポイント**: セッション開始時に専用ブランチを切り、dirty なら開始拒否
- **停止条件**: max-turns 到達（既定 30）／同一ツールエラー 3 連続／ユーザー中断。
  いずれも制御バッファに状況を出して停止し、人間に判断を返す

## プログラムからの利用 / ヘッドレス動作

コアは再入可能・非同期の `hernes-loop`（subagent はこの再帰呼び出しに過ぎない）:

```elisp
(hernes-loop
 :task    "READMEのtypoを直して"
 :root    "/path/to/project"
 :buffer  (get-buffer-create "*my-hernes*")  ; 省略可(nil でヘッドレス)
 :mode    'auto            ; 'chat / 'plan / 'auto
 :backend '(:endpoint "http://localhost:1234" :model "local-model")
 :on-turn (lambda (payload) ...)   ; ターン毎(省略時: buffer へ描画)
 :on-done (lambda (result) (message "status: %s" (plist-get result :status))))
```

`hernes-loop` は **UI なし（`emacs --batch` / デーモン / cron）でも完全に動作**する:

- ループ本体はミニバッファ対話を一切行わず、進捗はすべて `:on-turn` / `:on-done`
  コールバック経由で外に出す（対話的な初期入力は `M-x hernes` エントリ内のみ）。
- 制御バッファ `*hernes*` への描画は、これらコールバックの**デフォルト実装**にすぎない。
  `:buffer` が生きていて、かつ対応するコールバックが未指定のときだけ差し込まれる。
  `:buffer nil`（または独自コールバック指定）ならバッファに一切触れない。
- 外部トリガー（cron 等）からは `:buffer nil` + 独自 `:on-done` で直接呼べる。

- `:on-turn` payload: `(:turn N :text ASSISTANT-TEXT :results (RESULT...))`
- `:on-done` payload: `(:status done|stopped :reason STR :result STR :turns N :messages LIST)`

`hernes-loop` 自体は git ブランチを作らない（副作用フリー）。`auto` の git 安全網が
必要な呼び出し側は、送信前に `(hernes--ensure-git SESSION DONE)` を通す（UI がこれを
行う）。実行中セッションのモードは `(hernes-set-mode SESSION MODE)`（`chat`/`plan`/`auto`）で
いつでも変更でき、次の送信からツールフィルタとシステムプロンプトに反映される。

主なカスタム変数: `hernes-backend`, `hernes-system-prompt`, `hernes-plan-prompt`,
`hernes-max-turns`, `hernes-command-timeout`, `hernes-shell-file-name`（既定 `/bin/sh`）,
`hernes-command-deny-list`, `hernes-grep-exclude-dirs`。

## テスト

```sh
emacs -Q --batch -L . \
  -L ~/.emacs.d/elpaca/builds/gptel \
  -L ~/.emacs.d/elpaca/builds/compat \
  -L ~/.emacs.d/elpaca/builds/transient \
  -l hernes-test.el -f ert-run-tests-batch-and-exit
```

## ステータス

フェーズ **P-A**（垂直に1本通す）+ 対話バッファ UI（`hernes-ui.el`）と `plan` モード。
`confirm` モード・`hernes-attach`・LSP ツール・`spawn_agent` は後続フェーズ
（DESIGN.md §8 参照）。
