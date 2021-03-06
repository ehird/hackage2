{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, TemplateHaskell #-}
module Distribution.Server.Users.Users (
    -- * Users type
    Users(..),

    -- * Construction
    empty,
    add,
    insert,
    requireName,

    -- * Modification
    delete,
    setEnabled,
    replaceAuth,
    upgradeAuth,
    rename,

    -- * Lookup
    lookupId,
    lookupName,

    -- ** Lookup utils
    idToName,
    nameToId,

    -- * Enumeration
    enumerateAll,
    enumerateEnabled,

  ) where

import Distribution.Server.Users.Types
import Distribution.Server.Framework.AuthCrypt (checkCryptAuthInfo)
import Distribution.Server.Framework.Instances ()

import Distribution.Text (display)

import Control.Monad (liftM)
import Data.Maybe (maybeToList)
import Data.List (find)
import qualified Data.Map as Map
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import Data.SafeCopy (base, deriveSafeCopy)
import Data.Typeable (Typeable)


(?!) :: Maybe a -> e -> Either e a
ma ?! e = maybe (Left e) Right ma


-- | The entrie collection of users. Manages the mapping between 'UserName'
-- and 'UserId'.
--
data Users = Users {
    -- | A map from UserId to UserInfo
    userIdMap   :: !(IntMap.IntMap UserInfo),
    -- | A map from active UserNames to the UserId for that name
    userNameMap :: !(Map.Map UserName UserId),
    -- | A map from a UserName to all UserIds which ever used that name
    totalNameMap :: !(Map.Map UserName IntSet.IntSet),
    -- | The next available UserId
    nextId      :: !UserId
  }
  deriving (Eq, Typeable, Show)

-- invariant :: Users -> Bool
-- invariant _ = True
  --TODO: 1) the next id should be 0 if the userIdMap is empty
  --         or one bigger than the maximum allocated id
  --      2) there must be no overlap in the user names of active accounts
  --         (active are enabled or disabled but not deleted)
  --      3) the userNameMap must map every active user name to the id of the
  --         corresponding user info

  -- the point is, user names can be recycled but user ids never are
  -- this simplifies things because other user groups in the system do not
  -- need to be adjusted when an account is enabled/disabled/deleted
  -- it also allows us to track historical info, like name of uploader
  -- even if that user name has been recycled, the user ids will be distinct.


empty :: Users
empty = Users {
    userIdMap   = IntMap.empty,
    userNameMap = Map.empty,
    totalNameMap = Map.empty,
    nextId      = UserId 0
  }

-- | Add a new user account.
--
-- The new account is created in the enabled state.
--
-- * Returns 'Left' if the user name is already in use.
add :: UserName -> UserAuth -> Users -> Either String (Users, UserId)
add name auth users =
  case Map.lookup name (userNameMap users) of
    Just _  -> Left $ "Username " ++ display name ++ " already in use"
    Nothing -> users' `seq` Right (users', UserId userId)
  where
    UserId userId = nextId users
    userInfo = UserInfo {
      userName   = name,
      userStatus = Active Enabled auth
    }
    users'   = users {
      userIdMap   = IntMap.insert userId userInfo (userIdMap users),
      userNameMap = Map.insert name (UserId userId) (userNameMap users),
      totalNameMap = Map.insertWith IntSet.union name (IntSet.singleton userId) (totalNameMap users),
      nextId      = UserId (userId + 1)
    }

-- | Inserts the given info with the given id.
-- If a user is already present with the passed in
-- id, 'Left' is returned.
--
-- If the 'UserInfo' does not correspond to that of a
-- deleted user and the user name is already in use,
-- 'Left' will be returned.
insert :: UserId -> UserInfo -> Users -> Either String Users
insert user@(UserId ident) info users = do
    let name = userName info
        isDeleted = case userStatus info of
            Active {} -> False
            _ -> True
        idMap' = intInsertMaybe ident info (userIdMap users) ?! ("User ID " ++ show ident ++ " is already in use")
        nameMap' = insertMaybe name user (userNameMap users) ?! ("Username " ++ display name ++ " already in use")
        totalMap = Map.insertWith IntSet.union name (IntSet.singleton ident) (totalNameMap users)
        nextIdent | user >= nextId users = UserId (ident + 1)
                  | otherwise = nextId users
    -- Nothing on id clash, always fatal
    idMap <- idMap'
    if isDeleted
      then return $ Users idMap (userNameMap users) totalMap nextIdent
      else do
        -- Nothing on name clash only fatal if non-deleted user
        nameMap <- nameMap'
        return $ Users idMap nameMap totalMap nextIdent

