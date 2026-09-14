import pytest

from bdzbridge.recorder.series import same_title_key, series_key, series_name, summary_key


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


@pytest.mark.parametrize("title,name", [
    ("ドラえもん　【夢ホール】【ねこっかぶり】", "ドラえもん"),
    ("クレヨンしんちゃん　【ホットケーキはホッとするゾ】", "クレヨンしんちゃん"),
    ("ピタゴラスイッチ▽フレーミーとたね　▽たこたこピー", "ピタゴラスイッチ"),
    ("ピタゴラスイッチ「この装置　こんな名前がついてましたＳＰ」", "ピタゴラスイッチ"),
    ("それいけ！アンパンマン「カップケーキちゃんとふでじいさん・他」", "それいけ！アンパンマン"),
    ("刑事コロンボ（４８）「幻の娼（しょう）婦」", "刑事コロンボ"),
    ("ＢａｂｙＢｕｓーベビーバスー　★大人気の知育アニメがテレビで登場！", "ＢａｂｙＢｕｓーベビーバスー"),
    ("タモリ・山中伸弥の！？ＰＲ　人類史３．０　人間とは何か", "タモリ・山中伸弥の！？ＰＲ"),
    ("土曜ドラマ「ムショラン三ツ星」２分ＰＲ　今後の見どころ紹介！", "土曜ドラマ「ムショラン三ツ星」"),  # PR spots join the drama's group
    ("【土曜ドラマ】天城越え　後編", "【土曜ドラマ】天城越え"),
    ("フロンティアで会いましょう！（２５）自律神経　最新研究", "フロンティアで会いましょう！"),
    ("新プロジェクトＸ「世紀の難工事　関西国際空港」", "新プロジェクトＸ"),
    ("ＮＨＫ高校講座　数学Ⅰ　２次不等式[字]", "ＮＨＫ高校講座"),
    ("ミャクぷしゅ", "ミャクぷしゅ"),
    ("＃１２　いきなり話数で始まる", "＃１２　いきなり話数で始まる"),
])
def test_series_name_on_real_titles(title, name):
    assert series_name(title) == name


def test_same_title_and_summary_keys():
    assert same_title_key("ドラマＡ　第３話[再]") == same_title_key("ドラマA 第3話") == "ドラマa第3話"
    assert same_title_key("ドラマＡ　第３話") != same_title_key("ドラマＡ　第４話")
    assert summary_key("（再放送）あらすじ　本文") == summary_key("あらすじ本文[再]") == "あらすじ本文"
    assert summary_key("") == "" and summary_key(None) == ""
