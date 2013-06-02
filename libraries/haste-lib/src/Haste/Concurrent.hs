{-# LANGUAGE GADTs #-}
-- | Implements concurrency for Haste based on "A Poor Man's Concurrency Monad".
module Haste.Concurrent (
    MVar, CIO,
    forkIO, forkMany, newMVar, newEmptyMVar, takeMVar, putMVar, withMVarIO,
    modifyMVarIO, concurrent, liftIO
  ) where
import Control.Monad.IO.Class
import Control.Monad.Cont.Class
import Control.Monad
import Data.IORef

data MV a
  = Full  [(a, CIO ())] -- A full MVar: a queue of writers
  | Empty [a -> CIO ()] -- An empty MVar: a queue of readers
newtype MVar a = MVar (IORef (MV a))

data Action where
  Atom :: IO Action -> Action
  Fork :: [Action] -> Action
  Stop :: Action

-- | Concurrent IO monad. The normal IO monad does not have concurrency
--   capabilities with Haste. This monad is basically IO plus concurrency.
newtype CIO a = C {unC :: (a -> Action) -> Action}

instance Monad CIO where
  return x    = C $ \next -> next x
  (C m) >>= f = C $ \b -> m (\a -> unC (f a) b)

instance MonadIO CIO where
  liftIO m = C $ \next -> Atom (fmap next m)

instance MonadCont CIO where
  callCC f = C $ \next -> unC (f (\a -> C $ \_ -> next a)) next

-- | Spawn a new thread.
forkIO :: CIO () -> CIO ()
forkIO (C m) = C $ \next -> Fork [m (const Stop), next ()]

-- | Spawn several threads at once.
forkMany :: [CIO ()] -> CIO ()
forkMany ms = C $ \next -> Fork (next () : [act (const Stop) | C act <- ms])

-- | Create a new MVar with an initial value.
newMVar :: MonadIO m => a -> m (MVar a)
newMVar a = liftIO $ MVar `fmap` newIORef (Full [(a, C $ const Stop)])

-- | Create a new empty MVar.
newEmptyMVar :: MonadIO m => m (MVar a)
newEmptyMVar = liftIO $ MVar `fmap` newIORef (Empty [])

-- | Read an MVar. Blocks if the MVar is empty.
--   Only the first writer in the write queue, if any, is woken.
takeMVar :: MVar a -> CIO a
takeMVar (MVar ref) =
  callCC $ \next -> join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full ((x,w):ws) -> do
        writeIORef ref (Full ws)
        return $ forkIO w >> return x
      Full _ -> do
        writeIORef ref (Empty [next])
        return $ C (const Stop)
      Empty rs -> do
        writeIORef ref (Empty (rs ++ [next]))
        return $ C (const Stop)

-- | Write an MVar. Blocks if the MVar is already full.
--   Only the first reader in the read queue, if any, is woken.
putMVar :: MVar a -> a -> CIO ()
putMVar (MVar ref) x =
  callCC $ \next -> join $ liftIO $ do
    v <- readIORef ref
    case v of
      Full ws -> do
        writeIORef ref (Full (ws ++ [(x, next ())]))
        return $ C (const Stop)
      Empty (r:rs) -> do
        writeIORef ref (Empty rs)
        return $ forkIO (r x)
      Empty _ -> do
        writeIORef ref (Full [(x, next ())])
        return $ C (const Stop)

-- | Perform an IO action over an MVar.
withMVarIO :: MVar a -> (a -> IO b) -> CIO b
withMVarIO v m = takeMVar v >>= liftIO . m

-- | Perform an IO action over an MVar, then write the MVar back.
modifyMVarIO :: MVar a -> (a -> IO (a, b)) -> CIO b
modifyMVarIO v m = do
  (x, res) <- withMVarIO v m
  putMVar v x
  return res

-- | Run a concurrent computation. Two different concurrent computations may
--   share MVars; if this is the case, then a call to `concurrent` may return
--   before all the threads it spawned finish executing.
concurrent :: CIO () -> IO ()
concurrent (C m) = scheduler [m (const Stop)]
  where
    scheduler (p:ps) =
      case p of
        Atom io -> do
          next <- io
          scheduler (ps ++ [next])
        Fork ps' -> do
          scheduler (ps ++ ps')
        Stop -> do
          scheduler ps
    scheduler _ =
      return ()
