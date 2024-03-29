module Main exposing (..)

import Data exposing (..)
import Parsers exposing (..)
import View exposing (..)

import Browser
import Html exposing (Html, div, text, span, li, ol)
import Browser.Navigation as Navigation
import Url exposing (Url)
import Time
import Browser.Events
import Json.Decode as D
import Html.Attributes exposing (contenteditable, id, class, classList)
import Platform.Cmd as Cmd
import String.Extra as String
import Ports
import Html.Keyed as Keyed
import Platform.Cmd as Cmd
import Task
import Time.Extra as Time
import Parser

init : () -> Url -> Navigation.Key -> (Model, Cmd Msg)
init _ _ key =
  ( { key = key
  , mode = Waiting
  , nowish = Time.millisToPosix 0
  , zone = Time.utc -- for now, 'cos I'm lazy
  , data = []
  }
  , Cmd.batch
    [ Task.perform GetZone Time.here
    , Task.perform Tick Time.now
    ]
  )

{-
These are all `List String -> Maybe (Token, String, Int)`, where
  - The result is `Nothing` if it doesn't apply
  - The `Token` is the meaning if it does apply
  - The `String` is the completion, if the caret is within or at the end
  - The `Int` is the number of `Offset`s consumed in the case of success
-}


isDuration : List String -> Maybe (Token, Maybe String, Int)
isDuration list =
  List.head list
  |> Maybe.andThen
    (\s ->
      Parser.run shortDurationParser s
      |> Result.map (\(token, completion) -> Just (token, completion, 1))
      |> Result.withDefault Nothing
    )

isToday : List String -> Maybe (Token, Maybe String, Int)
isToday list =
  case List.head list of
    Just "tod" ->
      Just (Today, Just "ay", 1)
    Just "toda" ->
      Just (Today, Just "y", 1)
    Just "today" ->
      Just (Today, Nothing, 1)
    _ -> Nothing

isTomorrow : List String -> Maybe (Token, Maybe String, Int)
isTomorrow list =
  case List.head list of
    Just "tom" ->
      Just (Tomorrow, Just "orrow", 1)
    Just "tomo" ->
      Just (Tomorrow, Just "rrow", 1)
    Just "tomor" ->
      Just (Tomorrow, Just "row", 1)
    Just "tomorr" ->
      Just (Tomorrow, Just "ow", 1)
    Just "tomorro" ->
      Just (Tomorrow, Just "w", 1)
    Just "tomorrow" ->
      Just (Tomorrow, Nothing, 1)
    _ -> Nothing

findFirst : List (a -> Maybe b) -> a -> Maybe b
findFirst list data =
  case list of
    [] ->
      Nothing
    f::tail ->
      case f data of
        Nothing ->
          findFirst tail data
        x ->
          x

smallDurationToMinutes : SmallDuration -> Int
smallDurationToMinutes d =
  case d of
    Minutes m -> m
    Hours h m -> h * 60 + m

findMaxDuration : List (Token, Maybe String, Offset) -> Maybe SmallDuration
findMaxDuration list =
  List.foldl (\item state ->
    case item of
      (Duration d, _, _) ->
        case state of
          Nothing ->
            Just d
          Just d_ ->
            Just (if smallDurationToMinutes d_ > smallDurationToMinutes d then d_ else d)
      _ ->
        state
  ) Nothing list

parse : List Offset -> String -> List (Token, Maybe String, Offset) -> List (Token, Maybe String, Offset)
parse offsets s acc =
  let
    strings : List String
    strings = List.map (\{offset, extent} -> String.slice offset (offset + extent) s) offsets
  in
    case offsets of
      [] ->
        List.reverse acc
      h::tail ->
        findFirst
          [ isToday
          , isTomorrow
          , isDuration
          ]
          strings
        |> Maybe.map (\(token, completion, n) ->
          let
            combinedOffset =
              { offset = h.offset
              , extent =
                  List.drop (n - 1) offsets
                  |> List.head
                  |> Maybe.map (\last -> last.offset + last.extent - h.offset)
                  |> Maybe.withDefault 1
              }
            newAcc =
              (token, completion, combinedOffset) :: acc
          in
            case tail of
              h2::_ ->
                parse (List.drop n offsets) s ((Description, Nothing, { offset = h.offset + h.extent, extent = (h2.offset - (h.offset + h.extent)) }) :: newAcc)
              [] ->
                parse (List.drop n offsets) s newAcc
        ) |> Maybe.withDefault
          ( case tail of
              h2::_ ->
                parse tail s ((Description, Nothing, { h | extent = h2.offset - h.offset }) :: acc)
              [] ->
                parse tail s ((Description, Nothing, h) :: acc)
          )

