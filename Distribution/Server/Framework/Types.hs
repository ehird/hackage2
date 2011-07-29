module Distribution.Server.Framework.Types where

import Distribution.Server.Framework.BlobStorage (BlobStorage)

import Happstack.Server
import qualified Network.URI as URI

data Config = Config {
    serverStore     :: BlobStorage,
    serverStaticDir :: FilePath,
    serverTmpDir    :: FilePath,
    serverURI       :: URI.URIAuth
}

type DynamicPath = [(String, String)]

type ServerResponse = DynamicPath -> ServerPart Response
