module StringMap = Map.Make(String)

let string_eq ~a ~a_start ~b ~len =
  let r = ref true in
  for i = 0 to len - 1 do
    let a_i = a_start + i in
    let b_i = i in
    if a.[a_i] <> b.[b_i] then
      r := false
  done;
  !r

let ends_with ~suffix ~suffix_length s =
  let s_length = String.length s in
  (s_length >= suffix_length) &&
  (string_eq ~a:s ~a_start:(s_length - suffix_length) ~b:suffix ~len:suffix_length)

let rec first_matching p = function
  | [] -> None
  | x::xs ->
    begin
      match p x with
      | Some y -> Some y
      | None -> first_matching p xs
    end

let option_map f = function
  | None -> None
  | Some x -> Some (f x)

let find_common_idx a b =
  let rec go i =
    if i <= 0 then
      None
    else
      begin
        if ends_with ~suffix:b ~suffix_length:i a then
          Some (String.length a - i)
        else
          go (i - 1)
      end
  in
  go (String.length b)

let word = function
  | "" -> []
  | w -> [Some w]

let split_on_string ~pattern s =
  let pattern_length = String.length pattern in
  let rec go start acc =
    match Stringext.find_from ~start s ~pattern with
    | Some match_start ->
      let before = String.sub s start (match_start - start) in
      let new_acc = None::(word before)@acc in
      let new_start = match_start + pattern_length in
      go new_start new_acc
    | None ->
      (word (Stringext.string_after s start))@acc
  in
  List.rev (go 0 [])

let split_and_process_string ~boundary s =
  let f = function
    | None -> `Delim
    | Some w -> `Word w
  in
  List.map f @@ split_on_string ~pattern:boundary s

let bounded_split_on_string ~pattern until s =
  let pattern_length = String.length pattern in
    let until_idx = match (Stringext.find_from ~start:0 s ~pattern:until) with
      | None -> String.length s
      | Some index -> index
    in
    let rec go start acc =
      match (Stringext.find_from ~start s ~pattern)
      with
      | Some match_start ->
        let before = String.sub s start (match_start - start) in
        let new_acc = None::(word before)@acc in
        let new_start = match_start + pattern_length in
        begin
          match (until_idx + (String.length until) = new_start) with
          | true -> let string_after = (Stringext.string_after s new_start) in
            (word string_after)@new_acc
          | false -> go new_start new_acc
        end
      | None ->
        let string_after = (Stringext.string_after s start) in
        (word string_after)@acc
    in
    List.rev (go 0 [])

let bounded_split_and_process_string ~boundary until s =
  let f = function
    | None -> `Delim
    | Some w -> `Word w
  in
  List.map f @@ bounded_split_on_string ~pattern:boundary until s

let split s boundary =
  let r = ref None in
  let push v =
    match !r with
    | None -> r := Some v
    | Some _ -> assert false
  in
  let pop () =
    let res = !r in
    r := None;
    res
  in
  let go c0 =
    let c =
      match pop () with
      | Some x -> x ^ c0
      | None -> c0
    in
    let string_to_process = match find_common_idx c "\r\n\r\n" with
    | None -> c
    | Some idx ->
      begin
        let prefix = String.sub c 0 idx in
        let suffix = String.sub c idx (String.length c - idx) in
        push suffix;
        prefix
      end
    in
    Lwt.return @@ split_and_process_string ~boundary string_to_process
  in
  let initial = Lwt_stream.map_list_s go s in
  let final =
    Lwt_stream.flatten @@
    Lwt_stream.from_direct @@ fun () ->
    option_map (split_and_process_string ~boundary) @@ pop ()
  in
  Lwt_stream.append initial final

let split_part s =
  let open Lwt.Infix in
  let boundary = "\r\n" in
  let r = ref None in
  let push v =
    match !r with
    | None -> r := Some v
    | Some _ -> assert false
  in
  let pop () =
    let res = !r in
    r := None;
    res
  in
  let go c0 =
    let c =
      match pop () with
      | Some x -> x ^ c0
      | None -> c0
    in
    let string_to_process = match find_common_idx c boundary with
      | None -> c
      | Some idx ->
        begin
          let prefix = String.sub c 0 idx in
          let suffix = String.sub c idx (String.length c - idx) in
          push suffix;
          prefix
        end
    in
    Lwt.return @@ bounded_split_and_process_string ~boundary "\r\n\r\n" string_to_process
  in
  let initial = Lwt_stream.map_list_s go s in
  let final =
    Lwt_stream.flatten @@
    Lwt_stream.from_direct @@ fun () ->
    option_map (split_and_process_string ~boundary) @@ pop ()
  in
  Lwt_stream.append initial final


let until_next_delim s =
  Lwt_stream.from @@ fun () ->
  let%lwt res = Lwt_stream.get s in
  match res with
  | None
  | Some `Delim -> Lwt.return_none
  | Some (`Word w) -> Lwt.return_some w

let join s =
  Lwt_stream.filter_map (function
      | `Delim -> Some (until_next_delim @@ Lwt_stream.clone s)
      | `Word _ -> None
    ) s

