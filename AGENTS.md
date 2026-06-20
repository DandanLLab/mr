# MR — Multimedia Reader (Flutter)

## Commands

```bash
flutter pub get          # install dependencies
flutter run              # run on connected device/emulator
flutter build apk        # build Android APK
flutter test             # run all tests (`test/`)
flutter analyze          # lint + static analysis
```

## Testing

Three test files in `test/`:
- `widget_test.dart` — placeholder, always passes
- `legado_rule_test.dart` — CSS/JSoup chain selector rules
- `book_source_compat_test.dart` — book source import, URL parsing, metadata merge, source locator

```bash
flutter test test/legado_rule_test.dart        # focused test
flutter test test/book_source_compat_test.dart  # focused test
```

No CI test step — tests are local-only.

## Architecture

| Layer | Technology |
|-------|-----------|
| State | Provider (6 providers in `lib/providers/`) |
| Storage | Hive (init in `main.dart`) |
| HTTP | Dio (web needs CORS proxy via `ProxyService`) |
| JS | Dual engine: QuickJS (`flutter_js`) + Rhino (Android native), dispatched by `EngineDispatcher` |
| Routing | Custom `AppPageRoute` with `PageRouteBuilder`, zero-duration transitions, defined in `lib/routes/app_routes.dart` |

Entrypoint: `lib/main.dart` — initializes Hive, `StorageService`, `JsEngine`, `CoverConfigService`, then runs `DanShenqiApp`.

### Key directories

```
lib/
  services/source_engine/   # Legado rule engine core (analyze_rule, web_book, legado_json_path, legado_xpath, js_engine, proxy_service)
  services/native/          # JS engine dispatcher, extensions bridge, platform channel
  models/                   # BookSource, Book, Chapter, etc.
  pages/                    # 13 subdirectories: bookshelf, reader(comic+novel), player(audio+video), debug, etc.
  providers/                # App, Bookshelf, Discovery, Reader, Search, ExploreShow
  routes/
  utils/
  widgets/
  themes/
```

## Web platform

CORS proxy is started automatically when `kIsWeb` via `ProxyService.instance.start()` in `main.dart`. Tools: `tools/cors-proxy.js`.

## Linter

Rules in `analysis_options.yaml` (note: file is `.gitignore`d): `avoid_print`, `prefer_single_quotes`, `sort_child_properties_last`, `use_key_in_widget_constructors`, `prefer_const_constructors`, `prefer_final_fields/locals`, `prefer_const_declarations`.

Use `debugPrint` instead of `print` (enforced by `avoid_print`).

## CI

`.github/workflows/main.yml` — auto-merges all branches to `master` on push (with conflict → PR fallback). No test/lint checks in CI.

## Conventions

- Chinese comments and identifiers throughout (project is Chinese-language)
- Routes use `Map<String, dynamic>?` arguments (see `app_routes.dart` patterns)
- Route arguments may be `Map` (dynamic) or `Map<String, dynamic>` — code handles both with `is Map` checks
- `Book.fromJson` / `BookSource.fromJson` for serialization
