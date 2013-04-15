import System.Process
import System.IO
import System.Random
import System.Exit
import System.Environment ( getArgs )
import Control.Monad
import Debug.Trace
import Data.Int
import Data.List.Split
import System.Timeout
import System.Directory
import Mutate
import Data.Text (pack, unpack, strip)
import Data.Text.Read (hexadecimal)
import qualified Data.Map as M

import Data.List

import Language.Java.Syntax
import Language.Java.Pretty
import Symbolic
import Sketch

import Tarski.Config ( readConfig, filePath, testCases, methodName )

type Tests = [([Int],Int)]

main :: IO ()
main = do args <- getArgs
          cfg <- case args of
                      [s] -> readConfig s
                      _   -> error "QC requires a single argument denoting a configuration file"
          let filepath = filePath cfg
              testcases = read (testCases cfg) :: Tests
              method = methodName cfg
          mainLoop filepath testcases method

{-
paren_test = [
              ([0], 1),
              ([1,1],0),
              ([1,-1],0),
              ([2,1,1],0),
              ([2,1,-1],1),
              ([2,-1,1],0),
              ([2,-1,-1],0)
             ]
             -}


make_in = do
    n <- randomRIO (0 :: Int, 2)
    xs <- binary n
    fst <- return $ head xs
    return $ (n:xs, is_nested xs 0)

binary :: Int -> IO [Int]
binary 0 = return $ []
binary n = do
    b <- randomIO
    bs <- binary (n-1)
    return $ (if b then 1 else -1):bs

is_nested [] 0 = 1
is_nested [] _ = 0
is_nested (1:xs) n = is_nested xs (n+1)
is_nested (-1:_) 0 = 0
is_nested (-1:xs) n = is_nested xs (n-1)

mainLoop :: String -> Tests -> String -> IO ()
mainLoop file tests method = do
    program <- readFile file
    (state, ideas, qs) <- return $ genSketches program method
    best <- test_ideas state (reverse ideas) (reverse qs) tests
    case best of
        Nothing -> putStrLn $ unlines $ map prettyPrint ideas
        Just (code, model) -> do
            final_code <- return $ (constantFold model code) :: IO MemberDecl
            putStrLn ((prettyPrint final_code) :: String)--((show model) ++ " " ++ (prettyPrint code))

test_ideas :: SketchState -> [MemberDecl] -> [MemberDecl] -> Tests -> IO (Maybe (MemberDecl, M.Map String Int))
test_ideas st [] _ _ = return $ Nothing
test_ideas st (idea:ideas) (q:qs) tests = do
    result <- test_idea st idea q tests
    case result of
        Nothing -> test_ideas st ideas qs tests
        Just model -> return $ Just (idea, model)

test_idea :: SketchState -> MemberDecl -> MemberDecl -> Tests -> IO (Maybe (M.Map String Int))
test_idea st idea q tests = do
    putStrLn $ prettyPrint q
    {-tests <- return $ paren_test-} --mapM (\_ -> make_in) [1..10]
    z3in <- return $ ({-"(set-logic QF_AUFBV)\n" ++ -}(evalSketch idea st tests))
    writeFile "z3.smt2" z3in
    (exit, out, err) <- readProcessWithExitCode "z3" ["z3.smt2"] ""
    (head:model) <- return $ lines out
    if head == "unsat"
     then return Nothing
     else return $ Just (str_to_map $ tail model)

str_to_map :: [String] -> M.Map String Int
str_to_map [] = M.empty
str_to_map [x] = M.empty
str_to_map (x:y:rest) =
    if (length xs > 1 && isPrefixOf "sketch" (xs !! 1))
    then
    let
        val = if ylen == 1 then yval else -yval
        ylen = length $ words y
        yval = if ylen == 1 then to_int y else to_int $ (words y) !! 1
        m = str_to_map rest
    in M.insert (xs !! 1) val m
    else str_to_map (y:rest)
    where
    xs = words x


to_int :: String -> Int
to_int s = ans
    where
    trimmed = unpack $ strip $ pack $ s
    drop_sharp = drop 2 trimmed
    drop_paren = init $ drop_sharp
    Right (ans, _) = hexadecimal $ pack $ drop_paren
