{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Simplex.Chat.Store.Shared where

import Control.Concurrent.STM (stateTVar)
import Control.Exception (Exception)
import qualified Control.Exception as E
import Control.Monad.Except
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..), getCurrentTime)
import Database.SQLite.Simple (NamedParam (..), Only (..), Query, SQLError, (:.) (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import GHC.Generics (Generic)
import Simplex.Chat.Messages
import Simplex.Chat.Protocol
import Simplex.Chat.Types
import Simplex.Chat.Types.Preferences
import Simplex.Messaging.Agent.Protocol (AgentMsgId, ConnId, UserId)
import Simplex.Messaging.Agent.Store.SQLite (firstRow, maybeFirstRow)
import Simplex.Messaging.Parsers (dropPrefix, sumTypeJSON)
import Simplex.Messaging.Util (allFinally)
import UnliftIO.STM

-- These error type constructors must be added to mobile apps
data StoreError
  = SEDuplicateName
  | SEUserNotFound {userId :: UserId}
  | SEUserNotFoundByName {contactName :: ContactName}
  | SEUserNotFoundByContactId {contactId :: ContactId}
  | SEUserNotFoundByGroupId {groupId :: GroupId}
  | SEUserNotFoundByFileId {fileId :: FileTransferId}
  | SEUserNotFoundByContactRequestId {contactRequestId :: Int64}
  | SEContactNotFound {contactId :: ContactId}
  | SEContactNotFoundByName {contactName :: ContactName}
  | SEContactNotReady {contactName :: ContactName}
  | SEDuplicateContactLink
  | SEUserContactLinkNotFound
  | SEContactRequestNotFound {contactRequestId :: Int64}
  | SEContactRequestNotFoundByName {contactName :: ContactName}
  | SEGroupNotFound {groupId :: GroupId}
  | SEGroupNotFoundByName {groupName :: GroupName}
  | SEGroupMemberNameNotFound {groupId :: GroupId, groupMemberName :: ContactName}
  | SEGroupMemberNotFound {groupMemberId :: GroupMemberId}
  | SEGroupMemberNotFoundByMemberId {memberId :: MemberId}
  | SEGroupWithoutUser
  | SEDuplicateGroupMember
  | SEGroupAlreadyJoined
  | SEGroupInvitationNotFound
  | SESndFileNotFound {fileId :: FileTransferId}
  | SESndFileInvalid {fileId :: FileTransferId}
  | SERcvFileNotFound {fileId :: FileTransferId}
  | SERcvFileDescrNotFound {fileId :: FileTransferId}
  | SEFileNotFound {fileId :: FileTransferId}
  | SERcvFileInvalid {fileId :: FileTransferId}
  | SERcvFileInvalidDescrPart
  | SESharedMsgIdNotFoundByFileId {fileId :: FileTransferId}
  | SEFileIdNotFoundBySharedMsgId {sharedMsgId :: SharedMsgId}
  | SESndFileNotFoundXFTP {agentSndFileId :: AgentSndFileId}
  | SERcvFileNotFoundXFTP {agentRcvFileId :: AgentRcvFileId}
  | SEConnectionNotFound {agentConnId :: AgentConnId}
  | SEConnectionNotFoundById {connId :: Int64}
  | SEPendingConnectionNotFound {connId :: Int64}
  | SEIntroNotFound
  | SEUniqueID
  | SEInternalError {message :: String}
  | SENoMsgDelivery {connId :: Int64, agentMsgId :: AgentMsgId}
  | SEBadChatItem {itemId :: ChatItemId}
  | SEChatItemNotFound {itemId :: ChatItemId}
  | SEChatItemNotFoundByText {text :: Text}
  | SEChatItemSharedMsgIdNotFound {sharedMsgId :: SharedMsgId}
  | SEChatItemNotFoundByFileId {fileId :: FileTransferId}
  | SEChatItemNotFoundByGroupId {groupId :: GroupId}
  | SEProfileNotFound {profileId :: Int64}
  | SEDuplicateGroupLink {groupInfo :: GroupInfo}
  | SEGroupLinkNotFound {groupInfo :: GroupInfo}
  | SEHostMemberIdNotFound {groupId :: Int64}
  | SEContactNotFoundByFileId {fileId :: FileTransferId}
  deriving (Show, Exception, Generic)

instance ToJSON StoreError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "SE"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "SE"

insertedRowId :: DB.Connection -> IO Int64
insertedRowId db = fromOnly . head <$> DB.query_ db "SELECT last_insert_rowid()"

checkConstraint :: StoreError -> ExceptT StoreError IO a -> ExceptT StoreError IO a
checkConstraint err action = ExceptT $ runExceptT action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SQLError -> StoreError
handleSQLError err e
  | DB.sqlError e == DB.ErrorConstraint = err
  | otherwise = SEInternalError $ show e

storeFinally :: ExceptT StoreError IO a -> ExceptT StoreError IO b -> ExceptT StoreError IO a
storeFinally = allFinally mkStoreError
{-# INLINE storeFinally #-}

mkStoreError :: E.SomeException -> StoreError
mkStoreError = SEInternalError . show
{-# INLINE mkStoreError #-}

fileInfoQuery :: Query
fileInfoQuery =
  [sql|
    SELECT f.file_id, f.ci_file_status, f.file_path
    FROM chat_items i
    JOIN files f ON f.chat_item_id = i.chat_item_id
  |]

toFileInfo :: (Int64, Maybe ACIFileStatus, Maybe FilePath) -> CIFileInfo
toFileInfo (fileId, fileStatus, filePath) = CIFileInfo {fileId, fileStatus, filePath}

type EntityIdsRow = (Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64)

type ConnectionRow = (Int64, ConnId, Int, Maybe Int64, Maybe Int64, Bool, Maybe GroupLinkId, Maybe Int64, ConnStatus, ConnType, LocalAlias) :. EntityIdsRow :. (UTCTime, Maybe Text, Maybe UTCTime, Int)

type MaybeConnectionRow = (Maybe Int64, Maybe ConnId, Maybe Int, Maybe Int64, Maybe Int64, Maybe Bool, Maybe GroupLinkId, Maybe Int64, Maybe ConnStatus, Maybe ConnType, Maybe LocalAlias) :. EntityIdsRow :. (Maybe UTCTime, Maybe Text, Maybe UTCTime, Maybe Int)

toConnection :: ConnectionRow -> Connection
toConnection ((connId, acId, connLevel, viaContact, viaUserContactLink, viaGroupLink, groupLinkId, customUserProfileId, connStatus, connType, localAlias) :. (contactId, groupMemberId, sndFileId, rcvFileId, userContactLinkId) :. (createdAt, code_, verifiedAt_, authErrCounter)) =
  let entityId = entityId_ connType
      connectionCode = SecurityCode <$> code_ <*> verifiedAt_
   in Connection {connId, agentConnId = AgentConnId acId, connLevel, viaContact, viaUserContactLink, viaGroupLink, groupLinkId, customUserProfileId, connStatus, connType, localAlias, entityId, connectionCode, authErrCounter, createdAt}
  where
    entityId_ :: ConnType -> Maybe Int64
    entityId_ ConnContact = contactId
    entityId_ ConnMember = groupMemberId
    entityId_ ConnRcvFile = rcvFileId
    entityId_ ConnSndFile = sndFileId
    entityId_ ConnUserContact = userContactLinkId

toMaybeConnection :: MaybeConnectionRow -> Maybe Connection
toMaybeConnection ((Just connId, Just agentConnId, Just connLevel, viaContact, viaUserContactLink, Just viaGroupLink, groupLinkId, customUserProfileId, Just connStatus, Just connType, Just localAlias) :. (contactId, groupMemberId, sndFileId, rcvFileId, userContactLinkId) :. (Just createdAt, code_, verifiedAt_, Just authErrCounter)) =
  Just $ toConnection ((connId, agentConnId, connLevel, viaContact, viaUserContactLink, viaGroupLink, groupLinkId, customUserProfileId, connStatus, connType, localAlias) :. (contactId, groupMemberId, sndFileId, rcvFileId, userContactLinkId) :. (createdAt, code_, verifiedAt_, authErrCounter))
toMaybeConnection _ = Nothing

createConnection_ :: DB.Connection -> UserId -> ConnType -> Maybe Int64 -> ConnId -> Maybe ContactId -> Maybe Int64 -> Maybe ProfileId -> Int -> UTCTime -> IO Connection
createConnection_ db userId connType entityId acId viaContact viaUserContactLink customUserProfileId connLevel currentTs = do
  viaLinkGroupId :: Maybe Int64 <- fmap join . forM viaUserContactLink $ \ucLinkId ->
    maybeFirstRow fromOnly $ DB.query db "SELECT group_id FROM user_contact_links WHERE user_id = ? AND user_contact_link_id = ? AND group_id IS NOT NULL" (userId, ucLinkId)
  let viaGroupLink = isJust viaLinkGroupId
  DB.execute
    db
    [sql|
      INSERT INTO connections (
        user_id, agent_conn_id, conn_level, via_contact, via_user_contact_link, via_group_link, custom_user_profile_id, conn_status, conn_type,
        contact_id, group_member_id, snd_file_id, rcv_file_id, user_contact_link_id, created_at, updated_at
      ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    |]
    ( (userId, acId, connLevel, viaContact, viaUserContactLink, viaGroupLink, customUserProfileId, ConnNew, connType)
        :. (ent ConnContact, ent ConnMember, ent ConnSndFile, ent ConnRcvFile, ent ConnUserContact, currentTs, currentTs)
    )
  connId <- insertedRowId db
  pure Connection {connId, agentConnId = AgentConnId acId, connType, entityId, viaContact, viaUserContactLink, viaGroupLink, groupLinkId = Nothing, customUserProfileId, connLevel, connStatus = ConnNew, localAlias = "", createdAt = currentTs, connectionCode = Nothing, authErrCounter = 0}
  where
    ent ct = if connType == ct then entityId else Nothing

setCommandConnId :: DB.Connection -> User -> CommandId -> Int64 -> IO ()
setCommandConnId db User {userId} cmdId connId = do
  updatedAt <- getCurrentTime
  DB.execute
    db
    [sql|
      UPDATE commands
      SET connection_id = ?, updated_at = ?
      WHERE user_id = ? AND command_id = ?
    |]
    (connId, updatedAt, userId, cmdId)

createContact_ :: DB.Connection -> UserId -> Int64 -> Profile -> LocalAlias -> Maybe Int64 -> UTCTime -> Maybe UTCTime -> ExceptT StoreError IO (Text, ContactId, ProfileId)
createContact_ db userId connId Profile {displayName, fullName, image, contactLink, preferences} localAlias viaGroup currentTs chatTs =
  ExceptT . withLocalDisplayName db userId displayName $ \ldn -> do
    DB.execute
      db
      "INSERT INTO contact_profiles (display_name, full_name, image, contact_link, user_id, local_alias, preferences, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)"
      (displayName, fullName, image, contactLink, userId, localAlias, preferences, currentTs, currentTs)
    profileId <- insertedRowId db
    DB.execute
      db
      "INSERT INTO contacts (contact_profile_id, local_display_name, user_id, via_group, created_at, updated_at, chat_ts) VALUES (?,?,?,?,?,?,?)"
      (profileId, ldn, userId, viaGroup, currentTs, currentTs, chatTs)
    contactId <- insertedRowId db
    DB.execute db "UPDATE connections SET contact_id = ?, updated_at = ? WHERE connection_id = ?" (contactId, currentTs, connId)
    pure $ Right (ldn, contactId, profileId)

deleteUnusedIncognitoProfileById_ :: DB.Connection -> User -> ProfileId -> IO ()
deleteUnusedIncognitoProfileById_ db User {userId} profile_id =
  DB.executeNamed
    db
    [sql|
      DELETE FROM contact_profiles
      WHERE user_id = :user_id AND contact_profile_id = :profile_id AND incognito = 1
        AND 1 NOT IN (
          SELECT 1 FROM connections
          WHERE user_id = :user_id AND custom_user_profile_id = :profile_id LIMIT 1
        )
        AND 1 NOT IN (
          SELECT 1 FROM group_members
          WHERE user_id = :user_id AND member_profile_id = :profile_id LIMIT 1
        )
    |]
    [":user_id" := userId, ":profile_id" := profile_id]

type ContactRow = (ContactId, ProfileId, ContactName, Maybe Int64, ContactName, Text, Maybe ImageData, Maybe ConnReqContact, LocalAlias, Bool) :. (Maybe Bool, Maybe Bool, Bool, Maybe Preferences, Preferences, UTCTime, UTCTime, Maybe UTCTime)

toContact :: User -> ContactRow :. ConnectionRow -> Contact
toContact user (((contactId, profileId, localDisplayName, viaGroup, displayName, fullName, image, contactLink, localAlias, contactUsed) :. (enableNtfs_, sendRcpts, favorite, preferences, userPreferences, createdAt, updatedAt, chatTs)) :. connRow) =
  let profile = LocalProfile {profileId, displayName, fullName, image, contactLink, preferences, localAlias}
      activeConn = toConnection connRow
      chatSettings = ChatSettings {enableNtfs = fromMaybe True enableNtfs_, sendRcpts, favorite}
      mergedPreferences = contactUserPreferences user userPreferences preferences $ connIncognito activeConn
   in Contact {contactId, localDisplayName, profile, activeConn, viaGroup, contactUsed, chatSettings, userPreferences, mergedPreferences, createdAt, updatedAt, chatTs}

toContactOrError :: User -> ContactRow :. MaybeConnectionRow -> Either StoreError Contact
toContactOrError user (((contactId, profileId, localDisplayName, viaGroup, displayName, fullName, image, contactLink, localAlias, contactUsed) :. (enableNtfs_, sendRcpts, favorite, preferences, userPreferences, createdAt, updatedAt, chatTs)) :. connRow) =
  let profile = LocalProfile {profileId, displayName, fullName, image, contactLink, preferences, localAlias}
      chatSettings = ChatSettings {enableNtfs = fromMaybe True enableNtfs_, sendRcpts, favorite}
   in case toMaybeConnection connRow of
        Just activeConn ->
          let mergedPreferences = contactUserPreferences user userPreferences preferences $ connIncognito activeConn
           in Right Contact {contactId, localDisplayName, profile, activeConn, viaGroup, contactUsed, chatSettings, userPreferences, mergedPreferences, createdAt, updatedAt, chatTs}
        _ -> Left $ SEContactNotReady localDisplayName

getProfileById :: DB.Connection -> UserId -> Int64 -> ExceptT StoreError IO LocalProfile
getProfileById db userId profileId =
  ExceptT . firstRow toProfile (SEProfileNotFound profileId) $
    DB.query
      db
      [sql|
        SELECT cp.display_name, cp.full_name, cp.image, cp.contact_link, cp.local_alias, cp.preferences -- , ct.user_preferences
        FROM contact_profiles cp
        WHERE cp.user_id = ? AND cp.contact_profile_id = ?
      |]
      (userId, profileId)
  where
    toProfile :: (ContactName, Text, Maybe ImageData, Maybe ConnReqContact, LocalAlias, Maybe Preferences) -> LocalProfile
    toProfile (displayName, fullName, image, contactLink, localAlias, preferences) = LocalProfile {profileId, displayName, fullName, image, contactLink, preferences, localAlias}

type ContactRequestRow = (Int64, ContactName, AgentInvId, Int64, AgentConnId, Int64, ContactName, Text, Maybe ImageData, Maybe ConnReqContact) :. (Maybe XContactId, Maybe Preferences, UTCTime, UTCTime)

toContactRequest :: ContactRequestRow -> UserContactRequest
toContactRequest ((contactRequestId, localDisplayName, agentInvitationId, userContactLinkId, agentContactConnId, profileId, displayName, fullName, image, contactLink) :. (xContactId, preferences, createdAt, updatedAt)) = do
  let profile = Profile {displayName, fullName, image, contactLink, preferences}
   in UserContactRequest {contactRequestId, agentInvitationId, userContactLinkId, agentContactConnId, localDisplayName, profileId, profile, xContactId, createdAt, updatedAt}

userQuery :: Query
userQuery =
  [sql|
    SELECT u.user_id, u.agent_user_id, u.contact_id, ucp.contact_profile_id, u.active_user, u.local_display_name, ucp.full_name, ucp.image, ucp.contact_link, ucp.preferences,
      u.show_ntfs, u.send_rcpts_contacts, u.send_rcpts_small_groups, u.view_pwd_hash, u.view_pwd_salt
    FROM users u
    JOIN contacts uct ON uct.contact_id = u.contact_id
    JOIN contact_profiles ucp ON ucp.contact_profile_id = uct.contact_profile_id
  |]

toUser :: (UserId, UserId, ContactId, ProfileId, Bool, ContactName, Text, Maybe ImageData, Maybe ConnReqContact, Maybe Preferences) :. (Bool, Bool, Bool, Maybe B64UrlByteString, Maybe B64UrlByteString) -> User
toUser ((userId, auId, userContactId, profileId, activeUser, displayName, fullName, image, contactLink, userPreferences) :. (showNtfs, sendRcptsContacts, sendRcptsSmallGroups, viewPwdHash_, viewPwdSalt_)) =
  User {userId, agentUserId = AgentUserId auId, userContactId, localDisplayName = displayName, profile, activeUser, fullPreferences, showNtfs, sendRcptsContacts, sendRcptsSmallGroups, viewPwdHash}
  where
    profile = LocalProfile {profileId, displayName, fullName, image, contactLink, preferences = userPreferences, localAlias = ""}
    fullPreferences = mergePreferences Nothing userPreferences
    viewPwdHash = UserPwdHash <$> viewPwdHash_ <*> viewPwdSalt_

toPendingContactConnection :: (Int64, ConnId, ConnStatus, Maybe ByteString, Maybe Int64, Maybe GroupLinkId, Maybe Int64, Maybe ConnReqInvitation, LocalAlias, UTCTime, UTCTime) -> PendingContactConnection
toPendingContactConnection (pccConnId, acId, pccConnStatus, connReqHash, viaUserContactLink, groupLinkId, customUserProfileId, connReqInv, localAlias, createdAt, updatedAt) =
  PendingContactConnection {pccConnId, pccAgentConnId = AgentConnId acId, pccConnStatus, viaContactUri = isJust connReqHash, viaUserContactLink, groupLinkId, customUserProfileId, connReqInv, localAlias, createdAt, updatedAt}

-- | Saves unique local display name based on passed displayName, suffixed with _N if required.
-- This function should be called inside transaction.
withLocalDisplayName :: forall a. DB.Connection -> UserId -> Text -> (Text -> IO (Either StoreError a)) -> IO (Either StoreError a)
withLocalDisplayName db userId displayName action = getLdnSuffix >>= (`tryCreateName` 20)
  where
    getLdnSuffix :: IO Int
    getLdnSuffix =
      maybe 0 ((+ 1) . fromOnly) . listToMaybe
        <$> DB.queryNamed
          db
          [sql|
            SELECT ldn_suffix FROM display_names
            WHERE user_id = :user_id AND ldn_base = :display_name
            ORDER BY ldn_suffix DESC
            LIMIT 1
          |]
          [":user_id" := userId, ":display_name" := displayName]
    tryCreateName :: Int -> Int -> IO (Either StoreError a)
    tryCreateName _ 0 = pure $ Left SEDuplicateName
    tryCreateName ldnSuffix attempts = do
      currentTs <- getCurrentTime
      let ldn = displayName <> (if ldnSuffix == 0 then "" else T.pack $ '_' : show ldnSuffix)
      E.try (insertName ldn currentTs) >>= \case
        Right () -> action ldn
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreateName (ldnSuffix + 1) (attempts - 1)
          | otherwise -> E.throwIO e
      where
        insertName ldn ts =
          DB.execute
            db
            [sql|
              INSERT INTO display_names
                (local_display_name, ldn_base, ldn_suffix, user_id, created_at, updated_at)
              VALUES (?,?,?,?,?,?)
            |]
            (ldn, displayName, ldnSuffix, userId, ts, ts)

createWithRandomId :: forall a. TVar ChaChaDRG -> (ByteString -> IO a) -> ExceptT StoreError IO a
createWithRandomId = createWithRandomBytes 12

createWithRandomBytes :: forall a. Int -> TVar ChaChaDRG -> (ByteString -> IO a) -> ExceptT StoreError IO a
createWithRandomBytes size gVar create = tryCreate 3
  where
    tryCreate :: Int -> ExceptT StoreError IO a
    tryCreate 0 = throwError SEUniqueID
    tryCreate n = do
      id' <- liftIO $ encodedRandomBytes gVar size
      liftIO (E.try $ create id') >>= \case
        Right x -> pure x
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> throwError . SEInternalError $ show e

encodedRandomBytes :: TVar ChaChaDRG -> Int -> IO ByteString
encodedRandomBytes gVar = fmap B64.encode . randomBytes gVar

randomBytes :: TVar ChaChaDRG -> Int -> IO ByteString
randomBytes gVar = atomically . stateTVar gVar . randomBytesGenerate
