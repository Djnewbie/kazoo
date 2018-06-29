-module(kz_cache_stampede_tests).

-export([stampede_worker/3]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_stdlib/include/kz_types.hrl").

-define(BASE_TIMEOUT_MS, 50).

-define(SETUP_LOCAL(F), {'setup', 'spawn', fun init/0, fun cleanup/1, F}).
-define(SETUP_LOAD(F), {'setup', 'spawn', fun init_load/0, fun cleanup/1, F}).

wait_for_stampede_local_test_() ->
    {"simple stampede test", ?SETUP_LOCAL(fun wait_for_stampede_local/1)}.

stampede_load_test_() ->
    {"load test", ?SETUP_LOAD(fun stampede_load/1)}.

init() ->
    {'ok', CachePid} = kz_cache:start_link(?MODULE),
    CachePid.

%%------------------------------------------------------------------------------
%% @doc Generates workers to try access the cached key and write it if missing
%% Number of workers that can successfully finish appears to be a factor of
%% (worker-count, stampede-timeout).
%% The more workers starting up around the same time, the more that see the
%% missing key and try to lock the key using kz_cache:mitigate_stampede_local/2
%% There should obviously only be one worker who "locks" the key.
%% The rest of the workers should insert monitor objects into the monitor table
%% to be notified when the key is written to with a "real" value.
%%
%% @end
%%------------------------------------------------------------------------------

init_load() ->
    CachePid = init(),

    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(6),

    Workers = 3000,
    StampedeTimeout = 1000,

    Pids = [spawn_monitor(?MODULE, 'stampede_worker', [Key, Value, StampedeTimeout])
            || _ <- lists:seq(1,Workers)
           ],
    Waited = wait_for_workers(Pids, {0, 0}),

    {CachePid, Waited, Workers}.

cleanup({CachePid, _, _}) ->
    cleanup(CachePid);
cleanup(CachePid) ->
    kz_cache:stop_local(CachePid).

wait_for_stampede_local(_) ->
    Timeout = rand:uniform(?BASE_TIMEOUT_MS)+?BASE_TIMEOUT_MS,
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    _WriterPid = spawn_monitor(fun() -> writer_job_stampede(Key, Value, Timeout) end),
    timer:sleep(10), % allows the writer to lock the key
    ?_assertEqual({'ok', Value}, kz_cache:wait_for_stampede_local(?MODULE, Key, Timeout)).

writer_job_stampede(Key, Value, Timeout) ->
    kz_cache:mitigate_stampede_local(?MODULE, Key),
    timer:sleep(Timeout div 2),
    kz_cache:store_local(?MODULE, Key, Value).

stampede_load({_CachePid, Waited, Workers}) ->
    ?_assertEqual({Workers, 0}, Waited).

stampede_worker(Key, Value, StampedeTimeout) ->
    timer:sleep(rand:uniform(50)),

    %% ?LOG_INFO("~p: starting worker", [self()]),
    MitigationKey = kz_cache:mitigation_key(),
    {'ok', Value} =
        case kz_cache:fetch_local(?MODULE, Key) of
            {MitigationKey, _Pid} ->
                %% ?LOG_INFO("~p: waiting for mitigation from ~p", [self(), _Pid]),
                kz_cache:wait_for_stampede_local(?MODULE, Key, StampedeTimeout);
            {'ok', Value}=Ok ->
                %% ?LOG_INFO("got value"),
                Ok;
            {'error', 'not_found'} ->
                %% ?LOG_INFO("~p: mitigating stampede", [self()]),
                mitigate_stampede(Key, Value, StampedeTimeout)
        end.

mitigate_stampede(Key, Value, StampedeTimeout) ->
    case kz_cache:mitigate_stampede_local(?MODULE, Key) of
        'ok' ->
            %% ?LOG_INFO("~p: locked key", [self()]),
            write_to_cache(Key, Value);
        'error' ->
            %% ?LOG_INFO("~p: key already locked", [self()]),
            kz_cache:wait_for_stampede_local(?MODULE, Key, StampedeTimeout)
    end.

write_to_cache(Key, Value) ->
    timer:sleep(200), % simulate a db operation or other long-computation
    kz_cache:store_local(?MODULE, Key, Value),
    %% ?LOG_INFO("~p: wrote key", [self()]),
    {'ok', Value}.

wait_for_workers([], Results) -> Results;
wait_for_workers([{Pid, Ref} | Pids], {Success, Fail}) ->
    receive
        {'DOWN', Ref, 'process', Pid, 'normal'} ->
            wait_for_workers(Pids, {Success+1, Fail});
        {'DOWN', Ref, 'process', Pid, _Reason} ->
            wait_for_workers(Pids, {Success, Fail+1})
    after 5000 ->
            wait_for_workers(Pids, {Success, Fail+1})
    end.
