/-
Copyright (c) 2020 Gabriel Ebner. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Gabriel Ebner
-/
import Std.Tactic.Lint.Basic
import Std.Tactic.OpenPrivate
import Std.Util.LibraryNote
open Lean Meta

namespace Std.Tactic.Lint

/-!
# Linter for simplification lemmas

This files defines several linters that prevent common mistakes when declaring simp lemmas:

 * `simpNF` checks that the left-hand side of a simp lemma is not simplified by a different lemma.
 * `simpVarHead` checks that the head symbol of the left-hand side is not a variable.
 * `simpComm` checks that commutativity lemmas are not marked as simplification lemmas.
-/

/-- The data associated to a simp theorem. -/
structure SimpTheoremInfo where
  /-- The hypotheses of the theorem -/
  hyps : Array Expr
  /-- True if this is a conditional rewrite rule -/
  isConditional : Bool
  /-- The thing to replace -/
  lhs : Expr
  /-- The result of replacement -/
  rhs : Expr

/-- Given the list of hypotheses, is this a conditional rewrite rule? -/
def isConditionalHyps (eq : Expr) : List Expr → MetaM Bool
  | [] => pure false
  | h :: hs => do
    let ldecl ← getFVarLocalDecl h
    if !ldecl.binderInfo.isInstImplicit
        && !(← hs.anyM fun h' => do pure $ (← inferType h').containsFVar h.fvarId!)
        && !eq.containsFVar h.fvarId! then
      return true
    isConditionalHyps eq hs

