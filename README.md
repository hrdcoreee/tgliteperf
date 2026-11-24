# tgliteperf

Лёгкий runtime-твик (`.dylib` / `.deb`) для **Telegram** и **Swiftgram**, который убирает главные причины тормозов на старых iPhone (iPhone 7, 8, X, XR, XS, 11, SE 2 и любых устройствах с 2–4 ГБ RAM) без необходимости пересобирать весь клиент через Bazel/Xcode.

## Что делает твик

1. **Полное отключение блюра и 3D-стекла (Flat UI):**
   - **Полное отключение блюра:** полностью нейтрализует все `UIVisualEffectView` в приложении (алерты, модальные окна, шторки, контекстные меню, плееры) и заменяет их на быстрый плоский полупрозрачный фон (Flat UI).
   - Перехватывает `UIAccessibilityIsReduceTransparencyEnabled` (через `fishhook`) — `NavigationBackgroundNode` (навбары, таббары, плашки дат в чате, включая захардкоженные места) переключается на плоскую заливку без `UIVisualEffectView`.
   - Отключает `CABackdropLayer`, `filters` и 3D-деформацию `meshTransform` (`LegacyGlassView`).
   - На iOS 26+ переводит `UIGlassEffect` в лёгкий плоский фон.
   - Убирает оффскрин-тени без `shadowPath` в слоях SwiftUI-тулбара и стекла.
2. **Облегчает анимации эмодзи (30 FPS):**
   - Включает `isLowPowerModeEnabled` внутри приложения — `DCTMultiAnimationRendererImpl` и `SubcodecMultiAnimationRendererImpl` снижают частоту тиков кастомных эмодзи с 60 до 30 FPS (нагрузка на CPU/GPU падает вдвое).
3. **Ограничивает генераторы частиц (`CAEmitterLayer`):**
   - Снижает `birthRate` на 75% и `speed` для спойлеров, звёзд и эффектов.
4. **Отключает живую камеру в галерее:**
   - Автоматически включает `disableGalleryCameraPreview` в Swiftgram и блокирует живой рендер `AVCaptureVideoPreviewLayer` внутри сетки пикера в обычном Telegram (полноэкранная камера, кружочки и QR-сканер работают как обычно).
5. **Встроенное меню настроек:**
   - **Долгое удержание (0.85 сек) в нижней части экрана** (на панели вкладок) ИЛИ **тройной тап двумя пальцами** в любом месте открывает меню `TGLitePerf` со всеми переключателями.

## Как установить

- **Без джейлбрейка (TrollStore / Sideloadly / AltStore / ESign / Feather / TrollFools):**
  1. Скачайте `TGLitePerf.dylib` из вкладки **Actions** на GitHub.
  2. Вшейте `TGLitePerf.dylib` в готовый `.ipa` Telegram или Swiftgram (на iPhone через ESign/Feather/TrollFools, либо на Linux/macOS через [`cyan`](https://github.com/asdfzxcvbn/pyzule-rw): `cyan -i Swiftgram.ipa -o Swiftgram-Lite.ipa -f TGLitePerf.dylib`).
  3. Также можно запустить воркфлоу **Build TGLitePerf** вручную на GitHub Actions (`Run workflow`), указав `ipa_url` — CI сам скачает `.ipa` и вошьёт туда `TGLitePerf.dylib` прямо на `ubuntu-latest`.
- **С джейлбрейком (Dopamine / palera1n):**
  Установите готовый `.deb` (`rootless` или `rootful`) из артефактов GitHub Actions.

## Локальная сборка на Linux

```bash
# Нужны clang, lld, ldid и распакованный iPhoneOS16.5.sdk
SDK_PATH=/path/to/iPhoneOS16.5.sdk ./build.sh
```
