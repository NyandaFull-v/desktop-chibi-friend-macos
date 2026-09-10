$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root 'Sources\DesktopChibiFriendMac'
$character = Join-Path $root 'Resources\characters\chibidaful'
$requiredSources = @('main.swift','AppDelegate.swift','Models.swift','SpriteStore.swift','Views.swift','SystemIntegration.swift','SettingsController.swift','PetController.swift')
$requiredImages = @('sprites-v5.png','coin-v2.png','animations-sit-walk-v7.png','animations-pet-climb-v6.png','animations-sleep-look-trip-v6.png','animations-dig-v3.png','items-accessories-v3.png','items-sweets-v3.png','items-toys-v3.png')
foreach ($name in $requiredSources) { if (-not (Test-Path (Join-Path $source $name))) { throw "Missing source: $name" } }
foreach ($name in $requiredImages) { if (-not (Test-Path (Join-Path $character $name))) { throw "Missing image: $name" } }
$definition = Get-Content -Raw (Join-Path $character 'character.json') | ConvertFrom-Json
if ($definition.poses.Count -ne 9) { throw 'Pose count must be 9.' }
if (@($definition.animationSheets.PSObject.Properties).Count -ne 4) { throw 'Animation sheet count must be 4.' }
$swift = (Get-ChildItem $source -Filter *.swift | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
foreach ($token in @('rightMouseDown','AXIsProcessTrustedWithOptions','CGWindowListCopyWindowInfo','SMAppService.mainApp','com.obsproject.obs-studio','1d100','おわり！！')) {
    if (-not $swift.Contains($token)) { throw "Expected feature token missing: $token" }
}
Write-Host "Mac移植 静的検査: 正常"
Write-Host "ソース $($requiredSources.Count)本 / 画像 $($requiredImages.Count)枚 / ポーズ $($definition.poses.Count)種"
Write-Host '注: 実コンパイルと動作確認はmacOS 13以降で validate-macos.sh を実行してください。'
