msgq_flood -- Erlang VM でメッセージキューがたまると困る問題の再現コード
=================================================================

現象と課題
---------

Erlang VM の軽量プロセスのメッセージキューが数万を超えると、
メッセージキューの吸い込み速度が極端に遅くなる。

たとえば、以下の構成で、log_serve が複数のプロセスからのメッセージを受け付けているとき、
log_server のメッセージキュー長が増えると発生する。

```
  +----------------+        +------------+
  | sender process | -----> | log_server | ---> (file write)
  +----------------+     -> +------------+
                        / 
  +----------------+   / 
  | sender process | -/
  +----------------+
```
  
これを、以下の構成にすると、回避できる。
dam が log_server の前に入って、log_server のメッセージキュー長を見ながら
たまりすぎないように調整すると、dam 自身は遅くならなず、 log_server の遅延も発生しない。

```
  +----------------+        +-----+      +------------+
  | sender process | -----> | dam | ---> | log_server | ---> (file write)
  +----------------+     -> +-----+      +------------+
                        / 
  +----------------+   / 
  | sender process | -/
  +----------------+
```

この動作を再現するのが、本コードである。

使い方
------

事前に erlan shell を起動しておく。

### log_server のキュー処理が遅くなる現象を再現

```
%% モジュール読み込み
1> c(msgq_flood).
{ok,msgq_flood}

%% ログサーバとダム起動 (書き込み先は "a.log")
2> msgq_flood:start_link("a.log").
{ok,<0.67.0>}

%% プロセス確認
3> whereis(log_server).
<0.67.0>
4> whereis(log_dam).   
<0.68.0>

%% log_server に直接大量のメッセージを送る (100プロセス x 1万通 = 100万通)
5> msgq_flood:flood_direct(100, 10000).
ok

%% キュー残数と差分を観測する
6> msgq_flood:watch().
DateTime                        dam msgq (diff) server msgq (diff)
2019-06-30T08:26:47.392Z        0 (0)   795310 (0)
2019-06-30T08:26:48.395Z        0 (0)   999293 (203983)
2019-06-30T08:26:49.396Z        0 (0)   999221 (-72)
2019-06-30T08:26:50.397Z        0 (0)   999153 (-68)
2019-06-30T08:26:51.398Z        0 (0)   999083 (-70)
%% log_server のキュー吸い込みレートが 100通/秒 未満
```

このとき、Erlang VM は1コア占有状態になっている。

```
PID    COMMAND      %CPU  TIME     #TH   #WQ  #PORTS MEM    PURG   CMPRS  PGRP
60728  beam.smp     100.9 01:48.63 32/1  0    54     189M+  0B     0B     60728
```

### dam を経由すると遅くならないことを再現

```
%% モジュール読み込み
1> c(msgq_flood).
{ok,msgq_flood}

%% ログサーバとダム起動 (書き込み先は "a.log")
2> msgq_flood:start_link("a.log").
{ok,<0.67.0>}

%% dam に直接大量のメッセージを送る (100プロセス x 1万通 = 100万通)
3> msgq_flood:flood_to_dam(100, 10000).
ok

%% キュー残数と差分を観測する
4> msgq_flood:watch().
DateTime                        dam msgq (diff) server msgq (diff)
2019-06-30T08:34:24.366Z        329062 (0)      1999 (0)
2019-06-30T08:34:25.368Z        476762 (147700) 107 (-1892)
2019-06-30T08:34:26.369Z        610306 (133544) 9784 (9677)
2019-06-30T08:34:27.370Z        666357 (56051)  9526 (-258)
2019-06-30T08:34:28.371Z        658809 (-7548)  9223 (-303)
2019-06-30T08:34:29.372Z        651221 (-7588)  9729 (506)
%% dam の吸い込みレートは　数千通/秒 を維持
```

プロファイル
------------

flood_direct 後に `eprof` で log_server をプロファイルした結果:

