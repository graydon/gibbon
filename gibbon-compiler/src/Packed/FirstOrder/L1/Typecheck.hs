{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Packed.FirstOrder.L1.Typecheck
  ( tcProg, tcExp ) where


import Control.Monad.Except
import Data.Loc
import Data.Map as M
import Data.List as L
import Text.PrettyPrint
import Text.PrettyPrint.GenericPretty

import Packed.FirstOrder.Common
import Packed.FirstOrder.L1.Syntax as L1

--------------------------------------------------------------------------------

type Exp = L Exp1

-- | Typecheck a L1 expression
--
tcExp :: DDefs Ty1 -> Env2 Ty1 -> Exp -> TcM Ty1
tcExp ddfs env exp@(L p ex) =
  case ex of
    VarE v    -> lookupVar env v exp
    LitE _    -> return IntTy
    LitSymE _ -> return IntTy

    AppE v locs e -> do
      let (inTy, outTy) =
            case (M.lookup v (fEnv env)) of
              Just ty -> ty
              Nothing -> error $ "Function not found: " ++ sdoc v ++ " while checking " ++
                                 sdoc exp ++ " at " ++ show p

      -- Check that the expression does not have any locations
      case locs of
        [] -> return ()
        _  -> throwError $ GenericTC ("Expected the locations to be empty in L1. Got"
                                      ++ sdoc locs)
                           exp

      -- Check argument type
      argTy <- go e
      _     <- ensureEqualTy exp inTy argTy
      return outTy

    PrimAppE pr es -> do
      let len0 = checkLen exp pr 0 es
          len2 = checkLen exp pr 2 es
          len3 = checkLen exp pr 3 es

      tys <- mapM go es
      case pr of
        _ | pr `elem` [AddP, SubP, MulP]  -> do
          len2
          _ <- ensureEqualTy exp IntTy (tys !! 0)
          _ <- ensureEqualTy exp IntTy (tys !! 1)
          return IntTy

        _ | pr `elem` [MkTrue, MkFalse] -> do
          len0
          return BoolTy

        EqSymP -> do
          len2
          _ <- ensureEqualTy exp SymTy (tys !! 0)
          _ <- ensureEqualTy exp SymTy (tys !! 1)
          return BoolTy

        EqIntP -> do
          len2
          _ <- ensureEqualTy exp IntTy (tys !! 0)

          _ <- ensureEqualTy exp IntTy (tys !! 1)
          return BoolTy

        SizeParam -> do
          len0
          return IntTy

        DictEmptyP ty -> do
          len0
          return $ SymDictTy ty

        DictInsertP ty -> do
          len3
          let [d,k,v] = tys
          _ <- ensureEqualTy exp (SymDictTy ty) d
          _ <- ensureEqualTy exp SymTy k
          _ <- ensureEqualTy exp ty v
          return d

        DictLookupP ty -> do
          len2
          let [d,k] = tys
          _ <- ensureEqualTy exp (SymDictTy ty) d
          _ <- ensureEqualTy exp SymTy k
          return ty

        DictHasKeyP ty -> do
          len2
          let [d,k] = tys
          _ <- ensureEqualTy exp (SymDictTy ty) d
          _ <- ensureEqualTy exp SymTy k
          return BoolTy

        oth -> error $ "L1.tcExp : PrimAppE : TODO " ++ sdoc oth

    LetE (v,locs,ty,rhs) e -> do
      -- Check that the expression does not have any locations
      case locs of
        [] -> return ()
        _  -> throwError $ GenericTC ("Expected the locations to be empty in L1. Got"
                                      ++ sdoc locs)
                           exp
      -- Check RHS
      tyRhs <- go rhs
      _ <- ensureEqualTy exp tyRhs ty
      let env' = extendEnv env [(v,ty)]
      -- Check body
      tcExp ddfs env' e

    IfE tst consq alt -> do
      -- Check if the test is a boolean
      tyTst <- go tst
      _ <- ensureEqualTy exp tyTst BoolTy

      -- Check if both branches match
      tyConsq <- go consq
      tyAlt   <- go alt

      _ <- ensureEqualTy exp tyConsq tyAlt
      return tyConsq

    MkProdE es -> do
      tys <- mapM go es
      return $ ProdTy tys

    ProjE i e -> do
      ty  <- go e
      tyi <- tcProj exp i ty
      return tyi

    CaseE e cs -> do
      tye <- go e
      let tycons = L.map (getTyOfDataCon ddfs . (\(a,_,_) -> a)) cs
      case L.nub tycons of
        [one] -> do
          _ <- ensureEqualTy exp (PackedTy one ()) tye
          tcCases ddfs env cs
        oth   -> throwError $ GenericTC ("Case branches have mismatched types: " ++ sdoc oth
                                         ++" , in " ++ sdoc exp) exp

    DataConE loc dc es -> do
      tys <- mapM go es
      let dcTy = getTyOfDataCon ddfs dc
          args = lookupDataCon ddfs dc
      if length args /= length es
      then throwError $ GenericTC ("Invalid argument length: " ++ sdoc es) exp
      else do
        -- Check if arguments match with expected datacon types
        sequence_ [ ensureEqualTy e ty1 ty2
                  | (ty1,ty2,e) <- zip3 args tys es]
        return $ PackedTy dcTy loc

    TimeIt e _ty _b -> do
      -- Before flatten, _ty is always (PackedTy "DUMMY_TY" ())
      -- enforce ty == _ty in strict mode ?
      ty <- go e
      return ty

    oth -> error $ "L1.tcExp : TODO " ++ sdoc oth

  where
    go = tcExp ddfs env


-- | Typecheck a L1 program
--
tcProg :: Prog -> SyM Prog
tcProg prg@Prog{ddefs,fundefs,mainExp} = do

  -- Handle functions
  mapM_ fd $ M.elems fundefs

  -- Handle main expression
  case mainExp of
    Nothing -> return ()
    Just e  ->
      let res = runExcept $ tcExp ddefs env e
      in case res of
        Left err -> error $ sdoc err
        Right _ -> return ()

  -- Identity function for now.
  return prg

  where
    env = L1.progToEnv prg

    -- fd :: forall e l . FunDef Ty1 Exp -> SyM ()
    fd FunDef{funArg,funRetTy,funBody} = do
      let (arg,argTy) = funArg
          env' = Env2 (M.singleton arg argTy) (fEnv env)
          res = runExcept $ tcExp ddefs env' funBody
      case res of
        Left err -> error $ sdoc err
        Right ty -> if ty == funRetTy
                    then return ()
                    else error $ "Expected type " ++ (sdoc funRetTy)
                         ++ " and got type " ++ (sdoc ty)

      return ()

--------------------------------------------------------------------------------

-- TODO: share this with L2.Typecheck In fact, almost all of tcProg
-- is the same too
data TCError = GenericTC String  Exp
             | VarNotFoundTC Var Exp
             | UnsupportedExpTC  Exp
  deriving (Show, Eq, Ord, Generic)


instance Out TCError where
  doc tce =
    case tce of
      GenericTC str (L p ex)    -> text str <+> text "in" $$
                                   (text $ show p) <+> colon <+> doc ex
      VarNotFoundTC v (L p ex)  -> text "Var" <+> doc v <+> text "not found. Checking: " $$
                                   (text $ show p) <+> colon <+> doc ex
      UnsupportedExpTC (L p ex) -> text "Unsupported expression:" $$
                                   (text $ show p) <+> colon <+> doc ex

type TcM a = Except TCError a


extendEnv :: Env2 Ty1 -> [(Var, Ty1)] -> Env2 Ty1
extendEnv (Env2 vEnv fEnv) ((v,ty):rest) = extendEnv (Env2 (M.insert v ty vEnv) fEnv) rest
extendEnv env [] = env


lookupVar :: Env2 Ty1 -> Var -> Exp -> TcM Ty1
lookupVar env var exp =
    case M.lookup var $ vEnv env of
      Nothing -> throwError $ VarNotFoundTC var exp
      Just ty -> return ty

tcProj :: Exp -> Int -> Ty1 -> TcM Ty1
tcProj _ i (ProdTy tys) = return $ tys !! i
tcProj e _i ty = throwError $ GenericTC ("Projection from non-tuple type " ++ (sdoc ty)) e


tcCases :: DDefs Ty1 -> Env2 Ty1 -> [(DataCon, [(Var, l)], Exp)] -> TcM Ty1
tcCases ddfs env cs = do
  tys <- forM cs $ \(c,args',rhs) -> do
           let args  = L.map fst args'
               targs = lookupDataCon ddfs c
               env'  = extendEnv env (zip args targs)
           tcExp ddfs env' rhs
  foldM_ (\acc (ex,ty) -> ensureEqualTy ex ty acc >> (return acc))
         (head tys) (zipWith (\ty (_,_,ex) -> (ex,ty)) tys cs)
  return $ head tys


checkLen :: (Out op, Out arg) => Exp -> op -> Int -> [arg] -> TcM ()
checkLen expr pr n ls =
  if length ls == n
  then return ()
  else throwError $ GenericTC ("Wrong number of arguments to "++sdoc pr++
                               ".\nExpected "++sdoc n++", received "
                                ++sdoc (length ls)++":\n  "++sdoc ls)
                    expr

-- | Ensure that two things are equal.
-- Includes an expression for error reporting.
ensureEqual :: Exp -> String -> Ty1 -> Ty1 -> TcM Ty1
ensureEqual exp str a b = if a == b
                          then return a
                          else throwError $ GenericTC str exp


-- | Ensure that two types are equal.
-- Includes an expression for error reporting.
ensureEqualTy :: Exp -> Ty1 -> Ty1 -> TcM Ty1
ensureEqualTy exp a b = ensureEqual exp ("Expected these types to be the same: "
                                         ++ (sdoc a) ++ ", " ++ (sdoc b)) a b


--------------------------------------------------------------------------------

test6 = runSyM 0 $ tcProg t6

t6 :: Prog
t6 = Prog {ddefs = M.fromList [],
      fundefs = M.fromList [],
      mainExp = Just $ L NoLoc $LetE ("d0",
                           [],
                           SymDictTy IntTy,
                           L NoLoc $PrimAppE (DictEmptyP IntTy) [])
                          (L NoLoc $LetE ("d21",
                                 [],
                                 SymDictTy IntTy,
                                 L NoLoc $ PrimAppE (DictInsertP IntTy) [L NoLoc $VarE "d0",L NoLoc $LitSymE "hi",L NoLoc $LitE 200])
                                (L NoLoc $ LitE 44))}


test5 = runSyM 0 $ tcProg t5

t5 :: Prog
t5 = Prog {ddefs = M.fromList [("Foo",
                DDef {tyName = "Foo",
                      dataCons = [("A", [(False, IntTy)]),
                                  ("B", [(False, IntTy),(False, BoolTy)])]}),
               ("Nat",
                DDef {tyName = "Nat",
                      dataCons = [("Zero", []),("Suc", [(False, PackedTy "Nat" ())])]})],
      fundefs = M.fromList [],
      mainExp = Just $ L NoLoc $ CaseE (L NoLoc $ DataConE () "B" [L NoLoc $ LitE 2,
                                                                   L NoLoc $LitE 4])
                           [("A", [("x", ())], L NoLoc $ VarE "x"),
                            ("B", [("x", ()),("y", ())], L NoLoc $ VarE "x")]}

-- *** Exception: Expected these types to be the same: BoolTy, IntTy in
-- LitE 4

test4 = runSyM 0 $ tcProg t4

t4 :: Prog
t4 = Prog {ddefs = M.fromList [("Foo",
                DDef {tyName = "Foo",
                      dataCons = [("A", []),
                                  ("B", [(False, IntTy),(False, PackedTy "Foo" ())])]})],
      fundefs = M.fromList [("foo",
                  FunDef {funName = "foo",
                          funArg = ("ev", PackedTy "Foo" ()),
                          funRetTy = IntTy,
                          funBody = L NoLoc $ CaseE (L NoLoc $ VarE "ev")
                                          [("A", [], (L NoLoc $ LitE 10)),
                                           ("B", [("x", ()),("y", ())], L NoLoc $ LitE 200)]})],
      mainExp = Nothing}

test3 = runSyM 0 $ tcProg t3

t3 :: Prog
t3 = Prog {ddefs = M.fromList [],
           fundefs = M.fromList [],
           mainExp = Just $ L NoLoc $
                     IfE (L NoLoc $
                          PrimAppE EqIntP
                          [L NoLoc $ LitE 1, L NoLoc $ LitE 1])
                     (L NoLoc $
                      IfE (L NoLoc $ PrimAppE EqIntP
                           [L NoLoc $ LitE 2, L NoLoc $ LitE 2])
                       (L NoLoc $ LitE 100) (L NoLoc $ LitE 1))
                     (L NoLoc $ LitE 2)}

test2 = runSyM 0 $ tcProg t2

t2 :: Prog
t2 = Prog {ddefs = M.fromList
                   [("T",
                      DDef {tyName = "T", dataCons = [("MkA", []),("MkB", [(False, IntTy)])]})],
      fundefs = M.fromList [],
      mainExp = Just $ L NoLoc $ DataConE () "MkB" [L NoLoc $ LitE 10]}

test1 = runSyM 0 $ tcProg t1

t1 :: Prog
t1 =
  Prog {ddefs = M.fromList [],
        fundefs = M.fromList
                  [("mul2",
                    FunDef {funName = "mul2",
                            funArg = ("x_y1", ProdTy [IntTy,IntTy]),
                            funRetTy = IntTy,
                            funBody = L NoLoc $ PrimAppE MulP
                                      [L NoLoc $ ProjE 0 (L NoLoc $ VarE "x_y1"),
                                       L NoLoc $ ProjE 1 (L NoLoc $ VarE "x_y1")]}),
                   ("add2",
                    FunDef {funName = "add2",
                            funArg = ("x_y0", ProdTy [IntTy,IntTy]),
                            funRetTy = IntTy,
                            funBody = L NoLoc $ PrimAppE AddP
                                      [L NoLoc $  ProjE 0 (L NoLoc $ VarE "x_y0"),
                                       L NoLoc $ ProjE 1 (L NoLoc $ VarE "x_y0")]})],
        mainExp = Just $ L NoLoc $ AppE "mul2"
                  []
                  (L NoLoc $ MkProdE [L NoLoc $ LitE 10, L NoLoc $ AppE "add2" [] (L NoLoc $ MkProdE [L NoLoc $ LitE 40, L NoLoc $ LitE 2])])}
