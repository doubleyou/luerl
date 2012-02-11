%% Copyright (c) 2012 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%% File    : luerl_eval.erl
%% Author  : Robert Virding
%% Purpose : A very basic LUA 5.2 interpreter.

%% This interpreter works straight off the AST and does not do any
%% form of compilation. Which it really should.

-module(luerl_eval).

-export([init/0,chunk/2,gc/1]).

%% Internal functions which can be useful "outside".
-export([functioncall/3,getmetamethod/3,getmetamethod/4]).

-include("luerl.hrl").

%% -define(DP(F,As), io:format(F, As)).
-define(DP(F, A), ok).

%% init() -> State.
%% Initialise the basic state.

init() ->
    St0 = #luerl{env=[],sub=false},
    %% Initialise the table handling.
    St1 = St0#luerl{tabs=orddict:new(),free=[],next=0},
    %% Allocate the _G table and initialise the environment
    Basic = orddict:from_list(luerl_basic:table()),
    {_G,St2} = alloc_env(Basic, St1),		%Allocate base environment
    St3 = push_env(_G, St2),
    St4 = set_local_name('_G', _G, St3),	%Set _G to itself
    %% Add the other standard libraries.
%%     St5 = alloc_libs([{<<"math">>,luerl_math},
%% 		      {<<"os">>,luerl_os},
%% 		      {<<"string">>,luerl_string}], St4),
    St5 = alloc_libs([{<<"os">>,luerl_os}], St4),
    St5.

alloc_libs(Libs, St) ->
    Fun = fun ({Key,Mod}, St0) ->
		  D = orddict:from_list(Mod:table()), %To be safe
		  {T,St1} = alloc_table(D, St0),
		  set_local_key(Key, T, St1)
	  end,
    lists:foldl(Fun, St, Libs).

%% alloc_env(State) -> {Env,State}.
%% alloc_env(InitialTab, State) -> {Env,State}.
%% push_env(Env, State) -> {Env,State}.
%% pop_env(State) -> State.

alloc_env(St) -> alloc_env(orddict:new(), St).

alloc_env(Itab, St) -> alloc_table(Itab, St).

