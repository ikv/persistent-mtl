{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Mocked where

import Database.Persist (Entity(..))
import Database.Persist.Sql (fromSqlKey, toSqlKey)
import Test.Tasty
import Test.Tasty.HUnit

import Database.Persist.Monad
import Database.Persist.Monad.TestUtils
import Example

tests :: TestTree
tests = testGroup "Mocked tests"
  [ testWithTransaction
  , testPersistentAPI
  ]

testWithTransaction :: TestTree
testWithTransaction = testGroup "withTransaction"
  [ testCase "withTransaction doesn't error" $
      runMockSqlQueryT (withTransaction $ insert_ $ person "Alice")
        [ withRecord @Person $ \case
            Insert_ _ -> Just ()
            _ -> Nothing
        ]
  ]

testPersistentAPI :: TestTree
testPersistentAPI = testGroup "Persistent API"
  [ testCase "get" $ do
      result <- runMockSqlQueryT (mapM (get . toSqlKey) [1, 2])
        [ withRecord @Person $ \case
            Get (fromSqlKey -> n)
              | n == 1 -> Just $ Just $ person "Alice"
              | n == 2 -> Just Nothing
            _ -> Nothing
        ]
      map (fmap personName) result @?= [Just "Alice", Nothing]

  , testCase "selectList" $ do
      result <- runMockSqlQueryT (selectList [] [])
        [ withRecord @Person $ \case
            SelectList _ _ -> Just
              [ Entity (toSqlKey 1) (person "Alice")
              , Entity (toSqlKey 2) (person "Bob")
              ]
            _ -> Nothing
        ]
      map getName result @?= ["Alice", "Bob"]
  ]
