-module(extend104_connection).

-author("hejin 2013-10-26").

-include("extend104.hrl").

-include("extend104_frame.hrl").

-include_lib("elog/include/elog.hrl").

-export([start_link/2,
		status/1,
		send/2,
		subscribe/2,
		unsubscribe/2,
		command/2, command/3
		]).
		
-export([sync/1]).		

-behaviour(gen_server2).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-define(TCPOPTIONS, [binary, {packet, raw}, {active, true}]).
		%{backlog,   128},
		%{nodelay,   true},
		%{reuseaddr, true}]).

-define(TIMEOUT, 8000).

-record(state, {server, cid, tid, address, host, port, args, 
				socket, 
				conn_state ::  connected | start | disconnect,  
				rest= <<>>, 
				queue :: queue() | undefined,
				subscriber = [], 
				timer :: ref
				}).

-import(extbif, [to_list/1]).

sync(C) ->
	?INFO_MSG("begin to sync"),
	command(C, 'C_IC_NA_1', 20000),
	command(C, 'C_CI_NA_1', 20000),
	send(C, 'C_CS_NA_1').


start_link(Server, Args) ->
	gen_server2:start_link(?MODULE, [Server, Args], []).

status(C) when is_pid(C) ->
	gen_server2:call(C, status).	
	
subscribe(C, SPid) ->
	gen_server2:call(C, {subscribe, SPid}).	
	
unsubscribe(C, SPid) ->
	gen_server2:call(C, {unsubscribe, SPid}).		

-spec command(C :: pid(), Command :: {'C_DC_NA_1', list()}) -> ok.
command(C, Command)	->
	gen_server2:call(C, {command, Command}).
	
command(C, Command, Timeout)	->
	gen_server2:call(C, {command, Command, Timeout}, Timeout+1).	
	
	
-spec send(C :: pid(), Cmd :: 'STARTDT' | 'STOPDT' | 'C_IC_NA_1' | atom()) -> ok.
send(C, Req) when is_pid(C) and is_atom(Req) ->
	gen_server2:cast(C, {request, Req}).	

init([Server, Args]) ->
	?INFO("conn info:~p", [Args]),
    case (catch do_init(Server, Args)) of
	{error, Reason} ->
	    {stop, Reason};
	{ok, State} ->
		connect(State)
    end.
	
	