push_env({table,_}=T, #luerl{env=Es}=St) ->
    St#luerl{env=[T|Es]}.

pop_env(#luerl{env=[_|Es]}=St) ->
    St#luerl{env=Es}.

%% alloc_table(State) -> {Table,State}.
%% alloc_table(InitialTable, State) -> {Table,State}.
%% free_table(Table, State) -> State.

alloc_table(St) -> alloc_table(orddict:new(), St).

alloc_table(Itab, #luerl{tabs=Ts0,free=[N|Ns]}=St) ->
    Ts1 = orddict:store(N, {Itab,nil}, Ts0),
    {{table,N},St#luerl{tabs=Ts1,free=Ns}};
alloc_table(Itab, #luerl{tabs=Ts0,free=[],next=N}=St) ->
    Ts1 = orddict:store(N, {Itab,nil}, Ts0),
    {{table,N},St#luerl{tabs=Ts1,next=N+1}}.

free_table({table,N}, #luerl{tabs=Ts0,free=Ns}=St) ->
    Ts1 = orddict:erase(N, Ts0),
    St#luerl{tabs=Ts1,free=[N|Ns]}.

%% set_table_name(Name, Value, Table, State) -> State.
%% set_table_key(Key, Value, Table, State) -> State.
%% get_table_name(Name, Table, State) -> {Val,State}.
%% get_table_key(Key, Table, State) -> {Val,State}.
%%  Access tables, as opposed to the environment (which are also
%%  tables). Setting a value to 'nil' will clear it from the table.

set_table_name(Name, Val, Tab, St) ->
    set_table_key(atom_to_binary(Name, latin1), Val, Tab, St).

set_table_key(Key, Val, {table,N}, #luerl{tabs=Ts0}=St) ->
    {Tab0,Met} = orddict:fetch(N, Ts0),		%Get the table
    case orddict:find(Key, Tab0) of
	{ok,_} ->
	    Tab1 = if Val =:= nil -> orddict:erase(Key, Tab0);
		      true -> orddict:store(Key, Val, Tab0)
		   end,
	    Ts1 = orddict:store(N, {Tab1,Met}, Ts0),
	    St#luerl{tabs=Ts1};
	error ->
	    case getmetamethod_tab(Met, <<"__newindex">>, Ts0) of
		nil ->
		    Tab1 = orddict:store(Key, Val, Tab0),
		    Ts1 = orddict:store(N, {Tab1,Met}, Ts0),
		    St#luerl{tabs=Ts1};
		Meta when element(1, Meta) =:= function ->
		    functioncall(Meta, [Key,Val], St);
		Meta -> set_table_key(Key, Val, Meta, St)
	    end
    end.

%% set_table_key(Key, Val, {table,N}, #luerl{tabs=Ts0}=St) ->
%%     Upd = if Val =:= nil -> fun ({T,M}) -> {orddict:erase(Key, T),M} end;
%% 	     true -> fun ({T,M}) -> {orddict:store(Key, Val, T),M} end
%% 	  end,
%%     Ts1 = orddict:update(N, Upd, Ts0),
%%     St#luerl{tabs=Ts1}.

get_table_name(Name, Tab, St) ->
    get_table_key(atom_to_binary(Name, latin1), Tab, St).

get_table_key(K, {table,N}=T, #luerl{tabs=Ts}=St) ->
    {Tab,Met} = orddict:fetch(N, Ts),		%Get the table.
    case orddict:find(K, Tab) of
	{ok,Val} -> {Val,St};
	error ->
	    %% Key not present so try metamethod
	    case getmetamethod_tab(Met, <<"__index">>, Ts) of
		nil -> {nil,St};
		Meta when element(1, Meta) =:= function ->
		    {Vs,St1} = functioncall(Meta, [T,K], St),
		    {first_value(Vs),St1};	%Only one value
		Meta -> get_table_key(K, Meta, St)
	    end
    end;
get_table_key(_, _, St) -> {nil,St}.		%Key can never be present

%% set_local_name(Name, Val, State) -> State.
%% set_local_key(Key, Value, State) -> State.
%% set_local_keys(Keys, Values, State) -> State.
%%  Set variable values in the local environment. Variables are not
%%  cleared when their value is set to 'nil' as this would remove the
%%  local variable.

set_local_name(Name, Val, St) ->
    set_local_key(atom_to_binary(Name, latin1), Val, St).

set_local_name_env(Name, Val, Ts, Env) ->
    set_local_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_local_key(Key, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    Ts1 = set_local_key_env(Key, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_local_key_env(K, Val, Ts, [{table,E}|_]) ->
    Store = fun ({T,M}) -> {orddict:store(K, Val, T),M} end,
    orddict:update(E, Store, Ts).

set_local_keys(Ks, Vals, #luerl{tabs=Ts0,env=[{table,E}|_]}=St) ->
    Store = fun ({T,M}) -> {set_local_keys_tab(Ks, Vals, T),M} end,
    Ts1 = orddict:update(E, Store, Ts0),
    St#luerl{tabs=Ts1}.

set_local_keys_tab([K|Ks], [Val|Vals], T0) ->
    T1 = orddict:store(K, Val, T0),
    set_local_keys_tab(Ks, Vals, T1);
set_local_keys_tab([K|Ks], [], T0) ->
    T1 = orddict:store(K, nil, T0),		%Default value nil
    set_local_keys_tab(Ks, [], T1);
set_local_keys_tab([], _, T) -> T.		%Ignore extra values

%% set_name(Name, Val, State) -> State.
%% get_name(Name, State) -> Val.
%% set_key(Key, Value, State) -> State.
%% get_key(Key, State) -> Value.
%%  Set/get variable values in the environment tables. Variables are
%%  not cleared when their value is set to 'nil' as this would move
%%  them in the envornment stack..

set_name(Name, Val, St) ->
    set_key(atom_to_binary(Name, latin1), Val, St).

get_name(Name, St) -> get_key(atom_to_binary(Name, latin1), St).

set_name_env(Name, Val, Ts, Env) ->
    set_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_key(K, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    Ts1 = set_key_env(K, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_key_env(K, Val, Ts, [{table,_G}]) ->	%Top table _G
    Store = fun ({T,M}) -> {orddict:store(K, Val, T),M} end,
    orddict:update(_G, Store, Ts);
set_key_env(K, Val, Ts, [{table,E}|Es]) ->
    {Tab,_} = orddict:fetch(E, Ts),		%Find the table
    case orddict:is_key(K, Tab) of
	true ->
	    Store = fun ({T,M}) -> {orddict:store(K, Val, T),M} end,
	    orddict:update(E, Store, Ts);
	false -> set_key_env(K, Val, Ts, Es)
    end.

get_key(K, #luerl{tabs=Ts,env=Env}) ->
    get_key_env(K, Ts, Env).

get_key_env(K, Ts, [{table,E}|Es]) ->
    {Tab,_} = orddict:fetch(E, Ts),		%Get environment table
    case orddict:find(K, Tab) of		%Check if variable in the env
	{ok,Val} -> Val;
	error -> get_key_env(K, Ts, Es)
    end;
get_key_env(_, _, []) -> nil.			%The default value

%% chunk(Stats, State) -> {Return,State}.

chunk(Stats, St0) ->
    {Ret,St1} = block(Stats, St0),
    %% Should do GC here.
    {Ret,St1}.

%% block(Stats, State) -> {Return,State}.
%% A block creates a new local environment which we would like to
%% remove afterwards. We can only do this if there are no local
%% functions defined within this block or sub-blocks. The 'sub' field
%% is set to 'true' when this occurs.

block([], St) -> St;				%Empty block, do nothing
block(Stats, St) ->
    Do = fun (S) -> stats(Stats, S) end,
    in_block(Do, St).

%% in_block(Do, State) -> {Return,State}.
%% A block creates a new local environment which we would like to
%% remove afterwards. We can only do this if there are no local
%% functions defined within this block or sub-blocks. The 'sub' field
%% is set to 'true' when this occurs.

in_block(Do, St0) ->
    Sub0 = St0#luerl.sub,			%"Global" sub value
    ?DP("B: ~p\n", [St0]),
    {T,St1} = alloc_env(St0),			%Allocate the local table
    St2 = push_env(T, St1),			%Put it in the environment
    {Ret,St3} = Do(St2#luerl{sub=false}),	%Do its thing
    Sub1 = St3#luerl.sub,			%"Local" sub value
    ?DP("B-> ~p\n", [St3]),
    ?DP("Freeing table ~p: ~p\n", [T,not Sub1]),
    St4  = case Sub1 of				%Check if we can free table
	       true -> pop_env(St3);
	       false -> pop_env(free_table(T, St3))
	   end,
    ?DP("B-> ~p\n", [{Ret,Sub1 or Sub0}]),
    {Ret,St4#luerl{sub=Sub1 or Sub0}}.

stats([{assign,_,Vs,Es}|Ss], St0) ->
    St1 = assign(Vs, Es, St0),
    stats(Ss, St1);
stats([{return,_,Es}], St0) ->			%Not properly done yet
    {Vals,St1} = explist(Es, St0),
    {Vals,St1};
stats([{label,_,_}|_], _) ->			%Don't implement this yet
    error({undefined_op,label});
stats([{break,_}|_], _) ->			%Don't implement this yet
    error({undefined_op,break});
stats([{goto,_,_}|_], _) ->			%Don't implement this yet
    error({undefined_op,goto});
stats([{block,_,B}|Ss], St0) ->
    {_,St1} = block(B, St0),
    stats(Ss, St1);
stats([{functiondef,L,Fname,Ps,B}|Ss], St0) ->
    St1 = set_var(Fname, {function,L,St0#luerl.env,Ps,B}, St0),
    stats(Ss, St1#luerl{sub=true});
stats([{'while',_,Exp,Body}|Ss], St0) ->
    St1 = do_while(Exp, Body, St0),
    stats(Ss, St1);
stats([{repeat,_,Body,Exp}|Ss], St0) ->
    St1 = do_repeat(Body, Exp, St0),
    stats(Ss, St1);
stats([{'if',_,Tests,Else}|Ss], St0) ->
    St1 = if_tests(Tests, Else, St0),
    stats(Ss, St1);
stats([{for,Line,V,I,L,S,B}|Ss], St0) ->
    {_,St1} = numeric_for(Line, V, I, L, S, B, St0),
    stats(Ss, St1);
stats([{for,Line,V,I,L,B}|Ss], St0) ->
    {_,St1} = numeric_for(Line, V, I, L, {'NUMBER',Line,1.0}, B, St0),
    stats(Ss, St1);
stats([{for,Line,Ns,Gen,B}|Ss], St0) ->
    {_,St1} = generic_for(Line, Ns, Gen, B, St0),
    stats(Ss, St1);
stats([{local,Decl}|Ss], St0) ->
    St1 = local(Decl, St0),
    ?DP("L: ~p\n", [{Decl,St1}]),
    stats(Ss, St1);
stats([P|Ss], St0) ->
    {_,St1} = prefixexp(P, St0),		%Drop return value
    stats(Ss, St1);
stats([], St) -> {[],St}.

assign(Ns, Es, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_loop(Ns, Vals, St1).

assign_loop([Pre|Pres], [E|Es], St0) ->
    St1 = set_var(Pre, E, St0),
    assign_loop(Pres, Es, St1);
assign_loop([Pre|Pres], [], St0) ->		%Set remaining to nil
    St1 = set_var(Pre, nil, St0),
    assign_loop(Pres, [], St1);
assign_loop([], _, St) -> St.

%% set_var(PrefixExp, Val, State) -> State.
%% Step down the prefixexp sequence evaluating as we go, stop at the
%% end and return a key and a table where to put data. We can reuse
%% much of the prefixexp code bt must have our own thing at the end.

set_var({'.',_,Exp,Rest}, Val, St0) ->
    {[Next|_],St1} = prefixexp_first(Exp, St0),
    var_rest(Rest, Val, Next, St1);
set_var({'NAME',_,Name}, Val, St) ->
    set_name(Name, Val, St).
    
var_rest({'.',_,Exp,Rest}, Val, SoFar, St0) ->
    {[Next|_],St1} = prefixexp_element(Exp, SoFar, St0),
    var_rest(Rest, Val, Next, St1);
var_rest(Exp, Val, SoFar, St) ->
    var_last(Exp, Val, SoFar, St).

var_last({'NAME',_,N}, Val, SoFar, St) ->
    set_table_name(N, Val, SoFar, St);
var_last({key_field,_,Exp}, Val, SoFar, St0) ->
    {[Key|_],St1} = exp(Exp, St0),
    set_table_key(Key, Val, SoFar, St1);
var_last({method,_,{'NAME',_,N}}, {function,L,Env,Pars,B}, SoFar, St) ->
    %% Method a function, make a "method" by adding self parameter.
    set_table_name(N, {function,L,Env,[{'NAME',L,self}|Pars],B},
		   SoFar, St).

do_while(Exp, Body, St0) ->
    {Test,St1} = exp(Exp, St0),
    case is_true(Test) of
       true ->
	    {_,St2} = block(Body, St1),
	    do_while(Exp, Body, St2);
	false -> St1
    end.

do_repeat(Body, Exp, St0) ->
    Do = fun (S0) ->
		 {_,S1} = stats(Body, S0),
		 exp(Exp, S1)			%Return test expression value
	 end,
    {Ret,St1} = in_block(Do, St0),
    case is_true(Ret) of
	true -> St1;
	false -> do_repeat(Body, Exp, St1)
    end.

if_tests([{Exp,Block}|Ts], Else, St0) ->
    {[Test|_],St1} = exp(Exp, St0),		%What about the environment
    if Test =:= false; Test =:= nil ->		%Test failed, try again
	    if_tests(Ts, Else, St1);
       true ->					%Test succeeded, do block
	    {_,St2} = block(Block, St1),
	    St2
    end;
if_tests([], Else, St) ->
    block(Else, St).

numeric_for(_, {'NAME',_,Name}, Init, Limit, Step, Block, St) ->
    %% Create a local block to run the whole for loop.
    Do = fun (St0) ->
		 {[I0,L0,S0],St1} = explist([Init,Limit,Step], St0),
		 I1 = luerl_lib:tonumber(I0),
		 L1 = luerl_lib:tonumber(L0),
		 S1 = luerl_lib:tonumber(S0),
		 if (I1 == nil) or (L1 == nil) or (S1 == nil) ->
			 error({illegal_arg,for,[I0,L0,S0]});
		    true ->
			 St2 = numfor_loop(Name, I1, L1, S1, Block, St1),
			 {[],St2}
		 end
	 end,
    in_block(Do, St).

numfor_loop(Name, I, L, S, B, St0)
  when S > 0, I =< L ; S =< 0, I >= L ->
    St1 = set_local_name(Name, I, St0),
    %% Create a local block for each iteration of the loop.
    {_,St2} = block(B, St1),
    numfor_loop(Name, I+S, L, S, B, St2);
numfor_loop(_, _, _, _, _, St) -> St.		%We're done

generic_for(_, Names, Exps, Block, St) ->
    %% Create a local block to run the whole for loop.
    Do = fun (St0) ->
		 {Rets,St1} = explist(Exps, St0),
		 case Rets of			%Get 3 values!
		     [F] -> S = nil, Var = nil;
		     [F,S] -> Var = nil;
		     [F,S,Var|_] -> ok
		 end,
		 St2 = genfor_loop(Names, F, S, Var, Block, St1),
		 {[],St2}
	 end,
    in_block(Do, St).

genfor_loop(Names, F, S, Var, Block, St0) ->
    {Vals,St1} = functioncall(F, [S,Var], St0),
    case is_true(Vals) of
	true ->	    
	    St2 = assign_local_loop(Names, Vals, St1),
	    %% Create a local block for each iteration of the loop.
	    {_,St3} = block(Block, St2),
	    genfor_loop(Names, F, S, hd(Vals), Block, St3);
	false -> St1				%Done
    end.

%%     case functioncall(F, [S,Var], St0) of
%% 	{[],St1} -> St1;			%Done
%% 	{[nil|_],St1} -> St1;			%Done
%% 	{Vals,St1} ->				%We go on
%% 	    St2 = assign_local_loop(Names, Vals, St1),
%% 	    %% Create a local block for each iteration of the loop.
%% 	    {_,St3} = block(Block, St2),
%% 	    genfor_loop(Names, F, S, hd(Vals), Block, St3)
%%     end.

local({functiondef,L,{'NAME',_,Name},Ps,B}, St) ->
    set_local_name(Name, {function,L,St#luerl.env,Ps,B}, St#luerl{sub=true});
local({assign,_,Ns,Es}, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_local_loop(Ns, Vals, St1).

assign_local_loop(Ns, Vals, St) ->
    Ts = assign_local_loop(Ns, Vals, St#luerl.tabs, St#luerl.env),
    St#luerl{tabs=Ts}.

assign_local_loop([{'NAME',_,V}|Ns], [Val|Vals], Ts0, Env) ->
    Ts1 = set_local_name_env(V, Val, Ts0, Env),
    assign_local_loop(Ns, Vals, Ts1, Env);
assign_local_loop([{'NAME',_,V}|Ns], [], Ts0, Env) ->
    Ts1 = set_local_name_env(V, nil, Ts0, Env),
    assign_local_loop(Ns, [], Ts1, Env);
assign_local_loop([], _, Ts, _) -> Ts.

%% explist([Exp], State) -> {[Val],State}.
%% Evaluate a list of expressions returning a list of values. If the
%% last expression returns more than one value then these are appended
%% to the returned list.

explist([E], St) -> exp(E, St);			%Appended values to output
explist([E|Es], St0) ->
    {[Val|_],St1} = exp(E, St0),		%Only take the first value
    {Vals,St2} = explist(Es, St1),
    {[Val|Vals],St2};
explist([], St) -> {[],St}.

%% exp(Exp, State) -> {Vals,State}.
%% Function calls can affect the state. Return a list of values!

exp({nil,_}, St) -> {[nil],St};
exp({false,_}, St) -> {[false],St};
exp({true,_}, St) -> {[true],St};
exp({'NUMBER',_,N}, St) -> {[N],St};
exp({'STRING',_,S}, St) -> {[S],St};
exp({'...',_}, _) -> error({illegal_val,'...'});
exp({functiondef,L,Ps,B}, St) ->
    {[{function,L,St#luerl.env,Ps,B}],St#luerl{sub=true}};
exp({table,_,Fs}, St0) ->
    {Ts,St1} = tableconstructor(Fs, St0),
    {T,St2} = alloc_table(Ts, St1),
    {[T],St2};
exp({op,_,Op,L0,R0}, St0) ->
    {[L1|_],St1} = exp(L0, St0),
    {[R1|_],St2} = exp(R0, St1),
    op(Op, L1, R1, St2);
exp({op,_,Op,A0}, St0) ->
    {[A1|_],St1} = exp(A0, St0),
    op(Op, A1, St1);
exp(E, St) ->
    prefixexp(E, St).

%% prefixexp(PrefixExp, State) -> {[Vals],State}.
%% Step down the prefixexp sequence evaluating as we go.

prefixexp({'.',_,Exp,Rest}, St0) ->
    {[Next|_],St1} = prefixexp_first(Exp, St0),
    prefixexp_rest(Rest, Next, St1);
prefixexp(P, St) -> prefixexp_first(P, St).

prefixexp_first({'NAME',_,N}, St) -> {[get_name(N, St)],St};
prefixexp_first({single,_,E}, St0) ->		%Guaranteed only one value
    {[R|_],St1} = exp(E, St0),
    {[R],St1}.

prefixexp_rest({'.',_,Exp,Rest}, SoFar, St0) ->
    {[Next|_],St1} = prefixexp_element(Exp, SoFar, St0),
    prefixexp_rest(Rest, Next, St1);
prefixexp_rest(Exp, SoFar, St) ->
    prefixexp_element(Exp, SoFar, St).

prefixexp_element({functioncall,_,Args0}, SoFar, St0) ->
    {Args1,St1} = explist(Args0, St0),
    functioncall(SoFar, Args1, St1);
prefixexp_element({'NAME',_,N}, SoFar, St0) ->
    {V,St1} = get_table_name(N, SoFar, St0),
    {[V],St1};
prefixexp_element({key_field,_,Exp}, SoFar, St0) ->
    {[Key|_],St1} = exp(Exp, St0),
    {V,St2} = get_table_key(Key, SoFar, St1),
    {[V],St2};
prefixexp_element({method,_,{'NAME',_,N},Args0}, SoFar, St0) ->
    {Func,St1} = get_table_name(N, SoFar, St0),
    {Args1,St2} = explist(Args0, St1),
    functioncall(Func, [SoFar|Args1], St2).

functioncall({function,_,Env,Ps,B}, Args, St0) ->
    ?DP("F: ~p\n", [{Name,Args,St0}]),
    ?DP("F: ~p\n", [{Env,Ps,B}]),
    Env0 = St0#luerl.env,			%Caller's environment
    St1 = St0#luerl{env=Env},			%Set function's environment
    Do = fun (S0) ->
		 S1 = assign_local_loop(Ps, Args, S0),
		 stats(B, S1)
	 end,
    %% Use local assign to put argument into environment.
    {Ret,St2} = in_block(Do, St1),
    St3 = St2#luerl{env=Env0},			%Restore caller's environment
    ?DP("F-> ~p\n", [{Ret,St2}]),
    ?DP("F-> ~p\n", [{Ret,St3}]),
    {Ret,St3};
functioncall({function,Fun}, Args, St) when is_function(Fun) ->
    Fun(Args, St);
functioncall(Func, As, St) ->
    case getmetamethod(Func, <<"__call">>, St) of
	nil -> error({illegal_arg,Func,As});
	Meta -> functioncall(Meta, As, St)
    end.

%% tableconstructor(Fields, State) -> {TableData,State}.

tableconstructor(Fs, St0) ->
    Fun = fun ({exp_field,_,Ve}, {I,S0}) ->
		  {[V|_],S1} = exp(Ve, S0),
		  {{I,V},{I+1,S1}};
	      ({name_field,_,{'NAME',_,N},Ve}, {I,S0}) ->
		  {[V|_],S1} = exp(Ve, S0),
		  K = atom_to_binary(N, latin1),
		  {{K,V},{I,S1}};
	      ({key_field,_,Ke,Ve}, {I,S0}) ->
		  {[K|_],S1} = exp(Ke, S0),
		  {[V|_],S2} = exp(Ve, S1),
		  {{K,V},{I,S2}}
	  end,
    {T,{_,St1}} = lists:mapfoldl(Fun, {1.0,St0}, Fs),
    {orddict:from_list(T),St1}.

%% op(Op, Arg, State) -> {[Ret],State}.
%% op(Op, Arg1, Arg2, State) -> {[Ret],State}.
%% The built-in operators.

op('-', A, St) ->
    numeric_op('-', A, <<"__unm">>, fun (N) -> -N end, St);
op('not', false, St) -> {[true],St};
op('not', nil, St) -> {[true],St};
op('not', _, St) -> {[false],St};		%Everything else is false
op('#', B, St) when is_binary(B) -> {[byte_size(B)],St};
op('#', {table,N}=T, St) ->			%Not right, but will do for now
    Meta = getmetamethod(T, <<"__len">>, St),
    if ?IS_TRUE(Meta) -> functioncall(Meta, [T], St);
       true ->
	    Tab = orddict:fetch(N, St#luerl.tabs),
	    {[length(element(1, Tab))],St}
    end;
op(Op, A, _) -> error({illegal_arg,Op,[A]}).

%% Numeric operators.

op('+', A1, A2, St) ->
    numeric_op('+', A1, A2, <<"__add">>, fun (N1,N2) -> N1+N2 end, St);
op('-', A1, A2, St) ->
    numeric_op('-', A1, A2, <<"__sub">>, fun (N1,N2) -> N1-N2 end, St);
op('*', A1, A2, St) ->
    numeric_op('*', A1, A2, <<"__mul">>, fun (N1,N2) -> N1*N2 end, St);
op('/', A1, A2, St) ->
    numeric_op('/', A1, A2, <<"__div">>, fun (N1,N2) -> N1/N2 end, St);
op('%', A1, A2, St) ->
    numeric_op('%', A1, A2, <<"__mod">>,
	       fun (N1,N2) -> N1 - round(N1/N2 - 0.5)*N2 end, St);
op('^', A1, A2, St) ->
    numeric_op('^', A1, A2, <<"__pow">>,
	       fun (N1,N2) -> math:pow(N1, N2) end, St);
%% Relational operators, getting close.
op('==', A1, A2, St) -> eq_op('==', A1, A2, St);
op('~=', A1, A2, St) -> neq_op('~=', A1, A2, St);
op('<', A1, A2, St) -> lt_op('<', A1, A2, St);
op('<=', A1, A2, St) -> le_op('<=', A1, A2, St);
op('>', A1, A2, St) -> lt_op('>', A2, A1, St);
op('>=', A1, A2, St) -> le_op('>=', A2, A1, St);
%% Logical operators, handle truthy/falsey first arguments.
op('and', nil, _, St) -> {[nil],St};
op('and', false, _, St) -> {[false],St};
op('and', _, A2, St) -> {[A2],St};			%A1 is "true"
op('or', nil, A2, St) -> {[A2],St};
op('or', false, A2, St) -> {[A2],St};
op('or', A1, _, St) -> {[A1],St};			%A1 is "true"
%% String operator.
op('..', A1, A2, St) ->
    B1 = luerl_lib:tostring(A1),
    B2 = luerl_lib:tostring(A2),
    if B1 =/= nil, B2 =/= nil -> {[<< B1/binary,B2/binary >>],St};
       true ->
	    Meta = getmetamethod(A1, A2, <<"__concat">>, St),
	    functioncall(Meta, [A1,A2], St)
    end;
%% Bad args here.
op(Op, A1, A2, _) -> error({illegal_arg,Op,[A1,A2]}).

%% numeric_op(Op, Arg, Event, Raw, State) -> {[Ret],State}.
%% numeric_op(Op, Arg, Arg, Event, Raw, State) -> {[Ret],State}.
%% eq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% neq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% lt_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% le_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% Straigt out of the reference manual.

numeric_op(_, O, E, Raw, St0) ->
    N = luerl_lib:tonumber(O),
    if is_number(N) -> {[Raw(N)],St0};
       true ->
	    Meta = getmetamethod(O, E, St0),
	    {Ret,St1} = functioncall(Meta, [O], St0),
	    {[is_true(Ret)],St1}
    end.

numeric_op(_, O1, O2, E, Raw, St0) ->
    N1 = luerl_lib:tonumber(O1),
    N2 = luerl_lib:tonumber(O2),
    if is_number(N1), is_number(N2) -> {[Raw(N1, N2)],St0};
       true ->
	    Meta = getmetamethod(O1, O2, E, St0),
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true(Ret)],St1}
    end.

eq_op(_, O1, O2, St) when O1 =:= O2 -> {[true],St};
eq_op(_, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[is_true(Ret)],St1}.

neq_op(_, O1, O2, St) when O1 =:= O2 -> {[false],St};
neq_op(_, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[not is_true(Ret)],St1}.

eq_meta(O1, O2, St0) ->
    case getmetamethod(O1, <<"__eq">>, St0) of
	nil -> {[false],St0};			%Tweren't no method
	Meta ->
	    case getmetamethod(O2, <<"__eq">>, St0) of
		Meta ->				%Must be the same method
		    functioncall(Meta, [O1,O2], St0);
		_ -> {[false],St0}
	    end
    end.

lt_op(_, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 < O2],St};
lt_op(_, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 < O2],St};
lt_op(_, O1, O2, St0) ->
    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
    {[is_true(Ret)],St1}.

le_op(_, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 =< O2],St};
le_op(_, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 =< O2],St};
le_op(_, O1, O2, St0) ->
    case getmetamethod(O1, O2, <<"__le">>, St0) of
	Meta when Meta =/= nil ->
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true(Ret)],St1};
	nil ->
	    %% Try for not (Op2 < Op1) instead.
	    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
	    {Ret,St1} = functioncall(Meta, [O2,O1], St0),
	    {[not is_true(Ret)],St1}
    end.

%% getmetamethod(Object1, Object2, Event, State) -> Metod | nil.
%% getmetamethod(Object, Event, State) -> Method | nil.
%% Get the metamethod for object(s).

getmetamethod(O1, O2, E, St) ->
    case getmetamethod(O1, E, St) of
	nil -> getmetamethod(O2, E, St);
	M -> M
    end.

getmetamethod({table,N}, E, #luerl{tabs=Ts}) ->
    case orddict:fetch(N, Ts) of
	{_,{table,M}} ->			%There is a metatable
	    {Mtab,_} = orddict:fetch(M, Ts),
	    case orddict:find(E, Mtab) of
		{ok,Mm} -> Mm;
		error -> nil
	    end;
	{_,nil} -> nil				%No metatable
    end;
getmetamethod(_, _, _) -> nil.			%Other types have no metatables

getmetamethod_tab({table,M}, E, Ts) ->
    {Mtab,_} = orddict:fetch(M, Ts),
    case orddict:find(E, Mtab) of
	{ok,Mm} -> Mm;
	error -> nil
    end;
getmetamethod_tab(_, _, _) -> nil.		%Other types have no metatables

%% is_true(Rets) -> boolean()>

is_true([nil|_]) -> false;
is_true([false|_]) -> false;
is_true([_|_]) -> true;
is_true([]) -> false.

first_value([V|_]) -> V;
first_value([]) -> nil.

%% gc(State) -> State.
%% The garbage collector. Its main job is to reclaim unused tables. It
%% is a mark/sweep collector which passes over all objects and marks
%% tables which it has seen. All unseen tables are then freed and
%% their index added to the free list.

gc(#luerl{tabs=Ts0,free=Free0,env=Env}=St) ->
    Seen = mark(Env, [], [], Ts0),
    io:format("gc: ~p\n", [Seen]),
    %% Free unseen tables and add freed to free list.
    Ts1 = orddict:filter(fun (K, _) -> ordsets:is_element(K, Seen) end, Ts0),
    Free1 = orddict:fold(fun (K, _, F) ->
				 case ordsets:is_element(K, Seen) of
				     true -> F;
				     false -> [K|F]
				 end
			 end, Free0, Ts0),
    St#luerl{tabs=Ts1,free=Free1}.

%% mark(ToDo, MoreTodo, Seen, Tabs) -> Seen.
%% Scan over all live objects and mark seen tables by adding them to
%% the seen list.

mark([{table,T}|Todo], More, Seen0, Ts) ->
    case ordsets:is_element(T, Seen0) of
	true ->					%Already done
	    mark(Todo, More, Seen0, Ts);
	false ->				%Must do it
	    Seen1 = ordsets:add_element(T, Seen0),
	    {Tab,Meta} = orddict:fetch(T, Ts),
	    %% Have to be careful where add Tab and Meta as Tab is a
	    %% [{Key,Val}] and Meta is a nil|{table,M}. We want lists.
	    mark([Meta|Todo], [Tab|More], Seen1, Ts)
    end;
mark([{function,_,Env,_,_}|Todo], More, Seen, Ts) ->
    mark(Todo, [Env|More], Seen, Ts);
%% Catch these as they would match table key-value pair.
mark([{function,_}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([{thread,_}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([{userdata,_}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([{K,V}|Todo], More, Seen, Ts) ->		%Table key-value pair
    mark([K,V|Todo], More, Seen, Ts);
mark([_|Todo], More, Seen, Ts) ->		%Can ignore everything else
    mark(Todo, More, Seen, Ts);
mark([], [M|More], Seen, Ts) ->
    mark(M, More, Seen, Ts);
mark([], [], Seen, _) -> Seen.