tokenise : String -> Int -> Maybe Offset -> List Offset -> List Offset
tokenise s i current acc =
  case (String.slice i (i+1) s, current) of
    -- end-of-input cases
    ("", Nothing) ->
      List.reverse acc
    ("", Just c) ->
      List.reverse (c :: acc)
    -- whitespace cases
    (" ", Nothing) ->
      tokenise s (i+1) Nothing acc
    (" ", Just c) ->
      tokenise s (i+1) Nothing (c :: acc)
    (_, Nothing) ->
      tokenise s (i+1) (Just { offset = i, extent = 1 }) acc
    (_, Just c) ->
      tokenise s (i+1) (Just { c | extent = c.extent + 1 }) acc

updateSetString : String -> Int -> AwesomeBarState -> Model -> (Model, Cmd Msg)
updateSetString s i x model =
  ( { model
    | mode =
        AwesomeBar
          { x
          | s = s
          , i = i
          , parse = parse (tokenise s 0 Nothing []) s []
          }
    }
  , Ports.shiftCaret ({-Debug.log "Requesting caret shift to"-} i)
  )

-- UPDATE
update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
  NoOp ->
    (model, Cmd.none)
  Tick time ->
    ({ model | nowish = time }, Cmd.none)
  SwitchMode (AwesomeBar x) ->
    ({ model | mode = AwesomeBar x }, Ports.displayAwesomeBar ())
  SwitchMode Waiting ->
    ({ model | mode = Waiting }, Cmd.none)
  AB abmsg ->
    case model.mode of
      AwesomeBar x ->
        case abmsg of
          ListenerRemoved ->
            ({ model | mode = Waiting }, Cmd.none)
          Key Escape ->
            (model, Ports.hideAwesomeBar ())
          Key Tab ->
            -- Plausibly, this is means "complete the current token".
            x.parse
            |> List.filterMap
                (\(_, completion, {offset, extent} as ofs) ->
                  Maybe.andThen
                    (\completion_ ->
                      if x.i |> isWithinOffset offset extent then
                        Just (completion_, ofs)
                      else
                        Nothing
                    )
                    completion
                )
            |> List.head
            |> Maybe.map
                (\(completion, {offset, extent}) ->
                  let
                    s = String.left (offset + extent) x.s ++ completion ++ String.dropLeft (offset + extent) x.s
                    i = offset + extent + String.length completion
                  in
                    model |> updateSetString s i x
                )
            |> Maybe.withDefault (model, Cmd.none)
          Key Enter ->
            ( { model
              | mode = Waiting
              , data =
                  { s = x.s
                  , created = posixToDate model.zone model.nowish
                  , duration = findMaxDuration x.parse
                  } :: model.data
              }
            , Cmd.none
            )
          Key ArrowDown ->
            (model, Cmd.none)
          Key ArrowUp ->
            (model, Cmd.none)
          CaretMoved i ->
            ( { model
              | mode = AwesomeBar { x | i = i }
              }
            , Cmd.none
            )
          SetString s i ->
            model |> updateSetString s i x
      Waiting ->
        (model, Cmd.none)
  GetZone zone ->
    ( { model | zone = zone }, Cmd.none )

-- VIEW

