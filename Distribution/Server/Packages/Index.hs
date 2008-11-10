-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Server.Packages.Index
-- Copyright   :  (c) Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  duncan@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Create the package index.
--
-----------------------------------------------------------------------------
module Distribution.Server.Packages.Index (
    write,
  ) where

import qualified Distribution.Server.Util.Tar as Tar
         ( Entry(..), ExtendedHeader(..) )
import qualified Distribution.Server.Util.Index as PackageIndex

import Distribution.Server.Types
         ( PkgInfo(..) )
import qualified Distribution.Server.Users.Users as Users
         ( Users, idToName )

import Distribution.Text
         ( display )
import Distribution.Simple.PackageIndex (PackageIndex)
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Data.Time.Clock
         ( UTCTime )
import Data.Time.Clock.POSIX
         ( utcTimeToPOSIXSeconds )

import qualified Data.ByteString.Lazy as BS
import Data.ByteString.Lazy (ByteString)
import Prelude hiding (read)

write :: Users.Users -> PackageIndex PkgInfo -> ByteString
write users = PackageIndex.write pkgData setModTime
  where
    setModTime pkgInfo entry = entry {
      Tar.modTime   = utcToUnixTime (pkgUploadTime pkgInfo),
      Tar.headerExt = (Tar.headerExt entry) {
        Tar.ownerName = userName (pkgUploadUser pkgInfo),
        Tar.groupName = "HackageDB"
      }
    }
    utcToUnixTime :: UTCTime -> Int
    utcToUnixTime = truncate . utcTimeToPOSIXSeconds
    userName = display . Users.idToName users