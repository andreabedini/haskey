{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
-- | This module implements data structures and functions related to the database.
module Data.BTree.Alloc.Concurrent.Database where

import Control.Applicative ((<$>))
import Control.Concurrent.STM
import Control.Monad (void)
import Control.Monad.IO.Class

import Data.Proxy (Proxy(..))
import Data.List.NonEmpty (NonEmpty((:|)))

import STMContainers.Map (Map)
import qualified STMContainers.Map as Map

import Data.BTree.Alloc.Class
import Data.BTree.Alloc.Concurrent.Environment
import Data.BTree.Alloc.Concurrent.FreePages.Save
import Data.BTree.Alloc.Concurrent.FreePages.Tree
import Data.BTree.Alloc.Concurrent.Meta
import Data.BTree.Alloc.Concurrent.Monad
import Data.BTree.Alloc.Concurrent.Overflow
import Data.BTree.Alloc.Transaction
import Data.BTree.Impure
import Data.BTree.Primitives
import Data.BTree.Store
import Data.BTree.Utils.RLock
import qualified Data.BTree.Utils.STM.Map as Map

-- | An active concurrent database.
--
-- This can be shared amongst threads.
data ConcurrentDb k v = ConcurrentDb
    { concurrentDbHandles :: ConcurrentHandles
    , concurrentDbWriterLock :: RLock
    , concurrentDbCurrentMeta :: TVar CurrentMetaPage
    , concurrentDbMeta1 :: TVar (ConcurrentMeta k v)
    , concurrentDbMeta2 :: TVar (ConcurrentMeta k v)
    , concurrentDbReaders :: Map TxId Integer
    }

-- | Open all concurrent handles.
openConcurrentHandles :: ConcurrentMetaStoreM m
                      => ConcurrentHandles -> m ()
openConcurrentHandles ConcurrentHandles{..} = do
    openHandle concurrentHandlesMain
    openHandle concurrentHandlesMetadata1
    openHandle concurrentHandlesMetadata2

-- | Open a new concurrent database, with the given handles.
--
-- The handles should already have been opened using 'openConcurrentHandles'.
createConcurrentDb :: (Key k, Value v, MonadIO m, ConcurrentMetaStoreM m)
                   => ConcurrentHandles -> m (ConcurrentDb k v)
createConcurrentDb hnds = do
    db <- newConcurrentDb hnds meta0
    setCurrentMeta meta0 db
    setCurrentMeta meta0 db
    return db
  where
    meta0 = ConcurrentMeta { concurrentMetaRevision = 0
                           , concurrentMetaTree = Tree zeroHeight Nothing
                           , concurrentMetaFreeTree = Tree zeroHeight Nothing
                           , concurrentMetaOverflowTree = Tree zeroHeight Nothing
                           }

-- | Open the an existing database, with the given handles.
--
-- The handles should already have been opened using 'openConcurrentHandles'.
openConcurrentDb :: (Key k, Value v, MonadIO m, ConcurrentMetaStoreM m)
                 => ConcurrentHandles -> m (Maybe (ConcurrentDb k v))
openConcurrentDb hnds@ConcurrentHandles{..} = do
    m1 <- readConcurrentMeta concurrentHandlesMetadata1 Proxy Proxy
    m2 <- readConcurrentMeta concurrentHandlesMetadata2 Proxy Proxy
    case (m1, m2) of
        (Nothing, Nothing) -> return Nothing
        (Just m , Nothing) -> Just <$> newConcurrentDb hnds m
        (Nothing, Just m ) -> Just <$> newConcurrentDb hnds m
        (Just x , Just y ) -> if concurrentMetaRevision x > concurrentMetaRevision y
                                  then Just <$> newConcurrentDb hnds x
                                  else Just <$> newConcurrentDb hnds y

-- | Close the handles of the database.
closeConcurrentHandles :: (MonadIO m, ConcurrentMetaStoreM m)
                       => ConcurrentHandles
                       -> m ()
closeConcurrentHandles ConcurrentHandles{..} = do
    closeHandle concurrentHandlesMain
    closeHandle concurrentHandlesMetadata1
    closeHandle concurrentHandlesMetadata2

-- | Create a new concurrent database with handles and metadata provided.
newConcurrentDb :: (Key k, Value v, MonadIO m)
                => ConcurrentHandles
                -> ConcurrentMeta k v
                -> m (ConcurrentDb k v)
newConcurrentDb hnds meta0 = do
    readers <- liftIO Map.newIO
    meta    <- liftIO $ newTVarIO Meta1
    lock    <- liftIO   newRLock
    meta1   <- liftIO $ newTVarIO meta0
    meta2   <- liftIO $ newTVarIO meta0
    return $! ConcurrentDb
        { concurrentDbHandles = hnds
        , concurrentDbWriterLock = lock
        , concurrentDbCurrentMeta = meta
        , concurrentDbMeta1 = meta1
        , concurrentDbMeta2 = meta2
        , concurrentDbReaders = readers
        }

-- | Get the current meta data.
getCurrentMeta :: (Key k, Value v)
               => ConcurrentDb k v -> STM (ConcurrentMeta k v)
getCurrentMeta db
    | ConcurrentDb { concurrentDbCurrentMeta = v } <- db
    = readTVar v >>= \case
        Meta1 -> readTVar $ concurrentDbMeta1 db
        Meta2 -> readTVar $ concurrentDbMeta2 db

-- | Write the new metadata, and switch the pointer to the current one.
setCurrentMeta :: (MonadIO m, ConcurrentMetaStoreM m, Key k, Value v)
               => ConcurrentMeta k v -> ConcurrentDb k v -> m ()
setCurrentMeta new db
    | ConcurrentDb
      { concurrentDbCurrentMeta = v
      , concurrentDbHandles = hnds
      } <- db
    = liftIO (atomically $ readTVar v) >>= \case
        Meta1 -> do
            putConcurrentMeta (concurrentHandlesMetadata2 hnds) new
            liftIO . atomically $ do
                writeTVar v Meta2
                writeTVar (concurrentDbMeta2 db) new
        Meta2 -> do
            putConcurrentMeta (concurrentHandlesMetadata1 hnds) new
            liftIO . atomically $ do
                writeTVar v Meta1
                writeTVar (concurrentDbMeta1 db) new

{-| Execute a write transaction, with a result. -}
transact :: (MonadIO m, ConcurrentMetaStoreM m, Key key, Value val)
         => (forall n. AllocM n => Tree key val -> n (Transaction key val a))
         -> ConcurrentDb key val -> m a
transact act db = withRLock' (concurrentDbWriterLock db) $ do
    cleanup
    transactNow act db
  where
    cleanup :: (MonadIO m, ConcurrentMetaStoreM m) => m ()
    cleanup
        | ConcurrentDb
          { concurrentDbHandles = hnds
          , concurrentDbReaders = readers
          } <- db
        = do
        meta <- liftIO . atomically $ getCurrentMeta db
        let newRevision = concurrentMetaRevision meta + 1
        let tree = concurrentMetaOverflowTree meta
        (v, env) <- runConcurrentT (deleteOutdatedOverflowIds tree) $
                            newWriter hnds
                                      newRevision
                                      readers
                                      (concurrentMetaFreeTree meta)
        case v of
            Nothing -> return ()
            Just tree' -> do
                -- Save the free'd pages to the free page database
                freeTree' <- saveFreePages' 0 env

                -- Commit
                let newMeta = meta {
                      concurrentMetaRevision     = newRevision
                    , concurrentMetaFreeTree     = freeTree'
                    , concurrentMetaOverflowTree = tree'
                    }
                setCurrentMeta newMeta db

{-| Execute a write transaction, without cleaning up old overflow pages. -}
transactNow :: (MonadIO m, ConcurrentMetaStoreM m, Key key, Value val)
            => (forall n. AllocM n => Tree key val -> n (Transaction key val a))
            -> ConcurrentDb key val -> m a
transactNow act db
    | ConcurrentDb
      { concurrentDbHandles = hnds
      , concurrentDbWriterLock = lock
      , concurrentDbReaders = readers
      } <- db
    = withRLock' lock $ do

    meta <- liftIO . atomically $ getCurrentMeta db
    let newRevision = concurrentMetaRevision meta + 1
    (tx, env) <- runConcurrentT (act $ concurrentMetaTree meta) $
                    newWriter hnds
                              newRevision
                              readers
                              (concurrentMetaFreeTree meta)
    case tx of
        Abort v -> return v
        Commit newTree v -> do
            -- Save the newly free'd overflow pages to be deleted when they are
            -- no longer in use.
            (overflowTree', env') <- saveOverflowIds env
                (concurrentMetaOverflowTree meta)

            -- Save the free'd pages to the free page database
            freeTree' <- saveFreePages' 0 env'

            -- Commit
            let newMeta = ConcurrentMeta
                    { concurrentMetaRevision     = newRevision
                    , concurrentMetaTree         = newTree
                    , concurrentMetaFreeTree     = freeTree'
                    , concurrentMetaOverflowTree = overflowTree'
                    }
            setCurrentMeta newMeta db
            return v
  where
    saveOverflowIds :: (MonadIO m, ConcurrentMetaStoreM m)
                    => WriterEnv ConcurrentHandles
                    -> OverflowTree
                    -> m (OverflowTree, WriterEnv ConcurrentHandles)
    saveOverflowIds env tree =
        case map (\(OldOverflow i) ->i) (writerRemovedOverflows env) of
            [] -> return (tree, env)
            x:xs -> flip runConcurrentT env $
                insertOverflowIds (writerTxId env)
                                  (x :| xs)
                                  tree

saveFreePages' :: (MonadIO m, ConcurrentMetaStoreM m)
               => Int
               -> WriterEnv ConcurrentHandles
               -> m FreeTree
saveFreePages' paranoid env
    | paranoid >= 100 = error "paranoid: looping!"
    | otherwise
    = do

    -- Saving the free pages
    -- =====================
    --
    -- Saving free pages to the free database is a complicated task. At the end
    -- of a transaction we have 3 types of free pages:
    --
    --  1. 'DirtyFree': Pages that were freshly allocated from the end of the
    --                  dabase file, but are no longer used. These are free'd
    --                  by truncating the datase file. They can freely be used
    --                  during this routine.
    --
    --  2. 'NewlyFreed': Pages that were written by a previous transaction, but
    --                   free'd in this transaction. They might still be in use
    --                   by an older reader, and can thus not be used anyways.
    --
    --                   Note that this list **may grow during this routine**,
    --                   as new pages can be free'd.
    --
    --  3. 'OldFree': Pages that were fetched from the free database while
    --                executing the transaction. Technically, they can be used
    --                during this routine, BUT that would mean the list of
    --                'OldFree' pages can grow and shrink during the call,
    --                which would complicate the convergence/termination
    --                conditions of this routine. So currently, **we disable
    --                the use of these pages in this routine.**

    (freeTree', env') <- runConcurrentT (saveFreePages env) $
        env { writerReusablePagesOn = False }

    -- Did we free any new pages? We have to put them in the free tree!
    if writerNewlyFreedPages env' == writerNewlyFreedPages env
       then return freeTree'
       else saveFreePages' (paranoid + 1) $ env' { writerFreeTree = freeTree' }

{-| Execute a write transaction, without a result. -}
transact_ :: (MonadIO m, ConcurrentMetaStoreM m, Key key, Value val)
          => (forall n. AllocM n => Tree key val -> n (Transaction key val ()))
          -> ConcurrentDb key val -> m ()
transact_ act db = void $ transact act db

{-| Execute a read-only transaction. -}
transactReadOnly :: (MonadIO m, ConcurrentMetaStoreM m, Key key, Value val)
                 => (forall n. AllocReaderM n => Tree key val -> n a)
                 -> ConcurrentDb key val -> m a
transactReadOnly act db
    | ConcurrentDb
      { concurrentDbHandles = hnds
      , concurrentDbReaders = readers
      } <- db
    = do
    meta <- liftIO . atomically $ do
        meta <- getCurrentMeta db
        Map.alter (concurrentMetaRevision meta) addOne readers
        return meta
    v <- evalConcurrentT (act $ concurrentMetaTree meta) (ReaderEnv hnds)
    liftIO . atomically $ Map.alter (concurrentMetaRevision meta) subOne readers
    return v
  where
    addOne Nothing = Just 1
    addOne (Just x) = Just $! x + 1
    subOne Nothing = Nothing
    subOne (Just 0) = Nothing
    subOne (Just x) = Just $! x - 1