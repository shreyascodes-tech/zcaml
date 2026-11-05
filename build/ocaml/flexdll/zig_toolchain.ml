(* zcaml: support for using `zig cc` as the mingw/mingw64 C toolchain.

   This fragment is spliced into flexdll's reloc.ml (just before
   `setup_toolchain`) by `zig build`; it is not a standalone module.

   flexlink needs to know every symbol that the C toolchain provides by
   default (CRT start files, libmingw32, compiler-rt, the UCRT and Win32 import
   libraries, ...): such symbols are left to the linker, while all others in a
   DLL are resolved at load time from the main program. With gcc these
   libraries are found through `gcc -print-search-dirs`. Zig instead builds them
   on demand into its global cache, so we ask `zig cc -v` which libraries it
   would pass to `lld-link` for a trivial program and scan those.

   `-lfoo` options that cannot be found in the `-L`/`-I` directories are
   resolved the same way and passed through to `zig cc` unchanged (see
   [zig_libs] in `find_file`). *)

let zig_is_hex c =
  match c with '0'..'9' | 'a'..'f' -> true | _ -> false

let zig_is_sep c = c = '/' || c = '\\'

(* Positions [(start, stop)] of every `o<sep><32 hex digits><sep><name>.lib`
   (or `.obj`) in an `lld-link` command line, where [start] is the index of the
   `o` and [stop] is one past the end of the name. *)
let zig_cache_matches line =
  let n = String.length line in
  let ends_with_any s =
    List.exists (fun suf ->
        let ls = String.length s and lf = String.length suf in
        ls > lf && String.sub s (ls - lf) lf = suf)
      [".lib"; ".obj"]
  in
  let rec scan i acc =
    if i + 36 >= n then List.rev acc
    else if line.[i] = 'o' && i > 0 && zig_is_sep line.[i - 1]
            && zig_is_sep line.[i + 1] && zig_is_sep line.[i + 34] then begin
      let ok = ref true in
      for k = i + 2 to i + 33 do if not (zig_is_hex line.[k]) then ok := false done;
      if not !ok then scan (i + 1) acc
      else begin
        let j = ref (i + 35) in
        while !j < n && line.[!j] <> ' ' do incr j done;
        if ends_with_any (String.sub line i (!j - i)) then scan !j ((i, !j) :: acc)
        else scan (i + 1) acc
      end
    end else scan (i + 1) acc
  in
  scan 0 []

(* Paths in the `lld-link` line are printed unquoted and may contain spaces.
   Every library lives in the same cache directory, and most of them are
   adjacent on the command line, so the most common text found between two
   consecutive matches is the cache directory prefix. *)
let zig_parse_libs line =
  let matches = Array.of_list (zig_cache_matches line) in
  let counts = Hashtbl.create 8 in
  for k = 1 to Array.length matches - 1 do
    let (_, prev_stop) = matches.(k - 1) and (start, _) = matches.(k) in
    if start > prev_stop && line.[prev_stop] = ' ' then begin
      let prefix = String.sub line (prev_stop + 1) (start - prev_stop - 1) in
      let c = try Hashtbl.find counts prefix with Not_found -> 0 in
      Hashtbl.replace counts prefix (c + 1)
    end
  done;
  let prefix, _ =
    Hashtbl.fold (fun p c (bp, bc) -> if c > bc then (p, c) else (bp, bc))
      counts ("", 0)
  in
  let lp = String.length prefix in
  Array.fold_right (fun (start, stop) acc ->
      if start >= lp && String.sub line (start - lp) lp = prefix
         && (start = lp || line.[start - lp - 1] = ' ')
      then (prefix ^ String.sub line start (stop - start)) :: acc
      else acc)
    matches []

let zig_setup () =
  use_cygpath := `No;
  search_path := !dirs;
  let missing =
    List.filter (fun f ->
        String.length f > 2 && String.sub f 0 2 = "-l"
        && (try ignore (find_file_exn f); false with Not_found -> true))
      !files
  in
  List.iter (fun f -> Hashtbl.replace zig_libs f ()) missing;
  (* `zig cc` caches the probe's object under the source path: keep it fixed. *)
  let src = Filename.concat (Filename.get_temp_dir_name ()) "flexlink_zig_probe.c" in
  if not (Sys.file_exists src) then begin
    let tmp = temp_file "flexlink_zig" ".c" in
    let oc = open_out tmp in
    output_string oc "int main(void) { return 0; }\n";
    close_out oc;
    Sys.rename tmp src
  end;
  let stem = Filename.chop_suffix (temp_file "flexlink_zig" ".tmp") ".tmp" in
  let out = stem ^ (if !exe_mode = `EXE then ".exe" else ".dll") in
  List.iter (fun ext -> ignore (add_temp (stem ^ ext))) [".exe"; ".dll"; ".pdb"; ".lib"];
  let log = temp_file "flexlink_zig" ".log" in
  let cmd =
    Printf.sprintf "%s -v %s-o %s %s %s > %s 2>&1"
      (cc !toolchain)
      (if !exe_mode = `EXE then "" else
         "-shared -Wl,--out-implib=" ^ Filename.quote (stem ^ ".lib") ^ " ")
      (Filename.quote out) (Filename.quote src)
      (quote_files (List.map (fun d -> "-L" ^ d) !dirs @ missing))
      (Filename.quote log)
  in
  debug 1 "+ %s" cmd;
  let status = Sys.command cmd in
  let lines = read_file log in
  if status <> 0 then begin
    List.iter prerr_endline lines;
    failwith "Cannot determine the default libraries of zig cc"
  end;
  let link_line =
    try List.find (fun l -> has_prefix "lld-link " l) lines
    with Not_found -> failwith "Cannot find the lld-link command in zig cc -v output"
  in
  let own_obj = Filename.chop_suffix (Filename.basename src) ".c" ^ ".obj" in
  let libs =
    List.filter (fun f -> Filename.basename f <> own_obj) (zig_parse_libs link_line)
  in
  if libs = [] then
    failwith "Cannot find the default libraries in zig cc -v output";
  if !verbose >= 1 then begin
    Printf.printf "zig cc default libraries:\n";
    List.iter (Printf.printf "  %s\n") libs;
    flush stdout
  end;
  default_libs := libs;
  (* Reproducible images: a content hash instead of the link time in the
     COFF timestamp and the PDB signature. *)
  extra_args := "-Wl,-Brepro" :: !extra_args;
  (* Flexdll requires all images (the main program and the DLLs) to be close
     to each other in memory, because of 32-bit relative relocations. As for
     the msvc64 chain, request a low image base. *)
  if !machine = `x64 then
    extra_args := ("-Wl,--image-base=" ^ !base_addr) :: !extra_args

