# respawnkeeper / harness — 使い方

**サーバーが落ちたら、1回目で原因を特定し、直せるものだけ直して、起こし直す。直せないものは止まって人を待つ。**

対象サーバーは **`-ServerDir` で指す**。サーバーの場所もバージョンも、このフォルダの中には書いていない。

例外が3か所あり、リポジトリの親フォルダを基準にした並びを前提にしている。

- `ui\rk-console.ps1` のアンインストールは、respawnkeeper が置いたファイルを、親フォルダの下の `support\delate_files\` へ退避する。
- `rk-finish-setup.ps1` の最後の確認は、リポジトリの隣の `pokemoncraft\server` を探す。無ければ警告を出して先へ進む。
- `launcher\build-exe.ps1 -Verify` も同じ場所を探す。無ければ、通しの確認だけを飛ばす。

**Minecraft 専用ではない。** ゲームごとの違いは `games/<id>.psd1` にデータとして出してある。

| テンプレート | 検証状況 |
|---|---|
| `minecraft`（Forge / NeoForge） | ✅ **完全検証**（配置・起動・停止すべて実行済み） |
| `valheim` | ✅ 配置・起動・停止を実サーバーで実行済み（2026-09-13。正本は `games\valheim.psd1` の `verified`） |
| `palworld` `terraria` `tmodloader` | ⚠ **配置のみ実フォルダで検証。起動・停止は未実行** |
| `corekeeper` | 🚧 ドラフト（サーバー未インストールのため実物なし） |
| それ以外 | `rk-newgame.ps1` がその場で生成 → **実フォルダで検証してから採用** |

⚠ **`verified.stop` が false のゲームでは、自動再起動と日次点検が自動でOFFになる。**
人が1回クリーン停止を見届けて `games/<id>.psd1` の `verified.stop = $true` にするのが解除条件。
**強制終了がワールドを保存しない Valheim が一番危なかった**（2026-09-13 にクリーン停止を見届けて解除済み）。

---

## 使い始め — `respawnkeeper.exe` をダブルクリック

> `respawnkeeper.exe` は git に入れていない（ビルド生成物）。先に `launcher\build-exe.ps1` で作るか、同じ入口の `respawnkeeper.bat` を使う。

リポジトリ直下の **`respawnkeeper.exe`** を**ダブルクリック**（または**サーバーフォルダをドラッグ&ドロップ**）すると、
専用ウィンドウが開いて、そのフォルダ用の環境を作る:

```
1. サーバーフォルダを選ぶ（フォルダピッカー／ドロップ／パス貼り付け）
2. 何が入っているか自動判定（ローダー・MC版・必要なJavaを java -version で実測・ポート・ワールド名）
3. どこまで自分でやらせるかを選ぶ（manual / watch / unattended）
4. そのサーバーフォルダに環境を作る
5. -CheckOnly で検証して終わり（何も起動しない。起動するか最後に1回だけ聞く）
```

**サーバーフォルダに置かれるもの**（ここ以外には何も書かない）:

| ファイル | 何をする |
|---|---|
| `rk-start.bat` | **`run.bat` の代わりにこれをダブルクリック。** respawnkeeper 監視下でサーバーが動く |
| `rk-stop.bat` | **綺麗に停止。これで止めたものは自動再起動されない** |
| `rk-restart.bat` | **今すぐ点検つきで再起動**（予告 → 綺麗に停止 → ログ点検 → 起動）。日次点検と同じ経路を今走らせる |
| `rk-diagnose.bat` | 直近のクラッシュを読むだけ。何も変えない |
| `respawnkeeper\profile.json` | **そのサーバーの方針**（下記） |

### 方針は3つから選ぶ（サーバーごとに別々でよい）

| | 診断 | 自動修復 | 自動再起動 | モデル呼び出し |
|---|---|---|---|---|
| `manual` | ○ | ✕ | ✕ | ✕ |
| `watch` | ○ | ✕ | 無害と分かったものだけ | ✕ |
| `unattended` | ○ | ○ | ○ | ○（**1回目のクラッシュから**） |

**`unattended` でも止まる条件は残る**: クラッシュループ（30分に3回）／修復したのにまた落ちた／
モデルが「人の判断が要る」と書いた。**ファイルは絶対に消さない**（全部 `quarantine\` へ移動・`-Undo` で戻る）。

### ★ mod を外す判断軸 — 3つのゲート全部 ✅ のときだけ

| # | 問い | 測り方 |
|---|---|---|
| 1 | 原因が一意か | crash-report がその jar を名指ししているか |
| 2 | **道連れが0か** | 全 jar の `mods.toml` を読んで**逆依存を数える** |
| 3 | 友達に影響しないか | AutoModpack の配布リストに載っていないか |

**回数（N回落ちたら抜く）は軸にしない。** 回数が測るのは「しつこさ」であって「抜いたら直るか」ではないので。

実測（pokemoncraft・167 jar）: **125個が葉（誰も依存していない）／38個が依存されている。
`create` は33個から参照＝抜くのは1個ではなく34個。** だから抜かない。

`profile.json` の `allowModRemoval` は**測れない4つ目**（既に遊ばれたワールドから content mod を抜くと
チェストの中身が消える）で、`rk-setup` が一度だけ「このワールドは既に遊ばれていますか」と聞く。

**抜いても・抜けなくても `reports/comeback-<modid>-<日時>.md` を書く。**
何が壊れたか・3ゲートの結果・道連れの実名・**次にやれること6段**
（config → KubeJS → **Mixin** → **クラス補完シム** → 更新 → 恒久除去）。
**抜けなかったときの方が価値が高い** — そこが Mixin / シムの出番なので。

### モデルの財布（`unattended` のときだけ聞かれる）

| | 何 |
|---|---|
| `subscription`（既定） | `claude` CLI をアカウントログインで走らせる。**従量課金なし** |
| `api` | 同じCLIにAPIキーで課金させる |

**鍵は絶対に保存しない。** `profile.json` に入るのは**環境変数の「名前」だけ**で、値は
このPCの環境に既に設定されている必要がある。未設定のまま `api` を選ぶと、
**サブスクへ黙って戻らずに HALT する**（選んだのと違う財布から払わないため）。

### 日次の静的点検（既定OFF）

毎日決まった時刻に **予告 → クリーン停止 → その日のログを解析 → 報告書 → 再起動**。

**何も直さない。** クラッシュは別経路で即応するので、こちらは
**落ちないまま溜まっている問題**（黙って失敗したデータ読み込み、消えたAPIを呼び続けるスクリプト、
`Can't keep up!`）を数えて `reports/daily-YYYYMMDD.md` に残すだけ。
**モデルは使わない**（数えて畳むのは算術）。単独でも走らせられる:

