module Component.Post
    exposing
        ( Model
        , Msg(..)
        , Mode(..)
        , decoder
        , init
        , setup
        , teardown
        , update
        , view
        , handleReplyCreated
        )

import Date exposing (Date)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode exposing (Decoder, field, string)
import Task exposing (Task)
import Autosize
import Avatar exposing (personAvatar)
import Connection exposing (Connection)
import Data.Reply exposing (Reply)
import Data.ReplyComposer exposing (ReplyComposer, Mode(..))
import Data.Post exposing (Post)
import Data.SpaceUser exposing (SpaceUser)
import Icons
import Keys exposing (Modifier(..), preventDefault, onKeydown, enter, esc)
import Mutation.ReplyToPost as ReplyToPost
import Route
import Session exposing (Session)
import Subscription.PostSubscription as PostSubscription
import ViewHelpers exposing (setFocus, unsetFocus, displayName, smartFormatDate, injectHtml, viewIf, viewUnless)


-- MODEL


type alias Model =
    { id : String
    , mode : Mode
    , post : Post
    , replyComposer : ReplyComposer
    }


type Mode
    = Feed
    | FullPage



-- LIFECYCLE


decoder : Mode -> Decoder Model
decoder mode =
    Data.Post.decoder
        |> Decode.andThen (Decode.succeed << init mode)


init : Mode -> Post -> Model
init mode post =
    let
        replyMode =
            case mode of
                Feed ->
                    Autocollapse

                FullPage ->
                    AlwaysExpanded
    in
        Model post.id mode post (Data.ReplyComposer.init replyMode)


setup : Model -> Cmd Msg
setup model =
    Cmd.batch
        [ setupSockets model.id
        , Autosize.init (replyComposerId model.id)
        ]


teardown : Model -> Cmd Msg
teardown model =
    teardownSockets model.id


setupSockets : String -> Cmd Msg
setupSockets postId =
    PostSubscription.subscribe postId


teardownSockets : String -> Cmd Msg
teardownSockets postId =
    PostSubscription.unsubscribe postId



-- UPDATE


type Msg
    = ExpandReplyComposer
    | NewReplyBodyChanged String
    | NewReplyBlurred
    | NewReplySubmit
    | NewReplyEscaped
    | NewReplySubmitted (Result Session.Error ( Session, ReplyToPost.Response ))
    | NoOp


update : Msg -> String -> Session -> Model -> ( ( Model, Cmd Msg ), Session )
update msg spaceId session ({ post, replyComposer } as model) =
    case msg of
        ExpandReplyComposer ->
            let
                nodeId =
                    replyComposerId model.id

                cmd =
                    Cmd.batch
                        [ setFocus nodeId NoOp
                        , Autosize.init nodeId
                        ]

                newModel =
                    { model | replyComposer = Data.ReplyComposer.expand replyComposer }
            in
                ( ( newModel, cmd ), session )

        NewReplyBodyChanged val ->
            let
                newModel =
                    { model | replyComposer = Data.ReplyComposer.setBody val replyComposer }
            in
                noCmd session newModel

        NewReplySubmit ->
            let
                newModel =
                    { model | replyComposer = Data.ReplyComposer.submitting replyComposer }

                cmd =
                    Data.ReplyComposer.getBody replyComposer
                        |> ReplyToPost.Params spaceId post.id
                        |> ReplyToPost.request
                        |> Session.request session
                        |> Task.attempt NewReplySubmitted
            in
                ( ( newModel, cmd ), session )

        NewReplySubmitted (Ok ( session, reply )) ->
            let
                nodeId =
                    replyComposerId post.id

                newReplyComposer =
                    replyComposer
                        |> Data.ReplyComposer.notSubmitting
                        |> Data.ReplyComposer.setBody ""

                newModel =
                    { model | replyComposer = newReplyComposer }
            in
                ( ( newModel, setFocus nodeId NoOp ), session )

        NewReplySubmitted (Err Session.Expired) ->
            redirectToLogin session model

        NewReplySubmitted (Err _) ->
            noCmd session model

        NewReplyEscaped ->
            let
                nodeId =
                    replyComposerId model.id

                replyBody =
                    Data.ReplyComposer.getBody replyComposer
            in
                if replyBody == "" then
                    ( ( model, unsetFocus nodeId NoOp ), session )
                else
                    noCmd session model

        NewReplyBlurred ->
            let
                nodeId =
                    replyComposerId model.id

                replyBody =
                    Data.ReplyComposer.getBody replyComposer

                newModel =
                    { model | replyComposer = Data.ReplyComposer.blurred replyComposer }
            in
                noCmd session newModel

        NoOp ->
            noCmd session model


