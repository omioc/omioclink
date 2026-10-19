import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';

void main() {
  group('MusicTrack', () {
    test('解析服务端下发的完整字段', () {
      final track = MusicTrack.fromJson(<String, dynamic>{
        'platform': 'wy',
        'id': '509781655',
        'name': '想你就写信',
        'artists': <dynamic>[
          <String, dynamic>{'id': '6452', 'name': '周杰伦'},
          <String, dynamic>{'id': '12010120', 'name': '李硕'},
        ],
        'album': <String, dynamic>{
          'id': '36412633',
          'name': '中国新歌声',
          'coverUrl': 'https://p1.music.126.net/a.jpg',
        },
        'durationMs': 238698,
        'coverUrl': 'https://p1.music.126.net/a.jpg',
        'musicInfo': <String, dynamic>{'id': 509781655, 'fee': 1},
      });

      expect(track.key, 'wy:509781655');
      expect(track.artistLabel, '周杰伦 / 李硕');
      expect(track.duration, const Duration(milliseconds: 238698));
      expect(track.album?.name, '中国新歌声');
      // 跨层契约字段：必须原样保留，解析直链时整块交给音源脚本
      expect(track.musicInfo['id'], 509781655);
      expect(track.musicInfo['fee'], 1);
    });

    test('字段缺失时不炸（平台返回质量参差不齐）', () {
      final track = MusicTrack.fromJson(<String, dynamic>{'id': '1'});
      expect(track.platform, '');
      expect(track.name, '');
      expect(track.artists, isEmpty);
      expect(track.album, isNull);
      expect(track.artistLabel, '');
      expect(track.duration, isNull);
      expect(track.musicInfo, isEmpty);
    });

    test('toJson 与 fromJson 可往返（本地「最近点过」要靠它）', () {
      final track = MusicTrack.fromJson(<String, dynamic>{
        'platform': 'kw',
        'id': '474678847',
        'name': '花海',
        'artists': <dynamic>[
          <String, dynamic>{'name': '周杰伦'},
        ],
        'album': <String, dynamic>{'name': '哎呦，不错哦'},
        'durationMs': 210000,
        'musicInfo': <String, dynamic>{'MUSICRID': 'MUSIC_474678847'},
      });

      final restored = MusicTrack.fromJson(track.toJson());
      expect(restored.key, track.key);
      expect(restored.name, track.name);
      expect(restored.artistLabel, '周杰伦');
      expect(restored.durationMs, 210000);
      expect(restored.musicInfo['MUSICRID'], 'MUSIC_474678847');
    });
  });

  group('信封模型', () {
    test('搜索结果带单平台降级说明', () {
      final result = MusicSearchResult.fromJson(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'platform': 'wy', 'id': '1', 'name': 'A'},
        ],
        'total': 2,
        'hasMore': true,
        'errors': <dynamic>[
          <String, dynamic>{'platform': 'kw', 'message': '酷我 返回 HTTP 500'},
        ],
      });

      expect(result.items.single.name, 'A');
      expect(result.total, 2);
      expect(result.hasMore, isTrue);
      expect(result.errors.single.platform, 'kw');
    });

    test('首页结果解析专题与榜单预览', () {
      final home = MusicHomeResult.fromJson(<String, dynamic>{
        'platform': 'wy',
        'topics': <dynamic>[
          <String, dynamic>{
            'id': 'night',
            'name': '夜晚氛围',
            'description': '城市的夜',
            'coverUrl': 'https://x/cover.jpg',
            'kind': 'search',
            'target': '夜晚 纯音乐',
          },
        ],
        'charts': <dynamic>[
          <String, dynamic>{
            'chart': <String, dynamic>{'platform': 'wy', 'id': '3778678', 'name': '热歌榜'},
            'items': <dynamic>[
              <String, dynamic>{
                'rank': 1,
                'track': <String, dynamic>{'platform': 'wy', 'id': '9', 'name': '第一首'},
              },
            ],
          },
        ],
      });

      expect(home.platform, 'wy');
      expect(home.topics.single.name, '夜晚氛围');
      expect(home.charts.single.chart.name, '热歌榜');
      expect(home.charts.single.items.single.rank, 1);
      expect(home.charts.single.items.single.track.name, '第一首');
    });

    test('空响应退化成空集合（离线时的兜底）', () {
      final home = MusicHomeResult.fromJson(const <String, dynamic>{});
      expect(home.topics, isEmpty);
      expect(home.charts, isEmpty);
      expect(home.errors, isEmpty);

      final tracks = MusicTrackPage.fromJson(const <String, dynamic>{});
      expect(tracks.items, isEmpty);
      expect(tracks.hasMore, isFalse);
    });
  });

  test('平台展示名有兜底', () {
    expect(musicPlatformLabel('wy'), '网易云');
    expect(musicPlatformLabel('kg'), '酷狗');
    expect(musicPlatformLabel('unknown'), 'unknown');
  });
}
