(**** Colorful error / warning messages *************************************)

(* Format transformers (colors). *)
let red fmt = "\027[31m" ^^ fmt ^^ "\027[0m%!"
let gre fmt = "\027[32m" ^^ fmt ^^ "\027[0m%!"
let yel fmt = "\027[33m" ^^ fmt ^^ "\027[0m%!"
let blu fmt = "\027[34m" ^^ fmt ^^ "\027[0m%!"
let mag fmt = "\027[35m" ^^ fmt ^^ "\027[0m%!"
let cya fmt = "\027[36m" ^^ fmt ^^ "\027[0m%!"

(* [wrn fmt] prints a yellow warning message with [Printf] format [fmt].  Note
   that the output buffer is flushed by the function. *)
let wrn : ('a, out_channel, unit) format -> 'a =
  fun fmt -> Printf.eprintf (yel fmt)

(* [err fmt] prints a red error message with [Printf] format [fmt].  Note that
   the output buffer is flushed by the function. *)
let err : ('a, out_channel, unit) format -> 'a =
  fun fmt -> Printf.eprintf (red fmt)

(* [fatal fmt] is like [err fmt], but it aborts the program with [exit 1]. *)
let fatal : ('a, out_channel, unit, unit, unit, 'b) format6 -> 'a =
  fun fmt -> Printf.kfprintf (fun _ -> exit 1) stderr (red fmt)

(**** Debugging messages management *****************************************)

(* Various debugging / message flags. *)
let quiet       = ref false
let debug       = ref false
let debug_eval  = ref false
let debug_infer = ref false
let debug_patt  = ref false

(* [debug_enabled ()] indicates whether any debugging flag is enabled. *)
let debug_enabled : unit -> bool = fun () ->
  !debug || !debug_eval || !debug_infer || !debug_patt

(* [set_debug str] enables debugging flags according to [str]. *)
let set_debug : string -> unit =
  let enable c =
    match c with
    | 'a' -> debug       := true
    | 'e' -> debug_eval  := true
    | 'i' -> debug_infer := true
    | 'p' -> debug_patt  := true
    | _   -> wrn "Unknown debug flag %C\n" c
  in
  String.iter enable

(* [log name fmt] prints a message in the log with the [Printf] format  [fmt].
   The message is identified with the name (or flag) [name],  and coloured  in
   cyan. Note that the  output buffer is flushed by the  function,  and that a
   newline character ['\n'] is appended to the output. *)
let log : string -> ('a, out_channel, unit) format -> 'a =
  fun name fmt -> Printf.eprintf ((cya "[%s] ") ^^ fmt ^^ "\n%!") name

(* [out fmt] prints an output message with the [Printf] format [fmt]. Note the
   output buffer is flushed by the function, and that the message is displayed
   in magenta whenever a debugging mode is enabled. *)
let out : ('a, out_channel, unit) format -> 'a =
  fun fmt ->
    let fmt = if debug_enabled () then mag fmt else fmt ^^ "%!" in
    if !quiet then Printf.ifprintf stdout fmt else Printf.printf fmt

(**** Abstract syntax of the language ***************************************)

(* Type of terms (and types). *)
type term =
  (* Free variable. *)
  | Vari of term Bindlib.var
  (* "Type" constant. *)
  | Type
  (* "Kind" constant. *)
  | Kind
  (* Symbol (static or definable). *)
  | Symb of symbol
  (* Dependent product. *)
  | Prod of term * (term, term) Bindlib.binder
  (* Abstraction. *)
  | Abst of term * (term, term) Bindlib.binder
  (* Application. *)
  | Appl of bool * term * term
  (* Unification variable. *)
  | Unif of term option ref
  (* Pattern variable. *)
  | PVar of term option ref

(* NOTE: the boolean in application nodes is set to true for rigid terms. They
   are marked as such during evaluation for terms having a  static  symbol  at
   their head. This helps avoiding useless copies. *)

(* Representation of a reduction rule.  The [arity] corresponds to the minimal
   number of arguments that are required for the rule to apply. The definition
   of a rule is split into a left-hand side [lhs] and a right-and sides [rhs].
   The variables of the context are bound on both sides of the rule. Note that
   the left-hand side is given as a list of arguments for the definable symbol
   on which the rule is defined. The symbol is not given in the type of rules,
   as rules will be stored in the definition of symbols. *)
 and rule =
  { lhs   : (term, term list) Bindlib.mbinder
  ; rhs   : (term, term) Bindlib.mbinder
  ; arity : int }

(* NOTE: to check if a rule [r] applies on a term [t] using our representation
   is really easy.  First,  one should substitute the [r.lhs] binder (with the
   [Bindlib.msubst] function) using an array of pattern variables  (which size
   should be [Bindlib.mbinder_arity r.lhs]) to obtain a term list [lhs]. Then,
   to check if [r] applies on a the term [t] (which head should be the symbol)
   one should test equality (with unification) between [lhs] and the arguments
   of [t]. If they are equal then the rule applies and the term obtained after
   the application is computed by substituting [r.rhs] with the same array  of
   pattern variables that was used for [l.rhs] (at this point, all the pattern
   variables should have been instanciated by the equality test). If [lhs] and
   the arguments of [t] are not equal, then the rule does not apply. *)

(**** Symbols (static or definable) *****************************************)

(* Representation of a static symbol. *)
and sym =
  { sym_name  : string
  ; sym_type  : term
  ; sym_path  : string list }

(* Representation of a definable symbol,  which carries its reduction rules in
   a reference. It should be updated to add new rules. *)
and def =
  { def_name  : string
  ; def_type  : term
  ; def_rules : rule list ref
  ; def_path  : string list }

(* NOTE: the [path] that is stored in a symbol corresponds to a "module path".
   The path [["a"; "b"; "f"]] corresponds to file ["a/b/f.lp"].  It is printed
   and read in the source code as ["dira::dirb::file"]. *)

(* Representation of a (static or definable) symbol. *)
and symbol = Sym of sym | Def of def

(* [symbol_type s] returns the type of the given symbol [s]. *)
let symbol_type : symbol -> term =
  fun s ->
    match s with
    | Sym(sym) -> sym.sym_type
    | Def(def) -> def.def_type

(* Reference containing the module path of the current file. It is useful when
   printing symbol names to avoid giving the full path for local symbols. *)
let current_module : string list ref = ref []

(* [symbol_name s] returns the full name of the given symbol [s] (including if
   the symbol does not come from the current module. *)
let symbol_name : symbol -> string = fun s ->
  let (path, name) =
    match s with
    | Sym(sym) -> (sym.sym_path, sym.sym_name)
    | Def(def) -> (def.def_path, def.def_name)
  in
  if path = !current_module then name
  else String.concat "::" (path @ [name])

(**** Signature *************************************************************)

module Sign =
  struct
    (* Representation of a signature (roughly, a set of symbols). *)
    type t = { symbols : (string, symbol) Hashtbl.t ; path : string list }

    (* [create path] creates an empty signature with module path [path]. *)
    let create : string list -> t =
      fun path -> { path ; symbols = Hashtbl.create 37 }

    (* [new_static sign name a] creates a new static symbol named [name]  with
       type [a] the signature [sign]. *)
    let new_static : t -> string -> term -> unit =
      fun sign sym_name sym_type ->
        if Hashtbl.mem sign.symbols sym_name then
          wrn "Redefinition of %s.\n" sym_name;
        let sym_path = sign.path in
        let sym = { sym_name ; sym_type ; sym_path } in
        Hashtbl.add sign.symbols sym_name (Sym(sym))

    (* [new_definable sign name a] creates a new definable symbol (without any
       reduction rule) named [name] with type [a] the signature [sign]. *)
    let new_definable : t -> string -> term -> unit =
      fun sign def_name def_type ->
        if Hashtbl.mem sign.symbols def_name then
          wrn "Redefinition of %s.\n" def_name;
        let def_path = sign.path in
        let def_rules = ref [] in
        let def = { def_name ; def_type ; def_rules ; def_path } in
        Hashtbl.add sign.symbols def_name (Def(def))

    (* [find sign name] looks for a symbol named [name] in signature [sign] if
       there is one. The exception [Not_found] is raised if there is none. *)
    let find : t -> string -> symbol =
      fun sign name -> Hashtbl.find sign.symbols name

    (* [write sign file] writes the signature [sign] to the file [fname]. *)
    let write : t -> string -> unit =
      fun sign fname ->
        let oc = open_out fname in
        Marshal.to_channel oc sign [Marshal.Closures];
        close_out oc

    (* [read fname] reads a signature from the file [fname]. *)
    let read : string -> t =
      fun fname ->
        let ic = open_in fname in
        let sign = Marshal.from_channel ic in
        close_in ic; sign
  end

(**** Typing context ********************************************************)

module Ctxt =
  struct
    (* Representation of a typing context, associating a [term] (or type),  to
       the free variables. *)
    type t = (term Bindlib.var * term) list

    (* [empty] is the empty context. *)
    let empty : t = []

    (* [add x a ctx] maps the variable [x] to the type [a] in [ctx]. *)
    let add : term Bindlib.var -> term -> t -> t =
      fun x a ctx -> (x,a)::ctx

    (* [find x ctx] returns the type of variable [x] in the context [ctx] when
       the variable appears inthe context. [Not_found] is raised otherwise. *)
    let find : term Bindlib.var -> t -> term = fun x ctx ->
      snd (List.find (fun (y,_) -> Bindlib.eq_vars x y) ctx)
  end

(**** Unification variables management **************************************)

(* [unfold t] unfolds the toplevel unification / pattern variables in [t]. *)
let rec unfold : term -> term = fun t ->
  match t with
  | Unif({contents = Some(t)}) -> unfold t
  | PVar({contents = Some(t)}) -> unfold t
  | _                          -> t

(* [occurs r t] checks whether the unification variable [r] occurs in [t]. *)
let rec occurs : term option ref -> term -> bool = fun r t ->
  match unfold t with
  | Prod(a,b)   -> occurs r a || occurs r (Bindlib.subst b Kind)
  | Abst(a,t)   -> occurs r a || occurs r (Bindlib.subst t Kind)
  | Appl(n,t,u) -> occurs r t || occurs r u
  | Unif(u)     -> u == r
  | Type        -> false
  | Kind        -> false
  | Vari(_)     -> false
  | Symb(_)     -> false
  | PVar(_)     -> true

(* NOTE: pattern variable prevent unification to guarantee that they cannot be
   absorbed by unification varialbes (and do not escape rewriting code). *)

(* [unify r t] tries to unify [r] with [t],  and returns a boolean to indicate
   whether it succeeded or not. *)
let unify : term option ref -> term -> bool =
  fun r a ->
    assert (!r = None);
    not (occurs r a) && (r := Some(a); true)

(**** Smart constructors and other Bindlib-related things *******************)

(* Short names for variables and boxed terms. *)
type tvar = term Bindlib.var
type tbox = term Bindlib.bindbox

(* Injection of [Bindlib] variables into terms. *)
let mkfree : tvar -> term =
  fun x -> Vari(x)

(* [_Vari x] injects the free variable [x] into the bindbox, so that it may be
   available for binding. *)
let _Vari : tvar -> tbox =
  Bindlib.box_of_var

(* [_Type] injects the constructor [Type] in the [bindbox] type. *)
let _Type : tbox = Bindlib.box Type

(* [_Kind] injects the constructor [Kind] in the [bindbox] type. *)
let _Kind : tbox = Bindlib.box Kind

(* [_Symb s] injects the constructor [Symb(s)] in the [bindbox] type. *)
let _Symb : symbol -> tbox =
  fun s -> Bindlib.box (Symb(s))

(* [_Symb_find sign name] finds the symbol [s] with the given [name] in [sign]
   and injects the constructor [Symb(s)] into the [bindbox] type.  [Not_found]
   is raised if no such symbol is found. *)
let _Symb_find : Sign.t -> string -> tbox =
  fun sign n -> _Symb (Sign.find sign n)

(* [_Appl t u] lifts the application of [t] and [u] to the [bindbox] type. *)
let _Appl : tbox -> tbox -> tbox =
  Bindlib.box_apply2 (fun t u -> Appl(false,t,u))

(* [_Prod a x f] lifts a dependent product node to the [bindbox] type, given a
   boxed term [a] (the type of the domain),  a prefered name [x] for the bound
   variable, and function [f] to build the [binder] (codomain). *)
let _Prod : tbox -> string -> (tvar -> tbox) -> tbox =
  fun a x f ->
    let b = Bindlib.vbind mkfree x f in
    Bindlib.box_apply2 (fun a b -> Prod(a,b)) a b

(* [_Abst a x f] lifts an abstraction node to the [bindbox] type, given a term
   [a] (which is the type of the bound variable),  the prefered name [x] to be
   used for the bound variable, and the function [f] to build the [binder]. *)
let _Abst : tbox -> string -> (tvar -> tbox) -> tbox =
  fun a x f ->
    let b = Bindlib.vbind mkfree x f in
    Bindlib.box_apply2 (fun a b -> Abst(a,b)) a b

(* [lift t] lifts a [term] [t] to the [bindbox] type,  thus gathering its free
   variables, making them available for binding.  At the same time,  the names
   of the bound variables are automatically updated by [Bindlib]. *)
let rec lift : term -> tbox = fun t ->
  let t = unfold t in
  match t with
  | Vari(x)     -> _Vari x
  | Type        -> _Type
  | Kind        -> _Kind
  | Symb(s)     -> _Symb s
  | Prod(a,b)   -> _Prod (lift a) (Bindlib.binder_name b)
                     (fun x -> lift (Bindlib.subst b (mkfree x)))
  | Abst(a,t)   -> _Abst (lift a) (Bindlib.binder_name t)
                     (fun x -> lift (Bindlib.subst t (mkfree x)))
  | Appl(_,t,u) -> _Appl (lift t) (lift u)
  | Unif(_)     -> Bindlib.box t (* Variable not instanciated. *)
  | PVar(_)     -> Bindlib.box t (* Variable not instanciated. *)

(* [update_names t] updates the names of the bound variables of [t] to prevent
   "visual capture" while printing. Note that with [Bindlib],  real capture is
   not possible as binders are represented as OCaml function (HOAS). *)
let update_names : term -> term = fun t -> Bindlib.unbox (lift t)

(* [get_args t] returns a tuple [(hd,args)] where [hd] if the head of the term
   and [args] its arguments. *)
let get_args : term -> term * term list = fun t ->
  let rec get acc t =
    match unfold t with
    | Appl(_,t,u) -> get (u::acc) t
    | t           -> (t, acc)
  in get [] t

(* [add_args ~rigid hd args] builds the application of a term [hd] to the list
   of its arguments [args] (this is the inverse of [get_args]).  Note that the
   optional [rigid] argument ([false] by default) can be used to mark as rigid
   terms whose head are static symbol, to avoid copying them repeatedly. *)
let add_args : ?rigid:bool -> term -> term list -> term =
  fun ?(rigid=false) t args ->
    let rec add_args t args =
      match args with
      | []      -> t
      | u::args -> add_args (Appl(rigid,t,u)) args
    in add_args t args

(**** Printing functions (should come early for debuging) *******************)

(* [print_term oc t] pretty-prints the term [t] to the channel [oc]. *)
let print_term : out_channel -> term -> unit = fun oc t ->
  let pstring = output_string oc in
  let pformat fmt = Printf.fprintf oc fmt in
  let name = Bindlib.name_of in
  let rec print (p : [`Func | `Appl | `Atom]) oc t =
    let t = unfold t in
    match (t, p) with
    (* Atoms are printed inconditonally. *)
    | (Vari(x)  , _    )   -> pstring (name x)
    | (Type     , _    )   -> pstring "Type"
    | (Kind     , _    )   -> pstring "Kind"
    | (Symb(s)  , _    )   -> pstring (symbol_name s)
    | (Unif(_)  , _    )   -> pstring "?"
    | (PVar(_)  , _    )   -> pstring "?"
    (* Applications are printed when priority is above [`Appl]. *)
    | (Appl(_,t,u), `Appl)
    | (Appl(_,t,u), `Func) -> pformat "%a %a" (print `Appl) t (print `Atom) u
    (* Abstractions and products are only printed at priority [`Func]. *)
    | (Abst(a,t), `Func)   ->
        let (x,t) = Bindlib.unbind mkfree t in
        pformat "λ%s:%a.%a" (name x) (print `Func) a (print `Func) t
    | (Prod(a,b), `Func)   ->
        let (x,c) = Bindlib.unbind mkfree b in
        let x = if Bindlib.binder_occur b then (name x) ^ ":" else "" in
        pformat "%s%a ⇒ %a" x (print `Appl) a (print `Func) c
    (* Anything else needs parentheses. *)
    | (_        , _    )   -> pformat "(%a)" (print `Func) t
  in
  print `Func oc (update_names t)

(* [print_ctxt oc ctx] pretty-prints the context [ctx] to the channel [oc]. *)
let print_ctxt : out_channel -> Ctxt.t -> unit = fun oc ctx ->
  let pstring = output_string oc in
  let pformat fmt = Printf.fprintf oc fmt in
  let name = Bindlib.name_of in
  let rec print oc ls =
    match ls with
    | []          -> pstring "∅"
    | [(x,a)]     -> pformat "%s : %a" (name x) print_term a
    | (x,a)::ctx  -> pformat "%a, %s : %a" print ctx (name x) print_term a
  in print oc ctx

let print_rule : out_channel -> def * rule -> unit = fun oc (def,rule) ->
  let pformat fmt = Printf.fprintf oc fmt in
  let (xs,lhs) = Bindlib.unmbind mkfree rule.lhs in
  let lhs = add_args (Symb(Def def)) lhs in
  let rhs = Bindlib.msubst rule.rhs (Array.map mkfree xs) in
  pformat "%a → %a" print_term lhs print_term rhs

(**** Strict equality (no conversion) with unification **********************)

(* Short name for the type of an equality function. *)
type 'a eq = 'a -> 'a -> bool

(* [eq_binder eq b1 b2] tests the equality of two binders by substituting them
   with the same free variable, and testing the equality of the obtained terms
   with the [eq] function. *)
let eq_binder : term eq -> (term, term) Bindlib.binder eq =
  fun eq f g -> f == g ||
    let x = mkfree (Bindlib.new_var mkfree "_eq_binder_") in
    eq (Bindlib.subst f x) (Bindlib.subst g x)

(* [eq t u] tests the equality of the terms [t] and [u]. Pattern variables may
   be instantiated in the process. *)
let eq : ?rewrite: bool -> term -> term -> bool = fun ?(rewrite=false) a b ->
  if !debug then log "equa" "%a =!= %a" print_term a print_term b;
  let rec eq a b = a == b ||
    match (unfold a, unfold b) with
    | (Vari(x)      , Vari(y)      ) -> Bindlib.eq_vars x y
    | (Type         , Type         ) -> true
    | (Kind         , Kind         ) -> true
    | (Symb(Sym(sa)), Symb(Sym(sb))) -> sa == sb
    | (Symb(Def(sa)), Symb(Def(sb))) -> sa == sb
    | (Prod(a,f)    , Prod(b,g)    ) -> eq a b && eq_binder eq f g
    | (Abst(a,f)    , Abst(b,g)    ) -> eq a b && eq_binder eq f g
    | (Appl(_,t,u)  , Appl(_,f,g)  ) -> eq t f && eq u g
    | (Unif(_)      , _            )
    | (_            , Unif(_)      ) when rewrite -> assert false
    | (_            , PVar(_)      ) -> assert false
    | (PVar(r)      , b            ) -> r := Some b; true
    | (Unif(r1)     , Unif(r2)     ) when r1 == r2 -> true
    | (Unif(r)      , b            ) -> unify r b
    | (a            , Unif(r)      ) -> unify r a
    | (_            , _            ) -> false
  in
  let res = eq a b in
  if !debug then
    begin
      let c = if res then gre else red in
      log "equa" (c "%a =!= %a") print_term a print_term b;
    end;
  res

(* [eval t]: returns a weak head normal form of [t].  Note that some arguments
   are evaluated if they might be used to allow the application of a rewriting
   rule. As their evaluation is kept, so this function does more normalisation
   that the usual weak head normalisation. *)
let rec eval : term -> term = fun t ->
  if !debug_eval then log "eval" "evaluating %a" print_term t;
  (* eval_aux avaluates a term with a stack of arguments *)
  let rec eval_aux t stk =
    let t = unfold t in
    match (t, stk) with
    (* Push. *)
    | (Appl(n,f,u) , stk    ) ->
       (* If the term was already marked as rigid by previous eval, no
          need to inspect it *)
       if n then add_args ~rigid:true t stk (* rigid!*)
       else eval_aux f (eval_aux u [] :: stk)
    (* Beta. *)
    | (Abst(_,f)   , v::stk ) -> eval_aux (Bindlib.subst f v) stk
    (* Try to rewrite. *)
    | (Symb(Def(s)), stk    ) ->
        begin
          let nb_args = List.length stk in
          (*  Application  of one  rule:  if  the  rule applies,  if  returns
             ([rhs,stk]::ts) where [rhs] is the  instanciated rhs of the rule
             and [stk] are the arguments unused in the stack.   It returns ts
             unchanged is the rule does not apply. *)
          let match_term ts rule =
            if rule.arity > nb_args then ts else
            (* substitute the [lhs] of the rule with pattern variables *)
            let ar = Bindlib.mbinder_arity rule.lhs in
            let uvars = Array.init ar (fun _ -> PVar(ref None)) in
            let l = Bindlib.msubst rule.lhs uvars in
            if !debug_eval then log "eval" "RULE %a" print_rule (s,rule);
            (* match each argument of the lhs with the terms in the stack.
               returns the pair with the rhs of the rule and the unused
               part of the stack *)
            let rec match_args l stk =
              match (l, stk) with
              | ([]  , stk   ) ->
                 let r = Bindlib.msubst rule.rhs uvars in
                 (r, stk)::ts
              | (t::l, v::stk) ->
                 if eq ~rewrite:true t v then match_args l stk else ts
              | (_, _     ) ->
                 assert false
            in
            match_args l stk
          in
          (** We try to apply each rule *)
          let ts = List.fold_left match_term [] !(s.def_rules) in
          if !debug_eval then
            begin
              let nb = List.length ts in
              if nb > 1 then wrn "%i rules apply...\n%!" nb
            end;
          match ts with
          | []         -> add_args t stk (** no rule, we are finished *)
          | (t,stk)::_ -> eval_aux t stk (** continue evaluation *)
        end
    (* In head normal form, marking the rigid case *)
    | (Symb(Sym _), stk    ) -> add_args ~rigid:true t stk
    | (t          , stk    ) -> add_args t stk
  in
  let u = eval_aux t [] in
  if !debug_eval then log "eval" "produced %a" print_term u; u

(**** TODO cleaning and comments from here on *******************************)

(* Equality *)
let eq_modulo : term -> term -> bool = fun a b ->
  if !debug then log "equa" "%a == %a" print_term a print_term b;
  let rec get_head acc t =
    match unfold t with
    | Appl(_,t,u) -> get_head (u::acc) t
    | t           -> (t, acc)
  in
  let rec eq_mod a b = eq a b ||
    let a = eval a in
    let b = eval b in
    eq a b ||
    let (ha, argsa) = get_head [] a in
    let (hb, argsb) = get_head [] b in
    let rigid = ref true in
    begin
      match (ha, hb) with
      | (Vari(x)      , Vari(y)      ) -> Bindlib.eq_vars x y
      | (Type         , Type         ) -> true
      | (Kind         , Kind         ) -> true
      | (Symb(Sym(sa)), Symb(Sym(sb))) -> rigid := false; sa == sb
      | (Symb(Def(sa)), Symb(Def(sb))) -> sa == sb
      | (Prod(a,f)    , Prod(b,g)    ) -> eq_mod a b && eq_binder eq_mod f g
      | (Abst(a,f)    , Abst(b,g)    ) -> eq_mod a b && eq_binder eq_mod f g
      | (Appl(_)      , _            ) -> assert false
      | (_            , Appl(_)      ) -> assert false
      | (Unif(r1)     , Unif(r2)     ) when r1 == r2 -> true
      | (Unif(r)      , b            ) -> unify r b
      | (a            , Unif(r)      ) -> unify r a
      | (PVar(_)      , _            ) -> assert false
      | (_            , PVar(_)      ) -> assert false
      | (_            , _            ) -> false
    end &&
    try List.for_all2 (if !rigid then eq ~rewrite:false else eq_mod) argsa argsb
    with Invalid_argument(_) -> false
  in
  let res = eq_mod a b in
  if !debug then
    begin
      let c = if res then gre else red in
      log "equa" (c "%a == %a") print_term a print_term b;
    end;
  res

type constrs = (term * term) list

let constraints = ref None
let add_constraint : term -> term -> bool = fun a b ->
  match !constraints with
  | None    -> false
  | Some cs -> let c = (eval a, eval b) in
               constraints := Some (c :: cs); true

(* Judgements *)
let rec infer : Sign.t -> Ctxt.t -> term -> term = fun sign ctx t ->
  let rec infer ctx t =
    if !debug_infer then
      log "INFR" "%a ⊢ %a : ?" print_ctxt ctx print_term t;
    let a =
      match unfold t with
      | Vari(x)   -> Ctxt.find x ctx
      | Type      -> Kind
      | Kind      -> err "Kind has not type...\n";
                     raise Not_found
      | Symb(s)   -> symbol_type s
      | Prod(a,b) -> let (x,bx) = Bindlib.unbind mkfree b in
                     begin
                       match infer (Ctxt.add x a ctx) bx with
                       | Kind -> Kind
                       | Type -> Type
                       | _    ->
                           err "Expected Type / Kind for [%a]...\n"
                             print_term bx;
                           raise Not_found
                     end
      | Abst(a,t) -> let (x,tx) = Bindlib.unbind mkfree t in
                     let b = infer (Ctxt.add x a ctx) tx in
                     Prod(a, Bindlib.unbox (Bindlib.bind_var x (lift b)))
      | Appl(_,t,u) -> begin
                       match unfold (infer ctx t) with
                       | Prod(a,b) ->
                           if has_type sign ctx u a then Bindlib.subst b u
                           else
                             begin
                               err "Cannot show [%a : %a]...\n"
                                 print_term u print_term a;
                               raise Not_found
                             end
                       | a         ->
                           err "Product expected for [%a], found [%a]...\n"
                             print_term t print_term a;
                           raise Not_found
                     end
      | Unif(_)   -> assert false
      | PVar(_)   -> assert false
    in
    if !debug_infer then
      log "INFR" "%a ⊢ %a : %a" print_ctxt ctx print_term t print_term a;
    eval a
  in
  if !debug then
    log "infr" "%a ⊢ %a : ?" print_ctxt ctx print_term t;
  let a = infer ctx t in
  if !debug then
    log "infr" "%a ⊢ %a : %a" print_ctxt ctx print_term t print_term a;
  a

and has_type : Sign.t -> Ctxt.t -> term -> term -> bool = fun sign ctx t a ->
  let eq_modulo a b = eq_modulo a b || add_constraint a b in
  let rec has_type ctx t a =
    match (unfold t, eval a) with
    (* Sort *)
    | (Type     , Kind     ) -> true
    (* Variable *)
    | (Vari(x)  , a        ) -> eq_modulo (Ctxt.find x ctx) a
    (* Symbol *)
    | (Symb(s)  , a        ) -> eq_modulo (symbol_type s) a
    (* Product *)
    | (Prod(a,b), Type     ) -> let (x,bx) = Bindlib.unbind mkfree b in
                                let ctx_x =
                                  if Bindlib.binder_occur b then
                                    Ctxt.add x a ctx
                                  else ctx
                                in
                                has_type ctx a Type
                                && has_type ctx_x bx Type
    (* Product 2 *)
    | (Prod(a,b), Kind     ) -> let (x,bx) = Bindlib.unbind mkfree b in
                                let ctx_x =
                                  if Bindlib.binder_occur b then
                                    Ctxt.add x a ctx
                                  else ctx
                                in
                                has_type ctx a Type
                                && has_type ctx_x bx Kind
    (* Abstraction and Abstraction 2 *)
    | (Abst(a,t), Prod(c,b)) -> let (x,bx) = Bindlib.unbind mkfree b in
                                let tx = Bindlib.subst t (mkfree x) in
                                let ctx_x = Ctxt.add x a ctx in
                                eq_modulo a c
                                && has_type ctx a Type
                                && (has_type ctx_x bx Type
                                    || has_type ctx_x bx Kind)
                                && has_type ctx_x tx bx
    (* Application *)
    | (Appl(_,t,u), b        ) ->
        begin
          match infer sign ctx t with
          | Prod(a,ba) as tt -> eq_modulo (Bindlib.subst ba u) b
                                && has_type ctx t tt
                                && has_type ctx u a
          | _          -> false
        end
    (* No rule apply. *)
    | (_        , _        ) -> false
  in
  if !debug then
    log "type" "%a ⊢ %a : %a" print_ctxt ctx print_term t print_term a;
  let res = has_type ctx t a in
  if !debug then
    log "type" ((if res then gre else red) "%a ⊢ %a : %a")
      print_ctxt ctx print_term t print_term a;
  res

let infer_with_constrs : Sign.t -> Ctxt.t -> term -> term * constrs =
  fun sign ctx t ->
    constraints := Some [];
    let a = infer sign ctx t in
    let cnstrs = match !constraints with Some cs -> cs | None -> [] in
    constraints := None;
    if !debug_patt then
      begin
        log "patt" "inferred type [%a] for [%a]" print_term a print_term t;
        let fn (x,a) =
          log "patt" "  with\t%s\t: %a" (Bindlib.name_of x) print_term a
        in
        List.iter fn ctx;
        let fn (a,b) =
          log "patt" "  where\t%a == %a" print_term a print_term b
        in
        List.iter fn cnstrs
      end;
    (a, cnstrs)

let sub_from_constrs : constrs -> tvar array * term array = fun cs ->
  let rec build_sub acc cs =
    match cs with
    | []        -> acc
    | (a,b)::cs ->
        let (ha,argsa) = get_args a in
        let (hb,argsb) = get_args b in
        match (unfold ha, unfold hb) with
        | (Symb(Sym(sa)), Symb(Sym(sb))) when sa == sb ->
            let cs =
              try List.combine argsa argsb @ cs with Invalid_argument _ -> cs
            in
            build_sub acc cs
        | (Symb(Def(sa)), Symb(Def(sb))) when sa == sb ->
            wrn "%s may not be injective...\n%!" sa.def_name;
            build_sub acc cs
        | (Vari(x)      , _            ) when argsa = [] ->
            build_sub ((x,b)::acc) cs
        | (_            , Vari(x)      ) when argsb = [] ->
            build_sub ((x,a)::acc) cs
        | (a            , b            ) ->
            wrn "Not implemented [%a] [%a]...\n%!" print_term a print_term b;
            build_sub acc cs
  in
  let sub = build_sub [] cs in
  (Array.of_list (List.map fst sub), Array.of_list (List.map snd sub))

let eq_modulo_constrs : constrs -> term -> term -> bool =
  fun constrs a b -> eq_modulo a b ||
    let (xs,sub) = sub_from_constrs constrs in
    let p = Bindlib.box_pair (lift a) (lift b) in
    let p = Bindlib.unbox (Bindlib.bind_mvar xs p) in
    let (a,b) = Bindlib.msubst p sub in
    eq_modulo a b

(* Parser *)
type p_term =
  | P_Vari of string list * string
  | P_Type
  | P_Prod of string * p_term * p_term
  | P_Abst of string * p_term * p_term
  | P_Appl of p_term * p_term
  | P_Wild

let check_not_reserved id =
  if List.mem id ["Type"] then Earley.give_up ()

let parser ident = id:''[a-zA-Z0-9][_a-zA-Z0-9]*'' ->
  check_not_reserved id; id

let parser expr (p : [`Func | `Appl | `Atom]) =
  (* Variable *)
  | fs:{ident "::"}* x:ident
      when p = `Atom
      -> P_Vari(fs,x)
  (* Type constant *)
  | "Type"
      when p = `Atom
      -> P_Type
  (* Product *)
  | x:{ident ":"}?["_"] a:(expr `Appl) "⇒" b:(expr `Func)
      when p = `Func
      -> P_Prod(x,a,b)
  (* Wildcard *)
  | "_"
      when p = `Atom
      -> P_Wild
  (* Abstraction *)
  | "λ" x:ident ":" a:(expr `Func) "." t:(expr `Func)
      when p = `Func
      -> P_Abst(x,a,t)
  (* Application *)
  | t:(expr `Appl) u:(expr `Atom)
      when p = `Appl
      -> P_Appl(t,u)
  (* Parentheses *)
  | "(" t:(expr `Func) ")"
      when p = `Atom
  (* Coercions *)
  | t:(expr `Appl)
      when p = `Func
  | t:(expr `Atom)
      when p = `Appl

let expr = expr `Func

type p_item =
  | NewSym of bool * string * p_term
  | Rule   of string list * p_term * p_term
  | Check  of p_term * p_term
  | Infer  of p_term
  | Eval   of p_term
  | Conv   of p_term * p_term

let parser def =
  | "def" -> true
  | EMPTY -> false

let parser toplevel =
  | d:def x:ident ":" a:expr            -> NewSym(d,x,a)
  | "[" xs:ident* "]" t:expr "→" u:expr -> Rule(xs,t,u)
  | "#CHECK" t:expr "," a:expr          -> Check(t,a)
  | "#INFER" t:expr                     -> Infer(t)
  | "#EVAL" t:expr                      -> Eval(t)
  | "#CONV" t:expr "," u:expr           -> Conv(t,u)

let parser full = {l:toplevel "."}*

(** Blank function for basic blank characters (' ', '\t', '\r' and '\n')
    and line comments starting with "//". *)
let blank buf pos =
  let rec fn state prev ((buf0, pos0) as curr) =
    let open Input in
    let (c, buf1, pos1) = read buf0 pos0 in
    let next = (buf1, pos1) in
    match (state, c) with
    (* Basic blancs. *)
    | (`Ini, ' ' )
    | (`Ini, '\t')
    | (`Ini, '\r')
    | (`Ini, '\n') -> fn `Ini curr next
    (* Comment. *)
    | (`Ini, '/' ) -> fn `Opn curr next
    | (`Opn, '/' ) -> let p = normalize buf1 (line_length buf1) in fn `Ini p p
    (* Other. *)
    | (`Opn, _   ) -> prev
    | (`Ini, _   ) -> curr
  in
  fn `Ini (buf, pos) (buf, pos)

let parse_file : string -> p_item list =
  Earley.(handle_exception (parse_file full blank))

let wildcards : tvar list ref = ref []
let wildcard_counter = ref (-1)
let new_wildcard : unit -> tbox = fun () ->
  incr wildcard_counter;
  let x = Bindlib.new_var mkfree (Printf.sprintf "#%i#" !wildcard_counter) in
  wildcards := x :: !wildcards; Bindlib.box_of_var x

type env = (string * tvar) list

let loaded : (string list, Sign.t) Hashtbl.t = Hashtbl.create 7

let compile_ref : (bool -> string -> Sign.t) ref =
  ref (fun _ _ -> assert false)

let load_signature : string list -> Sign.t = fun fs ->
  try Hashtbl.find loaded fs with Not_found ->
  let file = (String.concat "/" fs) ^ ".lp" in
  !compile_ref false file

let to_tbox : bool -> env -> Sign.t -> p_term -> tbox =
  fun allow_wild vars sign t ->
    let rec build vars t =
      match t with
      | P_Vari([],x)  ->
          begin
            try Bindlib.box_of_var (List.assoc x vars) with Not_found ->
            try _Symb_find sign x with Not_found ->
            fatal "Unbound variable %S...\n%!" x
          end
      | P_Vari(fs,x)  ->
          begin
            let sign = load_signature fs in
            try _Symb_find sign x with Not_found ->
              let x = String.concat "::" (fs @ [x]) in
              fatal "Unbound symbol %S...\n%!" x
          end
      | P_Type        ->
          _Type
      | P_Prod(x,a,b) ->
          let f v = build (if x = "_" then vars else (x,v)::vars) b in
          _Prod (build vars a) x f
      | P_Abst(x,a,t) ->
          let f v = build ((x,v)::vars) t in
          _Abst (build vars a) x f
      | P_Appl(t,u)   ->
          _Appl (build vars t) (build vars u)
      | P_Wild        ->
          if not allow_wild then fatal "\"_\" not allowed in terms...\n";
          new_wildcard ()
    in
    build vars t

let to_term : ?vars:env -> Sign.t -> p_term -> term =
  fun ?(vars=[]) sign t -> Bindlib.unbox (to_tbox false vars sign t)


(* Check that the given term is a pattern and returns its data. *)
let pattern_data : term -> def = fun hd ->
  match unfold hd with
  | Symb(Def(s)) -> s
  | Symb(Sym(s)) -> fatal "%s is not a definable symbol...\n" s.sym_name
  | _            -> raise Exit

let to_tbox_wc : ?vars:env -> Sign.t -> p_term -> def * tbox list * tvar array =
  fun ?(vars=[]) sign t ->
  let rec fn acc t =
    match t with
    | P_Vari([],x)  ->
       let root =
         try Bindlib.box_of_var (List.assoc x vars) with Not_found ->
           try _Symb_find sign x with Not_found ->
             fatal "Unbound variable %S...\n%!" x
       in (root, acc)
    | P_Vari(fs,x)  ->
       let root =
         let sign = load_signature fs in
         try _Symb_find sign x with Not_found ->
           let x = String.concat "::" (fs @ [x]) in
           fatal "Unbound symbol %S...\n%!" x
       in (root, acc)
    | P_Appl(t,u) ->
       fn (to_tbox true vars sign u::acc) t
    | _ -> raise Exit
  in
  wildcards := []; wildcard_counter := -1;
  try
    let (hd,args) = fn [] t in
    let s = pattern_data (Bindlib.unbox hd) in
    (s, args, Array.of_list !wildcards)
  with
    Exit ->
      let t = Bindlib.unbox (to_tbox true vars sign t) in
      fatal "%a is not a valid pattern...\n" print_term t

(* Interpret a whole file *)
let handle_file : Sign.t -> string -> unit = fun sign fname ->
  let handle_item : p_item -> unit = fun it ->
    match it with
    | NewSym(d,x,a) ->
        let a = to_term sign a in
        let sort =
          if has_type sign Ctxt.empty a Type then "Type" else
          if has_type sign Ctxt.empty a Kind then "Kind" else
          fatal "%s is neither of type Type nor Kind.\n" x
        in
        let kind = if d then "defi" else "symb" in
        out "(%s) %s : %a (of sort %s)\n" kind x print_term a sort;
        if d then Sign.new_definable sign x a else Sign.new_static sign x a
    | Rule(xs,t,u) ->
        (* Scoping the LHS and RHS. *)
        let vars = List.map (fun x -> (x, Bindlib.new_var mkfree x)) xs in
        let (s, l, wcs) = to_tbox_wc ~vars sign t in
        let arity = List.length l in
        let l = Bindlib.box_list l in
        let u = to_tbox false vars sign u in
        (* Building the definition. *)
        let xs = Array.append (Array.of_list (List.map snd vars)) wcs in
        let lhs = Bindlib.unbox (Bindlib.bind_mvar xs l) in
        let rhs = Bindlib.unbox (Bindlib.bind_mvar xs u) in
        (* Constructing the typing context and the terms. *)
        let xs = Array.to_list xs in
        let ctx = List.map (fun x -> (x, Unif(ref None))) xs in
        let u = Bindlib.unbox u in
        (* Check that the LHS is a pattern and build the rule. *)
        let rule = { lhs ; rhs ; arity } in
        let t = add_args (Symb(Def s)) (Bindlib.unbox l) in
        (* Infer the type of the LHS and the constraints. *)
        let (tt, tt_constrs) =
          try infer_with_constrs sign ctx t with Not_found ->
            fatal "Unable to infer the type of [%a]\n" print_term t
        in
        (* Infer the type of the RHS and the constraints. *)
        let (tu, tu_constrs) =
          try infer_with_constrs sign ctx u with Not_found ->
            fatal "Unable to infer the type of [%a]\n" print_term u
        in
        (* Checking the implication of constraints. *)
        let check_constraint (a,b) =
          if not (eq_modulo_constrs tt_constrs a b) then
            fatal "A constraint is not satisfied...\n"
        in
        List.iter check_constraint tu_constrs;
        (* Checking if the rule is well-typed. *)
        if eq_modulo_constrs tt_constrs tt tu then
          begin
            out "(rule) %a → %a\n" print_term t print_term u;
            s.def_rules := !(s.def_rules) @ [rule]
          end
        else
          begin
            err "Infered type for LHS: %a\n" print_term tt;
            err "Infered type for RHS: %a\n" print_term tu;
            fatal "[%a → %a] is ill-typed\n" print_term t print_term u
          end
    | Check(t,a)   ->
        let t = to_term sign t in
        let a = to_term sign a in
        if has_type sign Ctxt.empty t a then
          out "(chck) %a : %a\n" print_term t print_term a
        else
          fatal "%a does not have type %a...\n" print_term t print_term a
    | Infer(t)     ->
        let t = to_term sign t in
        begin
          try
            let a = infer sign Ctxt.empty t in
            out "(infr) %a : %a\n" print_term t print_term a
          with Not_found ->
            err "%a : unable to infer\n%!" print_term t
        end
    | Eval(t)      ->
        let t = to_term sign t in
        out "(eval) %a\n" print_term (eval t)
    | Conv(t,u)    ->
        let t = to_term sign t in
        let u = to_term sign u in
        if not (eq_modulo t u) then
          err "unable to convert %a and %a...\n" print_term t print_term u
        else
          out "(conv) OK\n"
  in
  List.iter handle_item (parse_file fname)

let obj_file : string -> string = fun file ->
  Filename.chop_extension file ^ ".lpo"

let module_path : string -> string list = fun file ->
  let base = Filename.chop_extension (Filename.basename file) in
  let dir  = Filename.dirname  file in
  let rec build_path acc dir =
    let dirbase = Filename.basename dir in
    let dirdir  = Filename.dirname  dir in
    if dirbase = "." then acc else build_path (dirbase::acc) dirdir
  in
  build_path [base] dir

let mod_time : string -> float = fun fname ->
  if Sys.file_exists fname then Unix.((stat fname).st_mtime)
  else neg_infinity

let binary_time : float = mod_time "/proc/self/exe"

let more_recent source target =
  mod_time source > mod_time target
  || binary_time > mod_time target

let compile : bool -> string -> Sign.t = fun force file ->
  if not (Sys.file_exists file) then fatal "File not found: %s\n" file;
  let obj = obj_file file in
  let fs = module_path file in
  if more_recent file obj || (force && not (Hashtbl.mem loaded fs)) then
    begin
      out "Loading file [%s]\n%!" file;
      let sign = Sign.create fs in
      begin
        try handle_file sign file with e ->
          fatal "Uncaught exception...\n%s\n%!" (Printexc.to_string e)
      end;
      Sign.write sign obj;
      Hashtbl.add loaded fs sign;
      out "Done with file [%s]\n%!" file;
      sign
    end
  else
    try Hashtbl.find loaded fs with Not_found ->
    let sign = Sign.read obj in
    Hashtbl.add loaded fs sign; sign

let _ = compile_ref := compile

let compile force file =
  let fs = module_path file in
  current_module := fs;
  ignore (compile force file)

(* Run files *)
let _ =
  let usage = Sys.argv.(0) ^ " [--debug [a|e|i|p]] [--quiet] [FILE] ..." in
  let flags =
    [ "a : general debug informations"
    ; "e : extra debugging informations for equality"
    ; "i : extra debugging informations for inference"
    ; "p : extra debugging informations for patterns" ]
  in
  let flags = List.map (fun s -> String.make 18 ' ' ^ s) flags in
  let flags = String.concat "\n" flags in
  let spec =
    [ ("--debug", Arg.String set_debug, "<str> Set debugging mode:\n" ^ flags)
    ; ("--quiet", Arg.Set quiet       , " Disable output") ]
  in
  let files = ref [] in
  let anon fn = files := fn :: !files in
  Arg.parse (Arg.align spec) anon usage;
  List.iter (compile true) (List.rev !files)
