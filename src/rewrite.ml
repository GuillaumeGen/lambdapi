(** Implementation of the REWRITE tactic. *)

open Timed
open Terms
open Print
open Console
open Proofs
open Solve

(** Logging function for the rewrite tactic. *)
let log_rewr = new_logger 'w' "rewr" "informations for the rewrite tactic"
let log_rewr = log_rewr.logger

(** Rewrite pattern. *)
type rw_patt =
  | RW_Term           of term
  | RW_InTerm         of term
  | RW_InIdInTerm     of (term, term) Bindlib.binder
  | RW_IdInTerm       of (term, term) Bindlib.binder
  | RW_TermInIdInTerm of term * (term, term) Bindlib.binder
  | RW_TermAsIdInTerm of term * (term, term) Bindlib.binder

(** [break_prod] is given a nested product term (potentially with no products)
    and it unbinds all the the quantified variables. It returns the  term with
    the free variables and the list of variables that  were  unbound, so  that
    they can be bound to the term and substituted with the right terms. *)
let break_prod : term -> term * tvar list = fun t ->
  let rec aux : term -> tvar list -> term * tvar list = fun t vs ->
    match t with
    | Prod(_,b) -> let (v,b) = Bindlib.unbind b in aux b (v::vs)
    | _         -> (t, List.rev vs)
  in aux t []

type pattern = tvar array * term

let match_pattern : pattern -> term -> term array option = fun (xs,p) t ->
  let ts = Array.map (fun _ -> TRef(ref None)) xs in
  let p = Bindlib.msubst (Bindlib.unbox (Bindlib.bind_mvar xs (lift p))) ts in
  if Terms.eq p t then Some(Array.map unfold ts) else None

(** [find_sub] is given two terms and finds the first instance of  the  second
    term in the first, if one exists, and returns the substitution giving rise
    to this instance or an empty substitution otherwise. *)
let find_sub : term -> term -> tvar array -> term array = fun g l vars ->
  let rec find_sub_aux : term -> term array option = fun g ->
    match match_pattern (vars,l) g with
    | Some sub -> Some sub
    | None     ->
      begin
          match g with
          | Appl(x,y) ->
             begin
              match find_sub_aux x with
              | Some sub -> Some sub
              | None     -> find_sub_aux y
             end
          | _ -> None
      end
  in
  match find_sub_aux g with
  | Some sub -> sub
  | None     -> Array.map Terms.mkfree vars

(** [bind_match t1 t2] produces a binder that abstracts away all the occurence
    of the term [t1] in the term [t2].  We require that [t2] does not  contain
    products, abstraction, metavariables, or other awkward terms. *)
let bind_match : term -> term -> (term, term) Bindlib.binder = fun t1 t2 ->
  let x = Bindlib.new_var mkfree "X" in
  (* NOTE we lift to the bindbox while matching (for efficiency). *)
  let rec lift_subst : term -> tbox = fun t ->
    if Terms.eq t1 t then _Vari x else
    match unfold t with
    | Vari(y)     -> _Vari y
    | Type        -> _Type
    | Kind        -> _Kind
    | Symb(s)     -> _Symb s
    | Appl(t,u)   -> _Appl (lift_subst t) (lift_subst u)
    (* For now, we fail on products, abstractions and metavariables. *)
    | Prod(_)     -> fatal_no_pos "Cannot rewrite under products."
    | Abst(_)     -> fatal_no_pos "Cannot rewrite under abstractions."
    | Meta(_)     -> fatal_no_pos "Cannot rewrite metavariables."
    (* Forbidden cases. *)
    | Patt(_,_,_) -> assert false
    | TEnv(_,_)   -> assert false
    | Lazy(_)     -> assert false
    | Wild        -> assert false
    | TRef(_)     -> assert false
  in
  Bindlib.unbox (Bindlib.bind_var x (lift_subst t2))

(** [handle_rewrite t] rewrites according to the equality proved by [t] in the
    current goal. The term [t] should have a type corresponding to an equality
    (without any quantifier for now). All instances of the LHS are replaced by
    the RHS in the obtained goal. *)
