{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Dealing with Cabal.

module Stack.Package
  (readPackageDir
  ,readPackageUnresolvedDir
  ,readPackageUnresolvedIndex
  ,readPackageDescriptionDir
  ,readDotBuildinfo
  ,resolvePackage
  ,packageFromPackageDescription
  ,Package(..)
  ,PackageDescriptionPair(..)
  ,GetPackageFiles(..)
  ,GetPackageOpts(..)
  ,PackageConfig(..)
  ,buildLogPath
  ,PackageException (..)
  ,resolvePackageDescription
  ,packageDescTools
  ,packageDependencies
  ,autogenDir
  ,cabalFilePackageId
  ,gpdPackageIdentifier
  ,gpdPackageName
  ,gpdVersion)
  where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import           Data.List (isSuffixOf, partition, isPrefixOf)
import           Data.List.Extra (nubOrd)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8, decodeUtf8With)
import           Data.Text.Encoding.Error (lenientDecode)
import           Distribution.Compiler
import           Distribution.ModuleName (ModuleName)
import qualified Distribution.ModuleName as Cabal
import qualified Distribution.Package as D
import           Distribution.Package hiding (Package,PackageName,packageName,packageVersion,PackageIdentifier)
import qualified Distribution.PackageDescription as D
import           Distribution.PackageDescription hiding (FlagName)
import           Distribution.PackageDescription.Parse
import qualified Distribution.PackageDescription.Parse as D
import           Distribution.ParseUtils
import           Distribution.Simple.Utils
import           Distribution.System (OS (..), Arch, Platform (..))
import qualified Distribution.Text as D
import qualified Distribution.Types.CondTree as Cabal
import qualified Distribution.Types.ExeDependency as Cabal
import           Distribution.Types.ForeignLib
import qualified Distribution.Types.LegacyExeDependency as Cabal
import qualified Distribution.Types.UnqualComponentName as Cabal
import qualified Distribution.Verbosity as D
import           Distribution.Version (showVersion)
import           Lens.Micro (lens)
import qualified Hpack
import qualified Hpack.Config as Hpack
import           Path as FL
import           Path.Extra
import           Path.Find
import           Path.IO hiding (findFiles)
import           Stack.Build.Installed
import           Stack.Constants
import           Stack.Constants.Config
import           Stack.Prelude
import           Stack.PrettyPrint
import           Stack.Types.Build
import           Stack.Types.BuildPlan (ExeName (..))
import           Stack.Types.Compiler
import           Stack.Types.Config
import           Stack.Types.FlagName
import           Stack.Types.GhcPkgId
import           Stack.Types.Package
import           Stack.Types.PackageIdentifier
import           Stack.Types.PackageName
import           Stack.Types.Runner
import           Stack.Types.Version
import qualified System.Directory as D
import           System.FilePath (splitExtensions, replaceExtension)
import qualified System.FilePath as FilePath
import           System.IO.Error
import           System.Process.Run (runCmd, Cmd(..))

data Ctx = Ctx { ctxFile :: !(Path Abs File)
               , ctxDir :: !(Path Abs Dir)
               , ctxEnvConfig :: !EnvConfig
               }

instance HasPlatform Ctx
instance HasGHCVariant Ctx
instance HasLogFunc Ctx where
    logFuncL = configL.logFuncL
instance HasRunner Ctx where
    runnerL = configL.runnerL
instance HasConfig Ctx
instance HasBuildConfig Ctx
instance HasEnvConfig Ctx where
    envConfigL = lens ctxEnvConfig (\x y -> x { ctxEnvConfig = y })

-- | A helper function that performs the basic character encoding
-- necessary.
rawParseGPD
  :: MonadThrow m
  => Either PackageIdentifierRevision (Path Abs File)
  -> BS.ByteString
  -> m ([PWarning], GenericPackageDescription)
rawParseGPD key bs =
    case parseGenericPackageDescription chars of
       ParseFailed e -> throwM $ PackageInvalidCabalFile key e
       ParseOk warnings gpkg -> return (warnings,gpkg)
  where
    chars = T.unpack (dropBOM (decodeUtf8With lenientDecode bs))

    -- https://github.com/haskell/hackage-server/issues/351
    dropBOM t = fromMaybe t $ T.stripPrefix "\xFEFF" t

-- | Read the raw, unresolved package information from a file.
readPackageUnresolvedDir
  :: forall env. HasConfig env
  => Path Abs Dir -- ^ directory holding the cabal file
  -> Bool -- ^ print warnings?
  -> RIO env (GenericPackageDescription, Path Abs File)
readPackageUnresolvedDir dir printWarnings = do
  ref <- view $ runnerL.to runnerParsedCabalFiles
  (_, m) <- readIORef ref
  case M.lookup dir m of
    Just x -> return x
    Nothing -> do
      cabalfp <- findOrGenerateCabalFile dir
      bs <- liftIO $ BS.readFile $ toFilePath cabalfp
      (warnings, gpd) <- rawParseGPD (Right cabalfp) bs
      when printWarnings
        $ mapM_ (prettyWarnL . toPretty (toFilePath cabalfp)) warnings
      checkCabalFileName (gpdPackageName gpd) cabalfp
      let ret = (gpd, cabalfp)
      atomicModifyIORef' ref $ \(m1, m2) ->
        ((m1, M.insert dir ret m2), ret)
  where
    toPretty :: String -> PWarning -> [Doc AnsiAnn]
    toPretty src (PWarning x) =
      [ flow "Cabal file warning in"
      , fromString src <> ":"
      , flow x
      ]
    toPretty src (UTFWarning ln msg) =
      [ flow "Cabal file warning in"
      , fromString src <> ":" <> fromString (show ln) <> ":"
      , flow msg
      ]

    -- | Check if the given name in the @Package@ matches the name of the .cabal file
    checkCabalFileName :: MonadThrow m => PackageName -> Path Abs File -> m ()
    checkCabalFileName name cabalfp = do
        -- Previously, we just use parsePackageNameFromFilePath. However, that can
        -- lead to confusing error messages. See:
        -- https://github.com/commercialhaskell/stack/issues/895
        let expected = packageNameString name ++ ".cabal"
        when (expected /= toFilePath (filename cabalfp))
            $ throwM $ MismatchedCabalName cabalfp name

gpdPackageIdentifier :: GenericPackageDescription -> PackageIdentifier
gpdPackageIdentifier = fromCabalPackageIdentifier . D.package . D.packageDescription

gpdPackageName :: GenericPackageDescription -> PackageName
gpdPackageName = packageIdentifierName . gpdPackageIdentifier

gpdVersion :: GenericPackageDescription -> Version
gpdVersion = packageIdentifierVersion . gpdPackageIdentifier

-- | Read the 'GenericPackageDescription' from the given
-- 'PackageIdentifierRevision'.
readPackageUnresolvedIndex
  :: forall env. HasRunner env
  => (PackageIdentifierRevision -> IO ByteString) -- ^ load the raw bytes
  -> PackageIdentifierRevision
  -> RIO env GenericPackageDescription
