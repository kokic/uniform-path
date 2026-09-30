///|
/// `Drive("C:")` denotes `C:/`; `DriveRelative("C:")` preserves the distinct
/// meaning of `C:work`, whose resolution needs the host's current drive directory.
/// A UNC root includes both the server and share: `//server/share/`.
priv enum PathRoot {
  Relative
  Posix
  Drive(String)
  DriveRelative(String)
  UNC(server~ : String, share~ : String)
} derive(Eq)

///|
/// Platform-independent lexical path with `/` separators.
/// Roots are stored separately so POSIX normalization cannot collapse UNC's
/// leading `//` or mistake `C:/` for a relative path. Absolute paths clamp `..`
/// at the root; relative paths retain leading `..`. An empty relative portion
/// denotes the root, or `.` without a root. POSIX filenames retain backslashes.
/// This type does not access the filesystem or resolve symlinks.
pub struct Path {
  priv root : PathRoot
  priv relative : @posix.Path
} derive(Eq)

///|
pub extend Path with Eq::{equal, not_equal}

///|
/// Parse POSIX paths or Windows drive/UNC paths. Windows input is normalized
/// at this boundary; all subsequent operations and output use `/` separators.
/// Absolute POSIX paths preserve backslashes occurring in file names.
pub fn Path::Path(input : String) -> Path {
  let has_drive = input is [drive, ':', ..] &&
    ((drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z'))
  let windows_input = has_drive ||
    input.has_prefix("//") ||
    (!input.has_prefix("/") && input.contains("\\"))
  guard windows_input else {
    let root = {
      guard input.has_prefix("/") else { Relative }
      Posix
    }
    Path::from_parts(root, input)
  }

  let windows = @win32.Path(input).normalize()
  let windows_root = windows.root()
  let root_text = windows_root.to_owned().replace_all(old="\\", new="/")
  let root : PathRoot = {
    guard !has_drive else {
      let drive = root_text[:2].to_owned()
      guard windows.is_absolute() else { DriveRelative(drive) }
      Drive(drive)
    }
    guard !root_text.has_prefix("//") else {
      let parts = root_text
        .split("/")
        .filter(part => !part.is_empty())
        .to_array()
      guard parts is [server, share] else {
        return Path::from_parts(
          Posix,
          Show::to_string(windows).replace_all(old="\\", new="/"),
        )
      }
      UNC(server=server.to_owned(), share=share.to_owned())
    }
    guard windows.is_absolute() else { Relative }
    Posix
  }
  let text = Show::to_string(windows)
  let relative = text[windows_root.length():]
    .to_owned()
    .replace_all(old="\\", new="/")
  Path::from_parts(root, relative)
}

///|
/// Normalize only the relative portion. A synthetic POSIX root prevents
/// `..` from escaping an absolute root, including a drive or UNC share.
fn Path::from_parts(root : PathRoot, relative : String) -> Path {
  let normalized = match root {
    Relative | DriveRelative(_) => @posix.Path(relative).normalize()
    _ => @posix.Path("/" + relative).normalize()
  }
  let relative = Show::to_string(normalized).trim(chars="/").to_owned()
  guard relative != "." else { return { root, relative: Path(""), } }
  { root, relative: Path(relative), }
}

///|
/// Append a path fragment without replacing the root. Backslashes in Windows
/// fragments are converted at entry; POSIX file names retain literal backslashes.
pub fn Path::join(self : Path, fragment : String) -> Path {
  let fragment = match self.root {
    Drive(_) | DriveRelative(_) | UNC(..) =>
      fragment.replace_all(old="\\", new="/")
    _ => fragment
  }
  let relative = self.relative.join(Path(fragment))
  Path::from_parts(self.root, Show::to_string(relative))
}

///|
/// Return the parent, stopping at POSIX, drive, and UNC share roots.
pub fn Path::dirname(self : Path) -> Path {
  Path::from_parts(self.root, Show::to_string(self.relative.dirname()))
}

///|
pub fn Path::basename(self : Path) -> String {
  self.relative.basename().to_owned()
}

///|
pub impl Show for Path with fn to_string(self) {
  let relative = Show::to_string(self.relative)
  match self.root {
    Relative => {
      guard !relative.is_empty() else { "." }
      relative
    }
    Posix => "/" + relative
    Drive(drive) => drive + "/" + relative
    DriveRelative(drive) => drive + relative
    UNC(server~, share~) => "//\{server}/\{share}/" + relative
  }
}

///|
pub impl Show for Path with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
pub extend Path with Show::{to_string}

///|
pub extend Path with Show::{output}
