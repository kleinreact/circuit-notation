{-
 ██████╗██╗██████╗  ██████╗██╗   ██╗██╗████████╗███████╗
██╔════╝██║██╔══██╗██╔════╝██║   ██║██║╚══██╔══╝██╔════╝
██║     ██║██████╔╝██║     ██║   ██║██║   ██║   ███████╗
██║     ██║██╔══██╗██║     ██║   ██║██║   ██║   ╚════██║
╚██████╗██║██║  ██║╚██████╗╚██████╔╝██║   ██║   ███████║
 ╚═════╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝
  (C) 2020, Christopher Chalmers

Notation for describing the 'Circuit' type.
-}

{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module CircuitNotation (plugin, showC, trace) where

-- base
import           Control.Exception
import           Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Data              as Data
import           Data.Either            (partitionEithers)
import           Data.Maybe             (fromMaybe)
import           Debug.Trace
import           Data.Typeable
import           SrcLoc
import           System.IO
import           System.IO.Unsafe

-- ghc
import           Bag
import qualified ErrUtils               as Err
import           FastString             (mkFastString)
import qualified GhcPlugins             as GHC
import           HsExtension            (GhcPs, NoExt (..))
import           HsSyn
import           HscTypes               (throwOneError)
import qualified OccName
import qualified Outputable
import           PrelNames              (eqTyCon_RDR)

-- lens
import qualified Control.Lens           as L

-- mtl
import           Control.Monad.State
import           Control.Monad.Writer

-- pretty-show
import qualified Text.Show.Pretty       as SP

-- syb
import qualified Data.Generics          as SYB

-- | The name given to a 'port', i.e. the name of something either to the left of a '<-' or to the
-- right of a '-<'.
data PortName = PortName SrcSpan GHC.FastString

instance Show PortName where
  show (PortName _ fs) = GHC.unpackFS fs

fromRdrName :: GHC.RdrName -> GHC.FastString
fromRdrName = \case
  GHC.Unqual occName -> mkFastString (OccName.occNameString occName)
  GHC.Orig _ occName -> mkFastString (OccName.occNameString occName)
  nm -> mkFastString (deepShowD nm)

-- | A single circuit binding.
data Binding exp l = Binding
  { bCircuit :: exp
  , bOut     :: PortDescription l
  , bIn      :: PortDescription l
  } deriving (Functor)

-- | A description of a circuit with internal let bindings.
data CircuitQQ dec exp nm = CircuitQQ
  { circuitQQSlaves  :: PortDescription nm
  , circuitQQTypes   :: [LSig GhcPs]
  , circuitQQLets    :: [dec]
  , circuitQQBinds   :: [Binding exp nm]
  , circuitQQMasters :: PortDescription nm
  } deriving (Functor)

newtype CircuitState = CircuitState
  { cErrors   :: Bag Err.ErrMsg
  }

newtype CircuitM a = CircuitM (StateT CircuitState GHC.Hsc a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadState CircuitState)

liftHsc :: GHC.Hsc a -> CircuitM a
liftHsc = CircuitM . lift

instance GHC.HasDynFlags CircuitM where
  getDynFlags = liftHsc GHC.getDynFlags

runCircuitM :: CircuitM a -> GHC.Hsc a
runCircuitM (CircuitM m) = do
  let emptyCircuitState = CircuitState
        { cErrors = emptyBag
        }
  (a, s) <- runStateT m emptyCircuitState
  let errs = cErrors s
  unless (isEmptyBag errs) $ liftIO . throwIO $ GHC.mkSrcErr errs
  pure a

-- PortDescription -----------------------------------------------------

data PortDescription a
  = Tuple [PortDescription a]
  | Vec [PortDescription a]
  | Ref a
  | Lazy (PortDescription a)
  | SignalExpr (LHsExpr GhcPs)
  | SignalPat (LPat GhcPs)
  | PortType (LHsSigWcType GhcPs) (PortDescription a)
  | PortErr SrcSpan Err.MsgDoc
  deriving (Foldable, Functor, Traversable)

instance L.Plated (PortDescription a) where
  plate f = \case
    Tuple ps -> Tuple <$> traverse f ps
    Vec ps -> Vec <$> traverse f ps
    Lazy p -> Lazy <$> f p
    PortType t p -> PortType t <$> f p
    p -> pure p

getSigTy :: p ~ GhcPs => LHsSigWcType p -> LHsType p
getSigTy (HsWC _ (HsIB _ t)) = t
getSigTy _                   = error "getSigTy"

-- foldring :: (Contravariant f, Applicative f) => ((a -> f a -> f a) -> f a -> s -> f a) -> LensLike f s t a b
-- foldring fr f = phantom . fr (\a fa -> f a *> fa) noEffect
-- {-# INLINE foldring #-}LB

tupP :: p ~ GhcPs => [LPat p] -> LPat p
tupP pats = noLoc $ TuplePat NoExt pats GHC.Boxed

vecP :: p ~ GhcPs => [LPat p] -> LPat p
vecP pats = noLoc $ ListPat NoExt pats

varP :: p ~ GhcPs => SrcSpan -> String -> LPat p
varP loc nm = L loc $ VarPat NoExt (L loc $ var nm)

-- Types ---------------------------------------------------------------

tupT :: p ~ GhcPs => [LHsType p] -> LHsType p
tupT tys = noLoc $ HsTupleTy NoExt HsBoxedTuple tys

vecT :: p ~ GhcPs => [LHsType p] -> LHsType p
vecT _tys = error "can't do a vec type yet" -- noLoc $ HsTupleTy NoExt HsBoxedTuple tys

portTypeSig :: p ~ GhcPs => GHC.DynFlags -> PortDescription PortName -> LHsType p
portTypeSig dflags = \case
  Tuple ps -> tupT $ fmap (portTypeSig dflags) ps
  Vec ps   -> vecT $ fmap (portTypeSig dflags) ps
  Ref (PortName loc fs) -> varT loc (GHC.unpackFS fs <> "Ty")
  PortErr loc msgdoc -> unsafePerformIO . throwOneError $
    Err.mkLongErrMsg dflags loc Outputable.alwaysQualify (Outputable.text "portTypeSig") msgdoc
  Lazy p -> portTypeSig dflags p
  -- TODO make the 'a' unique
  SignalExpr (L l _) -> L l $ HsAppTy NoExt (conT l "Signal") (varT l "a")
  SignalPat (L l _) -> L l $ HsAppTy NoExt (conT l "Signal") (varT l "a")
  PortType _ p -> portTypeSig dflags p

-- Parsing -------------------------------------------------------------

err :: SrcSpan -> String -> CircuitM Err.ErrMsg
err loc msg = do
  dflags <- GHC.getDynFlags
  let errMsg = Err.mkLocMessageAnn Nothing Err.SevFatal loc (Outputable.text msg)
  pure $
    Err.mkErrMsg dflags loc Outputable.alwaysQualify errMsg

-- | Extract a simple lambda into inputs and body.
simpleLambda :: HsExpr p -> Maybe ([LPat p], LHsExpr p)
simpleLambda expr = do
  HsLam _ (MG _x alts _origin) <- Just expr
  L _ [L _ (Match _matchX _matchContext matchPats matchGr)] <- Just alts
  GRHSs _grX grHss _grLocalBinds <- Just matchGr
  [L _ (GRHS _ _ body)] <- Just grHss
  Just (matchPats, body)


-- | "parse" a circuit, i.e. convert it from ghc's ast to our representation of a circuit. This is
-- the expression following the 'circuit' keyword.
parseCircuit
  :: p ~ GhcPs
  => LHsExpr p
  -> CircuitM (CircuitQQ (LHsBind p) (LHsExpr p) PortName)
parseCircuit = \case
  -- strip out parenthesis
  L _ (HsPar _ lexp) -> parseCircuit lexp

  -- a lambda to match the slave ports
  L _loc (simpleLambda -> Just ([matchPats], body)) ->
    circuitBody (bindSlave matchPats) body

  -- a version without a lamda (i.e. no slaves)
  e -> circuitBody (Tuple []) e

-- | The main part of a circuit expression. Either a do block or simple rearranging case.
circuitBody
  :: p ~ GhcPs
  => PortDescription PortName
  -> LHsExpr p
  -> CircuitM (CircuitQQ (LHsBind p) (LHsExpr p) PortName)
circuitBody slaves = \case
  -- strip out parenthesis
  L _ (HsPar _ lexp) -> circuitBody slaves lexp

  L _ (HsDo _x _stmtContext (L _ (unsnoc -> Just (stmts, finStmt)))) -> do
    (masters, masterBindings) <-
      case finStmt of
        L _ (BodyStmt _bodyX bod _idr _idr') -> pure $ finalStmt bod
        L finLoc stmt ->
          throwOneError =<< err finLoc ("unhandled final stmt " <> show (Data.toConstr stmt))

    (sigs, lets, bindings) <- handleStmts stmts

    pure CircuitQQ
      { circuitQQSlaves = slaves
      , circuitQQTypes = sigs
      , circuitQQLets = lets
      , circuitQQBinds = masterBindings ++ bindings
      , circuitQQMasters = masters
      }

  -- the simple case without do notation
  L loc master ->
    let masters = bindMaster (L loc master)
    in pure CircuitQQ
      { circuitQQSlaves = slaves
      , circuitQQTypes = []
      , circuitQQLets = []
      , circuitQQBinds = []
      , circuitQQMasters = masters
      }

-- | Converts the statements of a circuit do block to either let bindings or port bindings.
handleStmts
  :: (p ~ GhcPs)
  => [ExprLStmt p]
  -> CircuitM ([LSig p], [LHsBind p], [Binding (LHsExpr p) PortName])
handleStmts stmts = do
  let (localBinds, bindings) = partitionEithers $ map (handleStmt . unL) stmts
  sigBinds <- forM localBinds $ \case
    L _ (HsValBinds _ (ValBinds _ valBinds sigs)) -> pure (sigs, bagToList valBinds)
    L loc stmt -> throwOneError =<< err loc ("unhandled statement" <> show (Data.toConstr stmt))

  let (sigs, binds) = unzip sigBinds

  pure (concat sigs, concat binds, bindings)

handleStmt
  :: (p ~ GhcPs, loc ~ SrcSpan, idL ~ GhcPs)
  => StmtLR idL idR (LHsExpr p)
  -> Either (LHsLocalBindsLR idL idR) (Binding (LHsExpr p) PortName)
handleStmt = \case
  LetStmt _xlet letBind -> Left letBind
  BodyStmt _xbody body _idr _idr' -> Right (bodyBinding Nothing body)
  BindStmt _xbody bind body _idr _idr' -> Right (bodyBinding (Just $ bindSlave bind) body)
  _ -> error "Unhandled stmt"

-- | Turn patterns to the left of a @<-@ into a PortDescription.
bindSlave :: p ~ GhcPs => LPat p -> PortDescription PortName
bindSlave = \case
  L _ (VarPat _ (L loc rdrName)) -> Ref (PortName loc (fromRdrName rdrName))
  L _ (TuplePat _ lpat _) -> Tuple $ fmap bindSlave lpat
  L _ (ParPat _ lpat) -> bindSlave lpat
  L _ (ConPatIn (L _ (GHC.Unqual occ)) (PrefixCon [lpat]))
    | OccName.occNameString occ == "Signal" -> SignalPat lpat
  L _ (SigPat ty port) -> PortType ty (bindSlave port)
  L loc pat ->
    PortErr loc
            (Err.mkLocMessageAnn
              Nothing
              Err.SevFatal
              loc
              (Outputable.text $ "Unhandled pattern " <> show (Data.toConstr pat))
              )

-- | Turn expressions to the right of a @-<@ into a PortDescription.
bindMaster :: p ~ GhcPs => LHsExpr p -> PortDescription PortName
bindMaster (L loc expr) = case expr of
  HsVar _xvar (L vloc rdrName) -> Ref (PortName vloc (fromRdrName rdrName))
  ExplicitTuple _ tups _ -> let
    vals = fmap (\(L _ (Present _ e)) -> e) tups
    in Tuple $ fmap bindMaster vals
  ExplicitList _ _syntaxExpr exprs -> Vec $ fmap bindMaster exprs
  HsApp _xapp (L _ (HsVar _ (L _ (GHC.Unqual occ)))) sig
    | OccName.occNameString occ == "Signal" -> SignalExpr sig
  ExprWithTySig ty expr' -> PortType ty (bindMaster expr')
  _ -> PortErr loc
    (Err.mkLocMessageAnn
      Nothing
      Err.SevFatal
      loc
      (Outputable.text $ "Unhandled expression " <> show (Data.toConstr expr))
      )

-- | The final statement of a circuit do block.
finalStmt
  :: p ~ GhcPs
  => LHsExpr p
  -> (PortDescription PortName, [Binding (LHsExpr GhcPs) PortName])
finalStmt (L loc expr) = case expr of
 -- special case for idC as the final statement, gives better type inferences and generates nicer
 -- code
  HsArrApp _xapp (L _ (HsVar _ (L _ (GHC.Unqual occ)))) arg _ _
    | OccName.occNameString occ == "idC" -> (bindMaster arg, [])

  -- Otherwise create a binding and use that as the master. This is equivalent to changing
  --   c -< x
  -- into
  --   finalStmt <- c -< x
  --   idC -< finalStmt
  _ -> let ref = Ref (PortName loc "final:stmt")
       in (ref, [bodyBinding (Just ref) (L loc expr)])

-- Checking ------------------------------------------------------------

checkCircuit :: p ~ GhcPs => CircuitQQ (LHsBind p) (LHsExpr p) PortName -> CircuitM ()
checkCircuit cQQ = checkMatching cQQ

checkMatching :: p ~ GhcPs => CircuitQQ (LHsBind p) (LHsExpr p) PortName -> CircuitM ()
checkMatching CircuitQQ {..} = do
  -- data CircuitQQ dec exp nm = CircuitQQ
  --   { circuitQQSlaves  :: PortDescription nm
  --   , circuitQQLets    :: [dec]
  --   , circuitQQBinds   :: [Binding exp nm]
  --   , circuitQQMasters :: PortDescription nm
  --   } deriving (Functor)
  pure ()


-- Creating ------------------------------------------------------------

bindWithSuffix :: p ~ GhcPs => GHC.DynFlags -> String -> PortDescription PortName -> LPat p
bindWithSuffix dflags suffix = \case
  Tuple ps -> tupP $ fmap (bindWithSuffix dflags suffix) ps
  Vec ps   -> vecP $ fmap (bindWithSuffix dflags suffix) ps
  Ref (PortName loc fs) -> varP loc (GHC.unpackFS fs <> suffix)
  PortErr loc msgdoc -> unsafePerformIO . throwOneError $
    Err.mkLongErrMsg dflags loc Outputable.alwaysQualify (Outputable.text "Unhandled bind") msgdoc
  Lazy _ -> error "bindWithSuffix Lazy not handled" -- tildeP $ bindWithSuffix suffix p
  SignalExpr (L l _) -> L l (WildPat NoExt)
  SignalPat lpat -> lpat
  PortType _ p -> bindWithSuffix dflags suffix p

bindOutputs
  :: p ~ GhcPs
  => GHC.DynFlags
  -> PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LPat p
bindOutputs dflags slaves masters = tupP [m2s, s2m]
  where
  -- super hacky: at this point we can generate names not possible in
  -- normal haskell (i.e. with spaces or colons). This is used to
  -- emulate non-captuable names.
  m2s = bindWithSuffix dflags ":M2S" masters
  s2m = bindWithSuffix dflags ":S2M" slaves

expWithSuffix :: p ~ GhcPs => String -> PortDescription PortName -> LHsExpr p
expWithSuffix suffix = \case
  Tuple ps -> tupE noSrcSpan $ fmap (expWithSuffix suffix) ps
  Vec ps   -> vecE noSrcSpan $ fmap (expWithSuffix suffix) ps
  Ref (PortName loc fs)   -> varE loc (var $ GHC.unpackFS fs <> suffix)
  -- lazyness only affects the pattern side
  Lazy p   -> expWithSuffix suffix p
  PortErr _ _ -> error "expWithSuffix PortErr!"
  SignalExpr lexpr -> lexpr
  SignalPat (L l _) -> tupE l []
  PortType _ p -> expWithSuffix suffix p

createInputs
  :: p ~ GhcPs
  => PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LHsExpr p
createInputs slaves masters = tupE noSrcSpan [m2s, s2m]
  where
  m2s = expWithSuffix ":M2S" masters
  s2m = expWithSuffix ":S2M" slaves

imap :: (Int -> a -> b) -> [a] -> [b]
imap f = zipWith f [0 ..]

decFromBinding :: p ~ GhcPs => GHC.DynFlags -> Int -> Binding (LHsExpr p) PortName -> HsBind p
decFromBinding dflags i Binding {..} = do
  let bindPat  = bindOutputs dflags bOut bIn
      inputExp = createInputs bIn bOut
      bod = varE noSrcSpan (var $ "run" <> show i) `appE` bCircuit `appE` inputExp
   in patBind bindPat bod

patBind :: p ~ GhcPs => LPat p -> LHsExpr p -> HsBindLR p p
patBind lhs expr = PatBind NoExt lhs rhs ([], [])
  where
    rhs = GRHSs NoExt [gr] (noLoc $ EmptyLocalBinds NoExt)
    gr  = L (getLoc expr) (GRHS NoExt [] expr)

letE
  :: p ~ GhcPs
  => SrcSpan
  -- ^ location for top level let bindings
  -> [LSig GhcPs]
  -- ^ type signatures
  -> [LHsBindLR p p]
  -- ^ let bindings
  -> LHsExpr p
  -- ^ final `in` expressions
  -> LHsExpr p
letE loc sigs binds expr = L loc (HsLet NoExt localBinds expr)
  where
    localBinds :: LHsLocalBindsLR GhcPs GhcPs
    localBinds = L loc $ HsValBinds NoExt valBinds

    valBinds :: HsValBindsLR GhcPs GhcPs
    valBinds = ValBinds NoExt hsBinds sigs

    hsBinds :: LHsBindsLR GhcPs GhcPs
    hsBinds = listToBag binds

circuitConstructor :: p ~ GhcPs => SrcSpan -> LHsExpr p
circuitConstructor loc = varE loc (con "Circuit")

runCircuitFun :: p ~ GhcPs => SrcSpan -> LHsExpr p
runCircuitFun loc = varE loc (var "runCircuit")

constVar :: p ~ GhcPs => SrcSpan -> LHsExpr p
constVar loc = varE loc (var "const")

appE :: p ~ GhcPs => LHsExpr p -> LHsExpr p -> LHsExpr p
appE fun arg = L noSrcSpan $ HsApp NoExt fun arg

varE :: p ~ GhcPs => SrcSpan -> GHC.RdrName -> LHsExpr p
varE loc rdr = L loc (HsVar NoExt (L loc rdr))

var :: String -> GHC.RdrName
var = GHC.Unqual . OccName.mkVarOcc

tyVar :: String -> GHC.RdrName
tyVar = GHC.Unqual . OccName.mkTyVarOcc

tyCon :: String -> GHC.RdrName
tyCon = GHC.Unqual . OccName.mkTcOcc

con :: String -> GHC.RdrName
con = GHC.Unqual . OccName.mkDataOcc

vecE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
vecE loc elems = L loc $ ExplicitList NoExt Nothing elems

tupE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
tupE loc elems = L loc $ ExplicitTuple NoExt tupArgs GHC.Boxed
  where
    tupArgs = map (\arg@(L l _) -> L l (Present NoExt arg)) elems

plugin :: GHC.Plugin
plugin = GHC.defaultPlugin
  { GHC.parsedResultAction = \_cliOptions -> pluginImpl
  }

pluginImpl :: GHC.ModSummary -> GHC.HsParsedModule -> GHC.Hsc GHC.HsParsedModule
pluginImpl _modSummary m = do
    debug "hello"
    dflags <- GHC.getDynFlags
    debug $ GHC.showPpr dflags (GHC.hpm_module m)
    hpm_module' <- transform (GHC.hpm_module m)
    let module' = m { GHC.hpm_module = hpm_module' }
    return module'

debug :: MonadIO m => String -> m ()
debug = liftIO . hPutStrLn stderr
-- debug _ = pure ()

unL :: Located a -> a
unL (L _ a) = a

deepShowD :: Data.Data a => a -> String
deepShowD a = show (Data.toConstr a) <>
  -- " (" <> (unwords . fst) (SYB.gmapM (\x -> ([show $ Data.toConstr x], x)) a) <> ")"
  " (" <> (unwords . fst) (SYB.gmapM (\x -> ([deepShowD x], x)) a) <> ")"


bodyBinding
  :: (p ~ GhcPs, loc ~ SrcSpan)
  => Maybe (PortDescription PortName)
  -> GenLocated loc (HsExpr p)
  -> Binding (LHsExpr p) PortName
bodyBinding mInput lexpr@(L _loc expr) =
  case expr of
    HsArrApp _xhsArrApp circuit port HsFirstOrderApp True ->
      Binding
        { bCircuit = circuit
        , bOut     = bindMaster port
        , bIn      = fromMaybe (Tuple []) mInput
        }

    _ ->
      Binding
        { bCircuit = lexpr
        , bOut     = Tuple []
        , bIn      = fromMaybe (error "standalone expressions not allowed") mInput
        }

unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc [x] = Just ([], x)
unsnoc (x:xs) = Just (x:a, b)
    where Just (a,b) = unsnoc xs

mkCircuit
  :: p ~ GhcPs
  => PortDescription PortName
  -- ^ slave ports
  -> [LHsBindLR p p]
  -- ^ let bindings
  -> PortDescription PortName
  -- ^ master ports
  -> CircuitM (LHsExpr p)
  -- ^ circuit
mkCircuit slaves lets masters = do
  dflags <- GHC.getDynFlags
  let pats = bindOutputs dflags masters slaves
      res  = createInputs slaves masters

      body :: LHsExpr GhcPs
      body = letE noSrcSpan [] lets res

  pure $ circuitConstructor noSrcSpan `appE` lamE [pats] body

varT :: SrcSpan -> String -> LHsType GhcPs
varT loc nm = L loc (HsTyVar NoExt NotPromoted (L loc (tyVar nm)))

conT :: SrcSpan -> String -> LHsType GhcPs
conT loc nm = L loc (HsTyVar NoExt NotPromoted (L loc (tyCon nm)))

-- a b -> (Circuit a b -> CircuitT a b)
mkRunCircuitTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
mkRunCircuitTy a b =
  noLoc $ HsFunTy noExt
  (noLoc $
    HsAppTy NoExt (noLoc $ HsAppTy NoExt (conT noSrcSpan "Circuit") a) b
    )
  ( noLoc $
    HsAppTy NoExt (noLoc $ HsAppTy NoExt (conT noSrcSpan "CircuitT") a) b
    )

-- portTypeSig :: p ~ GhcPs => GHC.DynFlags -> PortDescription PortName -> LHsType p

    -- let so_filename = python_interpreter.get_library_name(&module_name);
-- data CircuitQQ dec exp nm = CircuitQQ
  -- { circuitQQSlaves  :: PortDescription nm
  -- , circuitQQTypes   :: [LSig GhcPs]
  -- , circuitQQLets    :: [dec]
  -- , circuitQQBinds   :: [Binding exp nm]
  -- , circuitQQMasters :: PortDescription nm
  -- } deriving (Functor)
  -- -> CircuitM (CircuitQQ (LHsBind p) (LHsExpr p) PortName)


-- | Creates a (tuple of) run circuit types the used for the bindings.
bindRunCircuitTypes
  :: p ~ GhcPs
  => GHC.DynFlags
  -> [Binding (LHsExpr p) PortName]
  -> LHsType p
bindRunCircuitTypes dflags binds = tupT (map mkTy binds)
  where
    mkTy bind = mkRunCircuitTy a b
      where
        a = portTypeSig dflags (bOut bind)
        b = portTypeSig dflags (bIn bind)

mkInferenceHelperTy
  :: p ~ GhcPs
  => GHC.DynFlags
  -- -> PortDescription PortName
  -- -> PortDescription PortName
  -> CircuitQQ (LHsBind p) (LHsExpr p) PortName
  -> LHsType p
mkInferenceHelperTy dflags CircuitQQ {..} =
  noLoc $ HsFunTy noExt
    (noLoc $ HsAppTy NoExt topLevelCircuitTy b)
    -- (mkRunCircuitTy a b)
    (bindRunCircuitTypes dflags circuitQQBinds)
  where
    a = portTypeSig dflags circuitQQSlaves -- (varT noSrcSpan "aa")
    b = portTypeSig dflags circuitQQMasters -- (varT noSrcSpan "b")
    topLevelCircuitTy = noLoc $ HsAppTy NoExt (conT noSrcSpan "Circuit") a

filteredBy :: (L.Indexable a p, Applicative f) => (a -> Maybe a) -> p a (f a) -> a -> f a
filteredBy p f val = case p val of
  Nothing      -> pure val
  Just witness -> L.indexed f witness val

getTypeAnnots
  :: p ~ GhcPs
  => PortDescription l
  -> [(LHsSigWcType p, PortDescription l)]
getTypeAnnots = execWriter . L.traverseOf_ L.cosmos addTypes
  where
    addTypes = \case
      PortType ty p -> tell [(ty, p)]
      _             -> pure ()



-- transform = SYB.everywhereM (SYB.mkM transform') where

-- data PortDescription a
--   = Tuple [PortDescription a]
--   | Vec [PortDescription a]
--   | Ref a
--   | Lazy (PortDescription a)
--   | SignalExpr (LHsExpr GhcPs)
--   | SignalPat (LPat GhcPs)
--   | PortType (LHsSigWcType GhcPs) (PortDescription a)
--   | PortErr SrcSpan Err.MsgDoc
--   deriving (Foldable, Functor, Traversable)

tyEq :: p ~ GhcPs => SrcSpan -> LHsType p -> LHsType p -> LHsType p
tyEq l a b = L l $ HsOpTy NoExt a (noLoc eqTyCon_RDR) b

-- eqTyCon is a special name that has to be exactly correct for ghc to recognise it. In 8.6 this
-- lives in PrelNames and is called eqTyCon_RDR, in laster ghcs it's from TysWiredIn.

circuitQQExpM
  :: p ~ GhcPs
  => GHC.DynFlags
  -> CircuitQQ (LHsBind p) (LHsExpr p) PortName
  -> CircuitM (LHsExpr p)
circuitQQExpM dflags c@CircuitQQ {..} = do
  checkCircuit c
  dynflags <- GHC.getDynFlags
  let decs = concat
        [ circuitQQLets
        , imap (\i -> noLoc . decFromBinding dynflags i) circuitQQBinds
        ]
  cir <- mkCircuit circuitQQSlaves decs circuitQQMasters

  let inferenceSig :: LHsSigType GhcPs
      -- inferenceSig = HsIB NoExt (noLoc (varT NoExt NotPromoted (noLoc (tyVar "a"))))
      -- inferenceSig = HsIB NoExt (mkRunCircuitTy (noLoc $ varT "a") (noLoc $ varT "b"))
      inferencePlainSig = mkInferenceHelperTy dflags c
      inferenceSig = HsIB NoExt (noLoc $ HsQualTy NoExt (noLoc context) inferencePlainSig)
      allTypes = getTypeAnnots circuitQQSlaves
      context = map (\(ty, p) -> tyEq noSrcSpan (portTypeSig dflags p) (getSigTy ty)) allTypes
      inferenceHelperTy =
        TypeSig NoExt
          [noLoc (var "inferenceHelper")]
          (HsWC NoExt inferenceSig)
          -- (HsWC NoExt (noLoc $ HsQualTy NoExt context inferenceSig))
          -- ((HsWC NoExt (noLoc (HsIB NoExt (noLoc (HsTyVar undefined undefined undefined))))))

  let numBinds = length circuitQQBinds
      runCircuitExprs =
        tupE noSrcSpan $ replicate numBinds (runCircuitFun noSrcSpan)
      runCircuitBinds = tupP $ map (\i -> varP noSrcSpan ("run" <> show i)) [0 .. numBinds-1]

  pure $ letE noSrcSpan (if numBinds == 0 then [] else [noLoc inferenceHelperTy])
    ( [ noLoc $ patBind (varP noSrcSpan "cir") cir
    ] <> if numBinds == 0 then [] else [
      noLoc $ patBind (varP noSrcSpan "inferenceHelper")
                      (constVar noSrcSpan `appE` runCircuitExprs)
    , noLoc $ patBind runCircuitBinds
                 ((varE noSrcSpan (var "inferenceHelper")) `appE`
                     (varE noSrcSpan (var "cir")))
    ])
    (varE noSrcSpan (var "cir"))

-- patBind :: p ~ GhcPs => LPat p -> LHsExpr p -> HsBindLR p p

-- letE
--   :: p ~ GhcPs
--   => SrcSpan
--   -- ^ location for top level let bindings
--   -> [LHsBindLR p p]
--   -- ^ let bindings
--   -> LHsExpr p
--   -- ^ final `in` expressions
--   -> LHsExpr p

lamE :: p ~ GhcPs => [LPat p] -> LHsExpr p -> LHsExpr p
lamE pats expr = noLoc $ HsLam NoExt mg
  where
    mg = MG NoExt matches GHC.Generated

    matches :: Located [LMatch GhcPs (LHsExpr GhcPs)]
    matches = noLoc $ [singleMatch]

    singleMatch :: LMatch GhcPs (LHsExpr GhcPs)
    singleMatch = noLoc $ Match NoExt LambdaExpr pats grHss

    grHss :: GRHSs GhcPs (LHsExpr GhcPs)
    grHss = GRHSs NoExt [grHs] (noLoc $ EmptyLocalBinds NoExt)

    grHs :: LGRHS GhcPs (LHsExpr GhcPs)
    grHs = noLoc $ GRHS NoExt [] expr

isCircuitVar :: p ~ GhcPs => HsExpr p -> Bool
isCircuitVar = \case
  HsVar _ (L _ v) -> v == GHC.mkVarUnqual "circuit"
  _               -> False

isDollar :: p ~ GhcPs => HsExpr p -> Bool
isDollar = \case
  HsVar _ (L _ v) -> v == GHC.mkVarUnqual "$"
  _               -> False

-- deriving instance SYB.Data OccName.NameSpace

grr :: MonadIO m => OccName.NameSpace -> m ()
grr nm
  | nm == OccName.tcName = liftIO $ putStrLn "tcName"
  | nm == OccName.clsName = liftIO $ putStrLn "clsName"
  | nm == OccName.tcClsName = liftIO $ putStrLn "tcClsName"
  | nm == OccName.dataName = liftIO $ putStrLn "dataName"
  | nm == OccName.varName = liftIO $ putStrLn "varName"
  | nm == OccName.tvName = liftIO $ putStrLn "tvName"
  | otherwise = liftIO $ putStrLn "I dunno"

transform
    :: GHC.Located (HsModule GhcPs)
    -> GHC.Hsc (GHC.Located (HsModule GhcPs))
transform = SYB.everywhereM (SYB.mkM transform') where
  transform' :: LHsExpr GhcPs -> GHC.Hsc (LHsExpr GhcPs)
  transform' e@(L _ (HsLet _xlet (L _ (HsValBinds _ (ValBinds _ _ sigs))) _lappB)) =
--  -- --                debug $ show i ++ " ==> " ++ SYB.gshow stmt
    -- trace (show (SYB.gshow <$> sigs)) pure e
    -- trace (show (( \ (TypeSig _ ids ty) -> show (deepShowD <$> ids) <> " " <> deepShowD ty) . unL <$> sigs)) pure e
    case sigs of
      [L _ (TypeSig _ [L _ x] y)] -> do
        dflags <- GHC.getDynFlags
        let pp :: GHC.Outputable a => a -> String
            pp = GHC.showPpr dflags
        case y of
          HsWC _ (HsIB _ (L _ (HsTyVar _ _ (L _ (GHC.Unqual occ))))) -> do
            grr (OccName.occNameSpace occ)
          HsWC _ (HsIB _ (L _ (HsQualTy _ (L _ [L _ (HsOpTy NoExt _ (L _ (GHC.Orig m nm)) _)]) _))) -> do
            grr $ OccName.occNameSpace nm
            traceM (pp m)
          _ -> pure () -- error "nope"
        trace (pp x) trace (SYB.gshow y) pure e
        -- error "fin"
      _ -> pure e
  transform' (L _ (HsApp _xapp (L _ circuitVar) lappB))
    | isCircuitVar circuitVar = do
      debug "HsApp!"
      -- runCircuitM $ transformCircuit lappB
      c <- runCircuitM $ transformCircuit lappB
      dflags <- GHC.getDynFlags
      let pp :: GHC.Outputable a => a -> String
          pp = GHC.showPpr dflags
      traceM (show $ SP.parseValue $ SYB.gshow c)
      traceM (pp c)
      pure c

  transform' (L _ (OpApp _xapp (L _ circuitVar) (L _ infixVar) appR))
    | isCircuitVar circuitVar && isDollar infixVar = do
      traceM "BY STUFF"
      c <- runCircuitM $ transformCircuit appR
      dflags <- GHC.getDynFlags
      let pp :: GHC.Outputable a => a -> String
          pp = GHC.showPpr dflags
      traceM (pp c)
      pure c

  transform' e = pure e

-- ppp :: MonadIO m => String -> m ()
-- ppp s = case SP.parseValue s of
--   Just a -> valToStr a

transformCircuit :: p ~ GhcPs => LHsExpr p -> CircuitM (LHsExpr p)
transformCircuit e = do
  dflags <- GHC.getDynFlags
  let pp :: GHC.Outputable a => a -> String
      pp = GHC.showPpr dflags
  cqq <- parseCircuit e
  expr <- circuitQQExpM dflags cqq
  debug $ pp expr
  pure expr

showC :: Data.Data a => a -> String
showC a = show (typeOf a) <> " " <> show (Data.toConstr a)

--
--


-- mySuperSimpleLet :: p ~ GhcPs => LHsExpr p
-- mySuperSimpleLet = letE noSrcSpan binds end
--   where
--     binds :: [LHsBindLR GhcPs GhcPs]
--     binds = [noLoc $ patBind lhs rhs]
--     lhs = varP noSrcSpan "lhs"
--     rhs = varE noSrcSpan (var "rhs")
--     end = varE noSrcSpan (var "myVar")



--
--
--
--  -------------------------------------------------------------------------------
--  -- Expression
--  -------------------------------------------------------------------------------
--
--  transformExpr
--      :: MonadIO m
--      => GHC.DynFlags
--      -> LHsExpr GhcPs
--      -> m (LHsExpr GhcPs)
--  transformExpr dflags expr@(L _e OpApp {}) = do
--      let bt = matchOp expr
--      let result = idiomBT bt
--      debug $ "RES : " ++ GHC.showPpr dflags result
--      return result
--  transformExpr dflags expr = do
--      let (f :| args) = matchApp expr
--      let f' = pureExpr f
--      debug $ "FUN : " ++ GHC.showPpr dflags f
--      debug $ "FUN+: " ++ GHC.showPpr dflags f'
--      for_ (zip args args) $ \arg ->
--          debug $ "ARG : " ++ GHC.showPpr dflags arg
--      let result = foldl' apply f' args
--      debug $ "RES : " ++ GHC.showPpr dflags result
--      return result
--
--  -------------------------------------------------------------------------------
--  -- Pure
--  -------------------------------------------------------------------------------
--
--  -- f ~> pure f
--  pureExpr :: LHsExpr GhcPs -> LHsExpr GhcPs
--  pureExpr (L l f) =
--      L l $ HsApp NoExt (L l' (HsVar NoExt (L l' pureRdrName))) (L l' f)
--    where
--      l' = GHC.noSrcSpan
--
--  pureRdrName :: GHC.RdrName
--  pureRdrName = GHC.mkRdrUnqual (GHC.mkVarOcc "pure")
--
--  -- x y ~> x <|> y
--  altExpr :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
--  altExpr x y =
--      L l' $ OpApp NoExt x (L l' (HsVar NoExt (L l' altRdrName))) y
--    where
--      l' = GHC.noSrcSpan
--
--  altRdrName :: GHC.RdrName
--  altRdrName = GHC.mkRdrUnqual (GHC.mkVarOcc "<|>")
--
--  -- f x ~> f <$> x
--  fmapExpr :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
--  fmapExpr f x =
--      L l' $ OpApp NoExt f (L l' (HsVar NoExt (L l' fmapRdrName))) x
--    where
--      l' = GHC.noSrcSpan
--
--  fmapRdrName :: GHC.RdrName
--  fmapRdrName = GHC.mkRdrUnqual (GHC.mkVarOcc "<$>")
--
--  -- f x ~> f <*> x
--  apExpr :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
--  apExpr f x =
--      L l' $ OpApp NoExt f (L l' (HsVar NoExt (L l' apRdrName))) x
--    where
--      l' = GHC.noSrcSpan
--
--  apRdrName :: GHC.RdrName
--  apRdrName = GHC.mkRdrUnqual (GHC.mkVarOcc "<*>")
--
--  -- f x -> f <* x
--  birdExpr :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
--  birdExpr f x =
--      L l' $ OpApp NoExt f (L l' (HsVar NoExt (L l' birdRdrName))) x
--    where
--      l' = GHC.noSrcSpan
--
--  birdRdrName :: GHC.RdrName
--  birdRdrName = GHC.mkRdrUnqual (GHC.mkVarOcc "<*")
--
--  -- f x -y z  ->  (((pure f <*> x) <* y) <*> z)
--  apply :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
--  apply f (L _ (HsPar _ (L _ (HsApp _ (L _ (HsVar _ (L _ voidName'))) x))))
--      | voidName' == voidName = birdExpr f x
--  apply f x                   = apExpr f x
--
--  voidName :: GHC.RdrName
--  voidName = GHC.mkRdrUnqual (GHC.mkVarOcc "void")
--
--  -------------------------------------------------------------------------------
--  -- Function application maching
--  -------------------------------------------------------------------------------
--
--  -- | Match nested function applications, 'HsApp':
--  -- f x y z ~> f :| [x,y,z]
--  --
--  matchApp :: LHsExpr p -> NonEmpty (LHsExpr p)
--  matchApp (L _ (HsApp _ f x)) = neSnoc (matchApp f) x
--  matchApp e = pure e
--
--  neSnoc :: NonEmpty a -> a -> NonEmpty a
--  neSnoc (x :| xs) y = x :| xs ++ [y]
--
--  -------------------------------------------------------------------------------
--  -- Operator application matching
--  -------------------------------------------------------------------------------
--
--  -- | Match nested operator applications, 'OpApp'.
--  -- x + y * z ~>  Branch (+) (Leaf x) (Branch (*) (Leaf y) (Leaf z))
--  matchOp :: LHsExpr p -> BT (LHsExpr p)
--  matchOp (L _ (OpApp _  lhs op rhs)) = Branch (matchOp lhs) op (matchOp rhs)
--  matchOp x = Leaf x
--
--  -- | Non-empty binary tree, with elements at branches too.
--  data BT a = Leaf a | Branch (BT a) a (BT a)
--
--  -- flatten: note that leaf is returned as is.
--  idiomBT :: BT (LHsExpr GhcPs) -> LHsExpr GhcPs
--  idiomBT (Leaf x)            = x
--  idiomBT (Branch lhs op rhs) = fmapExpr op (idiomBT lhs) `apExpr` idiomBT rhs
--
--  -------------------------------------------------------------------------------
--  -- List Comprehension
--  -------------------------------------------------------------------------------
--
--  matchListComp :: [LStmt GhcPs (LHsExpr GhcPs)] -> Maybe [LHsExpr GhcPs]
--  matchListComp [L _ (BodyStmt _ expr2 _ _), L _ (LastStmt _ expr1 _ _)] =
--      Just [expr1, expr2]
--  matchListComp [L _ (ParStmt _ blocks _ _), L _ (LastStmt _ expr1 _ _)] = do
--      exprs <- for blocks $ \bl -> case bl of
--          ParStmtBlock _ [L _ (BodyStmt _ e _ _)] _ _ -> Just e
--          _ -> Nothing
--      return $ expr1 : exprs
--  matchListComp _ = Nothing
--
--  -------------------------------------------------------------------------------
--  -- Location checker
--  -------------------------------------------------------------------------------
--
--  -- Check that spans are right inside each others, i.e. we match
--  -- that there are no spaces between parens and brackets
--  inside :: SrcSpan -> SrcSpan -> Bool
--  inside (RealSrcSpan a) (RealSrcSpan b) = and
--      [ srcSpanStartLine a == srcSpanStartLine b
--      , srcSpanEndLine a == srcSpanEndLine b
--      , srcSpanStartCol a + 1 == srcSpanStartCol b
--      , srcSpanEndCol a == srcSpanEndCol b + 1
--      ]
--  inside _ _ = False
--    -- noLoc $ HsValBinds NoExt binds
--    -- where
--    --   binds :: HsValBindsLR GhcPs GhcPs
--    --   binds = ValBinds NoExt hsBinds sigs
--    --   sigs = []
--    --   hsBinds :: LHsBindsLR GhcPs GhcPs
--    --   hsBinds = listToBag . (:[]) $ myCoolBind
--
--    --   myCoolBind :: LHsBindLR GhcPs GhcPs
--    --   -- myCoolBind = noLoc $ VarBind NoExt myBindId myExpr False
--    --   myCoolBind = noLoc $ PatBind NoExt lhs rhs ([],[])
--
--    --   lhs :: LPat GhcPs
--    --   lhs = noLoc $ TuplePat NoExt pats GHC.Boxed
--
--    --   pats :: [LPat GhcPs]
--    --   pats =
--    --     [ noLoc $ VarPat NoExt (noLoc $ mkName "yo")
--    --     , noLoc $ VarPat NoExt (noLoc $ mkName "la")
--    --     ]
--
--    --   mkName :: String -> GHC.RdrName
--    --   mkName = GHC.Unqual . OccName.mkVarOcc
--
--    --   rhs :: GRHSs GhcPs (LHsExpr GhcPs)
--    --   rhs = GRHSs NoExt [myGr] (noLoc $ EmptyLocalBinds NoExt)
--
--    --   myGr :: LGRHS GhcPs (LHsExpr GhcPs)
--    --   myGr = noLoc $ GRHS NoExt [] myVar
--
--    --   myVar :: LHsExpr GhcPs
--    --   myVar = noLoc $ HsVar NoExt (noLoc $ mkName "ah")
--
--
--  -- patBind :: p ~ GhcPs => LPat p -> LHsExpr p -> HsBindLR p p
--
--  -- binding :: p ~ GhcPs => Binding (LHsExpr p) PortName -> HsBind p
--  -- binding Binding {..} = patBind pat expr
--  --   where
--  --     pat =
--
--  -- mySuperSimpleLet :: p ~ GhcPs => HsExpr p
--  -- mySuperSimpleLet = HsLet NoExt mySuperSimpleLocalBind myIn
--  --   where
--  --     myIn = noLoc $ HsVar NoExt (noLoc myVarId)
--  --     myVarId = GHC.Unqual (OccName.mkVarOcc "yo")
--
--
--    -- let bindPat  = bindOutputs bOut bIn
--    --     inputExp = createInputs bIn bOut
--    --     bod = varE 'runCircuit' `appE` pure bCircuit `appE` inputExp
--    -- valD bindPat (normalB bod) []
--
--
--
--  -- decFromBinding :: Binding String -> Q Dec
--  -- decFromBinding Binding {..} = do
--  --   let bindPat  = bindOutputs bOut bIn
--  --       inputExp = createInputs bIn bOut
--  --       bod = varE 'runCircuit' `appE` pure bCircuit `appE` inputExp
--  --   valD bindPat (normalB bod) []
--
--  -- plugin :: GHC.Plugin
--  -- plugin = GHC.defaultPlugin
--  --   { GHC.renamedResultAction = \_cliOptions _ _ -> error "made it here"
--  --   }
--
--  -- class GHC.Outputable a where
--  --     GHC.ppr :: a -> GHC.SDoc
--  --       GHC.pprPrec :: Rational -> a -> GHC.SDoc
--
--
--      -- transform' e@(L l (HsPar _ (L l' (ExplicitList  _ Nothing exprs)))) | inside l l' =
--      --     case exprs of
--      --         [expr] -> do
--      --             expr' <- transformExpr dflags expr
--      --             return (L l (HsPar NoExt expr'))
--      --         _ -> do
--      --             liftIO $ GHC.putLogMsg dflags GHC.NoReason Err.SevWarning l (GHC.defaultErrStyle dflags) $
--      --                 GHC.text "Non singleton idiom bracket list"
--      --                 GHC.$$
--      --                 GHC.ppr exprs
--      --             return e
--      -- transform' (L l (HsPar _ (L l' (HsDo _ ListComp (L _ stmts)))))
--      --     | inside l l', Just exprs <- matchListComp stmts = do
--      --         for_ exprs $ \expr ->
--      --             debug $ "ALT: " ++ GHC.showPpr dflags expr
--  -- --            for_ (zip stmts [0..]) $ \(stmt, i) -> do
--  -- --                debug $ show i ++ " ==> " ++ SYB.gshow stmt
--      --         exprs' <- traverse (transformExpr dflags) exprs
--      --         return (foldr1 altExpr exprs')
--      -- transform' expr =
--      --     return expr
--
--      -- transform' e@(L l (HsLet _xhsLet localBinds inExpr)) = do
--      --   case localBinds of
--      --     L _ (HsValBinds NoExt binds) ->
--      --       case binds of
--      --         ValBinds NoExt hsBinds sigs ->
--      --           case bagToList hsBinds of
--      --             -- [L _ (FunBind NoExt bindId expr _)] ->
--      --             [L _ (VarBind NoExt bindId expr _)] ->
--      --               debug $ deepShowD bindId
--      --             [L _ (PatBind NoExt (L _ lhs) rhs ticks)] -> do
--      --               debug $ "lhs: " <> deepShowD lhs
--      --               case lhs of
--      --                 TuplePat _xTuple pats GHC.Boxed ->
--      --                   case pats of
--      --                     [ L _ (VarPat _ (L _ (GHC.Unqual nm1)))
--      --                       , L _ (VarPat _ (L _ (GHC.Unqual nm2)))
--      --                       ]
--      --                       -> do debug $ "p1: " <> OccName.occNameString nm1
--      --                             debug $ "p2: " <> OccName.occNameString nm2
--      --                     _ -> for_ pats $ debug . deepShowD
--      --               debug $ "rhs: " <> deepShowD rhs
--      --               case rhs of
--      --                 GRHSs _ body (L _ localBinds) -> do
--      --                   for_ body $ \(L _ (GRHS _ guard (L _ bod))) -> do
--      --                     debug $ "grhs_body: " <> deepShowD bod
--      --                   debug $ "localBinds: " <> deepShowD localBinds
--                  -- [L _ vb] -> debug $ deepShowD vb
--        -- debug $ deepShowD localBinds
--        -- pure e
--
--  -- mkNewExprRn :: TcM (LHsExpr GhcTc)
--  -- mkNewExprRn = do
--  --   -- The names we want to use happen to already be in PrelNames so we use
--  --   -- them directly.
--  --   let print_occ = mkRdrUnqual (mkVarOcc "print")
--  --   print_name <- lookupOccRn print_occ
--  --   let raw_expr = nlHsApp (nlHsVar print_name) (nlHsVar (dataConName unitDataCon))
--  --   io_tycon <- tcLookupTyCon ioTyConName
--  --   let exp_type = mkTyConApp io_tycon [unitTy]
--  --   typecheckExpr exp_type raw_expr
--
--  -- mkNewExprPs :: TcM (LHsExpr GhcTc)
--  -- mkNewExprPs  = do
--
--  --   let
--  --     print_occ = mkRdrUnqual (mkVarOcc "print")
--  --     unit_occ = nameRdrName (dataConName unitDataCon)
--  --     ps_expr = nlHsApp (nlHsVar print_occ)
--  --                       (nlHsVar unit_occ)
--
--  --   io_tycon <- tcLookupTyCon ioTyConName
--  --   let exp_type = mkTyConApp io_tycon [unitTy]
--  --   renameExpr ps_expr >>= typecheckExpr exp_type
--
