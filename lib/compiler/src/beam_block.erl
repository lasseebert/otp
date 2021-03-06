%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1999-2018. All Rights Reserved.
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
%%
%% %CopyrightEnd%
%%
%% Purpose: Partition BEAM instructions into basic blocks.

-module(beam_block).

-export([module/2]).
-import(lists, [reverse/1,splitwith/2]).

-spec module(beam_utils:module_code(), [compile:option()]) ->
                    {'ok',beam_utils:module_code()}.

module({Mod,Exp,Attr,Fs0,Lc}, _Opts) ->
    Fs = [function(F) || F <- Fs0],
    {ok,{Mod,Exp,Attr,Fs,Lc}}.

function({function,Name,Arity,CLabel,Is0}) ->
    try
        Is1 = blockify(Is0),
        Is = embed_lines(Is1),
        {function,Name,Arity,CLabel,Is}
    catch
        Class:Error:Stack ->
	    io:fwrite("Function: ~w/~w\n", [Name,Arity]),
	    erlang:raise(Class, Error, Stack)
    end.

%% blockify(Instructions0) -> Instructions
%%  Collect sequences of instructions to basic blocks.
%%  Also do some simple optimations on instructions outside the blocks.

blockify(Is) ->
    blockify(Is, []).

blockify([{loop_rec,{f,Fail},{x,0}},{loop_rec_end,_Lbl},{label,Fail}|Is], Acc) ->
    %% Useless instruction sequence.
    blockify(Is, Acc);
blockify([I|Is0]=IsAll, Acc) ->
    case collect(I) of
	error -> blockify(Is0, [I|Acc]);
	Instr when is_tuple(Instr) ->
	    {Block,Is} = collect_block(IsAll),
	    blockify(Is, [{block,Block}|Acc])
    end;
blockify([], Acc) -> reverse(Acc).

collect_block(Is) ->
    collect_block(Is, []).

collect_block([{allocate,N,R}|Is0], Acc) ->
    {Inits,Is} = splitwith(fun ({init,{y,_}}) -> true;
                               (_) -> false
                           end, Is0),
    collect_block(Is, [{set,[],[],{alloc,R,{nozero,N,0,Inits}}}|Acc]);
collect_block([I|Is]=Is0, Acc) ->
    case collect(I) of
	error -> {reverse(Acc),Is0};
	Instr -> collect_block(Is, [Instr|Acc])
    end;
collect_block([], Acc) ->
    {reverse(Acc),[]}.

collect({allocate,N,R})      -> {set,[],[],{alloc,R,{nozero,N,0,[]}}};
collect({allocate_zero,N,R}) -> {set,[],[],{alloc,R,{zero,N,0,[]}}};
collect({allocate_heap,Ns,Nh,R}) -> {set,[],[],{alloc,R,{nozero,Ns,Nh,[]}}};
collect({allocate_heap_zero,Ns,Nh,R}) -> {set,[],[],{alloc,R,{zero,Ns,Nh,[]}}};
collect({init,D})            -> {set,[D],[],init};
collect({test_heap,N,R})     -> {set,[],[],{alloc,R,{nozero,nostack,N,[]}}};
collect({bif,N,F,As,D})      -> {set,[D],As,{bif,N,F}};
collect({gc_bif,N,F,R,As,D}) -> {set,[D],As,{alloc,R,{gc_bif,N,F}}};
collect({move,S,D})          -> {set,[D],[S],move};
collect({put_list,S1,S2,D})  -> {set,[D],[S1,S2],put_list};
collect({put_tuple,A,D})     -> {set,[D],[],{put_tuple,A}};
collect({put,S})             -> {set,[],[S],put};
collect({get_tuple_element,S,I,D}) -> {set,[D],[S],{get_tuple_element,I}};
collect({set_tuple_element,S,D,I}) -> {set,[],[S,D],{set_tuple_element,I}};
collect({get_hd,S,D})  ->       {set,[D],[S],get_hd};
collect({get_tl,S,D})  ->       {set,[D],[S],get_tl};
collect(remove_message)      -> {set,[],[],remove_message};
collect({put_map,F,Op,S,D,R,{list,Puts}}) ->
    {set,[D],[S|Puts],{alloc,R,{put_map,Op,F}}};
collect({'catch'=Op,R,L}) ->
    {set,[R],[],{try_catch,Op,L}};
collect({'try'=Op,R,L}) ->
    {set,[R],[],{try_catch,Op,L}};
collect(fclearerror)         -> {set,[],[],fclearerror};
collect({fcheckerror,{f,0}}) -> {set,[],[],fcheckerror};
collect({fmove,S,D})         -> {set,[D],[S],fmove};
collect({fconv,S,D})         -> {set,[D],[S],fconv};
collect(_)                   -> error.

%% embed_lines([Instruction]) -> [Instruction]
%%  Combine blocks that would be split by line/1 instructions.
%%  Also move a line instruction before a block into the block,
%%  but leave the line/1 instruction after a block outside.

embed_lines(Is) ->
    embed_lines(reverse(Is), []).

embed_lines([{block,B2},{line,_}=Line,{block,B1}|T], Acc) ->
    B = {block,B1++[{set,[],[],Line}]++B2},
    embed_lines([B|T], Acc);
embed_lines([{block,B1},{line,_}=Line|T], Acc) ->
    B = {block,[{set,[],[],Line}|B1]},
    embed_lines([B|T], Acc);
embed_lines([I|Is], Acc) ->
    embed_lines(Is, [I|Acc]);
embed_lines([], Acc) -> Acc.
