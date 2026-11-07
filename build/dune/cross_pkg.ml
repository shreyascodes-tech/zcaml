(* Cross-compiling a lock directory's packages, with [dune build -x <toolchain>].

   A context with a findlib toolchain takes its compiler from it, not from the
   lock directory's [ocaml] (see [Context]), so its packages' builds compile for
   the target. Each also depends on its dependencies' builds in the host
   context, and gets in its environment:

   - [DUNE_PKG_CROSS_TARGET]: the toolchain, for the package's
     [dune build -p <pkg>], which dune runs as itself: our [main] (build/dune/cross.zig)
     builds the package for the target with the toolchain, but its executables
     for the build machine, with the host context's libraries. Builds that don't
     use dune or topkg (make, configure scripts, ...) are the build machine's.
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
