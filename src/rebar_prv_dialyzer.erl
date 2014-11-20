%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et

-module(rebar_prv_dialyzer).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include("rebar.hrl").

-define(PROVIDER, dialyzer).
-define(DEPS, [compile]).

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Opts = [{update_plt, $u, "update-plt", boolean, "Enable updating the PLT. Default: true"},
            {succ_typings, $s, "succ-typings", boolean, "Enable success typing analysis. Default: true"}],
    State1 = rebar_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                               {module, ?MODULE},
                                                               {bare, false},
                                                               {deps, ?DEPS},
                                                               {example, "rebar dialyzer"},
                                                               {short_desc, short_desc()},
                                                               {desc, desc()},
                                                               {opts, Opts}])),
    {ok, State1}.

desc() ->
    short_desc() ++ "\n"
    "\n"
    "This command will build, and keep up-to-date, a suitable PLT and will use "
    "it to carry out success typing analysis on the current project.\n"
    "\n"
    "The following (optional) configurations can be added to a rebar.config:\n"
    "`dialyzer_warnings` - a list of dialyzer warnings\n"
    "`dialyzer_plt` - the PLT file to use\n"
    "`dialyzer_plt_apps` - a list of applications to include in the PLT file*\n"
    "`dialyzer_base_plt` - the base PLT file to use**\n"
    "`dialyzer_base_plt_dir` - the base PLT directory**\n"
    "`dialyzer_base_plt_apps` - a list of applications to include in the base "
    "PLT file**\n"
    "\n"
    "*If this configuration is not present a selection of applications will be "
    "used based on the `applications` and `included_applications` fields in "
    "the relevant .app files.\n"
    "**The base PLT is a PLT containing the core OTP applications often "
    "required for a project's PLT. One base PLT is created per OTP version and "
    "stored in `dialyzer_base_plt_dir` (defaults to $HOME/.rebar3/). A base "
    "PLT is used to create a project's initial PLT.".

short_desc() ->
    "Run the Dialyzer analyzer on the project.".

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    ?INFO("Dialyzer starting, this may take a while...", []),
    Plt = get_plt_location(State),
    Apps = rebar_state:project_apps(State),

    try
        {ok, State1} = update_proj_plt(State, Plt, Apps),
        succ_typings(State1, Plt, Apps)
    catch
        throw:{dialyzer_error, Error} ->
            {error, {?MODULE, {error_processing_apps, Error, Apps}}}
    end.

