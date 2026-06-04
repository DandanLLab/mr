@echo off
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
set PUB_CACHE=%~dp0.pub-cache

if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\flutter.bat" (
  call "%FLUTTER_ROOT%\bin\flutter.bat" %*
  exit /b %errorlevel%
)

for /f "delims=" %%F in ('where flutter.bat 2^>nul') do (
  if /i not "%%~fF"=="%~f0" (
    call "%%~fF" %*
    exit /b %errorlevel%
  )
)

echo Flutter SDK not found. Add Flutter's bin directory to PATH or set FLUTTER_ROOT. 1>&2
exit /b 1