do_init(Server, Args) ->
	Cid = proplists:get_value(id, Args),
	Tid = proplists:get_value(tid, Args),
	Address = proplists:get_value(address, Args),
	Host = proplists:get_value(ip, Args),
	Port = proplists:get_value(port, Args),
	do_init_c(),
	{ok, #state{server=Server, cid=Cid, tid=Tid, address=Address, host=to_list(Host), port=Port, args=Args} }.	
	
do_init_c() ->
	put(recv_c,0),
	put(send_c,0),
	put(ser_send_cn,{0,0}),
	put(ser_recv_cn,{0,0}).		

connect(State = #state{server=Server, cid=Cid, host=Host, port=Port}) ->
	?INFO("begin to conn:~p",[State]),
    case gen_tcp:connect(Host, Port, ?TCPOPTIONS, ?TIMEOUT) of 
    {ok, Sock} ->
		?INFO("~p:~p is connected.", [Host, Port]),
		send(self(), 'STARTDT'),
		Server ! {status, Cid, connected},
		{ok, State#state{socket = Sock, conn_state = connected, queue = queue:new()}};
    {error, Reason} ->
		?ERROR("failed to connect ~p:~p, error: ~p.", [Host, Port, Reason]),
		Server ! {status, Cid, disconnect},
		erlang:send_after(30000, self(), reconnect),
        {ok, State#state{socket = null, conn_state = disconnect}}
    end.


handle_call(status, _From, State) ->
    {reply, {ok, State}, State};
	
handle_call({command, Command, Timeout}, From, #state{conn_state=ConnState} = State) ->
	case ConnState of
		start ->
			try handle_cmd(Command, State) of
				{error, Reason} = Error ->
					{reply, Error, State};	
				{list, [Cmd|Cmds]} ->
					?ERROR("command send multi cmd:~p", [Cmd]),
					Resp = do_request(Cmd, From, State),
					[send_frame(C, State) || C <- Cmds],
					Resp;	
				Cmd ->
					?ERROR("command send cmd:~p", [Cmd]),
		    		do_request(Cmd, From, State)
			catch Error:Reason -> 
				?ERROR("handle command error:~p", [Reason]),
				{reply, {error, cmd_error}, State}
			end;
		_ ->
			{reply, {error, ConnState}, State}
	end;			
	
handle_call({subscribe, SPid}, _From, #state{conn_state=ConnState, subscriber=Subs}=State) ->
	case ConnState of
		disconnect ->
			{reply, {error, disconnect}, State};
		_ ->
			{reply, ok, State#state{subscriber=[SPid|Subs]}}
	end;	

handle_call({unsubscribe, SPid}, _From, #state{conn_state=ConnState, subscriber=Subs}=State) ->
	case ConnState of
		disconnect ->
			{reply, {error, disconnect}, State};
		_ ->
			{reply, ok, State#state{subscriber=[SP||SP <- Subs, SP =/= SPid]}}
	end;					

handle_call(stop, _From, State) ->
    ?INFO("received stop request", []),
    {stop, normal, State};

handle_call(Req, _From, State) ->
    ?WARNING("unexpect request: ~p,~p", [Req, State]),
    {reply, {error, {invalid_request, Req}}, State}.
	
	
handle_cast({request, Req}, #state{conn_state=start} = State) ->
	Cmd = handle_cmd(Req, State),
    send_frame(Cmd, State),
    {noreply, State};

handle_cast(Msg, #state{conn_state=ConnState} = State) ->
    ?WARNING("unexpected message: ~p~n~p", [Msg, ConnState]),
    {noreply, State}.
	
handle_info({tcp, _Sock, Data}, #state{rest=Rest, timer=LastTimer}=State) ->
	?INFO("get msg lenth:~p, ~p",[size(Data), Data]),
	NewState = check_frame(list_to_binary([Rest, Data]), State),
	if LastTimer == undefined -> ok;
		true -> erlang:cancel_timer(LastTimer)
	end,	
	Timer = erlang:start_timer(20000, self(), heartbeat),
    {noreply, NewState#state{timer = Timer}};

handle_info({tcp_closed, Sock}, State=#state{socket=Sock}) ->
	?ERROR_MSG("tcp closed."),
	% TODO reconnect
	do_init_c(),
	{ok, NState} =  connect(State),
    {noreply, NState};
	
handle_info({tcp_error, _Socket, _Reason}, State) ->
    %% This will be followed by a close
    {noreply, State};	

handle_info(reconnect, State) ->
	{ok, NState} =  connect(State),
    {noreply, NState};

handle_info({timeout, _Timer, heartbeat}, State) ->
	send_frame(?FRAME_TESTFR_SEND, State),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%---------------- fun ------------------%%	
do_request(Cmd, From, State) ->
    case send_frame(Cmd, State) of
        true ->
			?INFO("after send :~p", [Cmd]),
		    % Msg = {command_timeout, NextReqId, From},		    
		    % Ref = erlang:send_after(Timeout, self(), Msg),
            NewQueue = queue:in({1, From, Cmd}, State#state.queue),
            {noreply, State#state{queue = NewQueue}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.
	

% 启动
handle_cmd('STARTDT', State) ->
	?FRAME_STARTDT;
% 停止
handle_cmd('STOPDT', State) ->
	?FRAME_STOPDT;
% 总召 100
handle_cmd('C_IC_NA_1', #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	?FRAME_100(BCid);
% 计量总召 101
handle_cmd('C_CI_NA_1', #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	?FRAME_101(BCid);
% 时钟同步 103
handle_cmd('C_CS_NA_1', #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	?FRAME_103(BCid);
		

% 双点遥控 46
handle_cmd({'C_DC_NA_1', Data}, State) ->
	handle_cmd({46, Data}, State);
handle_cmd({46, Data}, #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	
	Key = extbif:to_list(proplists:get_value(<<"key">>, Data)),	
	[_, _, Maddr] =  string:tokens(Key, ":"),
	Maddr2 = extend104_util:reverse_int_value(extbif:to_integer(Maddr), 3),
	F = fun(SE) ->
			DCS = extbif:to_integer(proplists:get_value(<<"order">>, Data)),	
			?FRAME_46(6, BCid, Maddr2, <<SE:1,0:5,DCS:2>>)
		end,	
	case proplists:get_value(<<"action">>, Data) of
		<<"cancel">> -> 
			DCS = extbif:to_integer(proplists:get_value(<<"order">>, Data)),	
			?FRAME_46(8, BCid, Maddr2, <<0:1,0:5,DCS:2>>);
		<<"select">> -> F(1);
		<<"exec">> -> F(0);
		_ -> ok
	end;	
	
	
% 设点命令 52
handle_cmd({'C_SE_NA_1Ex', Data}, State) ->
	handle_cmd({52, Data}, State);
handle_cmd({52, Data}, #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	Key = extbif:to_list(proplists:get_value(<<"key">>, Data)),	
	[_, _, Maddr] =  string:tokens(Key, ":"),
	Maddr2 = extend104_util:reverse_int_value(extbif:to_integer(Maddr), 3),
	F = fun(SE) ->
			DATA = extbif:to_integer(proplists:get_value(<<"data">>, Data)),	
			?FRAME_52(6, BCid, Maddr2, DATA, SE)
		end,	
	case proplists:get_value(<<"action">>, Data) of
		<<"cancel">> -> 
			?FRAME_52(8, BCid, Maddr2, 0, 0);
		<<"select">> -> F(1);
		<<"exec">> -> F(0);
		_ -> ok
	end;
	
% 设点命令 55
handle_cmd({'C_SE_MA_Ex', Data}, State) ->
	handle_cmd({55, Data}, State);
handle_cmd({55, Data}, #state{address=Address}=State) ->
	BCid = extend104_util:reverse_int_value(Address),
	DATAS = string:token(proplists:get_value(<<"datas">>, Data), ","),	
	DataList = split_data(DATAS, 60, []),
	MI = if(length(DataList) == 1) ->  0;
			true ->  1
		end,	
	{list, lists:mapfoldl(fun(DS, Num) ->
		OV = if(Num == length(DataList)) -> 1;
				true -> 0
			 end,
		IN = Num, 	 	
		BDS = list_to_binary([<<D:32/float>> || D <- DS]),
		{?FRAME_55(6, BCid, MI, OV, IN, BDS), Num+1}
	end, 1, DataList) };
	
	
handle_cmd(Req, State) ->
	?ERROR("badreq: ~p", [Req]),
	{error, {unsupport_cmd, Req}}.
	

split_data(Datas, N, Acc) when length(Datas) >= N ->
	{Data, Rest} = lists:split(N, Datas),
	split_data(Rest, N, [Data|Acc]);
split_data(Datas, N, Acc) ->
	lists:reverse([Datas|Acc]).	
	
% send_cn is current = last s_recv_cn, recv_cn is next = last s_send_cn + 1
send_frame(Frame, #state{conn_state = start} = State) ->
	SendFrame = 
		case Frame of
			?FRAME_STARTDT -> Frame;
			?FRAME_STOPDT -> Frame;
			?FRAME_TESTFR_SEND -> Frame;
			?FRAME_TESTFR_REPLY -> Frame;
			#extend104_frame{c1=1,c2=0} -> Frame;
			_ ->
				{RC1,RC2} = case get(send_c) of
						 	0 -> {0, 0} ;
							_ ->
								extend104_util:add_cn(get(ser_send_cn))
							end,	
				put_c(send_c, get(send_c) + 1),
				{SC1,SC2} = get(ser_recv_cn),
				?INFO("send_c:~p, send_cn:~p", [{get(send_c), {RC1,RC2}, count_to_curr_c(get(send_c))}, {SC1,SC2}]),
				Frame#extend104_frame{c1=SC1,c2=SC2,c3=RC1,c4=RC2}
		end,	
	do_send_frame(SendFrame, State);
send_frame(Frame, #state{conn_state = ConnState} = State) ->	
	{error, ConnState}.
	
	
do_send_frame(Frame, #state{cid=Cid, socket = Sock,subscriber=Subs}) when is_record(Frame, extend104_frame) ->
	?INFO("send msg:~p", [extend104_frame:serialise(Frame)]),
	[SPid ! {frame, Cid, {send, calendar:local_time(), Frame}} ||SPid <- Subs],
    erlang:port_command(Sock, extend104_frame:serialise(Frame)).	
		
	
check_frame(<<>>, State) -> State#state{rest = <<>>};		
check_frame(<<16#68,L,Data/binary>> = Frames, State) ->
	if L =< size(Data) ->
		{FrameData, Rest} = split_binary(Data, L),
		NesState = recv_frame(FrameData, State),
		check_frame(Rest, NesState);	
	true ->
		State#state{rest = Frames}
	end;		
check_frame(Rest, State) ->
	?ERROR("get error msg:~p",[Rest]), 
	State#state{rest = <<>>}.		
	
recv_frame(FrameData, #state{cid=Cid, subscriber=Subs}=State) ->
	Frame = extend104_frame:parse(FrameData),
	[SPid ! {frame, Cid, {recv, calendar:local_time(), Frame} } ||SPid <- Subs],
	process_frame(Frame, State).	
		

process_frame(#extend104_frame{c1 = C1} = Frame, State) ->
	?INFO("Received: ~p", [Frame]),
	Tag1 = C1 band 16#01,	
	Tag2 = C1 band 16#03,
	if
	Tag1 == 0 -> 
		process_apci_i(Frame, State);
	Tag2 == 1 ->
		process_apci_s(Frame),
		State;
	Tag2 == 3 ->
		process_apci_u(Frame, State),
		State;
	true ->
		?ERROR("unsupport apci....~p", [Frame]),
		State
	end.

	% 校验请求，接收数		
process_apci_s(Frame) ->
	?INFO("get apci_s :~p",[Frame]).

	% 启动返回和心跳发送接受
process_apci_u(?FRAME_TESTFR_SEND, State) ->
	send_frame(?FRAME_TESTFR_REPLY, State),
	State;
process_apci_u(?FRAME_TESTFR_REPLY, State) ->
	State;	
process_apci_u(?FRAME_STARTDT_END, State=#state{server=Server, cid=Cid}) ->	
	Server ! {status, Cid, start},
	State#state{conn_state = start};
process_apci_u(Frame, State) -> %<<TESTFR:2,STOPDT:2,STARTDT:2,_:2>>
	% STOPDT = (C1 bsr 4) band 2#11,	
	% STARTDT = (C1 bsr 2) band 2#11,
	?INFO("get apci_u:~p",[Frame]),
	State.
	
process_apci_i(Frame, State) ->
	put(ser_send_cn, {Frame#extend104_frame.c1, Frame#extend104_frame.c2}),	
	put(ser_recv_cn, {Frame#extend104_frame.c3, Frame#extend104_frame.c4}),
	confirm_frame(State),
	DateTime = extbif:timestamp(),
	case extend104_frame:process_asdu(Frame) of
		ok -> State;
		{response, Res} ->
			NewQueue = reply(Res, State),
			State#state{queue = NewQueue};
		{measure, DataList} ->
			handle_data({measure, DateTime, DataList}, State),
			State
	end.		

reply(Res, #state{queue = Queue} = State) ->
    case queue:out(Queue) of
        {{value, {1, From, Cmd}}, NewQueue} ->
			?INFO("reply:~p, ~p", [Cmd, Res]),
			Resp = handle_response(Res, Cmd),
            safe_reply(From, Resp),
            NewQueue;
        {{value, {1, From, Cmd, Replies}}, NewQueue} ->
            safe_reply(From, lists:reverse([Res | Replies])),
            NewQueue;
        {{value, {N, From, Cmd, Replies}}, NewQueue} when N > 1 ->
            queue:in_r({N - 1, From, [Res | Replies]}, NewQueue);
        {empty, Queue} ->
            %% Oops
            ?ERROR("Nothing in queue, but got value from parser:~p", [Res]),
            Queue
    end.

handle_response({status, S}, _Cmd) ->	
	{status, S};
handle_response({result, R}, _Cmd) ->
	{result, R};
handle_response({data, RCot, RData}, #extend104_frame{payload = <<Type, SQ, SCot, _:3/binary, SData/binary>>}) ->		
	case {SCot+1, SData}  of
		{RCot, RData} ->
			{result, 1};
		_ ->
			?ERROR("command result fail, send:~p, recv:~p", [{SCot, SData}, {RCot, RData}]),
			{result, 0}
	end;
handle_response(Other, Cmd) ->
	?ERROR("unsupport response :~p, ~p", [Other, Cmd]).				
	
safe_reply(undefined, _Value) ->
    ok;
safe_reply(From, Value) ->
    gen_server:reply(From, Value).
	

handle_data({measure, DateTime, DataList}, #state{tid=Tid}) ->
	?INFO("get measure from tid:~p",[Tid]),
	extend104_hub:send_datalog({measure, Tid, DateTime, DataList}).


% special send
confirm_frame(State) ->
	RC = get(recv_c) + 1,
	if (RC rem 8) == 0 ->
		RCn = count_to_next_c(RC),
		ExpRecvCn = {L,H} = extend104_util:add_cn(get(ser_send_cn)),
		FrameConfirm = ?FRAME_CONFIRM#extend104_frame{c3=L, c4=H},
		?INFO("confirm recv_c:~p, exp_recv_cn:~p", [{RC, RCn}, ExpRecvCn]),
		send_frame(FrameConfirm, State);
	true ->
		ok
	end,		
	put_c(recv_c, RC).	
	
	
% begin with get->0, put->0	
put_c(Type, Value) ->
	V = if Value > 32767 -> 0;
		true -> Value
		end,
	put(Type, V).	
	
% for current cn (1 -> 0,0| 2 -> 2,0| 3 -> 4,0)	
count_to_curr_c(C) ->
	count_to_next_c(C-1).	
% for next cn [recv|send] (1 -> 2,0| 2 -> 4,0| 3 -> 6,0)	
count_to_next_c(C) ->
	C3 = (C band 16#FF) bsl 1 ,
	C4 = (C bsr 8),	
	{C3, C4}.
	
	