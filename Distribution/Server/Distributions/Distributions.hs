{-# LANGUAGE
    RecordWildCards
  #-}

module Distribution.Server.Distributions.Distributions
    ( DistroName
    , Distributions
    , emptyDistributions
    , addDistro
    , removeDistro
    , enumerate
    , isDistribution
    , DistroVersions
    , emptyDistroVersions
    , DistroPackageInfo(..)
    , addPackage
    , dropPackage
    , removeDistroVersions
    , distroStatus
    , packageStatus
    , distroPackageStatus
    , getDistroMaintainers
    , modifyDistroMaintainers
    ) where

import qualified Data.Map as Map
import qualified Data.Set as Set

import Distribution.Server.Distributions.Types
import qualified Distribution.Server.Users.Group as Group
import Distribution.Server.Users.Group (UserList)

import Distribution.Package

import Data.List (foldl')
import Data.Maybe (fromJust)

emptyDistributions :: Distributions
emptyDistributions = Distributions Map.empty

emptyDistroVersions :: DistroVersions
emptyDistroVersions = DistroVersions Map.empty Map.empty

--- Distribution updating

isDistribution :: DistroName -> Distributions -> Bool
isDistribution distro distros
    = Map.member distro (nameMap distros)

-- | Add a distribution. Returns 'Nothing' if the
-- name is already in use.
addDistro :: DistroName -> Distributions -> Maybe Distributions
addDistro name distros
    | isDistribution name distros = Nothing
    | otherwise = Just . Distributions $ Map.insert name Group.empty (nameMap distros)


-- | List all known distributions
enumerate :: Distributions -> [DistroName]
enumerate distros = Map.keys (nameMap distros)

--- Queries

-- | For a particular distribution, which packages do they have, and
-- at which version.
distroStatus :: DistroName -> DistroVersions -> [(PackageName, DistroPackageInfo)]
distroStatus distro distros
    = let packageNames = maybe [] Set.toList (Map.lookup distro $ distroMap distros)
          f package = let infoMap = fromJust $ Map.lookup package (packageDistroMap distros)
                          info = fromJust $ Map.lookup distro infoMap
                      in (package, info)
      in map f packageNames

-- | For a particular package, which distributions contain it and at which
-- version.
packageStatus :: PackageName -> DistroVersions -> [(DistroName, DistroPackageInfo)]
packageStatus package dv = maybe [] Map.toList (Map.lookup package $ packageDistroMap dv)

distroPackageStatus :: DistroName -> PackageName -> DistroVersions -> Maybe DistroPackageInfo
distroPackageStatus distro package dv = Map.lookup distro =<< Map.lookup package (packageDistroMap dv)

--- Removing

-- | Remove a distirbution from the list of known distirbutions
removeDistro :: DistroName -> Distributions -> Distributions
removeDistro distro distros = distros { nameMap = Map.delete distro (nameMap distros) }

-- | Drop all packages for a distribution.
removeDistroVersions :: DistroName -> DistroVersions -> DistroVersions
removeDistroVersions distro dv
    = let packageNames = maybe [] Set.toList (Map.lookup distro $ distroMap dv)
      in foldl' (flip $ dropPackage distro) dv packageNames

--- Updating

-- | Flag a package as no longer being distributed
dropPackage :: DistroName -> PackageName -> DistroVersions -> DistroVersions
dropPackage distro package dv@DistroVersions{..}
    = dv
      { packageDistroMap = Map.update pUpdate package packageDistroMap
      , distroMap  = Map.update dUpdate distro distroMap
      }
 where pUpdate infoMap = 
           case Map.delete distro infoMap of
             infoMap'
                 -> if Map.null infoMap'
                    then Nothing
                    else Just infoMap'

       dUpdate packageNames =
           case Set.delete package packageNames of
             packageNames'
                 -> if Set.null packageNames'
                    then Nothing
                    else Just packageNames'

-- | Add a package for a distribution. If the distribution already
-- had information for the specified package, that information is replaced.
addPackage :: DistroName -> PackageName -> DistroPackageInfo
           -> DistroVersions -> DistroVersions
addPackage distro package info dv@DistroVersions{..}
    = dv
      { packageDistroMap = Map.insertWith'
                      (const $ Map.insert distro info)
                      package
                      (Map.singleton distro info)
                      packageDistroMap

      , distroMap  = Map.insertWith  -- should be insertWith'?
                      (const $ Set.insert package)
                      distro
                      (Set.singleton package)
                      distroMap
      }

getDistroMaintainers :: DistroName -> Distributions -> Maybe UserList
getDistroMaintainers name = Map.lookup name . nameMap

modifyDistroMaintainers :: DistroName -> (UserList -> UserList) -> Distributions -> Distributions
modifyDistroMaintainers name func dists = dists {nameMap = Map.update (Just . func) name (nameMap dists) }


