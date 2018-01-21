{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unused-do-bind #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Packed.FirstOrder.Passes.LLVM.Codegen where

-- | standard library
import Control.Monad.Except
import Control.Monad.State
import Data.ByteString.Char8 (unpack)
import qualified Data.Map as Map

-- | gibbon internals
import Packed.FirstOrder.L4.Syntax
import Packed.FirstOrder.Passes.Codegen (rewriteReturns)
import Packed.FirstOrder.Common (fromVar,toVar, varAppend)
import Packed.FirstOrder.Passes.LLVM.Monad
import Packed.FirstOrder.Passes.LLVM.Instruction
import Packed.FirstOrder.Passes.LLVM.Terminator
import Packed.FirstOrder.Passes.LLVM.Gibbon
import Packed.FirstOrder.Passes.LLVM.Global hiding (toPtrTy)
import Packed.FirstOrder.Passes.LLVM.Utils

-- | llvm-hs
import qualified LLVM.AST as AST
import qualified LLVM.AST.Global as G
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.Type as T
import qualified LLVM.Context as CTX
import qualified LLVM.Module as M


toLLVM :: AST.Module -> IO String
toLLVM m = CTX.withContext $ \ctx -> do
    x <- M.withModuleFromAST ctx m M.moduleLLVMAssembly
    return $ unpack x


-- | Generate LLVM instructions for Prog
--
codegenProg :: Bool -> Prog -> IO String
codegenProg _ prg@(Prog fns body) = (toLLVM . genModule) $ do
  -- declare helpers defined in lib.c
  declare printInt
  declare fputs
  declare globalSizeParam
  declare globalItersParam
  declare clockGetTime
  declare difftimespecs
  declare printDiffTime
  declare printIterDiffTime
  declare saveAllocState
  declare restoreAllocState
  declare dictInsertInt
  declare dictLookupInt
  declare exit

  -- generate structs and fns
  _ <- addStructs prg
  _ <- addTypeDef "struct.timespec" timespecStruct
  _ <- addTypeDef "union.dict_item" dictItemUnion
  _ <- addTypeDef "struct.dict_item" dictItemStruct
  mapM_ codegenFunSig fns'
  mapM_ codegenFun fns'
  where expr = case body of
                 Just (PrintExp t) -> t
                 _ -> RetValsT []
        fns' = fns ++ [FunDecl (toVar "__main_expr") [] (ProdTy []) expr]


-- | Add fn signatures to globalFns
--
-- This is intended to be used by the call fn (LetCallT).
-- Storing only the signature is important to allow recursive fn definitions
-- and forward references
--
codegenFunSig :: FunDecl -> CodeGen ()
codegenFunSig (FunDecl fnName args retTy _) =
  let fnName' = fromVar fnName
      fnsig = G.functionDefaults
                {  G.name        = AST.Name $ toByteString fnName'
                ,  G.parameters  = ([G.Parameter (typeOf ty) (AST.Name $ toByteString $ fromVar v) []
                                    | (v, ty) <- args],
                                    False)
                , G.returnType  = typeOf retTy
                }
  in declare fnsig


-- | Generate LLVM instructions for function definitions
--
codegenFun :: FunDecl -> CodeGen ()
codegenFun (FunDecl fnName args retTy tl) = do
  let fnName' =  fromVar fnName
  _fns <- gets globalFns
  fnsig <- getfn (toByteString fnName')
  fnBody <- do
    entry <- newBlock $ "fn." ++ fnName' ++ ".entry"
    _     <- setBlock entry
    -- add all args to localVars
    forM_ args $ \(v,ty) ->
      modify $ \s ->
        let nm  = toByteString $ fromVar v
            ty' = typeOf ty
        in s { localVars = Map.insert nm (localRef ty' (AST.Name nm)) (localVars s)}
    _ <- codegenTail tl retTy
    createBlocks

  -- Now that we have the fn body, override the fn definition in globalFns
  declare $ fnsig {G.basicBlocks = fnBody}


-- | Generate LLVM instructions for Tail
--
codegenTail :: Tail -> Ty -> CodeGen BlockState
codegenTail (RetValsT []) _ = return_
codegenTail (RetValsT [t]) _ = do
  t' <- codegenTriv t
  retval_ t'
codegenTail (RetValsT ts) (ProdTy tys) =
  let structTy = typeOf tys
  in do
    struct <- mapM codegenTriv ts >>= populateStruct structTy FreshVar
    struct' <- convert (toPtrTy $ typeOf $ ProdTy tys) FreshVar struct
    load (typeOf $ ProdTy tys) FreshVar struct' >>= retval_

codegenTail (LetPrimCallT bnds prm rnds body) ty = do
  rnds' <- mapM codegenTriv rnds
  _     <- case prm of
             PrintInt -> call printInt FreshVar rnds' >>= \_ -> return_
             PrintString s -> printString s >>= \_ -> return_
             AddP -> addp bnds rnds'
             SubP -> subp bnds rnds'
             MulP -> mulp bnds rnds'
             EqP  -> eqp bnds rnds'
             SizeParam -> sizeParam bnds
             ReadTag -> readTag bnds rnds'
             ReadInt -> readInt bnds rnds'
             DictEmptyP _ -> let [(outV,outTy)] = bnds
                             in do
                               _ <- assign (typeOf outTy) (NamedVar $ toByteString $ fromVar outV) (constop_ $ C.Null $ toPtrTy $ T.NamedTypeReference $ AST.Name "struct.dict_item")
                               return_
             -- Will only work when ty is IntTy or SymTy
             DictInsertP _ -> let [(outV,_)] = bnds
                                  [(VarTriv dict),key,val] = rnds
                               in do
                                 dict' <- getvar (toByteString $ fromVar dict)
                                 key'  <- codegenTriv key
                                 val'  <- codegenTriv val
                                 _     <- call dictInsertInt (NamedVar $ toByteString $ fromVar outV) [dict', key', val']
                                 return_
             DictLookupP _ -> let [(outV,_)] = bnds
                                  [(VarTriv dict),key] = rnds
                              in do
                                dict' <- getvar (toByteString $ fromVar dict)
                                key'  <- codegenTriv key
                                _     <- call dictLookupInt (NamedVar $ toByteString $ fromVar outV) [dict', key']
                                return_

             _ -> error $ "Prim: Not implemented yet: " ++ show prm
  codegenTail body ty

codegenTail (IfT test consq els) ty = do
  _ <- ifThenElse (toIfPred test) (codegenTail consq ty) (codegenTail els ty)
  return_

codegenTail (Switch trv alts def) ty =
  let (alts', def') = case def of
                        Nothing -> let (rest,lastone) = splitAlts alts
                                   in  (rest, altTail lastone)
                        Just d  -> (alts, d)
      alts'' = case alts' of
                 IntAlts xs -> xs
                 TagAlts _  -> error "codegenTail: Not yet implemented; TagAlts"

      -- | Split alts to return a default case, in case switch was not given one
      splitAlts :: Alts -> (Alts, Alts)
      splitAlts (TagAlts ls) = (TagAlts (init ls), TagAlts [last ls])
      splitAlts (IntAlts ls) = (IntAlts (init ls), IntAlts [last ls])

      -- | Take a "singleton" Alts and extract the Tail
      altTail :: Alts -> Tail
      altTail (TagAlts [(_,t)]) = t
      altTail (IntAlts [(_,t)]) = t
      altTail oth = error $ "Unexpected " ++ show oth
  in
    do
      switchDefault <- newBlock "switch.default"

      trv' <- codegenTriv trv
      caseBlocks <- mapM (\(_,i) -> newBlock $ "switch.case" ++ show i)
                    (zip alts'' [1..])

      let caseBlockNames = map blockLabel caseBlocks
          dests = map (\((casei,_),b) -> do
                          (int_ $ toInteger casei, b))
                  (zip alts'' caseBlockNames)

      _ <- switch trv' (blockLabel switchDefault) dests

      -- generate case blocks
      forM_ (zip alts'' caseBlocks) $ \((_,t), b) -> do
        setBlock b
        codegenTail t ty

      -- generate the default block
      setBlock switchDefault
      codegenTail def' ty

codegenTail (LetCallT bnds rator rnds body) ty = do
  rnds' <- mapM codegenTriv rnds
  let nm = toByteString $ fromVar rator
  fn <- getfn nm
  _ <- callp fn bnds rnds'
  codegenTail body ty

codegenTail (LetAllocT lhs vals body) ty =
  let structTy = typeOf $ map fst vals
      lhsV     = fromVar lhs
  in do
    struct <- mapM (codegenTriv . snd) vals >>= populateStruct structTy FreshVar
    _ <- convert (typeOf PtrTy) (NamedVar $ toByteString lhsV) struct
    codegenTail body ty

codegenTail (LetUnpackT bnds ptr body) ty = do
  struct <- getvar (toByteString $ fromVar ptr)
  _ <- unpackPtrStruct FreshVar struct bnds
  codegenTail body ty

codegenTail (LetTrivT (v,trvTy,trv) bod) ty = do
  trv' <- codegenTriv trv
  x <- convert (typeOf trvTy) FreshVar trv'
  _ <- assign (typeOf trvTy) (NamedVar $ toByteString $ fromVar v) x
  codegenTail bod ty

codegenTail (LetTimedT isIter bnds timed bod) ty =
  let clockMonotonicRaw = constop_ $ int32_ 4
      ident     = case bnds of
                    ((v,_):_) -> v
                    _ -> (toVar "")
      begnVar   = "begin_" ++ (fromVar ident)
      endVar    = "end_" ++ (fromVar ident)
      timespecT = AST.NamedTypeReference $ AST.Name "struct.timespec"
  in do
    -- allocate variables
    _    <- allocate timespecT (NamedVar $ toByteString begnVar)
    _    <- allocate timespecT (NamedVar $ toByteString endVar)
    begn <- getvar (toByteString begnVar)
    end  <- getvar (toByteString endVar)
    if isIter then
      do
        let savealloc = call saveAllocState FreshVar [] >>= \_ -> return_
            restalloc = call restoreAllocState FreshVar [] >>= \_ -> return_
            noop = return_
            loopBody = do
              _ <- call clockGetTime FreshVar [clockMonotonicRaw, begn]
              i <- load T.i64 FreshVar $ globalOp T.i64 (AST.Name "global_iters_param")
              i_minus_1 <- sub FreshVar [i, constop_ $ int_ 1]
              let notZero = notZeroP FreshVar i_minus_1

              _ <- ifThenElse notZero savealloc noop
              let timed' = rewriteReturns timed bnds
              _ <- codegenTail timed' ty
              _ <- ifThenElse notZero restalloc noop

              -- print BATCHTIME
              call clockGetTime FreshVar [clockMonotonicRaw, end]

        loopEnd <- load T.i64 FreshVar $ globalOp T.i64 (AST.Name "global_iters_param")
        _ <- for 0 1 loopEnd loopBody
        diff <- call difftimespecs FreshVar [begn, end]
        _ <- call printIterDiffTime Void [diff]
        return_
    else
      do
        -- execute and get running time
        _ <- call clockGetTime FreshVar [clockMonotonicRaw, begn]
        let timed' = rewriteReturns timed bnds
        _ <- codegenTail timed' ty
        _ <- call clockGetTime FreshVar [clockMonotonicRaw, end]

        -- print SELFTIMED
        diff <- call difftimespecs FreshVar [begn, end]
        _ <- call printDiffTime FreshVar [diff]
        return_

    -- process body
    codegenTail bod ty

codegenTail (AssnValsT ls) _ = do
  forM_ ls $ \(v,ty,triv) -> do
    triv' <- codegenTriv triv
    assign (typeOf ty) (NamedVar $ toByteString $ fromVar v) triv'
  return_

codegenTail (LetIfT bnds (cond,thn,els) bod) ty = do
  let thn' = rewriteReturns thn bnds
      els' = rewriteReturns els bnds
      cond' = codegenTriv cond >>= notZeroP FreshVar
  case (thn', els') of
    (AssnValsT thnA, AssnValsT elsA) -> do
      let thnA' = map (\(v,vty,triv) -> (thenVar v,vty,triv)) thnA
          elsA' = map (\(v,vty,triv) -> (elseVar v,vty,triv)) elsA
          thn'' = codegenTail (AssnValsT thnA') ty
          els'' = codegenTail (AssnValsT elsA') ty
      (tb, fb) <- ifThenElse cond' thn'' els''
      forM_ thnA $ \(v,vty,_) ->
        phi (typeOf vty) (NamedVar $ toByteString $ fromVar v)
             [(varToOp (thenVar v), blockLabel tb),
              (varToOp (elseVar v), blockLabel fb)]
      return_
    _ -> do
      let thn'' = codegenTail thn' ty
          els'' = codegenTail els' ty
      _ <- ifThenElse cond' thn'' els''
      return_
  codegenTail bod ty
  where thenVar v = varAppend v (toVar "then")
        elseVar v = varAppend v (toVar "else")
        varToOp   = localRef T.VoidType . AST.Name . toByteString . fromVar

codegenTail (TailCall v ts) _ = do
  rnds <- mapM codegenTriv ts
  fn   <- getfn (toByteString $ fromVar v)
  callp fn [] rnds

codegenTail (ErrT msg) _ty = do
  _ <- printString msg
  _ <- call exit Void [constop_ $ int_ 1]
  return_

codegenTail t _ = error $ "Tail: Not implemented yet: " ++ show t


-- | Generate LLVM instructions for Triv
--
codegenTriv :: Triv -> CodeGen AST.Operand
codegenTriv (IntTriv i) = (return . constop_ . int_ . toInteger) i
codegenTriv (VarTriv v) = getvar (toByteString $ fromVar v)
codegenTriv t = error $ "Triv: Not implemented yet: " ++ show t
