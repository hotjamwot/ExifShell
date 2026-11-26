# ExifShell — Decision Log

Records architectural and product decisions made during development,
with the reasoning behind each one. Newest entries at the top.

Format per entry:
## [YYYY-MM-DD] — <short title>
- **Question / context:** one sentence
- **Decision:** what was decided
- **Reasoning:** why, including trade-offs considered
- **Files affected:** paths (if any)
- **Status:** Decided / Revisiting / Superseded

---

## [2026-11-26] — Pixel Motion Photos (.MP.jpg) kept as-is; metadata is the identifier

- **Question / context:** User has Pixel Motion Photo JPEGs (e.g. `PXL_20250816_160839304.MP.jpg`) that contain an embedded ~2.7 MB MP4 motion clip plus `XMP-GCamera:MotionPhoto = 1` flags. Renaming does not affect the embedded metadata. Concern: ExifShell saves (which rewrite JPEG metadata via ExifTool) might strip the motion capability.
- **Decision:** Keep MP files as-is. Do not add Motion Photo detection or stripping to ExifShell. Rely on embedded `XMP-GCamera:MotionPhoto = 1` / `MotionPhotoVideo` tags to re-identify them after any archive rename.
- **Reasoning:** Renaming does not touch embedded metadata, so the MP capability survives any archive rename. Stripping is lossy (destroys the motion clip) and storage cost (~2.7 MB/file) is negligible. ExifShell's save pipeline would need verification before being declared safe for MP files, and no code change was requested. MP files can be re-found later with `exiftool -if "$MotionPhoto eq 1" -filename -r <archive>`.
- **Files affected:** None (no code changes). Verified with `exiftool` on `/tmp` copies only; originals in `inbox/` untouched.
- **Status:** Decided