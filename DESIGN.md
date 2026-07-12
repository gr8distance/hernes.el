# hernes.el — ローカルLLMエージェントハーネス 設計書

日付: 2026-07-12 / 前提: Apple Silicon Mac (M5 Max 128GB)、OpenAI互換ローカルLLMサーバー

位置づけ: **gptel = ループエンジン(SDK)、hernes = その上のハーネス層**。
汎用ハーネスとして独立リポジトリで開発し、aeixer(セッションUI)はフック経由で hernes に乗る消費者。
macher 系のエディット単位承認は不採用(委任に向かない)。
安全網はエディット承認ではなく **タスク単位 + git チェックポイント**。

---

## 0. 全体像

```
 ユーザー ──▶ hernes (制御バッファ *hernes*)
                │
                ▼
        hernes-loop (再入可能・非同期)         ← コア。設定in/結果out の純関数的インターフェース
                │  gptel (tool-use)
                ▼
        LLMバックエンド (OpenAI互換endpoint)   ← LM Studio / llama-server / Ollama 差し替え可
                │  tool calls (1ターン複数 → 並列実行)
                ▼
        ツール群
          ├─ fs:    read_file / write_file / grep / list_files
          ├─ lsp:   diagnostics / references / definition   (Eglot = 差分価値)
          ├─ exec:  run_command (テスト・ビルド; 非同期プロセス)
          ├─ git:   checkpoint / diff / gh (CLI直叩き。Magitは人間のレビュー席)
          └─ spawn_agent (subagent = hernes-loop の再帰呼び出し)
```

**aeixer との関係:** hernes はセッション永続化を自前で持たない。ターン開始/終了/完了の
フック(`hernes-turn-hook` / `hernes-done-hook` 等)を公開し、aeixer が session-md (kind=code)
への記録とスイッチャー統合をフック側で実装する。hernes 単体でも動く。

---

## 1. 実行モード (安全網の中核)

| モード | 読み取りツール (fs read/grep, lsp, git diff) | 副作用ツール (write, exec, git commit, gh, spawn) | 確認 |
|---|---|---|---|
| `chat`    | ✅ | ❌ (スキーマ自体渡さない) | なし |
| `plan`    | ✅ | ❌ (同上) + 計画提示用システムプロンプト | なし |
| `confirm` | ✅ 自動実行 | ⏸ ターンごとに一括提示 → y/n/編集 | 毎ターン |
| `auto`    | ✅ | ✅ | 開始時と完了時のみ |

- `plan` = chat と同じ読み取り専用ツールセット + 「調査して実装計画を markdown で提示せよ、
  実装するな」のプロンプト差し替え。計画承認後は auto へ切替えて履歴ごと実行に移る。
- モードは**セッション途中で自由に変更可**(UI の S-TAB 巡回)。ツールフィルタとシステム
  プロンプトは**送信ごとに現在モードから再計算**する。
- git ブランチ作成はセッション開始時ではなく **auto モードでの最初の送信時に lazy 実行**
  (dirty ならその送信を拒否して理由を表示。chat/plan は git に触れない)。
- `confirm` の承認単位は「ターン内の副作用ツール一括」。個別 y/n はやらない。
- `auto` でも **git 安全網は常時有効** (§3)。破壊的コマンド(`rm -rf`, `git push --force` 等)は
  モードに関わらず deny-list で拒否。project-root 外へのファイルアクセスも常時拒否。

## 2. hernes-loop (コア)

```elisp
(hernes-loop
  :system-prompt STRING
  :tools LIST            ; モードで絞ったツール群
  :backend PLIST         ; (:endpoint URL :model NAME) — インスタンス毎に指定可
  :mode SYMBOL           ; chat / confirm / auto
  :max-turns INT         ; 既定 30
  :on-turn FUNC          ; 制御バッファへのログ + confirm フック
  :on-done FUNC)         ; 結果 (最終メッセージ + 統計) を返す
```

- **再入可能**であること。グローバル状態禁止(defcustom を除く)。subagent はこの関数の
  再帰呼び出しに過ぎない。
- 会話状態(メッセージ列)は hernes が所有し、ターン制御(max-turns、並列束ね、confirm ゲート)を
  hernes 側で握る。gptel はトランスポート(バックエンド抽象・ストリーミング)として使う。
  gptel の内部FSMに乗るか、ターン毎の gptel-request 呼び出しにするかは実装時に
  インストール済み gptel の API を確認して決定し、判断理由を記録する。
- 1ターンに複数 tool call が来たら **並列に実行して全結果を束ねて返す**
  (各ツールは必ず非同期。Emacsをブロックする同期プロセス呼び出しは禁止)。
