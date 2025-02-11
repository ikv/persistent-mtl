{-|
Module: Database.Persist.Monad

Defines the 'SqlQueryT' monad transformer, which has a 'MonadSqlQuery' instance
to execute @persistent@ database operations. Also provides easy transaction
management with 'withTransaction', which supports retrying with exponential
backoff and restricts IO actions to only allow IO actions explicitly marked
as rerunnable.

Usage:

@
myFunction :: (MonadSqlQuery m, MonadIO m) => m ()
myFunction = do
  insert_ $ Person { name = \"Alice\", age = Just 25 }
  insert_ $ Person { name = \"Bob\", age = Nothing }

  -- some other business logic

  personList <- selectList [] []
  liftIO $ print (personList :: [Person])

  -- everything in here will run in a transaction
  withTransaction $ do
    selectFirst [PersonAge >. 30] [] >>= \\case
      Nothing -> insert_ $ Person { name = \"Claire\", age = Just 50 }
      Just (Entity key person) -> replace key person{ age = Just (age person - 10) }

    -- liftIO doesn't work in here, since transactions can be retried.
    -- Use rerunnableIO to run IO actions, after verifying that the IO action
    -- can be rerun if the transaction needs to be retried.
    rerunnableIO $ putStrLn "Transaction is finished!"

  -- some more business logic

  return ()
@
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Database.Persist.Monad
  (
  -- * Type class for executing database queries
    MonadSqlQuery
  , withTransaction

  -- * SqlQueryT monad transformer
  , SqlQueryT
  , mapSqlQueryT
  , runSqlQueryT
  , runSqlQueryTWith
  , SqlQueryEnv(..)
  , mkSqlQueryEnv

  -- * Transactions
  , SqlTransaction
  , rerunnableLift
  , TransactionError(..)

  -- * Lifted functions
  , module Database.Persist.Monad.Shim
  ) where

import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.IO.Unlift (MonadUnliftIO(..), wrappedWithRunInIO)
import Control.Monad.Logger (MonadLogger)
import Control.Monad.Reader (ReaderT(..), mapReaderT)
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Resource (MonadResource)
import Data.Pool (Pool)
import Database.Persist.Sql (SqlBackend, SqlPersistT, runSqlConn)
import qualified GHC.TypeLits as GHC
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Exception (Exception, SomeException, catchJust, throwIO)
import UnliftIO.Pool (withResource)

import Control.Monad.IO.Rerunnable (MonadRerunnableIO, rerunnableIO)
import Database.Persist.Monad.Class
import Database.Persist.Monad.Shim
import Database.Persist.Monad.SqlQueryRep

{- SqlTransaction -}

-- | The monad that tracks transaction state.
--
-- Conceptually equivalent to 'Database.Persist.Sql.SqlPersistT', but restricts
-- IO operations, for two reasons:
--   1. Forking a thread that uses the same 'SqlBackend' as the current thread
--      causes Bad Things to happen.
--   2. Transactions may need to be retried, in which case IO operations in
--      a transaction are required to be rerunnable.
--
-- You shouldn't need to explicitly use this type; your functions should only
-- declare the 'MonadSqlQuery' constraint.
newtype SqlTransaction m a = SqlTransaction
  { unSqlTransaction :: SqlPersistT m a
  }
  deriving (Functor, Applicative, Monad, MonadRerunnableIO)

instance
  ( GHC.TypeError ('GHC.Text "Cannot run arbitrary IO actions within a transaction. If the IO action is rerunnable, use rerunnableIO")
  , Monad m
  )
  => MonadIO (SqlTransaction m) where
  liftIO = undefined

instance (MonadSqlQuery m, MonadUnliftIO m) => MonadSqlQuery (SqlTransaction m) where
  type TransactionM (SqlTransaction m) = TransactionM m

  runQueryRep = SqlTransaction . runSqlQueryRep

  -- Delegate to 'm', since 'm' is in charge of starting/stopping transactions.
  -- 'SqlTransaction' is ONLY in charge of executing queries.
  withTransaction = SqlTransaction . withTransaction

runSqlTransaction :: MonadUnliftIO m => SqlBackend -> SqlTransaction m a -> m a
runSqlTransaction conn = (`runSqlConn` conn) . unSqlTransaction

-- | 'SqlTransaction' does not have an instance for 'MonadTrans' to prevent
-- accidental lifting of unsafe monadic actions. Use this function to explicitly
-- mark a monadic action as rerunnable.
rerunnableLift :: MonadUnliftIO m => m a -> SqlTransaction m a
rerunnableLift m = SqlTransaction $ lift $ withRunInIO $ \runInIO -> rerunnableIO $ runInIO m

-- | Errors that can occur within a SQL transaction.
data TransactionError
  = RetryLimitExceeded
    -- ^ The retry limit was reached when retrying a transaction.
  deriving (Show, Eq)

instance Exception TransactionError

{- SqlQueryT monad -}

-- | Environment to configure running 'SqlQueryT'.
--
-- For simple usage, you can just use 'runSqlQueryT', but for more advanced
-- usage, including the ability to retry transactions, use 'mkSqlQueryEnv' with
-- 'runSqlQueryTWith'.
data SqlQueryEnv = SqlQueryEnv
  { backendPool :: Pool SqlBackend
    -- ^ The pool for your persistent backend. Get this from @withSqlitePool@
    -- or the equivalent for your backend.

  , retryIf     :: SomeException -> Bool
    -- ^ Retry a transaction when an exception matches this predicate. Will
    -- retry with an exponential backoff.
    --
    -- Defaults to always returning False (i.e. never retry)

  , retryLimit  :: Int
    -- ^ The number of times to retry, if 'retryIf' is satisfied.
    --
    -- Defaults to 10.
  }

-- | Build a SqlQueryEnv from the default.
--
-- Usage:
--
-- @
-- let env = mkSqlQueryEnv pool $ \\env -> env { retryIf = 10 }
-- in runSqlQueryTWith env m
-- @
mkSqlQueryEnv :: Pool SqlBackend -> (SqlQueryEnv -> SqlQueryEnv) -> SqlQueryEnv
mkSqlQueryEnv backendPool f = f SqlQueryEnv
  { backendPool
  , retryIf = const False
  , retryLimit = 10
  }

-- | The monad transformer that implements 'MonadSqlQuery'.
newtype SqlQueryT m a = SqlQueryT
  { unSqlQueryT :: ReaderT SqlQueryEnv m a
  } deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadTrans
    , MonadResource
    , MonadRerunnableIO
    , MonadThrow
    , MonadCatch
    , MonadMask
    , MonadLogger
    )

instance MonadUnliftIO m => MonadSqlQuery (SqlQueryT m) where
  type TransactionM (SqlQueryT m) = SqlTransaction (SqlQueryT m)

  -- Running a query directly in SqlQueryT will create a one-off transaction.
  runQueryRep = withTransaction . runQueryRep

  -- Start a new transaction and run the given 'SqlTransaction'
  withTransaction m = do
    SqlQueryEnv{..} <- SqlQueryT ask
    withResource backendPool $ \conn ->
      let filterRetry e = if retryIf e then Just e else Nothing
          loop i = catchJust filterRetry (runSqlTransaction conn m) $ \_ ->
            if i < retryLimit
              then do
                threadDelay $ 1000 * 2^i
                loop $! i + 1
              else throwIO RetryLimitExceeded
      in loop 0

instance MonadUnliftIO m => MonadUnliftIO (SqlQueryT m) where
  withRunInIO = wrappedWithRunInIO SqlQueryT unSqlQueryT

mapSqlQueryT :: (m a -> n b) -> SqlQueryT m a -> SqlQueryT n b
mapSqlQueryT f = SqlQueryT . mapReaderT f . unSqlQueryT

instance MonadReader r m => MonadReader r (SqlQueryT m) where
    ask = lift ask
    local = mapSqlQueryT . local

{- Running SqlQueryT -}

-- | Run the 'SqlQueryT' monad transformer with the given backend.
runSqlQueryT :: Pool SqlBackend -> SqlQueryT m a -> m a
runSqlQueryT backendPool = runSqlQueryTWith $ mkSqlQueryEnv backendPool id

-- | Run the 'SqlQueryT' monad transformer with the explicitly provided
-- environment.
runSqlQueryTWith :: SqlQueryEnv -> SqlQueryT m a -> m a
runSqlQueryTWith env = (`runReaderT` env) . unSqlQueryT
