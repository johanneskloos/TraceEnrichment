let (/:) = Filename.concat

let instrument_script_path =
  List.fold_right (/:) [ "src"; "js"; "commands" ] "instrument.js"

exception InstrumentationError

let instrument_make_html basename =
  Jg_template.from_string
    ~models:[ ("basename", Jg_types.Tstr (Filename.basename basename)) ]
    PageText.analysis_driver

let unlink_files files =
  Lwt.join (List.map (fun file ->
                        Lwt.catch
                          (fun () -> Lwt_unix.unlink file)
                          (fun _ -> Lwt.return_unit)) files)

(** Instrument one or more files using Jalangi2 and tracing instrumentation.
    Call as [jalangi2_instument strategy filenames outdir], where
    [strategy] representes a tracing strategy (see the generic tracer for this),
    [filenames] gives the filenames of files to instrument, and [outdir] the
    output directory. *)
let jalangi2_instrument strategy filenames outdir =
  let open Lwt in
  let args =
    [ "node";
      Config.get_jalangi2_path() /: instrument_script_path;
      "--inlineIID";
      "--inlineSource";
      "--inlineJalangi";
      "-i";
      "--analysis"; Config.get_analysis_script_path () /: "AlmostWeakMap.js";
      "--analysis"; Config.get_analysis_script_path () /: "generic-tracer.js";
      "--initParam"; "host:" ^ (Config.get_xhr_server_address ());
      "--initParam"; "port:" ^ (string_of_int (Config.get_xhr_server_port ()));
      "--initParam"; "strategy:" ^ strategy;
      "--outputDir"; outdir;
    ] @ filenames
  in let argarray = Array.of_list args in
    Log.info (fun m -> m "Executing 'node %a'" (Fmt.list Fmt.string) args);
  match Lwt_unix.fork () with
  | 0 ->
      Unix.close Unix.stdout;
      Unix.close Unix.stderr;
      Unix.execv (Config.get_node_path ()) argarray
  | pid ->
    match%lwt Lwt_unix.waitpid [] pid with
      | (_, Unix.WEXITED 0) ->
          (* Clean up. *)
          if Config.get_keep_temporaries () then
            Lwt.return_unit
          else
            Lwt_list.iter_p
              (fun filename ->
                 let base = Filename.basename filename in
                 if Filename.check_suffix base ".js" then begin
                   let base = outdir /: Filename.chop_suffix base ".js" in
                     unlink_files [ base ^ "_jalangi_.json"; base ^ "_orig_.js" ]
                 end else
                   Lwt.return_unit)
              filenames
      | _ -> raise InstrumentationError

let instrument_tmp_dir = ref None

let get_instrument_tmp_dir () =
  match !instrument_tmp_dir with
  | Some dir -> Lwt.return (dir, dir /: "instrumented")
  | None ->
    let%lwt path = Files.temp_dir_lwt "jstools" "" in
    let%lwt _ = Lwt_unix.mkdir (path /: "instrumented") 0o700 in
    instrument_tmp_dir := Some path;
    Lwt.return (path, path /: "instrumented")

let get_instrumented_dir () = Lwt.map snd (get_instrument_tmp_dir ())
let clean_up () =
  match !instrument_tmp_dir with
    | Some base ->
        if not (Config.get_keep_temporaries ()) then
          ignore (Sys.command ("rm -rf " ^ base))
    | None -> ()

(** Instrument a JS script for browser use.
    Call as [instrument_for_browser ~basename ~providejs],
    where [providejs] is a function taking a path name.

    First, [providejs] is called with the name of a temporary
    file (whose name is based on basename, if given).
    It is supposed to write a JavaScript file to this path name.
    Then, this file is instrumented by Jalangi, and a driver
    HTML file is generated. The function returns the path
    to both files, excluding the extension.
    *)