let join_part s =
  Lwt_stream.filter_map (function
      | `Delim -> Some (until_next_delim @@ Lwt_stream.clone s)
      | `Word _ -> None
    ) s

let align stream boundary =
  join @@ split stream boundary

let align_part_1 stream =
  join_part @@ split_part stream

type header = string * string

let extract_boundary content_type =
  Stringext.chop_prefix ~prefix:"multipart/form-data; boundary=" content_type

let unquote s =
  Scanf.sscanf s "%S" @@ (fun x -> x)

let parse_name s =
  option_map unquote @@ Stringext.chop_prefix ~prefix:"form-data; name=" s

let parse_header s =
  match Stringext.cut ~on:": " s with
  | Some (key, value) -> (key, value)
  | None -> invalid_arg "parse_header"

let non_empty st =
  let%lwt r = Lwt_stream.to_list @@ Lwt_stream.clone st in
  Lwt.return (String.concat "" r <> "")

let get_headers : string Lwt_stream.t Lwt_stream.t -> header list Lwt.t
  = fun lines ->
  let%lwt header_lines = Lwt_stream.get_while_s non_empty lines in
  Lwt_list.map_s (fun header_line_stream ->
      let%lwt parts = Lwt_stream.to_list header_line_stream in
      let concatted = String.concat "" parts in
      Lwt.return @@ parse_header @@ concatted
    ) header_lines

type stream_part =
  { headers : header list
  ; body : string Lwt_stream.t
  }

let process_body_part s =
  let until_next_delim_helper s =
    Lwt_stream.from @@ fun () ->
    let%lwt res = Lwt_stream.get s in
    match res with
    | None ->
      Lwt.return_none
    | Some `Delim -> Lwt.return_some "\r\n"
    | Some (`Word w) -> Lwt.return_some w in
  Lwt_stream.filter_map (fun value ->
      match value with
      | `Delim -> Some (until_next_delim_helper @@ Lwt_stream.clone s)
      | `Word w ->  None
    ) s

let parse_part chunk_stream =
  let open Lwt.Infix in
  let lines = align_part_1 (Lwt_stream.clone chunk_stream) in
  match%lwt get_headers lines with
  | [] -> Lwt.return_none
  | headers ->
    let body = Lwt_stream.concat @@ Lwt_stream.clone lines in
    Lwt.return_some { headers ; body = body }

let parse_stream ~stream ~content_type =
  match extract_boundary content_type with
  | None -> Lwt.fail_with "Cannot parse content-type"
  | Some boundary ->
    begin
      let actual_boundary = ("--" ^ boundary) in
      Lwt.return @@ Lwt_stream.filter_map_s parse_part @@ align stream actual_boundary
    end

let s_part_body {body} = body

let s_part_name {headers} =
  match
    parse_name @@ List.assoc "Content-Disposition" headers
  with
  | Some x -> x
  | None -> invalid_arg "s_part_name"

let parse_filename s =
  let parts = split_on_string s ~pattern:"; " in
  List.fold_left (fun (field_name, file_name) next ->
      match next with
      | None -> (field_name, file_name)
      | (Some part) ->
        begin
          match Stringext.cut part ~on:"=" with
          | Some ("filename", quoted_string) -> (field_name, Some (unquote quoted_string))
          | Some ("name", quoted_string) -> ((unquote quoted_string), file_name)
          | _ -> (field_name, file_name)
        end
    )
    ("", None) parts


let s_part_filename {headers} =
  let filename = parse_filename @@ List.assoc "Content-Disposition" headers in
  filename

type file = stream_part

let file_stream = s_part_body
let file_name = s_part_name
let full_name = s_part_filename

let file_content_type {headers} =
  List.assoc "Content-Type" headers

let as_part part =
  match s_part_filename part with
  | (_, Some filename) ->
      Lwt.return (`File part)
  | (_, None) ->
    let%lwt chunks = Lwt_stream.to_list part.body in
    let body = String.concat "" chunks in
    Lwt.return (`String body)

let get_parts s =
  let go part m =
    let name = s_part_name part in
    let%lwt parsed_part = as_part part in
    Lwt.return @@ StringMap.add name parsed_part m
  in
  Lwt_stream.fold_s go s StringMap.empty

let concat a b =
  match (a, b) with
  | (_, "") -> a
  | ("", _) -> b
  | _ -> a ^ b

module Reader = struct
  type t =
    { mutable buffer : string
    ; source : string Lwt_stream.t
    }

  let make stream =
    { buffer = ""
    ; source = stream
    }

  let unread r s =
    r.buffer <- concat s r.buffer

  let empty r =
    if r.buffer = "" then
      Lwt_stream.is_empty r.source
    else
      Lwt.return false

  let read_next r =
    let%lwt next_chunk = Lwt_stream.next r.source in
    r.buffer <- concat r.buffer next_chunk;
    Lwt.return_unit

  let read_chunk r =
    try%lwt
      let%lwt () =
        if r.buffer = "" then
          read_next r
        else
          Lwt.return_unit
      in
      let res = r.buffer in
      r.buffer <- "";
      Lwt.return (Some res)
    with Lwt_stream.Empty ->
      Lwt.return None

  let buffer_contains r s =
    match Stringext.cut r.buffer ~on:s with
    | Some _ -> true
    | None -> false

  let rec read_until r cond =
    if cond () then
      Lwt.return_unit
    else
      begin
        let%lwt () = read_next r in
        read_until r cond
      end

  let read_line r =
    let delim = "\r\n" in
    let%lwt () = read_until r (fun () -> buffer_contains r delim) in
    match Stringext.cut r.buffer ~on:delim with
    | None -> assert false
    | Some (line, next) ->
      begin
        r.buffer <- next;
        Lwt.return (line ^ delim)
      end
