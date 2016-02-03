type jsval =
  | OUndefined
  | ONull
  | OBoolean of bool
  | ONumberInt of int
  | ONumberFloat of float
  | OString of string
  | OSymbol of string
  | OFunction of int * int
  | OObject of int
  | OOther of string * int

type fieldspec = {
  value: jsval;
  writable: bool;
  get: jsval option;
  set: jsval option;
  enumerable: bool;
  configurable: bool
}

type objectspec = fieldspec StringMap.t
type objects = objectspec ExtArray.extarray

type local_funcspec = { from_toString : string; from_jalangi : string option }
type funcspec = Local of local_funcspec | External of int
type functions = funcspec ExtArray.extarray

type globals = jsval StringMap.t

let shorten s =
  let len = String.length s in
  try
    let idx = String.index s '\n' in
      String.sub s 0 (min idx 20) ^ "..."
  with Not_found ->
    if len < 20 then s else String.sub s 0 20 ^ "..."

let pp_jsval pp = let open Format in function
    | OUndefined -> pp_print_string pp "undefined"
    | ONull -> pp_print_string pp "null"
    | OBoolean x -> fprintf pp "bool:%b" x
    | ONumberInt x -> fprintf pp "int:%d" x
    | ONumberFloat x -> fprintf pp "float:%f" x
    | OString x -> fprintf pp "string:%s" (shorten x)
    | OSymbol x -> fprintf pp "symbol:%s" (shorten x)
    | OFunction (id, fid) -> fprintf pp "function:%d/%d" id fid
    | OObject id -> fprintf pp "object:%d" id
    | OOther (ty, id) -> fprintf pp "other:%s:%d" ty id

let pp_fieldspec pp { value; set; get; writable; enumerable; configurable } =
  (* Special-case the most common case *)
  if writable && enumerable && configurable && set = None && get = None then
    pp_jsval pp value
  else if set = None && get = None then
    Format.fprintf pp "[%s%s%s] %a"
      (if writable then "W" else "-")
      (if enumerable then "E" else "-")
      (if configurable then "C" else "-")
      pp_jsval value
  else
    Format.fprintf pp "[%s%s%s] %a { get = %a, set = %a }"
      (if writable then "W" else "-")
      (if enumerable then "E" else "-")
      (if configurable then "C" else "-")
      pp_jsval value
      (Fmt.option pp_jsval) get
      (Fmt.option pp_jsval) set

let pp_objectspec pp spec =
  let open Format in
  pp_open_hovbox pp 0;
  pp_print_string pp "{";
  StringMap.iter (fun fld value -> fprintf pp "@[<hov>%s: %a;@]" fld pp_fieldspec value) spec;
  pp_print_string pp "}";
  pp_close_box pp ()

let pp_objects pp arr =
  let open Format in
  pp_open_vbox pp 0;
  ExtArray.iteri (fun i s -> fprintf pp "%i: %a;@ " i pp_objectspec s) arr;
  pp_close_box pp ()
let pp_local_funcspec pp s = match s.from_jalangi with
  | Some body -> Format.fprintf pp "@[<hov>@ from_jalangi code: @[<hov>%s@]@]" body
  | None -> Format.fprintf pp "@[<hov>@ from_toString code: @[<hov>%s@]@]" s.from_toString
let pp_funcspec pp = function
  | Local s -> pp_local_funcspec pp s
  | External id -> Format.fprintf pp "(external code, id=%d)" id
let pp_functions pp arr = let open Format in
  pp_open_vbox pp 0;
  ExtArray.iteri (fun i s -> fprintf pp "%i: %a;@ " i pp_funcspec s) arr;
  pp_close_box pp ()
let pp_global_spec pp id = pp_jsval pp id
let pp_globals pp spec = let open Format in
  pp_open_hovbox pp 0;
  pp_print_string pp "{";
  StringMap.iter (fun fld value -> fprintf pp "@[<hov>%s => %a;@]" fld pp_global_spec value) spec;
  pp_print_string pp "}";
  pp_close_box pp ()

exception NotAnObject
let get_object = function
  | OObject id -> id
  | OOther (_, id) -> id
  | OFunction (id, _) -> id
  | _ -> raise NotAnObject

type objectid =
  | Object of int
  | Function of int * int
  | Other of string * int

type fieldref = objectid * string;;

let objectid_to_jsval = function
  | Object o -> OObject o
  | Function (o, f) -> OFunction (o, f)
  | Other (t, o) -> OOther (t, o)

let objectid_of_jsval = function
  | OObject o -> Object o
  | OFunction (o, f) -> Function (o, f)
  | OOther (t, o) -> Other (t, o)
  | _ -> failwith "Not an object"

let pp_objectid pp id = pp_jsval pp (objectid_to_jsval id)

let pp_fieldref pp (obj, name) = Format.fprintf pp "%a@%s" pp_objectid obj name


let get_object_id = function
  | Object id | Function (id, _) | Other (_, id) -> id