let instrument_for_browser ?basename ~providejs =
  let%lwt (tmpdir, insdir) = get_instrument_tmp_dir () in
    Log.debug (fun m -> m "tmpdir = %s, insdir = %s" tmpdir insdir);
  let basename = match basename with
    | Some basename -> tmpdir /: Filename.basename basename
    | None -> Filename.temp_file ~temp_dir:tmpdir "gen" ""
  in
    Log.debug (fun m -> m "basename = %s" basename);
  let jsfile = basename ^ ".js" and htmlfile = basename ^ ".html" in
    Log.debug (fun m -> m "jsfile = %s, htmlfile = %s" jsfile htmlfile);
  let%lwt () = providejs jsfile in
    Log.debug (fun m -> m "instrumented successfully");
  let driver = instrument_make_html basename in
    Log.debug (fun m -> m "driver file: %s" driver);
  let%lwt () = Lwt_io.with_file Lwt_io.Output htmlfile (fun c -> Lwt_io.write c driver) in
    Log.debug (fun m -> m "wrote driver");
  let%lwt () = jalangi2_instrument "xhr" [ jsfile; htmlfile ] insdir in
    Log.debug (fun m -> m "instrumented");
  let%lwt () =
    if Config.get_keep_temporaries () then
      Lwt.return_unit
    else
      unlink_files [ jsfile; htmlfile; basename ]
  in
    Log.debug (fun m -> m "dealt with temporaries");
    Lwt.return (insdir /: Filename.basename basename)

let mutated_path base path =
  let uri = Uri.to_string (Uri.resolve "" base (Uri.of_string path))
  in Uuidm.to_string (Uuidm.v5 Uuidm.ns_url uri)

let rec url_reader ~request_headers ~base url: char Lwt_stream.t Lwt.t =
  let url = Uri.resolve "" base url
  in let%lwt (response, body) = Cohttp_lwt_unix.Client.get ~headers:request_headers url
  in match Cohttp.Response.(response.status) with
      (* OK-style responses *)
    | `OK
    | `Created
    | `Accepted
    | `Non_authoritative_information
    | `No_content
    | `Reset_content ->
        begin match body with
            `Empty -> Lwt.return (Lwt_stream.of_list [])
          | `Stream s -> Lwt.return (Lwt_stream.map_list BatString.to_list s)
          | `String s -> Lwt.return (Lwt_stream.of_string s)
          | `Strings s -> Lwt.return (Lwt_stream.of_string (BatString.concat "" s))
        end
      (* Redirect responses *)
    | `Moved_permanently
    | `Found
    | `See_other
    | `Temporary_redirect ->
        begin match
          Cohttp.Header.get Cohttp.Response.(response.headers) "Location"
        with Some url -> url_reader ~request_headers ~base (Uri.of_string url)
          | None -> Log.err (fun m -> m "Bad redirect");
                    raise Exit
        end
      (* Not found/server error responses *)
    | `Bad_request
    | `Unauthorized
    | `Payment_required
    | `Forbidden
    | `Not_found
    | `Method_not_allowed
    | `Not_acceptable
    | `Proxy_authentication_required
    | `Request_timeout
    | `Gone
    | `Locked
    | `Upgrade_required
    | `Too_many_requests
    | `Internal_server_error
    | `Not_implemented
    | `Bad_gateway
    | `Service_unavailable
    | `Gateway_timeout
    | `Bandwidth_limit_exceeded
    | `Insufficient_storage as s ->
        Log.err (fun m -> m "Failed to load %s, reason: %s"
                            (Uri.to_string url)
                            (Cohttp.Code.string_of_status s));
        Lwt.fail Not_found
    (* Other responses *)
    | s -> Log.err(fun m -> m "Got unhandled response %s for %s"
                              (Cohttp.Code.string_of_status s)
                              (Uri.to_string url));
              raise Exit

let map_script_path server_base base = function
  | `Start_element ((path, "script"), args) ->
      `Start_element ((path, "script"),
       BatList.map (function
                      | ((namespace, "src"), path) ->
                          ((namespace, "src"), server_base ^ mutated_path base path ^ ".js")
                      | a -> a)
         args)
  | s -> s

