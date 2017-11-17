(*
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf
open Mirage_block

type 'a io = 'a Lwt.t

type page_aligned_buffer = Cstruct.t

type error = [ Mirage_block.error | `Read ]

let pp_error ppf = function
  | #Mirage_block.error as e -> Mirage_block.pp_error ppf e
  | `Read -> Fmt.string ppf "solo5 blk write"


type write_error = [ Mirage_block.write_error | `Write ]

let pp_write_error ppf = function
  | #Mirage_block.write_error as e -> Mirage_block.pp_write_error ppf e
  | `Write -> Fmt.string ppf "solo5 blk read"

type t = {
    name: string;
    info: Mirage_block.info;
  }

external solo5_blk_sector_size: unit -> int = "stub_blk_sector_size"
external solo5_blk_sectors: unit -> int64 = "stub_blk_sectors"
external solo5_blk_rw: unit -> bool = "stub_blk_rw"

external solo5_blk_write: int64 -> Cstruct.buffer -> int -> bool = "stub_blk_write"
external solo5_blk_read: int64 -> Cstruct.buffer -> int -> bool = "stub_blk_read"

let disconnect _id =
  printf "Blkfront: disconnect not implement yet\n";
  return_unit

let connect name =
  let sector_size = solo5_blk_sector_size () in
  let size_sectors = solo5_blk_sectors () in
  let read_write = solo5_blk_rw () in
  return ({ name; info = { sector_size; size_sectors; read_write } })


let do_write sector b =
  return (solo5_blk_write sector b.Cstruct.buffer b.Cstruct.len)

let rec write x sector_start buffers = match buffers with
    | [] -> return (Ok ())
    | b :: bs ->
       let new_start = Int64.(add sector_start (div (of_int (Cstruct.len b))
                                                    (of_int x.info.sector_size))) in
       Lwt.bind (do_write sector_start b)
                (fun (result) -> match result with
                                 | false -> return (Error `Write)
                                 | true -> write x new_start bs)

let do_read sector b =
  return (solo5_blk_read sector b.Cstruct.buffer b.Cstruct.len)

let rec read x sector_start pages = match pages with
    | [] -> return (Ok())
    | b :: bs ->
       let new_start = Int64.(add sector_start (div (of_int (Cstruct.len b))
                                                    (of_int x.info.sector_size))) in
       Lwt.bind (do_read sector_start b)
                (fun (result) -> match result with
                                 | false -> return (Error `Read)
                                 | true -> read x new_start bs)


let get_info t =
  return t.info