open private preprocess from Lean.Meta.Tactic.Simp.SimpTheorems in
/-- Runs the continuation on all the simp theorems encoded in the given type. -/
def withSimpTheoremInfos (ty : Expr) (k : SimpTheoremInfo → MetaM α) : MetaM (Array α) :=
  withReducible do
    let e ← preprocess (← mkSorry ty true) ty (inv := false) (isGlobal := true)
    e.toArray.mapM fun (_, ty') => do
      forallTelescopeReducing ty' fun hyps eq => do
        let some (_, lhs, rhs) := eq.eq? | throwError "not an equality {eq}"
        let isConditional ← isConditionalHyps eq hyps.toList
        k { hyps, lhs, rhs, isConditional }

/-- Checks whether two expressions are equal for the simplifier. That is,
they are reducibly-definitional equal, and they have the same head symbol. -/
def isSimpEq (a b : Expr) (whnfFirst := true) : MetaM Bool := withReducible do
  let a ← if whnfFirst then whnf a else pure a
  let b ← if whnfFirst then whnf b else pure b
  if a.getAppFn.constName? != b.getAppFn.constName? then return false
  isDefEq a b

/-- Constructs a message from all the simp theorems encoded in the given type. -/
def checkAllSimpTheoremInfos (ty : Expr) (k : SimpTheoremInfo → MetaM (Option MessageData)) :
    MetaM (Option MessageData) := do
  let errors := (← withSimpTheoremInfos ty fun i => do (← k i).mapM addMessageContextFull).filterMap id
  if errors.isEmpty then
    return none
  return MessageData.joinSep errors.toList Format.line

/-- Returns true if this is a `@[simp]` declaration. -/
def isSimpTheorem (declName : Name) : MetaM Bool := do
  pure $ (← getSimpTheorems).lemmaNames.contains declName

open Lean.Meta.DiscrTree in
/-- Returns the list of elements in the discrimination tree. -/
partial def _root_.Lean.Meta.DiscrTree.elements (d : DiscrTree α) : Array α :=
  d.root.foldl (init := #[]) fun arr _ => trieElements arr
where
  trieElements (arr)
  | Trie.node vs children =>
    children.foldl (init := arr ++ vs) fun arr (_, child) => trieElements arr child

open Std

/--
In Lean 4, the simplifier adds auxiliary lemmas if the declaration is not an equation.
For example, for `decl : a ↔ b` it generates `decl._auxLemma.1 : a = b`.
This function computes the map ``{`decl._auxLemma.1 ↦ `decl}``
-/
def constToSimpDeclMap (ctx : Simp.Context) : HashMap Name Name := Id.run do
  let mut map : HashMap Name Name := {}
  for sls' in ctx.simpTheorems do
    for sls in [sls'.pre, sls'.post] do
      for sl in sls.elements do
        if let some declName := sl.name? then
          if let some auxDeclName := sl.proof.getAppFn.constName? then
            map := map.insert auxDeclName declName
  return map

/-- Is this an equation lemma, and if so, what is the declaration it is a lemma for? -/
def isEqnLemma? (n : Name) : Option Name :=
  if n.isStr && n.getString!.startsWith "_eq_" then
    n.getPrefix
  else
    none

/-- Try to reconstruct the list of used simp lemmas given the result of `simp`. -/
def heuristicallyExtractSimpTheorems (ctx : Simp.Context)
    (prf : Expr) : Array Name := Id.run do
  let constToSimpDecl := constToSimpDeclMap ctx
  let mut cnsts : HashSet Name := {}
  for c in prf.getUsedConstants do
    if ctx.simpTheorems.isDeclToUnfold c then
      cnsts := cnsts.insert c
    else if ctx.congrTheorems.lemmas.contains c then
      cnsts := cnsts.insert c
    else if let some c' := constToSimpDecl.find? c then
      cnsts := cnsts.insert c'
    else if let some c' := isEqnLemma? c then
      cnsts := cnsts.insert c'
  return cnsts.toArray

/-- Add message `msg` to any errors thrown inside `k`. -/
def decorateError (msg : MessageData) (k : MetaM α) : MetaM α := do
  try k catch e => throw (.error e.getRef m!"{msg}\n{e.toMessageData}")

/-- Render the list of simp lemmas as a `MessageData`. -/
def formatLemmas (lems : Array Name) : CoreM MessageData := do
  toMessageData <$> lems.mapM mkConstWithLevelParams

/-- A linter for simp lemmas whose lhs is not in simp-normal form, and which hence never fire. -/
@[stdLinter] def simpNF : Linter where
  noErrorsFound := "All left-hand sides of simp lemmas are in simp-normal form."
  errorsFound := "SOME SIMP LEMMAS ARE NOT IN SIMP-NORMAL FORM.
see note [simp-normal form] for tips how to debug this.
https://leanprover-community.github.io/mathlib_docs/notes.html#simp-normal%20form"

  test := fun declName => do
    unless ← isSimpTheorem declName do return none
    -- TODO: equation lemmas
    let ctx ← Simp.Context.mkDefault
    let ctx := { ctx with config.decide := false }
    checkAllSimpTheoremInfos (← getConstInfo declName).type fun {lhs, rhs, isConditional, ..} => do
    let ⟨lhs', prf1, _⟩ ← decorateError "simplify fails on left-hand side:" <| simp lhs ctx
    let prf1_lems := heuristicallyExtractSimpTheorems ctx (prf1.getD (mkBVar 0))
    if prf1_lems.contains declName then return none
    let ⟨rhs', prf2, _⟩ ← decorateError "simplify fails on right-hand side:" <| simp rhs ctx
    let lhs'_eq_rhs' ← isSimpEq lhs' rhs' (whnfFirst := false)
    let lhs_in_nf ← isSimpEq lhs' lhs
    if lhs'_eq_rhs' then do
      if prf1.isNone then return none -- TODO: cannot detect used rfl-lemmas
      if let .str _n "sizeOf_spec" := declName then
        return none -- HACK: these often use rfl-lemmas but are not rfl
      let used_lemmas := heuristicallyExtractSimpTheorems ctx <|
        mkApp (prf1.getD (mkBVar 0)) (prf2.getD (mkBVar 0))
      return m!"simp can prove this:
  by simp only {← formatLemmas used_lemmas}
One of the lemmas above could be a duplicate.
If that's not the case try reordering lemmas or adding @[priority].
"
    else if ¬ lhs_in_nf then do
      return m!"Left-hand side simplifies from
  {lhs}
to
  {lhs'}
using
  {← formatLemmas prf1_lems}
Try to change the left-hand side to the simplified term!
"
    else if !isConditional && lhs == lhs' then
      return m!"Left-hand side does not simplify.
You need to debug this yourself using `set_option trace.Meta.Tactic.simp.rewrite true`"
    else
      return none

library_note "simp-normal form" /--
This note gives you some tips to debug any errors that the simp-normal form linter raises.

The reason that a lemma was considered faulty is because its left-hand side is not in simp-normal
form.
These lemmas are hence never used by the simplifier.

This linter gives you a list of other simp lemmas: look at them!

Here are some tips depending on the error raised by the linter:

  1. 'the left-hand side reduces to XYZ':
     you should probably use XYZ as the left-hand side.

  2. 'simp can prove this':
     This typically means that lemma is a duplicate, or is shadowed by another lemma:

     2a. Always put more general lemmas after specific ones:
      ```
      @[simp] lemma zero_add_zero : 0 + 0 = 0 := rfl
      @[simp] lemma add_zero : x + 0 = x := rfl
      ```

      And not the other way around!  The simplifier always picks the last matching lemma.

     2b. You can also use `@[priority]` instead of moving simp-lemmas around in the file.

      Tip: the default priority is 1000.
      Use `@[priority 1100]` instead of moving a lemma down,
      and `@[priority 900]` instead of moving a lemma up.

     2c. Conditional simp lemmas are tried last. If they are shadowed
         just remove the `simp` attribute.

     2d. If two lemmas are duplicates, the linter will complain about the first one.
         Try to fix the second one instead!
         (You can find it among the other simp lemmas the linter prints out!)

  3. 'try_for tactic failed, timeout':
     This typically means that there is a loop of simp lemmas.
     Try to apply squeeze_simp to the right-hand side (removing this lemma from the simp set) to see
     what lemmas might be causing the loop.

     Another trick is to `set_option trace.simplify.rewrite true` and
     then apply `try_for 10000 { simp }` to the right-hand side.  You will
     see a periodic sequence of lemma applications in the trace message.
-/

/--
A linter for simp lemmas whose lhs has a variable as head symbol,
and which hence never fire.
-/
@[stdLinter] def simpVarHead : Linter where
  noErrorsFound :=
    "No left-hand sides of a simp lemma has a variable as head symbol."
  errorsFound := "LEFT-HAND SIDE HAS VARIABLE AS HEAD SYMBOL.
Some simp lemmas have a variable as head symbol of the left-hand side:"
  test := fun declName => do
    unless ← isSimpTheorem declName do return none
    checkAllSimpTheoremInfos (← getConstInfo declName).type fun {lhs, ..} => do
    let headSym := lhs.getAppFn
    unless headSym.isFVar do return none
    return m!"Left-hand side has variable as head symbol: {headSym}"

/-- A linter for commutativity lemmas that are marked simp. -/
@[stdLinter] def simpComm : Linter where
  noErrorsFound := "No commutativity lemma is marked simp."
  errorsFound := "COMMUTATIVITY LEMMA IS SIMP.
Some commutativity lemmas are simp lemmas:"
  test := fun declName => withReducible do
    unless ← isSimpTheorem declName do return none
    let ty := (← getConstInfo declName).type
    forallTelescopeReducing ty fun _ ty => do
    let some (_, lhs, rhs) := ty.eq? | return none
    unless lhs.getAppFn.constName? == rhs.getAppFn.constName? do return none
    let (_, _, ty') ← forallMetaTelescopeReducing ty
    let some (_, lhs', rhs') := ty'.eq? | return none
    unless ← isDefEq rhs lhs' do return none
    unless ← withNewMCtxDepth (isDefEq rhs lhs') do return none
    -- ensure that the second application makes progress:
    if ← isDefEq lhs' rhs' then return none
    pure m!"should not be marked simp"
