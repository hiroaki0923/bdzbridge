import pytest

from bdzbridge.recorder.series import same_title_key, series_key, series_name, summary_key


def test_series_name_cuts_at_episode_markers():
    assert series_name("日曜劇場「ＳＡＭＰＬＥ」第１８話　前半戦完結　主人公＆相棒") == "日曜劇場「ＳＡＭＰＬＥ」"
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
    assert series_key("日曜劇場「SAMPLE」 第1話") == series_key("日曜劇場「ＳＡＭＰＬＥ」第１８話")
    assert series_key("サンプルニュース　あさの放送[字]") == series_key("サンプルニュース　あさの放送")
    assert series_key("") == ""


@pytest.mark.parametrize("title,name", [
    ("サンプルえもん　【夢ホール】【ねこっかぶり】", "サンプルえもん"),
    ("サンプルしんちゃん　【ホットケーキはホッとするゾ】", "サンプルしんちゃん"),
    ("サンプルスイッチ▽フレーミーとたね　▽たこたこピー", "サンプルスイッチ"),
    ("サンプルスイッチ「この装置　こんな名前がついてましたＳＰ」", "サンプルスイッチ"),
    ("それいけ！サンプルマン「カップケーキちゃんとふでじいさん・他」", "それいけ！サンプルマン"),
    ("刑事サンプル（４８）「幻の宝（たから）石」", "刑事サンプル"),
    ("ＳａｍｐｌｅＢｕｓーサンプルバスー　★大人気の知育アニメがテレビで登場！", "ＳａｍｐｌｅＢｕｓーサンプルバスー"),
    ("司会者・研究者の！？ＰＲ　人類史３．０　人間とは何か", "司会者・研究者の！？ＰＲ"),
    ("土曜ドラマ「サンプル三ツ星」２分ＰＲ　今後の見どころ紹介！", "土曜ドラマ「サンプル三ツ星」"),  # PR spots join the drama's group
    ("【土曜ドラマ】峠越え　後編", "【土曜ドラマ】峠越え"),
    ("サンプルで会いましょう！（２５）自律神経　最新研究", "サンプルで会いましょう！"),
    ("新プロジェクトＸ「世紀の難工事　架空国際空港」", "新プロジェクトＸ"),
    ("サンプル高校講座　数学Ⅰ　２次不等式[字]", "サンプル高校講座"),
    ("サンプルぷしゅ", "サンプルぷしゅ"),
    ("＃１２　いきなり話数で始まる", "＃１２　いきなり話数で始まる"),
    # sport and events number their instalments differently
    ("サンプル野球　第３戦　架空対架空", "サンプル野球"),
    ("大相撲サンプル場所　１０日目", "大相撲サンプル場所"),
    ("サンプル選手権　決勝", "サンプル選手権"),
    ("サンプル杯　準決勝　第２試合", "サンプル杯"),
    ("サンプルの秘密　その３", "サンプルの秘密"),
    ("サンプル講座　初回スペシャル", "サンプル講座"),
    ("サンプル初日の出中継", "サンプル初日の出中継"),  # 初日 is an episode word, 初日の出 is not
    # full-width marks, as broadcasters write them
    ("【HV】サンプル紀行＜再＞", "サンプル紀行"),
    ("サンプル劇場（後）", "サンプル劇場"),
    # a ▼ subtitle sitting before the episode number is not part of the name either
    ("サンプルゴルフ女子▼架空杯争奪第４戦", "サンプルゴルフ女子"),
    ("サンプル台所　Ｓｅａｓｏｎ２[終]▼最終話「南瓜」", "サンプル台所　Ｓｅａｓｏｎ２"),
])
def test_series_name_on_real_titles(title, name):
    assert series_name(title) == name


def test_same_title_and_summary_keys():
    assert same_title_key("ドラマＡ　第３話[再]") == same_title_key("ドラマA 第3話") == "ドラマa第3話"
    assert same_title_key("ドラマＡ　第３話") != same_title_key("ドラマＡ　第４話")
    assert summary_key("（再放送）あらすじ　本文") == summary_key("あらすじ本文[再]") == "あらすじ本文"
    assert summary_key("") == "" and summary_key(None) == ""
