%%%----------------------------------------------------------------------
%%% File    : extend104_frame.erl
%%% Author  : Ery Lee <ery.lee@gmail.com>
%%% Purpose : Parse and serialise extend104 frame.
%%% Created : Oct. 10 2013
%%% License : http://opengoss.com
%%%
%%% Copyright opengoss.com 2013 
%%%----------------------------------------------------------------------
-module(extend104_frame).

-include("extend104.hrl").

-include("extend104_frame.hrl").

-include_lib("elog/include/elog.hrl").

-import(extend104_util, [reverse_byte_value/1, reverse_byte_value2/1]).

-export([parse/1,
		serialise/1,
		process_asdu/1]).
		

parse(<<C1, C2, C3, C4, Payload/binary>>) ->
	#extend104_frame{c1=C1, c2=C2, c3=C3, c4=C4, payload=Payload}.

serialise(Frame) when is_record(Frame, extend104_frame) ->
	#extend104_frame{c1=C1, c2=C2, c3=C3, c4=C4, payload=Payload} = Frame,
	Len = size(Payload) + 4,
	<<16#68, Len, C1, C2, C3, C4, Payload/binary>>.
							
process_asdu(Frame = #extend104_frame{payload = <<>>}) ->
	?ERROR("empty ~p", [Frame]);
process_asdu(#extend104_frame{payload = <<Type,SQ:1,VSQ:7,COT:8,_COT:1/binary,Addr:2/binary,Data/binary>>}) ->
	ASDU = #extend104_asdu{type=Type, sq=SQ, vsq=VSQ, cot=COT, addr=extend104_util:reverse_byte(Addr), data=Data},
	case process_asdu(Type, ASDU) of
		ok -> ok;
		{datalist, DataList} ->
			?INFO("get asdu:~p,data length:~p, ~n ~p", [ASDU#extend104_asdu{data= <<>>}, length(DataList), DataList]),
			DataList1 = lists:map(fun({PAddr, Value}) ->
				MeasId = #measure_id{type=Type, no=reverse_byte_value(PAddr)},
				#measure{id= MeasId, station_no=VSQ, cot=COT, value = Value}
			end, DataList),
			{measure, DataList1}
	end.
	
			
% 初始化结束
process_asdu(?M_EI_NA_1, _ASDU) ->
	?INFO_MSG("sub station reset!");
	
% 100:总召确认 7	
process_asdu(?C_IC_NA_1, #extend104_asdu{cot= ?M_COT_ACTCON_1} = ASDU) ->
	?INFO("all confirm :~p",[ASDU]);	
% 100:总召结束 10
process_asdu(?C_IC_NA_1, #extend104_asdu{cot= ?M_COT_ACTTERM_1} = ASDU) ->
	?INFO("all over :~p",[ASDU]);	

% 101:计算量总召确认 7	
process_asdu(?C_CI_NA_1, #extend104_asdu{cot= ?M_COT_ACTCON_1} = ASDU) ->
	?INFO("all count confirm :~p",[ASDU]);	
% 101:计算量总召结束 10	
process_asdu(?C_CI_NA_1, #extend104_asdu{cot= ?M_COT_ACTTERM_1} = ASDU) ->
	?INFO("all count over:~p",[ASDU]);				

% 103:时钟同步确认 7
process_asdu(?C_CS_NA_1, #extend104_asdu{cot= ?M_COT_ACTCON_1} = ASDU) ->
	?INFO("all time confirm :~p",[ASDU]);		

% 1:单点NA
process_asdu(?M_SP_NA_1, ASDU) ->
	process_M_SP_NA(ASDU);
	
% 11:测量值--标度化值，与归一化相同处理
process_asdu(?M_ME_NB_1, ASDU) ->
	process_M_ME_NA(ASDU);
	
% 15:电能脉冲计数量帧
process_asdu(?M_IT_NA_1, ASDU) -> 
	process_M_IT_NA(ASDU);

process_asdu(Type, Payload) ->
	?ERROR("Unexepected ASDU: {~p, ~p}", [Type, Payload]).





% 1：M_SP_NA_1 遥信
process_M_SP_NA(#extend104_asdu{sq=0, data=Data}) ->
	process_M_SP_NA(0, Data, []);
process_M_SP_NA(#extend104_asdu{sq=1, data = <<PAddr:3/binary,Other/binary>>}) ->
	RPAddr = extend104_util:reverse_byte(PAddr),	
	[{RPAddr, process_M_SP_NA(1, Other, [])}].

% content
process_M_SP_NA(_SQ, <<>>, Acc) ->
	{datalist, Acc};
process_M_SP_NA(0, <<PAddr:3/binary, IV:1, NT:1, SB:1,BL:1,SPI:4,Other/binary>>, Acc) ->
	% ?INFO("get addr:~p,info :~p", [RPAddr, {IV,NT,SB,BL,SPI}]),
	process_M_SP_NA(0, Other, [{PAddr, {IV,NT,SB,BL,SPI}}|Acc]);
process_M_SP_NA(1, <<IV:1, NT:1, SB:1,BL:1,SPI:4,Other/binary>>, Acc) ->
	% ?INFO("get info :~p", [{IV,NT,SB,BL,SPI}]),
	process_M_SP_NA(1, Other, [{IV,NT,SB,BL,SPI}|Acc]).


% 11：M_ME_NA_1 遥测
process_M_ME_NA(#extend104_asdu{sq=0, data=Data}) ->
	process_M_ME_NA(0, Data, []);
process_M_ME_NA(#extend104_asdu{sq=1, data = <<PAddr:3/binary,Other/binary>>}) ->
	[{PAddr, process_M_ME_NA(1, Other, [])}].
	
process_M_ME_NA(_SQ, <<>>, Acc) ->
	{datalist, Acc};
process_M_ME_NA(0, <<PAddr:3/binary, Value:2/binary, IV:1, NT:1, SB:1,BL:1,OV:4,Other/binary>>, Acc) ->
	process_M_ME_NA(0, Other, [{PAddr, {reverse_byte_value2(Value),IV,NT,SB,BL,OV}}|Acc]);
process_M_ME_NA(1, <<Value:2/binary, IV:1, NT:1, SB:1,BL:1,OV:4,Other/binary>>, Acc) ->
	process_M_ME_NA(1, Other, [{reverse_byte_value2(Value),IV,NT,SB,BL,OV}|Acc]).

% 15：M_IT_NA_1	计数量
process_M_IT_NA(#extend104_asdu{sq=0, data=Data}) ->
	process_M_IT_NA(0, Data, []);
process_M_IT_NA(#extend104_asdu{sq=1, data = <<PAddr:3/binary,Other/binary>>}) ->
	[{PAddr, process_M_IT_NA(1, Other, [])}].
	
process_M_IT_NA(_, <<>>, Acc) ->
	{datalist, Acc};
process_M_IT_NA(0, <<PAddr:3/binary, Value:4/binary, IV:1, CA:1, CY:1,SQ:5,Other/binary>>, Acc) ->
	process_M_IT_NA(0, Other, [{PAddr, {reverse_byte_value(Value),IV,CA,CY,SQ}}|Acc]);
process_M_IT_NA(1, <<Value:4/binary, IV:1, CA:1, CY:1,SQ:5,Other/binary>>, Acc) ->
	process_M_IT_NA(1, Other, [{reverse_byte_value(Value),IV,CA,CY,SQ}|Acc]).	
