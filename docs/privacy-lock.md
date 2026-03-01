# Privacy Lock

Glitcho includes a biometric privacy lock for hiding sensitive sections and streamer activity until you authenticate.

## What It Can Hide
- Recordings navigation/content
- Pinned channels section
- Recent channels section
- Protected streamers (from sidebar and recordings)

## Settings
Open `Settings -> Privacy Lock`:
- Enable privacy lock
- Choose which sections to hide
- Optionally require authentication when opening Recordings
- Configure whether opening Settings should trigger authentication
- Configure a hotkey to lock/unlock (press again to relock)

## Protected Streamers
Use the protected streamers editor to:
- Add/remove streamer logins
- Import from current record list
- Optionally auto-add from custom auto-record allowlist actions

When locked, protected streamer entries are hidden from relevant sidebar and recording surfaces.

## Recording Security Notes
- Recordings are stored encrypted at rest (`.glitcho`) with opaque hashed filenames.
- Exports decrypt recordings to normal files in your chosen destination.
- Thumbnails are still available in-library for usability.

## Operational Behavior
- Authentication is silent until interactive authentication is requested.
- Keychain/Touch ID context reuse reduces repeated prompts after successful auth.
