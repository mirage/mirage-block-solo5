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

open Mirage_block
open OS.Solo5

type 'a io = 'a Lwt.t

type t = {
  name: string;
  info: Mirage_block.info;
}

type page_aligned_buffer = Cstruct.t

type error = [
  | Mirage_block.error
  | `Invalid_argument
  | `Unspecified_error
]

let pp_error ppf = function
  | #Mirage_block.error as e -> Mirage_block.pp_error ppf e
  | `Invalid_argument      -> Fmt.string ppf "Invalid argument"
  | `Unspecified_error     -> Fmt.string ppf "Unspecified error"

type write_error = [
  | Mirage_block.write_error
  | `Invalid_argument
  | `Unspecified_error
]

let pp_write_error ppf = function
  | #Mirage_block.write_error as e -> Mirage_block.pp_write_error ppf e
  | `Invalid_argument      -> Fmt.string ppf "Invalid argument"
  | `Unspecified_error     -> Fmt.string ppf "Unspecified error"

type solo5_block_info = {
  capacity: int64;
  block_size: int64;
}

external solo5_block_info:
  unit -> solo5_block_info = "mirage_solo5_block_info"
external solo5_block_read:
  int64 -> Cstruct.buffer -> int -> solo5_result = "mirage_solo5_block_read"
external solo5_block_write:
  int64 -> Cstruct.buffer -> int -> solo5_result = "mirage_solo5_block_write"

let disconnect _id =
  (* not implemented *)
  Lwt.return_unit

let connect name =
  let bi = solo5_block_info () in
  let sector_size = Int64.to_int bi.block_size in
  let size_sectors = (Int64.div bi.capacity bi.block_size) in
  let read_write = true in
  Lwt.return ({ name; info = { sector_size; size_sectors; read_write } })

(* XXX: also applies to read: unclear if mirage actually issues I/O requests
 * that are >1 sector in size *per buffer*. mirage-skeleton device-usage/block
 * does not exhibit this behaviour. in any case, this will be caught at the
 * Solo5 layer and return an error back if it happens.
 *)

let do_write1 offset b =
  let r = match solo5_block_write offset b.Cstruct.buffer b.Cstruct.len with
    | SOLO5_R_OK      -> Ok ()
    | SOLO5_R_AGAIN   -> assert false
    | SOLO5_R_EINVAL  -> Error `Invalid_argument
    | SOLO5_R_EUNSPEC -> Error `Unspecified_error
  in
  Lwt.return r

let rec do_write offset buffers = match buffers with
  | [] -> Lwt.return (Ok ())
  | b :: bs ->
     let new_offset = Int64.(add offset (of_int (Cstruct.len b))) in
     Lwt.bind (do_write1 offset b)
              (fun (result) -> match result with
                               | Error e -> Lwt.return (Error e)
                               | Ok () -> do_write new_offset bs)

let write x sector_start buffers =
  let offset = Int64.(mul sector_start (of_int x.info.sector_size)) in
  do_write offset buffers

let do_read1 offset b =
  let r = match solo5_block_read offset b.Cstruct.buffer b.Cstruct.len with
    | SOLO5_R_OK      -> Ok ()
    | SOLO5_R_AGAIN   -> assert false
    | SOLO5_R_EINVAL  -> Error `Invalid_argument
    | SOLO5_R_EUNSPEC -> Error `Unspecified_error
  in
  Lwt.return r

let rec do_read offset buffers = match buffers with
  | [] -> Lwt.return (Ok ())
  | b :: bs ->
     let new_offset = Int64.(add offset (of_int (Cstruct.len b))) in
     Lwt.bind (do_read1 offset b)
              (fun (result) -> match result with
                               | Error e -> Lwt.return (Error e)
                               | Ok () -> do_read new_offset bs)

let read x sector_start buffers =
  let offset = Int64.(mul sector_start (of_int x.info.sector_size)) in
  do_read offset buffers

let get_info t = Lwt.return t.info
