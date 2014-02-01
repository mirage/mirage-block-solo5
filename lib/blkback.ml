(*
 * Copyright (c) 2010-2011 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2012-14 Citrix Systems Inc
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

module type ACTIVATIONS = sig

(** Event channels handlers. *)

type event
(** identifies the an event notification received from xen *)

val program_start: event
(** represents an event which 'fired' when the program started *)

val after: Eventchn.t -> event -> event Lwt.t
(** [next channel event] blocks until the system receives an event
    newer than [event] on channel [channel]. If an event is received
    while we aren't looking then this will be remembered and the
    next call to [after] will immediately unblock. If the system
    is suspended and then resumed, all event channel bindings are invalidated
    and this function will fail with Generation.Invalid *)
end

open Lwt
open Printf
open Blkproto
open Gnt

type ops = {
  read : int64 -> Cstruct.t list -> unit Lwt.t;
  write : int64 -> Cstruct.t list -> unit Lwt.t;
}

type stats = {
  ring_utilisation: int array; (* one entry per leval, last entry includes all larger levels *)
  segments_per_request: int array; (* one entry per number of segments *)
  mutable total_requests: int;
  mutable total_ok: int;
  mutable total_error: int;
}

type ('a, 'b) t = {
  domid:  int;
  xg:     Gnttab.interface;
  xe:     Eventchn.handle;
  evtchn: Eventchn.t;
  ring:   ('a, 'b) Ring.Rpc.Back.t;
  ops :   ops;
  parse_req : Cstruct.t -> Req.t;
}

let page_size = 4096

module Opt = struct
  let map f = function
    | None -> None
    | Some x -> Some (f x)
  let iter f = function
    | None -> ()
    | Some x -> f x
  let default d = function
    | None -> d
    | Some x -> x
end

let empty = Cstruct.create 0

module Request = struct
  type kind = Read | Write

  type request = {
    kind: kind;
    sector: int64;
    buffers: Cstruct.t list;
    slots: int list;
  }

  (* partition into parallel groups where everything within a group can
     be executed in parallel since all the conflicts are between groups. *)

end

module BlockError = struct
  open Lwt
  let (>>=) x f = x >>= function
  | `Ok x -> f x
  | `Error (`Unknown x) -> fail (Failure x)
  | `Error `Unimplemented -> fail (Failure "unimplemented in block device")
  | `Error `Is_read_only -> fail (Failure "block device is read-only")
  | `Error `Disconnected -> fail (Failure "block device is disconnected")
  | `Error _ -> fail (Failure "unknown block device failure")
end

module Make(A: ACTIVATIONS)(X: Xs_client_lwt.S)(B: V1_LWT.BLOCK with type id := string) = struct
let service_thread t stats =
  let rec loop_forever after =
    (* For all the requests on the ring, build up a list of
       writable and readonly grants. We will map and unmap these
       as a batch. *)
    let writable_grants = ref [] in
    let readonly_grants = ref [] in
    (* The grants for a request will end up in the middle of a
       mapped block, so we need to know at which page offset it
       starts. *)
    let requests = ref [] in (* request record * offset within block of pages *)
    let next_writable_idx = ref 0 in
    let next_readonly_idx = ref 0 in

    let grants_of_segments = List.map (fun seg  -> {
          Gnttab.domid = t.domid;
          ref = Int32.to_int seg.Req.gref;
        }) in

    let is_writable req = match req.Req.op with
      | Some Req.Read -> true (* we need to write into the page *) 
      | Some Req.Write -> false (* we read from the guest and write to the backend *)
      | _ -> failwith "Unhandled request type" in

    let maybe_mapv writable = function
      | [] -> None (* nothing to do *)
      | grants ->
        begin match Gnttab.mapv t.xg grants writable with
          | None -> failwith "Failed to map grants" (* TODO: handle this error cleanly *)
          | x -> x
        end in

    (* Prepare to map all grants on the ring: *)
    let counter = ref 0 in
    Ring.Rpc.Back.ack_requests t.ring
      (fun slot ->
         incr counter;
         let open Req in
         let req = t.parse_req slot in
         let segs = Array.to_list req.segs in
         if is_writable req then begin
           let grants = grants_of_segments segs in
           writable_grants := !writable_grants @ grants;
           requests := (req, !next_writable_idx) :: !requests;
           next_writable_idx := !next_writable_idx + (List.length grants)
         end else begin
           let grants = grants_of_segments segs in
           readonly_grants := !readonly_grants @ grants;
           requests := (req, !next_readonly_idx) :: !requests;
           next_readonly_idx := !next_readonly_idx + (List.length grants)
         end;
      );
    (* -- at this point the ring slots may be overwritten *)
    let requests = List.rev !requests in
    (* Make one big writable mapping *)
    let writable_mapping = maybe_mapv true !writable_grants in
    let readonly_mapping = maybe_mapv false !readonly_grants in

    let writable_buffer = 
      Opt.(default empty (map (fun x -> Cstruct.of_bigarray (Gnttab.Local_mapping.to_buf x)) writable_mapping)) in
    let readonly_buffer =
      Opt.(default empty (map (fun x -> Cstruct.of_bigarray (Gnttab.Local_mapping.to_buf x)) readonly_mapping)) in

    let bucket = if !counter < Array.length stats.ring_utilisation then !counter else Array.length stats.ring_utilisation - 1 in
    stats.ring_utilisation.(bucket) <- stats.ring_utilisation.(bucket) + 1;
    stats.total_requests <- stats.total_requests + (!counter);

    let _ = (* perform everything else in a background thread *)
      let open Block_request in
      let requests = List.fold_left (fun acc (request, page_offset) -> match request.Req.op with
        | None -> printf "Unknown blkif request type\n%!"; failwith "unknown blkif request type";
        | Some op ->
          let buffer = if is_writable request then writable_buffer else readonly_buffer in
          let nr_segs = Array.length request.Req.segs in
          stats.segments_per_request.(nr_segs) <- stats.segments_per_request.(nr_segs) + 1;
          let buffer = Cstruct.sub buffer (page_offset * page_size) (nr_segs * page_size) in
          let (_, bufs) = List.fold_left (fun (idx, bufs) seg ->
            let page = Cstruct.sub buffer (idx * page_size) page_size in
            let frag = Cstruct.sub page (seg.Req.first_sector * 512) ((seg.Req.last_sector - seg.Req.first_sector + 1) * 512) in
            idx + 1, frag :: bufs
          ) (0, []) (Array.to_list request.Req.segs) in
          add acc request.Req.id op request.Req.sector (List.rev bufs)
        ) empty requests in
      let rec work remaining = match pop remaining with
      | [], _ -> return ()
      | now, later ->
        lwt () = Lwt_list.iter_p (fun r ->
          lwt result =
            try_lwt
              lwt () = (if r.op = Req.Read then t.ops.read else t.ops.write) r.sector r.buffers in
              return Res.OK
            with e ->
              return Res.Error in
          let open Res in
          let ok, error = List.fold_left (fun (ok, error) id ->
            let slot = Ring.Rpc.Back.(slot t.ring (next_res_id t.ring)) in
            (* These responses aren't visible until pushed (below) *)
            write_response (id, {op=Some r.Block_request.op; st=Some result}) slot;
            if result = OK then (ok + 1, error) else (ok, error + 1)
          ) (0, 0) r.id in
          stats.total_ok <- stats.total_ok + ok;
          stats.total_error <- stats.total_error + error;
          return ()
        ) now in
        work later in
      lwt () = work requests in

      (* We must unmap before pushing because the frontend will attempt
         to reclaim the pages (without this you get "g.e. still in use!"
         errors from Linux *)
      let () = try
          Opt.iter (Gnttab.unmap_exn t.xg) readonly_mapping 
        with e -> printf "Failed to unmap: %s\n%!" (Printexc.to_string e) in
      let () = try Opt.iter (Gnttab.unmap_exn t.xg) writable_mapping 
        with e -> printf "Failed to unmap: %s\n%!" (Printexc.to_string e) in
      (* Make the responses visible to the frontend *)
      let notify = Ring.Rpc.Back.push_responses_and_check_notify t.ring in
      if notify then Eventchn.notify t.xe t.evtchn;
      return () in

    lwt next = A.after t.evtchn after in
    loop_forever next in
  loop_forever A.program_start

let init xg xe domid ring_info ops =
  let evtchn = Eventchn.bind_interdomain xe domid ring_info.RingInfo.event_channel in
  let parse_req, idx_size = match ring_info.RingInfo.protocol with
    | Protocol.X86_64 -> Req.Proto_64.read_request, Req.Proto_64.total_size
    | Protocol.X86_32 -> Req.Proto_32.read_request, Req.Proto_32.total_size
    | Protocol.Native -> Req.Proto_64.read_request, Req.Proto_64.total_size
  in
  let grants = List.map (fun r ->
      { Gnttab.domid = domid; ref = Int32.to_int r })
      [ ring_info.RingInfo.ref ] in
  match Gnttab.mapv xg grants true with
  | None ->
    failwith "Gnttab.mapv failed"
  | Some mapping ->
    let buf = Gnttab.Local_mapping.to_buf mapping in
    let ring = Ring.Rpc.of_buf ~buf:(Io_page.to_cstruct buf) ~idx_size ~name:"blkback" in
    let ring = Ring.Rpc.Back.init ring in
    let ring_utilisation = Array.create (Ring.Rpc.Back.nr_ents ring + 1) 0 in
    let segments_per_request = Array.create (Blkproto.max_segments_per_request + 1) 0 in
    let total_requests = 0 and total_ok = 0 and total_error = 0 in
    let stats = { ring_utilisation; segments_per_request; total_requests; total_ok; total_error } in
    let t = { domid; xg; xe; evtchn; ops; parse_req; ring } in
    let th = service_thread t stats in
    on_cancel th (fun () -> let () = Gnttab.unmap_exn xg mapping in ());
    th, stats

open X

let get_my_domid client =
  immediate client (fun xs ->
    try_lwt
      lwt domid = read xs "domid" in
      return (int_of_string domid)
    with Xs_protocol.Enoent _ -> return 0)

let mk_backend_path client name (domid,devid) =
  lwt self = get_my_domid client in
  return (Printf.sprintf "/local/domain/%d/backend/%s/%d/%d" self name domid devid)

let mk_frontend_path client (domid,devid) =
  return (Printf.sprintf "/local/domain/%d/device/vbd/%d" domid devid)

let writev client pairs =
  transaction client (fun xs ->
    Lwt_list.iter_s (fun (k, v) -> write xs k v) pairs
  )

let readv client path keys =
  lwt options = immediate client (fun xs ->
    Lwt_list.map_s (fun k ->
      try_lwt
        lwt v = read xs (path ^ "/" ^ k) in
        return (Some (k, v))
      with _ -> return None) keys
  ) in
  return (List.fold_left (fun acc x -> match x with None -> acc | Some y -> y :: acc) [] options)

let read_one client k = immediate client (fun xs ->
  try_lwt
    lwt v = read xs k in
    return (`OK v)
  with _ -> return (`Error ("failed to read: " ^ k)))

let write_one client k v = immediate client (fun xs -> write xs k v)

let exists client k = match_lwt read_one client k with `Error _ -> return false | _ -> return true

(* Request a hot-unplug *)
let request_close name (domid, devid) =
  lwt client = make () in
  lwt backend_path = mk_backend_path client name (domid,devid) in
  writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Blkproto.State.to_assoc_list Blkproto.State.Closing))

let force_close (domid, device) =
  lwt client = make () in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  write_one client (frontend_path ^ "/state") (Blkproto.State.to_string Blkproto.State.Closed) 

let run (id: string) name (domid,devid) =
  lwt client = make () in
  let xg = Gnttab.interface_open () in
  let xe = Eventchn.init () in

  let open BlockError in
  B.connect id >>= fun t ->

  lwt backend_path = mk_backend_path client name (domid,devid) in

  (* Tell xapi we've noticed the backend *)
  lwt () = write_one client
    (backend_path ^ "/" ^ Blkproto.Hotplug._hotplug_status)
    Blkproto.Hotplug._online in

  try_lwt 

    lwt info = B.get_info t in
   
    (* Write the disk information for the frontend *)
    let di = Blkproto.DiskInfo.(to_assoc_list {
      sector_size = info.B.sector_size;
      sectors = info.B.size_sectors;
      media = Media.Disk;
      mode = Mode.ReadWrite }) in
    (* Advertise indirect descriptors with the same default as Linux blkback *)
    let features = Blkproto.FeatureIndirect.(to_assoc_list { max_indirect_segments = 256 }) in
    lwt () = writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (di @ features)) in
    lwt frontend_path = match_lwt read_one client (backend_path ^ "/frontend") with
      | `Error x -> failwith x
      | `OK x -> return x in
   
    (* wait for the frontend to enter state Initialised *)
    lwt () = wait client (fun xs ->
      try_lwt
        lwt state = read xs (frontend_path ^ "/" ^ Blkproto.State._state) in
        if Blkproto.State.of_string state = Some Blkproto.State.Initialised
        || Blkproto.State.of_string state = Some Blkproto.State.Connected
        then return ()
        else raise Xs_protocol.Eagain
      with Xs_protocol.Enoent _ -> raise Xs_protocol.Eagain
    ) in

    lwt frontend = readv client frontend_path Blkproto.RingInfo.keys in
    let ring_info = match Blkproto.RingInfo.of_assoc_list frontend with
      | `OK x -> x
      | `Error x -> failwith x in
    printf "%s\n%!" (Blkproto.RingInfo.to_string ring_info);
    let device_read ofs bufs =
      try_lwt
        B.read t ofs bufs >>= fun () ->
        return ()
      with e ->
        printf "blkback: read exception: %s, offset=%Ld\n%!" (Printexc.to_string e) ofs;
        Lwt.fail e in
    let device_write ofs bufs =
      try_lwt
        B.write t ofs bufs >>= fun () ->
        return ()
      with e ->
        printf "blkback: write exception: %s, offset=%Ld\n%!" (Printexc.to_string e) ofs;
        Lwt.fail e in
    let be_thread, stats = init xg xe domid ring_info {
      read = device_read;
      write = device_write;
    } in
    lwt () = writev client (List.map (fun (k, v) -> backend_path ^ "/" ^ k, v) (Blkproto.State.to_assoc_list Blkproto.State.Connected)) in
    (* wait for the frontend to disappear or enter a Closed state *)
    lwt () = wait client (fun xs -> 
      try_lwt
        lwt state = read xs (frontend_path ^ "/state") in
        if Blkproto.State.of_string state <> (Some Blkproto.State.Closed)
        then raise Xs_protocol.Eagain
        else return ()
      with Xs_protocol.Enoent _ ->
        return ()
    ) in
    Lwt.cancel be_thread;
    Lwt.return stats
  with e ->
    printf "blkback caught %s\n%!" (Printexc.to_string e);
    lwt () = B.disconnect t in
    fail e

let create ?backend_domid name (domid, device) =
  lwt client = make () in
  (* Construct the device: *)
  lwt backend_path = mk_backend_path client name (domid, device) in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  lwt backend_domid = match backend_domid with
  | None -> get_my_domid client
  | Some x -> return x in
  let c = Blkproto.Connection.({
    virtual_device = string_of_int device;
    backend_path;
    backend_domid;
    frontend_path;
    frontend_domid = domid;
    mode = Blkproto.Mode.ReadWrite;
    media = Blkproto.Media.Disk;
    removable = false;
  }) in
  transaction client (fun xs ->
    Lwt_list.iter_s (fun (owner_domid, (k, v)) ->
      lwt () = write xs k v in
      let acl =
        let open Xs_protocol.ACL in
        { owner = owner_domid; other = READ; acl = [ ] } in
      lwt () = setperms xs k acl in
      return ()
    ) (Blkproto.Connection.to_assoc_list c)
  )

let destroy name (domid, device) =
  lwt client = make () in
  lwt backend_path = mk_backend_path client name (domid, device) in
  lwt frontend_path = mk_frontend_path client (domid, device) in
  immediate client (fun xs ->
    lwt () = try_lwt rm xs backend_path with _ -> return () in
    lwt () = try_lwt rm xs frontend_path with _ -> return () in
    return ()
  )
end
