%%%----------------------------------------------------------------------
%%% File    : ejabberd_c2s.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve C2S connection
%%% Created : 16 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_wlan_protobuf_c2s).

-author('alexey@process-one.net').

-update_info({update, 0}).

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% External exports
-export([start/2,
	 stop/1,
	 start_link/2,
	 send_text/2,
	 send_element/2,
	 socket_type/0,
	 get_presence/1,
	 get_aux_field/2,
	 set_aux_field/3,
	 del_aux_field/2,
	 get_subscription/2,
	 broadcast/4,
	 get_subscribed/1,
         transform_listen_option/2]).

%% gen_fsm callbacks
-export([init/1,
	 wait_for_stream/2,
	 wait_for_auth/2,
	 wait_for_feature_request/2,
	 wait_for_bind/2,
	 wait_for_session/2,
	 wait_for_sasl_response/2,
	 wait_for_resume/2,
	 session_established/2,
	 handle_event/3,
	 handle_sync_event/4,
	 code_change/4,
	 handle_info/3,
	 terminate/3,
	 print_state/1
     ]).

-export([add_body_id/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("mod_privacy.hrl").

-define(SETS, gb_sets).
-define(DICT, dict).

%% pres_a contains all the presence available send (either through roster mechanism or directed).
%% Directed presence unavailable remove user from pres_a.
-record(state, {socket,
		sockmod,
		socket_monitor,
		xml_socket,
		streamid,
		sasl_state,
		access,
		shaper,
		zlib = false,
		tls = false,
		tls_required = false,
		tls_enabled = false,
		tls_options = [],
		authenticated = false,
		jid,
		user = "", server = <<"">>, resource = <<"">>,
		sid,
		pres_t = ?SETS:new(),
		pres_f = ?SETS:new(),
		pres_a = ?SETS:new(),
		pres_i = ?SETS:new(),
		pres_last, pres_pri,
		pres_timestamp,
		pres_invis = false,
		privacy_list = #userlist{},
		conn = unknown,
		auth_module = unknown,
		ip,
		aux_fields = [],
		mgmt_state,
		mgmt_xmlns,
		mgmt_queue,
		mgmt_max_queue,
		mgmt_pending_since,
		mgmt_timeout,
		mgmt_resend,
		mgmt_stanzas_in = 0,
		mgmt_stanzas_out = 0,
		key_flag = false,
        key = <<"">>,
		lang = <<"">>}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

%% Module start with or without supervisor:
-ifdef(NO_TRANSIENT_SUPERVISORS).
-define(SUPERVISOR_START, ?GEN_FSM:start(ejabberd_wlan_protobuf_c2s, [SockData, Opts],
					 fsm_limit_opts(Opts) ++ ?FSMOPTS)).
-else.
-define(SUPERVISOR_START, supervisor:start_child(ejabberd_c2s_sup,
						 [SockData, Opts])).
-endif.

%% This is the timeout to apply between event when starting a new
%% session:
-define(C2S_OPEN_TIMEOUT, 60000).

-define(C2S_HIBERNATE_TIMEOUT, 90000).

-define(STREAM_HEADER,
	<<"<?xml version='1.0'?><stream:stream "
	  "xmlns='jabber:client' xmlns:stream='http://et"
	  "herx.jabber.org/streams' id='~s' from='~s'~s~"
	  "s>">>).

-define(STREAM_TRAILER, <<"</stream:stream>">>).

-define(INVALID_NS_ERR, ?SERR_INVALID_NAMESPACE).

-define(INVALID_XML_ERR, ?SERR_XML_NOT_WELL_FORMED).

-define(HOST_UNKNOWN_ERR, ?SERR_HOST_UNKNOWN).

-define(POLICY_VIOLATION_ERR(Lang, Text),
	?SERRT_POLICY_VIOLATION(Lang, Text)).

-define(INVALID_FROM, ?SERR_INVALID_FROM).

%% XEP-0198:

-define(IS_STREAM_MGMT_TAG(Name),
	Name == <<"enable">>;
	Name == <<"resume">>;
	Name == <<"a">>;
	Name == <<"r">>).

-define(IS_SUPPORTED_MGMT_XMLNS(Xmlns),
	Xmlns == ?NS_STREAM_MGMT_2;
	Xmlns == ?NS_STREAM_MGMT_3).

-define(MGMT_FAILED(Condition, Xmlns),
	#xmlel{name = <<"failed">>,
	       attrs = [{<<"xmlns">>, Xmlns}],
	       children = [#xmlel{name = Condition,
				  attrs = [{<<"xmlns">>, ?NS_STANZAS}],
				  children = []}]}).

-define(MGMT_BAD_REQUEST(Xmlns),
	?MGMT_FAILED(<<"bad-request">>, Xmlns)).

-define(MGMT_ITEM_NOT_FOUND(Xmlns),
	?MGMT_FAILED(<<"item-not-found">>, Xmlns)).

-define(MGMT_SERVICE_UNAVAILABLE(Xmlns),
	?MGMT_FAILED(<<"service-unavailable">>, Xmlns)).

-define(MGMT_UNEXPECTED_REQUEST(Xmlns),
	?MGMT_FAILED(<<"unexpected-request">>, Xmlns)).

-define(MGMT_UNSUPPORTED_VERSION(Xmlns),
	?MGMT_FAILED(<<"unsupported-version">>, Xmlns)).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(SockData, Opts) ->
    ?SUPERVISOR_START.

start_link(SockData, Opts) ->
	?DEBUG("ejabberd_c2s ~p ,~p ~n",[SockData,Opts]),
    ?GEN_FSM:start_link(ejabberd_c2s, [SockData, Opts],
			fsm_limit_opts(Opts) ++ ?FSMOPTS).

socket_type() -> protobuf.

%% Return Username, Resource and presence information
get_presence(FsmRef) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef,
					 {get_presence}, 1000).

get_aux_field(Key, #state{aux_fields = Opts}) ->
    case lists:keysearch(Key, 1, Opts) of
      {value, {_, Val}} -> {ok, Val};
      _ -> error
    end.

set_aux_field(Key, Val,
	      #state{aux_fields = Opts} = State) ->
    Opts1 = lists:keydelete(Key, 1, Opts),
    State#state{aux_fields = [{Key, Val} | Opts1]}.

del_aux_field(Key, #state{aux_fields = Opts} = State) ->
    Opts1 = lists:keydelete(Key, 1, Opts),
    State#state{aux_fields = Opts1}.

get_subscription(From = #jid{}, StateData) ->
    get_subscription(jlib:jid_tolower(From), StateData);
get_subscription(LFrom, StateData) ->
    LBFrom = setelement(3, LFrom, <<"">>),
    F = (?SETS):is_element(LFrom, StateData#state.pres_f)
	  orelse
	  (?SETS):is_element(LBFrom, StateData#state.pres_f),
    T = (?SETS):is_element(LFrom, StateData#state.pres_t)
	  orelse
	  (?SETS):is_element(LBFrom, StateData#state.pres_t),
    if F and T -> both;
       F -> from;
       T -> to;
       true -> none
    end.

broadcast(FsmRef, Type, From, Packet) ->
    FsmRef ! {broadcast, Type, From, Packet}.

stop(FsmRef) -> (?GEN_FSM):send_event(FsmRef, closed).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%%----------------------------------------------------------------------
init([{SockMod, Socket}, Opts]) ->
    Access = case lists:keysearch(access, 1, Opts) of
	       {value, {_, A}} -> A;
	       _ -> all
	     end,
    Shaper = case lists:keysearch(shaper, 1, Opts) of
	       {value, {_, S}} -> S;
	       _ -> none
	     end,
    XMLSocket = case lists:keysearch(xml_socket, 1, Opts) of
		  {value, {_, XS}} -> XS;
		  _ -> false
		end,
    Zlib = proplists:get_bool(zlib, Opts),
    StartTLS = proplists:get_bool(starttls, Opts),
    StartTLSRequired = proplists:get_bool(starttls_required, Opts),
    TLSEnabled = proplists:get_bool(tls, Opts),
    TLS = StartTLS orelse
	    StartTLSRequired orelse TLSEnabled,
    TLSOpts1 = lists:filter(fun ({certfile, _}) -> true;
				({ciphers, _}) -> true;
				(_) -> false
			    end,
			    Opts),
    TLSOpts2 = case lists:keysearch(protocol_options, 1, Opts) of
                   {value, {_, O}} ->
                       [_|ProtocolOptions] = lists:foldl(
                                    fun(X, Acc) -> X ++ Acc end, [],
                                    [["|" | binary_to_list(Opt)] || Opt <- O, is_binary(Opt)]
                                   ),
                        [{protocol_options, iolist_to_binary(ProtocolOptions)} | TLSOpts1];
                   _ -> TLSOpts1
               end,
    TLSOpts3 = case proplists:get_bool(tls_compression, Opts) of
                   false -> [compression_none | TLSOpts2];
                   true -> TLSOpts2
               end,
    TLSOpts = [verify_none | TLSOpts3],
    StreamMgmtEnabled = proplists:get_value(stream_management, Opts, true),
    StreamMgmtState = if StreamMgmtEnabled -> inactive;
			 true -> disabled
		      end,
    MaxAckQueue = case proplists:get_value(max_ack_queue, Opts) of
		    Limit when is_integer(Limit), Limit > 0 -> Limit;
		    _ -> 500
		  end,
    ResumeTimeout = case proplists:get_value(resume_timeout, Opts) of
		      Timeout when is_integer(Timeout), Timeout >= 0 -> Timeout;
		      _ -> 300
		    end,
    ResendOnTimeout = proplists:get_bool(resend_on_timeout, Opts),
    IP = peerip(SockMod, Socket),
    %% Check if IP is blacklisted:
    case is_ip_blacklisted(IP) of
      true ->
	  ?INFO_MSG("Connection attempt from blacklisted "
		    "IP: ~s (~w)",
		    [jlib:ip_to_list(IP), IP]),
	  {stop, normal};
      false ->
	  Socket1 = if TLSEnabled andalso
			 SockMod /= ejabberd_frontend_socket ->
			   SockMod:starttls(Socket, TLSOpts);
		       true -> Socket
		    end,
	  SocketMonitor = SockMod:monitor(Socket1),
	  StateData = #state{socket = Socket1, sockmod = SockMod,
			     socket_monitor = SocketMonitor,
			     xml_socket = XMLSocket, zlib = Zlib, tls = TLS,
			     tls_required = StartTLSRequired,
			     tls_enabled = TLSEnabled, tls_options = TLSOpts,
			     sid = {os:timestamp(), self()}, streamid = new_id(),
			     access = Access, shaper = Shaper, ip = IP,
			     mgmt_state = StreamMgmtState,
			     mgmt_max_queue = MaxAckQueue,
			     mgmt_timeout = ResumeTimeout,
			     mgmt_resend = ResendOnTimeout},
	  {ok, wait_for_stream, StateData, ?C2S_OPEN_TIMEOUT}
    end.

%% Return list of all available resources of contacts,
get_subscribed(FsmRef) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef,
					 get_subscribed, 1000).

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------

wait_for_stream({xmlstreamstart, _Name, Attrs}, StateData) ->
    DefaultLang = ?MYLANG,
		?DEBUG("Attrs ~p ~n",[Attrs]),
    case xml:get_attr_s(<<"xmlns:stream">>, Attrs) of
	?NS_STREAM ->
            Server =
                case StateData#state.server of
                    <<"">> ->
                        jlib:nameprep(xml:get_attr_s(<<"to">>, Attrs));
                    S -> S
                end,
		?DEBUG("Server ~p ~n",[Server]),
	    case lists:member(Server, ?MYHOSTS) of
		true ->
		    Lang = case xml:get_attr_s(<<"xml:lang">>, Attrs) of
			       Lang1 when size(Lang1) =< 35 ->
				   %% As stated in BCP47, 4.4.1:
				   %% Protocols or specifications that
				   %% specify limited buffer sizes for
				   %% language tags MUST allow for
				   %% language tags of at least 35 characters.
				   Lang1;
			       _ ->
				   %% Do not store long language tag to
				   %% avoid possible DoS/flood attacks
				   <<"">>
			   end,
		    change_shaper(StateData, jlib:make_jid(<<"">>, Server, <<"">>)),
		    case xml:get_attr_s(<<"version">>, Attrs) of
			<<"1.0">> ->
			 %%   send_header(StateData, Server, <<"1.0">>, DefaultLang),
			    case StateData#state.authenticated of
				false ->
				    SASLState =
					cyrsasl:server_new(
					  <<"jabber">>, Server, <<"">>, [],
					  fun(U) ->
						  ejabberd_auth:get_password_with_authmodule(
						    U, Server)
					  end,
					  fun(U, P) ->
						  ejabberd_auth:check_wlan_password_with_authmodule(
						    U, Server, P)
					  end,
					  fun(U, P, D, DG) ->
						  ejabberd_auth:check_password_with_authmodule(
						    U, Server, P, D, DG)
					  end),
				    Mechs = lists:map(fun (S) ->
						      #xmlel{name = <<"mechanism">>,
							     attrs = [],
							     children = [{xmlcdata, S}]}
					      end,
					     [<<"PLAIN">>]),
					    %% cyrsasl:listmech(Server)),
		
				    SockMod =
					(StateData#state.sockmod):get_sockmod(
					  StateData#state.socket),
				    Zlib = StateData#state.zlib,
				    CompressFeature =
					case Zlib andalso
					    ((SockMod == gen_tcp) orelse
					     (SockMod == p1_tls)) of
					    true ->
						[#xmlel{name = <<"compression">>,
							attrs = [{<<"xmlns">>, ?NS_FEATURE_COMPRESS}],
							children = [#xmlel{name = <<"method">>,
								    attrs = [],
								    children = [{xmlcdata, <<"zlib">>}]}]}];
					    _ ->
						[]
					end,
				    TLS = StateData#state.tls,
				    TLSEnabled = StateData#state.tls_enabled,
				    TLSRequired = StateData#state.tls_required,
				    TLSFeature =
					case (TLS == true) andalso
					    (TLSEnabled == false) andalso
					    (SockMod == gen_tcp) of
					    true ->
						case TLSRequired of
						    true ->
							[#xmlel{name = <<"starttls">>,
								attrs = [{<<"xmlns">>, ?NS_TLS}],
								children = [#xmlel{name = <<"required">>,
									    attrs = [],
									    children = []}]}];
						    _ ->
							[#xmlel{name = <<"starttls">>,
								attrs = [{<<"xmlns">>, ?NS_TLS}],
								children = []}]
						end;
					    false ->
						[]
					end,
                    ?DEBUG("Tls ~p ~n",[TLSEnabled]),
					User = xml:get_attr_s(<<"user">>, Attrs),
                    Sockmod = case TLS of
                              true ->
                                    <<"TLS">>;
                              _ ->
                                    <<"">>
                              end,
					send_welcome_msg(StateData,User,Server,<<"1.0">>,Sockmod),
				    fsm_next_state(wait_for_feature_request,
					       StateData#state{
						 server = Server,
						 sasl_state = SASLState,
						 lang = Lang});
				_ ->
				    case StateData#state.resource of
				    <<"">> ->
					RosterVersioningFeature =
					    ejabberd_hooks:run_fold(roster_get_versioning_feature,
								    Server, [],
								    [Server]),
					StreamManagementFeature =
					    case stream_mgmt_enabled(StateData) of
					      true ->
						  [#xmlel{name = <<"sm">>,
							  attrs = [{<<"xmlns">>, ?NS_STREAM_MGMT_2}],
							  children = []},
						   #xmlel{name = <<"sm">>,
							  attrs = [{<<"xmlns">>, ?NS_STREAM_MGMT_3}],
							  children = []}];
					      false ->
						  []
					    end,
					StreamFeatures = [#xmlel{name = <<"bind">>,
								attrs = [{<<"xmlns">>, ?NS_BIND}],
								children = []},
							    #xmlel{name = <<"session">>,
								attrs = [{<<"xmlns">>, ?NS_SESSION}],
								children = []}]
							    ++
							    RosterVersioningFeature ++
							    StreamManagementFeature ++
							    ejabberd_hooks:run_fold(c2s_stream_features,
								Server, [], [Server]),
					send_element(StateData,
						    #xmlel{name = <<"stream:features">>,
							    attrs = [],
							    children = StreamFeatures}),
					fsm_next_state(wait_for_bind,
							StateData#state{server = Server, lang = Lang});
				    _ ->
					send_element(StateData,
						    #xmlel{name = <<"stream:features">>,
							    attrs = [],
							    children = []}),
					fsm_next_state(wait_for_session,
							StateData#state{server = Server, lang = Lang})
				    end
			    end;
		_ ->
		    send_header(StateData, Server, <<"">>, DefaultLang),
		    if not StateData#state.tls_enabled and
			StateData#state.tls_required ->
			    send_element(StateData,
					?POLICY_VIOLATION_ERR(Lang,
							    <<"Use of STARTTLS required">>)),
			    send_trailer(StateData),
			    {stop, normal, StateData};
			true ->
			    fsm_next_state(wait_for_auth,
					StateData#state{server = Server,
							lang = Lang})
		    end
	    end;
	_ ->
%	    send_header(StateData, ?MYNAME, <<"">>, DefaultLang),
%	    send_element(StateData, ?HOST_UNKNOWN_ERR),
%	    send_trailer(StateData),
		send_stream_end(StateData),
	    {stop, normal, StateData}
	end;
    _ ->
