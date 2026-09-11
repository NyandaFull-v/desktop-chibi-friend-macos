# デスクトップちびフレンド v0.4.2-mac 移植設計

## 完成基準

Windows版 v0.4.2 の機能・キャラクター画像・初期値を基準とする。Mac版固有の見た目や権限処理を除き、利用者から見える動作を同じにする。

## Windowsからの置換

| 項目 | Windows版 | Mac版 |
|---|---|---|
| 透過キャラ | Win32 layered window | AppKitの非アクティブ透明NSPanel |
| ウィンドウ検出 | EnumWindows / DWM | CGWindowListCopyWindowInfo |
| 全体マウス | Win32メッセージ | Core Graphics event tap |
| デスクトップ空白 | Explorer Accessibility | macOS Accessibility API |
| 全画面・ゲーム | 前景exeとモニター矩形 | 前景app bundleとウィンドウ矩形 |
| OBS検出 | プロセス列挙 | NSWorkspace runningApplications |
| OBS配信 | Winsock | Network.framework、127.0.0.1限定 |
| 自動起動 | Windows Startup | SMAppService.mainApp |
| ロック・スリープ | WTS / power message | NSWorkspace通知 |
| 保存 | exe横のdata | Application Support |

## 座標と地形

内部座標はAppKitに合わせ、左下を原点、上方向を正とする。Quartzの左上原点座標はメイン画面上端を基準に変換する。全モニターの `visibleFrame.minY` を常設の地面として登録し、小ウィンドウ上端と同じ落下交差判定を使う。

通常移動は移動前のモニターを保持する。端を越えた場合だけ隣接モニターを探し、移動先画面上部から落下へ切り替える。全画面やゲームからの避難、回収不能時のメイン画面復帰とは別経路にする。

## 入力

キャラ自身のクリックとドラッグは小型NSPanelだけで処理する。デスクトップ右ダブルクリックはCore Graphicsで監視する。Finderのコンテキストメニューが1回目の右クリック後に現れても、最初の位置が空白で2回目が近接・規定時間内なら召喚を成立させる。左トリプルクリックは怒って帰宅中の呼び戻しだけに使う。

## 省メモリ

- 全画面サイズの透明ウィンドウを作らない。
- 現在のポーズ系列だけをデコードして保持する。
- コイン・アイテム・吹き出しは必要な間だけ小型NSPanelを作る。
- 設定画面は初回表示時に生成し、普段は閉じる。
- OBSサーバーはOBS起動中だけ開始する。

## 保存と移行

Mac版の保存先は `~/Library/Application Support/DesktopChibiFriend/`。初回起動時、その保存先が空で `.app` と同じ場所にWindows版の `data` フォルダがあれば、コイン、所持品、所持数、次回コイン・会話時刻、設定を読み込む。Windowsの画面座標だけはMacで無効なので移行しない。

## Mac固有の制約

- グローバルクリックとデスクトップ空白確認には利用者によるアクセシビリティ許可が必須。
- 簡易署名版のため、初回はControlクリックの「開く」が必要になる場合がある。
- macOSの実コンパイル、権限画面、複数モニター、OBS連動はMac実機でのみ最終判定できる。
- Mac版はFences 4を参照せず、起動・終了・ウィンドウ状態へ一切干渉しない。