- 停止条件: max-turns 到達 / 同一エラー3連続 / コンテキスト逼迫 — いずれも
  **「停止して人間に状況を返す」**。圧縮・自動継続は最小垂直ではやらない。

## 3. git チェックポイント (安全網の実体)

1. セッション開始時: `git switch -c hernes/<session-id>` (dirty なら開始拒否 → 人間に返す)
2. 意味のある単位ごとに `git commit` (checkpoint ツールをLLMに提供、コミットメッセージも書かせる)
3. 完了時: 人間が **Magit でブランチ差分をレビュー** → merge / 差し戻し / 破棄
4. `gh` ツールは PR 作成・issue 参照用 (auto では PR 作成まで、merge は常に人間)

## 4. subagent (`spawn_agent`)

- 実体: `hernes-loop` の再帰呼び出し。**ネスト1段まで** (子からの spawn_agent は拒否)。
- 引数: `role` (探索/実装/レビュー等のプリセット = 痩せたツールセット+痩せたプロンプト。
  prefill コスト削減のため)、`task` (依頼文)、`model` (省略時は親と同じ)。
- 並列: 同時実行上限 `hernes-max-concurrency` (既定 2、ベンチ後調整)。
- 子は親のモードを継承するが、**子の confirm は親に集約** (人間への確認窓口は常に1つ)。
- 価値: コンテキスト隔離が第一(探索の読み散らかしを親の窓に入れない)。
  並列スループットは128GB環境の実測次第で調整。

## 5. ツール v1 (これだけ。追加は使ってから)

| ツール | 実装 | 備考 |
|---|---|---|
| `read_file` / `write_file` | Elisp | project-root 外へのアクセス拒否 |
| `grep` / `list_files` | rg / project.el | 除外設定は consult-ripgrep と同等(.git/ node_modules/ 等) |
| `lsp_diagnostics` | Flymake/Eglot | バッファ未オープンのファイルは一時的に開く |
| `lsp_references` / `lsp_definition` | Eglot (xref) | ローカル小型モデルの弱さをLSP精度で補う本丸 |
| `run_command` | make-process (async) | cwd=project-root、タイムアウト付き、deny-list |
| `git_checkpoint` / `git_diff` | git CLI (async) | Magit 関数は呼ばない |
| `gh` | gh CLI (async) | サブコマンド allow-list (pr create/view, issue view) |
| `spawn_agent` | 再帰 | §4 |

外部世界 (Notion 等) は mcp.el で後付け。v1 スコープ外。

## 6. バックエンド抽象

- `(:endpoint URL :model NAME)` をエージェントインスタンス毎に持つ。ハーネスはこれ以上知らない。
- LM Studio は直列処理のため並列 subagent 時のボトルネック候補 →
  llama-server (`--parallel N`) / Ollama (`OLLAMA_NUM_PARALLEL`) を実測して選定。
- プランナー(大モデル)/ワーカー(小モデル)分離は spawn_agent の `model` 引数で既に表現可能。
  最小垂直では使わない(単一モデルで動かしてから)。

## 7. UI — 対話バッファ (Claude Code 風)

`M-x hernes` はミニバッファではなく**セッションバッファ** `*hernes: <id>*` を開く。
1バッファ = 1セッション。実装は `hernes-ui.el` に分離(コアの headless 性を汚さない)。

- **構成**: 上部 = トランスクリプト(read-only。発話・ツール呼び出しと結果要約・完了状態)、
  下部 = 入力エリア(プロンプトマーカー `❯ ` 以降が編集可、複数行OK)
- **キー**(バッファローカル):
  - `RET` 送信 / `S-RET` または `C-j` 改行
  - `S-TAB` モード巡回: chat → plan → auto (confirm 実装後は auto の前に挿入)
  - `C-c C-k` 中断
  - 実行中の送信は不可(メッセージ表示)
- **header-line**: 現在モード / モデル名 / ターン数 / 状態 (idle・running)
- **送信の意味論**: セッション未開始 → `hernes-loop` 起動 / 完了済み → `hernes-resume` /
  実行中 → 拒否。ターン予算は人間の発話ごとにリセット。
- **入力行の特殊構文** (Claude Code 互換の操作感):
  - `!command` — LLM に送らず人間の命令として即実行 (project root・非同期・タイムアウト付き)。
    出力はトランスクリプト表示 + 会話コンテキストに積む (未開始なら保留し初回送信に同梱)。
    **deny-list は適用しない** (モデルを縛る安全網であり、人間の自己責任実行は M-! と同格)
  - `@path/to/file` — 送信時に §7.1 の出自つき `<context>` ブロックへ展開して同梱
    (大きいファイルは切り詰め)。`@` 直後は completion-at-point でプロジェクトファイル名を
    補完 (Corfu/Orderless がそのまま効く)
