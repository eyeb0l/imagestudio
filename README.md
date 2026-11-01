<img src="assets/icon.png" width="96" height="96" alt="Image Studio icon">

# Image Studio

A minimal, personal iOS app for generating images with the OpenAI Image API.

- **Prompt box** pinned to the bottom of the library, showing the active model, size, quality and image count. Tap any chip to change it for the next generation, or open the options sheet for everything else (background, format, compression, moderation).
- **Defaults** for new generations are set in Settings. Per-generation changes are highlighted and can be reset in one tap.
- **Library** grid in the style of Photos. Long-press an image to export, copy, regenerate, reuse its prompt, select or delete it. Use **Select** to export, regenerate or delete several images at once.
- **Detail view** with the image, prompt and generation details (model, size, quality, format, timing, tokens), plus export, regenerate and delete. Swipe between images; tap an image to view it full screen with pinch-to-zoom.
- **Secure API key**: stored in the iOS Keychain (`WhenUnlockedThisDeviceOnly`), never synced or backed up, and checked against OpenAI when you save it.

## Requirements

- Xcode 26 or later (built with Xcode 27.2)
- iOS 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An OpenAI API key from a [verified organization](https://platform.openai.com/settings/organization/general) (required for GPT Image models)

## Getting started

```sh
xcodegen            # generates ImageStudio.xcodeproj from project.yml
open ImageStudio.xcodeproj
```

The Xcode project is generated and git-ignored, so **`project.yml` is the source of truth**. Run `xcodegen` again after adding, removing or renaming files, or after changing build settings.

Then run on a device or simulator and add your API key in Settings (the gear icon).

### Command line

```sh
xcodegen
xcodebuild -scheme ImageStudio -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme ImageStudio -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Models

| Model | Sizes | Quality |
| --- | --- | --- |
| GPT Image 2.5 Flare (default) | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max |
| GPT Image 2.5 Sunburst | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max |
| GPT Image 2 | Presets, 2K/4K, custom | Auto, Low–High |
| GPT Image 1.5 | 1024², 1536×1024, 1024×1536 | Auto, Low–High |
| GPT Image 1 Mini | 1024², 1536×1024, 1024×1536 | Auto, Low–High |

Custom sizes must use multiples of 16, have an aspect ratio between 1:3 and 3:1, and fall between 655,360 and 8,294,400 pixels (at most 3840 px per side). Sizes above 2560×1440 are experimental. When you switch models, unsupported options fall back to valid values automatically. Model capabilities live in `ImageStudio/Models/GenerationSettings.swift`.

## Project layout

```
ImageStudio/
  App/            App entry point and dependency wiring
  Models/         GenerationSettings (options and validation), GeneratedImage (SwiftData)
  Services/       OpenAIImageClient, Keychain/APIKeyStore, ImageStore/ImageLoader
  State/          Studio (runs generations, owns library changes), Preferences, Composer
  Views/          Library, Composer, Detail, Settings, shared components
  Debug/          Sample library seeding (DEBUG builds only)
  Resources/      Asset catalog
ImageStudioTests/ Swift Testing unit tests
scripts/          make-icon.swift (renders the app icon)
```

Original image files are stored in `Application Support/Images`, and metadata is stored in SwiftData. Thumbnails are downsampled off the main thread and cached in memory.

## Development notes

- **Sample data:** in a DEBUG build, launch with `-SeedSampleLibrary` to fill an empty library with locally rendered placeholder images. This lets you work on the UI without spending API credit. You can toggle it under *Edit Scheme → Run → Arguments*. `-SeedPendingJobs` adds an in-progress tile and a failed tile.
- **Mock API:** `python3 scripts/mock_openai.py 20` serves fake images after a 20-second delay on `127.0.0.1:8765`. Launch a DEBUG build with `-OpenAIBaseURL http://127.0.0.1:8765/v1` to use it. Any key will verify.
- **Background generation:** requests run on a background `URLSession` (`GenerationSession`), so they continue while the app is suspended or after the system terminates it. Pending and failed jobs are stored as `PendingGeneration` records. Force-quitting the app cancels in-flight requests; those jobs show as failed with Retry.
- **App icon:** `swift scripts/make-icon.swift ImageStudio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- **Signing:** automatic signing with team `359794K46A` (set in `project.yml`).
