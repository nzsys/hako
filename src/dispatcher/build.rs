fn main() {
    // jailparam_* は FreeBSD base の libjail にある（libc には無い）。
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("freebsd") {
        println!("cargo:rustc-link-lib=jail");
    }
}
