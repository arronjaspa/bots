{- Elvenar Bot v2022-11-30

   This bot collects coins in the Elvenar game client window.

   The bot picks the topmost window in the display order, the one in the front. This selection happens once when starting the bot. The bot then remembers the window address and continues working on the same window.
   To use this bot, bring the Elvenar game client window to the foreground after pressing the button to run the bot. When the bot displays the window title in the status text, it has completed the selection of the game window.

   You can test this bot by placing a screenshot in a paint app like MS Paint or Paint.NET, where you can change its location within the window easily.

   You can see the training data samples used to develop this bot at <https://github.com/Viir/bots/tree/8b955f4035a9a202ba8450f12f4c38be8a2b8d7e/implement/applications/elvenar/training-data>
   If the bot does not recognize all coins with your setup, post it on GitHub issues at <https://github.com/Viir/bots/issues> or on the forum at <https://forum.botlab.org>
-}
{-
   catalog-tags:elvenar
   authors-forum-usernames:viir
-}


module Bot exposing
    ( ImagePattern
    , State
    , botMain
    , coinPattern
    , describeLocation
    , filterRemoveCloseLocations
    )

import BotLab.BotInterface_To_Host_20210823 as InterfaceToHost
import BotLab.SimpleBotFramework as SimpleBotFramework
import Common.AppSettings as AppSettings
import Common.EffectOnWindow
import DecodeBMPImage
import Dict
import Random
import Random.List


mouseClickLocationOffsetFromCoin : Location2d
mouseClickLocationOffsetFromCoin =
    { x = 0, y = 50 }


readFromWindowIntervalMilliseconds : Int
readFromWindowIntervalMilliseconds =
    4000


type alias SimpleState =
    { timeInMilliseconds : Int
    , lastReadFromWindowResult : Maybe ReadFromWindowResult
    }


type alias ReadFromWindowResult =
    { timeInMilliseconds : Int
    , readResult : SimpleBotFramework.ReadFromWindowResultStruct
    , image : SimpleBotFramework.ImageStructure
    , coinFoundLocations : List Location2d
    , missingOriginalPixelsCrops : List Rect
    }


type alias State =
    SimpleBotFramework.State BotSettings SimpleState


type alias BotSettings =
    {}


type alias PixelValue =
    SimpleBotFramework.PixelValue


type alias ImagePattern =
    Dict.Dict ( Int, Int ) DecodeBMPImage.PixelValue -> ( Int, Int ) -> Bool


botMain : InterfaceToHost.BotConfig State
botMain =
    SimpleBotFramework.composeSimpleBotMain
        { parseBotSettings = AppSettings.parseAllowOnlyEmpty {}
        , init = initState
        , processEvent = simpleProcessEvent
        }


initState : SimpleState
initState =
    { timeInMilliseconds = 0
    , lastReadFromWindowResult = Nothing
    }


