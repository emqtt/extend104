%%%----------------------------------------------------------------------
%%% Created	: 2013-12-4
%%% author 	: hejin1026@gmail.com
%%%----------------------------------------------------------------------
-module(master_ctl).

-include_lib("elog/include/elog.hrl").
-include("terminl.hrl").

-compile(export_all).

lookup_mnesia(Table) ->
	mnesia:table_info(list_to_atom(Table), all).
	
lookup_cid(Cid) ->
	mnesia:dirty_read(dispatch, {monitor, list_to_integer(Cid)}).	
	
process(Process) ->
   process_info(whereis(list_to_atom(Process)), [memory, message_queue_len,heap_size,total_heap_size]).	
	

run() ->
	Dispatch = fun(Record) ->
				Cid = proplists:get_value(id, Record),
				master_dist:dispatch({monitor, Cid, Record})
			end,
	
	spawn(fun() ->
		% AllCid = term:all_channel(),
		Sql = "select t2.id as tid, t2.address, t4.cityid, t3.code as protocol, t1.* 
				from channels t1, term_station t2, protocols t3, areas t4
				where t1.channel_type =0 and t2.id=t1.station_id and t1.protocol_id = t3.id and t2.area_id = t4.id", 
		case emysql:sqlquery(Sql) of
	        {ok, Records} ->
				?ERROR("start run ~p: ~p ~n", [Sql, length(Records)]),
				try
					split_and_sleep(Records, 200, Dispatch),
					% lists:foreach(Dispatch, Records),
					?ERROR("finish run ~p: ~p ~n", [?MODULE, length(Records)])
				catch
					_:Err -> ?ERROR("dispatch error: ~p, ~p", [Err, erlang:get_stacktrace()])
				end;
	        {error, Reason}  ->
	            ?ERROR("start failure...~p",[Reason]),
	            []
		end
	end).		
	
		
	
	
node_config() ->
	spawn(fun() ->
			Sql = "select t3.id as cid, t1.ptype, t4.type, t1.key, t1.coef, t1.offset
					from term_measure t1, term_station t2, channels t3 , measure_types t4
					where t1.station_id=t2.id and t2.id=t3.station_id and t4.ptype=t1.ptype and t4.type is not null",
			case emysql:sqlquery(Sql) of
		        {ok, Records} ->
					?ERROR("start node config ~p: ~p ~n", [?MODULE, length(Records)]),
		            lists:foreach(fun node_config/1, Records),
		            ?ERROR("finish node config ~p: ~p ~n", [?MODULE, length(Records)]);
		        {error, Reason}  ->
		            ?ERROR("start failure...~p",[Reason]),
		            stop
			end
				
		end).	

node_config(Record) ->
	Type = proplists:get_value(type, Record),
	Cid = proplists:get_value(cid, Record),
	Key = proplists:get_value(key, Record),
	Ptype = proplists:get_value(ptype, Record),
	Coef = proplists:get_value(coef, Record),
	Offset = proplists:get_value(offset, Record),
	master_dist:dispatch({config, Cid, Key, [{ptype, Ptype}, {type, Type}, {coef, Coef}, {offset, Offset}]}).
		
	
ertdb_config() ->	
	spawn(fun() ->
			case master:ertdb(connect) of
				ok ->
					Sql = "select t3.id as cid, t1.* 
							from term_measure t1, term_station t2, channels t3 
							where t1.station_id=t2.id and t2.id=t3.station_id ",
					case emysql:sqlquery(Sql) of
				        {ok, Records} ->
							?ERROR("start ertdb config ~p: ~p ~n", [?MODULE, length(Records)]),
							% split_and_sleep(Records, 100, fun ertdb_config/1),
							lists:foreach(fun ertdb_config/1, Records),
				            ?ERROR("finish ertdb config ~p: ~p~n", [?MODULE, length(Records)]);
				        {error, Reason}  ->
				            ?ERROR("ertdb config failure...~p",[Reason]),
				            stop
					end;
					% master:ertdb(close);
				{error, Reason} ->
					?ERROR("ertdb connect error:~p", [Reason])
			end
		end).	
		
ertdb_config(Record) ->
	Key = proplists:get_value(key, Record, proplists:get_value(<<"key">>, Record)),
	Value = build_config(Record, []),
	Cmd = ["config", Key, Value],
	master:config(Cmd).		
	

split_and_sleep([], _N, _F) ->
    ok;
split_and_sleep(L, N, F) when(length(L) < N)->
	lists:foreach(F, L);
split_and_sleep(L, N, F) ->
	?ERROR("the rest :~p", [length(L)]),
	{L1, L2} = lists:split(N, L),
	lists:foreach(F, L1),
	timer:sleep(1000),
	split_and_sleep(L2, N, F).
	
sync() ->
	Dispatch = fun(Cid) ->
		master_dist:dispatch({sync, Cid})
	end,
	spawn(fun() -> 
		AllCid = term:all_channel(),
		?INFO("begin to dispatch ~p entries...", [length(AllCid)]),
		try
			lists:foreach(Dispatch, AllCid)
		catch
			_:Err -> ?ERROR("dispatch error: ~p", [Err])
		end
	end).	
	

%% test	
command(Cid, Key, Action, Order) ->
	Payload = [{cid, Cid}, {type, 46}, {params, [{key, Key}, {action, Action}, {order, Order}]}],
	master_dist ! {deliver, <<"command.inter">>, undefined, mochijson2:encode(Payload)} .	
	
send_data(Cid, Ip, Port, Key, Value) ->
	Params = [{data, [{Key, Value}]}, {ip, Ip}, {port, Port}],
	master_dist:send_data(list_to_integer(Cid), Params).
		

