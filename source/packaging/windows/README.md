# Windows installer

Build the Flutter release, then run `./packaging/windows/build-installer.ps1`.
Requires Inno Setup 6.7.3, Visual Studio x64 redistributable CRT, root `LICENSE`,
and the prepared dependency notices. Override paths with `-Compiler`,
`-RuntimeDir`, `-NoticesDir`, and `-OutputDir` as needed. `-NoticesDir` must
contain `THIRD_PARTY_NOTICES.md` and `THIRD_PARTY_LICENSES/`.

Output: `artifacts/releases/YYYY-MM-DD/BRIZFI-<version>-windows-x64-setup.exe`
and its SHA-256. Each build stages the full release in a new directory under
`artifacts/windows-installer/`; existing release packages are preserved.

The installer uses the current Windows release, adds app-local Visual C++ CRT
DLLs and licenses, and preserves the installed EXE icon. Installation is per-user
in `%LOCALAPPDATA%/Programs/BRIZFI` by default. The Start menu shortcut is created;
the desktop shortcut is optional. Russian and English setup UI are available.
The fixed AppId supports future updates. Uninstallation removes installed files
and shortcuts; it does not recursively delete user folders or original books.
The installer is unsigned unless separately signed with an authorized certificate.

Sources: [Inno Setup](https://jrsoftware.org/isdl.php),
[per-user setup](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm),
[Microsoft CRT distribution](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files).

This task prepares a local EXE. Uploading, publishing, or code signing is separate.
