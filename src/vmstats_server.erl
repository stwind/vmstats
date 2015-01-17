%%% Main worker for vmstats. This module sits in a loop fired off with
%%% timers with the main objective of routinely sending data to
%%% statsderl.
-module(vmstats_server).
-behaviour(gen_server).
%% Interface
-export([start_link/0, start_link/1]).
%% Internal Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-define(TIMER_MSG, '#delay').

-record(state, {key :: string(),
                sched_time :: enabled | disabled | unavailable,
                prev_sched :: [{integer(), integer(), integer()}],
                timer_ref :: reference(),
                delay :: integer(), % milliseconds
                nodename :: atom(),
                prev_io :: {In::integer(), Out::integer()},
                prev_gc :: {GCs::integer(), Words::integer(), 0}}).
%%% INTERFACE
start_link() ->
    start_link(base_key()).

%% the base key is passed from the supervisor. This function
%% should not be called manually.
start_link(BaseKey) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, BaseKey, []).

%%% INTERNAL EXPORTS
init(BaseKey) ->
    {ok, Delay} = application:get_env(vmstats, delay),
    Ref = erlang:start_timer(Delay, self(), ?TIMER_MSG),
    {{input,In},{output,Out}} = erlang:statistics(io),
    PrevGC = erlang:statistics(garbage_collection),
    {ok, State} = case {sched_time_available(), application:get_env(vmstats, sched_time)} of
        {true, {ok,true}} ->
            {ok, #state{key = BaseKey,
                        timer_ref = Ref,
                        delay = Delay,
                        nodename = nodename(),
                        sched_time = enabled,
                        prev_sched = lists:sort(erlang:statistics(scheduler_wall_time)),
                        prev_io = {In,Out},
                        prev_gc = PrevGC}};
        {true, _} ->
            {ok, #state{key = BaseKey,
                        timer_ref = Ref,
                        delay = Delay,
                        nodename = nodename(),
                        sched_time = disabled,
                        prev_io = {In,Out},
                        prev_gc = PrevGC}};
        {false, _} ->
            {ok, #state{key = BaseKey,
                        timer_ref = Ref,
                        delay = Delay,
                        nodename = nodename(),
                        sched_time = unavailable,
                        prev_io = {In,Out},
                        prev_gc = PrevGC}}
    end,
    {ok, init_metrics(State)}.

handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, R, ?TIMER_MSG}, S = #state{delay=D, timer_ref=R}) ->
    %% Processes
    exometer:update(key(S, proc_count), erlang:system_info(process_count)),
    exometer:update(key(S, proc_limit), erlang:system_info(process_limit)),

    %% Messages in queues
    TotalMessages = lists:foldl(
        fun(Pid, Acc) ->
            case process_info(Pid, message_queue_len) of
                undefined -> Acc;
                {message_queue_len, Count} -> Count+Acc
            end
        end,
        0,
        processes()
    ),
    exometer:update(key(S, messages_in_queues), TotalMessages),

    %% Modules loaded
    exometer:update(key(S, modules), length(code:all_loaded())),

    %% Queued up processes (lower is better)
    exometer:update(key(S, run_queue), erlang:statistics(run_queue)),

    %% Error logger backlog (lower is better)
    {_, MQL} = process_info(whereis(error_logger), message_queue_len),
    exometer:update(key(S, error_logger_queue_len), MQL),

    %% Memory usage. There are more options available, but not all were kept.
    %% Memory usage is in bytes.
    Mem = erlang:memory(),
    exometer:update(key(S, [memory, total]), proplists:get_value(total, Mem)),
    exometer:update(key(S, [memory, procs_used]), proplists:get_value(processes_used,Mem)),
    exometer:update(key(S, [memory, atom_used]), proplists:get_value(atom_used,Mem)),
    exometer:update(key(S, [memory, binary]), proplists:get_value(binary, Mem)),
    exometer:update(key(S, [memory, ets]), proplists:get_value(ets, Mem)),

    %% Incremental values
    #state{prev_io={OldIn,OldOut}, prev_gc={OldGCs,OldWords,_}} = S,
    {{input,In},{output,Out}} = erlang:statistics(io),
    GC = {GCs, Words, _} = erlang:statistics(garbage_collection),

    exometer:update(key(S, [io, bytes_in]), In-OldIn),
    exometer:update(key(S, [io, bytes_out]), Out-OldOut),
    exometer:update(key(S, [gc, count]), GCs-OldGCs),
    exometer:update(key(S, [gc, words_reclaimed]), Words-OldWords),

    %% Reductions across the VM, excluding current time slice, already incremental
    {_, Reds} = erlang:statistics(reductions),
    exometer:update(key(S, reductions), Reds),

    %% Scheduler wall time
    #state{sched_time=Sched, prev_sched=PrevSched} = S,
    case Sched of
        enabled ->
            NewSched = lists:sort(erlang:statistics(scheduler_wall_time)),
            [begin
                SSid = integer_to_list(Sid),
                exometer:update(key(S, [scheduler_wall_time,SSid,active]), Active),
                exometer:update(key(S, [scheduler_wall_time,SSid,total]), Total)
             end
             || {Sid, Active, Total} <- wall_time_diff(PrevSched, NewSched)],
            {noreply, S#state{timer_ref=erlang:start_timer(D, self(), ?TIMER_MSG),
                              prev_sched=NewSched, prev_io={In,Out}, prev_gc=GC}};
        _ -> % disabled or unavailable
            {noreply, S#state{timer_ref=erlang:start_timer(D, self(), ?TIMER_MSG),
                              prev_io={In,Out}, prev_gc=GC}}
    end;
