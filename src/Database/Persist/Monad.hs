{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Database.Persist.Monad
  ( MonadSqlQuery(..)

    -- * SqlQueryT monad transformer
  , SqlQueryT
  , SqlQueryBackend(..)
  , runSqlQueryT

    -- * Test utility
  , MockSqlQueryT
  , runMockSqlQueryT
  , withRecord

    -- * Coerced functions
  , SqlQueryRep(..)
  , selectList
  , insert
  , insert_
  , runMigrationSilent
  ) where

import Control.Monad (msum)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.IO.Unlift (MonadUnliftIO(..), wrappedWithRunInIO)
import Control.Monad.Reader (ReaderT, ask, lift, local, runReaderT)
import Data.Pool (Pool)
import Data.Text (Text)
import Data.Typeable (Typeable, eqT, (:~:)(..))
import Database.Persist (Entity, Filter, Key, PersistRecordBackend, SelectOpt)
import Database.Persist.Sql (Migration, SqlBackend, runSqlPool)
import qualified Database.Persist.Sql as Persist

import Database.Persist.Monad.SqlQueryRep

class MonadSqlQuery m where
  runQueryRep :: Typeable record => SqlQueryRep record a -> m a
  withTransaction :: m a -> m a

{- SqlQueryT -}

data SqlQueryEnv = SqlQueryEnv
  { backend     :: SqlQueryBackend
  , currentConn :: Maybe SqlBackend
  }

newtype SqlQueryT m a = SqlQueryT
  { unSqlQueryT :: ReaderT SqlQueryEnv m a
  } deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    )

instance MonadUnliftIO m => MonadUnliftIO (SqlQueryT m) where
  withRunInIO = wrappedWithRunInIO SqlQueryT unSqlQueryT

data SqlQueryBackend
  = BackendSingle SqlBackend
  | BackendPool (Pool SqlBackend)

runSqlQueryT :: SqlQueryBackend -> SqlQueryT m a -> m a
runSqlQueryT backend = (`runReaderT` env) . unSqlQueryT
  where
    env = SqlQueryEnv { currentConn = Nothing, .. }

withCurrentConnection :: MonadUnliftIO m => (SqlBackend -> SqlQueryT m a) -> SqlQueryT m a
withCurrentConnection f = SqlQueryT ask >>= \case
  -- Currently in a transaction; use the transaction connection
  SqlQueryEnv { currentConn = Just conn } -> f conn
  -- Otherwise, get a new connection
  SqlQueryEnv { backend = BackendSingle conn } -> f conn
  SqlQueryEnv { backend = BackendPool pool } -> runSqlPool (lift . f =<< ask) pool

instance MonadUnliftIO m => MonadSqlQuery (SqlQueryT m) where
  runQueryRep queryRep =
    withCurrentConnection $ \conn ->
      Persist.runSqlConn (runSqlQueryRep queryRep) conn

  withTransaction action =
    withCurrentConnection $ \conn ->
      SqlQueryT . local (\env -> env { currentConn = Just conn }) . unSqlQueryT $ action

selectList :: (PersistRecordBackend record SqlBackend, Typeable record, MonadSqlQuery m) => [Filter record] -> [SelectOpt record] -> m [Entity record]
selectList a b = runQueryRep $ SelectList a b

insert :: (PersistRecordBackend record SqlBackend, Typeable record, MonadSqlQuery m) => record -> m (Key record)
insert a = runQueryRep $ Insert a

insert_ :: (PersistRecordBackend record SqlBackend, Typeable record, MonadSqlQuery m) => record -> m ()
insert_ a = runQueryRep $ Insert_ a

runMigrationSilent :: (MonadUnliftIO m, MonadSqlQuery m) => Migration -> m [Text]
runMigrationSilent a = runQueryRep $ RunMigrationsSilent a

{- MockSqlQueryT -}

data MockQuery = MockQuery (forall record a. Typeable record => SqlQueryRep record a -> Maybe a)

withRecord :: forall record. Typeable record => (forall a. SqlQueryRep record a -> Maybe a) -> MockQuery
withRecord f = MockQuery $ \(rep :: SqlQueryRep someRecord result) ->
  case eqT @record @someRecord of
    Just Refl -> f rep
    Nothing -> Nothing

newtype MockSqlQueryT m a = MockSqlQueryT
  { unMockSqlQueryT :: ReaderT [MockQuery] m a
  } deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    )

runMockSqlQueryT :: MockSqlQueryT m a -> [MockQuery] -> m a
runMockSqlQueryT action mockQueries = (`runReaderT` mockQueries) . unMockSqlQueryT $ action

instance Monad m => MonadSqlQuery (MockSqlQueryT m) where
  runQueryRep rep = do
    mockQueries <- MockSqlQueryT ask
    maybe (error $ "Could not find mock for query: " ++ show rep) return
      $ msum $ map tryMockQuery mockQueries
    where
      tryMockQuery (MockQuery f) = f rep

  withTransaction = id
