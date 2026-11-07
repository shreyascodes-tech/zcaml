(* Cross-compiling a lock directory's packages, with [dune build -x <toolchain>].

   A context with a findlib toolchain takes its compiler from it, not from the
   lock directory's [ocaml] (see [Context]), of the same release
   ([check_compiler]), so its packages' builds compile for the target. The OCaml
   tools its rules run by name are the toolchain's too ([toolchain_tool]). Each package's
   build also depends on its dependencies' builds in the host context, and gets
   in its environment:

   - [DUNE_PKG_CROSS_TARGET]: the toolchain, for the package's
     [dune build -p <pkg>] and [dune exec], which dune runs as itself: our [main]
     (build/dune/cross.zig) builds the package for the target with the
     toolchain, but its executables for the build machine, with the host
     context's libraries. Builds that don't use dune or topkg (make, configure
     scripts, ...) are the build machine's.
   - [DUNE_PKG_CROSS_HOST]: the host context.
   - [TOPKG_CONF_TOOLCHAIN]: the toolchain, for topkg's builds.

   Outside a lock directory's packages, in contexts without a toolchain, nothing
   changes. *)

open Import
open Memo.O

type t =
  { toolchain : Context_name.t
  ; host : Context_name.t
  }

(* The findlib toolchain and host context of [context], as [Context] makes
   them: a workspace context's [(toolchain)] and [(host)], or one of its
   targets ([-x]). *)
let of_context context =
  let+ workspace = Workspace.workspace () in
  List.find_map workspace.contexts ~f:(fun ctx ->
    let base = Workspace.Context.base ctx in
    if Context_name.equal base.name context
    then (
      match base.toolchain, base.host_context with
      | Some toolchain, Some host -> Some { toolchain; host }
      | _ -> None)
    else
      List.find_map base.targets ~f:(function
        | Workspace.Context.Target.Native -> None
        | Named { name = toolchain; _ } ->
          Option.some_if
            (Context_name.equal context (Context_name.target base.name ~toolchain))
            { toolchain; host = base.name }))
;;

(* The program [prog] of a rule's [(run prog ...)], in a context with a findlib
   toolchain whose compiler is [ocaml], if it's one of the compiler's tools: the
   toolchain's, as dune's own rules use. dune looks a rule's programs up for the
   build machine (in the host context), right for anything else. Not [ocaml]:
   scripts run on the build machine. *)
let toolchain_tool ~findlib_toolchain ~ocaml prog =
  match findlib_toolchain with
  | None -> Memo.return None
  | Some _ ->
    let+ (ocaml : Ocaml_toolchain.t) = ocaml () in
    (match prog with
     | "ocamlc" -> Some ocaml.ocamlc
     | "ocamlopt" -> Result.to_option ocaml.ocamlopt
     | "ocamldep" -> Result.to_option ocaml.ocamldep
     | "ocamlmklib" -> Result.to_option ocaml.ocamlmklib
     | "ocamlobjinfo" -> Result.to_option ocaml.ocamlobjinfo
     | _ -> None)
;;

(* The host context's builds are of the same packages, by digest, from the same
   lock directory. *)
let check_lock_dir context ~host =
  let* lock_dir = Lock_dir.get_path context in
  let+ host_lock_dir = Lock_dir.get_path host in
  if not (Option.equal Path.equal lock_dir host_lock_dir)
  then
    User_error.raise
      [ Pp.textf
          "Context %S cross-compiles its lock directory's packages with the builds of \
           the same packages in its host context %S, which needs the same lock \
           directory."
          (Context_name.to_string context)
          (Context_name.to_string host)
      ]
;;

(* A cross context's compiler, [ocaml] (from its findlib toolchain), compiles the
   same release as the host context's, the lock directory's [ocaml]: OCaml reads
   only its own release's compiled interfaces and ppx ASTs. *)
let check_compiler context ((ocaml : Ocaml_toolchain.t), _ as toolchain) =
  let+ lock_dir = Lock_dir.get_exn context in
  let release version =
    let before c v =
      match String.lsplit2 v ~on:c with
      | Some (v, _) -> v
      | None -> v
    in
    before '~' (before '+' version)
  in
  let compiler = release (Ocaml_config.version_string ocaml.ocaml_config) in
  let locked =
    Dune_pkg.Lock_dir.Packages.to_pkg_list lock_dir.packages
    |> List.filter_map ~f:(fun (pkg : Dune_pkg.Lock_dir.Pkg.t) ->
      Option.some_if
        (Package.Name.equal pkg.info.name (Package.Name.of_string "ocaml"))
        (Package_version.to_string pkg.info.version))
  in
  if (not (List.is_empty locked)) && not (List.mem locked compiler ~equal:String.equal)
  then
    User_error.raise
      [ Pp.textf
          "Context %S compiles with OCaml %s, from its toolchain, but its lock \
           directory has OCaml %s."
          (Context_name.to_string context)
          compiler
          (String.concat ~sep:", " locked)
      ]
      ~hints:
        [ Pp.text "Lock a compiler of the same release, or use a toolchain of the lock's." ];
  toolchain
;;

(* [action], the build of a package in [context], whose dependencies' target
   directories in a context are [deps_target_dirs]. *)
let build_action context ~deps_target_dirs (action : _ Action_builder.With_targets.t) =
  let build =
    let open Action_builder.O in
    Action_builder.of_memo (of_context context)
    >>= function
    | None -> action.build
    | Some { toolchain; host } ->
      let* () = Action_builder.of_memo (check_lock_dir context ~host) in
      let toolchain = Context_name.to_string toolchain in
      let env =
        Env.empty
        |> Env.add ~var:"DUNE_PKG_CROSS_TARGET" ~value:toolchain
        |> Env.add ~var:"DUNE_PKG_CROSS_HOST" ~value:(Context_name.to_string host)
        |> Env.add ~var:"TOPKG_CONF_TOOLCHAIN" ~value:toolchain
      in
      Action_builder.paths (List.map (deps_target_dirs host) ~f:Path.build)
      >>> Action_builder.map action.build ~f:(Action.Full.add_env env)
  in
  { action with build }
;;

(* The subdirectories of [_build/_private] ([dir]) that are package builds:
   [contexts]', and inactive [-x] contexts' ([<context>.<toolchain>]), kept so
   that building for another target doesn't throw them away. *)
let private_dirs ~dir contexts =
  let names = List.map contexts ~f:Context_name.to_string in
  let is_cross_of name context = String.starts_with name ~prefix:(context ^ ".") in
  let inactive =
    match Path.Untracked.readdir_unsorted (Path.build dir) with
    | Error _ -> []
    | Ok entries ->
      List.filter entries ~f:(fun entry ->
        List.exists names ~f:(is_cross_of (Filename.to_string entry)))
  in
  Subdir_set.of_list (List.map names ~f:Filename.of_string_exn @ inactive)
;;
