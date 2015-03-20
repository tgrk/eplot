%%
%% TODO: * fix croping margin
%%       * vertical, horizontal, no lines
%%       * antialiasing?
%%       * performance?
%%       * fonts loading. what happens when font is missing?
%%
-module(egd_chart).

%% API
-export([graph/1,
         graph/2,
         bar2d/1,
         bar2d/2
        ]).
-export([smart_ticksize/3, calculate_ticks_value/2]).

%% Types
-type data() :: list({any(), any()}).
-type opts() :: list({atom(), any()}).

-define(DEFAULT_FONT, "6x11_latin1.wingsfont").

-record(chart, {
          type          = png,
          render_engine = opaque,
          margin        = 40,                   % Margin
          bbx           = {{30,30}, {130,130}}, % Graph boundingbox (internal)
          ibbx          = undefined,
          ranges        = {{0,0}, {100,100}},   % Data boundingbox
          width         = 160,                  % Total chart width
          height        = 160,                  % Total chart height
          dxdy          = {1.0,1.0},
          ticktype      = {dash, x, y},         % Tick eg. {dash, x, y}, {line, x}
          ticksize      = {10,10},
          precision     = {2,2},
          font          = ?DEFAULT_FONT,

          %% default colors
          bg_rgba       = {230, 230, 255, 255}, % graph background color
          margin_rgba   = {255, 255, 255, 255}, % margin background color
          graph_rgba    = undefined,            % use colorscheme colors
          tick_rgba     = {130,130,130},        % use colorscheme colors

          %% graph specific
          x_label       = "X",
          y_label       = "Y",
          x_label_fun   = fun(X) -> X end,      % Transform X value using fun
          y_label_fun   = fun(Y) -> Y end,      % Transform Y value using fun
          graph_name_yo = 10,                   % Name offset from top
          graph_name_yh = 10,                   % Name drop offset
          graph_name_xo = 10,                   % Name offset from RHS

          %% bar2d specific
          bar_width     = 40,
          column_width  = 40
         }).

-define(float_error, 0.0000000000000001).

%%%============================================================================
%%% API
%%%============================================================================
-spec graph(data()) -> binary() | no_return().
graph(Data) ->
    graph(Data, [{width, 300}, {height, 300}]).

