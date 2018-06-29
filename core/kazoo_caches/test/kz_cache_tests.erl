-module(kz_cache_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_stdlib/include/kz_types.hrl").

-define(BASE_TIMEOUT, 50).

cache_test_() ->
    {'timeout'
    ,10
    ,{'spawn'
     ,{'setup'
      ,fun init/0
      ,fun cleanup/1
      ,fun(_CachePid) ->
               [{"wait for key exists", fun wait_for_key_local_existing/0}
               ,{"wait for key appears", fun wait_for_key_local_mid_stream/0}
               ,{"wait for key timeout", fun wait_for_key_local_timeout/0}
               ,{"key peek", fun peek_local/0}
               ,{"key erase", fun key_erase/0}
               ,{"cache flush", fun cache_flush/0}
               ,{"fetch keys", fun fetch_keys/0}
               ,{"key timeout is flushed", fun key_timeout_is_flushed/0}
               ]
       end
      }
     }
    }.

init() ->
    {'ok', CachePid} = kz_cache:start_link(?MODULE),
    CachePid.

cleanup(CachePid) ->
    kz_cache:stop_local(CachePid).

wait_for_key_local_existing() ->
    Timeout = rand:uniform(?BASE_TIMEOUT)+?BASE_TIMEOUT,
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    kz_cache:store_local(?MODULE, Key, Value),

    _WriterPid = spawn_monitor(fun() -> writer_job(Key, Value, Timeout) end),

    ?assertEqual({'ok', Value}, kz_cache:wait_for_key_local(?MODULE, Key, Timeout)).

wait_for_key_local_mid_stream() ->
    Timeout = rand:uniform(?BASE_TIMEOUT)+?BASE_TIMEOUT,
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    _WriterPid = spawn_monitor(fun() -> writer_job(Key, Value, Timeout) end),

    Wait = kz_cache:wait_for_key_local(?MODULE, Key, Timeout),
    ?assertEqual({'ok', Value}, Wait).

wait_for_key_local_timeout() ->
    Timeout = ?BASE_TIMEOUT,
    Key = kz_binary:rand_hex(5),

    ?assertEqual({'error', 'timeout'}, kz_cache:wait_for_key_local(?MODULE, Key, Timeout)).

peek_local() ->
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)),

    kz_cache:store_local(?MODULE, Key, Value),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, Key)).

key_timeout_is_flushed() ->
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    Timeout = 1, % 1s
    kz_cache:store_local(?MODULE, Key, Value, [{'expires', Timeout}]),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, Key)),
    timer:sleep(Timeout*?MILLISECONDS_IN_SECOND+1000), % account for soft-realtime timers
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)).

key_erase() ->
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)),
    ?assertEqual('ok', kz_cache:erase_local(?MODULE, Key)),

    kz_cache:store_local(?MODULE, Key, Value),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, Key)),

    kz_cache:erase_local(?MODULE, Key),
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)).

cache_flush() ->
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)),

    kz_cache:store_local(?MODULE, Key, Value),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, Key)),

    kz_cache:flush_local(?MODULE),
    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)).

fetch_keys() ->
    Key = kz_binary:rand_hex(5),
    Value = kz_binary:rand_hex(5),

    ?assertEqual({'error', 'not_found'}, kz_cache:peek_local(?MODULE, Key)),
    ?assertEqual([], kz_cache:fetch_keys_local(?MODULE)),

    kz_cache:store_local(?MODULE, Key, Value),
    ?assertEqual({'ok', Value}, kz_cache:peek_local(?MODULE, Key)),

    Keys = kz_cache:fetch_keys_local(?MODULE),
    ?assertEqual([Key], Keys).

writer_job(Key, Value, Timeout) ->
    timer:sleep(Timeout div 2),
    kz_cache:store_local(?MODULE, Key, Value).
