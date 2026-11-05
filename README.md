<img src="assets/icon.png" width="96" height="96" alt="Image Studio icon">

# Image Studio

A minimal, personal iOS app for generating images with the OpenAI Image API.

- **Prompt box** pinned to the bottom of the library, showing the active model, size, quality and image count. Tap any chip to change it for the next generation, or open the options sheet for everything else (complexity on GPT Image 2.6, background, format, compression, moderation, frames and frame duration for GIFs).
- **SVG output:** on GPT Image 2.6, choose **SVG** as the format to get an editable vector, such as an icon or a logo. A request makes one image, so the image count locks to 1 and says why. Quality and complexity apply to the reference image OpenAI creates first; a second model, the **SVG Author** you choose in the options sheet (GPT-6.1 Terra by default), then writes the SVG. It is billed separately at its own rates, and the details list its tokens apart from the image's. Library tiles show an SVG badge, and the detail view lists its shape rather than a resolution. Zooming in full screen renders more detail, so it stays sharp. Anything an SVG leaves unpainted shows a light checkerboard, in dark mode too, so black or white artwork stays visible. Export and Copy keep the original file (Copy also offers it as text). An SVG can't be used as a reference. A notification for one that finishes in the background has no thumbnail, unless it's already been shown.
- **Animated GIFs:** on GPT Image 2.6, choose **GIF** as the format and set the frames (2–16) and frame duration (20–2000 ms) in the options sheet. Describe the motion and the loop in your prompt. Library tiles show the first frame with a GIF badge. The detail view and the full-screen viewer play the animation, looping, while it's on screen; with Reduce Motion on or Auto-Play Animated Images off they show the first frame. Export and Copy keep the original GIF file. GIF output may need preview access from OpenAI; if not, the failed tile shows OpenAI's error.
- **Reference images:** attach up to 16 images from Photos with the photo button in the prompt box, or long-press a library image and choose **Use as Reference**. Requests with references use OpenAI's `/images/edits` endpoint, so you can restyle, combine or build on existing images. References are downscaled to 2048 px and stored with the images they produced. Regenerate and Reuse Prompt carry them over. `/images/edits` can't return GIFs or SVGs, so attaching a reference while one of them is selected switches the format to PNG and says so; removing the references brings it back, and your saved defaults don't change. A GIF used as a reference is sent as its first frame.
- **Markup-guided edits:** draw on an image to show where a change should happen, then describe the change in the prompt. Use the pencil on the first reference in the prompt box, or long-press a library image (or open its **More** menu) and choose **Mark Up**. That image becomes the first reference and any others stay behind it; cancelling leaves the prompt box as it was. Draw with a finger or Apple Pencil, in any orientation. Your strokes are kept, so you can come back and change them; **Done** with nothing drawn means no markup. OpenAI gets the original image plus your strokes as a separate transparent PNG of exactly the same size. Markup belongs to the first reference, so if that changes the markup is removed and the app says so. It needs GPT Image 2.5 or 2.6: other models can't be chosen while it's attached, and if your choice is one of them, GPT Image 2.6 Flare is used instead and says so, without changing your defaults. Regenerate, Reuse Prompt and Retry carry the markup over, and if its file has gone the generation fails rather than sending an unmarked edit. Images made with markup show it beside their references; tap it to see it on the image.
- **Defaults** for new generations are set in Settings. Per-generation changes are highlighted and can be reset in one tap.
- **Library** grid in the style of Photos. Long-press an image to export, copy, regenerate, reuse its prompt, select or delete it. Use **Select** to export, regenerate or delete several images at once.
- **Detail view** with the image, prompt and generation details (model, size, quality, complexity, frames for GIFs, format, timing, tokens), plus export, regenerate and delete. Images made from references list them, and you can tap a reference to view it. Swipe between images; tap an image to view it full screen with pinch-to-zoom.
- **Live Activity and notifications:** while generations run, a Live Activity on the Lock Screen and in the Dynamic Island shows how many images are on the way, the latest prompt and the elapsed time. When the last one finishes it shows a summary (e.g. "3 images ready, 1 failed") for 15 minutes, or closes at once if Image Studio is open. A generation that finishes or fails while the app isn't open also posts a notification with a thumbnail; tap it to open the image. Image Studio asks for notification permission the first time you generate. Both can be turned off in the Settings app.
- **Secure API key**: stored in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`, so background generations can read it while the phone is locked), never synced or backed up, and checked against OpenAI when you save it. Keys saved by earlier versions are migrated automatically. If the Keychain can't be read, Settings says so and offers to retry instead of acting as if no key were saved.
- **Resilient to a damaged library**: if the library database can't be opened, the app shows a recovery screen instead of crashing. **Try Again** retries; **Reset Library** moves the store files (never deletes them) to `Application Support/Library Backups/<timestamp>/` and starts a fresh library. Image files in `Application Support/Images` are untouched. Missing or undecodable image files, including SVGs that are malformed or that take too long to draw, show an "image unavailable" placeholder. Export and Copy are disabled if the file is missing, but stay available for a file that can't be drawn, so you can still get it out and look at it.

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

| Model | Sizes | Quality | Complexity | Formats |
| --- | --- | --- | --- | --- |
| GPT Image 2.6 Flare (default) | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max | Low–High | PNG, JPEG, WebP, GIF, SVG |
| GPT Image 2.6 Sunburst | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max | Low–High | PNG, JPEG, WebP, GIF, SVG |
| GPT Image 2.5 Flare | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max | — | PNG, JPEG, WebP |
| GPT Image 2.5 Sunburst | Presets, 2K/4K, custom | Auto, Low–High, Extra High, Max | — | PNG, JPEG, WebP |
| GPT Image 2 | Presets, 2K/4K, custom | Auto, Low–High | — | PNG, JPEG, WebP |
| GPT Image 1.5 | 1024², 1536×1024, 1024×1536 | Auto, Low–High | — | PNG, JPEG, WebP |
| GPT Image 1 Mini | 1024², 1536×1024, 1024×1536 | Auto, Low–High | — | PNG, JPEG, WebP |

Custom sizes must use multiples of 16, have an aspect ratio between 1:3 and 3:1, and fall between 655,360 and 8,294,400 pixels (at most 3840 px per side). Sizes above 2560×1440 are experimental. A GIF's frame count, frame size and image count must also fit OpenAI's total pixel budget; if a request is rejected, reduce one of them. When you switch models, unsupported options fall back to valid values automatically. Model capabilities live in `ImageStudio/Models/GenerationSettings.swift`.

## Project layout

```
ImageStudio/
  App/            App entry point and dependency wiring
  Models/         GenerationSettings (options and validation), GeneratedImage (SwiftData)
  Services/       OpenAIImageClient, GenerationSession, Keychain/APIKeyStore, ImageStore/ImageLoader, AnimatedImageDecoder, SVGDocument, SVGRasterizer, ReferenceStore, MarkupStore,
                  GenerationUpdates (Live Activity and notifications)
  State/          Studio (runs generations, owns library changes), Preferences, Composer
  Views/          Library, Composer, Detail, Markup, Settings, shared components
  Debug/          Sample library seeding (DEBUG builds only)
  Resources/      Asset catalog
