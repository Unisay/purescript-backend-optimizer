module PureScript.Backend.Directives.Defaults where

defaultDirectives :: String
defaultDirectives =
  """
  -- Prelude

  Control.Applicative.liftA1 arity=1
  Control.Applicative.when arity=1
  Control.Applicative.unless arity=1
  Control.Applicative.applicativeFn.pure arity=1
  Control.Applicative.applicativeArray.pure arity=1

  Control.Apply.applyFirst arity=1
  Control.Apply.applySecond arity=1
  Control.Apply.lift2 arity=1
  Control.Apply.lift3 arity=1
  Control.Apply.lift4 arity=1
  Control.Apply.lift5 arity=1
  Control.Apply.applyFn.apply arity=2

  Control.Bind.bindFlipped arity=1
  Control.Bind.join arity=1
  Control.Bind.composeKleisli arity=1
  Control.Bind.composeKleisliFlipped arity=1
  Control.Bind.ifM arity=1
  Control.Bind.bindFn arity=2
  Control.Bind.discard arity=1
  Control.Category.categoryFn.identity always

  Control.Monad.ap arity=1
  Control.Monad.lift1 arity=1
  Control.Monad.whenM arity=1
  Control.Monad.unlessM arity=1

  Control.Semigroupoid.composeFlipped arity=1
  Control.Semigroupoid.semigroupoidFn.compose arity=2

  Data.Boolean.otherwise always

  Data.Bounded.boundedRecordCons arity=5
  Data.Bounded.boundedRecord arity=2

  Data.Bounded.Generic.genericBottom arity=1
  Data.Bounded.Generic.genericBottom' arity=1
  Data.Bounded.Generic.genericBottomNoArguments.genericBottom' always
  Data.Bounded.Generic.genericBottomArgument.genericBottom' arity=1
  Data.Bounded.Generic.genericBottomSum.genericBottom' arity=1
  Data.Bounded.Generic.genericBottomProduct.genericBottom' arity=2
  Data.Bounded.Generic.genericBottomConstructor.genericBottom' arity=1
  Data.Bounded.Generic.genericTop arity=1
  Data.Bounded.Generic.genericTop' arity=1
  Data.Bounded.Generic.genericTopNoArguments.genericTop' always
  Data.Bounded.Generic.genericTopArgument.genericTop' arity=1
  Data.Bounded.Generic.genericTopSum.genericTop' arity=1
  Data.Bounded.Generic.genericTopProduct.genericTop' arity=2
  Data.Bounded.Generic.genericTopConstructor.genericTop' arity=1

  Data.DivisionRing.leftDiv arity=1
  Data.DivisionRing.rightDiv arity=1
  Data.DivisionRing.divisionringNumber.recip arity=1

  Data.Eq.notEq arity=1
  Data.Eq.eqArray arity=1
  Data.Eq.eqRowCons arity=4
  Data.Eq.notEq1 arity=1

  Data.EuclideanRing.gcd arity=4
  Data.EuclideanRing.lcm arity=4

  Data.Function.flip arity=1
  Data.Function.const arity=1
  Data.Function.apply arity=2
  Data.Function.applyFlipped arity=2
  Data.Function.on arity=2

  Data.Functor.mapFlipped arity=1
  Data.Functor.void arity=1
  Data.Functor.voidRight arity=1
  Data.Functor.voidLeft arity=1
  Data.Functor.flap arity=1

  Data.HeytingAlgebra.heytingAlgebraBoolean.implies arity=2
  Data.HeytingAlgebra.heytingAlgebraRecordCons arity=4

  Data.Monoid.guard arity=2
  Data.Monoid.monoidRecordCons arity=4

  Data.Ord.comparing arity=2
  Data.Ord.ordRecordCons arity=4

  Data.Semigroup.semigroupFn.append arity=2
  Data.Semigroup.semigroupRecordCons arity=4

  Control.Monad.ST.Internal.modify arity=2
  Effect.applyEffect.apply arity=2
  Effect.Ref.modify arity=2
  Record.Builder.build arity=1
  Record.Builder.rename arity=8
  """
