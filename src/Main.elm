module Main exposing (..)

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

-- MODEL

type alias Date =
  { year : Int
  , month : Int
  , day : Int
  }

-- type alias RoughInterval =
--   (Int, Int) -- e.g. roughly every 5-8 days/minutes/etc

-- type Pause
--   = Indefinitely { since : Date }
--   | Approximately RoughInterval -- measured in days

-- type TimeExpenditure
--   -- just unknown
--   = Undefined
--   | About RoughInterval -- measured in minutes/hours depending on suffix

-- type DeadlineTypes
--   -- this is the deadline by which the thing MUST be done.  Usually set by other people…
--   = HardDeadline Date
--   -- now, this is a "deadline" by which I kind of want to have it done, and there's a hard deadline too by which it MUST be done
--   | SoftDeadline Date Date
--   -- I want to have done some of this done just to keep some form of forward-progress, but when it's actually done is unknown.  Maybe never?
--   | ForwardProgress 

-- type Status
--   = Active
--   | Completed Posix
--   | Paused { previously : Status, now : Status }
--   | BallPlayed { checkAfter : RoughInterval } -- in days

-- type alias Todo =
--   { created : Date
--   , text : String
--   , status : Status
--   , spawnContext : Maybe String -- can be an event, a person, a todo
--   }

-- type CoreDatum
--   = Start

-- type alias CoreDatumModel =
--   {
--   }

-- AwesomeBar start
type Token
  = Today
  | Tomorrow
  | Description
  -- | AcceptLiterally
  -- | Cursor
  -- | AfterDays Int
  -- | AfterWeeks Int
type alias Offset =
  { offset : Int
  , extent : Int
  }

type alias AwesomeBarState =
  { s : String
  , i : Int -- caret position
  , tokenised : List Offset
  , parse : List (Token, Maybe String, Offset)
  }
-- AwesomeBar end

type Mode
  = Waiting
  | AwesomeBar AwesomeBarState

type ABSpecialKey
  = Escape
  | Tab
  | Enter
  | ArrowDown
  | ArrowUp

type ABMsg
  = SetString String Int
  | ListenerRemoved
  | Key ABSpecialKey
  | CaretMoved Int

type Msg
  = NoOp
  | SwitchMode Mode
  | AB ABMsg
  | Tick Time.Posix
  | GetZone Time.Zone

type alias Todo =
  { s : String
  , created : Date
  }

type alias Model =
  { key : Navigation.Key
  , mode : Mode
  , nowish : Time.Posix
  , zone : Time.Zone
  , data : List Todo
  }

toMonth : Time.Zone -> Time.Posix -> Int
toMonth zone time =
  case Time.toMonth zone time of
    Time.Jan -> 1
    Time.Feb -> 2
    Time.Mar -> 3
    Time.Apr -> 4
    Time.May -> 5
    Time.Jun -> 6
    Time.Jul -> 7
    Time.Aug -> 8
    Time.Sep -> 9
    Time.Oct -> 10
    Time.Nov -> 11
    Time.Dec -> 12

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
        findFirst [ isToday, isTomorrow ] strings
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

-- type alias ParserState =
--   { offsetCount : Int
--   , currentParse : List Token
--   }

-- startingParserState : ParserState
-- startingParserState =
--   { offsetCount = 0
--   , currentParse = []
--   }

