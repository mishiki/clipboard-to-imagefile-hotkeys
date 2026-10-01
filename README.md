# Clipboard Image Hotkeys

Windowsのクリップボード画像を一時PNGへ変換し、ファイルとして貼り付け・ドラッグできるようにする小さな常駐PowerShellユーティリティです。

Website: https://mishiki.github.io/clipboard-to-imagefile-hotkeys/

## ホットキー

| ホットキー | 動作 |
| --- | --- |
| `Win + Shift + B` | 現在のクリップボード画像をストックへ追加 |
| `Ctrl + Shift + Alt + V` | ストック全件をFileDropListとしてクリップボードへ設定。ストックがなければ現在の画像を単発変換 |
| `Win + Shift + O` | 現在の画像をPNG化し、Explorerで選択して表示 |
| `Win + Shift + Q` | 常駐ユーティリティを終了 |

`Ctrl + Shift + Alt + V` ではFileDropListを優先しつつ、可能な場合は画像形式も同じクリップボードデータに含めます。ストックは公開成功後に消費されます。

After Effectsの「フレームをクリップボードにコピー」など、PNG形式を含む画像はPNGを優先して読み取り、透明度を保ってファイル化します。変換後のクリップボードにはPNG形式も含めます。PNG形式がない場合は通常のビットマップ形式を使用します。

PNGは `%TEMP%\ClipboardImage\` に保存されます。24時間を超えたファイルを削除し、残りが100枚を超える場合は古いものから削除します。整理は起動時と各操作後に実行されます。

## 必要環境

- Windows 10またはWindows 11
- Windows PowerShell 5.1
- 追加モジュール不要

## インストール

PowerShellでこのフォルダへ移動し、次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

実行ファイルを `%LOCALAPPDATA%\ClipboardImageHotkeys\` へコピーし、現在のユーザーのスタートアップフォルダーへ `-WindowStyle Hidden` と `-NoWindow` 付きの起動用ショートカットを追加します。次回ログオン時はPowerShellのコンソールと管理画面を出さずに常駐を開始します。同じショートカットを常駐中にもう一度開くと、PowerShellのコンソールは隠したまま、既存の常駐を増やさず管理画面を表示します。リポジトリのフォルダは後から移動・削除できます。

スタートメニューに `Clipboard Image Hotkeys` が追加されます。開くと現在の稼働状態を確認し、起動・再起動・停止できます。

自動起動だけ登録し、今すぐ起動しない場合:

```powershell
.\Install.ps1 -NoStart
```

## 手動実行

管理画面を開く:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\ClipboardImage.ps1
```

管理画面を開かずに常駐を開始する:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File .\ClipboardImage.ps1 -NoWindow -HideConsole
```

状態確認:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\ClipboardImage.ps1 -Action Status
```

ログは `%TEMP%\ClipboardImage\ClipboardImage.log` に保存されます。

## アンインストール

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

常駐を終了し、スタートアップ登録と一時ファイルを削除します。一時PNGを残す場合は `-KeepTemporaryFiles` を付けます。

## 動作確認

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-ClipboardImage.ps1
```

テストは実際のWindowsクリップボードと常駐メッセージループを使います。テスト中はクリップボード内容が置き換わります。

## 注意事項

- 対象アプリがFileDropListの貼り付けに対応していない場合は、`Win + Shift + O` でExplorerを開き、ドラッグ＆ドロップしてください。
- `RegisterHotKey` が他アプリと競合する場合は、自動的に低レベルキーボードフックへ切り替えます。キー入力は保存・送信せず、指定4ホットキーだけを判定します。
- 一時PNGは永続保存用ではありません。必要な画像は別の場所へ移してください。

## License

MIT