```bash
powershell -File harness\rk-logscan.ps1 -ServerDir "<サーバーdir>" -SinceHours 24
```

`profile.json` はテキストなので後から手で直せる。優先順位は
**コマンドラインの switch > `profile.json` > `respawnkeeper.config.ps1` > 内蔵既定値**。

---

## まず打つコマンド（何も起動しない・安全）

```bash
powershell -File harness\respawnkeeper.ps1 -ServerDir "<サーバーdir>" -CheckOnly
```

ローダー種別・バージョン・**実際に `java -version` を叩いて確かめた Java**・ポート・レベル名・
今そのサーバーが動いているか・レガシー watchdog が残っていないか、までを出して終わる。

---

## ファイルの役割

| ファイル | 役割 | 単独で実行できるか |
|---|---|---|
| `..\respawnkeeper.exe` | **ダブルクリックの入口。** 引数なし＝**コントロールパネル**／フォルダを渡す＝ウィザード。ロジックは持たない [R-038]。git には入れていない（`launcher\build-exe.ps1` が作る） | ○ |
| `..\panel.bat` ／ `..\respawnkeeper.bat` | 同じ入口の退路（exe が SmartScreen 等で動かないとき） | ○ |
| `ui\rk-panel.ps1` | **コントロールパネル本体**。全サーバーの状態＋起動/停止/診断/報告。**読むだけ** [R-039] | ○ |
| `ui\panel-model.ps1` | パネルが知っていること（窓なし）。プレビューと共用 | — |
| `ui\render-preview.ps1` | **画面に出さずにPNGへ描く。** GUIの見た目を目で直すための治具 [R-040] | ○ |
| `ui\panel.xaml` ／ `ui\panel-strings.ja.json` | レイアウト ／ 日本語（**`.ps1` に日本語は書かない**） | — |
| `launcher\RespawnKeeper.cs` + `build-exe.ps1` | exe のソースとビルド。**Windows 同梱の `csc.exe` だけを使う**（何もダウンロードしない）。アイコンもここで描く | ○ |
| `..\finish-setup.bat` | 環境ごとに**1回だけ**: claude サインイン＋fc8旧heartbeat無効化 [R-036] | ○ |
| `rk-setup.ps1` | その中身。サーバー判定 → 方針選択 → `profile.json` と3つの `.bat` を生成 → 検証 | ○ |
| `respawnkeeper.ps1` | **司令塔**。起動→終了検知→診断→修復→再起動 or HALT | ○ |
| `respawnkeeper.config.ps1` | ハーネス共通の既定値。**サーバーごとの方針は `profile.json` が優先** | — |
| `rk-diagnose.ps1` | **1段目＝表引き診断**（LLM不使用）。読むだけ | ○ |
| `rk-repair.ps1` | 修復の実行。**既定はドライラン**、`-Apply` で実行、`-Undo` で巻き戻し | ○ |
| `rk-lock.ps1` | **排他ロック**。対話セッションはこれを見てから書く | ○ |
| `rules/crash-rules.psd1` | 1段目のルール表（16件・全件が実クラッシュ由来） | — |
| `games/*.psd1` | **ゲームごとの5つの答え**（起動/停止/ログ/クラッシュの見え方/直してよい場所） | — |
| `rk-newgame.ps1` | **未知のゲームのテンプレートを生成**。実フォルダで検証してから採用 | ○ |
| `rk-logscan.ps1` | **日次の静的点検**。ログを数えて畳んで報告書にする（LLM不使用） | ○ |
| `hooks/escalate-claude.ps1` + `escalate-prompt.md` | 2/3段目（Opus）。`unattended` のときだけ走る | 司令塔が呼ぶ |
| `lib/rk-common.ps1` | 共通関数（ローダー解決・生存判定・ロック・JSON） | — |
| `lib/rk-modgraph.ps1` | **除去の拒否権**。逆依存グラフと配布リストを読む | — |
| `tests/Invoke-SelfTest.ps1` | **自己テスト**。実 java を落として復旧まで通す（件数は実行結果の最終行に出る） | ○ |

