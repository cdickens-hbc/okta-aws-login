{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}

module App (
  App
, askUser
, chooseOne
, createConfFileIfDoesntExist
, getAwsRegion
, getOktaSamlConfig
, getSamlSession
, getUserCredentials
, isVerbose
, keepReloading
, lookupChoice
, doECRLogin
, numericChoices
, runApp
, setSamlSession
, tshow
, updateSamlSession
, useMFA
, usedMFA
) where


import           AppConfig
import           Args
import           Control.Bool
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Trans.Reader
import           Data.Foldable
import           Data.IORef
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NEL
import           Data.Maybe
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Development.GitRev
import           Network.AWS.Types
import           System.Directory
import           System.Environment (lookupEnv)
import           System.Exit
import           System.FilePath
import           System.IO
import           Types


data AppState =
  AppState { asArgs :: !Args
           , asOktaSamlConfig :: !(NonEmpty OktaSamlConfig)
           , asSamlSessionRef :: !(IORef SamlSession)
           , asUsedMFA :: !(IORef Bool) -- ^ remember if we had to use MFA codes during session (as opposed to being on a trusted net)
           }


newtype App a =
  App { unApp :: ReaderT AppState (LoggingT IO) a
      } deriving ( Applicative
                 , Functor
                 , Monad
                 , MonadCatch
                 , MonadIO
                 , MonadLogger
                 , MonadLoggerIO
                 , MonadThrow
                 )

runApp :: App a
       -> Args
       -> IO a
runApp appA args@Args{..} = do
  when argsVersion $ die $ "Version: " <> $(gitBranch) <> "@" <> $(gitHash)

  when argsListAwsProfiles $ do
    (allProfiles, defProf) <- listOktaSamlConfigProfiles args
    envProf <- getEnvAWSProfile

    forM_ allProfiles $ \p -> TIO.putStrLn $ unAwsProfile p
    forM_ defProf $ \p -> TIO.putStrLn $ "\nYour configured default profile is " <> unAwsProfile p <> "."
    forM_ envProf $ \p -> TIO.putStrLn $ "\nYour environment is configured with " <> unAwsProfile p <> ", it will override your config file defaults."

    when ((null . catMaybes) [envProf, defProf]) $
      TIO.putStrLn $ "\nNote that you can change your default AWS profile by exporting AWS_PROFILE environmental variable" <>
                     " or adding '\"default\": true' property to your preferred AWS profile in the config file."

    die ""

  let llf _ ll = argsVerbose || (ll >= LevelInfo)

  samlConf <- findOktaSamlConfig args
  samlSessRef <- newIORef []
  usedMFARef <- newIORef False

  let appState = AppState args samlConf samlSessRef usedMFARef

  runStderrLoggingT $ filterLogger llf $ runReaderT (unApp appA) appState


isVerbose :: App Bool
isVerbose = fmap argsVerbose getArgs

keepReloading :: App Bool
keepReloading = fmap argsKeepReloading getArgs

doECRLogin :: App Bool
doECRLogin = fmap (not . argsNoECRLogin) getArgs

getOktaSamlConfig :: App (NonEmpty OktaSamlConfig)
getOktaSamlConfig = App $ fmap asOktaSamlConfig ask


getUserCredentials :: App UserCredentials
getUserCredentials = getArgs >>= \Args{..} -> do
  uName <- case argsUserName
             of Just u -> return u
                Nothing -> UserName <$> askUser True "User > "
  password <- Password <$> askUser False "Please enter Okta password > "
  return (uName, password)


askUser :: Bool -- ^ terminal echo
        -> Text -- ^ prompt string
        -> App Text -- ^ user input
askUser e p = liftIO $ withEcho e $ do
  TIO.putStr p
  hFlush stdout
  r <- TIO.getLine
  TIO.putStrLn ""
  return r


getArgs :: App Args
getArgs = App $ fmap asArgs ask


getAwsRegion :: App Region
getAwsRegion = fmap argsRegion getArgs


getSamlSession :: App SamlSession
getSamlSession = do
  AppState{..} <- App ask
  liftIO $ readIORef asSamlSessionRef

setSamlSession :: SamlSession
               -> App SamlSession
setSamlSession s = do
  AppState{..} <- App ask
  liftIO $ writeIORef asSamlSessionRef s
  return s

