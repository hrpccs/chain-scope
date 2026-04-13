use std::fs::create_dir_all;
use std::path::{Path};

use libbpf_cargo::SkeletonBuilder;

const SRC: &str = "./src/bpf/hooks.bpf.c";

fn main() {
    create_dir_all("./src/bpf/.output").unwrap();
    let skel = Path::new("./src/bpf/.output/hooks.skel.rs");
    SkeletonBuilder::new()
        .source(SRC)
        .build_and_generate(&skel)
        .expect("bpf compilation failed");
    println!("cargo:rerun-if-changed={}", SRC);
}
