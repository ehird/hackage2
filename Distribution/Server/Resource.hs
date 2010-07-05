{-# LANGUAGE GeneralizedNewtypeDeriving, StandaloneDeriving, FlexibleContexts, FlexibleInstances #-}

module Distribution.Server.Resource (
    -- | Paths
    BranchComponent(..),
    BranchPath,
    trunkAt,

    -- | Resources
    Resource(..),
    ResourceFormat(..),
    BranchFormat(..),
    BranchEnd(..),
    Content,
    resourceAt,
    extendResource,
    extendResourcePath,
    serveResource,

    -- | URI generation
    URIGen,
    renderURI,
    renderResource,
    renderLink,

    -- | ServerTree
    ServerTree(..),
    serverTreeEmpty,
    addServerNode,
    renderServerTree,
    drawServerTree
  ) where

import Happstack.Server
import Distribution.Server.Types

import Data.Monoid
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Applicative ((<*>), (<$>))
import Control.Monad
import Data.Maybe (maybeToList)
import Data.Function (on)
import Data.List (intercalate, unionBy, findIndices)
import qualified Text.ParserCombinators.Parsec as Parse

import qualified Happstack.Server.SURI as SURI
import System.FilePath.Posix ((</>))
--for basic link creating
import Text.XHtml.Strict (anchor, href, (!), (<<), toHtml, Html)
import qualified Data.Tree as Tree (Tree(..), drawTree)

type Content = String

-- | A resource is an object that handles requests at a given URI. Best practice
-- is to construct it by calling resourceAt and then setting the method fields
-- using record update syntax. You can also extend an existing resource with
-- extendResource, which can be mappended to the original to combine their
-- functionality, or with extendResourcePath.
data Resource = Resource {
    -- | The location in a form which can be added to a ServerTree.
    resourceLocation :: BranchPath,
    -- | Handlers for GET requests for different content-types
    resourceGet    :: [(Content, ServerResponse)],
    -- | Handlers for PUT requests
    resourcePut    :: [(Content, ServerResponse)],
    -- | Handlers for POST requests
    resourcePost   :: [(Content, ServerResponse)],
    -- | Handlers for DELETE requests
    resourceDelete :: [(Content, ServerResponse)],
    -- | The format conventions held by the resource.
    resourceFormat  :: ResourceFormat,
    -- | The trailing slash conventions held by the resource.
    resourcePathEnd :: BranchEnd,
    -- | Given a DynamicPath, produce a lookup function, by default (flip lookup). This is for resources with special conventions.
    resourceURI :: DynamicPath -> (String -> Maybe String)
}
-- favors first
instance Monoid Resource where
    mempty = Resource [] [] [] [] [] noFormat NoSlash (flip lookup)
    mappend (Resource bpath rget rput rpost rdelete rformat rend ruri)
            (Resource bpath' rget' rput' rpost' rdelete' rformat' rend' ruri') =
        Resource (simpleCombine bpath bpath') (ccombine rget rget') (ccombine rput rput')
                   (ccombine rpost rpost') (ccombine rdelete rdelete')
                   (simpleCombine rformat rformat') (simpleCombine rend rend')
                   (simpleCombine ruri ruri')
      where ccombine = unionBy ((==) `on` fst)
            simpleCombine xs ys = if null bpath then ys else xs

-- | A path element of a URI.
--
-- * StaticBranch dirName - \/dirName
-- * DynamicBranch dynamicName - \/anyName (mapping created dynamicName -> anyName)
-- * TrailingBranch - doesn't consume any path; it's here to prevent e.g. conflict between \/.:format and \/...
--
-- trunkAt yields a simple list of BranchComponents.
-- resourceAt yields the same, and some complex metadata for processing formats and the like.
data BranchComponent = StaticBranch String | DynamicBranch String | TrailingBranch deriving (Show, Eq, Ord)
type BranchPath = [BranchComponent]

-- | This type dictates the preprocessing we must do on extensions (foo.json) when serving Resources
-- For BranchFormat, we need to do:
-- 1. for NoFormat - don't do any preprocessing. The second field is ignored here.
-- 1. for StaticFormat  - look for a specific format, and guard against that
-- 2. for DynamicFormat - strip off any extension (starting from the right end, so no periods allowed)
-- Under either of the above cases, the component might need to be preprocessed as well.
-- 1. for Nothing - this means a standalone format, like \/.json (as in \/distro\/arch\/.json)
--                  either accept \/distro\/arch\/ or read \/distro\/arch\/.format and pass it along
-- 2. for Just (StaticBranch sdir) - strip off the pre-format part and make sure it equals sdir
-- 3. for Just (DynamicBranch sdir) - strip off the pre-format part and pass it with the DynamicPath as sdir
-- DynamicFormat also has the property that it is optional, and defaulting is allowed.
data ResourceFormat = ResourceFormat BranchFormat (Maybe BranchComponent) deriving (Show, Eq, Ord)

noFormat :: ResourceFormat
noFormat = ResourceFormat NoFormat Nothing

data BranchFormat = NoFormat | DynamicFormat | StaticFormat String deriving (Show, Eq, Ord)
data BranchEnd  = Slash | NoSlash | Trailing deriving (Show, Eq, Ord)

-- | Creates an empty resource from a string specifying its location and format conventions.
--
-- (Explain path literal syntax.)
resourceAt :: String -> Resource
resourceAt arg = mempty
  { resourceLocation = reverse loc
  , resourceFormat  = format
  , resourcePathEnd = slash
  }
  where
    branch = either trunkError id $ Parse.parse parseFormatTrunkAt "Distribution.Server.Resource.parseFormatTrunkAt" arg
    trunkError pe = error $ "Distribution.Server.Resource.resourceAt: Could not parse trunk literal " ++ show arg ++ ". Parsec error: " ++ show pe
    (loc, slash, format) = trunkToResource branch

-- | Creates a new resource at the same location, but without any of the request
-- handlers of the original. When mappend'd to the original, its methods and content-types
-- will be combined. This can be useful for extending an existing resource with new representations and new
-- functionality.
extendResource :: Resource -> Resource
extendResource resource = resource { resourceGet = [], resourcePut = [], resourcePost = [], resourceDelete = [] }

-- | Creates a new resource that is at a subdirectory of an existing resource. This function takes care of formats
-- as best as it can.
--
-- extendResourcePath "\/bar\/.:format" (resourceAt "\/data\/:foo.:format") == resourceAt "\/data\/:foo\/bar\/:.format"
--
-- Extending static formats with this method is not recommended. (extending "\/:tarball.tar.gz"
-- with "\/data" will give "\/:tarball\/data", with the format stripped, and extending
-- "\/help\/.json" with "\/tree" will give "\/help\/.json\/tree")
extendResourcePath :: String -> Resource -> Resource
extendResourcePath arg resource =
  let endLoc = case resourceFormat resource of
        ResourceFormat (StaticFormat _) Nothing -> case loc of
            (DynamicBranch "format":rest) -> rest
            _ -> funcError "Static ending format must have dynamic 'format' branch"
        ResourceFormat (StaticFormat _) (Just (StaticBranch sdir)) -> case loc of
            (DynamicBranch sdir':rest) | sdir == sdir' -> rest
            _ -> funcError "Static branch and format must match stated location"
        ResourceFormat (StaticFormat _) (Just (DynamicBranch sdir)) -> case loc of
            (DynamicBranch sdir':_) | sdir == sdir' -> loc
            _ -> funcError "Dynamic branch with static format must match stated location"
        ResourceFormat DynamicFormat Nothing -> loc
        ResourceFormat DynamicFormat (Just (StaticBranch sdir)) -> case loc of
            (DynamicBranch sdir':rest) | sdir == sdir' -> StaticBranch sdir:rest
            _ -> funcError "Dynamic format with static branch must match stated location"
        ResourceFormat DynamicFormat (Just (DynamicBranch sdir)) -> case loc of
            (DynamicBranch sdir':_) | sdir == sdir' -> loc
            _ -> funcError "Dynamic branch and format must match stated location"
        -- For a URI like /resource/.format: since it is encoded as NoFormat in trunkToResource,
        -- this branch will incorrectly be taken. this isn't too big a handicap though
        ResourceFormat NoFormat Nothing -> case loc of
            (TrailingBranch:rest) -> rest
            _ -> loc
        _ -> funcError $ "invalid resource format in argument 2"
  in
    extendResource resource { resourceLocation = reverse loc' ++ endLoc, resourceFormat = format', resourcePathEnd = slash' }
  where
    branch = either trunkError id $ Parse.parse parseFormatTrunkAt "Distribution.Server.Resource.parseFormatTrunkAt" arg
    trunkError pe = funcError $ "Could not parse trunk literal " ++ show arg ++ ". Parsec error: " ++ show pe
    funcError reason = error $ "Distribution.Server.Resource.extendResourcePath :" ++ reason
    loc = resourceLocation resource
    (loc', slash', format') = trunkToResource branch

-- other combinatoresque methods here - e.g. addGet :: Content -> ServerResponse -> Resource -> Resource

type URIGen = DynamicPath -> Maybe String

-- Allows the formation of a URI from a URI specification (BranchPath).
-- URIs may obey additional constraints and have special rules (e.g., formats).
-- To accomodate these, insteaduse renderResource to get a URI.
--
-- ".." is a special argument that fills in a TrailingBranch. Make sure it's
-- properly escaped (see Happstack.Server.SURI)
--
-- renderURI (trunkAt "/home/:user/..")
--    [("user", "mgruen"), ("..", "docs/todo.txt")]
--    == Just "/home/mgruen/docs/todo.txt"
renderURI :: BranchPath -> URIGen
renderURI bpath dpath = renderGenURI bpath (flip lookup dpath)

-- Render a URI generally using a function of one's choosing (usually flip lookup)
-- Stops when a requested field is needed.
renderGenURI :: BranchPath -> (String -> Maybe String) -> Maybe String
renderGenURI bpath pathFunc = ("/" </>) <$> go (reverse bpath)
    where go (StaticBranch  sdir:rest) = (SURI.escape sdir </>) <$> go rest
          go (DynamicBranch sdir:rest) = ((</>) . SURI.escape) <$> pathFunc sdir <*> go rest
          go (TrailingBranch:_) = pathFunc ".."
          go [] = Just ""

-- Doesn't use a DynamicPath - rather, munches path components from a list
-- it stops if there aren't enough, and returns the extras if there's more than enough.
--
-- This approach makes it a bit easier to be type-safe, but nonetheless it's
-- less flexible (general) than renderGenURI.
--
-- Trailing branches currently are assumed to be complete escaped URI paths.
renderListURI :: BranchPath -> [String] -> (String, [String])
renderListURI bpath list = let (res, extra) = go (reverse bpath) list in ("/" </> res, extra)
    where go (StaticBranch  sdir:rest) xs  = let (res, extra) = go rest xs in (SURI.escape sdir </> res, extra)
          go (DynamicBranch _:rest) (x:xs) = let (res, extra) = go rest xs in (SURI.escape x </> res, extra)
          go (TrailingBranch:_) xs = case xs of [] -> ("", []); (x:rest) -> (x, rest)
          go _ rest = ("", rest)

-- Given a Resource, construct a URIGen. If the Resource uses a dynamic format, it can
-- be passed in the DynamicPath as "format". Trailing slash conventions are obeyed.
--
-- See documentation for the Resource to see the conventions in interpreting the DynamicPath.
-- As in renderURI, ".." is interpreted as the trailing branch.
--
-- renderURI (resourceAt "/home/:user/docs/:doc.:format")
--     [("user", "mgruen"), ("doc", "todo"), ("format", "json")]
--     == Just "/home/mgruen/docs/todo.txt"
renderMaybeResource :: Resource -> URIGen
renderMaybeResource resource dpath = case renderGenURI (normalizeResourceLocation resource) (resourceURI resource dpath) of
    Nothing  -> Nothing
    Just str -> Just $ renderResourceFormat resource (lookup "format" dpath) str

renderResource :: Resource -> [String] -> String
renderResource resource list = case renderListURI (normalizeResourceLocation resource) list of
    (str, format:_) -> renderResourceFormat resource (Just format) str
    (str, []) -> renderResourceFormat resource Nothing str

-- in some cases, DynamicBranches are used to accomodate formats for StaticBranches.
-- this returns them to their pre-format state so renderGenURI can handle them
normalizeResourceLocation resource = case (resourceFormat resource, resourceLocation resource) of
    (ResourceFormat _ (Just (StaticBranch sdir)), DynamicBranch sdir':xs) | sdir == sdir' -> StaticBranch sdir:xs
    (_, loc) -> loc

renderResourceFormat :: Resource -> Maybe String -> String -> String
renderResourceFormat resource dformat str = case (resourcePathEnd resource, resourceFormat resource) of
    (NoSlash, ResourceFormat NoFormat _) -> str
    (Slash, ResourceFormat NoFormat _) -> case str of "/" -> "/"; _ -> str ++ "/"
    (NoSlash, ResourceFormat (StaticFormat format) branch) -> case branch of
        Just {} -> str ++ "." ++ format
        Nothing -> str ++ "/." ++ format
    (Slash, ResourceFormat DynamicFormat Nothing) -> case dformat of
        Just format@(_:_) -> str ++ "/." ++ format
        _ -> str ++ "/"
    (NoSlash, ResourceFormat DynamicFormat _) -> case dformat of
        Just format@(_:_) -> str ++ "." ++ format
        _ -> str
    -- This case might be taken by TrailingBranch
    _ -> str

-- Given a URIGen, a DynamicPath, and a String for the text, construct an HTML
-- node that is just the text if the URI generation fails, and a link with the
-- text inside otherwise. A convenience function.
renderLink :: URIGen -> DynamicPath -> String -> Html
renderLink gen dpath text = case gen dpath of
    Nothing  -> toHtml text
    Just uri -> anchor ! [href uri] << text

-- Converts the output of parseTrunkFormatAt to something consumable by a Resource
-- It forbids many things that parse correctly, most notably using formats in the middle of a path.
-- It's possible in theory to allow such things, but complicated.
-- Directories are really format-less things.
--
-- trunkToResource is a top-level call to weed out cases that don't make sense recursively in trunkToResource'
trunkToResource  :: [(BranchComponent, BranchFormat)] -> ([BranchComponent], BranchEnd, ResourceFormat)
trunkToResource [] = ([], Slash, noFormat) -- ""
trunkToResource [(StaticBranch "", format)] = ([], Slash, ResourceFormat format Nothing) -- "/" or "/.format"
trunkToResource anythingElse = trunkToResource' anythingElse

trunkToResource' :: [(BranchComponent, BranchFormat)] -> ([BranchComponent], BranchEnd, ResourceFormat)
trunkToResource' [] = ([], NoSlash, noFormat)
-- /...
trunkToResource' ((TrailingBranch, _):xs) | null xs = ([TrailingBranch], Trailing, noFormat)
                                          | otherwise = error "Trailing path only allowed at very end"
-- /foo/, /foo/.format, or /foo/.:format
trunkToResource' [(branch, NoFormat), (StaticBranch "", format)] = pathFormatSep format
  where pathFormatSep (StaticFormat form) = ([branch, StaticBranch ("." ++ form)], NoSlash, noFormat) -- /foo/.json, format is not optional here!
        pathFormatSep DynamicFormat = ([branch], Slash, ResourceFormat DynamicFormat Nothing) -- /foo/.format
        pathFormatSep NoFormat = ([branch], Slash, noFormat) -- /foo/
-- /foo.format/[...] (rewrite into next case)
trunkToResource' ((StaticBranch sdir, StaticFormat format):xs) = trunkToResource' ((StaticBranch (sdir ++ "." ++ format), NoFormat):xs)
-- /foo/[...]
trunkToResource' ((branch, NoFormat):xs) = case trunkToResource' xs of (xs', slash, res) -> (branch:xs', slash, res)
-- /foo.format
trunkToResource' [(branch, format)] = pathFormat branch format
  where pathFormat (StaticBranch sdir) (StaticFormat form) = ([StaticBranch (sdir ++ "." ++ form)], NoSlash, noFormat) -- foo.json
        pathFormat (StaticBranch sdir) DynamicFormat = ([DynamicBranch sdir], NoSlash, ResourceFormat DynamicFormat (Just branch)) -- foo.:json
        pathFormat (DynamicBranch {}) (StaticFormat {}) = ([branch], NoSlash, ResourceFormat format (Just branch)) -- :foo.json
        pathFormat (DynamicBranch {}) DynamicFormat = ([branch], NoSlash, ResourceFormat DynamicFormat (Just branch)) -- :foo.:json
        pathFormat _ NoFormat = ([branch], NoSlash, noFormat) -- foo or :foo
        pathFormat _ _ = error "Trailing path can't have a format"
-- /foo.format/[...]
trunkToResource' _ = error "Format only allowed at end of path"

trunkAt :: String -> BranchPath
trunkAt arg = either trunkError reverse $ Parse.parse parseTrunkAt "Distribution.Server.Resource.parseTrunkAt" arg
    where trunkError pe = error $ "Distribution.Server.Resource.trunkAt: Could not parse trunk literal " ++ show arg ++ ". Parsec error: " ++ show pe

parseTrunkAt :: Parse.Parser [BranchComponent]
parseTrunkAt = do
    components <- Parse.many (Parse.try parseComponent)
    Parse.optional (Parse.char '/')
    Parse.eof
    return components
  where
    parseComponent = do
        Parse.char '/'
        fmap DynamicBranch (Parse.char ':' >> Parse.many1 (Parse.noneOf "/"))
          Parse.<|> fmap StaticBranch (Parse.many1 (Parse.noneOf "/"))

parseFormatTrunkAt :: Parse.Parser [(BranchComponent, BranchFormat)]
parseFormatTrunkAt = do
    components <- Parse.many (Parse.try parseComponent)
    rest <- Parse.option [] (Parse.char '/' >> return [(StaticBranch "", NoFormat)])
    Parse.eof
    return (components ++ rest)
  where
    parseComponent :: Parse.Parser (BranchComponent, BranchFormat)
    parseComponent = do
        Parse.char '/'
        Parse.choice $ map Parse.try
          [ Parse.char '.' >> Parse.many1 (Parse.char '.') >>
            ((Parse.lookAhead (Parse.char '/') >> return ()) Parse.<|> Parse.eof) >> return (TrailingBranch, NoFormat)
          , Parse.char ':' >> parseMaybeFormat DynamicBranch
          , do Parse.lookAhead (Parse.satisfy (/=':'))
               Parse.choice $ map Parse.try
                 [ parseMaybeFormat StaticBranch
                 , fmap ((,) (StaticBranch "")) parseFormat
                 , fmap (flip (,) NoFormat . StaticBranch) untilNext
                 ]
          ]
    parseMaybeFormat :: (String -> BranchComponent) -> Parse.Parser (BranchComponent, BranchFormat)
    parseMaybeFormat control = do
        sdir <- Parse.many1 (Parse.noneOf "/.")
        format <- Parse.option NoFormat parseFormat
        return (control sdir, format)
    parseFormat :: Parse.Parser BranchFormat
    parseFormat = Parse.char '.' >> Parse.choice
        [ Parse.char ':' >> untilNext >> return DynamicFormat
        , fmap StaticFormat untilNext
        ]
    untilNext :: Parse.Parser String
    untilNext = Parse.many1 (Parse.noneOf "/")

-- serveResource does all the path format and HTTP method preprocessing for a Resource
--
-- For a small curl-based test suite of [Resource]:
-- [res "/foo" ["json"], res "/foo/:bar.:format" ["html", "json"], res "/baz/test/.:format" ["html", "text", "json"], res "/package/:package/:tarball.tar.gz" ["tarball"], res "/a/:a/:b/" ["html", "json"], res "/mon/..." [""], res "/wiki/path.:format" [], res "/hi.:format" ["yaml", "mofo"]]
--     where res field formats = (resourceAt field) { resourceGet = map (\format -> (format, \_ -> return . toResponse . (++"\n") . ((show format++" - ")++) . show)) formats }
serveResource :: Resource -> ServerResponse
serveResource (Resource _ rget rput rpost rdelete rformat rend _) = \config dpath -> msum $
    map (\func -> func config dpath) $ methodPart ++ [optionPart]
  where
    optionPart = makeOptions $ concat [ met | ((_:_), met) <- zip methods methodsList]
    methodPart = [ serveResources met res | (res@(_:_), met) <- zip methods methodsList]
    -- some of the dpath lookup calls can be replaced by pattern matching the head/replacing
    -- at the moment, duplicate entries tend to be inserted in dpath, because old ones are not replaced
    -- Procedure:
    -- > Guard against method
    -- > Extract format/whatnot
    -- > Potentially redirect to canonical slash form
    -- > Go from format/content-type to ServerResponse to serve-}
    serveResources :: [Method] -> [(Content, ServerResponse)] -> ServerResponse
    serveResources met res = case rend of
        Trailing -> \config dpath -> methodOnly met >> serveContent res config dpath
        _ -> \config dpath -> serveFormat res met config dpath
    serveFormat :: [(Content, ServerResponse)] -> [Method] -> ServerResponse
    serveFormat res met = case rformat of
        ResourceFormat NoFormat Nothing -> \config dpath -> methodSP met $ serveContent res config dpath
        ResourceFormat (StaticFormat format) Nothing -> \config dpath -> path $ \format' -> methodSP met $ do
            -- this branch shouldn't happen - /foo/.json would instead be stored as two static dirs
            guard (format' == ('.':format))
            serveContent res config dpath
        ResourceFormat (StaticFormat format) (Just (StaticBranch sdir)) -> \config dpath -> methodSP met $
            -- likewise, foo.json should be stored as a single static dir
            if lookup sdir dpath == Just (sdir ++ "." ++ format) then mzero
                                                                 else serveContent res config dpath
        ResourceFormat (StaticFormat format) (Just (DynamicBranch sdir)) -> \config dpath -> methodSP met $
            case matchExt format =<< lookup sdir dpath of
                Just pname -> serveContent res config ((sdir, pname):dpath)
                Nothing -> mzero
        ResourceFormat DynamicFormat Nothing -> \config dpath ->
            msum [ methodSP met $ serveContent res config dpath
                 , path $ \pname -> case pname of
                       ('.':format) -> methodSP met $ serveContent res config (("format", format):dpath)
                       _ -> mzero
                 ]
        ResourceFormat DynamicFormat (Just (StaticBranch sdir)) -> \config dpath -> methodSP met $
            case fmap extractExt (lookup sdir dpath) of
                Just (pname, format) | pname == sdir -> serveContent res config (("format", format):dpath)
                _ -> mzero
        ResourceFormat DynamicFormat (Just (DynamicBranch sdir)) -> \config dpath -> methodSP met $
            -- this is somewhat complicated. consider /pkg-0.1 and /pkg-0.1.html. If the format is optional, where to split?
            -- the solution is to manually check the available formats to see if something matches
            -- if this situation comes up in practice, try to require a trailing slash, e.g. /pkg-0.1/.html
            case fmap (\sd -> (,) sd $ extractExt sd) (lookup sdir dpath) of
                Just (full, (pname, format)) -> do
                    let splitOption = serveContent res config (("format", format):(sdir, pname):dpath)
                        fullOption  = serveContent res config ((sdir, full):dpath)
                    case guard (not $ null format) >> lookup format res of
                        Nothing -> fullOption
                        Just {} -> splitOption
                _ -> mzero
        -- some invalid combination
        _ -> \config dpath -> methodSP met $ serveContent res config dpath
    serveContent :: [(Content, ServerResponse)] -> ServerResponse
    serveContent res config dpath = do
        -- there should be no remaining path segments at this point, now check page redirection
        met <- fmap rqMethod askRq
        -- we don't check if the page exists before redirecting!
        -- just send them to the canonical place the document may or may not be
        (if met == HEAD || met == GET
            then redirCanonicalSlash dpath
            else id) $ do
        -- "Find " ++ show (lookup "format" dpath) ++ " in " ++ show (map fst res)
        case lookup "format" dpath of
            Just format@(_:_) -> case lookup format res of
                               -- return a specific format if it is found
                Just answer -> answer config dpath
                Nothing -> mzero -- return 404 if the specific format is not found
                  -- return default response when format is empty or non-existent
            _ -> (snd $ head res) config dpath
    redirCanonicalSlash :: DynamicPath -> ServerPart Response -> ServerPart Response
    redirCanonicalSlash dpath trueRes = case rformat of
        ResourceFormat format Nothing | format /= NoFormat -> case lookup "format" dpath of
            Just {} -> requireNoSlash `mplus` trueRes
            Nothing -> requireSlash `mplus` trueRes
        _ -> case rend of
            Slash    -> requireSlash `mplus` trueRes
            NoSlash  -> requireNoSlash `mplus` trueRes
            Trailing -> mplus (nullDir >> requireSlash) trueRes
    requireSlash = do
        theUri <- fmap rqUri askRq
        guard $ last theUri /= '/'
        movedPermanently (theUri ++ "/") (toResponse ())
    requireNoSlash = do
        theUri <- fmap rqUri askRq
        guard $ last theUri == '/'
        movedPermanently (reverse . dropWhile (=='/') . reverse $ theUri) (toResponse ())
    -- matchExt and extractExt could also use manual string-chomping recursion if wanted
    matchExt format pname = let fsize = length format
                                (pname', format') = splitAt (length pname - fsize - 1) pname
                            in if '.':format == format' then Just pname'
                                                        else Nothing
    extractExt pname = case findIndices (=='.') pname of
        [] -> (pname, "")
        xs -> case splitAt (last xs) pname of (pname', _:format) -> (pname', format)
                                              _ -> (pname, "") -- this shouldn't happen
    methods = [rget, rput, rpost, rdelete]
    methodsList = [[GET, HEAD], [PUT], [POST], [DELETE]]
    makeOptions :: [Method] -> ServerResponse
    makeOptions methodList = \_ _ -> methodSP OPTIONS $ do
        setHeaderM "Allow" (intercalate ", " . map show $ methodList)
        return $ toResponse ()

----------------------------------------------------------------------------

data ServerTree a = ServerTree {
    nodeResponse :: Maybe a,
    nodeForest :: Map BranchComponent (ServerTree a)
} deriving (Show)

instance Functor ServerTree where
    fmap func (ServerTree value forest) = ServerTree (fmap func value) (Map.map (fmap func) forest)

drawServerTree :: ServerTree a -> String
drawServerTree tree = Tree.drawTree (transformTree tree Nothing)
  where transformTree (ServerTree res for) mlink = Tree.Node (drawLink mlink res) (map transformForest $ Map.toList for)
        drawLink mlink res = maybe "" ((++": ") . show) mlink ++ maybe "(nothing)" (const "response") res
        transformForest (link, tree') = transformTree tree' (Just link)

serverTreeEmpty :: ServerTree a
serverTreeEmpty = ServerTree Nothing Map.empty

-- essentially a ReaderT (Config, DynamicPath) ServerPart Response
-- this always renders parent URIs, but usually we guard against remaining path segments, so it's fine
renderServerTree :: Config -> DynamicPath -> ServerTree ServerResponse -> ServerPart Response
renderServerTree config dpath (ServerTree func forest) = msum $ maybeToList (fmap (\fun -> fun config dpath) func) ++ map (uncurry renderBranch) (Map.toList forest)
  where
    renderBranch :: BranchComponent -> ServerTree ServerResponse -> ServerPart Response
    renderBranch (StaticBranch  sdir) tree = dir sdir $ renderServerTree config dpath tree
    renderBranch (DynamicBranch sdir) tree = path $ \pname -> renderServerTree config ((sdir, pname):dpath) tree
    renderBranch TrailingBranch tree = renderServerTree config dpath tree

reinsert :: Monoid a => BranchComponent -> ServerTree a -> Map BranchComponent (ServerTree a) -> Map BranchComponent (ServerTree a)
-- combine will only be called if branchMap already contains the key
reinsert key newTree branchMap = Map.insertWith combine key newTree branchMap

combine :: Monoid a => ServerTree a -> ServerTree a -> ServerTree a
combine (ServerTree newResponse newForest) (ServerTree oldResponse oldForest) =
    -- replace old resource with new resource, combine old and new responses
    ServerTree (mappend newResponse oldResponse) (Map.foldWithKey reinsert oldForest newForest)

addServerNode :: Monoid a => BranchPath -> a -> ServerTree a -> ServerTree a
addServerNode trunk response tree = treeFold trunk (ServerTree (Just response) Map.empty) tree

--this function takes a list whose head is the resource and traverses leftwards in the URI
--this is due to the original design of specifying URI branches: if the resources are
--themselves encoded in the branch, then subresources should share the same parent
--resource, sharing list tails.
--
--This version is greatly simplified compared to what was previously here.
treeFold :: Monoid a => BranchPath -> ServerTree a -> ServerTree a -> ServerTree a
treeFold [] newChild topLevel = combine newChild topLevel
treeFold (sdir:otherTree) newChild topLevel = treeFold otherTree (ServerTree Nothing $ Map.singleton sdir newChild) topLevel 