updateSamlSession :: (SamlSession -> App SamlSession)
                  -> App SamlSession
updateSamlSession upS = getSamlSession >>= upS >>= setSamlSession


usedMFA :: App Bool
usedMFA = do
  AppState{..} <- App ask
  liftIO $ readIORef asUsedMFA

useMFA :: Bool
       -> App ()
useMFA x = do
  AppState{..} <- App ask
  liftIO $ writeIORef asUsedMFA x


tshow :: (Show a) => a -> Text
tshow = T.pack . show


-- | Interactive choices with numeric string keys
numericChoices :: [Text -> a -> InteractiveChoce a]
numericChoices = InteractiveChoce . tshow <$> ([0..] :: [Int])


-- | Lookup chosen value by key
lookupChoice :: Text -- ^ key
             -> [InteractiveChoce a]
             -> Maybe a
lookupChoice k cs =
  fmap icChoice $ listToMaybe $ filter (\InteractiveChoce{..} -> icKey == k) cs



chooseOne :: NonEmpty (InteractiveChoce a)
          -> App a
chooseOne (InteractiveChoce{..} :| []) = return icChoice
chooseOne opts = do
  liftIO $ TIO.putStrLn $ T.intercalate "\n" $
             fmap (\InteractiveChoce{..} -> "[" <> icKey <> "] " <> icMessage)
               (NEL.toList opts)

  uc <- askUser True "Please choose> "

  case lookupChoice uc (NEL.toList opts)
    of Nothing -> do liftIO $ putStrLn $ "Sorry, your choice of " <> show uc <> " is not available, please try again."
                     chooseOne opts
       Just x -> return x


-- | Creates a missing config file with a default text
createConfFileIfDoesntExist :: FilePath
                            -> Text
                            -> App ()
createConfFileIfDoesntExist fp txt = do
  let (dir, _) = splitFileName fp

  created <- liftIO $
    ifThenElseM (doesFileExist fp)
      (return False)
      ( do createDirectoryIfMissing False dir
           TIO.writeFile fp txt
           return True)

  when created $ $(logInfo) $ "Created default config " <> T.pack fp



findOktaSamlConfig :: Args
                   -> IO (NonEmpty OktaSamlConfig)
findOktaSamlConfig Args{..} = do
  appConf <- readAppConfigFile argsConfigFile
  envProf <- getEnvAWSProfile

  let defaultConfiguredProfiles = ocAwsProfile <$> NEL.filter (fromMaybe False . ocDefault) (ocSaml appConf)

       -- consider profiles in the order of preference
      selectedProfiles = fromMaybe [] $ listToMaybe $ filter (not . null)
                           [ argsAwsProfiles
                           , maybeToList envProf
                           , defaultConfiguredProfiles
                           ]

      samlConfPredicate OktaSamlConfig{..} = ocAwsProfile `elem` selectedProfiles

      selectedSamlConfigs = filter samlConfPredicate (NEL.toList (ocSaml appConf))

  case NEL.nonEmpty selectedSamlConfigs
    of Nothing -> error $ "Please provide at least one AWS profile or specify default(s) (in the config file or via an AWS_PROFILE environmental variable)." <>
                          " You can re-run with -l to see the list of configured profiles."
       Just cs -> return cs


-- | Returns configured profiles, with an optional default configured profile
listOktaSamlConfigProfiles :: Args
                           -> IO ([AWSProfile], Maybe AWSProfile)
listOktaSamlConfigProfiles Args{..} = do
  AppConfig{..} <- readAppConfigFile argsConfigFile

  let isDefaultConfig = fromMaybe False . ocDefault

      maybeDefaultProfile = ocAwsProfile <$> find isDefaultConfig ocSaml

      allProfiles = toList $ fmap ocAwsProfile ocSaml

  return (allProfiles, maybeDefaultProfile)


-- | Looks up AWS_PROFILE env var
getEnvAWSProfile :: IO (Maybe AWSProfile)
getEnvAWSProfile = fmap (AWSProfile . T.pack) <$> lookupEnv "AWS_PROFILE"


-- | Control terminal echo, flush stdin, for user interaction
withEcho :: Bool -> IO a -> IO a
withEcho echo action = do
  hFlush stdout
  old <- hGetEcho stdin
  bracket_ (hSetEcho stdin echo)
           (do hSetEcho stdin old ; hFlush stdout)
           action
