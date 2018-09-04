(** Type-checking and inference. *)

open Extra
open Timed
open Console
open Terms
open Print
open Typing

(** Logging function for unification. *)
let log_solv = new_logger 's' "solv" "debugging information for unification"
let log_solv = log_solv.logger

(** Boolean saying whether user metavariables can be set or not. *)
let can_instantiate : bool ref = ref true

(** [instantiate m ts v] check whether [m] can be instantiated to
    solve the unification problem [m[ts] = v]. Actually make the
    instantiation if it is possible. *)
let instantiate : meta -> term array -> term -> bool = fun m ar v ->
  (!can_instantiate || internal m) && distinct_vars ar && not (occurs m v) &&
  let bv = Bindlib.bind_mvar (to_tvars ar) (lift v) in
  Bindlib.is_closed bv && (set_meta m (Bindlib.unbox bv); true)

(** [eq_vari t u] checks that [t] and [u] are both variables, and the they are
    pariwise equal. *)
let eq_vari : term -> term -> bool = fun t u ->
  match (unfold t, unfold u) with
  | (Vari(x), Vari(y)) -> Bindlib.eq_vars x y
  | (_      , _      ) -> false

(** Representation of a set of problems. *)
type problems =
  { to_solve  : conv_constrs
  (** List of unification problems that must be put in WHNF first. *)
  ; unsolved  : conv_constrs
  (** List of unsolved unification problems. *)
  ; recompute : bool
  (** Indicates whether unsolved problems should be rechecked. *) }

(** Empty problem. *)
let no_problems : problems =
  { to_solve  = []
  ; unsolved  = []
  ; recompute = false }

(** [solve p] tries to solve the unification problems of [p]. *)
let rec solve : problems -> conv_constrs = fun p ->
  match p.to_solve with
  | []       ->
     if p.unsolved = [] then []
     else if p.recompute then
       solve {no_problems with to_solve = p.unsolved}
     else p.unsolved
  | (t,u)::l -> solve_aux t u {p with to_solve = l}

(** [solve_aux t1 t2 p] tries to solve the unificaton problem
    [(t1,t2)]. Then, it continues with the remaining problems. *)
and solve_aux t1 t2 p : conv_constrs =
  let (h1, ts1) = Eval.whnf_stk t1 [] in
  let (h2, ts2) = Eval.whnf_stk t2 [] in
  if !log_enabled then
    begin
      let t1 = add_args h1 ts1 in
      let t2 = add_args h2 ts2 in
      log_solv "solve_aux [%a] [%a]" pp t1 pp t2;
    end;
  match h1, h2 with
  | Type, Type
  | Kind, Kind -> solve p
  (* We have [ts1=ts2=[]] since [t1] and [t2] are [Kind] or typable. *)

  | Vari x, Vari y when Bindlib.eq_vars x y && List.same_length ts1 ts2 ->
      let to_solve =
        let fn l t1 t2 = (Eval.to_lazy t1, Eval.to_lazy t2)::l in
        List.fold_left2 fn p.to_solve ts1 ts2
      in
      solve {p with to_solve}

  | Prod(a,f), Prod(b,g)
  (* We have [ts1=ts2=[]] since [t1] and [t2] are [Kind] or typable. *)
  | Abst(a,f), Abst(b,g) ->
  (* We have [ts1=ts2=[]] since [t1] and [t2] are in whnf. *)
     let (_,u,v) = Bindlib.unbind2 f g in
     let to_solve = (a,b) :: (u,v) :: p.to_solve in
     solve {p with to_solve}

  | Symb(s1), Symb(s2) when s1 == s2 && ts1 = [] && ts2 = [] ->
     solve p

  | Symb(s1), Symb(s2) when Sign.is_const s1 && Sign.is_const s2 ->
     if s1 == s2 && List.same_length ts1 ts2 then
      let to_solve =
        let fn l t1 t2 = (Eval.to_lazy t1, Eval.to_lazy t2)::l in
        List.fold_left2 fn p.to_solve ts1 ts2
       in
       solve {p with to_solve}
     else fatal_no_pos "[%a] and [%a] are not convertible." pp t1 pp t2

  | Meta(m1,a1), Meta(m2,a2)
    when m1 == m2 && ts1 = [] && ts2 = [] && Array.for_all2 eq_vari a1 a2 ->
     solve p

  | Meta(m,ts), _ when ts1 = [] && instantiate m ts t2 ->
      solve {p with recompute = true}
  | _, Meta(m,ts) when ts2 = [] && instantiate m ts t1 ->
      solve {p with recompute = true}

  | Meta(_,_), _
  | _, Meta(_,_) ->
      solve {p with unsolved = (t1,t2) :: p.unsolved}

  | Symb(s), _ when not (Sign.is_const s) ->
     if Eval.eq_modulo t1 t2 then solve p
     else solve {p with unsolved = (t1,t2) :: p.unsolved}

  | _, Symb(s) when not (Sign.is_const s) ->
     if Eval.eq_modulo t1 t2 then solve p
     else solve {p with unsolved = (t1,t2) :: p.unsolved}

  | (_        , _        ) ->
     fatal_no_pos "[%a] and [%a] are not convertible." pp t1 pp t2

