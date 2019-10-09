-- | Migrations for the Hasura catalog.
--
-- To add a new migration:
--
--   1. Bump the catalog version number in "Migrate.Version".
--   2. Add a migration script in the @src-rsr/migrations/@ directory with the name
--      @<old version>_to_<new version>.sql@.
--
-- The Template Haskell code in this module will automatically compile the new migration script into
-- the @graphql-engine@ executable.
module Migrate
  ( latestCatalogVersion
  , migrateCatalog
  ) where

import           Data.Time.Clock            (UTCTime)

import           Hasura.Prelude
import           Hasura.RQL.DDL.Schema
import           Hasura.RQL.Types
import           Hasura.Server.Query

import qualified Data.Aeson                 as A
import qualified Data.Text                  as T
import qualified Data.Yaml.TH               as Y
import qualified Database.PG.Query          as Q
import qualified Language.Haskell.TH.Lib    as TH
import qualified Language.Haskell.TH.Syntax as TH

import Migrate.Version (latestCatalogVersion)

migrateCatalog
  :: forall m
   . ( MonadTx m
     , HasHttpManager m
     , HasSystemDefined m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     , HasSQLGenCtx m
     )
  => UTCTime -> m T.Text
migrateCatalog migrationTime = migrateFrom =<< getCatalogVersion
  where
    -- the old 0.8 catalog version is non-integral, so we store it in the database as a string
    latestCatalogVersionString = T.pack $ show latestCatalogVersion

    getCatalogVersion = liftTx $ runIdentity . Q.getRow <$> Q.withQE defaultTxErrorHandler
      [Q.sql| SELECT version FROM hdb_catalog.hdb_version |] () False

    migrateFrom :: T.Text -> m T.Text
    migrateFrom previousVersion
      | previousVersion == latestCatalogVersionString = pure $
          "already at the latest version. current version: " <> latestCatalogVersionString
      | [] <- neededMigrations = throw400 NotSupported $ "unsupported version : " <> previousVersion
      | otherwise = traverse_ snd neededMigrations *> postMigrate
      where
        neededMigrations = dropWhile ((/= previousVersion) . fst) migrations

        migrations :: [(T.Text, m ())]
        migrations =
          -- We need to build the list of migrations at compile-time so that we can compile the SQL
          -- directly into the executable using `Q.sqlFromFile`. The GHC stage restriction makes
          -- doing this a little bit awkward (we can’t use any definitions in this module at
          -- compile-time), but putting a `let` inside the splice itself is allowed.
          $(let migrationFromFile from to =
                  let path = "src-rsr/migrations/" <> from <> "_to_" <> to <> ".sql"
                  in [| runTx $(Q.sqlFromFile path) |]
                migrationsFromFile = map $ \(to :: Integer) ->
                  [| ( $(TH.lift $ T.pack (show to))
                     , $(migrationFromFile (show (to - 1)) (show to))
                     ) |]
            in TH.listE
              -- version 0.8 is the only non-integral catalog version
              $  [| ("0.8", $(migrationFromFile "08" "1")) |]
              :  migrationsFromFile [2..3]
              ++ [| ("3", from3To4) |]
              :  migrationsFromFile [5..latestCatalogVersion])

    postMigrate = do
      updateCatalogVersion
      replaceSystemMetadata
      buildSchemaCacheStrict
      pure $ "successfully migrated to " <> latestCatalogVersionString

    updateCatalogVersion = liftTx $ Q.unitQE defaultTxErrorHandler [Q.sql|
      UPDATE "hdb_catalog"."hdb_version"
         SET "version" = $1,
             "upgraded_on" = $2
      |] (latestCatalogVersionString, migrationTime) False

    replaceSystemMetadata = do
      runTx $(Q.sqlFromFile "src-rsr/clear_system_metadata.sql")
      void $ runQueryM $$(Y.decodeFile "src-rsr/hdb_metadata.yaml")

    from3To4 = liftTx $ Q.catchE defaultTxErrorHandler $ do
      Q.unitQ [Q.sql|
        ALTER TABLE hdb_catalog.event_triggers
        ADD COLUMN configuration JSON |] () False
      eventTriggers <- map uncurryEventTrigger <$> Q.listQ [Q.sql|
        SELECT e.name, e.definition::json, e.webhook, e.num_retries, e.retry_interval, e.headers::json
        FROM hdb_catalog.event_triggers e |] () False
      forM_ eventTriggers updateEventTrigger3To4
      Q.unitQ [Q.sql|
        ALTER TABLE hdb_catalog.event_triggers
        DROP COLUMN definition,
        DROP COLUMN query,
        DROP COLUMN webhook,
        DROP COLUMN num_retries,
        DROP COLUMN retry_interval,
        DROP COLUMN headers |] () False
      where
        uncurryEventTrigger (trn, Q.AltJ tDef, w, nr, rint, Q.AltJ headers) =
          EventTriggerConf trn tDef (Just w) Nothing (RetryConf nr rint Nothing) headers
        updateEventTrigger3To4 etc@(EventTriggerConf name _ _ _ _ _) = Q.unitQ [Q.sql|
                                             UPDATE hdb_catalog.event_triggers
                                             SET
                                             configuration = $1
                                             WHERE name = $2
                                             |] (Q.AltJ $ A.toJSON etc, name) True

    runTx :: Q.Query -> m ()
    runTx = liftTx . Q.multiQE defaultTxErrorHandler