handle_info(_Msg, {state, _Key, _TimerRef, _Delay}) ->
    exit(forced_upgrade_restart);
handle_info(_Msg, {state, _Key, SchedTime, _PrevSched, _TimerRef, _Delay}) ->
    %% The older version may have had the scheduler time enabled by default.
    %% We could check for settings and preserve it in memory, but then it would
    %% be more confusing if the behaviour changes on the next restart.
    %% Instead, we show a warning and restart as usual.
    case {application:get_env(vmstats, sched_time), SchedTime} of
        {undefined, active} -> % default was on
            error_logger:warning_msg("vmstats no longer runs scheduler time by default. Restarting...");
        _ ->
            ok
    end,
    exit(forced_upgrade_restart);
handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% Returns the two timeslices as a ratio of each other,
%% as a percentage so that StatsD gets to print something > 1
wall_time_diff(T1, T2) ->
    [{I, Active2-Active1, Total2-Total1}
     || {{I, Active1, Total1}, {I, Active2, Total2}} <- lists:zip(T1,T2)].

sched_time_available() ->
    try erlang:system_flag(scheduler_wall_time, true) of
        _ -> true
    catch
        error:badarg -> false
    end.

-spec base_key() -> term().
base_key() ->
    application:get_env(vmstats, base_key, vmstats).

key(S, Part) when is_atom(Part) ->
    key(S, [Part]);
key(#state{key = Key, nodename = Node}, Parts) when is_list(Parts) ->
    [Key, Node | Parts].

init_metrics(#state{sched_time = Sched} = S) ->
    exometer:new(key(S, proc_count), gauge),
    exometer:new(key(S, proc_limit), gauge),
    exometer:new(key(S, messages_in_queues), gauge),
    exometer:new(key(S, modules), gauge),
    exometer:new(key(S, error_logger_queue_len), gauge),
    exometer:new(key(S, [memory, total]), gauge),
    exometer:new(key(S, [memory, procs_used]), gauge),
    exometer:new(key(S, [memory, atom_used]), gauge),
    exometer:new(key(S, [memory, binary]), gauge),
    exometer:new(key(S, [memory, ets]), gauge),
    exometer:new(key(S, [io, bytes_in]), counter),
    exometer:new(key(S, [io, bytes_out]), counter),
    exometer:new(key(S, [io, count]), counter),
    exometer:new(key(S, [io, words_reclaimed]), counter),
    exometer:new(key(S, reductions), counter),
    case Sched of
        enabled ->
            NewSched = lists:sort(erlang:statistics(scheduler_wall_time)),
            [begin
                 exometer:new(key(S, [scheduler_wall_time,Id,active]), gauge),
                 exometer:new(key(S, [scheduler_wall_time,Id,total]), gauge)
             end || {Id, _, _} <- NewSched];
        _ ->
            nop
    end,
    S.

nodename() ->
    NodeStr = atom_to_list(node()),
    NodeStr2 = lists:foldl(
                 fun($., Acc) -> [$_ | Acc];
                    (C, Acc) -> [C | Acc]
                 end, [], NodeStr),
    list_to_atom(lists:reverse(NodeStr2)).
