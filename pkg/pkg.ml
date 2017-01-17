#!/usr/bin/env ocaml
#use "topfind"
#require "topkg"
open Topkg

let () =
  let lint_deps_excluding =
    Some [ "mirage-solo5"; "fmt"; "result" ]
  in
  let opams = [ Pkg.opam_file "opam" ~lint_deps_excluding ] in
  Pkg.describe ~opams "mirage-block-solo5" @@ fun c ->
  Ok [ Pkg.mllib "src/mirage_block_solo5.mllib"; ]
