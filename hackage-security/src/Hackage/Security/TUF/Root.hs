-- | The root filetype
module Hackage.Security.TUF.Root (
    -- * Datatypes
    Root(..)
  , RootRoles(..)
  , RoleSpec(..)
  ) where

import Hackage.Security.JSON
import Hackage.Security.Key
import Hackage.Security.Key.Env (KeyEnv)
import Hackage.Security.Key.ExplicitSharing
import Hackage.Security.TUF.Common
import Hackage.Security.TUF.Header
import Hackage.Security.TUF.Mirrors
import Hackage.Security.TUF.Signed
import Hackage.Security.TUF.Snapshot
import Hackage.Security.TUF.Targets
import Hackage.Security.TUF.Timestamp
import Hackage.Security.Util.Some

{-------------------------------------------------------------------------------
  Datatypes
-------------------------------------------------------------------------------}

-- | The root metadata
--
-- NOTE: We must have the invariant that ALL keys (apart from delegation keys)
-- must be listed in 'rootKeys'. (Delegation keys satisfy a similar invariant,
-- see Targets.)
data Root = Root {
    rootVersion :: FileVersion
  , rootExpires :: FileExpires
  , rootKeys    :: KeyEnv
  , rootRoles   :: RootRoles
  }

data RootRoles = RootRoles {
    rootRolesRoot      :: RoleSpec Root
  , rootRolesSnapshot  :: RoleSpec Snapshot
  , rootRolesTargets   :: RoleSpec Targets
  , rootRolesTimestamp :: RoleSpec Timestamp
  , rootRolesMirrors   :: RoleSpec Mirrors
  }

-- | Role specification
--
-- The phantom type indicates what kind of type this role is meant to verify.
data RoleSpec a = RoleSpec {
    roleSpecKeys      :: [Some PublicKey]
  , roleSpecThreshold :: KeyThreshold
  }
  deriving (Show)

instance HasHeader Root where
  fileVersion f x = (\y -> x { rootVersion = y }) <$> f (rootVersion x)
  fileExpires f x = (\y -> x { rootExpires = y }) <$> f (rootExpires x)

instance DescribeFile Root where
  describeFile _ = "root"

{-------------------------------------------------------------------------------
  JSON encoding
-------------------------------------------------------------------------------}

instance ToJSON RootRoles where
  toJSON RootRoles{..} = JSObject [
      ("root"      , toJSON rootRolesRoot)
    , ("snapshot"  , toJSON rootRolesSnapshot)
    , ("targets"   , toJSON rootRolesTargets)
    , ("timestamp" , toJSON rootRolesTimestamp)
    , ("mirrors"   , toJSON rootRolesMirrors)
    ]

instance FromJSON ReadJSON RootRoles where
  fromJSON enc = do
    rootRolesRoot      <- fromJSField enc "root"
    rootRolesSnapshot  <- fromJSField enc "snapshot"
    rootRolesTargets   <- fromJSField enc "targets"
    rootRolesTimestamp <- fromJSField enc "timestamp"
    rootRolesMirrors   <- fromJSField enc "mirrors"
    return RootRoles{..}

instance ToJSON Root where
  toJSON Root{..} = JSObject [
         ("_type"   , JSString "Root")
       , ("version" , toJSON rootVersion)
       , ("expires" , toJSON rootExpires)
       , ("keys"    , toJSON rootKeys)
       , ("roles"   , toJSON rootRoles)
       ]

instance ToJSON (RoleSpec a) where
  toJSON RoleSpec{..} = JSObject [
        ("keyids"    , JSArray $ map writeKeyAsId roleSpecKeys)
      , ("threshold" , toJSON roleSpecThreshold)
      ]

-- | We give an instance for Signed Root rather than Root because the key
-- environment from the root data is necessary to resolve the explicit sharing
-- in the signatures.
instance FromJSON ReadJSON (Signed Root) where
  fromJSON envelope = do
    enc      <- fromJSField envelope "signed"
    rootKeys <- fromJSField enc      "keys"
    withKeys rootKeys $ do
      -- TODO: verify _type
      rootVersion <- fromJSField enc "version"
      rootExpires <- fromJSField enc "expires"
      rootRoles   <- fromJSField enc "roles"
      let signed = Root{..}

      signatures <- fromJSField envelope "signatures"
      validate "signatures" $ verifySignatures enc signatures
      return Signed{..}

instance FromJSON ReadJSON (RoleSpec a) where
  fromJSON enc = do
    roleSpecKeys      <- mapM readKeyAsId =<< fromJSField enc "keyids"
    roleSpecThreshold <- fromJSField enc "threshold"
    return RoleSpec{..}
