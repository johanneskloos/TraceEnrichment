(** A unified reference type for variables and fields. *)

(** A reference to mutable state.
 *
 * Because of aliasing issues, the transformation from variables to
 * references is somewhat tricky. Therefore, we do not expose the
 * constructors of [reference]. *)
type reference = private
  | LocalVariable of string
  | GlobalVariable of string
  | Field of Types.objectid * string;;


(** Maps on references. *)
module ReferenceMap: Map.S with type key = reference

(** Pretty printers. *)
val pp_reference: Format.formatter -> reference -> unit
val pp_reference_map: (Format.formatter -> 'a -> unit) ->
  Format.formatter -> 'a ReferenceMap.t -> unit

(** Transform a variable name to a reference.
 *
 * [reference_of_name globals_are_properties alias_map is_global name]
 * creates the correct reference for the variable [name], taking into account
 * whether the variable is global ([is_global]), whether global variables
 * are references to properties of the global object ([globals_are_properties]),
 * and the current alias map ([alias_map]).
*)
val reference_of_name:
  bool -> Types.fieldref StringMap.t -> bool -> string -> reference
(** Transform a field access to a reference.
 *
 * Call as [reference_of_field base offset], where [base] must be a
 * value having an object identifier. *)
val reference_of_field: Types.jsval -> string -> reference
(** Transform a field reference to a reference. *)
val reference_of_fieldref: Types.fieldref -> reference
(** Transform a variable name that is known to be local and non-aliased to
 * a reference.
 *
 * Beware: Unless you are certain that no aliasing occurs for this name,
 * use [reference_of_name]! *)
val reference_of_local_name: string -> reference

(** Versioned references are references with an integer version. *)
type versioned_reference = reference * int
module VersionReferenceMap : Map.S with type key = versioned_reference
module VersionReferenceSet : Set.S with type elt = versioned_reference
val pp_versioned_reference: Format.formatter -> versioned_reference -> unit
val pp_versioned_reference_set: Format.formatter -> VersionReferenceSet.t -> unit
val pp_versioned_reference_map: (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a VersionReferenceMap.t -> unit

(** A points-to map assigned a value to each versioned reference occuring in a trace. *)
type points_to_map = Types.jsval VersionReferenceMap.t
(** Pretty-printer. *)
val pp_points_to_map: Format.formatter -> points_to_map -> unit

