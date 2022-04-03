-module(gleam_cowboy_websockets_native).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, start_link/2, read_entire_body/1, make_handlers/4]).

start_link(Handler, Port) ->
    RanchOptions = #{
        max_connections => 16384,
        num_acceptors => 100,
        socket_opts => [{port, Port}]
    },
    CowboyOptions = #{
        env => #{dispatch => [{'_', [], [{'_', [], ?MODULE, Handler}]}]},
        stream_handlers => [cowboy_stream_h]
    },
    ranch_listener_sup:start_link(
        {gleam_cowboy, make_ref()},
        ranch_tcp, RanchOptions,
        cowboy_clear, CowboyOptions
    ).

make_handlers(Handler, OnWSInit, OnWSFrame, OnInfo) ->
  #{handler => Handler, on_ws_init => OnWSInit, on_ws_frame => OnWSFrame, on_info => OnInfo}.

% Callback used by websocket.gleam
% Allows for both normal request/response as well as upgrades to a persistant
% websocket connection
init(Req, #{handler := Handler} = Handlers) when is_map(Handlers) ->
  Res = Handler(Req),
    case Res of
        {upgrade, State} -> {cowboy_websocket, Req, Handlers#{state => State}, #{max_frame_size => 8000000, idle_timeout => 30000}};
        Res -> {ok, Res, Req}
    end;

% Normal Callback used by cowboy.gleam
init(Req, Handler) ->
    logger:info(#{ message => "Got here", handler => Handler }),
    {ok, Handler(Req), Req}.

handle_response(Response, Handlers) ->
  case Response of
      {ignore, State} -> {ok, Handlers#{state := State}, hibernate};
      % ping and pong only have one thing in the tuple
      {respond, {X}, State} -> {reply, X, Handlers#{state => State}, hibernate};
      {respond, Frame, State} -> {reply, Frame, Handlers#{state => State}, hibernate};
      {multi_respond, Frames, State} -> {reply, Frames, Handlers#{state => State}, hibernate}
  end.

% https://ninenines.eu/docs/en/cowboy/2.9/guide/ws_handlers/
websocket_init(#{state := State, on_ws_init := OnWSInit } = Handlers) ->
  handle_response(OnWSInit(State), Handlers).

websocket_handle(Frame, #{state := State, on_ws_frame := OnWSFrame } = Handlers) ->
  handle_response(OnWSFrame(State, Frame), Handlers).

websocket_info(Message, #{state := State, on_info := OnInfo } = Handlers) ->
  handle_response(OnInfo(State, Message), Handlers).

read_entire_body(Req) ->
    read_entire_body([], Req).

read_entire_body(Body, Req0) ->
    case cowboy_req:read_body(Req0) of
        {ok, Chunk, Req1} -> {list_to_binary([Body, Chunk]), Req1};
        {more, Chunk, Req1} -> read_entire_body([Body, Chunk], Req1)
    end.
