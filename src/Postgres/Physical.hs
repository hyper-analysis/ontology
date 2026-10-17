module Postgres.Physical
  ( program
  ) where

import Data.List (nub)
import Ontology.Postgres
import qualified SQL.Syntax as SQL

program :: PgSchema -> SQL.Program
program schema =
  let
    SQL.Program tables = localProgram schema
    integrityStatements =
      concat
        [ lowerIntegrity index rule
        | (index, rule) <- zip [(1 :: Int)..] (pgIntegrity schema)
        ]
  in SQL.Program (tables ++ integrityStatements)

lowerIntegrity :: Int -> PgIntegrity -> [SQL.Statement]
lowerIntegrity index rule =
  let
    constraintName = "ontology_rule_" ++ show index
    functionName = constraintName ++ "_fn"
    affectedTables = nub (ruleTables rule)
    function =
      SQL.CreateFunction
        SQL.Function
          { SQL.functionName = functionName
          , SQL.functionBody =
              [ SQL.If
                  (invalid rule)
                  [ SQL.RaiseConstraint
                      constraintName
                      ("Ontology integrity rule " ++ show index ++ " violated")
                  ]
              , SQL.ReturnNull
              ]
          }
    triggers =
      [ SQL.CreateConstraintTrigger
          SQL.Trigger
            { SQL.triggerName =
                constraintName ++ "_tr" ++ show triggerIndex
            , SQL.triggerTable = table
            , SQL.triggerEvents =
                [SQL.Insert, SQL.Update, SQL.Delete]
            , SQL.triggerDeferred = True
            , SQL.triggerFunction = functionName
            }
      | (triggerIndex, table) <- zip [(1 :: Int)..] affectedTables
      ]
  in function : triggers

ruleTables :: PgIntegrity -> [String]
ruleTables rule =
  case rule of
    RequiredAlternative
      { integrityOwnerTable = owner
      , integrityBranchTable = branch
      } ->
        [owner, branch]

    DependentRequiresPresence
      { integrityParentTable = parent
      , integrityDependentTable = dependent
      } ->
        [parent, dependent]

    StructuredDistinctness
      { integritySelectorSources = sources
      } ->
        map selectorSourceTable sources

invalid :: PgIntegrity -> SQL.Expr
invalid rule =
  case rule of
    RequiredAlternative
      { integrityOwnerTable = owner
      , integrityOwnerKey = ownerKey
      , integrityTagField = tag
      , integrityTagValue = branchValue
      , integrityBranchTable = branch
      , integrityBranchKey = branchKey
      } ->
        SQL.Or
          [ SQL.Exists
              SQL.Select
                { SQL.selectFrom = owner
                , SQL.selectAlias = "o"
                , SQL.selectWhere =
                    SQL.And
                      [ SQL.Equals
                          (column "o" tag)
                          (SQL.TextValue branchValue)
                      , SQL.Not
                          (SQL.Exists
                            SQL.Select
                              { SQL.selectFrom = branch
                              , SQL.selectAlias = "b"
                              , SQL.selectWhere =
                                  keyEquals
                                    "o" ownerKey
                                    "b" branchKey
                              })
                      ]
                }

          , SQL.Exists
              SQL.Select
                { SQL.selectFrom = branch
                , SQL.selectAlias = "b"
                , SQL.selectWhere =
                    SQL.Not
                      (SQL.Exists
                        SQL.Select
                          { SQL.selectFrom = owner
                          , SQL.selectAlias = "o"
                          , SQL.selectWhere =
                              SQL.And
                                [ keyEquals
                                    "o" ownerKey
                                    "b" branchKey
                                , SQL.Equals
                                    (column "o" tag)
                                    (SQL.TextValue branchValue)
                                ]
                          })
                }
          ]

    DependentRequiresPresence
      { integrityParentTable = parent
      , integrityParentKey = parentKey
      , integrityPresenceField = presence
      , integrityDependentTable = dependent
      , integrityDependentKey = dependentKey
      } ->
        SQL.Exists
          SQL.Select
            { SQL.selectFrom = dependent
            , SQL.selectAlias = "d"
            , SQL.selectWhere =
                SQL.Not
                  (SQL.Exists
                    SQL.Select
                      { SQL.selectFrom = parent
                      , SQL.selectAlias = "p"
                      , SQL.selectWhere =
                          SQL.And
                            [ keyEquals
                                "p" parentKey
                                "d" dependentKey
                            , SQL.Equals
                                (column "p" presence)
                                (SQL.BoolValue True)
                            ]
                      })
            }

    StructuredDistinctness
      { integritySelectorSources = sources
      } ->
        SQL.Or
          [ duplicate sourceA sourceB
          | sourceA <- sources
          , sourceB <- sources
          ]

column :: SQL.Alias -> String -> SQL.Value
column alias name =
  SQL.ColumnValue (Just alias) name

keyEquals
  :: SQL.Alias
  -> [String]
  -> SQL.Alias
  -> [String]
  -> SQL.Expr
keyEquals leftAlias leftFields rightAlias rightFields =
  SQL.And
    [ SQL.Equals
        (column leftAlias leftField)
        (column rightAlias rightField)
    | (leftField, rightField) <- zip leftFields rightFields
    ]

duplicate :: SelectorSource -> SelectorSource -> SQL.Expr
duplicate left right =
  SQL.Exists
    SQL.Select
      { SQL.selectFrom = selectorSourceTable left
      , SQL.selectAlias = "a"
      , SQL.selectWhere =
          SQL.Exists
            SQL.Select
              { SQL.selectFrom = selectorSourceTable right
              , SQL.selectAlias = "b"
              , SQL.selectWhere =
                  SQL.And
                    [ keyEquals
                        "a" (selectorSourceOwnerKey left)
                        "b" (selectorSourceOwnerKey right)

                    , keyEquals
                        "a" (selectorSourceFields left)
                        "b" (selectorSourceFields right)

                    , SQL.Not
                        (SQL.Equals
                          (column "a" (selectorSourceOccurrence left))
                          (column "b" (selectorSourceOccurrence right)))
                    ]
              }
      }

