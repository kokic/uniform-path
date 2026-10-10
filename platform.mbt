///|
#cfg(all(target="native", platform="windows"))
fn host_is_windows() -> Bool {
  true
}

///|
#cfg(all(target="native", not(platform="windows")))
fn host_is_windows() -> Bool {
  false
}

///|
#cfg(target="js")
extern "js" fn host_is_windows() -> Bool =
  #|() => typeof process !== "undefined" && process.platform === "win32"

///|
#cfg(any(target="wasm", target="wasm-gc"))
fn host_is_windows() -> Bool = "__moonbit_sys_unstable" "is_windows"
