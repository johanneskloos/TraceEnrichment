open Trace
open TraceTypes
open TypesJS

type items =
  | ItemFunction of int * funcspec
  | ItemFunctionOrigCode of int * string
  | ItemObject of int * objectspec
  | ItemStep of event
  | ItemIID of int * location CCIntMap.t
  | ItemEnd
  | ItemStart

exception InvalidItem of string

let parse_item json =
  let open Yojson.Basic in
  match Yojson.Basic.Util.to_list json with
    | [`String "function"; `Int id; spec] ->
        ItemFunction (id, parse_funcspec spec)
    | [`String "object"; `Int id; spec] ->
        ItemObject (id, parse_objectspec spec)
    | [`String "step"; json] ->
        ItemStep (parse_operation json)
    | [`String "function-uninstrumented"; `Assoc fval; `String code] ->
        begin try
          if List.assoc "type" fval = `String "function" then begin
            let id = Yojson.Basic.Util.to_int (List.assoc "funid" fval) in
              ItemFunctionOrigCode (id, code)
          end else
            raise (InvalidItem ("FunctionOrigCode of bad type"))
        with e ->
          raise (InvalidItem ("FunctionOrigCode bad: " ^ Printexc.to_string e))
        end
    | [`String "iidmap"; `Int sid; iidmap_json ] ->
        ItemIID (sid, parse_single_iidmap iidmap_json)
    | [`String "end" ] ->
        ItemEnd
    | [`String "start" ] ->
        ItemStart
    | _ ->
        raise (InvalidItem ("Bad item: " ^ Yojson.Basic.to_string json))

let rec extract handler = function
  | x::l ->
      if handler x then
        extract handler l
      else
        x :: extract handler l
  | [] -> []

let rec handle_end = function
  | ItemEnd :: _ -> ([], true)
  | item :: items -> let (items, at_end) = handle_end items in (item::items, at_end)
  | [] -> ([], false)

let array_ensure arr num value =
  for i = BatDynArray.length arr to num - 1 do
    BatDynArray.add arr value
  done

let function_handler initials = function
  | ItemFunction (id, spec) ->
      array_ensure initials.functions id (External (-1));
      BatDynArray.insert initials.functions id spec;
      true
  | _ -> false

let object_handler initials = function
  | ItemObject (id, spec) ->
      array_ensure initials.objects id StringMap.empty;
      BatDynArray.insert initials.objects id spec;
      true
  | _ -> false

let iid_handler initials = function
  | ItemIID (sid, map) ->
      initials.iids <- CCIntMap.add sid map initials.iids;
      true
  | _ -> false

let function_uninstrumented_handler initials = function
  | ItemFunctionOrigCode (id, code) ->
      begin
        let open Reference in
          match BatDynArray.get initials.functions id with
            | ReflectedCode ins ->
                BatDynArray.set initials.functions id
                  (OrigCode (ins, code))
            | OrigCode (ins, _) ->
                Log.err (fun m -> m "Adding uninstrumented code to a function that already has this.");
                BatDynArray.set initials.functions id
                  (OrigCode (ins, code))
            | External _ -> raise (InvalidItem "functionOrigCode for external")
      end; true
  | _ -> false

let rec handle_start initials start_wakeup = function
  | ItemStart :: items ->
      lookup_functions initials;
      Lwt.wakeup_later start_wakeup ();
      items
  | item :: items -> item :: handle_start initials start_wakeup items
  | [] -> []

let parse_packet initials event_push start_wakeup json_string =
  let items =
    Yojson.Basic.from_string json_string
    |> Yojson.Basic.Util.convert_each parse_item
  in let (operations, at_end) =
    items
    |> extract (function_handler initials)
    |> extract (function_uninstrumented_handler initials)
    |> extract (object_handler initials)
    |> extract (iid_handler initials)
    |> handle_start initials start_wakeup
    |> handle_end 
  in
    Log.debug (fun m -> m "Extracted trace operations. At end: %b, %d operations"
                          at_end (List.length operations));
  let trace =
    List.map (function ItemStep op -> op | _ -> failwith "Only ItemStep can happen!")
      operations
  in
    Log.debug (fun m -> m "Prepare event feeding");
    List.iter (fun op -> event_push (Some op)) trace;
    Log.debug (fun m -> m "Finished event feeding");
    if at_end then event_push None;
    Log.debug (fun m -> m "At-end handling")


let parse_setup_packet json_string =
  match Yojson.Basic.from_string json_string |> Yojson.Basic.Util.to_list with
    | [ `Bool globals_are_properties; `Assoc globals_json ] ->
        let globals = List.fold_left (fun globals (name, val_json) ->
                                        StringMap.add name (parse_jsval val_json) globals)
                        StringMap.empty globals_json
        in let open Reference in
        let initials =
          build_initials (BatDynArray.create ()) (BatDynArray.create ())
            globals globals_are_properties CCIntMap.empty
        in let (stream, push) = Lwt_stream.create ()
        and (start_wait, start_wakeup) = Lwt.wait ()
        in (initials, stream, start_wait, parse_packet initials push start_wakeup)
    | _ -> raise (InvalidItem ("Bad setup packet: " ^ json_string))

