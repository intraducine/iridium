# Roadmap

Iridium focuses on adding a local Windows game, choosing it from the library,
and playing it with touch, a controller, or keyboard and mouse. The app also
provides native Steam downloads; transfer success and game compatibility need
separate validation.

## Steam acceptance

- Validate real password/Guard/QR login and saved-session/account switching.
- Test owned game/DLC downloads, branch/language choices, and large libraries.
- Check low/unknown storage and one-attempt Download Anyway behavior, network
  loss, backgrounding, termination, and verified resume.
- Verify repair/update registration and manual game-local save migration while
  retaining older installations. Steam Cloud and desktop Steam services remain
  outside the current implementation.

## Runtime reliability

- Improve launch recovery, error reporting, and shutdown.
- Validate rendering, audio, input, and save persistence for each tested game.
- Expand media playback coverage, including seeking, skipping, and audio sync.
- Measure performance and memory use on supported devices.

## Library and controls

- Improve executable detection and editable artwork matching.
- Keep navigation consistent across touch, controller, and keyboard input.
- Test controller reconnects and orientation changes during play.

## Distribution

- Keep dependency sources, notices, and rebuild instructions matched to binaries.
- Reuse component builds only when their inputs match.
- Complete the checks in the [release policy](../../docs/releasing.md).

Game compatibility varies. Record test results for specific games and devices;
do not infer broad support from a successful build or one playable title.
