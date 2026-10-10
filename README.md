# uniform-path

Cross-platform paths with consistent / separators.

`Path::from_windows` accepts native Windows paths. `to_string()` renders the
uniform format used by JSON; `to_windows()` renders backslashes for Windows
filesystem APIs. In particular, do not pass the uniform `//?/` representation
directly to a native file API.

| Native Windows input | Uniform representation | `to_windows()` |
| --- | --- | --- |
| `D:\folder` | `D:/folder` | `D:\folder` |
| `\\?\D:\folder` | `//?/D:/folder` | `\\?\D:\folder` |
| `\\?\UNC\server\share\folder` | `//?/UNC/server/share/folder` | `\\?\UNC\server\share\folder` |

Extended paths keep their namespace and components, including dot segments,
trailing separators, spaces, and periods, without lexical normalization.
`dirname()` stops at the actual drive or UNC share root; `join()` appends the
other path's already-parsed relative portion without normalizing a verbatim
base. `resolve()` interprets leading `..` in a relative input by walking the
base's parents: resolving `../b` against `//?/D:/a` produces `//?/D:/b`, and
parent traversal stops at the drive or share root. Other base components remain
unchanged. Ordinary paths retain their existing normalization behavior.

JSON and native-format round trips also preserve whether an extended root has
a separator. For example, `\\?\Volume{GUID}` remains distinct from
`\\?\Volume{GUID}\`: Windows opens the former as a volume and the latter as its
root directory. Joining a nonempty child adds the required separator.

This library does not validate filesystem names or access the filesystem.
Preserving an extended path does not make otherwise invalid components valid.
See Microsoft's [extended-path rules](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation).
