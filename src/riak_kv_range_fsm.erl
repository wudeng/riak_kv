%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Coordinator used to perform range queries.

-module(riak_kv_range_fsm).

-behaviour(riak_core_coverage_fsm).

-include_lib("riak_kv_vnode.hrl").

-export([init/2,
         process_results/2,
         finish/2]).

-type from() :: {atom(), req_id(), pid()}.
-type req_id() :: non_neg_integer().

-record(state, {client_type :: plain | mapred,
                from :: from()}).

%% @doc Return a tuple containing the ModFun to call per vnode,
%% the number of primary preflist vnodes the operation
%% should cover, the service to use to check for available nodes,
%% and the registered name to use to access the vnode master process.
init(From={_, _, ClientPid}, [Bucket, Start, End, Timeout, ClientType]) ->
    case ClientType of
        %% Link to the mapred job so we die if the job dies
        mapred ->
            link(ClientPid);
        _ ->
            ok
    end,
    BucketProps = riak_core_bucket:get_bucket(Bucket),
    NVal = proplists:get_value(n_val, BucketProps),
    Req = ?KV_RANGE_REQ{bucket=Bucket,
                        start=Start,
                        'end'=End},
    {Req, all, NVal, 1, riak_kv, riak_kv_vnode_master, Timeout,
     #state{client_type=ClientType, from=From}}.

process_results({results, {Bucket, Vals}},
                StateData=#state{client_type=ClientType,
                                 from={raw, ReqId, ClientPid}}) ->
    process_vals(ClientType, Bucket, Vals, ReqId, ClientPid),
    {ok, StateData};
process_results({final_results, {Bucket, Vals}},
                StateData=#state{client_type=ClientType,
                                 from={raw, ReqId, ClientPid}}) ->
    process_vals(ClientType, Bucket, Vals, ReqId, ClientPid),
    {done, StateData}.

finish({error, Error},
       StateData=#state{from={raw, ReqId, ClientPid},
                        client_type=ClientType}) ->
    case ClientType of
        mapred ->
            %% An error occurred or the timeout interval elapsed
            %% so all we can do now is die so that the rest of the
            %% MapReduce processes will also die and be cleaned up.
            exit(Error);
        plain ->
            %% Notify the requesting client that an error
            %% occurred or the timeout has elapsed.
            ClientPid ! {ReqId, Error}
    end,
    {stop, normal, StateData};
finish(clean,
       StateData=#state{from={raw, ReqId, ClientPid},
                        client_type=ClientType}) ->
    case ClientType of
        mapred ->
            luke_flow:finish_inputs(ClientPid);
        plain ->
            ClientPid ! {ReqId, done}
    end,
    {stop, normal, StateData}.

%% ===================================================================
%% Internal functions
%% ===================================================================

process_vals(plain, _Bucket, Vals, ReqId, ClientPid) ->
    ClientPid ! {ReqId, {vals, Vals}};
process_vals(mapred, Bucket, Vals, _ReqId, ClientPid) ->
    try
        luke_flow:add_inputs(ClientPid, [{Bucket, Val} || Val <- Vals])
    catch _:_ ->
            exit(self(), normal)
    end.