```
FUNCTION                                       CALLS        %      TIME  [uS / CALLS]
--------                                       -----  -------      ----  [----------]
gen_server:handle_msg/5                          784     0.00       837  [      1.07]
prim_file:drv_get_response/1                     784     0.00       956  [      1.22]
gen_server:decode_msg/8                          784     0.00      1044  [      1.33]
prim_file:write/2                                784     0.00      1082  [      1.38]
gen_server:handle_common_reply/6                 784     0.00      1415  [      1.80]
gen_server:loop/6                                784     0.00      1498  [      1.91]
prim_file:get_uint64/1                           784     0.00      1551  [      1.98]
prim_file:'-drv_command_nt/3-after$^0/0-0-'/1    784     0.00      1571  [      2.00]
prim_file:drv_get_response/2                     784     0.00      1703  [      2.17]
gen_server:try_dispatch/4                        784     0.00      1942  [      2.48]
prim_file:drv_command_nt/3                       784     0.00      1972  [      2.52]
msgq_flood:handle_cast/2                         784     0.00      2075  [      2.65]
erlang:port_command/2                            784     0.00      2270  [      2.90]
file:write/2                                     784     0.00      2429  [      3.10]
prim_file:translate_response/2                   784     0.00      2758  [      3.52]
prim_file:get_uint32/1                          1568     0.00      3882  [      2.48]
erts_internal:port_command/3                     784     0.01     13662  [     17.43]
erlang:bump_reductions/1                         784    14.35  13169774  [  16798.18]
gen_server:try_dispatch/3                        784    85.61  78579284  [ 100228.68]
---------------------------------------------  -----  -------  --------  [----------]
Total:                                         15680  100.00%  91791705  [   5854.06]
```

### erlang:bump_reductions/1 のコード
（実態はNIF）
erts/emulator/beam/bif.c:
```c
BIF_RETTYPE bump_reductions_1(BIF_ALIST_1)
{
    Sint reds;

    if (is_not_small(BIF_ARG_1) || ((reds = signed_val(BIF_ARG_1)) < 0)) {
        BIF_ERROR(BIF_P, BADARG);
    }

    if (reds > CONTEXT_REDS) {
        reds = CONTEXT_REDS;
    }
    BIF_RET2(am_true, reds);
}
```

ループもロックも無し。ここで時間を食う可能性は低くないか？

### gen_server:try_dispatch/3 のコード

lib/stdlib/src/gen_server.erl:

```erlang
try_dispatch({'$gen_cast', Msg}, Mod, State) ->
    try_dispatch(Mod, handle_cast, Msg, State);
try_dispatch(Info, Mod, State) ->
    try_dispatch(Mod, handle_info, Info, State).
```

この、ただの分岐関数が時間を食うわけないよね。

トライアル
----------

dam とlog_server の処理を変えたら現象が変化しないか、試した記録。

### log_server のファイル書き込みをやめる

現象発生せず。
数秒で100万通の吸い込みが完了。

### ログ書き込み先を /dev/null にする

現象は変わらず。
ファイルシステムへの書き込みが問題なわけではなさそう。

### ログメッセージを最小の1バイトにする

現象は変わらず。

サイズが小さければ大丈夫ということでもなさそう。

### ログメッセージを Refc Binary にする

メッセージを70バイトのバイナリにしたが、現象は変わらず。

Refc Binary とは、64バイトを超えるバイナリのことで、
Erlang VM はこのバイナリはプロセスヒープに置かずに、別の場所でリファレンスカウントを
使って管理している。

バイナリの扱い方は関係なさそう。

### message_queue_data = off_heap にしてみる

log_server にて process_flag(message_queue_data, off_heap) をしても現象は変わらず。

むしろ、吸い込み速度が、20％程度低下した。
on_heap 時は 60通/秒 程度が、off_heap 時は 50通/秒 になった。

### file:open のオプションを変えてみる

* append, raw, delayed_write → 再現 （元々のコード）
* append, raw → 再現
* append → 現象再現せず！
* append, delayed_write → 現象再現せず！

`raw` を指定しなければ遅くならない。
これが原因か？