simpleProcessEvent : BotSettings -> SimpleBotFramework.BotEvent -> SimpleState -> ( SimpleState, SimpleBotFramework.BotResponse )
simpleProcessEvent _ event stateBeforeUpdateTime =
    let
        stateBefore =
            { stateBeforeUpdateTime | timeInMilliseconds = event.timeInMilliseconds }

        activityContinueWaiting =
            ( [], "Wait before starting next reading..." )

        continueWaitingOrRead stateToContinueWaitingOrRead =
            let
                timeToTakeNewReadingFromGameWindow =
                    case stateToContinueWaitingOrRead.lastReadFromWindowResult of
                        Nothing ->
                            True

                        Just lastReadFromWindowResult ->
                            readFromWindowIntervalMilliseconds
                                < (stateToContinueWaitingOrRead.timeInMilliseconds - lastReadFromWindowResult.timeInMilliseconds)

                activityContinueWaitingOrRead =
                    if timeToTakeNewReadingFromGameWindow then
                        ( [ { taskId = SimpleBotFramework.taskIdFromString "read-from-window"
                            , task =
                                SimpleBotFramework.readFromWindow
                                    { crops_1x1_r8g8b8 = []
                                    , crops_2x2_r8g8b8 = [ { x = 0, y = 0, width = 9999, height = 9999 } ]
                                    }
                            }
                          ]
                        , "Get the next reading from the game"
                        )

                    else
                        activityContinueWaiting
            in
            ( stateToContinueWaitingOrRead, activityContinueWaitingOrRead )

        ( state, ( startTasks, activityDescription ) ) =
            case event.eventAtTime of
                SimpleBotFramework.TimeArrivedEvent ->
                    continueWaitingOrRead stateBefore

                SimpleBotFramework.SessionDurationPlannedEvent _ ->
                    continueWaitingOrRead stateBefore

                SimpleBotFramework.TaskCompletedEvent completedTask ->
                    case completedTask.taskResult of
                        SimpleBotFramework.NoResultValue ->
                            continueWaitingOrRead stateBefore

                        SimpleBotFramework.ReadFromWindowResult readFromWindowResult image ->
                            let
                                lastReadFromWindowResult =
                                    computeReadFromWindowResult readFromWindowResult image stateBefore

                                reachableCoinLocations =
                                    lastReadFromWindowResult.coinFoundLocations
                                        |> List.filter
                                            (\location ->
                                                location.y
                                                    < readFromWindowResult.windowClientRectOffset.y
                                                    + readFromWindowResult.windowClientAreaSize.y
                                                    - mouseClickLocationOffsetFromCoin.y
                                                    - 20
                                            )

                                activityFromReadResult =
                                    if
                                        (lastReadFromWindowResult.missingOriginalPixelsCrops /= [])
                                            && Dict.isEmpty lastReadFromWindowResult.image.imageAsDict
                                    then
                                        ( [ { taskId = SimpleBotFramework.taskIdFromString "get-image-data-from-reading"
                                            , task =
                                                SimpleBotFramework.getImageDataFromReading
                                                    { crops_1x1_r8g8b8 = lastReadFromWindowResult.missingOriginalPixelsCrops
                                                    , crops_2x2_r8g8b8 = []
                                                    }
                                            }
                                          ]
                                        , "Get details from last reading"
                                        )

                                    else
                                        case
                                            Random.initialSeed stateBefore.timeInMilliseconds
                                                |> Random.step (Random.List.shuffle reachableCoinLocations)
                                                |> Tuple.first
                                        of
                                            [] ->
                                                activityContinueWaiting
                                                    |> Tuple.mapSecond ((++) "Did not find any coin with reachable interactive area to click on. ")

                                            coinFoundLocation :: _ ->
                                                let
                                                    mouseDownLocation =
                                                        coinFoundLocation
                                                            |> addOffset mouseClickLocationOffsetFromCoin
                                                in
                                                ( [ { taskId =
                                                        SimpleBotFramework.taskIdFromString "collect-coin-input-sequence"
                                                    , task =
                                                        Common.EffectOnWindow.effectsForMouseDragAndDrop
                                                            { startPosition = mouseDownLocation
                                                            , mouseButton = Common.EffectOnWindow.LeftMouseButton
                                                            , waypointsPositionsInBetween =
                                                                [ mouseDownLocation |> addOffset { x = 15, y = 30 } ]
                                                            , endPosition = mouseDownLocation
                                                            }
                                                            |> SimpleBotFramework.effectSequenceTask
                                                                { delayBetweenEffectsMilliseconds = 100 }
                                                    }
                                                  ]
                                                , "Collect coin at " ++ describeLocation coinFoundLocation
                                                )
                            in
                            ( { stateBefore
                                | lastReadFromWindowResult = Just lastReadFromWindowResult
                              }
                            , activityFromReadResult
                            )

        notifyWhenArrivedAtTime =
            { timeInMilliseconds = state.timeInMilliseconds + 1000 }

        statusDescriptionText =
            [ activityDescription
            , lastReadingDescription state
            ]
                |> String.join "\n"
    in
    ( state
    , SimpleBotFramework.ContinueSession
        { startTasks = startTasks
        , statusText = statusDescriptionText
        , notifyWhenArrivedAtTime = Just notifyWhenArrivedAtTime
        }
    )


computeReadFromWindowResult :
    SimpleBotFramework.ReadFromWindowResultStruct
    -> SimpleBotFramework.ImageStructure
    -> SimpleState
    -> ReadFromWindowResult
computeReadFromWindowResult readFromWindowResult image stateBefore =
    let
        coinFoundLocations =
            SimpleBotFramework.locatePatternInImage
                coinPattern
                SimpleBotFramework.SearchEverywhere
                image
                |> filterRemoveCloseLocations 3

        binnedSearchLocations =
            image.imageBinned2x2AsDict
                |> Dict.keys
                |> List.map (\( x, y ) -> { x = x, y = y })

        matchLocationsOnBinned2x2 =
            image.imageBinned2x2AsDict
                |> SimpleBotFramework.getMatchesLocationsFromImage
                    coinPatternTestOnBinned2x2
                    binnedSearchLocations

        missingOriginalPixelsCrops =
            matchLocationsOnBinned2x2
                |> List.map (\binnedLocation -> ( binnedLocation.x * 2, binnedLocation.y * 2 ))
                |> List.filter (\location -> not (Dict.member location image.imageAsDict))
                |> List.map
                    (\( x, y ) ->
                        { x = x - 20
                        , y = y - 15
                        , width = 40
                        , height = 30
                        }
                    )
                |> List.filter (\rect -> 0 < rect.width && 0 < rect.height)
    in
    { timeInMilliseconds = stateBefore.timeInMilliseconds
    , readResult = readFromWindowResult
    , image = image
    , coinFoundLocations = coinFoundLocations
    , missingOriginalPixelsCrops = missingOriginalPixelsCrops
    }


