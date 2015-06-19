module Hackage.Security.Client.Repository.Local (
    LocalRepo
  , Cache
  , withRepository
    -- * Low-level API (for the benefit of other Repository implementations)
  , getCached
  , getCachedRoot
  , getCachedIndex
  , clearCache
  , getFromIndex
  , cacheRemoteFile
  ) where

import Control.Exception
import Control.Monad
import Codec.Archive.Tar.Index (TarIndex)
import qualified Codec.Archive.Tar       as Tar
import qualified Codec.Archive.Tar.Index as TarIndex
import qualified Codec.Compression.GZip  as GZip
import qualified Data.ByteString         as BS
import qualified Data.ByteString.Builder as BS.Builder
import qualified Data.ByteString.Lazy    as BS.L

import Hackage.Security.Client.Repository
import Hackage.Security.Client.Formats
import Hackage.Security.Util.IO
import Hackage.Security.Util.Path
import Hackage.Security.Util.Some

{-------------------------------------------------------------------------------
  Top-level
-------------------------------------------------------------------------------}

type LocalRepo = Path (Rooted Absolute)
type Cache     = Path (Rooted Absolute)

-- | Initialize the repository (and cleanup resources afterwards)
withRepository
  :: LocalRepo             -- ^ Location of local repository
  -> Cache                 -- ^ Location of local cache
  -> (LogMessage -> IO ()) -- ^ Logger
  -> (Repository -> IO a)  -- ^ Callback
  -> IO a
withRepository repo cache logger callback = callback Repository {
    repWithRemote    = withRemote repo cache
  , repGetCached     = getCached     cache
  , repGetCachedRoot = getCachedRoot cache
  , repClearCache    = clearCache    cache
  , repGetFromIndex  = getFromIndex  cache
  , repWithMirror    = mirrorsUnsupported
  , repLog           = logger
  , repDescription   = "Local repository at " ++ show repo
  }

{-------------------------------------------------------------------------------
  Implementations of the various methods of Repository
-------------------------------------------------------------------------------}

-- | Get a file from the server
withRemote :: LocalRepo -> Cache
           -> RemoteFile fs -> (SelectedFormat fs -> TempPath -> IO a) -> IO a
withRemote repo cache remoteFile callback = do
    result <- callback format remotePath
    cacheRemoteFile cache
                    remotePath
                    (selectedFormatSome format)
                    (mustCache remoteFile)
    return result
  where
    (format, remotePath') = formatsPrefer
                              (remoteFileNonEmpty remoteFile)
                              FUn
                              (remoteFilePath remoteFile)
    remotePath = repo </> remotePath'

-- | Cache a previously downloaded remote file
cacheRemoteFile :: Cache -> TempPath -> Some Format -> IsCached -> IO ()
cacheRemoteFile cache tempPath (Some f) isCached = do
    go f (cachedFileName isCached)
    -- TODO: This recreates the tar index ahead of time. Alternatively, we
    -- could delete the index here and then it will be rebuilt on first access.
    when (isCached == CacheIndex) $ rebuildTarIndex cache
  where
    go :: Format f -> Maybe UnrootedPath -> IO ()
    go _ Nothing =
      return () -- Don't cache
    go FUn (Just localName) = do
      -- TODO: (here and elsewhere): use atomic file operation instead
      let fp = cache </> localName
      createDirectoryIfMissing True (takeDirectory fp)
      copyFile tempPath fp
    go FGz (Just localName) = do
      let fp = cache </> localName
      createDirectoryIfMissing True (takeDirectory fp)
      compressed <- readLazyByteString tempPath
      writeLazyByteString fp $ GZip.decompress compressed

-- | Rebuild the tarball index
--
-- TODO: Should we attempt to rebuild this incrementally?
rebuildTarIndex :: Cache -> IO ()
rebuildTarIndex cache = do
    entries <- Tar.read <$> readLazyByteString (cache </> fragment "00-index.tar")
    case TarIndex.build entries of
      Left  ex    -> throwIO ex
      Right index ->
        withBinaryFile (cache </> fragment "00-index.tar.idx") WriteMode $ \h -> do
          hSetBuffering h (BlockBuffering Nothing)
          BS.Builder.hPutBuilder h $ TarIndex.serialise index

-- | The name of the file as cached
--
-- Returns @Nothing@ if we do not cache this file.
--
-- NOTE: We always cache files locally in uncompressed format. This is a
-- policy of this implementation of 'Repository', however, and other policies
-- are possible; that's why this lives here rather than in @Client.Repository@.
cachedFileName :: IsCached -> Maybe UnrootedPath
cachedFileName (CacheAs cachedFile) = Just $ cachedFilePath cachedFile
cachedFileName CacheIndex           = Just $ fragment "00-index.tar"
cachedFileName DontCache            = Nothing

-- | Get a cached file (if available)
getCached :: Cache -> CachedFile -> IO (Maybe AbsolutePath)
getCached cache cachedFile = do
    exists <- doesFileExist localPath
    if exists then return $ Just localPath
              else return $ Nothing
  where
    localPath = cache </> cachedFilePath cachedFile

-- | Get the cached index (if available)
getCachedIndex :: Cache -> IO (Maybe AbsolutePath)
getCachedIndex cache = do
    exists <- doesFileExist localPath
    if exists then return $ Just localPath
              else return $ Nothing
  where
    localPath = cache </> fragment "00-index.tar"

-- | Get the cached root
getCachedRoot :: Cache -> IO AbsolutePath
getCachedRoot cache = do
    mPath <- getCached cache CachedRoot
    case mPath of
      Just p  -> return p
      Nothing -> throwIO $ userError "Client missing root info"

-- | Get a file from the index
getFromIndex :: Cache -> IndexFile -> IO (Maybe BS.ByteString)
getFromIndex cache indexFile = do
    mIndex <- tryReadIndex (cache </> fragment "00-index.tar.idx")
    case mIndex of
      Left _err -> do
        -- If index is corrupted, rebuild and try again
        rebuildTarIndex cache
        getFromIndex cache indexFile
      Right index ->
        case tarIndexLookup index (indexFilePath indexFile) of
          Just (TarIndex.TarFileEntry offset) ->
            -- TODO: We might want to keep this handle open
            withFile (cache </> fragment "00-index.tar") ReadMode $ \h -> do
              entry <- TarIndex.hReadEntry h offset
              case Tar.entryContent entry of
                Tar.NormalFile lbs _size -> do
                  bs <- evaluate $ BS.concat . BS.L.toChunks $ lbs
                  return $ Just bs
                _otherwise ->
                  return Nothing
          _otherwise ->
            return Nothing
  where
    -- TODO: How come 'deserialise' uses _strict_ ByteStrings?
    tryReadIndex :: AbsolutePath -> IO (Either (Maybe IOException) TarIndex)
    tryReadIndex fp =
        aux <$> try (TarIndex.deserialise <$> readStrictByteString fp)
      where
        aux :: Either e (Maybe (a, leftover)) -> Either (Maybe e) a
        aux (Left e)              = Left (Just e)
        aux (Right Nothing)       = Left Nothing
        aux (Right (Just (a, _))) = Right a

-- | Delete a previously downloaded remote file
clearCache :: Cache -> IO ()
clearCache cache = void . handleDoesNotExist $ do
    removeFile $ cache </> cachedFilePath CachedTimestamp
    removeFile $ cache </> cachedFilePath CachedSnapshot