(** [solve b p] sets [can_instantiate] to [b] and returns
    [Some(l)] if [solve p] returns [l], and [None] otherwise. *)
let solve : bool -> problems -> conv_constrs option = fun b p ->
  can_instantiate := b;
  try Some (solve p) with Fatal(_,m) ->
    if !log_enabled then log_solv (red "solve: %s.\n") m; None

let msg (a,b) =
  if !log_enabled then log_solv "Cannot solve [%a] ~ [%a]\n" pp a pp b

(** [check c t a] returns [true] iff [t] has type [a] in context [c]. *)
let check : Ctxt.t -> term -> term -> bool = fun c t a ->
  if !log_enabled then log_solv "check [%a] [%a]" pp t pp a;
  let to_solve = Typing.check c t a in
  let problems = {no_problems with to_solve} in
  match solve true problems with
  | Some l -> List.iter msg l; l = []
  | None   -> false

(** [check_with_constrs cs t a] returns [true] iff [t] has type
    [a] in context [c] and constraints [cs] without instantiating any
    user-defined metavariable. *)
let check_with_constr (cs:conv_constrs) (t:term) (a:term) : bool =
  if !log_enabled then log_solv "check_with_constr [%a] [%a]" pp t pp a;
  let to_solve = Typing.check Ctxt.empty t a in
  let problems = {no_problems with to_solve} in
  match solve false problems with
  | Some l -> let l = List.filter (fun x -> not (List.mem x cs)) l in
              List.iter msg l; l = []
  | None   -> false

(** [infer_constr c t] returns [Some (a,l)] where [l] is a list of
   unification problems for [a] to be the type of [t] in context [c],
   or [None]. *)
let infer_constr (c:Ctxt.t) (t:term) : (conv_constrs * term) option =
  if !log_enabled then log_solv "infer_constr [%a]" pp t;
  let (a, to_solve) = Typing.infer c t in
  let problems = {no_problems with to_solve} in
  match solve true problems with
  | Some(l) -> Some (l, a)
  | None    -> None

(** [infer c t] returns [Some u] if [t] has type [u] in context [c],
    and [None] otherwise. *)
let infer (c:Ctxt.t) (t:term) : term option =
  match infer_constr c t with
  | Some ([], a) -> Some a
  | Some (l, _) -> List.iter msg l; None
  | None -> None

(** [sort_type c t] returns [true] iff [t] has type a sort in context [c]. *)
let sort_type (c:Ctxt.t) (t:term) : unit =
  if !log_enabled then log_solv "sort_type [%a]" pp t;
  match infer c t with
  | Some(a) ->
      begin
        match unfold a with
        | Type
        | Kind -> ()
        | a    -> fatal_no_pos "[%a] has type [%a] (not a sort)." pp t pp a
      end
  | None    -> fatal_no_pos "Unable to infer a sort for [%a]." pp t
