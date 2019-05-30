module Hasura.RQL.Types.Common
       ( PGColInfo(..)
       , RelName(..)
       , relNameToTxt
       , RelType(..)
       , rootRelName
       , relTypeToTxt
       , RelInfo(..)

       , FieldName(..)
       , fromPGCol
       , fromRel

       , TQueryName(..)
       , TemplateParam(..)

       , ToAesonPairs(..)
       , WithTable(..)
       , ColVals
       , MutateResp(..)

       , NEText
       , mkNEText
       , unNEText
       , adminText
       , rootText
       ) where

import           Hasura.Prelude
import           Hasura.SQL.Types

import           Data.Aeson
import           Data.Aeson.Casing
import           Data.Aeson.TH
import           Data.Aeson.Types
import qualified Data.HashMap.Strict        as HM
import qualified Data.Text                  as T
import qualified Database.PG.Query          as Q
import           Instances.TH.Lift          ()
import           Language.Haskell.TH.Syntax (Lift)
import qualified PostgreSQL.Binary.Decoding as PD

data PGColInfo
  = PGColInfo
  { pgiName       :: !PGCol
  , pgiType       :: !PGColType
  , pgiIsNullable :: !Bool
  } deriving (Show, Eq)

$(deriveJSON (aesonDrop 3 snakeCase) ''PGColInfo)

newtype NEText = NEText {unNEText :: T.Text}
  deriving (Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, Lift, Q.ToPrepArg, DQuote)

mkNEText :: T.Text -> Maybe NEText
mkNEText ""   = Nothing
mkNEText text = Just $ NEText text

parseNEText :: T.Text -> Parser NEText
parseNEText text = case mkNEText text of
  Nothing     -> fail "empty string not allowed"
  Just neText -> return neText

instance FromJSON NEText where
  parseJSON = withText "String" parseNEText

instance FromJSONKey NEText where
  fromJSONKey = FromJSONKeyTextParser parseNEText

instance Q.FromCol NEText where
  fromCol bs = mkNEText <$> Q.fromCol bs
    >>= maybe (Left "empty string not allowed") Right

adminText :: NEText
adminText = NEText "admin"

rootText :: NEText
rootText = NEText "root"

newtype RelName
  = RelName {getRelTxt :: NEText}
  deriving (Show, Eq, Hashable, FromJSON, ToJSON, Q.ToPrepArg, Q.FromCol, Lift)

instance IsIden RelName where
  toIden rn = Iden $ relNameToTxt rn

instance DQuote RelName where
  dquoteTxt = relNameToTxt

rootRelName :: RelName
rootRelName = RelName rootText

relNameToTxt :: RelName -> T.Text
relNameToTxt = unNEText . getRelTxt

relTypeToTxt :: RelType -> T.Text
relTypeToTxt ObjRel = "object"
relTypeToTxt ArrRel = "array"

data RelType
  = ObjRel
  | ArrRel
  deriving (Show, Eq, Generic)

instance Hashable RelType

instance ToJSON RelType where
  toJSON = String . relTypeToTxt

instance FromJSON RelType where
  parseJSON (String "object") = return ObjRel
  parseJSON (String "array") = return ArrRel
  parseJSON _ = fail "expecting either 'object' or 'array' for rel_type"

instance Q.FromCol RelType where
  fromCol bs = flip Q.fromColHelper bs $ PD.enum $ \case
    "object" -> Just ObjRel
    "array"  -> Just ArrRel
    _   -> Nothing

data RelInfo
  = RelInfo
  { riName     :: !RelName
  , riType     :: !RelType
  , riMapping  :: ![(PGCol, PGCol)]
  , riRTable   :: !QualifiedTable
  , riIsManual :: !Bool
  } deriving (Show, Eq)

$(deriveToJSON (aesonDrop 2 snakeCase) ''RelInfo)

newtype FieldName
  = FieldName { getFieldNameTxt :: T.Text }
  deriving (Show, Eq, Ord, Hashable, FromJSON, ToJSON, FromJSONKey, ToJSONKey, Lift)

instance IsIden FieldName where
  toIden (FieldName f) = Iden f

instance DQuote FieldName where
  dquoteTxt (FieldName c) = c

fromPGCol :: PGCol -> FieldName
fromPGCol (PGCol c) = FieldName c

fromRel :: RelName -> FieldName
fromRel rn = FieldName $ relNameToTxt rn

newtype TQueryName
  = TQueryName { getTQueryName :: NEText }
  deriving ( Show, Eq, Hashable, FromJSONKey, ToJSONKey
           , FromJSON, ToJSON, Q.ToPrepArg, Q.FromCol, Lift)

instance IsIden TQueryName where
  toIden (TQueryName r) = Iden $ unNEText r

instance DQuote TQueryName where
  dquoteTxt (TQueryName r) = unNEText r

newtype TemplateParam
  = TemplateParam { getTemplateParam :: T.Text }
  deriving (Show, Eq, Hashable, FromJSON, FromJSONKey, ToJSONKey, ToJSON, Lift)

instance DQuote TemplateParam where
  dquoteTxt (TemplateParam r) = r

class ToAesonPairs a where
  toAesonPairs :: (KeyValue v) => a -> [v]

data WithTable a
  = WithTable
  { wtName :: !QualifiedTable
  , wtInfo :: !a
  } deriving (Show, Eq, Lift)

instance (FromJSON a) => FromJSON (WithTable a) where
  parseJSON v@(Object o) =
    WithTable <$> o .: "table" <*> parseJSON v
  parseJSON _ =
    fail "expecting an Object with key 'table'"

instance (ToAesonPairs a) => ToJSON (WithTable a) where
  toJSON (WithTable tn rel) =
    object $ ("table" .= tn):toAesonPairs rel

type ColVals = HM.HashMap PGCol Value

data MutateResp
  = MutateResp
  { _mrAffectedRows     :: !Int
  , _mrReturningColumns :: ![ColVals]
  } deriving (Show, Eq)
$(deriveJSON (aesonDrop 3 snakeCase) ''MutateResp)
