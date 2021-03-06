{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE KindSignatures,
NamedFieldPuns, CPP, FlexibleInstances, ScopedTypeVariables,
LiberalTypeSynonyms, ViewPatterns, PatternGuards,
UndecidableInstances, BangPatterns, MagicHash #-}

#define _HERE ( __FILE__ ++ ":" ++ show ( __LINE__ :: Int ))

-- can compile this module to make an executable that writes our unparsed Appfl STG
-- and GHC STG to files with .{appfl,ghc}syn suffixes
--
-- ghc --make -package ghc -main-is FromGHC.FromGHC.amain FromGHC.hs -o hs2appfl
--
-- executable usage is: hs2appfl infile
-- It assumes a prelude directory with the AppflPrelude and APPFL base
-- in $PWD.  i.e. It's Fragile
module FromGHC.FromGHC
  ( ghc2stg
  , compileAndThen
  , writeGhcSyn
  , writeAppflSyn
  , printAppflSyn
  , printGhcSyn
  , target
  , amain
  )
where


-- As much as practical, I'll be explicit about what comes from where,
-- and what it's related to.  It's hard enough dealing with the
-- massive GHC codebase.

---------------------------------------- Local (APPFL) imports
import           ADT as A
import           AST as A
import           FromGHC.BuiltIn
import           FromGHC.Naming
import           FromGHC.PrettySTG
import           FromGHC.PruneSTG
import           WiredIn (noExhaustName)

import           Analysis (defAlt)
import           State hiding (liftM)
import           Util
import qualified PPrint as A

---------------------------------------- Standard library modules
import           Data.Map (Map)
import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set

import           Data.List as List
                 ( nub, nubBy, unfoldr, insertBy
                 , isPrefixOf, isSuffixOf, intersperse)
import           Data.Maybe (isJust, maybeToList, catMaybes)
import           Data.Function (on)
import           Debug.Trace
import           Data.Char (ord)
import           Control.Monad.Trans
import           Control.Monad.Trans.Except
import           Control.Monad
import           System.Exit (ExitCode (..), exitWith)
import           System.Environment (getArgs, lookupEnv)


---------------------------------------- GHC specific stuff

-- Note: I'm Working on importing from the original modules instead of
-- using re-exports from GHC. This is useful when I want to go see what's
-- _really_ going on in the source.

-- Where to find support libs on this system
import           GHC.Paths (libdir)

-- GHC API
import           GHC
                 -- Initialization
                 ( defaultErrorHandler, defaultCleanupHandler

                 -- Enter the GhcMonad with the (Ghc a) implementation
                 , runGhc

                 -- safely set new DynFlags (checked for consistency)
                 , setSessionDynFlags

                 -- Targets are source files
                 , guessTarget, addTarget

                 -- Loading/compiling
                 , load, LoadHowMuch (..)
                 , parseModule, typecheckModule, desugarModule, coreModule

                 -- Inspecting the module structure of the program
                 , ModSummary(..), Module, ModLocation (..)
                 , getModSummary, getModuleGraph
                 , moduleName
                 )

-- The GhcMonad. The Ghc and GhcT types are defined here.
import           GhcMonad
                 ( GhcMonad (..), printException
                 , getSessionDynFlags
                 )

import           ErrUtils (prettyPrintGhcErrors)

-- DynFlags determine most of the run-time behavior of GHC, notably
import           DynFlags
                 ( DynFlags (..), ExtensionFlag (..)
                 , HscTarget (..), GhcLink (..)
                 , defaultFatalMessager
                 , defaultFlushOut
                 , xopt_set, xopt_unset -- for LANGUAGE Extensions
                 )

import           HscTypes
                 ( HscEnv (..), CgGuts (..)
                 , isBootSummary, handleSourceError)

-- simplifying and tidying Core
import           HscMain   ( hscSimplify )
import           TidyPgm   ( tidyProgram )
import           CorePrep  ( corePrepPgm )

-- Getting STG from Core
import           CoreSyn   ( CoreProgram )
import           CoreToStg ( coreToStg   )
import           SimplStg  ( stg2stg     )

-- Finding where (in the source file) something came from
import           SrcLoc
                 ( SrcSpan(..)
                 , srcSpanStartLine, srcSpanEndLine
                 , srcSpanStartCol, srcSpanEndCol
                 , srcSpanFile)


-- Nodes of the STG AST
import           CoreSyn ( AltCon (..) )
import           StgSyn
                 ( StgBinding, GenStgBinding (..)
                 , StgExpr, GenStgExpr (..), StgOp (..)
                 , StgRhs, GenStgRhs (..)
                 , StgArg, GenStgArg (..)
                 , StgAlt, AltType (..)
                 )

-- Some of the constructs embedded in the STG AST
import           DataCon as G
                 ( DataCon
                 , isVanillaDataCon, dataConTag
                 , dataConTyCon, dataConRepType
                 , dataConWrapId, dataConWrapId_maybe
                 , isUnboxedTupleCon
                 )
import           TyCon as G ( TyCon, TyConParent (..)
                            , isDataTyCon, tyConParent )
import           TypeRep (Type (..), ) -- Analagous to our MonoType
import           Literal ( Literal (..) )
import           PrimOp ( PrimOp (..))

-- Id is an alias for Var, but it's used where you should expect the Id
-- constructor of the Var type. Vars add metadata to identifiers (Names)
import           Var (Var (..), Id, idDetails, isId )
import           IdInfo (IdDetails(..))

-- Name is the basic identifier type. NamedThings have a Name (accessed with
-- getName).
import           Name
                 ( Name, NamedThing (..)
                 , getOccString, nameSrcSpan )

-- FastStrings
import           FastString (mkFastString, unpackFS)

-- Profiling.  Don't need this except for type signatures
import           CostCentre ( CollectedCCs )

-- GHC's Pretty Printing facilities
import qualified Outputable as G


amain = do
  (i:_) <- getArgs
  Just cwd <- lookupEnv "PWD"
  let prld = cwd ++ "/prelude/"
  (ghc, (ts,os)) <- compileAndThen (return . g2a) prld i
  writeFile (i ++ ".appflsyn") (show $ A.unparse ts A.$+$ A.unparse os)
  writeFile (i ++ ".ghcsyn") (show $ pprGhcSyn ghc)


-- For in-progress tests. Note that $PWD is appfl/codegen when loading
-- this file in an Emacs Cabal REPL.  I have a feeling that's not true
-- when running GHCi from the command line.
testDir = "../test/haskell/"
testPreludeDir = "../prelude/"
target f = testDir ++ f


printGhcSyn file = writeGhcSyn file "/dev/stdout" >> putStrLn ""
writeGhcSyn infile outfile = do
  (_,stg) <- compile testPreludeDir infile
  writeFile outfile (show (pprGhcSyn stg))

compile prld file = compileAndThen pure prld file

printAppflSyn file = writeAppflSyn file "/dev/stdout" >> putStrLn ""

writeAppflSyn infile outfile =
  do
    (ghc, (ts,os)) <- compileAndThen (return . g2a) testPreludeDir infile
    writeFile outfile (show $ A.unparse ts A.$+$ A.unparse os)


ghc2stg preludeDir file = compileAndThen (return . g2a) preludeDir file >>= return . snd

-- stgFun gives access to GHC Stg within the GHC Monad
compileAndThen stgFun preludeDir file = do

  -- Install an error handler with functions for printing errors and flushing
  -- the stdout stream
  defaultErrorHandler defaultFatalMessager defaultFlushOut $ do

    -- Enter the GHC monad, giving it the directory "where GHC's library files
    -- reside."  See [Note topdir] in compiler/main/SysTools.hs in the GHC repo
    runGhc (Just libdir) $ do

      -- Need to modify the default DynFlags before doing anything.
      -- Default flags are defined as a function of a Settings object in
      -- compiler/main/DynFlags.hs
      -- The initialization process creates this Settings object in
      -- compiler/main/SysTools.hs:initSysTools

      oldFlags <- getSessionDynFlags
      let dflags = makeAppflFlags preludeDir oldFlags

      -- If we get source errors, exit with a message.
      -- They're already printed out (not sure how/where that happens)
      -- so we don't need to do anything with the exception.
      handleSourceError
        (\err -> do
            printException err
            liftIO $ do
              putStrLn "\n  \27[31mCompilation Failed\27[0m"
              exitWith $ ExitFailure 1 ) $ do


      setSessionDynFlags dflags
      -- construct (and add) a Target from the given file name.  The
      -- file's extension (and potentially some of the DynFlags)
      -- determine how the file is to be processed, i.e. which Phase
      -- of the compilation to start at.  For APPFL, this will
      -- probably always be *.hs files, so we may want to error on
      -- other inputs (as opposed to letting GHC try to do something
      -- with it)
      guessTarget file Nothing >>= addTarget

      -- An alternative approach to enforcing inclusion of our Prelude
      -- would be to allow the implicit Prelude and add ours as a target.
      -- There'd be no guarantees on what was referenced in the code though
      -- so there'd be a greater chance of failing on our end.
      --      guessTarget (preludeDir ++ "AppflPrelude.hs") Nothing >>= addTarget

      -- GHC.load normally initiates most of the heavy lifting for the
      -- compiler.  When the hscTarget is HscNothing (as it is here),
      -- this only incurs module dependency analysis, parsing,
      -- typechecking and the construction of an interface (ModIface).
      -- With -fwrite-interface, *.hi file(s) may be written to
      -- disk. We could turn that off explicitly if necessary.
      load LoadAllTargets
      -- It's not (yet) clear if it's strictly necessary to use the
      -- 'load' function.  There's a lot going on in there.
      -- If GHC.compileCore is any indicator, it *is* important:
      --  it calls 'load' and then parses and typechecks again before
      --  producing a CoreModule (not exactly what we want)

      modGraph <- getModuleGraph


      -- pull the ModGuts out of the parsed -> typechecked ->
      -- desugared modules. The ModGuts objects should have a
      -- CoreProgram (and other data relevant to a program's Core
      -- representation)
      modGuts <- mapM (liftM coreModule .
                      -- Left-fish operator (as I call it) composes
                      -- monadic operations right to left (as in (.) )
                      desugarModule <=< typecheckModule <=< parseModule)
                 -- I don't think we'll see .hs-boot files, but let's
                 -- be safe and filter them out since I don't know
                 -- what to do with them.
                 . filter (not . isBootSummary) $ modGraph


      -- Now we simplify the core.  This is where transformations and
      -- optimizations happen, so we definitely want this.
      hscEnv <- getSession

      -- CgGuts are a reduced form of ModGuts. They hold information necessary
      -- for Core to STG translation.
      (cgGuts, modDetails) <-
        mapAndUnzipM (liftIO . tidyProgram hscEnv <=< liftIO . hscSimplify hscEnv) modGuts
        -- Simplifying and Tidying seem to be useful, but not strictly necessary
        -- to get the Core and ship it off to STG

      (nestedStg, ccs) <- mapAndUnzipM gutsToSTG cgGuts
      dflags     <- getSessionDynFlags
      let stg = concat nestedStg
      res <- stgFun stg
      return $ (stg, res)


-- | Modify a DynFlags to include the settings that we want to enforce
-- during compilation.
makeAppflFlags :: FilePath -- | Location of AppflPrelude.hs and APPFL subdir
               -> DynFlags -- | Base DynFlags (get from GhcMonad)
               -> DynFlags -- | Modified DynFlags
makeAppflFlags preludeDir
  flags@DynFlags { importPaths  = oldIPaths }
  =
  -- fold in the requisite language extensions
  foldr xoptModify newFlags appflExts

  where
    xoptModify :: (ExtensionFlag, Bool) -> DynFlags -> DynFlags
    xoptModify (xflag, turnOn) flags
      | turnOn    = xopt_set flags xflag
      | otherwise = xopt_unset flags xflag

    newFlags =
      flags {
      -- hscTarget determines what form the backend takes (Native,
      -- LLVM, etc.)  We don't want any code generation but our own,
      -- so HscNothing is appropriate
      hscTarget      = HscNothing

      -- When using HscNothing, Linking appears to only happen
      -- if GHC is being used as an interface to ld (e.g. if a
      -- .o file is given as an argument) or if explicitly
      -- requested with flags.  Linking generally means writing
      -- files to disk, so it's turned off for now.
      , ghcLink        = NoLink

      -- Make sure our Prelude and Base libs are visible.
      -- Unfortunately, we can't implicitly import them (as far as I've found)
      , importPaths    = oldIPaths ++ [preludeDir, preludeDir ++ "/APPFL/" ]

      -- Should parameterize this (maybe with Options.h?)
      , verbosity      = 0
      }