lastReadingDescription : SimpleState -> String
lastReadingDescription stateBefore =
    case stateBefore.lastReadFromWindowResult of
        Nothing ->
            "Taking the first reading from the window..."

        Just lastReadFromWindowResult ->
            let
                coinFoundLocationsToDescribe =
                    lastReadFromWindowResult.coinFoundLocations
                        |> List.take 10

                coinFoundLocationsDescription =
                    "I found the coin in "
                        ++ (lastReadFromWindowResult.coinFoundLocations |> List.length |> String.fromInt)
                        ++ " locations:\n[ "
                        ++ (coinFoundLocationsToDescribe |> List.map describeLocation |> String.join ", ")
                        ++ " ]"

                imageBinned2x2AsDictLocations =
                    lastReadFromWindowResult.image.imageBinned2x2AsDict
                        |> Dict.keys

                observedRectLeft =
                    imageBinned2x2AsDictLocations |> List.map Tuple.first |> List.minimum

                observedRectRight =
                    imageBinned2x2AsDictLocations |> List.map Tuple.first |> List.maximum

                observedRectTop =
                    imageBinned2x2AsDictLocations |> List.map Tuple.second |> List.minimum

                observedRectBottom =
                    imageBinned2x2AsDictLocations |> List.map Tuple.second |> List.maximum

                windowProperties =
                    [ ( "window.width", String.fromInt lastReadFromWindowResult.readResult.windowSize.x )
                    , ( "window.height", String.fromInt lastReadFromWindowResult.readResult.windowSize.y )
                    , ( "windowClientArea.width", String.fromInt lastReadFromWindowResult.readResult.windowClientAreaSize.x )
                    , ( "windowClientArea.height", String.fromInt lastReadFromWindowResult.readResult.windowClientAreaSize.y )
                    , ( "observed"
                      , [ observedRectLeft, observedRectTop, observedRectRight, observedRectBottom ]
                            |> List.map (Maybe.map ((*) 2 >> String.fromInt) >> Maybe.withDefault "NA")
                            |> String.join ", "
                      )
                    ]
                        |> List.map (\( property, value ) -> property ++ " = " ++ value)
                        |> String.join ", "
            in
            [ "Last reading from window: " ++ windowProperties
            , "Pixels: "
                ++ ([ ( "binned 2x2", lastReadFromWindowResult.image.imageBinned2x2AsDict |> Dict.size )
                    , ( "original", lastReadFromWindowResult.image.imageAsDict |> Dict.size )
                    ]
                        |> List.map (\( name, value ) -> String.fromInt value ++ " " ++ name)
                        |> String.join ", "
                   )
                ++ "."
            , coinFoundLocationsDescription
            ]
                |> String.join "\n"


coinPattern : SimpleBotFramework.LocatePatternInImageApproach
coinPattern =
    SimpleBotFramework.TestPerPixelWithBroadPhase2x2
        { testOnBinned2x2 = coinPatternTestOnBinned2x2
        , testOnOriginalResolution =
            \getPixelColor ->
                case getPixelColor { x = 0, y = 0 } of
                    Nothing ->
                        False

                    Just centerColor ->
                        if
                            not
                                ((centerColor.red > 240)
                                    && (centerColor.green < 240 && centerColor.green > 210)
                                    && (centerColor.blue < 200 && centerColor.blue > 120)
                                )
                        then
                            False

                        else
                            case ( getPixelColor { x = 9, y = 0 }, getPixelColor { x = 2, y = -8 } ) of
                                ( Just rightColor, Just upperColor ) ->
                                    (rightColor.red > 70 && rightColor.red < 120)
                                        && (rightColor.green > 30 && rightColor.green < 80)
                                        && (rightColor.blue > 5 && rightColor.blue < 50)
                                        && (upperColor.red > 100 && upperColor.red < 180)
                                        && (upperColor.green > 70 && upperColor.green < 180)
                                        && (upperColor.blue > 60 && upperColor.blue < 100)

                                _ ->
                                    False
        }


coinPatternTestOnBinned2x2 : ({ x : Int, y : Int } -> Maybe PixelValue) -> Bool
coinPatternTestOnBinned2x2 getPixelColor =
    case getPixelColor { x = 0, y = 0 } of
        Nothing ->
            False

        Just centerColor ->
            (centerColor.red > 240)
                && (centerColor.green < 230 && centerColor.green > 190)
                && (centerColor.blue < 150 && centerColor.blue > 80)


filterRemoveCloseLocations : Int -> List { x : Int, y : Int } -> List { x : Int, y : Int }
filterRemoveCloseLocations distanceMin locations =
    let
        locationsTooClose l0 l1 =
            ((l0.x - l1.x) * (l0.x - l1.x) + (l0.y - l1.y) * (l0.y - l1.y)) < distanceMin * distanceMin
    in
    locations
        |> List.foldl
            (\nextLocation aggregate ->
                if List.any (locationsTooClose nextLocation) aggregate then
                    aggregate

                else
                    nextLocation :: aggregate
            )
            []


describeLocation : Location2d -> String
describeLocation { x, y } =
    "{ x = " ++ (x |> String.fromInt) ++ ", y = " ++ (y |> String.fromInt) ++ " }"


type alias Location2d =
    SimpleBotFramework.Location2d


type alias Rect =
    { x : Int
    , y : Int
    , width : Int
    , height : Int
    }


addOffset : Location2d -> Location2d -> Location2d
addOffset a b =
    { x = a.x + b.x, y = a.y + b.y }
