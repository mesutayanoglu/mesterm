What each release changed, for users: `vX.Y.Z.md`, one `- ` line per change.
The release workflow puts it under "What's changed" in the release notes,
which the app's update dialog shows. Without a file, the commit subjects are
used.

Versions are numbered automatically on each push to `main`, so a file is
optional: write `vX.Y.Z.md` for the version that push will get (the latest
tag plus one) when the commit subjects are not clear enough for users.
