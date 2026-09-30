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
/// denotes the root, or `.` without a root. Components retain literal backslashes.
/// This type does not access the filesystem or resolve symlinks.
/// See [Linux filename rules](https://man7.org/linux/man-pages/man7/pathname.7.html)
/// and [path resolution](https://man7.org/linux/man-pages/man7/path_resolution.7.html).
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
fn has_drive_prefix(input : String) -> Bool {
  input is [drive, ':', ..] &&
  ((drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z'))
}

///|
/// Parse uniform syntax with `/` separators, preserving literal backslashes.
/// Roots use `/`, `C:/`, `C:`, or `//server/share/`; drive letters are ASCII.
/// Three or more leading slashes denote a POSIX root.
/// Use `from_windows` to parse Windows separators explicitly.
pub fn Path::Path(input : String) -> Path {
  guard !has_drive_prefix(input) else {
    let drive = input[:2].to_owned()
    let relative = input[2:].to_owned()
    let root = {
      guard relative.has_prefix("/") else { DriveRelative(drive) }
      Drive(drive)
    }
    Path::from_parts(root, relative)
  }
  let has_unc_prefix = input.has_prefix("//") && !input.has_prefix("///")
  guard !has_unc_prefix else {
    let parts = input.split("/").filter(part => !part.is_empty()).to_array()
    guard parts is [server, share, .. relative] else {
      return Path::from_parts(Posix, input)
    }
    Path::from_parts(
      UNC(server=server.to_owned(), share=share.to_owned()),
      relative.join("/"),
    )
  }
  Path::from_parts(if input.has_prefix("/") { Posix } else { Relative }, input)
}

///|
/// Parse Windows drive, UNC, or relative syntax and convert its separators to
/// `/` before entering the uniform representation.
/// See [Windows naming rules](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file).
pub fn Path::from_windows(input : String) -> Path {
  let normalized = Show::to_string(@win32.Path(input).normalize())
  Path::Path(normalized.replace_all(old="\\", new="/"))
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
/// path's root. The other path's root is ignored. Both operands are already
/// parsed and normalized.
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
/// Render the normalized path. Relative paths with a drive-like first component
/// retain `./` to distinguish component names from drive roots.
/// A POSIX component can contain `:`, and `.` denotes the current directory:
/// [filename rules](https://man7.org/linux/man-pages/man7/pathname.7.html),
/// [path resolution](https://man7.org/linux/man-pages/man7/path_resolution.7.html).
pub impl Show for Path with fn to_string(self) {
  let relative = Show::to_string(self.relative)
  match self.root {
    Relative => {
      guard !relative.is_empty() else { "." }
      guard !has_drive_prefix(relative) else { "./" + relative }
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

///|
/// Paths cross the wire as normalized strings, never as platform internals.
pub impl ToJson for Path with fn to_json(self) {
  self.to_string().to_json()
}

///|
pub impl FromJson for Path with fn from_json(json, path) {
  Path(FromJson::from_json(json, path))
}

///|
pub extend Path with ToJson::{to_json}

///|
pub extend Path with FromJson::{from_json}
