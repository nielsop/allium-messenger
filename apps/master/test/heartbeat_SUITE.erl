-module(heartbeat_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    receive_heartbeat_node_valid_node_test/1,
    receive_heartbeat_client_valid_client_test/1,
    receive_heartbeat_node_invalid_node_test/1,
    receive_heartbeat_client_invalid_client_test/1, 
    remove_nodes_with_inactive_heartbeats_test/1,
    remove_clients_with_inactive_heartbeats_test/1,
    add_node_to_receive_heartbeat_node_format/1, 
    add_client_to_receive_heartbeat_client_format/1, 
    remove_node_from_heartbeat_monitor/1,
    remove_client_from_heartbeat_monitor/1
]).

all() ->
    [
        receive_heartbeat_node_valid_node_test,
        receive_heartbeat_client_valid_client_test,
        receive_heartbeat_node_invalid_node_test,
        receive_heartbeat_client_invalid_client_test,
        remove_nodes_with_inactive_heartbeats_test,
        remove_clients_with_inactive_heartbeats_test,
        add_node_to_receive_heartbeat_node_format,
        add_client_to_receive_heartbeat_client_format,
        remove_node_from_heartbeat_monitor,
        remove_client_from_heartbeat_monitor
    ].

init_per_suite(Config) ->
    meck:new(node_service, [non_strict]),
    meck:new(client_service, [non_strict]),
    meck:new(heartbeat_monitor, [passthrough]),
    meck:new(redis, [non_strict]),
    meck:new(persistence_service, [non_strict]),
    TimeBetweenHeartbeats = 5000,
    CurrentTime = 100000,
    HeartbeatNodeLabel = "heartbeat_node_",
    HeartbeatClientLabel = "heartbeat_client_",
    NodeLabel = "onion_" ++ HeartbeatNodeLabel,
    NodeLabels = {HeartbeatNodeLabel, NodeLabel},
    ClientLabel = "onion_" ++ HeartbeatClientLabel,
    ClientLabels = {HeartbeatClientLabel, ClientLabel},
    [{time, CurrentTime}, {timebetweenheartbeats, TimeBetweenHeartbeats},
        {nodelabels, NodeLabels}, {clientlabels, ClientLabels}] ++ Config.

init_per_testcase(_, Config) ->
    meck:expect(heartbeat_monitor, get_current_time, fun() -> 100000 end),
    meck:expect(node_service, node_verify,
        fun(NodeId, _) ->
            case NodeId of
                "10" -> ok;
                _ -> error(nodenotfound) end
        end),
    meck:expect(client_service, client_verify,
        fun(Username, _) ->
            case Username of
                "ValidUser" -> ok;
                _ -> error(clientnotfound) end
        end),
    meck:expect(node_service, node_unregister, fun(_) -> ok end),
    meck:expect(redis, set, fun(_, _) -> ok end),
    meck:expect(redis, remove, fun(_) -> ok end),
    Config.

end_per_testcase(_, Config) ->
    meck:unload(redis),
    meck:unload(heartbeat_monitor),
    meck:unload(node_service),
    meck:unload(client_service),
    meck:unload(persistence_service),
    Config.

receive_heartbeat_node_valid_node_test(Config) ->
    SecretHash = "NODE12345SECRETHASHDONTTELLANYONE",
    {HeartbeatNodeLabel, _} = ?config(nodelabels, Config),
    NodeId = "10",

    ok = heartbeat_monitor:receive_heartbeat_node(NodeId, SecretHash),
    true = test_helpers:check_function_called(node_service, node_verify, [NodeId, SecretHash]),
    true = test_helpers:check_function_called(heartbeat_monitor, get_current_time, []),
    true = test_helpers:check_function_called(redis, set, [HeartbeatNodeLabel ++ NodeId, 100000]).

receive_heartbeat_client_valid_client_test(Config) ->
    Validpass = "ValidPass",
    {HeartbeatClientLabel, _} = ?config(clientlabels, Config),
    Username = "ValidUser",

    ok = heartbeat_monitor:receive_heartbeat_client(Username, Validpass),
    true = test_helpers:check_function_called(client_service, client_verify, [Username, Validpass]),
    true = test_helpers:check_function_called(heartbeat_monitor, get_current_time, []),
    true = test_helpers:check_function_called(redis, set, [HeartbeatClientLabel ++ Username, 100000]).

receive_heartbeat_node_invalid_node_test(_Config) ->
    SecretHash =  "NODE12345SECRETHASHDONTTELLANYONE",
    NodeId = "11",

    test_helpers:assert_fail(fun heartbeat_monitor:receive_heartbeat_node/2, [NodeId, SecretHash],
        error, nodenotverified, failed_to_catch_invalid_node),
    true = test_helpers:check_function_called(node_service, node_verify, [NodeId, SecretHash]).

receive_heartbeat_client_invalid_client_test(_Config) ->
    Password = "Validpass",
    Username = "InvalidUsername",

    test_helpers:assert_fail(fun heartbeat_monitor:receive_heartbeat_client/2, [Username, Password],
        error, clientnotverified, failed_to_catch_invalid_client),
    true = test_helpers:check_function_called(client_service, client_verify, [Username, Password]).