ImageStudioWidgets/ Widget extension: the Live Activity's Lock Screen and Dynamic Island views
Shared/           Code compiled into both the app and the extension (Live Activity attributes)
ImageStudioTests/ Swift Testing unit tests
scripts/          make-icon.swift (renders the app icon)
```

Original image files are stored in `Application Support/Images`, and metadata is stored in SwiftData (`default.store` in Application Support). Thumbnails are downsampled off the main thread and cached in memory. Bitmaps rendered from SVGs are also cached in `Caches/SVGRasters`, up to 2048 px, and deleted with their image or when the library is reset.

## Development notes

- **Sample data:** in a DEBUG build, launch with `-SeedSampleLibrary` to fill an empty library with locally rendered placeholder images. This lets you work on the UI without spending API credit. You can toggle it under *Edit Scheme → Run → Arguments*. `-SeedPendingJobs` adds an in-progress tile and a failed tile. `-SimulateLibraryOpenFailure` forces the library recovery screen (it succeeds again once you choose Reset Library).
- **Mock API:** `python3 scripts/mock_openai.py 20` serves fake images after a 20-second delay on `127.0.0.1:8765`. Launch a DEBUG build with `-OpenAIBaseURL http://127.0.0.1:8765/v1` to use it. Any key will verify. It handles both `/images/generations` and multipart `/images/edits` requests. Add a second argument, e.g. `20 2`, to fail the first two requests with 503 + `Retry-After` and exercise automatic retries. GIF requests get a real animated GIF; a third argument, e.g. `20 0 403`, answers them with that status instead. SVG requests get a real SVG with an unpainted canvas; a prompt containing "malformed" or "hostile" gets a broken document or one that tries to run a script and fetch from the mock (the mock logs a warning if that ever gets through). It logs each request's format and frame fields, and for edits whether `markup` arrived, its PNG size and alpha channel, and the first image's size. It rejects combinations the real API would (GIF or SVG on `/images/edits`, frame fields without GIF, compression with GIF or SVG, `n` above 1 with SVG, and `markup` that isn't a PNG with an alpha channel, doesn't match the first image's size, goes over the size limits, is sent to a model without markup support, or comes with `mask` or `prompt_rewriter`).
- **Markup files:** an overlay and its strokes are stored in `Application Support/References` as `<id>.markup.png` and `<id>.markup.pkdrawing`, and records hold only the overlay's name. `Studio` counts both when it decides which files are still in use, so they follow the same rules as references: the composer has its own copies until it sends them, a job and its images share them by name, the last owner to go deletes them, and anything left over is swept at launch. Strokes are stored in canvas units (the image's shape, 256 units along its long edge), as PencilKit's monoline ink only takes widths from 0.5 to 4; the canvas is zoomed to cover the image's fitted rectangle, so letterboxing and rotation don't affect them. `MarkupExporter` scales them to the reference file's pixel size and renders at scale 1. `ReferenceStore.normalize` bakes in orientation, so the stored file's pixel size is the one that matters. The size, alpha channel and limits are checked again when a request is sent.
- **SVG rendering:** ImageIO and `UIImage` return nothing for an SVG (checked on the iOS 27.2 simulator), and iOS has no public API that draws a whole document. So `ImageLoader` hands files with the `.svg` extension to `SVGRasterizer`, which shows them in an off-screen `WKWebView` and takes a snapshot, keeping transparency; callers don't need to know. Documents are untrusted, so the file is first checked with `XMLParser` (well-formed UTF-8 declaring no other encoding, `<svg>` root, no entity declarations) and then shown as a base64 `<img>`, in which WebKit runs no scripts and loads no subresources. On top of that, the web view has content JavaScript off, a non-persistent data store, no base URL, a content rule list blocking all loads, a content security policy, and a navigation delegate that allows nothing but the page itself. Each render times out after 20 s and throws that web view away, and a document that times out with the app in the foreground throughout isn't tried again until the app restarts. Web views take seconds to start in the simulator but milliseconds to reuse, so at most two exist, kept until they've been idle for a minute. Nothing is rendered while the app is in the background, as a web view can't be relied on there; views try again when it returns. The renderer's size comes from `viewBox` or `width`/`height` (see `SVGDocument`). A document with neither gets the size the API reports written into its root element when it's saved, the one change ever made to a generated file; failing that, it's drawn on a 1024 × 1024 canvas.
- **Background generation:** requests run on a background `URLSession` (`GenerationSession`), so they continue while the app is suspended or after the system terminates it. Pending and failed jobs are stored as `PendingGeneration` records. Force-quitting the app cancels in-flight requests; those jobs show as failed with Retry.
- **Live Activity and notifications:** `GenerationActivityController` starts the activity when a generation starts (ActivityKit only allows that in the foreground) and updates or ends it from background relaunches too. `GenerationNotifier` posts notifications only when the app isn't active. With the mock API above, start a generation and go to the Home Screen to see both. Preview the activity's layouts in `ImageStudioWidgets/GenerationLiveActivity.swift`.
- **App icon:** `swift scripts/make-icon.swift ImageStudio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- **Signing:** automatic signing with team `359794K46A` (set in `project.yml`).
