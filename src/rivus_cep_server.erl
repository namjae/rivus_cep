%%------------------------------------------------------------------------------
%% Copyright (c) 2014 Vasil Kolarov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%------------------------------------------------------------------------------
-module(rivus_cep_server).
-behaviour(gen_fsm).
-compile([{parse_transform, lager_transform}]).
-include_lib("eunit/include/eunit.hrl").

-export([start_link/0, set_socket/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
    terminate/3, code_change/4]).

%% FSM States
-export([wait_for_socket/2, wait_for_data/2]).

-record(state, {
    socket,
    peername,
    cep_work_sup,
    cep_work_pid
}).

-define(SERVER, ?MODULE).
-define(TIMEOUT, 120000).
-include_lib("eunit/include/eunit.hrl").

start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

set_socket(Pid, Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, Socket}).

init([]) ->
    lager:debug("------> rivus_cep_server init() : ~p",[]),
    {ok, CepSup} = rivus_cep_app_srv:get_cep_sup(),
    {ok, wait_for_socket, #state{cep_work_sup = CepSup}}.

wait_for_socket({socket_ready, Socket}, #state{cep_work_sup = CepSup} = State) when is_port(Socket) ->
    case inet:peername(Socket) of
        {ok, PeerInfo} ->
            case supervisor:start_child(CepSup, []) of
                {ok, Pid} -> inet:setopts(Socket, [{active, once}, {packet, 4}, binary]),
                             lager:debug("------> Peer connected !"),
                             {next_state, wait_for_data, State#state{socket = Socket, peername = PeerInfo, cep_work_pid = Pid}};
                Error -> {stop, Error, State}
            end;
        {error, Reason} ->
            lager:debug("Could not get peername: ~p", [Reason]),
            {stop, ok, State}
    end;
wait_for_socket(Other, State) ->
    lager:info("State: wait_for_socket. Unexpected message: ~p\n", [Other]),
    {next_state, wait_for_socket, State}.


%% Notification event coming from client
wait_for_data({data, Packet}, State) ->
    process_packet(Packet, State),
    {next_state, wait_for_data, State, ?TIMEOUT};
wait_for_data(timeout, State) ->
    lager:error("--->Client connection timeout - closing: ~p", [self()]),
    {stop, normal, State};

wait_for_data(Data, State) ->
    lager:info("--->Ignoring data: ~p, ~p", [self(), Data]),
    {next_state, wait_for_data, State, ?TIMEOUT}.

handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.


handle_info({tcp, Socket, Packet}, StateName, State) ->
    inet:setopts(Socket, [{active, once}]),
    ?MODULE:StateName({data, Packet}, State);
handle_info({tcp_closed, Socket}, _StateName, State = #state{socket = Socket}) ->
    lager:debug("-----> Got tcp_closed!!!"),
    {stop, normal, State};
handle_info({tcp_error, Socket, Reason}, StateName, State = #state{socket = Socket}) ->
    lager:debug("-----> Got tcp_eror. Reason: ~p!!!", [Reason]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
process_packet(Packet, State) ->
    case decode_packet(Packet) of
        {event, Event} -> process_event(Event, State);
        {event, Provider, Event} -> process_event(Provider, Event, State);
        {load_query, Query} -> load_query(Query, State);
        P -> lager:error("Cannot decode packet ~p", [P])
    end.

decode_packet(Packet) ->
    Term = binary_to_term(Packet),
    lager:debug("Got term: ~p", [Term]),
    Term.

process_event(Event, #state{socket = Socket, cep_work_pid = Pid}) ->
    lager:debug("-----> Sending event to CEP: ~p", [Event]),
    rivus_cep:notify_sync(Pid, Event),
    send_resp(ok, Socket).

process_event(Provider, Event, #state{socket = Socket, cep_work_pid = Pid}) ->
    lager:debug("-----> Sending event to CEP: ~p", [Event]),
    rivus_cep:notify_sync(Pid, Provider, Event),
    send_resp(ok, Socket).

send_resp(Resp, Socket) ->
    ok = gen_tcp:send(Socket, term_to_binary(Resp)).

load_query(Query, #state{socket = Socket, cep_work_pid = Pid}) ->
    {QueryStr, Providers, UpdateListners, Options} = Query,

    case rivus_cep:execute(Pid, QueryStr, Providers, UpdateListners, Options) of
        {ok, QueryPid, _} -> ok = gen_tcp:send(Socket, term_to_binary(QueryPid));
        ok -> send_resp(ok, Socket);
        _ -> lager:error("Cannot execute statement:: ~p", [Query]),
            send_resp({error, "Cannot execute statement:: ~p"}, Socket)
    end.

