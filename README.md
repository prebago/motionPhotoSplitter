# mpsplit

Splits Google Motion Photos (`<name>.MP.jpg`, as produced by Pixel phones) into
`<name>.jpg` and `<name>.mp4`. See the
[Motion Photo format spec](https://developer.android.com/media/platform/motion-photo-format).

```bash
./mpsplit ~/Pictures/Pixel          # recursive, finds *.MP.jpg (any case)
./mpsplit some/file.MP.jpg          # single file
./mpsplit -o out ~/Pictures/Pixel   # write results to ./out instead of next to the source
```

With `-o`, all results go flat into that directory (subfolders are not recreated).
If two sources would produce the same output name (e.g. `a/x.MP.jpg` and
`b/x.MP.jpg`), the first is split and the second is reported as an error.

`-h`/`--help` shows the usage, `--version` the version.

Written in Perl using the ExifTool library (`Image::ExifTool`), so each file
is handled in a single process. Requires Perl 5.10+ and
`apt install libimage-exiftool-perl`, which is the package that also provides the
`exiftool` command.

Exit codes: `0` = all OK, `1` = at least one file failed, `2` = usage error.
Damaged files (truncated, unreadable, or not a JPEG despite the name) count as
errors.

The summary line counts files that were split, split with a warning (e.g. the
video metadata could not be written), skipped because the targets exist, not
motion photos, and errors.

## Tests

```bash
prove t/
```

Unit tests always run. End-to-end tests run the script on the motion photos in
`Samples/` (or `$MPSPLIT_SAMPLES`) and check that:

- the photo is a valid JPEG with no motion tags and no C2PA manifest left;
- the container directory keeps its other items unchanged;
- the gain map is byte-identical to the original's;
- the video's audio/video data is identical to the embedded video;
- the metadata was copied into the video;
- timestamps were copied, and a rerun skips everything.

Further cases use test files generated from the first sample:

- a single-file argument;
- damaged files;
- an output name collision;
- the legacy V1 (`MicroVideo`) format;
- a video without dates, which gets the photo's capture time.

## What it does

- **Photo** (`<name>.jpg`): everything before the embedded video, with all
  EXIF/GPS/ICC/XMP metadata kept. The motion-photo XMP tags
  (`GCamera:MotionPhoto*`, `MicroVideo*`) and the video entry in the
  `Container:Directory` are removed, as are the C2PA content credentials (see
  below). Other container items, such as an Ultra HDR gain map, are kept
  exactly as they were.
- **Video** (`<name>.mp4`): the exact embedded MP4 bytes, plus metadata copied
  from the photo: GPS incl. altitude (`Keys` + `UserData`), `Make`/`Model`, and
  `Keys:CreationDate` with timezone. QuickTime UTC dates are only filled in if
  the video lacks them (Pixel videos already have them).
- Both outputs get the source file's modification time and permissions.
- Supports the V2 (`Container:Directory`) and legacy V1 (`MicroVideoOffset`)
  formats. The video location is checked for an `ftyp` box before anything is
  written.
- Originals are never modified. If a target already exists, the file is
  skipped, so re-running the script is safe.
- Outputs are written as temp files and renamed into place, all or nothing:
  an interrupted or failed run never leaves a partial pair of outputs.

## C2PA content credentials

Recent Pixel photos carry a signed [C2PA](https://c2pa.org) manifest (JUMBF in
APP11, "Created by Pixel Camera"). Google signs the parts of the file
separately:

- the main photo, which includes the EXIF, XMP and MPF blocks;
- the Ultra HDR gain map (optional part);
- the video (optional part).

Only a few EXIF GPS/date fields are excluded from the main photo's hash.

Removing the motion-photo XMP changes signed bytes of the main photo, so the
signature can no longer verify. A broken signature would show up as "tampered"
in C2PA verifiers, which is worse than none. So **`mpsplit` removes the
C2PA manifest from the split photo**. The original `<name>.MP.jpg`, which the
script never modifies, keeps the valid credentials, so keep the originals if
you need provenance.