let fold_script_collection ~request_headers tmpdir base s (tasks, paths) =
  match s with
    | `Start_element ((_, "script"), args) ->
        begin try
          let path = List.assoc ("", "src") args
          in let mutated = tmpdir /: mutated_path base path ^ ".js"
          in Lwt.try_bind (fun () -> url_reader ~request_headers ~base (Uri.of_string path))
               (fun reader -> Lwt.return
                  (Lwt_io.chars_to_file mutated reader :: tasks,
                   mutated :: paths))
               (function
                  | Not_found -> Lwt.return (tasks, paths)
                  | e -> Lwt.fail e)
        with Not_found -> Lwt.return (tasks, paths)
        end
    | _ -> Lwt.return (tasks, paths)

let onload_script = {javascript|
// JALANGI DO NOT INSTRUMENT
var onload_chain = onload;
onload = function () { 
  if (typeof onload_chain === 'function') {
    onload_chain();
  }
  J$.initParams.end();
  document.location = J$.initParams.session_url;
}
|javascript}

(* WTF, markup library - why don't you tell me what the end tag
 * is for *)
let insert_onload_handler level signal =
  match signal, level with
  | `Start_element ((_, "body"), _), None ->
      Lwt.return ([signal], Some (Some 0))
  | `Start_element _, Some i ->
      Lwt.return ([signal], Some (Some (i+1)))
  | `End_element, Some 0 ->
      (* This is </body> *)
      Lwt.return ([`Start_element (("", "script"), []);
                   `Text [onload_script];
                   `End_element;
                   signal],
                  Some None)
  | `End_element, Some i ->
      Lwt.return ([signal], Some (Some (i-1)))
  | _, _ ->
      Lwt.return ([signal], Some level)

type where = OUTSIDE | HTML | HEAD of int * Markup.signal list | DONE
let insert_base_if_needed base_str where signal =
  let base_signal base_str = [
    `Start_element ((Markup.Ns.html, "base"), [(("", "href"), base_str)]);
    `End_element
  ]
  in let head_base_signal base_str =
    let bs = base_signal base_str
    in `Start_element ((Markup.Ns.html, "head"), []) :: bs @ [`End_element]
  in match signal, where with
    | `Start_element ((_, "html"), _), OUTSIDE ->
        Lwt.return ([signal], Some HTML)
    | `Start_element ((_, "head"), _), HTML ->
        Lwt.return ([signal], Some (HEAD (0, [])))
    | `Start_element ((_, "base"), _), HEAD (_, l) ->
        Lwt.return (BatList.rev (signal :: l), Some DONE)
    | `Start_element _, HEAD (i, l) ->
        Lwt.return ([], Some (HEAD (i+1, signal :: l)))
    | `End_element, HEAD (0, l) ->
        Lwt.return (base_signal base_str @ BatList.rev l, Some DONE)
    | `End_element, HEAD (i, l) ->
        Lwt.return ([], Some (HEAD (i-1, signal :: l)))
    | _, HEAD (i, l) ->
        Lwt.return ([], Some (HEAD (i, signal :: l)))
    | `Start_element _, HTML ->
        Lwt.return (head_base_signal base_str @ [signal], Some DONE)
    | _, _ -> Lwt.return ([signal], Some where)

(* The function gets calls as [instrument_page headers uri], and instruments
 * the page at the given URI.
 * It returs the path to the instrumented HTML file. *)
let instrument_page request_headers base_str =
  let base = Uri.of_string base_str
  and server_base =
    Uri.make ~scheme:"http"
      ~host:(Config.get_xhr_server_address())
      ~port:(Config.get_xhr_server_port())
      ~path:"/"
      ()
    |> Uri.to_string
  in let%lwt (tmpdir, insdir) = get_instrument_tmp_dir ()
  in let html_path = tmpdir /: (mutated_path base base_str) ^ ".html"
  in let%lwt html_raw_stream = url_reader ~request_headers ~base base
  in let html_stream =
    html_raw_stream
      |> Markup_lwt.lwt_stream
      |> Markup_lwt.parse_html ~context:`Document
      |> Markup.signals
      |> Markup_lwt.to_lwt_stream
  in let html_stream_dup = Lwt_stream.clone html_stream
  in let html_writer =
    Log.info (fun m -> m "Writing HTML to %s" html_path);
    Markup_lwt.lwt_stream html_stream
      |> Markup_lwt.map (fun s -> Lwt.return (map_script_path server_base base s))
      |> Markup_lwt.transform insert_onload_handler None
      |> Markup_lwt.transform (insert_base_if_needed base_str) OUTSIDE
      |> Markup_lwt.write_html
      |> Markup_lwt_unix.to_file html_path
  in let%lwt (tasks, paths) =
    Lwt_stream.fold_s (fold_script_collection ~request_headers tmpdir base)
      html_stream_dup ([], [])
  in let%lwt _ = Lwt.join (html_writer :: tasks)
  in let%lwt _ = jalangi2_instrument "xhr" (html_path :: paths) insdir
  in Lwt.return (Filename.basename html_path)
