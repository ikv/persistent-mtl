{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

module Mocked where

import qualified Data.Map.Strict as Map
import Database.Persist (Entity(..))
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
  [ testCase "it doesn't error with MockSqlQueryT" $
      runMockSqlQueryT (withTransaction $ insert_ $ person "Alice")
        [ withRecord @Person $ \case
            Insert_ _ -> Just ()
            _ -> Nothing
        ]
  ]

testPersistentAPI :: TestTree
testPersistentAPI = testGroup "Persistent API"
  [ testCase "get" $ do
      result <- runMockSqlQueryT (mapM get [1, 2])
        [ withRecord @Person $ \case
            Get n
              | n == 1 -> Just $ Just $ person "Alice"
              | n == 2 -> Just Nothing
            _ -> Nothing
        ]
      map (fmap personName) result @?= [Just "Alice", Nothing]

  , testCase "getMany" $ do
      result <- runMockSqlQueryT (getMany [1])
        [ withRecord @Person $ \case
            GetMany _ -> Just $ Map.fromList [(1, person "Alice")]
            _ -> Nothing
        ]
      personName <$> Map.lookup 1 result @?= Just "Alice"

  , testCase "getJust" $ do
      result <- runMockSqlQueryT (getJust 1)
        [ withRecord @Person $ \case
            GetJust _ -> Just $ person "Alice"
            _ -> Nothing
        ]
      personName result @?= "Alice"

  , testCase "getJustEntity" $ do
      result <- runMockSqlQueryT (getJustEntity 1)
        [ withRecord @Person $ \case
            GetJustEntity _ -> Just $ Entity 1 $ person "Alice"
            _ -> Nothing
        ]
      getName result @?= "Alice"

  , testCase "getEntity" $ do
      result <- runMockSqlQueryT (mapM getEntity [1, 2])
        [ withRecord @Person $ \case
            GetEntity n
              | n == 1 -> Just $ Just $ Entity 1 $ person "Alice"
              | n == 2 -> Just Nothing
            _ -> Nothing
        ]
      map (fmap getName) result @?= [Just "Alice", Nothing]

  , testCase "belongsTo" $ do
      let post1 = Post "Post #1" 1 (Just 1)
          post2 = Post "Post #2" 1 Nothing
      result <- runMockSqlQueryT (mapM (belongsTo postEditor) [post1, post2])
        [ withRecord @(Post, Person) $ \case
            BelongsTo _ Post{postEditor = Just 1} -> Just $ Just $ person "Alice"
            BelongsTo _ Post{postEditor = Nothing} -> Just Nothing
            _ -> Nothing
        ]
      map (fmap personName) result @?= [Just "Alice", Nothing]

  , testCase "belongsToJust" $ do
      let post1 = Post "Post #1" 1 Nothing
      result <- runMockSqlQueryT (belongsToJust postAuthor post1)
        [ withRecord @(Post, Person) $ \case
            BelongsToJust _ _ -> Just $ person "Alice"
            _ -> Nothing
        ]
      personName result @?= "Alice"

  , testCase "insert" $ do
      result <- runMockSqlQueryT (insert $ person "Alice")
        [ withRecord @Person $ \case
            Insert _ -> Just 1
            _ -> Nothing
        ]
      result @?= 1

  , testCase "insert_" $ do
      result <- runMockSqlQueryT (insert_ $ person "Alice")
        [ withRecord @Person $ \case
            Insert_ _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "insertMany" $ do
      result <- runMockSqlQueryT (insertMany [person "Alice", person "Bob"])
        [ withRecord @Person $ \case
            InsertMany records -> Just $ map fromIntegral [ 1 .. length records ]
            _ -> Nothing
        ]
      result @?= [1, 2]

  , testCase "insertMany_" $ do
      result <- runMockSqlQueryT (insertMany_ [person "Alice", person "Bob"])
        [ withRecord @Person $ \case
            InsertMany_ _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "insertEntityMany" $ do
      result <- runMockSqlQueryT (insertEntityMany [Entity 1 $ person "Alice"])
        [ withRecord @Person $ \case
            InsertEntityMany _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "insertKey" $ do
      result <- runMockSqlQueryT (insertKey 1 $ person "Alice")
        [ withRecord @Person $ \case
            InsertKey _ _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "repsert" $ do
      result <- runMockSqlQueryT (repsert 1 $ person "Alice")
        [ withRecord @Person $ \case
            Repsert _ _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "repsertMany" $ do
      result <- runMockSqlQueryT (repsertMany [(1, person "Alice")])
        [ withRecord @Person $ \case
            RepsertMany _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "replace" $ do
      result <- runMockSqlQueryT (replace 1 $ person "Alice")
        [ withRecord @Person $ \case
            Replace _ _ -> Just ()
            _ -> Nothing
        ]
      result @?= ()

  , testCase "selectList" $ do
      result <- runMockSqlQueryT (selectList [] [])
        [ withRecord @Person $ \case
            SelectList _ _ -> Just
              [ Entity 1 (person "Alice")
              , Entity 2 (person "Bob")
              ]
            _ -> Nothing
        ]
      map getName result @?= ["Alice", "Bob"]
  ]