- headless 用 API (`hernes-loop` / `hernes-resume`) は UI から独立に動作し続ける。
- セッション記録は持たない(§0 の通り aeixer がフックで実装)。

### 7.1 コンテキスト投げ込み (`hernes-attach`)

エディタからチャット/エージェントへコードを文脈として渡す入口。Cursor の Cmd+L 相当。

- **DWIM 1コマンド**: リージョンがあればその範囲、なければバッファ全体を採取。
- 渡す形式は生テキストではなく**出自つき構造**:
  ```
  <context file="lib/foo.ex" lines="12-34" lang="elixir">
  ...コード...
  </context>
  ```
  ファイルパスを含めることで、LLM がそのまま read_file/write_file の対象を特定できる。
- 投げ先の選択: 実行中セッションがあればそこへ / なければ新規 (モード選択)。
  添付後ミニバッファで指示を入力 → 即送信。
- 複数回 attach で積み上げ可 (送信時にまとめて同梱、送信後クリア)。

## 8. 実装フェーズ

- **P-A**: hernes-loop + fs/exec/git ツール + `auto`/`chat` モード + 制御バッファ + 常時安全網の基礎
  (deny-list, project-root ガード) — 垂直に1本通す
- **P-B**: `confirm` モード + hernes-attach (安全網とUXの完成)
- **P-C**: lsp ツール + spawn_agent (並列上限つき) + aeixer 統合フック
- **P-D**: ベンチ依存チューニング (バックエンド選定、並列数、モデル割り当て)

## 9. 未決事項 (ベンチ待ち)

- 並列サービングのバックエンド (llama-server vs Ollama vs LM Studio新版)
- 常用モデル (30B級 MoE A3B が本命候補) と tool calling 成功率
- 並列時の実効スループット → max-concurrency の既定値

## 10. 拡張フェーズ (P-A〜P-D の土台完成後に着手。コアは太らせない)

**設計上の前提制約: hernes-loop は headless (emacs --batch / デーモン) で完全動作すること。**
制御バッファは :on-turn/:on-done のデフォルト実装に過ぎず、ループ本体はUIに依存しない。

優先順位確定 (2026-07-12):

- **P-E: skills (必須)** — **agentskills.io オープン標準に準拠**: `skills/<name>/SKILL.md`
  (YAML frontmatter: name/description)。Hermes Agent (NousResearch) / Claude Code と同一形式のため
  **3ハーネス間でスキルライブラリを無変換共有できる**。置き場所: `~/.hernes/skills/` +
  プロジェクト毎 `.hernes/skills/`。説明文一覧をシステムプロンプトに載せ、本文は `load_skill`
  ツールで随時ロード (小型モデルの狭い窓と相性が良い)。タスク完了時の `save_skill` で
  「実装のスキル化」(Hermes の autonomous skill creation と同思想)。
- **P-F: memory** — 動的生成 (エージェントが `remember` で書き溜める md) × agentic retrieval
  (インデックス常載 + `recall`/grep で本文取得)。**ベクトルRAGは初手では採用しない**
  (この規模はgrepで足りる・デバッグ可能・埋め込みモデル運用が増えない)。Hermes も
  cross-session recall は FTS5+要約でありベクトルではない — 同判断の裏付け。
  検索側のアップグレード経路: grep → SQLite FTS5 (Emacs組み込みsqlite) →
  FTS5 + **sqlite-vec** ハイブリッド (レキシカル+連想検索)。sqlite-vec は
  `sqlite-load-extension` (Emacs 29+) で組み込み sqlite に直接ロード可、埋め込みは
  LM Studio `/v1/embeddings` (nomic-embed 等) — 全段ローカル完結。
  ファイルは md のまま形式不変、SQLite は「mdから再生成可能なインデックス」に徹する
  (壊れたら作り直せる = バックアップ・同期対象は md のみ)。
- **P-G: cron 管理** — launchd/cron → headless 呼び出し (= aeixer cowork がこの形で実装される想定)。
  スケジュール定義・結果の session-md 記録・失敗通知まで。
- **保留: Discord bridge** — bot が `emacsclient --eval` を叩く入口。リモート実行なので
  allow-list と auto+git安全網が前提 (headless では confirm 不可)。P-G まで完成してから再検討。