-- | List of language extensions we want to require of APPFL-haskell
-- source files.
appflExts :: [(ExtensionFlag, Bool)]
appflExts =
  [
    -- We want to enforce the use of our Prelude to have a better
    -- chance of getting full STG programs from GHC
    (Opt_ImplicitPrelude, False)

    -- We don't actually need RebindableSyntax (yet!) given the name mapping we have in
    -- FromGHC.BuiltIn.  Rebindable syntax actually introduces problems in strict
    -- evaluation: if-then-else expressions are desugared into a call to an 'ifThenElse'
    -- function, which loses the "short-circuiting" property of the normal case expression
    -- generated.  Since both branches are passed to this function, if either is bottom,
    -- strict evaluation breaks the programmers expectation of if-then-else.
    -- The comment below is left for posterity.

    -- We want to escape as much of the built-in stuff as possible,
    -- so we'll use our own "fromInteger", "ifthenelse" etc.
    -- This actually implies NoImplicitPrelude; I'm just being extra explicit
    -- see the GHC Syntactic Extensions docs or the definitions in APPFL.Base
    -- , (Opt_RebindableSyntax, True)
  ]


-- | In the GhcMonad, given a CgGuts object, pull out the
--   CoreProgram and convert it to STG
gutsToSTG :: GhcMonad m => CgGuts -> m ([StgBinding], CollectedCCs)
gutsToSTG CgGuts { cg_module -- :: Module
                 , cg_binds  -- :: CoreProgram
                 , cg_tycons -- :: [TyCon]
                 }
  =
  do
    ModSummary{ms_location} <- getModSummary $ moduleName cg_module
      -- As far as I know, it's entirely possible that the session
      -- and its DynFlags have been modified since they were bound
      -- above.  Grab them again here for safety.
    hscEnv <- getSession
    dflags <- getSessionDynFlags
    let datacons = filter G.isDataTyCon cg_tycons

    liftIO $ toStg cg_module cg_binds ms_location datacons hscEnv dflags