noCmd : Session -> Model -> ( ( Model, Cmd Msg ), Session )
noCmd session model =
    ( ( model, Cmd.none ), session )


redirectToLogin : Session -> Model -> ( ( Model, Cmd Msg ), Session )
redirectToLogin session model =
    ( ( model, Route.toLogin ), session )



-- EVENT HANDLERS


handleReplyCreated : Reply -> Model -> Model
handleReplyCreated reply ({ post } as model) =
    if reply.postId == post.id then
        { model | post = Data.Post.appendReply reply post }
    else
        model



-- VIEW


view : SpaceUser -> Date -> Model -> Html Msg
view currentUser now ({ post } as model) =
    div [ class "flex p-4" ]
        [ div [ class "flex-no-shrink mr-4" ] [ personAvatar Avatar.Medium post.author ]
        , div [ class "flex-grow leading-semi-loose" ]
            [ div [ class "pb-2" ]
                [ div []
                    [ span [ class "font-bold" ] [ text <| displayName post.author ]
                    , span [ class "ml-3 text-sm text-dusty-blue" ] [ text <| smartFormatDate now post.postedAt ]
                    ]
                , div [ class "markdown mb-2" ] [ injectHtml post.bodyHtml ]
                , viewIf (model.mode == Feed) <|
                    div [ class "flex items-center" ]
                        [ div [ class "flex-grow" ]
                            [ button [ class "inline-block mr-4", onClick ExpandReplyComposer ] [ Icons.comment ]
                            ]
                        ]
                ]
            , div [ class "relative" ]
                [ repliesView post now model.mode post.replies
                , replyComposerView currentUser model
                ]
            ]
        ]


repliesView : Post -> Date -> Mode -> Connection Reply -> Html Msg
repliesView post now mode replies =
    let
        { nodes, hasPreviousPage } =
            Connection.last 5 replies
    in
        viewUnless (Connection.isEmptyAndExpanded replies) <|
            div []
                [ viewIf (hasPreviousPage && mode == Feed) <|
                    a [ Route.href (Route.Post post.id), class "mb-2 text-dusty-blue no-underline" ] [ text "Show more..." ]
                , div [] (List.map (replyView now) nodes)
                ]


replyView : Date -> Reply -> Html Msg
replyView now reply =
    div [ class "flex my-3" ]
        [ div [ class "flex-no-shrink mr-3" ] [ personAvatar Avatar.Small reply.author ]
        , div [ class "flex-grow leading-semi-loose" ]
            [ div []
                [ span [ class "font-bold" ] [ text <| displayName reply.author ]
                ]
            , div [ class "markdown mb-2" ] [ injectHtml reply.bodyHtml ]
            ]
        ]


replyComposerView : SpaceUser -> Model -> Html Msg
replyComposerView currentUser { post, replyComposer } =
    if Data.ReplyComposer.isExpanded replyComposer then
        div [ class "-ml-3 py-3 sticky pin-b bg-white" ]
            [ div [ class "composer p-3" ]
                [ div [ class "flex" ]
                    [ div [ class "flex-no-shrink mr-2" ] [ personAvatar Avatar.Small currentUser ]
                    , div [ class "flex-grow" ]
                        [ textarea
                            [ id (replyComposerId post.id)
                            , class "p-1 w-full h-10 no-outline bg-transparent text-dusty-blue-darkest resize-none leading-normal"
                            , placeholder "Write a reply..."
                            , onInput NewReplyBodyChanged
                            , onKeydown preventDefault
                                [ ( [ Meta ], enter, \event -> NewReplySubmit )
                                , ( [], esc, \event -> NewReplyEscaped )
                                ]
                            , onBlur NewReplyBlurred
                            , value (Data.ReplyComposer.getBody replyComposer)
                            , readonly (Data.ReplyComposer.isSubmitting replyComposer)
                            ]
                            []
                        , div [ class "flex justify-end" ]
                            [ button
                                [ class "btn btn-blue btn-sm"
                                , onClick NewReplySubmit
                                , disabled (Data.ReplyComposer.unsubmittable replyComposer)
                                ]
                                [ text "Post reply" ]
                            ]
                        ]
                    ]
                ]
            ]
    else
        viewUnless (Connection.isEmpty post.replies) <|
            replyPromptView currentUser


replyPromptView : SpaceUser -> Html Msg
replyPromptView currentUser =
    button [ class "flex my-3 items-center", onClick ExpandReplyComposer ]
        [ div [ class "flex-no-shrink mr-3" ] [ personAvatar Avatar.Small currentUser ]
        , div [ class "flex-grow leading-semi-loose text-dusty-blue" ]
            [ text "Write a reply..."
            ]
        ]



-- UTILS


replyComposerId : String -> String
replyComposerId postId =
    "reply-composer-" ++ postId
