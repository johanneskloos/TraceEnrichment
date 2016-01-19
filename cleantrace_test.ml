Debug.enable_validate();

List.iter
  (fun file -> try
     Format.eprintf "%s@." file;
     file
       |> open_in
       |> Trace.parse_tracefile
       |> CleanTrace.clean_tracefile
       |> ignore
   with e -> Format.eprintf "%s@." (Printexc.to_string e))
  (List.tl (Array.to_list Sys.argv))