readPackageUnresolvedIndex loadFromIndex pir@(PackageIdentifierRevision pi' _) = do
  ref <- view $ runnerL.to runnerParsedCabalFiles
  (m, _) <- readIORef ref
  case M.lookup pir m of
    Just gpd -> return gpd
    Nothing -> do
      bs <- liftIO $ loadFromIndex pir
      (_warnings, gpd) <- rawParseGPD (Left pir) bs
      let foundPI =
              fromCabalPackageIdentifier
            $ D.package
            $ D.packageDescription gpd
      unless (pi' == foundPI) $ throwM $ MismatchedCabalIdentifier pir foundPI
      atomicModifyIORef' ref $ \(m1, m2) ->
        ((M.insert pir gpd m1, m2), gpd)

-- | Reads and exposes the package information
readPackageDir
  :: forall env. HasConfig env
  => PackageConfig
  -> Path Abs Dir
  -> Bool -- ^ print warnings from cabal file parsing?
  -> RIO env (Package, Path Abs File)
readPackageDir packageConfig dir printWarnings =
  first (resolvePackage packageConfig) <$> readPackageUnresolvedDir dir printWarnings

-- | Get 'GenericPackageDescription' and 'PackageDescription' reading info
-- from given directory.
readPackageDescriptionDir
  :: forall env. HasConfig env
  => PackageConfig
  -> Path Abs Dir
  -> Bool -- ^ print warnings?
  -> RIO env (GenericPackageDescription, PackageDescriptionPair)
readPackageDescriptionDir config pkgDir printWarnings = do
    (gdesc, _) <- readPackageUnresolvedDir pkgDir printWarnings
    return (gdesc, resolvePackageDescription config gdesc)

-- | Read @<package>.buildinfo@ ancillary files produced by some Setup.hs hooks.
-- The file includes Cabal file syntax to be merged into the package description
-- derived from the package's .cabal file.
--
-- NOTE: not to be confused with BuildInfo, an Stack-internal datatype.
readDotBuildinfo :: MonadIO m
                 => Path Abs File
                 -> m HookedBuildInfo
readDotBuildinfo buildinfofp =
    liftIO $ readHookedBuildInfo D.silent (toFilePath buildinfofp)

-- | Resolve a parsed cabal file into a 'Package', which contains all of
-- the info needed for stack to build the 'Package' given the current
-- configuration.
resolvePackage :: PackageConfig
               -> GenericPackageDescription
               -> Package
resolvePackage packageConfig gpkg =
    packageFromPackageDescription
        packageConfig
        (genPackageFlags gpkg)
        (resolvePackageDescription packageConfig gpkg)

packageFromPackageDescription :: PackageConfig
                              -> [D.Flag]
                              -> PackageDescriptionPair
                              -> Package
packageFromPackageDescription packageConfig pkgFlags (PackageDescriptionPair pkgNoMod pkg) =
    Package
    { packageName = name
    , packageVersion = fromCabalVersion (pkgVersion pkgId)
    , packageLicense = license pkg
    , packageDeps = deps
    , packageFiles = pkgFiles
    , packageTools = packageDescTools pkg
    , packageGhcOptions = packageConfigGhcOptions packageConfig
    , packageFlags = packageConfigFlags packageConfig
    , packageDefaultFlags = M.fromList
      [(fromCabalFlagName (flagName flag), flagDefault flag) | flag <- pkgFlags]
    , packageAllDeps = S.fromList (M.keys deps)
    , packageLibraries =
        let mlib = do
              lib <- library pkg
              guard $ buildable $ libBuildInfo lib
              Just lib
         in
          case mlib of
            Nothing
              | null extraLibNames -> NoLibraries
              | otherwise -> error "Package has buildable sublibraries but no buildable libraries, I'm giving up"
            Just _ -> HasLibraries foreignLibNames
    , packageTests = M.fromList
      [(T.pack (Cabal.unUnqualComponentName $ testName t), testInterface t)
          | t <- testSuites pkgNoMod
          , buildable (testBuildInfo t)
      ]
    , packageBenchmarks = S.fromList
      [T.pack (Cabal.unUnqualComponentName $ benchmarkName b)
          | b <- benchmarks pkgNoMod
          , buildable (benchmarkBuildInfo b)
      ]
        -- Same comment about buildable applies here too.
    , packageExes = S.fromList
      [T.pack (Cabal.unUnqualComponentName $ exeName biBuildInfo)
        | biBuildInfo <- executables pkg
                                    , buildable (buildInfo biBuildInfo)]
    -- This is an action used to collect info needed for "stack ghci".
    -- This info isn't usually needed, so computation of it is deferred.
    , packageOpts = GetPackageOpts $
      \sourceMap installedMap omitPkgs addPkgs cabalfp ->
           do (componentsModules,componentFiles,_,_) <- getPackageFiles pkgFiles cabalfp
              componentsOpts <-
                  generatePkgDescOpts sourceMap installedMap omitPkgs addPkgs cabalfp pkg componentFiles
              return (componentsModules,componentFiles,componentsOpts)
    , packageHasExposedModules = maybe
          False
          (not . null . exposedModules)
          (library pkg)
    , packageBuildType = buildType pkg
    , packageSetupDeps = msetupDeps
    }
  where
    extraLibNames = S.union subLibNames foreignLibNames

    subLibNames
      = S.fromList
      $ map (T.pack . Cabal.unUnqualComponentName)
      $ mapMaybe libName -- this is a design bug in the Cabal API: this should statically be known to exist
      $ filter (buildable . libBuildInfo)
      $ subLibraries pkg

    foreignLibNames
      = S.fromList
      $ map (T.pack . Cabal.unUnqualComponentName . foreignLibName)
      $ filter (buildable . foreignLibBuildInfo)
      $ foreignLibs pkg

    -- Gets all of the modules, files, build files, and data files that
    -- constitute the package. This is primarily used for dirtiness
    -- checking during build, as well as use by "stack ghci"
    pkgFiles = GetPackageFiles $
        \cabalfp -> debugBracket ("getPackageFiles" <+> display cabalfp) $ do
             let pkgDir = parent cabalfp
             distDir <- distDirFromDir pkgDir
             env <- view envConfigL
             (componentModules,componentFiles,dataFiles',warnings) <-
                 runReaderT
                     (packageDescModulesAndFiles pkg)
                     (Ctx cabalfp (buildDir distDir) env)
             setupFiles <-
                 if buildType pkg `elem` [Nothing, Just Custom]
                 then do
                     let setupHsPath = pkgDir </> $(mkRelFile "Setup.hs")
                         setupLhsPath = pkgDir </> $(mkRelFile "Setup.lhs")
                     setupHsExists <- doesFileExist setupHsPath
                     if setupHsExists then return (S.singleton setupHsPath) else do
                         setupLhsExists <- doesFileExist setupLhsPath
                         if setupLhsExists then return (S.singleton setupLhsPath) else return S.empty
                 else return S.empty
             buildFiles <- liftM (S.insert cabalfp . S.union setupFiles) $ do
                 let hpackPath = pkgDir </> $(mkRelFile Hpack.packageConfig)
                 hpackExists <- doesFileExist hpackPath
                 return $ if hpackExists then S.singleton hpackPath else S.empty
             return (componentModules, componentFiles, buildFiles <> dataFiles', warnings)
    pkgId = package pkg
    name = fromCabalPackageName (pkgName pkgId)
    deps = M.filterWithKey (const . not . isMe) (M.union
        (packageDependencies pkg)
        -- We include all custom-setup deps - if present - in the
        -- package deps themselves. Stack always works with the
        -- invariant that there will be a single installed package
        -- relating to a package name, and this applies at the setup
        -- dependency level as well.
        (fromMaybe M.empty msetupDeps))
    msetupDeps = fmap
        (M.fromList . map (depName &&& depRange) . setupDepends)
        (setupBuildInfo pkg)

    -- Is the package dependency mentioned here me: either the package
    -- name itself, or the name of one of the sub libraries
    isMe name' = name' == name || packageNameText name' `S.member` extraLibNames

-- | Generate GHC options for the package's components, and a list of
-- options which apply generally to the package, not one specific
-- component.
generatePkgDescOpts
    :: (HasEnvConfig env, MonadThrow m, MonadReader env m, MonadIO m)
    => SourceMap
    -> InstalledMap
    -> [PackageName] -- ^ Packages to omit from the "-package" / "-package-id" flags
    -> [PackageName] -- ^ Packages to add to the "-package" flags
    -> Path Abs File
    -> PackageDescription
    -> Map NamedComponent (Set DotCabalPath)
    -> m (Map NamedComponent BuildInfoOpts)
generatePkgDescOpts sourceMap installedMap omitPkgs addPkgs cabalfp pkg componentPaths = do
    config <- view configL
    distDir <- distDirFromDir cabalDir
    let cabalMacros = autogenDir distDir </> $(mkRelFile "cabal_macros.h")
    exists <- doesFileExist cabalMacros
    let mcabalMacros =
            if exists
                then Just cabalMacros
                else Nothing
    let generate namedComponent binfo =
            ( namedComponent
            , generateBuildInfoOpts BioInput
                { biSourceMap = sourceMap
                , biInstalledMap = installedMap
                , biCabalMacros = mcabalMacros
                , biCabalDir = cabalDir
                , biDistDir = distDir
                , biOmitPackages = omitPkgs
                , biAddPackages = addPkgs
                , biBuildInfo = binfo
                , biDotCabalPaths = fromMaybe mempty (M.lookup namedComponent componentPaths)
                , biConfigLibDirs = configExtraLibDirs config
                , biConfigIncludeDirs = configExtraIncludeDirs config
                , biComponentName = namedComponent
                }
            )
    return
        ( M.fromList
              (concat
                   [ maybe
                         []
                         (return . generate CLib . libBuildInfo)
                         (library pkg)
                   , fmap
                         (\exe ->
                               generate
                                    (CExe (T.pack (Cabal.unUnqualComponentName (exeName exe))))
                                    (buildInfo exe))
                         (executables pkg)
                   , fmap
                         (\bench ->
                               generate
                                    (CBench (T.pack (Cabal.unUnqualComponentName (benchmarkName bench))))
                                    (benchmarkBuildInfo bench))
                         (benchmarks pkg)
                   , fmap
                         (\test ->
                               generate
                                    (CTest (T.pack (Cabal.unUnqualComponentName (testName test))))
                                    (testBuildInfo test))
                         (testSuites pkg)]))
  where
    cabalDir = parent cabalfp

-- | Input to 'generateBuildInfoOpts'
data BioInput = BioInput
    { biSourceMap :: !SourceMap
    , biInstalledMap :: !InstalledMap
    , biCabalMacros :: !(Maybe (Path Abs File))
    , biCabalDir :: !(Path Abs Dir)
    , biDistDir :: !(Path Abs Dir)
    , biOmitPackages :: ![PackageName]
    , biAddPackages :: ![PackageName]
    , biBuildInfo :: !BuildInfo
    , biDotCabalPaths :: !(Set DotCabalPath)
    , biConfigLibDirs :: !(Set FilePath)
    , biConfigIncludeDirs :: !(Set FilePath)
    , biComponentName :: !NamedComponent
    }

-- | Generate GHC options for the target. Since Cabal also figures out
-- these options, currently this is only used for invoking GHCI (via
-- stack ghci).
generateBuildInfoOpts :: BioInput -> BuildInfoOpts
generateBuildInfoOpts BioInput {..} =
    BuildInfoOpts
        { bioOpts = ghcOpts ++ cppOptions biBuildInfo
        -- NOTE for future changes: Due to this use of nubOrd (and other uses
        -- downstream), these generated options must not rely on multiple
        -- argument sequences.  For example, ["--main-is", "Foo.hs", "--main-
        -- is", "Bar.hs"] would potentially break due to the duplicate
        -- "--main-is" being removed.
        --
        -- See https://github.com/commercialhaskell/stack/issues/1255
        , bioOneWordOpts = nubOrd $ concat
            [extOpts, srcOpts, includeOpts, libOpts, fworks, cObjectFiles]
        , bioPackageFlags = deps
        , bioCabalMacros = biCabalMacros
        }
  where
    cObjectFiles =
        mapMaybe (fmap toFilePath .
                  makeObjectFilePathFromC biCabalDir biComponentName biDistDir)
                 cfiles
    cfiles = mapMaybe dotCabalCFilePath (S.toList biDotCabalPaths)
    -- Generates: -package=base -package=base16-bytestring-0.1.1.6 ...
    deps =
        concat
            [ case M.lookup name biInstalledMap of
                Just (_, Stack.Types.Package.Library _ident ipid _) -> ["-package-id=" <> ghcPkgIdString ipid]
                _ -> ["-package=" <> packageNameString name <>
                 maybe "" -- This empty case applies to e.g. base.
                     ((("-" <>) . versionString) . piiVersion)
                     (M.lookup name biSourceMap)]
            | name <- pkgs]
    pkgs =
        biAddPackages ++
        [ name
        | Dependency cname _ <- targetBuildDepends biBuildInfo
        , let name = fromCabalPackageName cname
        , name `notElem` biOmitPackages]
    ghcOpts = concatMap snd . filter (isGhc . fst) $ options biBuildInfo
      where
        isGhc GHC = True
        isGhc _ = False
    extOpts = map (("-X" ++) . D.display) (usedExtensions biBuildInfo)
    srcOpts =
        map
            (("-i" <>) . toFilePathNoTrailingSep)
            ([biCabalDir | null (hsSourceDirs biBuildInfo)] <>
             mapMaybe toIncludeDir (hsSourceDirs biBuildInfo) <>
             [autogenDir biDistDir,buildDir biDistDir] <>
             [makeGenDir (buildDir biDistDir)
             | Just makeGenDir <- [fileGenDirFromComponentName biComponentName]]) ++
        ["-stubdir=" ++ toFilePathNoTrailingSep (buildDir biDistDir)]
    toIncludeDir "." = Just biCabalDir
    toIncludeDir relDir = concatAndColapseAbsDir biCabalDir relDir
    includeOpts =
        map ("-I" <>) (configExtraIncludeDirs <> pkgIncludeOpts)
    configExtraIncludeDirs = S.toList biConfigIncludeDirs
    pkgIncludeOpts =
        [ toFilePathNoTrailingSep absDir
        | dir <- includeDirs biBuildInfo
        , absDir <- handleDir dir
        ]
    libOpts =
        map ("-l" <>) (extraLibs biBuildInfo) <>
        map ("-L" <>) (configExtraLibDirs <> pkgLibDirs)
    configExtraLibDirs = S.toList biConfigLibDirs
    pkgLibDirs =
        [ toFilePathNoTrailingSep absDir
        | dir <- extraLibDirs biBuildInfo
        , absDir <- handleDir dir
        ]
    handleDir dir = case (parseAbsDir dir, parseRelDir dir) of
       (Just ab, _       ) -> [ab]
       (_      , Just rel) -> [biCabalDir </> rel]
       (Nothing, Nothing ) -> []
    fworks = map (\fwk -> "-framework=" <> fwk) (frameworks biBuildInfo)

-- | Make the .o path from the .c file path for a component. Example:
--
-- @
-- executable FOO
--   c-sources:        cbits/text_search.c
-- @
--
-- Produces
--
-- <dist-dir>/build/FOO/FOO-tmp/cbits/text_search.o
--
-- Example:
--
-- λ> makeObjectFilePathFromC
--     $(mkAbsDir "/Users/chris/Repos/hoogle")
--     CLib
--     $(mkAbsDir "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist")
--     $(mkAbsFile "/Users/chris/Repos/hoogle/cbits/text_search.c")
-- Just "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist/build/cbits/text_search.o"
-- λ> makeObjectFilePathFromC
--     $(mkAbsDir "/Users/chris/Repos/hoogle")
--     (CExe "hoogle")
--     $(mkAbsDir "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist")
--     $(mkAbsFile "/Users/chris/Repos/hoogle/cbits/text_search.c")
-- Just "/Users/chris/Repos/hoogle/.stack-work/Cabal-x.x.x/dist/build/hoogle/hoogle-tmp/cbits/text_search.o"
-- λ>
makeObjectFilePathFromC
    :: MonadThrow m
    => Path Abs Dir          -- ^ The cabal directory.
    -> NamedComponent        -- ^ The name of the component.
    -> Path Abs Dir          -- ^ Dist directory.
    -> Path Abs File         -- ^ The path to the .c file.
    -> m (Path Abs File) -- ^ The path to the .o file for the component.
makeObjectFilePathFromC cabalDir namedComponent distDir cFilePath = do
    relCFilePath <- stripProperPrefix cabalDir cFilePath
    relOFilePath <-
        parseRelFile (replaceExtension (toFilePath relCFilePath) "o")
    addComponentPrefix <- fileGenDirFromComponentName namedComponent
    return (addComponentPrefix (buildDir distDir) </> relOFilePath)

-- | The directory where generated files are put like .o or .hs (from .x files).
fileGenDirFromComponentName
    :: MonadThrow m
    => NamedComponent -> m (Path b Dir -> Path b Dir)
fileGenDirFromComponentName namedComponent =
    case namedComponent of
        CLib -> return id
        CExe name -> makeTmp name
        CTest name -> makeTmp name
        CBench name -> makeTmp name
  where makeTmp name = do
            prefix <- parseRelDir (T.unpack name <> "/" <> T.unpack name <> "-tmp")
            return (</> prefix)

-- | Make the autogen dir.
autogenDir :: Path Abs Dir -> Path Abs Dir
autogenDir distDir = buildDir distDir </> $(mkRelDir "autogen")

-- | Make the build dir.
buildDir :: Path Abs Dir -> Path Abs Dir
buildDir distDir = distDir </> $(mkRelDir "build")

-- | Make the component-specific subdirectory of the build directory.
getBuildComponentDir :: Maybe String -> Maybe (Path Rel Dir)
getBuildComponentDir Nothing = Nothing
getBuildComponentDir (Just name) = parseRelDir (name FilePath.</> (name ++ "-tmp"))

-- | Get all dependencies of the package (buildable targets only).
packageDependencies :: PackageDescription -> Map PackageName VersionRange
packageDependencies pkg =
  M.fromListWith intersectVersionRanges $
  map (depName &&& depRange) $
  concatMap targetBuildDepends (allBuildInfo' pkg) ++
  maybe [] setupDepends (setupBuildInfo pkg)

-- | Get all dependencies of the package (buildable targets only).
--
-- This uses both the new 'buildToolDepends' and old 'buildTools'
-- information.
packageDescTools :: PackageDescription -> Map ExeName VersionRange
packageDescTools =
  M.fromList . concatMap tools . allBuildInfo'
  where
    tools bi = map go1 (buildTools bi) ++ map go2 (buildToolDepends bi)

    go1 :: Cabal.LegacyExeDependency -> (ExeName, VersionRange)
    go1 (Cabal.LegacyExeDependency name range) = (ExeName $ T.pack name, range)

    go2 :: Cabal.ExeDependency -> (ExeName, VersionRange)
    go2 (Cabal.ExeDependency _pkg name range) = (ExeName $ T.pack $ Cabal.unUnqualComponentName name, range)

-- | Variant of 'allBuildInfo' from Cabal that includes foreign
-- libraries; see <https://github.com/haskell/cabal/issues/4763>
allBuildInfo' :: PackageDescription -> [BuildInfo]
allBuildInfo' pkg = allBuildInfo pkg ++
  [ bi | flib <- foreignLibs pkg
       , let bi = foreignLibBuildInfo flib
       , buildable bi
  ]

-- | Get all files referenced by the package.
packageDescModulesAndFiles
    :: (MonadLogger m, MonadUnliftIO m, MonadReader Ctx m, MonadThrow m)
    => PackageDescription
    -> m (Map NamedComponent (Set ModuleName), Map NamedComponent (Set DotCabalPath), Set (Path Abs File), [PackageWarning])
packageDescModulesAndFiles pkg = do
    (libraryMods,libDotCabalFiles,libWarnings) <- -- FIXME add in sub libraries
        maybe
            (return (M.empty, M.empty, []))
            (asModuleAndFileMap libComponent libraryFiles)
            (library pkg)
    (executableMods,exeDotCabalFiles,exeWarnings) <-
        liftM
            foldTuples
            (mapM
                 (asModuleAndFileMap exeComponent executableFiles)
                 (executables pkg))
    (testMods,testDotCabalFiles,testWarnings) <-
        liftM
            foldTuples
            (mapM (asModuleAndFileMap testComponent testFiles) (testSuites pkg))
    (benchModules,benchDotCabalPaths,benchWarnings) <-
        liftM
            foldTuples
            (mapM
                 (asModuleAndFileMap benchComponent benchmarkFiles)
                 (benchmarks pkg))
    dfiles <- resolveGlobFiles
                    (extraSrcFiles pkg
                        ++ map (dataDir pkg FilePath.</>) (dataFiles pkg))
    let modules = libraryMods <> executableMods <> testMods <> benchModules
        files =
            libDotCabalFiles <> exeDotCabalFiles <> testDotCabalFiles <>
            benchDotCabalPaths
        warnings = libWarnings <> exeWarnings <> testWarnings <> benchWarnings
    return (modules, files, dfiles, warnings)
  where
    libComponent = const CLib
    exeComponent = CExe . T.pack . Cabal.unUnqualComponentName . exeName
    testComponent = CTest . T.pack . Cabal.unUnqualComponentName . testName
    benchComponent = CBench . T.pack . Cabal.unUnqualComponentName . benchmarkName
    asModuleAndFileMap label f lib = do
        (a,b,c) <- f lib
        return (M.singleton (label lib) a, M.singleton (label lib) b, c)
    foldTuples = foldl' (<>) (M.empty, M.empty, [])

-- | Resolve globbing of files (e.g. data files) to absolute paths.
resolveGlobFiles :: (MonadLogger m,MonadUnliftIO m,MonadReader Ctx m)
                 => [String] -> m (Set (Path Abs File))
resolveGlobFiles =
    liftM (S.fromList . catMaybes . concat) .
    mapM resolve
  where
    resolve name =
        if '*' `elem` name
            then explode name
            else liftM return (resolveFileOrWarn name)
    explode name = do
        dir <- asks (parent . ctxFile)
        names <-
            matchDirFileGlob'
                (FL.toFilePath dir)
                name
        mapM resolveFileOrWarn names
    matchDirFileGlob' dir glob =
        catch
            (matchDirFileGlob_ dir glob)
            (\(e :: IOException) ->
                  if isUserError e
                      then do
                          prettyWarnL
                              [ flow "Wildcard does not match any files:"
                              , styleFile $ fromString glob
                              , line <> flow "in directory:"
                              , styleDir $ fromString dir
                              ]
                          return []
                      else throwIO e)

-- | This is a copy/paste of the Cabal library function, but with
--
-- @ext == ext'@
--
-- Changed to
--
-- @isSuffixOf ext ext'@
--
-- So that this will work:
--
-- @
-- λ> matchDirFileGlob_ "." "test/package-dump/*.txt"
-- ["test/package-dump/ghc-7.8.txt","test/package-dump/ghc-7.10.txt"]
-- @
--
matchDirFileGlob_ :: (MonadLogger m, MonadIO m, HasRunner env, MonadReader env m) => String -> String -> m [String]
matchDirFileGlob_ dir filepath = case parseFileGlob filepath of
  Nothing -> liftIO $ throwString $
      "invalid file glob '" ++ filepath
      ++ "'. Wildcards '*' are only allowed in place of the file"
      ++ " name, not in the directory name or file extension."
      ++ " If a wildcard is used it must be with an file extension."
  Just (NoGlob filepath') -> return [filepath']
  Just (FileGlob dir' ext) -> do
    efiles <- liftIO $ try $ D.getDirectoryContents (dir FilePath.</> dir')
    let matches =
            case efiles of
                Left (_ :: IOException) -> []
                Right files ->
                    [ dir' FilePath.</> file
                    | file <- files
                    , let (name, ext') = splitExtensions file
                    , not (null name) && isSuffixOf ext ext'
                    ]
    when (null matches) $
        prettyWarnL
            [ flow "filepath wildcard"
            , "'" <> styleFile (fromString filepath) <> "'"
            , flow "does not match any files."
            ]
    return matches

-- | Get all files referenced by the benchmark.
benchmarkFiles
    :: (MonadLogger m, MonadIO m, MonadReader Ctx m, MonadThrow m)
    => Benchmark -> m (Set ModuleName, Set DotCabalPath, [PackageWarning])
benchmarkFiles bench = do
    dirs <- mapMaybeM resolveDirOrWarn (hsSourceDirs build)
    dir <- asks (parent . ctxFile)
    (modules,files,warnings) <-
        resolveFilesAndDeps
            (Just $ Cabal.unUnqualComponentName $ benchmarkName bench)
            (dirs ++ [dir])
            (bnames <> exposed)
            haskellModuleExts
    cfiles <- buildOtherSources build
    return (modules, files <> cfiles, warnings)
  where
    exposed =
        case benchmarkInterface bench of
            BenchmarkExeV10 _ fp -> [DotCabalMain fp]
            BenchmarkUnsupported _ -> []
    bnames = map DotCabalModule (otherModules build)
    build = benchmarkBuildInfo bench

-- | Get all files referenced by the test.
testFiles
    :: (MonadLogger m, MonadIO m, MonadReader Ctx m, MonadThrow m)
    => TestSuite
    -> m (Set ModuleName, Set DotCabalPath, [PackageWarning])
testFiles test = do
    dirs <- mapMaybeM resolveDirOrWarn (hsSourceDirs build)
    dir <- asks (parent . ctxFile)
    (modules,files,warnings) <-
        resolveFilesAndDeps
            (Just $ Cabal.unUnqualComponentName $ testName test)
            (dirs ++ [dir])
            (bnames <> exposed)
            haskellModuleExts
    cfiles <- buildOtherSources build
    return (modules, files <> cfiles, warnings)
  where
    exposed =
        case testInterface test of
            TestSuiteExeV10 _ fp -> [DotCabalMain fp]
            TestSuiteLibV09 _ mn -> [DotCabalModule mn]
            TestSuiteUnsupported _ -> []
    bnames = map DotCabalModule (otherModules build)
    build = testBuildInfo test

-- | Get all files referenced by the executable.
executableFiles
    :: (MonadLogger m, MonadIO m, MonadReader Ctx m, MonadThrow m)
    => Executable
    -> m (Set ModuleName, Set DotCabalPath, [PackageWarning])
executableFiles exe = do
    dirs <- mapMaybeM resolveDirOrWarn (hsSourceDirs build)
    dir <- asks (parent . ctxFile)
    (modules,files,warnings) <-
        resolveFilesAndDeps
            (Just $ Cabal.unUnqualComponentName $ exeName exe)
            (dirs ++ [dir])
            (map DotCabalModule (otherModules build) ++
             [DotCabalMain (modulePath exe)])
            haskellModuleExts
    cfiles <- buildOtherSources build
    return (modules, files <> cfiles, warnings)
  where
    build = buildInfo exe

-- | Get all files referenced by the library.
libraryFiles
    :: (MonadLogger m, MonadIO m, MonadReader Ctx m, MonadThrow m)
    => Library -> m (Set ModuleName, Set DotCabalPath, [PackageWarning])
libraryFiles lib = do
    dirs <- mapMaybeM resolveDirOrWarn (hsSourceDirs build)
    dir <- asks (parent . ctxFile)
    (modules,files,warnings) <-
        resolveFilesAndDeps
            Nothing
            (dirs ++ [dir])
            names
            haskellModuleExts
    cfiles <- buildOtherSources build
    return (modules, files <> cfiles, warnings)
  where
    names = bnames ++ exposed
    exposed = map DotCabalModule (exposedModules lib)
    bnames = map DotCabalModule (otherModules build)
    build = libBuildInfo lib

-- | Get all C sources and extra source files in a build.
buildOtherSources :: (MonadLogger m,MonadIO m,MonadReader Ctx m)
           => BuildInfo -> m (Set DotCabalPath)
buildOtherSources build =
    do csources <- liftM
                       (S.map DotCabalCFilePath . S.fromList)
                       (mapMaybeM resolveFileOrWarn (cSources build))
       jsources <- liftM
                       (S.map DotCabalFilePath . S.fromList)
                       (mapMaybeM resolveFileOrWarn (targetJsSources build))
       return (csources <> jsources)

-- | Get the target's JS sources.
targetJsSources :: BuildInfo -> [FilePath]
targetJsSources = jsSources

-- | A pair of package descriptions: one which modified the buildable
-- values of test suites and benchmarks depending on whether they are
-- enabled, and one which does not.
--
-- Fields are intentionally lazy, we may only need one or the other
-- value.
--
-- MSS 2017-08-29: The very presence of this data type is terribly
-- ugly, it represents the fact that the Cabal 2.0 upgrade did _not_
-- go well. Specifically, we used to have a field to indicate whether
-- a component was enabled in addition to buildable, but that's gone
-- now, and this is an ugly proxy. We should at some point clean up
-- the mess of Package, LocalPackage, etc, and probably pull in the
-- definition of PackageDescription from Cabal with our additionally
-- needed metadata. But this is a good enough hack for the
-- moment. Odds are, you're reading this in the year 2024 and thinking
-- "wtf?"
data PackageDescriptionPair = PackageDescriptionPair
  { pdpOrigBuildable :: PackageDescription
  , pdpModifiedBuildable :: PackageDescription
  }

-- | Evaluates the conditions of a 'GenericPackageDescription', yielding
-- a resolved 'PackageDescription'.
resolvePackageDescription :: PackageConfig
                          -> GenericPackageDescription
                          -> PackageDescriptionPair
resolvePackageDescription packageConfig (GenericPackageDescription desc defaultFlags mlib subLibs foreignLibs' exes tests benches) =
    PackageDescriptionPair
      { pdpOrigBuildable = go False
      , pdpModifiedBuildable = go True
      }
  where
        go modBuildable =
          desc {library =
                  fmap (resolveConditions rc updateLibDeps) mlib
               ,subLibraries =
                  map (\(n, v) -> (resolveConditions rc updateLibDeps v){libName=Just n})
                      subLibs
               ,foreignLibs =
                  map (\(n, v) -> (resolveConditions rc updateForeignLibDeps v){foreignLibName=n})
                      foreignLibs'
               ,executables =
                  map (\(n, v) -> (resolveConditions rc updateExeDeps v){exeName=n})
                      exes
               ,testSuites =
                  map (\(n,v) -> (resolveConditions rc (updateTestDeps modBuildable) v){testName=n})
                      tests
               ,benchmarks =
                  map (\(n,v) -> (resolveConditions rc (updateBenchmarkDeps modBuildable) v){benchmarkName=n})
                      benches}

        flags =
          M.union (packageConfigFlags packageConfig)
                  (flagMap defaultFlags)

        rc = mkResolveConditions
                (packageConfigCompilerVersion packageConfig)
                (packageConfigPlatform packageConfig)
                flags

        updateLibDeps lib deps =
          lib {libBuildInfo =
                 (libBuildInfo lib) {targetBuildDepends = deps}}
        updateForeignLibDeps lib deps =
          lib {foreignLibBuildInfo =
                 (foreignLibBuildInfo lib) {targetBuildDepends = deps}}
        updateExeDeps exe deps =
          exe {buildInfo =
                 (buildInfo exe) {targetBuildDepends = deps}}

        -- Note that, prior to moving to Cabal 2.0, we would set
        -- testEnabled/benchmarkEnabled here. These fields no longer
        -- exist, so we modify buildable instead here.  The only
        -- wrinkle in the Cabal 2.0 story is
        -- https://github.com/haskell/cabal/issues/1725, where older
        -- versions of Cabal (which may be used for actually building
        -- code) don't properly exclude build-depends for
        -- non-buildable components. Testing indicates that everything
        -- is working fine, and that this comment can be completely
        -- ignored. I'm leaving the comment anyway in case something
        -- breaks and you, poor reader, are investigating.
        updateTestDeps modBuildable test deps =
          let bi = testBuildInfo test
              bi' = bi
                { targetBuildDepends = deps
                , buildable = buildable bi && (if modBuildable then packageConfigEnableTests packageConfig else True)
                }
           in test { testBuildInfo = bi' }
        updateBenchmarkDeps modBuildable benchmark deps =
          let bi = benchmarkBuildInfo benchmark
              bi' = bi
                { targetBuildDepends = deps
                , buildable = buildable bi && (if modBuildable then packageConfigEnableBenchmarks packageConfig else True)
                }
           in benchmark { benchmarkBuildInfo = bi' }

-- | Make a map from a list of flag specifications.
--
-- What is @flagManual@ for?
flagMap :: [Flag] -> Map FlagName Bool
flagMap = M.fromList . map pair
  where pair :: Flag -> (FlagName, Bool)
        pair (MkFlag (fromCabalFlagName -> name) _desc def _manual) = (name,def)

data ResolveConditions = ResolveConditions
    { rcFlags :: Map FlagName Bool
    , rcCompilerVersion :: CompilerVersion 'CVActual
    , rcOS :: OS
    , rcArch :: Arch
    }

-- | Generic a @ResolveConditions@ using sensible defaults.
mkResolveConditions :: CompilerVersion 'CVActual -- ^ Compiler version
                    -> Platform -- ^ installation target platform
                    -> Map FlagName Bool -- ^ enabled flags
                    -> ResolveConditions
mkResolveConditions compilerVersion (Platform arch os) flags = ResolveConditions
    { rcFlags = flags
    , rcCompilerVersion = compilerVersion
    , rcOS = os
    , rcArch = arch
    }

-- | Resolve the condition tree for the library.
resolveConditions :: (Monoid target,Show target)
                  => ResolveConditions
                  -> (target -> cs -> target)
                  -> CondTree ConfVar cs target
                  -> target
resolveConditions rc addDeps (CondNode lib deps cs) = basic <> children
  where basic = addDeps lib deps
        children = mconcat (map apply cs)
          where apply (Cabal.CondBranch cond node mcs) =
                  if condSatisfied cond
                     then resolveConditions rc addDeps node
                     else maybe mempty (resolveConditions rc addDeps) mcs
                condSatisfied c =
                  case c of
                    Var v -> varSatisifed v
                    Lit b -> b
                    CNot c' ->
                      not (condSatisfied c')
                    COr cx cy ->
                      condSatisfied cx || condSatisfied cy
                    CAnd cx cy ->
                      condSatisfied cx && condSatisfied cy
                varSatisifed v =
                  case v of
                    OS os -> os == rcOS rc
                    Arch arch -> arch == rcArch rc
                    Flag flag ->
                      fromMaybe False $ M.lookup (fromCabalFlagName flag) (rcFlags rc)
                      -- NOTE:  ^^^^^ This should never happen, as all flags
                      -- which are used must be declared. Defaulting to
                      -- False.
                    Impl flavor range ->
                      case (flavor, rcCompilerVersion rc) of
                        (GHC, GhcVersion vghc) -> vghc `withinRange` range
                        (GHC, GhcjsVersion _ vghc) -> vghc `withinRange` range
                        (GHCJS, GhcjsVersion vghcjs _) ->
                          vghcjs `withinRange` range
                        _ -> False

-- | Get the name of a dependency.
depName :: Dependency -> PackageName
depName (Dependency n _) = fromCabalPackageName n

-- | Get the version range of a dependency.
depRange :: Dependency -> VersionRange
depRange (Dependency _ r) = r

-- | Try to resolve the list of base names in the given directory by
-- looking for unique instances of base names applied with the given
-- extensions, plus find any of their module and TemplateHaskell
-- dependencies.
resolveFilesAndDeps
    :: (MonadIO m, MonadLogger m, MonadReader Ctx m, MonadThrow m)
    => Maybe String         -- ^ Package component name
    -> [Path Abs Dir]       -- ^ Directories to look in.
    -> [DotCabalDescriptor] -- ^ Base names.
    -> [Text]               -- ^ Extensions.
    -> m (Set ModuleName,Set DotCabalPath,[PackageWarning])
resolveFilesAndDeps component dirs names0 exts = do
    (dotCabalPaths, foundModules, missingModules) <- loop names0 S.empty
    warnings <- liftM2 (++) (warnUnlisted foundModules) (warnMissing missingModules)
    return (foundModules, dotCabalPaths, warnings)
  where
    loop [] _ = return (S.empty, S.empty, [])
    loop names doneModules0 = do
        resolved <- resolveFiles dirs names exts
        let foundFiles = mapMaybe snd resolved
            (foundModules', missingModules') = partition (isJust . snd) resolved
            foundModules = mapMaybe (dotCabalModule . fst) foundModules'
            missingModules = mapMaybe (dotCabalModule . fst) missingModules'
        pairs <- mapM (getDependencies component) foundFiles
        let doneModules =
                S.union
                    doneModules0
                    (S.fromList (mapMaybe dotCabalModule names))
            moduleDeps = S.unions (map fst pairs)
            thDepFiles = concatMap snd pairs
            modulesRemaining = S.difference moduleDeps doneModules
        -- Ignore missing modules discovered as dependencies - they may
        -- have been deleted.
        (resolvedFiles, resolvedModules, _) <-
            loop (map DotCabalModule (S.toList modulesRemaining)) doneModules
        return
            ( S.union
                  (S.fromList
                       (foundFiles <> map DotCabalFilePath thDepFiles))
                  resolvedFiles
            , S.union
                  (S.fromList foundModules)
                  resolvedModules
            , missingModules)
    warnUnlisted foundModules = do
        let unlistedModules =
                foundModules `S.difference`
                S.fromList (mapMaybe dotCabalModule names0)
        return $
            if S.null unlistedModules
                then []
                else [ UnlistedModulesWarning
                           component
                           (S.toList unlistedModules)]
    warnMissing _missingModules = do
        return []
        -- TODO: bring this back - see
        -- https://github.com/commercialhaskell/stack/issues/2649
        {-
        cabalfp <- asks ctxFile
        return $
            if null missingModules
               then []
               else [ MissingModulesWarning
                           cabalfp
                           component
                           missingModules]
        -}


-- | Get the dependencies of a Haskell module file.
getDependencies
    :: (MonadReader Ctx m, MonadIO m, MonadLogger m)
    => Maybe String -> DotCabalPath -> m (Set ModuleName, [Path Abs File])
getDependencies component dotCabalPath =
    case dotCabalPath of
        DotCabalModulePath resolvedFile -> readResolvedHi resolvedFile
        DotCabalMainPath resolvedFile -> readResolvedHi resolvedFile
        DotCabalFilePath{} -> return (S.empty, [])
        DotCabalCFilePath{} -> return (S.empty, [])
  where
    readResolvedHi resolvedFile = do
        dumpHIDir <- getDumpHIDir
        dir <- asks (parent . ctxFile)
        case stripProperPrefix dir resolvedFile of
            Nothing -> return (S.empty, [])
            Just fileRel -> do
                let dumpHIPath =
                        FilePath.replaceExtension
                            (toFilePath (dumpHIDir </> fileRel))
                            ".dump-hi"
                dumpHIExists <- liftIO $ D.doesFileExist dumpHIPath
                if dumpHIExists
                    then parseDumpHI dumpHIPath
                    else return (S.empty, [])
    getDumpHIDir = do
        bld <- asks ctxDir
        return $ maybe bld (bld </>) (getBuildComponentDir component)

-- | Parse a .dump-hi file into a set of modules and files.
parseDumpHI
    :: (MonadReader Ctx m, MonadIO m, MonadLogger m)
    => FilePath -> m (Set ModuleName, [Path Abs File])
parseDumpHI dumpHIPath = do
    dir <- asks (parent . ctxFile)
    dumpHI <- liftIO $ fmap C8.lines (C8.readFile dumpHIPath)
    let startModuleDeps =
            dropWhile (not . ("module dependencies:" `C8.isPrefixOf`)) dumpHI
        moduleDeps =
            S.fromList $
            mapMaybe (D.simpleParse . T.unpack . decodeUtf8) $
            C8.words $
            C8.concat $
            C8.dropWhile (/= ' ') (fromMaybe "" $ listToMaybe startModuleDeps) :
            takeWhile (" " `C8.isPrefixOf`) (drop 1 startModuleDeps)
        thDeps =
            -- The dependent file path is surrounded by quotes but is not escaped.
            -- It can be an absolute or relative path.
            mapMaybe
                (fmap T.unpack .
                  (T.stripSuffix "\"" <=< T.stripPrefix "\"") .
                  T.dropWhileEnd (== '\r') . decodeUtf8 . C8.dropWhile (/= '"')) $
            filter ("addDependentFile \"" `C8.isPrefixOf`) dumpHI
    thDepsResolved <- liftM catMaybes $ forM thDeps $ \x -> do
        mresolved <- liftIO (forgivingAbsence (resolveFile dir x)) >>= rejectMissingFile
        when (isNothing mresolved) $
            prettyWarnL
                [ flow "addDependentFile path (Template Haskell) listed in"
                , styleFile $ fromString dumpHIPath
                , flow "does not exist:"
                , styleFile $ fromString x
                ]
        return mresolved
    return (moduleDeps, thDepsResolved)

-- | Try to resolve the list of base names in the given directory by
-- looking for unique instances of base names applied with the given
-- extensions.
resolveFiles
    :: (MonadIO m, MonadLogger m, MonadThrow m, MonadReader Ctx m)
    => [Path Abs Dir] -- ^ Directories to look in.
    -> [DotCabalDescriptor] -- ^ Base names.
    -> [Text] -- ^ Extensions.
    -> m [(DotCabalDescriptor, Maybe DotCabalPath)]
resolveFiles dirs names exts =
    forM names (\name -> liftM (name, ) (findCandidate dirs exts name))

-- | Find a candidate for the given module-or-filename from the list
-- of directories and given extensions.
findCandidate
    :: (MonadIO m, MonadLogger m, MonadThrow m, MonadReader Ctx m)
    => [Path Abs Dir]
    -> [Text]
    -> DotCabalDescriptor
    -> m (Maybe DotCabalPath)
findCandidate dirs exts name = do
    pkg <- asks ctxFile >>= parsePackageNameFromFilePath
    candidates <- liftIO makeNameCandidates
    case candidates of
        [candidate] -> return (Just (cons candidate))
        [] -> do
            case name of
                DotCabalModule mn
                  | D.display mn /= paths_pkg pkg -> logPossibilities dirs mn
                _ -> return ()
            return Nothing
        (candidate:rest) -> do
            warnMultiple name candidate rest
            return (Just (cons candidate))
  where
    cons =
        case name of
            DotCabalModule{} -> DotCabalModulePath
            DotCabalMain{} -> DotCabalMainPath
            DotCabalFile{} -> DotCabalFilePath
            DotCabalCFile{} -> DotCabalCFilePath
    paths_pkg pkg = "Paths_" ++ packageNameString pkg
    makeNameCandidates =
        liftM (nubOrd . concat) (mapM makeDirCandidates dirs)
    makeDirCandidates :: Path Abs Dir
                      -> IO [Path Abs File]
    makeDirCandidates dir =
        case name of
            DotCabalMain fp -> resolveCandidate dir fp
            DotCabalFile fp -> resolveCandidate dir fp
            DotCabalCFile fp -> resolveCandidate dir fp
            DotCabalModule mn ->
                liftM concat
                $ mapM
                  ((\ ext ->
                     resolveCandidate dir (Cabal.toFilePath mn ++ "." ++ ext))
                   . T.unpack)
                   exts
    resolveCandidate
        :: (MonadIO m, MonadThrow m)
        => Path Abs Dir -> FilePath.FilePath -> m [Path Abs File]
    resolveCandidate x y = do
        -- The standard canonicalizePath does not work for this case
        p <- parseCollapsedAbsFile (toFilePath x FilePath.</> y)
        exists <- doesFileExist p
        return $ if exists then [p] else []

-- | Warn the user that multiple candidates are available for an
-- entry, but that we picked one anyway and continued.
warnMultiple
    :: (MonadLogger m, HasRunner env, MonadReader env m)
    => DotCabalDescriptor -> Path b t -> [Path b t] -> m ()
warnMultiple name candidate rest =
    -- TODO: figure out how to style 'name' and the dispOne stuff
    prettyWarnL
        [ flow "There were multiple candidates for the Cabal entry \""
        , fromString . showName $ name
        , line <> bulletedList (map dispOne rest)
        , line <> flow "picking:"
        , dispOne candidate
        ]
  where showName (DotCabalModule name') = D.display name'
        showName (DotCabalMain fp) = fp
        showName (DotCabalFile fp) = fp
        showName (DotCabalCFile fp) = fp
        dispOne = fromString . toFilePath
          -- TODO: figure out why dispOne can't be just `display`
          --       (remove the .hlint.yaml exception if it can be)

-- | Log that we couldn't find a candidate, but there are
-- possibilities for custom preprocessor extensions.
--
-- For example: .erb for a Ruby file might exist in one of the
-- directories.
logPossibilities
    :: (MonadIO m, MonadThrow m, MonadLogger m, HasRunner env,
        MonadReader env m)
    => [Path Abs Dir] -> ModuleName -> m ()
logPossibilities dirs mn = do
    possibilities <- liftM concat (makePossibilities mn)
    unless (null possibilities) $ prettyWarnL
        [ flow "Unable to find a known candidate for the Cabal entry"
        , (styleModule . fromString $ D.display mn) <> ","
        , flow "but did find:"
        , line <> bulletedList (map display possibilities)
        , flow "If you are using a custom preprocessor for this module"
        , flow "with its own file extension, consider adding the file(s)"
        , flow "to your .cabal under extra-source-files."
        ]
  where
    makePossibilities name =
        mapM
            (\dir ->
                  do (_,files) <- listDir dir
                     return
                         (map
                              filename
                              (filter
                                   (isPrefixOf (D.display name) .
                                    toFilePath . filename)
                                   files)))
            dirs

-- | Get the filename for the cabal file in the given directory.
--
-- If no .cabal file is present, or more than one is present, an exception is
-- thrown via 'throwM'.
--
-- If the directory contains a file named package.yaml, hpack is used to
-- generate a .cabal file from it.
findOrGenerateCabalFile
    :: forall m env.
          (MonadIO m, MonadUnliftIO m, MonadLogger m, HasRunner env, HasConfig env, MonadReader env m)
    => Path Abs Dir -- ^ package directory
    -> m (Path Abs File)
findOrGenerateCabalFile pkgDir = do
    hpack pkgDir
    findCabalFile
  where
    findCabalFile :: m (Path Abs File)
    findCabalFile = findCabalFile' >>= either throwIO return

    findCabalFile' :: m (Either PackageException (Path Abs File))
    findCabalFile' = do
        files <- liftIO $ findFiles
            pkgDir
            (flip hasExtension "cabal" . FL.toFilePath)
            (const False)
        return $ case files of
            [] -> Left $ PackageNoCabalFileFound pkgDir
            [x] -> Right x
            -- If there are multiple files, ignore files that start with
            -- ".". On unixlike environments these are hidden, and this
            -- character is not valid in package names. The main goal is
            -- to ignore emacs lock files - see
            -- https://github.com/commercialhaskell/stack/issues/1897.
            (filter (not . ("." `isPrefixOf`) . toFilePath . filename) -> [x]) -> Right x
            _:_ -> Left $ PackageMultipleCabalFilesFound pkgDir files
      where hasExtension fp x = FilePath.takeExtension fp == "." ++ x

-- | Generate .cabal file from package.yaml, if necessary.
hpack :: (MonadIO m, MonadUnliftIO m, MonadLogger m, HasRunner env, HasConfig env, MonadReader env m)
      => Path Abs Dir -> m ()
hpack pkgDir = do
    let hpackFile = pkgDir </> $(mkRelFile Hpack.packageConfig)
    exists <- liftIO $ doesFileExist hpackFile
    when exists $ do
        prettyDebugL [flow "Running hpack on", display hpackFile]

        config <- view configL
        case configOverrideHpack config of
            HpackBundled -> do
                r <- liftIO $ Hpack.hpackResult (Just $ toFilePath pkgDir) Hpack.NoForce
                forM_ (Hpack.resultWarnings r) prettyWarnS
                let cabalFile = styleFile . fromString . Hpack.resultCabalFile $ r
                case Hpack.resultStatus r of
                    Hpack.Generated -> prettyDebugL
                        [flow "hpack generated a modified version of", cabalFile]
                    Hpack.OutputUnchanged -> prettyDebugL
                        [flow "hpack output unchanged in", cabalFile]
                    Hpack.AlreadyGeneratedByNewerHpack -> prettyWarnL
                        [ cabalFile
                        , flow "was generated with a newer version of hpack,"
                        , flow "please upgrade and try again."
                        ]
                    Hpack.ExistingCabalFileWasModifiedManually -> prettyWarnL
                        [ flow "WARNING: "
                        , cabalFile
                        , flow " was modified manually.  Ignoring package.yaml in favor of cabal file."
                        , flow "If you want to use package.yaml instead of the cabal file, "
                        , flow "then please delete the cabal file."
                        ]
            HpackCommand command -> do
                envOverride <- getMinimalEnvOverride
                let cmd = Cmd (Just pkgDir) command envOverride []
                runCmd cmd Nothing

-- | Path for the package's build log.
buildLogPath :: (MonadReader env m, HasBuildConfig env, MonadThrow m)
             => Package -> Maybe String -> m (Path Abs File)
buildLogPath package' msuffix = do
  env <- ask
  let stack = getProjectWorkDir env
  fp <- parseRelFile $ concat $
    packageIdentifierString (packageIdentifier package') :
    maybe id (\suffix -> ("-" :) . (suffix :)) msuffix [".log"]
  return $ stack </> $(mkRelDir "logs") </> fp

-- Internal helper to define resolveFileOrWarn and resolveDirOrWarn
resolveOrWarn :: (MonadLogger m, MonadIO m, MonadReader Ctx m)
              => Text
              -> (Path Abs Dir -> String -> m (Maybe a))
              -> FilePath.FilePath
              -> m (Maybe a)
resolveOrWarn subject resolver path =
  do cwd <- liftIO getCurrentDir
     file <- asks ctxFile
     dir <- asks (parent . ctxFile)
     result <- resolver dir path
     when (isNothing result) $
       prettyWarnL
           [ fromString . T.unpack $ subject -- TODO: needs style?
           , flow "listed in"
           , maybe (display file) display (stripProperPrefix cwd file)
           , flow "file does not exist:"
           , styleDir . fromString $ path
           ]
     return result

-- | Resolve the file, if it can't be resolved, warn for the user
-- (purely to be helpful).
resolveFileOrWarn :: (MonadIO m,MonadLogger m,MonadReader Ctx m)
                  => FilePath.FilePath
                  -> m (Maybe (Path Abs File))
resolveFileOrWarn = resolveOrWarn "File" f
  where f p x = liftIO (forgivingAbsence (resolveFile p x)) >>= rejectMissingFile

-- | Resolve the directory, if it can't be resolved, warn for the user
-- (purely to be helpful).
resolveDirOrWarn :: (MonadIO m,MonadLogger m,MonadReader Ctx m)
                 => FilePath.FilePath
                 -> m (Maybe (Path Abs Dir))
resolveDirOrWarn = resolveOrWarn "Directory" f
  where f p x = liftIO (forgivingAbsence (resolveDir p x)) >>= rejectMissingDir

-- | Extract the @PackageIdentifier@ given an exploded haskell package
-- path.
cabalFilePackageId
    :: (MonadIO m, MonadThrow m)
    => Path Abs File -> m PackageIdentifier
cabalFilePackageId fp = do
    pkgDescr <- liftIO (D.readGenericPackageDescription D.silent $ toFilePath fp)
    (toStackPI . D.package . D.packageDescription) pkgDescr
  where
    toStackPI (D.PackageIdentifier (D.unPackageName -> name) ver) = do
        name' <- parsePackageNameFromString name
        ver' <- parseVersionFromString (showVersion ver)
        return (PackageIdentifier name' ver')