let handle_rewrite : term -> unit = fun t ->
  (* Obtain the required symbols from the current signature. *)
  (* FIXME use a parametric notion of equality. *)
  let sign = Sign.current_sign () in
  let find_sym : string -> sym = fun name ->
    try Sign.find sign name with Not_found ->
    fatal_no_pos "Current signature does not define symbol [%s]." name
  in
  let sign_P  = find_sym "P"  in
  let sign_T  = find_sym "T"  in
  let sign_eq = find_sym "eq" in
  let sign_eqind = find_sym "eqind" in

  (* Get the focused goal, and related data. *)
  let thm = current_theorem () in
  let (g, gs) =
    match thm.t_goals with
    | []    -> fatal_no_pos "No remaining goals..."
    | g::gs -> (g, gs)
  in

  (* Infer the type of [t] (the argument given to the tactic). *)
  let g_ctxt = Ctxt.of_env g.g_hyps in
  let t_type =
    match Solve.infer g_ctxt t with
    | Some(a) -> a
    | None    ->
        fatal_no_pos "Cannot infer the type of [%a] (given to rewrite)." pp t
  in
  (* Check that the type of [t] is of the form “P (Eq a l r)”. and return the
   * parameters. *)
  let (t_type, vars) = break_prod t_type in
  let (a, l, r)  =
    match get_args t_type with
    | (p,[eq]) when is_symb sign_P p ->
        begin
          match get_args eq with
          | (e,[a;l;r]) when is_symb sign_eq e -> (a, l, r)
          | _                                  ->
              fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
        end
    | _                              ->
        fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
  in

  let t_args = add_args t (List.map mkfree vars) in
  let triple = Bindlib.box_triple (lift t_args) (lift l) (lift r)  in
  let bound = Bindlib.unbox (Bindlib.bind_mvar (Array.of_list vars) triple) in

  (* Extract the term from the goal type (get “t” from “P t”). *)
  let g_term =
    match get_args g.g_type with
    | (p, [t]) when is_symb sign_P p -> t
    | _                              ->
        fatal_no_pos "Rewrite expects a goal of the form “P t” (found [%a])."
          pp g.g_type
  in

  let sigma = find_sub g_term l (Array.of_list vars) in
  let (t,l,r) = Bindlib.msubst bound sigma in
  let pred_bind = bind_match l g_term in
  let pred = Abst(Appl(Symb(sign_T), a), pred_bind) in

  (* Construct the new goal and its type. *)
  let goal_type = Appl(Symb(sign_P), Bindlib.subst pred_bind r) in
  let goal_term = Ctxt.make_meta g_ctxt goal_type in
  let new_goal =
    match goal_term with
    | Meta(m,_) -> m
    | _         -> assert false (* Cannot happen. *)
  in

  (* Build the final term produced by the tactic, and check its type. *)
  let term = add_args (Symb(sign_eqind)) [a; l; r; t; pred; goal_term] in
  if not (Solve.check g_ctxt term g.g_type) then
    begin
      match Solve.infer g_ctxt term with
      | Some(a) ->
          fatal_no_pos "The term produced by rewrite has type [%a], not [%a]."
            pp (Eval.snf a) pp g.g_type
      | None    ->
          fatal_no_pos "The term [%a] produced by rewrite is not typable."
            pp term
    end;

  (* Instantiate the current goal. *)
  let meta_env = Array.map Bindlib.unbox (Env.vars_of_env g.g_hyps)  in
  let b = Bindlib.bind_mvar (to_tvars meta_env) (lift term) in
  g.g_meta.meta_value := Some(Bindlib.unbox b);

  (* Update current theorem with the newly created goal. *)
  let new_g = {g_meta = new_goal; g_hyps = g.g_hyps; g_type = goal_type} in
  theorem := Some({thm with t_goals = new_g :: gs});

  log_rewr "Rewriting with:";
  log_rewr "  goal           = [%a]" pp g.g_type;
  log_rewr "  equality proof = [%a]" pp t;
  log_rewr "  equality type  = [%a]" pp t_type;
  log_rewr "  equality LHS   = [%a]" pp l;
  log_rewr "  equality RHS   = [%a]" pp r;
  log_rewr "  pred           = [%a]" pp pred;
  log_rewr "  new goal       = [%a]" pp goal_type;
  log_rewr "  produced term  = [%a]" pp term

(** [handle_rewrite s] rewrites according to the specification [s]. *)
let handle_rewrite : rw_patt option -> term -> unit = fun s t ->
  match s with
  | None                         -> handle_rewrite t
  | Some(RW_Term(_)            ) -> wrn "NOT IMPLEMENTED" (* TODO *)
  | Some(RW_InTerm(_)          ) -> wrn "NOT IMPLEMENTED" (* TODO *)
  | Some(RW_InIdInTerm(_)      ) -> wrn "NOT IMPLEMENTED" (* TODO *)
  | Some(RW_IdInTerm(_)        ) -> wrn "NOT IMPLEMENTED" (* TODO *)
  | Some(RW_TermInIdInTerm(_,_)) -> wrn "NOT IMPLEMENTED" (* TODO *)
  | Some(RW_TermAsIdInTerm(_,_)) -> wrn "NOT IMPLEMENTED" (* TODO *)
