%% sample code to evaluate message queue flood in BEAM.

-module(msgq_flood).

-behaviour(gen_server).

-define(DELAYED_WRITE_MS, 2*1000).
-define(DELAYED_WRITE_BYTES, 64*1024).

-define(SERVER_PROC_NAME, log_server).
-define(DAM_PROC_NAME, log_dam).

-define(DAM_THRESHOLD, 10000).
-define(DAM_WAIT_MS, 100).

%% API
-export([start_link/1]).
-export([log/1, log/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3,
         handle_cast/2, handle_info/2, code_change/3]).

%% dam (traffic controller) entrance and loop
-export([dam_loop/1]).

%---- (for debug) flood log and watch its consumption
-export([flood_direct/2]).
-export([flood_to_dam/2]).
-export([watch/0]).

-record(state,{file, dam}).

%%====================================================================
%% log server API
%%====================================================================
start_link(Path) ->
    gen_server:start_link({local, ?SERVER_PROC_NAME}, ?MODULE, [Path], []).

log(Msg) ->
    case whereis(?DAM_PROC_NAME) of
	undefined -> ok;
	Pid -> log(Msg, Pid)
    end.

log(Msg, Pid) ->
    DateTime = datetime(),
    IOList = [DateTime, " ", Msg, "\n"],
    gen_server:cast(Pid, {log, iolist_to_binary(IOList)}).

stop(Pid) ->
    gen_server:call(Pid, stop).

%%====================================================================
%% dam (traffic controller)
%%====================================================================
dam_loop(Pid) ->
    receive
	stop -> ok;
	Msg -> discharge(Pid, Msg), dam_loop(Pid)
    end.

discharge(Pid, Msg) ->
    {message_queue_len, Qlen} = process_info(Pid, message_queue_len),
    if Qlen =< ?DAM_THRESHOLD ->
	Pid ! Msg;
       true ->
	timer:sleep(?DAM_WAIT_MS), discharge(Pid, Msg)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Path]) ->
   {ok, File} = file:open(Path,
		    [append, raw, {delayed_write, ?DELAYED_WRITE_BYTES, ?DELAYED_WRITE_MS}]),
    DamPid = spawn_link(?MODULE, dam_loop, [self()]),
    register(?DAM_PROC_NAME, DamPid),
    {ok, #state{file = File, dam = DamPid}}.

terminate(_Reason, #state{file = File, dam = DamPid}) ->
    DamPid ! stop,
    file:close(File),
    ok.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast({log, Msg}, #state{file = File} = State) ->
    file:write(File, Msg),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% internal function
%%====================================================================

%% returns ISO8601 format date and time
datetime() ->
    TS = {_, _, Micro} = os:timestamp(),
    {Date, Time} = calendar:now_to_universal_time(TS),
    io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0b.~3..0bZ",
		  lists:flatten([tuple_to_list(Date), tuple_to_list(Time), Micro div 1000])).

flood_direct(ProcessCount, RepeatCount) ->
    Pid = whereis(?SERVER_PROC_NAME),
    flood(ProcessCount, RepeatCount, Pid).

flood_to_dam(ProcessCount, RepeatCount) ->
    Pid = whereis(?DAM_PROC_NAME),
    flood(ProcessCount, RepeatCount, Pid).

flood(ProcessCount, RepeatCount, Pid) ->
    Message = <<"hello">>,
    lists:foreach(fun(_) ->
                   spawn(fun() -> timer:sleep(1000),
                                  process_flag(priority, low),
                                  flood_inner(RepeatCount, Message, Pid)
                         end)
                  end,
                  lists:seq(1, ProcessCount)).

flood_inner(0, _Msg, _Pid) ->
    ok;
flood_inner(Num, Msg, Pid) ->
    log(Msg, Pid),
    flood_inner(Num-1, Msg, Pid).

watch() ->
    ServerPid = whereis(?SERVER_PROC_NAME),
    DamPid = whereis(?DAM_PROC_NAME),
    io:format("DateTime\t\t\tdam msgq (diff)\tserver msgq (diff)~n"),
    watch({DamPid, -1}, {ServerPid, -1}).

watch({DamServerPid, Prev1}, {LogServerPid, Prev2}) ->
    Clock = datetime(),
    NumOfMsgq1 = num_of_msgq(DamServerPid),
    Diff1 = diff_of_msgq(Prev1, NumOfMsgq1),
    NumOfMsgq2 = num_of_msgq(LogServerPid),
    Diff2 = diff_of_msgq(Prev2, NumOfMsgq2),
    io:format("~s\t~B (~B)\t~B (~B)~n", [Clock, NumOfMsgq1, Diff1, NumOfMsgq2, Diff2]),
    timer:sleep(1000),
    watch({DamServerPid, NumOfMsgq1}, {LogServerPid, NumOfMsgq2}).

num_of_msgq(Pid) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Num} -> Num;
        _ -> 0
    end.

diff_of_msgq(Prev, Now) ->
    case Prev of
        -1 -> 0;
        X when is_number(X) -> Now - X 
    end.
