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
  // The root after //?/: a drive, UNC/server/share, or a namespace name.
  Verbatim(String, has_separator~ : Bool)
} derive(Eq)

///|
/// Platform-independent lexical path with `/` separators.
/// Roots are stored separately so POSIX normalization cannot collapse UNC's
/// leading `//` or mistake `C:/` for a relative path. Absolute paths clamp `..`
/// at the root; relative paths retain leading `..`. Windows verbatim paths
/// preserve their components without normalization. An empty relative portion
/// denotes the root, or `.` without a root. Components retain literal backslashes.
/// This type does not access the filesystem or resolve symlinks.
/// It does not validate filesystem names; preserving verbatim components does
/// not make otherwise invalid names valid.
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
/// Roots use `/`, `C:/`, `C:`, `//server/share/`, or Windows `//?/` syntax;
/// drive letters are ASCII. Verbatim paths preserve their components.
/// Three or more leading slashes denote a POSIX root.
/// Use `from_windows` to parse Windows separators explicitly.
pub fn Path::Path(input : String) -> Path {
  guard !input.has_prefix("//?/") else {
    return Path::from_verbatim(input[4:].to_owned())
  }
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
/// Parse the namespace before considering ordinary UNC syntax. In particular,
/// UNC's server and share belong to the root, not to the relative components.
fn Path::from_verbatim(input : String) -> Path {
  let (prefix, relative) = input.split_once("/").unwrap_or((input[:], ""))
  let (root, relative) = if prefix.equal_ignore_ascii_case("UNC") &&
    relative.split_once("/") is Some((server, tail)) {
    let (share, relative) = tail.split_once("/").unwrap_or((tail, ""))
    ("\{prefix}/\{server}/\{share}", relative)
  } else {
    (prefix.to_owned(), relative)
  }
  Path::from_parts(
    Verbatim(root, has_separator=input.has_prefix(root + "/")),
    relative.to_owned(),
  )
}

///|
/// Parse Windows drive, UNC, or relative syntax and convert its separators to
/// `/` before entering the uniform representation. Extended paths beginning
/// with `\\?\` bypass normalization and retain their namespace.
/// Dot segments, trailing separators, spaces, and periods are preserved.
/// For example, `\\?\D:\folder` becomes `//?/D:/folder`, and
/// `\\?\UNC\server\share\folder` becomes `//?/UNC/server/share/folder`.
/// See [Windows naming rules](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file).
pub fn Path::from_windows(input : String) -> Path {
  guard !input.has_prefix("\\\\?\\") else {
    return Path(input.replace_all(old="\\", new="/"))
  }
  let normalized = Show::to_string(@win32.Path(input).normalize())
  Path::Path(normalized.replace_all(old="\\", new="/"))
}

///|
/// Parse a string returned by the host filesystem. Windows input uses
/// `from_windows`; POSIX input preserves literal backslashes and treats
/// drive-like names as ordinary components. Use `Path(input)` for uniform
/// protocol strings, regardless of the host platform.
/// JavaScript uses Node's platform when available, otherwise POSIX syntax.
pub fn Path::from_native(input : String) -> Path {
  guard !host_is_windows() else { return Path::from_windows(input) }
  let root = if input.has_prefix("/") { Posix } else { Relative }
  Path::from_parts(root, input)
}

///|
/// Render according to the stored root, without consulting the host platform.
/// Drive, drive-relative, UNC, and verbatim paths use Windows separators;
/// POSIX and relative paths retain `/` and literal backslashes. This does not
/// make a foreign path accessible on the host. Use `to_string` for uniform
/// protocol strings and `to_windows` to explicitly request Windows syntax.
/// Verbatim components and the root separator are preserved without normalization.
pub fn Path::to_native(self : Path) -> String {
  match self.root {
    Drive(_) | DriveRelative(_) | UNC(..) | Verbatim(_, ..) => self.to_windows()
    Relative | Posix => self.to_string()
  }
}

///|
/// Render a Windows path for native filesystem APIs, including the backslashes
/// required by extended paths. Use `to_string` for the uniform wire format.
/// Do not pass uniform `//?/` paths directly to native Windows file APIs.
/// The root separator is preserved: `\\?\Volume{GUID}` names the volume,
/// while `\\?\Volume{GUID}\` names its root directory.
/// This converts separators; it does not validate Windows filename rules.
/// See [Windows volume naming](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume)
/// and [extended-path rules](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation).
pub fn Path::to_windows(self : Path) -> String {
  self.to_string().replace_all(old="/", new="\\")
}

///|
/// Normalize only the relative portion. A synthetic POSIX root prevents
/// `..` from escaping an absolute root, including a drive or UNC share.
/// Verbatim paths retain their components without normalization.
fn Path::from_parts(root : PathRoot, relative : String) -> Path {
  guard !(root is Verbatim(_, ..)) else {
    return { root, relative: Path(relative), }
  }
  let normalized = match root {
    Relative | DriveRelative(_) => @posix.Path(relative).normalize()
    _ => @posix.Path("/" + relative).normalize()
  }
  let relative = Show::to_string(normalized).trim(chars="/").to_owned()
  guard relative != "." else { return { root, relative: Path(""), } }
  { root, relative: Path(relative), }
}

///|
/// Append the relative portion of another path, preserving this
/// path's root. The other path's root is ignored. Verbatim roots append the
/// parsed components without further normalization.
/// A nonempty child adds a root separator if the verbatim base lacks one.
pub fn Path::join(self : Path, other : Path) -> Path {
  guard self.root is Verbatim(root, ..) else {
    let relative = self.relative.join(other.relative)
    return Path::from_parts(self.root, Show::to_string(relative))
  }
  let left = Show::to_string(self.relative)
  let right = Show::to_string(other.relative)
  guard !right.is_empty() else { return self }
  let relative = if left.is_empty() || left.has_suffix("/") {
    left + right
  } else {
    left + "/" + right
  }
  Path::from_parts(Verbatim(root, has_separator=true), relative)
}

///|
/// Equivalent to `join`: append the right-hand path's relative portion,
/// ignoring its root and preserving the left-hand path's root and namespace.
pub impl Div for Path with fn div(self : Path, other : Path) -> Path {
  self.join(other)
}

///|
pub extend Path with Div::{div}

///|
/// Resolve another path against this explicit base without reading the host
/// environment. Absolute POSIX, drive, UNC, and verbatim paths replace the base;
/// ordinary relative paths are joined to it. The result can remain relative.
/// Leading `..` components in relative inputs walk the base's parents even
/// when the base is verbatim; the base's remaining components are preserved.
/// For example, resolving `../b` against `//?/D:/a` produces `//?/D:/b`.
/// Parent traversal stops at the drive or UNC share root.
/// A drive-relative path is joined to a base on the same drive, comparing drive
/// letters without case sensitivity and preserving the base's root.
/// Raises `ResolveError::DriveBaseRequired` when that drive base is unavailable.
pub fn Path::resolve(self : Path, other : Path) -> Path raise ResolveError {
  match other.root {
    Relative => self.resolve_relative(other)
    Posix | Drive(_) | UNC(..) | Verbatim(_, ..) => other
    DriveRelative(drive) =>
      match self.root {
        Drive(base_drive)
        | DriveRelative(base_drive)
        | Verbatim(base_drive, ..) if base_drive.equal_ignore_ascii_case(drive) =>
          self.resolve_relative(other)
        _ => raise DriveBaseRequired(drive~, base=self)
      }
  }
}

///|
/// Ordinary relative inputs are already normalized, so only leading parent
/// components remain. Consume those without normalizing the verbatim base.
fn Path::resolve_relative(self : Path, other : Path) -> Path {
  guard self.root is Verbatim(_, ..) else { return self / other }
  let relative = Show::to_string(other.relative)
  for base = self, tail = relative[:] {
    guard tail != ".." else { break base.dirname() }
    guard tail.strip_prefix("../") is Some(rest) else {
      break base.join({ ..other, relative: Path(tail.to_owned()), })
    }
    continue base.dirname(), rest
  }
}

///|
/// Return the parent, stopping at POSIX, drive, and UNC share roots.
pub fn Path::dirname(self : Path) -> Path {
  guard !(self.root is Verbatim(_, ..)) else {
    guard !Show::to_string(self.relative).is_empty() else { return self }
    let rooted = @posix.Path("/" + Show::to_string(self.relative))
    let parent = Show::to_string(rooted.dirname())
    return Path::from_parts(self.root, parent[1:].to_owned())
  }
  Path::from_parts(self.root, Show::to_string(self.relative.dirname()))
}

///|
pub fn Path::basename(self : Path) -> String {
  self.relative.basename().to_owned()
}

///|
/// Render the uniform path, retaining `//?/` for Windows verbatim namespaces.
/// Relative paths with a drive-like first component
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
    Verbatim(root, has_separator~) =>
      "//?/\{root}" + (if has_separator { "/" } else { "" }) + relative
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
/// Paths cross the wire in uniform syntax, including verbatim namespaces.
/// JSON round trips preserve whether a verbatim root has a separator.
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
