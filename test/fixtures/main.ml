external zcaml_add_mul : int -> int -> int -> int = "zcaml_add_mul"
external zcaml_call_ocaml_closure : (int -> int) -> int -> int = "zcaml_call_ocaml_closure"

(* 1. OCaml 5 Effects / fiber stack switching *)
type _ Effect.t += Ask : int -> int Effect.t

let test_effects () =
  let comp () =
    let a = Effect.perform (Ask 10) in
    let b = Effect.perform (Ask 32) in
    a + b
  in
  let res =
    Effect.Deep.match_with comp ()
      { retc = (fun x -> x);
        exnc = raise;
        effc = (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Ask n -> Some (fun (k : (a, _) Effect.Deep.continuation) ->
              Effect.Deep.continue k (n * 2))
          | _ -> None) }
  in
  assert (res = 84)

(* 2. C stubs + callback across C frame + exception handling *)
let test_c_stubs () =
  assert (zcaml_add_mul 3 4 6 = 42);
  let cb x =
    if x < 0 then failwith "negative_input"
    else x + 100
  in
  assert (zcaml_call_ocaml_closure cb 23 = 123);
  let caught =
    try
      ignore (zcaml_call_ocaml_closure cb (-5));
      false
    with Failure msg -> msg = "negative_input"
  in
  assert caught

(* 3. Lexer & Parser *)
let test_lex_yacc () =
  let lexbuf = Lexing.from_string "2 + 5 * 8" in
  let result = Calc_parser.main Calc_lexer.token lexbuf in
  assert (result = 42)

(* 4. Packed / Archived module *)
let test_pack () =
  assert (Packed.Sub_b.compute 23 = 42)

(* 5. Str regex *)
let test_str () =
  let re = Str.regexp "ocaml-\\([0-9]+\\)\\.\\([0-9]+\\)" in
  assert (Str.string_match re "ocaml-5.5" 0);
  assert (Str.matched_group 1 "ocaml-5.5" = "5");
  assert (Str.matched_group 2 "ocaml-5.5" = "5")

(* 6. Unix library *)
let test_unix () =
  let r, w = Unix.pipe () in
  let msg = Bytes.of_string "zcaml-unix-pipe" in
  let written = Unix.write w msg 0 (Bytes.length msg) in
  assert (written = Bytes.length msg);
  Unix.close w;
  let buf = Bytes.create 64 in
  let n = Unix.read r buf 0 64 in
  Unix.close r;
  assert (Bytes.sub_string buf 0 n = "zcaml-unix-pipe");
  let st = Unix.stat "." in
  assert (st.Unix.st_kind = Unix.S_DIR)

(* 7. Domains + Systhreads *)
let test_concurrency () =
  let atomic_sum = Atomic.make 0 in
  let mtx = Mutex.create () in
  let thread_sum = ref 0 in
  let domains =
    Array.init 2 (fun d ->
      Domain.spawn (fun () ->
        let ths =
          Array.init 2 (fun t ->
            Thread.create (fun () ->
              let v = (d + 1) * 10 + (t + 1) in
              Atomic.fetch_and_add atomic_sum v |> ignore;
              Mutex.lock mtx;
              thread_sum := !thread_sum + v;
              Mutex.unlock mtx
            ) ())
        in
        Array.iter Thread.join ths))
  in
  Array.iter Domain.join domains;
  (* (11 + 12) + (21 + 22) = 66 *)
  assert (Atomic.get atomic_sum = 66);
  assert (!thread_sum = 66)

(* 8. Marshaling *)
let test_marshal () =
  let data = List.init 200 (fun i -> (i, string_of_int (i * i))) in
  let bytes = Marshal.to_bytes data [Marshal.Closures] in
  let roundtrip : (int * string) list = Marshal.from_bytes bytes 0 in
  assert (roundtrip = data)

(* 9. GC & Finalisers *)
let test_gc () =
  let finalised = Atomic.make false in
  let mk () =
    let r = ref (String.make 64 'x') in
    Gc.finalise (fun _ -> Atomic.set finalised true) r;
    r
  in
  ignore (Sys.opaque_identity (mk ()));
  Gc.full_major ();
  Gc.full_major ();
  assert (Atomic.get finalised)

(* 10. Runtime_events *)
let test_runtime_events () =
  Runtime_events.start ();
  let cursor = Runtime_events.create_cursor None in
  let callbacks = Runtime_events.Callbacks.create () in
  ignore (Runtime_events.read_poll cursor callbacks None);
  Runtime_events.free_cursor cursor

(* 11. Dynlink *)
let test_dynlink plugin_path =
  if plugin_path <> "" then begin
    Dynlink.loadfile plugin_path;
    match !Plugin_api.registered with
    | Some f -> assert (f 10 = 31)
    | None -> assert false
  end

let () =
  Printexc.record_backtrace true;
  let plugin = if Array.length Sys.argv > 1 then Sys.argv.(1) else "" in
  test_effects ();
  test_c_stubs ();
  test_lex_yacc ();
  test_pack ();
  test_str ();
  test_unix ();
  test_concurrency ();
  test_marshal ();
  test_gc ();
  test_runtime_events ();
  test_dynlink plugin;
  print_endline "ZCAML_VERIFY_OK"
