{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}

module Language.PureScript.Bridge.Printer where

import           Control.Monad
import           Data.Map.Strict                     (Map)
import qualified Data.Map.Strict                     as Map
import           Data.Monoid
import           Data.Set                            (Set)
import qualified Data.Set                            as Set
import           Data.Text                           (Text)
import qualified Data.Text                           as T
import qualified Data.Text.IO                        as T
import           System.Directory
import           System.FilePath


import           Language.PureScript.Bridge.SumType
import           Language.PureScript.Bridge.TypeInfo


data Module (lang :: Language) = PSModule {
  psModuleName  :: !Text
, psImportLines :: !(Map Text ImportLine)
, psTypes       :: ![SumType lang]
} deriving Show

type PSModule = Module 'PureScript

data ImportLine = ImportLine {
  importModule :: !Text
, importTypes  :: !(Set Text)
} deriving Show

type Modules = Map Text PSModule
type ImportLines = Map Text ImportLine

printModule :: FilePath -> PSModule -> IO ()
printModule root m = do
  unlessM (doesDirectoryExist mDir) $ createDirectoryIfMissing True mDir
  T.writeFile mPath . moduleToText $ m
  where
    mFile = (joinPath . map T.unpack . T.splitOn "." $ psModuleName m) <> ".purs"
    mPath = root </> mFile
    mDir = takeDirectory mPath

sumTypesToNeededPackages :: [SumType lang] -> Set Text
sumTypesToNeededPackages = Set.unions . map sumTypeToNeededPackages

sumTypeToNeededPackages :: SumType lang -> Set Text
sumTypeToNeededPackages st =
  Set.filter (not . T.null) . Set.map _typePackage $ getUsedTypes st

moduleToText :: Module 'PureScript -> Text
moduleToText m = T.unlines $
  "-- File auto generated by purescript-bridge! --"
  : "module " <> psModuleName m <> " where\n"
  : map importLineToText (Map.elems (psImportLines m))
  ++ [ "\nimport Data.Generic (class Generic)\n\n" ]
  ++ map sumTypeToText (psTypes m)


importLineToText :: ImportLine -> Text
importLineToText l = "import " <> importModule l <> " (" <> typeList <> ")"
  where
    typeList = T.intercalate ", " (Set.toList (importTypes l))

sumTypeToText :: SumType 'PureScript -> Text
sumTypeToText (SumType t cs) = T.unlines $
    "data " <> typeInfoToText True t <> " ="
  : "    " <> T.intercalate "\n  | " (map (constructorToText 4) cs)
  : [ "\nderive instance generic" <> _typeName t <> " :: Generic " <> _typeName t ]


constructorToText :: Int -> DataConstructor 'PureScript -> Text
constructorToText _ (DataConstructor n (Left ts))  = n <> " " <> T.intercalate " " (map (typeInfoToText False) ts)
constructorToText indentation (DataConstructor n (Right rs)) =
       n <> " {\n"
    <> spaces (indentation + 2) <> T.intercalate intercalation (map recordEntryToText rs) <> "\n"
    <> spaces indentation <> "}"
  where
    intercalation = "\n" <> spaces indentation <> "," <> " "
    spaces c = T.replicate c " "

recordEntryToText :: RecordEntry 'PureScript -> Text
recordEntryToText e = _recLabel e <> " :: " <> typeInfoToText True (_recValue e)


typeInfoToText :: Bool -> PSType -> Text
typeInfoToText topLevel t = if needParens then "(" <> inner <> ")" else inner
  where
    inner = _typeName t <>
      if pLength > 0
        then " " <> T.intercalate " " textParameters
        else ""
    params = _typeParameters t
    pLength = length params
    needParens = not topLevel && pLength > 0
    textParameters = map (typeInfoToText False) params

sumTypesToModules :: Modules -> [SumType 'PureScript] -> Modules
sumTypesToModules = foldr sumTypeToModule

sumTypeToModule :: SumType 'PureScript -> Modules -> Modules
sumTypeToModule st@(SumType t _) = Map.alter (Just . updateModule) (_typeModule t)
  where
    updateModule Nothing = PSModule {
          psModuleName = _typeModule t
        , psImportLines = dropSelf $ typesToImportLines Map.empty (getUsedTypes st)
        , psTypes = [st]
        }
    updateModule (Just m) = m {
        psImportLines = dropSelf $ typesToImportLines (psImportLines m) (getUsedTypes st)
      , psTypes = st : psTypes m
      }
    dropSelf = Map.delete (_typeModule t)

typesToImportLines :: ImportLines -> Set PSType -> ImportLines
typesToImportLines = foldr typeToImportLines

typeToImportLines :: PSType -> ImportLines -> ImportLines
typeToImportLines t ls = typesToImportLines (update ls) (Set.fromList (_typeParameters t))
  where
    update = if not (T.null (_typeModule t))
                then Map.alter (Just . updateLine) (_typeModule t)
                else id

    updateLine Nothing = ImportLine (_typeModule t) (Set.singleton (_typeName t))
    updateLine (Just (ImportLine m types)) = ImportLine m $ Set.insert (_typeName t) types

importsFromList :: [ImportLine] -> Map Text ImportLine
importsFromList ls = let
    pairs = zip (map importModule ls) ls
    merge a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)
  in
    Map.fromListWith merge pairs

mergeImportLines :: ImportLines -> ImportLines -> ImportLines
mergeImportLines = Map.unionWith mergeLines
  where
    mergeLines a b = ImportLine (importModule a) (importTypes a `Set.union` importTypes b)

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM mbool action = mbool >>= flip unless action