view : Model -> Browser.Document Msg
view model =
  { title = "Hello, Elm!"
  , body =
    [ div []
      [ text "Hello, Elm!" ]
    , case model.mode of
      Waiting ->
        viewTodoList model
      AwesomeBar state ->
        div
          []
          [ viewAwesomeBar model state
          , viewTodoList model
          , viewCalendar (\d -> d.weekday == Time.Tue || d.weekday == Time.Mon || d.weekday == Time.Sat) (posixToDate model.zone model.nowish) 16
          ]
    ]
  }


-- SUBSCRIPTIONS
type EventInputType
  = InsertText
  | DeleteBackwards
  | DeleteForwards
  | Disallow

classifyInput : String -> String -> EventInputType
classifyInput inputType data =
  case {-Debug.log "inputType"-} inputType of
    "insertText" ->
      InsertText
    "insertReplacementText" ->
      InsertText
    "insertFromPaste" ->
      InsertText
    "deleteByCut" ->
      DeleteBackwards
    "deleteContent" ->
      DeleteBackwards
    "deleteContentBackward" ->
      DeleteBackwards
    "deleteContentForward" ->
      DeleteForwards
    "insertCompositionText" ->
      InsertText
    x -> -- this should never happen.
      Debug.log "Unhandled inputType seen" x
      |> \_ -> Disallow

decodeInput : Model -> D.Decoder Msg
decodeInput model =
  case model.mode of
    Waiting ->
      D.fail "Not in awesomebar mode"
    AwesomeBar state ->
      D.map4
        (\inputType data start end ->
          case classifyInput inputType data of
            Disallow ->
              NoOp
            InsertText ->
              let
                added = {-Debug.log "Chars added" <|-} String.length data
                left = {-Debug.log "Prefix" <|-} String.left start state.s
                right = {-Debug.log "Suffix" <|-} String.dropLeft end state.s
              in
                AB (SetString (left ++ data ++ right) (start + added))
            DeleteBackwards ->
              if start == 0 && end == start then
                NoOp
              else if start == end then
                AB (SetString (String.left (start - 1) state.s ++ String.dropLeft end state.s) (start - 1))
              else
                AB (SetString (String.left start state.s ++ String.dropLeft end state.s) start)
            DeleteForwards ->
              if start == end then
                AB (SetString (String.left start state.s ++ String.dropLeft (end + 1) state.s) start)
              else
                AB (SetString (String.left start state.s ++ String.dropLeft end state.s) start)
        )
        (D.field "inputType" D.string)
        (D.field "data" D.string)
        (D.field "start" D.int)
        (D.field "end" D.int)
  -- D.field 
  -- |> D.map
  --   (\input ->
  --     (AB (SetString input), True)
  --   )

decodeSpecialKey : String -> Msg
decodeSpecialKey key =
  case key of
    "Escape" ->
      AB <| Key Escape
    "Tab" ->
      AB <| Key Tab
    "Enter" ->
      AB <| Key Enter
    _ ->
      NoOp

subscriptions : Model -> Sub Msg
subscriptions model =
  case model.mode of
    Waiting ->
      Sub.batch
        [ Browser.Events.onKeyDown
          ( D.field "key" D.string
          |> D.map
            (\key ->
              if key == " " then SwitchMode (AwesomeBar { s = "", i = 0, parse = [] })
              else NoOp
            )
          )
        , Time.every 60000 Tick
        ]
    AwesomeBar state ->
      Sub.batch
        [ Ports.awesomeBarInput
            (D.decodeValue (decodeInput model) >> Result.withDefault NoOp)
        , Ports.listenerRemoved (\_ -> AB ListenerRemoved)
        , Ports.sendSpecial decodeSpecialKey
        , Ports.caretMoved
            (\input ->
              D.decodeValue (D.field "start" D.int) input
              |> Result.map
                (\i ->
                  if i == state.i then
                    NoOp
                  else
                    (AB <| CaretMoved i)
                )
              |> Result.withDefault NoOp
            )
        , Time.every 60000 Tick
        ]

-- PROGRAM


main : Program () Model Msg
main =
  Browser.application
  { init = init
  , update = update
  , view = view
  , subscriptions = subscriptions
  , onUrlRequest = \_ -> NoOp
  , onUrlChange = \_ -> NoOp
  }
