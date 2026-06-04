$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
$env:PUB_CACHE = (Join-Path $PSScriptRoot ".pub-cache")

if ($env:FLUTTER_ROOT) {
    $flutterFromRoot = Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
    if (Test-Path $flutterFromRoot) {
        & $flutterFromRoot @args
        exit $LASTEXITCODE
    }
}

$self = (Resolve-Path $PSCommandPath).Path
$flutter = Get-Command flutter.bat -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -ne $self } |
    Select-Object -First 1

if (-not $flutter) {
    Write-Error "Flutter SDK not found. Add Flutter's bin directory to PATH or set FLUTTER_ROOT."
    exit 1
}

& $flutter.Source @args
exit $LASTEXITCODE
