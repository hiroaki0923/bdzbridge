from recbridge.recorder.series import series_key, series_name


def test_series_name_cuts_at_episode_markers():
    assert series_name("日曜劇場「ＶＩＶＡＮＴ」第１８話　前半戦完結　乃木＆ノコル") == "日曜劇場「ＶＩＶＡＮＴ」"
    assert series_name("豊臣兄弟！（３５）秀長誕生") == "豊臣兄弟！"
    assert series_name("名探偵プリキュア！　＃３３ 名探偵の道も一歩から") == "名探偵プリキュア！"
    assert series_name("マルコ・ポーロの冒険（２３）「王の中の王フビライ」") == "マルコ・ポーロの冒険"
    assert series_name("[字]おかあさんといっしょ　月曜日") == "おかあさんといっしょ"
    assert series_name("ドキュメント７２時間ＰＲ") == "ドキュメント７２時間ＰＲ"
    assert series_name("必殺仕事人Ⅳ　第１４話「主水節分の豆を食べる」") == "必殺仕事人Ⅳ"
    assert series_name("パウ・パトロール「ピカピカパーティーでプカプカピンチ！」") == "パウ・パトロール"
    assert series_name("アニメ　おさるのジョージ「こんがら交換」「みどり、あお」") == "アニメ　おさるのジョージ"
    assert series_name("【土曜ドラマ】憶えのない殺人　後編「迷宮」") == "【土曜ドラマ】憶えのない殺人"
    assert series_name("ドラえもん　【夢ホール】【ねこっかぶり】") == "ドラえもん"


def test_series_key_normalises_width_and_case():
    assert series_key("日曜劇場「VIVANT」 第1話") == series_key("日曜劇場「ＶＩＶＡＮＴ」第１８話")
    assert series_key("ＮＨＫニュース　おはよう日本[字]") == series_key("NHKニュース　おはよう日本")
    assert series_key("") == ""
