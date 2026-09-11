#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

plutil -lint Info.plist
python3 - <<'PY'
import json
from pathlib import Path
root = Path('Resources/characters/chibidaful')
definition = json.loads((root / 'character.json').read_text(encoding='utf-8'))
required = [definition['spriteSheet'], definition['coinFile']]
required += [value['file'] for value in definition['animationSheets'].values()]
required += list(definition['itemAtlases'].values())
missing = [name for name in required if not (root / name).is_file()]
assert not missing, f'不足画像: {missing}'
assert definition['columns'] == 3 and definition['rows'] == 3
assert len(definition['poses']) == 9
assert len(definition['normalSpeech']) > 0 and len(definition['maybeSpeech']) > 0
print(f'画像定義: 正常 ({len(required)}ファイル)')
PY
swift build -c release
echo "Swiftビルド: 正常"

python3 - <<'PY'
from pathlib import Path
source = Path('Sources/DesktopChibiFriendMac/PetController.swift').read_text(encoding='utf-8')
start = source.index('private func collect(_ object: WorldObject)')
end = source.index('private func beginChase()', start)
collect = source[start:end]
for required in ('velocity = .zero', 'targetSurface = nil', 'phantomClimb = false', 'mode = .normal'):
    assert required in collect, f'取得停止処理が不足: {required}'
print('取得停止の回帰検査: 正常')
PY

if [ -d "dist/デスクトップちびフレンド.app" ]; then
  codesign --verify --deep --strict "dist/デスクトップちびフレンド.app"
  plutil -lint "dist/デスクトップちびフレンド.app/Contents/Info.plist"
  echo "アプリ構成と署名: 正常"
fi
