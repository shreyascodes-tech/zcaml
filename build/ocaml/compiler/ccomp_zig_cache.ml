(* zcaml: a private Zig cache for C toolchain commands, and gcc's object names.

   This fragment is spliced into utils/ccomp.ml (just before `command`) by
   `zig build`; it is not a standalone module.

   `zig cc` keeps every object file it compiles in its cache, keyed by the
   source's path, and OCaml assembles randomly named temporary files
   (`camlasm*.s`, `camlstartup*.s`): each compilation would leave an entry
   in the user's Zig cache forever. Commands run with a cache of their own
   instead, removed at exit. The C runtime libraries `zig cc` links stay in
   Zig's global cache. *)

let zig_cache_dir = lazy (
  let rec remove_tree path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> remove_tree (Filename.concat path f)) (Sys.readdir path);
      Sys.rmdir path
    end else Sys.remove path
  in
  let dir = Filename.temp_dir "camlzig" "" in
  at_exit (fun () -> try remove_tree dir with Sys_error _ -> ());
  dir)

let with_zig_cache cmdline =
  if not Sys.win32 then
    Printf.sprintf "ZIG_LOCAL_CACHE_DIR=%s; export ZIG_LOCAL_CACHE_DIR; %s"
      (Filename.quote (Lazy.force zig_cache_dir)) cmdline
  else if String.starts_with ~prefix:"\"" cmdline then
    (* cmd.exe strips the outer quotes of such commands: a prefix would stop it. *)
    cmdline
  else
    Printf.sprintf "set \"ZIG_LOCAL_CACHE_DIR=%s\" && %s"
      (Lazy.force zig_cache_dir) cmdline


(* `ocamlopt -c foo.c` leaves the object's name to the C compiler, which
   is `foo.o` for gcc but `foo.obj` for `zig cc` targeting Windows: name
   it as gcc would, `Config.ext_obj` in the current directory. *)
let default_c_output name =
  Printf.sprintf "%s%s" Config.c_output_obj
    (Filename.quote (Filename.remove_extension (Filename.basename name) ^ Config.ext_obj))
