{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
-- | Environments of a read or write transaction.
module Data.BTree.Alloc.Concurrent.Environment where

import Control.Monad.State

import Data.Set (Set)
import qualified Data.Set as S

import STMContainers.Map (Map)

import Data.BTree.Alloc.Concurrent.FreePages.Tree
import Data.BTree.Primitives

newtype ReaderEnv hnd = ReaderEnv { readerHnd :: hnd }

data WriterEnv hnd = WriterEnv
    { writerHnd :: !hnd
    , writerTxId :: !TxId
    , writerReaders :: Map TxId Integer

    , writerNewlyFreedPages :: ![NewlyFreed]
    -- ^ Pages free'd in this transaction, not ready for reuse until the
    -- transaction is commited.

    , writerDirtyPages :: !(Set Dirty)
    -- ^ Pages written to in this transcation. These pages can be reused in the
    -- same transaction if free'd later.

    , writerFreedDirtyPages :: ![DirtyFree]
    -- ^ Pages free for immediate reuse.

    , writerFreedDirtyPagesOn :: Bool
    -- ^ Whether or not it is allowed to use pages from
    -- 'writerFreedDirtyPages'.

    , writerFreeTree :: !FreeTree
    -- ^ The root of the free tree, might change during a transaction.

    , writerDirtyReusablePages :: !(Set DirtyOldFree)
    -- ^ All pages queried from the free page database for
    -- 'writerReusablePagesTxId', and actually used once already.

    , writerReusablePages :: ![OldFree]
    -- ^ Pages queried from the free pages database and ready for immediate
    -- reuse.

    , writerReusablePagesTxId :: !(Maybe TxId)
    -- ^ The 'TxId' of the pages in 'writerReusablePages', or 'Nothing' if no
    -- pages were queried yet from the free database.

    , writerReusablePagesOn :: !Bool
    -- ^ Used to turn of querying the free page database for free pages.
    }

-- | Create a new writer.
newWriter :: hnd -> TxId -> Map TxId Integer -> FreeTree -> WriterEnv hnd
newWriter hnd tx readers freeTree = WriterEnv {
    writerHnd = hnd
  , writerTxId = tx
  , writerReaders = readers
  , writerNewlyFreedPages = []
  , writerDirtyPages = S.empty
  , writerFreedDirtyPages = []
  , writerFreedDirtyPagesOn = True
  , writerFreeTree = freeTree
  , writerDirtyReusablePages = S.empty
  , writerReusablePages = []
  , writerReusablePagesTxId = Nothing
  , writerReusablePagesOn = True
  }

-- | Wrapper around 'PageId' indicating it is a fresh page, allocated at the
-- end of the database.
newtype Fresh = Fresh PageId deriving (Eq, Ord, Show)

-- | Wrapper around 'PageId' indicating it is newly free'd and cannot be reused
-- in the same transaction.
newtype NewlyFreed = NewlyFreed PageId deriving (Eq, Ord, Show)

-- | Wrapper around 'PageId' indicating it is a dirty page.
newtype Dirty = Dirty PageId deriving (Eq, Ord, Show)

-- | Wrapper around 'PageId' indicating the page is dirty and free for reuse.
newtype DirtyFree = DirtyFree PageId deriving (Eq, Ord, Show)

-- | Wrapper around 'PageId' inidcating it was fetched from the free database
-- and is ready for reuse.
newtype OldFree = OldFree PageId deriving (Eq, Ord, Show)

-- | Wrapper around 'PageId' indicating it wa fetched from the free database
-- and is actually dirty.
newtype DirtyOldFree = DirtyOldFree PageId deriving (Eq, Ord, Show)

-- | A sum type repesenting any type of free page, that can immediately be used
-- to write something to.
data SomeFreePage = FreshFreePage Fresh
                  | DirtyFreePage DirtyFree
                  | OldFreePage OldFree

getSomeFreePageId :: SomeFreePage -> PageId
getSomeFreePageId (FreshFreePage (Fresh     pid)) = pid
getSomeFreePageId (DirtyFreePage (DirtyFree pid)) = pid
getSomeFreePageId (OldFreePage   (OldFree   pid)) = pid

-- | Try to free a page, given a set of dirty pages.
--
-- If the page was dirty, a 'DirtyFree' page is added to the environment, if
-- not a 'NewlyFreed' page is added to the environment.
freePage :: MonadState (WriterEnv hnd) m => PageId -> m ()
freePage pid = do
    dirty'        <- dirty pid
    dirtyOldFree' <- dirtyOldFree pid

    if | Just (Dirty p) <- dirty' -> modify' $
            \e -> e { writerFreedDirtyPages = DirtyFree p : writerFreedDirtyPages e }

       | Just (DirtyOldFree p) <- dirtyOldFree' -> modify' $
            \e -> e { writerReusablePages = OldFree p : writerReusablePages e }

       | p <- pid -> modify' $
            \e -> e { writerNewlyFreedPages = NewlyFreed p : writerNewlyFreedPages e }

-- | Get a 'Dirty' page, by first proving it is in fact dirty.
dirty :: MonadState (WriterEnv hnd) m => PageId -> m (Maybe Dirty)
dirty pid = (page . writerDirtyPages) <$> get
  where
    page dirty'
        | S.member (Dirty pid) dirty' = Just (Dirty pid)
        | otherwise                   = Nothing

-- | Get a 'DirtyOldFree' page, by first proving it is in fact a dirty old free page.
dirtyOldFree :: MonadState (WriterEnv hnd) m => PageId -> m (Maybe DirtyOldFree)
dirtyOldFree pid = (page . writerDirtyReusablePages) <$> get
  where
    page dirty'
        | S.member (DirtyOldFree pid) dirty' = Just (DirtyOldFree pid)
        | otherwise                          = Nothing


-- | Touch a fresh page, make it dirty.
touchPage :: MonadState (WriterEnv hnd) m => SomeFreePage -> m ()
touchPage (DirtyFreePage _) = return ()
touchPage (FreshFreePage (Fresh pid)) = modify' $ \e -> e { writerDirtyPages = S.insert dirty' (writerDirtyPages e) }
  where dirty' = Dirty pid
touchPage (OldFreePage (OldFree pid)) = modify' $ \e -> e { writerDirtyReusablePages = S.insert dirty' (writerDirtyReusablePages e) }
  where dirty' = DirtyOldFree pid
