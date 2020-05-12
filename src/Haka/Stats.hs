{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Haka.Stats
  ( API,
    server,
  )
where

import Control.Exception.Safe (throw)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Aeson (ToJSON (..), genericToJSON)
import Data.Int (Int64)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Time (addDays, diffDays)
import Data.Time.Clock (UTCTime (..), getCurrentTime)
import GHC.Generics
import Haka.AesonHelpers (noPrefixOptions)
import qualified Haka.DatabaseOperations as DbOps
import Haka.Errors (missingAuthError)
import Haka.Types (ApiToken (..), AppM, StatRow (..), pool)
import Katip
import Polysemy (runM)
import Polysemy.Error (runError)
import Polysemy.IO (embedToMonadIO)
import PostgreSQL.Binary.Data (Scientific)
import Servant

data ResourceStats
  = ResourceStats
      { -- | The name of the resource.
        pName :: Text,
        -- | Total number of seconds spent on the resource for the time range.
        pTotalSeconds :: Int64,
        -- | Percentage of the total time in the range spent on the resource.
        pTotalPct :: Scientific,
        -- | Total seconds spend on the project for each day in the range.
        pTotalDaily :: [Int64],
        -- | Percentage of the day spent on the resource for each day in the range.
        pPctDaily :: [Scientific]
      }
  deriving (Show, Generic)

instance ToJSON ResourceStats where
  toJSON = genericToJSON noPrefixOptions

-- TODO: Move data types to a separate module
data StatsPayload
  = StatsPayload
      { -- The first day in the range (inclusive).
        startDate :: UTCTime,
        -- The last day in the range (inclusive).
        endDate :: UTCTime,
        -- | Total coding activity as seconds for the given range of time.
        totalSeconds :: Int64,
        -- | Average coding activity per day as seconds for the given range of time.
        dailyAvg :: Double,
        -- | Total coding activity for each day.
        dailyTotal :: [Int64],
        -- Statistics for all each project separately.
        projects :: [ResourceStats],
        -- Statistics for all each language separately.
        languages :: [ResourceStats],
        -- Statistics for all each platform separately.
        platforms :: [ResourceStats],
        -- Statistics for all each machine separately.
        machines :: [ResourceStats],
        -- Statistics for all each editor separately.
        editors :: [ResourceStats]
      }
  deriving (Show, Generic)

instance ToJSON StatsPayload

type TotalStats =
  "api"
    :> "v1"
    :> "users"
    :> "current"
    :> "stats"
    :> QueryParam "start" UTCTime
    :> QueryParam "end" UTCTime
    :> Header "Authorization" ApiToken
    :> Get '[JSON] StatsPayload

type TotalUserStats =
  "api"
    :> "v1"
    :> "users"
    :> Capture "user" Text
    :> "stats"
    :> QueryParam "start" UTCTime
    :> QueryParam "end" UTCTime
    :> Get '[JSON] StatsPayload

type API = TotalStats :<|> TotalUserStats

server ::
  ( Maybe UTCTime ->
    Maybe UTCTime ->
    Maybe ApiToken ->
    AppM StatsPayload
  )
    :<|> ( Text ->
           Maybe UTCTime ->
           Maybe UTCTime ->
           AppM StatsPayload
         )
server = statsHandler :<|> statsUserHandler

-- API Handlers
statsUserHandler ::
  Text ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  AppM StatsPayload
statsUserHandler _ _ _ = undefined

statsHandler ::
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe ApiToken ->
  AppM StatsPayload
statsHandler _ _ Nothing = throw missingAuthError
statsHandler t0Param t1Param (Just token) = do
  t1def <- liftIO getCurrentTime
  p <- asks pool
  let (t0, t1) = case (t0Param, t1Param) of
        (Nothing, Nothing) -> (removeAWeek t1def, t1def)
        (Nothing, Just b) -> (removeAWeek b, b)
        (Just a, Nothing) -> (a, addAWeek a)
        (Just a, Just b) -> (max a (removeAYear b), b)
  res <-
    runM
      . embedToMonadIO
      . runError
      $ DbOps.interpretDatabaseIO
      $ DbOps.generateStatistics p token (t0, t1)
  case res of
    Left e -> do
      $(logTM) ErrorS (logStr $ show e)
      throw (DbOps.toJSONError e)
    Right rows -> return $ toStatsPayload t0 t1 rows
  where
    removeAWeek, removeAYear, addAWeek :: UTCTime -> UTCTime
    removeAWeek t =
      UTCTime
        { utctDay = addDays (-7) (utctDay t),
          utctDayTime = 0
        }
    removeAYear t =
      UTCTime
        { utctDay = addDays (-365) (utctDay t),
          utctDayTime = 0
        }
    addAWeek t =
      UTCTime
        { utctDay = addDays 7 (utctDay t),
          utctDayTime = 0
        }

fillMissing :: [UTCTime] -> [[StatRow]] -> [[StatRow]]
fillMissing times rows = go times rows ([] :: [[StatRow]])
  where
    go :: [UTCTime] -> [[StatRow]] -> [[StatRow]] -> [[StatRow]]
    go [] _ res = res
    go _ [] res = res
    go (t : ts) rows'@(r : rs) res =
      if utctDay t == utctDay (rDay $ head r)
        then go ts rs (res ++ [r])
        else go ts rows' (res ++ [[]])

genDates :: UTCTime -> UTCTime -> [UTCTime]
genDates t0 t1 =
  [ UTCTime
      { utctDay = addDays d (utctDay t0),
        utctDayTime = 0
      }
    | d <- [0 .. (diffDays (utctDay t1) (utctDay t0))]
  ]

-- | Generate a statistics payload object from the statistics rows.
toStatsPayload :: UTCTime -> UTCTime -> [StatRow] -> StatsPayload
toStatsPayload t0 t1 xs =
  StatsPayload
    { totalSeconds = allSecs,
      startDate = t0,
      endDate = t1,
      dailyAvg = dailyAvgSecs,
      dailyTotal = map (sum . map rTotalSeconds) byDate,
      projects = getSegment rProject,
      editors = getSegment rEditor,
      languages = getSegment rLanguage,
      platforms = getSegment rPlatform,
      machines = getSegment rMachine
    }
  where
    getSegment fn =
      let all' :: [(UTCTime, Map.Map Text CalcStatistics)]
          all' = mapMaybe (aggregateBy fn) byDate
          uniqProjectNames :: [Text]
          uniqProjectNames = List.nub $ concatMap ((map fst . Map.toList) . snd) all'
       in map
            ( \name ->
                let (secs', pct', dailyPct') =
                      unzip3 $ map (\(_, m') -> Data.Maybe.fromMaybe (0, 0, 0) (Map.lookup name m')) all'
                 in ResourceStats
                      { pName = name,
                        pTotalSeconds = sum secs',
                        pTotalPct = sum pct',
                        pTotalDaily = secs',
                        pPctDaily = dailyPct'
                      }
            )
            uniqProjectNames
    allSecs :: Int64
    allSecs = sum $ [rTotalSeconds x | x <- xs]
    dailyAvgSecs :: Double
    dailyAvgSecs = fromIntegral allSecs / numOfDays
    byDate :: [[StatRow]]
    byDate = fillMissing (genDates t0 t1) (List.groupBy (\a b -> rDay a == rDay b) xs)
    numOfDays :: Double
    numOfDays = fromIntegral $ length byDate

type RangePct = Scientific

type DailyPct = Scientific

type CalcStatistics = (Int64, RangePct, DailyPct)

aggregateBy ::
  -- | Which field to extract from the row.
  (StatRow -> Text) ->
  -- | All the rows for a particular day.
  [StatRow] ->
  -- | Total seconds of activity per field for that day.
  Maybe (UTCTime, Map.Map Text CalcStatistics)
-- aggregateBy _ [] = Nothing
aggregateBy f rows = Just (rDay $ head rows, go rows Map.empty)
  where
    go :: [StatRow] -> Map.Map Text CalcStatistics -> Map.Map Text CalcStatistics
    go [] m' = m'
    go (x : xs) m' =
      go
        xs
        ( Map.insertWith
            ( \(a', b', c') (a, b, c) -> (a' + a, b' + b, c' + c)
            )
            (f x)
            (rTotalSeconds x, rPct x, rDailyPct x)
            m'
        )