-spec format_error(any()) -> iolist().
format_error({error_processing_apps, Error, _Apps}) ->
    io_lib:format("Error in dialyzing apps: ~s", [Error]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%% Internal functions

get_plt_location(State) ->
    BuildDir = rebar_state:get(State, base_dir, ?DEFAULT_BASE_DIR),
    DefaultPlt = filename:join([BuildDir, default_plt()]),
    rebar_state:get(State, dialyzer_plt, DefaultPlt).

default_plt() ->
    ".rebar3.otp-" ++ otp_version() ++ ".plt".

otp_version() ->
    Release = erlang:system_info(otp_release),
    try otp_version(Release) of
        Vsn ->
            Vsn
    catch
        error:_ ->
            Release
    end.

otp_version(Release) ->
    File = filename:join([code:root_dir(), "releases", Release, "OTP_VERSION"]),
    {ok, Contents} = file:read_file(File),
    [Vsn] = binary:split(Contents, [<<$\n>>], [global, trim]),
    [_ | _] = unicode:characters_to_list(Vsn).

update_proj_plt(State, Plt, Apps) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    case proplists:get_value(update_plt, Args) of
        false ->
            {ok, State};
        _ ->
            do_update_proj_plt(State, Plt, Apps)
    end.

do_update_proj_plt(State, Plt, Apps) ->
    ?INFO("Updating plt...", []),
    Files = get_plt_files(State, Apps),
    case read_plt(State, Plt) of
        {ok, OldFiles} ->
            check_plt(State, Plt, OldFiles, Files);
        {error, no_such_file} ->
            build_proj_plt(State, Plt, Files)
    end.

get_plt_files(State, Apps) ->
    PltApps = rebar_state:get(State, dialyzer_plt_apps, []),
    DepApps = lists:flatmap(fun rebar_app_info:applications/1, Apps),
    get_plt_files([erts] ++ PltApps ++ DepApps, Apps, [], []).

default_plt_apps() ->
    [erts,
     kernel,
     stdlib].

get_plt_files([], _, _, Files) ->
    Files;
get_plt_files([AppName | DepApps], Apps, PltApps, Files) ->
    case lists:member(AppName, PltApps) orelse app_member(AppName, Apps) of
        true ->
            get_plt_files(DepApps, Apps, PltApps, Files);
        false ->
            {DepApps2, Files2} = app_name_to_info(AppName),
            DepApps3 = DepApps2 ++ DepApps,
            Files3 = Files2 ++ Files,
            get_plt_files(DepApps3, Apps, [AppName | PltApps], Files3)
    end.

app_member(AppName, Apps) ->
    case rebar_app_utils:find(ec_cnv:to_binary(AppName), Apps) of
        {ok, _App} ->
            true;
        error ->
            false
    end.

apps_to_files(Apps) ->
    lists:flatmap(fun app_to_files/1, Apps).

app_to_files(App) ->
    AppName = ec_cnv:to_atom(rebar_app_info:name(App)),
    {_, Files} = app_name_to_info(AppName),
    Files.

modules_to_files(Modules, EbinDir) ->
    Ext = code:objfile_extension(),
    Mod2File = fun(Module) -> module_to_file(Module, EbinDir, Ext) end,
    rebar_utils:filtermap(Mod2File, Modules).

module_to_file(Module, EbinDir, Ext) ->
    File = filename:join(EbinDir, atom_to_list(Module) ++ Ext),
    case filelib:is_file(File) of
        true ->
            {true, File};
        false ->
            ?CONSOLE("Unknown module ~s", [Module]),
            false
    end.

app_names_to_files(AppNames) ->
    ToFiles = fun(AppName) ->
                      {_, Files} = app_name_to_info(AppName),
                      Files
              end,
    lists:flatmap(ToFiles, AppNames).

app_name_to_info(AppName) ->
    case code:lib_dir(AppName) of
        {error, _} ->
            ?CONSOLE("Unknown application ~s", [AppName]),
            {[], []};
        AppDir ->
            app_dir_to_info(AppDir, AppName)
    end.

app_dir_to_info(AppDir, AppName) ->
    EbinDir = filename:join(AppDir, "ebin"),
    AppFile = filename:join(EbinDir, atom_to_list(AppName) ++ ".app"),
    case file:consult(AppFile) of
        {ok, [{application, AppName, AppDetails}]} ->
            DepApps = proplists:get_value(applications, AppDetails, []),
            IncApps = proplists:get_value(included_applications, AppDetails,
                                          []),
            Modules = proplists:get_value(modules, AppDetails, []),
            Files = modules_to_files(Modules, EbinDir),
            {IncApps ++ DepApps, Files};
        _ ->
            Error = io_lib:format("Could not parse ~p", [AppFile]),
            throw({dialyzer_error, Error})
    end.

read_plt(_State, Plt) ->
    case dialyzer:plt_info(Plt) of
        {ok, Info} ->
            Files = proplists:get_value(files, Info, []),
            {ok, Files};
        {error, no_such_file} = Error ->
            Error;
        {error, read_error} ->
            Error = io_lib:format("Could not read the PLT file ~p", [Plt]),
            throw({dialyzer_error, Error})
    end.

check_plt(State, Plt, OldList, FilesList) ->
    Old = sets:from_list(OldList),
    Files = sets:from_list(FilesList),
    Remove = sets:subtract(Old, Files),
    {ok, State1} = remove_plt(State, Plt, sets:to_list(Remove)),
    Check = sets:intersection(Files, Old),
    {ok, State2} = check_plt(State1, Plt, sets:to_list(Check)),
    Add = sets:subtract(Files, Old),
    add_plt(State2, Plt, sets:to_list(Add)).

remove_plt(State, _Plt, []) ->
    {ok, State};
remove_plt(State, Plt, Files) ->
    ?INFO("Removing ~b files from ~p...", [length(Files), Plt]),
    run_plt(State, Plt, plt_remove, Files).

check_plt(State, _Plt, []) ->
    {ok, State};
check_plt(State, Plt, Files) ->
    ?INFO("Checking ~b files in ~p...", [length(Files), Plt]),
    run_plt(State, Plt, plt_check, Files).

add_plt(State, _Plt, []) ->
    {ok, State};
add_plt(State, Plt, Files) ->
    ?INFO("Adding ~b files to ~p...", [length(Files), Plt]),
    run_plt(State, Plt, plt_add, Files).

run_plt(State, Plt, Analysis, Files) ->
    Opts = [{analysis_type, Analysis},
            {init_plt, Plt},
            {from, byte_code},
            {files, Files}],
    run_dialyzer(State, Opts).

build_plt(State, Plt, Files) ->
    ?INFO("Adding ~b files to ~p...", [length(Files), Plt]),
    Opts = [{analysis_type, plt_build},
            {output_plt, Plt},
            {files, Files}],
    run_dialyzer(State, Opts).

build_proj_plt(State, Plt, Files) ->
    BasePlt = get_base_plt_location(State),
    BaseFiles = get_base_plt_files(State),
    {ok, State1} = update_base_plt(State, BasePlt, BaseFiles),
    ?INFO("Copying ~p to ~p...", [BasePlt, Plt]),
    case file:copy(BasePlt, Plt) of
        {ok, _} ->
            check_plt(State1, Plt, BaseFiles, Files);
        {error, Reason} ->
            Error = io_lib:format("Could not copy PLT from ~p to ~p: ~p",
                                  [BasePlt, Plt, file:format_error(Reason)]),
            throw({dialyzer_error, Error})
    end.

get_base_plt_location(State) ->
    Home = rebar_utils:home_dir(),
    GlobalConfigDir = filename:join(Home, ?CONFIG_DIR),
    BaseDir = rebar_state:get(State, dialyzer_base_plt_dir, GlobalConfigDir),
    BasePlt = rebar_state:get(State, dialyzer_base_plt, default_plt()),
    filename:join(BaseDir, BasePlt).

get_base_plt_files(State) ->
    BasePltApps = rebar_state:get(State, dialyzer_base_plt_apps,
                                  default_plt_apps()),
    app_names_to_files(BasePltApps).

update_base_plt(State, BasePlt, BaseFiles) ->
    ?INFO("Updating base plt...", []),
    case read_plt(State, BasePlt) of
        {ok, OldBaseFiles} ->
            check_plt(State, BasePlt, OldBaseFiles, BaseFiles);
        {error, no_such_file} ->
            _ = filelib:ensure_dir(BasePlt),
            build_plt(State, BasePlt, BaseFiles)
    end.

succ_typings(State, Plt, Apps) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    case proplists:get_value(succ_typings, Args) of
        false ->
            {ok, State};
        _ ->
            do_succ_typings(State, Plt, Apps)
    end.

do_succ_typings(State, Plt, Apps) ->
    ?INFO("Doing success typing analysis...", []),
    Files = apps_to_files(Apps),
    ?INFO("Analyzing ~b files with ~p...", [length(Files), Plt]),
    Opts = [{analysis_type, succ_typings},
            {from, byte_code},
            {files, Files},
            {init_plt, Plt}],
    run_dialyzer(State, Opts).

run_dialyzer(State, Opts) ->
    Warnings = rebar_state:get(State, dialyzer_warnings, default_warnings()),
    Opts2 = [{get_warnings, true},
             {warnings, Warnings} |
             Opts],
    _ = [?CONSOLE(format_warning(Warning), [])
         || Warning <- dialyzer:run(Opts2)],
    {ok, State}.

format_warning(Warning) ->
    string:strip(dialyzer_format_warning(Warning), right, $\n).

dialyzer_format_warning(Warning) ->
    case dialyzer:format_warning(Warning) of
        ":0: " ++ Warning2 ->
            Warning2;
        Warning2 ->
            Warning2
    end.
default_warnings() ->
    [error_handling,
     unmatched_returns,
     underspecs].
