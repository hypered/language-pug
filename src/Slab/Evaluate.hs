{-# LANGUAGE RecordWildCards #-}

module Slab.Evaluate
  ( PreProcessError (..)
  , preProcessPugFile
  , evaluatePugFile
  , evaluate
  , defaultEnv
  ) where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT, except, runExceptT, throwE)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Aeson.Key
import Data.Aeson.KeyMap qualified as Aeson.KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Vector qualified as V
import Data.Void (Void)
import Slab.Parse qualified as Parse
import Slab.Syntax
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, takeExtension, (<.>), (</>))
import Text.Megaparsec hiding (Label, label, parse, parseErrorPretty, unexpected)

--------------------------------------------------------------------------------
data Context = Context
  { ctxStartPath :: FilePath
  }

data PreProcessError
  = PreProcessParseError (ParseErrorBundle Text Void)
  | PreProcessError Text -- TODO Add specific variants instead of using Text.
  deriving (Show, Eq)

-- Similarly to `parsePugFile` but pre-process the include statements.
preProcessPugFile :: FilePath -> IO (Either PreProcessError [Block])
preProcessPugFile = runExceptT . preProcessPugFileE

preProcessPugFileE :: FilePath -> ExceptT PreProcessError IO [Block]
preProcessPugFileE path = do
  pugContent <- liftIO $ T.readFile path
  let mnodes = first PreProcessParseError $ Parse.parsePug path pugContent
  nodes <- except mnodes
  let ctx =
        Context
          { ctxStartPath = path
          }
  preProcessNodesE ctx nodes

-- Process include statements (i.e. read the given path and parse its content
-- recursively).
preProcessNodesE :: Context -> [Block] -> ExceptT PreProcessError IO [Block]
preProcessNodesE ctx nodes = mapM (preProcessNodeE ctx) nodes

evaluatePugFile :: FilePath -> IO (Either PreProcessError [Block])
evaluatePugFile path = runExceptT (preProcessPugFileE path >>= evaluate defaultEnv ["toplevel"])

