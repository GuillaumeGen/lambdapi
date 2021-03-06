(** Interface to LSP *)

(* Lambdapi core *)
open Core

(** Abstract representation of a command (top-level item). *)
module Command : sig
  type t
  val equal : t -> t -> bool
  val get_pos : t -> Pos.popt
end

(** Abstract representation of a tactic (proof item). *)
module Tactic : sig
  type t
  val equal : t -> t -> bool
  val get_pos : t -> Pos.popt
end

(** Exception raised by [parse_text]. *)
exception Parse_error of Pos.pos * string

(** [parse_text fname contents] runs the parser on the string [contents] as if
    it were a file named [fname]. This function may raise [Parse_error]. *)
val parse_text : string -> string -> Command.t list

(** Representation of the state when at the toplevel. *)
type command_state

(** Representation of the state when in a proof. *)
type proof_state

(** [current_goals s] returns the list of open goals for proof state [s]. *)
val current_goals : proof_state -> Proof.Goal.t list

(** Result type of the [handle_command] function. *)
type command_result =
  | Cmd_OK    of command_state
  (** Command is done. *)
  | Cmd_Proof of proof_state * Tactic.t list * Pos.popt * Pos.popt
  (** Enter proof mode (positions are for statement and qed). *)
  | Cmd_Error of Pos.popt option * string
  (** Error report. *)

(** Result type of the [handle_tactic] function. *)
type tactic_result =
  | Tac_OK    of proof_state
  | Tac_Error of Pos.popt option * string

(** [initial_state path] returns a initial state for a signature having module
    path [path]. The resulting state can be used by [handle_command]. *)
val initial_state : Files.module_path -> command_state

(** [handle_command st cmd] evaluated the command [cmd] in state [st],  giving
    one of three possible results: the command is fully handled (corresponding
    to the [Cmd_OK] constructor,  the command starts a proof (corresponding to
    the [Cmd_Proof] constructor), or the command fails (corresponding  to  the
    [Cmd_Error] constuctor). *)
val handle_command : command_state -> Command.t -> command_result

(** [handle_tactic st tac] evaluated the tactic [tac] in state [st], returning
    a new proof state (with [Tac_OK]) or an error (with [Tac_Error]). *)
val handle_tactic : proof_state -> Tactic.t -> tactic_result

(** [end_proof st] finalises the proof which state is [st], returning a result
    at the command level for the whole theorem. This function should be called
    when all the tactics have been handled with [handle_tactic]. Note that the
    value returned by this function cannot be {!const:Cmd_Proof}. *)
val end_proof : proof_state -> command_result

(** [get_symbols st] returns all the symbols defined in the signature at state
    [st]. This can be used for displaying the type of symbols. *)
val get_symbols : command_state -> (Terms.sym * Pos.popt) Extra.StrMap.t
