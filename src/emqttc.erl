-module(emqttc).

-behaviour(gen_server).

-export([start/3, start/4, stop/1, subscribe/3, publish/4, unsubscribe/2]).
-export([start_link/4, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


-record(state, {mod, client_id, opts, client, topics = [], child_state}).

-type message() :: {deliver,  Message :: map()} | {puback,  Ack :: map()}.

-callback init(ClientId :: binary()) ->
    {ok, State :: any()} | {ok, Topics :: list(), State :: any()} | {error, Reason :: any()}.

-callback handle_msg(Info, State) -> ok | {ok, State} when
    Info :: message(),
    State :: any().

-callback stop(Reason :: any(), ClientId :: binary(), State :: any()) ->
    ok.

subscribe(Pid, Topic, SubOpts) ->
    gen_server:call(Pid, {sub, Topic, SubOpts}).

unsubscribe(Pid, Topic) ->
    gen_server:call(Pid, {unsub, Topic}).

publish(Pid, Topic, Payload, PubOpts) ->
    gen_server:call(Pid, {pub, Topic, Payload, PubOpts}).


start(ClientId, Mod, Opts) ->
    supervisor:start_child(emqttc_sup, [ClientId, Mod, Opts]).

start(Name, ClientId, Mod, Opts) ->
    supervisor:start_child(emqttc_sup, [Name, ClientId, Mod, Opts]).

stop(Pid) ->
    gen_server:call(Pid, stop).


start_link(ClientId, Mod, Opts) ->
    gen_server:start_link(?MODULE, [ClientId, Mod, Opts], []).

start_link(Name, ClientId, Mod, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [ClientId, Mod, Opts], []).


init([ClientId, Mod, Opts]) ->
    process_flag(trap_exit, true),
    State = #state{ mod = Mod, client_id = ClientId, opts = Opts },
    case do_connect(State) of
        {ok, NewState} ->
            {ok, NewState};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, #state{client = ConnPid} = State) ->
    Reply = do_call(disconnect, [ConnPid]),
    {reply, Reply, State};



handle_call({pub, Topic, Payload, PubOpts}, _From, #state{client = Client} = State) ->
    Reply =
        case is_pid(Client) andalso is_process_alive(Client) andalso lists:keyfind(qos, 1, PubOpts) of
            false ->
                {error, disconnected};
            0 ->
                do_call(publish, [Client, Topic, #{}, Payload, PubOpts]);
            _ ->
                case do_call(publish, [Client, Topic, #{}, Payload, PubOpts]) of
                    {ok, _PktId} ->
                        ok;
                    {error, Reason} ->
                        {error, Reason}
                end
        end,
    {reply, Reply, State};

handle_call({unsub, Topic}, _From, #state{client = Client, topics = Topics} = State) ->
    Reply = do_call(unsubscribe, [Client, #{}, Topic]),
    {reply, Reply, State#state{topics = lists:keydelete(Topic, 1, Topics)}};

handle_call({sub, Topic, SubOpts}, _From, #state{client = Client, client_id = ClientId, topics = Topics} = State) ->
    case is_pid(Client) andalso is_process_alive(Client) of
        true ->
            case  lists:keyfind(Topic, 1, Topics) of
                false ->
                    case do_subscribe(Client, ClientId, Topic, SubOpts) of
                        {ok, Properties, ReasonCode} ->
                            NewTopics = [{Topic, SubOpts} | Topics],
                            {reply, {ok, Properties, ReasonCode}, State#state{topics = NewTopics}};
                        {error, Reason} ->
                            {reply, {error, Reason}, State}
                    end;
                _ ->
                    {reply, {error, duplicate}, State}
            end;
        false ->
            {reply, {error, disconnected}, State}
    end;


handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info({publish, Msg}, #state{mod = Mod} = State) ->
    case Mod:handle_msg({deliver,  Msg}, State#state.child_state) of
        ok ->
            {noreply, State};
        {ok, NewChildState} ->
            {noreply, State#state{child_state = NewChildState}}
    end;

handle_info({puback, Ack}, #state{ mod = Mod } = State) ->
    case Mod:handle_msg({puback, Ack}, State#state.child_state) of
        ok ->
            {noreply, State};
        {ok, NewChildState} ->
            {noreply, State#state{child_state = NewChildState}}
    end;

handle_info({'EXIT', Pid, Reason}, #state{client = Pid, client_id = ClientId} = State) ->
    case Reason of
        normal ->
            {stop, normal, State};
        _ ->
            logger:error("MQTT Client ~p stop, Reason:~p~n", [ClientId, Reason]),
            handle_info(reconnect, State)
    end;

handle_info(reconnect, #state{client_id = ClientId, opts = Opts} = State) ->
    case do_connect(State) of
        {ok, NewState} ->
            logger:info("MQTT Client ~p reconnect success, Reason:~p~n", [ClientId]),
            {noreply, NewState};
        {error, Reason} ->
            logger:info("MQTT Client ~p reconnect error, Reason:~p~n", [ClientId, Reason]),
            Time = proplists:get_value(reconnect, Opts, 5000),
            erlang:send_after(Time, self(), reconnect),
            {noreply, State#state{client = undefined}}
    end;

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(Reason, State = #state{ mod = Mod }) ->
    Mod:stop(Reason, State#state.child_state),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.


do_connect(#state{ client_id = ClientId, mod = Mod, opts = Opts } = State) ->
    case mqtt_connect(ClientId, Opts) of
        {ok, _Properties, ConnPid} ->
            case Mod:init(ClientId) of
                {ok, Topics, ChildState} ->
                    do_subscribe(ConnPid, ClientId, Topics),
                    {ok, State#state{
                        topics = Topics,
                        child_state = ChildState,
                        client = ConnPid
                    }};
                {ok, ChildState} ->
                    {ok, State#state{
                        child_state = ChildState,
                        client = ConnPid
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

mqtt_connect(ClientId, Opts) ->
    case emqtt:start_link([{owner, self()},{clientid, binary_to_list(ClientId)} | Opts]) of
        {ok, ConnPid} ->
            case do_call(connect, [ConnPid]) of
                {ok, Properties} ->
                    {ok, Properties, ConnPid};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

do_subscribe(Client, ClientId, Topics) ->
    F =
        fun({Topic, SubOpts}) ->
            case do_subscribe(Client, ClientId, Topic, SubOpts) of
                {error, Reason} ->
                    logger:error("client(~s) sub topic ~p error ~p", [ClientId, Topic, Reason]);
                {ok, _, _} ->
                    ok
            end
        end,
    [F(Element) || Element <- Topics].


do_subscribe(Client, _ClientId, Topic, SubOpts) ->
    case do_call(subscribe, [Client, Topic, SubOpts]) of
        {ok, Properties, ReasonCode} ->
            {ok, Properties, ReasonCode};
        {error, Reason} ->
            {error, Reason}
    end.


do_call(Fun, Args) ->
    case catch apply(emqtt, Fun, Args) of
        {'EXIT', Reason} ->
            {error, Reason};
        Result ->
            Result
    end.