**状態ファイルはサーバーの隣**（`<ServerDir>\respawnkeeper\`）に出る。ハーネスの隣ではない
（fc8 と pokemoncraft のログが混ざって `STATUS.txt` が無意味になるため。[R-003]）。

| `<ServerDir>\respawnkeeper\` | 中身 |
|---|---|
| `STATUS.txt` | 人が読む現状（`STATE:` と `INTENT:`） |
| `state.json` | 機械が読む現状。**`intent`＝SHOULD_RUN / STOPPED_BY_USER / HALTED** |
| `watchdog.log` / `repair.log` / `hangwatch.log` | 追記ログ |
| `diagnosis.json` | 直近の診断結果（全一致・根拠つき） |
| `repair-result.txt` | 判定1行（`FIXED:` / `HALT:` / `SECURITY-HALT:`） |
| `quarantine/<日時>/` | **隔離した実体＋`MANIFEST.json`**。`-Undo` の材料 |
| `reports/comeback-*.md` | **復帰の宿題。** 抜いた／抜けなかった mod をどう戻すか |
| `modgraph.json` | 逆依存グラフのキャッシュ（jar が変われば自動で作り直す） |
| `profile.json` | **そのサーバーの方針**（`rk-setup.ps1` が作る。手で直してよい） |
| `reports/daily-*.md` | **日次点検の報告書。** じっくり読む用 |
| `console/*.log` | ログファイルを書かないゲームの、記録したコンソール |
| `repair.lock` / `harness.lock` / `server.pid` | ロックとPID |

---

## 通常運用

```bash
# 起動（run.bat / start_server.ps1 の代わり）。落ちても既定では再起動しない
powershell -File harness\respawnkeeper.ps1 -ServerDir "<サーバーdir>"

# 無人復旧まで許す（自分で決めたときだけ）
powershell -File harness\respawnkeeper.ps1 -ServerDir "<サーバーdir>" -AutoRestart -AutoRepair
```

**綺麗に止める** — パネル／コンソール窓の **停止** ボタン、または `rk-stop.bat`。
同じことをコマンドでやるなら:

```bash
powershell -Command "New-Item -ItemType File -Path '<サーバーdir>\STOP_SERVER'"
```

**今すぐ点検つきで再起動する** — パネル／コンソール窓の **メンテ再起動** ボタン、または `rk-restart.bat`。
日次点検と**同じ経路**（予告 → 綺麗に停止 → ログ点検 → 起動）を今走らせる。予告は既定 60 秒
（`profile.json` の `dailyMaintenance.forcedWarnSeconds`）。放送手段の無いゲームは予告を飛ばして即停止。
**何も kill しない** — 綺麗に止まらなければ respawnkeeper は手を引く。

```bash
powershell -Command "Set-Content -Path '<サーバーdir>\MAINTENANCE_NOW' -Value '0' -NoNewline"   # 中身の数字＝予告秒。空なら既定
```

### ボタンは「誰かが聞いているか」を先に確かめる

`STOP_SERVER` / `MAINTENANCE_NOW` は **supervisor しか読まない**。誰も見張っていないサーバーに
フラグを置いても、次の起動時に黙って捨てられるだけになる。だからパネルとコンソール窓のボタンは
`respawnkeeper\harness.lock` の pid が**生きた respawnkeeper.ps1 か**を確かめてから書き、
違えば「受け取る相手がいない」と言って**何も書かない**。`run.bat` 等で外から起動したサーバーは
カードに「respawnkeeper の外で動いています」と出て、停止／メンテ再起動ボタンは押せない。

処理中はカードの状態欄が **停止を依頼済み → 保存して停止中… → 点検中 → 再起動中…** と動く
（`state.json` の `MAINT_PENDING` / `STOPPING` / `ANALYZING` / `RESTARTING`）。その間は
起動・停止・メンテ再起動の全部が押せない（停止中の上にもう1回停止を重ねても強くはならない）。

### ★ 手で止めたものは、絶対に再起動されない

終了コードだけでは「人が止めた」と「落ちた」を区別できない
（**タスクマネージャで java を殺すと終了コードは非0・crash-report は無し**＝クラッシュと同じ見た目）。
なので終了理由は3つの証拠で判定する:

| 証拠 | 判定 | ふるまい |
|---|---|---|
| crash-report がある／`hs_err_pid*.log` がある／ログ末尾に例外 | **crash** | 診断へ進む |
| ログ末尾に停止シーケンス（`Stopping server` / `Saving worlds` / `All dimensions are saved`） | **clean** | `intent=STOPPED_BY_USER` で終了 |
| **どれも無い**（タスクマネージャ・窓を閉じた・スリープ） | **unknown** | `STOPPED_EXTERNALLY` で終了。**再起動しない** |

`unknown` をクラッシュ扱いしないのは意図的。
**起動し直す手間は1回で済むが、作業中のサーバーを勝手に起こされる方が高くつく。**
逆にしたければ `profile.json` の `restartAfterUnknownExit` を `true` に。

---

## 通知（[R-023]）

トーストは**片道**。中身を読み返す処理は無く、announce する状態は全部
`STATUS.txt` / `state.json` / `watchdog.log` / `reports\` にも書かれる。
だからトーストの唯一の仕事は**人を起こすこと**で、切っても機能は何も壊れない。
壊れるのは「**落ちたまま止まっているのに気付けない**」ことだけ。

`profile.json` の `toastLevel`（既定 `important`）:

| level | 鳴るもの |
|---|---|
| `off` | 何も鳴らない。**HALT も届かない** |
| **`important`** | HALT 2種／修復したが手動起動待ち／既に起動していた |
| `all` | 上＋日常（日次メンテ完了・外から止められた・落ちたが対処中） |

**ハングは元から通知しない**（`hangwatch.log` に1行書くだけ・[R-029]）。

### Windows 側で切っている場合はこちらが強い

```
powershell -Command "Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\respawnkeeper' -Name Enabled -Value 1"
```

## 落ちたとき、中で何が起きるか

```
java 終了
  ├ 正常終了 or STOP_SERVER ──▶ intent=STOPPED_BY_USER。終わり（絶対に起こし直さない）
  └ クラッシュ
       │  crash-report は JVM 終了前に書き終わっているので、待たずに読める
       ├ ① サーキットブレーカー（30分に3回で HALT）── これは外せない
       ├ ② 1段目＝表引き（LLM不使用・16ルール・全一致を出す）
       │     ├ RESTART        … 一過性。そのまま再起動
       │     ├ 自動修復できる  … -AutoRepair があれば隔離/リセットして再起動
       │     └ 人間の判断が要る … escalateOnHalt が ON なら ③ へ／OFF なら HALT
       ├ ③ エスカレーション（Opus）── `unattended` のときだけ。判定は FIXED / HALT / SECURITY-HALT
       └ ④ 修復したのにまた落ちた ──▶ **再試行しない。HALT**（実測成功率 1/3）
```

**修復は必ず停止中**。しかも「止まっている」はフラグではなく、
**ポート・PIDファイル・java のコマンドラインの3点を毎回機械で確かめて**から進む。

---

## 対話セッションとの衝突を避ける（[R-008]）

ハーネスが修復に入るとロックを取る。**サーバー配下に書く前に必ずこれを打つ**：

```bash
powershell -File harness\rk-lock.ps1 -ServerDir "<サーバーdir>" -Check
```

`FREE`（exit 0）なら書いてよい。`HELD` / `STALE`（exit 3）なら**読むだけにする**。
死んだ持ち主のロックは自動で `STALE` になるので、修復が落ちてもサーバーが永久に塞がることはない。

---

## 修復を巻き戻す

```bash
powershell -File harness\rk-repair.ps1 -ServerDir "<dir>" -ListQuarantine
powershell -File harness\rk-repair.ps1 -ServerDir "<dir>" -Undo last -Apply
powershell -File harness\rk-repair.ps1 -ServerDir "<dir>" -Undo 20260826_210111 -Apply
```

**削除は一切しない。全部 `quarantine\` へ移すだけ。**

---

## 自己テスト

```bash
powershell -File harness\tests\Invoke-SelfTest.ps1
```

捨てディレクトリに偽サーバーを組み、**本物の java を本物の argfile 経路で起動して意図的に落とし**、
表引き→隔離→再起動→正常終了 までを通す（`tests\crashsim\CrashSim.java`）。
実サーバーには触らない（最後の2件だけ `-CheckOnly` 相当の読み取り確認）。
手で止めたときに再起動しないこと・`profile.json` が効くことも同じ治具で確かめている。
**2026-08-27 実測: PASS 107 / FAIL 0 / SKIP 0**（ゲーム検出・日次点検・除去ゲート・秘密の伏せ字を含む）。
その後に試験を足したので、今の件数は実行結果の最終行（`PASS n   FAIL n   SKIP n`）で見る。

---

## fc8 に使うときの前提

fc8 には**旧 watchdog（`watchdog\fc8_watchdog.ps1`）と Layer2 のタスクスケジューラ
`FC8WatchdogHeartbeat` が今も生きている**（2026-08-26 時点で armed・当日実行あり）。
2つの司令塔が同じサーバーを起こし合うので、**respawnkeeper は armed なら起動を拒否する**。
先に外す：

```bash
powershell -File "<fc8>\watchdog\uninstall_heartbeat.ps1"
```

---

## 表（1段目）を育てる

`rules/crash-rules.psd1` に1行足すだけで、次から同じクラッシュは**モデル無しで**片付く。
**実際に起きたクラッシュだけを足す**（`evidence` 欄が必須。自己テストがそれを検査する）。
エスカレーションが走ったときは、レポート末尾に「表に足すべきパターン」を書かせてあるので、
そこから拾う。**表への追加の採否はエヴァが決める。**