%	send_header(StateData, ?MYNAME, <<"">>, DefaultLang),
%	send_element(StateData, ?INVALID_NS_ERR),
%	send_trailer(StateData),
	send_stream_end(StateData),
	{stop, normal, StateData}
    end;
wait_for_stream(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_stream({xmlstreamelement, _}, StateData) ->
%    send_element(StateData, ?INVALID_XML_ERR),
 %   send_trailer(StateData),
 	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_stream({xmlstreamend, _}, StateData) ->
%    send_element(StateData, ?INVALID_XML_ERR),
 %   send_trailer(StateData),
 	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_stream({xmlstreamerror, _}, StateData) ->
%    send_header(StateData, ?MYNAME, <<"1.0">>, <<"">>),
 %   send_element(StateData, ?INVALID_XML_ERR),
  %  send_trailer(StateData),
  	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_stream(closed, StateData) ->
    {stop, normal, StateData}.

wait_for_auth({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_auth, dispatch_stream_mgmt(El, StateData));
wait_for_auth({xmlstreamelement, El}, StateData) ->
    case is_auth_packet(El) of
      {auth, _ID, get, {U, _, _, _}} ->
	  #xmlel{name = Name, attrs = Attrs} =
	      jlib:make_result_iq_reply(El),
	  case U of
	    <<"">> -> UCdata = [];
	    _ -> UCdata = [{xmlcdata, U}]
	  end,
	  Res = case
		  ejabberd_auth:plain_password_required(StateData#state.server)
		    of
		  false ->
		      #xmlel{name = Name, attrs = Attrs,
			     children =
				 [#xmlel{name = <<"query">>,
					 attrs = [{<<"xmlns">>, ?NS_AUTH}],
					 children =
					     [#xmlel{name = <<"username">>,
						     attrs = [],
						     children = UCdata},
					      #xmlel{name = <<"password">>,
						     attrs = [], children = []},
					      #xmlel{name = <<"digest">>,
						     attrs = [], children = []},
					      #xmlel{name = <<"resource">>,
						     attrs = [],
						     children = []}]}]};
		  true ->
		      #xmlel{name = Name, attrs = Attrs,
			     children =
				 [#xmlel{name = <<"query">>,
					 attrs = [{<<"xmlns">>, ?NS_AUTH}],
					 children =
					     [#xmlel{name = <<"username">>,
						     attrs = [],
						     children = UCdata},
					      #xmlel{name = <<"password">>,
						     attrs = [], children = []},
					      #xmlel{name = <<"resource">>,
						     attrs = [],
						     children = []}]}]}
		end,
	  send_element(StateData, Res),
	  fsm_next_state(wait_for_auth, StateData);
      {auth, _ID, set, {_U, _P, _D, <<"">>}} ->
	  Err = jlib:make_error_reply(El,
				      ?ERR_AUTH_NO_RESOURCE_PROVIDED((StateData#state.lang))),
	  send_element(StateData, Err),
	  fsm_next_state(wait_for_auth, StateData);
      {auth, _ID, set, {U, P, D, R}} ->
	  JID = jlib:make_jid(U, StateData#state.server, R),
	  case JID /= error andalso
		 acl:match_rule(StateData#state.server,
				StateData#state.access, JID)
		   == allow
	      of
	    true ->
		DGen = fun (PW) ->
			       p1_sha:sha(<<(StateData#state.streamid)/binary, PW/binary>>)
		       end,
		case ejabberd_auth:check_password_with_authmodule(U,
								  StateData#state.server,
								  P, D, DGen)
		    of
		  {true, AuthModule} ->
			?INFO_MSG("(~w) Accepted legacy authentication for ~s by ~p",
				[StateData#state.socket,
				 jlib:jid_to_string(JID), AuthModule]),
			Conn = get_conn_type(StateData),
			Info = [{ip, StateData#state.ip}, {conn, Conn},
				    {auth_module, AuthModule}],
                        Res = jlib:make_result_iq_reply(
                                El#xmlel{children = []}),
			send_element(StateData, Res),
			ejabberd_sm:open_session(StateData#state.sid, U,
						 StateData#state.server, R,
						 Info),
			change_shaper(StateData, JID),
			{Fs, Ts} =
			    ejabberd_hooks:run_fold(roster_get_subscription_lists,
						    StateData#state.server,
						    {[], []},
						    [U,
							StateData#state.server]),
			LJID =
			    jlib:jid_tolower(jlib:jid_remove_resource(JID)),
			Fs1 = [LJID | Fs],
			Ts1 = [LJID | Ts],
			PrivList = ejabberd_hooks:run_fold(privacy_get_user_list,
						    StateData#state.server,
						    #userlist{},
						    [U, StateData#state.server]),
			NewStateData = StateData#state{user = U,
							resource = R,
							jid = JID,
							conn = Conn,
							auth_module = AuthModule,
							pres_f = (?SETS):from_list(Fs1),
							pres_t = (?SETS):from_list(Ts1),
							privacy_list = PrivList},
			fsm_next_state(session_established, NewStateData);
		  _ ->
		      IP = peerip(StateData#state.sockmod,
				  StateData#state.socket),
		      ?INFO_MSG("(~w) Failed legacy authentication for "
				"~s from IP ~s",
				[StateData#state.socket,
				    jlib:jid_to_string(JID), jlib:ip_to_list(IP)]),
		      Err = jlib:make_error_reply(El, ?ERR_NOT_AUTHORIZED),
		      send_element(StateData, Err),
		      fsm_next_state(wait_for_auth, StateData)
		end;
	    _ ->
		if JID == error ->
		       ?INFO_MSG("(~w) Forbidden legacy authentication "
				 "for username '~s' with resource '~s'",
				 [StateData#state.socket, U, R]),
		       Err = jlib:make_error_reply(El, ?ERR_JID_MALFORMED),
		       send_element(StateData, Err),
		       fsm_next_state(wait_for_auth, StateData);
		   true ->
		       ?INFO_MSG("(~w) Forbidden legacy authentication "
				 "for ~s",
				 [StateData#state.socket,
				  jlib:jid_to_string(JID)]),
		       Err = jlib:make_error_reply(El, ?ERR_NOT_ALLOWED),
		       send_element(StateData, Err),
		       fsm_next_state(wait_for_auth, StateData)
		end
	  end;
      _ ->
	  process_unauthenticated_stanza(StateData, El),
	  fsm_next_state(wait_for_auth, StateData)
    end;
wait_for_auth(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_auth({xmlstreamend, _Name}, StateData) ->
%%    send_trailer(StateData),
	send_stream_end(StateData),
	{stop, normal, StateData};
wait_for_auth({xmlstreamerror, _}, StateData) ->
 %   send_element(StateData, ?INVALID_XML_ERR),
  %  send_trailer(StateData),
  	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_auth(closed, StateData) ->
    {stop, normal, StateData}.

wait_for_feature_request({xmlstreamelement, #xmlel{name = Name} = El},
			 StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_feature_request,
		   dispatch_stream_mgmt(El, StateData));
wait_for_feature_request({xmlstreamelement, El},
			 StateData) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} = El,
    Zlib = StateData#state.zlib,
    TLS = StateData#state.tls,
    TLSEnabled = StateData#state.tls_enabled,
    TLSRequired = StateData#state.tls_required,
    SockMod =
	(StateData#state.sockmod):get_sockmod(StateData#state.socket),
    case {xml:get_attr_s(<<"xmlns">>, Attrs), Name} of
      {?NS_SASL, <<"auth">>}
	  when not ((SockMod == gen_tcp) and TLSRequired) ->
	  Mech = xml:get_attr_s(<<"mechanism">>, Attrs),
	  ClientIn = jlib:decode_base64(xml:get_cdata(Els)),
	  case cyrsasl:server_start(StateData#state.sasl_state,
				    Mech, ClientIn)
	      of
	    {ok, Props} ->
		(StateData#state.sockmod):reset_stream(StateData#state.socket),
		%U = xml:get_attr_s(username, Props),
		U = proplists:get_value(username, Props, <<>>),
		%AuthModule = xml:get_attr_s(auth_module, Props),
		AuthModule = proplists:get_value(auth_module, Props, undefined),
		?INFO_MSG("(~w) Accepted authentication for ~s "
			  "by ~p",
			  [StateData#state.socket, U, AuthModule]),
		case catch xml:get_attr_s(<<"id">>, Attrs) of
		<<"">> ->
			send_auth_login_response_sucess(StateData,U,StateData#state.server,<<"0">>,<<"">>);
		ID ->
			send_auth_login_response_sucess(StateData,U,StateData#state.server,ID,<<"">>)
		end,
%		send_auth_msg(StateData,U,StateData#state.server,<<"sucess">>),
%		send_element(StateData,
%			    #xmlel{name = <<"success">>,
%				    attrs = [{<<"xmlns">>, ?NS_SASL}],
%				    children = []}),
		
%%		fsm_next_state(wait_for_stream,
		fsm_next_state(wait_for_bind,
				StateData#state{streamid = new_id(),
						authenticated = true,
						auth_module = AuthModule,
                                                sasl_state = undefined,
						user = U});
	    {continue, ServerOut, NewSASLState} ->
		send_element(StateData,
			     #xmlel{name = <<"challenge">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children =
					[{xmlcdata,
					  jlib:encode_base64(ServerOut)}]}),
		fsm_next_state(wait_for_sasl_response,
			       StateData#state{sasl_state = NewSASLState});
	    {error, Error, Username} ->
		IP = peerip(StateData#state.sockmod, StateData#state.socket),
		?INFO_MSG("(~w) Failed authentication for ~s@~s from IP ~s",
		       [StateData#state.socket,
			Username, StateData#state.server, jlib:ip_to_list(IP)]),
	%	send_element(StateData,
	%		     #xmlel{name = <<"failure">>,
	%			    attrs = [{<<"xmlns">>, ?NS_SASL}],
	%			    children =
	%				[#xmlel{name = Error, attrs = [],
	%					children = []}]}),
        ?DEBUG("Errr ~p ~n",[Error]),

		case catch xml:get_attr_s(<<"id">>, Attrs) of
		<<"">> ->
				send_auth_login_response_failed(StateData,StateData#state.user,StateData#state.server,<<"0">>,Error);
		ID ->
                ?DEBUG("Errr ID  ~p ~n",[ID]),
				send_auth_login_response_failed(StateData,StateData#state.user,StateData#state.server,ID,Error)
		end,		
		fsm_next_state(wait_for_feature_request, StateData);
	    {error, Error} ->
%		send_element(StateData,
%			     #xmlel{name = <<"failure">>,
%				    attrs = [{<<"xmlns">>, ?NS_SASL}],
%				    children =
%					[#xmlel{name = Error, attrs = [],
%						children = []}]}),
		case catch xml:get_attr_s(<<"id">>, Attrs) of
		<<"">> ->
				send_auth_login_response_failed(StateData,StateData#state.user,StateData#state.server,<<"0">>,Error);
		ID ->
				send_auth_login_response_failed(StateData,StateData#state.user,StateData#state.server,ID,Error)
		end,		
		fsm_next_state(wait_for_feature_request, StateData)
	  end;
      {?NS_TLS, <<"starttls">>}
	  when TLS == true, TLSEnabled == false,
        SockMod == gen_tcp ->
	  TLSOpts = case
		      ejabberd_config:get_option(
                        {domain_certfile, StateData#state.server},
                        fun iolist_to_binary/1)
			of
		      undefined -> StateData#state.tls_options;
		      CertFile ->
			  [{certfile, CertFile} | lists:keydelete(certfile, 1,
								  StateData#state.tls_options)]
		    end,
	  Socket = StateData#state.socket,
%	  BProceed = xml:element_to_binary(#xmlel{name = <<"proceed">>,
%						  attrs = [{<<"xmlns">>, ?NS_TLS}]}),
    ?DEBUG("Socket ~p ~n",[Socket]),
      BProceed = send_startTLS(StateData,StateData#state.user,StateData#state.server),
	  TLSSocket = (StateData#state.sockmod):starttls('probuff',Socket,
							 TLSOpts,
							 BProceed),
    ?DEBUG("TLSSocket ~p ~n",[TLSSocket]),
	  fsm_next_state(wait_for_feature_request,
			 StateData#state{socket = TLSSocket,
					 streamid = new_id(),
					 tls_enabled = true});
      {?NS_COMPRESS, <<"compress">>}
	  when Zlib == true,
	       (SockMod == gen_tcp) or (SockMod == p1_tls) ->
	  case xml:get_subtag(El, <<"method">>) of
	    false ->
		send_element(StateData,
			     #xmlel{name = <<"failure">>,
				    attrs = [{<<"xmlns">>, ?NS_COMPRESS}],
				    children =
					[#xmlel{name = <<"setup-failed">>,
						attrs = [], children = []}]}),
		fsm_next_state(wait_for_feature_request, StateData);
	    Method ->
		case xml:get_tag_cdata(Method) of
		  <<"zlib">> ->
		      Socket = StateData#state.socket,
		      BCompressed = xml:element_to_binary(#xmlel{name = <<"compressed">>,
								 attrs = [{<<"xmlns">>, ?NS_COMPRESS}]}),
		      ZlibSocket = (StateData#state.sockmod):compress(Socket,
								      BCompressed),
		      fsm_next_state(wait_for_stream,
				     StateData#state{socket = ZlibSocket,
						     streamid = new_id()});
		  _ ->
		      send_element(StateData,
				   #xmlel{name = <<"failure">>,
					  attrs = [{<<"xmlns">>, ?NS_COMPRESS}],
					  children =
					      [#xmlel{name =
							  <<"unsupported-method">>,
						      attrs = [],
						      children = []}]}),
		      fsm_next_state(wait_for_feature_request, StateData)
		end
	  end;
      _ ->
	  if (SockMod == gen_tcp) and TLSRequired ->
		 Lang = StateData#state.lang,
		 send_element(StateData,
			      ?POLICY_VIOLATION_ERR(Lang,
						    <<"Use of STARTTLS required">>)),
		 send_trailer(StateData),
		 {stop, normal, StateData};
	     true ->
		 process_unauthenticated_stanza(StateData, El),
		 fsm_next_state(wait_for_feature_request, StateData)
	  end
    end;
wait_for_feature_request(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_feature_request({xmlstreamend, _Name},
			 StateData) ->
   %% send_trailer(StateData),
    send_stream_end(StateData),
	{stop, normal, StateData};
wait_for_feature_request({xmlstreamerror, _},
			 StateData) ->
  %  send_element(StateData, ?INVALID_XML_ERR),
   % send_trailer(StateData),
    send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_feature_request(closed, StateData) ->
    {stop, normal, StateData}.

wait_for_sasl_response({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_sasl_response, dispatch_stream_mgmt(El, StateData));
wait_for_sasl_response({xmlstreamelement, El},
		       StateData) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} = El,
    case {xml:get_attr_s(<<"xmlns">>, Attrs), Name} of
      {?NS_SASL, <<"response">>} ->
	  ClientIn = jlib:decode_base64(xml:get_cdata(Els)),
	  case cyrsasl:server_step(StateData#state.sasl_state,
				   ClientIn)
	      of
	    {ok, Props} ->
		catch
		  (StateData#state.sockmod):reset_stream(StateData#state.socket),
%		U = xml:get_attr_s(username, Props),
		U = proplists:get_value(username, Props, <<>>),
%		AuthModule = xml:get_attr_s(auth_module, Props),
		AuthModule = proplists:get_value(auth_module, Props, <<>>),
		?INFO_MSG("(~w) Accepted authentication for ~s "
			  "by ~p",
			  [StateData#state.socket, U, AuthModule]),
		send_element(StateData,
			    #xmlel{name = <<"success">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children = []}),
		fsm_next_state(wait_for_stream,
				StateData#state{streamid = new_id(),
						authenticated = true,
						auth_module = AuthModule,
                                                sasl_state = undefined,
						user = U});
	    {ok, Props, ServerOut} ->
		(StateData#state.sockmod):reset_stream(StateData#state.socket),
%		U = xml:get_attr_s(username, Props),
		U = proplists:get_value(username, Props, <<>>),
%		AuthModule = xml:get_attr_s(auth_module, Props),
		AuthModule = proplists:get_value(auth_module, Props, undefined),
		?INFO_MSG("(~w) Accepted authentication for ~s "
			  "by ~p",
			  [StateData#state.socket, U, AuthModule]),
		send_element(StateData,
			    #xmlel{name = <<"success">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children =
					[{xmlcdata,
					jlib:encode_base64(ServerOut)}]}),
		fsm_next_state(wait_for_stream,
				StateData#state{streamid = new_id(),
						authenticated = true,
						auth_module = AuthModule,
                                                sasl_state = undefined,
						user = U});
	    {continue, ServerOut, NewSASLState} ->
		send_element(StateData,
			     #xmlel{name = <<"challenge">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children =
					[{xmlcdata,
					  jlib:encode_base64(ServerOut)}]}),
		fsm_next_state(wait_for_sasl_response,
			       StateData#state{sasl_state = NewSASLState});
	    {error, Error, Username} ->
		IP = peerip(StateData#state.sockmod, StateData#state.socket),
		?INFO_MSG("(~w) Failed authentication for ~s@~s from IP ~s",
		       [StateData#state.socket,
			Username, StateData#state.server, jlib:ip_to_list(IP)]),
		send_element(StateData,
			     #xmlel{name = <<"failure">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children =
					[#xmlel{name = Error, attrs = [],
						children = []}]}),
		fsm_next_state(wait_for_feature_request, StateData);
	    {error, Error} ->
		send_element(StateData,
			     #xmlel{name = <<"failure">>,
				    attrs = [{<<"xmlns">>, ?NS_SASL}],
				    children =
					[#xmlel{name = Error, attrs = [],
						children = []}]}),
		fsm_next_state(wait_for_feature_request, StateData)
	  end;
      _ ->
	  process_unauthenticated_stanza(StateData, El),
	  fsm_next_state(wait_for_feature_request, StateData)
    end;
wait_for_sasl_response(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_sasl_response({xmlstreamend, _Name},
		       StateData) ->
   % send_trailer(StateData),
    send_stream_end(StateData),
	{stop, normal, StateData};
wait_for_sasl_response({xmlstreamerror, _},
		       StateData) ->
    %send_element(StateData, ?INVALID_XML_ERR),
	send_stream_end(StateData),
%    send_trailer(StateData),
    {stop, normal, StateData};
wait_for_sasl_response(closed, StateData) ->
    {stop, normal, StateData}.

resource_conflict_action(U, S, R) ->
    OptionRaw = case ejabberd_sm:is_existing_resource(U, S, R) of
		  true ->
		      ejabberd_config:get_option(
                        {resource_conflict, S},
                        fun(setresource) -> setresource;
                           (closeold) -> closeold;
                           (closenew) -> closenew;
                           (acceptnew) -> acceptnew
                        end);
                  false ->
                      acceptnew
		end,
    Option = case OptionRaw of
	       setresource -> setresource;
	       closeold ->
		   acceptnew; %% ejabberd_sm will close old session
	       closenew -> closenew;
	       acceptnew -> acceptnew;
	       _ -> acceptnew %% default ejabberd behavior
	     end,
    case Option of
      acceptnew -> {accept_resource, R};
      closenew -> closenew;
      setresource ->
	  Rnew = iolist_to_binary([randoms:get_string()
                                   | [jlib:integer_to_binary(X)
                                      || X <- tuple_to_list(os:timestamp())]]),
	  {accept_resource, Rnew}
    end.

wait_for_bind({xmlstreamelement, #xmlel{name = Name, attrs = Attrs} = El},
	      StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    case Name of
      <<"resume">> ->
	  case handle_resume(StateData, Attrs) of
	    {ok, ResumedState} ->
		fsm_next_state(session_established, ResumedState);
	    error ->
		fsm_next_state(wait_for_bind, StateData)
	  end;
      _ ->
	  fsm_next_state(wait_for_bind, dispatch_stream_mgmt(El, StateData))
    end;
wait_for_bind({xmlstreamelement, El}, StateData) ->
    case jlib:iq_query_info(El) of
      #iq{type = set, xmlns = ?NS_BIND, sub_el = SubEl,id = ID} =
	  IQ ->
	  U = StateData#state.user,
	  R1 = xml:get_path_s(SubEl,
			      [{elem, <<"resource">>}, cdata]),
	  R = case jlib:resourceprep(R1) of
		error -> error;
		<<"">> ->
                      iolist_to_binary([randoms:get_string()
                                        | [jlib:integer_to_binary(X)
                                           || X <- tuple_to_list(os:timestamp())]]);
		Resource -> Resource
	      end,
	  case R of
	    error ->
		Err = jlib:make_error_reply(El, ?ERR_BAD_REQUEST),
		send_element(StateData, Err),
		fsm_next_state(wait_for_bind, StateData);
	    _ ->
		case resource_conflict_action(U, StateData#state.server,
					      R)
		    of
		  closenew ->
		      Err = jlib:make_error_reply(El,
						  ?STANZA_ERROR(<<"409">>,
								<<"modify">>,
								<<"conflict">>)),
		      send_element(StateData, Err),
		      fsm_next_state(wait_for_bind, StateData);
		  {accept_resource, R2} ->
		      JID = jlib:make_jid(U, StateData#state.server, R2),
		      Res = IQ#iq{type = result,
				  sub_el =
				      [#xmlel{name = <<"bind">>,
					      attrs = [{<<"xmlns">>, ?NS_BIND}],
					      children =
						  [#xmlel{name = <<"jid">>,
							  attrs = [],
							  children =
							      [{xmlcdata,
								jlib:jid_to_string(JID)}]}]}]},
			  Key = iolist_to_binary([integer_to_binary(random:uniform(65536)) | [jlib:integer_to_binary(X)|| X <- tuple_to_list(os:timestamp())]]),	
              ejabberd_public:set_redis_user_key(StateData#state.server,U,R2,Key,R2,86400*3),
			  NewState = StateData#state{key = Key,key_flag = true},
              send_element(NewState, jlib:iq_to_xml(Res)),
	    	  case acl:match_rule(NewState#state.server,
					NewState#state.access, JID) of
			  allow ->
		    		?INFO_MSG("(~w) Opened session for ~s",     [NewState#state.socket,  jlib:jid_to_string(JID)]),
		    		LJID = jlib:jid_tolower(jlib:jid_remove_resource(JID)),
		    		Conn = get_conn_type(NewState),
		    		Info = [{ip, NewState#state.ip}, {conn, Conn},
			    		{auth_module, NewState#state.auth_module}],

		    		ejabberd_sm:open_session( NewState#state.sid, U, NewState#state.server, R, Info),
                    UpdatedStateData = NewState#state{ conn = Conn,	    
%					   	pres_f = ?SETS:from_list(Fs1),   pres_t = ?SETS:from_list(Ts1),     privacy_list = PrivList,
					   		resource = R2, jid = JID},
					update_priority(5, <<"">>, UpdatedStateData),
		   			fsm_next_state_pack(session_established,  UpdatedStateData);
			_ ->
		    		fsm_next_state(session_established,
			    		 StateData#state{resource = R2, jid = JID})
			end
		end
	  end;
      _ -> fsm_next_state(session_established, StateData)
    end;
wait_for_bind(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_bind({xmlstreamend, _Name}, StateData) ->
   % send_trailer(StateData), 
    send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_bind({xmlstreamerror, _}, StateData) ->
%    send_element(StateData, ?INVALID_XML_ERR),
 %   send_trailer(StateData),
 	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_bind(closed, StateData) ->
    {stop, normal, StateData}.

wait_for_session({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_session, dispatch_stream_mgmt(El, StateData));
wait_for_session({xmlstreamelement, El}, StateData) ->
    NewStateData = update_num_stanzas_in(StateData, El),
    case jlib:iq_query_info(El) of
	#iq{type = set, xmlns = ?NS_SESSION} ->
	    U = NewStateData#state.user,
	    R = NewStateData#state.resource,
	    JID = NewStateData#state.jid,
	    case acl:match_rule(NewStateData#state.server,
				NewStateData#state.access, JID) of
		allow ->
		    ?INFO_MSG("(~w) Opened session for ~s",
			      [NewStateData#state.socket,
			       jlib:jid_to_string(JID)]),
		    Res = jlib:make_result_iq_reply(El#xmlel{children = []}),
		    NewState = send_stanza(NewStateData, Res),
		    change_shaper(NewState, JID),
		    {Fs, Ts} = ejabberd_hooks:run_fold(
				 roster_get_subscription_lists,
				 NewState#state.server,
				 {[], []},
				 [U, NewState#state.server]),
		    LJID = jlib:jid_tolower(jlib:jid_remove_resource(JID)),
		    Fs1 = [LJID | Fs],
		    Ts1 = [LJID | Ts],
		    PrivList =
			ejabberd_hooks:run_fold(
			  privacy_get_user_list, NewState#state.server,
			  #userlist{},
			  [U, NewState#state.server]),
		    Conn = get_conn_type(NewState),
		    Info = [{ip, NewState#state.ip}, {conn, Conn},
			    {auth_module, NewState#state.auth_module}],
                
             case catch ejabberd_auth_odbc:check_multiple_login_user(U) of
             false ->
                update_push_flag(StateData#state.server,U,R);
             _ ->
                ok
             end,
    
		    ejabberd_sm:open_session(
		      NewState#state.sid, U, NewState#state.server, R, Info),
                    UpdatedStateData =
                        NewState#state{
				     conn = Conn,
				     pres_f = ?SETS:from_list(Fs1),
				     pres_t = ?SETS:from_list(Ts1),
				     privacy_list = PrivList},

		    fsm_next_state_pack(session_established,
                                        UpdatedStateData);
		_ ->
		    ejabberd_hooks:run(forbidden_session_hook,
				       NewStateData#state.server, [JID]),
		    ?INFO_MSG("(~w) Forbidden session for ~s",
			      [NewStateData#state.socket,
			       jlib:jid_to_string(JID)]),
		    Err = jlib:make_error_reply(El, ?ERR_NOT_ALLOWED),
		    send_element(NewStateData, Err),
		    fsm_next_state(wait_for_session, NewStateData)
	    end;
	_ ->
	    fsm_next_state(wait_for_session, NewStateData)
    end;

wait_for_session(timeout, StateData) ->
    {stop, normal, StateData};
wait_for_session({xmlstreamend, _Name}, StateData) ->
   % send_trailer(StateData), 
   send_stream_end(StateData),
   {stop, normal, StateData};
wait_for_session({xmlstreamerror, _}, StateData) ->
%    send_element(StateData, ?INVALID_XML_ERR),
 %   send_trailer(StateData),
 	send_stream_end(StateData),
    {stop, normal, StateData};
wait_for_session(closed, StateData) ->
    {stop, normal, StateData}.

session_established({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
    when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(session_established, dispatch_stream_mgmt(El, StateData));
session_established({xmlstreamelement, El},
		    StateData) ->
    FromJID = StateData#state.jid,
	Resource = FromJID#jid.resource,
	User = FromJID#jid.user,
	LServer = jlib:nameprep(FromJID#jid.server),
	?DEBUG("El ~p ~n",[El]),
	NewStateData =
		send_time_key_presence(LServer,User,Resource,StateData),	
				
    case check_from(El, FromJID) of
	'invalid-from' ->
	    send_element(StateData, ?INVALID_FROM),
%%	    send_trailer(StateData),
%%	    {stop, normal, StateData};
		send_stream_end(StateData),
	    {stop, normal, NewStateData};
	_NewEl ->
%		session_established2 msg in this
%%	    session_established2(El, StateData)
	    session_established2(El, NewStateData)
    end;
%% We hibernate the process to reduce memory consumption after a
%% configurable activity timeout
session_established(timeout, StateData) ->
    Options = [],
    proc_lib:hibernate(?GEN_FSM, enter_loop,
		       [?MODULE, Options, session_established, StateData]),
    fsm_next_state(session_established, StateData);
session_established({xmlstreamend, _Name}, StateData) ->
%%    send_trailer(StateData),
	send_stream_end(StateData),
	{stop, normal, StateData};
session_established({xmlstreamerror,
		     <<"XML stanza is too big">> = E},
		    StateData) ->
 %   send_element(StateData,
%		 ?POLICY_VIOLATION_ERR((StateData#state.lang), E)),
 %   send_trailer(StateData),
	send_stream_end(StateData),
    {stop, normal, StateData};
session_established({xmlstreamerror, _}, StateData) ->
%    send_element(StateData, ?INVALID_XML_ERR),
%   send_trailer(StateData),
	send_stream_end(StateData),
    {stop, normal, StateData};
session_established(closed, StateData)
    when StateData#state.mgmt_timeout > 0,
	 StateData#state.mgmt_state == active ->
    fsm_next_state(wait_for_resume, StateData);
session_established(closed, StateData) ->
    {stop, normal, StateData}.

%% Process packets sent by user (coming from user on c2s XMPP
%% connection)
session_established2(El, StateData) ->
    #xmlel{name = Name, attrs = Attrs} = El,
	?DEBUG("El ~p ~n",[El]),
    NewStateData = update_num_stanzas_in(StateData, El),
    User = NewStateData#state.user,
    Server = NewStateData#state.server,
    FromJID = NewStateData#state.jid,
    To = xml:get_attr_s(<<"to">>, Attrs),
    ToJID = case To of
	      <<"">> -> jlib:make_jid(User, Server, <<"">>);
	      _ -> jlib:string_to_jid(To)
	    end,
    NewEl1 = jlib:remove_attr(<<"xmlns">>, El),
    NewEl = case xml:get_attr_s(<<"xml:lang">>, Attrs) of
	      <<"">> ->
		  case NewStateData#state.lang of
		    <<"">> -> NewEl1;
		    Lang ->
			xml:replace_tag_attr(<<"xml:lang">>, Lang, NewEl1)
		  end;
	      _ -> NewEl1
	    end,
    NewState = case ToJID of
		 error ->
		     case xml:get_attr_s(<<"type">>, Attrs) of
		       <<"error">> -> NewStateData;
		       <<"result">> -> NewStateData;
		       _ ->
			   Err = jlib:make_error_reply(NewEl,
						       ?ERR_JID_MALFORMED),
			   send_packet(NewStateData, Err)
		     end;
		 _ ->
		     case Name of
		       <<"presence">> ->
			   PresenceEl =
			   	   case catch xml:get_attr_s(<<"xmlns">>, Attrs) of 
				   ?NS_VER_FRI ->
				   		El;
			       ?NS_MUC_INVITE ->
		               El;
		           ?NS_MUC_DEL_REGISTER->
				   	   El;
					_ ->
			       		ejabberd_hooks:run_fold(c2s_update_presence,
							       Server, NewEl,
							       [User, Server])
					end,
			   ejabberd_hooks:run(user_send_packet, Server,
					      [FromJID, ToJID, PresenceEl]),
			   case ToJID of
			     #jid{user = User, server = Server,
				  resource = <<"">>} ->
				 ?DEBUG("presence_update(~p,~n\t~p,~n\t~p)",
					[FromJID, PresenceEl, NewStateData]),
				 presence_update(FromJID, PresenceEl,
						 NewStateData);
			     _ ->
				 presence_track(FromJID, ToJID, PresenceEl,
						NewStateData)
			   end;
		       <<"iq">> ->
			   case jlib:iq_query_info(NewEl) of
			     #iq{xmlns = Xmlns} = IQ
				 when Xmlns == (?NS_PRIVACY);
				      Xmlns == (?NS_BLOCKING) ->
				 process_privacy_iq(FromJID, ToJID, IQ,
						    NewStateData);
			     _ ->
				 ejabberd_hooks:run(user_send_packet, Server,
						    [FromJID, ToJID, NewEl]),
				 check_privacy_route(FromJID, NewStateData,
						     FromJID, ToJID, NewEl),
				 NewStateData
			   end;
		       <<"message">> ->
			   NewPacket = do_sent_repley(NewEl,FromJID,NewStateData),
			   ejabberd_hooks:run(user_send_packet, Server,
					      [FromJID, ToJID, NewPacket]),
			%%		      [FromJID, ToJID, NewEl]),
				?DEBUG("message ~p ~n",[NewPacket]),
			   case check_privacy_route(FromJID, NewStateData, FromJID,
					       ToJID, NewPacket) of
			   deny ->
			   		ok;
				_ ->
					carbon_message(FromJID,ToJID,NewPacket)
			    end,
			   NewStateData;
		       _ -> NewStateData
		     end
	       end,
    ejabberd_hooks:run(c2s_loop_debug,
		       [{xmlstreamelement, El}]),
    fsm_next_state(session_established, NewState).

wait_for_resume({xmlstreamelement, _El} = Event, StateData) ->
    session_established(Event, StateData),
    fsm_next_state(wait_for_resume, StateData);
wait_for_resume(timeout, StateData) ->
    ?DEBUG("Timed out waiting for resumption of stream for ~s",
	   [jlib:jid_to_string(StateData#state.jid)]),
    {stop, normal, StateData};
wait_for_resume(Event, StateData) ->
    ?DEBUG("Ignoring event while waiting for resumption: ~p", [Event]),
    fsm_next_state(wait_for_resume, StateData).

%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
%state_name(Event, From, StateData) ->
%    Reply = ok,
%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(_Event, StateName, StateData) ->
    fsm_next_state(StateName, StateData).

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event({get_presence}, _From, StateName,
		  StateData) ->
    User = StateData#state.user,
    PresLast = StateData#state.pres_last,
    Show = get_showtag(PresLast),
    Status = get_statustag(PresLast),
    Resource = StateData#state.resource,
    Reply = {User, Resource, Show, Status},
    fsm_reply(Reply, StateName, StateData);
handle_sync_event(get_subscribed, _From, StateName,
		  StateData) ->
    Subscribed = (?SETS):to_list(StateData#state.pres_f),
    {reply, Subscribed, StateName, StateData};
handle_sync_event({resume_session, Time}, _From, _StateName,
		  StateData) when element(1, StateData#state.sid) == Time ->
    %% The old session should be closed before the new one is opened, so we do
    %% this here instead of leaving it to the terminate callback
    ejabberd_sm:close_session(StateData#state.sid,
			      StateData#state.user,
			      StateData#state.server,
			      StateData#state.resource),
    {stop, normal, {ok, StateData}, StateData#state{mgmt_state = resumed}};
handle_sync_event({resume_session, _Time}, _From, StateName,
		  StateData) ->
    {reply, {error, <<"Previous session not found">>}, StateName, StateData};
handle_sync_event(_Event, _From, StateName,
		  StateData) ->
    Reply = ok, fsm_reply(Reply, StateName, StateData).

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    ejabberd_hooks:run(c2s_loop_debug, [Text]),
    fsm_next_state(StateName, StateData);
handle_info(replaced, StateName, StateData) ->
    Lang = StateData#state.lang,
    Xmlelement = ?SERRT_CONFLICT(Lang, <<"Replaced by new connection">>),
    handle_info({kick, replaced, Xmlelement}, StateName, StateData);
handle_info(kick, StateName, StateData) ->
    Lang = StateData#state.lang,
    Xmlelement = ?SERRT_POLICY_VIOLATION(Lang, <<"has been kicked">>),
    handle_info({kick, kicked_by_admin, Xmlelement}, StateName, StateData);
handle_info({kick, Reason, Xmlelement}, _StateName, StateData) ->
%    send_element(StateData, Xmlelement),
 %   send_trailer(StateData),
 	send_stream_end(StateData),
    {stop, normal,
     StateData#state{authenticated = Reason}};
handle_info({route, _From, _To, {broadcast, Data}},
            StateName, StateData) ->
    ?DEBUG("broadcast~n~p~n", [Data]),
    case Data of
        {item, IJID, ISubscription} ->
            fsm_next_state(StateName,
                           roster_change(IJID, ISubscription, StateData));
        {exit, Reason} ->
            Lang = StateData#state.lang,
            send_element(StateData, ?SERRT_CONFLICT(Lang, Reason)),
            catch send_trailer(StateData),
            {stop, normal, StateData};
        {privacy_list, PrivList, PrivListName} ->
            case ejabberd_hooks:run_fold(privacy_updated_list,
                                         StateData#state.server,
                                         false,
                                         [StateData#state.privacy_list,
                                          PrivList]) of
                false ->
                    fsm_next_state(StateName, StateData);
                NewPL ->
                    PrivPushIQ = #iq{type = set,
                                     id = <<"push",
                                            (randoms:get_string())/binary>>,
                                     sub_el =
                                         [#xmlel{name = <<"query">>,
                                                 attrs = [{<<"xmlns">>,
                                                           ?NS_PRIVACY}],
                                                 children =
                                                     [#xmlel{name = <<"list">>,
                                                             attrs = [{<<"name">>,
                                                                       PrivListName}],
                                                             children = []}]}]},
                    PrivPushEl = jlib:replace_from_to(
                                   jlib:jid_remove_resource(StateData#state.jid),
                                   StateData#state.jid,
                                   jlib:iq_to_xml(PrivPushIQ)),
                    NewState = send_stanza(StateData, PrivPushEl),
                    fsm_next_state(StateName,
                                   NewState#state{privacy_list = NewPL})
            end;
        {blocking, What} ->
            NewState = route_blocking(What, StateData),
            fsm_next_state(StateName, NewState);
        _ ->
            fsm_next_state(StateName, StateData)
    end;
%% Process Packets that are to be send to the user
handle_info({route, From, To,
             #xmlel{name = Name, attrs = Attrs, children = Els} = Packet},
            StateName, StateData) ->
			?DEBUG("send_msg_to_pakcet ~p ~n",[Packet]),
    {Pass, NewAttrs, NewState} = case Name of
				   <<"presence">> ->
				       State =
					   ejabberd_hooks:run_fold(c2s_presence_in,
								   StateData#state.server,
								   StateData,
								   [{From, To,
								     Packet}]),
				       case xml:get_attr_s(<<"type">>, Attrs) of
					 <<"probe">> ->
					     LFrom = jlib:jid_tolower(From),
					     LBFrom =
						 jlib:jid_remove_resource(LFrom),
					     NewStateData = case
							      (?SETS):is_element(LFrom,
										 State#state.pres_a)
								orelse
								(?SETS):is_element(LBFrom,
										   State#state.pres_a)
								of
							      true -> State;
							      false ->
								  case
								    (?SETS):is_element(LFrom,
										       State#state.pres_f)
								      of
								    true ->
									A =
									    (?SETS):add_element(LFrom,
												State#state.pres_a),
									State#state{pres_a
											=
											A};
								    false ->
									case
									  (?SETS):is_element(LBFrom,
											     State#state.pres_f)
									    of
									  true ->
									      A =
										  (?SETS):add_element(LBFrom,
												      State#state.pres_a),
									      State#state{pres_a
											      =
											      A};
									  false ->
									      State
									end
								  end
							    end,
					     process_presence_probe(From, To,
								    NewStateData),
					     {false, Attrs, NewStateData};
					 <<"error">> ->
					     NewA =
						 remove_element(jlib:jid_tolower(From),
								State#state.pres_a),
					     {true, Attrs,
					      State#state{pres_a = NewA}};
					 <<"subscribe">> ->
					     SRes = is_privacy_allow(State,
								     From, To,
								     Packet,
								     in),
					     {SRes, Attrs, State};
					 <<"subscribed">> ->
					     SRes = is_privacy_allow(State,
								     From, To,
								     Packet,
								     in),
					     {SRes, Attrs, State};
					 <<"unsubscribe">> ->
					     SRes = is_privacy_allow(State,
								     From, To,
								     Packet,
								     in),
					     {SRes, Attrs, State};
					 <<"unsubscribed">> ->
					     SRes = is_privacy_allow(State,
								     From, To,
								     Packet,
								     in),
					     {SRes, Attrs, State};
					 _ ->
					     case privacy_check_packet(State,
								       From, To,
								       Packet,
								       in)
						 of
					       allow ->
						   LFrom =
						       jlib:jid_tolower(From),
						   LBFrom =
						       jlib:jid_remove_resource(LFrom),
						   case
						     (?SETS):is_element(LFrom,
									State#state.pres_a)
						       orelse
						       (?SETS):is_element(LBFrom,
									  State#state.pres_a)
						       of
						     true ->
							 {true, Attrs, State};
						     false ->
							 case
							   (?SETS):is_element(LFrom,
									      State#state.pres_f)
							     of
							   true ->
							       A =
								   (?SETS):add_element(LFrom,
										       State#state.pres_a),
							       {true, Attrs,
								State#state{pres_a
										=
										A}};
							   false ->
							       case
								 (?SETS):is_element(LBFrom,
										    State#state.pres_f)
								   of
								 true ->
								     A =
									 (?SETS):add_element(LBFrom,
											     State#state.pres_a),
								     {true,
								      Attrs,
								      State#state{pres_a
										      =
										      A}};
								 false ->
								     {true,
								      Attrs,
								      State}
							       end
							 end
						   end;
					       deny -> {false, Attrs, State}
					     end
				       end;
				   <<"iq">> ->
				       IQ = jlib:iq_query_info(Packet),
				       case IQ of
					 #iq{xmlns = ?NS_LAST} ->
					     LFrom = jlib:jid_tolower(From),
					     LBFrom =
						 jlib:jid_remove_resource(LFrom),
					     HasFromSub =
						 ((?SETS):is_element(LFrom,
								     StateData#state.pres_f)
						    orelse
						    (?SETS):is_element(LBFrom,
								       StateData#state.pres_f))
						   andalso
						   is_privacy_allow(StateData,
								    To, From,
								    #xmlel{name
									       =
									       <<"presence">>,
									   attrs
									       =
									       [],
									   children
									       =
									       []},
								    out),
					     case HasFromSub of
					       true ->
						   case
						     privacy_check_packet(StateData,
									  From,
									  To,
									  Packet,
									  in)
						       of
						     allow ->
							 {true, Attrs,
							  StateData};
						     deny ->
							 {false, Attrs,
							  StateData}
						   end;
					       _ ->
						   Err =
						       jlib:make_error_reply(Packet,
									     ?ERR_FORBIDDEN),
						   ejabberd_router:route(To,
									 From,
									 Err),
						   {false, Attrs, StateData}
					     end;
					 IQ
					     when is_record(IQ, iq) or
						    (IQ == reply) ->
					     case
					       privacy_check_packet(StateData,
								    From, To,
								    Packet, in)
						 of
					       allow ->
						   {true, Attrs, StateData};
					       deny when is_record(IQ, iq) ->
						   Err =
						       jlib:make_error_reply(Packet,
									     ?ERR_SERVICE_UNAVAILABLE),
						   ejabberd_router:route(To,
									 From,
									 Err),
						   {false, Attrs, StateData};
					       deny when IQ == reply ->
						   {false, Attrs, StateData}
					     end;
					 IQ
					     when (IQ == invalid) or
						    (IQ == not_iq) ->
					     {false, Attrs, StateData}
				       end;
				   <<"message">> ->
				       case privacy_check_packet(StateData,
								 From, To,
								 Packet, in)
					   of
					 allow -> {true, Attrs, StateData};
					 deny -> {false, Attrs, StateData}
				       end;
				   _ -> {true, Attrs, StateData}
				 end,
    if Pass == exit ->
	    %% When Pass==exit, NewState contains a string instead of a #state{}
	   % Lang = StateData#state.lang,
	   % send_element(StateData, ?SERRT_CONFLICT(Lang, NewState)),
%	    send_trailer(StateData),
		send_stream_end(StateData),
	    {stop, normal, StateData};
	Pass ->
	    Attrs2 =
	       jlib:replace_from_to_attrs(jlib:jid_to_string(From),
					  jlib:jid_to_string(To), NewAttrs),
	    FixedPacket = #xmlel{name = Name, attrs = Attrs2, children = Els},
		%% send msg to client
	%%    SentStateData = send_packet(NewState, FixedPacket),
		SentStateData = NewState,
%%		send_probuf_msg(Name,NewState,To,From,FixedPacket,Attrs2),
        ?DEBUG("Packet ~p ~n",[Packet]),
        send_probuf_msg(StateData, FixedPacket),
	    ejabberd_hooks:run(user_receive_packet,
			       SentStateData#state.server,
			       [SentStateData#state.jid, From, To, FixedPacket]),
	    ejabberd_hooks:run(c2s_loop_debug, [{route, From, To, Packet}]),
	    fsm_next_state(StateName, SentStateData);
	true ->
	    ejabberd_hooks:run(c2s_loop_debug, [{route, From, To, Packet}]),
	    fsm_next_state(StateName, NewState)
    end;
handle_info({'DOWN', Monitor, _Type, _Object, _Info},
	    _StateName, StateData)
    when Monitor == StateData#state.socket_monitor ->
    if StateData#state.mgmt_timeout > 0,
       StateData#state.mgmt_state == active orelse
       StateData#state.mgmt_state == pending ->
	   fsm_next_state(wait_for_resume, StateData);
       true ->
	   {stop, normal, StateData}
    end;
handle_info(system_shutdown, StateName, StateData) ->
    case StateName of
      wait_for_stream ->
	  send_header(StateData, ?MYNAME, <<"1.0">>, <<"en">>),
	  send_element(StateData, ?SERR_SYSTEM_SHUTDOWN),
	 % send_trailer(StateData),
	  send_stream_end(StateData),
	  ok;
      _ ->
%	  send_element(StateData, ?SERR_SYSTEM_SHUTDOWN),
	
	%  send_trailer(StateData),
	  send_stream_end(StateData),
	  ok
    end,
    {stop, normal, StateData};
handle_info({force_update_presence, LUser}, StateName,
	    #state{user = LUser, server = LServer} = StateData) ->
    NewStateData = case StateData#state.pres_last of
		     #xmlel{name = <<"presence">>} ->
			 PresenceEl =
			     ejabberd_hooks:run_fold(c2s_update_presence,
						     LServer,
						     StateData#state.pres_last,
						     [LUser, LServer]),
			 StateData2 = StateData#state{pres_last = PresenceEl},
			 presence_update(StateData2#state.jid, PresenceEl,
					 StateData2),
			 StateData2;
		     _ -> StateData
		   end,
    fsm_next_state(StateName, NewStateData);
handle_info({broadcast, Type, From, Packet}, StateName, StateData) ->
    Recipients = ejabberd_hooks:run_fold(
		   c2s_broadcast_recipients, StateData#state.server,
		   [],
		   [StateData#state.server, StateData, Type, From, Packet]),
    lists:foreach(
      fun(USR) ->
	      ejabberd_router:route(
		From, jlib:make_jid(USR), Packet)
      end, lists:usort(Recipients)),
    fsm_next_state(StateName, StateData);
handle_info({update_presence_a,Muc}, StateName, StateData) ->
	?DEBUG("state pres_a jid ~p ,~p ~n",[Muc,StateData#state.pres_a]),
	Jid_muc = jlib:jid_tolower(Muc),
   	A1 =  remove_element(Jid_muc, StateData#state.pres_a),
	?DEBUG("state pres_a ~p ~n",[StateData#state.pres_a]),
	A2 = (?SETS):add_element(Jid_muc, A1),
	NewStateData =	StateData#state{pres_a =  A2},
    fsm_next_state(StateName, NewStateData);
handle_info({remove_presence_a,Muc}, StateName, StateData) ->
	Jid_muc = jlib:jid_tolower(Muc),
   	A =  remove_element(Jid_muc, StateData#state.pres_a),
	NewStateData =	StateData#state{pres_a =  A},
    fsm_next_state(StateName, NewStateData);
handle_info(print_presence_a, StateName, StateData) ->
	?DEBUG("state pres_a ~p ~n",[StateData#state.pres_a]),
	fsm_next_state(StateName, StateData);
handle_info(Info, StateName, StateData) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    fsm_next_state(StateName, StateData).


%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State = #state{pres_t = T, pres_f = F, pres_a = A, pres_i = I}) ->
   State#state{pres_t = {pres_t, ?SETS:size(T)},
               pres_f = {pres_f, ?SETS:size(F)},
               pres_a = {pres_a, ?SETS:size(A)},
               pres_i = {pres_i, ?SETS:size(I)}
               }.
    
%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, StateName, StateData) ->
    case StateData#state.mgmt_state of
      resumed ->
	  ?INFO_MSG("Closing former stream of resumed session for ~s",
		    [jlib:jid_to_string(StateData#state.jid)]);
      _ ->
	  if StateName == session_established;
	     StateName == wait_for_resume ->
		 case StateData#state.authenticated of
		   replaced ->
		       ?INFO_MSG("(~w) Replaced session for ~s",
				 [StateData#state.socket,
				  jlib:jid_to_string(StateData#state.jid)]),
		       From = StateData#state.jid,
		       Packet = #xmlel{name = <<"presence">>,
				       attrs = [{<<"type">>, <<"unavailable">>}],
				       children =
					   [#xmlel{name = <<"status">>, attrs = [],
						   children =
						       [{xmlcdata,
							 <<"Replaced by new connection">>}]}]},
		       ejabberd_sm:close_session_unset_presence(StateData#state.sid,
								StateData#state.user,
								StateData#state.server,
								StateData#state.resource,
								<<"Replaced by new connection">>),
		       presence_broadcast(StateData, From,
					  StateData#state.pres_a, Packet),
		       presence_broadcast(StateData, From,
					  StateData#state.pres_i, Packet),
		       handle_unacked_stanzas(StateData);
		   _ ->
		       ?INFO_MSG("(~w) Close session for ~s,Reason ~p ",
				 [StateData#state.socket,
				  jlib:jid_to_string(StateData#state.jid),Reason]),
               catch mod_monitor:monitor_count(StateData#state.server,<<"close_session">>,1),
		       EmptySet = (?SETS):new(),
		       case StateData of
			 #state{pres_last = undefined,
				pres_a = EmptySet,
				pres_i = EmptySet,
				pres_invis = false} ->
			     ejabberd_sm:close_session(StateData#state.sid,
						       StateData#state.user,
						       StateData#state.server,
						       StateData#state.resource);
			 _ ->
			     From = StateData#state.jid,
			     Packet = #xmlel{name = <<"presence">>,
					     attrs = [{<<"type">>, <<"unavailable">>}],
					     children = []},
			     ejabberd_sm:close_session_unset_presence(StateData#state.sid,
								      StateData#state.user,
								      StateData#state.server,
								      StateData#state.resource,
								      <<"">>),
			     presence_broadcast(StateData, From,
						StateData#state.pres_a, Packet),
			     presence_broadcast(StateData, From,
						StateData#state.pres_i, Packet)
		       end,
		       handle_unacked_stanzas(StateData)
		 end,
		 bounce_messages();
	     true ->
		 ok
	  end
    end,
    ejabberd_public:clear_redis_user_key(StateData#state.server,StateData#state.user,StateData#state.resource),
    (StateData#state.sockmod):close(StateData#state.socket),
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

change_shaper(StateData, JID) ->
    Shaper = acl:match_rule(StateData#state.server,
			    StateData#state.shaper, JID),
    (StateData#state.sockmod):change_shaper(StateData#state.socket,
					    Shaper).

send_text(StateData, Text) when StateData#state.mgmt_state == pending ->
    ?DEBUG("Cannot send text while waiting for resumption: ~p", [Text]);
send_text(StateData, Text) when StateData#state.xml_socket ->
    ?DEBUG("Send Text on stream = ~p", [Text]),
    (StateData#state.sockmod):send_xml(StateData#state.socket, 
				       {xmlstreamraw, Text});
send_text(StateData, Text) when StateData#state.mgmt_state == active ->
    ?DEBUG("Send XML on stream = ~p,size ~p ", [Text,size(Text)]),
    case catch (StateData#state.sockmod):send(StateData#state.socket, Text) of
      {'EXIT', _} ->
	  (StateData#state.sockmod):close(StateData#state.socket);
      _ ->
	  ok
    end;
send_text(StateData, Text) ->
%%	case judge_log_to_write(Text) of
%%	true ->
%%		?INFO_MSG("[Send XML on stream] ~s, ~p ", [Text,StateData#state.socket]);
%%	_ ->
		?DEBUG("[Send XML on stream] ~p, ~p ,~p", [Text,StateData#state.socket, size(Text)]),
%%		ok
%%	end,
    (StateData#state.sockmod):send(StateData#state.socket, Text).

send_element(StateData, El) when StateData#state.mgmt_state == pending ->
    catch ?DEBUG("Cannot send element while waiting for resumption: ~p", [El]);
%send_element(StateData, El) when StateData#state.xml_socket ->
 %   (StateData#state.sockmod):send_xml(StateData#state.socket,
%				       {xmlstreamelement, El});
send_element(StateData, El) ->
    catch mod_monitor:monitor_count(StateData#state.server,<<"probuf_user_send_msg">>,1),
    send_probuf_msg(StateData, El).
 % %  send_text(StateData, xml:element_to_binary(El)).
 %%	send_protobuf_text(StateData,El).

send_stanza(StateData, Stanza) when StateData#state.mgmt_state == pending ->
    mgmt_queue_add(StateData, Stanza);
send_stanza(StateData, Stanza) when StateData#state.mgmt_state == active ->
    send_stanza_and_ack_req(StateData, Stanza),
    mgmt_queue_add(StateData, Stanza);
send_stanza(StateData, Stanza) ->
    send_element(StateData, Stanza),
    StateData.

send_probuf_msg(<<"message">>,StateData,From,To, Packet,Attrs) ->
	JFrom = jlib:jid_to_string({From#jid.luser,From#jid.lserver,<<"">>}),
	JTo =  jlib:jid_to_string({To#jid.luser,To#jid.lserver,<<"">>}),

	MsgId = xml:get_tag_attr_s(<<"id">>,xml:get_subtag(Packet,<<"body">>)),
	MsgType = xml:get_tag_attr_s(<<"msgType">>,xml:get_subtag(Packet,<<"body">>)),
	Type = xml:get_attr_s(<<"type">>, Attrs),
	ID = xml:get_attr_s(<<"id">>, Attrs),
	Body = xml:get_subtag_cdata(Packet, <<"body">>),
	
	Msg = ejabberd_encode_protobuf:encode_pb_message('MessageTypeText','ClientTypeiOS',1,MsgId,Body,ID),
	PbMsg = ejabberd_encode_protobuf:encode_pb_protomessage(JFrom,JTo,'SignalTypeChat',0,Msg),
	Message = list_to_binary(ejabberd_encode_protobuf:encode_pb_protoheader(0,PbMsg)),

	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(Message),Message),
	?DEBUG("Send Message  Text ~p ~n",[Text]),
	send_text(StateData, Text);
send_probuf_msg(_,StateData, From,To,Packet,Attrs) ->
	send_packet(StateData, Packet).

send_packet(StateData, Packet) when StateData#state.mgmt_state == active;
				    StateData#state.mgmt_state == pending ->
    case is_stanza(Packet) of
      true ->
	  send_stanza(StateData, Packet);
      false ->
	  send_element(StateData, Packet),
	  StateData
    end;
%% send msg to client
send_packet(StateData, Stanza) ->
    send_element(StateData, Stanza),
    StateData.

send_header(StateData, Server, Version, Lang)
    when StateData#state.xml_socket ->
    VersionAttr = case Version of
		    <<"">> -> [];
		    _ -> [{<<"version">>, Version}]
		  end,
    LangAttr = case Lang of
		 <<"">> -> [];
		 _ -> [{<<"xml:lang">>, Lang}]
	       end,
    Header = {xmlstreamstart, <<"stream:stream">>,
	      VersionAttr ++
		LangAttr ++
		  [{<<"xmlns">>, <<"jabber:client">>},
		   {<<"xmlns:stream">>,
		    <<"http://etherx.jabber.org/streams">>},
		   {<<"id">>, StateData#state.streamid},
		   {<<"from">>, Server}]},
    (StateData#state.sockmod):send_xml(StateData#state.socket,
				       Header);
send_header(StateData, Server, Version, Lang) ->
    VersionStr = case Version of
		   <<"">> -> <<"">>;
		   _ -> [<<" version='">>, Version, <<"'">>]
		 end,
    LangStr = case Lang of
		<<"">> -> <<"">>;
		_ -> [<<" xml:lang='">>, Lang, <<"'">>]
	      end,
    Header = io_lib:format(?STREAM_HEADER,
			   [StateData#state.streamid, Server, VersionStr,
			    LangStr]),
    send_text(StateData, iolist_to_binary(Header)).

send_trailer(StateData)
    when StateData#state.mgmt_state == pending ->
    ?DEBUG("Cannot send stream trailer while waiting for resumption", []);
send_trailer(StateData)
    when StateData#state.xml_socket ->
    (StateData#state.sockmod):send_xml(StateData#state.socket,
				       {xmlstreamend, <<"stream:stream">>});
send_trailer(StateData) ->
    send_text(StateData, ?STREAM_TRAILER).

new_id() -> randoms:get_string().

is_auth_packet(El) ->
    case jlib:iq_query_info(El) of
	#iq{id = ID, type = Type, xmlns = ?NS_AUTH, sub_el = SubEl} ->
	    #xmlel{children = Els} = SubEl,
	    {auth, ID, Type,
	     get_auth_tags(Els, <<"">>, <<"">>, <<"">>, <<"">>)};
	_ -> false
    end.

is_stanza(#xmlel{name = Name, attrs = Attrs}) when Name == <<"message">>;
						   Name == <<"presence">>;
						   Name == <<"iq">> ->
    case xml:get_attr(<<"xmlns">>, Attrs) of
      {value, NS} when NS /= <<"jabber:client">>,
		       NS /= <<"jabber:server">> ->
	  false;
      _ ->
	  true
    end;
is_stanza(_El) ->
    false.

get_auth_tags([#xmlel{name = Name, children = Els} | L],
	      U, P, D, R) ->
    CData = xml:get_cdata(Els),
    case Name of
      <<"username">> -> get_auth_tags(L, CData, P, D, R);
      <<"password">> -> get_auth_tags(L, U, CData, D, R);
      <<"digest">> -> get_auth_tags(L, U, P, CData, R);
      <<"resource">> -> get_auth_tags(L, U, P, D, CData);
      _ -> get_auth_tags(L, U, P, D, R)
    end;
get_auth_tags([_ | L], U, P, D, R) ->
    get_auth_tags(L, U, P, D, R);
get_auth_tags([], U, P, D, R) ->
    {U, P, D, R}.

%% Copied from ejabberd_socket.erl
-record(socket_state, {sockmod, socket, receiver}).

get_conn_type(StateData) ->
    case (StateData#state.sockmod):get_sockmod(StateData#state.socket) of
    gen_tcp -> c2s;
    p1_tls -> c2s_tls;
    ezlib ->
	case ezlib:get_sockmod((StateData#state.socket)#socket_state.socket) of
	    gen_tcp -> c2s_compressed;
	    p1_tls -> c2s_compressed_tls
	end;
    ejabberd_http_poll -> http_poll;
    ejabberd_http_bind -> http_bind;
    _ -> unknown
    end.

process_presence_probe(From, To, StateData) ->
    LFrom = jlib:jid_tolower(From),
    LBFrom = setelement(3, LFrom, <<"">>),
    case StateData#state.pres_last of
	undefined ->
	    ok;
	_ ->
	    Cond1 = (not StateData#state.pres_invis)
		andalso (?SETS:is_element(LFrom, StateData#state.pres_f)
			 orelse
			 ((LFrom /= LBFrom) andalso
			  ?SETS:is_element(LBFrom, StateData#state.pres_f)))
		andalso (not
			 (?SETS:is_element(LFrom, StateData#state.pres_i)
			  orelse
			  ((LFrom /= LBFrom) andalso
			   ?SETS:is_element(LBFrom, StateData#state.pres_i)))),
	    Cond2 = StateData#state.pres_invis
		andalso ?SETS:is_element(LFrom, StateData#state.pres_f)
		andalso ?SETS:is_element(LFrom, StateData#state.pres_a),
	    if
		Cond1 ->
		    Timestamp = StateData#state.pres_timestamp,
		    Packet = xml:append_subtags(
			       StateData#state.pres_last,
			       %% To is the one sending the presence (the target of the probe)
			       [jlib:timestamp_to_xml(Timestamp, utc, To, <<"">>),
				%% TODO: Delete the next line once XEP-0091 is Obsolete
				jlib:timestamp_to_xml(Timestamp)]),
		    case privacy_check_packet(StateData, To, From, Packet, out) of
			deny ->
			    ok;
			allow ->
			    Pid=element(2, StateData#state.sid),
			    ejabberd_hooks:run(presence_probe_hook, StateData#state.server, [From, To, Pid]),
			    %% Don't route a presence probe to oneself
			    case From == To of
				false ->
				    ejabberd_router:route(To, From, Packet);
			    	true ->
				    ok
			    end
		    end;
		Cond2 ->
		    ejabberd_router:route(To, From,
			#xmlel{name = <<"presence">>,
			       attrs = [],
			       children = []});
		true ->
		    ok
	    end
    end.

%% User updates his presence (non-directed presence packet)
presence_update(From, Packet, StateData) ->
    #xmlel{attrs = Attrs} = Packet,
    case xml:get_attr_s(<<"type">>, Attrs) of
      <<"unavailable">> ->
	  Status = case xml:get_subtag(Packet, <<"status">>) of
		     false -> <<"">>;
		     StatusTag -> xml:get_tag_cdata(StatusTag)
		   end,
	  Info = [{ip, StateData#state.ip},
		  {conn, StateData#state.conn},
		  {auth_module, StateData#state.auth_module}],
	  ejabberd_sm:unset_presence(StateData#state.sid,
				     StateData#state.user,
				     StateData#state.server,
				     StateData#state.resource, Status, Info),
	  presence_broadcast(StateData, From,
			     StateData#state.pres_a, Packet),
	  StateData#state{pres_last = undefined,
			  pres_timestamp = undefined, pres_a = (?SETS):new()};
      <<"error">> -> StateData;
      <<"probe">> -> StateData;
      <<"subscribe">> -> StateData;
      <<"subscribed">> -> StateData;
      <<"unsubscribe">> -> StateData;
      <<"unsubscribed">> -> StateData;
      _ ->
	  OldPriority = case StateData#state.pres_last of
			  undefined -> 0;
			  OldPresence -> get_priority_from_presence(OldPresence)
			end,
	  NewPriority = get_priority_from_presence(Packet),
	  Timestamp = calendar:now_to_universal_time(os:timestamp()),
	  update_priority(NewPriority, Packet, StateData),
	  FromUnavail = (StateData#state.pres_last == undefined),
	  ?DEBUG("from unavail = ~p~n", [FromUnavail]),
	  NewStateData = StateData#state{pres_last = Packet,
					 pres_timestamp = Timestamp},
	  catch record_user_show_tag(Packet,NewStateData),
	  NewState = if FromUnavail ->
			    ejabberd_hooks:run(user_available_hook,
					       NewStateData#state.server,
					       [NewStateData#state.jid]),
			    ResentStateData = if NewPriority >= 0 ->
						     resend_offline_messages(NewStateData),
						     resend_subscription_requests(NewStateData);
						 true -> NewStateData
					      end,
			    presence_broadcast_first(From, ResentStateData,
						     Packet);
			true ->
			    presence_broadcast_to_trusted(NewStateData, From,
							  NewStateData#state.pres_f,
							  NewStateData#state.pres_a,
							  Packet),
			    if OldPriority < 0, NewPriority >= 0 ->
				   resend_offline_messages(NewStateData);
			       true -> ok
			    end,
			    NewStateData
		     end,
	  NewState
    end.

%% User sends a directed presence packet
presence_track(From, To, Packet, StateData) ->
    #xmlel{attrs = Attrs} = Packet,
    LTo = jlib:jid_tolower(To),
    User = StateData#state.user,
    Server = StateData#state.server,
    case xml:get_attr_s(<<"type">>, Attrs) of
      <<"unavailable">> ->
	  check_privacy_route(From, StateData, From, To, Packet),
	  A = remove_element(LTo, StateData#state.pres_a),
	  StateData#state{pres_a = A};
      <<"subscribe">> ->
	  try_roster_subscribe(subscribe, User, Server, From, To, Packet, StateData),
	  StateData;
      <<"subscribed">> ->
	  ejabberd_hooks:run(roster_out_subscription, Server,
			     [User, Server, To, subscribed]),
	  check_privacy_route(From, StateData,
			      jlib:jid_remove_resource(From), To, Packet),
	  StateData;
      <<"unsubscribe">> ->
	  try_roster_subscribe(unsubscribe, User, Server, From, To, Packet, StateData),
	  StateData;
      <<"unsubscribed">> ->
	  ejabberd_hooks:run(roster_out_subscription, Server,
			     [User, Server, To, unsubscribed]),
	  check_privacy_route(From, StateData,
			      jlib:jid_remove_resource(From), To, Packet),
	  StateData;
      <<"error">> ->
	  check_privacy_route(From, StateData, From, To, Packet),
	  StateData;
      <<"probe">> ->
	  check_privacy_route(From, StateData, From, To, Packet),
	  StateData;
      <<"verify_friend">> ->
	  NewPacket = make_new_presence_packet(StateData#state.server,From,Packet,Attrs),
	  ?DEBUG("NewPacket ~p ,~p ~n",[NewPacket,Packet]),
	  check_privacy_route(From, StateData, From, To, NewPacket),
	  StateData;
      <<"manual_authentication_confirm">> ->
	  NewPacket = make_new_presence_packet(StateData#state.server,From,Packet,Attrs),
	  check_privacy_route(From, StateData, From, To, NewPacket),
	  StateData;
      _ ->
	  check_privacy_route(From, StateData, From, To, Packet),
	  New_pres_a = 
	  	case  jlib:jid_tolower(To) of
	  	{<<"">>,_,<<"">>} ->
			Nick = 	ejabberd_public:get_user_nick(From#jid.user),
			Muc_pres_a = 
				case catch ejabberd_odbc:sql_query(From#jid.lserver,
                	[<<"select muc_name,domain from user_register_mucs where username = '">>,From#jid.user,
                        <<"' and registed_flag = 1;">>]) of 
				{selected,[<<"muc_name">>,<<"domain">>], SRes}   when is_list(SRes) ->
			   		lists:flatmap(fun([M,D]) ->
					 	case jlib:jid_tolower({M,D,Nick}) of  
						error ->
							[];
						Muc_To ->
							case catch (?SETS):is_element(Muc_To, StateData#state.pres_a) of
							true ->
								[];
							_ ->
								[Muc_To]
							end
						end end,SRes);
				_ ->
					[]
				end,
			Set_Muc_pres_a = (?SETS):from_list(Muc_pres_a),
			(?SETS):union(Set_Muc_pres_a,StateData#state.pres_a);
		_ ->		
	  		(?SETS):add_element(LTo, StateData#state.pres_a)
		end,
	 StateData#state{pres_a = New_pres_a}
    end.

check_privacy_route(From, StateData, FromRoute, To,
		    Packet) ->
    case privacy_check_packet(StateData, From, To, Packet,
			      out)
	of
      deny ->
	  	Lang = StateData#state.lang,
	  	ErrText = <<"Your active privacy list has denied "
	  	        "the routing of this stanza.">>,
	  	Err = jlib:make_error_reply(Packet,
	  	  		      ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)),
	  	ejabberd_router:route(To, From, Err),
	  	deny;
      allow -> 
			ejabberd_router:route(From, To, Packet)
    end.

%% Check if privacy rules allow this delivery
privacy_check_packet(StateData, From, To, Packet,
		     Dir) ->
    ejabberd_hooks:run_fold(privacy_check_packet,
			    StateData#state.server, allow,
			    [StateData#state.user, StateData#state.server,
			     StateData#state.privacy_list, {From, To, Packet},
			     Dir]).

is_privacy_allow(StateData, From, To, Packet, Dir) ->
    allow ==
      privacy_check_packet(StateData, From, To, Packet, Dir).

%%% Check ACL before allowing to send a subscription stanza
try_roster_subscribe(Type, User, Server, From, To, Packet, StateData) ->
    JID1 = jlib:make_jid(User, Server, <<"">>),
    Access = gen_mod:get_module_opt(Server, mod_roster, access, fun(A) when is_atom(A) -> A end, all),
    case acl:match_rule(Server, Access, JID1) of
	deny ->
	    %% Silently drop this (un)subscription request
	    ok;
	allow ->
	    ejabberd_hooks:run(roster_out_subscription,
			       Server,
			       [User, Server, To, Type]),
	    check_privacy_route(From, StateData, jlib:jid_remove_resource(From),
				To, Packet)
    end.

%% Send presence when disconnecting
presence_broadcast(StateData, From, JIDSet, Packet) ->
    JIDs = ?SETS:to_list(JIDSet),
    JIDs2 = format_and_check_privacy(From, StateData, Packet, JIDs, out),
    send_multiple(StateData, From, JIDs2, Packet).

%% Send presence when updating presence
presence_broadcast_to_trusted(StateData, From, Trusted, JIDSet, Packet) ->
    JIDs = ?SETS:to_list(JIDSet),
    JIDs_trusted = [JID || JID <- JIDs, ?SETS:is_element(JID, Trusted)],
    JIDs2 = format_and_check_privacy(From, StateData, Packet, JIDs_trusted, out),
    send_multiple(StateData, From, JIDs2, Packet).

%% Send presence when connecting
presence_broadcast_first(From, StateData, Packet) ->
    JIDsProbe =
	?SETS:fold(
	   fun(JID, L) -> [JID | L] end,
	   [],
	   StateData#state.pres_t),
    PacketProbe = #xmlel{name = <<"presence">>, attrs = [{<<"type">>,<<"probe">>}], children = []},
    JIDs2Probe = format_and_check_privacy(From, StateData, Packet, JIDsProbe, out),
    Server = StateData#state.server,
    send_multiple(StateData, From, JIDs2Probe, PacketProbe),
    {As, JIDs} =
	?SETS:fold(
	   fun(JID, {A, JID_list}) ->
		   {?SETS:add_element(JID, A), JID_list++[JID]}
	   end,
	   {StateData#state.pres_a, []},
	   StateData#state.pres_f),
    JIDs2 = format_and_check_privacy(From, StateData, Packet, JIDs, out),
    Server = StateData#state.server,
    send_multiple(StateData, From, JIDs2, Packet),
    StateData#state{pres_a = As}.

format_and_check_privacy(From, StateData, Packet, JIDs, Dir) ->
    FJIDs = [jlib:make_jid(JID) || JID <- JIDs],
    lists:filter(
      fun(FJID) ->
	      case ejabberd_hooks:run_fold(
		     privacy_check_packet, StateData#state.server,
		     allow,
		     [StateData#state.user,
		      StateData#state.server,
		      StateData#state.privacy_list,
		      {From, FJID, Packet},
		      Dir]) of
		  deny -> false;
		  allow -> true
	      end
      end,
      FJIDs).

send_multiple(StateData, From, JIDs, Packet) ->
    lists:foreach(
      fun(JID) ->
              case privacy_check_packet(StateData, From, JID, Packet, out) of
                  deny ->
                      ok;
                  allow ->
                      ejabberd_router:route(From, JID, Packet)
              end
      end, JIDs).

remove_element(E, Set) ->
    case (?SETS):is_element(E, Set) of
      true -> (?SETS):del_element(E, Set);
      _ -> Set
    end.

roster_change(IJID, ISubscription, StateData) ->
    LIJID = jlib:jid_tolower(IJID),
    IsFrom = (ISubscription == both) or (ISubscription == from),
    IsTo = (ISubscription == both) or (ISubscription == to),
    OldIsFrom = (?SETS):is_element(LIJID, StateData#state.pres_f),
    FSet = if
	       IsFrom -> (?SETS):add_element(LIJID, StateData#state.pres_f);
	       not IsFrom -> remove_element(LIJID, StateData#state.pres_f)
	   end,
    TSet = if
	       IsTo -> (?SETS):add_element(LIJID, StateData#state.pres_t);
	       not IsTo -> remove_element(LIJID, StateData#state.pres_t)
	   end,
    case StateData#state.pres_last of
      undefined ->
	  StateData#state{pres_f = FSet, pres_t = TSet};
      P ->
	  ?DEBUG("roster changed for ~p~n",
		 [StateData#state.user]),
	  From = StateData#state.jid,
	  To = jlib:make_jid(IJID),
	  Cond1 = IsFrom andalso not OldIsFrom,
	  Cond2 = not IsFrom andalso OldIsFrom andalso
		    ((?SETS):is_element(LIJID, StateData#state.pres_a)),
	  if Cond1 ->
		 ?DEBUG("C1: ~p~n", [LIJID]),
		 case privacy_check_packet(StateData, From, To, P, out)
		     of
		   deny -> ok;
		   allow -> 
			ejabberd_router:route(From, To, P)
		 end,
		 A = (?SETS):add_element(LIJID, StateData#state.pres_a),
		 StateData#state{pres_a = A, pres_f = FSet,
				 pres_t = TSet};
	     Cond2 ->
		 ?DEBUG("C2: ~p~n", [LIJID]),
		 PU = #xmlel{name = <<"presence">>,
			     attrs = [{<<"type">>, <<"unavailable">>}],
			     children = []},
		 case privacy_check_packet(StateData, From, To, PU, out)
		     of
		   deny -> ok;
		   allow -> 
			ejabberd_router:route(From, To, PU)
		 end,
		 A = remove_element(LIJID, StateData#state.pres_a),
		 StateData#state{pres_a = A, pres_f = FSet,
				 pres_t = TSet};
	     true -> StateData#state{pres_f = FSet, pres_t = TSet}
	  end
    end.

update_priority(Priority, Packet, StateData) ->
    Info = [{ip, StateData#state.ip}, {conn, StateData#state.conn},
	    {auth_module, StateData#state.auth_module}],
    ejabberd_sm:set_presence(StateData#state.sid,
			     StateData#state.user, StateData#state.server,
			     StateData#state.resource, Priority, Packet, Info).

get_priority_from_presence(PresencePacket) ->
    case xml:get_subtag(PresencePacket, <<"priority">>) of
      false -> 0;
      SubEl ->
	  case catch
		 jlib:binary_to_integer(xml:get_tag_cdata(SubEl))
	      of
	    P when is_integer(P) -> P;
	    _ -> 0
	  end
    end.

process_privacy_iq(From, To,
		   #iq{type = Type, sub_el = SubEl} = IQ, StateData) ->
    {Res, NewStateData} = case Type of
			    get ->
				R = ejabberd_hooks:run_fold(privacy_iq_get,
							    StateData#state.server,
							    {error,
							     ?ERR_FEATURE_NOT_IMPLEMENTED},
							    [From, To, IQ,
							     StateData#state.privacy_list]),
				{R, StateData};
			    set ->
				case ejabberd_hooks:run_fold(privacy_iq_set,
							     StateData#state.server,
							     {error,
							      ?ERR_FEATURE_NOT_IMPLEMENTED},
							     [From, To, IQ])
				    of
				  {result, R, NewPrivList} ->
				      {{result, R},
				       StateData#state{privacy_list =
							   NewPrivList}};
				  R -> {R, StateData}
				end
			  end,
    IQRes = case Res of
	      {result, Result} ->
		  IQ#iq{type = result, sub_el = Result};
	      {error, Error} ->
		  IQ#iq{type = error, sub_el = [SubEl, Error]}
	    end,
    ejabberd_router:route(To, From, jlib:iq_to_xml(IQRes)),
    NewStateData.

resend_offline_messages(StateData) ->
	catch odbc_queries:del_muc_spool(StateData#state.server,StateData#state.user),
    case ejabberd_hooks:run_fold(resend_offline_messages_hook,
				 StateData#state.server, [],
				 [StateData#state.user, StateData#state.server])
    of
      Rs -> %%when is_list(Rs) ->
	  lists:foreach(fun ({route, From, To,
			      #xmlel{} = Packet}) ->
				Pass = case privacy_check_packet(StateData,
								 From, To,
								 Packet, in)
					   of
					 allow -> true;
					 deny -> false
				       end,
				if Pass ->
				       ejabberd_router:route(From, To, Packet);
				   true -> ok
				end
			end,
			Rs)
    end.

resend_subscription_requests(#state{user = User,
				    server = Server} = StateData) ->
    PendingSubscriptions =
	ejabberd_hooks:run_fold(resend_subscription_requests_hook,
				Server, [], [User, Server]),
    lists:foldl(fun (XMLPacket, AccStateData) ->
			send_packet(AccStateData, XMLPacket)
		end,
		StateData,
		PendingSubscriptions).

get_showtag(undefined) -> <<"unavailable">>;
get_showtag(Presence) ->
    case xml:get_path_s(Presence, [{elem, <<"show">>}, cdata]) of
	<<"">> -> <<"available">>;
	ShowTag -> ShowTag
    end.

get_statustag(undefined) -> <<"">>;
get_statustag(Presence) ->
    xml:get_path_s(Presence, [{elem, <<"status">>}, cdata]).

process_unauthenticated_stanza(StateData, El) ->
    NewEl = case xml:get_tag_attr_s(<<"xml:lang">>, El) of
	      <<"">> ->
		  case StateData#state.lang of
		    <<"">> -> El;
		    Lang -> xml:replace_tag_attr(<<"xml:lang">>, Lang, El)
		  end;
	      _ -> El
	    end,
    case jlib:iq_query_info(NewEl) of
      #iq{} = IQ ->
	  Res = ejabberd_hooks:run_fold(c2s_unauthenticated_iq,
					StateData#state.server, empty,
					[StateData#state.server, IQ,
					 StateData#state.ip]),
	  case Res of
	    empty ->
		ResIQ = IQ#iq{type = error,
			      sub_el = [?ERR_SERVICE_UNAVAILABLE]},
		Res1 = jlib:replace_from_to(jlib:make_jid(<<"">>,
							  StateData#state.server,
							  <<"">>),
					    jlib:make_jid(<<"">>, <<"">>,
							  <<"">>),
					    jlib:iq_to_xml(ResIQ)),
		send_element(StateData,
			     jlib:remove_attr(<<"to">>, Res1));
	    _ -> send_element(StateData, Res)
	  end;
      _ ->
	  % Drop any stanza, which isn't IQ stanza
	  ok
    end.

peerip(SockMod, Socket) ->
    IP = case SockMod of
	   gen_tcp -> inet:peername(Socket);
	   _ -> SockMod:peername(Socket)
	 end,
    case IP of
      {ok, IPOK} -> IPOK;
      _ -> undefined
    end.

%% fsm_next_state_pack: Pack the StateData structure to improve
%% sharing.
fsm_next_state_pack(StateName, StateData) ->
    fsm_next_state_gc(StateName, pack(StateData)).

%% fsm_next_state_gc: Garbage collect the process heap to make use of
%% the newly packed StateData structure.
fsm_next_state_gc(StateName, PackedStateData) ->
    erlang:garbage_collect(),
    fsm_next_state(StateName, PackedStateData).

%% fsm_next_state: Generate the next_state FSM tuple with different
%% timeout, depending on the future state
fsm_next_state(session_established, StateData) ->
    {next_state, session_established, StateData,
     ?C2S_HIBERNATE_TIMEOUT};
fsm_next_state(wait_for_resume, StateData)
    when StateData#state.mgmt_state /= pending ->
    ?INFO_MSG("Waiting for resumption of stream for ~s",
	      [jlib:jid_to_string(StateData#state.jid)]),
    {next_state, wait_for_resume,
     StateData#state{mgmt_state = pending, mgmt_pending_since = os:timestamp()},
     StateData#state.mgmt_timeout};
fsm_next_state(wait_for_resume, StateData) ->
    Diff = timer:now_diff(os:timestamp(), StateData#state.mgmt_pending_since),
    Timeout = max(StateData#state.mgmt_timeout - Diff div 1000, 1),
    {next_state, wait_for_resume, StateData, Timeout};
fsm_next_state(StateName, StateData) ->
    {next_state, StateName, StateData, ?C2S_OPEN_TIMEOUT}.

%% fsm_reply: Generate the reply FSM tuple with different timeout,
%% depending on the future state
fsm_reply(Reply, session_established, StateData) ->
    {reply, Reply, session_established, StateData,
     ?C2S_HIBERNATE_TIMEOUT};
fsm_reply(Reply, wait_for_resume, #state{mgmt_pending_since = undefined} =
	  StateData) ->
    {reply, Reply, wait_for_resume,
     StateData#state{mgmt_pending_since = os:timestamp()},
     StateData#state.mgmt_timeout};
fsm_reply(Reply, wait_for_resume, StateData) ->
    Diff = timer:now_diff(os:timestamp(), StateData#state.mgmt_pending_since),
    Timeout = max(StateData#state.mgmt_timeout - Diff div 1000, 1),
    {reply, Reply, wait_for_resume, StateData, Timeout};
fsm_reply(Reply, StateName, StateData) ->
    {reply, Reply, StateName, StateData, ?C2S_OPEN_TIMEOUT}.

%% Used by c2s blacklist plugins
is_ip_blacklisted(undefined) -> false;
is_ip_blacklisted({IP, _Port}) ->
    ejabberd_hooks:run_fold(check_bl_c2s, false, [IP]).

%% Check from attributes
%% returns invalid-from|NewElement
check_from(El, FromJID) ->
    case xml:get_tag_attr(<<"from">>, El) of
	false ->
	    El;
	{value, SJID} ->
	    JID = jlib:string_to_jid(SJID),
	    case JID of
		error ->
		    'invalid-from';
		#jid{} ->
		    if
			(JID#jid.luser == FromJID#jid.luser) and
			(JID#jid.lserver == FromJID#jid.lserver) and
			(JID#jid.lresource == FromJID#jid.lresource) ->
			    El;
			(JID#jid.luser == FromJID#jid.luser) and
			(JID#jid.lserver == FromJID#jid.lserver) and
			(JID#jid.lresource == <<"">>) ->
			    El;
			true ->
			    'invalid-from'
		    end
	    end
    end.

fsm_limit_opts(Opts) ->
    case lists:keysearch(max_fsm_queue, 1, Opts) of
      {value, {_, N}} when is_integer(N) -> [{max_queue, N}];
      _ ->
	  case ejabberd_config:get_option(
                 max_fsm_queue,
                 fun(I) when is_integer(I), I > 0 -> I end) of
            undefined -> [];
	    N -> [{max_queue, N}]
	  end
    end.

bounce_messages() ->
    receive
      {route, From, To, El} ->
	  ejabberd_router:route(From, To, El), bounce_messages()
      after 0 -> ok
    end.

%%%----------------------------------------------------------------------
%%% XEP-0191
%%%----------------------------------------------------------------------

route_blocking(What, StateData) ->
    SubEl = case What of
	      {block, JIDs} ->
		  #xmlel{name = <<"block">>,
			 attrs = [{<<"xmlns">>, ?NS_BLOCKING}],
			 children =
			     lists:map(fun (JID) ->
					       #xmlel{name = <<"item">>,
						      attrs =
							  [{<<"jid">>,
							    jlib:jid_to_string(JID)}],
						      children = []}
				       end,
				       JIDs)};
	      {unblock, JIDs} ->
		  #xmlel{name = <<"unblock">>,
			 attrs = [{<<"xmlns">>, ?NS_BLOCKING}],
			 children =
			     lists:map(fun (JID) ->
					       #xmlel{name = <<"item">>,
						      attrs =
							  [{<<"jid">>,
							    jlib:jid_to_string(JID)}],
						      children = []}
				       end,
				       JIDs)};
	      unblock_all ->
		  #xmlel{name = <<"unblock">>,
			 attrs = [{<<"xmlns">>, ?NS_BLOCKING}], children = []}
	    end,
    PrivPushIQ = #iq{type = set, id = <<"push">>, sub_el = [SubEl]},
    PrivPushEl =
	jlib:replace_from_to(jlib:jid_remove_resource(StateData#state.jid),
			     StateData#state.jid, jlib:iq_to_xml(PrivPushIQ)),
    %% No need to replace active privacy list here,
    %% blocking pushes are always accompanied by
    %% Privacy List pushes
    send_stanza(StateData, PrivPushEl).

%%%----------------------------------------------------------------------
%%% XEP-0198
%%%----------------------------------------------------------------------

stream_mgmt_enabled(#state{mgmt_state = disabled}) ->
    false;
stream_mgmt_enabled(_StateData) ->
    true.

dispatch_stream_mgmt(El, StateData)
    when StateData#state.mgmt_state == active;
	 StateData#state.mgmt_state == pending ->
    perform_stream_mgmt(El, StateData);
dispatch_stream_mgmt(El, StateData) ->
    negotiate_stream_mgmt(El, StateData).

negotiate_stream_mgmt(_El, #state{resource = <<"">>} = StateData) ->
    %% XEP-0198 says: "For client-to-server connections, the client MUST NOT
    %% attempt to enable stream management until after it has completed Resource
    %% Binding unless it is resuming a previous session".  However, it also
    %% says: "Stream management errors SHOULD be considered recoverable", so we
    %% won't bail out.
    send_element(StateData, ?MGMT_UNEXPECTED_REQUEST(?NS_STREAM_MGMT_3)),
    StateData;
negotiate_stream_mgmt(#xmlel{name = Name, attrs = Attrs}, StateData) ->
    case xml:get_attr_s(<<"xmlns">>, Attrs) of
      Xmlns when ?IS_SUPPORTED_MGMT_XMLNS(Xmlns) ->
	  case stream_mgmt_enabled(StateData) of
	    true ->
		case Name of
		  <<"enable">> ->
		      handle_enable(StateData#state{mgmt_xmlns = Xmlns}, Attrs);
		  _ ->
		      Res = if Name == <<"a">>;
			       Name == <<"r">>;
			       Name == <<"resume">> ->
				   ?MGMT_UNEXPECTED_REQUEST(Xmlns);
			       true ->
				   ?MGMT_BAD_REQUEST(Xmlns)
			    end,
		      send_element(StateData, Res),
		      StateData
		end;
	    false ->
	      send_element(StateData, ?MGMT_SERVICE_UNAVAILABLE(Xmlns)),
	      StateData
	  end;
      _ ->
	  send_element(StateData, ?MGMT_UNSUPPORTED_VERSION(?NS_STREAM_MGMT_3)),
	  StateData
    end.

perform_stream_mgmt(#xmlel{name = Name, attrs = Attrs}, StateData) ->
    case xml:get_attr_s(<<"xmlns">>, Attrs) of
      Xmlns when Xmlns == StateData#state.mgmt_xmlns ->
	  case Name of
	    <<"r">> ->
		handle_r(StateData);
	    <<"a">> ->
		handle_a(StateData, Attrs);
	    _ ->
		Res = if Name == <<"enable">>;
			 Name == <<"resume">> ->
			     ?MGMT_UNEXPECTED_REQUEST(Xmlns);
			 true ->
			     ?MGMT_BAD_REQUEST(Xmlns)
		      end,
		send_element(StateData, Res),
		StateData
	  end;
      _ ->
	  send_element(StateData,
		       ?MGMT_UNSUPPORTED_VERSION(StateData#state.mgmt_xmlns)),
	  StateData
    end.

handle_enable(#state{mgmt_timeout = ConfigTimeout} = StateData, Attrs) ->
    Timeout = case xml:get_attr_s(<<"resume">>, Attrs) of
		ResumeAttr when ResumeAttr == <<"true">>;
				ResumeAttr == <<"1">> ->
		    MaxAttr = xml:get_attr_s(<<"max">>, Attrs),
		    case catch jlib:binary_to_integer(MaxAttr) of
		      Max when is_integer(Max), Max > 0, Max =< ConfigTimeout ->
			  Max;
		      _ ->
			  ConfigTimeout
		    end;
		_ ->
		    0
	      end,
    ResAttrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns}] ++
	if Timeout > 0 ->
	       ?INFO_MSG("Stream management with resumption enabled for ~s",
			 [jlib:jid_to_string(StateData#state.jid)]),
	       [{<<"id">>, make_resume_id(StateData)},
		{<<"resume">>, <<"true">>},
		{<<"max">>, jlib:integer_to_binary(Timeout)}];
	   true ->
	       ?INFO_MSG("Stream management without resumption enabled for ~s",
			 [jlib:jid_to_string(StateData#state.jid)]),
	       []
	end,
    Res = #xmlel{name = <<"enabled">>,
		 attrs = ResAttrs,
		 children = []},
    send_element(StateData, Res),
    StateData#state{mgmt_state = active,
		    mgmt_queue = queue:new(),
		    mgmt_timeout = Timeout * 1000}.

handle_r(StateData) ->
    H = jlib:integer_to_binary(StateData#state.mgmt_stanzas_in),
    Res = #xmlel{name = <<"a">>,
		 attrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns},
			  {<<"h">>, H}],
		 children = []},
    send_element(StateData, Res),
    StateData.

handle_a(StateData, Attrs) ->
    case catch jlib:binary_to_integer(xml:get_attr_s(<<"h">>, Attrs)) of
      H when is_integer(H), H >= 0 ->
	  check_h_attribute(StateData, H);
      _ ->
	  ?DEBUG("Ignoring invalid ACK element from ~s",
		 [jlib:jid_to_string(StateData#state.jid)]),
	  StateData
    end.

handle_resume(StateData, Attrs) ->
    R = case xml:get_attr_s(<<"xmlns">>, Attrs) of
	  Xmlns when ?IS_SUPPORTED_MGMT_XMLNS(Xmlns) ->
	      case stream_mgmt_enabled(StateData) of
		true ->
		    case {xml:get_attr(<<"previd">>, Attrs),
			  catch jlib:binary_to_integer(xml:get_attr_s(<<"h">>, Attrs))}
			of
		      {{value, PrevID}, H} when is_integer(H), H >= 0 ->
			  case inherit_session_state(StateData, PrevID) of
			    {ok, InheritedState} ->
				{ok, InheritedState, H};
			    {error, Err} ->
				{error, ?MGMT_ITEM_NOT_FOUND(Xmlns), Err}
			  end;
		      _ ->
			  {error, ?MGMT_BAD_REQUEST(Xmlns),
			   <<"Invalid request">>}
		    end;
		false ->
		    {error, ?MGMT_SERVICE_UNAVAILABLE(Xmlns),
		     <<"XEP-0198 disabled">>}
	      end;
	  _ ->
	      {error, ?MGMT_UNSUPPORTED_VERSION(?NS_STREAM_MGMT_3),
	       <<"Invalid XMLNS">>}
	end,
    case R of
      {ok, ResumedState, NumHandled} ->
	  NewState = check_h_attribute(ResumedState, NumHandled),
	  AttrXmlns = NewState#state.mgmt_xmlns,
	  AttrId = make_resume_id(NewState),
	  AttrH = jlib:integer_to_binary(NewState#state.mgmt_stanzas_in),
	  send_element(NewState,
		       #xmlel{name = <<"resumed">>,
			      attrs = [{<<"xmlns">>, AttrXmlns},
				       {<<"h">>, AttrH},
				       {<<"previd">>, AttrId}],
			      children = []}),
	  SendFun = fun(_F, _T, El) -> send_element(NewState, El) end,
	  handle_unacked_stanzas(NewState, SendFun),
	  send_element(NewState,
		       #xmlel{name = <<"r">>,
			      attrs = [{<<"xmlns">>, AttrXmlns}],
			      children = []}),
	  ?INFO_MSG("Resumed session for ~s",
		    [jlib:jid_to_string(NewState#state.jid)]),
	  {ok, NewState};
      {error, El, Msg} ->
	  send_element(StateData, El),
	  ?INFO_MSG("Cannot resume session for ~s@~s: ~s",
		    [StateData#state.user, StateData#state.server, Msg]),
	  error
    end.

check_h_attribute(#state{mgmt_stanzas_out = NumStanzasOut} = StateData, H)
    when H > NumStanzasOut ->
    ?DEBUG("~s acknowledged ~B stanzas, but only ~B were sent",
	   [jlib:jid_to_string(StateData#state.jid), H, NumStanzasOut]),
    mgmt_queue_drop(StateData#state{mgmt_stanzas_out = H}, NumStanzasOut);
check_h_attribute(#state{mgmt_stanzas_out = NumStanzasOut} = StateData, H) ->
    ?DEBUG("~s acknowledged ~B of ~B stanzas",
	   [jlib:jid_to_string(StateData#state.jid), H, NumStanzasOut]),
    mgmt_queue_drop(StateData, H).

update_num_stanzas_in(#state{mgmt_state = active} = StateData, El) ->
    NewNum = case {is_stanza(El), StateData#state.mgmt_stanzas_in} of
	       {true, 4294967295} ->
		   0;
	       {true, Num} ->
		   Num + 1;
	       {false, Num} ->
		   Num
	     end,
    StateData#state{mgmt_stanzas_in = NewNum};
update_num_stanzas_in(StateData, _El) ->
    StateData.

send_stanza_and_ack_req(StateData, Stanza) ->
    AckReq = #xmlel{name = <<"r">>,
		    attrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns}],
		    children = []},
    StanzaS = xml:element_to_binary(Stanza),
    AckReqS = xml:element_to_binary(AckReq),
    send_text(StateData, [StanzaS, AckReqS]).

mgmt_queue_add(StateData, El) ->
    NewNum = case StateData#state.mgmt_stanzas_out of
	       4294967295 ->
		   0;
	       Num ->
		   Num + 1
	     end,
    NewQueue = queue:in({NewNum, El}, StateData#state.mgmt_queue),
    NewState = StateData#state{mgmt_queue = NewQueue,
			       mgmt_stanzas_out = NewNum},
    check_queue_length(NewState).

mgmt_queue_drop(StateData, NumHandled) ->
    NewQueue = jlib:queue_drop_while(fun({N, _Stanza}) -> N =< NumHandled end,
				     StateData#state.mgmt_queue),
    StateData#state{mgmt_queue = NewQueue}.

check_queue_length(#state{mgmt_max_queue = Limit} = StateData)
    when Limit == infinity;
	 Limit == unlimited ->
    StateData;
check_queue_length(#state{mgmt_queue = Queue,
			  mgmt_max_queue = Limit} = StateData) ->
    case queue:len(Queue) > Limit of
      true ->
	  ?WARNING_MSG("ACK queue too long, terminating session for ~s",
		       [jlib:jid_to_string(StateData#state.jid)]),
	  Lang = StateData#state.lang,
	  Err = ?SERRT_POLICY_VIOLATION(Lang, <<"Too many unacked stanzas">>),
	  self() ! {kick, queue_overflow, Err},
	  StateData#state{mgmt_resend = false}; % Don't resend the flood!
      false ->
	  StateData
    end.

handle_unacked_stanzas(StateData, F)
    when StateData#state.mgmt_state == active;
	 StateData#state.mgmt_state == pending ->
    Queue = StateData#state.mgmt_queue,
    case queue:len(Queue) of
      0 ->
	  ok;
      N ->
	  ?INFO_MSG("~B stanzas were not acknowledged by ~s",
		    [N, jlib:jid_to_string(StateData#state.jid)]),
	  lists:foreach(
	    fun({_, #xmlel{attrs = Attrs} = El}) ->
		    From_s = xml:get_attr_s(<<"from">>, Attrs),
		    From = jlib:string_to_jid(From_s),
		    To_s = xml:get_attr_s(<<"to">>, Attrs),
		    To = jlib:string_to_jid(To_s),
		    F(From, To, El)
	    end, queue:to_list(Queue))
    end;
handle_unacked_stanzas(_StateData, _F) ->
    ok.

handle_unacked_stanzas(StateData)
    when StateData#state.mgmt_state == active;
	 StateData#state.mgmt_state == pending ->
    ReRoute = case StateData#state.mgmt_resend of
		true ->
		    fun ejabberd_router:route/3;
		false ->
		    fun(From, To, El) ->
			    Err =
				jlib:make_error_reply(El,
						      ?ERR_SERVICE_UNAVAILABLE),
			    ejabberd_router:route(To, From, Err)
		    end
	      end,
    F = fun(From, To, El) ->
		%% We'll drop the stanza if it was <forwarded/> by some
		%% encapsulating protocol as per XEP-0297.  One such protocol is
		%% XEP-0280, which says: "When a receiving server attempts to
		%% deliver a forked message, and that message bounces with an
		%% error for any reason, the receiving server MUST NOT forward
		%% that error back to the original sender."  Resending such a
		%% stanza could easily lead to unexpected results as well.
		case is_encapsulated_forward(El) of
		  true ->
		      ?DEBUG("Dropping forwarded stanza from ~s",
			     [xml:get_attr_s(<<"from">>, El#xmlel.attrs)]);
		  false ->
		      ReRoute(From, To, El)
		end
	end,
    handle_unacked_stanzas(StateData, F);
handle_unacked_stanzas(_StateData) ->
    ok.

is_encapsulated_forward(#xmlel{name = <<"message">>} = El) ->
    SubTag = case {xml:get_subtag(El, <<"sent">>),
		   xml:get_subtag(El, <<"received">>),
		   xml:get_subtag(El, <<"result">>)} of
	       {false, false, false} ->
		   false;
	       {Tag, false, false} ->
		   Tag;
	       {false, Tag, false} ->
		   Tag;
	       {_, _, Tag} ->
		   Tag
	    end,
    if SubTag == false ->
	   false;
       true ->
	   case xml:get_subtag(SubTag, <<"forwarded">>) of
	     false ->
		 false;
	     _ ->
		 true
	   end
    end;
is_encapsulated_forward(_El) ->
    false.

inherit_session_state(#state{user = U, server = S} = StateData, ResumeID) ->
    case jlib:base64_to_term(ResumeID) of
      {term, {U, S, R, Time}} ->
	  case ejabberd_sm:get_session_pid(U, S, R) of
	    none ->
		{error, <<"Previous session PID not found">>};
	    OldPID ->
		OldSID = {Time, OldPID},
		case catch resume_session(OldSID) of
		  {ok, OldStateData} ->
		      NewSID = {Time, self()}, % Old time, new PID
		      Priority = case OldStateData#state.pres_last of
				   undefined ->
				       0;
				   Presence ->
				       get_priority_from_presence(Presence)
				 end,
		      Conn = get_conn_type(StateData),
		      Info = [{ip, StateData#state.ip}, {conn, Conn},
			      {auth_module, StateData#state.auth_module}],
		      ejabberd_sm:open_session(NewSID, U, S, R,
					       Priority, Info),
		      {ok, StateData#state{sid = NewSID,
					   jid = OldStateData#state.jid,
					   resource = OldStateData#state.resource,
					   pres_t = OldStateData#state.pres_t,
					   pres_f = OldStateData#state.pres_f,
					   pres_a = OldStateData#state.pres_a,
					   pres_i = OldStateData#state.pres_i,
					   pres_last = OldStateData#state.pres_last,
					   pres_pri = OldStateData#state.pres_pri,
					   pres_timestamp = OldStateData#state.pres_timestamp,
					   pres_invis = OldStateData#state.pres_invis,
					   privacy_list = OldStateData#state.privacy_list,
					   aux_fields = OldStateData#state.aux_fields,
					   mgmt_xmlns = OldStateData#state.mgmt_xmlns,
					   mgmt_queue = OldStateData#state.mgmt_queue,
					   mgmt_timeout = OldStateData#state.mgmt_timeout,
					   mgmt_stanzas_in = OldStateData#state.mgmt_stanzas_in,
					   mgmt_stanzas_out = OldStateData#state.mgmt_stanzas_out,
					   mgmt_state = active}};
		  {error, Msg} ->
		      {error, Msg};
		  _ ->
		      {error, <<"Cannot grab session state">>}
		end
	  end;
      error ->
	  {error, <<"Invalid 'previd' value">>}
    end.

resume_session({Time, PID}) ->
    (?GEN_FSM):sync_send_all_state_event(PID, {resume_session, Time}, 3000).

make_resume_id(StateData) ->
    {Time, _} = StateData#state.sid,
    ID = {StateData#state.user,
	  StateData#state.server,
	  StateData#state.resource,
	  Time},
    jlib:term_to_base64(ID).

%%%----------------------------------------------------------------------
%%% JID Set memory footprint reduction code
%%%----------------------------------------------------------------------

%% Try to reduce the heap footprint of the four presence sets
%% by ensuring that we re-use strings and Jids wherever possible.
pack(S = #state{pres_a = A, pres_f = F,
		pres_t = T}) ->
    {NewA, Pack2} = pack_jid_set(A, gb_trees:empty()),
    {NewF, Pack3} = pack_jid_set(F, Pack2),
    {NewT, _Pack4} = pack_jid_set(T, Pack3),
    S#state{pres_a = NewA, pres_f = NewF,
	    pres_t = NewT}.

pack_jid_set(Set, Pack) ->
    Jids = (?SETS):to_list(Set),
    {PackedJids, NewPack} = pack_jids(Jids, Pack, []),
    {(?SETS):from_list(PackedJids), NewPack}.

pack_jids([], Pack, Acc) -> {Acc, Pack};
pack_jids([{U, S, R} = Jid | Jids], Pack, Acc) ->
    case gb_trees:lookup(Jid, Pack) of
      {value, PackedJid} ->
	  pack_jids(Jids, Pack, [PackedJid | Acc]);
      none ->
	  {NewU, Pack1} = pack_string(U, Pack),
	  {NewS, Pack2} = pack_string(S, Pack1),
	  {NewR, Pack3} = pack_string(R, Pack2),
	  NewJid = {NewU, NewS, NewR},
	  NewPack = gb_trees:insert(NewJid, NewJid, Pack3),
	  pack_jids(Jids, NewPack, [NewJid | Acc])
    end.

pack_string(String, Pack) ->
    case gb_trees:lookup(String, Pack) of
      {value, PackedString} -> {PackedString, Pack};
      none -> {String, gb_trees:insert(String, String, Pack)}
    end.

transform_listen_option(Opt, Opts) ->
    [Opt|Opts].

record_user_show_tag(Packet,StateData) ->
	case catch get_presence_show_tag(Packet) of
	<<"normal">> ->
	   ejabberd_sm:record_show(StateData#state.user, 
			StateData#state.server,StateData#state.resource,<<"normal">>);
	<<"away">> ->
	   ejabberd_sm:record_show(StateData#state.user, 
			StateData#state.server,StateData#state.resource,<<"away">>);
	_ ->
	 		ok
	end.

get_presence_show_tag(Presence) ->
    case xml:get_path_s(Presence, [{elem, <<"show">>}, cdata]) of
	<<"away">> -> <<"away">>;
    <<"normal">> -> <<"normal">>;
	_ -> <<"unknown">>
    end.

judge_log_to_write(Text) ->
	case str:str(Text,<<"message">>) of
	0 ->
		true;
	_ ->
		case str:str(Text,<<"body">>) =/=0 andalso (str:str(Text,<<"chat">>) =/=0 orelse str:str(Text,<<"groupchat">>) =/=0) of
		true ->
			true;
		false ->
			false
		end
	end.


do_sent_repley(El,FromJID,StateData) ->
	case catch xml:get_subtag_cdata(El, <<"body">>) of
	<<>> -> 
		El;
	_ ->
		Type = xml:get_tag_attr_s(<<"type">>, El),
		case Type =:= <<"readmark">> orelse Type =:= <<"error">> orelse Type =:= <<"headline">> orelse 
				Type =:= <<"subscription">> of 
		true ->
			El;
		_ ->
			case catch xml:get_tag_attr_s(<<"id">>,xml:get_subtag(El,<<"body">>)) of
			<<"">> ->
               % Bid = list_to_binary("add_" ++ uuid:to_string(uuid:random())),
            Bid = list_to_binary("http_" ++ integer_to_list(random:uniform(65536)) ++ integer_to_list(mod_time:get_exact_timestamp())),
				ReEls = ejabberd_public:make_sent_packet(FromJID,Bid),
                ?INFO_MSG("ReEls ~p ~n",[ReEls]),
				send_element(StateData, ReEls),
				add_body_id(El,Bid);
			ID ->
				ReEls = ejabberd_public:make_sent_packet(FromJID,ID),
                ?INFO_MSG("ReEls ~p ~n",[ReEls]),
				send_element(StateData, ReEls),
				El
			end
		end
	end.

add_body_id(Packet,ID) ->
	ID_Packet = xml:replace_tag_attr(<<"id">>,ID,xml:get_subtag(Packet,<<"body">>)),
	case catch xml:remove_subtags_by_name(Packet,<<"body">>) of
	Body when is_record(Body,xmlel) ->
		xml:append_subtags(Body,[ID_Packet]);
	_ ->
		Packet
	end.

make_time_key_presence(Key) ->
	Time = integer_to_binary(mod_time:get_timestamp()),
	#xmlel{name = <<"presence">>,
	   	attrs = [{<<"xmlns">>,?CONFIG_XMPP_TIME_KEY},{<<"time_value">>,Time},{<<"key_value">>,Key}],
	   	children = []}.

send_time_key_presence(LServer,User,Resource,StateData) ->
	case  StateData#state.key_flag of 
	false ->
		Key =
			case redis_link:hash_get(LServer,1,User,Resource) of
			{ok,undefined} ->
				<<"">>;
			{ok,K} ->
				K;
			_ ->
				<<"">>
			end,
		case Key of
		<<"">> ->
%			send_trailer(StateData),
			StateData#state{key_flag = false};
		_ ->
		    Presence = make_time_key_presence(Key),
    		send_element(StateData,Presence),
			StateData#state{key_flag = true}
		end;
	_ ->
		StateData
	end.

send_user_refused_msg(StateData,From,To,_Packet) ->
	send_element(StateData, make_recv_reply_packet(From,To)).
		
make_recv_reply_packet(From,To) ->
   xml:to_xmlel(
		{xmlel ,<<"message">>, [{<<"type">>,<<"reply">>},{<<"to">>,jlib:jid_to_string(From)},{<<"receiver">>,jlib:jid_to_string(To)}],
		             [{xmlel,<<"body">>,[{<<"reply">>,<<"refused">>}],[]}]}).

make_new_presence_packet(LServer,From,Packet,_Attrs) ->
	Num = mod_user_relation:get_users_friend_num(LServer,From#jid.luser),
	xml:replace_tag_attr(<<"friend_num">>,http_utils:to_binary(Num,<<"0">>), Packet).

carbon_message(From,To,Packet) ->
    ?DEBUG("Carbon Packet ~p ~n",[Packet]),
	case ejabberd_sm:get_user_resources(From#jid.user,From#jid.server) of
	Resoureces  when is_list(Resoureces) ->
		case length(Resoureces) of
		0 ->
			ok;
		1 ->
			ok;
		_ ->
			#xmlel{name = Name, attrs = Attrs, children = Els} = Packet,
            Type = xml:get_attr_s(<<"type">>, Attrs),
            if Type == <<"normal">> ; Type == <<"chat">>; Type == <<"revoke">> ->
				case str:str(To#jid.server,<<"conference">>) =:= 0 andalso xml:get_attr_s(<<"auto_reply">>, Attrs) =/= <<"true">> of 
				true ->
					lists:foreach(fun(Resource) ->
						if Resource =:= From#jid.resource ->
							ok;
						true ->
							NewFrom = jlib:make_jid(From#jid.user,From#jid.server, Resource),
							case NewFrom of 
							error ->
							ok;
							_ ->
								Attrs2 = jlib:replace_from_to_attrs(jlib:jid_to_string(NewFrom),jlib:jid_to_string(To), Attrs),
								Attrs3 = lists:append([Attrs2,[{<<"carbon_message">>,<<"true">>}]]),
								NewPacket = #xmlel{name = Name, attrs = Attrs3,	children = Els },
								ejabberd_router:route(To, NewFrom, NewPacket)
							end
						 end
				  	end,Resoureces);
				_ ->
					ok
				end;
			true ->
				ok
			end
		end;
	_ ->
		ok
	end.

send_probuf_msg(StateData, Packet) ->
    To = ejabberd_public:get_xml_attrs_to(Packet,{StateData#state.user,StateData#state.server,StateData#state.resource}),
    From = ejabberd_public:get_xml_attrs_from(Packet,{StateData#state.user,StateData#state.server,StateData#state.resource}),
    catch do_send_probuf_msg(StateData,ejabberd_pb2xml_public:list_and_character_to_binary(From),
                                ejabberd_pb2xml_public:list_and_character_to_binary(To), Packet).
    
do_send_probuf_msg(StateData,From,To, Packet = #xmlel{name = <<"iq">>}) ->
    PB_IQ = encode_iq_pb_packet(StateData,From,To,Packet),
    case PB_IQ of
    <<"error">> ->
        ok;
    _ ->
        Text = ejabberd_encode_protobuf:uint32_pack(byte_size(PB_IQ),PB_IQ), 
        ?DEBUG("PB_IQ ~p ,Text ~p ~n",[PB_IQ,Text]),
        send_text(StateData, Text)
    end;
do_send_probuf_msg(StateData,From,To, Packet = #xmlel{name = <<"message">>}) ->
    PB_MSG = ejabberd_xml2pb_message:xml2pb_msg(From,To,Packet),
    case PB_MSG of 
    <<"">> ->
        ?INFO_MSG("PB_MSG ~p ~n",[Packet]);
    _ ->
        ok
    end,
    Text = 
        case catch ejabberd_encode_protobuf:uint32_pack(byte_size(PB_MSG),PB_MSG) of
        I  when is_binary(I) ->
            I;
        V ->
            ?DEBUG("Paket ~p ~n",[Packet]),
            V
        end,
    ?DEBUG("PB_MSG ~p ,Text ~p ~n",[PB_MSG,Text]),
    send_text(StateData, Text);
do_send_probuf_msg(StateData,From,To, Packet = #xmlel{name = <<"presence">>}) ->
    PB_PRESENCE = 
        case catch xml:get_attr_s(<<"xmlns">>,Packet#xmlel.attrs) of
        <<"http://jabber.org/protocol/muc#invite">> ->
                ejabberd_xml2pb_presence:encode_presence_invite_muc(From,To,Packet);
        <<"http://jabber.org/protocol/muc#del_register">> ->
                ejabberd_xml2pb_presence:encode_del_muc_register(From,To,Packet);
        <<"http://jabber.org/protocol/muc#vcard_update">> ->
                ejabberd_xml2pb_presence:encode_update_muc_vcard(From,To,Packet);      
        <<"jabber:x:verify_friend">> ->
                case proplists:get_value(<<"result">>,Packet#xmlel.attrs) of
                undefined ->
                    case proplists:get_value(<<"method">>,Packet#xmlel.attrs) of
                    <<"manual_authentication_confirm">> ->
                        ejabberd_xml2pb_presence:encode_manual_authentication_confirm(From,To,Packet);
                    _ ->
                        <<"error">>
                    end;
                _ ->
                    ejabberd_xml2pb_presence:encode_verify_friend(From,To,Packet)
                end;
        <<"http://jabber.org/protocol/user#invite_rslt">> ->
                case proplists:get_value(<<"result">>,Packet#xmlel.attrs) of
                undefined ->
                    <<"error">>;
                _ ->
                    ejabberd_xml2pb_presence:encode_verify_friend(From,To,Packet)
                end;
        <<"jabber:x:delete_friend">> ->
                ejabberd_xml2pb_presence:encode_delete_friend(From,To,Packet);      
        <<"jabber:x:mask_user">> ->
                ejabberd_xml2pb_presence:encode_presence_mask_user(From,To,Packet);      
        <<"">> ->
            case catch ejabberd_public:get_sub_xmlns_name(Packet) of
            {<<"x">>,<<"http://jabber.org/protocol/muc#user">>} ->
                ejabberd_xml2pb_presence:encode_x_user_packet(From,To,Packet);
            {<<"query">>,<<"http://jabber.org/protocol/muc#owner">>} ->
                ejabberd_xml2pb_presence:encode_encode_update_muc_vcard(From,To,Packet);
            _ ->
                case catch xml:get_subtag(Packet,<<"show">>) of
                false ->
                    <<"error">>;
                _ ->
                    ejabberd_xml2pb_presence:enocde_status(From,To,Packet)
                end
            end;
        _ ->
            <<"error">>
        end,

    case PB_PRESENCE of
    <<"error">> ->
        ok;
    _ ->
        Text = ejabberd_encode_protobuf:uint32_pack(byte_size(PB_PRESENCE),PB_PRESENCE),
        ?DEBUG("PB_PRESENCE ~p ,Text ~p ~n",[PB_PRESENCE,Text]),
        send_text(StateData, Text)
    end;
do_send_probuf_msg(StateData,From,To, Packet) ->
    ?DEBUG("Packet ~p ~n",[Packet]).
     
send_welcome_msg(StateData,User,Server,Version,SockMod) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	PBMsg = ejabberd_encode_protobuf:struct_pb_welcome(From,From,Server,Version,User,SockMod),
		?DEBUG("PBMsg ~p ~n",[PBMsg]),
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(PBMsg),PBMsg),
		?DEBUG("Text ~p ~n",[Text]),
	send_text(StateData, Text).
	
send_startTLS(StateData,User,Server) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	PBMsg = ejabberd_encode_protobuf:struct_pb_startTLS(From,From),
		?DEBUG("PBMsg ~p ~n",[PBMsg]),
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(PBMsg),PBMsg),
		?DEBUG("Text ~p ~n",[Text]),
	%%send_text(StateData, Text).
    Text.

send_stream_end(StateData) ->
    ?DEBUG("send_stream_end ~p ~n",[self()]),
	End_Msg = ejabberd_encode_protobuf:struct_pb_streamend(<<"">>,<<"">>),
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(End_Msg),End_Msg),
	send_text(StateData, Text).
	

send_auth_msg(StateData,User,Server,Res) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	Auth_Msg = ejabberd_encode_protobuf:struct_pb_auth_msg(From,From,Res),	
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(Auth_Msg),Auth_Msg),
		?DEBUG("Text auth ~p ~n",[Text]),
	send_text(StateData, Text).

send_auth_login_response_sucess(StateData,User,Server,Msg_ID,INFO) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	Auth_Msg = ejabberd_encode_protobuf:struct_pb_response_suc(From,From,0,Msg_ID,INFO,<<"login sucess">>),	
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(Auth_Msg),Auth_Msg),
		?DEBUG("Text login  auth ~p, ~p ,~p  ~n",[Text,StateData#state.sockmod,StateData#state.socket]),
	send_text(StateData, Text).

send_auth_login_response_failed(StateData,User,Server,Msg_ID,INFO) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	Auth_Msg = ejabberd_encode_protobuf:struct_pb_response_err(From,From,0,Msg_ID,INFO,<<"login failed">>),
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(Auth_Msg),Auth_Msg),
		?DEBUG("Text login  auth ~p ,~p ,~p ~n",[Text,StateData#state.sockmod,StateData#state.socket]),
	send_text(StateData, Text).

send_iq_bind_msg(StateData,User,Server,Key,Value,Msg_ID,Body) ->
	From = jlib:jid_to_string({User,Server,<<"">>}),
	IQ_Msg = ejabberd_encode_protobuf:struct_pb_iq_msg(From,From,Key,Value,Msg_ID,Body),
	Text = ejabberd_encode_protobuf:uint32_pack(byte_size(IQ_Msg),IQ_Msg),
	?DEBUG("Text IQ ~p ~n",[Text]),
	send_text(StateData, Text).

encode_iq_pb_packet(StateData,From,To, Packet) ->
    case xml:get_attr(<<"type">>, Packet#xmlel.attrs) of
    <<"eorror">> ->
        encode_iq_error_pb_packet(From,To,Packet);
    _ ->
        encode_iq_result_pb_packet(StateData,From,To,Packet)
    end.


encode_iq_error_pb_packet(From,To,Packet) ->
    ejabberd_xml2pb_iq:encode_pb_error_iq(From,To,Packet).  

encode_iq_result_pb_packet(StateData,From,To, Packet) ->
    case catch ejabberd_public:get_sub_xmlns_name(Packet) of
    {<<"bind">>,<<"urn:ietf:params:xml:ns:xmpp-bind">>} ->
        ejabberd_xml2pb_iq:encode_pb_iq_bind_result(From,To,Packet,StateData#state.key);
    {<<"query">>,<<"http://jabber.org/protocol/muc#user_mucs">>} ->
        ejabberd_xml2pb_iq:encode_user_muc_pb(From,To,Packet);
    {<<"query">>,<<"http://jabber.org/protocol/create_muc">>} ->
        ejabberd_xml2pb_iq:encode_pb_iq_create_muc(From,To,Packet);
    {<<"query">>,<<"http://jabber.org/protocol/muc#invite_v2">>} ->
        ejabberd_xml2pb_iq:encode_muc_invite_user_v2_pb(From,To,Packet);
    {<<"query">>,<<"http://jabber.org/protocol/muc#register">>} ->
        case xml:get_subtag(Packet,<<"query">>) of
        false ->
            <<"error">>;
        Query ->
            case xml:get_subtags(Query,<<"m_user">>) of
            false ->
                ejabberd_xml2pb_iq:encode_pb_muc_user_register(From,To,Packet);
            _ ->
                ejabberd_xml2pb_iq:encode_muc_user_pb(From,To,Packet)
            end
        end;
    {<<"query">>,<<"http://jabber.org/protocol/muc#del_register">>} ->
        ejabberd_xml2pb_iq:encode_pb_muc_user_del_register(From,To,Packet);
    {<<"query">>,<<"http://jabber.org/protocol/muc#admin">>} ->
        ejabberd_xml2pb_iq:encode_pb_muc_amdin(From,To,Packet);
    {<<"query">>,<<"http://jabber.org/protocol/muc#owner">>} ->
        ejabberd_xml2pb_iq:encode_pb_destroy_muc(From,To,Packet);
    {<<"get_verify_friend_mode">>,<<"jabber:iq:verify_friend_mode">>} ->
        ejabberd_xml2pb_iq:encode_pb_get_friend_opt(From,To,Packet);
    {<<"set_verify_friend_mode">>,<<"jabber:iq:verify_friend_mode">>} ->
        ejabberd_xml2pb_iq:encode_pb_set_friend_opt(From,To,Packet);
    {<<"get_user_friends">>,<<"jabber:x:get_friend">>} ->
        ejabberd_xml2pb_iq:encode_pb_get_user_friends(From,To,Packet);
    {<<"delete_friend">>,<<"jabber:x:delete_friend">>} ->
        ejabberd_xml2pb_iq:encode_pb_del_user_friend(From,To,Packet);
    {<<"key">>,<<"urn:xmpp:key">>} ->
        ejabberd_xml2pb_iq:encode_pb_time_http_key(From,To,Packet);
    {<<"query">>,<<"jabber:x:mask_user_v2">>} ->
        ejabberd_xml2pb_iq:encode_pb_get_mask_user(From,To,Packet);
    {<<"query">>, <<"http://jabber.org/protocol/muc#muc_user_subscribe">>} ->
        ejabberd_xml2pb_iq:encode_pb_handle_user_subscribe(From,To,Packet);
    {<<"mask_user">>,<<"jabber:x:mask_user">>} ->
        ejabberd_xml2pb_iq:encode_pb_set_mask_user(From,To,Packet);
    {<<"cancel_mask_user">>,<<"jabber:x:mask_user">>} ->
        ejabberd_xml2pb_iq:encode_pb_cancel_mask_user(From,To,Packet);
    _ ->
        case xml:get_attr(<<"type">>, Packet#xmlel.attrs) of
        {value,<<"result">>} ->
             if Packet#xmlel.children =:= [] ->
                 ejabberd_xml2pb_iq:encode_pb_ping(From,To,Packet);
             true -> 
                 <<"error">>
             end;
         _ ->            
             <<"error">>
         end
    end.


update_push_flag(Server,User,Rescource) ->
        ejabberd_auth_odbc:kick_token_login_user(User,Server),
        case str:str(Rescource,<<"Android">>) =/=0  of
        true ->
                update_push(User,Server,<<"android">>);
        false ->
                case str:str(Rescource,<<"iPhone">>) =/= 0 of
                true ->
                        update_push(User,Server,<<"ios">>);
                false ->
                        ok
                end
        end.

update_push(User,Server,Key) ->
 case Key of
 <<"android">> ->
         catch ejabberd_odbc:sql_query(Server,
                [<<"update person_user_mac_key set push_flag = 0 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'ios' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update person_user_mac_key set push_flag = 1 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'android' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update user_mac_key set push_flag = 0 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'ios' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update user_mac_key set push_flag = 1 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'android' ;">>]);
 <<"ios">> ->
         catch ejabberd_odbc:sql_query(Server,
                [<<"update person_user_mac_key set push_flag = 1 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'ios' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update person_user_mac_key set push_flag = 0 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'android' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update user_mac_key set push_flag = 1 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'ios' ;">>]),
         catch ejabberd_odbc:sql_query(Server,
                [<<"update user_mac_key set push_flag = 0 where user_name = '">>,User,<<"' and host = '">>,Server,<<"' and os = 'android' ;">>]);
  _ ->
        ok
 end.