-- -- parseIntoTokens : (Int, List String) -> ParserState -> List Token
-- -- parseIntoTokens (caret, list) state =
-- --   {- the cursor might be anywhere in the list, including right at the start or
-- --      right at the end.  In the parser state, I track the `offsetCount`, which is
-- --      the number of characters that I've encountered thus far.

-- --      If the offsetCount is
-- --   -}
-- --   case list of
-- --     [] ->
-- --       state.currentParse
-- --     ""::restOfList ->
-- --       {- The only way I'll see an empty string is if I have two consecutive spaces.
-- --          So if I have a whitespace as my most recent parse, extend it; otherwise,
-- --          put in a whitespace token with 2 consecutive spaces.
-- --       -}
-- --       case state.currentParse of
-- --         Whitespace n::restOfParse ->
-- --           parseIntoTokens caret restOfList
-- --             { state
-- --             | currentParse = Whitespace (n + 1)::restOfParse
-- --             , offsetCount = state.offsetCount + 1
-- --             }
-- --         other ->
-- --           parseIntoTokens caret restOfList
-- --             { state
-- --             | currentParse = Whitespace 2::other
-- --             , offsetCount = state.offsetCount + 2
-- --             }
-- --     _ ->
-- --       {- Chances are that this is a normal word (or phrase), but it may be keyword(s)
-- --          with some special meaning.  So, let's see what we can find, longest
-- --          chain-of-meaning being prioritised over a smaller one, and taking the
-- --          current parse into account.
-- --       -}
-- --       if 
-- --     [] ->
-- --       state.currentParse

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
      let
        tokens = tokenise s 0 Nothing []
      in
        AwesomeBar
          { x
          | s = s
          , i = i
          , tokenised = tokens
          , parse = parse tokens s []
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
                  , created =
                    { year = Time.toYear model.zone model.nowish
                    , month = toMonth model.zone model.nowish
                    , day = Time.toDay model.zone model.nowish
                    }
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
classFor : Token -> String
classFor token =
  case token of
    Today -> "when"
    Tomorrow -> "when"
    Description -> ""

tokenWithoutCompletion : String -> Token -> String -> Html Msg
tokenWithoutCompletion s token txt =
  span
    [ classList
        [ ("token-viz", token /= Description)
        , (classFor token, token /= Description)
        ]
    ]
    [ text txt ]

tokenWithCompletion : String -> Token -> String -> String -> Html Msg
tokenWithCompletion s token completion txt =
  span
    [ classList
        [ ("token-viz", token /= Description)
        , (classFor token, token /= Description)
        ]
    , Html.Attributes.attribute "data-completionlen" (String.fromInt <| String.length completion)
    ]
    [ text txt
    , span
        [ class "completion"
        , contenteditable False
        , Html.Attributes.attribute "inert" "true"
        , Html.Attributes.attribute "data-completion" completion
        ]
        [ text completion ]
    ]
  
isWithinOffset : Int -> Int -> Int -> Bool
isWithinOffset offset extent caretPosition =
  offset <= caretPosition && offset + extent >= caretPosition

tokenToView : String -> Int -> (Token, Maybe String, Offset) -> Html Msg
tokenToView s caretPosition (token, completion, {offset, extent}) =
  let
    txt = String.slice offset (offset+extent) s
  in
    case (completion, caretPosition |> isWithinOffset offset extent) of
      (Nothing, _) ->
        tokenWithoutCompletion s token txt
      (_, False) ->
        tokenWithoutCompletion s token txt
      (Just completion_, True) ->
        tokenWithCompletion s token completion_ txt

viewTodoList : Model -> Html Msg
viewTodoList model =
  ol
    []    
    ( List.map
      (\{ s, created } ->
        li
          [ class "todo" ]
          [ span
              [ class "todo-text" ]
              [ text s ]
          , span
              [ class "todo-created" ]
              [ text <| "Created " ++ String.fromInt created.year ++ "-" ++ String.fromInt created.month ++ "-" ++ String.fromInt created.day ]
          ]
      )
      model.data
    )

viewAwesomeBar : Model -> AwesomeBarState -> Html Msg
viewAwesomeBar model state =
  div
    []
    [ Keyed.node "div"
        [ id "awesomebar-container"
        ]
        [ ("title", div
          [ id "awesomebar-title" ]
          [ text "Task" ])
        -- this next bit is keyed to a constant just to stop Elm from recreating the element.
        -- If Elm DOES recreate the element, the events associated with it externally… disappear!
        , ("bar", div
            [ contenteditable True
            , id "awesomebar"
            ]
            ( let
                last = List.drop (List.length state.parse - 1) state.parse |> List.head
                first = List.head state.parse
                prefix =
                  Maybe.map (\(_, _, { offset }) ->
                    text <| String.repeat offset " "
                  ) first
                suffix =
                  Maybe.map (\(_, _, { offset, extent }) ->
                    text <| String.repeat (String.length state.s - (offset + extent)) " "
                  ) last
                tokenHtml =
                  List.map (tokenToView state.s state.i) state.parse
              in
                case (prefix, suffix) of
                  (Nothing, Nothing) ->
                    tokenHtml
                  (Just prefixHtml, Nothing) ->
                    prefixHtml :: tokenHtml
                  (Nothing, Just suffixHtml) ->
                    tokenHtml ++ [suffixHtml]
                  (Just prefixHtml, Just suffixHtml) ->
                    (prefixHtml :: tokenHtml) ++ [suffixHtml]
            )
          )
        ]
    ]

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
    -- "insertLineBreak" ->
    --   Disallow
    -- "insertParagraph" ->
    --   Disallow
    -- "insertOrderedList" ->
    --   Disallow
    -- "insertUnorderedList" ->
    --   Disallow
    -- "insertHorizontalRule" ->
    --   Disallow
    -- "insertFromYank" ->
    --   Disallow
    -- "insertFromDrop" ->
    --   Disallow
    -- "insertFromPasteAsQuotation" ->
    --   Disallow
    -- "insertTranspose" ->
    --   Disallow
    -- "insertLink" ->
    --   Disallow
    -- "deleteWordBackward" ->
    --   Disallow
    -- "deleteWordForward" ->
    --   Disallow
    -- "deleteSoftLineBackward" ->
    --   Disallow
    -- "deleteSoftLineForward" ->
    --   Disallow
    -- "deleteEntireSoftLine" ->
    --   Disallow
    -- "deleteHardLineBackward" ->
    --   Disallow
    -- "deleteHardLineForward" ->
    --   Disallow
    -- "deleteByDrag" ->
    --   Disallow
    -- "historyUndo" ->
    --   Disallow
    -- "historyRedo" ->
    --   Disallow
    -- "formatBold" ->
    --   Disallow
    -- "formatItalic" ->
    --   Disallow
    -- "formatUnderline" ->
    --   Disallow
    -- "formatStrikeThrough" ->
    --   Disallow
    -- "formatSuperscript" ->
    --   Disallow
    -- "formatSubscript" ->
    --   Disallow
    -- "formatJustifyFull" ->
    --   Disallow
    -- "formatJustifyCenter" ->
    --   Disallow
    -- "formatJustifyRight" ->
    --   Disallow
    -- "formatJustifyLeft" ->
    --   Disallow
    -- "formatIndent" ->
    --   Disallow
    -- "formatOutdent" ->
    --   Disallow
    -- "formatRemove" ->
    --   Disallow
    -- "formatSetBlockTextDirection" ->
    --   Disallow
    -- "formatSetInlineTextDirection" ->
    --   Disallow
    -- "formatBackColor" ->
    --   Disallow
    -- "formatFontColor" ->
    --   Disallow
    -- "formatFontName" ->
    --   Disallow
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
              if key == " " then SwitchMode (AwesomeBar { s = "", i = 0, parse = [], tokenised = [] })
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
