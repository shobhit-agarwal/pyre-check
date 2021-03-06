(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
open Ast

type t = {
  global_resolution: GlobalResolution.t;
  annotation_store: RefinementUnit.t Reference.Map.t;
  type_variables: Type.Variable.Set.t;
  resolve: resolution:t -> Expression.t -> Annotation.t;
  resolve_assignment: resolution:t -> Statement.Assign.t -> t;
  parent: Reference.t option;
}

let create ~global_resolution ~annotation_store ~resolve ~resolve_assignment ?parent () =
  {
    global_resolution;
    annotation_store;
    type_variables = Type.Variable.Set.empty;
    resolve;
    resolve_assignment;
    parent;
  }


let pp format { annotation_store; type_variables; _ } =
  let annotation_store_entry (reference, refinement_unit) =
    Format.asprintf "%a -> %a" Reference.pp reference RefinementUnit.pp refinement_unit
  in
  Type.Variable.Set.to_list type_variables
  |> List.map ~f:Type.Variable.show
  |> String.concat ~sep:", "
  |> Format.fprintf format "Type variables: [%s]\n";
  Map.to_alist annotation_store
  |> List.map ~f:annotation_store_entry
  |> String.concat ~sep:", "
  |> Format.fprintf format "Annotation Store: [%s]"


let show resolution = Format.asprintf "%a" pp resolution

let is_global { global_resolution; _ } ~reference =
  Reference.delocalize reference |> GlobalResolution.global global_resolution |> Option.is_some


let resolve ({ resolve; _ } as resolution) expression =
  resolve ~resolution expression |> Annotation.annotation


let resolve_to_annotation ({ resolve; _ } as resolution) expression = resolve ~resolution expression

let resolve_reference ({ resolve; _ } as resolution) reference =
  Expression.from_reference ~location:Location.any reference
  |> resolve ~resolution
  |> Annotation.annotation


let resolve_assignment ({ resolve_assignment; _ } as resolution) assignment =
  resolve_assignment ~resolution assignment


let resolve_mutable_literals ({ global_resolution; _ } as resolution) =
  GlobalResolution.resolve_mutable_literals global_resolution ~resolve:(resolve resolution)


let partition_name resolution ~name =
  let identifiers = Reference.as_list (Expression.name_to_reference_exn name) in
  match identifiers with
  | head :: attributes ->
      let rec partition_attribute base attribute_list =
        let base_type = resolve_reference resolution base in
        if Type.is_untyped base_type then
          match attribute_list with
          | [] -> Reference.create head, attributes, None
          | attribute :: attribute_list ->
              partition_attribute Reference.(attribute |> create |> combine base) attribute_list
        else
          base, attribute_list, Some (Annotation.create base_type)
      in
      partition_attribute (Reference.create head) attributes
      |> fun (base, attributes, annotation) ->
      base, Reference.create_from_list attributes, annotation
  | _ -> Reference.create_from_list identifiers, Reference.create "", None


let set_local ({ annotation_store; _ } as resolution) ~reference ~annotation =
  {
    resolution with
    annotation_store =
      Map.set
        annotation_store
        ~key:reference
        ~data:(RefinementUnit.create () |> RefinementUnit.set_base ~base:annotation);
  }


let set_local_with_attributes ({ annotation_store; _ } as resolution) ~name ~annotation =
  let object_reference, attribute_path, base = partition_name resolution ~name in
  let set_base refinement_unit ~base =
    match RefinementUnit.base refinement_unit, base with
    | None, Some base -> RefinementUnit.set_base refinement_unit ~base
    | _ -> refinement_unit
  in
  {
    resolution with
    annotation_store =
      Map.set
        annotation_store
        ~key:object_reference
        ~data:
          ( Map.find annotation_store object_reference
          |> Option.value ~default:(RefinementUnit.create ())
          |> RefinementUnit.add_attribute_refinement ~reference:attribute_path ~base:annotation
          |> set_base ~base );
  }


let get_local ?(global_fallback = true) ~reference { annotation_store; global_resolution; _ } =
  match Map.find annotation_store reference with
  | Some result
    when global_fallback
         || not
              (result |> RefinementUnit.base >>| Annotation.is_global |> Option.value ~default:true)
    ->
      RefinementUnit.base result
  | _ when global_fallback ->
      let global = GlobalResolution.global global_resolution in
      Reference.delocalize reference |> global >>| Node.value
  | _ -> None


let get_local_with_attributes
    ?(global_fallback = true)
    ~name
    ({ annotation_store; global_resolution; _ } as resolution)
  =
  let object_reference, attribute_path, _ = partition_name resolution ~name in
  match Map.find annotation_store object_reference with
  | Some result
    when global_fallback
         || not
              ( result
              |> RefinementUnit.annotation ~reference:attribute_path
              >>| Annotation.is_global
              |> Option.value ~default:true ) ->
      RefinementUnit.annotation result ~reference:attribute_path
  | _ when global_fallback ->
      let global = GlobalResolution.global global_resolution in
      Reference.(combine object_reference attribute_path |> delocalize) |> global >>| Node.value
  | _ -> None


let unset_local ({ annotation_store; _ } as resolution) ~reference =
  { resolution with annotation_store = Map.remove annotation_store reference }


let add_type_variable ({ type_variables; _ } as resolution) ~variable =
  { resolution with type_variables = Type.Variable.Set.add type_variables variable }


let type_variable_exists { type_variables; _ } ~variable =
  Type.Variable.Set.mem type_variables variable


let all_type_variables_in_scope { type_variables; _ } = Type.Variable.Set.to_list type_variables

let annotation_store { annotation_store; _ } = annotation_store

let with_annotation_store resolution ~annotation_store = { resolution with annotation_store }

let parent { parent; _ } = parent

let with_parent resolution ~parent = { resolution with parent }

let is_consistent_with ({ global_resolution; _ } as resolution) =
  GlobalResolution.is_consistent_with global_resolution ~resolve:(resolve resolution)


let global_resolution { global_resolution; _ } = global_resolution
