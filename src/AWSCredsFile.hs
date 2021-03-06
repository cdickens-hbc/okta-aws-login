{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TemplateHaskell    #-}

module AWSCredsFile (
  updateAwsCreds
) where


import           App
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Data.Foldable
import qualified Data.HashMap.Strict as M
import           Data.Ini
import           Data.Maybe
import           Network.AWS.Data.Text
import           Network.AWS.Types
import           System.Directory
import           System.FilePath
import           Types


updateAwsCreds :: [(AWSProfile, SamlAWSCredentials)]
               -> App ()
updateAwsCreds pCreds = do
  credsFile <- awsCredentialsFileName

  createConfFileIfDoesntExist credsFile "[default]"

  !savedCreds <- liftIO $ readIniFile credsFile >>=
                   \case Left e -> error $ "Unable to read AWS credentials file from " <> credsFile <> " error: " <> e
                         Right c -> return c

  region <- getAwsRegion

  let updatedIni = foldr' (uncurry (updateProfileCredentials region)) savedCreds pCreds


  $(logDebug) $ "Writing new credentials to file " <> tshow updatedIni
  liftIO $ writeIniFileWith (WriteIniSettings EqualsKeySeparator) credsFile updatedIni


awsCredentialsFileName :: App FilePath
awsCredentialsFileName = liftIO $ do
  h <- getHomeDirectory
  return $ h </> ".aws" </> "credentials"


updateProfileCredentials :: Region
                         -> AWSProfile
                         -> SamlAWSCredentials
                         -> Ini
                         -> Ini
updateProfileCredentials region awsProf SamlAWSCredentials{..} awsIni =
  let profileSection = unAwsProfile awsProf
      savedProfileConfSection = fromMaybe M.empty $ M.lookup profileSection (unIni awsIni)

   in Ini $ M.insert profileSection
              ((M.insert "region"                (toText region) .
                M.insert "aws_access_key_id"     (toText sacAuthAccess) .
                M.insert "aws_secret_access_key" (toText sacAuthSecret) .
                M.insert "aws_session_token"     (toText sacAuthToken) .
                M.insert "aws_security_token"    (toText sacAuthToken) ) savedProfileConfSection ) (unIni awsIni)