end

let read_headers reader =
  let rec go headers =
    let%lwt line = Reader.read_line reader in
    if line = "\r\n" then
      Lwt.return headers
    else
      let header = parse_header line in
      go (header::headers)
  in
  go []

let rec compute_case reader boundary =
  let open Lwt.Infix in
  match%lwt Reader.read_chunk reader with
  | None -> Lwt.return `Empty
  | Some line ->
    begin
      match Stringext.cut line ~on:(boundary ^ "\r\n") with
      | Some (pre, post) -> Lwt.return @@ `Boundary (pre, post)
      | None ->
        begin
          match Stringext.cut line ~on:(boundary ^ "--\r\n") with
          | Some (pre, post) -> Lwt.return @@ `Boundary (pre, post)
          | None ->
            begin
              match find_common_idx line boundary with
              | Some 0 ->
                begin
                Reader.unread reader line;
                Reader.read_next reader >>= fun _ ->
                compute_case reader boundary
                end
              | Some amb_idx ->
                let unambiguous = String.sub line 0 amb_idx in
                let ambiguous = String.sub line amb_idx (String.length line - amb_idx) in
                Lwt.return @@ `May_end_with_boundary (unambiguous, ambiguous)
              | None -> Lwt.return @@ `App_data line
            end
        end
    end

let iter_part reader boundary callback =
  let fin = ref false in
  let last () =
    fin := true;
    Lwt.return_unit
  in
  let handle ~send ~unread ~finish =
    let%lwt () = callback send in
    Reader.unread reader unread;
    if finish then
      last ()
    else
      Lwt.return_unit
  in
  while%lwt not !fin do
    let%lwt res = compute_case reader boundary in
    match res with
    | `Empty -> last ()
    | `Boundary (pre, post) -> handle ~send:pre ~unread:post ~finish:true
    | `May_end_with_boundary (unambiguous, ambiguous) -> handle ~send:unambiguous ~unread:ambiguous ~finish:false
    | `App_data line -> callback line
  done

let read_file_part reader boundary callback =
  iter_part reader boundary callback

let strip_crlf s =
  if ends_with ~suffix:"\r\n" ~suffix_length:2 s then
    String.sub s 0 (String.length s - 2)
  else
    s

let read_string_part reader boundary =
  let open Lwt.Infix in
  let value = Buffer.create 0 in
  let append_to_value line = Lwt.return (Buffer.add_string value line) in
  iter_part reader boundary append_to_value >>= fun _ ->
  Lwt.return @@ strip_crlf (Buffer.contents value)

type callbacks =
  { default : name:string -> filename:string -> string -> unit Lwt.t
  ; named : (string * (string option ref * (string -> unit Lwt.t))) list
  }

let get_callback name filename callbacks =
  match List.assoc name callbacks.named with
  | (filename_ref, named_callback) ->
    begin
      filename_ref := Some filename;
      named_callback
    end
  | exception Not_found -> callbacks.default ~name ~filename

let read_part reader boundary callbacks fields =
  let%lwt headers = read_headers reader in
  let content_disposition = List.assoc "Content-Disposition" headers in
  let name =
    match parse_name content_disposition with
    | Some x -> x
    | None -> invalid_arg "handle_multipart"
  in
  let filename = parse_filename content_disposition in
  match filename with
  | (_, Some filename) ->
      read_file_part reader boundary @@ get_callback name filename callbacks
  | (_, None) ->
    let%lwt value = read_string_part reader boundary in
    fields := (name, value)::!fields;
    Lwt.return_unit

let handle_multipart reader boundary callbacks =
  let fields = (ref [] : (string * string) list ref) in
  let%lwt () =
    let%lwt dummyline = Reader.read_line reader in
    let fin = ref false in
    while%lwt not !fin do
      if%lwt Reader.empty reader then
        Lwt.return (fin := true)
      else
        read_part reader boundary callbacks fields
    done
  in
  Lwt.return (!fields)

let ignore_callback ~name ~filename chunk =
  Lwt.return_unit

let parse ~content_type ?(default_callback=ignore_callback) ?(callbacks=[]) stream =
  let reader = Reader.make stream in
  let boundary =
    match extract_boundary content_type with
    | Some s -> "--" ^ s
    | None -> invalid_arg "iter_multipart"
  in
  let callbacks =
    { default = default_callback
    ; named = callbacks
    }
  in
  handle_multipart reader boundary callbacks
