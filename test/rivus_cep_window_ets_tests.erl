%%%
%%% Copyright 2012 - Basho Technologies, Inc. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%

-module(rivus_cep_window_ets_tests).
-include_lib("eunit/include/eunit.hrl").
-include("rivus_cep.hrl").
-include_lib("../deps/folsom/include/folsom.hrl").

-define(SIZE, 30).
-define(DOUBLE_SIZE, 60).
-define(RUNTIME, 90).
-define(READINGS, 10).

slide_test_() ->
    {setup,
     fun () ->
	     folsom:start(),
	     meck:new(folsom_utils)
     end,
     fun (_) -> meck:unload(folsom_utils),
		folsom:stop()
     end,
     [{"Create sliding window",
       fun create/0},
      {"test sliding window",
       {timeout, 30, fun slide/0}},
      {"resize sliding window (expand)",
       {timeout, 30, fun expand_window/0}},
      {"resize sliding window (shrink)",
       {timeout, 30, fun shrink_window/0}}

     ]}.

create() ->
    Window = rivus_cep_window_ets:new(?SIZE, []),
    ?assert(is_pid(Window#slide.server)),
    ?assertEqual(?SIZE, Window#slide.window),
    ?assertEqual(0, ets:info(Window#slide.reservoir, size)).

slide() ->
    %% don't want a trim to happen
    %% unless we call trim
    %% so kill the trim server process
    Window = rivus_cep_window_ets:new(?SIZE, []),
    ok = folsom_sample_slide_server:stop(Window#slide.server),
    Moments = lists:seq(1, ?RUNTIME),
    %% pump in 90 seconds worth of readings
    Moment = lists:foldl(fun(_X, Tick) ->
                                 Tock = tick(Tick),
                                 [rivus_cep_window_ets:update(Window, N, []) ||
                                     N <- lists:duplicate(?READINGS, Tock)],
                                 Tock end,
                         0,
                         Moments),
    %% are all readings in the table?
    check_table(Window, Moments),
    %% get values only returns last ?WINDOW seconds
    ExpectedValues = lists:sort(lists:flatten([lists:duplicate(?READINGS, N) ||
                                                  N <- lists:seq(?RUNTIME - ?SIZE, ?RUNTIME)])),
    Values = lists:sort(rivus_cep_window_ets:get_values(Window, [])),
    ?assertEqual(ExpectedValues, Values),
    %% trim the table
    Trimmed = rivus_cep_window_ets:trim(Window),
    ?assertEqual((?RUNTIME - ?SIZE - 1) * ?READINGS, Trimmed),
    check_table(Window, lists:seq(?RUNTIME - ?SIZE, ?RUNTIME)),
    %% increment the clock past the window
    tick(Moment, ?SIZE * 2),
    %% get values should be empty
    ?assertEqual([], rivus_cep_window_ets:get_values(Window, [])),
    %% trim, and table should be empty
    Trimmed2 = rivus_cep_window_ets:trim(Window),
    ?assertEqual((?RUNTIME * ?READINGS) - ((?RUNTIME - ?SIZE - 1) * ?READINGS), Trimmed2),
    check_table(Window, []),
    ok.

expand_window() ->
    %% create a new histogram
    %% will leave the trim server running, as resize() needs it
    Window = rivus_cep_window_ets:new(?SIZE, []),
    Moments = lists:seq(1, ?RUNTIME ),
    %% pump in 90 seconds worth of readings
    Moment = lists:foldl(fun(_X, Tick) ->
                                 Tock = tick(Tick),
                                 [rivus_cep_window_ets:update(Window, N, []) ||
                                     N <- lists:duplicate(?READINGS, Tock)],
                                 Tock end,
                         0,
                         Moments),
    %% are all readings in the table?
    check_table(Window, Moments),
    
    %% get values only returns last ?WINDOW seconds
    ExpectedValues = lists:sort(lists:flatten([lists:duplicate(?READINGS, N) ||
                                                  N <- lists:seq(?RUNTIME - ?SIZE, ?RUNTIME)])),
    Values = lists:sort(rivus_cep_window_ets:get_values(Window, [])),
    ?assertEqual(ExpectedValues, Values),

    %%expand the sliding window
    NewWindow = rivus_cep_window_ets:resize(Window, ?DOUBLE_SIZE, []),

    %% get values only returns last ?WINDOW*2 seconds
    NewExpectedValues = lists:sort(lists:flatten([lists:duplicate(?READINGS, N) ||
                                                  N <- lists:seq(?RUNTIME - ?DOUBLE_SIZE, ?RUNTIME)])),
    NewValues = lists:sort(rivus_cep_window_ets:get_values(NewWindow, [])),
    ?assertEqual(NewExpectedValues, NewValues),
        
    %% trim the table
    Trimmed = rivus_cep_window_ets:trim(NewWindow),
    ?assertEqual((?RUNTIME - ?DOUBLE_SIZE - 1) * ?READINGS, Trimmed),
    check_table(NewWindow, lists:seq(?RUNTIME - ?DOUBLE_SIZE, ?RUNTIME)),
    %% increment the clock past the window
    tick(Moment, ?DOUBLE_SIZE*2),
    %% get values should be empty
    ?assertEqual([], rivus_cep_window_ets:get_values(NewWindow, [])),
    %% trim, and table should be empty
    Trimmed2 = rivus_cep_window_ets:trim(NewWindow),
    ?assertEqual((?RUNTIME * ?READINGS) - ((?RUNTIME - ?DOUBLE_SIZE - 1) * ?READINGS), Trimmed2),
    check_table(NewWindow, []),
    ok.
%%    ok = folsom_metrics:delete_metric(?HISTO2).


shrink_window() ->
    %% create a new histogram
    %% will leave the trim server running, as resize() needs it
    Window = rivus_cep_window_ets:new(?DOUBLE_SIZE, []),
    Moments = lists:seq(1, ?RUNTIME ),
    %% pump in 90 seconds worth of readings
    Moment = lists:foldl(fun(_X, Tick) ->
                                 Tock = tick(Tick),
                                 [rivus_cep_window_ets:update(Window, N, []) ||
                                     N <- lists:duplicate(?READINGS, Tock)],
                                 Tock end,
                         0,
                         Moments),
    %% are all readings in the table?
    check_table(Window, Moments),
    
    %% get values only returns last ?DOUBLE_WINDOW seconds
    ExpectedValues = lists:sort(lists:flatten([lists:duplicate(?READINGS, N) ||
                                                  N <- lists:seq(?RUNTIME - ?DOUBLE_SIZE, ?RUNTIME)])),
    Values = lists:sort(rivus_cep_window_ets:get_values(Window, [])),
    ?assertEqual(ExpectedValues, Values),

    %%shrink the sliding window
    NewWindow = rivus_cep_window_ets:resize(Window, ?SIZE, []),

    %% get values only returns last ?SIZE seconds
    NewExpectedValues = lists:sort(lists:flatten([lists:duplicate(?READINGS, N) ||
                                                  N <- lists:seq(?RUNTIME - ?SIZE, ?RUNTIME)])),
    NewValues = lists:sort(rivus_cep_window_ets:get_values(NewWindow, [])),
    ?assertEqual(NewExpectedValues, NewValues),
    
    
    %% trim the table
    Trimmed = rivus_cep_window_ets:trim(NewWindow),
    ?assertEqual((?RUNTIME - ?SIZE - 1) * ?READINGS, Trimmed),
    check_table(NewWindow, lists:seq(?RUNTIME - ?SIZE, ?RUNTIME)),
    %% increment the clock past the window
    tick(Moment, ?SIZE*2),
    %% get values should be empty
    ?assertEqual([], rivus_cep_window_ets:get_values(NewWindow, [])),
    %% trim, and table should be empty
    Trimmed2 = rivus_cep_window_ets:trim(NewWindow),
    ?assertEqual((?RUNTIME * ?READINGS) - ((?RUNTIME - ?SIZE - 1) * ?READINGS), Trimmed2),
    check_table(NewWindow, []),
    ok.

tick(Moment0, IncrBy) ->
    Moment = Moment0 + IncrBy,
    meck:expect(folsom_utils, now_epoch, fun() ->
						 Moment end),
    Moment.

tick(Moment) ->
    tick(Moment, 1).

check_table(Window, Moments) ->
    Tab = lists:sort(ets:tab2list(Window#slide.reservoir)),
    {Ks, Vs} = lists:unzip(Tab),
    ExpectedVs = lists:sort(lists:flatten([lists:duplicate(10, N) || N <- Moments])),
    StrippedKeys = lists:usort([X || {X, _} <- Ks]),
    ?assertEqual(Moments, StrippedKeys),
    ?assertEqual(ExpectedVs, lists:sort(Vs)).