-spec graph(data(), opts()) -> binary() | no_return().
graph(Data, Options) ->
    Chart = graph_chart(Options, Data),
    Im = egd:create(Chart#chart.width, Chart#chart.height),

    %% background
    BgColor = egd:color(Chart#chart.bg_rgba),
    {Pt1, Pt2} = Chart#chart.bbx,
    egd:filledRectangle(Im, Pt1, Pt2, BgColor),

    %% use external fonts
    Font = load_font(Chart),

    %% draw linear graph
    draw_graphs(Data, Chart, Im),

    %% mask everything outside of bbx
    {{X0,Y0}, {X1,Y1}} = Chart#chart.bbx,
    W = Chart#chart.width,
    H = Chart#chart.height,
    egd:filledRectangle(Im, {0, 0},      {X0 - 1, H}, BgColor),
    egd:filledRectangle(Im, {X1 + 1, 0}, {W, H},      BgColor),
    egd:filledRectangle(Im, {0, 0},      {W, Y0 - 1}, BgColor),
    egd:filledRectangle(Im, {0, Y1 + 1}, {W, H},      BgColor),

    %% draw grid
    draw_ticks(Chart, Im, Font),

    %% draw graph box
    draw_origo_lines(Chart, Im),

    %% draw graph legend
    draw_graph_names(Data, Chart, Font, Im),

    %% draw axis labels
    draw_xlabel(Chart, Im, Font),
    draw_ylabel(Chart, Im, Font),

    render_graph(Im, Chart).


%% @doc
%% Abstract:
%% The graph is devided into column where each column have
%% one or more bars.
%% Each column is associated with a name.
%% Each bar may have a secondary name (a key).
%% @end
-spec bar2d(data()) -> binary() | no_return().
bar2d(Data) ->
    bar2d(Data, [{width, 600}, {height, 600}]).

-spec bar2d(data(), opts()) -> binary() | no_return().
bar2d(Data0, Options) ->
    {ColorMap, Data} = bar2d_convert_data(Data0),
    Chart = bar2d_chart(Options, Data),
    Im = egd:create(Chart#chart.width, Chart#chart.height),

    %% background
    BgColor = egd:color(Chart#chart.bg_rgba),
    {Pt1, Pt2} = Chart#chart.bbx,
    egd:filledRectangle(Im, Pt1, Pt2, BgColor),

    %% Fonts? Check for text enabling
    Font = load_font(Chart),

    draw_bar2d_ytick(Im, Chart, Font),

    %% Color map texts for sets
    draw_bar2d_set_colormap(Im, Chart, Font, ColorMap),

    %% Draw bars
    draw_bar2d_data(Data, Chart, Font, Im),

    egd:rectangle(Im, Pt1, Pt2, egd:color({0,0,0})),

    render_graph(Im, Chart).

%%%============================================================================
%%% Internal functions
%%%============================================================================
graph_chart(Opts, Data) ->
    {{X0,Y0},{X1,Y1}} = proplists:get_value(ranges, Opts, ranges(Data)),
    Type       = proplists:get_value(type,          Opts, png),
    Width      = proplists:get_value(width,         Opts, 600),
    Height     = proplists:get_value(height,        Opts, 600),
    Xlabel     = proplists:get_value(x_label,       Opts, "X"),
    Ylabel     = proplists:get_value(y_label,       Opts, "Y"),
    XlabelFun  = proplists:get_value(x_label_fun,   Opts, fun (X) -> X end),
    YlabelFun  = proplists:get_value(y_label_fun,   Opts, fun (Y) -> Y end),

    %% multiple ways to set ranges
    XrangeMax  = proplists:get_value(x_range_max,   Opts, X1),
    XrangeMin  = proplists:get_value(x_range_min,   Opts, X0),
    YrangeMax  = proplists:get_value(y_range_max,   Opts, Y1),
    YrangeMin  = proplists:get_value(y_range_min,   Opts, Y0),
    {Xr0, Xr1} = proplists:get_value(x_range,       Opts, {XrangeMin, XrangeMax}),
    {Yr0, Yr1} = proplists:get_value(y_range,       Opts, {YrangeMin, YrangeMax}),
    Ranges     = {{Xr0, Yr0}, {Xr1,Yr1}},

    Precision  = precision_level(Ranges, 10),
    {TsX, TsY} = smart_ticksize(Ranges, 10),
    TickType   = proplists:get_value(ticktype,      Opts, {dash, x, y}),
    XTicksize  = proplists:get_value(x_ticksize,    Opts, TsX),
    YTicksize  = proplists:get_value(y_ticksize,    Opts, TsY),
    Ticksize   = proplists:get_value(ticksize,      Opts, {XTicksize, YTicksize}),
    Margin     = proplists:get_value(margin,        Opts, 30),
    BGC        = proplists:get_value(bg_rgba,       Opts, {230, 230, 255, 255}),
    MGC        = proplists:get_value(margin_rgba,   Opts, {230, 230, 255, 255}),
    GGC        = proplists:get_value(graph_rgba,    Opts, undefined),
    TGC        = proplists:get_value(tick_rgba,     Opts, {130, 130, 130}),
    Renderer   = proplists:get_value(render_engine, Opts, opaque),

    BBX        = {{Margin, Margin}, {Width - Margin, Height - Margin}},
    DxDy       = update_dxdy(Ranges,BBX),

    %%TODO: validate opts eg ticksize cannot be {0,0}
    #chart{
       type          = Type,
       width         = Width,
       height        = Height,
       x_label       = Xlabel,
       y_label       = Ylabel,
       x_label_fun   = XlabelFun,
       y_label_fun   = YlabelFun,
       ranges        = Ranges,
       precision     = Precision,
       ticktype      = TickType,
       ticksize      = Ticksize,
       margin        = Margin,
       bbx           = BBX,
       dxdy          = DxDy,
       render_engine = Renderer,
       bg_rgba       = BGC,
       margin_rgba   = MGC,
       graph_rgba    = GGC,
       tick_rgba     = TGC
    }.

draw_ylabel(Chart, Im, Font) ->
    Label = string(Chart#chart.y_label, 2),
    N = length(Label),
    {Fw, _Fh} = egd_font:size(Font),
    Width = N * Fw,
    {{Xbbx, Ybbx}, {_,_}} = Chart#chart.bbx,
    Pt = {Xbbx - trunc(Width / 2), Ybbx - 20},
    egd:text(Im, Pt, Font, Label, egd:color({0,0,0})).

draw_xlabel(Chart, Im, Font) ->
    Label = string(Chart#chart.x_label, 2),
    N = length(Label),
    {Fw,_Fh} = egd_font:size(Font),
    Width = N*Fw,
    {{Xbbxl,_}, {Xbbxr,Ybbx}} = Chart#chart.bbx,
    Xc = trunc((Xbbxr - Xbbxl)/2) + Chart#chart.margin,
    Y  = Ybbx + 20,
    Pt = {Xc - trunc(Width/2), Y},
    egd:text(Im, Pt, Font, Label, egd:color({0,0,0})).

draw_graphs(Datas, Chart, Im) ->
    draw_graphs(Datas, 0, Chart, Im).
draw_graphs([], _, _, _) -> ok;
draw_graphs([{_, Data} | Datas], ColorIndex, Chart, Im) ->
    Color = get_graph_color(Chart, ColorIndex),

    %% convert data to graph data
    %% fewer pass of xy2chart
    GraphData = [xy2chart(Pt, Chart) || Pt <- Data],
    draw_graph(GraphData, Color, Im),
    draw_graphs(Datas, ColorIndex + 1, Chart, Im).

draw_graph([], _, _) -> ok;
draw_graph([Pt1, Pt2 | Data], Color, Im) ->
    draw_graph_dot(Pt1, Color, Im),
    draw_graph_line(Pt1,Pt2, Color, Im),
    draw_graph([Pt2 | Data], Color, Im);

draw_graph([Pt | Data], Color, Im) ->
    draw_graph_dot(Pt, Color, Im),
    draw_graph(Data, Color, Im).

draw_graph_dot({X, Y}, Color, Im) ->
    egd:filledEllipse(Im, {X - 3, Y - 3}, {X + 3, Y + 3}, Color);
draw_graph_dot({X,Y,Ey}, Color, Im) ->
    egd:line(Im, {X, Y - Ey}, {X, Y + Ey}, Color),
    egd:line(Im, {X - 4, Y - Ey}, {X + 4, Y - Ey}, Color),
    egd:line(Im, {X - 4, Y + Ey}, {X + 4, Y + Ey}, Color),
    egd:filledEllipse(Im, {X - 3, Y - 3}, {X + 3, Y + 3}, Color).

draw_graph_line({X1, Y1, _},{X2 , Y2, _}, Color, Im) ->
    egd:line(Im, {X1, Y1}, {X2, Y2}, Color);
draw_graph_line(Pt1, Pt2, Color, Im) ->
    egd:line(Im, Pt1, Pt2, Color).

%% name and color information
draw_graph_names(Datas, Chart, Font, Im) ->
    draw_graph_names(Datas, 0, Chart, Font, Im, 0, Chart#chart.graph_name_yh).
draw_graph_names([], _, _, _, _, _, _) ->
    ok;
draw_graph_names([{Name, _}|Datas], ColorIndex, Chart, Font, Im, Yo, Yh) ->
    Color = get_graph_color(Chart, ColorIndex),
    draw_graph_name_color(Chart, Im, Font, Name, Color, Yo),
    draw_graph_names(Datas, ColorIndex + 1, Chart, Font, Im, Yo + Yh, Yh).

draw_graph_name_color(Chart, Im, Font, Name, Color, Yh) ->
    {{_X0,Y0}, {X1,_Y1}} = Chart#chart.bbx,
    Xo   = Chart#chart.graph_name_xo,
    Yo   = Chart#chart.graph_name_yo,
    Xl   = 50,
    LPt1 = {X1 - Xo - Xl, Y0 + Yo + Yh},
    LPt2 = {X1 - Xo, Y0 + Yo + Yh},

    {Fw, Fh} = egd_font:size(Font),
    Str      = string(Name,2),
    N        = length(Str),
    TPt      = {X1 - 2 * Xo - Xl - Fw * N, Y0 + Yo + Yh - trunc(Fh / 2) - 3},

    egd:filledRectangle(Im, LPt1, LPt2, Color),
    egd:text(Im, TPt, Font, Str, egd:color({0,0,0})).

%% origo crosshair
draw_origo_lines(Chart, Im) ->
    Black  = egd:color({20,20,20}),
    Black1 = egd:color({50,50,50}),
    {{X0,Y0},{X1,Y1}} = Chart#chart.bbx,
    {X,Y} = xy2chart({0,0}, Chart),
    if
        X > X0, X < X1, Y > Y0, Y < Y1 ->
            egd:filledRectangle(Im, {X0,Y}, {X1,Y}, Black1),
            egd:filledRectangle(Im, {X,Y0}, {X,Y1}, Black1);
        true ->
            ok
    end,
    egd:rectangle(Im, {X0,Y0}, {X1,Y1}, Black),
    ok.

%%TODO: move to bottom
calculate_ticks_value(Range, TickSize) when Range < 0 ->
    trunc(Range / TickSize) * TickSize;
calculate_ticks_value(Range, TickSize)  ->
    (trunc(Range / TickSize) + 1) * TickSize.

calculate_ticks_gap(line = TicksType) -> 0;
calculate_ticks_gap(dash = TicksType) -> 2.

%% new ticks
draw_ticks(#chart{ticktype = {_Shape, x, y}} = Chart, Im, Font) ->
    {Xts, Yts} = Chart#chart.ticksize,
    {{Xmin,Ymin}, {Xmax,Ymax}} = Chart#chart.ranges,
    Ys = calculate_ticks_value(Ymin, Yts),
    Xs = calculate_ticks_value(Xmin, Xts),
    draw_yticks_lp(Im, Chart, Ys, Yts, Ymax, Font),
    draw_xticks_lp(Im, Chart, Xs, Xts, Xmax, Font);
draw_ticks(#chart{ticktype = {_Shape, x}} = Chart, Im, Font) ->
    {Xts, _Yts} = Chart#chart.ticksize,
    {{Xmin,_Ymin}, {Xmax,_Ymax}} = Chart#chart.ranges,
    Xs = calculate_ticks_value(Xmin, Xts),
    draw_xticks_lp(Im, Chart, Xs, Xts, Xmax, Font);
draw_ticks(#chart{ticktype = {_Shape, y}} = Chart, Im, Font) ->
    {_Xts, Yts} = Chart#chart.ticksize,
    {{_Xmin,Ymin}, {_Xmax,Ymax}} = Chart#chart.ranges,
    Ys = calculate_ticks_value(Ymin, Yts),
    draw_yticks_lp(Im, Chart, Ys, Yts, Ymax, Font).

draw_yticks_lp(Im, Chart, Yi, Yts, Ymax, Font) when Yi < Ymax ->
    {_, Y}          = xy2chart({0, Yi}, Chart),
    {{X, _}, _}     = Chart#chart.bbx,
    {_, Precision}  = Chart#chart.precision,
    Gap             = calculate_ticks_gap(element(1, Chart#chart.ticktype)),

    draw_perf_ybar(Im, Chart, Y),
    egd:filledRectangle(Im, {X - Gap,Y}, {X + Gap, Y}, egd:color({0,0,0})),
    tick_text(Im, Font, apply_label_fun(y, Chart, Yi), {X, Y}, Precision, left),
    draw_yticks_lp(Im, Chart, Yi + Yts, Yts, Ymax, Font);
draw_yticks_lp(_,_,_,_,_,_) ->
    ok.

draw_xticks_lp(Im, Chart, Xi, Xts, Xmax, Font) when Xi < Xmax ->
    {X, _}          = xy2chart({Xi,0}, Chart),
    {_, {_, Y}}     = Chart#chart.bbx,
    {Precision, _}  = Chart#chart.precision,
    Gap             = calculate_ticks_gap(element(1, Chart#chart.ticktype)),

    draw_perf_xbar(Im, Chart, X),
    egd:filledRectangle(Im, {X ,Y - Gap}, {X, Y + Gap}, egd:color({0,0,0})),
    tick_text(Im, Font, apply_label_fun(x, Chart, Xi), {X, Y}, Precision, below),
    draw_xticks_lp(Im, Chart, Xi + Xts, Xts, Xmax, Font);
draw_xticks_lp(_,_,_,_,_,_) ->
    ok.

%%TODO: move to bottom
apply_label_fun(Axis, Chart, Value) ->
    Fun = case Axis =:= x of
              true  -> Chart#chart.x_label_fun;
              false -> Chart#chart.y_label_fun
          end,
    Fun(Value).

tick_text(Im, Font, Tick, {X,Y}, Precision, Orientation) ->
    String = string(Tick, Precision),
    L = length(String),
    {Xl,Yl} = egd_font:size(Font),
    PxL = L * Xl,
    {Xo,Yo} = case Orientation of
                  above -> {-round(PxL/2), -Yl - 3};
                  below -> {-round(PxL/2), 3};
                  left  -> {round(-PxL - 4),-round(Yl/2) - 1};
                  right -> {3, -round(Yl/2)};
                  _ -> throw(tick_text_error)
              end,
    egd:text(Im, {X + Xo,Y + Yo}, Font, String, egd:color({0,0,0})).

%% background tick bars, should be drawn with background
draw_perf_ybar(Im, Chart, Yi) ->
    Pw = 5,
    Lw = 10,
    {{X0,_},{X1,_}} = Chart#chart.bbx,
    [Xl,Xr] = lists:sort([X0,X1]),
    Color = egd:color(Chart#chart.tick_rgba),
    lists:foreach(
      fun(X) ->
              egd:filledRectangle(Im, {X,Yi}, {X+Pw, Yi}, Color)
      end, lists:seq(Xl,Xr,Lw)),
    ok.

draw_perf_xbar(Im, Chart, Xi) ->
    Pw = 5,
    Lw = 10,
    {{_,Y0},{_,Y1}} = Chart#chart.bbx,
    [Yu,Yl] = lists:sort([Y0,Y1]),
    Color = egd:color(Chart#chart.tick_rgba),
    lists:foreach(
      fun(Y) ->
              egd:filledRectangle(Im, {Xi,Y}, {Xi, Y+Pw}, Color)
      end, lists:seq(Yu,Yl,Lw)),
    ok.

bar2d_convert_data(Data) ->
    bar2d_convert_data(Data, 0,{[], []}).
bar2d_convert_data([], _, {ColorMap, Out}) ->
    {lists:reverse(ColorMap), lists:sort(Out)};
bar2d_convert_data([{Set, KVs}|Data], ColorIndex, {ColorMap, Out}) ->
    Color = egd_colorscheme:select(default, ColorIndex),
    bar2d_convert_data(Data, ColorIndex + 1, {[{Set,Color}|ColorMap], bar2d_convert_data_kvs(KVs, Set, Color, Out)}).

bar2d_convert_data_kvs([], _, _, Out) ->
    Out;
bar2d_convert_data_kvs([{Key, Value, _} | KVs], Set, Color, Out) ->
    bar2d_convert_data_kvs([{Key, Value} | KVs], Set, Color, Out);
bar2d_convert_data_kvs([{Key, Value} | KVs], Set, Color, Out) ->
    case proplists:get_value(Key, Out) of
        undefined ->
            bar2d_convert_data_kvs(KVs, Set, Color, [{Key, [{{Color, Set}, Value}]}|Out]);
        DVs ->
            bar2d_convert_data_kvs(KVs, Set, Color, [{Key, [{{Color, Set}, Value} | DVs]} | proplists:delete(Key, Out)])
    end.

%% beta color map, static allocated
bar2d_chart(Opts, Data) ->
    Values = lists:foldl(fun ({_, DVs}, Out) ->
                                 Vs = [V || {_,V} <- DVs],
                                 Out ++ Vs
                         end, [], Data),
    Type      = proplists:get_value(type,          Opts, png),
    Margin    = proplists:get_value(margin,        Opts, 30),
    Width     = proplists:get_value(width,         Opts, 600),
    Height    = proplists:get_value(height,        Opts, 600),

    XrangeMax = proplists:get_value(x_range_max,   Opts, length(Data)),
    XrangeMin = proplists:get_value(x_range_min,   Opts, 0),
    YrangeMax = proplists:get_value(y_range_max,   Opts, lists:max(Values)),
    YrangeMin = proplists:get_value(y_range_min,   Opts, 0),
    {Yr0,Yr1} = proplists:get_value(y_range,       Opts, {YrangeMin, YrangeMax}),
    {Xr0,Xr1} = proplists:get_value(x_range,       Opts, {XrangeMin, XrangeMax}),
    Ranges    = proplists:get_value(ranges,        Opts, {{Xr0, Yr0}, {Xr1,Yr1}}),

    TickType  = proplists:get_value(ticktype,      Opts, {dash, x, y}),
    Ticksize  = proplists:get_value(ticksize,      Opts, smart_ticksize(Ranges, 10)),
    Cw        = proplists:get_value(column_width,  Opts, {ratio, 0.8}),
    Bw        = proplists:get_value(bar_width,     Opts, {ratio, 1.0}),
    InfoW     = proplists:get_value(info_box,      Opts, 0),
    Renderer  = proplists:get_value(render_engine, Opts, opaque),

    %% colors
    BGC       = proplists:get_value(bg_rgba,       Opts, {230, 230, 255, 255}),
    MGC       = proplists:get_value(margin_rgba,   Opts, {255, 255, 255, 255}),
    TGC       = proplists:get_value(tick_rgba,     Opts, {130,130,130}),

    %% bounding box
    IBBX     = {{Width - Margin - InfoW, Margin}, {Width - Margin, Height - Margin}},
    BBX      = {{Margin, Margin}, {Width - Margin - InfoW - 10, Height - Margin}},
    DxDy     = update_dxdy(Ranges, BBX),

    #chart{
       type            = Type,
       margin          = Margin,
       width           = Width,
       height          = Height,
       ranges          = Ranges,
       ticktype        = TickType,
       ticksize        = Ticksize,
       bbx             = BBX,
       ibbx            = IBBX,
       dxdy            = DxDy,
       column_width    = Cw,
       bar_width       = Bw,
       margin_rgba     = MGC,
       bg_rgba         = BGC,
       tick_rgba       = TGC,
       render_engine   = Renderer
    }.

draw_bar2d_set_colormap(Im, Chart, Font, ColorMap) ->
    Margin = Chart#chart.margin,
    draw_bar2d_set_colormap(Im, Chart, Font, ColorMap, {Margin, 3}, Margin).

draw_bar2d_set_colormap(_, _, _, [], _, _) -> ok;
draw_bar2d_set_colormap(Im, Chart, Font, [{Set, Color}|ColorMap], {X, Y}, Margin) ->
    String = string(Set, 2),
    egd:text(Im, {X + 10, Y}, Font, String, egd:color({0,0,0})),
    egd:filledRectangle(Im, {X,Y+3}, {X+5, Y+8}, Color),
    draw_bar2d_set_colormap_step(Im, Chart, Font, ColorMap, {X,Y}, Margin).

draw_bar2d_set_colormap_step(Im, Chart, Font, ColorMap, {X,Y}, Margin) when (Y + 23) < Margin ->
    draw_bar2d_set_colormap(Im, Chart, Font, ColorMap, {X, Y + 12}, Margin);
draw_bar2d_set_colormap_step(Im, Chart, Font, ColorMap, {X,_Y}, Margin) ->
    draw_bar2d_set_colormap(Im, Chart, Font, ColorMap, {X + 144, 3}, Margin).

draw_bar2d_ytick(Im, Chart, Font) ->
    {_, Yts}               = Chart#chart.ticksize,
    {{_, _}, {_, Ymax}} = Chart#chart.ranges,
    draw_bar2d_yticks_up(Im, Chart, Yts, Yts, Ymax, Font).   %% UPPER tick points

draw_bar2d_yticks_up(Im, Chart, Yi, Yts, Ymax, Font) when Yi < Ymax ->
    {X, Y}         = xy2chart({0,Yi}, Chart),
    {_, Precision} = Chart#chart.precision,
    draw_bar2d_ybar(Im, Chart, Y),
    egd:filledRectangle(Im, {X-2,Y}, {X+2,Y}, egd:color({0,0,0})),
    tick_text(Im, Font, Yi, {X,Y}, Precision, left),
    draw_bar2d_yticks_up(Im, Chart, Yi + Yts, Yts, Ymax, Font);
draw_bar2d_yticks_up(_,_,_,_,_,_) -> ok.

draw_bar2d_ybar(Im, Chart, Yi) ->
    Pw = 5,
    Lw = 10,
    {{X0,_},{X1,_}} = Chart#chart.bbx,
    [Xl,Xr] = lists:sort([X0,X1]),
    Color = egd:color({180,180,190}),
    lists:foreach(
      fun(X) ->
              egd:filledRectangle(Im, {X-Pw,Yi}, {X, Yi}, Color)
      end, lists:seq(Xl+Pw,Xr,Lw)),
    ok.

draw_bar2d_data(Columns, Chart, Font, Im) ->
    {{Xl,_}, {Xr,_}} = Chart#chart.bbx,
    Cn = length(Columns), % number of columns
    Co = (Xr - Xl)/(Cn),  % column offset within chart
    Cx = Xl + Co/2,       % start x of column
    draw_bar2d_data_columns(Columns, Chart, Font, Im, Cx, Co).

draw_bar2d_data_columns([], _, _, _, _, _) -> ok;
draw_bar2d_data_columns([{Name, Bars} | Columns], Chart, Font, Im, Cx, Co) ->
    {{_X0,_Y0}, {_X1,Y1}} = Chart#chart.bbx,

    Cwb = case Chart#chart.column_width of
              default -> Co;
              {ratio, P} when is_number(P) -> P*Co;
              Cw when is_number(Cw) -> lists:min([Cw,Co])
          end,

    %% draw column text
    String = string(Name, 2),
    Ns = length(String),
    {Fw, Fh} = egd_font:size(Font),
    L = Fw*Ns,
    Tpt = {trunc(Cx - L/2 + 2), Y1 + Fh},
    egd:text(Im, Tpt, Font, String, egd:color({0,0,0})),

    Bn = length(Bars),      % number of bars
    Bo = Cwb/Bn,            % bar offset within column
    Bx = Cx - Cwb/2 + Bo/2, % starting x of bar

    CS = 43,
    draw_bar2d_data_bars(Bars, Chart, Font, Im, Bx, Bo, CS),
    draw_bar2d_data_columns(Columns, Chart, Font, Im, Cx + Co, Co).

draw_bar2d_data_bars([], _, _, _, _, _, _) -> ok;
draw_bar2d_data_bars([{{Color,_Set}, Value}|Bars], Chart, Font, Im, Bx, Bo,CS) ->
    {{_X0,_Y0}, {_X1,Y1}} = Chart#chart.bbx,
    {_, Precision}        = Chart#chart.precision,
    {_, Y}                = xy2chart({0, Value}, Chart),

    Bwb = case Chart#chart.bar_width of
              default -> Bo;
              {ratio, P} when is_number(P) -> P*Bo;
              Bw when is_number(Bw) -> lists:min([Bw,Bo])
          end,


    Black = egd:color({0,0,0}),

    %% draw bar text
    String = string(Value, Precision),
    Ns = length(String),
    {Fw, Fh} = egd_font:size(Font),
    L = Fw*Ns,
    Tpt = {trunc(Bx - L/2 + 2), Y - Fh - 5},
    egd:text(Im, Tpt, Font, String, Black),


    Pt1 = {trunc(Bx - Bwb / 2), Y},
    Pt2 = {trunc(Bx + Bwb / 2), Y1},
    egd:filledRectangle(Im, Pt1, Pt2, Color),
    egd:rectangle(Im, Pt1, Pt2, Black),
    draw_bar2d_data_bars(Bars, Chart, Font, Im, Bx + Bo, Bo, CS + CS).

%%%============================================================================
%%% Aux functions
%%%============================================================================
xy2chart({X,Y}, #chart{
                   ranges = {{Rx0,Ry0}, {_Rx1,_Ry1}},
                   bbx    = {{Bx0,By0}, {_Bx1, By1}},
                   dxdy   = {Dx, Dy},
                   margin = Margin } ) ->
    {round(X*Dx + Bx0 - Rx0*Dx), round(By1 - (Y*Dy + By0 - Ry0*Dy - Margin))};
xy2chart({X,Y,Error}, Chart) ->
    {Xc,Yc} = xy2chart({X,Y}, #chart{ dxdy = {_,Dy} } = Chart),
    {Xc, Yc, round(Dy*Error)}.

ranges([{_Name, Es} | Data]) when is_list(Es) ->
    Ranges = xy_minmax(Es),
    ranges(Data, Ranges).

ranges([], Ranges) -> Ranges;
ranges([{_Name, Es} | Data], CoRanges) when is_list(Es) ->
    Ranges = xy_minmax(Es),
    ranges(Data, xy_resulting_ranges(Ranges, CoRanges)).

smart_ticksize({{X0, Y0}, {X1, Y1}}, N) ->
    { smart_ticksize(X0,X1,N), smart_ticksize(Y0,Y1,N)}.

smart_ticksize(S, E, N) when is_number(S), is_number(E), is_number(N) ->
    %% Calculate stepsize then 'humanize' the value to a human pleasing format.
    R = abs((E - S))/N,
    if
        abs(R) < ?float_error -> 2.0;
        true ->
            %% get the ratio on the form of 2-3 significant digits.
            %%V =  2 - math:log10(R),
            %%P = trunc(V + 0.5),
            P = precision_level(S, E, N),
            M = math:pow(10, P),
            Vsig = R*M,

            %% do magic
            Rsig = Vsig/50,
            Hsig = 50 * trunc(Rsig + 0.5),

            %% fin magic
            Hsig/M
    end;
smart_ticksize(_, _, _) -> 2.0.

precision_level({{X0, Y0}, {X1, Y1}}, N) ->
     { precision_level(X0,X1,N), precision_level(Y0,Y1,N)}.

precision_level(S, E, N) when is_number(S), is_number(E) ->
    % Calculate stepsize then 'humanize' the value to a human pleasing format.
    R = abs((E - S)) / N,
    if
        abs(R) < ?float_error -> 2;
        true ->
            %% get the ratio on the form of 2-3 significant digits.
            V =  2 - math:log10(R),
            trunc(V + 0.5)
    end;
precision_level(_, _, _) -> 2.

% on form [{X,Y}] | [{X,Y,E}]
xy_minmax(Elements) ->
    {Xs, Ys} = lists:foldl(fun ({X,Y,_}, {Xis, Yis}) -> {[X|Xis],[Y|Yis]};
                               ({X,Y},   {Xis, Yis}) -> {[X|Xis],[Y|Yis]}
                          end, {[],[]}, Elements),
    {{lists:min(Xs),lists:min(Ys)}, {lists:max(Xs), lists:max(Ys)}}.

xy_resulting_ranges({{X0,Y0},{X1,Y1}},{{X2,Y2},{X3,Y3}}) ->
    {
      {lists:min([X0,X1,X2,X3]), lists:min([Y0,Y1,Y2,Y3])},
      {lists:max([X0,X1,X2,X3]), lists:max([Y0,Y1,Y2,Y3])}
    }.

update_dxdy({{Rx0, Ry0}, {Rx1, Ry1}}, {{Bx0,By0},{Bx1,By1}}) ->
    Dx = divide((Bx1 - Bx0),(Rx1 - Rx0)),
    Dy = divide((By1 - By0),(Ry1 - Ry0)),
    {Dx,Dy}.

divide(_T, N) when abs(N) < ?float_error -> 0.0;
%divide(T, N) when abs(N) < ?float_error -> exit({bad_divide, {T,N}});
divide(T, N) -> T / N.

get_graph_color(Chart, ColorIndex) ->
    case Chart#chart.graph_rgba of
        undefined ->
            egd_colorscheme:select(default, ColorIndex);
        UserDefined ->
            egd:color(UserDefined)
    end.

render_graph(Im, Chart) ->
    Output = egd:render(Im, Chart#chart.type,
                        [{render_engine, Chart#chart.render_engine}]),
    egd:destroy(Im),
    try erlang:exit(Im, normal) catch _:_ -> ok end,
    Output.

load_font(Chart) ->
    Path = filename:join([code:priv_dir(percept), "fonts", Chart#chart.font]),
    case filelib:is_regular(Path) of
        true ->
            egd_font:load(Path);
        false ->
            throw({erorr, {font_not_found, Chart#chart.font}})
    end.

string(E, _P) when is_atom(E)    -> atom_to_list(E);
string(E,  P) when is_float(E)   -> float_to_maybe_integer_to_string(E, P);
string(E, _P) when is_integer(E) -> s("~w", [E]);
string(E, _P) when is_binary(E)  -> lists:flatten(binary_to_list(E));
string(E, _P) when is_list(E)    -> s("~s", [E]).

float_to_maybe_integer_to_string(F, P) ->
    I = trunc(F),
    A = abs(I - F),
    if
        A < ?float_error ->
            %% integer
            s("~w", [I]);
        true ->
            %% float
            Format = s("~~.~wf", [P]),
            s(Format, [F])
    end.

s(Format, Terms) -> lists:flatten(io_lib:format(Format, Terms)).
