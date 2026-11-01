<img src="assets/icon.png" width="96" height="96" alt="Image Studio icon">

# Image Studio

A minimal, personal iOS app for generating images with the OpenAI Image API.

- **Prompt box** pinned to the bottom of the library, showing the active model, size, quality and image count. Tap any chip to change it for the next generation, or open the options sheet for everything else (background, format, compression, moderation).
- **Reference images:** attach up to 16 images from Photos with the photo button in the prompt box, or long-press a library image and choose **Use as Reference**. Requests with references use OpenAI's `/images/edits` endpoint, so you can restyle, combine or build on existing images. References are downscaled to 2048 px and stored with the images they produced. Regenerate and Reuse Prompt carry them over.
- **Defaults** for new generations are set in Settings. Per-generation changes are highlighted and can be reset in one tap.
- **Library** grid in the style of Photos. Long-press an image to export, copy, regenerate, reuse its prompt, select or delete it. Use **Select** to export, regenerate or delete several images at once.
- **Detail view** with the image, prompt and generation details (model, size, quality, format, timing, tokens), plus export, regenerate and delete. Images made from references list them, and you can tap a reference to view it. Swipe between images; tap an image to view it full screen with pinch-to-zoom.
- **Live Activity and notifications:** while generations run, a Live Activity on the Lock Screen and in the Dynamic Island shows how many images are on the way, the latest prompt and the elapsed time. When the last one finishes it shows a summary (e.g. "3 images ready, 1 failed") for 15 minutes, or closes at once if Image Studio is open. A generation that finishes or fails while the app isn't open also posts a notification with a thumbnail; tap it to open the image. Image Studio asks for notification permission the first time you generate. Both can be turned off in the Settings app.
- **Secure API key**: stored in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`, so background generations can read it while the phone is locked), never synced or backed up, and checked against OpenAI when you save it. Keys saved by earlier versions are migrated automatically. If the Keychain can't be read, Settings says so and offers to retry instead of acting as if no key were saved.
- **Resilient to a damaged library**: if the library database can't be opened, the app shows a recovery screen instead of crashing. **Try Again** retries; **Reset Library** moves the store files (never deletes them) to `Application Support/Library Backups/<timestamp>/` and starts a fresh library. Image files in `Application Support/Images` are untouched. Missing or undecodable image files show an "image unavailable" placeholder, and Export and Copy are disabled for them.

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
  Services/       OpenAIImageClient, GenerationSession, Keychain/APIKeyStore, ImageStore/ImageLoader, ReferenceStore,
                  GenerationUpdates (Live Activity and notifications)
  State/          Studio (runs generations, owns library changes), Preferences, Composer
  Views/          Library, Composer, Detail, Settings, shared components
  Debug/          Sample library seeding (DEBUG builds only)
  Resources/      Asset catalog
ImageStudioWidgets/ Widget extension: the Live Activity's Lock Screen and Dynamic Island views
Shared/           Code compiled into both the app and the extension (Live Activity attributes)
ImageStudioTests/ Swift Testing unit tests
scripts/          make-icon.swift (renders the app icon)
```

Original image files are stored in `Application Support/Images`, and metadata is stored in SwiftData (`default.store` in Application Support). Thumbnails are downsampled off the main thread and cached in memory.

## Development notes

- **Sample data:** in a DEBUG build, launch with `-SeedSampleLibrary` to fill an empty library with locally rendered placeholder images. This lets you work on the UI without spending API credit. You can toggle it under *Edit Scheme → Run → Arguments*. `-SeedPendingJobs` adds an in-progress tile and a failed tile. `-SimulateLibraryOpenFailure` forces the library recovery screen (it succeeds again once you choose Reset Library).
- **Mock API:** `python3 scripts/mock_openai.py 20` serves fake images after a 20-second delay on `127.0.0.1:8765`. Launch a DEBUG build with `-OpenAIBaseURL http://127.0.0.1:8765/v1` to use it. Any key will verify. It handles both `/images/generations` and multipart `/images/edits` requests. Add a second argument, e.g. `20 2`, to fail the first two requests with 503 + `Retry-After` and exercise automatic retries.
- **Background generation:** requests run on a background `URLSession` (`GenerationSession`), so they continue while the app is suspended or after the system terminates it. Pending and failed jobs are stored as `PendingGeneration` records. Force-quitting the app cancels in-flight requests; those jobs show as failed with Retry.
- **Live Activity and notifications:** `GenerationActivityController` starts the activity when a generation starts (ActivityKit only allows that in the foreground) and updates or ends it from background relaunches too. `GenerationNotifier` posts notifications only when the app isn't active. With the mock API above, start a generation and go to the Home Screen to see both. Preview the activity's layouts in `ImageStudioWidgets/GenerationLiveActivity.swift`.
- **App icon:** `swift scripts/make-icon.swift ImageStudio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- **Signing:** automatic signing with team `359794K46A` (set in `project.yml`).