remove_nodes_with_inactive_heartbeats_test(Config) ->
    Time = ?config(time, Config),
    HeartbeatTime = ?config(timebetweenheartbeats, Config),
    {HeartbeatNodeLabel, NodeLabel} = ?config(nodelabels, Config),
    NodesWithTimes = [{activenode1, "10", Time - HeartbeatTime}, {activenode2, "13", Time},
        {inactivenode1, "11", Time - HeartbeatTime - 1}, {inactivenode2, "14", Time - HeartbeatTime * 2}],
    [ActiveNodeIdOne, ActiveNodeIdTwo, InactiveNodeIdOne, InactiveNodeIdTwo] = [element(2, X) || X <- NodesWithTimes],

    MonitoredNodes = [list_to_binary(NodeLabel ++ NodeId) || {_, NodeId, _} <- NodesWithTimes],
    MonitoredTimes = [integer_to_binary(TimeHeartbeat) || {_, _, TimeHeartbeat} <- NodesWithTimes],
    meck:expect(redis, get_matching_keys, fun(_HeartbeatNodeLabel) -> MonitoredNodes end),
    meck:expect(redis, get_list, fun(_) -> MonitoredTimes end),

    [InactiveNodeIdOne, InactiveNodeIdTwo] = heartbeat_monitor:remove_inactive_nodes(HeartbeatTime),
    true = test_helpers:check_function_called(redis, get_matching_keys, [HeartbeatNodeLabel]),
    true = test_helpers:check_function_called(redis, get_list, [[NodeLabel ++ ActiveNodeIdOne, NodeLabel ++
        ActiveNodeIdTwo, NodeLabel ++ InactiveNodeIdOne, NodeLabel ++ InactiveNodeIdTwo]]),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatNodeLabel ++ InactiveNodeIdOne]),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatNodeLabel ++ InactiveNodeIdTwo]),
    true = test_helpers:check_function_called(heartbeat_monitor, get_current_time, []),
    true = test_helpers:check_function_called(node_service, node_unregister, [InactiveNodeIdOne]),
    true = test_helpers:check_function_called(node_service, node_unregister, [InactiveNodeIdTwo]).

remove_clients_with_inactive_heartbeats_test(Config) ->
    Time = ?config(time, Config),
    HeartbeatTime = ?config(timebetweenheartbeats, Config),
    {HeartbeatClientLabel, ClientLabel} = ?config(clientlabels, Config),
    ClientsWithTimes = [{activeclient1, "client1", Time - HeartbeatTime}, {activeclient2, "client3", Time},
        {inactiveclient1, "client2", Time - HeartbeatTime - 1}, {inactiveclient2, "client4", Time - HeartbeatTime * 2}],
    [ActiveClientIdOne, ActiveClientIdTwo, InactiveClientIdOne, InactiveClientIdTwo] =
        [element(2, X) || X <- ClientsWithTimes],
    MonitoredClients = [list_to_binary(ClientLabel ++ Username) || {_, Username, _} <- ClientsWithTimes],
    MonitoredTimes = [integer_to_binary(TimeHeartbeat) || {_, _, TimeHeartbeat} <- ClientsWithTimes],
    meck:expect(redis, get_matching_keys, fun(_HeartbeatClientLabel) -> MonitoredClients end),
    meck:expect(redis, get_list, fun(_) -> MonitoredTimes end),
    meck:expect(persistence_service, update_client_hash, fun(_, _) -> ok end),

    [InactiveClientIdOne, InactiveClientIdTwo] = heartbeat_monitor:remove_inactive_clients(HeartbeatTime),
    true = test_helpers:check_function_called(redis, get_matching_keys, [HeartbeatClientLabel]),
    true = test_helpers:check_function_called(redis, get_list, [[ClientLabel ++ ActiveClientIdOne, ClientLabel ++
        ActiveClientIdTwo, ClientLabel ++ InactiveClientIdOne, ClientLabel ++ InactiveClientIdTwo]]),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatClientLabel ++ InactiveClientIdOne]),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatClientLabel ++ InactiveClientIdTwo]),
    true = test_helpers:check_function_called(heartbeat_monitor, get_current_time, []),
    true = test_helpers:check_function_called(client_service, client_logout, [InactiveClientIdOne]),
    true = test_helpers:check_function_called(client_service, client_logout, [InactiveClientIdTwo]).

add_node_to_receive_heartbeat_node_format(Config) ->
    {HeartbeatNodeLabel, _} = ?config(nodelabels, Config),
    CurrentTime = ?config(time, Config),
    NodeId = "12",

    ok = heartbeat_monitor:add_node(NodeId),
    true = test_helpers:check_function_called(redis, set, [HeartbeatNodeLabel ++ NodeId, CurrentTime]).

add_client_to_receive_heartbeat_client_format(Config) ->
    {HeartbeatClientLabel, _} = ?config(clientlabels, Config),
    CurrentTime = ?config(time, Config),
    Username = "validUser",

    ok = heartbeat_monitor:add_client(Username),
    true = test_helpers:check_function_called(redis, set, [HeartbeatClientLabel ++ Username, CurrentTime]).

remove_node_from_heartbeat_monitor(Config) ->
    {HeartbeatNodeLabel, _} = ?config(nodelabels, Config),
    NodeId = "20",

    ok = heartbeat_monitor:remove_node(NodeId),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatNodeLabel ++ NodeId]).

remove_client_from_heartbeat_monitor(Config) ->
    {HeartbeatClientLabel, _} = ?config(clientlabels, Config),
    Username = "validUser",

    ok = heartbeat_monitor:remove_client(Username),
    true = test_helpers:check_function_called(redis, remove, [HeartbeatClientLabel ++ Username]).


