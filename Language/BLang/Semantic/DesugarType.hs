{-# LANGUAGE FlexibleContexts #-}

module Language.BLang.Semantic.DesugarType (
  tyDesugar,
  fnArrDesugar
) where

import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Monad.Error (strMsg)
import Control.Applicative ((<|>))

import Language.BLang.Data
import Language.BLang.Error
import Language.BLang.Miscellaneous
import qualified Language.BLang.FrontEnd.Parser as P
import Language.BLang.Semantic.Type

data Var = Var deriving Show
type ExtType = Either Var P.Type

isVar :: Either Var P.Type -> Bool
isVar (Left _) = True
isVar (Right _) = False

-- desugar user-defined type
tyDesugar :: MonadWriter [CompileError] m => P.AST -> m P.AST
tyDesugar ast = liftM fst $ runReaderT (runStateT (mapM tyDeMTop ast) emptyA) emptyA

tyDeMTop :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
         => P.ASTTop -> m P.ASTTop
tyDeMTop (P.VarDeclList decls) = liftM P.VarDeclList $ tyDeMDecls decls
tyDeMTop (P.FuncDecl lines@(lret:lname:ls) ty name args code) = do
  insertTy lname (name, Left Var)
  ty' <- deTy lret ty
  args' <- zipWithM (mapsnd . deTy) ls args
  code' <- runLocal $ do
    zipWithM insertTy ls $ map (\(name, ty) -> (name, Left Var)) args'
    tyDeMBlock' code
  return (P.FuncDecl lines ty' name args' code')

tyDeMDecls :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
           => [P.ASTDecl] -> m [P.ASTDecl]
tyDeMDecls decls = do
  (ls, vs) <- liftM unzip $ tyDeMDecls' decls
  return [P.VarDecl ls vs]

tyDeMDecls' :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
            => [P.ASTDecl] -> m [(Line, (String, P.Type, Maybe P.ASTStmt))]
tyDeMDecls' ((P.VarDecl ls decls):rest) = do
  decls' <- zipWithM (map2nd . deTy) ls decls
  zipWithM_ insertTy ls $ map (\(name, ty, _) -> (name, Left Var)) decls
  rest' <- tyDeMDecls' rest
  return (zip ls decls' ++ rest')
tyDeMDecls' ((P.TypeDecl ls decls):rest) = do
  insertTys ls decls
  rest' <- tyDeMDecls' rest
  return $ (zip ls $ zip3 (map fst decls) (repeat $ P.TCustom "?") $ repeat Nothing) ++ rest'
tyDeMDecls' [] = return []

tyDeMBlock' :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
            => P.ASTStmt -> m P.ASTStmt
tyDeMBlock' (P.Block decls stmts) = do
  decls' <- tyDeMDecls decls
  stmts' <- mapM tyDeMStmt stmts
  return $ P.Block decls' stmts'

tyDeMStmt :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
          => P.ASTStmt -> m P.ASTStmt
tyDeMStmt block@(P.Block _ _) = runLocal $ tyDeMBlock' block
tyDeMStmt for@(P.For _ _ _ _ code) = do
  code' <- tyDeMStmt code
  return for{ P.forCode = code' }
tyDeMStmt while@(P.While _ _ code) = do
  code' <- tyDeMStmt code
  return while{ P.whileCode = code' }
tyDeMStmt (P.If line con th el) = do
  th' <- tyDeMStmt th
  el' <- maybeM el tyDeMStmt
  return (P.If line con th' el')
tyDeMStmt s = return s -- Expr, Ap, Return, Identifier, LiteralVal, ArrayRef, Nop

insertTys :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
          => [Line] -> [(String, P.Type)] -> m ()
insertTys ls tys = do
  tys' <- zipWithM (mapsnd . deTy) ls tys -- recursive definition is not allowed
  zipWithM_ insertTy ls (map (second Right) tys')

insertTy :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
         => Line -> (String, Either Var P.Type) -> m ()
insertTy line (name, ty) = do
  currScope <- get
  when ((not $ isVar ty) && (name `memberA` currScope)) $
    tell [errorAt line "type name redeclared"]
  put (insertA name ty currScope)

deTy :: (MonadReader (Assoc String ExtType) m, MonadState (Assoc String ExtType) m, MonadWriter [CompileError] m)
     => Line -> P.Type -> m P.Type
deTy line (P.TPtr t) = liftM P.TPtr (deTy line t)
deTy line (P.TArray ixs t) = do
  t' <- deTy line t
  case t' of -- merge array types
    (P.TArray ixs' t'') -> return $ P.TArray (ixs ++ ixs') t''
    _ -> return $ P.TArray ixs t'
deTy line (P.TCustom name) = do
  currScope <- get
  upperScope <- ask
  case lookupA name currScope <|> lookupA name upperScope of
    Just (Right ty) -> return ty
    Just (Left Var) -> do
      tell [errorAt line $ "'" ++ name ++ "' is declared to be a variable"]
      return P.TVoid
    Nothing -> do
      tell [errorAt line $ "variable has unknown base type '" ++ name ++ "'"]
      return P.TVoid -- give unknown type variable `TVoid`
deTy _ t = return t -- TInt, TFloat, TVoid, TChar

-- desugar function array type
fnArrDesugar :: P.AST -> P.AST
fnArrDesugar = map fnArrDeTop

fnArrDeTop :: P.ASTTop -> P.ASTTop
fnArrDeTop f@(P.FuncDecl _ _ _ args _) = f{ P.funcArgs = map toPtr args }
fnArrDeTop decl = decl

toPtr :: (String, P.Type) -> (String, P.Type)
toPtr (name, ty) = (name, tyParserArrayDecay ty)

runLocal :: (Ord key, MonadReader (Assoc key val) m, MonadState (Assoc key val) m)
         => m a -> m a
runLocal m = do
  upperState <- ask
  currState <- get
  put emptyA
  a <- local (const $ currState `unionA` upperState) m
  put currState
  return a