-- Process mixin calls. This should be done after processing the include statement
-- since mixins may be defined in included files.
evaluate :: Monad m => Env -> [Text] -> [Block] -> ExceptT PreProcessError m [Block]
evaluate env stack nodes = do
  -- Note that we pass the environment that we are constructing, so that each
  -- definition sees all definitions (including later ones and itself).
  let vars = extractVariables env' nodes
      env' = augmentVariables env vars
  mapM (eval env' stack) nodes

preProcessNodeE :: Context -> Block -> ExceptT PreProcessError IO Block
preProcessNodeE ctx@Context {..} = \case
  node@BlockDoctype -> pure node
  PugElem name mdot attrs nodes -> do
    nodes' <- preProcessNodesE ctx nodes
    pure $ PugElem name mdot attrs nodes'
  node@(PugText _ _) -> pure node
  PugInclude path _ -> do
    let includedPath = takeDirectory ctxStartPath </> path
        slabExt = takeExtension includedPath == ".slab"
    exists <- liftIO $ doesFileExist includedPath
    if exists && not slabExt
      then do
        -- Include the file content as-is.
        content <- liftIO $ T.readFile includedPath
        let nodes' = map (PugText Include . (: []) . Lit) $ T.lines content
        pure $ PugInclude path (Just nodes')
      else do
        -- Parse and process the .slab file.
        let includedPath' = if slabExt then includedPath else includedPath <.> ".slab"
        nodes' <- preProcessPugFileE includedPath'
        pure $ PugInclude path (Just nodes')
  PugFragmentDef name nodes -> do
    nodes' <- preProcessNodesE ctx nodes
    pure $ PugFragmentDef name nodes'
  PugFragmentCall name nodes -> do
    nodes' <- preProcessNodesE ctx nodes
    pure $ PugFragmentCall name nodes'
  node@(PugEach _ _ _ _) -> pure node
  node@(PugComment _ _) -> pure node
  node@(PugFilter _ _) -> pure node
  node@(PugRawElem _ _) -> pure node
  PugDefault name nodes -> do
    nodes' <- preProcessNodesE ctx nodes
    pure $ PugDefault name nodes'
  PugImport path _ nodes -> do
    -- An import is treated like an include used to define a fragment, then
    -- directly calling that fragment.
    let includedPath = takeDirectory ctxStartPath </> path
        slabExt = takeExtension includedPath == ".slab"
    exists <- liftIO $ doesFileExist includedPath
    if exists && not slabExt
      then throwE $ PreProcessError $ "Extends requires a .slab file"
      else do
        -- Parse and process the .slab file.
        let includedPath' = if slabExt then includedPath else includedPath <.> ".slab"
        nodes' <- preProcessPugFileE includedPath'
        let def = PugFragmentDef (T.pack path) nodes'
        nodes'' <- mapM (preProcessNodeE ctx) nodes
        -- Maybe we should set the blocks as WithinCall here?
        let call = PugFragmentCall (T.pack path) nodes''
        pure $ PugList [def, call]
  PugReadJson name path _ -> do
    content <- liftIO $ BL.readFile path
    case Aeson.eitherDecode content of
      Right val ->
        pure $ PugReadJson name path $ Just val
      Left err ->
        throwE $ PreProcessError $ "Can't decode JSON: " <> T.pack err
  node@(PugAssignVar _ _) -> pure node
  PugIf cond as bs -> do
    -- File inclusion is done right away, without checking the condition.
    as' <- preProcessNodesE ctx as
    bs' <- preProcessNodesE ctx bs
    pure $ PugIf cond as' bs'
  PugList nodes -> do
    nodes' <- preProcessNodesE ctx nodes
    pure $ PugList nodes'
  node@(BlockCode _) -> pure node

eval :: Monad m => Env -> [Text] -> Block -> ExceptT PreProcessError m Block
eval env stack = \case
  node@BlockDoctype -> pure node
  PugElem name mdot attrs nodes -> do
    nodes' <- evaluate env stack nodes
    pure $ PugElem name mdot attrs nodes'
  PugText syn template -> do
    template' <- evalTemplate env template
    pure $ PugText syn template'
  PugInclude path mnodes -> do
    case mnodes of
      Just nodes -> do
        nodes' <- evaluate env ("include" : stack) nodes
        pure $ PugList nodes'
      Nothing ->
        pure $ PugInclude path Nothing
  PugFragmentDef _ _ -> pure $ PugList []
  PugFragmentCall name args -> do
    case lookupVariable name env of
      Just (Frag capturedEnv body) -> do
        env' <- map (\(a, b) -> (a, Frag env b)) <$> namedBlocks args
        let env'' = augmentVariables capturedEnv env'
        body' <- evaluate env'' ("frag" : stack) body
        pure $ PugList body'
      Just _ -> throwE $ PreProcessError $ "Calling something that is not a fragment \"" <> name <> "\" in " <> T.pack (show stack)
      Nothing -> throwE $ PreProcessError $ "Can't find fragment \"" <> name <> "\""
  PugEach name mindex values nodes -> do
    -- Re-use PugEach to construct a single node to return.
    let zero :: Int
        zero = 0
    values' <- evalCode env values
    collection <- case values' of
      List xs -> pure $ zip xs $ map Int [zero ..]
      Object xs -> pure $ map (\(k, v) -> (v, k)) xs
      _ -> throwE $ PreProcessError $ "Iterating on something that is not a collection"
    nodes' <- forM collection $ \(value, index) -> do
      let env' = case mindex of
            Just idxname -> augmentVariables env [(name, value), (idxname, index)]
            Nothing -> augmentVariables env [(name, value)]
      evaluate env' ("each" : stack) nodes
    pure $ PugList $ concat nodes'
  node@(PugComment _ _) -> pure node
  node@(PugFilter _ _) -> pure node
  node@(PugRawElem _ _) -> pure node
  PugDefault name nodes -> do
    -- If the fragment is not given as an argument, we return the default block,
    -- but recursively trying to replace the blocks found within its own body.
    case lookupVariable name env of
      Nothing -> do
        nodes' <- evaluate env ("?block" : stack) nodes
        pure $ PugList nodes'
      Just (Frag capturedEnv nodes') -> do
        nodes'' <- evaluate capturedEnv ("+block" : stack) nodes'
        pure $ PugList nodes''
      Just _ -> throwE $ PreProcessError $ "Calling something that is not a fragment \"" <> name <> "\" in " <> T.pack (show stack)
  PugImport _ _ _ ->
    throwE $ PreProcessError $ "Extends must be preprocessed before evaluation\""
  PugReadJson _ _ _ -> pure $ PugList []
  PugAssignVar _ _ -> pure $ PugList []
  PugIf cond as bs -> do
    cond' <- evalCode env cond
    case cond' of
      SingleQuoteString s
        | not (T.null s) -> do
            as' <- evaluate env ("then" : stack) as
            pure $ PugList as'
      Int n
        | n /= 0 -> do
            as' <- evaluate env ("then" : stack) as
            pure $ PugList as'
      _ -> do
        bs' <- evaluate env ("else" : stack) bs
        pure $ PugList bs'
  PugList nodes -> do
    nodes' <- evaluate env stack nodes
    pure $ PugList nodes'
  BlockCode code -> do
    code' <- evalCode env code
    pure $ BlockCode code'

defaultEnv :: Env
defaultEnv = Env [("true", Int 1), ("false", Int 0)]

lookupVariable :: Text -> Env -> Maybe Code
lookupVariable name Env {..} = lookup name envVariables

augmentVariables :: Env -> [(Text, Code)] -> Env
augmentVariables Env {..} xs = Env {envVariables = xs <> envVariables}

namedBlocks :: Monad m => [Block] -> ExceptT PreProcessError m [(Text, [Block])]
namedBlocks nodes = do
  named <- concat <$> mapM namedBlock nodes
  unnamed <- concat <$> mapM unnamedBlock nodes
  let content = if null unnamed then [] else [("content", unnamed)]
  if isJust (lookup "content" named) && not (null unnamed)
    then throwE $ PreProcessError $ "A block of content and a content argument are provided"
    else pure $ named <> content

namedBlock :: Monad m => Block -> ExceptT PreProcessError m [(Text, [Block])]
namedBlock (PugFragmentDef name content) = pure [(name, content)]
namedBlock _ = pure []

unnamedBlock :: Monad m => Block -> ExceptT PreProcessError m [Block]
unnamedBlock (PugFragmentDef _ _) = pure []
unnamedBlock node = pure [node]

evalCode :: Monad m => Env -> Code -> ExceptT PreProcessError m Code
evalCode env = \case
  Variable name ->
    case lookupVariable name env of
      Just val -> pure val
      Nothing -> throwE $ PreProcessError $ "Can't find variable \"" <> name <> "\""
  Lookup name key ->
    case lookupVariable name env of
      Just (Object obj) -> do
        -- key' <- evalCode env key
        case lookup key obj of
          Just val -> pure val
          Nothing ->
            pure $ Variable "false"
      -- throwE $ PreProcessError $ "Key lookup failed. Key: " <> T.pack (show key) <> T.pack (show obj)
      Just _ -> throwE $ PreProcessError $ "Variable \"" <> name <> "\" is not an object"
      Nothing -> throwE $ PreProcessError $ "Can't find variable \"" <> name <> "\""
  Add a b -> do
    a' <- evalCode env a
    b' <- evalCode env b
    case (a', b') of
      (Int i, Int j) -> pure . Int $ i + j
      (Int i, SingleQuoteString s) -> pure . SingleQuoteString $ T.pack (show i) <> s
      _ -> throwE $ PreProcessError $ "Unimplemented: " <> T.pack (show (Add a' b'))
  code -> pure code

-- After evaluation, the template should be either empty or contain a single literal.
evalTemplate :: Monad m => Env -> [Inline] -> ExceptT PreProcessError m [Inline]
evalTemplate env inlines = do
  t <- T.concat <$> traverse (evalInline env) inlines
  pure [Lit t]

evalInline :: Monad m => Env -> Inline -> ExceptT PreProcessError m Text
evalInline env = \case
  Lit s -> pure s
  Place code -> do
    code' <- evalCode env code
    case code' of
      SingleQuoteString s -> pure s
      Int x -> pure . T.pack $ show x
      -- Variable x -> context x -- Should not happen after evalCode
      x -> error $ "render: unhandled value: " <> show x

-- Extract both fragments and assignments.
-- TODO This should be merged with namedBlocks.
-- TODO We could filter the env, keeping only the free variables that appear
-- in the bodies.
extractVariables :: Env -> [Block] -> [(Text, Code)]
extractVariables env = concatMap f
 where
  f BlockDoctype = []
  f (PugElem _ _ _ _) = []
  f (PugText _ _) = []
  f (PugInclude _ children) = maybe [] (extractVariables env) children
  f (PugEach _ _ _ _) = []
  f (PugFragmentDef name children) = [(name, Frag env children)]
  f (PugFragmentCall _ _) = []
  f (PugComment _ _) = []
  f (PugFilter _ _) = []
  f (PugRawElem _ _) = []
  f (PugDefault _ _) = []
  f (PugImport _ _ _) = []
  f (PugReadJson name _ (Just val)) = [(name, jsonToCode val)]
  f (PugReadJson _ _ Nothing) = []
  f (PugAssignVar name s) = [(name, SingleQuoteString s)]
  f (PugIf _ _ _) = []
  f (PugList _) = []
  f (BlockCode _) = []

jsonToCode :: Aeson.Value -> Code
jsonToCode = \case
  Aeson.String s -> SingleQuoteString s
  Aeson.Array xs ->
    List $ map jsonToCode (V.toList xs)
  Aeson.Object kvs ->
    let f (k, v) = (SingleQuoteString $ Aeson.Key.toText k, jsonToCode v)
     in Object $ map f (Aeson.KeyMap.toList kvs)
  x -> error $ "jsonToCode: " <> show x