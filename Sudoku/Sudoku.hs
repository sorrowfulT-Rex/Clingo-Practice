{-# LANGUAGE OverloadedStrings #-}

import           Control.Exception
import           Control.Monad
import           Control.Monad.ST
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Except
import           Data.Array
import           Data.Array.ST
import           Data.Char
import           Data.List
import           Data.List.Split
import           Data.Maybe
import           System.Directory
import           System.Environment
import           System.Exit
import           System.IO
import           System.Process
import qualified Text.Read as R

newtype Board = Board (Array (Int, Int) (Maybe Int))

instance Show Board where
  show :: Board -> String
  show (Board board) = concatMap worker (assocs board)
    where
      worker ((r, c), mN) = pref ++ maybe "X" show mN
        where
          pref
            | r `elem` [4, 7] && c == 1 = "\n\n"
            | r > 1 && c == 1           = "\n"
            | c `elem` [4, 7]           = "  "
            | c > 1                     = " "
            | otherwise                 = ""

base :: String
base = "numero(1..9).\n\
       \1 { grid(R, C, N) : numero(N) } 1 :- numero(R), numero(C).\n\
       \:- grid(R, C1, N), grid(R, C2, N), C1 != C2.\n\
       \:- grid(R1, C, N), grid(R2, C, N), R1 != R2.\n\
       \group(1..3, 1..3).\n\
       \group(4..6, 4..6).\n\
       \group(7..9, 7..9).\n\
       \:- grid(R1, C1, N), grid(R2, C2, N), group(R1, R2), group(C1, C2), (R1, C1) != (R2, C2).\n"

handleErr :: ExceptT String IO () -> ExceptT String IO ()
handleErr = handleE (lift . putStrLn . ("An error has occured when running Sudoku:\n" ++)) . mapExceptT (handle worker)
  where
    worker (e :: SomeException) = pure (Left (show e))

parseBoard :: String -> Either String Board
parseBoard str
  | length elems /= 81 = Left "Expect exactly 9 * 9 numbers!"
  | otherwise          = Board . listArray ((1, 1), (9, 9)) <$> mapM num elems
  where
    elems  = concatMap words (lines str)
    num []           = Left "Expecting either a number between 0 and 9 or 'X' for each grid!"
    num n'@(n : rem) = if null rem && (isDigit n || n == 'X')
        then Right (R.readMaybe [n])
        else Left $ "Invalid number '" <> n' <> "'! It should be either a number between 0 and 9 or 'X'."

parseResult :: String -> [(Int, Int, Int)]
parseResult str = mapMaybe worker (words str)
  where
  worker str
    | pref /= "grid" = Nothing
    | otherwise      = let [r, c, n] = splitOn "," (init (tail suff))
                       in  Just (read r, read c, read n)
    where
      (pref, suff) = splitAt 4 str

buildBoard :: [(Int, Int, Int)] -> Board
buildBoard grids = Board $ runST $ do
  arrST <- newArray ((1, 1), (9, 9)) Nothing :: ST s (STArray s (Int, Int) (Maybe Int))
  forM_ grids $ \(r, c, n) -> do
    writeArray arrST (r, c) (Just n)
  freeze arrST

isSat :: Int -> Maybe Bool
isSat n
  | n == 10 || n == 30 = Just True
  | n == 20            = Just False
  | otherwise          = Nothing

main :: IO ()
main = void . runExceptT . handleErr $ do
  args <- lift getArgs
  case args of
    []      -> throwE "Please provide the Sudoku input!"
    src : _ -> do
      str                     <- lift $ readFile src
      Board board             <- except $ parseBoard str
      (file, handle)          <- lift $ openTempFile "./" "mmzk"
      lift $ hClose handle
      lift $ writeFile file base
      forM_ (assocs board) $ \((r, c), mN) -> case mN of
        Nothing -> pure ()
        Just n  -> lift . appendFile file
                 $ concat ["grid(", intercalate "," (show <$> [r, c, n]), ")."]
      (exitCode, result, err) <- lift $ readProcessWithExitCode "clingo3" [file] ""
      lift $ removeFile file
      case exitCode of
        ExitSuccess   -> except $ Left err
        ExitFailure n -> case isSat n of
          Just True  -> lift $ print (buildBoard $ parseResult result)
          Just False -> lift $ putStrLn "No solution!"
          Nothing    -> except $ Left err