-- | Try to find an id for a given user name (either active or historical),
-- and if one doesn't exist, make one as an historical account.
requireName :: UserName -> Users -> (Maybe Users, UserId)
requireName name users =
    case findGoodId =<< Map.lookup name (totalNameMap users) of
        Just uid -> (Nothing, UserId uid)
        Nothing  -> (Just users', UserId userId)
  where
    -- bit of a complicated way to say: preferred existing accounts,
    -- but historical accounts are fine as a second option
    findGoodId iset =
        let infos = do
                uid <- IntSet.toList iset
                info <- maybeToList $ IntMap.lookup uid (userIdMap users)
                return (uid, userStatus info)
        in case fmap fst $ find (isActive . snd) infos of
            Just uid -> Just uid
            Nothing  -> fmap fst $ find (isHistorical . snd) infos
    UserId userId = nextId users
    userInfo = UserInfo {
      userName   = name,
      userStatus = Historical
    }
    users'   = users {
      userIdMap   = IntMap.insert userId userInfo (userIdMap users),
      totalNameMap = Map.insertWith IntSet.union name (IntSet.singleton userId) (totalNameMap users),
      nextId      = UserId (userId + 1)
    }

-- | Delete a user account.
--
-- Prevents the given user from performing authenticated operations.
-- This operation is idempotent but not reversible. Deleting an account forgets
-- any authentication credentials and the user name becomes available for
-- re-use in a new account.
--
-- Unlike 'UserName's, 'UserId's are never actually deleted or re-used. This is
-- what distinguishes disabling and deleting an account; a disabled account can
-- be enabled again and a disabled account does not release the user name for
-- re-use.
--
-- * Returns 'Left' if the user id does not exist.
--
delete :: UserId -> Users -> Either String Users
delete (UserId userId) users = do
  userInfo     <- IntMap.lookup userId (userIdMap users) ?! ("No user with ID " ++ show userId)
  let userInfo' = userInfo { userStatus = Deleted }
  return $! users {
    userIdMap   = IntMap.insert userId userInfo' (userIdMap users),
    userNameMap = Map.delete (userName userInfo) (userNameMap users)
    -- but total name map remains the same
  }

-- | Change the status of a user account to enabled or disabled.
--
-- Prevents the given user from performing any authenticated operations.
-- This operation is idempotent and reversable. Use 'enable' to re-enable a
-- disabled account.
--
-- The disabled state is intended to be temporary. Use 'delete' to permanently
-- delete the account and release the user name to be re-used.
--
-- * Returns 'Left' if the user id does not exist or is deleted
--
setEnabled :: Bool -> UserId -> Users -> Either String Users
setEnabled newStatus (UserId userId) users = do
    userInfo  <- IntMap.lookup userId (userIdMap users) ?! ("No user with ID " ++ show userId)
    userInfo' <- changeStatus userInfo                  ?! "Inactive users cannot have their enabledness changed"
    return $! users {
        userIdMap = IntMap.insert userId userInfo' (userIdMap users)
    }
  where
    changeStatus userInfo = case userStatus userInfo of
        Active _ auth -> Just userInfo { userStatus = Active (if newStatus then Enabled else Disabled) auth }
        _ -> Nothing


lookupId :: UserId -> Users -> Maybe UserInfo
lookupId (UserId userId) users = IntMap.lookup userId (userIdMap users)

lookupName :: UserName -> Users -> Maybe UserId
lookupName name users = Map.lookup name (userNameMap users)

-- | Convert a 'UserId' to a 'UserName'. If the user id doesn't exist,
-- an ugly placeholder is used instead.
--
idToName :: Users -> UserId -> UserName
idToName users userId@(UserId idNum) = case lookupId userId users of
  Just user -> userName user
  Nothing   -> UserName $ "~id#" ++ show idNum

