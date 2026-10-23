import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_locales.dart';
import 'package:omioclink_client/data/locale_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppLocales.resolve', () {
    test('系统是英文就用英文', () {
      expect(
        AppLocales.resolve(const [Locale('en', 'US')]).languageCode,
        'en',
      );
    });

    test('中文不区分地区（简繁都命中）', () {
      expect(AppLocales.resolve(const [Locale('zh', 'TW')]).languageCode, 'zh');
      expect(AppLocales.resolve(const [Locale('zh', 'CN')]).languageCode, 'zh');
    });

    test('日文 / 韩文各自命中', () {
      expect(AppLocales.resolve(const [Locale('ja', 'JP')]).languageCode, 'ja');
      expect(AppLocales.resolve(const [Locale('ko', 'KR')]).languageCode, 'ko');
    });

    test('系统语言不在支持列表时回落到中文，而不是列表第一个', () {
      expect(
        AppLocales.resolve(const [Locale('fr', 'FR')]).languageCode,
        'zh',
        reason: '法语用户不该被塞一份英文界面',
      );
    });

    test('系统偏好有多门语言时取第一个支持的', () {
      expect(
        AppLocales.resolve(const [Locale('de'), Locale('ja')]).languageCode,
        'ja',
      );
    });

    test('空列表 / null 也回落到中文', () {
      expect(AppLocales.resolve(const <Locale>[]).languageCode, 'zh');
      expect(AppLocales.resolve(null).languageCode, 'zh');
    });

    test('语言选项用它自己的语言命名', () {
      expect(AppLocales.nativeName('zh'), '中文');
      expect(AppLocales.nativeName('en'), 'English');
      expect(AppLocales.nativeName('ja'), '日本語');
      expect(AppLocales.nativeName('ko'), '한국어');
    });
  });

  group('LocaleStore', () {
    test('默认跟随系统', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocaleStore();
      await store.load();
      expect(store.locale, isNull);
      expect(store.followsSystem, isTrue);
      expect(store.selection, AppLocales.system);
    });

    test('选择语言会落盘，下次启动读得回来', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocaleStore();
      await store.load();
      await store.select('ja');
      expect(store.locale?.languageCode, 'ja');

      final again = LocaleStore();
      await again.load();
      expect(again.selection, 'ja');
    });

    test('选「跟随系统」把记录清掉', () async {
      SharedPreferences.setMockInitialValues({'omioclink.locale': 'ko'});
      final store = LocaleStore();
      await store.load();
      expect(store.selection, 'ko');

      await store.select(AppLocales.system);
      expect(store.locale, isNull);

      final again = LocaleStore();
      await again.load();
      expect(again.selection, AppLocales.system);
    });

    test('存了个不支持的语言码就当没选过', () async {
      SharedPreferences.setMockInitialValues({'omioclink.locale': 'fr'});
      final store = LocaleStore();
      await store.load();
      expect(store.selection, AppLocales.system);
    });

    test('重复选同一个语言不再通知（免得整棵树白重建一次）', () async {
      SharedPreferences.setMockInitialValues({'omioclink.locale': 'en'});
      final store = LocaleStore();
      await store.load();

      var notified = 0;
      store.addListener(() => notified++);
      await store.select('en');
      expect(notified, 0);

      await store.select('ko');
      expect(notified, 1);
    });
  });

  group('Accept-Language', () {
    test('选完语言后接口层拿到的就是这门语言', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocaleStore();
      await store.load();

      await store.select('ko');
      expect(AppLocales.activeLanguageCode, 'ko');

      await store.select('en');
      expect(AppLocales.activeLanguageCode, 'en');
    });

    test('跟随系统时按系统语言解析（不写死中文）', () async {
      SharedPreferences.setMockInitialValues({'omioclink.locale': 'ja'});
      final store = LocaleStore();
      await store.load();
      expect(AppLocales.activeLanguageCode, 'ja');

      await store.select(AppLocales.system);
      expect(
        AppLocales.activeLanguageCode,
        AppLocales.resolve(PlatformDispatcher.instance.locales).languageCode,
      );
    });

    test('不支持的语言码不会写进请求头', () {
      AppLocales.setActive('ja');
      AppLocales.setActive('fr');
      expect(AppLocales.activeLanguageCode, 'zh');
    });
  });
}
