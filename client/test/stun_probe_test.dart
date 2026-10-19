import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/media/stun_probe.dart';

const int _magicCookie = 0x2112A442;

/// 独立于被测代码的 XOR-MAPPED-ADDRESS 编码器（交叉验证解析结果）。
Uint8List _encodeXorMappedAddress(String ipv4, int port) {
  final octets = ipv4.split('.').map(int.parse).toList();
  final value = Uint8List(8);
  value[0] = 0;
  value[1] = 0x01; // IPv4
  final xPort = port ^ (_magicCookie >> 16);
  value[2] = (xPort >> 8) & 0xFF;
  value[3] = xPort & 0xFF;
  for (var i = 0; i < 4; i++) {
    value[4 + i] = octets[i] ^ ((_magicCookie >> (8 * (3 - i))) & 0xFF);
  }
  return value;
}

Uint8List _buildResponse(
  List<int> transactionId,
  Uint8List attributeValue, {
  int attributeType = 0x0020,
  int? declaredLength,
  int type = 0x0101,
  int cookie = _magicCookie,
}) {
  final padding = (4 - attributeValue.length % 4) % 4;
  final body = Uint8List(4 + attributeValue.length + padding);
  final bodyView = ByteData.view(body.buffer);
  bodyView.setUint16(0, attributeType);
  bodyView.setUint16(2, attributeValue.length);
  body.setRange(4, 4 + attributeValue.length, attributeValue);

  final message = Uint8List(20 + body.length);
  final view = ByteData.view(message.buffer);
  view.setUint16(0, type);
  view.setUint16(2, declaredLength ?? body.length);
  view.setUint32(4, cookie);
  message.setRange(8, 20, transactionId);
  message.setRange(20, 20 + body.length, body);
  return message;
}

void main() {
  final transactionId = List<int>.generate(12, (index) => index * 3);

  test('buildBindingRequest 是合法的 20 字节 Binding Request', () {
    final request = StunProbe.buildBindingRequest(transactionId);
    final view = ByteData.view(request.buffer);
    expect(request.length, 20);
    expect(view.getUint16(0), 0x0001);
    expect(view.getUint16(2), 0, reason: '请求不带属性');
    expect(view.getUint32(4), _magicCookie);
    expect(request.sublist(8), transactionId);
  });

  test('解析 XOR-MAPPED-ADDRESS 得到公网映射地址', () {
    final response = _buildResponse(
      transactionId,
      _encodeXorMappedAddress('203.0.113.7', 54321),
    );
    final parsed = StunProbe.parseBindingResponse(response, transactionId);
    expect(parsed, isNotNull);
    expect(parsed!.address.address, '203.0.113.7');
    expect(parsed.port, 54321);
  });

  test('也能解析未做 XOR 的 MAPPED-ADDRESS', () {
    final value = Uint8List(8);
    value[1] = 0x01;
    value[2] = 0x52; // 端口 21077 = 0x5255 的高字节
    value[3] = 0x55; //                    低字节
    value[4] = 10;
    value[5] = 0;
    value[6] = 0;
    value[7] = 5;
    final response = _buildResponse(
      transactionId,
      value,
      attributeType: 0x0001,
    );
    final parsed = StunProbe.parseBindingResponse(response, transactionId);
    expect(parsed!.address.address, '10.0.0.5');
    expect(parsed.port, 21077);
  });

  test('忽略无关属性并按 4 字节对齐', () {
    // 属性值长度 5 → 需要 3 字节补齐；解析应跳过它继续找 XOR-MAPPED-ADDRESS
    final noise = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    final padding = (4 - noise.length % 4) % 4;
    final noiseBody = Uint8List(4 + noise.length + padding);
    ByteData.view(noiseBody.buffer).setUint16(0, 0x8022); // SOFTWARE
    ByteData.view(noiseBody.buffer).setUint16(2, noise.length);
    noiseBody.setRange(4, 4 + noise.length, noise);

    final mapped = _encodeXorMappedAddress('198.51.100.9', 12345);
    final mappedBody = Uint8List(12);
    ByteData.view(mappedBody.buffer).setUint16(0, 0x0020);
    ByteData.view(mappedBody.buffer).setUint16(2, mapped.length);
    mappedBody.setRange(4, 12, mapped);

    final body = Uint8List(noiseBody.length + mappedBody.length)
      ..setRange(0, noiseBody.length, noiseBody)
      ..setRange(
        noiseBody.length,
        noiseBody.length + mappedBody.length,
        mappedBody,
      );

    final message = Uint8List(20 + body.length);
    final view = ByteData.view(message.buffer);
    view.setUint16(0, 0x0101);
    view.setUint16(2, body.length);
    view.setUint32(4, _magicCookie);
    message.setRange(8, 20, transactionId);
    message.setRange(20, 20 + body.length, body);

    final parsed = StunProbe.parseBindingResponse(message, transactionId);
    expect(parsed!.address.address, '198.51.100.9');
    expect(parsed.port, 12345);
  });

  test('畸形响应返回 null', () {
    final good = _buildResponse(
      transactionId,
      _encodeXorMappedAddress('203.0.113.7', 54321),
    );
    // 事务 ID 不匹配（防串包）
    expect(
      StunProbe.parseBindingResponse(good, List<int>.filled(12, 9)),
      isNull,
    );
    // 不是 success response
    expect(
      StunProbe.parseBindingResponse(
        _buildResponse(
          transactionId,
          _encodeXorMappedAddress('203.0.113.7', 54321),
          type: 0x0111,
        ),
        transactionId,
      ),
      isNull,
    );
    // magic cookie 不对
    expect(
      StunProbe.parseBindingResponse(
        _buildResponse(
          transactionId,
          _encodeXorMappedAddress('203.0.113.7', 54321),
          cookie: 0xDEADBEEF,
        ),
        transactionId,
      ),
      isNull,
    );
    // 长度不足
    expect(StunProbe.parseBindingResponse(Uint8List(8), transactionId), isNull);
    expect(StunProbe.parseBindingResponse(Uint8List(0), transactionId), isNull);
  });

  test('属性声明长度越界时安全退出', () {
    // 头部声明属性值长度 8，但实际只给了 4 字节
    final body = Uint8List.fromList(<int>[
      0x00, 0x20, 0x00, 0x08, // XOR-MAPPED-ADDRESS，长度 8
      0x00, 0x01, 0x12, 0x34, // 只有 4 字节
    ]);
    final message = Uint8List(20 + body.length);
    final view = ByteData.view(message.buffer);
    view.setUint16(0, 0x0101);
    view.setUint16(2, body.length);
    view.setUint32(4, _magicCookie);
    message.setRange(8, 20, transactionId);
    message.setRange(20, 20 + body.length, body);

    expect(StunProbe.parseBindingResponse(message, transactionId), isNull);
  });

  test('address 属性长度不足时返回 null（不越界读）', () {
    final response = _buildResponse(
      transactionId,
      Uint8List.fromList(<int>[0, 1]),
    );
    expect(StunProbe.parseBindingResponse(response, transactionId), isNull);
  });
}