-- | Convert a 'UserName' to a 'UserId'. The user name must exist.
--
nameToId :: Users -> UserName -> UserId
nameToId users name = case lookupName name users of
  Just userId -> userId
  Nothing     -> error $ "Users.nameToId: no such user name " ++ display name

-- | Replace the user authentication for the given user.
--   Returns 'Left' if the user does not exist or the user existed but was not active.
replaceAuth :: Users -> UserId -> UserAuth -> Either String Users
replaceAuth users userId newAuth
    = modifyUserInfo users userId $ \userInfo ->
      case userStatus userInfo of
        Active status _ -> Right $ userInfo { userStatus = Active status newAuth }
        _ -> Left "Inactive users cannot have their authentication info changed"

-- | Replace the user authentication for the given user.
--   Returns 'Left' if the user does not exist, if the user existed but was not
--   active, the old password didn't match, or if the password was already upgraded.
upgradeAuth :: Users -> UserId -> PasswdPlain -> UserAuth -> Either String Users
upgradeAuth users userId passwd newAuth
    = modifyUserInfo users userId $ \userInfo ->
      case userStatus userInfo of
        Active status (OldUserAuth oldHash)
          | checkCryptAuthInfo oldHash passwd -> Right $ userInfo { userStatus = Active status newAuth }
          | otherwise                         -> Left "Password did not match user's old password"
        Active _ _ -> Left "This user's password has already been upgraded"
        _ -> Left "Inactive users cannot have their authentication info changed"

-- | Modify a single user. Returns 'Left' if the user does not
--   exist. This function isn't exported.
modifyUserInfo :: Users -> UserId -> (UserInfo -> Either String UserInfo) -> Either String Users
modifyUserInfo users (UserId userId) fn =
    case alterM fn userId (userIdMap users) of
      Nothing      -> Left $ "No user with ID " ++ show userId
      Just mnewmap -> liftM (\newMap -> users { userIdMap = newMap }) mnewmap

alterM :: (a -> Either String a) -> Int -> IntMap.IntMap a -> Maybe (Either String (IntMap.IntMap a))
alterM f k mp = case IntMap.lookup k mp of
  Just v  -> Just $ liftM (\v' -> IntMap.insert k v' mp) $ f v
  Nothing -> Nothing

-- | Rename a single user, regardless of account status. Returns either the
-- successfully altered Users structure or a `Maybe UserId` to indicate an
-- error: `Nothing` if the user does not exist and `Just uid` if there is
-- already a user by that name.
rename :: Users -> UserId -> UserName -> Either (Maybe UserId) Users
rename users uid uname = 
    case Map.lookup uname (userNameMap users) of
        Nothing   -> case modifyUserInfo users uid (\user -> Right $ user { userName = uname }) of
            Left _no_user -> Left Nothing
            Right new     -> Right new
        Just uid' -> Left $ Just uid'
 -- FIXME: this function should probably modify the other fields of Users

enumerateAll :: Users -> [(UserId, UserInfo)]
enumerateAll = mapFst UserId . IntMap.assocs . userIdMap
  where mapFst f = map $ \(x,y) -> (f x, y)

enumerateEnabled :: Users -> [(UserId, UserInfo)]
enumerateEnabled users = [ x | x@(_, UserInfo { userStatus = Active Enabled _ }) <- enumerateAll users ]


-- | Insertion fails if key is present
insertMaybe :: Ord k => k -> a -> Map.Map k a -> (Maybe (Map.Map k a))
insertMaybe k a m
    = case Map.insertLookupWithKey undefined k a m of
        (Nothing, m') -> Just m'
        _ -> Nothing

intInsertMaybe
    :: IntMap.Key -> a -> IntMap.IntMap a -> (Maybe (IntMap.IntMap a))
intInsertMaybe k a m
    = case IntMap.insertLookupWithKey undefined k a m of
        (Nothing, m') -> Just m'
        _ -> Nothing

$(deriveSafeCopy 0 'base ''Users)
