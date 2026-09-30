///|
/// `Drive("C:")` denotes `C:/`; `DriveRelative("C:")` preserves the distinct
/// meaning of `C:work`, whose resolution needs an explicit base on that drive.
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
/// A drive-relative path cannot be resolved without a base on the same drive.
pub(all) suberror ResolveError {
  DriveBaseRequired(drive~ : String, base~ : Path)
}

///|
pub impl Show for ResolveError with fn output(self, logger) {
  match self {
    DriveBaseRequired(drive~, base~) =>
      logger.write_string(
        "resolving a drive-relative path on \{drive} requires a base on that drive, got \{base}",
      )
  }
}

///|
pub extend ResolveError with Show::{to_string, output}

///|
/// Parse POSIX paths or Windows drive/UNC paths. Windows input is normalized
/// at this boundary; all subsequent operations and output use `/` separators.
/// Exactly two leading forward slashes select Windows UNC parsing; three or
/// more select POSIX parsing.
/// Absolute POSIX paths preserve backslashes occurring in file names.
pub fn Path::Path(input : String) -> Path {
  let has_drive = input is [drive, ':', ..] &&
    ((drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z'))
  let has_unc_prefix = input.has_prefix("//") && !input.has_prefix("///")
  let windows_input = has_drive ||
    has_unc_prefix ||
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
/// Append the relative portion of another normalized path, preserving this
/// path's root. The other path's root is ignored. Input syntax and separators
/// are handled by `Path::Path` before joining.
pub fn Path::join(self : Path, other : Path) -> Path {
  let relative = self.relative.join(other.relative)
  Path::from_parts(self.root, Show::to_string(relative))
}

///|
/// Equivalent to `join`: append the right-hand path's relative portion,
/// ignoring its root and preserving the left-hand path's root.
pub impl Div for Path with fn div(self : Path, other : Path) -> Path {
  self.join(other)
}

///|
pub extend Path with Div::{div}

///|
/// Resolve another normalized path against this explicit base without reading
/// the host environment. Absolute POSIX, drive, and UNC paths replace the base;
/// ordinary relative paths are joined to it. The result can remain relative.
/// A drive-relative path is joined to a base on the same drive, comparing drive
/// letters without case sensitivity and preserving the base's root.
/// Raises `ResolveError::DriveBaseRequired` when that drive base is unavailable.
pub fn Path::resolve(self : Path, other : Path) -> Path raise ResolveError {
  match other.root {
    Relative => self / other
    Posix | Drive(_) | UNC(..) => other
    DriveRelative(drive) =>
      match self.root {
        Drive(base_drive) | DriveRelative(base_drive) if base_drive.equal_ignore_ascii_case(
            drive,
          ) => self / other
        _ => raise DriveBaseRequired(drive~, base=self)
      }
  }
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
