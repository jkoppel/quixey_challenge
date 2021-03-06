module Tarski.Sketch where

import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Monoid (getSum)

import Control.Monad.Reader (ask, ReaderT, runReaderT)
import Control.Monad.State (evalStateT, runState, lift, State, StateT)
import Control.Lens ( makeLenses, (+=), (.=), use )

import Language.Java.Parser
import Language.Java.Syntax
import Language.KURE
import Language.KURE.Utilities
import Language.KURE.Injection (promoteR, promoteT, inject)

import Kure
import KureCong (Context, initialContext)
import Tarski.Mutate (countExp, getTypeMap, is_int, nextLabel, TypeMap)

data SketchState = SketchState {
                          _sketchVars :: Set.Set String,
                          _nVars :: Int
                   } deriving (Show)

makeLenses ''SketchState

type Sketch = State SketchState

startSketchState :: SketchState
startSketchState = SketchState  {
                                _sketchVars = Set.empty,
                                _nVars = 0
                 }

newSketchVar :: Sketch String
newSketchVar = do n <- use nVars
                  nVars += 1
                  vs <- use sketchVars
                  let nv = "sketch" ++ (show n)
                  sketchVars .= Set.insert nv vs
                  return nv

sketchConst :: Sketch Exp
sketchConst = do v <- newSketchVar
                 return (ExpName $ Name [Ident v])

sketchOp :: Op -> Sketch Exp -> Sketch Exp -> Sketch Exp
sketchOp o e1 e2 = do e1' <- e1
                      e2' <- e2
                      return $ BinOp e1' o e2'

sketchCond :: Sketch Exp -> Sketch Exp -> Sketch Exp
sketchCond e1 e2 = do
    e1' <- e1
    e2' <- e2
    return $ Cond (BinOp e1' Equal e2') (Lit $ Int $ 1) (Lit $ Int $ 0)

sketchArg :: Sketch Exp
sketchArg = do
    c <- sketchConst
    return $ ArrayAccess $ ArrayIndex (ExpName $ Name [Ident "A"]) c

alternatives :: [Sketch Exp] -> Sketch Exp
alternatives [] = return $ Lit $ Int $ 0
alternatives [x] = x
alternatives (x:xs) = do
    v <- newSketchVar
    frst <- x
    rest <- alternatives xs
    return $ Cond (BinOp (ExpName $ Name [Ident v]) Equal (Lit $ Int 0)) frst rest

sketchVar :: Map.Map Ident a -> Sketch Exp
sketchVar m = alternatives (map (\v -> return $ ExpName $ Name [v]) (map fst $ Map.toList m))

boundedExp :: Map.Map Ident a -> Int -> Sketch Exp
boundedExp m 0 = alternatives [sketchConst, sketchVar m , sketchArg]
boundedExp m n = alternatives [sketchConst,
                               sketchVar m,
                               sketchArg,
                               sketchOp Add e e,
                               sketchOp Sub e e,
                               sketchOp Mult e e,
                               sketchOp Div e e,
                               sketchCond e e]
              where
                e = boundedExp m (n-1)

findMethod' :: String -> TranslateJ MemberDecl MemberDecl
findMethod' n = translate $ \_ d -> case d of
                                        MethodDecl _ _ _ (Ident n') _ _ _ | n == n' -> return d
                                        _                                           -> fail "method not found"

findMethod :: String -> TranslateJ GenericJava MemberDecl
findMethod n = onetdT $ promoteT (findMethod' n)

getMethod :: String -> CompilationUnit -> MemberDecl
getMethod interest prog = runKureM id (error "did not find method") (apply (findMethod interest) initialContext (inject prog))

makeSketchExp :: MemberDecl -> Map.Map Ident a -> Int -> (SketchState, Exp)
makeSketchExp d m hole_depth = swap $ runState (boundedExp m hole_depth) startSketchState

replaceExp' :: Int -> Exp -> Rewrite Context (ReaderT TypeMap (StateT Int KureM)) Exp
replaceExp' n f = translate $ \_ e -> do l <- lift nextLabel
                                         if l /= n
                                          then
                                           return e
                                          else
                                           do tm <- ask
                                              if not (is_int e tm)
                                               then
                                                 return e
                                               else
                                                return f


replaceExp :: Int -> Exp -> Rewrite Context (ReaderT TypeMap (StateT Int KureM)) GenericJava
replaceExp n e = anybuR $ promoteR $ replaceExp' n e

doReplaceExp :: MemberDecl -> Int -> Exp -> MemberDecl
doReplaceExp d i e = let tm = runKureM id (error "type map failed") (apply getTypeMap initialContext (inject d))
                         t = runReaderT (apply (replaceExp i e) initialContext (inject d)) tm
                         t' = evalStateT t 0 in
                     runKureM (\(GMemberDecl c) -> c) (error "memberdecl proj failed") t'

genSketches :: String -> String -> Int -> (SketchState, [MemberDecl], [MemberDecl])
genSketches src interest hole_depth = case parser compilationUnit src of
                                          Left err -> error $ "Parse error" ++ (show err)
                                          Right tree -> let m = getMethod interest tree
                                                            tm = runKureM id (error "type map failed") (apply getTypeMap initialContext (inject m))
                                                            tm' = Map.delete (Ident "A") $ Map.delete (Ident interest) tm
                                                            (skst, sexp) = makeSketchExp m tm' hole_depth
                                                            nExp = getSum $ runKureM id (error "count exp failed") (apply countExp initialContext (inject m))
                                                            sketches = [doReplaceExp m i sexp | i <- [0..(nExp-1)]]
                                                            questions = [doReplaceExp m i (ExpName $ Name [Ident "????"]) | i <- [0..(nExp-1)]] in
                                                          (skst, sketches, questions)
