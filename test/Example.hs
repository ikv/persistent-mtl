{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Example
  ( TestApp
  , runTestApp

    -- * Functions
  , getPeople

    -- * Models
  , Person(..)
  , Post(..)
  , Unique(..)
  ) where

import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Logger (runNoLoggingT)
import Database.Persist (Entity, Unique)
import Database.Persist.Sqlite (withSqlitePool)
import Database.Persist.TH
    ( mkDeleteCascade
    , mkMigrate
    , mkPersist
    , persistLowerCase
    , share
    , sqlSettings
    )
import UnliftIO (MonadUnliftIO(..), wrappedWithRunInIO)

import Database.Persist.Monad

share
  [ mkPersist sqlSettings
  , mkDeleteCascade sqlSettings
  , mkMigrate "migrate"
  ]
  [persistLowerCase|
Person
  name String
  age Int
  UniqueName name
  deriving Show Eq

Post
  title String
  author PersonId
  deriving Show Eq
|]

deriving instance Eq (Unique Person)

newtype TestApp a = TestApp
  { unTestApp :: SqlQueryT IO a
  } deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadSqlQuery
    )

instance MonadUnliftIO TestApp where
  withRunInIO = wrappedWithRunInIO TestApp unTestApp

runTestApp :: TestApp a -> IO a
runTestApp m = runNoLoggingT $ withSqlitePool ":memory:" 5 $ \pool ->
  liftIO . runSqlQueryT pool . unTestApp $ do
    _ <- runMigrationSilent migrate
    m

{- Functions -}

getPeople :: MonadSqlQuery m => m [Entity Person]
getPeople = selectList [] []
