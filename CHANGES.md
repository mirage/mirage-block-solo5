## v0.8.1 (2022-11-29)

* Check that buffers are aligned before conducting I/O (#29 @reynir)
* Allow read/write with buffers being multiple of sector_size (#28 @reynir)

## v0.8.0 (2022-03-27)

* Rename the freestanding toolchain to solo5 (@dinosaure, #24)
* Use ocamlformat (@samoht, #26)

## v0.7.0 (2022-02-01)

* Adapt to the new `mirage-block.2.0.0` API (@hannesm, #20)
* Be able to install & build `mirage-block-solo5` without the expected `dune`'s context
  (@TheLortex, @dinosaure, #21)
* Use `Solo5_os` instead of `OS` (@dinosaure, #22)

## v0.6.1 (2019-11-01)

* Adapt to mirage-block 2.0.0 changes (@hannesm, #19)
* Raise lower bound to OCaml 4.06.0 (@hannesm, #19)

## v0.6.0 (2019-09-25)

* Synchronise version number with other Mirage/Solo5 component packages.
* Update to Solo5 0.6.0+ APIs, multiple devices support (@mato, #18)
* Port to dune (@pascutto, #16)

## v0.4.0 (2018-11-08)

* Correctly use Cstruct buffer offset (@mato, #15)
* Migrate to OPAM 2 (@mato, #14)

## v0.3.0 (2018-06-17)

* Adapt to Solo5 v0.3.0 APIs, refactor and cleanup (@mato, #12, @hannesm, #10)

## v0.2.1 (2017-01-17)

* Declare dependency on result and fmt in opam (@hannesm, #8)

## v0.2.0 (2017-01-17)

* Port to topkg (@yomimono, #5)
* Update types and interface for MirageOS 3 (@hannesm, @yomimono, @samoht)

## v0.1.1 (2016-07-14)

* Initial release, based on mirage-block-{xen,unix} code.