-- | Convert a CoreProgram to STG (includes the stg2stg pass,
--   which is where profiling information is added and any IO
--   may occur.
toStg :: Module             -- this module (being compiled)
      -> CoreProgram        -- its Core bindings
      -> ModLocation        -- Where is it? (I think)
      -> [G.TyCon]          -- Its data constructors
      -> HscEnv             -- The compiler session
      -> DynFlags           -- Dynamic flags
      -> IO ([StgBinding],  -- The STG program
              CollectedCCs) -- Cost centres (don't care about these)
toStg mod core modLoc datacons hscEnv dflags =
  do
    prepped   <- corePrepPgm hscEnv modLoc core datacons

    --    core2stg, by inspection, does not produce IO, despite its type
    stg_binds <- coreToStg dflags mod prepped

    -- Not clear if this is necessary.
    -- It may only do cost center analysis, which we don't use for now
    stg2stg dflags mod stg_binds


-- | Used to indicate an unsanitized STG tree
data Dirty = Dirty

instance A.Unparse Dirty where
  unparse _ = A.text "Dirty"

-- | Used in the Appfl STG metadata fields for Post-G2A work.  Currently, this
-- is only used to resolve typeclass dictionaries, but could be expanded if
-- necessary.
data PostG2A
  = IncompleteDict {dictId :: Id}
  | Complete


-- | Alias to indicate a fully prepped and sanitized STG tree
type Clean = ()


-- g2a prefix => GHC to APPFL

-- | A TyMap holds the information required to build TyCons (TyCon name
-- -> (GHC)DataCon).  We only see one data constructor at a time in
-- the STG syntax, so we add them to the Map as we see them. Once
-- accumulated, the DataCons can be translate to APPFL DataCon.  This
-- translation does not happen immediately because we want to preserve
-- the ordering of constructors in the data definition (based on the
-- ConTag field of the GHC DataCons).  This tag is occasionally used by
-- GHC (in deriving Enum instances, in particular) and we don't want
-- to break that logic.
type TyMap = Map A.Con [G.DataCon]


-- | The DictInfo datatype holds information accumulated during the G2A
-- translation for replacing the GHC typeclass dictionaries with Appfl
-- equivalents.
data DictInfo
  = DictInfo
    { appflCompatAList :: [ ((Name, [Type]), AppflName) ]
    -- ^ The mapping of (Class, Type(s)) instance pairs to the AppflName that is
    -- bound to the compat implementation. The Names are always Names of
    -- Classes. This is not a Data.Map because there's no Ord instance for
    -- Types, nor is making one simple.

    , undefs :: Set Id
    -- ^ The DFunIds that we still need to find an Appfl equivalent for.  If
    -- there are any left after postprocessing of the (Appfl) STG, we're in
    -- trouble.

    ,  haveDefs :: Set Id
    -- ^ The DFunIds that were bound in an StgBinding (i.e. we have a "real"
    -- definition for them).
    }
-- `undefs` and `haveDefs` along with the PostG2A metadata help reduce the
-- number of lookups during post-processing.  The Id from some element's
-- IncompleteDict metadata only needs to be checked if it's also in `undefs`.

emptyDictInfo :: DictInfo
emptyDictInfo = DictInfo [] Set.empty Set.empty

-- We want a "stateful" traversal, since, once a TyCon is identified
-- any new DataCon associated with it should be inserted into its
-- constructor list.  If we don't linearize the traversal, we'd have
-- to merge the TyMaps intelligently; not impossible, but extra work.
data G2AState = G2A { tymap :: TyMap
                    , unamer :: UniqueNamer
                    , dictInfo :: DictInfo}


-- Because this is likely to have all kinds of errors, and we'd like
-- to know as much as possible about them, we'll use the ExceptT
-- transformer to marry State and Exception
data G2AException
  = Except
    { srcSpan :: SrcSpan
    , mNames  :: Maybe (Name, AppflName)
    , msg     :: String
    , mCause  :: Maybe G2AException} -- Exceptions can be chained

type G2AMonad t = ExceptT G2AException (State G2AState) t


instance UniqueNameState (ExceptT G2AException (State G2AState)) where
  getNamer   = lget >>= return . unamer
  putNamer n = lget >>= \gst -> lput gst{unamer = n}


-- lift the State primitive operators into the G2AMonad
lget :: G2AMonad G2AState
lget = lift get

lput :: G2AState -> G2AMonad ()
lput = lift . put


getDictInfo :: G2AMonad DictInfo
getDictInfo = liftM dictInfo lget

putDictInfo :: DictInfo -> G2AMonad ()
putDictInfo di = lget >>= \gst -> lput gst{dictInfo = di}


-- | Add a GHC DataCon to the State of the G2AMonad
putDataCon :: G.DataCon -> G2AMonad ()
putDataCon dc =
  do
    tcname <- nameGhcThing (dataConTyCon dc)
    G2A tymap un classmap <- lget
    lput $ G2A (Map.insertWith insertDC tcname [dc] tymap) un classmap
  where
    -- If we've already seen the datacon, we don't need to add it.  We no longer
    -- have problems with GHC/APPFL naming overlaps, since given a GHC DataCon,
    -- we're able to construct the appropriate data definition.
    insertDC [new] dcs | any (== new) dcs = dcs
                       | otherwise =
                         List.insertBy (compare `on` dataConTag) new dcs

    -- `Map.insertWith f key new map` Promises that, if the (key, old) pair is
    -- present in the map, the new pair in the map will be (key, f new old). If
    -- the key is not in the map, the new val is added without calling f.  Since
    -- 'new' is always the singleton list [dc] above, the above match should
    -- never fail
    insertDC _ _ = unreachable _HERE

-- | Entry point to the GHC to APPFL STG conversion
g2a :: [StgBinding] -> ([A.TyCon], [Obj Clean])
g2a binds =
  let ((objs,tycons), st) = runG2AorElse $
                               do -- We do want to fail hard at the moment.
                                 objs0 <- concatMapM g2aObj binds
                                 tycons <- makeTyCons
                                 let dcFuns = concatMap makeDCWorkers tycons
                                 objs1 <- mapM pproc (objs0 ++ dcFuns)
                                 return (objs1, tycons)

  in (map sanitizeTC tycons, map sanitizeObj objs)


-- | Translate bindings (let/letrec, including top level) into APPFL Obj types.
g2aObj :: StgBinding -> G2AMonad [Obj PostG2A]
g2aObj bind =
  case bind of
    -- We don't distinguish between recursive bindings and otherwise at the type level, so
    -- no need to do anything special here.

    StgNonRec id rhs -> liftM maybeToList $ procRhs id rhs

    StgRec pairs -> liftM catMaybes $ mapM (uncurry procRhs) pairs

  where
    procRhs :: Id -> StgRhs -> G2AMonad (Maybe (Obj PostG2A))
    procRhs id rhs = rethrowAtName id $
      do
        case idDetails id of

          -- We don't want to do anything if the Id refers to a DataCon Worker,
          -- since we generate them independently.
          DataConWorkId dc -> putDataCon dc >> return Nothing

          -- If this binding is for a dictionary, we want to make sure we
          -- note it in the DictInfo
          DFunId _ _       -> procLhsDictId id >> fmap pure (comp id rhs)

          -- The normal case, just make an Appfl Obj type
          _                -> fmap pure (comp id rhs)

    comp :: Id -> StgRhs -> G2AMonad (Obj PostG2A)
    comp id rhs =  case rhs of
      -- FUN or THUNK
      StgRhsClosure ccs bindInfo fvs updFlag srt args expr

        -- it's a THUNK
        | null args -> do
            expr <- g2aExpr expr
            name <- nameGhcThing id
            return $ THUNK Complete expr name

        -- it's a FUN(ish) thing.  Data constructors are functions too but they
        -- are not given a distinguished definition as in APPFL STG or full
        -- Haskell. This is fine; we can leave function wrappers for the CONs,
        -- and only use them when constructors aren't fully saturated.
        | otherwise
          -> liftM3 (FUN Complete) (mapM nameGhcThing args) (g2aExpr expr) (nameGhcThing id)

      -- It's either a top-level empty constructor (a la Nil/Nothing) or it's
      -- being used in a let binding. Either way, we make sure the DataCon is
      -- added to the TyMap.
      StgRhsCon _ dataCon args

        -- DataCon does not have a "fancy" type.
        -- "No existentials, no coercions, nothing" (basicTypes/DataCon.hs)
        | isVanillaDataCon dataCon
          -> do
            name <- nameGhcThing id
            putDataCon dataCon
              -- If GHC generated a wrapper, let's try to use it
            (if dcHasWrapper dataCon
              then mkWrapperCall else mkConObj) dataCon args name
            -- Constructors are always saturated at this point so we
            -- can safely make a CON. See StgSyn commentary:
            -- https://ghc.haskell.org/trac/ghc/wiki/Commentary/Compiler/StgSynType


        -- Something fancy going on with the DataCon, fail hard until we figure
        -- out how to handle it.
        | otherwise -> unsupportedWithName dataCon (G.showSDocUnsafe $ G.ppr dataCon)


-- | Make a THUNK function call to a DataCon's wrapper function
mkWrapperCall :: G.DataCon -> [StgArg] -> String -> G2AMonad (Obj PostG2A)
mkWrapperCall dc args name =
  do
    expr <- liftM2 (EFCall Complete) (nameGhcThing $ dataConWrapId dc) (mapM g2aArg args)
    return $ THUNK Complete expr name

-- | Make a CON Object from a DataCon and its StgArgs
mkConObj :: G.DataCon -> [StgArg] -> String -> G2AMonad (Obj PostG2A)
mkConObj dc args bind =
  do
    args' <- mapM g2aArg args
    con  <- nameGhcThing dc
    return $ CON Complete con args' bind


-- | Turn an StgArg into an APPFL Expr.  Invariant: Expr is an EAtom
g2aArg :: StgArg -> G2AMonad (Expr PostG2A)
g2aArg (StgLitArg lit) = liftM (EAtom Complete) (g2aLit lit)
g2aArg (StgVarArg id)
  | isId id = g2aAtomId id
  | otherwise =
    -- This would be strange, I don't know how an StgVarArg would hold anything
    -- other than a "real" Id.  If it's something else, it probably will break
    -- some other assumptions, so we'll throw an exceptions
    unsupportedWithName id "StgVarArgs wrapping a non-Id"


g2aAtomId :: Id -> G2AMonad (Expr PostG2A)
g2aAtomId id = do
  (name, post) <- case idDetails id of
            DataConWorkId dc ->
              -- Important: The name we want is that of the DataCon,
              -- _not_ the Id
              putDataCon dc >> liftM (,Complete) (nameGhcThing dc)
              
            DFunId _ _ -> liftM2 (,) (nameGhcThing id) (procRhsDictId id)
            _ -> liftM (,Complete) (nameGhcThing id)

  return $ EAtom post (Var name)
  
g2aLit :: Literal -> G2AMonad Atom
g2aLit lit = case lit of
  LitInteger i typ
    | Just int  <- toInt64 i   -> return $ LitI int
    | otherwise              -> unsupported $ "LitInteger val too large: " ++ show i

  -- This may not be wise, particularly if someone is counting on
  -- 8-bit overflow
  MachChar chr               -> return $ LitI $ to64 $ ord chr
  MachInt i                  -> return $ LitI (fromInteger i)

  -- Word == Int64 == Word64 == 64 bit types for APPFL
  MachInt64 i                -> return $ LitI (fromInteger i)
  MachWord i                 -> return $ LitI (fromInteger i)
  MachWord64 i               -> return $ LitI (fromInteger i)
  MachFloat r                -> return $ LitD (fromRational r)
  MachDouble r               -> return $ LitD (fromRational r)
  
  MachStr bs                 -> return $ LitStr (show bs)
  MachNullAddr               -> unsupported "Machine (Null) Address"
  MachLabel fs mi fORd       -> unsupported "Machine Labels"



g2aRealApp :: Id -> [StgArg] -> G2AMonad (Expr PostG2A)
g2aRealApp id args = do
    meta <- case idDetails id of
              DFunId _ _ -> procRhsDictId id
              _ -> return Complete

    args'  <- mapM g2aArg args
    name   <- nameGhcThing id
    return $ EFCall meta name args'


-- TODO : Actually implement an erroring mechanism
makeErrorCall :: Id -> [StgArg] -> G2AMonad (Expr PostG2A)
makeErrorCall id args = g2aRealApp id args


-- | Convert a GHC STG Expression to an APPFL Expression
g2aExpr :: StgExpr -> G2AMonad (Expr PostG2A)
g2aExpr e = case e of
  -- Function Application or a Var
  StgApp id args -> rethrowAtName id $
    case () of

      -- No args ==> EAtom with a Var.  Literals are StgLit below
      _  | null args    -> g2aAtomId id
         | isErrorId id -> makeErrorCall id args
         | isId id      -> g2aRealApp id args
         | otherwise    -> unsupportedWithName id "Application of non-Id Var type?"



  -- Literal Expr (all literals are primitive)
  StgLit lit
    -> liftM (EAtom Complete) $ g2aLit lit


  -- CONs are only valid in let-bindings in our STG, but this appears
  -- anywhere Exprs are valid in GHC's version.  For boxed types, we
  -- need to make a new ELet.  The only unboxed constructors are
  -- unboxed tuple constructors.  For now, we can simply box them up
  -- and let-bind them (or fail) but we'll want to do something
  -- different if we ever really support them.
  StgConApp datacon args
    | isUnboxedTupleCon datacon -> do
        -- Letting them stay for now
        putDataCon datacon
        bindConInLet datacon args
    | otherwise -> do
        putDataCon datacon
        bindConInLet datacon args


  -- Primop application.  ForeignCalls and PrimCalls fall into this
  -- category too, but we're not dealing with them.
  StgOpApp stgop args resType
    | StgPrimOp op <- stgop -> mkAppflPrimop op args

    -- Anything that's not a PrimOp is essentially a foreign call
    -- Don't ask me the difference between a PrimCall and ForeignCall
    | otherwise -> unsupported "PrimCall/ForeignCall"


  StgCase scrut _ _ bind _ altT alts
    -> do
    ealts <- g2aAlts altT bind alts
    escrt <- g2aExpr scrut
    return $ ECase Complete escrt ealts


  -- Treat the two forms of Let as identical
  StgLet bindings body
    -> makeLetExpr bindings body
  StgLetNoEscape _ _ bindings body
    -> makeLetExpr bindings body


  -- Ignore the profiler tick, make the expr
  StgTick _ realExpr
    -> g2aExpr realExpr


  -- "used *only* during CoreToStg's work". See stgSyn/StgSyn.hs
  StgLam args body
    -> unreachable _HERE


-- | Make an Alts object given the AltType (unused), scrutinee binder
-- and list of StgAlts
g2aAlts :: AltType -> Id -> [StgAlt] -> G2AMonad (Alts PostG2A)
g2aAlts altT bind alts = rethrowAtName bind $
    do
      scrtName <- nameGhcThing bind
      let escrt = EAtom Complete (Var scrtName)
      altsList <- mapM (g2aAlt scrtName) (reorderAlts alts)
      return $ Alts Complete altsList "alts" escrt


mkAppflPrimop :: PrimOp.PrimOp -> [StgArg] -> G2AMonad (Expr PostG2A)
mkAppflPrimop primop args = case lookupAppflPrimop primop of
  Just (op,info) -> liftM (EPrimOp Complete op info) (mapM g2aArg args)
  Nothing ->
    case lookupImplementedPrimop primop of
                 Just name -> liftM (EFCall Complete name) (mapM g2aArg args)
                 Nothing   -> quickPpr primop >>= unsupported


bindConInLet :: G.DataCon -> [StgArg] -> G2AMonad (Expr PostG2A)
bindConInLet dc args = rethrowAtName dc $
  do
    let inBody = EAtom Complete (Var bind)
        -- We don't want to shadow names, but maintaining an environment to guarantee this
        -- is annoying. For such a small scope, we can use an invalid name and rely on
        -- sanitization to fix it before codegen.
        bind   = "@"  -- hack
    conObj <- mkConObj dc args bind
    return $ ELet Complete [conObj] inBody


makeLetExpr :: StgBinding -> StgExpr -> G2AMonad (Expr PostG2A)
makeLetExpr ghcBindings ghcBody =
  do
    appflObjs <- g2aObj ghcBindings
    appflBody <- g2aExpr ghcBody
    return $ ELet Complete appflObjs appflBody


-- | Make an APPFL Alt from a GHC STG Alt.  "Default" cases, where no
-- constructor or literal is matched, do not bind variables in GHC's
-- STG since a case expression has exactly such a binding.  This
-- variable parameter must be given to make the APPFL version of the
-- same.
g2aAlt :: A.Var  -- | Scrutinee Binding
       -> StgAlt -- | GHC Alt to convert
       -> G2AMonad (Alt PostG2A)
g2aAlt scrtName (acon, binders, usemask, rhsExpr)
  | isAltErrorExpr rhsExpr =
    return (ADef { amd = Complete
                 , av  = "x"
                 , ae  = EFCall{ emd = Complete
                               , ev  = noExhaustName
                               , eas = [ EAtom{ emd = Complete
                                              , ea  = Var "x" }
                                       ]
                               }
                 }
           )
  | otherwise =
    do
      appflRhs <- g2aExpr rhsExpr
      conParams <- mapM nameGhcThing binders
      case acon of
        -- Constructor match (Maybe a, I# i, etc.)
        DataAlt datacon -> rethrowAtName datacon $
          do
            putDataCon datacon
            conName <- nameGhcThing datacon
            return $ ACon Complete conName conParams appflRhs

        -- primitive literal pattern match (3#, 1.0#, etc)
        LitAlt lit -> do
          l <- g2aLit lit
          case l of
            LitI i -> return $ ACon Complete (show i) conParams appflRhs
            _      -> unsupported "Only pattern matching on literal Int# for now"

        DEFAULT -> return $ ADef Complete scrtName appflRhs

-- Note on failing pattern matches and void# --
--
-- For boxed case expressions, GHC adds Alt clauses with fail variables that
-- serve like our stg_case_not_exhaustive.
-- Ex.
--   let patError = error "pat failure" in
--     case e of
--       ...
--       _ -> patError
--
-- We try to identify them with a name-lookup in FromGHC.BuiltIn and substitute
-- the 'defAlt' from the Analysis module (which makes the call to
-- stg_case_not_exhaustive).  For *unboxed* case expressions, any such error
-- identifier may be legally "case-bound" in transforms.
-- Ex.
--  case error "pat failure" of
--    patError -> case e of
--                  ...
--                  _ -> patError
--
-- To prevent this, they (claim to) use a function instead:
--   let failMe = \_ -> error "pat failure"
--   in case e of
--        ...
--        _ -> failMe void#
--
-- BUT, what I've seen is more often is a generated function replaces nested
-- case expressions:
--
-- case i# %# 3# of
--   0# -> case i# of ..        -- replaced by call to genFunc1 void#
--   g# -> case i# %# 2# of ..  -- replaced by call to genFunc2 void#
--
-- genFunc1 x = case i# of ..
-- genFunc2 x = case i# %# 2# of ..
--
-- This is strange, since the Alts in all these cases are provably exhaustive.  In
-- non-strict evaluation, I'm reasonably confident we could replace void# with anything
-- without changing semantics, but in the strict case, we'd probably like it to be safely
-- evaluable, even though it seems to always be ignored.  For now, void# is a dummy VOID
-- (~ Unit) data type.


-- | Given an Id (appearing on the RHS of a definition) known to be a dictionary
-- for a typeclass, accumulate any information necessary for post-processing and
-- return a PostG2A type indicating whether the Id will need further work after
-- G2A.
procRhsDictId :: Id -> G2AMonad PostG2A
procRhsDictId id = procDictId id False

-- | Given a LHS DFunId, (i.e. a Dictionary with a real implementation), add it
-- to the known definitions (possibly removing it from the unknowns) in the DictInfo
-- of the G2AMonad.
procLhsDictId :: Id -> G2AMonad ()
procLhsDictId id =
  -- Don't want the PostG2A to be used by mistake
  procDictId id True >> return ()

-- | General form of processing DFunIds, parameterized for whether the Id is found
-- in a binding or in an expression.
procDictId :: Id   -- | Id known to have DFunId details
           -> Bool -- | Was it found in the Lhs of a StgBinding?
           -> G2AMonad PostG2A
procDictId id isImpl =
  case finalResultType $ varType id of
    TyConApp tc typs
      | ClassTyCon clas <- tyConParent tc -> do
      -- If the TyCon is a dictionary, its parent will be a ClassTyCon

          d@DictInfo{appflCompatAList, undefs, haveDefs} <- getDictInfo

          when isImpl $ putDictInfo d{ undefs   = Set.delete id undefs
                                     , haveDefs = Set.insert id haveDefs }

          case getClassFromAppflEquiv (qualifyName clas) of
            -- If this class is a compatability class,
            -- this is the "real" class name ..
            Just className -> do
              idname <- nameGhcThing id

              -- add it to the mappings we're accumulating
              let newCompats = ((className, typs), idname) : appflCompatAList

              putDictInfo d{appflCompatAList = newCompats}
              return Complete

            -- Otherwise, it's a reference to a dictionary of some other class.
            -- We'll add it to the undefs only if we don't know it's defined.
            Nothing
              | isImpl || id `Set.member` haveDefs
                -> return Complete

              | otherwise -> do
                  putDictInfo d{undefs = Set.insert id undefs}
                  return (IncompleteDict id)

    _otherwise -> unreachable _HERE
      -- I'm pretty sure this shouldn't happen, since any Id known to be a
      -- DFunId should have a TyConApp result type (application of the
      -- Dictionary constructor) and its parent really should be a ClassTyCon.
      -- If I'm wrong, I'll have to do investigate GHC STG some more.



-- | Construct the actual TyCons from the TyMap in the G2AMonad
makeTyCons :: G2AMonad [A.TyCon]
makeTyCons =
  do G2A{tymap} <- lget
     mapM constrTyCon (Map.toList tymap)

-- | Given a (Con, GHC DataCons) pair, build the appropriate APPFL TyCon
constrTyCon :: (Con, [G.DataCon]) -> G2AMonad A.TyCon
constrTyCon (con, dcs) = do
  appflDCs <- mapM g2aDataCon dcs
  let tyvars = nub $ concatMap dataConTyVars appflDCs
  -- Assuming everything is boxed for now
  return $ TyCon True con tyvars appflDCs

-- | Convert a GHC DataCon to an APPFL DataCon
g2aDataCon :: G.DataCon -> G2AMonad A.DataCon
g2aDataCon dc = rethrowAtName dc $
  do
    let -- The type of a GHC DataCon is a function type.  We represent this as a
        -- list of Monotypes, rather than nested MFuns.  'go' unfolds MFun(s)
        -- resulting from the GHC to APPFL type conversion into the list form
        go :: A.Monotype -> [A.Monotype]
        go (MFun m1 m2) = m1 : go m2
        go m            = [m]
    con <- nameGhcThing dc
    -- See note below about why we need the init here
    mtypes <- liftM (init . go) (g2aMonoType $ dataConRepType dc)
    return $ A.DataCon con mtypes

{- Getting data constructor definitions from GHC:

data constructor definitions do not exist at the STG level in GHC.  The
constructors are simply functions.  We can recreate the definitions from the
types of these functions.  For example, the list constructors look like this:

       |- argument types -|    |- result type -|
(:) ::    a    ->   [] a    ->      [] a
       |-    no args     -|    |- result type -|
[]  ::                              [] a

We can convert these to Monotypes, but we need only the 'argument' types and not
the 'result' type to form the DataCon's Monotype. (The result type could be used
to make the TyCon, but that's accessible in simpler ways.)

What this means is that when we convert the dataConRepType of the GHC DataCon to
an APPFL Monotype and unfold it into a list, the last item in the list is the
result and we need to discard it.  This is why we need the init from the result
of 'go' above.

-}


-- | Make functions or top level bindings equivalent to GHC's concept of DataCon
-- workers: things that produce values of the datatype.
makeDCWorkers :: A.TyCon -> [Obj PostG2A]
makeDCWorkers (TyCon _ _ _ dcs) = map mkWorker dcs
  where
    -- Don't need to let-ify a no-arg datacon: make a CON directly
    mkWorker (DataCon con [])  = CON Complete con [] con
    -- With args, need to make a FUN
    mkWorker (DataCon con mts) =
          let vars = take (length mts) allNameStrings
              conargs = map (EAtom Complete . Var) vars
              conBind = "theCon"
              letbody = EAtom Complete (Var conBind)
              letExpr = ELet Complete [CON Complete con conargs conBind] letbody
          in FUN Complete vars letExpr con


-- | Convert a GHC Type to an APPFL Monotype for use in DataCons
g2aMonoType :: Type -> G2AMonad A.Monotype
g2aMonoType t =
  case t of
    -- Simplest case, a type variable
    TyVarTy v        -> liftM MVar (nameGhcThing v)

    -- AppTy will never be an application of a TyConnApp to
    -- some other type.  The first param is always another AppTy or
    -- a TyVarTy.  This seems like it would show up in contexts like
    -- f :: Monad m => m a -> m b.  In Haskell, this is fine, but there are
    -- no typeclasses or synonyms at the STG level, so this type may have
    -- been excised/simplified by the time we start touching the STG tree
    AppTy t1 t2      ->  do
      m1 <- g2aMonoType t1
      m2 <- g2aMonoType t2
      case m1 of
        MVar v        -> return $ MCon (Just True) v [m2]
        MCon b c args -> return $ MCon b c (args ++ [m2])
          -- Anything else would be strange, but let's be sure
        _             -> unsupportedType

    -- e.g. List a, Maybe Int, etc.
    TyConApp tc args  -> do
      mtypes <- mapM g2aMonoType args
      name   <- nameGhcThing tc
      return $ MCon (Just True) name mtypes

    -- This assumes the right-associativity of (->) is expressed just as in our
    -- MFun, which is probably reasonable. Anything else would be
    -- counterintuitive
    FunTy t1 t2      -> liftM2 MFun (g2aMonoType t1) (g2aMonoType t2)

    -- If this is nested in a type (as in higher-rank types), just ignoring the
    -- universal quantifier may be a problem.  We'll see...
    ForAllTy var ty  -> g2aMonoType ty

    -- Type-level Literals are definitely beyond what we support.  They *should*
    -- only appear in programs with -XDataKinds, so they could be rejected
    -- early, in theory.
    LitTy _          -> unsupportedType

  where unsupportedType = do
          nmr <- getNamer
          unsupported $
            "Having trouble converting Type to MonoType:" ++
            show (mkDocWithNamer t nmr)




--------------------------------------------------------------------------------
--  Utility functions
--------------------------------------------------------------------------------
-- The DEFAULT pattern match, if present, is always at the head of the
-- alts list. Since we're producing C switch statements, we really
-- want any DEFAULT (ADef for us) to be the *last* one.  This should
-- be safe, since shadowed matches seem to be excised by GHC.

-- Though we don't modify the order otherwise, the order of rest of the patterns doesn't
-- matter for the same reason. Somewhere (coreSyn/CoreSyn.hs, maybe) it's stated that the
-- DataAlts are ordered by their Tag (which is based simply on the order they're defined,
-- as it is for us as well), so other than the DEFAULT, we don't need to worry at all
-- about this ordering.
reorderAlts :: [StgAlt] -> [StgAlt]
reorderAlts (a@(DEFAULT,_,_,_):alts) = alts ++ [a]
reorderAlts alts = alts


-- | Check if there's a Wrapper DataCon for some GHC DataCon
dcHasWrapper :: G.DataCon -> Bool
dcHasWrapper = isJust . dataConWrapId_maybe


-- | Check if some TyCon is the constructor for the dictionary of a class for
-- which we have a equivalent.
isAppflEquivClassTC :: G.TyCon -> Bool
isAppflEquivClassTC tc =
  -- non-stateful naming is OK here, since any name we're interested in will be
  -- a top-level element of a module and therefore fully qualified.
  qualifyName tc `Map.member` appflClassImplMap



-- | Given some GHC Type, get the "result" Type of function type, or simply return the
-- Type itself.
-- e.g.  a -> b -> T b   yields  T b
--       T e             yields  T e
finalResultType :: Type -> Type
finalResultType = last . unrollType

-- | Unroll a GHC Function Type into a List of types.  If given a non-function
-- type as argument, it will be the sole element of a singleton list
unrollType :: Type -> [Type]
unrollType ty =
  case ty of
    FunTy t1 t2 -> t1 : unrollType t2
    ForAllTy v t -> unrollType t
    t -> [t]

isAltErrorExpr :: StgExpr -> Bool
isAltErrorExpr (StgApp id args) = isErrorId id
isAltErrorExpr _ = False

dictInfoKeyComp :: (Name, [Type]) -> (Name, [Type]) -> Bool
dictInfoKeyComp (n1, ts1) (n2, ts2) =
  n1 == n2 && and (zipWith myTyEq ts1 ts2)

-- | Type equivalence for typeclass implementations
myTyEq :: Type -> Type -> Bool
myTyEq (TyVarTy _) (TyVarTy _) = True -- tyvars are equivalent for my needs
myTyEq (AppTy a1 b1) (AppTy a2 b2) =  a1 `myTyEq` a2 && b1 `myTyEq` b2
myTyEq (TyConApp tc1 ts1) (TyConApp tc2 ts2) =
  tc1 == tc2 && and (zipWith myTyEq ts1 ts2)
myTyEq (FunTy a1 b1) (FunTy a2 b2) =  a1 `myTyEq` a2 && b1 `myTyEq` b2
myTyEq (ForAllTy _ t1) (ForAllTy _ t2) =  t1 `myTyEq` t2
myTyEq _ _ = False



--------------------------------------------------------------------------------
--    Exception construction, manipulation and handling functions
--------------------------------------------------------------------------------


-- | Run a computation in the G2A monad, failing hard on exceptions
runG2AorElse :: G2AMonad a -> (a, G2AState)
runG2AorElse comp = case runState (runExceptT comp) (G2A Map.empty emptyNamer emptyDictInfo) of
  (Left e, _) -> failHard e
  (Right r, st) -> (r, st)

-- | Put nested exceptions into a list, outermost to innermost
exceptToList e@Except{mCause = Nothing} = [e]
exceptToList e@Except{mCause = Just cause} = e : exceptToList cause


-- | Show a G2AException.  This does not show nested exceptions.
exceptString :: G2AException -> String
exceptString Except{srcSpan, mNames, msg} =
  unlines $ [msg] ++ blame mNames ++ ["Occurring at or near " ++ locStr]
  where
    blame Nothing = []
    blame (Just (ghcName, appflName)) =
      [ "Caused by or near something with names:"
      , "  Source Occurrence --> " ++ (show $ getOccString ghcName)
      , "  APPFL Qualified ----> " ++ appflName ]

    locStr = case srcSpan of
      UnhelpfulSpan s -> unpackFS s
      RealSrcSpan rss ->
        let (start, end) = unpackRSS rss
            file         = unpackFS $ srcSpanFile rss
        in concat $ intersperse " "
           ["file:", file, show start, "to", show end]

    unpackRSS rss = ((srcSpanStartLine rss, srcSpanStartCol rss),
                     (srcSpanEndLine rss  , srcSpanEndCol rss  ))


-- | Show a G2AException and any nested exceptions.
exceptStrings :: G2AException -> [String]
exceptStrings = map exceptString . exceptToList

-- | Throw an exception with an optional AppflNameable thing and an optional
-- source G2AException
exceptG2A
  :: AppflNameable a
  => Maybe a            -- | Nameable thing that caused it
  -> Maybe G2AException -- | Exception that preceeded this one
  -> String             -- | Some helpful message
  -> G2AMonad b
exceptG2A mthing mexcept msg = do
  (loc, mNames) <-
    case mthing of
      Nothing    -> pure ((UnhelpfulSpan $ mkFastString "Uncertain location"),
                          Nothing)
      Just thing -> do
        let ghcName = getName thing
        appflName <- nameGhcThing thing
        return (nameSrcSpan ghcName, Just (ghcName, appflName))

  throwE $ Except loc mNames msg mexcept


-- | Throw an exception for an unsupported feature without any name/location
-- information
unsupported :: String -> G2AMonad a
unsupported = exceptG2A (Nothing :: Maybe Id) Nothing

-- | Throw an exception caused by a NamedThing.  The SrcSpan is derived from the
-- thing's Name.
unsupportedWithName :: AppflNameable t => t -> String -> G2AMonad a
unsupportedWithName nthing = exceptG2A (Just nthing) Nothing

-- | Given a NamedThing, if some computation produces an exception and has no
-- useful SrcSpan and/or Name, replace the useless values with those derived
-- from the NamedThing
rethrowAtName :: AppflNameable t => t -> G2AMonad a -> G2AMonad a
rethrowAtName nthing e = catchE e nestExcepts
  where nestExcepts e = exceptG2A (Just nthing) (Just e) ""



-- can use this as a 'catchE' handler in the G2AMonad, but, as the name
-- suggests, it fails hard when an Exception is encountered.  There's not much
-- use trying to recover from an Exception, so maybe that's fine.
failHard :: G2AException -> a
failHard e = failHard' e 5

failHard' e depth = error $ unlines $
  "Exception in G2A!" : trimmed
  where eStrs = exceptStrings e
        trimmed = drop (length eStrs - depth) eStrs




--------------------------------------------------------------------------------
--           Post processing of the Appfl STG tree.
--
-- This is just dictionary resolution at the moment but could be more later.
--------------------------------------------------------------------------------


class PostProc (stg :: * -> *) where
  pproc :: (stg PostG2A) -> G2AMonad (stg Dirty)
  -- We do want to stay in the Monad here, or at least be "stateful" since we'll
  -- be modifying the DictInfo as we process the STG tree and its final state
  -- determines whether or not there were unresolved dictionaries in the program

instance PostProc Obj where
  pproc o = case o of
    CON {omd, as} -> do
      pAs <- mapM pproc as
      return o{ omd = Dirty
              , as  = pAs }

    _ -> do
      pE <- pproc (e o) -- THUNK or FUN body
      return o{ omd = Dirty
              , e   = pE }


instance PostProc Expr where
  pproc e = case emd e of
    Complete -> recur e

    IncompleteDict id -> case e of

      -- Simple case: This Atom identifies a dictionary we need to find the
      -- Appfl equivalent for.
      EAtom {} -> makeNewExpr id e (\name -> e{ea = Var name})


      -- The function being called might be a dictionary identifer in constrained
      -- instances. For example, in the (Eq a => Eq [a]) instance, `[2] == [1,2]`
      -- becomes `(==) (dEqList dEqInt) [2] [1,2]`.  The dictionary dEqList takes
      -- a dictionary argument for its elements.
      EFCall {} -> makeNewExpr id e (\name -> e{ev = name})

      -- Anything else doesn't make sense, since IncompleteDict is basically
      -- saying that "this idenfier needs to be swapped".  Let and Case
      -- expressions do not have a single identifier, and Primops are definitely
      -- not dictionaries.
      primop -> unreachable _HERE

    where
      recur e = case e of
        -- Common logic to both Complete and Incomplete case: traverse the
        -- rest of the tree

        ELet {edefs, ee} -> do
          pdefs <- mapM pproc edefs
          pe    <- pproc ee
          return e{ emd   = Dirty
                  , edefs = pdefs
                  , ee    = pe }

        ECase {ee, ealts} -> do
          palts <- pproc ealts
          pe    <- pproc ee
          return e{ emd   = Dirty
                  , ealts = palts
                  , ee    = pe }

        EAtom {ea} ->
          return e{ emd = Dirty
                  , ea} -- typecheck fails without the `ea` param. GHC bug?

        -- Even though a Primop will never be applied to a Dictionary, we still
        -- need to change the argument metadata.  EFCalls just happen to have the
        -- same logic.  Their args may need modification
        fCallOrPrimop -> do
          pas <- mapM pproc (eas e)
          return e{ emd = Dirty
                  , eas = pas }

      -- Called from the IncompleteDict cases
      makeNewExpr id ex mkEx = do
        DictInfo{appflCompatAList, undefs} <- getDictInfo
        if (id `Set.member` undefs)
          then
          do
            -- These matches should never fail, having been matched when the
            -- Id was placed in the metadata.
            let TyConApp tc typs = finalResultType (varType id)
                ClassTyCon clas = tyConParent tc
            case lookupBy dictInfoKeyComp (getName clas, typs) appflCompatAList of

              -- Found our Appfl implementation
              Just appflName -> recur $ mkEx appflName

              -- Bad news: Undefined dictionary with no Appfl implementation
              Nothing -> do
                clasStr <- quickPpr clas
                typStrs <- mapM quickPpr $ typs
                unsupportedWithName id $
                  unlines $
                  "No Appfl equivalent class implementation:" : clasStr : typStrs

            -- Dictionary is defined somewhere in the AST, don't do anything
            -- special
          else recur ex


instance PostProc Alts where
  pproc a@Alts{alts, scrt} = do
    pscrt <- pproc scrt
    palts <- mapM pproc alts
    return a{ altsmd = Dirty
            , alts   = palts
            , scrt   = pscrt}

instance PostProc Alt where
  pproc a = do
      pae <- pproc (ae a)
      return a{ amd = Dirty
              , ae  = pae }
