module Application.TypeScript (contractModule, resultType, validator) where

import Data.List (intercalate, nub)
import Application.Data
import Application.JSX (jsString, literalJS)
import qualified Ontology.Relational as R
import qualified Ontology.Syntax as O

resultType :: PageData -> String
resultType (ScalarData (FixedText text)) = jsString text
resultType (ScalarData (SemanticScalar _ atom)) = atomType atom
resultType (ArrayData child) = "ReadonlyArray<" ++ resultType child ++ ">"
resultType (NullableData child) = "(" ++ resultType child ++ " | null)"
resultType (ObjectData fields) = "Readonly<{\n"
  ++ concat ["  " ++ jsString (dataKey f) ++ optional (dataPresence f)
      ++ ": " ++ resultType (dataShape f) ++ ";\n" | f <- fields] ++ "}>"
  where optional Required = ""; optional BranchOnly{} = "?"

atomType :: R.Atom -> String
atomType (R.ScalarAtom O.TString) = "string"
atomType (R.ScalarAtom O.TTimestamp) = "string"
atomType (R.ScalarAtom O.TNumber) = "number"
atomType (R.ScalarAtom O.TBoolean) = "boolean"
atomType (R.LiteralAtom value) = literalJS value
atomType (R.EnumAtom []) = "never"
atomType (R.EnumAtom values) = "(" ++ intercalate " | " (map literalJS values) ++ ")"
atomType R.ReferenceAtom{} = "never"

validator :: PageData -> String -> String
validator = check 0
  where
    check :: Int -> PageData -> String -> String
    check depth shape x = case shape of
      ScalarData (FixedText text) -> x ++ " === " ++ jsString text
      ScalarData (SemanticScalar _ atom) -> atomic atom x
      NullableData child -> "(" ++ x ++ " === null || " ++ check depth child x ++ ")"
      ArrayData child -> let v = "entry" ++ show depth
        in "(Array.isArray(" ++ x ++ ") && " ++ x ++ ".every((" ++ v
          ++ ": unknown) => " ++ check (depth + 1) child v ++ "))"
      ObjectData fields -> conjunction
        (["isRecord(" ++ x ++ ")"
         ,"Object.keys(" ++ x ++ ").every(k => new Set<string>(["
           ++ intercalate "," (map (jsString . dataKey) fields) ++ "]).has(k))"]
         ++ map (one depth x) fields ++ exclusive x fields)
    one depth x field =
      let key = jsString (dataKey field)
          own = "Object.hasOwn(" ++ x ++ ", " ++ key ++ ")"
          access = x ++ "[" ++ key ++ "]"
          valid = check depth (dataShape field) access
      in case dataPresence field of
          Required -> "(" ++ own ++ " && " ++ valid ++ ")"
          BranchOnly _ -> "(!" ++ own ++ " || " ++ valid ++ ")"
    exclusive x fields = case nub [dataKey f | f <- fields, BranchOnly _ <- [dataPresence f]] of
      [] -> []
      keys -> ["(" ++ intercalate " + "
        ["(Object.hasOwn(" ++ x ++ ", " ++ jsString key ++ ") ? 1 : 0)" | key <- keys] ++ " <= 1)"]
    atomic (R.ScalarAtom O.TString) x = "typeof " ++ x ++ " === \"string\""
    atomic (R.ScalarAtom O.TTimestamp) x = "typeof " ++ x ++ " === \"string\""
    atomic (R.ScalarAtom O.TBoolean) x = "typeof " ++ x ++ " === \"boolean\""
    atomic (R.ScalarAtom O.TNumber) x = "(typeof " ++ x ++ " === \"number\" && Number.isFinite(" ++ x ++ "))"
    atomic (R.LiteralAtom value) x = x ++ " === " ++ literalJS value
    atomic (R.EnumAtom []) _ = "false"
    atomic (R.EnumAtom values) x = "(" ++ intercalate " || " [x ++ " === " ++ literalJS value | value <- values] ++ ")"
    atomic R.ReferenceAtom{} _ = "false"
    conjunction xs = "(" ++ intercalate " && " xs ++ ")"

contractModule :: PageData -> String
contractModule shape = unlines
  [ "// Generated from a particular view; this is not an arbitrary JSON renderer."
  , "export type ViewData = " ++ resultType shape ++ ";"
  , "function isRecord(value: unknown): value is Record<string, unknown> {"
  , "  return typeof value === 'object' && value !== null && !Array.isArray(value);"
  , "}"
  , "export function isViewData(value: unknown): value is ViewData {"
  , "  return " ++ validator shape "value" ++ ";"
  , "}"
  ]

