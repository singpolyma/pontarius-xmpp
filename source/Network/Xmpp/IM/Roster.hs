{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Xmpp.IM.Roster where

import           Control.Concurrent.STM
import           Control.Monad
import           Data.List (nub)
import qualified Data.Map.Strict as Map
import           Data.Maybe (isJust, fromMaybe)
import           Data.Text (Text)
import           Data.XML.Pickle
import           Data.XML.Types
import           System.Log.Logger

import           Network.Xmpp.IM.Roster.Types
import           Network.Xmpp.Marshal
import           Network.Xmpp.Concurrent.Types
import           Network.Xmpp.Types
import           Network.Xmpp.Concurrent.IQ

-- | Push a roster item to the server. The values for approved and ask are
-- ignored and all values for subsciption except "remove" are ignored
rosterPush :: Item -> Session -> IO IQResponse
rosterPush item session = do
    let el = pickleElem xpQuery (Query Nothing [fromItem item])
    sendIQ'  Nothing Set Nothing el session

-- | Add or update an item to the roster.
--
-- To update the item just send the complete set of new data
rosterAdd :: Jid -- ^ JID of the item
          -> Maybe Text -- ^ Name alias
          -> [Text] -- ^ Groups (duplicates will be removed)
          -> Session
          -> IO IQResponse
rosterAdd j n gs session = do
    let el = pickleElem xpQuery (Query Nothing
                                 [QueryItem { qiApproved = Nothing
                                            , qiAsk = False
                                            , qiJid = j
                                            , qiName = n
                                            , qiSubscription = Nothing
                                            , qiGroups = nub gs
                                            }])
    sendIQ'  Nothing Set Nothing el session

-- | Remove an item from the roster. Return True when the item is sucessfully
-- removed or if it wasn't in the roster to begin with.
rosterRemove :: Jid -> Session -> IO Bool
rosterRemove j sess = do
    roster <- getRoster sess
    case Map.lookup j (items roster) of
        Nothing -> return True -- jid is not on the Roster
        Just _ -> do
            res <- rosterPush (Item False False j Nothing Remove []) sess
            case res of
                IQResponseResult IQResult{} -> return True
                _ -> return False

-- | Retrieve the current Roster state
getRoster :: Session -> IO Roster
getRoster session = atomically $ readTVar (rosterRef session)

-- | Get the initial roster / refresh the roster. You don't need to call this on your own
initRoster :: Session -> IO ()
initRoster session = do
    oldRoster <- getRoster session
    mbRoster <- retrieveRoster (if isJust (ver oldRoster) then Just oldRoster
                                                          else Nothing ) session
    case mbRoster of
        Nothing -> errorM "Pontarius.Xmpp"
                          "Server did not return a roster"
        Just roster -> atomically $ writeTVar (rosterRef session) roster

handleRoster :: TVar Roster -> TChan Stanza -> Stanza -> IO Bool
handleRoster ref outC sta = case sta of
    IQRequestS (iqr@IQRequest{iqRequestPayload =
                                   iqb@Element{elementName = en}})
        | nameNamespace en == Just "jabber:iq:roster" -> do
            case iqRequestFrom iqr of
                Just _from -> return True -- Don't handle roster pushes from
                                          -- unauthorized sources
                Nothing -> case unpickleElem xpQuery iqb of
                    Right Query{ queryVer = v
                               , queryItems = [update]
                               } -> do
                        handleUpdate v update
                        atomically . writeTChan outC $ result iqr
                        return False
                    _ -> do
                        errorM "Pontarius.Xmpp" "Invalid roster query"
                        atomically . writeTChan outC $ badRequest iqr
                        return False
    _ -> return True
  where
    handleUpdate v' update = atomically $ modifyTVar ref $ \(Roster v is) ->
        Roster (v' `mplus` v) $ case qiSubscription update of
            Just Remove -> Map.delete (qiJid update) is
            _ -> Map.insert (qiJid update) (toItem update) is

    badRequest (IQRequest iqid from _to lang _tp bd) =
        IQErrorS $ IQError iqid Nothing from lang errBR (Just bd)
    errBR = StanzaError Cancel BadRequest Nothing Nothing
    result (IQRequest iqid from _to lang _tp _bd) =
        IQResultS $ IQResult iqid Nothing from lang Nothing

retrieveRoster :: Maybe Roster -> Session -> IO (Maybe Roster)
retrieveRoster oldRoster sess = do
    res <- sendIQ' Nothing Get Nothing
        (pickleElem xpQuery (Query (ver =<< oldRoster) []))
        sess
    case res of
        IQResponseResult (IQResult{iqResultPayload = Just ros})
            -> case unpickleElem xpQuery ros of
            Left _e -> do
                errorM "Pontarius.Xmpp.Roster" "getRoster: invalid query element"
                return Nothing
            Right ros' -> return . Just $ toRoster ros'
        IQResponseResult (IQResult{iqResultPayload = Nothing}) -> do
            return oldRoster
                -- sever indicated that no roster updates are necessary
        IQResponseTimeout -> do
            errorM "Pontarius.Xmpp.Roster" "getRoster: request timed out"
            return Nothing
        IQResponseError e -> do
            errorM "Pontarius.Xmpp.Roster" $ "getRoster: server returned error"
                   ++ show e
            return Nothing
  where
    toRoster (Query v is) = Roster v (Map.fromList
                                             $ map (\i -> (qiJid i, toItem i))
                                               is)

toItem :: QueryItem -> Item
toItem qi = Item { approved = fromMaybe False (qiApproved qi)
                 , ask = qiAsk qi
                 , jid = qiJid qi
                 , name = qiName qi
                 , subscription = fromMaybe None (qiSubscription qi)
                 , groups = nub $ qiGroups qi
                 }

fromItem :: Item -> QueryItem
fromItem i = QueryItem { qiApproved = Nothing
                       , qiAsk = False
                       , qiJid = jid i
                       , qiName = name i
                       , qiSubscription = case subscription i of
                           Remove -> Just Remove
                           _ -> Nothing
                       , qiGroups = nub $ groups i
                       }

xpItems :: PU [Node] [QueryItem]
xpItems = xpWrap (map (\((app_, ask_, jid_, name_, sub_), groups_) ->
                        QueryItem app_ ask_ jid_ name_ sub_ groups_))
                 (map (\(QueryItem app_ ask_ jid_ name_ sub_ groups_) ->
                        ((app_, ask_, jid_, name_, sub_), groups_))) $
          xpElems "{jabber:iq:roster}item"
          (xp5Tuple
            (xpAttribute' "approved" xpBool)
            (xpWrap isJust
                    (\p -> if p then Just () else Nothing) $
                     xpOption $ xpAttribute_ "ask" "subscribe")
            (xpAttribute  "jid" xpPrim)
            (xpAttribute' "name" xpText)
            (xpAttribute' "subscription" xpPrim)
          )
          (xpFindMatches $ xpElemText "{jabber:iq:roster}group")

xpQuery :: PU [Node] Query
xpQuery = xpWrap (\(ver_, items_) -> Query ver_ items_ )
                 (\(Query ver_ items_) -> (ver_, items_)) $
          xpElem "{jabber:iq:roster}query"
            (xpAttribute' "ver" xpText)
            xpItems