status() ->
    {InternalStatus, _ProvidedStatus} = init:get_status(),
    ?PRINT("Node ~p is ~p.", [node(), InternalStatus]),
    case lists:keysearch(master, 1, application:which_applications()) of
	false ->
		?PRINT_MSG("master is not running~n");
	{value,_Version} ->
		?PRINT_MSG("master is running~n")
    end.

	
build_config([], Acc) ->
	string:join([lists:concat([K, "=", strnum(V)]) || {K, V} <- Acc], ",");	
build_config([{vaild, Value}|Data], Acc) ->
	build_config(Data, [{vaild, Value}|Acc]);		 
build_config([{quality, Value}|Data], Acc) ->
	build_config(Data, [{quality, Value}|Acc]);		 	
build_config([{coef, Value}|Data], Acc) ->	
	build_config(Data, [{coef, Value}|Acc]);
build_config([{offset, Value}|Data], Acc) ->	
	build_config(Data, [{offset, Value}|Acc]);		 
build_config([{deviation, Value}|Data], Acc) ->	
	build_config(Data, [{dev, Value * 0.01}|Acc]);
build_config([{maxtime, Value}|Data], Acc) ->
	build_config(Data, [{maxtime, Value}|Acc]);	
build_config([{mintime, Value}|Data], Acc) ->
	build_config(Data, [{mintime, Value}|Acc]);		
build_config([{his_compress, Value}|Data], Acc) ->
	build_config(Data, [{compress, Value}|Acc]);	
build_config([{his_deviation, Value}|Data], Acc) ->
	build_config(Data, [{his_dev, Value * 0.01}|Acc]);			
build_config([{his_maxtime, Value}|Data], Acc) ->
	build_config(Data, [{his_maxtime, Value}|Acc]);	
build_config([{his_mintime, Value}|Data], Acc) ->
	build_config(Data, [{his_mintime, Value}|Acc]);			

build_config([{<<"vaild">>, Value}|Data], Acc) ->
	build_config(Data, [{vaild, Value}|Acc]);		 
build_config([{<<"quality">>, Value}|Data], Acc) ->
	build_config(Data, [{quality, Value}|Acc]);		 	
build_config([{<<"coef">>, Value}|Data], Acc) ->	
	build_config(Data, [{coef, Value}|Acc]);
build_config([{<<"offset">>, Value}|Data], Acc) ->	
	build_config(Data, [{offset, Value}|Acc]);		 
build_config([{<<"deviation">>, Value}|Data], Acc) ->	
	build_config(Data, [{dev, extbif:to_integer(Value) * 0.01}|Acc]);
build_config([{<<"maxtime">>, Value}|Data], Acc) ->
	build_config(Data, [{maxtime, Value}|Acc]);	
build_config([{<<"mintime">>, Value}|Data], Acc) ->
	build_config(Data, [{mintime, Value}|Acc]);		
build_config([{<<"his_compress">>, Value}|Data], Acc) ->
	build_config(Data, [{compress, Value}|Acc]);	
build_config([{<<"his_deviation">>, Value}|Data], Acc) ->
	build_config(Data, [{his_dev, extbif:to_integer(Value) * 0.01}|Acc]);			
build_config([{<<"his_maxtime">>, Value}|Data], Acc) ->
	build_config(Data, [{his_maxtime, Value}|Acc]);	
build_config([{<<"his_mintime">>, Value}|Data], Acc) ->
	build_config(Data, [{his_mintime, Value}|Acc]);		

build_config([_|Data], Acc) ->
	build_config(Data, Acc).	
		
	
strnum(V) when is_integer(V) ->
    integer_to_list(V);
strnum(V) when is_float(V) ->
    [S] = io_lib:format("~.6f", [V]), S;
strnum(V) when is_binary(V) ->	
	binary_to_list(V);
strnum(Other) ->
	Other.
		
	
	
run2() ->
	Dispatch = fun(Record) ->
				Cid = proplists:get_value(id, Record),
				master_dist:dispatch({monitor, Cid, Record})
			end,
		
	CountSql = "select count(*) as count
			from channels t1, term_station t2, protocols t3, areas t4
           	where t1.channel_type =0 and t2.id=t1.station_id and t1.protocol_id = t3.id and t2.area_id = t4.id",	
			
	{ok, [Data]} = emysql:sqlquery(CountSql),		
	?ERROR("data: ~p", [Data]),	
	Count = proplists:get_value(count, Data),
	PoolSize = erlang:system_info(schedulers),
	?ERROR("PoolSize: ~p,~p", [Count, PoolSize]),
	
	Num = (Count div PoolSize) + 1,
			
	lists:foreach(fun(N) ->
		Start = (N -1) *  Num,
		?ERROR("start from :~p, num:~p ~n", [Start, Num]),
		spawn(fun() ->
			% AllCid = term:all_channel(),
			Sql = "select t2.id as tid, t2.address, t4.cityid, t3.code as protocol, t1.* 
					from channels t1, term_station t2, protocols t3, areas t4
					where t1.channel_type =0 and t2.id=t1.station_id and t1.protocol_id = t3.id and t2.area_id = t4.id
					order by t1.id " ++ lists:concat(["limit ", Num, " offset ", Start]),
			case emysql:sqlquery(Sql) of
		        {ok, Records} ->
					?ERROR("start run ~p: ~p ~n", [Sql, length(Records)]),
					try
						lists:foreach(Dispatch, Records)
					catch
						_:Err -> ?ERROR("dispatch error: ~p, ~p", [Err, erlang:get_stacktrace()])
					end,
		            ?ERROR("finish run ~p: ~p ~n", [?MODULE, length(Records)]);
		        {error, Reason}  ->
		            ?ERROR("start failure...~p",[Reason]),
		            []
			end
		end)		
	end, lists:seq(1, PoolSize) ).	
	
	
	