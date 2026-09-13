from bdzbridge.recorder.series import series_key, series_name


def test_series_name_cuts_at_episode_markers():
    assert series_name("日曜劇場「サンプルドラマ」第１８話　前半戦完結　主人公＆相棒") == "日曜劇場「サンプルドラマ」"
    assert series_name("架空兄弟！（３５）弟の誕生") == "架空兄弟！"
    assert series_name("名探偵サンプル！　＃３３ 名探偵の道も一歩から") == "名探偵サンプル！"
    assert series_name("冒険者サンプルの旅（２３）「王の中の王」") == "冒険者サンプルの旅"
    assert series_name("[字]サンプルといっしょ　月曜日") == "サンプルといっしょ"
    assert series_name("記録サンプル７２分ＰＲ") == "記録サンプル７２分ＰＲ"
    assert series_name("必殺サンプル人Ⅳ　第１４話「主人公節分の豆を食べる」") == "必殺サンプル人Ⅳ"
    assert series_name("サンプル・パトロール「ピカピカパーティーでプカプカピンチ！」") == "サンプル・パトロール"
    assert series_name("アニメ　サンプルなおさる「こんがら交換」「みどり、あお」") == "アニメ　サンプルなおさる"
    assert series_name("【土曜ドラマ】覚えのない事件　後編「迷宮」") == "【土曜ドラマ】覚えのない事件"
    assert series_name("サンプルえもん　【夢ホール】【ねこっかぶり】") == "サンプルえもん"


def test_series_key_normalises_width_and_case():
    assert series_key("日曜劇場「サンプルドラマ」 第1話") == series_key("日曜劇場「サンプルドラマ」第１８話")
    assert series_key("サンプルニュース　あさの放送[字]") == series_key("サンプルニュース　あさの放送")
    assert series_key("") == ""
